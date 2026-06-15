# VGA Input Status Register #1 (port 0x3DA / 0x3BA) — deterministic vertical-retrace / display-enable

Status: **design plan** (no source changed by this document). Implementation-ready.

> **Status: v2.** Revised after a 3-perspective review (determinism, VGA-hardware fidelity, Zig
> 0.16/integration); every `file:line` and constant re-verified against the real source. Targeted
> edits, structure preserved. Changes by area:
> (1) **CRITICAL timing-constant fix — the geometry was off by 2×.** v1 pinned `HTOTAL_DOTS = 400`,
> but mode 13h is **800 dots/line** (8 dots × 100 character-clocks). That made the v1 `FRAME_CYCLES`
> a *140 Hz* frame, not the canonical 70.086 Hz (v1's own self-check mis-read `14_318_184/102_146` as
> "70.18 Hz" — it is 140.17 Hz). §3.2 is re-derived from the correct 800-dot geometry; the abandoned
> 400-dot / `101_923` / `102_146` / "140 Hz" narrative is **struck entirely** (not left as rejected
> reasoning an implementer could transcribe). The corrected, floor-pinned constants:
> `FRAME_CYCLES = 204_293`, `LINE_CYCLES = 454`, `HDE_CYCLES = 181`. Effective refresh
> `14_318_184 / 204_293 = 70.0865 Hz` ✓.
> (2) **Prose fix:** Zig `/` is **floor / truncating** division, NOT "round-to-nearest" — the
> comptime expressions truncate; every "round" claim is corrected.
> (3) **Comptime-pin hardened** (§3.2, P1): the assert uses the *identical truncating expression* AND
> separately asserts the effective refresh ≈ 70.086 Hz (a tight tolerance against
> `CPU_CLOCK_HZ * 1000 / 70086`) — so it validates against the canonical target rather than
> rubber-stamping whatever the inputs produce.
> (4) **Determinism grep-gate coverage** (new P5 item): `vga.zig` is NOT in the float/host-clock grep
> gate (`src/devices/pit_test.zig:53-58` embeds only pic/pit/keyboard/devices). The checklist now
> requires adding `@embedFile("vga.zig")` to that gate's `sources` array (the temptation to write an
> `f64` "70.086 Hz" is real — both refs use `double`/`fmod`).
> (5) **`timing` import** (P1): `vga.zig` imports only `std`+`bus` today; the design uses
> `timing.CPU_CLOCK_HZ`, so P1 adds `const timing = @import("timing");` (module already wired into
> `devices_mod` in `build.zig:68`; `speaker.zig:48` uses it). Derived constants are exposed `pub` on
> `Vga` so tests read `devices.Vga.FRAME_CYCLES` with no new test-module import.
> (6) **Test hardening** (§5.2/P5): both poll **Shape A** (bit-3 retrace) and **Shape B** (bit-0
> Borland `putch`) must *terminate*; assert **two-run byte-identity** (not an external golden); add a
> **window-width safety assertion** flagging the dependency on the deferred per-instruction PRM cost
> pass (`src/cpu/cycles.zig:81-86`).
> (7) **0x3C0 attribute-write path** (D-RT3): must be a **loud flag** (assert or explicit
> "not implemented"), never a silent no-op — matching the codebase's inert-register / BCD-assert
> discipline (`src/devices/pit.zig:260`).
> (8) **KEYECHO acceptance gate explicit** (§5.3/P6): switch `examples/dos-src/KEYECHO.C` back to the
> real Borland `putch()` (removing the current `bdos(2,...)` workaround), recompile via
> `tools/bcc.sh`; getting KEYECHO with real `putch()` to run end-to-end is **the acceptance gate** for
> this feature.

Owner module: `src/devices/vga.zig` (+ one wiring line in `src/machine/machine.zig`).

---

## 1. Problem statement

Many DOS programs poll the VGA **Input Status Register #1** (port `0x3DA` in colour mode, `0x3BA`
in mono mode) in a tight loop to either:

- **(a) Wait for vertical retrace before touching video memory** — snow-free / tear-free drawing.
  Borland's direct-video console runtime (`putch`/`cprintf` with `directvideo=1`) does this, and
  many mode-13h engines do it before a palette/VRAM update.
- **(b) Sync the frame loop to the ~70 Hz vertical refresh** — the canonical mode-13h game frame
  pacing.

zdos does **not** model `0x3DA`. The VGA device registers only the DAC ports (`0x3C6`-`0x3C9`),
the misc-output register (`0x3C2` write / `0x3CC` read) — see `src/devices/vga.zig:222-224` and the
scope note at `src/devices/vga.zig:24-27`. `0x3DA`/`0x3BA` are **unregistered**, so a guest read
falls through the bus port dispatch to the unmapped fill:

- `Bus.portIn8` returns `ports.unmapped_in8` for an unregistered port — `src/bus/bus.zig:497-501`.
- `ports.unmapped_in8 = 0xFF` — `src/bus/ports.zig:84`.

`0xFF` has **bit 3 set permanently** (the vertical-retrace bit) and **bit 0 set permanently** (the
display-enable/blanking bit). The two common loop shapes both misbehave:

```asm
; Shape A — "wait until NOT in retrace, then wait FOR retrace" (frame sync).
@@wait_not:  in   al, 0x3DA
             test al, 8
             jnz  @@wait_not      ; bit 3 stuck 1 => spins forever
@@wait_for:  in   al, 0x3DA
             test al, 8
             jz   @@wait_for

; Shape B — Borland putch snow-avoid (observed in KEYECHO):
             in   al, 0x3DA
             ror  al, 1           ; rotates bit 0 (display-enable) into carry
             jc   $-5             ; CF set while "displaying"; 0xFF => CF always 1 => spins
```

Concretely, this was found via **KEYECHO**: Borland `putch` hangs in `in al,0x3da; ror al,1; jc -5`
because bit 0 of `0xFF` is always set. The whole class of retrace-polling DOS graphics software is
blocked. The bounded blackbox harness (`tests/blackbox/keyecho_test.zig:27-29`) prevents a *host*
hang, but the guest never makes progress.

