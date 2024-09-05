const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const elf = @import("elf.zig");
const libdwarf = @cImport({
    @cInclude("libdwarf-0/dwarf.h");
    @cInclude("libdwarf-0/libdwarf.h");
});

const DwarfAttr = struct {
    inner: libdwarf.Dwarf_Attribute,

    fn asAddr(self: *const DwarfAttr) !u64 {
        var ret: libdwarf.Dwarf_Addr = undefined;
        const err = libdwarf.dwarf_formaddr(self.inner, &ret, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.NotAddr;
        }

        return ret;
    }

    fn asU64(self: *const DwarfAttr) !u64 {
        var ret: libdwarf.Dwarf_Unsigned = undefined;
        const err = libdwarf.dwarf_formudata(self.inner, &ret, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.NotU64;
        }

        return ret;
    }

    fn asString(self: *const DwarfAttr) ![]const u8 {
        var s: [*c]u8 = undefined;
        const err = libdwarf.dwarf_formstring(self.inner, &s, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.NotString;
        }

        return std.mem.span(s);
    }

    fn form(self: *const DwarfAttr) !u32 {
        var ret: libdwarf.Dwarf_Half = undefined;
        const err = libdwarf.dwarf_whatform(self.inner, &ret, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.UnknownForm;
        }

        return ret;
    }

    fn asDie(self: *const DwarfAttr, dbg: libdwarf.Dwarf_Debug) !DwarfDie {
        var offs: libdwarf.Dwarf_Off = undefined;
        var is_info: c_int = 0;
        var err = libdwarf.dwarf_formref(self.inner, &offs, &is_info, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.NotOffs;
        }

        var global_offs: libdwarf.Dwarf_Off = undefined;
        err = libdwarf.dwarf_convert_to_global_offset(self.inner, offs, &global_offs, null);
        if (err != libdwarf.DW_DLV_OK) {
            return error.InvalidOffset;
        }

        var die: libdwarf.Dwarf_Die = undefined;
        err = libdwarf.dwarf_offdie_b(dbg, global_offs, is_info, &die, null);

        if (err != libdwarf.DW_DLV_OK) {
            return error.InvalidGlobalOffset;
        }

        return .{
            .die = die,
        };
    }
};

pub const Local = struct {
    name: []const u8,
    type_name: []const u8,
    type_size: ?u8,
    op: DwOp,
};

pub const DwarfDie = struct {
    die: libdwarf.Dwarf_Die,

    pub fn deinit(self: *const DwarfDie) void {
        libdwarf.dwarf_dealloc_die(self.die);
    }

    // NOTE: Tied to lifetime of die
    pub fn name(self: *const DwarfDie) ![]const u8 {
        var text: [*c]u8 = null;
        const ret = libdwarf.dwarf_die_text(self.die, libdwarf.DW_AT_name, &text, null);

        if (ret != libdwarf.DW_DLV_OK) {
            return error.DwarfNoName;
        }

        return std.mem.span(text);
    }

    pub fn getLocals(self: *const DwarfDie, alloc: Allocator, info: *const DwarfInfo) ![]Local {
        var it = (try self.child()) orelse return &.{};
        errdefer it.deinit();

        var out = std.ArrayList(Local).init(alloc);
        defer out.deinit();

        while (true) {
            const child_tag = try it.tag();
            if (child_tag == libdwarf.DW_TAG_variable) {
                const typ_attr = try it.attr(libdwarf.DW_AT_type);
                const typ = try typ_attr.asDie(info.dbg);

                var local = Local{
                    .name = try it.name(),
                    .type_name = try typ.name(),
                    .type_size = null,
                    .op = try DwOp.init(it),
                };
                switch (try typ.tag()) {
                    libdwarf.DW_TAG_base_type => {
                        const size_attr = try typ.attr(libdwarf.DW_AT_byte_size);
                        local.type_size = @truncate(try size_attr.asU64());
                    },
                    else => {},
                }

                try out.append(local);
            }

            const next_it = try it.nextSibling();
            it.deinit();
            if (next_it) |val| {
                it = val;
            } else {
                break;
            }
        }

        return try out.toOwnedSlice();
    }

    fn tag(self: *const DwarfDie) !libdwarf.Dwarf_Half {
        var val: libdwarf.Dwarf_Half = 0;
        const ret = libdwarf.dwarf_tag(self.die, &val, null);
        if (ret != libdwarf.DW_DLV_OK) {
            return error.DwarfTag;
        }

        return val;
    }

    fn attr(self: *const DwarfDie, val: u16) !DwarfAttr {
        var output: libdwarf.Dwarf_Attribute = undefined;
        const ret = libdwarf.dwarf_attr(self.die, val, &output, null);
        if (ret != libdwarf.DW_DLV_OK) {
            return error.NoAttr;
        }

        return .{
            .inner = output,
        };
    }

    fn nextSibling(self: *const DwarfDie) !?DwarfDie {
        var new_die: libdwarf.Dwarf_Die = undefined;
        const ret = libdwarf.dwarf_siblingof_c(self.die, &new_die, null);

        if (ret == libdwarf.DW_DLV_NO_ENTRY) {
            return null;
        }

        if (ret != libdwarf.DW_DLV_OK) {
            return error.DwarfDieIter;
        }

        return .{
            .die = new_die,
        };
    }

    fn child(self: *const DwarfDie) !?DwarfDie {
        var new_die: libdwarf.Dwarf_Die = undefined;
        const ret = libdwarf.dwarf_child(self.die, &new_die, null);

        if (ret == libdwarf.DW_DLV_NO_ENTRY) {
            return null;
        }

        if (ret != libdwarf.DW_DLV_OK) {
            return error.DwarfDieIter;
        }

        return .{
            .die = new_die,
        };
    }
};

