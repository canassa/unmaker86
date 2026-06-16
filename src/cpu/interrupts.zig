//! Real-mode interrupt/exception model (Phase 5) and the run loop's single
//! instruction-boundary checkpoint `serviceInterrupts()` (Theme G).
//!
//! Priority order at a boundary:
//!   1. pending fault / abort (raised by the just-executed instruction)
//!   2. TF single-step trap (#DB)
//!   3. NMI
//!   4. maskable IRQ (modulo the one-instruction inhibit / interrupt shadow)
//!
//! Delivery uses the real-mode IVT sequence: vector*4 -> IP:CS; push FLAGS, CS,
//! IP (16-bit each, in that order on the SS stack); clear IF and TF.

const std = @import("std");
const state = @import("state.zig");
const cycles = @import("cycles.zig");
const dispatch = @import("dispatch.zig");
const StepResult = state.StepResult;
const StopReason = state.StopReason;
const Seg = state.Seg;
const FaultClass = state.FaultClass;

// Architectural exception vectors (real-mode-relevant).
pub const VEC_DE: u8 = 0; // divide error (fault)
pub const VEC_DB: u8 = 1; // debug (trap/fault)
pub const VEC_NMI: u8 = 2;
pub const VEC_BP: u8 = 3; // INT3 (trap)
pub const VEC_OF: u8 = 4; // INTO (trap)
pub const VEC_BR: u8 = 5; // BOUND (fault)
pub const VEC_UD: u8 = 6; // invalid opcode (fault)
pub const VEC_NM: u8 = 7; // device not available (fault)
pub const VEC_DF: u8 = 8; // double fault (abort)
pub const VEC_SS: u8 = 12; // stack-segment fault
pub const VEC_GP: u8 = 13; // general protection fault

/// Class of a given exception vector (Phase 6 EIP semantics).
pub fn classOf(vector: u8) FaultClass {
    return switch (vector) {
        VEC_BP, VEC_OF => .trap,
        VEC_DF => .abort,
        else => .fault,
    };
}

/// The primitive step() (D11). Snapshots the instruction start, executes one
/// instruction (or delivers a pending boundary event), and returns the result.
pub fn step(cpu: anytype) StepResult {
    const start_cycles = cpu.st.cycles;

    if (cpu.st.shutdown) {
        return .{ .cycles_consumed = 0, .stop_reason = .shutdown };
    }

    // Halted: report halted with idle-to-next-event; the machine fast-forwards.
    if (cpu.st.halted) {
        // Recognize a wake event: a pending interrupt clears HLT.
        if (wakeable(cpu)) {
            cpu.st.halted = false;
        } else {
            const next = cpu.sched.nextEventCycle();
            const idle = if (next > cpu.st.cycles) next - cpu.st.cycles else 0;
            return .{ .cycles_consumed = idle, .stop_reason = .halted };
        }
    }

    cpu.instr_start_eip = cpu.st.eip;
    const shadow_was_set = cpu.st.inhibit_irq_one_instruction;
    // TF as seen at the START of this instruction. The single-step #DB is a TRAP
    // recognized only when TF was ALREADY set entering the instruction — an
    // instruction that newly SETS TF (POPF / IRET popping a FLAGS image with TF=1,
    // or a flag store) does NOT itself trap; the trap is deferred to the next
    // instruction. (Intel SDM Vol 3, "Single-Step Trap": TF is checked at the
    // instruction boundary against its value before the instruction.) Without this,
    // a do-nothing INT 1 handler that IRETs with TF still set re-triggers #DB on
    // its own IRET boundary forever (Stunts LOAD.EXE single-step timing loop).
    // Mirrors DOSBox-x's `cpu.trap_skip` (core_normal.cpp:228-231).
    const tf_at_start = cpu.st.eflags.tf;

    // Execute one instruction. Faults are recorded in pending_fault and surface
    // as error.Fault; the dispatcher catches and we deliver below.
    dispatch.executeOne(cpu) catch {
        // Roll EIP back for faults (restartable); traps already advanced EIP.
        if (cpu.st.pending_fault) |pf| {
            if (pf.class == .fault) cpu.st.eip = cpu.instr_start_eip;
        }
    };

    // The interrupt shadow lasts exactly one instruction.
    if (shadow_was_set) cpu.st.inhibit_irq_one_instruction = false;

    // Instruction-boundary checkpoint.
    const stop = serviceInterrupts(cpu, tf_at_start);

    // By-construction guard (Phase 1a / Theme E): every executed instruction
    // charges at least its table base cost. HLT/shutdown returned earlier.
    std.debug.assert(cpu.st.cycles > start_cycles);
    return .{ .cycles_consumed = cpu.st.cycles - start_cycles, .stop_reason = stop };
}

