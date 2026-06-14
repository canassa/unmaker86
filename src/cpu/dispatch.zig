//! Instruction fetch, the prefix scan, ModR/M+SIB resolution, and the single
//! big dispatch switch (D2). Execution bodies live in exec_*.zig and are called
//! from the switch arms.

const std = @import("std");
const state = @import("state.zig");
const decode = @import("decode.zig");
const cycles = @import("cycles.zig");
const interrupts = @import("interrupts.zig");
const exec = @import("exec.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
const Decoded = decode.Decoded;
const OperandSize = decode.OperandSize;
const AddrSize = decode.AddrSize;

const CS = @intFromEnum(Seg.cs);

/// Max instruction length on the 386 (#GP if exceeded).
const MAX_INSTR_LEN: u8 = 15;

// ---------------------------------------------------------------------------
// Instruction fetch (segmented CS:EIP -> linear -> physical). Charges nothing
// extra here; base cost is charged by the dispatch choke point.
// ---------------------------------------------------------------------------

pub fn fetch8(cpu: anytype) !u8 {
    const off = cpu.st.eip;
    const v = try cpu.segRead8(.cs, off);
    cpu.st.eip = off +% 1;
    cpu.dec.len += 1;
    if (cpu.dec.len > MAX_INSTR_LEN) return cpu.raiseFault(interrupts.VEC_GP, .fault, 0);
    return v;
}

pub fn fetch16(cpu: anytype) !u16 {
    const lo = try fetch8(cpu);
    const hi = try fetch8(cpu);
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

pub fn fetch32(cpu: anytype) !u32 {
    const lo = try fetch16(cpu);
    const hi = try fetch16(cpu);
    return @as(u32, lo) | (@as(u32, hi) << 16);
}

// ---------------------------------------------------------------------------
// executeOne: the per-instruction entry called by interrupts.step().
// ---------------------------------------------------------------------------

pub fn executeOne(cpu: anytype) !void {
    cpu.dec.reset();

    // --- Prefix scan (single forward pass) ---
    var op: u8 = try fetch8(cpu);
    while (true) {
        switch (op) {
            0x2E => cpu.dec.seg_override = .cs,
            0x36 => cpu.dec.seg_override = .ss,
            0x3E => cpu.dec.seg_override = .ds,
            0x26 => cpu.dec.seg_override = .es,
            0x64 => cpu.dec.seg_override = .fs,
            0x65 => cpu.dec.seg_override = .gs,
            0x66 => cpu.dec.has_66 = true,
            0x67 => cpu.dec.has_67 = true,
            0xF0 => cpu.dec.lock = true,
            0xF2 => cpu.dec.repne = true,
            0xF3 => cpu.dec.rep = true,
            else => break,
        }
        op = try fetch8(cpu);
    }

    // --- Two-byte opcode map ---
    if (op == 0x0F) {
        cpu.dec.is_0F = true;
        op = try fetch8(cpu);
    }
    cpu.dec.opcode = op;

    // --- Resolve sizes (real mode: CS.D=0) ---
    const cs_big = cpu.st.seg_desc[CS].big;
    decode.resolveSizes(&cpu.dec, cs_big);
    decode.computeKey(&cpu.dec);

    // --- Charge base cost by construction (Theme E) ---
    cpu.st.cycles += cycles.baseFor(cpu.dec.key);

    // --- LOCK on a clearly non-lockable opcode -> #UD before execution. The
    // mem-destination refinement for lockable opcodes happens in decodeModRM. ---
    if (cpu.dec.lock and !lockOpcodePossible(cpu.dec.is_0F, op)) {
        return cpu.raiseFault(interrupts.VEC_UD, .fault, 0);
    }

    // --- Dispatch ---
    try exec.execute(cpu);
}

// ---------------------------------------------------------------------------
// ModR/M + SIB decode. Fills cpu.dec.{mod,reg,rm,kind,mem_seg,mem_off}.
// ---------------------------------------------------------------------------

/// LOCK legality (386): the LOCK prefix is valid ONLY on a documented set of
/// read-modify-write opcodes AND only when the destination is a MEMORY operand.
/// Anything else (a non-lockable opcode, or a register destination) #UDs. This
/// is the lockable-opcode gate the plan mandates (ground rule: enforce, never
/// ignore). reg = the ModR/M reg field (the group sub-opcode for groups).
/// True if the opcode is in the lockable family at all (ignoring the reg-field
/// and operand-kind refinement). Used to #UD a LOCK on a clearly non-lockable
/// opcode that may not even decode a ModR/M byte (e.g. PUSH seg, NOP, far CALL).
pub fn lockOpcodePossible(is_0F: bool, opcode: u8) bool {
    if (is_0F) {
        return switch (opcode) {
            0xB3, 0xAB, 0xBB, 0xBA, 0xB0, 0xB1, 0xC0, 0xC1 => true,
            else => false,
        };
    }
    return switch (opcode) {
        0x00, 0x01, 0x08, 0x09, 0x10, 0x11, 0x18, 0x19, 0x20, 0x21, 0x28, 0x29, 0x30, 0x31,
        0x80, 0x81, 0x82, 0x83, 0x86, 0x87, 0xF6, 0xF7, 0xFE, 0xFF => true,
        else => false,
    };
}

fn lockAllowed(is_0F: bool, opcode: u8, reg: u3) bool {
    if (is_0F) {
        return switch (opcode) {
            0xB3, 0xAB, 0xBB => true, // BTR / BTS / BTC  r/m, reg
            0xBA => (reg >= 5), // Grp8: BTS(5)/BTR(6)/BTC(7) r/m, imm8 (BT(4) not lockable)
            0xB0, 0xB1 => true, // CMPXCHG (486) — lockable form (gated #UD elsewhere on 386)
            0xC0, 0xC1 => true, // XADD (486)
            else => false,
        };
    }
    return switch (opcode) {
        // ADD/OR/ADC/SBB/AND/SUB/XOR — only the r/m,reg (dest=r/m) forms.
        0x00, 0x01, 0x08, 0x09, 0x10, 0x11, 0x18, 0x19, 0x20, 0x21, 0x28, 0x29, 0x30, 0x31 => true,
        // Grp1 (0x80/0x81/0x82/0x83): ADD..XOR imm to r/m; reg==7 is CMP (not lockable).
        0x80, 0x81, 0x82, 0x83 => (reg != 7),
        0x86, 0x87 => true, // XCHG r/m, reg
        0xF6, 0xF7 => (reg == 2 or reg == 3), // NOT(2)/NEG(3)
        0xFE => (reg == 0 or reg == 1), // INC/DEC r/m8
        0xFF => (reg == 0 or reg == 1), // INC/DEC r/m
        else => false,
    };
}

pub fn decodeModRM(cpu: anytype) !void {
    const m = try fetch8(cpu);
    cpu.dec.has_modrm = true;
    cpu.dec.modrm = m;
    cpu.dec.mod = @truncate(m >> 6);
    cpu.dec.reg = @truncate(m >> 3);
    cpu.dec.rm = @truncate(m);

    // LOCK legality: #UD unless a lockable opcode with a memory destination.
    if (cpu.dec.lock) {
        const mem_dest = (cpu.dec.mod != 0b11);
        if (!mem_dest or !lockAllowed(cpu.dec.is_0F, cpu.dec.opcode, cpu.dec.reg)) {
            return cpu.raiseFault(interrupts.VEC_UD, .fault, 0);
        }
    }

    if (cpu.dec.mod == 0b11) {
        cpu.dec.kind = .reg;
        return;
    }
    cpu.dec.kind = .mem;
    if (cpu.dec.addr_size == .a16) {
        try decodeMem16(cpu);
    } else {
        try decodeMem32(cpu);
    }
}

fn decodeMem16(cpu: anytype) !void {
    const mod = cpu.dec.mod;
    const rm = cpu.dec.rm;

    var off: u32 = 0;
    var def_seg: Seg = .ds;

    if (mod == 0 and rm == 6) {
        // disp16 direct.
        off = try fetch16(cpu);
        def_seg = .ds;
    } else {
        const t = decode.rm16(rm);
        def_seg = t.default_seg;
        var ea: u16 = 0;
        if (t.base_reg) |b| ea +%= cpu.st.getReg16(b);
        if (t.index_reg) |ix| ea +%= cpu.st.getReg16(ix);
        switch (mod) {
            0 => {},
            1 => {
                const d: i8 = @bitCast(try fetch8(cpu));
                ea +%= @bitCast(@as(i16, d));
            },
            2 => {
                const d = try fetch16(cpu);
                ea +%= d;
            },
            3 => unreachable,
        }
        off = ea;
    }
    cpu.dec.mem_seg = cpu.dec.seg_override orelse def_seg;
    cpu.dec.mem_off = off;
}

fn decodeMem32(cpu: anytype) !void {
    const mod = cpu.dec.mod;
    const rm = cpu.dec.rm;
    var off: u32 = 0;
    var def_seg: Seg = .ds;

    if (rm == 4) {
        // SIB byte follows.
        const sib = try fetch8(cpu);
        const scale_shift: u2 = @truncate(sib >> 6); // 0,1,2,3 -> *1,*2,*4,*8
        const index: u3 = @truncate(sib >> 3);
        const base: u3 = @truncate(sib);

        var ea: u32 = 0;
        // Index (ESP/index==100 => no index).
        if (index != 4) {
            ea +%= cpu.st.getReg32(index) << scale_shift;
        }
        // Base.
        if (base == 5 and mod == 0) {
            // disp32, no base.
            off = try fetch32(cpu);
            ea +%= off;
            def_seg = .ds;
        } else {
            ea +%= cpu.st.getReg32(base);
            def_seg = if (base == 4 or base == 5) .ss else .ds;
            switch (mod) {
                0 => {},
                1 => {
                    const d: i8 = @bitCast(try fetch8(cpu));
                    ea +%= @bitCast(@as(i32, d));
                },
                2 => {
                    const d = try fetch32(cpu);
                    ea +%= d;
                },
                3 => unreachable,
            }
        }
        off = ea;
    } else if (mod == 0 and rm == 5) {
        // disp32 direct.
        off = try fetch32(cpu);
        def_seg = .ds;
    } else {
        var ea: u32 = cpu.st.getReg32(rm);
        def_seg = if (rm == 5) .ss else .ds; // EBP base => SS
        switch (mod) {
            0 => {},
            1 => {
                const d: i8 = @bitCast(try fetch8(cpu));
                ea +%= @bitCast(@as(i32, d));
            },
            2 => {
                const d = try fetch32(cpu);
                ea +%= d;
            },
            3 => unreachable,
        }
        off = ea;
    }
    cpu.dec.mem_seg = cpu.dec.seg_override orelse def_seg;
    cpu.dec.mem_off = off;
}

// ---------------------------------------------------------------------------
// Immediate / displacement fetch helpers (sized by operand size).
// ---------------------------------------------------------------------------

pub fn immByOpSize(cpu: anytype) !u32 {
    return switch (cpu.dec.op_size) {
        .b16 => @as(u32, try fetch16(cpu)),
        .b32 => try fetch32(cpu),
    };
}