const CompilationUnitIt = struct {
    dbg: *libdwarf.Dwarf_Debug,

    fn init(dbg: *libdwarf.Dwarf_Debug) !CompilationUnitIt {
        return .{
            .dbg = dbg,
        };
    }

    fn next(self: *CompilationUnitIt) !?DwarfDie {
        var die: libdwarf.Dwarf_Die = undefined;

        const ret = libdwarf.dwarf_next_cu_header_e(
            self.dbg.*,
            1,
            &die,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
        );

        if (ret == libdwarf.DW_DLV_NO_ENTRY) {
            return null;
        }

        if (ret != libdwarf.DW_DLV_OK) {
            return error.DwarfDieIter;
        }

        return .{
            .die = die,
        };
    }
};

pub const DwOp = union(enum) {
    fbreg: i64,
    unknown: struct {
        op: u8,
        opd1: c_ulonglong,
        opd2: c_ulonglong,
        opd3: c_ulonglong,
    },
    none,

    fn init(die: DwarfDie) !DwOp {
        var attr: libdwarf.Dwarf_Attribute = undefined;
        var ret = libdwarf.dwarf_attr(die.die, libdwarf.DW_AT_location, &attr, null);
        if (ret != libdwarf.DW_DLV_OK) {
            return .none;
        }
        defer libdwarf.dwarf_dealloc_attribute(attr);

        var head: libdwarf.Dwarf_Loc_Head_c = undefined;
        var count: libdwarf.Dwarf_Unsigned = undefined;

        ret = libdwarf.dwarf_get_loclist_c(attr, &head, &count, null);
        if (ret != libdwarf.DW_DLV_OK) {
            return error.InvalidLocList;
        }
        defer libdwarf.dwarf_dealloc_loc_head_c(head);

        var desc: libdwarf.Dwarf_Locdesc_c = undefined;
        var dw_lle_value_out: libdwarf.Dwarf_Small = undefined;
        var dw_rawlowpc: libdwarf.Dwarf_Unsigned = undefined;
        var dw_rawhipc: libdwarf.Dwarf_Unsigned = undefined;
        var dw_debug_addr_unavailable: libdwarf.Dwarf_Bool = undefined;
        var dw_lowpc_cooked: libdwarf.Dwarf_Addr = undefined;
        var dw_hipc_cooked: libdwarf.Dwarf_Addr = undefined;
        var dw_locexpr_op_count_out: libdwarf.Dwarf_Unsigned = undefined;
        var dw_loclist_source_out: libdwarf.Dwarf_Small = undefined;
        var dw_expression_offset_out: libdwarf.Dwarf_Unsigned = undefined;
        var dw_locdesc_offset_out: libdwarf.Dwarf_Unsigned = undefined;

        ret = libdwarf.dwarf_get_locdesc_entry_d(
            head,
            0,
            &dw_lle_value_out,
            &dw_rawlowpc,
            &dw_rawhipc,
            &dw_debug_addr_unavailable,
            &dw_lowpc_cooked,
            &dw_hipc_cooked,
            &dw_locexpr_op_count_out,
            &desc,
            &dw_loclist_source_out,
            &dw_expression_offset_out,
            &dw_locdesc_offset_out,
            null,
        );

        if (ret != libdwarf.DW_DLV_OK) {
            return error.InvalidLocDescEntry;
        }

        if (dw_locexpr_op_count_out == 0) {
            // FIXME: Unsure if nonoe makes sense here
            return .none;
        }

        var dw_operator_out: libdwarf.Dwarf_Small = undefined;
        var dw_operand1: libdwarf.Dwarf_Unsigned = undefined;
        var dw_operand2: libdwarf.Dwarf_Unsigned = undefined;
        var dw_operand3: libdwarf.Dwarf_Unsigned = undefined;
        var dw_offset_for_branch: libdwarf.Dwarf_Unsigned = undefined;

        if (dw_locexpr_op_count_out == 0) {
            // FIXME: Unsure if nonoe makes sense here
            return .none;
        }

        ret = libdwarf.dwarf_get_location_op_value_c(desc, 0, &dw_operator_out, &dw_operand1, &dw_operand2, &dw_operand3, &dw_offset_for_branch, null);

        if (ret != libdwarf.DW_DLV_OK) {
            return error.InvalidOp;
        }

        switch (dw_operator_out) {
            libdwarf.DW_OP_fbreg => {
                return .{
                    .fbreg = @bitCast(dw_operand1),
                };
            },
            else => {
                return .{
                    .unknown = .{
                        .op = dw_operator_out,
                        .opd1 = dw_operand1,
                        .opd2 = dw_operand2,
                        .opd3 = dw_operand3,
                    },
                };
            },
        }
    }
};

