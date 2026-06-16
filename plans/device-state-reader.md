# Device / chipset / A20 state reader (debugger API)

Status: PLAN (no code written). Owner: debugger surface (ROADMAP `[later]` "device-state readers").

## Why

Debugging the real Stunts EXEPACK load failure, the root cause was the BIOS POST
**enabling the A20 gate** — which defeated the 8086 1 MiB wraparound the EXEPACK
self-decompressor depends on. That state was **invisible through the API**: no endpoint
exposes the A20 gate, the PIC/PIT/VGA register state, the 8042, or a non-mutating view of
an I/O port. It had to be inferred indirectly from memory-wrap behavior (read through
`0xFFFF:0x510` and observe whether it wrapped). A device-state reader makes the chipset
directly observable, so the next "the hardware is in an unexpected state" bug is a single
GET away instead of a memory-archaeology session.

This is the same class of feature as `/api/cpu`, `/api/screen`, `/api/framebuffer`,
`/api/memory-regions`, `/api/ivt/<n>`, `/api/stack` — a side-effect-free inspection
surface over machine state, serviced on the worker, charging zero cycles.

## References consulted (file:line)

zdos (the model + the state to expose):
- `src/api/server.zig:436-622` — the `dispatch` route table; the `/api/health` off-worker
  pattern (`:436`), the `/api/screen` server-parsed-flag pattern (`:452`, `submitAndRespondScreen`
  `:977`), `/api/framebuffer` (`:460`), `/api/memory-regions` (`:476`), `/api/ivt/<n>` (`:578`).
- `src/api/server.zig:1122-1141` — `respondRegions`/`respondMem`: the grouped-JSON serializer
  idiom (a fixed `resp_buf` + `std.json.Stringify.value` over an inline fixed array). The new
  `/api/devices` serializer mirrors this.
- `src/debug/controller.zig:588-905` — the **side-effect-free peek path**: `cpuSnapshot` (`:591`),
  `peekMemPhys`/`peekMem` (`:638`/`:643`) routed through `bus.peekBlock` (NEVER device read
  handlers), `screen` (`:688`), `framebuffer` (`:771`), `status` (`:884`). Doc comment `:11-12`:
  "Inspection is side-effect-free (the bus peek path), so an inspect leaves `machine.snapshot()`
  byte-identical." This is the purity contract the new reader must satisfy.
- `src/api/queue.zig:62-136` — the `Command` union (note the `void` commands `console_get`/
  `screen_get`/`framebuffer_get`/`status`/`mem_regions`); `Response` union (`:269`), `ErrCode`
  (`:168`), `RegionsResult` (`:264`), the "all payloads pointer-free POD" rule.
- `src/api/worker.zig` — the worker dispatch that maps each `Command` → a `Controller` call →
  a `Response` (the sole machine-touching thread).
- `src/bus/a20.zig:18-31` — `mask_enabled` (`0x1F_FFFF`) / `mask_disabled` (`0x0F_FFFF`).
- `src/bus/bus.zig:99-100,223-234` — `a20_mask` field + `setA20`/`a20Enabled()` (**the accessor
  the reader reuses for A20 — it already exists**).
- `src/machine/machine.zig:131-135,453,512-514,608-626` — device ownership (`pic`/`pit`/`vga`/
  `keyboard`/`speaker`), POST `setA20(false)` (`:453`), `enableA20` (`:512`), the `Snapshot`
  aggregate (`:566-626`) that already pulls every device's `snapshot()`.
- `src/devices/pic.zig:31-51,344-354` — `Controller` fields (irr/isr/imr/vector_base/icw_index/
  read_isr/special_mask/priority_base) + `Pic.Snapshot`.
- `src/devices/pit.zig:70-139,472-481` — `PitChannel` fields + `liveCounter`/`outBit`/`statusByte`
  (the **cycle-derived** values — pure functions of `cpu.st.cycles`); `Pit.Snapshot`.
- `src/devices/vga.zig:175-401,896-934,1158-1219` — register files (`seq`/`crtc`/`gfx`/`attr`),
  DAC state, `pel_mask`, `misc_output`, `attr_flip_flop_is_index`, `feature_control`, latches;
  `statusReg1` (the cycle-derived 0x3DA — **computed, never read**); `Vga.Snapshot`.
- `src/devices/keyboard.zig:99-122,346-381` — 8042 fields (fifo/status/config/output_port/
  pending) + `Keyboard.Snapshot`.
- `src/devices/speaker.zig:55-66` — port-0x61 latch.
- `src/dos/ems.zig:47-63,138-169` — `REPORTED_PAGES`/`BACKING_PAGES`, handle table, `Ems.Snapshot`.