### The fix, and the hard constraint it must honour

The retrace/display-enable bits MUST be a **pure function of the CPU cycle counter** (`cpu.st.cycles`),
never the host wall clock. This is CLAUDE.md prime directive #2 ("Emulated time = f(cycle counter)")
and #3 ("No dependence on host scheduling or real I/O timing"). Because a guest poll loop *executes
instructions*, the cycle counter advances on every `in al,0x3DA`/`ror`/`jc` iteration, so a
cycle-derived scan position advances too, the bit flips at a **deterministic cycle**, and the loop
terminates reproducibly. Break at cycle N → identical `0x3DA` value, every run (CLAUDE.md #6).

The existing scope note that says the retrace bits are "DELIBERATELY NOT modeled"
(`src/devices/vga.zig:24-27`) was written when no retrace-polling guest was in scope. It is now
wrong for the *device* layer (a real VGA always answers `0x3DA`); it remains correct for the
**oracle** layer (these bits must never enter a cross-emulator golden — see §5). This plan flips the
device-layer decision and tightens the oracle-layer wording.

---

## 2. Investigation summary

### 2.1 zdos timing + VGA internals (the deterministic time source)

- **The cycle counter is the single time source.** `cpu.st.cycles` is a `u64`; the CPU is its sole
  writer (`src/machine/machine.zig:25`). Devices that need emulated time take a `cycles: ?*const u64`
  back-pointer wired to `&self.cpu.st.cycles` at `wire()`. The PIT does this
  (`src/devices/pit.zig:146`, wired `src/machine/machine.zig:228`) and so does the PC-speaker
  (`src/devices/pit.zig`/speaker, wired `src/machine/machine.zig:240`). **The VGA device currently
  has NO such back-pointer** — it must be added (it is a pure-state device today).

- **The PIT is the worked model of "device state as a pure function of cycles."** Its live counter
  is derived on read from elapsed cycles, never stored-and-ticked:
  `PitChannel.liveCounter(cycles_now)` computes `elapsed_cycles = cycles_now - last_arm_cycle`, then
  `timing.cyclesToTicks(elapsed_cycles)`, then `period - (elapsed % period)` for periodic modes —
  `src/devices/pit.zig:119-138`. Its OUT bit (`outBit`, `src/devices/pit.zig:398-423`) is the same
  pattern: `into = elapsed_ticks % period; into < half`. **This is exactly the shape the retrace
  model should copy**: `into = elapsed % frame_period; bit = into in [retrace_start, retrace_end)`.

- **The timing constants leaf.** `src/abi/timing.zig` pins `PIT_TICK_RATE = 1_193_182`
  (`:18`) and `CPU_CLOCK_HZ = PIT_TICK_RATE * 12 = 14_318_184` (~14.32 MHz) (`:25`), with the
  integer conversion `cyclesToTicks`/`ticksToCycles` (`:60-72`). It is grep-enforced to contain no
  host time / RNG / float (`:74-88`). The VGA frame period must be expressed in **CPU cycles** using
  this same `CPU_CLOCK_HZ`, as an integer constant computed at comptime (see §3.2).

- **The scheduler is cycle-keyed.** `Scheduler` keys every event on an absolute `fire_cycle: u64`
  (`src/machine/scheduler.zig:38-50`); `EventKind` is `{pit_ch0, pit_ch1, pit_ch2}` today
  (`:31-35`). A retrace *status poll* needs **no scheduler event** — the bit is computed on read.
  (A scheduler event would only be needed for a vertical-retrace *IRQ*, which mode-13h BaK-class
  software does not use; see §6.) So this design adds **zero** new `EventKind`s.

- **Port read flow.** `Bus.portIn8(port)` → `port_handler_id[port]` → `port_handlers[id].?.in8(port)`
  (`src/bus/bus.zig:497-501`). A device implements `PortHandler.in8(ctx, port) u8`; the VGA's is
  `Vga.portIn8` (`src/devices/vga.zig:266-276`), a `switch (port)`. Adding `0x3DA`/`0x3BA` is a new
  arm in that switch plus a `registerPort` call in `wire()`. The handler contract requires purity
  (a pure function of device state + the cycle counter it reads through its back-pointer) —
  `src/bus/bus.zig:26-30`.

- **Snapshot.** `Vga.Snapshot` (`src/devices/vga.zig:302-334`) captures DAC + misc-output by value;
  VRAM is copied separately by the machine. The cycle counter is owned by the CPU, not the VGA, so
  the retrace value needs **no new snapshot field** (it is derived). The *only* new mutable
  guest-visible state is the attribute-controller flip-flop (§3.4), which must be added to the
  snapshot.

### 2.2 How the reference emulators model 0x3DA

#### dosbox-staging — emulated-time-derived, full CRTC duty cycle

`vga_read_p3da` (`references/dosbox-staging/src/hardware/video/vga_misc.cpp:19-44`):

```cpp
uint8_t vga_read_p3da(io_port_t, io_width_t) {
    uint8_t retval = 4;                               // bit 2 always set (Blues Brothers)
    const auto timeInFrame = PIC_FullIndex() - vga.draw.delay.framestart;
    vga.attr.is_address_mode = true;                  // <-- attribute flip-flop reset (side effect)
    vga.tandy.pcjr_flipflop = false;
    // bit 3 = vertical retrace
    if (timeInFrame >= vga.draw.delay.vrstart && timeInFrame <= vga.draw.delay.vrend)
        retval |= 8;
    // bit 0 = display-enable (h-or-v blanking)
    if (timeInFrame >= vga.draw.delay.vdend) {
        retval |= 1;                                  // past last display line => blanking (vblank)
    } else {
        const auto timeInLine = fmod(timeInFrame, vga.draw.delay.htotal);
        if (timeInLine >= vga.draw.delay.hblkstart && timeInLine <= vga.draw.delay.hblkend)
            retval |= 1;                              // within hblank window
    }
    return retval;
}
```

Time source — **emulated, not host wall clock**: `PIC_FullIndex()` =
`PIC_Ticks + PIC_TickIndex()` where `PIC_TickIndexND() = CPU_CycleMax - CPU_CycleLeft - CPU_Cycles`
(`references/dosbox-staging/src/hardware/pic.h:29-52`). That is **fraction of the current emulated
millisecond consumed by executed cycles** — derived from the CPU cycle budget. `framestart` is set
to `PIC_FullIndex()` at the start of each emulated frame in `VGA_VerticalTimer`
(`references/dosbox-staging/src/hardware/video/vga_draw.cpp:1390`). So dosbox's retrace is a function
of emulated cycles — **the model zdos should adopt** (zdos has an even cleaner single `u64` counter,
no budget/`CycleLeft` bookkeeping).

The timing constants (all in milliseconds, computed in `VGA_SetupDrawing`,
`references/dosbox-staging/src/hardware/video/vga_draw.cpp:2031-2064`):

```cpp
const auto fps     = VGA_GetRefreshRate();               // mode-13h => ~70.086 Hz
const auto f_clock = fps * vert.total * horiz.total;     // dot/char clock in Hz
htotal   = horiz.total      * 1000.0 / f_clock;          // ms per scanline
hblkstart= horiz.blanking_start * 1000.0 / f_clock;
hblkend  = horiz.blanking_end   * 1000.0 / f_clock;
vrstart  = vert.retrace_start * htotal;                  // ms into frame, v-retrace start
vrend    = vert.retrace_end   * htotal;
vdend    = vert.display_end   * htotal;                  // ms into frame, last display line
// vtotal (frame period in ms) = 1000.0 / fps                (:3286)
```

dos_refresh_hz itself: `clock / (vert.total * horiz.total)`
(`references/dosbox-staging/src/hardware/video/vga_draw.cpp:2281-2282`). The pixel clock for VGA is
`Vga640PixelClockHz = 25_175_000` (`references/dosbox-staging/src/hardware/video/vga.h:140`),
divided by the clocking-mode dot count, with pixel-doubling doubling `horiz.total` for 320-wide
modes (`vga_draw.cpp:119-130`).

**Mode-13h CRTC totals** (BIOS mode table, `references/dosbox-staging/src/ints/int10_modes.cpp:45`):

```
{ 0x013, M_VGA, sw=320, sh=200, tw=40, th=25, cw=8, ch=8, pt=1, A0000, 0x2000,
  htot=100, vtot=449, hde=80, vde=400, flags=0 }
```

Reconciling to the canonical hardware figure: dosbox's table stores `htot`/`hde` in **character**
units (100/80 chars). The 8-dot char clock is the 25.175 MHz pixel clock ÷8 (`vga_draw.cpp:1948`,
`clock /= PixelsPerChar::Eight`), so `f_clock = fps * vert.total * horiz.total` is built on the
*char* clock and `horiz.total ≈ 100` char-clocks (`vga_draw.cpp:2031-2032`, `:2281-2282`). One line
is therefore **100 char-clocks × 8 dots = 800 dots** at the 25.175 MHz pixel clock. With
`vtotal = 449 lines`, the refresh is `25_175_000 / (800 × 449) = 70.086 Hz`. So the canonical
hardware triple zdos pins (§3.2) is **htotal = 800 dots, vtotal = 449 lines, dot clock 25.175 MHz**.
Active region: `hde = 80 chars × 8 = 640`… but mode 13h is **pixel-doubled** (the BIOS programs the
double-scan / pixel-doubling so 320 logical pixels fill the 640-dot active span); zdos models the
display-enable window from the **320 active mode-13h pixels of the 800-dot line** (§3.1/§3.2).
Vertical retrace begins a few lines after the display end (`vde=400`): on real VGA the mode-13h
CRTC sets v-retrace-start ≈ line 412 and v-retrace-end ≈ line 414.

dosbox models **CGA "snow"** only on the legacy CGA path (`vga_other.cpp`), not on `vgaonly`/VGA —
irrelevant to zdos's VGA-only scope.

#### spice86 — emulated-time-derived, scanline event chain (deterministic core)

spice86 **does** model `0x3DA` and does so deterministically off emulated time:

- The read handler (`references/spice86/.../Video/VgaIoPortHandler.cs:161-166`) returns
  `_generalRegisters.InputStatusRegister1.Value` and, as a **side effect, resets the attribute
  flip-flop**: `_attributeDataMode = false` ("Reset the attribute data mode for port 0x03C0 to
  Index"). The register fields are bit 3 = `VerticalRetrace`, bit 0 = `DisplayDisabled`
  (`InputStatusRegister1.cs`).
- The bits are *set* by `VgaTimingEngine`
  (`references/spice86/.../Video/VgaTimingEngine.cs`): a scanline-walking event chain on its
  `DeviceScheduler` + `IEmulatedClock`. `OnFrameStart` clears both bits, schedules per-scanline
  active/hblank events that toggle `DisplayDisabled`, and `OnVerticalRetraceStart` sets both bits
  (`:77-107`). Comment: "fire deterministically on the emulation thread instead of on a UI timer."
- Its clock is cycle-derived: `CyclesClock.ElapsedTimeMs = Cycles * 1000 / CyclesPerSecond + jitter`
  (`references/spice86/.../VM/Clock/CyclesClock.cs:21-22`).

**Determinism lens — what to copy vs avoid:**

- **Copy (both refs):** derive the bits from *emulated* time (cycle counter), and **reset the
  attribute flip-flop on read** (both refs do this — dosbox `vga.attr.is_address_mode = true`,
  spice86 `_attributeDataMode = false`).
- **Avoid — host-ish / non-integer:** dosbox uses `double` ms + `fmod`, and its `framestart` rides on
  the `CycleMax/CycleLeft` budget bookkeeping; spice86's `CyclesClock` **adds a `_jitter.Advance()`
  term** and uses `double` ms with a *hardcoded* `31469` Hz horizontal rate
  (`VgaTimingEngine.cs:13`). zdos must use **pure `u64` integer math from `cpu.st.cycles`, no float,
  no jitter, no scheduler event** for the status poll. Neither ref is byte-reproducible across runs
  for retrace timing; zdos defines its own deterministic semantics (this is the project's whole
  point).

---

## 3. The deterministic scan-position design

### 3.1 Core idea

Model a free-running CRT beam whose position is a pure function of `cpu.st.cycles`. On a `0x3DA`
read, compute the cycle offset into the current frame, derive (scanline, dot-in-line), and set the
status bits. **No stored, ticked state**; **no scheduler event** (mirrors `Pit.liveCounter` /
`Pit.outBit`, `src/devices/pit.zig:119-138`, `:398-423`).

```
now            = cpu.st.cycles                 // the single u64 time source
into_frame     = now % FRAME_CYCLES            // 0 .. FRAME_CYCLES-1  (free-running, anchored at 0)
scanline       = into_frame / LINE_CYCLES      // 0 .. 449  (floor div; 449 occurs — see §3.2 note)
into_line      = into_frame % LINE_CYCLES      // 0 .. LINE_CYCLES-1

bit3 (vretrace)      = (scanline >= VRSTART_LINE and scanline < VREND_LINE)
displaying           = (scanline < VDE_LINES) and (into_line < HDE_CYCLES)
bit0 (display-enable)= !displaying             // 1 == in h-or-v blank/retrace ("display disabled")
```

`scanline` reaches **449** for the final ~447 cycles of each frame (see the §3.2 scanline-range
note). That value is past `VDE_LINES` and outside `[VRSTART_LINE, VREND_LINE)`, so it yields the
same vblank status as scanline 448 — **no clamp** is required (and none must be added).

`into_frame = now % FRAME_CYCLES` anchors frame 0 at cycle 0 — a deterministic, reset-stable phase
(unlike dosbox/spice86 which anchor at a per-frame event time). This is *more* reproducible and is
fine: guests poll for *transitions*, not an absolute phase. (If a future need arises to re-anchor the
phase on a mode-set, store a `frame_anchor_cycle: u64` in the snapshot and subtract it; not needed
for v1 — see §6.)

The key property holds: each loop iteration burns cycles (an `in` + a few ALU/branch ops, charged by
the CPU's instruction-cost model), so `now` grows, `into_frame` advances, and bit 3 / bit 0 flip at
deterministic cycles. The loop terminates at a reproducible cycle, byte-identically across runs.

### 3.2 Timing constants — mode 13h (and text mode)

Pin the canonical VGA hardware triple and derive cycles from `CPU_CLOCK_HZ` at comptime. Expose them
as `pub const` on the `Vga` module/struct in `src/devices/vga.zig` so tests read them via
`devices.Vga.FRAME_CYCLES` without a new test-module import. All conversions use Zig integer `/`,
which is **floor / truncating** division. Expressed in **integer CPU cycles**:

```zig
// Canonical mode-13h / standard-VGA 70 Hz timing (also mode 03h text — same CRTC family).
//   pixel (dot) clock        = 25_175_000 Hz   (dosbox Vga640PixelClockHz, vga.h:140)
//   horizontal total         = 800 dots/line   (8 dots/char × 100 char-clocks;
//                                                the BIOS mode table's htot=100 is in CHARACTER units)
//   vertical total           = 449 lines/frame
//   => vertical refresh      = 25_175_000 / (800*449) = 70.086 Hz   (the canonical figure)
//   horizontal display end   = 320 dots (active pixels per line, mode 13h)
//   vertical display end     = 400 lines (double-scanned 200) ; v-retrace ~lines 412..414

pub const DOT_CLOCK_HZ : u64 = 25_175_000;
pub const HTOTAL_DOTS  : u64 = 800;   // 8 dots/char × 100 char-clocks (table htot=100 is in chars)
pub const VTOTAL_LINES : u64 = 449;
pub const HDE_DOTS     : u64 = 320;   // active pixels per line (display-enable high region)
pub const VDE_LINES    : u64 = 400;   // last active scanline (display end)
pub const VRSTART_LINE : u64 = 412;   // vertical retrace pulse start (lines)
pub const VREND_LINE   : u64 = 414;   // vertical retrace pulse end

// Convert the dot-clock geometry into CPU cycles using the pinned CPU clock
// (timing.CPU_CLOCK_HZ = 14_318_184). Pure integer math, evaluated at comptime;
// Zig `/` is FLOOR (truncating) division, so the constants are byte-stable.
//   FRAME_CYCLES = CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ
//   LINE_CYCLES  = FRAME_CYCLES / VTOTAL_LINES
//   HDE_CYCLES   = CPU_CLOCK_HZ * HDE_DOTS / DOT_CLOCK_HZ
pub const FRAME_CYCLES : u64 = timing.CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ;
pub const LINE_CYCLES  : u64 = FRAME_CYCLES / VTOTAL_LINES;
pub const HDE_CYCLES   : u64 = timing.CPU_CLOCK_HZ * HDE_DOTS / DOT_CLOCK_HZ;

comptime {
    // Pin against the CANONICAL target, not a re-derivation that could rubber-stamp
    // a wrong input. Mirrors the timing.zig comptime-pin style (timing.zig:45-50).
    std.debug.assert(FRAME_CYCLES == 204_293);
    std.debug.assert(LINE_CYCLES == 454);
    std.debug.assert(HDE_CYCLES == 181);
    // Effective refresh ≈ 70.08 Hz: 14_318_184 * 100 / 204_293 = 7008 (= 70.08 Hz).
    std.debug.assert(timing.CPU_CLOCK_HZ * 100 / FRAME_CYCLES == 7008);
}
```

Worked numbers (floor / truncating division, Zig `/`):
- `FRAME_CYCLES = 14_318_184 * 800 * 449 / 25_175_000 = ` **`204_293`** cycles/frame.
- Effective refresh = `14_318_184 / 204_293 = ` **`70.086 Hz`** ✓ (the canonical figure).
- `LINE_CYCLES = 204_293 / 449 = ` **`454`** cycles/scanline.
- `HDE_CYCLES = 14_318_184 * 320 / 25_175_000 = ` **`181`** cycles.

So pin **`FRAME_CYCLES = 204_293`** (70.086 Hz at the 14.318 MHz pinned CPU clock — the canonical
figure), `LINE_CYCLES = 454`, `HDE_CYCLES = 181`, `VRSTART_LINE = 412`, `VREND_LINE = 414`,
`VDE_LINES = 400`. These are **comptime integer constants**; the `comptime` block above pins them
against the canonical refresh target so a future edit can't silently drift (mirrors
`timing.zig:45-50`).

**Scanline-range note (no clamp needed).** `scanline = into_frame / LINE_CYCLES` spans `0..449`
(inclusive of 449), because `LINE_CYCLES × VTOTAL = 454 × 449 = 203_846 < FRAME_CYCLES = 204_293` —
the final ~447 cycles of each frame read scanline 449. This is **harmless and needs no clamp**:
scanline 449 is past `VDE_LINES` (display-enable blank) and outside `[VRSTART_LINE, VREND_LINE)`
(no retrace), so its status byte is identical to scanline 448 (both vblank). An implementer must
**not** add a clamp or panic for scanline 449.

> **Decision D-RT1: faithful simplified duty cycle, not full programmable CRTC.** zdos pins the
> mode-13h/standard-VGA 70 Hz timing as fixed constants rather than reading the CRTC registers
> (which zdos keeps "present-but-inert", `src/devices/vga.zig:16-19`). Justification: (1) BaK and the
> oracle corpus only ever run mode 13h / standard text — they never reprogram the CRTC totals
> (`plans/io-oracle.md §1.4`); (2) the retrace bits are explicitly **excluded from every
> cross-emulator golden** (`plans/io-oracle.md:172-176`, `:396-400`), so absolute timing fidelity
> has no oracle to match — only *internal* determinism and *loop-terminating* behaviour matter;
> (3) a fixed duty cycle is trivially deterministic and snapshot-free. **Structure the code so a
> per-mode timing table can be slotted in later** (a `mode: Mode` field selecting a constants
> struct) if a guest ever reprograms the CRTC — flag, don't pre-build (CLAUDE ground rule).

**Text mode (03h):** same CRTC family / same 70 Hz frame (the BIOS mode table uses `vtot=449` for
modes 0-3 too, `int10_modes.cpp:30-33`). Reuse the *same* `FRAME_CYCLES`/`LINE_CYCLES`; only
`HDE_DOTS` differs (720 active of a wider htotal). For v1, the **same constants are acceptable** for
text mode because the only consumer is a retrace-wait loop that cares about bit 3 (frame-level, mode-
independent) and bit 0's blanking duty (a coarse fraction). If a text-mode `putch` snow-avoid loop is
observed needing a different htotal, add a text constants struct then.

### 3.3 Status byte — all bits of Input Status Register #1

A faithful VGA `0x3DA` read returns (low byte; high bits read as the floating bus / undefined — VGA
docs leave 4-7 unspecified, real cards return them low):

| Bit | Meaning | zdos value |
|-----|---------|------------|
| 0 | Display-enable complement (1 = in horizontal **or** vertical blank/retrace) | computed (§3.1) |
| 1 | Light-pen trigger (obsolete on VGA) | 0 |
| 2 | Light-pen switch (obsolete on VGA) | dosbox sets **1** (`vga_misc.cpp:21`, "needed by Blues Brothers"); zdos: **1** for compatibility |
| 3 | Vertical retrace (1 = in v-retrace) | computed (§3.1) |
| 4-5 | Reserved / video feedback (diagnostic) | 0 |
| 6-7 | Reserved | 0 |

So the assembled byte = `0x04 (bit2) | (bit3? 0x08) | (bit0? 0x01)`. Matching dosbox's `retval = 4`
base keeps the one documented compatibility quirk (bit 2) without inventing anything.

> **Decision D-RT2: keep bit 2 = 1.** dosbox sets it unconditionally with a cited game dependency.
> It costs nothing and is the only non-derived bit; copying it avoids a future "Blues Brothers"-class
> surprise. This is a faithful reproduction of documented hardware-emulator behaviour, not a fake.

### 3.4 The attribute-controller flip-flop reset (read side effect)

Reading `0x3DA`/`0x3BA` **resets the attribute controller (port `0x3C0`) address/data flip-flop** to
the *address* (index) phase. Both refs do this (dosbox `vga.attr.is_address_mode = true`,
`vga_misc.cpp:24`; spice86 `_attributeDataMode = false`, `VgaIoPortHandler.cs:162`). This is *real,
deterministic, guest-visible state* — programs read `0x3DA` precisely to guarantee the next `0x3C0`
write is interpreted as an index, not data.

**zdos does NOT currently model the attribute controller (0x3C0/0x3C1) at all** — confirmed: no
`attr`/`0x3C0` state in `src/devices/vga.zig`; the register files are "present-but-inert"
(`:16-19`). So:

> **Decision D-RT3: scope the flip-flop minimally now, model the AC fully only when a guest needs
> it.** Add a single `bool attr_flip_flop_is_index` field to `Vga` *now* (so the `0x3DA` read can
> set it to `true`, faithfully reproducing the documented side effect and making it snapshot-stable),
> but do **not** build the full `0x3C0` address/data state machine until a guest actually writes
> `0x3C0` in a way that matters (BaK/oracle do not — they let the BIOS program the palette via INT
> 10h, `src/devices/vga.zig:128-133`). The field defaults `true` (power-on index phase). If/when
> `0x3C0` is modeled, this field is exactly the latch it needs — no rework. The unmodeled `0x3C0`
> attribute-controller **WRITE** path must be a **loud flag — an assert or an explicit
> "not implemented" comment, NEVER a silent no-op** — matching the codebase's inert-register /
> assert-don't-fake discipline (`src/devices/pit.zig:260` asserts on the unimplemented BCD bit rather
> than silently treating it as binary).

If the human prefers to defer even the field: the `0x3DA` read can be a pure derived read with **no**
state mutation, and the flip-flop is added with the `0x3C0` work later. The field costs 1 byte of
snapshot and makes the side effect faithful from day one — recommended, but a clean either/or for the
human (see §6 Q3).

### 3.5 Port wiring

In `Vga`:
- Add `cycles: ?*const u64 = null` back-pointer (mirror `Pit.cycles`, `src/devices/pit.zig:146`),
  with a private `cyclesNow()` helper (mirror `src/devices/pit.zig:154-156`).
- Add `attr_flip_flop_is_index: bool = true` (D-RT3).
- Add a `statusReg1(self) u8` method computing §3.1/§3.3, plus the flip-flop reset, and call it from
  a new `0x3DA`/`0x3BA` arm in `portIn8` (`src/devices/vga.zig:266-276`). `portIn8` is non-`const`
  already, so the flip-flop mutation is allowed there.
- `portOut8` for `0x3DA`/`0x3BA`: **drop** (write-only- to-nothing; the real status register is
  read-only — spice86 doc: "Do not write to this register"). The `else => {}` arm already drops.

In `machine.wire()` (`src/machine/machine.zig`):
- After the existing VGA port registrations (`:222-224`), add
  `_ = self.bus.registerPort(0x3DA, self.vga.portHandler());` and
  `_ = self.bus.registerPort(0x3BA, self.vga.portHandler());`.
- In the back-pointer block, add `self.vga.cycles = &self.cpu.st.cycles;` (alongside the speaker's,
  `:240`). Re-bound on restore exactly like the PIT/speaker pointers.

**Registration order matters for snapshot replay** (`src/bus/bus.zig:910-916`): append the two new
ports *after* the existing VGA registrations so handler-ID assignment stays stable across the
snapshot/restore replay. New ports at the end of the VGA block is order-safe.

**Mono alias (`0x3BA`):** real hardware routes status to `0x3BA` when misc-output bit 0 = 0 (mono)
and `0x3DA` when 1 (colour) — dosbox switches the active base on the `0x3C2` write
(`vga_misc.cpp:71-90`). zdos's VGA-only mode-13h target is always colour, so registering **both**
ports to the same handler is faithful and simpler (a mono guest reading `0x3BA` gets the same correct
status). No misc-output-driven re-routing needed for v1; document it.

---

## 4. Determinism & snapshot analysis

- **Bits are derived, not stored.** `statusReg1` reads `cpu.st.cycles` through the back-pointer and
  computes via integer `%`/`/` — a pure function of the cycle counter and the comptime constants.
  No host time, no float, no RNG, no scheduler dependence. Satisfies CLAUDE #2/#3 and the handler
  purity contract (`src/bus/bus.zig:26-30`). Same as `Pit.liveCounter`.
- **Phase anchored at cycle 0** (`now % FRAME_CYCLES`) → reset-stable and restore-stable with no new
  state (snapshot restores `cpu.st.cycles`, so `into_frame` is identical post-restore).
- **One new mutable field:** `attr_flip_flop_is_index` (D-RT3). It IS guest-visible and IS mutated by
  the `0x3DA` read, so it **must go in `Vga.Snapshot`** (`src/devices/vga.zig:302-334`) and be reset
  to `true` in `Vga.reset` (`:115-125`). Add it to `snapshot`/`restore` (`:313-334`). The `cycles`
  back-pointer is NOT snapshotted (re-bound by the machine on restore, like PIT/speaker).
- **Peek path is unaffected:** the debugger peek path never routes through device port reads (only
  memory `peek8`), so an inspect of `0x3DA` is not a thing — port reads are not peekable. The derived
  status thus can't perturb `machine.snapshot()` via inspection (CLAUDE #5/#6 preserved).
- **Cycle ledger: no hole.** A `0x3DA` `in` is charged by the CPU's `IN` instruction cost, exactly
  like the DAC ports today (`src/devices/vga.zig:31-36`); the handler adds zero cycles. No
  host-serviced trap, no synthetic-cost question. CLAUDE #1 holds with no new ledger entry.

---

## 5. Test strategy

### 5.1 Device unit tests (`src/devices/vga_test.zig`)

Mirror the existing direct-port style (`v.out8`/`v.in8`, `src/devices/vga_test.zig:23-42`), but the
retrace tests need a controllable cycle source. Give the test `Vga` a local `u64 cycles` and point
`v.cycles = &cycles` (the test harness analog of `wire`). Then:

1. **bit 3 toggles deterministically.** Set `cycles` to a value with
   `into_frame = scanline 0 * LINE_CYCLES` → bit 3 == 0; set it into `[VRSTART_LINE, VREND_LINE)` →
   bit 3 == 1. Assert exact byte values at hand-computed cycles.
2. **bit 0 (display-enable) duty.** `into_line < HDE_CYCLES` on a display line → bit 0 == 0
   (displaying); `into_line >= HDE_CYCLES` → bit 0 == 1 (hblank); any `scanline >= VDE_LINES` →
   bit 0 == 1 (vblank).
3. **bit 2 always 1** (D-RT2); bits 1,4-7 always 0.
4. **Attribute flip-flop reset** (D-RT3): set `attr_flip_flop_is_index = false`, read `0x3DA`, assert
   it is now `true`.
5. **0x3BA mono alias** returns the same byte as `0x3DA` at the same cycle.
6. **Pure-function check:** two reads at the *same* `cycles` return the same byte (the only mutation
   is the flip-flop, which is idempotent at `true`).

### 5.2 Determinism regression (the core gate)

A machine-level test must exercise **both** poll shapes and prove byte-identity, not match an
external golden.

**Shape A — wide bit-3 vertical-retrace poll** (`while(in&8); while(!(in&8));`, the §1 frame-sync
pattern): run a tiny guest for a bounded cycle budget and assert (a) the loop **terminates** — both
the `jnz` and the `jz` fall through, reaching a sentinel write, **not** the cycle cap.

**Shape B — narrow bit-0 Borland-`putch`-style poll** (`in al,0x3DA; ror al,1; jc $-5`): assert it
also **terminates** (reaches a sentinel, not the cycle cap) — bit 0 toggles between display/blank, so
the `jc` eventually falls through.

**Two-run byte-identity (the core assertion, NOT an external golden):** run the *same* program on
two fresh machines and assert the **cycle at which bit 3 first transitions** is identical AND the
final machine state is byte-identical across the two runs (mirror
`tests/blackbox/keyecho_test.zig:86-106`'s two-process determinism assertion, and the existing
`src/machine/determinism_test.zig`). Do **not** compare against a dosbox/spice86 capture — their
retrace timing is not a deterministic golden (see §5.4 and the oracle-non-determinism-boundary note).

**Window-width safety assertion (comptime or test).** The polled status windows must be **much
wider** than the worst-case cycles-per-poll-iteration, or a poll could step *over* a window and never
observe the transition — re-introducing an infinite loop. Assert:
- bit-3 retrace window = `(VREND_LINE − VRSTART_LINE) × LINE_CYCLES = 2 × 454 = 908` cycles, and
- the bit-0 active span (`HDE_CYCLES = 181` cycles) and the bit-0 blank span (`LINE_CYCLES − HDE_CYCLES = 273` cycles)

are each ≫ the worst-case cycles-per-poll-iteration. **Dependency to flag:** the per-instruction
cost is the deferred PRM-fidelity pass (`src/cpu/cycles.zig:81-86`, currently a flat `FLAT_BASE = 4`).
If that pass raises per-instruction costs, a poll iteration could grow until it exceeds the narrowest
window (the 181-cycle bit-0 active span). The safety assertion must encode this margin so the future
cost pass can't silently shrink a window below the poll rate and reintroduce the hang.

### 5.3 Black-box: KEYECHO with real `putch()` — THE acceptance gate

**Getting `examples/dos-src/KEYECHO.C` to run end-to-end with the real Borland `putch()` is THE
acceptance gate for this feature.** KEYECHO presently uses a `bdos(2,...)` workaround because
Borland's direct-video `putch()` (the snow-avoidance path that polls `0x3DA` and `ror`s bit 0 into
carry) hangs on the stuck `0xFF` status. After this change:

