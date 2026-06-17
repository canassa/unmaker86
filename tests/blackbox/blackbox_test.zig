//! Black-box integration tests for the zdos debugger HTTP API.
//!
//! Each test spawns its OWN `Session` (a real `zdos --serve 0` child process driven
//! over a real localhost socket) for full isolation, then asserts CONCRETE,
//! DETERMINISTIC values — no vacuous asserts, no test theater. The headline test
//! (#2) actually compares two independent runs byte-for-byte: it would FAIL if the
//! API perturbed machine state across the inspection calls.
//!
//! These tests use real sockets + child processes, so they are their OWN build step
//! (`zig build test-blackbox`), NOT folded into the default hermetic `test` gate.
//!
//! Fixture: `examples/HELLO.EXE` (committed, deterministic). Golden values below
//! were captured from the running server and are asserted exactly.

const std = @import("std");
const Session = @import("session.zig").Session;

// Pull the input-injection black-box tests (KEYECHO + MOUSERB) into this same
// `test-blackbox` step (they live in their own file for focus).
test {
    _ = @import("keyecho_test.zig");
    _ = @import("ttm_test.zig");
    _ = @import("mouse_test.zig");
}

const FIXTURE = "examples/HELLO.EXE";

// Golden constants for HELLO.EXE, captured from the running API and asserted exactly.
const ENTRY_LINEAR: u32 = 33200; // cs_base(33200) + eip(0) at process entry
const ENTRY_BYTES_HEX = "0e1fb409ba0e00cd21b8004ccd214865"; // 16 bytes at ENTRY_LINEAR
const CYCLE_BP_STOP: u64 = 224; // a cycle bp armed at 50 stops at the next boundary, cycle 224
const STEP1_CYCLE: u64 = 4; // one instruction from entry retires at cycle 4

fn spawn(io: std.Io) !Session {
    return Session.spawn(std.testing.allocator, io, FIXTURE);
}

test "1: health + initial status (paused at entry, cycles=0)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // health is the off-worker liveness ping.
    const h = try s.requestRaw(.GET, "/api/health", null);
    try std.testing.expectEqual(std.http.Status.ok, h.status);
    try std.testing.expect(std.mem.indexOf(u8, h.body, "\"ok\":true") != null);

    // The machine launched but is PAUSED at entry: cycles=0, runnable, not terminated.
    const st = try s.status();
    try std.testing.expectEqual(@as(u64, 0), st.cycles);
    try std.testing.expect(st.runnable);
    try std.testing.expect(!st.terminated);

    const c = try s.cpu();
    try std.testing.expectEqual(@as(u64, 0), c.cycles);
    try std.testing.expectEqual(@as(u32, 0), c.eip);
    // Entry linear address is cs_base + eip.
    try std.testing.expectEqual(ENTRY_LINEAR, c.cs_base + c.eip);
}

test "2: DETERMINISM — two fresh sessions reach byte-identical CPU at the same stop cycle" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Session A: arm a cycle breakpoint at 50, run, capture the stop cycle + CPU.
    var a = try spawn(io);
    defer a.deinit();
    const bp_a = try a.addBreakpoint(.{ .cycle = .{ .at_cycle = 50 } }, false);
    const stop_a = try a.run(null);
    const cpu_a = try a.cpu();

    // Assert the run stopped at the documented golden cycle on the cycle breakpoint.
    try std.testing.expect(stop_a.stop.breakpoint != null);
    try std.testing.expectEqual(bp_a.id, stop_a.stop.breakpoint.?.id);
    try std.testing.expectEqual(CYCLE_BP_STOP, stop_a.stop.breakpoint.?.at_cycle);
    try std.testing.expectEqual(CYCLE_BP_STOP, cpu_a.cycles);

    // Session B: an INDEPENDENT process, same command sequence.
    var b = try spawn(io);
    defer b.deinit();
    _ = try b.addBreakpoint(.{ .cycle = .{ .at_cycle = 50 } }, false);
    const stop_b = try b.run(null);
    const cpu_b = try b.cpu();

    // Identical stop cycle...
    try std.testing.expectEqual(stop_a.stop.breakpoint.?.at_cycle, stop_b.stop.breakpoint.?.at_cycle);
    // ...and BYTE-IDENTICAL CPU snapshot (every register/flag/segment/base/cycle).
    // This is the core regression: if the API perturbed state, these would differ.
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&cpu_a), std.mem.asBytes(&cpu_b));
}

