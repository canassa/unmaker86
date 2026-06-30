//! Phase 4 determinism audit (B9 — the module gate): grep-enforced no-host-state,
//! same-ops-twice byte-identical, fresh-bus byte-identical, zero-alloc on the
//! access path, and the populated-bus snapshot→restore→byte-identical round-trip
//! with handlers re-bound by stable ID (B12).
//!
//! CONFORMANCE-ANGLE NOTE (Phase 4): the CPU's `TestBus` already validates the
//! contract SHAPE — the 12 methods, little-endian round-trip, sparse fill. The
//! REAL bus adds, and tests HERE (not in ProcessorTests), what `TestBus` does
//! not: region dispatch (RAM/ROM/MMIO/unmapped), the A20 gate + 1 MiB wrap, the
//! registered port dispatch + the 0xFF floating-bus default, the width-aware +
//! host-ptr MMIO seam, the standard ROM regions, the region-crossing wide-access
//! path, and the snapshot round-trip. Also: the real bus's single-region wide
//! path is one `readInt`/`writeInt` (Phase 1), NOT `TestBus`'s per-byte loop.

const std = @import("std");
const bus_mod = @import("bus.zig");
const Bus = bus_mod.Bus;
const memmap = @import("memmap.zig");
const ports = @import("ports.zig");
const regions = @import("regions.zig");

