# Memory-watchpoint breakpoints (and I/O-port watchpoint assessment)

Status: **memory watchpoints are already implemented and tested end-to-end** in the
`cpu → bus → debug → api` stack. This plan (a) documents the existing design so the
hard parts (fast-path coverage, cycle-neutrality, stop-point semantics) are recorded
and verified, (b) closes the one real reporting gap (the `StopReason` does not carry
the access details — address / read|write / value), and (c) builds the deferred
`io` (port) watchpoint, which is still a 501.

This is a **plan only** — no source changes are made by this document.

---

## 0. Investigation result: what is already built

The task brief assumed the `memory` kind was declared-but-not-firing (a 501). It is
not — it is live. Concretely, walking the choke point bottom-up:

- **`src/bus/bus.zig`** — the full watch machinery exists:
  - `WatchAccess` enum (`read|write|access`), `Watch` POD, `max_watches = 64`
    (`bus.zig:52-64`).
  - A new page kind `.watched` and the per-page bookkeeping: `watch_prior[]`
    (the kind the page replaced), `watch_page_refs[]` (ref-count so overlapping
    watches restore correctly), `watch_used[]`, `watches[]` (`bus.zig:126-150`).
  - `setWatch` / `clearWatch` promote/demote covered pages to/from `.watched`
    (`bus.zig:777-802`), ref-counted via `markPagesWatched`/`unmarkPagesWatched`
    (`bus.zig:744-772`).
  - The access hooks: `read8Kind`/`write8Kind` (`bus.zig:273-318`) and the wide
    `readWideOnePageKind`/`writeWideOnePageKind` (`bus.zig:375-436`) handle a
    `.watched` page by re-dispatching to `watch_prior[page]` (faithful passthrough)
    then calling `checkWatchHit` / `checkWatchHitSpan` (`bus.zig:819-845`).
  - The breadcrumb `last_mem_watch{linear, access, seq}` + `recordWatchHit`
    (`bus.zig:74-78, 847-861`), the freshness `seq` modeled on
    `cpu.State.last_delivered`.
  - Snapshot/restore round-trips all of it (`bus.zig:920-968`); `resetWatchHit`
    clears the breadcrumb on `Machine.reset` (`bus.zig:863-869`).
- **`src/debug/breakpoints.zig`** — the `memory` arm of `BreakpointKind`
  (`{linear, len, access}`) is matched live in `matches()` (`breakpoints.zig:162-174`):
  fresh-hit test (`w.seq != seq.watch`), range containment, access-class filter.
  `SeqBefore{delivery, watch}` carries the pre-step watch seq (`breakpoints.zig:133-138`).
- **`src/debug/controller.zig`** — `addBreakpoint` arms a bus watch for a `.memory`
  bp and records its slot in `watch_ids[]`; `removeBreakpoint` clears it
  (`controller.zig:270-304`). `toWatchAccess` bridges the duplicated enum
  (`controller.zig:47-53`). `runUntilEvent`/`stepN` snapshot `seqBefore` and scan
  via `matches` (`controller.zig:200, 240-259, 347-350`).
- **`src/api/`** — `AddBpReq{kind: BreakpointKind}` parses `{"memory":{...}}` via
  std.json's default union parsing (`json_wire.zig:53-56`); `handleAddBp` passes
  every kind through to the worker **except** `.io`, which is the only 501
  (`server.zig:807-814`). The worker calls `ctrl.addBreakpoint` and maps
  `WatchTableFull`→`BreakpointTableFull`→503 (`worker.zig:111, 195-200`;
  `controller.zig:282-289`).
- **`src/debug/watchpoint_test.zig`** — registered in `debug.zig:53`, run by
  `zig build test`. Covers: write fires on store; read ignores store, fires on load;
  access catches the first touch; out-of-range never fires; armed-vs-unarmed run is
  byte-identical at cycle N (the cycle-neutral proof); page promotion + `clearWatch`
  restore + overlapping-watch ref-counting.

So the **memory watchpoint is functional**. The work that remains is verification +
two gaps (reporting detail, and `io`).

---

