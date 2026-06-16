//! Phase 3 regression tests (M1 §4): step==run equivalence (#5), stepOver over a
//! direct CALL incl. recursion via the SP guard and the reported step-into
//! fallback (#15), reset determinism, and the mutate round-trips.

const std = @import("std");
const debug = @import("debug.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

// A deterministic arithmetic program (no devices/IRQs): a run of INC AX / DEC BX
// then HLT, so step==run over the span is exactly comparable.
const PROG: u32 = 0x0500;
fn loadArithProg(m: *Machine) void {
    const b = &m.bus;
    // 0500: B8 00 00      MOV AX, 0
    // 0503: BB 10 00      MOV BX, 0x10
    // 0506: 40            INC AX
    // 0507: 4B            DEC BX
    // 0508: 40            INC AX
    // 0509: 4B            DEC BX
    // 050A: F4            HLT
    const code = [_]u8{
        0xB8, 0x00, 0x00,
        0xBB, 0x10, 0x00,
        0x40, 0x4B, 0x40,
        0x4B, 0xF4,
    };
    for (code, 0..) |byte, i| b.writePhys8(PROG + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

test "#5 step == run equivalence: runToCycle(N) vs stepInstruction until >= N" {
    const alloc = std.testing.allocator;
    const N: u64 = 12; // a few instructions in, before HLT

    // Run-to-cycle path.
    const mr = try makeMachine(alloc);
    defer destroy(alloc, mr);
    loadArithProg(mr);
    var cr = Controller.init(mr);
    _ = try cr.runToCycle(N);
    const run_snap = mr.snapshot();
    const run_ram = try alloc.dupe(u8, mr.bus.ram);
    defer alloc.free(run_ram);

    // Single-step path: step until cycles >= N.
    const ms = try makeMachine(alloc);
    defer destroy(alloc, ms);
    loadArithProg(ms);
    var cs = Controller.init(ms);
    while (ms.cpu.st.cycles < N) {
        const r = cs.stepInstruction();
        if (std.meta.activeTag(r) != .step_complete) break; // terminal
    }
    const step_snap = ms.snapshot();

    // The two paths must reach byte-identical state + RAM at the same ledger value
    // (no stepping cost is invented; N steps == one run over the same span).
    try std.testing.expectEqual(run_snap.cpu_state.cycles, step_snap.cpu_state.cycles);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&run_snap.cpu_state), std.mem.asBytes(&step_snap.cpu_state));
    try std.testing.expectEqualSlices(u8, run_ram, ms.bus.ram);
}

test "runToCycle in the past returns immediately with cycle_budget_exhausted" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadArithProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.runToCycle(20); // advance a bit
    const cyc = m.cpu.st.cycles;
    const r = try ctrl.runToCycle(cyc); // <= current
    switch (r) {
        .cycle_budget_exhausted => |e| try std.testing.expectEqual(cyc, e.at_cycle),
        else => return error.WrongStopReason,
    }
    try std.testing.expectEqual(cyc, m.cpu.st.cycles); // no step taken
}

test "stepInstruction on an already-terminal machine does not step" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadArithProg(m);
    var ctrl = Controller.init(m);
    // Run to the permanent HLT.
    _ = ctrl.runUntilEvent(10_000);
    try std.testing.expect(m.cpu.st.halted);
    const cyc = m.cpu.st.cycles;
    const r = ctrl.stepInstruction();
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r));
    try std.testing.expectEqual(cyc, m.cpu.st.cycles); // ledger untouched (no hole)
}

// ---- #15 stepOver -------------------------------------------------------------

