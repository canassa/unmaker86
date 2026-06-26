# Multi-Machine, Threaded Execution Model ("Model B")

Status: design doc (no code yet). Targets Zig 0.16, `zdos` at repo root.

This plan adds a **multi-tenant, session-routed** execution model: one `zdos`
process runs **multiple independent emulated machines concurrently**, each on its
own thread, each driven by a different debugger client (MCP first, the existing
`/api/*` HTTP API second). One client's long-running `run` must never block
another client's request.

Every claim below is grounded in the source; file:line citations are inline.

---

## 1. Overview, goals, non-goals

### Goal — Model B (the chosen model)

- **N concurrent machines in one process.** Each `(Machine, Controller, queue,
  worker thread, RunControl, RunPacer, render buffers, live-mouse, stream hub,
  load recipe)` becomes a **Session**. Sessions are isolated: per-machine
  determinism is preserved, and cross-thread scheduling affects only wall-clock
  latency, never any guest's instruction stream.
- **Session-routed transport.** MCP clients address a session via
  `Mcp-Session-Id` (`src/api/mcp.zig:39`). The single listening socket fans out
  requests to the correct session's command queue.
- **Concurrency in the *transport*, determinism in the *core*.** The simulation
  core stays single-threaded *per machine* (one worker thread owns one
  Controller); concurrency is only across sessions and across connections.

### Non-goal — Model A (rejected)

"N separate `zdos` processes on N ports" is explicitly **not** the solution. It
sidesteps the routing/lifecycle problem instead of solving it, gives no shared
process surface (one MCP endpoint, one resource pool, one binary), and a prior
audit mistakenly costed *this* model rather than Model B. Model A is mentioned
only to be ruled out.

### Hard constraints (CLAUDE.md, these outrank the task)

1. **Per-machine determinism.** Same binary + same inputs ⇒ byte-identical state
   at cycle N. The only time source is `cpu.st.cycles`
   (`src/machine/machine.zig:24-28`). No RNG/host-clock/uninitialized state may
   reach guest state. Parallelism may change *only* wall-clock latency.
2. No shortcuts/fakes/stubs/mocks.
3. If something cannot be done faithfully, STOP and surface it (see §12).

---

## 2. Resolution of the two open questions (the de-risking spikes)

A prior audit *asserted* these were fine without proof. Both are now verified
against `references/zig/lib/std/`. Both come back **safe**, which is what lets the
rest of this plan be "concurrency in the transport" rather than a heavier
event-loop rearchitecture.

### 2.1 Allocator thread-safety — VERIFIED SAFE

`main(init: std.process.Init)` takes `gpa = init.gpa`
(`src/main.zig:28-29`). In the stdlib, `Init.gpa` is documented:

> "A default-selected general purpose allocator ... **Threadsafe.**"
> — `references/zig/lib/std/process.zig:36-39`

What actually backs `gpa` depends on build mode
(`references/zig/lib/std/start.zig:704-713`):

- **Debug / ReleaseSafe (no libc):** `debug_allocator.allocator()` — a
  `DebugAllocator(.{})`. Its config defaults `thread_safe = !builtin.single_threaded`
  (`references/zig/lib/std/heap/debug_allocator.zig:127`), and every
  alloc/free/resize/remap takes an internal `Io.Mutex`
  (`debug_allocator.zig:197-198, 721-722, 834-835, 853-854, 871-872`). Thread-safe.
- **ReleaseFast/Small (multi-threaded, no libc):** `std.heap.smp_allocator`. Its
  module doc states it is explicitly designed for multi-threading: per-thread
  freelists, each operation grabs its slot's lock and moves to the next slot on
  contention (`references/zig/lib/std/heap/SmpAllocator.zig:1-28`). Thread-safe.
- **with libc:** `std.heap.c_allocator` (libc malloc) — thread-safe by C-standard
  guarantee.

**Verdict:** N machine threads can `gpa.create(Machine)` / allocate concurrently
without heap corruption, in every build mode this project ships. No wrapper is
needed.

**Fallback (kept, not needed):** if a future change to the build introduced a
non-thread-safe `gpa` (e.g. a single-threaded ReleaseFast build), wrap it once at
startup in a `std.heap.ThreadSafeAllocator` and pass *that* down. Session
provisioning is rare (one alloc per `initialize`), so the wrapper's lock is never
on a hot path. Per-session arenas are an alternative but are unnecessary given the
above, and would complicate the existing inline-field ownership of `Machine`.

### 2.2 Sharing one `std.Io` across N blocking-socket threads — VERIFIED SAFE

`io = init.io` (`src/main.zig:30`). `Init.io` is documented "Threadsafe"
(`references/zig/lib/std/process.zig:40-42`) and is always a `std.Io.Threaded`
instance (`references/zig/lib/std/start.zig:724, 744`). The `Threaded` struct's
own doc-comment says **"Thread-safe."**
(`references/zig/lib/std/Io/Threaded.zig:24`).

The load-bearing question is whether a *blocking* op (accept/read/write) on one
thread holds a global lock that would serialize all other threads. It does not.
The `Threaded.mutex` is used **only** for the async task-queue / worker-spawn
machinery (`Threaded.zig:1707-2257` are `async`/`asyncConcurrent`/`select`
plumbing). The blocking syscall paths ignore it entirely:

- `netAcceptPosix(userdata, ...)` binds `const t = @ptrCast(...); _ = t;` then
  loops on a raw `accept4()`/`accept()` syscall with `Syscall.start()/finish()`
  cancel handling — **no mutex** (`Threaded.zig:12554-12601`).
- `netReadPosix(...)` likewise `_ = t;` then a raw `readv`/`recv` loop — **no
  mutex** (`Threaded.zig:12667+`).
- `netWritePosix(...)` follows the same pattern (`Threaded.zig:13136+`).

So thread A blocked in `accept` does not stop thread B from `read`/`write` on its
own socket, nor from a third thread allocating. The blocking model is exactly
"one OS thread per blocking call," which is precisely the thread-per-connection
shape this plan uses.

The clockless handoff primitives the queue already uses —
`Io.Mutex.lockUncancelable` / `Io.Condition.waitUncancelable`
(`src/api/queue.zig:13-16, 417-462`) — are likewise per-instance and futex-backed
with no shared global state, so N independent queues each with its own mutex/cond
are safe.

