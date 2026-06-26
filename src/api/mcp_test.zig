//! Phase-1 MCP (Model Context Protocol) tests (M3, mcp-plan.md §9), driven IN-PROCESS
//! over in-memory reader/writer streams — a REAL machine + Controller + queue + worker
//! thread, no socket (the same harness shape as `server_test.zig`). They exercise the
//! full `POST /mcp` → JSON-RPC envelope → buildCommand → queue.submit → worker →
//! Response → shared `writeX` → tool-result content path.
//!
//! The load-bearing case is the ANTI-DRIFT equivalence: a tool's inner content body is
//! byte-for-byte the body the equivalent HTTP route emits (`step`↔`/api/step`,
//! `read_cpu`↔`/api/cpu`, `read_memory`↔`/api/mem`) — proving the two front-ends share
//! one serializer, not two copies.

const std = @import("std");
const build_options = @import("build_options");
const server_mod = @import("server.zig");
const q = @import("queue.zig");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const mcp = @import("mcp.zig");
const mcp_tools = @import("mcp_tools.zig");
const http = std.http;

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Server = server_mod.Server;
const Reg32 = cpu_mod.state.Reg32;

// --- a fresh machine at entry: 8 NOPs, then HLT + a tight self-jump (matches the
//     server_test.zig fixture so the equivalence comparisons share a known program). ---
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
fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    loadNopProg(m);
    return m;
}
fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

/// A live test server (real machine + Controller + queue + worker thread; no listener).
/// The DEFAULT session drives the hand-built NOP machine `m` exactly as before; the load
/// RECIPE + mount dir are pointed at the committed `examples/HELLO.COM` so an MCP
/// `initialize` (which now MINTS a fresh booted session via the registry, Phase 3) has a
/// real program to boot. The recipe/mount only affect mint/load/reset — every existing
/// test uses the blank-session default machine, so its behavior is unchanged.
const TestServer = struct {
    alloc: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    dir: std.Io.Dir,
    m: *Machine,
    ctrl: Controller,
    srv: *Server,
    worker: std.Thread,

    fn init(alloc: std.mem.Allocator) !TestServer {
        const threaded = try alloc.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(alloc, .{});
        const io = threaded.io();
        const dir = try std.Io.Dir.cwd().openDir(io, build_options.examples_dir, .{ .iterate = true });
        const m = try makeMachine(alloc);
        const srv = try alloc.create(Server);
        srv.* = try Server.init(alloc, io, undefined, 0, server_mod.LoadRecipe.init(2, "HELLO.COM", ""), dir);
        return .{
            .alloc = alloc,
            .threaded = threaded,
            .dir = dir,
            .m = m,
            .ctrl = Controller.init(m),
            .srv = srv,
            .worker = undefined,
        };
    }

    fn start(self: *TestServer) !void {
        self.srv.session.?.ctrl = &self.ctrl;
        const w = struct {
            fn run(s: *Server) void {
                const worker = @import("worker.zig");
                const ww: worker.Worker = .{ .queue = &s.session.?.queue, .ctrl = s.session.?.ctrl, .render = s.session.?.render };
                ww.run();
            }
        };
        self.worker = try std.Thread.spawn(.{}, w.run, .{self.srv});
    }

    fn deinit(self: *TestServer) void {
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.srv.session.?.queue.submit(&ctx);
        self.worker.join();
        self.srv.deinit(); // also tears down any registry-minted sessions (joins their workers)
        destroy(self.alloc, self.m);
        self.alloc.destroy(self.srv);
        self.dir.close(self.threaded.io());
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
    }

    /// Issue one raw HTTP request over in-memory streams; return the FULL raw response.
    fn request(self: *TestServer, raw: []const u8, out_buf: []u8) []const u8 {
        var in = std.Io.Reader.fixed(raw);
        var out = std.Io.Writer.fixed(out_buf);
        var hs = http.Server.init(&in, &out);
        self.srv.serveOne(&hs);
        return out.buffered();
    }
};

const Resp = struct { status: u16, body: []const u8, raw: []const u8 };

fn splitResponse(raw: []const u8) Resp {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n").?;
    const body = raw[sep + 4 ..];
    const sp = std.mem.indexOfScalar(u8, raw, ' ').?;
    const status = std.fmt.parseInt(u16, raw[sp + 1 .. sp + 4], 10) catch 0;
    return .{ .status = status, .body = body, .raw = raw };
}

/// Serve one raw HTTP request straight against a `*Server` over in-memory streams (no
/// `TestServer` wrapper) — used by the EMPTY-START tests, which run a `Server.initEmpty`
/// with NO default machine/worker.
fn serveRaw(srv: *Server, raw: []const u8, out: []u8) Resp {
    var in = std.Io.Reader.fixed(raw);
    var w = std.Io.Writer.fixed(out);
    var hs = http.Server.init(&in, &w);
    srv.serveOne(&hs);
    return splitResponse(w.buffered());
}

fn get(ts: *TestServer, path: []const u8, out: []u8) Resp {
    var req_buf: [512]u8 = undefined;
    const raw = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path}) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

/// POST a JSON-RPC body to `/mcp` (optionally with an `Mcp-Session-Id` header).
fn mcpPost(ts: *TestServer, body: []const u8, session: ?[]const u8, out: []u8) Resp {
    var req_buf: [2048]u8 = undefined;
    const raw = if (session) |s|
        std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\nMcp-Session-Id: {s}\r\ncontent-length: {d}\r\n\r\n{s}", .{ s, body.len, body }) catch unreachable
    else
        std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

// --- a tiny JSON navigator over a parsed response body (per-test arena) ---
const Nav = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,

    fn parse(alloc: std.mem.Allocator, body: []const u8) !Nav {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
        return .{ .arena = arena, .root = root };
    }
    fn deinit(self: *Nav) void {
        self.arena.deinit();
    }
};

// Sized to hold a full `tools/list` reply: the catalog grew (the machine-lifecycle tools +
// the per-machine `machine` arg injected into every per-machine schema), so the response
// now exceeds 16 KiB. The server's own `resp_buf` is 32 KiB; this mirrors that headroom.
var obuf: [64 * 1024]u8 = undefined;

// ===========================================================================
// Lifecycle
// ===========================================================================

/// Extract the `Mcp-Session-Id` response header value (the minted session id) from a raw
/// HTTP response, copied into `dst` (the raw buffer is reused by later requests).
fn sessionHeader(raw: []const u8, dst: []u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    var it = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "mcp-session-id")) {
            var v = line[colon + 1 ..];
            while (v.len > 0 and v[0] == ' ') v = v[1..];
            @memcpy(dst[0..v.len], v);
            return dst[0..v.len];
        }
    }
    return null;
}