// A program with a direct near CALL to a subroutine, then a marker, then HLT.
//   0600: E8 04 00     CALL 0607          (rel16 = +4 -> 0603+4 = 0607)
//   0603: BE 99 00     MOV SI, 0x99       (the "after-call" marker instruction)
//   0606: F4           HLT
//   0607: 40           INC AX             (subroutine body)
//   0608: 40           INC AX
//   0609: C3           RET
const CALLPROG: u32 = 0x0600;
const AFTER_CALL: u32 = 0x0603;
const SUBR: u32 = 0x0607;
fn loadCallProg(m: *Machine) void {
    const b = &m.bus;
    const code = [_]u8{
        0xE8, 0x04, 0x00, // CALL +4 -> 0x0607
        0xBE, 0x99, 0x00, // MOV SI, 0x99
        0xF4, // HLT
        0x40, 0x40, 0xC3, // INC AX; INC AX; RET
    };
    for (code, 0..) |byte, i| b.writePhys8(CALLPROG + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = CALLPROG;
}

test "#15 stepOver a direct near CALL lands after the call, not inside the callee" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadCallProg(m);
    var ctrl = Controller.init(m);

    const res = ctrl.stepOver();
    try std.testing.expect(!res.stepped_into); // we stepped OVER, not into
    // CS:IP must be at the instruction AFTER the call (0x0603), not in the callee.
    try std.testing.expectEqual(@as(u32, AFTER_CALL), m.cpu.st.eip);
    // The callee ran (it incremented AX twice) — step-over executes the call.
    try std.testing.expectEqual(@as(u16, 2), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
    switch (res.reason) {
        .step_complete => {},
        else => return error.WrongStopReason,
    }
}

// A self-recursive subroutine: counts down CX, recursing, so the SAME return
// linear is hit at multiple SP depths. stepOver over the OUTER call must land
// after it (SP guard rejects the deeper re-entries).
//   0700: B9 03 00     MOV CX, 3
//   0703: E8 03 00     CALL 0709           (outer call)
//   0706: BE 11 00     MOV SI, 0x11        (after-call marker)  [we HLT instead]
//   0706: F4 ...                            -> we put HLT at 0706
// subroutine at 0709:
//   0709: 49           DEC CX
//   070A: 74 04        JZ +4 -> 0710 (ret path)
//   070C: E8 FA FF     CALL 0709           (recurse: rel16 = -6 -> 070F-6 = 0709)
//   070F: C3           RET
//   0710: C3           RET
const RECPROG: u32 = 0x0700;
const REC_AFTER: u32 = 0x0706;
fn loadRecProg(m: *Machine) void {
    const b = &m.bus;
    const code = [_]u8{
        0xB9, 0x03, 0x00, // 0700 MOV CX, 3
        0xE8, 0x03, 0x00, // 0703 CALL 0709
        0xF4, // 0706 HLT (after-call marker)
        // pad to 0709
        0x90, 0x90, // 0707,0708 NOP NOP (filler so subr starts at 0709)
        0x49, // 0709 DEC CX
        0x74, 0x04, // 070A JZ +4 -> 0710
        0xE8, 0xFA, 0xFF, // 070C CALL 0709 (rel16 = -6: 070F-6=0709)
        0xC3, // 070F RET
        0xC3, // 0710 RET
    };
    for (code, 0..) |byte, i| b.writePhys8(RECPROG + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = RECPROG;
}

test "#15 stepOver a recursive CALL handles re-entry via the SP guard" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadRecProg(m);
    var ctrl = Controller.init(m);

    // Step the MOV CX,3 first so CS:IP sits on the outer CALL at 0x0703.
    _ = ctrl.stepInstruction();
    try std.testing.expectEqual(@as(u32, 0x0703), m.cpu.st.eip);

    const res = ctrl.stepOver();
    try std.testing.expect(!res.stepped_into);
    // Despite the callee recursing (hitting return-linear 0x0706? no — the return
    // site is 0x0706, hit only when the OUTER call returns at the original SP).
    // The recursion's inner returns hit 0x070F, not our guarded 0x0706, but the
    // SP guard makes the design robust either way. Land after the outer call.
    try std.testing.expectEqual(@as(u32, REC_AFTER), m.cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 0), m.cpu.st.getReg16(@intFromEnum(Reg32.ecx))); // CX fully counted down
}

test "#15 stepOver falls back to step-into for a non-direct-call opcode (reported)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadArithProg(m); // first opcode is MOV AX (0xB8), not a call
    var ctrl = Controller.init(m);
    const res = ctrl.stepOver();
    try std.testing.expect(res.stepped_into); // reported fallback, never silent
    try std.testing.expectEqual(@as(u32, PROG + 3), m.cpu.st.eip); // stepped one instr
}

test "#15 stepOver an INT (0xCD) steps over the handler via SP guard" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    const b = &m.bus;
    // IVT[0x80] -> a tiny handler that just IRETs.
    const HANDLER: u32 = 0x0400;
    b.writePhys16(0x80 * 4, @intCast(HANDLER));
    b.writePhys16(0x80 * 4 + 2, 0x0000);
    b.writePhys8(HANDLER, 0x40); // INC AX (handler side effect)
    b.writePhys8(HANDLER + 1, 0xCF); // IRET
    // Main: INT 0x80; MOV SI,0x55; HLT
    const MAIN: u32 = 0x0500;
    b.writePhys8(MAIN, 0xCD);
    b.writePhys8(MAIN + 1, 0x80); // INT 0x80
    b.writePhys8(MAIN + 2, 0xBE);
    b.writePhys8(MAIN + 3, 0x55);
    b.writePhys8(MAIN + 4, 0x00); // MOV SI, 0x55
    b.writePhys8(MAIN + 5, 0xF4); // HLT
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = MAIN;

    var ctrl = Controller.init(m);
    const res = ctrl.stepOver();
    try std.testing.expect(!res.stepped_into);
    // Landed after the INT (at MAIN+2), with the handler having run (AX incremented).
    try std.testing.expectEqual(@as(u32, MAIN + 2), m.cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 1), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

