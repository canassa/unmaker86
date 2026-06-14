//! Decode front end (Phase 2): prefix scan, operand/address-size resolution,
//! ModR/M + SIB, immediate/displacement fetch.
//!
//! Produces a `Decoded` describing the instruction: opcode, resolved sizes, and
//! a fully computed effective address / register operand with its effective
//! segment. The instruction-fetch helpers go through the CPU's segmented CS:EIP
//! memory path and charge fetch cost there.

const std = @import("std");
const state = @import("state.zig");
const Seg = state.Seg;

pub const OperandSize = enum { b16, b32 };
pub const AddrSize = enum { a16, a32 };

/// A decoded operand: either a register (by index) or memory (linear EA already
/// resolved against the effective segment's limit will happen at access time).
pub const OperandKind = enum { reg, mem };

/// Per-instruction decode result. Reset each step; no allocation.
pub const Decoded = struct {
    // Prefixes (single forward scan).
    seg_override: ?Seg = null,
    has_66: bool = false,
    has_67: bool = false,
    rep: bool = false, // F3
    repne: bool = false, // F2
    lock: bool = false,
    prefix_len: u8 = 0,

    // Resolved sizes.
    op_size: OperandSize = .b16,
    addr_size: AddrSize = .a16,

    // Opcode.
    is_0F: bool = false,
    opcode: u8 = 0,
    /// Dispatch key (D2): (op_size==b32 ? 0x200 : 0) | (is_0F ? 0x100 : 0) | opcode.
    key: u12 = 0,

    // ModR/M (valid once decodeModRM ran).
    has_modrm: bool = false,
    modrm: u8 = 0,
    mod: u2 = 0,
    reg: u3 = 0,
    rm: u3 = 0,
    /// Operand location.
    kind: OperandKind = .reg,
    /// For reg operand: the register index (rm field).
    /// For mem operand: the effective segment + offset (effective address).
    mem_seg: Seg = .ds,
    mem_off: u32 = 0,

    /// Total instruction length so far (for the 15-byte limit + EIP advance).
    len: u8 = 0,

    pub fn reset(self: *Decoded) void {
        self.* = .{};
    }
};

/// Resolve sizes from CS.D and the 0x66/0x67 prefixes. In real mode CS.D=0.
pub fn resolveSizes(d: *Decoded, cs_big: bool) void {
    const base_op: OperandSize = if (cs_big) .b32 else .b16;
    const base_addr: AddrSize = if (cs_big) .a32 else .a16;
    d.op_size = if (d.has_66) (if (base_op == .b16) .b32 else .b16) else base_op;
    d.addr_size = if (d.has_67) (if (base_addr == .a16) .a32 else .a16) else base_addr;
}

/// Compute the dispatch key (D2) from resolved state.
pub fn computeKey(d: *Decoded) void {
    var k: u12 = d.opcode;
    if (d.is_0F) k |= 0x100;
    if (d.op_size == .b32) k |= 0x200;
    d.key = k;
}

// ---------------------------------------------------------------------------
// 16-bit ModR/M effective-address base/index table (Intel encoding).
// Returns the two register contributions + default segment for rm (mod != 11).
// ---------------------------------------------------------------------------

pub const Rm16 = struct {
    /// list of GP reg indices to sum (16-bit views).
    base_reg: ?u3,
    index_reg: ?u3,
    default_seg: Seg,
    /// true for the special mod00/rm110 disp16-direct form.
    disp16_direct: bool = false,
};

/// rm field (0..7) -> 16-bit addressing components (for mod 00/01/10).
pub fn rm16(rm: u3) Rm16 {
    return switch (rm) {
        0 => .{ .base_reg = 3, .index_reg = 6, .default_seg = .ds }, // BX+SI
        1 => .{ .base_reg = 3, .index_reg = 7, .default_seg = .ds }, // BX+DI
        2 => .{ .base_reg = 5, .index_reg = 6, .default_seg = .ss }, // BP+SI
        3 => .{ .base_reg = 5, .index_reg = 7, .default_seg = .ss }, // BP+DI
        4 => .{ .base_reg = 6, .index_reg = null, .default_seg = .ds }, // SI
        5 => .{ .base_reg = 7, .index_reg = null, .default_seg = .ds }, // DI
        6 => .{ .base_reg = 5, .index_reg = null, .default_seg = .ss }, // BP
        7 => .{ .base_reg = 3, .index_reg = null, .default_seg = .ds }, // BX
    };
}

test "rm16 BP defaults to SS, BX to DS" {
    try std.testing.expectEqual(Seg.ss, rm16(6).default_seg);
    try std.testing.expectEqual(Seg.ds, rm16(7).default_seg);
    try std.testing.expectEqual(Seg.ss, rm16(2).default_seg);
}
