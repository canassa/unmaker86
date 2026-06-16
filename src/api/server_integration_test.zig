//! The single REAL-SOCKET integration test (opt-in: `zig build test-api-integration`,
//! NOT in the default `test` aggregate). It covers the one piece that cannot be
//! unit-tested: the listener + `net.Server.accept` + `http.Server` over a real
//! localhost TCP socket. It asserts CORRECTNESS of one request — NOT determinism
//! (real socket I/O — port numbers, timing — is not byte-reproducible; determinism
//! is proved by the in-process tests 1-9 below the socket).

const std = @import("std");
const server_mod = @import("server.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Server = server_mod.Server;
const net = std.Io.net;
const Reg32 = cpu_mod.state.Reg32;

const PORT: u16 = 39517; // a fixed high port for the opt-in test

const PROG: u32 = 0x0500;
fn loadNopProg(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90);
    b.writePhys8(PROG + 8, 0xF4);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

fn runServer(srv: *Server) void {
    srv.run() catch {};
}

test "real socket: GET /api/status returns valid JSON" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const m = try alloc.create(Machine);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    var ctrl = Controller.init(m);

    // This test never drives `POST /api/load`; pass cwd as the (unused) mount dir.
    var srv = try Server.init(alloc, io, &ctrl, PORT, server_mod.LoadRecipe.init(2, "PROG.COM", ""), std.Io.Dir.cwd());
    defer srv.deinit();

    const listener = try std.Thread.spawn(.{}, runServer, .{&srv});

    // Connect (retry until the listener is bound).
    const addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    var stream: net.Stream = blk: {
        var attempt: usize = 0;
        while (attempt < 200) : (attempt += 1) {
            const s = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
                std.Thread.yield() catch {};
                continue;
            };
            break :blk s;
        }
        srv.shutdown();
        listener.join();
        return error.CouldNotConnect;
    };

    // Send the request.
    {
        var wbuf: [256]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        try sw.interface.writeAll("GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n");
        try sw.interface.flush();
    }

    // Read the response.
    var resp_buf: [4096]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const n = sr.interface.readSliceShort(&resp_buf) catch 0;
    const resp = resp_buf[0..n];

    stream.close(io);
    srv.shutdown();
    listener.join();

    // Assert one correct request: 200 + the status JSON keys.
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"runnable\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cycles\":") != null);
}

// ===========================================================================
// Live-stream WebSocket tests (Phase 3) — REAL sockets, opt-in. They cover the
// pieces that cannot be unit-tested: the std WebSocket handshake (101 + correct
// Sec-WebSocket-Accept), the raw-indexed frame on the wire (§6.3), the N+1 → 503
// connection cap (§9.1), two concurrent clients (one slow client must not stall the
// other or the producer), and a clean shutdown with a live stream connection.
// ===========================================================================

const stream_mod = @import("stream.zig");
const sf = @import("shared_frame.zig");

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="; // RFC 6455 example key

fn expectedAccept(out: *[28]u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(CLIENT_KEY);
    sha1.update(WS_GUID);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out[0..];
}

/// Put the served machine into mode 13h with a known VRAM pattern + palette so the
/// producer can publish a real graphics frame (not an "unsupported" marker).
fn setMode13(m: *Machine) void {
    m.bus.writePhys8(0x400 + 0x49, 0x13); // OFF_VIDEO_MODE = 13h
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) m.vga.vram[i] = @truncate(i * 3 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 5, .blue = 9 };
}