// NOTE (agent-provisioning-plan §4, the EMPTY-START / stateless inversion): `initialize` is
// now a PURE handshake — it mints NO session and issues NO `Mcp-Session-Id` header. The
// "initialize mints / routes by header" coverage these tests used to assert moved onto
// `provision_machine` + the `machine` tool arg (the minting/routing model that actually ships).

test "initialize is a pure handshake: protocolVersion + capabilities, and mints NO Mcp-Session-Id" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"protocolVersion\":\"2025-06-18\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"capabilities\":{\"tools\":{}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"id\":1") != null);
    // STATELESS MCP: initialize mints NOTHING and issues NO Mcp-Session-Id header — a machine
    // is created by provision_machine (handle in the tool RESULT), never by initialize.
    var sbuf: [128]u8 = undefined;
    try std.testing.expect(sessionHeader(r.raw, &sbuf) == null);
}

test "provision_machine mints a fresh zdos-sess handle (the minting initialize used to do)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const h = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "zdos-sess-"));
}

test "provision_machine twice mints two DISTINCT machines; the {machine} arg routes each" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    // Two provisions of the SAME program → two independent machines with distinct handles
    // (was "initialize twice mints two distinct"; routing moved from the header to the arg).
    const a = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(a);
    const b = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));

    // Step ONLY A (route by its handle); B is a separate booted machine, still at cycle 0.
    var sbuf: [512]u8 = undefined;
    const step = std.fmt.bufPrint(&sbuf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"step\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{a}) catch unreachable;
    _ = mcpPost(&ts, step, null, &obuf);
    try std.testing.expect(cyclesVia(&ts, a) > 0);
    try std.testing.expectEqual(@as(u64, 0), cyclesVia(&ts, b));
}

test "deprovision destroys the addressed machine; a later tools/call on it is unknown_machine" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const h = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(h);

    var sbuf: [512]u8 = undefined;
    const stat = std.fmt.bufPrint(&sbuf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"status\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{h}) catch unreachable;
    const live = mcpPost(&ts, stat, null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), live.status);
    try std.testing.expect(std.mem.indexOf(u8, live.body, "\"isError\":false") != null);

    // deprovision via the tool (was "DELETE /mcp destroys").
    var dbuf: [512]u8 = undefined;
    const del = std.fmt.bufPrint(&dbuf, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"deprovision\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{h}) catch unreachable;
    _ = mcpPost(&ts, del, null, &obuf);

    // A later tools/call on the destroyed handle is an unknown_machine tool error (not a crash).
    const after = mcpPost(&ts, stat, null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), after.status);
    try std.testing.expect(std.mem.indexOf(u8, after.body, "unknown_machine") != null);
}

test "DELETE /mcp is an HTTP alias for deprovision (header-addressed by the handle)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const h = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(h);

    var dreq: [256]u8 = undefined;
    const draw = std.fmt.bufPrint(&dreq, "DELETE /mcp HTTP/1.1\r\nHost: x\r\nMcp-Session-Id: {s}\r\n\r\n", .{h}) catch unreachable;
    const del = splitResponse(ts.request(draw, &obuf));
    try std.testing.expectEqual(@as(u16, 200), del.status);
    try std.testing.expect(std.mem.indexOf(u8, del.body, "\"deleted\":true") != null);
    try std.testing.expectEqual(@as(usize, 0), ts.srv.registry.liveCount());
}

test "a tools/call with NO machine arg reaches the default machine (back-compat)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    // No machine arg, no header → the default (the NOP machine). The shipped single-machine UX.
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"status\"}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"isError\":false") != null);
}

test "notifications/initialized → HTTP 202, empty body" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", mcp.SESSION_ID, &obuf);
    try std.testing.expectEqual(@as(u16, 202), r.status);
    try std.testing.expectEqualStrings("", r.body);
}

test "tools/list returns all four Phase-1 tools, each with name/description/inputSchema" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);

    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const list = nav.root.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(mcp_tools.tools.len, list.items.len);
    for (list.items) |item| {
        try std.testing.expect(item.object.get("name").? == .string);
        try std.testing.expect(item.object.get("description").? == .string);
        // inputSchema is spliced as a JSON object literal (so it parses as an object).
        try std.testing.expect(item.object.get("inputSchema").? == .object);
    }
    // Spot-check the names are present.
    for ([_][]const u8{ "step", "read_cpu", "read_memory", "add_breakpoint" }) |want| {
        var found = false;
        for (list.items) |item| {
            if (std.mem.eql(u8, item.object.get("name").?.string, want)) found = true;
        }
        try std.testing.expect(found);
    }
}

// ===========================================================================
// Tool dispatch
// ===========================================================================

test "tools/call step advances the guest (status shows cycles > 0)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const before = get(&ts, "/api/status", &obuf);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "\"cycles\":0") != null);

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"step\",\"arguments\":{}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"isError\":false") != null);

    const after = get(&ts, "/api/status", &obuf);
    try std.testing.expect(std.mem.indexOf(u8, after.body, "\"cycles\":0") == null);
}

test "tools/call read_cpu content parses as a CPU snapshot" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"read_cpu\"}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);

    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const text = nav.root.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    // The text IS the CPU snapshot JSON — parse it and check a known field.
    var inner = try Nav.parse(std.testing.allocator, text);
    defer inner.deinit();
    try std.testing.expect(inner.root.object.get("eip") != null);
}

test "tools/call read_memory returns a hex body" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    // Read the 8 NOP bytes at PROG (0x0500): expect "9090909090909090".
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"read_memory\",\"arguments\":{\"phys\":1280,\"len\":8}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);

    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const text = nav.root.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try Nav.parse(std.testing.allocator, text);
    defer inner.deinit();
    try std.testing.expectEqualStrings("9090909090909090", inner.root.object.get("data").?.string);
}

test "tools/call add_breakpoint returns an id" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"add_breakpoint\",\"arguments\":{\"kind\":{\"cycle\":{\"at_cycle\":578}}}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"isError\":false") != null);

    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const text = nav.root.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try Nav.parse(std.testing.allocator, text);
    defer inner.deinit();
    try std.testing.expectEqual(@as(i64, 0), inner.root.object.get("id").?.integer);
}

// ===========================================================================
// Screenshot — the deferred framebuffer feature (mcp-plan.md §7): an MCP IMAGE
// content block carrying a base64 PNG, streamed with an exact Content-Length. The
// pipeline reuses `framebuffer_get` + `encodePng` on the RESOLVED session — the same
// deterministic re-render path `/api/framebuffer?format=png` drives.
// ===========================================================================

const PNG_SIG = "\x89PNG\r\n\x1a\n";

/// Find a response header value by (case-insensitive) name in the raw HTTP head.
fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    var it = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            var v = line[colon + 1 ..];
            while (v.len > 0 and v[0] == ' ') v = v[1..];
            return v;
        }
    }
    return null;
}

