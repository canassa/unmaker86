//! Run-ownership arbitration + the pacer arm/disarm flag (video-stream §5.2/§5.3).
//!
//! This is the SHARED, CLOCKLESS coordination state between the (clockless) HTTP
//! handlers in `server.zig` and the host-side run-pacer (`src/host/run_pacer.zig`).
//! It lives in `src/api/` deliberately: it carries NO host clock (only `std.atomic`
//! scalars), so it is safe inside the `src/api` determinism grep-gate. The pacer's
//! actual wall-clock sleep stays in `src/host/` (§5.1a) — this struct only holds the
//! atomic flag the pacer polls and the small status the endpoints read/write.
//!
//! Determinism (CLAUDE #4): nothing here feeds back into WHICH guest cycles run or
//! their order. Arming the pacer changes only how fast wall time advances (the host
//! sleep between slices); the slices themselves are bounded deterministic
//! `runUntilEvent` calls behind the submit-gated queue.
//!
//! Concurrency model:
//!   - `armed` / `owner` / the slice params / `last_*` are plain atomics; producers
//!     and the pacer touch them with acquire/release ordering. There is no machine
//!     state here, so a torn read is impossible (each field is a single atomic word).
//!   - Arbitration (the idle→paced / paced→debugger transitions) is serialized by
//!     `arb`, a CLOCKLESS `Io.Mutex` (the no-timeout `*Uncancelable` variants), so a
//!     `/api/run/start` and a debugger `step` cannot race the owner transition.

const std = @import("std");
const timing = @import("timing");
const Io = std.Io;

/// The single mutually-exclusive run owner (§5.3). `idle` = nobody is driving the
/// machine; `paced` = the run-pacer owns the free-run loop; `debugger` = an explicit
/// bounded debugger command (`run`/`run-to-cycle`/`run-to-address`/`step*`) is in
/// flight and must land deterministically without pacer interleaving.
pub const RunOwner = enum(u8) { idle, paced, debugger };

/// A terminal `StopReason` tag the pacer surfaces to the status endpoint. We keep a
/// compact enum (not the full debug.StopReason union, which carries payloads) so the
/// status is a pointer-free atomic word. `none` = no slice has stopped yet.
pub const StopTag = enum(u8) {
    none,
    breakpoint,
    step_complete,
    cycle_budget_exhausted,
    target_reached,
    halted_forever,
    program_terminated,
    shutdown,
    /// A branch-trace trap fired (docs/branch-trace-plan.md §4) — the paced run disarms
    /// (like a breakpoint), but it is NOT a program end (no "stopped" stream frame).
    branch_trap,
    /// The no-progress watchdog tripped (a frozen ledger) — the paced run disarms so it
    /// does not busy-spin against the stuck machine. Not a program end.
    no_progress,
    /// A paced slice was PREEMPTED by a control command (`/api/run/stop`/`/api/reset` raised
    /// the abort signal). The pacer disarms (like a user stop) so it does not immediately
    /// re-run past the preemption and re-jam the worker. NOT a program end.
    stopped_by_request,
};

