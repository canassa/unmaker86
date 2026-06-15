//! The burst run loop (M-D5) — closing the HLT/idle determinism boundary.
//!
//! Per `machine.step()` (the burst-aware primitive, M-D5/M-D10), in fixed order:
//!   1. Fire due events: any event with `fire_cycle <= cpu.st.cycles` (e.g. an
//!      IRQ0 that came due during the previous burst) raises its IRR bit in the
//!      PIC NOW, before the CPU's next boundary check — the single, well-defined
//!      event-firing boundary.
//!   2. Run the CPU one step: the CPU internally runs `serviceInterrupts`
//!      (fault->TF->NMI->IRQ), sampling `pic.getPendingInterrupt()`, so the IRQ
//!      raised in step 1 is recognized here if IF=1 and not interrupt-shadowed
//!      (M-D6). The CPU's interrupt-delivery charge is the only cost added (M-D7).
//!   3. Handle the stop reason:
//!      - .normal   -> continue.
//!      - .halted   -> HLT fast-forward (D11): advance the ledger to
//!        `nextEventCycle()` via `cpu.fastForwardIdle` (the machine NEVER writes
//!        cpu.st.cycles); permanent halt (no events AND not wakeable) surfaces
//!        `.halted_forever` deterministically.
//!      - .shutdown -> triple fault; record + surface `.shutdown` (no auto-reset).

const std = @import("std");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine.zig");

const Machine = machine_mod.Machine;
const StopReason = machine_mod.StopReason;
const CpuStopReason = cpu_mod.StopReason;

/// One step's outcome — either the run should continue, or it has a terminal
/// machine-level stop reason. `.halted_forever`/`.shutdown` are terminal.
pub const StepOutcome = struct {
    /// True if the run loop should keep stepping; false if terminal.
    cont: bool,
    /// The terminal machine StopReason when `cont == false`; else `.normal`.
    reason: StopReason,
};

const cont_outcome: StepOutcome = .{ .cont = true, .reason = .normal };

/// The burst-aware primitive (M-D5). NEVER reads host time; the HLT fast-forward
/// target is `nextEventCycle()`, a pure function of the schedule.
pub fn step(m: *Machine) StepOutcome {
    // Debug-only: the machine must still be wired at its final address (M-D1).
    if (std.debug.runtime_safety) {
        std.debug.assert(m.cpu.bus == &m.bus);
        std.debug.assert(m.cpu.sched == m);
    }

    // 1. Fire due events (raises IRR bits at the deterministic boundary, M-D6).
    m.fireDue();

    // 2. Run the CPU one step.
    const r = m.cpu.step();

    // 3. Handle the stop reason.
    switch (r.stop_reason) {
        .normal => return cont_outcome,
        .shutdown => {
            m.shutdown = true; // also set by onShutdown; idempotent (Phase 6)
            return .{ .cont = false, .reason = .shutdown };
        },
        .halted => {
            // HLT fast-forward (D11). The CPU returned idle-to-next-event in
            // r.cycles_consumed; the canonical target is nextEventCycle().
            const next = m.sched.nextEventCycle();
            if (next == std.math.maxInt(u64)) {
                // No scheduled events: permanent halt iff the CPU is not wakeable.
                // Mirror the CPU's actual wake rule by re-stepping: a wakeable CPU
                // clears `halted` on the next step (interrupts.zig:56-57). If it
                // stays halted with no events, it is halted_forever.
                if (!cpuWakeable(m)) {
                    return .{ .cont = false, .reason = .halted_forever };
                }
                // Wakeable (e.g. a pending IRQ/NMI/fault) — let the next step
                // clear halted and deliver; continue.
                return cont_outcome;
            }
            // Fast-forward through the idle span to the next event cycle. The CPU
            // is the sole ledger writer (cpu.fastForwardIdle), never the machine.
            m.cpu.fastForwardIdle(next);
            return cont_outcome;
        },
    }
}

/// Mirror the CPU's `wakeable()` (interrupts.zig:90-98) WITHOUT mutating state:
/// a pending fault, an NMI, or (IF=1) a pending maskable IRQ wakes a halted CPU.
/// Used only to decide `.halted_forever` deterministically (the CPU side is the
/// source of truth; this is a read-only mirror so the two can't diverge in effect
/// — getPendingInterrupt is a pure query, M-D6).
fn cpuWakeable(m: *Machine) bool {
    const st = &m.cpu.st;
    if (st.pending_fault != null) return true;
    if (st.nmi_pending() and !st.nmi_in_service) return true;
    if (st.eflags.iff) {
        if (m.cpu.pic.getPendingInterrupt() != null) return true;
    }
    return false;
}

/// Run until the cycle budget `n` is consumed, or a terminal stop (M-D13). Returns
/// `.cycles_reached` when the budget is hit. (Breakpoints are NOT a machine
/// concern in M1 — the debug control core in `src/debug/` owns its own run loop
/// over `step` and scans its breakpoint set between steps.)
pub fn runCycles(m: *Machine, n: u64) StopReason {
    const target = m.cpu.st.cycles + n;
    while (m.cpu.st.cycles < target) {
        if (m.shutdown) return .shutdown;
        const out = step(m);
        if (!out.cont) return out.reason;
    }
    return .cycles_reached;
}

/// Run until `predicate(m)` (-> .normal), the `max_cycles` budget is exhausted
/// (-> .cycles_reached), or a terminal stop (M-D13). BOUNDED — never an unbounded
/// host loop. (Breakpoints are NOT a machine concern in M1; see `runCycles`.)
pub fn runUntil(
    m: *Machine,
    predicate: *const fn (*Machine) bool,
    max_cycles: u64,
) StopReason {
    const deadline = m.cpu.st.cycles + max_cycles;
    while (true) {
        if (predicate(m)) return .normal;
        if (m.cpu.st.cycles >= deadline) return .cycles_reached;
        if (m.shutdown) return .shutdown;
        const out = step(m);
        if (!out.cont) return out.reason;
    }
}
