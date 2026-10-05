//! mzdiff: compares two mzML files by what they mean, fast, in one forward pass over both.
//!
//! A is the reference (usually TRFP's mzML next to the .raw), B the output under test. Spectra
//! pair by scan number (`scan=N` in the native id; by position when either file lacks it), so a
//! spectrum missing on one side is reported once instead of shifting every later comparison;
//! paired spectra must share the native id, and scan numbers must rise. Chromatograms pair by
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
const output = @import("output.zig");
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
    \\  -q, --quiet        nothing; the exit status is the answer
    \\
    \\How to show it (text by default):
    \\  --json             JSON: one document, or JSON Lines with --list
    \\  --tsv              tab-separated rows
    \\  --color WHEN       auto (default), always, or never; text only
    \\
    \\Narrow what is shown (never the verdict):
    \\  --severity LEVEL   critical, major, or minor and above (default minor)
    \\  --key KEY          only this key; repeat for more
    \\  --record ID        only this record, by its native id (--list); repeat for more
    \\  --limit N          print at most N differences (--list)
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
    const options = parse(arena, args, &rules, &problem) catch |err| switch (err) {
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
    const style: output.Style = .{ .color = options.format == .text and useColor(io, init.environ_map, options.color) };
    const interactive = std.Io.File.stdout().isTty(io) catch false;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    const status = run(allocator, io, out, &rules, options, style, interactive) catch |err| {
        out.flush() catch {};
        // A reader that closed the pipe (`| head`) has what it wanted.
        if (err == error.WriteFailed and brokenPipe(&stdout)) return 0;
        std.debug.print("mzdiff: error.{s}\n", .{@errorName(err)});
        return 2;
    };
    out.flush() catch return if (brokenPipe(&stdout)) 0 else 2;
    return if (status == .differs) 1 else 0;
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
    var examples_set = false;
    while (p.i < args.len) : (p.i += 1) {
        const arg = args[p.i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.Help;
        if (modeOf(arg)) |mode| {
            if (mode_flag) |earlier| return p.fail("{s} and {s} are both modes; pick one", .{ earlier, arg });
            mode_flag = arg;
            options.mode = mode;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--tsv")) {
            if (format_flag) |earlier| return p.fail("{s} and {s} are both formats; pick one", .{ earlier, arg });
            format_flag = arg;
            options.format = if (arg[2] == 'j') .json else .tsv;
        } else if (std.mem.eql(u8, arg, "--color")) {
            const text = try p.value(arg);
            options.color = std.meta.stringToEnum(Color, text) orelse return p.fail(
                "--color takes auto, always, or never, not '{s}'",
                .{text},
            );
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
        .report, .list => {},
    }
    if (options.mode != .list) if (list_flag) |flag| return p.fail("{s} works with --list", .{flag});
    if (options.mode != .report and examples_set) return p.fail("--examples applies to the report only", .{});
    options.a = files[0];
    options.b = files[1];
    options.selection.keys = keys.items;
    options.selection.records = records.items;
    return options;
}

fn modeOf(arg: []const u8) ?output.Mode {
    if (std.mem.eql(u8, arg, "--summary")) return .summary;
    if (std.mem.eql(u8, arg, "--list")) return .list;
    if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) return .quiet;
    return null;
}

// One input: its file, reader, and header. The header is read on the main thread; records are
// read by `produce` on the side's own thread. Never moved after `open`: the reader points into
// `input`.
const Side = struct {
    path: []const u8,
    file: std.Io.File,
    buffer: [256 * 1024]u8,
    input: std.Io.File.Reader,
    reader: mzml.StreamReader,
    decoded: mzml.DecodedArrays,
    header: *const model.Header,
    software: []const u8 = "",
    rules: Rules,
    slots: [QUEUE_DEPTH]Item = undefined,
    queue: std.Io.Queue(Item) = undefined,
    // Arenas handed back by the comparing thread for reuse, so memory is allocated and freed on
    // the reading thread instead of piling up in another thread's allocator cache.
    spare_slots: [QUEUE_DEPTH + 4]*std.heap.ArenaAllocator = undefined,
    spare: std.Io.Queue(*std.heap.ArenaAllocator) = undefined,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    failure: ?anyerror = null,
    spectra: usize = 0,
    chromatograms: usize = 0,
    // Each instrument configuration's component facts by id, for the scans that refer to it.
    configurations: std.StringHashMapUnmanaged([]const Fact) = .empty,
    default_configuration: ?[]const u8 = null,
    // What is wrong with the indexed wrapper's tail, or null.
    trailer: ?[]const u8 = null,
    configuration_arena: std.heap.ArenaAllocator = undefined,

    fn open(self: *Side, allocator: std.mem.Allocator, io: std.Io, path: []const u8, rules: *const Rules) !void {
        self.path = path;
        self.failure = null;
        self.spectra = 0;
        self.chromatograms = 0;
        self.file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer self.file.close(io);
        self.input = self.file.reader(io, &self.buffer);
        self.reader = try mzml.StreamReader.init(allocator, &self.input.interface, .{});
        errdefer self.reader.deinit();
        self.decoded = mzml.DecodedArrays.init(allocator, .{});
        errdefer self.decoded.deinit();
        self.header = self.reader.readHeader() catch |err| return self.explain(err);
        self.software = softwareName(self.header.document);
        self.trailer = if (self.header.indexed) try checkTrailer(self.file, io) else null;
        self.rules = try rules.clone();
        errdefer self.rules.deinit();
        self.configuration_arena = .init(allocator);
        errdefer self.configuration_arena.deinit();
        self.configurations = .empty;
        try self.readConfigurations();
        self.queue = .init(&self.slots);
        self.spare = .init(&self.spare_slots);
        self.allocator = allocator;
        self.io = io;
    }

    // An arena for the next record: a recycled one when available.
    fn arena(self: *Side) !*std.heap.ArenaAllocator {
        var one: [1]*std.heap.ArenaAllocator = undefined;
        if ((self.spare.get(self.io, &one, 0) catch 0) == 1) return one[0];
        const fresh = try self.allocator.create(std.heap.ArenaAllocator);
        fresh.* = .init(self.allocator);
        return fresh;
    }

    // Takes back a record's arena; frees it when the spare queue is full or closed.
    fn recycle(self: *Side, arena_state: *std.heap.ArenaAllocator) void {
        _ = arena_state.reset(.retain_capacity);
        const handed = self.spare.put(self.io, &.{arena_state}, 0) catch 0;
        if (handed == 0) destroyArena(self.allocator, arena_state);
    }

    fn freeSpares(self: *Side) void {
        self.spare.close(self.io);
        var one: [1]*std.heap.ArenaAllocator = undefined;
        while ((self.spare.get(self.io, &one, 1) catch 0) == 1) destroyArena(self.allocator, one[0]);
    }

    // Collects each instrument configuration's components (source, analyzer, detector) as facts
    // under the scan path, so a scan that names another configuration differs where it matters.
    fn readConfigurations(self: *Side) !void {
        const store = self.configuration_arena.allocator();
        self.default_configuration = self.header.run.attribute("defaultInstrumentConfigurationRef");
        const list = self.header.document.child(.instrument_configuration_list) orelse return;
        for (list.children) |configuration| {
            if (configuration.kind != .instrument_configuration) continue;
            const id = configuration.attribute("id") orelse continue;
            var facts: std.ArrayList(Fact) = .empty;
            const components = configuration.child(.component_list);
            if (components) |node| try compare.collect(store, &self.rules, &facts, node, CONFIGURATION_PATH, self.header.groups, &.{});
            try self.configurations.put(store, id, facts.items);
        }
    }

    fn close(self: *Side, io: std.Io) void {
        self.configuration_arena.deinit();
        self.freeSpares();
        self.rules.deinit();
        self.decoded.deinit();
        self.reader.deinit();
        self.file.close(io);
    }

    fn explain(self: *Side, err: anyerror) anyerror {
        if (self.reader.diagnostic()) |diagnostic| std.debug.print("mzdiff: {s}: {f}\n", .{ self.path, diagnostic });
        return err;
    }
};

// Records in flight per side; bounds memory to this many decoded records each.
const QUEUE_DEPTH = 16;

// One record, read and reduced to facts and arrays on its side's thread, owning its memory.
const Item = struct {
    kind: model.Kind,
    id: []const u8,
    scan: ?u64,
    // The chromatogram type term (TIC, base peak, SRM, ...), or "" without one.
    type: []const u8,
    facts: []Fact,
    elements: []const compare.Element,
    arrays: []const compare.Role,
    arena: *std.heap.ArenaAllocator,
    owner: *Side,
    used: bool = false,
    // Pairing by scan number, this spectrum has none, or one not above the previous spectrum's.
    out_of_order: bool = false,

    fn free(self: *const Item, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.owner.recycle(self.arena);
    }
};

fn destroyArena(allocator: std.mem.Allocator, arena_state: *std.heap.ArenaAllocator) void {
    arena_state.deinit();
    allocator.destroy(arena_state);
}

// Reads the side's records into owned items and queues them; closes the queue at the end. A read
// failure is kept in `side.failure`.
fn produce(allocator: std.mem.Allocator, io: std.Io, side: *Side) void {
    defer side.queue.close(io);
    while (true) {
        const record = side.reader.nextDecodedRecord(&side.decoded) catch |err| {
            side.failure = side.explain(err);
            return;
        } orelse return;
        const item = makeItem(side, record) catch |err| {
            side.failure = err;
            return;
        };
        side.queue.putOne(io, item) catch {
            item.free(allocator);
            return;
        };
    }
}

const SCAN_PATH = "spectrum/scanList/scan";
const CONFIGURATION_PATH = SCAN_PATH ++ "/instrumentConfiguration";

fn makeItem(side: *Side, record: model.Record) !Item {
    const rules = &side.rules;
    const header = side.header;
    const arena_state = try side.arena();
    errdefer destroyArena(side.allocator, arena_state);
    const arena = arena_state.allocator();
    var facts: std.ArrayList(Fact) = .empty;
    var elements: std.ArrayList(compare.Element) = .empty;
    const collector: compare.Collector = .{
        .arena = arena,
        .rules = rules,
        .facts = &facts,
        .elements = &elements,
        .groups = header.groups,
    };
    try collector.add(record.node, "", compare.NO_PARENT);
    // Facts borrow from the reader's record; copy them before it moves on.
    var type_key: []const u8 = "";
    for (facts.items) |*fact| {
        fact.* = try compare.ownFact(arena, fact.*);
        const on_chromatogram = record.node.kind == .chromatogram and std.mem.eql(u8, fact.path, "chromatogram");
        if (on_chromatogram and type_key.len == 0 and rules.isA(fact.key, "MS:1000626"))
            type_key = fact.key;
    }
    for (elements.items) |*element| element.path = try arena.dupe(u8, element.path);
    // Each scan's instrument configuration, named or the run's default, as component facts. The
    // configuration facts live as long as the side; only the element they belong to is new.
    for (elements.items, 0..) |element, position| {
        if (!std.mem.eql(u8, element.path, SCAN_PATH)) continue;
        const scan = nthScan(record.node, scanOrdinal(elements.items, position)) orelse continue;
        const ref = scan.attribute("instrumentConfigurationRef") orelse side.default_configuration orelse continue;
        const components = side.configurations.get(ref) orelse {
            try facts.append(arena, compare.makeFact(SCAN_PATH, "instrumentConfiguration", "", ref, "", @intCast(position)));
            continue;
        };
        for (components) |component| {
            var fact = component;
            fact.element = @intCast(position);
            try facts.append(arena, fact);
        }
    }
    const id = try arena.dupe(u8, record.id);
    return .{
        .kind = record.node.kind,
        .id = id,
        .scan = scanNumber(id),
        .type = type_key,
        .facts = facts.items,
        .elements = elements.items,
        .arrays = try compare.roles(arena, record, header.groups, &side.decoded, true),
        .arena = arena_state,
        .owner = side,
    };
}

// Which scan (0 for the first) the element at `position` is among the record's scans.
fn scanOrdinal(elements: []const compare.Element, position: usize) usize {
    var count: usize = 0;
    for (elements[0..position]) |element| count += @intFromBool(std.mem.eql(u8, element.path, SCAN_PATH));
    return count;
}

fn nthScan(spectrum: model.Node, ordinal: usize) ?model.Node {
    const list = spectrum.child(.scan_list) orelse return null;
    var count: usize = 0;
    for (list.children) |child| if (child.kind == .scan) {
        if (count == ordinal) return child;
        count += 1;
    };
    return null;
}

// The reader stops at </mzML>, so the indexed wrapper's tail is checked here: it must end with
// indexListOffset, fileChecksum, and </indexedmzML>, and the offset must point at <indexList
// (or the whitespace before it). Returns what is wrong, or null. The offsets inside the index
// and the checksum are left to mzValidate.
fn checkTrailer(file: std.Io.File, io: std.Io) !?[]const u8 {
    const size = try file.length(io);
    var tail_buffer: [4096]u8 = undefined;
    const start = size -| tail_buffer.len;
    const tail = tail_buffer[0..try file.readPositionalAll(io, tail_buffer[0..@intCast(size - start)], start)];
    const trimmed = std.mem.trimEnd(u8, tail, " \t\r\n");
    const offset_text = between(trimmed, "<indexListOffset>", "</indexListOffset>");
    const checksum = between(trimmed, "<fileChecksum>", "</fileChecksum>");
    if (!std.mem.endsWith(u8, trimmed, "</indexedmzML>") or offset_text == null or checksum == null)
        return "no index trailer";
    const offset = std.fmt.parseInt(u64, std.mem.trim(u8, offset_text.?, " \t\r\n"), 10) catch return "offset is not a number";
    // TRFP's offsets point at the indentation before the element, which readers accept.
    var head_buffer: [256]u8 = undefined;
    const got = if (offset < size) try file.readPositionalAll(io, &head_buffer, offset) else 0;
    const head = std.mem.trimStart(u8, head_buffer[0..got], " \t\r\n");
    if (!std.mem.startsWith(u8, head, "<indexList")) return "offset misses <indexList>";
    return null;
}

fn between(text: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOf(u8, text, open) orelse return null;
    const end = std.mem.indexOfPos(u8, text, at + open.len, close) orelse return null;
    return text[at + open.len .. end];
}

fn softwareName(document: model.Node) []const u8 {
    const list = document.child(.software_list) orelse return "";
    if (list.children.len == 0) return "";
    return list.children[0].attribute("id") orelse "";
}

fn scanNumber(id: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, id, "scan=") orelse return null;
    var end = at + 5;
    while (end < id.len and std.ascii.isDigit(id[end])) end += 1;
    return std.fmt.parseInt(u64, id[at + 5 .. end], 10) catch null;
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

// The consumer's view of one side: the item at hand, pulled from the side's queue.
const Stream = struct {
    side: *Side,
    io: std.Io,
    current: ?Item = null,
    position: usize = 0,
    by_scan: bool = false,
    previous_scan: ?u64 = null,

    fn advance(self: *Stream) void {
        self.current = self.side.queue.getOne(self.io) catch null;
        if (self.current) |*item| switch (item.kind) {
            .spectrum => {
                self.side.spectra += 1;
                self.position += 1;
                if (self.by_scan) {
                    const previous = self.previous_scan;
                    item.out_of_order = item.scan == null or (previous != null and item.scan.? <= previous.?);
                    if (item.scan) |scan| self.previous_scan = scan;
                }
            },
            .chromatogram => self.side.chromatograms += 1,
            else => {},
        };
    }

    // Hands over the current item; the caller frees it.
    fn take(self: *Stream) Item {
        const item = self.current.?;
        self.current = null;
        return item;
    }

    fn isSpectrum(self: *const Stream) bool {
        return if (self.current) |item| item.kind == .spectrum else false;
    }

    fn key(self: *const Stream, by_scan: bool) u64 {
        return if (by_scan) self.current.?.scan orelse self.position else self.position;
    }
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
    const sides = try allocator.create([2]Side);
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
    var future_a = try io.concurrent(produce, .{ allocator, io, side_a });
    var future_b = io.concurrent(produce, .{ allocator, io, side_b }) catch |err| {
        side_a.queue.close(io);
        drain(allocator, io, side_a);
        future_a.await(io);
        return err;
    };
    var a: Stream = .{ .side = side_a, .io = io };
    var b: Stream = .{ .side = side_b, .io = io };
    var kept: std.ArrayList(Item) = .empty;
    var kept_b: std.ArrayList(Item) = .empty;
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var paired: usize = 0;
    var paired_chromatograms: usize = 0;
    var stopped_early = false;

    const consumed: anyerror!void = consume: {
        a.advance();
        b.advance();
        const by_scan = if (a.current != null and b.current != null) a.current.?.scan != null and b.current.?.scan != null else false;
        a.by_scan = by_scan;
        b.by_scan = by_scan;
        a.previous_scan = if (a.current) |item| item.scan else null;
        b.previous_scan = if (b.current) |item| item.scan else null;
        while (a.isSpectrum() and b.isSpectrum()) {
            if (options.max_spectra) |limit| if (paired >= limit) {
                stopped_early = true;
                break;
            };
            const ka = a.key(by_scan);
            const kb = b.key(by_scan);
            report.record += 1;
            if (ka == kb) {
                const x = a.take();
                const y = b.take();
                defer x.free(allocator);
                defer y.free(allocator);
                _ = scratch_state.reset(.retain_capacity);
                checkOrder(&report, x, true) catch |err| break :consume err;
                checkOrder(&report, y, false) catch |err| break :consume err;
                if (by_scan and !std.mem.eql(u8, x.id, y.id))
                    report.add(null, .id_mismatch, "spectrum", "id", "native id", x.id, x.id, y.id) catch |err| break :consume err;
                compare.diffFacts(&report, x.id, x.facts, y.facts) catch |err| break :consume err;
                compare.diffGrouping(&report, scratch, x.id, x.facts, x.elements, y.facts, y.elements) catch |err| break :consume err;
                compare.compareArrays(&report, scratch, x.id, "spectrum", x.arrays, y.arrays) catch |err| break :consume err;
                paired += 1;
                a.advance();
                b.advance();
            } else if (ka < kb) {
                const x = a.take();
                defer x.free(allocator);
                checkOrder(&report, x, true) catch |err| break :consume err;
                report.add(.critical, .record_missing, "spectrum", "@id", "spectrum", x.id, x.id, "") catch |err| break :consume err;
                a.advance();
            } else {
                const y = b.take();
                defer y.free(allocator);
                checkOrder(&report, y, false) catch |err| break :consume err;
                report.add(.critical, .record_extra, "spectrum", "@id", "spectrum", y.id, "", y.id) catch |err| break :consume err;
                b.advance();
            }
        }
        if (stopped_early) break :consume {};
        // What is left: unpaired spectra, then chromatograms, which are few and paired by type.
        inline for (.{ .{ &a, &kept, Kind.record_missing }, .{ &b, &kept_b, Kind.record_extra } }) |entry| {
            const stream = entry[0];
            while (stream.current != null) {
                const item = stream.take();
                if (item.kind == .chromatogram) {
                    entry[1].append(allocator, item) catch |err| {
                        item.free(allocator);
                        break :consume err;
                    };
                } else {
                    defer item.free(allocator);
                    report.record += 1;
                    const in_a = entry[2] == .record_missing;
                    checkOrder(&report, item, in_a) catch |err| break :consume err;
                    report.add(
                        .critical,
                        entry[2],
                        "spectrum",
                        "@id",
                        "spectrum",
                        item.id,
                        if (in_a) item.id else "",
                        if (in_a) "" else item.id,
                    ) catch |err| break :consume err;
                }
                stream.advance();
            }
        }
        paired_chromatograms = compareChromatograms(&report, scratch, kept.items, kept_b.items) catch |err| break :consume err;
    };

    // Stop the readers (a no-op when they finished), free what they queued, and wait for them.
    side_a.queue.close(io);
    side_b.queue.close(io);
    if (a.current) |item| item.free(allocator);
    if (b.current) |item| item.free(allocator);
    drain(allocator, io, side_a);
    drain(allocator, io, side_b);
    future_a.await(io);
    future_b.await(io);
    for (kept.items) |item| item.free(allocator);
    for (kept_b.items) |item| item.free(allocator);
    kept.deinit(allocator);
    kept_b.deinit(allocator);
    try consumed;
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
        .paired_spectra = paired,
        .paired_chromatograms = paired_chromatograms,
        .completion = if (stopped_early) .incomplete else .complete,
        .status = output.statusOf(classes, options.fail_on),
        .fail_on = options.fail_on,
        .totals = totals,
        .seconds = if (interactive) @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s else null,
    };
    switch (options.mode) {
        .report => try output.writeReport(out, options.format, style, outcome, classes, options.selection),
        .summary => try output.writeSummary(out, options.format, style, outcome),
        .list => try lister.finish(outcome),
        .quiet => {},
    }
    // Only the text forms say so themselves.
    if (stopped_early and options.format != .text and options.mode != .quiet) std.debug.print(
        "mzdiff: stopped after {d} paired spectra (--max-spectra); the result is incomplete\n",
        .{paired},
    );
    return outcome.status;
}

