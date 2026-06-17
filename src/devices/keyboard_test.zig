//! 8042 keyboard-controller unit tests (input Phase 1a): port read/write +
//! status-byte round-trips, the output FIFO push/pop order, the §5.1b command/
//! response pairs (device cmds on 0x60, controller cmds on 0x64), and IRQ1 assert
//! on scancode injection. The harness binds the device's PIC-raise back-pointer to
//! a recording counter (the same RaiseFn the machine binds), without the machine.

const std = @import("std");
const devices = @import("devices");
const timing = @import("timing");

const Keyboard = devices.Keyboard;

const ST_OBF: u8 = 0x01;
const ST_CMD: u8 = 0x08;

fn msToCycles(ms: u64) u64 {
    return ms * timing.CPU_CLOCK_HZ / 1000;
}

/// A recording IRQ sink standing in for the PIC, plus a minimal single-slot
/// scheduler standing in for the machine scheduler. The keyboard holds at most one
/// live `kbd_repeat` event (cancel-then-schedule discipline), so one slot is
/// faithful. `cycles` is the test-driven cycle ledger the keyboard reads as "now".
const Harness = struct {
    kbd: Keyboard = .{},
    irq1_count: u32 = 0,
    cycles: u64 = 0,

    // ---- single-slot scheduler stand-in ----
    has_event: bool = false,
    fire_cycle: u64 = 0,

    fn raise(ctx: *anyopaque, line: u4) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        if (line == 1) self.irq1_count += 1;
    }
    fn schedule(ctx: *anyopaque, from: u64, delta: u64) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        std.debug.assert(!self.has_event); // cancel-then-schedule invariant
        self.has_event = true;
        self.fire_cycle = from + delta;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.has_event = false;
    }
    fn wire(self: *Harness) void {
        self.kbd.raise_ctx = self;
        self.kbd.raise_fn = raise;
        self.kbd.cycles = &self.cycles;
        self.kbd.sched = .{ .ctx = self, .schedule = schedule, .cancel = cancel };
    }

    /// Advance to the scheduled fire cycle and dispatch one repeat (mirrors the
    /// machine's `fireDue` → `kbd.onRepeatFire`). Returns false if no event is live.
    fn fireOnce(self: *Harness) bool {
        if (!self.has_event) return false;
        const fc = self.fire_cycle;
        self.cycles = fc;
        self.has_event = false; // the event is consumed before the handler re-arms
        self.kbd.onRepeatFire(fc);
        return true;
    }
};

test "power-on config: keyboard IRQ + translate + system flag enabled" {
    var h = Harness{};
    h.wire();
    // Config read-back via controller cmd 0x20 puts the config byte on 0x60.
    h.kbd.out8(0x64, 0x20);
    const cfg = h.kbd.in8(0x60);
    try std.testing.expectEqual(@as(u8, 0x01), cfg & 0x01); // bit0: kbd IRQ
    try std.testing.expectEqual(@as(u8, 0x40), cfg & 0x40); // bit6: translate
    try std.testing.expectEqual(@as(u8, 0x04), cfg & 0x04); // bit2: system flag
}

test "FIFO push pops in order; OBF tracks emptiness" {
    var h = Harness{};
    h.wire();
    try std.testing.expect(h.kbd.pushByte(0x11));
    try std.testing.expect(h.kbd.pushByte(0x22));
    try std.testing.expect(h.kbd.pushByte(0x33));
    try std.testing.expectEqual(@as(u8, ST_OBF), h.kbd.in8(0x64) & ST_OBF);
    try std.testing.expectEqual(@as(u8, 0x11), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x22), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x33), h.kbd.in8(0x60));
    // Now empty: OBF clears.
    try std.testing.expectEqual(@as(u8, 0), h.kbd.in8(0x64) & ST_OBF);
}

test "FIFO full returns false (no silent drop)" {
    var h = Harness{};
    h.wire();
    var i: usize = 0;
    while (i < devices.keyboard.FIFO_LEN) : (i += 1) {
        try std.testing.expect(h.kbd.pushByte(@intCast(i)));
    }
    try std.testing.expect(!h.kbd.pushByte(0xEE)); // full
    try std.testing.expect(!h.kbd.fifoHasRoom());
}

