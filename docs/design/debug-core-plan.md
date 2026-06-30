# Protocol-Neutral Debug Core — Implementation Plan

**Status:** plan (no code). Zig 0.16, for the zdos / "unmaker" deterministic DOS emulator.
Companion to the design (`docs/design/debug-core-architecture.md`) — the analog of
`tds-parser-plan.md` for the parser. The design says *what*; this says *how*, *where*, and *in
what order*, mapped onto the **real, built** Borland TDS symbol layer (`src/debug/symbols/`) and
zdos's existing execution-control substrate.

This plan turns the **now-built, reviewed** pieces —

- the symbol layer `Symbols` / `SymbolIndex` / `AddressMap` / `TypeGraph` (`src/debug/symbols/`,
  153 tests), and
- the live-machine integration proof (`src/debug/symbols_integration_test.zig`) —

into **source-level debugging operations + events** that MCP and (later) DAP frontends sit on,
**without** adding any new engine surface that touches the cycle ledger or `Machine.Snapshot`.

> **Prime directive (CLAUDE.md §1): determinism.** The whole core is **host-side, outside the
> deterministic machine**. It observes and controls; it never alters emulated execution, charges
> no cycles of its own, and never enters the serialized snapshot. The pure source-semantics layer
> lives under `src/debug/` (on the no-atomics/no-clock grep-gate); the async/event/session
> machinery lives in `src/api/` (atomics legal, host *clock* still forbidden).

---

## Table of Contents

