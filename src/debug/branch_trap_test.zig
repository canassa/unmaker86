//! Branch-trace TRAP + no-progress watchdog tests (docs/branch-trace-plan.md §9),
//! driven through the real `Controller.runUntilEvent` against a wired `Machine`. The
//! trap halts AT the derail (CS:IP == the transfer target); the watchdog catches a
//! frozen ledger. Both are reporting-only (zero guest cycles, exactly like a breakpoint
//! check between steps).

const std = @import("std");
const debug = @import("debug.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;
const BranchKind = cpu_mod.branch_trace.BranchKind;

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

// A stub whose RET pops an OUT-OF-RANGE return address (the motivating derail):
//   0x0500: B8 00 02   MOV AX, 0x0200   (a bad return target, below the code range)
//   0x0503: 50         PUSH AX
//   0x0504: C3         RET              -> jumps to 0x0200 (data/garbage)
const STUB: u32 = 0x0500;
fn loadDerailStub(m: *Machine) void {
    const b = &m.bus;
    b.writePhys8(STUB + 0, 0xB8);
    b.writePhys8(STUB + 1, 0x00);
    b.writePhys8(STUB + 2, 0x02);
    b.writePhys8(STUB + 3, 0x50);
    b.writePhys8(STUB + 4, 0xC3);
    m.cpu.st.eip = STUB;
}

test "to_range trap: halts AT the derail target with the culprit RET entry" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadDerailStub(m);
    var c = Controller.init(m);

    _ = c.armBranchTrace(true, 0xFFFF);
    // Code range = the stub's extent; a transfer outside trips.
    _ = c.armBranchTrap(.{ .armed = true, .to_range = true, .to_lo = STUB, .to_hi = STUB + 0x10 });

    const r = c.runUntilEvent(10_000);
    try std.testing.expect(r == .branch_trap);
    try std.testing.expectEqual(@intFromEnum(BranchKind.ret_near), r.branch_trap.entry.kind);
    try std.testing.expectEqual(@as(u16, 0x0200), r.branch_trap.entry.to_ip);
    // The machine is paused AT the transfer target (CS:IP == to), post-transfer.
    try std.testing.expectEqual(@as(u32, 0x0200), m.cpu.st.eip);
    // The latch was consumed (a subsequent run won't re-fire on the stale hit).
    try std.testing.expect(m.branch_trace.trap_hit == null);
}

test "sp_range trap: a RET that leaves SP outside bounds trips" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    // RET at 0x0500 with SP near the top so the post-pop SP exceeds sp_hi.
    m.bus.writePhys8(STUB, 0xC3);
    m.bus.writePhys16(0x6FFE, 0x0510); // planted return target (in range below)
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x6FFE);
    m.cpu.st.eip = STUB;
    var c = Controller.init(m);

    _ = c.armBranchTrace(true, 0xFFFF);
    // Stack window [0..0x6FFE]; the RET pops to SP=0x7000 → above sp_hi → trap.
    _ = c.armBranchTrap(.{ .armed = true, .sp_range = true, .sp_lo = 0, .sp_hi = 0x6FFF });

    const r = c.runUntilEvent(10_000);
    try std.testing.expect(r == .branch_trap);
    try std.testing.expectEqual(@intFromEnum(BranchKind.ret_near), r.branch_trap.entry.kind);
    try std.testing.expectEqual(@as(u16, 0x7000), r.branch_trap.entry.sp);
}

test "kind_match trap: stops on the next IRET" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    // INT 3-free IRET stub: set up the stack frame and execute IRET.
    //   stack: IP=0x0520, CS=0, FLAGS=0x0202
    m.bus.writePhys16(0x6FFA, 0x0520);
    m.bus.writePhys16(0x6FFC, 0x0000);
    m.bus.writePhys16(0x6FFE, 0x0202);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x6FFA);
    m.bus.writePhys8(STUB, 0xCF); // IRET
    m.cpu.st.eip = STUB;
    var c = Controller.init(m);

    _ = c.armBranchTrace(true, 0xFFFF);
    _ = c.armBranchTrap(.{ .armed = true, .kind_match = true, .kind_trap_mask = @as(u16, 1) << @intFromEnum(BranchKind.iret) });

    const r = c.runUntilEvent(10_000);
    try std.testing.expect(r == .branch_trap);
    try std.testing.expectEqual(@intFromEnum(BranchKind.iret), r.branch_trap.entry.kind);
    try std.testing.expectEqual(@as(u32, 0x0520), m.cpu.st.eip);
}

