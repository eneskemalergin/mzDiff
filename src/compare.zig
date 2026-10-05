//! Compares two mzML records (or the two headers) by meaning, not by bytes.
//!
//! Each side becomes a list of facts: (element path, key, value, unit) for every attribute,
//! cvParam, and userParam, with group references expanded. Facts are sorted and compared per
//! (path, key), so parameter order, attribute order, whitespace, number spelling ("50" and
//! "50.000"), and the order of repeated elements do not matter, except a spectrum's precursors,
//! whose order says which stage each one is. Scan times in seconds are compared
//! in minutes. Arrays are compared as decoded values, at 32-bit precision when either side stores
//! 32 bits. Every difference is filed under a class (severity, kind, path, key) in a `Report`.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const model = mzml.model;
const cv = mzml.cv;

const rules_mod = @import("rules.zig");
const Rules = rules_mod.Rules;
const Severity = rules_mod.Severity;

pub const Kind = enum {
    missing,
    extra,
    value,
    rounding,
    narrow,
    ppm,
    count,
    unit,
    record_missing,
    record_extra,
    peak_count,
    peak_values,
    peak_order,
    precision,
    array_missing,
    array_extra,
    id_mismatch,
    regrouped,
    order,
    element_order,
    term,
    specific,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .missing => "missing in B",
            .extra => "only in B",
            .value => "value differs",
            .rounding => "last digit differs",
            .narrow => "equal at 32-bit precision",
            .ppm => "m/z within tolerance",
            .count => "count differs",
            .unit => "unit differs",
            .record_missing => "record missing in B",
            .record_extra => "record only in B",
            .peak_count => "array length differs",
            .peak_values => "array values differ",
            .peak_order => "same peaks, other order",
            .precision => "array precision differs",
            .array_missing => "array missing in B",
            .array_extra => "array only in B",
            .id_mismatch => "paired ids differ",
            .regrouped => "values regrouped",
            .order => "records out of order",
            .element_order => "in another order",
            .term => "another term",
            .specific => "a more specific term",
        };
    }
};

pub const Example = struct { id: []const u8, a: []const u8, b: []const u8 };

/// One difference as found, before it is filed under a class. Strings borrow from the caller and
/// last only for the `Sink.emit` call.
pub const Difference = struct {
    record: []const u8,
    severity: Severity,
    kind: Kind,
    path: []const u8,
    key: []const u8,
    name: []const u8,
    a: []const u8,
    b: []const u8,
    array: ?ArrayDetail = null,
};

/// How a differing array differs: values compared, how many differ, and the largest difference
/// (relative to the larger of the two values).
pub const ArrayDetail = struct {
    values: usize,
    /// The index the difference's `a` and `b` show.
    shown: usize = 0,
    differing: usize,
    largest: usize,
    largest_a: f64,
    largest_b: f64,
};

/// Receives every difference `Report.add` files, in the order found.
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Difference) anyerror!void,
};

pub const Class = struct {
    severity: Severity,
    kind: Kind,
    path: []const u8,
    key: []const u8,
    name: []const u8,
    /// Records (spectra, chromatograms, or the header) with at least one such difference.
    records: usize = 0,
    last_record: usize = std.math.maxInt(usize),
    examples: std.ArrayList(Example) = .empty,
};

// The most difference classes a report keeps one by one; see `Report.add`.
const MAX_CLASSES = 4096;

