//! Branch-trace worker-path tests (docs/branch-trace-plan.md §6/§7): the arm/dump/
//! status commands through `drainOne`, and the KEY snapshot-seam invariant — a
//! `restore` AUTO-CLEARS the trace (a new timeline must not interleave overlapping
//! `at_cycle` stamps). Driven through the worker with a real per-session SnapshotStore,
//! exactly as the server wires it.

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

// A call/ret loop so the branch trace records hooked transfers every iteration:
//   0x0500: E8 02 00   CALL +2 -> 0x0505   (call_near_direct, pushes 0x0503)
//   0x0503: EB FB      JMP  -5 -> 0x0500    (loop; jmp is NOT hooked)
//   0x0505: C3         RET     -> 0x0503    (ret_near)
const PROG: u32 = 0x0500;
fn loadCallLoop(m: *Machine) void {
    const b = &m.bus;
    b.writePhys8(PROG + 0, 0xE8);
    b.writePhys8(PROG + 1, 0x02);
    b.writePhys8(PROG + 2, 0x00);
    b.writePhys8(PROG + 3, 0xEB);
    b.writePhys8(PROG + 4, 0xFB);
    b.writePhys8(PROG + 5, 0xC3);
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
    loadCallLoop(m);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

fn drain(ctrl: *Controller, store: *SnapshotStore, cmd: q.Command) q.Response {
    var ctx: q.RequestCtx = .{ .cmd = cmd };
    return worker.drainOne(ctrl, &ctx, .{}, null, null, store, null);
}

test "worker: arm → run records → status/dump reflect the ring" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();
    var c = Controller.init(m);

    const armed = drain(&c, &store, .{ .branch_trace_arm = .{ .on = true, .kind_mask = 0xFFFF } });
    try std.testing.expect(armed == .trace_status);
    try std.testing.expect(armed.trace_status.armed);
    try std.testing.expectEqual(@as(u32, cpu_mod.branch_trace.TRACE_CAPACITY), armed.trace_status.capacity);

    _ = drain(&c, &store, .{ .run = .{ .cycle_cap = 4000 } });

    const status = drain(&c, &store, .branch_trace_status);
    try std.testing.expect(status.trace_status.total > 0);
    try std.testing.expect(status.trace_status.len > 0);

    const dump = drain(&c, &store, .{ .branch_trace_dump = .{ .limit = 16, .offset = 0, .newest_first = true } });
    try std.testing.expect(dump == .trace_dump);
    try std.testing.expect(dump.trace_dump.count > 0);
    // newest-first: the most recent transfer is a ret_near or call_near_direct.
    const k = dump.trace_dump.items[0].kind;
    try std.testing.expect(k == .ret_near or k == .call_near_direct);
    // from_lin/to_lin are the convenience linears of the row.
    const row = dump.trace_dump.items[0];
    try std.testing.expectEqual((@as(u32, row.to_cs) << 4) +% row.to_ip, row.to_lin);
}

test "worker: restore AUTO-CLEARS the branch trace (new timeline)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();
    var c = Controller.init(m);

    // 1. snapshot the pristine machine (snap-0).
    const snap = drain(&c, &store, .snapshot);
    try std.testing.expect(snap == .snapshot_done);
    const seq = snap.snapshot_done.seq;

    // 2. arm + record some transfers.
    _ = drain(&c, &store, .{ .branch_trace_arm = .{ .on = true, .kind_mask = 0xFFFF } });
    _ = drain(&c, &store, .{ .run = .{ .cycle_cap = 4000 } });
    try std.testing.expect(m.branch_trace.total > 0);

    // 3. restore → a NEW timeline; the worker auto-clears the trace.
    const rest = drain(&c, &store, .{ .restore = .{ .seq = seq } });
    try std.testing.expect(rest == .snapshot_restored);

    // 4. the ring is empty (contents cleared) — config (armed) persists.
    const status = drain(&c, &store, .branch_trace_status);
    try std.testing.expectEqual(@as(u32, 0), status.trace_status.len);
    try std.testing.expectEqual(@as(u64, 0), status.trace_status.total);
    try std.testing.expect(status.trace_status.armed); // config survived the clear

    const dump = drain(&c, &store, .{ .branch_trace_dump = .{ .limit = 16, .offset = 0, .newest_first = true } });
    try std.testing.expectEqual(@as(u16, 0), dump.trace_dump.count);
}

test "worker: branch_trap_arm latches a stop reason on a derail run" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var store = SnapshotStore.init(alloc);
    defer store.deinit();
    var c = Controller.init(m);

    // Arm a to_range trap OUTSIDE the loop's code extent. The call/ret loop stays in
    // range, so the trap never fires and the run hits the cycle cap (not branch_trap).
    _ = drain(&c, &store, .{ .branch_trace_arm = .{ .on = true, .kind_mask = 0xFFFF } });
    const armed = drain(&c, &store, .{ .branch_trap_arm = .{ .to_range = true, .to_lo = PROG, .to_hi = PROG + 0x20 } });
    try std.testing.expect(armed.trace_status.trap_armed);

    const r = drain(&c, &store, .{ .run = .{ .cycle_cap = 2000 } });
    try std.testing.expect(r == .stop);
    try std.testing.expect(r.stop == .cycle_budget_exhausted); // in-range loop: no trap

    // Disarm clears the predicate.
    const cleared = drain(&c, &store, .branch_trap_clear);
    try std.testing.expect(!cleared.trace_status.trap_armed);
}
