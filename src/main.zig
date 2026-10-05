//! mzdiff: compares two mzML files by what they mean, fast, in one forward pass over both.
//!
//! A is the reference (usually TRFP's mzML next to the .raw), B the output under test. Spectra
//! pair by native id in any vendor's format (by scan number when the formats differ, by position
//! when neither works) through a bounded join that needs no order, so a spectrum missing or moved
//! on one side is reported once and the pairs around it stay correct. Chromatograms pair by
//! type and id, then type, then id. The headers are compared too, without the parts that differ
//! between tools by design (cvList, softwareList, dataProcessingList, ids, file locations), and
//! an indexed file's trailer must be complete.
//!
//! Each difference is filed under a class with a severity (see `rules.zig`): critical, major,
//! minor, or ignored. Output lists the classes, most severe and most frequent first, with
//! examples. Each file is read and decoded on its own thread, so the two inputs are parsed at
//! the same time; memory stays bounded by the queue depth. Exit status: 0 when nothing at or
//! above `--fail-on` (default major) differs, 1 when something does, 2 for a usage error or a
//! file that cannot be read.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const model = mzml.model;

const compare = @import("compare.zig");
const html = @import("html.zig");
const output = @import("output.zig");
const pair = @import("pair.zig");
const read = @import("read.zig");
const rules_mod = @import("rules.zig");

const Fact = compare.Fact;
const Kind = compare.Kind;
const Report = compare.Report;
const Rules = rules_mod.Rules;
const Severity = rules_mod.Severity;

const USAGE =
    \\usage: mzdiff [options] A.mzML B.mzML
    \\
    \\Compares B (the output under test) with A (the reference) by meaning, not bytes.
    \\
    \\What to show (one; the report by default):
    \\  --summary          the verdict and its counts, on one line
    \\  --list             every difference, one per line, in the order found
    \\  --view             the differing records as a git-style diff; refuses when too large
    \\  -q, --quiet        nothing; the exit status is the answer
    \\
    \\How to show it (text by default):
    \\  --json             JSON: one document, or JSON Lines with --list
    \\  --tsv              tab-separated rows
    \\  --html             with --view: one self-contained, interactive HTML page
    \\  --color WHEN       auto (default), always, or never; text only
    \\  --side-by-side     with --view: A and B in two columns
    \\  --width N          with --side-by-side: the line width (default COLUMNS, else 160)
    \\
    \\Narrow what is shown (never the verdict):
    \\  --severity LEVEL   critical, major, or minor and above (default minor)
    \\  --key KEY          only this key; repeat for more
    \\  --record ID        only this record, by its native id (--list, --view); repeat for more
    \\  --limit N          print at most N differences (--list), or view at most N records
    \\                     (--view: default 40, or 500 with --html)
    \\  --examples N       examples per class in the report (default 3)
    \\
    \\Compare:
    \\  --ppm X            m/z within X ppm is a minor difference (default 1)
    \\  --set KEY=LEVEL    give KEY this severity: critical, major, minor, or ignored
    \\  --no-header        skip the header
    \\  --max-spectra N    stop after N paired spectra; the result is incomplete
    \\  --fail-on LEVEL    exit 1 at this severity or above (default major)
    \\
    \\  -h, --help         this text
    \\
    \\A KEY is a PSI-MS accession (MS:1000016), user:NAME, @attribute, array:ACCESSION, or a
    \\named check: id, indexed, indexListOffset, instrumentConfiguration, scan, element.
    \\Exit status: 0 same or tolerated, 1 differs, 2 usage error or unreadable file.
    \\
;

const Color = enum { auto, always, never };

