//! Renders a comparison for people and for programs: the report (difference classes with
//! examples), the summary (the verdict and its counts), the list (every difference, streamed as it
//! is found), each as text, TSV, or JSON, and the view (a git-style diff of the differing records,
//! for people only).
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

pub const Mode = enum { report, summary, list, view, quiet };

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

/// Renders the differing records as a git-style diff: a header per record, the element path, then
/// `-` for A and `+` for B (`~` when the difference is within a tolerance). The text is built in a bounded buffer while the comparison runs; when more than `records`
/// records differ or the text passes `bytes`, `finish` refuses to show it and says how to narrow it.
pub const Viewer = struct {
    out: *std.Io.Writer,
    style: Style,
    selection: Selection,
    records: usize = 40,
    bytes: usize = 1 << 20,
    buffer: std.Io.Writer.Allocating,
    last_record: std.ArrayList(u8) = .empty,
    last_path: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    shown: usize = 0,
    /// Differing records by their most severe shown difference: critical, major, minor.
    differing: [3]usize = .{ 0, 0, 0 },
    worst: ?Severity = null,
    too_large: bool = false,
    /// Per key: how many records it differs in, to say what to narrow by when the view is refused.
    keys: std.StringHashMapUnmanaged(KeyCount) = .empty,

    const KeyCount = struct { name: []const u8, records: usize, last: usize };

    pub fn init(allocator: std.mem.Allocator, out: *std.Io.Writer, style: Style, selection: Selection) Viewer {
        return .{ .out = out, .style = style, .selection = selection, .buffer = .init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Viewer) void {
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
        }
        self.keys.deinit(self.allocator);
        self.buffer.deinit();
        self.last_record.deinit(self.allocator);
        self.last_path.deinit(self.allocator);
    }

    pub fn sink(self: *Viewer) compare.Sink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, difference: Difference) anyerror!void {
        const self: *Viewer = @ptrCast(@alignCast(context));
        if (!self.selection.shows(difference.severity, difference.key, difference.record)) return;
        if (!std.mem.eql(u8, self.last_record.items, difference.record)) {
            self.closeRecord();
            self.last_record.clearRetainingCapacity();
            try self.last_record.appendSlice(self.allocator, difference.record);
            self.last_path.clearRetainingCapacity();
            self.shown += 1;
            if (self.shown > self.records) self.drop();
            if (!self.too_large) try self.recordHeader(difference.record);
        }
        if (self.worst == null or @intFromEnum(difference.severity) < @intFromEnum(self.worst.?)) self.worst = difference.severity;
        try self.countKey(difference);
        if (self.too_large) return;
        const w = &self.buffer.writer;
        // Arrays sit under their own heading, apart from the record's parameters.
        const arrays = std.mem.startsWith(u8, difference.key, "array:");
        const path_matches = std.mem.startsWith(u8, self.last_path.items, difference.path) and
            std.mem.eql(u8, self.last_path.items[difference.path.len..], if (arrays) "/binaryDataArray" else "");
        if (!path_matches) {
            self.last_path.clearRetainingCapacity();
            try self.last_path.appendSlice(self.allocator, difference.path);
            if (arrays) try self.last_path.appendSlice(self.allocator, "/binaryDataArray");
            try w.writeAll("  ");
            try self.dim(w, true);
            try writeShortPath(w, self.last_path.items);
            try self.dim(w, false);
            try w.writeByte('\n');
        }
        try self.unified(w, difference);
        if (self.buffer.written().len > self.bytes) self.drop();
    }

    fn countKey(self: *Viewer, difference: Difference) !void {
        const entry = try self.keys.getOrPut(self.allocator, difference.key);
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, difference.key) catch |err| {
                _ = self.keys.remove(difference.key);
                return err;
            };
            entry.value_ptr.* = .{ .name = try self.allocator.dupe(u8, difference.name), .records = 0, .last = 0 };
        }
        if (entry.value_ptr.last == self.shown) return;
        entry.value_ptr.last = self.shown;
        entry.value_ptr.records += 1;
    }

    fn closeRecord(self: *Viewer) void {
        if (self.worst) |worst| self.differing[@intFromEnum(worst)] += 1;
        self.worst = null;
    }

    // Too much to show: keep counting, stop rendering.
    fn drop(self: *Viewer) void {
        self.too_large = true;
        self.buffer.clearRetainingCapacity();
    }

    fn recordHeader(self: *Viewer, record: []const u8) !void {
        const w = &self.buffer.writer;
        if (self.shown > 1) try w.writeByte('\n');
        if (self.style.color) try w.writeAll("\x1b[1m");
        try w.print("{s}", .{record});
        if (self.style.color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }

    fn unified(self: *Viewer, w: *std.Io.Writer, difference: Difference) !void {
        const tolerated = isTolerance(difference.kind);
        var label_buffer: [160]u8 = undefined;
        const label = describe(&label_buffer, difference);
        // The first line of the pair carries the tag.
        var tagged = false;
        if (difference.a.len != 0 or difference.kind == .missing or difference.kind == .record_missing) {
            const width = try self.line(w, if (tolerated) '~' else '-', .a, label, difference.a);
            try w.splatByteAll(' ', TAG_COLUMN -| width);
            try self.tag(w, difference);
            tagged = true;
        }
        if (difference.b.len != 0 or difference.kind == .extra or difference.kind == .record_extra) {
            const width = try self.line(w, if (tolerated) '~' else '+', .b, label, difference.b);
            if (tagged) {
                try w.writeByte('\n');
            } else {
                try w.splatByteAll(' ', TAG_COLUMN -| width);
                try self.tag(w, difference);
            }
        }
        if (difference.array) |array| {
            try w.writeAll("      ");
            try self.dim(w, true);
            try w.print("{d} of {d} values differ", .{ array.differing, array.values });
            if (array.largest != array.shown) try writeLargest(w, array);
            try self.dim(w, false);
            try w.writeByte('\n');
        }
    }

    const Which = enum { a, b };

    // One side of a difference; returns its width, so a tag after it can line up in one column.
    fn line(self: *Viewer, w: *std.Io.Writer, marker: u8, side: Which, label: []const u8, value: []const u8) !usize {
        const color = if (marker == '~') "\x1b[33m" else if (side == .a) "\x1b[31m" else "\x1b[32m";
        if (self.style.color) try w.writeAll(color);
        try w.print("  {c} {s}", .{ marker, label });
        var width = 4 + label.len;
        if (value.len != 0) {
            try w.print(" = {s}", .{value});
            width += 3 + value.len;
        }
        if (self.style.color) try w.writeAll("\x1b[0m");
        return width;
    }

    const TAG_COLUMN = 64;

    fn tag(self: *Viewer, w: *std.Io.Writer, difference: Difference) !void {
        try w.writeAll("  ");
        try self.style.severity(w, difference.severity, 0);
        try self.dim(w, true);
        try w.print(" {s}", .{difference.kind.label()});
        try self.dim(w, false);
        try w.writeByte('\n');
    }

    fn dim(self: *const Viewer, w: *std.Io.Writer, on: bool) !void {
        if (self.style.color) try w.writeAll(if (on) "\x1b[2m" else "\x1b[0m");
    }

    // What to narrow by: a severity that would cut the count, and the keys that hit the most records.
    fn refusalHelp(self: *Viewer) !void {
        const out = self.out;
        if (self.differing[0] != 0 and self.differing[0] <= self.records)
            try out.print("mzdiff:   --severity critical  shows {d} records\n", .{self.differing[0]});
        if (self.differing[2] != 0 and self.differing[0] + self.differing[1] != 0 and self.differing[0] + self.differing[1] <= self.records)
            try out.print("mzdiff:   --severity major     shows {d} records\n", .{self.differing[0] + self.differing[1]});
        var top: [3]?struct { key: []const u8, count: KeyCount } = .{ null, null, null };
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            var candidate: @TypeOf(top[0]) = .{ .key = entry.key_ptr.*, .count = entry.value_ptr.* };
            for (&top) |*slot| {
                if (slot.* == null or candidate.?.count.records > slot.*.?.count.records) {
                    const pushed = slot.*;
                    slot.* = candidate;
                    candidate = pushed;
                    if (candidate == null) break;
                }
            }
        }
        for (top) |slot| if (slot) |found| {
            try out.print("mzdiff:   --key {s}  ({s}) differs in {d} records\n", .{ found.key, found.count.name, found.count.records });
        };
        try out.writeAll("mzdiff:   --record ID shows one record; --limit N raises the cap; --list shows everything\n\n");
    }

    /// Prints the view, or, when it is too large, how large and how to narrow it; then the summary.
    pub fn finish(self: *Viewer, outcome: Outcome) !void {
        self.closeRecord();
        const total = self.differing[0] + self.differing[1] + self.differing[2];
        if (self.too_large) {
            try self.out.print("mzdiff: too large to view: {d} records differ (critical {d}, major {d}, minor {d});" ++
                " the view shows at most {d}.\n", .{
                total, self.differing[0], self.differing[1], self.differing[2], self.records,
            });
            try self.refusalHelp();
        } else {
            try self.out.writeAll(self.buffer.written());
            if (total != 0) try self.out.writeByte('\n');
        }
        try writeSummaryLine(self.out, self.style, outcome);
    }
};

