const std = @import("std");

fn makeQtLazyPath(b: *std.Build) !std.Build.LazyPath {
    const dep = b.dependency("qt", .{});
    const generated = try b.allocator.create(std.Build.GeneratedFile);
    generated.* = std.Build.GeneratedFile{
        .step = &dep.builder.install_tls.step,
        .path = dep.builder.install_path,
    };
    return .{
        .generated = .{
            .file = generated,
        },
    };
}

fn getGuiSourceFiles(b: *std.Build, qt_install_dir: std.Build.LazyPath) ![]std.Build.LazyPath {
    const moc = std.Build.Step.Run.create(b, "moc");
    moc.addFileArg(qt_install_dir.path(b, "libexec/moc"));
    moc.addArg("-o");
    const app_moc = moc.addOutputFileArg("app.moc.cpp");
    moc.addFileArg(b.path("gui/app.h"));

    return b.allocator.dupe(std.Build.LazyPath, &.{ app_moc, b.path("gui/gui.cpp") });
}

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

    const qt_install_dir = try makeQtLazyPath(b);
    const gui_sources = try getGuiSourceFiles(b, qt_install_dir);

    const desphaero = b.addExecutable(.{
        .name = "desphaero",
        .root_source_file = b.path("src/desphaero.zig"),
        .target = target,
        .optimize = optimize,
    });
    desphaero.linkSystemLibrary("libdwarf");
    desphaero.linkSystemLibrary("z");
    desphaero.linkSystemLibrary("zstd");
    desphaero.linkLibC();

    desphaero.addLibraryPath(qt_install_dir.path(b, "lib"));
    desphaero.linkSystemLibrary("Qt6Core");
    desphaero.linkSystemLibrary("Qt6Qml");
    desphaero.linkSystemLibrary("Qt6Gui");
    desphaero.addIncludePath(b.path("gui"));
    desphaero.addIncludePath(qt_install_dir.path(b, "include"));
    desphaero.linkLibCpp();
    for (gui_sources) |s| {
        desphaero.addCSourceFile(.{
            .file = s,
        });
    }

    b.installArtifact(desphaero);

    const dwarf_test = b.addExecutable(.{
        .name = "dwarf_test",
        .root_source_file = b.path("src/dwarf_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dwarf_test.linkSystemLibrary("libdwarf");
    dwarf_test.linkSystemLibrary("z");
    dwarf_test.linkSystemLibrary("zstd");
    dwarf_test.linkLibC();
    const check_dwarf_test = try b.allocator.create(std.Build.Step.Compile);
    check_dwarf_test.* = dwarf_test.*;
    check.dependOn(&check_dwarf_test.step);

    b.installArtifact(dwarf_test);
}
