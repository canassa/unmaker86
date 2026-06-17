# Live-adjustable CPU clock — fix BaK lag without changing game pace (design)

Status: **DESIGN — reviewed (3 lenses); approach LOCKED = (B) faithful time-domain refactor.**
Fix not started. The LOCKED section below consolidates the reviews and OVERRIDES any
contradicting text later in this doc.

## Review outcome — LOCKED design (implement exactly this)

All three reviewers validated the core model (independent crystals; raising the CPU:PIT ratio
smooths CPU-bound rendering while timer-bound game pace stays put) and confirmed it matches the
references: **dosbox-staging schedules the PIT in a millisecond/time domain and makes CPU speed a
separate live scalar (`CPU_CycleMax` = cycles/ms, Ctrl+F11/F12); dosbox-x drives VGA from fixed
dot-clock oscillators.** We adopt that architecture.

### Chosen approach (B): schedule/phase everything in a mult-independent DEVICE-TIME domain
Today the scheduler keys on the CPU **cycle** counter and VGA/speaker compute phase from
`cycles_now % period` anchored at absolute cycle 0 — so a live `mult` change shifts every period
and breaks phase continuity (the BLOCKER three reviewers found: VGA/speaker have NO anchor state).
Approach (A) (add anchor fields + re-arm every device on each change) is rejected as fragile and
determinism-critical. Instead:

1. **Device-time domain.** Real-time-anchored devices (PIT, VGA, speaker, OPL, keyboard typematic)
   schedule events and compute phase in a **mult-independent device-time unit** (the PIT/crystal
   time base), NOT in CPU cycles. `mult` (= `cycles_num`, CPU cycles per device-time unit) is used
   ONLY to convert device-time↔CPU-cycles at the run-loop boundary ("CPU cycles until next event =
   (next_event_devtime − now_devtime) × mult"). The run loop tracks a continuous `device_time`
   accumulator advancing as the CPU executes.
2. **A live `mult` change needs NO re-arm.** Device events + phases are in device-time (unchanged
   by mult); only the device-time→CPU-cycle conversion factor changes for FUTURE conversions. This
   **dissolves the BLOCKER** — VGA/speaker phase stays continuous with no anchor fields; PIT/OPL/
   keyboard events keep their device-time fire points. (This is exactly dosbox keeping `channel.
   delay/start` in ms across a `CycleMax` change.)
3. **Integer-exact, no floats (determinism).** The device-time unit + the device-time↔cycle
   conversion must be integer-exact with an explicit fractional remainder accumulator (no dropped/
   double tick), like today's `timing.ticksToCycles` remainder. The exact unit (PIT ticks vs a
   finer "nominal cycles at the reference mult" base so VGA dot-clock/OPL-µs periods stay integer)
   is the key IMPLEMENTATION decision — settle it in Phase 1 with its own review; constraints: no
   `f32`/`f64`, no tick lost/doubled, and **default mult 12 ⇒ byte-identical cycle ledger to today**
   (every golden holds with no re-mint).

### Determinism (confirmed by review)
- `mult` is guest-affecting state (it sets how guest code interleaves with device events) → it AND
  the `device_time` accumulator (+ remainder) join `Machine.Snapshot` (in-memory; the API
  `DevicesSnapshot` is separate — no wire golden touched).
- Per-config: a given `mult` is fully deterministic; different `mult` ⇒ different goldens (expected,
  user-confirmed). The determinism harness uses the default (12) and never changes the clock.
- A live change is a deterministic input applied at a **worker-command boundary** (a specific
  cycle), recordable/replayable as `(cycle, mult)` — same model as live mouse/keyboard. Route it
  through the worker command queue (`Command.set_clock` → `Controller.setClock`), NOT the live-mouse
  non-blocking fold.

### Corrections to this plan's earlier text (from review)
- **Drop the "1.74× dual-clock BUG" framing (arch M1).** It is NOT a determinism bug. It is a
  wall-speed quirk: today the pacer feeds 25 MHz while the device clock is 14.32 MHz, so the game
  plays ~1.74× fast in wall time. The pacer must derive its slice from the runtime
  `cpu_clock_hz = PIT_TICK_RATE × mult` so the timer's wall rate stays correct (18.2 Hz) as `mult`
  rises — this is part of preserving pace under the knob, not a bug fix. Wall-only; paced≡unpaced
  holds; no golden moves.
