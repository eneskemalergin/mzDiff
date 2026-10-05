//! Renders a comparison for people and for programs: the report (difference classes with
//! examples), the summary (the verdict and its counts), and the list (every difference, streamed
//! as it is found), each as text, TSV, or JSON.
//!
//! What is shown never changes the verdict: `Selection` narrows the report's classes and the
//! list's lines, while `Outcome` (status, completion, totals) always describes the whole
//! comparison. JSON is schema 1: the report and the summary are one document each, the list is
//! JSON Lines ending with a summary line. Text may carry ANSI color; TSV and JSON never do.

const std = @import("std");

const compare = @import("compare.zig");
const rules_mod = @import("rules.zig");

const Class = compare.Class;
const Difference = compare.Difference;
const Severity = rules_mod.Severity;

pub const Mode = enum { report, summary, list, quiet };

pub const Format = enum { text, tsv, json };

/// `same`: no difference at all; `tolerated`: none at or above `--fail-on`; `differs`: some.
pub const Status = enum { same, tolerated, differs };

/// `incomplete` when `--max-spectra` stopped the comparison before the end of either file.
pub const Completion = enum { complete, incomplete };

pub const Side = struct {
    path: []const u8,
    software: []const u8,
    spectra: usize,
    chromatograms: usize,
};

/// The whole comparison, whatever is selected for display.
pub const Outcome = struct {
    a: Side,
    b: Side,
    paired_spectra: usize,
    paired_chromatograms: usize,
    completion: Completion,
    status: Status,
    fail_on: Severity,
    /// Difference classes per severity: critical, major, minor.
    totals: [3]usize,
    /// Wall time, shown only to an interactive reader.
    seconds: ?f64,
};

/// What to show; never the verdict.
pub const Selection = struct {
    severity: Severity = .minor,
    keys: []const []const u8 = &.{},
    records: []const []const u8 = &.{},
    limit: ?usize = null,

    pub fn shows(self: Selection, severity: Severity, key: []const u8, record: ?[]const u8) bool {
        if (@intFromEnum(severity) > @intFromEnum(self.severity)) return false;
        if (self.keys.len != 0 and !contains(self.keys, key)) return false;
        if (record) |id| if (self.records.len != 0 and !contains(self.records, id)) return false;
        return true;
    }
};

pub const Style = struct {
    color: bool = false,

    fn severity(self: Style, out: *std.Io.Writer, level: Severity, width: usize) !void {
        const label = level.label();
        if (self.color) try out.writeAll(switch (level) {
            .critical => "\x1b[1;31m",
            .major => "\x1b[33m",
            .minor, .ignored => "\x1b[2m",
        });
        try out.writeAll(label);
        if (self.color) try out.writeAll("\x1b[0m");
        try out.splatByteAll(' ', width -| label.len);
    }

    fn status(self: Style, out: *std.Io.Writer, word: Status) !void {
        if (self.color) try out.writeAll(switch (word) {
            .same => "\x1b[32m",
            .tolerated => "\x1b[36m",
            .differs => "\x1b[1;31m",
        });
        try out.writeAll(@tagName(word));
        if (self.color) try out.writeAll("\x1b[0m");
    }
};

/// The status word: from the classes found and `--fail-on`, never from the selection.
pub fn statusOf(classes: []const *Class, fail_on: Severity) Status {
    if (classes.len == 0) return .same;
    for (classes) |class| if (@intFromEnum(class.severity) <= @intFromEnum(fail_on)) return .differs;
    return .tolerated;
}

