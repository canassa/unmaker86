# Debugger Milestone 2 — the HTTP/JSON API server over the M1 control core

> **Scope.** Expose the **already-built, synchronous M1 `Controller`** (`src/debug/controller.zig`)
> over HTTP/1.1 + JSON so external tools (and, in M3, an MCP layer) can drive the emulator. This
> milestone adds a `src/api/` module and a `--serve PORT` runner flag. It writes **no new
> emulation logic** — every endpoint is a thin 1:1 wrapper over an existing `Controller` method.
>
> **Prime directive (CLAUDE.md).** Same binary + same inputs ⇒ byte-identical machine state at any
> cycle N, every run. M2 introduces threads (the HTTP listener) for the first time in this project.
> The hard constraint (#4): *the emulation core stays single-threaded; the API server may thread but
> must never feed host scheduling or real I/O timing back into emulation timing or ordering.* The
> entire architecture below exists to make that violation impossible-by-construction, not merely
> avoided by discipline.
>
> **Ground rule (CLAUDE.md).** No mocks/stubs/fakes/hardcoding. If a Zig 0.16 stdlib API does not
> exist as hoped, STOP and surface it in §F rather than inventing one. Where a useful debugger
> operation has **no backing `Controller` method**, this plan either (a) adds the method to the
> controller as an explicit, small task, or (b) marks it out of scope for M2 — it never fakes a
> response.
>
> **Status: v2 (plan).** Folds in a 3-perspective review. v2 changes, by area: **(A) BLOCKING Zig
> 0.16 corrections** — `Request.reader` does not exist → `readerExpectNone(buffer)` /
> `readerExpectContinue` (`http/Server.zig:591/577`), which **invalidate `Head` strings** (capture
> route + content-type first); the listening socket has no `shutdown` (it's on `net.Stream`,
> `Io/net.zig:1252`) → wrap in a `Stream` or `server.deinit(io)`; stream reader/writer return
> **by value** → declare named locals that outlive the `http.Server` (UB otherwise); condvar uses a
> **predicate `while` loop**; `parseFromSlice` allocs a fresh arena per call →
> `parseFromSliceLeaky` over a reset-able arena (`json/static.zig:88`); `listen` wants
> `*const IpAddress` (`Io/net.zig:246`). **(B) Determinism mechanizations** — one-in-flight is now a
> **mechanism** (assert, global submit lock), only `/health` (+ static `memoryRegions`) may answer
> off-worker, `u64` cycle fields emitted as **JSON strings**, adversarial + golden-order tests added.
> **(C) Completeness** — flags PATCH uses the symmetric 13-bool object; the register-set wire shape is
> a single valid std.json tagged union; memory bounds → **400 `address_out_of_range`** (bus is
> host-OOB-safe); `POST /api/load` promoted to a real endpoint; `DELETE /api/breakpoints` (clear-all)
> added; `running` JSON key renamed to `runnable`. **(D)** dispatch returns a typed `code`, not HTTP
> status. Factual fixes: Spice86 is **66 tools**, `read_memory` is **seg:off**, and it returns **400**
> (not 404) for out-of-range memory.
>
> **Status: v1 (plan).** Grounded in the real M1 controller (`src/debug/controller.zig`, read in
> full), the M1 plan (`plans/debugger-milestone-1.md` §3, §6), Spice86's HTTP controllers + the
> 66-tool MCP catalogue (`references/spice86/.../Mcp/EmulatorMcpTools.cs`, verified count), and the
> **actual** Zig 0.16 stdlib at `references/zig/lib/std/` (every API below is cited to a real
> `file:line`).

---

## 0. Investigation summary — the real APIs we build on (cited)

### 0.1 The M1 `Controller` public surface (what M2 wraps, 1:1)

Read from `src/debug/controller.zig`. Every method is **synchronous**, returns a value or a typed
error, never threads/polls/reads host time. These are the *only* operations M2 exposes:

| Group | Controller method | `file:line` |
|---|---|---|
| run | `runUntilEvent(cycle_cap: u64) StopReason` | `controller.zig:167` |
| run | `runToCycle(c: u64) Error!StopReason` | `controller.zig:335` |
| run | `runToAddress(linear: u32) Error!StopReason` | `controller.zig:346` |
| step | `stepInstruction() StopReason` | `controller.zig:305` |
| step | `stepN(n: u64) StopReason` | `controller.zig:318` |
| step | `stepOver() StepOverResult` | `controller.zig:370` |
| bp | `addBreakpoint(kind: BreakpointKind, one_shot: bool) Error!u32` | `controller.zig:246` |
| bp | `removeBreakpoint(id: u32) Error!void` | `controller.zig:270` |
| bp | `enableBreakpoint(id: u32, on: bool) Error!void` | `controller.zig:281` |
| bp | `getBreakpoint(id: u32) Error!Breakpoint` | `controller.zig:284` |
| bp | `forEachBreakpoint(ctx, comptime f) void` | `controller.zig:287` |
| cpu read | `cpuSnapshot() CpuSnapshot` | `controller.zig:509` |
| cpu write | `setReg32(Reg32, u32)` / `setReg16(Reg16, u16)` / `setReg8(Reg8, u8)` | `controller.zig:456/459/462` |
| cpu write | `setSegment(Seg, u16)` / `setEip(u32)` / `setFlags(Flags)` | `controller.zig:465/468/471` |
| mem read | `peekMem(Seg, off, dst)` / `peekMemPhys(phys, dst)` | `controller.zig:561/556` |
| mem write | `writeMem(Seg, off, src)` / `writeMemPhys(phys, src)` | `controller.zig:475/480` |
| ivt/stack | `peekIvtEntry(vector: u8) {ip,cs}` / `peekStack(out: []u16) []u16` | `controller.zig:567/578` |
| session | `status() {...}` / `reset() !void` / `memoryRegions() []const Region` | `controller.zig:594/497/615` |

Shared types (also from `controller.zig`): `StopReason` (`:53`, tagged union), `StepOverResult`
(`:71`), `CpuSnapshot` (`:82`), `Reg16`/`Reg8` (`:125/126`), `Region` (`:129`); from
`src/debug/breakpoints.zig`: `BreakpointKind` (tagged union), `Breakpoint`, `AccessKind`,
`Error = error{BreakpointTableFull, NoSuchBreakpoint}` (`breakpoints.zig`); from `cpu`:
`Reg32`, `Seg`, `Flags`. **`Flags` is `packed struct(u32)`** (`src/cpu/flags.zig:11`) with the 13
named flag bools (`cf,pf,af,zf,sf,tf,iff,df,of,nt,rf,vm,ac`) + reserved bits; it has a public
`fromU32(v) Flags` (`flags.zig:38`, reserved-bit-masked) and `toU32()` (`:46`). **Note:** an earlier
review claimed `Flags.fromU32` does not exist — it does. M2 still prefers the symmetric 13-bool
object on the wire (§B.4/§C) so the read/write shapes match `cpuSnapshot` and the handler builds a
`Flags` field-by-field — no `fromU32` call and no `src/cpu`/`src/debug` change either way.

**Endpoint needs with NO backing controller method — flagged, not faked:**

1. **List breakpoints as a single JSON array.** There is no `listBreakpoints() []Breakpoint`
   (deliberate — `items[]` is sparse, see `controller.zig:287` doc / M1 §3). M2 builds the array
   **via `forEachBreakpoint`** into a response builder. No new controller method needed. ✔ in-scope.
2. **Disassembly.** No disassembler exists (`plans/debugger-milestone-1.md` §7.1). Spice86 exposes
   `read_disassembly`. M2 **defers** it (`GET /disasm` returns 501 Not Implemented, with the raw
   bytes available via `GET /mem`). Out of scope — do NOT ship a fake decoder.
3. **Memory search** (`search_memory` in Spice86). No controller method. **Deferred** to M3 (it is a
   pure read-only scan over `peekMemPhys`; trivial to add later as `Controller.searchMem`). Out of
   scope for M2.
4. **Device-state reads** (VGA/SB/PIT/EMS/DOS-state tools — the bulk of Spice86's 66). The
   controller exposes *generic* memory/CPU/IVT inspection but **no per-device structured readers**.
   These are out of scope for M2 (they belong to a later "device inspection" milestone); flagged in
   §B as the Spice86 tools we defer.
5. **`runUntilEvent` with no cap.** The HTTP `POST /run` must pass an explicit `cycle_cap`. The
   contract requires a bounded budget per command (§A, §6 of M1). No new method — the request
   carries the cap; an absent cap maps to a documented large default, never "infinite".

### 0.2 The M1 forward-compatibility contract (M2 must honor it exactly)

From `plans/debugger-milestone-1.md` §6 — these are **pinned decisions**, not open for redesign:

- The core stays single-threaded. The HTTP listener runs on its **own thread** but **never calls
  the machine**. It **enqueues commands** into a **single-producer/single-consumer ring = a fixed
  `[N]Command` array + power-of-two masked head/tail indices** (`std.RingBuffer` is gone in 0.16 —
  confirmed `plans/debugger-milestone-1.md:150`). The emulation thread (which owns `Controller`)
  drains the queue at deterministic boundaries.
- Determinism holds **iff at most one command is in flight** (request/response). The guest runs only
  in response to an explicit `run`/`step` command, each carrying its own bounded budget; no command
  arrives "mid-run" to be ambiguously drained. A "run to completion then drain whatever arrived"
  design would let host scheduling decide which commands are present at the stop → constraint #4
  violation. **M2 enforces one-in-flight.**
- Breakpoint ids are stable handles; the breakpoint set is snapshot-safe POD — JSON serialization is
  a pure mapping; errors map to HTTP status codes.

### 0.3 Zig 0.16 stdlib — what actually exists (verified against `references/zig/lib/std/`)

> **Several APIs moved in 0.16. Do not write from 0.15 memory.** Findings, each cited:

- **`std.http.Server` EXISTS and is suitable** (`std/http/Server.zig`). Shape:
  - `Server.init(in: *Io.Reader, out: *Io.Writer) Server` (`http/Server.zig:25`). It wraps a
    *byte stream* — it does **not** own a socket; you feed it a connection's reader/writer.
  - `server.receiveHead() ReceiveHeadError!Request` (`:46`) — parses request line + headers.
  - `request.head` is a `Head{ method, target, version, content_length, content_type, ... }`
    (`:70-90`). `request.iterateHeaders()` (`:237`) for extra headers.
  - Request **body — CORRECTED (BLOCKING).** There is **no `request.reader(...)`**. The body reader
    is **`request.readerExpectNone(buffer: []u8) *Reader`** (`http/Server.zig:591`) — or
    `readerExpectContinue(buffer) ExpectContinueError!*Reader` (`:577`) if the client may send
    `Expect: 100-continue`. **Critical lifetime rule:** `readerExpectNone` calls
    `head.invalidateStrings()` (`:591`), so taking the body reader **invalidates all `Head` string
    memory** (`target`, `content_type`, header values). Therefore the handler MUST **capture the
    route (`head.target`) and content-type into owned/copied storage BEFORE taking the body reader.**
    Read the body into a fixed `[MAX_BODY]u8` via `Io.Reader.readSliceShort`/`readSliceAll`; before
    reading, **reject `content_length > MAX_BODY` with 413** (so we never spool an oversized body).
    `content_length` is in `request.head` (`:76`).
  - Response: `request.respond(content: []const u8, options: RespondOptions) ExpectContinueError!void`
    (`:323`); `RespondOptions{ status, extra_headers, keep_alive, ... }` (`:300`). Status is
    `http.Status`; extra headers are `[]const http.Header`. Streaming variant `respondStreaming`
    (`:412`) — not needed (our bodies are small JSON).
  - **Recommendation: USE `std.http.Server`.** It correctly handles HTTP/1.1 head parsing,
    keep-alive, content-length, and HEAD, and is the stdlib gold standard. A hand-rolled parser is
    the fallback only if integration proves it awkward (see §F).
- **Networking moved to `std.Io.net`** (`std/Io/net.zig`) and now requires an **`Io` instance**:
  - `IpAddress.listen(addr: *const IpAddress, io: Io, options: ListenOptions) ListenError!Server`
    (`Io/net.zig:246`) — **takes `*const IpAddress`**. `Ip4Address.loopback(port)` (`:349`) returns a
    **bare `Ip4Address`**, not an `IpAddress`. **CORRECTED bind recipe (BLOCKING):** wrap the v4 in
    the `IpAddress` union, then take its address:
    `const addr: net.IpAddress = .{ .ip4 = .loopback(port) }; const server = try addr.listen(io, .{});`
    (or `IpAddress.parseLiteral`, `:73`). `IpAddress` is a `union(enum){ ip4, ip6 }` (`:57`).
  - `net.Server.accept(s: *Server, io: Io) AcceptError!Stream` (`:1442`). **Clean thread-stop —
    CORRECTED (BLOCKING).** `net.Server.socket` is a `net.Socket` (`:1403`), and `net.Socket` has
    **only `close`/`closeMany`** (`:1080/1084`) — there is **no `socket.shutdown`**. `shutdown` lives
    on `net.Stream` (`Stream.shutdown(s, io, how) ShutdownError!void`, `:1252`;
    `ShutdownHow = enum{recv,send,both}`, `:980`). To unblock a blocking `accept` with
    `error.SocketNotListening` (the documented concurrent-cancellation path, `Server.accept`
    `AcceptError`), either: (a) wrap the server socket in a `Stream` —
    `const s: net.Stream = .{ .socket = server.socket }; try s.shutdown(io, .both);` (use `.recv` to
    just stop accepts) — or (b) call `server.deinit(io)` (`:1406`, closes the socket). Then **join the
    worker thread.** Do NOT write `socket.shutdown` — it does not compile.
  - `Stream.reader(io, buffer) Reader` (`:1393`) / `Stream.writer(io, buffer) Writer` (`:1397`)
    **return their structs BY VALUE.** `http.Server.init` stores the `*Io.Reader`/`*Io.Writer` you
    pass and recovers the parent `Stream.Reader`/`Stream.Writer` via `@fieldParentPtr` from `.interface`.
    **UB risk (BLOCKING):** if you pass `&stream.reader(io,&buf).interface` from a temporary, the
    parent struct is destroyed at the end of the statement → dangling `@fieldParentPtr`. **CORRECTED
    lifetime rule:** declare them as **named locals that outlive the `http.Server`**:
    ```zig
    var rbuf: [HTTP_HEADER_MAX]u8 = undefined;   // doubles as max head length → undersize = 413
    var wbuf: [WRITE_BUF]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);
    ```
    Size `rbuf` ≥ the largest HTTP header block we accept (it is also the head-parse buffer; an
    undersized buffer surfaces as a 413/oversize-head error). `Stream.close(io)` (`:1248`).
  - The `Io` is obtained from a backend: `std.Io.Threaded` (`std/Io.zig:28`), `t.io()`
    (`Io/Threaded.zig:1806`). **`main` already receives one** as `init.io`
    (`src/main.zig:28`) — we thread it into the server.
- **JSON** (`std/json.zig`):
  - Serialize: `std.json.Stringify.value(v, options, writer)` (`json/Stringify.zig:573`) or
    `std.json.Stringify.valueAlloc(gpa, v, options) ![]u8` (`:618`). `Options` (`:539`):
    `whitespace`, `emit_null_optional_fields`, **`emit_nonportable_numbers_as_strings`**
    (`Stringify.zig:567`), etc. **Tagged unions serialize as `{"<tag>": <payload>}`** (the
    `.@"union"` arm, `Stringify.zig:960` jsonStringify path / static.zig `:602`). `void` payloads
    serialize as `{}` (`static.zig:296`). **v2 sets `emit_nonportable_numbers_as_strings = true`** so
    the `u64` cycle fields (`cycles`, `at_cycle`) emit as base-10 JSON strings when > 2^53 (§C.1,
    finding R6) — a lossy JS client cannot then produce a false golden pass.
  - Parse — **CORRECTED (BLOCKING).** `std.json.parseFromSlice(T, allocator, s, options)`
    (`json/static.zig:73`) **allocates a FRESH `ArenaAllocator` on every call** (`static.zig:108-113`
    via `parseFromTokenSource`) — a per-request heap alloc/free, which violates the no-per-op-alloc
    hot-path rule (CLAUDE.md). **Use `parseFromSliceLeaky(T, arena.allocator(), s, options) T`**
    (`json/static.zig:88`) against a **single per-request `std.heap.ArenaAllocator` reset with
    `arena.reset(.retain_capacity)`** between requests — the backing capacity is retained, so steady
    state does zero new allocations. Then **copy the scalars + hex-decoded bytes I need into the
    `Command` POD before the next reset** (no borrowed slice — e.g. the hex `data` — outlives the
    arena; the decoded bytes land in the command's fixed scratch buffer).
    `ParseOptions{ ignore_unknown_fields, duplicate_field_behavior, ... }` (`:19`).
    **Tagged-union parse**: the JSON object must have exactly the tag name as its single key
    (`static.zig:271-308`); `error.UnknownField`/`error.MissingField` on mismatch (`:203-204`).
  - Dynamic value: `std.json.Value`/`parseFromValue` (`json.zig:65/88`) — *not* used; we parse into
    typed request structs for clarity and to avoid unordered-map iteration (constraint #5).
- **Concurrency moved under `std.Io`** in 0.16 (NOT `std.Thread.Mutex`):
  - `std.Thread.spawn(config, fn, args) SpawnError!Thread` (`std/Thread.zig:344`); `.join()`
    (`:370`), `.detach()` (`:364`) — **still exists**, used to start the listener thread.
  - `std.Io.Mutex` (`std/Io.zig:1587`): `Mutex.init`, `lock(m, io) Cancelable!void` (`:1602`),
    `lockUncancelable(m, io)` (`:1623`), `unlock(m, io)` (`:1641`). **Takes an `io`.**
  - `std.Io.Condition` (`std/Io.zig:1653`): `wait(cond, io, mutex) Cancelable!void` (`:1668`),
    `waitUncancelable(cond, io, mutex)` (`:1675`), `signal`/`broadcast`. **Takes an `io`.**
  - **Consequence — flagged (§F):** the new lock/condvar APIs are cancelable and `io`-threaded.
    Because the queue handoff is host-side bookkeeping (NOT emulation), we use the
    **`*Uncancelable` variants** to keep the handoff total/simple. Confirmed the `*Uncancelable`
    variants take **no `Timeout`** (`lockUncancelable(m, io)` `Io.zig:1623`, `unlock(m, io)` `:1641`,
    `waitUncancelable(cond, io, mutex)` `:1675`, `signal(cond, io)` `:1726`) — there is no clock
    anywhere in the handoff. (The timeout-bearing siblings `futexWaitTimeout`/`waitTimeout` take a
    `Timeout` (`Io.zig:1558/1827`); we never call them — see the §D clock-affordance ban.)
  - **Condvar handshake — predicate `while` loop (BLOCKING; lost/spurious wakeup).** `done` is
    written and read **only under the mutex**, no atomics needed. The exact protocol:
    - listener (waiter): `mutex.lockUncancelable(io); while (!ctx.done) ctx.cond.waitUncancelable(io, &mutex); mutex.unlock(io);`
    - worker (signaler): `mutex.lockUncancelable(io); ctx.response = …; ctx.done = true; ctx.cond.signal(io); mutex.unlock(io);`
    The `while (!ctx.done)` predicate (not a bare `if`) is mandatory: it absorbs spurious wakeups and
    closes the lost-wakeup window where the worker signals before the waiter parks.
  - These primitives live in `src/api/`, **never** in `src/debug/` (the determinism grep in
    `determinism_test.zig:36` forbids `std.atomic`/`@atomic` in `src/debug/`, and we add
    `std.Thread`/`std.Io.Mutex` to the *forbidden-in-debug* list too — see §D).

---

## A. Architecture & threading model (determinism-critical)

### A.1 The two threads and the one queue

```
        HTTP listener thread(s)                 emulation thread (owns Controller + Machine)
        ───────────────────────                 ────────────────────────────────────────────
  accept() ─► parse HTTP+JSON ─► build Command ─┐
                                                 │  enqueue (ring tail++)
                                                 ▼
                                         ┌──────────────────────┐
                                         │  CommandQueue (SPSC)  │   fixed [N]Command array +
                                         │  fixed array + masks  │   power-of-two masked head/tail
                                         └──────────────────────┘
                                                 │  dequeue (ring head++)
                                                 ▼
                                         dispatch ─► ONE Controller call ─► fill Response slot
  serialize Response ◄── wake on completion ◄────┘ (signal the request's completion condvar)
        ─► respond() over the socket
```

- **The emulation thread is the sole owner of `*Machine` and `*Controller`.** It is the only thread
  that ever touches emulation state. It is a plain loop: `wait for a command → run exactly one
  Controller method → publish the response → signal the waiter → loop`. It **never** reads host
  time, never `accept()`s, never parses HTTP.
- **The listener thread(s)** do all socket + HTTP + JSON work. They produce `Command` values and
  consume `Response` values. They **never** touch the machine.

### A.2 The command queue (fixed array, no per-op alloc)

`src/api/queue.zig`:

```zig
pub const Command = union(enum) {
    run: struct { cycle_cap: u64 },
    run_to_cycle: struct { cycle: u64 },
    run_to_address: struct { linear: u32 },
    step: void,
    step_n: struct { n: u64 },
    step_over: void,
    add_bp: struct { kind: bp.BreakpointKind, one_shot: bool },
    remove_bp: struct { id: u32 },
    clear_bp: void,                                // DELETE /api/breakpoints (clear-all, G5)
    enable_bp: struct { id: u32, on: bool },
    get_bp: struct { id: u32 },
    list_bp: void,
    cpu_get: void,
    reg_set: RegSetReq, // tagged union {reg32:{name,value}, reg16:.., reg8:.., seg:.., eip:{value}, flags:{13 bools}}
    mem_peek: struct { phys: u32, len: u32 },      // len bounded; uses a fixed response buffer
    mem_write: struct { phys: u32, len: u32 },     // bytes carried in the request's scratch buffer
    ivt_get: struct { vector: u8 },
    stack_get: struct { count: u16 },
    status: void,
    reset: void,
    load: LoadReq,                                 // POST /api/load — server-held bootProgram recipe (G16)
    mem_regions: void,
};
```

- **Single producer, single consumer — by MECHANISM, not discipline (R1, HIGH).** v2 ships
  **exactly one listener thread, processing one connection to completion at a time, with keep-alive
  and pipelining OFF** (each connection = exactly one request; after responding we close, or set
  `keep_alive = false` in `RespondOptions` and drain/ignore any trailing bytes). It is therefore
  *impossible-by-construction* for a second producer to exist in v1 — not merely blocked. To make
  that an enforced invariant rather than a code-reading exercise, the producer `submit()`, after
  acquiring the queue mutex, **`assert`s the queue is empty** (`assert(q.head == q.tail)`) — a second
  in-flight producer would trip the assert in a debug build, surfacing any future regression instead
  of silently smearing ordering.
- With one producer and one consumer, the ring needs only two indices — but the grep audit forbids
  `std.atomic` in `src/debug/` (not `src/api/`); the queue lives in `src/api/`, so it MAY use atomics.
  **However**, because we enforce **one command in flight** (next paragraph), the queue is
  effectively a 1-deep handoff and we protect it with a single `std.Io.Mutex` + `std.Io.Condition`
  rather than lock-free atomics — simpler, total, and the contention is one slot. (The fixed-array
  masked-index ring shape is kept per the M1 §6 pin so it generalizes to multi-client later without a
  rewrite.)
- **The documented multi-client future commits to a GLOBAL SUBMIT LOCK** that serializes the whole
  `submit → run → respond` round-trip per command (one held lock spanning enqueue-to-response), so
  even with N listener threads exactly one command is ever in flight and the per-command effect stays
  deterministic. **Correction to §A.3 wording:** with multiple clients the *order* of commands is
  host-decided (whichever thread wins the lock first), so it is NOT "independent of when each
  arrived" — but for the **realized sequence** the guest trajectory and each command's effect remain
  byte-deterministic. Say exactly that, never "ordering is independent of arrival" in the multi-client
  case.
- **No per-op alloc.** The ring is `[QUEUE_CAP]Command` allocated once at server init. Memory
  payloads (mem_write bytes, mem_peek/stack results) live in **per-slot fixed scratch buffers**
  sized to the bounded max (e.g. `MAX_MEM_CHUNK = 4096`, mirroring Spice86's `read_memory` 1-4096
  cap, `EmulatorMcpTools.cs:220`). A request larger than the cap is rejected with `400` **before**
  enqueue — never a heap alloc on the hot path.

### A.3 One command in flight (the determinism enforcement)

This is the heart of constraint #4. Enforced concretely:

1. A `Request` carries: the `Command`, a fixed `Response` slot, and a per-request
   `std.Io.Condition` + `done: bool` completion flag (all in a stack-or-arena `RequestCtx` owned by
   the listener thread for the lifetime of the call). `done` is read/written only under the mutex.
2. The listener thread takes the queue mutex, **asserts the queue is empty** (the mechanism above),
   enqueues its single command, then waits with the **predicate `while` loop**:
   `while (!ctx.done) ctx.cond.waitUncancelable(io, &mutex);` (never a bare `if`).
3. The emulation thread dequeues the one command, runs the matching `Controller` method, writes the
   result into the `Response` slot, sets `done = true` (under the mutex), and `signal`s that
   request's condition.
4. The listener thread wakes, re-checks the predicate, reads the `Response`, releases the slot, and
   serializes + writes the HTTP response.
5. Because v1 runs **one connection at a time with keep-alive off**, request/response is serial by
   construction: there is **never more than one command in the queue, and never two commands observed
   at a stop boundary.** The guest's trajectory is therefore a pure function of the *sequence* of
   commands. **In the single-client v1 the sequence is fixed by one socket**, so it is independent of
   host scheduling. **In the documented multi-client future** the sequence is host-decided (which
   listener wins the global submit lock first) — the *order* is not arrival-independent, but the
   guest trajectory and each command's effect for the realized sequence remain byte-deterministic.
   That is exactly the property §6 demands.

> **Why this preserves the prime directive (restated explicitly):** the guest advances **only**
> inside a single `Controller.run*`/`step*` call on the emulation thread; that call reads no host
> clock and charges only real/synthetic cycles (M1 §4). The listener thread's timing affects *only
> how long the HTTP response takes to come back*, **never which instructions ran or in what order**.
> Two runs that submit the same command sequence reach byte-identical state at cycle N regardless of
> network jitter. The queue is a pure reordering-free conveyor under the one-in-flight rule.

### A.3a What may be answered OFF the worker thread (R2, MED — torn-read safety)

The worker thread is the **sole reader of live machine state**. The listener thread reads
`u64 cycles` and other live fields **only via the `Response` it gets back from a `submit()`**, never
directly — otherwise it races the worker mid-mutation (a `u64` is two 32-bit stores on a 32-bit
host: a torn read). Concretely:

- **Only `GET /api/health` may be answered off-worker**, and its body must read **ZERO
  machine/controller state** — a compile-time-constant body (`{"ok":true,"version":"zdos-m2"}`). It
  touches neither `ctrl` nor `m`.
- **Every endpoint whose handler touches `ctrl`/`m` MUST go through `submit()`.** This explicitly
  includes `GET /api/status`, which calls `Controller.status()` (`controller.zig:594`) reading the
  live `u64 cycles` (`:604`) — answering it off-worker would be a torn-read race. No exceptions.
- **Optional off-worker exception:** `Controller.memoryRegions()` (`:615`) ignores `self` (it returns
  a static region table — the regions are fixed at power-on). It MAY therefore be answered off-worker
  if desired; v2 still routes it through `submit()` by default for one uniform path, and notes the
  static-data exception as a permitted optimization.
- **Grep-enforced invariant (R2).** A determinism check (§D) asserts that `server.zig` references no
  `ctrl.` / `controller.` / `machine.` / `m.` **outside the `submit()` call path** — so a future
  handler that "just peeks one field" off-worker fails the gate instead of silently introducing a
  torn read.

### A.4 Long runs, caps, and the cancel/interrupt question (genuine design decision)

A `POST /run` may execute a long `runUntilEvent`. During it, the emulation thread is busy and the
socket for *that* request blocks until the stop event. Three sub-questions, with the chosen answer +
the alternatives flagged for the human:

- **Does the socket block until the stop event?** Yes — request/response. The HTTP client gets its
  response when the run stops (terminal / breakpoint / cap). This is simple and deterministic.
- **Is there a cap?** **Yes, always.** `POST /run` REQUIRES a `cycle_cap` (or a documented large
  default, e.g. `1<<32`, never unbounded). A capped run is the unit of determinism: it always
  terminates at a deterministic boundary, so the response is reproducible. An unbounded run that
  "stops when the user sends another request" would make the stop point depend on host arrival time
  → constraint #4 violation. **Rejected.**
- **Can a second request cancel/interrupt a running run — and if so, HOW without nondeterminism?**
  This is the real open decision. **Three options:**
  - **(Option A — recommended for M2) No async cancel.** A run runs to its cap/event; cancellation
    is achieved by choosing a small cap and re-issuing. Strictly deterministic, trivially correct,
    zero new machinery. The cost: a client cannot abort a very long run early. *Recommended* — it
    honors the prime directive with no caveats and matches "one command in flight".
  - **(Option B — deferred) Cooperative cap-lowering.** A `POST /interrupt` sets a shared
    `interrupt_requested` flag the emulation thread polls **at the same instruction boundary it
    already checks breakpoints** (`controller.zig:170` loop). The stop point would then depend on
    *when the flag was observed* relative to the cycle ledger — which depends on host timing →
    **nondeterministic stop point.** To keep determinism, the interrupt would have to resolve to a
    *cycle number* ("stop at the next boundary ≥ cycle K") computed deterministically, which is just
    Option A with a recomputed cap. **So Option B reduces to A** for determinism; offer it only as a
    UX convenience clearly labeled "stop point is host-timing-dependent, not reproducible."
  - **(Option C — deferred) Run in fixed bursts.** `POST /run` internally loops
    `runUntilEvent(burst)` in fixed-size bursts, checking the interrupt flag between bursts. Same
    determinism caveat as B (the *observed* stop is host-timed) unless the abort is logged by cycle.
  - **Decision:** ship **Option A** in M2. Surface B/C as a future "non-reproducible convenience
    abort" only if a user demands it, and only behind an explicit flag in the response that the stop
    was timing-dependent. **Flagged in §F.**

### A.5 Module placement

`src/api/` sits **above `debug` + `machine`** in the module graph (CLAUDE.md graph: "observes
machine; never drives timing"). It imports `debug` (for `Controller` + the shared types) and `cpu`
(for `Reg32`/`Seg`/`Flags` enums needed to decode register-set requests). **Nothing below `api`
imports it.** Files:

```
src/api/
  api.zig          module root + test {} aggregator (mirrors src/debug/debug.zig)
  queue.zig        Command/Response unions + the fixed-array masked-index ring + mutex/condvar handoff
  server.zig       net listen/accept loop, per-connection http.Server, route table, JSON (de)serialize
  json_wire.zig    the wire format: jsonStringify/parse helpers for StopReason/CpuSnapshot/Breakpoint/Region/errors
  worker.zig       the emulation-thread drain loop: dequeue → one Controller call → fill Response → signal
  api_test.zig            in-process queue/determinism tests (no sockets)
  server_test.zig         route/JSON unit tests (parse + serialize round-trips, no sockets)
  determinism_test.zig    grep audit for src/api/ + the one-in-flight serialization test
```

---

## B. The complete endpoint list

**Conventions.** Base path `/api`. Content-Type `application/json` for all request and response
bodies. Addresses/values: **see §C — numbers are JSON integers (decimal); memory byte payloads are
lowercase hex strings** (Spice86 convention, `EmulatorMcpTools.cs:220`). Every endpoint maps to
exactly one `Controller` method (or a `forEachBreakpoint` aggregation). The "Spice86" column cites
the MCP tool(s) it covers.

### B.1 Session / status / health

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `GET /api/health` | Liveness ping; does NOT touch the machine (answered on the listener thread directly). | — | `{"ok":true,"version":"zdos-m2"}` | none | `mcp_about` |
| `GET /api/status` | Run state + last stop. | — | see below | `status()` `:594` | `read_cpu_state` (partial), `pause`/`resume` state |
| `POST /api/reset` | Re-init machine to power-on. **Does NOT reload the program** — follow with `POST /api/load` or the machine is unrunnable (see below + §F). | `{}` | `{"ok":true}` | `reset()` `:497` | (no direct tool) |
| `POST /api/load` | (Re)load a program via the `bootProgram` recipe — the only way to get a runnable machine after `reset()`. | see below | `{"ok":true}` | `bootProgram` (`main.zig:103`, server-held recipe) | (no direct tool) |
| `GET /api/memory-regions` | Peekable region bounds so a client can validate ranges. | — | `{"regions":[{"kind":"ram","phys_start":0,"len":1114112}, ...]}` | `memoryRegions()` `:615` | (informs `read_memory`) |

`GET /api/status` response (from `status()` return, `controller.zig:594`). **`running` is renamed to
`runnable` on the wire** (finding G11): the always-paused model means it is never "executing" — the
controller field `running` (`:595/604`) actually means *not terminated/shutdown/permanently-halted*,
i.e. **runnable**. The wire key reflects the true meaning (the controller field name cannot change,
but the JSON key can; the server maps it). The real "why did it stop" signal is `last_stop`.
```json
{ "runnable": true, "terminated": false, "ret_code": 0, "cycles": "12345",
  "last_stop": { "step_complete": { "at_cycle": "12345" } } }
```
`last_stop` is `null` or a `StopReason` discriminated object (§C). `cycles`/`at_cycle` are emitted as
**JSON strings** (§C.1, finding R6).

**`POST /api/load`** (finding 16). `Controller.reset()` (`controller.zig:497`) deliberately does NOT
reload the program (`controller.zig:488-496` doc: the controller does not own the load recipe), so
without this endpoint `POST /api/reset` yields a machine at power-on with **no program loaded** —
unrunnable. The **server holds the load recipe** captured at `--serve` startup (and updated by each
`POST /api/load`) and re-applies it via the worker, mirroring `main.zig:103`
`m.bootProgram(drive, file_name, cmdtail)`:
```json
{ "drive": 2, "file": "KRONDOR.EXE", "cmdtail": "" }
```
All three fields default to the startup recipe when omitted (so `POST /api/load {}` after a reset
re-loads the originally-launched program). The load runs on the worker thread (it mutates `m`), goes
through `submit()`, and is **not** a controller change (it is the server re-driving `bootProgram`).

### B.2 Execution control

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `POST /api/run` | Advance until terminal/breakpoint/cap. | `{"cycle_cap": 1000000}` (optional; default `1<<32`) | `{"stop": <StopReason>}` | `runUntilEvent()` `:167` | `resume_emulator`, `go` |
| `POST /api/run-to-cycle` | One-shot cycle bp + run. | `{"cycle": 578}` | `{"stop": <StopReason>}` | `runToCycle()` `:335` | (no direct tool) |
| `POST /api/run-to-address` | One-shot exec bp + run. | `{"linear": 1048592}` | `{"stop": <StopReason>}` | `runToAddress()` `:346` | (no direct tool) |
| `POST /api/step` | One retired instruction. | `{}` | `{"stop": <StopReason>}` | `stepInstruction()` `:305` | `step` |
| `POST /api/step-n` | N steps, early-stop on event. | `{"n": 10}` | `{"stop": <StopReason>}` | `stepN()` `:318` | (loop of `step`) |
| `POST /api/step-over` | Step over direct CALL/INT. | `{}` | `{"stop": <StopReason>, "stepped_into": false}` | `stepOver()` `:370` | `step_over` |

**`POST /api/run-to-cycle` / `run-to-address` / `run` errors:** `runToCycle`/`runToAddress` return
`Error!StopReason` — `error.BreakpointTableFull` maps to HTTP 503 (see §B error model). `runToCycle`
with `cycle <= current` returns `cycle_budget_exhausted` (a normal 200 response, documented at
`controller.zig:331-338`).

Example `POST /api/run` → 200:
```json
{ "stop": { "breakpoint": { "id": 0, "at_cycle": 578 } } }
```
Example `POST /api/step-over` → 200 (degraded to step-into, reported honestly):
```json
{ "stop": { "step_complete": { "at_cycle": 590 } }, "stepped_into": true }
```

### B.3 Breakpoints

Kinds map onto `BreakpointKind` (`breakpoints.zig`): `execution_address{linear}`, `cycle{at_cycle}`,
`interrupt{vector}`, `memory{linear,len,access}`. **`io` is declared in the union but `matches`
returns false for it (M1 deferred)** — `POST /api/breakpoints` with `kind:"io"` returns **501 Not
Implemented**, never a fake accept (ground rule).

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `POST /api/breakpoints` | Add a breakpoint of any supported kind. | see below | `{"id": 3}` | `addBreakpoint()` `:246` | `add_breakpoint` |
| `GET /api/breakpoints` | List all used breakpoints (ascending id order). | — | `{"breakpoints":[{"id":0,...}, ...]}` | `forEachBreakpoint()` `:287` | `list_breakpoints` |
| `GET /api/breakpoints/{id}` | One breakpoint. | — | `<Breakpoint>` | `getBreakpoint()` `:284` | (subset of list) |
| `DELETE /api/breakpoints` | Clear ALL breakpoints. | — | `{"removed": 3}` | `forEachBreakpoint()` + `removeBreakpoint()` `:287/270` | `clear_breakpoints` |
| `DELETE /api/breakpoints/{id}` | Remove one. | — | `{"ok":true}` | `removeBreakpoint()` `:270` | `remove_breakpoint` |
| `PATCH /api/breakpoints/{id}` | Enable/disable. | `{"enabled": false}` | `{"ok":true}` | `enableBreakpoint()` `:281` | (no direct tool) |

> **`GET /api/breakpoints` order is deterministic ascending-id (slot-index).** `forEachBreakpoint`
> delegates to `BreakpointSet.forEach` (`breakpoints.zig:108`), which iterates `id = 0 ..
> MAX_BREAKPOINTS` ascending — exactly matching `scanBreakpoints` (`controller.zig:219`). The list
> serializer collects in that order, so the array is reproducible (golden-string tested, §D #12).
>
> **`DELETE /api/breakpoints` (clear-all, finding G5)** mirrors Spice86's `clear_breakpoints`. zdos
> expresses it with **no controller change**: enumerate ids via `forEachBreakpoint` into a small
> fixed buffer, then `removeBreakpoint(id)` each (done on the worker thread, one `submit()`). Returns
> the count removed.

`POST /api/breakpoints` request (the `kind` is the discriminated `BreakpointKind`, §C):
```json
{ "kind": { "execution_address": { "linear": 1048592 } }, "one_shot": false }
{ "kind": { "cycle": { "at_cycle": 578 } }, "one_shot": false }
{ "kind": { "interrupt": { "vector": 33 } }, "one_shot": false }
{ "kind": { "memory": { "linear": 65536, "len": 16, "access": "write" } }, "one_shot": false }
```
`GET /api/breakpoints/{id}` response (a `Breakpoint`):
```json
{ "id": 3, "kind": { "cycle": { "at_cycle": 578 } }, "enabled": true, "one_shot": false }
```
> Note: the in-core `Breakpoint` (`breakpoints.zig`) has `{kind, enabled, one_shot}` but **not** the
> id (the id is the slot index). The wire `Breakpoint` ADDS `id` so a list entry is
> self-identifying; the serializer injects it from the `forEachBreakpoint` callback's `u32 id`.

**Note on Spice86's breakpoint types** (`add_breakpoint`, `EmulatorMcpTools.cs:1876`): it offers
`CPU_EXECUTION_ADDRESS`, `MEMORY_ACCESS/WRITE/READ`, `IO_ACCESS/WRITE/READ`. zdos covers
`CPU_EXECUTION_ADDRESS` (exec) + `MEMORY_*` (memory watchpoints, M1 Phase 5) + adds `cycle` and
`interrupt` (which Spice86 lacks). zdos **defers `IO_*`** (M1 deferred io). Mapping: `MEMORY_ACCESS`
→ `access:"access"`, `MEMORY_WRITE` → `"write"`, `MEMORY_READ` → `"read"`.

### B.4 CPU state

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `GET /api/cpu` | Full register/flag/cycle snapshot. | — | `<CpuSnapshot>` | `cpuSnapshot()` `:509` | `read_cpu_state` |
| `PATCH /api/cpu/reg` | Set one register/segment/eip/flags. | see below | `{"ok":true}` | `setReg32/16/8`/`setSegment`/`setEip`/`setFlags` `:456-471` | (no direct write tool) |

`GET /api/cpu` response = the `CpuSnapshot` struct serialized directly (field order =
`controller.zig:82`): `eax..edi`, `cs..ss`, `cs_base..ss_base`, `eip`, the 13 flag bools, `cycles`,
`halted`, `shutdown`.

`PATCH /api/cpu/reg` request — a **single valid `std.json` tagged union** `{"<tag>": <payload>}`
(finding G2: the v1 flat `{"reg32":"eax","value":N}` shape is NOT a parseable tagged union; v2 uses
the nested form, exactly like `BreakpointKind`). One key, naming which thing to set, whose payload
carries the target + value:
```json
{ "reg32": { "name": "eax", "value": 4660 } }
{ "reg16": { "name": "bx",  "value": 18 } }
{ "reg8":  { "name": "al",  "value": 255 } }
{ "seg":   { "name": "ds",  "value": 4096 } }
{ "eip":   { "value": 256 } }
{ "flags": { "cf": true, "pf": false, "af": false, "zf": true, "sf": false, "df": false,
             "of": false, "iff": true, "tf": false, "nt": false, "rf": false, "vm": false, "ac": false } }
```
- The `reg32`/`reg16`/`reg8`/`seg` `name` values are the enum tag names (`Reg32`/`Reg16`/`Reg8`/`Seg`);
  the server validates via `std.meta.stringToEnum` and returns `400` on an unknown name. `value` is
  range-checked to the register width (`400` if it overflows, e.g. 256 for a `reg8`).
- **`flags` is the SAME 13-bool object `cpuSnapshot` emits** (`cf,pf,af,zf,sf,df,of,iff,tf,nt,rf,vm,ac` —
  field order per `src/cpu/flags.zig:11`), so the read (`GET /api/cpu`) and write shapes are
  **symmetric** (finding G1). The handler assembles a `cpu.Flags` **field-by-field** from the 13 bools
  and calls `Controller.setFlags(f)` (`controller.zig:471`) — **no controller/cpu change**.
  > Note: `Controller.setFlags` takes a `Flags` struct. `Flags` is `packed struct(u32)` with a public
  > `fromU32(v)` (`flags.zig:38`) — so a flat packed-`u32` wire alternative is technically possible
  > **without** any new function (an earlier review wrongly claimed `fromU32` is missing). v2 still
  > picks the bool-object: it is symmetric with `cpuSnapshot`, needs no bit-layout doc, and avoids the
  > reserved-bit footguns `fromU32` masks.

### B.5 Memory

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `GET /api/mem?phys={p}&len={n}` | Side-effect-free peek of n bytes (n ≤ 4096). | — | `{"phys":65536,"len":16,"data":"b80200..."}` | `peekMemPhys()` `:556` | (Spice86 HTTP `HttpApiMemoryController`, phys form) |
| `PUT /api/mem` | Write hex bytes (≤ 4096) at a phys address. | `{"phys":65536,"data":"b80200"}` | `{"phys":65536,"len":3}` | `writeMemPhys()` `:480` | (Spice86 HTTP controller, phys form) |
| `GET /api/mem/seg?seg={s}&off={o}&len={n}` | Peek via a logical `seg:off` view. | — | as `GET /api/mem` | `peekMem()` `:561` | `read_memory` (the MCP tool is **seg:off**, `EmulatorMcpTools.cs:220`) |
| `PUT /api/mem/seg` | Write via `seg:off`. | `{"seg":"ds","off":0,"data":"00"}` | as `PUT /api/mem` | `writeMem()` `:475` | `write_memory` (seg:off) |

> **Reads use the peek path (side-effect-free)** — `peekMemPhys`/`peekMem` (`controller.zig:556/561`)
> route through `bus.peekBlock`, never the device read handlers (M1 §3, the whole reason zdos exists
> to not perturb the machine on inspection). **This must be stated in the OpenAPI/docs.**
> **Writes** go through the real bus write path (a debugger write is a deliberate new *input*, M1
> §3 / `controller.zig:450-453`).

`len`/`data` length are bounded (≤ `MAX_MEM_CHUNK = 4096`); a larger request → `400` (matches
Spice86's 1-4096 cap).

**Address bounds (finding G3 — RESOLVED, not a blocker).** The bus is **host-OOB-safe**: every slab
access is guarded — `peekPhys8`/`read8Kind` (`bus.zig:~277`) and the peek mirror (`bus.zig:~681`)
return `unmapped_fill`/`0xFF` when `m >= ram_total_size`; `write8Kind` (`bus.zig:~300`) drops the
store; `contiguousRamSpan` rejects `start + len > ram_total_size` (`bus.zig:692`). So **there is NO
host OOB** — a bad address can never read or write outside the slab. On top of that backstop the
handler **validates** the half-open `[phys, phys+len)` (or the `seg:off` linear address) against
`ram_total_size` (and/or `memoryRegions()`) **before** the controller call and returns **400
`address_out_of_range`** on overflow. (Spice86's `HttpApiMemoryController` returns **400**, not 404,
for out-of-range, `HttpApiMemoryController.cs:38` — v2 aligns to 400.) **Predicate:** the request must
be *contained in the addressable slab* — note the RAM phys range in `memoryRegions()` overlaps the
VRAM/EMS windows, so "in a region" is not the right test; "`[phys, phys+len) ⊆ [0, ram_total_size)`"
(slab containment) is.

### B.6 IVT / stack

| Method+Path | Purpose | Request | Response | Controller | Spice86 |
|---|---|---|---|---|---|
| `GET /api/ivt/{vector}` | Read a real-mode IVT entry (vector 0-255). | — | `{"vector":33,"ip":4096,"cs":61440}` | `peekIvtEntry()` `:567` | `read_interrupt_vector` |
| `GET /api/stack?count={n}` | Top n 16-bit words from SS:SP upward (n bounded). | — | `{"count":4,"words":[514,0,4096,256]}` | `peekStack()` `:578` | `read_stack` |

`count` ≤ a fixed `MAX_STACK_WORDS` (e.g. 256, the per-slot scratch size); larger → `400`.

### B.7 Spice86 tools we deliberately defer (the completeness audit)

The 66-tool MCP catalogue is the completeness *spec*; M2 covers the **CPU/memory/breakpoint/IVT/
stack/exec-control core** (the generic, controller-backed subset). Deferred to later milestones,
each because **no faithful controller method exists yet** (ground rule — do NOT fake):

- **Disassembly** (`read_disassembly`, `read_cfg_cpu_graph`) — no decoder-to-text (M1 §7.1). `GET
  /api/disasm` ⇒ 501. **M3+.**
- **Memory search** (`search_memory`, `search_ems_memory`, `search_xms_memory`) — no scan method.
  **M3** (a pure read-only `Controller.searchMem` over `peekMemPhys`).
- **I/O ports** (`read_io_port`, `write_io_port`) — io breakpoints + side-effect-free port peek are
  M1-deferred. **Later.**
- **Input injection** (`send_keyboard_key`, `send_mouse_*`) — no controller input API. **Later** (a
  deterministic, cycle-scheduled input-injection milestone; live host input would violate #3).
- **Device-state readers** (`read_video_state*`, `read_sound_blaster_*`, `read_opl_state`,
  `read_pc_speaker_state`, `read_midi_state`, `read_ems_state`, `read_xms_state`, `read_dos_state*`,
  `read_bios_data_area`, all `video_*`, `*_set_*`, `*_write_*`) — no structured per-device readers on
  the controller. **A dedicated device-inspection milestone.** (Generic BDA/EMS bytes are reachable
  *today* via `GET /api/mem` at the right phys addresses, which we document.)
- **Screenshot** (`screenshot`) — framebuffer capture belongs to `src/host/`; defer. (VRAM bytes are
  reachable via `GET /api/mem` at `0xA0000`, per `memoryRegions()` `controller.zig:628`.)
- **`pause_emulator`/`resume_emulator`** — zdos's model is the inverse of Spice86's free-running
  loop: the guest is *always paused* between commands and only advances on an explicit `run`/`step`.
  So "pause" ≡ "the run command returned"; there is no background run to pause. `GET /api/status`
  reports the paused-between-commands state. No separate endpoint needed.

### B.8 Error model

Map each `Controller` `Error` + each transport error to an HTTP status + a typed JSON body. **One
error shape** for all failures:
```json
{ "error": { "code": "breakpoint_table_full", "message": "all 64 breakpoint slots are in use" } }
```

| Condition | HTTP | `code` |
|---|---|---|
| `error.BreakpointTableFull` (`breakpoints.zig`; from `addBreakpoint`/`runTo*`) | **503** Service Unavailable | `breakpoint_table_full` |
| `error.NoSuchBreakpoint` (remove/enable/get a bad id) | **404** Not Found | `no_such_breakpoint` |
| Memory `[phys, phys+len)` not contained in the addressable slab (`[0, ram_total_size)`) | **400** | `address_out_of_range` |
| `len`/`count`/value exceeds the bounded cap, or value overflows reg width | **400** Bad Request | `out_of_range` |
| Malformed JSON (`parseFromSliceLeaky` error), bad hex in `data`, unknown enum name | **400** | `bad_request` |
| Unknown `BreakpointKind`/`access`/missing required field (`error.MissingField`/`UnknownField`) | **400** | `bad_request` |
| `kind:"io"` or `GET /disasm` (declared-but-unimplemented) | **501** Not Implemented | `not_implemented` |
| Unknown route / method-not-allowed on a known path | **404** / **405** | `not_found` / `method_not_allowed` |
| Request body exceeds `MAX_BODY` or header oversize (`http.Reader` `HttpHeadersOversize`) | **413** | `payload_too_large` |
| Content-Type not `application/json` on a body endpoint | **415** | `unsupported_media_type` |

- **Content-type:** request bodies must be `application/json` (or absent for GET/DELETE); responses
  are always `application/json; charset=utf-8`.
- **Malformed JSON:** `parseFromSliceLeaky` returns a `ParseError`; the handler catches it and returns
  `400 bad_request` — never a panic (the controller never sees malformed input).
- **Unknown route:** the route table's fallthrough returns `404 not_found` with the error body.
- **503 vs 404 for BreakpointTableFull:** chosen 503 because it is a transient resource-exhaustion
  (free a slot and retry), distinct from the 404 "this id never existed".
- **Transport-independent dispatch (finding D20).** The worker's `drainOne(ctrl, cmd) Response`
  returns the typed **`code`** (a stable string/enum like `breakpoint_table_full`,
  `no_such_breakpoint`, `address_out_of_range`, …) in its error `Response` variant — **never an HTTP
  status**. The `code → HTTP status` mapping (this table) lives **only in `server.zig`**. The dispatch
  core is therefore transport-independent: the M3 MCP layer reuses the exact same `code`s over a
  non-HTTP transport without touching the worker or controller.

---

## C. JSON wire format

### C.1 Numbers: decimal integers; bytes: lowercase hex strings

- **All addresses, cycle counts, register values, ids, vectors, lengths are JSON integers
  (decimal).** Rationale: `std.json` parses/serializes integers natively and unambiguously; decimal
  avoids the "is `0x10` 16 or a string?" parsing fork. Determinism is unaffected (the value is the
  same either way) and clarity favors one canonical numeric form. **`cycles`/`at_cycle` are `u64` and
  v2 emits them as JSON STRINGS (finding R6, reproducibility-test rationale).** With
  `emit_nonportable_numbers_as_strings = true` (`Stringify.zig:567`), `Stringify` renders any integer
  outside ±2^53 (f64's exact range) as a base-10 string. This matters for the **prime-directive
  regression test**: a lossy JS client that silently rounds a >2^53 cycle count could otherwise
  produce a *false golden pass* (two different machine states comparing "equal" after the client
  truncates). Strings make the cycle ledger exact end-to-end. (Below 2^53 the value emits as a plain
  number; clients should accept either form — or treat the cycle field as a string uniformly.)
- **Raw memory bytes are lowercase-hex strings** (`"b80200"`), exactly Spice86's convention
  (`read_memory`/`write_memory`, `EmulatorMcpTools.cs:220/284`). Rationale: a byte array as a JSON
  number array is 3-4× larger and harder to eyeball; hex is the universal memory-dump idiom. The
  server hex-decodes on write (rejecting odd-length/invalid hex → `400`) and hex-encodes on read.
  This is the **one** place we diverge from "everything decimal", and it is the established norm.

### C.2 Tagged unions: discriminated `{"<tag>": <payload>}` (matches std.json)

Zig 0.16 `std.json` serializes a tagged union as a single-key object keyed by the active tag name,
and parses the same shape (`json/static.zig:271-308` parse; `Stringify.zig:960`-path serialize). We
**rely on the default `std.json` union encoding** rather than hand-rolling — confirmed it produces
exactly `{"tag": payload}`. So:

- **`StopReason`** (`controller.zig:53`) →
  ```json
  { "breakpoint": { "id": 0, "at_cycle": 578 } }
  { "step_complete": { "at_cycle": 12345 } }
  { "cycle_budget_exhausted": { "at_cycle": 1000000 } }
  { "halted_forever": {} }
  { "program_terminated": { "ret_code": 0 } }
  { "shutdown": {} }
  ```
  Void-payload variants (`halted_forever`, `shutdown`) serialize as `{}` (std.json void rule,
  `static.zig:296`). **Serialization is read-only** (StopReason only goes server→client) so we never
  parse it back.
- **`BreakpointKind`** (`breakpoints.zig`) →
  ```json
  { "execution_address": { "linear": 1048592 } }
  { "cycle": { "at_cycle": 578 } }
  { "interrupt": { "vector": 33 } }
  { "memory": { "linear": 65536, "len": 16, "access": "write" } }
  { "io": { "port": 96, "access": "access" } }   // PARSED → rejected 501 (matches=false in core)
  ```
  `BreakpointKind` is **both serialized (in GET) and parsed (in POST)**. The default `std.json` union
  parse handles it; the server post-checks `kind == .io` and returns 501 before enqueuing.
- **`AccessKind`** (`enum(u2){read,write,access}`) → the tag name string `"read"|"write"|"access"`
  (std.json enum → string).

### C.3 The plain structs

- **`CpuSnapshot`** (`controller.zig:82`): serialized field-for-field; integer registers decimal, the
  13 flags as JSON bools, `cycles` as a JSON string (the `u64` rule above). Use
  `Stringify.value(snapshot, .{ .emit_nonportable_numbers_as_strings = true }, w)`. The 13 flag fields
  are exactly the bool object the `PATCH /api/cpu/reg` `flags` payload accepts (symmetric, §B.4).
- **`Breakpoint`** wire form = the core `Breakpoint{kind,enabled,one_shot}` **plus an injected
  `id`** (the slot index from `forEachBreakpoint`). Since the core struct lacks `id`, the serializer
  emits a small `WireBreakpoint{ id, kind, enabled, one_shot }` built in the callback.
- **`Region`** (`controller.zig:129`): `{kind, phys_start, len}` where `kind` is the tag name
  (`"ram"|"vram"|"ems_frame"`).
- **Request structs** (`RunReq{cycle_cap:?u64}`, `AddBpReq{kind,one_shot}`, **`RegSetReq` as a
  tagged union** `{reg32:{name,value}, reg16:{name,value}, reg8:{name,value}, seg:{name,value},
  eip:{value}, flags:{13 bools}}` — a single valid `std.json` union, §B.4/G2), `LoadReq{drive,file,
  cmdtail}`, `MemWriteReq{phys,data:[]const u8}`, etc.) are parsed with
  **`parseFromSliceLeaky(T, arena.allocator(), body, .{ .ignore_unknown_fields = true })`** over a
  per-request `ArenaAllocator` reset `.retain_capacity` (§0.3 correction — NOT `parseFromSlice`, which
  allocs a fresh arena per call). The handler then **immediately copies the scalars + hex-decoded
  bytes into the `Command` POD** before the next arena reset — no borrowed slice (e.g. the hex `data`)
  outlives the arena; the decoded bytes land in the command's fixed scratch buffer.

### C.4 Determinism/clarity tradeoff (the explicit call)

Hex-string memory is the only non-decimal choice; it costs a decode/encode step but matches Spice86
and is the universal idiom — **clarity wins, determinism unaffected** (the bytes are identical). All
other values are decimal for a single canonical numeric form. **No floats anywhere in the wire
format** (constraint #2 — the determinism grep forbids `f32`/`f64` and there are none to emit).

---

## D. Determinism tests

Reuse the M1 idioms: `expectStateEqual` (`machine_test.zig:23`), `CountingAllocator`
(`determinism_test.zig:40-108` lineage), the forbidden-host-dependence grep
(`src/debug/determinism_test.zig`). New tests live in `src/api/*_test.zig`, wired via `test-api`
(§E).

1. **Queue-drive == direct-call equivalence (the core regression).** In-process, **no real
   sockets**: build a `Machine` + `Controller`, then build the M2 `worker` drain loop over a
   `CommandQueue`. Push a fixed command sequence (e.g. `add_bp{cycle 578}`, `run`, `cpu_get`,
   `step`, `mem_peek`) through the queue and drain it on the *same* thread (the worker loop is
   thread-agnostic; the queue handoff is exercised separately). Assert the resulting machine state
   is **byte-identical** (`expectStateEqual` + RAM `expectEqualSlices`) to running the equivalent
   `Controller` calls directly. Proves the queue/worker layer adds zero behavioral change.
2. **HTTP layer adds zero nondeterminism (grep audit — extended, R4).** Extend the forbidden-needle
   grep to `src/api/`: forbid `std.time`, `std.Random`/`std.rand`, `getenv`, `f32`/`f64`, **and every
   clock affordance** — `futexWaitTimeout`, `.fromNow`, `Timeout`, `Clock`, `io.sleep`,
   `nanoTimestamp`, `Instant`, `std.time.Timer` (all confirmed to exist in 0.16: `Timeout`
   `Io.zig:1131`, `futexWaitTimeout` `:1558`, `Clock`/`sleep` `:1169`). **Allow**
   `std.Thread`/`std.Io.Mutex`/`std.Io.Condition`/`std.atomic` and the no-timeout `*Uncancelable`
   variants (they are the legitimate, clockless server threading) — but assert via a **reflection
   test** that no thread/host-timing value ever enters a `Command`/`Response` POD (no pointer fields,
   no host-time fields), mirroring `src/debug/determinism_test.zig:49-70`. Also re-run the **existing
   `src/debug/` grep unchanged** to prove M2 did not leak threading primitives down into the control
   core.
2a. **Off-worker invariant (R2 grep, §A.3a).** Assert `server.zig` references **no** `ctrl.` /
   `controller.` / `machine.` / `m.` outside the `submit()` call path — i.e. the only handler that
   touches machine/controller state off the worker is `GET /api/health`, which references none. A
   future "just peek one field off-worker" regression fails this gate (it would be a torn `u64`
   `cycles` read).
3. **One-in-flight serialization is order-independent.** Spawn the worker thread + a producer that
   submits two command sequences whose *interleaving the contract serializes* (e.g. two clients each
   doing `add_bp; run-to-cycle; cpu_get`). Because the queue enforces one-in-flight and the producer
   submits each command only after the prior completes, assert the **final machine state + each
   command's response is identical across repeated runs** regardless of OS scheduling (run the test
   N times; results byte-identical). This is the constraint-#4 proof at the threading boundary.
4. **Capped run reproducibility.** Two fresh machines, same `POST /run {cycle_cap:K}` command
   sequence ⇒ identical `StopReason` and identical state at the stop. (Pure-program reproducibility,
   constraint #6, through the API path.)
5. **Bounded, retained-capacity hot path (R5 correction).** `CountingAllocator` around a drained
   burst of commands (run/step/peek/write/bp) parsed through the per-request `ArenaAllocator`. The
   assertion is **NOT "zero allocations"** — `parseFromSliceLeaky` may allocate into the arena on the
   first request. Instead: (a) the **ring + per-slot scratch buffers do zero allocations after server
   init** (they are pre-sized); and (b) the **parse arena's growth is bounded** — after a warm-up
   request its backing capacity is retained across `arena.reset(.retain_capacity)`, so steady-state
   re-parses of same-or-smaller bodies allocate nothing new. Assert bounded/retained-capacity growth
   (capacity stops increasing after warm-up), not a literal zero. Mirrors M1 test #7's *intent*
   (no unbounded per-op heap churn).
6. **JSON round-trips (unit, no sockets).** For each request struct: serialize a canonical value →
   `parseFromSliceLeaky` → assert equal. For each response type (`StopReason`, `CpuSnapshot`,
   `WireBreakpoint`, `Region`, the error body): serialize → assert exact expected bytes (golden
   strings), proving the discriminated-union encoding is stable. Include the **`u64`-as-string** form
   for `cycles`/`at_cycle` in the golden (e.g. `"at_cycle":"578"`, finding R6).
7. **Error mapping (unit).** Each `Controller.Error` and each malformed input → the expected typed
   `code` from `drainOne`, AND the `code → HTTP status` mapping in `server.zig` (finding D20). Drive
   the route handler with a synthetic request, assert the status/body.
8. **Adversarial determinism — second command during an in-flight run (R3).** Spawn the worker
   thread, `submit` a **capped, long** `run` (large `cycle_cap`), and while it executes attempt to
   `submit` a second command from another producer. Assert the second producer is **serialized/blocked
   by the mechanism** (the empty-queue `assert` + global submit lock, §A), **not** by socket
   discipline, and that the realized command sequence yields **byte-identical** machine state across N
   repeats under different scheduler outcomes. This is the constraint-#4 proof that "one in flight" is
   structural, not accidental.
9. **Breakpoint list golden order (R7).** With several breakpoints added in scrambled id order,
   `GET /api/breakpoints` serializes them in **ascending id (slot-index)** order — assert the exact
   golden array. Confirms `forEachBreakpoint`→`BreakpointSet.forEach` (`breakpoints.zig:108`) iterates
   ascending, matching `scanBreakpoints` (`controller.zig:219`).

**Integration-tested (real sockets) vs unit-tested:** the queue/worker/JSON/error layers are **all
unit-/in-process-tested** (tests 1, 2a, 5, 6, 7, 8, 9) — no socket needed. The **listener +
`net.Server.accept` + `http.Server` path** is the only piece needing a real socket; cover it with a
**single localhost integration test** (`server_integration_test.zig`, opt-in step, not in the default
`test` aggregate if it proves flaky under CI): bind to `127.0.0.1:0` (ephemeral port), spawn the
server, issue one `GET /api/status` via a client `Stream`, assert the JSON body, then unblock `accept`
by wrapping `server.socket` in a `net.Stream` and calling `Stream.shutdown(io, .recv)`
(`Io/net.zig:1252`) — or `server.deinit(io)` (`:1406`) — which makes `accept` return
`error.SocketNotListening`, then `join`. (There is **no `socket.shutdown`** — §0.3.) **Real socket
I/O cannot be made byte-reproducible** (port numbers, timing) so this test asserts *correctness of one
request*, not determinism — determinism is proved by tests 1-9 below the socket.

---

## E. Module placement & build

- **`src/api/` module.** Add `api_mod = b.addModule("api", ...)` after the `debug_mod` block
  (`build.zig:129-135`), importing `debug` + `cpu` (and `machine`/`bus` only if a test needs to
  build a machine — the production `api` code imports just `debug` + `cpu`). Wire it into the exe:
  `exe.root_module.addImport("api", api_mod)` next to `addImport("debug", ...)` (`build.zig:148`).
- **`test-api` step**, mirroring `test-debug` (`build.zig:395-407`). Define an `api_imports` array
  (`api`, `debug`, `machine`, `cpu`, `bus`, `devices`, `timing` — the machine-building set, like
  `debug_imports` at `build.zig:388-395`), build `MachineTest.add(b, target, optimize,
  "src/api/api.zig", &api_imports)` (the module root's `test {}` aggregator), make a
  `b.step("test-api", ...)`, and **fold it into the aggregate `test`** (`test_step.dependOn(...)`
  near `build.zig:402-420`). The optional real-socket integration test gets its **own**
  `test-api-integration` step that is NOT folded into `test` (kept opt-in, per §D).
- **`--serve PORT` runner flag** in `src/main.zig`. Extend the existing arg parse (the
  `--break-cycle` branch, `main.zig:44-58`) with a `--serve PORT` branch that, after the machine is
  built + program loaded (`main.zig:96-110`), constructs the `api.Server` over the `Controller` and
  the already-available `init.io` (`main.zig:28`) and `init.gpa`, then runs the accept loop until
  shutdown (e.g. SIGINT, or a `POST /api/shutdown`). It **coexists** with `--break-cycle`: the flags
  are mutually exclusive (specifying both → usage error); the default no-flag path (run-to-
  termination, `main.zig:158`) is unchanged. The server path **reuses the same `Controller.init(m)`
  construction** the `--break-cycle` path already uses (`main.zig:114`).
- **`Io` plumbing.** `main` already has `init.io` (`main.zig:28`); pass it to
  `api.Server.init(gpa, io, &controller, port)`. The server uses it for `IpAddress.listen`/`accept`
  and for the `Io.Mutex`/`Io.Condition` handoff. The emulation thread does **not** use `io` for
  anything emulation-related (it only `waitUncancelable`s on the queue condvar — host bookkeeping,
  not emulation timing).

---

## F. Risks / open questions (for the human)

1. **`std.http.Server` vs hand-rolled — RECOMMEND std.http.Server.** Verified it exists and fits
   (`http/Server.zig:25,46,323`); it parses HTTP/1.1 heads, handles keep-alive/content-length/HEAD,
   and pairs cleanly with a `net.Stream` reader/writer (`Io/net.zig:1393/1397`). **Two confirmed
   wrinkles, both handled (§0.3):** (a) `http.Server.init` wants `*Io.Reader`/`*Io.Writer`, which the
   `net.Stream.reader/writer` `.interface` provides — but `reader`/`writer` return **by value**, so
   the `sr`/`sw` locals must outlive the `http.Server` (else `@fieldParentPtr` dangles). (b) The body
   reader is `readerExpectNone`/`readerExpectContinue` (not `request.reader`), and taking it
   **invalidates `Head` strings** — capture route + content-type first. **Fallback** (only if
   integration is awkward): a minimal hand-rolled HTTP/1.1 request-line + header + content-length-body
   parser (~150 lines) over the raw `net.Stream` — the request shape we accept is tiny (method, path,
   optional JSON body). We recommend std first; budget a half-day to fall back if needed.
2. **Run cancellation/interrupt (Option A vs B vs C, §A.4).** Decision needed: M2 ships **Option A
   (no async cancel; cap-and-reissue)** for clean determinism. Approve, or do you want a
   clearly-labeled non-reproducible `POST /api/interrupt` (Option B/C) as a UX convenience? The
   honest constraint: any abort whose stop point depends on host arrival time is non-reproducible —
   it must be labeled as such or expressed as a recomputed cycle cap.
3. **MCP transport — keep in M3.** This plan stops at HTTP/JSON. The MCP layer (Spice86's
   `EmulatorMcpTools`, the 66-tool catalogue) is a thin adapter over these same endpoints and is
   **deferred to M3**. Should M2 stub an empty `src/mcp/` placeholder, or keep the tree clean until
   M3? Recommend: keep clean (no empty stub — ground rule: no fakes).
4. **Multi-client vs single-client.** M2 ships **single listener thread, one connection at a time**
   (simplest correct one-in-flight). The fixed-array masked-index ring (M1 §6) already generalizes
   to multi-producer later. Is single-client acceptable for M2? Multi-client needs the ring's
   producer side to become MPSC (atomics or a producer mutex) — additive, no redesign.
5. **`reset()` re-load responsibility — RESOLVED in v2 (now §B.1).** `Controller.reset()`
   (`controller.zig:497`) re-inits the machine but **deliberately does NOT reload the program** (the
   controller doesn't own the load recipe, `controller.zig:488-496`), so `POST /api/reset` alone
   yields an unrunnable machine. v2 promotes **`POST /api/load`** to a real §B.1 endpoint (+ §G Phase
   5 task): the **server holds the `bootProgram` recipe** (`drive,file,cmdtail`, `main.zig:103`)
   captured at startup and re-applies it via the worker — explicit, no hidden controller state, NOT a
   controller change. (This was review option (a).) No open question remains.
6. **u64 cycles > 2^53 in JSON — RESOLVED in v2 (emit as strings).** `at_cycle`/`cycles` are `u64`;
   JSON's safe-integer range is 2^53. A lossy JS client could otherwise round a large cycle count and
   produce a **false golden pass** (the reproducibility regression test compares cycle ledgers). v2
   therefore sets **`emit_nonportable_numbers_as_strings = true`** (`Stringify.zig:567`) so cycle
   fields > 2^53 emit as base-10 strings (and clients should accept either form, or treat the field as
   a string uniformly). No longer an open question. (Note: the v1 plan cited `Stringify.zig:539` for
   this option; the real line is `:567` — corrected.)
7. **0.16 concurrency API churn (informational, not blocking).** Confirmed: `std.Thread.Mutex` is
   **gone**; locks live at `std.Io.Mutex`/`std.Io.Condition` and take an `io` + are `Cancelable`
   (`Io.zig:1587/1653`). Networking moved to `std.Io.net` and needs an `Io` (`Io/net.zig:246/1442`).
   All endpoints in this plan are written against the **real** 0.16 signatures — no invented API. If
   a future stdlib bump moves these again, the server layer is isolated to `src/api/` and nothing
   below it depends on the choice.

---

## G. Implementation checklist (phased; each phase independently testable; gates stay green)

> Run `zig build test` after every phase. Each `- [ ]` is sized to be one focused commit. Cited
> `file:line` are the exact APIs to wrap. **No `src/debug/` or `src/cpu/...` emulation changes** —
> M2 is purely additive in `src/api/` + a `build.zig`/`main.zig` wiring touch.

### Phase 0 — module skeleton + build wiring (no behavior, gates green)
- [x] Create `src/api/api.zig` (module root + `test {}` aggregator, mirroring `src/debug/debug.zig`).
- [x] Register `api_mod` in `build.zig` after the `debug_mod` block (`build.zig:129-135`); import
      `debug` + `cpu`. Add `exe.root_module.addImport("api", api_mod)` (`build.zig:148`).
- [x] Add the `test-api` step (mirror `test-debug`, `build.zig:395-407`) and fold it into the
      aggregate `test` (`build.zig:402+`). `zig build test` green (empty aggregator).

### Phase 1 — the wire format (`json_wire.zig`), pure, no threads/sockets
- [x] Define request structs (`RunReq`, `RunToCycleReq`, `RunToAddrReq`, `StepNReq`, `AddBpReq`,
      `EnableBpReq`, **`RegSetReq` as a single valid tagged union** `{reg32:{name,value},
      reg16:{name,value}, reg8:{name,value}, seg:{name,value}, eip:{value}, flags:{13 bools}}` (§B.4/G2,
      flags = the same 13-bool object `cpuSnapshot` emits), `LoadReq{drive,file,cmdtail}`, `MemPeekReq`,
      `MemWriteReq`, `IvtReq`, `StackReq`) and wire response structs
      (`WireBreakpoint{id,kind,enabled,one_shot}`, `ErrorBody{code,message}`).
- [x] Serialize helpers via `std.json.Stringify.value`/`valueAlloc` (`Stringify.zig:573/618`) **with
      `.{ .emit_nonportable_numbers_as_strings = true }`** (`Stringify.zig:567`) so `u64`
      `cycles`/`at_cycle` emit as strings (R6). Cover `StopReason`/`CpuSnapshot`/`WireBreakpoint`/
      `Region`/`ErrorBody`. Confirm the discriminated `{"tag":payload}` encoding for
      `StopReason`/`BreakpointKind`/`AccessKind`/`RegSetReq` (§C.2).
- [x] Parse helpers via **`std.json.parseFromSliceLeaky(T, arena.allocator(), body,
      .{.ignore_unknown_fields=true})`** (`static.zig:88`) over a per-request `ArenaAllocator` reset
      `.retain_capacity` (NOT `parseFromSlice`, which allocs a fresh arena per call, `static.zig:108`);
      copy scalars + hex-decoded bytes out into POD before the next arena reset.
- [x] Hex encode/decode for `data` fields (reject odd-length/invalid → error).
- [x] Build a `cpu.Flags` field-by-field from the `flags` 13-bool payload (no `fromU32`, no controller
      change — §B.4/G1).
- [x] Tests: §D #6 (round-trips, golden strings incl. `u64`-as-string) + the hex edge cases.

 the command queue (`queue.zig`), threaded handoff, no sockets
- [ ] `Command`/`Response` unions (§A.2) + the fixed `[QUEUE_CAP]Command` ring with power-of-two
      masked head/tail (M1 §6 pin; `std.RingBuffer` is gone). Per-slot fixed scratch buffers
      (`MAX_MEM_CHUNK=4096`, `MAX_STACK_WORDS=256`).
- [ ] The handoff: `std.Io.Mutex` (`lockUncancelable` `Io.zig:1623`, `unlock` `:1641`) + per-request
      `std.Io.Condition` (`waitUncancelable` `:1675`, `signal` `:1726`) + `done: bool` flag
      read/written **only under the mutex**. Use the **predicate `while (!ctx.done) cond.waitUncancelable(io,&mutex)`**
      loop (lost/spurious-wakeup safe — §0.3/§A.3). `submit(cmd) Response` (blocks until done) +
      `tryDequeue`/`complete` for the worker.
- [ ] Enforce **one-in-flight as a MECHANISM** (R1): `submit()` **`assert`s the queue is empty**
      after taking the mutex (a second producer is impossible in v1, not merely blocked). Document the
      multi-client **global submit lock** (serialize whole submit→run→respond) as the additive future.
- [ ] Tests: §D #3 (order-independent serialization, run N times) + §D #8 (adversarial: second
      command rejected/serialized while a long capped run is in flight — by mechanism, byte-identical
      across N) + a basic submit/drain on two threads returns the right response.

### Phase 3 — the worker drain loop (`worker.zig`), the 1:1 Controller dispatch
- [ ] `drainOne(ctrl: *Controller, cmd: Command) Response`: a `switch` mapping each `Command` to
      exactly one `Controller` method (table in §0.1). Translate `Error` → an error `Response`
      variant carrying the **typed `code`** (a stable string/enum, **never an HTTP status** — the
      `code → status` map lives only in `server.zig`, finding D20, so M3 MCP reuses `code`). Handle
      `list_bp` via `forEachBreakpoint` (`controller.zig:287`) into a bounded response builder
      (ascending id order, §D #9). Handle **`clear_bp` (DELETE-all)** via `forEachBreakpoint` +
      `removeBreakpoint` (G5, no controller change). Handle **`load`** by re-running the server-held
      `bootProgram` recipe (G/§B.1). Validate memory `[phys,phys+len) ⊆ [0,ram_total_size)` →
      `address_out_of_range` (G3). Reject `kind:.io` (501) and `add_bp` with unsupported kinds before
      the controller call.
- [ ] The worker thread entry: loop `tryDequeue → drainOne → complete(signal)`; exits on a shutdown
      sentinel command.
- [ ] Tests: §D #1 (queue-drive == direct-call, byte-identical) + #5 (bounded/retained-capacity, not
      literal-zero) + #7 (typed `code` per `Controller.Error` + the `server.zig` status map) + #9
      (breakpoint list ascending-id golden).

### Phase 4 — HTTP routing + net listener (`server.zig`), real sockets
- [ ] Route table: method+path → handler, parsing path params (`{id}`, `{vector}`) and query
      (`?phys=&len=`). Fallthrough → 404; known-path/bad-method → 405. Include `DELETE
      /api/breakpoints` (clear-all) and `POST /api/load` (G5/G16).
- [ ] Per-connection loop, **one connection at a time, keep-alive OFF** (one request per connection,
      R1): `net.Server.accept(io)` (`Io/net.zig:1442`) → declare **named locals** `var sr =
      stream.reader(io,&rbuf); var sw = stream.writer(io,&wbuf);` (return-by-value; must outlive the
      http.Server — §0.3 UB rule; size `rbuf` ≥ max header block) → `http.Server.init(&sr.interface,
      &sw.interface)` (`http/Server.zig:25`) → `receiveHead` (`:46`) → **capture `head.target` +
      content-type FIRST**, then take the body reader **`request.readerExpectNone(&body_buf)`**
      (`:591`, NOT `request.reader`; it invalidates `Head` strings) and read via
      `Io.Reader.readSliceShort`/`readSliceAll`; **reject `content_length > MAX_BODY` with 413 before
      reading** → route → `request.respond(json, .{.status=..., .keep_alive=false,
      .extra_headers=&content_type_json})` (`:323`). Each handler builds a `Command`, `submit`s it,
      serializes the `Response`. Content-type guard → 415; malformed JSON → 400 (§B.8).
- [ ] `IpAddress` bind (CORRECTED): `const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
      const server = try addr.listen(io, .{});` (`listen` takes `*const IpAddress` `Io/net.zig:246`;
      `Ip4Address.loopback` returns a bare `Ip4Address` `:349`). Bind address configurable (optional
      host arg, e.g. `IpAddress.parseLiteral` `:73`).
- [ ] Clean shutdown (CORRECTED — no `socket.shutdown`): wrap the server socket in a `net.Stream`
      (`const s: net.Stream = .{ .socket = server.socket };`) and `s.shutdown(io, .recv)`
      (`Io/net.zig:1252`), or `server.deinit(io)` (`:1406`) — `accept` then returns
      `error.SocketNotListening` → join the worker thread.
- [ ] `GET /api/health` answered on the listener thread WITHOUT enqueuing and reading **zero**
      machine state (compile-time-constant body — §A.3a/B.1). All other handlers go through `submit()`.
- [ ] Test: §D #4 (capped-run reproducibility through the handler path, in-process) + the single
      opt-in real-socket integration test (its own `test-api-integration` step, not in `test`).

### Phase 5 — runner integration (`main.zig`) + the determinism audit
- [ ] `--serve PORT` branch in the arg parse (`main.zig:44-58`), mutually exclusive with
      `--break-cycle`; construct `api.Server` over the `Controller` (`main.zig:114` construction) +
      `init.io`/`init.gpa`; run the accept loop; default no-flag path unchanged (`main.zig:158`).
- [ ] `src/api/determinism_test.zig`: the **extended** grep audit for `src/api/` (R4 — forbid host
      time/RNG/env/floats AND every clock affordance: `futexWaitTimeout`, `.fromNow`, `Timeout`,
      `Clock`, `io.sleep`, `nanoTimestamp`, `Instant`, `std.time.Timer`; ALLOW
      `Mutex`/`Condition`/`Thread`/`atomic` and the `*Uncancelable` no-timeout variants) + the
      **off-worker grep (R2)**: `server.zig` references no `ctrl.`/`controller.`/`machine.`/`m.`
      outside the `submit()` path (only `/health` is off-worker, and it touches none) + a reflection
      test that `Command`/`Response` have no pointer/host-time fields + a re-run of the **unchanged**
      `src/debug/` grep to prove no threading leaked down (§D #2/#2a). Fold into `test-api`.
- [ ] `zig build test` green; `zig fmt --check src/api`.
- [ ] Manual smoke (documented, not a CI gate): `zig build run -- --serve 8080 PROGRAM.EXE`, then
      `curl localhost:8080/api/status`, `curl -X POST localhost:8080/api/run -d '{"cycle_cap":578}'`,
      `curl localhost:8080/api/cpu` — confirm two identical command sequences give identical state.
