const std = @import("std");
const Allocator = std.mem.Allocator;
const elf = @import("elf.zig");
const c = @cImport({
    @cInclude("sys/user.h");
});

fn printPidMaps(alloc: Allocator, pid: std.os.linux.pid_t) void {
    var path_buf: [1024]u8 = undefined;
    const maps_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid});
    const f = try std.fs.openFileAbsolute(maps_path, .{});
    defer f.close();

    const maps_data = try f.readToEndAlloc(alloc, 1e9);
    defer alloc.free(maps_data);

    std.debug.print("Current maps:\n{s}\n", .{maps_data});
}

const DebugStatus = union(enum) {
    stopped: struct {
        regs: c.user_regs_struct,
        siginfo: std.os.linux.siginfo_t,
    },
    finished,
};

const Debugger = struct {
    const int3 = 0xcc;

    alloc: Allocator,
    exe: [:0]const u8,
    pid: std.posix.pid_t = 0,

    breakpoints: std.AutoHashMapUnmanaged(u64, u8) = .{},

    regs: c.user_regs_struct = undefined,
    last_signum: i32 = 0,

    pub fn init(alloc: Allocator, exe: [:0]const u8) Debugger {
        return .{
            .alloc = alloc,
            .exe = exe,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit(self.alloc);
    }

    pub fn launch(self: *Debugger) !void {
        const pid = try std.posix.fork();
        if (pid == 0) {
            try std.posix.ptrace(std.os.linux.PTRACE.TRACEME, 0, undefined, undefined);
            std.posix.execveZ(self.exe, &.{null}, &.{null}) catch {
                std.log.err("Exec error", .{});
            };
        } else {
            self.pid = pid;
        }
    }

    pub fn wait(self: *Debugger) !DebugStatus {
        const ret = std.posix.waitpid(self.pid, 0);

        if (!std.os.linux.W.IFSTOPPED(ret.status)) {
            self.pid = 0;
            return .finished;
        }

        var regs: c.user_regs_struct = undefined;
        try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, self.pid, 0, @intFromPtr(&regs));

        var siginfo: std.os.linux.siginfo_t = undefined;
        try std.posix.ptrace(std.os.linux.PTRACE.GETSIGINFO, self.pid, 0, @intFromPtr(&siginfo));

        self.regs = regs;
        self.last_signum = siginfo.signo;

        return .{
            .stopped = .{
                .regs = regs,
                .siginfo = siginfo,
            },
        };
    }

    pub fn cont(self: *Debugger) !void {
        if (self.breakpoints.getEntry(self.regs.rip - 1)) |entry| {
            var current_data: u64 = 0;
            try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, entry.key_ptr.*, @intFromPtr(&current_data));

            std.debug.assert(current_data & 0xff == int3); // Not interrupt

            swapLeastSignificantByte(&current_data, entry.value_ptr.*);
            try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, entry.key_ptr.*, current_data);

            std.debug.print("Put breakpoint back\n", .{});

            var new_regs = self.regs;
            new_regs.rip = entry.key_ptr.*;
            try std.posix.ptrace(std.os.linux.PTRACE.SETREGS, self.pid, 0, @intFromPtr(&new_regs));

            try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, self.pid, 0, 0);
            _ = try self.wait();
            std.debug.print("New instruction pointer: 0x{x}\n", .{self.regs.rip});

            try self.setBreakpoint(entry.key_ptr.*);
        }

        if (self.last_signum == std.os.linux.SIG.TRAP) {
            try std.posix.ptrace(std.os.linux.PTRACE.CONT, self.pid, 0, 0);
        } else {
            try std.posix.ptrace(std.os.linux.PTRACE.CONT, self.pid, 0, @intCast(self.last_signum));
        }
    }

    pub fn setBreakpoint(self: *Debugger, address: u64) !void {
        const gop = try self.breakpoints.getOrPut(self.alloc, address);

        var current_data: u64 = 0;
        try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, address, @intFromPtr(&current_data));

        gop.value_ptr.* = @intCast(current_data & 0xff);

        swapLeastSignificantByte(&current_data, int3);
        try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, address, current_data);
    }

    fn swapLeastSignificantByte(val: *u64, new_least_sig: u8) void {
        val.* &= ~@as(u64, 0xff);
        val.* |= new_least_sig;
    }
};

const Args = struct {
    breakpoint_names: []const []const u8,
    exe: [:0]const u8,

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        defer it.deinit();

        const process_name = it.next() orelse "desphaero";

        const exe = it.next() orelse {
            print("exe not provided\n", .{});
            help(process_name);
        };

        var breakpoints = std.ArrayList([]const u8).init(alloc);
        defer breakpoints.deinit();

        while (it.next()) |breakpoint_s| {
            try breakpoints.append(try alloc.dupe(u8, breakpoint_s));
        }

        return .{
            .exe = try alloc.dupeZ(u8, exe),
            .breakpoint_names = try breakpoints.toOwnedSlice(),
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
        for (self.breakpoint_names) |name| {
            alloc.free(name);
        }
        alloc.free(self.breakpoint_names);
        alloc.free(self.exe);
    }

    fn help(process_name: []const u8) noreturn {
        print("Usage: {s} [exe] [entry] [breakpoint]\n", .{process_name});
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

    var elf_metadata = try elf.getElfMetadata(alloc, args.exe);
    defer elf_metadata.deinit(alloc);

    var debugger = Debugger.init(alloc, args.exe);
    defer debugger.deinit();

    try debugger.launch();
    while (true) {
        const status = try debugger.wait();
        switch (status) {
            .stopped => |info| {
                std.debug.print("Stopped at 0x{x}\n", .{info.regs.rip});
                if (info.regs.rip == elf_metadata.entry) {
                    std.debug.print("Setting up breakpoint\n", .{});
                    for (args.breakpoint_names) |name| {
                        const breakpoint = elf_metadata.fn_addresses.get(name) orelse {
                            std.debug.print("No fn with name {s}\n", .{name});
                            continue;
                        };
                        try debugger.setBreakpoint(breakpoint);
                    }
                    try debugger.cont();
                } else {
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
