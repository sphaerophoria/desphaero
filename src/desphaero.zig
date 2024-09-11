const std = @import("std");
const Allocator = std.mem.Allocator;
const elf = @import("elf.zig");
const c = @cImport({
    @cInclude("sys/user.h");
});
const debuginfo = @import("debuginfo.zig");

fn printPidMaps(alloc: Allocator, pid: std.os.linux.pid_t) void {
    var path_buf: [1024]u8 = undefined;
    const maps_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid});
    const f = try std.fs.openFileAbsolute(maps_path, .{});
    defer f.close();

    const maps_data = try f.readToEndAlloc(alloc, 1e9);
    defer alloc.free(maps_data);

    std.debug.print("Current maps:\n{s}\n", .{maps_data});
}

fn addu64i64(a: u64, b: i64) u64 {
    const b_u: u64 = @bitCast(b);
    return a +% b_u;
}

const DebugStatus = union(enum) {
    stopped: struct {
        siginfo: std.os.linux.siginfo_t,
    },
    finished,
};

const Debugger = struct {
    const int3 = 0xcc;

    alloc: Allocator,
    exe: [:0]const u8,
    pid: std.posix.pid_t = 0,
    dwarf_info: debuginfo.DwarfInfo,
    elf_metadata: elf.ElfMetadata,

    breakpoints: std.AutoHashMapUnmanaged(u64, u8) = .{},
    pending_breakpoints: std.AutoHashMapUnmanaged(u64, void) = .{},

    regs: c.user_regs_struct = undefined,
    last_signum: i32 = 0,

    pub fn init(alloc: Allocator, exe: [:0]const u8) !Debugger {
        var diagnostics = debuginfo.DwarfInfo.Diagnostics{
            .alloc = alloc,
        };
        defer diagnostics.deinit();

        var elf_metadata = try elf.getElfMetadata(alloc, exe);
        errdefer elf_metadata.deinit(alloc);

        const dwarf_info = try debuginfo.DwarfInfo.init(alloc, exe, &diagnostics);

        if (diagnostics.unhandled_fns.count() > 0) {
            std.log.warn("Some fns have unhandled IP lookup", .{});
            var key_it = diagnostics.unhandled_fns.keyIterator();

            var string_buf = std.ArrayList(u8).init(alloc);
            defer string_buf.deinit();
            while (key_it.next()) |item| {
                try string_buf.appendSlice(item.*);
                try string_buf.appendSlice(", ");
            }
            std.log.debug("Function lookup will fail in: {s}", .{string_buf.items});
        }

        return .{
            .alloc = alloc,
            .exe = exe,
            .elf_metadata = elf_metadata,
            .dwarf_info = dwarf_info,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit(self.alloc);
        self.pending_breakpoints.deinit(self.alloc);
        self.dwarf_info.deinit(self.alloc);
        self.elf_metadata.deinit(self.alloc);
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

        var siginfo: std.os.linux.siginfo_t = undefined;
        try std.posix.ptrace(std.os.linux.PTRACE.GETSIGINFO, self.pid, 0, @intFromPtr(&siginfo));

        try std.posix.ptrace(std.os.linux.PTRACE.GETREGS, self.pid, 0, @intFromPtr(&self.regs));
        self.last_signum = siginfo.signo;

        try self.recoverFromBreakpoint();
        try self.setPendingBreakpoints();

        return .{
            .stopped = .{
                .siginfo = siginfo,
            },
        };
    }

    pub fn cont(self: *Debugger) !void {
        try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, self.pid, 0, 0);
        _ = try self.wait();

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

    pub fn stepInstruction(self: *Debugger) !DebugStatus {
        try std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, self.pid, 0, 0);
        return self.wait();
    }

    pub fn stepInto(self: *Debugger) !DebugStatus {
        var start_loc = try self.sourceLocation();
        defer start_loc.deinit(self.alloc);

        while (true) {
            const info = try self.stepInstruction();

            // FIXME: sourceLocation is unbelievably expensive at this point
            var current_loc = try self.sourceLocation();
            defer current_loc.deinit(self.alloc);

            if (current_loc.line == 0) {
                continue;
            }

            if (!start_loc.eql(current_loc)) {
                return info;
            }
        }
    }

    pub fn sourceLocation(self: *Debugger) !debuginfo.SourceLocation {
        return try self.dwarf_info.sourceLocation(
            self.alloc,
            self.regs.rip,
            self.getLineProgramSection(),
        );
    }

    pub fn printLocals(self: *Debugger) !void {
        const die = self.dwarf_info.getDieForInstruction(self.regs.rip);
        const locals = try die.getLocals(self.alloc, &self.dwarf_info);
        defer self.alloc.free(locals);
        for (locals) |local| {
            switch (local.op) {
                .fbreg => |v| {
                    // FIXME: rbp invalid if fomit-frame-pointer
                    const address = addu64i64(self.regs.rbp, v);
                    var val: u64 = 0;
                    try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, address, @intFromPtr(&val));

                    if (local.type_size) |size| {
                        const mask = ~@as(u64, 0) >> @intCast((8 - size) * 8);
                        val = val & mask;
                    }

                    std.debug.print("\x1b[34mvar \x1b[35m{s}\x1b[m: {s} ({any}) = {x}\n", .{ local.name, local.type_name, local.type_size, val });
                },
                else => {
                    std.debug.print("local {s} with unhandled op {any}\n", .{ local.name, local.op });
                },
            }
        }
    }

    fn recoverFromBreakpoint(self: *Debugger) !void {
        const entry = self.breakpoints.getEntry(self.regs.rip - 1) orelse return;

        var current_data: u64 = 0;
        try std.posix.ptrace(std.os.linux.PTRACE.PEEKTEXT, self.pid, entry.key_ptr.*, @intFromPtr(&current_data));

        std.debug.assert(current_data & 0xff == int3); // Not interrupt

        swapLeastSignificantByte(&current_data, entry.value_ptr.*);
        try std.posix.ptrace(std.os.linux.PTRACE.POKETEXT, self.pid, entry.key_ptr.*, current_data);

        self.regs.rip = entry.key_ptr.*;
        try std.posix.ptrace(std.os.linux.PTRACE.SETREGS, self.pid, 0, @intFromPtr(&self.regs));

        try self.pending_breakpoints.put(self.alloc, entry.key_ptr.*, {});
        _ = self.breakpoints.remove(entry.key_ptr.*);
    }

    fn setPendingBreakpoints(self: *Debugger) !void {
        var bp_it = self.pending_breakpoints.keyIterator();
        var fixed_breakpoints = std.ArrayList(u64).init(self.alloc);
        defer {
            for (fixed_breakpoints.items) |bp| {
                _ = self.pending_breakpoints.remove(bp);
            }
            fixed_breakpoints.deinit();
        }

        while (bp_it.next()) |bp| {
            if (self.regs.rip != bp.*) {
                try self.setBreakpoint(bp.*);
                // FIXME: If append fails we might think the breakpoint is unset
                try fixed_breakpoints.append(bp.*);
            }
        }
    }

    fn getLineProgramSection(self: *const Debugger) []const u8 {
        return self.elf_metadata.di.sections[@intFromEnum(std.dwarf.DwarfSection.debug_line)].?.data;
    }

    fn swapLeastSignificantByte(val: *u64, new_least_sig: u8) void {
        val.* &= ~@as(u64, 0xff);
        val.* |= new_least_sig;
    }
};

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

    var debugger = try Debugger.init(alloc, args.exe);
    defer debugger.deinit();

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

                        try debugger.setBreakpoint(addu64i64(breakpoint, offs));
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