- **The knob is "cycles"/relative-speed, NOT calibrated MHz (timing LOW + arch m1).** The cost
  model is interim-flat, so MHz overstates fidelity; dosbox exposes cycles and only *shows* a
  derived MHz estimate. Wire field is an **integer** (`mult` or integer cycles) — no float in the
  `src/api` layer (the `f32`/`f64` grep gate). May DISPLAY "≈N MHz" derived, but the control is
  cycles/mult. Integer `mult` keeps `cycles_den = 1` (exact, zero drift).
- **VGA comptime asserts + dependent tests** (`vga.zig:210-219`, `vga_test.zig:26-31`,
  `vga_retrace_test.zig:161-163`) consume `FRAME_CYCLES`/`LINE_CYCLES`/`HDE_CYCLES` as comptime
  consts. When these become device-time/runtime, convert the asserts to runtime checks evaluated at
  the default mult; keep the mult-invariant 70.086 Hz identity (`CPU_CLOCK_HZ*100/FRAME_CYCLES ==
  7008`) as a runtime check **with a ±1 rounding band** (floor division means a naive exact assert
  could fire on a legal mult — timing/determinism reviewers).
- **Self-calibrating guests** (delay loops counting instructions per PIT tick) will measure a
  different count at a higher mult — that is faithful turbo-button behavior, not a fake. No action.

### Where it lives + how threaded (arch recommendation)
`ClockConfig { mult: u64 = 12 }` (+ the `device_time` accumulator) as a VALUE on `Machine`,
snapshotted. Devices reach it via a `*const ClockConfig` back-pointer bound at `wire`, re-bound on
`restore` (the existing `self.pit.cycles = &self.cpu.st.cycles` pattern) — but the VALUE rides the
machine snapshot. `abi/timing.zig` helpers take `mult` (stays a clockless leaf). The machine owns
the device-time↔cycle conversion at the run-loop/scheduler boundary, so most devices need only
device-time periods, not the mult directly. Worker reaches it via worker→controller→machine
(`Controller.setClock`, like `reset`).

### Phase order (each step: `zig build test` green; currently 607)
- **Phase 0 — feasibility gate:** measure host-sustainable guest cycles/sec in ReleaseFast → caps
  the usable top of the knob. (If the host can't feed a faster clock, the lag is interpreter-perf,
  a separate effort — say so, don't ship a knob the host can't feed.)
- **Phase 1 — device-time refactor at FIXED mult 12 (NO-OP):** move scheduler + VGA/speaker/OPL/
  keyboard/PIT to device-time; settle the integer unit + remainder; convert VGA comptime
  asserts/tests to runtime. **Every golden byte-identical** — the golden-exposure gate; stop and
  verify the full corpus + oracle here.
- **Phase 2 — make `mult` runtime + snapshot** `mult` + `device_time` (+ remainder); default 12;
  snapshot→restore byte-identical.
- **Phase 3 — command + UI + pacer:** `Command.set_clock` (integer `mult`) + route + UI cycles knob
  (label "CPU ≈N MHz" derived); pacer derives slice from runtime `cpu_clock_hz`. With (B) the live
  change is trivial (no re-arm) — verify VGA/speaker phase continuity + `(cycle,mult)` determinism.

### Phase 3 outcome (SHIPPED, with one BLOCKER surfaced — do not re-run blind)
SHIPPED: `Command.set_clock`/`clock_get` → `Controller.setCpuMult`/`clockMult` → `Machine.setClockMult`
(clamps `[1, MAX_MULT=55]`); `POST`/`GET /api/cpu/clock` (integer `{mult}` or `{mhz}`, integer-only
wire, derived `cpu_hz`/`mhz`/`slice_cycles`); the pacer paces at the DEVICE clock — `PACER_TARGET_HZ`
(25 MHz) DROPPED, default slice now `PIT_TICK_RATE*12/100 = 143_181` (faithful 14.32 MHz), retuned
live to `PIT_TICK_RATE*mult/100` by the handler via `RunControl.setSlice`. UI = a "CPU ≈N MHz" HUD
slider (mult 1..55), synced from GET, POSTs on change. Default byte-identical (BaK to 50M cycles
identical pre/post; full suite + oracle green, NO re-mint). `(cycle,mult)` replays byte-identically;
the scheduler-side NO-RE-ARM holds (a pending PIT event keeps its device-time fire point); timer WALL
rate invariant to mult (live BaK: ~17 ticks/s at BOTH mult 12 and 24 while CPU cyc/s doubled).

