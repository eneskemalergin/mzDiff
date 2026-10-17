//! Builds `mzdiff`, the mzML comparator, against zmz, and defines the `run` and `test` steps.
//! ReleaseFast builds are stripped, the only form that ships or is measured.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zmz = b.dependency("zmz", .{ .target = target, .optimize = optimize }).module("zmz");
    // The version in build.zig.zon, for --version and the JSON output. Its name differs from
    // zmz's own `version` option: two options files with equal contents are one file to Zig, and
    // one file cannot root two modules.
    const options = b.addOptions();
    options.addOption([]const u8, "mzdiff_version", @import("build.zig.zon").version);
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{.{ .name = "zmz", .module = zmz }},
    });
    module.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "mzdiff", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run mzdiff: zig build run -- A.mzML B.mzML").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the mzdiff tests").dependOn(&b.addRunArtifact(tests).step);
}
