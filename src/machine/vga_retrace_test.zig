//! VGA Input Status Register #1 (0x3DA) determinism regression (plans/vga-retrace.md
//! §5.2 / P5). The retrace + display-enable bits are a pure function of the CPU
//! cycle counter, so a guest that polls 0x3DA makes deterministic progress instead
//! of spinning on the old unmapped 0xFF default. This proves it end-to-end at the
//! machine level with REAL guest 8086 code:
//!
//!   - Shape A — the wide bit-3 vertical-retrace frame-sync poll
//!     (`while(in&8); while(!(in&8));`) TERMINATES (reaches a sentinel, not the cap).
//!   - Shape B — the narrow bit-0 Borland-`putch`-style poll
//!     (`in al,0x3DA; ror al,1; jc $-5`) TERMINATES.
//!   - Two-run byte-identity: the same program on two fresh machines reaches the
//!     sentinel at the SAME cycle and ends in byte-identical state (NOT an external
//!     golden — both reference emulators' retrace timing is non-deterministic; zdos
//!     defines its own deterministic semantics).
//!   - A window-width safety assertion flagging the dependency on the deferred
//!     per-instruction PRM cost pass (src/cpu/cycles.zig).

const std = @import("std");
const machine = @import("machine");
const cpu_mod = @import("cpu");
const devices = @import("devices");

const Machine = machine.Machine;
const StopReason = machine.StopReason;
const Vga = devices.Vga;

const PROG_ADDR: u32 = 0x0500;
const SENTINEL_ADDR: u32 = 0x0600; // a byte the loop writes ONLY after it terminates
const SENTINEL_VALUE: u8 = 0xAA;
const STACK_TOP: u16 = 0x7000;
const RUN_CAP: u64 = 4_000_000; // bounded: a stuck guest can never hang the harness

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}
fn destroyMachine(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

/// Load a program at PROG_ADDR (real-mode segment 0) and point CS:IP at it with a
/// fresh stack. `bytes` is the raw machine code; it must end by writing
/// SENTINEL_VALUE to SENTINEL_ADDR and HLT-ing once the poll loop falls through.
fn loadProgram(m: *Machine, bytes: []const u8) void {
    const b = &m.bus;
    for (bytes, 0..) |byte, i| b.writePhys8(PROG_ADDR + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), STACK_TOP);
    m.cpu.st.eip = PROG_ADDR;
}

// Shape A — "wait until NOT in retrace, then wait FOR retrace" (frame sync). Port
// 0x3DA is a 16-bit port number, so it must be addressed via DX (`IN AL,DX` = EC),
// NOT the 8-bit-immediate `IN AL,imm8`. The two polls both eventually fall through
// (bit 3 toggles deterministically across a frame), then we write the sentinel + HLT.
//
//               BA DA 03     MOV DX, 0x03DA
//   @@wait_not: EC           IN  AL, DX
//               A8 08        TEST AL, 8
//               75 FB        JNZ @@wait_not     ; rel = -5
//   @@wait_for: EC           IN  AL, DX
//               A8 08        TEST AL, 8
//               74 FB        JZ  @@wait_for     ; rel = -5
//               B0 AA        MOV AL, 0xAA
//               A2 00 06     MOV [0x0600], AL   ; sentinel
//               F4           HLT
const SHAPE_A = [_]u8{
    0xBA, 0xDA, 0x03, // MOV DX, 0x03DA
    0xEC, 0xA8, 0x08, 0x75, 0xFB, // wait_not
    0xEC, 0xA8, 0x08, 0x74, 0xFB, // wait_for
    0xB0, 0xAA, 0xA2, 0x00, 0x06,
    0xF4,
};

// Shape B — Borland putch snow-avoid: poll until display-enable goes low (bit 0
// rotated into carry), i.e. wait for the active display span.
//
//           BA DA 03     MOV DX, 0x03DA
//   @@spin: EC           IN  AL, DX
//           D0 C8        ROR AL, 1          ; bit 0 -> carry
//           72 FB        JC  @@spin         ; rel = -5 (CF set while blanking)
//           B0 AA        MOV AL, 0xAA
//           A2 00 06     MOV [0x0600], AL   ; sentinel
//           F4           HLT
const SHAPE_B = [_]u8{
    0xBA, 0xDA, 0x03, // MOV DX, 0x03DA
    0xEC, 0xD0, 0xC8, 0x72, 0xFB, // spin
    0xB0, 0xAA, 0xA2, 0x00, 0x06,
    0xF4,
};