**BLOCKER — VGA/speaker phase + scheduler "now" are NOT continuous across a live change.** Phases 1-2
shipped the SHORTCUT `cpuToDevice(absolute_cpu_cycles, mult)` instead of the LOCKED design's continuous
`device_time` ACCUMULATOR (locked point 1). At a fixed mult both agree (byte-identical goldens), but a
mid-run mult change RETRO-SCALES the absolute cycle history: at cycle 123457 device-time is 123457 @
mult 12 but 61728 @ mult 24 → a ~30%-of-a-frame VGA-retrace phase JUMP (and the scheduler's `now_dt`
reference jumps the same way). It is a ONE-SHOT fidelity glitch at the instant of the change (a retrace
tear / PIT phase hiccup), STILL fully deterministic given `(cycle,mult)` — NOT a determinism break.
The faithful fix is the device_time accumulator (advance a machine-owned `device_time` by
`cpu_delta*REF_MULT/mult` per step with a remainder, snapshot it, and have every device read it instead
of recomputing from absolute cycles) — that is Phase-1-scope (touches the hot run loop + every device
phase read + the snapshot format), NOT the rejected per-device anchor fields (approach A). Deliberately
NOT papered over. Until then the knob works but glitches once per change.

---

Original plan body follows (read through the LOCKED lens above; approach (B) supersedes the
"re-arm each device" framing in §4).

## 0. Problem

BaK plays laggy. Not a host/code bottleneck per se and NOT the game speed — zdos emulates a
**slow 386 (~14.32 MHz, 386SX-12 class)**. BaK was genuinely sluggish on period 386es.

The insight that lets us fix lag WITHOUT changing game speed:
- **Game logic / pacing is timer-bound** (PIT countdown loops, e.g. `[0x2c55]`). Locked to the
  PIT; does NOT change with CPU speed → "plays at the original pace."
- **Frame rendering is CPU-bound.** On a slow CPU the per-frame render work overruns the timer
  budget → choppy/laggy. A faster CPU fits the frame → smooth.

So a **faster CPU clock fixes the lag while leaving game pace unchanged** — and the user wants it
**adjustable live** (DOSBox-cycles style: dial CPU speed while playing).

## 1. Why this works in zdos's model (load-bearing fact)

`timing.CPU_CLOCK_HZ` (= `PIT_TICK_RATE * cycles_num` = `1_193_182 * 12` = 14_318_184) is the
**"cycles per real second"** anchor. Consumers (`grep`-verified):
- **Real-time-anchored (scale WITH the clock):** PIT reload↔cycle (`timing.ticksToCycles`/
  `cyclesToTicks`, `cycles_num`), VGA frame/retrace (`vga.zig:204` `FRAME_CYCLES`, `:208`
  `HDE_CYCLES`, `:218` assert), OPL timers (`opl.zig:82`), speaker PWM (`speaker.zig:90`),
  keyboard typematic (`keyboard.zig:80`), BDA tick (`machine.zig:491`).
- **Cycle-anchored (does NOT scale):** the CPU instruction **cost table** (flat per-opcode).

Raising the multiplier makes fixed-cost instructions a smaller slice of each real second → more
instructions/sec (faster CPU) → rendering fits → smooth; peripherals keep their real rates; and
the multiplier **cancels in the PIT wall rate** (`reload*m/(PIT_TICK_RATE*m)=reload/PIT_TICK_RATE`)
so the timer stays 18.2 Hz — **game pace invariant** — provided the pacer paces at the device
clock (§3). Crucially, the VGA frame RATE is also invariant: `CPU_CLOCK_HZ/FRAME_CYCLES` is a
constant (70.086 Hz, the `:218` assert), so refresh stays correct at any multiplier.

## 2. Approach: a RUNTIME clock the machine owns (not a comptime constant)

Today `cycles_num`/`CPU_CLOCK_HZ` are **comptime `pub const`** in `abi/timing.zig`, consumed in
comptime contexts (notably VGA `FRAME_CYCLES` const + the `:218` comptime assert). A live config
means making the clock a **runtime value** threaded to every real-time-anchored consumer.

