//! Architectural state of the 80386 core (real mode).
//!
//! Pure data, one preallocated struct. No allocation, no hidden machine state:
//! eager flags (D1) and decoded `seg_base`/`seg_limit`/`seg_desc` (D4) mean the
//! whole CPU is serializable for the future API server (Phase 9 save/restore).
//!
//! Layout doctrine (Theme F, memory-and-performance.md §5): hot state (GP regs,
//! EFLAGS, EIP, seg_base/seg_limit) kept tight; cold state (CR/DR/IDTR/GDTR,
//! the PM-shaped SegDescCold) kept separate.

const std = @import("std");
const builtin = @import("builtin");
const flags = @import("flags.zig");

// The byte[0]=AL, byte[1]=AH overlay only works little-endian (D3).
comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// One general-purpose register with the AX/AH/AL aliasing overlay (D3).
/// extern union (NOT packed) gives the C layout; packed would require equal
/// bit-sizes for all fields (zig-langref/18-union.md), which u32/[2]u16/[4]u8
/// violate.
pub const GenReg32 = extern union {
    dword: u32,
    word: [2]u16,
    byte: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(GenReg32) == 4);
}

/// Index of a 32-bit GP register in the register file (ModR/M reg encoding).
pub const Reg32 = enum(u3) { eax, ecx, edx, ebx, esp, ebp, esi, edi };

/// Index of a segment register. Dense order chosen to match the common
/// ES,CS,SS,DS,FS,GS encoding used by the segment-override prefixes and the
/// MOV-to-segreg `reg` field (the latter uses 0=ES,1=CS,2=SS,3=DS,4=FS,5=GS).
pub const Seg = enum(u3) { es, cs, ss, ds, fs, gs };

/// Cold, PM-shaped descriptor fields (D4). Written once on a segment load,
/// never read on the real-mode access path. The PM seam.
pub const SegDescCold = packed struct(u16) {
    /// Segment type field (descriptor type bits). Real mode writes a default.
    seg_type: u4 = 0,
    /// Descriptor privilege level.
    dpl: u2 = 0,
    /// Present bit.
    present: bool = true,
    /// Conforming code segment.
    conforming: bool = false,
    /// Expand-down data segment.
    expand_down: bool = false,
    /// Readable code / always-readable data.
    readable: bool = true,
    /// Writable data segment.
    writable: bool = true,
    /// Big/default-B/default-D bit. 0 in real mode (16-bit defaults).
    big: bool = false,
    _reserved: u4 = 0,
};

comptime {
    std.debug.assert(@sizeOf(SegDescCold) == 2);
}

/// Reason `step()` stopped, returned in StepResult (D11).
pub const StopReason = enum {
    /// A normal instruction retired.
    normal,
    /// HLT executed; the machine fast-forwards emulated time to the next
    /// scheduled event. The CPU charges no host-derived idle.
    halted,
    /// Triple fault / shutdown signalled; the machine decides reset policy.
    shutdown,
};

/// Result of a single `step()` (D11) — the primitive of the public API.
pub const StepResult = struct {
    cycles_consumed: u64,
    stop_reason: StopReason,
};

/// Exception/interrupt class (determines EIP semantics at delivery, Phase 6).
pub const FaultClass = enum { fault, trap, abort, interrupt };

/// A pending fault recorded by a memory/decode/segment helper before it returns
/// `error.Fault` (D10). `error_code` is the Theme G PM/CR2 seam — always
/// null in real mode.
pub const PendingFault = struct {
    vector: u8,
    class: FaultClass,
    error_code: ?u32 = null,
};

/// A read-only breadcrumb of the most recent IVT delivery (M1 Phase 4). `seq`
/// starts at 0 ("no delivery yet") and increments on every delivery; the debugger
/// compares it against the pre-step value to detect a fresh delivery.
pub const LastDelivered = struct {
    vector: u8 = 0,
    at_cycle: u64 = 0,
    seq: u64 = 0,
};

