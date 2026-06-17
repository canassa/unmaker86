//! The AdLib / OPL2 (Yamaha YM3812) FM-synth card — TIMER + STATUS half only,
//! I/O ports 0x388 (address/status) and 0x389 (data). This is the register-trace
//! sound contract (USER DECISION D2: NO sample/FM synthesis) applied to the OPL,
//! exactly as the PC-speaker device (speaker.zig) models port 0x61 without a tone
//! emitter: we model the guest-OBSERVABLE state — the two timers and the status
//! register an AdLib/SB *detection* routine reads back — so a real DOS AdLib probe
//! round-trips faithfully, but no audio is synthesized.
//!
//! Why this exists: the canonical AdLib presence check (and every Sound-Blaster
//! driver that wraps it, e.g. Stunts' `AD15.DRV`) is:
//!   1. write reg 4 = 0x60  (mask both timers)         ; or 0x80 (reset IRQ flags)
//!   2. read  port 0x388, require (status & 0xE0) == 0x00   ; no flags yet
//!   3. write reg 2 = 0xFF  (timer-1 reload: 1 tick = 80us)
//!   4. write reg 4 = 0x21  (start timer 1, mask timer 2)
//!   5. delay ~80us, then poll port 0x388 until (status & 0xE0) == 0xC0
//!      (bit7 IRQ + bit6 timer-1-overflow set, bit5 timer-2 clear).
//! Without an OPL device port 0x388 reads the floating-bus 0xFF, so step 2 already
//! fails and the driver reports "no card" -> the guest aborts. Modeling the two
//! timers + the status byte makes the probe succeed deterministically.
//!
//! Status register (read port 0x388), matching dosbox-x adlib.cpp `Chip::Read`:
//!   bit 7 (0x80) = IRQ        — set if EITHER unmasked timer has overflowed
//!   bit 6 (0x40) = timer-1 overflow
//!   bit 5 (0x20) = timer-2 overflow
//!   bits 0-4     = 0
//!
//! Control register (reg 4, written via port 0x389 after addressing reg 4):
//!   bit 0 = timer-1 START (1=run, 0=stop)
//!   bit 1 = timer-2 START
//!   bit 5 = timer-2 MASK   (masked -> overflow flag never set / cleared)
//!   bit 6 = timer-1 MASK
//!   bit 7 = IRQ-RESET: clears both overflow flags (and, per the YM3812, the other
//!           bits of this write are ignored when bit7 is set).
//! Reg 2 = timer-1 reload (8-bit; interval = (256-reload) * 80us).
//! Reg 3 = timer-2 reload (8-bit; interval = (256-reload) * 320us).
//!
//! Determinism (CLAUDE prime directive): a timer's overflow is a pure function of
//! the u64 CYCLE LEDGER (`start_cycle`, `interval_cycles`) — never the host wall
//! clock (CLAUDE #2). dosbox-x derives the same overflow from `PIC_FullIndex()`
//! (ms wall time); zdos derives it from elapsed CPU cycles via the shared
//! `timing` leaf, so the AdLib probe's pass/fail is reproducible run-to-run.
//! All device state is plain and zero at reset (CLAUDE #5).
//!
//! Cycle cost (CLAUDE hard-constraint #1): port I/O is charged by the CPU's
//! IN/OUT instruction cost; this handler and the bus port path add ZERO cycles —
//! no host-serviced trap, no ledger hole. The timers schedule NOTHING on the
//! machine scheduler (the OPL timer is not an IRQ source in this register-trace
//! model — there is no INT line wired), so there is no event-queue interaction;
//! overflow is computed lazily at status-read time from the ledger.

const std = @import("std");
const bus_mod = @import("bus");
const timing = @import("timing");

const PortHandler = bus_mod.PortHandler;

