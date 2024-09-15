const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("terminal_gui.h");
});
const libvterm = @import("vterm.zig");
const Terminal = @import("Terminal.zig");

fn waitThenExit(terminal: *Terminal, pid: std.posix.pid_t) !void {
    std.time.sleep(2 * std.time.ns_per_s);
    try terminal.io.pressKey('e');
    try terminal.io.pressKey('x');
    try terminal.io.pressKey('i');
    try terminal.io.pressKey('t');
    try terminal.io.pressKey('\n');

    _ = pid;
    //try std.posix.kill(pid, std.os.linux.SIG.TERM);
    // _ = std.posix.waitpid(pid, 0);
    try terminal.io.exit();
}

fn runTerminal(alloc: Allocator, terminal: *Terminal, gui: ?*c.TerminalEmulatorState) !void {
    while (true) {
        try terminal.step();
        const snapshot = try terminal.getScreenSnapshot(alloc);
        //defer snapshot.deinit();

        std.debug.assert(snapshot.metadata.len == snapshot.glyphs.len);
        const c_metadata = try alloc.alloc(c.GlyphMetadata, snapshot.metadata.len);
        defer alloc.free(c_metadata);

        const c_glyphs = try alloc.alloc(c.Range, snapshot.glyphs.len);
        defer alloc.free(c_glyphs);

        for (0..snapshot.glyphs.len) |i| {
            c_glyphs[i] = .{
                .start = snapshot.glyphs[i].start,
                .end = snapshot.glyphs[i].end,
            };

            c_metadata[i] = .{
                .r = snapshot.metadata[i].fg_color.r,
                .g = snapshot.metadata[i].fg_color.g,
                .b = snapshot.metadata[i].fg_color.b,
            };
        }

        const snapshot_c = c.ScreenSnapshot{
            .string_buf = snapshot.string_buf.ptr,
            .string_buf_len = snapshot.string_buf.len,
            .glyphs = c_glyphs.ptr,
            .metadata = c_metadata.ptr,
            .glyphs_len = snapshot.glyphs.len,
            .width = snapshot.width,
        };

        c.setSnapshot(gui, &snapshot_c);
    }
}

pub fn main() !void {
    var fd: c_int = 0;
    const pid = c.forkpty(&fd, null, null, null);
    if (pid == 0) {
        std.posix.execveZ("/usr/bin/env", &.{ "/usr/bin/env", "bash", "--noprofile", null }, &.{null}) catch {
            std.debug.print("exec failed\n", .{});
        };
    } else {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        const alloc = gpa.allocator();

        var terminal = try Terminal.init(alloc, fd);
        defer terminal.deinit();

        const gui = c.makeGui(&terminal.io);

        const t = try std.Thread.spawn(.{}, runTerminal, .{ alloc, &terminal, gui });
        defer t.join();

        // FIXME: ignore error?
        _ = c.runGui(gui);
    }
}