const Options = struct {
    a: []const u8,
    b: []const u8,
    mode: output.Mode = .report,
    format: output.Format = .text,
    color: Color = .auto,
    layout: output.Layout = .unified,
    width: ?usize = null,
    selection: output.Selection = .{},
    examples: usize = 3,
    fail_on: Severity = .major,
    max_spectra: ?usize = null,
    ppm: f64 = 1.0,
    header: bool = true,
};

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| {
        std.debug.print("mzdiff: cannot read the arguments: {s}\n", .{@errorName(err)});
        return 2;
    };
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var problem: []const u8 = "";
    var options = parse(arena, args, &rules, &problem) catch |err| switch (err) {
        error.Help => {
            std.Io.File.stdout().writeStreamingAll(io, USAGE) catch {};
            return 0;
        },
        else => {
            std.debug.print(
                "mzdiff: {s}\nmzdiff: run 'mzdiff --help' for the options\n",
                .{if (problem.len != 0) problem else @errorName(err)},
            );
            return 2;
        },
    };
    if (options.width == null) options.width = terminalWidth(init.environ_map);
    const style: output.Style = .{ .color = options.format == .text and useColor(io, init.environ_map, options.color) };
    const interactive = std.Io.File.stdout().isTty(io) catch false;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    const status = run(allocator, io, out, &rules, options, style, interactive) catch |err| {
        // A JSON Lines stream that stops early says so, so its reader cannot mistake it for complete.
        if (options.mode == .list and options.format == .json)
            out.print("{{\"type\": \"error\", \"error\": \"{s}\"}}\n", .{@errorName(err)}) catch {};
        out.flush() catch {};
        // A reader that closed the pipe (`| head`) has what it wanted.
        if (err == error.WriteFailed and brokenPipe(&stdout)) return 0;
        std.debug.print("mzdiff: error.{s}\n", .{@errorName(err)});
        return 2;
    };
    out.flush() catch return if (brokenPipe(&stdout)) 0 else 2;
    return if (status == .differs) 1 else 0;
}

// The side-by-side width: COLUMNS when the shell exports it, else 160.
fn terminalWidth(environ: *const std.process.Environ.Map) usize {
    const text = environ.get("COLUMNS") orelse return 160;
    const width = std.fmt.parseInt(usize, text, 10) catch return 160;
    return @max(width, 80);
}

fn brokenPipe(writer: *const std.Io.File.Writer) bool {
    const err = writer.err orelse return false;
    return err == error.BrokenPipe;
}

// mzValidate's rules: a nonempty NO_COLOR wins, then a nonempty CLICOLOR_FORCE, then a terminal
// whose TERM is not "dumb".
fn useColor(io: std.Io, environ: *const std.process.Environ.Map, color: Color) bool {
    switch (color) {
        .always => return true,
        .never => return false,
        .auto => {},
    }
    if (environ.get("NO_COLOR")) |value| if (value.len != 0) return false;
    if (environ.get("CLICOLOR_FORCE")) |value| if (value.len != 0) return true;
    if (environ.get("TERM")) |term| if (std.mem.eql(u8, term, "dumb")) return false;
    return std.Io.File.stdout().isTty(io) catch false;
}

const Parser = struct {
    args: []const []const u8,
    i: usize = 1,
    arena: std.mem.Allocator,
    problem: *[]const u8,

    fn fail(self: *Parser, comptime fmt: []const u8, values: anytype) error{Usage} {
        self.problem.* = std.fmt.allocPrint(self.arena, fmt, values) catch "invalid arguments";
        return error.Usage;
    }

    fn value(self: *Parser, flag: []const u8) error{Usage}![]const u8 {
        self.i += 1;
        if (self.i == self.args.len) return self.fail("{s} needs a value", .{flag});
        return self.args[self.i];
    }

    fn count(self: *Parser, flag: []const u8) error{Usage}!usize {
        const text = try self.value(flag);
        return std.fmt.parseInt(usize, text, 10) catch self.fail("{s} takes a whole number, not '{s}'", .{ flag, text });
    }

    // `--set` may ignore a key; `--severity` and `--fail-on` take only the three levels.
    fn level(self: *Parser, flag: []const u8, text: []const u8, ignored: bool) error{Usage}!Severity {
        const levels = if (ignored) "critical, major, minor, or ignored" else "critical, major, or minor";
        const found = std.meta.stringToEnum(Severity, text) orelse
            return self.fail("{s} takes {s}, not '{s}'", .{ flag, levels, text });
        if (found == .ignored and !ignored) return self.fail("{s} takes {s}, not '{s}'", .{ flag, levels, text });
        return found;
    }
};