1. Switch KEYECHO from its `bdos(2,...)` workaround **back to the real `putch()`** echo path.
2. Recompile via `tools/bcc.sh`.
3. Run the black-box test (`tests/blackbox/keyecho_test.zig`) and confirm it **passes**: keys are
   echoed, **ESC terminates**, the guest no longer hangs, and CON output is byte-identical across two
   processes.

This is the end-to-end proof that the whole class of retrace-polling DOS graphics software is
unblocked. State it plainly: getting KEYECHO with real `putch()` to run end-to-end is THE acceptance
gate for this feature.

### 5.4 Oracle-determinism boundary (note, not a golden)

**dosbox-x cannot produce a deterministic golden for "the cycle at which the Nth retrace is
observed."** Its retrace rides on `PIC_FullIndex()`, which mixes `PIC_Ticks` (emulated ms) with the
`CycleMax/CycleLeft` *budget* state — that budget depends on the host cycle-throttling and frame
pacing, so the absolute retrace phase smears across launches (the same "hole/smear" CLAUDE.md cites
for cross-trap cycle counts). spice86 is similar and additionally injects `_jitter` into its clock.
**Therefore zdos defines its OWN deterministic retrace semantics** (the cycle-0-anchored model in
§3.1) and **documents it as an oracle-non-determinism boundary** — exactly like the existing entries
in `plans/io-oracle.md:172-176`, `:396-400`, the PIT ch2-OUT caveat
(`src/devices/pit.zig:224-227`), and the memory note `oracle-non-determinism-boundaries.md`. **Action:
add a line to `plans/io-oracle.md` §1.5 and the memory note** stating the device now answers `0x3DA`
from the cycle counter for *internal* determinism, and that the value is **never** a cross-emulator
golden. Update the now-stale `src/devices/vga.zig:24-27` comment to reflect "modeled at the device
layer (cycle-derived), excluded from goldens."

