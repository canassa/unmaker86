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
        srv.* = Server.init(alloc, io, undefined, 0, server_mod.LoadRecipe.init(2, "PROG.COM", ""), std.Io.Dir.cwd());
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
                const ww: worker.Worker = .{ .queue = &s.queue, .ctrl = s.ctrl };
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
