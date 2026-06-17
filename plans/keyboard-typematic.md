# Keyboard typematic auto-repeat (design / fix plan)

Status: **IMPLEMENTED — all 9 LOCKED revisions shipped (the keyboard device models typematic,
cycle-scheduled via the machine scheduler like the PIT). `zig build test` green at 607/607.**
The LOCKED revisions below were the binding spec; they OVERRIDE any contradicting text later.

## Review outcome — LOCKED revisions (implement exactly these)

The root-cause analysis, the layer (typematic lives in the keyboard device), make-only repeats,
last-key-wins (no resume-on-release), idempotent modifiers, extended-key re-injection via
`pushScancode`, the keystone, and keeping `app.js` as-is were all CONFIRMED. Corrections:

1. **[snapshot — my §4 was WRONG] The scheduler snapshots the repeat event VERBATIM; do NOT
   "reconstruct it on restore."** The PIT event is not rebuilt on restore — `Scheduler.Snapshot`
   serializes the live `events` array verbatim (`scheduler.zig:195-216`), `Machine.restore` copies
   `sched` verbatim (`machine.zig:703`), and `fireDue` re-binds `(source_id,kind)→device` at
   dispatch. So: add an `EventKind.kbd_repeat` variant + `KBD_SOURCE_ID` and the live repeat event
   round-trips for free. The keyboard snapshot gains ONLY the device config — `repeat_code`
   (`{scancode,ext}` or none), `delay_cycles`, `rate_cycles`. **Drop `next_repeat_cycle`** — it
   would duplicate the scheduler entry's `fire_cycle` and invite divergence.
2. **[wiring] Use the PIT's existing unified scheduler abstraction (not the either/or I wrote).**
   Add `kbd_repeat` to `EventKind` (`scheduler.zig:31`); `pub const KBD_SOURCE_ID: u16 = 2`
   (`machine.zig`); a bound `SchedulerApi {ctx, schedule, cancel}` on the keyboard mirroring
   `pit.zig:34-41` (bound at `wire`, `machine.zig:294-298` analogue); and a `fireDue` arm
   `.kbd_repeat => self.kbd.onRepeatFire(ev.fire_cycle)` (`machine.zig:562-567`).
3. **[wiring] The keyboard needs a `cycles: ?*const u64` back-pointer** (it has none today). Bind
   `self.kbd.cycles = &self.cpu.st.cycles` at `wire` (next to the existing `raise` binding,
   `machine.zig:315-316`), re-bound on restore, NOT snapshotted — exactly like speaker/PIT/VGA/OPL.
4. **[determinism] Reschedule from the fired event's `fire_cycle`, NOT `cyclesNow()`** (the
   handler gets `fire_cycle`), so burst granularity never drifts the cadence — mirror
   `onPitCh0Fire` re-arming from `fire_cycle` (`pit.zig:218-224`). And **cancel-then-schedule on
   EVERY (re)arm** — `schedule` asserts `!hasLive(source_id,kind)` (`scheduler.zig:119`); the
   new-make-restarts-delay path and the per-fire reschedule both must `cancel` first (like
   `armCh0`, `pit.zig:199`).
5. **[fidelity — my rate numbers were WRONG] The rate field is a non-linear ms-PERIOD table, not
   "2–30 cps", and the default is 30 cps (33 ms), not 10.9 cps.** Decode the `0xF3` byte
   `0dd rrrrr`: `delay_ms = DELAY[(byte>>5)&3]`, `period_ms = PERIOD[byte & 0x1F]` with
   ```
   DELAY  = { 250, 500, 750, 1000 }                                  // ms
   PERIOD = {  33, 37, 42, 46, 50, 54, 58, 63,  67, 75, 83, 92,100,109,118,125,
             133,149,167,182,200,217,233,250, 270,303,333,370,400,435,476,500 } // ms
   ```
   (from `references/dosbox-x/src/hardware/keyboard.cpp:684-690` / dosbox-staging
   `input/keyboard.cpp:346-354`). **Default (never set): delay 500 ms, period 33 ms (≈30 cps)** —
   the AT BIOS sets `0xF3,0x20` for "set default" (`dosbox-x/src/ints/bios_keyboard.cpp:1425-1427`).
   Convert with `period_cycles = period_ms * timing.CPU_CLOCK_HZ / 1000` (CPU_CLOCK_HZ = 14_318_184,
   `abi/timing.zig:25`; integer-exact). Name `CPU_CLOCK_HZ` specifically — NOT the PIT-tick helpers.
6. **[fidelity — gap] Add INT 16h AH=03 (set typematic rate/delay via BIOS).** zdos's
   `bios/int16.zig:102-134` handles only AH=00/01/02/10/11; AH=03 falls through to unsupported.
   Real BIOS routes AH=03 to the `0xF3` path (`bios_keyboard.cpp:1424-1434`): AL=00 → byte `0x20`
   (default); AL=05 → byte `((BH&3)<<5) | (BL&0x1F)`. Drive the SAME decode as the port-0x60 path.
   (Many guests set their rate this way; without it the cadence stays at the default. Do it, or
   flag as a deferred gap — recommend doing it.)
