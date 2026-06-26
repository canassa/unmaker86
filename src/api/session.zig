//! Per-session state bundle (multi-machine plan §3.2/§4.1 — Phase 1). Groups
//! everything currently tied to ONE emulated machine into a single struct so the
//! `Server` can hold one default `Session` today and a registry of N sessions
//! later. This is a PURE refactor: the fields, their allocation, and their
//! lifetimes are byte-for-byte what `Server` owned before — only their home moved.
//! No concurrency, no registry, no MCP lifecycle change is introduced here (those
//! are Phases 2-4); a `Server` still owns exactly ONE default `Session`.
//!
//! Determinism (CLAUDE prime directive): a Session carries NO host clock, NO RNG,
//! and NO float in any emitted byte. Its only time source is the machine's own
//! `cpu.st.cycles`, reached solely through the gated `queue` on the worker thread.
//! Two Sessions share nothing mutable IN-PROCESS (RAM / CPU / devices are each per-
//! machine), so per-machine determinism holds. The ONE shared mutable thing they do
//! NOT isolate is the host filesystem: the writable host mount dir is handed to every
//! session and is a CALLER-MANAGED external input, not zdos state (multi-machine plan
//! §13 / Finding 4 — by design). Determinism is preserved given fixed inputs; a caller
//! that lets two sessions mutate one shared dir has fed a shared-mutating input.
//!
//! ===========================================================================
//! PER-SESSION CONCURRENCY CONTRACT (the rule the whole threaded model rests on)
//! ===========================================================================
//! The worker thread SOLELY owns the machine. A connection thread only builds a
//! `Command`, submits it through `queue` (one in flight, `submit_gate`-serialized),
//! and serializes the `Response`. That invariant — pure queue commands need no extra
//! lock, the `submit_gate` already serializes their producers — is preserved and is
//! why `read_cpu`/`step`/`mem`/`status`/… stay LOCK-FREE on the hot path.
//!
//! But some per-session MUTABLE state is NOT a single queue command. Before Phase 2
//! the serial "one connection at a time" accept loop was an IMPLICIT lock that
//! protected it; making connections concurrent deleted that lock without replacing
//! it. `Session.lock` (below) is the explicit replacement.
//!
//! THE CONTRACT: *any access — READ or WRITE — to shared per-session state that is NOT
//! a single queue command must hold `session.lock` across the whole critical section.*
//! The rule is symmetric on purpose: a lock-free READER tears just as badly against a
//! locked writer as two writers do (Finding 3 was exactly an unlocked recipe READ). Pure
//! queue commands stay lock-free (the `submit_gate` serializes their producers). The
//! covered off-queue spans (server.zig / stream.zig):
//!   1. CAPTURE (`handleMcpScreenshot`, `submitAndRespondFramebuffer`): submit
//!      `framebuffer_get` → read/encode `render`/`png_out` → COPY the finished bytes into
//!      the connection's own scratch. The worker must not re-render into `render` while a
//!      connection is still reading/encoding it (`encodePng` even mutates `render.index`
//!      in place). The span ends at the snapshot COPY, NOT the wire write (Finding 2): the
//!      unbounded socket write runs UNLOCKED over the owned copy, because the pacer's
//!      inline `produceFrame` shares this lock and holding it across a slow write would
//!      freeze the guest. Held across submit→read→encode→copy-out only.
//!   2. DEBUGGER (`submitDebuggerAndRespond`, the MCP run/step path): `beginDebugger`
//!      → submit run/step → `endDebugger`. The owner save/restore is a read-modify-
//!      write on `run_control`; two concurrent debugger spans interleaving it leave the
//!      owner stuck at `debugger` (start() then 409s forever). Held across begin→end so
//!      it is atomic per session.
//!   3. RECIPE WRITE (`handleLoad`, `buildMcpLoad`): overlay+persist `recipe` then submit
//!      `load`. Two concurrent loads lose-update `recipe` and desync the persisted
//!      recipe from the loaded machine. Held across overlay→persist→submit.
//!   4. RECIPE READ (`respondMcpInitialize`): copy `recipe` + `mount_dir` out of the
//!      DEFAULT session to seed a freshly minted session. An unlocked by-value read tears
//!      against a concurrent `load` writer (#3) → the minted session boots a corrupt
//!      recipe (Finding 3). Held ONLY across the copy-out; `registry.create` then runs
//!      OUTSIDE the lock (the registry mutex must NOT nest under `session.lock` — see the
//!      lock order below), so the lock is released before the heavy provision.
//!   5. LIVE-FRAME read (`stream.produceFrame`, host pacer thread): submit
//!      `framebuffer_get` → copy `render` into the shared frame. Same `render` the
//!      capture paths read; covered by the SAME lock (the hub holds `&session.lock`).
//!
//! LOCK ORDER (global, must never invert): `session.lock` → `run_control.arb` →
//! `queue.submit_gate` → `queue.mutex`. `session.lock` is held ACROSS a `queue.submit`
//! in every covered span, so `submit_gate` is taken WHILE holding `session.lock` —
//! NOTHING may ever take `submit_gate` (i.e. call `queue.submit`) and then reach for
//! `session.lock`. Pure queue commands and the pacer's own `run_slice`/`input_mouse_
//! fold` submits take `submit_gate` ALONE (never `session.lock`), so they cannot
//! invert the order. The registry mutex and `conn_mutex` guard only their own maps and
//! are never nested under `session.lock` (resolve/release run before/after a handler,
//! not inside a covered span). CLOCKLESS: the no-timeout `lockUncancelable`/`unlock`
//! variants only (the determinism grep bans every clock affordance).
//!
//! Stable-address contract (machine.zig:8-20; the worker captures member
//! addresses): a `Session` is held BY VALUE inside the `Server`, and the `Server`
//! itself never moves after construction (it reaches its final address — a stack
//! local in `main.zig`'s `--serve` path, or a heap slot via `gpa.create(Server)`
//! in the tests — BEFORE any thread is spawned). `Session.init` therefore captures
//! NO self-address; the address-sensitive `&queue` / hub-wiring captures happen
//! only later in `Server.wireStream`/`Server.bind`, AFTER the Session is at its
//! final address. The heap-owned members (render / run_control / live_mouse /
//! shared_frame / stream_hub) are stable wherever the Session value itself sits,
//! exactly as they were when `Server` allocated them directly.
//!
//! NOTE (Phase-1 scope): the run-pacer is NOT a Session member here even though the
//! plan's §4.1 eventual shape lists it. It currently lives as a `main.zig` local
//! (not a `Server` field), and `RunPacer` is in `src/host`, which sits ABOVE `api`
//! in the module graph (`api` must NOT import `host`). Pulling it into a `src/api`
//! `Session` would invert that layering. The pacer reaches this Session's machine
//! ONLY through the gated `queue` / clockless `run_control`, so it stays a host-side
//! local wired in `main.zig`. Folding it into the Session is Phase 3+ work (it rides
//! with the registry, which can live where it sees `host`).