const WsClient = struct {
    stream: net.Stream,
    io: std.Io,
    reader: net.Stream.Reader,
    rbuf: [4096]u8 = undefined,

    /// Connect + perform the WS handshake on `path`. Returns the parsed 101 status and
    /// the server's Sec-WebSocket-Accept value (caller verifies). On a non-101 (e.g. the
    /// 503 cap), `status` carries the numeric code and `accept` is empty.
    fn connect(io: std.Io, port: u16, path: []const u8, hdr_buf: []u8) !struct { status: u16, accept: []const u8, client: *WsClient } {
        const alloc = std.testing.allocator;
        const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream: net.Stream = blk: {
            var attempt: usize = 0;
            while (attempt < 400) : (attempt += 1) {
                const s = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
                    std.Thread.yield() catch {};
                    continue;
                };
                break :blk s;
            }
            return error.CouldNotConnect;
        };

        // Send the upgrade request.
        var wbuf: [512]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const req = try std.fmt.bufPrint(&wbuf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, CLIENT_KEY });
        // bufPrint reused `wbuf` which is also the writer buffer — write via a separate
        // small buffer to avoid aliasing.
        var req_copy: [512]u8 = undefined;
        @memcpy(req_copy[0..req.len], req);
        try sw.interface.writeAll(req_copy[0..req.len]);
        try sw.interface.flush();

        const client = try alloc.create(WsClient);
        client.* = .{ .stream = stream, .io = io, .reader = undefined };
        client.reader = client.stream.reader(io, &client.rbuf);

        // Read the response head (up to \r\n\r\n) into hdr_buf.
        var got: usize = 0;
        while (got < hdr_buf.len) {
            const n = client.reader.interface.readSliceShort(hdr_buf[got .. got + 1]) catch break;
            if (n == 0) break;
            got += n;
            if (got >= 4 and std.mem.eql(u8, hdr_buf[got - 4 .. got], "\r\n\r\n")) break;
        }
        const head = hdr_buf[0..got];
        const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return error.BadResponse;
        const status = std.fmt.parseInt(u16, head[sp + 1 .. sp + 4], 10) catch 0;
        var accept: []const u8 = "";
        if (std.ascii.indexOfIgnoreCase(head, "sec-websocket-accept:")) |ai| {
            const after = head[ai + "sec-websocket-accept:".len ..];
            const eol = std.mem.indexOf(u8, after, "\r\n") orelse after.len;
            accept = std.mem.trim(u8, after[0..eol], " ");
        }
        return .{ .status = status, .accept = accept, .client = client };
    }

    /// Read ONE server→client WS frame (unmasked). Returns the opcode + the payload
    /// (into `payload`). Handles the 7/16/64-bit length forms.
    fn readFrame(self: *WsClient, payload: []u8) !struct { opcode: u4, len: usize } {
        var h: [2]u8 = undefined;
        try self.readExact(&h);
        const opcode: u4 = @truncate(h[0] & 0x0F);
        const len7: u7 = @truncate(h[1] & 0x7F);
        var len: usize = len7;
        if (len7 == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len7 == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            len = @intCast(std.mem.readInt(u64, &ext, .big));
        }
        if (len > payload.len) return error.FrameTooBig;
        try self.readExact(payload[0..len]);
        return .{ .opcode = opcode, .len = len };
    }

    fn readExact(self: *WsClient, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            const n = self.reader.interface.readSliceShort(dst[got..]) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            got += n;
        }
    }

    fn close(self: *WsClient) void {
        self.stream.close(self.io);
        std.testing.allocator.destroy(self);
    }
};

fn driveProducer(srv: *Server, n: usize) void {
    // Pump the producer directly (no pacer in this test). Each call submits a
    // framebuffer_get peek + publishes into the shared frame.
    var i: usize = 0;
    while (i < n) : (i += 1) srv.streamHub().produceFrame();
}

const WS_PORT_BASE: u16 = 39600;

fn bootServer(alloc: std.mem.Allocator, io: std.Io, port: u16, m_out: **Machine, ctrl_out: *Controller, srv_out: **Server) !std.Thread {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    setMode13(m);
    ctrl_out.* = Controller.init(m);
    const srv = try alloc.create(Server);
    srv.* = try Server.init(alloc, io, ctrl_out, port, server_mod.LoadRecipe.init(2, "PROG.COM", ""), std.Io.Dir.cwd());
    m_out.* = m;
    srv_out.* = srv;
    return try std.Thread.spawn(.{}, runServer, .{srv});
}

test "WS: handshake returns 101 + correct Sec-WebSocket-Accept" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE, &m, &ctrl, &srv);
    defer {
        srv.shutdown();
        listener.join();
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    var hdr: [1024]u8 = undefined;
    const h = try WsClient.connect(io, WS_PORT_BASE, "/api/stream", &hdr);
    defer h.client.close();
    try std.testing.expectEqual(@as(u16, 101), h.status);
    var ebuf: [28]u8 = undefined;
    try std.testing.expectEqualStrings(expectedAccept(&ebuf), h.accept);
}