pub const Report = struct {
    allocator: std.mem.Allocator,
    rules: *Rules,
    max_examples: usize,
    /// m/z parameters closer than this (parts per million) are a minor difference.
    ppm: f64 = 1.0,
    classes: std.StringHashMapUnmanaged(*Class) = .empty,
    /// Serial number of the record being compared, so a class counts each record once.
    record: usize = 0,
    /// Paths with a real difference in the current record (set by `diffFacts`).
    dirty: std.ArrayList([]const u8) = .empty,
    // Scratch for `sortFacts`, reused across records.
    runs: std.ArrayList(Run) = .empty,
    reordered: std.ArrayList(Fact) = .empty,
    // `diffFacts` scratch: groups on one side only, and the terms paired between them.
    only_a: std.ArrayList(usize) = .empty,
    only_b: std.ArrayList(usize) = .empty,
    terms: std.ArrayList(TermPair) = .empty,
    /// Sees every difference before it is filed, for `--list`.
    sink: ?Sink = null,

    pub fn init(allocator: std.mem.Allocator, rules: *Rules, max_examples: usize) Report {
        return .{ .allocator = allocator, .rules = rules, .max_examples = max_examples };
    }

    pub fn deinit(self: *Report) void {
        var it = self.classes.iterator();
        while (it.next()) |entry| {
            const class = entry.value_ptr.*;
            for (class.examples.items) |example| {
                self.allocator.free(example.id);
                self.allocator.free(example.a);
                self.allocator.free(example.b);
            }
            class.examples.deinit(self.allocator);
            self.allocator.free(class.path);
            self.allocator.free(class.key);
            self.allocator.free(class.name);
            self.allocator.destroy(class);
            self.allocator.free(entry.key_ptr.*);
        }
        self.classes.deinit(self.allocator);
        self.dirty.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.reordered.deinit(self.allocator);
        self.only_a.deinit(self.allocator);
        self.only_b.deinit(self.allocator);
        self.terms.deinit(self.allocator);
    }

    /// Like `add`, and marks the path as holding a real difference in this record.
    fn addDirty(
        self: *Report,
        severity: ?Severity,
        kind: Kind,
        path: []const u8,
        key: []const u8,
        name: []const u8,
        id: []const u8,
        a: []const u8,
        b: []const u8,
    ) !void {
        try self.dirty.append(self.allocator, path);
        try self.add(severity, kind, path, key, name, id, a, b);
    }

    /// Files one difference. `severity` null means "from the rules for key".
    pub fn add(
        self: *Report,
        severity: ?Severity,
        kind: Kind,
        path: []const u8,
        key: []const u8,
        name: []const u8,
        id: []const u8,
        a: []const u8,
        b: []const u8,
    ) !void {
        try self.addDetailed(severity, kind, path, key, name, id, a, b, null);
    }

    /// `add` with an array's detail for the sink.
    pub fn addDetailed(
        self: *Report,
        severity: ?Severity,
        kind: Kind,
        path: []const u8,
        key: []const u8,
        name: []const u8,
        id: []const u8,
        a: []const u8,
        b: []const u8,
        array: ?ArrayDetail,
    ) !void {
        // `--set` wins even over a severity the check chose itself (a tolerance, a lost record).
        var level = self.rules.overridden(key) orelse severity orelse self.rules.severity(key);
        if (level == .ignored) return;
        // fileContent summarises the spectra, which are compared themselves.
        if (level == .critical and std.mem.indexOf(u8, path, "fileContent") != null) level = .major;
        if (self.sink) |sink| try sink.emit(sink.context, .{
            .record = id,
            .severity = level,
            .kind = kind,
            .path = path,
            .key = key,
            .name = if (name.len != 0) name else self.rules.name(key) orelse "",
            .a = a,
            .b = b,
            .array = array,
        });
        var key_buffer: [512]u8 = undefined;
        var class_key = std.fmt.bufPrint(&key_buffer, "{s}\x1f{s}\x1f{s}", .{ path, key, @tagName(kind) }) catch
            try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f{s}", .{ path, key, @tagName(kind) });
        // Past MAX_CLASSES, a new key joins one class per path and kind instead of making its own,
        // so endless distinct keys in a file cannot grow the report without bound; the list and
        // the sink still see every difference.
        var class_name = name;
        var class_name_key = key;
        if (self.classes.count() >= MAX_CLASSES and !self.classes.contains(class_key)) {
            if (class_key.ptr != &key_buffer) self.allocator.free(class_key);
            class_key = std.fmt.bufPrint(&key_buffer, "{s}\x1f(more keys)\x1f{s}\x1f{s}", .{ path, @tagName(kind), @tagName(level) }) catch
                try std.fmt.allocPrint(self.allocator, "{s}\x1f(more keys)\x1f{s}\x1f{s}", .{ path, @tagName(kind), @tagName(level) });
            class_name_key = "(more keys)";
            class_name = "keys past the class limit";
        }
        defer if (class_key.ptr != &key_buffer) self.allocator.free(class_key);
        const entry = try self.classes.getOrPut(self.allocator, class_key);
        if (!entry.found_existing) {
            errdefer _ = self.classes.remove(class_key);
            const owned_key = try self.allocator.dupe(u8, class_key);
            const class = try self.allocator.create(Class);
            class.* = .{
                .severity = level,
                .kind = kind,
                .path = try self.allocator.dupe(u8, path),
                .key = try self.allocator.dupe(u8, class_name_key),
                .name = try self.allocator.dupe(u8, if (class_name.len != 0) class_name else self.rules.name(key) orelse ""),
            };
            entry.key_ptr.* = owned_key;
            entry.value_ptr.* = class;
        }
        const class = entry.value_ptr.*;
        if (class.last_record == self.record) return;
        class.last_record = self.record;
        class.records += 1;
        if (class.examples.items.len < self.max_examples) {
            try class.examples.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .a = try self.allocator.dupe(u8, clip(a)),
                .b = try self.allocator.dupe(u8, clip(b)),
            });
        }
    }

    /// Classes sorted by severity, then by records hit, then by path and key.
    pub fn sorted(self: *const Report, allocator: std.mem.Allocator) ![]*Class {
        const list = try allocator.alloc(*Class, self.classes.count());
        var it = self.classes.valueIterator();
        var i: usize = 0;
        while (it.next()) |class| : (i += 1) list[i] = class.*;
        std.mem.sort(*Class, list, {}, struct {
            fn less(_: void, x: *Class, y: *Class) bool {
                if (x.severity != y.severity) return @intFromEnum(x.severity) < @intFromEnum(y.severity);
                if (x.records != y.records) return x.records > y.records;
                const order = std.mem.order(u8, x.path, y.path);
                if (order != .eq) return order == .lt;
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.less);
        return list;
    }
};

// At most 160 bytes, cut before a UTF-8 continuation byte so the output stays valid text.
fn clip(text: []const u8) []const u8 {
    var end = @min(text.len, 160);
    while (end > 0 and end < text.len and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

// --- Facts ---

pub const Fact = struct {
    path: []const u8,
    key: []const u8,
    name: []const u8,
    text: []const u8,
    number: ?f64,
    unit: []const u8,
    /// What `number` was multiplied by to reach the compared unit (1/60 for seconds read as
    /// minutes), so the printed precision of `text` scales with it.
    scale: f64 = 1,
    /// The element the fact belongs to: an index into the record's `Element` list.
    element: u32 = 0,
};

/// One element of a record, in document order; facts point at their element, elements at their
/// parent, so repeated elements (two precursors, say) can be compared as wholes.
pub const Element = struct { path: []const u8, parent: u32 };

pub const NO_PARENT = std.math.maxInt(u32);

/// Collects the facts of a node and its children. Binary arrays are left to `compareArrays`; the
/// elements in `skip` (header lists) are left out with their children. With `elements`, each
/// element visited is listed and each fact names its element.
/// Strings that repeat across one side's records (element paths, keys, names, units), copied once
/// and shared by every fact after, with each key's severity looked up once. One per reading thread,
/// so it needs no lock; its strings live until `deinit`. Past `limit` bytes it takes no new strings
/// and `get` returns null, so a file with endless distinct keys costs per-record copies, not
/// unbounded memory.
pub const Interner = struct {
    arena: std.heap.ArenaAllocator,
    strings: std.StringHashMapUnmanaged(?KeyInfo) = .empty,
    bytes: usize = 0,
    limit: usize = 8 << 20,

    pub fn init(allocator: std.mem.Allocator) Interner {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Interner) void {
        self.arena.deinit();
    }

    /// Returns the shared copy of `text`, or null once the interner is full.
    pub fn get(self: *Interner, text: []const u8) !?[]const u8 {
        if (self.strings.getKey(text)) |found| return found;
        // The map's own entries count too, roughly.
        if (self.bytes + text.len + 32 > self.limit) return null;
        const arena = self.arena.allocator();
        const copy = try arena.dupe(u8, text);
        try self.strings.put(arena, copy, null);
        self.bytes += text.len + 32;
        return copy;
    }

    fn info(self: *Interner, rules: *Rules, key: []const u8) KeyInfo {
        const cached = self.strings.getPtr(key) orelse return KeyInfo.of(rules, key);
        if (cached.*) |found| return found;
        const found = KeyInfo.of(rules, key);
        cached.* = found;
        return found;
    }
};

/// What the rules say about a key, looked up once per key and reader.
const KeyInfo = struct {
    severity: Severity,
    /// The vocabulary types the key's value as an integer.
    integer: bool,

    fn of(rules: *Rules, key: []const u8) KeyInfo {
        return .{ .severity = rules.severity(key), .integer = rules.integerTyped(key) };
    }
};

fn inRecord(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "spectrum") or std.mem.startsWith(u8, path, "chromatogram");
}

// Whether `text` is an XSD integer: an optional sign and digits, around optional whitespace.
fn integerSpelling(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const digits = if (trimmed.len != 0 and (trimmed[0] == '+' or trimmed[0] == '-')) trimmed[1..] else trimmed;
    if (digits.len == 0) return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub const Collector = struct {
    arena: std.mem.Allocator,
    rules: *Rules,
    facts: *std.ArrayList(Fact),
    elements: ?*std.ArrayList(Element) = null,
    groups: []const cv.Group,
    skip: []const model.Kind = &.{},
    /// When set, every fact's path, key, name, and unit is a stable copy (shared or in `arena`);
    /// only its text still borrows from the record.
    interner: ?*Interner = null,

    // A stable copy of a repeating string: shared when the interner has room, else in the arena.
    // Without an interner the string is returned as it is, borrowed.
    fn stable(self: *const Collector, text: []const u8) ![]const u8 {
        const interner = self.interner orelse return text;
        return (try interner.get(text)) orelse try self.arena.dupe(u8, text);
    }

    fn infoOf(self: *const Collector, key: []const u8) KeyInfo {
        const interner = self.interner orelse return KeyInfo.of(self.rules, key);
        return interner.info(self.rules, key);
    }

    pub fn add(self: *const Collector, node: model.Node, prefix: []const u8, parent: u32) !void {
        for (self.skip) |kind| if (node.kind == kind) return;
        if (node.kind == .binary_data_array_list or node.kind == .binary) return;
        var path_buffer: [512]u8 = undefined;
        const path = if (prefix.len == 0)
            node.kind.xmlName()
        else if (self.interner != null)
            try self.stable(std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ prefix, node.kind.xmlName() }) catch
                return error.ElementPathTooLong)
        else
            try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ prefix, node.kind.xmlName() });
        var element: u32 = 0;
        if (self.elements) |list| {
            element = @intCast(list.items.len);
            try list.append(self.arena, .{ .path = path, .parent = parent });
        }

        for (node.attributes) |attribute| {
            if (attribute.namespace_uri != null) continue;
            var key_buffer: [128]u8 = undefined;
            const probe = std.fmt.bufPrint(&key_buffer, "@{s}", .{attribute.name}) catch return error.AttributeNameTooLong;
            const key = if (self.interner != null) try self.stable(probe) else try self.arena.dupe(u8, probe);
            if (self.infoOf(key).severity == .ignored) continue;
            try self.facts.append(self.arena, makeFact(path, key, "", attribute.value, "", element));
        }

        // Whether a spectrum or chromatogram takes parameters through a group is a fact of its own
        // (the group's id is bookkeeping): the parameters compare as if written inline, but some
        // readers (Sage) ignore groups and miss what they hold. The header's groups, which every
        // header reader resolves, are not noted.
        if (inRecord(path)) for (node.params) |entry| if (entry == .group_ref) {
            try self.facts.append(self.arena, makeFact(path, "form:paramGroup", "parameters through a group", "", "", element));
            break;
        };

        var params: cv.EffectiveIterator = .{ .entries = node.params, .groups = self.groups };
        while (try params.next()) |entry| switch (entry) {
            .cv => |param| {
                const key = try self.stable(if (param.accession) |accession| accession.raw else param.name orelse continue);
                // An integer-typed value spelled otherwise ("2.0" for a charge) is the same number,
                // but outside the standard: readers that parse the declared type refuse the file.
                const info = self.infoOf(key);
                if (param.value) |value| if (info.integer and !integerSpelling(value))
                    try self.facts.append(self.arena, makeFact(path, "form:integer", "integer value written otherwise", key, "", element));
                if (info.severity == .ignored) continue;
                try self.facts.append(self.arena, makeFact(
                    path,
                    key,
                    try self.stable(param.name orelse ""),
                    param.value orelse "",
                    try self.stable(unitOf(param.unit)),
                    element,
                ));
            },
            .user => |param| {
                const name = param.name orelse continue;
                var key_buffer: [256]u8 = undefined;
                const key = if (self.interner != null)
                    try self.stable(std.fmt.bufPrint(&key_buffer, "user:{s}", .{name}) catch return error.ParameterNameTooLong)
                else
                    try std.fmt.allocPrint(self.arena, "user:{s}", .{name});
                if (self.infoOf(key).severity == .ignored) continue;
                try self.facts.append(self.arena, makeFact(
                    path,
                    key,
                    try self.stable(name),
                    param.value orelse "",
                    try self.stable(unitOf(param.unit)),
                    element,
                ));
            },
            .group_ref => {},
        };

        for (node.children) |child| try self.add(child, path, element);
    }
};

/// Shorthand for `Collector.add` without element tracking, as the header uses it.
pub fn collect(
    arena: std.mem.Allocator,
    rules: *Rules,
    facts: *std.ArrayList(Fact),
    node: model.Node,
    prefix: []const u8,
    groups: []const cv.Group,
    skip: []const model.Kind,
) !void {
    const collector: Collector = .{ .arena = arena, .rules = rules, .facts = facts, .groups = groups, .skip = skip };
    try collector.add(node, prefix, NO_PARENT);
}

/// A fact with its value parsed; times in seconds become minutes.
pub fn makeFact(path: []const u8, key: []const u8, name: []const u8, value: []const u8, unit: []const u8, element: u32) Fact {
    const text = std.mem.trim(u8, value, " \t\r\n");
    const number: ?f64 = if (text.len == 0) null else std.fmt.parseFloat(f64, text) catch null;
    var fact: Fact = .{ .path = path, .key = key, .name = name, .text = text, .number = number, .unit = unit, .element = element };
    if (fact.number) |seconds| if (std.mem.eql(u8, unit, SECOND)) {
        fact.number = seconds / 60.0;
        fact.unit = MINUTE;
        fact.scale = 1.0 / 60.0;
    };
    return fact;
}

const SECOND = "UO:0000010";

const MINUTE = "UO:0000031";

fn unitOf(unit: anytype) []const u8 {
    return if (unit.accession) |accession| accession.raw else unit.name orelse "";
}