/// Lay mode 13h (320x200x8) into the DEFAULT session's machine: BDA video-mode byte +
/// a known VRAM ramp + a known DAC palette. Mirrors the `/api/framebuffer` mode-13h
/// tests so the captured frame is a real, deterministic graphics frame.
fn layMode13h(ts: *TestServer) void {
    ts.m.bus.writePhys8(0x400 + 0x49, 0x13); // OFF_VIDEO_MODE = 13h
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) ts.m.vga.vram[i] = @truncate(i * 3 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) ts.m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 5, .blue = 9 };
}

/// Parse a `screenshot` tool result, assert the image content shape, and base64-decode
/// `data` into `dst`; returns the decoded PNG bytes.
fn decodeScreenshot(alloc: std.mem.Allocator, body: []const u8, dst: []u8) ![]const u8 {
    var nav = try Nav.parse(alloc, body);
    defer nav.deinit();
    try std.testing.expect(nav.root.object.get("error") == null); // a result, not a protocol error
    const result = nav.root.object.get("result").?.object;
    try std.testing.expectEqual(false, result.get("isError").?.bool);
    const content0 = result.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("image", content0.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", content0.get("mimeType").?.string);
    const b64 = content0.get("data").?.string;
    try std.testing.expect(b64.len > 0);
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    try dec.decode(dst[0..n], b64);
    return dst[0..n];
}

const SCREENSHOT_CALL = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}";

test "screenshot returns a well-formed PNG image content block (mode 13h frame)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    layMode13h(&ts);

    // The streamed JSON-RPC body holds ~1.33× the PNG — allocate generously.
    const out = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(out);
    const png_buf = try alloc.alloc(u8, 1300 * 1024);
    defer alloc.free(png_buf);

    const r = splitResponse(ts.request(
        "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: " ++
            std.fmt.comptimePrint("{d}", .{SCREENSHOT_CALL.len}) ++ "\r\n\r\n" ++ SCREENSHOT_CALL,
        out,
    ));
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(headerValue(r.raw, "content-type").?[0] == 'a'); // application/json…

    const png_bytes = try decodeScreenshot(alloc, r.body, png_buf);
    try std.testing.expect(png_bytes.len > PNG_SIG.len);
    try std.testing.expectEqualStrings(PNG_SIG, png_bytes[0..PNG_SIG.len]);
    // PNG IHDR width/height live at byte offsets 16 and 20 (big-endian u32) — confirm the
    // captured frame is the 320x200 mode-13h frame, not a stray buffer.
    const width = std.mem.readInt(u32, png_bytes[16..20], .big);
    const height = std.mem.readInt(u32, png_bytes[20..24], .big);
    try std.testing.expectEqual(@as(u32, 320), width);
    try std.testing.expectEqual(@as(u32, 200), height);
}

// The raw HTTP response Content-Length header (the streamed envelope length) must match
// the actual body length — proving the exact-length streaming math (prefix + base64 +
// suffix) is correct.
test "screenshot streams an exact Content-Length matching the body" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    layMode13h(&ts);

    const out = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(out);
    const r = splitResponse(ts.request(
        "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: " ++
            std.fmt.comptimePrint("{d}", .{SCREENSHOT_CALL.len}) ++ "\r\n\r\n" ++ SCREENSHOT_CALL,
        out,
    ));
    const cl = try std.fmt.parseInt(usize, headerValue(r.raw, "content-length").?, 10);
    try std.testing.expectEqual(cl, r.body.len);
}

test "screenshot is deterministic (two captures of the same frame → byte-identical base64)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    layMode13h(&ts);

    const o1 = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(o1);
    const o2 = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(o2);
    const req_raw = "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: " ++
        std.fmt.comptimePrint("{d}", .{SCREENSHOT_CALL.len}) ++ "\r\n\r\n" ++ SCREENSHOT_CALL;
    const r1 = splitResponse(ts.request(req_raw, o1));
    const r2 = splitResponse(ts.request(req_raw, o2));
    try std.testing.expectEqualStrings(r1.body, r2.body);
}

test "screenshot of an unsupported mode → isError result, not_implemented (never a fake frame)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    ts.m.bus.writePhys8(0x400 + 0x49, 0xFE); // mode 0xFE has no rasterizer

    const r = mcpPost(&ts, SCREENSHOT_CALL, null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status); // a tool error is still HTTP 200

    var nav = try Nav.parse(alloc, r.body);
    defer nav.deinit();
    try std.testing.expect(nav.root.object.get("error") == null); // NOT a JSON-RPC protocol error
    const result = nav.root.object.get("result").?.object;
    try std.testing.expectEqual(true, result.get("isError").?.bool);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "not_implemented") != null);
}

test "screenshot appears in tools/list with an image-oriented description" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", null, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const list = nav.root.object.get("result").?.object.get("tools").?.array;
    var found = false;
    for (list.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, "screenshot")) found = true;
    }
    try std.testing.expect(found);
}

// ===========================================================================
// Protocol errors (could-not-dispatch) → JSON-RPC error envelope
// ===========================================================================

fn rpcErrorCode(body: []const u8, alloc: std.mem.Allocator) !i64 {
    var nav = try Nav.parse(alloc, body);
    defer nav.deinit();
    try std.testing.expect(nav.root.object.get("result") == null); // NOT a result
    return nav.root.object.get("error").?.object.get("code").?.integer;
}

test "garbage body → -32700 parse error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "this is not json", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(i64, -32700), try rpcErrorCode(r.body, std.testing.allocator));
}

test "unknown method → -32601" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"bogus/method\"}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(@as(i64, -32601), try rpcErrorCode(r.body, std.testing.allocator));
}

test "missing jsonrpc field → -32600" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"id\":8,\"method\":\"tools/list\"}", null, &obuf);
    try std.testing.expectEqual(@as(i64, -32600), try rpcErrorCode(r.body, std.testing.allocator));
}

test "tools/call unknown tool → -32602" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}", null, &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

test "tools/call read_memory with bad arg type → -32602" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    // phys as a string is a schema violation → invalid params (fix the CALL).
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"read_memory\",\"arguments\":{\"phys\":\"x\",\"len\":8}}}", null, &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

// ===========================================================================
// Tool error vs transport error (load-bearing)
// ===========================================================================

test "read_memory out-of-range → HTTP 200, isError result, no top-level JSON-RPC error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    // phys well beyond the addressable slab, but within u32 (so it parses cleanly and
    // DISPATCHES — the failure is an emulator ErrCode, not a validation error).
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"read_memory\",\"arguments\":{\"phys\":4000000000,\"len\":16}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);

    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expect(nav.root.object.get("error") == null); // NOT a transport error
    const result = nav.root.object.get("result").?;
    try std.testing.expectEqual(true, result.object.get("isError").?.bool);
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "address_out_of_range") != null);
}

