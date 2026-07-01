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
/// CP437→Unicode-scalar transcode for the worker-side JSON emitters (T16c). Re-exported
/// here so the transport layer reaches it as `core.cp437Scalar`.
pub const cp437Scalar = @import("debugger.zig").cp437Scalar;

/// The pure real-mode stack-unwinder (M-S2 §2). Kept as a submodule so `debug.core.unwind`
/// is reachable from the in-process tests; on the `src/debug` grep gate (no host clock/RNG/
/// float/atomic/thread) like the rest of `core/`.
pub const unwind = @import("unwind.zig");

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

// ─────────────────────────── source window (M-S1.5) ───────────────────────────
// The neutral, slice-bearing source-window DTO (debug-source-inlining-plan §5/§8). The
// worker flattens it into the pointer-free `q.SourceWindow` POD. `text` borrows owned
// bytes out of the `SourceDebugger` source cache (UTF-8, already transcoded), valid for
// the program's lifetime (the same Stopped-epoch borrow `SourceLoc.path` uses). EXCLUDED
// from the reflection gate (transient, frontend-facing, never snapshotted) like the other
// neutral DTOs — covered by the grep gate only.

/// `±DEFAULT_SOURCE_CONTEXT` ≈ 11 total (gdb/pdb/Delve convention, verified plan §1).
pub const DEFAULT_SOURCE_CONTEXT: u16 = 5;
/// The hard cap on rows in one window (so `context` is effectively ≤ 16 each side).
pub const MAX_WINDOW_LINES: u8 = 33;
/// The per-line text cap, in UTF-8 bytes (mirrors `q.DBG_SRC_LINE_CAP`); a longer line is
/// truncated on a codepoint boundary and `truncated` is set. EXPLICIT, never a silent drop.
pub const MAX_LINE_BYTES: u16 = 160;

/// One source line of a window: its 1-based `number`, the (borrowed, ≤MAX_LINE_BYTES,
/// UTF-8) `text`, whether it is the active (location) line, and whether the text was
/// truncated to `MAX_LINE_BYTES`.
pub const SrcLine = struct {
    number: u32,
    text: []const u8,
    active: bool,
    truncated: bool,
};

/// A windowed, line-numbered view around an active source line. `root_index` is the
/// configured source-root INDEX that supplied the text (never a host path — finding #9);
/// `clamped` is set when the requested context exceeded `MAX_WINDOW_LINES`.
pub const SourceWindow = struct {
    file_id: u32,
    active_line: u32,
    clamped: bool,
    root_index: ?u8 = null,
    lines: []const SrcLine,
};

// ─────────────────────────── backtrace / stack unwind (M-S2 §2) ───────────────────────────
// The neutral frame DTO produced by `src/debug/core/unwind.zig`. Slice-bearing (borrowed
// function name / source path), so — like `PcLocation`/`SourceWindow` — it is a worker-side
// render target, EXCLUDED from the reflection gate and NEVER placed on `q.Response` as a
// slice (only the serialized `body_len` crosses the queue, §1). No fabrication (CLAUDE.md
// §2): a frame is either correct or flagged `unreliable`; a case that cannot be unwound
// faithfully TERMINATES the walk with a typed `BacktraceStop`, it never invents a parent.

/// One unwound call frame, innermost-first (DAP/mcp-debugger convention).
pub const Frame = struct {
    /// 0 = innermost (live CS:IP); callers ascend.
    index: u32,
    /// Frame 0: the live CS:IP. Callers: the CALL-SITE address (return-addr − 1, §2.5) so
    /// `source` names the call, not the following statement.
    pc: Addr,
    /// Borrowed function name; null ⇒ no symbol covers this pc.
    function: ?[]const u8 = null,
    /// file:line of the call site (or the live line for frame 0); null ⇒ no line record.
    source: ?SourceLoc = null,
    /// This frame's BP (SS-relative) — the locals base a later `locals` op reads from.
    frame_base: u16,
    /// This frame reached its callee (the next-inner frame) by a FAR call — the callee
    /// pushed a 2-word `CS:IP` return, so unwinding across that edge read `SS:[BP+2]`(IP) +
    /// `SS:[BP+4]`(CS). Always false for frame 0 (the live frame has no in-trace callee).
    is_far: bool = false,
    /// A sanity check rested on an ASSUMPTION (e.g. near/far guessed for a `.map` image, or
    /// a mid-prologue frame 0 whose BP does not yet frame it). An honest "this frame's
    /// identity is suspect" flag — set on assumptions, NEVER silently on a hard failure
    /// (a hard failure terminates the walk instead).
    unreliable: bool = false,
};

/// Why the walk stopped — ALWAYS reported so the agent knows the terminating condition was
/// a real boundary, never a hidden cap or a fabricated parent.
pub const BacktraceStop = enum {
    /// The top frame is the whole trace (frame 0 only; no caller could be walked).
    ok_top,
    /// Saved BP is 0 — the base of the frame chain (`c0`/`_start`).
    bp_zero,
    /// The saved-BP chain stopped strictly ascending, or BP left the stack window / was odd
    /// — the chain is corrupt or we crossed a non-BP frame; stop rather than mis-walk.
    bp_not_increasing,
    /// The reconstructed return address is NOT preceded by a real CALL (the T3
    /// anti-fabrication check): refuse to emit a parent under zero-init-RAM garbage BP.
    no_call_site,
    /// The reconstructed caller maps to no function, and we had NO symbols before it either.
    no_function,
    /// The reconstructed caller maps to no function, but we HAD symbols — the C runtime
    /// startup (C0) / a trampoline; a clean, expected top-of-user-stack boundary.
    c0_startup,
    /// The callee we just left is an INTERRUPT handler; the layout above is the CPU-pushed
    /// `[FLAGS][CS][IP]`, not a BP frame — we cannot BP-walk through it, so stop here.
    interrupt_boundary,
    /// Frame 0 is mid-prologue / frame-less: BP does not (yet) frame it, so the saved-BP
    /// chain is unavailable — emit frame 0 (`unreliable`) only.
    frameless_callee,
    /// Hit the caller-supplied `max_frames` cap (or the DTO buffer) — not a boundary.
    max_frames,
};

