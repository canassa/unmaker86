//! The Intel 8254 Programmable Interval Timer — 3 channels, ports 0x40-0x43.
//! Channel 0 schedules IRQ0 as a DETERMINISTIC future-cycle event on the
//! machine's scheduler and re-arms (the BaK-critical timer path).
//!
//! It is an ordinary `src/devices/` module: implements `PortHandler` (0x40-0x43)
//! and is a scheduler-event source. The machine OWNS the `Pit` value and wires
//! its back-pointers (`*Pic`, `*Scheduler`, `*const u64 cycles`) at `wire`.
//!
//! Determinism (M-D6/M-D7/M-D8):
//!   - ch0's IRQ0 fire_cycle is computed by the INTEGER M-D8 conversion (with the
//!     remainder accumulator carried across re-arms in the scheduler), so the
//!     IRQ0 cadence is a pure function of the cycle counter — no host time.
//!   - re-arm uses the SCHEDULED `fire_cycle` (not the burst-overshot
//!     `cpu.st.cycles`) so the period stays exact and overshoot never accumulates.
//!   - the PIT adds ZERO cycles to the ledger (M-D7) — only the CPU's
//!     interrupt-delivery charge counts.
//!   - counter read-back computes the current counter from elapsed CYCLES since
//!     the last arm (`cyclesNow - last_arm_cycle`), never host time.
//! No host time / RNG / float anywhere in the scheduling path (grep-enforced).

const std = @import("std");
const bus = @import("bus");
const timing = @import("timing");

const PortHandler = bus.PortHandler;

/// The scheduler seam the PIT uses, as bound callbacks (M-D1/M-D11) so the device
/// module does NOT import the machine (module-graph rule: devices <- bus/abi only).
/// The machine binds these to its own `Scheduler` at `wire`; on restore it re-binds
/// them. `schedule`/`cancel` are pointer-free w.r.t. the device — they carry an
/// opaque `ctx` (the machine's scheduler). `remainder` access goes through the
/// scheduler too (M-D8 carry), but since the pinned ratio is 12/1 the remainder is
/// always 0; the scheduler owns/snapshots it, so the PIT just passes ticks.
pub const SchedulerApi = struct {
    ctx: *anyopaque,
    /// schedule(ctx, from_cycle, ticks, val) — converts ticks->cycles (carrying
    /// the remainder) and schedules a ch0 event `ticks` PIT ticks after `from`.
    schedule: *const fn (ctx: *anyopaque, from: u64, ticks: u64, val: u32) void,
    /// cancel any live ch0 event.
    cancel: *const fn (ctx: *anyopaque) void,
};

/// 8254 operating mode. Stored per channel.
pub const PitMode = enum(u8) {
    inactive, // power-on: not yet programmed (no event scheduled)
    mode0, // interrupt on terminal count (one-shot)
    mode1, // hardware retriggerable one-shot (gate-driven; ch0 gate tied high)
    mode2, // rate generator (periodic)
    mode3, // square wave (periodic; IRQ0 period = R, OUT toggles at R/2)
    mode4, // software-triggered strobe
    mode5, // hardware-triggered strobe (gate-driven)
};

/// Access mode (control-word bits 5-4): the lobyte/hibyte read/write sequence.
pub const AccessMode = enum(u8) {
    latch, // 00 = counter-latch command (not a persistent access mode)
    lobyte, // 01 = LSB only
    hibyte, // 10 = MSB only
    lohi, // 11 = LSB then MSB
};

/// The PortHandler vtable is built against an INTERFACE the PIT does not need to
/// know its concrete PIC type for — the PIT only needs `raiseIrq(line)`. We keep
/// the PIC dependency as a typed pointer set by the machine at `wire`. To avoid a
/// devices->machine cycle the PIT takes the PIC type by `anytype`-free design:
/// the machine assigns `pic_raise` as a bound callback. Simpler and pointer-free
/// for snapshot: store an opaque `*anyopaque` + a raise fn (re-bound on restore).
pub const RaiseFn = *const fn (ctx: *anyopaque, line: u4) void;

