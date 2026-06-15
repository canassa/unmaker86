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

// Phase 0: module skeleton only. The breakpoint data model (Phase 1) and the
// controller facade (Phase 2+) are added below as their files land.

test {
    // Empty in Phase 0; the submodule tests are pulled in as they land.
}
