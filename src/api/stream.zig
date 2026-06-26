//! The WebSocket live-stream server side (video-stream §4/§6/§9.1): the per-connection
//! threads, the connection registry + cap, the shared-frame producer, the raw-indexed
//! wire protocol send, and Wyhash dedup. ALL host-side OBSERVATION — it charges no
//! cycle, mutates no machine state, and never feeds back into emulation ordering
//! (CLAUDE #4): the only machine access is `submit(framebuffer_get)` (the cycle-neutral
//! peek) through the SAME submit-gated queue every other producer uses.
//!
//! CLOCKLESS by design (only `std.atomic` + `std.Io.Mutex` + `std.Thread`): there is no
//! host clock here, so it is safe inside the `src/api` determinism grep-gate. The fps
//! SAMPLING CADENCE (which wall-clock tick captures a frame) is decided by the host
//! run-pacer (`src/host/run_pacer.zig`, outside the gate); this module only exposes a
//! clockless `produceFrame()` the pacer calls and clockless registry/send machinery.
//!
//! Lifetime rule (§9.1): a stream connection's `WebSocket`/`Reader`/`Writer`/buffers
//! live in the STREAM THREAD's own frame (`connThread`) for the connection's lifetime —
//! NEVER the server's shared `sr`/`sw`/`resp_buf`/`arena`. That thread owns and
//! `close()`s the socket. The accept loop keeps taking serial control connections.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `http.Server.WebSocket` (`http/Server.zig:654`): `writeMessage(data, op)`
//!     (`:750`, picks the 7/16/64-bit length form), the plain struct
//!     `{ key, input: *Reader, output: *Writer }` (`:655`).
//!   - `net.Stream.reader/writer(io, buf)` return BY VALUE (`Io/net.zig:1393/1397`) →
//!     named locals that outlive the WebSocket; `Stream.close(io)` (`:1248`).
//!   - `std.Thread.spawn` / `Thread.join`; `std.atomic.Value(bool)`.

const std = @import("std");
const q = @import("queue.zig");
const sf = @import("shared_frame.zig");
const run_control = @import("run_control.zig");

const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const SharedFrame = sf.SharedFrame;
const WebSocket = http.Server.WebSocket;

/// The connection cap (§9.1): beyond this the WS upgrade is rejected with HTTP 503.
pub const MAX_CONNS: usize = 4;

/// WS buffer sizing per connection (in the stream thread's frame). The OUTPUT buffer
/// must hold one full frame payload + the WS framing header; the INPUT buffer only ever
/// carries tiny client→server input frames (Phase 6), but we keep comfortable room.
const WS_OUT_BUF: usize = sf.MAX_PAYLOAD + 64;
const WS_IN_BUF: usize = 4 * 1024;

/// One stream-connection slot in the fixed registry. The thread handle + the
/// per-connection stop flag (set at shutdown to make the thread exit promptly) + the
/// socket (so shutdown can wake a blocked recv/send via shutdown). `active` is owned by
/// the hub under `reg_mutex`.
const Conn = struct {
    active: bool = false,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// The connection's socket, kept so the hub can `shutdown` it to unblock a parked
    /// thread at server stop. The thread itself `close()`s on exit.
    socket: net.Socket = undefined,
};