### 5.5 Determinism grep-gate coverage (float / host-clock-free)

The float / host-clock grep gate in `src/devices/pit_test.zig:53-58` currently embeds only
`pic.zig`/`pit.zig`/`keyboard.zig`/`devices.zig` — **`vga.zig` is NOT covered.** This new
integer-timing code is exactly what the gate exists to protect (the temptation to write an `f64`
"70.086 Hz" is real — both reference emulators use `double`/`fmod`). **Action: add
`@embedFile("vga.zig")` to that gate's `sources` array** so the retrace constants stay
float / `std.time` / RNG-free.

---

## 6. Phased checklist

Each box ≈ one focused commit; gates (`zig build test`) stay green throughout.

- [ ] **P1 — `timing` import + timing constants + comptime pin.** `vga.zig` imports only `std`+`bus`
      today; add `const timing = @import("timing");` (the `timing` module is already wired into
      `devices_mod` in `build.zig:68`, as `speaker.zig:48` does) — without it the constants won't
      compile. Then add the mode-13h timing constants as `pub const` (`FRAME_CYCLES`, `LINE_CYCLES`,
      `HDE_CYCLES`, `HTOTAL_DOTS`, `VTOTAL_LINES`, `HDE_DOTS`, `VDE_LINES`, `VRSTART_LINE`,
      `VREND_LINE`, `DOT_CLOCK_HZ`) to `src/devices/vga.zig` with the `comptime` block that pins
      `FRAME_CYCLES == 204_293` / `LINE_CYCLES == 454` / `HDE_CYCLES == 181` against the canonical
      ~70.086 Hz target (mirror `src/abi/timing.zig:45-50`). No behaviour change yet; unit-test the
      constants resolve to 70.086 Hz and read via `devices.Vga.FRAME_CYCLES`.
