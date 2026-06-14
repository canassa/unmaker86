//! Shift & rotate execution (Phase 4c): Grp2 (C0/C1/D0/D1/D2/D3) and the
//! double-precision SHLD/SHRD (0F A4/A5/AC/AD).

const std = @import("std");
const alu = @import("alu.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const flags = @import("flags.zig");
const Width = alu.Width;

const ShiftOp = enum(u3) { rol, ror, rcl, rcr, shl, shr, sal, sar };

fn applyShift(f: *flags.Flags, op: ShiftOp, w: Width, v: u64, count: u64) u64 {
    return switch (op) {
        .rol => alu.rol(f, w, v, count),
        .ror => alu.ror(f, w, v, count),
        .rcl => alu.rcl(f, w, v, count),
        .rcr => alu.rcr(f, w, v, count),
        .shl, .sal => alu.shl(f, w, v, count),
        .shr => alu.shr(f, w, v, count),
        .sar => alu.sar(f, w, v, count),
    };
}

/// Grp2. op selects width/count source:
///   C0 r/m8,imm8   C1 r/m,imm8   D0 r/m8,1   D1 r/m,1   D2 r/m8,CL  D3 r/m,CL
pub fn grp2(cpu: anytype, op: u8) !void {
    try dispatch.decodeModRM(cpu);
    const shift_op: ShiftOp = @enumFromInt(cpu.dec.reg);
    const byte = (op == 0xC0 or op == 0xD0 or op == 0xD2);

    var count: u64 = undefined;
    switch (op) {
        0xC0, 0xC1 => count = try dispatch.fetch8(cpu),
        0xD0, 0xD1 => count = 1,
        0xD2, 0xD3 => count = cpu.st.getReg8(1), // CL
        else => unreachable,
    }

    const f = &cpu.st.eflags;
    if (byte) {
        const v: u64 = try exec.readRM8(cpu);
        const r = applyShift(f, shift_op, .b8, v, count);
        try exec.writeRM8(cpu, @truncate(r));
    } else {
        const w = exec.widthOf(cpu);
        const v = try exec.readRMv(cpu);
        const r = applyShift(f, shift_op, w, v, count);
        try exec.writeRMv(cpu, r);
    }
}

/// SHLD/SHRD. op: 0xA4 SHLD r/m,reg,imm8 ; 0xA5 SHLD r/m,reg,CL ;
/// 0xAC SHRD r/m,reg,imm8 ; 0xAD SHRD r/m,reg,CL.
pub fn shld_shrd(cpu: anytype, op: u8) !void {
    try dispatch.decodeModRM(cpu);
    const is_left = (op == 0xA4 or op == 0xA5);
    const use_cl = (op == 0xA5 or op == 0xAD);
    const count_raw: u64 = if (use_cl) cpu.st.getReg8(1) else try dispatch.fetch8(cpu);
    const w = exec.widthOf(cpu);
    const count: u6 = @truncate(count_raw & 0x1F);

    const dst = try exec.readRMv(cpu);
    const src = exec.readRegv(cpu);
    const f = &cpu.st.eflags;
    if (count == 0) return; // count==0: result and flags unchanged.

    // The exact 16- vs 32-bit result formulas (incl. count>16 for the 16-bit
    // forms) mirror the 386: see dosbox `DSHLW/DSHRW/DSHLD/DSHRD`. CF = the last
    // bit shifted out of the destination.
    var res: u64 = undefined;
    var cf: bool = undefined;
    if (w == .b32) {
        const d: u32 = @truncate(dst);
        const s: u32 = @truncate(src);
        const c: u5 = @truncate(count);
        if (is_left) {
            cf = ((d >> @intCast(32 - @as(u6, c))) & 1) != 0;
            res = (@as(u64, d) << c) | (@as(u64, s) >> @intCast(32 - @as(u6, c)));
        } else {
            cf = ((d >> @intCast(@as(u6, c) - 1)) & 1) != 0;
            res = (@as(u64, d) >> c) | (@as(u64, s) << @intCast(32 - @as(u6, c)));
        }
        res &= 0xFFFF_FFFF;
    } else {
        // 16-bit: assemble a 32-bit working value and extract the result word.
        const d: u32 = @as(u32, @truncate(dst)) & 0xFFFF;
        const s: u32 = @as(u32, @truncate(src)) & 0xFFFF;
        const c: u6 = count;
        if (is_left) {
            cf = ((d >> @intCast(16 - @min(c, 16))) & 1) != 0;
            var tempd: u32 = ((d << 16) | s) << @intCast(c);
            if (c > 16) tempd |= s << @intCast(c - 16);
            res = (tempd >> 16) & 0xFFFF;
        } else {
            cf = ((d >> @intCast(@min(c, 16) - 1)) & 1) != 0;
            var tempd: u32 = ((s << 16) | d) >> @intCast(c);
            if (c > 16) tempd |= s << @intCast(32 - @as(u6, c));
            res = tempd & 0xFFFF;
        }
    }
    f.cf = cf;
    // OF defined for count==1 (= sign change); the 386 leaves it deterministic
    // but the harness treats OF undefined for SHLD/SHRD (D9 supplement), so this
    // value is not compared for count != 1 either way.
    f.of = ((res ^ dst) & w.signbit()) != 0;
    setSzpAfter(f, w, res);
    f.af = false;
    try exec.writeRMv(cpu, res);
}

fn setSzpAfter(f: *flags.Flags, w: Width, res: u64) void {
    const r = res & w.mask();
    f.zf = (r == 0);
    f.sf = (r & w.signbit()) != 0;
    f.pf = flags.parity_table[@as(u8, @truncate(r))];
}
