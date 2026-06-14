//! EFLAGS bit layout, the eager condition-code storage (D1), and the parity
//! table. The Jcc/SETcc condition path reads the packed fields directly (Theme
//! G); `toU32` is used ONLY for PUSHF / save-restore.

const std = @import("std");

/// EFLAGS as a packed struct (D1 storage decision). Bit positions per Intel
/// 386 PRM / dosbox registers.h:
///   CF=0, (1=1 reserved), PF=2, (3=0), AF=4, (5=0), ZF=6, SF=7, TF=8, IF=9,
///   DF=10, OF=11, IOPL=12-13, NT=14, (15=0), RF=16, VM=17, AC=18, ...
pub const Flags = packed struct(u32) {
    cf: bool = false,
    _r1: u1 = 1, // reserved, always 1
    pf: bool = false,
    _r3: u1 = 0, // reserved, always 0
    af: bool = false,
    _r5: u1 = 0, // reserved, always 0
    zf: bool = false,
    sf: bool = false,
    tf: bool = false,
    iff: bool = false, // IF (interrupt enable)
    df: bool = false,
    of: bool = false,
    iopl: u2 = 0,
    nt: bool = false,
    _r15: u1 = 0, // reserved, always 0
    rf: bool = false,
    vm: bool = false,
    ac: bool = false,
    _hi: u13 = 0, // bits 19..31 (id/vip/vif etc.) — stored as a block, 0 in scope

    /// Reserved-bit mask applied on every fromU32: bit1=1, bits 3,5,15 = 0,
    /// and bits 18..31 forced to 0. On the 80386 the highest defined EFLAGS bit
    /// is VM (bit 17); AC (bit 18) is 486+ and the bits above are reserved, so
    /// they must read back as 0 (PUSHFD must not push a phantom AC). This is the
    /// real-386 reserved-bit behavior (validated against the SingleStepTests
    /// vectors: a set bit 18 in the input EFLAGS must NOT survive into PUSHFD).
    pub fn fromU32(v: u32) Flags {
        var masked: u32 = v;
        masked |= 0x0000_0002; // bit 1 always 1
        masked &= ~@as(u32, 0x0000_8028); // clear bits 3,5,15
        masked &= 0x0003_FFFF; // clear bits 18..31 (not present on the 386)
        return @bitCast(masked);
    }

    pub fn toU32(self: Flags) u32 {
        return @bitCast(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(Flags) == 4);
    std.debug.assert(@bitSizeOf(Flags) == 32);
}

/// EFLAGS write masks for POPF/IRET. In real mode CPL=0 so all writable bits
/// are writable; the helper exists so the deferred PM path can reuse it
/// (cf. cpu.cpp FMASK_NORMAL vs FMASK_ALL).
pub const FMASK_TEST: u32 = 0x0000_08D5; // CF PF AF ZF SF OF
pub const FMASK_NORMAL: u32 = FMASK_TEST | 0x0000_0700; // + TF IF DF
pub const FMASK_ALL: u32 = FMASK_NORMAL | 0x0000_7000; // + IOPL NT

/// 256-entry even-parity table for the low byte (PF). Generated at comptime.
pub const parity_table: [256]bool = blk: {
    var t: [256]bool = undefined;
    for (0..256) |i| {
        t[i] = (@popCount(@as(u8, @intCast(i))) & 1) == 0;
    }
    break :blk t;
};

test "Flags round-trips through u32 with reserved-bit masking" {
    const f = Flags.fromU32(0xFFFF_FFFF);
    const u = f.toU32();
    // bit 1 set, bits 3,5,15 clear, bits >=19 clear
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(u >> 1)));
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(u >> 3)));
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(u >> 5)));
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(u >> 15)));
    try std.testing.expectEqual(@as(u32, 0), u >> 18); // bits 18..31 cleared (386)
}

test "parity table" {
    try std.testing.expect(parity_table[0x00]); // even (0 bits)
    try std.testing.expect(parity_table[0x03]); // even (2 bits)
    try std.testing.expect(!parity_table[0x01]); // odd
    try std.testing.expect(!parity_table[0x07]); // odd (3 bits)
}
