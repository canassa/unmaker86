//! Phase 1 regression tests for the breakpoint data model (M1 §4 #12 subset, #14).
//! Stable ids across add/remove, the `active_count` gate, `matches` firing on the
//! right cycle/address, error paths, and the no-pointer-fields reflection check.

const std = @import("std");
const bp = @import("breakpoints.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const BreakpointSet = bp.BreakpointSet;

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}

test "default set is empty, well-defined POD, gate at zero" {
    const set: BreakpointSet = .{};
    try std.testing.expectEqual(@as(u32, 0), set.active_count);
    // Every slot is a valid default Breakpoint (a tag read is legal, not IB).
    for (set.items) |b| {
        try std.testing.expect(!b.enabled);
        try std.testing.expectEqual(bp.default_kind, b.kind);
    }
    for (set.used) |u| try std.testing.expect(!u);
}

test "add returns ascending lowest-free ids; gate counts enabled bps" {
    var set: BreakpointSet = .{};
    const id0 = try set.add(.{ .cycle = .{ .at_cycle = 100 } }, false);
    const id1 = try set.add(.{ .execution_address = .{ .linear = 0x500 } }, false);
    const id2 = try set.add(.{ .cycle = .{ .at_cycle = 200 } }, true);
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(u32, 3), set.active_count);
}

test "stable ids across add/remove: removed slot reused at lowest free index" {
    var set: BreakpointSet = .{};
    const id0 = try set.add(.{ .cycle = .{ .at_cycle = 1 } }, false);
    const id1 = try set.add(.{ .cycle = .{ .at_cycle = 2 } }, false);
    const id2 = try set.add(.{ .cycle = .{ .at_cycle = 3 } }, false);
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);

    // Remove the middle id; its slot frees but id2 keeps its index (stable id).
    try set.remove(id1);
    try std.testing.expectEqual(@as(u32, 2), set.active_count);
    const got2 = try set.get(id2);
    try std.testing.expectEqual(@as(u64, 3), got2.kind.cycle.at_cycle);

    // The next add reuses the lowest free slot (= id1), not a fresh index.
    const id3 = try set.add(.{ .cycle = .{ .at_cycle = 4 } }, false);
    try std.testing.expectEqual(@as(u32, 1), id3);
    try std.testing.expectEqual(@as(u32, 3), set.active_count);
}

test "enable/disable flips the active gate" {
    var set: BreakpointSet = .{};
    const id = try set.add(.{ .cycle = .{ .at_cycle = 1 } }, false);
    try std.testing.expectEqual(@as(u32, 1), set.active_count);
    try set.enable(id, false);
    try std.testing.expectEqual(@as(u32, 0), set.active_count);
    try set.enable(id, true);
    try std.testing.expectEqual(@as(u32, 1), set.active_count);
}

test "error paths: table full, bad id, double remove (#12 subset)" {
    var set: BreakpointSet = .{};
    var i: u32 = 0;
    while (i < bp.MAX_BREAKPOINTS) : (i += 1) {
        _ = try set.add(.{ .cycle = .{ .at_cycle = i } }, false);
    }
    // A 65th breakpoint is a clean error, never a panic.
    try std.testing.expectError(error.BreakpointTableFull, set.add(.{ .cycle = .{ .at_cycle = 999 } }, false));

    // Out-of-range / stale id.
    try std.testing.expectError(error.NoSuchBreakpoint, set.get(bp.MAX_BREAKPOINTS));
    try std.testing.expectError(error.NoSuchBreakpoint, set.enable(bp.MAX_BREAKPOINTS, true));

    // Remove an id, then double-remove -> NoSuchBreakpoint (idempotent-safe).
    try set.remove(0);
    try std.testing.expectError(error.NoSuchBreakpoint, set.remove(0));
}

test "forEach skips unused slots and visits only used ones" {
    var set: BreakpointSet = .{};
    _ = try set.add(.{ .cycle = .{ .at_cycle = 1 } }, false);
    const id1 = try set.add(.{ .cycle = .{ .at_cycle = 2 } }, false);
    _ = try set.add(.{ .cycle = .{ .at_cycle = 3 } }, false);
    try set.remove(id1); // free the middle slot

    const Counter = struct {
        var seen: u32 = 0;
        var ids: [bp.MAX_BREAKPOINTS]u32 = undefined;
        fn visit(_: void, id: u32, _: *const bp.Breakpoint) void {
            ids[seen] = id;
            seen += 1;
        }
    };
    Counter.seen = 0;
    set.forEach({}, Counter.visit);
    try std.testing.expectEqual(@as(u32, 2), Counter.seen);
    try std.testing.expectEqual(@as(u32, 0), Counter.ids[0]);
    try std.testing.expectEqual(@as(u32, 2), Counter.ids[1]); // id1 skipped
}

test "matches: cycle bp fires at the first boundary >= at_cycle" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    var b = bp.Breakpoint{ .kind = .{ .cycle = .{ .at_cycle = 100 } }, .enabled = true };
    m.cpu.st.cycles = 99;
    try std.testing.expect(!bp.matches(&b, m, 0));
    m.cpu.st.cycles = 100;
    try std.testing.expect(bp.matches(&b, m, 0));
    m.cpu.st.cycles = 250;
    try std.testing.expect(bp.matches(&b, m, 0)); // still matches above the threshold

    // A disabled breakpoint never matches.
    b.enabled = false;
    try std.testing.expect(!bp.matches(&b, m, 0));
}

test "matches: execution_address bp fires on linear(CS:IP)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.loadSegment(.cs, 0x1000); // base = 0x10000
    m.cpu.st.eip = 0x0234;
    const linear: u32 = 0x10000 + 0x0234;
    const b = bp.Breakpoint{ .kind = .{ .execution_address = .{ .linear = linear } }, .enabled = true };
    try std.testing.expect(bp.matches(&b, m, 0));
    try std.testing.expectEqual(linear, bp.currentLinear(m));

    m.cpu.st.eip = 0x0235;
    try std.testing.expect(!bp.matches(&b, m, 0));
}

test "interrupt/memory/io kinds do not match in Phase 1" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    const bi = bp.Breakpoint{ .kind = .{ .interrupt = .{ .vector = 0x21 } }, .enabled = true };
    const bm = bp.Breakpoint{ .kind = .{ .memory = .{ .linear = 0, .len = 1, .access = .write } }, .enabled = true };
    const bo = bp.Breakpoint{ .kind = .{ .io = .{ .port = 0x40, .access = .read } }, .enabled = true };
    try std.testing.expect(!bp.matches(&bi, m, 0));
    try std.testing.expect(!bp.matches(&bm, m, 0));
    try std.testing.expect(!bp.matches(&bo, m, 0));
}

test "POD types contain no pointer-typed fields (part of #14)" {
    try expectNoPointerFields(bp.Breakpoint);
    try expectNoPointerFields(bp.BreakpointSet);
    try expectNoPointerFields(bp.BreakpointKind);
}

/// Recursively assert a type (and its struct/union fields) has no pointer field,
/// so no ASLR'd pointer can leak into a snapshot or M2 JSON (constraint #5).
fn expectNoPointerFields(comptime T: type) !void {
    switch (@typeInfo(T)) {
        .pointer => return error.PointerFieldFound,
        .@"struct" => |s| inline for (s.fields) |f| try expectNoPointerFields(f.type),
        .@"union" => |u| inline for (u.fields) |f| try expectNoPointerFields(f.type),
        .optional => |o| try expectNoPointerFields(o.child),
        .array => |a| try expectNoPointerFields(a.child),
        else => {},
    }
}