7. **[fidelity] Do the Pause/PrtScn no-repeat exclusion now** (one line; `KBD_pause`/`printscreen`
   excluded — dosbox-staging `typematic_update:198-199`), not a deferred minor.
8. **[Phase 1] Replace the `0xF3` param DISCARD** at `keyboard.zig:229-232` with the decode above
   (it currently ACKs and throws the byte away).
9. **[edge] Extended-key repeat needs 2 free FIFO slots** — guard `fifoFree() < 2` (mirror
   `controller.zig:823`) so a full FIFO never strands a lone `0xE0`; on FIFO-full, re-arm at
   `fire_cycle + period_cycles` (cycle-derived), never "retry when the FIFO drains."

Keystone re-confirmed by review: no key held ⇒ `repeat_code == null` ⇒ no `schedule` call ⇒
`nextEventCycle()`/burst bound identical ⇒ byte-identical to today. Re-injection via `pushScancode`
from `fireDue` runs at a clean boundary and is re-entrancy-safe. Snapshot is in-memory only
(no wire-format/version concern).

---

## 0. Symptom & root cause (confirmed)

Holding ↑ in **Stunts** under zdos accelerates continuously (works). Holding ↑ in **BaK** only
moves once per *physical tap*. In **dosbox-x** (verified live) holding ↑ in BaK auto-repeats.
So this is a zdos gap, not a game bug.

**Root cause: zdos models no keyboard typematic auto-repeat.**
- The emulated keyboard parses the `0xF3` set-typematic-rate command but only ACKs it and
  **discards the rate/delay** — no repeats are ever generated (`src/devices/keyboard.zig:90,229,254-256`;
  no repeat logic in `keyboard.zig`/`bios/int09.zig`/`bios/int16.zig`).
- `app.js` deliberately suppresses the browser's OS auto-repeat: `if (held[e.code]) return;`
  (`src/api/web/app.js:433`). So a held key delivers exactly **one make** (keydown) + **one
  break** (keyup), nothing between.

Why the two games differ:
- **Stunts** reads make/break scancodes and tracks key *state* → "make, no break yet" = held →
  keeps accelerating. Needs no repeats.
- **BaK** reads cooked characters via **BIOS INT 16h** (the BDA keyboard ring). One make → one
  INT 09h enqueue → one character → one move. Real hardware repeats the scancode at the
  typematic rate after the delay → repeated characters → continuous movement. zdos never
  repeats → one char → must tap.

## 1. Design — model typematic in the emulated keyboard (faithful + deterministic)

Real typematic repeat happens in the **keyboard itself** (it re-sends the *make* code, with no
intervening break, while a key is held; the break is sent once on release). zdos already routes
every injected make/break through the keyboard device FIFO (`Controller.injectScancode` →
`kbd.pushScancode`, `controller.zig:818-827`), and `pushScancode` raises IRQ1 — so the device
sees every edge and the repeat re-uses the exact same enqueue+IRQ path. Keep `app.js` as-is
(one make / one break is correct; the *emulator* generates the repeats, like real hardware).

State added to `Keyboard` (`src/devices/keyboard.zig`):
- `repeat_code: ?{ scancode: u8, ext: bool }` — the currently-repeating key (the last make
  still held). `null` = nothing repeating.
- `delay_cycles: u64`, `rate_cycles: u64` — derived from the `0xF3` param (or the default).
- `next_repeat_cycle: u64` — when the next repeat fires (scheduler event), valid iff
  `repeat_code != null`.

