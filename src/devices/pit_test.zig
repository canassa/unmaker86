//! 8254 PIT unit tests (Phase 5): mode 2/3 scheduling at period = R ticks, reload
//! write sequence, latch + read-back state machine, mode-0 one-shot, reprogram
//! cancel/re-arm, and the deterministic counter read-back from elapsed cycles.

const std = @import("std");
const devices = @import("devices");
const timing = @import("timing");

const Pit = devices.Pit;

/// A minimal test harness binding the PIT to a recording "scheduler" + a movable
/// cycle counter + a recording IRQ raise — exercising the same SchedulerApi the
/// machine uses, without pulling in the whole machine.
const Harness = struct {
    pit: Pit = .{},
    cycles: u64 = 0,
    remainder: u64 = 0,
    armed: bool = false,
    arm_from: u64 = 0,
    arm_ticks: u64 = 0,
    arm_cycle: u64 = 0, // absolute fire cycle
    arm_count: u32 = 0, // total schedule() calls (re-arms count)
    irq0_count: u32 = 0,

    fn schedule(ctx: *anyopaque, from: u64, ticks: u64, val: u32) void {
        _ = val;
        const self: *Harness = @ptrCast(@alignCast(ctx));
        const delta = timing.ticksToCycles(ticks, &self.remainder);
        self.armed = true;
        self.arm_from = from;
        self.arm_ticks = ticks;
        self.arm_cycle = from + delta;
        self.arm_count += 1;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.armed = false;
    }
    fn raise(ctx: *anyopaque, line: u4) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        if (line == 0) self.irq0_count += 1;
    }

    fn wire(self: *Harness) void {
        self.pit.cycles = &self.cycles;
        self.pit.raise_ctx = self;
        self.pit.raise_fn = raise;
        self.pit.sched = .{ .ctx = self, .schedule = schedule, .cancel = cancel };
    }
};

