//! Phase 3 stream tests — the HERMETIC, in-process half (no real socket): the shared
//! latest-frame buffer (publish/copy-out/seqno/wakeAll/waitNext), the §6.3 wire header,
//! Wyhash dedup including the palette-only-change correctness case, and the frame
//! producer's cycle-neutrality (driving the real worker/queue but NO net listener).
//!
//! The real-socket half (WS handshake/101, frame round-trip on the wire, the N+1 → 503
//! cap, 2 concurrent clients, clean shutdown with a live connection) lives OUT-OF-
//! PROCESS in the black-box suite (`tests/blackbox/stream_test.zig`, `test-blackbox`),
//! so the default `test` gate stays hermetic + CI-stable (the existing convention).

const std = @import("std");
const sf = @import("shared_frame.zig");
const stream = @import("stream.zig");
const q = @import("queue.zig");
const run_control = @import("run_control.zig");
const worker = @import("worker.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const SharedFrame = sf.SharedFrame;
const Reg32 = cpu_mod.state.Reg32;

// ===========================================================================
// SharedFrame — publish / copy-out / seqno / palette-change tracking.
// ===========================================================================

fn makeIo(alloc: std.mem.Allocator) !*std.Io.Threaded {
    const t = try alloc.create(std.Io.Threaded);
    t.* = std.Io.Threaded.init(alloc, .{});
    return t;
}

test "SharedFrame: publish bumps seqno and copyOut returns the body" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const io = t.io();

    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(io);

    try std.testing.expectEqual(@as(u64, 0), frame.currentSeqno());

    var index: [16]u8 = undefined;
    for (&index, 0..) |*p, i| p.* = @intCast(i);
    var palette: [sf.PALETTE_LEN]u8 = undefined;
    for (&palette, 0..) |*p, i| p.* = @truncate(i);

    frame.publish(.{
        .supported = true,
        .width = 4,
        .height = 4,
        .kind = 5,
        .pel_mask = 0xFF,
        .index = &index,
        .palette = &palette,
    });
    try std.testing.expectEqual(@as(u64, 1), frame.currentSeqno());

    var idst: [sf.INDEX_CAP]u8 = undefined;
    var pdst: [sf.PALETTE_LEN]u8 = undefined;
    var rdst: [sf.STOP_REASON_CAP]u8 = undefined;
    const snap = frame.copyOut(&idst, &pdst, &rdst);
    try std.testing.expectEqual(@as(u32, 16), snap.index_len);
    try std.testing.expectEqualSlices(u8, &index, snap.index);
    try std.testing.expectEqualSlices(u8, &palette, snap.palette);
    try std.testing.expect(snap.supported);
    try std.testing.expectEqual(@as(u16, 4), snap.width);
    try std.testing.expectEqual(@as(u64, 1), snap.palette_seq);
}