**Verdict:** one shared `io` is safe for N threads each doing blocking
accept/read/respond plus `Io.Mutex`/`Condition` waits. This is the gotcha that
*could* have forced a single-event-loop rearchitecture; it does not. **The rest
of the plan is therefore a thread-per-connection + per-session-worker design, not
an async/fiber redesign.**

**Fallback (kept, not needed):** if a future Io backend (e.g. a single-threaded
`Uring` or fiber backend selected by build) made one shared `io` unsafe for N
*OS* threads, the fix is structural, not local: drive all connections from the
event loop with `io.async`/`io.concurrent` per request and keep the per-session
worker as the only OS thread that runs the machine. That would change §5 (connection
handling) but **not** §3-§4 or §8 (ownership, registry, determinism), because the
machine core never touches `io`. This is the honest worst case from §12.

---

## 3. Architecture and ownership map

### 3.1 Diagram

```
                         one zdos process
  ┌──────────────────────────────────────────────────────────────────┐
  │ PROCESS-GLOBAL                                                      │
  │   gpa (thread-safe)   io (std.Io.Threaded, thread-safe)            │
  │   net.Server listener (single bound socket)                        │
  │   const tables (opcodes, scancodes, fonts, palettes)              │
  │   SessionRegistry  (map: session-id -> *Session, + mutex + cap)   │
  └──────────────────────────────────────────────────────────────────┘
        │ accept()                       
        ▼                                
  ┌─────────────┐  spawns per connection 
  │ accept loop │ ───────────────────────┐
  └─────────────┘                        ▼
                              ┌────────────────────────┐  (thread-per-conn,
                              │ connection handler      │   per-conn scratch:
                              │  parse → route by sid   │   rbuf/wbuf/resp_buf/
                              │  → session.queue.submit │   mcp_body_buf/...)
                              └───────────┬────────────┘
                                          │ submit (blocks this conn only)
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                  ▼
  ┌───────────┐                     ┌───────────┐                     ┌───────────┐
  │ Session A │                     │ Session B │                     │ Session C │
  │  Machine  │                     │  Machine  │                     │  Machine  │
  │  Controller                     │  ...      │                     │  ...      │
  │  CommandQueue + worker thread   │           │                     │           │
  │  RunControl + RunPacer thread   │           │                     │           │
  │  RenderBuffers / SharedFrame /  │           │                     │           │
  │  StreamHub / LiveMouseState /   │           │                     │           │
  │  LoadRecipe / mount_dir         │           │                     │           │
  └───────────┘                     └───────────┘                     └───────────┘
   own time = cpu.st.cycles (A)      own cycles (B)                    own cycles (C)
```

### 3.2 What becomes PER-SESSION

Everything currently embedded in / owned by `Server` that is tied to one machine.
Today these are "per-Server singletons" because there is one Server == one
machine; under Model B they are per-Session:

- `*Controller` over the heap-pinned `*Machine` (`src/main.zig:113-139`). The
  Machine is fully self-contained: CPU, RAM slab, PIC/PIT/VGA/keyboard/OPL/
  speaker, scheduler, BIOS, DOS, callback bridge — all inline/heap-owned, with
  self-pointers pinned by `wire()` (`src/machine/machine.zig:8-20, 310-460`).
  **Spot-verified:** the only time source is `cpu.st.cycles`
  (`machine.zig:24-28`), devices read it via per-machine back-pointers
  (`machine.zig:383-434`), and there is no module-scope `var`, `threadlocal`, or
  singleton in the machine graph. Two machines share nothing mutable IN-PROCESS (RAM/
  CPU/devices); the writable host mount dir is the one shared, caller-managed external
  input, not zdos state (§13 / Finding 4 — host-FS isolation is the caller's job).
- `CommandQueue` — currently inline in `Server` (`src/api/server.zig:134`,
  `queue.zig:384`). It is already self-contained (its own `submit_gate`/`mutex`/
  `work_ready` live inside the struct, `queue.zig:386-401`). **Spot-verified:** N
  independent queues need zero code change.
- The **worker thread** — spawned per server today (`server.zig:290-291`,
  `worker.zig:485-497`), no statics. One per session.
- `RunControl` (`server.zig:143`, `run_control.zig`) — clockless atomics, one per
  session.
- `RunPacer` — host thread, one per session (`src/host/run_pacer.zig`,
  `main.zig:175-195`).
- `RenderBuffers` (~4 MiB; see §9), `SharedFrame` (~308 KiB), `StreamHub`
  (`server.zig:159-172`, `worker.zig:49-66`, `shared_frame.zig`, `stream.zig`).
- `LiveMouseState` (`server.zig:150`).
- `LoadRecipe` + `mount_dir` (`server.zig:93-132`).

### 3.3 What stays PROCESS-GLOBAL

- **`gpa`** and **`io`** — verified thread-safe (§2). Shared by all sessions.
- The **single listening `net.Server`** — one bound socket, accept loop fans out.
- All **const/comptime tables** (opcode dispatch, scancodes, fonts, palettes) —
  read-only, safe to share.
- The new **SessionRegistry** (§4).

### 3.4 What becomes PER-CONNECTION (transient request scratch)

This is the specific buffer-ownership split the audit flagged. Today the per-
request scratch lives **on the `Server`** and is reused because "one connection at
a time" (`server.zig:174-189`):

- `resp_buf [32 KiB]`, `body_buf [64 KiB]`, `read_scratch [64 KiB]`,
  `mcp_body_buf [32 KiB]`, `mcp_session_buf [128]`, `mcp_session_len`, and the
  per-request `arena` (`server.zig:175-188, 219`).
- The stack-local `rbuf [16 KiB]` / `wbuf [8 KiB]` already live in
  `handleConnection` (`server.zig:373-377`) — those are *already* per-connection.

Under concurrency, the `Server`-owned scratch becomes a data race. **The fix: move
the transient request scratch to a per-connection struct** owned by the connection
handler's stack/heap (allocated when a connection is accepted, freed when it
closes). The comment at `server.zig:174` ("safe to reuse ... one connection at a
time") is the exact invariant being broken; per-connection ownership restores it.

**The split (design point):**

- **Per-connection, transient scratch** (lifetime = one connection): `resp_buf`,
  `body_buf`, `read_scratch`, `mcp_body_buf`, `mcp_session_buf`, the per-request
  `arena`, and the proposed **screenshot/framebuffer streaming scratch** for that
  request. None of these hold machine state; they are wire-format work areas.
- **Per-session, machine-tied render buffers** (lifetime = one session):
  `RenderBuffers` and `SharedFrame`. These are large (~4 MiB) and are written by
  the *worker* (the sole machine owner) via the pure peek
  (`worker.zig:404-419`); the response only carries a small descriptor
  (`FramebufferResult`, `queue.zig:288-305`) and the binary pixels are streamed
  from the session buffer, never through `resp_buf`. They must stay session-scoped
  so a capture for session A never lands in session B's buffer, and so a per-
  connection request can stream them without re-allocating 4 MiB per request.

So: small JSON/transport scratch is **per-connection**; the big machine-tied pixel
buffers are **per-session**. A connection handler holds a `*Session` and a
`*ConnScratch`; it reads pixels out of `session.render` but builds JSON in
`conn.resp_buf`.

---

## 4. Session registry and lifecycle

### 4.1 The `Session` struct (shape)

Phase 1 (§10) extracts today's per-Server singletons into one struct, with no
behavior change:

```zig
pub const Session = struct {
    id: SessionId,                 // see §4.4 (id generation)
    machine: *Machine,            // heap-pinned, wire()'d
    ctrl: Controller,             // inline; bound to its final address after pin
    queue: q.CommandQueue,
    worker_thread: ?std.Thread = null,
    run_control: *run_control.RunControl,
    pacer: host.RunPacer,         // its own host thread
    render: *worker_mod.RenderBuffers,
    shared_frame: *sf.SharedFrame,
    stream_hub: *stream_mod.StreamHub,
    live_mouse: *live_mouse_mod.LiveMouseState,
    recipe: LoadRecipe,
    mount_dir: Io.Dir,
    // lifecycle bookkeeping (no wall clock — see §4.3):
    last_request_seq: u64 = 0,    // monotonic request counter for LRU
};
```

`Server` (the listener side) shrinks to: `gpa`, `io`, the listener socket, the
`SessionRegistry`, and per-connection scratch handling. The transport-independent
`writeX` body builders and the routing tables stay on `Server` (they are
session-agnostic; they operate on a `*Session` argument).

### 4.2 The registry interface

```zig
pub const SessionRegistry = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: std.Thread.Mutex = .{},          // guards the map only (clockless)
    map: std.AutoHashMapUnmanaged(SessionId, *Session) = .empty,
    count: usize = 0,
    seq: u64 = 0,                            // request counter (LRU key source)

    pub const MAX_SESSIONS: usize = 8;       // see §9

    /// Provision a fresh machine + worker + pacer for `id`. Errors at the cap.
    pub fn create(self: *SessionRegistry, id: SessionId,
                  recipe: LoadRecipe, mount_dir: Io.Dir) !*Session;

    /// Look up by id (transport-routed). Bumps the session's LRU seq.
    pub fn resolve(self: *SessionRegistry, id: SessionId) ?*Session;

    /// Explicit teardown: stop pacer, drain+join worker, deinit machine, free.
    pub fn destroy(self: *SessionRegistry, id: SessionId) bool;

    /// The single default session for the back-compat HTTP path (§6).
    pub fn default(self: *SessionRegistry) *Session;
};
```

The registry's `mutex` is a plain `std.Thread.Mutex` — it guards only the hashmap
and `count`/`seq`, never machine state, and is held for O(1) map ops. It is **not**
in the `src/api` determinism grep-gate path (see §4.4 / §8 for where it must
live). Because it touches no machine cycle and no clock, it does not affect
per-machine determinism.

### 4.3 Creation, addressing, destruction, GC

- **Create.** An MCP `initialize` provisions a Session: `gpa.create(Machine)`,
  `m.init` + `m.wire` + `m.boot(...)` exactly as `main.zig:113-130` does today,
  then spawn that session's worker (`worker.zig` `Worker.run`) and pacer
  (`run_pacer.zig` `start`). The `initialize` reply carries the new
  `Mcp-Session-Id`. (See §7 for migrating the current fixed-id PoC.)
- **Address.** Subsequent MCP requests carry `Mcp-Session-Id`
  (`mcp.zig:39`, captured in `serveRequest`, `server.zig:444-455`). The
  connection handler resolves it to the `*Session` before any submit.
- **Destroy.** An explicit `DELETE /mcp` with the session header tears the
  session down: disarm + join the pacer (the §9.1 ordering, `server.zig:346-361`,
  `run_pacer.zig:92-98`), drain the worker with the `shutdown_worker` sentinel
  (`queue.zig:172`, `worker.zig:489-492`), join the worker, `machine.deinit()` +
  `gpa.destroy(machine)`, free the per-session heap blocks, remove from the map.
- **GC (determinism-clean).** Sessions must be reclaimed if a client vanishes
  without `DELETE`, **but never via a wall-clock sweep** (a timed sweep would
  introduce host-time-dependent teardown, and the determinism grep already bans
  `Clock`/`io.sleep`/`Instant`, `determinism_test.zig:68-77`). Use **LRU by
  request count**: each resolve bumps `last_request_seq = ++registry.seq`; at the
  cap (§9), a new `create` evicts the session with the lowest seq (least-recently
  *requested*, not least-recently in wall time). This is fully deterministic given
  a request order and needs no clock. Explicit `DELETE` is the primary path; LRU
  is the safety net.

### 4.4 Session-id generation (the determinism carve-out)

A session id is **transport-only**: it routes a request to a queue and never
enters guest state, the cycle ledger, or any `Command`/`Response` POD
(`queue.zig:62-363`, all pointer-free, reflection-tested
`determinism_test.zig:128-146`). So a *random* id does **not** violate
*per-machine* determinism.

However, a random generator (`std.Random`/`getrandom`) **would trip the
determinism source-grep** (`determinism_test.zig:56-78` forbids `std.Random`,
`std.rand`). Two viable schemes, recommend (a):

- **(a) Deterministic id scheme — RECOMMENDED.** `id = "zdos-sess-" ++ dec(seq)`
  where `seq` is the registry's monotonic counter. Pros: no grep carve-out, no RNG,
  trivially reproducible in tests, and the ids are still unique per process. Cons:
  ids are guessable — acceptable because the server already binds loopback-only
  (`server.zig:293`, `Ip4Address.loopback`) and is a local debugger, not a public
  multi-user service. **This is the chosen scheme.**
- **(b) Random id with a documented transport-only carve-out.** If unguessable
  ids are ever required, generate via `getrandom` in a NEW file *outside* the
  embedded `api_sources` set (`determinism_test.zig:22-53`) — mirroring exactly
  how the wall clock was moved to `src/host/run_pacer.zig` to stay outside the
  gate (`run_pacer.zig:3-11`). Put a one-line carve-out in the test asserting the
  id generator is the *only* RNG and lives outside `src/api`. Not chosen for v1.

The fixed PoC id `"zdos-mcp-singleton"` (`mcp.zig:38`) becomes the **default
session's** id (§6, §7), keeping the existing MCP behavior for a client that does
not send `initialize`.

`SessionId` itself is a fixed-capacity, pointer-free value type
(`struct { buf: [128]u8, len: u8 }`) so it can be a hashmap key and copied freely
— matching the existing `[128]u8` session-header capture (`server.zig:187`).

---

## 5. Concurrent connection handling

### 5.1 Replace the serial accept loop

Today `serve()` is strictly serial: a `while (true)` accept loop, one connection
handled inline, `keep_alive = false`, **no per-connection thread spawn** (only the
worker thread is spawned) (`server.zig:306-325`, with the determinism rationale at
`server.zig:23-26`). The serial-ness is what makes the `Server`-owned scratch safe
(`server.zig:174`).

**Chosen approach: thread-per-connection (bounded by a connection semaphore).**

Rationale:

- §2.2 proved blocking accept/read/write on one thread does not block others.
  Thread-per-connection is the natural fit for `std.Io.Threaded` blocking I/O.
- The existing code is already a "spawn a thread that owns a socket" shape: the WS
  stream upgrade hands the socket to a dedicated stream thread
  (`server.zig:313-316, 384-391`; `stream.zig` per-connection threads). We are
  generalizing that pattern to *every* connection.
- A request blocks only its own connection thread inside `queue.submit`
  (`queue.zig:417-435`); other connections (and other sessions) proceed. This is
  the exact "one client's long run must not block another" requirement.

**Bounded, not unbounded:** a global connection cap (e.g. `MAX_CONNS_TOTAL`,
mirroring the per-session stream cap `MAX_CONNS = 4`, `stream.zig:39-40`) is
enforced with a counting semaphore (or atomic counter) checked right after
`accept`. Over the cap, the handler responds `503 service_unavailable` and closes
— the same back-pressure idiom already used for the stream cap and the input FIFO
(`queue.zig:213-217`). Back-pressure is preferable to an unbounded thread
explosion and keeps memory bounded (§9).

*Alternative considered — a fixed worker pool draining a connection queue.* It
caps threads more tightly but adds a second queue and a head-of-line-blocking risk
(a slow connection in a pool slot). Given blocking I/O is cheap to park and the
session count is small (§9), thread-per-connection with a cap is simpler and has
no head-of-line blocking. Recommended.

### 5.2 Per-connection scratch ownership

When a connection is accepted, allocate its `ConnScratch` (the §3.4 transient
buffers). Options:

- Stack-allocate the small buffers in the connection thread's entry frame (like
  today's `rbuf`/`wbuf`, `server.zig:373-377`) and keep them for the connection's
  lifetime. `resp_buf`/`body_buf`/`read_scratch`/`mcp_body_buf` total ~192 KiB —
  large for a default 8 MiB-ish thread stack but acceptable; or
- Heap-allocate `ConnScratch` via `gpa` (thread-safe, §2.1) at accept, free at
  close. **Recommended** (keeps thread stacks small, explicit lifetime).

The per-request `arena` moves into `ConnScratch` and is `reset(.retain_capacity)`
per request exactly as today (`server.zig:719-722`).

### 5.3 Routing a request to a session's queue

1. Connection thread reads the head, captures route + `Mcp-Session-Id` into
   `ConnScratch` (today's capture logic, `server.zig:422-455`).
2. Resolve `*Session` (registry lookup for `/mcp`; the default session for
   `/api/*`, §6).
3. Build the `Command` and `session.queue.submit(&ctx)` — the submit blocks only
   this connection thread until *that session's* worker completes it. The
   submit-gate (`queue.zig:387-398`) still serializes the producers of *one*
   session (its pacer, stream producer, and now multiple connection threads
   targeting the same session), which is exactly its purpose and already
   multi-producer-safe.
4. Serialize the `Response` into `ConnScratch.resp_buf` and `request.respond(...)`.

### 5.4 `keep_alive`

Stays `false` (`server.zig:21-26`): one request per connection. With thread-per-
connection this is fine — each request is its own short-lived thread. Keeping it
false preserves the "one command in flight per connection" simplicity and avoids
buffer-reuse-across-requests aliasing. (A later optimization could enable
keep-alive per connection since the scratch is now per-connection, but it is out
of scope and not needed for Model B.)

---

## 6. Routing and backward compatibility

`--serve PORT` must keep working unchanged: a single machine, the full existing
`/api/*` surface, the shipped MCP singleton behavior.

**The design decision: HTTP stays single-default; MCP is multi-session.**

- At `--serve` startup, create **one default Session** (id = the existing
  `"zdos-mcp-singleton"`, `mcp.zig:38`) and boot it exactly as `main.zig:113-130`
  does today. This is the registry's `default()` (`§4.2`).
- **`/api/*` routes** (`server.zig:489-693`) all assume one machine and carry no
  session header. **They route to the default session.** This is faithful: the
  existing single-machine HTTP debugger is unchanged; it simply drives session 0.
- **`/mcp`** resolves `Mcp-Session-Id` through the registry. A request with no /
  blank id resolves to the default session (preserving today's behavior,
  `server.zig:1290-1293`). An `initialize` *may* mint a new session and return its
  id; subsequent requests with that id reach the new session.

**Options considered for HTTP multi-session:**

- *(A) HTTP stays single-default (RECOMMENDED).* Zero churn to 40+ `/api/*`
  routes and to `server_test.zig`'s assumptions; MCP is where multi-tenancy is
  actually needed (the MCP clients are the concurrent drivers). Faithful and
  minimal.
- *(B) Add an optional `X-Zdos-Session` header to `/api/*`.* Routes to the named
  session if present, else default. A clean extension if a future browser UI wants
  to drive a specific machine. **Defer to a later phase** — the routing seam (a
  `*Session` argument threaded into the handlers) makes (B) a small addition once
  the per-session refactor lands; do not build it in v1.

So v1: HTTP == default session; MCP == registry-routed with a default fallback.

---

## 7. The MCP layer interaction (growing the resolver seam)

Today the MCP layer is a deliberate PoC seam (mcp-plan.md R7):

- A single fixed id constant `"zdos-mcp-singleton"` (`mcp.zig:32-39`).
- A trivial resolver: `resolveSession(self, sid) *Server { _ = sid; return self; }`
  (`server.zig:1290-1293`).
- `handleMcp` calls `resolveSession` once, then threads the resulting `session`
  pointer through `handleMcpToolCall` / `buildMcpLoad`
  (`server.zig:1306-1310, 1347, 1353, 1383-1387`). Crucially, **the seam already
  passes a `session` object into the tool-call path** — it just happens to be the
  one `*Server` today.

**How the seam grows (an extension, not a rewrite):**

1. `resolveSession` changes from returning `*Server` to returning `*Session`:
   `fn resolveSession(self, sid) ?*Session`. For a blank/absent id it returns the
   registry's `default()` (preserving today's behavior); for a known id it returns
   the mapped session; for an unknown id it returns `null` → the handler replies a
   JSON-RPC error (a new "unknown session" case, or `initialize`-required).
2. `handleMcpToolCall` / `buildMcpLoad` already take a `session` param
   (`server.zig:1353, 1439`); their bodies change from `session.run_control` /
   `session.queue` (where `session` was a `*Server`) to the same fields on
   `*Session` (the fields moved there in Phase 1, §10). The *call sites* of
   `session.run_control.beginDebugger()` / `session.queue.submit(&ctx)`
   (`server.zig:1383-1387`) are **unchanged in shape** — only the type of
   `session` changes.
3. `initialize` (`server.zig:1345` → `respondMcpInitialize`) gains the ability to
   mint a session: it calls `registry.create(nextId(), recipe, mount_dir)` and
   echoes the new id in the reply's `Mcp-Session-Id` (the response already echoes
   the id today via the initialize handler). A client that never calls
   `initialize` keeps using the default session — so **the shipped MCP tools and
   `mcp_test.zig` keep passing** with no protocol change.
