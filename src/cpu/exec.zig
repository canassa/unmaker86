//! The single big dispatch switch (D2) over the u12 key, plus operand
//! read/write helpers used by every execution body. Execution bodies are
//! organized by class in exec_*.zig and called from the switch arms.

const std = @import("std");
const state = @import("state.zig");
const decode = @import("decode.zig");
const dispatch = @import("dispatch.zig");
const interrupts = @import("interrupts.zig");
const alu = @import("alu.zig");
const Seg = state.Seg;
const Width = alu.Width;

const data = @import("exec_data.zig");
const exalu = @import("exec_alu.zig");
const shift = @import("exec_shift.zig");
const muldiv = @import("exec_muldiv.zig");
const bit = @import("exec_bit.zig");
const bcd = @import("exec_bcd.zig");
const ctrl = @import("exec_ctrl.zig");
const str = @import("exec_string.zig");
const io = @import("exec_io.zig");
const sys = @import("exec_system.zig");

/// Raise #UD (invalid opcode).
pub fn ud(cpu: anytype) !void {
    return cpu.raiseFault(interrupts.VEC_UD, .fault, 0);
}

/// Width of the operand for the current operand size.
pub inline fn widthOf(cpu: anytype) Width {
    return if (cpu.dec.op_size == .b32) Width.b32 else Width.b16;
}

// ---------------------------------------------------------------------------
// ModR/M operand read/write (after dispatch.decodeModRM).
// rm operand: register (mod 11) or memory (effective seg:off).
// ---------------------------------------------------------------------------

pub fn readRM8(cpu: anytype) !u8 {
    if (cpu.dec.kind == .reg) return cpu.st.getReg8(cpu.dec.rm);
    return cpu.segRead8(cpu.dec.mem_seg, cpu.dec.mem_off);
}
pub fn writeRM8(cpu: anytype, v: u8) !void {
    if (cpu.dec.kind == .reg) {
        cpu.st.setReg8(cpu.dec.rm, v);
    } else {
        try cpu.segWrite8(cpu.dec.mem_seg, cpu.dec.mem_off, v);
    }
}
pub fn readRM16(cpu: anytype) !u16 {
    if (cpu.dec.kind == .reg) return cpu.st.getReg16(cpu.dec.rm);
    return cpu.segRead16(cpu.dec.mem_seg, cpu.dec.mem_off);
}
pub fn writeRM16(cpu: anytype, v: u16) !void {
    if (cpu.dec.kind == .reg) {
        cpu.st.setReg16(cpu.dec.rm, v);
    } else {
        try cpu.segWrite16(cpu.dec.mem_seg, cpu.dec.mem_off, v);
    }
}
pub fn readRM32(cpu: anytype) !u32 {
    if (cpu.dec.kind == .reg) return cpu.st.getReg32(cpu.dec.rm);
    return cpu.segRead32(cpu.dec.mem_seg, cpu.dec.mem_off);
}
pub fn writeRM32(cpu: anytype, v: u32) !void {
    if (cpu.dec.kind == .reg) {
        cpu.st.setReg32(cpu.dec.rm, v);
    } else {
        try cpu.segWrite32(cpu.dec.mem_seg, cpu.dec.mem_off, v);
    }
}

/// Read the rm operand at the current operand size, returned as u64.
pub fn readRMv(cpu: anytype) !u64 {
    return switch (widthOf(cpu)) {
        .b16 => @as(u64, try readRM16(cpu)),
        .b32 => @as(u64, try readRM32(cpu)),
        else => unreachable,
    };
}
pub fn writeRMv(cpu: anytype, v: u64) !void {
    switch (widthOf(cpu)) {
        .b16 => try writeRM16(cpu, @truncate(v)),
        .b32 => try writeRM32(cpu, @truncate(v)),
        else => unreachable,
    }
}

