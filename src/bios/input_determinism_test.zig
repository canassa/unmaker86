//! Input-injection determinism tests for the keyboard POLLING path (input Phase
//! 1f). These prove the prime directive for injected keys: the same command
//! sequence (inject scancode(s) + run-to-cycle) reaches byte-identical machine
//! state across two fresh runs — the injection is keyed to a deterministic command
//! boundary (Model A), never to host time. Also covers the 8042-FIFO-full error
//! path and a black-box INT 16h read-back of an injected key (the AH=01/00 host
//! path), plus a grep audit that the new int09/scancodes sources stay host-clock-
//! and float-free.
//!
//! The blocking-read round-trip (Phase 1d, the guest-asm INT 16h poll loop) IS
//! here too — the three "blocking INT 16h AH=00" tests below prove a guest that
//! BLOCKS on an empty ring (a) keeps emulated time ADVANCING during the wait
//! (timer ticks, cycles climb — never frozen, §0.1), (b) UNBLOCKS deterministically
//! when a scancode + IRQ1 is injected, and (c) reaches byte-identical state across
//! two identical inject sequences (the determinism proof).

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const debug = @import("debug");
const bda_mod = @import("bios").Bda;

const Machine = machine_mod.Machine;
const Cpu = machine_mod.Cpu;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

const CODE_SEG: u16 = 0x2000;

fn boot(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

/// STI ; JMP $ — a poll loop with interrupts enabled so an injected IRQ1 is
/// recognized through the normal fetch/execute loop (no HLT fast-forward skip).
fn loadIdle(m: *Machine) void {
    const code = [_]u8{ 0xFB, 0xEB, 0xFE };
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, CODE_SEG);
    m.cpu.loadSegment(.es, CODE_SEG);
    m.cpu.st.eflags.iff = true;
}

/// Drive the SAME command log (inject 'a', then run to cycle N) on a fresh machine
/// and return it for snapshot comparison. The injection enters at the controller
/// (Model A) at the deterministic command boundary; the guest INT 09h ISR delivers
/// it during the subsequent run.
fn driveSequence(alloc: std.mem.Allocator) !*Machine {
    const m = try boot(alloc);
    loadIdle(m);
    var c = Controller.init(m);
    // Command 1: inject 'a' make (scancode 0x1E) at the controller + raise IRQ1.
    try std.testing.expect(c.injectScancode(0x1E, true, false));
    // Command 2: run to a fixed cycle. The ISR runs, cooks the word, fills the ring.
    _ = c.runToCycle(200_000) catch unreachable;
    return m;
}

test "byte-identical machine state across two identical inject+run sequences" {
    const alloc = std.testing.allocator;

    const m1 = try driveSequence(alloc);
    defer destroy(alloc, m1);
    const snap1 = m1.snapshot();
    const ram1 = try alloc.dupe(u8, m1.bus.ram);
    defer alloc.free(ram1);

    const m2 = try driveSequence(alloc);
    defer destroy(alloc, m2);
    const snap2 = m2.snapshot();

    // Identical CPU state (byte-compared — the State has an untagged reg union).
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snap1.cpu_state), std.mem.asBytes(&snap2.cpu_state));
    // Identical device + scheduler + keyboard-controller state.
    try std.testing.expectEqualDeep(snap1.pic, snap2.pic);
    try std.testing.expectEqualDeep(snap1.pit, snap2.pit);
    try std.testing.expectEqualDeep(snap1.kbd, snap2.kbd);
    try std.testing.expectEqualDeep(snap1.sched, snap2.sched);
    // Byte-identical RAM (incl. the BDA keyboard ring + shift flags the ISR wrote).
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);

    // And the cooked word actually landed (the run did the real work).
    const bda = bda_mod(Cpu).init(&m2.cpu);
    try std.testing.expectEqual(@as(?u16, 0x1E61), bda.kbPeek());
}

test "8042 FIFO-full injection returns false (no silent drop)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer destroy(alloc, m);
    var c = Controller.init(m);
    // Without running (so the controller never drains via INT 09h), the output FIFO
    // fills. The inject that overflows it returns false — surfaced as input_buffer_full.
    var saw_full = false;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        if (!c.injectScancode(0x1E, true, false)) {
            saw_full = true;
            break;
        }
    }
    try std.testing.expect(saw_full);
}

test "black-box: a guest INT 16h read returns the injected key after inject+run" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer destroy(alloc, m);

    // Guest: STI ; (poll) INT 16h AH=01 until ZF=0, then AH=00 read, HLT.
    //   FB            STI
    //   B4 01         MOV AH,1
    //   CD 16         INT 16h        ; check keystroke (peek)
    //   74 FA         JZ  -6         ; if empty, loop back to MOV AH,1
    //   B4 00         MOV AH,0
    //   CD 16         INT 16h        ; get keystroke (dequeue) -> AX
    //   F4            HLT
    const code = [_]u8{ 0xFB, 0xB4, 0x01, 0xCD, 0x16, 0x74, 0xFA, 0xB4, 0x00, 0xCD, 0x16, 0xF4 };
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, CODE_SEG);
    m.cpu.loadSegment(.es, CODE_SEG);
    m.cpu.st.eflags.iff = true;

    var c = Controller.init(m);
    // Inject 'a' at the controller (Model A) BEFORE the run; the guest poll loop +
    // INT 09h ISR deliver it. AH=01 then sees the key and AH=00 dequeues it.
    try std.testing.expect(c.injectScancode(0x1E, true, false));

    const Pred = struct {
        fn halted(mm: *Machine) bool {
            return mm.cpu.st.halted;
        }
    };
    _ = m.runUntil(Pred.halted, 2_000_000);
    // AX = the cooked word for 'a'.
    try std.testing.expectEqual(@as(u16, 0x1E61), m.cpu.st.getReg16(0));
}

