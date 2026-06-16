//! `Session` — the black-box test harness for the zdos debugger HTTP API.
//!
//! Each `Session` spawns the REAL built binary `./zig-out/bin/zdos --serve 0 <exe>`
//! as a child process (full process isolation), parses the OS-assigned ephemeral
//! port from the child's stderr banner, and drives the API as a real HTTP/1.1 client
//! over a localhost socket. It is a TRUE black box: it never imports the emulator
//! internals — it only speaks the wire protocol, exactly as an external tool would.
//!
//! Determinism note: the only host-time dependence here is TEST infrastructure — the
//! bounded `/api/health` readiness poll and the bounded banner read. Neither touches
//! emulation: the guest advances ONLY in response to explicit `run`/`step` commands,
//! each carrying a deterministic budget, so two sessions issuing the same command
//! sequence reach byte-identical machine state regardless of network/spawn jitter.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `std.process.spawn(io, .{ .argv, .stderr = .pipe })` → `Child` with
//!     `child.stderr: ?File` (`process.zig:442`, `process/Child.zig:31`).
//!   - `Child.kill(io)` forcibly terminates AND reaps (idempotent) (`Child.zig:118`).
//!   - `File.reader(io, buf) Reader` (`Io/File.zig:566`); `Reader.readSliceShort`.
//!   - `std.http.Client{ .allocator, .io }`; `client.fetch(.{ .location=.{.url=…},
//!     .method, .payload, .extra_headers, .response_writer })` returns
//!     `{ status }` (`http/Client.zig:1801`).
//!   - `std.Io.Writer.Allocating.init(alloc)` to capture the response body
//!     (`Io/Writer.zig:2506`); `.written()` / `.deinit()`.
//!   - `std.json.parseFromSlice(T, alloc, body, opts)` (`json/static.zig:73`).

const std = @import("std");
const api = @import("api");
const debug = @import("debug");

const Io = std.Io;
const http = std.http;

/// The wire request structs — imported from the REAL `src/api/json_wire.zig` so a
/// wire-format change FAILS TO COMPILE here (compile-time coupling to the contract).
pub const wire = api.wire;
/// `BreakpointKind` is the SAME core type the server parses (`src/debug`), so a
/// breakpoint-shape change breaks compilation here.
pub const BreakpointKind = debug.BreakpointKind;

const json_ct = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};

