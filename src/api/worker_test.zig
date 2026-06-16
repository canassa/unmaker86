//! Phase 3 worker-dispatch tests (§D #1, #5, #7, #9). The proof that the
//! queue/worker layer adds ZERO behavioral change: a fixed command sequence driven
//! through `drainOne` reaches byte-identical machine state vs. the equivalent
//! direct `Controller` calls.

const std = @import("std");
const q = @import("queue.zig");
const worker = @import("worker.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

const PROG: u32 = 0x0500;
fn loadNopProg(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90);
    b.writePhys8(PROG + 8, 0xF4);
    b.writePhys8(PROG + 9, 0xEB);
    b.writePhys8(PROG + 10, 0xFD);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

fn expectStateEqual(a: cpu_mod.State, b: cpu_mod.State) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

/// Run one command through `drainOne` synchronously (no thread; the worker loop is
/// thread-agnostic — the threading is exercised separately in queue_test).
fn drain(ctrl: *Controller, cmd: q.Command) q.Response {
    var ctx: q.RequestCtx = .{ .cmd = cmd };
    return worker.drainOne(ctrl, &ctx, .{}, null);
}

test "#1 queue-drive == direct-call: byte-identical state (CPU + RAM)" {
    const alloc = std.testing.allocator;

    // Path A: drive via drainOne.
    const ma = try makeMachine(alloc);
    defer destroy(alloc, ma);
    var ca = Controller.init(ma);
    _ = drain(&ca, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 4 } }, .one_shot = false } });
    _ = drain(&ca, .{ .run = .{ .cycle_cap = 10_000 } });
    _ = drain(&ca, .cpu_get);
    _ = drain(&ca, .step);
    {
        var ctx: q.RequestCtx = .{ .cmd = .{ .mem_write = .{ .phys = 0x600, .len = 3 } } };
        ctx.scratch[0] = 0xde;
        ctx.scratch[1] = 0xad;
        ctx.scratch[2] = 0xbe;
        _ = worker.drainOne(&ca, &ctx, .{}, null);
    }
    _ = drain(&ca, .{ .mem_peek = .{ .phys = 0x600, .len = 3 } });

    // Path B: equivalent direct Controller calls.
    const mb = try makeMachine(alloc);
    defer destroy(alloc, mb);
    var cb = Controller.init(mb);
    _ = try cb.addBreakpoint(.{ .cycle = .{ .at_cycle = 4 } }, false);
    _ = cb.runUntilEvent(10_000);
    _ = cb.cpuSnapshot();
    _ = cb.stepInstruction();
    cb.writeMemPhys(0x600, &.{ 0xde, 0xad, 0xbe });
    var peek: [3]u8 = undefined;
    cb.peekMemPhys(0x600, &peek);

    // Byte-identical CPU state + RAM slab.
    try expectStateEqual(ma.cpu.st, mb.cpu.st);
    try std.testing.expectEqualSlices(u8, ma.bus.ram, mb.bus.ram);
}

test "#1b run response StopReason matches the direct call exactly" {
    const alloc = std.testing.allocator;
    const ma = try makeMachine(alloc);
    defer destroy(alloc, ma);
    var ca = Controller.init(ma);
    _ = drain(&ca, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 4 } }, .one_shot = false } });
    const resp = drain(&ca, .{ .run = .{ .cycle_cap = 10_000 } });
    try std.testing.expect(resp == .stop);

    const mb = try makeMachine(alloc);
    defer destroy(alloc, mb);
    var cb = Controller.init(mb);
    _ = try cb.addBreakpoint(.{ .cycle = .{ .at_cycle = 4 } }, false);
    const direct = cb.runUntilEvent(10_000);

    // Same tag and same at_cycle.
    try std.testing.expectEqualStrings(@tagName(resp.stop), @tagName(direct));
    switch (resp.stop) {
        .breakpoint => |h| try std.testing.expectEqual(direct.breakpoint.at_cycle, h.at_cycle),
        else => return error.WrongStopReason,
    }
}

