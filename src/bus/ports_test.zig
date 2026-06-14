//! Phase 4 tests: port dispatch — register/dispatch 8/16/32, the 0xFF
//! floating-bus default, and single-handler width dispatch (native width OR
//! byte-synthesis from the SAME handler, never port+1).

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const ports = @import("ports.zig");
const PortHandler = ports.PortHandler;

// A recording, byte-only port handler (no native widths). Records every byte
// access so we can prove a wide access byte-synthesizes from the SAME base port.
const RecPort = struct {
    in_log: std.ArrayList(u16) = .empty,
    out_log: std.ArrayList(u16) = .empty,
    regs: [4]u8 = .{ 0x10, 0x20, 0x30, 0x40 },
    alloc: std.mem.Allocator,

    fn in8(ctx: *anyopaque, port: u16) u8 {
        const s: *RecPort = @ptrCast(@alignCast(ctx));
        s.in_log.append(s.alloc, port) catch {};
        return s.regs[port & 3];
    }
    fn out8(ctx: *anyopaque, port: u16, v: u8) void {
        const s: *RecPort = @ptrCast(@alignCast(ctx));
        s.out_log.append(s.alloc, port) catch {};
        s.regs[port & 3] = v;
    }
    const vt: PortHandler.VTable = .{ .in8 = in8, .out8 = out8 };
    fn handler(self: *RecPort) PortHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

// A native-16-bit-aware handler recording which width was used.
const Wide16Port = struct {
    last: enum { none, in8, in16 } = .none,
    fn in8(ctx: *anyopaque, _: u16) u8 {
        const s: *Wide16Port = @ptrCast(@alignCast(ctx));
        s.last = .in8;
        return 0xAB;
    }
    fn out8(_: *anyopaque, _: u16, _: u8) void {}
    fn in16(ctx: *anyopaque, _: u16) u16 {
        const s: *Wide16Port = @ptrCast(@alignCast(ctx));
        s.last = .in16;
        return 0xCAFE;
    }
    const vt: PortHandler.VTable = .{
        .in8 = in8,
        .out8 = out8,
        .in16 = in16,
        .width = .{ .w16 = true },
    };
    fn handler(self: *Wide16Port) PortHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

test "unmapped port IN returns 0xFF/0xFFFF/0xFFFFFFFF, OUT dropped" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    try std.testing.expectEqual(@as(u8, 0xFF), bus.portIn8(0x3F8));
    try std.testing.expectEqual(@as(u16, 0xFFFF), bus.portIn16(0x3F8));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bus.portIn32(0x3F8));
    bus.portOut8(0x3F8, 0x42); // dropped, no crash
}

test "registerPort: IN/OUT 8-bit route to the handler" {
    var rp = RecPort{ .alloc = std.testing.allocator };
    defer rp.in_log.deinit(std.testing.allocator);
    defer rp.out_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.registerPort(0x60, rp.handler());

    try std.testing.expectEqual(@as(u8, 0x10), bus.portIn8(0x60));
    bus.portOut8(0x60, 0x99);
    try std.testing.expectEqual(@as(u8, 0x99), bus.portIn8(0x60));
}

test "16-bit IN on a byte-only handler synthesizes from the SAME base port (not port+1)" {
    var rp = RecPort{ .alloc = std.testing.allocator };
    defer rp.in_log.deinit(std.testing.allocator);
    defer rp.out_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.registerPortRange(0x60, 4, rp.handler());

    rp.in_log.clearRetainingCapacity();
    const v = bus.portIn16(0x60);
    // regs[0]=0x10, regs[1]=0x20 → LE 0x2010.
    try std.testing.expectEqual(@as(u16, 0x2010), v);
    // Two byte INs, to ports 0x60 and 0x61, BOTH on the same handler.
    try std.testing.expectEqual(@as(usize, 2), rp.in_log.items.len);
    try std.testing.expectEqual(@as(u16, 0x60), rp.in_log.items[0]);
    try std.testing.expectEqual(@as(u16, 0x61), rp.in_log.items[1]);
}

test "32-bit IN byte-synthesizes 4 ascending byte INs from the same handler" {
    var rp = RecPort{ .alloc = std.testing.allocator };
    defer rp.in_log.deinit(std.testing.allocator);
    defer rp.out_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.registerPortRange(0x60, 4, rp.handler());
    rp.in_log.clearRetainingCapacity();
    const v = bus.portIn32(0x60);
    try std.testing.expectEqual(@as(u32, 0x40302010), v);
    try std.testing.expectEqual(@as(usize, 4), rp.in_log.items.len);
}

test "native-16-bit handler gets a single in16 (not two in8)" {
    var w = Wide16Port{};
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.registerPort(0x1F0, w.handler());
    const v = bus.portIn16(0x1F0);
    try std.testing.expectEqual(@as(u16, 0xCAFE), v);
    try std.testing.expectEqual(@as(@TypeOf(w.last), .in16), w.last);
}

test "overlap detection: portRangeClaimed reports a claimed port (the assert basis)" {
    var rp = RecPort{ .alloc = std.testing.allocator };
    defer rp.in_log.deinit(std.testing.allocator);
    defer rp.out_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    try std.testing.expect(!bus.portRangeClaimed(0x60, 1));
    _ = bus.registerPort(0x60, rp.handler());
    try std.testing.expect(bus.portRangeClaimed(0x60, 1)); // re-registering would assert
    try std.testing.expect(bus.portRangeClaimed(0x5F, 4)); // overlapping range detected
    try std.testing.expect(!bus.portRangeClaimed(0x70, 4)); // disjoint is free
}

test "registerPortRange covers each port" {
    var rp = RecPort{ .alloc = std.testing.allocator };
    defer rp.in_log.deinit(std.testing.allocator);
    defer rp.out_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.registerPortRange(0x300, 8, rp.handler());
    bus.portOut8(0x303, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), bus.portIn8(0x303));
    // A port outside the range is still unmapped.
    try std.testing.expectEqual(@as(u8, 0xFF), bus.portIn8(0x308));
}