pub fn writeReport(
    out: *std.Io.Writer,
    format: Format,
    style: Style,
    outcome: Outcome,
    classes: []const *Class,
    selection: Selection,
) !void {
    switch (format) {
        .tsv => {
            try out.writeAll("severity\tkind\trecords\tpath\tkey\tname\texample\ta\tb\n");
            for (classes) |class| {
                if (!selection.shows(class.severity, class.key, null)) continue;
                const example: compare.Example = if (class.examples.items.len != 0)
                    class.examples.items[0]
                else
                    .{ .id = "", .a = "", .b = "" };
                try out.print("{s}\t{s}\t{d}", .{ @tagName(class.severity), @tagName(class.kind), class.records });
                for ([_][]const u8{ class.path, class.key, class.name, example.id, example.a, example.b }) |field| {
                    try out.writeByte('\t');
                    try writeTsvField(out, field);
                }
                try out.writeByte('\n');
            }
        },
        .json => {
            try out.writeAll("{\n");
            try writeOutcomeJson(out, outcome, "  ");
            try out.writeAll(",\n  \"classes\": [");
            var first = true;
            for (classes) |class| {
                if (!selection.shows(class.severity, class.key, null)) continue;
                try out.writeAll(if (first) "\n    {" else ",\n    {");
                first = false;
                try out.print("\"severity\": \"{s}\", \"kind\": \"{s}\", \"label\": ", .{ @tagName(class.severity), @tagName(class.kind) });
                try writeJsonString(out, class.kind.label());
                try out.writeAll(", \"path\": ");
                try writeJsonString(out, class.path);
                try out.writeAll(", \"key\": ");
                try writeJsonString(out, class.key);
                try out.writeAll(", \"name\": ");
                try writeJsonString(out, class.name);
                try out.print(", \"records\": {d}, \"examples\": [", .{class.records});
                for (class.examples.items, 0..) |example, i| {
                    if (i != 0) try out.writeAll(", ");
                    try out.writeAll("{\"record\": ");
                    try writeJsonString(out, example.id);
                    try out.writeAll(", \"a\": ");
                    try writeJsonString(out, example.a);
                    try out.writeAll(", \"b\": ");
                    try writeJsonString(out, example.b);
                    try out.writeByte('}');
                }
                try out.writeAll("]}");
            }
            try out.writeAll(if (first) "]\n}\n" else "\n  ]\n}\n");
        },
        .text => {
            try writeHeadText(out, style, outcome);
            var shown: usize = 0;
            var current: ?Severity = null;
            for (classes) |class| {
                if (!selection.shows(class.severity, class.key, null)) continue;
                shown += 1;
                if (current != class.severity) {
                    current = class.severity;
                    try out.writeByte('\n');
                    try style.severity(out, class.severity, 0);
                    try out.writeByte('\n');
                }
                try out.print("  {d:>8}  {s:<26} ", .{ class.records, class.kind.label() });
                try writeShortPath(out, class.path);
                try out.print("  {s}", .{class.key});
                if (class.name.len != 0) try out.print(" ({s})", .{class.name});
                try out.writeByte('\n');
                for (class.examples.items) |example| {
                    try out.print("            {s}", .{example.id});
                    if (example.a.len != 0 or example.b.len != 0) try out.print(
                        "  A: {s}  B: {s}",
                        .{ orNone(example.a), orNone(example.b) },
                    );
                    try out.writeByte('\n');
                }
            }
            if (shown < classes.len) try out.print("\n{d} of {d} classes shown (--severity, --key)\n", .{ shown, classes.len });
        },
    }
}

pub fn writeSummary(out: *std.Io.Writer, format: Format, style: Style, outcome: Outcome) !void {
    switch (format) {
        .text => try writeSummaryLine(out, style, outcome),
        .tsv => {
            try out.writeAll("completion\tstatus\tfail_on\tcritical\tmajor\tminor\ta_spectra\tb_spectra\tpaired_spectra\t" ++
                "a_chromatograms\tb_chromatograms\tpaired_chromatograms\n");
            try out.print("{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                @tagName(outcome.completion), @tagName(outcome.status), @tagName(outcome.fail_on),
                outcome.totals[0],            outcome.totals[1],        outcome.totals[2],
                outcome.a.spectra,            outcome.b.spectra,        outcome.paired_spectra,
                outcome.a.chromatograms,      outcome.b.chromatograms,  outcome.paired_chromatograms,
            });
        },
        .json => {
            try out.writeAll("{\n");
            try writeOutcomeJson(out, outcome, "  ");
            try out.writeAll("\n}\n");
        },
    }
}

