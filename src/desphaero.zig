const std = @import("std");
const Allocator = std.mem.Allocator;
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

    exe: [:0]const u8,
    pid: std.posix.pid_t = 0,

    bp: u64 = 0,
    previous_bp_byte: u8 = 0,

    regs: c.user_regs_struct = undefined,
    last_signum: i32 = 0,

    pub fn init(exe: [:0]const u8) Debugger {
        return .{
            .exe = exe,
        };
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
        // Offset by 1 because the int3 instruction has already been hit
        if (self.regs.rip == self.bp + 1) {
            var current_data: u64 = 0;
            try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, self.bp, @intFromPtr(&current_data));

            std.debug.assert(current_data & 0xff == int3); // Not interrupt
            swapLeastSignificantByte(&current_data, self.previous_bp_byte);
            try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, self.bp, current_data);

            std.debug.print("Put breakpoint back\n", .{});

            var new_regs = self.regs;
            new_regs.rip = self.bp;
            try std.posix.ptrace(std.os.linux.PTRACE.SETREGS, self.pid, 0, @intFromPtr(&new_regs));

            try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, self.pid, 0, 0);
            _ = try self.wait();
            std.debug.print("New instruction pointer: 0x{x}\n", .{self.regs.rip});

            try self.setBreakpoint(self.bp);
        }

        if (self.last_signum == std.os.linux.SIG.TRAP) {
            try std.posix.ptrace(std.os.linux.PTRACE.CONT, self.pid, 0, 0);
        } else {
            try std.posix.ptrace(std.os.linux.PTRACE.CONT, self.pid, 0, @intCast(self.last_signum));
        }
    }

    pub fn setBreakpoint(self: *Debugger, address: u64) !void {
        self.bp = address;

        var current_data: u64 = 0;
        try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, address, @intFromPtr(&current_data));
        self.previous_bp_byte = @intCast(current_data & 0xff);
        swapLeastSignificantByte(&current_data, int3);
        try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, address, current_data);
    }

    fn swapLeastSignificantByte(val: *u64, new_least_sig: u8) void {
        val.* &= ~@as(u64, 0xff);
        val.* |= new_least_sig;
    }
};

const Args = struct {
    entry_address: u64,
    breakpoint_address: u64,
    exe: [:0]const u8,

    pub fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        defer it.deinit();

        const process_name = it.next() orelse "desphaero";

        const exe = it.next() orelse {
            print("exe not provided\n", .{});
            help(process_name);
        };

        const entry_s = it.next() orelse {
            print("entry address not provided", .{});
            help(process_name);
        };

        const entry = std.fmt.parseInt(u64, entry_s, 0) catch {
            print("Entry point was not a number\n", .{});
            help(process_name);
        };

        const breakpoint_s = it.next() orelse {
            print("breakpoint address not provided", .{});
            help(process_name);
        };

        const breakpoint = std.fmt.parseInt(u64, breakpoint_s, 0) catch {
            print("Entry point was not a number\n", .{});
            help(process_name);
        };

        return .{
            .exe = try alloc.dupeZ(u8, exe),
            .breakpoint_address = breakpoint,
            .entry_address = entry,
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
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

    var debugger = Debugger.init(args.exe);
    try debugger.launch();
    while (true) {
        const status = try debugger.wait();
        switch (status) {
            .stopped => |info| {
                std.debug.print("Stopped at 0x{x}\n", .{info.regs.rip});
                if (info.regs.rip == args.entry_address) {
                    std.debug.print("Setting up breakpoint\n", .{});
                    try debugger.setBreakpoint(args.breakpoint_address);
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