/// One OPL timer (timer 1 = 80us/tick, timer 2 = 320us/tick). Overflow is computed
/// lazily from the cycle ledger; nothing is scheduled. Mirrors dosbox-x's
/// `Timer` (adlib.h) but with INTEGER cycle math instead of floating ms.
const Timer = struct {
    /// Per-tick interval in microseconds: 80 (timer 1) or 320 (timer 2). Comptime
    /// per-instance constant — set when the field is constructed.
    micros: u64,
    /// 8-bit reload value (reg 2 / reg 3). Interval = (256 - counter) ticks.
    counter: u8 = 0,
    /// Running flag (control bit 0 / bit 1).
    enabled: bool = false,
    /// Mask flag (control bit 6 for timer 1, bit 5 for timer 2). A masked timer
    /// keeps counting but never raises its overflow flag (and a SetMask clears it).
    masked: bool = false,
    /// Latched overflow flag. Set lazily by `update`, cleared by reset/mask/start.
    overflow: bool = false,
    /// The cycle at which the current interval started (synced on start, and
    /// re-synced past each elapsed interval by `update`).
    start_cycle: u64 = 0,

    /// Interval to overflow, in DEVICE-TIME units (Phase 1 device-time seam): the
    /// OPL tick rate is real-time-anchored, so the period lives in the mult-
    /// independent device-time domain. `interval = (256 - counter) ticks * micros *
    /// CPU_CLOCK_HZ / 1_000_000`. Device-time == nominal cycles at the reference
    /// mult, so this is byte-identical to the former cycle interval; the elapsed
    /// CPU span it is compared against is converted CPU→device-time at each phase
    /// site. The product fits u64 comfortably (256 * 320 * 14_318_184 < 2^41).
    fn intervalDeviceTime(self: *const Timer) u64 {
        const ticks: u64 = 256 - @as(u64, self.counter);
        // us→device-time with the multiply BEFORE the divide (exact floor on the
        // whole product, identical to the former cycle interval math).
        return timing.usToDeviceTime(ticks * self.micros);
    }

    /// dosbox-x `Timer::Update(time)`: if the interval has elapsed, re-sync `start`
    /// to the most recent interval boundary and (when unmasked) latch overflow.
    /// Pure function of the cycle ledger.
    fn update(self: *Timer, now: u64, mult: u64) void {
        if (!self.enabled) return;
        const interval = self.intervalDeviceTime(); // device-time
        if (interval == 0) return; // degenerate; never overflows
        if (now < self.start_cycle) return; // clock went backwards (restore): no-op
        // Phase math in DEVICE-TIME (Phase 1/2 seam): convert the elapsed CPU span
        // CPU→device-time (at the live `mult`) and compare to the device-time
        // interval. Identity at the default mult 12. The re-synced boundary
        // remainder is converted back to a CPU span before subtracting from `now`
        // (`start_cycle` stays CPU cycles, the device's read-back domain).
        const elapsed = timing.cpuToDevice(now - self.start_cycle, mult);
        if (elapsed >= interval) {
            self.start_cycle = now - timing.deviceToCpu(elapsed % interval, mult);
            if (!self.masked) self.overflow = true;
        }
    }

    /// Side-effect-free: would this timer's overflow flag be SET if read now?
    /// (Either already latched, or the interval has elapsed and it is unmasked.)
    /// Pure function of (state, now) — used by the observability peek, not the
    /// real read path (the real read latches via `update`).
    fn wouldOverflow(self: *const Timer, now: u64, mult: u64) bool {
        if (self.overflow) return true;
        if (!self.enabled or self.masked) return false;
        const interval = self.intervalDeviceTime(); // device-time
        if (interval == 0 or now < self.start_cycle) return false;
        return timing.cpuToDevice(now - self.start_cycle, mult) >= interval;
    }

    /// reg 2 / reg 3 write: set the reload value. dosbox re-syncs (Update) before
    /// changing the interval; we do the same at the call site.
    fn setCounter(self: *Timer, val: u8) void {
        self.counter = val;
    }

    /// Control bit0/bit1 = 1: start the timer (only re-syncs `start` when it was
    /// not already running, matching dosbox-x `Start`).
    fn start(self: *Timer, now: u64) void {
        if (!self.enabled) {
            self.enabled = true;
            self.overflow = false;
            self.start_cycle = now;
        }
    }

    fn stop(self: *Timer) void {
        self.enabled = false;
    }

    /// Control bit5/bit6: set the mask. Masking clears a pending overflow flag.
    fn setMask(self: *Timer, set: bool) void {
        self.masked = set;
        if (set) self.overflow = false;
    }

    /// Control bit7 (IRQ reset): clear the overflow flag.
    fn reset(self: *Timer) void {
        self.overflow = false;
    }
};

