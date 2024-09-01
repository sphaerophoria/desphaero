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

fn printShType(typ: u32) void {
    const name = switch (typ) {
        std.elf.SHT_NULL => "SHT_NULL",
        std.elf.SHT_PROGBITS => "SHT_PROGBITS",
        std.elf.SHT_SYMTAB => "SHT_SYMTAB",
        std.elf.SHT_STRTAB => "SHT_STRTAB",
        std.elf.SHT_RELA => "SHT_RELA",
        std.elf.SHT_HASH => "SHT_HASH",
        std.elf.SHT_DYNAMIC => "SHT_DYNAMIC",
        std.elf.SHT_NOTE => "SHT_NOTE",
        std.elf.SHT_NOBITS => "SHT_NOBITS",
        std.elf.SHT_REL => "SHT_REL",
        std.elf.SHT_SHLIB => "SHT_SHLIB",
        std.elf.SHT_DYNSYM => "SHT_DYNSYM",
        std.elf.SHT_INIT_ARRAY => "SHT_INIT_ARRAY",
        std.elf.SHT_FINI_ARRAY => "SHT_FINI_ARRAY",
        std.elf.SHT_PREINIT_ARRAY => "SHT_PREINIT_ARRAY",
        std.elf.SHT_GROUP => "SHT_GROUP",
        std.elf.SHT_SYMTAB_SHNDX => "SHT_SYMTAB_SHNDX",
        std.elf.SHT_LOOS => "SHT_LOOS",
        std.elf.SHT_LLVM_ADDRSIG => "SHT_LLVM_ADDRSIG",
        std.elf.SHT_GNU_HASH => "SHT_GNU_HASH",
        std.elf.SHT_GNU_VERDEF => "SHT_GNU_VERDEF",
        std.elf.SHT_GNU_VERNEED => "SHT_GNU_VERNEED",
        std.elf.SHT_GNU_VERSYM => "SHT_GNU_VERSYM",
        //std.elf.SHT_HIOS   => "SHT_HIOS",
        std.elf.SHT_LOPROC => "SHT_LOPROC",
        std.elf.SHT_X86_64_UNWIND => "SHT_X86_64_UNWIND",
        std.elf.SHT_HIPROC => "SHT_HIPROC",
        std.elf.SHT_LOUSER => "SHT_LOUSER",
        std.elf.SHT_HIUSER => "SHT_HIUSER",
        else => "unknown",
    };

    std.debug.print("header name: {s}\n", .{name});
}

const SymbolIterator = struct {
    f: *std.fs.File,
    symtab_offs: u64,
    symtab_size_bytes: u64,
    i: usize = 0,

    const sym_size = @sizeOf(std.elf.Sym);

    fn init(f: *std.fs.File, symtab_offs: u64, symtab_size_bytes: u64) SymbolIterator {
        return .{
            .f = f,
            .symtab_offs = symtab_offs,
            .symtab_size_bytes = symtab_size_bytes,
        };
    }

    fn next(self: *SymbolIterator) !?std.elf.Sym {
        if (self.i * sym_size >= self.symtab_size_bytes) {
            return null;
        }
        defer self.i += 1;

        try self.f.seekTo(self.symtab_offs + sym_size * self.i);
        var ret: std.elf.Sym = undefined;
        _ = try self.f.readAll(std.mem.asBytes(&ret));
        return ret;
    }
};

const StringTable = struct {
    buf: []const u8,

    fn init(alloc: Allocator, f: *std.fs.File, offs: u64, size: u64) !StringTable {
        try f.seekTo(offs);
        const buf = try alloc.alloc(u8, size);
        const num_bytes_read = try f.readAll(buf);
        if (num_bytes_read != buf.len) {
            return error.UnexpectedEof;
        }

        return .{
            .buf = buf,
        };
    }

    fn deinit(self: *StringTable, alloc: Allocator) void {
        alloc.free(self.buf);
    }

    fn get(self: *const StringTable, idx: usize) [:0]const u8 {
        const ret = self.buf[idx..];
        const ret_len = std.mem.indexOfScalar(u8, ret, 0).?;
        return @ptrCast(ret[0..ret_len]);
    }
};

const ElfMetadata = struct {
    entry: u64,
    fn_addresses: std.StringHashMap(u64),
    string_table: StringTable,

    fn deinit(self: *ElfMetadata, alloc: Allocator) void {
        self.string_table.deinit(alloc);
        self.fn_addresses.deinit();
    }
};

fn getElfMetadata(alloc: Allocator, path: []const u8) !ElfMetadata {
    var f = try std.fs.cwd().openFile(path, .{});

    const header = try std.elf.Header.read(&f);

    var section_it = header.section_header_iterator(&f);

    var i: usize = 0;
    var strtab: ?StringTable = null;
    errdefer if (strtab) |*st| st.deinit(alloc);

    var symbols = std.ArrayList(struct {
        name: usize,
        addr: u64,
    }).init(alloc);
    defer symbols.deinit();
    while (try section_it.next()) |shdr| {
        defer i += 1;
        if (shdr.sh_type == std.elf.SHT_SYMTAB) {
            var sym_it = SymbolIterator.init(&f, shdr.sh_offset, shdr.sh_size);
            while (try sym_it.next()) |sym| {
                try symbols.append(.{
                    .name = sym.st_name,
                    .addr = sym.st_value,
                });
            }
        } else if (shdr.sh_type == std.elf.SHT_STRTAB and i != header.shstrndx) {
            std.debug.assert(strtab == null);
            strtab = try StringTable.init(alloc, &f, shdr.sh_offset, shdr.sh_size);
        }
    }

    if (strtab == null) {
        return error.NoStrTab;
    }

    var fn_addresses = std.StringHashMap(u64).init(alloc);
    for (symbols.items) |sym| {
        try fn_addresses.put(strtab.?.get(sym.name), sym.addr);
    }
    return .{
        .entry = header.entry,
        .fn_addresses = fn_addresses,
        .string_table = strtab.?,
    };
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

    var elf_metadata = try getElfMetadata(alloc, args.exe);
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