fn parse(arena: std.mem.Allocator, args: []const []const u8, rules: *Rules, problem: *[]const u8) !Options {
    var p: Parser = .{ .args = args, .arena = arena, .problem = problem };
    var files: [2][]const u8 = undefined;
    var file_count: usize = 0;
    var options: Options = .{ .a = "", .b = "" };
    var keys: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var mode_flag: ?[]const u8 = null;
    var format_flag: ?[]const u8 = null;
    var selection_flag: ?[]const u8 = null;
    var list_flag: ?[]const u8 = null;
    var view_flag: ?[]const u8 = null;
    var examples_set = false;
    while (p.i < args.len) : (p.i += 1) {
        const arg = args[p.i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.Help;
        if (modeOf(arg)) |mode| {
            if (mode_flag) |earlier| return p.fail("{s} and {s} are both modes; pick one", .{ earlier, arg });
            mode_flag = arg;
            options.mode = mode;
        } else if (formatOf(arg)) |format| {
            if (format_flag) |earlier| return p.fail("{s} and {s} are both formats; pick one", .{ earlier, arg });
            format_flag = arg;
            options.format = format;
        } else if (std.mem.eql(u8, arg, "--color")) {
            const text = try p.value(arg);
            options.color = std.meta.stringToEnum(Color, text) orelse return p.fail(
                "--color takes auto, always, or never, not '{s}'",
                .{text},
            );
        } else if (std.mem.eql(u8, arg, "--side-by-side")) {
            options.layout = .side_by_side;
            view_flag = arg;
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try p.count(arg);
            view_flag = arg;
        } else if (std.mem.eql(u8, arg, "--severity")) {
            options.selection.severity = try p.level(arg, try p.value(arg), false);
            selection_flag = arg;
        } else if (std.mem.eql(u8, arg, "--key")) {
            try keys.append(arena, try p.value(arg));
            selection_flag = arg;
        } else if (std.mem.eql(u8, arg, "--record")) {
            try records.append(arena, try p.value(arg));
            list_flag = arg;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            options.selection.limit = try p.count(arg);
            list_flag = arg;
        } else if (std.mem.eql(u8, arg, "--examples")) {
            options.examples = try p.count(arg);
            examples_set = true;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.header = false;
        } else if (std.mem.eql(u8, arg, "--max-spectra")) {
            options.max_spectra = try p.count(arg);
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            const text = try p.value(arg);
            options.ppm = std.fmt.parseFloat(f64, text) catch return p.fail("--ppm takes a number, not '{s}'", .{text});
            if (!(options.ppm >= 0)) return p.fail("--ppm cannot be negative", .{});
        } else if (std.mem.eql(u8, arg, "--fail-on")) {
            options.fail_on = try p.level(arg, try p.value(arg), false);
        } else if (std.mem.eql(u8, arg, "--set")) {
            const text = try p.value(arg);
            const eq = std.mem.lastIndexOfScalar(u8, text, '=') orelse return p.fail("--set takes KEY=LEVEL, not '{s}'", .{text});
            try rules.override(text[0..eq], try p.level(arg, text[eq + 1 ..], true));
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            return p.fail("unknown option '{s}'", .{arg});
        } else {
            if (file_count == 2) return p.fail("one file too many: '{s}' (A and B are already given)", .{arg});
            files[file_count] = arg;
            file_count += 1;
        }
    }
    if (file_count != 2) return p.fail("give two files, A (the reference) and B (the output under test)", .{});
    switch (options.mode) {
        .quiet => if (format_flag) |flag| return p.fail("--quiet prints nothing, so {s} does not apply", .{flag}),
        .summary => if (selection_flag) |flag| return p.fail("--summary counts everything, so {s} does not apply", .{flag}),
        .view => if (options.format == .json or options.format == .tsv)
            return p.fail("--view is for people; for programs, use --list {s}", .{format_flag.?}),
        .report, .list => {},
    }
    if (options.format == .html and options.mode != .view) return p.fail("--html works with --view", .{});
    if (options.format == .html and options.layout == .side_by_side)
        return p.fail("--html has both layouts; switch between them on the page", .{});
    if (options.mode != .list and options.mode != .view) if (list_flag) |flag| return p.fail("{s} works with --list or --view", .{flag});
    if (options.mode != .view) if (view_flag) |flag| return p.fail("{s} works with --view", .{flag});
    if (options.mode == .view and options.layout == .unified and options.width != null)
        return p.fail("--width works with --side-by-side", .{});
    if (options.mode != .report and examples_set) return p.fail("--examples applies to the report only", .{});
    options.a = files[0];
    options.b = files[1];
    options.selection.keys = keys.items;
    options.selection.records = records.items;
    return options;
}

fn formatOf(arg: []const u8) ?output.Format {
    if (std.mem.eql(u8, arg, "--json")) return .json;
    if (std.mem.eql(u8, arg, "--tsv")) return .tsv;
    if (std.mem.eql(u8, arg, "--html")) return .html;
    return null;
}

fn modeOf(arg: []const u8) ?output.Mode {
    if (std.mem.eql(u8, arg, "--summary")) return .summary;
    if (std.mem.eql(u8, arg, "--list")) return .list;
    if (std.mem.eql(u8, arg, "--view")) return .view;
    if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) return .quiet;
    return null;
}

