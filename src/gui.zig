const std = @import("std");

const Allocator = std.mem.Allocator;
const Debugger = @import("Debugger.zig");
const guipp = @cImport({
    @cInclude("gui.h");
});

pub fn run(alloc: Allocator, debugger: *Debugger) !void {

    // FIXME: Why was this a pointer again?
    const thread_data = try alloc.create(DebuggerThread);
    thread_data.* = .{
        .alloc = alloc,
        .debugger = debugger,
        .gui_handle = undefined,
    };
    const gui_handle = guipp.makeGui(&thread_data.thread_handle) orelse return error.MakeGui;
    thread_data.gui_handle = gui_handle;

    const t = try std.Thread.spawn(.{}, DebuggerThread.run, .{thread_data});
    defer t.join();

    guipp.setDebuggerState(gui_handle, guipp.STATE_RUN);
    if (guipp.runGui(gui_handle) != 0) {
        return error.RunGui;
    }
}

const DebuggerThread = struct {
    alloc: Allocator,
    debugger: *Debugger,
    gui_handle: *guipp.GuiHandle,
    thread_handle: Handle = .{},
    finished: bool = false,

    const Handle = struct {
        mutex: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        mutex_protected: struct {
            cont: bool = true,
        } = .{},
    };

    fn step(self: *DebuggerThread) !void {
        {
            self.thread_handle.mutex.lock();
            defer self.thread_handle.mutex.unlock();

            if (self.finished or !self.thread_handle.mutex_protected.cont) {
                self.thread_handle.cv.wait(&self.thread_handle.mutex);
                return;
            }

            if (self.thread_handle.mutex_protected.cont) {
                try self.debugger.cont();
                self.thread_handle.mutex_protected.cont = false;
            }
        }

        guipp.setDebuggerState(self.gui_handle, guipp.STATE_RUN);
        const status = try self.debugger.wait();
        guipp.setDebuggerState(self.gui_handle, guipp.STATE_STOP);
        switch (status) {
            .stopped => |_| {
                var loc = try self.debugger.sourceLocation();
                defer loc.deinit(self.debugger.alloc);

                guipp.setCurrentFile(self.gui_handle, loc.path.ptr, loc.path.len);
                guipp.setCurrentLine(self.gui_handle, loc.line);

                const c_regs = try makeCRegs(self.alloc, self.debugger.regs);
                //defer freeCRegs(c_regs);
                guipp.setRegisters(self.gui_handle, c_regs.ptr, c_regs.len);

                const locals = try self.debugger.getLocals();
                // FIXME: Pass in allocator to getLocals
                defer self.debugger.alloc.free(locals);

                var c_vars = try makeCVars(self.alloc, locals);
                defer c_vars.deinit(self.alloc);
                guipp.setVars(self.gui_handle, c_vars.vars.ptr, c_vars.vars.len);

                var c_breakpoints = try makeCBreakpoints(self.alloc, self.debugger);
                defer c_breakpoints.deinit(self.alloc);
                guipp.setBreakpoints(self.gui_handle, c_breakpoints.breakpoints.ptr, c_breakpoints.breakpoints.len);
            },
            .finished => {
                guipp.setDebuggerState(self.gui_handle, guipp.STATE_FINISH);
                self.finished = true;
            },
        }
    }

    // FIXME: Error crashes thread, probably should be protected
    fn run(self: *DebuggerThread) !void {
        try self.debugger.launch();
        while (true) {
            self.step() catch |e| {
                std.log.err("debugger error: {s}", .{@errorName(e)});
            };
        }
    }
};

fn makeCRegs(alloc: Allocator, regs: anytype) ![]guipp.Register {
    const T = @TypeOf(regs);
    const fields = std.meta.fields(T);

    const out = try alloc.alloc(guipp.Register, fields.len);

    inline for (fields, 0..) |reg, i| {
        out[i].name = reg.name;
        out[i].value = @field(regs, reg.name);
    }

    return out;
}

const CVarsWrapper = struct {
    stash: [][:0]const u8,
    vars: []guipp.Variable,

    fn deinit(self: *CVarsWrapper, alloc: Allocator) void {
        for (self.stash) |v| {
            alloc.free(v);
        }

        alloc.free(self.stash);
        alloc.free(self.vars);
    }
};

fn makeCVars(alloc: Allocator, vars: []Debugger.Variable) !CVarsWrapper {
    const out = try alloc.alloc(guipp.Variable, vars.len);

    var stash = std.ArrayList([:0]const u8).init(alloc);
    defer stash.deinit();

    for (vars, 0..) |v, i| {
        try stash.append(try alloc.dupeZ(u8, v.name));
        out[i].name = stash.getLast().ptr;
        try stash.append(try alloc.dupeZ(u8, v.type_name));
        out[i].type_name = stash.getLast().ptr;
        out[i].value = vars[i].value;
    }

    return .{
        .stash = try stash.toOwnedSlice(),
        .vars = out,
    };
}

// FIXME: Generic C null terminated strings + other thing type
const CBreakpointWrapper = struct {
    stash: [][:0]const u8,
    breakpoints: []guipp.Breakpoint,

    fn deinit(self: *CBreakpointWrapper, alloc: Allocator) void {
        for (self.stash) |v| {
            alloc.free(v);
        }

        alloc.free(self.stash);
        alloc.free(self.breakpoints);
    }
};

fn makeCBreakpoints(alloc: Allocator, debugger: *const Debugger) !CBreakpointWrapper {
    var bp_it = debugger.breakpoints.keyIterator();

    const out = try alloc.alloc(guipp.Breakpoint, debugger.breakpoints.count() + debugger.pending_breakpoints.count());

    var stash = std.ArrayList([:0]const u8).init(alloc);
    defer stash.deinit();

    var i: usize = 0;
    while (bp_it.next()) |addy| {
        defer i += 1;
        var loc = try debugger.dwarf_info.sourceLocation(
            alloc,
            addy.*,
            // FIXME: getLineProgramSection maybe shouldn't be public i dunno
            debugger.getLineProgramSection(),
        );
        defer loc.deinit(alloc);

        try stash.append(try alloc.dupeZ(u8, loc.path));
        out[i] = .{
            .file = stash.getLast().ptr,
            .line = loc.line,
        };
    }

    var pending_bp_it = debugger.pending_breakpoints.keyIterator();
    while (pending_bp_it.next()) |addy| {
        defer i += 1;

        // FIXME: function
        var loc = try debugger.dwarf_info.sourceLocation(
            alloc,
            addy.*,
            // FIXME: getLineProgramSection maybe shouldn't be public i dunno
            debugger.getLineProgramSection(),
        );
        defer loc.deinit(alloc);

        try stash.append(try alloc.dupeZ(u8, loc.path));
        out[i] = .{
            .file = stash.getLast().ptr,
            .line = loc.line,
        };
    }

    return .{
        .stash = try stash.toOwnedSlice(),
        .breakpoints = out,
    };
}

export fn debuggerContinue(handle: *DebuggerThread.Handle) void {
    handle.mutex.lock();
    defer handle.mutex.unlock();

    handle.mutex_protected.cont = true;
    handle.cv.broadcast();
}
