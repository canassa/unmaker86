//! The HTTP/1.1 + JSON listener (M2 §A/§B, Phase 4). Runs on its OWN thread(s) and
//! NEVER touches the machine: every handler builds a `Command`, `submit()`s it to
//! the queue, and serializes the `Response` the worker returns. Only `/api/health`
//! is answered off-worker — and it reads ZERO machine state (a constant body).
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `net.IpAddress.listen(*const IpAddress, io, opts)` (`Io/net.zig:246`);
//!     `Ip4Address.loopback(port)` (`:349`) returns a BARE `Ip4Address` → wrap in
//!     the union: `.{ .ip4 = .loopback(port) }`.
//!   - `net.Server.accept(io) Stream` (`:1442`); clean stop: there is NO
//!     `socket.shutdown` — wrap the server socket in a `Stream` and
//!     `Stream.shutdown(io, .recv)` (`:1252`), or `server.deinit(io)` (`:1406`);
//!     `accept` then returns `error.SocketNotListening`.
//!   - `Stream.reader/writer(io, buf)` (`:1393/:1397`) RETURN BY VALUE → declare
//!     named locals `sr`/`sw` that OUTLIVE the `http.Server` (else `@fieldParentPtr`
//!     dangles). `http.Server.init(&sr.interface, &sw.interface)` (`http/Server.zig:25`).
//!   - `receiveHead()` (`:46`); the body reader is `request.readerExpectNone(buf)`
//!     (`:591`) — NOT `request.reader`; it `invalidateStrings()`s the `Head`, so we
//!     CAPTURE the route + content-type into owned storage FIRST.
//!   - `request.respond(content, .{.status, .keep_alive=false, .extra_headers})`
//!     (`:323`).
//!
//! Determinism (constraint #4): the listener's timing affects only HTTP latency,
//! never which guest instructions ran or in what order. One connection at a time,
//! keep-alive OFF → one request per connection → one command in flight by
//! construction (the queue's `submit()` also asserts the ring empty).

const std = @import("std");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const q = @import("queue.zig");
const worker_mod = @import("worker.zig");
const wire = @import("json_wire.zig");
const scancodes = @import("bios").scancodes;

const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const Controller = debug.Controller;
const Reg32 = cpu_mod.Reg32;
const Reg16 = debug.Reg16;
const Reg8 = debug.Reg8;
const Seg = cpu_mod.Seg;

const HTTP_HEADER_MAX = 16 * 1024; // also the head-parse buffer; undersize → 413/oversize-head
const WRITE_BUF = 8 * 1024;
const MAX_BODY = 64 * 1024; // > MAX_MEM_CHUNK*2 hex + JSON overhead; reject larger with 413
const RESPONSE_BUF = 32 * 1024; // serialized JSON body

const json_content_type = [_]http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};

