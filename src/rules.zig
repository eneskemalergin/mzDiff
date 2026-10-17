//! Severity of a difference, by the key it concerns: a PSI-MS accession, `user:NAME` for a
//! userParam, `@NAME` for an attribute, or `array:ACCESSION` for a binary array.
//!
//! Critical is the data or what it means; major, values readers commonly use; minor, everything
//! else; ignored, bookkeeping tools write differently by design, dropped when facts are collected.
//! Overrides from `--set` win, then exact keys; any other array is major, and any other accession
//! takes the severity of its ancestry in the bundled PSI-MS vocabulary, else minor. Ancestry
//! answers are cached for at most `CACHE_LIMIT` accessions.

const std = @import("std");
const zmz = @import("zmz");
const cv = zmz.mzml.cv;

pub const Severity = enum {
    critical,
    major,
    minor,
    ignored,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .critical => "CRITICAL",
            .major => "MAJOR",
            .minor => "minor",
            .ignored => "ignored",
        };
    }
};

const EXACT = std.StaticStringMap(Severity).initComptime(.{
    .{ "MS:1000511", .critical },
    .{ "MS:1000016", .critical },
    .{ "MS:1000827", .critical },
    .{ "MS:1000744", .critical },
    .{ "MS:1000040", .critical },
    .{ "MS:1000041", .critical },
    .{ "array:MS:1000514", .critical },
    .{ "array:MS:1000515", .critical },
    .{ "array:MS:1000595", .critical },

    .{ "MS:1000828", .major },
    .{ "MS:1000829", .major },
    .{ "MS:1000045", .major },
    .{ "MS:1002680", .major },
    .{ "MS:1000512", .major },
    .{ "MS:1000927", .major },
    .{ "MS:1000501", .major },
    .{ "MS:1000500", .major },
    .{ "MS:1000285", .major },
    .{ "MS:1000504", .major },
    .{ "MS:1000505", .major },
    .{ "MS:1000528", .major },
    .{ "MS:1000527", .major },
    .{ "MS:1001581", .major },
    .{ "MS:1000042", .major },
    .{ "MS:1000569", .major },
    .{ "MS:1000529", .major },
    .{ "MS:1000928", .major },
    .{ "@spectrumRef", .major },
    .{ "order", .major },
    .{ "precursorOrder", .major },
    .{ "id", .major },
    .{ "indexed", .major },
    .{ "indexListOffset", .major },
    .{ "instrumentConfiguration", .major },

    .{ "form:integer", .critical },
    .{ "form:paramGroup", .major },
    .{ "form:numpress", .major },
    .{ "@startTimeStamp", .major },

    .{ "@id", .ignored },
    .{ "@index", .ignored },
    .{ "@count", .ignored },
    .{ "@ref", .ignored },
    .{ "@order", .ignored },
    .{ "@location", .ignored },
    .{ "@name", .ignored },
    .{ "@version", .ignored },
    .{ "@softwareRef", .ignored },
    .{ "@sourceFileRef", .ignored },
    .{ "@dataProcessingRef", .ignored },
    .{ "@defaultDataProcessingRef", .ignored },
    .{ "@defaultInstrumentConfigurationRef", .ignored },
    .{ "@defaultSourceFileRef", .ignored },
    .{ "@instrumentConfigurationRef", .ignored },
    .{ "@scanSettingsRef", .ignored },
    .{ "@defaultArrayLength", .ignored },
    .{ "@arrayLength", .ignored },
    .{ "@encodedLength", .ignored },
    .{ "@nativeID", .ignored },
    .{ "@externalSpectrumID", .ignored },
    .{ "MS:1000799", .ignored },
    .{ "MS:1000544", .ignored },
    .{ "MS:1000035", .ignored },
    .{ "MS:1000796", .ignored },
});

const ANCESTORS = [_]struct { []const u8, Severity }{
    .{ "MS:1000044", .critical },
    .{ "MS:1000465", .critical },
    .{ "MS:1000525", .critical },
    .{ "MS:1000559", .critical },
    .{ "MS:1000031", .critical },
    .{ "MS:1000443", .major },
    .{ "MS:1000008", .major },
    .{ "MS:1000026", .major },
    .{ "MS:1000626", .major },
    .{ "MS:1000518", .ignored },
    .{ "MS:1000572", .ignored },
    .{ "MS:1000561", .ignored },
};

const INTEGER_TYPES = [_][]const u8{
    "xsd:int",             "xsd:integer",            "xsd:long",            "xsd:short",
    "xsd:byte",            "xsd:nonNegativeInteger", "xsd:positiveInteger", "xsd:nonPositiveInteger",
    "xsd:negativeInteger", "xsd:unsignedInt",        "xsd:unsignedLong",    "xsd:unsignedShort",
    "xsd:unsignedByte",
};

const CACHE_LIMIT = 16384;

