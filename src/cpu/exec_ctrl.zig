//! Control flow + flag/misc + sign-extension + INT/IRET (Phases 4f/4h).
//! Condition codes read the packed Flags fields directly (Theme G).

const std = @import("std");
const state = @import("state.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const interrupts = @import("interrupts.zig");
const data = @import("exec_data.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
const ESP = @intFromEnum(Reg32.esp);
const ECX = @intFromEnum(Reg32.ecx);

// ---- Condition-code evaluation (cc 0..15), reading packed fields directly ----
pub fn cond(cpu: anytype, cc: u4) bool {
    const f = cpu.st.eflags;
    return switch (cc) {
        0x0 => f.of, // O
        0x1 => !f.of, // NO
        0x2 => f.cf, // B/C/NAE
        0x3 => !f.cf, // AE/NB/NC
        0x4 => f.zf, // E/Z
        0x5 => !f.zf, // NE/NZ
        0x6 => f.cf or f.zf, // BE/NA
        0x7 => !(f.cf or f.zf), // A/NBE
        0x8 => f.sf, // S
        0x9 => !f.sf, // NS
        0xA => f.pf, // P/PE
        0xB => !f.pf, // NP/PO
        0xC => f.sf != f.of, // L/NGE
        0xD => f.sf == f.of, // GE/NL
        0xE => f.zf or (f.sf != f.of), // LE/NG
        0xF => !f.zf and (f.sf == f.of), // G/NLE
    };
}

// ---- Relative jumps ----
fn ipMask(cpu: anytype) u32 {
    return if (cpu.dec.op_size == .b32) 0xFFFFFFFF else 0xFFFF;
}

pub fn jccRel8(cpu: anytype, cc: u4) !void {
    const rel: i8 = @bitCast(try dispatch.fetch8(cpu));
    if (cond(cpu, cc)) {
        cpu.st.eip = (cpu.st.eip +% @as(u32, @bitCast(@as(i32, rel)))) & ipMask(cpu);
    }
}

pub fn jccRelv(cpu: anytype, cc: u4) !void {
    const rel = try relByOpSize(cpu);
    if (cond(cpu, cc)) {
        cpu.st.eip = (cpu.st.eip +% rel) & ipMask(cpu);
    }
}

fn relByOpSize(cpu: anytype) !u32 {
    if (cpu.dec.op_size == .b32) {
        return try dispatch.fetch32(cpu);
    }
    const r: i16 = @bitCast(try dispatch.fetch16(cpu));
    return @bitCast(@as(i32, r));
}

pub fn jmpRel8(cpu: anytype) !void {
    const rel: i8 = @bitCast(try dispatch.fetch8(cpu));
    cpu.st.eip = (cpu.st.eip +% @as(u32, @bitCast(@as(i32, rel)))) & ipMask(cpu);
}
pub fn jmpRelv(cpu: anytype) !void {
    const rel = try relByOpSize(cpu);
    cpu.st.eip = (cpu.st.eip +% rel) & ipMask(cpu);
}

pub fn callRelv(cpu: anytype) !void {
    const rel = try relByOpSize(cpu);
    // Push return address (current EIP after operand fetch).
    try pushIp(cpu, cpu.st.eip);
    cpu.st.eip = (cpu.st.eip +% rel) & ipMask(cpu);
}

fn pushIp(cpu: anytype, ip: u32) !void {
    if (cpu.dec.op_size == .b32) {
        try data.push32(cpu, ip);
    } else {
        try interrupts.pushWord(cpu, @truncate(ip));
    }
}
/// Push a segment selector for a far transfer: a full 32-bit slot (selector
/// zero-extended) for a 32-bit operand size, else a single word.
fn pushSegSlot(cpu: anytype, sel: u16) !void {
    if (cpu.dec.op_size == .b32) {
        try data.push32(cpu, sel);
    } else {
        try interrupts.pushWord(cpu, sel);
    }
}
fn popIp(cpu: anytype) !u32 {
    if (cpu.dec.op_size == .b32) {
        return data.pop32(cpu);
    }
    return @as(u32, try interrupts.popWord(cpu));
}
/// Pop a segment-selector slot off the stack. For a 32-bit far transfer the
/// selector occupies a full 32-bit stack slot (only the low 16 bits are used);
/// for a 16-bit transfer it is a single word. Returns the selector.
fn popSegSlot(cpu: anytype) !u16 {
    if (cpu.dec.op_size == .b32) {
        return @truncate(try data.pop32(cpu));
    }
    return interrupts.popWord(cpu);
}

pub fn retNear(cpu: anytype, imm16: ?u16) !void {
    var ip = try popIp(cpu);
    ip &= ipMask(cpu);
    if (imm16) |n| {
        cpu.st.setReg16(ESP, cpu.st.getReg16(ESP) +% n);
    }
    cpu.st.eip = ip;
}

// ---- SETcc r/m8 ----
pub fn setcc(cpu: anytype, cc: u4) !void {
    try dispatch.decodeModRM(cpu);
    try exec.writeRM8(cpu, if (cond(cpu, cc)) 1 else 0);
}

// ---- LOOP / JCXZ ----
pub fn loop(cpu: anytype, kind: enum { loop, loope, loopne, jcxz }) !void {
    const rel: i8 = @bitCast(try dispatch.fetch8(cpu));
    const a32 = cpu.dec.addr_size == .a32;
    const target = (cpu.st.eip +% @as(u32, @bitCast(@as(i32, rel)))) & ipMask(cpu);

    if (kind == .jcxz) {
        const c = if (a32) cpu.st.getReg32(ECX) else @as(u32, cpu.st.getReg16(ECX));
        if (c == 0) cpu.st.eip = target;
        return;
    }

    var c: u32 = if (a32) cpu.st.getReg32(ECX) else @as(u32, cpu.st.getReg16(ECX));
    c -%= 1;
    if (a32) cpu.st.setReg32(ECX, c) else cpu.st.setReg16(ECX, @truncate(c));
    const counter_ok = (if (a32) c else (c & 0xFFFF)) != 0;
    const take = switch (kind) {
        .loop => counter_ok,
        .loope => counter_ok and cpu.st.eflags.zf,
        .loopne => counter_ok and !cpu.st.eflags.zf,
        .jcxz => unreachable,
    };
    if (take) cpu.st.eip = target;
}

// ---- Grp5 (0xFF): INC/DEC r/m, CALL/JMP near/far, PUSH r/m ----
pub fn grp5(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const alu = @import("alu.zig");
    const w = exec.widthOf(cpu);
    switch (cpu.dec.reg) {
        0 => { // INC
            const v = try exec.readRMv(cpu);
            try exec.writeRMv(cpu, alu.inc(&cpu.st.eflags, w, v));
        },
        1 => { // DEC
            const v = try exec.readRMv(cpu);
            try exec.writeRMv(cpu, alu.dec(&cpu.st.eflags, w, v));
        },
        2 => { // CALL near indirect
            const target: u32 = @as(u32, @truncate(try exec.readRMv(cpu))) & ipMask(cpu);
            try pushIp(cpu, cpu.st.eip);
            cpu.st.eip = target;
        },
        3 => try farCallIndirect(cpu), // CALL far
        4 => { // JMP near indirect
            cpu.st.eip = @as(u32, @truncate(try exec.readRMv(cpu))) & ipMask(cpu);
        },
        5 => try farJmpIndirect(cpu), // JMP far
        6 => { // PUSH r/m
            const v = try exec.readRMv(cpu);
            if (cpu.dec.op_size == .b32) try data.push32(cpu, @truncate(v)) else try interrupts.pushWord(cpu, @truncate(v));
        },
        7 => try exec.ud(cpu),
    }
}

// ---- Grp4 (0xFE): INC/DEC r/m8 ----
pub fn grp4(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const alu = @import("alu.zig");
    switch (cpu.dec.reg) {
        0 => {
            const v: u64 = try exec.readRM8(cpu);
            try exec.writeRM8(cpu, @truncate(alu.inc(&cpu.st.eflags, .b8, v)));
        },
        1 => {
            const v: u64 = try exec.readRM8(cpu);
            try exec.writeRM8(cpu, @truncate(alu.dec(&cpu.st.eflags, .b8, v)));
        },
        else => try exec.ud(cpu),
    }
}

// ---- Far transfers (real mode: simple CS:IP load + limit check) ----
pub fn farJmpDirect(cpu: anytype) !void {
    // ptr16:16 or ptr16:32 immediate.
    const new_ip = try dispatch.immByOpSize(cpu);
    const new_cs = try dispatch.fetch16(cpu);
    cpu.loadSegment(.cs, new_cs);
    cpu.st.eip = new_ip & ipMask(cpu);
}
pub fn farCallDirect(cpu: anytype) !void {
    const new_ip = try dispatch.immByOpSize(cpu);
    const new_cs = try dispatch.fetch16(cpu);
    try pushSegSlot(cpu, cpu.st.selector[@intFromEnum(Seg.cs)]);
    try pushIp(cpu, cpu.st.eip);
    cpu.loadSegment(.cs, new_cs);
    cpu.st.eip = new_ip & ipMask(cpu);
}
fn farJmpIndirect(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    const off = cpu.dec.mem_off;
    const seg = cpu.dec.mem_seg;
    const new_ip = if (cpu.dec.op_size == .b32) try cpu.segRead32(seg, off) else @as(u32, try cpu.segRead16(seg, off));
    const cs_off = off +% (if (cpu.dec.op_size == .b32) @as(u32, 4) else 2);
    const new_cs = try cpu.segRead16(seg, cs_off);
    cpu.loadSegment(.cs, new_cs);
    cpu.st.eip = new_ip & ipMask(cpu);
}
fn farCallIndirect(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    const off = cpu.dec.mem_off;
    const seg = cpu.dec.mem_seg;
    const new_ip = if (cpu.dec.op_size == .b32) try cpu.segRead32(seg, off) else @as(u32, try cpu.segRead16(seg, off));
    const cs_off = off +% (if (cpu.dec.op_size == .b32) @as(u32, 4) else 2);
    const new_cs = try cpu.segRead16(seg, cs_off);
    try pushSegSlot(cpu, cpu.st.selector[@intFromEnum(Seg.cs)]);
    try pushIp(cpu, cpu.st.eip);
    cpu.loadSegment(.cs, new_cs);
    cpu.st.eip = new_ip & ipMask(cpu);
}
pub fn retFar(cpu: anytype, imm16: ?u16) !void {
    const ip = try popIp(cpu);
    const cs = try popSegSlot(cpu);
    cpu.loadSegment(.cs, cs);
    cpu.st.eip = ip & ipMask(cpu);
    if (imm16) |n| cpu.st.setReg16(ESP, cpu.st.getReg16(ESP) +% n);
}

// ---- INT/INT3/INTO/IRET ----
pub fn intN(cpu: anytype) !void {
    const vec = try dispatch.fetch8(cpu);
    return interrupts.deliverViaIvt(cpu, vec);
}
pub fn int3(cpu: anytype) !void {
    return interrupts.deliverViaIvt(cpu, interrupts.VEC_BP);
}
pub fn into(cpu: anytype) !void {
    if (cpu.st.eflags.of) return interrupts.deliverViaIvt(cpu, interrupts.VEC_OF);
}
pub fn icebp(cpu: anytype) !void {
    // 0xF1 ICEBP/INT1: single-byte vector-1 trap.
    return interrupts.deliverViaIvt(cpu, interrupts.VEC_DB);
}
pub fn iret(cpu: anytype) !void {
    const ip = try popIp(cpu);
    const cs = try popSegSlot(cpu);
    const new_flags: u32 = if (cpu.dec.op_size == .b32) try data.pop32(cpu) else @as(u32, try interrupts.popWord(cpu));
    cpu.loadSegment(.cs, cs);
    cpu.st.eip = ip & ipMask(cpu);
    // Real mode: write all writable flag bits.
    const cur = cpu.st.eflags.toU32();
    const mask: u32 = if (cpu.dec.op_size == .b32) 0x0027_FFFF else 0x0000_FFFF;
    cpu.st.eflags = @import("flags.zig").Flags.fromU32((cur & ~mask) | (new_flags & mask));
    // Clear NMI-in-service on IRET.
    cpu.st.nmi_in_service = false;
}

// ---- Flag ops ----
pub fn clc(cpu: anytype) void {
    cpu.st.eflags.cf = false;
}
pub fn stc(cpu: anytype) void {
    cpu.st.eflags.cf = true;
}
pub fn cmc(cpu: anytype) void {
    cpu.st.eflags.cf = !cpu.st.eflags.cf;
}
pub fn cld(cpu: anytype) void {
    cpu.st.eflags.df = false;
}
pub fn std_(cpu: anytype) void {
    cpu.st.eflags.df = true;
}
pub fn cli(cpu: anytype) void {
    cpu.st.eflags.iff = false;
}
pub fn sti(cpu: anytype) void {
    cpu.st.eflags.iff = true;
    cpu.st.inhibit_irq_one_instruction = true; // one-instruction shadow
}
pub fn sahf(cpu: anytype) void {
    const ah = cpu.st.getReg8(4);
    const cur = cpu.st.eflags.toU32();
    // SAHF loads SF,ZF,AF,PF,CF from AH (low byte format).
    const new = (cur & 0xFFFFFF00) | (@as(u32, ah) & 0xD5) | 0x02;
    cpu.st.eflags = @import("flags.zig").Flags.fromU32(new);
}
pub fn lahf(cpu: anytype) void {
    const low: u8 = @truncate(cpu.st.eflags.toU32() & 0xD5 | 0x02);
    cpu.st.setReg8(4, low);
}
pub fn salc(cpu: anytype) void {
    cpu.st.setReg8(0, if (cpu.st.eflags.cf) 0xFF else 0x00);
}

// ---- Sign/zero extension ----
pub fn movzx(cpu: anytype, byte_src: bool) !void {
    try dispatch.decodeModRM(cpu);
    if (byte_src) {
        const v: u64 = try exec.readRM8(cpu);
        exec.writeRegv(cpu, v);
    } else {
        const v: u64 = try exec.readRM16(cpu);
        exec.writeRegv(cpu, v);
    }
}
pub fn movsx(cpu: anytype, byte_src: bool) !void {
    try dispatch.decodeModRM(cpu);
    if (byte_src) {
        const v: i8 = @bitCast(try exec.readRM8(cpu));
        exec.writeRegv(cpu, @as(u32, @bitCast(@as(i32, v))));
    } else {
        const v: i16 = @bitCast(try exec.readRM16(cpu));
        exec.writeRegv(cpu, @as(u32, @bitCast(@as(i32, v))));
    }
}

pub fn cbw_cwde(cpu: anytype) void {
    if (cpu.dec.op_size == .b32) {
        // CWDE: sign-extend AX into EAX
        const ax_: i16 = @bitCast(cpu.st.getReg16(0));
        cpu.st.setReg32(0, @bitCast(@as(i32, ax_)));
    } else {
        // CBW: sign-extend AL into AX
        const al_: i8 = @bitCast(cpu.st.getReg8(0));
        cpu.st.setReg16(0, @bitCast(@as(i16, al_)));
    }
}
pub fn cwd_cdq(cpu: anytype) void {
    const EDX = @intFromEnum(Reg32.edx);
    if (cpu.dec.op_size == .b32) {
        // CDQ: sign of EAX into EDX
        cpu.st.setReg32(EDX, if ((cpu.st.getReg32(0) & 0x80000000) != 0) 0xFFFFFFFF else 0);
    } else {
        cpu.st.setReg16(EDX, if ((cpu.st.getReg16(0) & 0x8000) != 0) 0xFFFF else 0);
    }
}

// ---- XLAT ----
pub fn xlat(cpu: anytype) !void {
    const EBX = @intFromEnum(Reg32.ebx);
    const seg = cpu.dec.seg_override orelse Seg.ds;
    const base = if (cpu.dec.addr_size == .a32) cpu.st.getReg32(EBX) else @as(u32, cpu.st.getReg16(EBX));
    const off = base +% cpu.st.getReg8(0);
    cpu.st.setReg8(0, try cpu.segRead8(seg, off));
}

// ---- BOUND ----
pub fn bound(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    const idx = exec.readRegv(cpu);
    if (cpu.dec.op_size == .b32) {
        const lo: i32 = @bitCast(try cpu.segRead32(cpu.dec.mem_seg, cpu.dec.mem_off));
        const hi: i32 = @bitCast(try cpu.segRead32(cpu.dec.mem_seg, cpu.dec.mem_off +% 4));
        const v: i32 = @bitCast(@as(u32, @truncate(idx)));
        if (v < lo or v > hi) return cpu.raiseFault(interrupts.VEC_BR, .fault, null);
    } else {
        const lo: i16 = @bitCast(try cpu.segRead16(cpu.dec.mem_seg, cpu.dec.mem_off));
        const hi: i16 = @bitCast(try cpu.segRead16(cpu.dec.mem_seg, cpu.dec.mem_off +% 2));
        const v: i16 = @bitCast(@as(u16, @truncate(idx)));
        if (v < lo or v > hi) return cpu.raiseFault(interrupts.VEC_BR, .fault, null);
    }
}

// ---- HLT ----
pub fn hlt(cpu: anytype) void {
    cpu.st.halted = true;
}