pub const DebugDump = struct {
    // name owned by DwarfInfo/static memory
    name: []const u8,
    tag: []const u8,
    op: ?DwOp = null,
    children: []DebugDump,

    pub fn deinit(self: *DebugDump, alloc: Allocator) void {
        alloc.free(self.tag);
        for (self.children) |*child| {
            child.deinit(alloc);
        }
        alloc.free(self.children);
    }

    pub fn init(alloc: Allocator, exe: [:0]const u8) ![]DebugDump {
        var dbg = try dwarfDbgFromPath(exe);
        var cu_it = try CompilationUnitIt.init(&dbg);
        var it = DwarfIt.init(alloc, &cu_it);
        defer it.deinit();

        var children_bufs: std.ArrayListUnmanaged(std.ArrayListUnmanaged(DebugDump)) = .{};
        defer {
            for (children_bufs.items) |*item| {
                for (item.items) |*serialized_die| {
                    serialized_die.deinit(alloc);
                }
                item.deinit(alloc);
            }
            children_bufs.deinit(alloc);
        }

        while (try it.next()) |item| {
            defer item.deinit();
            const name = item.die.name() catch "unknown";

            while (children_bufs.items.len < item.level) {
                try children_bufs.append(alloc, .{});
            }

            var children: []DebugDump = &.{};
            errdefer alloc.free(children);

            if (children_bufs.items.len > item.level) {
                //collect children into new DebugDump
                std.debug.assert(item.level + 1 == children_bufs.items.len);

                var children_al = children_bufs.pop();
                children = try children_al.toOwnedSlice(alloc);
            }

            const tag = try item.die.tag();
            const tag_s = try std.fmt.allocPrint(alloc, "{any}", .{tag});
            errdefer alloc.free(tag_s);

            var serialized = DebugDump{
                .name = name,
                .tag = tag_s,
                .children = children,
            };

            if (tag == libdwarf.DW_TAG_variable) {
                const op = try DwOp.init(item.die);
                serialized.op = op;
            }

            try children_bufs.items[children_bufs.items.len - 1].append(alloc, serialized);
        }

        std.debug.assert(children_bufs.items.len == 1);
        var ret_al = children_bufs.pop();
        return try ret_al.toOwnedSlice(alloc);
    }
};

const DwarfIt = struct {
    it: *CompilationUnitIt,
    stack: std.ArrayList(DwarfDie),

    const Output = struct {
        level: usize,
        die: DwarfDie,

        fn deinit(self: *const Output) void {
            self.die.deinit();
        }
    };

    pub fn init(alloc: Allocator, it: *CompilationUnitIt) DwarfIt {
        return .{
            .it = it,
            .stack = std.ArrayList(DwarfDie).init(alloc),
        };
    }

    pub fn deinit(self: *DwarfIt) void {
        for (self.stack.items) |item| {
            item.deinit();
        }
        self.stack.deinit();
    }

    pub fn next(self: *DwarfIt) !?Output {
        if (self.stack.items.len == 0) {
            if (try self.it.next()) |item| {
                try self.stack.append(item);
                try self.pushWhileHasChild();
            } else {
                return null;
            }
        }

        const child = &self.stack.items[self.stack.items.len - 1];
        if (try child.nextSibling()) |sibling| {
            const die = child.*;
            errdefer die.deinit();

            child.* = sibling;
            const level = self.stack.items.len;
            try self.pushWhileHasChild();
            return .{
                .level = level,
                .die = die,
            };
        } else {
            defer _ = self.stack.popOrNull();
            return .{
                .level = self.stack.items.len,
                .die = child.*,
            };
        }
    }

    fn pushWhileHasChild(self: *DwarfIt) !void {
        var it = self.stack.getLast();
        while (try it.child()) |child| {
            try self.stack.append(child);
            it = child;
        }
    }
};