test "injectScancode asserts IRQ1 and queues the byte" {
    var h = Harness{};
    h.wire();
    try std.testing.expect(h.kbd.pushScancode(0x1E)); // 'a' make
    try std.testing.expectEqual(@as(u32, 1), h.irq1_count);
    try std.testing.expectEqual(@as(u8, 0x1E), h.kbd.in8(0x60));
}

test "disabled keyboard IRQ does not assert IRQ1" {
    var h = Harness{};
    h.wire();
    // Clear config bit0 (kbd IRQ) via cmd 0x60 + a data byte.
    h.kbd.out8(0x64, 0x60);
    h.kbd.out8(0x60, 0x00);
    try std.testing.expect(h.kbd.pushScancode(0x1E));
    try std.testing.expectEqual(@as(u32, 0), h.irq1_count); // no IRQ1
}

test "§5.1b: 0xFF reset -> 0xFA then 0xAA in order" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xFF);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0xAA), h.kbd.in8(0x60));
}

test "§5.1b: 0xF2 identify -> 0xFA, 0xAB, 0x83" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xF2);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0xAB), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x83), h.kbd.in8(0x60));
}

test "§5.1b: 0xEE echo replies 0xEE (no ACK)" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xEE);
    try std.testing.expectEqual(@as(u8, 0xEE), h.kbd.in8(0x60));
}

test "§5.1b: 0xED set-LEDs ACKs the command and the mask param" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xED);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60)); // ACK the cmd
    h.kbd.out8(0x60, 0x07); // LED mask param
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60)); // ACK the param
}

test "§5.1b: 0xF3 typematic ACKs the command and the rate param" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xF3);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    h.kbd.out8(0x60, 0x20); // rate/delay param
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
}

test "§5.1b: 0xF4/0xF5/0xF6 each ACK with 0xFA" {
    var h = Harness{};
    h.wire();
    for ([_]u8{ 0xF4, 0xF5, 0xF6 }) |cmd| {
        h.kbd.out8(0x60, cmd);
        try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    }
}

test "§5.1b: 0xFE resend re-sends the last response byte" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xEE); // last response = 0xEE
    try std.testing.expectEqual(@as(u8, 0xEE), h.kbd.in8(0x60));
    h.kbd.out8(0x60, 0xFE); // resend
    try std.testing.expectEqual(@as(u8, 0xEE), h.kbd.in8(0x60));
}

test "§5.1b: controller 0xAA self-test -> 0x55" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), h.kbd.in8(0x60));
}

test "§5.1b: controller 0xAB test-keyboard-port -> 0x00" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0xAB);
    try std.testing.expectEqual(@as(u8, 0x00), h.kbd.in8(0x60));
}

test "§5.1b: 0xAD disable / 0xAE enable keyboard port toggles config bit4" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0xAD); // disable
    h.kbd.out8(0x64, 0x20); // read config
    try std.testing.expectEqual(@as(u8, 0x10), h.kbd.in8(0x60) & 0x10);
    h.kbd.out8(0x64, 0xAE); // enable
    h.kbd.out8(0x64, 0x20);
    try std.testing.expectEqual(@as(u8, 0x00), h.kbd.in8(0x60) & 0x10);
}

test "§5.1b: 0x60 write-config round-trips through 0x20 read-config" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0x60); // write config
    h.kbd.out8(0x60, 0x45); // new config value
    h.kbd.out8(0x64, 0x20); // read config back
    try std.testing.expectEqual(@as(u8, 0x45), h.kbd.in8(0x60));
}

test "§5.1b: 0xD0/0xD1 output-port read-back (A20 NOT driven here)" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0xD1); // write output port
    h.kbd.out8(0x60, 0xDF); // includes bit1 (A20) — latched, NOT routed to the bus
    h.kbd.out8(0x64, 0xD0); // read output port
    try std.testing.expectEqual(@as(u8, 0xDF), h.kbd.in8(0x60));
}

test "status: command write sets the cmd/data bit; data read clears it" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x64, 0x20); // controller command sets ST_CMD
    try std.testing.expectEqual(@as(u8, ST_CMD), h.kbd.in8(0x64) & ST_CMD);
    _ = h.kbd.in8(0x60); // a data read clears ST_CMD
    try std.testing.expectEqual(@as(u8, 0), h.kbd.in8(0x64) & ST_CMD);
}

