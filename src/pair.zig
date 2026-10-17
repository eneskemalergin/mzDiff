//! Pairs the records of the two sides and compares each pair. Spectra pair by native id in any
//! vendor's format (by scan number when the two files' formats differ, by position when neither
//! works) through a bounded join that assumes no order: each spectrum waits in its side's table
//! until the other side yields the same key, and beyond `WINDOW` waiting records or `WINDOW_BYTES`
//! the oldest are reported missing or extra. Chromatograms pair by id through the same join, then
//! the leftovers by type.

const std = @import("std");

const compare = @import("compare.zig");
const read = @import("read.zig");

const Item = read.Item;
const Kind = compare.Kind;
const Report = compare.Report;

const KeyKind = enum { id, scan, position };

fn keyKind(a: ?Item, b: ?Item) KeyKind {
    const x = a orelse return .position;
    const y = b orelse return .position;
    if (x.kind != .spectrum or y.kind != .spectrum) return .position;
    if (sameIdFields(x.id, y.id)) return .id;
    if (x.scan != null and y.scan != null) return .scan;
    return .position;
}

fn sameIdFields(a: []const u8, b: []const u8) bool {
    var fields_a = std.mem.tokenizeScalar(u8, a, ' ');
    var fields_b = std.mem.tokenizeScalar(u8, b, ' ');
    while (true) {
        const x = fields_a.next();
        const y = fields_b.next();
        if (x == null or y == null) return x == null and y == null;
        const name_x = x.?[0 .. std.mem.indexOfScalar(u8, x.?, '=') orelse return false];
        const name_y = y.?[0 .. std.mem.indexOfScalar(u8, y.?, '=') orelse return false];
        if (!std.mem.eql(u8, name_x, name_y)) return false;
    }
}

fn pairingKey(item: *const Item, kind: KeyKind) ![]const u8 {
    const arena = item.arena.allocator();
    return switch (kind) {
        .id => item.id,
        .scan => if (item.scan) |scan|
            try std.fmt.allocPrint(arena, "scan={d}", .{scan})
        else
            try std.fmt.allocPrint(arena, "id={s}", .{item.id}),
        .position => try std.fmt.allocPrint(arena, "{d}", .{item.position}),
    };
}

const Pending = struct {
    const Waiting = struct { item: Item, seq: u64, bytes: usize };
    const Entry = struct { key: []u8, seq: u64 };

    waiting: std.StringHashMapUnmanaged(Waiting) = .empty,
    queue: std.ArrayList(Entry) = .empty,
    head: usize = 0,
    bytes: usize = 0,

    fn contains(self: *const Pending, key: []const u8) bool {
        return self.waiting.contains(key);
    }

    fn count(self: *const Pending) usize {
        return self.waiting.count();
    }

    fn put(self: *Pending, allocator: std.mem.Allocator, key: []const u8, item: Item, seq: u64) !void {
        const owned = try allocator.dupe(u8, key);
        errdefer allocator.free(owned);
        try self.queue.append(allocator, .{ .key = owned, .seq = seq });
        errdefer self.queue.items.len -= 1;
        const bytes = item.arena.queryCapacity();
        try self.waiting.put(allocator, owned, .{ .item = item, .seq = seq, .bytes = bytes });
        self.bytes += bytes;
    }

    fn take(self: *Pending, allocator: std.mem.Allocator, key: []const u8) ?Item {
        const found = self.waiting.fetchRemove(key) orelse return null;
        self.trim(allocator);
        self.bytes -= found.value.bytes;
        return found.value.item;
    }

    fn full(self: *const Pending) bool {
        return self.count() > WINDOW or (self.count() > 1 and self.bytes > WINDOW_BYTES);
    }

    fn oldest(self: *Pending, allocator: std.mem.Allocator) ?Item {
        self.trim(allocator);
        if (self.head == self.queue.items.len) return null;
        const entry = self.queue.items[self.head];
        const found = self.waiting.fetchRemove(entry.key).?;
        self.head += 1;
        allocator.free(entry.key);
        self.trim(allocator);
        self.bytes -= found.value.bytes;
        return found.value.item;
    }

    fn trim(self: *Pending, allocator: std.mem.Allocator) void {
        while (self.head < self.queue.items.len) {
            const entry = self.queue.items[self.head];
            if (self.waiting.get(entry.key)) |live| if (live.seq == entry.seq) break;
            allocator.free(entry.key);
            self.head += 1;
        }
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
    }

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        var it = self.waiting.valueIterator();
        while (it.next()) |live| live.item.free(allocator);
        for (self.queue.items[self.head..]) |entry| allocator.free(entry.key);
        self.waiting.deinit(allocator);
        self.queue.deinit(allocator);
    }
};

