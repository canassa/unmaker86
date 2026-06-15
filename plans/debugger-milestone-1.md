# Debugger Milestone 1 — the in-process, single-threaded, deterministic control core

> **Scope.** Breakpoints + run-until-event + stepping + a state inspect/mutate
> facade, **in-process and synchronous**. **No HTTP/JSON server** in this milestone.
> The whole design is shaped so milestone 2 can layer an HTTP/command-queue server on
> top with zero rework (see *Milestone-2 forward compatibility*).
>
> **Prime directive (CLAUDE.md).** Same binary + same inputs ⇒ byte-identical machine
> state at any cycle N, every run. The control core must never read host time, never
> spawn an emulation thread, never poll, and never punch a hole in the cycle ledger.
> It **observes and drives** the machine synchronously; it is not part of the
> emulation timing path.
>
> **Status: v2.** Revised after a 3-perspective review (completeness, Zig 0.16/perf/memory,
> determinism/faithfulness). All review findings are folded in. The biggest changes from
> v1: (a) the **controller owns the run loop** (no `?*anyopaque` thunk on Machine);
> (b) a mandatory **side-effect-free inspection (peek) path** — inspection must never
> route through device read handlers; (c) a mandatory **deterministic firing & precedence**
> spec; (d) a real **error model** (typed errors, not asserts, for anything reachable from
> the API); (e) the breakpoint table is **defined-POD, not `undefined`**.

---

## 0. Investigation summary (what already exists, cited)

The machine already has the *bones* of a breakpoint mechanism — but they are **scaffolding
only, wired to nothing** (`grep` for `setBreakpoint`/`bp_predicate` finds zero callers
outside `machine.zig`/`run_loop.zig`). Milestone 1 **deletes** this single-predicate stub
(rather than generalizing it) and puts the breakpoint loop in `src/debug/`.

### The three Spice86 choke points, located in zdos