- [ ] **P2 — VGA cycle back-pointer.** Add `cycles: ?*const u64` + `cyclesNow()` to `Vga`
      (`src/devices/vga.zig`, mirror `src/devices/pit.zig:146,154-156`); wire
      `self.vga.cycles = &self.cpu.st.cycles;` in `machine.wire()` near `src/machine/machine.zig:240`.
      Re-bound on restore (it already is, via re-`wire`). No port change yet.
- [ ] **P3 — `statusReg1` + 0x3DA/0x3BA read.** Implement `statusReg1()` (§3.1/§3.3) and add the
      `0x3DA`/`0x3BA` arms to `Vga.portIn8` (`src/devices/vga.zig:266-276`); register both ports in
      `machine.wire()` after `:224`. Add the §5.1 device unit tests (bits, duty, alias, purity).
- [ ] **P4 — Attribute flip-flop field (D-RT3).** Add `attr_flip_flop_is_index: bool = true`; set it
      `true` on the `0x3DA`/`0x3BA` read; add to `Vga.reset`, `Vga.Snapshot`, `snapshot`/`restore`
      (`src/devices/vga.zig:115-125,302-334`). Unit-test the reset side effect + snapshot round-trip.
      Add a `// TODO/flag` that the `0x3C0` write path is not yet modeled (assert-or-document).