test "snapshot round-trips the FIFO + status + config" {
    var h = Harness{};
    h.wire();
    h.kbd.out8(0x60, 0xFF); // queues 0xFA, 0xAA
    h.kbd.out8(0x64, 0x60); // pend a config write
    const snap = h.kbd.snapshot();

    var h2 = Harness{};
    h2.wire();
    h2.kbd.restore(snap);
    // The pending config write resumes correctly after restore.
    h2.kbd.out8(0x60, 0x55);
    h2.kbd.out8(0x64, 0x20);
    // FIFO order preserved: 0xFA, 0xAA, then the read-config 0x55.
    try std.testing.expectEqual(@as(u8, 0xFA), h2.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0xAA), h2.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x55), h2.kbd.in8(0x60));
}

// ===========================================================================
// Typematic auto-repeat (the held-key re-make path).
// ===========================================================================

test "typematic KEYSTONE: no make ⇒ no scheduled repeat event" {
    var h = Harness{};
    h.wire();
    // A make+break pair (a tap) leaves no live event.
    h.kbd.noteEdge(0x1E, true, false); // 'a' make -> arms
    try std.testing.expect(h.has_event);
    h.kbd.noteEdge(0x1E, false, false); // 'a' break -> cancels
    try std.testing.expect(!h.has_event);
    try std.testing.expect(h.kbd.repeat_code == null);
}

test "typematic make arms first repeat at now+delay (default 500 ms)" {
    var h = Harness{};
    h.wire();
    h.cycles = 1000;
    h.kbd.noteEdge(0x1E, true, false); // 'a' make
    try std.testing.expect(h.has_event);
    try std.testing.expectEqual(@as(u64, 1000 + msToCycles(500)), h.fire_cycle);
}

test "typematic repeats re-inject the make at the rate (BaK scenario)" {
    var h = Harness{};
    h.wire();
    h.cycles = 0;
    // The injection seam pushes the make byte THEN drives noteEdge (as the
    // Controller's injectScancode does); model both here.
    _ = h.kbd.pushScancode(0x1E); // 'a' make: one byte queued now, raises IRQ1
    h.kbd.noteEdge(0x1E, true, false);
    try std.testing.expectEqual(@as(u8, 0x1E), h.kbd.in8(0x60)); // drain the make
    const irq_after_make = h.irq1_count;

    // Fire the first repeat (after the delay) + two more (at the rate).
    try std.testing.expect(h.fireOnce()); // delay -> repeat #1
    try std.testing.expectEqual(@as(u64, msToCycles(500) + msToCycles(33)), h.fire_cycle);
    try std.testing.expect(h.fireOnce()); // rate  -> repeat #2
    try std.testing.expectEqual(@as(u64, msToCycles(500) + 2 * msToCycles(33)), h.fire_cycle);
    try std.testing.expect(h.fireOnce()); // rate  -> repeat #3

    // Three re-made scancodes are now in the FIFO, each having raised IRQ1.
    try std.testing.expectEqual(@as(u32, irq_after_make + 3), h.irq1_count);
    try std.testing.expectEqual(@as(u8, 0x1E), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x1E), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x1E), h.kbd.in8(0x60));
}

test "typematic reschedules from fire_cycle (no burst drift)" {
    var h = Harness{};
    h.wire();
    h.cycles = 0;
    h.kbd.noteEdge(0x1E, true, false);
    // Even if "now" overshoots the fire cycle (a burst), the reschedule is from the
    // SCHEDULED fire_cycle, so the cadence stays exact.
    try std.testing.expect(h.has_event);
    const fc1 = h.fire_cycle;
    h.cycles = fc1 + 999; // simulate a burst overshoot
    h.has_event = false;
    h.kbd.onRepeatFire(fc1);
    try std.testing.expectEqual(@as(u64, fc1 + msToCycles(33)), h.fire_cycle); // from fc1, not cycles
}

test "typematic break of the repeating key cancels (cancel scenario)" {
    var h = Harness{};
    h.wire();
    h.kbd.noteEdge(0x48, true, true); // up-arrow make (extended)
    try std.testing.expect(h.has_event);
    h.kbd.noteEdge(0x48, false, true); // up-arrow break
    try std.testing.expect(!h.has_event);
    try std.testing.expect(h.kbd.repeat_code == null);
}

test "typematic break of a DIFFERENT key is ignored (no resume)" {
    var h = Harness{};
    h.wire();
    h.kbd.noteEdge(0x1E, true, false); // 'a' held -> repeating
    h.kbd.noteEdge(0x30, false, false); // 'b' break (was never the repeat target)
    try std.testing.expect(h.has_event); // 'a' still repeats
    const rc = h.kbd.repeat_code.?;
    try std.testing.expectEqual(@as(u8, 0x1E), rc.scancode);
}