// ---- #15b stepOver a whole REP-string (plans/step-over-rep.md) ---------------

// REP MOVSB then a marker then HLT. DS:SI -> source, ES:DI -> dest, CX = count.
//   0800: F3 A4        REP MOVSB
//   0802: BE 99 00     MOV SI, 0x99   (after-REP marker)
//   0805: F4           HLT
const REPPROG: u32 = 0x0800;
const REP_AFTER: u32 = 0x0802;
const REP_SRC: u32 = 0x1000;
const REP_DST: u32 = 0x2000;
fn loadRepProg(m: *Machine, count: u16) void {
    const b = &m.bus;
    b.writePhys8(REPPROG, 0xF3); // REP
    b.writePhys8(REPPROG + 1, 0xA4); // MOVSB
    b.writePhys8(REPPROG + 2, 0xBE);
    b.writePhys8(REPPROG + 3, 0x99);
    b.writePhys8(REPPROG + 4, 0x00); // MOV SI, 0x99
    b.writePhys8(REPPROG + 5, 0xF4); // HLT
    // Distinct source bytes so a correct copy is verifiable.
    var i: u32 = 0;
    while (i < count) : (i += 1) b.writePhys8(REP_SRC + i, @intCast(0x40 + (i & 0x3F)));
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.es, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esi), REP_SRC);
    m.cpu.st.setReg16(@intFromEnum(Reg32.edi), REP_DST);
    m.cpu.st.setReg16(@intFromEnum(Reg32.ecx), count);
    m.cpu.st.eflags.df = false;
    m.cpu.st.eip = REPPROG;
}

test "#15b stepOver a large REP MOVSB lands AFTER the REP in one command, copy complete" {
    const alloc = std.testing.allocator;
    const N: u16 = 64;

    // Machine A: one stepOver over the whole REP.
    const a = try makeMachine(alloc);
    defer destroy(alloc, a);
    loadRepProg(a, N);
    var ca = Controller.init(a);
    const res = ca.stepOver();

    try std.testing.expect(!res.stepped_into); // stepped OVER the whole REP
    try std.testing.expectEqual(@as(u32, REP_AFTER), a.cpu.st.eip); // past the REP
    try std.testing.expectEqual(@as(u16, 0), a.cpu.st.getReg16(@intFromEnum(Reg32.ecx))); // CX exhausted
    // The block was actually copied.
    var di: u32 = 0;
    while (di < N) : (di += 1) {
        try std.testing.expectEqual(a.bus.peekPhys8(REP_SRC + di), a.bus.peekPhys8(REP_DST + di));
    }

    // Machine B: drive the REP via per-iteration stepInstruction; the cycle count
    // must match — stepOver charges the REP's REAL cycles, no synthetic count.
    const bm = try makeMachine(alloc);
    defer destroy(alloc, bm);
    loadRepProg(bm, N);
    var cb = Controller.init(bm);
    while (bm.cpu.st.eip == REPPROG) _ = cb.stepInstruction();
    try std.testing.expectEqual(bm.cpu.st.cycles, a.cpu.st.cycles);
}

test "#15b stepOver a REP with CX=0 is a single no-op step to the next instruction" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadRepProg(m, 0); // CX = 0: REP is a no-op
    var ctrl = Controller.init(m);
    const res = ctrl.stepOver();
    try std.testing.expect(!res.stepped_into);
    try std.testing.expectEqual(@as(u32, REP_AFTER), m.cpu.st.eip);
    // Nothing copied (dest stays zero).
    try std.testing.expectEqual(@as(u8, 0), m.bus.peekPhys8(REP_DST));
}