- [ ] **P5 — Determinism regression + grep-gate.** Machine-level test (§5.2): **Shape A** (wide bit-3
      retrace poll) AND **Shape B** (narrow bit-0 `in al,0x3DA; ror al,1; jc $-5`) both **terminate**
      (reach a sentinel, not the cycle cap); assert **two-run byte-identity** of the first bit-3
      transition cycle and final state (NOT an external golden), mirroring
      `tests/blackbox/keyecho_test.zig:86-106` (`src/machine/determinism_test.zig` or a new
      `vga_retrace_test.zig`). Add the **window-width safety assertion** (§5.2) flagging the
      dependency on the deferred PRM cost pass (`src/cpu/cycles.zig:81-86`). **Also add
      `@embedFile("vga.zig")` to the determinism grep-gate `sources` array
      (`src/devices/pit_test.zig:53-58`)** — vga.zig is not currently covered (§5.5).
- [ ] **P6 — KEYECHO `putch` black-box (THE acceptance gate).** Getting `examples/dos-src/KEYECHO.C`
      to run end-to-end with the **REAL Borland `putch()`** (the snow-avoidance path that polls
      `0x3DA` and currently hangs) **is THE acceptance gate for this feature.** Switch KEYECHO from its
      `bdos(2,...)` workaround back to real `putch()`, recompile via `tools/bcc.sh`, and confirm the
      black-box test passes: keys echoed, ESC terminates, no hang, byte-identical CON output across
      two processes (`tests/blackbox/keyecho_test.zig`).