## 1. The hard parts — how the existing design nails them (verify, don't rebuild)

### 1.1 Where the check lives + the hostPtr-fast-path coverage (THE critical issue)

The single memory choke point is the `Bus` (`bus.zig`); the CPU has **no private RAM
pointer** — `Cpu(Bus)` calls `bus.readPhys8/16/32` and `writePhys*` for every guest
access (`cpu.zig:121-138`, `readLogical8` at `cpu.zig:253-266`). So every guest memory
access is observable inside the bus. Good.

There are **two** in-bus fast paths that bypass the per-byte `read8Kind`/`write8Kind`,
and the design handles the watchpoint coverage of both **by page-kind gating**, which
is the clean answer to the brief's "fast path would MISS the watch" concern:

1. **The RAM fast path** (`fastRamSpan`, `bus.zig:244-253`). It is taken only when the
   page kind is `.ram` or `.rom`. `setWatch` promotes every covered page to `.watched`
   (`markPagesWatched`, `bus.zig:744-756`), so `fastRamSpan` returns **false** for a
   watched page and the access falls into `readWideOnePageKind`/the per-byte path,
   which re-dispatches to `watch_prior` and records the hit. **A watched RAM write is
   therefore caught** — this is exactly the EXEPACK-relocation case. When the last
   watch on a page is cleared, `unmarkPagesWatched` restores the prior `.ram`/`.rom`
   kind and the page **re-enters the fast path** at zero cost (`bus.zig:760-772`).
   → This is the "disable the fast path for pages with an armed watchpoint" strategy
   the brief proposed, implemented via the page-kind table rather than a side flag.

2. **The MMIO host-pointer fast path** (`h.hostPtr(page)`, `bus.zig:283, 305, 384,
   418`). RAM-like MMIO (VGA VRAM, mapped EMS frame pages) indexes the backing
   pointer directly **inside** the `.mmio` arm. But a watched MMIO page is `.watched`,
   not `.mmio`, so the access first enters the `.watched` arm (records the hit), then
   re-dispatches to `watch_prior == .mmio`, which *then* takes the hostPtr fast path
   for the actual data. **The hit is recorded before the fast-path passthrough** — so
   a watch on VRAM / the EMS frame is also caught. (Verify with a Phase-1 test; see
   §4.)

**Verification task:** add a fast-path-RAM-write test and a hostPtr-MMIO-write test
(VRAM) to prove no access escapes the hook. The existing suite proves RAM via
`runUntilEvent` but does not explicitly assert the fast-path/hostPtr coverage as the
load-bearing case.

### 1.2 Determinism: zero cycles + free when unarmed

- **Zero cycles when it fires.** The watched-page handler is a faithful passthrough
  (`read8Kind`/`write8Kind` re-dispatch to `watch_prior` for identical bytes/drops)
  and `recordWatchHit` only bumps a `seq` and writes a POD breadcrumb — it touches
  **no cycle counter**. The cycle ledger is the CPU's (`machine.zig`), charged by the
  instruction's `baseFor(dec.key)` independent of bus routing. So an access through a
  `.watched` page costs exactly what the same access through `.ram`/`.mmio` costs.
  The "(b) armed run is byte-identical to an unarmed run at cycle N" test
  (`watchpoint_test.zig`) is the regression for this.
- **Free when no watchpoint is armed.** When no watch is set, **no page is
  `.watched`**, so the fast path / normal `.ram`/`.mmio`/`.unmapped` arms run
  untouched — there is literally no extra branch on the hot path (the gate is the
  page-kind switch that already exists). This is stronger than a runtime "any armed?"
  flag: an unarmed bus is bit-for-bit the pre-watchpoint bus. The controller's
  `active_count == 0` gate (`controller.zig:241`) additionally short-circuits the
  between-steps scan.

### 1.3 Stop-point semantics