/// Streams every difference as it is found, in the chosen format. Holds nothing per difference.
pub const Lister = struct {
    out: *std.Io.Writer,
    format: Format,
    style: Style,
    selection: Selection,
    shown: usize = 0,
    hidden: usize = 0,
    last_record: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    started: bool = false,

    pub fn deinit(self: *Lister) void {
        self.last_record.deinit(self.allocator);
    }

    pub fn sink(self: *Lister) compare.Sink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, difference: Difference) anyerror!void {
        const self: *Lister = @ptrCast(@alignCast(context));
        if (!self.selection.shows(difference.severity, difference.key, difference.record)) return;
        if (self.selection.limit) |limit| if (self.shown >= limit) {
            self.hidden += 1;
            return;
        };
        self.shown += 1;
        switch (self.format) {
            .text => try self.text(difference),
            .tsv => {
                if (!self.started) try self.out.writeAll("record\tseverity\tkind\tpath\tkey\tname\ta\tb\n");
                try writeTsvField(self.out, difference.record);
                try self.out.print("\t{s}\t{s}", .{ @tagName(difference.severity), @tagName(difference.kind) });
                for ([_][]const u8{ difference.path, difference.key, difference.name }) |field| {
                    try self.out.writeByte('\t');
                    try writeTsvField(self.out, field);
                }
                try self.out.writeByte('\t');
                try writeTsvField(self.out, difference.a);
                try self.out.writeByte('\t');
                try writeTsvField(self.out, difference.b);
                try self.out.writeByte('\n');
            },
            .json => {
                try self.out.writeAll("{\"type\": \"difference\", \"record\": ");
                try writeJsonString(self.out, difference.record);
                try self.out.print(
                    ", \"severity\": \"{s}\", \"kind\": \"{s}\", \"path\": ",
                    .{ @tagName(difference.severity), @tagName(difference.kind) },
                );
                try writeJsonString(self.out, difference.path);
                try self.out.writeAll(", \"key\": ");
                try writeJsonString(self.out, difference.key);
                try self.out.writeAll(", \"name\": ");
                try writeJsonString(self.out, difference.name);
                try self.out.writeAll(", \"a\": ");
                try writeJsonString(self.out, difference.a);
                try self.out.writeAll(", \"b\": ");
                try writeJsonString(self.out, difference.b);
                if (difference.array) |array| {
                    try self.out.print(
                        ", \"values\": {d}, \"differing\": {d}, \"largest\": {{\"index\": {d}, \"a\": ",
                        .{ array.values, array.differing, array.largest },
                    );
                    try writeJsonNumber(self.out, array.largest_a);
                    try self.out.writeAll(", \"b\": ");
                    try writeJsonNumber(self.out, array.largest_b);
                    try self.out.writeByte('}');
                }
                try self.out.writeAll("}\n");
            },
        }
        self.started = true;
    }

    fn text(self: *Lister, difference: Difference) !void {
        const out = self.out;
        if (!std.mem.eql(u8, self.last_record.items, difference.record)) {
            self.last_record.clearRetainingCapacity();
            try self.last_record.appendSlice(self.allocator, difference.record);
            try out.print("{s}\n", .{difference.record});
        }
        try out.writeAll("  ");
        try self.style.severity(out, difference.severity, 9);
        try out.print("{s:<26} ", .{difference.kind.label()});
        try writeShortPath(out, difference.path);
        try out.print("  {s}", .{difference.key});
        if (difference.name.len != 0) try out.print(" ({s})", .{difference.name});
        if (difference.a.len != 0 or difference.b.len != 0) try out.print(
            "  A: {s}  B: {s}",
            .{ orNone(difference.a), orNone(difference.b) },
        );
        if (difference.array) |array| {
            try out.print("  ({d} of {d} values differ", .{ array.differing, array.values });
            if (array.largest != array.shown) try out.print(
                "; largest at [{d}]: {d} against {d}",
                .{ array.largest, array.largest_a, array.largest_b },
            );
            try out.writeByte(')');
        }
        try out.writeByte('\n');
    }

    /// Ends the list: the summary line or object, and how many lines `--limit` held back.
    pub fn finish(self: *Lister, outcome: Outcome) !void {
        switch (self.format) {
            .text => {
                if (self.shown != 0) try self.out.writeByte('\n');
                if (self.hidden != 0) try self.out.print("{d} more differences not shown (--limit)\n", .{self.hidden});
                try writeSummaryLine(self.out, self.style, outcome);
            },
            .tsv => if (!self.started) try self.out.writeAll("record\tseverity\tkind\tpath\tkey\tname\ta\tb\n"),
            .json => {
                try self.out.writeAll("{\"type\": \"summary\", ");
                try writeOutcomeJson(self.out, outcome, "");
                try self.out.print(", \"shown\": {d}, \"not_shown\": {d}}}\n", .{ self.shown, self.hidden });
            },
        }
    }
};

