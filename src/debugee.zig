const std = @import("std");

fn doPrintLoop(val: usize) void {
    std.debug.print("loop iter {d}\n", .{val});
}

fn doPrintLoop2(val: usize) void {
    std.debug.print("other loop iter {d}\n", .{val});
}

pub fn main() !void {
    std.debug.print("Hello world\n", .{});

    for (0..5) |i| {
        doPrintLoop(i);
        doPrintLoop2(i);
    }
    std.debug.print("Goodbye\n", .{});
}
