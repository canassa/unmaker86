//! SAME-SESSION concurrency stress test (the regression guard for the per-session
//! concurrency CONTRACT in session.zig). Going thread-per-connection exposed several
//! same-session data races on the NON-QUEUE shared state — the render/png_out capture
//! buffers, the `run_control` owner save/restore, and the `recipe` overlay/persist —
//! that the old serial accept loop protected only ACCIDENTALLY. This test hammers ONE
//! session from many real OS connection threads, mixing the three previously-racy
//! paths (`screenshot`/framebuffer-png + `run`/`step` + `load`), and asserts the
//! INVARIANTS the lock must uphold — never a specific interleaving (scheduling is
//! legitimately nondeterministic; only per-machine state must stay sound):
//!
//!   (a) no crash / UB (it runs under the Debug allocator's thread-safe checks, and a
//!       torn buffer or lock-order deadlock would hang/trip here);
//!   (b) every framebuffer-PNG capture returns HTTP 200 with an intact PNG signature
//!       (`\x89PNG…`) and a non-empty body — a torn frame / corrupted `png_out` (two
//!       concurrent captures racing `session.render`) would corrupt the signature;
//!   (c) the run-owner never gets STUCK: after the storm a `/api/run/start` succeeds
//!       (200, not a permanent 409) — proving two concurrent run/step spans did not
//!       interleave the `beginDebugger`/`endDebugger` owner save/restore;
//!   (d) the `recipe` never tears: each load thread writes a recipe whose `file` and
//!       `cmdtail` both encode the SAME thread digit, so a lost-update / torn write
//!       would leave the persisted recipe's `file` digit ≠ its `cmdtail` digit;
//!   (e) the machine stays self-consistent and responsive (`/api/status`,`/api/cpu` 200).
//!
//! Concurrency is driven by spawning REAL connection threads, each calling the
//! in-process `serveOne` over its OWN in-memory streams against the SHARED server +
//! its single default session + its one worker thread — mirroring how the real accept
//! loop hands each connection its own `Conn`, so it exercises the exact per-connection
//! ownership + per-session lock the production path uses (no real socket needed).

const std = @import("std");
const server_mod = @import("server.zig");
const q = @import("queue.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const http = std.http;

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Server = server_mod.Server;
const Reg32 = cpu_mod.state.Reg32;

// A fresh machine at entry: 8 NOPs then HLT + a tight self-jump (the server_test
// fixture), so /api/step and /api/run have a defined, terminating program to drive.
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

/// Lay mode 13h (320x200x8) into the default session's machine so every framebuffer
/// capture renders a real, supported graphics frame (mirrors the mode-13h fixtures in
/// server_test.zig / mcp_test.zig). The load threads use a NULL mount, so a `load`
/// returns `load_failed` WITHOUT re-booting — the VGA mode stays 13h for the run.
fn layMode13h(m: *Machine) void {
    m.bus.writePhys8(0x400 + 0x49, 0x13); // OFF_VIDEO_MODE = 13h
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) m.vga.vram[i] = @truncate(i * 3 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 5, .blue = 9 };
}