/// The server-owned stream hub: the single `SharedFrame`, the fixed connection registry
/// + cap, the queue (for the producer's `framebuffer_get` submit), the `RunControl` (for
/// auto-start/stop on first/last client, §5.3), and `io`. Heap-allocated once by the
/// server (a stable pointer the stream threads hold).
pub const StreamHub = struct {
    io: Io,
    queue: *q.CommandQueue,
    control: *run_control.RunControl,
    /// The server-owned render buffers the producer's `framebuffer_get` fills. The hub
    /// reads the freshly-peeked index/palette out of these and copies into `frame`.
    render: *RenderBuffers,
    frame: *SharedFrame,
    /// The owning session's concurrency lock (session.zig CONTRACT, span #4). `produceFrame`
    /// reads `render` OFF the queue on the host pacer thread; the connection-thread capture
    /// paths (`handleMcpScreenshot`/`/api/framebuffer`) read the same `render`. Holding this
    /// across `produceFrame`'s submit→copy serializes the two so neither tears the frame nor
    /// races the worker re-rendering into `render`. Pointer into the Session (stable for the
    /// session's life). Order: `lock` → `submit_gate` (taken inside `queue.submit`).
    lock: *Io.Mutex,

    /// Registry mutex: guards the `conns` slots' `active`/`thread`/`socket` + the count
    /// so concurrent upgrades and the joining shutdown serialize. CLOCKLESS.
    reg_mutex: Io.Mutex = .init,
    conns: [MAX_CONNS]Conn = @splat(.{}),
    active_count: std.atomic.Value(usize) = .init(0),

    /// A forward decl so this module needs no `worker` import (the render-buffer type
    /// lives there). The server passes its `*worker.RenderBuffers`; the layouts are the
    /// same nominal type, so we take it as an opaque-by-import alias.
    pub const RenderBuffers = @import("worker.zig").RenderBuffers;

    pub fn init(io: Io, queue: *q.CommandQueue, control: *run_control.RunControl, render: *RenderBuffers, frame: *SharedFrame, lock: *Io.Mutex) StreamHub {
        return .{ .io = io, .queue = queue, .control = control, .render = render, .frame = frame, .lock = lock };
    }

    /// True iff at least one stream client is connected — the producer only samples then
    /// (don't render when nobody is watching, §4.1).
    pub fn hasClients(self: *const StreamHub) bool {
        return self.active_count.load(.acquire) != 0;
    }

    // -----------------------------------------------------------------------
    // The frame producer (called by the host pacer each fps tick, §4.1).
    // -----------------------------------------------------------------------

    /// Capture ONE frame for all clients (§4.1): submit `framebuffer_get` (the existing
    /// cycle-neutral peek into the server-owned `render` buffers) through the gated
    /// queue, then copy the index + palette into the shared `frame` + bump its seqno.
    /// CLOCKLESS — the pacer decides WHEN to call this (the fps cadence rides its tick).
    /// Does nothing when no clients are connected.
    /// Signal that the guest PROGRAM TERMINATED (§6.4): publish the "stopped" state on
    /// the shared frame, waking the per-connection threads so each sends a one-shot
    /// `{"event":"stopped","reason":...,"cycle":...}` text control frame and keeps the
    /// connection open. Called by the host pacer ONLY on a program-end terminal
    /// (program_terminated/halted_forever) — NOT a breakpoint, a user `/api/run/stop`,
    /// or shutdown (those are debugger/user/lifecycle actions, not program end). The
    /// publish is idempotent (re-marking a dead machine is a no-op), so it emits once.
    /// CLOCKLESS: `cycle` is the EMULATED cycle counter, never a host wall clock.
    pub fn markStopped(self: *StreamHub, reason: []const u8, cycle: u64) void {
        self.frame.markStopped(reason, cycle);
    }

    pub fn produceFrame(self: *StreamHub) void {
        if (!self.hasClients()) return;
        // A terminated machine: stop sampling it (the "stopped" control frame was already
        // published by `markStopped`). The pacer also disarms, so this is belt-and-braces.
        if (self.frame.isStopped()) return;
        // Hold the session lock across submit→read(render)→publish (session.zig CONTRACT,
        // span #4): the connection-thread capture paths read the SAME `render`, so without
        // this a concurrent screenshot/framebuffer would tear the frame the worker is re-
        // rendering. Order `lock` → `submit_gate` (inside `submit`) matches every covered
        // span — no inversion, and the pacer's run_control use is unaffected (this touches
        // no `run_control`). A bounded peek + a ~308 KiB copy, never a long debugger run.
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var ctx: q.RequestCtx = .{ .cmd = .framebuffer_get };
        const resp = self.queue.submit(&ctx);
        const fr = switch (resp) {
            .framebuffer => |f| f,
            else => return, // a transient non-frame response: skip this tick (no fake)
        };
        if (!fr.supported) {
            // Publish a "no pixels / unsupported" marker (clients forward a control
            // frame, §6.4) rather than fabricating pixels.
            self.frame.publish(.{
                .supported = false,
                .width = 0,
                .height = 0,
                .kind = @intFromEnum(fr.kind),
                .pel_mask = fr.pel_mask,
                .index = self.render.index[0..0],
                .palette = self.render.palette[0..],
            });
            return;
        }
        self.frame.publish(.{
            .supported = true,
            .width = fr.width,
            .height = fr.height,
            .kind = @intFromEnum(fr.kind),
            .pel_mask = fr.pel_mask,
            .index = self.render.index[0..fr.index_len],
            .palette = self.render.palette[0..],
        });
    }

    // -----------------------------------------------------------------------
    // Connection lifecycle (claim a slot, spawn the thread; §9.1).
    // -----------------------------------------------------------------------

    /// Reserve a free registry slot for a new stream connection. Returns the slot index,
    /// or null when the cap is reached (the caller replies 503 and does NOT upgrade).
    /// Increments `active_count` and, if this is the FIRST client, auto-arms the pacer
    /// when idle (§5.3 — never hijack a paused debugger session).
    fn claimSlot(self: *StreamHub, socket: net.Socket) ?usize {
        self.reg_mutex.lockUncancelable(self.io);
        defer self.reg_mutex.unlock(self.io);
        for (&self.conns, 0..) |*c, i| {
            if (!c.active) {
                // A previous occupant that self-exited (client disconnect) leaves its
                // thread handle here `active=false, thread!=null` for join-on-reuse — so
                // no handle is ever overwritten unjoined (no OS-thread leak across
                // connect/disconnect churn). It already ran `cleanup` → returns promptly.
                if (c.thread) |t| {
                    t.join();
                    c.thread = null;
                }
                c.active = true;
                c.stop = .init(false);
                c.socket = socket;
                const was = self.active_count.fetchAdd(1, .acq_rel);
                if (was == 0) self.autoStart();
                return i;
            }
        }
        return null;
    }

    /// Release a slot when its thread exits. Decrements `active_count`; if this was the
    /// LAST client, auto-stops the pacer (only when WE own the run, §5.3).
    fn releaseSlot(self: *StreamHub, idx: usize) void {
        self.reg_mutex.lockUncancelable(self.io);
        defer self.reg_mutex.unlock(self.io);
        const c = &self.conns[idx];
        if (!c.active) return;
        c.active = false;
        // The thread handle is detached at exit (it self-releases); shutdown joins via
        // the registry snapshot, so we leave `thread` for the joiner to clear.
        const now = self.active_count.fetchSub(1, .acq_rel) - 1;
        if (now == 0) self.autoStop();
    }

    /// Auto-arm the pacer on first connect — ONLY when idle (§5.3). `start` itself
    /// refuses if a debugger run is in flight, so this never hijacks a paused session.
    fn autoStart(self: *StreamHub) void {
        if (self.control.getOwner() == .idle) {
            _ = self.control.start(0, 0); // keep current tuning
        }
    }

    /// Auto-stop the pacer on last disconnect — only if WE (paced) own the run.
    fn autoStop(self: *StreamHub) void {
        if (self.control.getOwner() == .paced) self.control.stop();
    }

    /// Try to upgrade `request` to a WebSocket on a new stream thread (§6.1/§9.1). The
    /// handshake (`respondWebSocket`) is completed on the SERVER's shared writer (it just
    /// writes the 101 + flushes), then the OWNERSHIP of the socket + the WebSocket I/O
    /// moves to the spawned thread, which builds its OWN Reader/Writer over the socket
    /// (the post-handshake protocol is raw WS frames — no http.Server state needed).
    ///
    /// Returns true iff the socket was handed to a stream thread (the caller must NOT
    /// close it — the thread owns it). Returns false on a rejected/failed upgrade (the
    /// caller handled the HTTP error response and still owns the socket).
    pub fn upgrade(self: *StreamHub, request: *http.Server.Request, stream: net.Stream, key: []const u8) bool {
        const idx = self.claimSlot(stream.socket) orelse {
            // Cap reached → 503, do NOT upgrade (§9.1).
            request.respond("{\"error\":{\"code\":\"capacity\",\"message\":\"stream connection cap reached\"}}", .{
                .status = .service_unavailable,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
            }) catch {};
            return false;
        };

        // Complete the handshake on the shared server writer (writes 101 + accept key).
        var ws = request.respondWebSocket(.{ .key = key }) catch {
            self.releaseSlot(idx);
            return false;
        };
        ws.flush() catch {
            self.releaseSlot(idx);
            return false;
        };

        const args: ThreadArgs = .{ .hub = self, .idx = idx, .stream = stream };
        const t = std.Thread.spawn(.{}, connThread, .{args}) catch {
            self.releaseSlot(idx);
            return false;
        };
        // Record the thread handle for the shutdown join.
        self.reg_mutex.lockUncancelable(self.io);
        self.conns[idx].thread = t;
        self.reg_mutex.unlock(self.io);
        return true;
    }

    // -----------------------------------------------------------------------
    // Shutdown (§9.1): stop-flag + shutdown sockets + join all stream threads.
    // Called by the server's pre-shutdown path BEFORE the worker sentinel.
    // -----------------------------------------------------------------------

    /// Signal every live stream thread to exit, unblock any parked socket I/O, and join.
    /// After this returns, no stream thread is running, so the subsequent worker
    /// shutdown sentinel cannot race a producer/consumer submit (§9.1).
    pub fn shutdown(self: *StreamHub) void {
        // Snapshot the live slots under the registry lock, then set the stop flags +
        // shutdown the sockets (so a blocked readSmallMessage/writeMessage returns).
        var threads: [MAX_CONNS]?std.Thread = .{null} ** MAX_CONNS;
        self.reg_mutex.lockUncancelable(self.io);
        for (&self.conns, 0..) |*c, i| {
            if (c.active or c.thread != null) {
                c.stop.store(true, .release);
                // Unblock a parked recv/send: shutdown both directions on the socket.
                const s: net.Stream = .{ .socket = c.socket };
                s.shutdown(self.io, .both) catch {};
                // CLAIM the handle under the lock (null it now) so a concurrent
                // `claimSlot` reusing the slot cannot also join the same handle (no
                // double-join). We join the snapshot below, outside the lock.
                threads[i] = c.thread;
                c.thread = null;
                c.active = false;
            }
        }
        self.reg_mutex.unlock(self.io);

        // Wake any consumer parked in `waitNext` so it re-checks its stop flag and exits
        // (the socket shutdown above only unblocks a thread parked in socket I/O).
        self.frame.wakeAll();

        for (threads) |maybe| {
            if (maybe) |t| t.join();
        }
        // The threads we force-stopped above had their slots marked inactive under the
        // lock, so their own `releaseSlot` early-returns (no double-decrement). Reset the
        // count to keep it coherent post-shutdown.
        self.active_count.store(0, .release);
    }
};

