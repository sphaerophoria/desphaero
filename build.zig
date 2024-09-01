const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const debuggee = b.addExecutable(.{
        .name = "debugee",
        .root_source_file = b.path("src/debugee.zig"),
        .target = target,
        .optimize = optimize,
    });


    b.installArtifact(debuggee);

    const desphaero = b.addExecutable(.{
        .name = "desphaero",
        .root_source_file = b.path("src/desphaero.zig"),
        .target = target,
        .optimize = optimize,
    });
    desphaero.linkLibC();


    b.installArtifact(desphaero);
}