/// The AdLib / OPL2 card (timer + status only). The machine OWNS this value and
/// wires its `cycles` back-pointer at `wire`.
pub const Opl = struct {
    /// The last register index selected by a write to the address port (0x388).
    reg_index: u8 = 0,
    /// Timer 1: 80us per tick.
    timer1: Timer = .{ .micros = 80 },
    /// Timer 2: 320us per tick.
    timer2: Timer = .{ .micros = 320 },

    // ---- back-pointer wired by the machine at `wire` ----
    /// Points at cpu.st.cycles (the single time source). Overflow is derived from
    /// it, never from host time. Re-bound on restore.
    cycles: ?*const u64 = null,
    /// The active CPU:PIT multiplier (Phase 2) — points at `&machine.clock.mult`,
    /// bound at `wire`, re-bound on `restore`. The OPL phase math converts an
    /// elapsed CPU span ↔ device-time at this live ratio. Defaults to
    /// `timing.DEFAULT_MULT` (12) when unbound (stand-alone tests).
    mult: ?*const u64 = null,

    pub fn reset(self: *Opl) void {
        self.reg_index = 0;
        self.timer1 = .{ .micros = 80 };
        self.timer2 = .{ .micros = 320 };
    }

    fn cyclesNow(self: *const Opl) u64 {
        return (self.cycles orelse return 0).*;
    }

    fn multNow(self: *const Opl) u64 {
        return (self.mult orelse return timing.DEFAULT_MULT).*;
    }

    /// Read the OPL status register (port 0x388). dosbox-x `Chip::Read`: timer-1
    /// overflow -> 0x40|0x80, timer-2 overflow -> 0x20|0x80. Updates the timers
    /// from the ledger first (side-effect-free w.r.t. the ledger — it only mutates
    /// the device's own latched-overflow state, as the real chip does on any read).
    fn readStatus(self: *Opl) u8 {
        const now = self.cyclesNow();
        const mult = self.multNow();
        self.timer1.update(now, mult);
        self.timer2.update(now, mult);
        var v: u8 = 0;
        if (self.timer1.overflow) v |= 0x40 | 0x80;
        if (self.timer2.overflow) v |= 0x20 | 0x80;
        return v;
    }

    /// Side-effect-free status peek for observability (`GET /api/devices`): compute
    /// the status byte WITHOUT latching overflow into device state (a real status
    /// read DOES latch, so this is debug-only — it mirrors `/api/io`'s shadow
    /// contract). Pure function of the cycle ledger + current timer state.
    pub fn statusPeek(self: *const Opl) u8 {
        const now = self.cyclesNow();
        const mult = self.multNow();
        var v: u8 = 0;
        if (self.timer1.wouldOverflow(now, mult)) v |= 0x40 | 0x80;
        if (self.timer2.wouldOverflow(now, mult)) v |= 0x20 | 0x80;
        return v;
    }

    /// Observability accessors (debug snapshot) — the timer's running/mask/reload
    /// state, without exposing the private `Timer` type.
    pub fn timer1Enabled(self: *const Opl) bool {
        return self.timer1.enabled;
    }
    pub fn timer1Masked(self: *const Opl) bool {
        return self.timer1.masked;
    }
    pub fn timer1Reload(self: *const Opl) u8 {
        return self.timer1.counter;
    }
    pub fn timer2Enabled(self: *const Opl) bool {
        return self.timer2.enabled;
    }
    pub fn timer2Masked(self: *const Opl) bool {
        return self.timer2.masked;
    }
    pub fn timer2Reload(self: *const Opl) u8 {
        return self.timer2.counter;
    }

    /// Write the OPL data port (0x389): apply the value to the currently-addressed
    /// register. Only the timer/control registers (2/3/4) have observable effect in
    /// this register-trace model; all other registers (FM operator params) are
    /// accepted and dropped (no synthesis — D2).
    fn writeData(self: *Opl, val: u8) void {
        const now = self.cyclesNow();
        const mult = self.multNow();
        switch (self.reg_index) {
            0x02 => { // timer-1 reload
                self.timer1.update(now, mult);
                self.timer1.setCounter(val);
            },
            0x03 => { // timer-2 reload
                self.timer2.update(now, mult);
                self.timer2.setCounter(val);
            },
            0x04 => { // timer control
                if (val & 0x80 != 0) {
                    // IRQ reset: clear both overflow flags (other bits ignored).
                    self.timer1.reset();
                    self.timer2.reset();
                } else {
                    if (val & 0x01 != 0) self.timer1.start(now) else self.timer1.stop();
                    if (val & 0x02 != 0) self.timer2.start(now) else self.timer2.stop();
                    // dosbox-x: timer0(=timer1).SetMask(bit6), timer1(=timer2).SetMask(bit5).
                    self.timer1.setMask(val & 0x40 != 0);
                    self.timer2.setMask(val & 0x20 != 0);
                }
            },
            else => {}, // FM operator registers: no synthesis (D2) — accepted, dropped.
        }
    }

    // -----------------------------------------------------------------------
    // PortHandler wiring (ports 0x388 address/status + 0x389 data).
    // -----------------------------------------------------------------------
    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Opl = @ptrCast(@alignCast(ctx));
        return switch (port) {
            // Reading the base port returns the status register. The data port
            // (0x389) is not readable on the OPL2 (returns the floating bus); the
            // detection routines never read it.
            0x388 => self.readStatus(),
            else => 0xFF,
        };
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Opl = @ptrCast(@alignCast(ctx));
        switch (port) {
            0x388 => self.reg_index = v, // address port: select register
            0x389 => self.writeData(v), // data port: write to selected register
            else => {},
        }
    }

    /// Direct typed port access (tests / internal callers).
    pub fn out8(self: *Opl, port: u16, v: u8) void {
        portOut8(self, port, v);
    }
    pub fn in8(self: *Opl, port: u16) u8 {
        return portIn8(self, port);
    }

    const vtable: PortHandler.VTable = .{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    pub fn portHandler(self: *Opl) PortHandler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (M-D11). All emulation state is plain; the `cycles`
    // back-pointer is re-bound by the machine on restore (never by host pointer).
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        reg_index: u8,
        timer1: Timer,
        timer2: Timer,
    };
    pub fn snapshot(self: *const Opl) Snapshot {
        return .{
            .reg_index = self.reg_index,
            .timer1 = self.timer1,
            .timer2 = self.timer2,
        };
    }
    pub fn restore(self: *Opl, snap: Snapshot) void {
        self.reg_index = snap.reg_index;
        self.timer1 = snap.timer1;
        self.timer2 = snap.timer2;
    }
};