Reference emulators (both surface this state; zdos's twist is side-effect-free + cycle-derived):
- dosbox-x `src/debug/debug.cpp:2665` — `A20` debug command (on/off/query); `:2684` — `PIC`
  command + `DEBUG_LogPIC()` (`:2726`) dumping master/slave IRR/ISR/IMR + per-IRQ mask/in-service.
  These are interactive console commands that read live device state directly.
- spice86 dedicated debugger ViewModels: `src/Spice86/ViewModels/VideoCardViewModel.cs` (VGA
  register/CRTC/DAC state), `PaletteViewModel.cs` (DAC palette), `EmsViewModel.cs` +
  `EmsHandleEntryViewModel.cs`/`EmsLogicalPageEntryViewModel.cs`/`EmsPhysicalPageEntryViewModel.cs`
  (EMS handle/page map), `DosMemoryOverviewViewModel.cs` (memory config). spice86 reads the live
  C# device objects' fields directly (its introspection model). zdos's improvement over both:
  the read is provably side-effect-free (snapshot-before == snapshot-after) and any timing-derived
  value (0x3DA, PIT counters, ch2 OUT) is a deterministic `f(cycles)`, not a host-clock sample.

## The critical rule: side-effect-free peeks of RAW FIELDS — never `in8`/port reads

**Every exposed value MUST be a raw-field read (or a pure cycle-derived computation), NEVER a
call into the device's `in8`/port-read handler.** Port reads mutate device state; that mutation
would (a) corrupt the very state we are trying to observe and (b) break the prime directive
(`machine.snapshot()` must be byte-identical before and after any inspect — `controller.zig:11-12`).

The model is exactly `Controller.cpuSnapshot`/`screen`/`framebuffer`: they read struct fields and
the bus *peek* path, never `cpu` side-effecting ops or device port handlers.

### Dangerous ports — reading these via `in8` MUTATES state (do NOT call them)

| Port(s) | Device | Mutation on read (why a peek must read the raw field instead) |
|---|---|---|
| `0x3DA` / `0x3BA` | VGA Input Status #1 | Resets the AC address/data flip-flop to index phase (`vga.zig:912-915`, sets `attr_flip_flop_is_index=true`). Reader: **compute** the retrace/display bits from `cpu.st.cycles` via the same integer math `statusReg1` uses (do NOT call `statusReg1` — it writes the flip-flop). Expose `attr_flip_flop_is_index` as a separate raw field. |
| `0x3C9` | VGA DAC data | Each read returns one R/G/B sub-byte and **advances** `dac_pel_index`, then `dac_read_index` after a full triple (`vga.zig:871-896`). Reader: read `dac_rgb[]`/`dac_read_index`/`dac_write_index`/`dac_pel_index`/`dac_state` raw. |
| `0x3C7` | VGA DAC state | Read returns `dac_state`; harmless-ish but go through the raw field for uniformity. |
| `0x20`/`0xA0` (cmd) | PIC | An `in8` returns IRR **or** ISR per the last OCW3 `read_isr` latch — reading does not itself flip the latch, but synthesizing "give me both IRR and ISR" via `in8` is impossible without issuing OCW3 writes (which DO mutate `read_isr`). Reader: read `irr`/`isr`/`imr` raw — expose all three unconditionally. |
| `0x40`/`0x41`/`0x42` | PIT counters | `in8` walks the lobyte/hibyte read sequence and clears the counter latch (`pit.zig:320-348`, toggles `read_lohi_phase`, clears `latched`). Reader: read `reload`/`mode`/`access`/`latched`/`read_latch` raw and **compute** the live counter with `liveCounter(cyclesNow)` (a pure function — `pit.zig:119`, no mutation). |
| `0x60` | 8042 data | An `in8` **pops** the output FIFO and clears `ST_CMD`/OBF and may re-assert IRQ1 (`keyboard.zig:304-313`, `popByte`). Reader: read `fifo`/`fifo_head/tail/count`/`status`/`config`/`output_port`/`pending` raw — never pop. |
| `0x61` | KBC port B / speaker | bit 4 toggles (refresh), bit 5 samples ch2 OUT (cycle-derived). Reader: read the `speaker.port_b` latch raw + **compute** ch2 OUT via `pit.out2Bit()` (pure). |

General rule for the implementer: in the new `Controller` methods, touch only `self.m.<dev>.<field>`
and the pure compute helpers (`pit.liveCounter`, `pit.statusByte`, `pit.out2Bit`, and an
A20/0x3DA computation that does not write the flip-flop). If a value is only reachable by calling a
`portIn8`/`readPort`/`popByte`/`statusReg1`-that-mutates function, that is a structural signal to
add a pure raw-field accessor to the device (next to its existing `snapshot()`), NOT to call the
port handler. Surface the gap; never fake it by issuing a mutating read.

Determinism properties the reader inherits (all already true of the peek path): cycle-neutral
(charges 0 cycles), off the emulation worker's hot path (serviced as a normal one-in-flight
command on the worker thread), single-threaded w.r.t. the machine, no host clock (timing-derived
values are `f(cpu.st.cycles)`), no float/RNG/unordered iteration.

