//! Milestone integration test (Phase 7) — the deterministic timer-tick
//! regression. A tiny real-mode program programs PIT ch0, unmasks IRQ0, STI;HLT,
//! takes a timer IRQ through the PIC, the ISR increments a tick counter + sends
//! EOI + IRETs. Asserted: run-to-cycle-N-twice -> byte-identical (CLAUDE #6),
//! IRQ-arrives-at-deterministic-cycle, HLT-fast-forward end-to-end, reprogram to a
//! faster tick (the cancel/re-arm path BaK uses), and snapshot-mid-run round-trip.

const std = @import("std");
const machine = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine.Machine;
const StopReason = machine.StopReason;
const Seg = cpu_mod.Seg;

/// Compare two CPU States byte-for-byte (GenReg32 is an untagged union; the whole
/// State is plain serializable bytes — CLAUDE #6).
fn expectStateEqual(a: cpu_mod.State, b: cpu_mod.State) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

// Memory layout for the test program (real-mode segment 0).
const ISR_ADDR: u32 = 0x0400; // ISR body
const MAIN_ADDR: u32 = 0x0500; // main program
const TICK_COUNTER: u32 = 0x0600; // word: ticks taken
const STACK_TOP: u16 = 0x7000;

/// Install the test program + IVT entry for INT 08h (master IRQ0 vector). Uses a
/// reprogrammed FASTER tick (mode 2, reload 20) — the cancel/re-arm path.
fn loadProgram(m: *Machine) void {
    const b = &m.bus;

    // IVT[0x08] -> ISR at 0000:ISR_ADDR (IP then CS, each 16-bit).
    b.writePhys16(0x08 * 4, @intCast(ISR_ADDR));
    b.writePhys16(0x08 * 4 + 2, 0x0000);

    // ISR: INC word [TICK_COUNTER]; MOV AL,0x20; OUT 0x20,AL; IRET.
    //   FF 06 00 06   INC word [0x0600]
    //   B0 20         MOV AL, 0x20
    //   E6 20         OUT 0x20, AL    (non-specific EOI to master)
    //   CF            IRET
    const isr = [_]u8{ 0xFF, 0x06, 0x00, 0x06, 0xB0, 0x20, 0xE6, 0x20, 0xCF };
    for (isr, 0..) |byte, i| b.writePhys8(ISR_ADDR + @as(u32, @intCast(i)), byte);

    // Main: set up segments + stack, program PIT ch0 to a fast tick, unmask IRQ0,
    // STI, then a HLT loop.
    //   FA            CLI
    //   B0 34         MOV AL, 0x34       ; ch0, lohi, mode 2
    //   E6 43         OUT 0x43, AL
    //   B0 14         MOV AL, 0x14       ; reload LSB = 20
    //   E6 40         OUT 0x40, AL
    //   B0 00         MOV AL, 0x00       ; reload MSB = 0  -> reload 20
    //   E6 40         OUT 0x40, AL
    //   E4 21         IN  AL, 0x21       ; read master IMR
    //   24 FE         AND AL, 0xFE       ; unmask IRQ0
    //   E6 21         OUT 0x21, AL
    //   FB            STI
    //   F4            HLT                ; wait for the timer IRQ
    //   EB FD         JMP $-1 (back to HLT) -> after IRET, HLT again
    const main = [_]u8{
        0xFA,
        0xB0, 0x34, 0xE6, 0x43,
        0xB0, 0x14, 0xE6, 0x40,
        0xB0, 0x00, 0xE6, 0x40,
        0xE4, 0x21, 0x24, 0xFE, 0xE6, 0x21,
        0xFB,
        0xF4,
        0xEB, 0xFD,
    };
    for (main, 0..) |byte, i| b.writePhys8(MAIN_ADDR + @as(u32, @intCast(i)), byte);
}