4. `DELETE /mcp` is added to the dispatch (`server.zig:699-702` currently only
   handles `POST /mcp`): on `DELETE` with a session header, call
   `registry.destroy(id)` and reply 200/204.

Because the tool catalog, the args→Command mapping (`mcp_tools.zig`), and the
shared `writeX` body builders are all session-agnostic (they operate on a queue +
a response), **none of them change**. The migration is: (1) move per-Server fields
to `Session`, (2) retype `resolveSession`, (3) teach `initialize`/`DELETE` the
registry. The PoC's fixed id becomes the default session id, so nothing breaks.

---

## 8. Determinism analysis (point-by-point)

The prime directive is *per-machine* determinism. The argument that the threaded
model preserves it:

1. **No shared cycle counter.** Each Machine's only time source is its own
   `cpu.st.cycles` (`machine.zig:24-28, 257-276`); devices/scheduler derive timing
   from per-machine back-pointers bound in `wire`
   (`machine.zig:383-434`). Two Machines share no cycle/clock state, so no
   interleaving of their worker threads can perturb either's ledger.
2. **No RNG, no host clock in the core or the api path.** The determinism grep
   (`determinism_test.zig:55-87`) already forbids `std.time`, `std.Random`,
   `Clock`, `io.sleep`, `Instant`, etc. across every `src/api` source. The new
   code (registry, per-connection handling) lives in `src/api` and **must stay
   inside this gate** — it uses only `gpa`, `io` blocking calls, `std.Thread`,
   `std.Thread.Mutex`/`std.atomic`, and clockless `Io.Mutex`/`Condition`. The
   registry's LRU uses a request counter, not a clock (§4.3).