## Reuse existing snapshot accessors

Every device already has a by-value `snapshot()` built for save/restore that returns exactly the
raw POD we want to expose:
- `Pic.snapshot()` → `{master, slave}` Controllers (`pic.zig:348`).
- `Pit.snapshot()` → `{channels: [3]PitChannel}` (`pit.zig:475`).
- `Vga.snapshot()` → DAC + regs + flip-flop + latches (`vga.zig:1182`).
- `Keyboard.snapshot()` → fifo/status/config/... (`keyboard.zig:357`).
- `Speaker.snapshot()`, `Ems.snapshot()` likewise.

These are **provably side-effect-free** (they read fields by value) and already pointer-free POD,
so the reader's `Controller` methods SHOULD call them (or read the same fields) rather than invent
a parallel accessor. The only values NOT in a snapshot are the cycle-derived computed ones (PIT
live counter, PIT ch2 OUT, the 0x3DA retrace/display bits) — those are computed at read time from
the snapshot fields + `cpu.st.cycles` via the existing pure helpers. The reader therefore needs
**almost no new device code**: it is a thin presenter over the snapshot structs + the three pure
compute helpers. (One small addition may be warranted: a pure `Vga.statusReg1Peek(cyclesNow)` that
returns the assembled byte WITHOUT setting `attr_flip_flop_is_index` — i.e. `statusReg1` minus its
one mutating line — so the reader and the live port read share the bit math without duplicating it.)

## What to expose

Grouped by device. All values raw fields or pure `f(cycles)`.

- **A20** (the thing that was invisible): `enabled` (`bus.a20Enabled()`), `mask` (`bus.a20_mask`,
  hex), and the `kbc_output_port` bit-1 latch (`keyboard.output_port` bit 1) annotated as
  "latched, not the live A20 owner — the bus owns A20" (`keyboard.zig:79-81`).
- **PIC** (master + slave): `irr`, `isr`, `imr`, `vector_base`, `read_isr` (IRR vs ISR readback
  select), `special_mask`, `priority_base`, `icw_index` (mid-init indicator). Cite that `imr`
  power-on is `0xFF` (all masked).
- **PIT** (3 channels): per channel `mode`, `access`, `bcd`, `reload` (effective, 0→65536),
  `gate`, **`counter`** (= `liveCounter(cyclesNow)`, computed), **`output`** (= `outBit`, computed),
  `latched`/`status_latched` flags, `new_mode` (null-count). Note these are cycle-derived (move
  with the ledger) and the cross-emulator-golden caveat for ch2 OUT.
- **VGA**:
  - `mode` (BDA video mode, via peek of BDA 0x49 — same source `screen` uses), `misc_output`,
    `feature_control`, `pel_mask`, `attr_flip_flop_is_index`, `attr_pas`.
  - register files: `seq[0..5]`, `crtc[0..32]`, `gfx[0..9]`, `attr[0..21]` (+ each file's
    `index`) as hex byte arrays.
  - DAC: `dac_read_index`, `dac_write_index`, `dac_pel_index`, `dac_state`, and optionally the
    256×RGB palette (large — gate behind `?palette=1`, like `/api/screen?attrs=1`, so the default
    snapshot stays small).
  - `input_status1` = **computed** retrace(bit3)/display-enable(bit0) byte derived from
    `cpu.st.cycles` (the non-mutating computation), explicitly labeled "computed, not read".
  - latches `latch[0..4]`.
- **8042 / keyboard**: `status` (port-0x64 byte), `config` (command byte), `output_port`,
  `pending` (param-awaited), `fifo_count` + the FIFO contents (raw, not popped), `last_response`.
- **Speaker / KBC port B**: `port_b` latch (0x61) + computed ch2 `gate`/`out`.
- **DMA**: **NOT MODELED in zdos** (no 8237 in `src/devices/`). Expose `"dma": null` with a note,
  or omit the group. Do NOT fabricate a register set — surfacing the absence honestly is correct
  (and is itself useful: a guest that programs the DMA would reveal an unsupported path).
