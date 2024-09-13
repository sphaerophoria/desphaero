const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

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

pub const ElfMetadata = struct {
    entry: u64,
    fn_addresses: std.StringHashMap(u64),
    string_table: StringTable,
    // FIXME: We don't use this
    di: std.dwarf.DwarfInfo,

    pub fn deinit(self: *ElfMetadata, alloc: Allocator) void {
        self.string_table.deinit(alloc);
        self.fn_addresses.deinit();
        self.di.deinit(alloc);
    }
};

pub fn getElfMetadata(alloc: Allocator, path: []const u8) !ElfMetadata {
    var f = try std.fs.cwd().openFile(path, .{});

    const header = try std.elf.Header.read(&f);

    const section_header_buf = try alloc.alloc(std.elf.Elf64_Shdr, header.shnum);
    defer alloc.free(section_header_buf);

    var di = std.dwarf.DwarfInfo{
        .endian = builtin.cpu.arch.endian(),
        .is_macho = false,
    };
    errdefer di.deinit(alloc);

    std.debug.print("header endianness: {any}\n", .{header.endian});

    try f.seekTo(header.shoff);
    const num_bytes_read = try f.readAll(std.mem.sliceAsBytes(section_header_buf));
    std.debug.print("Num bytes read: {d}, expected: {d}\n", .{ num_bytes_read, section_header_buf.len * @sizeOf(std.elf.Elf64_Shdr) });

    const shstrtab_header = section_header_buf[header.shstrndx];
    var shstrtab = try StringTable.init(alloc, &f, shstrtab_header.sh_offset, shstrtab_header.sh_size);
    defer shstrtab.deinit(alloc);

    var i: usize = 0;
    var strtab: ?StringTable = null;
    errdefer if (strtab) |*st| st.deinit(alloc);

    var symbols = std.ArrayList(struct {
        name: usize,
        addr: u64,
    }).init(alloc);
    defer symbols.deinit();
    for (section_header_buf) |shdr| {
        defer i += 1;
        std.debug.print("{s}\n", .{shstrtab.get(shdr.sh_name)});
        //printShType(shdr.sh_type);
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

        const section_name = shstrtab.get(shdr.sh_name);
        if (section_name.len > 1) blk: {
            const section = std.meta.stringToEnum(std.dwarf.DwarfSection, section_name[1..]) orelse break :blk;
            const dwarf_idx: usize = @intFromEnum(section);

            const section_data = try alloc.alloc(u8, shdr.sh_size);
            errdefer alloc.free(section_data);

            try f.seekTo(shdr.sh_offset);
            _ = try f.readAll(section_data);

            di.sections[dwarf_idx] = .{
                .data = section_data,
                .owned = true,
            };
        }
    }

    if (strtab == null) {
        return error.NoStrTab;
    }

    var fn_addresses = std.StringHashMap(u64).init(alloc);
    for (symbols.items) |sym| {
        try fn_addresses.put(strtab.?.get(sym.name), sym.addr);
    }

    try std.dwarf.openDwarfDebugInfo(&di, alloc);

    return .{
        .entry = header.entry,
        .fn_addresses = fn_addresses,
        .string_table = strtab.?,
        .di = di,
    };
}
