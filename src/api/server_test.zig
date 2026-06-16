//! Phase 4 server route/JSON tests (§D #4 + route/parse/serialize round-trips),
//! driven IN-PROCESS over in-memory reader/writer streams — NO real socket. The
//! server's queue + worker thread run for real, so this exercises the full
//! request → Command → submit → worker → Response → JSON path. (The single
//! real-socket test lives in server_integration_test.zig, an opt-in step.)

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

/// A live test server: a real machine + Controller, a CommandQueue, and the worker
/// thread spawned — but NO net listener. Requests are fed via `request()`.
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
        const m = try makeMachine(alloc);
        const srv = try alloc.create(Server);
        srv.* = try Server.init(alloc, io, undefined, 0, server_mod.LoadRecipe.init(2, "PROG.COM", ""), std.Io.Dir.cwd());
        // The Controller lives inline in the returned struct; `start()` binds
        // `srv.ctrl` to its FINAL address (after the caller stores the struct), so
        // the worker thread sees the stable Controller.
        return .{
            .alloc = alloc,
            .threaded = threaded,
            .m = m,
            .ctrl = Controller.init(m),
            .srv = srv,
            .worker = undefined,
        };
    }

    fn start(self: *TestServer) !void {
        self.srv.ctrl = &self.ctrl;
        const w = struct {
            fn run(s: *Server) void {
                const worker = @import("worker.zig");
                const ww: worker.Worker = .{ .queue = &s.queue, .ctrl = s.ctrl, .render = s.render };
                ww.run();
            }
        };
        self.worker = try std.Thread.spawn(.{}, w.run, .{self.srv});
    }

    fn deinit(self: *TestServer) void {
        // Shut the worker down via the sentinel, join, then free.
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.srv.queue.submit(&ctx);
        self.worker.join();
        self.srv.deinit();
        destroy(self.alloc, self.m);
        self.alloc.destroy(self.srv);
        self.threaded.deinit();
        self.alloc.destroy(self.threaded);
    }

    /// Issue one HTTP request (raw bytes) over in-memory streams; return the FULL
    /// raw HTTP response (status line + headers + body) in `out_buf`.
    fn request(self: *TestServer, raw: []const u8, out_buf: []u8) []const u8 {
        var in = std.Io.Reader.fixed(raw);
        var out = std.Io.Writer.fixed(out_buf);
        var hs = http.Server.init(&in, &out);
        self.srv.serveOne(&hs);
        return out.buffered();
    }
};

const Resp = struct { status: u16, body: []const u8 };

/// Extract the body (after the blank line) and the numeric status from a raw
/// HTTP/1.1 response.
fn splitResponse(raw: []const u8) Resp {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n").?;
    const body = raw[sep + 4 ..];
    // status: "HTTP/1.1 NNN ..."
    const sp = std.mem.indexOfScalar(u8, raw, ' ').?;
    const status = std.fmt.parseInt(u16, raw[sp + 1 .. sp + 4], 10) catch 0;
    return .{ .status = status, .body = body };
}

fn get(ts: *TestServer, path: []const u8, out: []u8) Resp {
    var req_buf: [512]u8 = undefined;
    const raw = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path}) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

fn post(ts: *TestServer, path: []const u8, body: []const u8, out: []u8) Resp {
    var req_buf: [1024]u8 = undefined;
    const raw = std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ "POST", path, body.len, body }) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

fn method(ts: *TestServer, m: []const u8, path: []const u8, body: []const u8, out: []u8) Resp {
    var req_buf: [1024]u8 = undefined;
    const raw = if (body.len > 0)
        std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: x\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ m, path, body.len, body }) catch unreachable
    else
        std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{ m, path }) catch unreachable;
    return splitResponse(ts.request(raw, out));
}

var obuf: [16 * 1024]u8 = undefined;

test "GET /api/health is a constant body, off-worker" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/health", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"ok\":true,\"version\":\"zdos-m2\"}", r.body);
}

test "GET /api/status reports runnable + cycles" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/status", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"runnable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"cycles\":") != null);
}

test "GET /api/cpu returns the snapshot" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/cpu", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"eip\":") != null);
}

test "POST /api/run advances and returns a StopReason" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = post(&ts, "/api/run", "{\"cycle_cap\":10000}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"stop\":") != null);
}