/// reg-field operand access (the /r register).
pub fn readReg8(cpu: anytype) u8 {
    return cpu.st.getReg8(cpu.dec.reg);
}
pub fn writeReg8(cpu: anytype, v: u8) void {
    cpu.st.setReg8(cpu.dec.reg, v);
}
pub fn readRegv(cpu: anytype) u64 {
    return switch (widthOf(cpu)) {
        .b16 => @as(u64, cpu.st.getReg16(cpu.dec.reg)),
        .b32 => @as(u64, cpu.st.getReg32(cpu.dec.reg)),
        else => unreachable,
    };
}
pub fn writeRegv(cpu: anytype, v: u64) void {
    switch (widthOf(cpu)) {
        .b16 => cpu.st.setReg16(cpu.dec.reg, @truncate(v)),
        .b32 => cpu.st.setReg32(cpu.dec.reg, @truncate(v)),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// The dispatch switch. Key = (op32?0x200) | (0F?0x100) | opcode.
// Implemented incrementally per milestone; unmapped => #UD.
// ---------------------------------------------------------------------------

pub fn execute(cpu: anytype) !void {
    const op = cpu.dec.opcode;
    if (cpu.dec.is_0F) {
        return dispatch0F(cpu, op);
    }
    return dispatchOne(cpu, op);
}

fn dispatchOne(cpu: anytype, op: u8) !void {
    switch (op) {
        // ---- ALU r/m, reg / reg, r/m / AL/AX,imm (0x00-0x3D) ----
        0x00...0x05, 0x08...0x0D, 0x10...0x15, 0x18...0x1D, 0x20...0x25, 0x28...0x2D, 0x30...0x35, 0x38...0x3D => try exalu.aluPrimary(cpu, op),

        // ---- INC/DEC reg (0x40-0x4F) ----
        0x40...0x4F => try exalu.incDecReg(cpu, op),

        // ---- PUSH/POP reg (0x50-0x5F) ----
        0x50...0x57 => try data.pushReg(cpu, @truncate(op - 0x50)),
        0x58...0x5F => try data.popReg(cpu, @truncate(op - 0x58)),

        // ---- Grp1 0x80-0x83 ----
        0x80, 0x81, 0x82, 0x83 => try exalu.grp1(cpu, op),

        // ---- TEST / XCHG r/m,reg ----
        0x84 => try exalu.testRM8(cpu),
        0x85 => try exalu.testRMv(cpu),
        0x86 => try data.xchgRM8(cpu),
        0x87 => try data.xchgRMv(cpu),

        // ---- MOV ----
        0x88 => try data.movRM8FromReg(cpu),
        0x89 => try data.movRMvFromReg(cpu),
        0x8A => try data.movReg8FromRM(cpu),
        0x8B => try data.movRegvFromRM(cpu),
        0x8C => try data.movRMFromSeg(cpu),
        0x8D => try data.lea(cpu),
        0x8E => try data.movSegFromRM(cpu),

        0x90 => {}, // NOP (XCHG AX,AX)
        0x91...0x97 => try data.xchgAxReg(cpu, @truncate(op - 0x90)),

        // ---- PUSH/POP segment ----
        0x06 => try data.pushSeg(cpu, .es),
        0x07 => try data.popSeg(cpu, .es),
        0x0E => try data.pushSeg(cpu, .cs),
        0x16 => try data.pushSeg(cpu, .ss),
        0x17 => try data.popSeg(cpu, .ss),
        0x1E => try data.pushSeg(cpu, .ds),
        0x1F => try data.popSeg(cpu, .ds),

        // ---- BCD ----
        0x27 => try bcd.daa(cpu),
        0x2F => try bcd.das(cpu),
        0x37 => try bcd.aaa(cpu),
        0x3F => try bcd.aas(cpu),

        // ---- PUSHA / POPA ----
        0x60 => try data.pusha(cpu),
        0x61 => try data.popa(cpu),

        // ---- BOUND / ARPL / PUSH imm / IMUL imm / INS / OUTS ----
        0x62 => try ctrl.bound(cpu),
        0x63 => try ud(cpu), // ARPL: PM-only => #UD in real mode (PINNED)
        0x68 => try data.pushImmv(cpu),
        0x69 => try muldiv.imul3(cpu, false),
        0x6A => try data.pushImm8(cpu),
        0x6B => try muldiv.imul3(cpu, true),
        0x6C => try io.ins(cpu, true),
        0x6D => try io.ins(cpu, false),
        0x6E => try io.outs(cpu, true),
        0x6F => try io.outs(cpu, false),

        // ---- Jcc rel8 ----
        0x70...0x7F => try ctrl.jccRel8(cpu, @truncate(op - 0x70)),

        // ---- POP r/m (0x8F) ----
        0x8F => try data.popRM(cpu),

        // ---- CBW/CWDE, CWD/CDQ, far CALL, WAIT, PUSHF/POPF, SAHF/LAHF ----
        0x98 => ctrl.cbw_cwde(cpu),
        0x99 => ctrl.cwd_cdq(cpu),
        0x9A => try ctrl.farCallDirect(cpu),
        0x9B => {}, // WAIT/FWAIT: no FPU; charges base cost only (BaK no FPU)
        0x9C => try data.pushf(cpu),
        0x9D => try data.popf(cpu),
        0x9E => ctrl.sahf(cpu),
        0x9F => ctrl.lahf(cpu),

        // ---- MOV moffs ----
        0xA0 => try data.movAlMoffs(cpu),
        0xA1 => try data.movAxMoffs(cpu),
        0xA2 => try data.movMoffsAl(cpu),
        0xA3 => try data.movMoffsAx(cpu),

        // ---- String ops ----
        0xA4 => try str.movsb(cpu),
        0xA5 => try str.movsv(cpu),
        0xA6 => try str.cmpsb(cpu),
        0xA7 => try str.cmpsv(cpu),
        0xA8 => { // TEST AL, imm8
            const a: u64 = cpu.st.getReg8(0);
            const imm: u64 = try dispatch.fetch8(cpu);
            alu.testOp(&cpu.st.eflags, .b8, a, imm);
        },
        0xA9 => { // TEST AX/EAX, imm
            const w = widthOf(cpu);
            const a = if (w == .b32) @as(u64, cpu.st.getReg32(0)) else @as(u64, cpu.st.getReg16(0));
            const imm = try dispatch.immByOpSize(cpu);
            alu.testOp(&cpu.st.eflags, w, a, imm);
        },
        0xAA => try str.stosb(cpu),
        0xAB => try str.stosv(cpu),
        0xAC => try str.lodsb(cpu),
        0xAD => try str.lodsv(cpu),
        0xAE => try str.scasb(cpu),
        0xAF => try str.scasv(cpu),

        // ---- MOV reg, imm ----
        0xB0...0xB7 => try data.movReg8Imm(cpu, @truncate(op - 0xB0)),
        0xB8...0xBF => try data.movRegvImm(cpu, @truncate(op - 0xB8)),

        // ---- Grp2 shifts (imm8) ----
        0xC0, 0xC1 => try shift.grp2(cpu, op),

        // ---- RET near ----
        0xC2 => try ctrl.retNear(cpu, try dispatch.fetch16(cpu)),
        0xC3 => try ctrl.retNear(cpu, null),

        // ---- LES / LDS ----
        0xC4 => try data.loadFarPtr(cpu, .es),
        0xC5 => try data.loadFarPtr(cpu, .ds),

        // ---- MOV r/m, imm (Grp11 C6/C7) ----
        0xC6 => try data.movRM8Imm(cpu),
        0xC7 => try data.movRMvImm(cpu),

        // ---- ENTER / LEAVE ----
        0xC8 => try data.enter(cpu),
        0xC9 => try data.leave(cpu),

        // ---- RET far / INT / IRET ----
        0xCA => try ctrl.retFar(cpu, try dispatch.fetch16(cpu)),
        0xCB => try ctrl.retFar(cpu, null),
        0xCC => try ctrl.int3(cpu),
        0xCD => try ctrl.intN(cpu),
        0xCE => try ctrl.into(cpu),
        0xCF => try ctrl.iret(cpu),

        // ---- Grp2 shifts (1 / CL) ----
        0xD0, 0xD1, 0xD2, 0xD3 => try shift.grp2(cpu, op),

        // ---- AAM / AAD / SALC / XLAT ----
        0xD4 => try bcd.aam(cpu),
        0xD5 => try bcd.aad(cpu),
        0xD6 => ctrl.salc(cpu), // undocumented-but-valid 386 SALC
        0xD7 => try ctrl.xlat(cpu),

        // ---- ESC (0xD8-0xDF): FPU. CR0.EM/TS hooks raise #NM (Phase 4j) ----
        0xD8...0xDF => try escFpu(cpu),

        // ---- LOOP / JCXZ ----
        0xE0 => try ctrl.loop(cpu, .loopne),
        0xE1 => try ctrl.loop(cpu, .loope),
        0xE2 => try ctrl.loop(cpu, .loop),
        0xE3 => try ctrl.loop(cpu, .jcxz),

        // ---- IN/OUT imm8 ----
        0xE4 => try io.inAlImm(cpu),
        0xE5 => try io.inAxImm(cpu),
        0xE6 => try io.outImmAl(cpu),
        0xE7 => try io.outImmAx(cpu),

        // ---- CALL/JMP rel, far JMP, JMP rel8 ----
        0xE8 => try ctrl.callRelv(cpu),
        0xE9 => try ctrl.jmpRelv(cpu),
        0xEA => try ctrl.farJmpDirect(cpu),
        0xEB => try ctrl.jmpRel8(cpu),

        // ---- IN/OUT DX ----
        0xEC => try io.inAlDx(cpu),
        0xED => try io.inAxDx(cpu),
        0xEE => try io.outDxAl(cpu),
        0xEF => try io.outDxAx(cpu),

        // ---- ICEBP / HLT / CMC / Grp3 / flag ops / Grp4/Grp5 ----
        0xF1 => try ctrl.icebp(cpu), // ICEBP/INT1 (386-valid)
        0xF4 => ctrl.hlt(cpu),
        0xF5 => ctrl.cmc(cpu),
        0xF6 => try muldiv.grp3b(cpu),
        0xF7 => try muldiv.grp3v(cpu),
        0xF8 => ctrl.clc(cpu),
        0xF9 => ctrl.stc(cpu),
        0xFA => ctrl.cli(cpu),
        0xFB => ctrl.sti(cpu),
        0xFC => ctrl.cld(cpu),
        0xFD => ctrl.std_(cpu),
        0xFE => try ctrl.grp4(cpu),
        0xFF => try ctrl.grp5(cpu),

        else => try ud(cpu),
    }
}

fn escFpu(cpu: anytype) !void {
    // Decode the ModR/M so the instruction length is consumed correctly.
    try dispatch.decodeModRM(cpu);
    // CR0.EM=1 => any ESC raises #NM; CR0.TS=1 => #NM as well.
    if ((cpu.st.cr0 & 0x4) != 0 or (cpu.st.cr0 & 0x8) != 0) {
        return cpu.raiseFault(interrupts.VEC_NM, .fault, null);
    }
    // EM=0/TS=0: a real 387 would execute. No FPU in scope (BaK does not use
    // it): raise #NM as the FPU-extension seam (flagged deferral, not a fake).
    return cpu.raiseFault(interrupts.VEC_NM, .fault, null);
}

fn dispatch0F(cpu: anytype, op: u8) !void {
    switch (op) {
        0x00 => try ud(cpu), // Grp6 (LLDT/LTR/SLDT/STR/LAR/LSL): PM-only => #UD in real mode
        0x01 => try sys.grp7(cpu), // Grp7 (LGDT/LIDT/SGDT/SIDT/SMSW/LMSW)
        0x02, 0x03 => try ud(cpu), // LAR/LSL: PM-only => #UD
        0x06 => try sys.clts(cpu), // CLTS
        0x08, 0x09 => try ud(cpu), // INVD/WBINVD: 486+ => #UD
        0x20 => try sys.movFromCr(cpu),
        0x21 => try sys.movFromDr(cpu),
        0x22 => try sys.movToCr(cpu),
        0x23 => try sys.movToDr(cpu),

        // ---- Jcc rel16/rel32 ----
        0x80...0x8F => try ctrl.jccRelv(cpu, @truncate(op - 0x80)),
        // ---- SETcc r/m8 ----
        0x90...0x9F => try ctrl.setcc(cpu, @truncate(op - 0x90)),

        0xA0 => try data.pushSeg(cpu, .fs),
        0xA1 => try data.popSeg(cpu, .fs),
        0xA3 => try bit.btReg(cpu, .bt),
        0xA4 => try shift.shld_shrd(cpu, 0xA4),
        0xA5 => try shift.shld_shrd(cpu, 0xA5),
        0xA8 => try data.pushSeg(cpu, .gs),
        0xA9 => try data.popSeg(cpu, .gs),
        0xAB => try bit.btReg(cpu, .bts),
        0xAC => try shift.shld_shrd(cpu, 0xAC),
        0xAD => try shift.shld_shrd(cpu, 0xAD),
        0xAF => try muldiv.imul2(cpu),

        0xB2 => try data.loadFarPtr(cpu, .ss), // LSS
        0xB3 => try bit.btReg(cpu, .btr),
        0xB4 => try data.loadFarPtr(cpu, .fs), // LFS
        0xB5 => try data.loadFarPtr(cpu, .gs), // LGS
        0xB6 => try ctrl.movzx(cpu, true),
        0xB7 => try ctrl.movzx(cpu, false),
        0xBA => try bit.grp8(cpu),
        0xBB => try bit.btReg(cpu, .btc),
        0xBC => try bit.bsf_bsr(cpu, false),
        0xBD => try bit.bsf_bsr(cpu, true),
        0xBE => try ctrl.movsx(cpu, true),
        0xBF => try ctrl.movsx(cpu, false),

        // ---- 486+/Pentium+ opcodes => #UD on 386 (honest gating) ----
        // BSWAP (C8-CF), CMPXCHG (B0/B1), XADD (C0/C1), CPUID (A2),
        // RDTSC (31), RSM (AA), INVLPG (01/7 handled in grp7) all #UD here.
        else => try ud(cpu),
    }
}

test {
    std.testing.refAllDecls(@This());
}