zdos stops at the **end of the instruction** that made the access (the step boundary),
consistent with every other zdos breakpoint kind and with how real source-level
debuggers report a data watchpoint. Mechanism: the bus records the hit *during* the
step; the controller compares `bus.last_mem_watch.seq` against the `seqBefore`
snapshot *after* the step (`controller.zig:200-204`, `breakpoints.zig:162-174`). It
does **not** stop mid-instruction (no re-entrant unwind, which would complicate the
cycle ledger). The reported boundary cycle is `m.cpu.st.cycles` — the same value used
for every kind.

One consequence to **document** (not a bug): if a single instruction makes several
watched accesses, only the **last** hit's `linear/access` survives in the breadcrumb
(seq counts them but the record is overwritten by `recordWatchHit`). For
end-of-instruction reporting this is acceptable and deterministic; note it in the API
docs. (dosbox-x's poll model has the same single-value limitation.)

### 1.4 Reference comparison (consulted)

- **dosbox-x** (`references/dosbox-x/src/debug/debug.cpp`): `EBreakpoint` includes
  `BKPNT_MEMORY` (debug.cpp:556); `CBreakpoint::CheckBreakpoint` polls memory
  breakpoints **per instruction under `C_HEAVY_DEBUG`** by storing the old byte and
  comparing the current byte, firing only when the **value changed**
  (debug.cpp:763-789), and reporting `seg:off - oldVal -> newVal` (debug.cpp:786).
  This is a *value-change poll*, strictly weaker than zdos's *access hook*: it misses
  reads, misses a write of the same value, and only runs in heavy-debug builds.
  zdos's bus-hook (fire on the real read/write, any value) is more faithful — keep it.
  **Takeaway adopted:** dosbox-x reports old→new value; zdos should report the access
  value too (the gap in §2).
- **spice86** (`references/spice86/`): hooks memory breakpoints in its memory
  read/write path (the bus equivalent), which is the same architecture zdos uses —
  validating the bus-hook choice over the poll.

---

## 2. Gap to close: report the access details in the StopReason

Today `StopReason.breakpoint = {id, at_cycle}` (`controller.zig:58-62`). A client
learns *which* bp fired but not the **address / read|write / value** that tripped it —
the most useful datum for a watchpoint (and the thing dosbox-x prints). The bus
already holds it in `last_mem_watch{linear, access}`; the controller just needs to
surface it for a `memory`-kind hit.

Design (keep it pointer-free POD, snapshot/JSON-safe, no new module deps):

- Add an **optional access detail** to the `breakpoint` stop reason, populated only
  when the reported bp is a `memory` (or, later, `io`) kind. Two shapes to choose
  between in Phase 2:
  - (a) extend `breakpoint` to `{id, at_cycle, watch: ?WatchHit}` where
    `WatchHit = {linear: u32, access: AccessKind, value: u8}`; or
  - (b) add a sibling reason `memory_breakpoint{id, at_cycle, linear, access, value}`
    and keep `breakpoint` for exec/cycle/interrupt.
  Prefer **(a)** — it keeps the one breakpoint-stop concept and `?WatchHit`
  serializes as `null` for non-memory bps (the JSON wire already handles optionals).
- **`value`**: the byte at `linear` read **side-effect-free via the peek path**
  (`bus.peekPhys8`) at the stop boundary — NOT a second real read (which would charge
  cycles / re-trip the watch). For `access == .write` this is the just-written value
  (the passthrough already stored it); for `.read` it is the value the guest read.
  This is cycle-neutral by construction (peek path, `bus.zig:651`).
- The controller fills `watch` in `scanBreakpoints` when the matched bp's kind is
  `.memory`, reading `m.bus.last_mem_watch` (already the fresh hit for this step).
- `json_wire.zig` / `queue.zig` `StopReason` mappings extend to carry the optional;
  the web UI (`src/api/web/app.js`) can show `addr (R/W) = NN`.

This is the only behavioral gap; everything else is verification.

---

## 3. I/O-port watchpoints (`io` kind) — assessment + phased build

The `io` arm of `BreakpointKind = {port, access}` is declared (`breakpoints.zig:38`),
`matches()` returns `false` (`breakpoints.zig:175`), and the server returns **501**
(`server.zig:810-812`). The I/O choke point is symmetric to memory: `Bus.portIn8/16/32`
and `portOut8/16/32` (`bus.zig:497-526`) dispatch by `port_handler_id`. The design
mirrors the memory watch exactly:

- **Detection point:** the `portIn*`/`portOut*` methods on the bus. There is no
  port "fast path" that bypasses them (the CPU's `IN`/`OUT` go straight to these), so
  there is no fast-path-coverage hazard — `io` is *simpler* than memory.
- **Gate:** a parallel `port_watches` table (small; ports are 16-bit, the common case
  is a handful of watched ports). Unlike pages, a port has no "kind" to flip; the
  cheapest cycle-neutral gate is an `any_port_watch_armed: bool` flag checked once at
  the top of `portIn*`/`portOut*` (free when unarmed: one bool test, the brief's
  recommended pattern). When set, a per-watch range/access scan records a
  `last_port_watch{port, access, value, seq}` breadcrumb (twin of `last_mem_watch`).
- **Cycle-neutral:** identical argument — the port handler dispatch is unchanged; the
  flag test + breadcrumb add no cycles, and port I/O cost is charged at the
  instruction, not the bus.
- **Stop semantics + reporting:** end-of-instruction, same `seqBefore`/`matches`
  freshness mechanism (extend `SeqBefore` with `port_watch`); report
  `{port, access, value}` in the StopReason via the §2 detail (reuse the same
  `?WatchHit`-style payload, with a `port` variant).
- **Wiring:** `matches()` `.io` arm goes live; `addBreakpoint`/`removeBreakpoint`
  arm/clear a `setPortWatch`/`clearPortWatch`; the server drops the 501 for `.io`.

**Priority:** lower than the memory gap. It is cheap (no fast-path hazard) and worth
including as a phase, but BaK's first-target needs (the EXEPACK / relocation class of
bug) are served by **memory** watchpoints; `io` is for device-interaction debugging.

---

## 4. Phased roadmap

### Phase 0 — verify the existing memory implementation (no code, just confirm)
- [ ] Run `zig build test` and confirm `src/debug/watchpoint_test.zig` passes (it is
      registered via `debug.zig:53`).
- [ ] Re-read the fast-path gating (`fastRamSpan` `.ram`/`.rom`-only at `bus.zig:251`;
      `markPagesWatched` flips to `.watched` at `bus.zig:751-752`) and confirm a
      watched page cannot take the RAM fast path.
- [ ] Confirm the peek path never records a hit (`peekPhys8` reads through
      `watch_prior`, `bus.zig:654-674`) so inspection stays cycle-neutral.

### Phase 1 — harden coverage with explicit load-bearing tests (test-only)
- [ ] **Fast-path RAM write is caught:** arm a write watch on a `.ram` address that a
      16/32-bit store would otherwise take via `fastRamSpan`; run; assert the run
      stops at that instruction with `linear`/`.write` correct. (The critical case.)
- [ ] **hostPtr MMIO write is caught:** arm a write watch inside VGA VRAM (a
      hostPtr-backed `.mmio` page); a guest store to it stops with the right detail —
      proving the `.watched` arm precedes the hostPtr passthrough.
- [ ] **Wide access partially covering the watch fires** (`checkWatchHitSpan`):
      a `u32` store straddling so only its high byte is watched still fires, at the
      lowest covered byte (deterministic).
- [ ] **Range watch** (`len > 1`) fires for any byte in `[linear, linear+len)` and
      not at `linear+len`.
- [ ] **Multiple + overlapping watches:** two watches on one page; clearing one keeps
      the page `.watched`; clearing both restores `.ram` and re-enables the fast path
      (extend the existing `(c)` test if needed).
- [ ] **Unarmed = zero overhead / byte-identical:** a no-watch run is byte-identical
      to the pre-watchpoint behavior (the `(b)` test covers armed-vs-unarmed at cycle
      N; add an explicit no-watch-set determinism double-run).
- [ ] **Determinism double-run:** same program + same watch → identical stop cycle +
      identical `last_mem_watch` across two runs.

### Phase 2 — report access details (the one behavioral change)
- [ ] Add `WatchHit{linear: u32, access: AccessKind, value: u8}` (pointer-free POD,
      in `debug/`).
- [ ] Extend `StopReason.breakpoint` to `{id, at_cycle, watch: ?WatchHit}` (option (a)
      in §2).
- [ ] In `scanBreakpoints`, when the reported bp is `.memory`, fill `watch` from
      `bus.last_mem_watch` + `bus.peekPhys8(linear)` for `value` (peek path —
      cycle-neutral; assert no cycle delta in a test).
- [ ] Thread the new field through `queue.zig` `StopReason`/`Response` and
      `json_wire.zig` (optional serializes as `null` for exec/cycle/interrupt bps).
- [ ] Surface in `src/api/web/app.js` (show `addr (R/W) = NN`).
- [ ] Tests: a memory bp stop carries the right `{linear, access, value}`; a
      non-memory bp stop carries `null`; the value read is the peek value (no cycle
      delta, no re-trip of the watch).

### Phase 3 — I/O-port watchpoints (the `io` kind)
- [ ] Bus: add `PortWatch{port, len?, access}` table + `last_port_watch{port, access,
      value, seq}` breadcrumb + `any_port_watch_armed` gate; `setPortWatch`/
      `clearPortWatch`; record a hit in `portIn*`/`portOut*` when armed (cycle-neutral;
      free when unarmed = one bool test).
- [ ] `breakpoints.zig`: implement the `.io` arm of `matches()` (extend `SeqBefore`
      with `port_watch`); `seqBefore` includes the port-watch seq.
- [ ] `controller.zig`: `addBreakpoint`/`removeBreakpoint` arm/clear a port watch for
      `.io` (parallel to `watch_ids`); map `AccessKind`.
- [ ] `server.zig`: drop the `.io` 501 (`server.zig:812`); let it flow through.
- [ ] Reporting: reuse the §2 detail with a `port` variant (or a `port_watch` sibling)
      in the StopReason.
- [ ] Snapshot/restore: round-trip the port-watch table + breadcrumb (twin of the
      memory watch in `Bus.Snapshot`, `bus.zig:920-968`).
- [ ] Tests: `OUT` to a watched port stops with `{port, .write, value}`; `IN` read
      watch; access; unarmed = byte-identical (cycle-neutral); determinism double-run;
      a watch on a port with a real device handler (e.g. PIT/VGA) still dispatches the
      device faithfully (passthrough), then records the hit.

### Phase 4 — docs
- [ ] Document the end-of-instruction stop semantics, the single-value breadcrumb
      caveat (last access of a multi-access instruction wins), and the peek-read
      `value` for both `memory` and `io` in the API reference.
- [ ] Update `plans/ROADMAP.md` with the memory-watchpoint status (built) + the
      reporting/`io` follow-ups.

---

## 5. Constraints honored (CLAUDE prime directive)

- **No cycle holes / cycle-neutral:** the watch hook is a passthrough + a POD
  breadcrumb; it charges nothing. The cycle ledger stays the CPU's, charged by
  `baseFor(dec.key)` regardless of `.watched` routing.
- **Free when unarmed:** memory — no `.watched` pages means the bus is bit-identical
  to the pre-watchpoint bus (page-kind gating, not a runtime flag on the hot path);
  io — a single bool test.
- **No fakes / no shortcuts:** the value reported is the real access value via the
  side-effect-free peek path, not a re-read that would re-trip or re-charge. `.io` is
  a real 501 until built — never a fake accept (`server.zig:810-812`).
- **Determinism is the regression:** every phase ends with a double-run / armed-vs-
  unarmed byte-identical test; snapshot/restore round-trips the watch tables.
- **No per-op alloc, no pointers in PODs:** fixed `[max_watches]` tables; all watch
  state is pointer-free and snapshot-serializable.
- **Module graph respected:** the bus never imports `debug`; the controller bridges
  the duplicated `AccessKind`↔`WatchAccess` downward (`controller.zig:47-53`); data
  flows down (`setWatch`), hits poll up (`last_mem_watch.seq`) — the Phase-4
  `last_delivered` shape, no fnptr / `*anyopaque` / type fork.
