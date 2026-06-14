//! Region/page dispatch types: the width-aware + host-pointer-capable
//! `MemHandler` interface (B11) for MMIO (the registration seam; EMS is just an
//! MMIO device, B8), modeled on `std.mem.Allocator`'s "context ptr + vtable"
//! shape (gold standard). The bus routes RAM/ROM directly; only `.mmio` pages
//! reach a handler (the rare path — a vtable here is fine, the comptime-zero-cost
//! requirement applies to the RAM fast path, which never touches this).
//!
//! Handlers are referenced by STABLE INTEGER ID (B12), never by pointer
//! (pointers are ASLR-varying / unsnapshotable, CLAUDE #5). The bus stores the
//! ID in the per-page table; the machine re-binds ID → handler on restore.

const std = @import("std");

/// A width-aware MMIO handler (B11): an opaque context pointer + a vtable with
/// explicit per-width read/write methods and an optional host-pointer escape.
///
/// Width methods are required for faithful width-sensitive MMIO (real VGA
/// register writes are width-sensitive). A handler that only implements the byte
/// methods leaves `read16/read32/write16/write32` null; the bus then synthesizes
/// the wide access from the byte methods in fixed ascending order (the documented
/// byte-decompose fallback).
///
/// `getHostPtr(ctx, page) ?[*]u8` (DOSBox `GetHostReadPt` analog) lets RAM-like
/// MMIO (the VGA framebuffer at 0xA0000, the EMS frame, B8) stay on the
/// direct-index fast path: when it returns non-null for a page the bus indexes
/// that pointer directly; when null it falls to the per-width vtable methods.
pub const MemHandler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Required: 8-bit read. `off` is the page-relative offset (0..0xFFF) of
        /// the access within the handler's claimed region's containing page —
        /// callers pass the full A20-masked physical address; the handler
        /// decides intra-page decode. We pass the FULL masked physical address
        /// so a multi-page handler (e.g. the 64 KiB EMS frame) can decode it.
        read8: *const fn (ctx: *anyopaque, phys: u32) u8,
        /// Required: 8-bit write.
        write8: *const fn (ctx: *anyopaque, phys: u32, v: u8) void,
        /// Optional native 16-bit read; null → byte-synthesized.
        read16: ?*const fn (ctx: *anyopaque, phys: u32) u16 = null,
        /// Optional native 32-bit read; null → byte-synthesized.
        read32: ?*const fn (ctx: *anyopaque, phys: u32) u32 = null,
        /// Optional native 16-bit write; null → byte-synthesized.
        write16: ?*const fn (ctx: *anyopaque, phys: u32, v: u16) void = null,
        /// Optional native 32-bit write; null → byte-synthesized.
        write32: ?*const fn (ctx: *anyopaque, phys: u32, v: u32) void = null,
        /// Optional host-pointer escape (B11). Returns a pointer to the start of
        /// the given guest page's backing bytes if this handler is RAM-like, so
        /// the bus can index it directly; null → use the per-width methods.
        getHostPtr: ?*const fn (ctx: *anyopaque, page: u32) ?[*]u8 = null,
    };

    // --- Per-width dispatch with the byte-decompose fallback (B11). ---
    pub inline fn read8(self: MemHandler, phys: u32) u8 {
        return self.vtable.read8(self.ctx, phys);
    }
    pub inline fn write8(self: MemHandler, phys: u32, v: u8) void {
        self.vtable.write8(self.ctx, phys, v);
    }
    pub inline fn read16(self: MemHandler, phys: u32) u16 {
        if (self.vtable.read16) |f| return f(self.ctx, phys);
        // Byte-synthesize in fixed ascending order, little-endian.
        return @as(u16, self.read8(phys)) | (@as(u16, self.read8(phys +% 1)) << 8);
    }
    pub inline fn read32(self: MemHandler, phys: u32) u32 {
        if (self.vtable.read32) |f| return f(self.ctx, phys);
        return @as(u32, self.read8(phys)) |
            (@as(u32, self.read8(phys +% 1)) << 8) |
            (@as(u32, self.read8(phys +% 2)) << 16) |
            (@as(u32, self.read8(phys +% 3)) << 24);
    }
    pub inline fn write16(self: MemHandler, phys: u32, v: u16) void {
        if (self.vtable.write16) |f| return f(self.ctx, phys, v);
        self.write8(phys, @truncate(v));
        self.write8(phys +% 1, @truncate(v >> 8));
    }
    pub inline fn write32(self: MemHandler, phys: u32, v: u32) void {
        if (self.vtable.write32) |f| return f(self.ctx, phys, v);
        self.write8(phys, @truncate(v));
        self.write8(phys +% 1, @truncate(v >> 8));
        self.write8(phys +% 2, @truncate(v >> 16));
        self.write8(phys +% 3, @truncate(v >> 24));
    }
    pub inline fn hostPtr(self: MemHandler, page: u32) ?[*]u8 {
        if (self.vtable.getHostPtr) |f| return f(self.ctx, page);
        return null;
    }
};
