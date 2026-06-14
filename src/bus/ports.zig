//! Port I/O dispatch types (B6, B7): the `PortHandler` interface and the
//! width-capability descriptor used for single-handler 16/32-bit dispatch.
//!
//! Dispatch table layout (B6) lives on the `Bus`: a dense `port_handler_id:
//! [65536]u8` index table (64 KiB, at the COLD TAIL of the struct, never touched
//! by the RAM fast path) + a small handler array. ID `0` is the reserved
//! "unmapped" slot (floating-bus 0xFF read / dropped write, B7). Handlers are
//! referenced by stable integer ID (B12), never by pointer.
//!
//! 16/32-bit access dispatches to the SINGLE handler at the base port (NOT
//! port+1, B6): native-width method if the handler advertises that width via its
//! `width` descriptor, else byte-synthesis from THAT SAME handler. Port
//! aliasing/mirroring is the device's responsibility.

const std = @import("std");

/// Which native access widths a `PortHandler` implements. The bus uses this to
/// decide native-width dispatch vs byte-synthesis (B6). Byte (`in8/out8`) is
/// always required.
pub const WidthCaps = packed struct(u8) {
    w16: bool = false,
    w32: bool = false,
    _pad: u6 = 0,
};

/// A width-aware port handler (B6): opaque context + a vtable mirroring the bus
/// contract's per-width port methods.
pub const PortHandler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Which native widths the handler implements (besides the required 8).
        width: WidthCaps = .{},
        in8: *const fn (ctx: *anyopaque, port: u16) u8,
        out8: *const fn (ctx: *anyopaque, port: u16, v: u8) void,
        in16: ?*const fn (ctx: *anyopaque, port: u16) u16 = null,
        in32: ?*const fn (ctx: *anyopaque, port: u16) u32 = null,
        out16: ?*const fn (ctx: *anyopaque, port: u16, v: u16) void = null,
        out32: ?*const fn (ctx: *anyopaque, port: u16, v: u32) void = null,
    };

    pub inline fn in8(self: PortHandler, port: u16) u8 {
        return self.vtable.in8(self.ctx, port);
    }
    pub inline fn out8(self: PortHandler, port: u16, v: u8) void {
        self.vtable.out8(self.ctx, port, v);
    }
    pub inline fn in16(self: PortHandler, port: u16) u16 {
        if (self.vtable.width.w16) {
            if (self.vtable.in16) |f| return f(self.ctx, port);
        }
        // Byte-synthesize from THIS SAME handler, ascending, little-endian.
        return @as(u16, self.in8(port)) | (@as(u16, self.in8(port +% 1)) << 8);
    }
    pub inline fn in32(self: PortHandler, port: u16) u32 {
        if (self.vtable.width.w32) {
            if (self.vtable.in32) |f| return f(self.ctx, port);
        }
        return @as(u32, self.in8(port)) |
            (@as(u32, self.in8(port +% 1)) << 8) |
            (@as(u32, self.in8(port +% 2)) << 16) |
            (@as(u32, self.in8(port +% 3)) << 24);
    }
    pub inline fn out16(self: PortHandler, port: u16, v: u16) void {
        if (self.vtable.width.w16) {
            if (self.vtable.out16) |f| return f(self.ctx, port, v);
        }
        self.out8(port, @truncate(v));
        self.out8(port +% 1, @truncate(v >> 8));
    }
    pub inline fn out32(self: PortHandler, port: u16, v: u32) void {
        if (self.vtable.width.w32) {
            if (self.vtable.out32) |f| return f(self.ctx, port, v);
        }
        self.out8(port, @truncate(v));
        self.out8(port +% 1, @truncate(v >> 8));
        self.out8(port +% 2, @truncate(v >> 16));
        self.out8(port +% 3, @truncate(v >> 24));
    }
};

/// Floating-bus port-read defaults (B7) — the deterministic unmapped values.
pub const unmapped_in8: u8 = 0xFF;
pub const unmapped_in16: u16 = 0xFFFF;
pub const unmapped_in32: u32 = 0xFFFF_FFFF;