// ===========================================================================
// Anti-drift equivalence: MCP inner tool body == the equivalent HTTP route body
// ===========================================================================

/// Pull `result.content[0].text` out of an MCP `tools/call` reply.
fn toolText(nav: *Nav) []const u8 {
    return nav.root.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
}

test "equivalence: read_cpu tool body == GET /api/cpu body (same machine, cycle-neutral)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    // HTTP body first (read is cycle-neutral, so order does not matter).
    var http_buf: [16 * 1024]u8 = undefined;
    const httpr = get(&ts, "/api/cpu", &http_buf);

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"read_cpu\"}}", null, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expectEqualStrings(httpr.body, toolText(&nav));
}

test "equivalence: read_memory tool body == GET /api/mem body" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    var http_buf: [16 * 1024]u8 = undefined;
    const httpr = get(&ts, "/api/mem?phys=1280&len=8", &http_buf);

    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"read_memory\",\"arguments\":{\"phys\":1280,\"len\":8}}}", null, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expectEqualStrings(httpr.body, toolText(&nav));
}

test "equivalence: step tool body == POST /api/step body (fresh machines, first step)" {
    // Two fresh machines at entry: the first step is deterministic, so the StopReason
    // JSON is identical. This proves the MCP step shares the HTTP step serializer.
    var ts_http = try TestServer.init(std.testing.allocator);
    try ts_http.start();
    defer ts_http.deinit();
    var http_buf: [16 * 1024]u8 = undefined;
    var step_buf: [1024]u8 = undefined;
    const step_raw = std.fmt.bufPrint(&step_buf, "POST /api/step HTTP/1.1\r\nHost: x\r\n\r\n", .{}) catch unreachable;
    const httpr = splitResponse(ts_http.request(step_raw, &http_buf));

    var ts_mcp = try TestServer.init(std.testing.allocator);
    try ts_mcp.start();
    defer ts_mcp.deinit();
    const r = mcpPost(&ts_mcp, "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"step\",\"arguments\":{}}}", null, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expectEqualStrings(httpr.body, toolText(&nav));
}

// ===========================================================================
// Phase-2 tool dispatch (the full surface). Each builds a `tools/call`, asserts an
// HTTP-200 non-error result, and (where cheap) spot-checks the inner body.
// ===========================================================================

/// Build + POST a `tools/call` for `name` with the raw JSON `args` object.
fn call(ts: *TestServer, idn: u32, name: []const u8, args: []const u8, out: []u8) Resp {
    var b: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(
        &b,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ idn, name, args },
    ) catch unreachable;
    return mcpPost(ts, body, null, out);
}

/// True iff the reply is a tool `result` with `isError:true`.
fn toolIsError(body: []const u8) !bool {
    var nav = try Nav.parse(std.testing.allocator, body);
    defer nav.deinit();
    try std.testing.expect(nav.root.object.get("error") == null); // a tool result, not a transport error
    return nav.root.object.get("result").?.object.get("isError").?.bool;
}

/// Assert: HTTP 200 + a non-error tool result; return the inner content text dup'd into
/// `dst` (so the caller can inspect it after the Nav arena is freed).
fn expectOkText(body: []const u8, dst: []u8) ![]const u8 {
    var nav = try Nav.parse(std.testing.allocator, body);
    defer nav.deinit();
    try std.testing.expectEqual(false, nav.root.object.get("result").?.object.get("isError").?.bool);
    const t = toolText(&nav);
    @memcpy(dst[0..t.len], t);
    return dst[0..t.len];
}

test "dispatch: run / step_n / step_over advance the guest" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(@as(u16, 200), call(&ts, 100, "step_n", "{\"n\":3}", &obuf).status);
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 101, "step_over", "{}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 102, "run", "{\"cycle_cap\":50}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 103, "run_to_cycle", "{\"cycle\":80}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 104, "run_to_address", "{\"linear\":1280}", &obuf).body));
}

test "dispatch: breakpoint lifecycle (add / list / remove / clear)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const add = call(&ts, 110, "add_breakpoint", "{\"kind\":{\"cycle\":{\"at_cycle\":99}}}", &obuf);
    try std.testing.expectEqual(false, try toolIsError(add.body));

    var dst: [4096]u8 = undefined;
    const listed = try expectOkText(call(&ts, 111, "list_breakpoints", "{}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"breakpoints\"") != null);

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 112, "remove_breakpoint", "{\"id\":0}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 113, "clear_breakpoints", "{}", &obuf).body));
}

test "dispatch: set_register then read_cpu reflects it" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 120, "set_register", "{\"reg32\":{\"name\":\"eax\",\"value\":4660}}", &obuf).body));

    var dst: [4096]u8 = undefined;
    const cpu = try expectOkText(call(&ts, 121, "read_cpu", "{}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, cpu, "\"eax\":4660") != null);
}

test "dispatch: write_memory then read_memory round-trips" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 130, "write_memory", "{\"phys\":8192,\"data\":\"cafebabe\"}", &obuf).body));

    var dst: [256]u8 = undefined;
    const mem = try expectOkText(call(&ts, 131, "read_memory", "{\"phys\":8192,\"len\":4}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, mem, "\"data\":\"cafebabe\"") != null);
}

test "dispatch: read_memory_seg + write_memory_seg" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 140, "write_memory_seg", "{\"seg\":\"ds\",\"off\":256,\"data\":\"1234\"}", &obuf).body));
    var dst: [256]u8 = undefined;
    const mem = try expectOkText(call(&ts, 141, "read_memory_seg", "{\"seg\":\"ds\",\"off\":256,\"len\":2}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, mem, "\"data\":\"1234\"") != null);
}

test "dispatch: read_ivt / read_io_port / status / reset" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    var dst: [512]u8 = undefined;
    const ivt = try expectOkText(call(&ts, 150, "read_ivt", "{\"vector\":33}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, ivt, "\"vector\":33") != null);

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 151, "read_io_port", "{\"port\":97}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 152, "status", "{}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 153, "reset", "{}", &obuf).body));
}

test "dispatch: input_key (char) and input_mouse (scripted)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 160, "input_key", "{\"char\":\"a\"}", &obuf).body));
    try std.testing.expectEqual(false, try toolIsError(call(&ts, 161, "input_mouse", "{\"x\":10,\"y\":20,\"buttons\":1}", &obuf).body));
}

test "dispatch: set_clock applies then get_clock reflects the mult" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    try std.testing.expectEqual(false, try toolIsError(call(&ts, 170, "set_clock", "{\"mult\":6}", &obuf).body));
    var dst: [512]u8 = undefined;
    const clk = try expectOkText(call(&ts, 171, "get_clock", "{}", &obuf).body, &dst);
    try std.testing.expect(std.mem.indexOf(u8, clk, "\"mult\":6") != null);
}