const ThreadArgs = struct {
    hub: *StreamHub,
    idx: usize,
    stream: net.Stream,
};

/// The per-connection stream thread (§4.3/§9.1). Owns the socket + its own
/// Reader/Writer/WebSocket in THIS frame. Loops: poll the shared seqno; on new data copy
/// the body out under the mutex, dedup with Wyhash, and send a raw-indexed frame (full
/// frame on connect; palette sent when it changed). Exits on the per-conn stop flag, a
/// closed socket, or a send error. Closes the socket on exit and releases its slot.
fn connThread(args: ThreadArgs) void {
    const hub = args.hub;
    const io = hub.io;
    const idx = args.idx;
    const stream = args.stream;

    // Per-thread WS I/O buffers + the post-handshake Reader/Writer over the socket. The
    // handshake's 101 was already written + flushed on the server's shared writer; from
    // here the protocol is raw WS frames, so a fresh Reader/Writer over the same socket
    // is correct and keeps ALL state in this thread's frame (§9.1).
    var rbuf: [WS_IN_BUF]u8 = undefined;
    var wbuf: [WS_OUT_BUF]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    var ws: WebSocket = .{ .key = "", .input = &sr.interface, .output = &sw.interface };

    // Per-thread frame copy-out buffers + the WS payload scratch (allocated once on the
    // thread stack — no per-op alloc, §4.4). These are large (~308 KiB each); the thread
    // stack default is generous, but to be safe we keep one combined payload buffer that
    // copyOut writes index into, then we splice the palette after.
    const Bufs = struct {
        index: [sf.INDEX_CAP]u8 = undefined,
        palette: [sf.PALETTE_LEN]u8 = undefined,
        payload: [sf.MAX_PAYLOAD]u8 = undefined,
        reason: [sf.STOP_REASON_CAP]u8 = undefined,
    };
    var bufs = std.heap.page_allocator.create(Bufs) catch {
        cleanup(hub, idx, stream);
        return;
    };
    defer std.heap.page_allocator.destroy(bufs);

    var last_hash: ?u64 = null;
    var last_palette_seq: u64 = 0;
    var last_seqno: u64 = 0;
    // The terminal "stopped" control frame (§6.4) is sent at most ONCE per connection.
    var stopped_sent: bool = false;

    const stop = &hub.conns[idx].stop;
    while (!stop.load(.acquire)) {
        // Park (clockless) until a NEW frame is published or shutdown wakes us — no
        // busy-spin, no host clock. `waitNext` returns immediately when a frame already
        // exists (a fresh client gets the current frame without waiting for a change).
        const cur = hub.frame.waitNext(last_seqno, stop);
        if (stop.load(.acquire)) break;
        if (cur == last_seqno) continue; // a spurious/shutdown wake with no new frame
        last_seqno = cur;

        // Copy the body out under the mutex into this thread's buffers (drop-to-latest:
        // we always read the CURRENT frame, never a backlog, §4.3).
        const snap = hub.frame.copyOut(bufs.index[0..], bufs.palette[0..], bufs.reason[0..]);

        // Program-end (§6.4): emit a one-shot `{"event":"stopped",...}` text frame and
        // keep the connection open (the client shows an overlay; the user may reconnect).
        // Checked BEFORE the dedup `continue` below, because the stopped publish leaves
        // the pixel body unchanged (its hash would match and skip it otherwise).
        if (snap.stopped and !stopped_sent) {
            const ok = sendStopped(&ws, &bufs.payload, snap) catch break;
            if (!ok) break;
            stopped_sent = true;
            continue; // keep parking; don't send a (dead) pixel frame for this seqno
        }

        // Dedup (§4.3): skip an unchanged frame, but ALWAYS send the first frame after
        // connect (last_hash unset). The hash covers index+palette so palette-only fades
        // are NOT skipped.
        if (last_hash) |lh| {
            if (lh == snap.frame_hash) continue;
        }

        const sent = sendFrame(&ws, &bufs.payload, snap, &last_palette_seq) catch break;
        if (!sent) break;
        last_hash = snap.frame_hash;
    }

    cleanup(hub, idx, stream);
}

