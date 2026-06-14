//! Phase 2/3 tests: region dispatch (RAM/ROM/MMIO/unmapped), ROM installed at
//! init + write-drop, mapMmio/loadRom/unmapRegion, overlap asserts, the
//! width-aware + getHostPtr MMIO seam, EMS-style internal remap, and the
//! region-crossing wide-access ascending order.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const memmap = @import("memmap.zig");
const regions = @import("regions.zig");
const MemHandler = regions.MemHandler;

// --- A recording MMIO handler over a 4 KiB scratch buffer (byte methods only;
//     wide access exercises the byte-decompose fallback). Records the ascending
//     order of byte accesses for the region-crossing test. ---
const RecordingMmio = struct {
    base: u32,
    buf: [memmap.page_size]u8 = @splat(0),
    read_log: std.ArrayList(u32) = .empty,
    write_log: std.ArrayList(u32) = .empty,
    alloc: std.mem.Allocator,

    fn read8(ctx: *anyopaque, phys: u32) u8 {
        const self: *RecordingMmio = @ptrCast(@alignCast(ctx));
        self.read_log.append(self.alloc, phys) catch {};
        return self.buf[phys - self.base];
    }
    fn write8(ctx: *anyopaque, phys: u32, v: u8) void {
        const self: *RecordingMmio = @ptrCast(@alignCast(ctx));
        self.write_log.append(self.alloc, phys) catch {};
        self.buf[phys - self.base] = v;
    }
    const vt: MemHandler.VTable = .{ .read8 = read8, .write8 = write8 };
    fn handler(self: *RecordingMmio) MemHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

// --- A native-width-aware handler that records which width method was called. ---
const WidthMmio = struct {
    base: u32,
    last: enum { none, r8, r16, r32, w8, w16, w32 } = .none,

    fn read8(ctx: *anyopaque, _: u32) u8 {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .r8;
        return 0x11;
    }
    fn read16(ctx: *anyopaque, _: u32) u16 {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .r16;
        return 0x2222;
    }
    fn read32(ctx: *anyopaque, _: u32) u32 {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .r32;
        return 0x33333333;
    }
    fn write8(ctx: *anyopaque, _: u32, _: u8) void {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .w8;
    }
    fn write16(ctx: *anyopaque, _: u32, _: u16) void {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .w16;
    }
    fn write32(ctx: *anyopaque, _: u32, _: u32) void {
        const s: *WidthMmio = @ptrCast(@alignCast(ctx));
        s.last = .w32;
    }
    const vt: MemHandler.VTable = .{
        .read8 = read8,
        .write8 = write8,
        .read16 = read16,
        .read32 = read32,
        .write16 = write16,
        .write32 = write32,
    };
    fn handler(self: *WidthMmio) MemHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

// --- An EMS-style handler that exposes a host pointer it can swap (internal
//     remap, B8/B11). Two backing pages; the handler points at one at a time. ---
const HostPtrMmio = struct {
    page_a: [memmap.page_size]u8 = @splat(0xAA),
    page_b: [memmap.page_size]u8 = @splat(0xBB),
    active_b: bool = false,
    base_page: u32,

    fn read8(ctx: *anyopaque, phys: u32) u8 {
        const s: *HostPtrMmio = @ptrCast(@alignCast(ctx));
        const off = phys & (memmap.page_size - 1);
        return if (s.active_b) s.page_b[off] else s.page_a[off];
    }
    fn write8(ctx: *anyopaque, phys: u32, v: u8) void {
        const s: *HostPtrMmio = @ptrCast(@alignCast(ctx));
        const off = phys & (memmap.page_size - 1);
        if (s.active_b) s.page_b[off] = v else s.page_a[off] = v;
    }
    fn getHostPtr(ctx: *anyopaque, _: u32) ?[*]u8 {
        const s: *HostPtrMmio = @ptrCast(@alignCast(ctx));
        return if (s.active_b) &s.page_b else &s.page_a;
    }
    const vt: MemHandler.VTable = .{
        .read8 = read8,
        .write8 = write8,
        .getHostPtr = getHostPtr,
    };
    fn handler(self: *HostPtrMmio) MemHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

test "RAM page: read/write round-trip" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.writePhys8(0x500, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), bus.readPhys8(0x500));
}

test "ROM region installed at init: write-dropped, read-hits-backing-RAM, no image" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    // 0xF0000 is .rom from defaultPageKind even with no loadRom.
    try std.testing.expectEqual(memmap.PageKind.rom, bus.page_kind[memmap.pageIndex(0xF0000)]);
    const before = bus.rom_write_drops;
    bus.writePhys8(0xF0000, 0xEE); // dropped
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0xF0000)); // backing RAM unchanged
    try std.testing.expectEqual(before + 1, bus.rom_write_drops);
}

test "loadRom copies into backing RAM; reads hit it; writes still drop" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    const img = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    bus.loadRom(0xF0000, &img);
    try std.testing.expectEqual(@as(u32, 0xEFBEADDE), bus.readPhys32(0xF0000));
    bus.writePhys8(0xF0000, 0x00); // dropped, image preserved
    try std.testing.expectEqual(@as(u8, 0xDE), bus.readPhys8(0xF0000));
}

test "unmapped read = 0x00, write dropped (UMA default)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    try std.testing.expectEqual(memmap.PageKind.unmapped, bus.page_kind[memmap.pageIndex(0xA0000)]);
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0xA0000));
    bus.writePhys8(0xA0000, 0xFF); // dropped
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0xA0000));
}

