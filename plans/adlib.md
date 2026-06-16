# AdLib (Yamaha OPL2 / YM3812) support

Status: PLAN (no code written). Owner: `src/devices/` (a new self-registering device) +
the existing device-state reader surface (`/api/devices`, `/api/io`).

## Why now — the motivating bug (Stunts 1.1 hangs)

> ✅ **PREMISE VINDICATED + PHASE 1 IMPLEMENTED — the OPL2 timer/status device unblocked Stunts.**
> An earlier note here called the premise "disproven," but that trace was of `LOAD.EXE` run
> DIRECTLY (no command tail) — the wrong entry point, which exits early on a NULL arg before any
> sound code. Once the nested-EXEC debugger fix (commit `db7cab7`) made the real launcher chain
> `ST.COM`→`STUNTS.COM`→`LOAD.EXE /u MCGA /ssb` visible, a live trace showed the `/ssb` FM driver
> **`AD15.DRV` runs the textbook OPL2 timer probe on port 0x388** (write reg4=0x80; read status; reg2=0xFF;
> reg4=0x21; poll until `status & 0xE0 == 0xC0`). With no OPL device, 0x388 read `0xFF` → probe failed
> 300× → `LOAD.EXE` aborted with `exit(1)` at ~49M cycles. **Phase 1 of this plan is now implemented**
> as `src/devices/opl.zig` (commit `259fa4e`): the faithful register-trace OPL2 (ports 0x388/0x389,
> timers 1/2, reg2/3 reload, reg4 control, status `0x40|0x80`/`0x20|0x80` on overflow — overflow a
> pure function of the cycle ledger, no host clock/float, snapshot-covered, port I/O charges zero
> cycles). **Result: Stunts passes the probe and renders its intro** (DSI logo + starfield, then the
> "Professional Driver on Closed Circuit" animation). 574 tests green; determinism byte-identical at
> 400M. Two small deviations from this plan's letter, both fine: the device registers 2 ports
> (0x388/0x389) not the 4-port mirror range, and the read is inherently non-mutating (flags computed
> lazily from the ledger, cleared only by reg4 bit7) so no separate `statusPeek`/`statusRead` split
> was needed. **Phase 2 (FM SYNTHESIS) remains DEFERRED** — the rest of this doc covers it. Below,
> read "Why now / proves Stunts unblocks" as accurate-as-of-Phase-1; the remaining Stunts work is
> whatever wall comes AFTER the intro renders (see `plans/stunts-milestone.md`), plus Phase 2 FM
> synthesis here if/when audible sound is wanted.

Stunts 1.1 self-decompresses, then runs its sound-hardware autodetect, which polls the
**AdLib OPL2 status register at I/O port 0x388** waiting for the timer-overflow bits. zdos does
not model the OPL2 at all, so 0x388 is an **unmapped port** → the bus floating-bus default
(`unmapped_in8 = 0xFF`, `src/bus/ports.zig:84`) is returned on every read. The detection never
sees the expected overflow→cleared transition and the game **hangs**.

The canonical OPL2 probe (what Stunts and essentially every AdLib detection routine does — it is
the routine documented in the Yamaha YM3812 application notes and reproduced in the AdLib SDK):

```
1.  OUT 0x388, 0x04   ; address Timer-control reg
    OUT 0x389, 0x60   ; bit6|bit5 = mask (reset) both timer IRQ-overflow flags
2.  OUT 0x388, 0x04
    OUT 0x389, 0x80   ; bit7 = RESET: clear both overflow latches
3.  IN  0x388         ; read status -> expect 0x00 (no overflow)
4.  OUT 0x388, 0x02   ; address Timer-1 data reg
    OUT 0x389, 0xFF   ; Timer-1 counter = 0xFF -> overflow after (256-255)=1 tick (80 us)
5.  OUT 0x388, 0x04
    OUT 0x389, 0x21   ; bit0 START Timer-1, bit5 MASK Timer-2 (only T1 unmasked)
6.  delay ~80+ us (a busy loop)
7.  IN  0x388         ; read status -> expect 0xC0 (bit7 IRQ | bit6 Timer-1 overflow)
8.  OUT 0x388, 0x04
    OUT 0x389, 0x60   ; mask+reset both
9.  AND result with 0xE0 ; AdLib present iff status was 0xC0 (some routines accept 0x80/0x40)
```

So the **timer + status-register subset** is exactly what unblocks Stunts. Full FM **audio
synthesis** (real samples) is a *separate, later* phase. This plan ships the timer/status path as a
fully spec-compliant subset (Phase 1) and designs — but does not build — the synthesis core
(Phase 2). It NEVER hardcodes the detection result; the overflow bits are computed from the cycle
ledger so the probe passes for the same reason a real chip passes it.

## References consulted (file:line)

### dosbox-staging (primary reference)
- `references/dosbox-staging/src/hardware/audio/opl.cpp:99-103` — `Timer::Timer(int micros)`:
  `clock_interval = micros * 0.001` (interval in **milliseconds**); `SetCounter(0)`.
- `:107-125` — `Timer::Update(double time)`: overflow fires when `enabled && time >= trigger`;
  re-syncs `start`/`trigger` to the current cycle (`fmod(delta,counter_interval)`), sets
  `overflow=true` **only if not masked**. Returns `overflow`. **This is host-double-time math;
  zdos replaces it with pure integer cycle math (see §Determinism).**
- `:133-138` — `SetCounter(val)`: `counter_interval = (256 - counter) * clock_interval`. The
  **(256 − counter)** rule is the load-bearing period formula.