test "dispatch: load with a missing file → isError load_failed (tool ran)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = call(&ts, 180, "load", "{\"file\":\"NOPE.COM\"}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(true, try toolIsError(r.body));
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expect(std.mem.indexOf(u8, toolText(&nav), "load_failed") != null);
}

// ===========================================================================
// Error mapping — a representative ErrCode per category + the validation dividing line.
// ===========================================================================

test "error: set_register reg8 overflow is a -32602 validation error (before submit)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = call(&ts, 200, "set_register", "{\"reg8\":{\"name\":\"al\",\"value\":256}}", &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

test "error: search_memory both pattern+ascii is a -32602 validation error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = call(&ts, 201, "search_memory", "{\"pattern\":\"aa\",\"ascii\":\"x\"}", &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

test "error: input_key scancode+char is a -32602 validation error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = call(&ts, 202, "input_key", "{\"scancode\":30,\"char\":\"a\"}", &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

test "error: remove_breakpoint of a missing id is an isError tool result (no_such_breakpoint)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = call(&ts, 203, "remove_breakpoint", "{\"id\":99}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqual(true, try toolIsError(r.body));
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expect(std.mem.indexOf(u8, toolText(&nav), "no_such_breakpoint") != null);
}

test "error: read_devices unknown group is a -32602 validation error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = call(&ts, 204, "read_devices", "{\"device\":\"nope\"}", &obuf);
    try std.testing.expectEqual(@as(i64, -32602), try rpcErrorCode(r.body, std.testing.allocator));
}

// ===========================================================================
// Anti-drift equivalence: MCP inner tool body == the equivalent HTTP route body,
// byte-for-byte (proves the shared `writeResponseBody`/`writeX` builders).
// ===========================================================================

/// Generic helper: assert the MCP `name`/`args` inner content text equals the body of
/// `GET <http_path>` on the SAME machine (every compared route is a cycle-neutral read).
fn expectEquivGet(idn: u32, name: []const u8, args: []const u8, http_path: []const u8) !void {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    var http_buf: [16 * 1024]u8 = undefined;
    const httpr = get(&ts, http_path, &http_buf);

    const r = call(&ts, idn, name, args, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expectEqualStrings(httpr.body, toolText(&nav));
}

test "equivalence: read_screen tool body == GET /api/screen?attrs=1" {
    try expectEquivGet(300, "read_screen", "{\"attrs\":true}", "/api/screen?attrs=1");
}
test "equivalence: read_screen (no attrs) == GET /api/screen" {
    try expectEquivGet(301, "read_screen", "{}", "/api/screen");
}
test "equivalence: disassemble tool body == GET /api/disasm" {
    try expectEquivGet(302, "disassemble", "{\"linear\":1280,\"count\":3}", "/api/disasm?linear=1280&count=3");
}
test "equivalence: read_devices tool body == GET /api/devices" {
    try expectEquivGet(303, "read_devices", "{}", "/api/devices");
}
test "equivalence: read_stack tool body == GET /api/stack" {
    try expectEquivGet(304, "read_stack", "{\"count\":4}", "/api/stack?count=4");
}
test "equivalence: list_breakpoints tool body == GET /api/breakpoints" {
    try expectEquivGet(305, "list_breakpoints", "{}", "/api/breakpoints");
}
test "equivalence: read_console tool body == GET /api/console" {
    try expectEquivGet(306, "read_console", "{}", "/api/console");
}
test "equivalence: search_memory tool body == GET /api/mem/search" {
    try expectEquivGet(307, "search_memory", "{\"pattern\":\"90\",\"start\":1280,\"len\":8}", "/api/mem/search?pattern=90&start=1280&len=8");
}
test "equivalence: get_clock tool body == GET /api/cpu/clock" {
    try expectEquivGet(308, "get_clock", "{}", "/api/cpu/clock");
}
test "equivalence: read_devices?palette tool body == GET /api/devices?palette=1" {
    try expectEquivGet(309, "read_devices", "{\"palette\":true}", "/api/devices?palette=1");
}
test "equivalence: read_devices{device} tool body == GET /api/device/pic" {
    try expectEquivGet(310, "read_devices", "{\"device\":\"pic\"}", "/api/device/pic");
}

// ===========================================================================
// Phase 4 — HTTP `/api/*` session routing via the optional `X-Zdos-Session`
// header (multi-machine plan §6 option B). These drive the SAME registry-minted
// machines an MCP `initialize` provisions, but through the `/api/*` HTTP surface,
// and assert per-session isolation on a DETERMINISTIC comparison point (the
// `cycles` ledger after explicit steps), never on timing.
// ===========================================================================

/// `GET path` with an optional `X-Zdos-Session` header (null = no header → default session).
fn apiGet(ts: *TestServer, path: []const u8, session: ?[]const u8, out: []u8) Resp {
    var req_buf: [512]u8 = undefined;
    const raw = if (session) |s|
        std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nX-Zdos-Session: {s}\r\n\r\n", .{ path, s }) catch unreachable
    else
        std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path}) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

/// `POST path` (empty body) with an optional `X-Zdos-Session` header.
fn apiPost(ts: *TestServer, path: []const u8, session: ?[]const u8, out: []u8) Resp {
    var req_buf: [512]u8 = undefined;
    const raw = if (session) |s|
        std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: x\r\nX-Zdos-Session: {s}\r\ncontent-length: 0\r\n\r\n", .{ path, s }) catch unreachable
    else
        std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: x\r\ncontent-length: 0\r\n\r\n", .{path}) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

/// Read the `cycles` ledger via `GET /api/status` for the session selected by `session`
/// (null = default). Asserts 200 and parses the base-10 `cycles` field.
fn statusCycles(ts: *TestServer, session: ?[]const u8, out: []u8) !u64 {
    const r = apiGet(ts, "/api/status", session, out);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    return @intCast(nav.root.object.get("cycles").?.integer);
}

/// Mint a fresh registry-backed machine via `provision_machine` (stateless MCP — `initialize`
/// no longer mints); return its handle (caller frees). The handle doubles as the `X-Zdos-
/// Session` value the `/api/*` routing resolves, so these Phase-4 HTTP-routing tests still
/// exercise a registry-minted machine — now provisioned, not header-minted.
fn mintSession(ts: *TestServer, out: []u8) ![]const u8 {
    var bbuf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"provision_machine\",\"arguments\":{{\"mount_dir\":\"{s}\",\"file\":\"HELLO.COM\"}}}}}}", .{build_options.examples_dir}) catch unreachable;
    const r = mcpPost(ts, body, null, out);
    if (r.status != 200) return error.ProvisionFailed;
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    const obj = toolObject(&nav);
    const handle = obj.object.get("machine") orelse return error.NoMachineHandle;
    return std.testing.allocator.dupe(u8, handle.string);
}

test "Phase 4: X-Zdos-Session routes /api/* to the minted machine; the default is untouched" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const id = try mintSession(&ts, &obuf);
    defer std.testing.allocator.free(id);

    const minted_before = try statusCycles(&ts, id, &obuf);
    const default_before = try statusCycles(&ts, null, &obuf);

    // Drive the MINTED session via /api/step carrying its id — never the default.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const s = apiPost(&ts, "/api/step", id, &obuf);
        try std.testing.expectEqual(@as(u16, 200), s.status);
    }

    const minted_after = try statusCycles(&ts, id, &obuf);
    const default_after = try statusCycles(&ts, null, &obuf);

    // The routed machine advanced; the default machine did NOT move a single cycle.
    try std.testing.expect(minted_after > minted_before);
    try std.testing.expectEqual(default_before, default_after);
}

