//! BCD / ASCII adjust (Phase 4i): DAA, DAS, AAA, AAS, AAM, AAD.
//! Formulas transcribed from dosbox-staging instructions.h (cross-checked vs
//! Intel 386 PRM). Undefined flags (D9) pinned to these reproducible values.

const std = @import("std");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const flags = @import("flags.zig");
const interrupts = @import("interrupts.zig");

fn al(cpu: anytype) u8 {
    return cpu.st.getReg8(0);
}
fn setAl(cpu: anytype, v: u8) void {
    cpu.st.setReg8(0, v);
}
fn setAh(cpu: anytype, v: u8) void {
    cpu.st.setReg8(4, v);
}
fn ax(cpu: anytype) u16 {
    return cpu.st.getReg16(0);
}
fn setAx(cpu: anytype, v: u16) void {
    cpu.st.setReg16(0, v);
}

pub fn daa(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    var a = al(cpu);
    if ((a & 0x0F) > 0x09 or f.af) {
        if (a > 0x99 or f.cf) {
            a +%= 0x60;
            f.cf = true;
        } else f.cf = false;
        a +%= 0x06;
        f.af = true;
    } else {
        if (a > 0x99 or f.cf) {
            a +%= 0x60;
            f.cf = true;
        } else f.cf = false;
        f.af = false;
    }
    setAl(cpu, a);
    f.sf = (a & 0x80) != 0;
    f.zf = (a == 0);
    f.pf = flags.parity_table[a];
}

pub fn das(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    var a = al(cpu);
    const osigned = a & 0x80;
    if ((a & 0x0F) > 9 or f.af) {
        if (a > 0x99 or f.cf) {
            a -%= 0x60;
            f.cf = true;
        } else f.cf = (a <= 0x05);
        a -%= 6;
        f.af = true;
    } else {
        if (a > 0x99 or f.cf) {
            a -%= 0x60;
            f.cf = true;
        } else f.cf = false;
        f.af = false;
    }
    setAl(cpu, a);
    f.of = (osigned != 0) and ((a & 0x80) == 0);
    f.sf = (a & 0x80) != 0;
    f.zf = (a == 0);
    f.pf = flags.parity_table[a];
}

pub fn aaa(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    const a = al(cpu);
    f.sf = (a >= 0x7a) and (a <= 0xf9);
    if ((a & 0xf) > 9) {
        f.of = (a & 0xf0) == 0x70;
        setAx(cpu, ax(cpu) +% 0x106);
        f.cf = true;
        f.zf = (al(cpu) == 0);
        f.af = true;
    } else if (f.af) {
        setAx(cpu, ax(cpu) +% 0x106);
        f.of = false;
        f.cf = true;
        f.zf = false;
        f.af = true;
    } else {
        f.of = false;
        f.cf = false;
        f.zf = (a == 0);
        f.af = false;
    }
    f.pf = flags.parity_table[al(cpu)];
    setAl(cpu, al(cpu) & 0x0F);
}

pub fn aas(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    const a = al(cpu);
    if ((a & 0x0f) > 9) {
        f.sf = a > 0x85;
        setAx(cpu, ax(cpu) -% 0x106);
        f.of = false;
        f.cf = true;
        f.af = true;
    } else if (f.af) {
        f.of = (a >= 0x80) and (a <= 0x85);
        f.sf = (a < 0x06) or (a > 0x85);
        setAx(cpu, ax(cpu) -% 0x106);
        f.cf = true;
        f.af = true;
    } else {
        f.sf = a >= 0x80;
        f.of = false;
        f.cf = false;
        f.af = false;
    }
    f.zf = (al(cpu) == 0);
    f.pf = flags.parity_table[al(cpu)];
    setAl(cpu, al(cpu) & 0x0F);
}

pub fn aam(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    const base = try dispatch.fetch8(cpu);
    if (base == 0) return cpu.raiseFault(interrupts.VEC_DE, .fault, null);
    const a = al(cpu);
    setAh(cpu, a / base);
    setAl(cpu, a % base);
    const lo = al(cpu);
    f.sf = (lo & 0x80) != 0;
    f.zf = (lo == 0);
    f.pf = flags.parity_table[lo];
    f.cf = false;
    f.of = false;
    f.af = false;
}

pub fn aad(cpu: anytype) !void {
    const f = &cpu.st.eflags;
    const base = try dispatch.fetch8(cpu);
    const ax1: u16 = @as(u16, cpu.st.getReg8(4)) *% base; // AH * base
    const ax2: u16 = ax1 +% al(cpu);
    setAl(cpu, @truncate(ax2));
    setAh(cpu, 0);
    const lo = al(cpu);
    f.cf = false;
    f.of = false;
    f.af = false;
    f.sf = lo >= 0x80;
    f.zf = lo == 0;
    f.pf = flags.parity_table[lo];
}