test "typematic last-key-wins: a second make redirects + restarts the delay" {
    var h = Harness{};
    h.wire();
    h.cycles = 0;
    h.kbd.noteEdge(0x1E, true, false); // 'a' make at cycle 0
    h.cycles = 100;
    h.kbd.noteEdge(0x30, true, false); // 'b' make at cycle 100 -> redirects
    const rc = h.kbd.repeat_code.?;
    try std.testing.expectEqual(@as(u8, 0x30), rc.scancode);
    // Delay restarts from the new make's "now" (100), not 0.
    try std.testing.expectEqual(@as(u64, 100 + msToCycles(500)), h.fire_cycle);
}

test "typematic extended key re-injects E0 + code (2 FIFO bytes)" {
    var h = Harness{};
    h.wire();
    h.kbd.noteEdge(0x48, true, true); // up-arrow make (caller already pushed E0,48)
    try std.testing.expect(h.fireOnce()); // repeat re-injects E0 + 48
    try std.testing.expectEqual(@as(u8, 0xE0), h.kbd.in8(0x60));
    try std.testing.expectEqual(@as(u8, 0x48), h.kbd.in8(0x60));
}

test "typematic Print-Screen (E0 37) is excluded from repeat" {
    var h = Harness{};
    h.wire();
    h.kbd.noteEdge(0x37, true, true); // PrtScn make
    try std.testing.expect(!h.has_event);
    try std.testing.expect(h.kbd.repeat_code == null);
}

test "typematic full-FIFO repeat is dropped but cadence preserved" {
    var h = Harness{};
    h.wire();
    h.kbd.noteEdge(0x1E, true, false); // arm
    // Fill the FIFO so the repeat re-injection has no room.
    while (h.kbd.fifoHasRoom()) _ = h.kbd.pushByte(0xAA);
    const before = h.irq1_count;
    try std.testing.expect(h.fireOnce()); // repeat fires but is dropped
    try std.testing.expectEqual(before, h.irq1_count); // no IRQ1 (nothing pushed)
    try std.testing.expect(h.has_event); // cadence preserved (rescheduled)
}

test "typematic 0xF3 decode sets delay/rate per the table" {
    var h = Harness{};
    h.wire();
    // 0xF3 byte 0dd rrrrr: delay index 2 (750 ms), rate index 31 (500 ms).
    const byte: u8 = (2 << 5) | 31;
    h.kbd.out8(0x60, 0xF3);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    h.kbd.out8(0x60, byte);
    try std.testing.expectEqual(@as(u8, 0xFA), h.kbd.in8(0x60));
    try std.testing.expectEqual(msToCycles(750), h.kbd.delay_cycles);
    try std.testing.expectEqual(msToCycles(500), h.kbd.rate_cycles);
    // The new rate takes effect on the next make.
    h.cycles = 0;
    h.kbd.noteEdge(0x1E, true, false);
    try std.testing.expectEqual(msToCycles(750), h.fire_cycle);
}

test "typematic setTypematicByte (INT 16h AH=03 path) drives the same decode" {
    var h = Harness{};
    h.wire();
    h.kbd.setTypematicByte(0x20); // AL=00 default -> delay 500 ms, rate 33 ms
    try std.testing.expectEqual(msToCycles(500), h.kbd.delay_cycles);
    try std.testing.expectEqual(msToCycles(33), h.kbd.rate_cycles);
}

test "typematic snapshot round-trips config (event rides the scheduler, not this)" {
    var h = Harness{};
    h.wire();
    h.kbd.setTypematicByte((1 << 5) | 5); // delay 500 ms, rate index 5 (54 ms)
    h.kbd.noteEdge(0x1E, true, false); // arm a repeat candidate
    const snap = h.kbd.snapshot();
    try std.testing.expect(snap.repeat_code != null);
    try std.testing.expectEqual(msToCycles(500), snap.delay_cycles);
    try std.testing.expectEqual(msToCycles(54), snap.rate_cycles);

    var h2 = Harness{};
    h2.wire();
    h2.kbd.restore(snap);
    try std.testing.expectEqual(@as(u8, 0x1E), h2.kbd.repeat_code.?.scancode);
    try std.testing.expectEqual(msToCycles(54), h2.kbd.rate_cycles);
}