/// The unwound stack: `frames` innermost-first (borrowed slice into the caller's buffer),
/// plus the always-present `truncated_reason` (never a silent cap).
pub const Backtrace = struct {
    frames: []const Frame,
    truncated_reason: BacktraceStop,
};

/// The hard cap on unwound frames (bounds the worker's on-stack `Frame` buffer and the
/// nested-JSON body). A caller's `max_frames` is clamped to this.
pub const MAX_FRAMES: usize = 256;

// ─────────────────────────── scopes / locals / variable tree (M-S2 §3) ───────────────────────────
// The neutral DTOs produced by `src/debug/core/vars.zig` (on the grep gate). Slice-bearing
// (borrowed symbol name / a worker scratch-rendered value), so — like `Frame` — they are
// worker-side render targets, EXCLUDED from the reflection gate and NEVER placed on
// `q.Response` as slices (only the serialized `body_len` crosses the queue, §1). No
// fabrication (CLAUDE.md §2): a value is either correct or HONESTLY flagged
// (`outer_frame_register` / `unreadable` / `<null>` / `(?)`), never guessed.

/// The lazy-expansion re-export: `debug.core.vars` is the pure `Storage`-dispatch + type-
/// directed renderer. On the `src/debug` grep gate like the rest of `core/`.
pub const vars = @import("vars.zig");

/// The M-S3 `evaluate` C-expression evaluator (READ-ONLY). Pure, peek-only, zero-cycle — on
/// the `src/debug` grep gate + a dedicated guest-exec/write-symbol assertion so it can never
/// execute the guest or write state.
pub const expr = @import("expr.zig");

/// The host-side expansion-handle node (minted/validated by `SourceDebugger`); re-exported
/// so the worker's `variables{ref}` serializer names it without reaching into `debugger.zig`.
pub const ExpandNode = @import("debugger.zig").ExpandNode;

/// One scope-local (the symbol-layer POD); re-exported so the worker gathers a frame's
/// locals with `core.Local` rather than a deep `symbols/types.zig` path.
pub const Local = @import("../symbols/types.zig").Local;

/// The DAP scope kinds. M-S2 collapses arguments+locals into ONE `locals` scope (T12 —
/// `Local` carries no `isParam`), plus the live `registers` scope (frame 0 only).
pub const ScopeKind = enum { locals, registers, globals };

/// One DAP scope for a frame. `variables_ref` is a lazy handle: pass it to `variables{ref}`
/// to enumerate the scope's variables (u64 epoch|slot, T11).
pub const Scope = struct {
    kind: ScopeKind,
    frame_index: u32,
    variables_ref: u64,
};

/// Whether a variable's value could be read faithfully — the HONEST-degradation axis
/// (CLAUDE.md §2). `ok` carries a value; every other tag carries an EMPTY `value_text`
/// and a typed reason the frontend surfaces verbatim (never a fabricated number).
pub const VarAvail = enum {
    ok,
    /// The value lives in a register the callee overwrote; only frame 0's regs are live.
    outer_frame_register,
    /// The resolved address is not in mapped RAM (a static in a non-resident segment, or a
    /// corrupt outer BP / wild pointer target). DISTINCT from a `<null>` pointer.
    unreadable,
    /// The symbol's storage class is unmodelled (`Storage.other`) — no value location.
    no_storage,
};

/// One rendered variable (a local, a struct member, an array element, or a deref child).
/// `value_text` is rendered into a WORKER scratch buffer (borrowed); `type_ref` lets the
/// worker stream `typeName(type_ref)` straight into the JSON (T13 — `typeName` returns void,
/// so the DTO never carries a borrowed type-name slice). A non-zero `variables_ref` marks an
/// aggregate/array/pointer that expands ONE level via `variables{ref}` (DAP-lazy).
pub const Variable = struct {
    name: []const u8,
    value_text: []const u8 = "",
    avail: VarAvail = .ok,
    addr: ?Addr = null,
    type_ref: u16 = 0,
    variables_ref: u64 = 0,
    /// Bitfield width in bits (0 = not a bitfield) — carried for the member render only.
    bit_width: u8 = 0,
    writable: bool = false,
    /// A SYNTHESIZED type name (M-S3 `evaluate`): an arithmetic/literal/`sizeof`/`&` result
    /// has no `type_ref` (so `typeName` would render `"?"`). When non-empty, `writeVariable`
    /// prefers this borrowed string over streaming `typeName(type_ref)`. Empty ("") for every
    /// graph-typed result (M-S2 locals/inspect), so their rendering is byte-identical. Like
    /// `name`/`value_text`, a transient worker-side render view — EXCLUDED from the reflection
    /// gate (never snapshotted, never a slice on `q.Response`).
    type_text: []const u8 = "",
};

/// The per-expand child cap (a struct's member count / an array page). An array larger than
/// this is PAGED via `variables{ref,start,count}` (T16a), never silently clipped.
pub const MAX_CHILDREN: usize = 256;

/// Max distinct locals gathered for one frame (innermost scope + ancestors). A frame with
/// more visible locals than this is capped (honest — the extras are simply not listed; the
/// TDS corpus never approaches it).
pub const MAX_LOCALS: usize = 256;

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
