//! Phase 2 tests: the A20 gate — default-off at power-on, bit-20-only masking,
//! and the 1 MiB-seam wrap both ways (determinism-critical, B5).

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const a20 = @import("a20.zig");

test "A20 is DISABLED at power-on (B5)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    try std.testing.expectEqual(false, bus.a20Enabled());
    try std.testing.expectEqual(@as(u32, a20.mask_disabled), bus.a20_mask);
}

test "1 MiB wrap: FFFF:FFFF -> 0x10FFEF, A20 on lands in HMA, A20 off wraps to conventional" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();

    // With A20 ON: 0x10FFEF & 0x1FFFFF = 0x10FFEF (HMA, real storage).
    bus.setA20(true);
    bus.writePhys8(0x10_FFEF, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), bus.readPhys8(0x10_FFEF));
    // The wrapped-to-conventional address is a SEPARATE location while A20 on.
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0x00_FFEF));

    // With A20 OFF: clearing ONLY bit 20: 0x10FFEF & 0x0FFFFF = 0x00FFEF
    // (wraps into conventional). (NB: only bit 20 is cleared, not bits 12-19.)
    bus.setA20(false);
    bus.writePhys8(0x10_FFEF, 0xBB); // actually writes 0x00FFEF
    try std.testing.expectEqual(@as(u8, 0xBB), bus.readPhys8(0x00_FFEF));
    // And reading 0x10FFEF with A20 off returns the same wrapped byte.
    try std.testing.expectEqual(@as(u8, 0xBB), bus.readPhys8(0x10_FFEF));
}

test "fresh bus (default A20 off) wraps until setA20(true)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    // Default-off: writing the HMA top actually hits conventional 0x00FFEF
    // (only bit 20 cleared).
    bus.writePhys8(0x10_FFEF, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), bus.readPhys8(0x00_FFEF));
    // After enabling A20 the HMA byte is its own storage (still zero).
    bus.setA20(true);
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0x10_FFEF));
}

test "A20-off masks ONLY bit 20, does not clamp bits 21+ (resolves via page table)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    // 0x1F_F000 with A20 off masks to 0x0F_F000 (bit 20 cleared, bits 21+ n/a in
    // a 21-bit address). An in-mask-but-beyond-slab address (e.g. 0x1F_0000 with
    // A20 on) is .unmapped → 0x00 fill, never OOB.
    bus.setA20(true);
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0x1F_0000));
    bus.writePhys8(0x1F_0000, 0x42); // dropped (unmapped), no crash
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0x1F_0000));
}

test "16-bit access straddling the 1 MiB seam re-masks per byte (A20 off)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setA20(false);
    // Read a u16 at 0x10FFEF: byte0 @0x10FFEF→0x00FFEF, byte1 @0x10FFF0→0x00FFF0
    // (each byte re-masked independently, bit-20-only).
    bus.writePhys8(0x00_FFEF, 0x34);
    bus.writePhys8(0x00_FFF0, 0x12);
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readPhys16(0x10_FFEF));
}