pub const Rules = struct {
    allocator: std.mem.Allocator,
    vocabulary: ?*const cv.Vocabulary,
    overrides: std.StringHashMapUnmanaged(Severity) = .empty,
    cache: std.StringHashMapUnmanaged(Severity) = .empty,
    integers: std.StringHashMapUnmanaged(bool) = .empty,

    pub fn init(allocator: std.mem.Allocator) Rules {
        var vocabulary: ?*const cv.Vocabulary = null;
        for (cv.Resolver.BUNDLED) |*resource| {
            if (std.mem.eql(u8, resource.identity.key, "psi-ms")) vocabulary = resource;
        }
        return .{ .allocator = allocator, .vocabulary = vocabulary };
    }

    pub fn deinit(self: *Rules) void {
        var keys = self.cache.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.cache.deinit(self.allocator);
        var integer_keys = self.integers.keyIterator();
        while (integer_keys.next()) |key| self.allocator.free(key.*);
        self.integers.deinit(self.allocator);
        var overrides = self.overrides.keyIterator();
        while (overrides.next()) |key| self.allocator.free(key.*);
        self.overrides.deinit(self.allocator);
    }

    pub fn clone(self: *const Rules) !Rules {
        var copy = Rules.init(self.allocator);
        errdefer copy.deinit();
        var it = self.overrides.iterator();
        while (it.next()) |entry| try copy.override(entry.key_ptr.*, entry.value_ptr.*);
        return copy;
    }

    pub fn override(self: *Rules, key: []const u8, level: Severity) !void {
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        const entry = try self.overrides.getOrPut(self.allocator, owned);
        if (entry.found_existing) self.allocator.free(owned);
        entry.value_ptr.* = level;
    }

    pub fn overridden(self: *const Rules, key: []const u8) ?Severity {
        return self.overrides.get(key);
    }

    pub fn severity(self: *Rules, key: []const u8) Severity {
        if (self.overrides.get(key)) |found| return found;
        if (EXACT.get(key)) |found| return found;
        if (std.mem.startsWith(u8, key, "array:")) return .major;
        if (!std.mem.startsWith(u8, key, "MS:")) return .minor;
        if (self.cache.get(key)) |found| return found;
        const found = self.byAncestry(key);
        if (self.cache.count() >= CACHE_LIMIT) return found;
        const owned = self.allocator.dupe(u8, key) catch return found;
        self.cache.put(self.allocator, owned, found) catch self.allocator.free(owned);
        return found;
    }

    pub fn integerTyped(self: *Rules, key: []const u8) bool {
        if (!std.mem.startsWith(u8, key, "MS:")) return false;
        if (self.integers.get(key)) |found| return found;
        const found = self.byValueType(key);
        if (self.integers.count() >= CACHE_LIMIT) return found;
        const owned = self.allocator.dupe(u8, key) catch return found;
        self.integers.put(self.allocator, owned, found) catch self.allocator.free(owned);
        return found;
    }

    fn byValueType(self: *const Rules, accession: []const u8) bool {
        const vocabulary = self.vocabulary orelse return false;
        var slots: [8][]const u8 = undefined;
        const types = vocabulary.valueTypes(accession, &slots, 1_000) catch return false;
        if (types.len == 0) return false;
        for (types) |value_type| {
            const integer = for (INTEGER_TYPES) |known| {
                if (std.mem.eql(u8, value_type, known)) break true;
            } else false;
            if (!integer) return false;
        }
        return true;
    }

    pub fn category(self: *const Rules, key: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, key, "MS:")) return null;
        const vocabulary = self.vocabulary orelse return null;
        for (ANCESTORS) |rule| {
            if (rule[1] == .ignored) continue;
            if (vocabulary.isA(key, rule[0]) catch false) return rule[0];
        }
        return null;
    }

    pub fn name(self: *const Rules, key: []const u8) ?[]const u8 {
        const accession = if (std.mem.startsWith(u8, key, "array:")) key["array:".len..] else key;
        const vocabulary = self.vocabulary orelse return null;
        const match = vocabulary.lookup(accession) orelse return null;
        return match.term.name();
    }

    pub fn isA(self: *const Rules, accession: []const u8, parent: []const u8) bool {
        const vocabulary = self.vocabulary orelse return false;
        return vocabulary.isA(accession, parent) catch false;
    }

    fn byAncestry(self: *const Rules, accession: []const u8) Severity {
        const vocabulary = self.vocabulary orelse return .minor;
        for (ANCESTORS) |rule| {
            const is_a = vocabulary.isA(accession, rule[0]) catch false;
            if (is_a) return rule[1];
        }
        return .minor;
    }
};

// --- Tests ---

test "[unit] - [severity]: exact keys win over ancestry and the default" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000511"));
    try std.testing.expectEqual(Severity.ignored, rules.severity("@index"));
    try std.testing.expectEqual(Severity.minor, rules.severity("user:Something"));
    try std.testing.expectEqual(Severity.major, rules.severity("array:MS:1000617"));
    try std.testing.expectEqual(Severity.major, rules.severity("MS:1000928"));
}

test "[unit] - [severity]: ancestry classifies activation methods, polarity, and models" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try std.testing.expect(rules.vocabulary != null);
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000422"));
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000598"));
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000130"));
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1002416"));
    try std.testing.expectEqual(Severity.ignored, rules.severity("MS:1000574"));
}

test "[unit] - [severity]: overrides win over every built-in rule" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try rules.override("MS:1000511", .ignored);
    try std.testing.expectEqual(Severity.ignored, rules.severity("MS:1000511"));
}

test "[unit] - [types]: charge and ms level are integer typed, times and m/z are not" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try std.testing.expect(rules.integerTyped("MS:1000041"));
    try std.testing.expect(rules.integerTyped("MS:1000511"));
    try std.testing.expect(!rules.integerTyped("MS:1000016"));
    try std.testing.expect(!rules.integerTyped("MS:1000744"));
    try std.testing.expect(!rules.integerTyped("user:charge"));
    try std.testing.expect(rules.integerTyped("MS:1000041"));
}