const WINDOW = 1024;
const WINDOW_BYTES = 64 << 20;

pub const Counts = struct { spectra: usize = 0, chromatograms: usize = 0, stopped_early: bool = false };

pub fn run(allocator: std.mem.Allocator, report: *Report, a: *read.Stream, b: *read.Stream, max_spectra: ?usize) !Counts {
    var counts: Counts = .{};
    var kept: std.ArrayList(Item) = .empty;
    defer {
        for (kept.items) |item| item.free(allocator);
        kept.deinit(allocator);
    }
    var kept_b: std.ArrayList(Item) = .empty;
    defer {
        for (kept_b.items) |item| item.free(allocator);
        kept_b.deinit(allocator);
    }
    var chromatograms_a: Pending = .{};
    defer chromatograms_a.deinit(allocator);
    var chromatograms_b: Pending = .{};
    defer chromatograms_b.deinit(allocator);
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var pending_a: Pending = .{};
    defer pending_a.deinit(allocator);
    var pending_b: Pending = .{};
    defer pending_b.deinit(allocator);
    a.advance();
    b.advance();
    const kind = keyKind(a.current, b.current);
    var seq: u64 = 0;
    var last: ?[2]usize = null;
    while (a.isSpectrum() or b.isSpectrum()) {
        if (max_spectra) |limit| if (counts.spectra >= limit) {
            counts.stopped_early = true;
            break;
        };
        inline for (.{ .{ a, &pending_a, &pending_b, true }, .{ b, &pending_b, &pending_a, false } }) |entry| {
            const stream = entry[0];
            if (stream.isSpectrum()) {
                const item = stream.take();
                stream.advance();
                seq += 1;
                const in_a = entry[3];
                const key = pairingKey(&item, kind) catch |err| {
                    item.free(allocator);
                    return err;
                };
                if (entry[2].take(allocator, key)) |partner| {
                    const x = if (in_a) item else partner;
                    const y = if (in_a) partner else item;
                    defer x.free(allocator);
                    defer y.free(allocator);
                    _ = scratch_state.reset(.retain_capacity);
                    report.record += 1;
                    comparePair(report, scratch, kind, x, y, &last) catch |err| return err;
                    counts.spectra += 1;
                } else if (entry[1].contains(key)) {
                    defer item.free(allocator);
                    reportUnpaired(report, item, in_a) catch |err| return err;
                } else {
                    entry[1].put(allocator, key, item, seq) catch |err| {
                        item.free(allocator);
                        return err;
                    };
                    while (entry[1].full()) {
                        const old = entry[1].oldest(allocator).?;
                        defer old.free(allocator);
                        reportUnpaired(report, old, in_a) catch |err| return err;
                    }
                }
            }
        }
    }
    if (counts.stopped_early) return counts;
    inline for (.{ .{ &pending_a, true }, .{ &pending_b, false } }) |entry| {
        while (entry[0].oldest(allocator)) |item| {
            defer item.free(allocator);
            reportUnpaired(report, item, entry[1]) catch |err| return err;
        }
    }
    while (a.current != null or b.current != null) {
        inline for (.{ .{ a, &chromatograms_a, &chromatograms_b, true }, .{ b, &chromatograms_b, &chromatograms_a, false } }) |entry| {
            const stream = entry[0];
            if (stream.current != null) {
                const item = stream.take();
                stream.advance();
                seq += 1;
                const in_a = entry[3];
                if (item.kind != .chromatogram) {
                    defer item.free(allocator);
                    try reportUnpaired(report, item, in_a);
                } else if (entry[2].take(allocator, item.id)) |partner| {
                    const x = if (in_a) item else partner;
                    const y = if (in_a) partner else item;
                    defer x.free(allocator);
                    defer y.free(allocator);
                    _ = scratch_state.reset(.retain_capacity);
                    try compareChromatogram(report, scratch, x, y);
                    counts.chromatograms += 1;
                } else if (entry[1].contains(item.id)) {
                    defer item.free(allocator);
                    try reportUnpaired(report, item, in_a);
                } else {
                    entry[1].put(allocator, item.id, item, seq) catch |err| {
                        item.free(allocator);
                        return err;
                    };
                    while (entry[1].full()) {
                        const old = entry[1].oldest(allocator).?;
                        defer old.free(allocator);
                        try reportUnpaired(report, old, in_a);
                    }
                }
            }
        }
    }
    inline for (.{ .{ &chromatograms_a, &kept }, .{ &chromatograms_b, &kept_b } }) |entry| {
        while (entry[0].oldest(allocator)) |item| {
            entry[1].append(allocator, item) catch |err| {
                item.free(allocator);
                return err;
            };
        }
    }
    _ = scratch_state.reset(.retain_capacity);
    counts.chromatograms += try pairByType(report, scratch, kept.items, kept_b.items);
    return counts;
}

