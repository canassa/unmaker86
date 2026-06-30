//! `WsClient` — a minimal WebSocket client for the black-box test harness.
//!
//! It speaks RFC 6455 directly over its OWN `std.Io.net.Stream` (a fresh localhost
//! TCP connection to the spawned `Session`'s port) — it does NOT route through
//! `Session`'s `std.http.Client`, because the live-video stream is a raw socket
//! upgrade (`GET /api/stream` → 101) that the HTTP client abstraction would consume.
//!
//! Ported verbatim (behaviour-preserving) from the retired in-process
//! `src/api/server_integration_test.zig`, but parameterised on `io: std.Io` + the
//! `port: u16` of an already-spawned REAL `zdos --serve 0` child (full process
//! isolation, exactly like `Session`). It is a reusable helper, like `session.zig`:
//! `stream_test.zig` imports it; it carries no tests of its own.
//!
//! Determinism note: the bounded `connect` retry loop is TEST infrastructure only
//! (waiting for a localhost socket to accept) — it touches no emulation state. The
//! guest advances solely via the explicit `/api/run/start` pacer arm the tests issue.

const std = @import("std");

const net = std.Io.net;

/// The RFC 6455 server-side magic GUID + the canonical example client key. The
/// expected `Sec-WebSocket-Accept` is `base64(SHA1(CLIENT_KEY ++ WS_GUID))`.
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="; // RFC 6455 example key

/// Compute the expected `Sec-WebSocket-Accept` for `CLIENT_KEY` into `out` and return
/// the slice. The handshake test compares the server's header against this.
pub fn expectedAccept(out: *[28]u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(CLIENT_KEY);
    sha1.update(WS_GUID);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out[0..];
}

/// The parsed handshake outcome plus the live client. On a non-101 response (e.g. the
/// 503 connection-cap rejection) `status` carries the numeric code and `accept` is
/// empty — the caller still owns `client` and must `close()` it.
pub const Handshake = struct { status: u16, accept: []const u8, client: *WsClient };

pub const WsClient = struct {
    stream: net.Stream,
    io: std.Io,
    alloc: std.mem.Allocator,
    reader: net.Stream.Reader,
    rbuf: [4096]u8 = undefined,

    /// One server→client WS frame: its opcode + payload length (already read into the
    /// caller's buffer).
    pub const Frame = struct { opcode: u4, len: usize };

    /// Connect to `127.0.0.1:port` and perform the WS handshake on `path`. Returns the
    /// parsed status line code + the server's `Sec-WebSocket-Accept` value (the caller
    /// verifies it against `expectedAccept`). The handshake response head (up to the
    /// blank line) is read byte-at-a-time into `hdr_buf`. `alloc` owns the heap-pinned
    /// `WsClient` (the buffered `Reader` holds a pointer into `client.rbuf`, so the
    /// client must not be moved after construction — hence the box).
    pub fn connect(alloc: std.mem.Allocator, io: std.Io, port: u16, path: []const u8, hdr_buf: []u8) !Handshake {
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

        // Send the upgrade request. `bufPrint` formats into `wbuf`, which is ALSO the
        // writer's buffer — copy the formatted request into a separate buffer before
        // writing to avoid aliasing the in-flight writer buffer.
        var wbuf: [512]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const req = try std.fmt.bufPrint(&wbuf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, CLIENT_KEY });
        var req_copy: [512]u8 = undefined;
        @memcpy(req_copy[0..req.len], req);
        try sw.interface.writeAll(req_copy[0..req.len]);
        try sw.interface.flush();

        const client = try alloc.create(WsClient);
        client.* = .{ .stream = stream, .io = io, .alloc = alloc, .reader = undefined };
        client.reader = client.stream.reader(io, &client.rbuf);

        // Read the response head (up to the terminating \r\n\r\n) into `hdr_buf`.
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

    /// Read ONE server→client WS frame (unmasked, as the server always sends). Returns
    /// the opcode + payload length; the payload is read into `payload`. Handles the
    /// 7/16/64-bit length encodings.
    pub fn readFrame(self: *WsClient, payload: []u8) !Frame {
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

    pub fn close(self: *WsClient) void {
        self.stream.close(self.io);
        self.alloc.destroy(self);
    }
};
