// FIXME: prune
const std = @import("std");
const Allocator = std.mem.Allocator;
const elf = @import("elf.zig");
const c = @cImport({
    @cInclude("gui.h");
    @cInclude("sys/user.h");
});
const debuginfo = @import("debuginfo.zig");

const int3 = 0xcc;
const Debugger = @This();

pub const DebugStatus = union(enum) {
    stopped: struct {
        siginfo: std.os.linux.siginfo_t,
    },
    finished,
};

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

pub const Variable = struct {
    // FIXME: These are owned by dwarf memory, kinda odd to assume future
    // interface will not require an allocation
    name: []const u8,
    type_name: []const u8,
    value: u64,
};

pub fn getLocals(self: *Debugger) ![]Variable {
    const die = self.dwarf_info.getDieForInstruction(self.regs.rip);
    const locals = try die.getLocals(self.alloc, &self.dwarf_info);
    defer self.alloc.free(locals);

    var ret = std.ArrayList(Variable).init(self.alloc);
    defer ret.deinit();

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

                try ret.append(.{
                    .name = local.name,
                    .type_name = local.type_name,
                    .value = val,
                });
            },
            else => {
                std.log.err("local {s} with unhandled op {any}", .{ local.name, local.op });
            },
        }
    }

    return try ret.toOwnedSlice();
}

pub fn printLocals(self: *Debugger) !void {
    const vars = try self.getLocals();
    for (vars) |v| {
        std.debug.print("\x1b[34mvar \x1b[35m{s}\x1b[m: {s} = {x}\n", .{ v.name, v.type_name, v.value });
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

pub fn getLineProgramSection(self: *const Debugger) []const u8 {
    return self.elf_metadata.di.sections[@intFromEnum(std.dwarf.DwarfSection.debug_line)].?.data;
}

fn swapLeastSignificantByte(val: *u64, new_least_sig: u8) void {
    val.* &= ~@as(u64, 0xff);
    val.* |= new_least_sig;
}

// FIXME: Should this be public?
pub fn addu64i64(a: u64, b: i64) u64 {
    const b_u: u64 = @bitCast(b);
    return a +% b_u;
}
