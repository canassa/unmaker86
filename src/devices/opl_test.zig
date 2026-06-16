//! AdLib / OPL2 (YM3812) timer + status unit tests. These exercise the exact
//! detection sequence an AdLib/SB driver runs (Stunts' AD15.DRV) plus the timer
//! semantics, and prove the overflow is a pure function of the cycle ledger
//! (determinism). No FM synthesis is modeled (D2) — only the guest-observable
//! timers + status byte.

const std = @import("std");
const devices = @import("devices");
const timing = @import("timing");

const Opl = devices.Opl;

/// Bind an OPL to a movable cycle counter (the single time source), like the
/// machine does at `wire`, without pulling in the whole machine.
const Harness = struct {
    opl: Opl = .{},
    cycles: u64 = 0,

    fn wire(self: *Harness) void {
        self.opl.cycles = &self.cycles;
        self.opl.reset();
    }
    /// Write OPL register `reg` = `val` (address port then data port).
    fn writeReg(self: *Harness, reg: u8, val: u8) void {
        self.opl.out8(0x388, reg);
        self.opl.out8(0x389, val);
    }
    fn status(self: *Harness) u8 {
        return self.opl.in8(0x388);
    }
};

test "power-on status is 0 (no timer overflow)" {
    var h = Harness{};
    h.wire();
    try std.testing.expectEqual(@as(u8, 0x00), h.status());
}

test "AD15.DRV detection sequence: status goes 0x00 -> 0xC0 after timer-1 expires" {
    var h = Harness{};
    h.wire();

    // Step 1: reg4 = 0x80 (IRQ reset / clear flags). First status read must be 0.
    h.writeReg(0x04, 0x80);
    try std.testing.expectEqual(@as(u8, 0x00), h.status() & 0xE0);

    // Step 2: reg2 = 0xFF (timer-1 reload: 256-255 = 1 tick = 80us).
    h.writeReg(0x02, 0xFF);
    // Step 3: reg4 = 0x21 (start timer 1, mask timer 2).
    h.writeReg(0x04, 0x21);

    // Immediately after start: no overflow yet.
    try std.testing.expectEqual(@as(u8, 0x00), h.status() & 0xE0);

    // Advance the ledger past one 80us tick. 80us in cycles:
    const tick_cycles: u64 = 80 * timing.CPU_CLOCK_HZ / 1_000_000; // ~1145
    h.cycles += tick_cycles + 1;

    // Now the detection check: (status & 0xE0) == 0xC0 (bit7 IRQ + bit6 timer-1).
    try std.testing.expectEqual(@as(u8, 0xC0), h.status() & 0xE0);
}

test "a masked timer never raises its overflow flag" {
    var h = Harness{};
    h.wire();
    h.writeReg(0x02, 0xFF); // timer-1 reload = 1 tick
    // reg4 = 0x01 | 0x40 = start timer 1 + MASK timer 1 (bit6). Should never set.
    h.writeReg(0x04, 0x41);
    h.cycles += 80 * timing.CPU_CLOCK_HZ / 1_000_000 * 4;
    try std.testing.expectEqual(@as(u8, 0x00), h.status() & 0xE0);
}

test "reg4 bit7 (IRQ reset) clears a pending overflow" {
    var h = Harness{};
    h.wire();
    h.writeReg(0x02, 0xFF);
    h.writeReg(0x04, 0x21); // start timer 1
    h.cycles += 80 * timing.CPU_CLOCK_HZ / 1_000_000 + 1;
    try std.testing.expectEqual(@as(u8, 0xC0), h.status() & 0xE0); // overflowed
    h.writeReg(0x04, 0x80); // IRQ reset
    try std.testing.expectEqual(@as(u8, 0x00), h.status() & 0xE0); // cleared
}

test "timer-2 sets bit5+bit7 (0xA0) at 320us cadence" {
    var h = Harness{};
    h.wire();
    h.writeReg(0x03, 0xFF); // timer-2 reload = 1 tick (320us)
    h.writeReg(0x04, 0x02); // start timer 2 (no mask)
    // Before 320us: not yet.
    h.cycles += 80 * timing.CPU_CLOCK_HZ / 1_000_000; // only ~one 80us tick
    try std.testing.expectEqual(@as(u8, 0x00), h.status() & 0xE0);
    // Past 320us: timer-2 overflow -> bit5 (0x20) + IRQ (0x80) = 0xA0.
    h.cycles += 320 * timing.CPU_CLOCK_HZ / 1_000_000 + 1;
    try std.testing.expectEqual(@as(u8, 0xA0), h.status() & 0xE0);
}

test "overflow timing is a pure function of the cycle ledger (determinism)" {
    // Two independent OPLs driven to the same cycle yield identical status — the
    // overflow depends only on elapsed cycles, never on call count or host time.
    const tick: u64 = 80 * timing.CPU_CLOCK_HZ / 1_000_000;

    var a = Harness{};
    a.wire();
    a.writeReg(0x02, 0xFF);
    a.writeReg(0x04, 0x21);

    var b = Harness{};
    b.wire();
    b.writeReg(0x02, 0xFF);
    b.writeReg(0x04, 0x21);

    // Drive A in many small ledger steps, B in one big jump — same final cycle.
    var i: u64 = 0;
    while (i < tick + 10) : (i += 1) {
        a.cycles += 1;
        _ = a.status(); // repeated reads must not change the pure-function result
    }
    b.cycles = a.cycles;

    try std.testing.expectEqual(b.status(), a.status());
    try std.testing.expectEqual(@as(u8, 0xC0), a.status() & 0xE0);
}

test "snapshot/restore round-trips OPL timer state" {
    var h = Harness{};
    h.wire();
    h.writeReg(0x02, 0x80);
    h.writeReg(0x04, 0x21);
    h.cycles += 4000;

    const snap = h.opl.snapshot();
    var h2 = Harness{};
    h2.cycles = h.cycles;
    h2.opl.cycles = &h2.cycles;
    h2.opl.restore(snap);

    try std.testing.expectEqual(h.status(), h2.status());
}
