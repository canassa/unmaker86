//! `src/debug/` — the in-process, single-threaded, deterministic debugger control
//! core (Milestone 1). This is the module ROOT; it re-exports the public surface.
//!
//! Placement in the module graph (CLAUDE.md): `src/debug/` sits ABOVE `machine`.
//! It imports `cpu` + `machine`; nothing below it imports `debug`. The controller
//! OBSERVES and DRIVES the machine synchronously — it is never part of the
//! emulation timing path: it reads the cycle ledger but the CPU stays the sole
//! writer, it never reads host time, never spawns a thread, never polls, and never
//! punches a hole in the cycle ledger.
//!
//! Milestone-1 scope: breakpoints + run-until-event + stepping + a side-effect-free
//! state inspect/mutate facade, in-process and synchronous. NO HTTP/JSON server
//! (that is Milestone 2, which layers on top of this facade with zero rework).

const breakpoints = @import("breakpoints.zig");

// ---- breakpoint data model (Phase 1) ----
pub const AccessKind = breakpoints.AccessKind;
pub const BreakpointKind = breakpoints.BreakpointKind;
pub const Breakpoint = breakpoints.Breakpoint;
pub const BreakpointSet = breakpoints.BreakpointSet;
pub const Error = breakpoints.Error;
pub const MAX_BREAKPOINTS = breakpoints.MAX_BREAKPOINTS;
pub const default_kind = breakpoints.default_kind;

const controller = @import("controller.zig");

// ---- controller facade (Phase 2+) ----
pub const Controller = controller.Controller;
pub const StopReason = controller.StopReason;
pub const StepOverResult = controller.StepOverResult;
pub const CpuSnapshot = controller.CpuSnapshot;
pub const Reg16 = controller.Reg16;
pub const Reg8 = controller.Reg8;
pub const Region = controller.Region;

test {
    _ = breakpoints;
    _ = controller;
    _ = @import("breakpoints_test.zig");
    _ = @import("controller_test.zig");
    _ = @import("stepping_test.zig");
    _ = @import("interrupt_test.zig");
    _ = @import("determinism_test.zig");
}