/// True if a pending event would wake a halted CPU.
fn wakeable(cpu: anytype) bool {
    if (cpu.st.pending_fault != null) return true;
    // NMI always wakes.
    // A maskable IRQ wakes only if IF=1 (HLT with IF=0 waits for NMI/reset).
    if (cpu.st.eflags.iff) {
        if (cpu.pic.getPendingInterrupt() != null) return true;
    }
    return false;
}

/// The single instruction-boundary checkpoint (Theme G). Applies the fixed
/// priority order and delivers at most one event per boundary. `tf_at_start` is
/// the TF flag as it stood entering the just-executed instruction; the
/// single-step #DB fires only when TF was already set then (see `step`).
pub fn serviceInterrupts(cpu: anytype, tf_at_start: bool) StopReason {
    // 1. Pending fault from the just-executed instruction.
    if (cpu.st.pending_fault) |pf| {
        cpu.st.pending_fault = null;
        deliverException(cpu, pf.vector, pf.class, pf.error_code) catch {
            // A fault during delivery escalates (double/triple fault).
            return escalate(cpu);
        };
        cpu.st.fault_nesting = 0;
        if (cpu.st.shutdown) return .shutdown;
        return .normal;
    }

    // The one-instruction inhibit suppresses recognition this boundary.
    if (cpu.st.inhibit_irq_one_instruction) return .normal;

    // 2. TF single-step trap (#DB) — delivered after the instruction (trap), but
    //    only if TF was set ENTERING it. An instruction that newly set TF (POPF/
    //    IRET/flag store) defers the trap one instruction, so a TF-restoring IRET
    //    does not immediately re-trap on its own boundary.
    if (tf_at_start and cpu.st.eflags.tf) {
        deliverException(cpu, VEC_DB, .trap, null) catch {
            return escalate(cpu);
        };
        return .normal;
    }

    // 3. NMI (non-maskable; nested-NMI blocked until IRET).
    if (cpu.st.nmi_pending() and !cpu.st.nmi_in_service) {
        cpu.st.clearNmi();
        cpu.st.nmi_in_service = true;
        deliverInterrupt(cpu, VEC_NMI) catch {
            return escalate(cpu);
        };
        return .normal;
    }

    // 4. Maskable IRQ (IF-gated, via the 8259 handshake).
    if (cpu.st.eflags.iff) {
        if (cpu.pic.getPendingInterrupt()) |vector| {
            cpu.pic.ackIrq(vector);
            cpu.st.cycles += cycles.interrupt_delivery;
            deliverInterrupt(cpu, vector) catch {
                return escalate(cpu);
            };
            return .normal;
        }
    }

    return .normal;
}

/// Escalate a fault-during-delivery to double/triple fault.
fn escalate(cpu: anytype) StopReason {
    cpu.st.fault_nesting += 1;
    if (cpu.st.fault_nesting >= 2) {
        // Fault during #DF delivery => triple fault => shutdown.
        cpu.st.shutdown = true;
        cpu.sched_onShutdown();
        return .shutdown;
    }
    // First escalation: deliver #DF.
    cpu.st.pending_fault = null;
    deliverException(cpu, VEC_DF, .abort, 0) catch {
        cpu.st.shutdown = true;
        cpu.sched_onShutdown();
        return .shutdown;
    };
    return .normal;
}