1. **CPU instruction loop (choke point #1 — execution-address & cycle breakpoints).**
   - One instruction is executed by `interrupts.step(cpu)` at `src/cpu/interrupts.zig:46`.
     `step` snapshots `start_cycles = cpu.st.cycles` (`interrupts.zig:47`), runs
     `dispatch.executeOne(cpu)` (`interrupts.zig:70`), then `serviceInterrupts`
     (`interrupts.zig:81`), and asserts `cpu.st.cycles > start_cycles` (`interrupts.zig:85`).
     **Note:** a shutdown CPU early-returns consuming 0 cycles (`interrupts.zig:49-51`),
     bypassing that assert — relevant to "step a terminal machine" (§3).
   - The **cycle ledger is advanced in exactly one place per instruction**: the
     by-construction base charge `cpu.st.cycles += cycles.baseFor(cpu.dec.key)` at
     `src/cpu/dispatch.zig:88`. Event costs are added at `interrupts.zig:140`
     (`interrupt_delivery`), `:175` (`fault_delivery`); the HLT idle fast-forward charges
     via `cpu.fastForwardIdle` (`cpu.zig:209-212`). The CPU is the **sole writer**
     of `st.cycles` (`machine.zig:25-27`).
   - The CPU is generic over `Bus`/hook types at **comptime** via `Cpu(comptime Bus)` /
     `CpuWith(Bus, opts)` (`src/cpu/cpu.zig:67-82`). `opts: Options` already carries
     `Pic`, `Scheduler`, `CallbackSink` comptime types (`cpu.zig:60-64`), each defaulting
     to a zero-cost `Null*` stub (`cpu.zig:33-57`). **This is the pattern the deferred
     memory/IO watchpoint hook will follow** (§5) — and explicitly NOT the pattern for the
     execution/cycle breakpoint check (which lives in the controller; see §1).
   - **Conclusion:** the cheapest place to check execution-address / cycle / interrupt
     breakpoints is **between steps**, at the instruction boundary. zdos already runs the
     guest one `step` at a time from `run_loop` (`run_loop.zig:41`). The controller will
     drive that same `step` primitive directly (§1) and scan the breakpoint set between
     steps — **zero cost on the CPU hot path** (the per-instruction work is entirely
     inside `cpu.step`; the scan is in the *debug* loop, not the *emulation* inner loop).
     Memory/IO watchpoints are the exception — they fire *mid-instruction* and are
     deferred (§5).
   - **Important faithfulness note (was understated in v1):** `serviceInterrupts` runs
     *inside* `cpu.step` (`interrupts.zig:81`), so a between-steps check observes
     **post-`serviceInterrupts` CS:IP** — i.e. if an IRQ was delivered this step, CS:IP is
     already at the ISR entry (`interrupts.zig:207-208`). Therefore an `execution_address`
     breakpoint *does* catch ISR-entry addresses, and a delivered interrupt at a boundary
     shifts the observed address. This is correct and faithful; tests must assert with this
     in mind (do not assume "the next sequential instruction").

2. **`Machine.runUntil` and the run loop (the primitive the controller drives).**
   - `src/machine/run_loop.zig`:
     - `step(m)` (`:41`) = the burst primitive: `fireDue()` → `cpu.step()` → handle
       `.normal`/`.shutdown`/`.halted` (HLT fast-forward to `nextEventCycle()`,
       `:62-80`); returns `StepOutcome{cont, reason}`. **This is what the controller calls.**
     - `runCycles(m, n)` (`:104`) and `runUntil(m, predicate, max_cycles)` (`:122`) are the
       existing bounded wrappers. The controller's `runUntilEvent` is a *new* loop in
       `src/debug/` over `run_loop.step` — it does NOT reuse `runUntil` (whose `bool`
       predicate collapses every stop into `Machine.StopReason.normal`, `:129`, which cannot
       carry the rich reason we need — see §3).
   - `Machine.StopReason` (`src/machine/machine.zig:114-126`): `normal`, `breakpoint`,
     `halted_forever`, `shutdown`, `cycles_reached`. The debug layer defines its own richer
     `debug.StopReason` (§3) and translates.
   - The runner (`src/main.zig:20-22,88`) uses `fn untilDone(m) bool { return
     m.cpu.st.halted or m.dos.terminated; }`. Terminal signals available:
     `m.cpu.st.halted` (`state.zig:142`), `m.cpu.st.shutdown` (`state.zig:144`),
     `m.dos.terminated`, `m.dos.ret_code` (used at `main.zig:96,101`).

3. **State surface for inspect/mutate (already reachable).** See §3 for the exact mapping.
   Highlights:
   - GP regs: `cpu.readReg32/writeReg32(Reg32, …)` (`cpu.zig:236-241`). **`Reg32` encoding
     order is `{ eax, ecx, edx, ebx, esp, ebp, esi, edi }` (`state.zig:35`)** — NOT
     alphabetical; `readReg32` indexes by `@intFromEnum` (`cpu.zig:236-237`). 16/8-bit
     access is via `cpu.st.getReg16/8(r: u3)` / `setReg16/8(r: u3, v)` (`state.zig:188-206`),
     which take a **raw `u3` index**, and for 8-bit the index encodes AL=0..BL=3 (low) /
     AH=4..BH=7 (high) (`state.zig:194-206,250-251`). There is **no** `Cpu.setReg16/8`.
   - Segments: `cpu.readSegSelector(Seg)` (`cpu.zig:242`); `cpu.loadSegment(Seg, sel)`
     recomputes base (`cpu.zig:172`); bases `cpu.st.seg_base[..]` (`state.zig:108`); limits
     `seg_limit` (`state.zig:110`).
   - IP/EIP: `cpu.st.eip` (`state.zig:104`); `cpu.patchEip(v)` (`cpu.zig:248`).
   - Flags: `cpu.readFlags() -> Flags` (`cpu.zig:245`); fields `cf,pf,af,zf,sf,tf,iff,df,of,
     nt,rf,vm,ac` (`flags.zig:11-29`); `Flags.toU32/fromU32` (`flags.zig:38-47`); written by
     poking `cpu.st.eflags` (no `Cpu.writeFlags` exists).
   - Cycles: `cpu.st.cycles` (`state.zig:156`). Status: `cpu.st.halted`/`shutdown`
     (`state.zig:142-144`).
   - Memory (RAW — see §4 for why inspection must NOT use these): logical
     `cpu.readLogical8`/`patchLogical8` (`cpu.zig:253-260`); physical
     `cpu.readPhysical8`/`patchPhysical8` (`cpu.zig:262-267`); bulk
     `bus.readGuestBlock`/`writeGuestBlock` (`bus.zig:530-550`); wide `bus.readPhys16/32`,
     `writePhys16/32` (`bus.zig:242-279`). **These route through device read handlers for
     non-hostPtr MMIO pages and can mutate device state** (see §4, R2).
   - IVT: real-mode IVT at `idtr_base` (`state.zig:126`, reset base 0, limit 0x3FF); an
     entry = phys16 at `base+vec*4` (IP) and `+2` (CS), mirroring `interrupts.zig:193-194`.
   - Devices/ports: `bus.portIn8/16/32`, `portOut8/16/32` (`bus.zig:418-447`). **Port reads
     are side-effecting** (e.g. PIT `readCounter` mutates `latched`/`read_lohi_phase`,
     `pit.zig:320-348`) — inspection must not call them (§4).

   **Mirror of Spice86 `CpuStateSnapshot.cs`:** Spice86 exposes EAX..EBP, CS/DS/ES/FS/GS/SS,
   IP, the 8 flag bools (CF/PF/AF/ZF/SF/DF/OF/IF), and Cycles. zdos has **all** of these,
   plus extras (full EIP, TF/NT/RF/VM/AC, seg bases/limits, CR0-3, IDTR, halted/shutdown).
   **Nothing in Spice86's snapshot is missing.**

4. **Bus / memory choke point (for memory watchpoints — deferred to §5).** All guest memory
   funnels through `Bus.readPhys{8,16,32}`/`writePhys{8,16,32}` (`bus.zig:197-279`) /
   `readPhys8RawMasked`/`writePhys8RawMasked` (`bus.zig:375-407`). The RAM fast path is a
   tight branch-light loop (`fastRamSpan`, `bus.zig:185-194`) reading only
   `ram`/`a20_mask`/`page_kind`. Dispatch is by `page_kind[page]` (`bus.zig:197-233`);
   `.mmio` pages without a `hostPtr` call the device handler (`bus.zig:209,357,384`).
   **Tradeoff (flagged):** a memory-watchpoint hook on this path is the one place a debug
   check would cost the *emulation* hot loop. It must therefore be either a comptime-gated
   hook (`Null*` discipline, §1) or a page-kind `.mmio`-trap — **deferred; do not pay
   speculatively** (§5).

5. **I/O port dispatcher (choke point #3 — IO breakpoints, later).** Ports funnel through
   `Bus.portIn*/portOut*` (`bus.zig:418-447`), dispatching by `port_handler_id[port]` to a
   registered `PortHandler` (devices self-register in `Machine.wire`, `machine.zig:204-222`).
   **Located only; deferred** — same rationale as #4.

6. **Test harness (how the regression proves determinism).**
   - `build.zig`: per-area `test-cpu` (`:154`), `test-bus` (`:185`), `test-machine` (`:192`),
     external oracles `test-oracle` (`:339`)/`test-io-oracle` (`:356`), aggregate `test`
     (`:369-391`). `MachineTest.add(b, target, optimize, root, imports)` helper
     (`build.zig:194-212`) builds a test artifact importing named modules — **the debugger
     tests register here** via a new `test-debug` step folded into `test`.
   - Determinism idioms to copy:
     - Byte-identical State compare: `expectStateEqual` (`machine_test.zig:23-25`).
     - Alloc-free run-path proof via `CountingAllocator` (`determinism_test.zig:40-108`).
     - Forbidden-host-dependence grep audit (`determinism_test.zig:12-36`) — **extended for
       `src/debug/`**, see §4.

7. **Zig 0.16 idioms confirmed** (zig-developer skill, `memory-and-performance.md`):
   - **`std.BoundedArray` is removed in 0.16** (§ line 59) → fixed `[N]T` + occupancy.
   - **`std.RingBuffer` is removed in 0.16** (confirmed absent from `references/zig/lib/std/
     std.zig`) → the M2 queue uses a fixed array + power-of-two masked head/tail (§6).
   - No per-op alloc; allocate up front; hot loops do zero alloc/free.
   - Handles (small int indices), not pointers; snapshot-safe (mirrors `bus.zig` stable IDs).
   - `@splat` for array-field defaults is the house style (`state.zig:102,108`;
     `machine.zig:76,142`; `bus.zig:81`). **Reading an `undefined` tagged union's tag is
     illegal behavior** (`zig-langref/41-illegal-behavior.md`) — so the breakpoint table is
     `@splat`-of-a-default, never `undefined` (§2).

---

## 1. Architecture & module placement

### Where the code lives: `src/debug/`

A new module `src/debug/` sits **above** `machine` in the module graph (it imports `cpu` +
`machine`; nothing imports it except `main`/tests/M2's `api`):

```
src/cpu/      ← nothing      (gains a comptime DebugHook *type* default in §5 only; no import)
src/bus/      ← nothing
src/devices/  ← bus contract (gains a side-effect-free peek8 to the MemHandler/PortHandler
                              contract — see §4; pure addition, no import of debug)
src/dos/      ← bus + machine facade
src/bios/     ← bus
src/machine/  ← all above
src/debug/    ← OBSERVES + DRIVES machine (imports cpu + machine)   ← NEW (this milestone)
src/api/      ← debug + machine        (M2, not now)
src/host/     ← machine output
```

### The controller owns the loop (revised from v1)

v1 put a type-erased `?*anyopaque` + `*const fn(*anyopaque,*Machine) ?StopReason` thunk on
`Machine` and had the machine call *down* into the controller between steps. **That is a
runtime indirect call** — the opposite of the `Null*` comptime-monomorphization pattern; it
also forces a machine-side seam that exists only to dodge the module-graph rule.

**v2: invert it. The `Controller` (in `src/debug/`) owns the run loop and calls
`run_loop.step(m)` directly.** It holds a `*Machine` (it is *above* machine in the graph,
so the import is legal), and it scans its own `BreakpointSet` between steps. No function
pointer, no `*anyopaque`, no type erasure, and it is strictly faster when armed.

Consequences for the machine:
- **Delete** `bp_predicate` (`machine.zig:151`), `setBreakpoint` (`machine.zig:442-445`),
  and the breakpoint-predicate checks in `run_loop.zig:110-114,134-138`. (v1 generalized
  these; v2 removes them — the controller does the checking.)
- **Remove** `breakpoints_armed` (`machine.zig:148`) too (decision locked: open question #6).
  Nothing reads it once the controller owns the loop; `run_loop` goes back to its pure form.
  Behavior-neutral (nothing referenced the predicate today).
- Expose (or reuse) a single public step primitive the controller can call. `run_loop.step`
  is already `pub` and is exactly it.

**Zero-cost-when-disabled, restated honestly:**
- When no `Controller` exists (the bare runner, all existing tests), the machine runs
  exactly as today — **identical fast path, zero added cost** (we removed a dead branch).
- When a `Controller` runs but the breakpoint set is empty, `runUntilEvent` is a tight loop
  `while (...) { step(m); if (set.active_count == 0) continue; scan; }` — the `active_count`
  test is one bool per step, in the *debug* loop, never in the CPU inner loop.
- Memory/IO watchpoints (deferred, §5) use the comptime `Null*`-style hook so they cost
  **zero** when not compiled in — that is the only place the comptime pattern applies.

### Resolving "check between steps" vs "manage at high level"

There is no longer a tension: both the check *and* the manager live in `src/debug/`. The
machine is oblivious to the debugger. Three check sites remain, by kind:

| Breakpoint kind | Where checked | Mechanism |
|---|---|---|
| Execution-address, Cycle, Interrupt-vector | between `run_loop.step` calls, in `Controller` | direct scan of `BreakpointSet`; `active_count` gate |
| Memory R/W (deferred §5) | inside the bus access path | comptime hook OR page-kind `.mmio` trap |
| IO R/W (deferred) | inside the port dispatch | same |

---

## 2. Data model (the breakpoint representation)

All in `src/debug/breakpoints.zig`. **Fixed up-front storage, no per-op alloc. Defined POD
(never `undefined`), so it is snapshot-safe and free of illegal-behavior tag reads.**

### Breakpoint kind, access kind

```zig
pub const AccessKind = enum(u2) { read, write, access }; // access = read|write

pub const BreakpointKind = union(enum) {
    /// Fires when, after a retired step, linear(CS:IP) == linear (cs.base +% eip).
    execution_address: struct { linear: u32 },
    /// Fires at the first step boundary where cpu.st.cycles >= at_cycle.
    cycle: struct { at_cycle: u64 },
    /// Fires when interrupt `vector` was delivered this step (Phase 4; needs the
    /// State.last_delivered field, §3/§7).
    interrupt: struct { vector: u8 },
    // ---- declared now so ids/handles/serialization are stable; built in §5 / later ----
    memory: struct { linear: u32, len: u32, access: AccessKind }, // Phase 5+
    io: struct { port: u16, access: AccessKind },                 // deferred
};

/// A well-defined default so unused slots are valid POD (NOT `undefined`).
pub const default_kind: BreakpointKind = .{ .cycle = .{ .at_cycle = 0 } };
```

### Breakpoint record + storage

```zig
pub const Breakpoint = struct {
    kind: BreakpointKind = default_kind,
    enabled: bool = false,
    /// One-shot: auto-disabled after it fires (stepping/run-to use these).
    one_shot: bool = false,
};

pub const MAX_BREAKPOINTS = 64;
pub const Error = error{ BreakpointTableFull, NoSuchBreakpoint };

pub const BreakpointSet = struct {
    /// DEFINED POD — every slot is a valid Breakpoint (default-init), so a tag read is
    /// never illegal behavior and a snapshot never captures garbage.
    items: [MAX_BREAKPOINTS]Breakpoint = @splat(.{}),
    used: [MAX_BREAKPOINTS]bool = @splat(false),
    /// O(1) "any enabled breakpoint?" gate. Single source of truth; recomputed on every
    /// mutation. (No len/exec_count/cycle_count — nothing reads them at N<=64; a linear
    /// scan of <=64 defined PODs is one cache-friendly pass. Don't memoize cheap work.)
    active_count: u32 = 0,
};
```

**Stable ids = slot index.** `id == index into items[]`. `add` finds the lowest free slot;
`remove` clears `used[id]` and resets the slot to default. Ids stay stable across
add/remove (an M2 REST handle and a snapshot both reference by id). This mirrors the bus's
stable-integer-ID discipline (`bus.zig:55-58`).

**No derived fast indices.** v1's `len`/`exec_count`/`cycle_count` are dropped: at the
64-cap a linear scan over `items[]` (filtered by `used[] && enabled`) is a handful of cache
lines and beats maintaining counters nothing reads (`memory-and-performance.md §5`: don't
memoize cheap computations). `active_count` is the only kept counter — it backs the per-step
gate. If a future profile ever shows the scan matters, swap in a comptime-sized table
*then*, preserving the §3 tie-break order — an internal change, no API impact.

### One-shot vs persistent

- **Persistent:** survive firing; stay enabled (user breakpoints).
- **One-shot:** auto-`enabled=false` on fire. **Stepping is built from one-shots** (§3).

---

## 3. Core control API (the facade M2 wraps)

`src/debug/controller.zig` — `pub const Controller = struct { m: *Machine, set:
BreakpointSet, last_stop: ?StopReason }`. Created **after** `Machine.wire()` (pinning
invariant, `machine.zig:8-20`); must not outlive the machine. Every method is
**synchronous**, returns a value or a typed error, and never threads/polls/reads host time.

### Stop reasons

```zig
pub const StopReason = union(enum) {
    breakpoint: struct { id: u32, at_cycle: u64 }, // which user bp fired, and when
    step_complete: struct { at_cycle: u64 },       // a step/stepN/stepOver finished
    cycle_budget_exhausted: struct { at_cycle: u64 },
    halted_forever,                                // deterministic permanent HLT
    program_terminated: struct { ret_code: u8 },   // dos.terminated
    shutdown,                                       // triple fault
};
```

### Deterministic firing & precedence (NEW — mandatory)

A single step boundary can satisfy several conditions at once. The reported `StopReason` is
part of the observable, reproducible result (constraint #6, #5), so the order is **fixed and
tested**, never dependent on scan/iteration order:

1. **Terminal beats breakpoint.** After each `run_loop.step`, check terminals in this exact
   order and return the first that holds: `shutdown` (`m.cpu.st.shutdown`) →
   `program_terminated` (`m.dos.terminated`, carry `m.dos.ret_code`) → `halted_forever`
   (the `run_loop.step` outcome reports a permanent HLT with no pending events).
2. **Then breakpoints.** If no terminal, scan `items[]` in **ascending id order** and report
   the **lowest-id** matching enabled breakpoint. This is the total tie-break: among
   simultaneously-eligible breakpoints, lowest id wins, deterministically.
3. **One-shot consumption rule (fixed):** **every** matching one-shot at this boundary is
   consumed (disabled), not only the reported one. (Rationale: a one-shot's contract is "at
   most once"; leaving an un-reported but matched one-shot armed would re-fire at a boundary
   the user already passed.) Persistent matches are untouched.
4. **Then the budget.** If nothing above fired and the cycle cap is reached, return
   `cycle_budget_exhausted`.

`Controller.last_stop` is set to the returned reason on every `runUntilEvent`/step return
(so M2's idempotent `GET /status` can re-read it), and cleared (`null`) at the *start* of
each run call to prevent a stale value leaking.

### Resume / re-fire (NEW — mandatory)

If `runUntilEvent` is called while CS:IP already sits on a persistent `execution_address`
breakpoint (the common "continue after stopping here" case), a naive between-steps check
would re-fire immediately and never advance. Rule: **`runUntilEvent` always executes at
least one `run_loop.step` before evaluating the breakpoint set.** (Terminals are still
checked first each boundary — you cannot step a terminal machine; see below.) This is the
standard "step off the breakpoint" behavior.

### Run / step

```zig
/// Advance until a terminal, a breakpoint, or `cycle_cap` cycles elapse. Synchronous.
/// Steps at least once before checking breakpoints (resume rule). Generalizes the loop
/// shape of run_loop.runUntil but returns the rich StopReason and owns the scan.
pub fn runUntilEvent(self: *Controller, cycle_cap: u64) StopReason;

/// One retired instruction. If the machine is ALREADY terminal (shutdown/terminated/
/// permanent-HLT), it does NOT step — returns the terminal reason. Otherwise charges
/// exactly the instruction's real cycles (one run_loop.step) and returns step_complete.
pub fn stepInstruction(self: *Controller) StopReason;

/// n× stepInstruction, stopping early on any fired persistent breakpoint or terminal.
pub fn stepN(self: *Controller, n: u64) StopReason;

/// Step over a CALL/INT by running to its return, else == stepInstruction.
/// Returns step_complete; the result also reports whether it degraded to step-into.
pub fn stepOver(self: *Controller) StepOverResult;

/// One-shot cycle bp at `c`, then runUntilEvent. If c <= current cycles, returns
/// immediately (no step) with cycle_budget_exhausted{at_cycle = current} — documented.
pub fn runToCycle(self: *Controller, c: u64) StopReason;

/// One-shot execution_address bp at `linear`, then runUntilEvent.
pub fn runToAddress(self: *Controller, linear: u32) StopReason;
```

**`stepOver` (revised — no silent degradation).** Decoding one opcode byte is insufficient
to size `INT n`, indirect `CALL` (`0xFF /2,/3` need ModR/M), `REP`-prefixed, or far vs near
returns. So:

```zig
pub const StepOverResult = struct {
    reason: StopReason,
    stepped_into: bool, // true if we could not step *over* and fell back to step-into
};
```

- Detect a *direct* call we can handle cheaply: `0xE8` (near `CALL rel`) / `0x9A` (far
  `CALL ptr`) / `0xCD` (`INT imm8`). For these, **execute the call instruction itself**
  (one `run_loop.step`), then set a **one-shot `execution_address` bp at the pushed return
  linear address** read from the stack via the **peek path** (§4, never `bus.readPhys*`),
  **guarded by SP**: the bp fires only when, at a later boundary, `linear(CS:IP) == return
  && SS:SP >= sp_at_return`. The SP guard makes recursion correct (a recursive re-entry to
  the same linear address at a deeper SP does not trip it). Then `runUntilEvent`.
- For anything else (indirect call, REP, prefixes we don't classify), **fall back to
  `stepInstruction` and set `stepped_into = true`** — the degradation is reported, never
  silent (ground rule). M2 surfaces the flag.

**Firing rules (deterministic, exact):**
- `cycle{at}`: fires at the first boundary where `cpu.st.cycles >= at` (a single
  instruction may jump the ledger past `at` by `baseFor(key)`; the HLT fast-forward may jump
  it a large idle span to `nextEventCycle()`). The **reported `at_cycle` is the actual
  ledger value at that boundary**, which is a pure function of the program and thus identical
  every run — it equals `at` only outside idle spans. Tests assert the reported value, not
  `== at`.
- `execution_address{linear}`: after a retired step, `linear = cpu.st.seg_base[CS] +%
  cpu.st.eip` (mirrors `segmentation.zig:41`); fires before the instruction at that address
  executes, and (per §0.1) also catches ISR-entry addresses.

### Breakpoint management (typed errors, not asserts)

```zig
pub fn addBreakpoint(self: *Controller, kind: BreakpointKind, one_shot: bool) Error!u32;
//   -> id, or error.BreakpointTableFull when all 64 slots are used (NEVER a panic — this
//      is reachable from the M2 HTTP API; a 65th breakpoint must be a clean error response).
pub fn removeBreakpoint(self: *Controller, id: u32) Error!void; // error.NoSuchBreakpoint
pub fn enableBreakpoint(self: *Controller, id: u32, on: bool) Error!void;
pub fn getBreakpoint(self: *const Controller, id: u32) Error!Breakpoint;   // M2 GET /bp/{id}
pub fn forEachBreakpoint(self: *const Controller, ctx, f) void;            // skips unused slots
//   listBreakpoints does NOT return a []const Breakpoint view: items[] is sparse (used[]),
//   so a slice would expose non-active slots. Use the visitor (or a compact-into-caller-
//   buffer variant) so only used && valid slots are observed.
```

Every mutation recomputes `active_count` (and updates the optional `breakpoints_armed`
advisory if kept). Bad/stale/out-of-range ids return `error.NoSuchBreakpoint`; double-remove
is `error.NoSuchBreakpoint` (idempotent-safe for the caller to ignore).

### Inspect — SIDE-EFFECT-FREE peek path (NEW — mandatory)

**Inspection must never perturb the machine** (prime directive; the whole reason zdos
exists). `bus.readPhys*`/`portIn*` route through device read handlers that mutate state
(PIT `readCounter`, `pit.zig:320-348`; unmapped EMS slots; etc.). So inspection uses a
**peek path that bypasses handlers**:

- Add a side-effect-free `peek8(addr) u8` to the `MemHandler` contract (and `peekPort`? —
  only when port inspection lands). RAM/ROM/hostPtr-backed MMIO (e.g. VGA VRAM,
  `vga.zig:157-167`) peek straight from the slab/host pointer. Non-hostPtr device MMIO
  implements `peek8` as a **pure snapshot read** (PIT returns the live/latched value
  *without* advancing `read_lohi_phase`). A device that genuinely cannot be read without a
  side effect returns a clearly-marked "not peekable" sentinel rather than faking a value
  (ground rule). `bus.peekBlock(addr, dst)` composes these.

```zig
pub const CpuSnapshot = struct {
    eax: u32, ecx: u32, edx: u32, ebx: u32, esp: u32, ebp: u32, esi: u32, edi: u32, // Reg32 ORDER
    cs: u16, ds: u16, es: u16, fs: u16, gs: u16, ss: u16,
    cs_base: u32, ds_base: u32, es_base: u32, fs_base: u32, gs_base: u32, ss_base: u32,
    eip: u32,
    cf: bool, pf: bool, af: bool, zf: bool, sf: bool, df: bool, of: bool, iff: bool,
    tf: bool, nt: bool, rf: bool, vm: bool, ac: bool,
    cycles: u64,
    halted: bool, shutdown: bool,
};
/// Pure reads. Fill FIELD-BY-FIELD via the typed enum (snap.eax = cpu.readReg32(.eax), …) —
/// NEVER an index loop over a struct whose field order differs from Reg32's encoding.
pub fn cpuSnapshot(self: *const Controller) CpuSnapshot;

pub fn peekMem(self: *const Controller, seg_or_phys, off, dst: []u8) void; // bus.peekBlock
pub fn peekIvtEntry(self: *const Controller, vector: u8) struct { ip: u16, cs: u16 }; // peek8 x4
pub fn peekStack(self: *const Controller, count: u16, out: []u16) []u16; // SS:SP upward, peek; no SP mutation
// disassemble: NOT AVAILABLE — see Risks. M1 exposes raw bytes at CS:IP via peekMem; no fake.
```

### Mutate

```zig
/// 8/16-bit register identity — explicit enums (the State setters take a raw u3; AH..BH are
/// indices 4..7). The facade owns the mapping; it does NOT pretend Reg32 covers 8/16-bit.
pub const Reg16 = enum(u3) { ax, cx, dx, bx, sp, bp, si, di };
pub const Reg8  = enum(u3) { al, cl, dl, bl, ah, ch, dh, bh };

pub fn setReg32(self: *Controller, r: Reg32, v: u32) void;   // cpu.writeReg32 (cpu.zig:239)
pub fn setReg16(self: *Controller, r: Reg16, v: u16) void;   // cpu.st.setReg16(@intFromEnum(r), v)
pub fn setReg8(self: *Controller, r: Reg8, v: u8) void;      // cpu.st.setReg8(@intFromEnum(r), v)
pub fn setSegment(self: *Controller, s: Seg, sel: u16) void; // cpu.loadSegment (recomputes base)
pub fn setEip(self: *Controller, v: u32) void;               // cpu.patchEip (cpu.zig:248)
pub fn setFlags(self: *Controller, f: Flags) void;           // cpu.st.eflags = f
pub fn writeMem(self: *Controller, seg_or_phys, off, src: []const u8) void; // bus.writeGuestBlock
```

Mutation writes go through the real bus write path (a debugger write is a deliberate new
**input**; the determinism guarantee is "same binary + *same inputs*"). Documented in code:
the core never mutates *implicitly* — only on an explicit `set*`/`writeMem`.

### Session / status ops (NEW — so M2 needs zero controller changes)

```zig
pub fn status(self: *const Controller) struct {
    running: bool, terminated: bool, ret_code: u8, cycles: u64, last_stop: ?StopReason,
};
pub fn reset(self: *Controller) !void; // re-init the machine deterministically; honors the
//   pinning invariant (machine.zig:8-20). Flagged as the one non-trivial op (see Risks).
pub fn memoryRegions(self: *const Controller) []const Region; // RAM size, VRAM, MMIO bounds
//   so an M2 readMem client can validate ranges before calling.
```

---

## 4. Determinism requirements (per piece)

- **No host clock / nondeterminism anywhere in `src/debug/`.** Extend the grep audit
  (`determinism_test.zig:12-36`) for `src/debug/` to also forbid `HashMap`/`hash_map`
  (unordered iteration → constraint #5), `std.atomic`/`@atomic` (M2 threading → #4), in
  addition to the existing `std.time`/`std.Random`/`std.Thread`/`getenv`/`f32`/`f64`.
  Add a **comptime reflection test** asserting `BreakpointSet`, `Breakpoint`, and
  `StopReason` contain **no pointer-typed fields** (so no ASLR'd pointer can leak into a
  snapshot or M2 JSON; constraint #5).
- **`runUntilEvent` introduces no new time source.** It loops `run_loop.step` (`:41`), whose
  HLT path fast-forwards to `nextEventCycle()` (`:62-80`) — a pure function of the schedule.
- **Stepping charges real cycles.** `stepInstruction` = one `run_loop.step` →
  `cpu.step` → `dispatch.executeOne` → `cpu.st.cycles += baseFor(key)` (`dispatch.zig:88`).
  No invented "stepping cost"; N steps == one run over the same span ⇒ identical ledger
  (regression #4).
- **No ledger holes / sole writer.** The debugger only *reads* `st.cycles`; the CPU stays
  sole writer (`machine.zig:25-27`). "Pausing" = returning from `runUntilEvent`, leaving the
  ledger exactly where the last retired step put it — no smear, no host-time gap (the whole
  point vs. Spice86's 1ms wall-clock poll).
- **Inspection is side-effect-free** (§3 peek path). A test asserts `cpuSnapshot` +
  `peekMem` + `peekStack` + `peekIvtEntry` over a **device-backed region** leave
  `machine.snapshot()` byte-identical (R2).
- **Deterministic firing** (§3): fixed terminal precedence, lowest-id tie-break, all-matching
  one-shot consumption — each with a regression test.
- **Watchpoints are cycle-cost-neutral** (when built, §5): arming a watchpoint must not
  change the cycle cost or trajectory of the watched access vs. unwatched. The base charge is
  at `dispatch.zig:88` (independent of bus routing), so this holds today; §5 must *assert*
  it (a watched run and an unwatched run reach byte-identical state + ledger at cycle N).
- **Snapshot-safe breakpoint set.** Defined POD with stable ids; foldable into
  `Machine.Snapshot` later (M2) with no pointer rebinding (mirrors `bus.zig:615-663`). M1
  keeps it controller-owned.

### Regression tests (`src/debug/*_test.zig`, wired via a `test-debug` step in `build.zig`)

1. **Exact-cycle bp.** `cycle{at=K}`; assert reason `.breakpoint`, reported `at_cycle` is the
   first boundary `>= K`, and that value is **constant across two fresh runs**.
2. **HLT-span cycle bp.** `cycle{at}` landing inside a known HLT idle span fires at
   `nextEventCycle`, constant across runs (R5).
3. **Byte-identical two-run.** Same program to the same cycle bp on two fresh machines;
   `expectStateEqual` + RAM `expectEqualSlices`.
4. **Execution-address bp.** Fires with `linear(CS:IP) == addr` (account for ISR-entry
   semantics, §0.1).
5. **Step == run equivalence.** `runToCycle(N)` vs `stepInstruction` until `cycles >= N` →
   byte-identical state + RAM. Proves no ledger drift.
6. **Disarmed transparency.** With no controller / no breakpoints, behavior is byte-identical
   to the existing bare `run_loop` path for a corpus program.
7. **Alloc-free control loop.** `CountingAllocator` → zero allocations after setup.
8. **Tie-break determinism.** Two simultaneously-eligible breakpoints → reported id is the
   lowest and constant across runs; all matching one-shots are consumed.
9. **Terminal precedence.** A step that both satisfies a breakpoint and sets `dos.terminated`
   → reports `program_terminated` (precedence), constant across runs.
10. **Resume / re-fire.** Stop at a persistent exec bp; a second `runUntilEvent` steps off
    and does not immediately re-fire at the same PC.
11. **One-shot lifecycle.** A one-shot fires once; a second `runUntilEvent` does not stop on
    it.
12. **Error paths.** `addBreakpoint` past 64 → `error.BreakpointTableFull`; remove/enable a
    bad id → `error.NoSuchBreakpoint`; `runToCycle(past)` → immediate `cycle_budget_exhausted`.
13. **Side-effect-free inspection.** Snapshot+peek over a device region (PIT/VRAM) leaves
    `machine.snapshot()` byte-identical (R2).
14. **Grep + reflection audit.** `src/debug/` passes the extended forbidden-needle grep; no
    pointer fields in the POD types.
15. **stepOver.** Over a direct CALL returns to caller (not into callee); recursion handled
    by the SP guard; an indirect/INT case reports `stepped_into = true` (no silent degrade).

---

## 5. Implementation checklist (phased; each phase independently testable; gates stay green)

> Run `zig build test` after every phase. Each `- [ ]` is sized to be one focused commit.
> Cited `file:line` are the exact edit/insert points.

### Phase 0 — module skeleton + remove the dead seam (no behavior change)
- [x] Create `src/debug/debug.zig` (module root) and register `debug_mod` in `build.zig`
      near the other `b.addModule` blocks (~`build.zig:30-60`), importing `cpu` + `machine`.
- [x] Remove the dead breakpoint scaffolding: `bp_predicate` (`machine.zig:151`),
      `setBreakpoint` (`machine.zig:442-445`), the predicate checks in `run_loop.zig:110-114,
      134-138`, and `breakpoints_armed` (`machine.zig:148`) (decision locked, #6). Confirm
      `run_loop.step` is `pub` and usable as the controller's primitive. Pure deletion of
      unused code.
- [x] `zig build test` — green (nothing referenced the removed symbols).

### Phase 1 — breakpoint data model
- [ ] `src/debug/breakpoints.zig`: `AccessKind`, `BreakpointKind` (+ `default_kind`),
      `Breakpoint`, `BreakpointSet` (`items: @splat(.{})`, `used`, `active_count`), `Error`.
      **No alloc; defined POD.**
- [ ] `add` (lowest free slot → id, `error.BreakpointTableFull` when full),
      `remove`/`enable`/`get` (`error.NoSuchBreakpoint`), `forEachBreakpoint` (skips
      `!used`), `recomputeActive`.
- [ ] `matches(bp, m) bool` for `execution_address` + `cycle` (others `false` for now).
- [ ] `src/debug/breakpoints_test.zig`: stable ids across add/remove; gate flips; `matches`
      fires on the right cycle/address; **error paths (test #12 subset)**; reflection
      no-pointer-fields check (part of #14).

### Phase 2 — controller facade + `runUntilEvent`
- [ ] `src/debug/controller.zig`: `Controller{ m, set, last_stop }`, `init` (post-`wire`).
- [ ] `runUntilEvent(cycle_cap)`: own loop over `run_loop.step`; **step-at-least-once**
      resume rule; per-boundary **terminal precedence** then **lowest-id breakpoint** scan
      then budget (§3); set/clear `last_stop`; all-matching one-shot consumption.
- [ ] `addBreakpoint/removeBreakpoint/enableBreakpoint/getBreakpoint/forEachBreakpoint`
      (delegate; recompute `active_count`).
- [ ] Inspect: `cpuSnapshot` (field-by-field, `Reg32` order), `status`, `memoryRegions`.
      *(peek path lands in Phase 2b so this phase can compile against RAM-only first if
      needed — but prefer doing 2b together.)*
- [ ] Tests: #1, #3, #6, #7, #8, #9, #10, #11, #12, #14.

### Phase 2b — side-effect-free peek path
- [ ] Add `peek8` to the `MemHandler` contract (`src/bus/`/`src/devices/`); implement for
      RAM/ROM/hostPtr (direct) and for device MMIO as a pure snapshot (PIT peek without phase
      advance, `pit.zig`). `bus.peekBlock`.
- [ ] Controller `peekMem`/`peekIvtEntry`/`peekStack`; raw-bytes-at-CS:IP via `peekMem`.
- [ ] Test #13 (inspection leaves `machine.snapshot()` byte-identical over a device region).

### Phase 3 — mutate + stepping & run-to (one-shot breakpoints)
- [ ] Mutate: `setReg32/16/8` (explicit `Reg16`/`Reg8` enums → `u3`), `setSegment`,
      `setEip`, `setFlags`, `writeMem`.
- [ ] `stepInstruction` (no-op + terminal reason when already terminal), `stepN`,
      `runToCycle` (immediate return when `c <= cycles`), `runToAddress`.
- [ ] `stepOver` with `StepOverResult{reason, stepped_into}`: direct CALL/INT via SP-guarded
      one-shot return-address bp read through the **peek** path; explicit fallback flag.
- [ ] `reset()` (open question #5, locked in): re-init the machine deterministically honoring
      the pinning invariant (`machine.zig:8-20`) — re-`wire` after re-`init`; reload the same
      program/inputs; assert a reset+rerun reaches byte-identical state at cycle N.
- [ ] Tests: #5 (step==run), #15 (stepOver incl. recursion + reported fallback); reset
      determinism (reset then rerun == fresh run, byte-identical).

### Phase 4 — interrupt-vector breakpoints
- [ ] Add a read-only `last_delivered: struct { vector: u8, at_cycle: u64, seq: u64 }` to
      **`cpu.State`** (the serialized type, so it round-trips), set in
      `interrupts.serviceInterrupts` (`interrupts.zig:102`), reset in `cpu.reset()`. The
      `seq`/`at_cycle` lets the between-steps check tell a fresh delivery from a stale one.
      Define which classes count (software `INT`, hardware IRQ; document fault behavior).
- [ ] `matches` for `interrupt{vector}`; add to `expectStateEqual` coverage.
- [ ] Test: `interrupt{0x21}` fires on a DOS call in a corpus program; freshness correct.

### Phase 5 — (optional; may defer to M2) memory watchpoints
- [ ] Decide mechanism: comptime `Options.DebugHook` (`cpu.zig:60-64`, zero-cost
      `NullDebugHook`) vs. page-kind `.mmio` trap. **Recommend page-kind trap** (single `Cpu`
      type; hot path untouched for unwatched pages — verified `bus.zig:185-233`).
- [ ] Implement watched-page accesses through the trap; consult the controller's `memory`
      bps mid-instruction.
- [ ] Tests: a write watchpoint fires mid-instruction at the right cycle; **cycle-cost
      neutrality** (watched vs unwatched run reach byte-identical state+ledger); disabled
      path byte-identical + alloc-free.

### Phase 6 — runner integration (optional; keeps `main.zig` thin)
- [ ] Opt-in flag (e.g. `--break-cycle N`) in `src/main.zig` constructing a `Controller`,
      setting one breakpoint, calling `runUntilEvent` instead of `runUntil` (`main.zig:88`).
      Default path unchanged.

---

## 6. Milestone-2 forward compatibility (do NOT implement now)

The M2 HTTP/JSON server layers on **without touching `controller.zig`**:

- **The core stays single-threaded.** M2 runs the HTTP listener on its own thread, but that
  thread does **not** call the machine. It enqueues commands into a single-producer/
  single-consumer ring — **a fixed `[N]Command` array + power-of-two masked head/tail
  indices** (NOT `std.RingBuffer`, which is gone in 0.16). The emulation thread (the one that
  owns `Controller`) drains the queue at deterministic boundaries.
- **Determinism is preserved only under the request/response contract (made explicit).** The
  guarantee holds *iff* there is **at most one command in flight** — the guest runs only in
  response to an explicit `run`/`step` command (each carrying its own bounded budget), so no
  command can arrive "mid-run" to be ambiguously drained. A naive "run to completion, then
  drain whatever happened to arrive" would let host scheduling decide *which* commands are
  present at the stop → host timing feeding back into trajectory (constraint #4 violation).
  M2 therefore enforces one-in-flight; "replay determinism" with live input requires a
  command log keyed by **cycle**, not arrival time.
- **The facade is already the wire protocol's shape.** Each M2 endpoint maps 1:1 to a
  `Controller` method: `POST /breakpoints`→`addBreakpoint`, `DELETE`→`removeBreakpoint`,
  `GET /breakpoints/{id}`→`getBreakpoint`, `POST /run`→`runUntilEvent`, `POST /step`→
  `stepInstruction`/`stepOver`, `GET /cpu`→`cpuSnapshot`, `GET /status`→`status`,
  `GET /mem`→`peekMem`, `PUT /mem`→`writeMem`, `POST /reset`→`reset`. All synchronous,
  returning POD/typed errors → JSON serialization is a pure mapping; errors map to HTTP
  status codes.
- **Breakpoint ids are stable handles; the breakpoint set is snapshot-safe POD** — M2's
  save/load debug session is a memcpy, no rebinding.

---

## 7. Risks / open questions (for the human)

1. **No disassembler exists in `src/`** (confirmed). M1 exposes raw instruction *bytes* at
   CS:IP via `peekMem`; it does **not** ship a fake disassembler (ground rule). A real 386
   decoder-to-text pass (reusing `src/cpu/decode.zig` tables) is its own later milestone.
   *Note:* there is no side-effect-free length-only decode today either, so M1 also does not
   promise "instruction length" — only raw bytes. (Reconciles v1's contradictory open
   questions.)
2. **`stepOver` coverage.** v2 handles direct `CALL`/`INT` with an SP-guarded return bp and
   **explicitly reports** fallback-to-step-into for indirect/REP/unclassified cases (no
   silent degrade). Accept this scope for M1? (Full coverage needs the decoder from #1.)
3. **Memory-watchpoint mechanism (Phase 5).** Recommend the page-kind `.mmio` trap (single
   `Cpu` type; unwatched hot path untouched). The hard requirement: arming a watchpoint must
   be **cycle-cost-neutral** (asserted by a test) or it perturbs the trajectory it observes.
   Decide before Phase 5.
4. **`interrupt`-bp needs a read-only `State.last_delivered` field** (`interrupts.zig:102`) —
   a 1-field change in a low module, determinism-neutral and serialized (must be in
   `cpu.State`, reset in `cpu.reset`, covered by `expectStateEqual`). Acceptable?
5. **`reset()` — RESOLVED: included in M1.** It is the one non-trivial facade op (the pinning
   invariant, `machine.zig:8-20`, means re-init must re-`wire`). Implement it in Phase 3
   alongside the other session ops.
6. **`breakpoints_armed` advisory — RESOLVED: removed.** Nothing reads it once the controller
   owns the loop (Phase 0 deletes it). Revisit only if a non-controller burst path ever needs
   a gate.
7. **Breakpoint set in `Machine.Snapshot`?** M1 keeps it controller-owned (out of the
   snapshot). Folding the POD set into the snapshot (for "resume a saved debug session at
   cycle N with the same breakpoints") is trivial later — defer to M2.