/// A live test server with a real machine + Controller + queue + worker thread, no
/// listener. The worker uses a NULL mount (so `load` exercises the recipe overlay/
/// persist race then fails cleanly without re-booting) but a real `render` buffer (so
/// framebuffer captures render for real). Requests are fed via `request`, callable
/// concurrently from many threads (each builds its OWN `Conn` in `serveOne`).
const TestServer = struct {
    alloc: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    m: *Machine,
    ctrl: Controller,
    srv: *Server,
    worker: std.Thread,

    fn init(alloc: std.mem.Allocator) !TestServer {
        const threaded = try alloc.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(alloc, .{});
        const io = threaded.io();
        const m = try alloc.create(Machine);
        try m.init(alloc, &.{});
        m.wire();
        loadNopProg(m);
        layMode13h(m);
        const srv = try alloc.create(Server);
        srv.* = try Server.init(alloc, io, undefined, 0, server_mod.LoadRecipe.init(2, "PROG.COM", ""), std.Io.Dir.cwd());
        return .{ .alloc = alloc, .threaded = threaded, .m = m, .ctrl = Controller.init(m), .srv = srv, .worker = undefined };
    }

    fn start(self: *TestServer) !void {
        self.srv.session.ctrl = &self.ctrl;
        const w = struct {
            fn run(s: *Server) void {
                const worker = @import("worker.zig");
                const ww: worker.Worker = .{ .queue = &s.session.queue, .ctrl = s.session.ctrl, .render = s.session.render };
                ww.run();
            }
        };
        self.worker = try std.Thread.spawn(.{}, w.run, .{self.srv});
    }

    fn deinit(self: *TestServer) void {
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.srv.session.queue.submit(&ctx);
        self.worker.join();
        self.srv.deinit();
        self.m.deinit();
        self.alloc.destroy(self.m);
        self.alloc.destroy(self.srv);
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
    }

    /// Issue one raw HTTP request over in-memory streams; return the FULL raw response.
    /// Re-entrant: each call has its own reader/writer/`http.Server`/`Conn`, so many
    /// threads can call this concurrently against the shared server + session.
    fn request(self: *TestServer, raw: []const u8, out_buf: []u8) []const u8 {
        var in = std.Io.Reader.fixed(raw);
        var out = std.Io.Writer.fixed(out_buf);
        var hs = http.Server.init(&in, &out);
        self.srv.serveOne(&hs);
        return out.buffered();
    }
};

fn statusOf(raw: []const u8) u16 {
    const sp = std.mem.indexOfScalar(u8, raw, ' ') orelse return 0;
    return std.fmt.parseInt(u16, raw[sp + 1 .. sp + 4], 10) catch 0;
}
fn bodyOf(raw: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
    return raw[sep + 4 ..];
}

const PNG_SIG = "\x89PNG\r\n\x1a\n";
const ITERS: usize = 40;

// ---- the three previously-racy connection-thread workloads ----

/// CAPTURE: spam `/api/framebuffer?format=png`; every reply must be 200 with an intact
/// PNG signature (a torn frame / corrupted png_out from a concurrent capture corrupts it).
fn captureLoop(ts: *TestServer, fail: *std.atomic.Value(bool)) void {
    const out = ts.alloc.alloc(u8, 512 * 1024) catch {
        fail.store(true, .release);
        return;
    };
    defer ts.alloc.free(out);
    var n: usize = 0;
    while (n < ITERS) : (n += 1) {
        const raw = ts.request("GET /api/framebuffer?format=png HTTP/1.1\r\nHost: x\r\n\r\n", out);
        const body = bodyOf(raw);
        if (statusOf(raw) != 200 or body.len <= PNG_SIG.len or !std.mem.eql(u8, body[0..PNG_SIG.len], PNG_SIG)) {
            fail.store(true, .release);
            return;
        }
    }
}

/// DEBUGGER: alternate `/api/step` and `/api/run` — the begin/endDebugger owner span.
/// Every reply must be 200 carrying a `"stop"` reason (a stuck owner would 409 a `run`).
fn debuggerLoop(ts: *TestServer, fail: *std.atomic.Value(bool)) void {
    var out: [8 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < ITERS) : (n += 1) {
        const raw = if (n & 1 == 0)
            ts.request("POST /api/step HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: 0\r\n\r\n", &out)
        else
            ts.request("POST /api/run HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: 19\r\n\r\n{\"cycle_cap\":1000}", &out);
        if (statusOf(raw) != 200 or std.mem.indexOf(u8, bodyOf(raw), "\"stop\":") == null) {
            fail.store(true, .release);
            return;
        }
    }
}

