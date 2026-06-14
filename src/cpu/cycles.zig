//! Cycle-accounting model for the 386 real-mode core.
//!
//! ============================================================================
//! INTERIM DETERMINISTIC FLAT MODEL — *NOT* hardware-accurate 386 timing.
//! ============================================================================
//!
//! This is the **deterministic flat cycle model** (the M5 decision). It is an
//! INTENTIONAL, DOCUMENTED interim timing model, NOT an attempt at faithful
//! Intel-80386 clock counts. Read this header before assuming any number here is
//! a real 386 figure — it is not, and is not presented as one.
//!
//! ## Why a flat model (and why it is NOT a "fake")
//!
//! The CLAUDE.md prime directive is **determinism**: byte-identical machine
//! state at cycle N, every run. Determinism requires the cycle ledger to be a
//! *total pure function of (CPU state, inputs, the deterministic event
//! schedule)* with **no holes** — every path must charge a fixed, reproducible
//! cost. Determinism does NOT require the costs to be *accurate* 386 figures; it
//! requires them to be *fixed*. A flat-per-instruction cost satisfies the prime
//! directive completely.
//!
//! The CLAUDE.md ground rule forbids *fakes* — papering over missing behaviour
//! to make something *appear* to work. A flat model is the opposite of a fake:
//! it is honestly labelled as interim and provisional-by-design, it makes no
//! claim to be a real clock count, and it is a complete, hole-free, pure
//! function. The distinction is the whole point: a "fake" would be presenting
//! `4` as *the* 386 clock count for `ADD r/m,r`; this model presents `FLAT_BASE`
//! as *a deterministic interim cost*, explicitly not the PRM figure.
//!
//! ## What is deferred (fidelity only, NOT a blocker)
//!
//! Transcribing the faithful Intel 80386 PRM "Instruction Set Clock Count
//! Summary" per-instruction counts (D6) is a future **fidelity-only** pass. It
//! is NOT on the critical path and does NOT block real-mode sign-off, because:
//!   * D8 asserts state, not cycles, against the conformance vectors — the flat
//!     model cannot regress conformance;
//!   * determinism needs fixed costs, which this already provides.
//! When the PRM is sourced, the fidelity pass is a **data swap, not a rewrite**:
//!   * `table[key].base` is per-dispatch-key, so per-instruction PRM counts drop
//!     straight in (set `.base` per key, flip `.provisional = false`);
//!   * the named event costs below become the PRM real-mode interrupt/IRET
//!     figures;
//!   * the choke point in `dispatch.executeOne` (charges `baseFor(key)`) and the
//!     by-construction guard in `interrupts.step` do not move.
//!
//! ## The model (the exact scheme)
//!
//!   * **Flat per-instruction base.** Every dispatch key charges a single fixed
//!     base of `FLAT_BASE` cycles, looked up by the D2 u12 dispatch key at the
//!     Phase 1a cost-charging choke point. This includes the #UD / default arm
//!     (its key also resolves to `FLAT_BASE` — never zero, so faults still
//!     advance the ledger). The lookup is a *total* function over all 0x400
//!     keys: every key, defined or not, maps to a non-zero base.
//!   * **Data-dependent multi-step ops stay pure functions of the operands.**
//!     REP / string ops are modelled re-entrant at the instruction boundary
//!     (Phase 4g): each iteration is a separate `executeOne`, so a count-`N` REP
//!     charges `N * FLAT_BASE` — it is NOT collapsed to one tick, and an
//!     interrupt mid-REP lands on a deterministic iteration that is a pure
//!     function of the cycle ledger.
//!   * **Faults / IVT delivery charge fixed documented costs** (`fault_delivery`,
//!     `interrupt_delivery`, `iret_return`) added on top at the exact points
//!     they occur, so every fault/interrupt path advances `cycles` by a fixed
//!     reproducible amount.
//!   * **HLT/idle (D11).** The CPU charges NO host-derived idle. On HLT,
//!     `step()` returns `halted` with the idle-to-next-event count; the MACHINE
//!     fast-forwards emulated time to the scheduler's next event (a pure
//!     function of the deterministic event schedule). No number in this file is
//!     ever derived from host time.
//!   * **EA / segment / misalignment penalties:** folded into the flat base for
//!     now (`ea_simple = 0`); D12 waives the misalignment penalty. These are
//!     fidelity knobs for the deferred PRM pass.

const std = @import("std");

/// The flat per-instruction base cost (interim deterministic model). A small
/// fixed positive number: positive so the ledger always advances (hole-free
/// guarantee); the exact value is arbitrary-but-fixed and carries NO claim to be
/// a real 386 clock count. The deferred PRM pass replaces this per key.
pub const FLAT_BASE: u16 = 4;

/// Per-instruction cycle entry. `provisional = true` marks a value that is the
/// interim flat cost, NOT a transcribed PRM figure. The deferred fidelity pass
/// sets the real `.base` per key and flips this to `false`.
pub const Entry = struct {
    base: u16,
    provisional: bool = true,
};

/// The number of dispatch keys. The key is
/// (op32?0x200) | (0F?0x100) | opcode, so the maximum is 0x200|0x100|0xFF =
/// 0x3FF; allocate the full 0x400.
pub const KEY_COUNT = 0x400;

/// Flat array indexed by dispatch key. INTERIM deterministic flat model: every
/// key (defined or not) charges `FLAT_BASE`. Kept as a per-key table so the
/// deferred PRM fidelity pass is a data swap, not a rewrite. The total-function
/// guarantee (every key non-zero) is asserted at comptime below and exercised by
/// the exhaustive sweep in determinism_test.zig.
pub const table: [KEY_COUNT]Entry = blk: {
    @setEvalBranchQuota(KEY_COUNT * 4);
    var t: [KEY_COUNT]Entry = undefined;
    for (0..KEY_COUNT) |i| {
        t[i] = .{ .base = FLAT_BASE, .provisional = true };
    }
    break :blk t;
};

// Total-function guarantee, enforced at comptime: no dispatch key (incl. the
// #UD/default arm's key) may charge zero. This is the cost-charging-by-
// construction invariant (Phase 1a / Theme E) verified before any test runs.
comptime {
    @setEvalBranchQuota(KEY_COUNT * 4);
    for (table) |e| {
        if (e.base == 0) @compileError("cycles.table has a zero-cost key (ledger hole)");
    }
}

/// Base cost for a dispatch key. Total over the full u12 key space.
pub fn baseFor(key: u12) u16 {
    return table[key].base;
}

// Named event costs (interim flat model; the deferred PRM pass replaces these
// with the real-mode interrupt/IRET figures). All fixed and positive so every
// fault/interrupt/return path advances the ledger deterministically.
pub const interrupt_delivery: u16 = FLAT_BASE; // IRQ/INT IVT delivery (interim)
pub const iret_return: u16 = FLAT_BASE; // IRET return (interim)
pub const fault_delivery: u16 = FLAT_BASE; // exception IVT delivery (interim)
pub const ea_simple: u16 = 0; // EA penalty folded into the flat base for now (D12)

test "cycle table is a total non-zero function over the full key space" {
    // Every key in the full u12 space (defined or not) charges a fixed non-zero
    // base — the hole-free / by-construction guarantee.
    try std.testing.expectEqual(@as(usize, KEY_COUNT), table.len);
    for (table) |e| try std.testing.expect(e.base > 0);
}

test "event costs are fixed and non-zero (no host-time-derived cost)" {
    try std.testing.expect(interrupt_delivery > 0);
    try std.testing.expect(iret_return > 0);
    try std.testing.expect(fault_delivery > 0);
}