fn writeLargest(w: *std.Io.Writer, array: compare.ArrayDetail) !void {
    try w.print("; largest at [{d}]: {d} against {d}", .{ array.largest, array.largest_a, array.largest_b });
}

fn isTolerance(kind: compare.Kind) bool {
    return switch (kind) {
        .narrow, .rounding, .ppm, .precision, .peak_order => true,
        else => false,
    };
}

// The left-hand name of a difference: what it is, and what about it differs when that is not its
// value ("base peak m/z (unit)").
fn describe(buffer: []u8, difference: Difference) []const u8 {
    const name = if (difference.name.len != 0) difference.name else difference.key;
    const aspect: ?[]const u8 = switch (difference.kind) {
        .record_missing, .record_extra => return difference.path,
        .order => return "position in the file",
        .id_mismatch => return "native id",
        .peak_order => return "peaks (m/z, intensity)",
        .unit => "unit",
        .count, .peak_count => "count",
        .precision => "precision",
        .regrouped => "grouping",
        else => null,
    };
    return if (aspect) |what| std.fmt.bufPrint(buffer, "{s} ({s})", .{ name, what }) catch name else name;
}

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

test "[unit] - [view]: a differing value shows as a - and + pair with one tag" {
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var viewer = Viewer.init(std.testing.allocator, &out, .{}, .{});
    defer viewer.deinit();
    const sink = viewer.sink();
    try sink.emit(sink.context, .{
        .record = "scan=5",
        .severity = .critical,
        .kind = .value,
        .path = "spectrum",
        .key = "MS:1000511",
        .name = "ms level",
        .a = "2",
        .b = "3",
    });
    const side: Side = .{ .path = "a", .software = "", .spectra = 1, .chromatograms = 0 };
    try viewer.finish(.{
        .a = side,
        .b = side,
        .paired_spectra = 1,
        .paired_chromatograms = 0,
        .completion = .complete,
        .status = .differs,
        .fail_on = .major,
        .totals = .{ 1, 0, 0 },
        .seconds = null,
    });
    var lines = std.mem.splitScalar(u8, out.buffered(), '\n');
    try std.testing.expectEqualStrings("scan=5", lines.next().?);
    try std.testing.expectEqualStrings("  spectrum", lines.next().?);
    const minus = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, minus, "  - ms level = 2 "));
    try std.testing.expect(std.mem.endsWith(u8, minus, "CRITICAL value differs"));
    try std.testing.expectEqualStrings("  + ms level = 3", lines.next().?);
}

test "[edge] - [view]: more records than the cap are refused with counts and keys" {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var viewer = Viewer.init(std.testing.allocator, &out, .{}, .{});
    defer viewer.deinit();
    viewer.records = 2;
    const sink = viewer.sink();
    for ([_][]const u8{ "scan=1", "scan=2", "scan=3" }) |record| {
        try sink.emit(sink.context, .{
            .record = record,
            .severity = .major,
            .kind = .value,
            .path = "spectrum/scan",
            .key = "MS:1000512",
            .name = "filter string",
            .a = "x",
            .b = "y",
        });
    }
    const side: Side = .{ .path = "a", .software = "", .spectra = 3, .chromatograms = 0 };
    try viewer.finish(.{
        .a = side,
        .b = side,
        .paired_spectra = 3,
        .paired_chromatograms = 0,
        .completion = .complete,
        .status = .differs,
        .fail_on = .major,
        .totals = .{ 0, 1, 0 },
        .seconds = null,
    });
    const text = out.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "mzdiff: too large to view: 3 records differ (critical 0, major 3, minor 0)"));
    try std.testing.expect(std.mem.indexOf(u8, text, "--key MS:1000512  (filter string) differs in 3 records") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "filter string = x") == null);
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