test "#7 typed ErrCode per Controller.Error" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);

    // NoSuchBreakpoint: remove / enable / get a bad id.
    try std.testing.expectEqual(q.ErrCode.no_such_breakpoint, drain(&c, .{ .remove_bp = .{ .id = 9 } }).err);
    try std.testing.expectEqual(q.ErrCode.no_such_breakpoint, drain(&c, .{ .enable_bp = .{ .id = 9, .on = false } }).err);
    try std.testing.expectEqual(q.ErrCode.no_such_breakpoint, drain(&c, .{ .get_bp = .{ .id = 9 } }).err);

    // BreakpointTableFull: fill all 64 slots, the 65th add errors.
    var i: u32 = 0;
    while (i < debug.MAX_BREAKPOINTS) : (i += 1) {
        const r = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 1 } }, .one_shot = false } });
        try std.testing.expect(r == .bp_id);
    }
    try std.testing.expectEqual(q.ErrCode.breakpoint_table_full, drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 1 } }, .one_shot = false } }).err);
}

test "#7b memory out-of-range and over-cap codes" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);

    // Over the 4096 chunk cap → out_of_range.
    try std.testing.expectEqual(q.ErrCode.out_of_range, drain(&c, .{ .mem_peek = .{ .phys = 0, .len = q.MAX_MEM_CHUNK + 1 } }).err);

    // Beyond the addressable slab → address_out_of_range. Find ram size.
    var total: u32 = 0;
    for (c.memoryRegions()) |reg| {
        if (reg.kind == .ram) total = reg.len;
    }
    try std.testing.expectEqual(q.ErrCode.address_out_of_range, drain(&c, .{ .mem_peek = .{ .phys = total - 2, .len = 16 } }).err);
    // A valid in-slab peek succeeds.
    try std.testing.expect(drain(&c, .{ .mem_peek = .{ .phys = 0x500, .len = 8 } }) == .mem);
}

test "#9 breakpoint list golden order: ascending id regardless of add/remove churn" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);

    // Add ids 0,1,2,3, then remove id 1 → reused as the lowest free slot later.
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 10 } }, .one_shot = false } }); // id 0
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .execution_address = .{ .linear = 0x1000 } }, .one_shot = false } }); // id 1
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .interrupt = .{ .vector = 0x21 } }, .one_shot = true } }); // id 2
    _ = drain(&c, .{ .remove_bp = .{ .id = 1 } });
    // Re-add → lands back in the lowest free slot (id 1).
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 99 } }, .one_shot = false } }); // id 1

    const list = drain(&c, .list_bp);
    try std.testing.expect(list == .bp_list);
    const items = list.bp_list.items[0..list.bp_list.count];
    try std.testing.expectEqual(@as(usize, 3), items.len);
    // Ascending id order: 0, 1, 2.
    try std.testing.expectEqual(@as(u32, 0), items[0].id);
    try std.testing.expectEqual(@as(u32, 1), items[1].id);
    try std.testing.expectEqual(@as(u32, 2), items[2].id);
    // id 1 is the re-added cycle bp at 99.
    try std.testing.expectEqual(@as(u64, 99), items[1].kind.cycle.at_cycle);
    try std.testing.expectEqual(@as(u8, 0x21), items[2].kind.interrupt.vector);
    try std.testing.expectEqual(true, items[2].one_shot);
}

test "#9b clear_bp removes all and reports the count" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 1 } }, .one_shot = false } });
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 2 } }, .one_shot = false } });
    const r = drain(&c, .clear_bp);
    try std.testing.expectEqual(@as(u32, 2), r.cleared);
    try std.testing.expectEqual(@as(u32, 0), drain(&c, .list_bp).bp_list.count);
}

test "input_key command injects a scancode at the 8042 and raises IRQ1 (Model A)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);

    const r = drain(&c, .{ .input_key = .{ .scancode = 0x1E, .make = true, .ext = false, .press = false, .shift = false } });
    try std.testing.expect(r == .ok);
    // The make scancode is in the 8042 output buffer and IRQ1 (master IRR bit1) is set.
    try std.testing.expectEqual(@as(u8, 0x1E), m.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x02), m.pic.master.irr & 0x02);
}