3. **Session id is transport-only.** It never enters a `Command`/`Response` POD
   (all pointer-free, `queue.zig:62-363`; reflection-tested
   `determinism_test.zig:128-146`), the cycle ledger, or guest RAM. The chosen
   deterministic id scheme (§4.4) keeps the grep green; the random fallback would
   live outside `src/api` exactly like `run_pacer.zig` (`run_pacer.zig:3-11`).
4. **Cross-thread scheduling affects only wall-clock latency.** A guest advances
   *only* inside the single `Controller.run*`/`step*` call on its own worker
   thread (`worker.zig:1-13, 96-181`); that call reads no host clock. Whether
   session B's worker runs before, during, or after session A's changes only when
   the HTTP response comes back, never which instructions ran. This is the same
   property the existing single-machine worker already guarantees
   (`queue.zig:18-22`), now replicated N times with no shared mutable state
   between the replicas.
5. **The submit-gate stays correct under more producers.** A session's queue may
   now have multiple connection-thread producers plus its pacer + stream producer.
   The `submit_gate` already serializes *all* producers of one queue for the whole
   submit-and-wait (`queue.zig:387-435`) and asserts one-in-flight by construction
   — this is exactly the multi-producer case it was built for; it holds unchanged.

**Extending the determinism test posture:**

- The `src/api` forbidden-needle grep (`determinism_test.zig:55-87`) auto-covers
  any new `src/api` source as long as the new files are added to `api_sources`
  (`determinism_test.zig:22-53`). **Add the registry/session files there.**
- The Command/Response POD reflection (`determinism_test.zig:128-146`) auto-covers
  any new fields. A `SessionId` field, if it ever appeared in a Command (it should
  not — routing happens before the command is built), would be a fixed `[128]u8`
  and pass; better, keep the id out of the PODs entirely (it is a routing key, not
  a command payload).