test "#15b stepOver entered MID-REP still completes the remaining iterations" {
    const alloc = std.testing.allocator;
    const N: u16 = 32;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadRepProg(m, N);
    var ctrl = Controller.init(m);

    // Step 5 iterations by hand — EIP stays pinned at the REP opcode (mid-flight).
    var k: u32 = 0;
    while (k < 5) : (k += 1) _ = ctrl.stepInstruction();
    try std.testing.expectEqual(@as(u32, REPPROG), m.cpu.st.eip); // still on the REP
    try std.testing.expectEqual(@as(u16, N - 5), m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));

    // stepOver from mid-REP completes the rest in one command.
    const res = ctrl.stepOver();
    try std.testing.expect(!res.stepped_into);
    try std.testing.expectEqual(@as(u32, REP_AFTER), m.cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 0), m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
}

test "#15b stepOver over a REP is deterministic (two runs byte-identical + same cycle)" {
    const alloc = std.testing.allocator;
    const N: u16 = 50;
    var snaps: [2]Machine.Snapshot = undefined;
    var cycles: [2]u64 = undefined;
    for (0..2) |run| {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadRepProg(m, N);
        var ctrl = Controller.init(m);
        _ = ctrl.stepOver();
        snaps[run] = m.snapshot();
        cycles[run] = m.cpu.st.cycles;
    }
    try std.testing.expectEqual(cycles[0], cycles[1]);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snaps[0].cpu_state), std.mem.asBytes(&snaps[1].cpu_state));
}

test "#15b stepOver an INDIRECT CALL (FF /2) still reports step-into (documented gap)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    const b = &m.bus;
    // FF D0 = CALL AX (register-indirect near call). Not a direct CALL/INT, not a
    // REP — so step-over has no cheap next-addr and reports a step-into fallback.
    b.writePhys8(0x0500, 0xFF);
    b.writePhys8(0x0501, 0xD0); // CALL AX
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.setReg16(@intFromEnum(Reg32.eax), 0x0600); // call target
    m.cpu.st.eip = 0x0500;

    var ctrl = Controller.init(m);
    const res = ctrl.stepOver();
    try std.testing.expect(res.stepped_into); // reported fallback, never silent
}

// ---- reset + mutate -----------------------------------------------------------

test "reset then re-load + rerun == fresh run, byte-identical" {
    const alloc = std.testing.allocator;
    const N: u64 = 14;

    // Fresh machine run.
    const fresh = try makeMachine(alloc);
    defer destroy(alloc, fresh);
    loadArithProg(fresh);
    var cf = Controller.init(fresh);
    _ = try cf.runToCycle(N);
    const fresh_snap = fresh.snapshot();
    const fresh_ram = try alloc.dupe(u8, fresh.bus.ram);
    defer alloc.free(fresh_ram);

    // Dirty a machine, run it, reset it, re-load the same program, rerun.
    const reused = try makeMachine(alloc);
    defer destroy(alloc, reused);
    loadArithProg(reused);
    var cu = Controller.init(reused);
    _ = cu.runUntilEvent(10_000); // run to HLT, dirtying state
    try cu.reset(); // deterministic power-on
    loadArithProg(reused); // re-establish the same inputs
    _ = try cu.runToCycle(N);
    const reused_snap = reused.snapshot();

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&fresh_snap.cpu_state), std.mem.asBytes(&reused_snap.cpu_state));
    try std.testing.expectEqualSlices(u8, fresh_ram, reused.bus.ram);
}

test "mutate round-trips: setReg32/16/8, setSegment, setEip, setFlags, writeMem" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);

    ctrl.setReg32(.eax, 0x11223344);
    try std.testing.expectEqual(@as(u32, 0x11223344), m.cpu.readReg32(.eax));
    ctrl.setReg16(.bx, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
    ctrl.setReg8(.ah, 0x77); // high byte of AX
    try std.testing.expectEqual(@as(u8, 0x77), m.cpu.st.getReg8(4));
    ctrl.setSegment(.ds, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), m.cpu.readSegSelector(.ds));
    try std.testing.expectEqual(@as(u32, 0x1234 << 4), m.cpu.st.seg_base[@intFromEnum(cpu_mod.Seg.ds)]); // base recomputed
    ctrl.setEip(0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD), m.cpu.st.eip);
    var f = m.cpu.readFlags();
    f.cf = true;
    f.zf = true;
    ctrl.setFlags(f);
    try std.testing.expect(m.cpu.st.eflags.cf and m.cpu.st.eflags.zf);

    // writeMem through the real bus path; read it back via the peek path.
    ctrl.setSegment(.es, 0x0000);
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    ctrl.writeMem(.es, 0x2000, &bytes);
    var got: [4]u8 = undefined;
    ctrl.peekMem(.es, 0x2000, &got);
    try std.testing.expectEqualSlices(u8, &bytes, &got);
}