test "trap latch-first: the FIRST out-of-range transfer is reported" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    // 0x0500: E9 00 F0   JMP +0xF000... no — keep it simple with two indirect jmps.
    // 0x0500: FF E3       JMP BX  (BX=0x0100, out of range)  [first derail]
    // landing 0x0100: FF E3   JMP BX again (still 0x0100)     [second derail]
    m.bus.writePhys8(0x0500, 0xFF);
    m.bus.writePhys8(0x0501, 0xE3);
    m.bus.writePhys8(0x0100, 0xFF);
    m.bus.writePhys8(0x0101, 0xE3);
    m.cpu.st.setReg16(@intFromEnum(Reg32.ebx), 0x0100);
    m.cpu.st.eip = 0x0500;
    var c = Controller.init(m);

    _ = c.armBranchTrace(true, 0xFFFF);
    _ = c.armBranchTrap(.{ .armed = true, .to_range = true, .to_lo = 0x0500, .to_hi = 0x0600 });

    const r = c.runUntilEvent(10_000);
    try std.testing.expect(r == .branch_trap);
    // The FIRST jmp (from 0x0500 to 0x0100) is the culprit; the latch was not
    // overwritten by the second jmp at 0x0100.
    try std.testing.expectEqual(@as(u16, 0x0500), r.branch_trap.entry.from_ip);
    try std.testing.expectEqual(@as(u16, 0x0100), r.branch_trap.entry.to_ip);
}

test "trap is cycle-neutral: same cycles to the stop boundary, armed vs disarmed" {
    const alloc = std.testing.allocator;
    // With the trap DISARMED, run to a one-shot execution breakpoint at the derail
    // target; with it ARMED, the branch_trap stops at the SAME boundary. The cycle
    // count at the stop must be identical (reporting-only).
    var cyc_disarmed: u64 = 0;
    var cyc_armed: u64 = 0;
    for (0..2) |mode| {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadDerailStub(m);
        var c = Controller.init(m);
        _ = c.armBranchTrace(true, 0xFFFF);
        if (mode == 0) {
            const id = try c.addBreakpoint(.{ .execution_address = .{ .linear = 0x0200 } }, true);
            _ = id;
            const r = c.runUntilEvent(10_000);
            try std.testing.expect(r == .breakpoint);
            cyc_disarmed = m.cpu.st.cycles;
        } else {
            _ = c.armBranchTrap(.{ .armed = true, .to_range = true, .to_lo = STUB, .to_hi = STUB + 0x10 });
            const r = c.runUntilEvent(10_000);
            try std.testing.expect(r == .branch_trap);
            cyc_armed = m.cpu.st.cycles;
        }
    }
    try std.testing.expectEqual(cyc_disarmed, cyc_armed);
}

test "no_progress watchdog fires on a frozen-ledger spin" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    // Force a frozen, non-terminal state: HLT with an NMI pending but not in service
    // and IF=0. `cpuWakeable` (run_loop) sees the NMI and keeps the run going, but the
    // CPU's own halt-wake rule does not deliver it — so every step charges 0 cycles and
    // the machine never advances. (`permanentlyHalted` returns false for a pending NMI,
    // so the terminal check does not pre-empt the watchdog.) This is exactly the kind of
    // host-emulation derail the watchdog is the backstop for.
    m.cpu.st.halted = true;
    m.cpu.st.nmi_latched = true;
    m.cpu.st.nmi_in_service = false;
    m.cpu.st.eflags.iff = false;
    m.cpu.st.pending_fault = null;
    var c = Controller.init(m);

    const before = m.cpu.st.cycles;
    const r = c.runUntilEvent(std.math.maxInt(u64));
    try std.testing.expect(r == .no_progress);
    try std.testing.expectEqual(before, m.cpu.st.cycles); // the ledger never moved
}

test "snapshot/restore leaves the ring back-pointer + contents untouched by Machine.restore" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadDerailStub(m);
    var c = Controller.init(m);
    _ = c.armBranchTrace(true, 0xFFFF);

    const snap = m.snapshot();
    // Record a transfer (run the stub one RET).
    _ = c.runUntilEvent(10_000);
    try std.testing.expect(m.branch_trace.len > 0);

    // Machine.restore copies only cpu_state + devices — it does NOT touch the ring (an
    // observer field, not in Snapshot) nor the back-pointer (on the CpuWith wrapper).
    m.restore(snap);
    try std.testing.expect(m.cpu.branch_trace == &m.branch_trace); // pointer survived
    try std.testing.expect(m.branch_trace.len > 0); // contents NOT reverted by restore
    // A post-restore transfer still records (the back-pointer is live).
    const prev_total = m.branch_trace.total;
    m.cpu.st.eip = STUB;
    _ = c.runUntilEvent(10_000);
    try std.testing.expect(m.branch_trace.total > prev_total);
}
