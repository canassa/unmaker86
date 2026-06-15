//! 8042 keyboard-controller unit tests (input Phase 1a): port read/write +
//! status-byte round-trips, the output FIFO push/pop order, the §5.1b command/
//! response pairs (device cmds on 0x60, controller cmds on 0x64), and IRQ1 assert
//! on scancode injection. The harness binds the device's PIC-raise back-pointer to
//! a recording counter (the same RaiseFn the machine binds), without the machine.

const std = @import("std");
const devices = @import("devices");

const Keyboard = devices.Keyboard;

const ST_OBF: u8 = 0x01;
const ST_CMD: u8 = 0x08;

/// A recording IRQ sink standing in for the PIC.
const Harness = struct {
    kbd: Keyboard = .{},
    irq1_count: u32 = 0,

    fn raise(ctx: *anyopaque, line: u4) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        if (line == 1) self.irq1_count += 1;
    }
    fn wire(self: *Harness) void {
        self.kbd.raise_ctx = self;
        self.kbd.raise_fn = raise;
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
