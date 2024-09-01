const std = @import("std");

fn doGoodbye() void {
    std.debug.print("Goodbye\n", .{});
}

pub fn main() !void {
    std.debug.print("Hello world\n", .{});
    std.debug.print("address of doGoodbye: 0x{x}\n", .{&doGoodbye});
    const content: [*]const u8 = @ptrCast(&doGoodbye);
    std.debug.print("content of doGoodbye: {x}\n", .{std.mem.bytesAsValue(u32, content[0..4]).*});
    doGoodbye();
}