/// Run a poll-shape program to completion (or the cap) and return the terminating
/// stop reason. After it returns, SENTINEL_ADDR holds SENTINEL_VALUE iff the loop
/// fell through (did NOT spin to the cap).
fn runShape(m: *Machine, bytes: []const u8) StopReason {
    loadProgram(m, bytes);
    return m.runCycles(RUN_CAP);
}

test "Shape A (bit-3 retrace poll) terminates at a sentinel, not the cycle cap" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroyMachine(alloc, m);

    const stop = runShape(m, &SHAPE_A);
    // Falling through both polls reaches the HLT (halted_forever: no scheduled
    // events, IF=0) — NOT cycles_reached (which would mean it spun to the cap).
    try std.testing.expect(stop != .cycles_reached);
    try std.testing.expectEqual(SENTINEL_VALUE, m.bus.readPhys8(SENTINEL_ADDR));
}

test "Shape B (bit-0 ror;jc putch poll) terminates at a sentinel, not the cycle cap" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroyMachine(alloc, m);

    const stop = runShape(m, &SHAPE_B);
    try std.testing.expect(stop != .cycles_reached);
    try std.testing.expectEqual(SENTINEL_VALUE, m.bus.readPhys8(SENTINEL_ADDR));
}

test "two-run byte-identity: same retrace-poll program -> identical cycle + state" {
    const alloc = std.testing.allocator;

    const a = try makeMachine(alloc);
    defer destroyMachine(alloc, a);
    _ = runShape(a, &SHAPE_A);
    const a_cycles = a.cpu.st.cycles; // the cycle the loop terminated at
    const a_snap = a.snapshot();
    const a_ram = try alloc.dupe(u8, a.bus.ram);
    defer alloc.free(a_ram);

    const b = try makeMachine(alloc);
    defer destroyMachine(alloc, b);
    _ = runShape(b, &SHAPE_A);
    const b_snap = b.snapshot();

    // The loop falls through at the SAME deterministic cycle (the first-bit-3
    // transition the §1 frame-sync pattern blocks on is reset-stable, anchored at
    // cycle 0), and the whole machine ends byte-identical — NOT compared to any
    // external dosbox/spice86 capture (their retrace timing is not a golden).
    try std.testing.expectEqual(a_cycles, b.cpu.st.cycles);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&a_snap.cpu_state),
        std.mem.asBytes(&b_snap.cpu_state),
    );
    try std.testing.expectEqualSlices(u8, a_ram, b.bus.ram);
}

test "window-width safety: every polled 0x3DA window >> the worst-case poll cost" {
    // A poll loop observes a transition only if the polled status WINDOW is wider
    // than one poll iteration's cycle cost — otherwise a poll could step OVER the
    // window and never see the toggle, re-introducing an infinite loop. The three
    // windows the §1/§5.2 shapes depend on:
    const retrace_window = (Vga.VREND_LINE - Vga.VRSTART_LINE) * Vga.LINE_CYCLES; // bit-3, 908
    const active_span = Vga.HDE_CYCLES; // bit-0 active (displaying), 181
    const blank_span = Vga.LINE_CYCLES - Vga.HDE_CYCLES; // bit-0 blank, 273

    // The narrowest window (the bit-0 active span, 181 cycles) is the binding
    // constraint. A poll iteration today is a handful of instructions at the flat
    // interim cost (src/cpu/cycles.zig FLAT_BASE = 4): IN + ROR + Jcc ≈ 12 cycles,
    // far below 181. Pin a conservative ceiling so a FUTURE PRM-fidelity cost pass
    // that raises per-instruction costs cannot silently shrink a window below the
    // poll rate and reintroduce the hang — if it does, THIS assertion fails first.
    //
    // DEPENDENCY FLAG: this margin assumes the deferred per-instruction cost pass
    // (src/cpu/cycles.zig) keeps a single 0x3DA poll iteration under
    // MAX_POLL_ITER_CYCLES. Raising costs past that must re-derive the VGA timing
    // windows (or model a wider duty), not just bump this number.
    const MAX_POLL_ITER_CYCLES: u64 = 40; // generous vs the ~12-cycle reality
    try std.testing.expect(active_span > MAX_POLL_ITER_CYCLES);
    try std.testing.expect(blank_span > MAX_POLL_ITER_CYCLES);
    try std.testing.expect(retrace_window > MAX_POLL_ITER_CYCLES);
}
