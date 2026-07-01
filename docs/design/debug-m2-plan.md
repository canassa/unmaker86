# M-S2 — Frames, Scopes & Variables for the Source-Level Debugger

**Status:** plan (no code). Zig 0.16, for the zdos deterministic, headless,
cycle-reproducible 16-bit DOS emulator (MCP/HTTP debugger API). Companion to
`debug-core-plan.md`, `debug-core-architecture.md`, and `debug-source-inlining-plan.md`.

This plan turns the **shipped** M-S1 (`whereami` / source+function breakpoints / source
stepping, blocking path) and M-S1.5 (inlined source windows) into **stack unwinding,
scope/variable inspection, and a lazily-expandable variable tree** — the DAP/MCP
`stackTrace` / `scopes` / `variables` / (assessed) `evaluate` layer. It is the milestone
the architecture doc explicitly **deferred to M-S2**: the *nested-serialize-on-worker*
transport seam and the *expansion-handle / stop_epoch* lifecycle.

> **Prime directive (CLAUDE.md §1): determinism.** Every M-S2 op is a **side-effect-free
> PEEK** at the machine state *at the stop cycle*. It must NEVER perturb the machine,
> charge the cycle ledger, read a host clock/RNG, enter `Machine.Snapshot`, or rely on
> host scheduling. All ordering is deterministic (dense arrays, ascending indices).
>
> **No fabrication (CLAUDE.md §2).** If a frame cannot be unwound, an outer-frame
> register-stored local cannot be recovered, a type cannot be rendered, or an expression
> cannot be evaluated, the API surfaces that **honestly with a typed reason**. A
> wrong-but-plausible answer is the worst possible outcome for a debugger. The
> honest-degradation catalogue (§11) is the heart of this plan.

---

## Table of Contents