test "Phase 4: two X-Zdos-Session-routed machines are isolated from each other" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const id_a = try mintSession(&ts, &obuf);
    defer std.testing.allocator.free(id_a);
    const id_b = try mintSession(&ts, &obuf);
    defer std.testing.allocator.free(id_b);
    try std.testing.expect(!std.mem.eql(u8, id_a, id_b));

    const b_before = try statusCycles(&ts, id_b, &obuf);

    // Step ONLY A; B must not advance.
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = apiPost(&ts, "/api/step", id_a, &obuf);

    const a_after = try statusCycles(&ts, id_a, &obuf);
    const b_after = try statusCycles(&ts, id_b, &obuf);
    try std.testing.expect(a_after > b_after);
    try std.testing.expectEqual(b_before, b_after); // B bit-for-bit unchanged
}

test "Phase 4: an explicit but UNKNOWN X-Zdos-Session is 404, not a silent default fallthrough" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const r = apiGet(&ts, "/api/status", "zdos-sess-does-not-exist", &obuf);
    try std.testing.expectEqual(@as(u16, 404), r.status);
}

test "Phase 4: blank/absent and the singleton id both route /api/* to the default session" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    // Advance the default machine via the NO-HEADER path (the back-compat surface).
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = apiPost(&ts, "/api/step", null, &obuf);

    // The same machine is visible via the explicit singleton id AND via no header.
    const via_blank = try statusCycles(&ts, null, &obuf);
    const via_singleton = try statusCycles(&ts, mcp.SESSION_ID, &obuf);
    try std.testing.expect(via_blank > 0);
    try std.testing.expectEqual(via_blank, via_singleton);
}

test "Phase 4: a DELETE'd session no longer routes via /api/* (X-Zdos-Session → 404)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const id = try mintSession(&ts, &obuf);
    defer std.testing.allocator.free(id);

    // Live: an /api/* call with its id works.
    try std.testing.expectEqual(@as(u16, 200), apiGet(&ts, "/api/status", id, &obuf).status);

    // Tear it down over the wire.
    var dreq: [256]u8 = undefined;
    const draw = std.fmt.bufPrint(&dreq, "DELETE /mcp HTTP/1.1\r\nHost: x\r\nMcp-Session-Id: {s}\r\n\r\n", .{id}) catch unreachable;
    try std.testing.expectEqual(@as(u16, 200), splitResponse(ts.request(draw, &obuf)).status);

    // Routing its id now 404s; the default session is still reachable (no header).
    try std.testing.expectEqual(@as(u16, 404), apiGet(&ts, "/api/status", id, &obuf).status);
    try std.testing.expectEqual(@as(u16, 200), apiGet(&ts, "/api/status", null, &obuf).status);
}

// ===========================================================================
// Finding 1 (BLOCKER) regression: `mapCpuSpeed` bounds `mhz` BEFORE the multiply.
// An unbounded `mhz * 1_000_000` overflowed u64 → a checked-arithmetic panic that
// killed the whole server (reachable from MCP `set_clock` AND HTTP POST /api/cpu/clock,
// the shared mapper). The fix clamps `mhz` to the MHz ceiling that already maps past
// `MAX_MULT`, so a huge `mhz` clamps EXACTLY like a huge `mult` does — no panic — and
// in-range values stay byte-identical. Deterministic, integer-only assertions.
// ===========================================================================
test "mapCpuSpeed: a huge mhz CLAMPS (no overflow panic) and equals mhz=66" {
    // maxInt(u64) * 1_000_000 would overflow u64 pre-fix → panic. Post-fix it clamps.
    const huge = mcp_tools.mapCpuSpeed(null, std.math.maxInt(u64));
    const ceil = mcp_tools.mapCpuSpeed(null, 66);
    switch (huge) {
        .ok => |mult_huge| switch (ceil) {
            .ok => |mult_ceil| {
                // Both saturate to the same requested mult (the worker then clamps to
                // MAX_MULT=55; the mapper returns the pre-clamp requested mult, which is
                // identical for every mhz at/above the ceiling).
                try std.testing.expectEqual(mult_ceil, mult_huge);
                // Sanity: the ceiling maps at/above MAX_MULT (so the worker clamp engages).
                try std.testing.expect(mult_huge >= 55);
            },
            .fail => return error.UnexpectedFail,
        },
        .fail => return error.UnexpectedPanicAvoidedButFailed,
    }
}

test "mapCpuSpeed: in-range mhz is byte-identical (14 MHz still maps to the 12 baseline)" {
    // The shipped default is mult 12 (== timing.DEFAULT_MULT); 14 MHz rounds to it. This
    // pins that the clamp did NOT perturb any in-range value.
    switch (mcp_tools.mapCpuSpeed(null, 14)) {
        .ok => |mult| try std.testing.expectEqual(@as(u64, 12), mult),
        .fail => return error.UnexpectedFail,
    }
    // mhz=0 is still a bad_request (the clamp did not swallow the zero guard).
    switch (mcp_tools.mapCpuSpeed(null, 0)) {
        .ok => return error.ExpectedFail,
        .fail => |f| try std.testing.expect(std.mem.eql(u8, f.code, "bad_request")),
    }
}

// NOTE (agent-provisioning-plan §4): the former "concurrent /api/load + initialize: every
// minted session boots ONE WHOLE recipe (no torn read)" regression (Finding 3) is RETIRED.
// It guarded a by-value copy of `default.recipe` inside `respondMcpInitialize`; the EMPTY-START
// inversion GUTTED that function (initialize no longer reads the default recipe — it mints
// nothing), so the torn-read code path it exercised no longer exists. `provision_machine`
// builds its recipe from per-call request ARGS parsed into the per-request arena — never a
// shared default field — so there is no analogous shared-recipe tear to regress against.

