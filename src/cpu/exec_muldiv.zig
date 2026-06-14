//! Grp3 (TEST/NOT/NEG/MUL/IMUL/DIV/IDIV) and the 2/3-operand IMUL (Phase 4e).
//! #DE on divide error (restartable fault; no state change before the fault).

const std = @import("std");
const alu = @import("alu.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const interrupts = @import("interrupts.zig");
const state = @import("state.zig");
const Width = alu.Width;
const Reg32 = state.Reg32;

const EAX = @intFromEnum(Reg32.eax);
const EDX = @intFromEnum(Reg32.edx);

/// Grp3 byte form (0xF6). reg: 0/1 TEST imm8, 2 NOT, 3 NEG, 4 MUL, 5 IMUL,
/// 6 DIV, 7 IDIV.
pub fn grp3b(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const f = &cpu.st.eflags;
    switch (cpu.dec.reg) {
        0, 1 => {
            const a: u64 = try exec.readRM8(cpu);
            const imm: u64 = try dispatch.fetch8(cpu);
            alu.testOp(f, .b8, a, imm);
        },
        2 => { // NOT (no flags)
            const v = try exec.readRM8(cpu);
            try exec.writeRM8(cpu, @truncate(alu.notOp(.b8, v)));
        },
        3 => { // NEG
            const v: u64 = try exec.readRM8(cpu);
            try exec.writeRM8(cpu, @truncate(alu.neg(f, .b8, v)));
        },
        4 => { // MUL: AX = AL * r/m8
            const v: u64 = try exec.readRM8(cpu);
            const product = alu.mul(f, .b8, cpu.st.getReg8(0), v);
            cpu.st.setReg16(EAX, @truncate(product));
        },
        5 => { // IMUL: AX = AL * r/m8
            const v: u64 = try exec.readRM8(cpu);
            const product = alu.imul(f, .b8, cpu.st.getReg8(0), v);
            cpu.st.setReg16(EAX, @truncate(product));
        },
        6 => { // DIV: AL=AX/r/m8, AH=AX%r/m8
            const divisor: u64 = try exec.readRM8(cpu);
            const dividend: u64 = cpu.st.getReg16(EAX);
            const res = alu.divUnsigned(.b8, dividend, divisor) catch
                return cpu.raiseFault(interrupts.VEC_DE, .fault, null);
            cpu.st.setReg8(0, @truncate(res.q)); // AL
            cpu.st.setReg8(4, @truncate(res.r)); // AH
        },
        7 => { // IDIV
            const divisor: u64 = try exec.readRM8(cpu);
            const dividend: u64 = cpu.st.getReg16(EAX);
            const res = alu.divSigned(.b8, dividend, divisor) catch
                return cpu.raiseFault(interrupts.VEC_DE, .fault, null);
            cpu.st.setReg8(0, @truncate(res.q));
            cpu.st.setReg8(4, @truncate(res.r));
        },
    }
}

/// Grp3 v form (0xF7).
pub fn grp3v(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const f = &cpu.st.eflags;
    const w = exec.widthOf(cpu);
    switch (cpu.dec.reg) {
        0, 1 => {
            const a = try exec.readRMv(cpu);
            const imm = try dispatch.immByOpSize(cpu);
            alu.testOp(f, w, a, imm);
        },
        2 => {
            const v = try exec.readRMv(cpu);
            try exec.writeRMv(cpu, alu.notOp(w, v));
        },
        3 => {
            const v = try exec.readRMv(cpu);
            try exec.writeRMv(cpu, alu.neg(f, w, v));
        },
        4 => try mulv(cpu, false),
        5 => try mulv(cpu, true),
        6 => try divv(cpu, false),
        7 => try divv(cpu, true),
    }
}

fn mulv(cpu: anytype, signed: bool) !void {
    const f = &cpu.st.eflags;
    const w = exec.widthOf(cpu);
    const v = try exec.readRMv(cpu);
    const acc: u64 = if (w == .b32) cpu.st.getReg32(EAX) else cpu.st.getReg16(EAX);
    const product = if (signed) alu.imul(f, w, acc, v) else alu.mul(f, w, acc, v);
    if (w == .b32) {
        cpu.st.setReg32(EAX, @truncate(product));
        cpu.st.setReg32(EDX, @truncate(product >> 32));
    } else {
        cpu.st.setReg16(EAX, @truncate(product));
        cpu.st.setReg16(EDX, @truncate(product >> 16));
    }
}

fn divv(cpu: anytype, signed: bool) !void {
    const w = exec.widthOf(cpu);
    const divisor = try exec.readRMv(cpu);
    var dividend: u64 = undefined;
    if (w == .b32) {
        dividend = @as(u64, cpu.st.getReg32(EAX)) | (@as(u64, cpu.st.getReg32(EDX)) << 32);
    } else {
        dividend = @as(u64, cpu.st.getReg16(EAX)) | (@as(u64, cpu.st.getReg16(EDX)) << 16);
    }
    const res = (if (signed) alu.divSigned(w, dividend, divisor) else alu.divUnsigned(w, dividend, divisor)) catch
        return cpu.raiseFault(interrupts.VEC_DE, .fault, null);
    if (w == .b32) {
        cpu.st.setReg32(EAX, @truncate(res.q));
        cpu.st.setReg32(EDX, @truncate(res.r));
    } else {
        cpu.st.setReg16(EAX, @truncate(res.q));
        cpu.st.setReg16(EDX, @truncate(res.r));
    }
}

/// IMUL reg, r/m (0F AF): two-operand.
pub fn imul2(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const w = exec.widthOf(cpu);
    const a = exec.readRegv(cpu);
    const b = try exec.readRMv(cpu);
    const product = alu.imul(&cpu.st.eflags, w, a, b);
    exec.writeRegv(cpu, product);
}

/// IMUL reg, r/m, imm (0x69 imm, 0x6B imm8-sext): three-operand.
pub fn imul3(cpu: anytype, imm8: bool) !void {
    try dispatch.decodeModRM(cpu);
    const w = exec.widthOf(cpu);
    const b = try exec.readRMv(cpu);
    var imm: u64 = undefined;
    if (imm8) {
        const s: i8 = @bitCast(try dispatch.fetch8(cpu));
        imm = if (w == .b32) @as(u64, @as(u32, @bitCast(@as(i32, s)))) else @as(u64, @as(u16, @bitCast(@as(i16, s))));
    } else {
        imm = try dispatch.immByOpSize(cpu);
    }
    const product = alu.imul(&cpu.st.eflags, w, b, imm);
    exec.writeRegv(cpu, product);
}
