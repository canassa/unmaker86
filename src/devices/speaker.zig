//! The PC-speaker control port — KBC port B, I/O port 0x61 (I/O band 5,
//! plans/io-oracle.md §3). This is the register-trace half of the v1 sound
//! contract: NO sample/FM synthesis (USER DECISION D2, deferred). The device
//! models the guest-OBSERVABLE port-0x61 state a PC-speaker tone-programming
//! sequence reads back, exactly as dosbox-x's `read_p61`/`write_p61`
//! (keyboard.cpp:724/739) do, so a real DOS beep routine round-trips faithfully.
//!
//! It is an ordinary `src/devices/` module: it exposes a `PortHandler` for
//! port 0x61 only and keeps a typed back-pointer to the `Pit` (set by the machine
//! at `wire`) so a write can drive channel 2's GATE and a read can sample channel
//! 2's OUT pin — the same wiring dosbox-x has between KBC port B and the 8254.
//! Module-graph: it imports only the bus contract leaf + the sibling pit module's
//! public type (devices may reference each other's types; the machine owns/wires
//! the values). It never imports cpu/machine.
//!
//! Bit layout of port 0x61 (IBM PC/AT KBC port B; dosbox-x MCH_VGA path):
//!   write (write_p61):
//!     bit0  PIT-2 GATE      — drives TIMER_SetGate2(bit0): gate the speaker timer.
//!     bit1  speaker DATA    — the speaker output enable (AND-gated with timer OUT).
//!     bits2-7 stored verbatim into `port_61_data` (other PPI port-B lines).
//!   read (read_p61) returns:
//!     bits0-3 = port_61_data & 0x0F      — what was written (DETERMINISTIC).
//!     bit4 (0x10) = refresh toggle       — wall-clock-ish in dosbox-x
//!                   (fmod(PIC_FullIndex(),0.030)>0.015). zdos derives it from the
//!                   CYCLE LEDGER instead (deterministic in zdos), but it is
//!                   EXCLUDED from cross-emulator goldens (io-oracle.md §3.3/§7).
//!     bit5 (0x20) = TIMER_GetOutput2() || gate-off — channel-2 OUT pin (or forced
//!                   1 when the gate is off). Emulated-time-derived; zdos computes
//!                   it from the cycle ledger but it too is EXCLUDED from goldens.
//!     bits6-7 = 0 on MCH_VGA (the oracle's machine=vgaonly: the CGA/PCJR/Tandy/
//!                   Herc/MDA bit-6/7 special cases do NOT apply, keyboard.cpp:731).
//!
//! Determinism (CLAUDE prime directive): `port_61_data` is plain device state,
//! zero at reset (CLAUDE #5). The two time-derived read bits (4,5) are functions
//! of the u64 cycle counter and the PIT's deterministic OUT model — NEVER the host
//! wall clock (CLAUDE #2). They are nonetheless kept OUT of the oracle golden (the
//! SND1 program masks `inp(0x61) & 0x0F`), so the cross-emulator assertion rests
//! only on the host-independent low nibble.
//!
//! Cycle cost (CLAUDE hard-constraint #1): port I/O is charged by the CPU's IN/OUT
//! instruction cost; the bus port path and this handler add ZERO cycles — there is
//! no host-serviced trap and no hole. Setting the ch2 gate schedules nothing
//! (channel 2 is never an IRQ source; only ch0 drives IRQ0).

const std = @import("std");
const bus_mod = @import("bus");
const pit_mod = @import("pit.zig");
const timing = @import("timing");

const PortHandler = bus_mod.PortHandler;
const Pit = pit_mod.Pit;