- Add a **positive** assertion that the id generator (if random/(b)) is the only
  RNG and lives outside `src/api`, mirroring `determinism_test.zig:89-97`.

**Residual risk (honest):** the *registry mutex* and *connection threads*
introduce host-scheduling nondeterminism in **wall-clock latency and in the order
two different sessions' responses come back** — but never within one session's
instruction stream. If a future feature ever let one session *observe another*
(shared memory, cross-session events), that would couple their streams and break
the property; **§12 records this as a forbidden design direction.** As specified,
sessions are fully isolated IN-PROCESS (RAM/CPU/devices/worker) and the property holds.
(The host filesystem is deliberately NOT isolated — the shared writable mount dir is a
caller-managed external input, not in-process state; Finding 4. Per-machine determinism
still holds given fixed inputs; a caller that lets two sessions mutate one shared dir has
fed a shared-mutating input.)

---

## 9. Resource management

### 9.1 Memory per session (computed from the source)

Per Session, the dominant allocations:

- **`Machine`** via `gpa.create(Machine)` (`main.zig:113`). `@sizeOf(Machine)` is
  dominated by the **inline EMS backing slab**: `Ems.backing` is
  `[BACKING_PAGES * PAGE_SIZE]u8` = `956 * 16 KiB ≈ 15 MiB`
  (`ems.zig:18, 63, 156-157`; backing == reported pages, `ems.zig:50-57`). EMS is
  an inline field of `Dos` (`dos.zig:129`), which is inline in `Machine`
  (`machine.zig:220`). So **one `Machine` ≈ 15 MiB** before its separate alloc'd
  buffers.
- **RAM slab** `bus.ram` = `ram_total_size 0x110000` ≈ **1.06 MiB** (1 MiB + 64
  KiB HMA, `memmap.zig:6, 17`), alloc'd in `Bus.init`.
- **VGA** = VRAM `VRAM_SIZE 0x40000` (256 KiB) + two text windows
  (`vga.zig:60-66, 377-385`) ≈ **~320 KiB**, alloc'd in `vga.init`.
- **`RenderBuffers`** (`server.zig:191-194`, `worker.zig:49-66`): index 307200 +
  rgba 1228800 + palette 768 + `png_out` `PNG_OUT_CAP = 1300*1024` (~1.3 MiB) +
  `png_work` ≈ **~4.1 MiB**.
- **`SharedFrame`** ≈ **308 KiB** (`shared_frame.zig:42-43, 93-94`).
- `RunControl`, `LiveMouseState`, `StreamHub`, `LoadRecipe`: small (< a few KiB
  total).

**Per-session total ≈ 21 MiB** (≈ 15 EMS + ~1.1 RAM + ~0.3 VGA + ~4.1 render +
~0.3 frame). The EMS slab is the elephant.

### 9.2 Cap, thread count, behavior at the cap

- **`MAX_SESSIONS = 8`** (registry constant, §4.2). 8 × ~21 MiB ≈ **~168 MiB** —
  comfortable, and the cap is a one-line knob. (The EMS slab is the reason not to
  set this to dozens without revisiting EMS sizing; see §12.)
- **Threads per session:** 1 worker + 1 pacer = 2 long-lived; plus up to
  `MAX_CONNS = 4` stream threads (`stream.zig:39-40`) when streaming. At 8
  sessions: ~16 long-lived + transient connection threads (bounded by the global
  connection cap, §5.1). Modest.
- **At the session cap:** `registry.create` either (a) evicts the lowest-seq LRU
  session (§4.3) to make room, or (b) — if eviction is disabled — returns an error
  that `initialize` surfaces as a JSON-RPC error (e.g. a new `ErrCode` like
  `session_limit_reached` → HTTP 503 in the `code → status` map that lives in
  `server.zig`, `queue.zig:206-218`). **Recommend:** explicit `DELETE` is primary;
  at the cap, reject new `initialize` with `503 session_limit_reached` rather than
  silently evicting an in-use session (eviction of a session that another client
  is mid-`run` on would be surprising). LRU eviction is the safety net only for
  sessions with the lowest request-seq (effectively abandoned).
- **At the connection cap:** `503 service_unavailable`, close (§5.1).

---

## 10. Phased rollout

Each phase is independently shippable and verified by the existing test suite
staying green.

### Phase 0 — De-risking spikes (DONE in this doc, codify as tests)

The two stdlib facts (§2). Land them as small assertions/comments:

- A test (or doc) confirming `gpa`/`io` thread-safety per build mode.
- A trivial spike: spawn 2 threads, each `gpa.create(Machine)` + `m.init`/`wire`/
  `boot` + a short `runUntil`, asserting no crash and identical results — this is
  really the first isolation test (§11) and proves §2 end-to-end.

**Why safe alone:** pure investigation + a throwaway test; no production change.

### Phase 1 — Extract `Session` (pure refactor, still serial, one default session)

Group today's per-Server singletons (§3.2) into a `Session` struct
(`server.zig:123-243`). `Server` keeps one default `Session`. The accept loop
stays serial; scratch stays where it is for now. `resolveSession` still returns
the default. Thread the `*Session` through `handleMcpToolCall`/`buildMcpLoad`
(already parameterized, `server.zig:1353, 1439`) and through the `/api/*` handlers
(new `*Session` argument, defaulted).

**Verify:** the *entire existing test suite* (`server_test.zig`, `mcp_test.zig`,
`determinism_test.zig`) passes unchanged. This is a mechanical move; byte-identical
behavior.

**Why safe alone:** no concurrency introduced; a refactor proven by green tests.

### Phase 2 — Concurrent connection handling + per-connection scratch

Move the transient scratch (§3.4) into a per-connection `ConnScratch` (§5.2).
Replace the serial accept loop with thread-per-connection + the global connection
cap (§5.1). Still **one** (default) session.

**Verify:** existing tests pass (they drive `serveOne` over in-memory streams,
`server_test.zig:103-106`, bypassing the accept loop — so they exercise the new
per-connection scratch path with the new ownership). Add a concurrency smoke test:
N connection threads hitting the one default session concurrently, asserting no
data race (run under the thread sanitizer / debug allocator) and correct
responses.