- `:145-151` — `SetMask(set)`: masking clears overflow.
- `:158-178` — `Stop()`/`Start(time)`: Start only acts when not already enabled; syncs `start` to
  the last clock interval, sets `trigger = start + counter_interval`.
- `:185` — `OplChip::OplChip() : timer0(80), timer1(320)` — **Timer-1 = 80 µs, Timer-2 = 320 µs.**
- `:187-227` — `OplChip::Write(reg,val)`: reg `0x02` → `timer0.Update; SetCounter`;
  `0x03` → `timer1.Update; SetCounter`; `0x04` → if `val&0x80` Reset both, else
  `val&0x1`→T0.Start/Stop, `val&0x2`→T1.Start/Stop, `T0.SetMask(val&0x40)`, `T1.SetMask(val&0x20)`.
- `:229-242` — `OplChip::Read()`: `if (timer0.Update(time)) ret |= 0x40|0x80;` and
  `if (timer1.Update(time)) ret |= 0x20|0x80;` — **status bit map.**
- `:244-258` — `EsfmReadbackReg(0x04)`: assembles the control-reg readback bits
  (`T0.enabled | (T1.enabled<<1) | (T1.masked<<5) | (T1.masked<<6)`).
- `:922-935` — port install: `WriteHandler[0].Install(Port::AdLib::Command, …, 4)` /
  `ReadHandler[0]` at the AdLib command port with **4 ports** (`0x388-0x38b`); the SB mirror at
  `0x220` only for dual-OPL.
- `:64-97` — `initialize_opl_tone_generators` — the Adlib-driver power-on register seed (Phase 2
  detail; documents that the synth core has a defined reset state, not garbage).
- `references/dosbox-staging/src/libs/nuked/opl3.c` + `opl3.h` — the **Nuked-OPL3** synthesis
  core dosbox-staging vendors (`OPL3_Reset`, `OPL3_WriteRegBuffered`, `OPL3_GenerateStream`). This
  is the core Phase 2 ports (see §Phase 2).

### dosbox-x (cross-check — byte-identical timer/status semantics)
- `references/dosbox-x/src/hardware/adlib.h:33-122` — `class Timer`: same fields
  (`start`/`trigger`/`clockInterval`/`counterInterval`/`counter`/`masked`/`enabled`/`overflow`),
  same `Update`/`SetCounter`/`SetMask`/`Start`/`Stop`/`Reset` bodies as staging.
- `adlib.h:124-137` — `struct Chip { Timer timer0, timer1; … }`.
- `references/dosbox-x/src/hardware/adlib.cpp:1039` — `Chip::Chip() : timer0(80), timer1(320)`.
- `adlib.cpp:1042-1084` — `Chip::Write` — identical reg-0x02/0x03/0x04 semantics; confirms
  `0x04` bit7 = reset-overflow, bit0/bit1 = start T0/T1, bit6 = mask T0, bit5 = mask T1.
- `adlib.cpp:1117-1154` — `Chip::Read` — `0x40|0x80` for T0 overflow, `0x20|0x80` for T1.
- `adlib.cpp:1349-1352` — OPL2 `PortRead`: `return chip[0].Read() | 0x6;` — **on OPL2 the unused
  low status bits 1–2 read back as 1** (`| 0x06`). (OPL3 path does NOT OR 0x06.)
- `adlib.cpp:1736-1737` — `WriteHandler[0].Install(0x388,…,4)` / `ReadHandler[0]` — **0x388 + 4
  ports** on the non-PC98 path. The 0x220 SB mirror only when `!single` (dual/SB).
- `adlib.cpp:1048-1153` — the `adlib_force_timer_overflow_on_polling` HACK (a DOSBox heuristic
  that force-sets overflow when a guest polls the status port "too fast" w.r.t. host wall-clock).
  **zdos does NOT and MUST NOT replicate this** — it is a host-wall-clock hack that exists only
  because DOSBox's cycle model is not faithful enough for some detection loops. zdos's faithful
  cycle-derived timer makes the hack unnecessary (and it would violate the prime directive: it
  reads host time and fabricates overflow). Explicitly out of scope — surfacing this is itself a
  validation that zdos's deterministic model is the *correct* one. (See §Honesty notes.)

### zdos anchors (the device contract + reader the OPL plugs into)
- `src/devices/pit.zig:124-165` — `PitChannel.outBitAt`/`liveCounter`: the EXACT model for a
  cycle-derived, const, side-effect-free device value (`f(cpu.st.cycles)`, no host time). The OPL
  timer-overflow computation mirrors this.
- `src/devices/speaker.zig:55-160` — the **closest device template**: a tiny self-registering
  `src/devices/` module that owns a port latch, holds a `*const u64 cycles` back-pointer wired by
  the machine, derives a time-dependent read bit from the cycle ledger
  (`window = CPU_CLOCK_HZ * 30 / 1_000_000`, `:90`), exposes a `PortHandler` (`:137-144`), and has
  `reset`/`snapshot`/`restore` (`:66`, `:151-159`). The OPL device is structured identically.
- `src/abi/timing.zig:18-25` — `PIT_TICK_RATE = 1_193_182`, `CPU_CLOCK_HZ = PIT_TICK_RATE*12 =
  14_318_184`. **The cycle clock the OPL timer math converts µs → cycles against.**
- `src/abi/timing.zig:74-88` — the grep test forbidding `std.time`/`std.Random`/`f32`/`f64` in
  the timing leaf; the OPL device must satisfy the same (no host time, no float).