// --- Fact comparison ---

/// Compares two fact lists (sorted here) and files each differing (path, key) once per record.
/// The paths of real differences (not tolerance-level ones) are kept in `report.dirty`.
pub fn diffFacts(report: *Report, id: []const u8, a: []Fact, b: []Fact) !void {
    report.dirty.clearRetainingCapacity();
    try sortFacts(report, a);
    try sortFacts(report, b);
    try pairTerms(report, a, b);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        const take_a = j == b.len or (i < a.len and groupLess(a[i], b[j]));
        const take_b = i == a.len or (j < b.len and groupLess(b[j], a[i]));
        if (take_a) {
            const end = groupEnd(a, i);
            if (partnerOf(report, i)) |pair| {
                const x = a[i];
                const y = b[pair.b];
                // One term in place of another: a more specific one costs nothing, any other has
                // the severity of what both name (`--set` on A's term still wins).
                const severity: ?Severity = if (pair.specific) .minor else null;
                try report.addDirty(severity, if (pair.specific) .specific else .term, x.path, x.key, report.rules.name(pair.category) orelse "", id, orKey(x), orKey(y));
            } else try report.addDirty(null, .missing, a[i].path, a[i].key, a[i].name, id, a[i].text, "");
            i = end;
        } else if (take_b) {
            const end = groupEnd(b, j);
            const paired = for (report.terms.items) |pair| {
                if (pair.b == j) break true;
            } else false;
            if (!paired) try report.addDirty(null, .extra, b[j].path, b[j].key, b[j].name, id, "", b[j].text);
            j = end;
        } else {
            const end_a = groupEnd(a, i);
            const end_b = groupEnd(b, j);
            try diffGroup(report, id, a[i..end_a], b[j..end_b]);
            i = end_a;
            j = end_b;
        }
    }
}

const TermPair = struct { a: usize, b: usize, category: []const u8, specific: bool };

// Pairs the terms without a value found on one side only, at the same element and in the same
// category of the vocabulary (two analyzers, two polarities): one term written in place of the
// other reads as one difference, not a missing and an extra. Each term pairs at most once, the
// first in key order.
fn pairTerms(report: *Report, a: []const Fact, b: []const Fact) !void {
    report.terms.clearRetainingCapacity();
    report.only_a.clearRetainingCapacity();
    report.only_b.clearRetainingCapacity();
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        const take_a = j == b.len or (i < a.len and groupLess(a[i], b[j]));
        const take_b = i == a.len or (j < b.len and groupLess(b[j], a[i]));
        if (take_a) {
            if (a[i].text.len == 0) try report.only_a.append(report.allocator, i);
            i = groupEnd(a, i);
        } else if (take_b) {
            if (b[j].text.len == 0) try report.only_b.append(report.allocator, j);
            j = groupEnd(b, j);
        } else {
            i = groupEnd(a, i);
            j = groupEnd(b, j);
        }
    }
    if (report.only_a.items.len == 0 or report.only_b.items.len == 0) return;
    for (report.only_a.items) |x| {
        const category = report.rules.category(a[x].key) orelse continue;
        for (report.only_b.items) |y| {
            if (!sameText(a[x].path, b[y].path)) continue;
            const taken = for (report.terms.items) |pair| {
                if (pair.b == y) break true;
            } else false;
            if (taken) continue;
            const other = report.rules.category(b[y].key) orelse continue;
            if (!std.mem.eql(u8, category, other)) continue;
            try report.terms.append(report.allocator, .{ .a = x, .b = y, .category = category, .specific = report.rules.isA(b[y].key, a[x].key) });
            break;
        }
    }
}

fn partnerOf(report: *const Report, i: usize) ?TermPair {
    for (report.terms.items) |pair| if (pair.a == i) return pair;
    return null;
}

fn orKey(fact: Fact) []const u8 {
    return if (fact.name.len != 0) fact.name else fact.key;
}

/// Sorts and drops exact repeats (same path, key, value, unit): header facts compare as a set,
/// so a model named once per instrument configuration is not a count difference.
pub fn dedupe(facts: []Fact) []Fact {
    std.mem.sortUnstable(Fact, facts, {}, factLess);
    var kept: usize = 0;
    for (facts) |fact| {
        if (kept > 0) {
            const last = facts[kept - 1];
            if (sameGroup(last, fact) and std.mem.eql(u8, last.text, fact.text) and std.mem.eql(u8, last.unit, fact.unit)) continue;
        }
        facts[kept] = fact;
        kept += 1;
    }
    return facts[0..kept];
}

const Run = struct { path: []const u8, start: usize, end: usize };

// Sorts facts by `factLess`, using the order they arrive in: a record's facts come grouped by
// element, so sorting the runs of one path (a dozen or so) and then each path's facts by key costs
// far fewer comparisons than sorting them all at once. The result is the same order.
fn sortFacts(report: *Report, facts: []Fact) !void {
    const allocator = report.allocator;
    report.runs.clearRetainingCapacity();
    var start: usize = 0;
    while (start < facts.len) {
        var end = start + 1;
        while (end < facts.len and sameText(facts[end].path, facts[start].path)) end += 1;
        try report.runs.append(allocator, .{ .path = facts[start].path, .start = start, .end = end });
        start = end;
    }
    const runs = report.runs.items;
    if (runs.len > 1) {
        std.mem.sortUnstable(Run, runs, {}, struct {
            fn less(_: void, x: Run, y: Run) bool {
                return orderText(x.path, y.path) == .lt;
            }
        }.less);
        report.reordered.clearRetainingCapacity();
        try report.reordered.ensureTotalCapacity(allocator, facts.len);
        for (runs) |run| report.reordered.appendSliceAssumeCapacity(facts[run.start..run.end]);
        @memcpy(facts, report.reordered.items);
    }
    // Each path's facts, now adjacent (repeated elements included), by key and value.
    start = 0;
    while (start < facts.len) {
        var end = start + 1;
        while (end < facts.len and sameText(facts[end].path, facts[start].path)) end += 1;
        if (end - start > 1) std.mem.sortUnstable(Fact, facts[start..end], {}, factLess);
        start = end;
    }
}

// A total order: by path, key, value (numbers first, NaN after other numbers), text, then unit.
fn factLess(_: void, x: Fact, y: Fact) bool {
    var order = orderText(x.path, y.path);
    if (order != .eq) return order == .lt;
    order = orderText(x.key, y.key);
    if (order != .eq) return order == .lt;
    if (x.number != null and y.number != null) {
        const p = x.number.?;
        const q = y.number.?;
        if (std.math.isNan(p) != std.math.isNan(q)) return std.math.isNan(q);
        if (p != q and !std.math.isNan(p)) return p < q;
    } else if (x.number != null or y.number != null) {
        return x.number != null;
    }
    order = std.mem.order(u8, x.text, y.text);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, x.unit, y.unit) == .lt;
}

// Interned strings of one side are the same pointer, which settles most comparisons at once.
fn orderText(a: []const u8, b: []const u8) std.math.Order {
    if (a.ptr == b.ptr and a.len == b.len) return .eq;
    return std.mem.order(u8, a, b);
}

fn sameText(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

fn sameGroup(x: Fact, y: Fact) bool {
    return sameText(x.path, y.path) and sameText(x.key, y.key);
}

fn groupLess(x: Fact, y: Fact) bool {
    const order = std.mem.order(u8, x.path, y.path);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, x.key, y.key) == .lt;
}

fn groupEnd(facts: []const Fact, start: usize) usize {
    var end = start + 1;
    while (end < facts.len and sameGroup(facts[start], facts[end])) end += 1;
    return end;
}

// A total ion current of zero where A has one: readers take it for an empty spectrum and skip it
// (Sage drops the spectrum without a word), so the spectrum is lost to them, not just a value.
fn emptied(x: Fact, y: Fact) ?Severity {
    if (!std.mem.eql(u8, x.key, "MS:1000285")) return null;
    const p = x.number orelse return null;
    const q = y.number orelse return null;
    return if (q == 0 and p != 0) .critical else null;
}

fn diffGroup(report: *Report, id: []const u8, a: []const Fact, b: []const Fact) !void {
    const first = a[0];
    if (a.len != b.len) {
        var ta: [32]u8 = undefined;
        var tb: [32]u8 = undefined;
        try report.addDirty(
            null,
            .count,
            first.path,
            first.key,
            first.name,
            id,
            std.fmt.bufPrint(&ta, "{d} of them", .{a.len}) catch "",
            std.fmt.bufPrint(&tb, "{d} of them", .{b.len}) catch "",
        );
        return;
    }
    for (a, b) |x_unit, y_unit| {
        var x = x_unit;
        var y = y_unit;
        if (!std.mem.eql(u8, x.unit, y.unit)) {
            if (x.unit.len != 0 and y.unit.len != 0) {
                try report.addDirty(null, .unit, x.path, x.key, x.name, id, x.unit, y.unit);
                continue;
            }
            try report.add(oneSidedUnit(report, x.key, x.unit), .unit, x.path, x.key, x.name, id, orDash(x.unit), orDash(y.unit));
            // With a unit on one side only, the values compare as printed, not converted.
            x = asPrinted(x);
            y = asPrinted(y);
        }
        switch (compareValues(report.ppm, x, y)) {
            .same => {},
            .different => try report.addDirty(emptied(x, y), .value, x.path, x.key, x.name, id, x.text, y.text),
            inline else => |kind| try report.add(.minor, @field(Kind, @tagName(kind)), x.path, x.key, x.name, id, x.text, y.text),
        }
    }
}

