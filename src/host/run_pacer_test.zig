//! Run-pacer tests (stream §5.1/§13): the LOAD-BEARING determinism proof
//! (paced ≡ unpaced, byte-identical at the actual final cycle), the pacer's
//! self-disarm on a terminal slice, and the run-ownership arbitration (a debugger
//! `run-to-cycle` with the pacer armed disarms it and lands exactly at N).
//!
//! These build a REAL machine + Controller + the api queue/worker + the host pacer.
//! The pacer reaches the worker only through the submit-gated queue (CLAUDE #4); its
//! host sleep changes only wall-time pacing, never which cycles run.

const std = @import("std");
const api = @import("api");
const machine_mod = @import("machine");
const debug = @import("debug");
const cpu_mod = @import("cpu");

const run_pacer = @import("run_pacer.zig");
const RunPacer = run_pacer.RunPacer;

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const RunControl = api.RunControl;
const RunOwner = api.RunOwner;
const Reg32 = cpu_mod.state.Reg32;

// ---------------------------------------------------------------------------
// Test programs (mirror the queue/controller tests).
// ---------------------------------------------------------------------------

const PROG: u32 = 0x0500;

/// A long deterministic NOP→HLT program: 8 NOPs, then HLT, then a self-jump so a
/// permanent HLT is reachable (the controller reports `halted_forever`).
fn loadNopHlt(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90);
    b.writePhys8(PROG + 8, 0xF4); // HLT
    b.writePhys8(PROG + 9, 0xEB); // JMP -3
    b.writePhys8(PROG + 10, 0xFD);
    seedRegs(m);
}

/// A never-terminating tight loop: `NOP; NOP; JMP -4`. Runs forever, so a paced run
/// to a cycle cap lands at a deterministic cycle decided only by the cap — perfect
/// for the paced≡unpaced proof where the final cycle must match exactly.
fn loadSpinLoop(m: *Machine) void {
    const b = &m.bus;
    b.writePhys8(PROG + 0, 0x90); // NOP
    b.writePhys8(PROG + 1, 0x90); // NOP
    b.writePhys8(PROG + 2, 0xEB); // JMP rel8
    b.writePhys8(PROG + 3, 0xFC); // -4 → back to PROG+0
    seedRegs(m);
}

fn seedRegs(m: *Machine) void {
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

fn makeMachine(alloc: std.mem.Allocator, load: *const fn (*Machine) void) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    load(m);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

const WorkerArgs = struct { queue: *api.CommandQueue, ctrl: *Controller };

fn workerThread(args: WorkerArgs) void {
    while (true) {
        const ctx = args.queue.waitDequeue();
        if (ctx.cmd == .shutdown_worker) {
            args.queue.complete(ctx, .ok);
            return;
        }
        const resp = api.drainOne(args.ctrl, ctx, .{}, null, null);
        args.queue.complete(ctx, resp);
    }
}

/// Spin until `pred()` or a generous deadline (poll on the awake clock — TEST host
/// pacing only, never touches a machine cycle). Returns false on timeout.
fn waitUntil(io: std.Io, pred: anytype) bool {
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) {
        if (pred.call()) return true;
        io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch return false;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 1. The load-bearing proof: paced ≡ unpaced, byte-identical at the final cycle.
// ---------------------------------------------------------------------------

test "paced run ≡ unpaced run: byte-identical machine state at the actual final cycle" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ---- Session 1: run via the PACER (many small slices) ----
    const m1 = try makeMachine(alloc, loadSpinLoop);
    defer destroy(alloc, m1);
    var ctrl1 = Controller.init(m1);
    var queue1 = api.CommandQueue.init(io);
    const wt1 = try std.Thread.spawn(.{}, workerThread, .{WorkerArgs{ .queue = &queue1, .ctrl = &ctrl1 }});

    var rc1 = RunControl.init(io);
    // Tiny slices (well under a frame) so MANY slice boundaries occur — the whole
    // point is to prove slicing changes nothing.
    var pacer = RunPacer{ .queue = &queue1, .control = &rc1, .io = io };
    try pacer.start();

    _ = rc1.start(64, 0); // 64-cycle slices — lots of boundaries
    // Let the pacer run for a little wall time, accumulating slices.
    const ArmedAdvanced = struct {
        q: *api.CommandQueue,
        fn call(self: @This()) bool {
            // Probe the live cycle via a status command (off-thread reads are unsafe).
            var ctx: api.RequestCtx = .{ .cmd = .status };
            const r = self.q.submit(&ctx);
            return switch (r) {
                .status => |st| st.cycles >= 4000,
                else => false,
            };
        }
    };
    _ = waitUntil(io, ArmedAdvanced{ .q = &queue1 });

    // FULLY stop the pacer thread (disarm + join) so NO further slice can run — only
    // then sample, guaranteeing the captured cycle is the true final cycle (do NOT
    // assume start + K·slice; a HLT fast-forward could overshoot a slice boundary).
    pacer.join();

    var cyc_ctx: api.RequestCtx = .{ .cmd = .status };
    const final_cycle = switch (queue1.submit(&cyc_ctx)) {
        .status => |st| st.cycles,
        else => return error.NoStatus,
    };
    try std.testing.expect(final_cycle >= 4000);

    // Snapshot session 1's state at the final cycle.
    var snap_ctx: api.RequestCtx = .{ .cmd = .cpu_get };
    const cpu1 = switch (queue1.submit(&snap_ctx)) {
        .cpu => |c| c,
        else => return error.NoCpu,
    };
    const ram1 = try alloc.dupe(u8, m1.bus.ram);
    defer alloc.free(ram1);

    var sd1: api.RequestCtx = .{ .cmd = .shutdown_worker };
    _ = queue1.submit(&sd1);
    wt1.join();

    // ---- Session 2: a fresh machine, single unpaced run-to-cycle(final_cycle) ----
    const m2 = try makeMachine(alloc, loadSpinLoop);
    defer destroy(alloc, m2);
    var ctrl2 = Controller.init(m2);
    const stop = try ctrl2.runToCycle(final_cycle);
    _ = stop;
    const cpu2 = ctrl2.cpuSnapshot();

    // ---- Byte-identical? ----
    try std.testing.expectEqual(final_cycle, cpu1.cycles);
    try std.testing.expectEqual(final_cycle, cpu2.cycles);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&cpu1), std.mem.asBytes(&cpu2));
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);
}