- `src/bus/ports.zig:20-81` — `WidthCaps` + `PortHandler` (`ctx`+`VTable`, `in8`/`out8`); `:84`
  `unmapped_in8 = 0xFF` (today's 0x388 behaviour). The OPL exposes a `PortHandler` for byte width.
- `src/bus/bus.zig:1011-1032` — `registerPort`/`registerPortRange`/`allocPortHandler` (stable
  integer IDs; ID 0 = unmapped).
- `src/machine/machine.zig:132-135` — device fields (`pit: Pit = .{}`, `speaker: Speaker = .{}`).
  The OPL becomes a new field `opl: Opl = .{}`.
- `machine.zig:202-251` — the `registerPort(Range)` block in `wire()` (port registration order
  matters: snapshot replay re-binds by ID in this order — append the OPL ports at the documented
  tail to keep IDs stable).
- `machine.zig:263-282` — back-pointer wiring (`self.pit.cycles = &self.cpu.st.cycles`, etc.).
  The OPL gets `self.opl.cycles = &self.cpu.st.cycles` here.
- `machine.zig:459-463` — `reset()` calls each device's `reset()` in order; add `self.opl.reset()`.
- `machine.zig:563-628` — the `Snapshot` aggregate + `snapshot()`; add `opl: Opl.Snapshot` and
  `.opl = self.opl.snapshot()`. (Restore mirror lives in the machine's restore path.)
- `src/debug/controller.zig:235-329` — `DevA20`/`DevPit`/`DevSpeaker`/`DevVga`/`DevEms`/
  `DevicesSnapshot`/`IoShadow` — the device-reader POD types. Add a `DevOpl` group + an `opl`
  field on `DevicesSnapshot`.
- `controller.zig:948-1029` — `devicesSnapshot()` (side-effect-free presenter over each device's
  `snapshot()` + pure helpers). Add the OPL group here using a **pure status-peek helper**.
- `controller.zig:1031-1074` — `ioShadow(port)`: the per-port NON-mutating shadow switch. Add
  `0x388` (and mirrors) → the pure OPL status peek.
- `src/api/queue.zig:144-147,336` — `Command.devices_get`/`io_shadow` + `Response.io_shadow`
  (the reader already exists end-to-end; the OPL just adds a group to the existing payload).
- `src/api/server.zig:1071-1107,1293` — `/api/devices`, `/api/device/<name>`, `/api/io` routes +
  serializers (already built — the OPL group serializes for free once added to `DevicesSnapshot`).
- `plans/device-state-reader.md` — the **side-effect-free-peek contract** (raw fields / pure
  `f(cycles)` only, NEVER an `in8` that mutates) the OPL reader integration MUST obey.

## The real OPL2 register map (what Phase 1 stores; what Phase 2 renders)

The YM3812 is an indexed register file: write the **register number** to the address port (0x388),
then the **value** to the data port (0x389). The full 0x01–0xF5 map (stored faithfully by the
register file in Phase 1, even though only 0x02/0x03/0x04 are *acted on* until Phase 2):

| Reg     | Name / function |
|---------|-----------------|
| `0x01`  | Test register / WSE (bit5 = waveform-select enable on OPL2) |
| `0x02`  | **Timer 1 data** (counter preset; overflow after (256−val) ticks @ 80 µs) — Phase 1 |
| `0x03`  | **Timer 2 data** (overflow after (256−val) ticks @ 320 µs) — Phase 1 |
| `0x04`  | **Timer control / IRQ reset** (see bit table below) — Phase 1 |
| `0x08`  | CSW / NOTE-SEL (composite sine / keyboard split) |
| `0x20`–`0x35` | AM / VIB / EG-type / KSR / Multiple (per operator, 18 operators on OPL2) |
| `0x40`–`0x55` | KSL / Total Level (per operator) |
| `0x60`–`0x75` | Attack Rate / Decay Rate (per operator) |
| `0x80`–`0x95` | Sustain Level / Release Rate (per operator) |
| `0xA0`–`0xA8` | Frequency number low 8 bits (per channel, 9 channels) |
| `0xB0`–`0xB8` | Key-On / Block (octave) / Frequency number high 2 bits (per channel) |
| `0xBD`        | AM depth / VIB depth / Rhythm enable / BD/SD/TT/CY/HH key-on |
| `0xC0`–`0xC8` | Feedback / Connection (per channel) |
| `0xE0`–`0xF5` | Waveform select (per operator; only when reg 0x01 bit5 set on OPL2) |

The address-port register select is masked to **0xFF** (OPL2 has a single 256-entry register
bank; OPL3's second bank at 0x100 does not exist on OPL2 — `adlib.cpp:1302`,
`reg.normal = WriteAddr(port,val) & 0xff`).

### Timer-control register 0x04 bits (from `OplChip::Write` case 0x04)
| Bit  | Mask  | Meaning |
|------|-------|---------|
| 7    | 0x80  | **IRQ-RESET**: clears BOTH timer overflow latches (and the composite IRQ bit). When set, the rest of the byte is ignored. |
| 6    | 0x40  | **MASK Timer 1**: when set, Timer 1 overflow does NOT set its status bit. |
| 5    | 0x20  | **MASK Timer 2**: when set, Timer 2 overflow does NOT set its status bit. |
| 1    | 0x02  | **START Timer 2** (1 = run, 0 = stop). |
| 0    | 0x01  | **START Timer 1** (1 = run, 0 = stop). |

(Note the asymmetry, straight from the reference: bit 0/bit 6 are the Timer-1 start/mask pair,
bit 1/bit 5 are the Timer-2 start/mask pair.)

**bit7 (IRQ-RESET) clears ONLY `overflow_latched` (both timers)** — it does NOT touch
`start_cycle`/`enabled`/`masked` (matches `Timer::Reset`, which sets only `overflow=false`). So a
timer that is still enabled and whose period has already elapsed re-overflows on the very next read
(`hasOverflowed` recomputes from the unchanged `start_cycle`). The canonical probe's final
`0x04←0x60` happens to also mask, so it reads `0x06` regardless — but the reset path must be
faithful for a reset-without-mask, which the Phase-1 tests cover.

### Status register (read of 0x388) bits — OPL2 (`Chip::Read` + `| 0x06`)
| Bit  | Mask  | Meaning |
|------|-------|---------|
| 7    | 0x80  | **IRQ pending** — set if EITHER unmasked timer has overflowed. |
| 6    | 0x40  | **Timer 1 overflow** (set with bit 7). |
| 5    | 0x20  | **Timer 2 overflow** (set with bit 7). |
| 2,1  | 0x06  | **Always read 1 on OPL2** (the `| 0x6` in `PortRead` — these distinguish OPL2 from OPL3, where they read 0). |
| 4,3,0| —     | 0. |

So a fresh OPL2 with no overflow reads **0x06**; after a Timer-1 overflow it reads **0xC0 | 0x06 =
0xC6**; many detection routines `AND 0xE0` and compare to `0xC0`, which is why the low `0x06` does
not affect the probe — but it MUST be present for the routines that check the OPL2/OPL3
discriminator bits.

### Address-port / data-port / status pair
- **0x388** — write = register-address select; **read = status register** (the only readable port).
- **0x389** — write = register data; read = `0xFF` (no defined readback on OPL2; the higher of the
  4 allocated ports return `0xFF`, `adlib.cpp:1351`).
- **0x38A / 0x38B** — allocated (the device claims a 4-port range) but only used by the OPL3-Gold
  control chip; on plain OPL2 reads return `0xFF`, writes are address/data aliases of 0x388/0x389
  (`port & 1` selects data vs address — `adlib.cpp:1255/1297`). zdos registers the 4-port range
  `0x388-0x38B` so a guest probing 0x38A/0x38B sees the deterministic `0xFF`/alias behaviour rather
  than the unmapped floating bus. (Decision: register the full 4-port range, matching both
  references; do NOT register the 0x220 SB mirror — that belongs to a future Sound Blaster device,
  not the bare AdLib card. Surface that as a deferred item, not a fake.)

### Does AdLib wire an IRQ line? (be precise — cite the reference)
**No.** The bare AdLib / YM3812 card does **NOT connect its IRQ pin to the PC interrupt
controller.** Detection is purely **poll-based**: the guest programs a timer, busy-waits, and reads
the status port to observe the overflow bits. Nothing in `Chip::Write`/`Chip::Read`
(`adlib.cpp:1042-1154`) raises a host IRQ — the "IRQ pending" status bit (0x80) is a *status flag*,
not an interrupt request. (DOSBox models the overflow flag entirely inside `Timer`/`Chip` with no
`PIC_ActivateIRQ` call.) Therefore the zdos OPL device is **NOT a scheduler/IRQ source** — unlike
the PIT (`pit.zig` schedules IRQ0), the OPL schedules **nothing** and raises **nothing**. This is
central to keeping it cycle-neutral and simple: overflow is a pure read-time computation, never an
event. (If a later Sound-Blaster-integrated OPL needs the SB DSP IRQ, that is the SB device's IRQ,
not the OPL's — out of scope.)

## Determinism — the prime directive (the core of Phase 1)

DOSBox computes overflow from **host wall-clock doubles** (`PIC_FullIndex()`, `fmod`, `double`
intervals). zdos MUST NOT. The overflow state of each OPL timer is a **pure integer function of
`cpu.st.cycles`**, exactly like `pit.zig` `liveCounter`/`outBitAt` and `vga.zig`'s `statusReg1`.

### The exact cycle math

Per-timer constants (integer cycles, computed once at comptime from `timing.CPU_CLOCK_HZ`):

```
CPU_CLOCK_HZ = 14_318_184           (timing.zig:25)
1 tick of Timer 1 = 80 µs   -> t1_tick_cycles  = CPU_CLOCK_HZ * 80 / 1_000_000 = 1_145
1 tick of Timer 2 = 320 µs  -> t2_tick_cycles  = 4 * t1_tick_cycles            = 4_580
```

(Timer 1 is the integer floor `14_318_184*80/1_000_000 = 1145.45… -> 1145`. **Timer 2 is defined as
`4 * t1_tick_cycles = 4580`, NOT an independent floor** of `*320/1_000_000 = 4581.81… -> 4581`: the
real chip derives both timers from one master clock with 320 µs = 4 × 80 µs *exactly*, and DOSBox's
real-arithmetic model keeps that exact 4× ratio (an independent floor would break it by 1 cycle).
Pin both as comptime constants with `comptime { assert(t1_tick_cycles == CPU_CLOCK_HZ*80/1_000_000);
assert(t2_tick_cycles == 4 * t1_tick_cycles); }` so they cannot silently drift (mirror
`timing.zig:45-50`). The absolute value of t1 is implementation-defined-but-FIXED (the determinism
contract needs only pinned integers, identical every run); do NOT carry a fractional remainder
unless a later cross-emulator audio golden requires sub-tick accuracy — and if one does, add a
remainder accumulator exactly like `timing.ticksToCycles`, `timing.zig:60-64`, NEVER a float.)

Per-timer **period** in cycles for a programmed counter value `C`:

```
overflow_period_cycles(C) = (256 - C) * tick_cycles      // mirrors SetCounter's (256-counter)
```

Per-timer state stored (pointer-free POD): `counter: u8`, `enabled: bool`, `masked: bool`,
`overflow_latched: bool`, and `start_cycle: u64` (the cycle at which the running timer last synced
its period — the analogue of DOSBox's `start`/`trigger`, but a single absolute cycle).

**Pure overflow computation** (the single source of truth; both the live port read and the
non-mutating shadow call it):

```
fn hasOverflowed(t, cycles_now) bool:
    if t.overflow_latched: return true            // a prior elapsed period latched it
    if !t.enabled:        return false
    if t.masked:          return false            // masked timers never set the flag
    period = (256 - t.counter) * t.tick_cycles    // counter: u8 -> (256-C) in [1,256] -> period>0
    return (cycles_now - t.start_cycle) >= period
```

The status byte is then assembled exactly as the reference (`Chip::Read`):
`if t1.hasOverflowed: ret |= 0x40|0x80; if t2.hasOverflowed: ret |= 0x20|0x80;` then `ret | 0x06`
for OPL2.

### Live read vs. non-mutating shadow — one bit-math source of truth

This is the subtle part the device-state-reader contract demands (`plans/device-state-reader.md`
§"side-effect-free peeks"). DOSBox's `Read()` MUTATES: `Timer::Update` re-syncs `start`/`trigger`
when an overflow is observed (so the *next* period is measured from the read instant). That re-sync
is the only mutation on a status read.

- **The live port read (`in8(0x388)`)** computes `hasOverflowed` and, when it returns true,
  **latches** `overflow_latched = true` (so the flag stays set until reg-0x04 reset/mask clears
  it) and **re-arms** `start_cycle = start_cycle + k*period` (advancing past the `k` whole periods
  elapsed) — the faithful re-sync. This is a mutation, which is correct for a real port read.
  INVARIANT: `k` and `period` MUST be computed from the SAME `counter` value — so a `0x02`/`0x03`
  counter rewrite (which changes `period`) must FIRST re-sync `start_cycle` (a no-latch re-base to
  the rewrite cycle, mirroring DOSBox calling `Update` *before* `SetCounter`, `opl.cpp`), THEN apply
  the new counter. Otherwise the residue is measured against a stale period and two runs can diverge.
- **Masked-timer re-sync (documented simplification):** DOSBox's `Update` re-syncs `start`/`trigger`
  on a read even when the timer is masked; this plan's `statusRead` only re-syncs when
  `hasOverflowed` returns true (and a masked timer returns false), so a mask→elapse→unmask sequence
  reads slightly differently than DOSBox. This is irrelevant to any real detection routine (which
  never reads while masked) and is an INTENTIONAL simplification — both behaviours are fully
  deterministic in zdos. Noted so it is a known choice, not an oversight.
- **The peek/shadow (`/api/io?port=0x388`, `/api/devices`.opl)** calls the SAME
  `hasOverflowed(cycles_now)` pure function but **does NOT latch and does NOT re-sync** — it just
  reports what a read *would* return. So a debugger inspection leaves `machine.snapshot()`
  byte-identical (the prime directive; identical to `vga.statusReg1Peek` vs the mutating
  `statusReg1`, controller.zig:996/1041).

Concretely: add `pub fn statusPeek(self: *const Opl, cycles_now: u64) u8` (const, no mutation) and
a non-const `fn statusRead(self: *Opl, cycles_now: u64) u8` that calls `statusPeek` for the bit
math and then performs the latch/re-sync. **`statusPeek` is the one source of truth** for the bit
assembly; the live read adds only the mutation. (Mirror of `pit.outBitAt` being the pure core that
`Pit.outBit` delegates to, pit.zig:124/425.)

### Why two runs stay byte-identical
- `start_cycle`, `counter`, `enabled`, `masked`, `overflow_latched` are plain POD, zeroed at reset
  (CLAUDE #5). No host clock, no RNG, no float (the comptime tick constants are integers; satisfy
  the same grep test as `timing.zig:74`).
- Port I/O charges its cost at the CPU IN/OUT instruction (the bus port path adds **zero** cycles,
  exactly like `pit.zig`/`speaker.zig` — CLAUDE #1: no hole in the ledger). The OPL schedules no
  events and raises no IRQ, so it adds nothing to the ledger ever.
- Overflow is `(cycles_now - start_cycle) >= period`: a deterministic function of the cycle counter,
  so break-at-cycle-N → identical status, every run (the prime directive's "byte-identical at any
  cycle N").

## Snapshot / restore (pointer-free POD, deterministic reset)

Mirror `pit.zig:477-485` / `speaker.zig:151-159`:

```
pub const Snapshot = struct {
    // address latch + the full 256-byte register file (faithful storage; Phase 1 stores,
    // Phase 2 renders). 256 bytes by-value is fine (cf. vga register files in the snapshot).
    reg_index: u8,
    regs: [256]u8,
    // the two timers (each: counter, enabled, masked, overflow_latched, start_cycle)
    timer1: TimerState,
    timer2: TimerState,
};
```

- `snapshot()` returns by value; `restore(snap)` copies back. The `cycles: *const u64`
  back-pointer is RE-BOUND by the machine on restore (never snapshotted — same rule as
  `speaker.cycles`, speaker.zig:148).
- `reset()` zeroes the POD fields individually (timers + `regs`/`reg_index`); do **NOT** `self.* =
  .{}` — that would clobber the `cycles` back-pointer (exactly why `speaker.reset()`, speaker.zig:66,
  sets fields rather than whole-struct-reinit; note `pit.zig:108` *does* `self.* = .{}`, but only on
  `PitChannel`, which has no back-pointer — do not copy that idiom onto `Opl`). Deterministic
  power-on: all timers stopped, unmasked, no overflow, register file all-zero, `reg_index = 0`.
- Add `opl: Opl.Snapshot` to `Machine.Snapshot` (machine.zig:563), `.opl = self.opl.snapshot()` to
  `Machine.snapshot()` (machine.zig:615), AND the explicit `self.opl.restore(snap.opl)` line to
  `Machine.restore()` (machine.zig:633 — each device has its own restore line; omitting it silently
  breaks the round-trip).
- **Round-trip is exact** because the state is small fixed POD and the only derived value
  (overflow) is recomputed from `start_cycle` + `cycles_now`, both preserved.

## API integration (side-effect-free, non-mutating)

The device reader (`/api/devices`, `/api/device/<name>`, `/api/io`) already exists end-to-end
(controller.zig:948/1035, server.zig:1071/1293). The OPL plugs in as one more group:

1. **`DevOpl` POD** (controller.zig, next to `DevSpeaker`): `installed: bool`, `reg_index: u8`,
   `timer1: { counter, enabled, masked, overflow }`, `timer2: { … }`, and `status: u8` — where
   `overflow`/`status` are **computed via `statusPeek(cyclesNow)`** (NOT a port read). Optionally
   gate the full 256-byte `regs` array behind `?regs=1` (like `?palette=1` for the DAC,
   controller.zig:296) so the default `/api/devices` payload stays small.
2. **`devicesSnapshot()`** (controller.zig:1020): add `.opl = …` reading
   `self.m.opl` raw fields + `self.m.opl.statusPeek(cyclesNow)`. Pure, cycle-neutral, leaves the
   snapshot byte-identical (the load-bearing contract).
3. **`ioShadow(port)`** (controller.zig:1039): add
   `0x388 => self.m.opl.statusPeek(cyclesNow)` and `0x389, 0x38A, 0x38B => 0xFF` (the OPL2
   non-status ports' defined read). This makes `GET /api/io?port=0x388` a non-mutating view — a
   debugger can watch the overflow bits across cycles WITHOUT consuming the latch (contrast the
   live `in8(0x388)` which latches/re-syncs).
4. **Serializers** (server.zig) pick the OPL group up for free once it is a field on
   `DevicesSnapshot`/the `IoShadow` value path; add an `opl` arm to `/api/device/<name>`
   (name `opl`).

## Architecture fit (module graph)

- New module `src/devices/opl.zig`: imports only `bus` (the `PortHandler` contract) + `timing`
  (the cycle clock) + `std` — never `cpu`/`machine` (module-graph rule; identical imports to
  `speaker.zig:45-48`). Exposes `Opl` with `portHandler()`, `reset()`, `snapshot()`/`restore()`,
  `statusPeek()` (pure) and the port `in8`/`out8` thunks.
- `machine.zig` owns the value (`opl: Opl = .{}`), wires `opl.cycles = &cpu.st.cycles`
  (machine.zig:263 block), registers the 4-port range in `wire()` **after** the existing device
  ports (so snapshot replay IDs stay stable — append at the documented tail, machine.zig:251), and
  calls `opl.reset()` in `reset()` and `opl.snapshot()`/restore in the snapshot path.
- `src/debug/controller.zig` + `src/api/server.zig` observe it via the existing reader (never
  drives timing — CLAUDE module graph: api observes, never feeds back into emulation).

## Phase 1 — OPL2 timers + status register + register file (unblocks Stunts)

Spec-compliant subset: full register map STORED, the two cycle-derived timers, the status read
(live + non-mutating shadow), control-reg 0x04 semantics, 4-port wiring, snapshot/restore, reader
integration. **Synthesis registers are stored faithfully but not rendered** (no samples yet).

- [ ] `src/devices/opl.zig`: `Opl` struct — `cycles: ?*const u64`, `reg_index: u8`,
      `regs: [256]u8`, `timer1`/`timer2` (`TimerState{counter,enabled,masked,overflow_latched,
      start_cycle}`). Comptime tick constants `t1_tick_cycles`/`t2_tick_cycles` from
      `timing.CPU_CLOCK_HZ` (80/320 µs). Document the rounding.
- [ ] `statusPeek(self: *const Opl, cycles_now) u8` — the PURE bit-math source of truth
      (`hasOverflowed` per timer → `0x40|0x80` / `0x20|0x80`, then `| 0x06`). No mutation.
- [ ] `statusRead(self: *Opl, cycles_now) u8` — calls `statusPeek` for bits, then LATCHES
      `overflow_latched` and RE-SYNCS `start_cycle` past elapsed periods (the faithful read).
- [ ] `writeReg(idx, val)` — reg 0x02 → `timer1.setCounter(val)` (and sync `start_cycle` like
      `Timer::Update` before set: re-base to now); 0x03 → `timer2.setCounter`; 0x04 → bit7 reset
      both `overflow_latched`; else bit0/bit1 start/stop (Start only re-bases `start_cycle` when
      transitioning stopped→running, mirroring `Start`'s `if(!enabled)` guard), bit6 mask T1,
      bit5 mask T2 (mask clears overflow). ALL other regs (0x01,0x08,0x20-0xF5,…) → store into
      `regs[idx]` only (faithful storage; not rendered in Phase 1).
- [ ] `PortHandler` thunks. NOTE the read and write decodes use DIFFERENT masks:
      - **Writes** decode on `port & 1` (`adlib.cpp:1255/1297`): `out8(0x388 or 0x38A)` →
        `reg_index = val & 0xFF` (address latch); `out8(0x389 or 0x38B)` → `writeReg(reg_index,
        val)`.
      - **Reads** decode on `port & 3` (`opl.cpp:730` — `if (!(port & 3)) return Read()|0x6 else
        return 0xff`): status is returned on **0x388 ONLY**. `in8(0x388)` → `statusRead(cyclesNow)`;
        `in8(0x389 or 0x38A or 0x38B)` → `0xFF`. (Do NOT map 0x38A → status — that mirrors the
        write decode, not the read decode.)
      Direct typed `in8`/`out8` for tests (speaker.zig:130).
- [ ] `reset()`, `Snapshot`, `snapshot()`/`restore()` (POD round-trip; back-pointer re-bound).
- [ ] `machine.zig`: add `opl: Opl = .{}` field; `registerPortRange(0x388, 4, opl.portHandler())`
      appended at the tail of `wire()`; `opl.cycles = &cpu.st.cycles`; `opl.reset()` in `reset()`;
      `Opl.Snapshot` in the aggregate + snapshot/restore.
- [ ] `controller.zig`: `DevOpl` POD; OPL group in `devicesSnapshot()` (via `statusPeek`); `0x388`
      (status peek) + `0x389/0x38A/0x38B` (`0xFF`) in `ioShadow()`.
- [ ] `server.zig`: `opl` arm in `/api/device/<name>`; (the `/api/devices` + `/api/io` paths pick
      it up automatically).

### Phase 1 tests
- [ ] **The exact AdLib detection sequence passes** (the §"Why now" probe), driven on a `Machine`
      directly: program Timer-1 (`0x04←0x60` mask/reset; read 0x388 → `0x06`; `0x02←0xFF`;
      `0x04←0x21` start T1 unmasked; **advance the cycle ledger ≥ 1×80 µs worth of cycles
      (`>= t1_tick_cycles`)** via `cpu.st.cycles += …` or a `runCycles`; read 0x388 → `0xC0|0x06`;
      `0x04←0x60`; read 0x388 → `0x06`). Assert each read. (This proves the OPL2 timer/status model
      is SPEC-CORRECT against the canonical probe. It does NOT by itself prove Stunts unblocks — see
      the unverified-premise caveat in §"Why now"; an end-to-end Stunts run past `F000:10D3` is the
      separate gate for that.)
- [ ] **Counter rewrite mid-run re-bases the period** (the `start_cycle` re-sync invariant): start
      T1, advance, write a NEW `0x02` counter, advance, assert overflow flips at the new period
      measured from the rewrite cycle (proves `writeReg(0x02/0x03)` re-syncs `start_cycle` BEFORE
      applying the new counter, like `Timer::Update` precedes `SetCounter`).
- [ ] **bit7 reset clears ONLY the latch**: after a T1 overflow, write `0x04←0x80` (reset, NO mask)
      and assert `overflow_latched` cleared but `start_cycle`/`enabled`/`masked` UNCHANGED — so a
      still-enabled, still-elapsed timer re-overflows on the next read (matches `Timer::Reset`).
- [ ] **Masked timer never overflows**: start T1 with bit6 (mask T1) set → after a full period,
      status bit6/bit7 stay clear (mirrors `Chip::Read` "won't be set if masked").
- [ ] **Period formula**: counter `0x00` → overflow after (256−0)=256 ticks; counter `0xFF` →
      1 tick. Assert `hasOverflowed` flips at exactly `(256-C)*tick_cycles`.
- [ ] **OPL2 discriminator bits**: a no-overflow read returns `0x06` (bits 1,2 set) — proves the
      `| 0x06` is present (some routines key on it to tell OPL2 from OPL3).
- [ ] **Determinism (double-run)**: two `Machine`s, identical port-write script + identical
      `cpu.st.cycles` advances → byte-identical status reads at every step and byte-identical
      `machine.snapshot()`.
- [ ] **Cycle-neutral inspection (load-bearing)**: snapshot `machine`; call `devicesSnapshot()`
      and `ioShadow(0x388)` (the status PEEK); snapshot again → **byte-identical**, and assert the
      OPL `overflow_latched`/`start_cycle` are UNCHANGED. Contrast guard: a separate test that
      DOES `opl.in8(0x388)` after an overflow asserts `overflow_latched` flipped to true and
      `start_cycle` advanced (proving the live read mutates and the peek does not — exactly the
      0x3DA flip-flop contrast in plans/device-state-reader.md).
- [ ] **Snapshot round-trip**: program timers + write a few synthesis regs (e.g. 0x20, 0xA0,
      0xB0); `snapshot()` → mutate → `restore()` → assert all `regs[]`/timer fields and the
      recomputed status match.
- [ ] **Unmapped→mapped**: assert `bus.portIn8(0x388)` was `0xFF` before wiring and is the OPL
      status after (the direct fix for "0x388 unmapped").
- [ ] **No host time / float** grep test on `opl.zig` (mirror timing.zig:74).
- [ ] Integration (`server_integration_test.zig`): `GET /api/devices` includes the `opl` group;
      `GET /api/io?port=0x388` twice in a row returns the SAME value and a following
      `/api/devices` shows `overflow_latched` unchanged (HTTP-level purity proof).

## Phase 2 — audio synthesis (DEFERRED, faithful — designed, NOT stubbed)

Phase 1 makes detection correct and stores every synthesis register faithfully but renders **no
samples**. This is an HONEST scoped subset, not a fake: the register file is real state, and the
gap (no FM output) is explicit. Phase 2 ports a real OPL2 core. **Never** a stub that returns
silence-pretending-to-be-sound or hardcoded waveforms.

### Which core, and why
**Port Nuked-OPL3** (`references/dosbox-staging/src/libs/nuked/opl3.c` + `opl3.h`; there is no
separate OPL2 core — Nuked is OPL3/YMF262 and OPL2 is run as a subset) — the core
dosbox-staging vendors and uses (`NukedOPL::Handler`, adlib.cpp:371-409 in dosbox-x;
`opl.cpp` in staging). Rationale:
- It is a **cycle-exact, integer** model of the YM3812/YMF262 (no floats in the sample path) —
  the determinism prime directive is satisfiable: samples become a pure function of (register
  writes, sample index), with **no host audio clock** (CLAUDE #2/#3). DBOPL (the older DOSBox core,
  `dbopl.cpp`) is faster but less accurate and uses some float tables; Nuked is the faithful
  choice and matches "no shortcuts."
- An OPL2 is a strict subset of Nuked's OPL3 (instantiate in OPL2 mode — single bank, no 4-op,
  no second register page), so one ported core serves both if zdos later adds OPL3.
- dosbox-staging already drives it deterministically (`OPL3_Reset(rate)`,
  `OPL3_WriteRegBuffered`, `OPL3_GenerateStream`) — a known-good integration template.

### Sample-generation path (determinism-preserving)
- The core generates samples at the fixed OPL rate **49716 Hz** (`OplSampleRateHz`,
  opl.cpp:29) — a CONSTANT, never the host audio device rate. The number of samples to generate
  between two points is `f(cpu.st.cycles)`: `samples = (cycles_elapsed * 49716) / CPU_CLOCK_HZ`
  (integer, with a carried remainder accumulator like `timing.ticksToCycles`), NOT a host
  wall-clock duration. Headless: samples are captured **on demand** (a ring/buffer the API can
  read), exactly as the framebuffer is captured on demand — never pushed to a real audio device on
  the emulation thread.
- Register writes are applied to the Nuked chip **at the cycle they occur** (the emulation is
  single-threaded; a write at cycle N is ordered before sample N's generation), so the
  guest↔synth ordering is deterministic — no "smearing" across a host buffer.
- The Nuked `opl3_chip` is large but pointer-free POD → it extends the `Opl.Snapshot` (or is
  snapshotted alongside) so audio state round-trips with the rest of the machine.
- The timer/status path from Phase 1 is UNCHANGED — it stays the cycle-derived integer model;
  Nuked's own internal timers are NOT used for the status port (DOSBox keeps `Adlib::Timer`
  separate from the synth core for exactly this reason — adlib.h:124 has `Timer timer0,timer1`
  alongside the `handler` synth). zdos does the same: Phase-1 timers remain the status source.

### Phase 2 work (sketch; its own milestone)
- [ ] Port `nuked/opl3.{c,h}` to Zig (or vendor as a faithful translation) — integer-only sample
      path; verify no float/host-time creeps in (the grep test).
- [ ] OPL2-mode instantiation + apply `regs[]` writes through it.
- [ ] Cycle→sample integer conversion with a remainder accumulator (no host audio clock).
- [ ] On-demand capture buffer + an API endpoint to read rendered samples (headless).
- [ ] Snapshot the chip POD; determinism double-run on a known FM tune (byte-identical samples).
- [ ] Determinism regression: render N samples to a golden; re-run → byte-identical.

## Honesty / structural-gap notes

- **Phase 1 is spec-compliant for the timer/status/register-file subset** — the overflow bits,
  the 0x04 control semantics, and the OPL2 discriminator (`| 0x06`) are faithful to the YM3812
  and to both DOSBox cores. It is NOT a hardcoded detection result: the probe passes because the
  cycle-derived timer genuinely overflows at the right cycle. A guest that does anything other than
  the standard probe (e.g. reads counters back via reg 0x02/0x03 — note real OPL2 does NOT expose
  counter readback; only ESFM does, `EsfmReadbackReg`) gets the faithful behaviour (reg 0x389
  read = 0xFF), not a faked value.
- **Audio synthesis is explicitly out of Phase 1.** Writes to synthesis registers (0x01, 0x08,
  0x20–0xF5, 0xA0–0xC8, 0xBD) are STORED in `regs[]` faithfully but produce no sound. This is
  stated to the API consumer via the `DevOpl` group (the register file is observable; absence of a
  sample stream is the honest gap). Phase 2 closes it by porting Nuked — designed above, not
  stubbed.
- **The DOSBox `adlib_force_timer_overflow_on_polling` hack is deliberately NOT ported** — it is a
  host-wall-clock heuristic that fabricates overflow for games whose detection loop outpaces
  DOSBox's cycle model. zdos's faithful cycle-derived timer makes it unnecessary; porting it would
  read host time and fake the result (two prime-directive violations). If a real guest is ever
  found that the faithful model still fails, that is a genuine cycle-model bug to investigate
  (likely the CPU cycle cost of the busy-wait), NOT a reason to fabricate overflow — surface it.
- **No 0x220 Sound-Blaster OPL mirror, no IRQ line.** The bare AdLib card maps only 0x388-0x38B and
  does not wire an interrupt (poll-based detection, `adlib.cpp` has no `PIC_ActivateIRQ`). The SB
  OPL mirror at 0x220 belongs to a future Sound Blaster device; registering it here would be
  premature. Flagged, not faked.
- **No DMA.** The OPL is a pure port device (no 8237) — consistent with zdos having no DMA model
  (plans/device-state-reader.md); nothing to fabricate.
- **ROADMAP**: `plans/ROADMAP.md` should get an OPL2/AdLib entry **when Phase 1 lands** (the
  source-of-truth convention). This plan does NOT edit ROADMAP.