/// The server-held program-load recipe (captured at `--serve` startup, updated by
/// `POST /api/load`). Re-applied via the worker — the only way to a runnable
/// machine after `reset()` (§B.1/G16). Fixed-capacity, pointer-free.
pub const LoadRecipe = struct {
    drive: u8,
    file_len: u8 = 0,
    file: [13]u8 = undefined,
    cmdtail_len: u8 = 0,
    cmdtail: [127]u8 = undefined,

    pub fn init(drive: u8, file: []const u8, cmdtail: []const u8) LoadRecipe {
        var r: LoadRecipe = .{ .drive = drive };
        const fn_len = @min(file.len, r.file.len);
        @memcpy(r.file[0..fn_len], file[0..fn_len]);
        r.file_len = @intCast(fn_len);
        const ct_len = @min(cmdtail.len, r.cmdtail.len);
        @memcpy(r.cmdtail[0..ct_len], cmdtail[0..ct_len]);
        r.cmdtail_len = @intCast(ct_len);
        return r;
    }

    fn toCmd(self: LoadRecipe) q.LoadCmd {
        var c: q.LoadCmd = .{
            .drive = self.drive,
            .file_len = self.file_len,
            .cmdtail_len = self.cmdtail_len,
        };
        @memcpy(c.file[0..self.file_len], self.file[0..self.file_len]);
        @memcpy(c.cmdtail[0..self.cmdtail_len], self.cmdtail[0..self.cmdtail_len]);
        return c;
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ctrl: *Controller,
    port: u16,
    recipe: LoadRecipe,
    /// The host directory mounted as the DOS drive (`recipe.drive`). Held so the
    /// worker can RE-mount it on `POST /api/load` — `reset()` wipes the mount via
    /// `dos.init` (G16 / the reset→load bug). Re-mount runs on the worker thread.
    mount_dir: Io.Dir,

    queue: q.CommandQueue,
    worker_thread: ?std.Thread = null,
    net_server: ?net.Server = null,

    // Per-request scratch (one connection at a time → safe to reuse).
    arena: std.heap.ArenaAllocator,
    resp_buf: [RESPONSE_BUF]u8 = undefined,
    body_buf: [MAX_BODY]u8 = undefined,
    read_scratch: [MAX_BODY]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: Io, ctrl: *Controller, port: u16, recipe: LoadRecipe, mount_dir: Io.Dir) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .ctrl = ctrl,
            .port = port,
            .recipe = recipe,
            .mount_dir = mount_dir,
            .queue = q.CommandQueue.init(io),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        self.arena.deinit();
    }

    /// Bind, spawn the worker, and run the accept loop until shutdown (= `bind` then
    /// `serve`). The worker (sole owner of `ctrl`) drains the queue; the listener
    /// (this thread) does all socket/HTTP/JSON work.
    pub fn run(self: *Server) !void {
        try self.bind();
        try self.serve();
    }

    /// Spawn the worker and bind the listening socket. After this, `boundPort()`
    /// returns the OS-assigned port — which is the request's `port` unless it was 0
    /// (ephemeral), in which case `listen` resolves it via `getsockname` and stores
    /// it in `Socket.address` (`Io/net.zig:1054`, filled by `netListenIpPosix`'s
    /// `getsockname`, `Io/Threaded.zig:11828`). Split out of `run` so a caller (the
    /// `--serve 0` path) can PRINT the resolved port BEFORE the blocking accept loop.
    pub fn bind(self: *Server) !void {
        const w: worker_mod.Worker = .{ .queue = &self.queue, .ctrl = self.ctrl, .mount_dir = self.mount_dir, .io = self.io };
        self.worker_thread = try std.Thread.spawn(.{}, worker_mod.Worker.run, .{w});

        const addr: net.IpAddress = .{ .ip4 = .loopback(self.port) };
        self.net_server = try addr.listen(self.io, .{ .reuse_address = true });
        // Record the resolved (possibly ephemeral) port for `boundPort()`.
        self.port = self.net_server.?.socket.address.getPort();
    }

    /// The OS-assigned listening port. Valid only AFTER `bind`/`run` has listened
    /// (for `--serve 0` it is the ephemeral port `getsockname` resolved).
    pub fn boundPort(self: *const Server) u16 {
        return self.port;
    }

    /// Run the accept loop until shutdown. `bind` MUST have been called first.
    pub fn serve(self: *Server) !void {
        while (true) {
            var stream = self.net_server.?.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening => break, // clean shutdown signaled
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            self.handleConnection(&stream);
            stream.close(self.io);
        }

        if (self.net_server) |*s| {
            s.deinit(self.io); // close the listening socket on clean exit
            self.net_server = null;
        }
        self.joinWorker();
    }

    /// Stop the accept loop from another thread. There is NO `socket.shutdown`
    /// (§0.3): wrap the listening socket in a `net.Stream` and `shutdown(.both)` —
    /// a blocked `accept` then returns `error.SocketNotListening`. We do NOT call
    /// `net_server.deinit` here (it sets the Server to `undefined`, racing the run
    /// loop's `accept`); the run loop closes the socket on exit via `deinit`.
    pub fn shutdown(self: *Server) void {
        if (self.net_server) |s| {
            const stream: net.Stream = .{ .socket = s.socket };
            stream.shutdown(self.io, .both) catch {};
        }
    }

    fn joinWorker(self: *Server) void {
        // Drain the worker with the shutdown sentinel, then join.
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.queue.submit(&ctx);
        if (self.worker_thread) |t| t.join();
        self.worker_thread = null;
    }

    // -----------------------------------------------------------------------
    // Per-connection: one request, keep-alive OFF.
    // -----------------------------------------------------------------------

    fn handleConnection(self: *Server, stream: *net.Stream) void {
        // Named locals that OUTLIVE the http.Server (return-by-value lifetime rule).
        var rbuf: [HTTP_HEADER_MAX]u8 = undefined;
        var wbuf: [WRITE_BUF]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        var sw = stream.writer(self.io, &wbuf);
        var hs = http.Server.init(&sr.interface, &sw.interface);
        self.serveOne(&hs);
    }

    /// Handle exactly one HTTP request over an already-constructed `http.Server`.
    /// Factored out of `handleConnection` so an in-process test can drive it over
    /// in-memory reader/writer streams (no real socket).
    pub fn serveOne(self: *Server, hs: *http.Server) void {
        var request = hs.receiveHead() catch return; // malformed/oversized head → drop

        // CAPTURE route + content-type BEFORE taking the body reader (it invalidates
        // Head strings). We copy into fixed locals.
        var target_buf: [1024]u8 = undefined;
        const target_src = request.head.target;
        if (target_src.len > target_buf.len) {
            self.respondError(&request, .payload_too_large, "payload_too_large", "request target too long");
            return;
        }
        @memcpy(target_buf[0..target_src.len], target_src);
        const target = target_buf[0..target_src.len];
        const method = request.head.method;
        const content_length = request.head.content_length orelse 0;
        const is_json = blk: {
            const ct = request.head.content_type orelse break :blk false;
            break :blk std.mem.startsWith(u8, ct, "application/json");
        };

        // Reject an oversized body BEFORE reading it (413).
        if (content_length > MAX_BODY) {
            self.respondError(&request, .payload_too_large, "payload_too_large", "request body too large");
            return;
        }

        // Read the body (now that route+ct are captured). The body reader uses
        // `read_scratch` as its working buffer; we copy out into `body_buf` (a
        // DISTINCT buffer — they must not alias, else @memcpy panics).
        var body: []const u8 = &.{};
        if (content_length > 0) {
            const reader = request.readerExpectNone(self.read_scratch[0..]);
            const got = reader.readSliceShort(self.body_buf[0..@intCast(content_length)]) catch {
                self.respondError(&request, .bad_request, "bad_request", "failed to read request body");
                return;
            };
            body = self.body_buf[0..got];
        }

        self.dispatch(&request, method, target, body, is_json);
    }

    // -----------------------------------------------------------------------
    // Routing — method + path → handler. Path params: {id}, {vector}; query: ?k=v.
    // -----------------------------------------------------------------------

    fn dispatch(self: *Server, req: *http.Server.Request, method: http.Method, target: []const u8, body: []const u8, is_json: bool) void {
        // Split target into path + query.
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |i| target[0..i] else target;
        const query = if (qmark) |i| target[i + 1 ..] else "";

        // --- session / status / health ---
        if (std.mem.eql(u8, path, "/api/health")) {
            if (method != .GET) return self.methodNotAllowed(req);
            // OFF-WORKER, reads ZERO machine state (constant body) — §A.3a.
            self.respondJson(req, .ok, "{\"ok\":true,\"version\":\"zdos-m2\"}");
            return;
        }
        if (std.mem.eql(u8, path, "/api/status")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .status);
        }
        if (std.mem.eql(u8, path, "/api/memory-regions")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .mem_regions);
        }
        if (std.mem.eql(u8, path, "/api/reset")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .reset);
        }
        if (std.mem.eql(u8, path, "/api/load")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleLoad(req, body, is_json);
        }

        // --- execution control ---
        if (std.mem.eql(u8, path, "/api/run")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleRun(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/run-to-cycle")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleRunToCycle(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/run-to-address")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleRunToAddr(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/step")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .step);
        }
        if (std.mem.eql(u8, path, "/api/step-n")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleStepN(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/step-over")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .step_over);
        }

        // --- breakpoints ---
        if (std.mem.eql(u8, path, "/api/breakpoints")) {
            switch (method) {
                .POST => return self.handleAddBp(req, body, is_json),
                .GET => return self.submitAndRespond(req, .list_bp),
                .DELETE => return self.submitAndRespond(req, .clear_bp),
                else => return self.methodNotAllowed(req),
            }
        }
        if (std.mem.startsWith(u8, path, "/api/breakpoints/")) {
            const id_str = path["/api/breakpoints/".len..];
            const id = std.fmt.parseInt(u32, id_str, 10) catch return self.respondError(req, .bad_request, "bad_request", "breakpoint id must be an integer");
            switch (method) {
                .GET => return self.submitAndRespond(req, .{ .get_bp = .{ .id = id } }),
                .DELETE => return self.submitAndRespond(req, .{ .remove_bp = .{ .id = id } }),
                .PATCH => return self.handleEnableBp(req, id, body, is_json),
                else => return self.methodNotAllowed(req),
            }
        }

        // --- cpu ---
        if (std.mem.eql(u8, path, "/api/cpu")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.submitAndRespond(req, .cpu_get);
        }
        if (std.mem.eql(u8, path, "/api/cpu/reg")) {
            if (method != .PATCH) return self.methodNotAllowed(req);
            return self.handleRegSet(req, body, is_json);
        }

        // --- memory ---
        if (std.mem.eql(u8, path, "/api/mem")) {
            switch (method) {
                .GET => return self.handleMemPeek(req, query),
                .PUT => return self.handleMemWrite(req, body, is_json),
                else => return self.methodNotAllowed(req),
            }
        }
        if (std.mem.eql(u8, path, "/api/mem/seg")) {
            switch (method) {
                .GET => return self.handleMemPeekSeg(req, query),
                .PUT => return self.handleMemWriteSeg(req, body, is_json),
                else => return self.methodNotAllowed(req),
            }
        }

        // --- ivt / stack ---
        if (std.mem.startsWith(u8, path, "/api/ivt/")) {
            if (method != .GET) return self.methodNotAllowed(req);
            const v_str = path["/api/ivt/".len..];
            const vector = std.fmt.parseInt(u8, v_str, 10) catch return self.respondError(req, .bad_request, "bad_request", "vector must be 0-255");
            return self.submitAndRespond(req, .{ .ivt_get = .{ .vector = vector } });
        }
        if (std.mem.eql(u8, path, "/api/stack")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleStack(req, query);
        }

        // --- input injection ---
        if (std.mem.eql(u8, path, "/api/input/key")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleInputKey(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/input/mouse")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleInputMouse(req, body, is_json);
        }

        // --- deferred, honestly reported ---
        if (std.mem.eql(u8, path, "/api/disasm")) {
            return self.respondError(req, .not_implemented, "not_implemented", "disassembly is deferred to a later milestone");
        }

        self.respondError(req, .not_found, "not_found", "no such endpoint");
    }

    // -----------------------------------------------------------------------
    // Body-parsing handlers (parse → build Command → submit → respond).
    // -----------------------------------------------------------------------

    fn parseBody(self: *Server, comptime T: type, body: []const u8) ?T {
        _ = self.arena.reset(.retain_capacity);
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), body, wire.parse_options) catch null;
    }

    fn requireJson(self: *Server, req: *http.Server.Request, is_json: bool, body: []const u8) bool {
        // An empty body is allowed for endpoints that accept `{}`-equivalent (we treat
        // absent body as defaults). A non-empty body MUST be application/json.
        if (body.len > 0 and !is_json) {
            self.respondError(req, .unsupported_media_type, "unsupported_media_type", "request body must be application/json");
            return false;
        }
        return true;
    }

    fn handleRun(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const default_cap: u64 = 1 << 32;
        var cap: u64 = default_cap;
        if (body.len > 0) {
            const r = self.parseBody(wire.RunReq, body) orelse return self.badJson(req);
            cap = r.cycle_cap orelse default_cap;
        }
        self.submitAndRespond(req, .{ .run = .{ .cycle_cap = cap } });
    }

    fn handleRunToCycle(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToCycleReq, body) orelse return self.badJson(req);
        self.submitAndRespond(req, .{ .run_to_cycle = .{ .cycle = r.cycle } });
    }

    fn handleRunToAddr(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToAddrReq, body) orelse return self.badJson(req);
        self.submitAndRespond(req, .{ .run_to_address = .{ .linear = r.linear } });
    }

    fn handleStepN(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.StepNReq, body) orelse return self.badJson(req);
        self.submitAndRespond(req, .{ .step_n = .{ .n = r.n } });
    }

    fn handleInputKey(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.KeyReq, body) orelse return self.badJson(req);
        // Exactly one of scancode / char (§5.1).
        if (r.scancode != null and r.char != null) {
            return self.respondError(req, .bad_request, "bad_request", "give either scancode or char, not both");
        }
        if (r.scancode) |sc| {
            // Precise path: a single raw scancode edge.
            return self.submitAndRespond(req, .{ .input_key = .{
                .scancode = sc,
                .make = r.make,
                .ext = r.ext,
                .press = false,
                .shift = false,
            } });
        }
        if (r.char) |ch| {
            if (ch.len != 1) {
                return self.respondError(req, .bad_request, "bad_request", "char must be a single ASCII character");
            }
            // Resolve over the REAL set-1 table (not a fabricated map). A char with
            // no single set-1 key is a 400 (documented, §5.1) — never invented.
            const res = scancodes.resolveChar(ch[0]) orelse
                return self.respondError(req, .bad_request, "bad_request", "no single set-1 scancode for that char");
            return self.submitAndRespond(req, .{ .input_key = .{
                .scancode = res.scancode,
                .make = true,
                .ext = false,
                .press = true,
                .shift = res.shift,
            } });
        }
        self.respondError(req, .bad_request, "bad_request", "provide scancode or char");
    }

    fn handleInputMouse(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        var r: wire.MouseReq = .{};
        if (body.len > 0) r = self.parseBody(wire.MouseReq, body) orelse return self.badJson(req);
        // Absolute vs relative are mutually exclusive PER AXIS (§5.2): mixing an
        // absolute set with a relative delta on the SAME axis is ambiguous -> 400.
        if (r.x != null and r.dx != null) {
            return self.respondError(req, .bad_request, "bad_request", "give either x or dx, not both");
        }
        if (r.y != null and r.dy != null) {
            return self.respondError(req, .bad_request, "bad_request", "give either y or dy, not both");
        }
        // Require at least one motion/button field so an empty request is a 400 (no
        // silent no-op that a client could mistake for an applied event).
        if (r.x == null and r.y == null and r.dx == null and r.dy == null and r.buttons == null) {
            return self.respondError(req, .bad_request, "bad_request", "provide at least one of x/y/dx/dy/buttons");
        }
        _ = r.fire_callback; // Phase 3 (AX=000C event callback) — accepted, no-op here.
        self.submitAndRespond(req, .{ .input_mouse = .{
            .x = r.x orelse 0,
            .y = r.y orelse 0,
            .dx = r.dx orelse 0,
            .dy = r.dy orelse 0,
            .buttons = r.buttons orelse 0,
            .set_x = r.x != null,
            .set_y = r.y != null,
            .set_dx = r.dx != null,
            .set_dy = r.dy != null,
            .set_buttons = r.buttons != null,
        } });
    }

    fn handleAddBp(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.AddBpReq, body) orelse return self.badJson(req);
        // `io` breakpoints are declared in the core but matches()==false (M1 deferred)
        // → 501, never a fake accept (ground rule).
        if (r.kind == .io) return self.respondError(req, .not_implemented, "not_implemented", "io breakpoints are not implemented");
        self.submitAndRespond(req, .{ .add_bp = .{ .kind = r.kind, .one_shot = r.one_shot } });
    }

    fn handleEnableBp(self: *Server, req: *http.Server.Request, id: u32, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.EnableBpReq, body) orelse return self.badJson(req);
        self.submitAndRespond(req, .{ .enable_bp = .{ .id = id, .on = r.enabled } });
    }

    fn handleRegSet(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RegSetReq, body) orelse return self.badJson(req);
        // Resolve the enum NAME → typed enum (pure; no machine access) and range-check
        // the value to the register width before enqueue (§B.4).
        const cmd: q.RegSetCmd = switch (r) {
            .reg32 => |x| .{ .reg32 = .{
                .reg = std.meta.stringToEnum(Reg32, x.name) orelse return self.badEnum(req),
                .value = x.value,
            } },
            .reg16 => |x| blk: {
                if (x.value > std.math.maxInt(u16)) return self.respondError(req, .bad_request, "out_of_range", "value overflows 16-bit register");
                break :blk .{ .reg16 = .{
                    .reg = std.meta.stringToEnum(Reg16, x.name) orelse return self.badEnum(req),
                    .value = @intCast(x.value),
                } };
            },
            .reg8 => |x| blk: {
                if (x.value > std.math.maxInt(u8)) return self.respondError(req, .bad_request, "out_of_range", "value overflows 8-bit register");
                break :blk .{ .reg8 = .{
                    .reg = std.meta.stringToEnum(Reg8, x.name) orelse return self.badEnum(req),
                    .value = @intCast(x.value),
                } };
            },
            .seg => |x| blk: {
                if (x.value > std.math.maxInt(u16)) return self.respondError(req, .bad_request, "out_of_range", "value overflows segment selector");
                break :blk .{ .seg = .{
                    .seg = std.meta.stringToEnum(Seg, x.name) orelse return self.badEnum(req),
                    .value = @intCast(x.value),
                } };
            },
            .eip => |x| .{ .eip = .{ .value = x.value } },
            .flags => |f| .{ .flags = f.toFlags() },
        };
        self.submitAndRespond(req, .{ .reg_set = cmd });
    }

    fn handleLoad(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        // Start from the server-held recipe; override with any provided fields.
        var recipe = self.recipe;
        if (body.len > 0) {
            const r = self.parseBody(wire.LoadReq, body) orelse return self.badJson(req);
            if (r.drive) |d| recipe.drive = d;
            if (r.file) |f| {
                const n = @min(f.len, recipe.file.len);
                @memcpy(recipe.file[0..n], f[0..n]);
                recipe.file_len = @intCast(n);
            }
            if (r.cmdtail) |ct| {
                const n = @min(ct.len, recipe.cmdtail.len);
                @memcpy(recipe.cmdtail[0..n], ct[0..n]);
                recipe.cmdtail_len = @intCast(n);
            }
        }
        // Persist the updated recipe so a later `POST /api/load {}` re-loads it.
        self.recipe = recipe;
        self.submitAndRespond(req, .{ .load = recipe.toCmd() });
    }

    // --- memory handlers: query parse / hex decode into the request ctx scratch ---

    fn handleMemPeek(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const phys = self.queryU32(query, "phys") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid phys");
        const len = self.queryU32(query, "len") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid len");
        self.submitAndRespond(req, .{ .mem_peek = .{ .phys = phys, .len = len } });
    }

    fn handleMemWrite(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.MemWriteReq, body) orelse return self.badJson(req);
        var ctx: q.RequestCtx = .{ .cmd = undefined };
        const decoded = wire.hexDecode(ctx.scratch[0..], r.data) catch return self.respondError(req, .bad_request, "bad_request", "invalid hex in data");
        ctx.cmd = .{ .mem_write = .{ .phys = r.phys, .len = @intCast(decoded.len) } };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn handleMemPeekSeg(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const seg = self.querySeg(query) orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid seg");
        const off = self.queryU32(query, "off") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid off");
        const len = self.queryU32(query, "len") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid len");
        self.submitAndRespond(req, .{ .mem_peek_seg = .{ .seg = seg, .off = off, .len = len } });
    }

    fn handleMemWriteSeg(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.MemWriteSegReq, body) orelse return self.badJson(req);
        const seg = std.meta.stringToEnum(Seg, r.seg) orelse return self.badEnum(req);
        var ctx: q.RequestCtx = .{ .cmd = undefined };
        const decoded = wire.hexDecode(ctx.scratch[0..], r.data) catch return self.respondError(req, .bad_request, "bad_request", "invalid hex in data");
        ctx.cmd = .{ .mem_write_seg = .{ .seg = seg, .off = r.off, .len = @intCast(decoded.len) } };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn handleStack(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const count = self.queryU32(query, "count") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid count");
        if (count > std.math.maxInt(u16)) return self.respondError(req, .bad_request, "out_of_range", "count too large");
        self.submitAndRespond(req, .{ .stack_get = .{ .count = @intCast(count) } });
    }

    // -----------------------------------------------------------------------
    // Query helpers (decimal integers; seg name).
    // -----------------------------------------------------------------------

    fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        return null;
    }
    fn queryU32(self: *Server, query: []const u8, key: []const u8) ?u32 {
        _ = self;
        const v = queryValue(query, key) orelse return null;
        return std.fmt.parseInt(u32, v, 10) catch null;
    }
    fn querySeg(self: *Server, query: []const u8) ?Seg {
        _ = self;
        const v = queryValue(query, "seg") orelse return null;
        return std.meta.stringToEnum(Seg, v);
    }

    // -----------------------------------------------------------------------
    // Submit + serialize the response. The ONLY path that crosses to the worker.
    // -----------------------------------------------------------------------

    fn submitAndRespond(self: *Server, req: *http.Server.Request, cmd: q.Command) void {
        var ctx: q.RequestCtx = .{ .cmd = cmd };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn submitCtxAndRespond(self: *Server, req: *http.Server.Request, ctx: *q.RequestCtx) void {
        const resp = self.queue.submit(ctx);
        self.serializeResponse(req, resp);
    }

    fn serializeResponse(self: *Server, req: *http.Server.Request, resp: q.Response) void {
        switch (resp) {
            .err => |code| self.respondErrCode(req, code),
            .ok => self.respondJson(req, .ok, "{\"ok\":true}"),
            .stop => |s| self.respondValue(req, .ok, .{ .stop = s }),
            .step_over => |so| self.respondValue(req, .ok, .{ .stop = so.reason, .stepped_into = so.stepped_into }),
            .bp_id => |id| self.respondValue(req, .ok, .{ .id = id }),
            .bp_one => |b| self.respondValue(req, .ok, b),
            .bp_list => |l| self.respondBpList(req, l),
            .cleared => |n| self.respondValue(req, .ok, .{ .removed = n }),
            .cpu => |snap| self.respondValue(req, .ok, snap),
            .mem => |mr| self.respondMem(req, mr),
            .mem_written => |w| self.respondValue(req, .ok, .{ .phys = w.phys, .len = w.len }),
            .ivt => |i| self.respondValue(req, .ok, .{ .vector = i.vector, .ip = i.ip, .cs = i.cs }),
            .stack => |s| self.respondStack(req, s),
            .status => |st| self.respondValue(req, .ok, st),
            .regions => |rg| self.respondRegions(req, rg),
        }
    }

    fn respondValue(self: *Server, req: *http.Server.Request, status: http.Status, v: anytype) void {
        const json = wire.serialize(self.resp_buf[0..], v) catch return self.respondError(req, .service_unavailable, "internal", "response too large to serialize");
        self.respondJson(req, status, json);
    }

    fn respondBpList(self: *Server, req: *http.Server.Request, l: q.BpListResult) void {
        // Build {"breakpoints":[...]} with the inline items (ascending id order).
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.writeAll("{\"breakpoints\":") catch break :blk false;
            std.json.Stringify.value(l.items[0..l.count], wire.stringify_options, &w) catch break :blk false;
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn respondRegions(self: *Server, req: *http.Server.Request, rg: q.RegionsResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.writeAll("{\"regions\":") catch break :blk false;
            std.json.Stringify.value(rg.items[0..rg.count], wire.stringify_options, &w) catch break :blk false;
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn respondMem(self: *Server, req: *http.Server.Request, mr: q.MemResult) void {
        // {"phys":N,"len":N,"data":"<hex>"}
        var hex_buf: [q.MAX_MEM_CHUNK * 2]u8 = undefined;
        const hex = wire.hexEncode(&hex_buf, mr.bytes[0..mr.len]) catch return self.respondError(req, .service_unavailable, "internal", "encode failed");
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        w.print("{{\"phys\":{d},\"len\":{d},\"data\":\"{s}\"}}", .{ mr.phys, mr.len, hex }) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn respondStack(self: *Server, req: *http.Server.Request, s: q.StackResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.print("{{\"count\":{d},\"words\":", .{s.count}) catch break :blk false;
            std.json.Stringify.value(s.words[0..s.count], wire.stringify_options, &w) catch break :blk false;
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    // -----------------------------------------------------------------------
    // The code → HTTP status mapping lives ONLY here (D20).
    // -----------------------------------------------------------------------

    fn respondErrCode(self: *Server, req: *http.Server.Request, code: q.ErrCode) void {
        const status: http.Status, const code_str: []const u8, const msg: []const u8 = switch (code) {
            .breakpoint_table_full => .{ .service_unavailable, "breakpoint_table_full", "all breakpoint slots are in use" },
            .no_such_breakpoint => .{ .not_found, "no_such_breakpoint", "no breakpoint with that id" },
            .address_out_of_range => .{ .bad_request, "address_out_of_range", "memory range not contained in the addressable slab" },
            .out_of_range => .{ .bad_request, "out_of_range", "length/count/value exceeds the bounded cap" },
            .bad_request => .{ .bad_request, "bad_request", "malformed request" },
            .not_implemented => .{ .not_implemented, "not_implemented", "operation not implemented" },
            .load_failed => .{ .service_unavailable, "load_failed", "failed to load the program" },
            // A full 8042 output FIFO is a transient resource limit -> 503 (the
            // breakpoint_table_full idiom, input-injection.md §5.1b); `run` to drain
            // the controller via INT 09h, then retry.
            .input_buffer_full => .{ .service_unavailable, "input_buffer_full", "the 8042 keyboard output buffer is full" },
        };
        self.respondError(req, status, code_str, msg);
    }

    fn badJson(self: *Server, req: *http.Server.Request) void {
        self.respondError(req, .bad_request, "bad_request", "malformed JSON body");
    }
    fn badEnum(self: *Server, req: *http.Server.Request) void {
        self.respondError(req, .bad_request, "bad_request", "unknown register/segment name");
    }
    fn methodNotAllowed(self: *Server, req: *http.Server.Request) void {
        self.respondError(req, .method_not_allowed, "method_not_allowed", "method not allowed on this endpoint");
    }

    fn respondError(self: *Server, req: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) void {
        const body: wire.ErrorBody = .{ .code = code, .message = message };
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.writeAll("{\"error\":") catch break :blk false;
            std.json.Stringify.value(body, wire.stringify_options, &w) catch break :blk false;
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        const out = if (ok) w.buffered() else "{\"error\":{\"code\":\"internal\",\"message\":\"error\"}}";
        self.respondJson(req, status, out);
    }

    fn respondJson(self: *Server, req: *http.Server.Request, status: http.Status, body: []const u8) void {
        _ = self;
        req.respond(body, .{
            .status = status,
            .keep_alive = false, // one request per connection (R1)
            .extra_headers = &json_content_type,
        }) catch {};
    }
};