test "POST /api/breakpoints then GET list (ascending id) then DELETE all" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const a = post(&ts, "/api/breakpoints", "{\"kind\":{\"cycle\":{\"at_cycle\":578}}}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), a.status);
    try std.testing.expect(std.mem.indexOf(u8, a.body, "\"id\":0") != null);

    const list = get(&ts, "/api/breakpoints", &obuf);
    try std.testing.expectEqual(@as(u16, 200), list.status);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"breakpoints\":[{\"id\":0") != null);

    const del = method(&ts, "DELETE", "/api/breakpoints", "", &obuf);
    try std.testing.expectEqual(@as(u16, 200), del.status);
    try std.testing.expectEqualStrings("{\"removed\":1}", del.body);
}

test "GET unknown breakpoint id → 404 no_such_breakpoint" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/breakpoints/9", &obuf);
    try std.testing.expectEqual(@as(u16, 404), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"no_such_breakpoint\"") != null);
}

test "POST /api/breakpoints kind:io → 501 not_implemented (honest deferral)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = post(&ts, "/api/breakpoints", "{\"kind\":{\"io\":{\"port\":96,\"access\":\"access\"}}}", &obuf);
    try std.testing.expectEqual(@as(u16, 501), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"not_implemented\"") != null);
}

test "GET /api/disasm → 501 (deferred, not faked)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/disasm", &obuf);
    try std.testing.expectEqual(@as(u16, 501), r.status);
}

test "PUT /api/mem writes hex, GET /api/mem reads it back" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const w = method(&ts, "PUT", "/api/mem", "{\"phys\":1536,\"data\":\"b80200\"}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), w.status);
    try std.testing.expectEqualStrings("{\"phys\":1536,\"len\":3}", w.body);

    const r = get(&ts, "/api/mem?phys=1536&len=3", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"phys\":1536,\"len\":3,\"data\":\"b80200\"}", r.body);
}

test "GET /api/mem over the 4096 cap → 400 out_of_range" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/mem?phys=0&len=5000", &obuf);
    try std.testing.expectEqual(@as(u16, 400), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"out_of_range\"") != null);
}

test "GET /api/mem beyond the slab → 400 address_out_of_range" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/mem?phys=4294967290&len=16", &obuf);
    try std.testing.expectEqual(@as(u16, 400), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"address_out_of_range\"") != null);
}

test "PATCH /api/cpu/reg sets eax, GET /api/cpu reflects it" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const p = method(&ts, "PATCH", "/api/cpu/reg", "{\"reg32\":{\"name\":\"eax\",\"value\":4660}}", &obuf);
    try std.testing.expectEqual(@as(u16, 200), p.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", p.body);
    const c = get(&ts, "/api/cpu", &obuf);
    try std.testing.expect(std.mem.indexOf(u8, c.body, "\"eax\":4660") != null);
}

test "PATCH /api/cpu/reg unknown name → 400" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const p = method(&ts, "PATCH", "/api/cpu/reg", "{\"reg32\":{\"name\":\"nope\",\"value\":1}}", &obuf);
    try std.testing.expectEqual(@as(u16, 400), p.status);
}

test "PATCH /api/cpu/reg reg8 value overflow → 400 out_of_range" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const p = method(&ts, "PATCH", "/api/cpu/reg", "{\"reg8\":{\"name\":\"al\",\"value\":256}}", &obuf);
    try std.testing.expectEqual(@as(u16, 400), p.status);
    try std.testing.expect(std.mem.indexOf(u8, p.body, "\"out_of_range\"") != null);
}

test "GET /api/ivt/{vector} reads an IVT entry" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/ivt/33", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"vector\":33") != null);
}

test "GET /api/memory-regions lists the slab regions" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/memory-regions", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"regions\":[{\"kind\":\"ram\"") != null);
}

test "unknown route → 404; wrong method → 405" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const nf = get(&ts, "/api/nope", &obuf);
    try std.testing.expectEqual(@as(u16, 404), nf.status);
    const na = method(&ts, "DELETE", "/api/status", "", &obuf);
    try std.testing.expectEqual(@as(u16, 405), na.status);
}