fn setupAndRun(m: *Machine, n: u64) StopReason {
    m.programDefaultPic(); // BIOS-POST stand-in: master 0x08, slave 0x70, cascade
    loadProgram(m);
    // Point the CPU at the main program (real-mode segment 0).
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.loadSegment(.es, 0);
    m.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), STACK_TOP);
    m.cpu.st.eip = MAIN_ADDR;
    // IVT base/limit are real-mode defaults (base 0, limit 0x3FF) from reset.
    return m.runCycles(n);
}

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}

test "deterministic timer-tick: run-to-cycle-N twice is byte-identical" {
    const alloc = std.testing.allocator;
    const N: u64 = 50_000; // spans several 20-tick (240-cycle) timer periods

    const m1 = try makeMachine(alloc);
    defer {
        m1.deinit();
        alloc.destroy(m1);
    }
    _ = setupAndRun(m1, N);
    const snap1 = m1.snapshot();
    const ram1 = try alloc.dupe(u8, m1.bus.ram);
    defer alloc.free(ram1);

    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    _ = setupAndRun(m2, N);
    const snap2 = m2.snapshot();

    // Byte-identical CPU state, PIC, PIT, scheduler.
    try expectStateEqual(snap1.cpu_state, snap2.cpu_state);
    try std.testing.expectEqualDeep(snap1.pic, snap2.pic);
    try std.testing.expectEqualDeep(snap1.pit, snap2.pit);
    try std.testing.expectEqualDeep(snap1.sched, snap2.sched);
    // Byte-identical RAM (incl. the tick counter).
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);

    // The ISR actually ran several times (the timer path is alive, not idle).
    const ticks = m1.bus.readPhys16(TICK_COUNTER);
    try std.testing.expect(ticks > 1);
}

test "IRQ arrives at a deterministic cycle across two runs" {
    const alloc = std.testing.allocator;

    // Helper: run until the tick counter first becomes 1, recording cpu.st.cycles.
    const Capture = struct {
        fn firstTickCycle(mm: *Machine) u64 {
            // Step until the ISR has incremented the counter once.
            var guard: usize = 0;
            while (mm.bus.readPhys16(TICK_COUNTER) == 0 and guard < 100_000) : (guard += 1) {
                const out = mm.step();
                if (!out.cont) break;
            }
            return mm.cpu.st.cycles;
        }
    };

    const m1 = try makeMachine(alloc);
    defer {
        m1.deinit();
        alloc.destroy(m1);
    }
    m1.programDefaultPic();
    loadProgram(m1);
    m1.cpu.loadSegment(.cs, 0);
    m1.cpu.loadSegment(.ds, 0);
    m1.cpu.loadSegment(.ss, 0);
    m1.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), STACK_TOP);
    m1.cpu.st.eip = MAIN_ADDR;
    const c1 = Capture.firstTickCycle(m1);

    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    m2.programDefaultPic();
    loadProgram(m2);
    m2.cpu.loadSegment(.cs, 0);
    m2.cpu.loadSegment(.ds, 0);
    m2.cpu.loadSegment(.ss, 0);
    m2.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), STACK_TOP);
    m2.cpu.st.eip = MAIN_ADDR;
    const c2 = Capture.firstTickCycle(m2);

    try std.testing.expect(c1 > 0);
    try std.testing.expectEqual(c1, c2); // deterministic recognition cycle
}