test "3: execution-address breakpoint fires at the set linear address" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // Break one byte past entry (after the first 1-byte instruction PUSH CS).
    const target: u32 = ENTRY_LINEAR + 1;
    const bp = try s.addBreakpoint(.{ .execution_address = .{ .linear = target } }, false);
    const stop = try s.run(null);

    try std.testing.expect(stop.stop.breakpoint != null);
    try std.testing.expectEqual(bp.id, stop.stop.breakpoint.?.id);
    // The CPU is now AT the target: cs_base + eip == target.
    const c = try s.cpu();
    try std.testing.expectEqual(target, c.cs_base + c.eip);
}

test "4: step advances the cycle counter; step-n advances by N steps" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // One step from entry retires the first instruction at the golden cycle.
    const r1 = try s.step();
    try std.testing.expect(r1.stop.step_complete != null);
    try std.testing.expectEqual(STEP1_CYCLE, r1.stop.step_complete.?.at_cycle);
    const after1 = (try s.cpu()).cycles;
    try std.testing.expectEqual(STEP1_CYCLE, after1);

    // step-n {n:3} advances three more instructions — the cycle counter strictly
    // increases past the single-step value (deterministic, no breakpoints armed).
    const r3 = try s.stepN(3);
    try std.testing.expect(r3.stop.step_complete != null);
    const after4 = (try s.cpu()).cycles;
    try std.testing.expect(after4 > after1);
    try std.testing.expectEqual(after4, r3.stop.step_complete.?.at_cycle);

    // And a SECOND session reproduces the exact same step-n stop cycle.
    var s2 = try spawn(threaded.io());
    defer s2.deinit();
    _ = try s2.step();
    const r3b = try s2.stepN(3);
    try std.testing.expectEqual(r3.stop.step_complete.?.at_cycle, r3b.stop.step_complete.?.at_cycle);
}

test "5: memory read returns the expected bytes; identical across two sessions" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try spawn(io);
    defer s.deinit();
    const m = try s.mem(ENTRY_LINEAR, 16);
    try std.testing.expectEqual(ENTRY_LINEAR, m.phys);
    try std.testing.expectEqual(@as(u32, 16), m.len);
    try std.testing.expectEqualStrings(ENTRY_BYTES_HEX, m.data);

    // The same bytes come back from a second independent session (deterministic load).
    var s2 = try spawn(io);
    defer s2.deinit();
    const m2 = try s2.mem(ENTRY_LINEAR, 16);
    try std.testing.expectEqualStrings(m.data, m2.data);
}

test "6: register mutate round-trip (PATCH reg, GET cpu, assert changed)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    const before = try s.cpu();
    try std.testing.expectEqual(@as(u32, 0), before.eax); // entry eax is 0

    const ok = try s.setReg32("eax", 0x1234);
    try std.testing.expect(ok.ok);

    const after = try s.cpu();
    try std.testing.expectEqual(@as(u32, 0x1234), after.eax);
}

test "7: error paths — 404 no_such_breakpoint, 501 disasm, 501 io breakpoint" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // A bad breakpoint id → 404 with the typed code.
    const e404 = try s.rawStatus(.GET, "/api/breakpoints/99", null);
    try std.testing.expectEqual(std.http.Status.not_found, e404.status);
    try std.testing.expect(std.mem.indexOf(u8, e404.body, "\"no_such_breakpoint\"") != null);

    // GET /api/disasm is a declared-but-deferred endpoint → 501.
    const e_dis = try s.rawStatus(.GET, "/api/disasm", null);
    try std.testing.expectEqual(std.http.Status.not_implemented, e_dis.status);

    // An io-kind breakpoint is declared in the core but unimplemented → 501.
    const io_bp = "{\"kind\":{\"io\":{\"port\":0,\"access\":\"write\"}},\"one_shot\":false}";
    const e_io = try s.rawStatus(.POST, "/api/breakpoints", io_bp);
    try std.testing.expectEqual(std.http.Status.not_implemented, e_io.status);
    try std.testing.expect(std.mem.indexOf(u8, e_io.body, "\"not_implemented\"") != null);
}