/// RECIPE: spam `/api/load` with a recipe whose `file` and `cmdtail` BOTH encode this
/// thread's digit at index 1 — so a torn read-modify-write of `session.recipe` would
/// leave the persisted `file[1]` ≠ `cmdtail[1]`. The NULL-mount worker returns 503
/// (load_failed) AFTER the connection thread persisted the recipe (the racy part), so
/// 200/503 are both fine; only the recipe's internal consistency is asserted post-storm.
fn loadLoop(ts: *TestServer, digit: u8, fail: *std.atomic.Value(bool)) void {
    var out: [4 * 1024]u8 = undefined;
    var body_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"drive\":2,\"file\":\"F{c}.COM\",\"cmdtail\":\"C{c}\"}}", .{ digit, digit }) catch unreachable;
    var req_buf: [256]u8 = undefined;
    const raw_req = std.fmt.bufPrint(&req_buf, "POST /api/load HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    var n: usize = 0;
    while (n < ITERS) : (n += 1) {
        const raw = ts.request(raw_req, &out);
        const st = statusOf(raw);
        if (st != 200 and st != 503) {
            fail.store(true, .release);
            return;
        }
    }
}

test "same-session concurrency storm: screenshot + run/step + load stays sound" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();

    var fail = std.atomic.Value(bool).init(false);

    const CAP = 4;
    const DBG = 4;
    const LOAD = 4;
    var threads: [CAP + DBG + LOAD]std.Thread = undefined;
    var ti: usize = 0;
    var i: usize = 0;
    while (i < CAP) : (i += 1) {
        threads[ti] = try std.Thread.spawn(.{}, captureLoop, .{ &ts, &fail });
        ti += 1;
    }
    i = 0;
    while (i < DBG) : (i += 1) {
        threads[ti] = try std.Thread.spawn(.{}, debuggerLoop, .{ &ts, &fail });
        ti += 1;
    }
    i = 0;
    while (i < LOAD) : (i += 1) {
        threads[ti] = try std.Thread.spawn(.{}, loadLoop, .{ &ts, '0' + @as(u8, @intCast(i)), &fail });
        ti += 1;
    }
    for (threads) |t| t.join();

    // (a)/(b)/(c-as-409)/(d-as-503): no worker thread set the failure flag.
    try std.testing.expect(!fail.load(.acquire));

    // (d) the recipe never tore: `file[1]` and `cmdtail[1]` are the SAME thread digit.
    const recipe = ts.srv.session.recipe;
    try std.testing.expect(recipe.file_len >= 2 and recipe.cmdtail_len >= 2);
    try std.testing.expectEqual(recipe.file[1], recipe.cmdtail[1]);

    // (c) the run-owner is NOT stuck at `debugger`: a fresh start succeeds (200, not 409).
    var out: [8 * 1024]u8 = undefined;
    const start = ts.request("POST /api/run/start HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: 0\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u16, 200), statusOf(start));
    const stop = ts.request("POST /api/run/stop HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: 0\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u16, 200), statusOf(stop));

    // (e) the machine stays self-consistent + responsive after the storm.
    const status = ts.request("GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u16, 200), statusOf(status));
    try std.testing.expect(std.mem.indexOf(u8, bodyOf(status), "\"cycles\":") != null);
    const cpu = ts.request("GET /api/cpu HTTP/1.1\r\nHost: x\r\n\r\n", &out);
    try std.testing.expectEqual(@as(u16, 200), statusOf(cpu));
    try std.testing.expect(std.mem.indexOf(u8, bodyOf(cpu), "\"eip\":") != null);
}

// ===========================================================================
// Finding 2 (HIGH liveness) regression: the CAPTURE paths release `session.lock`
// BEFORE the unbounded socket write. Pre-fix the lock was held across the whole
// `req.respond` wire write; the pacer's inline `produceFrame` takes the SAME lock, so a
// slow/stalled capture client froze the pacer → the GUEST STOPPED ADVANCING. This test
// drives the REAL `submitAndRespondFramebuffer` over a writer that STALLS mid-write (a
// deterministic atomic handshake — no host clock), then proves the pacer can still take
// `session.lock` (via the real `produceFrame`) AND advance the guest: we assert the guest
// CYCLE COUNTER strictly increases across N pacer ticks while the capture write is parked.
// We assert on cycle-counter monotonicity, never on timing. Pre-fix this DEADLOCKS in
// `produceFrame` (the held lock) — i.e. the guest is frozen — exactly the bug.
// ===========================================================================

/// A response writer that BLOCKS on its first drain (the wire write) until the test
/// releases it — a faithful stand-in for a slow/stalled capture client. Bytes are
/// discarded after the stall (we assert on the guest cycle counter, not the body). The
/// handshake is two atomics (no host clock), so the stall is deterministic.
const StallWriter = struct {
    writer: std.Io.Writer,
    started: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),

    fn init(buf: []u8, started: *std.atomic.Value(bool), release: *std.atomic.Value(bool)) StallWriter {
        return .{
            .writer = .{
                .vtable = &.{ .drain = drain, .sendFile = std.Io.Writer.unimplementedSendFile },
                .buffer = buf,
            },
            .started = started,
            .release = release,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StallWriter = @alignCast(@fieldParentPtr("writer", w));
        // First drain == the response wire write has begun. The capture path has ALREADY
        // released `session.lock` by here (post-fix), so park until the test releases us.
        if (!self.started.swap(true, .acq_rel)) {
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        }
        // Discard (like std.Io.Writer.Discarding) so `respond` completes after release.
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var written: usize = pattern.len * splat;
        for (slice) |bytes| written += bytes.len;
        w.end = 0;
        return written;
    }
};

const StallCtx = struct {
    ts: *TestServer,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(c: *StallCtx) void {
        var in = std.Io.Reader.fixed("GET /api/framebuffer?format=png HTTP/1.1\r\nHost: x\r\n\r\n");
        var backing: [4096]u8 = undefined;
        var sw = StallWriter.init(&backing, &c.started, &c.release);
        var hs = http.Server.init(&in, &sw.writer);
        c.ts.srv.serveOne(&hs); // blocks inside `req.respond`'s drain until released
    }
};

fn cycleNow(queue: *q.CommandQueue) u64 {
    var ctx: q.RequestCtx = .{ .cmd = .status };
    return switch (queue.submit(&ctx)) {
        .status => |s| s.cycles,
        else => 0,
    };
}

test "pacer liveness: a stalled capture does NOT freeze the guest (cycles keep advancing)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    // An infinite tight loop (`jmp $`) at the entry so every `run` slice advances the
    // cycle counter by ~cycle_cap with no halt — a clean monotonicity signal.
    ts.m.bus.writePhys8(PROG, 0xEB);
    ts.m.bus.writePhys8(PROG + 1, 0xFE);
    ts.m.cpu.st.eip = PROG;
    try ts.start();
    defer ts.deinit();

    // Wire the session's stream hub onto `&session.lock` (the SAME lock the capture path
    // takes) and force a "client" so `produceFrame` actually samples (it no-ops with none).
    ts.srv.wireStream();
    const hub = ts.srv.streamHub();
    _ = hub.active_count.fetchAdd(1, .acq_rel);
    defer {
        _ = hub.active_count.fetchSub(1, .acq_rel);
    }

    // Launch a capture whose wire write STALLS mid-flight (lock already released post-fix).
    var ctx = StallCtx{ .ts = &ts };
    const cap_thread = try std.Thread.spawn(.{}, StallCtx.run, .{&ctx});
    // Release + join via defer so an assertion failure UNBLOCKS the parked capture and joins
    // it cleanly (a leaked stalled thread would hang teardown, masking the real failure).
    defer cap_thread.join();
    defer ctx.release.store(true, .release);
    // Wait (deterministic handshake, no clock) until the capture is parked in its write.
    while (!ctx.started.load(.acquire)) std.atomic.spinLoopHint();

    // The pacer's job WHILE the capture write is outstanding: `produceFrame` (takes
    // `session.lock` — would DEADLOCK pre-fix) + a run slice; the cycle counter must
    // strictly increase every tick. Frozen pre-fix; live post-fix.
    var prev = cycleNow(&ts.srv.session.queue);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        hub.produceFrame(); // proves the lock is free during the capture's wire write
        var rctx: q.RequestCtx = .{ .cmd = .{ .run = .{ .cycle_cap = 2000 } } };
        _ = ts.srv.session.queue.submit(&rctx);
        const now = cycleNow(&ts.srv.session.queue);
        try std.testing.expect(now > prev); // STRICTLY increasing — the guest advanced
        prev = now;
    }
}