fn writeHeadText(out: *std.Io.Writer, style: Style, outcome: Outcome) !void {
    try out.print("A  {s}  ({s})\nB  {s}  ({s})\n", .{ outcome.a.path, outcome.a.software, outcome.b.path, outcome.b.software });
    try out.print("spectra        A {d}  B {d}  paired {d}{s}\n", .{
        outcome.a.spectra,
        outcome.b.spectra,
        outcome.paired_spectra,
        if (outcome.completion == .incomplete) "  (stopped early)" else "",
    });
    try out.print(
        "chromatograms  A {d}  B {d}  paired {d}\n",
        .{ outcome.a.chromatograms, outcome.b.chromatograms, outcome.paired_chromatograms },
    );
    if (outcome.seconds) |seconds| try out.print("time           {d:.2} s\n", .{seconds});
    try out.writeAll("result         ");
    try style.status(out, outcome.status);
    if (outcome.status == .same) {
        try out.writeAll(" in everything compared\n");
    } else {
        try out.print(
            ": {d} critical, {d} major, {d} minor difference classes\n",
            .{ outcome.totals[0], outcome.totals[1], outcome.totals[2] },
        );
    }
}

// "complete: differs | classes: critical 1, major 4, minor 4 | spectra: A 2103, B 2103, paired 2103 | ..."
fn writeSummaryLine(out: *std.Io.Writer, style: Style, outcome: Outcome) !void {
    try out.print("{s}: ", .{@tagName(outcome.completion)});
    try style.status(out, outcome.status);
    try out.print(" | classes: critical {d}, major {d}, minor {d}" ++
        " | spectra: A {d}, B {d}, paired {d} | chromatograms: A {d}, B {d}, paired {d}\n", .{
        outcome.totals[0],       outcome.totals[1],       outcome.totals[2],
        outcome.a.spectra,       outcome.b.spectra,       outcome.paired_spectra,
        outcome.a.chromatograms, outcome.b.chromatograms, outcome.paired_chromatograms,
    });
}

// The outcome's fields, without the enclosing braces, each line starting with `indent` (an empty
// indent writes one line).
fn writeOutcomeJson(out: *std.Io.Writer, outcome: Outcome, indent: []const u8) !void {
    const sep = if (indent.len == 0) ", " else ",\n";
    try out.print("{s}\"schema_version\": 1{s}", .{ indent, sep });
    inline for (.{ .{ "a", outcome.a }, .{ "b", outcome.b } }) |entry| {
        try out.print("{s}\"{s}\": {{\"path\": ", .{ indent, entry[0] });
        try writeJsonString(out, entry[1].path);
        try out.writeAll(", \"software\": ");
        try writeJsonString(out, entry[1].software);
        try out.print(", \"spectra\": {d}, \"chromatograms\": {d}}}{s}", .{ entry[1].spectra, entry[1].chromatograms, sep });
    }
    try out.print(
        "{s}\"paired\": {{\"spectra\": {d}, \"chromatograms\": {d}}}{s}",
        .{ indent, outcome.paired_spectra, outcome.paired_chromatograms, sep },
    );
    try out.print("{s}\"completion\": \"{s}\"{s}", .{ indent, @tagName(outcome.completion), sep });
    try out.print("{s}\"status\": \"{s}\"{s}", .{ indent, @tagName(outcome.status), sep });
    try out.print("{s}\"fail_on\": \"{s}\"{s}", .{ indent, @tagName(outcome.fail_on), sep });
    try out.print(
        "{s}\"totals\": {{\"critical\": {d}, \"major\": {d}, \"minor\": {d}}}",
        .{ indent, outcome.totals[0], outcome.totals[1], outcome.totals[2] },
    );
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}