/// The PC-speaker / KBC port-B device. The machine OWNS this value and wires its
/// back-pointers (`*Pit`, `*const u64 cycles`) at `wire`.
pub const Speaker = struct {
    /// The last byte written to port 0x61 (the persistent KBC port-B latch). Read
    /// back (low nibble) verbatim; bits 0,1 also gate/enable the speaker.
    port_61_data: u8 = 0,

    // ---- back-pointers wired by the machine at `wire` ----
    /// The 8254 — port 0x61 bit 0 drives ch2's gate; bit 5 read samples ch2 OUT.
    pit: ?*Pit = null,
    /// Points at cpu.st.cycles (the single time source) for the refresh bit.
    cycles: ?*const u64 = null,
    /// The active CPU:PIT multiplier (Phase 2) — points at `&machine.clock.mult`,
    /// bound at `wire`, re-bound on `restore`. The refresh-bit phase converts the
    /// elapsed CPU ledger → device-time at this live ratio. Defaults to
    /// `timing.DEFAULT_MULT` (12) when unbound (stand-alone tests).
    mult: ?*const u64 = null,
    /// The CONTINUOUS device-time accumulator (`&machine.device_time`) — the
    /// LOCKED-design fix. The refresh-bit phase reads "now" from THIS (device-time
    /// directly), NOT from a recompute off `cpu.st.cycles` (the removed SHORTCUT,
    /// which made the PWM phase JUMP on a live mult change). Bound at `wire`,
    /// re-bound on restore, like `cycles`/`mult`. `null` (stand-alone tests) falls
    /// back to the cycle-derived phase. At mult 12 it equals `cpu.st.cycles`.
    device_time: ?*const u64 = null,
    /// The machine's `dt_accounted_cpu` high-water mark — `deviceTimeNow` adds the
    /// uncommitted tail (`cyclesNow - dt_accounted`) so a mid-instruction read is
    /// current. Same machine accumulator, not a per-device anchor.
    dt_accounted: ?*const u64 = null,

    pub fn reset(self: *Speaker) void {
        self.port_61_data = 0;
        // The gate follows bit 0 (= 0 at reset): silence the timer-2 gate so the
        // device and the PIT agree at power-on (write_p61(0,0,0), keyboard.cpp:2879).
        if (self.pit) |p| p.setGate2(false);
    }

    fn cyclesNow(self: *const Speaker) u64 {
        return (self.cycles orelse return 0).*;
    }

    fn multNow(self: *const Speaker) u64 {
        return (self.mult orelse return timing.DEFAULT_MULT).*;
    }

    /// The current DEVICE-TIME "now" — from the machine's CONTINUOUS accumulator
    /// (the LOCKED-design fix) when wired; else (stand-alone test) fall back to
    /// converting the cycle ledger at the current mult. Identity at mult 12.
    fn deviceTimeNow(self: *const Speaker) u64 {
        if (self.device_time) |dt| {
            const acc = self.dt_accounted orelse return dt.*;
            return dt.* + timing.cpuToDevice(self.cyclesNow() - acc.*, self.multNow());
        }
        return timing.cpuToDevice(self.cyclesNow(), self.multNow());
    }

    /// read_p61 (keyboard.cpp:724), MCH_VGA path.
    fn read61(self: *Speaker) u8 {
        var v: u8 = self.port_61_data & 0x0F;
        // bit5: channel-2 OUT, OR forced high when the gate (bit0) is off. dosbox:
        // (TIMER_GetOutput2() || (port_61_data&1)==0) ? 0x20 : 0.
        const gate_off = (self.port_61_data & 0x01) == 0;
        const out2 = if (self.pit) |p| p.out2Bit() else false;
        if (out2 or gate_off) v |= 0x20;
        // bit4: the ~66.6us refresh toggle. dosbox uses wall-clock
        // (fmod(PIC_FullIndex(),0.030)>0.015 ms-domain); zdos derives the SAME
        // square wave from the cycle ledger: high in the second half of each
        // 0.030ms window. This refresh rate is real-time-anchored, so the window
        // + phase live in the mult-independent DEVICE-TIME domain (Phase 1 seam):
        // window = CPU_CLOCK_HZ * 30 / 1_000_000 device-time units; the ledger is
        // converted CPU→device-time before the phase modulo. Device-time ==
        // nominal cycles at the reference mult, so this is byte-identical today.
        const window: u64 = timing.usToDeviceTime(30);
        if (window != 0) {
            const phase = self.deviceTimeNow() % window;
            if (phase >= window / 2) v |= 0x10;
        }
        return v;
    }

    /// write_p61 (keyboard.cpp:739). A change in bit 0 re-gates timer 2; bits 0-1
    /// would re-arm the PC-speaker emitter (a no-op in register-trace v1 — no
    /// synthesis). The full byte is latched.
    fn write61(self: *Speaker, val: u8) void {
        const diff = self.port_61_data ^ val;
        if ((diff & 0x01) != 0) {
            if (self.pit) |p| p.setGate2((val & 0x01) != 0);
        }
        // bits 0-1 toggling would call PCSPEAKER_SetType — register-trace only, so
        // we model no emitter (D2 deferred). The gate above is the observable part.
        self.port_61_data = val;
    }

    // -----------------------------------------------------------------------
    // PortHandler wiring (port 0x61 only).
    // -----------------------------------------------------------------------
    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Speaker = @ptrCast(@alignCast(ctx));
        return switch (port) {
            0x61 => self.read61(),
            else => 0xFF,
        };
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Speaker = @ptrCast(@alignCast(ctx));
        switch (port) {
            0x61 => self.write61(v),
            else => {},
        }
    }

    /// Direct typed port access (tests / internal callers).
    pub fn out8(self: *Speaker, port: u16, v: u8) void {
        portOut8(self, port, v);
    }
    pub fn in8(self: *Speaker, port: u16) u8 {
        return portIn8(self, port);
    }

    const vtable: PortHandler.VTable = .{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    pub fn portHandler(self: *Speaker) PortHandler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (B12 / M-D11). Only `port_61_data` is emulation state;
    // the back-pointers are re-bound by the machine on restore (never by host
    // pointer), and the PIT's ch2 gate is part of the PIT snapshot.
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        port_61_data: u8,
    };
    pub fn snapshot(self: *const Speaker) Snapshot {
        return .{ .port_61_data = self.port_61_data };
    }
    pub fn restore(self: *Speaker, snap: Snapshot) void {
        self.port_61_data = snap.port_61_data;
    }
};