pub const PitChannel = struct {
    mode: PitMode = .inactive,
    access: AccessMode = .lohi,
    bcd: bool = false,

    reload: u16 = 0, // 0 means 65536
    write_latch: u16 = 0, // value being assembled from lobyte/hibyte writes
    write_state: u8 = 0, // 0 = expect LSB, 1 = expect MSB (for lohi)

    read_latch: u16 = 0, // latched counter for a stable read
    latched: bool = false, // a counter-latch command is pending a full read
    read_state: u8 = 0, // 0 = read MSB next (after lohi LSB), see read_latch logic
    read_lohi_phase: u8 = 0, // 0 = LSB next, 1 = MSB next (for lohi live reads)

    status_latched: bool = false, // read-back latched a status byte
    status_value: u8 = 0,

    new_mode: bool = false, // a control word was written; counter not yet loaded
    output: bool = false, // OUT pin state (mode-dependent)

    /// Absolute cycle at which this channel's current count began (M-D8). The
    /// live counter is derived from `cyclesNow - last_arm_cycle`.
    last_arm_cycle: u64 = 0,

    pub fn reset(self: *PitChannel) void {
        self.* = .{};
    }

    /// Effective reload as a tick count (0 -> 65536).
    pub fn reloadTicks(self: *const PitChannel) u64 {
        return if (self.reload == 0) 65536 else self.reload;
    }

    /// The live counter value computed from elapsed cycles since the last arm
    /// (M-D8 — pure function of the cycle ledger, not host time). For periodic
    /// modes (2/3) the counter wraps within the period; mode 0 counts down once.
    pub fn liveCounter(self: *const PitChannel, cycles_now: u64) u16 {
        const period = self.reloadTicks();
        if (period == 0) return 0;
        const elapsed_cycles = cycles_now -% self.last_arm_cycle;
        const elapsed_ticks = timing.cyclesToTicks(elapsed_cycles);
        switch (self.mode) {
            .mode2, .mode3 => {
                const into = elapsed_ticks % period;
                // Counter counts down from reload toward 0.
                return @intCast((period - into) & 0xFFFF);
            },
            else => {
                if (elapsed_ticks >= period) return 0;
                return @intCast((period - elapsed_ticks) & 0xFFFF);
            },
        }
    }
};

