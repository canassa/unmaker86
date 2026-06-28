//! Snapshot / restore tests (snapshot-restore-plan §4/§6), driven THROUGH the worker
//! queue (`drainOne`) with a real per-session `SnapshotStore` wired exactly as the
//! server wires it. Three families:
//!   1. Double-mint byte-identity: snapshot → mutate (cycles/regs/RAM + the 3 DOS
//!      scalars) → restore → byte-identical CPU + RAM + the 3 scalars + cycle counter;
//!      and run-from-restored == run-from-original.
//!   2. Lazy-alloc + cap + no-leak: the testing allocator's leak detector proves
//!      `Session.deinit`'s per-slot free loop releases every lazy slab; an idle store
//!      allocates no slab; the cap is enforced; delete frees a slot for reuse.
//!   3. Deterministic handles: `snap-0`, `snap-1`, … identical across two runs.

const std = @import("std");
const q = @import("queue.zig");
const worker = @import("worker.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const snapshot_store = @import("snapshot_store.zig");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const SnapshotStore = snapshot_store.SnapshotStore;
const Reg32 = cpu_mod.state.Reg32;

// A tiny deterministic guest: INC AX ; INC BX ; JMP $-2 — an infinite register-churning
// loop, so a bounded `run` advances a fixed number of cycles and end state is a pure
// function of the cycle budget (the determinism the snapshot must reproduce).
const PROG: u32 = 0x0500;
fn loadLoopProg(m: *Machine) void {
    const b = &m.bus;
    b.writePhys8(PROG + 0, 0x40); // INC AX
    b.writePhys8(PROG + 1, 0x43); // INC BX
    b.writePhys8(PROG + 2, 0xEB); // JMP rel8
    b.writePhys8(PROG + 3, 0xFC); // -4 → back to PROG
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
    loadLoopProg(m);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

/// Drive one command through `drainOne` with the store wired (no thread — drainOne is
/// thread-agnostic; the threading itself is covered by queue_test).
fn drain(ctrl: *Controller, store: *SnapshotStore, cmd: q.Command) q.Response {
    var ctx: q.RequestCtx = .{ .cmd = cmd };
    return worker.drainOne(ctrl, &ctx, .{}, null, null, store, null);
}

test "double-mint: snapshot → mutate → restore is byte-identical (CPU + RAM + 3 DOS scalars + cycle)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();

    // Advance to a non-trivial state, and set the three guest-mutable DOS scalars to
    // distinctive non-default values BEFORE the snapshot.
    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 500 } });
    m.dos.strategy = .last_fit;
    m.dos.last_error = 0x1234;
    m.dos.breakcheck = true;
    // Poke some RAM so the slab capture is exercised (not all-zero).
    m.bus.writePhys8(0x0600, 0xAB);
    m.bus.writePhys8(0x0601, 0xCD);

    // Snapshot → handle snap-0; record the reference state AT the snapshot instant.
    const snap_resp = drain(&ctrl, &store, .snapshot);
    try std.testing.expect(snap_resp == .snapshot_done);
    try std.testing.expectEqual(@as(u64, 0), snap_resp.snapshot_done.seq);
    const ref_cycle = snap_resp.snapshot_done.cycle;
    try std.testing.expectEqual(m.cpu.st.cycles, ref_cycle);
    const ref_state = m.cpu.st;
    const ref_ram = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ref_ram);

    // Mutate EVERYTHING the snapshot covers: run more cycles, change a register + RAM,
    // and flip the three DOS scalars.
    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 777 } });
    ctrl.setReg32(.eax, 0xDEADBEEF);
    m.bus.writePhys8(0x0600, 0x00);
    m.bus.writePhys8(0x0601, 0x00);
    m.dos.strategy = .first_fit;
    m.dos.last_error = 0;
    m.dos.breakcheck = false;
    try std.testing.expect(m.cpu.st.cycles != ref_cycle);

    // Restore → byte-identical revert of CPU state + RAM + the 3 scalars + the cycle.
    const r = drain(&ctrl, &store, .{ .restore = .{ .seq = 0 } });
    try std.testing.expect(r == .snapshot_restored);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&ref_state), std.mem.asBytes(&m.cpu.st));
    try std.testing.expectEqualSlices(u8, ref_ram, m.bus.ram);
    try std.testing.expectEqual(ref_cycle, m.cpu.st.cycles);
    try std.testing.expectEqual(@as(u16, 0x1234), m.dos.last_error);
    try std.testing.expectEqual(true, m.dos.breakcheck);
    try std.testing.expect(m.dos.strategy == .last_fit);
}

test "run-from-restored == run-from-original (same end state after an identical forward run)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();

    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 300 } });
    _ = drain(&ctrl, &store, .snapshot); // snap-0

    // Original timeline: run K forward, capture the end state.
    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 2000 } });
    const end_state = m.cpu.st;
    const end_ram = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(end_ram);

    // Restore and run the SAME K forward — must reach byte-identical end state.
    _ = drain(&ctrl, &store, .{ .restore = .{ .seq = 0 } });
    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 2000 } });
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&end_state), std.mem.asBytes(&m.cpu.st));
    try std.testing.expectEqualSlices(u8, end_ram, m.bus.ram);
}