Design: a small **runtime clock record** (the single source of truth), e.g.
```
ClockConfig { mult: u64 }   // CPU:PIT multiplier; cpu_clock_hz = PIT_TICK_RATE * mult; default 12
```
- Lives in **machine state** (it affects guest computation — see §4 — so it is NOT a re-bindable
  pointer like `cycles`; the VALUE is part of the deterministic machine and is **snapshotted**).
- Devices read it where they currently read the comptime const:
  - **PIT** (`pit.zig`): `ticksToCycles`/`cyclesToTicks` take the runtime `mult` (or the PIT holds
    a `*const ClockConfig`). This is the core CPU:timer relationship.
  - **VGA** (`vga.zig`): `FRAME_CYCLES`/`HDE_CYCLES` become **runtime-computed** from the clock
    (recomputed on a clock change). Convert the `:218` comptime assert to a derived/runtime check
    (the frame *rate* is multiplier-invariant, so it still holds).
  - **OPL/speaker/keyboard** (`opl.zig:82`, `speaker.zig:90`, `keyboard.zig:80`): already
    fn-local computations — read the runtime clock instead of the const.
  - **machine** BDA tick (`machine.zig:491`): runtime `ticksToCycles`.
- `abi/timing.zig` keeps `PIT_TICK_RATE`, the DEFAULT mult (12), and the conversion helpers
  (parameterized by `mult`); it stays a clockless leaf.

## 3. Pacer must pace at the (runtime) device clock — fixes a pre-existing dual-clock bug

Today the pacer paces at a hardcoded `PACER_TARGET_HZ = 25_000_000` (`run_control.zig:84`) while
the device clock is 14.32 MHz → the timer + all peripherals run **~1.74× fast today**. Fix: derive
the slice from the **runtime** `cpu_clock_hz` (slice = `cpu_clock_hz / 100` for a 10 ms slice), and
**recompute it on every live clock change** so the timer's wall rate stays 18.2 Hz at any speed.
Wall-only; paced ≡ unpaced still holds (`run_pacer_test.zig:104`).

## 4. Determinism (prime directive) — the crux of a LIVE change

The multiplier changes **guest-visible computation**: the PIT (and VGA/OPL/...) fire at different
CPU-cycle points relative to guest code, so the IRQ/guest interleaving — hence byte state at cycle
N — depends on the clock. That is physically correct (a faster CPU is interrupted at different
points) and it means:
- **The clock is deterministic machine state.** It MUST be in `Machine.Snapshot` (a new field) so
  snapshot→restore is byte-identical. (Contrast the `cycles`/`raise`/scheduler POINTERS, which are
  re-bound on restore; the clock VALUE is state.)
- **A live change is a deterministic INPUT** (like a keystroke/mouse event): applied by the worker
  at a command boundary = a specific cycle. Same binary + same `(cycle, new_mult)` change stream ⇒
  byte-identical. Recordable/replayable exactly like live input (live-mouse/keyboard precedent).
- **Per-config goldens (user-confirmed):** the DEFAULT (mult 12) leaves the cycle ledger and EVERY
  golden unchanged; the determinism harness uses the default and NEVER changes the clock mid-run.
  A non-default run is its own deterministic config.
- **Re-arm on change = model the independent crystals (NOT a fudge).** On real hardware the PIT
  has its OWN 1.193182 MHz crystal and the VGA its own dot-clock; both are independent of the CPU
  clock — which is exactly why a turbo-button toggle sped up the CPU while the timer kept correct
  time (and why timer-bound games stayed correctly paced). zdos collapses everything onto one
  CPU-cycle counter and schedules the PIT/VGA in CPU-cycles, so a live mult change must re-express
  each device's *remaining own-unit countdown* on the new cycle scale:
  `next_fire_cycle = C + remaining_pit_ticks × new_mult` (PIT; analogous for VGA dot-clock time).
  The remaining countdown in the device's own units is UNCHANGED by the CPU clock — this is
  literally "the crystal kept counting while the CPU clock changed," so it is deterministic,
  hole-free, and faithful. Implement it as: at the change, read each pending device event's
  remaining time in device units (from current device state, not the stale CPU-cycle fire), then
  reschedule at `C + remaining × new_mult`.

## 5. Live-change path (the correct "knob")

