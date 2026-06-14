//! Bit instructions (Phase 4d): BT/BTS/BTR/BTC and BSF/BSR.

const std = @import("std");
const alu = @import("alu.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const flags = @import("flags.zig");
const Width = alu.Width;

const BitOp = enum { bt, bts, btr, btc };

/// BT/BTS/BTR/BTC with a register bit-index (0F A3/AB/B3/BB). For a memory
/// operand the bit offset indexes adjacent memory (the bit-string semantics):
/// effective address += (offset/operand-bits)*bytes, bit = offset % bits.
pub fn btReg(cpu: anytype, op: BitOp) !void {
    try dispatch.decodeModRM(cpu);
    const w = exec.widthOf(cpu);
    const bits: i64 = w.bits();
    const index_raw = exec.readRegv(cpu);

    if (cpu.dec.kind == .mem) {
        // Signed bit offset indexes the bit string in memory.
        const signed_index: i64 = alu.signExtend(w, index_raw);
        const byte_off = @divFloor(signed_index, 8);
        const bit_in_byte: u3 = @intCast(@mod(signed_index, 8));
        var addr: u32 = @bitCast(@as(i32, @truncate(@as(i64, @as(i32, @bitCast(cpu.dec.mem_off))) + byte_off)));
        // The effective address wraps within the current address size (16-bit
        // addressing masks to 0xFFFF — keeps the bit-string offset in-segment,
        // matching the 386).
        if (cpu.dec.addr_size == .a16) addr &= 0xFFFF;
        const byte = try cpu.segRead8(cpu.dec.mem_seg, addr);
        const bit = (byte >> bit_in_byte) & 1;
        cpu.st.eflags.cf = bit != 0;
        if (op != .bt) {
            const new_byte = applyBit(op, byte, bit_in_byte);
            try cpu.segWrite8(cpu.dec.mem_seg, addr, new_byte);
        }
        return;
    }

    // Register operand: bit index is taken mod operand-size.
    const bit_index: u6 = @intCast(@mod(@as(i64, @bitCast(index_raw)), bits));
    const v = try exec.readRMv(cpu);
    const bit = (v >> bit_index) & 1;
    cpu.st.eflags.cf = bit != 0;
    if (op != .bt) {
        const nv = applyBitWide(op, v, bit_index, w);
        try exec.writeRMv(cpu, nv);
    }
}

/// Grp8 (0F BA /4-7): BT/BTS/BTR/BTC r/m, imm8.
pub fn grp8(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const op: BitOp = switch (cpu.dec.reg) {
        4 => .bt,
        5 => .bts,
        6 => .btr,
        7 => .btc,
        else => return exec.ud(cpu),
    };
    const w = exec.widthOf(cpu);
    const imm = try dispatch.fetch8(cpu);
    const bit_index: u6 = @intCast(imm & @as(u8, @intCast(w.bits() - 1)));
    const v = try exec.readRMv(cpu);
    cpu.st.eflags.cf = ((v >> bit_index) & 1) != 0;
    if (op != .bt) {
        try exec.writeRMv(cpu, applyBitWide(op, v, bit_index, w));
    }
}

fn applyBit(op: BitOp, byte: u8, bit: u3) u8 {
    const mask = @as(u8, 1) << bit;
    return switch (op) {
        .bt => byte,
        .bts => byte | mask,
        .btr => byte & ~mask,
        .btc => byte ^ mask,
    };
}

fn applyBitWide(op: BitOp, v: u64, bit: u6, w: Width) u64 {
    const mask = @as(u64, 1) << bit;
    const r = switch (op) {
        .bt => v,
        .bts => v | mask,
        .btr => v & ~mask,
        .btc => v ^ mask,
    };
    return r & w.mask();
}

/// BSF (0F BC) / BSR (0F BD). ZF set if source==0; dest undefined then (D9:
/// leave dest unchanged, pinned).
pub fn bsf_bsr(cpu: anytype, reverse: bool) !void {
    try dispatch.decodeModRM(cpu);
    const w = exec.widthOf(cpu);
    const src = (try exec.readRMv(cpu)) & w.mask();
    if (src == 0) {
        cpu.st.eflags.zf = true;
        return; // dest unchanged (undefined, pinned)
    }
    cpu.st.eflags.zf = false;
    // src is held in a u64 container; @ctz/@clz operate on that 64-bit width.
    // BSF = index of lowest set bit = @ctz. BSR = index of highest set bit =
    // 63 - @clz (the container is 64 bits).
    const result: u64 = if (reverse) (63 - @clz(src)) else @ctz(src);
    exec.writeRegv(cpu, result);
}
