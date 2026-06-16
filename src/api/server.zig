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
const run_control = @import("run_control.zig");
const wire = @import("json_wire.zig");
const scancodes = @import("bios").scancodes;
const png = @import("png.zig");
const stream_mod = @import("stream.zig");
const sf = @import("shared_frame.zig");

/// The three `/api/framebuffer?format=` surfaces (§3.2). `index`/`rgba` stream the raw
/// server-owned buffer (the byte-diffable oracle); `png` is a derived, viewable artifact.
const FramebufferFormat = enum { index, rgba, png };

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

/// Static UI assets, embedded at compile time (`@embedFile` resolves relative to
/// THIS source file, so no `build.zig` change is needed). The servable file set is
/// fixed at compile time → a single self-contained binary, no runtime FS dependency,
/// and zero path-traversal surface. Served same-origin so the page's `fetch('/api/*')`
/// and a future stream socket need no CORS / second port. See `plans/http-static-serving.md`.
const StaticAsset = struct { path: []const u8, bytes: []const u8 };
const static_assets = [_]StaticAsset{
    .{ .path = "/", .bytes = @embedFile("web/index.html") },
    .{ .path = "/index.html", .bytes = @embedFile("web/index.html") },
    .{ .path = "/app.js", .bytes = @embedFile("web/app.js") },
    .{ .path = "/style.css", .bytes = @embedFile("web/style.css") },
};

