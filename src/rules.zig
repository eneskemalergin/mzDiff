//! Severity of a difference, by the key it concerns: a PSI-MS accession, `user:NAME` for a
//! userParam, `@NAME` for an attribute, or `array:ROLE` for a binary array.
//!
//! - critical: the data itself or what it means (peaks, MS level, polarity, times, precursor m/z
//!   and charge, activation method, spectrum type, instrument model).
//! - major: values a search engine or a reader commonly uses (isolation offsets, energies, filter
//!   string, injection time, scan window, summary values, FAIMS, source checksum).
//! - minor: everything else, including unknown terms and user parameters.
//! - ignored: bookkeeping that differs between tools by design (ids, offsets, counts, software,
//!   file locations). Ignored keys are dropped when facts are collected.
//!
//! Exact keys come first, then ancestry in the bundled PSI-MS vocabulary, then the default.

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
    // Spectrum identity and data.
    // ms level
    .{ "MS:1000511", .critical },
    // scan start time
    .{ "MS:1000016", .critical },
    // isolation window target m/z
    .{ "MS:1000827", .critical },
    // selected ion m/z
    .{ "MS:1000744", .critical },
    // m/z (historical selected ion m/z)
    .{ "MS:1000040", .critical },
    // charge state
    .{ "MS:1000041", .critical },
    // m/z array
    .{ "array:MS:1000514", .critical },
    // intensity array
    .{ "array:MS:1000515", .critical },
    // time array
    .{ "array:MS:1000595", .critical },

    // Values readers use.
    // isolation window lower offset
    .{ "MS:1000828", .major },
    // isolation window upper offset
    .{ "MS:1000829", .major },
    // collision energy
    .{ "MS:1000045", .major },
    // supplemental collision energy
    .{ "MS:1002680", .major },
    // filter string
    .{ "MS:1000512", .major },
    // ion injection time
    .{ "MS:1000927", .major },
    // scan window lower limit
    .{ "MS:1000501", .major },
    // scan window upper limit
    .{ "MS:1000500", .major },
    // total ion current
    .{ "MS:1000285", .major },
    // base peak m/z
    .{ "MS:1000504", .major },
    // base peak intensity
    .{ "MS:1000505", .major },
    // lowest observed m/z
    .{ "MS:1000528", .major },
    // highest observed m/z
    .{ "MS:1000527", .major },
    // FAIMS compensation voltage
    .{ "MS:1001581", .major },
    // peak intensity (selected ion)
    .{ "MS:1000042", .major },
    // SHA-1 of the source file
    .{ "MS:1000569", .major },
    // instrument serial number
    .{ "MS:1000529", .major },
    .{ "@spectrumRef", .major },
    // spectra paired out of their files' order
    .{ "order", .major },
    // a spectrum's precursors in another order: the first is the one readers take
    .{ "precursorOrder", .major },
    // the native id of spectra paired by scan number
    .{ "id", .major },
    // the indexedmzML wrapper, present or not
    .{ "indexed", .major },
    // the wrapper's tail: present, and pointing at the index
    .{ "indexListOffset", .major },
    // a scan naming a configuration the header lacks
    .{ "instrumentConfiguration", .major },
    .{ "@startTimeStamp", .major },

    // Bookkeeping that differs between tools by design.
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
    // checked through the arrays
    .{ "@defaultArrayLength", .ignored },
    .{ "@arrayLength", .ignored },
    .{ "@encodedLength", .ignored },
    .{ "@nativeID", .ignored },
    .{ "@externalSpectrumID", .ignored },
    // custom unreleased software tool
    .{ "MS:1000799", .ignored },
    // conversion to mzML
    .{ "MS:1000544", .ignored },
    // peak picking (a processing claim, not data)
    .{ "MS:1000035", .ignored },
    // spectrum title
    .{ "MS:1000796", .ignored },
});