Behavior (the keyboard's typematic state machine):
- **On a MAKE** entering the keyboard: set `repeat_code` to that key (last-key-wins — a new make
  replaces any current candidate) and schedule the first repeat at `now + delay_cycles`.
- **On a BREAK** of the key in `repeat_code`: clear `repeat_code`, cancel the event. (Break of a
  *different* key: ignore — only the last-pressed-still-held key repeats; this matches the
  common single-repeating-key hardware behavior.)
- **On the repeat event firing**: re-inject `repeat_code` as a MAKE via the normal
  `pushScancode` path (E0 prefix first if `ext`), which raises IRQ1 → INT 09h enqueues the char
  again; then reschedule at `now + rate_cycles`. (If the FIFO is full, skip this repeat but keep
  the schedule — real keyboards drop on a full buffer too.)

Both games stay correct: BaK's INT 16h reader now sees repeated characters; Stunts' make/break
tracking is idempotent under extra makes (it already gets repeated makes on real hardware).

## 2. Scheduler wiring (the one new seam)

The keyboard must schedule a future repeat on the **machine scheduler** (cycle-driven), exactly
as the PIT schedules IRQ0 (`machine.zig` `PIT_SOURCE_ID`, `onPitCh0Fire`, `fireDue`). Add a
keyboard event source: a bound `schedule_fn`/`cancel_fn` (mirror the existing `raise_fn`
opaque-ctx binding, `keyboard.zig:46/121`, re-bound on restore) OR a new `KBD_SOURCE_ID` the
machine drives. On `fireDue`, the keyboard's repeat handler runs at the scheduled cycle and
re-injects. **Never host time** — the cadence is a pure function of `cpu.st.cycles`.

## 3. Rate/delay derivation

- Decode the `0xF3` rate byte per the AT spec: bits 0-4 = repeat rate (2–30 cps), bits 5-6 =
  delay (250/500/750/1000 ms). Store the *current* values; apply on the next make.
- **Default** (never set by the guest): the BIOS/keyboard power-on default — **500 ms delay,
  ~10.9 cps** (the standard PC default). Verify exact numbers against the references (§7).
- Convert ms → cycles via the SAME emulated-clock basis the PIT uses (cycles-per-second derived
  from the CPU/PIT frequency constants — find and reuse that constant; do NOT invent a new one).
  The absolute "feel" matters less than determinism, but match real timing closely.

## 4. Determinism (prime directive)

- The repeat is a **scheduled cycle event**; the cadence is byte-reproducible. Live key arrival
  (browser keydown/keyup) is non-deterministic in *when it starts*, but once started the repeat
  is deterministic — the same split the live-mouse work uses (and scripted `injectScancode` at a
  cycle is *fully* deterministic, repeats included).
- **Keystone:** no key held ⇒ `repeat_code == null` ⇒ no event scheduled ⇒ zero added cycles ⇒
  a no-input run is byte-identical to today.
- **Snapshot:** `repeat_code`, `delay_cycles`, `rate_cycles`, `next_repeat_cycle` join the
  keyboard snapshot; the scheduled event is **reconstructed from this state on restore** (mirror
  how the PIT event is rebuilt from device state, not stored as a raw scheduler entry). Confirm
  the keyboard snapshot already round-trips and extend it.
- No ledger hole: a repeat that fires INT 09h charges the ISR's real cycles via the normal path.

## 5. Edge cases / fidelity

- **Extended keys (arrows = E0 48/50/4B/4D)**: the repeat must re-send the full `E0`+code make.
  `injectScancode`/`pushScancode` already handle `ext`; carry `ext` in `repeat_code`.
- **Modifiers (Shift/Ctrl/Alt)** typematic-repeat on real hardware too, but INT 09h treats a
  repeated modifier make idempotently (re-sets the flag, no ring enqueue) — harmless; no special
  case needed.
- **Pause** does not auto-repeat (and PrtScn is special); exclude these from `repeat_code`
  (or flag as a documented minor if not handled in v1).
- **A new make while one repeats** restarts the delay for the new key (last-key-wins).

## 6. Implementation phases (each compiles + `zig build test` green)

- **Phase 0**: confirm the keyboard snapshot round-trips today; pick the scheduler-wiring shape
  (bound `schedule_fn` vs `KBD_SOURCE_ID`) by reading how the PIT is wired.
- **Phase 1**: store + decode the `0xF3` rate/delay (currently discarded) + the default; ms→cycle
  conversion against the existing clock constant.
- **Phase 2**: the typematic state machine in `keyboard.zig` (make → arm; break → cancel; event
  → re-inject + reschedule) + the scheduler seam.
- **Phase 3**: snapshot the repeat state + reconstruct the event on restore; round-trip test.
- **Phase 4**: tests (§8).

## 7. References (verify exact rate/delay + repeat semantics)

- dosbox-x / dosbox-staging keyboard typematic: `KEYBOARD_AddKey` + the repeat timer
  (`src/hardware/keyboard.cpp` — `KEYB_*` repeat state, `KEYBOARD_TickHandler`/repeat event).
  Confirm: repeats send the *make* only (no interleaved break), last-key-wins, default
  delay/rate, and the AT `0xF3` byte decoding.
- AT/PS2 spec: `0xF3` byte = `0dd rrrrr` (delay bits 5-6, rate bits 0-4); default 500 ms / 10.9 cps.

## 8. Tests

- **BaK scenario**: hold a key (make, no break), step past the delay + several rate periods →
  INT 16h / the BDA ring yields *repeated* characters (cycle-exact count for a given span).
- **Stunts scenario**: a held key + a game that tracks make/break is unaffected (extra makes are
  idempotent; break still ends the hold).
- **Cancel**: break of the repeating key stops repeats deterministically.
- **last-key-wins**: a second make redirects the repeat + restarts the delay.
- **Determinism**: two runs with the same scripted make-at-cycle + a fixed step span are
  byte-identical (repeats included).
- **Keystone**: no key held ⇒ no scheduled event ⇒ byte-identical to today.
- **Snapshot**: arm a repeat, snapshot mid-delay, restore, continue → same repeat cadence.
- **Rate/delay**: a `0xF3` set-rate changes the cadence per the decoded value.

## 9. Honesty / structural notes

- Live key arrival is not bit-reproducible (start); the repeat *cadence* is. Documented, matches
  live-mouse.
- The "feel" depends on the ms→cycle constant; pick it from the existing clock basis, not a
  guess, and note it.
- v1 may skip Pause/PrtScn special-casing (flag it). Modifier repeat is left idempotent (no
  special case) — faithful.
- Keeps `app.js` suppressing OS auto-repeat (correct: the emulator owns repeat). This fixes the
  live player AND scripted/headless/oracle paths uniformly.
