const std = @import("std");

const Allocator = std.mem.Allocator;
const elf = @import("elf.zig");
const debuginfo = @import("debuginfo.zig");
const Debugger = @import("Debugger.zig");
const gui = @import("gui.zig");

pub const std_options = std.Options{
    .log_level = .warn,
};

fn printPidMaps(alloc: Allocator, pid: std.os.linux.pid_t) void {
    var path_buf: [1024]u8 = undefined;
    const maps_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid});
    const f = try std.fs.openFileAbsolute(maps_path, .{});
    defer f.close();

    const maps_data = try f.readToEndAlloc(alloc, 1e9);
    defer alloc.free(maps_data);

    std.debug.print("Current maps:\n{s}\n", .{maps_data});
}

const Args = struct {
    breakpoint_names: []const []const u8,
    breakpoint_offsets: []i64,
    exe: [:0]const u8,

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        defer it.deinit();

        const process_name = it.next() orelse "desphaero";

        const exe = it.next() orelse {
            print("exe not provided\n", .{});
            help(process_name);
        };

        var breakpoint_names = std.ArrayList([]const u8).init(alloc);
        defer breakpoint_names.deinit();

        var breakpoint_offsets = std.ArrayList(i64).init(alloc);
        defer breakpoint_offsets.deinit();

        while (it.next()) |breakpoint_s| {
            try breakpoint_names.append(try alloc.dupe(u8, breakpoint_s));

            const breakpoint_offs_s = it.next() orelse {
                print("Breakpoint {s} has no offset\n", .{breakpoint_s});
                help(process_name);
            };

            const breakpoint_offs = std.fmt.parseInt(i64, breakpoint_offs_s, 0) catch {
                print("Breakpoint offset {s} is not a valid i64\n", .{breakpoint_offs_s});
                help(process_name);
            };

            try breakpoint_offsets.append(breakpoint_offs);
        }

        return .{
            .exe = try alloc.dupeZ(u8, exe),
            .breakpoint_names = try breakpoint_names.toOwnedSlice(),
            .breakpoint_offsets = try breakpoint_offsets.toOwnedSlice(),
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
        for (self.breakpoint_names) |name| {
            alloc.free(name);
        }
        alloc.free(self.breakpoint_offsets);
        alloc.free(self.breakpoint_names);
        alloc.free(self.exe);
    }

    fn help(process_name: []const u8) noreturn {
        print("Usage: {s} [exe] [<breakpoint name> <breakpoint offs>]...\n", .{process_name});
        std.process.exit(1);
    }

    fn print(comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print(fmt, args) catch {};
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit(alloc);

    //_ = c.runGui();

    var debugger = try Debugger.init(alloc, args.exe);
    defer debugger.deinit();

    for (args.breakpoint_names, 0..) |name, i| {
        const breakpoint = debugger.elf_metadata.fn_addresses.get(name) orelse {
            std.debug.print("No fn with name {s}\n", .{name});
            continue;
        };

        const offs = args.breakpoint_offsets[i];

        // FIXME: API abuse
        try debugger.pending_breakpoints.put(debugger.alloc, Debugger.addu64i64(breakpoint, offs), {});
    }

    try gui.run(alloc, &debugger);

    if (true) return;
    try debugger.launch();
    while (true) {
        const status = try debugger.wait();
        switch (status) {
            .stopped => |_| {
                if (debugger.regs.rip == debugger.elf_metadata.entry) {
                    std.debug.print("Setting up breakpoint\n", .{});
                    for (args.breakpoint_names, 0..) |name, i| {
                        const breakpoint = debugger.elf_metadata.fn_addresses.get(name) orelse {
                            std.debug.print("No fn with name {s}\n", .{name});
                            continue;
                        };

                        const offs = args.breakpoint_offsets[i];

                        try debugger.setBreakpoint(Debugger.addu64i64(breakpoint, offs));
                    }
                    try debugger.cont();
                } else {
                    std.debug.print("in wait: 0x{x}\n", .{debugger.regs.rip});
                    var loc = try debugger.sourceLocation();
                    defer loc.deinit(alloc);
                    std.debug.print("Hit breakpoint at {s}:{d}\n", .{ loc.path, loc.line });
                    try debugger.printLocals();

                    for (0..2) |_| {
                        _ = try debugger.stepInto();

                        var step_loc = try debugger.sourceLocation();
                        defer step_loc.deinit(alloc);
                        std.debug.print("stepped to {s}:{d}\n", .{ step_loc.path, step_loc.line });

                        try debugger.printLocals();
                    }
                    try debugger.cont();
                }
            },
            .finished => {
                std.debug.print("Process exited\n", .{});
                break;
            },
        }
    }
}