- **API:** a new command, e.g. `POST /api/cpu/clock { mult }` (or `{ mhz }` → nearest integer
  mult; log the actual MHz). It goes through the **worker command queue** (NOT the live-mouse
  non-blocking fold — a clock change is rare and must apply at a precise, serialized cycle
  boundary). The worker sets the machine clock, re-arms PIT/VGA, and the pacer re-derives its slice.
- **UI:** a HUD knob — but now a CORRECT one: it changes CPU speed (smoothness), NOT emulated time.
  Label it "CPU" in MHz (e.g. 14–66 MHz). Unlike the reverted knob, this does NOT fast-forward the
  game — pace is invariant. Sync initial value from `/api/cpu/clock` (GET) or run/status.
- Default mult 12 (14.32 MHz). Integer multipliers only (`cycles_den` stays 1 → exact, zero drift).

## 6. Phase 0 — feasibility gate (MEASURE the host ceiling) — STILL REQUIRED

A faster *emulated* clock only smooths play if the **host can execute those cycles in real-time**;
the pacer never catches up (a slice overrunning its 10 ms budget = choppy regardless of the dialed
clock). Measure, in **ReleaseFast**, the sustainable guest cycles/sec (run BaK armed; sample
`/api/run/status` cycle over wall time off-path, or a headless `runCycles` bench). This sets the
USABLE top of the live knob:
- Ceiling ≫ target (sustains 50–100+ MHz): the knob is fully useful; cap it at the measured ceiling.
- Ceiling near 14–25 MHz: the lag is largely **interpreter throughput** — the knob can't exceed
  what the host feeds; surface that honestly (the UI should show when the pacer falls behind), and
  treat CPU-loop perf as the real lever. Do NOT ship a knob that just makes the pacer fall behind.

## 7. Implementation sketch (after Phase 0 + review)
- `abi/timing.zig`: keep `PIT_TICK_RATE` + DEFAULT mult; make `CPU_CLOCK_HZ`/conversions derive
  from a passed `mult` (helpers gain a `mult` param or read the `ClockConfig`).
- New `ClockConfig` in machine state; init to default; snapshot/restore it.
- Thread it to PIT, VGA (runtime FRAME_CYCLES/HDE_CYCLES + de-comptime the `:218` assert), OPL,
  speaker, keyboard, BDA tick. Devices reach it like the existing `cycles` pointer (re-bound on
  wire/restore) — but the VALUE rides the machine snapshot.
- `run_control.zig`: drop `PACER_TARGET_HZ`; derive slice from runtime `cpu_clock_hz`; recompute on
  change.
- API: `POST /api/cpu/clock` (worker command) + wire field + GET; UI knob.

## 8. Tests
- **Default determinism:** full suite + oracle corpus green at mult 12, no golden re-mint.
- **Snapshot:** the clock is in `Machine.Snapshot`; snapshot→restore byte-identical, incl. after a
  mid-run change.
- **Live change determinism:** a scripted `(cycle, mult)` change stream replays byte-identically
  (two runs); changing mult changes the interleaving deterministically.
- **Pace invariance:** across mult values the PIT/VGA/OPL/keyboard **wall rates are unchanged**
  (timer 18.2 Hz, VGA 70.086 Hz) while cycles-to-a-fixed-wall-span scale with mult (CPU faster).
  Assert wall rates, not cycle counts.
- **Pacer:** paced ≡ unpaced still holds; the BDA tick advances at the real 18.2 Hz wall after the
  §3 fix; slice recomputes on a clock change.
- **Re-arm on change:** a clock change mid-flight leaves no scheduling hole/double-fire; the next
  timer fire lands at the correct new-ratio cycle.

## 9. Honesty / open questions for review
- **Mid-run re-arm** of PIT/VGA on a clock change (§4) is the trickiest determinism detail — get it
  reviewed hard.
- The clock joining `Machine.Snapshot` is a snapshot-format change — confirm no external golden
  serializes the snapshot in a way this breaks (it's in-memory; the API `DevicesSnapshot` is
  separate — verify).
- Units/range of the knob; cap at the Phase-0 host ceiling; show pacer-fell-behind state in the UI.
- Should a clock change be allowed only while paced-running, or also while stopped/stepping? (Apply
  at a command boundary either way.)
- Phase 0 gates the whole thing: if the host can't feed a faster clock, this is interpreter-perf,
  not a clock knob — say so rather than ship a knob capped by the host.