test "mapMmio routes reads/writes to the handler (byte + decomposed wide)" {
    var rec = RecordingMmio{ .base = 0xA0000, .alloc = std.testing.allocator };
    defer rec.read_log.deinit(std.testing.allocator);
    defer rec.write_log.deinit(std.testing.allocator);

    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xA0000, memmap.page_size, rec.handler());
    try std.testing.expectEqual(memmap.PageKind.mmio, bus.page_kind[memmap.pageIndex(0xA0000)]);

    bus.writePhys8(0xA0000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), bus.readPhys8(0xA0000));
    // A 16-bit write decomposes into two ascending byte writes to the handler.
    bus.writePhys16(0xA0010, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.readPhys16(0xA0010));
    try std.testing.expectEqual(@as(u8, 0xEF), rec.buf[0x10]);
    try std.testing.expectEqual(@as(u8, 0xBE), rec.buf[0x11]);
}

test "width-aware MMIO: native width methods are called for 8/16/32" {
    var w = WidthMmio{ .base = 0xB0000 };
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xB0000, memmap.page_size, w.handler());

    _ = bus.readPhys8(0xB0000);
    try std.testing.expectEqual(@as(@TypeOf(w.last), .r8), w.last);
    _ = bus.readPhys16(0xB0000);
    try std.testing.expectEqual(@as(@TypeOf(w.last), .r16), w.last);
    _ = bus.readPhys32(0xB0000);
    try std.testing.expectEqual(@as(@TypeOf(w.last), .r32), w.last);
    bus.writePhys16(0xB0000, 0x1234);
    try std.testing.expectEqual(@as(@TypeOf(w.last), .w16), w.last);
}

test "EMS-style internal remap: swapping the backing slice relocates the window" {
    var ems = HostPtrMmio{ .base_page = memmap.pageIndex(0xE0000) };
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xE0000, memmap.page_size, ems.handler());

    // Initially points at page_a (filled 0xAA).
    try std.testing.expectEqual(@as(u8, 0xAA), bus.readPhys8(0xE0000));
    // Internal remap: swap to page_b (filled 0xBB) — zero bus EMS surface.
    ems.active_b = true;
    try std.testing.expectEqual(@as(u8, 0xBB), bus.readPhys8(0xE0000));
}

test "unmapRegion reverts pages to defaultPageKind" {
    var rec = RecordingMmio{ .base = 0xA0000, .alloc = std.testing.allocator };
    defer rec.read_log.deinit(std.testing.allocator);
    defer rec.write_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xA0000, memmap.page_size, rec.handler());
    try std.testing.expectEqual(memmap.PageKind.mmio, bus.page_kind[memmap.pageIndex(0xA0000)]);
    bus.unmapRegion(0xA0000, memmap.page_size);
    // 0xA0000 default is .unmapped.
    try std.testing.expectEqual(memmap.PageKind.unmapped, bus.page_kind[memmap.pageIndex(0xA0000)]);
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0xA0000));
}

test "region-crossing wide access routes each byte ascending to its own region" {
    var rec = RecordingMmio{ .base = 0xA0000, .alloc = std.testing.allocator };
    defer rec.read_log.deinit(std.testing.allocator);
    defer rec.write_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xA0000, memmap.page_size, rec.handler());

    // A 16-bit read straddling 0x9FFFF (RAM) / 0xA0000 (MMIO).
    bus.writePhys8(0x9FFFF, 0x77); // RAM side
    rec.buf[0] = 0x88; // MMIO side (offset 0)
    rec.read_log.clearRetainingCapacity();
    const v = bus.readPhys16(0x9FFFF);
    try std.testing.expectEqual(@as(u16, 0x8877), v); // LE: low=RAM 0x77, high=MMIO 0x88
    // The MMIO byte was read exactly once, at 0xA0000 (ascending after the RAM byte).
    try std.testing.expectEqual(@as(usize, 1), rec.read_log.items.len);
    try std.testing.expectEqual(@as(u32, 0xA0000), rec.read_log.items[0]);
}

test "overlap detection: mmioPagesClaimed reports a claimed page (the assert basis)" {
    var rec = RecordingMmio{ .base = 0xA0000, .alloc = std.testing.allocator };
    defer rec.read_log.deinit(std.testing.allocator);
    defer rec.write_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    // Before mapping: not claimed (mapMmio would succeed).
    try std.testing.expect(!bus.mmioPagesClaimed(0xA0000, memmap.page_size));
    _ = bus.mapMmio(0xA0000, memmap.page_size, rec.handler());
    // After mapping: claimed → a second mapMmio over it would assert.
    try std.testing.expect(bus.mmioPagesClaimed(0xA0000, memmap.page_size));
    // An overlapping (partially) range is also detected.
    try std.testing.expect(bus.mmioPagesClaimed(0xA0000, 2 * memmap.page_size));
    // A disjoint range is free.
    try std.testing.expect(!bus.mmioPagesClaimed(0xB0000, memmap.page_size));
}

test "32-bit MMIO write via getHostPtr-less handler decomposes ascending" {
    var rec = RecordingMmio{ .base = 0xA0000, .alloc = std.testing.allocator };
    defer rec.read_log.deinit(std.testing.allocator);
    defer rec.write_log.deinit(std.testing.allocator);
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    _ = bus.mapMmio(0xA0000, memmap.page_size, rec.handler());
    rec.write_log.clearRetainingCapacity();
    bus.writePhys32(0xA0000, 0x04030201);
    try std.testing.expectEqual(@as(usize, 4), rec.write_log.items.len);
    try std.testing.expectEqual(@as(u32, 0xA0000), rec.write_log.items[0]);
    try std.testing.expectEqual(@as(u32, 0xA0003), rec.write_log.items[3]);
    try std.testing.expectEqual(@as(u8, 0x01), rec.buf[0]);
    try std.testing.expectEqual(@as(u8, 0x04), rec.buf[3]);
}