// A unit on one side only leaves the value as it was. One B adds is minor (mzValidate judges
// whether the term allows it); one B drops costs readers the unit: never more than major, except
// for a time, which means nothing without one.
fn oneSidedUnit(report: *Report, key: []const u8, unit_a: []const u8) Severity {
    if (unit_a.len == 0) return .minor;
    const level = report.rules.severity(key);
    // A time without its unit could be seconds or minutes, and readers refuse it or misread it
    // sixtyfold; any other unit is implied by the term, so dropping it costs at most major.
    if (std.mem.eql(u8, unit_a, MINUTE) or std.mem.eql(u8, unit_a, SECOND)) return level;
    return if (level == .critical) .major else level;
}

fn asPrinted(fact: Fact) Fact {
    var copy = fact;
    if (copy.number) |number| copy.number = number / copy.scale;
    copy.scale = 1;
    return copy;
}

fn orDash(text: []const u8) []const u8 {
    return if (text.len == 0) "-" else text;
}

const Verdict = enum { same, narrow, rounding, ppm, different };

// How two values of the same key compare: equal, equal within a tolerance (and which), or not.
fn compareValues(ppm: f64, x: Fact, y: Fact) Verdict {
    if (x.number != null and y.number != null) {
        const p = x.number.?;
        const q = y.number.?;
        if (p == q or (std.math.isNan(p) and std.math.isNan(q))) return .same;
        if (sameAt32(p, q)) return .narrow;
        if (lastDigit(x.text, y.text, p, q, x.scale, y.scale)) return .rounding;
        if (isMz(x.key) and @abs(p - q) <= ppm * 1e-6 * @max(@abs(p), @abs(q))) return .ppm;
        return .different;
    }
    if (std.mem.eql(u8, x.text, y.text)) return .same;
    if (std.mem.eql(u8, x.key, "@startTimeStamp") and std.mem.eql(u8, trimFraction(x.text), trimFraction(y.text))) return .same;
    return .different;
}

// "2015-10-14T03:22:49.630Z" -> "2015-10-14T03:22:49.63": trailing zeros of the seconds
// fraction and the zone letter Z carry no information.
fn trimFraction(text: []const u8) []const u8 {
    var end = text.len;
    if (end > 0 and text[end - 1] == 'Z') end -= 1;
    const dot = std.mem.lastIndexOfScalar(u8, text[0..end], '.') orelse return text[0..end];
    while (end > dot + 1 and text[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return text[0..end];
}

/// True when two numbers are the same value printed with different rounding. With the same
/// number of decimals they may differ by one unit in the last place ("79.106" and "79.107", one
/// side rounded from a 32-bit value); with different numbers, the shorter must be the longer
/// rounded to its places, within half a unit of each. A scale (1/60 for seconds read as minutes)
/// carries each spelling's precision into the compared unit. A value printed as an integer is
/// never a rounding: "26" against "26.112" is a nominal value, not the measured one.
fn lastDigit(text_a: []const u8, text_b: []const u8, a: f64, b: f64, scale_a: f64, scale_b: f64) bool {
    const da = decimals(text_a) orelse return relativeClose(a, b);
    const db = decimals(text_b) orelse return relativeClose(a, b);
    if (da == 0 or db == 0) return false;
    const ua = std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(da))) * scale_a;
    const ub = std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(db))) * scale_b;
    const tolerance = if (da == db and scale_a == scale_b) ua else (ua + ub) / 2;
    return @abs(a - b) <= tolerance * 1.000001;
}

// Parameters that hold an m/z value, compared with the ppm tolerance.
fn isMz(key: []const u8) bool {
    const keys = [_][]const u8{
        "MS:1000744", "MS:1000040", "MS:1000827", "MS:1000504", "MS:1000528", "MS:1000527",
    };
    for (keys) |k| if (std.mem.eql(u8, key, k)) return true;
    return false;
}

/// True when the values agree to 32-bit precision: they round to the same 32-bit float, or lie
/// within one 32-bit epsilon (2^-23, relative) when rounding falls on either side of a boundary.
/// One side stored or printed a 32-bit value, the other the 64-bit value it came from.
fn sameAt32(a: f64, b: f64) bool {
    const x: f32 = @floatCast(a);
    const y: f32 = @floatCast(b);
    if (x == y) return true;
    return @abs(a - b) <= std.math.floatEps(f32) * @max(@abs(a), @abs(b));
}

fn relativeClose(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-6 * @max(@abs(a), @abs(b));
}

// Digits after the decimal point; null for exponent notation.
fn decimals(text: []const u8) ?usize {
    if (std.mem.indexOfAny(u8, text, "eE") != null) return null;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    return text.len - dot - 1;
}

// --- Repeated elements ---

/// Checks that repeated elements (two precursors, two scan windows) keep their values together:
/// facts compared per (path, key) would not notice charge 2 and charge 3 trading places between
/// two precursors. For each path that repeats in a record and holds no real difference already,
/// every element of A, with its descendants, must match a distinct element of B within the
/// usual tolerances. Elements present on one side only are counted too. Call after `diffFacts`,
/// which sorts the facts and fills `report.dirty`.
pub fn diffGrouping(
    report: *Report,
    scratch: std.mem.Allocator,
    id: []const u8,
    a: []const Fact,
    elements_a: []const Element,
    b: []const Fact,
    elements_b: []const Element,
) !void {
    // Paths filed as regrouped; their descendants would only repeat the same finding.
    var filed: std.ArrayList([]const u8) = .empty;
    for (elements_a, 0..) |element, position| {
        if (!firstOfPath(elements_a, position)) continue;
        if (under(filed.items, element.path)) continue;
        const count_a = countPath(elements_a, element.path);
        const count_b = countPath(elements_b, element.path);
        if (count_a < 2 and count_b < 2) continue;
        if (isDirty(report, element.path)) continue;
        if (count_a != count_b) {
            var ta: [32]u8 = undefined;
            var tb: [32]u8 = undefined;
            try report.addDirty(
                null,
                .count,
                element.path,
                "element",
                "",
                id,
                std.fmt.bufPrint(&ta, "{d} of them", .{count_a}) catch "",
                std.fmt.bufPrint(&tb, "{d} of them", .{count_b}) catch "",
            );
            continue;
        }
        const groups_a = try subtrees(scratch, a, elements_a, element.path, count_a);
        const groups_b = try subtrees(scratch, b, elements_b, element.path, count_b);
        const taken = try scratch.alloc(bool, groups_b.len);
        @memset(taken, false);
        // B's elements by the hash of their exact contents: an element of A finds an exact partner
        // by binary search, however many elements repeat or however they are ordered.
        const index = try scratch.alloc(Hashed, groups_b.len);
        for (groups_b, index, 0..) |group, *entry, at| entry.* = .{ .hash = subtreeHash(group.items), .at = at };
        std.mem.sortUnstable(Hashed, index, {}, Hashed.less);
        var moved = false;
        var unmatched: ?usize = null;
        for (groups_a, 0..) |group, position_a| {
            const at = matchExact(report.ppm, group.items, groups_b, index, taken) orelse
                matchNear(report.ppm, group.items, groups_b, taken, position_a) orelse {
                unmatched = position_a;
                break;
            };
            moved = moved or at != position_a;
        }
        if (unmatched) |position_a| {
            try reportRegrouped(report, scratch, id, element.path, groups_a[position_a].items, groups_b, taken);
            try filed.append(scratch, element.path);
        } else if (moved and ordered(element.path)) {
            // The same elements in another order, where the order carries meaning: shown by the
            // m/z of the first one on each side, the one a reader takes.
            const first_a = try firstMz(scratch, groups_a[0].items);
            const first_b = try firstMz(scratch, groups_b[0].items);
            try report.add(null, .element_order, element.path, "precursorOrder", "precursors", id, first_a, first_b);
        }
    }
    for (elements_b, 0..) |element, position| {
        if (!firstOfPath(elements_b, position) or countPath(elements_a, element.path) != 0) continue;
        if (countPath(elements_b, element.path) < 2 or isDirty(report, element.path)) continue;
        try report.addDirty(null, .count, element.path, "element", "", id, "0 of them", "several");
    }
}

const Hashed = struct {
    hash: u64,
    at: usize,

    fn less(_: void, x: Hashed, y: Hashed) bool {
        return x.hash < y.hash;
    }
};

// A hash of an element's facts exactly as written (path, key, unit, text), the same on both sides
// for elements that match without any tolerance.
fn subtreeHash(facts: []const Fact) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (facts) |fact| {
        for ([_][]const u8{ fact.path, fact.key, fact.unit, fact.text }) |part| {
            hasher.update(part);
            hasher.update(&.{0});
        }
    }
    return hasher.final();
}

fn matchExact(ppm: f64, group: []const Fact, groups: []const std.ArrayList(Fact), index: []const Hashed, taken: []bool) ?usize {
    const hash = subtreeHash(group);
    var low: usize = 0;
    var high: usize = index.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (index[middle].hash < hash) low = middle + 1 else high = middle;
    }
    while (low < index.len and index[low].hash == hash) : (low += 1) {
        const at = index[low].at;
        if (taken[at] or !sameSubtree(ppm, group, groups[at].items)) continue;
        taken[at] = true;
        return at;
    }
    return null;
}

// Elements of B that match only within a tolerance this many places either side of the same
// position are looked for; further away, the element is filed as regrouped. It keeps the search
// linear however many elements repeat.
const NEAR = 512;

