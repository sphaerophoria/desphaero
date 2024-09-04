const std = @import("std");

pub fn build(b: *std.Build) !void {
    const check = b.step("check", "");

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
    desphaero.linkSystemLibrary("dwarf");
    desphaero.linkLibC();


    b.installArtifact(desphaero);


    const dwarf_test = b.addExecutable(.{
        .name = "dwarf_test",
        .root_source_file = b.path("src/dwarf_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dwarf_test.linkSystemLibrary("dwarf");
    dwarf_test.linkLibC();

    const check_dwarf_test = try b.allocator.create(std.Build.Step.Compile);
    check_dwarf_test.* = dwarf_test.*;
    check.dependOn(&check_dwarf_test.step);

    b.installArtifact(dwarf_test);
}
