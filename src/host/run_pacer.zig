//! The host-side run-pacer (video-stream §5 / §5.1a) — the paced free-run loop.
//!
//! WHY THIS FILE LIVES IN `src/host/` (the grep-gate resolution, §5.1a): the pacer
//! needs a host clock — it sleeps the remainder of each wall-clock tick after a slice.
//! `src/api/determinism_test.zig` `@embedFile`s every `src/api` source and FAILS the
//! build on any clock affordance (`io.sleep`/`Clock`/`Instant`/...). Putting the
//! clock here, OUTSIDE the embedded api set, keeps that gate intact and unchanged —
//! the `/api/run/*` endpoints only flip the clockless atomic `RunControl.armed`, and
//! the pacer polls it. `src/host/` is the layer CLAUDE.md designates for "consumes
//! machine output"; it reaches the worker ONLY through the submit-gated queue, so it
//! never feeds back into emulation ordering (CLAUDE #4).
//!
//! Determinism contract (§5.1, load-bearing): a paced run to cycle N is BYTE-IDENTICAL
//! to an unpaced `run-to-cycle N`. The pacer is just a loop of bounded
//! `runUntilEvent(slice)` calls on the single worker with host sleeps inserted ONLY
//! BETWEEN slices. The wall clock decides only how fast wall time advances, never how
//! many guest cycles elapse — emulated time stays f(cycles). If the host is slow,
//! slices fall behind real time (the stream just runs slower); we NEVER "catch up" by
//! changing cycle counts (no smear — the anti-Spice86 invariant).
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `Io.sleep(io, duration, clock)` (`Io.zig:2397`): sleep `duration` on `clock`.
//!   - `Io.Duration.fromMilliseconds` / `.fromNanoseconds` (`Io.zig:~975`).
//!   - `Clock.Timestamp.now(io, .awake)` (`Io.zig:804`) + `durationTo` (`:821`) to
//!     measure a slice's wall-time (the MONOTONIC `.awake` clock, never `.real`).

const std = @import("std");
const api = @import("api");
const Io = std.Io;

const CommandQueue = api.CommandQueue;
const RequestCtx = api.RequestCtx;
const RunControl = api.RunControl;
const StopTag = api.StopTag;
const StreamHub = api.StreamHub;
const LiveMouseState = api.LiveMouseState;

