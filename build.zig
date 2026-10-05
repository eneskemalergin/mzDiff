//! Builds `mzdiff`, the mzML comparator, against zmz, and defines the `test` step. ReleaseFast
//! builds are stripped, the only form that ships or is measured.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zmz = b.dependency("zmz", .{ .target = target, .optimize = optimize }).module("zmz");
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{.{ .name = "zmz", .module = zmz }},
    });
    b.installArtifact(b.addExecutable(.{ .name = "mzdiff", .root_module = module }));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the mzdiff tests").dependOn(&b.addRunArtifact(tests).step);
}