test "restore rewinds the cycle counter; a later run_to_cycle works again" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();

    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 400 } });
    const at = m.cpu.st.cycles;
    _ = drain(&ctrl, &store, .snapshot); // snap-0
    _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 5000 } });
    try std.testing.expect(m.cpu.st.cycles > at);

    _ = drain(&ctrl, &store, .{ .restore = .{ .seq = 0 } });
    try std.testing.expectEqual(at, m.cpu.st.cycles);
    // A run_to_cycle to a now-future deadline runs again (the deadline math is relative).
    const r = drain(&ctrl, &store, .{ .run_to_cycle = .{ .cycle = at + 100 } });
    try std.testing.expect(r == .stop);
    try std.testing.expect(m.cpu.st.cycles >= at + 100);
}

test "breakpoints persist across restore; memory watch re-armed (clear-then-rebuild)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();

    // Snapshot with NO breakpoints, then add a memory watch AFTER — the desync the
    // rearm closes (the bus watch table is reverted by restore; the controller's
    // watch_ids are not).
    _ = drain(&ctrl, &store, .snapshot); // snap-0
    const add = drain(&ctrl, &store, .{ .add_bp = .{ .kind = .{ .memory = .{ .linear = 0x0600, .len = 1, .access = .write } }, .one_shot = false } });
    try std.testing.expect(add == .bp_id);

    // Restore: the breakpoint PERSISTS (still listed) and its bus watch is rebuilt, so a
    // following add does not overflow / duplicate the watch table.
    _ = drain(&ctrl, &store, .{ .restore = .{ .seq = 0 } });
    const list = drain(&ctrl, &store, .list_bp);
    try std.testing.expect(list == .bp_list);
    try std.testing.expectEqual(@as(u32, 1), list.bp_list.count);

    // The watch is live: a write to the watched byte during a run fires the breakpoint.
    const run = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 50 } });
    _ = run; // the loop program does not write 0x600; this just proves no crash/overflow.
    // Adding a second memory watch still succeeds (the table was not left full by stacking).
    const add2 = drain(&ctrl, &store, .{ .add_bp = .{ .kind = .{ .memory = .{ .linear = 0x0700, .len = 1, .access = .write } }, .one_shot = false } });
    try std.testing.expect(add2 == .bp_id);
}

test "lazy alloc + cap + list + delete; deterministic snap-<n> handles" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();

    // Idle store allocates NO slab.
    for (&store.slots) |*s| try std.testing.expect(s.slab == null);

    // Fill to the cap; handles are snap-0..snap-(MAX-1) in order.
    var i: u64 = 0;
    while (i < q.MAX_SNAPSHOTS) : (i += 1) {
        const r = drain(&ctrl, &store, .snapshot);
        try std.testing.expect(r == .snapshot_done);
        try std.testing.expectEqual(i, r.snapshot_done.seq);
    }
    // The cap is enforced (no eviction).
    const over = drain(&ctrl, &store, .snapshot);
    try std.testing.expect(over == .err);
    try std.testing.expectEqual(q.ErrCode.snapshot_limit_reached, over.err);

    // list_snapshots reflects the full set.
    const ls = drain(&ctrl, &store, .list_snapshots);
    try std.testing.expect(ls == .snapshot_list);
    try std.testing.expectEqual(@as(u32, q.MAX_SNAPSHOTS), ls.snapshot_list.count);
    try std.testing.expectEqual(@as(u32, q.MAX_SNAPSHOTS), ls.snapshot_list.max);

    // Delete one → a fresh snapshot succeeds and mints the NEXT seq (never reused).
    const del = drain(&ctrl, &store, .{ .delete_snapshot = .{ .seq = 3 } });
    try std.testing.expect(del == .snapshot_deleted);
    try std.testing.expectEqual(@as(u64, 3), del.snapshot_deleted.seq);
    try std.testing.expectEqual(@as(u32, q.MAX_SNAPSHOTS - 1), del.snapshot_deleted.count);

    const again = drain(&ctrl, &store, .snapshot);
    try std.testing.expect(again == .snapshot_done);
    try std.testing.expectEqual(@as(u64, q.MAX_SNAPSHOTS), again.snapshot_done.seq); // monotonic, never 3

    // restore / delete of an unknown handle → no_such_snapshot.
    const bad_r = drain(&ctrl, &store, .{ .restore = .{ .seq = 999 } });
    try std.testing.expectEqual(q.ErrCode.no_such_snapshot, bad_r.err);
    const bad_d = drain(&ctrl, &store, .{ .delete_snapshot = .{ .seq = 999 } });
    try std.testing.expectEqual(q.ErrCode.no_such_snapshot, bad_d.err);

    // The leak detector (testing allocator) verifies `store.deinit` frees every slab.
}

test "deterministic handles: two identical command sequences mint the same snap-<n>" {
    const alloc = std.testing.allocator;
    var seqs_a: [3]u64 = undefined;
    var seqs_b: [3]u64 = undefined;

    inline for (.{ &seqs_a, &seqs_b }) |out| {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        var ctrl = Controller.init(m);
        var store = SnapshotStore.init(alloc);
        defer store.deinit();
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            _ = drain(&ctrl, &store, .{ .run = .{ .cycle_cap = 100 } });
            const r = drain(&ctrl, &store, .snapshot);
            out[k] = r.snapshot_done.seq;
        }
    }
    try std.testing.expectEqualSlices(u64, &seqs_a, &seqs_b);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 2 }, &seqs_a);
}

test "store absent (no wired store) fails loud, never a fake capture" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var ctx: q.RequestCtx = .{ .cmd = .snapshot };
    const r = worker.drainOne(&ctrl, &ctx, .{}, null, null, null, null);
    try std.testing.expect(r == .err);
    try std.testing.expectEqual(q.ErrCode.load_failed, r.err);
}