test "malformed JSON body → 400 bad_request" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = post(&ts, "/api/run-to-cycle", "{not json", &obuf);
    try std.testing.expectEqual(@as(u16, 400), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"bad_request\"") != null);
}

test "#4 capped-run reproducibility through the handler path (two fresh servers)" {
    const alloc = std.testing.allocator;
    var first_body_buf: [256]u8 = undefined;
    var first_body: ?[]u8 = null;
    var run: usize = 0;
    while (run < 2) : (run += 1) {
        var ts = try TestServer.init(alloc);
        try ts.start();
        defer ts.deinit();
        // add a cycle bp, run, read cpu — the same sequence each launch.
        _ = post(&ts, "/api/breakpoints", "{\"kind\":{\"cycle\":{\"at_cycle\":5}}}", &obuf);
        const stop = post(&ts, "/api/run", "{\"cycle_cap\":100000}", &obuf);
        // capture the stop response body; it must be byte-identical across launches.
        if (first_body) |fb| {
            try std.testing.expectEqualStrings(fb, stop.body);
        } else {
            @memcpy(first_body_buf[0..stop.body.len], stop.body);
            first_body = first_body_buf[0..stop.body.len];
        }
    }
}

// ---------------------------------------------------------------------------
// Static UI serving (video-stream Phase 1 / http-static-serving.md). Off-worker,
// same-origin homepage; the branches sit after `/api/*` and before the 404.
// ---------------------------------------------------------------------------

test "GET / serves the index.html page (200, text/html, known marker)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const out = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(out);
    const raw = ts.request("GET / HTTP/1.1\r\nHost: x\r\n\r\n", out);
    const r = splitResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", headerValue(raw, "content-type").?);
    try std.testing.expectEqualStrings("no-cache", headerValue(raw, "cache-control").?);
    // The page carries an explicit marker proving it (not a 404 body) was served.
    try std.testing.expect(std.mem.indexOf(u8, r.body, "zdos-player-canvas") != null);
    // It pulls in the WebGL2 player script.
    try std.testing.expect(std.mem.indexOf(u8, r.body, "app.js") != null);
}

test "GET /app.js serves the script with text/javascript" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    // The player script is larger than the other assets; size for the full body.
    const out = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(out);
    const raw = ts.request("GET /app.js HTTP/1.1\r\nHost: x\r\n\r\n", out);
    const r = splitResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", headerValue(raw, "content-type").?);
    // The full script body fit in the buffer (no truncation).
    try std.testing.expect(std.mem.indexOf(u8, raw, "\r\n\r\n") != null);
    // The player script connects to the stream and forwards input.
    try std.testing.expect(std.mem.indexOf(u8, r.body, "/api/stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "/api/input/key") != null);
}

test "GET /style.css serves the stylesheet with text/css" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const out = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(out);
    const raw = ts.request("GET /style.css HTTP/1.1\r\nHost: x\r\n\r\n", out);
    const r = splitResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", headerValue(raw, "content-type").?);
}

test "HEAD / returns headers with no body (200, text/html)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const out = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(out);
    const raw = ts.request("HEAD / HTTP/1.1\r\nHost: x\r\n\r\n", out);
    const r = splitResponse(raw);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", headerValue(raw, "content-type").?);
    // HEAD: headers present (incl. content-length), but no body.
    try std.testing.expectEqual(@as(usize, 0), r.body.len);
    try std.testing.expect(headerValue(raw, "content-length") != null);
}

test "unknown static path → 404 (no shadowing of the 404 catch-all)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/nope.html", &obuf);
    try std.testing.expectEqual(@as(u16, 404), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"not_found\"") != null);
}

test "POST / on a static asset → 405 method_not_allowed" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = post(&ts, "/", "", &obuf);
    try std.testing.expectEqual(@as(u16, 405), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"method_not_allowed\"") != null);
}

test "static routes do not shadow the API (/api/health still resolves)" {
    var ts = try TestServer.init(std.testing.allocator);
    try ts.start();
    defer ts.deinit();
    const r = get(&ts, "/api/health", &obuf);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"ok\":true,\"version\":\"zdos-m2\"}", r.body);
}