test "SharedFrame: palette_seq bumps ONLY when the palette changes" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(t.io());

    var index = [_]u8{1} ** 16;
    var palette = [_]u8{7} ** sf.PALETTE_LEN;

    frame.publish(.{ .supported = true, .width = 4, .height = 4, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    const p1 = frame.palette_seq;

    // Same palette, different index → palette_seq must NOT bump.
    index[0] = 99;
    frame.publish(.{ .supported = true, .width = 4, .height = 4, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    try std.testing.expectEqual(p1, frame.palette_seq);

    // Changed palette → palette_seq bumps.
    palette[0] = 8;
    frame.publish(.{ .supported = true, .width = 4, .height = 4, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    try std.testing.expectEqual(p1 + 1, frame.palette_seq);
}

test "SharedFrame: frame_hash differs for a PALETTE-ONLY change (dedup correctness)" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(t.io());

    const index = [_]u8{3} ** 64; // identical index across both publishes
    var palette = [_]u8{0} ** sf.PALETTE_LEN;

    frame.publish(.{ .supported = true, .width = 8, .height = 8, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    const h1 = frame.frame_hash;

    // Identical index, identical palette → the hash MUST match (an unchanged frame is
    // skipped by dedup).
    frame.publish(.{ .supported = true, .width = 8, .height = 8, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    try std.testing.expectEqual(h1, frame.frame_hash);

    // PALETTE-ONLY change (index identical) → the hash MUST differ, so the frame is NOT
    // skipped (the key correctness case: palette fades must reach the client).
    palette[5] = 200;
    frame.publish(.{ .supported = true, .width = 8, .height = 8, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    try std.testing.expect(frame.frame_hash != h1);
}

test "SharedFrame: waitNext returns immediately when a frame already exists" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(t.io());

    const index = [_]u8{0} ** 4;
    const palette = [_]u8{0} ** sf.PALETTE_LEN;
    frame.publish(.{ .supported = true, .width = 2, .height = 2, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });

    var stop = std.atomic.Value(bool).init(false);
    // last=0, seqno=1 → does not block, returns the current seqno.
    const got = frame.waitNext(0, &stop);
    try std.testing.expectEqual(@as(u64, 1), got);
}

test "SharedFrame: waitNext wakes on wakeAll without a new frame" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(t.io());

    // No frame published (seqno==0). A waiter with last==0 would block; spawn a thread
    // that sets stop + wakeAll and assert the waiter returns.
    var stop = std.atomic.Value(bool).init(false);
    const Waiter = struct {
        f: *SharedFrame,
        s: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
        fn run(w: @This()) void {
            _ = w.f.waitNext(0, w.s);
            w.done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, Waiter.run, .{Waiter{ .f = frame, .s = &stop, .done = &done }});
    // Let the waiter park, then wake it via stop + wakeAll.
    std.Thread.yield() catch {};
    stop.store(true, .release);
    frame.wakeAll();
    th.join();
    try std.testing.expect(done.load(.acquire));
}

test "SharedFrame: markStopped publishes the stopped state once and copyOut carries it" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(t.io());

    // Publish a normal frame first; copyOut reports NOT stopped.
    const index = [_]u8{1} ** 16;
    const palette = [_]u8{0} ** sf.PALETTE_LEN;
    frame.publish(.{ .supported = true, .width = 4, .height = 4, .kind = 0, .pel_mask = 0xFF, .index = &index, .palette = &palette });
    try std.testing.expect(!frame.isStopped());

    var idst: [sf.INDEX_CAP]u8 = undefined;
    var pdst: [sf.PALETTE_LEN]u8 = undefined;
    var rdst: [sf.STOP_REASON_CAP]u8 = undefined;
    {
        const snap = frame.copyOut(&idst, &pdst, &rdst);
        try std.testing.expect(!snap.stopped);
    }

    // markStopped bumps the seqno (wakes parked consumers) and records reason + cycle.
    const seq_before = frame.currentSeqno();
    frame.markStopped("program_terminated", 12345);
    try std.testing.expect(frame.isStopped());
    try std.testing.expectEqual(seq_before + 1, frame.currentSeqno());

    {
        const snap = frame.copyOut(&idst, &pdst, &rdst);
        try std.testing.expect(snap.stopped);
        try std.testing.expectEqual(@as(u64, 12345), snap.stop_cycle);
        try std.testing.expectEqualStrings("program_terminated", snap.stop_reason);
    }

    // Idempotent: a second markStopped does NOT re-publish (no extra seqno bump).
    const seq_after = frame.currentSeqno();
    frame.markStopped("halted", 999);
    try std.testing.expectEqual(seq_after, frame.currentSeqno());
    {
        const snap = frame.copyOut(&idst, &pdst, &rdst);
        try std.testing.expectEqualStrings("program_terminated", snap.stop_reason); // unchanged
        try std.testing.expectEqual(@as(u64, 12345), snap.stop_cycle);
    }
}

// ===========================================================================
// The §6.3 wire header round-trip (parse what writeHeader laid).
// ===========================================================================

test "wire header: magic/version/seqno/dims/lens parse back" {
    var buf: [sf.HEADER_LEN]u8 = undefined;
    sf.writeHeader(&buf, 7, sf.FLAG_HAS_PALETTE, 320, 200, 5, 0xFF, 320 * 200, 768);
    try std.testing.expectEqual(sf.MAGIC, std.mem.readInt(u16, buf[0..2], .little));
    try std.testing.expectEqual(sf.VERSION, buf[2]);
    try std.testing.expect(buf[3] & sf.FLAG_HAS_PALETTE != 0);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u16, 320), std.mem.readInt(u16, buf[8..10], .little));
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[10..12], .little));
    try std.testing.expectEqual(@as(u32, 320 * 200), std.mem.readInt(u32, buf[14..18], .little));
    try std.testing.expectEqual(@as(u16, 768), std.mem.readInt(u16, buf[18..20], .little));
}

// ===========================================================================
// The frame producer is cycle-neutral (drives the real worker/queue; no listener).
// ===========================================================================

const PROG: u32 = 0x0500;
fn loadNopProg(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90);
    b.writePhys8(PROG + 8, 0xF4);
    b.writePhys8(PROG + 9, 0xEB);
    b.writePhys8(PROG + 10, 0xFD);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

test "producer: sampling N frames is cycle-neutral (charges no cycle)" {
    const alloc = std.testing.allocator;
    const t = try makeIo(alloc);
    defer {
        t.deinit();
        alloc.destroy(t);
    }
    const io = t.io();

    const m = try alloc.create(Machine);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    var ctrl = Controller.init(m);

    // The render buffers + queue + worker (the machine side); no net listener.
    const render = try alloc.create(worker.RenderBuffers);
    defer alloc.destroy(render);
    const frame = try alloc.create(SharedFrame);
    defer alloc.destroy(frame);
    frame.* = SharedFrame.init(io);

    var queue = q.CommandQueue.init(io);
    const w: worker.Worker = .{ .queue = &queue, .ctrl = &ctrl, .render = render };
    const worker_thread = try std.Thread.spawn(.{}, worker.Worker.run, .{w});
    defer {
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = queue.submit(&ctx);
        worker_thread.join();
    }

    var rc = run_control.RunControl.init(io);
    // A standalone session lock for the hub's off-queue `render` read (session.zig
    // CONTRACT span #4); in this unit test only the producer touches `render`.
    var session_lock: std.Io.Mutex = .init;
    var hub = stream.StreamHub.init(io, &queue, &rc, render, frame, &session_lock);

    // Advance the machine a bit so there is a defined cycle count.
    {
        var ctx: q.RequestCtx = .{ .cmd = .{ .run = .{ .cycle_cap = 5000 } } };
        _ = queue.submit(&ctx);
    }
    const cycles_before = cycleNow(&queue);

    // Without a client, produceFrame is a no-op (don't sample when nobody watches).
    hub.produceFrame();
    try std.testing.expectEqual(@as(u64, 0), frame.currentSeqno());

    // Force a client so the producer samples; sample several frames.
    _ = hub.active_count.fetchAdd(1, .acq_rel);
    var n: usize = 0;
    while (n < 8) : (n += 1) hub.produceFrame();
    _ = hub.active_count.fetchSub(1, .acq_rel);

    const cycles_after = cycleNow(&queue);
    try std.testing.expectEqual(cycles_before, cycles_after); // the peek charges NO cycle
    // (mode-13h-less nop program may be an unsupported mode → seqno still advances with
    // an "unsupported" marker; either way the cycle ledger is untouched.)
    try std.testing.expect(frame.currentSeqno() >= 1);
}

fn cycleNow(queue: *q.CommandQueue) u64 {
    var ctx: q.RequestCtx = .{ .cmd = .status };
    const resp = queue.submit(&ctx);
    return switch (resp) {
        .status => |s| s.cycles,
        else => 0,
    };
}
