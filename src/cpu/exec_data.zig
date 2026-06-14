//! Data movement & stack execution (Phase 4a). No ALU flags (except where the
//! instruction defines them). Plumbing only.

const std = @import("std");
const state = @import("state.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const interrupts = @import("interrupts.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
const ESP = @intFromEnum(Reg32.esp);

// ---- MOV r/m,reg and reg,r/m ----
pub fn movRM8FromReg(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    try exec.writeRM8(cpu, exec.readReg8(cpu));
}
pub fn movRMvFromReg(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    try exec.writeRMv(cpu, exec.readRegv(cpu));
}
pub fn movReg8FromRM(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    exec.writeReg8(cpu, try exec.readRM8(cpu));
}
pub fn movRegvFromRM(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    exec.writeRegv(cpu, try exec.readRMv(cpu));
}

// ---- MOV with segment registers (8C/8E). reg field selects ES,CS,SS,DS,FS,GS. ----
fn segFromReg(reg: u3) ?Seg {
    return switch (reg) {
        0 => .es,
        1 => .cs,
        2 => .ss,
        3 => .ds,
        4 => .fs,
        5 => .gs,
        else => null,
    };
}

pub fn movRMFromSeg(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const seg = segFromReg(cpu.dec.reg) orelse return exec.ud(cpu);
    const v = cpu.st.selector[@intFromEnum(seg)];
    // Destination is r/m16 (or zero-extended to r/m32 in reg form). Real form
    // stores 16-bit selector value.
    if (cpu.dec.kind == .reg) {
        if (cpu.dec.op_size == .b32) cpu.st.setReg32(cpu.dec.rm, v) else cpu.st.setReg16(cpu.dec.rm, v);
    } else {
        try cpu.segWrite16(cpu.dec.mem_seg, cpu.dec.mem_off, v);
    }
}

pub fn movSegFromRM(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const seg = segFromReg(cpu.dec.reg) orelse return exec.ud(cpu);
    if (seg == .cs) return exec.ud(cpu); // MOV CS, r/m is #UD
    const v = try exec.readRM16(cpu);
    cpu.loadSegment(seg, v);
    // MOV SS / POP SS arm the one-instruction interrupt shadow.
    if (seg == .ss) cpu.st.inhibit_irq_one_instruction = true;
}

// ---- LEA ----
pub fn lea(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    if (cpu.dec.kind == .reg) return exec.ud(cpu); // LEA needs a memory operand
    const off = cpu.dec.mem_off;
    // Destination size = operand size; address size already folded into mem_off.
    if (cpu.dec.op_size == .b32) {
        cpu.st.setReg32(cpu.dec.reg, off);
    } else {
        cpu.st.setReg16(cpu.dec.reg, @truncate(off));
    }
}

// ---- MOV reg, imm ----
pub fn movReg8Imm(cpu: anytype, idx: u3) !void {
    cpu.st.setReg8(idx, try dispatch.fetch8(cpu));
}
pub fn movRegvImm(cpu: anytype, idx: u3) !void {
    const v = try dispatch.immByOpSize(cpu);
    if (cpu.dec.op_size == .b32) cpu.st.setReg32(idx, v) else cpu.st.setReg16(idx, @truncate(v));
}

// ---- MOV r/m, imm (Grp11) ----
pub fn movRM8Imm(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const v = try dispatch.fetch8(cpu);
    try exec.writeRM8(cpu, v);
}
pub fn movRMvImm(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const v = try dispatch.immByOpSize(cpu);
    try exec.writeRMv(cpu, v);
}

// ---- MOV AL/AX/EAX <-> moffs (direct address; uses addr size for offset) ----
fn moffs(cpu: anytype) !u32 {
    return switch (cpu.dec.addr_size) {
        .a16 => @as(u32, try dispatch.fetch16(cpu)),
        .a32 => try dispatch.fetch32(cpu),
    };
}
fn moffsSeg(cpu: anytype) Seg {
    return cpu.dec.seg_override orelse .ds;
}
pub fn movAlMoffs(cpu: anytype) !void {
    const off = try moffs(cpu);
    cpu.st.setReg8(0, try cpu.segRead8(moffsSeg(cpu), off));
}
pub fn movAxMoffs(cpu: anytype) !void {
    const off = try moffs(cpu);
    if (cpu.dec.op_size == .b32) {
        cpu.st.setReg32(0, try cpu.segRead32(moffsSeg(cpu), off));
    } else {
        cpu.st.setReg16(0, try cpu.segRead16(moffsSeg(cpu), off));
    }
}
pub fn movMoffsAl(cpu: anytype) !void {
    const off = try moffs(cpu);
    try cpu.segWrite8(moffsSeg(cpu), off, cpu.st.getReg8(0));
}
pub fn movMoffsAx(cpu: anytype) !void {
    const off = try moffs(cpu);
    if (cpu.dec.op_size == .b32) {
        try cpu.segWrite32(moffsSeg(cpu), off, cpu.st.getReg32(0));
    } else {
        try cpu.segWrite16(moffsSeg(cpu), off, cpu.st.getReg16(0));
    }
}

// ---- XCHG ----
pub fn xchgRM8(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const a = try exec.readRM8(cpu);
    const b = exec.readReg8(cpu);
    try exec.writeRM8(cpu, b);
    exec.writeReg8(cpu, a);
}
pub fn xchgRMv(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const a = try exec.readRMv(cpu);
    const b = exec.readRegv(cpu);
    try exec.writeRMv(cpu, b);
    exec.writeRegv(cpu, a);
}
pub fn xchgAxReg(cpu: anytype, idx: u3) !void {
    if (cpu.dec.op_size == .b32) {
        const a = cpu.st.getReg32(0);
        cpu.st.setReg32(0, cpu.st.getReg32(idx));
        cpu.st.setReg32(idx, a);
    } else {
        const a = cpu.st.getReg16(0);
        cpu.st.setReg16(0, cpu.st.getReg16(idx));
        cpu.st.setReg16(idx, a);
    }
}

// ---- PUSH / POP reg ----
pub fn pushReg(cpu: anytype, idx: u3) !void {
    if (cpu.dec.op_size == .b32) {
        try push32(cpu, cpu.st.getReg32(idx));
    } else {
        try interrupts.pushWord(cpu, cpu.st.getReg16(idx));
    }
}
pub fn popReg(cpu: anytype, idx: u3) !void {
    if (cpu.dec.op_size == .b32) {
        cpu.st.setReg32(idx, try pop32(cpu));
    } else {
        cpu.st.setReg16(idx, try interrupts.popWord(cpu));
    }
}

/// 32-bit push (operand-size 32; real-mode stack pointer is SP, 16-bit width).
pub fn push32(cpu: anytype, v: u32) !void {
    const sp = cpu.st.getReg16(ESP);
    const new_sp = sp -% 4;
    try cpu.segWrite32(.ss, new_sp, v);
    cpu.st.setReg16(ESP, new_sp);
}
pub fn pop32(cpu: anytype) !u32 {
    const sp = cpu.st.getReg16(ESP);
    const v = try cpu.segRead32(.ss, sp);
    cpu.st.setReg16(ESP, sp +% 4);
    return v;
}

// ---- PUSH imm ----
pub fn pushImm8(cpu: anytype) !void {
    const s: i8 = @bitCast(try dispatch.fetch8(cpu));
    if (cpu.dec.op_size == .b32) {
        try push32(cpu, @bitCast(@as(i32, s)));
    } else {
        try interrupts.pushWord(cpu, @bitCast(@as(i16, s)));
    }
}
pub fn pushImmv(cpu: anytype) !void {
    const v = try dispatch.immByOpSize(cpu);
    if (cpu.dec.op_size == .b32) try push32(cpu, v) else try interrupts.pushWord(cpu, @truncate(v));
}

// ---- PUSH/POP segment register ----
pub fn pushSeg(cpu: anytype, seg: Seg) !void {
    if (cpu.dec.op_size == .b32) {
        try push32(cpu, cpu.st.selector[@intFromEnum(seg)]);
    } else {
        try interrupts.pushWord(cpu, cpu.st.selector[@intFromEnum(seg)]);
    }
}
pub fn popSeg(cpu: anytype, seg: Seg) !void {
    const v: u16 = if (cpu.dec.op_size == .b32) @truncate(try pop32(cpu)) else try interrupts.popWord(cpu);
    cpu.loadSegment(seg, v);
    if (seg == .ss) cpu.st.inhibit_irq_one_instruction = true;
}

// ---- PUSHF / POPF ----
pub fn pushf(cpu: anytype) !void {
    const flags = @import("flags.zig");
    const v = cpu.st.eflags.toU32();
    if (cpu.dec.op_size == .b32) {
        try push32(cpu, v & 0x00FCFFFF); // RF & VM masked out of pushed value
    } else {
        try interrupts.pushWord(cpu, @truncate(v));
    }
    _ = flags;
}
pub fn popf(cpu: anytype) !void {
    const flags = @import("flags.zig");
    const cur = cpu.st.eflags.toU32();
    if (cpu.dec.op_size == .b32) {
        const v = try pop32(cpu);
        const mask: u32 = 0x0027_4DD5 | 0x0000_0700; // arithmetic+TF/IF/DF+IOPL/NT
        cpu.st.eflags = flags.Flags.fromU32((cur & ~mask) | (v & mask));
    } else {
        const v: u32 = try interrupts.popWord(cpu);
        const mask: u32 = 0x0000_FFFF & ~@as(u32, 0); // low 16 (real mode CPL=0)
        cpu.st.eflags = flags.Flags.fromU32((cur & 0xFFFF0000) | (v & mask));
    }
}

// ---- PUSHA / POPA ----
// Fault-restart atomicity (Theme F, pattern (a) pre-flight): probe the whole
// stack range for a limit/wrap fault BEFORE any write, so a fault leaves SP and
// all registers unchanged (restartable). On fault, restore SP.
pub fn pusha(cpu: anytype) !void {
    const sp_orig = cpu.st.getReg16(ESP);
    const word = if (cpu.dec.op_size == .b32) @as(u32, 4) else 2;
    const total: u32 = word * 8;
    // Pre-flight: the lowest written byte is at SP - total; check that range.
    const lowest = sp_orig -% @as(u16, @truncate(total));
    _ = try @import("segmentation.zig").checkSegmentAccess(cpu, .ss, lowest, total, .write);

    if (cpu.dec.op_size == .b32) {
        const regs = [_]u32{
            cpu.st.getReg32(0), cpu.st.getReg32(1), cpu.st.getReg32(2), cpu.st.getReg32(3),
            @as(u32, sp_orig),  cpu.st.getReg32(5), cpu.st.getReg32(6), cpu.st.getReg32(7),
        };
        for (regs) |r| try push32(cpu, r);
    } else {
        const regs = [_]u16{
            cpu.st.getReg16(0), cpu.st.getReg16(1), cpu.st.getReg16(2), cpu.st.getReg16(3),
            sp_orig,            cpu.st.getReg16(5), cpu.st.getReg16(6), cpu.st.getReg16(7),
        };
        for (regs) |r| try interrupts.pushWord(cpu, r);
    }
}
pub fn popa(cpu: anytype) !void {
    if (cpu.dec.op_size == .b32) {
        // pop EDI,ESI,EBP,(skip ESP),EBX,EDX,ECX,EAX
        cpu.st.setReg32(7, try pop32(cpu));
        cpu.st.setReg32(6, try pop32(cpu));
        cpu.st.setReg32(5, try pop32(cpu));
        // ESP slot: the value is NOT loaded into the low (stack-mask) part of
        // ESP — that follows the normal SP increment. But with a 16-bit stack
        // the HIGH 16 bits of ESP, which the stack pointer does not cover, DO
        // take the popped slot's high word (real 386 behaviour, validated
        // against the SingleStepTests POPAD vectors). pop32 advances SP (low 16)
        // first; we then merge the popped high word into ESP.
        const slot = try pop32(cpu);
        const cur = cpu.st.getReg32(ESP);
        cpu.st.setReg32(ESP, (slot & 0xFFFF_0000) | (cur & 0x0000_FFFF));
        cpu.st.setReg32(3, try pop32(cpu));
        cpu.st.setReg32(2, try pop32(cpu));
        cpu.st.setReg32(1, try pop32(cpu));
        cpu.st.setReg32(0, try pop32(cpu));
    } else {
        cpu.st.setReg16(7, try interrupts.popWord(cpu));
        cpu.st.setReg16(6, try interrupts.popWord(cpu));
        cpu.st.setReg16(5, try interrupts.popWord(cpu));
        _ = try interrupts.popWord(cpu);
        cpu.st.setReg16(3, try interrupts.popWord(cpu));
        cpu.st.setReg16(2, try interrupts.popWord(cpu));
        cpu.st.setReg16(1, try interrupts.popWord(cpu));
        cpu.st.setReg16(0, try interrupts.popWord(cpu));
    }
}

// ---- POP r/m (0x8F) ----
pub fn popRM(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    if (cpu.dec.op_size == .b32) {
        try exec.writeRMv(cpu, try pop32(cpu));
    } else {
        try exec.writeRMv(cpu, try interrupts.popWord(cpu));
    }
}

// ---- LDS/LES/LSS/LFS/LGS (far pointer loads) ----
pub fn loadFarPtr(cpu: anytype, seg: Seg) !void {
    try dispatch.decodeModRM(cpu);
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    const off = cpu.dec.mem_off;
    const mseg = cpu.dec.mem_seg;
    if (cpu.dec.op_size == .b32) {
        const ptr = try cpu.segRead32(mseg, off);
        const sel = try cpu.segRead16(mseg, off +% 4);
        cpu.loadSegment(seg, sel);
        cpu.st.setReg32(cpu.dec.reg, ptr);
    } else {
        const ptr = try cpu.segRead16(mseg, off);
        const sel = try cpu.segRead16(mseg, off +% 2);
        cpu.loadSegment(seg, sel);
        cpu.st.setReg16(cpu.dec.reg, ptr);
    }
    if (seg == .ss) cpu.st.inhibit_irq_one_instruction = true;
}

// ---- ENTER / LEAVE ----
pub fn enter(cpu: anytype) !void {
    const alloc_size = try dispatch.fetch16(cpu);
    const level: u8 = @truncate(try dispatch.fetch8(cpu) & 0x1F);
    const EBP = @intFromEnum(Reg32.ebp);

    if (cpu.dec.op_size == .b32) {
        // 32-bit operand form: push EBP (4 bytes), copy 32-bit display pointers.
        try push32(cpu, cpu.st.getReg32(EBP));
        const frame_temp = cpu.st.getReg16(ESP); // SP after the push
        if (level > 0) {
            var i: u8 = 1;
            while (i < level) : (i += 1) {
                cpu.st.setReg32(EBP, cpu.st.getReg32(EBP) -% 4);
                const v = try cpu.segRead32(.ss, cpu.st.getReg16(EBP));
                try push32(cpu, v);
            }
            try push32(cpu, frame_temp);
        }
        cpu.st.setReg32(EBP, frame_temp);
        cpu.st.setReg16(ESP, cpu.st.getReg16(ESP) -% alloc_size);
        return;
    }

    // 16-bit operand form (real mode default).
    const frame_temp = blk: {
        try interrupts.pushWord(cpu, cpu.st.getReg16(EBP)); // push BP
        break :blk cpu.st.getReg16(ESP);
    };
    if (level > 0) {
        var i: u8 = 1;
        while (i < level) : (i += 1) {
            cpu.st.setReg16(EBP, cpu.st.getReg16(EBP) -% 2);
            const v = try cpu.segRead16(.ss, cpu.st.getReg16(EBP));
            try interrupts.pushWord(cpu, v);
        }
        try interrupts.pushWord(cpu, frame_temp);
    }
    cpu.st.setReg16(EBP, frame_temp);
    cpu.st.setReg16(ESP, cpu.st.getReg16(ESP) -% alloc_size);
}
pub fn leave(cpu: anytype) !void {
    const EBP = @intFromEnum(Reg32.ebp);
    if (cpu.dec.op_size == .b32) {
        // 32-bit: SP = BP, then pop EBP (4 bytes).
        cpu.st.setReg16(ESP, cpu.st.getReg16(EBP));
        cpu.st.setReg32(EBP, try pop32(cpu));
    } else {
        cpu.st.setReg16(ESP, cpu.st.getReg16(EBP));
        cpu.st.setReg16(EBP, try interrupts.popWord(cpu));
    }
}