test "STI-shadow straddle: IRQ recognition slips exactly one instruction (M-D6)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    m.bus.portOut8(0x21, 0xFE); // unmask IRQ0

    // ISR records the RETURN address (the pushed IP = the interrupted EIP) so we
    // can prove WHICH instruction boundary recognized the IRQ. The real-mode IVT
    // push order is FLAGS, CS, IP — so IP is at the lowest address = [SP] = [BP+0].
    // ISR: MOV BP,SP; MOV AX,[BP]; MOV [0x0600],AX; MOV AL,0x20; OUT 0x20,AL; HLT.
    //   89 E5            MOV BP, SP
    //   8B 46 00         MOV AX, [BP+0]   (the pushed IP)
    //   A3 00 06         MOV [0x0600], AX
    //   B0 20            MOV AL, 0x20
    //   E6 20            OUT 0x20, AL
    //   F4               HLT
    const isr = [_]u8{ 0x89, 0xE5, 0x8B, 0x46, 0x00, 0xA3, 0x00, 0x06, 0xB0, 0x20, 0xE6, 0x20, 0xF4 };
    for (isr, 0..) |byte, i| m.bus.writePhys8(ISR_ADDR + @as(u32, @intCast(i)), byte);
    m.bus.writePhys16(0x08 * 4, @intCast(ISR_ADDR));
    m.bus.writePhys16(0x08 * 4 + 2, 0x0000);

    // Main program at 0:0x0500. IRQ0 is raised (pending) BEFORE STI; IF starts 0.
    //   FB        STI        ; sets IF + the one-instruction shadow
    //   90        NOP        ; shadow still active across THIS instruction's boundary
    //   90        NOP        ; recognition happens at or before here
    //   F4        HLT
    const prog = [_]u8{ 0xFB, 0x90, 0x90, 0xF4 };
    for (prog, 0..) |byte, i| m.bus.writePhys8(MAIN_ADDR + @as(u32, @intCast(i)), byte);

    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), STACK_TOP);
    m.cpu.st.eip = MAIN_ADDR;
    m.cpu.st.eflags.iff = false;
    m.pic.raiseIrq(0); // pending before STI

    _ = m.runCycles(2_000);

    // The pushed return IP is the EIP at the boundary where the IRQ was recognized.
    // With the STI shadow, recognition is INHIBITED at the boundary right after STI
    // (which would have given return IP = MAIN_ADDR+1, before the first NOP). The
    // shadow forces it to slip exactly one instruction: the first NOP executes
    // (eip -> MAIN_ADDR+2), THEN the IRQ is recognized -> pushed IP = MAIN_ADDR+2.
    // This is the correct IF=1 AND !inhibit rule (M-D6), not the naive "first
    // boundary >= fire_cycle".
    const pushed_ip = m.bus.readPhys16(TICK_COUNTER);
    try std.testing.expectEqual(@as(u16, @intCast(MAIN_ADDR + 2)), pushed_ip);
}

test "snapshot mid-run -> restore -> run-to-N byte-identical" {
    const alloc = std.testing.allocator;
    const MID: u64 = 5_000;
    const N: u64 = 50_000;

    // Reference run straight to N.
    const ref = try makeMachine(alloc);
    defer {
        ref.deinit();
        alloc.destroy(ref);
    }
    _ = setupAndRun(ref, N);
    const ref_snap = ref.snapshot();
    const ref_ram = try alloc.dupe(u8, ref.bus.ram);
    defer alloc.free(ref_ram);

    // Run to MID, snapshot, restore into a fresh machine, finish to N.
    const a = try makeMachine(alloc);
    defer {
        a.deinit();
        alloc.destroy(a);
    }
    _ = setupAndRun(a, MID);
    const mid_snap = a.snapshot();
    const mid_ram = try alloc.dupe(u8, a.bus.ram);
    defer alloc.free(mid_ram);

    const b = try makeMachine(alloc);
    defer {
        b.deinit();
        alloc.destroy(b);
    }
    // Re-register handlers in the same order (makeMachine's wire does this), then
    // restore the snapshot + RAM.
    b.restore(mid_snap);
    @memcpy(b.bus.ram, mid_ram);
    // Finish to N (runCycles uses an absolute target = current + n).
    _ = b.runCycles(N - b.cpu.st.cycles);

    const b_snap = b.snapshot();
    try expectStateEqual(ref_snap.cpu_state, b_snap.cpu_state);
    try std.testing.expectEqualDeep(ref_snap.pic, b_snap.pic);
    try std.testing.expectEqualDeep(ref_snap.pit, b_snap.pit);
    try std.testing.expectEqualDeep(ref_snap.sched, b_snap.sched);
    try std.testing.expectEqualSlices(u8, ref_ram, b.bus.ram);
}
