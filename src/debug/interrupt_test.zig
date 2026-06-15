//! Phase 4 regression tests (M1 §4): interrupt-vector breakpoints fire on a
//! delivery of the watched vector, with correct freshness (a stale delivery from
//! a prior step does not re-fire), and deterministically across runs.

const std = @import("std");
const debug = @import("debug.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

// A program that issues a software INT 0x21 (handler IRETs), then continues, then
// HLTs. The interrupt bp on vector 0x21 must fire at the delivery boundary.
const HANDLER: u32 = 0x0400;
const MAIN: u32 = 0x0500;
fn loadIntProg(m: *Machine) void {
    const b = &m.bus;
    // IVT[0x21] -> HANDLER.
    b.writePhys16(0x21 * 4, @intCast(HANDLER));
    b.writePhys16(0x21 * 4 + 2, 0x0000);
    b.writePhys8(HANDLER, 0xCF); // IRET
    // MAIN: NOP; INT 0x21; NOP; HLT.
    b.writePhys8(MAIN, 0x90); // NOP
    b.writePhys8(MAIN + 1, 0xCD);
    b.writePhys8(MAIN + 2, 0x21); // INT 0x21
    b.writePhys8(MAIN + 3, 0x90); // NOP
    b.writePhys8(MAIN + 4, 0xF4); // HLT
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = MAIN;
}

test "interrupt bp fires on the watched vector delivery; freshness + determinism" {
    const alloc = std.testing.allocator;

    var captured_cycle: ?u64 = null;
    var run: u32 = 0;
    while (run < 2) : (run += 1) {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadIntProg(m);
        var ctrl = Controller.init(m);
        const id = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);

        const r = ctrl.runUntilEvent(10_000);
        switch (r) {
            .breakpoint => |hit| {
                try std.testing.expectEqual(id, hit.id);
                // At the firing boundary, CS:IP is the handler entry (post-delivery).
                try std.testing.expectEqual(@as(u32, HANDLER), m.cpu.st.eip);
                try std.testing.expectEqual(@as(u8, 0x21), m.cpu.st.last_delivered.vector);
                if (captured_cycle) |c| {
                    try std.testing.expectEqual(c, hit.at_cycle); // deterministic
                } else captured_cycle = hit.at_cycle;
            },
            else => return error.WrongStopReason,
        }
    }
}

test "interrupt bp does not re-fire on a stale delivery (freshness)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadIntProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);

    // First run: stop at the INT 0x21 delivery.
    const r1 = ctrl.runUntilEvent(10_000);
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .breakpoint), std.meta.activeTag(r1));
    const seq_at_stop = m.cpu.st.last_delivered.seq;

    // Resume: the handler IRETs and the program runs to HLT. The SAME (now stale)
    // last_delivered must NOT re-fire the bp — only a fresh delivery does. There
    // is no second INT, so the run reaches the permanent HLT.
    const r2 = ctrl.runUntilEvent(10_000);
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r2));
    // No new delivery happened on the resume leg.
    try std.testing.expectEqual(seq_at_stop, m.cpu.st.last_delivered.seq);
}

test "interrupt bp on a DIFFERENT vector does not fire" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadIntProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x10 } }, false); // not delivered
    const r = ctrl.runUntilEvent(10_000);
    // The program delivers INT 0x21 (not 0x10) then HLTs; the bp never fires.
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r));
}

test "last_delivered round-trips through machine snapshot/restore" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadIntProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);
    _ = ctrl.runUntilEvent(10_000);

    const snap = m.snapshot();
    try std.testing.expectEqual(@as(u8, 0x21), snap.cpu_state.last_delivered.vector);
    try std.testing.expect(snap.cpu_state.last_delivered.seq > 0);
}