test "WS: plain GET /api/stream without upgrade → 426" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE + 1, &m, &ctrl, &srv);
    defer {
        srv.shutdown();
        listener.join();
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    const addr: net.IpAddress = .{ .ip4 = .loopback(WS_PORT_BASE + 1) };
    var stream: net.Stream = blk: {
        var attempt: usize = 0;
        while (attempt < 400) : (attempt += 1) {
            const s = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
                std.Thread.yield() catch {};
                continue;
            };
            break :blk s;
        }
        return error.CouldNotConnect;
    };
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll("GET /api/stream HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();
    var resp: [1024]u8 = undefined;
    var rbuf: [1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const n = sr.interface.readSliceShort(&resp) catch 0;
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "426") != null);
}

test "WS: client receives a valid raw-indexed frame (header + index + palette)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE + 2, &m, &ctrl, &srv);
    defer {
        srv.shutdown();
        listener.join();
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    var hdr: [1024]u8 = undefined;
    const h = try WsClient.connect(io, WS_PORT_BASE + 2, "/api/stream", &hdr);
    defer h.client.close();
    try std.testing.expectEqual(@as(u16, 101), h.status);

    // Drive the producer (the connect auto-armed the pacer, but there is no pacer thread
    // in this test — pump directly). A short retry lets the stream thread park first.
    var got_frame = false;
    const payload = try alloc.alloc(u8, sf.MAX_PAYLOAD);
    defer alloc.free(payload);
    var tries: usize = 0;
    while (tries < 50 and !got_frame) : (tries += 1) {
        driveProducer(srv, 1);
        const f = h.client.readFrame(payload) catch {
            std.Thread.yield() catch {};
            continue;
        };
        try std.testing.expectEqual(@as(u4, 2), f.opcode); // binary
        // Parse the §6.3 header.
        try std.testing.expect(f.len >= sf.HEADER_LEN);
        try std.testing.expectEqual(sf.MAGIC, std.mem.readInt(u16, payload[0..2], .little));
        try std.testing.expectEqual(sf.VERSION, payload[2]);
        const flags = payload[3];
        const width = std.mem.readInt(u16, payload[8..10], .little);
        const height = std.mem.readInt(u16, payload[10..12], .little);
        const index_len = std.mem.readInt(u32, payload[14..18], .little);
        const palette_len = std.mem.readInt(u16, payload[18..20], .little);
        try std.testing.expectEqual(@as(u16, 320), width);
        try std.testing.expectEqual(@as(u16, 200), height);
        try std.testing.expectEqual(@as(u32, 320 * 200), index_len);
        // First frame after connect → palette present.
        try std.testing.expect(flags & sf.FLAG_HAS_PALETTE != 0);
        try std.testing.expectEqual(@as(u16, 768), palette_len);
        try std.testing.expectEqual(@as(usize, sf.HEADER_LEN + index_len + 768), f.len);
        // The index bytes match the mode-13h VRAM pattern.
        try std.testing.expectEqual(m.vga.vram[0], payload[sf.HEADER_LEN]);
        try std.testing.expectEqual(m.vga.vram[123], payload[sf.HEADER_LEN + 123]);
        got_frame = true;
    }
    try std.testing.expect(got_frame);
}

test "WS: the 5th concurrent stream upgrade is rejected with 503 (cap)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE + 3, &m, &ctrl, &srv);
    defer {
        srv.shutdown();
        listener.join();
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    var clients: [stream_mod.MAX_CONNS]*WsClient = undefined;
    var hdr: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < stream_mod.MAX_CONNS) : (i += 1) {
        const h = try WsClient.connect(io, WS_PORT_BASE + 3, "/api/stream", &hdr);
        try std.testing.expectEqual(@as(u16, 101), h.status);
        clients[i] = h.client;
    }
    defer for (clients) |c| c.close();

    // The (N+1)th upgrade must be rejected with 503 (no upgrade).
    const over = try WsClient.connect(io, WS_PORT_BASE + 3, "/api/stream", &hdr);
    defer over.client.close();
    try std.testing.expectEqual(@as(u16, 503), over.status);
}

