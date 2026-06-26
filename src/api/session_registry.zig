//! The process-global session registry (multi-machine plan §4, Phase 3): a thread-safe
//! map of `Mcp-Session-Id` → `*Session`, each session owning its OWN machine + controller
//! + command queue + worker thread, provisioned over the MCP lifecycle (`initialize`
//! mints, `DELETE /mcp` destroys). It is the seam that turns the single default session
//! into N concurrent machines, each IN-PROCESS isolated (own RAM / CPU / devices / worker).
//! They are NOT isolated on the host filesystem: every session is handed the same writable
//! mount dir, which is a CALLER-MANAGED external input, not zdos state (multi-machine plan
//! §13 / Finding 4 — host-FS isolation is the caller's responsibility, by design).
//!
//! WHY THIS LIVES IN `src/api` (the layering): the registry provisions a full `Machine`
//! + `Controller` + worker — all reachable from `api` (it imports `machine`/`debug`).
//! It does NOT spawn a run-pacer: a registry-minted session is DEBUGGER-DRIVEN only
//! (its guest advances solely via `tools/call` step/run through the gated queue, exactly
//! like the HTTP debugger path), so it never needs the host-side paced free-run loop.
//! The paced free-run + live stream stay on the DEFAULT session, wired in `main.zig`
//! (where `src/host` is visible). Keeping the registry in `api` keeps it inside the
//! determinism grep-gate (it carries NO host clock, NO RNG, NO float).
//!
//! Determinism (CLAUDE prime directive): session ids are minted from a monotonic counter
//! (`zdos-sess-<seq>`), NEVER a clock/RNG. GC is explicit `DELETE` (primary) with LRU
//! BY REQUEST COUNT as the documented safety net — NEVER a timed sweep. Each session's
//! guest advances only inside its own worker via its own `queue.submit`; sessions share
//! no mutable state, so each stays individually cycle-deterministic. The registry mutex
//! guards ONLY the map + counters (clockless `Io.Mutex`/`Io.Condition`, the same
//! no-timeout variants the queue uses); it touches no machine cycle.
//!
//! Stable-address discipline (machine.zig:8-20; the worker captures `&session.queue` and
//! `session.ctrl`): every minted `Machine`, `Controller`, and `Session` is its OWN
//! `gpa.create` heap block — never stored by value in a relocatable container. The map
//! stores `*Session` (a pointer), so growing/rehashing the map never moves a session. A
//! session's worker is spawned only AFTER the session reaches its final heap address.

const std = @import("std");
const debug = @import("debug");
const machine_mod = @import("machine");
const q = @import("queue.zig");
const worker_mod = @import("worker.zig");
const session_mod = @import("session.zig");

const Io = std.Io;
const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Session = session_mod.Session;
const SessionId = session_mod.SessionId;
const LoadRecipe = session_mod.LoadRecipe;

/// Errors a `create` can surface (mapped to the MCP/JSON-RPC error model by the caller —
/// the per-failure granularity the LLM branches on, plan §8). `SessionLimitReached` is the
/// resource cap (§9 → `machine_limit_reached`); `ProgramNotFound` is a missing program file
/// in the mount (→ a client `-32602`, distinct from a genuine fault — it propagates the DOS
/// loader's OWN `error.NotFound`, which resolves the host name through the case-insensitive
/// vfs exactly as a real boot would, so it never diverges from what a launch would find);
/// `BootFailed` is a program that was found but could not load/run (bad image / no guest
/// memory / I/O — a `-32603` internal); `OutOfMemory`/`SpawnError` are provisioning faults.
pub const CreateError = error{ SessionLimitReached, ProgramNotFound, BootFailed } || std.Thread.SpawnError || std.mem.Allocator.Error;

/// The result of a successful `create`: the new `*Session` PLUS its minted id BY VALUE
/// (multi-machine concurrency fix — the lifetime/UAF BLOCKER). `create` publishes the
/// `*Session` into the map UN-refcounted, so the instant it returns a concurrent `DELETE`
/// of the predictable `zdos-sess-<seq>` id may tear the session down and FREE it. A caller
/// that needs the id (e.g. `initialize` echoing the `Mcp-Session-Id` header) must read it
/// from THIS value copy and MUST NOT dereference `session` after the call (the pointer is
/// only safe to deref while the caller holds a refcount, which `create` does not take).
pub const CreateResult = struct { session: *Session, id: SessionId };