pub const RunControl = struct {
    /// The pacer arm flag. `/api/run/start` sets it (owner=paced); `/api/run/stop`
    /// and a self-disarm-on-terminal clear it. The pacer polls it each loop and
    /// exits cleanly when it reads false.
    armed: std.atomic.Value(bool) = .init(false),
    /// The current run owner (`RunOwner` as a u8 for the atomic).
    owner: std.atomic.Value(u8) = .init(@intFromEnum(RunOwner.idle)),

    /// The pacer's slice size in guest cycles (deterministic integer). Read by the
    /// pacer at the top of each loop so `/api/run/start {slice_cycles}` can retune it.
    slice_cycles: std.atomic.Value(u64) = .init(DEFAULT_SLICE_CYCLES),
    /// The target frame-sample cadence (frames/sec). Stored for `/api/run/status`;
    /// the pacer derives the inter-slice sleep from `slice_cycles` + the emulated CPU
    /// rate, not from `fps` (fps gates only the frame producer in a later phase).
    fps: std.atomic.Value(u32) = .init(DEFAULT_FPS),

    /// The last slice's stop tag + the cycle it stopped at (for `/api/run/status`).
    last_stop: std.atomic.Value(u8) = .init(@intFromEnum(StopTag.none)),
    last_cycle: std.atomic.Value(u64) = .init(0),

    /// The host-measured RAW emulation throughput (guest cycles/sec) on the CURRENT
    /// workload, EMA-smoothed by the host pacer. CLOCK-FREE here (a plain atomic word):
    /// the pacer in `src/host/run_pacer.zig` MEASURES it (it owns the wall clock —
    /// `slice_cycles / slice_wall_time`) and STORES it via `setMeasuredHz`; the api layer
    /// only READS it via `getMeasuredHz` to derive the UI-only `sustainableMult`. It is
    /// NEVER an emulation input and NEVER an applied-mult clamp — it changes only how high
    /// the browser's SPEED SLIDER can go (so a user can't pick a mult the host can't pace
    /// in real time → slow-motion). The APPLIED mult stays host-independent (clamped only
    /// by the STATIC `timing.MAX_MULT`), so determinism holds: same inputs ⇒ same machine
    /// state on every host, fast or slow. 0 = never paced yet (no data → don't cap).
    measured_hz: std.atomic.Value(u64) = .init(0),

    /// The PREEMPT signal (robustness against a wedged/hanging guest). A clockless count
    /// of in-flight control commands (`/api/run/stop`, `/api/reset`, MCP `reset`) that need
    /// to seize the single worker NOW, away from a long/unbounded/wedged run. The WORKER's
    /// run loop polls `preemptRequested()` BETWEEN its bounded `runUntilEvent` bursts and, if
    /// set, abandons the run at a clean instruction boundary (`stopped_by_request`) so the
    /// control command lands PROMPTLY. A COUNTER (not a bool) so it is non-starvable and
    /// race-free: it stays raised across the WHOLE control span (begin→submit→end), so a run
    /// that is in flight — or one that starts during the span — keeps yielding until the
    /// control command has actually been serviced; a concurrent run can never clear another
    /// command's pending preempt (the bug a single bool would have). A normal run never sees
    /// it (it is raised only by a wall-clock control action), so determinism is untouched:
    /// the abort changes only WHERE a run pauses, never which cycles ran (constraint #1).
    /// CLOCKLESS atomic — legal in `src/api`, polled in the worker (also `src/api`), NEVER in
    /// the control core (`src/debug`, where the determinism gate forbids atomics).
    preempt_pending: std.atomic.Value(u32) = .init(0),

    /// PUBLISHED machine status (clockless, host-observability only) — the last settled cycle
    /// ledger + applied CPU:PIT mult, stamped by the WORKER after every command it services
    /// (and once at worker start). It lets `GET /api/machines` report each machine's
    /// cycles/mult WITHOUT submitting to that machine's worker — so the machine LIST can NEVER
    /// be blocked by a wedged/long-running machine that is holding its own worker (the
    /// server-robustness invariant: the list endpoint never depends on a stuck per-machine
    /// worker). It is a best-effort observability snapshot (the value AT THE LAST command
    /// boundary; a machine mid-run shows its last settled cycle), NEVER an emulation input —
    /// the authoritative ledger stays `cpu.st.cycles`, read on the worker. `published_mult==0`
    /// means "not yet stamped" (a never-commanded machine), which the reader maps to "unknown".
    published_cycle: std.atomic.Value(u64) = .init(0),
    published_mult: std.atomic.Value(u64) = .init(0),

    /// Serializes the owner transitions so start/stop and debugger commands cannot
    /// race. CLOCKLESS (`*Uncancelable`) — no timeout enters the api grep-gate.
    arb: Io.Mutex = .init,

    /// `Io.Mutex` lock/unlock take an `io` (used only on a contended futex wait — a
    /// bare futex, no clock). Held once at construction so the methods need no `io`
    /// argument. The pacer/server pass their own `Io` to the gated queue separately.
    io: Io,

    /// Default slice size: the guest cycles executed per ~10 ms wall-clock tick
    /// (§5). The pacer runs one slice then sleeps the rest of the tick, so this sets
    /// the effective WALL-CLOCK speed (cycles/sec ≈ `slice_cycles * 100`), NOT guest
    /// determinism (paced ≡ unpaced — `run_pacer.zig`). ~10 ms keeps input/control
    /// latency low (one slice's wall-time).
    ///
    /// The CPU-speed knob (Phase 3) retunes it live: the `/api/cpu/clock` handler sets
    /// `slice_cycles = PIT_TICK_RATE * mult / 100` so the timer's WALL rate stays
    /// correct (18.2 Hz) at any `mult` (the mult cancels in the PIT wall rate — game
    /// pace invariant). The DEFAULT is the TRUE device rate at mult 12
    /// (`PIT_TICK_RATE * 12 / 100` ≈ 143_181, the faithful 14.32 MHz device rate),
    /// NOT the former hardcoded 25 MHz — so the default now plays at faithful 386
    /// speed (the knob is how the user speeds it up). This is WALL-ONLY: paced ≡
    /// unpaced, no cycle golden moves.
    pub const DEFAULT_SLICE_CYCLES: u64 = SLICE_CYCLES_10MS;
    pub const DEFAULT_FPS: u32 = 30;

    /// The default pacer slice = the device rate's cycles-per-10ms at mult 12, so the
    /// timer + all peripherals run at their faithful wall rates (timer 18.2 Hz, VGA
    /// 70.086 Hz). Recomputed for the live mult by the CPU-speed handler. Integer math
    /// (`PIT_TICK_RATE * mult`), no float — inline so the api grep-gate stays clean.
    const SLICE_CYCLES_10MS: u64 = sliceForMult(timing.DEFAULT_MULT); // 143_181

    /// The pacer slice (guest cycles per ~10 ms wall tick) for a given CPU:PIT `mult`, so
    /// the timer's WALL rate stays ~18.2 Hz at ANY speed: `PIT_TICK_RATE * mult / 100`.
    /// This is the SINGLE source of that formula — `DEFAULT_SLICE_CYCLES`, the
    /// `/api/cpu/clock` retune, the MCP `set_clock` retune, AND the provision-time sync all
    /// derive the slice from here, so it can never drift from the applied mult (the exact
    /// drift that made a provisioned non-default-mult machine mis-paced). Integer-only, no
    /// float — the api grep-gate stays clean. WALL-ONLY: the slice changes only how fast wall
    /// time advances, never which guest cycles run (paced ≡ unpaced).
    pub fn sliceForMult(mult: u64) u64 {
        return timing.PIT_TICK_RATE * mult / 100;
    }

    /// The MAXIMUM CPU:PIT mult the host can emulate IN REAL TIME on the current workload —
    /// for the browser to CAP its speed-slider range so a user can't pick a mult the host
    /// can't pace (which runs the emulated clock slow → slow-motion). UI-ONLY: this is NOT
    /// the applied-mult clamp (that stays the STATIC `timing.MAX_MULT`, host-independent for
    /// determinism — an explicit API caller can still request up to `MAX_MULT` and it
    /// applies on every host). Derived from the pacer's measured raw throughput with 10%
    /// headroom: `floor(measured_hz * 9/10 / PIT_TICK_RATE)`, clamped to `[1, MAX_MULT]`.
    /// `measured_hz == 0` (never paced) ⇒ `MAX_MULT` (no data → don't cap). Integer-only,
    /// no float / no clock — the `src/api` determinism grep-gate stays clean.
    pub fn sustainableMult(measured_hz: u64) u64 {
        if (measured_hz == 0) return timing.MAX_MULT;
        const s = measured_hz * 9 / 10 / timing.PIT_TICK_RATE;
        return std.math.clamp(s, @as(u64, 1), timing.MAX_MULT);
    }

    /// Retune the pacer slice to match an APPLIED (already-clamped) CPU:PIT `mult` via the
    /// canonical `sliceForMult`, so the timer wall rate tracks the CPU speed (game-pace
    /// invariant). The pacer reads `slice_cycles` at the top of each slice, so the new value
    /// takes effect next tick. Called by every speed front-end (`/api/cpu/clock`, MCP
    /// `set_clock`, AND provision-time machine minting) so none can drift. WALL-ONLY.
    pub fn syncSliceToMult(self: *RunControl, mult: u64) void {
        self.slice_cycles.store(sliceForMult(mult), .release);
    }

    pub fn getOwner(self: *const RunControl) RunOwner {
        return @enumFromInt(self.owner.load(.acquire));
    }

    fn setOwner(self: *RunControl, o: RunOwner) void {
        self.owner.store(@intFromEnum(o), .release);
    }

    pub fn isArmed(self: *const RunControl) bool {
        return self.armed.load(.acquire);
    }

    /// `/api/run/start`: arm the pacer if no DEBUGGER run is in flight. Returns
    /// `false` if a debugger run owns the machine (the caller replies 409). Idempotent
    /// when already paced (returns true). `slice_cycles==0`/`fps==0` keep the current
    /// value (so `start {}` re-arms with the prior tuning).
    pub fn start(self: *RunControl, slice_cycles: u64, fps: u32) bool {
        self.arb.lockUncancelable(self.ioless());
        defer self.arb.unlock(self.ioless());
        if (self.getOwner() == .debugger) return false; // 409
        if (slice_cycles != 0) self.slice_cycles.store(slice_cycles, .release);
        if (fps != 0) self.fps.store(fps, .release);
        self.setOwner(.paced);
        self.armed.store(true, .release);
        return true;
    }

    /// `/api/run/stop`: disarm the pacer and return ownership to idle. The pacer
    /// stops submitting at the next loop iteration. Safe to call when already idle.
    pub fn stop(self: *RunControl) void {
        self.arb.lockUncancelable(self.ioless());
        defer self.arb.unlock(self.ioless());
        self.armed.store(false, .release);
        // Only relinquish ownership if WE (paced) hold it — never stomp a debugger run.
        if (self.getOwner() == .paced) self.setOwner(.idle);
    }

    /// A debugger command (`step`/`run`/`run-to-cycle`/`run-to-address`) is about to
    /// run: AUTO-DISARM the pacer and take ownership for the command's duration so it
    /// lands deterministically without interleaving pacer slices (§5.3). Returns the
    /// owner to RESTORE afterward via `endDebugger`: if the pacer was armed (owner was
    /// paced) we restore `paced`; otherwise `idle`. The in-flight pacer slice is
    /// allowed to finish — serialization is enforced by the submit-gate, so this
    /// debugger command simply waits for that slice at the queue and then runs next.
    pub fn beginDebugger(self: *RunControl) RunOwner {
        self.arb.lockUncancelable(self.ioless());
        defer self.arb.unlock(self.ioless());
        const prev = self.getOwner();
        self.armed.store(false, .release); // stop the pacer submitting more slices
        self.setOwner(.debugger);
        return prev;
    }

    /// Restore ownership after a debugger command. `restore_to` is `beginDebugger`'s
    /// return: re-arm the pacer if it owned the run before (paced), else go idle.
    pub fn endDebugger(self: *RunControl, restore_to: RunOwner) void {
        self.arb.lockUncancelable(self.ioless());
        defer self.arb.unlock(self.ioless());
        switch (restore_to) {
            .paced => {
                self.setOwner(.paced);
                self.armed.store(true, .release);
            },
            else => {
                self.setOwner(.idle);
            },
        }
    }

    /// The pacer's self-disarm on a terminal slice (§10): stop submitting against a
    /// dead machine and return ownership to idle.
    pub fn disarmTerminal(self: *RunControl) void {
        self.arb.lockUncancelable(self.ioless());
        defer self.arb.unlock(self.ioless());
        self.armed.store(false, .release);
        if (self.getOwner() == .paced) self.setOwner(.idle);
    }

    /// Raise the preempt signal for the duration of a control command (`/api/run/stop`,
    /// `/api/reset`, MCP `reset`). Paired with `endPreempt` (LIFO `defer`). While raised, the
    /// worker's run loop yields any in-flight run at the next burst boundary so the control
    /// command seizes the worker promptly — the non-starvation keystone. Increment/decrement
    /// (a count) so overlapping control commands compose and none clears another's pending
    /// state. clockless (a single atomic RMW); never touches a cycle or the wall clock.
    pub fn beginPreempt(self: *RunControl) void {
        _ = self.preempt_pending.fetchAdd(1, .acq_rel);
    }

    /// Drop this control command's preempt request (the worker stops yielding once the count
    /// reaches zero). Called AFTER the command's own `queue.submit` has completed, so the
    /// worker has actually serviced it before runs resume.
    pub fn endPreempt(self: *RunControl) void {
        _ = self.preempt_pending.fetchSub(1, .acq_rel);
    }

    /// True iff a control command is waiting to seize the worker. Polled by the worker's
    /// bounded-burst run loop BETWEEN bursts (never inside the control core). Acquire-loaded
    /// so the yielding worker sees the raising thread's prior writes.
    pub fn preemptRequested(self: *const RunControl) bool {
        return self.preempt_pending.load(.acquire) > 0;
    }

    /// Stamp the published machine status (the worker calls this after each command + once at
    /// start). clockless host-observability only; never an emulation input.
    pub fn publishStatus(self: *RunControl, cycle: u64, mult: u64) void {
        self.published_cycle.store(cycle, .release);
        self.published_mult.store(mult, .release);
    }
    /// The last settled cycle ledger (for `/api/machines`; non-blocking, off the worker).
    pub fn publishedCycle(self: *const RunControl) u64 {
        return self.published_cycle.load(.acquire);
    }
    /// The last settled CPU:PIT mult, or 0 = "not yet stamped" (never-commanded machine).
    pub fn publishedMult(self: *const RunControl) u64 {
        return self.published_mult.load(.acquire);
    }

    pub fn recordStop(self: *RunControl, tag: StopTag, cycle: u64) void {
        self.last_cycle.store(cycle, .release);
        self.last_stop.store(@intFromEnum(tag), .release);
    }

    pub fn lastStop(self: *const RunControl) StopTag {
        return @enumFromInt(self.last_stop.load(.acquire));
    }
    pub fn lastCycle(self: *const RunControl) u64 {
        return self.last_cycle.load(.acquire);
    }
    pub fn sliceCycles(self: *const RunControl) u64 {
        return self.slice_cycles.load(.acquire);
    }

    /// Retune the pacer slice (the CPU-speed knob, Phase 3): the pacer reads this
    /// atomic at the top of each slice, so the new value takes effect on the next
    /// tick. WALL-ONLY — it changes only how fast wall time advances (paced ≡ unpaced;
    /// no cycle golden moves). Returns the value stored. `slice==0` is a no-op (keeps
    /// the current tuning); otherwise it is stored as-is (the caller derived it from
    /// the applied, already-clamped mult: `PIT_TICK_RATE * mult / 100`).
    pub fn setSlice(self: *RunControl, slice: u64) u64 {
        if (slice == 0) return self.slice_cycles.load(.acquire);
        self.slice_cycles.store(slice, .release);
        return slice;
    }
    pub fn getFps(self: *const RunControl) u32 {
        return self.fps.load(.acquire);
    }

    /// Store the host pacer's EMA-smoothed measured throughput (guest cycles/sec). Called
    /// ONLY from the host pacer (which owns the clock); CLOCK-FREE here. UI-only — see the
    /// `measured_hz` field doc. Wall-pacing telemetry, never an emulation input.
    pub fn setMeasuredHz(self: *RunControl, hz: u64) void {
        self.measured_hz.store(hz, .release);
    }
    /// Read the last measured throughput (0 = never paced). Read by the api layer to derive
    /// the UI-only `sustainableMult`; no clock.
    pub fn getMeasuredHz(self: *const RunControl) u64 {
        return self.measured_hz.load(.acquire);
    }

    fn ioless(self: *const RunControl) Io {
        return self.io;
    }

    pub fn init(io: Io) RunControl {
        return .{ .io = io };
    }
};