/// Deliver a CPU exception. EIP semantics already applied by caller (fault =
/// rolled back, trap = advanced). No error code pushed in real mode.
pub fn deliverException(cpu: anytype, vector: u8, class: FaultClass, error_code: ?u32) !void {
    _ = class;
    _ = error_code;
    cpu.st.cycles += cycles.fault_delivery;
    try deliverViaIvt(cpu, vector);
}

/// Deliver a hardware/software interrupt via the IVT.
pub fn deliverInterrupt(cpu: anytype, vector: u8) !void {
    try deliverViaIvt(cpu, vector);
}

/// The real-mode IVT delivery sequence (the only delivery path in scope).
pub fn deliverViaIvt(cpu: anytype, vector: u8) !void {
    // IDTR.limit enforcement (Theme D): vector*4 + 3 must be within the limit.
    const entry: u32 = @as(u32, vector) * 4;
    if (entry + 3 > cpu.st.idtr_limit) {
        // Limit-exceeded during delivery escalates via the contributory path;
        // we signal a fault that the caller's catch turns into escalation.
        return cpu.raiseFault(VEC_GP, .fault, 0);
    }
    const new_ip = cpu.readLinear16(cpu.st.idtr_base +% entry);
    const new_cs = cpu.readLinear16(cpu.st.idtr_base +% entry +% 2);

    // Push FLAGS, CS, IP (16-bit each) on the SS stack.
    const flags16: u16 = @truncate(cpu.st.eflags.toU32());
    try pushWord(cpu, flags16);
    try pushWord(cpu, cpu.st.selector[@intFromEnum(Seg.cs)]);
    try pushWord(cpu, @truncate(cpu.st.eip));

    // Clear IF and TF (interrupt routine entered with interrupts disabled).
    cpu.st.eflags.iff = false;
    cpu.st.eflags.tf = false;

    // Load CS:IP from the IVT entry (real-mode far load).
    cpu.loadSegment(.cs, new_cs);
    cpu.st.eip = new_ip;

    // Record the delivery breadcrumb (M1 Phase 4 — interrupt-vector breakpoints).
    // Every IVT delivery funnels through here (software INT via exec_ctrl, hardware
    // IRQ/NMI via serviceInterrupts, exceptions via deliverException), so this is
    // the single faithful chokepoint. Set ONLY after a successful far load (a
    // limit-exceeded delivery returned above before reaching here). This is a
    // read-only debugger aid; it does not affect the execution path or cost.
    cpu.st.last_delivered = .{
        .vector = vector,
        .at_cycle = cpu.st.cycles,
        .seq = cpu.st.last_delivered.seq + 1,
    };
}

/// Push a 16-bit word using SP (real mode stack width = 16-bit).
pub fn pushWord(cpu: anytype, v: u16) !void {
    const sp = cpu.st.getReg16(@intFromEnum(state.Reg32.esp));
    const new_sp = sp -% 2;
    try cpu.segWrite16(.ss, new_sp, v);
    cpu.st.setReg16(@intFromEnum(state.Reg32.esp), new_sp);
}

/// Pop a 16-bit word using SP.
pub fn popWord(cpu: anytype) !u16 {
    const sp = cpu.st.getReg16(@intFromEnum(state.Reg32.esp));
    const v = try cpu.segRead16(.ss, sp);
    cpu.st.setReg16(@intFromEnum(state.Reg32.esp), sp +% 2);
    return v;
}

test "classOf" {
    try std.testing.expectEqual(FaultClass.trap, classOf(VEC_BP));
    try std.testing.expectEqual(FaultClass.fault, classOf(VEC_GP));
    try std.testing.expectEqual(FaultClass.abort, classOf(VEC_DF));
}
