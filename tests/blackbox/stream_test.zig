//! Black-box LIVE-VIDEO-STREAM tests for the zdos debugger API.
//!
//! Each test spawns its OWN REAL `./zig-out/bin/zdos --serve 0 <prog>` child (full
//! process isolation, exactly like `blackbox_test.zig`) and drives the `/api/stream`
//! WebSocket endpoint over real localhost sockets via the `ws.zig` helper. These are
//! the cases that cannot be unit-tested: the std WebSocket handshake (101 + correct
//! `Sec-WebSocket-Accept`), the 426-on-no-upgrade reject, the raw §6.3 indexed frame
//! on the wire, the `MAX_CONNS` connection cap (N+1 → 503), the program-termination
//! `{"event":"stopped"}` control frame, and two concurrent clients + clean shutdown.
//!
//! These migrated from the retired in-process `src/api/server_integration_test.zig`,
//! which faked frame production with white-box hooks (`streamHub().produceFrame()` /
//! `markStopped()`) because it built `Server` WITHOUT a pacer thread. Here the REAL
//! `--serve` binary wires the host run-pacer + stream hub (`src/main.zig`): frames are
//! driven the REAL way — arm the pacer with `POST /api/run/start` and let the producer
//! publish to every connected WS client as the guest free-runs.
//!
//! Determinism note: real socket I/O (ports, frame-arrival timing) is NOT byte-
//! reproducible — these assert CORRECTNESS, not determinism (CLAUDE.md ground rule 1).
//! The bounded retry/yield loops are TEST infrastructure (waiting on a socket), never
//! an emulation-time dependency: the guest advances solely via the explicit pacer arm.
//!
//! Wire-frame constants come from the REAL `api` module surface
//! (`api.shared_frame.*`, `api.stream.MAX_CONNS`) — a frame/stream-contract change
//! FAILS TO COMPILE here (same compile-time coupling rationale as `session.zig`'s
//! `api.wire`).

const std = @import("std");
const api = @import("api");
const Session = @import("session.zig").Session;
const ws = @import("ws.zig");

const testing = std.testing;
const sf = api.shared_frame;

/// `examples/VGA13.COM` — sets VGA mode 13h, fills VRAM with `VRAM[i] = i & 0xFF`, then
/// loops forever. The frozen filled screen makes a WS frame and an HTTP framebuffer read
/// agree byte-for-byte once stable (used by the raw-frame + two-client tests).
const VGA13 = "examples/VGA13.COM";
/// `examples/HELLO.EXE` — prints and TERMINATES via INT 21h/AH=4Ch (used by the
/// program-termination stopped-event test).
const HELLO = "examples/HELLO.EXE";

fn spawn(io: std.Io, prog: []const u8) !Session {
    return Session.spawn(testing.allocator, io, prog);
}

/// Arm the host run-pacer (paced free-run). The producer publishes frames to every
/// connected WS client while armed — the REAL frame-production path (no white-box hook).
fn runStart(s: *Session) !void {
    const r = try s.requestRaw(.POST, "/api/run/start", "{}");
    if (@intFromEnum(r.status) < 200 or @intFromEnum(r.status) >= 300) {
        std.debug.print("run/start failed: HTTP {d}: {s}\n", .{ @intFromEnum(r.status), r.body });
        return error.RunStartFailed;
    }
}

test "WS: handshake returns 101 + correct Sec-WebSocket-Accept" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, HELLO);
    defer s.deinit();

    var hdr: [1024]u8 = undefined;
    const h = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr);
    defer h.client.close();
    try testing.expectEqual(@as(u16, 101), h.status);
    var ebuf: [28]u8 = undefined;
    try testing.expectEqualStrings(ws.expectedAccept(&ebuf), h.accept);
}

test "WS: plain GET /api/stream without upgrade -> 426" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, HELLO);
    defer s.deinit();

    // A plain GET (no Upgrade/Connection headers) is a normal HTTP response, so the
    // session's HTTP client reads it: the server rejects the non-upgrade with 426.
    const r = try s.requestRaw(.GET, "/api/stream", null);
    try testing.expectEqual(@as(u16, 426), @intFromEnum(r.status));
}

