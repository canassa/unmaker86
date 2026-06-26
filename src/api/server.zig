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
//! never which guest instructions ran or in what order. Connections are served
//! CONCURRENTLY (thread-per-connection, multi-machine plan §5, Phase 2) with
//! per-connection scratch, but a guest still advances ONLY inside the worker via the
//! submit-gated queue — so cross-connection scheduling changes only wall-clock
//! latency, never the instruction stream. Keep-alive stays OFF → one request per
//! connection; the submit-gate (queue.zig:387) serializes the multiple connection-
//! thread producers onto the one session queue and enforces one-command-in-flight by
//! construction (the queue's `submit()` also asserts the ring empty).

const std = @import("std");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const q = @import("queue.zig");
const worker_mod = @import("worker.zig");
const run_control = @import("run_control.zig");
const live_mouse_mod = @import("live_mouse.zig");
const wire = @import("json_wire.zig");
const scancodes = @import("bios").scancodes;
const timing = @import("timing"); // PIT_TICK_RATE / MAX_MULT for the CPU-speed knob (Phase 3)
const png = @import("png.zig");
const stream_mod = @import("stream.zig");
const mcp = @import("mcp.zig"); // the JSON-RPC 2.0 envelope codec (M3, mcp-plan.md §2)
const mcp_tools = @import("mcp_tools.zig"); // the MCP tool catalog + args→Command mapping (M3 §2/§4)
const session_mod = @import("session.zig"); // the per-session state bundle (multi-machine plan §3.2/§4.1, Phase 1)
const registry_mod = @import("session_registry.zig"); // the N-session registry (multi-machine plan §4, Phase 3)

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

/// Worst-case size of a per-`Conn` CAPTURE buffer (Finding 2): the largest raw frame
/// payload a capture path copies out from under `session.lock` before the unbounded
/// socket write. The capture paths snapshot/encode the frame under the lock, COPY the
/// finished bytes here, UNLOCK, then write — so the slow socket write never holds the
/// lock that the pacer's inline `produceFrame` also needs (otherwise a slow capture
/// client freezes the guest). The copied payload is one of: the raw indexed buffer
/// (`RENDER_INDEX_CAP`), the RGBA buffer (`RENDER_RGBA_CAP`), or the encoded PNG slab
/// (`PNG_OUT_CAP`); the screenshot path copies the PNG and base64-streams it from this
/// owned copy AFTER unlock. Sized to the max of the three so ONE buffer serves every
/// path. Lazily heap-allocated per connection on first capture and reused, so only
/// capture-active connections pay and the static `Conn` footprint is unchanged.
const CAPTURE_BUF_CAP: usize = @max(
    worker_mod.PNG_OUT_CAP,
    @max(debug.RENDER_RGBA_CAP, debug.RENDER_INDEX_CAP),
);

/// The optional per-request session selector for the HTTP `/api/*` surface (multi-machine
/// plan §6 option B, Phase 4). A header — NOT a path/query segment — so the 40+ existing
/// `/api/*` routes and every shipped client are untouched: a request with NO `X-Zdos-Session`
/// header still drives the single DEFAULT session (the mandatory back-compat path). A request
/// WITH it routes to the registry-minted session of that id (the same machines MCP `initialize`
/// mints), resolved through the SAME `resolveSession` seam + refcount discipline the `/mcp`
/// `tools/call` path uses. Compared case-insensitively (`std.ascii.eqlIgnoreCase`), mirroring
/// the MCP `mcp-session-id` capture. Distinct from `mcp.SESSION_HEADER` so the two transports
/// stay independently addressable.
const API_SESSION_HEADER = "x-zdos-session";

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

/// The server-held program-load recipe. Re-exported from `session.zig` (it is a
/// per-Session datum, defined there so a `Session` field can name it without a
/// server↔session import cycle). Public surface — `api.zig` and the tests reach it
/// as `server.LoadRecipe`, unchanged.
pub const LoadRecipe = session_mod.LoadRecipe;
const Session = session_mod.Session;
const SessionId = session_mod.SessionId;
const SessionRegistry = registry_mod.SessionRegistry;

/// The global cap on CONCURRENT client connections (multi-machine plan §5.1, Phase 2).
/// Each connection is served on its OWN thread with its OWN ~192 KiB `Conn` scratch;
/// this bounds the thread + memory fan-out (mirrors the per-session stream cap
/// `stream.MAX_CONNS = 4`, generalized to all control connections). At the cap the
/// listener replies 503 and closes — back-pressure, not an unbounded thread explosion
/// (§5.1). The array of `ConnSlot`s IS the cap, so no separate counter is needed.
const MAX_CONNS_TOTAL: usize = 16;