/// The complete 386 architectural state (real-mode subset). One struct, fully
/// reset-initialized, no hidden state.
pub const State = struct {
    // ---- HOT: touched every instruction, keep tight ----
    /// GP register file, indexed by Reg32 (ModR/M reg field). AoS, 32 bytes.
    regs: [8]GenReg32 = @splat(.{ .dword = 0 }),
    /// Instruction pointer (full 32-bit; IP is the low 16).
    eip: u32 = 0,
    /// Flags register (eager, D1).
    eflags: flags.Flags = .{},
    /// Authoritative segment bases on the access path (base = sel<<4 in real mode).
    seg_base: [6]u32 = @splat(0),
    /// Authoritative segment limits. Set at reset, NOT on load (unreal mode, D4).
    seg_limit: [6]u32 = @splat(0xFFFF),
    /// Segment selectors.
    selector: [6]u16 = @splat(0),

    // ---- COLD: PM seam + system regs, kept separate ----
    /// Parallel PM-shaped descriptor cache (written on load, unread on access).
    seg_desc: [6]SegDescCold = @splat(.{}),
    /// Control register 0. All bits modeled as storage.
    cr0: u32 = 0,
    /// Page-fault linear address (storage; effect is paging, deferred).
    cr2: u32 = 0,
    /// Page-directory base (storage; effect is paging, deferred).
    cr3: u32 = 0,
    /// Debug registers (storage; breakpoint matching deferred).
    dr: [8]u32 = @splat(0),
    /// Interrupt descriptor table register. In real mode the IVT.
    idtr_base: u32 = 0,
    idtr_limit: u16 = 0x3FF,
    /// Global descriptor table register (storage; PM effect deferred).
    gdtr_base: u32 = 0,
    gdtr_limit: u16 = 0,
    /// Local descriptor table register (storage; PM-only).
    ldtr: u16 = 0,
    /// Task register (storage; PM-only).
    tr: u16 = 0,
    /// Current privilege level. Fixed at 0 in real mode; stored for PM reuse.
    cpl: u2 = 0,

    // ---- Instruction-boundary state (Phase 9 audit: all serializable) ----
    /// One-instruction interrupt shadow after STI / MOV SS / POP SS / LSS-SS.
    inhibit_irq_one_instruction: bool = false,
    /// Halted (HLT). Serializable.
    halted: bool = false,
    /// Shutdown latched (triple fault). The machine handles reset.
    shutdown: bool = false,
    /// NMI input latched (edge). Serializable.
    nmi_latched: bool = false,
    /// NMI currently in service (blocks nested NMI until IRET).
    nmi_in_service: bool = false,
    /// Nesting depth of in-progress fault delivery (double/triple-fault logic).
    fault_nesting: u8 = 0,
    /// A fault recorded by a helper, pending delivery at the boundary (D10).
    pending_fault: ?PendingFault = null,

    /// The most recent IVT delivery (any class: software INT, hardware IRQ, NMI,
    /// or exception). Read-only architectural breadcrumb for the debugger's
    /// interrupt-vector breakpoints (M1 Phase 4) — NOT consulted on the execution
    /// path. `seq` is a monotonic delivery counter so a between-steps observer can
    /// tell a fresh delivery from a stale one; `at_cycle` is the ledger value at
    /// delivery. Serialized in `State` (round-trips), reset in `reset()`. Default
    /// = "no delivery yet" (seq 0).
    last_delivered: LastDelivered = .{},

    // ---- Determinism ledger ----
    /// Monotonic cycle counter. Pure function of (state, inputs, schedule).
    cycles: u64 = 0,

    /// 386 power-on reset state (Intel 386 PRM §reset; cross-checked CPU_Init).
    pub fn reset(self: *State) void {
        self.* = .{};
        // EIP = 0xFFF0; CS selector 0xF000 but base held high (386 reset quirk)
        // until the first far jump reloads CS.
        self.eip = 0x0000FFF0;
        self.selector[@intFromEnum(Seg.cs)] = 0xF000;
        self.seg_base[@intFromEnum(Seg.cs)] = 0xFFFF0000;
        // Every segment limit set to 0xFFFF ONLY here, never on a segment load.
        self.seg_limit = @splat(0xFFFF);
        // EFLAGS reset value = 0x00000002 (reserved bit 1 = 1).
        self.eflags = flags.Flags.fromU32(0x00000002);
        // Real mode, CR0 = 0 (PE=0).
        self.cr0 = 0;
        // IDTR: real-mode IVT default base 0, limit 0x3FF.
        self.idtr_base = 0;
        self.idtr_limit = 0x3FF;
        self.gdtr_base = 0;
        self.gdtr_limit = 0;
        self.cycles = 0;
    }

    // ---- GP register accessors honoring AX/AH/AL aliasing (Phase 1b) ----

    pub inline fn getReg32(self: *const State, r: u3) u32 {
        return self.regs[r].dword;
    }
    pub inline fn setReg32(self: *State, r: u3, v: u32) void {
        self.regs[r].dword = v;
    }
    pub inline fn getReg16(self: *const State, r: u3) u16 {
        return self.regs[r].word[0];
    }
    pub inline fn setReg16(self: *State, r: u3, v: u16) void {
        self.regs[r].word[0] = v;
    }
    /// 8-bit register encoding: 0-3 = AL,CL,DL,BL (low byte of regs 0-3);
    /// 4-7 = AH,CH,DH,BH (high byte of regs 0-3).
    pub inline fn getReg8(self: *const State, r: u3) u8 {
        if (r < 4) return self.regs[r].byte[0];
        return self.regs[r - 4].byte[1];
    }
    pub inline fn setReg8(self: *State, r: u3, v: u8) void {
        if (r < 4) {
            self.regs[r].byte[0] = v;
        } else {
            self.regs[r - 4].byte[1] = v;
        }
    }

    // ---- NMI input ----
    pub inline fn nmi_pending(self: *const State) bool {
        return self.nmi_latched;
    }
    pub inline fn clearNmi(self: *State) void {
        self.nmi_latched = false;
    }

    // ---- Mode helpers ----
    pub inline fn isProtected(self: *const State) bool {
        return (self.cr0 & 0x1) != 0; // CR0.PE
    }
    pub inline fn isPaging(self: *const State) bool {
        return (self.cr0 & 0x80000000) != 0; // CR0.PG
    }
};