fn matchNear(ppm: f64, group: []const Fact, groups: []const std.ArrayList(Fact), taken: []bool, position: usize) ?usize {
    var distance: usize = 0;
    while (distance <= NEAR) : (distance += 1) {
        const before: ?usize = if (position >= distance) position - distance else null;
        const after: ?usize = if (distance != 0) position + distance else null;
        for ([_]?usize{ before, after }) |candidate| {
            const at = candidate orelse continue;
            if (at >= groups.len or taken[at] or !sameSubtree(ppm, group, groups[at].items)) continue;
            taken[at] = true;
            return at;
        }
    }
    return null;
}

fn firstMz(scratch: std.mem.Allocator, facts: []const Fact) ![]const u8 {
    for (facts) |fact| if (std.mem.eql(u8, fact.key, "MS:1000744")) return std.fmt.allocPrint(scratch, "first at m/z {s}", .{fact.text});
    return "";
}

// Repeated elements whose order carries meaning: a spectrum's precursors run from the nearest
// stage back, and readers take the first as the precursor of the spectrum.
fn ordered(path: []const u8) bool {
    return std.mem.eql(u8, path, "spectrum/precursorList/precursor");
}

fn under(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (path.len > p.len and std.mem.startsWith(u8, path, p) and path[p.len] == '/') return true;
    return false;
}

fn firstOfPath(elements: []const Element, position: usize) bool {
    for (elements[0..position]) |earlier| if (std.mem.eql(u8, earlier.path, elements[position].path)) return false;
    return true;
}

fn countPath(elements: []const Element, path: []const u8) usize {
    var count: usize = 0;
    for (elements) |element| count += @intFromBool(std.mem.eql(u8, element.path, path));
    return count;
}

fn isDirty(report: *const Report, path: []const u8) bool {
    for (report.dirty.items) |dirty| {
        if (std.mem.startsWith(u8, dirty, path) and (dirty.len == path.len or dirty[path.len] == '/')) return true;
    }
    return false;
}

// The facts under each element at `path`, in the order the facts are sorted.
fn subtrees(
    scratch: std.mem.Allocator,
    facts: []const Fact,
    elements: []const Element,
    path: []const u8,
    count: usize,
) ![]std.ArrayList(Fact) {
    const groups = try scratch.alloc(std.ArrayList(Fact), count);
    for (groups) |*group| group.* = .empty;
    // Each element at `path`, numbered in document order.
    const slot = try scratch.alloc(u32, elements.len);
    var next: u32 = 0;
    for (elements, slot) |element, *s| {
        if (std.mem.eql(u8, element.path, path)) {
            s.* = next;
            next += 1;
        } else s.* = NO_PARENT;
    }
    for (facts) |fact| {
        var at = fact.element;
        while (at != NO_PARENT and at < elements.len) : (at = elements[at].parent) {
            if (slot[at] != NO_PARENT) {
                try groups[slot[at]].append(scratch, fact);
                break;
            }
        }
    }
    return groups;
}

fn sameSubtree(ppm: f64, a: []const Fact, b: []const Fact) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!sameGroup(x, y)) return false;
        if (x.unit.len != 0 and y.unit.len != 0 and !std.mem.eql(u8, x.unit, y.unit)) return false;
        if (compareValues(ppm, x, y) == .different) return false;
    }
    return true;
}

// Files the first unmatched element of A against the unused element of B closest to it, under
// the most severe key that differs between them, so the rules and `--set` apply as usual.
fn reportRegrouped(
    report: *Report,
    scratch: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    group: []const Fact,
    others: []const std.ArrayList(Fact),
    taken: []const bool,
) !void {
    var best: ?[]const Fact = null;
    var best_score: usize = 0;
    for (others, taken) |other, used| {
        if (used) continue;
        var score: usize = 0;
        for (group) |x| {
            for (other.items) |y| if (sameGroup(x, y) and compareValues(report.ppm, x, y) != .different) {
                score += 1;
                break;
            };
        }
        if (best == null or score > best_score) {
            best = other.items;
            best_score = score;
        }
    }
    const other = best orelse &.{};
    var key: []const u8 = "element";
    var level: Severity = .ignored;
    for (group) |x| {
        var matched = false;
        for (other) |y| if (sameGroup(x, y) and compareValues(report.ppm, x, y) != .different) {
            matched = true;
            break;
        };
        if (matched) continue;
        const severity = report.rules.severity(x.key);
        if (@intFromEnum(severity) < @intFromEnum(level)) {
            level = severity;
            key = x.key;
        }
    }
    try report.addDirty(
        if (level == .ignored) .major else null,
        .regrouped,
        path,
        key,
        "",
        id,
        try summarize(scratch, path, group),
        try summarize(scratch, path, other),
    );
}

// "MS:1000744=641.29 MS:1000041=2 ...", the facts of one element with paths relative to it.
fn summarize(scratch: std.mem.Allocator, path: []const u8, facts: []const Fact) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (facts, 0..) |fact, i| {
        if (i != 0) try text.append(scratch, ' ');
        const rest = if (fact.path.len > path.len) fact.path[path.len + 1 ..] else "";
        if (rest.len != 0) try text.print(scratch, "{s}/", .{rest});
        try text.print(scratch, "{s}={s}", .{ fact.key, fact.text });
    }
    return text.items;
}

// --- Arrays ---

/// A decoded array: its role key (`array:ACCESSION`), the unit its role term carries, and values.
pub const Role = struct { key: []const u8, unit: []const u8 = "", values: mzml.DecodedArrays.Values };

/// The record's decoded arrays keyed by role. With `copy`, the values are copied into `arena` so
/// they outlive the reader's next record.
pub fn roles(
    arena: std.mem.Allocator,
    record: model.Record,
    groups: []const cv.Group,
    decoded: *const mzml.DecodedArrays,
    copy: bool,
) ![]Role {
    const nodes = record.binaryArrays();
    var list: std.ArrayList(Role) = .empty;
    for (0..decoded.len()) |position| {
        const array = decoded.get(position) orelse continue;
        if (array.source_position >= nodes.len) continue;
        const node = nodes[array.source_position];
        const key = try roleKey(arena, node, groups);
        const unit = try arena.dupe(u8, try arrayUnit(node, groups));
        const values: mzml.DecodedArrays.Values = if (!copy) array.values else switch (array.values) {
            inline else => |slice, tag| @unionInit(mzml.DecodedArrays.Values, @tagName(tag), try arena.dupe(@TypeOf(slice[0]), slice)),
        };
        try list.append(arena, .{ .key = key, .unit = unit, .values = values });
    }
    return list.items;
}

/// Compares two records' arrays, matched by role. `path` names the record kind.
pub fn compareArrays(
    report: *Report,
    arena: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    arrays_a: []const Role,
    arrays_b: []const Role,
) !void {
    // Checked once per record, on the first peak array that differs.
    var order_checked = false;
    var reordered = false;

    for (arrays_a, 0..) |x_raw, position| {
        var y = nth(arrays_b, x_raw.key, rank(arrays_a, position)) orelse {
            try report.add(null, .array_missing, path, x_raw.key, "", id, lengthText(arena, x_raw.values), "");
            continue;
        };
        var x = x_raw;
        if (!std.mem.eql(u8, x.unit, y.unit)) {
            // Seconds and minutes are the same time; anything else is a different meaning.
            if (std.mem.eql(u8, x.unit, SECOND) and std.mem.eql(u8, y.unit, MINUTE)) {
                x.values = try toMinutes(arena, x.values);
            } else if (std.mem.eql(u8, x.unit, MINUTE) and std.mem.eql(u8, y.unit, SECOND)) {
                y.values = try toMinutes(arena, y.values);
            } else if (x.unit.len == 0 or y.unit.len == 0) {
                try report.add(oneSidedUnit(report, x.key, x.unit), .unit, path, x.key, "", id, orDash(x.unit), orDash(y.unit));
            } else {
                try report.add(null, .unit, path, x.key, "", id, x.unit, y.unit);
                continue;
            }
        }
        if (std.meta.activeTag(x.values) != std.meta.activeTag(y.values))
            try report.add(
                .minor,
                .precision,
                path,
                x.key,
                "",
                id,
                @tagName(std.meta.activeTag(x.values)),
                @tagName(std.meta.activeTag(y.values)),
            );
        if (len(x.values) != len(y.values)) {
            try report.add(null, .peak_count, path, x.key, "", id, lengthText(arena, x.values), lengthText(arena, y.values));
            continue;
        }
        const is_mz = std.mem.eql(u8, x.key, "array:MS:1000514");
        const mismatch = firstMismatch(x.values, y.values, if (is_mz) report.ppm else 0);
        const at = mismatch.exact orelse continue;
        const is_peak = std.mem.eql(u8, x.key, "array:MS:1000514") or std.mem.eql(u8, x.key, "array:MS:1000515");
        if (is_peak) {
            if (!order_checked) {
                order_checked = true;
                reordered = try samePeaks(arena, arrays_a, arrays_b);
                // Not a tolerance: readers that deisotope or search the peaks assume rising m/z, and
                // Sage matches other peptides when they fall instead, so the order is a difference
                // at the arrays' severity (major, `--set array:peaks=...`).
                if (reordered) try report.add(null, .peak_order, path, "array:peaks", "m/z and intensity pairs", id, "", "");
            }
            if (reordered) continue;
        }
        const shown = mismatch.beyond orelse at;
        const ta = try std.fmt.allocPrint(arena, "[{d}] {d}", .{ shown, valueAt(x.values, shown) });
        const tb = try std.fmt.allocPrint(arena, "[{d}] {d}", .{ shown, valueAt(y.values, shown) });
        // Counting every differing value costs a pass, so it is done only for a listing.
        var detail: ?ArrayDetail = if (report.sink != null) arrayDetail(x.values, y.values) else null;
        if (detail) |*found| found.shown = shown;
        if (mismatch.beyond == null) {
            const close = sameAt32(valueAt(x.values, at), valueAt(y.values, at));
            try report.addDetailed(.minor, if (close) .narrow else .ppm, path, x.key, "", id, ta, tb, detail);
        } else {
            try report.addDetailed(null, .peak_values, path, x.key, "", id, ta, tb, detail);
        }
    }
    for (arrays_b, 0..) |y, position| {
        if (nth(arrays_a, y.key, rank(arrays_b, position)) == null)
            try report.add(null, .array_extra, path, y.key, "", id, "", lengthText(arena, y.values));
    }
}

