# Source-Code Inlining for the Source-Level Debugger (M-S1.5)

**Status:** plan (no code). Zig 0.16, for the zdos deterministic DOS emulator.
Companion to `debug-core-plan.md` and `debug-core-architecture.md`. It extends the
**already-shipped M-S1** source-level debugger (commit `d3d9d24`) so its MCP/HTTP results
carry **source TEXT** (a windowed, line-numbered, active-line-flagged view), not just a
source LOCATION — removing the round-trip where an LLM agent has to open `BB.C` and map
line numbers itself.

> **Prime directive (CLAUDE.md §1): determinism.** Source display is a **pure host-side
> concern**. Every source read happens at LOAD time (or a host-side QUERY-time inspection
> that already charges no cycles) — **never** during guest execution, **never** charging
> the cycle ledger, **never** perturbing `Machine` state or entering `Machine.Snapshot`.
> This is the same boundary the symbol overlay already lives on (`attachOnLoad`).

---

## Table of Contents

1. [Verified research summary (Phase 1)](#1-verified-research-summary-phase-1)
2. [Where M-S1 stands today (ground truth)](#2-where-m-s1-stands-today-ground-truth)
3. [Design decision A — where the source TEXT comes from](#3-design-decision-a--where-the-source-text-comes-from)
4. [Design decision B — transport](#4-design-decision-b--transport)
5. [Design decision C — the concrete API changes (R1/R2/R3/R6)](#5-design-decision-c--the-concrete-api-changes)
6. [Design decision D — milestone fit & sequencing](#6-design-decision-d--milestone-fit--sequencing)
7. [Design decision E — determinism + no-fakes checklist](#7-design-decision-e--determinism--no-fakes-checklist)
8. [Concrete change list, per file](#8-concrete-change-list-per-file)
9. [Test plan](#9-test-plan)

---

## 1. Verified research summary (Phase 1)

Each claim was independently re-verified against PRIMARY sources (the DAP spec + the
actual GitHub repos / gdb-pdb-Delve docs). All five **hold up**; two carry a minor nuance
the plan accounts for.

| # | Claim | Verdict | Source | Evidence |
|---|---|---|---|---|
| 1 | DAP does **not** inline source on a stop; `stackTrace` returns a `StackFrame` + `Source{path, sourceReference}` location only, and source CONTENT comes from a separate `source` request, served only when `sourceReference > 0` | **CONFIRMED** | <https://microsoft.github.io/debug-adapter-protocol/specification> | `StackFrame` has `id,name,source,line,column,…` — no text field. `Source.sourceReference`: "If `sourceReference > 0` the client can use this to retrieve the source via the `source` request." **Nuance:** the discriminator is `sourceReference > 0`, *not* strictly "has no path" — a `Source` may carry both `path` and a nonzero `sourceReference`. The claim's "virtual/decompiled" gloss is the common case, not an exclusive rule. |
| 2 | **dap_mcp** (`KashunCheng/dap_mcp`) has a `view_file_around_line`-style tool rendering line numbers + a `->` arrow on the active line, and its description tells the model to always prefer it for reading code | **CONFIRMED** | <https://github.com/KashunCheng/dap_mcp> | Tool desc: "…**You should ALWAYS prefer this tool if you are reading code.** Because it will show the line number, which is crucial for debugging…". `render.py` emits `f"{line_number} -> {content}"` for the active line. |
| 3 | **mcp-debugger** (`debugmcp/mcp-debugger`) has `get_source_context(file, line, linesContext=5)` returning `{lineContent, surrounding:[{line,content}]}`, and ≈v0.17.0 step commands themselves return active source context | **CONFIRMED** | <https://github.com/debugmcp/mcp-debugger> (`docs/tool-reference.md`, CHANGELOG) | Returns the line + a `surrounding:[{line,content},…]` array; `linesContext` default = 5 ("lines before and after"). CHANGELOG v0.17.0: "every `step_*` response now embeds current source context…". **Nuance:** documented params are `sessionId, file, linesContext` — it uses the session's stopped line, there is **no explicit `line` arg**, and `sessionId` is required. Substance confirmed. |
| 4 | **pwno-mcp** (`pwno-io/pwno-mcp`) offers a COMBINED context snapshot (registers+stack+disasm+source+backtrace) "designed for LLM agents" | **CONFIRMED** | <https://github.com/pwno-io/pwno-mcp> | README: "Fast context snapshots for registers, stack, disassembly, source, and backtrace"; project "designed for LLM agents." |
| 5 | The ±5-line (~11 total) + active-line-marker convention (gdb `list` default 10, pdb 11, Delve ±5) | **CONFIRMED** | gdb <https://sourceware.org/gdb/current/onlinedocs/gdb/List.html>; pdb <https://docs.python.org/3/library/pdb.html>; Delve repo | gdb "By default, ten lines are printed." pdb "list 11 lines around the current line (five before and five after)," current line marked `->`. Delve `source-list-line-count` default 5 (±5). |

**Nothing in the research was overstated enough to invalidate the plan.** The two nuances
*strengthen* the design: (1) confirms DAP itself proves location-only is the norm and text
is a separate concern — so inlining is an additive convenience, never a protocol violation;
(3) confirms the better ergonomic is to use the *stopped* line as the default center and
make an explicit `line` arg optional (we do exactly that).

---

## 2. Where M-S1 stands today (ground truth)

The implementer must read these before coding; cited by `file:line`.

**The neutral DTOs (slice-bearing, worker-side render targets):**
`src/debug/core/core.zig` — `SourceLoc{file_id,path,line}` (`:48`, `path` borrows
`SymbolIndex.sourceFile`), `PcLocation{addr,function,source}` (`:56`),
`StopState{running,kind,pc,…}` (`:88`), `StopKind` (`:86`).

**The SourceDebugger (pure, on the grep-gate):**
`src/debug/core/debugger.zig` — `SourceDebugger{gpa,ctrl,syms,map,specs,…}` (`:101`),
`attachOnLoad(exe,opt_map,psp_seg)` (`:130`, frees+rebuilds the overlay on every load),
`pcLocation()` (`:269`, gated on not-`.running`), `pcLocationUnchecked` (`:274`),
`sourceLocOf(file_id,line)` (`:285`), `projectStop` (`:305`), `stepBurst` (`:460`),
`init`/`deinit` (`:113`/`:117`).

**The flat transport (M-S1 uses flat-flatten ONLY — `debug-core-plan.md §3.1a`):**
`src/api/queue.zig` — caps `DBG_PATH_CAP=128`/`DBG_NAME_CAP=128`/`DBG_MAX_SPECS=64`
(`:245-248`); the pointer-free result PODs `PcLocationResult` (`:520`), `DbgBreakpoint`
(`:540`), `DbgBpListResult` (`:557`), `DbgStopResult` (`:564`); the `q.Command` variants
`dbg_where`/`dbg_set_src_bp`/`dbg_step_*`/`dbg_run_to_line` (`:216-234`) and the matching
`q.Response` arms (`:624-632`). All pass `expectNoPointerFields(q.Response)`
(`src/api/determinism_test.zig:155`, the unchanged gate).

**The worker flatten + handlers (single machine-owning thread):**
`src/api/worker.zig` — `drainOne(…, sd: ?*SourceDebugger)` (`:115`); the load-time host
reads `readHostFile` (`:762`), `sameStem` (`:779`), `attachSymbols` (`:792`, reads EXE/.MAP
off the mount and calls `sd.attachOnLoad`); the flatteners `flattenPc` (`:825`), `flattenBp`
(`:842`), `flattenStop` (`:871`); handlers `dbgWhere` (`:892`), `dbgSetSrcBp` (`:898`),
`dbgStep` (`:935`); the worker's `sd: ?*SourceDebugger` field (`:990`) and the
initial-attach at worker start (`:1000-1010`).

**The off-worker serializers:** `src/api/server.zig` — `writePcLocBody` (`:2840`, shared by
whereami + step `pc`), `writeWhere` (`:2855`), `writeDbgBreakpoint` (`:2861`), `writeDbgStop`
(`:2899`); dispatch at `:2818-2821`.

**The MCP tool catalog:** `src/api/mcp_tools.zig` — `whereami` (`:358`),
`set_source_breakpoint` (`:363`), `set_function_breakpoint` (`:370`),
`list/clear_source_breakpoint` (`:377`/`:382`), `step_line/in/out` (`:388`/`:394`/`:399`),
`run_to_line` (`:404`); `buildCommand` arms (`:1105-1124`), `SrcLineReq` (`:813`),
`fillSrcBp` (`:817`).

**The symbol layer (paths + line tables):** `src/debug/symbols/index.zig` —
`sourceFile(file_id) -> ?[]const u8` (`:347`, "raw compile-time source-file path … path
normalization is the frontend's job"), `sourceFileCount() -> u32` (`:354`),
`fileId(name) -> ?u32` (`:363`, exact-name match). **The symbol layer knows the source
file's *name* (e.g. `"BB.C"`), not its on-disk text** — exactly as `debug_test.zig`'s
header states: "it does NOT read `BB.C` itself … `BB.C` is committed alongside purely as
the human oracle." The on-disk text is therefore an unsolved input this plan supplies.

**The C: mount is the GUEST filesystem — NOT a source location.** `src/main.zig` splits the
program path into a host directory mounted as DOS `C:` + the file name (`dir_path =
program[0..sep]`, `≈:206-208`), and the provision path opens `mount_dir` as the DOS drive
(`server.zig:2098`). That `Io.Dir` is the guest's drive image; it must **not** be assumed to
hold debug source. The TDS records only a source *filename* (`sourceFile` → e.g. `"BB.C"`),
which needn't correspond to any host path. Where the host keeps debug source is a **separate,
explicit machine-setup configuration** (decision A) — that `examples/BB.C` happens to sit
beside `examples/BB.EXE` is incidental and must not be relied on.

**Machine-setup entry points (where the source-root config attaches) — API ONLY, no CLI.**
Source roots are configured exclusively through the **MCP machine-setup tools**, never a CLI
flag (decision A). Two tools carry an optional `source_path`:
- `provision_machine` — `ProvisionArgs{mount_dir,file,cmdtail,drive,cpu}` (`mcp_tools.zig:505`),
  handled at `handleMcpProvision` `server.zig:2073` (opens `mount_dir` `:2098`, builds
  `LoadRecipe` `:2101`) — sets a minted machine's roots at creation.
- `load` — overlays `wire.LoadReq{drive,file,cmdtail}` (`json_wire.zig:69`) onto the
  session recipe (`buildMcpLoad` `server.zig:2534`, `LoadRecipe.overlay` `session.zig:171`,
  the load command serviced by `loadResp` `worker.zig:671`) — sets/updates the **default
  singleton** (`--serve PORT PROGRAM`) session's roots, and any re-load's.

The C: mount (`Server.init(…, mount_dir: Io.Dir)` `server.zig:229` → `Session.init(…, mount_dir)`
`server.zig:237`, the `dir` arg in `api_mod.Server.init(…)` `main.zig:≈250`) is the **GUEST**
drive — a SEPARATE handle from the source roots, which the source tools open independently.

---

## 3. Design decision A — where the source TEXT comes from

**Answer: an EXPLICIT, host-side source search path configured at machine setup — a
separate concern from the C: mount. The TDS-recorded source filename is reduced to its
basename and searched across the configured source roots; first match wins; read host-side
at load time.**

**Why NOT the EXE's mount / co-location.** The C: mount `Io.Dir` is the GUEST filesystem.
Two reasons it must not be the source of debug text: (1) the TDS records only a source
*filename* — often a bare basename (`"BB.C"`), sometimes a compile-time DOS path
(`"C:\PROJ\BB.C"`) — that needn't correspond to any host location; (2) where the host keeps
debug source is orthogonal to where the guest's drive image lives. Inferring text from the
mount would be a fragile coincidence (it works for `examples/` only because the fixture is
co-located by accident). The host source location is therefore **operator-supplied config**.

### A.1 The source search path (machine-setup config)

A host-side **source search path** — an ordered list of one or more host directories — is
provided at machine setup, *separate* from `mount_dir`. Resolution, host-side, at the read
site:

1. Take `SymbolIndex.sourceFile(file_id)` (the compiler-recorded name; normalization is
   "the frontend's job", `index.zig:345-346`).
2. Derive **two** candidate forms: the **relative path** (drop any drive/leading-separator
   prefix, keep inner dirs — `"SRC\UTIL.C"`, with `\`→`/` normalized) and the bare
   **basename** (`"UTIL.C"`).
3. For each configured source root **in order**: try the **relative path first**
   (`readHostFile(gpa, root_dir, io, "SRC/UTIL.C")`), then the **basename**
   (`readHostFile(gpa, root_dir, io, "UTIL.C")`). The first hit (root + form) wins; record the
   **root index** that supplied it.
4. No source path configured, or no candidate hits any root → **omit text, keep the
   location** (`has=false`). Never fabricate, never error the whole `whereami`.

Trying the relative path **before** the basename is what keeps two distinct TDS files that
share a basename apart (finding #5): `SRC\UTIL.C` and `LIB\UTIL.C` resolve to different host
files when the source tree mirrors the recorded structure, instead of both collapsing onto one
`UTIL.C`. The cache is keyed by `file_id` (distinct per TDS file), so even a basename-fallback
collision caches under the correct id — but relative-first avoids the wrong-text case entirely.

The resolver is **decoupled from the C: mount**: it reuses the generic `readHostFile(gpa,
dir, io, name)` helper (`worker.zig:762`) but hands it a **configured source-root `Io.Dir`**,
never `mount.dir`. (`readHostFile` is already dir-agnostic — only the directory argument
changes.)

**Edge cases (explicit):**
- *No source path configured* → every window is `has=false`; locations still resolve. The
  source-window feature is simply inert until a source root is configured. Graceful, no fake.
- *Basename collision across roots* (same filename in two roots) → **first-match-wins** by
  (root order, relative-then-basename). The window carries the **root INDEX** (`root: u8`,
  `has_root`) — **never a host path** (finding #9: no operator filesystem layout on the wire)
  — so the agent can re-order roots if it picked the wrong one.
- *Same-basename, different `file_id`* (e.g. two `#include`d `UTIL.C`s, finding #5) → the
  relative-path-first probe (step 3) resolves each to its own host file; basename fallback is
  only used when no relative form exists.
- *Recorded name not found in any root (any form)* → `has=false`, location preserved.
- *File over the per-file cap (A.5)* → not cached, `has=false`. Graceful.

**Future extension (noted, not designed here):** a DAP-style **source map**
(compile-time-path → host-path) is the natural successor for projects whose recorded paths
must map non-trivially to the host tree. The search-path mechanism is the M-S1.5 baseline;
the resolver is the seam a source-map would later slot into.

### A.2 How the config is passed at each setup entry point

**Source roots are PER-MACHINE only, configured through the API — NO CLI flag, no global /
registry-wide default (finding #7, reversed; CLI removed).** A session's source roots come
from exactly one place: an MCP machine-setup tool — `load source_path` for the default
singleton session, or `provision_machine source_path` for a minted session. They are never
set on the command line, never shared, never inherited.

- **MCP `load` — the default singleton's (and any re-load's) roots.** Add an optional
  `source_path` argument (a host dir, or a list) to the `load` tool schema
  (`mcp_tools.zig:320`) and to `wire.LoadReq` (`json_wire.zig:69`, as `?[]const u8` — it is a
  per-request **arena/wire struct**, NOT the pointer-free queue POD `LoadCmd`, so a string
  field is fine and never crosses the queue). The `load` front-ends already overlay
  `wire.LoadReq` onto the session recipe (`buildMcpLoad` `server.zig:2534` / HTTP `handleLoad`
  `server.zig:1670`); **alongside that overlay**, the server (listener thread) opens each
  `source_path` entry as an `Io.Dir` and **swaps the Session's source-root field** (closing
  the prior roots, under `session.lock`) **before** submitting the `.load` command. The worker
  then services `.load` via `loadResp` (`worker.zig:671`) → `attachSymbols`, which reads from
  the now-current Session roots. `source_path` is **not** added to `LoadRecipe`/`LoadCmd`
  (those stay pointer-free): the roots are Session state applied server-side, not recipe
  fields. `--serve PORT PROGRAM` thus configures source via a `load{file:"PROG.EXE",
  source_path:"…"}` call (or relies on the default empty roots → `window.has=false`).
- **MCP `provision_machine` — a minted machine's roots at creation.** Add the same optional
  `source_path` to `ProvisionArgs` (`mcp_tools.zig:505`) + its input schema
  (`mcp_tools.zig:419`). `handleMcpProvision` (`server.zig:2073`) opens each as an `Io.Dir`
  (mirroring the `mount_dir` open at `server.zig:2098`) and passes the root list into
  `SessionRegistry.create` → the minted `Session`.
- **A machine with no configured `source_path` shows no source text** (`window.has=false`) —
  the documented, non-surprising behavior; there is **no** fallback to a shared/CLI default.
- **Session + the TWO worker-spawn sites (finding #4).** Add a session-owned, bounded
  **source-root field** (ordered list of opened `Io.Dir` + a bounded `root_index→basename`
  for display, `MAX_SOURCE_ROOTS` ≈ 8), lifetime = the session, closed in `Session.deinit`
  (and on each `load`-swap). It is **always per-Session** (never a shared default), fed only
  by `load`/`provision_machine source_path`. It is handed to the **worker** via a new field
  (a pointer/reference to the Session's roots) beside `Worker.mount_dir`, and that field
  **must be set at BOTH** `Worker` construction sites that already set `.sd`/`.mount_dir`:
  `server.zig:386` (default session) **and** `session_registry.zig:238-251` (the provisioned
  session — `.sd = session.source_debugger` at `:247`, `.mount_dir = session.mount_dir` at
  `:241`). The eager attach (`attachSymbols`) runs against the worker's own fields, so missing
  the registry site would make every provisioned machine — the headline `provision_machine
  source_path` goal — load symbols but resolve every window `has=false`.

### A.3 Read site, ownership, lifetime — EAGER at load (recommended)

Extend `attachSymbols` (`worker.zig:792`): **after** `sd.attachOnLoad(…)` succeeds and the
symbol overlay exists, loop `0..sd.sourceFileCount()`, and for each file id resolve the
basename across the configured source roots (A.1) and, on a hit, hand the owned bytes to the
core via `sd.cacheSource(file_id, basename, bytes)`, which **copies** them into a
SourceDebugger-owned buffer + builds a line-offset index; free the temp read buffer. Misses
are skipped (window `has=false`).

The cache lives **inside the `SourceDebugger`** (host-side, outside the machine), with the
**same lifetime as the symbol overlay**: freed and rebuilt by `attachOnLoad` on every
`load`/`reset+load`, freed in `deinit`. This is byte-for-byte the overlay pattern — all
host I/O is on the worker (`src/api`, Io legal); the pure core only **stores and renders**
owned bytes (no Io, gate-clean). The worker passes the configured source roots into
`attachSymbols` (it already receives the mount via `MountSource`; the source roots ride
alongside).

Why eager-at-load and not lazy-at-query:

- **Simplest control flow + most obviously deterministic.** All host I/O is confined to the
  load path (`attachSymbols`); thereafter the window render is a pure in-memory slice op. No
  host read ever happens inside a `whereami`/`step` `drainOne` turn.
- **Lazy is a valid alternative** (read+cache the file on first window request — still
  query-time, still cycle-neutral since `whereami` already charges no cycles, and the worker
  still holds the source roots). Lazy avoids reading source files that are never displayed.
  Prefer lazy **only** if eager cache pressure becomes real (large multi-file C++ builds).
  **This plan recommends eager; the cache API (`cacheSource`/`sourceWindow`) and the
  search-path resolver are identical either way**, so eager↔lazy is a worker-side detail that
  does not change the wire shape or the config.

### A.4 Determinism confirmation (CLAUDE.md §1)

- The read is **load-time host I/O** (or, in the lazy variant, a host-side inspection that
  charges zero cycles) from the **configured source roots** — never the per-cycle path, and
  never from the guest's running drive image. CLAUDE.md §1 governs *emulated* time; this
  introduces **no cycle-time host dependency**.
- It **does not touch** `Machine` state, registers, RAM, or the cycle ledger, and the cache
  **never enters `Machine.Snapshot`** (SourceDebugger-owned host state, like `syms`/`map`).
- The bytes are a pure function of the on-disk files in the configured roots at load — the
  same binary + same roots yields byte-identical windows; the resolver order is fixed config,
  so first-match is deterministic.
- A source-file edit (or a roots re-order) on the host between runs changes only the
  *display*, never machine state or stop decisions (the stop is keyed on the line table /
  linear PC, not the text).

### A.5 Caching

One bounded table in the `SourceDebugger`: `MAX_CACHED_SOURCES` slots, each
`{file_id, root_index, bytes: []u8 (owned), line_starts: []u32 (owned)}`. Caps:
`MAX_SOURCE_BYTES` per file (e.g. 256 KiB) and a total budget. Freed/rebuilt in
`attachOnLoad`/`deinit`. The line-offset index is built once at cache time (scan for `\n`,
strip trailing `\r`), so each window is an O(1) slice lookup.

**Admission is query-order-independent (finding #8).** The eager `attachSymbols` loop walks
`file_id` in **ascending order** and, when a file would push past the per-file cap or the
total budget, it is **SKIPPED** (`has=false`, graceful) — a previously-admitted file is
**never evicted**. This is a fixed, ascending-`file_id` admission policy, **not** an
access-order LRU: which files are cached is a pure function of `(file_id order, sizes,
budget)`, independent of which windows the agent requests and in what order. That is what
makes A.4's "byte-identical windows every run" hold even in the lazy variant (lazy must use
the **same** ascending-`file_id` admission decision, not first-touch order).

---

## 4. Design decision B — transport

**Recommendation: transport (a) — a BOUNDED fixed-cap flat POD (the
`DisasmResult`/`DisasmInsn` pattern), keeping `whereami`/step on the existing
flat-flatten path. NOT the M-S2 worker-side-JSON seam.**

### B.1 Why flat-flatten (a), not nested-serialize (b)

- A source window is **bounded by a hard MAX** of fixed-cap text lines. Even though the
  window size is now **requestable** per call (a `context` param, §B.2), it is capped at a
  generous compile-time MAX and a request above it is **clamped + flagged** — never an
  unbounded shape. This is the exact situation where a fixed cap is *faithful*, unlike a
  struct/array tree whose caps would force a **silent truncation of meaningful data**
  (forbidden by CLAUDE.md §2, the reason `debug-core-plan.md §3.1a` routes
  `backtrace`/`locals` through the nested seam).
- `whereami` (`PcLocationResult`), the steps (`DbgStopResult`), and breakpoint confirms
  (`DbgBreakpoint`) are **already** flat PODs serialized off-worker by `writeX`
  (`server.zig:2840-2914`). Embedding the window as another flat sub-POD keeps them on that
  path with **zero new transport machinery** — this is the whole point of an "M-S1.5" that
  does not need M-S2's nested seam.
- The flat POD passes `expectNoPointerFields(q.Response)` (`src/api/determinism_test.zig:155`)
  by construction (integers + bools + fixed arrays only), so the gate stays unchanged.

### B.2 Caps — a requestable window with a hard MAX (chosen + justified)

The window size is a per-call parameter (`context` = lines above and below; default 5,
§5/R1/R2). A requestable window is **no longer fixed at 11 lines**, which forces a transport
decision. **Chosen (PREFERRED): keep the flat-flatten POD with a generous hard MAX; clamp a
larger request and surface the clamp** — so M-S1.5 stays self-contained (no nested seam).

- `DBG_CONTEXT_DEFAULT = 5` — the ±5 (≈11-total) convention verified across gdb (10), pdb
  (11, with a `->` marker), and Delve (±5). Used when the caller omits `context`.
- `DBG_WINDOW_LINES_MAX = 33` — the hard cap on total lines in one window POD (so `context`
  is effectively clamped to `(MAX-1)/2 = 16` each side). A request for more is **clamped to
  MAX**, and the window sets `clamped = true` (see B.3) — **not silently dropped**. To read
  **more than MAX** lines, the agent **pages** via `read_source` at successive center lines
  (an explicit, agent-driven range walk), keeping any single response bounded. (A future
  `read_source` `{start_line,end_line}` range variant is a trivial extension; not M-S1.5.)
- `DBG_SRC_LINE_CAP = 160` bytes of (transcoded) text per line — comfortably covers DOS/C
  source; longer lines are truncated **explicitly** (see B.3).

**Cap sizing (interacts with finding #1).** A `SourceLine` is ≈`8 + DBG_SRC_LINE_CAP` bytes;
a `SourceWindow` is ≈`DBG_WINDOW_LINES_MAX × (8 + DBG_SRC_LINE_CAP)`. The POD is **always
max-sized** (copied by value on every command), so the caps are chosen to **roughly halve**
the prior 64×200 (~13.3 KB) sizing: `33 × (8+160) ≈ 5.5 KB`. Two windows still ride a single
`whereami`/step response without strain (`RESPONSE_BUF = 48 KiB`, `server.zig:67`). Critically
the window rides **only single-frame results** — never a `[64]` list row (§B.5 / finding #1).

### B.5 The window rides single-frame results ONLY — never the `[64]` list row (finding #1)

`DbgBreakpoint` (`queue.zig:540`) doubles as the row type of `DbgBpListResult`
(`items:[DBG_MAX_SPECS]DbgBreakpoint`, `queue.zig:557`). Embedding a ~5.5 KB `SourceWindow`
in `DbgBreakpoint` would make `DbgBpListResult` ≈`64 × 5.5 KB ≈ 350 KB`, copied **by value
for every command** (the `q.Response` union is sized to its largest variant). **Therefore:**

- `DbgBreakpoint` (the list row) stays **window-free**.
- The breakpoint **SET-confirm** (R6) gets its **own** result POD that carries the window —
  `DbgBpSetResult{ bp: DbgBreakpoint, window: SourceWindow }` — returned only by the
  single-result `dbg_set_src_bp`/`dbg_set_fn_bp` arms.
- `dbg_bp_list` keeps returning the bare `DbgBpListResult` (no window).

So the window lives on exactly the **single-frame** results: `whereami` (`PcLocationResult`),
the steps/stop (`DbgStopResult`), the set-confirm (`DbgBpSetResult`), and the standalone
`dbg_source` — never on a multi-row list.

**Rejected alternative:** routing `read_source` through the worker-side-JSON nested seam to
serve arbitrarily large reads in one call. That would move `read_source` to **M-S2** (it
needs the nested transport that M-S2 introduces), losing M-S1.5's self-containment. Paging a
flat, MAX-bounded window is strictly simpler and ships now — recommended unless a single
arbitrarily-large read becomes a hard requirement.

### B.3 Truncation / clamp policy (EXPLICIT — no silent smear, CLAUDE.md §2)

- **Long line:** copy the first `DBG_SRC_LINE_CAP` bytes (of the **transcoded** text, §5/R1)
  and set `truncated = true` on that line. Nothing is silently lost.
- **Line splitting / CRLF:** lines are split on `\n`; a **trailing `\r`** (DOS CRLF source)
  is stripped before the line is stored, so a CRLF file does not leak a stray `\r` into every
  line's text. The split + `\r`-strip happen once at `cacheSource` time.
- **Oversize request (`2*context+1 > DBG_WINDOW_LINES_MAX`):** clamp the window to the MAX
  centered on the active line and set `clamped = true`, so the agent knows it asked for more
  than one response can carry (and should page via `read_source`).
- **`context = 0`:** the window is exactly the **active line** (one row, `count = 1`).
- **Window edges:** at file start/end the window simply has fewer lines; `count` reflects the
  real number and each line carries its true 1-based `number`, so the agent can tell it is at
  a boundary (smaller count, **not** a clamp — `clamped` stays false).
- **Active-line marker:** a structured `active: bool` per line (cleaner for an LLM than an
  embedded `->` glyph; the serializer/description still notes the convention). The active
  line is the location's `line`.
- **Encoding:** the byte→text transcode (CP437→UTF-8, TAB handling) is **specified in the
  `writeSourceWindow` serializer spec** (§5/R1, finding #2) so the wire body is always valid
  UTF-8 — the one place CLAUDE.md §2 "no silent smear" is at risk.
- **File absent / not cached:** `has = false`; the location stands alone (decision A).

### B.4 The flat POD shape (`queue.zig`)

```zig
pub const DBG_CONTEXT_DEFAULT = 5;    // ±5 ≈ 11 total (gdb/pdb/Delve convention, verified)
pub const DBG_WINDOW_LINES_MAX = 33;  // hard cap on rows in one window (context ≤ 16/side)
pub const DBG_SRC_LINE_CAP = 160;     // bytes of UTF-8 text per line; longer ⇒ truncated=true

pub const SourceLine = struct {
    number: u32 = 0,                 // 1-based source line number
    active: bool = false,            // the location's line (whereami/step/bp center)
    truncated: bool = false,         // text exceeded DBG_SRC_LINE_CAP (explicit)
    len: u16 = 0,                    // valid bytes in `text` (UTF-8, transcoded)
    text: [DBG_SRC_LINE_CAP]u8 = undefined,
};

pub const SourceWindow = struct {
    has: bool = false,               // false ⇒ no text (file absent / no symbols / no line)
    clamped: bool = false,           // requested context exceeded DBG_WINDOW_LINES_MAX
    has_root: bool = false,          // a configured source root supplied the text
    root: u8 = 0,                    // INDEX into the configured roots (NOT a host path) — #9
    file_id: u32 = 0,
    active_line: u32 = 0,
    count: u8 = 0,                    // valid rows in `lines`
    lines: [DBG_WINDOW_LINES_MAX]SourceLine = undefined,
};

/// R6 breakpoint SET-confirm (single result) — carries the window. The list row
/// `DbgBreakpoint` stays window-free so `DbgBpListResult` does not balloon (finding #1).
pub const DbgBpSetResult = struct { bp: DbgBreakpoint, window: SourceWindow = .{} };
```

All integers/bools/fixed arrays → passes the reflection gate. The window rides as a sub-field
of the single-frame flat results (`PcLocationResult`, `DbgStopResult`, `DbgBpSetResult`) and
as the standalone `dbg_source` response — **never** the `[64]`-row `DbgBpListResult` (§B.5).
`root` is a bounded index, never a host path string (finding #9 — no operator filesystem
layout on the wire).

---

## 5. Design decision C — the concrete API changes

All changes are **ADDITIVE** — every existing field stays. The neutral core produces a
slice-bearing `core.SourceWindow` DTO (borrowed `[]const u8` line slices into the cache,
Stopped-epoch/program-scoped, exactly like `SourceLoc.path` borrows today); the worker
flattens it into the `q.SourceWindow` POD with `flattenWindow` (the `flattenPc` sibling).

### R1 — embed a requestable source window in `whereami` AND every step/stop response

- Add `window: q.SourceWindow = .{}` to **`PcLocationResult`** (`queue.zig:520`) and to
  **`DbgStopResult`** (`queue.zig:564`, or reuse the embedded `pc.window`).
- **`context` is requestable here too** (symmetric, lines above and below; default
  `DBG_CONTEXT_DEFAULT = 5`). The previously-`void` commands `dbg_where` (`queue.zig:218`),
  `dbg_step_line`/`dbg_step_in`/`dbg_step_out` (`:228-232`) now carry it: change them to a
  tiny POD `DbgStepReq{ context: u8 = DBG_CONTEXT_DEFAULT }`, and add `context` to the
  `dbg_run_to_line` arg (`DbgSrcBpCmd`). `buildCommand` parses the optional `context`,
  defaults to 5, and clamps to the MAX before filling the command (the worker also clamps,
  defence-in-depth). These tools' schemas move from `SCHEMA_EMPTY` to an object with one
  optional `context` (integer, min 0).
- In the worker: after `pcLocation()`/`projectStop()` yields a `PcLocation` whose `source`
  resolved, call `sd.sourceWindow(file_id, line, context)` and fill the window in
  `flattenPc`/`flattenStop`. No source → `has=false`.
- Active line = `source.line`. Applies to `whereami`, `step_line`, `step_in`, `step_out`,
  `run_to_line`.
- Serializer: a new `writeSourceWindow` called from `writePcLocBody` (`server.zig:2840`) so
  both `writeWhere` and `writeDbgStop` get it for free. Shape:
  `"window":{"has":true,"clamped":false,"root":0,"file_id":0,"active_line":9,"lines":[{"number":4,"active":false,"truncated":false,"text":"int g_frames;"},…]}` (or `"window":null` when `has=false`).

**Encoding — the `writeSourceWindow` / `cacheSource` text spec (finding #2, CLAUDE.md §2).**
DOS source is **CP437**, not UTF-8: feeding raw `text:[N]u8` through
`std.json.Stringify.encodeJsonString` (`server.zig:2845` pattern) emits high bytes
(`0x80..0xFF`) **raw → invalid-UTF-8 JSON** that strict MCP clients reject; turning on
`escape_unicode` would `utf8Decode catch unreachable` **panic** on a lone CP437 byte. So the
transcode is mandatory and is done **once, at `cacheSource` time** (storing already-UTF-8
bytes in the cache, so `len`/`DBG_SRC_LINE_CAP` count UTF-8 bytes and the serializer just
emits a valid string):
  - **CP437 → UTF-8** for every byte (the standard CP437 table maps `0x00..0xFF` to Unicode
    scalars; ASCII `0x20..0x7E` is identity). This guarantees a valid-UTF-8 body without
    `escape_unicode`. (A simpler conforming fallback, if a full CP437 table is deferred:
    emit bytes `≥0x80` as the U+FFFD replacement char — still valid UTF-8, never a panic —
    but the CP437 table is preferred so box-drawing/accented source renders faithfully.)
  - **TAB (`0x09`):** **expand to spaces** to a fixed tab stop (e.g. 8) at cache time — chosen
    over escaping so the agent sees aligned columns; stated explicitly (one policy, no smear).
    (`\r` is already stripped, other C0 controls are rare in source; pass them to
    `encodeJsonString`, which escapes them as `\u00XX` safely.)
  - Because the stored line is UTF-8 and `DBG_SRC_LINE_CAP` truncates on a **UTF-8 boundary**
    (never mid-codepoint), `truncated=true` lines stay valid UTF-8 too.

### R2 — a dedicated `read_source` tool (read code the agent is NOT stopped in)

- New `q.Command` `dbg_read_source: DbgReadSrcCmd{ has_file_id:bool, file_id:u32,
  file:[DBG_PATH_CAP]u8, file_len, line:u32, context:u8 }` and `q.Response`
  `dbg_source: SourceWindow`. `context` defaults to `DBG_CONTEXT_DEFAULT`.
- **Addressing shares ONE namespace with the window resolver (finding #3).** `whereami`/steps
  return a `file_id`; `read_source` accepts an optional `file_id` so the agent can **echo
  back exactly what it saw** (the robust path). When only a `file` name is given, the worker
  resolves it via a **unified `sd.fileIdForName(name)`** that tries the strict exact
  `SymbolIndex.fileId` (`index.zig:363`, `std.mem.eql`) **then** a new
  `SymbolIndex.fileIdByBasename` fallback — so a full-path-recorded TDS name (`C:\PROJ\BB.C`)
  whose window resolver succeeded does **not** make `read_source` miss on `fileId("BB.C")`.
  Both the eager cache (keyed by `file_id`) and `read_source` thus speak the same id space.
- Worker handler `dbgReadSource`: pick `file_id` (echoed or resolved via `fileIdForName`),
  clamp `context` so `2*context+1 ≤ DBG_WINDOW_LINES_MAX` (set `window.clamped` when it bit),
  call `sd.sourceWindow(file_id, line, context)`. Unknown name/id → `err.unresolved`; no
  symbols → `err.no_symbols`. **Not gated on Stopped** — a pure host-side cache read.
- MCP tool `read_source` (`mcp_tools.zig`), arm in `buildCommand` reusing the `SrcLineReq`
  +`fillSrcBp`-style copy (`mcp_tools.zig:813-817`); the schema is
  `{file?:string, file_id?:integer, line:integer≥1, context?:integer≥0 (default 5, clamped to MAX; page for more)}`
  (require at least one of `file`/`file_id`).
- **Description borrows dap_mcp's wording** (verified claim 2): *"Read guest source code with
  line numbers and the active line flagged. ALWAYS prefer this tool when you need to read the
  guest's source — it returns numbered lines so you never have to guess line positions. Pass
  the `file_id` from whereami (or a file name from list_sources). `context` sets the lines
  above/below (default 5); for a window larger than the per-call MAX, call again at a later
  line to page. Use `whereami`/the step tools for the source at the current stop instead."*
- Serializer `writeDbgSource` = bare `writeSourceWindow`.

### R2b — `list_sources` (source-file discovery, finding #6 — needed to make R2 usable)

The agent only ever sees the **current** file (via `whereami`); to read a file it is *not*
stopped in, it must learn what files exist. Add a tiny discovery tool:

- New `q.Command` `dbg_list_sources: void` → `q.Response` `dbg_sources: SourceFilesResult`,
  a flat POD `{ count:u32, items:[DBG_MAX_SOURCES]{ file_id:u32, path:[DBG_PATH_CAP]u8,
  path_len:u8, cached:bool } }` — a thin pass-through over the `sd.sourceFileCount()` /
  `sd.sourceFileName(file_id)` accessors already added in §8, plus `cached` = "text is in the
  source cache" (so the agent knows which files have windows). Bounded → flat-flatten.
- MCP tool `list_sources` (empty schema), `buildCommand` arm, serializer `writeDbgSources`.
  Description: *"List the guest program's source files {file_id, path, cached}. Pass a
  `file_id` to read_source to view any of them."* Ships in **M-S1.5** (it is what makes R2
  usable). `path` is the TDS-recorded name (not a host path) — no operator layout leak.

### R3 — combined "context" call (forward-looking, lands in M-S2)

A single call returning {top frame `PcLocation` + source window} **+ backtrace + top-frame
locals} — the pwno-mcp "context snapshot for LLM agents" ergonomic (verified claim 4).

- The **frame + source-window** parts are available **now** (flat-flatten).
- **`backtrace` (N frames) and `locals`/`scopes` are M-S2** — they are unbounded/variable
  and must ride the **nested-serialize-on-worker** seam (`debug-core-plan.md §3.1a`,
  Category B). So R3 is **designed now, implemented in M-S2**: a `context` tool whose worker
  handler serializes one JSON body that **embeds the same source-window bytes** (produced by
  the same `sourceWindow` render) alongside the worker-serialized backtrace/locals. No new
  source-window work in M-S2 — it reuses R1's render. Document the field layout now so the
  M-S2 body is `{frame, window, backtrace:[…], locals:[…]}`.

### R6 — self-describing breakpoint placement (window on the SET-confirm only, finding #1)

- `set_source_breakpoint`/`set_function_breakpoint` already return `verified` + the relocated
  `line` in `DbgBreakpoint` (`queue.zig:540`, `flattenBp` `worker.zig:842`). The window goes
  on a **new single-result POD `DbgBpSetResult{ bp: DbgBreakpoint, window: SourceWindow }`**
  (§B.4/§B.5) returned by the `dbg_set_src_bp`/`dbg_set_fn_bp` arms — **NOT** on `DbgBreakpoint`
  itself, because that type is the row of the `[64]` `DbgBpListResult` and a window there would
  balloon the list to ~350 KB copied per command (finding #1). `DbgBreakpoint` and
  `DbgBpListResult` stay window-free.
- The window is filled at the **bound** line (`active = bp.src_line`) so the agent visually
  confirms placement (set `BB.C:9` → window centered on the resolved line, line 9 active). New
  serializer `writeDbgBpSet` = `writeDbgBreakpoint(bp)` + `writeSourceWindow(window)`;
  `writeDbgBreakpoint` (`server.zig:2861`) and `writeDbgBpList` are unchanged (still
  window-free).
- `verified=false` (line mapped to no code / name not found) → `window.has=false`; the
  existing fields are unchanged.

### Description updates (all four families)

Update the `whereami`/`step_*`/`run_to_line`/`set_*_breakpoint` descriptions
(`mcp_tools.zig:358-409`) to note "the response now embeds a `window` of numbered source
lines around the active line (`active:true`); pass `context` (default 5) to widen/narrow
it", echoing mcp-debugger's v0.17.0 step-embeds-context ergonomic (verified claim 3). The
`whereami`/`step_*` schemas gain the optional `context` field (no longer `SCHEMA_EMPTY`);
`set_*_breakpoint`'s placement window uses the default context. Point `read_source` at
`list_sources` for discovery and at the `file_id` whereami returns.

---

## 6. Design decision D — milestone fit & sequencing

**M-S1.5 (this plan) is a small, self-contained milestone that does NOT need the M-S2 nested
transport** — because transport (a) was chosen (decision B). Ordering:

- **M-S1.5 — source-window inlining (this plan):** the source-search-path config + cache +
  the `SourceWindow` flat POD + R1 (whereami/steps) + R2 (`read_source`) + R2b
  (`list_sources`, makes R2 usable) + R6 (breakpoint set-confirm placement). All on the
  existing flat-flatten path. Ships **independently of M-S2**.
- **M-S2 — nested seam (`scopes`/`locals`/`variables`/`backtrace`):** unchanged from
  `debug-core-plan.md §8`. Brings the worker-side-JSON body.
- **R3 — combined `context` call:** lands in **M-S2**, embedding M-S1.5's source-window
  render into the nested body.

Dependency edges: M-S1.5 depends only on shipped M-S1 + the symbol layer. R3 depends on
M-S2's nested seam **and** M-S1.5's `sourceWindow`. So sequence: **M-S1.5 → M-S2 → R3**.

---

## 7. Design decision E — determinism + no-fakes checklist

The implementation MUST satisfy all of:

- [ ] **Host-side reads only, off the per-cycle path, from the CONFIGURED source roots.**
      Source text is read via `readHostFile` (`worker.zig:762`) against the operator-supplied
      **source search path** (decision A) — never the C: mount, never the guest drive image —
      at LOAD time (eager) or a cycle-neutral host QUERY (lazy). Never inside the guest run
      loop; never charges the cycle ledger.
- [ ] **No machine perturbation.** The window path touches no registers/RAM/devices and does
      not advance cycles; `Controller.cpuSnapshot()`/`snapshot()` stay byte-identical across
      a window read.
- [ ] **No source text in `Machine.Snapshot`.** The cache and the source-root handles are
      SourceDebugger/Session-owned host state (lifetime = program/session), freed/rebuilt by
      `attachOnLoad` / closed in deinit; they never serialize.
- [ ] **Bounded buffers, EXPLICIT truncation + clamp.** `DBG_WINDOW_LINES_MAX`/
      `DBG_SRC_LINE_CAP` cap the window; a clipped line sets `truncated=true`, an oversize
      `context` request sets `clamped=true`, an edge sets a smaller `count` — no silent smear
      (CLAUDE.md §2). `context` defaults to `DBG_CONTEXT_DEFAULT = 5`.
- [ ] **Pointer-free PODs pass the reflection gate (BOTH unions).** `SourceWindow`/
      `SourceLine`/`DbgBpSetResult`/`SourceFilesResult` (Response) and the new `{context}`
      command fields / `DbgReadSrcCmd` / `dbg_list_sources` (Command) are integers/bools/fixed
      arrays only; **both** `expectNoPointerFields(q.Command)` and `(q.Response)`
      (`api/determinism_test.zig:155`) stay unchanged and green. Source-root `Io.Dir` handles
      live on the Session/worker, never on a Command/Response.
- [ ] **Graceful absence, never a fake.** No source path configured / basename in no root /
      over cap / no symbols / line maps to no code → `has=false`, location preserved. Never
      fabricate text or a line number.
- [ ] **Core stays grep-gate clean.** The render in `src/debug/core` does NO Io, no host
      clock/RNG/thread/atomic, no float, no HashMap — it slices owned bytes. All host I/O is
      in the worker (`src/api`). New core code stays on the `src/debug/determinism_test.zig`
      sources/grep gate (already wired for `core/*.zig`).
- [ ] **No host float in any render** (line numbers/offsets are integers).

---

## 8. Concrete change list, per file

**`src/debug/core/core.zig`** — add the neutral (slice-bearing) window DTO + size consts:
```zig
pub const SrcLine = struct { number: u32, text: []const u8, active: bool, truncated: bool };
pub const SourceWindow = struct {
    file_id: u32, active_line: u32, clamped: bool, root_index: ?u8 = null,
    lines: []const SrcLine,
};
pub const DEFAULT_SOURCE_CONTEXT: u8 = 5;     // ±5 ≈ 11 (gdb/pdb/Delve, verified)
pub const MAX_WINDOW_LINES: u8 = 33;          // hard cap (mirrors q.DBG_WINDOW_LINES_MAX)
```

**`src/debug/symbols/index.zig`** — add `pub fn fileIdByBasename(self, name) ?u32` (basename
match — the relaxed sibling of the strict-`eql` `fileId` at `:363`) so `read_source`'s name
lookup and the window resolver share one id space (finding #3). Pure, integer-only, on both
gates.

**`src/debug/core/debugger.zig`** — add to `SourceDebugger`:
- A bounded source cache field (`MAX_CACHED_SOURCES` slots: `{file_id, root_index:u8,
  bytes:[]u8 owned (UTF-8, transcoded), line_starts:[]u32 owned}`), from `self.gpa`.
- `pub fn cacheSource(self, file_id, root_index, bytes) void` — **transcode CP437→UTF-8,
  expand TABs, strip trailing `\r`** (the §5/R1 spec) while copying, build the `\n`
  line-offset index. **Admission: SKIP over the per-file/total budget in ascending `file_id`
  order — never evict a previously-admitted file** (finding #8), so the cached set is
  query-order-independent.
- `pub fn sourceWindow(self, file_id, line, context) ?SourceWindow` — clamp `context` so
  `2*context+1 ≤ MAX_WINDOW_LINES` (set `clamped`; `context==0` ⇒ active line only), set
  `root_index` from the cache slot, slice the lines into a caller/scratch `SrcLine` buffer
  (borrowed slices into the cache); null when the file is not cached.
- `pub fn fileIdForName(self, name) ?u32` — exact `index.fileId` **then** `fileIdByBasename`
  fallback (finding #3); `pub fn sourceFileCount(self) u32` / `sourceFileName(self, file_id)
  ?[]const u8` — pass-throughs over `index` so the worker drives the eager read + `list_sources`
  + `read_source` name lookup without reaching into `syms`.
- Free the cache in `attachOnLoad` (before rebuild) and `deinit`. (Source-root `Io.Dir`
  handles are NOT held here — Session/worker own them; the core only stores handed bytes.)

**`src/main.zig`** — **no change.** Source roots are API-machine-setup-only; there is no
`--source-path` CLI flag and no empty-start handling for it (CLI removed). `main.zig` arg
parsing is untouched.

**`src/api/json_wire.zig`** — add `source_path: ?[]const u8 = null` (a host dir, or a list) to
`wire.LoadReq` (`:69`). It is a per-request **arena/wire struct**, NOT the pointer-free queue
POD `LoadCmd`, so a string field is fine and never crosses the queue. (Not added to
`LoadRecipe`/`LoadCmd`, which stay pointer-free — the roots are Session state, not recipe.)

**`src/api/session.zig`** — add a session-owned, bounded **source-root field** (ordered list
of opened `Io.Dir` + a bounded `root_index→basename` for `list_sources` display only,
`MAX_SOURCE_ROOTS ≈ 8`) to `Session`; accept it in `Session.init` (`server.zig:237` callsite),
add a **swap helper** (close prior roots, install new — used by `load source_path`), and close
the dirs in `Session.deinit`. (Machine-setup config, not `LoadRecipe`; session-scoped.)

**`src/api/session_registry.zig`** (finding #4) — `create` (`:157`) accepts the per-machine
`source_path` roots and stores them on the minted `Session` (no registry-wide default field —
finding #7 reversed; a machine without `source_path` gets an empty list → `window.has=false`).
**Set the new worker source-roots field at the registry worker-spawn site** — the `Worker{…}`
literal at `:238-251`, right where `.sd = session.source_debugger` (`:247`) and `.mount_dir =
session.mount_dir` (`:241`) are set. (Missing this = provisioned machines load symbols but
every window `has=false` — the headline `provision_machine source_path` regression.)

**`src/api/server.zig`** — thread the source roots through `Server.init` (`:229`) →
`Session.init` (`:237`), and set the new worker source-roots field at the **default**
worker-spawn site (`:386`, beside `.sd`/`.mount_dir`). **`load source_path`:** in **both** load
front-ends — `buildMcpLoad` (`:2534`) and HTTP `handleLoad` (`:1670`) — after the existing
`recipe.overlay(LoadReq)`, if `source_path` is present open each entry as an `Io.Dir` and call
the Session **swap helper** (close prior, install new, under `session.lock`) **before**
submitting the `.load` command, so `loadResp`/`attachSymbols` reads the current roots. In
`handleMcpProvision` (`:2073`, the actual name — not `handleProvisionMachine`) open each
`source_path` root as an `Io.Dir` (mirroring the `mount_dir` open at `:2098`) and pass to
`SessionRegistry.create`. Add `writeSourceWindow(w, win)` (emits `clamped`, `root`); call it
from `writePcLocBody` (`:2840`, covers `writeWhere` + `writeDbgStop`'s `pc`); add `writeDbgBpSet`
(= `writeDbgBreakpoint` + `writeSourceWindow`) for the set-confirm — `writeDbgBreakpoint`
(`:2861`)/`writeDbgBpList` stay window-free (finding #1); add `writeDbgSource` (= bare window)
and `writeDbgSources` (`list_sources`); add `dbg_source`/`dbg_sources`/`dbg_bp_set` dispatch
arms at `:2818`.

**`src/api/queue.zig`** — add `DBG_CONTEXT_DEFAULT=5`/`DBG_WINDOW_LINES_MAX=33`/
`DBG_SRC_LINE_CAP=160`/`DBG_MAX_SOURCES`, the `SourceLine` + `SourceWindow` (with `clamped`,
`has_root`+`root`) + `DbgBpSetResult` + `SourceFilesResult` flat PODs (§4.4/§B.5); add the
`window` field to `PcLocationResult` (`:520`) and `DbgStopResult` (`:564`) — **NOT** to
`DbgBreakpoint` (`:540`, finding #1); change the `dbg_where`/`dbg_step_*` Command variants
(`:218-232`) from `void` to carry `DbgStepReq{context:u8}`; add `context` to `DbgSrcBpCmd`
(`dbg_run_to_line`); add `DbgReadSrcCmd{has_file_id,file_id,file,file_len,line,context}` +
the `dbg_read_source`/`dbg_list_sources` Commands (`:211-234`) + the `dbg_source:
SourceWindow` / `dbg_sources: SourceFilesResult` / `dbg_bp_set: DbgBpSetResult` Responses
(`:624-632`). The set-confirm arms (`dbg_set_src_bp`/`dbg_set_fn_bp`) return `dbg_bp_set`.

**`src/api/worker.zig`** — give the worker (and the attach call) the configured **source
roots**; in `attachSymbols` (`:792`), after `attachOnLoad`, loop `sd.sourceFileCount()` in
**ascending `file_id`**, resolve each recorded name across the roots in order — **relative
path first, then basename** (`readHostFile(gpa, root_dir, io, candidate)` — **NOT**
`mount.dir`, findings #5/#9) — and `sd.cacheSource(file_id, root_index, bytes)` on first hit.
Add `flattenWindow(core.SourceWindow) q.SourceWindow` (copies `root_index`→`root`); call it in
`flattenPc` (`:825`)/`flattenStop` (`:871`) and in a new `flattenBpSet` (set-confirm), passing
the requested `context`. Add `dbgReadSource` (echo `file_id` or `sd.fileIdForName`) +
`dbgListSources` handlers; thread `context` through `dbgWhere`/`dbgStep`; change
`dbgSetSrcBp`/`dbgSetFnBp` to return `dbg_bp_set`; add `dbg_read_source`/`dbg_list_sources`
arms in `drainOne` (`:115`). Lazy variant reads+caches inside those handlers on a miss (the
worker still holds the roots + `io`).

**`src/api/mcp_tools.zig`** — add `read_source` (`{file?,file_id?,line,context?}`) + the new
`list_sources` (empty schema) tool rows + `buildCommand` arms (`:1105-1124`), reusing the
`SrcLineReq`/`fillSrcBp` copy pattern (`:813-817`); add the optional `source_path` to **both**
the `load` schema (`:320`) and the `provision_machine` schema (`:419`) + `ProvisionArgs`
(`:505`) (the `load` schema's `source_path` is consumed server-side via `wire.LoadReq`, not
the queue); change the `whereami`/`step_*` schemas from `SCHEMA_EMPTY` to one optional
`context` and parse it in `buildCommand`; update the descriptions (`:358-409`) to advertise the
embedded `window` + `context`, and the `load`/`provision_machine` descriptions to mention
`source_path` (host source dirs for the inlined window); give `read_source`/`list_sources` the
dap_mcp-style "ALWAYS prefer this for reading code" wording.

**Gates / reflection (no regression):** new `core/*.zig` stays on
`src/debug/determinism_test.zig`'s sources list; the new/changed `q.Command` (the `{context}`
fields, `DbgReadSrcCmd`, `dbg_list_sources`) and `q.Response` (`SourceWindow`/`DbgBpSetResult`/
`SourceFilesResult`) PODs stay **pointer-free** — source-root `Io.Dir` handles live on the
Session/worker, **never** on a Command/Response — so **both** `expectNoPointerFields(q.Command)`
and `(q.Response)` (`api/determinism_test.zig:155`) stay green. Verify after the change.

`TODO(verify):` the exact `src/main.zig` line numbers for the dir/file split (≈`:206-208`,
cited from a `sed` slice) — informational only; `main.zig` is **not** modified by this plan.

---

## 9. Test plan

A **minimal provable test** that the window appears with the right active line + content,
deterministic against the `BB.C` oracle (line 9 = `r = v;`, line 10 = `if (r < lo) r = lo;`,
line 20 = `m = GRAPHICS;`). **The test configures the source path through the API**, NOT a CLI
flag: after spawn, call an MCP `load {file:"BB.EXE", source_path:"examples"}` (or
`provision_machine {…, source_path:"examples"}`) **before** driving `whereami`, pointing the
roots at the directory holding `examples/BB.C`. It must NOT rely on the source sitting beside
the EXE on the C: mount, and there is **no** `--source-path` on the spawn line.

**Extend `tests/blackbox/debug_test.zig`** (the over-the-wire MCP test; add `Window`/`Line`
result shapes mirroring `writeSourceWindow`, including `clamped`). **Step 0 — configure source
via the API:** `load {file:"BB.EXE", source_path:"examples"}` (re-loads the recipe with the
source roots set), then proceed:

1. **R6 placement:** `set_source_breakpoint {file:"BB.C", line:9}` → assert `verified`,
   `window.has`, `window.active_line == 9`, default context (11 lines, clamped to file =
   4..14), active line's `text` (trimmed) == `"r = v;"`, neighbors line 8 (`int r;`) and 10
   (`if (r < lo) r = lo;`) present with `active=false`.
2. **R1 whereami (default context):** run to the bp, `whereami` (no `context`) →
   `source.line == 9` AND `window.lines[active].text` trimmed == `"r = v;"`; window 4..14,
   each with the correct 1-based `number`, `clamped=false`.
3. **R1 whereami (small `context`):** `whereami {context:2}` → exactly 5 lines (7..11),
   active line 9 flagged, `clamped=false` — proves a non-default size narrows correctly.
4. **R1 step:** `step_line {context:2}` → `pc.source.line == 10`, window re-centers (8..12),
   active text == `"if (r < lo) r = lo;"`.
5. **R2 read_source (not stopped there, explicit `context`):**
   `read_source {file:"BB.C", line:20, context:3}` → `window.active_line == 20`, active text
   == `"m = GRAPHICS;"`, exactly 7 lines (17..23).
6. **R2 read_source `context:0`:** `read_source {file:"BB.C", line:20, context:0}` → exactly
   1 line (`count==1`), that line active, text `"m = GRAPHICS;"`.
7. **Clamp flag (large `context`):** `read_source {file:"BB.C", line:6, context:1000}` →
   `clamped == true` (the request `2*1000+1` exceeds `DBG_WINDOW_LINES_MAX`), and `count`
   is the lesser of `DBG_WINDOW_LINES_MAX` and the file length (BB.C is 28 lines, so
   `count == 28`, the whole file). Proves an oversize request is clamped + flagged, never
   silently dropped. (For a unit assertion that `count == DBG_WINDOW_LINES_MAX` exactly,
   feed `cacheSource` a synthetic file longer than the MAX.)
8. **R2 by `file_id` echo (finding #3):** take the `source.file_id` from step 2's `whereami`
   and call `read_source {file_id:<that>, line:20}` → same window as the `file:"BB.C"` form.
   Proves the id whereami returns is directly usable by read_source (one namespace).
9. **R2b `list_sources` (finding #6):** `list_sources` → contains `{file_id, path:"BB.C",
   cached:true}`; that `file_id` round-trips into `read_source`. Proves discovery works.
10. **Graceful absence (no source configured):** in a **fresh** spawn that **never** calls
    `load source_path` / `provision_machine source_path` → `set_source_breakpoint`/`whereami`
    still resolve the location, but every `window.has == false` (no root holds the file).
    Proves the API source path is the sole text source, not co-location. Also
    `read_source {file:"NOPE.C", line:1}` → tool error `unresolved`, and `whereami` at a PC in
    the C-runtime (no symbols) → `source == null`, `window.has == false`.
11. **`tools/list` still fits `RESPONSE_BUF` (finding #11):** assert the `tools/list` body is
    served without overflow after adding `read_source` + `list_sources` rows and the `context`
    schemas (it was ~37.6 KiB; the additions land it ~39 KiB, within the 48 KiB `RESPONSE_BUF`,
    `server.zig:67`). A simple "`tools/list` returns 200 and parses" assertion guards the cap.

**CP437 / CRLF / TAB encoding fixture (finding #2).** Add (or use) a small fixture source file
with **a CP437 high byte** (e.g. a `0xC9`/`═` box-drawing char or an accented identifier in a
comment), **a CRLF line ending**, and **a leading TAB**, placed under the configured source
root. Assert `read_source` on that line returns: **valid UTF-8** body (the transcoded glyph,
not a raw `0x80..0xFF`), **no trailing `\r`** in `text`, and the TAB **expanded to spaces** —
exercising the one place "no silent smear" is at risk. (A pure unit form: hand `cacheSource`
raw CP437+CRLF+TAB bytes and assert the stored UTF-8 line.)

**Extend `src/debug/symbols_integration_test.zig`** (in-process, pure): after the existing
`runtimeAddrForLine(fileId("BB.C"),9)` breakpoint loop, drive `cacheSource` with the on-disk
`examples/BB.C` bytes and assert `sourceWindow(file_id, 9, 5)` yields 11 lines (4..14) with
line 9 `active` and text `"    r = v;"`; also `sourceWindow(file_id, 9, 0)` → 1 line, and a
context past `MAX_WINDOW_LINES` → `clamped==true`. A long synthetic line asserts
`truncated==true` and `len==DBG_SRC_LINE_CAP`; a CP437+CRLF+TAB synthetic line asserts valid
UTF-8 + `\r`-stripped + TAB-expanded; `fileIdForName("BB.C")` and `fileIdByBasename` resolve
the same id `fileId` does. Proves the pure render + flags + name lookup independent of the wire.

**Determinism assertions:** the same run + same roots yields byte-identical window text every
time; the cache admission is the same regardless of which windows are queried first (finding
#8); a window read leaves `cpuSnapshot()`/cycle count unchanged (a window read between two
`whereami` calls must not move the cycle counter).