**Why safe alone:** still one machine; this proves the connection concurrency in
isolation before sessions multiply.

### Phase 3 — Session registry + MCP `initialize`/`DELETE` + grow the resolver

Add `SessionRegistry` (§4). `initialize` mints sessions; `DELETE /mcp` destroys
them; `resolveSession` returns `?*Session` from the registry with a default
fallback (§7). Deterministic id scheme (§4.4a). Enforce `MAX_SESSIONS`.

**Verify:** `mcp_test.zig` (default-session path) stays green. New tests: create
two sessions, drive them concurrently, isolation + concurrent-determinism (§11).

**Why safe alone:** HTTP and the default MCP path are untouched; multi-session is
purely additive behind `initialize`.

### Phase 4 — HTTP `/api/*` session routing (optional) + limits + polish

If/when desired (§6 option B): optional `X-Zdos-Session` on `/api/*`. Finalize the
caps, the `503` behaviors, the LRU safety net, docs.

**Why safe alone:** the routing seam from Phase 1-3 is already in place; this is a
small, optional extension.

---

## 11. Testing plan

Reuse the existing harnesses:

- The in-process `serveOne` over `Io.Reader.fixed`/`Io.Writer.fixed`
  (`server_test.zig:103-106`) and the `TestServer` (real Machine + Controller +
  CommandQueue + worker, `server_test.zig:48-88`). For multi-session, instantiate
  N `TestServer`-like sessions (or one registry with N sessions).
- The `mcp_test.zig` JSON-RPC patterns for `initialize`/`tools/call` →
  extend with `Mcp-Session-Id` round-trips and `DELETE`.

### 11.1 Concurrent-determinism tests (the core property)

- **Two sessions, same program, in parallel == single-machine golden.** Boot the
  *same* program in session A and session B on their own threads, run both to the
  same cycle N (via `run-to-cycle`), snapshot each
  (`machine.snapshot`, `machine.zig:867-893`), and assert **both snapshots are
  byte-identical to the existing single-machine golden** for that program at N.
  This proves parallelism did not perturb either stream.
- **Interleaved execution == identical.** Drive A and B in interleaved slices
  (A steps, B steps, A steps, ...) from two threads and assert the final per-
  machine state still matches the single-machine golden. Interleaving must not
  matter.

### 11.2 Isolation tests