0. [Ground truth this plan builds on](#0-ground-truth-this-plan-builds-on)
1. [A. Module layout & placement](#1-a-module-layout--placement)
2. [B. Attach-on-load (the symbol hook)](#2-b-attach-on-load-the-symbol-hook)
3. [C. The protocol-neutral operations (1:1 onto the real API)](#3-c-the-protocol-neutral-operations-11-onto-the-real-api)
4. [D. Variable inspection (generalize the integration proof)](#4-d-variable-inspection-generalize-the-integration-proof)
5. [E. Source-line stepping](#5-e-source-line-stepping)
6. [F. The async event bus + background debug-run owner (the risk)](#6-f-the-async-event-bus--background-debug-run-owner-the-risk)
7. [G. Session & multi-frontend model](#7-g-session--multi-frontend-model)
8. [H. Phasing → milestones](#8-h-phasing--milestones)
9. [I. Testing strategy](#9-i-testing-strategy)
10. [J. Determinism boundary + open questions/risks](#10-j-determinism-boundary--open-questionsrisks)
11. [Appendix: codebase anchors](#11-appendix-codebase-anchors)

---

## 0. Ground truth this plan builds on

The implementer must read these first; this plan cites them by `file:function/line`.

**Symbol layer (BUILT — the only API the core consumes):**

- `src/debug/symbols/symbols.zig` — façade `Symbols`: `open(gpa, exe_bytes, opt_map_bytes) ->
  Symbols` (`:94`, precedence embedded-TDS → `.map` → none), `attach(psp_seg) -> AddressMap`
  (`:144`), `scopeForRuntimeAddr(am, linear) -> ?usize` (`:152`), `deinit` (`:132`). Owns `index:
  SymbolIndex` (always present), `tds: ?*Tds`, `typegraph: ?TypeGraph`.
- `src/debug/symbols/index.zig` — `SymbolIndex`: `addrToLine`/`lineToAddr`/`addrToFunction`/
  `nameToSymbol`/`entryOffsetForFunction`/`functionName`/`symbolName`/`fileId`/`sourceFile`/
  `sourceFileCount`/`module`. Result PODs `FuncRef`/`SymRef`/`LineHit`/`ImageAddr` (integers
  only).
- `src/debug/symbols/map.zig` — `AddressMap` (the **only** `load_para` consumer): `attach`
  (`:31`, `base_para = psp_seg + 0x10`), `toRuntimeLinear` (`:36`), `imageAddrForLinear` (`:44`),
  `runtimeAddrForLine` (`:57`), `lineForRuntimeAddr` (`:63`), `functionForRuntimeAddr` (`:69`),
  `entryAddrForFunction` (`:77`).
- `src/debug/symbols/types.zig` — `TypeGraph`: `typeInfo`/`typeName`/`typeSize`/`members`/`bases`/
  `enumerators`/`localsForScope`/`parentOf`/`scopeForAddr`/`typedefForSymbol`. PODs `TypeInfo`/
  `MemberInfo`/`BaseInfo`/`EnumeratorInfo`/`Local{name_index,type_ref,storage}`/`Storage`
  (`auto:i16` / `register:u8` / `static:{seg,off}` / `constant:i16` / `absolute:u16` / `other`).
- `src/debug/debug.zig:62-68` — re-exports `symbols`, `Symbols`, `SymbolIndex`, `AddressMap`,
  `Tds`.

**The integration proof (BUILT — the loop to extend):** `src/debug/symbols_integration_test.zig`
boots, `m.bootProgram(2,"BB.EXE","")`, reads `psp_seg = m.dos.current_psp`, `Symbols.open(bb_exe)`
→ `attach(psp_seg)`, `runtimeAddrForLine(fileId("BB.C"),9)` → `Controller.addBreakpoint(
.execution_address)` → `runUntilEvent` → `stop == .breakpoint`, then `livePc == seg_base[CS]+%eip`
→ `functionForRuntimeAddr`/`lineForRuntimeAddr`/`scopeForRuntimeAddr` → `localsForScope`, and read
a `.auto = 4` local off `SS:[BP+4]` via `m.bus.readPhys16`. **It needed zero symbol additions.**

**Execution-control substrate (BUILT):**

- `src/debug/controller.zig` — `Controller{ m:*Machine, set:BreakpointSet, last_stop, watch_ids }`.
  `init` (`:460`), `runUntilEvent` (`:480`), `stepInstruction` (`:823`), `stepN` (`:848`),
  `stepOver` (`:1035`, SP-guarded), `runToAddress` (`:888`), `runToCycle` (`:866`),
  `beginRunToAddress`/`runTargetBurst`/`endRunTarget` (`:948/:960/:969`), `addBreakpoint` (`:634`),
  `removeBreakpoint` (`:671`), `rearmWatches` (`:775`), `cpuSnapshot` (`:1472`), `peekMem` (`:1536`),
  `peekMemPhys` (`:1519`), `peekStack` (`:1977`), `disasmWindow` (`:1698`), `setReg*`/`setSegment`/
  `setEip`/`writeMem`/`writeMemPhys` (`:1141-1165`), `status` (`:1993`), `console` (`:1774`),
  `currentCycle` (`:984`), `recordExternalStop` (`:977`). `StopReason` union (`:81`,
  `breakpoint{id,at_cycle,watch}` / `step_complete` / `target_reached` / `program_terminated{ret}`
  / `shutdown` / `halted_forever` / `cycle_budget_exhausted` / `no_progress` / `stopped_by_request`).
  `StepOverResult{reason, stepped_into}` (`:144`).
- `src/debug/breakpoints.zig` — `BreakpointKind.execution_address{linear:u32}` (`:30`),
  `BreakpointSet` (MAX 64, POD, snapshot-safe), `currentLinear(m) = seg_base[CS]+%EIP` (`:212`).
- `src/api/worker.zig` — `Worker{queue, ctrl, mount_dir, io, render, live_mouse, snapshots,
  run_ctl}`; loop `run` (`:748`) = `waitDequeue → drainOne → complete → publishStatus`; `drainOne`
  (`:113`, one `q.Command` → one Controller method → one `q.Response`); `runCapPreemptible`
  (`:292`, burst loop polling `preemptRequested`); `loadResp` (`:655`, calls `ctrl.m.boot`);
  `restoreResp` (`:692`, calls `rearmWatches`).
- `src/api/run_control.zig` — `RunControl` (atomics + one `Io.Mutex arb`); `RunOwner{idle, paced,
  debugger}` (`:31`); `beginDebugger`/`endDebugger` (`:230/:241`); `beginPreempt`/`endPreempt`/
  `preemptRequested` (`:270/:277/:284`); `publishStatus`/`publishedCycle` (`:290/:295`);
  `recordStop`/`lastStop` (`:303/:308`).
- `src/api/session.zig` — `Session` (`:201`): `ctrl:*Controller`, `queue`, `worker_thread`,
  `run_control:*RunControl`, `render`, `snapshots`, `recipe:LoadRecipe`, `mount_dir`, `lock`.
  `LoadRecipe` (`:145`, the host-side-config-re-applied-on-load precedent). `Session.init` (`:315`).
- `src/dos/loader.zig` — `load_seg = psp_seg + 16` (`:195`), `dos.current_psp = psp_seg` (`:206`).
  `src/machine/machine.zig` — `bootProgram` (`:560`), `boot` (`:583`). `dos.current_psp` lives at
  `src/dos/dos.zig:126`.
- `src/api/mcp_tools.zig` — `Tool{name, description, input_schema, per_machine}` (`:47`); catalog
  `tools` (`:74-388`, 35 tools); `buildCommand` maps a tool → `q.Command`; server-specials
  (`load`, `screenshot`, `provision_*`) live in `server.zig:handleMcpToolCall`.
- `src/debug/determinism_test.zig` — the grep-gate `sources` list (`:12-28`) + reflection gate
  (`:67-90`). New `src/debug/core/*.zig` files **must** be added here.

---

## 1. A. Module layout & placement

Respect the existing graph: `src/debug` is pure + synchronous + atomics-free (a determinism
grep-gate); `src/api` is threaded + atomics-legal (host clock still forbidden). The neutral core
**type definitions** and **pure semantics** go in `src/debug/core/`; the **async/event/session**
machinery extends `src/api`.

```
src/debug/core/                 (NEW — pure, synchronous, on the determinism gate)
  core.zig        ── module root: re-exports + the protocol-neutral DTOs (§3.1): Addr, SourceLoc,
                     PcLocation, BreakpointSpec/Request/ResolvedBreakpoint, Frame, Scope, Variable,
                     StopKind, StopState, Event/EventKind. NO DAP/MCP type here.
  debugger.zig    ── SourceDebugger: the core object. Holds `ctrl: *Controller`, `syms: ?Symbols`,
                     `map: ?AddressMap`, and a fixed `specs: [64]BpSpecSlot` (spec↔ctrl-bp-id).
                     Implements: attachOnLoad / onMachineReverted; pcLocation; setBreakpoint /
                     clearBreakpoint / reresolve; stepLine/stepIn/stepOut/runToLine; stackTrace;
                     scopes; variables; setVariable. Pure + synchronous — runs ON the worker thread.
  vars.zig        ── Tier-2: render a `Local` → `Variable` (typeName + storage read). Imports
                     TypeGraph + Controller peek path.
  unwind.zig      ── Tier-3: BP-chain frame unwinding (near/far per calling convention).
  core_test.zig / stepping_test.zig / vars_test.zig  ── unit + harness tests (§9).

src/api/                        (extend — threaded, atomics legal, no host clock)
  event_bus.zig   ── NEW: clockless broadcast of Event PODs to attached frontends (M-S4).
  run_control.zig ── extend: reuse RunOwner.debugger; add the background debug-run arming (M-S4).
  debug_runner.zig── NEW (M-S4): the background debug-run driver thread (the pacer analog).
  worker.zig      ── extend drainOne: route new source q.Commands to SourceDebugger; attach hook
                     in loadResp; onMachineReverted in restoreResp.
  queue.zig       ── extend q.Command / q.Response with the source-debug variants (§3.3).
  mcp_tools.zig   ── append source-level tool rows + buildCommand arms (§3.3, §8).
  dap.zig         ── NEW (M-DAP): the DAP codec (sibling of mcp.zig), attaches to event_bus.
```

**Why `SourceDebugger` is a discrete object (not methods on `Controller`).** It needs both the
host-side symbol overlay (re-attached on load, like `LoadRecipe`) **and** a `*Controller`. Keeping
it separate (a) leaves `Controller` minimal and snapshot-clean, (b) puts all symbol-aware logic on
the pure `src/debug/core` side of the gate, and (c) mirrors how `Controller` itself is a
synchronous object the worker owns. The `Session` owns one `SourceDebugger` (like it owns the
`Controller`); the `Worker` gets a `?*SourceDebugger` field and calls it inside `drainOne` — so
every source op runs on the **single machine-owning thread**, exactly like every existing inspect
command. **No second path to the machine is introduced.**

**Gate wiring.** Add `core/core.zig`, `core/debugger.zig`, `core/vars.zig`, `core/unwind.zig` to
`src/debug/determinism_test.zig`'s `sources` embed list (`:12-28`) and register them in
`src/debug/debug.zig`'s `test {}` block. This puts the core on the **grep gate** (no
`std.time`/`std.Random`/`std.Thread`/`std.atomic`/`std.Io.Mutex`/`f32`/`f64`/`HashMap` — see
`determinism_test.zig:29-56`): the pure semantics may not poll atomics or import `src/api`
(this is the boundary Finding-1, §5, enforces).

**Reflection-gate scope (corrected — review Finding 3).** Two distinct reflection gates exist and
must not be conflated. **(a)** `src/debug/determinism_test.zig` (`expectNoPointerFields`, the
*symbol-POD* gate) recurses into *every* field and rejects **any** slice (`[]T` is a `.pointer`);
it admits no per-field "borrowed" exception. The **integer-only symbol PODs** (`SymRef`/`FuncRef`/
`LineHit`/`ImageAddr`/`TypeInfo`/`MemberInfo`/`Local`/`Storage`) already pass it and **stay on it**
— they can enter `Machine.Snapshot`-adjacent paths. The **neutral DTOs** of §3.1 (`SourceLoc`,
`PcLocation`, `Variable`, …) carry resolved `[]const u8` views (paths, names, rendered text), so
they **cannot** pass it and are **deliberately EXCLUDED** from that gate. They are covered by the
**grep gate only** (no host time/RNG/thread/atomic), like every other `src/debug/core` source.

**(b)** `src/api/determinism_test.zig:155` runs the **same** `expectNoPointerFields` over
**`q.Command`/`q.Response`** — and **that gate stays unchanged; do NOT loosen it.** Its invariant
is *not* aesthetic: **no field of a `q.Response` may borrow memory whose contents or lifetime
aren't guaranteed past the Stopped epoch.** Serialization runs on the **listener** thread *after*
`submit()` returns (`queue.zig:555`; `complete()` `:593` copies the POD and signals, then the
worker **immediately** loops back to `waitDequeue` in its `while(true)` run loop,
`worker.zig:753-760`) — so by the time a
`writeX` serializer runs (e.g. `writeDisasm`, `server.zig:2997`, on `Conn`) the worker may already
have executed the **next** command: advancing guest RAM (`run`/`step`) or freeing+rebuilding the
symbol arena (`load`/`reset` → `attachOnLoad` → `old.deinit()`, §2.2). A borrowed slice on a
`q.Response` is therefore **both** a *read-after-resume race* **and** *non-deterministic output*.
The §3.1 neutral DTOs are thus **never placed in a `q.Response` as live slices**; they are
worker-internal render targets. What crosses `q.Response` is only a **flat pointer-free POD** (flat
results) or a **length-tagged owned-body descriptor** (nested results) — the two transports of
§3.1a. The fix is to route *around* the gate with owned bytes, never to relax it.

**Allocator ownership.** The `SourceDebugger` (and the `Symbols` overlay it owns) is allocated
from the **`Session`'s `gpa`** in `Session.init` (`session.zig:315`, which already receives `gpa`)
and freed in `Session.deinit`. Its lifetime is the Session's; the *symbol overlay inside it*
(`syms`/`map`) has the **shorter** lifetime of the currently-loaded program — `attachOnLoad`
(§2.2) frees the prior overlay and rebuilds it on each `load`/`reset+load`. No DTO outlives the
Stopped epoch that produced it (§7 stale-ref stamping).

---

## 2. B. Attach-on-load (the symbol hook)

The symbol overlay is **host-side config re-attached on load**, exactly like `LoadRecipe`
(`session.zig:145`) and the bus-watch re-sync (`rearmWatches`). It is **never** in
`Machine.Snapshot`.

### 2.1 The hook point

In `worker.zig:loadResp` (`:655`), after `ctrl.m.boot(...)` succeeds (`:659`) and before clearing
`last_stop` (`:664`), call the attach:

```
fn loadResp(ctrl, sd: ?*SourceDebugger, c: q.LoadCmd, mount: MountSource) Response {
    ctrl.m.boot(c.drive, dir, io, file, cmdtail) catch return .{ .err = .load_failed };
    if (sd) |s| {
        // read the just-loaded EXE bytes back from the host mount (same dir/io boot used)
        const exe = readHostFile(mount.dir, mount.io, file) catch null;   // host I/O, load-time only
        const opt_map = readHostFile(mount.dir, mount.io, sameStem(file, ".MAP")) catch null;
        s.attachOnLoad(exe, opt_map, ctrl.m.dos.current_psp);             // §2.2
    }
    ctrl.last_stop = null;
    return .ok;
}
```

`mount.dir`/`mount.io` are already in hand (the worker uses them to mount C: in `boot`). Reading
the EXE bytes a second time, host-side, at load time, is determinism-safe (load is **not** the
per-cycle path; CLAUDE.md §1 governs *emulated* time). An OOM / unreadable file ⇒ `syms = none`,
never a panic.

**Threading work this implies (do not understate it).** The current signature is
`loadResp(ctrl, c, mount)` (`worker.zig:655`) — it has **no** `SourceDebugger`. This plan
**threads a new `?*SourceDebugger` parameter** through `drainOne` (`worker.zig:113`) and down into
`loadResp` (and `restoreResp` `:692`, for `onMachineReverted`). `drainOne`'s own signature gains
the `sd` argument alongside its existing `ctrl`/`mount`/`render`/`run_ctl` params, and `worker.run`
passes the worker's `?*SourceDebugger` field. **`readHostFile(dir, io, name)` and
`sameStem(file, ".MAP")` are NEW helper code to be written** (in `worker.zig` or a small
`core`-adjacent helper) — they do **not** exist today. `readHostFile` is a host-side, load-time
file read over the same `Io.Dir`/`Io` the mount uses; `sameStem` swaps an 8.3 extension. Both are
load-path only (never per-cycle), so they are determinism-safe.

### 2.2 `SourceDebugger.attachOnLoad`

```
pub fn attachOnLoad(self: *SourceDebugger, exe: ?[]const u8, opt_map: ?[]const u8, psp_seg: u16) void {
    if (self.syms) |*old| old.deinit();                 // free the prior overlay (reload)
    self.syms = if (exe) |b| Symbols.open(self.gpa, b, opt_map) catch null else null;
    self.map  = if (self.syms) |*s| s.attach(psp_seg) else null;   // base_para = psp_seg + 0x10
    self.reresolveBreakpoints();                        // recompute every spec's linear (§3.3)
    // emit module_loaded{ symbols = self.syms != null and .source != .none } on the bus (M-S4)
}
```

- `Symbols.open` is **pure** (a function of the EXE bytes); the only machine read is `psp_seg`,
  passed to `attach`. This is the seam the integration proof validated byte-for-byte.
- **Reset / reload** (`worker.zig` `reset` `:225`, `load`) re-run the hook with the new `psp_seg`.
- **Restore** (`worker.zig:restoreResp` `:692`): `load_para` is unchanged (same load), so neither
  `Symbols` nor `AddressMap` rebuilds. Add `sd.onMachineReverted()` next to `rearmWatches`
  (`:696`) — it only invalidates the live frame/variable caches (valid only while stopped). No
  reparse, no guest effect.

### 2.3 Where the `Symbols` is stored

The `Session` owns the `SourceDebugger` (heap, stable address) alongside `ctrl`, created in
`Session.init` (`:315`), `deinit`'d with the session. The `Worker` holds `?*SourceDebugger`. The
overlay's lifetime = the loaded program, freed/rebuilt by `attachOnLoad`. `AddressMap` borrows
`&syms.index`, so `syms` must stay at a stable address while `map` is live — guaranteed by the
heap `Symbols` field (the façade's own contract, `symbols.zig:74-78`).

---

## 3. C. The protocol-neutral operations (1:1 onto the real API)

### 3.1 The neutral DTOs

Keep the design §4 types (`Addr`, `SourceLoc`, `PcLocation`, `BreakpointSpec`/`Request`/
`ResolvedBreakpoint`, `Frame`, `Scope`, `Variable`, `StopKind`, `StopState`, `Event`) **as-is** in
`core/core.zig` — they are already protocol-neutral and DAP/MCP map onto them. They are produced
*from* the symbol PODs but are not the same types (the symbol PODs carry `name_index`/`type_ref`
integers; the DTOs carry resolved `[]const u8`/rendered text). `SourceLoc.path` borrows
`SymbolIndex.sourceFile(file_id)`; `PcLocation.function` borrows `functionName`.

These borrows are **worker-side and Stopped-epoch-scoped only**: a DTO is consumed by the worker's
own *flatten* or *serialize* step (§3.1a) **before** the `q.Response` crosses to the listener — it
is **never** the wire payload. That is what keeps the borrow from outliving the worker turn (cf.
`attachOnLoad` freeing the symbol arena on the next `load`/`reset`, §2.2, which would otherwise turn
a "stable" name-pool slice into a use-after-free once the listener serialized it).

### 3.1a Crossing the queue: two transport categories (flat-flatten vs nested-serialize-on-worker)

Because the §3.1 DTOs cannot ride `q.Response` as slices (§1, the read-after-resume race), debug
results split into **two categories with two transports** — exactly the split the existing inspect
path already runs between flat PODs (`DisasmResult`) and large variable-length payloads (the
framebuffer):

**Category A — flat, tightly-bounded results → flatten into a pointer-free POD on `q.Response`.**
`where`/`pcLocation`, breakpoint-set confirmations, and `registers` are *bounded*: a DOS symbol
name and a ≤255-char DOS source path are genuinely fixed-cap. These follow the
**`DisasmResult`/`DisasmInsn` flatten pattern** (the pointer-free `disasm: debug.DisasmResult`
`q.Response` variant, `queue.zig:478`; serialized off-worker by `writeDisasm`, `server.zig:2997`):
the worker copies names/paths into **fixed inline byte buffers**
plus integer line/addr fields, so the `q.Response` variant is a by-value POD that **passes
`expectNoPointerFields(q.Response)`**. The listener's `writeX` serializer reads only owned-by-value
bytes — no borrow, no race. **The MVP needs nothing beyond this** (§8).

**Category B — nested / variable-length results → serialize to JSON on the WORKER.** A backtrace is
N frames; `scopes` is a variable-count set; `locals` is N variables each with name+type+rendered
value; and the recursive variable/struct/array **tree** has unbounded shape. Forcing these through
fixed-cap PODs would require inventing arbitrary `MAX_FRAMES`/`MAX_DEPTH`/`MAX_MEMBERS`/
`MAX_VALUE_LEN` caps and **silently truncating** a struct's rendered value — a fake, forbidden by
CLAUDE.md §2. Instead they **generalize the framebuffer seam**
(`submitAndRespondFramebuffer`, `server.zig:2631-2721` + `FramebufferResult`, `queue.zig:410` + the
off-Command `*RenderBuffers`, `worker.zig:61-84`): the worker serializes the result to **JSON text**
into a **session-owned bounded body buffer** (reached off-Command, mirroring `RenderBuffers`, **not**
carried in the pointer-free Command); the `q.Response` carries only a `{ body_len }` descriptor; the
listener copies/streams those owned bytes **under `session.lock`**, then unlocks and writes the
socket — byte-for-byte the framebuffer pattern, generalized from binary pixels to JSON text. **A
length is not a pointer**, so the descriptor passes the gate, and routing the *bytes* (not a slice)
is strictly safer than any slice-crossing scheme: immune to both the read-after-resume race **and**
the `load`/`reset`-frees-the-symbol-arena use-after-free.

Both the HTTP and MCP front-ends already wrap **identical body bytes** (MCP embeds the same JSON the
HTTP route returns), so emitting the final body on the worker causes **no drift** between frontends
— it *removes* a drift risk, since the bytes are produced once, deterministically, at the Stopped
epoch.

**Determinism rationale (the true invariant).** Moving Category-B serialization onto the worker is
precisely CLAUDE.md §1: the body is produced **while the machine is parked at the Stopped epoch**,
from the same registers/RAM/symbol-arena the stop observed. A listener-side serializer would read
that state *after* the worker resumed — a different, non-reproducible machine. Worker-side emission
makes the rendered output a **pure function of the stop cycle**.

**Two explicit risks this introduces:**

1. **The worker now builds JSON strings for the nested ops.** It stays **pure/clockless** — no host
   time, no RNG (it remains inside the `src/api` grep gate) — but the per-op body buffer is
   **bounded**, and an overflow **MUST** be an *explicit* error (a 503 / "response too large", the
   existing `writeScreen`-overflow precedent at `server.zig:2989`), **never** a silent truncation
   (CLAUDE.md §2).
2. **The session-owned debug body buffer is shared session state.** Concurrent debug queries on one
   session **must serialize on `session.lock`** for the copy window, exactly as concurrent
   framebuffer captures already do (the CAPTURE-span contract, `server.zig:2632`).

**Result-type categorization (which transport each result uses):**

| Debug result | Transport | Why |
|---|---|---|
| `pcLocation` / `where` | **flat-flatten** | one function name + one ≤255-char path + integer line/addr — bounded |
| breakpoint-set confirm (`ResolvedBreakpoint`) | **flat-flatten** | id + resolved `Addr` + one path/line — bounded |
| `listBreakpoints` | **flat-flatten** | ≤ `MAX_BREAKPOINTS` (64) bounded rows |
| `registers` | **flat-flatten** | reuses the existing pointer-free `CpuSnapshot` POD |
| `backtrace` / `stackTrace` | **nested-serialize-on-worker** | N frames, each name+path+line |
| `scopes` | **nested-serialize-on-worker** | variable-count scope set |
| `locals` / `variables` | **nested-serialize-on-worker** | N vars × (name+type+rendered value) |
| variable/struct/array **tree** (`children_ref` expansion) | **nested-serialize-on-worker** | recursive, unbounded depth/width |
| `setVariable` / `evaluate` result | **nested-serialize-on-worker** | echoes a (possibly aggregate) rendered `Variable` |

First milestone that needs the **nested-serialize-on-worker** seam: **M-S2** (`scopes`/`locals`/
`variables`); **M-S1** uses **flat-flatten only** (§8).

### 3.2 The master mapping (every op → symbol API + controller)

| Core op | Symbol API call(s) | Controller call(s) |
|---|---|---|
| **`pcLocation`** | `AddressMap.functionForRuntimeAddr(pc)` + `functionName`; `lineForRuntimeAddr(pc)` → `SourceLoc{line, sourceFile(file_id)}` | `cpuSnapshot` (CS:IP → `pc = seg_base[CS]+%EIP`, the `currentLinear` formula) |
| **`setBreakpoint{source}`** | `SymbolIndex.fileId(file)` → `AddressMap.runtimeAddrForLine(file_id,line)` | `addBreakpoint(.{.execution_address={.linear=…}}, false)` |
| **`setBreakpoint{function}`** | `nameToSymbol(name)` → `addrToFunction(seg,off)` → `entryAddrForFunction(f)` (post-prologue) | `addBreakpoint(.execution_address)` |
| **`setBreakpoint{addr}`** | — | `addBreakpoint(.execution_address)` |
| **`clearBreakpoint`** / **`clearBreakpointsForSource`** | (spec table filter) | `removeBreakpoint(id)` |
| **`listBreakpoints`** | — | `forEachBreakpoint` (over the spec table) |
| **`stepInstruction`** | — | `stepInstruction` |
| **`stepLine`** (next) | `lineForRuntimeAddr` (loop) | `stepOver` (loop, SP-guarded) — §5.2 |
| **`stepIn`** | `lineForRuntimeAddr` + `functionForRuntimeAddr` (loop) | `stepInstruction` (loop) — §5.3 |
| **`stepOut`** | far/near from `typeInfo(SymbolIndex.typeRefForFunction(fn).?).?.function.far` (NEW accessor — see below) | `peekStack`/`peekMem` + one-shot `addBreakpoint` + `runUntilEvent` — §5.4 |
| **`runToLine`** | `fileId` + `runtimeAddrForLine` | `runToAddress(linear)` — §5.5 |
| **`stackTrace`** | `functionForRuntimeAddr`, `lineForRuntimeAddr` per frame | `cpuSnapshot`, `peekMem`/`peekStack` (BP chain) — Tier 3 |
| **`scopes`** | `scopeForRuntimeAddr(am, pc)` + climb `parentOf` | — |
| **`variables`** | `localsForScope` → `typeName`/`typeInfo`/`members` | `cpuSnapshot`, `peekMem`, `peekMemPhys` — §4 |
| **`setVariable`** | `localsForScope` → `Storage` | `writeMem`/`writeMemPhys`/`setReg*` — §4 |
| **`registers`** | — | `cpuSnapshot` (reuse `debug.CpuSnapshot`) |
| **`readMemory`/`writeMemory`** | — | `peekMem`/`writeMem` |
| **`stopState`** | resolve `pcLocation` from `last_stop` PC | `status` / `last_stop` + `cpuSnapshot` |

**`StopReason` → `StopKind`** projection is the design §4.6 table, computed in **one** place
(`SourceDebugger.projectStop`): the only spot the raw `Controller.StopReason` union is read.
`breakpoint{id}` → `.breakpoint` unless `id` is the core's own one-shot (then `.step`);
`program_terminated{ret}` → `.exit{exit_code=ret}`; `stopped_by_request` → `.pause`; etc.

**NEW symbol-layer accessor required — `SymbolIndex.typeRefForFunction` (review Finding 4).**
`stepOut` (§5.4) needs the *current* function's return type to choose a near vs far return.
But the live-PC path yields a **`FuncRef`** (from `AddressMap.functionForRuntimeAddr`), and
`FuncRef` (`index.zig:36`) carries `{sym_index, segment, start, end, name_index}` — it has **no
`type_index`** (only `SymRef`, from `nameToSymbol`, carries `type_index`). The function's type
ref therefore cannot be reached from a `FuncRef` today. Add a thin accessor:

```
/// The 1-based type-ref of the function symbol behind `f` (its `Tds.symbols[sym_index-1].type`),
/// for far/near-return resolution. Null for a `.map`-backed index (no Tds / no symbol type).
pub fn typeRefForFunction(self: *const SymbolIndex, f: FuncRef) ?u16
```

It returns a **`?u16` type-ref** (the same `type_ref` `TypeGraph.typeInfo(type_ref)` consumes; it
is `u16` throughout `types.zig`), resolving through `self.tds.?.symbols[f.sym_index - 1].type` and
returning `null` when `tds == null` or `sym_index` is out of range. This is **the one symbol-layer
addition** this whole plan needs (reconcile §10's "no additions" claim accordingly). It is pure,
integer-only, and stays on both gates.

**Inspection ops are GATED on the Stopped state (review item).** `pcLocation`, `stackTrace`,
`scopes`, `variables`, `setVariable`, `registers`, `readMemory`, and `setVariable` read **live**
BP/SP/registers that are only meaningful at a clean instruction boundary. The core **must reject**
them with a clean `Error` (not a fabricated frame) whenever the `SourceDebugger` is **not** in the
Stopped state (design §5.1: frames/scopes/vars valid *only* in Stopped). The worker already
guarantees it is idle between commands; the explicit gate guards against a query racing a
background debug-run (M-S4) — it returns "not stopped" rather than peeking a mid-burst machine.

### 3.3 Plumbing into `q.Command` / MCP

Each op that touches the machine becomes a `q.Command` variant handled in `worker.zig:drainOne`
by delegating to the `?*SourceDebugger` (pure ops like breakpoint resolution can run there too,
since the spec table is on the worker side). New variants (names): `dbg_where` (pcLocation),
`dbg_set_src_bp`/`dbg_set_fn_bp`, `dbg_step_line`/`dbg_step_in`/`dbg_step_out`/`dbg_run_to_line`,
`dbg_backtrace`, `dbg_scopes`, `dbg_variables`, `dbg_set_var`. **Responses do NOT carry the
slice-bearing neutral DTOs** (they cannot cross `expectNoPointerFields(q.Response)`, §1/§3.1a): the
**flat** ops (`dbg_where`, the `dbg_set_*_bp`/`list` confirmations) return a **pointer-free
flattened POD** (the `DisasmResult` pattern, serialized off-worker by a `writeX`); the **nested**
ops (`dbg_backtrace`/`dbg_scopes`/`dbg_variables`/`dbg_set_var`) return a `{ body_len }` descriptor
over a **worker-serialized, session-owned JSON body** (the framebuffer pattern, §3.1a). The neutral
DTOs of §3.1 are the worker-side render targets that *feed* both — never the wire payload.

New MCP tool rows (append to `mcp_tools.zig:tools` + a `buildCommand` arm): `whereami`,
`set_source_breakpoint{file,line}`, `set_function_breakpoint{name}`, `step_line`, `step_in`,
`step_out`, `run_to_line{file,line}`, `backtrace`, `locals{frame}`, `eval{expr,frame}` (stub). The
existing `add_breakpoint`/`run`/`step`/`read_cpu`/`status` already cover the instruction layer.

---

## 4. D. Variable inspection (generalize the integration proof)

The proof's §5–6 *is* the algorithm; generalize its hardcoded `.auto = 4 → SS:[BP+4]` read into a
`Storage`-driven dispatch. `vars.zig:renderLocal(local, frame) -> Variable`:

1. **`scopes`** ← `Symbols.scopeForRuntimeAddr(map, pc)` (`symbols.zig:152`) for the innermost
   scope, then climb `TypeGraph.parentOf` (`types.zig:476`) to gather all visible locals (one
   `Scope` per `ScopeKind`: `.locals`/`.arguments` split by sign of `Storage.auto`, plus
   `.registers`).
2. **`type_name`** ← `TypeGraph.typeName(local.type_ref, &writer)` (`types.zig:423`).
3. **value + `addr`** ← dispatch on `local.storage` (`Storage`, `types.zig:146`), reading via the
   **side-effect-free peek path** (charges zero cycles, leaves `snapshot()` byte-identical):

   | `Storage` | read |
   |---|---|
   | `.auto = off` (i16) | `addr.linear = ss_base +% (BP + off)`; `Controller.peekMem(.ss, BP+off, dst)`. *(proof: `v` at `+4` == 300)* |
   | `.register = n` (u8) | live register from `Controller.cpuSnapshot` (map `format.Reg`: CX=1, DX=2, BX=3, SI=6, …). *(proof: `lo`/`hi`/`r`)* |
   | `.static = {seg,off}` | global: `AddressMap.toRuntimeLinear(seg, off)`; `Controller.peekMemPhys` |
   | `.constant = c` / `.absolute = a` | rendered directly, `writable=false`, no bus read |
   | `.other` | rendered as raw; not writable |

4. **typed rendering by `typeInfo`** (`types.zig:338`): `.primitive` → format per size/signedness;
   `.pointer` → hex `seg:off` (+ `children_ref` to deref the pointee); `.array` → `count`
   elements (`children_ref`); `.aggregate` → walk `members` (`types.zig:396`, each `MemberInfo`
   has `byte_offset`) under `children_ref`; `.enumeration` → match `enumerators` value → name.
   `children_ref` is a host-side handle stamped with the current `stop_epoch` (design §6.2); a
   stale ref after a step is rejected cleanly.

   **Floats render as raw hex bytes ONLY — never host float formatting.** The Borland primitive
   set includes `.float`/`.double`/`.ldouble`/`.tpreal` (`types.zig:342`), but (a) zdos has **no
   x87** (memory note *no-FPU-constraint*) and (b) the core lives on the grep gate that **forbids
   `f32`/`f64` outright** (`determinism_test.zig:37-40`). So a floating-point local's `value_text`
   is the variable's storage rendered as a fixed-width **hex byte string** (e.g. `0x00 00 80 3F`
   for the 4 bytes of a `float`), exactly the determinism-safe path the rest of the inspector uses
   — no host `std.fmt` float conversion, which would be both a gate violation and a potential
   host-rounding nondeterminism. The type name (`"float"`/`"double"`) still renders normally.

5. **`setVariable`** inverts step 3: `.auto`→`Controller.writeMem(.ss,…)`, `.register`→`setReg*`,
   `.static`→`writeMemPhys`. A deliberate, recorded new input (CLAUDE.md §1 "same binary + SAME
   inputs"). `.constant`/`.absolute` reject (`writable=false`).

**Tier note:** §4 is **Tier 2**. The proof already exercised the read path end-to-end, so this is
generalization, not new ground.

---

## 5. E. Source-line stepping

All four kinds are host-side loops over `Controller` primitives + the line table, per design §7.
The "current line" key is the live linear PC; `lineForRuntimeAddr` does the interval lookup.

**Worker owns the run/preempt loop; the pure core owns only the line predicate (review Finding
1).** `src/debug/core/debugger.zig` is on the determinism grep gate, so it may **not** call
`run_ctl.preemptRequested()` (an atomic) and may **not** import `src/api`. Polling preempt from
inside the gated pure module would be a boundary violation. A step is therefore split exactly the
way `runCapPreemptible` / `runToTargetPreemptible` (`worker.zig:292` / `:312`) already split a run:

- **Pure core (`debugger.zig`, on the gate):** a *bounded* burst
  `stepLineBurst(budget_cycles) -> StepOutcome` (and `stepInBurst` / `stepOutBurst`). It loops
  `ctrl.stepOver()` / `ctrl.stepInstruction()` + the line predicate (`lineForRuntimeAddr` + the SP
  test) until it either (a) satisfies the next-line stop predicate → `.stopped(StopState)`, (b)
  hits a terminal / user-breakpoint `StopReason` → `.stopped(…)`, or (c) spends `budget_cycles`
  (measured as a `ctrl.currentCycle()` delta) with no qualifying line change → `.budget_exhausted`.
  **No atomics, no preempt poll, no `src/api` import.** Deciding "should I stop here?" (a new source
  line at the same-or-outer frame) is the *only* thing the pure core owns.
- **Worker (`drainOne`, `src/api`, atomics legal):** a preemptible loop — the
  `runToTargetPreemptible` analog — that calls `sd.stepLineBurst(STEP_BURST_CYCLES)` repeatedly,
  polling `run_ctl.preemptRequested()` **between** bursts (so a `pause` / `reset` / new-breakpoint
  from another frontend lands at a burst boundary as `stopped_by_request`), under an **anti-wedge
  total cap** `STEP_WEDGE_CAP_CYCLES`: once the cumulative stepped cycles reach the cap with no line
  change (a tight no-line loop), the worker stops and the core reports `.step` with a "budget
  reached" note — never an infinite host loop.

**The per-step cycle budget is a FIXED, compile-time, deterministic constant — never
host-derived.** `STEP_BURST_CYCLES` (the per-burst preempt granularity; placeholder
`= PREEMPT_BURST_CYCLES`, the existing worker constant) and `STEP_WEDGE_CAP_CYCLES` (the anti-wedge
ceiling; placeholder `= 8_000_000`) are `const` in `worker.zig`. They **must** be compile-time
constants of the *cycle counter* — never derived from a host clock, wall time, thread state, or
env — so the same binary + inputs takes byte-identical stop decisions every run (CLAUDE.md §1).
Slicing a step into bursts is byte-identical to one unbounded loop: the bursts change only *where
preemption is evaluated*, never the retired instruction stream (the exact property
`runCapPreemptible` already proves).

### 5.2 `stepLine` (next — step over calls)

```
start = lineForRuntimeAddr(pc);  start_sp = SP
loop (budget):
    res = ctrl.stepOver()                       // skips callee bodies, SP-guarded (:1035)
    if terminal/user-bp(res.reason): return projectStop(res.reason)
    cur = lineForRuntimeAddr(pc)
    if cur != null and cur != start and SP >= start_sp: return .step   // same/shallower frame
    if SP > start_sp and cur != null:            return .step          // returned to caller
```

### 5.3 `stepIn` (descend into a callee's first line)

```
start = lineForRuntimeAddr(pc);  start_sp = SP   // capture the frame anchor up front
loop (budget):
    res = ctrl.stepInstruction()                 // plain step — enters calls (:823)
    if terminal/user-bp: return projectStop
    cur = lineForRuntimeAddr(pc)
    if cur != null and cur != start:
        if functionForRuntimeAddr(pc) != null: return .step   // entered a symbolized fn
        else: continue as stepLine(start_sp)      // no-symbol callee (C0/libc): run back out,
                                                  //   carrying the ORIGINAL start_sp anchor
```

Guard: a callee with no debug info must not trap the user — `functionForRuntimeAddr == null` ⇒
degrade to `stepLine`, reported, never silent. **The fallback must preserve the original
`start_sp`** (captured before the first `stepInstruction`, *not* re-sampled inside the unsymbolized
callee where `SP` is already deeper): `stepLine`'s "same-or-shallower frame" test (§5.2) is
relative to that anchor, so reusing the caller's `start_sp` is what lets the fallback run *back out*
to the next line in the original frame instead of losing the frame and stopping one instruction in.

### 5.4 `stepOut` (run to the caller's return)

```
fn      = functionForRuntimeAddr(pc)                       // FuncRef (no type_index!)
type_ref = SymbolIndex.typeRefForFunction(fn)              // NEW accessor (§3.2); ?u16
far     = if (type_ref) |t| typeInfo(t).?.function.far else false   // null/.map ⇒ assume near
ret_linear = far ? farRet(BP) : nearRet(BP)      // [SS:BP+2] (near) / CS:IP from [BP+2],[BP+4] (far)
guard_sp   = BP + (far ? 4 : 2)                  // SP after this frame tears down
id = ctrl.addBreakpoint(.{.execution_address={.linear=ret_linear}}, one_shot=true)
loop: r = ctrl.runUntilEvent(burst); if hit-at-id and SP >= guard_sp: return .step
```

Reads use `peekStack`/`peekMem`. Far-ness comes from the function's TDS type via the **NEW**
`SymbolIndex.typeRefForFunction(fn)` accessor (§3.2) → `TypeGraph.typeInfo(type_ref).function.far`
(`types.zig:374`, the `.func`/`.specialfunc` → `.function{ret, far, conv}` arm) — **not** from the
`FuncRef` directly, which carries no `type_index`. A `.map`-backed image (no TDS type) ⇒ assume
near (small-model default), reported. BB.EXE is small-model (all near). **Caveat (design risk 3):**
without BP frames (optimized `-O` builds) unwinding past the innermost frame is unreliable —
report the limitation, do not fabricate.

### 5.5 `runToLine`

`fileId(file)` + `AddressMap.runtimeAddrForLine(file_id,line)` → `linear`; `ctrl.runToAddress(
linear)` (`:888`); project `target_reached` → `.step`. Line maps to no code ⇒ `Error` (DAP:
unverified), never run forever.

---

## 6. F. The async event bus + background debug-run owner (the risk)

**This is the single highest-risk piece** and is deliberately **deferred past the MVP** (§8). The
MVP proves the entire source-semantics loop using the **existing blocking command/response path**
— no event bus, no background owner — exactly the shape MCP agents want. The async machinery is an
*additive* milestone (M-S4) that does not change the source semantics, only how a stop *surfaces*.

### 6.1 Blocking variant (MVP — reuse today's shape)

`cont`/`stepLine`/`runToLine` run to completion **inside `drainOne`** on the worker (using
`runCapPreemptible` / the §5 loops) and return the resulting `StopState` in the `q.Response`. The
MCP tool result *is* the stop. This is byte-identical to today's blocking `run`/`step`. MCP keeps
this variant **permanently** (agents are turn-based; there is no MCP server-push).

### 6.2 Async variant (M-S4 — the DAP-grade model)

Generalize the **pacer precedent** (`run_pacer.zig` + `run_control.zig` + `stream.zig`): a
background run already exists (`owner = paced`) that submits bounded bursts from a driver thread
and surfaces frames asynchronously. The debug-run reuses the **already-present** `RunOwner.debugger`
(`run_control.zig:31`) + `beginDebugger`/`endDebugger` (`:230/:241`):

1. A frontend's `cont`/`step*` → core calls `RunControl.beginDebugger()`, arms a background
   debug-run flag, returns `Ack{accepted=true}` **immediately**, and the bus broadcasts
   `Continued`. A second concurrent `cont` serializes on `arb` and gets `accepted=false`
   (already running) — idempotent.
2. A **dedicated debug-run driver** (`src/api/debug_runner.zig`, the pacer analog) loops:
   submit a bounded `dbg_run_burst` `q.Command` → worker runs `ctrl.runUntilEvent(BURST)` →
   continue only on `cycle_budget_exhausted`, polling `preemptRequested()` between bursts so a
   `pause`/`reset`/new-breakpoint from any frontend lands at a burst boundary (the exact
   `beginPreempt` mechanism `worker.zig:runCapPreemptible` already uses).
3. On a real stop, the driver calls the **async end transition** (`endDebuggerAsync()`, §6.2.1 —
   *not* today's `endDebugger(restore_to)`), `RunControl.recordStop`, and
   `event_bus.publish(Stopped{StopState})`, which fans out to every attached frontend. DAP turns
   it into a DAP `stopped` event; the web UI updates; MCP (which never subscribed) sees it on its
   next `status` poll.

### 6.2.1 The ownership state machine must distinguish blocking vs async (review Finding 2)

Today's `beginDebugger`/`endDebugger` (`run_control.zig:230/:241`) **does not compose** for a
background run, for three concrete reasons — all of which M-S4 must address (stated now, even
though the fix ships in M-S4):

1. **Stuck owner on a non-returning run.** `beginDebugger` sets `owner = .debugger`; the blocking
   command path pairs it with `endDebugger` inside one `drainOne`. A *background* run has no such
   synchronous pairing — if it is ever left without a guaranteed end call (driver error, frontend
   vanishing mid-run), the owner stays `.debugger` forever. `RunControl.start` refuses while
   `getOwner() == .debugger` (`run_control.zig:205`, returns `false` → 409), so the machine
   **wedges**: no pacer, no new debugger run, no recovery.
2. **`owner = .debugger` is ambiguous (blocking vs async).** The existing blocking per-command
   `run`/`step` *also* takes `.debugger`. A background debug-run reusing the same enum value is
   **indistinguishable** from an in-flight blocking command — a `pause`, a `status`, or a second
   `cont` cannot tell which is running, so it cannot choose the right end transition.
3. **`endDebugger(paced)` re-runs the guest past the breakpoint.** `endDebugger`'s contract
   (`run_control.zig:241-253`) restores `.paced` **and re-arms the pacer**
   (`self.armed.store(true)`) when the prior owner was `paced`. For a background run that **just
   stopped at a breakpoint**, re-arming the pacer resumes a free-run — the guest sails straight
   **past** the breakpoint we stopped at. A debugger stop must leave the machine *parked*, not
   hand it back to the pacer.

**The fix: an explicit async-run ownership state.** M-S4 distinguishes the two debugger owners —
e.g. extend `RunOwner` to `{ idle, paced, debugger_blocking, debugger_async }` (or keep
`.debugger` for blocking and add `.debugger_async`), with a matching `beginDebuggerAsync()` /
`endDebuggerAsync()` pair:

- `cont`/`step*` (async) → `beginDebuggerAsync()` takes `.debugger_async` (the prior owner, idle or
  paced, is **remembered but not auto-restored on a stop**).
- The **driver thread owns the begin/end pairing** (a `defer`-style guarantee on the driver, not on
  any frontend), so a frontend disconnecting mid-run can never strand the owner — the driver still
  reaches its end transition on the eventual stop (fixing reason 1).
- `endDebuggerAsync()` on a **real stop** (breakpoint/step/exit) transitions to **Stopped =
  `owner = .idle`**, and **never re-arms the pacer** (fixing reason 3). The machine is parked for
  inspection; only an explicit subsequent `cont` (or an explicit "resume free-run") re-arms paced.
- Blocking `run`/`step` keep today's `beginDebugger`/`endDebugger(restore_to)` unchanged — the MVP
  (§6.1) never touches the async owner, so nothing regresses (reason 2 is resolved by the two
  states simply being different values).

### 6.3 `event_bus.zig` shape

A clockless broadcast in `src/api` (atomics + `Io.Mutex`/`Condition` legal there; **no host
clock**): a small mutex + condvar + bounded ring of `Event` PODs, with a per-frontend cursor (or a
per-frontend SPSC mailbox). It touches **no guest state and no cycle ledger** → determinism-neutral
by construction; it never enters a snapshot. Frontend reader threads block on the condvar (no
timeout = clockless). `Output` events emit only the *delta* of `Controller.console()` since a
host-side high-water mark (design risk 8).

**Overflow policy (bounded ring — must be specified, not implicit).** The ring is fixed-capacity;
a slow frontend reader can fall behind the producer. The policy: **drop-oldest with a coalesced
"overflow" marker**, never block the producer (the worker/driver must never stall on a frontend)
and never unbounded-grow. When a frontend's cursor would be overrun, the bus advances that
frontend's cursor to the oldest live entry and sets a per-frontend `dropped` flag; the next event
that frontend reads is annotated "you missed N events — re-sync via `stopState()`/`pcLocation()`".
Because the **level** (`last_stop`) is always re-readable (§7, design §5.3), a dropped *edge* is
always recoverable by a poll — losing an event is a hint to re-query, never a correctness loss.
The terminal `Stopped`/`Exited` for the current epoch is the authoritative one a re-sync converges
on. This keeps the bus determinism-neutral (it carries no cycle, gates nothing) regardless of
reader speed.

**Preempt-counter leak on async pause — must be paired (review item).** `beginPreempt`/`endPreempt`
(`run_control.zig:270/:277`) is a **counter** (`fetchAdd`/`fetchSub`), and `preemptRequested()` is
true while it is `> 0`. In the blocking path the pair is a strict LIFO `defer`. In the **async**
path the danger is real: a `pause` raises the counter to make the background driver yield, but the
run now surfaces via a *`Stopped` event*, not a blocking response — so the naive code path that
would have called `endPreempt` is skipped, the counter **leaks**, `preemptRequested()` stays true
forever, and **every** future background burst yields immediately at its first boundary → the
machine can never make progress again. The fix: the async `pause` must pair `beginPreempt` with a
guaranteed `endPreempt` on the **driver side** — when the driver observes `preemptRequested()` and
yields at a burst boundary, it (the consumer of the preempt) drains the pending request via the
same `endPreempt`, returning the counter to zero before it publishes `Stopped{kind=.pause}`. The
counter must be back at zero by the time the epoch is parked; a non-zero residual is a bug the
M-S4 two-frontend test asserts against (count == 0 after the `pause` lands).

### 6.4 Why this is the risk, stated honestly

It reshapes the worker/queue contract: a run now surfaces via an *event* instead of a blocking
*response*. The mitigations: (a) it is **purely additive** — the blocking variant (§6.1) stays for
MCP and the MVP, so nothing existing regresses; (b) it reuses three already-proven mechanisms
(owner arbitration, the preempt counter, the pacer driver) rather than inventing concurrency; (c)
the bus is machine-free so it cannot perturb determinism. **Sign-off item:** adopting the
background `debugger_async` owner (the explicit async-run ownership state of §6.2.1) + bus is the
one consequential architectural decision (design §12) and should be reviewed before M-S4 starts.
It is **not** on the MVP critical path.

---

## 7. G. Session & multi-frontend model

**One session per machine** (the existing `Session`), **multiple attached frontends** (DAP IDE +
web UI + MCP agent simultaneously). Control is shared but **serialized through the core**:

- **Run-ownership** is `RunControl`'s existing `{idle, paced, debugger}` + `arb` mutex. Two `cont`s
  serialize; the second gets `accepted=false`.
- **All run-control + inspection** still funnels through the **one** per-session `queue`
  (`submit_gate`-serialized, one command in flight). The `SourceDebugger` adds **no second path** —
  it runs inside `drainOne` on the worker.
- **`pause`/new-breakpoint/`stepX` from any frontend** raises the preempt counter (`beginPreempt`,
  `run_control.zig:270`) so an in-flight background run yields at the next burst — the exact
  mechanism `/api/run/stop` and MCP `reset` already use to seize a wedged run.
- **Stale refs:** frame/`children_ref`/`var_ref` handles are valid only in the current Stopped
  epoch; the core stamps each with a `stop_epoch` and rejects stale ones with a clean error
  (design §6.2). The lock order is the session's documented one (`session.zig:65`):
  `session.lock → run_control.arb → queue.submit_gate → queue.mutex`.
- **Detach policy:** dropping the last frontend does **not** kill the guest (attach semantics) —
  pin as a product decision (design risk 4).
- **Last-detach must not wedge the run owner (review item).** If the last frontend detaches while a
  background debug-run is in flight (`owner = .debugger_async`, §6.2.1), detach must **not** drop
  the owner mid-burst — that is exactly the stuck-owner wedge. Because the **driver thread** (not
  the frontend) owns the `beginDebuggerAsync`/`endDebuggerAsync` pairing, the run simply continues
  headless and its eventual stop still runs `endDebuggerAsync()` → `owner = .idle`, leaving the
  machine cleanly parked and re-attachable. Detach therefore unsubscribes the frontend from the
  bus and frees its cursor/`dropped` flag, but never touches run ownership. (A detach issued *for*
  a stop — "stop and disconnect" — raises a paired `beginPreempt`/`endPreempt` like any other
  `pause`, §6.3, so it cannot leak the preempt counter either.)

---

## 8. H. Phasing → milestones

| Milestone | Scope | New work | Driven through | Proven by |
|---|---|---|---|---|
| **M-S1 (MVP)** | attach-on-load + `pcLocation` + source/function/addr breakpoints + line stepping (`stepLine`/`stepIn`/`stepOut`/`runToLine`) + frame-0 location, **blocking** path | `src/debug/core/{core,debugger}.zig`; `attachOnLoad` hook in `worker.zig:loadResp`; `q.Command` source variants; MCP tool rows; `projectStop` | **MCP** (`whereami`/`set_source_breakpoint`/`set_function_breakpoint`/`step_line`/`step_in`/`step_out`/`run_to_line`) | extend the integration test to drive **the core** end-to-end on `BB.EXE` (§9) |
| **M-S2** | scopes / variables / types | `core/vars.zig`: `Storage`-driven read + `typeName`/`members` render; `scopes`/`variables`/`setVariable`; `children_ref` expansion; **the worker-side JSON body seam (§3.1a)** — session-owned bounded buffer + `{body_len}` descriptor — **first lands here** (the first nested results) | MCP `locals`/`backtrace`(frame-0) | a variable-render test asserting `v==300`, `lo/hi/r` registers, `int` types (the proof's facts, now through the core) |
| **M-S3** | full stack unwinding + `evaluate` | `core/unwind.zig`: BP-chain near/far multi-frame; full `stackTrace`; a small C-expr `evaluate` (member/index/deref over the peek path) | MCP `backtrace`(full)/`eval` | a multi-frame fixture (call depth ≥ 3) |
| **M-S4** (gated review) | async event bus + background `debugger_async`-owner run | `src/api/event_bus.zig`; `debug_runner.zig`; the `.debugger_async` owner + `beginDebuggerAsync`/`endDebuggerAsync` (§6.2.1); bus overflow policy (§6.3); `Stopped`/`Continued`/`Output`/`Exited` events | web UI + (next) DAP | a two-frontend test: A `cont`, B `pause` → single broadcast `Stopped{kind=.pause}`, **preempt counter back to 0**, **owner back to `.idle`** (no wedge, no pacer re-arm past the stop) |
| **M-DAP** | in-process DAP codec | `src/api/dap.zig` (Content-Length + JSON), translate DAP ↔ neutral ops/events, subscribe to the bus | an IDE DAP client | a DAP `setBreakpoints`→`continue`→`stopped`→`scopes`→`variables` round-trip |

**MVP rationale.** M-S1 reuses the existing instruction-level primitives and the blocking
command/response path almost entirely — the *only* genuinely new code is the symbol-aware
resolution/stepping in `core/debugger.zig` + the attach hook. It proves the highest-value slice
(IDE-grade source breakpoints + source stepping) on a running guest with **zero** new async
machinery, de-risking the project before M-S4.

**Transport note (§3.1a).** M-S1's result types — `pcLocation`/`where`, the source/function/addr
breakpoint confirmations, `registers` — are all **flat-flatten** (pointer-free PODs on `q.Response`,
the `DisasmResult` pattern), so the MVP needs **no** worker-side JSON seam. The
**nested-serialize-on-worker** seam (the framebuffer-pattern session-owned body buffer +
`{ body_len }` descriptor) first becomes necessary at **M-S2**, when `scopes`/`locals`/`variables`
land, and is exercised further by **M-S3**'s full `backtrace` + recursive variable tree. Building
M-S1 on the existing flat path first de-risks the queue/serialization contract before the nested
seam is added.

---

## 9. I. Testing strategy

Build directly on the integration-proof harness (`symbols_integration_test.zig`'s `boot` +
`writeHostFile` + `bootProgram`), now driving **the core** instead of raw `Symbols`/`Controller`:

- **M-S1 end-to-end (the headline test).** Boot + load `BB.EXE`; construct a `SourceDebugger` over
  the live `Controller` + `attachOnLoad(bb_exe, null, current_psp)`; `setBreakpoint(.{.source=
  {"BB.C",9}})` → assert `verified` and `resolved.linear == ((psp+0x10)<<4)+0x02CB` (the proof's
  invariant, now via the core); blocking `cont` → assert `StopState{kind=.breakpoint}`; `pcLocation`
  → assert `function=="_clamp"`, `source.line==9`. Then `stepLine` once → assert the line advanced
  (9→…); `stepOut` → assert it lands back in `_main`. All deterministic (fixed binary, empty input,
  no host clock/RNG — the proof's determinism stance).
- **M-S2 variables.** At the `BB.C:9` stop: `scopes`+`variables` → assert `{v:int=300, lo:int=BX,
  hi:int=CX, r:int=DX}` by name/type/value — the proof's asserted facts, now rendered through
  `core/vars.zig`.
- **Breakpoint persistence across reload.** Set a source bp, `reset`+`load` (new `psp_seg`), assert
  the spec re-resolves to the **new** linear (`reresolveBreakpoints`) without re-sending.
- **Graceful no-symbols.** Load a stripped EXE (or `Symbols.source == .none`): `pcLocation` returns
  null fields, source/function breakpoints resolve `verified=false`, address-level still works.
- **Determinism gates.** Add the `core/*.zig` to `src/debug/determinism_test.zig:sources` (the
  **grep gate**: no host time/RNG/thread/atomic/`f32`/`f64`/HashMap). The **neutral DTOs are NOT
  added to the symbol-POD reflection gate** (`expectNoPointerFields`) — they carry resolved
  `[]const u8` views and so cannot pass it; they are worker-internal render targets, never in
  `Machine.Snapshot` (§1 "Reflection-gate scope"). The integer-only symbol PODs already on that
  gate stay there. Additionally, the **new `q.Response` variants stay ON the
  `expectNoPointerFields(q.Response)` gate** (`src/api/determinism_test.zig:155`, unchanged):
  assert each **flat** variant is a pointer-free POD and each **nested** variant carries only a
  `{ body_len }` descriptor (no slice). Add a test that a Category-B body exceeding the
  session-owned buffer returns an **explicit** "response too large" error, never a truncated JSON
  (CLAUDE.md §2), and a two-query test that concurrent nested queries on one session serialize on
  `session.lock` (no torn body), mirroring the framebuffer-capture test. Run the same scenario
  twice → byte-identical machine state at the stop cycle.
- **M-S4 async (when reached).** Two-frontend arbitration (A `cont`, B `pause`) → exactly one
  broadcast `Stopped{kind=.pause}`; `Output` delta correctness; no double-run.

The fixtures (`BB.EXE`, plus `TEST.EXE`/`RICH.EXE` for multi-segment) are already committed under
`src/debug/symbols/testdata/`.

---

## 10. J. Determinism boundary + open questions/risks

**Determinism boundary (audited).** New engine hooks that touch the cycle ledger or the snapshot:
**none.** Run/step/run-to = `runUntilEvent`/`stepInstruction`/`stepOver`/`runToAddress` + the
preemptible burst loop. Breakpoints = `execution_address{linear}` (no new kind). Inspection = the
peek path (`peekMem`/`peekMemPhys`/`peekStack`/`cpuSnapshot`) — zero cycles, snapshot-identical.
Mutation (`writeMem`/`setReg*`) = a deliberate, recorded input. The `SourceDebugger` (symbols +
spec table + caches) is host-side config re-attached on load, never serialized — the `LoadRecipe`
pattern. The event bus is machine-free and clockless. **The `psp_seg` read is the *only* machine
state the symbol path consumes, and only via `AddressMap.attach`.**

**Open questions / risks:**

1. **[HEADLINE] The async event bus + background `debugger`-owner run (§6).** The one consequential
   architectural change; deferred past the MVP, additive, reuses the pacer/preempt precedent.
   Requires sign-off before M-S4. *Mitigation:* MVP proves everything via the blocking path first.
2. **16-bit unwinding without frame pointers (design risk 3).** M-S3 relies on BC++ `-v` `push bp;
   mov bp,sp` frames. Optimized builds may omit them. *Mitigation:* fall back to frame-0-only and
   report; verify the BaK relink is a debug build. `stepOut` far/near comes from the function's TDS
   type (`typeInfo(...).function.far`).
3. **Source-path remap (design risk 5 / symbol R6).** TDS stores compile-time DOS paths
   (`SymbolIndex.sourceFile` returns them raw). The compile-path→host-path remap + source-serving
   belong to the **frontend** (IDE-specific, not a debugging semantic). The core exposes raw paths
   only — no change needed.
4. **`evaluate` scope (design risk 2).** v1 = symbol/field/index/deref over the **peek path** only;
   **no guest execution** (a function-call eval would charge cycles and inject an unrecorded input
   — forbidden). Conditional breakpoints (design risk 1) likewise: peek-only conditions are
   determinism-safe; side-effecting conditions are forbidden in v1.
5. **`Output` event fidelity (design risk 8).** `console()` is non-clearing; emit only the delta
   since a host high-water mark; distinguish stdout/stderr if the DOS layer tracks the handle.
6. **Step-loop wedge.** A line that never changes (no-line tight loop) must not hang the host —
   the §5 budget cap + preempt poll handle it; surfaced as a reported `step_complete`.

**Where the real API could not serve a design op — and the minimal addition:** **exactly one
symbol-layer accessor** (review Finding 4). Every design §4 operation and §7 stepping primitive
maps onto an existing `Symbols`/`AddressMap`/`SymbolIndex`/`TypeGraph` + `Controller` call (§3.2)
— **except `stepOut`'s far/near decision**, which needs the current function's return type. The
live-PC path yields a `FuncRef`, and `FuncRef` (`index.zig:36`) carries **no `type_index`** (only
`SymRef` does), so the function's type cannot be reached without **`SymbolIndex.typeRefForFunction(
FuncRef) ?u16`** (§3.2 — pure, integer-only, gate-clean). This is the **single** new symbol-API
surface; the integration proof did not exercise `stepOut`, so it did not surface the gap. **No new
*engine* surface** (no cycle-ledger or snapshot touch) is added. The remaining new code is the
source-semantics layer itself (`src/debug/core/`) and the `src/api` async/frontend plumbing. (Other
minor pure helpers — e.g. a register-number→`format.Reg` mapping for `.register` locals, or the
`readHostFile`/`sameStem` load-time helpers in `worker.zig` — are not symbol-API or engine changes.)

---

## 11. Appendix: codebase anchors

**Top files to build on (absolute paths under the repo root):**

1. `src/debug/symbols/{symbols,index,map,types}.zig` — the consumed API (§0). `Symbols.open`/
   `attach`/`scopeForRuntimeAddr`; `AddressMap.runtimeAddrForLine`/`lineForRuntimeAddr`/
   `functionForRuntimeAddr`/`entryAddrForFunction`; `SymbolIndex.fileId`/`nameToSymbol`/
   `functionName`/`sourceFile`; `TypeGraph.localsForScope`/`typeName`/`typeInfo`/`members`;
   `Storage`/`Local`.
2. `src/debug/symbols_integration_test.zig` — the end-to-end loop the M-S1/M-S2 tests extend.
3. `src/debug/controller.zig` — the run/step/peek/write primitives the core composes (§0 line
   table). `src/debug/breakpoints.zig` — `execution_address{linear}` + `currentLinear` (`:212`).
4. `src/api/worker.zig` (`drainOne` `:113`, `loadResp` `:655`, `restoreResp` `:692`,
   `runCapPreemptible` `:292`) + `src/api/run_control.zig` (`RunOwner.debugger` `:31`,
   `beginDebugger`/`endDebugger` `:230/:241`, preempt `:270-284`, `publishStatus` `:290`) — the
   attach hook + async owner.
5. `src/api/session.zig` (`Session` `:201`, `LoadRecipe` `:145`, `init` `:315`) — where the
   `SourceDebugger` is owned, the host-side-config-on-load precedent.
6. `src/api/mcp_tools.zig` (`Tool` `:47`, `tools` `:74-388`, `buildCommand`) — where the
   source-level MCP tool rows attach.
7. `src/debug/determinism_test.zig` (`sources` `:12-28`, reflection gate `:67-90`) — the gate the
   new `core/*.zig` files must pass.

**Reference docs:** `docs/design/debug-core-architecture.md` (the reconciled design — §3 boundary,
§4 interface, §5 async model, §7 stepping, §8 DAP/MCP mapping); `docs/design/tds-parser-plan.md`
(the sibling parser plan this mirrors in form); `docs/research/borland-tds-format-complete.md` (§14
the `load_para` relocation the `AddressMap` implements).