- **Memory config**: A20 (above) + conventional-memory ceiling (DOS arena top) + EMS config:
  `reported_pages`/`backing_pages` (`ems.zig:47-63`), `active_handles`, `user_pages`, page frame
  base/len. Reuse `Ems.snapshot()` fields. (Per-handle/per-page detail can be a later sub-endpoint,
  mirroring spice86's `EmsHandleEntryViewModel` — out of v1 scope.)

## Endpoint shape (recommended)

Three GET endpoints, all off the worker via `void`/tiny-POD commands, all side-effect-free:

1. **`GET /api/devices`** — the grouped JSON snapshot of ALL device state in one response:
   ```json
   { "a20": {...}, "pic": { "master": {...}, "slave": {...} },
     "pit": { "channels": [ {...}, {...}, {...} ] },
     "vga": {...}, "kbc": {...}, "speaker": {...}, "dma": null,
     "memory": { "ems": {...}, ... } }
   ```
   One round trip, one consistent worker-snapshot (no cross-device tearing). `?palette=1` (and any
   future bulky sub-array) is parsed server-side and only widens the JSON — the command stays
   `void` (the `/api/screen?attrs=1` pattern, `server.zig:457,977`). This is the primary endpoint.

2. **`GET /api/device/<name>`** — a single group (`name` ∈ `a20|pic|pit|vga|kbc|speaker|ems`),
   same data as the corresponding key in `/api/devices`. Cheaper payload when a client polls one
   device (e.g. watching A20 across POST). Unknown name → 404. Justification: avoids re-serializing
   the whole chipset when a debugger UI is polling just the PIT counters at 30 Hz.

3. **`GET /api/io?port=<n>`** — the **non-mutating shadow** of a single I/O port: the value an
   `in8(port)` would *currently* return, computed from raw fields **without** issuing the mutating
   read. Response: `{ "port": N, "value": "0xNN", "shadow": true, "note": "non-mutating view;
   a live IN may differ for stateful ports (DAC index advance, FIFO pop, AC flip-flop)" }`.
   Implemented as a pure `port → raw-field-or-computed-value` switch in the controller (NOT a call
   to the port dispatch table's `in8`). For ports whose live read is purely stateful with no stable
   shadow (e.g. `0x3C9` mid-triple), return the best-defined raw value (the indexed entry sub-byte
   at the current `dac_pel_index`) and keep the disclaimer. **Justification & honesty guard:** this
   is explicitly a *shadow*, never a live IN — naming it `/api/io` (not `/api/in`) and the `shadow`
   flag prevent a client mistaking it for a real port read (which would mutate). v1 can ship #1+#2
   and defer #3 if scope is tight, but #3 is the direct answer to the "I/O-port inspection" item in
   the ROADMAP and is cheap once the per-port shadow switch exists.

All three reuse the standard machinery: a new `Command` variant (`devices_get`, optionally
`device_get: {which}`, `io_shadow: {port}`), a `Response` POD (pointer-free fixed arrays — the
register files are small fixed sizes), a `Controller.devicesSnapshot()` (and friends) on the
side-effect-free peek path, a worker dispatch arm, and a `respondDevices`-style serializer that
mirrors `respondRegions` (`server.zig:1122`). The MCP layer (`api.zig`) gets these for free since
dispatch is transport-independent.

## Tests

Unit (controller, hermetic — a `Machine` directly):
- **A20 reported correctly**: after POST, `/api/devices`.a20.enabled == false (the EXEPACK
  regression's invariant; mirrors `bios_test.zig`'s "A20 OFF after POST"); after
  `machine.enableA20()` (INT 15h AX=2401 path) == true.
- **PIC fields** match a known post-BIOS-init state (e.g. master `vector_base==0x08`, slave
  `0x70` after ICW2; `imr` reflecting the BIOS mask) and power-on `imr==0xFF` pre-init.
- **PIT fields** match a known programmed state: after `OUT 0x43` ch0 mode-3 + a reload, the
  reported `mode`/`access`/`reload` match, and the computed `counter` equals `liveCounter` at the
  same `cycles` (assert the reader's value == a direct `liveCounter` call — proves it uses the pure
  helper, not a port read).
- **VGA fields** after a BIOS set-mode (e.g. mode 13h): `mode==0x13`, the dumped CRTC/SEQ register
  bytes match the known IBM VGA table (cross-check against the existing `vga_modes` tables), and
  the computed `input_status1` retrace bit matches `statusReg1`'s math at a fixed cycle.
- **Purity / cycle-neutrality (THE load-bearing test)**: take `machine.snapshot()`, call every
  reader method (`devicesSnapshot`, `io_shadow` for each dangerous port `0x3DA/0x3C9/0x60/0x40/
  0x61/0x20`), take `machine.snapshot()` again — assert **byte-identical** (and `cpu.st.cycles`
  unchanged). Specifically assert the VGA `attr_flip_flop_is_index`, `dac_pel_index`,
  `dac_read_index`, the PIT `read_lohi_phase`/`latched`, and the 8042 `fifo_count` are all
  UNCHANGED — the exact fields a real `in8` would have mutated. (Contrast guard: a separate test
  that DOES call `vga.in8(0x3DA)` and asserts the flip-flop DID flip, proving the danger is real
  and the reader avoids it.)

Integration (over HTTP, `server_test.zig`/`server_integration_test.zig`):
- `GET /api/devices` → 200 JSON with all groups present (`dma:null`), valid shapes.
- `GET /api/device/a20` → matches the `a20` sub-object of `/api/devices`; unknown name → 404.
- `GET /api/io?port=0x3da` twice in a row → identical value, and a following `/api/devices` shows
  the AC flip-flop UNCHANGED (the HTTP-level purity proof).
- Determinism: two server launches → run to a fixed cycle → `/api/devices` byte-identical.

## Phased roadmap

Phase 1 — A20 + the highest-value devices (the bug that motivated this):
- [ ] Add `Command.devices_get: void` + `Response.devices: DevicesResult` (pointer-free POD:
      fixed register-file arrays + scalars) in `src/api/queue.zig`.
- [ ] Add a pure `Vga.statusReg1Peek(cyclesNow) u8` (= `statusReg1` minus the flip-flop write) so
      the reader and the live port read share the bit math without mutation. (Only if reusing the
      computation cleanly requires it; otherwise inline the integer math in the controller.)
- [ ] `Controller.devicesSnapshot()` on the side-effect-free peek path: A20 (`bus.a20Enabled`/
      `bus.a20_mask` + KBC output-port bit1), PIC (`Pic.snapshot`), PIT (snapshot + computed
      `liveCounter`/`outBit`), 8042 (`Keyboard.snapshot`). Touches only raw fields + pure helpers.
- [ ] Worker dispatch arm for `devices_get`.
- [ ] `GET /api/devices` route + `respondDevices` serializer (mirror `respondRegions`).
- [ ] Unit tests: A20 off-after-POST / on-after-enable; PIC/PIT/8042 known-state; **purity
      (snapshot before==after)**; contrast test that a real `in8(0x3DA)` DOES mutate.
- [ ] Integration test: `GET /api/devices` 200 + shape; two-run determinism.

Phase 2 — VGA register state + the per-device endpoint:
- [ ] Add VGA group to `devicesSnapshot` (seq/crtc/gfx/attr files, DAC indices/state, misc/feature/
      pel_mask/flip-flop/latches, BDA mode, computed `input_status1`); `?palette=1` widens to the
      256×RGB DAC.
- [ ] `GET /api/device/<name>` route (a|pic|pit|vga|kbc|speaker|ems); unknown → 404.
- [ ] Speaker (port-0x61 latch + computed ch2 gate/out).
- [ ] VGA tests: post-set-mode register match; computed `input_status1` == `statusReg1` math;
      purity over `0x3C9` (DAC index unchanged).

Phase 3 — memory/EMS config + the I/O-port shadow:
- [ ] Memory group: conventional ceiling + EMS (`Ems.snapshot` fields: reported/backing pages,
      active handles, user pages, frame base/len). `dma:null` honest marker.
- [ ] `GET /api/io?port=<n>`: a pure per-port shadow switch (NO `in8` call) with the `shadow:true`
      flag + disclaimer; dangerous-port coverage; purity test (read does not mutate).
- [ ] (Later, optional, mirrors spice86) per-EMS-handle / per-page sub-endpoint.

## Honesty / structural-gap notes

- **DMA is not modeled** — report `null`, never fabricate registers. If a target guest programs
  the 8237, that is a real gap to surface (a new device), not something the reader should paper over.
- The **8042 output-port A20 latch is read-back-only** (the bus owns A20); the reader must label it
  as the latch, not the live gate, so a client never confuses the two owners.
- If any value turns out to be reachable only through a mutating port handler, **add a pure
  raw-field accessor to the device** (next to `snapshot()`) — do not call the port handler from the
  reader. This is the project ground rule (no fakes; surface the gap) applied to inspection.
