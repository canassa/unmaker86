//! ALU / arithmetic / logic execution (Phase 4b). Operand plumbing only; the
//! flag/result math lives in alu.zig (the single source of truth, D1).

const std = @import("std");
const state = @import("state.zig");
const alu = @import("alu.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const Width = alu.Width;
const Reg32 = state.Reg32;

/// The 8 ALU operations, indexed by the opcode's high 3 bits (op >> 3).
const AluOp = enum(u3) { add, or_, adc, sbb, and_, sub, xor, cmp };

fn applyAlu(f: *state.State, op: AluOp, w: Width, a: u64, b: u64, dst: *u64) void {
    const fl = &f.eflags;
    switch (op) {
        .add => dst.* = alu.add(fl, w, a, b),
        .or_ => dst.* = alu.orOp(fl, w, a, b),
        .adc => dst.* = alu.adc(fl, w, a, b),
        .sbb => dst.* = alu.sbb(fl, w, a, b),
        .and_ => dst.* = alu.andOp(fl, w, a, b),
        .sub => dst.* = alu.sub(fl, w, a, b),
        .xor => dst.* = alu.xorOp(fl, w, a, b),
        .cmp => alu.cmp(fl, w, a, b), // no write-back
    }
}

inline fn writesBack(op: AluOp) bool {
    return op != .cmp;
}

/// Primary ALU opcodes 0x00-0x3D (8 ops × 6 forms). op encodes:
///   op>>3 = which ALU op; op&7 = form:
///   0: r/m8,reg8  1: r/m,reg  2: reg8,r/m8  3: reg,r/m  4: AL,imm8  5: AX/EAX,imm
pub fn aluPrimary(cpu: anytype, op: u8) !void {
    const alu_op: AluOp = @enumFromInt(@as(u3, @truncate(op >> 3)));
    const form: u3 = @truncate(op & 7);
    const w = exec.widthOf(cpu);

    switch (form) {
        0 => { // r/m8, reg8
            try dispatch.decodeModRM(cpu);
            const a: u64 = try exec.readRM8(cpu);
            const b: u64 = exec.readReg8(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, .b8, a, b, &res);
            if (writesBack(alu_op)) try exec.writeRM8(cpu, @truncate(res));
        },
        1 => { // r/m, reg
            try dispatch.decodeModRM(cpu);
            const a = try exec.readRMv(cpu);
            const b = exec.readRegv(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, w, a, b, &res);
            if (writesBack(alu_op)) try exec.writeRMv(cpu, res);
        },
        2 => { // reg8, r/m8
            try dispatch.decodeModRM(cpu);
            const a: u64 = exec.readReg8(cpu);
            const b: u64 = try exec.readRM8(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, .b8, a, b, &res);
            if (writesBack(alu_op)) exec.writeReg8(cpu, @truncate(res));
        },
        3 => { // reg, r/m
            try dispatch.decodeModRM(cpu);
            const a = exec.readRegv(cpu);
            const b = try exec.readRMv(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, w, a, b, &res);
            if (writesBack(alu_op)) exec.writeRegv(cpu, res);
        },
        4 => { // AL, imm8
            const a: u64 = cpu.st.getReg8(0);
            const b: u64 = try dispatch.fetch8(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, .b8, a, b, &res);
            if (writesBack(alu_op)) cpu.st.setReg8(0, @truncate(res));
        },
        5 => { // AX/EAX, imm
            const a = if (w == .b32) @as(u64, cpu.st.getReg32(0)) else @as(u64, cpu.st.getReg16(0));
            const b = try dispatch.immByOpSize(cpu);
            var res: u64 = 0;
            applyAlu(&cpu.st, alu_op, w, a, b, &res);
            if (writesBack(alu_op)) {
                if (w == .b32) cpu.st.setReg32(0, @truncate(res)) else cpu.st.setReg16(0, @truncate(res));
            }
        },
        else => unreachable,
    }
}

/// INC/DEC reg16/32 (0x40-0x4F). Bit 3 of (op-0x40) selects DEC.
pub fn incDecReg(cpu: anytype, op: u8) !void {
    const idx: u3 = @truncate(op & 7);
    const is_dec = (op & 0x08) != 0;
    const w = exec.widthOf(cpu);
    const fl = &cpu.st.eflags;
    if (w == .b32) {
        const a: u64 = cpu.st.getReg32(idx);
        const r = if (is_dec) alu.dec(fl, .b32, a) else alu.inc(fl, .b32, a);
        cpu.st.setReg32(idx, @truncate(r));
    } else {
        const a: u64 = cpu.st.getReg16(idx);
        const r = if (is_dec) alu.dec(fl, .b16, a) else alu.inc(fl, .b16, a);
        cpu.st.setReg16(idx, @truncate(r));
    }
}

/// Grp1: 0x80 r/m8,imm8 ; 0x81 r/m,imm ; 0x82 r/m8,imm8 (alias of 0x80) ;
/// 0x83 r/m,imm8(sign-extended). reg field selects the ALU op.
pub fn grp1(cpu: anytype, op: u8) !void {
    try dispatch.decodeModRM(cpu);
    const alu_op: AluOp = @enumFromInt(cpu.dec.reg);

    if (op == 0x80 or op == 0x82) {
        const a: u64 = try exec.readRM8(cpu);
        const b: u64 = try dispatch.fetch8(cpu);
        var res: u64 = 0;
        applyAlu(&cpu.st, alu_op, .b8, a, b, &res);
        if (writesBack(alu_op)) try exec.writeRM8(cpu, @truncate(res));
        return;
    }

    const w = exec.widthOf(cpu);
    const a = try exec.readRMv(cpu);
    var b: u64 = undefined;
    if (op == 0x83) {
        const imm8: i8 = @bitCast(try dispatch.fetch8(cpu));
        b = if (w == .b32) @as(u64, @as(u32, @bitCast(@as(i32, imm8)))) else @as(u64, @as(u16, @bitCast(@as(i16, imm8))));
    } else {
        b = try dispatch.immByOpSize(cpu);
    }
    var res: u64 = 0;
    applyAlu(&cpu.st, alu_op, w, a, b, &res);
    if (writesBack(alu_op)) try exec.writeRMv(cpu, res);
}

/// TEST r/m8, reg8 (0x84).
pub fn testRM8(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const a: u64 = try exec.readRM8(cpu);
    const b: u64 = exec.readReg8(cpu);
    alu.testOp(&cpu.st.eflags, .b8, a, b);
}

/// TEST r/m, reg (0x85).
pub fn testRMv(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const a = try exec.readRMv(cpu);
    const b = exec.readRegv(cpu);
    alu.testOp(&cpu.st.eflags, exec.widthOf(cpu), a, b);
}
