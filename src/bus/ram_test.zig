//! Phase 1 tests: the one fixed RAM block + direct-index 8/16/32 fast path,
//! little-endian ordering, page-boundary spans, the single-load fast path.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const memmap = @import("memmap.zig");

test "RAM r/w 8/16/32 round-trip" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();

    bus.writePhys8(0x1000, 0x12);
    try std.testing.expectEqual(@as(u8, 0x12), bus.readPhys8(0x1000));

    bus.writePhys16(0x2000, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.readPhys16(0x2000));

    bus.writePhys32(0x3000, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), bus.readPhys32(0x3000));
}

test "RAM little-endian byte ordering matches TestBus" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();

    bus.writePhys32(0x100, 0xDEADBEEF);
    // Read back individual bytes: little-endian.
    try std.testing.expectEqual(@as(u8, 0xEF), bus.readPhys8(0x100));
    try std.testing.expectEqual(@as(u8, 0xBE), bus.readPhys8(0x101));
    try std.testing.expectEqual(@as(u8, 0xAD), bus.readPhys8(0x102));
    try std.testing.expectEqual(@as(u8, 0xDE), bus.readPhys8(0x103));
    // And as a u16 over the low half.
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.readPhys16(0x100));
}

test "fresh RAM reads zero (deterministic init)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    var addr: u32 = 0;
    while (addr < 0x1000) : (addr += 0x137) {
        try std.testing.expectEqual(@as(u8, 0), bus.readPhys8(addr));
    }
    try std.testing.expectEqual(@as(u32, 0), bus.readPhys32(0x500));
}

test "16-bit access spanning a page boundary within RAM (slow per-byte path)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    const at: u32 = memmap.page_size - 1; // 0xFFF: byte 0 in page 0, byte 1 in page 1
    bus.writePhys16(at, 0xCAFE);
    try std.testing.expectEqual(@as(u16, 0xCAFE), bus.readPhys16(at));
    try std.testing.expectEqual(@as(u8, 0xFE), bus.readPhys8(at));
    try std.testing.expectEqual(@as(u8, 0xCA), bus.readPhys8(at + 1));
}

test "32-bit access straddling a page boundary within RAM" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    const at: u32 = memmap.page_size - 2; // 0xFFE: bytes split 2/2 across pages
    bus.writePhys32(at, 0x11223344);
    try std.testing.expectEqual(@as(u32, 0x11223344), bus.readPhys32(at));
    try std.testing.expectEqual(@as(u8, 0x44), bus.readPhys8(at));
    try std.testing.expectEqual(@as(u8, 0x33), bus.readPhys8(at + 1));
    try std.testing.expectEqual(@as(u8, 0x22), bus.readPhys8(at + 2));
    try std.testing.expectEqual(@as(u8, 0x11), bus.readPhys8(at + 3));
}

test "aligned wide RAM access takes the single-load fast path (still correct)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    // Aligned, mid-page: fastRamSpan is true → one readInt/writeInt.
    bus.writePhys32(0x8000, 0xA1B2C3D4);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), bus.readPhys32(0x8000));
    bus.writePhys16(0x8010, 0x5566);
    try std.testing.expectEqual(@as(u16, 0x5566), bus.readPhys16(0x8010));
}

test "HMA region (above 1 MiB) is RAM-backed with A20 enabled" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.setA20(true);
    bus.writePhys16(0x10_0000, 0x1234); // first HMA byte
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readPhys16(0x10_0000));
    bus.writePhys8(0x10_FFEF, 0x99); // FFFF:FFFF top
    try std.testing.expectEqual(@as(u8, 0x99), bus.readPhys8(0x10_FFEF));
}