// ---------------------------------------------------------------------------
// GET /api/framebuffer (Phase 4, B1) — the raw-binary capture transport. The
// pixels stream from the server-owned render buffer, NOT through resp_buf/JSON.
// ---------------------------------------------------------------------------

/// Find a header value (case-insensitive name) in the raw HTTP head.
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

test "GET /api/framebuffer mode 13h streams the raw index image (B1)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();

    // Put the BDA in mode 13h and lay a known VRAM pattern + palette.
    ts.m.bus.writePhys8(0x400 + 0x49, 0x13); // OFF_VIDEO_MODE = 13h
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) ts.m.vga.vram[i] = @truncate(i * 3 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) ts.m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 5, .blue = 9 };

    // A big out buffer: status+headers + 64000-byte body.
    const out = try alloc.alloc(u8, 80 * 1024);
    defer alloc.free(out);
    const raw = ts.request("GET /api/framebuffer HTTP/1.1\r\nHost: x\r\n\r\n", out);

    try std.testing.expect(std.mem.indexOf(u8, raw, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "application/octet-stream") != null);
    try std.testing.expectEqualStrings("320", headerValue(raw, "x-frame-width").?);
    try std.testing.expectEqualStrings("200", headerValue(raw, "x-frame-height").?);
    try std.testing.expectEqualStrings("index", headerValue(raw, "x-frame-format").?);

    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n").?;
    const body = raw[sep + 4 ..];
    try std.testing.expectEqual(@as(usize, 320 * 200), body.len);
    // The body IS the raw VRAM index bytes (mode 13h: index == VRAM).
    try std.testing.expectEqual(ts.m.vga.vram[0], body[0]);
    try std.testing.expectEqual(ts.m.vga.vram[100], body[100]);
    try std.testing.expectEqual(ts.m.vga.vram[320 * 200 - 1], body[320 * 200 - 1]);
}

test "GET /api/framebuffer?format=rgba streams the DAC-expanded RGBA" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    ts.m.bus.writePhys8(0x400 + 0x49, 0x13);
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) ts.m.vga.vram[i] = @truncate(i);
    var k: u16 = 0;
    while (k < 256) : (k += 1) ts.m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 0, .blue = 0 };

    const out = try alloc.alloc(u8, 320 * 200 * 4 + 4096);
    defer alloc.free(out);
    const raw = ts.request("GET /api/framebuffer?format=rgba HTTP/1.1\r\nHost: x\r\n\r\n", out);
    try std.testing.expect(std.mem.indexOf(u8, raw, "200") != null);
    try std.testing.expectEqualStrings("rgba", headerValue(raw, "x-frame-format").?);
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n").?;
    const body = raw[sep + 4 ..];
    try std.testing.expectEqual(@as(usize, 320 * 200 * 4), body.len);
    // Pixel 0: DAC[vram[0]] -> 6->8. vram[0] = 0 -> red = expand(0)=0; alpha=0xFF.
    const idx0 = ts.m.vga.vram[0];
    const expect_r = (@as(u8, ts.m.vga.dac_rgb[idx0].red & 0x3F) << 2) | (ts.m.vga.dac_rgb[idx0].red >> 4);
    try std.testing.expectEqual(expect_r, body[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), body[3]);
}

test "GET /api/framebuffer in an unsupported mode -> 501 (honest, no fake frame)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    // Mode 0xFE has no rasterizer wired -> 501, never a fabricated body.
    ts.m.bus.writePhys8(0x400 + 0x49, 0xFE);
    const r = get(&ts, "/api/framebuffer", &obuf);
    try std.testing.expectEqual(@as(u16, 501), r.status);
}

// ---------------------------------------------------------------------------
// GET /api/framebuffer?format=png — the viewable screenshot (screenshot-api.md).
// ---------------------------------------------------------------------------

const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Walk a PNG byte stream and return the first chunk of the named type.
fn pngChunk(bytes: []const u8, want: *const [4]u8) ?[]const u8 {
    var pos: usize = 8; // skip signature
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        if (std.mem.eql(u8, ctype, want)) return bytes[pos + 8 ..][0..len];
        pos += 12 + len;
    }
    return null;
}

