//! Reads one input on its own thread: opens the file, reads the header, checks the indexed
//! wrapper's tail, and turns each record into an `Item`: its facts (with each scan's instrument
//! configuration), its elements, and its decoded arrays, in memory the item owns. Items cross to
//! the comparing thread through a bounded queue, and their arenas come back for reuse, so memory
//! stays bounded by the queue depth.
//!
//! `Side`, `Item`, `Stream`, `produce`, and `drain` are public for `main.zig` and `pair.zig` only.

const std = @import("std");
const zmz = @import("zmz");
const mzml = zmz.mzml;
const model = mzml.model;
const cv = mzml.cv;

const compare = @import("compare.zig");
const rules_mod = @import("rules.zig");

const Fact = compare.Fact;
const Rules = rules_mod.Rules;

// One input: its file, reader, and header. The header is read on the main thread; records are
// read by `produce` on the side's own thread. Never moved after `open`: the reader points into
// `input`.
pub const Side = struct {
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
    // The reader's diagnostic for the failure, when it gave one; set before `failure`.
    reason_buffer: [512]u8 = undefined,
    reason: []const u8 = "",
    spectra: usize = 0,
    chromatograms: usize = 0,
    // Each instrument configuration's component facts by id, for the scans that refer to it.
    configurations: std.StringHashMapUnmanaged([]const Fact) = .empty,
    default_configuration: ?[]const u8 = null,
    // What is wrong with the indexed wrapper's tail, or null.
    trailer: ?[]const u8 = null,
    configuration_arena: std.heap.ArenaAllocator = undefined,
    // The repeating strings of this side's facts, shared by its items; outlives every item.
    interner: compare.Interner = undefined,

    pub fn open(self: *Side, allocator: std.mem.Allocator, io: std.Io, path: []const u8, rules: *const Rules) !void {
        self.path = path;
        self.failure = null;
        self.reason = "";
        self.spectra = 0;
        self.chromatograms = 0;
        self.file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer self.file.close(io);
        // A directory opens like a file on Linux and fails only at the first read, obscurely.
        if ((try self.file.stat(io)).kind == .directory) return error.IsDir;
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
        self.interner = .init(allocator);
        errdefer self.interner.deinit();
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

    pub fn close(self: *Side, io: std.Io) void {
        self.configuration_arena.deinit();
        self.interner.deinit();
        self.freeSpares();
        self.rules.deinit();
        self.decoded.deinit();
        self.reader.deinit();
        self.file.close(io);
    }

    // Keeps the reader's diagnostic for `err`, cut to the buffer, for main to report.
    fn explain(self: *Side, err: anyerror) anyerror {
        if (self.reader.diagnostic()) |diagnostic| {
            var writer = std.Io.Writer.fixed(&self.reason_buffer);
            writer.print("{f}", .{diagnostic}) catch {};
            self.reason = writer.buffered();
        }
        return err;
    }
};

// Records in flight per side; bounds memory to this many decoded records each.
const QUEUE_DEPTH = 16;

// One record, read and reduced to facts and arrays on its side's thread, owning its memory.
pub const Item = struct {
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
    // Which spectrum of its file this is (1 for the first); 0 for a chromatogram.
    position: usize = 0,

    pub fn free(self: *const Item, allocator: std.mem.Allocator) void {
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
pub fn produce(allocator: std.mem.Allocator, io: std.Io, side: *Side) void {
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
        .interner = &side.interner,
    };
    try collector.add(record.node, "", compare.NO_PARENT);
    // Paths, keys, names, and units are stable already; values borrow from the reader's record, so
    // copy them before it moves on.
    var type_key: []const u8 = "";
    for (facts.items) |*fact| {
        fact.text = try arena.dupe(u8, fact.text);
        const on_chromatogram = record.node.kind == .chromatogram and std.mem.eql(u8, fact.path, "chromatogram");
        if (on_chromatogram and type_key.len == 0 and rules.isA(fact.key, "MS:1000626"))
            type_key = fact.key;
    }
    // Each scan's instrument configuration, named or the run's default, as component facts. The
    // configuration facts live as long as the side; only the element they belong to is new. The
    // scan elements and the scan nodes are both in document order, so one pass walks them together.
    var scans = Scans.of(record.node);
    for (elements.items, 0..) |element, position| {
        if (!std.mem.eql(u8, element.path, SCAN_PATH)) continue;
        const scan = scans.next() orelse continue;
        const ref = scan.attribute("instrumentConfigurationRef") orelse side.default_configuration orelse continue;
        const components = side.configurations.get(ref) orelse {
            // The reference borrows from the reader's record, which the reader thread reuses for
            // the next one while this item waits to be compared: copy it like every other value.
            const owned = try arena.dupe(u8, ref);
            try facts.append(arena, compare.makeFact(SCAN_PATH, "instrumentConfiguration", "", owned, "", @intCast(position)));
            continue;
        };
        for (components) |component| {
            var fact = component;
            fact.element = @intCast(position);
            try facts.append(arena, fact);
        }
    }
    try noteArrayForm(&facts, arena, record.node, header.groups);
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

// Arrays in MS-Numpress, as a fact on the record (text and name are literals, so they outlive the
// reader's record): the values compare the same, but readers without Numpress fail (Sage reads
// the bytes as plain floats or drops the array). Base64 broken by whitespace is the other such
// form, but zmz decodes the text as it streams and keeps none of it, so it is a zmz gap.
fn noteArrayForm(facts: *std.ArrayList(Fact), arena: std.mem.Allocator, node: model.Node, groups: []const cv.Group) !void {
    const list = node.child(.binary_data_array_list) orelse return;
    for (list.children) |array| {
        if (array.kind != .binary_data_array) continue;
        var params: cv.EffectiveIterator = .{ .entries = array.params, .groups = groups };
        while (params.next() catch null) |entry| {
            if (entry != .cv) continue;
            const accession = if (entry.cv.accession) |a| a.raw else continue;
            for (NUMPRESS) |known| if (std.mem.eql(u8, accession, known)) {
                return facts.append(arena, compare.makeFact(node.kind.xmlName(), "form:numpress", "arrays in MS-Numpress", "", "", 0));
            };
        }
    }
}

// MS-Numpress linear, positive integer, and short logged float, alone and followed by zlib.
const NUMPRESS = [_][]const u8{ "MS:1002312", "MS:1002313", "MS:1002314", "MS:1002746", "MS:1002747", "MS:1002748" };

// A spectrum's scan nodes, in document order.
const Scans = struct {
    children: []const model.Node,
    at: usize = 0,

    fn of(spectrum: model.Node) Scans {
        const list = spectrum.child(.scan_list) orelse return .{ .children = &.{} };
        return .{ .children = list.children };
    }

    fn next(self: *Scans) ?model.Node {
        while (self.at < self.children.len) {
            const child = self.children[self.at];
            self.at += 1;
            if (child.kind == .scan) return child;
        }
        return null;
    }
};

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

// The consumer's view of one side: the item at hand, pulled from the side's queue.
pub const Stream = struct {
    side: *Side,
    io: std.Io,
    current: ?Item = null,
    position: usize = 0,

    pub fn advance(self: *Stream) void {
        self.current = self.side.queue.getOne(self.io) catch null;
        if (self.current) |*item| switch (item.kind) {
            .spectrum => {
                self.side.spectra += 1;
                self.position += 1;
                item.position = self.position;
            },
            .chromatogram => self.side.chromatograms += 1,
            else => {},
        };
    }

    // Hands over the current item; the caller frees it.
    pub fn take(self: *Stream) Item {
        const item = self.current.?;
        self.current = null;
        return item;
    }

    pub fn isSpectrum(self: *const Stream) bool {
        return if (self.current) |item| item.kind == .spectrum else false;
    }
};

pub fn drain(allocator: std.mem.Allocator, io: std.Io, side: *Side) void {
    while (side.queue.getOne(io)) |item| item.free(allocator) else |_| {}
}

// --- Tests ---

test "[unit] - [pairing]: scan numbers come from the native id" {
    try std.testing.expectEqual(@as(?u64, 42), scanNumber("controllerType=0 controllerNumber=1 scan=42"));
    try std.testing.expectEqual(@as(?u64, null), scanNumber("index=3"));
}