test "no host time / RNG / thread / env reads anywhere in src/bus (grep-enforced)" {
    const sources = [_][]const u8{
        @embedFile("bus.zig"),
        @embedFile("memmap.zig"),
        @embedFile("a20.zig"),
        @embedFile("regions.zig"),
        @embedFile("ports.zig"),
    };
    const forbidden = [_][]const u8{
        "std.time",
        "std.Random",
        "std.rand",
        "std.Thread",
        "std.posix.getenv",
        "std.process.getEnv",
        "std.os.getenv",
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a bus source file\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

/// Run a fixed scripted sequence across RAM/ROM/unmapped + ports + an A20 toggle.
/// Returns a digest of all returned values so two runs can be compared.
fn scriptedRun(bus: *Bus, out_reads: *std.ArrayList(u64), alloc: std.mem.Allocator) !void {
    bus.writePhys8(0x1000, 0x11);
    bus.writePhys16(0x1002, 0x2233);
    bus.writePhys32(0x1004, 0x44556677);
    bus.writePhys8(0xF0000, 0xEE); // ROM: dropped
    bus.writePhys8(0xA0000, 0xEE); // unmapped: dropped
    bus.setA20(true);
    bus.writePhys16(0x10_0000, 0xABCD); // HMA
    bus.setA20(false);

    try out_reads.append(alloc, bus.readPhys8(0x1000));
    try out_reads.append(alloc, bus.readPhys16(0x1002));
    try out_reads.append(alloc, bus.readPhys32(0x1004));
    try out_reads.append(alloc, bus.readPhys8(0xF0000)); // 0 (write dropped)
    try out_reads.append(alloc, bus.readPhys8(0xA0000)); // 0 fill
    try out_reads.append(alloc, bus.portIn8(0x3F8)); // 0xFF
    try out_reads.append(alloc, bus.portIn16(0x60)); // 0xFFFF
    bus.portOut8(0x60, 0x77); // dropped (unmapped)
}

test "same ops twice on fresh buses → byte-identical RAM + identical returns" {
    var reads_a: std.ArrayList(u64) = .empty;
    defer reads_a.deinit(std.testing.allocator);
    var reads_b: std.ArrayList(u64) = .empty;
    defer reads_b.deinit(std.testing.allocator);

    var bus_a = try Bus.init(std.testing.allocator);
    defer bus_a.deinit();
    var bus_b = try Bus.init(std.testing.allocator);
    defer bus_b.deinit();

    try scriptedRun(&bus_a, &reads_a, std.testing.allocator);
    try scriptedRun(&bus_b, &reads_b, std.testing.allocator);

    try std.testing.expectEqualSlices(u64, reads_a.items, reads_b.items);
    try std.testing.expectEqualSlices(u8, bus_a.ram, bus_b.ram);
    try std.testing.expectEqual(bus_a.a20_mask, bus_b.a20_mask);
    try std.testing.expectEqualSlices(memmap.PageKind, &bus_a.page_kind, &bus_b.page_kind);
}

test "fresh bus is byte-identical: RAM zero, tables default (no uninitialized state)" {
    var a = try Bus.init(std.testing.allocator);
    defer a.deinit();
    var b = try Bus.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, a.ram, b.ram);
    // RAM is all zero.
    for (a.ram) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualSlices(memmap.PageKind, &a.page_kind, &b.page_kind);
    try std.testing.expectEqualSlices(u8, &a.page_handler_id, &b.page_handler_id);
    try std.testing.expectEqualSlices(u8, &a.port_handler_id, &b.port_handler_id);
    try std.testing.expectEqual(a.a20_mask, b.a20_mask);
}

/// Counting allocator: records alloc/free/resize/remap so the access path can be
/// asserted alloc-free (memory-and-performance.md §7).
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawResize(m, a, nl, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawRemap(m, a, nl, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.backing.rawFree(m, a, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "zero allocation on the access path (read/write/port)" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    var bus = try Bus.init(counting.allocator());
    defer bus.deinit();
    const after_init = counting.count;

    // Exercise every access method; none may allocate.
    bus.writePhys8(0x10, 1);
    bus.writePhys16(0x12, 2);
    bus.writePhys32(0x14, 3);
    _ = bus.readPhys8(0x10);
    _ = bus.readPhys16(0x12);
    _ = bus.readPhys32(0x14);
    _ = bus.portIn8(0x60);
    _ = bus.portIn16(0x60);
    _ = bus.portIn32(0x60);
    bus.portOut8(0x60, 1);
    bus.portOut16(0x60, 2);
    bus.portOut32(0x60, 3);
    bus.setA20(true);
    // Region-crossing wide access (slow path) must not allocate either.
    _ = bus.readPhys32(0x9FFFE);

    try std.testing.expectEqual(after_init, counting.count);
}

// --- Snapshot round-trip (B12): handlers re-bound by stable ID, never pointer. ---

const SnapHandler = struct {
    tag: u8,
    fn read8(ctx: *anyopaque, _: u32) u8 {
        const s: *SnapHandler = @ptrCast(@alignCast(ctx));
        return s.tag;
    }
    fn write8(_: *anyopaque, _: u32, _: u8) void {}
    const vt: regions.MemHandler.VTable = .{ .read8 = read8, .write8 = write8 };
    fn handler(self: *SnapHandler) regions.MemHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

const SnapPort = struct {
    tag: u8,
    fn in8(ctx: *anyopaque, _: u16) u8 {
        const s: *SnapPort = @ptrCast(@alignCast(ctx));
        return s.tag;
    }
    fn out8(_: *anyopaque, _: u16, _: u8) void {}
    const vt: ports.PortHandler.VTable = .{ .in8 = in8, .out8 = out8 };
    fn handler(self: *SnapPort) ports.PortHandler {
        return .{ .ctx = self, .vtable = &vt };
    }
};

/// Replay the machine's CONFIG registrations in a fixed order (assigns the same
/// stable IDs). Used to build both the original and the restored bus.
fn registerConfig(bus: *Bus, mmio: *SnapHandler, port: *SnapPort) void {
    _ = bus.mapMmio(0xA0000, memmap.page_size, mmio.handler());
    _ = bus.registerPort(0x60, port.handler());
}

test "populated bus snapshot → restore → byte-identical, handlers re-bound by ID" {
    var mmio = SnapHandler{ .tag = 0x5A };
    var port = SnapPort{ .tag = 0x42 };

    // --- Original bus: register config, mutate state. ---
    var orig = try Bus.init(std.testing.allocator);
    defer orig.deinit();
    registerConfig(&orig, &mmio, &port);
    orig.writePhys32(0x1234, 0xCAFEBABE);
    orig.writePhys8(0x8000, 0x99);
    orig.setA20(true);
    // Mutate the page-kind table at runtime (EMS-style remap analog).
    _ = orig.mapMmio(0xE0000, memmap.page_size, mmio.handler());

    const snap = orig.snapshot();
    const ram_copy = try std.testing.allocator.dupe(u8, orig.ram);
    defer std.testing.allocator.free(ram_copy);

    // --- Restored bus: machine replays config (same order → same IDs), then
    //     restore overwrites RAM + A20 + the mutated tables. ---
    var restored = try Bus.init(std.testing.allocator);
    defer restored.deinit();
    registerConfig(&restored, &mmio, &port);
    _ = restored.mapMmio(0xE0000, memmap.page_size, mmio.handler()); // same replay order
    @memcpy(restored.ram, ram_copy);
    restored.restore(snap);

    // Byte-identical: RAM, A20, page-kind, handler-ID tables.
    try std.testing.expectEqualSlices(u8, orig.ram, restored.ram);
    try std.testing.expectEqual(orig.a20_mask, restored.a20_mask);
    try std.testing.expectEqualSlices(memmap.PageKind, &orig.page_kind, &restored.page_kind);
    try std.testing.expectEqualSlices(u8, &orig.page_handler_id, &restored.page_handler_id);
    try std.testing.expectEqualSlices(u8, &orig.port_handler_id, &restored.port_handler_id);

    // Functional: reads through re-bound handlers/IDs work on the restored bus.
    try std.testing.expectEqual(@as(u8, 0x5A), restored.readPhys8(0xA0000));
    try std.testing.expectEqual(@as(u8, 0x42), restored.portIn8(0x60));
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), restored.readPhys32(0x1234));
}