// How many arrays before `position` share its key: the second array of one role pairs with the
// second of the other side, not the first again.
fn rank(list: []const Role, position: usize) usize {
    var count: usize = 0;
    for (list[0..position]) |role| count += @intFromBool(std.mem.eql(u8, role.key, list[position].key));
    return count;
}

fn nth(list: []const Role, key: []const u8, wanted: usize) ?Role {
    var count: usize = 0;
    for (list) |role| if (std.mem.eql(u8, role.key, key)) {
        if (count == wanted) return role;
        count += 1;
    };
    return null;
}

fn toMinutes(arena: std.mem.Allocator, values: mzml.DecodedArrays.Values) !mzml.DecodedArrays.Values {
    const out = try arena.alloc(f64, len(values));
    for (out, 0..) |*value, i| value.* = valueAt(values, i) / 60.0;
    return .{ .float64 = out };
}

fn roleKey(arena: std.mem.Allocator, node: model.Node, groups: []const cv.Group) ![]const u8 {
    switch (try model.arrayRole(node, groups)) {
        .mz => return "array:MS:1000514",
        .intensity => return "array:MS:1000515",
        .time => return "array:MS:1000595",
        .other => {},
    }
    var params: cv.EffectiveIterator = .{ .entries = node.params, .groups = groups };
    while (try params.next()) |entry| switch (entry) {
        .cv => |param| {
            const accession = (param.accession orelse continue).raw;
            if (isEncodingTerm(accession)) continue;
            return try std.fmt.allocPrint(arena, "array:{s}", .{accession});
        },
        .user => |param| return try std.fmt.allocPrint(arena, "array:user:{s}", .{param.name orelse ""}),
        .group_ref => {},
    };
    return "array:unknown";
}

// The unit on the array's role term (the first term that is not about encoding).
fn arrayUnit(node: model.Node, groups: []const cv.Group) ![]const u8 {
    var params: cv.EffectiveIterator = .{ .entries = node.params, .groups = groups };
    while (try params.next()) |entry| switch (entry) {
        .cv => |param| {
            const accession = (param.accession orelse continue).raw;
            if (isEncodingTerm(accession)) continue;
            return unitOf(param.unit);
        },
        .user => |param| return unitOf(param.unit),
        .group_ref => {},
    };
    return "";
}

fn isEncodingTerm(accession: []const u8) bool {
    const terms = [_][]const u8{
        // primitives
        "MS:1000519", "MS:1000520", "MS:1000521", "MS:1000522", "MS:1000523",
        // zlib, none
        "MS:1000574", "MS:1000576",
        // numpress
        "MS:1002312", "MS:1002313", "MS:1002314",
        "MS:1002746", "MS:1002747", "MS:1002748",
    };
    for (terms) |term| if (std.mem.eql(u8, accession, term)) return true;
    return false;
}

fn find(list: []const Role, key: []const u8) ?Role {
    for (list) |role| if (std.mem.eql(u8, role.key, key)) return role;
    return null;
}

fn len(values: mzml.DecodedArrays.Values) usize {
    return switch (values) {
        inline else => |slice| slice.len,
    };
}

fn lengthText(arena: std.mem.Allocator, values: mzml.DecodedArrays.Values) []const u8 {
    return std.fmt.allocPrint(arena, "{d} values", .{len(values)}) catch "";
}

fn valueAt(values: mzml.DecodedArrays.Values, at: usize) f64 {
    return switch (values) {
        .float32 => |slice| slice[at],
        .float64 => |slice| slice[at],
        .int32 => |slice| @floatFromInt(slice[at]),
        .int64 => |slice| @floatFromInt(slice[at]),
    };
}

const Mismatch = struct {
    // First index whose values differ at all (beyond what 32-bit storage explains when either
    // side is 32-bit).
    exact: ?usize = null,
    // First index whose values differ beyond the tolerance.
    beyond: ?usize = null,
};

// Finds differing values. `ppm` > 0 compares within that many parts per million (m/z arrays);
// otherwise within 32-bit precision.
fn firstMismatch(a: mzml.DecodedArrays.Values, b: mzml.DecodedArrays.Values, ppm: f64) Mismatch {
    if (a == .float64 and b == .float64 and std.mem.eql(u8, std.mem.sliceAsBytes(a.float64), std.mem.sliceAsBytes(b.float64))) return .{};
    if (a == .float32 and b == .float32 and std.mem.eql(u8, std.mem.sliceAsBytes(a.float32), std.mem.sliceAsBytes(b.float32))) return .{};
    const narrow_only = a == .float32 or b == .float32;
    var result: Mismatch = .{};
    for (0..len(a)) |i| {
        const p = valueAt(a, i);
        const q = valueAt(b, i);
        if (p == q or (std.math.isNan(p) and std.math.isNan(q))) continue;
        const same32 = sameAt32(p, q);
        if (narrow_only and same32) continue;
        if (result.exact == null) result.exact = i;
        const within = same32 or (ppm > 0 and @abs(p - q) <= ppm * 1e-6 * @max(@abs(p), @abs(q)));
        if (!within) {
            result.beyond = i;
            break;
        }
    }
    return result;
}

fn arrayDetail(a: mzml.DecodedArrays.Values, b: mzml.DecodedArrays.Values) ArrayDetail {
    var detail: ArrayDetail = .{ .values = len(a), .differing = 0, .largest = 0, .largest_a = 0, .largest_b = 0 };
    var worst: f64 = -1;
    for (0..len(a)) |i| {
        const p = valueAt(a, i);
        const q = valueAt(b, i);
        if (p == q or (std.math.isNan(p) and std.math.isNan(q))) continue;
        detail.differing += 1;
        const scale = @max(@abs(p), @abs(q));
        const relative = if (std.math.isNan(p) or std.math.isNan(q)) std.math.inf(f64) else if (scale == 0) 0 else @abs(p - q) / scale;
        if (relative > worst) {
            worst = relative;
            detail.largest = i;
            detail.largest_a = p;
            detail.largest_b = q;
        }
    }
    return detail;
}

// Whether both records hold the same (m/z, intensity) pairs in another order. Pairs already in
// the same order are not reordered, even when they differ below 32-bit precision.
fn samePeaks(arena: std.mem.Allocator, arrays_a: []const Role, arrays_b: []const Role) !bool {
    const pa = try pairs(arena, arrays_a) orelse return false;
    const pb = try pairs(arena, arrays_b) orelse return false;
    if (pa.len != pb.len or samePairs(pa, pb)) return false;
    for ([_][][2]f32{ pa, pb }) |list| std.mem.sort([2]f32, list, {}, struct {
        fn less(_: void, x: [2]f32, y: [2]f32) bool {
            return if (x[0] != y[0]) x[0] < y[0] else x[1] < y[1];
        }
    }.less);
    return samePairs(pa, pb);
}

fn samePairs(a: []const [2]f32, b: []const [2]f32) bool {
    for (a, b) |x, y| if (x[0] != y[0] or x[1] != y[1]) return false;
    return true;
}

// The record's (m/z, intensity) pairs at 32-bit precision, in array order.
fn pairs(arena: std.mem.Allocator, list: []const Role) !?[][2]f32 {
    const mz = (find(list, "array:MS:1000514") orelse return null).values;
    const intensity = (find(list, "array:MS:1000515") orelse return null).values;
    if (len(mz) != len(intensity)) return null;
    const out = try arena.alloc([2]f32, len(mz));
    for (out, 0..) |*pair, i| pair.* = .{ @floatCast(valueAt(mz, i)), @floatCast(valueAt(intensity, i)) };
    return out;
}

// --- Tests ---

test "[edge] - [values]: timestamps differing only in trailing zeros are equal" {
    try std.testing.expectEqualStrings(trimFraction("2015-10-14T03:22:49.63Z"), trimFraction("2015-10-14T03:22:49.630Z"));
    try std.testing.expectEqualStrings("2015-10-14T03:22:49", trimFraction("2015-10-14T03:22:49.000Z"));
}

test "[unit] - [values]: last-digit differences are rounding, larger ones are not" {
    try std.testing.expect(lastDigit("79.106", "79.107", 79.106, 79.107, 1, 1));
    try std.testing.expect(!lastDigit("0.5", "0.75", 0.5, 0.75, 1, 1));
    try std.testing.expect(!lastDigit("79", "80", 79, 80, 1, 1));
    try std.testing.expect(lastDigit("1.5e3", "1.5000001e3", 1500, 1500.0001, 1, 1));
    // The shorter spelling must be the longer one rounded: 1.59 rounds to 1.6, not 1.5.
    try std.testing.expect(lastDigit("1.6", "1.59", 1.6, 1.59, 1, 1));
    try std.testing.expect(!lastDigit("1.5", "1.59", 1.5, 1.59, 1, 1));
    try std.testing.expect(!lastDigit("26.11219024658203", "26", 26.11219024658203, 26, 1, 1));
    try std.testing.expect(!lastDigit("6.5", "7", 6.5, 7, 1, 1));
}

