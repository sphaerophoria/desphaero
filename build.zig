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

    return b.allocator.dupe(std.Build.LazyPath, &.{app_moc, b.path("gui/gui.cpp")});
}

fn getTerminalGuiSourceFiles(b: *std.Build, qt_install_dir: std.Build.LazyPath) ![]std.Build.LazyPath {
     //rcc gui.qrc -o resources.cpp && moc app.h -o app.moc.cpp && g++ -o gui gui.cpp resources.cpp app.moc.cpp -lQt5Gui -lQt5Qml -lQt5Core

    const moc = std.Build.Step.Run.create(b, "moc");
    moc.addFileArg(qt_install_dir.path(b, "libexec/moc"));
    moc.addArg("-o");
    const app_moc = moc.addOutputFileArg("terminal.moc.cpp");
    moc.addFileArg(b.path("gui/terminal.h"));

    return b.allocator.dupe(std.Build.LazyPath, &.{app_moc, b.path("gui/terminal.cpp")});
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

    const terminal_test = b.addExecutable(.{
        .name = "terminal_test",
        .root_source_file = b.path("src/terminal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_test.addCSourceFiles(.{
        .root = b.path("vendor/libvterm-0.3.3/src"),
        .files = &.{
            "encoding.c",
            "state.c",
            "unicode.c",
            "pen.c",
            "parser.c",
            "mouse.c",
            "screen.c",
            "keyboard.c",
            "vterm.c",
        },
    });
    terminal_test.addIncludePath(b.path("vendor/libvterm-0.3.3/include"));
    terminal_test.addIncludePath(b.path("vendor/libvterm-0.3.3/src"));
    terminal_test.addIncludePath(qt_install_dir.path(b, "include"));
    terminal_test.addIncludePath(b.path("gui"));

    terminal_test.linkLibC();
    terminal_test.linkLibCpp();

    terminal_test.addLibraryPath(qt_install_dir.path(b, "lib"));
    terminal_test.linkSystemLibrary("Qt6Core");
    terminal_test.linkSystemLibrary("Qt6Gui");
    terminal_test.linkSystemLibrary("Qt6Qml");

    const terminal_gui_files = try getTerminalGuiSourceFiles(b, qt_install_dir);
    for (terminal_gui_files) |f| {
        terminal_test.addCSourceFile(.{
            .file = f,
        });
    }

    b.installArtifact(terminal_test);
}