// ---------------------------------------------------------------------------
// 2. The pacer disarms itself on a terminal (program_terminated/halted_forever).
// ---------------------------------------------------------------------------

test "pacer disarms on a terminal slice (halted_forever) and stops submitting" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const m = try makeMachine(alloc, loadNopHlt);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var queue = api.CommandQueue.init(io);
    const wt = try std.Thread.spawn(.{}, workerThread, .{WorkerArgs{ .queue = &queue, .ctrl = &ctrl }});

    var rc = RunControl.init(io);
    var pacer = RunPacer{ .queue = &queue, .control = &rc, .io = io };
    try pacer.start();
    _ = rc.start(1000, 0);

    // The NOP→HLT program reaches a permanent HLT quickly; the pacer must DISARM.
    const Disarmed = struct {
        c: *RunControl,
        fn call(self: @This()) bool {
            return !self.c.isArmed() and self.c.getOwner() == .idle;
        }
    };
    try std.testing.expect(waitUntil(io, Disarmed{ .c = &rc }));
    try std.testing.expectEqual(api.StopTag.halted_forever, rc.lastStop());

    pacer.join();
    var sd: api.RequestCtx = .{ .cmd = .shutdown_worker };
    _ = queue.submit(&sd);
    wt.join();
}

// ---------------------------------------------------------------------------
// 3. Run-ownership: a debugger run-to-cycle with the pacer armed disarms it and
//    lands EXACTLY at N (byte-identical to no pacer). Modeled at the RunControl +
//    queue level (the server's submitDebuggerAndRespond brackets identically).
// ---------------------------------------------------------------------------

test "run-to-cycle with the pacer armed disarms it and lands exactly at N" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const m = try makeMachine(alloc, loadSpinLoop);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    var queue = api.CommandQueue.init(io);
    const wt = try std.Thread.spawn(.{}, workerThread, .{WorkerArgs{ .queue = &queue, .ctrl = &ctrl }});

    var rc = RunControl.init(io);
    var pacer = RunPacer{ .queue = &queue, .control = &rc, .io = io };
    try pacer.start();
    _ = rc.start(64, 0); // pacer running

    // The server's debugger path: beginDebugger (auto-disarm) → run_to_cycle → end.
    // After beginDebugger the pacer submits no more slices, so the machine is parked
    // at some cycle C. We pick the target FROM C (C + delta) so N is in the future —
    // mirroring the real flow where a debugger run-to-cycle to a PAST cycle would
    // correctly return immediately (a different, also-deterministic case).
    const restore = rc.beginDebugger();
    try std.testing.expectEqual(RunOwner.debugger, rc.getOwner());
    var cyc_ctx: api.RequestCtx = .{ .cmd = .status };
    const parked = switch (queue.submit(&cyc_ctx)) {
        .status => |st| st.cycles,
        else => return error.NoStatus,
    };
    const target: u64 = parked + 5000;

    var ctx: api.RequestCtx = .{ .cmd = .{ .run_to_cycle = .{ .cycle = target } } };
    const resp = queue.submit(&ctx);

    // Sample session 1's CPU at N via the worker WHILE STILL the debugger owner —
    // BEFORE re-arming, so the pacer can't advance past N before we read it.
    var snap_ctx: api.RequestCtx = .{ .cmd = .cpu_get };
    const cpu1 = switch (queue.submit(&snap_ctx)) {
        .cpu => |c| c,
        else => return error.NoCpu,
    };
    const ram1 = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ram1);

    // It must have stopped at EXACTLY the target cycle. `runToCycle` arms an internal
    // one-shot CYCLE breakpoint at N and translates its hit into the dedicated
    // `target_reached{at_cycle=N}` reason (the internal id never leaks as a
    // `.breakpoint`). A run-to-PAST cycle would instead be `cycle_budget_exhausted`
    // at the current cycle — a different, also-deterministic case. Here N is in the
    // future → target_reached.
    switch (resp) {
        .stop => |s| switch (s) {
            .target_reached => |c| try std.testing.expectEqual(target, c.at_cycle),
            .cycle_budget_exhausted => |c| try std.testing.expectEqual(target, c.at_cycle),
            else => return error.WrongStop,
        },
        else => return error.WrongResp,
    }

    rc.endDebugger(restore); // re-arm the pacer (it owned the run before)

    // Compare to a fresh unpaced run-to-cycle(target): byte-identical CPU state.
    const m2 = try makeMachine(alloc, loadSpinLoop);
    defer destroy(alloc, m2);
    var ctrl2 = Controller.init(m2);
    _ = try ctrl2.runToCycle(target);

    const cpu2 = ctrl2.cpuSnapshot();
    try std.testing.expectEqual(target, cpu1.cycles);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&cpu1), std.mem.asBytes(&cpu2));
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);

    pacer.join();
    var sd: api.RequestCtx = .{ .cmd = .shutdown_worker };
    _ = queue.submit(&sd);
    wt.join();
}