pub const SessionRegistry = struct {
    gpa: std.mem.Allocator,
    io: Io,

    /// Guards the map + `count`/`next_seq`/`lru_seq` + each session's `refs`/
    /// `pending_destroy`. CLOCKLESS (no-timeout `Io.Mutex`), held only for O(1) map ops
    /// (NEVER across a worker join or a machine boot), so it stays inside the determinism
    /// grep-gate and never serializes the heavy provisioning work.
    mutex: Io.Mutex = .init,
    /// Signalled when a session's `refs` drops to zero — `destroy` waits on it so a
    /// teardown blocks until every in-flight request on that session has drained.
    drained: Io.Condition = .init,

    /// session-id → `*Session`. Holds ONLY registry-minted sessions; the default session
    /// is resolved separately by the caller (blank/singleton id → default). The key is
    /// the session's OWN `id.slice()` (stable heap storage), so the map never copies it.
    map: std.StringHashMapUnmanaged(*Session) = .empty,

    /// Live minted-session count (≤ `MAX_SESSIONS`). Reserved under the mutex at the
    /// START of `create` so two concurrent creates can never both pass the cap.
    count: usize = 0,
    /// The monotonic id counter — the deterministic source of `zdos-sess-<seq>` (§4.4a).
    /// Never reused, so ids are unique per process even across create/destroy churn.
    next_seq: u64 = 0,
    /// The monotonic REQUEST counter (LRU key source, §4.3). Bumped on every `resolve`.
    lru_seq: u64 = 0,

    /// The resource cap (multi-machine plan §9). At ~21 MiB/session (the EMS slab
    /// dominates), 8 sessions ≈ 168 MiB. A one-line knob; raising it past a couple dozen
    /// would require revisiting the inline EMS backing slab (§12).
    pub const MAX_SESSIONS: usize = 8;

    pub fn init(gpa: std.mem.Allocator, io: Io) SessionRegistry {
        return .{ .gpa = gpa, .io = io };
    }

    /// Pre-size the map to the cap so the `putAssumeCapacity` in `create` (done under the
    /// mutex) never allocates/fails mid-provision. Called once after the registry reaches
    /// its final address.
    pub fn prealloc(self: *SessionRegistry) !void {
        try self.map.ensureTotalCapacity(self.gpa, MAX_SESSIONS);
    }

    /// Destroy every remaining minted session and free the map. Called at server shutdown
    /// AFTER the accept loop has stopped and all connection threads have joined (so no
    /// connection thread still holds a `*Session`), so no refcount wait is needed here.
    pub fn deinit(self: *SessionRegistry) void {
        // Snapshot the live sessions under the lock, clear the map, then tear each down
        // OUTSIDE the lock (a worker join must not hold the global map mutex).
        var pending: [MAX_SESSIONS]*Session = undefined;
        var n: usize = 0;
        self.mutex.lockUncancelable(self.io);
        var it = self.map.valueIterator();
        while (it.next()) |vp| {
            pending[n] = vp.*;
            n += 1;
        }
        self.map.clearRetainingCapacity();
        self.count = 0;
        self.mutex.unlock(self.io);
        for (pending[0..n]) |session| self.teardown(session);
        self.map.deinit(self.gpa);
    }

    /// Provision a fresh machine + worker for a NEW session and return it (multi-machine
    /// plan §4.3). Mints a deterministic `zdos-sess-<seq>` id. Errors at the cap
    /// (`SessionLimitReached`) or if the program will not boot (`BootFailed`). The heavy
    /// work (machine alloc + boot + worker spawn) happens OUTSIDE the registry mutex so it
    /// never blocks concurrent `resolve`/`destroy` on OTHER sessions; only the cap reserve
    /// and the final map insert take the lock.
    /// `cpu_mult` is applied to the fresh machine on THIS (create) thread — uncontended,
    /// after `boot` and BEFORE the worker spawn, so it is a deterministic input at a fixed
    /// post-boot cycle (the live-clock approach (B), no host clock/RNG/float). `owns_mount`
    /// records whether the new session OWNS its `mount_dir` fd (a `provision_machine` opens
    /// a fresh dir → `true`; an `initialize` clone of the default shares `main.zig`'s dir →
    /// `false`); `teardown` closes the fd iff owned (the §5 fd-leak fix).
    pub fn create(self: *SessionRegistry, recipe: LoadRecipe, mount_dir: Io.Dir, cpu_mult: u64, owns_mount: bool) CreateError!CreateResult {
        // Reserve a slot + a seq under the lock (the cap is enforced here, atomically).
        self.mutex.lockUncancelable(self.io);
        if (self.count >= MAX_SESSIONS) {
            self.mutex.unlock(self.io);
            return error.SessionLimitReached;
        }
        const seq = self.next_seq;
        self.next_seq += 1;
        self.count += 1;
        self.mutex.unlock(self.io);
        // On ANY failure below, release the reserved slot (the errdefers above this one
        // free the partially-built session in reverse order first).
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.count -= 1;
            self.mutex.unlock(self.io);
        }

        // Build the machine exactly as main.zig's fresh-launch path: init + wire + boot.
        const m = try self.gpa.create(Machine);
        errdefer self.gpa.destroy(m);
        try m.init(self.gpa, &.{});
        errdefer m.deinit();
        m.wire();
        // Map the loader's OWN failure cause so the caller can report the precise code
        // (plan §8): `error.NotFound` (the program file is not in the mount) is a CLIENT
        // input error (`-32602`), distinct from a genuine load fault. The DOS loader
        // resolves the host name through the case-insensitive vfs, so propagating its
        // `NotFound` is strictly more faithful than a host-side case-sensitive pre-stat
        // (which would falsely miss a `BAK.EXE` stored as `bak.exe`).
        m.boot(recipe.drive, mount_dir, self.io, recipe.file[0..recipe.file_len], recipe.cmdtail[0..recipe.cmdtail_len]) catch |err| switch (err) {
            error.NotFound => return error.ProgramNotFound,
            else => return error.BootFailed,
        };

        // The Controller over the heap-pinned machine — heap-allocated so its address is
        // stable for the worker (the worker dereferences `session.ctrl`).
        const ctrl = try self.gpa.create(Controller);
        errdefer self.gpa.destroy(ctrl);
        ctrl.* = Controller.init(m);
        // Apply the requested CPU:PIT multiplier now (uncontended — no worker yet), exactly
        // as a `set_clock` would on the worker, but at this fixed post-boot cycle. Integer-
        // only, clamped to `[1, MAX_MULT]`; the applied value rides the machine snapshot.
        _ = ctrl.setCpuMult(cpu_mult);

        // The Session block (its own heap address; the worker captures `&session.queue`).
        const session = try self.gpa.create(Session);
        errdefer self.gpa.destroy(session);
        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "zdos-sess-{d}", .{seq}) catch unreachable;
        session.* = try Session.init(self.gpa, self.io, SessionId.fromSlice(id_text), ctrl, recipe, mount_dir);
        errdefer session.deinit(self.gpa);
        // Snapshot the minted id BY VALUE now, while we still SOLELY own `session` (it is not
        // in the map yet, so no `resolve`/`destroy` can reach it). After the publish below a
        // concurrent `DELETE` could free `session`, so the caller must use THIS copy, never
        // re-read `session.id` (the lifetime/UAF fix).
        const minted_id = session.id;
        session.owned_machine = m;
        session.owned_ctrl = ctrl;
        session.owns_mount = owns_mount;
        session.destroyable = true;
        // Wire the hub now that the session is at its final address.
        session.wireStream(self.io);

        // Spawn this session's worker (the sole owner of its machine).
        const w: worker_mod.Worker = .{
            .queue = &session.queue,
            .ctrl = session.ctrl,
            .mount_dir = session.mount_dir,
            .io = self.io,
            .render = session.render,
            .live_mouse = session.live_mouse,
        };
        session.worker_thread = try std.Thread.spawn(.{}, worker_mod.Worker.run, .{w});
        errdefer {
            var sc: q.RequestCtx = .{ .cmd = .shutdown_worker };
            _ = session.queue.submit(&sc);
            if (session.worker_thread) |t| t.join();
        }

        // Publish into the map (capacity pre-reserved, so this cannot fail). The key is
        // the session's OWN id storage (stable heap), valid for the entry's lifetime.
        self.mutex.lockUncancelable(self.io);
        self.map.putAssumeCapacity(session.id.slice(), session);
        self.mutex.unlock(self.io);
        // Return the id by VALUE; the caller must NOT dereference `session` (a concurrent
        // DELETE may already have freed it now that it is published un-refcounted).
        return .{ .session = session, .id = minted_id };
    }

    /// Route an `Mcp-Session-Id` to its session, bumping the in-flight refcount + the LRU
    /// stamp. The caller MUST pair a successful resolve with `release`. Returns null for an
    /// unknown / being-destroyed id (the caller replies a JSON-RPC error). The BLANK and
    /// the default-singleton ids are handled by the caller (→ the default session), never
    /// here — this only resolves minted sessions.
    pub fn resolve(self: *SessionRegistry, id_slice: []const u8) ?*Session {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.map.get(id_slice) orelse return null;
        if (session.pending_destroy) return null; // mid-teardown — treat as gone
        session.refs += 1;
        self.lru_seq += 1;
        session.last_request_seq = self.lru_seq;
        return session;
    }

    /// Drop an in-flight reference taken by `resolve`. A no-op for the default session
    /// (never refcounted). When the last reference on a session pending destruction drops,
    /// wake the waiting `destroy`.
    pub fn release(self: *SessionRegistry, session: *Session) void {
        if (!session.destroyable) return;
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(session.refs > 0);
        session.refs -= 1;
        if (session.refs == 0 and session.pending_destroy) self.drained.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Explicit teardown (`DELETE /mcp`): remove the id from the map (so no NEW request can
    /// resolve it), wait for in-flight requests to drain, then stop + join the worker and
    /// free the machine/buffers. Returns false if the id is unknown (not a minted session).
    /// Leak-free and race-free: the map removal + the refcount drain are the barrier
    /// against a concurrent request, and the worker join is the barrier against in-flight
    /// queue work — both complete BEFORE any free.
    pub fn destroy(self: *SessionRegistry, id_slice: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        const kv = self.map.fetchRemove(id_slice) orelse {
            self.mutex.unlock(self.io);
            return false;
        };
        const session = kv.value;
        session.pending_destroy = true;
        // Wait (clockless) until every connection that resolved this session has released
        // it. Removal-before-wait guarantees no NEW resolve can take a ref, so this drains.
        while (session.refs > 0) self.drained.waitUncancelable(self.io, &self.mutex);
        self.count -= 1;
        self.mutex.unlock(self.io);
        self.teardown(session);
        return true;
    }

    /// Stop + join a session's worker and free its machine, controller, and heap buffers.
    /// Called only when no other thread can reach `session` (after map removal + refs==0,
    /// or at `deinit` when all connections have joined). Holds NO registry lock (a worker
    /// join must never hold the global map mutex).
    fn teardown(self: *SessionRegistry, session: *Session) void {
        // §9.1 ordering: stop the session's stream threads (none for a minted session, but
        // the hub is wired so this is well-defined), then drain + join the worker.
        session.stream_hub.shutdown();
        var sc: q.RequestCtx = .{ .cmd = .shutdown_worker };
        _ = session.queue.submit(&sc);
        if (session.worker_thread) |t| t.join();
        session.worker_thread = null;
        // Snapshot the mount ownership BEFORE freeing the session block (the close happens
        // last, once nothing can touch the dir).
        const owns_mount = session.owns_mount;
        const mount_dir = session.mount_dir;
        if (session.owned_machine) |m| {
            m.deinit();
            self.gpa.destroy(m);
        }
        if (session.owned_ctrl) |c| self.gpa.destroy(c);
        session.deinit(self.gpa);
        self.gpa.destroy(session);
        // Close the OWNED mount fd LAST — the worker is joined and the machine is freed, so
        // nothing can touch the dir now (the §5 fd-leak fix). A provisioned session owns its
        // fresh `Io.Dir`; the DEFAULT session does NOT (`main.zig` owns + closes that one),
        // so closing it here would double-close it.
        if (owns_mount) mount_dir.close(self.io);
    }

    /// Live minted-session count (for the cap-aware caller / tests). Takes the lock.
    pub fn liveCount(self: *SessionRegistry) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.count;
    }

    /// Snapshot the live minted sessions into `out` and PIN each (refcount++), returning the
    /// count written (capped at `out.len`). The read-only `list_machines` tool needs a stable
    /// set of `*Session` to read each machine's small metadata from — but it must not hold the
    /// registry mutex while doing so (that work submits to per-session workers / takes per-
    /// session locks). Pinning under the mutex here lets the caller release the mutex, read the
    /// metadata OFF the global lock, and tear-down-safely: a concurrent `destroy` removes the
    /// id + drains the refcount, so a pinned session cannot be freed mid-read. The caller MUST
    /// pair EACH returned session with `release` (exactly like a `resolve`). Skips a session
    /// already `pending_destroy` (mid-teardown — treat as gone), mirroring `resolve`.
    pub fn snapshotLive(self: *SessionRegistry, out: []*Session) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        var it = self.map.valueIterator();
        while (it.next()) |vp| {
            if (n >= out.len) break;
            const s = vp.*;
            if (s.pending_destroy) continue;
            s.refs += 1;
            out[n] = s;
            n += 1;
        }
        return n;
    }
};