/// One paced free-run driver. Created by the server with a `*CommandQueue` (to submit
/// `run_slice` via the submit-gate), the shared `*RunControl` (the clockless arm flag
/// + owner), and an `Io` (for the inter-slice sleep + the elapsed-time read). Its own
/// thread loops while armed; `/api/run/start|stop` flip `RunControl.armed`.
pub const RunPacer = struct {
    queue: *CommandQueue,
    control: *RunControl,
    io: Io,
    /// The live-stream frame producer (§4.1). Optional: null in the pacer's own unit
    /// tests (which only prove paced≡unpaced); set by the server when streaming is wired.
    /// Each fps tick the pacer calls `hub.produceFrame()` (a `framebuffer_get` peek
    /// through the gated queue + a clockless copy into the shared frame). The pacer's
    /// clock decides the SAMPLE CADENCE; the producer itself is clockless.
    hub: ?*StreamHub = null,

    /// The coalesced LIVE-mouse record (plans/mouse-input.md, LOCKED §1/§5). Optional:
    /// null in the pacer's own unit tests (which only prove paced≡unpaced). Set by the
    /// server when the live-mouse path is wired. Each slice the pacer ALWAYS submits one
    /// `input_mouse_fold` through the gated queue — the race-free gate is on the worker
    /// side (`takeFold()` returns null UNDER THE MUTEX when clean), so a no-input slice
    /// folds zero guest cycles. This bounds live-mouse delivery latency to ≤ one slice
    /// (~10 ms) on EMULATED-time cadence (the slice boundary), never the host clock.
    live_mouse: ?*LiveMouseState = null,

    thread: ?std.Thread = null,

    /// Tick counter for the fps frame-sample cadence (capture every Nth ~10 ms slice).
    sample_tick: u32 = 0,

    /// The thread shutdown flag (distinct from `RunControl.armed`: `armed` toggles the
    /// paced run on/off at runtime; `stop_loop` ends the thread entirely at shutdown).
    stop_loop: std.atomic.Value(bool) = .init(false),

    /// The target wall-clock period of ONE slice, in milliseconds. The pacer sleeps
    /// `target_ms − elapsed` after each slice so a slice's real cadence is ~10 ms,
    /// bounding input/control latency (a producer waits at most one slice for the gate,
    /// §5). Derived from the default slice size at the pinned CPU rate; retuned
    /// implicitly if `/api/run/start {slice_cycles}` changes the slice size (the
    /// per-slice sleep auto-corrects via the measured elapsed time).
    pub const TARGET_SLICE_MS: i64 = 10;

    /// Idle-poll period while disarmed (a paused machine costs ~nothing). Small enough
    /// that `/api/run/start` arms with sub-frame latency.
    const IDLE_POLL_MS: i64 = 5;

    /// Spawn the pacer thread. It blocks on `armed` going true (a short poll-sleep),
    /// runs slices while armed, and exits ONLY when `stop_loop` is set at shutdown.
    pub fn start(self: *RunPacer) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signal the loop to exit and join the thread (shutdown ordering §9.1: the server
    /// disarms + joins the pacer BEFORE the worker shutdown sentinel, so no pacer
    /// submit can race the sentinel). Idempotent.
    pub fn join(self: *RunPacer) void {
        self.stop_loop.store(true, .release);
        // Also disarm so the loop's inner slice loop exits promptly.
        self.control.armed.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn runLoop(self: *RunPacer) void {
        const io = self.io;
        while (!self.stop_loop.load(.acquire)) {
            if (!self.control.isArmed()) {
                // Not running: idle-poll for an arm (or shutdown) without busy-spinning.
                // This sleep is host pacing only — no machine cycle is touched here.
                io.sleep(Io.Duration.fromMilliseconds(IDLE_POLL_MS), .awake) catch return;
                continue;
            }
            self.runOneSlice();
        }
    }

    /// Submit ONE `run_slice` through the submit-gate, record the stop, and sleep the
    /// remainder of the wall-clock tick. On a terminal stop, DISARM (don't spin against
    /// a dead machine, §10).
    fn runOneSlice(self: *RunPacer) void {
        const io = self.io;
        const slice = self.control.sliceCycles();

        const t0 = Io.Clock.Timestamp.now(io, .awake);

        // Submit the slice via the SUBMIT-GATE (the gate is inside queue.submit, so a
        // debugger command issued mid-tick serializes correctly — it waits for this
        // in-flight slice at the queue, then runs next; §5.1).
        var ctx: RequestCtx = .{ .cmd = .{ .run_slice = .{ .slice_cycles = slice } } };
        const resp = self.queue.submit(&ctx);

        // Record the stop for /api/run/status and decide whether to keep going.
        const cls = recordAndClassify(self.control, resp);
        if (cls.terminal) {
            // The guest PROGRAM ENDED (not a user breakpoint, a `/api/run/stop`, or
            // shutdown): signal the stream so connected clients get a one-shot
            // `{"event":"stopped",...}` control frame (§6.4). Scoped strictly to the
            // program-end terminals; `markStopped` is itself idempotent (emits once).
            if (cls.program_end) {
                if (self.hub) |hub| hub.markStopped(cls.reason, cls.cycle);
            }
            // Stop submitting against a dead/halted/breakpoint-stopped machine.
            self.control.disarmTerminal();
            return;
        }

        // Live-stream frame production (§4.1): sample at the fps cadence (every Nth
        // ~10 ms slice), independent of the slice size. The producer no-ops when no
        // client is connected, so this is free when nobody is watching. Sampling rides
        // the pacer's existing tick; the producer reaches the worker only via the gated
        // queue, so it charges no cycle (a cycle-neutral peek).
        if (self.hub) |hub| {
            // ticks-per-frame at the slice cadence (1000/TARGET_SLICE_MS ticks/s): one
            // sample every (ticks_per_sec / fps) ticks, min 1.
            const fps: u32 = @max(self.control.getFps(), 1);
            const ticks_per_sec: u32 = @intCast(@max(@divTrunc(@as(i64, 1000), @max(TARGET_SLICE_MS, 1)), 1));
            const ticks_per_frame: u32 = @max(ticks_per_sec / fps, 1);
            self.sample_tick += 1;
            if (self.sample_tick >= ticks_per_frame) {
                self.sample_tick = 0;
                hub.produceFrame();
            }
        }

        // Live-mouse fold (plans/mouse-input.md §4, LOCKED §5): ALWAYS submit one
        // `input_mouse_fold` per slice through the same gated queue. The race-free gate
        // lives on the worker (`takeFold()` returns null UNDER THE MUTEX when the record
        // is clean), so this is a no-op — ZERO guest cycles — unless a POST made the
        // record dirty. This is the ONLY place the live fold reaches the worker; it rides
        // the slice boundary (an EMULATED-time cadence — the fold's cycle position is a
        // fixed function of `slice_cycles`, NOT of when the POST arrived), bounding live
        // delivery latency to ≤ one slice. The keystone determinism invariant holds: no
        // POST ⇒ clean record ⇒ null fold ⇒ byte-identical to a run without this submit.
        if (self.live_mouse != null) {
            var fold_ctx: RequestCtx = .{ .cmd = .input_mouse_fold };
            _ = self.queue.submit(&fold_ctx);
        }

        // Sleep the rest of the tick (host pacing ONLY — never alters slice size or
        // results). If the slice already overran the target (slow host), skip the
        // sleep and run the next slice immediately — we NEVER shrink/grow a slice to
        // "catch up" (no smear).
        const t1 = Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ms = t0.durationTo(t1).raw.toMilliseconds();
        const remaining_ms = TARGET_SLICE_MS - elapsed_ms;
        if (remaining_ms > 0) {
            io.sleep(Io.Duration.fromMilliseconds(remaining_ms), .awake) catch return;
        }
    }
};

/// The classification of one slice's stop: whether the pacer should disarm (`terminal`),
/// whether the cause is the guest PROGRAM ENDING (`program_end` — drives the stream's
/// "stopped" control frame, NOT a breakpoint/user-stop/shutdown), plus the reason token
/// + cycle to carry into that frame (only meaningful when `program_end`).
const Classification = struct {
    terminal: bool,
    program_end: bool = false,
    reason: []const u8 = "",
    cycle: u64 = 0,
};

/// Map the worker's `Response` (a `.stop` carrying a debug `StopReason`) to the compact
/// `StopTag`, record it on the control block, and classify it. A breakpoint also stops
/// the paced run (the debugger took over or a user bp fired) — the pacer disarms so it
/// doesn't immediately re-run past it, but that is NOT a program end (no "stopped" frame).
fn recordAndClassify(control: *RunControl, resp: api.Response) Classification {
    switch (resp) {
        .stop => |reason| {
            const tag: StopTag, const cycle: u64, const terminal: bool = switch (reason) {
                .breakpoint => |b| .{ .breakpoint, b.at_cycle, true },
                .step_complete => |s| .{ .step_complete, s.at_cycle, false },
                .cycle_budget_exhausted => |c| .{ .cycle_budget_exhausted, c.at_cycle, false },
                // A click/tap dwell completion is a WORKER-only outcome (input_mouse/
                // input_key bounded commands), never a paced run_slice result — mapped
                // defensively to the budget tag (non-terminal) so the switch stays total.
                .dwell_complete => |d| .{ .cycle_budget_exhausted, d.at_cycle, false },
                .target_reached => |t| .{ .target_reached, t.at_cycle, false },
                .halted_forever => |h| .{ .halted_forever, h.at_cycle, true },
                .program_terminated => |p| .{ .program_terminated, p.at_cycle, true },
                .shutdown => |s| .{ .shutdown, s.at_cycle, true },
                // A branch-trap is like a breakpoint: disarm the paced run (terminal in
                // the pacer's sense) so it doesn't immediately run past the trap; NOT a
                // program end (no "stopped" stream frame).
                .branch_trap => |t| .{ .branch_trap, t.at_cycle, true },
                // The no-progress watchdog: disarm so the pacer doesn't busy-spin against
                // a frozen-ledger machine. NOT a program end.
                .no_progress => |t| .{ .no_progress, t.at_cycle, true },
            };
            control.recordStop(tag, cycle);
            // Program-end terminals only (NOT breakpoint, step, budget, or shutdown):
            // these are the cases where the guest program itself stopped running.
            const program_end: bool, const token: []const u8 = switch (reason) {
                .program_terminated => .{ true, "program_terminated" },
                .halted_forever => .{ true, "halted" },
                else => .{ false, "" },
            };
            return .{ .terminal = terminal, .program_end = program_end, .reason = token, .cycle = cycle };
        },
        // Any other response to a run_slice is unexpected (the worker only returns
        // `.stop` for it) — treat as terminal so we don't spin.
        else => return .{ .terminal = true },
    }
}
