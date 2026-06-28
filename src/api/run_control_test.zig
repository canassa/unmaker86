//! Run-ownership arbitration tests (stream §5.3). Pure, clockless: no machine, no
//! sockets — just the atomic `RunControl` state machine (idle/paced/debugger), the
//! 409-on-debugger-run rule, and the auto-disarm/restore around a debugger command.

const std = @import("std");
const timing = @import("timing");
const rc_mod = @import("run_control.zig");
const RunControl = rc_mod.RunControl;
const RunOwner = rc_mod.RunOwner;
const StopTag = rc_mod.StopTag;

fn makeIo(threaded: *std.Io.Threaded) std.Io {
    return threaded.io();
}

test "fresh RunControl is idle and disarmed with sane defaults" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    try std.testing.expectEqual(RunOwner.idle, rc.getOwner());
    try std.testing.expect(!rc.isArmed());
    try std.testing.expectEqual(RunControl.DEFAULT_SLICE_CYCLES, rc.sliceCycles());
    try std.testing.expectEqual(RunControl.DEFAULT_FPS, rc.getFps());
    try std.testing.expectEqual(StopTag.none, rc.lastStop());
}

test "start arms the pacer (owner=paced) and is idempotent" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    try std.testing.expect(rc.start(0, 0)); // keep defaults
    try std.testing.expectEqual(RunOwner.paced, rc.getOwner());
    try std.testing.expect(rc.isArmed());

    // Idempotent: re-arm while paced succeeds.
    try std.testing.expect(rc.start(123_456, 60));
    try std.testing.expectEqual(@as(u64, 123_456), rc.sliceCycles());
    try std.testing.expectEqual(@as(u32, 60), rc.getFps());
}

test "stop disarms and returns to idle" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    try std.testing.expect(rc.start(0, 0));
    rc.stop();
    try std.testing.expectEqual(RunOwner.idle, rc.getOwner());
    try std.testing.expect(!rc.isArmed());
}

test "start returns false (409) while a debugger run is in flight" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    // Model a debugger run being in flight.
    const restore = rc.beginDebugger();
    try std.testing.expectEqual(RunOwner.debugger, rc.getOwner());
    try std.testing.expect(!rc.isArmed());

    // /api/run/start must be refused (the caller replies 409).
    try std.testing.expect(!rc.start(0, 0));
    try std.testing.expectEqual(RunOwner.debugger, rc.getOwner());

    // End the debugger command; with no prior paced owner, we return to idle.
    rc.endDebugger(restore);
    try std.testing.expectEqual(RunOwner.idle, rc.getOwner());
    try std.testing.expect(!rc.isArmed());
}

test "debugger auto-disarms the pacer then RE-ARMS it (owner restored to paced)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    // Pacer running.
    try std.testing.expect(rc.start(0, 0));
    try std.testing.expectEqual(RunOwner.paced, rc.getOwner());

    // A debugger command arrives: it disarms the pacer for its duration.
    const restore = rc.beginDebugger();
    try std.testing.expectEqual(RunOwner.debugger, rc.getOwner());
    try std.testing.expect(!rc.isArmed()); // pacer paused so the command lands cleanly
    try std.testing.expectEqual(RunOwner.paced, restore);

    // After the command, the pacer is re-armed (it owned the run before).
    rc.endDebugger(restore);
    try std.testing.expectEqual(RunOwner.paced, rc.getOwner());
    try std.testing.expect(rc.isArmed());
}

test "Phase 3: default slice paces at the DEVICE rate (mult 12), not the old 25 MHz" {
    // The pacer now paces at the faithful device clock: PIT_TICK_RATE*12/100 ≈ 143_181
    // cycles per 10 ms slice (~14.32 MHz), NOT the former hardcoded 250_000 (25 MHz).
    try std.testing.expectEqual(
        timing.PIT_TICK_RATE * timing.DEFAULT_MULT / 100,
        RunControl.DEFAULT_SLICE_CYCLES,
    );
    try std.testing.expectEqual(@as(u64, 143_181), RunControl.DEFAULT_SLICE_CYCLES);
}

test "Phase 3: setSlice retunes the pacer slice to PIT_TICK_RATE*mult/100 (CPU-speed knob)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    // The /api/cpu/clock handler derives the slice from the APPLIED mult; assert the
    // pacer slice tracks it (so the timer's WALL rate stays ~18.2 Hz at any speed).
    const mult24_slice = timing.PIT_TICK_RATE * 24 / 100;
    try std.testing.expectEqual(mult24_slice, rc.setSlice(mult24_slice));
    try std.testing.expectEqual(mult24_slice, rc.sliceCycles());

    // The slice scales with the mult (cycles/sec ∝ cpu_clock_hz): mult 24's slice is
    // ~2x mult 12's, so the same number of PIT TICKS elapse per wall second and the
    // 18.2 Hz timer's WALL rate stays invariant (reload ticks are mult-independent).
    const mult12_slice = timing.PIT_TICK_RATE * 12 / 100;
    try std.testing.expect(mult24_slice > mult12_slice);
    try std.testing.expect(mult24_slice - 2 * mult12_slice <= 1); // 2x within floor rounding

    // setSlice(0) is a no-op (keeps current tuning).
    try std.testing.expectEqual(mult24_slice, rc.setSlice(0));
    try std.testing.expectEqual(mult24_slice, rc.sliceCycles());
}