/// One HTTP response: status + the owned body bytes (in the caller's arena).
pub const Resp = struct {
    status: http.Status,
    body: []u8,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    client: http.Client,
    port: u16,
    /// `http://127.0.0.1:<port>` — the URL prefix for every request.
    base: []u8,
    /// Per-request scratch arena (parsed responses + URL building); reset between
    /// requests so a long session does not grow without bound.
    arena: std.heap.ArenaAllocator,

    /// Spawn `./zig-out/bin/zdos --serve 0 <exe_path>`, parse the ephemeral port from
    /// the stderr banner, and poll `/api/health` until the server answers.
    pub fn spawn(gpa: std.mem.Allocator, io: Io, exe_path: []const u8) !Session {
        return spawnArgs(gpa, io, exe_path, &.{});
    }

    /// Like `spawn`, but appends `guest_args` after `exe_path` on the zdos command
    /// line. zdos forwards extra CLI args as the guest DOS command tail (e.g. passing
    /// `&.{"headless"}` runs the TTM movie without the trailing BIOS-tick end-hold).
    pub fn spawnArgs(gpa: std.mem.Allocator, io: Io, exe_path: []const u8, guest_args: []const []const u8) !Session {
        // argv = { "./zig-out/bin/zdos", "--serve", "0", exe_path } ++ guest_args.
        const argv = try gpa.alloc([]const u8, 4 + guest_args.len);
        defer gpa.free(argv);
        argv[0] = "./zig-out/bin/zdos";
        argv[1] = "--serve";
        argv[2] = "0";
        argv[3] = exe_path;
        for (guest_args, 0..) |arg, i| argv[4 + i] = arg;

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdout = .ignore, // the guest prints CON output only on run-to-termination
            .stderr = .pipe, // the `[zdos] listening 127.0.0.1:<PORT>` banner lands here
        });
        errdefer child.kill(io);

        const port = try readBannerPort(io, child.stderr.?);

        var self: Session = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .client = .{ .allocator = gpa, .io = io },
            .port = port,
            .base = undefined,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        self.base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
        errdefer gpa.free(self.base);

        try self.waitReady();
        return self;
    }

    /// Terminate the child cleanly (kill reaps it; idempotent) and free resources.
    /// Mirrors `server_integration_test.zig`'s teardown discipline: no leaked process.
    pub fn deinit(self: *Session) void {
        // Drain+close the stderr pipe so the kill has nothing dangling, then kill.
        if (self.child.stderr) |f| {
            f.close(self.io);
            self.child.stderr = null;
        }
        self.child.kill(self.io);
        self.client.deinit();
        self.gpa.free(self.base);
        self.arena.deinit();
    }

    // -----------------------------------------------------------------------
    // Raw transport: one HTTP request, body captured into the per-request arena.
    // -----------------------------------------------------------------------

    /// Issue `method path` with optional `payload`; returns the status + the owned
    /// response body (lives in the session arena until the next request resets it).
    ///
    /// Uses the lower-level `client.request` + `sendBodyComplete`/`sendBodiless` path
    /// rather than `client.fetch`: `fetch` sends a content-length body through a
    /// ZERO-length `BodyWriter` buffer (`Client.zig:1823` passes `&.{}`), which panics
    /// in `contentLengthDrain` for our small JSON payloads. `sendBodyComplete(payload)`
    /// sets the body writer's `end = body.len` directly and avoids that path.
    pub fn requestRaw(self: *Session, method: http.Method, path: []const u8, payload: ?[]const u8) !Resp {
        // `path`/`payload` may themselves live in the session arena (built by a
        // convenience wrapper), and we reset that arena here — so copy them onto the
        // STACK first (stack memory survives the reset), THEN reset, THEN use.
        var path_buf: [1024]u8 = undefined;
        var pay_buf: [8192]u8 = undefined;
        if (path.len > path_buf.len or payload != null and payload.?.len > pay_buf.len) return error.RequestTooLong;
        @memcpy(path_buf[0..path.len], path);
        const path_s = path_buf[0..path.len];
        var pay_s: ?[]u8 = null;
        if (payload) |p| {
            @memcpy(pay_buf[0..p.len], p);
            pay_s = pay_buf[0..p.len];
        }

        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ self.base, path_s });
        const uri = try std.Uri.parse(url);

        // POST/PATCH always carry a body (the API contract allows an empty `{}`-like
        // body; we send a zero-length content-length body for the no-payload case
        // rather than `sendBodiless`, which asserts the method has no body and would
        // trip for POST/PATCH).
        const has_body = method.requestHasBody();
        var req = try self.client.request(method, uri, .{
            .keep_alive = false, // one request per connection (the server closes; R1)
            .extra_headers = if (pay_s != null) &json_ct else &.{},
            .redirect_behavior = .unhandled, // the API never redirects
        });
        defer req.deinit();

        if (has_body) {
            const body = pay_s orelse pay_buf[0..0]; // zero-length body for empty POST/PATCH
            req.transfer_encoding = .{ .content_length = body.len };
            try req.sendBodyComplete(body);
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Stream the (identity-encoded) JSON body into an owned arena buffer.
        var body_alloc: std.Io.Writer.Allocating = .init(a);
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        _ = reader.streamRemaining(&body_alloc.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{ .status = response.head.status, .body = body_alloc.written() };
    }

    /// Assert a 2xx status and parse the body into `RespT` (in the session arena).
    pub fn parseOk(self: *Session, comptime RespT: type, r: Resp) !RespT {
        if (@intFromEnum(r.status) < 200 or @intFromEnum(r.status) >= 300) {
            std.debug.print("unexpected HTTP {d}: {s}\n", .{ @intFromEnum(r.status), r.body });
            return error.UnexpectedStatus;
        }
        const parsed = try std.json.parseFromSliceLeaky(RespT, self.arena.allocator(), r.body, .{ .ignore_unknown_fields = true });
        return parsed;
    }

    // -----------------------------------------------------------------------
    // Typed request helpers. `post`/`get` reuse the REAL wire structs so a
    // contract change breaks compilation here.
    // -----------------------------------------------------------------------

    /// POST `path` with `req` (a wire request struct, JSON-encoded) → parse `RespT`.
    pub fn post(self: *Session, path: []const u8, req: anytype, comptime RespT: type) !RespT {
        const payload = try std.json.Stringify.valueAlloc(self.arena.allocator(), req, .{});
        const r = try self.requestRaw(.POST, path, payload);
        return self.parseOk(RespT, r);
    }

    /// POST `path` with NO body → parse `RespT`.
    pub fn postEmpty(self: *Session, path: []const u8, comptime RespT: type) !RespT {
        const r = try self.requestRaw(.POST, path, null);
        return self.parseOk(RespT, r);
    }

    /// GET `path` → parse `RespT`.
    pub fn get(self: *Session, path: []const u8, comptime RespT: type) !RespT {
        const r = try self.requestRaw(.GET, path, null);
        return self.parseOk(RespT, r);
    }

    /// Raw status code for a method+path (for asserting 404/501/etc.). The body is
    /// returned too so a test can assert the typed error `code`.
    pub fn rawStatus(self: *Session, method: http.Method, path: []const u8, payload: ?[]const u8) !Resp {
        return self.requestRaw(method, path, payload);
    }

    // -----------------------------------------------------------------------
    // Convenience wrappers (each one HTTP round-trip).
    // -----------------------------------------------------------------------

    pub const StopResp = struct { stop: WireStop };
    /// A `StopReason` as it appears on the wire — a `{"<tag>":payload}` object. We
    /// only decode the fields the tests assert (id/at_cycle); unknown fields ignored.
    pub const WireStop = struct {
        breakpoint: ?struct { id: u32, at_cycle: u64 } = null,
        step_complete: ?struct { at_cycle: u64 } = null,
        cycle_budget_exhausted: ?struct { at_cycle: u64 } = null,
        program_terminated: ?struct { ret_code: u16 } = null,
        // `halted_forever` / `shutdown` are void-payload tags → `{}`; if present they
        // appear as the object's single key. We do not model them as fields (the
        // tests that need them assert via rawStatus/body).
    };

    pub const CpuSnapshot = debug.CpuSnapshot;
    pub const Status = struct {
        runnable: bool,
        terminated: bool,
        ret_code: u16,
        cycles: u64,
        last_stop: ?WireStop = null,
    };
    pub const BpId = struct { id: u32 };
    pub const Mem = struct { phys: u32, len: u32, data: []const u8 };
    pub const Ivt = struct { vector: u8, ip: u16, cs: u16 };
    pub const Ok = struct { ok: bool };
    /// `GET /api/console` — the guest's accumulated CON output as a `{len, data}`
    /// object where `data` is lowercase hex (so arbitrary CON bytes survive JSON).
    pub const Console = struct { len: u32, data: []const u8 };

    pub fn status(self: *Session) !Status {
        return self.get("/api/status", Status);
    }
    pub fn cpu(self: *Session) !CpuSnapshot {
        return self.get("/api/cpu", CpuSnapshot);
    }
    pub fn step(self: *Session) !StopResp {
        return self.postEmpty("/api/step", StopResp);
    }
    pub fn stepN(self: *Session, n: u64) !StopResp {
        return self.post("/api/step-n", wire.StepNReq{ .n = n }, StopResp);
    }
    pub fn run(self: *Session, cycle_cap: ?u64) !StopResp {
        return self.post("/api/run", wire.RunReq{ .cycle_cap = cycle_cap }, StopResp);
    }
    pub fn runToCycle(self: *Session, c: u64) !StopResp {
        return self.post("/api/run-to-cycle", wire.RunToCycleReq{ .cycle = c }, StopResp);
    }
    pub fn runToAddress(self: *Session, linear: u32) !StopResp {
        return self.post("/api/run-to-address", wire.RunToAddrReq{ .linear = linear }, StopResp);
    }
    pub fn addBreakpoint(self: *Session, kind: BreakpointKind, one_shot: bool) !BpId {
        return self.post("/api/breakpoints", wire.AddBpReq{ .kind = kind, .one_shot = one_shot }, BpId);
    }
    pub fn mem(self: *Session, phys: u32, len: u32) !Mem {
        const path = try std.fmt.allocPrint(self.arena.allocator(), "/api/mem?phys={d}&len={d}", .{ phys, len });
        return self.get(path, Mem);
    }
    pub fn ivt(self: *Session, vector: u8) !Ivt {
        const path = try std.fmt.allocPrint(self.arena.allocator(), "/api/ivt/{d}", .{vector});
        return self.get(path, Ivt);
    }
    pub fn reset(self: *Session) !Ok {
        return self.postEmpty("/api/reset", Ok);
    }
    pub fn load(self: *Session) !Ok {
        // Empty body → re-load the server-held startup recipe (the documented
        // `POST /api/load {}` semantics).
        return self.postEmpty("/api/load", Ok);
    }
    // -----------------------------------------------------------------------
    // Input injection (POST /api/input/key, /api/input/mouse) + CON readback.
    // Each injection mutates input state at the one-command-in-flight boundary
    // (Model A, input-injection.md §2.1); the NEXT `run`/`step` delivers it.
    // -----------------------------------------------------------------------

    /// Inject a single precise scancode EDGE (input-injection.md §5.1). `make` true
    /// = key-down (raw set-1 code), false = key-up (break = code|0x80); `ext` = the
    /// 0xE0 extended prefix. Pushes the byte at the 8042 + raises IRQ1; the guest
    /// INT 09h ISR cooks it into the BDA ring on the next run.
    pub fn injectKey(self: *Session, scancode: u8, make: bool, ext: bool) !Ok {
        return self.post("/api/input/key", wire.KeyReq{ .scancode = scancode, .make = make, .ext = ext }, Ok);
    }

    /// Inject a full keystroke by CHARACTER (the `{"char"}` convenience): the server
    /// resolves the char to its set-1 scancode (+ a Shift bracket when needed) over
    /// the REAL scancode table and injects make+break as one deterministic command.
    pub fn injectKeyChar(self: *Session, ch: u8) !Ok {
        const s = [_]u8{ch};
        return self.post("/api/input/key", wire.KeyReq{ .char = &s }, Ok);
    }

    /// Inject a mouse event into the INT 33h driver (input-injection.md §5.2). Any
    /// subset of absolute position (x/y), relative motion (dx/dy), and the button
    /// mask; a null field is left unset. Absolute and relative are mutually exclusive
    /// per axis at the server (mixing x+dx / y+dy is a 400).
    pub fn injectMouse(self: *Session, x: ?i16, y: ?i16, dx: ?i16, dy: ?i16, buttons: ?u16) !Ok {
        return self.post("/api/input/mouse", wire.MouseReq{ .x = x, .y = y, .dx = dx, .dy = dy, .buttons = buttons }, Ok);
    }

    /// `GET /api/console` → the raw `{len, data(hex)}` object (side-effect-free read
    /// of what the guest has printed to CON so far).
    pub fn console(self: *Session) !Console {
        return self.get("/api/console", Console);
    }

    /// `GET /api/screen` — the active VGA text page as a `{cols,rows,mode,cursor,
    /// text,attrs}` object. `text` is the cols×rows grid (rows joined by '\n'),
    /// `attrs` is null unless `?attrs=1` was requested. Pass `attrs=true` for the
    /// attribute array (lowercase hex).
    pub const ScreenCursor = struct { row: u16, col: u16, page: u8 };
    pub const Screen = struct {
        cols: u16,
        rows: u16,
        mode: u8,
        cursor: ScreenCursor,
        text: []const u8,
        attrs: ?[]const u8 = null,
    };
    pub fn screen(self: *Session, attrs: bool) !Screen {
        const path = if (attrs) "/api/screen?attrs=1" else "/api/screen";
        return self.get(path, Screen);
    }

    /// `GET /api/console`, hex-decoded into `out`; returns the decoded prefix (in
    /// `out`). The CON output as the raw bytes the guest printed.
    pub fn consoleBytes(self: *Session, out: []u8) ![]u8 {
        const c = try self.console();
        if (c.data.len % 2 != 0) return error.BadConsoleHex;
        const n = c.data.len / 2;
        if (n > out.len) return error.ConsoleBufferTooSmall;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = (try hexNibble(c.data[i * 2]) << 4) | try hexNibble(c.data[i * 2 + 1]);
        }
        return out[0..n];
    }

    fn hexNibble(ch: u8) !u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => error.BadConsoleHex,
        };
    }

    pub fn setReg32(self: *Session, name: []const u8, value: u32) !Ok {
        const req = wire.RegSetReq{ .reg32 = .{ .name = name, .value = value } };
        const payload = try std.json.Stringify.valueAlloc(self.arena.allocator(), req, .{});
        const r = try self.requestRaw(.PATCH, "/api/cpu/reg", payload);
        return self.parseOk(Ok, r);
    }

    // -----------------------------------------------------------------------
    // Spawn-time helpers (TEST infra; bounded host-time waits — NOT emulation).
    // -----------------------------------------------------------------------

    /// Read the child's stderr until the `[zdos] listening 127.0.0.1:<PORT>` banner
    /// line is seen; return the parsed port. Uses `File.readStreaming` (ONE read per
    /// call, returning whatever bytes are AVAILABLE) — NOT the buffered Reader's
    /// `readSliceShort`, which loops until the full buffer is filled and would block
    /// forever here (the server prints ~36 bytes, then blocks on accept with nothing
    /// more to emit). EOF (n==0) means the child died before announcing → error.
    fn readBannerPort(io: Io, stderr: std.Io.File) !u16 {
        const marker = "listening 127.0.0.1:";
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = stderr.readStreaming(io, &.{buf[total..]}) catch break;
            if (n == 0) break; // EOF — child exited before announcing
            total += n;
            const seen = buf[0..total];
            if (std.mem.indexOf(u8, seen, marker)) |i| {
                const after = seen[i + marker.len ..];
                const end = std.mem.indexOfScalar(u8, after, '\n') orelse continue; // wait for the full line
                return std.fmt.parseInt(u16, std.mem.trim(u8, after[0..end], " \r"), 10) catch return error.BadBannerPort;
            }
        }
        return error.NoBanner;
    }

    /// Poll `GET /api/health` until it returns 200. Bounded retries (TEST infra).
    fn waitReady(self: *Session) !void {
        var attempt: usize = 0;
        while (attempt < 500) : (attempt += 1) {
            const r = self.requestRaw(.GET, "/api/health", null) catch {
                std.Thread.yield() catch {};
                continue;
            };
            if (r.status == .ok) return;
            std.Thread.yield() catch {};
        }
        return error.ServerNotReady;
    }
};
