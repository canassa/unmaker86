//! Phase 1 wire-format tests (§D #6): JSON round-trips, golden serialization
//! strings (incl. the `u64`-as-string form for `cycles`/`at_cycle`, R6), and the
//! hex encode/decode edge cases. No threads, no sockets, no machine.

const std = @import("std");
const wire = @import("json_wire.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");

const StopReason = debug.StopReason;
const CpuSnapshot = debug.CpuSnapshot;
const BreakpointKind = debug.BreakpointKind;
const Region = debug.Region;

// A scratch buffer big enough for any wire body in these tests.
var sbuf: [4096]u8 = undefined;

fn ser(v: anytype) ![]u8 {
    return wire.serialize(&sbuf, v);
}

// ---------------------------------------------------------------------------
// Golden serialization strings (the discriminated-union encoding is stable).
// ---------------------------------------------------------------------------

test "StopReason golden: breakpoint with small at_cycle is a number" {
    const r: StopReason = .{ .breakpoint = .{ .id = 0, .at_cycle = 578 } };
    try std.testing.expectEqualStrings(
        \\{"breakpoint":{"id":0,"at_cycle":578}}
    , try ser(r));
}

test "StopReason golden: u64 at_cycle > 2^53 emits as a JSON string (R6)" {
    const big: u64 = (1 << 53) + 1; // 9007199254740993 — outside f64 exact range
    const r: StopReason = .{ .step_complete = .{ .at_cycle = big } };
    try std.testing.expectEqualStrings(
        \\{"step_complete":{"at_cycle":"9007199254740993"}}
    , try ser(r));
}

test "StopReason golden: terminal variants carry at_cycle" {
    try std.testing.expectEqualStrings(
        \\{"halted_forever":{"at_cycle":42}}
    , try ser(@as(StopReason, .{ .halted_forever = .{ .at_cycle = 42 } })));
    try std.testing.expectEqualStrings(
        \\{"shutdown":{"at_cycle":7}}
    , try ser(@as(StopReason, .{ .shutdown = .{ .at_cycle = 7 } })));
}

test "StopReason golden: program_terminated carries ret_code + at_cycle" {
    const r: StopReason = .{ .program_terminated = .{ .ret_code = 0, .at_cycle = 7425 } };
    try std.testing.expectEqualStrings(
        \\{"program_terminated":{"ret_code":0,"at_cycle":7425}}
    , try ser(r));
}

test "BreakpointKind golden: each supported kind" {
    try std.testing.expectEqualStrings(
        \\{"execution_address":{"linear":1048592}}
    , try ser(@as(BreakpointKind, .{ .execution_address = .{ .linear = 1048592 } })));
    try std.testing.expectEqualStrings(
        \\{"cycle":{"at_cycle":578}}
    , try ser(@as(BreakpointKind, .{ .cycle = .{ .at_cycle = 578 } })));
    try std.testing.expectEqualStrings(
        \\{"interrupt":{"vector":33}}
    , try ser(@as(BreakpointKind, .{ .interrupt = .{ .vector = 33 } })));
    try std.testing.expectEqualStrings(
        \\{"memory":{"linear":65536,"len":16,"access":"write"}}
    , try ser(@as(BreakpointKind, .{ .memory = .{ .linear = 65536, .len = 16, .access = .write } })));
}

test "WireBreakpoint golden: id is injected, field order fixed" {
    const wb: wire.WireBreakpoint = .{
        .id = 3,
        .kind = .{ .cycle = .{ .at_cycle = 578 } },
        .enabled = true,
        .one_shot = false,
    };
    try std.testing.expectEqualStrings(
        \\{"id":3,"kind":{"cycle":{"at_cycle":578}},"enabled":true,"one_shot":false}
    , try ser(wb));
}

test "Region golden: kind is the tag-name string" {
    const reg: Region = .{ .kind = .ram, .phys_start = 0, .len = 1114112 };
    try std.testing.expectEqualStrings(
        \\{"kind":"ram","phys_start":0,"len":1114112}
    , try ser(reg));
}

test "ErrorBody golden" {
    const e: wire.ErrorBody = .{ .code = "breakpoint_table_full", .message = "all 64 breakpoint slots are in use" };
    try std.testing.expectEqualStrings(
        \\{"code":"breakpoint_table_full","message":"all 64 breakpoint slots are in use"}
    , try ser(e));
}

test "CpuSnapshot golden: cycles emitted as a string when large; flags as bools" {
    var snap: CpuSnapshot = std.mem.zeroes(CpuSnapshot);
    snap.eax = 0x1234;
    snap.cycles = (1 << 53) + 7; // > 2^53 → string
    snap.zf = true;
    const out = try ser(snap);
    // Spot-check the load-bearing pieces (full field-for-field order is the
    // controller's; we assert the determinism-critical bits here).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"eax\":4660") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cycles\":\"9007199254740999\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"zf\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"halted\":false") != null);
}

// ---------------------------------------------------------------------------
// Parse round-trips (request structs). Use a leaky arena reset .retain_capacity.
// ---------------------------------------------------------------------------

fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, wire.parse_options);
}

test "RunReq parse: present and absent cycle_cap" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r1 = try parse(wire.RunReq, a.allocator(), "{\"cycle_cap\":1000000}");
    try std.testing.expectEqual(@as(?u64, 1000000), r1.cycle_cap);
    const r2 = try parse(wire.RunReq, a.allocator(), "{}");
    try std.testing.expectEqual(@as(?u64, null), r2.cycle_cap);
}

test "AddBpReq parse: tagged-union kind + one_shot default" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(wire.AddBpReq, a.allocator(),
        \\{"kind":{"execution_address":{"linear":1048592}}}
    );
    try std.testing.expectEqual(@as(u32, 1048592), r.kind.execution_address.linear);
    try std.testing.expectEqual(false, r.one_shot);
}

test "AddBpReq parse: io kind parses (handler rejects later)" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(wire.AddBpReq, a.allocator(),
        \\{"kind":{"io":{"port":96,"access":"access"}},"one_shot":false}
    );
    try std.testing.expect(r.kind == .io);
    try std.testing.expectEqual(@as(u16, 96), r.kind.io.port);
}

test "RegSetReq parse: each arm" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r32 = try parse(wire.RegSetReq, a.allocator(), "{\"reg32\":{\"name\":\"eax\",\"value\":4660}}");
    try std.testing.expectEqualStrings("eax", r32.reg32.name);
    try std.testing.expectEqual(@as(u32, 4660), r32.reg32.value);

    const reip = try parse(wire.RegSetReq, a.allocator(), "{\"eip\":{\"value\":256}}");
    try std.testing.expectEqual(@as(u32, 256), reip.eip.value);

    const rf = try parse(wire.RegSetReq, a.allocator(),
        \\{"flags":{"cf":true,"pf":false,"af":false,"zf":true,"sf":false,"df":false,"of":false,"iff":true,"tf":false,"nt":false,"rf":false,"vm":false,"ac":false}}
    );
    const f = rf.flags.toFlags();
    try std.testing.expect(f.cf and f.zf and f.iff);
    try std.testing.expect(!f.pf and !f.sf);
}

test "RegSetReq round-trip: serialize then parse the flags arm" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const orig: wire.RegSetReq = .{ .flags = .{ .cf = true, .zf = true, .iff = true } };
    const json = try ser(orig);
    const back = try parse(wire.RegSetReq, a.allocator(), json);
    try std.testing.expect(back == .flags);
    try std.testing.expectEqual(orig.flags.cf, back.flags.cf);
    try std.testing.expectEqual(orig.flags.zf, back.flags.zf);
    try std.testing.expectEqual(orig.flags.of, back.flags.of);
}

test "MemWriteReq parse: data is the raw hex string" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(wire.MemWriteReq, a.allocator(), "{\"phys\":65536,\"data\":\"b80200\"}");
    try std.testing.expectEqual(@as(u32, 65536), r.phys);
    try std.testing.expectEqualStrings("b80200", r.data);
}

test "LoadReq parse: all fields optional, default null" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(wire.LoadReq, a.allocator(), "{}");
    try std.testing.expectEqual(@as(?u8, null), r.drive);
    try std.testing.expectEqual(@as(?[]const u8, null), r.file);
}

test "parse: unknown fields are ignored (ignore_unknown_fields)" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(wire.RunToCycleReq, a.allocator(), "{\"cycle\":578,\"future\":\"ok\"}");
    try std.testing.expectEqual(@as(u64, 578), r.cycle);
}

test "parse: arena reset .retain_capacity reuses backing memory" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const r = try parse(wire.MemWriteReq, a.allocator(), "{\"phys\":1,\"data\":\"deadbeef\"}");
        try std.testing.expectEqualStrings("deadbeef", r.data);
        _ = a.reset(.retain_capacity);
    }
}

// ---------------------------------------------------------------------------
// Hex encode / decode edge cases.
// ---------------------------------------------------------------------------

test "hexDecode: valid lowercase and uppercase" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x02, 0x00 }, try wire.hexDecode(&out, "b80200"));
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, try wire.hexDecode(&out, "DEADBEEF"));
}

test "hexDecode: empty string is the empty slice" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try wire.hexDecode(&out, "")).len);
}

test "hexDecode: odd length rejected" {
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.OddLength, wire.hexDecode(&out, "abc"));
}

test "hexDecode: invalid digit rejected" {
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidHexDigit, wire.hexDecode(&out, "zz"));
}

test "hexDecode: buffer too small rejected" {
    var out: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, wire.hexDecode(&out, "aabb"));
}

test "hexEncode: round-trips with hexDecode" {
    const bytes = [_]u8{ 0x00, 0x7f, 0x80, 0xff };
    var enc: [8]u8 = undefined;
    const s = try wire.hexEncode(&enc, &bytes);
    try std.testing.expectEqualStrings("007f80ff", s);
    var dec: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try wire.hexDecode(&dec, s));
}