test "no host time / RNG / thread / env / float anywhere in src/devices (grep)" {
    const sources = [_][]const u8{
        @embedFile("pic.zig"),
        @embedFile("pit.zig"),
        @embedFile("keyboard.zig"),
        @embedFile("devices.zig"),
        // The VGA 0x3DA retrace/display-enable timing is integer-only and must stay
        // float / host-clock / RNG free (the temptation to write an f64 "70.086 Hz"
        // is real — both reference emulators use double/fmod). plans/vga-retrace.md §5.5.
        @embedFile("vga.zig"),
    };
    const forbidden = [_][]const u8{
        "std.time",
        "std.Random",
        "std.rand",
        "std.Thread",
        "std.posix.getenv",
        "std.process.getEnv",
        "std.os.getenv",
        // No floats in the scheduling/timing path (M-D2).
        "f32",
        "f64",
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a devices source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

test "mode 3 ch0 reload 0 -> period 65536 ticks scheduled; re-arms at +period" {
    var h = Harness{};
    h.wire();
    // OUT 0x43 = 0x36 (ch0, lohi, mode 3), then reload 0,0 -> 65536.
    h.pit.out8(0x43, 0x36);
    h.pit.out8(0x40, 0x00);
    h.pit.out8(0x40, 0x00);
    try std.testing.expect(h.armed);
    // delta = 65536 ticks * 12 cyc/tick = 786432.
    try std.testing.expectEqual(@as(u64, 65536 * 12), h.arm_cycle);

    // Fire it (machine would call onPitCh0Fire at fire_cycle) -> IRQ0 + re-arm.
    h.pit.onPitCh0Fire(h.arm_cycle);
    try std.testing.expectEqual(@as(u32, 1), h.irq0_count);
    try std.testing.expect(h.armed);
    // Re-arm is from fire_cycle, +period.
    try std.testing.expectEqual(@as(u64, 65536 * 12 * 2), h.arm_cycle);
}

test "reload write sequence: partial (lohi LSB only) does not arm" {
    var h = Harness{};
    h.wire();
    h.pit.out8(0x43, 0x34); // ch0, lohi, mode 2
    h.pit.out8(0x40, 0x10); // LSB only
    try std.testing.expect(!h.armed); // not yet
    h.pit.out8(0x40, 0x00); // MSB -> reload = 0x0010 = 16
    try std.testing.expect(h.armed);
    try std.testing.expectEqual(@as(u64, 16), h.arm_ticks);
}

test "mode 2 and mode 3 schedule IRQ0 at the same period = R ticks" {
    var h2 = Harness{};
    h2.wire();
    h2.pit.out8(0x43, 0x34); // mode 2
    h2.pit.out8(0x40, 0x64); // reload 100
    h2.pit.out8(0x40, 0x00);

    var h3 = Harness{};
    h3.wire();
    h3.pit.out8(0x43, 0x36); // mode 3
    h3.pit.out8(0x40, 0x64); // reload 100
    h3.pit.out8(0x40, 0x00);

    try std.testing.expectEqual(h2.arm_ticks, h3.arm_ticks); // identical period
    try std.testing.expectEqual(@as(u64, 100), h2.arm_ticks);
}

test "counter latch -> IN 0x40 returns value consistent with elapsed cycles" {
    var h = Harness{};
    h.wire();
    h.pit.out8(0x43, 0x34); // ch0 mode 2 lohi
    h.pit.out8(0x40, 0x00); // reload 0 = 65536
    h.pit.out8(0x40, 0x00);
    // Advance 12 cycles = 1 PIT tick.
    h.cycles = 12;
    // Latch (control word access bits 00).
    h.pit.out8(0x43, 0x00);
    const lsb = h.pit.in8(0x40);
    const msb = h.pit.in8(0x40);
    const counter: u16 = @as(u16, lsb) | (@as(u16, msb) << 8);
    // 65536 - 1 tick elapsed = 65535.
    try std.testing.expectEqual(@as(u16, 65535), counter);

    // A second latch at a different cycle returns a different deterministic value.
    h.cycles = 24; // 2 ticks
    h.pit.out8(0x43, 0x00);
    const lsb2 = h.pit.in8(0x40);
    const msb2 = h.pit.in8(0x40);
    const counter2: u16 = @as(u16, lsb2) | (@as(u16, msb2) << 8);
    try std.testing.expectEqual(@as(u16, 65534), counter2);
}

test "read-back status byte encodes mode/access/null-count" {
    var h = Harness{};
    h.wire();
    h.pit.out8(0x43, 0x34); // ch0, lohi, mode 2
    // Before a reload write, new_mode is set -> null-count bit (0x40).
    // Read-back: OUT 0x43 = 0xE2 (bits7-6=11, bit5=1 no-latch-count, bit4=0
    // latch-status, bit1=1 select ch0).
    h.pit.out8(0x43, 0xE2);
    const status = h.pit.in8(0x40);
    try std.testing.expect((status & 0x40) != 0); // null-count set
    try std.testing.expectEqual(@as(u8, 0x03 << 4), status & 0x30); // access = lohi(3)
    try std.testing.expectEqual(@as(u8, 2 << 1), status & 0x0E); // mode 2
}

test "mode 0 one-shot fires once and does not re-arm" {
    var h = Harness{};
    h.wire();
    h.pit.out8(0x43, 0x30); // ch0, lohi, mode 0
    h.pit.out8(0x40, 0x0A);
    h.pit.out8(0x40, 0x00); // reload 10
    try std.testing.expect(h.armed);
    try std.testing.expectEqual(@as(u32, 1), h.arm_count);
    h.pit.onPitCh0Fire(h.arm_cycle);
    try std.testing.expectEqual(@as(u32, 1), h.irq0_count);
    try std.testing.expectEqual(@as(u32, 1), h.arm_count); // mode 0 did not re-arm
}

test "reprogramming ch0 cancels the old event and arms the new period" {
    var h = Harness{};
    h.wire();
    h.pit.out8(0x43, 0x34);
    h.pit.out8(0x40, 0x64); // reload 100
    h.pit.out8(0x40, 0x00);
    try std.testing.expectEqual(@as(u64, 100), h.arm_ticks);
    // Reprogram to a faster tick.
    h.cycles = 50;
    h.pit.out8(0x43, 0x34);
    try std.testing.expect(!h.armed); // control word canceled the old event
    h.pit.out8(0x40, 0x0A); // reload 10
    h.pit.out8(0x40, 0x00);
    try std.testing.expect(h.armed);
    try std.testing.expectEqual(@as(u64, 10), h.arm_ticks);
    try std.testing.expectEqual(@as(u64, 50), h.arm_from); // armed from current cycle
}