/// Load `MOV AH,0 ; INT 16h ; HLT` at CODE_SEG:0 — a guest that issues a BLOCKING
/// INT 16h AH=00 GET KEYSTROKE on an (empty) ring, so it spins in the guest-asm
/// poll loop until a key arrives, then halts. AX after HLT == the cooked word.
fn loadBlockingGet(m: *Machine) void {
    //   B4 00   MOV AH,0
    //   CD 16   INT 16h     ; blocking GET -> the hybrid poll loop
    //   F4      HLT
    const code = [_]u8{ 0xB4, 0x00, 0xCD, 0x16, 0xF4 };
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, CODE_SEG);
    m.cpu.loadSegment(.es, CODE_SEG);
    m.cpu.st.eflags.iff = true;
}

test "blocking INT 16h AH=00 advances emulated time while waiting (never frozen)" {
    // §0.1: a real blocking AH=00 spins WITH INTERRUPTS ENABLED; emulated time must
    // advance during the wait (cycles climb, IRQ0/the BDA tick fires). Prove it:
    // run the blocking program WITHOUT injecting and confirm it is STILL spinning
    // (not halted) after a fixed cycle budget, that the cycle ledger MOVED, and that
    // the timer ticked — i.e. the wait is the guest poll loop, not a frozen clock.
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer destroy(alloc, m);
    loadBlockingGet(m);

    const bda = bda_mod(Cpu).init(&m.cpu);
    const tick0 = bda.tickCount();
    const cyc0 = m.cpu.st.cycles;

    var c = Controller.init(m);
    // No inject: the ring stays empty, so the poll loop spins. runToCycle returns
    // when the budget is hit (the program never halts on its own).
    _ = c.runToCycle(cyc0 + 5_000_000) catch unreachable;

    // The program is STILL inside the blocking read (not halted) — it genuinely
    // blocked, it did not fall through with a fake AX=0.
    try std.testing.expect(!m.cpu.st.halted);
    // Emulated time ADVANCED during the wait: cycles climbed (the loop ran real
    // guest instructions) and the timer ticked (IRQ0 fired through the loop's
    // STI-enabled window). NOT a frozen clock.
    try std.testing.expect(m.cpu.st.cycles > cyc0);
    try std.testing.expect(bda.tickCount() > tick0);
}

/// Drive the SAME Phase-1d command log on a fresh machine: load the blocking
/// AH=00 program, inject 'a' (Model A, while paused), run to completion. Returns
/// the machine so two runs can be snapshot-compared (the determinism proof).
fn driveBlockingSequence(alloc: std.mem.Allocator) !*Machine {
    const m = try boot(alloc);
    loadBlockingGet(m);
    var c = Controller.init(m);
    // Inject 'a' (scancode 0x1E) at the controller + raise IRQ1, while paused.
    try std.testing.expect(c.injectScancode(0x1E, true, false));
    const Pred = struct {
        fn halted(mm: *Machine) bool {
            return mm.cpu.st.halted;
        }
    };
    // Run to completion: the poll loop's INT 09h ISR cooks the injected scancode,
    // has-key then sees it, dequeue sets AX, IRET, HLT.
    _ = m.runUntil(Pred.halted, 5_000_000);
    return m;
}

test "blocking INT 16h AH=00 unblocks on an injected key, byte-identical x2" {
    const alloc = std.testing.allocator;

    const m1 = try driveBlockingSequence(alloc);
    defer destroy(alloc, m1);
    // The block resolved: the program halted and AX == the cooked word for 'a'.
    try std.testing.expect(m1.cpu.st.halted);
    try std.testing.expectEqual(@as(u16, 0x1E61), m1.cpu.st.getReg16(0));

    const snap1 = m1.snapshot();
    const ram1 = try alloc.dupe(u8, m1.bus.ram);
    defer alloc.free(ram1);

    const m2 = try driveBlockingSequence(alloc);
    defer destroy(alloc, m2);
    const snap2 = m2.snapshot();

    // Determinism proof: identical CPU + device + scheduler + RAM state, INCLUDING
    // the exact cycle at which the loop exited (cpu_state holds cpu.st.cycles).
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snap1.cpu_state), std.mem.asBytes(&snap2.cpu_state));
    try std.testing.expectEqualDeep(snap1.pic, snap2.pic);
    try std.testing.expectEqualDeep(snap1.pit, snap2.pit);
    try std.testing.expectEqualDeep(snap1.kbd, snap2.kbd);
    try std.testing.expectEqualDeep(snap1.sched, snap2.sched);
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);
}

test "grep: new int09/scancodes/bda sources are host-clock + float free" {
    // Mirrors the src/bios determinism gate, asserting the Phase-1 additions stay
    // clean (the gate in determinism_test.zig embeds the whole BIOS surface; this is
    // a focused redundant check the polling additions don't regress).
    const sources = [_][]const u8{
        @embedFile("int09.zig"),
        @embedFile("scancodes.zig"),
        @embedFile("bda.zig"),
    };
    const forbidden = [_][]const u8{
        "f32",        "f64",      "std.time",   "nanoTimestamp",
        "std.Random", "std.rand", "std.Thread", "getenv",
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) return error.ForbiddenHostDependence;
        }
    }
}
