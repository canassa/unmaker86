//! `src/debug/core/` — the protocol-neutral, source-level debug core (milestone
//! M-S1). This is the module sub-root: it re-exports the neutral DTOs and the
//! `SourceDebugger` object. It owns ALL source-level debugging semantics (breakpoint
//! resolution, `pcLocation`, source-line stepping) on top of the already-built Borland
//! TDS symbol overlay (`src/debug/symbols/`) and the synchronous `Controller`.
//!
//! Placement (debug-core-plan.md §1): this sits on the `src/debug` determinism
//! grep-gate — pure + synchronous, NO `src/api` import, NO atomics, NO host clock/RNG,
//! NO float, NO unordered containers. The async/event/session machinery lives one layer up in
//! `src/api`. The worker owns the preempt loop; the pure core exposes only BOUNDED
//! bursts (`stepBurst`) + the line predicate (Finding 1).
//!
//! Determinism (CLAUDE.md §1): the whole core is host-side, OUTSIDE the deterministic
//! machine. It observes and controls; it never alters emulated execution, charges no
//! cycles of its own, and never enters the serialized snapshot. The neutral DTOs below
//! carry resolved `[]const u8` views (paths/names) and so are deliberately EXCLUDED
//! from the reflection gate (they are transient, frontend-facing, never snapshotted);
//! they are covered by the grep gate only (debug-core-plan.md §1 reflection-gate scope).

const std = @import("std");

pub const SourceDebugger = @import("debugger.zig").SourceDebugger;
pub const Error = @import("debugger.zig").Error;

// ─────────────────────────── stepping budgets ───────────────────────────
// FIXED, compile-time constants of the CYCLE COUNTER — never host-derived (no clock,
// no wall time, no thread state, no env). Slicing a step into bursts is byte-identical
// to one unbounded loop: bursts change only WHERE preemption is evaluated, never the
// retired instruction stream (the exact property `worker.zig:runCapPreemptible` proves).

/// The per-burst stepping budget (the worker's preempt granularity), measured as a
/// `Controller.currentCycle()` delta. Mirrors `worker.zig:PREEMPT_BURST_CYCLES`.
pub const STEP_BURST_CYCLES: u64 = 1 << 20;

/// The anti-wedge ceiling: once cumulative stepped cycles reach this with no qualifying
/// line change (a tight no-line loop), the step stops with a reported "budget reached"
/// outcome — never an infinite host loop (debug-core-plan.md §5 / risk 6).
pub const STEP_WEDGE_CAP_CYCLES: u64 = 8_000_000;

// ─────────────────────────── identity & location ───────────────────────────

/// A 16-bit segmented address plus its resolved 20-bit linear form. `linear` is the
/// canonical key (== `breakpoints.currentLinear`); seg:off is carried for display.
pub const Addr = struct { seg: u16, off: u16, linear: u32 };

/// A resolved source position (from the TDS line table + the load_para map). `path` is
/// borrowed from the symbol layer (`SymbolIndex.sourceFile`), stable for the load.
pub const SourceLoc = struct {
    file_id: u32,
    path: []const u8,
    line: u32,
    column: u32 = 0, // TDS has no columns; always 0
};

/// Where the PC is, fully resolved. Any field may be null if symbols don't cover it.
pub const PcLocation = struct {
    addr: Addr,
    function: ?[]const u8 = null,
    source: ?SourceLoc = null,
};

// ─────────────────────────── breakpoints ───────────────────────────

/// A neutral, source-aware breakpoint spec. `function`/`source` resolve to a
/// `Controller` `execution_address{linear}` breakpoint via the symbol layer.
pub const BreakpointSpec = union(enum) {
    addr: struct { linear: u32 },
    function: struct { name: []const u8 },
    source: struct { file: []const u8, line: u32 },
};

/// The outcome of resolving a spec. `verified=false` ⇒ no address (file:line had no
/// code / symbols absent); the spec is still retained and re-resolved on reload.
pub const ResolvedBreakpoint = struct {
    /// A SourceDebugger-stable handle (the spec-table slot index). Survives a reload
    /// even as the underlying Controller breakpoint id changes with the new load_para.
    id: u32,
    spec: BreakpointSpec,
    resolved: ?Addr = null,
    source: ?SourceLoc = null,
    verified: bool,
};

// ─────────────────────────── stop state ───────────────────────────

pub const StopKind = enum { breakpoint, step, pause, entry, fault, exit, terminated };

pub const StopState = struct {
    running: bool,
    kind: ?StopKind,
    pc: ?PcLocation,
    bp_id: ?u32 = null, // set when kind == .breakpoint
    cycle: u64,
    exit_code: ?u16 = null, // set when kind == .exit/.terminated
};

/// Which kind of source step is in flight (set by `beginStep`).
pub const StepKind = enum { line, in, out, to_line };

/// The BOUNDED-burst outcome the WORKER drives (Finding 1). The pure core never polls
/// preempt; it runs one bounded burst and reports either a real stop or that it spent
/// the budget with no qualifying stop (the worker then polls preempt + re-enters).
pub const StepOutcome = union(enum) {
    stopped: StopState,
    budget_exhausted: void,
};

test {
    std.testing.refAllDecls(@This());
}