test "Phase 3: the PIT/BDA timer WALL rate is invariant to mult (18.2 Hz at mult 12 AND 24)" {
    // The timer's wall rate cancels the mult: IRQ0 fires every `reload * mult` CPU
    // cycles, and the pacer feeds `cpu_clock_hz = PIT_TICK_RATE * mult` cycles per
    // wall-second (slice * 100). So fires/wall-second = (PIT_TICK_RATE * mult) /
    // (reload * mult) = PIT_TICK_RATE / reload — the mult cancels (game pace
    // invariant). We assert this exact integer identity at mult 12 AND mult 24,
    // proving the wall rate is the same ~18.2 Hz at both.
    const reload: u64 = 65536; // the BIOS default (18.2 Hz) PIT ch0 reload
    const Helper = struct {
        fn firesPerWallSecondScaled(mult: u64) u64 {
            const slice = timing.PIT_TICK_RATE * mult / 100; // pacer slice @ this mult
            const cpu_per_wall_sec = slice * 100; // 10 ms slice => *100
            const cpu_per_fire = reload * mult; // IRQ0 every reload*mult cpu cycles
            // Scale by 1000 to keep two-decimal precision in pure integers.
            return cpu_per_wall_sec * 1000 / cpu_per_fire;
        }
    };
    const r12 = Helper.firesPerWallSecondScaled(12);
    const r24 = Helper.firesPerWallSecondScaled(24);
    try std.testing.expectEqual(r12, r24); // mult cancels — identical wall rate
    // ~18.2 Hz: PIT_TICK_RATE/65536 = 1_193_182/65536 ≈ 18.21 → 18210 ± rounding.
    try std.testing.expect(r12 >= 18_200 and r12 <= 18_220);
}

test "disarmTerminal stops the pacer on a terminal slice" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    try std.testing.expect(rc.start(0, 0));
    rc.recordStop(.program_terminated, 999);
    rc.disarmTerminal();
    try std.testing.expectEqual(RunOwner.idle, rc.getOwner());
    try std.testing.expect(!rc.isArmed());
    try std.testing.expectEqual(StopTag.program_terminated, rc.lastStop());
    try std.testing.expectEqual(@as(u64, 999), rc.lastCycle());
}

test "sustainableMult: UI-only host real-time ceiling math (integer, no clock)" {
    // No data yet (never paced) → don't cap: report the static MAX_MULT.
    try std.testing.expectEqual(timing.MAX_MULT, RunControl.sustainableMult(0));

    // ~46M cyc/s (ReleaseFast-ish): floor(46_000_000 * 9/10 / PIT_TICK_RATE)
    //   = floor(41_400_000 / 1_193_182) = 34, well under MAX_MULT (55) → 34.
    try std.testing.expectEqual(@as(u64, 34), RunControl.sustainableMult(46_000_000));

    // A blazing host clamps to the static MAX_MULT (the slider never exceeds it).
    try std.testing.expectEqual(timing.MAX_MULT, RunControl.sustainableMult(1_000_000_000));

    // A crawling host (Debug ~8M cyc/s) → floor(7_200_000 / 1_193_182) = 6.
    try std.testing.expectEqual(@as(u64, 6), RunControl.sustainableMult(8_000_000));

    // A near-zero throughput still floors to at least 1 (slider min), never 0.
    try std.testing.expectEqual(@as(u64, 1), RunControl.sustainableMult(1_500_000));

    // The 10% headroom actually bites: exactly PIT_TICK_RATE cyc/s would be mult 1
    // without headroom, but * 9/10 floors it to 0 → clamped up to 1 (the floor).
    try std.testing.expectEqual(@as(u64, 1), RunControl.sustainableMult(timing.PIT_TICK_RATE));
}

test "setMeasuredHz/getMeasuredHz round-trip (clock-free atomic telemetry)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var rc = RunControl.init(threaded.io());

    try std.testing.expectEqual(@as(u64, 0), rc.getMeasuredHz());
    rc.setMeasuredHz(46_000_000);
    try std.testing.expectEqual(@as(u64, 46_000_000), rc.getMeasuredHz());
    // The applied-mult path (sliceForMult) is INDEPENDENT of measured_hz — host-independent.
    try std.testing.expectEqual(RunControl.sliceForMult(55), timing.PIT_TICK_RATE * 55 / 100);
}