// ===========================================================================
// Agent-driven machine PROVISIONING (multi-machine plan §3/§8/§11.2) — provision_machine /
// deprovision / list_machines + the `machine`-arg routing on the per-machine tools. Each
// provisions a REAL machine (the committed example dirs) through the registry; assertions
// are on per-machine state at explicit points (never inter-machine timing).
// ===========================================================================

/// Re-parse a tool reply's inner result (`result.content[0].text`) as a JSON object, in the
/// SAME `nav` arena (so the returned Value stays valid while `nav` lives).
fn toolObject(nav: *Nav) std.json.Value {
    const text = toolText(nav);
    return std.json.parseFromSliceLeaky(std.json.Value, nav.arena.allocator(), text, .{}) catch unreachable;
}

/// Provision a machine and return its handle (duped on `alloc` — the caller frees it).
fn provisionHandle(ts: *TestServer, alloc: std.mem.Allocator, mount_dir: []const u8, file: []const u8, cpu_frag: []const u8) ![]u8 {
    var bbuf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"provision_machine\",\"arguments\":{{\"mount_dir\":\"{s}\",\"file\":\"{s}\"{s}}}}}}}", .{ mount_dir, file, cpu_frag }) catch unreachable;
    const r = mcpPost(ts, body, null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    var nav = try Nav.parse(alloc, r.body);
    defer nav.deinit();
    const obj = toolObject(&nav);
    return alloc.dupe(u8, obj.object.get("machine").?.string);
}

/// `status.cycles` for a machine handle (or the default machine when `machine` is null),
/// driven through the per-machine `status` tool via the `machine`-arg route.
fn cyclesVia(ts: *TestServer, machine: ?[]const u8) u64 {
    var bbuf: [512]u8 = undefined;
    const body = if (machine) |h|
        std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"status\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{h}) catch unreachable
    else
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"status\"}}";
    const r = mcpPost(ts, body, null, &obuf);
    var nav = Nav.parse(std.testing.allocator, r.body) catch unreachable;
    defer nav.deinit();
    return @intCast(toolObject(&nav).object.get("cycles").?.integer);
}

test "provision_machine: two distinct dirs are isolated; {machine} routes only the addressed one" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const a = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(a);
    const b = try provisionHandle(&ts, std.testing.allocator, build_options.dos_examples_dir, "HELLO.EXE", "");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b)); // distinct handles

    // Baseline: both freshly-booted machines and the default NOP machine are at cycle 0.
    try std.testing.expectEqual(@as(u64, 0), cyclesVia(&ts, b));
    try std.testing.expectEqual(@as(u64, 0), cyclesVia(&ts, null));

    // Step ONLY machine A (route by its handle).
    var sbuf: [512]u8 = undefined;
    const step = std.fmt.bufPrint(&sbuf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"step\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{a}) catch unreachable;
    _ = mcpPost(&ts, step, null, &obuf);

    // A advanced; B and the default machine are bit-for-bit untouched (separate machines).
    try std.testing.expect(cyclesVia(&ts, a) > 0);
    try std.testing.expectEqual(@as(u64, 0), cyclesVia(&ts, b));
    try std.testing.expectEqual(@as(u64, 0), cyclesVia(&ts, null));
}

test "provision_machine: cpu {mult:24} is reflected by get_clock on that machine" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const h = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", ",\"cpu\":{\"mult\":24}");
    defer std.testing.allocator.free(h);

    var bbuf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"get_clock\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{h}) catch unreachable;
    const r = mcpPost(&ts, body, null, &obuf);
    var nav = try Nav.parse(std.testing.allocator, r.body);
    defer nav.deinit();
    try std.testing.expectEqual(@as(i64, 24), toolObject(&nav).object.get("mult").?.integer);
}

test "provision_machine: a missing file is -32602 file_not_found (NOT internal)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    // A REAL (openable) mount dir but a file that is not in it → the loader's own NotFound,
    // mapped to -32602 file_not_found (NOT a -32603 internal fault).
    var bbuf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"provision_machine\",\"arguments\":{{\"mount_dir\":\"{s}\",\"file\":\"NOPE.COM\"}}}}}}", .{build_options.examples_dir}) catch unreachable;
    const r = mcpPost(&ts, body, null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "file_not_found") != null);
    // It must NOT have leaked a registry slot, and no machine was created.
    try std.testing.expectEqual(@as(usize, 0), ts.srv.registry.liveCount());
}

test "provision_machine: at MAX_SESSIONS the next provision is machine_limit_reached" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    var handles: [registry_max]?[]u8 = .{null} ** registry_max;
    defer for (handles) |h| if (h) |hh| std.testing.allocator.free(hh);
    var i: usize = 0;
    while (i < registry_max) : (i += 1)
        handles[i] = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    try std.testing.expectEqual(registry_max, ts.srv.registry.liveCount());

    // One past the cap → a distinct machine_limit_reached tool error (NOT -32603 internal).
    var obuf2: [1024]u8 = undefined;
    const over_body = std.fmt.bufPrint(&obuf2, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{{\"name\":\"provision_machine\",\"arguments\":{{\"mount_dir\":\"{s}\",\"file\":\"HELLO.COM\"}}}}}}", .{build_options.examples_dir}) catch unreachable;
    const over = mcpPost(&ts, over_body, null, &obuf);
    try std.testing.expect(std.mem.indexOf(u8, over.body, "machine_limit_reached") != null);
    try std.testing.expect(std.mem.indexOf(u8, over.body, "-32603") == null);
}

const registry_max = @import("session_registry.zig").SessionRegistry.MAX_SESSIONS;

test "deprovision: provision -> list shows it -> deprovision -> list shows 0; slot reusable" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();

    const h = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(h);

    // list_machines shows exactly the one we provisioned.
    {
        const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_machines\"}}", null, &obuf);
        var nav = try Nav.parse(std.testing.allocator, r.body);
        defer nav.deinit();
        const obj = toolObject(&nav).object;
        try std.testing.expectEqual(@as(i64, 1), obj.get("live_machines").?.integer);
        const machines = obj.get("machines").?.array;
        try std.testing.expectEqual(@as(usize, 1), machines.items.len);
        try std.testing.expectEqualStrings(h, machines.items[0].object.get("machine").?.string);
        try std.testing.expectEqualStrings("HELLO.COM", machines.items[0].object.get("file").?.string);
    }

    // deprovision the handle (parse the result — the inner body is JSON-escaped into the
    // text content block, so a raw substring search for `"deleted":true` would not match).
    var dbuf: [512]u8 = undefined;
    const del = std.fmt.bufPrint(&dbuf, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"deprovision\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{h}) catch unreachable;
    const dr = mcpPost(&ts, del, null, &obuf);
    {
        var nav = try Nav.parse(std.testing.allocator, dr.body);
        defer nav.deinit();
        const obj = toolObject(&nav).object;
        try std.testing.expect(obj.get("deleted").?.bool);
        try std.testing.expectEqual(@as(i64, 0), obj.get("live_machines").?.integer);
    }
    try std.testing.expectEqual(@as(usize, 0), ts.srv.registry.liveCount());

    // list now shows zero; the slot is reusable (a fresh provision succeeds).
    {
        const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_machines\"}}", null, &obuf);
        var nav = try Nav.parse(std.testing.allocator, r.body);
        defer nav.deinit();
        try std.testing.expectEqual(@as(i64, 0), toolObject(&nav).object.get("live_machines").?.integer);
    }
    const again = try provisionHandle(&ts, std.testing.allocator, build_options.examples_dir, "HELLO.COM", "");
    defer std.testing.allocator.free(again);
    try std.testing.expectEqual(@as(usize, 1), ts.srv.registry.liveCount());
}