const HEADER_SKIP = [_]model.Kind{
    .cv_list,
    .software_list,
    .data_processing_list,
    .referenceable_param_group_list,
    .run,
    .spectrum_list,
    .chromatogram_list,
    .index_list,
};

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    rules: *Rules,
    options: Options,
    style: output.Style,
    interactive: bool,
) !output.Status {
    const sides = try allocator.create([2]read.Side);
    defer allocator.destroy(sides);
    const side_a = &sides[0];
    const side_b = &sides[1];
    try side_a.open(allocator, io, options.a, rules);
    defer side_a.close(io);
    try side_b.open(allocator, io, options.b, rules);
    defer side_b.close(io);

    var report = Report.init(allocator, rules, options.examples);
    defer report.deinit();
    report.ppm = options.ppm;
    var lister: output.Lister = .{
        .out = out,
        .format = options.format,
        .style = style,
        .selection = options.selection,
        .allocator = allocator,
    };
    defer lister.deinit();
    if (options.mode == .list) report.sink = lister.sink();
    var viewer = output.Viewer.init(allocator, out, style, options.selection);
    defer viewer.deinit();
    viewer.layout = options.layout;
    viewer.width = options.width orelse 160;
    if (options.selection.limit) |limit| viewer.tally.records = limit;
    var page = html.Page.init(allocator, out, options.selection);
    defer page.deinit();
    if (options.selection.limit) |limit| page.tally.records = limit;
    if (options.mode == .view) report.sink = if (options.format == .html) page.sink() else viewer.sink();
    // B's broken index trailer is a difference, reported whether or not the header is compared; the
    // reference's is only worth a warning.
    if (side_b.trailer) |problem|
        try report.add(
            null,
            .value,
            "indexedmzML",
            "indexListOffset",
            "index trailer",
            "header",
            side_a.trailer orelse "ok",
            problem,
        );
    if (side_a.trailer) |problem| std.debug.print("mzdiff: {s}: index trailer: {s}\n", .{ side_a.path, problem });

    if (options.header) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var facts_a: std.ArrayList(Fact) = .empty;
        var facts_b: std.ArrayList(Fact) = .empty;
        try compare.collect(arena, rules, &facts_a, side_a.header.document, "", side_a.header.groups, &HEADER_SKIP);
        try compare.collect(arena, rules, &facts_b, side_b.header.document, "", side_b.header.groups, &HEADER_SKIP);
        try collectRun(arena, rules, &facts_a, side_a.header);
        try collectRun(arena, rules, &facts_b, side_b.header);
        // The random-access index, when the reference has one; an index only in B loses nothing.
        if (side_a.header.indexed and !side_b.header.indexed)
            try report.add(null, .value, "indexedmzML", "indexed", "index", "header", "yes", "no");
        try compare.diffFacts(&report, "header", compare.dedupe(facts_a.items), compare.dedupe(facts_b.items));
    }

    const started = std.Io.Timestamp.now(io, .awake);
    // Each side is read, decoded, and reduced on its own thread; this thread pairs and compares.
    var future_a = try io.concurrent(read.produce, .{ allocator, io, side_a });
    var future_b = io.concurrent(read.produce, .{ allocator, io, side_b }) catch |err| {
        side_a.queue.close(io);
        read.drain(allocator, io, side_a);
        future_a.await(io);
        return err;
    };
    var a: read.Stream = .{ .side = side_a, .io = io };
    var b: read.Stream = .{ .side = side_b, .io = io };

    const consumed = pair.run(allocator, &report, &a, &b, options.max_spectra);

    // Stop the readers (a no-op when they finished), free what they queued, and wait for them.
    side_a.queue.close(io);
    side_b.queue.close(io);
    if (a.current) |item| item.free(allocator);
    if (b.current) |item| item.free(allocator);
    read.drain(allocator, io, side_a);
    read.drain(allocator, io, side_b);
    future_a.await(io);
    future_b.await(io);
    const counts = try consumed;
    if (side_a.failure) |err| return err;
    if (side_b.failure) |err| return err;

    const elapsed = std.Io.Timestamp.now(io, .awake).toNanoseconds() - started.toNanoseconds();
    // Nothing to pair is never a pass worth trusting.
    if (side_a.spectra == 0 and side_a.chromatograms == 0) std.debug.print(
        "mzdiff: {s} holds no spectra or chromatograms\n",
        .{side_a.path},
    );

    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    var totals = [_]usize{0} ** 3;
    for (classes) |class| if (class.severity != .ignored) {
        totals[@intFromEnum(class.severity)] += 1;
    };
    const outcome: output.Outcome = .{
        .a = .{ .path = side_a.path, .software = side_a.software, .spectra = side_a.spectra, .chromatograms = side_a.chromatograms },
        .b = .{ .path = side_b.path, .software = side_b.software, .spectra = side_b.spectra, .chromatograms = side_b.chromatograms },
        .paired_spectra = counts.spectra,
        .paired_chromatograms = counts.chromatograms,
        .completion = if (counts.stopped_early) .incomplete else .complete,
        .status = output.statusOf(classes, options.fail_on),
        .fail_on = options.fail_on,
        .totals = totals,
        .seconds = if (interactive) @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s else null,
    };
    switch (options.mode) {
        .report => try output.writeReport(out, options.format, style, outcome, classes, options.selection),
        .summary => try output.writeSummary(out, options.format, style, outcome),
        .list => try lister.finish(outcome),
        .view => if (options.format == .html) try page.finish(outcome) else try viewer.finish(outcome),
        .quiet => {},
    }
    // Only the text forms say so themselves.
    if (counts.stopped_early and options.format != .text and options.mode != .quiet) std.debug.print(
        "mzdiff: stopped after {d} paired spectra (--max-spectra); the result is incomplete\n",
        .{counts.spectra},
    );
    return outcome.status;
}

