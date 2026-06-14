//! String ops (Phase 4g): MOVS/CMPS/SCAS/LODS/STOS, REP/REPE/REPNE.
//! Modeled re-entrant at the instruction boundary (DECIDED REP interruptibility):
//! one iteration per executeOne when REP-prefixed and not done, leaving EIP at
//! the REP so an interrupt mid-REP is restartable and the partial SI/DI/CX state
//! is exact.

const std = @import("std");
const state = @import("state.zig");
const exec = @import("exec.zig");
const alu = @import("alu.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
const ESI = @intFromEnum(Reg32.esi);
const EDI = @intFromEnum(Reg32.edi);
const ECX = @intFromEnum(Reg32.ecx);

const StrOp = enum { movs, cmps, stos, lods, scas };

fn opWidth(cpu: anytype, byte: bool) alu.Width {
    if (byte) return .b8;
    return exec.widthOf(cpu);
}

fn bytesPer(w: alu.Width) u32 {
    return switch (w) {
        .b8 => 1,
        .b16 => 2,
        .b32 => 4,
    };
}

fn getCx(cpu: anytype) u32 {
    return if (cpu.dec.addr_size == .a32) cpu.st.getReg32(ECX) else @as(u32, cpu.st.getReg16(ECX));
}
fn setCx(cpu: anytype, v: u32) void {
    if (cpu.dec.addr_size == .a32) cpu.st.setReg32(ECX, v) else cpu.st.setReg16(ECX, @truncate(v));
}
fn getSi(cpu: anytype) u32 {
    return if (cpu.dec.addr_size == .a32) cpu.st.getReg32(ESI) else @as(u32, cpu.st.getReg16(ESI));
}
fn setSi(cpu: anytype, v: u32) void {
    if (cpu.dec.addr_size == .a32) cpu.st.setReg32(ESI, v) else cpu.st.setReg16(ESI, @truncate(v));
}
fn getDi(cpu: anytype) u32 {
    return if (cpu.dec.addr_size == .a32) cpu.st.getReg32(EDI) else @as(u32, cpu.st.getReg16(EDI));
}
fn setDi(cpu: anytype, v: u32) void {
    if (cpu.dec.addr_size == .a32) cpu.st.setReg32(EDI, v) else cpu.st.setReg16(EDI, @truncate(v));
}

/// Execute one string instruction (handles REP at the instruction boundary).
pub fn string(cpu: anytype, op: StrOp, byte: bool) !void {
    const has_rep = cpu.dec.rep or cpu.dec.repne;

    if (has_rep) {
        const c = getCx(cpu);
        if (c == 0) return; // REP with CX=0 is a no-op
        try oneIter(cpu, op, byte);
        const new_c = c - 1;
        setCx(cpu, new_c);
        // ZF-based termination for CMPS/SCAS.
        var done = (new_c == 0);
        if (op == .cmps or op == .scas) {
            if (cpu.dec.rep and !cpu.st.eflags.zf) done = true; // REPE: stop when ZF=0
            if (cpu.dec.repne and cpu.st.eflags.zf) done = true; // REPNE: stop when ZF=1
        }
        if (!done) {
            // Re-enter: leave EIP pointing at the REP instruction so the next
            // step (after the interrupt check) continues the loop.
            cpu.st.eip = cpu.instr_start_eip;
        }
        return;
    }

    try oneIter(cpu, op, byte);
}

fn oneIter(cpu: anytype, op: StrOp, byte: bool) !void {
    const w = opWidth(cpu, byte);
    const n = bytesPer(w);
    const delta: u32 = if (cpu.st.eflags.df) (0 -% n) else n;
    const src_seg = cpu.dec.seg_override orelse Seg.ds;

    switch (op) {
        .movs => {
            const v = try readSeg(cpu, src_seg, getSi(cpu), w);
            try writeSeg(cpu, .es, getDi(cpu), w, v);
            setSi(cpu, advance(cpu, getSi(cpu), delta));
            setDi(cpu, advance(cpu, getDi(cpu), delta));
        },
        .stos => {
            const v = accVal(cpu, w);
            try writeSeg(cpu, .es, getDi(cpu), w, v);
            setDi(cpu, advance(cpu, getDi(cpu), delta));
        },
        .lods => {
            const v = try readSeg(cpu, src_seg, getSi(cpu), w);
            setAcc(cpu, w, v);
            setSi(cpu, advance(cpu, getSi(cpu), delta));
        },
        .scas => {
            const a = accVal(cpu, w);
            const b = try readSeg(cpu, .es, getDi(cpu), w);
            alu.cmp(&cpu.st.eflags, w, a, b);
            setDi(cpu, advance(cpu, getDi(cpu), delta));
        },
        .cmps => {
            const a = try readSeg(cpu, src_seg, getSi(cpu), w);
            const b = try readSeg(cpu, .es, getDi(cpu), w);
            alu.cmp(&cpu.st.eflags, w, a, b);
            setSi(cpu, advance(cpu, getSi(cpu), delta));
            setDi(cpu, advance(cpu, getDi(cpu), delta));
        },
    }
}

fn advance(cpu: anytype, ptr: u32, delta: u32) u32 {
    if (cpu.dec.addr_size == .a32) return ptr +% delta;
    return (ptr +% delta) & 0xFFFF;
}

fn readSeg(cpu: anytype, seg: Seg, off: u32, w: alu.Width) !u64 {
    return switch (w) {
        .b8 => @as(u64, try cpu.segRead8(seg, off)),
        .b16 => @as(u64, try cpu.segRead16(seg, off)),
        .b32 => @as(u64, try cpu.segRead32(seg, off)),
    };
}
fn writeSeg(cpu: anytype, seg: Seg, off: u32, w: alu.Width, v: u64) !void {
    switch (w) {
        .b8 => try cpu.segWrite8(seg, off, @truncate(v)),
        .b16 => try cpu.segWrite16(seg, off, @truncate(v)),
        .b32 => try cpu.segWrite32(seg, off, @truncate(v)),
    }
}
fn accVal(cpu: anytype, w: alu.Width) u64 {
    return switch (w) {
        .b8 => cpu.st.getReg8(0),
        .b16 => cpu.st.getReg16(0),
        .b32 => cpu.st.getReg32(0),
    };
}
fn setAcc(cpu: anytype, w: alu.Width, v: u64) void {
    switch (w) {
        .b8 => cpu.st.setReg8(0, @truncate(v)),
        .b16 => cpu.st.setReg16(0, @truncate(v)),
        .b32 => cpu.st.setReg32(0, @truncate(v)),
    }
}

// Public entry points for the dispatch switch.
pub fn movsb(cpu: anytype) !void {
    return string(cpu, .movs, true);
}
pub fn movsv(cpu: anytype) !void {
    return string(cpu, .movs, false);
}
pub fn cmpsb(cpu: anytype) !void {
    return string(cpu, .cmps, true);
}
pub fn cmpsv(cpu: anytype) !void {
    return string(cpu, .cmps, false);
}
pub fn stosb(cpu: anytype) !void {
    return string(cpu, .stos, true);
}
pub fn stosv(cpu: anytype) !void {
    return string(cpu, .stos, false);
}
pub fn lodsb(cpu: anytype) !void {
    return string(cpu, .lods, true);
}
pub fn lodsv(cpu: anytype) !void {
    return string(cpu, .lods, false);
}
pub fn scasb(cpu: anytype) !void {
    return string(cpu, .scas, true);
}
pub fn scasv(cpu: anytype) !void {
    return string(cpu, .scas, false);
}