test "deprovision: an unknown handle is an unknown_machine tool error, not a crash" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"deprovision\",\"arguments\":{\"machine\":\"zdos-sess-999\"}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "unknown_machine") != null);
}

test "per-machine routing: an unknown {machine} is an unknown_machine tool error" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = mcpPost(&ts, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"status\",\"arguments\":{\"machine\":\"zdos-sess-999\"}}}", null, &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "unknown_machine") != null);
}

// ===========================================================================
// EMPTY-START (agent-provisioning-plan §6/§7): `Server.initEmpty` — NO default machine, NO
// worker, NO pacer. `/api/health` answers off-worker; a per-machine MCP tool with no machine
// → the `no_machine` guided error; a blank `/api/*` → 409; provision→drive→deprovision works.
// ===========================================================================

/// A live EMPTY test server (`Server.initEmpty`): the real registry + listener seam over
/// in-memory streams, but NO default session/worker. Minted machines (from provision_machine)
/// each get their own worker, joined by `srv.deinit()`.
const EmptyServer = struct {
    alloc: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    srv: *Server,

    fn init(alloc: std.mem.Allocator) !EmptyServer {
        const threaded = try alloc.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(alloc, .{});
        const srv = try alloc.create(Server);
        srv.* = try Server.initEmpty(alloc, threaded.io(), 0);
        return .{ .alloc = alloc, .threaded = threaded, .srv = srv };
    }
    fn deinit(self: *EmptyServer) void {
        self.srv.deinit(); // tears down any registry-minted sessions (joins their workers)
        self.alloc.destroy(self.srv);
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
    }
};

fn emptyMcp(es: *EmptyServer, body: []const u8, out: []u8) Resp {
    var req_buf: [2048]u8 = undefined;
    const raw = std.fmt.bufPrint(&req_buf, "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    return serveRaw(es.srv, raw, out);
}

fn emptyGet(es: *EmptyServer, path: []const u8, out: []u8) Resp {
    var req_buf: [256]u8 = undefined;
    const raw = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path}) catch unreachable;
    return serveRaw(es.srv, raw, out);
}

test "empty-start: /api/health answers ok with no machine provisioned" {
    var es = try EmptyServer.init(std.testing.allocator);
    defer es.deinit();
    const r = emptyGet(&es, "/api/health", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"ok\":true") != null);
}

test "empty-start: initialize is still a pure handshake with no machine" {
    var es = try EmptyServer.init(std.testing.allocator);
    defer es.deinit();
    const r = emptyMcp(&es, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"protocolVersion\":\"2025-06-18\"") != null);
    var sbuf: [128]u8 = undefined;
    try std.testing.expect(sessionHeader(r.raw, &sbuf) == null);
}

test "empty-start: a per-machine MCP tool with no machine is the no_machine guided error" {
    var es = try EmptyServer.init(std.testing.allocator);
    defer es.deinit();
    const r = emptyMcp(&es, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"status\"}}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status); // a tool error is still HTTP 200 (isError result)
    try std.testing.expect(std.mem.indexOf(u8, r.body, "no_machine") != null);
}

test "empty-start: a blank /api/* request is 409 (no machine provisioned)" {
    var es = try EmptyServer.init(std.testing.allocator);
    defer es.deinit();
    const r = emptyGet(&es, "/api/status", &obuf);
    try std.testing.expectEqual(@as(u16, 409), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "no_machine") != null);
}

test "empty-start: provision -> drive by {machine} -> list -> deprovision all work" {
    var es = try EmptyServer.init(std.testing.allocator);
    defer es.deinit();

    // provision a REAL machine even though no default ever existed.
    var bbuf: [1024]u8 = undefined;
    const pbody = std.fmt.bufPrint(&bbuf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"provision_machine\",\"arguments\":{{\"mount_dir\":\"{s}\",\"file\":\"HELLO.COM\"}}}}}}", .{build_options.examples_dir}) catch unreachable;
    const pr = emptyMcp(&es, pbody, &obuf);
    try std.testing.expectEqual(@as(u16, 200), pr.status);
    var pnav = try Nav.parse(std.testing.allocator, pr.body);
    const handle = try std.testing.allocator.dupe(u8, toolObject(&pnav).object.get("machine").?.string);
    pnav.deinit();
    defer std.testing.allocator.free(handle);
    try std.testing.expect(std.mem.startsWith(u8, handle, "zdos-sess-"));
    try std.testing.expectEqual(@as(usize, 1), es.srv.registry.liveCount());

    // drive it by {machine}: a step on its own worker returns a non-error result.
    var sbuf: [512]u8 = undefined;
    const step = std.fmt.bufPrint(&sbuf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"step\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{handle}) catch unreachable;
    const sr = emptyMcp(&es, step, &obuf);
    try std.testing.expectEqual(@as(u16, 200), sr.status);
    try std.testing.expect(std.mem.indexOf(u8, sr.body, "\"isError\":false") != null);

    // list_machines shows exactly the one live machine.
    {
        const lr = emptyMcp(&es, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_machines\"}}", &obuf);
        var lnav = try Nav.parse(std.testing.allocator, lr.body);
        defer lnav.deinit();
        try std.testing.expectEqual(@as(i64, 1), toolObject(&lnav).object.get("live_machines").?.integer);
    }

    // deprovision frees it; the registry is empty again.
    var dbuf: [512]u8 = undefined;
    const del = std.fmt.bufPrint(&dbuf, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"deprovision\",\"arguments\":{{\"machine\":\"{s}\"}}}}}}", .{handle}) catch unreachable;
    _ = emptyMcp(&es, del, &obuf);
    try std.testing.expectEqual(@as(usize, 0), es.srv.registry.liveCount());
}