pub const Pit = struct {
    channels: [3]PitChannel = .{ .{}, .{}, .{} },

    // ---- back-pointers wired by the machine at `wire` (M-D1) ----
    sched: ?SchedulerApi = null,
    cycles: ?*const u64 = null, // points at cpu.st.cycles (the single time source)
    raise_ctx: ?*anyopaque = null,
    raise_fn: ?RaiseFn = null,

    pub fn reset(self: *Pit) void {
        for (&self.channels) |*c| c.reset();
    }

    fn cyclesNow(self: *const Pit) u64 {
        return (self.cycles orelse return 0).*;
    }

    fn raiseIrq0(self: *Pit) void {
        if (self.raise_fn) |f| f(self.raise_ctx.?, 0);
    }

    // -----------------------------------------------------------------------
    // Channel-0 IRQ0 scheduling (M-D6/M-D8 — the core BaK requirement).
    // -----------------------------------------------------------------------

    /// Arm (or re-arm) channel 0's IRQ0 event for periodic/one-shot modes. `from`
    /// is the absolute cycle the period starts at (arm: `cyclesNow`; re-arm: the
    /// scheduled `fire_cycle`). Cancels any live ch0 event first (reprogram = re-arm).
    fn armCh0(self: *Pit, from: u64) void {
        const s = self.sched orelse return;
        const ch = &self.channels[0];
        s.cancel(s.ctx);
        switch (ch.mode) {
            .inactive => return, // not programmed -> no event
            else => {},
        }
        const ticks = ch.reloadTicks();
        // Mode-2 R==1 is illegal (a degenerate 1-tick re-arm) — flag/guard it
        // (M-D8 / Phase 5): do NOT schedule it.
        if (ch.mode == .mode2 and ticks == 1) {
            std.debug.assert(false); // mode-2 reload==1 is illegal (8254)
            return;
        }
        ch.last_arm_cycle = from;
        s.schedule(s.ctx, from, ticks, 0);
    }

    /// The ch0 event callback (M-D6) — called by the machine's `fireDue` at the
    /// deterministic `fire_cycle`. Raises IRQ0, then re-arms periodic modes from
    /// `fire_cycle` (NOT cyclesNow) so the cadence is exact.
    pub fn onPitCh0Fire(self: *Pit, fire_cycle: u64) void {
        self.raiseIrq0();
        const ch = &self.channels[0];
        switch (ch.mode) {
            .mode2, .mode3 => self.armCh0(fire_cycle), // periodic: re-arm
            else => {}, // mode0/4 one-shot: do not re-arm
        }
    }

    // -----------------------------------------------------------------------
    // Port programming (PortHandler). Ports 0x40/0x41/0x42 = counters,
    // 0x43 = control word / read-back.
    // -----------------------------------------------------------------------

    fn writeControl(self: *Pit, v: u8) void {
        const sel: u8 = v >> 6;
        if (sel == 3) {
            self.readBackCommand(v);
            return;
        }
        const chan: usize = sel;
        const ch = &self.channels[chan];
        const access_bits: u8 = (v >> 4) & 0x03;
        if (access_bits == 0) {
            // Counter-latch command: snapshot the live counter for a stable read.
            ch.read_latch = ch.liveCounter(self.cyclesNow());
            ch.latched = true;
            ch.read_lohi_phase = 0;
            return;
        }
        // A full control word: set access + mode + BCD, await the reload write.
        ch.access = @enumFromInt(access_bits);
        const mode_bits: u8 = (v >> 1) & 0x07;
        ch.mode = decodeMode(mode_bits);
        // BCD (M-D8 ground rule): assert-or-implement — we ASSERT-on-BCD-bit and
        // do NOT silently treat BCD as binary.
        ch.bcd = (v & 0x01) != 0;
        std.debug.assert(!ch.bcd); // BCD counting not implemented; flag, don't fake
        ch.new_mode = true;
        ch.write_state = 0;
        ch.latched = false;
        ch.status_latched = false;
        ch.read_lohi_phase = 0;
        // A new mode cancels any in-flight schedule for ch0; it re-arms on reload.
        if (chan == 0) {
            if (self.sched) |s| s.cancel(s.ctx);
        }
    }

    fn decodeMode(bits: u8) PitMode {
        // Modes 6/7 alias 2/3 on the 8254.
        return switch (bits) {
            0 => .mode0,
            1 => .mode1,
            2, 6 => .mode2,
            3, 7 => .mode3,
            4 => .mode4,
            5 => .mode5,
            else => .mode0,
        };
    }

    fn writeCounter(self: *Pit, chan: usize, v: u8) void {
        const ch = &self.channels[chan];
        std.debug.assert(!ch.bcd);
        var loaded = false;
        switch (ch.access) {
            .lobyte => {
                ch.write_latch = v;
                loaded = true;
            },
            .hibyte => {
                ch.write_latch = @as(u16, v) << 8;
                loaded = true;
            },
            .lohi => {
                if (ch.write_state == 0) {
                    ch.write_latch = v; // LSB
                    ch.write_state = 1;
                } else {
                    ch.write_latch = (ch.write_latch & 0x00FF) | (@as(u16, v) << 8);
                    ch.write_state = 0;
                    loaded = true;
                }
            },
            .latch => {}, // not a write access mode
        }
        if (!loaded) return; // partial write (lohi LSB only) does not arm
        ch.reload = ch.write_latch;
        ch.new_mode = false;
        if (chan == 0) {
            self.armCh0(self.cyclesNow());
        } else {
            ch.last_arm_cycle = self.cyclesNow();
        }
    }

    fn readCounter(self: *Pit, chan: usize) u8 {
        const ch = &self.channels[chan];
        // Read-back status takes precedence if latched (8254).
        if (ch.status_latched) {
            ch.status_latched = false;
            return ch.status_value;
        }
        const value: u16 = if (ch.latched) ch.read_latch else ch.liveCounter(self.cyclesNow());
        switch (ch.access) {
            .lobyte => {
                if (ch.latched) ch.latched = false;
                return @truncate(value);
            },
            .hibyte => {
                if (ch.latched) ch.latched = false;
                return @truncate(value >> 8);
            },
            .lohi, .latch => {
                if (ch.read_lohi_phase == 0) {
                    ch.read_lohi_phase = 1;
                    return @truncate(value); // LSB
                } else {
                    ch.read_lohi_phase = 0;
                    if (ch.latched) ch.latched = false; // clear latch after full read
                    return @truncate(value >> 8); // MSB
                }
            },
        }
    }

    /// 8254 read-back command (OUT 0x43, bits 7-6 = 11): latch counter and/or
    /// status for selected channels. Status byte (dosbox-x `read_status`, M-D8):
    /// bit7 = OUT, bit6 = null-count, bits5-4 = access, bits3-1 = mode, bit0 = BCD.
    fn readBackCommand(self: *Pit, v: u8) void {
        const latch_count = (v & 0x20) == 0; // bit5=0 => latch count
        const latch_status = (v & 0x10) == 0; // bit4=0 => latch status
        var chan: usize = 0;
        while (chan < 3) : (chan += 1) {
            if ((v & (@as(u8, 1) << @intCast(chan + 1))) == 0) continue;
            const ch = &self.channels[chan];
            if (latch_count and !ch.latched) {
                ch.read_latch = ch.liveCounter(self.cyclesNow());
                ch.latched = true;
                ch.read_lohi_phase = 0;
            }
            if (latch_status and !ch.status_latched) {
                ch.status_value = self.statusByte(chan);
                ch.status_latched = true;
            }
        }
    }

    fn statusByte(self: *Pit, chan: usize) u8 {
        const ch = &self.channels[chan];
        var st: u8 = 0;
        // Recompute OUT for the status read (mode-dependent square-wave for mode 3).
        if (self.outBit(chan)) st |= 0x80;
        if (ch.new_mode) st |= 0x40; // null-count: counter not yet loaded
        // Access mode (bits 5-4).
        st |= @as(u8, @intFromEnum(ch.access)) << 4;
        // Mode (bits 3-1).
        const mode_field: u8 = switch (ch.mode) {
            .mode0 => 0,
            .mode1 => 1,
            .mode2 => 2,
            .mode3 => 3,
            .mode4 => 4,
            .mode5 => 5,
            .inactive => 0,
        };
        st |= mode_field << 1;
        if (ch.bcd) st |= 0x01;
        return st;
    }

    /// OUT pin state. Mode 3 (square wave) toggles every half-period (R/2 ticks);
    /// modes 2/0 have their own OUT shape. This affects ONLY read-back/speaker,
    /// NOT the scheduled IRQ0 period (M-D8: IRQ0 period = R for both 2 and 3).
    fn outBit(self: *Pit, chan: usize) bool {
        const ch = &self.channels[chan];
        if (ch.mode == .inactive) return false;
        const period = ch.reloadTicks();
        if (period == 0) return ch.output;
        const elapsed_ticks = timing.cyclesToTicks(self.cyclesNow() -% ch.last_arm_cycle);
        switch (ch.mode) {
            .mode3 => {
                // High for the first half of the period, low for the second.
                const half = period / 2;
                const into = elapsed_ticks % period;
                return into < half;
            },
            .mode2 => {
                // OUT is low for one tick at terminal count, high otherwise.
                const into = elapsed_ticks % period;
                return into != (period - 1);
            },
            else => return ch.output,
        }
    }

    // -----------------------------------------------------------------------
    // PortHandler wiring.
    // -----------------------------------------------------------------------

    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Pit = @ptrCast(@alignCast(ctx));
        return switch (port) {
            0x40 => self.readCounter(0),
            0x41 => self.readCounter(1),
            0x42 => self.readCounter(2),
            else => 0xFF, // 0x43 is write-only on the 8254
        };
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Pit = @ptrCast(@alignCast(ctx));
        switch (port) {
            0x40 => self.writeCounter(0, v),
            0x41 => self.writeCounter(1, v),
            0x42 => self.writeCounter(2, v),
            0x43 => self.writeControl(v),
            else => {},
        }
    }

    /// Direct typed port access (used by tests / internal callers). The bus path
    /// goes through the `*anyopaque` thunks below.
    pub fn out8(self: *Pit, port: u16, v: u8) void {
        portOut8(self, port, v);
    }
    pub fn in8(self: *Pit, port: u16) u8 {
        return portIn8(self, port);
    }

    const vtable: PortHandler.VTable = .{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    pub fn portHandler(self: *Pit) PortHandler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (M-D11) — channel state by value; back-pointers and
    // the scheduler remainder are re-bound / owned elsewhere (the machine re-wires
    // pointers, the scheduler snapshots its own remainder).
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        channels: [3]PitChannel,
    };
    pub fn snapshot(self: *const Pit) Snapshot {
        return .{ .channels = self.channels };
    }
    pub fn restore(self: *Pit, snap: Snapshot) void {
        self.channels = snap.channels;
    }
};
