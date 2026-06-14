//! I/O instructions (Phase 4g/4): IN/OUT (fixed + DX), INS/OUTS string I/O.
//! Real mode CPL=0, so no IOPL / I/O-bitmap check.

const std = @import("std");
const state = @import("state.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
const EDX = @intFromEnum(Reg32.edx);
const EDI = @intFromEnum(Reg32.edi);
const ESI = @intFromEnum(Reg32.esi);
const ECX = @intFromEnum(Reg32.ecx);

pub fn inAlImm(cpu: anytype) !void {
    const port = try dispatch.fetch8(cpu);
    cpu.st.setReg8(0, cpu.bus.portIn8(port));
}
pub fn inAxImm(cpu: anytype) !void {
    const port = try dispatch.fetch8(cpu);
    if (cpu.dec.op_size == .b32) cpu.st.setReg32(0, cpu.bus.portIn32(port)) else cpu.st.setReg16(0, cpu.bus.portIn16(port));
}
pub fn outImmAl(cpu: anytype) !void {
    const port = try dispatch.fetch8(cpu);
    cpu.bus.portOut8(port, cpu.st.getReg8(0));
}
pub fn outImmAx(cpu: anytype) !void {
    const port = try dispatch.fetch8(cpu);
    if (cpu.dec.op_size == .b32) cpu.bus.portOut32(port, cpu.st.getReg32(0)) else cpu.bus.portOut16(port, cpu.st.getReg16(0));
}
pub fn inAlDx(cpu: anytype) !void {
    cpu.st.setReg8(0, cpu.bus.portIn8(cpu.st.getReg16(EDX)));
}
pub fn inAxDx(cpu: anytype) !void {
    const port = cpu.st.getReg16(EDX);
    if (cpu.dec.op_size == .b32) cpu.st.setReg32(0, cpu.bus.portIn32(port)) else cpu.st.setReg16(0, cpu.bus.portIn16(port));
}
pub fn outDxAl(cpu: anytype) !void {
    cpu.bus.portOut8(cpu.st.getReg16(EDX), cpu.st.getReg8(0));
}
pub fn outDxAx(cpu: anytype) !void {
    const port = cpu.st.getReg16(EDX);
    if (cpu.dec.op_size == .b32) cpu.bus.portOut32(port, cpu.st.getReg32(0)) else cpu.bus.portOut16(port, cpu.st.getReg16(0));
}

// INS/OUTS (string I/O). Single iteration (REP handled like string ops).
fn delta(cpu: anytype, n: u32) u32 {
    return if (cpu.st.eflags.df) (0 -% n) else n;
}
fn ptr(cpu: anytype, idx: u3) u32 {
    return if (cpu.dec.addr_size == .a32) cpu.st.getReg32(idx) else @as(u32, cpu.st.getReg16(idx));
}
fn setPtr(cpu: anytype, idx: u3, v: u32) void {
    if (cpu.dec.addr_size == .a32) cpu.st.setReg32(idx, v) else cpu.st.setReg16(idx, @truncate(v));
}

pub fn insOne(cpu: anytype, byte: bool) !void {
    const port = cpu.st.getReg16(EDX);
    const di = ptr(cpu, EDI);
    if (byte) {
        try cpu.segWrite8(.es, di, cpu.bus.portIn8(port));
        setPtr(cpu, EDI, di +% delta(cpu, 1));
    } else if (cpu.dec.op_size == .b32) {
        try cpu.segWrite32(.es, di, cpu.bus.portIn32(port));
        setPtr(cpu, EDI, di +% delta(cpu, 4));
    } else {
        try cpu.segWrite16(.es, di, cpu.bus.portIn16(port));
        setPtr(cpu, EDI, di +% delta(cpu, 2));
    }
}
pub fn outsOne(cpu: anytype, byte: bool) !void {
    const port = cpu.st.getReg16(EDX);
    const src_seg = cpu.dec.seg_override orelse Seg.ds;
    const si = ptr(cpu, ESI);
    if (byte) {
        cpu.bus.portOut8(port, try cpu.segRead8(src_seg, si));
        setPtr(cpu, ESI, si +% delta(cpu, 1));
    } else if (cpu.dec.op_size == .b32) {
        cpu.bus.portOut32(port, try cpu.segRead32(src_seg, si));
        setPtr(cpu, ESI, si +% delta(cpu, 4));
    } else {
        cpu.bus.portOut16(port, try cpu.segRead16(src_seg, si));
        setPtr(cpu, ESI, si +% delta(cpu, 2));
    }
}

pub fn ins(cpu: anytype, byte: bool) !void {
    return repWrap(cpu, byte, insOne);
}
pub fn outs(cpu: anytype, byte: bool) !void {
    return repWrap(cpu, byte, outsOne);
}

fn repWrap(cpu: anytype, byte: bool, comptime f: anytype) !void {
    if (cpu.dec.rep or cpu.dec.repne) {
        const c = ptr(cpu, ECX);
        if (c == 0) return;
        try f(cpu, byte);
        const nc = c - 1;
        setPtr(cpu, ECX, nc);
        if (nc != 0) cpu.st.eip = cpu.instr_start_eip;
        return;
    }
    try f(cpu, byte);
}
