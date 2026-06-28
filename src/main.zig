//! zdos — a minimal headless runner frontend.
//!
//! Loads a real-mode DOS program (`.COM`/`.EXE`) from the host filesystem through
//! the emulated DOS loader, runs it to termination, and dumps whatever the program
//! wrote to the CON device (INT 21h AH=02/06/09, handle 1) to the host stdout.
//!
//! Determinism note: the CON output is captured in an internal buffer during the
//! run (never live host stdout — that would couple emulation to host I/O), and
//! flushed once at exit. The run itself touches no host clock.
//!
//! Usage: `zig build run -- <path/to/PROGRAM.COM>`  (or a `.EXE`)

const std = @import("std");
const machine_mod = @import("machine");
const debug_mod = @import("debug");
const api_mod = @import("api");
const host_mod = @import("host");

const Machine = machine_mod.Machine;
const Controller = debug_mod.Controller;

/// Stop the run once the initial process terminates (INT 21h AH=4C / INT 20h) or
/// the CPU halts with no way to wake (`halted_forever` lands here via `halted`).
fn untilDone(m: *Machine) bool {
    return m.cpu.st.halted or m.dos.terminated;
}

/// Parse a dotted-quad IPv4 (`"0.0.0.0"`, `"127.0.0.1"`) into 4 bytes. Returns null on any
/// malformed input (wrong field count, non-numeric, > 255).
fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null; // too many fields
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null; // exactly four fields required
}

/// Parse the `--host` argument into a bind address. Accepts a dotted IPv4 (e.g. `0.0.0.0`,
/// `127.0.0.1`) or the IPv6 wildcard `::` (dual-stack on Linux — accepts IPv6 AND IPv4, so
/// it is the right choice to reach the server by an IPv6-only hostname). Null = unparseable.
fn parseBindHost(s: []const u8) ?api_mod.Server.BindHost {
    if (std.mem.eql(u8, s, "::")) return .{ .ip6 = @splat(0) }; // IPv6 any (::)
    if (parseIp4(s)) |b| return .{ .ip4 = b };
    return null;
}