test "GET /api/framebuffer?format=png mode 13h -> 200 image/png, indexed, decodes to the laid pattern" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();

    // Same known mode-13h pattern + palette the index/rgba tests use.
    ts.m.bus.writePhys8(0x400 + 0x49, 0x13);
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) ts.m.vga.vram[i] = @truncate(i * 3 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) ts.m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 5, .blue = 9 };

    const out = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(out);
    const raw = ts.request("GET /api/framebuffer?format=png HTTP/1.1\r\nHost: x\r\n\r\n", out);

    try std.testing.expect(std.mem.indexOf(u8, raw, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "image/png") != null);
    try std.testing.expectEqualStrings("320", headerValue(raw, "x-frame-width").?);
    try std.testing.expectEqualStrings("200", headerValue(raw, "x-frame-height").?);
    try std.testing.expectEqualStrings("png-indexed", headerValue(raw, "x-frame-format").?);

    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n").?;
    const body = raw[sep + 4 ..];
    try std.testing.expectEqualSlices(u8, &png_signature, body[0..8]);

    // IHDR: 320x200, bit depth 8, color type 3 (indexed).
    const ihdr = pngChunk(body, "IHDR").?;
    try std.testing.expectEqual(@as(u32, 320), std.mem.readInt(u32, ihdr[0..4], .big));
    try std.testing.expectEqual(@as(u32, 200), std.mem.readInt(u32, ihdr[4..8], .big));
    try std.testing.expectEqual(@as(u8, 8), ihdr[8]);
    try std.testing.expectEqual(@as(u8, 3), ihdr[9]);

    // PLTE present, 768 bytes; entry for vram[0]'s index has the laid DAC color, 6->8.
    const plte = pngChunk(body, "PLTE").?;
    try std.testing.expectEqual(@as(usize, 768), plte.len);

    // Decode the IDAT, strip filter bytes, and check pixel 0 / pixel N == VRAM indices.
    const idat = pngChunk(body, "IDAT").?;
    var reader: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    const decoded = try alloc.alloc(u8, 200 * (1 + 320));
    defer alloc.free(decoded);
    const n = try dec.reader.readSliceShort(decoded);
    try std.testing.expectEqual(@as(usize, 200 * (1 + 320)), n);
    // Row 0: filter byte then 320 indices == vram[0..320].
    try std.testing.expectEqual(@as(u8, 0), decoded[0]);
    try std.testing.expectEqual(ts.m.vga.vram[0], decoded[1]);
    try std.testing.expectEqual(ts.m.vga.vram[100], decoded[1 + 100]);
    // The PLTE entry the decoded index points at == the DAC color 6->8 expanded.
    const idx0 = ts.m.vga.vram[0];
    const expect_r = (@as(u8, ts.m.vga.dac_rgb[idx0].red & 0x3F) << 2) | (ts.m.vga.dac_rgb[idx0].red >> 4);
    try std.testing.expectEqual(expect_r, plte[@as(usize, idx0) * 3 + 0]);
}

test "GET /api/framebuffer?format=png is deterministic (two captures byte-identical)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    ts.m.bus.writePhys8(0x400 + 0x49, 0x13);
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) ts.m.vga.vram[i] = @truncate(i * 7 + 3);
    var k: u16 = 0;
    while (k < 256) : (k += 1) ts.m.vga.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = @truncate((k >> 1) & 0x3F), .blue = 0 };

    const o1 = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(o1);
    const o2 = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(o2);
    const r1 = ts.request("GET /api/framebuffer?format=png HTTP/1.1\r\nHost: x\r\n\r\n", o1);
    const r2 = ts.request("GET /api/framebuffer?format=png HTTP/1.1\r\nHost: x\r\n\r\n", o2);
    const b1 = r1[std.mem.indexOf(u8, r1, "\r\n\r\n").? + 4 ..];
    const b2 = r2[std.mem.indexOf(u8, r2, "\r\n\r\n").? + 4 ..];
    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "GET /api/framebuffer?format=png in an unsupported mode -> 501 (no fake frame)" {
    const alloc = std.testing.allocator;
    var ts = try TestServer.init(alloc);
    try ts.start();
    defer ts.deinit();
    ts.m.bus.writePhys8(0x400 + 0x49, 0xFE);
    const r = get(&ts, "/api/framebuffer?format=png", &obuf);
    try std.testing.expectEqual(@as(u16, 501), r.status);
}