/// One slot in the Server's connection-thread registry (mirrors `stream.Conn`,
/// stream.zig:52). Holds the connection thread's handle, joined on slot reuse or at
/// shutdown — never dropped unjoined. `active` is owned by the Server under `conn_mutex`.
///
/// Unlike stream.zig's LONG-LIVED parked connections, a control connection is short-lived
/// (one request, keep-alive off), so its thread has finished — and CLOSED its own socket —
/// by the time shutdown joins it. We therefore do NOT store/shutdown the socket here:
/// calling `shutdown` on the already-closed fd would hit `BADF`, which `std.Io.Threaded`
/// treats as a non-recoverable programmer bug (a debug-build PANIC, not a catchable
/// error). The only case socket-shutdown would help is a client that opened a connection
/// and never sent a request head (a thread parked in `receiveHead`); that could stall
/// shutdown, but it is a pre-existing limitation — the prior single-threaded loop hung the
/// WHOLE server on such a client — not a Phase-2 regression.
const ConnSlot = struct {
    active: bool = false,
    thread: ?std.Thread = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    port: u16,
    net_server: ?net.Server = null,

    /// The single default `Session` (multi-machine plan §4.1, Phase 1). Holds the
    /// per-machine state that used to be `Server` fields directly — the Controller
    /// pointer, the load recipe + mount dir, the command queue + worker thread, the
    /// clockless `run_control`, the live-mouse record, the render buffers, and the
    /// shared-frame / stream-hub. Held BY VALUE so the inline `queue`'s address is
    /// stable for the worker once the `Server` is at its final address (the worker is
    /// spawned only in `bind`, after that point). The HTTP/MCP handlers reach all of
    /// this through `defaultSession()` (or `self.session.*`); Phase 3 routes `/mcp` through
    /// the `registry` below while `/api/*` and the blank/singleton MCP id stay on THIS one.
    session: Session,

    /// The N-session registry (multi-machine plan §4, Phase 3). Owns the registry-minted
    /// sessions (one per MCP `initialize`), each with its OWN machine + worker. The
    /// DEFAULT session above is NOT in the map — it is process-owned and resolved directly
    /// (blank / singleton id → `defaultSession()`). HTTP `/api/*` stays on the default
    /// session (Phase 4 adds optional HTTP session routing); only `/mcp` routes through the
    /// registry. Constructed in `init`, torn down in `deinit` (joins every minted worker,
    /// leak-free).
    registry: SessionRegistry,

    /// A pre-shutdown hook invoked ONCE before the worker `shutdown_worker` sentinel
    /// (shutdown ordering §9.1: stop + join any host producer — the run-pacer — so its
    /// submit cannot race the sentinel). Type-agnostic (opaque ctx + fn) so the server
    /// stays free of any `src/host` dependency. main.zig registers the pacer's join.
    pre_shutdown_ctx: ?*anyopaque = null,
    pre_shutdown_fn: ?*const fn (?*anyopaque) void = null,

    // -------------------------------------------------------------------
    // Concurrent connection handling (multi-machine plan §5, Phase 2). The accept
    // loop hands each connection to its OWN thread; the per-request scratch moved
    // OFF the Server onto a per-connection `Conn` (defined below this struct), so two
    // concurrent connections never share a response buffer. This fixed registry of
    // thread slots (mirroring stream.zig's per-connection registry) bounds the
    // concurrency and lets shutdown join every connection thread before the worker
    // sentinel goes in.
    // -------------------------------------------------------------------
    /// Guards `conn_slots` (each slot's `active`/`thread`/`socket`). CLOCKLESS
    /// (no-timeout `Io.Mutex`), so it stays inside the `src/api` determinism gate.
    conn_mutex: Io.Mutex = .init,
    /// The fixed connection-thread registry. A free slot is claimed per accepted
    /// connection; when all slots are active the accept loop replies 503 (the cap).
    conn_slots: [MAX_CONNS_TOTAL]ConnSlot = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator, io: Io, ctrl: *Controller, port: u16, recipe: LoadRecipe, mount_dir: Io.Dir) !Server {
        // Stand up the one default session (its own heap blocks + the inline queue).
        // The Session's errdefer chain frees every block on a partial failure, and it
        // captures NO self-address — the stream hub is wired later in `bind`, once the
        // Session sits at its final address inside the at-rest Server.
        // The default session carries the FIXED singleton id (mcp.SESSION_ID), so a client
        // that never `initialize`s — sending a blank or `zdos-mcp-singleton` Mcp-Session-Id
        // — keeps reaching this one machine, exactly as the shipped MCP PoC did.
        const session = try Session.init(gpa, io, SessionId.fromSlice(mcp.SESSION_ID), ctrl, recipe, mount_dir);
        errdefer {
            var s = session;
            s.deinit(gpa);
        }
        // Stand up the N-session registry and pre-size its map to the cap so a mid-flight
        // `initialize` never fails on a map allocation. It carries no host clock/RNG.
        var registry = SessionRegistry.init(gpa, io);
        try registry.prealloc();
        return .{
            .gpa = gpa,
            .io = io,
            .port = port,
            .session = session,
            .registry = registry,
        };
    }

    /// The single default session (multi-machine plan §6, Phase 1): the `/api/*`
    /// routes all drive it, and a blank/absent `Mcp-Session-Id` resolves here. Returns
    /// a stable `*Session` (the Server is at rest before any worker holds these
    /// addresses). Phase 3 replaces this with a registry lookup keyed by `sid`.
    pub fn defaultSession(self: *Server) *Session {
        return &self.session;
    }

    /// Finish wiring the stream hub. Called after `init` (when the Server — and so the
    /// inline Session — has its FINAL address) so the hub's `*CommandQueue`/`*RunControl`/
    /// `*RenderBuffers`/`*SharedFrame` point at the stable session-owned instances (the
    /// queue lives INLINE in the Session, so its address is only stable once at rest).
    pub fn wireStream(self: *Server) void {
        self.session.wireStream(self.io);
    }

    pub fn deinit(self: *Server) void {
        // Tear down every registry-minted session FIRST (stop + join each worker, free its
        // machine + buffers). Safe + leak-free here: `serve()` has already stopped the
        // accept loop and joined all connection threads, so no thread still holds a minted
        // `*Session` (no refcount wait needed). Then free the default session's heap blocks.
        self.registry.deinit();
        self.session.deinit(self.gpa);
    }

    /// The stream hub (for the host pacer to drive the frame producer each fps tick).
    pub fn streamHub(self: *Server) *stream_mod.StreamHub {
        return self.session.stream_hub;
    }

    /// The shared run-control block (for the host pacer to poll the arm flag). Valid
    /// for the server's lifetime. The pacer reaches the machine ONLY via the gated
    /// queue (`queueRef`); it never dereferences the run-controller handle.
    pub fn runControl(self: *Server) *run_control.RunControl {
        return self.session.run_control;
    }

    /// The coalesced live-mouse record (for the host pacer to poll its dirty seq and
    /// submit `input_mouse_fold`). Valid for the server's lifetime; the pacer reaches
    /// the machine ONLY via the gated queue, never through this handle's machine state
    /// (the record IS host-side, so reading its atomic-free fields is done UNDER ITS
    /// MUTEX in `takeFold` on the worker — the pacer just submits the fold command).
    pub fn liveMouse(self: *Server) *live_mouse_mod.LiveMouseState {
        return self.session.live_mouse;
    }

    /// The command queue (for the host pacer to submit `run_slice` via the submit-gate).
    pub fn queueRef(self: *Server) *q.CommandQueue {
        return &self.session.queue;
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
        // Wire the stream hub now that the Server is at its final address (its `&self.session.queue`
        // pointer is stable). Done in `bind` — BEFORE the pacer starts or any client
        // connects — so `produceFrame`/`hasClients` never read an uninitialized hub.
        self.wireStream();
        const w: worker_mod.Worker = .{ .queue = &self.session.queue, .ctrl = self.session.ctrl, .mount_dir = self.session.mount_dir, .io = self.io, .render = self.session.render, .live_mouse = self.session.live_mouse };
        self.session.worker_thread = try std.Thread.spawn(.{}, worker_mod.Worker.run, .{w});

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
            const stream = self.net_server.?.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening => break, // clean shutdown signaled
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            // Hand the connection to its OWN thread (Phase 2, §5.1): a long-running
            // `run` on one connection must never block another connection (or another
            // producer) — §2.2 proved blocking accept/read/write do not serialize across
            // threads on `std.Io.Threaded`. `dispatchConnection` claims a registry slot +
            // spawns the worker-of-the-wire; at the cap it replies 503 inline and closes.
            // Determinism is untouched: the guest still advances ONLY inside the session
            // worker via the submit-gated queue; connection scheduling changes only
            // wall-clock latency (§8).
            self.dispatchConnection(stream);
        }

        // Clean shutdown (§9.1 ordering): the accept loop has stopped. JOIN every
        // in-flight connection thread BEFORE the worker sentinel — a connection thread
        // blocked in `queue.submit` must complete first (the worker is still alive here),
        // so it never submits after the worker is gone. Only then does `joinWorker` stop
        // the pacer + stream threads and drain the worker.
        if (self.net_server) |*s| {
            s.deinit(self.io); // close the listening socket on clean exit
            self.net_server = null;
        }
        self.joinConnections();
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
        self.session.stream_hub.shutdown();
        // Drain the worker with the shutdown sentinel, then join.
        var ctx: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = self.session.queue.submit(&ctx);
        if (self.session.worker_thread) |t| t.join();
        self.session.worker_thread = null;
    }

    // -----------------------------------------------------------------------
    // Per-connection: one request, keep-alive OFF.
    // -----------------------------------------------------------------------

    /// Handle one accepted connection — runs on the connection's OWN thread (spawned by
    /// `dispatchConnection`, entered via `connThreadMain`). Returns true iff the socket
    /// was CLAIMED by a stream thread (a WS upgrade on `/api/stream`) — `connThreadMain`
    /// must then NOT close it (the stream thread owns + closes it). Otherwise returns
    /// false (a control request served with this connection's own `Conn` scratch, closed
    /// by `connThreadMain`). The `rbuf`/`wbuf`/`sr`/`sw` named locals live in THIS frame
    /// for the connection's lifetime (the return-by-value lifetime rule), so they are
    /// already per-connection; Phase 2 adds the per-connection `Conn` for the request
    /// scratch that used to live on the shared `Server`.
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
            if (self.session.stream_hub.upgrade(&request, stream.*, key)) return true; // claimed
            return false; // rejected (503) — handler wrote the error; loop closes socket
        }

        // Per-connection request scratch (§3.4/§5.2): ~192 KiB of JSON/transport work
        // buffers + the per-request arena, owned by THIS connection for its lifetime and
        // freed on close. Heap-allocated (thread-safe gpa, §2.1) to keep the connection
        // thread's stack small. Under concurrency two connections must never share a
        // response buffer — this per-connection ownership is the core of Phase 2.
        const conn = self.gpa.create(Conn) catch return false; // OOM → drop the connection
        defer self.gpa.destroy(conn);
        conn.* = Conn.init(self, self.defaultSession());
        defer conn.deinit();
        conn.serveRequest(&request);
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

    /// Handle exactly one HTTP request over an already-constructed `http.Server`. Used by
    /// the in-process tests (over in-memory reader/writer streams, no real socket). It
    /// builds the SAME per-connection `Conn` scratch the real accept path allocates, so
    /// the tests exercise the Phase-2 per-connection ownership. Stack-allocated here (the
    /// tests are single-threaded; the real accept path heap-allocates one per connection
    /// thread).
    pub fn serveOne(self: *Server, hs: *http.Server) void {
        var request = hs.receiveHead() catch return; // malformed/oversized head → drop
        var conn = Conn.init(self, self.defaultSession());
        defer conn.deinit();
        conn.serveRequest(&request);
    }

    // -----------------------------------------------------------------------
    // Connection-thread registry + dispatch (Phase 2, §5.1). Mirrors the per-
    // connection thread management in stream.zig (claim/release/join a fixed slot
    // array). These run on the LISTENER thread (dispatch/reject) or the connection
    // thread (release); the heavy request work happens on `Conn` (the struct below).
    // -----------------------------------------------------------------------

    /// Args handed to a spawned connection thread (the Server, its slot, the socket).
    const ConnArgs = struct { server: *Server, idx: usize, stream: net.Stream };

    /// Claim a free registry slot for a newly accepted connection. Joins a leftover
    /// finished thread handle on slot reuse, so no OS-thread handle is ever dropped
    /// unjoined across connect/close churn (the stream.zig discipline, stream.zig:163).
    /// Returns null when every slot is active (the cap, §5.1) → the caller replies 503.
    fn claimConnSlot(self: *Server) ?usize {
        self.conn_mutex.lockUncancelable(self.io);
        defer self.conn_mutex.unlock(self.io);
        for (&self.conn_slots, 0..) |*c, i| {
            if (!c.active) {
                if (c.thread) |t| {
                    t.join();
                    c.thread = null;
                }
                c.active = true;
                return i;
            }
        }
        return null;
    }

    /// Release a slot when its connection thread exits. Marks it inactive but LEAVES the
    /// thread handle for the joiner (slot reuse in `claimConnSlot`, or `joinConnections`
    /// at shutdown) — so the handle is joined exactly once, never double-joined.
    fn releaseConnSlot(self: *Server, idx: usize) void {
        self.conn_mutex.lockUncancelable(self.io);
        defer self.conn_mutex.unlock(self.io);
        self.conn_slots[idx].active = false;
    }

    /// Shutdown (§9.1): join every connection thread. Called from `serve` AFTER the accept
    /// loop stops and BEFORE `joinWorker`, so no connection thread can submit to the queue
    /// after the worker sentinel goes in — a connection thread blocked in `queue.submit`
    /// completes first (the worker is still alive here) and returns. Claims the handles
    /// under the lock (nulls them) so a concurrent `releaseConnSlot`/slot-reuse cannot race
    /// the join (no double-join). We deliberately do NOT shut down the sockets (see the
    /// `ConnSlot` doc: a finished control connection already closed its own fd, and
    /// `shutdown` on a closed fd is a `BADF` panic under `std.Io.Threaded`).
    fn joinConnections(self: *Server) void {
        var threads: [MAX_CONNS_TOTAL]?std.Thread = @splat(null);
        self.conn_mutex.lockUncancelable(self.io);
        for (&self.conn_slots, 0..) |*c, i| {
            threads[i] = c.thread;
            c.thread = null;
            c.active = false;
        }
        self.conn_mutex.unlock(self.io);
        for (threads) |maybe| {
            if (maybe) |t| t.join();
        }
    }

    /// Dispatch one accepted connection to its own thread (§5.1). Over the cap, or if the
    /// thread spawn fails, reply 503 inline on the listener thread and close. Records the
    /// thread handle in the claimed slot for the shutdown join.
    fn dispatchConnection(self: *Server, stream: net.Stream) void {
        const idx = self.claimConnSlot() orelse return self.rejectConnection(stream);
        const t = std.Thread.spawn(.{}, connThreadMain, .{ConnArgs{ .server = self, .idx = idx, .stream = stream }}) catch {
            self.releaseConnSlot(idx);
            return self.rejectConnection(stream);
        };
        self.conn_mutex.lockUncancelable(self.io);
        self.conn_slots[idx].thread = t;
        self.conn_mutex.unlock(self.io);
    }

    /// Back-pressure (§5.1): the connection cap is reached (or a spawn failed). Read the
    /// request head and reply 503 + close — on the LISTENER thread (cheap; no worker hop).
    /// A stuck client here can briefly stall new accepts, but only at saturation (the same
    /// class of stall the prior single-threaded loop had on EVERY connection).
    fn rejectConnection(self: *Server, stream_in: net.Stream) void {
        var stream = stream_in;
        var rbuf: [HTTP_HEADER_MAX]u8 = undefined;
        var wbuf: [WRITE_BUF]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        var sw = stream.writer(self.io, &wbuf);
        var hs = http.Server.init(&sr.interface, &sw.interface);
        var request = hs.receiveHead() catch {
            stream.close(self.io);
            return;
        };
        request.respond("{\"error\":{\"code\":\"service_unavailable\",\"message\":\"connection cap reached\"}}", .{
            .status = .service_unavailable,
            .keep_alive = false,
            .extra_headers = &json_content_type,
        }) catch {};
        stream.close(self.io);
    }

    /// A connection thread's entry point (§5.1). Serves exactly one request via
    /// `handleConnection` (with its own `Conn` scratch), closes the socket unless a WS
    /// upgrade claimed it, and releases its registry slot. Determinism: the guest only
    /// advances inside the worker; this thread merely parses/serializes the wire.
    fn connThreadMain(args: ConnArgs) void {
        const self = args.server;
        var stream = args.stream;
        defer self.releaseConnSlot(args.idx);
        const claimed = self.handleConnection(&stream);
        if (!claimed) stream.close(self.io);
    }
};