fn collectRun(arena: std.mem.Allocator, rules: *Rules, facts: *std.ArrayList(Fact), header: *const model.Header) !void {
    var run_node = header.run;
    run_node.children = &.{};
    try compare.collect(arena, rules, facts, run_node, "", header.groups, &.{});
}

// --- Tests ---

test {
    _ = compare;
    _ = html;
    _ = output;
    _ = pair;
    _ = read;
    _ = rules_mod;
}

test "[unit] - [arguments]: each mode, format, and selection combines only where it applies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    const cases = [_]struct { args: []const []const u8, problem: []const u8 }{
        .{ .args = &.{ "--list", "--summary" }, .problem = "--list and --summary are both modes; pick one" },
        .{ .args = &.{ "--json", "--tsv" }, .problem = "--json and --tsv are both formats; pick one" },
        .{ .args = &.{ "-q", "--json" }, .problem = "--quiet prints nothing, so --json does not apply" },
        .{ .args = &.{ "--summary", "--severity", "major" }, .problem = "--summary counts everything, so --severity does not apply" },
        .{ .args = &.{ "--limit", "5" }, .problem = "--limit works with --list or --view" },
        .{ .args = &.{ "--view", "--json" }, .problem = "--view is for people; for programs, use --list --json" },
        .{ .args = &.{"--side-by-side"}, .problem = "--side-by-side works with --view" },
        .{ .args = &.{ "--view", "--width", "120" }, .problem = "--width works with --side-by-side" },
        .{ .args = &.{"--html"}, .problem = "--html works with --view" },
        .{ .args = &.{ "--list", "--examples", "2" }, .problem = "--examples applies to the report only" },
        .{ .args = &.{ "--severity", "ignored" }, .problem = "--severity takes critical, major, or minor, not 'ignored'" },
        .{ .args = &.{ "--set", "MS:1000511" }, .problem = "--set takes KEY=LEVEL, not 'MS:1000511'" },
    };
    for (cases) |case| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena.allocator(), &.{ "mzdiff", "a.mzML", "b.mzML" });
        try args.appendSlice(arena.allocator(), case.args);
        var problem: []const u8 = "";
        try std.testing.expectError(error.Usage, parse(arena.allocator(), args.items, &rules, &problem));
        try std.testing.expectEqualStrings(case.problem, problem);
    }
    var problem: []const u8 = "";
    const options = try parse(
        arena.allocator(),
        &.{ "mzdiff", "--list", "--json", "--key", "MS:1000016", "a.mzML", "b.mzML" },
        &rules,
        &problem,
    );
    try std.testing.expectEqual(output.Mode.list, options.mode);
    try std.testing.expectEqual(output.Format.json, options.format);
    try std.testing.expectEqualStrings("MS:1000016", options.selection.keys[0]);
}