fn orNone(text: []const u8) []const u8 {
    return if (text.len == 0) "-" else text;
}

// Drops the list levels, which add length but no meaning: spectrum/scanList/scan -> spectrum/scan.
fn writeShortPath(out: *std.Io.Writer, path: []const u8) !void {
    var parts = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (parts.next()) |part| {
        if (std.mem.endsWith(u8, part, "List") and parts.peek() != null) continue;
        if (!first) try out.writeByte('/');
        try out.writeAll(part);
        first = false;
    }
}

// A TSV field with tabs and line breaks escaped, so each row stays one line.
fn writeTsvField(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '\t' => try out.writeAll("\\t"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\\' => try out.writeAll("\\\\"),
        else => try out.writeByte(c),
    };
}

fn writeJsonString(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try out.print("\\u{x:0>4}", .{c}),
        else => try out.writeByte(c),
    };
    try out.writeByte('"');
}

// JSON has no NaN or infinity; those become strings.
fn writeJsonNumber(out: *std.Io.Writer, value: f64) !void {
    if (std.math.isFinite(value)) return out.print("{d}", .{value});
    try writeJsonString(out, if (std.math.isNan(value)) "NaN" else if (value > 0) "Infinity" else "-Infinity");
}

// --- Tests ---

test "[unit] - [output]: the status word comes from the classes and --fail-on" {
    var minor: Class = .{ .severity = .minor, .kind = .value, .path = "", .key = "", .name = "" };
    var major: Class = .{ .severity = .major, .kind = .value, .path = "", .key = "", .name = "" };
    try std.testing.expectEqual(Status.same, statusOf(&.{}, .major));
    try std.testing.expectEqual(Status.tolerated, statusOf(&.{&minor}, .major));
    try std.testing.expectEqual(Status.differs, statusOf(&.{ &minor, &major }, .major));
    try std.testing.expectEqual(Status.differs, statusOf(&.{&minor}, .minor));
}

test "[edge] - [output]: JSON strings escape quotes, backslashes, and control bytes" {
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeJsonString(&out, "a\"b\\c\td\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\td\\u0001\"", out.buffered());
}

test "[unit] - [output]: selection narrows by severity, key, and record" {
    const selection: Selection = .{ .severity = .major, .keys = &.{"MS:1000016"}, .records = &.{"scan=5"} };
    try std.testing.expect(selection.shows(.critical, "MS:1000016", "scan=5"));
    try std.testing.expect(!selection.shows(.minor, "MS:1000016", "scan=5"));
    try std.testing.expect(!selection.shows(.critical, "MS:1000512", "scan=5"));
    try std.testing.expect(!selection.shows(.critical, "MS:1000016", "scan=6"));
    try std.testing.expect(selection.shows(.critical, "MS:1000016", null));
}

test "[unit] - [output]: a list in JSON Lines ends with one summary line" {
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var lister: Lister = .{ .out = &out, .format = .json, .style = .{}, .selection = .{}, .allocator = std.testing.allocator };
    defer lister.deinit();
    const sink = lister.sink();
    try sink.emit(sink.context, .{
        .record = "scan=5",
        .severity = .major,
        .kind = .value,
        .path = "spectrum/scan",
        .key = "MS:1000512",
        .name = "filter string",
        .a = "x",
        .b = "y",
    });
    const side: Side = .{ .path = "a", .software = "", .spectra = 1, .chromatograms = 0 };
    try lister.finish(.{
        .a = side,
        .b = side,
        .paired_spectra = 1,
        .paired_chromatograms = 0,
        .completion = .complete,
        .status = .differs,
        .fail_on = .major,
        .totals = .{ 0, 1, 0 },
        .seconds = null,
    });
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.buffered(), "\n"), '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"type\": \"difference\", \"record\": \"scan=5\""));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"type\": \"summary\", \"schema_version\": 1"));
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}