test "WS: the (MAX_CONNS+1)th concurrent stream upgrade is rejected with 503 (cap)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, HELLO);
    defer s.deinit();

    var clients: [api.stream.MAX_CONNS]*ws.WsClient = undefined;
    var hdr: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < api.stream.MAX_CONNS) : (i += 1) {
        const h = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr);
        try testing.expectEqual(@as(u16, 101), h.status);
        clients[i] = h.client;
    }
    defer for (clients) |c| c.close();

    // The (N+1)th upgrade must be rejected with 503 (no upgrade), the cap holding.
    const over = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr);
    defer over.client.close();
    try testing.expectEqual(@as(u16, 503), over.status);
}

test "WS: client receives a valid raw-indexed mode-13h frame matching the HTTP framebuffer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, VGA13);
    defer s.deinit();

    var hdr: [1024]u8 = undefined;
    const h = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr);
    defer h.client.close();
    try testing.expectEqual(@as(u16, 101), h.status);

    // Arm the pacer — the REAL producer now publishes frames as VGA13 sets mode 13h and
    // fills VRAM (VRAM[i] = i & 0xFF), then hangs. Early frames may be `{"event":
    // "unsupported"}` TEXT control frames (still text mode) or partial fills; poll the
    // stream until a fully-filled, STABLE mode-13h frame arrives (do NOT hardcode an
    // arrival time). The screen freezes after the fill, so the filled frame is the last
    // one published and the cross-checked HTTP read agrees with it byte-for-byte.
    try runStart(&s);

    const payload = try testing.allocator.alloc(u8, sf.MAX_PAYLOAD);
    defer testing.allocator.free(payload);

    var saw_palette_frame = false; // asserted the §6.3 palette on the FIRST binary frame
    var got_frame = false;
    var tries: usize = 0;
    while (tries < 4000 and !got_frame) : (tries += 1) {
        const f = h.client.readFrame(payload) catch {
            std.Thread.yield() catch {};
            continue;
        };
        if (f.opcode != 2) continue; // skip the unsupported text control frames

        // Parse the §6.3 header. These fields hold on EVERY mode-13h frame.
        try testing.expect(f.len >= sf.HEADER_LEN);
        try testing.expectEqual(sf.MAGIC, std.mem.readInt(u16, payload[0..2], .little));
        try testing.expectEqual(sf.VERSION, payload[2]);
        const flags = payload[3];
        const width = std.mem.readInt(u16, payload[8..10], .little);
        const height = std.mem.readInt(u16, payload[10..12], .little);
        const index_len = std.mem.readInt(u32, payload[14..18], .little);
        const palette_len = std.mem.readInt(u16, payload[18..20], .little);
        try testing.expectEqual(@as(u16, 320), width);
        try testing.expectEqual(@as(u16, 200), height);
        try testing.expectEqual(@as(u32, 320 * 200), index_len);

        if (!saw_palette_frame) {
            // The FIRST binary frame a connection receives ALWAYS carries the full 768-byte
            // palette (§6.3/§4.3: first frame after connect, `last_palette_seq == 0`).
            // Subsequent frames omit it (the mode-13h palette does not change), so this is
            // the one frame on which palette presence is guaranteed.
            try testing.expect(flags & sf.FLAG_HAS_PALETTE != 0);
            try testing.expectEqual(@as(u16, 768), palette_len);
            try testing.expectEqual(@as(usize, sf.HEADER_LEN + index_len + 768), f.len);
            saw_palette_frame = true;
        }

        const index = payload[sf.HEADER_LEN .. sf.HEADER_LEN + index_len];
        // VGA13 fills VRAM SEQUENTIALLY (VRAM[i] = i & 0xFF, i = 0..63999) then hangs, so a
        // frame captured mid-fill has a filled head and a zero tail. Only accept the
        // fully-filled, STABLE screen: every byte must equal i & 0xFF (the tail is the last
        // thing written, so this is true only once the fill completed and the screen froze).
        // A partial fill fails here and we keep polling for the stable frame — this is what
        // makes the cross-check timing-robust without hardcoding a frame-arrival time.
        if (!isFullyFilled(index)) continue;
        // Sanity points on the wrap-every-256 pattern (documented goldens).
        try testing.expectEqual(@as(u8, 0x00), index[0]);
        try testing.expectEqual(@as(u8, 0xFF), index[255]);
        try testing.expectEqual(@as(u8, 0x00), index[256]);

        // CROSS-CHECK: the live HTTP framebuffer (a cycle-neutral peek of the same frozen
        // VRAM) must equal the WS frame's index bytes EXACTLY.
        const fb = try s.framebuffer("index");
        try testing.expectEqual(std.http.Status.ok, fb.status);
        try testing.expectEqual(@as(u16, 320), fb.width);
        try testing.expectEqual(@as(u16, 200), fb.height);
        try testing.expectEqual(@as(u32, 320 * 200), @as(u32, @intCast(fb.data.len)));
        try testing.expectEqualSlices(u8, fb.data, index);
        got_frame = true;
    }
    try testing.expect(saw_palette_frame);
    try testing.expect(got_frame);
}