/// Format a bind host for the (informational, URL-shaped) listen banner. IPv6 is only ever
/// the `::` wildcard here, so it prints as the URL-bracketed `[::]`.
fn fmtBindHost(host: api_mod.Server.BindHost, buf: []u8) []const u8 {
    return switch (host) {
        .ip4 => |b| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch "?",
        .ip6 => "[::]",
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    // ---- args: [--break-cycle N] <PROGRAM> [guest args...] ------------------
    // The optional `--break-cycle N` flag (debugger opt-in) constructs a
    // Controller and stops the run deterministically at the first instruction
    // boundary at/after cycle N, dumping a CPU snapshot — instead of running to
    // termination. The default path (no flag) is unchanged.
    const usage = "usage: zig build run -- [--break-cycle N <PROGRAM> | --serve PORT [PROGRAM]] <PROGRAM.COM|PROGRAM.EXE> [args...]\n";
    var args_it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next(); // skip argv[0]
    var break_cycle: ?u64 = null;
    var serve_port: ?u16 = null;
    // The address the `--serve` listener binds. Loopback by default (this-host-only); `--host
    // 0.0.0.0` (IPv4 LAN) or `--host ::` (IPv6/dual-stack) opens it up. Reachability only.
    var serve_host: api_mod.Server.BindHost = .{ .ip4 = .{ 127, 0, 0, 1 } };
    // The guest program path. NULL only on the EMPTY-START path (`--serve PORT` with no
    // program) — every other mode requires a program and exits below if it is missing.
    var path: ?[]const u8 = null;
    const first = args_it.next() orelse {
        try stderr.writeStreamingAll(io, usage);
        std.process.exit(2);
    };
    if (std.mem.eql(u8, first, "--break-cycle")) {
        const n_str = args_it.next() orelse {
            try stderr.writeStreamingAll(io, "zdos: --break-cycle requires a cycle count\n");
            std.process.exit(2);
        };
        break_cycle = std.fmt.parseInt(u64, n_str, 10) catch {
            try stderr.writeStreamingAll(io, "zdos: --break-cycle expects a non-negative integer\n");
            std.process.exit(2);
        };
        path = args_it.next() orelse {
            try stderr.writeStreamingAll(io, usage);
            std.process.exit(2);
        };
    } else if (std.mem.eql(u8, first, "--serve")) {
        const p_str = args_it.next() orelse {
            try stderr.writeStreamingAll(io, "zdos: --serve requires a port\n");
            std.process.exit(2);
        };
        serve_port = std.fmt.parseInt(u16, p_str, 10) catch {
            try stderr.writeStreamingAll(io, "zdos: --serve expects a port number (1-65535)\n");
            std.process.exit(2);
        };
        // The PROGRAM is OPTIONAL under `--serve` (the EMPTY-START inversion, agent-
        // provisioning-plan §6): `--serve PORT` with no program starts EMPTY (no default
        // machine — an agent provisions machines on demand); `--serve PORT PROGRAM` auto-
        // provisions the default machine exactly as before.
        if (args_it.next()) |tok0| {
            var tok: ?[]const u8 = tok0;
            // OPTIONAL `--host ADDR` immediately after the port (before any PROGRAM):
            // binds the listener to ADDR instead of loopback (e.g. `0.0.0.0` for LAN access).
            if (std.mem.eql(u8, tok0, "--host")) {
                const h = args_it.next() orelse {
                    try stderr.writeStreamingAll(io, "zdos: --host requires an IPv4 address\n");
                    std.process.exit(2);
                };
                serve_host = parseBindHost(h) orelse {
                    try stderr.writeStreamingAll(io, "zdos: --host expects an IPv4 (e.g. 0.0.0.0) or :: (IPv6/dual-stack)\n");
                    std.process.exit(2);
                };
                tok = args_it.next(); // advance to the PROGRAM (or null = empty start)
            }
            if (tok) |t| {
                // --break-cycle and --serve are mutually exclusive (one or the other path).
                if (std.mem.eql(u8, t, "--break-cycle")) {
                    try stderr.writeStreamingAll(io, "zdos: --serve and --break-cycle are mutually exclusive\n");
                    std.process.exit(2);
                }
                path = t;
            }
        }
    } else {
        path = first;
    }

    // ---- EMPTY-START: `--serve PORT` with no program (agent-provisioning-plan §6) -------
    // Stand up an EMPTY server — no default machine, no worker, no pacer, no stream. An
    // MCP-client agent provisions machines on demand over `/mcp` (`provision_machine`) and
    // drives each by the `machine` tool arg; `/api/health` answers off-worker meanwhile. This
    // returns before any machine/dir/boot work below (which is the default-machine path only).
    if (path == null) {
        const port = serve_port.?; // path is null ONLY on the --serve empty path
        var server = try api_mod.Server.initEmpty(gpa, io, port);
        defer server.deinit();
        server.bind_host = serve_host;
        server.bind() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve bind failed: {t}\n", .{err}) catch "zdos: --serve bind failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        var hbuf: [48]u8 = undefined;
        const hs = fmtBindHost(serve_host, &hbuf);
        var sbuf: [96]u8 = undefined;
        const banner = std.fmt.bufPrint(&sbuf, "\n[zdos] listening {s}:{d}\n", .{ hs, server.boundPort() }) catch "\n[zdos] listening\n";
        try stderr.writeStreamingAll(io, banner);
        var mbuf: [160]u8 = undefined;
        const mcp_banner = std.fmt.bufPrint(&mbuf, "[zdos] mcp endpoint: POST http://{s}:{d}/mcp (empty start — provision_machine to begin)\n", .{ hs, server.boundPort() }) catch "[zdos] mcp endpoint: POST /mcp (empty start)\n";
        try stderr.writeStreamingAll(io, mcp_banner);
        // The host-side MULTI-SESSION pacer (agent-provisioning live-play): there is no default
        // machine to pace, but an agent `provision_machine`s machines into the registry, and each
        // can be RUN IN REAL TIME (`/api/run/start` arms its clockless `RunControl`; a live stream
        // auto-arms it). This one thread paces every armed minted session through its gated queue
        // — the host CLOCK lives in `src/host/run_pacer.zig` (outside the api grep-gate, §5.1a),
        // so it never perturbs any cycle ledger. Joined BEFORE `server.deinit()` (the `defer`
        // below runs before the deferred `server.deinit`, which drains the minted workers), so no
        // slice can race a worker shutdown sentinel.
        var spacer: host_mod.SessionPacer = .{ .registry = server.sessionRegistry(), .io = io };
        spacer.start() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve session-pacer start failed: {t}\n", .{err}) catch "zdos: --serve session-pacer start failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        defer spacer.join();
        server.serve() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve failed: {t}\n", .{err}) catch "zdos: --serve failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        return;
    }
    const program = path.?; // non-null on every non-empty-start path

    // Any remaining host args become the guest DOS command tail (space-joined),
    // e.g. `... -- TCC.EXE -IINCLUDE HELLO.C` runs TCC with that command line.
    // psp.build formats the on-disk tail (count byte + leading space) to match
    // DOS, so the guest parses it exactly as it would under real DOS.
    var tail_buf: [127]u8 = undefined;
    var tail_len: usize = 0;
    while (args_it.next()) |a| {
        if (tail_len != 0 and tail_len < tail_buf.len) {
            tail_buf[tail_len] = ' ';
            tail_len += 1;
        }
        const n = @min(a.len, tail_buf.len - tail_len);
        @memcpy(tail_buf[tail_len .. tail_len + n], a[0..n]);
        tail_len += n;
    }
    const cmdtail = tail_buf[0..tail_len];

    // Split into a host directory (mounted as DOS drive C:) and the file name.
    const sep = std.mem.lastIndexOfScalar(u8, program, '/');
    const dir_path = if (sep) |s| program[0..s] else ".";
    const file_name = if (sep) |s| program[s + 1 ..] else program;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "zdos: cannot open directory '{s}': {t}\n", .{ dir_path, err }) catch "zdos: cannot open directory\n";
        try stderr.writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer dir.close(io);

    // ---- build the machine (heap-pinned: wire() captures self-pointers) ------
    const m = try gpa.create(Machine);
    defer {
        m.deinit();
        gpa.destroy(m);
    }
    try m.init(gpa, &.{}); // empty BIOS image -> POST stand-in
    m.wire();

    // ---- load + run ----------------------------------------------------------
    // The full fresh-launch boot sequence (post + mount C: + bootProgram). The
    // `--serve` path re-uses the SAME `Machine.boot` on `POST /api/load` after a
    // `POST /api/reset`, so reset→load→run reproduces this launch byte-identically.
    m.boot(2, dir, io, file_name, cmdtail) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "zdos: cannot load '{s}': {t}\n", .{ file_name, err }) catch "zdos: cannot load program\n";
        try stderr.writeStreamingAll(io, msg);
        std.process.exit(1);
    };

    if (serve_port) |port| {
        // Debugger HTTP/JSON server path (Milestone 2). Construct the Controller
        // over the already-wired machine (same construction as --break-cycle) and
        // run the accept loop. The server holds the load recipe captured here so a
        // `POST /api/load` can re-run `bootProgram` after a `POST /api/reset`. The
        // emulation core stays single-threaded — the server's worker thread is the
        // sole owner of the Controller; the listener never touches the machine.
        var ctrl = Controller.init(m);
        const recipe = api_mod.LoadRecipe.init(2, file_name, cmdtail);
        // The server holds the host mount `dir` (+ `io`) so a `POST /api/load` after
        // a `POST /api/reset` can re-establish the C: mount and re-run the full boot
        // (reset wipes the mount via `dos.init`). Re-mount happens server-side on the
        // worker thread (the sole owner of machine state) — see worker.zig loadResp.
        var server = try api_mod.Server.init(gpa, io, &ctrl, port, recipe, dir);
        defer server.deinit();
        server.bind_host = serve_host;

        // Bind first so we can print the OS-RESOLVED port (when `--serve 0` was
        // given, the kernel picks an ephemeral port). The banner line is in a
        // STABLE, parseable format the black-box test harness greps for to learn
        // which port to connect to: `\n[zdos] listening <HOST>:<PORT>\n` (HOST is
        // 127.0.0.1 unless `--host` widened it).
        server.bind() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve bind failed: {t}\n", .{err}) catch "zdos: --serve bind failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };

        var hbuf: [48]u8 = undefined;
        const hs = fmtBindHost(serve_host, &hbuf);
        var sbuf: [96]u8 = undefined;
        const banner = std.fmt.bufPrint(&sbuf, "\n[zdos] listening {s}:{d}\n", .{ hs, server.boundPort() }) catch "\n[zdos] listening\n";
        try stderr.writeStreamingAll(io, banner);

        // Informational: the MCP (Model Context Protocol) JSON-RPC 2.0 endpoint rides the
        // SAME `--serve` port (mcp-plan.md §3.4). Purely a banner — no behavior change, no
        // wall clock (the bound port is the only datum).
        var mbuf: [96]u8 = undefined;
        const mcp_banner = std.fmt.bufPrint(&mbuf, "[zdos] mcp endpoint: POST http://{s}:{d}/mcp\n", .{ hs, server.boundPort() }) catch "[zdos] mcp endpoint: POST /mcp\n";
        try stderr.writeStreamingAll(io, mcp_banner);

        // The host-side run-pacer (stream §5): a separate thread that, while armed via
        // `POST /api/run/start`, submits `run_slice` through the submit-gated queue and
        // sleeps the rest of each wall-clock tick. The HOST CLOCK lives in
        // `src/host/run_pacer.zig` (outside the api grep-gate, §5.1a). It reaches the
        // worker ONLY via the gated queue, so it never perturbs the cycle ledger.
        var pacer: host_mod.RunPacer = .{
            .queue = server.queueRef(),
            .control = server.runControl(),
            .io = io,
            // The live-stream frame producer (§4.1): each fps tick the pacer captures a
            // frame via the gated queue and copies it into the shared latest-frame
            // buffer for the per-connection stream threads. The hub's pointers are wired
            // by `server.serve()` → `wireStream()` before any client connects.
            .hub = server.streamHub(),
            // The coalesced LIVE-mouse record (plans/mouse-input.md, LOCKED §1/§5): each
            // slice the pacer submits one `input_mouse_fold` (a worker-side no-op unless
            // a POST made the record dirty), draining the browser cursor at ≤ one slice
            // latency on emulated-time cadence.
            .live_mouse = server.liveMouse(),
        };
        pacer.start() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve pacer start failed: {t}\n", .{err}) catch "zdos: --serve pacer start failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        // §9.1 shutdown ordering: the server stops + joins the pacer BEFORE the worker
        // sentinel (so a pacer submit can't race it). Register the pacer's join as the
        // server's pre-shutdown hook.
        server.setPreShutdown(&pacer, struct {
            fn hook(ctx: ?*anyopaque) void {
                const p: *host_mod.RunPacer = @ptrCast(@alignCast(ctx.?));
                p.join();
            }
        }.hook);

        // The host-side MULTI-SESSION pacer: the `RunPacer` above paces the DEFAULT machine;
        // this paces every armed registry-minted machine (`provision_machine` works in this mode
        // too). Disjoint sessions/queues, so it never interferes with the default pacer. Its host
        // clock also lives in `src/host/run_pacer.zig`. Joined via the `defer` below — which runs
        // before the deferred `server.deinit()` (registry minted-worker drain), so no minted slice
        // races a worker sentinel. (The default `RunPacer` is joined inside `serve` via the
        // pre-shutdown hook above, before the default worker drain.)
        var spacer: host_mod.SessionPacer = .{ .registry = server.sessionRegistry(), .io = io };
        spacer.start() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve session-pacer start failed: {t}\n", .{err}) catch "zdos: --serve session-pacer start failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        defer spacer.join();

        server.serve() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --serve failed: {t}\n", .{err}) catch "zdos: --serve failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        return;
    }

    if (break_cycle) |bc| {
        // Debugger path: drive the machine via the Controller and stop at cycle N.
        // The Controller observes/drives the machine synchronously; it never reads
        // host time and leaves the ledger exactly where the last retired step put
        // it (no smear) — the determinism property zdos exists to keep.
        var ctrl = Controller.init(m);
        const stop = ctrl.runToCycle(bc) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --break-cycle failed: {t}\n", .{err}) catch "zdos: --break-cycle failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };

        // Flush whatever the program printed up to the break point.
        try stdout.writeStreamingAll(io, m.dos.dev_table.con.output());

        const snap = ctrl.cpuSnapshot();
        var sbuf: [320]u8 = undefined;
        const status = std.fmt.bufPrint(&sbuf,
            \\
            \\[zdos] stopped: {s}; cycle {d}
            \\  CS:IP {x:0>4}:{x:0>4}  EAX={x:0>8} EBX={x:0>8} ECX={x:0>8} EDX={x:0>8}
            \\  ESP={x:0>8} EBP={x:0>8} ESI={x:0>8} EDI={x:0>8}  FLAGS: CF={d} ZF={d} SF={d} IF={d}
            \\
        , .{
            @tagName(stop),
            snap.cycles,
            snap.cs,
            @as(u16, @truncate(snap.eip)),
            snap.eax,
            snap.ebx,
            snap.ecx,
            snap.edx,
            snap.esp,
            snap.ebp,
            snap.esi,
            snap.edi,
            @intFromBool(snap.cf),
            @intFromBool(snap.zf),
            @intFromBool(snap.sf),
            @intFromBool(snap.iff),
        }) catch "\n[zdos] stopped\n";
        try stderr.writeStreamingAll(io, status);
        return;
    }

    const reason = m.runUntil(untilDone, 500_000_000);

    // ---- flush CON output, then report exit status ---------------------------
    try stdout.writeStreamingAll(io, m.dos.dev_table.con.output());

    var sbuf: [160]u8 = undefined;
    const status = std.fmt.bufPrint(&sbuf, "\n[zdos] {s}; exit code {d}; {d} cycles\n", .{
        @tagName(reason),
        m.dos.ret_code,
        m.cpu.st.cycles,
    }) catch "\n[zdos] done\n";
    try stderr.writeStreamingAll(io, status);

    if (!m.dos.terminated) std.process.exit(1);
}