test "WS: on program termination the client gets a {\"event\":\"stopped\"} text frame" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE + 5, &m, &ctrl, &srv);
    defer {
        srv.shutdown();
        listener.join();
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    var hdr: [1024]u8 = undefined;
    const h = try WsClient.connect(io, WS_PORT_BASE + 5, "/api/stream", &hdr);
    defer h.client.close();
    try std.testing.expectEqual(@as(u16, 101), h.status);

    const payload = try alloc.alloc(u8, sf.MAX_PAYLOAD);
    defer alloc.free(payload);

    // First a normal mid-run frame: it MUST be a BINARY frame (opcode 2), never text.
    var got_binary = false;
    var tries: usize = 0;
    while (tries < 50 and !got_binary) : (tries += 1) {
        driveProducer(srv, 1);
        if (h.client.readFrame(payload)) |f| {
            try std.testing.expectEqual(@as(u4, 2), f.opcode); // binary, NOT a control frame
            got_binary = true;
        } else |_| {
            std.Thread.yield() catch {};
        }
    }
    try std.testing.expect(got_binary);

    // The guest program terminates — the pacer signals the hub (here we call it directly,
    // as the program-end terminal path does). The connected client must receive ONE
    // `{"event":"stopped",...}` TEXT control frame (opcode 1) with the right shape.
    srv.streamHub().markStopped("program_terminated", 4242);

    var got_stopped = false;
    tries = 0;
    while (tries < 80 and !got_stopped) : (tries += 1) {
        if (h.client.readFrame(payload)) |f| {
            if (f.opcode == 1) { // TEXT control frame
                const json = payload[0..f.len];
                try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"stopped\"") != null);
                try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"program_terminated\"") != null);
                try std.testing.expect(std.mem.indexOf(u8, json, "\"cycle\":4242") != null);
                got_stopped = true;
            }
            // a stray binary frame (a late publish) is fine — keep looking for the text one
        } else |_| {
            std.Thread.yield() catch {};
        }
    }
    try std.testing.expect(got_stopped);
}

test "WS: two concurrent clients both receive frames; shutdown joins cleanly" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m: *Machine = undefined;
    var ctrl: Controller = undefined;
    var srv: *Server = undefined;
    const listener = try bootServer(alloc, io, WS_PORT_BASE + 4, &m, &ctrl, &srv);
    // NOTE: shutdown is exercised inside this test (a live connection at shutdown).
    defer {
        srv.deinit();
        m.deinit();
        alloc.destroy(m);
        alloc.destroy(srv);
    }

    var hdr1: [1024]u8 = undefined;
    var hdr2: [1024]u8 = undefined;
    const a = try WsClient.connect(io, WS_PORT_BASE + 4, "/api/stream", &hdr1);
    const b = try WsClient.connect(io, WS_PORT_BASE + 4, "/api/stream", &hdr2);
    try std.testing.expectEqual(@as(u16, 101), a.status);
    try std.testing.expectEqual(@as(u16, 101), b.status);

    const payload = try alloc.alloc(u8, sf.MAX_PAYLOAD);
    defer alloc.free(payload);

    // Client A reads frames; client B stays idle (a "slow" client whose socket buffer
    // fills). Drive the producer; A must keep receiving — B's idleness must not stall it.
    var a_frames: usize = 0;
    var tries: usize = 0;
    while (tries < 80 and a_frames < 1) : (tries += 1) {
        driveProducer(srv, 1);
        if (a.client.readFrame(payload)) |f| {
            if (f.opcode == 2) a_frames += 1;
        } else |_| {
            std.Thread.yield() catch {};
        }
    }
    try std.testing.expect(a_frames >= 1);

    // Now drain B too (it should also have buffered frames).
    var b_frames: usize = 0;
    driveProducer(srv, 1);
    if (b.client.readFrame(payload)) |f| {
        if (f.opcode == 2) b_frames += 1;
    } else |_| {}
    try std.testing.expect(b_frames >= 1);

    // Shutdown with BOTH connections live: must stop-flag + shutdown sockets + join the
    // stream threads cleanly (no hang, no leak). The accept loop's joinWorker runs the
    // stream-hub shutdown before the worker sentinel.
    srv.shutdown();
    listener.join();
    a.client.close();
    b.client.close();
}