// Lock the hot layout sizes (memory-and-performance.md §5c).
comptime {
    std.debug.assert(@sizeOf(@FieldType(State, "regs")) == 32);
    std.debug.assert(@sizeOf(@FieldType(State, "seg_base")) == 24);
    std.debug.assert(@sizeOf(@FieldType(State, "seg_limit")) == 24);
}

test "reset puts CPU in documented 386 power-on state" {
    var s: State = undefined;
    s.reset();
    try std.testing.expectEqual(@as(u32, 0xFFF0), s.eip);
    try std.testing.expectEqual(@as(u16, 0xF000), s.selector[@intFromEnum(Seg.cs)]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), s.seg_base[@intFromEnum(Seg.cs)]);
    for (s.seg_limit) |l| try std.testing.expectEqual(@as(u32, 0xFFFF), l);
    try std.testing.expectEqual(@as(u32, 0x00000002), s.eflags.toU32());
    try std.testing.expectEqual(@as(u32, 0), s.cr0);
    try std.testing.expectEqual(@as(u16, 0x3FF), s.idtr_limit);
    try std.testing.expectEqual(@as(u64, 0), s.cycles);
    for (s.regs) |r| try std.testing.expectEqual(@as(u32, 0), r.dword);
}

test "GP register aliasing AL/AH/AX/EAX" {
    var s: State = .{};
    s.setReg32(@intFromEnum(Reg32.eax), 0x11223344);
    try std.testing.expectEqual(@as(u16, 0x3344), s.getReg16(@intFromEnum(Reg32.eax)));
    try std.testing.expectEqual(@as(u8, 0x44), s.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x33), s.getReg8(4)); // AH
    s.setReg8(4, 0xFF); // AH = 0xFF
    try std.testing.expectEqual(@as(u32, 0x1122FF44), s.getReg32(@intFromEnum(Reg32.eax)));
    s.setReg8(0, 0x00); // AL = 0
    try std.testing.expectEqual(@as(u32, 0x1122FF00), s.getReg32(@intFromEnum(Reg32.eax)));
}