test "[unit] - [values]: values equal at 32-bit precision are told apart from real differences" {
    try std.testing.expect(sameAt32(573.290283203125, 573.2902916127172));
    try std.testing.expect(!sameAt32(573.2903, 573.2911));
    try std.testing.expect(sameAt32(0.1853804976, 0.1853804886341095));
}

test "[edge] - [values]: equal NaNs compare as the same and NaN against a number differs" {
    const nan = makeFact("spectrum", "MS:1000285", "", "NaN", "", 0);
    const also_nan = makeFact("spectrum", "MS:1000285", "", "nan", "", 0);
    const number = makeFact("spectrum", "MS:1000285", "", "15869.6875", "", 0);
    try std.testing.expectEqual(Verdict.same, compareValues(1, nan, also_nan));
    try std.testing.expectEqual(Verdict.different, compareValues(1, nan, number));
    // Opposite signs, so the arrays differ as bytes and the NaN check itself decides.
    const a = [_]f64{ std.math.nan(f64), 1 };
    const b = [_]f64{ -std.math.nan(f64), 1 };
    const c = [_]f64{ 1, 1 };
    try std.testing.expectEqual(@as(?usize, null), firstMismatch(.{ .float64 = &a }, .{ .float64 = &b }, 0).exact);
    try std.testing.expectEqual(@as(?usize, 0), firstMismatch(.{ .float64 = &a }, .{ .float64 = &c }, 0).beyond);
}

test "[unit] - [arrays]: peaks in the same order are not reordered when an intensity narrows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mz = [_]f64{ 100, 200, 300 };
    const intensity_a = [_]f64{ 10, 20, 30 };
    // Below 32-bit precision: equal as 32-bit floats, different as 64-bit ones.
    const intensity_b = [_]f64{ 10, 20 * (1 + 5e-9), 30 };
    const a = [_]Role{
        .{ .key = "array:MS:1000514", .values = .{ .float64 = &mz } },
        .{ .key = "array:MS:1000515", .values = .{ .float64 = &intensity_a } },
    };
    const b = [_]Role{
        .{ .key = "array:MS:1000514", .values = .{ .float64 = &mz } },
        .{ .key = "array:MS:1000515", .values = .{ .float64 = &intensity_b } },
    };
    try std.testing.expect(!try samePeaks(arena.allocator(), &a, &b));
    const mz_reversed = [_]f64{ 300, 200, 100 };
    const intensity_reversed = [_]f64{ 30, 20, 10 };
    const c = [_]Role{
        .{ .key = "array:MS:1000514", .values = .{ .float64 = &mz_reversed } },
        .{ .key = "array:MS:1000515", .values = .{ .float64 = &intensity_reversed } },
    };
    try std.testing.expect(try samePeaks(arena.allocator(), &a, &c));
}

test "[property] - [facts]: sorting by path runs gives the same order as one full sort" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    const ion = "spectrum/precursor/selectedIon";
    // Two repeated elements, a path that returns after another, and ties broken by text and unit.
    const facts = [_]Fact{
        makeFact("spectrum", "MS:1000511", "", "2", "", 0),
        makeFact(ion, "MS:1000744", "", "641.29", "", 1),
        makeFact(ion, "MS:1000041", "", "2", "", 1),
        makeFact("spectrum/scan", "MS:1000016", "", "1.5", MINUTE, 2),
        makeFact(ion, "MS:1000744", "", "427.53", "", 3),
        makeFact(ion, "MS:1000041", "", "3", "", 3),
        makeFact("spectrum", "MS:1000285", "", "nan", "", 0),
        makeFact("spectrum", "MS:1000285", "", "17442.45", "", 0),
        makeFact("spectrum", "user:note", "", "b", "", 0),
        makeFact("spectrum", "user:note", "", "a", "", 0),
    };
    var by_runs = facts;
    var full = facts;
    try sortFacts(&report, &by_runs);
    std.mem.sortUnstable(Fact, &full, {}, factLess);
    for (by_runs, full) |x, y| {
        try std.testing.expectEqualStrings(y.path, x.path);
        try std.testing.expectEqualStrings(y.key, x.key);
        try std.testing.expectEqualStrings(y.text, x.text);
    }
}

test "[edge] - [report]: keys past the class limit join one class instead of growing the report" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var key_buffer: [32]u8 = undefined;
    for (0..MAX_CLASSES + 500) |k| {
        report.record = k;
        const key = try std.fmt.bufPrint(&key_buffer, "user:k{d}", .{k});
        try report.add(null, .extra, "spectrum", key, "", "scan=1", "", "v");
    }
    try std.testing.expectEqual(@as(usize, MAX_CLASSES + 1), report.classes.count());
    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    var folded: usize = 0;
    for (classes) |class| if (std.mem.eql(u8, class.key, "(more keys)")) {
        folded = class.records;
    };
    try std.testing.expectEqual(@as(usize, 500), folded);
}

test "[unit] - [facts]: facts compare by value whatever the spelling and order" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var a = [_]Fact{
        makeFact("spectrum/scan", "MS:1000927", "ion injection time", "50", "UO:0000028", 0),
        makeFact("spectrum", "MS:1000511", "ms level", "2", "", 0),
    };
    var b = [_]Fact{
        makeFact("spectrum", "MS:1000511", "ms level", "2", "", 0),
        makeFact("spectrum/scan", "MS:1000927", "ion injection time", "50.000", "UO:0000028", 0),
    };
    try diffFacts(&report, "scan=1", &a, &b);
    try std.testing.expectEqual(@as(usize, 0), report.classes.count());
}

test "[unit] - [facts]: a missing parameter and a changed value are filed with their severity" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var a = [_]Fact{
        makeFact("spectrum", "MS:1000511", "ms level", "2", "", 0),
        makeFact("spectrum/precursorList/precursor/selectedIonList/selectedIon", "MS:1000041", "charge state", "2", "", 0),
    };
    var b = [_]Fact{makeFact("spectrum", "MS:1000511", "ms level", "1", "", 0)};
    try diffFacts(&report, "scan=1", &a, &b);
    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    try std.testing.expectEqual(@as(usize, 2), classes.len);
    for (classes) |class| try std.testing.expectEqual(Severity.critical, class.severity);
}

test "[edge] - [values]: seconds read as minutes keep the precision they were printed with" {
    // 3000.12 s is 50.002 min; "50.1" min is 5.9 s away, far beyond the last printed digit.
    const a = makeFact("spectrum/scan", "MS:1000016", "", "3000.12", SECOND, 0);
    const b = makeFact("spectrum/scan", "MS:1000016", "", "50.1", MINUTE, 0);
    try std.testing.expectEqual(Verdict.different, compareValues(1, a, b));
    const c = makeFact("spectrum/scan", "MS:1000016", "", "50.00200", MINUTE, 0);
    try std.testing.expect(compareValues(1, a, c) != .different);
}

test "[unit] - [facts]: a unit b drops is at most major, except a time's, and one b adds is minor" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    const MZ = "MS:1000040";
    // Both keys are critical; the values match, so only the unit differs.
    const cases = [_]struct { key: []const u8, a: []const u8, b: []const u8, severity: Severity }{
        // m/z is the selected ion's only unit: dropping it shows the cap.
        .{ .key = "MS:1000744", .a = MZ, .b = "", .severity = .major },
        .{ .key = "MS:1000744", .a = "", .b = MZ, .severity = .minor },
        // A time without its unit could be seconds or minutes.
        .{ .key = "MS:1000016", .a = MINUTE, .b = "", .severity = .critical },
        .{ .key = "MS:1000016", .a = SECOND, .b = "", .severity = .critical },
        .{ .key = "MS:1000016", .a = "", .b = MINUTE, .severity = .minor },
    };
    for (cases) |case| {
        var report = Report.init(allocator, &rules, 3);
        defer report.deinit();
        var a = [_]Fact{makeFact("spectrum/scan", case.key, "", "1.5", case.a, 0)};
        var b = [_]Fact{makeFact("spectrum/scan", case.key, "", "1.5", case.b, 0)};
        try diffFacts(&report, "scan=1", &a, &b);
        const classes = try report.sorted(allocator);
        defer allocator.free(classes);
        try std.testing.expectEqual(@as(usize, 1), classes.len);
        try std.testing.expectEqual(Kind.unit, classes[0].kind);
        try std.testing.expectEqual(case.severity, classes[0].severity);
    }
}

test "[unit] - [facts]: a total ion current that drops to zero is critical, other changes major" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    const cases = [_]struct { b: []const u8, severity: Severity }{
        .{ .b = "0", .severity = .critical },
        .{ .b = "0.0", .severity = .critical },
        .{ .b = "1492781.9", .severity = .major },
    };
    for (cases) |case| {
        var report = Report.init(allocator, &rules, 3);
        defer report.deinit();
        var a = [_]Fact{makeFact("spectrum", "MS:1000285", "", "746390.94", "", 0)};
        var b = [_]Fact{makeFact("spectrum", "MS:1000285", "", case.b, "", 0)};
        try diffFacts(&report, "scan=1", &a, &b);
        const classes = try report.sorted(allocator);
        defer allocator.free(classes);
        try std.testing.expectEqual(@as(usize, 1), classes.len);
        try std.testing.expectEqual(case.severity, classes[0].severity);
    }
}