const std = @import("std");
const debug = @import("debug");
const machine_mod = @import("machine");
const q = @import("queue.zig");
const wire = @import("json_wire.zig");
const worker_mod = @import("worker.zig");
const run_control = @import("run_control.zig");
const live_mouse_mod = @import("live_mouse.zig");
const stream_mod = @import("stream.zig");
const sf = @import("shared_frame.zig");

const Io = std.Io;
const Controller = debug.Controller;
const Machine = machine_mod.Machine;

/// A transport-only session identity (multi-machine plan §4.4). Routes a request to a
/// session's queue; it NEVER enters guest state, the cycle ledger, or any Command/
/// Response POD — so it is determinism-neutral (a fixed-capacity, pointer-free value
/// that hashes/copies freely). The id text itself is minted DETERMINISTICALLY by the
/// registry (`zdos-sess-<seq>` from a monotonic counter — no clock, no RNG), so the
/// `src/api` determinism grep stays green with no carve-out. The backing buffer is
/// zero-padded beyond `len` so the value hashes/compares consistently as a map key.
pub const SessionId = struct {
    buf: [128]u8 = @splat(0),
    len: u8 = 0,

    pub fn fromSlice(s: []const u8) SessionId {
        var id: SessionId = .{};
        const n = @min(s.len, id.buf.len);
        @memcpy(id.buf[0..n], s[0..n]);
        id.len = @intCast(n);
        return id;
    }

    pub fn slice(self: *const SessionId) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eqlSlice(self: *const SessionId, s: []const u8) bool {
        return std.mem.eql(u8, self.slice(), s);
    }
};