- Mutate session A's memory (`PUT /api/mem`), registers (`PATCH /api/cpu/reg`),
  and device state, then assert session B is **bit-for-bit unchanged** (read back
  B's mem/cpu/devices). Repeat with the roles swapped.
- Inject a key/mouse into A (`/api/input/*`) and assert B's keyboard/mouse state
  is untouched.

### 11.3 Stress test

- Create `MAX_SESSIONS` sessions, run each a few million cycles concurrently under
  the debug allocator (leak + thread-safety checking), assert all complete and
  each matches its golden. Confirms no shared-state corruption at scale.

### 11.4 Lifecycle tests

- Create → resolve → run → `DELETE` → assert the id no longer resolves and the
  worker/pacer threads joined (no leak).
- Cap behavior: create `MAX_SESSIONS+1`, assert the last `initialize` returns the
  `session_limit_reached` error (or, if LRU enabled, evicts the lowest-seq one and
  the evicted id stops resolving).
- Reuse: create id X, `DELETE` X, create again — fresh machine at power-on state.

### 11.5 Making the concurrent tests themselves deterministic/reliable

Concurrent tests are notoriously flaky. Keep *the asserted outcome* deterministic
even though *scheduling* is not:

- Assert on **final per-machine state**, never on inter-session timing or
  response ordering (which are legitimately nondeterministic, §8).
- Drive each session to an *explicit cycle target* (`run-to-cycle N`) rather than
  a wall-clock duration, so the comparison point is determinate.
- Use a barrier (`std.Thread.WaitGroup` / a join) to ensure both workers finished
  before snapshotting — no sleeps.
- Run under the debug allocator (default in Debug, §2.1) and, where available, the
  thread sanitizer, so data races fail loudly rather than flaking.

---

## 12. Risks, open questions, structural issues (ground rule 3)

- **EMS slab dominates per-session memory (~15 MiB).** `Ems.backing` is an inline
  `[956*16 KiB]u8` (`ems.zig:156-157`) carried in every Machine. At 8 sessions
  that is ~120 MiB of EMS alone. This is the single biggest scaling limit. It is
  *faithful* (BACKING == REPORTED, `ems.zig:50-57`), so we cannot shrink it
  without changing reported EMS — a guest-visible change. **Surfaced, not papered
  over:** if many sessions are ever needed, EMS backing should become a lazily-
  mapped or per-session-arena slab, which is a real design task (out of scope for
  this plan). For now the `MAX_SESSIONS` cap (§9) bounds it.
- **The `std.Io` worst case (honest).** §2.2 verifies one shared `io` is safe for
  N *OS* threads doing blocking I/O *with the current `Threaded` backend*. If a
  future build selected a single-threaded or fiber Io backend, thread-per-
  connection would be wrong and the architecture would have to move to
  `io.async`/`io.concurrent` per request with the machine worker as the only OS
  thread (§2.2 fallback). That changes §5 only; the ownership/registry/determinism
  design is backend-agnostic because the machine core never touches `io`.
- **Cross-session observation is a forbidden direction.** Per-machine determinism
  holds *only* because sessions share no mutable state (§8). Any future feature
  that let one session read/affect another (shared memory regions, cross-session
  breakpoints, a global event bus) would couple their instruction streams and
  break the prime directive. If such a feature is ever requested, STOP and
  escalate — it cannot be done faithfully under the determinism contract.
- **Pinning under concurrent provisioning.** `Machine.wire()` captures self-
  pointers and the machine must not move after wiring (`machine.zig:8-20`).
  `gpa.create(Machine)` gives a stable heap address, so this is fine per session;
  the registry must store `*Machine`/`*Session` (pointers to heap), never values,
  and must not rehash-move the `Session` structs (store `*Session` in the map, as
  §4.2 does). Spot-verified against the existing `main.zig:113-119` pattern.
- **Controller final-address binding.** `Controller` is inline in `Session` and is
  bound to the worker after the `Session` reaches its final address — exactly the
  `TestServer.start()` pattern that binds `srv.ctrl = &self.ctrl` after the struct
  is stored (`server_test.zig:76-81`). The registry must store `*Session` and bind
  each session's controller after the session's heap slot is fixed, or the worker
  will hold a dangling `*Controller`. Flagged because it is an easy mistake.
- **Open question — global connection cap value.** §5.1 proposes a cap mirroring
  the stream cap; the exact number (and whether it is global or per-session) is a
  tuning decision to settle in Phase 2 against expected client count.

---

## 13. Per-session concurrency contract (Phase 2/3 hardening)

Going concurrent (§5: thread-per-connection) deleted an IMPLICIT lock. The old serial
"one connection at a time" accept loop meant only one connection ever touched a session's
mutable state at a time, so some per-session state that is NOT behind the queue was
protected only ACCIDENTALLY. Phase 2 made connections concurrent without replacing that
protection. A `Session.lock: std.Io.Mutex` (clockless `lockUncancelable`/`unlock`, in
`src/api/session.zig`) restores it.

**The contract.** The worker still SOLELY owns the machine; a connection thread builds a
`Command`, submits via the per-session queue (one in flight, `submit_gate`-serialized),
and serializes the `Response`. Pure queue commands (`read_cpu`/`step`/`mem`/`status`/…)
stay **lock-free** — the `submit_gate` already serializes their producers, and adding a
second lock would needlessly serialize the pacer-vs-control run/stop arbitration. The rule
is narrow but **symmetric**: **any access — READ or WRITE — to shared per-session state
that is NOT a single queue command must hold `session.lock` across the whole critical
section.** A lock-free READER tears just as badly against a locked writer as two writers
do — Finding 3 was an unlocked recipe READ racing the locked `load` writer. The covered
off-queue spans:

1. **Capture** (`handleMcpScreenshot`, `submitAndRespondFramebuffer`): submit
   `framebuffer_get` → read/encode `session.render`/`png_out` → **COPY the finished bytes
   into the connection's own scratch**. The worker re-renders into `render` and the
   connection reads/encodes it off-queue (`encodePng` even mutates `render.index` in
   place); two concurrent same-session captures tore the frame / corrupted the PNG. **The
   span ends at the snapshot COPY, NOT the wire write (Finding 2):** the unbounded socket
   write runs UNLOCKED over the per-`Conn` owned copy, because span #5's `produceFrame`
   shares this lock and holding it across a slow capture client's write would block the
   pacer's next slice and FREEZE the guest.
2. **Debugger** (`submitDebuggerAndRespond`, the MCP run/step path): `beginDebugger` →
   submit run/step → `endDebugger`. The owner save/restore is a read-modify-write on
   `run_control`; two concurrent debugger spans interleaving it left the owner stuck at
   `debugger` (`start()` then 409s forever).
3. **Recipe write** (`handleLoad`, `buildMcpLoad`): overlay+persist `session.recipe` →
   submit `load`. Two concurrent loads lost-update the recipe and desynced the persisted
   recipe from the loaded machine.
4. **Recipe read** (`respondMcpInitialize`): copy the DEFAULT session's `recipe` +
   `mount_dir` out to seed a freshly minted session. An unlocked by-value read tears
   against a concurrent `load` writer (#3) → the minted session boots a corrupt recipe
   (Finding 3). The lock is held ONLY across the copy-out; `registry.create` then runs
   OUTSIDE it, because the registry mutex must NOT nest under `session.lock` (it would
   invert the lock order below).
5. **Live-frame read** (`stream.produceFrame`, the host pacer thread): submit
   `framebuffer_get` → copy `render` into the shared frame. Same `render` the capture
   paths read; covered by the SAME lock (the hub holds `&session.lock`). This path
   pre-existed Phase 2 (the pacer always ran concurrently with the accept loop).

**Lock order (global, must never invert):**
`session.lock` → `run_control.arb` → `queue.submit_gate` → `queue.mutex`.
`session.lock` is held ACROSS `queue.submit` in every covered span, so `submit_gate` is
acquired WHILE holding `session.lock`. Nothing ever calls `queue.submit` (i.e. takes
`submit_gate`) and THEN reaches for `session.lock`: pure queue commands and the pacer's own
`run_slice`/`input_mouse_fold` submits take `submit_gate` ALONE. The registry mutex and
`conn_mutex` guard only their own maps and are never nested under `session.lock` (resolve/
release run before/after a handler, not inside a covered span).

**Pacer-vs-control arbitration is unaffected.** The pacer drives `run_control` (`start`/
`stop`/`disarmTerminal` — the `arb` mutex) WITHOUT ever taking `session.lock`, so a control
connection can always take over or stop a paced free-run. The only place the pacer touches
`session.lock` is `produceFrame` (span #4), where it takes `session.lock` THEN `submit_gate`
— the same order as every other span, so no inversion. During a debugger run the pacer is
disarmed, so it does not contend `session.lock`; a `produceFrame` that began just as a
debugger span took the lock simply waits for that bounded run to finish (wall-clock latency
only, never a deadlock, never blocking `run_control`).

**Lifetime fix (the UAF BLOCKER).** `SessionRegistry.create` publishes the new `*Session`
into the map UN-refcounted; a concurrent `DELETE` of the predictable `zdos-sess-<seq>` id
could free it the instant `create` returns. `create` now returns the minted id BY VALUE
(`CreateResult{ session, id }`, snapshotted under the registry mutex before publish), and
`respondMcpInitialize` reads only that id value — it NEVER dereferences the just-published
pointer.

**Determinism.** `session.lock` is a clockless `Io.Mutex` (no timeout, no host clock); it
adds no RNG/float and only changes wall-clock latency, never which guest cycles run. The
`src/api` determinism grep already covers `session.zig`/`stream.zig`. A same-session
concurrency stress test (`src/api/concurrency_stress_test.zig`) hammers ONE session from
many connection threads mixing capture + run/step + load and asserts the invariants (intact
PNGs, no stuck owner, an un-torn recipe, a responsive machine) without asserting any
specific interleaving.