test "[unit] - [report]: --set wins over a severity the check chose itself" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    try rules.override("array:MS:1000515", .ignored);
    try rules.override("MS:1000285", .minor);
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    try report.add(.minor, .precision, "spectrum", "array:MS:1000515", "", "scan=1", "float64", "float32");
    try report.add(.critical, .value, "spectrum", "MS:1000285", "", "scan=1", "746390.94", "0");
    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqual(Severity.minor, classes[0].severity);
}

test "[unit] - [regrouping]: values that trade places between repeated elements are found" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const ion = "spectrum/precursor/selectedIon";
    const elements = [_]Element{
        .{ .path = "spectrum", .parent = NO_PARENT },
        .{ .path = ion, .parent = 0 },
        .{ .path = ion, .parent = 0 },
    };
    var a = [_]Fact{
        makeFact(ion, "MS:1000744", "", "641.29", "", 1), makeFact(ion, "MS:1000041", "", "2", "", 1),
        makeFact(ion, "MS:1000744", "", "427.53", "", 2), makeFact(ion, "MS:1000041", "", "3", "", 2),
    };
    var b = [_]Fact{
        makeFact(ion, "MS:1000744", "", "641.29", "", 1), makeFact(ion, "MS:1000041", "", "3", "", 1),
        makeFact(ion, "MS:1000744", "", "427.53", "", 2), makeFact(ion, "MS:1000041", "", "2", "", 2),
    };
    try diffFacts(&report, "scan=1", &a, &b);
    try std.testing.expectEqual(@as(usize, 0), report.classes.count());
    try diffGrouping(&report, scratch.allocator(), "scan=1", &a, &elements, &b, &elements);
    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqual(Kind.regrouped, classes[0].kind);
    try std.testing.expectEqual(Severity.critical, classes[0].severity);
    try std.testing.expectEqualStrings("MS:1000041", classes[0].key);
}

test "[edge] - [regrouping]: thousands of reordered elements pair exactly, and one swap among them is found" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const path = "spectrum/scanList/scan";
    const n = 3000;
    var elements: std.ArrayList(Element) = .empty;
    try elements.append(arena, .{ .path = "spectrum", .parent = NO_PARENT });
    for (0..n) |_| try elements.append(arena, .{ .path = path, .parent = 0 });
    var a: std.ArrayList(Fact) = .empty;
    var b: std.ArrayList(Fact) = .empty;
    for (0..n) |k| {
        const time = try std.fmt.allocPrint(arena, "{d}.5", .{k});
        const window = try std.fmt.allocPrint(arena, "{d}", .{k * 2});
        try a.append(arena, makeFact(path, "MS:1000016", "", time, MINUTE, @intCast(k + 1)));
        try a.append(arena, makeFact(path, "MS:1000501", "", window, "", @intCast(k + 1)));
        // B holds the same scans in reverse order.
        try b.append(arena, makeFact(path, "MS:1000016", "", time, MINUTE, @intCast(n - k)));
        try b.append(arena, makeFact(path, "MS:1000501", "", window, "", @intCast(n - k)));
    }
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    try diffFacts(&report, "scan=1", a.items, b.items);
    try diffGrouping(&report, arena, "scan=1", a.items, elements.items, b.items, elements.items);
    try std.testing.expectEqual(@as(usize, 0), report.classes.count());
    // Two windows trade places between scans: every value is still there, the pairs are not.
    var swapped = Report.init(allocator, &rules, 3);
    defer swapped.deinit();
    for (b.items) |*fact| {
        if (std.mem.eql(u8, fact.text, "10"))
            fact.* = makeFact(path, "MS:1000501", "", "12", "", fact.element)
        else if (std.mem.eql(u8, fact.text, "12"))
            fact.* = makeFact(path, "MS:1000501", "", "10", "", fact.element);
    }
    try diffFacts(&swapped, "scan=1", a.items, b.items);
    try diffGrouping(&swapped, arena, "scan=1", a.items, elements.items, b.items, elements.items);
    const classes = try swapped.sorted(allocator);
    defer allocator.free(classes);
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqual(Kind.regrouped, classes[0].kind);
}

test "[edge] - [regrouping]: the same elements in another order are not regrouped" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const ion = "spectrum/precursor/selectedIon";
    const elements = [_]Element{
        .{ .path = "spectrum", .parent = NO_PARENT },
        .{ .path = ion, .parent = 0 },
        .{ .path = ion, .parent = 0 },
    };
    var a = [_]Fact{
        makeFact(ion, "MS:1000744", "", "641.29", "", 1), makeFact(ion, "MS:1000041", "", "2", "", 1),
        makeFact(ion, "MS:1000744", "", "427.53", "", 2), makeFact(ion, "MS:1000041", "", "3", "", 2),
    };
    var b = [_]Fact{
        makeFact(ion, "MS:1000744", "", "427.530", "", 1), makeFact(ion, "MS:1000041", "", "3", "", 1),
        makeFact(ion, "MS:1000744", "", "641.29", "", 2),  makeFact(ion, "MS:1000041", "", "2", "", 2),
    };
    try diffFacts(&report, "scan=1", &a, &b);
    try diffGrouping(&report, scratch.allocator(), "scan=1", &a, &elements, &b, &elements);
    try std.testing.expectEqual(@as(usize, 0), report.classes.count());
}

test "[unit] - [regrouping]: precursors in another order are reported, once" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    var report = Report.init(allocator, &rules, 3);
    defer report.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const precursor = "spectrum/precursorList/precursor";
    const ion = "spectrum/precursorList/precursor/selectedIonList/selectedIon";
    const elements = [_]Element{
        .{ .path = "spectrum", .parent = NO_PARENT },
        .{ .path = precursor, .parent = 0 },
        .{ .path = ion, .parent = 1 },
        .{ .path = precursor, .parent = 0 },
        .{ .path = ion, .parent = 3 },
    };
    var a = [_]Fact{
        makeFact(ion, "MS:1000744", "", "641.29", "", 2), makeFact(ion, "MS:1000041", "", "2", "", 2),
        makeFact(ion, "MS:1000744", "", "427.53", "", 4), makeFact(ion, "MS:1000041", "", "3", "", 4),
    };
    // The MS1 precursor first: a reader taking the first precursor gets 427.53 at charge 3.
    var b = [_]Fact{
        makeFact(ion, "MS:1000744", "", "427.53", "", 2), makeFact(ion, "MS:1000041", "", "3", "", 2),
        makeFact(ion, "MS:1000744", "", "641.29", "", 4), makeFact(ion, "MS:1000041", "", "2", "", 4),
    };
    try diffFacts(&report, "scan=1", &a, &b);
    try diffGrouping(&report, scratch.allocator(), "scan=1", &a, &elements, &b, &elements);
    const classes = try report.sorted(allocator);
    defer allocator.free(classes);
    try std.testing.expectEqual(@as(usize, 1), classes.len);
    try std.testing.expectEqual(Kind.element_order, classes[0].kind);
    try std.testing.expectEqual(Severity.major, classes[0].severity);
    try std.testing.expectEqualStrings("precursorOrder", classes[0].key);
}

test "[unit] - [form]: integers are an optional sign and digits only" {
    for ([_][]const u8{ "2", "+2", "-3", " 17 ", "0" }) |text| try std.testing.expect(integerSpelling(text));
    for ([_][]const u8{ "2.0", "2e0", "", "+", "two", "0x2" }) |text| try std.testing.expect(!integerSpelling(text));
}

test "[unit] - [facts]: a term in place of another of the same kind is one difference" {
    const allocator = std.testing.allocator;
    var rules = Rules.init(allocator);
    defer rules.deinit();
    const path = "spectrum/scanList/scan/instrumentConfiguration/componentList/analyzer";
    const cases = [_]struct { a: []const u8, b: []const u8, kinds: []const Kind, severity: Severity }{
        // FT-ICR against orbitrap: two analyzers.
        .{ .a = "MS:1000079", .b = "MS:1000484", .kinds = &.{.term}, .severity = .major },
        // ion trap against radial ejection linear ion trap, a kind of ion trap.
        .{ .a = "MS:1000264", .b = "MS:1000083", .kinds = &.{.specific}, .severity = .minor },
        // positive against negative scan.
        .{ .a = "MS:1000130", .b = "MS:1000129", .kinds = &.{.term}, .severity = .critical },
        // An analyzer against a detector (inductive detector) are not one thing written two ways.
        .{ .a = "MS:1000079", .b = "MS:1000624", .kinds = &.{ .missing, .extra }, .severity = .major },
    };
    for (cases) |case| {
        var report = Report.init(allocator, &rules, 3);
        defer report.deinit();
        var a = [_]Fact{makeFact(path, case.a, "", "", "", 0)};
        var b = [_]Fact{makeFact(path, case.b, "", "", "", 0)};
        try diffFacts(&report, "scan=1", &a, &b);
        const classes = try report.sorted(allocator);
        defer allocator.free(classes);
        try std.testing.expectEqual(case.kinds.len, classes.len);
        for (classes) |class| {
            const known = for (case.kinds) |kind| {
                if (kind == class.kind) break true;
            } else false;
            try std.testing.expect(known);
        }
        try std.testing.expectEqual(case.severity, classes[0].severity);
    }
}

test "[edge] - [report]: clipped examples end on a character boundary" {
    const text = "a" ** 159 ++ "é";
    try std.testing.expectEqual(@as(usize, 159), clip(text).len);
}
