//! Scheduler unit tests (Phase 2): ordering, the (fire_cycle, seq) tie-break, the
//! <=1-live invariant, cancel, re-arm-not-in-same-drain, the empty-queue maxInt
//! contract, and the snapshot round-trip (next_seq matches from-scratch).

const std = @import("std");
const sched = @import("scheduler.zig");

const Scheduler = sched.Scheduler;
const EventKind = sched.EventKind;

test "empty queue -> nextEventCycle == maxInt" {
    var s = Scheduler{};
    try std.testing.expectEqual(std.math.maxInt(u64), s.nextEventCycle());
}

test "three events fire in cycle order; nextEventCycle returns the min" {
    var s = Scheduler{};
    s.schedule(0, 300, 1, .pit_ch0, 0);
    s.schedule(0, 100, 2, .pit_ch1, 0);
    s.schedule(0, 200, 3, .pit_ch2, 0);
    try std.testing.expectEqual(@as(u64, 100), s.nextEventCycle());

    // Drain at a cycle past all of them; they pop in cycle order.
    var fired = std.ArrayListUnmanaged(u64).empty;
    defer fired.deinit(std.testing.allocator);
    while (s.popDue(1000)) |ev| try fired.append(std.testing.allocator, ev.fire_cycle);
    try std.testing.expectEqualSlices(u64, &.{ 100, 200, 300 }, fired.items);
}

test "tie-break: same fire_cycle -> scheduled-first (lower seq) fires first" {
    var s = Scheduler{};
    s.schedule(0, 100, 10, .pit_ch0, 111); // seq 0
    s.schedule(0, 100, 20, .pit_ch1, 222); // seq 1
    const a = s.popDue(100).?;
    const b = s.popDue(100).?;
    try std.testing.expectEqual(@as(u32, 111), a.val); // lower seq first
    try std.testing.expectEqual(@as(u32, 222), b.val);

    // Reverse the schedule order -> firing order reverses (proves seq is the key,
    // not slot index).
    var s2 = Scheduler{};
    s2.schedule(0, 100, 20, .pit_ch1, 222); // seq 0
    s2.schedule(0, 100, 10, .pit_ch0, 111); // seq 1
    try std.testing.expectEqual(@as(u32, 222), s2.popDue(100).?.val);
    try std.testing.expectEqual(@as(u32, 111), s2.popDue(100).?.val);
}

test "cancel removes a scheduled event; nextEventCycle reflects it" {
    var s = Scheduler{};
    s.schedule(0, 100, 1, .pit_ch0, 0);
    s.schedule(0, 200, 2, .pit_ch1, 0);
    s.cancel(1, .pit_ch0);
    try std.testing.expectEqual(@as(u64, 200), s.nextEventCycle());
    try std.testing.expect(!s.hasLive(1, .pit_ch0));
    // The canceled event never fires.
    const ev = s.popDue(1000).?;
    try std.testing.expectEqual(EventKind.pit_ch1, ev.kind);
    try std.testing.expect(s.popDue(1000) == null);
}

test "<=1 live per (source_id, kind): cancel degenerates to cancel-one" {
    var s = Scheduler{};
    s.schedule(0, 100, 7, .pit_ch0, 0);
    // Reprogram exactly when due: cancel + re-arm -> exactly one survives.
    s.cancel(7, .pit_ch0);
    s.schedule(100, 50, 7, .pit_ch0, 0); // re-armed from cycle 100
    try std.testing.expectEqual(@as(u32, 1), s.active);
    try std.testing.expectEqual(@as(u64, 150), s.nextEventCycle());
}

test "re-arm in a callback does not re-fire in the same drain" {
    var s = Scheduler{};
    s.schedule(0, 100, 1, .pit_ch0, 0);
    // Simulate fireDue: pop the due event, then (callback) schedule a follow-up.
    const ev = s.popDue(100).?;
    try std.testing.expectEqual(@as(u64, 100), ev.fire_cycle);
    s.schedule(ev.fire_cycle, 100, 1, .pit_ch0, 0); // re-arm from fire_cycle
    // The follow-up is at cycle 200 (future) -> not due at 100; drain finds none.
    try std.testing.expect(s.popDue(100) == null);
    try std.testing.expectEqual(@as(u64, 200), s.nextEventCycle());
}

test "delta clamped to >=1 (no event in the past)" {
    var s = Scheduler{};
    s.schedule(500, 0, 1, .pit_ch0, 0); // delta 0 -> clamped to 1
    try std.testing.expectEqual(@as(u64, 501), s.nextEventCycle());
}

test "snapshot round-trip: events + next_seq verbatim, firing order identical" {
    var s = Scheduler{};
    s.schedule(0, 300, 1, .pit_ch0, 30);
    s.schedule(0, 100, 2, .pit_ch1, 10);
    s.schedule(0, 200, 3, .pit_ch2, 20);
    const snap = s.snapshot();
    const expected_next_seq = s.next_seq;

    var restored = Scheduler{};
    restored.restore(snap);
    try std.testing.expectEqual(expected_next_seq, restored.next_seq);
    try std.testing.expectEqual(s.nextEventCycle(), restored.nextEventCycle());

    // Firing order is byte-identical.
    var a = std.ArrayListUnmanaged(u32).empty;
    defer a.deinit(std.testing.allocator);
    var b = std.ArrayListUnmanaged(u32).empty;
    defer b.deinit(std.testing.allocator);
    while (s.popDue(1000)) |ev| try a.append(std.testing.allocator, ev.val);
    while (restored.popDue(1000)) |ev| try b.append(std.testing.allocator, ev.val);
    try std.testing.expectEqualSlices(u32, a.items, b.items);
}

test "snapshot next_seq equals from-scratch run's next_seq at the same cycle" {
    // Two identical schedule sequences must produce the same next_seq.
    var s1 = Scheduler{};
    var s2 = Scheduler{};
    inline for (0..5) |i| {
        s1.schedule(0, 100 + i, @intCast(i), .pit_ch0, 0);
        s1.cancel(@intCast(i), .pit_ch0);
        s2.schedule(0, 100 + i, @intCast(i), .pit_ch0, 0);
        s2.cancel(@intCast(i), .pit_ch0);
    }
    try std.testing.expectEqual(s1.next_seq, s2.next_seq);
}