/// The per-connection request context (multi-machine plan §3.4/§5.2, Phase 2): the
/// transient JSON/transport scratch that USED to live on `Server` (safe to reuse only
/// because one connection was handled at a time — the now-removed invariant), plus the
/// request-handling methods that build and serialize each response. One `Conn` is
/// allocated per accepted connection (heap, on the connection thread) or per test request
/// (`serveOne`, stack), so two concurrent connections NEVER share a response buffer. It
/// borrows the shared `*Server` (for the session resolver seam) and the routed `*Session`
/// (the default session, or the `X-Zdos-Session`-named one for `/api/*` — Phase 4); the
/// heavy machine-tied render buffers stay per-session on `session.render` and are streamed
/// from there, never through `resp_buf`.
///
/// Determinism (CLAUDE prime directive): a `Conn` carries no host clock, no RNG, and no
/// float in any emitted byte. It reaches guest state ONLY through `session.queue.submit`
/// (the gated, one-in-flight worker handoff); connection scheduling changes only
/// wall-clock latency, never which instructions ran.
pub const Conn = struct {
    /// The shared listener (for the session resolver seam, `resolveSession`). Borrowed;
    /// the Server outlives every connection.
    server: *Server,
    /// The routed session the `/api/*` handlers drive. Initialized to the DEFAULT session in
    /// `Conn.init`; `dispatch` re-points it at the `X-Zdos-Session`-named session (Phase 4
    /// §6 option B) for the duration of one request, holding a refcount. `/mcp` does NOT use
    /// this field — it re-resolves its own session from `Mcp-Session-Id` via `resolveSession`.
    session: *Session,

    /// Per-request arena (parsed-JSON working memory), `reset(.retain_capacity)` per
    /// request exactly as the old `Server.arena` was. Owned by this connection.
    arena: std.heap.ArenaAllocator,
    resp_buf: [RESPONSE_BUF]u8 = undefined,
    body_buf: [MAX_BODY]u8 = undefined,
    read_scratch: [MAX_BODY]u8 = undefined,
    /// The inner tool-call body for `/mcp` (mcp-plan.md §3.3/R2): the shared `writeX`
    /// builders write the SAME bytes the HTTP route emits HERE, then `handleMcp`
    /// escapes that slice into the JSON-RPC envelope (built in `resp_buf`). Kept
    /// distinct from `resp_buf` so the inner body and the envelope never alias.
    mcp_body_buf: [RESPONSE_BUF]u8 = undefined,
    /// The incoming `Mcp-Session-Id` header value, captured in `serveRequest` BEFORE the
    /// body read (which asserts/invalidates the head — `iterateHeaders` requires
    /// `state == .received_head`). Per-connection → no sharing, no race.
    mcp_session_buf: [128]u8 = undefined,
    mcp_session_len: usize = 0,
    /// The incoming `X-Zdos-Session` header value (the optional HTTP `/api/*` session
    /// selector, Phase 4 §6 option B). Captured in the SAME pre-body-read window as the MCP
    /// header (and for the same `iterateHeaders`-needs-`received_head` reason), but only for
    /// `/api/` paths. Empty → the default session (the back-compat path). Per-connection.
    api_session_buf: [128]u8 = undefined,
    api_session_len: usize = 0,

    /// LAZILY heap-allocated, reused per-connection CAPTURE scratch (Finding 2). The
    /// capture paths (`handleMcpScreenshot`, `submitAndRespondFramebuffer`) snapshot +
    /// encode the frame under `session.lock`, COPY the finished wire bytes here, UNLOCK,
    /// then write — so the unbounded socket write never holds the lock that the pacer's
    /// inline `produceFrame` shares (holding it across the write freezes the guest, since
    /// the pacer cannot submit its next slice). `null` until the first capture on this
    /// connection; allocated once to `CAPTURE_BUF_CAP` and reused; freed in `deinit`.
    /// Only capture-active connections pay; the static `Conn` footprint is unchanged.
    capture_buf: ?[]u8 = null,

    /// Build a fresh per-connection context. The big scratch arrays stay `undefined`
    /// (filled on use); only the arena needs a backing allocator (the thread-safe gpa).
    fn init(server: *Server, session: *Session) Conn {
        return .{
            .server = server,
            .session = session,
            .arena = std.heap.ArenaAllocator.init(server.gpa),
        };
    }

    fn deinit(self: *Conn) void {
        if (self.capture_buf) |buf| self.server.gpa.free(buf);
        self.arena.deinit();
    }

    /// Return this connection's CAPTURE buffer (Finding 2), allocating it once on first
    /// use and reusing it thereafter. Returns `null` only on OOM (the caller turns that
    /// into an honest error response). Sized to `CAPTURE_BUF_CAP` so it covers every
    /// capture payload (raw index/rgba or encoded PNG). Freed in `deinit`.
    fn ensureCaptureBuf(self: *Conn) ?[]u8 {
        if (self.capture_buf) |buf| return buf;
        const buf = self.server.gpa.alloc(u8, CAPTURE_BUF_CAP) catch return null;
        self.capture_buf = buf;
        return buf;
    }

    /// The shared request body: capture route + content-type, read the body, dispatch.
    fn serveRequest(self: *Conn, request: *http.Server.Request) void {
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

        // Capture the `Mcp-Session-Id` header for `/mcp` BEFORE the body read — the
        // body reader invalidates the head and `iterateHeaders` asserts `received_head`,
        // so this is the only window to read it (mcp-plan.md §3.3/§11 R7). Only the
        // `/mcp` route consults it; skip the header walk for every other path.
        self.mcp_session_len = 0;
        if (std.mem.startsWith(u8, target, "/mcp")) {
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, mcp.SESSION_HEADER)) {
                    const n = @min(h.value.len, self.mcp_session_buf.len);
                    @memcpy(self.mcp_session_buf[0..n], h.value[0..n]);
                    self.mcp_session_len = n;
                    break;
                }
            }
        }

        // Capture the OPTIONAL `X-Zdos-Session` header for `/api/*` (Phase 4 §6 option B),
        // in the SAME pre-body-read window (the body reader invalidates the head). Absent →
        // `api_session_len` stays 0 → `dispatch` keeps the default session (back-compat). A
        // separate small walk from the `/mcp` one above — the two routes are mutually
        // exclusive, so at most one runs, and neither walk is taken for static/other paths.
        self.api_session_len = 0;
        if (std.mem.startsWith(u8, target, "/api/")) {
            var it = request.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, API_SESSION_HEADER)) {
                    const n = @min(h.value.len, self.api_session_buf.len);
                    @memcpy(self.api_session_buf[0..n], h.value[0..n]);
                    self.api_session_len = n;
                    break;
                }
            }
        }

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

    fn dispatch(self: *Conn, req: *http.Server.Request, method: http.Method, target: []const u8, body: []const u8, is_json: bool) void {
        // Split target into path + query.
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |i| target[0..i] else target;
        const query = if (qmark) |i| target[i + 1 ..] else "";

        // --- HTTP `/api/*` session routing (multi-machine plan §6 option B, Phase 4) ---
        // An optional `X-Zdos-Session` header selects which machine this `/api/*` request
        // drives. ABSENT/blank → the DEFAULT session (the mandatory back-compat path: every
        // shipped client + test sends no header and is byte-for-byte unchanged). A KNOWN
        // minted id → that session, with its in-flight refcount BUMPED for the WHOLE request
        // (the `defer release` below) so a concurrent `DELETE /mcp` cannot free it mid-flight
        // — the exact resolve→defer-release discipline the MCP `tools/call` path uses. An
        // explicit but UNKNOWN/destroyed id → 404 (a typo must NOT silently fall through to
        // the default and mutate the wrong machine; the MCP path likewise rejects an unknown
        // id). `resolveSession` already maps blank/singleton → default un-refcounted (so the
        // `release` is a no-op on it), so the seam is SHARED with `/mcp`, not duplicated. The
        // header is captured only for `/api/` paths (so `api_session_len` is 0 for `/mcp` and
        // static routes), and `/mcp` re-resolves its OWN session below, leaving the routed
        // `self.session` as the default for that path.
        if (self.api_session_len > 0) {
            const routed = self.resolveSession(self.api_session_buf[0..self.api_session_len]) orelse
                return self.respondError(req, .not_found, "unknown_session", "unknown or destroyed X-Zdos-Session; mint one via MCP initialize");
            self.session = routed;
        }
        // Drop the in-flight ref at request end (no-op for the default session, which is
        // process-owned and never refcounted). Registered AFTER the resolve so the unknown-id
        // early-return above — which took no ref — does not under-flow the refcount.
        defer self.server.registry.release(self.session);

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

        // --- live CPU speed (Phase 3): GET reflects the applied mult; POST sets it ---
        if (std.mem.eql(u8, path, "/api/cpu/clock")) {
            switch (method) {
                .GET => return self.handleCpuSpeedGet(req),
                .POST => return self.handleCpuSpeedSet(req, body, is_json),
                else => return self.methodNotAllowed(req),
            }
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

        // --- MCP (Model Context Protocol) JSON-RPC 2.0 endpoint (M3, mcp-plan.md §3.1) ---
        // A SECOND front-end over the same transport-independent worker core: a different
        // envelope (JSON-RPC) building the SAME q.Command values + sharing the SAME writeX
        // body serializers (no drift). One POST carries one JSON-RPC request.
        if (std.mem.eql(u8, path, "/mcp")) {
            switch (method) {
                .POST => return self.handleMcp(req, body, is_json),
                // Session teardown (multi-machine plan §4.3): destroy the addressed session.
                .DELETE => return self.handleMcpDelete(req),
                else => return self.methodNotAllowed(req),
            }
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

    fn parseBody(self: *Conn, comptime T: type, body: []const u8) ?T {
        _ = self.arena.reset(.retain_capacity);
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), body, wire.parse_options) catch null;
    }

    fn requireJson(self: *Conn, req: *http.Server.Request, is_json: bool, body: []const u8) bool {
        // An empty body is allowed for endpoints that accept `{}`-equivalent (we treat
        // absent body as defaults). A non-empty body MUST be application/json.
        if (body.len > 0 and !is_json) {
            self.respondError(req, .unsupported_media_type, "unsupported_media_type", "request body must be application/json");
            return false;
        }
        return true;
    }

    fn handleRun(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const default_cap: u64 = 1 << 32;
        var cap: u64 = default_cap;
        if (body.len > 0) {
            const r = self.parseBody(wire.RunReq, body) orelse return self.badJson(req);
            cap = r.cycle_cap orelse default_cap;
        }
        self.submitDebuggerAndRespond(req, .{ .run = .{ .cycle_cap = cap } });
    }

    fn handleRunToCycle(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToCycleReq, body) orelse return self.badJson(req);
        self.submitDebuggerAndRespond(req, .{ .run_to_cycle = .{ .cycle = r.cycle } });
    }

    fn handleRunToAddr(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RunToAddrReq, body) orelse return self.badJson(req);
        self.submitDebuggerAndRespond(req, .{ .run_to_address = .{ .linear = r.linear } });
    }

    fn handleStepN(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
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
    fn handleRunStart(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        var slice_cycles: u64 = 0; // 0 => keep current
        var fps: u32 = 0;
        if (body.len > 0) {
            const r = self.parseBody(wire.RunStartReq, body) orelse return self.badJson(req);
            slice_cycles = r.slice_cycles orelse 0;
            fps = r.fps orelse 0;
        }
        if (!self.session.run_control.start(slice_cycles, fps)) {
            return self.respondError(req, .conflict, "run_in_flight", "a debugger run is in flight; cannot start the paced run");
        }
        self.respondRunStatus(req);
    }

    /// `POST /api/run/stop` — disarm the pacer (owner=idle); return the run status
    /// (incl. the stop cycle). A stopped machine stays inspectable/steppable.
    fn handleRunStop(self: *Conn, req: *http.Server.Request) void {
        self.session.run_control.stop();
        self.respondRunStatus(req);
    }

    /// `GET /api/run/status` — `{running, owner, cycle, slice_cycles, fps,
    /// last_stop_reason}`. `cycle` is the machine cycle: fetched via a normal `status`
    /// command (the worker is the sole reader of `cpu.st.cycles`; we never read it
    /// off-worker). The rest come from the clockless RunControl atomics.
    fn handleRunStatus(self: *Conn, req: *http.Server.Request) void {
        self.respondRunStatus(req);
    }

    fn respondRunStatus(self: *Conn, req: *http.Server.Request) void {
        // Fetch the live machine cycle via the worker (off-worker reads are banned).
        var ctx: q.RequestCtx = .{ .cmd = .status };
        const resp = self.session.queue.submit(&ctx);
        const cycle: u64 = switch (resp) {
            .status => |st| st.cycles,
            else => self.session.run_control.lastCycle(),
        };
        const rc = self.session.run_control;
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

    // -----------------------------------------------------------------------
    // Live CPU speed knob (Phase 3 of the live-CPU-clock work). INTEGER wire only
    // (the determinism grep-gate bans host floats): `{mult}` is the CPU:PIT
    // multiplier; `{mhz}` is a convenience converted to `round(mhz*1_000_000 /
    // PIT_TICK_RATE)` with integer math. A live change goes through the worker
    // command queue (applied at a precise serialized cycle, like `reset`) — NOT the
    // non-blocking live-mouse fold. On a set, the handler ALSO updates the pacer
    // slice (`PIT_TICK_RATE * applied_mult / 100`) so the timer's WALL rate stays
    // ~18.2 Hz at any speed (game pace invariant — wall-only, no golden moves).
    // -----------------------------------------------------------------------

    /// `GET /api/cpu/clock` — reflect the applied mult + derived cpu_hz/MHz so the UI
    /// can sync its knob. Reads the mult via the worker (sole reader of machine state).
    fn handleCpuSpeedGet(self: *Conn, req: *http.Server.Request) void {
        var ctx: q.RequestCtx = .{ .cmd = .clock_get };
        const resp = self.session.queue.submit(&ctx);
        switch (resp) {
            .clock => |mult| self.respondCpuSpeed(req, mult),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected clock response"),
        }
    }

    /// `POST /api/cpu/clock {mult}` or `{mhz}` — set the active CPU:PIT multiplier.
    /// Rejects `mult==0`/`mhz==0` (400). The worker CLAMPS to `[1, MAX_MULT]` and
    /// returns the APPLIED value; we then retune the pacer slice from the SAME applied
    /// value and reply with `{mult, cpu_hz, mhz, slice_cycles}`.
    fn handleCpuSpeedSet(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.CpuSpeedReq, body) orelse return self.badJson(req);
        // The mult-xor-mhz validation + the integer mhz→mult conversion is the SHARED
        // `mcp_tools.mapCpuSpeed` — the SAME copy the MCP `set_clock` tool calls (R4).
        const requested: u64 = switch (mcp_tools.mapCpuSpeed(r.mult, r.mhz)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |m| m,
        };

        // Apply at the serialized worker boundary; the worker clamps + echoes.
        var ctx: q.RequestCtx = .{ .cmd = .{ .set_clock = .{ .mult = requested } } };
        const resp = self.session.queue.submit(&ctx);
        const applied: u64 = switch (resp) {
            .clock => |m| m,
            .err => |code| return self.respondErrCode(req, code),
            else => return self.respondError(req, .service_unavailable, "internal", "unexpected clock response"),
        };

        // Retune the pacer slice from the APPLIED mult so the timer wall rate stays
        // correct as the CPU speeds up (§3). Wall-only: the pacer reads this atomic at
        // the top of each slice (paced ≡ unpaced — no cycle golden moves). fps==0 keeps
        // the current frame cadence; we only change the slice.
        const slice: u64 = timing.PIT_TICK_RATE * applied / 100;
        _ = self.session.run_control.setSlice(slice);

        self.respondCpuSpeed(req, applied);
    }

    /// `{mult, cpu_hz, mhz, slice_cycles}` — the CPU-speed view. `mhz` is rendered as
    /// a fixed-point string ("14.32") via INTEGER math (no float in src/api): cpu_hz
    /// is `PIT_TICK_RATE * mult`, the integer part is `cpu_hz / 1_000_000` and the two
    /// fractional digits are `(cpu_hz % 1_000_000) / 10_000`.
    /// Pure body-builder (mcp-plan.md §3.2) for the CPU-speed view — shared by the HTTP
    /// `respondCpuSpeed` wrapper and the MCP `get_clock`/`set_clock` tools (anti-drift).
    fn writeCpuSpeed(self: *Conn, w: *std.Io.Writer, mult: u64) std.Io.Writer.Error!void {
        _ = self;
        const cpu_hz: u64 = timing.PIT_TICK_RATE * mult;
        const mhz_int: u64 = cpu_hz / 1_000_000;
        const mhz_frac: u64 = (cpu_hz % 1_000_000) / 10_000; // 2 decimals
        const slice: u64 = cpu_hz / 100;
        try w.print(
            "{{\"mult\":{d},\"cpu_hz\":{d},\"mhz\":\"{d}.{d:0>2}\",\"slice_cycles\":{d},\"max_mult\":{d}}}",
            .{ mult, cpu_hz, mhz_int, mhz_frac, slice, timing.MAX_MULT },
        );
    }

    fn respondCpuSpeed(self: *Conn, req: *http.Server.Request, mult: u64) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeCpuSpeed(&w, mult) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn handleInputKey(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.KeyReq, body) orelse return self.badJson(req);
        // The scancode-xor-char resolution (incl. the REAL set-1 char→scancode lookup)
        // is the SHARED `mcp_tools.mapKey` — the SAME copy the MCP `input_key` tool
        // calls (R4); a char with no single set-1 key is a 400, never invented.
        switch (mcp_tools.mapKey(r)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |cmd| self.submitAndRespond(req, cmd),
        }
    }

    fn handleInputMouse(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        var r: wire.MouseReq = .{};
        if (body.len > 0) r = self.parseBody(wire.MouseReq, body) orelse return self.badJson(req);

        // --- LIVE coalesced path (plans/mouse-input.md, LOCKED §1/§2/§3) ---
        // Any Q16-normalized absolute (`nx_q16`/`ny_q16`) or the true relative channel
        // (`mdx`/`mdy`) marks this as a LIVE browser event. It folds NON-BLOCKING into
        // the `LiveMouseState` record (overwrite abs, sum rel, latest buttons) and
        // returns immediately — NO command queue, NO submit-gate, NO slice wait (the
        // latency fix). The pacer drains it at the next slice boundary via
        // `input_mouse_fold`. The buttons on a live event ride into the SAME record
        // (the browser sends `{nx_q16,ny_q16,buttons}` for a click). Determinism: this
        // touches no machine cycle; with no POSTs the record stays clean and the fold
        // arm is a no-op (byte-identical to today).
        const is_live = r.nx_q16 != null or r.ny_q16 != null or r.mdx != null or r.mdy != null;
        if (is_live) {
            // Q16 absolute is set as a PAIR (both axes) — a partial absolute can't map.
            if ((r.nx_q16 != null) != (r.ny_q16 != null)) {
                return self.respondError(req, .bad_request, "bad_request", "give both nx_q16 and ny_q16, or neither");
            }
            const set_abs = r.nx_q16 != null;
            const set_rel = r.mdx != null or r.mdy != null;
            const set_buttons = r.buttons != null;
            const nx = @min(r.nx_q16 orelse 0, @as(u32, 0x1_0000));
            const ny = @min(r.ny_q16 orelse 0, @as(u32, 0x1_0000));
            self.session.live_mouse.ingest(
                nx,
                ny,
                r.mdx orelse 0,
                r.mdy orelse 0,
                r.buttons orelse 0,
                set_abs,
                set_rel,
                set_buttons,
            );
            return self.respondJson(req, .ok, "{\"ok\":true}");
        }

        // --- SCRIPTED / deterministic path (input-injection.md §5.2) ---
        // The per-axis mutual exclusion + the `set_*` flag mapping is the SHARED
        // `mcp_tools.mapMouseScripted` — the SAME copy the MCP `input_mouse` tool
        // calls (R4). `fire_callback` is accepted for forward-compat (a no-op here).
        switch (mcp_tools.mapMouseScripted(r)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |cmd| self.submitAndRespond(req, cmd),
        }
    }

    fn handleAddBp(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.AddBpReq, body) orelse return self.badJson(req);
        // All breakpoint kinds (incl. `io` port watchpoints) are live.
        self.submitAndRespond(req, .{ .add_bp = .{ .kind = r.kind, .one_shot = r.one_shot } });
    }

    fn handleEnableBp(self: *Conn, req: *http.Server.Request, id: u32, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.EnableBpReq, body) orelse return self.badJson(req);
        self.submitAndRespond(req, .{ .enable_bp = .{ .id = id, .on = r.enabled } });
    }

    fn handleRegSet(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.RegSetReq, body) orelse return self.badJson(req);
        // The enum-name→typed-enum resolution + width range-check is the SHARED
        // `mcp_tools.mapRegSet` (the SAME copy the MCP `set_register` tool calls — R4).
        switch (mcp_tools.mapRegSet(r)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |cmd| self.submitAndRespond(req, .{ .reg_set = cmd }),
        }
    }

    fn handleLoad(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        // RECIPE span (session.zig CONTRACT #3): the read-modify-write of `session.recipe`
        // plus the `load` submit are ONE atomic per-session critical section. Two concurrent
        // loads would otherwise lose-update the recipe AND desync the persisted recipe from
        // the machine state actually loaded. Order `lock` → `submit_gate` (in submit).
        self.session.lock.lockUncancelable(self.server.io);
        defer self.session.lock.unlock(self.server.io);
        // Start from the server-held recipe; override with any provided fields.
        var recipe = self.session.recipe;
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
        self.session.recipe = recipe;
        self.submitAndRespond(req, .{ .load = recipe.toCmd() });
    }

    // --- memory handlers: query parse / hex decode into the request ctx scratch ---

    fn handleMemPeek(self: *Conn, req: *http.Server.Request, query: []const u8) void {
        const phys = self.queryU32(query, "phys") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid phys");
        const len = self.queryU32(query, "len") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid len");
        self.submitAndRespond(req, .{ .mem_peek = .{ .phys = phys, .len = len } });
    }

    fn handleMemWrite(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;
        const r = self.parseBody(wire.MemWriteReq, body) orelse return self.badJson(req);
        var ctx: q.RequestCtx = .{ .cmd = undefined };
        const decoded = wire.hexDecode(ctx.scratch[0..], r.data) catch return self.respondError(req, .bad_request, "bad_request", "invalid hex in data");
        ctx.cmd = .{ .mem_write = .{ .phys = r.phys, .len = @intCast(decoded.len) } };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn handleMemPeekSeg(self: *Conn, req: *http.Server.Request, query: []const u8) void {
        const seg = self.querySeg(query) orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid seg");
        const off = self.queryU32(query, "off") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid off");
        const len = self.queryU32(query, "len") orelse return self.respondError(req, .bad_request, "bad_request", "missing/invalid len");
        self.submitAndRespond(req, .{ .mem_peek_seg = .{ .seg = seg, .off = off, .len = len } });
    }

    fn handleMemWriteSeg(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
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
    fn handleMemSearch(self: *Conn, req: *http.Server.Request, query: []const u8) void {
        const start = self.queryU32(query, "start") orelse 0;
        const len = self.queryU32(query, "len") orelse 0; // 0 => to slab end (worker)
        const max_q = self.queryU32(query, "max") orelse 0; // 0 => MAX_SEARCH_HITS (worker)

        const pat = queryValue(query, "pattern");
        const asc = queryValue(query, "ascii");
        // Exactly one of pattern/ascii. The DECODE differs per transport (HTTP
        // percent-decodes the `ascii` query value; the MCP tool uses the JSON literal),
        // so it stays here; the post-decode bounds + the command build are the SHARED
        // `mcp_tools.buildSearch` (the SAME copy the MCP `search_memory` tool calls — R4).
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
        ctx.cmd = .{ .mem_search = switch (mcp_tools.buildSearch(needle, start, len, max_q)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |c| c,
        } };
        const resp = self.session.queue.submit(&ctx);
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
    fn writeSearch(self: *Conn, w: *std.Io.Writer, sr: q.SearchResult, needle: []const u8) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("{\"pattern\":\"");
        for (needle) |b| {
            try w.writeByte("0123456789abcdef"[b >> 4]);
            try w.writeByte("0123456789abcdef"[b & 0x0F]);
        }
        try w.print("\",\"needle_len\":{d},\"start\":{d},\"len\":{d},\"count\":{d},\"truncated\":{s},\"matches\":[", .{
            sr.needle_len, sr.start, sr.len, sr.count, if (sr.truncated) "true" else "false",
        });
        for (sr.hits[0..sr.count], 0..) |phys, i| {
            if (i != 0) try w.writeAll(",");
            try w.print("{{\"phys\":{d},\"seg\":{d},\"off\":{d}}}", .{ phys, phys >> 4, phys & 0xF });
        }
        try w.writeAll("]}");
    }

    fn respondSearch(self: *Conn, req: *http.Server.Request, sr: q.SearchResult, needle: []const u8) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeSearch(&w, sr, needle) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
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

    fn handleStack(self: *Conn, req: *http.Server.Request, query: []const u8) void {
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
    fn handleDisasm(self: *Conn, req: *http.Server.Request, query: []const u8) void {
        // Parse the raw query fields FOLLOWING the origin precedence (linear wins over
        // seg(+off)), so only the fields the precedence actually uses are parsed — the
        // transport-specific parse errors stay here. The count bound + the origin
        // SELECTION are the SHARED `mcp_tools.mapDisasm` (the SAME copy the MCP
        // `disassemble` tool calls — R4).
        const count: ?u32 = if (queryValue(query, "count")) |v|
            (std.fmt.parseInt(u32, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid count"))
        else
            null;
        var linear: ?u32 = null;
        var seg: ?u16 = null;
        var off: ?u32 = null;
        if (queryValue(query, "linear")) |v| {
            linear = std.fmt.parseInt(u32, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid linear");
        } else if (queryValue(query, "seg")) |v| {
            seg = std.fmt.parseInt(u16, v, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid seg (numeric selector)");
            if (queryValue(query, "off")) |o| {
                off = std.fmt.parseInt(u32, o, 0) catch return self.respondError(req, .bad_request, "bad_request", "invalid off");
            }
        }
        switch (mcp_tools.mapDisasm(linear, seg, off, count)) {
            .fail => |e| return self.respondError(req, .bad_request, e.code, e.message),
            .ok => |c| self.submitAndRespond(req, .{ .disasm = .{ .origin = c.origin, .count = c.count } }),
        }
    }

    /// `GET /api/devices[?palette=1]` — the grouped chipset/A20/device snapshot.
    /// `void` command; `?palette=1` only widens the JSON (the worker always fills
    /// the DAC palette, the server nulls it when the flag is absent). Pure peek.
    fn handleDevices(self: *Conn, req: *http.Server.Request, query: []const u8) void {
        const want_palette = (self.queryU32(query, "palette") orelse 0) != 0;
        var ctx: q.RequestCtx = .{ .cmd = .devices_get };
        const resp = self.session.queue.submit(&ctx);
        switch (resp) {
            .devices => |d| self.respondDevices(req, d, want_palette),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected devices response"),
        }
    }

    /// `GET /api/device/<name>` — a single device group (a20|pic|pit|vga|kbc|
    /// speaker|opl|ems). Same data as the matching key in `/api/devices`; unknown → 404.
    fn handleDevice(self: *Conn, req: *http.Server.Request, name: []const u8, query: []const u8) void {
        const want_palette = (self.queryU32(query, "palette") orelse 0) != 0;
        var ctx: q.RequestCtx = .{ .cmd = .devices_get };
        const resp = self.session.queue.submit(&ctx);
        const d = switch (resp) {
            .devices => |d| d,
            .err => |code| return self.respondErrCode(req, code),
            else => return self.respondError(req, .service_unavailable, "internal", "unexpected devices response"),
        };
        var snap = d;
        if (!want_palette) snap.vga.palette = null;
        // The name→field DISPATCH is the SHARED `writeNamedDevice` (also used by the MCP
        // `read_devices {device}` selector via `writeResponseBody` — one authority).
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const matched = self.writeNamedDevice(&w, snap, name) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        if (!matched) return self.respondError(req, .not_found, "not_found", "unknown device group");
        return self.respondJson(req, .ok, w.buffered());
    }

    /// `GET /api/io?port=N` — the non-mutating shadow of one I/O port.
    fn handleIoShadow(self: *Conn, req: *http.Server.Request, query: []const u8) void {
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
    fn queryU32(self: *Conn, query: []const u8, key: []const u8) ?u32 {
        _ = self;
        const v = queryValue(query, key) orelse return null;
        return std.fmt.parseInt(u32, v, 10) catch null;
    }
    fn querySeg(self: *Conn, query: []const u8) ?Seg {
        _ = self;
        const v = queryValue(query, "seg") orelse return null;
        return std.meta.stringToEnum(Seg, v);
    }

    // -----------------------------------------------------------------------
    // Submit + serialize the response. The ONLY path that crosses to the worker.
    // -----------------------------------------------------------------------

    fn submitAndRespond(self: *Conn, req: *http.Server.Request, cmd: q.Command) void {
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
    fn submitDebuggerAndRespond(self: *Conn, req: *http.Server.Request, cmd: q.Command) void {
        // DEBUGGER span (session.zig CONTRACT #2): `beginDebugger`→submit→`endDebugger` is the
        // owner save/restore; two concurrent run/steps on one session must not interleave it
        // (the stuck-owner bug). Hold `session.lock` across the WHOLE begin→end so it is atomic
        // per session. Order `lock` → `run_control.arb` (in begin/end) → `submit_gate` (in
        // submit) — never inverted. The pacer's own `run_control` use takes no `session.lock`,
        // so this never blocks pacer-vs-control arbitration.
        self.session.lock.lockUncancelable(self.server.io);
        defer self.session.lock.unlock(self.server.io);
        const restore = self.session.run_control.beginDebugger();
        defer self.session.run_control.endDebugger(restore);
        var ctx: q.RequestCtx = .{ .cmd = cmd };
        self.submitCtxAndRespond(req, &ctx);
    }

    fn submitCtxAndRespond(self: *Conn, req: *http.Server.Request, ctx: *q.RequestCtx) void {
        const resp = self.session.queue.submit(ctx);
        self.serializeResponse(req, resp);
    }

    // -----------------------------------------------------------------------
    // MCP (Model Context Protocol) — the JSON-RPC 2.0 front-end (M3, mcp-plan.md §5).
    // A SECOND front-end over the SAME worker core: a different envelope building the
    // SAME q.Command values, sharing the SAME writeX body serializers (no drift).
    // -----------------------------------------------------------------------

    /// The session-resolver seam (mcp-plan.md §11 R7, RESOLVED). Phase 1 runs ONE
    /// default `Session`, so any/blank `Mcp-Session-Id` resolves to `defaultSession()`.
    /// Model B (a per-session registry, each with its own queue/worker) swaps THIS
    /// function for a lookup keyed by `sid` returning a `?*Session` — an EXTENSION of
    /// the seam (the return type is already `*Session`), not a rewrite.
    /// Resolve an `Mcp-Session-Id` to the session that owns its machine (multi-machine
    /// plan §7). A BLANK id, or the fixed singleton id, → the DEFAULT session (preserving
    /// the shipped single-machine behavior for a client that never `initialize`s). A
    /// known minted id → that session, with its in-flight refcount BUMPED (the caller must
    /// pair a non-null result with `registry.release`, so a concurrent `DELETE` cannot
    /// free the session mid-request). An unknown / being-destroyed id → null (the caller
    /// replies a JSON-RPC error). The returned default session is NOT refcounted (it is
    /// process-owned and never destroyed; `release` is a no-op on it).
    fn resolveSession(self: *Conn, sid: []const u8) ?*Session {
        const default = self.server.defaultSession();
        if (sid.len == 0 or default.id.eqlSlice(sid)) return default;
        return self.server.registry.resolve(sid);
    }

    /// Handle one `POST /mcp` JSON-RPC 2.0 request (mcp-plan.md §5/§6). The reply shape:
    ///   - a NOTIFICATION (`notifications/*`) → HTTP 202, empty body;
    ///   - a protocol failure (bad JSON / envelope / method / params) → a JSON-RPC
    ///     `error` envelope at HTTP 200;
    ///   - a tool that DISPATCHED but the emulator returned an `ErrCode` → a tool
    ///     `result` with `isError:true` at HTTP 200 (the model fixes its plan, not the
    ///     call — the §6 dividing line);
    ///   - otherwise a tool `result` carrying the SAME body bytes the HTTP route emits.
    /// Determinism: arena reset per request, all guest effects via `queue.submit`, run/
    /// step through `beginDebugger`/`endDebugger` exactly like the HTTP path — no host
    /// time, no RNG, the session id a fixed literal constant.
    fn handleMcp(self: *Conn, req: *http.Server.Request, body: []const u8, is_json: bool) void {
        if (!self.requireJson(req, is_json, body)) return;

        // Parse the whole body into a Value tree (carry `params` as a sub-tree; detect a
        // batch). A parse failure is JSON-RPC -32700 with id:null.
        _ = self.arena.reset(.retain_capacity);
        const tree = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), body, wire.parse_options) catch {
            return self.respondRpcError(req, null, .parse, "request body is not valid JSON");
        };

        // A top-level array is a JSON-RPC batch — rejected in v1 (mcp-plan.md §11 R3).
        if (tree == .array) return self.respondRpcError(req, null, .invalid_request, "JSON-RPC batches are not supported");
        if (tree != .object) return self.respondRpcError(req, null, .invalid_request, "request must be a JSON-RPC object");
        const obj = tree.object;

        // Extract the id (echoed verbatim). A float/bool id is malformed → -32600 (R6:
        // keeps floats out of our emitted bytes). Absent or explicit null → id:null.
        var id: ?mcp.Id = null;
        if (obj.get("id")) |idv| switch (idv) {
            .null => {},
            .integer, .number_string, .string => id = mcp.parseId(idv).?,
            else => return self.respondRpcError(req, null, .invalid_request, "id must be a string or integer"),
        };

        // `jsonrpc` must be exactly "2.0"; `method` must be a string.
        const ver = obj.get("jsonrpc") orelse return self.respondRpcError(req, id, .invalid_request, "missing jsonrpc field");
        if (ver != .string or !std.mem.eql(u8, ver.string, "2.0")) {
            return self.respondRpcError(req, id, .invalid_request, "jsonrpc must be \"2.0\"");
        }
        const method_v = obj.get("method") orelse return self.respondRpcError(req, id, .invalid_request, "missing method field");
        if (method_v != .string) return self.respondRpcError(req, id, .invalid_request, "method must be a string");
        const method = method_v.string;
        const params: std.json.Value = obj.get("params") orelse .null;

        // --- dispatch on method ---
        // `initialize`/`tools/list`/notifications are session-AGNOSTIC (initialize MINTS a
        // session rather than addressing one), so they never resolve. Only `tools/call`
        // addresses a machine: resolve its `Mcp-Session-Id` HERE (blank/singleton → the
        // default; a known minted id → that session, refcounted; unknown → a JSON-RPC
        // error). The refcount pins the session for the whole call so a concurrent
        // `DELETE /mcp` cannot tear it down mid-flight; `release` drops it on every path.
        if (std.mem.startsWith(u8, method, "notifications/")) return self.respondNotificationAck(req);
        if (std.mem.eql(u8, method, "initialize")) return self.respondMcpInitialize(req, id);
        if (std.mem.eql(u8, method, "tools/list")) return self.respondMcpToolsList(req, id);
        if (std.mem.eql(u8, method, "tools/call")) {
            // An unknown/destroyed session id is HTTP 404 (the MCP Streamable-HTTP convention +
            // consistency with the `/api/*` unknown-`X-Zdos-Session` 404), NOT a 200 envelope —
            // the client should re-`initialize` rather than retry the same dead id.
            const session = self.resolveSession(self.mcp_session_buf[0..self.mcp_session_len]) orelse
                return self.respondRpcErrorStatus(req, id, .invalid_request, "unknown or destroyed Mcp-Session-Id; call initialize first", .not_found);
            defer self.server.registry.release(session);
            return self.handleMcpToolCall(req, id, params, session);
        }
        return self.respondRpcError(req, id, .method_not_found, "unknown method");
    }

    /// `DELETE /mcp` (multi-machine plan §4.3 teardown): destroy the addressed session —
    /// stop + join its worker, free its machine + buffers, remove it from the registry.
    /// `registry.destroy` serializes teardown against any in-flight request on that
    /// session (it removes the id, drains the refcount, then joins the worker), so this is
    /// race- and leak-free. A blank id, the default singleton, or an unknown id is NOT a
    /// destroyable session → 404 (the default session is process-owned, never torn down
    /// over the wire).
    fn handleMcpDelete(self: *Conn, req: *http.Server.Request) void {
        const sid = self.mcp_session_buf[0..self.mcp_session_len];
        const default = self.server.defaultSession();
        if (sid.len == 0 or default.id.eqlSlice(sid)) {
            return self.respondError(req, .not_found, "not_found", "no destroyable session for that Mcp-Session-Id");
        }
        if (!self.server.registry.destroy(sid)) {
            return self.respondError(req, .not_found, "not_found", "no such session");
        }
        self.respondJson(req, .ok, "{\"ok\":true,\"deleted\":true}");
    }

    /// `tools/call`: validate `name`+`arguments` → build the worker command → submit →
    /// serialize the result content via the SHARED writeX builders.
    fn handleMcpToolCall(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, params: std.json.Value, session: *Session) void {
        if (params != .object) return self.respondRpcError(req, id, .invalid_params, "params must be an object");
        const pobj = params.object;
        const name_v = pobj.get("name") orelse return self.respondRpcError(req, id, .invalid_params, "tools/call requires a name");
        if (name_v != .string) return self.respondRpcError(req, id, .invalid_params, "name must be a string");
        const name = name_v.string;
        if (mcp_tools.find(name) == null) return self.respondRpcError(req, id, .invalid_params, "unknown tool");
        const args: std.json.Value = pobj.get("arguments") orelse .null;

        // `screenshot` is server-special like `load`: it needs the session render buffers
        // AND emits a bespoke (image, streamed) response shape rather than the text
        // content block the rest of the tools share (mcp-plan.md §7). It takes no
        // arguments, so it branches out before the buildCommand mapping below.
        if (std.mem.eql(u8, name, "screenshot")) return self.handleMcpScreenshot(req, id, session);

        // Map (name, args) → q.Command (+ debugger flag + RespondOpts). A validation
        // failure is -32602 (fix the CALL). `load` is server-special: its recipe overlay
        // + persist need `Server` state, so it is built here (mcp-plan.md §4.4) instead
        // of in the pure `buildCommand`.
        var ctx: q.RequestCtx = .{ .cmd = undefined };
        var opts: mcp_tools.RespondOpts = .{};

        // Submit through the SAME queue as the HTTP path, taking `session.lock` for exactly
        // the off-queue spans (session.zig CONTRACT): `load` is the RECIPE span (#3 — recipe
        // overlay+persist+submit atomic, identical to `handleLoad`); a run/step is the
        // DEBUGGER span (#2 — begin→submit→end atomic, identical to `submitDebuggerAndRespond`,
        // the stuck-owner fix). Every other tool is a pure queue command and stays LOCK-FREE
        // (the `submit_gate` already serializes it). Order `lock` → `run_control.arb` →
        // `submit_gate`, never inverted.
        const resp: q.Response = if (std.mem.eql(u8, name, "load")) load: {
            session.lock.lockUncancelable(self.server.io);
            defer session.lock.unlock(self.server.io);
            ctx.cmd = self.buildMcpLoad(req, id, session, args) orelse return; // error reply done inside; defer unlocks
            break :load session.queue.submit(&ctx);
        } else built: {
            const b = switch (mcp_tools.buildCommand(self.arena.allocator(), name, args, &ctx)) {
                .invalid_params => |msg| return self.respondRpcError(req, id, .invalid_params, msg),
                .command => |c| c,
            };
            ctx.cmd = b.cmd;
            opts = b.opts;
            if (b.needs_debugger) {
                session.lock.lockUncancelable(self.server.io);
                defer session.lock.unlock(self.server.io);
                const restore = session.run_control.beginDebugger();
                defer session.run_control.endDebugger(restore);
                break :built session.queue.submit(&ctx);
            }
            break :built session.queue.submit(&ctx);
        };

        // `set_clock` post-step (mcp-plan.md §4.4): retune the pacer slice from the
        // APPLIED (worker-clamped) mult so the timer wall rate stays correct — exactly
        // like the HTTP `handleCpuSpeedSet`. Wall-only; no cycle golden moves.
        if (std.mem.eql(u8, name, "set_clock")) switch (resp) {
            .clock => |applied| _ = session.run_control.setSlice(timing.PIT_TICK_RATE * applied / 100),
            else => {},
        };

        // Build the inner tool body into `mcp_body_buf` via the SHARED `writeResponseBody`
        // builder — the SAME bytes the matching HTTP route emits (the anti-drift
        // guarantee). An emulator ErrCode becomes an `isError` content body (the §6
        // dividing line) from the shared `errInfo`.
        var bw = std.Io.Writer.fixed(self.mcp_body_buf[0..]);
        var is_error = false;
        const body_ok = blk: {
            switch (resp) {
                .err => |code| {
                    is_error = true;
                    const info = errInfo(code);
                    bw.print("{{\"error\":{{\"code\":\"{s}\",\"message\":", .{info.code}) catch break :blk false;
                    std.json.Stringify.encodeJsonString(info.msg, wire.stringify_options, &bw) catch break :blk false;
                    bw.writeAll("}}") catch break :blk false;
                },
                else => self.writeResponseBody(&bw, resp, opts) catch break :blk false,
            }
            break :blk true;
        };
        if (!body_ok) return self.respondRpcError(req, id, .internal, "failed to serialize tool result");
        const inner = bw.buffered();

        // Frame the JSON-RPC envelope in `resp_buf`, escaping the inner body (itself JSON
        // text) into the MCP text content block.
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const env_ok = blk: {
            mcp.writeResultPrefix(&w, id) catch break :blk false;
            w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch break :blk false;
            std.json.Stringify.encodeJsonString(inner, wire.stringify_options, &w) catch break :blk false;
            w.print("}}],\"isError\":{s}}}", .{if (is_error) "true" else "false"}) catch break :blk false;
            mcp.writeResultSuffix(&w) catch break :blk false;
            break :blk true;
        };
        if (!env_ok) return self.respondRpcError(req, id, .internal, "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// The `screenshot` tool (mcp-plan.md §7 — the deferred framebuffer feature). Capture
    /// the ADDRESSED session's current video frame as a PNG and return it as an MCP IMAGE
    /// content block: `{"content":[{"type":"image","data":"<b64 PNG>","mimeType":
    /// "image/png"}],"isError":false}`. Image-capable clients render it inline.
    ///
    /// This reuses the EXACT deterministic pipeline of the HTTP `/api/framebuffer` route:
    /// submit `framebuffer_get` to the SESSION's queue (the worker re-renders the current
    /// VGA mode from machine state into THAT session's render buffers), then `encodePng`
    /// the immutable snapshot — one render path, no second rasterizer. A mode with no
    /// faithful rasterizer (`!fr.supported`) is reported as an `isError` text result (the
    /// §6 dividing line: the model fixes its plan, not the call), NEVER a fabricated frame
    /// (ground rules 2/3). An encode overflow is likewise an honest error, not a truncated
    /// image.
    ///
    /// Response strategy = (A) STREAMING (mcp-plan.md §7 option A). A frame PNG is up to
    /// ~1.2 MiB; base64 inflates it ~1.33× to ~1.6 MiB — far past the 32 KiB `resp_buf`.
    /// Rather than stage that, we compute the EXACT Content-Length (prefix + base64 len
    /// [= 4·⌈pngLen/3⌉] + suffix — all known once the PNG is encoded) and stream straight
    /// to the socket: `respondStreaming` drains a small fixed buffer while
    /// `base64.Encoder.encodeWriter` produces the text in 3-byte windows over `png_out`.
    /// No ~1.6 MiB buffer is held anywhere — memory stays flat across the 16-connection /
    /// N-session world (a per-`Conn` 1.6 MiB buffer would cost 25 MiB; a per-session one
    /// would scale with sessions). Concurrency: per-session render buffers + `png_out`
    /// mean two clients screenshotting DIFFERENT sessions cannot corrupt each other; the
    /// submit→read-snapshot→encode window is the SAME one the shipped `/api/framebuffer`
    /// route uses on `session.render`, so this adds no new race.
    ///
    /// Determinism: PNG encode + base64 are pure functions of the rendered frame — same
    /// machine state ⇒ byte-identical base64. No host clock / RNG / host-filename anywhere.
    fn handleMcpScreenshot(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, session: *Session) void {
        // CAPTURE span (session.zig CONTRACT #1) — the lock now ends at the snapshot COPY,
        // NOT the wire write (Finding 2). We hold `session.lock` only across submit →
        // read/ENCODE `session.render`/`png_out` → COPY the finished PNG into this
        // connection's owned `capture_buf`; then UNLOCK and base64-stream the OWNED copy to
        // the (unbounded, possibly slow) socket. Holding the lock across that write would
        // block the pacer's inline `produceFrame` (which takes the SAME lock) and FREEZE the
        // guest. Determinism is unaffected: encode is a pure function of an immutable worker
        // snapshot taken under the lock; the post-unlock write is pure transport.
        const buf = self.ensureCaptureBuf() orelse
            return self.respondMcpToolError(req, id, "internal", "out of memory allocating capture buffer");

        // A typed failure recorded under the lock and acted on AFTER unlock, so no socket
        // write ever happens while the lock is held. `.tool` → an `isError` tool result
        // (§6: an emulator ErrCode, an unrasterizable mode, an encode overflow); `.rpc` → a
        // JSON-RPC protocol error (an unexpected response shape).
        const Fail = union(enum) {
            tool: struct { code: []const u8, msg: []const u8 },
            rpc: []const u8,
        };
        var png_len: usize = 0;
        const failure: ?Fail = blk: {
            session.lock.lockUncancelable(self.server.io);
            defer session.lock.unlock(self.server.io);
            // Re-render the current VGA mode into the session's render buffers (same path
            // the HTTP framebuffer route drives). The connection blocks in `submit` until
            // the worker has finished, so the snapshot we read next is complete and stable.
            var ctx: q.RequestCtx = .{ .cmd = .framebuffer_get };
            const resp = session.queue.submit(&ctx);
            const fr = switch (resp) {
                .framebuffer => |f| f,
                // An emulator ErrCode is a tool `result` with isError:true (§6), not a
                // JSON-RPC protocol error.
                .err => |code| {
                    const info = errInfo(code);
                    break :blk Fail{ .tool = .{ .code = info.code, .msg = info.msg } };
                },
                else => break :blk Fail{ .rpc = "unexpected framebuffer response" },
            };
            // No faithful rasterizer for the current mode → honest deferral, not a fake frame.
            if (!fr.supported)
                break :blk Fail{ .tool = .{ .code = "not_implemented", .msg = "no faithful rasterizer for the current video mode" } };

            // Encode the snapshot into the session's `png_out` slab, then COPY the finished
            // PNG into this connection's owned buffer so the wire write outlives the lock.
            // An overflow is an honest error result, not a clipped PNG.
            const png_bytes = encodePng(session.render, fr) orelse
                break :blk Fail{ .tool = .{ .code = "internal", .msg = "PNG encode overflow" } };
            @memcpy(buf[0..png_bytes.len], png_bytes);
            png_len = png_bytes.len;
            break :blk null;
        };
        // Lock released — every error response and the socket write happen UNLOCKED.
        if (failure) |f| switch (f) {
            .tool => |t| return self.respondMcpToolError(req, id, t.code, t.msg),
            .rpc => |m| return self.respondRpcError(req, id, .internal, m),
        };
        const png_bytes = buf[0..png_len];

        // Build the envelope+content PREFIX into `resp_buf` so we can measure its exact
        // byte length (it embeds the echoed `id`); the image `data` string opens here and
        // the base64 streams next. Suffix closes the image object, content array, result
        // object, and envelope.
        const enc = std.base64.standard.Encoder;
        const b64_len = enc.calcSize(png_bytes.len);
        var pw = std.Io.Writer.fixed(self.resp_buf[0..]);
        const prefix_ok = blk: {
            mcp.writeResultPrefix(&pw, id) catch break :blk false;
            pw.writeAll("{\"content\":[{\"type\":\"image\",\"data\":\"") catch break :blk false;
            break :blk true;
        };
        if (!prefix_ok) return self.respondRpcError(req, id, .internal, "response too large");
        const prefix = pw.buffered();
        const suffix = "\",\"mimeType\":\"image/png\"}],\"isError\":false}}";
        const content_length: u64 = @as(u64, prefix.len) + b64_len + suffix.len;

        // Stream: write headers with the exact content-length, then push prefix → base64 →
        // suffix straight to the socket. A small fixed buffer is drained as it fills; no
        // large intermediate buffer exists. A write failure here means the peer dropped —
        // headers are already on the wire, so we just let the (keep_alive=false) socket
        // close, which honestly signals truncation. We never emit a fake/clipped frame.
        const headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        };
        var stream_buf: [4096]u8 = undefined;
        var bw = req.respondStreaming(&stream_buf, .{
            .content_length = content_length,
            .respond_options = .{ .status = .ok, .keep_alive = false, .extra_headers = &headers },
        }) catch return;
        bw.writer.writeAll(prefix) catch return;
        enc.encodeWriter(&bw.writer, png_bytes) catch return;
        bw.writer.writeAll(suffix) catch return;
        bw.end() catch return;
    }

    /// Emit a tool `result` with `isError:true` carrying `{"error":{"code":<code>,
    /// "message":<msg>}}` as the text content — the §6 dividing line for an emulator-domain
    /// failure (an unrasterizable video mode, an encode overflow). Small text body → fits
    /// `resp_buf` via the normal `respondJson` path. Byte-identical in shape to the
    /// `.err` arm of `handleMcpToolCall`.
    fn respondMcpToolError(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, code: []const u8, msg: []const u8) void {
        // Build the inner `{"error":...}` object first, then escape it as the content text.
        var bw = std.Io.Writer.fixed(self.mcp_body_buf[0..]);
        const inner_ok = blk: {
            bw.print("{{\"error\":{{\"code\":\"{s}\",\"message\":", .{code}) catch break :blk false;
            std.json.Stringify.encodeJsonString(msg, wire.stringify_options, &bw) catch break :blk false;
            bw.writeAll("}}") catch break :blk false;
            break :blk true;
        };
        if (!inner_ok) return self.respondRpcError(req, id, .internal, "failed to serialize tool error");
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            mcp.writeResultPrefix(&w, id) catch break :blk false;
            w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch break :blk false;
            std.json.Stringify.encodeJsonString(bw.buffered(), wire.stringify_options, &w) catch break :blk false;
            w.writeAll("}],\"isError\":true}") catch break :blk false;
            mcp.writeResultSuffix(&w) catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondRpcError(req, id, .internal, "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// The `load` tool (mcp-plan.md §4.4): overlay the `LoadReq` fields onto the
    /// session-held recipe, PERSIST it (so a later `load {}` re-loads it), and return the
    /// `.load` command — mirroring the HTTP `handleLoad`. On a malformed `arguments` it
    /// emits the `-32602` envelope and returns null (the caller returns). Parsed over the
    /// per-request arena (already reset by `handleMcp`). CONCURRENCY: the CALLER must hold
    /// `session.lock` across this overlay/persist AND the subsequent `load` submit (the
    /// RECIPE span, session.zig CONTRACT #3) — this function does not take the lock itself.
    fn buildMcpLoad(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, session: *Session, args: std.json.Value) ?q.Command {
        var recipe = session.recipe;
        if (args == .object) {
            const r = std.json.parseFromValueLeaky(wire.LoadReq, self.arena.allocator(), args, wire.parse_options) catch {
                self.respondRpcError(req, id, .invalid_params, "load expects {drive?,file?,cmdtail?}");
                return null;
            };
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
        session.recipe = recipe;
        return .{ .load = recipe.toCmd() };
    }

    /// A JSON-RPC `error` envelope (mcp-plan.md §6.2). Always HTTP 200 — a well-formed
    /// JSON-RPC error response is still a successful HTTP exchange.
    fn respondRpcError(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, code: mcp.RpcError, msg: []const u8) void {
        self.respondRpcErrorStatus(req, id, code, msg, .ok);
    }

    /// A JSON-RPC `error` envelope at an EXPLICIT HTTP status. Used for the unknown/destroyed
    /// `Mcp-Session-Id` case on `tools/call`, which returns HTTP 404 (not 200) — matching both
    /// (a) zdos's own `/api/*` unknown-`X-Zdos-Session` 404 and (b) the MCP Streamable-HTTP
    /// convention (an unknown session ⇒ 404 ⇒ the client re-`initialize`s). The JSON-RPC
    /// error body is still carried, so a client that reads the body also gets a typed reason.
    fn respondRpcErrorStatus(self: *Conn, req: *http.Server.Request, id: ?mcp.Id, code: mcp.RpcError, msg: []const u8, status: http.Status) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        mcp.writeErrorEnvelope(&w, id, code, msg) catch {
            return self.respondJson(req, status, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal\"}}");
        };
        self.respondJson(req, status, w.buffered());
    }

    /// A notification has no id → fire-and-forget → HTTP 202, empty body (mcp-plan.md §5).
    fn respondNotificationAck(self: *Conn, req: *http.Server.Request) void {
        _ = self;
        req.respond("", .{ .status = .accepted, .keep_alive = false }) catch {};
    }

    /// `initialize`: PROVISION a new session in the registry and advertise the protocol
    /// version + serverInfo + tools capability, echoing the freshly MINTED `zdos-sess-<seq>`
    /// in the `Mcp-Session-Id` response header (multi-machine plan §7.3). The minted
    /// session boots the SAME program as the default (its recipe + mount dir) on its own
    /// machine + worker, so the client drives an independent, isolated guest. At the
    /// `MAX_SESSIONS` cap a JSON-RPC `internal` error is returned (the §9 reject-don't-evict
    /// behavior); a program that will not boot is likewise an `internal` error. A client
    /// that NEVER calls `initialize` keeps using the default session (blank id → default),
    /// so the shipped single-machine behavior is unchanged.
    fn respondMcpInitialize(self: *Conn, req: *http.Server.Request, id: ?mcp.Id) void {
        const default = self.server.defaultSession();
        // RECIPE READ span (session.zig CONTRACT): `default.recipe` is a ~143-byte multi-
        // field `LoadRecipe` and `default.mount_dir` an `Io.Dir`; the locked WRITERS
        // (`handleLoad`, `buildMcpLoad`) overlay/persist `recipe` under `default.lock`. A
        // concurrent `POST /api/load` racing this by-value read would TEAR the copy (a
        // `file`/`file_len` mismatch) → the minted session boots a corrupt program. Hold
        // `default.lock` ONLY across the copy-out, then UNLOCK before `registry.create`:
        // `create` takes the registry mutex, and the §13 lock order forbids nesting the
        // registry mutex under `session.lock` (it would invert `session.lock` →
        // registry-mutex against the resolve/release ordering). So we never hold the
        // session lock across `create`.
        default.lock.lockUncancelable(self.server.io);
        const recipe = default.recipe;
        const mount_dir = default.mount_dir;
        default.lock.unlock(self.server.io);
        const created = self.server.registry.create(recipe, mount_dir) catch |err| switch (err) {
            error.SessionLimitReached => return self.respondRpcError(req, id, .internal, "session limit reached; DELETE an existing session first"),
            error.BootFailed => return self.respondRpcError(req, id, .internal, "failed to boot the program for the new session"),
            error.OutOfMemory => return self.respondRpcError(req, id, .internal, "out of memory provisioning the new session"),
            // A worker-thread spawn failure (resource exhaustion) is likewise a provisioning failure.
            else => return self.respondRpcError(req, id, .internal, "failed to provision the new session"),
        };
        // The minted id arrives BY VALUE from `create` (the lifetime/UAF fix): `create`
        // publishes the new `*Session` into the map UN-refcounted, so a concurrent DELETE of
        // the predictable `zdos-sess-<seq>` id could free it the instant `create` returns. We
        // therefore NEVER dereference `created.session` here — only the id value, which the
        // registry snapshotted while it still solely owned the session.
        const minted_id: SessionId = created.id;

        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            mcp.writeResultPrefix(&w, id) catch break :blk false;
            w.print(
                "{{\"protocolVersion\":\"{s}\",\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}},\"capabilities\":{{\"tools\":{{}}}}}}",
                .{ mcp.PROTOCOL_VERSION, mcp.SERVER_NAME, mcp.SERVER_VERSION },
            ) catch break :blk false;
            mcp.writeResultSuffix(&w) catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondRpcError(req, id, .internal, "response too large");
        const headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "mcp-session-id", .value = minted_id.slice() },
        };
        req.respond(w.buffered(), .{ .status = .ok, .keep_alive = false, .extra_headers = &headers }) catch {};
    }

    /// `tools/list`: emit the static catalog (each `{name,description,inputSchema}`).
    fn respondMcpToolsList(self: *Conn, req: *http.Server.Request, id: ?mcp.Id) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        const ok = blk: {
            mcp.writeResultPrefix(&w, id) catch break :blk false;
            mcp_tools.writeToolsList(&w) catch break :blk false;
            mcp.writeResultSuffix(&w) catch break :blk false;
            break :blk true;
        };
        if (!ok) return self.respondRpcError(req, id, .internal, "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Submit the `void` screen command and serialize with the server-parsed
    /// `?attrs` flag (the flag is NOT part of the command — Finding 5).
    fn submitAndRespondScreen(self: *Conn, req: *http.Server.Request, want_attrs: bool) void {
        var ctx: q.RequestCtx = .{ .cmd = .screen_get };
        const resp = self.session.queue.submit(&ctx);
        switch (resp) {
            .screen => |sr| self.respondScreen(req, sr, want_attrs),
            .err => |code| self.respondErrCode(req, code),
            else => self.respondError(req, .service_unavailable, "internal", "unexpected screen response"),
        }
    }

    /// Submit the `framebuffer_get` command (the worker renders into the SERVER-OWNED
    /// `self.session.render` buffers) and stream the selected buffer as a raw binary body (B1).
    /// The pixels are read straight from `self.session.render` to the socket — never through
    /// `resp_buf`/JSON. The descriptor (mode/width/height/lens/double-scan) goes in
    /// `X-Frame-*` response headers. A mode with no faithful rasterizer is a 501 (the
    /// honest deferral — never a fabricated frame).
    fn submitAndRespondFramebuffer(self: *Conn, req: *http.Server.Request, fmt: FramebufferFormat) void {
        // CAPTURE span (session.zig CONTRACT #1) — the lock now ends at the snapshot COPY,
        // NOT the `req.respond` wire write (Finding 2). The worker re-renders into
        // `session.render` and we READ/ENCODE that same buffer here (`encodePng` even mutates
        // `render.index` in place), so a concurrent capture (another connection, or the
        // pacer's inline `produceFrame`) must not tear the frame or re-render mid-read. We
        // therefore hold `session.lock` only across submit → read/encode → COPY the selected
        // bytes into this connection's owned `capture_buf`, then UNLOCK and `req.respond` the
        // OWNED copy. Pre-fix the body sliced INTO `session.render` and the unbounded socket
        // write held the lock — blocking `produceFrame` (same lock) and FREEZING the guest.
        // Determinism is unaffected: the copy is a pure snapshot under the lock; the write is
        // pure transport. Order `lock` → `submit_gate` (in submit).
        const buf = self.ensureCaptureBuf() orelse
            return self.respondError(req, .service_unavailable, "internal", "out of memory allocating capture buffer");

        // A typed failure recorded under the lock and acted on AFTER unlock (so no socket
        // write runs while the lock is held). `.err_code` → `respondErrCode`; `.status` → a
        // plain HTTP error (unexpected response, unrasterizable mode, encode overflow).
        const FbFail = union(enum) {
            err_code: q.ErrCode,
            status: struct { status: http.Status, code: []const u8, msg: []const u8 },
        };
        var fr_copy: q.FramebufferResult = undefined; // POD descriptor, valid past unlock
        var body_len: usize = 0;
        const failure: ?FbFail = blk: {
            self.session.lock.lockUncancelable(self.server.io);
            defer self.session.lock.unlock(self.server.io);
            var ctx: q.RequestCtx = .{ .cmd = .framebuffer_get };
            const resp = self.session.queue.submit(&ctx);
            const fr = switch (resp) {
                .framebuffer => |f| f,
                .err => |code| break :blk FbFail{ .err_code = code },
                else => break :blk FbFail{ .status = .{ .status = .service_unavailable, .code = "internal", .msg = "unexpected framebuffer response" } },
            };
            if (!fr.supported)
                break :blk FbFail{ .status = .{ .status = .not_implemented, .code = "not_implemented", .msg = "no faithful rasterizer for the current video mode" } };
            // COPY the selected buffer into the owned scratch so the body does NOT alias
            // `session.render` past the unlock (the worker could re-render under it). The PNG
            // path re-encodes the same peek host-side over the server-owned snapshot
            // (off-worker, cycle-neutral §3.6); index/rgba copy the raw buffer.
            const src: []const u8 = switch (fmt) {
                .index => self.session.render.index[0..fr.index_len],
                .rgba => self.session.render.rgba[0..fr.rgba_len],
                .png => encodePng(self.session.render, fr) orelse
                    break :blk FbFail{ .status = .{ .status = .service_unavailable, .code = "internal", .msg = "PNG encode overflow" } },
            };
            @memcpy(buf[0..src.len], src);
            body_len = src.len;
            fr_copy = fr;
            break :blk null;
        };
        // Lock released — every error response and the `req.respond` write happen UNLOCKED.
        if (failure) |f| switch (f) {
            .err_code => |code| return self.respondErrCode(req, code),
            .status => |s| return self.respondError(req, s.status, s.code, s.msg),
        };
        const body = buf[0..body_len]; // owned copy; never points into `session.render`

        // content-type + format tag, computed UNLOCKED over the copied `fr_copy` descriptor.
        var content_type: []const u8 = "application/octet-stream";
        var fmt_str: []const u8 = "index";
        switch (fmt) {
            .index => {},
            .rgba => fmt_str = "rgba",
            .png => {
                content_type = "image/png";
                fmt_str = if (fr_copy.palette_present) "png-indexed" else "png-rgb";
            },
        }

        // Descriptor headers (the client reads dims/kind from these). Small fixed scratch.
        var wbuf: [8]u8 = undefined;
        var hbuf: [8]u8 = undefined;
        var kbuf: [8]u8 = undefined;
        const w_str = std.fmt.bufPrint(&wbuf, "{d}", .{fr_copy.width}) catch "0";
        const h_str = std.fmt.bufPrint(&hbuf, "{d}", .{fr_copy.height}) catch "0";
        const kind_str = std.fmt.bufPrint(&kbuf, "{d}", .{@intFromEnum(fr_copy.kind)}) catch "0";

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

    /// Encode the just-captured frame (in the per-session `render` snapshot) into THAT
    /// session's `png_out` slab and return the PNG bytes. Indexed PNG when the mode is
    /// paletted (the PLTE comes from the worker-filled palette slab, with `pel_mask`
    /// applied to the indices, §3.3); truecolor RGB otherwise. On an encode overflow it
    /// returns `null` WITHOUT responding — the caller picks the error shape (the HTTP
    /// `/api/framebuffer` route 500s; the MCP `screenshot` tool emits an `isError`
    /// result). This runs on the listener thread over an immutable snapshot — it reads
    /// NO machine state, charges NO cycle (§3.1/§5), and is a pure function of the frame
    /// (the determinism prime directive: same frame ⇒ byte-identical PNG).
    fn encodePng(render: *worker_mod.RenderBuffers, fr: q.FramebufferResult) ?[]const u8 {
        const rb = render;
        var out: std.Io.Writer = .fixed(rb.png_out[0..]);
        if (fr.palette_present) {
            // Apply pel_mask to each index in place so the PLTE lookup matches the RGBA
            // peek (`indexToRgba`: `dac_rgb[idx & mask]`). 0xFF => a no-op copy.
            const idx = rb.index[0..fr.index_len];
            if (fr.pel_mask != 0xFF) {
                for (idx) |*p| p.* &= fr.pel_mask;
            }
            const palette: *const [256]png.Rgb = @ptrCast(&rb.palette);
            png.encodeIndexed(&out, &rb.png_work, fr.width, fr.height, idx, palette) catch return null;
        } else {
            png.encodeRgb(&out, &rb.png_work, fr.width, fr.height, rb.rgba[0..fr.rgba_len]) catch return null;
        }
        return out.buffered();
    }

    /// The HTTP serializer: map a worker `Response` to a JSON body. The non-error,
    /// non-framebuffer arms are built by the SHARED `writeResponseBody` (the SAME
    /// builder the MCP `tools/call` path uses → the two front-ends are byte-identical,
    /// pinned by the equivalence tests). `.err` keeps its `code → HTTP status` mapping;
    /// `.framebuffer` is streamed separately (raw binary, B1) and never reaches here.
    fn serializeResponse(self: *Conn, req: *http.Server.Request, resp: q.Response) void {
        switch (resp) {
            .err => |code| return self.respondErrCode(req, code),
            // If a framebuffer ever reaches this generic JSON path, report it honestly
            // rather than emitting a wrong body.
            .framebuffer => return self.respondError(req, .service_unavailable, "internal", "framebuffer must be streamed via /api/framebuffer"),
            else => {},
        }
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        // Default opts: no attrs / no palette / whole-snapshot / no search-needle echo —
        // exactly the prior per-arm defaults (the `/api/screen`, `/api/devices`,
        // `/api/mem/search` routes pass their own flags via their dedicated handlers).
        self.writeResponseBody(&w, resp, .{}) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// The ONE per-arm body builder (mcp-plan.md §3.2) shared by `serializeResponse`
    /// (HTTP) and `handleMcpToolCall` (MCP). It NEVER handles `.err`/`.framebuffer` —
    /// both front-ends pre-handle those (an `.err` is a tool `isError` content for MCP /
    /// an HTTP status for HTTP; a `.framebuffer` is streamed). `opts` carries the
    /// per-route flags (`want_attrs`/`want_palette`/`device`/`search_needle`).
    fn writeResponseBody(self: *Conn, w: *std.Io.Writer, resp: q.Response, opts: mcp_tools.RespondOpts) std.Io.Writer.Error!void {
        switch (resp) {
            .ok => try w.writeAll("{\"ok\":true}"),
            .stop => |s| try self.writeValue(w, .{ .stop = s }),
            .step_over => |so| try self.writeValue(w, .{ .stop = so.reason, .stepped_into = so.stepped_into }),
            .bp_id => |id| try self.writeValue(w, .{ .id = id }),
            .bp_one => |b| try self.writeValue(w, b),
            .bp_list => |l| try self.writeBpList(w, l),
            .cleared => |n| try self.writeValue(w, .{ .removed = n }),
            .cpu => |snap| try self.writeValue(w, snap),
            .clock => |mult| try self.writeCpuSpeed(w, mult),
            .mem => |mr| try self.writeMem(w, mr),
            .mem_written => |mw| try self.writeValue(w, .{ .phys = mw.phys, .len = mw.len }),
            .ivt => |i| try self.writeValue(w, .{ .vector = i.vector, .ip = i.ip, .cs = i.cs }),
            .stack => |s| try self.writeStack(w, s),
            .status => |st| try self.writeValue(w, st),
            .console => |cr| try self.writeConsole(w, cr),
            .screen => |sr| try self.writeScreen(w, sr, opts.want_attrs),
            .regions => |rg| try self.writeRegions(w, rg),
            .disasm => |dr| try self.writeDisasm(w, dr),
            .devices => |d| {
                if (opts.device) |dev| {
                    var snap = d;
                    if (!opts.want_palette) snap.vga.palette = null;
                    // `device` is validated against the allowlist before dispatch, so
                    // this always matches; ignore the bool.
                    _ = try self.writeNamedDevice(w, snap, dev);
                } else {
                    try self.writeDevices(w, d, opts.want_palette);
                }
            },
            .io_shadow => |io| try self.writeIoShadow(w, io),
            .search => |sr| try self.writeSearch(w, sr, opts.search_needle),
            // Pre-handled by every caller (see the doc comment). Reaching here is a bug.
            .err, .framebuffer => unreachable,
        }
    }

    /// Serialize the grouped device snapshot. The whole POD is JSON-Stringify-able
    /// (enums → strings, fixed arrays → arrays); the only server-side shaping is
    /// nulling the bulky DAC palette unless `palette` was requested.
    fn writeDevices(self: *Conn, w: *std.Io.Writer, d: debug.DevicesSnapshot, want_palette: bool) std.Io.Writer.Error!void {
        var snap = d;
        if (!want_palette) snap.vga.palette = null;
        try self.writeValue(w, snap);
    }

    fn respondDevices(self: *Conn, req: *http.Server.Request, d: debug.DevicesSnapshot, want_palette: bool) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeDevices(&w, d, want_palette) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Write one device group by name into `w`; returns false (writing nothing) when the
    /// name is unknown. The ONE name→field dispatch authority, shared by the HTTP
    /// `/api/device/<name>` route (404 on false) and the MCP `read_devices {device}`
    /// selector via `writeResponseBody`.
    fn writeNamedDevice(self: *Conn, w: *std.Io.Writer, snap: debug.DevicesSnapshot, name: []const u8) std.Io.Writer.Error!bool {
        if (std.mem.eql(u8, name, "a20")) {
            try self.writeValue(w, snap.a20);
        } else if (std.mem.eql(u8, name, "pic")) {
            try self.writeValue(w, snap.pic);
        } else if (std.mem.eql(u8, name, "pit")) {
            try self.writeValue(w, snap.pit);
        } else if (std.mem.eql(u8, name, "vga")) {
            try self.writeValue(w, snap.vga);
        } else if (std.mem.eql(u8, name, "kbc")) {
            try self.writeValue(w, snap.kbc);
        } else if (std.mem.eql(u8, name, "speaker")) {
            try self.writeValue(w, snap.speaker);
        } else if (std.mem.eql(u8, name, "opl")) {
            try self.writeValue(w, snap.opl);
        } else if (std.mem.eql(u8, name, "ems")) {
            try self.writeValue(w, snap.ems);
        } else {
            return false;
        }
        return true;
    }

    /// `{"port":N,"value":"0xNN"|null,"shadow":true,"note":"..."}` — the I/O-port
    /// shadow. `shadow:true` + the `/api/io` name (not `/api/in`) make explicit this
    /// is a non-mutating VIEW, never a live read (a live `in` would advance the DAC
    /// index / pop the 8042 FIFO / flip the AC flip-flop).
    fn writeIoShadow(self: *Conn, w: *std.Io.Writer, io: debug.IoShadow) std.Io.Writer.Error!void {
        _ = self;
        if (io.value) |v| {
            try w.print("{{\"port\":{d},\"value\":\"0x{x:0>2}\",\"shadow\":true,", .{ io.port, v });
        } else {
            try w.print("{{\"port\":{d},\"value\":null,\"shadow\":true,", .{io.port});
        }
        try w.writeAll("\"note\":\"non-mutating view; a live IN may differ for stateful ports (DAC index advance, FIFO pop, AC flip-flop)\"}");
    }

    fn respondIoShadow(self: *Conn, req: *http.Server.Request, io: debug.IoShadow) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeIoShadow(&w, io) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Pure body-builder (mcp-plan.md §3.2): write `v` as the project-standard JSON into
    /// `w`. The HTTP `respondValue` wrapper and `handleMcp` (the MCP front-end) BOTH call
    /// this, so the bytes are byte-identical across the two transports (the anti-drift
    /// requirement, pinned by the equivalence tests). No host time, no allocation.
    fn writeValue(self: *Conn, w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
        _ = self;
        try std.json.Stringify.value(v, wire.stringify_options, w);
    }

    fn respondValue(self: *Conn, req: *http.Server.Request, status: http.Status, v: anytype) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeValue(&w, v) catch return self.respondError(req, .service_unavailable, "internal", "response too large to serialize");
        self.respondJson(req, status, w.buffered());
    }

    fn writeBpList(self: *Conn, w: *std.Io.Writer, l: q.BpListResult) std.Io.Writer.Error!void {
        _ = self;
        // Build {"breakpoints":[...]} with the inline items (ascending id order).
        try w.writeAll("{\"breakpoints\":");
        try std.json.Stringify.value(l.items[0..l.count], wire.stringify_options, w);
        try w.writeAll("}");
    }

    fn respondBpList(self: *Conn, req: *http.Server.Request, l: q.BpListResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeBpList(&w, l) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn writeRegions(self: *Conn, w: *std.Io.Writer, rg: q.RegionsResult) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("{\"regions\":");
        try std.json.Stringify.value(rg.items[0..rg.count], wire.stringify_options, w);
        try w.writeAll("}");
    }

    fn respondRegions(self: *Conn, req: *http.Server.Request, rg: q.RegionsResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeRegions(&w, rg) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Pure body-builder (mcp-plan.md §3.2) for a memory peek: `{"phys":N,"len":N,
    /// "data":"<hex>"}`. Shared by the HTTP `respondMem` wrapper and `handleMcp` so the
    /// `read_memory` tool body == the `GET /api/mem` body byte-for-byte (anti-drift).
    fn writeMem(self: *Conn, w: *std.Io.Writer, mr: q.MemResult) std.Io.Writer.Error!void {
        _ = self;
        var hex_buf: [q.MAX_MEM_CHUNK * 2]u8 = undefined;
        // `mr.len` is worker-bounded to MAX_MEM_CHUNK, so the encode never overflows.
        const hex = wire.hexEncode(&hex_buf, mr.bytes[0..mr.len]) catch unreachable;
        try w.print("{{\"phys\":{d},\"len\":{d},\"data\":\"{s}\"}}", .{ mr.phys, mr.len, hex });
    }

    fn respondMem(self: *Conn, req: *http.Server.Request, mr: q.MemResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeMem(&w, mr) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn writeConsole(self: *Conn, w: *std.Io.Writer, cr: q.ConsoleResult) std.Io.Writer.Error!void {
        _ = self;
        // {"len":N,"data":"<hex>"} — hex so arbitrary CON bytes (control chars, NULs)
        // survive JSON intact (mirrors the /api/mem encoding). `cr.len` is worker-bounded
        // to MAX_CONSOLE, so the encode never overflows.
        var hex_buf: [q.MAX_CONSOLE * 2]u8 = undefined;
        const hex = wire.hexEncode(&hex_buf, cr.bytes[0..cr.len]) catch unreachable;
        try w.print("{{\"len\":{d},\"data\":\"{s}\"}}", .{ cr.len, hex });
    }

    fn respondConsole(self: *Conn, req: *http.Server.Request, cr: q.ConsoleResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeConsole(&w, cr) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Serialize a text-screen grid (§4.1). `text` = `rows` rows joined by '\n',
    /// each row = the `cols` cell CHARACTERS (cell byte0), JSON-escaped (raw CP437
    /// bytes survive; the consumer decodes glyphs). `attrs` (the cell byte1 array,
    /// lowercase hex) is emitted only when `want_attrs` is set (D-TM4); otherwise
    /// the field is null. Cursor/mode/cols/rows come straight from the BDA scalars.
    fn writeScreen(self: *Conn, w: *std.Io.Writer, sr: q.ScreenResult, want_attrs: bool) std.Io.Writer.Error!void {
        _ = self;
        const cols = sr.cols;
        const rows = sr.rows;
        try w.print("{{\"cols\":{d},\"rows\":{d},\"mode\":{d},\"cursor\":{{\"row\":{d},\"col\":{d},\"page\":{d}}},\"text\":", .{
            cols, rows, sr.mode, sr.cursor_row, sr.cursor_col, sr.active_page,
        });
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
        try std.json.Stringify.value(text_buf[0..tlen], wire.stringify_options, w);
        if (want_attrs) {
            // Parallel attribute array as lowercase hex (cell byte1, in row-major
            // order — cols*rows bytes).
            try w.writeAll(",\"attrs\":\"");
            var i: usize = 1;
            while (i < sr.len) : (i += 2) {
                try w.writeByte("0123456789abcdef"[sr.cells[i] >> 4]);
                try w.writeByte("0123456789abcdef"[sr.cells[i] & 0x0F]);
            }
            try w.writeAll("\"");
        } else {
            try w.writeAll(",\"attrs\":null");
        }
        try w.writeAll("}");
    }

    fn respondScreen(self: *Conn, req: *http.Server.Request, sr: q.ScreenResult, want_attrs: bool) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeScreen(&w, sr, want_attrs) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    /// Serialize a disassembly window:
    /// `{"count":N,"instructions":[{"linear":N,"seg":N|null,"off":N|null,
    ///   "bytes":"<hex>","length":N,"text":"..."},...]}`
    /// `seg`/`off` are null for the `?linear=` origin (no segment context).
    fn writeDisasm(self: *Conn, w: *std.Io.Writer, dr: debug.DisasmResult) std.Io.Writer.Error!void {
        _ = self;
        try w.print("{{\"count\":{d},\"instructions\":[", .{dr.count});
        for (dr.items[0..dr.count], 0..) |insn, i| {
            if (i != 0) try w.writeAll(",");
            try w.print("{{\"linear\":{d},", .{insn.linear});
            if (insn.has_seg) {
                try w.print("\"seg\":{d},\"off\":{d},", .{ insn.seg, insn.off });
            } else {
                try w.writeAll("\"seg\":null,\"off\":null,");
            }
            try w.writeAll("\"bytes\":\"");
            for (insn.bytes[0..insn.len]) |b| {
                try w.writeByte("0123456789abcdef"[b >> 4]);
                try w.writeByte("0123456789abcdef"[b & 0x0F]);
            }
            try w.print("\",\"length\":{d},\"text\":", .{insn.len});
            try std.json.Stringify.value(insn.text[0..insn.text_len], wire.stringify_options, w);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }

    fn respondDisasm(self: *Conn, req: *http.Server.Request, dr: debug.DisasmResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeDisasm(&w, dr) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    fn writeStack(self: *Conn, w: *std.Io.Writer, s: q.StackResult) std.Io.Writer.Error!void {
        _ = self;
        try w.print("{{\"count\":{d},\"words\":", .{s.count});
        try std.json.Stringify.value(s.words[0..s.count], wire.stringify_options, w);
        try w.writeAll("}");
    }

    fn respondStack(self: *Conn, req: *http.Server.Request, s: q.StackResult) void {
        var w = std.Io.Writer.fixed(self.resp_buf[0..]);
        self.writeStack(&w, s) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
        self.respondJson(req, .ok, w.buffered());
    }

    // -----------------------------------------------------------------------
    // The code → HTTP status mapping lives ONLY here (D20).
    // -----------------------------------------------------------------------

    /// The ONE source of truth mapping a transport-neutral `q.ErrCode` to its HTTP
    /// status + stable string code + message (mcp-plan.md §3.2). `respondErrCode` (the
    /// HTTP path) uses all three; `handleMcp` (the MCP path) uses `.code`/`.msg` to build
    /// the `isError` tool-result content. Extracted so the two front-ends can never drift.
    const ErrInfo = struct { status: http.Status, code: []const u8, msg: []const u8 };

    fn errInfo(code: q.ErrCode) ErrInfo {
        return switch (code) {
            .breakpoint_table_full => .{ .status = .service_unavailable, .code = "breakpoint_table_full", .msg = "all breakpoint slots are in use" },
            .no_such_breakpoint => .{ .status = .not_found, .code = "no_such_breakpoint", .msg = "no breakpoint with that id" },
            .address_out_of_range => .{ .status = .bad_request, .code = "address_out_of_range", .msg = "memory range not contained in the addressable slab" },
            .out_of_range => .{ .status = .bad_request, .code = "out_of_range", .msg = "length/count/value exceeds the bounded cap" },
            .bad_request => .{ .status = .bad_request, .code = "bad_request", .msg = "malformed request" },
            .not_implemented => .{ .status = .not_implemented, .code = "not_implemented", .msg = "operation not implemented" },
            .load_failed => .{ .status = .service_unavailable, .code = "load_failed", .msg = "failed to load the program" },
            // A full 8042 output FIFO is a transient resource limit -> 503 (the
            // breakpoint_table_full idiom, input-injection.md §5.1b); `run` to drain
            // the controller via INT 09h, then retry.
            .input_buffer_full => .{ .status = .service_unavailable, .code = "input_buffer_full", .msg = "the 8042 keyboard output buffer is full" },
        };
    }

    fn respondErrCode(self: *Conn, req: *http.Server.Request, code: q.ErrCode) void {
        const info = errInfo(code);
        self.respondError(req, info.status, info.code, info.msg);
    }

    fn badJson(self: *Conn, req: *http.Server.Request) void {
        self.respondError(req, .bad_request, "bad_request", "malformed JSON body");
    }
    fn badEnum(self: *Conn, req: *http.Server.Request) void {
        self.respondError(req, .bad_request, "bad_request", "unknown register/segment name");
    }
    fn methodNotAllowed(self: *Conn, req: *http.Server.Request) void {
        self.respondError(req, .method_not_allowed, "method_not_allowed", "method not allowed on this endpoint");
    }

    fn respondError(self: *Conn, req: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) void {
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

    fn respondJson(self: *Conn, req: *http.Server.Request, status: http.Status, body: []const u8) void {
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
    fn serveStatic(self: *Conn, req: *http.Server.Request, m: http.Method, path: []const u8, body: []const u8) void {
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
