//! `src/host/` — the host layer (CLAUDE.md module graph: "consumes machine output";
//! may thread, but reaches the worker ONLY through the submit-gated queue, so it never
//! feeds back into emulation ordering — constraint #4). This is the module ROOT.
//!
//! It is the deliberate home for any HOST-CLOCK use (the run-pacer's inter-slice
//! sleep), kept OUTSIDE the `src/api` determinism grep-gate (stream §5.1a): the api
//! gate forbids clock affordances in every embedded api source, so the pacer's clock
//! lives here instead. `/api/run/*` only flips the clockless atomic `api.RunControl`.

const run_pacer = @import("run_pacer.zig");

pub const RunPacer = run_pacer.RunPacer;
pub const SessionPacer = run_pacer.SessionPacer;

test {
    _ = run_pacer;
    _ = @import("run_pacer_test.zig");
}
