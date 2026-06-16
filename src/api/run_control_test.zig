//! Run-ownership arbitration tests (stream §5.3). Pure, clockless: no machine, no
//! sockets — just the atomic `RunControl` state machine (idle/paced/debugger), the
//! 409-on-debugger-run rule, and the auto-disarm/restore around a debugger command.

const std = @import("std");
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