- [ ] **P7 — Docs / oracle boundary.** Update the stale `src/devices/vga.zig:24-27` scope note; add
      the 0x3DA cycle-derived / not-a-golden line to `plans/io-oracle.md` §1.5 and to the
      `oracle-non-determinism-boundaries` memory note. Flip the ROADMAP backlog item
      (`plans/ROADMAP.md:24`) to done.

---

## 7. Risks / open questions for the human

1. **Q1 — CRTC fidelity: fixed duty cycle vs programmable.** This plan pins mode-13h/text 70 Hz as
   fixed constants (D-RT1) and does NOT read the CRTC registers. This is faithful for BaK/oracle
   (mode 13h only, retrace excluded from goldens) and trivially deterministic. **Risk:** a future
   guest that reprograms the CRTC totals (Mode-X, a custom tweak) would get the wrong duty cycle.
   The code is structured to slot a per-mode table later. **Confirm v1 only needs mode 13h + text.**
   (`plans/io-oracle.md:393-399` already flags that a BaK recon pass hasn't confirmed mode usage —
   tie this to that gap.)

2. **Q2 — `FRAME_CYCLES` exact value.** Pinned `FRAME_CYCLES = 204_293`
   (`timing.CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ = 14_318_184 * 800 * 449 / 25_175_000`,
   floor division → effective refresh `14_318_184 / 204_293 = 70.086 Hz`, the canonical figure). Mode
   13h is **800 dots/line** (8 dots/char × 100 char-clocks; the BIOS mode table's `htot=100` is in
   *character* units, the 2× source of the v1 error). The §3.2 `comptime` block pins this value plus
   the 70.086 Hz refresh against the canonical target. **Confirm** the pinned value; the tiny offset
   from the textbook 70.086 Hz is invisible to a transition-polling loop and there is no oracle to
   match.