0. [Ground truth this plan builds on](#0-ground-truth-this-plan-builds-on)
1. [Piece 1 — the worker-side JSON serialization seam](#1-piece-1--the-worker-side-json-serialization-seam)
2. [Piece 2 — backtrace / stackTrace (the correctness-critical part)](#2-piece-2--backtrace--stacktrace)
3. [Piece 3 — scopes / locals / the variable tree](#3-piece-3--scopes--locals--the-variable-tree)
4. [Piece 4 — evaluate (assessment + recommendation)](#4-piece-4--evaluate-assessment--recommendation)
5. [R3 — the combined `context` call](#5-r3--the-combined-context-call)
6. [Stopped-state gating + the stop-epoch wiring](#6-stopped-state-gating--the-stop-epoch-wiring)
7. [Determinism checklist](#7-determinism-checklist)
8. [Honest-degradation catalogue](#8-honest-degradation-catalogue)
9. [Tool surface (MCP schemas)](#9-tool-surface-mcp-schemas)
10. [Milestone sequencing within M-S2](#10-milestone-sequencing-within-m-s2)
11. [Test plan](#11-test-plan)
12. [Open `TODO(verify):` items](#12-open-todoverify-items)

---

## 0. Ground truth this plan builds on

Read these first; this plan cites them by `file:line` and stays consistent with them.

**The shipped core (M-S1 / M-S1.5):**

- `src/debug/core/core.zig` — the neutral DTOs: `Addr` (`:44`), `SourceLoc{file_id,path,line}`
  (`:48`), `PcLocation{addr,function,source}` (`:56`), `StopKind` (`:86`),
  `StopState{running,kind,pc,bp_id,cycle,exit_code}` (`:88`), `SrcLine`/`SourceWindow`
  (`:116`/`:126`), `StepKind`/`StepOutcome` (`:135`/`:140`), the step budgets
  `STEP_BURST_CYCLES`/`STEP_WEDGE_CAP_CYCLES` (`:33`/`:38`). **All slice-bearing DTOs are
  worker-side render targets, EXCLUDED from the reflection gate, never on `q.Response` as
  slices** (core.zig header `:13-18`).
- `src/debug/core/debugger.zig` — `SourceDebugger` (`:155`): `gpa`, `ctrl: *Controller`,
  `syms: ?Symbols`, `map: ?AddressMap`, `specs`, `step: StepSession` (`:89`), `state: State`
  (`:99` = `{configuring, running, stopped, terminated}`), the source cache. Methods:
  `attachOnLoad` (`:190`), `onMachineReverted` (`:209`), `pcLocation`/`pcLocationUnchecked`
  (`:332`/`:337`), `sourceLocOf` (`:348`), `projectStop` (`:557` — **the ONE place
  `StopReason` is read; it sets `state` and resolves `pc`**), `sourceWindow` (`:476`),
  `fileIdForName`/`sourceFileName`/`sourceFileCount` (`:537`/`:529`/`:523`), `livePc`/`lineKey`
  (`:847`/`:852`), the `Error` set (`:44` = `{NotStopped, NoSymbols, Unresolved,
  SpecTableFull, BreakpointTableFull, NoSuchBreakpoint}`).
- `src/debug/symbols/types.zig` — `TypeGraph`: `typeInfo` (`:338`), `typeName` (`:423`),
  `typeSize` (`:330`), `members` (`:396`), `bases` (`:406`), `enumerators` (`:413`),
  `localsForScope` (`:469`), `parentOf` (`:476`), `scopeForAddr` (`:487`),
  `typedefForSymbol` (`:387`); PODs `TypeInfo` (`:55`), `MemberInfo{name_index,type_ref,
  byte_offset,bit_width,kind}` (`:113`), `BaseInfo{type_ref,class_index,is_virtual,
  byte_offset}` (`:127`), `EnumeratorInfo{name_index,value}` (`:140`), `Local{name_index,
  type_ref,storage}` (`:156`), `Storage` union (`:146` = `auto:i16 / register:u8 /
  static:{seg,off} / constant:i16 / absolute:u16 / other:u8`), `MemberKind` (`:99`),
  `PtrKind` (`:38`). `primitiveName` (`:512`, a **free function**, not a `TypeGraph` method).
  Note `typeName` (`:423`) **streams into a `*std.Io.Writer` and returns void** — it does not
  return a slice (T13).
- `src/debug/symbols/format.zig` — `Reg` (`:83`, `ax=0 cx=1 dx=2 bx=3 sp=4 bp=5 si=6 di=7
  al..bh`), `FuncClass` (`:240`, `near_c=0 far_c=4 interrupt=7`, bit2=far), `MemoryModel`
  (`:110`, `tiny small medium compact large huge`), `PointerClass` (`:228`), `TypeId`
  (`:185`).
- `src/debug/symbols/index.zig` — `FuncRef{sym_index,segment,start,end,name_index}` (`:36`,
  **no `type_index`**), `SymRef{...,type_index,...}` (`:41`), `LineHit{line,file_id,
  code_offset}` (`:30`), `ImageAddr{segment,offset}` (`:27`); `typeRefForFunction(FuncRef)
  -> ?u16` (`:417`), `entryOffsetForFunction(FuncRef) -> u16` (`:312`, post-prologue),
  `functionName(FuncRef)` (`:397`), `nameToSymbol` (`:323`), `sourceFile`/`fileId`/
  `fileIdByBasename`/`sourceFileCount` (`:347`/`:363`/`:376`/`:354`).
  **There is NO FPO / frame-less flag and NO per-function memory-model field** — only
  `entryOffsetForFunction` (prologue landing) and `typeRefForFunction → function.far`.
- `src/debug/symbols/map.zig` — `AddressMap{index:*const SymbolIndex, base_para:u32}`
  (`:23`); **all methods take `self: AddressMap` BY VALUE** (it is a 2-field POD):
  `attach(idx,psp_seg)` (`:31`, `base_para = psp_seg+0x10`), `toRuntimeLinear(seg, off)`
  (`:36`), `imageAddrForLinear(linear) -> ?ImageAddr` (`:44`), `runtimeAddrForLine` (`:57`),
  `lineForRuntimeAddr(linear) -> ?LineHit` (`:63`), `functionForRuntimeAddr(linear) ->
  ?FuncRef` (`:69`), `entryAddrForFunction(FuncRef) -> u32` (`:77`).
- `src/debug/symbols/symbols.zig` — `Symbols{source, tds:?*Tds, index:SymbolIndex,
  typegraph:?TypeGraph}` (`:79`): `attach(psp_seg) -> AddressMap` (`:144`),
  `scopeForRuntimeAddr(am, linear) -> ?usize` (`:152`, 0-based innermost scope; null for
  `.map`/`.none`).
- `src/debug/controller.zig` — the **only** way to read machine state: `cpuSnapshot() ->
  CpuSnapshot` (`:1472`; **32-bit registers** `eax ecx edx ebx esp ebp esi edi`, segs `cs ds
  es fs gs ss` + `*_base`, `eip`, flags, `cycles`, `halted`, `shutdown` — POD at `:166`;
  **no 16-bit `ax/bx/…` accessors, truncate the `eXX`**), `peekMem(seg: cpu.Seg, off: u32,
  dst: []u8)` (`:1536`; `Seg = enum{es,cs,ss,ds,fs,gs}`), `peekMemPhys(phys, dst)` (`:1519`),
  `peekStack(out: []u16) -> []u16` (`:1977`, words from `SS:SP` up), `currentCycle()` (`:984`),
  `addBreakpoint`/`removeBreakpoint`/`runUntilEvent` (`:634`/`:671`/`:480`). **Never
  `bus.read*`/`portIn*`.**

**The transport precedent to generalize (the framebuffer path):**

- `src/api/queue.zig` — `Command` union (`:62`); `framebuffer_get: void` (`:148`); the M-S1
  debug command arms `dbg_where`/`dbg_set_*_bp`/`dbg_step_*`/`dbg_run_to_line`/
  `dbg_read_source`/`dbg_list_sources` (`:216-239`); `Response` union (`:662`);
  `framebuffer: FramebufferResult` (`:685`); **`FramebufferResult` (`:546`) carries only
  `index_len`/`rgba_len` length descriptors — the *bytes* stay in the session-owned
  `RenderBuffers`**; the M-S1 flat debug PODs `PcLocationResult` (`:596`), `DbgStopResult`
  (`:642`), `DbgBreakpoint`/`DbgBpSetResult`/`SourceWindow`/`SourceFilesResult`; caps
  `DBG_PATH_CAP=128`/`DBG_NAME_CAP=128`/`DBG_MAX_SPECS=64` (`:250-253`). The reflection-gate
  note (`:588-592`).
- `src/api/worker.zig` — off-Command `RenderBuffers` (`:107`, allocated once at server
  start, reached via a `*RenderBuffers` the worker holds — **not** carried in the
  pointer-free Command); `framebufferResp(ctrl, render)` (`:662`, writes the big payload into
  the session slab, returns only the descriptor); `Worker` fields (`:1147`:
  `render:?*RenderBuffers` `:1155`, `sd:?*SourceDebugger` `:1173`, `source_roots` `:1177`);
  `drainOne(ctrl, ctx, mount, render, live, snapshots, run_ctl, sd)` (`:153`); the run loop
  `waitDequeue → drainOne → queue.complete` (`:1201`).
- `src/api/server.zig` — `RESPONSE_BUF = 48*1024` (`:67`); `submitAndRespondFramebuffer`
  (`:2679`): holds `session.lock.lockUncancelable(io)` + `defer unlock` (`:2704`) only across
  `submit → read/encode → @memcpy into the Conn-owned buf + capture body_len`, then **unlocks
  and writes the socket over the owned copy**; the **length descriptor `body_len` that
  crosses the lock** (`:2701/:2726/:2735`); the debug serializer dispatch `writeResponseBody`
  (`:2824`) → `writeWhere`/`writeDbgStop`/`writeSourceWindow`/… (`:2865-2870`); the overflow
  precedent **`respondError(req, .service_unavailable, "internal", "response too large")`**
  (`:3184`, `:2815`, …) for HTTP, and **`respondRpcError(req, id, .internal, "response too
  large")`** for MCP (`:2146`/`:2543`); `errInfo` (`:3232`, the `ErrCode → {status,code,msg}`
  map). The MCP debug span analog is `submitDebuggerAndRespond` (referenced `:1064`).
- `src/api/mcp_tools.zig` — `Tool{name,description,input_schema,per_machine}` (`:47`); the
  `tools` catalog; `buildCommand` arms (`:1144-1182`); `SrcLineReq`/`fillSrcBp` (`:837`/`:859`);
  `parseCtx`/`ctxFrom` (the `context` parse).
- `src/api/session.zig` — `Session` (`:201`): `ctrl`, `queue`, `worker_thread`, `render`,
  `snapshots`, `recipe`, `mount_dir`, `source_debugger`, `lock`; the documented lock order
  (`:65`) `session.lock → run_control.arb → queue.submit_gate → queue.mutex`.
- The gates: `src/debug/determinism_test.zig` (grep gate `sources` `:12-32` already lists
  `core/core.zig` + `core/debugger.zig`; reflection gate over the symbol PODs);
  `src/api/determinism_test.zig:155` (`expectNoPointerFields(q.Command)` + `(q.Response)`).

**The integration facts (the test oracle).** `examples/BB.C`: `clamp(int v,int lo,int hi)`
has local `int r`; `main(void)` has `struct Pixel p`, `enum Mode m`, `int i`;
`struct Pixel{int x;int y;unsigned char color;}`; `enum Mode{TEXT,GRAPHICS,HIRES}`
(GRAPHICS=1); call site `p.x = clamp(300,0,319)` is line 21, `clamp` body lines 9-12,
`main`'s first stmt line 20. `src/debug/symbols_integration_test.zig:153-187` proves at the
`BB.C:9` stop: **`v → auto [BP+4] == 300`, `lo → register BX(3)`, `hi → register CX(1)`,
`r → register DX(2)`** — the canonical worked example (note three of clamp's four locals are
register-stored: the outer-frame-register honest-degradation case, §8).

---

## 1. Piece 1 — the worker-side JSON serialization seam

**(Build first. Everything else rides it.)** M-S2 results — backtrace (N frames), scopes
(variable-count), locals (N vars × name+type+rendered-value), the recursive variable tree —
are **variable-length and nested**. They cannot ride the flat pointer-free PODs (forcing
them through fixed `MAX_FRAMES`/`MAX_DEPTH`/`MAX_VALUE_LEN` caps would *silently truncate a
struct's rendered value* — a fake, forbidden by CLAUDE.md §2, the exact reason
`debug-core-plan.md §3.1a` routes these through Category B). They **generalize the
framebuffer seam**: the worker, while Stopped, serializes the result to **JSON bytes** into a
**session-owned bounded buffer**; only a `{ body_len }` descriptor crosses `q.Response`; the
listener copies the owned bytes under `session.lock`, unlocks, and writes the socket.

### 1.1 The session-owned JSON body buffer (the new off-Command slab)

Mirror `RenderBuffers` (`worker.zig:107`) exactly, but for text:

```zig
// src/api/worker.zig (new, beside RenderBuffers)
pub const DBG_JSON_CAP: usize = 256 * 1024;   // bounded; the EXPLICIT nested-body ceiling
pub const DebugJsonBuffer = struct {
    body: [DBG_JSON_CAP]u8 = undefined,       // the worker-serialized JSON for ONE nested op
};
```

**T8 — the two front-ends must share ONE success ceiling.** HTTP can stream a 256 KiB body
straight to the socket, but the **MCP** path (the *primary* frontend) wraps the body with
`mcp.writeTextResult` → `std.json.Stringify.encodeJsonString(inner_body, …)` into a
`std.Io.Writer.fixed(resp_buf)` (`mcp.zig:114-117`; `resp_buf = RESPONSE_BUF = 48 KiB`,
`server.zig:67`), and **JSON-escaping the body can ~2×** its size. A ~100 KiB backtrace would
then return 200 on HTTP but `response_too_large` on MCP — a silent divergence in what
"succeeds". The fix (chosen): **stream the escaped JSON-RPC envelope incrementally to the
socket** (a small `writeEscapedToSocket` that escapes the owned body in fixed-size chunks,
exactly as `handleMcpScreenshot` already streams base64 past `resp_buf`, `server.zig:2500+`),
so MCP and HTTP share the **same** `DBG_JSON_CAP` ceiling rather than MCP's 48 KiB/2. (The
alternative — clamp `DBG_JSON_CAP` to ~`RESPONSE_BUF/2` so both transports share a small
ceiling — is simpler but throttles HTTP needlessly; prefer incremental MCP streaming.)

- **Ownership + lifetime:** the `Session` owns one `DebugJsonBuffer` (heap, allocated once at
  session init beside `render`; `session.zig`), freed in `Session.deinit`. The `Worker` gets
  a new `?*DebugJsonBuffer` field (`worker.zig:1147`, beside `render:?*RenderBuffers` `:1155`)
  set at **both** worker-spawn sites (`server.zig:386` default, `session_registry.zig`
  provisioned — the same two sites `.render`/`.sd` are set; missing one regresses provisioned
  machines). It is reached **off-Command**, never inside the pointer-free `q.Command`.
- **Why session-owned and not Conn-owned:** the bytes are produced *by the worker, while
  Stopped*, from the same registers/RAM/symbol-arena the stop observed. A Conn/listener-side
  serializer would read that state *after* the worker resumed → a different,
  non-reproducible machine. Worker-side emission makes the body a **pure function of the stop
  cycle** (`debug-core-plan.md §3.1a` "determinism rationale").

### 1.2 The descriptor that crosses `q.Response`

One **generic** nested-result arm (the backtrace/scopes/locals/variables/context bodies are
all "a JSON document of length N in the session slab" — one arm serves them all, so the body
is produced once, deterministically, and the wire shape never drifts):

```zig
// src/api/queue.zig
pub const DbgJsonResult = struct { body_len: u32 = 0 };   // a LENGTH is not a pointer → passes the gate
// Command union (:216 region) — new arms (T18: distinct request types, no reuse with
// mismatched field sets):
//   dbg_backtrace:       DbgBacktraceCmd,   // { full: bool, max_frames: u16 }
//   dbg_scopes:          DbgScopesReq,      // { frame: u16 }
//   dbg_frame_variables: DbgFrameVarsReq,   // { frame: u16 }          (scopes + locals in one body)
//   dbg_variables:       DbgVarsReq,        // { ref: u64, start: u32, count: u32 }  (expand/page a handle, T16a)
//   dbg_inspect:         DbgInspectReq,     // { frame: u16, path_len: u8, path: [DBG_PATH_CAP]u8 }  (T9: FLATTENED path)
//   dbg_context:         DbgContextReq,     // { window: u16, max_frames: u16 }  (R3; arg renamed `window`, T16b)
// Response union (:662 region) — ONE new arm reused by all of the above:
//   dbg_json:            DbgJsonResult,
```

**T9 — `dbg_inspect`'s path must not be a slice.** A `[]const u8 path` on `q.Command` is a
`.pointer` and fails `expectNoPointerFields(q.Command)`. Flatten it into `path:[DBG_PATH_CAP]u8
+ path_len` (the M-S1 `fillSrcBp` precedent, `mcp_tools.zig:859`) — or carry it in
`RequestCtx.scratch` like `mem_write` (`queue.zig:88`), since `RequestCtx` is excluded from the
gate. Either way `dbg_inspect` is a full member of the Command-arm enumeration above.

`DbgJsonResult` is integers only ⇒ `expectNoPointerFields(q.Response)`
(`api/determinism_test.zig:155`) stays unchanged and green; the new Command PODs are
integers only ⇒ `expectNoPointerFields(q.Command)` likewise. The seam routes **bytes** (in
the slab), never a slice — strictly safer than any slice-crossing scheme: immune to both the
read-after-resume race **and** the `load`/`reset`-frees-the-symbol-arena use-after-free
(`debug-core-architecture.md §4` head note).

### 1.3 The worker handler (clockless JSON)

In `drainOne` (`worker.zig:153`), new arms delegate to a new `worker.zig` helper that writes
into `self.dbg_json.?.body` via `std.Io.Writer.fixed` + `std.json.Stringify` (the same
encoder family `server.zig` already uses for the flat bodies), pulling values from the pure
core:

```zig
fn dbgJsonResp(sd: ?*SourceDebugger, body: ?*DebugJsonBuffer, build: anytype) Response {
    const s = sd orelse return .{ .err = .no_symbols };       // honest, never a fake body
    const buf = body orelse return .{ .err = .load_failed };
    if (s.state == .running) return .{ .err = .not_stopped };  // §6 gating
    var w = std.Io.Writer.fixed(buf.body[0..]);
    build(s, &w) catch return .{ .err = .response_too_large };  // EXPLICIT overflow → typed error
    return .{ .dbg_json = .{ .body_len = @intCast(w.buffered().len) } };
}
```

The worker stays **clockless / RNG-free**: it builds JSON from owned bytes + integer
indices + peek reads; no `std.time`, no `std.Random` (it remains inside the `src/api` grep
posture). `build` is the only place that calls the core's `backtrace`/`scopes`/`variables`
renderers (§§2-3); the core itself produces neutral DTOs and **the worker emits them to
JSON** — preserving the "core decides what to read, worker does host I/O + JSON" split.

**Overflow policy — EXPLICIT, never silent truncation (CLAUDE.md §2).** A body that would
exceed `DBG_JSON_CAP` makes the fixed writer return `error.WriteFailed`; the worker maps it
to `q.ErrCode.response_too_large` (a **new** `ErrCode`, → HTTP `413 payload_too_large` /
MCP tool error; sized so the JSON path gets its *own* honest error rather than the binary
path's raw `respondError` idiom). The listener never sees a clipped JSON document. (For a
genuinely huge backtrace/tree the agent narrows `max_frames` / expands one handle at a time —
the DAP-lazy contract of §3 already keeps any one body bounded in practice.)

### 1.4 The listener (copy-under-lock, then stream)

A new `submitDebuggerJsonAndRespond` (the `submitAndRespondFramebuffer` analog,
`server.zig:2679`), used by **both** the HTTP route and the MCP `tools/call` dispatcher so
they emit **identical body bytes** (MCP wraps the exact JSON the HTTP route returns — the
bytes are produced once on the worker, so there is **no drift**, the seam *removes* a drift
risk):

```
buf = self.ensureDbgBuf()                            // a Conn-owned copy target (gpa.alloc DBG_JSON_CAP, cached)
var body_len: usize = 0;
{ session.lock.lockUncancelable(io); defer unlock;   // the CAPTURE span (session.zig CONTRACT)
  resp = session.queue.submit(&ctx);                 // blocks until the worker finished serializing
  switch (resp) {
     .dbg_json => |d| { @memcpy(buf[0..d.body_len], session.dbg_json.body[0..d.body_len]); body_len = d.body_len; }
     .err => |code| { record errInfo(code); }          // not_stopped / no_symbols / response_too_large / stale_handle
     else => record "unexpected debug response";
  }
}                                                    // UNLOCK before any socket write
if (failure) respond the typed error (HTTP errInfo status / MCP tool error);
else write the OWNED copy buf[0..body_len] to the socket (HTTP body / MCP text result).
```

**Why this respects the no-borrow-past-Stopped-epoch invariant (T10 — corrected rationale).**
The naive ordering claim is *backwards*: `complete()` (`queue.zig:816`) runs **before** and
**causes** `submit` (`:778`) to return, and the worker then **immediately loops back to
`waitDequeue` concurrently** with the listener's copy — and a `run`/`load` from *another*
connection does **not** take `session.lock`. So the safety does **not** come from the worker
being blocked. It comes from two real invariants:

1. **The JSON is fully materialized into OWNED bytes (the session slab) by the worker BEFORE
   `complete()`** — the body is finished text, not a borrowed view into the symbol arena or
   guest RAM. A concurrent `run`/`load` that advances RAM or frees+rebuilds the symbol arena
   therefore touches **disjoint** state; the slab bytes are already a closed, self-contained
   document. (Contrast a slice-bearing DTO, which *would* be a use-after-free here — exactly
   why the seam routes bytes, not slices.)
2. **`session.lock` serializes the dbg_json PRODUCERS/consumers.** Every command that writes
   `session.dbg_json` (every nested debug query) is submitted **under `session.lock`** (the
   CAPTURE span above), so two debug queries cannot interleave their slab writes, and the
   listener's copy reads a single, complete body. *(Stated explicitly as the contract: a
   `dbg_json`-producing command must be submitted while holding `session.lock`.)*

Concurrent nested queries on one session thus serialize on `session.lock` (the same
CAPTURE-span contract concurrent framebuffer captures obey); the copy is of finished owned
bytes, immune to a concurrent `run`/`load` on another connection.

### 1.5 New typed `ErrCode`s (one wire vocabulary)

Add to `q.ErrCode` + `errInfo` (`server.zig:3232`): `not_stopped` (→ 409 conflict),
`stale_handle` (→ 409), `response_too_large` (→ 413), `bad_frame` (→ 400). Reuse the existing
`no_symbols` / `unresolved` (already asserted by `debug_test.zig:211`). These are the typed
signals the honest-degradation catalogue (§8) emits.

---

## 2. Piece 2 — backtrace / stackTrace

The correctness-critical part. Real 16-bit real-mode stack unwinding over the **Borland C
frame convention** — `push bp; mov bp,sp` (`55 8B EC`), so within a frame: saved caller BP at
`SS:[BP]`, near return IP at `SS:[BP+2]`, far return `CS:IP` at `SS:[BP+2]`/`SS:[BP+4]`. New
pure module `src/debug/core/unwind.zig` (on the grep gate); new neutral DTO `core.Frame`.

### 2.1 The neutral frame DTO

```zig
// src/debug/core/core.zig
pub const Frame = struct {
    index: u32,                  // 0 = innermost (live CS:IP); DAP/mcp-debugger convention
    pc: Addr,                    // frame 0: live CS:IP. callers: the CALL-SITE addr (return-addr - 1, §2.5)
    function: ?[]const u8,       // borrowed name; null ⇒ no symbol covers this pc
    source: ?SourceLoc,          // file:line of the call site (or live line for frame 0)
    frame_base: u16,             // this frame's BP (SS-relative); the locals base for §3
    is_far: bool,                // this frame was entered by a FAR call (callee far) — affects the parent read
    unreliable: bool = false,    // a sanity check failed; this frame's identity is suspect — see `stop_reason`
};
pub const BacktraceStop = enum { bp_zero, bp_not_increasing, no_function, c0_startup,
                                 no_call_site, interrupt_boundary, max_frames,
                                 frameless_callee, ok_top };
pub const Backtrace = struct { frames: []const Frame, truncated_reason: BacktraceStop };
```

`no_call_site` is the T3 defense (the reconstructed return address is not preceded by a
`CALL` ⇒ we refuse to emit the parent). The walk needs the SS stack window for the BP
sanity check; `CpuSnapshot` exposes `ss`/`ss_base` but **not** the SS limit
(`controller.zig:166`; the authoritative `seg_limit[ss]` lives in `cpu/state.zig:119`). This
plan therefore specifies **one additive, outside-the-seam touch**: add a `ss_limit: u32`
field to `debug.CpuSnapshot` (filled from `cpu.st.seg_limit[ss]`) — the pure `unwind.zig`
core must NOT reach into `ctrl.m.cpu.st`, so it reads the bound off the snapshot. (This is a
real, non-trivial change to `controller.zig` + the POD; it is *not* part of the §1 transport
seam.)

### 2.2 The unwind algorithm (pseudo-code)

All reads are `peekMem(.ss, …)` / `peekStack` (side-effect-free; charge zero cycles; leave
`snapshot()` byte-identical). BP/SP/regs come from `ctrl.cpuSnapshot()`.

All offset arithmetic into a segment is **masked to u16** before peeking — real-mode wraps
at 64 KiB (`peekStack` already masks; `peekMem(seg, off:u32)` does **not**, so we mask at the
call site). `peek16(seg, off)` ≡ `peekMem(seg, u16(off), &b2); readInt(u16, b2, .little)`.

```
fn backtrace(sd, out: []Frame, max_frames) Backtrace:
    snap = ctrl.cpuSnapshot()
    pc0  = snap.cs_base +% snap.eip
    bp   = u16(snap.ebp)                       // truncate the 32-bit reg (CpuSnapshot has no bp16)
    ss_lo = u16(snap.esp)                       // current SP
    ss_hi = u16(snap.ss_limit)                  // SS segment limit (the NEW CpuSnapshot field, §2.1)
    // ---- frame 0 (live) ----
    f0_func = map.functionForRuntimeAddr(pc0)  // ?FuncRef
    cur_seg_base = snap.cs_base                 // T2: the code-segment base for NEAR returns; updated on each FAR pop
    frames[0] = mkFrame(0, pc0, f0_func, bp, is_far=false, live=true)
    // PROLOGUE CHECK (§2.4): if pc0 is still in this fn's prologue, BP is the CALLER's —
    // frame 0's frame_base is invalid; mark unreliable, do NOT walk.
    if inPrologue(pc0, f0_func): frames[0].unreliable = true; return {frames[0..1], frameless_callee}

    i = 1
    prev_fn = f0_func                            // T18: init before use
    had_symbols = (f0_func != null)              // T18: init before use
    cur_far = isFar(f0_func)                     // the CALL convention of the function we are LEAVING
    while i < min(max_frames, out.len):
        // sanity: BP inside the stack window, even, and the chain must ASCEND.
        if bp == 0:                          return {frames[0..i], bp_zero}
        if (bp & 1) != 0:                    return {frames[0..i], bp_not_increasing}  // odd BP ⇒ not a real frame
        if bp < ss_lo or bp >= ss_hi:        return {frames[0..i], bp_not_increasing}  // BP left the stack window
        saved_bp = peek16(.ss, bp)           // caller BP   (offset masked to u16)
        if saved_bp != 0 and saved_bp <= bp: return {frames[0..i], bp_not_increasing}  // not strictly ascending
        ret_ip   = peek16(.ss, bp + 2)
        if cur_far:
            ret_cs       = peek16(.ss, bp + 4)
            ret_seg_base = u32(ret_cs) << 4
            ret_lin      = ret_seg_base +% ret_ip
        else:
            ret_lin      = cur_seg_base +% ret_ip   // T2: NEAR uses the CURRENT code-seg base, not frame-0's
        site_lin = ret_lin -% 1                 // the CALL site, not the next statement (§2.5)
        // ---- T3: CALL-SITE VERIFICATION (the highest-value hardening) ----
        // Require the bytes ending at ret_lin to be an actual CALL — else a garbage BP that
        // passed the window/ascending checks (zero-init RAM reality) would fabricate a plausible
        // parent. Scan back up to 7 bytes for E8 cw (near), 9A cd (far), or FF /2 //3 (indirect).
        if not endsWithCall(ret_lin):
            // refuse to fabricate. If this is frame 1 (the most common garbage case) the chain is
            // bogus from here — stop. Flag the boundary honestly.
            return {frames[0..i], no_call_site}
        site_fn  = map.functionForRuntimeAddr(site_lin)
        // ---- termination: we walked out of symbolized code ----
        if site_fn == null:
            // ret addr maps to no function. If we previously HAD a function, we reached the C
            // runtime startup (C0) or an ISR trampoline — stop honestly, never emit a bogus frame.
            return {frames[0..i], (had_symbols ? c0_startup : no_function)}
        // ---- interrupt-frame guard ----
        // If the callee we just left is an INTERRUPT handler, the layout above it is the
        // CPU-pushed [FLAGS][CS][IP], NOT a BP frame. We cannot BP-walk through it — stop.
        if isInterrupt(prev_fn): return {frames[0..i], interrupt_boundary}
        frames[i] = mkFrame(i, site_lin, site_fn, saved_bp, cur_far, live=false)
        bp        = saved_bp
        prev_fn   = site_fn
        had_symbols = true
        if cur_far: cur_seg_base = ret_seg_base  // T2: a FAR pop crossed code segments — rebase NEAR reads
        cur_far   = isFar(site_fn)               // the NEXT pop uses the callee-being-left's far-ness
        i += 1
    return {frames[0..i], max_frames}
```

`endsWithCall(ret_lin)` peeks the ≤7 bytes ending at `ret_lin` (the byte *after* the CALL)
and matches a CALL encoding: `E8 cw` (near rel), `9A cd` (far abs), or a `FF` ModRM with
reg-field `/2` (near indirect) or `/3` (far indirect). A match at the right length-from-end
accepts the frame; no match ⇒ `no_call_site` (refuse to fabricate). This is what *enforces*
the §8 "never a fabricated parent" claim under garbage BP — without it, even/in-window/
ascending BP + a resolvable `functionForRuntimeAddr(ret-1)` would emit a wrong parent with
`unreliable=false`.

`isFar(funcref)` (§2.3) and `isInterrupt(funcref)` both resolve via
`index.typeRefForFunction(f) → typegraph.typeInfo(t)`; **T18: assume NEAR / not-interrupt
when `typeInfo(t)` returns any non-`.function` variant or null**, not only when the type-ref
is null.

### 2.3 Near vs far per frame

`isFar(funcref)` = `index.typeRefForFunction(f)` (`index.zig:417`) → `typegraph.typeInfo(t)`
→ `.function.far` (`types.zig:79/374`, derived from the `FuncClass` bit2). A `.map`-backed
image (no TDS type) or a null type-ref ⇒ **assume near** (small-model default) and the frame
carries that assumption; this is exactly what `armStepOut` already does
(`debugger.zig:677-688`). BB.EXE is small-model (all near). The format supports far, so the
loop handles **both** per-frame: the far-ness used to pop a frame is the **callee's** (the
function whose frame we are leaving), because that callee decided whether it was reached by
`E8`(near `CALL`) or `9A`(far `CALL`) and therefore whether it pushed a 1-word or 2-word
return.

### 2.4 Frame-less / FPO / leaf detection (HONEST degradation)

The symbol layer exposes **no FPO/frame-less flag** (§0). We detect a non-standard prologue
by **scanning the bytes at the function entry** via the peek path (no cycle cost):

- `inPrologue(pc, f)` uses **two** tests, OR-combined:
  1. **Structural (works for `.map` images too — T5):** the live `pc` image-offset is within
     `[f.start, f.start + 3)` (3 = `len("55 8B EC")`). `entryOffsetForFunction(f)` alone is
     **not** sufficient: it falls back to `f.start` for a `.map`-backed function that has no
     interior line records (`index.zig:312-320`), so a PC sitting *at* `f.start` — exactly
     where a `.map` function/addr breakpoint lands, before `push bp` — would NOT be flagged,
     and the caller's BP would be used as frame-0's base with `unreliable=false`. The
     `pc < f.start + 3` window catches that case independently of the line table.
  2. **Prologue-shape:** read the function's first 3 code bytes (`peekMem(.cs, …)` via
     `map.imageAddrForLinear`); if they are **not** `55 8B EC` (`push bp; mov bp,sp`) the
     function is frame-less. Also: if `pc` is at/after `f.start` but **before**
     `entryOffsetForFunction(f)` (a TDS image with line records), it is still in the prologue.
- **What we do, never fabricate:** for **frame 0** in a frame-less/mid-prologue function we
  emit frame 0 with `unreliable=true` and **stop** (`truncated_reason = frameless_callee`) —
  we may not be able to find the saved-BP chain at all. For an **outer** frame whose function
  is frame-less, the BP we read from the child's saved-BP slot does not belong to it; the
  ascending-BP sanity check (§2.2) catches the corruption and terminates with
  `bp_not_increasing` rather than emitting a bogus parent. Either way we **flag or stop**, we
  never invent a parent.
- This is the design risk the architecture doc names (`debug-core-architecture.md §11 risk
  3`): optimized `-O` builds may omit BP frames. The BaK relink and BB.EXE are `-v` debug
  builds (standard frames). The plan **does not fabricate** for the optimized case — it
  surfaces `frameless_callee`/`bp_not_increasing` and the agent gets frame 0 only.

### 2.5 Per-frame source mapping (the call-site line)

For frame 0, `source` = `lineForRuntimeAddr(pc0)`. For a **caller** frame the return address
points at the instruction *after* the `CALL`; mapping that would name the *next* statement.
Map **`ret_lin - 1`** (the last byte of the `CALL`) so the line is the **CALL site**, not the
following statement — standard debugger convention. `function` = `functionName(site_fn)`;
`source` = `sourceLocOf(lineForRuntimeAddr(site_lin))`. Frames whose `site_lin` maps to no
line carry `source = null` (honest; an inter-statement address). The M-S1.5 source window
(`sd.sourceWindow`, `debugger.zig:476`) is reused **per frame for R3** (§5) — each frame's
window is centered on its `source.line`.

### 2.6 Outer-frame registers are NOT recoverable (call it out — affects §3)

Frame 0's register values are **live** (`cpuSnapshot`). For an **outer** frame the saved
registers live wherever the callee spilled them (callee-save pushes), which the TDS does not
map — so an outer frame's register-stored local is **honestly unavailable** (§3, §8). In
BB.EXE this is concrete: `clamp`'s `lo`/`hi`/`r` are in BX/CX/DX; if `clamp` is an *outer*
frame (e.g. stopped inside a callee of clamp), those three are `available=false` while `v`
(BP-relative auto) and `main`'s `struct Pixel p` (BP-relative auto) remain readable off the
outer frame's `frame_base`.

### 2.7 Output

JSON, innermost-first (frame 0 = top), via the §1 seam:
`{"frames":[{"index":0,"function":"_clamp","file":"BB.C","line":9,"addr":{"seg":..,"off":..,
"linear":..},"frame_base":<BP>,"unreliable":false}, …],"truncated_reason":"c0_startup"}`.
`truncated_reason` is always present so the agent knows *why* the walk stopped (a degradation
signal, not a hidden cap).

---

## 3. Piece 3 — scopes / locals / the variable tree

New pure module `src/debug/core/vars.zig` (on the grep gate). Generalizes the integration
proof's hardcoded `.auto=4 → SS:[BP+4]` read (`symbols_integration_test.zig:184-187`) into a
`Storage`-driven dispatch + type-directed rendering + a lazy expansion handle.

### 3.1 Neutral DTOs

```zig
// src/debug/core/core.zig
// T12: arguments and locals are COLLAPSED into one `locals` scope for M-S2. `Local`
// (types.zig:156) carries no param flag — `isParam` is on `format.Symbol` and is dropped by
// `localFromSymbol`, so an arguments/locals split is unimplementable today AND would
// misclassify register-stored params (clamp's `lo`/`hi` in BX/CX). One `locals` scope is
// DAP-legal and is all an LLM needs. (Splitting args out is a future symbol-layer
// enhancement: `Local` would have to carry `isParam`.)
pub const ScopeKind = enum { locals, registers, globals };
pub const Scope = struct { kind: ScopeKind, frame_index: u32, variables_ref: u64 };  // u64 handle (T11); expands to its vars
pub const VarAvail = enum { ok, outer_frame_register, unreadable, no_storage };
pub const Variable = struct {
    name: []const u8,               // borrowed from the symbol arena (Tds.name)
    // T13: `TypeGraph.typeName` STREAMS into a `*std.Io.Writer` and returns void — it does
    // NOT yield a slice. The type name is therefore rendered DIRECTLY into the JSON writer on
    // the worker (or a worker scratch buffer), never carried as a borrowed slice on the DTO.
    value_text: []const u8,         // rendered scalar/enum-name/pointer/hex; "" when avail != ok
    avail: VarAvail = .ok,          // HONEST: outer_frame_register / unreadable ⇒ no fabricated value
    addr: ?Addr = null,             // where it lives (auto: SS:BP+off; static: seg:off); null for register/const
    type_ref: u16 = 0,              // the worker streams typeName(type_ref) into the JSON
    variables_ref: u64 = 0,         // non-zero ⇒ aggregate/array/pointer; u64 handle (T11); expand via `variables{ref}`
    writable: bool = false,         // M-S2: read-only (setVariable is a later, deliberate-input op)
};
```

### 3.2 scopes — walk the scope chain

For the selected frame `f` (frame 0 unless DAP passes a frame index):
`pc = frames[f].pc.linear`; `scope0 = syms.scopeForRuntimeAddr(map, pc)`
(`symbols.zig:152`); climb `tg.parentOf` (`types.zig:476`) to the function top, gathering
`tg.localsForScope` (`types.zig:469`) at each level. Emit **one `locals` scope** holding all
of them (T12 — no args/locals split, which `Local` cannot support), plus a `registers` scope
(the live CPU regs, frame 0 only) and an optional `globals` scope (file-scope statics —
deferred). **Determinism:** scopes and their locals are emitted in dense `localsForScope`
order (already table-order, innermost scope first), never hashed.

### 3.3 locals — Storage dispatch (the peek reads)

For each `Local` (`vars.zig:renderLocal(local, frame) -> Variable`):

All segment-offset reads **mask the computed offset to u16** before `peekMem` (T6: real-mode
wraps at 64 KiB; an outer-frame BP near `0xFFFE` would otherwise read past the segment), and
**bounds-check the linear range against the RAM slab** before peeking via the worker's
`inSlab` pattern (`worker.zig:144`, the same guard `mem_write`/`searchRam` use) — an
out-of-slab read (a static in a non-resident segment, or a corrupt outer BP pointing outside
RAM) yields `avail = unreadable`, **never** the `unmapped_fill` byte rendered as a plausible
value (T15b/c). (`inSlab` is worker-side; the pure core returns the resolved linear range +
a "needs-read" marker and the worker does the bounds-checked peek — keeping `unwind.zig`/
`vars.zig` off any `ctrl.m` internal.)

| `Storage` | read | notes |
|---|---|---|
| `.auto = off` (i16) | `eff = u16(frame.frame_base +% off)`; `addr.linear = ss_base +% eff`; bounds-check + `peekMem(.ss, eff, dst)` | works for **any** frame (outer frames too — `frame_base` is that frame's BP). *(proof: `v` at +4 == 300)* |
| `.register = n` (u8) | **frame 0 only**: live reg from `cpuSnapshot` via `format.Reg`. **Reg 0-7** (`ax cx dx bx sp bp si di`) → low 16 of the matching `eXX`; **Reg 8-11** (`al cl dl bl`) → low byte; **Reg 12-15** (`ah ch dh bh`) → `(eXX >> 8) & 0xFF` (T7 — NOT a plain truncate, which would give `al` for an `ah` local). **Outer frame ⇒ `avail = outer_frame_register`, no value** (§2.6, §8) | *(proof: `lo`=BX, `hi`=CX, `r`=DX)* |
| `.static = {segment,offset}` | global: `map.toRuntimeLinear(segment, offset)`; bounds-check + `peekMemPhys(linear, dst)`; out-of-slab ⇒ `avail = unreadable` | frame-independent. *(T18: the `Storage.static` fields are `segment`/`offset`.)* |
| `.constant = c` | render `c` directly; no bus read; `addr=null`, `writable=false` | |
| `.absolute = a` | render `a` directly; no bus read | |
| `.other` | rendered raw / `avail = no_storage` | unmodelled class byte |

### 3.4 Type-directed rendering

`typeInfo(local.type_ref)` (`types.zig:338`) drives `value_text`; the **type name** is
streamed by the worker via `typeName(type_ref, writer)` straight into the JSON (T13 — it
returns void, never a slice). **Text-encoding policy (T16c):** every string the worker emits
into the JSON body — `name`, `value_text`, type names, `char`/`char[]` byte renderings — is
**CP437→UTF-8 transcoded with CR-strip + TAB-expand BEFORE `Stringify`** (the M-S1.5
`cacheSource` policy, `debugger.zig:133-153`), not just the R3 source window; a raw guest high
byte (`0x80..0xFF`) in a `char[]` or an identifier must never reach `encodeJsonString` (it
would emit invalid UTF-8 or panic under `escape_unicode`).

- **`.primitive`** → integer value (read `size` bytes LE) as decimal **+ hex**; `char` also
  shows the byte. Sign per `TypeId`.
- **`.enumeration`** → read the value, match `enumerators(type_ref)` (`types.zig:413`) → the
  **enumerator NAME** (e.g. `GRAPHICS`); unmatched value renders as the integer with a `(?)`
  honest marker, never an invented name.
- **`.pointer`** → the pointer value as `seg:off` hex (far) / `off` hex (near, +current seg).
  `variables_ref` non-zero ⇒ **one-level deref** on expand (read the pointee at the target via
  the `PtrKind` segment base; a null/zero pointer expands to an honest `"<null>"` child, never
  a wild read). **Decision:** do *not* auto-deref inline (could read arbitrary guest memory);
  deref only on explicit expansion (DAP-lazy).
- **`.array`** → `count` (`types.zig:353`) and element type; `variables_ref` non-zero ⇒ expand
  to indexed children `[0]…[count-1]`, bounded by a per-expand `MAX_CHILDREN`. An array larger
  than the cap is **paged** via the `variables{ref,start,count}` schema (T16a, §9) — the
  expansion handle plus an explicit window — never silently clipped.
- **`.aggregate`** (struct/union/class) → summary `"{…}"`; `variables_ref` non-zero ⇒ expand
  to `members(type_ref)` (`types.zig:396`), each at `base + byte_offset`; for a **class** also
  walk `bases(type_ref)` (`types.zig:406`) at `base + base.byte_offset`. Bitfield members
  (`bit_width != 0`) render the extracted field. Method/static members (`MemberKind != .data`)
  render as a typed **signature**, no value (they have no data offset — `types.zig:113` note).
- **`.function`/`.unknown`** → type name only, no value.

**Float rendering: raw hex bytes ONLY.** The Borland primitive set includes
`float/double/ldouble/tpreal` (`types.zig:342`), but zdos has **no x87** (memory note
*no-FPU-constraint*) and the core is on the grep gate that **forbids `f32`/`f64`**
(`determinism_test.zig:37-40`). A float local's `value_text` is its storage rendered as a
fixed-width hex byte string (e.g. `0x00 00 80 3F`); the **type name** (`"float"`) still
renders. No host `std.fmt` float conversion (a gate violation *and* a host-rounding
nondeterminism).

### 3.5 The expansion-handle / stop_epoch lifecycle (the piece the arch doc DEFERRED)

DAP `variablesReference`: a struct/array/pointer var carries a `variables_ref` the frontend
passes back to `variables{ref}` to lazily expand one level. We must **never** serve a stale
handle (from a prior stop) as a silent wrong read. Design, in full:

```zig
// src/debug/core/debugger.zig — a HOST-SIDE table on SourceDebugger (never snapshotted)
pub const MAX_HANDLES = 256;
const ExpandNode = struct {                  // what a variables_ref encodes
    frame_index: u16,
    target: enum { aggregate, array, pointee },
    type_ref: u16,                            // the type to expand
    base: Addr,                               // where the aggregate/array lives (or the pointer's pointee target)
    seg_sel: format.PtrKind = .near,          // for a pointee: which segment base to use
    elem_count: u32 = 0,                      // arrays
};
const ExpandTable = struct {
    nodes: [MAX_HANDLES]ExpandNode = undefined,
    count: u16 = 0,
};
// on SourceDebugger:
stop_epoch: u64 = 0,                          // STRICTLY MONOTONIC for the Session lifetime; only +%=1, NEVER reset
expand: ExpandTable = .{},
```

- **INVARIANT (T1 — `stop_epoch` is strictly monotonic, never zeroed).** It starts at 0 only
  for a **fresh Session** and thereafter is **only ever incremented** (`+%= 1`) — by every
  resume **and** by `attachOnLoad` / `onMachineReverted`. It is **NEVER reset to 0**. This is
  critical and easy to get wrong: the shipped `attachOnLoad`/`onMachineReverted` reset
  `self.step = .{}` to its default; an implementer mirroring that reflex for the epoch would
  zero it, and a prior-stop handle (`ref` with `slot 0`) would then **re-validate against a
  DIFFERENT struct at the reused slot** after a `restore`/`load` — a silent wrong value, and a
  **cross-program** stale read on `load`. So: `stop_epoch` lives *outside* the `self.step`/
  `self.expand` reset; the reset clears `expand.count` but the epoch only ever climbs.
- **Minting:** while rendering a frame's locals (or a parent expansion), an aggregate/array/
  pointer var allocates the next `ExpandTable` slot, recording `{frame_index, target,
  type_ref, base, …}`. The returned `variables_ref` is a **u64-safe descriptor** packing the
  epoch + slot: `ref = (stop_epoch << 16) | (slot + 1)` (slot+1 so a valid ref is never 0;
  `MAX_HANDLES = 256` fits 16 bits). **What it encodes:** frame + the resolved address path
  (`base` Addr + type), so expansion is a pure re-peek at the same stop — no path re-walk.
  *(T11: a u64 ref with a 48-bit epoch + 16-bit slot stays exactly representable as a JSON/DAP
  number — DAP `variablesReference` is a number, integer-safe to 2^53 — and does not wrap for
  any realistic session, unlike a u32 `epoch<<12` which overflows after ~2^20 resumes and then
  fail-closed rejects every fresh handle, silently killing the variable tree. `Variable.
  variables_ref` and the `DbgVarsReq.ref` Command field are therefore `u64`.)*
- **Validation (the no-stale-read guarantee):** `variables{ref}` decodes `epoch = ref >> 16`,
  `slot = (ref & 0xFFFF) - 1`; if `epoch != self.stop_epoch` **or** `slot >= self.expand.count`
  → **reject `error.StaleHandle`** (`ErrCode.stale_handle`, §1.5) — a clean typed error, never
  a silent stale read. Because the epoch only climbs (the T1 invariant), a handle minted at a
  *prior* stop is always detectably wrong even after the table is cleared and the slot reused.
- **Invalidation:** `self.expand.count = 0; self.stop_epoch +%= 1` on **every resume** (§6).
  Handles are valid **only within one Stopped epoch**; the table is rebuilt fresh at each
  stop. This is the lifecycle the architecture doc (`§6.2`, conflict-cases row "Stale
  variableReference") deferred to M-S2.

### 3.6 Output

Via the §1 seam. `scopes{frame}` → `{"scopes":[{"kind":"arguments","variables_ref":N}, …]}`.
`variables{ref}` (or `frame_variables{frame}` = scopes+locals in one body) →
`{"variables":[{"name":"v","type_name":"int","value_text":"300 (0x12C)","avail":"ok",
"variables_ref":0}, {"name":"lo","type_name":"int","avail":"outer_frame_register"}, …]}`.
`avail != "ok"` carries no `value_text` — the honest "I cannot recover this" signal.

---

## 4. Piece 4 — evaluate (assessment + recommendation)

**Recommendation: SPLIT the full C-expression `evaluate` into M-S3. Ship in M-S2 only a
strictly-bounded, clearly-labelled `inspect` op (bare identifier + a literal member/index
path), with EVERY non-trivial expression returning an honest `unsupported`.**

**Why defer the parser.** A faithful C-expression evaluator is real work: a recursive-descent
parser over identifiers, member `.`/`->`, array `[]`, address-of/deref `&`/`*`, casts,
unary/binary arithmetic, C integer promotion + precedence — all resolved against the
scope/type graph + peek path. The no-shortcuts mandate (CLAUDE.md §2) makes a *half*
evaluator the **worst** option: silently mis-handling precedence, a cast, or pointer
arithmetic yields a wrong-but-plausible number — the exact failure mode this project exists
to escape. A regex/string-match "evaluator" is forbidden. Doing it right deserves its own
milestone with its own test corpus (the architecture doc already scopes `evaluate` to Tier 3
/ M-S3 — `debug-core-architecture.md §10`, `debug-core-plan.md §8`).

**What M-S2 ships instead (free — it reuses `vars.zig`).** A `dbg_inspect{frame, path}` op
(the `path` **flattened** into `[DBG_PATH_CAP]u8 + path_len`, never a `q.Command` slice — T9,
§1.2) where `path` is **only**: a bare local/argument name (`"v"`), optional `.`/`->` member
chains (`"p.x"`, `"p->x"`), and constant array indices (`"a[2]"`). It resolves the head
identifier through the §3.2 scope walk, then re-uses the §3.4 type-directed member/index
descent + peek — **no operators, no arithmetic, no casts, no `&`/`*` as expression syntax,
no function calls**. Anything outside that grammar → `error.UnsupportedExpression`
(`ErrCode.unsupported_expression`, an honest "use M-S3" signal), **never a guessed result**.
This is not an "expression evaluator" and is documented as such; it is a path-addressed
variable read, the same faithful peek the variable tree already does. It gives agents the
80%-case (`p.x`, `node->next->value`) with zero risk of a wrong arithmetic answer.

**Hard determinism boundary for the real M-S3 evaluator (recorded now).** No guest
execution, ever: a function-call eval (`foo(x)`) would charge cycles and inject an
unrecorded input — **forbidden** (CLAUDE.md §1). The M-S3 evaluator is peek-only
(`debug-core-plan.md §10 risk 4`); side-effecting expressions are rejected, not run.

---

## 5. R3 — the combined `context` call

The pwno-mcp "fast context snapshot for LLM agents" ergonomic
(`debug-source-inlining-plan.md §R3`): one MCP call returning, in one nested-JSON body
(§1), **current frame `PcLocation` + its source window + the full backtrace + frame-0
locals** — built on pieces 1-3, reusing M-S1.5's `sourceWindow` render (no new
source-window work). Shape:

```json
{ "frame":     { "function":"_clamp", "file":"BB.C", "line":9, "addr":{…} },
  "window":    { "has":true, "active_line":9, "lines":[ … ] },           // §1.5 reuse, per the top frame
  "backtrace": [ {"index":0,"function":"_clamp","file":"BB.C","line":9,"frame_base":…}, … ],
  "locals":    [ {"name":"v","type_name":"int","value_text":"300 (0x12C)","avail":"ok"}, … ] }
```

`dbg_context{window, max_frames}` → `dbg_json` (the source-window radius arg is `window`,
T16b). The worker `build` callback emits the four sections in fixed order (deterministic);
each section degrades honestly (absent symbols ⇒ `"window":null`, `"backtrace":[…ok_top]`,
`"locals":[…avail flags]`). This is the single tool an agent calls on every stop.

---

## 6. Stopped-state gating + the stop-epoch wiring

**Gating.** All M-S2 inspection ops (`backtrace`, `scopes`, `frame_variables`, `variables`,
`inspect`, `context`) are valid **only when Stopped**. The worker rejects them with
`ErrCode.not_stopped` whenever `sd.state == .running` (§1.3) — the live BP/SP/registers are
meaningful only at a clean instruction boundary; we return a typed error rather than peek a
mid-burst machine (`debug-core-architecture.md §6` "inspection ops gated on Stopped").

**The stop-epoch / state wiring — a structural `drainOne` change to raise (T4).** `projectStop`
(`debugger.zig:557`) sets `sd.state` + (M-S2) bumps `stop_epoch`, but it runs **today only
inside `dbgStep`** — *not* on the plain run/step path. ~10 `drainOne` arms advance the machine
and return a stop **directly from the controller**, bypassing `SourceDebugger` entirely:
`run` (`worker.zig:162`), `run_slice` (`:166`, the live-play run-pacer's per-tick advance),
`run_to_cycle`/`run_to_address` (`:167`/`:171`), `step`/`step_n`/`step_over`
(`:175`/`:176`/`:177`), and the **input-injection** ops that charge cycles + move CS:IP:
`clickMouse` (`:224`), `injectMouseDeliver` (`:241`), `tapKey` (`:451`). Plus bare `reset`
(`:265`) wipes the machine to zero-init RAM but leaves `sd.state`/`stop_epoch` stale — a
pre-reset handle would then read zero-init RAM as a plausible value. So `sd.state`/`stop_epoch`
would be stale after any of these (M-S1 has this latent seam; M-S2 makes it load-bearing
because handles depend on it). **This is a cross-cutting `drainOne` change, not reuse of
existing wiring.**

**Required wiring — state it MECHANICALLY, not as a hand-list:** wrap **every `drainOne` arm
that charges cycles, advances CS:IP, or wipes the machine**:

1. **Before** such an arm runs, the worker calls `sd.beginResume()` → `expand.count = 0;
   stop_epoch +%= 1; state = .running`. (For the `dbg_step_*` arms this can fold into
   `beginStep`; for the ~10 plain arms above + `reset` it is a new explicit call.)
2. **After** the arm returns a stop on **any** path, the worker calls `sd.noteStopped(reason)`
   (= `projectStop`) so `sd.state = .stopped` and the stop's `pc` is resolved — regardless of
   which command stopped the machine. `restore` (`:283`-ish) instead calls `onMachineReverted`
   (`debugger.zig:209`).
3. **T1 — none of `beginResume` / `attachOnLoad` / `onMachineReverted` / `reset`-handling may
   ZERO `stop_epoch`.** They clear `expand.count` and reset `step`/`state`, but the epoch is
   **only incremented** (it lives outside the `self.step = .{}` reset, §3.5 invariant). Only a
   fresh `SourceDebugger.init` starts it at 0.

This makes the handle epoch a **universal, path-independent** invalidation: every resume —
through any front-door, including the run-pacer and input injection — clears the table and
bumps the (monotonic) epoch, so a prior-stop handle is always detectably stale. Host-side (no
machine touch), deterministic, and robust to a restore-to-an-earlier-cycle (the counter only
climbs, so a handle whose cycle coincidentally matches is still rejected by the epoch
mismatch).

---

## 7. Determinism checklist

- [ ] **Peek-only.** Every read is `cpuSnapshot`/`peekMem`/`peekMemPhys`/`peekStack`
      (`controller.zig:1472/1536/1519/1977`) — never `bus.read*`/`portIn*`. An inspection
      leaves `ctrl.snapshot()` byte-identical and charges **zero cycles**.
- [ ] **No cycle perturbation.** No `runUntilEvent`/`step*` on the inspection path; backtrace
      walks the stack by peeking, it never executes.
- [ ] **No host clock/RNG/float/atomic/thread** in `src/debug/core/{unwind,vars}.zig` — they
      go on the `src/debug/determinism_test.zig` `sources` grep gate (`:12-32`) beside the
      existing `core/*.zig`. Float locals render as hex bytes (§3.4).
- [ ] **Deterministic ordering.** Frames innermost-first; scopes/locals in dense
      `localsForScope`/table order; members in `members()` order; enumerators in
      `enumerators()` order. No HashMap, no unordered iteration.
- [ ] **Nothing in `Machine.Snapshot`.** The `ExpandTable`, `stop_epoch`, and the JSON slab
      are host-side (SourceDebugger / Session), freed/rebuilt by `attachOnLoad`/`deinit`,
      never serialized — the `LoadRecipe` posture.
- [ ] **Pure core vs worker split.** The core (`unwind.zig`/`vars.zig`) decides *what to
      read* and produces neutral DTOs (slices into the symbol arena + scratch); the **worker**
      does the host I/O (none, beyond peek via the ctrl it holds) + the **JSON emission** into
      the session slab. The neutral DTOs never cross `q.Response` as slices — only `body_len`.
- [ ] **The Response/Command PODs stay pointer-free** — `DbgJsonResult{body_len}` and the new
      Command request PODs are integers only ⇒ both `expectNoPointerFields` gates
      (`api/determinism_test.zig:155`) stay unchanged + green.
- [ ] **Explicit overflow.** A body over `DBG_JSON_CAP` → `ErrCode.response_too_large`, never
      a truncated JSON (CLAUDE.md §2).
- [ ] **Two runs byte-identical.** Same binary + same inputs ⇒ identical stop cycle ⇒
      byte-identical backtrace/locals/tree JSON.

---

## 8. Honest-degradation catalogue

The heart of the "no fakes" mandate. Every case where fidelity is limited on real-mode DOS,
and the EXACT typed signal:

| Case | Why it cannot be done faithfully | Honest signal |
|---|---|---|
| **Reconstructed caller not preceded by a CALL (garbage BP)** | An even/in-window/ascending BP (zero-init RAM reality) can resolve a plausible `functionForRuntimeAddr(ret-1)` without an actual call ever having happened. | **CALL-opcode check at the call site (T3, §2.2)**; no `E8`/`9A`/`FF /2`//`/3` ⇒ `truncated_reason = no_call_site`, the frame is **refused**. This is what *enforces* "never a fabricated parent". |
| **Outer-frame register local** | The callee spilled the reg somewhere TDS does not map; only frame 0's regs are live (`cpuSnapshot`). | `Variable.avail = outer_frame_register`, `value_text=""`. *(BB.EXE: clamp's `lo`/`hi`/`r` as an outer frame.)* |
| **Frame-less / FPO caller (optimized `-O`)** | No `push bp; mov bp,sp`; no saved-BP chain. Symbol layer has no FPO flag. | frame 0: `unreliable=true`, `truncated_reason=frameless_callee`. Outer: the ascending-BP **or** the CALL-site check trips → `bp_not_increasing` / `no_call_site`. **Never a fabricated parent.** |
| **PC mid-prologue (frame 0), incl. `.map` at `f.start`** | BP is still the caller's; this frame's `frame_base` is invalid. The `.map` case (PC == `f.start`) is caught structurally by `pc < f.start+3` (T5). | frame 0 `unreliable=true`, `frameless_callee`; do not walk. |
| **Far/near assumed (no TDS type)** | `.map`-backed image carries no `function.far`. | Assume near (small-model default), recorded; same as `armStepOut`. The frame's **`unreliable=true`** marks the assumption (this is the `unreliable` the `backtrace` tool advertises for outer frames — T15a; it is set on an *assumption*, never silently on a hard failure, which terminates instead). |
| **Interrupt / callback frame (IRQ, INT 74h/AX=0Ch)** | CPU pushed `[FLAGS][CS][IP]`, not a BP frame — a BP-walk would mis-read. | Stop at the boundary: `truncated_reason=interrupt_boundary`. Detected when the callee-being-left is `FuncClass.interrupt`. |
| **Return addr maps to no function** | Reached C0 startup / a trampoline / library with no symbols. | `truncated_reason = c0_startup` (had symbols) or `no_function`. |
| **Non-constant SS (a program that reloads SS)** | The whole unwind + every `.auto` read assumes one stack segment; if the guest switched SS, `frame_base`/`SS:[BP]` reads are against the wrong segment. | We cannot detect a prior SS switch from a single snapshot — so the BP-window / ascending / CALL-site checks (§2.2) are the backstop: a cross-SS frame fails them and **terminates** (`bp_not_increasing`/`no_call_site`) rather than mis-reading. Documented assumption: small/medium/compact/large single-SS models (BB.EXE, BaK). |
| **Static local in a non-resident segment** | `peekMemPhys` of an unmapped linear returns `unmapped_fill`, which would render as a plausible value. | Bounds-check against the RAM slab (`inSlab`, `worker.zig:144`) ⇒ `avail = unreadable`, no value (T15b). |
| **Out-of-slab `.auto` / pointer read (corrupt outer BP)** | A corrupt outer `frame_base` (or a wild pointer target) points outside RAM. | `avail = unreadable` — a row **distinct** from `<null>` (T15c): `<null>` is an honest zero pointer; `unreadable` is "the address is not in mapped RAM". |
| **Enum value with no matching enumerator** | The stored value is not a declared enumerator. | Render the integer + `(?)`, never invent a name. |
| **Unmodelled `Storage.other` / missing type** | Symbol class byte not modelled / `type_ref` out of range. | `avail = no_storage` / type name `"?"`; no value. |
| **Stale `variables_ref` after a step** | Handle from a prior Stopped epoch (epoch only climbs, T1). | `ErrCode.stale_handle` (epoch mismatch), 409. **Never a silent stale read.** |
| **No symbols (stripped image)** | No TDS / `.map` only. | `ErrCode.no_symbols`; address-level still works. |
| **Nested body over the slab cap** | Genuinely huge backtrace/tree. | `ErrCode.response_too_large` (413, shared HTTP+MCP ceiling, T8); narrow `max_frames` / page expansion. |
| **Expression beyond the M-S2 subset** | No full parser yet (§4). | `ErrCode.unsupported_expression`; the real evaluator is M-S3. |
| **Null pointer deref** | Expanding a zero pointer. | Child `"<null>"`; no read. *(A non-zero but out-of-slab pointer target is `unreadable`, the row above.)* |

---

## 9. Tool surface (MCP schemas)

New rows in `mcp_tools.zig:tools` + `buildCommand` arms (`:1144` region). All per-machine.
Bodies are the §1 nested-JSON (served via `submitDebuggerJsonAndRespond`).

- **`backtrace`** `{ full?:bool=true, max_frames?:int=32 }` → the frame list (§2.7).
  Desc: *"The call stack, innermost first: each frame's {index, function, file:line of the
  call site, address, frame_base}. `truncated_reason` says why the walk stopped (c0_startup /
  no_call_site / interrupt_boundary / bp_not_increasing / frameless_callee) — frames past it
  are NOT fabricated (a reconstructed caller is refused unless its call site is a real CALL). A
  frame's `unreliable:true` flags an *assumption* (e.g. near/far guessed for a `.map` image
  with no type info); a hard failure terminates the walk instead of emitting a doubtful frame."*
- **`locals`** / **`frame_variables`** `{ frame?:int=0 }` → scopes + that frame's variables in
  one body (§3.6). Desc: *"The selected frame's arguments + locals: {name, type, value, avail}.
  `avail:"outer_frame_register"` means the value lives in a register the callee overwrote and
  is honestly unrecoverable for a non-top frame. Aggregates/arrays/pointers carry a
  `variables_ref` — pass it to `variables` to expand one level."*
- **`variables`** `{ ref:int, start?:int=0, count?:int }` → expand one handle level with an
  explicit array window (T16a — `start`/`count` page an array larger than `MAX_CHILDREN`; a
  struct ignores them). Desc: *"Expand a struct / array / pointer one level via the
  `variables_ref` from `locals`/`backtrace`; for a long array pass `start`/`count` to page. A
  ref from a previous stop is rejected (stale_handle) — re-fetch after stepping."*
- **`inspect`** `{ frame?:int=0, path:string }` → the bounded path read (§4). Desc: *"Read a
  variable by a member/index PATH (e.g. `p.x`, `node->next->value`, `a[2]`). This is NOT a C
  expression evaluator — arithmetic / casts / `&`/`*` / calls return `unsupported`."*
- **`context`** `{ window?:int=5, max_frames?:int=32 }` → R3 (§5). **The source-window radius
  arg is named `window` (T16b)** — not `context`, which collides with the tool name and reads
  as "frames". Desc (dap_mcp/pwno-mcp style): *"One snapshot for the current stop: frame +
  numbered source window (`window` lines each side) + backtrace + top-frame locals. Prefer
  this on every stop instead of separate calls."*
- **(deferred) `evaluate`** — **M-S3**. Document its absence; `inspect` covers path reads now.

Existing `read_cpu` already serves DAP `registers`; `setVariable` is deferred (a deliberate
input op, after read fidelity is proven).

**T16d — `tools/list` must still fit `RESPONSE_BUF`.** The catalog is already ~37.6 KiB; the
five new rows add ~5 KiB, landing ~42-43 KiB inside the 48 KiB `RESPONSE_BUF`
(`server.zig:67`) — tight. The §11 test plan asserts `tools/list` returns 200 and parses
after the additions (the M-S1.5 finding-#11 guard).

---

## 10. Milestone sequencing within M-S2

| Step | Scope | Provable at this step |
|---|---|---|
| **M2-a — the seam** | §1: `DebugJsonBuffer` slab, `DbgJsonResult{body_len}`, `dbgJsonResp`, `submitDebuggerJsonAndRespond`, the `response_too_large`/`not_stopped`/`stale_handle` ErrCodes, the §6 stop-epoch wiring. Drive it with a trivial `dbg_context` stub body. | A nested body crosses the queue as `{body_len}`, copied under `session.lock`, identical HTTP+MCP bytes; an over-cap body → explicit 413; both reflection gates green. |
| **M2-b — backtrace** | §2: `unwind.zig`, `core.Frame`, the BP-chain walk (near/far, prologue/frameless/interrupt/termination), call-site mapping. | `backtrace` stopped in `clamp` shows `clamp → main → (c0_startup)` with correct file:lines and `main`'s line = the CALL site (21). |
| **M2-c — locals + tree** | §3: `vars.zig`, `Scope`/`Variable`, Storage dispatch, type-directed render, the `ExpandTable`/`stop_epoch` handle lifecycle. | `clamp`'s `v`/`lo`/`hi`/`r` read correctly (frame 0); `main`'s `struct Pixel p` expands to `x`/`y`/`color`; `enum Mode m` renders `GRAPHICS`; a stale ref after a step → `stale_handle`. |
| **M2-d — inspect + R3** | §4 bounded `inspect`; §5 `context` assembling a-c. | `inspect p.x` reads the member; `context` returns all four sections; `inspect "p.x+1"` → `unsupported`. |
| **(M-S3, separate)** | the full C-expression `evaluate` parser (§4). | a member/index/deref/cast/arith corpus. |

M2-a first de-risks the new transport contract before any nested producer exists (exactly how
M-S1 built the flat path before M-S1.5 leaned on it).

---

## 11. Test plan

Black-box over the wire on `examples/BB.EXE`, extending `tests/blackbox/debug_test.zig`
patterns (`mcpCall`/`mcpOk`, the `Pc`/`Bp`/`Window` result shapes; add `Frame`/`Variable`/
`Backtrace`/`Scope` shapes mirroring the new serializers). The deterministic goldens come
from `BB.C` + `symbols_integration_test.zig:153-187`.

1. **Backtrace in clamp.** `set_source_breakpoint BB.C:9` → run → `backtrace`: assert
   `frames[0].function=="_clamp"`, `frames[0].line==9`; `frames[1].function=="_main"`,
   `frames[1].line==21` (the **call site** `clamp(300,0,319)`, not the next stmt — proves the
   `addr-1` mapping); `truncated_reason` is `c0_startup` or `no_function` (main was reached
   from the runtime), and **no fabricated frame past it**. `frame_base` non-zero.
2. **clamp's locals (frame 0).** `locals {frame:0}`: assert `v:int == 300` (auto BP+4 via
   peek), `lo:int == BX`, `hi:int == CX`, `r:int == DX` (live registers, `avail:"ok"`) — the
   integration proof's facts, now through `vars.zig` + the seam.
3. **main's aggregate expand + enum name.** `set_function_breakpoint _main` (resolves line
   20) → run → `locals {frame:0}`: `m:enum Mode` after `m = GRAPHICS` renders **`GRAPHICS`**;
   `p:struct Pixel` carries a non-zero `variables_ref`; `variables {ref}` → children `x`, `y`,
   `color` (with `color:unsigned char`), each at the right byte offset.
4. **Stale handle.** Hold the step-3 `variables_ref`, `step_line`, then `variables {ref}` →
   tool error containing `stale_handle` (the epoch bumped). Proves no silent stale read.
5. **Outer-frame register honesty.** At `BB.C:9`, `locals {frame:1}` (main): `p` (auto)
   reads via the outer `frame_base`; any register-stored local of main reports
   `avail:"outer_frame_register"` with no value. (And from a deeper stop, clamp's `lo`/`hi`/`r`
   as an outer frame report `outer_frame_register`.)
6. **No-symbols / frame-less degradation.** At entry (C0, no symbols) `backtrace` →
   `frames[0]` address-only, `truncated_reason` honest; a stripped/`.map`-only image →
   `no_symbols`. (Frame-less is asserted at the unit level with a synthetic non-`55 8B EC`
   prologue → `unreliable`/`frameless_callee`, since BB.EXE is a `-v` build.)
7. **inspect path read.** `inspect {path:"p.x"}` after step 3 == `p.x`'s value;
   `inspect {path:"p.x+1"}` → `unsupported_expression`.
8. **context (R3).** `context` at `BB.C:9` → `frame` clamp:9, `window` lines 4..14 (M-S1.5
   reuse), `backtrace` ≥ 2 frames, `locals` with v/lo/hi/r.
9. **Transport + overflow.** A `dbg_*` while running → `not_stopped`. A synthetic
   over-`DBG_JSON_CAP` body (unit: feed `dbgJsonResp` a builder that overruns) →
   `response_too_large`, never truncated JSON. Concurrent two-query test serializes on
   `session.lock` (no torn body), mirroring the framebuffer-capture test.
10. **Determinism + gates (incl. T18 snapshot-identity).** Run the whole scenario **twice** →
    byte-identical machine state at the stop cycle **and** byte-identical backtrace/locals
    JSON. **Bracket a full `backtrace` + a deep `variables` expansion with `ctrl.snapshot()`
    and assert the bytes are identical before and after** (T18 / CLAUDE.md §1 — proves the
    whole inspection path, not just one read, is side-effect-free). Add `core/unwind.zig` +
    `core/vars.zig` to `src/debug/determinism_test.zig:sources` (grep gate green). Assert
    `expectNoPointerFields(q.Command)` + `(q.Response)` still pass with the new arms
    (`api/determinism_test.zig:155`). Assert `currentCycle()` is unchanged across the
    bracket. **`tools/list` returns 200 and parses** after the five new rows (T16d).

**A second, richer fixture is a small prerequisite task (T17).** BB.C exercises **none** of:
pointer one-level deref + null `<null>` + out-of-slab `unreadable`, a **far-frame pop**
(`bp+4`/`ret_cs`, the per-frame `is_far`/`cur_seg_base` path), `interrupt_boundary`
termination, **array** expand + paging, **bitfield** render, **float-as-hex**, **recursion**
frame identity, and the **T3 fabricated-parent defense**. Add a second `.C` fixture with a
pointer local, an array, a bitfield struct, and a recursive function (and, if a larger memory
model is compiled, a far call) — plus these tests:

11. **Pointer / null / unreadable.** A non-null pointer local expands one level to its
    pointee; a null pointer → child `"<null>"`; a pointer set out of RAM → `avail:"unreadable"`.
12. **Array expand + paging.** An array local expands to `[0]…`; `variables {ref,start,count}`
    pages a slice; the bitfield struct renders each field's extracted value.
13. **Recursion frame identity.** Stop in a recursive call depth ≥ 3 → `backtrace` shows the
    repeated function with **distinct `frame_base`** per level (proves SP-relative identity),
    correct call-site lines, terminating at the C0/no_call_site boundary.
14. **Far-frame pop (if a larger model is built).** A far call → the caller frame's `is_far`
    set and its `pc` resolved through the **far `cur_seg_base`** (T2), not frame-0's `cs_base`.
15. **T3 fabricated-parent defense (UNIT, synthetic).** Feed `unwind` a **synthetic
    garbage-BP stack** (a hand-built SS image whose BP chain is even/in-window/ascending but
    whose "return addresses" are NOT preceded by a CALL) and assert it **does not fabricate** a
    parent — it terminates with `no_call_site` (or flags `unreliable`), never emitting a
    confident wrong frame. This is the headline no-fakes regression guard.

Also extend `src/debug/symbols_integration_test.zig` (in-process, pure) to drive `unwind` +
`renderLocal` directly at the `BB.C:9` stop (frame 0 + the v/lo/hi/r facts, with the T7
high-byte register decode) so the pure core is proven independent of the wire.

---

## 12. Open `TODO(verify):` items

- `TODO(verify):` the exact `Session` field/site to own the `DebugJsonBuffer` and the second
  worker-spawn site in `src/api/session_registry.zig` (the framebuffer-seam agent confirmed
  the `.render`/`.sd` literal but not the registry line — mirror wherever `.render` is set,
  cited as `session_registry.zig:238-251` in `debug-source-inlining-plan §8`).
- `TODO(verify):` the additive `CpuSnapshot.ss_limit` touch (§2.1/§2.2) — confirm
  `cpu.st.seg_limit[ss]` (`cpu/state.zig:119`) is the right real-mode bound to surface (vs. a
  fixed `0x10000` wrap), and that the `controller.zig:166` POD + `cpuSnapshot` (`:1472`) fill
  is the only engine touch. (T14 — outside the §1 seam; the pure `unwind.zig` must read the
  bound off the snapshot, never `ctrl.m.cpu.st`.)
- `TODO(verify):` the **epoch-width** packing (T11) — confirm the chosen `u64` ref
  (`(stop_epoch<<16)|(slot+1)`, 48 epoch bits) stays under 2^53 for the whole session so it is
  exactly representable as a JSON/DAP number, and that no front-end truncates the ref to 32
  bits in transit. (A 48-bit epoch never wraps in practice; a u32 `epoch<<12` would, and then
  fail-closed.)
- `TODO(verify):` `MAX_CHILDREN` per expansion and `DBG_JSON_CAP` sizing against a realistic
  BaK frame (deep struct) — confirm 256 KiB clears the largest single-level expansion with
  margin, else page; and confirm the **MCP incremental-escape stream** (T8) shares that
  ceiling rather than the 48 KiB `resp_buf`/2.
- `TODO(verify):` whether the engine ever reloads SS (the constant-SS assumption, §8) on the
  BaK relink — if a code path switches SS, confirm the BP-window/CALL-site backstops terminate
  rather than mis-read, and document the model coverage (single-SS small..large).
- `TODO(verify):` interrupt-frame detection coverage for the INT 74h / AX=0Ch path (memory
  note *input-injection*) — confirm those handlers carry `FuncClass.interrupt` in their TDS
  type, else fall back to `bp_not_increasing` termination (still honest, never mis-walked).
- `TODO(verify):` that the M-S3 `evaluate` split is acceptable to the DAP `evaluate` request
  contract (clients tolerate an `unsupported` until M-S3; `inspect` covers the watch-path
  common case).