test "input_key break edge encodes scancode|0x80" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    _ = drain(&c, .{ .input_key = .{ .scancode = 0x1E, .make = false, .ext = false, .press = false, .shift = false } });
    try std.testing.expectEqual(@as(u8, 0x9E), m.kbd.in8(0x60)); // 0x1E | 0x80
}

test "input_key ext prepends the 0xE0 prefix" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    _ = drain(&c, .{ .input_key = .{ .scancode = 0x48, .make = true, .ext = true, .press = false, .shift = false } });
    try std.testing.expectEqual(@as(u8, 0xE0), m.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x48), m.kbd.in8(0x60));
}

test "input_key press+shift injects shift make, key make+break, shift break" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    // The {"char":"A"} convenience resolves to scancode 0x1E with shift.
    _ = drain(&c, .{ .input_key = .{ .scancode = 0x1E, .make = true, .ext = false, .press = true, .shift = true } });
    try std.testing.expectEqual(@as(u8, 0x2A), m.kbd.in8(0x60)); // LShift make
    try std.testing.expectEqual(@as(u8, 0x1E), m.kbd.in8(0x60)); // 'a' make
    try std.testing.expectEqual(@as(u8, 0x9E), m.kbd.in8(0x60)); // 'a' break
    try std.testing.expectEqual(@as(u8, 0xAA), m.kbd.in8(0x60)); // LShift break
}

test "input_buffer_full when the 8042 output FIFO is full (no silent drop)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    // Fill the FIFO with single-edge injects; some bytes drain as IRQ1 re-asserts
    // are level-only (no reads here), so the FIFO fills and the next inject errors.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const r = drain(&c, .{ .input_key = .{ .scancode = 0x1E, .make = true, .ext = false, .press = false, .shift = false } });
        if (r == .err) {
            try std.testing.expectEqual(q.ErrCode.input_buffer_full, r.err);
            return; // got the full error -> pass
        }
    }
    return error.ExpectedBufferFull;
}

test "#5 bounded/retained-capacity: the queue ring + scratch do zero allocations after init" {
    // The ring is a fixed [QUEUE_CAP]?*RequestCtx and each RequestCtx carries a
    // fixed scratch buffer — both pre-sized. Driving a burst of commands through
    // drainOne over a CountingAllocator-backed machine must add NO allocations on
    // the dispatch path (the per-request parse arena is exercised in json_wire_test).
    const alloc = std.testing.allocator;
    var counter = CountingAllocator.init(alloc);
    const ca = counter.allocator();

    const m = try makeMachine(ca);
    defer destroy(ca, m);
    var c = Controller.init(m);
    _ = drain(&c, .{ .add_bp = .{ .kind = .{ .cycle = .{ .at_cycle = 3 } }, .one_shot = false } });

    const baseline = counter.alloc_count;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        _ = drain(&c, .{ .run = .{ .cycle_cap = 2 } });
        _ = drain(&c, .step);
        _ = drain(&c, .cpu_get);
        _ = drain(&c, .{ .mem_peek = .{ .phys = 0x500, .len = 16 } });
        var ctx: q.RequestCtx = .{ .cmd = .{ .mem_write = .{ .phys = 0x600, .len = 4 } } };
        _ = worker.drainOne(&c, &ctx, .{}, null);
        _ = drain(&c, .list_bp);
        _ = drain(&c, .status);
    }
    try std.testing.expectEqual(baseline, counter.alloc_count); // zero new allocations on the dispatch path
}

/// A counting allocator wrapper (M1 lineage) — tallies alloc calls so we can assert
/// the dispatch path is alloc-free.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: usize = 0,

    fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }
    fn allocFn(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resizeFn(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, a, new_len, ra);
    }
    fn remapFn(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(buf, a, new_len, ra);
    }
    fn freeFn(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, a, ra);
    }
};
