const std = @import("std");

const GlobalVarTracker = enum(u54) {
    a,
    b,
    c,
};

var my_global_var_pog: usize = 4;
var my_global_var_2: GlobalVarTracker = .a;

fn doPrintLoop(val: usize) void {
    const x: i32 = 4 + @as(i32, @intCast(val));
    const y: i32 = 5 + @as(i32, @intCast(val));
    my_global_var_pog += 1;
    std.debug.print("loop iter {d} {d} {d} {d} {any}\n", .{ x, y, val, my_global_var_pog, my_global_var_2 });
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
