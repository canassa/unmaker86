# Snapshot / Restore over the MCP + HTTP debugger API — design plan

**Status:** PLAN ONLY (no source changed). Every claim below is cited to the live code.

> ### Revised per adversarial review
>
> This rev folds in review findings; the deltas from the first draft:
>
> 1. **Snapshot is NOT byte-identical-complete as the draft claimed.** `Machine.Snapshot`
>    captures only the DOS *process* subset and omits **three** guest-mutable, guest-observable
>    scalars — `strategy`, `last_error`, `breakcheck` (`src/dos/dos.zig:102`,`:105`,`:106`).
>    §1 now specifies extending `Machine.Snapshot` with these 3 POD fields (exactly how the
>    nested-EXEC work added `dos_current_psp` et al.), and the "run-from-restored ==
>    run-from-original" claim holds *only after they are added*. Open-file/SFT remains the
>    one accepted v1 gap.
> 2. **Locked decisions wired in.** FULL snapshot always (whole machine incl. the full EMS
>    backing every time); cap **8/session**; deterministic `snap-<n>` handles; breakpoints
>    PERSIST across restore (+ `rearmWatches`); **lazy per-slot allocation**.
> 3. **Memory budget re-sized to the cap-8 reality:** worst case
>    `8 × (21 + 8×16.31)` ≈ **~1.2 GiB** (was the stale "default 4 / ~690 MiB"). Accepted
>    (user: "16 MiB is nothing", cap 8). See §3 / Risk 1 / D1.
> 4. **Lazy slabs, not inline arrays.** Slots hold **optional heap slabs** allocated on first
>    snapshot into the slot (idle session costs nothing) — the draft's inline fixed arrays
>    would force ~131 MiB eager per session. Teardown gains a **per-slot free loop** before
>    `gpa.destroy(self.snapshots)` (lazy slabs would otherwise leak).
> 5. **`rearmWatches()` is clear-then-rebuild**, not just "re-derive" — it must FIRST clear
>    the snapshot-reverted bus watches, THEN rebuild from the live breakpoint set, else
>    re-`setWatch` stacks on the reverted entries.
> 6. **Paced-run stall noted** (the ~16 MiB memcpy blocks the pacer's submit gate — a
>    wall-clock hiccup only; determinism unaffected).
> 7. **`bytes` is a constant** under full-snapshot (17,104,896 = **16.31 MiB**); the draft's
>    "16.4 MiB" was loose. Kept as a field for forward-compat.
> 8. **Cross-feature note** added for the branch-trace interaction (§4): require an input-free
>    [snapshot, target] window; auto-clear the branch trace on restore.

## 0. Goal & the reuse story

Expose machine **snapshot** (capture the live machine, return an opaque handle) and
**restore** (rewind the machine to a handle) as MCP tools + HTTP routes, so an
operator/agent can checkpoint a known-good state and run/step/experiment/restore
cheaply instead of re-driving from boot.

**We do NOT invent serialization.** zdos already has a complete, determinism-test-proven
machine snapshot/restore — the same mechanism the "double-mint" tests use to prove
byte-identical replay:

- `Machine.Snapshot` (POD) + `Machine.snapshot()` / `Machine.restore()` —
  `src/machine/machine.zig:811`, `:900`, `:930`.
- Composed per-subsystem snapshots: `Bus.Snapshot` (`src/bus/bus.zig:1058`),
  `Pic.Snapshot`, `Pit.Snapshot`, `Vga.Snapshot` (`src/devices/vga.zig:1220`),
  `Speaker.Snapshot`, `Opl.Snapshot`, `Keyboard.Snapshot`, `Scheduler.Snapshot`,
  the INT 33h mouse (`dos.mouse.snapshot()` `machine.zig:911`), EMS
  (`Dos.EmsType.Snapshot` `src/dos/ems.zig`), and the DOS process-kernel subset
  (`current_psp`/`current_drive`/`dta_seg`/`dta_off`/`ret_code`/`ret_type`/`terminated`
  — `machine.zig:870-876`). **This rev extends that subset by three more guest-mutable
  scalars** — `strategy`/`last_error`/`breakcheck` (see §1.1.1); the recipe is identical
  (POD fields added to `Machine.Snapshot` + assigned in `snapshot()`/`restore()`).
- The **large slabs are captured OUT OF BAND** by the caller (never inlined into the
  by-value `Snapshot`): `bus.ram`, `vga.vram`, `vga.text_vram`, `vga.text_vram_mono`,
  and `ems.backing` (`src/dos/ems.zig:823` `backingBytes()`/`restoreBacking`).

