# Live video-stream API — watch (and play) the running game in a browser

**This document is the single authoritative plan for the live browser stream.** It supersedes the
earlier draft of this file and folds in its two companion investigations:

- `plans/research-low-latency-browser-streaming.md` — validates **WebSocket → `<canvas>`** as the
  consensus low-latency local path, with **raw indexed frames primary on localhost** and PNG only as a
  bandwidth tier for remote.
- `plans/http-static-serving.md` — serves the player page **same-origin** from the existing
  `std.http.Server` via `@embedFile` (no CORS, no second port).

Cross-reference those two for the survey/rationale (transport matrix, WebCodecs/WebRTC deferral, MJPEG
caveats, drop-to-latest patterns, static-serving route mechanics) — this plan does **not** re-derive
them; it states the locked outcome and the concrete build.

> Status: **PLAN v2** (not implemented) — review-folded. Natural successor to the screenshot API
> (ROADMAP #13): the screenshot answers "what did cycle N look like"; the stream answers "show me the
> game *as it runs*," live in a browser, interactively.

---

## v2 — review fold (changelog)

v2 folds in a 4-perspective review; every item was verified against the codebase. What changed:

1. **Submit-gate mutex (correctness fix).** The command queue is **NOT** multi-producer-safe:
   `CommandQueue.submit` (`src/api/queue.zig:322-337`) takes the mutex, `assert(head==tail)`
   (`:326`), enqueues, then `while (!ctx.done) ctx.cond.waitUncancelable(io, &mutex)` (`:333`) —
   **the condvar wait RELEASES the mutex**, so a second concurrent producer can acquire it in the
   window before the worker dequeues and trip the `head==tail` assert. v1 had ≥3 concurrent producers
   (run-pacer, frame producer, per-connection input). §5/§9 now add a dedicated **submit-gate
   `std.Io.Mutex`** held for the ENTIRE submit-and-wait, serializing producers by construction. The
   old "one-command-in-flight invariant is unchanged / no new ordering hazard" wording is removed.
   **Consequence:** input/control latency is now bounded by a `run_slice` wall-time → size slices for
   ~8–16 ms (§5).
2. **Use `std.http.Server`'s built-in WebSocket (no hand-rolling).** `Request.upgradeRequested()`
   (`references/zig/lib/std/http/Server.zig:500`), `Request.respondWebSocket()` (`:531`, does the
   accept-key + 101 and returns a `WebSocket`), `WebSocket.writeMessage(data, .binary)` (`:750`),
   `WebSocket.readSmallMessage()` (`:706`) all exist. §6 rewritten to use them; our 22-byte header is
   just the `data` payload of `writeMessage(..., .binary)`.
3. **`std.Thread.Mutex` does not exist in Zig 0.16 → `std.Io.Mutex`** (`references/zig/lib/std/Io.zig:1587`;
   lock/unlock take an `io` arg → `lockUncancelable(io)`/`unlock(io)`, matching the queue). `SharedFrame`
   mutex + prose fixed (§4.2). `seqno` stays `std.atomic.Value(u64)` with `.acquire`/`.release`, u64
   internally, truncated to u32 only on the wire.
4. **Run-pacer vs the `src/api` determinism grep-gate resolved (flag, don't bypass).**
   `src/api/determinism_test.zig:30-62` `@embedFile`s the api sources and forbids `io.sleep`/`Clock`/
   `Timeout`/`Instant`/`std.time.Timer`/`nanoTimestamp`/`waitTimeout`. The pacer needs a host clock.
   §5 picks **option (b)**: host the pacer in `src/host/` (outside the embedded api set); `/api/run/*`
   only flips an atomic the pacer polls. Gate stays intact and is documented.
5. **Multi-connection server change spelled out (§9.1).** Per-connection threads own their own
   `Reader`/`Writer`/`http.Server`/buffers in the **stream thread's frame**; that thread closes the
   socket. The shared `resp_buf`/`body_buf`/`read_scratch`/`arena` (`src/api/server.zig:113-117`) are
   one-connection-at-a-time → concurrent paths use stack/per-thread scratch only. Control stays serial
   on the accept loop; only stream sockets go to threads.
6. **Run-ownership arbitration (§5.3).** A single `RunOwner = enum { idle, paced, debugger }`:
   `/api/run/start` → 409 if a debugger run is in flight; `step`/`run-to-cycle`/`run-to-address`
   auto-disarm the pacer. Auto-start on first stream connect **only when `idle`** (never hijack a
   paused-at-breakpoint debug session). Added test: `run-to-cycle N` with a stream connected still
   lands exactly at N.
7. **Client fixes (§7):** shader reads the index with **`texelFetch`** (integer coords) not `texture()`;
   `gl.pixelStorei(UNPACK_ALIGNMENT, 1)`; a `KeyboardEvent.code → set-1 {scancode, ext}` table with
   **make on keydown / break on keyup** (the `{char}` path only sends down — `server.zig:508-514`
   hardcodes make/press); mid-stream `(width,height)`/mode-change handling; absolute mouse mapping via
   `getBoundingClientRect` + `devicePixelRatio`.
8. **MED/LOW:** connection cap N=4 (503 beyond); single-broadcaster trade-off noted; shutdown ordering;
   terminate-mid-stream disarms the pacer; SharedFrame body read **only under the mutex**; paced≡unpaced
   compares at the actual final cycle; 64-bit WS length always; heartbeat-resend test; render+hash budget.

---

## 0. Overview

A developer points a browser at a zdos URL, sees a NEW homepage with a `<canvas>`, and **watches Betrayal
at Krondor play live** — and can press keys / move the mouse to play it. The picture moves because a new
**paced free-run loop** keeps the machine advancing throttled toward wall-clock. Each rendered frame is
broadcast as a **raw indexed VGA frame** (1 byte/pixel + a 256-color palette) over a **WebSocket**; a
**WebGL2** player expands index→RGB on the GPU and blits it scaled to the canvas. Everything streaming is
**host-side observation** — it reads immutable snapshots through the existing single command queue and
never perturbs the emulator's cycle ledger.

This is a *headless emulator* gaining a live face without compromising its prime directive: the emulation
core stays single-threaded and byte-for-byte deterministic; the stream is pure read.

---

## 1. Locked decisions (design to these exactly — not re-litigated here)

1. **Wire format = RAW INDEXED frames.** Each frame = the 8-bit index buffer (1 byte/pixel, straight from
   `vga_render.render`'s index output — `vga_render.zig:502`) + the 256-entry palette (RGB, 6→8 expanded
   with the pinned `(c<<2)|(c>>4)` — `expand6to8`, `vga_render.zig:115`). **The palette is sent only when
   it changes** (a "has-palette" flag in the frame header). No PNG/codec on this path. (PNG remains a
   *deferred remote/bandwidth tier* — one line in §10 — but v1 is raw indexed.)
2. **Fast-hash dedup with `std.hash.Wyhash`** (`references/zig/lib/std/hash/wyhash.zig:3`; non-crypto,
   multi-GB/s — explicitly NOT the SHA-256 used for goldens). The hash covers **index bytes + palette
   together** so palette-only fades are not missed. Each connection holds a **`last_hash`**; unchanged
   frames are skipped. A **full frame is sent on connect** (a fresh client can't wait for a change), plus
   an optional low-rate heartbeat resend.
3. **Client = a NEW homepage + WebGL2 player.** The index buffer is uploaded as an integer texture
   (R8UI / `usampler2D`); the palette as a 256×1 RGB texture; a fragment shader does
   `color = palette[index]`, drawn to a `<canvas>` with nearest filtering for crisp pixels and free
   scaling. The GPU does the palette expansion — this is *why* indexed-on-the-wire works (4× less
   bandwidth than RGBA, zero per-pixel JS). Served same-origin by zdos (no CORS). WebGPU is an optional
   future swap.
4. **Transport = WebSocket** (binary frames), using **`std.http.Server`'s built-in WebSocket** — do
   NOT hand-roll the handshake or framing. `Request.upgradeRequested()`
   (`references/zig/lib/std/http/Server.zig:500`) detects the upgrade;
   `Request.respondWebSocket(.{ .key = ... })` (`:531`) computes
   `Sec-WebSocket-Accept = base64(SHA1(key ++ GUID))`, writes the `101`, and returns a `WebSocket`.
   Frames out: `WebSocket.writeMessage(payload, .binary)` (`:750`, correct 7/16/64-bit length, server→
   client unmasked). Input in: `WebSocket.readSmallMessage()` (`:706`, unmasks client→server, enforces
   the mask bit, skips pongs). Our 22-byte header (§6.3) is just the `payload` of `writeMessage`.
   **Drop-to-latest** on both ends; never accumulate latency.
5. **No impact on the emulator core; a thread per connection.** Emulation stays single-threaded behind
   the existing command queue (`server.zig:699` `queue.submit`; `worker.zig:408` the sole `*Machine`
   owner), now fronted by a **submit-gate mutex** so the multiple host producers serialize (§5/§9 —
   v1's "one in flight" assert is NOT multi-producer-safe by itself). Each WebSocket connection gets
   **its own thread** for socket I/O + per-connection dedup + send, owning its own `WebSocket`/buffers
   in that thread's frame (§9.1). Frame *production* (render/peek) still goes through the worker/queue.
   A **shared latest-frame buffer** (server-owned index+palette + a seqno, written by the producer, read
   by each connection thread **under the mutex**) lets one render feed all clients. Stream threads ONLY
   read snapshots — zero cycle-ledger impact, no feedback into emulation ordering (CLAUDE constraint #4).
   **Connection cap = 4** (further WS upgrades → 503; §9.1/§10).

---

## 2. What already exists (the stream is mostly wiring)

- **Pure, cycle-neutral framebuffer peek:** `Controller.framebuffer(index_buf, rgba_buf, palette_buf)`
  (`src/debug/controller.zig:759`) — "advances NO cycles and mutates NO device field" (`:743`). Returns a
  `FramebufferView` (`:716`: kind/width/height/index_len/rgba_len/double_scan/row_repeat/supported/
  palette_present/pel_mask). It fills the palette slab with the 6→8 expanded RGB triples — exactly our
  wire palette. This is the snapshot the producer samples.
- **The rasterizer:** `vga_render.render` → 8-bit index image (`vga_render.zig:502`); the pinned DAC
  expansion `expand6to8` (`:115`). Our wire format is the *input* to RGBA expansion, so it needs no new
  rendering code.
- **Server-owned render buffers, never through JSON:** `RenderBuffers { index, rgba, palette, png_out,
  png_work }` (`worker.zig:46`), allocated once at `Server.init` (`server.zig:122`). `framebuffer_get`
  fills them on the worker (`worker.zig:331` `framebufferResp`); `submitAndRespondFramebuffer`
  (`server.zig:721`) streams them as a raw binary body with `X-Frame-*` headers — the discipline the
  stream mirrors. Unsupported mode → 501, never a fake frame (`server.zig:729`).
- **The one-command-in-flight queue:** every handler builds a `Command` and `queue.submit`s it
  (`server.zig:693`); the single worker runs exactly one method and publishes a typed `Response`. `submit`
  asserts the ring empty → one command in flight by construction.
- **`/api/health` off-worker pattern** (`server.zig:280`): a route answered on the listener thread with
  ZERO machine access. Static serving and the WS handshake follow this — no command submitted.
- **Input injection (the interactivity half):** `POST /api/input/key` (`server.zig:418`, `handleInputKey`
  `:483`) → scancode/char → 8042 → IRQ1 → INT 09h; `POST /api/input/mouse` (`server.zig:422`,
  `handleInputMouse` `:519`) → INT 33h state. Both are normal worker commands landing at command
  boundaries (Model A, `plans/input-injection.md`). No new input surface is required.
- **Run control, but only *bounded* today:** `/api/run`, `/api/run-to-cycle`, `/api/step`, etc.
  (`server.zig:334`–`357`) via `Controller.runUntilEvent`. **There is no continuous free-run loop** — the
  genuinely new emulation-adjacent piece (§5).
- **std confirmed present (Zig 0.16):** `std.hash.Wyhash`, `std.http.Server.WebSocket` (handshake +
  framing built in — `references/zig/lib/std/http/Server.zig:500/531/706/750`), `std.Thread`,
  `std.Io.Mutex` (`references/zig/lib/std/Io.zig:1587`), `std.compress.flate`. (`std.Thread.Mutex` does
  **NOT** exist in 0.16 — use `std.Io.Mutex` with `lockUncancelable(io)`/`unlock(io)`, matching the
  queue. The api determinism gate, `src/api/determinism_test.zig:70`, asserts `Io.Mutex` is in use.)

---

## 3. Architecture

Two host concerns are added, both *above* the emulation core in the module graph, both reaching the
machine **only** through the existing queue:

- **A paced free-run driver** (§5): keeps the machine advancing in fixed cycle slices while "running."
- **A frame producer + per-connection stream threads** (§4): one render fills a shared latest-frame
  buffer; each connection thread dedups and sends to its socket.

```
 ┌─────────── host side (threads; observation only) ───────────┐   ┌─ emulation core (single thread) ─┐
 │                                                              │   │                                   │
 │  run-pacer thread ── submit(run_slice) ──┐                   │   │   ┌──────── worker ────────┐      │
 │   (sleep between slices, wall clock)      │                  │   │   │ sole *Machine owner     │      │
 │                                            ▼                 │   │   │ run slice → run slice…  │      │
 │                                   ┌────────────────┐  submit │   │   │ framebuffer_get (peek)  │      │
 │  frame producer ── submit(framebuffer_get) ──────► │ command │───┼──►│ fills RenderBuffers     │      │
 │   (after slice / fps tick)  copy ▼                 │  queue  │   │   └────────────────────────┘      │
 │                         ┌───────────────────────┐  │(1 in    │   │   (charges cycles only in run;    │
 │                         │ SHARED latest-frame    │  │ flight) │   │    peek charges none)             │
 │                         │  index+palette + seqno │  └────────┘   └───────────────────────────────────┘
 │                         └───────────┬───────────┘                │
 │            (atomic seqno / mutex)   │  read snapshot             │
 │   ┌──────────────┬──────────────────┴───────────────┐           │
 │   ▼              ▼                                   ▼           │
 │ stream-thread  stream-thread  …                  stream-thread   │
 │  (conn A)       (conn B)                           (conn N)      │
 │  Wyhash dedup   Wyhash dedup                       Wyhash dedup  │
 │  WS send ▲      WS send ▲                          WS send ▲     │
 └──────────┼──────────────┼──────────────────────────────┼───────┘
            │ frames        │                              │
            ▼ input         ▼                              ▼
        browser A        browser B                     browser N
    (WebGL2 canvas;   keydown/mouse → /api/input/key|mouse (or framed over the same WS))
```

The accept loop keeps taking short-lived **control** connections serially as today; a WS upgrade is
handed to a dedicated stream thread (§9.1), which owns its `WebSocket`/buffers. All machine access —
pacer slices, frame peeks, injected input — funnels through the single queue **behind the submit-gate
mutex** (§5), so the multiple host producers serialize deterministically (CLAUDE #4: deterministic
interleaving). The diagram's "input → /api/input/..." path is also valid framed-over-WS (§6.5).

---

## 4. Frame production + the shared latest-frame buffer

### 4.1 Producing one frame for all clients
The producer renders **once** and publishes to a server-owned shared buffer that every connection thread
reads. This avoids N renders for N clients and keeps the worker's load independent of viewer count.

- **When:** the producer captures on a wall-clock **fps tick** (v1 default **30 fps**), independent of
  emulated vsync — it samples *whatever frame is current*, never stalling emulation to wait for an
  emulated vsync edge (CLAUDE #4: the observer never gates the core). The simplest wiring makes the
  **run-pacer also the producer**: after a slice completes, if the fps interval has elapsed, capture.
  (Alternatively a standalone sampler thread on its own 1/30 s tick — chosen during implementation; both
  only `submit(framebuffer_get)`.)
- **How:** `submit(framebuffer_get)` runs the existing peek into the worker-owned `RenderBuffers`
  (`worker.zig:331`). On return, the producer **copies** the `index[0..index_len]` and the 768-byte
  `palette` out of `RenderBuffers` into the **shared latest-frame buffer** (the copy is cheap — ≤308 KiB —
  and necessary because the next command may overwrite `RenderBuffers`; this also keeps a single render
  buffer per the recommendation below).
- **Unsupported video mode:** the producer publishes a "no-frame / unsupported" marker (kind, supported
  =false) rather than fabricating pixels; connection threads forward it as a control frame (§6.4), never
  invented data (same honesty as the 501 on `/api/framebuffer`).

### 4.2 The shared latest-frame buffer (synchronization)
A server-owned struct, allocated once (heap, like `Server.render`, `server.zig:122`):

```
SharedFrame {
    seqno:    std.atomic.Value(u64),  // bumped on each new publish (the version); u64 internally,
                                      // truncated to u32 only on the wire (§6.3)
    mutex:    std.Io.Mutex = .init,   // guards the body during copy-in / copy-out (NOT std.Thread.Mutex)
    width, height: u16,
    kind:     vga_render.Kind,
    supported: bool,
    pel_mask: u8,
    palette_seq: u64,              // bumped only when the palette bytes change
    index:    [RENDER_INDEX_CAP]u8 = undefined,   // 307200 (640x480)
    palette:  [768]u8 = undefined,
    frame_hash: u64,               // Wyhash(index ++ palette), computed once by producer
}
```

Synchronization contract (must never stall or perturb the worker):

- **Producer write:** the producer already holds the snapshot in `RenderBuffers` *before* touching
  `SharedFrame`. It computes `Wyhash` over index+palette, then `mutex.lockUncancelable(io)`, `@memcpy`s
  index/palette + scalars, bumps `palette_seq` iff the palette bytes differ from the previous publish,
  `mutex.unlock(io)`, and finally `seqno.store(.., .release)`. The producer never blocks on a stream
  thread — the mutex is held only for the memcpy (sub-ms), and stream threads only read it; a slow socket
  can never back-pressure into the producer or the worker.
- **Stream read:** a connection thread `seqno.load(.acquire)`; if it equals its last-seen seqno it
  sleeps to the next tick (nothing new). Otherwise it takes `mutex`, copies the body
  (index + palette + scalars) into a thread-local buffer, releases, then does all dedup + send work
  outside the lock. (Per-thread buffers mean a slow client copies and drops on its own time without
  holding the lock.) **The seqno fast path is a "is there new data" signal ONLY — not a license for a
  lockless body read.** The body (index + palette + scalars) is *only ever* read under the `mutex`; the
  atomic seqno gates whether to bother taking the mutex, but never substitutes for it. (Reading the body
  on a bare seqno compare would be a broken seqleq — the producer's memcpy could be mid-flight. Don't.)
- **Why this honors CLAUDE #4:** the only cross-thread state is an immutable-once-published snapshot +
  a seqno. Producer→consumer is one-way (no consumer ever writes machine-visible state); the worker is
  reached only via `submit`. Nothing the stream threads do feeds back into *which* cycles run or *in what
  order* — they observe.

### 4.3 Per-connection dedup + drop-to-latest
- Each connection thread keeps `last_hash`. After copying a new shared frame, compare its `frame_hash`
  (computed once by the producer) to `last_hash`; if equal, **skip the send** (an unchanged frame — incl.
  palette-only fades, since the hash covers both). On first frame after connect, `last_hash` is unset →
  always send (a fresh client can't wait for a change).
- **Drop-to-latest:** if the producer advanced the seqno several times while this thread was sending, the
  thread simply reads the *current* `SharedFrame` next tick — intermediate frames are dropped, never
  queued. The thread never builds a backlog; a slow client drops frames and never stalls others or the
  emulator (per-connection backpressure, §9).
- **Heartbeat:** an optional low-rate (e.g. 1 Hz) resend of the current frame even when unchanged, so a
  client that connected during a static screen and a transient packet hiccup both self-heal. (Optional;
  the connect-time full frame already covers the join case.)

### 4.4 Buffers / ownership recap (no per-op alloc)
- Producer: reuses the existing `RenderBuffers` (`worker.zig:46`) for the peek; copies into `SharedFrame`.
  **No new render buffer** — the recommended single-render-buffer design.
- `SharedFrame`: one server-owned allocation.
- Per stream thread: a thread-local frame copy (index+palette) + the WS framing scratch, allocated once
  when the thread starts. Pixels never flow through `resp_buf`/JSON (B1 preserved).

---

## 5. The paced free-run mode (the one new emulation-adjacent piece)

The machine must run continuously, throttled toward wall-clock, so frames change over time.

- **New worker command `run_slice`** = `Controller.runUntilEvent(slice_cycles)` (mirrors `.run`,
  `worker.zig:95`) — bounded, deterministic, identical to a manual `POST /api/run {cycle_cap: slice}`.
  Returns the `StopReason`, so a terminal/breakpoint stops free-run and is surfaced to clients.
- **A host "run-pacer" thread** (NOT the worker): a loop of `submit(run_slice) → host-sleep(target_tick −
  elapsed)`. **The sleep is the ONLY wall-clock use, and only *between* slices** — it never alters slice
  size or results. If the host is slow, slices fall behind real time (the stream just runs slower); we
  **never "catch up"** by changing cycle counts (no smear — the anti-Spice86 invariant).
- **Submit-gate (the queue is NOT multi-producer-safe — load-bearing).** `CommandQueue.submit`
  (`src/api/queue.zig:322-337`) takes the mutex, `assert(head==tail)` (`:326`), enqueues, then
  `while (!ctx.done) ctx.cond.waitUncancelable(io, &mutex)` (`:333`). **The condvar wait RELEASES the
  mutex**, so during the wait a second producer can acquire it and trip the `head==tail` assert. With
  ≥3 host producers (this pacer, the frame producer, per-connection input submits) that race is real.
  **Fix:** add a dedicated **submit-gate `std.Io.Mutex`** that every host producer takes (
  `lockUncancelable(io)`) for the **ENTIRE submit-and-wait** and releases after the response returns →
  producers strictly serialize, so the one-in-flight invariant + the `head==tail` assert hold *by
  construction*. (This wraps `queue.submit`; the queue's own mutex/assert are unchanged.)
- **Consequence — input/control latency.** A producer now waits for the in-flight `run_slice` to finish
  before its own command runs, so **input/control latency is bounded by one slice's wall-time.** Size
  `slice_cycles` for acceptable lag: target a slice wall-time of **~8–16 ms** (NOT the full 1/30 s frame
  interval). The producer then captures every Nth slice to hit the 30 fps sample cadence.
- **Slice sizing:** pick `slice_cycles` so one slice ≈ **8–16 ms** of wall-clock at the configured
  emulated CPU rate (deterministic integer cycles-per-slice). BaK's emulated vsync is ~70 Hz; v1 caps the
  *frame-sample* cadence at **30 fps** (capture every Nth slice), decoupled from the slice size so input
  latency stays low.

### 5.1 Determinism contract (the load-bearing invariant)
> **A paced run to cycle N is byte-identical to an unpaced `run-to-cycle N`.** The pacer is just a loop of
> bounded `runUntilEvent(slice)` calls on the single worker with host sleeps inserted only between slices;
> the slices, breakpoints, and results are identical to issuing those same bounded runs by hand. The wall
> clock decides only *how fast wall time advances*, never *how many guest cycles elapse* — emulated time
> stays `f(cycles)`. PIT/retrace/INT 1Ah keep deriving time from `cpu.st.cycles`, untouched.

Because the pacer, the frame producer, and any input POST all go through the **same single-command
queue, behind the submit-gate mutex**, they serialize deterministically — a key press submitted between
two slices lands at that slice boundary exactly as Model A guarantees. The submit-gate is what *makes*
this true with multiple producers: without it, two producers can interleave inside `queue.submit`'s
condvar wait and trip the `head==tail` assert (`queue.zig:326`). With it, the existing one-in-flight
mechanism holds by construction (CLAUDE #4).

### 5.1a Where the pacer lives (the grep-gate resolution — flag, don't bypass)
`src/api/determinism_test.zig:30-62` `@embedFile`s every `src/api` source (`api.zig`, `queue.zig`,
`json_wire.zig`, `worker.zig`, `server.zig` — `:22-28`) and FAILS the build if any contains
`io.sleep`/`Clock`/`Timeout`/`Instant`/`std.time.Timer`/`nanoTimestamp`/`waitTimeout` (`:45-52`). The
pacer needs a host clock (inter-slice sleep + the fps tick). **Silently leaving a new file out of the
embed set would be the papering-over failure mode** — so v2 resolves this explicitly:

> **Option (b) — host the pacer in `src/host/`** (e.g. `src/host/run_pacer.zig`), OUTSIDE the embedded
> api set. `/api/run/start|stop` (handled in `server.zig`, clockless) only flips an **atomic flag** the
> pacer polls; the pacer's loop (sleep + `queue.submit(run_slice)` via the submit-gate) lives in
> `src/host/`. The `src/api` grep-gate stays unchanged and intact — no new allow-list, no clock in any
> embedded file. (Option (a) — adding the pacer to the embed list with a narrowly-scoped, tested
> allow-list for the single inter-slice sleep — was considered and rejected: keeping the clock entirely
> out of `src/api` is cleaner and needs no gate edit.) **Note:** `src/host/` consumes machine output
> and may thread (CLAUDE: `src/host` "consumes machine output"); it reaches the worker only via the
> submit-gated queue, so it never feeds back into emulation ordering (CLAUDE #4).

### 5.2 Run-control endpoints
- `POST /api/run/start {slice_cycles?, fps?}` → arms the run-pacer atomic (idempotent; **409 if a
  debugger run is in flight**, §5.3). Body optional → defaults. Clockless: it only sets the flag.
- `POST /api/run/stop` → clears the flag; the pacer stops at the next slice boundary; returns the stop
  cycle. A stopped machine is still fully inspectable/steppable/streamable (you see the current frame).
- `GET /api/run/status` → `{owner, running, cycle, fps, slice_cycles, last_stop_reason}`.
- Existing `/api/run-to-cycle`, `/api/step`, breakpoints all still work; a breakpoint/terminal during
  free-run auto-stops the pacer, and the reason flows to `/api/run/status` and a WS control frame (§6.4).

### 5.3 Run-ownership arbitration (pacer vs debugger)
A single mutually-exclusive run owner — `RunOwner = enum { idle, paced, debugger }`:
- `POST /api/run/start` → **409** if `owner == debugger` (a `run-to-cycle`/`run-to-address`/`step` is in
  flight); otherwise sets `owner = paced`.
- `step` / `run-to-cycle` / `run-to-address` while `owner == paced` → **auto-disarm the pacer** (clear
  the flag, let the in-flight slice finish, set `owner = debugger`), run the requested bounded run, then
  return `owner = idle`. (Auto-disarm chosen over refusal — friendlier; the debugger always wins.)
- **Auto-start guard (changed from v1):** the first stream connection auto-arms the pacer **only when
  `owner == idle`** — NOT when paused at a breakpoint (`owner == debugger`/halted). Opening the viewer
  must never hijack a paused debug session. Stop when the last stream disconnects (only if the pacer is
  the owner). `POST /api/run/start|stop` stay authoritative.
- **Test (§13):** with a stream connected, `run-to-cycle N` disarms the pacer and lands **exactly** at N
  (byte-identical to no stream connected).

---

## 6. WebSocket transport + wire protocol

### 6.1 Handshake (use std's built-in WebSocket — do NOT hand-roll)
`GET /api/stream` is detected in `dispatch` (`server.zig:273`) **before** the catch-all 404. Use the
`std.http.Server` WebSocket support — no hand-written SHA1/base64/101:
- `req.upgradeRequested()` (`references/zig/lib/std/http/Server.zig:500`) returns
  `.{ .websocket = sec_websocket_key }` when the client requested a WS upgrade (it also enforces
  `HTTP/1.1` + `GET`).
- `req.respondWebSocket(.{ .key = key })` (`:531`) computes
  `Sec-WebSocket-Accept = base64(SHA1(key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`, writes the
  `101 Switching Protocols`, and returns a `WebSocket` value.

Off-worker (like `/api/health`, `server.zig:280`): no command is submitted during the handshake, so it's
cycle-neutral. On success the **upgraded socket + its `WebSocket`/buffers move into the new stream
thread's frame** (§9.1); the handler returns without touching the machine. If the connection cap is
already reached, respond **503** instead of upgrading (§9.1/§10).

### 6.2 WebSocket framing (use `WebSocket.writeMessage` / `readSmallMessage`)
- **Server→client:** `WebSocket.writeMessage(payload, .binary)` (`:750`) — std emits the correct
  7/16/64-bit length header (server→client unmasked) and flushes. Our 22-byte header (§6.3) + index
  (+ palette) is just the `payload`. **Always rely on the 64-bit length form for big frames:** a
  320×200 frame with palette is ~64 KiB+768 B > 65535 → the 16-bit form can't carry it; `writeMessage`
  selects len64 automatically (`:789`). At the 640×480 ceiling (~300 KiB) it's still one binary message.
- **Client→server (input):** `WebSocket.readSmallMessage()` (`:706`) unmasks, **enforces the mask bit**,
  and skips pongs for us. **Constraint:** it rejects any frame larger than the WS *input buffer* or any
  non-FIN frame (`error.MessageOversize`, `:720/:728`) — so size the WS input buffer for the largest
  input (key/mouse) frame. Input frames are tiny (a few bytes, §6.5), so this is comfortably fine.

### 6.3 The frame wire protocol (minimal binary header + payload)
A small fixed header, little-endian, followed by index bytes [+ palette bytes when `has_palette`]:

```
offset  size  field
  0      2    magic         = 0x5A44   ('ZD')
  2      1    version       = 1
  3      1    flags         bit0 = has_palette (palette bytes follow the index)
                            bit1 = unsupported (no pixels; control-style marker)
  4      4    seqno         (u32, monotonic; the producer's publish version, low 32 bits)
  8      2    width
 10      2    height
 12      1    kind          (vga_render.Kind enum value)
 13      1    pel_mask      (DAC pixel mask; client applies index & pel_mask in the shader)
 14      4    index_len     (= width*height)
 18      4    palette_len   (768 when has_palette, else 0)
 22     ...   index bytes   (index_len)
 ...    ...   palette bytes (palette_len; RGB triples, already 6→8 expanded)
```

The header is 22 bytes; everything is explicit so the client never guesses. `has_palette` is set on the
first frame and whenever `palette_seq` changed since the client's last sent frame (the producer's
palette-change flag, §4.2). When `unsupported` is set, no pixel/palette bytes follow.

### 6.4 Control frames
For stop/terminal/unsupported events the server sends a WebSocket **text** frame with a tiny JSON
(`{"event":"stopped","reason":...,"cycle":...}` or `{"event":"unsupported"}`) so the page can show
"program exited" or "no renderer for this mode." Pixels are never fabricated.

### 6.5 Input (client→server), the round-trip
Two equivalent paths (v1 picks one; both land at command boundaries via the existing injection commands):
- **Same-WS framed input (recommended):** the browser sends a small binary message for key/mouse over the
  same socket; the stream thread reads it with `WebSocket.readSmallMessage()` (`:706`, unmasks + enforces
  the mask bit), translates it into `input_key`/`input_mouse` commands, and `submit`s them **through the
  submit-gate** (§5). Avoids per-event HTTP handshakes and keeps ordering with the frame channel (the
  cloud-gaming pattern, `research-low-latency-browser-streaming.md` §10). The translation runs in the
  **stream thread** and must touch only **stack/thread-local scratch** — never `self.arena`/`resp_buf`/
  `body_buf` (those are the server's one-connection-at-a-time scratch, §9.1).
- **Separate HTTP POSTs:** `keydown`/`keyup`/`mousemove`/`mousedown` → `POST /api/input/key|mouse`
  (`server.zig:418`/`:422`) — zero new server surface, simplest to ship; runs on the (serial) control
  accept loop, so the shared scratch is safe.

**Make/break edges (load-bearing).** The `{char}` HTTP path only sends a key-DOWN: `server.zig:508-514`
hardcodes `make = true, press = true` (no break edge). Games need both edges. So the framed-WS key input
carries an explicit **`{scancode, make, ext}`** triple (the same fields `input_key` already accepts,
`server.zig:490-498`): the client sends **make on keydown / break on keyup** (§7.4). Reserve `{char}`
only for typed text.

Either way the event enters the emulation **deterministically** at the next command boundary between
slices (Model A). The *cycle* it lands at depends on real-time pacing — fine: input timing was never part
of the determinism guarantee (only that a recorded input sequence at given cycles replays identically;
cycle-keyed Model B replay is the future bridge, `plans/input-injection.md`).

---

## 7. The WebGL2 player (the new homepage)

Served same-origin from `src/api/web/` via `@embedFile` (§8). The player uploads the indexed frame to the
GPU and expands the palette in a fragment shader — no per-pixel JS, 4× less wire than RGBA.

### 7.1 Textures
- **Index texture:** a 2D **integer** texture, internal format `R8UI`, format `RED_INTEGER`, type
  `UNSIGNED_BYTE`, size `width × height`, sampled via `usampler2D`. Filtering `NEAREST` (integer textures
  require nearest — filtered sampling of an integer texture is undefined), wrap `CLAMP_TO_EDGE`. Call
  **`gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1)`** before uploading (rows are 1-byte indices; the default
  alignment of 4 would corrupt odd-width rows). `texSubImage2D` the index bytes each frame
  (re-`texImage2D` only when dimensions change, §7.5).
- **Palette texture:** a `256 × 1` 2D texture, `RGB8`, `NEAREST`, updated via `texSubImage2D` only when
  `has_palette` is set (palette changed) — most frames skip this upload entirely.

### 7.2 Fragment shader sketch (GLSL ES 3.00)
```glsl
#version 300 es
precision highp float; precision highp usampler2D;
uniform usampler2D uIndex;     // R8UI, width x height
uniform sampler2D  uPalette;   // RGB8, 256 x 1
uniform uint uPelMask;         // DAC pixel mask
in vec2 vUv;                   // 0..1, flipped so row 0 is top
out vec4 frag;
void main() {
    // texelFetch with INTEGER coords — never texture(): filtered sampling of an
    // integer (usampler2D / R8UI) texture is undefined.
    ivec2 p = ivec2(vUv * vec2(textureSize(uIndex, 0)));
    uint idx = texelFetch(uIndex, p, 0).r & uPelMask;
    vec3 rgb = texelFetch(uPalette, ivec2(int(idx), 0), 0).rgb;
    frag = vec4(rgb, 1.0);
}
```
A full-screen triangle/quad provides `vUv`. The canvas is sized to the display size; the GPU scales for
free. Use `image-rendering: pixelated` on the canvas (or just NEAREST sampling) for crisp retro pixels —
**no server-side upscaling**. `uPelMask` mirrors the `indexToRgba` masking (`vga_render.zig:125`) so the
GPU result is identical to the CPU RGBA peek.

### 7.3 Client loop (drop-to-latest)
- `ws.binaryType = "arraybuffer"` for synchronous typed-array access. `onmessage` only **stores the
  latest** frame's `ArrayBuffer` (and flags new palette); a `requestAnimationFrame` loop uploads + draws
  whatever the latest stored frame is, dropping any intermediate frames the producer outran. This
  naturally never accumulates latency (`research-...` §6/§7).
- Parse the 22-byte header, slice the index (+ palette) views, detect mode/resolution change (§7.5),
  `texSubImage2D`, draw.

### 7.4 Key mapping (make/break, `KeyboardEvent.code` → set-1)
The client builds a **`KeyboardEvent.code` → set-1 `{scancode, ext}`** table — keyed on `code`
(layout-independent physical key), NOT `key`. The authority for the set-1 values is
`src/bios/scancodes.zig` (the base `table`, `:67-204`, and the extended `ext_table`, `:206-232`):
- On `keydown` send **make** (`{scancode, make: true, ext}`); on `keyup` send **break**
  (`{scancode, make: false, ext}`). This is why §6.5 uses the explicit `{scancode, make, ext}` triple —
  the `{char}` path only ever emits make/press (`server.zig:508-514`) and games need both edges.
- Extended keys (arrows, right-Ctrl/Alt, Insert/Home/etc., the keypad-/) carry the **`ext`** flag (set-1
  `0xE0` prefix) — `input_key` already forwards `ext` (`server.zig:496`).
- `{char}` is reserved for typed text only (where a single ASCII char resolves via
  `scancodes.resolveChar`, `server.zig:506`); the gameplay key path is the make/break scancode table.
- `e.preventDefault()` on captured keys so the browser doesn't scroll/navigate.

### 7.5 Resolution / mode change mid-stream
The frame header carries `(width, height)` and `kind` (§6.3). The player must:
- Detect a `(width, height)` change → **re-`texImage2D`** the index texture at the new size, resize the
  canvas backing store + `gl.viewport`. (`texSubImage2D` alone would mismatch the old allocation.)
- Handle the **`unsupported`** flag / text-mode frame (§6.4): show an overlay ("no renderer for this
  mode") and **keep the socket open** — never tear down the connection. v1 decision: **text modes are
  sent as `unsupported` control frames** (no pixel stream); graphics modes (13h, and the 640×480 ceiling)
  stream. Re-streaming resumes automatically when the guest returns to a supported mode.

### 7.6 Mouse mapping (absolute, no Pointer Lock)
Map canvas coords → guest absolute coords with `getBoundingClientRect()` + `devicePixelRatio`:
`gx = (e.clientX − rect.left) / rect.width * guestWidth` (and similarly for `y`), clamped to
`[0, guestWidth)` / `[0, guestHeight)`. Send absolute `x`/`y` to `input_mouse` (framed over the WS, or
`POST /api/input/mouse`, `server.zig:422`). **Absolute** is chosen over relative deltas so the cursor
tracks 1:1 without Pointer Lock (BaK is a point-and-click UI). Buttons map to `input_mouse` button state.

WebGPU is a future optional renderer swap (same texture/shader idea); WebGL2 is the v1 target for
universal support.

---

## 8. Static-serving integration (same-origin)

Per `plans/http-static-serving.md` (do not duplicate its mechanics here):
- Player assets live in `src/api/web/` — `index.html`, `app.js` (player + WS + WebGL), embedded via
  `@embedFile` in `server.zig` (single self-contained binary, no FS dep, no path-traversal surface).
- New `dispatch` branches (`server.zig:273`): `GET /` → `index.html`, `GET /app.js` →
  `text/javascript`, placed **after** the `/api/*` branches and **before** the 404 catch-all so they can
  never shadow an API route. Off-worker, no command submitted, cycle-neutral (`/api/health` pattern,
  `server.zig:280`).
- Same-origin means the page's `fetch('/api/...')` and `new WebSocket('ws://'+location.host+'/api/stream')`
  just work — no CORS, no second port.

---

## 9. Determinism / threading boundary (one paragraph)

The emulator core is untouched: the guest advances only inside the single `Controller.run*`/`step*` call
on the worker (`worker.zig:95`), which reads no host clock and charges only real/synthetic cycles. The
stream is host-side observation — frame sampling uses the existing **pure cycle-neutral peek**
(`controller.zig:759`), copied into an immutable shared snapshot; per-connection threads only read that
snapshot + a seqno, dedup with `Wyhash`, and write their own sockets. They charge no cycles, mutate no
device state, read no `cpu.st.cycles`, and are **never imported by `src/devices/`** (the new
stream/WS/WebGL code is host-side and stays out of the `src/devices` grep-gate, same boundary the PNG
encoder already honors). The only new emulation-adjacent piece is the paced free-run loop, which executes
the **identical cycle sequence** as an unpaced run (paced run-to-N ≡ unpaced run-to-N, byte for byte),
with host sleeps inserted only between slices. No host clock, RNG, or float touches anything affecting
emulated state. Constraints #1 (no ledger holes), #2 (time = f(cycles)), #4 (host may thread, never feeds
back into ordering — all machine access funnels through the single **submit-gated** queue, §5/§9.1), and
#6 (reproducibility) hold.

### 9.1 The multi-connection server change (two structural changes, called out honestly)
Today the server is strictly **one connection at a time, keep-alive OFF** (`server.zig:172-181` accept
loop). A long-lived WS stream concurrent with control/input requests requires **concurrent connections**
for the stream endpoint. This is **feasible** (verified): `net.Server.accept(io)` returns a copyable
`Stream` by value (`server.zig:174`), and `std.Io.Threaded` net ops are direct blocking syscalls with no
shared lock, so per-connection stream threads + a live accept loop run concurrently. Two structural
changes — neither is free, both are stated plainly:

**(1) Concurrent stream sockets vs the serial control loop.** On a WS upgrade, hand the socket to a
dedicated stream thread; the accept loop keeps taking short-lived **control** connections serially (v1
decision: **control stays serial**, only stream sockets go to threads — no need to make every control
request reentrant). **Lifetime rule:** the connection's `Reader`/`Writer`/`http.Server`/`WebSocket`/
buffers MUST live in the **stream thread's own frame** for the connection's lifetime — NOT the server's
shared `sr`/`sw` — and that thread closes the socket on exit.

**(2) Shared scratch is one-connection-at-a-time.** `arena`/`resp_buf`/`body_buf`/`read_scratch`
(`server.zig:113-117`, commented "one connection at a time → safe to reuse") are usable ONLY on the
serial control path. Any code that can run **concurrently** (the stream threads, incl. their input
translation) MUST use **stack / per-thread scratch** and must NOT touch `self.arena`/`resp_buf`/
`body_buf`/`read_scratch`. (Stream threads already get their own buffers; the §6.5 input-translation note
restates this.)

**Correctness (the v1 wording was wrong).** Stream threads reach the machine only via `submit` — but
`queue.submit` is **NOT** multi-producer-safe (`queue.zig:326` `assert(head==tail)` with a mutex-releasing
condvar wait, §5). Concurrent producers are made safe by the **submit-gate mutex** (§5), not by an
already-true invariant. So: *all machine access funnels through the submit-gated queue*; that gate is what
preserves one-in-flight, and the deterministic interleaving (CLAUDE #4) holds by construction.

**Connection cap.** Cap concurrent stream connections at **N = 4** (a fixed array registry). Beyond the
cap, reject the WS upgrade with **503** (don't `respondWebSocket`). This bounds per-connection thread
resources (each thread's index/palette copy + WS buffers).

**Single-broadcaster alternative (documented trade).** One broadcaster thread fanning out to N clients
would eliminate the `SharedFrame` lock entirely and is simpler for the realistic 1–3 viewers. v2 keeps
**per-connection threads** anyway — a wedged/slow client must not stall the others (the user's isolation
requirement); per-connection threads give each client independent backpressure (§10). This is the
explicit trade: a little more machinery for fault isolation.

**Shutdown ordering** (avoid the sentinel racing producers): (1) stop accepting; (2) **disarm the pacer**
and join its `src/host/` thread; (3) set the stream stop-flag, signal + **join all stream threads** (the
fixed-cap registry); (4) only THEN submit the worker `shutdown_worker` sentinel — so no producer can be
mid-`submit` when the sentinel goes in. The stream threads poll the stop flag between ticks and exit.

---

## 10. Worst-case + robustness

- **Resolution:** 320×200 typical (~64 KiB index/frame), 640×480 ceiling (~300 KiB; no VESA modes).
- **Bandwidth (raw indexed, 30 fps):** ~1.9 MB/s @320×200, ~9 MB/s @640×480 — trivial on localhost,
  comfortable on Gigabit LAN. Dedup drops static screens to near-zero. (A future **PNG remote tier**
  reusing `png.zig` — ~10–15 KiB/frame — is the bandwidth fallback for slow/remote links; deferred,
  not v1.)
- **Drop-to-latest under pressure:** producer publishes at the fps cap; stream threads read the *current*
  snapshot each tick and skip intermediates; the client's `rAF` loop draws only the latest. No queue grows
  anywhere; latency never accumulates.
- **Per-connection backpressure:** a slow client's send blocks only its own thread (it copies the shared
  frame and drops on its own time); it never holds the producer's mutex during a send, never stalls other
  clients, and never touches the emulator. A dead socket → close the thread; the producer is unaffected.
- **Unsupported mode / terminal / breakpoint:** control frame (§6.4), never fabricated pixels.
- **Terminate mid-stream:** on `program_terminated` (a `run_slice` returning a terminal `StopReason`) the
  pacer must **DISARM** — stop submitting `run_slice` against a dead machine, not merely "stop at the next
  slice." The last published frame stays streamable (clients keep seeing it + get the `stopped` control
  frame, §6.4), but the re-sampling loop halts. `owner` returns to `idle`.
- **Render + hash CPU budget:** the per-sample `framebuffer_get` peek + `Wyhash` over index+palette runs
  on the **worker between slices**. Wyhash over ~308 KiB at 30 Hz is negligible (multi-GB/s hash → tens of
  µs/frame), comfortably inside the slice cadence; it never perturbs cycle counts (peek charges no cycles).

---

## 11. Open questions (settle during implementation)

*Resolved in v2:* WS handshake/framing → use std's built-in WebSocket (§6); pacer placement →
`src/host/` to keep the api grep-gate intact (§5.1a); upgraded-socket ownership → feasible, owned by the
stream thread (§9.1, verified); multi-client cap → **N = 4, 503 beyond** (§9.1); run-ownership →
`RunOwner` arbitration (§5.3). Remaining:

- **Slice sizing / fps:** fixed default vs `slice_cycles`/`fps` params on `/api/run/start`; derive
  cycles-per-slice from a configured emulated CPU rate (deterministic integer). v2 target: slice
  wall-time ~8–16 ms for input latency, frame sample cadence 30 fps (capture every Nth slice, §5).
- **Producer placement:** run-pacer doubles as producer vs a standalone sampler thread (both only
  `submit(framebuffer_get)` through the submit-gate).
- **Input path:** framed-over-WS (recommended, §6.5) vs separate HTTP POSTs for v1.

---

## 12. Phased implementation roadmap

### Phase 1 — static serving (the page exists)
- [ ] Create `src/api/web/index.html` + `src/api/web/app.js` (initially a placeholder that `fetch`es
      `/api/health`, per `plans/http-static-serving.md`).
- [ ] Embed via `@embedFile` in `server.zig`; add `contentTypeFor` + a `serveStatic` branch in `dispatch`
      after `/api/*` and before the 404 (`server.zig:273`/`:432`). Off-worker, cycle-neutral.
- [ ] Tests: `GET /` → 200 `text/html`; `GET /app.js` → 200 `text/javascript`; `GET /nope` → 404;
      `POST /` → 405; an `/api/*` route still resolves (no shadowing).

### Phase 2 — paced free-run + run control (the picture can move)
- [ ] Add a `run_slice` worker command = `runUntilEvent(slice_cycles)` (mirror `.run`, `worker.zig:95`).
- [ ] Add the **submit-gate `std.Io.Mutex`** wrapping `queue.submit` so multiple host producers serialize
      (§5; the bare `head==tail` assert is NOT multi-producer-safe).
- [ ] Add the **run-pacer thread in `src/host/`** (NOT `src/api/`, to keep the api grep-gate intact,
      §5.1a): loop `host-sleep → submit(run_slice)` via the submit-gate; `/api/run/*` only flips an atomic
      it polls. `RunOwner` arbitration (§5.3); stop-on-terminal/breakpoint **disarms** the pacer (§10).
- [ ] `POST /api/run/start {slice_cycles?, fps?}` (409 if debugger owns the run), `POST /api/run/stop`,
      `GET /api/run/status` (clockless handlers in `server.zig`).
- [ ] Tests: **paced ≡ unpaced** byte-identical at the **actual final cycle** (§13); start/stop/status;
      breakpoint auto-stop; `run-to-cycle N` with a stream connected lands exactly at N (pacer disarmed).

### Phase 3 — WS handshake/framing + shared-frame producer + multi-connection model
- [ ] WS upgrade on `/api/stream` using **std's built-in WebSocket** — `req.upgradeRequested()` +
      `req.respondWebSocket()` (§6.1); frames via `writeMessage(.binary)` / `readSmallMessage` (§6.2).
      No hand-rolled handshake/framing.
- [ ] Server-model change (§9.1): hand the upgraded socket to a dedicated **stream thread** (owns its own
      `WebSocket`/buffers in its frame); accept loop keeps taking **serial control** connections. Stream
      threads use stack/per-thread scratch only — never `arena`/`resp_buf`/`body_buf` (`server.zig:113-117`).
- [ ] **Connection cap N = 4** (fixed-array registry; 503 beyond) + the **shutdown ordering** (stop-accept
      → disarm/join pacer → stop-flag + join stream threads → then `shutdown_worker` sentinel), §9.1.
- [ ] Add the `SharedFrame` buffer (`std.atomic.Value(u64)` seqno + `std.Io.Mutex`, §4.2; body read ONLY
      under the mutex) + the producer that `submit(framebuffer_get)` → copies snapshot → `Wyhash` → publish.
- [ ] Tests: handshake (`101` + correct `Sec-WebSocket-Accept`); a stream thread reads the shared frame;
      503 past the cap; clean shutdown joins all threads with no sentinel race.

### Phase 4 — raw-indexed broadcast + dedup (frames on the wire)
- [ ] Connection thread: read `SharedFrame` on a tick, `Wyhash` dedup vs `last_hash`, build the §6.3
      header + index (+ palette when changed), send a binary WS frame. Full frame on connect; optional
      heartbeat.
- [ ] Control frames for stop/terminal/unsupported (§6.4) — never fabricate pixels.
- [ ] Tests: frame round-trip (drive a mode-13h pattern as in `server_test.zig`, connect, receive a
      binary frame, assert header + index decode); **dedup correctness — a palette-only change is NOT
      skipped**; **heartbeat resend bypasses `last_hash`** (an unchanged frame IS resent on the heartbeat
      tick); cycle-neutral sampling (sampling N frames doesn't change final `cpu.st.cycles`).

### Phase 5 — WebGL2 player page
- [ ] `src/api/web/app.js`: WS client (`binaryType="arraybuffer"`), parse §6.3 header, R8UI index texture
      + 256×1 palette texture, the §7.2 fragment shader, `rAF` draw with drop-to-latest, `pixelated`
      scaling.
- [ ] `index.html`: the canvas homepage; optional auto `POST /api/run/start` on load (§5.2).

### Phase 6 — input round-trip (playable)
- [ ] Wire `keydown`/`keyup`/`mousemove`/`mousedown` → input (framed over WS via `readSmallMessage`, or
      `/api/input/key|mouse`). Client `KeyboardEvent.code → set-1 {scancode, ext}` table (authority
      `src/bios/scancodes.zig:67-232`) sending **make on keydown / break on keyup** (§7.4); absolute mouse
      via `getBoundingClientRect`+`devicePixelRatio` (§7.6). Lands at command boundaries (Model A).
- [ ] Test: an injected **make AND break** key edge over the stream path reaches the BDA ring / INT 33h
      state deterministically (not just the make edge the `{char}` path provides).

### Phase 7 — tests + demo + docs
- [ ] Boundary guard: stream/pacer code reads no `cpu.st.cycles` directly and is not added to the
      `src/devices` grep-gate; the only emulation access is via the submit-gated queue
      (`run_slice`/`framebuffer_get`). The `src/api` determinism grep-gate
      (`src/api/determinism_test.zig:30-62`) stays unchanged — the pacer's host clock lives in `src/host/`
      (§5.1a), outside the embedded api set, so no clock affordance enters any embedded api file.
- [ ] Manual black-box: open `http://localhost:PORT/`, watch BaK animate, press keys / move mouse and see
      it respond (assets out-of-tree → manual, like the screenshot TTM demo).
- [ ] Update `plans/ROADMAP.md` with the landed stream entry; note the determinism contract (§9).

---

## 13. Test plan (the load-bearing checks)

**Determinism (Hard Constraint #6):**
- [ ] **Paced ≡ unpaced:** run free-run for K slices of S cycles; capture CPU+framebuffer state AND the
      **actual final cycle C** of the paced run (a HLT fast-forward inside a slice can overshoot
      `start + K·S`, so do NOT assume the final cycle equals `start + K·S`). Reset, `run-to-cycle C`,
      capture; assert **byte-identical**. Run twice → identical (no host-clock leakage into state).
- [ ] **Sampling is cycle-neutral:** sampling N frames during a run leaves final `cpu.st.cycles`
      unchanged vs the same run with no sampling.
- [ ] **Run-ownership:** with a stream connected (pacer armed), `run-to-cycle N` disarms the pacer and
      lands **exactly** at N — byte-identical to the same `run-to-cycle N` with no stream (§5.3).

**Transport / protocol:**
- [ ] WS handshake: `GET /api/stream` with a valid `Sec-WebSocket-Key` → `101` + correct
      `Sec-WebSocket-Accept = base64(SHA1(key ++ GUID))`.
- [ ] WS framing: a frame whose payload exceeds 65535 bytes (a 320×200 + palette frame already does) is
      sent with the **64-bit length form** by `writeMessage` and decodes correctly on the client.
- [ ] Frame-protocol round-trip: drive a mode-13h pattern, connect, receive a frame, parse the §6.3
      header, assert index bytes match the laid pattern and palette matches the expanded DAC.
- [ ] **Dedup correctness:** an identical frame is skipped; a **palette-only change IS sent** (the hash
      covers index+palette); a full frame is always sent on connect.
- [ ] **Heartbeat resend:** on the heartbeat tick an unchanged frame IS resent (the heartbeat bypasses
      `last_hash`).
- [ ] Unsupported mode → an `unsupported` control frame, never fabricated pixels; the socket stays open.

**Run control + static:**
- [ ] `POST /api/run/start` → `/api/run/status` shows `running:true` + advancing cycle; `stop` halts at a
      slice boundary; a breakpoint during free-run auto-stops and the reason surfaces (status + control
      frame).
- [ ] Static-serving route (`GET /` → 200 `text/html`; no `/api/*` shadowing).

**Manual / demo:** open the page, watch BaK, press keys (§12 Phase 7).

---

## 14. Reference research (prior art — see the companion docs for full detail)
- `plans/research-low-latency-browser-streaming.md` — the consensus *local* pattern is WebSocket binary
  frames → canvas with strict drop-to-latest (noVNC raw, jsmpeg); WebCodecs/WebRTC are WAN/compression
  tiers gated on a C codec dependency we avoid; MSE/LL-HLS are wrong for no-buffer live. Confirms raw
  indexed primary on localhost.
- `plans/http-static-serving.md` — same-origin `@embedFile` serving from the existing server.
- dosbox-staging ZMBV (`references/dosbox-staging/src/capture/video/zmbv.cpp`): deflate over
  block-motion-XOR'd **indexed** frames — validates that an indexed delta codec is dependency-light if a
  future bandwidth tier is wanted (but it is AVI-wrapped, not browser-native).
- spice86 has **no** live browser stream (its remote surface is a GDB server) — the live-stream feature is
  new ground for zdos.