// Checked in order; the first ancestor that matches decides.
const ANCESTORS = [_]struct { []const u8, Severity }{
    // dissociation method
    .{ "MS:1000044", .critical },
    // scan polarity
    .{ "MS:1000465", .critical },
    // spectrum representation
    .{ "MS:1000525", .critical },
    // spectrum type
    .{ "MS:1000559", .critical },
    // instrument model
    .{ "MS:1000031", .critical },
    // mass analyzer type
    .{ "MS:1000443", .major },
    // ionization type
    .{ "MS:1000008", .major },
    // detector type
    .{ "MS:1000026", .major },
    // chromatogram type
    .{ "MS:1000626", .major },
    // binary data type
    .{ "MS:1000518", .ignored },
    // binary data compression type
    .{ "MS:1000572", .ignored },
    // data file checksum type (other than SHA-1, kept above)
    .{ "MS:1000561", .ignored },
};

// The most accessions whose ancestry severity is remembered.
const CACHE_LIMIT = 16384;

pub const Rules = struct {
    allocator: std.mem.Allocator,
    vocabulary: ?*const cv.Vocabulary,
    overrides: std.StringHashMapUnmanaged(Severity) = .empty,
    cache: std.StringHashMapUnmanaged(Severity) = .empty,

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
        var overrides = self.overrides.keyIterator();
        while (overrides.next()) |key| self.allocator.free(key.*);
        self.overrides.deinit(self.allocator);
    }

    /// A copy with the same overrides and an empty cache, for use on another thread.
    pub fn clone(self: *const Rules) !Rules {
        var copy = Rules.init(self.allocator);
        errdefer copy.deinit();
        var it = self.overrides.iterator();
        while (it.next()) |entry| try copy.override(entry.key_ptr.*, entry.value_ptr.*);
        return copy;
    }

    /// Sets a key's severity from the command line; it wins over every built-in rule.
    pub fn override(self: *Rules, key: []const u8, level: Severity) !void {
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        const entry = try self.overrides.getOrPut(self.allocator, owned);
        if (entry.found_existing) self.allocator.free(owned);
        entry.value_ptr.* = level;
    }

    /// The severity `--set` gave `key`, which wins over any a check chooses itself.
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
        // A file with endless distinct accessions must not grow the cache without bound.
        if (self.cache.count() >= CACHE_LIMIT) return found;
        const owned = self.allocator.dupe(u8, key) catch return found;
        self.cache.put(self.allocator, owned, found) catch self.allocator.free(owned);
        return found;
    }

    /// The term's name in the bundled vocabulary, or null for unknown accessions.
    pub fn name(self: *const Rules, key: []const u8) ?[]const u8 {
        const accession = if (std.mem.startsWith(u8, key, "array:")) key["array:".len..] else key;
        const vocabulary = self.vocabulary orelse return null;
        const match = vocabulary.lookup(accession) orelse return null;
        return match.term.name;
    }

    /// Whether `accession` is `parent` or one of its descendants in the bundled vocabulary.
    pub fn isA(self: *const Rules, accession: []const u8, parent: []const u8) bool {
        const vocabulary = self.vocabulary orelse return false;
        return vocabulary.isA(accession, parent, 10_000) catch false;
    }

    fn byAncestry(self: *const Rules, accession: []const u8) Severity {
        const vocabulary = self.vocabulary orelse return .minor;
        for (ANCESTORS) |rule| {
            const is_a = vocabulary.isA(accession, rule[0], 10_000) catch false;
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
}

test "[unit] - [severity]: ancestry classifies activation methods, polarity, and models" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try std.testing.expect(rules.vocabulary != null);
    // beam-type CID
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000422"));
    // ETD
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000598"));
    // positive scan
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1000130"));
    // Orbitrap Fusion
    try std.testing.expectEqual(Severity.critical, rules.severity("MS:1002416"));
    // zlib
    try std.testing.expectEqual(Severity.ignored, rules.severity("MS:1000574"));
}

test "[unit] - [severity]: overrides win over every built-in rule" {
    var rules = Rules.init(std.testing.allocator);
    defer rules.deinit();
    try rules.override("MS:1000511", .ignored);
    try std.testing.expectEqual(Severity.ignored, rules.severity("MS:1000511"));
}
