const std = @import("std");

fn doPrintLoop(val: usize) void {
    std.debug.print("loop iter {d}\n", .{val});
}

pub fn main() !void {
    std.debug.print("Hello world\n", .{});
    std.debug.print("address of doPrintLoop: 0x{x}\n", .{&doPrintLoop});

    for (0..5) |i| {
        doPrintLoop(i);
    }
    std.debug.print("Goodbye\n", .{});
}