test "WS: on program termination the client gets a {\"event\":\"stopped\"} text frame" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, HELLO);
    defer s.deinit();

    var hdr: [1024]u8 = undefined;
    const h = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr);
    defer h.client.close();
    try testing.expectEqual(@as(u16, 101), h.status);

    // Arm the pacer: HELLO prints then terminates via INT 21h/AH=4Ch. On program end the
    // hub publishes ONE `{"event":"stopped","reason":"program_terminated","cycle":N}` TEXT
    // control frame. Any binary/unsupported frame before it is fine — keep reading.
    try runStart(&s);

    const payload = try testing.allocator.alloc(u8, sf.MAX_PAYLOAD);
    defer testing.allocator.free(payload);

    var got_stopped = false;
    var tries: usize = 0;
    while (tries < 4000 and !got_stopped) : (tries += 1) {
        const f = h.client.readFrame(payload) catch {
            std.Thread.yield() catch {};
            continue;
        };
        if (f.opcode != 1) continue; // a binary/pixel frame — keep looking for the text one
        const json = payload[0..f.len];
        if (std.mem.indexOf(u8, json, "\"event\":\"stopped\"") == null) continue; // e.g. an "unsupported" text frame
        try testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"program_terminated\"") != null);
        // A real run cycle is present (do NOT assert a specific value).
        try testing.expect(std.mem.indexOf(u8, json, "\"cycle\":") != null);
        got_stopped = true;
    }
    try testing.expect(got_stopped);
}

test "WS: two concurrent clients both receive frames; shutdown is clean" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try spawn(io, VGA13);
    defer s.deinit();

    var hdr_a: [1024]u8 = undefined;
    var hdr_b: [1024]u8 = undefined;
    const a = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr_a);
    defer a.client.close();
    const b = try ws.WsClient.connect(testing.allocator, io, s.port, "/api/stream", &hdr_b);
    defer b.client.close();
    try testing.expectEqual(@as(u16, 101), a.status);
    try testing.expectEqual(@as(u16, 101), b.status);

    // Arm the pacer with BOTH clients connected; each must receive at least one BINARY
    // pixel frame. We drain A to a binary frame first, then B — proving one client's
    // idleness does not stall the other (independent per-connection threads).
    try runStart(&s);

    const payload = try testing.allocator.alloc(u8, sf.MAX_PAYLOAD);
    defer testing.allocator.free(payload);

    try testing.expect(try drainToBinary(a.client, payload));
    try testing.expect(try drainToBinary(b.client, payload));

    // Tear-down is exercised by the deferred `client.close()` + `Session.deinit` (which
    // kills the child): both must complete without hang or leak while two stream
    // connections are live.
}

/// True iff `index` is the fully-filled VGA13 screen: every byte equals i & 0xFF. The
/// fill is sequential, so a mid-fill frame has a zero tail and fails this — only the
/// frozen, completed screen passes.
fn isFullyFilled(index: []const u8) bool {
    for (index, 0..) |b, i| {
        if (b != @as(u8, @truncate(i))) return false;
    }
    return true;
}

/// Read frames until a BINARY pixel frame (opcode 2) arrives (skipping `unsupported`
/// text control frames published before VGA13 sets mode 13h). Bounded poll.
fn drainToBinary(client: *ws.WsClient, payload: []u8) !bool {
    var tries: usize = 0;
    while (tries < 4000) : (tries += 1) {
        const f = client.readFrame(payload) catch {
            std.Thread.yield() catch {};
            continue;
        };
        if (f.opcode == 2) return true;
    }
    return false;
}
