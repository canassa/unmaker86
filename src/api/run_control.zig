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
    const SLICE_CYCLES_10MS: u64 = timing.PIT_TICK_RATE * timing.DEFAULT_MULT / 100; // 143_181

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

    fn ioless(self: *const RunControl) Io {
        return self.io;
    }

    pub fn init(io: Io) RunControl {
        return .{ .io = io };
    }
};