fn cleanup(hub: *StreamHub, idx: usize, stream: net.Stream) void {
    stream.close(hub.io);
    hub.releaseSlot(idx);
}

/// Send the one-shot terminal control frame (§6.4) as a TEXT WS message, mirroring the
/// `unsupported` text-frame mechanism above. Shape matches the client's `handleControl`
/// EXACTLY: `{"event":"stopped","reason":"<reason>","cycle":<n>}`. The reason token is a
/// fixed allow-list of `[a-z_]` from the terminal StopReason (never client/guest input),
/// so it needs no JSON escaping. Returns true on success, false on a closed socket.
fn sendStopped(ws: *WebSocket, payload: []u8, snap: SharedFrame.Snapshot) !bool {
    const json = std.fmt.bufPrint(
        payload,
        "{{\"event\":\"stopped\",\"reason\":\"{s}\",\"cycle\":{d}}}",
        .{ snap.stop_reason, snap.stop_cycle },
    ) catch return false;
    ws.writeMessage(json, .text) catch return false;
    return true;
}

/// Build the §6.3 payload in `payload` and send it as a binary WS message. Returns true
/// on success, false on a closed socket. The palette is included (has_palette) on the
/// first frame and whenever it changed since this connection last sent it (§4.3/§6.3).
fn sendFrame(ws: *WebSocket, payload: []u8, snap: SharedFrame.Snapshot, last_palette_seq: *u64) !bool {
    if (!snap.supported) {
        // Unsupported mode → a control frame (§6.4), never fabricated pixels.
        ws.writeMessage("{\"event\":\"unsupported\"}", .text) catch return false;
        return true;
    }

    const send_palette = (last_palette_seq.* != snap.palette_seq) or (last_palette_seq.* == 0);
    var flags: u8 = 0;
    if (send_palette) flags |= sf.FLAG_HAS_PALETTE;

    const palette_len: u16 = if (send_palette) @intCast(sf.PALETTE_LEN) else 0;
    sf.writeHeader(
        payload[0..sf.HEADER_LEN],
        @truncate(snap.seqno),
        flags,
        snap.width,
        snap.height,
        snap.kind,
        snap.pel_mask,
        snap.index_len,
        palette_len,
    );
    var off: usize = sf.HEADER_LEN;
    @memcpy(payload[off .. off + snap.index_len], snap.index[0..snap.index_len]);
    off += snap.index_len;
    if (send_palette) {
        @memcpy(payload[off .. off + sf.PALETTE_LEN], snap.palette[0..sf.PALETTE_LEN]);
        off += sf.PALETTE_LEN;
    }

    ws.writeMessage(payload[0..off], .binary) catch return false;
    last_palette_seq.* = snap.palette_seq;
    return true;
}