fn comparePair(report: *Report, scratch: std.mem.Allocator, kind: KeyKind, x: Item, y: Item, last: *?[2]usize) !void {
    if (last.*) |previous| if ((x.position > previous[0]) != (y.position > previous[1])) {
        var ta: [32]u8 = undefined;
        var tb: [32]u8 = undefined;
        try report.add(
            null,
            .order,
            "spectrum",
            "order",
            "spectrum order",
            x.id,
            std.fmt.bufPrint(&ta, "spectrum {d}", .{x.position}) catch "",
            std.fmt.bufPrint(&tb, "spectrum {d}", .{y.position}) catch "",
        );
    };
    last.* = .{ x.position, y.position };
    if (kind == .scan and !std.mem.eql(u8, x.id, y.id))
        try report.add(null, .id_mismatch, "spectrum", "id", "native id", x.id, x.id, y.id);
    try compare.diffFacts(report, x.id, x.facts, y.facts);
    try compare.diffGrouping(report, scratch, x.id, x.facts, x.elements, y.facts, y.elements);
    try compare.compareArrays(report, scratch, x.id, "spectrum", x.arrays, y.arrays);
}

fn reportUnpaired(report: *Report, item: Item, in_a: bool) !void {
    report.record += 1;
    const kind: Kind = if (in_a) .record_missing else .record_extra;
    const spectrum = item.kind != .chromatogram;
    const what = if (spectrum) "spectrum" else "chromatogram";
    try report.add(if (spectrum) .critical else .major, kind, what, "@id", what, item.id, if (in_a) item.id else "", if (in_a) "" else item.id);
}

fn compareChromatogram(report: *Report, scratch: std.mem.Allocator, x: Item, y: Item) !void {
    report.record += 1;
    try compare.diffFacts(report, x.id, x.facts, y.facts);
    try compare.diffGrouping(report, scratch, x.id, x.facts, x.elements, y.facts, y.elements);
    try compare.compareArrays(report, scratch, x.id, "chromatogram", x.arrays, y.arrays);
}

fn pairByType(report: *Report, scratch: std.mem.Allocator, a: []Item, b: []Item) !usize {
    var paired: usize = 0;
    for (a) |*x| {
        const y = match(b, x) orelse {
            try reportUnpaired(report, x.*, true);
            continue;
        };
        y.used = true;
        try compareChromatogram(report, scratch, x.*, y.*);
        paired += 1;
    }
    for (b) |y| if (!y.used) try reportUnpaired(report, y, false);
    return paired;
}

fn match(list: []Item, x: *const Item) ?*Item {
    if (x.type.len == 0) return null;
    for (list) |*y| if (!y.used and std.mem.eql(u8, y.type, x.type)) return y;
    return null;
}

// --- Tests ---

test "[unit] - [pairing]: native ids with the same fields pair by the whole id" {
    try std.testing.expect(sameIdFields("controllerType=0 controllerNumber=1 scan=5", "controllerType=0 controllerNumber=1 scan=9"));
    try std.testing.expect(sameIdFields("function=2 process=0 scan=1", "function=3 process=0 scan=1"));
    try std.testing.expect(sameIdFields("sample=1 period=1 cycle=22 experiment=1", "sample=1 period=1 cycle=3 experiment=2"));
    try std.testing.expect(!sameIdFields("controllerType=0 controllerNumber=1 scan=5", "scan=5"));
    try std.testing.expect(!sameIdFields("scan=19", "sample=1 period=1 cycle=22 experiment=1"));
    try std.testing.expect(!sameIdFields("index=3", "index"));
}