3. **Q3 — Attribute flip-flop scope.** Recommend adding the 1-byte `attr_flip_flop_is_index` field
   now (faithful side effect, snapshot-stable, zero rework when `0x3C0` lands) without building the
   full `0x3C0` AC state machine (no guest needs it yet). **Alternative:** pure derived read with no
   mutation, defer the flip-flop entirely to the future `0x3C0` work. **Pick one.**

4. **Q4 — Vertical-retrace IRQ.** Some (rare) software programs the CRTC Vertical Retrace End
   register to fire an IRQ at retrace start (the bit 4/5 enable on `0x3C0`/`0x11` CRTC). BaK-class
   mode-13h software does **not** — it polls. This plan does **not** model the retrace IRQ (it would
   need a new `EventKind` + a scheduler event chain like spice86's). **Flag:** if a target guest is
   later found to rely on the retrace IRQ, that is a separate, larger piece of work (add
   `EventKind.vga_vretrace`, schedule a periodic event at `FRAME_CYCLES`, raise the wired IRQ). Out
   of scope for unblocking the poll-loop class. **Confirm no v1 target needs it.**

5. **Q5 — Text-mode htotal reuse.** v1 reuses mode-13h `FRAME_CYCLES`/`LINE_CYCLES` for text mode
   (same 449-line CRTC family) with only `HDE_DOTS` nominally different. If a text-mode Borland
   `putch` snow-avoid loop is observed needing a distinct hblank duty, add a text constants struct
   (small follow-up). **Acceptable for v1?**
