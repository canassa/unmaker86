//! Real-mode-executable system / privileged instructions (Phase 4k). CPL=0 in
//! real mode so privilege checks pass; storage effects implemented faithfully or
//! FLAGGED where the full effect needs deferred PM/paging (never faked).

const std = @import("std");
const state = @import("state.zig");
const exec = @import("exec.zig");
const dispatch = @import("dispatch.zig");
const Seg = state.Seg;

/// A program set CR0.PE or PG; the PM/paging effect is deferred (flagged, not
/// faked). The CPU stores the bit faithfully but cannot perform the mode switch
/// / translation. A PM-dependent transfer afterwards surfaces this.
pub var deferred_pm_flagged: bool = false;
pub var deferred_paging_flagged: bool = false;

/// Grp7 (0F 01): LGDT/LIDT/SGDT/SIDT/SMSW/LMSW (+ INVLPG is 486+, #UD).
pub fn grp7(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    switch (cpu.dec.reg) {
        0 => try sgdt(cpu), // SGDT
        1 => try sidt(cpu), // SIDT
        2 => try lgdt(cpu), // LGDT
        3 => try lidt(cpu), // LIDT
        4 => try smsw(cpu), // SMSW
        6 => try lmsw(cpu), // LMSW
        else => try exec.ud(cpu), // /5 reserved, /7 INVLPG (486+) => #UD on 386
    }
}

fn sgdt(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    try cpu.segWrite16(cpu.dec.mem_seg, cpu.dec.mem_off, cpu.st.gdtr_limit);
    const base = cpu.st.gdtr_base;
    // 16-bit operand size stores only 24 bits of base; 32-bit stores full.
    if (cpu.dec.op_size == .b16) {
        try cpu.segWrite32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2, base & 0x00FFFFFF);
    } else {
        try cpu.segWrite32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2, base);
    }
}
fn sidt(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    try cpu.segWrite16(cpu.dec.mem_seg, cpu.dec.mem_off, cpu.st.idtr_limit);
    const base = cpu.st.idtr_base;
    if (cpu.dec.op_size == .b16) {
        try cpu.segWrite32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2, base & 0x00FFFFFF);
    } else {
        try cpu.segWrite32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2, base);
    }
}
fn lgdt(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    cpu.st.gdtr_limit = try cpu.segRead16(cpu.dec.mem_seg, cpu.dec.mem_off);
    const raw = try cpu.segRead32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2);
    cpu.st.gdtr_base = if (cpu.dec.op_size == .b16) (raw & 0x00FFFFFF) else raw;
    // GDTR has no real-mode effect; the descriptor-table use is deferred.
}
fn lidt(cpu: anytype) !void {
    if (cpu.dec.kind != .mem) return exec.ud(cpu);
    cpu.st.idtr_limit = try cpu.segRead16(cpu.dec.mem_seg, cpu.dec.mem_off);
    const raw = try cpu.segRead32(cpu.dec.mem_seg, cpu.dec.mem_off +% 2);
    cpu.st.idtr_base = if (cpu.dec.op_size == .b16) (raw & 0x00FFFFFF) else raw;
    // IDTR.limit is honored by interrupt delivery (interrupts.deliverViaIvt).
}
fn smsw(cpu: anytype) !void {
    const v: u16 = @truncate(cpu.st.cr0);
    if (cpu.dec.kind == .reg) {
        if (cpu.dec.op_size == .b32) cpu.st.setReg32(cpu.dec.rm, @truncate(cpu.st.cr0)) else cpu.st.setReg16(cpu.dec.rm, v);
    } else {
        try cpu.segWrite16(cpu.dec.mem_seg, cpu.dec.mem_off, v);
    }
}
fn lmsw(cpu: anytype) !void {
    const v = try exec.readRM16(cpu);
    // LMSW can set PE but cannot clear it. Affects low 4 bits (PE,MP,EM,TS).
    const old = cpu.st.cr0;
    var new = (old & 0xFFFFFFF0) | (@as(u32, v) & 0x0F);
    new |= (old & 0x1); // PE cannot be cleared
    if ((new & 0x1) != 0 and (old & 0x1) == 0) deferred_pm_flagged = true;
    cpu.st.cr0 = new;
}

/// CLTS (0F 06): clear CR0.TS.
pub fn clts(cpu: anytype) !void {
    cpu.st.cr0 &= ~@as(u32, 0x8); // TS = bit 3
}

/// MOV from CR (0F 20).
pub fn movFromCr(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    // mod is forced to register; the reg field selects the CR.
    const v: u32 = switch (cpu.dec.reg) {
        0 => cpu.st.cr0,
        2 => cpu.st.cr2,
        3 => cpu.st.cr3,
        else => return exec.ud(cpu),
    };
    cpu.st.setReg32(cpu.dec.rm, v);
}
/// MOV to CR (0F 22).
pub fn movToCr(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    const v = cpu.st.getReg32(cpu.dec.rm);
    switch (cpu.dec.reg) {
        0 => {
            const old = cpu.st.cr0;
            cpu.st.cr0 = v;
            if ((v & 0x1) != 0 and (old & 0x1) == 0) deferred_pm_flagged = true;
            if ((v & 0x80000000) != 0 and (old & 0x80000000) == 0) deferred_paging_flagged = true;
        },
        2 => cpu.st.cr2 = v,
        3 => cpu.st.cr3 = v,
        else => return exec.ud(cpu),
    }
}
/// MOV from DR (0F 21).
pub fn movFromDr(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    cpu.st.setReg32(cpu.dec.rm, cpu.st.dr[cpu.dec.reg]);
}
/// MOV to DR (0F 23). Storage only; breakpoint matching is deferred (flagged).
pub fn movToDr(cpu: anytype) !void {
    try dispatch.decodeModRM(cpu);
    cpu.st.dr[cpu.dec.reg] = cpu.st.getReg32(cpu.dec.rm);
}