The canonical "full machine snapshot" recipe is already written down in tests — the
design just lifts it onto the worker thread and adds a per-session store. Reference
recipes:

- Same-machine in-place round-trip: `src/dos/integration_test.zig:371`,
  `:405` (mouse), `:308` (EMS backing), `:1466` (in-flight IRQ12).
- Cross-machine restore into a *fresh* wired machine (proves the slab list is complete):
  `src/machine/machine_test.zig:273` (copies `bus.ram` + `vga.vram` + `vga.text_vram` +
  `vga.text_vram_mono`; `m2.restore(snap)` then `@memcpy` each slab).
- **Run-from-restored == run-from-original** (the determinism proof we extend):
  `src/dos/nested_exec_debug_test.zig:474-500` snapshots mid-EXEC, restores into a
  fresh machine, runs to `program_terminated`, and asserts byte-identical end state.

## 1. Completeness of the existing snapshot

### 1.1 What `Machine.snapshot()` captures (enumerated)

`Machine.snapshot()` (`machine.zig:900`) returns a `Machine.Snapshot` (`:811`). **As shipped
today it is NOT byte-identical-resume complete** — it omits three guest-mutable DOS scalars
(§1.1.1). With those three added, plus **the five out-of-band slabs**, it *is*
byte-identical-resume complete:

| State | In `Snapshot` POD | Out-of-band slab | Cite |
|---|---|---|---|
| CPU state incl. **cycle counter** (`cpu.st.cycles`) | ✅ `cpu_state` | — | `machine.zig:902`, `:931` |
| Guest RAM (1 MiB + HMA, `ram_total_size=0x110000`) | bus tables only | ✅ `bus.ram` 1,114,112 B | `bus.zig:1076`, `memmap.zig:19` |
| Bus A20 + page-kind + handler-id + **watch tables** | ✅ `bus` | — | `bus.zig:1058-1075` |
| VGA registers/DAC | ✅ `vga` | ✅ `vga.vram` 256 KiB | `machine.zig:823`, `vga.zig:60-66` |
| VGA text pages (B8000/B0000) | — | ✅ `text_vram`+`text_vram_mono` 2×32 KiB | `machine.zig:819-822`, `vga.zig:84` |
| PIC / PIT / speaker / OPL / keyboard | ✅ | — | `machine.zig:904-909` |
| Scheduler (pending PIT/kbd events) | ✅ `sched` | — | `machine.zig:910` |
| INT 33h mouse driver (incl. `pending_event_mask`) | ✅ `dos_mouse` | — | `machine.zig:911`, `:855` |
| EMS bookkeeping (handles/frame map/cursor) | ✅ `dos_ems` | ✅ `ems.backing` ~15 MiB | `machine.zig:856-862`, `ems.zig:63` |
| DOS kernel subset (psp/drive/dta/ret/terminated) | ✅ | — | `machine.zig:870-876` |
| DOS scalars **strategy/last_error/breakcheck** (TO ADD — §1.1.1) | ⚠️ NOT YET | — | `dos.zig:102`,`:105`,`:106` |
| `shutdown` latch | ✅ | — | `machine.zig:877` |
| Clock `mult` + continuous device-time accumulator | ✅ `clock`/`device_time`/`dt_*` | — | `machine.zig:878-897` |

**Total snapshot footprint = 16.31 MiB**, dominated by the EMS backing slab
(15,663,104 B ≈ 92%): `1,114,112 + 262,144 + 32,768 + 32,768 + 15,663,104` = **17,104,896 B**
(16.31 MiB) plus a ~70 KiB POD (`Bus.Snapshot.port_handler_id[65536]` is the bulk of the POD
— `bus.zig:1062`). Under the LOCKED full-snapshot design every slab is fixed-size, so this
total is a **compile-time constant** (the `bytes` metadata is therefore constant too — kept
as a per-slot field only for forward-compat with a future zero-skip/RLE EMS encoding, §3).

#### 1.1.1 Three guest-mutable DOS scalars to ADD to `Machine.Snapshot`

The current `Machine.Snapshot` (`machine.zig:811`) captures only the DOS *process* subset
(`dos_current_psp`…`dos_terminated`, `machine.zig:870-876`). It **OMITS three scalars that
the guest can both set and read back**, so today a restore would silently revert them to
whatever the live `Dos` holds:

| Field | Decl | Guest write | Guest read |
|---|---|---|---|
| `strategy` (`mcb_mod.Strategy`) | `dos.zig:102` | INT 21h AX=5801 (`int21.zig:1428`) | AX=5800 (`int21.zig:1425`) |
| `last_error` (`u16`) | `dos.zig:105` | set on DOS errors | AH=59 (`int21.zig:1141`) |
| `breakcheck` (`bool`) | `dos.zig:106` | AH=33 subfn 1/2 (`int21.zig:1122`) | AH=33 subfn 0/2 (`int21.zig:1121`) |

**Fix (same shape as the nested-EXEC `dos_current_psp` work):** add three POD fields to
`Machine.Snapshot` —
```
dos_strategy: mcb_mod.Strategy,
dos_last_error: u16,
dos_breakcheck: bool,
```
assign them in `snapshot()` (`machine.zig:900`, alongside `:913-919`) and write them back in
`restore()` (`machine.zig:930`). All three are POD/snapshot-safe. With them added, the §4
"run-from-restored == run-from-original" determinism claim is exact; without them a guest that
tweaks its allocation strategy / break-check flag and reads it back after a restore would
diverge.

Re-bound on restore (NOT serialized — they are host pointers into the machine's own
fields, valid because we restore **in place** onto the already-`wire()`'d session
machine): every device back-pointer (`cycles`/`mult`/`device_time`/`dt_accounted`,
`machine.zig:383-423`), the INT 33h PIC seam (`bindMouseSeam` `:621`), the scheduler
thunks, and the bus handler registrations. `Machine.restore()` only overwrites POD
fields, so these stay valid (`machine.zig:950-963`). This is exactly why the in-place
round-trip tests pass without re-wiring.

### 1.2 Gaps to FLAG (ground rule #3 — surfaced, not papered over)

These are **host-side state NOT in `Machine.Snapshot`**. For our use case (in-place
restore onto the SAME wired+mounted session machine) most are harmless, but two are real:

1. **Open file handles / SFT / file positions / mounted-drive table / cwd / search
   state / CON stdin cursor.** `machine.zig:838-849` explicitly classifies `sft`,
   `dev_table`, `drives`, `cwd`, `search_dir*` as "host-side device/VFS state … NOT
   captured" — a *pre-existing, documented* snapshot gap. Consequences:
   - **Mount table**: harmless for us — restore is **in-place** on the already-mounted
     machine and `restore()` never touches `dos.drives`, so the live mount persists.
     (A cross-machine restore *would* lose it; we do not do that.)
   - **Open files mid-read**: a genuine gap. If the guest holds a file open with a
     non-zero seek position at snapshot time, a later restore does **not** reopen it or
     rewind the host fd. For the dominant read-only game-debugging workflow (open →
     read → close within one trap) this rarely bites, but it MUST be documented as a
     known limitation. *Closing it faithfully* would require snapshotting the SFT +
     re-`lseek`-ing host fds on restore — out of scope for v1; flag for the user.
   - **CON stdin cursor** (`dev_table` CON `in_buf/in_pos/in_len`): deferred-coverage
     item already noted at `machine.zig:843-849`; only matters if the INT 21h stdin
     injection path is exercised (it is not today).

2. **Controller debug state is observer state, not machine state.** Breakpoints
   (`Controller.set`), `watch_ids`/`port_watch_ids`, and `last_stop`
   (`src/debug/controller.zig:411-420`) are NOT in `Machine.Snapshot`. Design intent:
   breakpoints **survive** a restore (LOCKED), exactly as they survive a `reset`
   (`controller.zig:1161-1163`). **But there is a real coupling to close:** the bus
   memory/IO **watch tables ARE inside `Machine.Snapshot`** (`bus.zig:1063-1075`), so
   `restore()` reverts them to the snapshot instant. The controller's `watch_ids`/
   `port_watch_ids` (`controller.zig:416-420`) are observer state and are NOT reverted.
   If a `memory`/`io` breakpoint was added/removed between snapshot and restore, the
   controller's live `watch_ids` and the reverted bus watch tables **desync** (a phantom
   or dangling watch). **Resolution (`Controller.rearmWatches()`, CLEAR-THEN-REBUILD):**
   after `m.restore(...)` the helper must (1) **clear** every snapshot-reverted bus
   watch + reset the controller's `watch_ids`/`port_watch_ids` to a known-empty state,
   then (2) **rebuild** them by re-deriving from the live breakpoint set — i.e. walk the
   `.memory`/`.io` breakpoints and re-`setWatch`/`setPortWatch` exactly as
   `addBreakpoint` does (`controller.zig:586-637`). A naïve "just re-`setWatch`" WITHOUT
   the clear would stack new entries on top of the reverted ones and exhaust/duplicate
   the bounded watch table (`Bus.setWatch` → `BreakpointTableFull`, `controller.zig:598`).
   See §4 + Decision D2.