fn dwarfDbgFromPath(exe: [:0]const u8) !libdwarf.Dwarf_Debug {
    var dbg: libdwarf.Dwarf_Debug = undefined;

    const ret = libdwarf.dwarf_init_path(exe, null, 0, libdwarf.DW_GROUPNUMBER_ANY, null, null, &dbg, null);

    if (ret != libdwarf.DW_DLV_OK) {
        return error.DwarfInitError;
    }
    return dbg;
}

pub const DwarfInfo = struct {
    dbg: libdwarf.Dwarf_Debug,
    functions: []Function,

    const Function = struct {
        range: struct {
            start: u64,
            end: u64,
        },
        die: DwarfDie,
    };

    pub const Diagnostics = struct {
        alloc: Allocator,
        unhandled_fns: std.StringHashMapUnmanaged(void) = .{},
        string_storage: std.ArrayListUnmanaged([]const u8) = .{},

        pub fn deinit(self: *Diagnostics) void {
            self.unhandled_fns.deinit(self.alloc);
            for (self.string_storage.items) |item| {
                self.alloc.free(item);
            }
            self.string_storage.deinit(self.alloc);
        }

        fn pushUnhandledFn(self: *Diagnostics, unowned_name: []const u8) !void {
            const name = try self.alloc.dupe(u8, unowned_name);
            errdefer self.alloc.free(name);

            try self.string_storage.append(self.alloc, name);
            errdefer _ = self.string_storage.pop();

            try self.unhandled_fns.put(self.alloc, name, {});
        }
    };

    pub fn init(alloc: Allocator, exe: [:0]const u8, diagnostics: ?*Diagnostics) !DwarfInfo {
        var dbg = try dwarfDbgFromPath(exe);
        errdefer _ = libdwarf.dwarf_finish(dbg);

        var cu_it = try CompilationUnitIt.init(&dbg);
        var dwarf_it = DwarfIt.init(alloc, &cu_it);
        defer dwarf_it.deinit();

        var functions = std.ArrayList(Function).init(alloc);
        defer functions.deinit();

        while (try dwarf_it.next()) |item| {
            const die = item.die;
            switch (try die.tag()) {
                // FIXME: DW_TAG_inlined_subroutine + DW_TAG_entry_point
                libdwarf.DW_TAG_subprogram => {
                    errdefer die.deinit();
                    // FIXME: These don't have to be addr/u64
                    const low_attr = die.attr(libdwarf.DW_AT_low_pc) catch {
                        die.deinit();
                        if (diagnostics) |d| {
                            const name = item.die.name() catch "unknown";
                            try d.pushUnhandledFn(name);
                        }
                        continue;
                    };
                    const low_val = try low_attr.asAddr();

                    const high_attr = try die.attr(libdwarf.DW_AT_high_pc);
                    const high_val = try high_attr.asU64();

                    try functions.append(.{
                        .range = .{
                            .start = low_val,
                            .end = low_val + high_val,
                        },
                        .die = die,
                    });
                },
                else => {
                    die.deinit();
                },
            }
        }

        const fnLessThan = struct {
            fn f(_: void, lhs: Function, rhs: Function) bool {
                return lhs.range.start < rhs.range.start;
            }
        }.f;

        std.sort.pdq(Function, functions.items, {}, fnLessThan);

        return .{
            .dbg = dbg,
            .functions = try functions.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *DwarfInfo, alloc: Allocator) void {
        for (self.functions) |f| {
            f.die.deinit();
        }
        alloc.free(self.functions);
        _ = libdwarf.dwarf_finish(self.dbg);
    }

    pub fn getDieForInstruction(self: *const DwarfInfo, addr: u64) *const DwarfDie {
        const itemLessThan = struct {
            fn f(_: void, lhs: u64, rhs: Function) bool {
                return lhs < rhs.range.start;
            }
        }.f;

        const upper = upperBound(Function, addr, self.functions, {}, itemLessThan);

        return &self.functions[upper -| 1].die;
    }
};

// NOTE: upperBound API cannot handle mis-matched types in 0.13 (I think, didn't actually check but pretty sure)
fn upperBound(
    comptime T: type,
    key: anytype,
    items: []const T,
    context: anytype,
    comptime lessThan: fn (context: @TypeOf(context), lhs: @TypeOf(key), rhs: T) bool,
) usize {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        const mid = (right + left) / 2;
        if (!lessThan(context, key, items[mid])) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    return left;
}