test "8: reset -> load -> run reproduces a fresh run byte-identically (Part-1 regression)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try spawn(io);
    defer s.deinit();

    // A FRESH run: stop at a cycle breakpoint, capture the CPU.
    _ = try s.addBreakpoint(.{ .cycle = .{ .at_cycle = 50 } }, false);
    const fresh_stop = try s.run(null);
    const fresh_cpu = try s.cpu();
    try std.testing.expectEqual(CYCLE_BP_STOP, fresh_stop.stop.breakpoint.?.at_cycle);

    // reset wipes the machine to power-on (and, before the fix, wiped the C: mount).
    const rok = try s.reset();
    try std.testing.expect(rok.ok);

    // load {} re-establishes the mount + re-runs the full boot (the Part-1 fix). It
    // must SUCCEED (before the fix it returned load_failed).
    const lok = try s.load();
    try std.testing.expect(lok.ok);

    // Re-arm the same breakpoint and run again — the breakpoint set survives reset
    // (a debug session's breakpoints outlive a machine reset), so the cycle bp at 50
    // is still armed and we just run.
    const re_stop = try s.run(null);
    const re_cpu = try s.cpu();

    // Same stop cycle...
    try std.testing.expectEqual(fresh_stop.stop.breakpoint.?.at_cycle, re_stop.stop.breakpoint.?.at_cycle);
    // ...and BYTE-IDENTICAL CPU snapshot vs. the fresh run. This is the regression:
    // reset+load must reproduce the documented fresh-launch state.
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&fresh_cpu), std.mem.asBytes(&re_cpu));
}

/// The CPU-speed knob view (`/api/cpu/clock`). INTEGER fields only (no float on the
/// wire); `mhz` is a derived display string.
const ClockView = struct {
    mult: u64,
    cpu_hz: u64,
    mhz: []const u8,
    slice_cycles: u64,
    max_mult: u64,
};

test "9: CPU-speed knob — GET defaults to mult 12; POST {mult} sets it; integer-only wire" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try spawn(io);
    defer s.deinit();

    // GET reflects the power-on default mult 12 (≈14.32 MHz), with the derived view.
    const g0 = try s.get("/api/cpu/clock", ClockView);
    try std.testing.expectEqual(@as(u64, 12), g0.mult);
    try std.testing.expectEqual(@as(u64, 14_318_184), g0.cpu_hz);
    try std.testing.expectEqualStrings("14.31", g0.mhz); // 14318184 -> 14.31 (floor 2dp)
    try std.testing.expectEqual(@as(u64, 143_181), g0.slice_cycles);

    // POST {mult:24} applies it; the response echoes the applied mult + derived view.
    const p = try s.post("/api/cpu/clock", .{ .mult = @as(u64, 24) }, ClockView);
    try std.testing.expectEqual(@as(u64, 24), p.mult);
    try std.testing.expectEqual(@as(u64, 28_636_368), p.cpu_hz);
    try std.testing.expectEqual(@as(u64, 286_363), p.slice_cycles); // pacer slice retuned

    // GET now reflects the applied mult (the UI can sync).
    const g1 = try s.get("/api/cpu/clock", ClockView);
    try std.testing.expectEqual(@as(u64, 24), g1.mult);

    // POST {mhz} converts to a nearest-integer mult (mhz/1.193182): 50 MHz -> mult 42.
    const pm = try s.post("/api/cpu/clock", .{ .mhz = @as(u64, 50) }, ClockView);
    try std.testing.expectEqual(@as(u64, 42), pm.mult); // round(50_000_000/1_193_182)=42

    // A too-large mult is clamped to max_mult (the host-ceiling knob bound).
    const pmax = try s.post("/api/cpu/clock", .{ .mult = @as(u64, 9999) }, ClockView);
    try std.testing.expectEqual(g0.max_mult, pmax.mult);

    // mult 0 is a 400 (validated at the handler — never applied).
    const bad = try s.rawStatus(.POST, "/api/cpu/clock", "{\"mult\":0}");
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
}
