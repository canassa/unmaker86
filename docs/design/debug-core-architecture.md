# Protocol-Neutral Debug Core — Architecture & Design

**Status:** design (no code). Targets source-level debugging of Borland-C++-3.1-compiled
DOS guests (a decompiled *Betrayal at Krondor* relink) under zdos.

**Prime directive (inherited, non-negotiable — CLAUDE.md §1):** determinism. Same binary +
same inputs ⇒ byte-identical machine state at any cycle N, every run. The debug core lives
**host-side, outside the deterministic machine**. It observes and controls; it never alters
emulated execution and never enters the serialized snapshot. This document is written *to*
that constraint, not around it.

---

## Table of Contents

1. [Goals & non-goals](#1-goals--non-goals)
2. [How zdos debugging works today (grounding)](#2-how-zdos-debugging-works-today-grounding)
3. [A. Layering & boundaries](#3-a-layering--boundaries)
4. [B. The debug-core interface (operations & events)](#4-b-the-debug-core-interface-operations--events)
5. [C. The async run + state model](#5-c-the-async-run--state-model)
6. [D. Session & multi-frontend model](#6-d-session--multi-frontend-model)
7. [E. Source-line stepping algorithm](#7-e-source-line-stepping-algorithm)
8. [F. Mapping tables (DAP / MCP ↔ core)](#8-f-mapping-tables-dap--mcp--core)
9. [G. Transport options & source-tree placement](#9-g-transport-options--source-tree-placement)
10. [H. Phasing (Tiers ↔ milestones ↔ DAP subsets)](#10-h-phasing-tiers--milestones--dap-subsets)
11. [I. Open questions & risks](#11-i-open-questions--risks)
12. [Minimal new engine surface (determinism audit)](#12-minimal-new-engine-surface-determinism-audit)
13. [Appendix: key file/function references](#13-appendix-key-filefunction-references)

---

## 1. Goals & non-goals

### Goals

- A **protocol-neutral debug core** that owns *all* debugging semantics: source-line
  stepping, frame unwinding, variable rendering, breakpoint resolution, run control, and
  event emission. Expressed as **native Zig types** — no DAP JSON, no MCP JSON leaks into
  the core.
- **Event-driven**: `continue` / `step` / run-control return immediately; the machine runs
  in the background; the core emits subscribable events (stopped, continued, output, exited,
  …). The core *also* exposes pollable current state for pull-based frontends (MCP agents).
- Frontends (**DAP, MCP, the existing HTTP/JSON + web UI**) are **dumb translators**: they
  map their wire protocol onto the same core operations/events and carry no debugging logic.
- Build on the existing zdos primitives. Add **zero** new engine surface that touches the
  cycle ledger or the serialized snapshot.

### Non-goals (for this design)

- The TDS parser itself — its format is already nailed in
  `docs/research/borland-bcc3-debug-format.md` (read §0 "Empirical Confirmation" and §8
  "Address and Segment Model"). This doc consumes the **symbol layer** as a dependency and
  specifies its interface contract, not its byte-level parsing.
- A full C expression evaluator. `evaluate` is stubbed to symbol-name lookup in v1.
- Multi-process / overlay / DPMI debugging. The target is a single 16-bit real-mode MZ image.

---

## 2. How zdos debugging works today (grounding)

Every claim below is anchored to a concrete file/function. The new core **builds on** these;
it does not replace them.

### 2.1 Controller — "controller-owns-the-loop"

`src/debug/controller.zig : Controller` is the synchronous, in-process facade that **owns the
run loop**. It holds a `*Machine` (it sits *above* `machine` in the module graph: `src/debug`
imports `cpu` + `machine`, nothing below imports `debug`) and drives the machine's step
primitive directly, scanning its own breakpoint set between steps.

- **`Controller.runUntilEvent(cycle_cap)`** (`controller.zig:480`) is the core run engine:
  a `while` loop that calls `self.m.step()` once, then checks terminal precedence
  (`terminalReason`), then scans breakpoints (`scanBreakpoints`), then the branch-trap, then
  the cycle deadline. It returns a rich `StopReason` (`controller.zig:81`). It **only reads**
  the cycle ledger — the CPU stays the sole writer. No host time, no thread, no poll. Pausing
  = returning from this function, leaving the ledger exactly where the last retired step put
  it.
- The machine step primitive is **`src/machine/run_loop.zig : step(m)`** (`run_loop.zig:41`):
  fire-due-events → `cpu.step()` → HLT fast-forward / shutdown handling. This is the only
  thing that advances guest cycles.
- `StopReason` (`controller.zig:81`) is a tagged union: `breakpoint`, `step_complete`,
  `cycle_budget_exhausted`, `target_reached`, `dwell_complete`, `halted_forever`,
  `program_terminated{ret_code}`, `shutdown`, `branch_trap`, `no_progress`,
  `stopped_by_request`. The new core's neutral `StopReason` is a re-projection of this.

### 2.2 Breakpoints / watchpoints

`src/debug/breakpoints.zig`:

- `BreakpointKind` (`breakpoints.zig:27`) is a union: `execution_address{linear:u32}`,
  `cycle{at_cycle:u64}`, `interrupt{vector:u8}`, `memory{linear,len,access}`, `io{port,access}`.
- `BreakpointSet` (`breakpoints.zig:54`) is fixed storage (`MAX_BREAKPOINTS = 64`), **stable
  ids = slot index**, defined POD (never `undefined`), no pointer fields (so it is
  snapshot-safe and serializes cleanly). `add`/`remove`/`enable`/`get`/`forEach`.
- `matches(bp, m, seq_before)` (`breakpoints.zig:154`) is side-effect-free; `currentLinear(m)`
  (`breakpoints.zig:212`) = `seg_base[CS] +% EIP` — the **same linear formula** the TDS
  address model produces, which is what makes source breakpoints reduce to
  `execution_address{linear}`.
- `Controller.addBreakpoint` (`controller.zig:634`) also arms a **bus watch** for `memory`/`io`
  kinds; `removeBreakpoint` clears it. The watch table rides *inside* `Machine.Snapshot`, so
  `rearmWatches` (`controller.zig:775`) re-syncs after a restore — important precedent for §3.

### 2.3 Stepping, run-to, step-over

All on top of one-shot breakpoints + `runUntilEvent`:

- `stepInstruction` (`controller.zig:823`), `stepN` (`controller.zig:848`).
- `stepOver` (`controller.zig:1035`): for a direct CALL/INT (`E8`/`9A`/`CD`) it executes the
  call then arms a one-shot `execution_address` at the **pushed return address**, **SP-guarded**
  so recursion is correct (`returnSiteAfterCall`, `controller.zig:1120`). For a REP-string it
  arms a one-shot at the next instruction. Everything else falls back to step-into and
  **reports** it (`StepOverResult.stepped_into`). **This is exactly the machinery `stepOut` and
  `next` reuse** (§7).
- `runToAddress` (`controller.zig:888`) / `runToCycle` (`controller.zig:866`): one-shot
  breakpoint + `runUntilEvent`, translating the internal one-shot's hit into a dedicated
  `target_reached` reason.
- Preemptible variants: `beginRunToAddress` / `runTargetBurst` / `endRunTarget`
  (`controller.zig:948-971`) split a long run into bounded bursts so the worker can yield.

### 2.4 Inspection (side-effect-free peek path)

All reads use the **bus peek path** — never device read handlers (which mutate). So an inspect
leaves `machine.snapshot()` byte-identical and charges zero cycles:

- `cpuSnapshot` (`controller.zig:1472`) — full register/flag/cycle POD.
- `peekMem(seg,off,dst)` / `peekMemPhys(phys,dst)` (`controller.zig:1519/1536`).
- `peekStack(out)` (`controller.zig:1977`) — words from SS:SP upward, no SP mutation.
- `disasmWindow(origin,count,out)` (`controller.zig:1698`) — pure-peek disassembler, takes a
  `DisasmOrigin` (`linear` / `seg_off` / `cs_eip`).
- `peekIvtEntry`, `console`, `screen`, `framebuffer`, `devicesSnapshot`, `ioShadow`, `searchRam`.
- `status()` (`controller.zig:1993`) — `{running, terminated, ret_code, cycles, last_stop}`.

### 2.5 Mutation (explicit, deliberate inputs)

`setReg32/16/8`, `setSegment`, `setEip`, `setFlags`, `writeMem`/`writeMemPhys`
(`controller.zig:1141-1167`). A debugger write is a *new deterministic input* ("same binary +
SAME INPUTS"); the core never mutates implicitly.

### 2.6 The threading / queue layer (`src/api`)

The Controller is **purely synchronous and single-threaded** by design; `src/debug` forbids
atomics (a determinism grep-gate). The async machinery lives one layer up in `src/api`:

- **`src/api/worker.zig : Worker`** (`worker.zig:724`) — the **sole owner** of
  `*Controller`/`*Machine` at runtime. Its loop is `waitDequeue → drainOne → complete`.
  `drainOne` (`worker.zig:113`) maps exactly one `q.Command` to exactly one Controller method
  and fills a typed `q.Response` carrying a transport-independent `ErrCode` (never an HTTP
  status). The `code → HTTP status` map lives only in `server.zig`, so MCP reuses the codes.
- **`src/api/run_control.zig : RunControl`** (`run_control.zig:57`) — clockless atomics +
  one `Io.Mutex`. Owns: the run **owner** arbitration enum `{idle, paced, debugger}`
  (`RunOwner`, `run_control.zig:31`) with `beginDebugger`/`endDebugger`/`start`/`stop`; the
  **preempt counter** (`beginPreempt`/`endPreempt`/`preemptRequested`, `run_control.zig:270`)
  that lets a control command seize the worker between bursts; and the **published clockless
  status** (`publishStatus`/`publishedCycle`, `run_control.zig:290`) that lets `/api/machines`
  report a machine's cycle without submitting to (and being blocked by) its worker.
- **`src/api/session.zig : Session`** (`session.zig:201`) — bundles one machine's
  `ctrl`, `queue`, `worker_thread`, `run_control`, `render`, `live_mouse`, `snapshots`,
  `recipe`, `mount_dir`. The module header documents the **per-session concurrency contract**:
  the worker *solely* owns the machine; a connection thread only builds a `Command`, submits it
  through the serialized `queue` (one in flight, `submit_gate`-gated), and serializes the
  `Response`. Off-queue shared state is guarded by `session.lock`. **The breakpoint set,
  recipe, and mount config are host-side, re-attached on load — NOT in the machine snapshot.**

### 2.7 Existing frontends

- **HTTP/JSON** — `src/api/server.zig` maps routes to `q.Command`s and `ErrCode → HTTP status`.
  A blocking `run`/`step` returns its `StopReason` in the response body.
- **MCP** — `src/api/mcp.zig` (JSON-RPC envelope) + `src/api/mcp_tools.zig` (the ~40-tool
  catalog, each row mapping 1:1 to a `q.Command`): `step`, `step_n`, `step_over`, `run`,
  `run_to_cycle`, `run_to_address`, `add_breakpoint`, `read_cpu`, `read_stack`, `read_memory`,
  `disassemble`, `status`, `snapshot`/`restore`, etc. MCP is **stateless / pull-based** — there
  is no server-push channel to an agent; it polls `status`.
- **Web UI / live video** — `src/api/stream.zig` + `src/host/run_pacer.zig`: the host pacer
  arms a **background free-run** (owner = `paced`) that submits `run_slice` each ~10 ms wall
  tick, and a frame producer pushes VGA frames. **This is the existing precedent for
  "background running with asynchronous surfacing of state"** that the event-driven debug
  model generalizes.

**Takeaway:** zdos already has (a) a protocol-neutral, host-side, synchronous control core
(the `Controller`), (b) a transport-independent command/response/error vocabulary
(`q.Command`/`q.Response`/`ErrCode`), (c) a single-worker serialized ownership model with
preemption, and (d) a background-run + push precedent (pacer + stream). The new debug core is
**two additions** on top: a **symbol layer** (TDS) and a **source-semantics + event layer**,
plus an **event bus** in `src/api`. No new engine surface.

---

## 3. A. Layering & boundaries

### 3.1 The stack

```
┌──────────────────────────────────────────────────────────────────────────┐
│ FRONTENDS (thin adapters — wire translation ONLY, no debug logic)          │
│   DAP adapter   │   MCP tools   │   HTTP/JSON + web UI                      │
└─────────┬───────────────┬──────────────────┬─────────────────────────────-┘
          │ native ops/events (Zig types) — NO DAP/MCP types cross this line  │
┌─────────▼───────────────▼──────────────────▼─────────────────────────────-┐
│ DEBUG CORE  (protocol-neutral; owns ALL debugging semantics)               │
│   • run control (cont/pause/step kinds, runToLine)                         │
│   • breakpoint resolution (addr | function | file:line | conditional)      │
│   • source-line stepping algorithm                                         │
│   • stack unwinding, scopes, variable rendering, evaluate                  │
│   • EVENT emission (Stopped/Continued/Output/Exited/ModuleLoaded/…)        │
│   pure semantics live in src/debug; async/event/session in src/api         │
└─────────┬──────────────────────────────────────────┬─────────────────────-┘
          │ addr↔line/func, name→addr, scopes/locals  │ run/step/peek/write
┌─────────▼──────────────────────────-┐   ┌───────────▼─────────────────────┐
│ SYMBOL LAYER (TDS)  — host-side      │   │ Controller (src/debug)          │
│   parse TDS, build indices,          │   │   runUntilEvent / step* /       │
│   addr↔source, name↔addr, types,     │   │   runToAddress / peek* / set*   │
│   load_para relocation               │   │   (controller-owns-the-loop)    │
└──────────────────────────────────────┘   └───────────┬─────────────────────┘
                                                        │ machine.step()
                                            ┌───────────▼─────────────────────┐
                                            │ zdos ENGINE (deterministic)      │
                                            │   machine / cpu / bus / devices  │
                                            │   ← the ONLY thing in snapshots   │
                                            └──────────────────────────────────┘
```

### 3.2 Host-side vs in-the-machine

| Component | Lives in | In `Machine.Snapshot`? |
|---|---|---|
| RAM, CPU regs, devices, cycle ledger | deterministic machine | **Yes** |
| Bus memory/IO **watch tables** | machine (armed by Controller) | **Yes** (so `restore` reverts them; re-synced by `rearmWatches`) |
| Breakpoint **set** (`Controller.set`) | host (Controller) | **No** |
| Symbol layer (TDS parse, indices, `load_para` map) | host (debug core) | **No** |
| Debug session state, event subscriptions, frame caches | host (debug core / api) | **No** |

**The rule:** the debug core's own state — breakpoints, session, symbol indices, frame/variable
caches — is **host-side configuration re-attached on load**, exactly analogous to the
**ROM / mount-dir / load-recipe** config that `Session` already re-applies on `reset`+`load`
(`session.zig : LoadRecipe`, `worker.zig : loadResp`). It is never serialized.

### 3.3 Determinism / snapshot interaction (the load_para subtlety)

The TDS→runtime relocation is `runtime = load_para + seg_base + tds_offset`
(research §8). `load_para` is the DOS load paragraph — **a property of the deterministic load,
recoverable from the machine** (the MCB/PSP allocation that zdos tracks), *not* something the
core invents. The symbol layer therefore re-derives `load_para` **from the machine** at attach
time (or after each `load`), exactly as the existing config is re-applied. Concretely:

- On `load` / `reset+load` (`worker.zig : loadResp`), the resolved runtime address of any TDS
  symbol changes only because `load_para` changed — a deterministic function of the load. The
  core re-resolves its address indices; the **breakpoint *specs* persist** (file:line,
  function name), their **resolved linear addresses are recomputed**. This mirrors how
  breakpoints "PERSIST across a restore (LOCKED, like reset)" while their bus watches are
  rebuilt (`rearmWatches` doc, `controller.zig:757`).
- On `restore` (`worker.zig : restoreResp`): the machine reverts to a prior cycle, the bus
  watch tables revert with it, and `rearmWatches` re-syncs. **`load_para` is unchanged across a
  restore** (same load), so the symbol indices need no rebuild; only `last_stop` and the live
  frame/variable caches (which are valid only while stopped) are invalidated. The design adds a
  symmetric `core.onMachineReverted()` hook called from `restoreResp` next to `rearmWatches`.

No core state ever enters `Machine.Snapshot`; the snapshot/restore byte-identity guarantee is
untouched.

---

## 4. B. The debug-core interface (operations & events)

Native Zig types. **No DAP/MCP type appears here.** Reuses existing PODs where they already fit
(`debug.CpuSnapshot`, `debug.DisasmResult`). DAP maps ~1:1 onto these; MCP maps a friendlier
subset of the *same* operations.

### 4.1 Identity & location types

```zig
/// DOS is single-CPU, no preemptive guest threads. We expose ONE synthetic thread so
/// DAP's "threads→frames" model has a root. Always present, never created/destroyed.
pub const ThreadId = enum(u32) { cpu = 1, _ };

/// A 16-bit segmented address plus its resolved 20-bit linear form. `linear` is the
/// canonical key (== Controller.currentLinear); seg:off is carried for display/DAP.
pub const Addr = struct { seg: u16, off: u16, linear: u32 };

/// A resolved source position (from the TDS line table + load_para map).
pub const SourceLoc = struct {
    file_id: u32,            // index into the symbol layer's source-file table
    path: []const u8,        // borrowed from the symbol layer (stable for session)
    line: u32,               // 1-based
    column: u32 = 0,         // TDS has no columns; always 0 (DAP tolerates)
};

/// Where the PC is, fully resolved. Any field may be null if symbols don't cover it.
pub const PcLocation = struct {
    addr: Addr,
    function: ?[]const u8 = null,
    source: ?SourceLoc = null,
    in_prologue: bool = false,   // PC is before the function's first source line
};
```

### 4.2 Breakpoint specs (neutral, source-aware)

```zig
pub const BreakpointSpec = union(enum) {
    addr: struct { linear: u32 },                       // instruction bp
    function: struct { name: []const u8 },              // resolve name→entry addr (post-prologue)
    source: struct { file: []const u8, line: u32 },     // resolve file:line→addr via TDS
};

/// A spec plus an OPTIONAL guest-expression condition (see Open Questions for determinism).
pub const BreakpointRequest = struct {
    spec: BreakpointSpec,
    condition: ?[]const u8 = null,   // v1: ignored or simple "reg==imm"; full eval deferred
    hit_condition: ?u32 = null,      // stop on the Nth hit (host-side counter; deterministic)
};

/// The outcome of resolving a request. `verified=false` ⇒ no address (e.g. file:line had no
/// code / symbols absent); DAP reports it as an unverified breakpoint, MCP as a warning.
pub const ResolvedBreakpoint = struct {
    id: u32,                         // == underlying Controller breakpoint id (stable)
    request: BreakpointRequest,
    resolved: ?Addr = null,          // the actual code address it landed on
    source: ?SourceLoc = null,       // the actual line (line table may snap to next exec line)
    verified: bool,
};
```

A `source`/`function` spec **resolves to a `Controller` `execution_address{linear}` breakpoint**
(`addBreakpoint`, `controller.zig:634`). The core keeps the spec→id mapping so it can
*re-resolve* after a `load` (new `load_para`) without the frontend re-sending.

### 4.3 Frames, scopes, variables

```zig
pub const Frame = struct {
    index: u32,                      // 0 = innermost (current PC)
    pc: Addr,                        // CS:IP for frame 0; return address for callers
    function: ?[]const u8,
    source: ?SourceLoc,
    frame_base: u16,                 // the BP value for this frame (SS-relative); locals base
    is_far: bool,                    // far vs near return frame (from the fn calling convention)
};

pub const ScopeKind = enum { locals, arguments, registers, globals };
pub const Scope = struct {
    kind: ScopeKind,
    frame_index: u32,
    var_ref: u32,                    // opaque handle the frontend passes back to `variables`
};

pub const Variable = struct {
    name: []const u8,
    type_name: []const u8,           // rendered from the TDS type graph, e.g. "struct Foo *"
    value_text: []const u8,          // rendered scalar/pointer/aggregate summary
    addr: ?Addr = null,              // where it lives (auto: SS:BP+off ; static: DS:off)
    children_ref: u32 = 0,           // non-zero ⇒ aggregate/pointer; expand via `variables`
    writable: bool = true,
};
```

### 4.4 Stop reason & stop state (pollable)

```zig
pub const StopKind = enum { breakpoint, step, pause, entry, fault, exit, terminated };

pub const StopState = struct {
    running: bool,
    kind: ?StopKind,                 // null while running
    thread: ThreadId = .cpu,
    pc: ?PcLocation,
    bp_id: ?u32 = null,              // set when kind == .breakpoint
    cycle: u64,
    exit_code: ?u16 = null,          // set when kind == .exit/.terminated
};
```

### 4.5 Operations

Return-immediately run-control returns a small `Ack`; the *result* (the stop) arrives as a
`Stopped` event (§5). Query/inspect operations are synchronous (they run on the worker via the
existing queue and return a value).

```zig
pub const Ack = struct { accepted: bool, reason: ?[]const u8 = null }; // false ⇒ e.g. already running

pub const DebugCore = struct {
    // ── session ───────────────────────────────────────────────────────────
    pub fn attach(self: *DebugCore, frontend: *Frontend) FrontendHandle;     // subscribe + register a control producer
    pub fn detach(self: *DebugCore, h: FrontendHandle) void;

    // ── breakpoints ───────────────────────────────────────────────────────
    pub fn setBreakpoint(self: *DebugCore, req: BreakpointRequest) Error!ResolvedBreakpoint;
    pub fn clearBreakpoint(self: *DebugCore, id: u32) Error!void;
    pub fn clearBreakpointsForSource(self: *DebugCore, file: []const u8) void; // DAP setBreakpoints replaces a file's set
    pub fn listBreakpoints(self: *DebugCore, out: []ResolvedBreakpoint) []ResolvedBreakpoint;

    // ── run control (ASYNC — return immediately; surface a Stopped event) ───
    pub fn cont(self: *DebugCore) Ack;
    pub fn pause(self: *DebugCore) Ack;
    pub fn stepInstruction(self: *DebugCore) Ack;
    pub fn stepLine(self: *DebugCore) Ack;          // "next": step over calls, stop at next source line
    pub fn stepIn(self: *DebugCore) Ack;            // descend into a callee's first source line
    pub fn stepOut(self: *DebugCore) Ack;           // run to caller frame return
    pub fn runToLine(self: *DebugCore, file: []const u8, line: u32) Error!Ack;

    // ── state queries (SYNC, pollable; side-effect-free peek path) ──────────
    pub fn stopState(self: *DebugCore) StopState;
    pub fn pcLocation(self: *DebugCore) PcLocation;
    pub fn registers(self: *DebugCore) debug.CpuSnapshot;     // reuse existing POD
    pub fn stackTrace(self: *DebugCore, out: []Frame) []Frame;
    pub fn scopes(self: *DebugCore, frame_index: u32, out: []Scope) []Scope;
    pub fn variables(self: *DebugCore, var_ref: u32, out: []Variable) []Variable;
    pub fn evaluate(self: *DebugCore, expr: []const u8, frame_index: u32) Error!Variable; // v1: name lookup

    // ── memory (SYNC; reuse Controller peek/write) ──────────────────────────
    pub fn readMemory(self: *DebugCore, at: Addr, dst: []u8) void;
    pub fn writeMemory(self: *DebugCore, at: Addr, src: []const u8) void;     // a deliberate new input
    pub fn setVariable(self: *DebugCore, var_ref: u32, name: []const u8, value: []const u8) Error!Variable;
};
```

### 4.6 Events

```zig
pub const EventKind = enum {
    stopped,        // execution halted; carries StopState
    continued,      // background run (re)started
    breakpoint,     // a breakpoint was resolved/changed (verified flips, address moved on reload)
    output,         // guest CON / stdout / stderr bytes
    module_loaded,  // a symbol module attached (TDS parsed) or detached (reload)
    exited,         // guest process exited with a code (INT 21h AH=4C / INT 20h)
    terminated,     // the debug session ended (machine shutdown / detach)
};

pub const Event = union(EventKind) {
    stopped: StopState,
    continued: struct { thread: ThreadId },
    breakpoint: ResolvedBreakpoint,
    output: struct { category: enum { stdout, stderr, console }, bytes: []const u8 },
    module_loaded: struct { name: []const u8, base_para: u16, symbols: bool },
    exited: struct { code: u16 },
    terminated: struct { reason: enum { exited, shutdown, detached } },
};

/// A frontend implements this; the core fan-outs every event to all attached frontends.
pub const Frontend = struct {
    onEvent: *const fn (ctx: *anyopaque, ev: Event) void,
    ctx: *anyopaque,
};
```

**Mapping from the existing `debug.StopReason` → neutral `StopKind`** (done inside the core, the
*only* place the raw union is read):

| `debug.StopReason` | `StopKind` | Notes |
|---|---|---|
| `breakpoint` | `.breakpoint` (or `.step` if it is the core's own one-shot) | `bp_id` set |
| `step_complete` | `.step` | |
| `target_reached` | `.step` | runToLine/stepOut one-shot |
| `program_terminated` | `.exit` | `exit_code = ret_code` |
| `shutdown` | `.fault` then `.terminated` | triple fault |
| `halted_forever` | `.terminated` | deterministic permanent HLT |
| `cycle_budget_exhausted` | *(no event)* | internal burst boundary; resume |
| `branch_trap` / `no_progress` | `.fault` | surfaced with detail |
| `stopped_by_request` | `.pause` | a `pause`/preempt landed |

---

## 5. C. The async run + state model

### 5.1 Session state machine

```
            attach + symbols          configurationDone / first cont
 ┌────────┐  ────────────────►  ┌──────────────┐  ───────────────►  ┌──────────┐
 │ Detached│                    │ Configuring   │                    │ Running   │
 └────────┘  ◄────────────────  └──────────────┘  ◄───────────────  └────┬─────┘
        detach / terminated          pause/bp/step/exit (Stopped)        │
                                          ▲                               │
                                          │      cont / step* ────────────┘
                                     ┌────┴──────┐
                                     │ Stopped    │  (frames/scopes/vars valid ONLY here)
                                     └───────────-┘
                                          │ exit/shutdown
                                          ▼
                                     ┌──────────-┐
                                     │ Terminated │
                                     └───────────-┘
```

- **Configuring**: symbols attached, breakpoints being set; the machine is loaded and paused at
  entry (this is exactly what `--serve PROGRAM` already does — load, pause at entry, serve).
- **Running**: a background run is in flight (worker is bursting). `cont`/`step*` enter here.
- **Stopped**: the worker is idle at a clean instruction boundary; `stackTrace`/`scopes`/
  `variables` are valid only in this state (they read live BP/SP, valid only while paused).
- **Terminated**: guest exited / shutdown / session detached.

### 5.2 How `cont` returns immediately and a `Stopped` event surfaces later

This reuses the **existing background-run precedent** (the pacer, `run_control.zig`/`run_pacer.zig`)
generalized into a **debug-run owner**:

1. A frontend calls `cont()`. The core acquires `session.lock`, calls
   `RunControl.beginDebugger()` (`run_control.zig:230`) to take the run owner, and **arms a
   background debug-run** (a new `RunOwner.debugger` free-run mode, distinct from the blocking
   per-command `run`). It returns `Ack{accepted=true}` to the frontend **immediately** and emits
   a `Continued` event to all subscribers.
2. A **dedicated debug-run driver** (the worker, prompted by a `cont`/`run_slice`-style command)
   loops `Controller.runUntilEvent(BURST)` in bounded bursts — *exactly* the preemptible burst
   loop already in `worker.zig : runCapPreemptible` (`worker.zig:292`). Between bursts it polls
   `RunControl.preemptRequested()` so a `pause`/`reset` from any frontend lands promptly.
3. When a burst returns a non-`cycle_budget_exhausted` `StopReason`, the driver:
   - records it (`Controller.last_stop`, `RunControl.recordStop`),
   - calls `RunControl.endDebugger()` to release the owner (state → Stopped),
   - **publishes a `Stopped` event** to the event bus, which fans out to every attached frontend.

The DAP frontend turns that into a DAP `stopped` event; the web UI updates; the MCP poller sees
it on its next `status` call.

### 5.3 Polling coexisting with events

Pull-based frontends (MCP agents, scripts) never subscribe; they call `stopState()` /
`pcLocation()` / `registers()`. Two non-blocking sources make this cheap and race-free:

- The **published clockless status** (`RunControl.publishedCycle`/`publishedMult`,
  `run_control.zig:290`) — readable **without submitting to the worker**, so a poll never blocks
  on a long run. This already exists for `/api/machines`.
- The full `stopState()` query goes through the normal serialized queue and returns the
  authoritative `last_stop` + a fresh `cpuSnapshot` when the worker is idle.

The event bus and polling are **two views of the same `last_stop`**: the event is the *push*
edge, `stopState()` is the *level*. A frontend may use either or both.

### 5.4 Threading / turn model (given zdos's single-loop controller)

The hard invariant from `session.zig`: **the worker thread solely owns the machine; everything
else submits serialized commands**. The event-driven model respects this exactly:

- All run-control + inspection still funnels through the **one** per-session `queue` (one command
  in flight, `submit_gate`-serialized). The core adds **no second path** to the machine.
- The **event bus is a separate, machine-free broadcast channel** (a small mutex + condvar +
  bounded ring of `Event` records, or a per-frontend SPSC mailbox). It touches no guest state
  and no cycle ledger, so it is determinism-neutral and can live entirely in `src/api` (atomics
  legal there). Frontends' reader threads block on it.
- The background debug-run is the worker bursting on its own; control commands (`pause`, new
  breakpoints) interleave **between bursts** via the existing preempt mechanism. There is never
  more than one thread inside `Controller`.

---

## 6. D. Session & multi-frontend model

**One active debug session per machine** (the existing `Session`), with **multiple attached
frontends** (a DAP client in the IDE, the web UI, an MCP agent — simultaneously). Control is
**shared but serialized through the core**: any frontend may issue any control op; the core
arbitrates and **broadcasts every event to all** frontends.

### 6.1 Arbitration

- Run-ownership is already arbitrated by `RunControl` (`{idle, paced, debugger}` +
  `arb` mutex). The debug-run owner extends this: a `cont` from frontend A and a `cont` from
  frontend B serialize on `arb`; the second sees the machine already `Running` and gets
  `Ack{accepted=false, reason="already running"}` (idempotent, no double-run).
- A `pause` / new `setBreakpoint` / `stepX` from **any** frontend raises the preempt counter
  (`beginPreempt`, `run_control.zig:270`) so the in-flight background run yields at the next
  burst boundary — then the control op runs. This is the **exact mechanism** that already lets
  `/api/run/stop` and MCP `reset` seize a wedged run.

### 6.2 Conflict cases (and resolutions)

| Conflict | Resolution |
|---|---|
| Two frontends `cont` simultaneously | `arb` serializes; second gets `accepted=false` (already running). One `Continued` event, one eventual `Stopped`, both see both. |
| Frontend A `cont`, Frontend B `pause` | B's `pause` raises preempt; run yields → single `Stopped{kind=pause}` broadcast to **both**. |
| Frontend A steps while B is reading variables | Both are queue commands; `submit_gate` serializes. A's step only runs after B's `variables` completes (worker is idle between them). Frame/var refs B holds are invalidated by the step → next `variables` re-fetches. |
| A sets a breakpoint mid-run | Raises preempt; bp added between bursts; run resumes. A `breakpoint` event broadcasts the resolution. |
| A `detach`es while running | Its subscription is dropped; the run continues for the others. If A was the *last* frontend, the core may keep running headless (policy: do **not** kill the guest on detach — matches DAP "attach" detach semantics). |
| Stale variable reference (DAP `variablesReference`) after a step | Refs are valid only in the current Stopped epoch; the core stamps each ref with a `stop_epoch` and rejects stale ones with a clean error. |

**Note (shared FS):** per the memory note *session FS isolation = caller's job* and `session.zig`
header, two sessions share the host mount dir by design; that is orthogonal to multi-frontend
(which is multiple clients of **one** session/machine).

---

## 7. E. Source-line stepping algorithm

All four step kinds are **host-side loops over existing Controller instruction primitives + the
TDS line table**. No new engine surface. The 16-bit segmented reality: the "current line" key is
always the **linear** PC (`Controller.currentLinear`, = `seg_base[CS] +% EIP`), looked up in the
TDS line table after applying `load_para` (research §8). The single (fake) thread means there is
exactly one PC and one BP chain to reason about.

### 7.1 Primitives the algorithm composes

- `Controller.stepInstruction()` — one retired instruction, stops early on a user breakpoint.
- `Controller.stepOver()` — steps over a direct CALL/INT or a whole REP (SP-guarded return),
  falling back to step-into with a reported flag (`controller.zig:1035`).
- `Controller.runToAddress(linear)` — one-shot bp + run.
- Symbol layer: `lineForAddr(linear) -> ?SourceLoc`, `functionForAddr(linear) -> ?Fn`,
  `addrForLine(file,line) -> ?linear`, `entryAddr(fn) -> linear` (post-prologue).

### 7.2 `stepLine` / `next` (step over, stop at next source line)

```
start_loc  = lineForAddr(currentLinear)         // may be null in prologue/no-symbol code
start_sp   = SS:SP  (frame identity)
loop:
    res = Controller.stepOver()                 // skips callee bodies; SP-guarded
    if res.reason is terminal/user-breakpoint: emit Stopped(that); return
    cur = lineForAddr(currentLinear)
    // stop when the line genuinely changed AND we are NOT deeper than where we started
    if cur != null and cur != start_loc and SP >= start_sp:   // same or shallower frame
        emit Stopped(step); return
    // if we returned to the caller (SP > start_sp) and landed on a line, also stop
    if SP > start_sp and cur != null:
        emit Stopped(step); return
```

`stepOver` already does the heavy lifting of *not* descending into calls; the wrapper just keeps
going until the **line table** reports a different line at the same-or-outer frame depth.

### 7.3 `stepIn` (descend into a callee's first line)

```
start_loc = lineForAddr(currentLinear)
loop:
    res = Controller.stepInstruction()          // plain step — DOES enter calls
    if res.reason is terminal/user-breakpoint: emit Stopped(that); return
    cur = lineForAddr(currentLinear)
    if cur != null and cur != start_loc:
        // entered a new function? its first executable line is the stepIn target.
        // (If we stepped into a no-symbol region — e.g. a C runtime call — fall back to
        //  stepLine semantics so we don't strand the user in unsymbolized code.)
        if functionForAddr(currentLinear) has symbols: emit Stopped(step); return
        else: behave as stepLine from here (run out of the unsymbolized callee)
```

Guard: a callee with **no** debug info (C0 startup, library) must not trap the user — detect "no
source for this addr" and degrade to `stepLine` (run back out), reported, never silent.

### 7.4 `stepOut` (run to the caller frame's return)

Directly reuses `stepOver`'s SP-guarded return logic:

```
// unwind one frame: caller return address from the live BP frame
ret_linear = returnAddrOfFrame(0)   // [SS:BP+2] (near) / CS:IP from [BP+2],[BP+4] (far)
guard_sp   = BP + frame_pop         // SP once this frame is torn down
arm one-shot execution_address{ret_linear}, SP-guarded (>= guard_sp)  // exactly stepOver's pattern
Controller.runUntilEvent(...) ; on the guarded hit → emit Stopped(step)
```

`returnAddrOfFrame` reads the stack via the side-effect-free `peekStack`/`peekMem`. Far vs near
is taken from the function's TDS calling-convention (research §7).

### 7.5 `runToLine`

`addrForLine(file,line)` → `linear`; `Controller.runToAddress(linear)`; translate
`target_reached` → `Stopped{kind=step}`. If the line maps to no code, return an `Error` (DAP:
unverified) rather than running forever.

### 7.6 Realities handled

- **Prologue**: a function-entry breakpoint resolves to the **post-prologue** first line
  (`entryAddr`) so BP-relative locals are already valid when the user stops there.
- **Multi-address lines / line spread across segments**: the line table can map one source line
  to several offset ranges; `addrForLine` returns the lowest executable offset; `lineForAddr`
  does an interval lookup. Correlation records tie line ranges to (source,segment) (research §6).
- **IRQ landing mid-step**: an ISR runs at its own CS:IP; the line lookup there has no source
  (or a different module's source), so the "line changed at same frame" test naturally does not
  fire until control returns — same robustness `stepOver` documents for mid-REP IRQs.

---

## 8. F. Mapping tables (DAP / MCP ↔ core)

### 8.1 DAP request/event ↔ debug-core operation/event

| DAP request | Core operation | Notes / gaps |
|---|---|---|
| `initialize` | (handshake) → returns `Capabilities` | core has fixed caps; single-thread |
| `launch` | `attach` (machine already loadable via recipe) | zdos "launch" = load+pause-at-entry (existing `--serve`) |
| `attach` | `attach` | attach to an already-running `--serve` session |
| `configurationDone` | (state Configuring→Stopped-at-entry) | no-op beyond a marker |
| `setBreakpoints` (source) | `clearBreakpointsForSource` + `setBreakpoint{source}` per line | DAP replaces a file's whole set |
| `setFunctionBreakpoints` | `setBreakpoint{function}` | |
| `setInstructionBreakpoints` | `setBreakpoint{addr}` | maps to existing `execution_address` |
| `setExceptionBreakpoints` | *(gap v1)* | no C++ exceptions in the C target; map to fault stop later |
| `continue` | `cont` | async; `Continued` event |
| `next` | `stepLine` | |
| `stepIn` | `stepIn` | |
| `stepOut` | `stepOut` | |
| `stepInstruction` (granularity=instruction) | `stepInstruction` | |
| `pause` | `pause` | preempt path |
| `threads` | (synthetic single `ThreadId.cpu`) | DAP requires ≥1 thread |
| `stackTrace` | `stackTrace` | Tier 1: frame 0 only; full unwind in Tier 3 |
| `scopes` | `scopes` | Tier 2 |
| `variables` | `variables` | Tier 2 |
| `setVariable` | `setVariable` (→ `writeMemory`) | Tier 2 |
| `evaluate` | `evaluate` | Tier 3 (name lookup stub earlier) |
| `readMemory` / `writeMemory` | `readMemory` / `writeMemory` | existing peek/write |
| `disassemble` | (reuse `Controller.disasmWindow`) | existing |
| `terminate` / `disconnect` | `detach` (+ optional reset) | attach-detach keeps guest alive |
| **DAP event** | **Core event** | |
| `stopped` | `Stopped` | reason mapping per §4.6 |
| `continued` | `Continued` | |
| `output` | `Output` | from guest CON capture (`Controller.console`) |
| `breakpoint` | `Breakpoint` | verified/address changed on reload |
| `terminated` | `Terminated` | |
| `exited` | `Exited` | `program_terminated.ret_code` |
| `module` | `ModuleLoaded` | when TDS attaches |
| `thread` | *(n/a)* | single fixed thread, never started/exited |

### 8.2 MCP tool ↔ debug-core operation (proposed)

Existing MCP tools (`mcp_tools.zig`) already cover the instruction layer; the source layer adds a
friendlier subset. MCP is **pull-based**, so there is **no event push** — agents poll `status`.

| MCP tool (existing / **new**) | Core operation | Coverage |
|---|---|---|
| `add_breakpoint` (existing, addr) | `setBreakpoint{addr}` | full |
| **`set_source_breakpoint`** {file,line} | `setBreakpoint{source}` | new |
| **`set_function_breakpoint`** {name} | `setBreakpoint{function}` | new |
| `list_breakpoints` / `clear_breakpoints` (existing) | list / clear | full |
| `run` (existing) | `cont` (sync-blocking variant retained for agents) | MCP keeps blocking-run ergonomics; event surfaced as the tool result |
| `step` / `step_over` (existing) | `stepInstruction` / `stepLine` | partial |
| **`step_line`** / **`step_in`** / **`step_out`** | `stepLine`/`stepIn`/`stepOut` | new |
| **`run_to_line`** {file,line} | `runToLine` | new |
| `read_cpu` (existing) | `registers` | full |
| **`backtrace`** | `stackTrace` | new |
| **`locals`** {frame} | `scopes`+`variables` | new |
| **`whereami`** | `pcLocation` | new |
| **`eval`** {expr,frame} | `evaluate` | new (stub) |
| `read_memory` / `write_memory` (existing) | `readMemory`/`writeMemory` | full |
| `status` (existing) | `stopState` (poll) | **the event substitute for MCP** |

**Gap:** MCP has no server-push, so `Output`/`Stopped` reach an agent only via polling `status`
/ `read_console`. Acceptable: agents are turn-based. If push is later wanted, add an MCP
long-poll or SSE tool that drains the event bus.

---

## 9. G. Transport options & source-tree placement

### 9.1 Where DAP terminates: in-process vs sidecar

**Option A — in-process DAP frontend on the unified server.** Add `src/api/dap.zig` (a DAP
codec, sibling of `mcp.zig`) that speaks DAP framing over a socket (TCP, or stdio bridged by a
~30-line launcher) and translates DAP ↔ the **native core ops/events**. It attaches to the event
bus directly.

- **Pros:** one process; direct event-bus subscription (true async `stopped`); zero extra
  serialization hop; shares the worker/queue/run_control; the "core owns all semantics" rule is
  trivially enforced because the DAP layer only translates. Lowest latency for stepping.
- **Cons:** DAP framing implemented in Zig (modest — it is `Content-Length` + JSON); couples the
  server binary to DAP versioning.

**Option B — sidecar DAP adapter** (a small Node/Python process using an off-the-shelf DAP
library) that drives zdos over the **existing HTTP/JSON + MCP API**.

- **Pros:** zdos stays lean; DAP logic in a language with mature DAP libs; iterate independently.
- **Cons:** **double serialization**; the HTTP API has a frame stream but **no debug-event
  channel**, so the sidecar must **poll** `status` for stops (laggy stepping) *or* we must build
  an event-streaming endpoint anyway; an extra process to ship/debug; strong temptation to put
  debugging logic in the sidecar — **which violates the core-owns-semantics rule**.

**Recommendation: Option A (in-process).** The decisive argument: the core-owns-semantics
constraint *requires* the event bus and source-stepping to live in zdos. A sidecar would either
re-implement semantics (forbidden) or need a new push endpoint regardless — so it buys nothing
over a thin in-process codec while adding a hop and a process. Build the event bus once; attach
the DAP codec, the web UI (it can consume the same events over its existing WebSocket/stream),
and (optionally) an MCP long-poll to it.

### 9.2 Where the core lives in the source tree

Respect the existing `src/debug` (pure, synchronous, no-atomics determinism gate) vs `src/api`
(threaded, atomics-legal) split:

- **Symbol layer:** `src/debug/symbols/` (new) — pure TDS parse + indices + `load_para` map.
  Imports only `std` (+ reads bytes the loader/machine provide). No atomics; snapshot-neutral.
- **Source semantics:** `src/debug/source.zig` (new) — the source-line stepping algorithm,
  breakpoint resolution, unwinding, variable rendering. Sits **above** `Controller`, imports the
  symbol layer + `Controller`. Pure and synchronous, like the rest of `src/debug`.
- **Async / event / session machinery:** extend `src/api` — `src/api/event_bus.zig` (new,
  clockless broadcast), the debug-run owner in `run_control.zig`, the DAP codec `src/api/dap.zig`,
  and the source-tool rows in `mcp_tools.zig`. The neutral `DebugCore` *facade* (§4) is the
  public seam these consume; its pure methods delegate to `src/debug/source.zig`, its async
  methods to the `src/api` worker/event machinery.

This keeps the **protocol-neutral core type definitions** in one place (`src/debug/source.zig`
public API), with frontends in `src/api` translating to/from them — and no DAP/MCP type ever
crossing into `src/debug`.

---

## 10. H. Phasing (Tiers ↔ milestones ↔ DAP subsets)

| Tier | Capability | New work | DAP subset enabled | Milestone |
|---|---|---|---|---|
| **Tier 1** | addr↔symbol↔line; source/function breakpoints; source stepping | symbol layer (addr→line, name→addr, addr→func, `load_para` map); `setBreakpoint{source,function}`; `runToLine`; `stepLine`/`stepIn`/`stepOut`; **event bus + debug-run owner**; `Stopped`/`Continued`/`Output`/`Exited` events; `pcLocation`; `stackTrace` frame-0 only | initialize, launch/attach, setBreakpoints, setFunctionBreakpoints, configurationDone, continue, next, stepIn, stepOut, stepInstruction, pause, threads(1), stackTrace(1 frame), stopped/continued/terminated/exited/output | **D1** |
| **Tier 2** | scopes / variables / types | TDS type graph + member table; BP-relative local decoding; `scopes`/`variables`/`setVariable`; aggregate/pointer expansion via `children_ref` | scopes, variables, setVariable, evaluate(name lookup) | **D2** |
| **Tier 3** | stack unwinding + evaluate | BP-chain multi-frame unwind (near/far per calling-conv); full `stackTrace`; a small C-expression `evaluate` (member/index/deref) | stackTrace (full), evaluate (expressions), readMemory/writeMemory, disassemble | **D3** |

Each tier is shippable: Tier 1 alone gives IDE source breakpoints + source stepping + a working
DAP session (the highest-value slice), reusing the existing instruction-level primitives almost
entirely.

---

## 11. I. Open questions & risks

1. **Conditional-breakpoint determinism.** A `condition`/`hit_condition` is evaluated host-side
   when the underlying `execution_address` bp fires. A **pure** condition (registers + a
   side-effect-free memory peek + a host hit counter) is determinism-safe: it only changes
   *whether the core reports a stop*, never which cycles ran (same property as `target_reached`
   vs `breakpoint`). **Risk:** if a condition ever triggers a guest call (e.g. evaluating a
   function call in the expression), that would charge cycles and violate the prime directive —
   so **v1 forbids side-effecting conditions** (peek-only). Decide the condition grammar with
   this gate explicit.
2. **`evaluate` scope.** How far does expression eval go? v1 = symbol/field/index/deref over the
   peek path (no guest execution). Function-call evaluation ("call `foo(x)` in the inferior") is
   a determinism hazard (it injects a new input mid-session) and is **out of scope** unless
   modeled as an explicit, recorded input.
3. **16-bit stack unwinding without frame pointers.** Tier 3 relies on standard BC++ `-v` BP
   frames (`push bp; mov bp,sp`). **Optimized builds (`-O`) may omit them**; the BaK relink is a
   debug build, but verify. Without BP frames, unwinding past the innermost frame is unreliable —
   fall back to "frame 0 only" and report the limitation rather than fabricating frames.
4. **Multi-frontend control conflicts.** §6 resolves the known cases via `RunControl` arbitration
   + the preempt counter, but the *policy* questions remain: does `detach` of the last frontend
   kill or keep the guest? (proposed: keep — attach semantics). Does a frontend's `pause` while
   another expects to keep running surprise it? (resolved by broadcasting `Stopped` to all). Pin
   these as product decisions.
5. **Source file location / serving to the IDE.** TDS stores source *paths* as they were at
   compile time (DOS 8.3, e.g. `C:\BAK\FOO.C`). The IDE needs the actual files. Need a
   **source-path map** (compile-path → host-path) the frontend supplies, plus possibly a DAP
   `source` request that serves bytes from a host directory. Decide whether the core or the DAP
   frontend owns the path remap (proposed: the symbol layer holds the raw path; the frontend owns
   the remap, since it is IDE-/host-specific and not a debugging semantic).
6. **Stale `variablesReference` epochs.** DAP refs are valid only while stopped; the core stamps a
   `stop_epoch` and rejects stale refs. Confirm DAP clients tolerate the clean error (they
   should — they re-fetch on each stop).
7. **Line-table edge cases not yet pinned in research.** §0 of the research confirms the
   `{line, offset}` entry layout, but the **source-file record (6 bytes)** and **correlation
   record (8 bytes)** field semantics are only "partially resolved." Address↔line for the *main*
   module is solid; multi-file / multi-segment correlation needs a confirming multi-file build
   before Tier 1 can claim full file coverage.
8. **`Output` event fidelity.** `Controller.console()` is a non-clearing capture of guest CON; an
   `Output` event must emit only the *delta* since the last emit (host-side high-water mark), and
   distinguish stdout vs stderr (DOS handle 1 vs 2) if the DOS layer tracks it.

---

## 12. Minimal new engine surface (determinism audit)

**New engine hooks that touch the cycle ledger or the snapshot: none.** The design is composed
entirely from existing primitives:

- Run/step/run-to: `Controller.runUntilEvent` / `stepInstruction` / `stepOver` / `runToAddress`
  and the preemptible burst loop in `worker.zig`.
- Breakpoints: `execution_address{linear}` via `Controller.addBreakpoint`; source/function
  breakpoints **resolve to** that — no new breakpoint kind.
- Inspection: the side-effect-free peek path (`peekMem`, `peekStack`, `cpuSnapshot`,
  `disasmWindow`).
- Mutation: `setReg*`/`writeMem` (a deliberate, recorded input).

**New host-side machinery that is determinism-neutral by construction:**

- The **symbol layer** — pure byte parsing + index building; reads no machine state except the
  deterministic `load_para`; never serialized.
- The **event bus** — a clockless broadcast channel in `src/api` carrying `Event` PODs; touches
  no guest state, charges no cycle, enters no snapshot. (Atomics are legal in `src/api`; they are
  *not* introduced into `src/debug`.)
- The **debug-run owner** — a new `RunOwner` mode reusing the existing `RunControl` arbitration
  and `worker.zig` burst loop. A background run is byte-identical to a blocking one (the burst
  slicing tracks an absolute deadline / fires absolute-coordinate one-shots — the same property
  `worker.zig` already proves for preemptible runs).
- The **`core.onMachineReverted()`** hook — called from `restoreResp` next to `rearmWatches` to
  invalidate live frame/variable caches and (no-op for `load_para`, which is unchanged across a
  restore). Pure host-side cache invalidation; no guest effect.

The one judgment call requiring sign-off (the **single most consequential design decision**):
**making `cont`/`step` truly asynchronous by adding the event bus + a background debug-run owner
to the `src/api` worker model**, rather than keeping today's synchronous blocking-per-command
shape. This reshapes the worker/queue contract (a run now surfaces via an event instead of a
blocking response) and is the linchpin of the whole DAP/MCP-friendly model. Recommendation:
adopt it, reusing the pacer/preempt precedent so the change is additive (the blocking `run`
command can remain for MCP agents that prefer it).

---

## 13. Appendix: key file/function references

The implementer builds primarily on these (all paths absolute under the repo root):

**Top 3 to build on:**

1. `src/debug/controller.zig` — `Controller`: `runUntilEvent` (`:480`), `stepInstruction`
   (`:823`), `stepOver` (`:1035`, the SP-guarded return logic `stepOut`/`next` reuse),
   `runToAddress` (`:888`), `beginRunToAddress`/`runTargetBurst`/`endRunTarget` (`:948`),
   `cpuSnapshot` (`:1472`), `peekMem`/`peekStack` (`:1536`/`:1977`), `disasmWindow` (`:1698`),
   `set*`/`writeMem` (`:1141`). The source-stepping algorithm is a thin host-side wrapper over
   these.
2. `src/api/worker.zig` (`drainOne` `:113`, `runCapPreemptible` `:292`) + `src/api/run_control.zig`
   (`RunControl` `:57`, `beginDebugger`/`endDebugger` `:230`, preempt counter `:270`, published
   status `:290`). The event-driven background run + multi-frontend serialization extend this.
3. `src/debug/breakpoints.zig` — `BreakpointKind.execution_address` + `BreakpointSet` (`:54`),
   `matches`/`currentLinear` (`:154`/`:212`). Source/function/file:line breakpoints resolve to
   `execution_address{linear}`.

**Supporting:**

- `src/machine/run_loop.zig : step` (`:41`) — the burst primitive the Controller drives.
- `src/api/session.zig : Session` (`:201`) — the per-session bundle + concurrency contract;
  `LoadRecipe` (the host-side, re-attached-on-load config the symbol layer is modeled after).
- `src/api/mcp.zig` / `src/api/mcp_tools.zig` — the existing pull-based frontend the source tools
  extend.
- `src/host/run_pacer.zig` + `src/api/stream.zig` — the background-run + server-push precedent the
  event model generalizes.
- `docs/research/borland-bcc3-debug-format.md` — the symbol layer's spec (§0 empirical
  confirmation; §6 line/correlation; §7 types; §8 address/segment model + `load_para`).
```