/// The server-held program-load recipe (captured at `--serve` startup, updated by
/// `POST /api/load`). Re-applied via the worker — the only way to a runnable
/// machine after `reset()` (§B.1/G16). Fixed-capacity, pointer-free. Lives here (not
/// `server.zig`) because it is a per-Session datum and so a Session field can name it
/// without a server↔session import cycle; `server.zig` re-exports it for the API root.
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

    /// Apply the PRESENT (non-null) fields of a wire `LoadReq` onto this recipe IN PLACE
    /// — the single overlay both load front-ends share (HTTP `handleLoad` + MCP
    /// `buildMcpLoad`), so the two transports can never drift in how a partial request
    /// updates the persisted recipe (anti-drift; the equivalence tests pin it). An absent
    /// field keeps the prior value, so `{}` re-loads the persisted program after a reset.
    /// The file/cmdtail copies are length-capped to the fixed buffers with the SAME
    /// `@min`/`@memcpy`/`_len` discipline as `init` (a too-long name truncates, never
    /// overruns). PURE: no allocation, no host time.
    pub fn overlay(self: *LoadRecipe, r: wire.LoadReq) void {
        if (r.drive) |d| self.drive = d;
        if (r.file) |f| {
            const n = @min(f.len, self.file.len);
            @memcpy(self.file[0..n], f[0..n]);
            self.file_len = @intCast(n);
        }
        if (r.cmdtail) |ct| {
            const n = @min(ct.len, self.cmdtail.len);
            @memcpy(self.cmdtail[0..n], ct[0..n]);
            self.cmdtail_len = @intCast(n);
        }
    }

    pub fn toCmd(self: LoadRecipe) q.LoadCmd {
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

/// One emulated machine and everything bound to it (multi-machine plan §3.2). Held
/// BY VALUE inside `Server` as the single default session (Phase 1); a future
/// `SessionRegistry` (Phase 3) will own N of these by pointer. Every member here was
/// a `Server` field before — the allocation/teardown discipline is unchanged.
pub const Session = struct {
    /// The transport-routing identity (multi-machine plan §4.4). The DEFAULT session's id is the
    /// fixed `zdos-mcp-singleton` — its INTERNAL handle, used by the HTTP `/api/*` resolver
    /// (a blank or singleton `X-Zdos-Session` → the default) and by `DELETE /mcp`'s reject-the-
    /// default guard. It is NOT minted or echoed over MCP (which is stateless — agent-
    /// provisioning-plan §4). A registry-PROVISIONED session gets a `zdos-sess-<seq>` handle,
    /// returned in the `provision_machine` tool result and threaded back as the `machine` arg.
    id: SessionId = .{},

    /// The Controller over the heap-pinned, `wire()`'d Machine. A pointer FIELD —
    /// the worker (sole machine owner) dereferences it; nothing here does. Bound to
    /// the Controller's FINAL address by the caller after the Session is at rest
    /// (mirrors the old `Server.ctrl` lifetime).
    ctrl: *Controller,

    /// REGISTRY-OWNED machine + controller (multi-machine plan §4.3, Phase 3). For the
    /// single DEFAULT session these stay null — its `Machine`/`Controller` are owned by
    /// `main.zig` (or the test harness) and torn down there, exactly as before. For a
    /// registry-MINTED session the registry `gpa.create`s both at stable heap addresses
    /// (so the worker's captured `ctrl`/`&queue` never dangle) and frees them on
    /// teardown. Held here so a session is self-contained for `SessionRegistry.destroy`.
    owned_machine: ?*Machine = null,
    owned_ctrl: ?*Controller = null,

    /// True only for a registry-minted session (the default session is process-owned and
    /// never destroyed). Gates the refcount + `SessionRegistry.destroy` teardown.
    destroyable: bool = false,

    /// In-flight-request refcount + teardown-pending flag (multi-machine plan §5 safety).
    /// Guarded by the OWNING `SessionRegistry.mutex` (clockless), NOT by any session
    /// state. `resolve` bumps `refs` while a connection holds this `*Session`; `destroy`
    /// removes the id from the map then waits (clockless condvar) for `refs==0` before
    /// joining the worker + freeing — so a teardown never races a request mid-flight and
    /// never use-after-frees a destroyed session. The default session is never refcounted.
    refs: u32 = 0,
    pending_destroy: bool = false,

    /// RESERVED recency bookkeeping (agent-provisioning-plan §9): the registry stamps this with
    /// its monotonic request counter on every `resolve`. NO LRU/time eviction ships — reclamation
    /// is explicit `deprovision` and recovery is `list_machines` — so nothing READS this today.
    /// Kept (clockless, monotonic) so a future operability feature has a deterministic recency
    /// key with no wall clock (which the determinism grep bans).
    last_request_seq: u64 = 0,

    /// The program-load recipe + the host mount dir, held so a `POST /api/load`
    /// after `reset()` can re-run the full boot on the worker thread.
    recipe: LoadRecipe,
    mount_dir: Io.Dir,

    /// Does THIS session OWN its `mount_dir` fd (multi-machine plan §5, the v2 BLOCKER
    /// fix)? The single DEFAULT session shares `main.zig`'s one `Io.Dir` (opened +
    /// `defer dir.close`-d there), so it is `false` — `main.zig` closes that dir, and the
    /// registry must NOT (a double-close). A registry-PROVISIONED session (`provision_
    /// machine`) opens a FRESH `Io.Dir` per machine and hands ownership here, so it is
    /// `true` and `SessionRegistry.teardown` closes that fd on deprovision — without this,
    /// every provision/deprovision cycle would leak a directory fd (an agent churning
    /// machines would exhaust host fds). Set by `SessionRegistry.create`'s caller.
    owns_mount: bool = false,

    /// The PER-SESSION concurrency lock (see the module-level CONTRACT above). Guards the
    /// OFF-QUEUE critical sections only — the capture (render/png_out), debugger (owner
    /// save/restore), and recipe (overlay/persist) spans, plus the host pacer's live-frame
    /// `render` read in `stream.produceFrame`. Pure queue commands do NOT take it (the
    /// `submit_gate` already serializes them). Held ACROSS a `queue.submit` inside those
    /// spans, so the global order is `lock` → `run_control.arb` → `queue.submit_gate`;
    /// nothing ever acquires them in the opposite order. CLOCKLESS (the no-timeout
    /// `lockUncancelable`/`unlock` variants), so it stays inside the determinism grep-gate.
    /// A pointer to it (`&session.lock`) is handed to the stream hub at `wireStream`, so the
    /// pacer's `produceFrame` shares the exact same lock as the connection-thread captures.
    lock: Io.Mutex = .init,

    /// The per-session command queue (the producer↔worker handoff). INLINE — its
    /// address (`&session.queue`) is captured by the worker in `Server.bind`, AFTER
    /// the Session reaches its final address, so it must never move thereafter.
    queue: q.CommandQueue,
    /// This session's worker thread (the sole owner of `ctrl`/`Machine`). Spawned in
    /// `Server.bind`, joined via the `shutdown_worker` sentinel in `Server.joinWorker`.
    worker_thread: ?std.Thread = null,

    /// Run-ownership arbitration + the pacer arm flag (stream §5.2/§5.3). CLOCKLESS
    /// (atomics + a no-timeout mutex). Heap-allocated ONCE so the host pacer can hold
    /// a stable pointer to it across the session's lifetime.
    run_control: *run_control.RunControl,

    /// The coalesced LIVE-mouse arrival record (plans/mouse-input.md §1). Host-side
    /// state, NOT machine state, NOT snapshotted. Heap-allocated ONCE so the worker +
    /// pacer hold stable pointers.
    live_mouse: *live_mouse_mod.LiveMouseState,

    /// The fixed render buffers for `GET /api/framebuffer` (~4 MiB). Heap-allocated
    /// ONCE; the worker renders into them via the pure peek and the server streams the
    /// selected buffer as a raw binary body (pixels never flow through `resp_buf`/JSON).
    render: *worker_mod.RenderBuffers,

    /// The live-video-stream side: the shared latest-frame buffer + the per-connection
    /// stream-thread registry/cap + the frame producer. Heap-allocated ONCE (stable
    /// pointers the pacer + stream threads hold). Reaches the worker ONLY via the gated
    /// queue (`framebuffer_get`), so it charges no cycle and never perturbs ordering.
    shared_frame: *sf.SharedFrame,
    stream_hub: *stream_mod.StreamHub,

    /// Allocate the per-session heap blocks and stand up the queue. Captures NO
    /// self-address (the stream hub is `.init`-wired later, in `Server.wireStream`,
    /// once the Session is at its final address). The errdefer chain frees every
    /// block on a partial failure — identical to the old `Server.init` body.
    pub fn init(gpa: std.mem.Allocator, io: Io, id: SessionId, ctrl: *Controller, recipe: LoadRecipe, mount_dir: Io.Dir) !Session {
        // The render buffers (~4 MiB) — too large for the stack/`resp_buf`; one alloc.
        const render = try gpa.create(worker_mod.RenderBuffers);
        errdefer gpa.destroy(render);
        // The run-control block (clockless arm flag + owner). Stable pointer for the pacer.
        const rc = try gpa.create(run_control.RunControl);
        rc.* = run_control.RunControl.init(io);
        errdefer gpa.destroy(rc);
        // The coalesced live-mouse record (clockless, float-free POD). Stable for worker+pacer.
        const lm = try gpa.create(live_mouse_mod.LiveMouseState);
        lm.* = live_mouse_mod.LiveMouseState.init(io);
        errdefer gpa.destroy(lm);
        // The shared latest-frame buffer (~308 KiB) + the stream hub: stable pointers the
        // host pacer + stream threads hold. The hub is `.init`-wired in `Server.wireStream`.
        const frame = try gpa.create(sf.SharedFrame);
        frame.* = sf.SharedFrame.init(io);
        errdefer gpa.destroy(frame);
        const hub = try gpa.create(stream_mod.StreamHub);
        return .{
            .id = id,
            .ctrl = ctrl,
            .recipe = recipe,
            .mount_dir = mount_dir,
            .queue = q.CommandQueue.init(io),
            .render = render,
            .run_control = rc,
            .live_mouse = lm,
            .shared_frame = frame,
            .stream_hub = hub,
        };
    }

    /// Wire this session's stream hub now that the Session is at its FINAL address (the
    /// hub captures `&self.queue`, which is only stable once at rest). Factored so both
    /// `Server.wireStream` (the default session) and `SessionRegistry.create` (a minted
    /// session) wire identically. A minted session has no host pacer, but the hub is
    /// still initialized so its `shutdown()` is well-defined at teardown.
    pub fn wireStream(self: *Session, io: Io) void {
        // Hand the hub `&self.lock` so the host pacer's off-queue `render` read in
        // `produceFrame` is serialized against the connection-thread capture spans by the
        // SAME lock (the multi-machine concurrency contract above, span #4).
        self.stream_hub.* = stream_mod.StreamHub.init(io, &self.queue, self.run_control, self.render, self.shared_frame, &self.lock);
    }

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        gpa.destroy(self.render);
        gpa.destroy(self.run_control);
        gpa.destroy(self.live_mouse);
        gpa.destroy(self.shared_frame);
        gpa.destroy(self.stream_hub);
    }
};