/// Map a request path's extension to a MIME type (the tiny v1 set). `/` (no
/// extension) and anything unknown fall back to HTML / octet-stream respectively.
fn contentTypeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.eql(u8, path, "/")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    return "application/octet-stream";
}

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

    /// Run-ownership arbitration + the pacer arm flag (stream §5.2/§5.3). CLOCKLESS
    /// (only atomics + a no-timeout mutex), so it is safe in the api determinism
    /// grep-gate. `/api/run/start|stop` flip it; debugger commands auto-disarm via it.
    /// The host run-pacer (`src/host/run_pacer.zig`) holds a pointer to this and polls
    /// `armed`. Server-owned (allocated once at `init`, like `render`).
    run_control: *run_control.RunControl,

    /// A pre-shutdown hook invoked ONCE before the worker `shutdown_worker` sentinel
    /// (shutdown ordering §9.1: stop + join any host producer — the run-pacer — so its
    /// submit cannot race the sentinel). Type-agnostic (opaque ctx + fn) so the server
    /// stays free of any `src/host` dependency. main.zig registers the pacer's join.
    pre_shutdown_ctx: ?*anyopaque = null,
    pre_shutdown_fn: ?*const fn (?*anyopaque) void = null,

    /// The server-owned fixed render buffers for `GET /api/framebuffer` (B1):
    /// allocated ONCE at `init` (~1.5 MiB; too large for the stack/`resp_buf`), reused
    /// for every capture. The worker renders into these via the pure peek; the server
    /// streams the selected buffer as a raw binary body — the pixels NEVER flow through
    /// `resp_buf`/JSON.
    render: *worker_mod.RenderBuffers,

    /// The live-video-stream side (§4/§6/§9.1): the shared latest-frame buffer + the
    /// per-connection stream-thread registry/cap + the frame producer. Server-owned,
    /// allocated ONCE at `init` (a stable pointer the pacer + stream threads hold). All
    /// host-side observation — it reaches the worker ONLY via the gated queue
    /// (`framebuffer_get`), so it charges no cycle and never perturbs ordering.
    shared_frame: *sf.SharedFrame,
    stream_hub: *stream_mod.StreamHub,

    // Per-request scratch (one connection at a time → safe to reuse).
    arena: std.heap.ArenaAllocator,
    resp_buf: [RESPONSE_BUF]u8 = undefined,
    body_buf: [MAX_BODY]u8 = undefined,
    read_scratch: [MAX_BODY]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: Io, ctrl: *Controller, port: u16, recipe: LoadRecipe, mount_dir: Io.Dir) !Server {
        // The server-owned render buffers (~1.5 MiB) are heap-allocated ONCE here
        // (B1: no per-op alloc; too large for the stack/`resp_buf`).
        const render = try gpa.create(worker_mod.RenderBuffers);
        errdefer gpa.destroy(render);
        // The run-control block (clockless arm flag + owner). Heap-allocated ONCE so
        // the host pacer can hold a stable pointer to it across the server's lifetime.
        const rc = try gpa.create(run_control.RunControl);
        rc.* = run_control.RunControl.init(io);
        errdefer gpa.destroy(rc);
        // The shared latest-frame buffer (~308 KiB) + the stream hub: allocated ONCE so
        // the host pacer + stream threads hold stable pointers across the lifetime.
        const frame = try gpa.create(sf.SharedFrame);
        frame.* = sf.SharedFrame.init(io);
        errdefer gpa.destroy(frame);
        const hub = try gpa.create(stream_mod.StreamHub);
        return .{
            .gpa = gpa,
            .io = io,
            .ctrl = ctrl,
            .port = port,
            .recipe = recipe,
            .mount_dir = mount_dir,
            .queue = q.CommandQueue.init(io),
            .arena = std.heap.ArenaAllocator.init(gpa),
            .render = render,
            .run_control = rc,
            .shared_frame = frame,
            .stream_hub = hub,
        };
    }

    /// Finish wiring the stream hub. Called after `init` (when the Server has its FINAL
    /// address) so the hub's `*CommandQueue`/`*RunControl`/`*RenderBuffers`/`*SharedFrame`
    /// point at the stable server-owned instances (the queue lives INLINE in `Server`,
    /// so its address is only stable once the Server is at rest).
    pub fn wireStream(self: *Server) void {
        self.stream_hub.* = stream_mod.StreamHub.init(self.io, &self.queue, self.run_control, self.render, self.shared_frame);
    }

    pub fn deinit(self: *Server) void {
        self.arena.deinit();
        self.gpa.destroy(self.render);
        self.gpa.destroy(self.run_control);
        self.gpa.destroy(self.shared_frame);
        self.gpa.destroy(self.stream_hub);
    }

    /// The stream hub (for the host pacer to drive the frame producer each fps tick).
    pub fn streamHub(self: *Server) *stream_mod.StreamHub {
        return self.stream_hub;
    }

    /// The shared run-control block (for the host pacer to poll the arm flag). Valid
    /// for the server's lifetime. The pacer reaches the machine ONLY via the gated
    /// queue (`queueRef`); it never dereferences the run-controller handle.
    pub fn runControl(self: *Server) *run_control.RunControl {
        return self.run_control;
    }

    /// The command queue (for the host pacer to submit `run_slice` via the submit-gate).
    pub fn queueRef(self: *Server) *q.CommandQueue {
        return &self.queue;
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
        // Wire the stream hub now that the Server is at its final address (its `&self.queue`
        // pointer is stable). Done in `bind` — BEFORE the pacer starts or any client
        // connects — so `produceFrame`/`hasClients` never read an uninitialized hub.
        self.wireStream();
        const w: worker_mod.Worker = .{ .queue = &self.queue, .ctrl = self.ctrl, .mount_dir = self.mount_dir, .io = self.io, .render = self.render };
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
            // A WS upgrade on /api/stream is handed to a dedicated stream thread that
            // OWNS the socket (§9.1) — the accept loop must NOT close it then. Every
            // other request is a short-lived serial control connection (closed here).
            const claimed = self.handleConnection(&stream);
            if (!claimed) stream.close(self.io);
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

    /// Register a pre-shutdown hook (the run-pacer's stop+join). Invoked once before
    /// the worker sentinel (§9.1). main.zig wires the pacer here after `bind`.
    pub fn setPreShutdown(self: *Server, ctx: ?*anyopaque, hook: *const fn (?*anyopaque) void) void {
        self.pre_shutdown_ctx = ctx;
        self.pre_shutdown_fn = hook;
    }

    fn joinWorker(self: *Server) void {
        // §9.1 ordering: stop + join host producers (the run-pacer) FIRST, so no
        // producer can be mid-`submit` when the sentinel goes in.
        if (self.pre_shutdown_fn) |hook| {
            hook(self.pre_shutdown_ctx);
            self.pre_shutdown_fn = null; // run once
        }
        // §9.1 ordering: THEN stop-flag + shutdown sockets + join ALL stream threads,
        // so no stream producer/consumer can be mid-`submit` when the sentinel goes in.
        self.stream_hub.shutdown();
        // Drain the worker with the shutdown sentinel, then join.
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.queue.submit(&ctx);
        if (self.worker_thread) |t| t.join();
        self.worker_thread = null;
    }

    // -----------------------------------------------------------------------
    // Per-connection: one request, keep-alive OFF.
    // -----------------------------------------------------------------------

    /// Handle one accepted connection. Returns true iff the socket was CLAIMED by a
    /// stream thread (a WS upgrade on `/api/stream`) — the accept loop must then NOT
    /// close it (the stream thread owns + closes it). Otherwise returns false (a normal
    /// serial control request, closed by the accept loop).
    fn handleConnection(self: *Server, stream: *net.Stream) bool {
        // Named locals that OUTLIVE the http.Server (return-by-value lifetime rule).
        var rbuf: [HTTP_HEADER_MAX]u8 = undefined;
        var wbuf: [WRITE_BUF]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        var sw = stream.writer(self.io, &wbuf);
        var hs = http.Server.init(&sr.interface, &sw.interface);

        var request = hs.receiveHead() catch return false; // malformed/oversized → drop

        // WS-upgrade path (§6.1): a `GET /api/stream` with the Upgrade headers is handed
        // to a dedicated stream thread that owns the socket. `upgradeRequested` does not
        // invalidate `head`, so the target check below is safe.
        if (isStreamUpgrade(&request)) |key| {
            // The handshake's 101 is written on THIS frame's `sw` (shared); the stream
            // thread then builds its own Reader/Writer over the same socket (the
            // post-handshake protocol is raw WS frames). We must capture the key into the
            // request frame; `respondWebSocket` reads it immediately, before any body
            // reader invalidates head strings.
            if (self.stream_hub.upgrade(&request, stream.*, key)) return true; // claimed
            return false; // rejected (503) — handler wrote the error; loop closes socket
        }

        self.serveRequest(&request);
        return false;
    }

    /// Detect a WebSocket upgrade for `GET /api/stream`. Returns the `Sec-WebSocket-Key`
    /// when it is a valid WS upgrade on the stream path, else null. A `GET /api/stream`
    /// WITHOUT the upgrade headers falls through to the normal dispatch (a sensible 426/
    /// error), per the test plan.
    fn isStreamUpgrade(request: *const http.Server.Request) ?[]const u8 {
        const target = request.head.target;
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |i| target[0..i] else target;
        if (!std.mem.eql(u8, path, "/api/stream")) return null;
        return switch (request.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key, // null key → invalid; caller treats as none
            else => null,
        };
    }

    /// Handle exactly one HTTP request over an already-constructed `http.Server`.
    /// Used by the in-process test (over in-memory reader/writer streams, no real
    /// socket); the real accept path calls `serveRequest` directly after `receiveHead`.
    pub fn serveOne(self: *Server, hs: *http.Server) void {
        var request = hs.receiveHead() catch return; // malformed/oversized head → drop
        self.serveRequest(&request);
    }

    /// The shared request body: capture route + content-type, read the body, dispatch.
    fn serveRequest(self: *Server, request: *http.Server.Request) void {
        // CAPTURE route + content-type BEFORE taking the body reader (it invalidates
        // Head strings). We copy into fixed locals.
        var target_buf: [1024]u8 = undefined;
        const target_src = request.head.target;
        if (target_src.len > target_buf.len) {
            self.respondError(request, .payload_too_large, "payload_too_large", "request target too long");
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
            self.respondError(request, .payload_too_large, "payload_too_large", "request body too large");
            return;
        }

        // Read the body (now that route+ct are captured). The body reader uses
        // `read_scratch` as its working buffer; we copy out into `body_buf` (a
        // DISTINCT buffer — they must not alias, else @memcpy panics).
        var body: []const u8 = &.{};
        if (content_length > 0) {
            const reader = request.readerExpectNone(self.read_scratch[0..]);
            const got = reader.readSliceShort(self.body_buf[0..@intCast(content_length)]) catch {
                self.respondError(request, .bad_request, "bad_request", "failed to read request body");
                return;
            };
            body = self.body_buf[0..got];
        }

        self.dispatch(request, method, target, body, is_json);
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
        if (std.mem.eql(u8, path, "/api/console")) {
            if (method != .GET) return self.methodNotAllowed(req);
            // Side-effect-free read of the guest's accumulated CON output (what the
            // program has printed). No clear-on-read — a read never perturbs state.
            return self.submitAndRespond(req, .console_get);
        }
        if (std.mem.eql(u8, path, "/api/screen")) {
            if (method != .GET) return self.methodNotAllowed(req);
            // Side-effect-free read of the VGA text page (B8000/B0000 cell grid).
            // `?attrs=1` is parsed server-side (Finding 5): the command stays void;
            // the flag only decides whether the JSON carries the attribute array.
            const want_attrs = (self.queryU32(query, "attrs") orelse 0) != 0;
            return self.submitAndRespondScreen(req, want_attrs);
        }
        if (std.mem.eql(u8, path, "/api/framebuffer")) {
            if (method != .GET) return self.methodNotAllowed(req);
            // Pure rasterizer peek of the current VGA mode (B1). `?format=index|rgba`
            // (default index) selects which server-owned buffer to stream as a raw
            // binary body; the descriptor goes in `X-Frame-*` headers. No JSON for the
            // pixels — a frame is 64 KiB..1.2 MiB and must NOT route through resp_buf.
            // `?format=index` (default) | `rgba` | `png`. The first two stream the raw
            // server-owned buffer; `png` re-encodes that same peek host-side (§3.2).
            const fmt: FramebufferFormat = blk: {
                const f = queryValue(query, "format") orelse break :blk .index;
                if (std.mem.eql(u8, f, "rgba")) break :blk .rgba;
                if (std.mem.eql(u8, f, "png")) break :blk .png;
                break :blk .index;
            };
            return self.submitAndRespondFramebuffer(req, fmt);
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

        // --- paced free-run control (stream §5.2) ---
        // Placed BEFORE the `/api/run` exact-match (eql) so the longer paths resolve
        // first; all are clockless (they only flip/read the atomic RunControl).
        if (std.mem.eql(u8, path, "/api/run/start")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleRunStart(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/run/stop")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleRunStop(req);
        }
        if (std.mem.eql(u8, path, "/api/run/status")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleRunStatus(req);
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
            return self.submitDebuggerAndRespond(req, .step);
        }
        if (std.mem.eql(u8, path, "/api/step-n")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.handleStepN(req, body, is_json);
        }
        if (std.mem.eql(u8, path, "/api/step-over")) {
            if (method != .POST) return self.methodNotAllowed(req);
            return self.submitDebuggerAndRespond(req, .step_over);
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
        if (std.mem.eql(u8, path, "/api/mem/search")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleMemSearch(req, query);
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

        // --- live video stream (§6) ---
        // The WS UPGRADE is intercepted in `handleConnection` BEFORE dispatch (it needs
        // the raw socket to hand to a stream thread). Reaching here means a plain
        // `GET /api/stream` WITHOUT the Upgrade headers (or a non-GET) — a sensible 426.
        if (std.mem.eql(u8, path, "/api/stream")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.respondError(req, .upgrade_required, "upgrade_required", "GET /api/stream requires a WebSocket upgrade");
        }

        // --- device / chipset / A20 state reader ---
        if (std.mem.eql(u8, path, "/api/devices")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleDevices(req, query);
        }
        if (std.mem.startsWith(u8, path, "/api/device/")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleDevice(req, path["/api/device/".len..], query);
        }
        if (std.mem.eql(u8, path, "/api/io")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleIoShadow(req, query);
        }

        // --- disassembly ---
        if (std.mem.eql(u8, path, "/api/disasm")) {
            if (method != .GET) return self.methodNotAllowed(req);
            return self.handleDisasm(req, query);
        }

        // --- static UI assets (same-origin homepage) ---
        // Slotted AFTER every `/api/*` route and BEFORE the 404 catch-all so a
        // static path can never shadow an API route. Off-worker, no command
        // submitted, cycle-neutral — exactly like `/api/health`.
        for (static_assets) |asset| {
            if (std.mem.eql(u8, path, asset.path)) return self.serveStatic(req, method, path, asset.bytes);
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
        self.submitDebuggerAndRespond(req, .{ .run = .{ .cycle_cap = cap } });
    }

    fn handleRunToCycle(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToCycleReq, body) orelse return self.badJson(req);
        self.submitDebuggerAndRespond(req, .{ .run_to_cycle = .{ .cycle = r.cycle } });
    }

    fn handleRunToAddr(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToAddrReq, body) orelse return self.badJson(req);
        self.submitDebuggerAndRespond(req, .{ .run_to_address = .{ .linear = r.linear } });
    }

    fn handleStepN(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.StepNReq, body) orelse return self.badJson(req);
        self.submitDebuggerAndRespond(req, .{ .step_n = .{ .n = r.n } });
    }

    // -----------------------------------------------------------------------
    // Paced free-run control (stream §5.2). CLOCKLESS handlers: they only flip/read
    // the atomic `RunControl`; the wall clock lives in src/host/run_pacer.zig (§5.1a).
    // -----------------------------------------------------------------------

    /// `POST /api/run/start {slice_cycles?, fps?}` — arm the pacer (owner=paced).
    /// 409 if a debugger run is in flight (owner==debugger). Idempotent: re-arming
    /// while already paced is `{"ok":true,...}`. Body optional → keep current tuning.
    fn handleRunStart(self: *Server, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        var slice_cycles: u64 = 0; // 0 => keep current
        var fps: u32 = 0;
        if (body.len > 0) {
            const r = self.parseBody(wire.RunStartReq, body) orelse return self.badJson(req);
            slice_cycles = r.slice_cycles orelse 0;
            fps = r.fps orelse 0;
        }
        if (!self.run_control.start(slice_cycles, fps)) {
            return self.respondError(req, .conflict, "run_in_flight", "a debugger run is in flight; cannot start the paced run");
        }
        self.respondRunStatus(req);
    }

    /// `POST /api/run/stop` — disarm the pacer (owner=idle); return the run status
    /// (incl. the stop cycle). A stopped machine stays inspectable/steppable.
    fn handleRunStop(self: *Server, req: *http.Server.Request) void {
        self.run_control.stop();
        self.respondRunStatus(req);
    }

    /// `GET /api/run/status` — `{running, owner, cycle, slice_cycles, fps,
    /// last_stop_reason}`. `cycle` is the machine cycle: fetched via a normal `status`
    /// command (the worker is the sole reader of `cpu.st.cycles`; we never read it
    /// off-worker). The rest come from the clockless RunControl atomics.
    fn handleRunStatus(self: *Server, req: *http.Server.Request) void {
        self.respondRunStatus(req);
    }

    fn respondRunStatus(self: *Server, req: *http.Server.Request) void {
        // Fetch the live machine cycle via the worker (off-worker reads are banned).
        var ctx: q.RequestCtx = .{ .cmd = .status };
        const resp = self.queue.submit(&ctx);
        const cycle: u64 = switch (resp) {
            .status => |st| st.cycles,
            else => self.run_control.lastCycle(),
        };
        const rc = self.run_control;
        const owner = rc.getOwner();
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.print(
                "{{\"running\":{s},\"owner\":\"{s}\",\"cycle\":{d},\"slice_cycles\":{d},\"fps\":{d},\"last_stop_reason\":\"{s}\"}}",
                .{
                    if (rc.isArmed()) "true" else "false",
                    @tagName(owner),
                    cycle,
                    rc.sliceCycles(),
                    rc.getFps(),
                    @tagName(rc.lastStop()),
                },
            ) catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
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

    /// `GET /api/mem/search?pattern=<hex>|ascii=<str>&start&len&max` — find a byte
    /// needle in the guest RAM slab (side-effect-free, on the worker, cycle-neutral).
    /// Exactly one of `pattern` (hex) / `ascii` (text, percent-decoded) is required.
    fn handleMemSearch(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const start = self.queryU32(query, "start") orelse 0;
        const len = self.queryU32(query, "len") orelse 0; // 0 => to slab end (worker)
        const max_q = self.queryU32(query, "max") orelse 0; // 0 => MAX_SEARCH_HITS (worker)
        if (max_q > std.math.maxInt(u16)) return self.respondError(req, .bad_request, "out_of_range", "max too large");

        const pat = queryValue(query, "pattern");
        const asc = queryValue(query, "ascii");
        // Exactly one of pattern/ascii.
        if ((pat == null) == (asc == null)) {
            return self.respondError(req, .bad_request, "bad_request", "specify exactly one of pattern/ascii");
        }

        var ctx: q.RequestCtx = .{ .cmd = undefined };
        const needle: []const u8 = blk: {
            if (pat) |p| {
                const d = wire.hexDecode(ctx.scratch[0..], p) catch return self.respondError(req, .bad_request, "bad_request", "invalid hex in pattern");
                break :blk d;
            }
            // ascii: percent-decode the literal text into scratch.
            const d = percentDecode(ctx.scratch[0..], asc.?) orelse return self.respondError(req, .bad_request, "bad_request", "malformed percent-encoding in ascii");
            break :blk d;
        };
        if (needle.len == 0) return self.respondError(req, .bad_request, "bad_request", "empty search pattern");
        if (needle.len > q.MAX_SEARCH_NEEDLE) return self.respondError(req, .bad_request, "out_of_range", "needle too long");

        ctx.cmd = .{ .mem_search = .{
            .start = start,
            .len = len,
            .needle_len = @intCast(needle.len),
            .max = @intCast(max_q),
        } };
        const resp = self.queue.submit(&ctx);
        switch (resp) {
            // `ctx` (hence the decoded needle in scratch) is still owned by us here —
            // submit() blocks until the worker is done — so the `pattern` echo is intact.
            .search => |sr| self.respondSearch(req, sr, ctx.scratch[0..sr.needle_len]),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected search response"),
        }
    }

    /// Serialize a search result: `{"pattern","needle_len","start","len","count",
    /// "truncated","matches":[{"phys","seg","off"},...]}`. `pattern` echoes the
    /// searched needle as lowercase hex (both modes). `seg`/`off` are the canonical
    /// real-mode decomposition (`seg=phys>>4, off=phys&0xF`) — pure arithmetic.
    fn respondSearch(self: *Server, req: *http.Server.Request, sr: q.SearchResult, needle: []const u8) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.writeAll("{\"pattern\":\"") catch break :blk false;
            for (needle) |b| {
                w.writeByte("0123456789abcdef"[b >> 4]) catch break :blk false;
                w.writeByte("0123456789abcdef"[b & 0x0F]) catch break :blk false;
            }
            w.print("\",\"needle_len\":{d},\"start\":{d},\"len\":{d},\"count\":{d},\"truncated\":{s},\"matches\":[", .{
                sr.needle_len, sr.start, sr.len, sr.count, if (sr.truncated) "true" else "false",
            }) catch break :blk false;
            for (sr.hits[0..sr.count], 0..) |phys, i| {
                if (i != 0) w.writeAll(",") catch break :blk false;
                w.print("{{\"phys\":{d},\"seg\":{d},\"off\":{d}}}", .{ phys, phys >> 4, phys & 0xF }) catch break :blk false;
            }
            w.writeAll("]}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Percent-decode a query value into `dst`, returning the decoded slice (a
    /// prefix of `dst`) or null on a malformed `%XX`. `+` is left literal (query
    /// values here are not form-encoded). Used for the `ascii` search needle.
    fn percentDecode(dst: []u8, src: []const u8) ?[]u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < src.len) {
            if (src[i] == '%') {
                if (i + 2 >= src.len) return null;
                const hi = std.fmt.charToDigit(src[i + 1], 16) catch return null;
                const lo = std.fmt.charToDigit(src[i + 2], 16) catch return null;
                if (n >= dst.len) return null;
                dst[n] = @as(u8, hi) << 4 | lo;
                n += 1;
                i += 3;
            } else {
                if (n >= dst.len) return null;
                dst[n] = src[i];
                n += 1;
                i += 1;
            }
        }
        return dst[0..n];
    }

    fn handleStack(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const count = self.queryU32(query, "count") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid count");
        if (count > std.math.maxInt(u16)) return self.respondError(req, .bad_request, "out_of_range", "count too large");
        self.submitAndRespond(req, .{ .stack_get = .{ .count = @intCast(count) } });
    }

    /// `GET /api/disasm` — disassemble a window of instructions. Origin precedence:
    ///   - `?linear=N`           → linear (physical) address, no segment context
    ///   - `?seg=N[&off=N]`      → real-mode `seg:off` (linear = seg*16 + off)
    ///   - (no linear, no seg)   → the current CS:EIP (live CPU state)
    /// `?count=N` (default 16, ≤ MAX_DISASM_INSNS). Integers accept decimal or `0x`
    /// hex. Pure peek on the worker — cycle-neutral, never perturbs guest state.
    fn handleDisasm(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const count: u16 = blk: {
            const v = queryValue(query, "count") orelse break :blk 16;
            const n = std.fmt.parseInt(u32, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid count");
            if (n == 0 or n > debug.MAX_DISASM_INSNS) return self.respondError(req, .bad_request, "out_of_range", "count must be 1..64");
            break :blk @intCast(n);
        };
        const origin: debug.DisasmOrigin = orig: {
            if (queryValue(query, "linear")) |v| {
                const lin = std.fmt.parseInt(u32, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid linear");
                break :orig .{ .linear = lin };
            }
            if (queryValue(query, "seg")) |v| {
                const seg = std.fmt.parseInt(u16, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid seg (numeric selector)");
                const off: u32 = if (queryValue(query, "off")) |o|
                    (std.fmt.parseInt(u32, o, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid off"))
                else
                    0;
                break :orig .{ .seg_off = .{ .seg = seg, .off = off } };
            }
            break :orig .cs_eip;
        };
        self.submitAndRespond(req, .{ .disasm = .{ .origin = origin, .count = count } });
    }

    /// `GET /api/devices[?palette=1]` — the grouped chipset/A20/device snapshot.
    /// `void` command; `?palette=1` only widens the JSON (the worker always fills
    /// the DAC palette, the server nulls it when the flag is absent). Pure peek.
    fn handleDevices(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const want_palette = (self.queryU32(query, "palette") orelse 0) != 0;
        var ctx: q.RequestCtx = .{ .cmd = .devices_get };
        const resp = self.queue.submit(&ctx);
        switch (resp) {
            .devices => |d| self.respondDevices(req, d, want_palette),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected devices response"),
        }
    }

    /// `GET /api/device/<name>` — a single device group (a20|pic|pit|vga|kbc|
    /// speaker|ems). Same data as the matching key in `/api/devices`; unknown → 404.
    fn handleDevice(self: *Server, req: *http.Server.Request, name: []const u8, query: []const u8) void {
        const want_palette = (self.queryU32(query, "palette") orelse 0) != 0;
        var ctx: q.RequestCtx = .{ .cmd = .devices_get };
        const resp = self.queue.submit(&ctx);
        const d = switch (resp) {
            .devices => |d| d,
            .err => |code| return self.respondErrCode(req, code),
            else => return self.respondError(req, .service_unavailable, "internal", "unexpected devices response"),
        };
        var snap = d;
        if (!want_palette) snap.vga.palette = null;
        if (std.mem.eql(u8, name, "a20")) return self.respondValue(req, .ok, snap.a20);
        if (std.mem.eql(u8, name, "pic")) return self.respondValue(req, .ok, snap.pic);
        if (std.mem.eql(u8, name, "pit")) return self.respondValue(req, .ok, snap.pit);
        if (std.mem.eql(u8, name, "vga")) return self.respondValue(req, .ok, snap.vga);
        if (std.mem.eql(u8, name, "kbc")) return self.respondValue(req, .ok, snap.kbc);
        if (std.mem.eql(u8, name, "speaker")) return self.respondValue(req, .ok, snap.speaker);
        if (std.mem.eql(u8, name, "ems")) return self.respondValue(req, .ok, snap.ems);
        return self.respondError(req, .not_found, "not_found", "unknown device group");
    }

    /// `GET /api/io?port=N` — the non-mutating shadow of one I/O port.
    fn handleIoShadow(self: *Server, req: *http.Server.Request, query: []const u8) void {
        const v = queryValue(query, "port") orelse return self.respondError(req, .bad_request, "bad_request", "missing port");
        const port = std.fmt.parseInt(u16, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid port");
        self.submitAndRespond(req, .{ .io_shadow = .{ .port = port } });
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

    /// Submit a DEBUGGER run/step command (the bounded `run`/`run-to-cycle`/
    /// `run-to-address`/`step*`) — AUTO-DISARMING the pacer for its duration (§5.3) so
    /// it lands deterministically without interleaving pacer slices. `beginDebugger`
    /// clears the arm flag + sets owner=debugger; the submit-gate then makes this
    /// command wait for any in-flight pacer slice at the queue and run NEXT;
    /// `endDebugger` restores the prior owner (re-arm the pacer iff it owned the run).
    /// Determinism: this is byte-identical to the same command with no pacer — it is
    /// the SAME bounded run-until-event on the SAME single worker; the pacer only
    /// changes wall-time pacing, never which cycles run.
    fn submitDebuggerAndRespond(self: *Server, req: *http.Server.Request, cmd: q.Command) void {
        const restore = self.run_control.beginDebugger();
        defer self.run_control.endDebugger(restore);
        var ctx: q.RequestCtx = .{ .cmd = cmd };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn submitCtxAndRespond(self: *Server, req: *http.Server.Request, ctx: *q.RequestCtx) void {
        const resp = self.queue.submit(ctx);
        self.serializeResponse(req, resp);
    }

    /// Submit the `void` screen command and serialize with the server-parsed
    /// `?attrs` flag (the flag is NOT part of the command — Finding 5).
    fn submitAndRespondScreen(self: *Server, req: *http.Server.Request, want_attrs: bool) void {
        var ctx: q.RequestCtx = .{ .cmd = .screen_get };
        const resp = self.queue.submit(&ctx);
        switch (resp) {
            .screen => |sr| self.respondScreen(req, sr, want_attrs),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected screen response"),
        }
    }

    /// Submit the `framebuffer_get` command (the worker renders into the SERVER-OWNED
    /// `self.render` buffers) and stream the selected buffer as a raw binary body (B1).
    /// The pixels are read straight from `self.render` to the socket — never through
    /// `resp_buf`/JSON. The descriptor (mode/width/height/lens/double-scan) goes in
    /// `X-Frame-*` response headers. A mode with no faithful rasterizer is a 501 (the
    /// honest deferral — never a fabricated frame).
    fn submitAndRespondFramebuffer(self: *Server, req: *http.Server.Request, fmt: FramebufferFormat) void {
        var ctx: q.RequestCtx = .{ .cmd = .framebuffer_get };
        const resp = self.queue.submit(&ctx);
        const fr = switch (resp) {
            .framebuffer => |f| f,
            .err => |code| return self.respondErrCode(req, code),
            else => return self.respondError(req, .service_unavailable, "internal", "unexpected framebuffer response"),
        };
        if (!fr.supported) {
            return self.respondError(req, .not_implemented, "not_implemented", "no faithful rasterizer for the current video mode");
        }

        // Build the body + content-type + format-tag. The PNG path re-encodes the same
        // peek host-side over the server-owned snapshot (off-worker, cycle-neutral §3.6);
        // index/rgba stream the raw buffer. Pixels never flow through resp_buf/JSON (B1).
        var content_type: []const u8 = "application/octet-stream";
        var fmt_str: []const u8 = "index";
        const body: []const u8 = switch (fmt) {
            .index => self.render.index[0..fr.index_len],
            .rgba => blk: {
                fmt_str = "rgba";
                break :blk self.render.rgba[0..fr.rgba_len];
            },
            .png => blk: {
                content_type = "image/png";
                break :blk self.encodePng(req, fr) orelse return; // error response done inside
            },
        };
        if (fmt == .png) fmt_str = if (fr.palette_present) "png-indexed" else "png-rgb";

        // Descriptor headers (the client reads dims/kind from these). Small fixed scratch.
        var wbuf: [8]u8 = undefined;
        var hbuf: [8]u8 = undefined;
        var kbuf: [8]u8 = undefined;
        const w_str = std.fmt.bufPrint(&wbuf, "{d}", .{fr.width}) catch "0";
        const h_str = std.fmt.bufPrint(&hbuf, "{d}", .{fr.height}) catch "0";
        const kind_str = std.fmt.bufPrint(&kbuf, "{d}", .{@intFromEnum(fr.kind)}) catch "0";

        const headers = [_]http.Header{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "x-frame-width", .value = w_str },
            .{ .name = "x-frame-height", .value = h_str },
            .{ .name = "x-frame-kind", .value = kind_str },
            .{ .name = "x-frame-format", .value = fmt_str },
        };
        req.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &headers,
        }) catch {};
    }

    /// Encode the just-captured frame (in the server-owned `self.render` snapshot) into
    /// the server-owned `png_out` slab and return the PNG bytes. Indexed PNG when the
    /// mode is paletted (the PLTE comes from the worker-filled palette slab, with
    /// `pel_mask` applied to the indices, §3.3); truecolor RGB otherwise. On an encode
    /// overflow it responds 500 and returns null (the caller stops). This runs on the
    /// listener thread over an immutable snapshot — it reads NO machine state, charges
    /// NO cycle (§3.1/§5).
    fn encodePng(self: *Server, req: *http.Server.Request, fr: q.FramebufferResult) ?[]const u8 {
        const rb = self.render;
        var out: std.Io.Writer = .fixed(rb.png_out[0..]);
        if (fr.palette_present) {
            // Apply pel_mask to each index in place so the PLTE lookup matches the RGBA
            // peek (`indexToRgba`: `dac_rgb[idx & mask]`). 0xFF => a no-op copy.
            const idx = rb.index[0..fr.index_len];
            if (fr.pel_mask != 0xFF) {
                for (idx) |*p| p.* &= fr.pel_mask;
            }
            const palette: *const [256]png.Rgb = @ptrCast(&rb.palette);
            png.encodeIndexed(&out, &rb.png_work, fr.width, fr.height, idx, palette) catch {
                self.respondError(req, .service_unavailable, "internal", "PNG encode overflow");
                return null;
            };
        } else {
            png.encodeRgb(&out, &rb.png_work, fr.width, fr.height, rb.rgba[0..fr.rgba_len]) catch {
                self.respondError(req, .service_unavailable, "internal", "PNG encode overflow");
                return null;
            };
        }
        return out.buffered();
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
            .console => |cr| self.respondConsole(req, cr),
            // Direct `.screen` responses default to no attributes; the dedicated
            // `/api/screen` route uses `submitAndRespondScreen` to pass `?attrs`.
            .screen => |sr| self.respondScreen(req, sr, false),
            // The framebuffer is streamed by the dedicated `submitAndRespondFramebuffer`
            // (raw binary, B1) — it never reaches this generic JSON serializer. If it
            // ever does, report it honestly rather than emitting a wrong body.
            .framebuffer => self.respondError(req, .service_unavailable, "internal", "framebuffer must be streamed via /api/framebuffer"),
            .regions => |rg| self.respondRegions(req, rg),
            .disasm => |dr| self.respondDisasm(req, dr),
            // Direct `.devices` responses default to no palette; the dedicated
            // `/api/devices` route passes `?palette` via `handleDevices`.
            .devices => |d| self.respondDevices(req, d, false),
            .io_shadow => |io| self.respondIoShadow(req, io),
            // `/api/mem/search` serializes directly in `handleMemSearch` (it needs
            // the listener-owned needle for the `pattern` echo); this arm only
            // exists for switch-exhaustiveness and would lack that echo.
            .search => |sr| self.respondSearch(req, sr, &.{}),
        }
    }

    /// Serialize the grouped device snapshot. The whole POD is JSON-Stringify-able
    /// (enums → strings, fixed arrays → arrays); the only server-side shaping is
    /// nulling the bulky DAC palette unless `?palette=1` was passed.
    fn respondDevices(self: *Server, req: *http.Server.Request, d: debug.DevicesSnapshot, want_palette: bool) void {
        var snap = d;
        if (!want_palette) snap.vga.palette = null;
        self.respondValue(req, .ok, snap);
    }

    /// `{"port":N,"value":"0xNN"|null,"shadow":true,"note":"..."}` — the I/O-port
    /// shadow. `shadow:true` + the `/api/io` name (not `/api/in`) make explicit this
    /// is a non-mutating VIEW, never a live read (a live `in` would advance the DAC
    /// index / pop the 8042 FIFO / flip the AC flip-flop).
    fn respondIoShadow(self: *Server, req: *http.Server.Request, io: debug.IoShadow) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            if (io.value) |v| {
                w.print("{{\"port\":{d},\"value\":\"0x{x:0>2}\",\"shadow\":true,", .{ io.port, v }) catch break :blk false;
            } else {
                w.print("{{\"port\":{d},\"value\":null,\"shadow\":true,", .{io.port}) catch break :blk false;
            }
            w.writeAll("\"note\":\"non-mutating view; a live IN may differ for stateful ports (DAC index advance, FIFO pop, AC flip-flop)\"}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
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

    fn respondConsole(self: *Server, req: *http.Server.Request, cr: q.ConsoleResult) void {
        // {"len":N,"data":"<hex>"} — hex so arbitrary CON bytes (control chars, NULs)
        // survive JSON intact (mirrors the /api/mem encoding).
        var hex_buf: [q.MAX_CONSOLE * 2]u8 = undefined;
        const hex = wire.hexEncode(&hex_buf, cr.bytes[0..cr.len]) catch return self.respondError(req, .service_unavailable, "internal", "encode failed");
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        w.print("{{\"len\":{d},\"data\":\"{s}\"}}", .{ cr.len, hex }) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Serialize a text-screen grid (§4.1). `text` = `rows` rows joined by '\n',
    /// each row = the `cols` cell CHARACTERS (cell byte0), JSON-escaped (raw CP437
    /// bytes survive; the consumer decodes glyphs). `attrs` (the cell byte1 array,
    /// lowercase hex) is emitted only when `want_attrs` is set (D-TM4); otherwise
    /// the field is null. Cursor/mode/cols/rows come straight from the BDA scalars.
    fn respondScreen(self: *Server, req: *http.Server.Request, sr: q.ScreenResult, want_attrs: bool) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const cols = sr.cols;
        const rows = sr.rows;
        const ok = blk: {
            w.print("{{\"cols\":{d},\"rows\":{d},\"mode\":{d},\"cursor\":{{\"row\":{d},\"col\":{d},\"page\":{d}}},\"text\":", .{
                cols, rows, sr.mode, sr.cursor_row, sr.cursor_col, sr.active_page,
            }) catch break :blk false;
            // Build the text grid: extract each cell's char byte (even indices),
            // newline-separate the rows, then JSON-escape the whole string.
            var text_buf: [q.MAX_SCREEN_CELLS]u8 = undefined; // chars + newlines fit
            var tlen: usize = 0;
            var r: u16 = 0;
            while (r < rows) : (r += 1) {
                var c: u16 = 0;
                while (c < cols) : (c += 1) {
                    const idx = (@as(usize, r) * cols + c) * 2;
                    if (idx < sr.len) {
                        text_buf[tlen] = sr.cells[idx];
                        tlen += 1;
                    }
                }
                if (r + 1 < rows) {
                    text_buf[tlen] = '\n';
                    tlen += 1;
                }
            }
            std.json.Stringify.value(text_buf[0..tlen], wire.stringify_options, &w) catch break :blk false;
            if (want_attrs) {
                // Parallel attribute array as lowercase hex (cell byte1, in row-major
                // order — cols*rows bytes).
                w.writeAll(",\"attrs\":\"") catch break :blk false;
                var i: usize = 1;
                while (i < sr.len) : (i += 2) {
                    const hi = "0123456789abcdef"[sr.cells[i] >> 4];
                    const lo = "0123456789abcdef"[sr.cells[i] & 0x0F];
                    w.writeByte(hi) catch break :blk false;
                    w.writeByte(lo) catch break :blk false;
                }
                w.writeAll("\"") catch break :blk false;
            } else {
                w.writeAll(",\"attrs\":null") catch break :blk false;
            }
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Serialize a disassembly window:
    /// `{"count":N,"instructions":[{"linear":N,"seg":N|null,"off":N|null,
    ///   "bytes":"<hex>","length":N,"text":"..."},...]}`
    /// `seg`/`off` are null for the `?linear=` origin (no segment context).
    fn respondDisasm(self: *Server, req: *http.Server.Request, dr: debug.DisasmResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            w.print("{{\"count\":{d},\"instructions\":[", .{dr.count}) catch break :blk false;
            for (dr.items[0..dr.count], 0..) |insn, i| {
                if (i != 0) w.writeAll(",") catch break :blk false;
                w.print("{{\"linear\":{d},", .{insn.linear}) catch break :blk false;
                if (insn.has_seg) {
                    w.print("\"seg\":{d},\"off\":{d},", .{ insn.seg, insn.off }) catch break :blk false;
                } else {
                    w.writeAll("\"seg\":null,\"off\":null,") catch break :blk false;
                }
                w.writeAll("\"bytes\":\"") catch break :blk false;
                for (insn.bytes[0..insn.len]) |b| {
                    w.writeByte("0123456789abcdef"[b >> 4]) catch break :blk false;
                    w.writeByte("0123456789abcdef"[b & 0x0F]) catch break :blk false;
                }
                w.print("\",\"length\":{d},\"text\":", .{insn.len}) catch break :blk false;
                std.json.Stringify.value(insn.text[0..insn.text_len], wire.stringify_options, &w) catch break :blk false;
                w.writeAll("}") catch break :blk false;
            }
            w.writeAll("]}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondError(req, .service_unavailable, "internal", "response too large");
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

    /// Serve one embedded static asset (the same-origin UI). GET/HEAD only —
    /// any other method is a 405 (reusing `methodNotAllowed`). The content-type
    /// comes from the path extension; `Cache-Control: no-cache` keeps a rebuilt
    /// binary's assets fresh during dev. `req.respond` sets content-length from the
    /// slice and OMITS the body for HEAD automatically. No command is submitted —
    /// off-worker and cycle-neutral, like `/api/health`.
    fn serveStatic(self: *Server, req: *http.Server.Request, m: http.Method, path: []const u8, body: []const u8) void {
        if (m != .GET and m != .HEAD) return self.methodNotAllowed(req);
        const headers = [_]http.Header{
            .{ .name = "content-type", .value = contentTypeFor(path) },
            .{ .name = "cache-control", .value = "no-cache" },
        };
        req.respond(body, .{
            .status = .ok,
            .keep_alive = false, // one request per connection (R1)
            .extra_headers = &headers,
        }) catch {};
    }
};