// Files a spectrum that breaks the scan order pairing relies on; the pairs after it may be off.
fn checkOrder(report: *Report, item: Item, in_a: bool) !void {
    if (!item.out_of_order) return;
    const text = if (item.scan == null) "no scan number" else "scan number not above the previous";
    try report.add(.critical, .order, "spectrum", "scan", "scan order", item.id, if (in_a) text else "", if (in_a) "" else text);
}

fn drain(allocator: std.mem.Allocator, io: std.Io, side: *Side) void {
    while (side.queue.getOne(io)) |item| item.free(allocator) else |_| {}
}

fn collectRun(arena: std.mem.Allocator, rules: *Rules, facts: *std.ArrayList(Fact), header: *const model.Header) !void {
    var run_node = header.run;
    run_node.children = &.{};
    try compare.collect(arena, rules, facts, run_node, "", header.groups, &.{});
}

// Pairs chromatograms by type and id, then by type alone (TIC with TIC whatever its id), then by
// id alone, so a list of same-typed SRM traces pairs by id rather than by position. Returns how
// many pairs it compared.
fn compareChromatograms(report: *Report, scratch: std.mem.Allocator, a: []Item, b: []Item) !usize {
    var paired: usize = 0;
    const partner = try scratch.alloc(?*Item, a.len);
    @memset(partner, null);
    inline for (.{ Match.type_and_id, Match.type_only, Match.id_only }) |how| {
        for (a, partner) |*x, *slot| {
            if (slot.* != null) continue;
            slot.* = match(b, x, how);
            if (slot.*) |y| y.used = true;
        }
    }
    for (a, partner) |*x, slot| {
        report.record += 1;
        const y = slot orelse {
            try report.add(.major, .record_missing, "chromatogram", "@id", "chromatogram", x.id, x.id, "");
            continue;
        };
        try compare.diffFacts(report, x.id, x.facts, y.facts);
        try compare.diffGrouping(report, scratch, x.id, x.facts, x.elements, y.facts, y.elements);
        try compare.compareArrays(report, scratch, x.id, "chromatogram", x.arrays, y.arrays);
        paired += 1;
    }
    for (b) |y| {
        if (y.used) continue;
        report.record += 1;
        try report.add(.major, .record_extra, "chromatogram", "@id", "chromatogram", y.id, "", y.id);
    }
    return paired;
}

const Match = enum { type_and_id, type_only, id_only };

fn match(list: []Item, x: *const Item, how: Match) ?*Item {
    for (list) |*y| {
        if (y.used) continue;
        const same_type = x.type.len != 0 and std.mem.eql(u8, y.type, x.type);
        const same_id = std.mem.eql(u8, y.id, x.id);
        const hit = switch (how) {
            .type_and_id => same_type and same_id,
            .type_only => same_type,
            .id_only => same_id,
        };
        if (hit) return y;
    }
    return null;
}

// --- Tests ---

test {
    _ = compare;
    _ = output;
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
        .{ .args = &.{ "--limit", "5" }, .problem = "--limit works with --list" },
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

test "[unit] - [pairing]: scan numbers come from the native id" {
    try std.testing.expectEqual(@as(?u64, 42), scanNumber("controllerType=0 controllerNumber=1 scan=42"));
    try std.testing.expectEqual(@as(?u64, null), scanNumber("index=3"));
}