3. **Pure host/observer state, correctly excluded:** `live_mouse` (`session.zig:286`
   — "NOT machine state, NOT snapshotted"), the render buffers / `shared_frame` /
   `stream_hub` (host output), and any future **branch-trace** (observer state, NOT
   part of the restored machine — restoring rewinds the machine, the trace log is a
   separate observation stream).

**Verdict:** once the three DOS scalars of §1.1.1 are added, the asset is
byte-identical-complete for the **full machine** (CPU+RAM+all devices+scheduler+EMS+mouse+
clock+DOS-process subset) — provable by extending `machine_test.zig:273` and
`nested_exec_debug_test.zig:474`. The **one accepted v1 resume gap** for our in-place
workflow is **open-file/SFT state**; flag it as a documented v1 limitation, and close the
**bus-watch/breakpoint re-sync** with a clear-then-rebuild re-arm helper (§1.2 #2). Note:
the draft's "byte-identical-complete / only open-files is a gap" claim was wrong *as of the
current code* — it is only true after the §1.1.1 fields land.

## 2. Architecture & plumbing

### 2.1 Per-session model (unchanged seams we thread through)

- `Session` owns one machine's world by value/pointer (`src/api/session.zig:200`); the
  registry mints N of them (`src/api/session_registry.zig:73`) with deterministic
  `zdos-sess-<seq>` handles (`:164`, `:211`).
- The **worker thread is the SOLE owner of the Machine** — it dequeues one
  `q.Command`, runs one `Controller` method, fills one `q.Response`
  (`src/api/worker.zig:95` `drainOne`, `:501` `Worker.run`). Snapshot/restore MUST run
  here.
- `q.Command`/`q.Response` are **pointer-free POD** unions (`src/api/queue.zig:62`,
  `:340`) — reflection-gated (`determinism_test.zig:148`). So the queue carries only
  small scalars; large buffers are reached the way `render`/`live_mouse` already are:
  **the worker holds a direct `?*` pointer**, NOT via the Command
  (`worker.zig:487-499`).
- MCP catalog + `buildCommand` (`src/api/mcp_tools.zig:74`, `:711`) build the SAME
  PODs the HTTP handlers build; results serialize through the shared
  `writeResponseBody` (`server.zig:2451`) — the anti-drift authority for HTTP **and**
  MCP.

### 2.2 New storage owner: `SnapshotStore` (new file `src/api/snapshot_store.zig`)

A per-`Session` heap block (allocated by the session allocator, like
`RenderBuffers`/`run_control` in `Session.init` `session.zig:306-335`), reached by the
worker via a direct pointer. The `SnapshotStore` struct itself is small (just the slot
array + counters) and is `gpa.create`'d once; the **big slabs hang off each slot as
optional heap pointers**, allocated lazily. Each slot holds:

- `snap: Machine.Snapshot` (the POD).
- The five out-of-band slabs as **optional heap slabs** — `?*[memmap.ram_total_size]u8`,
  `?*[vga.VRAM_SIZE]u8`, two `?*[vga.TEXT_WINDOW_LEN]u8`,
  `?*[ems.BACKING_PAGES*ems.PAGE_SIZE]u8` (or equivalently a single `?[]u8` covering all
  five regions at fixed offsets). `null` until the first `snapshot` lands in the slot.
- Metadata: `occupied: bool`, `seq: u64` (the `snap-<n>` id), `cycle: u64`, `bytes: u64`.

**Lazy, NOT inline.** The slabs MUST be optional heap pointers, not inline fixed arrays
inside the slot struct. Inline arrays would make `@sizeOf(SnapshotStore)` =
`MAX_SNAPSHOTS × 16.31 MiB` ≈ **131 MiB**, forced eager at `Session.init` for every
session — directly contradicting §3/Risk-1/D1's "idle session costs nothing." With
optional pointers, `snapshotResp` `gpa.alloc`s a slot's ~16.31 MiB **on the first
snapshot that lands in it** and reuses it on subsequent re-snapshots into the same slot;
an idle (or never-snapshotted) session pays zero. The freeing rule this implies is in
§3 ("Cleanup") — a per-slot free loop, because the draft's single `gpa.destroy` line is
correct only for the inline-array shape we are NOT using.

A monotonic `next_seq: u64` on the store mints deterministic `snap-<n>` handles (mirrors
the registry's `next_seq` → `zdos-sess-<n>`, `session_registry.zig:94-96`,
`session.zig:118` SessionId discipline) — **no clock, no RNG**.

The worker reaches the store exactly like `render`:
```
pub const Worker = struct { ...; snapshots: ?*SnapshotStore = null, ... };
```
set in `Server.bind`/`main.zig` (default session) and `SessionRegistry.create`'s
worker-spawn site (`session_registry.zig:228-236`).

### 2.3 New commands + how each threads the layers

Add to `q.Command` (`queue.zig:62`) — all pointer-free POD:
```
snapshot: void,                 // capture; returns snap-<n> + cycle + bytes
restore: struct { seq: u64 },   // rewind to a handle
list_snapshots: void,
delete_snapshot: struct { seq: u64 },
```
Add to `q.Response` (`queue.zig:340`):
```
snapshot_done: struct { seq: u64, cycle: u64, bytes: u64 },
snapshot_list: SnapshotListResult,   // fixed array of {seq,cycle,bytes}, count, max
snapshot_deleted: struct { seq: u64 },
```
Add an `ErrCode.snapshot_limit_reached` and `ErrCode.no_such_snapshot`
(`queue.zig:216`). The `seq` is parsed from the `snap-<n>` text by the handler/mapper
(integer-only), so the queue carries a `u64`, never a string.

`drainOne` (`worker.zig:95`) gains four arms, mirroring `framebuffer_get`'s
"reach-the-pointer" style (`worker.zig:169`, `:420`):
```
.snapshot       => snapshotResp(ctrl, snapshots),
.restore        => restoreResp(ctrl, snapshots, c.seq),
.list_snapshots => listSnapshotsResp(snapshots),
.delete_snapshot=> deleteSnapshotResp(snapshots, c.seq),
```
- `snapshotResp`: pick a free slot (else `snapshot_limit_reached`) → **if the slot's
  slabs are `null`, `gpa.alloc` them now (lazy first-use alloc)**; on alloc failure
  surface a clean error, never a panic → `slot.snap = ctrl.m.snapshot()` → `@memcpy` the
  five slabs from `ctrl.m.bus.ram` / `ctrl.m.vga.vram` / `.text_vram` / `.text_vram_mono`
  / `ctrl.m.dos.ems.backingBytes()` → stamp `seq=next_seq++`,
  `cycle=ctrl.m.cpu.st.cycles`, `bytes=TOTAL` (the constant 17,104,896). **Pure read** of
  the machine (no cycle charge — like the other peeks, `worker.zig:13`).
- `restoreResp`: find slot by `seq` (else `no_such_snapshot`) → `ctrl.m.restore(slot.snap)`
  → `@memcpy` the five slabs back → `ctrl.m.dos.ems.restoreBacking(...)` →
  `ctrl.rearmWatches()` (clear-then-rebuild, §1.2 #2 / D2) → `ctrl.last_stop = null`
  (coherent status, like `load` `worker.zig:478`) → (cross-feature) signal the
  branch-trace to auto-clear (§4). Deterministic mutation at the serialized command
  boundary.

MCP catalog rows + `buildCommand` arms (`mcp_tools.zig:74`, `:711`) — these are
**per-machine** tools (`per_machine=true`, routed by the `machine` arg like
step/run, NOT server-special). `restore`/`delete_snapshot` parse `{snapshot:"snap-<n>"}`
→ `seq` via a tiny shared parser. HTTP gets parallel routes (`POST /api/snapshot`,
`POST /api/restore`, `GET /api/snapshots`, `DELETE /api/snapshot/<id>`) whose handlers
build the SAME commands and share `writeResponseBody`. New `writeResponseBody` arms
(`server.zig:2451`) use the existing `writeValue` helper for the three new response
variants. New source files get added to the determinism grep set
(`determinism_test.zig:22-68`).

## 3. Storage, handles, lifecycle, memory

- **Location:** per-`Session`, in the `SnapshotStore` heap block (session allocator),
  freed in `Session.deinit` (`session.zig:349`) alongside `render`/`run_control`. The
  worker is the sole writer/reader (machine-owner thread), so no extra lock.
- **Handles:** `snap-<n>`, `n` from the store's monotonic `next_seq` (never reused).
  Deterministic, clock-free, RNG-free.
- **Capacity cap:** `MAX_SNAPSHOTS = 8` per session (LOCKED; a one-line knob, mirroring
  `SessionRegistry.MAX_SESSIONS=8` `session_registry.zig:107`). At the cap, `snapshot`
  returns `snapshot_limit_reached` — **no time/LRU eviction** (eviction would inject host
  scheduling into which checkpoint survives, violating determinism; same posture as the
  registry's no-eviction rule `session_registry.zig:98-100`). Reclamation is explicit
  `delete_snapshot`; recovery is `list_snapshots`.
- **Memory budget:** 16.31 MiB/slot (the constant of §1.1). At cap 8 ⇒ ~130 MiB of slabs
  per *fully-snapshotted* session, **on top of** the session's own ~21 MiB machine
  (`session_registry.zig:104`). With `MAX_SESSIONS=8` the worst case is
  `8 × (21 + 8×16.31)` ≈ **~1.2 GiB**. This is the **accepted budget** (D1): the user
  accepted "16 MiB is nothing" and cap 8, and the full-snapshot design trades RAM for
  correctness simplicity. The only structural mitigation that ships is (a) **lazy slab
  alloc** — a slot's 16.31 MiB is `gpa.alloc`'d only on first use, so an idle or
  lightly-checkpointed session pays far less than the worst case. **Future** (NOT v1):
  (b) zero-skip/RLE on the EMS backing (~15 MiB is usually all-zero for non-EMS guests —
  the same "quadratic trap" the EMS comment warns of, `ems.zig:825`); this is why `bytes`
  is kept per-slot even though it is constant today. The cap × `MAX_SESSIONS` interaction
  is **Decision D1** (accepted).
- **Lifecycle on `reset`/`load`:** snapshots **survive** (they are self-contained saved
  machine states the operator explicitly captured; restoring a pre-reset snapshot is a
  core use case). `reset`/`load` already do not touch the store.
- **Cleanup on `deprovision`:** `SessionRegistry.teardown` frees the session
  (`session_registry.zig:325` `session.deinit`), which must free the store. Because the
  slabs are **lazy heap allocations**, `Session.deinit` (`session.zig:349-355`) needs a
  **per-slot free loop that frees each non-`null` slab BEFORE `gpa.destroy(self.snapshots)`**
  — e.g. `for (store.slots) |*s| { if (s.ram) |p| gpa.free(p); … }` then
  `gpa.destroy(store)`. The draft's single `gpa.destroy(self.snapshots)` line was correct
  only for the inline-array shape we rejected in §2.2; for lazy slabs that one line **leaks
  every allocated slab**.

## 4. Determinism & correctness

- **`snapshot` is a pure read.** It only memcpys machine state out; charges no cycles
  (the peek discipline, `worker.zig:13`). The determinism harness never calls it, so all
  goldens are untouched.
- **`restore` is a deterministic mutation** applied at the serialized worker-command
  boundary — exactly like `reset`/`load`/`set_clock` (`worker.zig:175-181`,
  `machine.zig:980-983`). It charges no cycles (a state load).
- **Paced-run stall (wall-clock only, determinism unaffected).** Both `snapshot` and
  `restore` are single worker commands that do a ~16.31 MiB memcpy (~92% of it the 15 MiB
  EMS slab). While one runs, the host pacer's `run_slice` blocks on the submit gate, so a
  live paced run hiccups for the duration of the copy. This is a **wall-clock hiccup only**
  — the cycle state is captured/applied atomically at the serialized command boundary, so
  emulated time and all goldens are unaffected. Acceptable at the small cap-8 working set.
- **Restore resets the cycle counter** to the snapshot's cycle, because `cpu.st.cycles`
  is inside `cpu_state` (`machine.zig:902`, `:931`). So `run_to_cycle` to a now-future
  cycle and `cycle` breakpoints behave correctly after a rewind (deadline math is
  `cpu.st.cycles +| cycle_cap`, `controller.zig:446`).
- **Byte-identical proof (extend the double-mint pattern):**
  `snapshot → mutate (RAM/CPU/devices) → restore → assert byte-identical` reusing the
  recipe at `integration_test.zig:371`/`machine_test.zig:273`, but driven through the
  worker queue. And **run-from-restored == run-from-original** by extending
  `nested_exec_debug_test.zig:474`: capture at cycle N via the tool, restore, run to a
  terminal, assert the same end state as the uninterrupted reference. **This claim is
  exact only once the three §1.1.1 DOS scalars (`strategy`/`last_error`/`breakcheck`) are
  in `Machine.Snapshot`** — without them a guest that mutates and re-reads one of those
  would diverge after restore. Add a focused test that sets all three (AX=5801, force a
  `last_error`, AH=33 set), snapshots, perturbs them, restores, and asserts they revert.
- **Deterministic handles:** `snap-<n>` from a monotonic counter — no host clock/RNG.
- **Breakpoints:** KEPT across restore (LOCKED; observer/debug-session state, like `reset`
  `controller.zig:1161`); the bus-watch re-sync is closed by `rearmWatches()`, which is
  **clear-then-rebuild** (§1.2 #2 / Decision D2) — clear the snapshot-reverted bus watches
  first, then rebuild from the live breakpoint set, so re-arming never stacks on the
  reverted entries.
- **Branch-trace cross-feature interaction (composition review).** The forthcoming
  branch-trace feature is OBSERVER state, explicitly **not** part of the restored machine —
  `restore` rewinds the machine; the trace stream is separate. Two couplings the operator
  must respect:
  - **(a) The `[snapshot, target]` window must be input-free.** Injected keys/mouse are
    *not* a replayable input stream — `restore` rewinds machine state but does NOT
    re-inject the events that drove the guest between the checkpoint and the target. So a
    "branch from snapshot to target" workflow only reproduces the original timeline if no
    keyboard/mouse was injected in that window; **checkpoint AFTER the last triggering
    input.** With injected input in the window, restore-then-run diverges.
  - **(b) `restore` auto-clears the branch trace.** The branch-trace doc owns the actual
    clear, but the `restore` command is what triggers it: after a rewind, leaving the old
    trace in place would interleave two timelines whose `at_cycle` stamps overlap (the
    rewound run re-emits cycles ≤ the trace's existing entries). So `restoreResp` signals
    the trace to reset — see the §2.3 `restoreResp` step.

## 5. MCP / HTTP tool surface

All four are **per-machine** (routed by the `machine` arg; the `tools/list` emitter
injects the `machine` property, `mcp_tools.zig:354`). Schemas are hand-authored ASCII
(no floats, integer-only — the §8/determinism posture).

| Tool | Input schema | Result body |
|---|---|---|
| `snapshot` | `{}` (+ injected `machine`) | `{"handle":"snap-<n>","cycle":N,"bytes":N}` |
| `restore` | `{"snapshot":"snap-<n>"}` required | `{"handle":"snap-<n>"}` |
| `list_snapshots` | `{}` | `{"snapshots":[{"handle","cycle","bytes"}],"count":N,"max":N}` |
| `delete_snapshot` | `{"snapshot":"snap-<n>"}` required | `{"handle":"snap-<n>","deleted":true,"count":N}` |

Descriptions (catalog `mcp_tools.zig:74`):
- `snapshot`: "Capture the full live machine state (CPU, RAM, all devices, scheduler,
  EMS, DOS process state, cycle counter) as a checkpoint; returns an opaque snap-<n>
  handle, the cycle it was taken at, and its size in bytes. Cycle-neutral (a pure read).
  Open guest file handles are NOT captured (a documented limitation)."
- `restore`: "Rewind the machine to a previously captured snapshot handle. Resets the
  cycle counter to the snapshot's cycle; breakpoints are preserved. Deterministic."
- `list_snapshots` / `delete_snapshot`: enumerate / free checkpoints.

Anti-drift: HTTP routes build the identical `q.Command`s and both transports serialize
through the SAME `writeResponseBody` arms (`server.zig:2451`) + `errInfo`
(`server.zig:2685`) — the project's enforced one-authority rule (the off-worker grep
`determinism_test.zig:114` stays green because the handlers only `submit()`).

## 6. Phased plan, tests, audit checklist, risks

### Phases
1. **Store + worker core** (no transport): `src/api/snapshot_store.zig`
   (`SnapshotStore`, slots, lazy alloc, `snap-<n>` seq); `worker.zig` `Worker.snapshots`
   field + four `drainOne` arms + helpers; `queue.zig` new Command/Response/ErrCode.
   `Controller.rearmWatches()` in `src/debug/controller.zig`. *Unit test directly on the
   store + a worker harness.* (~250 LOC + ~120 test)
2. **Session/registry plumbing:** `Session` field + alloc/free (`session.zig`); pass to
   worker at both spawn sites (`session_registry.zig:228`, `main.zig` default session).
   (~40 LOC)
3. **MCP surface:** four catalog rows + `buildCommand` arms + the `snap-<n>` parser
   (`mcp_tools.zig`); `writeResponseBody` arms (`server.zig`); add new source files to
   `determinism_test.zig:22` embed set. (~150 LOC + ~80 test)
4. **HTTP surface:** parallel routes sharing the same commands/serializers. (~80 LOC)

### Tests
- `snapshot → poke RAM/CPU/a device → restore → assert byte-identical` (extends
  `integration_test.zig:371`), driven through the queue.
- **run-from-restored == run-from-original** (extends `nested_exec_debug_test.zig:474`).
- EMS-backing round-trip through a snapshot handle (extends `integration_test.zig:308`).
- **Capacity + explicit-delete:** fill to `MAX_SNAPSHOTS`, assert
  `snapshot_limit_reached`, `delete_snapshot`, then `snapshot` succeeds; `list_snapshots`
  reflects the set; deterministic `snap-<n>` ordering.
- `restore` of an unknown handle → `no_such_snapshot`.
- Cycle-counter rewind: snapshot at N, run forward, restore, assert
  `status.cycles == N` and a `run_to_cycle(N+k)` works again.
- Schema/serializer anti-drift (mirrors `mcp_tools.zig:1051` / the HTTP-MCP equivalence
  tests).

### Determinism-audit checklist
- [ ] `snapshot`/`restore` charge zero cycles; harness goldens unmoved.
- [ ] Handles are `snap-<n>` from a monotonic counter (no clock/RNG).
- [ ] New `q.Command`/`q.Response` stay pointer-free POD (`determinism_test.zig:148`
      reflection gate passes; the store is reached via the worker pointer, not the queue).
- [ ] New `src/api` files carry no float/clock/RNG (added to grep `:22-68`).
- [ ] `restore` resets `cpu.st.cycles` and clears `last_stop`; breakpoints preserved +
      bus watches re-armed via `rearmWatches()` **clear-then-rebuild** (no desync, no
      stacked/duplicated watch-table entries).
- [ ] The three §1.1.1 DOS scalars (`strategy`/`last_error`/`breakcheck`) round-trip a
      snapshot/restore (dedicated test).
- [ ] Lazy slabs: idle session allocates no slab; `Session.deinit` per-slot free loop
      frees every allocated slab before `gpa.destroy(store)` (no leak under the leak-check
      allocator).
- [ ] Off-worker grep stays green (`determinism_test.zig:114`): server only `submit()`s.

### Risks
1. **Memory budget** (cap 8 × MAX_SESSIONS 8 × 16.31 MiB slabs + 8 × 21 MiB machines ≈
   **~1.2 GiB** worst case). ACCEPTED per D1; **lazy slab alloc** keeps the typical
   working set far below worst case (idle/lightly-checkpointed sessions pay near zero).
2. **EMS 15 MiB copy per snapshot** — the quadratic trap (`ems.zig:825`), and the
   paced-run submit-gate stall it causes (§4). Acceptable at cap 8; flag zero-skip/RLE as
   a future optimization (forward-compat `bytes` field already in place).
3. **Three DOS scalars missing from `Machine.Snapshot`** (§1.1.1) — real correctness gap
   in the *current* code; closed by adding `strategy`/`last_error`/`breakcheck` POD fields.
4. **Bus-watch / breakpoint desync on restore** — real; closed by `rearmWatches()`
   (clear-then-rebuild, Decision D2). Without it, memory/IO breakpoints added after a
   snapshot misbehave or exhaust the bus watch table.
5. **Lazy-slab teardown leak** — if `Session.deinit` only `gpa.destroy`s the store
   struct, every allocated slab leaks; closed by the per-slot free loop (§3).
6. **Open-file state not captured** — accepted v1 limitation (§1.2 #1); only bites guests
   holding files open across the snapshot boundary.
7. **Branch-trace composition** — injected input in the `[snapshot, target]` window
   breaks reproduction; restore auto-clears the trace (§4).

## Decisions (LOCKED — recorded, no longer open)
- **D1 — cap & memory budget — LOCKED.** `MAX_SNAPSHOTS = 8`/session; full snapshot
  always; **lazy slab alloc**. Worst case `8 × (21 + 8×16.31)` ≈ **~1.2 GiB** is the
  accepted budget (user: "16 MiB is nothing", cap 8). No eviction; reclamation is explicit
  `delete_snapshot`.
- **D2 — breakpoints across restore — LOCKED.** Breakpoints **persist** across restore
  (consistent with `reset`); add `Controller.rearmWatches()` (clear-then-rebuild) to
  re-sync the snapshot-reverted bus watches with the live breakpoint set.
- **D3 — open-file gap — ACCEPTED as a documented v1 limitation.** "Open file handles not
  captured" (§1.2 #1). Scoping SFT capture in (re-`lseek` host fds on restore; touches
  `dos` host-side state at `machine.zig:838`) is deferred past v1.

### Residual open item
- **§1.1.1 must ship as part of v1** — adding `strategy`/`last_error`/`breakcheck` to
  `Machine.Snapshot` is the one *new* correctness prerequisite this review surfaced (the
  draft wrongly assumed completeness). It is small and POD; called out so the user signs
  off on extending the proven `Machine.Snapshot` format rather than leaving the gap.
