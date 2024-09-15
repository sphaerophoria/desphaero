const std = @import("std");
const Allocator = std.mem.Allocator;
const libvterm = @import("vterm.zig");

alloc: Allocator,
vterm: *libvterm.VTerm,
screen: *libvterm.VTermScreen,
// File descriptor to child process
fd: c_int,

io: Handle,

const Key = u8;

// Gui thread
// I have input
const Handle = struct {
    mutex: std.Thread.Mutex = .{},
    protected: struct {
        input: std.fifo.LinearFifo(u8, .Dynamic),
        // FIXME: Integrated into linearfifo probably
        exit: bool = false,
    },

    pub fn pressKey(self: *Handle, key: Key) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.protected.input.writeItem(key);
    }

    pub fn exit(self: *Handle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.protected.exit = true;
    }
};

const Terminal = @This();

pub const num_rows = 24;
pub const num_cols = 80;

pub fn init(alloc: Allocator, fd: c_int) !Terminal {
    const vterm = libvterm.vterm_new(num_rows, num_cols) orelse return error.CreateVterm;
    errdefer libvterm.vterm_free(vterm);
    libvterm.vterm_set_utf8(vterm, 1);

    const screen = libvterm.vterm_obtain_screen(vterm) orelse return error.GetScreen;
    libvterm.vterm_screen_reset(screen, 1);

    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    var flags_o: std.os.linux.O = @bitCast(@as(u32, @truncate(flags)));
    flags_o.NONBLOCK = true;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(flags_o)));

    return .{
        .alloc = alloc,
        .vterm = vterm,
        .screen = screen,
        .io = .{
            .protected = .{
                .input = std.fifo.LinearFifo(u8, .Dynamic).init(alloc),
            },
        },
        .fd = fd,
    };
}

pub fn deinit(self: *Terminal) void {
    libvterm.vterm_free(self.vterm);
}

pub fn step(self: *Terminal) !void {
    var buf: [1024]u8 = undefined;

    libvterm.vterm_output_set_callback(self.vterm, sendOutput, self);
    defer libvterm.vterm_output_set_callback(self.vterm, null, null);

    _ = try self.pollInput();

    // timed read
    // FIXME: Select and wait for timeout
    const size = std.posix.read(self.fd, &buf) catch {
        std.time.sleep(100 * std.time.ns_per_ms);
        return;
    };
    const ret = libvterm.vterm_input_write(self.vterm, &buf, size);
    std.debug.assert(ret == size);
}

const ScreenSnapshot = struct {
    string_buf: []const u8,
    glyphs: []Range,
    metadata: []Metadata,
    width: u32,

    const Range = struct {
        start: usize,
        end: usize,
    };
    const Metadata = struct {
        fg_color: struct {
            r: u8,
            g: u8,
            b: u8,
        },
    };
};

// FIXME: Super tied to QT, should be internal representation
// FIXME: Extract screen text while running
pub fn getScreenSnapshot(self: *Terminal, alloc: Allocator) !ScreenSnapshot {
    var string_buf = try std.ArrayList(u8).initCapacity(alloc, num_rows * num_cols);
    defer string_buf.deinit();

    var glyphs = try alloc.alloc(ScreenSnapshot.Range, num_rows * num_cols);
    errdefer alloc.free(glyphs);

    var metadata = try alloc.alloc(ScreenSnapshot.Metadata, num_rows * num_cols);
    errdefer alloc.free(metadata);

    for (0..num_rows) |row| {
        for (0..num_cols) |col| {
            const glyph_idx = row * num_cols + col;

            var cell: libvterm.VTermScreenCell = undefined;
            const ret = libvterm.vterm_screen_get_cell(self.screen, libvterm.VTermPos{
                .row = @intCast(row),
                .col = @intCast(col),
            }, &cell);

            if (ret == 0) {
                return error.NoCell;
            }

            const glyph = try appendCellString(cell, &string_buf);
            glyphs[glyph_idx] = glyph;

            libvterm.vterm_screen_convert_color_to_rgb(self.screen, &cell.fg);
            const glyph_metadata = ScreenSnapshot.Metadata{
                .fg_color = .{
                    .r = cell.fg.rgb.red,
                    .g = cell.fg.rgb.green,
                    .b = cell.fg.rgb.blue,
                },
            };
            metadata[glyph_idx] = glyph_metadata;
        }
    }

    return .{
        .string_buf = try string_buf.toOwnedSlice(),
        .glyphs = glyphs,
        .metadata = metadata,
        .width = num_cols,
    };
}

const InputEvents = struct {
    exit: bool,
    keys: []Key,
};

fn getInputEvents(self: *Terminal) !InputEvents {
    self.io.mutex.lock();
    defer self.io.mutex.unlock();

    const num_items = self.io.protected.input.readableLength();
    const ret = try self.alloc.alloc(Key, num_items);

    const size = self.io.protected.input.read(ret);
    std.debug.assert(size == ret.len);

    return .{
        .exit = self.io.protected.exit,
        .keys = ret,
    };
}

fn sendOutput(buf: [*c]const u8, len: usize, userdata: ?*anyopaque) callconv(.C) void {
    std.debug.print("output sending {s}\n", .{buf});
    const self: *Terminal = @ptrCast(@alignCast(userdata));
    const ret = std.posix.write(self.fd, buf[0..len]) catch {
        std.log.err("Failed to write to child file descriptor for terminal input", .{});
        return;
    };

    // FIXME: Handle early returns
    std.debug.assert(ret == len);
}

// FIXME: ENum better than bool
fn pollInput(self: *Terminal) !bool {
    const events = try self.getInputEvents();

    for (events.keys) |event| {
        std.debug.print("sending key: {c}\n", .{event});
        libvterm.vterm_keyboard_unichar(self.vterm, event, libvterm.VTERM_MOD_NONE);
    }
    return events.exit;
}

// FIXME: Tied to gui in weird way
pub export fn terminalInputKey(io_opt: ?*Handle, key: u8) void {
    const io = io_opt orelse return;

    std.debug.print("got key: {c}\n", .{key});
    // FIXME: log?
    io.pressKey(key) catch {};
}

fn appendCellString(cell: libvterm.VTermScreenCell, string_buf: *std.ArrayList(u8)) !ScreenSnapshot.Range {
    const initial_len = string_buf.items.len;
    for (0..cell.width) |i| {
        const c_u: u21 = std.math.cast(u21, cell.chars[i]) orelse return error.InvalidCodepoint;
        const out_len = try std.unicode.utf8CodepointSequenceLength(@intCast(cell.chars[i]));
        const old_buf_len = string_buf.items.len;
        try string_buf.resize(string_buf.items.len + out_len);

        _ = try std.unicode.utf8Encode(c_u, string_buf.items[old_buf_len..]);
    }

    return .{
        .start = initial_len,
        .end = string_buf.items.len,
    };
}
