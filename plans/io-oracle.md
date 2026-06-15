# I/O-phase oracle strategy (VGA / keyboard / sound / mouse)

Status: Band V1 IMPLEMENTED (VGA mode-13h device + INT 10h + binary-blob oracle harness landed;
VGAINIT + VGABIOS reproduce byte-identically — `zig build test-io-oracle` green). USER DECISIONS
D1/D2/D3 RESOLVED (see §7). Remaining bands (V2 palette/fade, K1 keyboard ring, mouse, sound) are
still design. Deliverable for the I/O phase that follows the DOS-layer oracle loop
(`plans/dos-oracle-report.md`, 40-program corpus green via `zig build test-oracle`). This
doc tells the next agent how dosbox-x becomes the truth source for the **non-console-diffable**
devices — graphics, keyboard, sound, mouse — **without abandoning the existing oracle discipline**
(verify-by-readback, double/triple-mint determinism, headless dosbox-x, pinned 1993 epoch, no
faking). It is detailed enough to start building VGA + the first video-oracle band directly.

The validated probe results in §1.3 are the load-bearing part: the proposed VGA capture technique
was run end-to-end under headless dosbox-x in this repo's exact flag set and is byte-deterministic.

---

## 0. The core principle: capture guest-observable DEVICE STATE, never rendered pixels

The console oracle works because DOS console output **is** a guest-observable byte stream the
program produced. The naive extension — screenshot the framebuffer — breaks every invariant we
care about:

- Rendered/scaled pixels depend on dosbox-x's scaler, aspect correction, output backend, and
  draw-timing — none of which a cycle-reproducible emulator should assert, and several of which
  are explicitly disabled in our headless flags (`scaler=none`, `aspect=false`).
- A PNG of the screen tests dosbox-x's *renderer*, not the *machine state* zdos must reproduce.

So the oracle captures the **device state that rendering is a pure function of**, read back by a
real guest program through the same architectural surfaces a game uses:

| Modality | Guest-observable state captured (the golden) |
| --- | --- |
| VGA | VRAM bytes (A000:0000…) + DAC palette (ports 0x3C7/0x3C9) + key CRTC/SEQ/GFX/ATTR regs + BDA video state |
| Keyboard | INT 16h dequeue/peek/shift-flag results over a program-seeded BDA ring; later, INT 09h scancode→ASCII translation table |
| Sound | Ordered register-write trace (PIT ch2 ports 0x42/0x43/0x61; OPL ports 0x388/0x389) and read-back device state — **not** synthesized PCM/FM samples (deferred) |
| Mouse | INT 33h driver state (position/buttons/visibility/handler ptr) over scripted motion — already modeled in `src/dos/int33.zig` |

This reuses ~100% of the existing oracle infrastructure: a guest program reads back the device
state and writes it to a file with ordinary DOS file I/O, which `tools/oracle.sh` already captures.
The only extension needed is a **binary-blob golden variant** (today's golden is text:
`exit_code:` + CON bytes; device blobs are raw binary).

---

## 1. VGA / video — the lead modality

### 1.1 Modality and golden format

A BC3.1 program sets a video mode, draws (via INT 10h services and/or direct VRAM writes), then
**reads back** the guest-observable VGA state and writes a single binary blob via `fwrite`/`fputc`.
That blob is the golden; zdos must reproduce it byte-identically offline.

Recommended self-describing blob layout (little-endian, fixed offsets — a v1 "VGA state record"):

```
offset  size   field
0x00    4      magic  "VGA1"
0x04    1      bda_video_mode      (BDA 0040:0049, & 0x7F)
0x05    1      reserved (0)
0x06    2      vram_len            (e.g. 0xFA00 = 64000 for mode 13h)
0x08    N      vram bytes          (read back from A000:0000, length vram_len)
...     768    dac_palette         (256 entries x 3 bytes R,G,B, each 0..63 — 6-bit DAC)
...     K      register snapshot   (a fixed, documented list of CRTC/SEQ/GFX/ATTR/misc bytes)
```

The register snapshot for v1 mode-13h can be minimal (see §1.4). VRAM may be captured in full
(64000 bytes) or as a hash + a few sampled spans; **full VRAM is preferred** — it is the exact
deterministic artifact and keeps the golden trivially diffable. 64000 bytes per golden is fine
(comparable to the CPU conformance vectors already vendored).

A program that only wants to assert palette + mode + a handful of pixels (a small "smoke" band)
can emit a shorter blob; the magic + length fields make blobs self-describing so the harness can
parse either.

### 1.2 Capture mechanism (reuse `tools/oracle.sh`, add a binary path)

The existing redirect trick (`PROG.EXE > OUT.TXT`) captures **stdout text**. A VGA program instead
writes a **named binary file** (`VGAP.BIN`) directly with `fopen(...,"wb")`. So the oracle needs to:

1. run the program (no stdout redirect needed — the program writes its own file), and
2. copy `<PROG>.BIN` off the mounted C: drive as the golden `<STEM>.vga` (or `.io`) sidecar.

Two integration options:

- **Preferred: a new `tools/oracle-io.sh`** dedicated to binary device blobs. It reuses the exact
  headless invocation from `tools/oracle.sh` / `tools/bcc.sh` (`-silent -fastlaunch -nogui -exit`
  + the device-off `-set` list + `xms=false`), runs `PROG.EXE`, then copies the program-produced
  `OUT.BIN` to the committed `<STEM>.vga`. It still also captures the exit code (the program can
  exit non-zero on a self-check failure so a broken mint is caught immediately), reusing the
  errorlevel-ladder logic. Keeping it a separate script avoids overloading `oracle.sh`'s
  text-golden contract.
- Alternative: teach `oracle.sh` to *also* grab a `<STEM>.bin` if the program produced one. This
  couples two golden formats in one script; the separate script is cleaner.

**Pin one extra `-set` for video:** the oracle must fix the VGA card so register read-backs are
stable. dosbox-x defaults `machine=svga_s3` (`src/dosbox.cpp:1755`). **USER DECISION D1 — RESOLVED:
`machine=vgaonly`** (plain IBM VGA, no S3): it matches BaK's plain-VGA scope and shrinks the
register surface zdos's VGA device must reproduce. PINNED in `tools/oracle-io.sh`
(`-set "machine=vgaonly"`).

The DAC is 6-bit by default (`vga.dac.bits=6`, `src/hardware/vga_dac.cpp:444`), so palette
read-backs are 0..63 — zdos's VGA DAC must store/return 6-bit values, not scale to 8-bit.

### 1.3 VALIDATED — the technique works headless and is deterministic

A throwaway probe (`VGAP.C`, now removed) was compiled with `tools/bcc.sh`'s recipe and run under
the exact headless flag set. It:

1. set mode 13h via INT 10h AX=0013,
2. drew pixel (10,20)=5 via INT 10h AH=0C,
3. wrote VRAM offset 100 = 0x2A directly through `MK_FP(0xA000,0)`,
4. set DAC entries 5 and 6 via INT 10h AX=1010,
5. **read back** the DAC via `outp(0x3C7, idx)` then three `inp(0x3C9)` per entry,
6. read the BDA mode byte at 0040:0049,
7. wrote all of it to `VGAP.BIN`.

Resulting 9-byte blob (mode, px1, px2, pal5.rgb, pal6.rgb):

```
13 05 2a 3f 00 15 10 20 30
```

— mode 0x13, pixel=5, direct-write=0x2A, DAC entry 5 = (0x3F,0x00,0x15), entry 6 = (0x10,0x20,0x30).
Every value is exactly what the program wrote: the guest **can** read A000:0000 back, read the DAC
through ports, read the BDA, and write a file — all headless, VGA enabled by default, no display.

**Determinism: triple-mint byte-identical** (same SHA-256 across three independent dosbox-x runs).
This is the same double/triple-mint discipline the DOS bands use, and it passed.

This is the central validation: the VRAM+palette-readback oracle is real, headless, and
deterministic. No host-display, scaler, or wall-clock dependency entered the golden.

### 1.4 What BaK actually needs (the right first target)

No BaK reconnaissance dirs exist in this repo yet (no `betrayal-at-krondor/`, no `c-recon`), so the
scope below is from BaK's documented hardware profile (CLAUDE.md: "VGA, mode 13h") and the standard
1993 VGA-game pattern:

- **Mode 13h (320x200x256, linear at A000:0000, 64000 bytes)** — the primary and almost certainly
  only graphics mode BaK uses. mode 13h is the unchained-free linear MCGA/VGA mode; one byte = one
  pixel = one palette index. This is the first and main VGA target.
- **DAC palette programming** via INT 10h AH=10 (AL=10 single, AL=12 block) and/or direct port
  writes (0x3C8 write index, 0x3C9 data). BaK does heavy palette work (fades, day/night). The
  BIOS palette path is a pure port-write sequence (`int10_pal.cpp:219`:
  write 0x3C8=index, then 3x 0x3C9=R,G,B), which is exactly the contract zdos's VGA device exposes.
- **Direct VRAM writes** (the game blits its own buffers into A000) — must round-trip byte-exact.
- **INT 10h AH=00 set mode** (already stubs the BDA + emits misc-output port write in
  `src/bios/int10.zig:17`), **AH=0F get mode**, **AH=0C/0D put/get pixel**, **AH=02/03 cursor**
  (text only; minor).
- Likely **NOT** needed for v1: planar EGA modes (0x0D/0x0E/0x10/0x12), Mode-X (unchained), VESA
  SVGA, hardware scrolling, split-screen, smooth-scroll CRTC tricks. Confirm by recon when a BaK
  EXE is available; until then build mode 13h only and flag anything else as out of scope.

**Minimal VGA feature set for BaK v1:** mode 13h linear framebuffer (64 KB window A000–AFFF) +
256-entry 6-bit DAC (read/write via ports 0x3C8/0x3C9/0x3C7) + the INT 10h services above +
the BDA video fields. The CRTC/SEQ/GFX/ATTR register file can be present-but-mostly-inert for
mode 13h (the BIOS sets it once at mode-set; the game doesn't reprogram it). The register snapshot
in the golden can therefore be a short fixed list (misc output 0x3CC, a few SEQ/CRTC bytes) just to
prove mode-set wrote the right registers — not a full SVGA dump.

### 1.5 Determinism statement (VGA)

Byte-reproducible. The golden is a function only of: (a) the guest instruction stream the program
runs, (b) the deterministic mode-set the BIOS performs, (c) the DAC/VRAM writes the program issues,
all read back through architectural surfaces. No host display, scaler, aspect, draw-timing, or wall
clock contributes. **Proven by triple-mint (§1.3).** zdos reproduces it offline because mode 13h
VRAM is one fixed 64 KB block (CLAUDE.md memory discipline) and the DAC is a 256x3 array of 6-bit
values — both zero-initialized deterministically at device reset (CLAUDE #5), then overwritten only
by guest writes.

The one host-dependent VGA value to **exclude** from any golden: anything derived from retrace/scan
timing (the input-status register 0x3DA retrace bits, current scanline). A program must never assert
those — they are wall-clock-ish in dosbox-x. **zdos now models 0x3DA / 0x3BA (Input Status Register
#1)** at the device layer: the vertical-retrace (bit 3) + display-enable (bit 0) status is derived
from the cycle counter (emulated time = f(cycles), CLAUDE #2) via integer math — see
`src/devices/vga.zig` `statusReg1` and `plans/vga-retrace.md`. So the bits are deterministic *in
zdos* (a retrace-poll loop terminates reproducibly), but they are NOT a faithful cross-emulator
oracle and must stay out of the blob.

**Text-buffer content IS a valid golden (recommended follow-up band).** Unlike the retrace bits, the
**text page B800:0000 cell content after a deterministic INT 10h sequence is a faithful cross-emulator
golden** — it is pure guest-observable device state, the same VRAM-readback discipline already proven
for mode 13h (§1.2/§1.3). A text-oracle band: a BC3.1 program issues a fixed INT 10h text sequence
(set mode 3, teletype / write-char / scroll a known pattern), reads back the first `cols*rows*2` B800
cells, and `fwrite`s them as a binary blob; mint the golden under headless dosbox-x and zdos reproduces
it byte-identically offline (the cells are a pure function of the INT 10h calls). This is the K1/V-band
analog for text — the text page + INT 10h text services landed (`plans/text-mode-video.md`), so this is
now buildable. **The one value to exclude: cursor *blink* phase (not modeled); the cursor *position*
(BDA) IS a valid golden.** (Today `VIDTEXT.EXE` already asserts the teletyped cells + advanced cursor
via AH=08 over the CON-text golden; a binary B800-blob band is the natural next step.)

---

## 2. Keyboard

### 2.1 Two distinct layers, two oracles

The keyboard splits into two architectural layers, and conflating them is the trap:

- **DOS handle-0 / CON stdin** — already covered. The existing `.in` sidecar + dosbox-x
  `PROG.EXE < IN.TXT` feeds DOS handle 0; zdos preloads the identical bytes via
  `con.loadInput` (`oracle_test.zig:312`, `devices.zig:109`). READLINE/GETCH/STDSTAT/CSCANF/CTRLC
  already pass this way. **Nothing new needed here.**
- **BIOS INT 16h / BDA keyboard ring** — NOT reached by stdin redirection. dosbox-x's redirected
  stdin is a `LocalFile`; it does not push scancodes into the BIOS keyboard buffer
  (`BIOS_AddKeyToBuffer`, `bios_keyboard.cpp:370`). A game polling INT 16h AH=01/AH=00 reads the
  BDA ring, a different surface. zdos's `src/bios/int16.zig` already drains the BDA ring via
  `bda.kbDequeue/kbPeek/kbShiftFlags`.

### 2.2 The deterministic INT 16h oracle (no real key injection)

dosbox-x's `AUTOTYPE` command injects keys but on **timed intervals** (`dos_programs.cpp:8222`) —
non-deterministic for a cycle-reproducible oracle, so it is rejected.

The faithful, deterministic oracle for the INT 16h layer is a **program-seeded ring**: the BC3.1
program writes a known sequence of `scancode:ascii` words **directly into the BDA keyboard ring**
(0040:001E…, advancing the tail at 0040:001C exactly as the IRQ1 handler would), then reads them
back through INT 16h (AH=00 read, AH=01 peek, AH=02 shift flags) and writes the (scancode,ascii)
pairs it observed + the ZF/empty results to a file. This tests **exactly** the INT 16h dequeue /
peek / shift-flag / empty-ring logic — the part zdos owns — with zero host-input dependence. Both
dosbox-x and zdos run the identical guest code over the identical seeded ring, so the goldens match
and are deterministic by construction (the program is the sole source of the keys).

This is the analogue of the EMS/VECTORS bands: the program drives the API surface end-to-end and
prints only oracle-able results. Golden format: text (reuse `oracle.sh` as-is) — lines of
`scan=NN ascii=NN` plus peek/empty booleans.

### 2.3 The INT 09h scancode→ASCII translation oracle (later band)

A heavier, still-deterministic oracle: drive raw scancodes through the hardware path. dosbox-x
maps scancode → (normal/shift/control/alt) ASCII in `scan_to_scanascii` (`bios_keyboard.cpp:795`).
zdos's INT 09h handler must reproduce that table. The oracle is a program that — for a fixed list
of scancodes with fixed shift-state — looks up what the BIOS produced and records the resulting
ring words. **Injection mechanism is the open problem here:** from inside the guest we can't fire
IRQ1. Options for a future band: (a) a host-side scripted scancode stream fed into zdos's keyboard
device at deterministic cycles (zdos side), matched against a *table extracted from dosbox-x's
`scan_to_scanascii` source* as the golden (treat the dosbox-x source table as the truth, like a
conformance vector), or (b) defer INT 09h-level translation until a BaK recon shows the game uses
raw scancodes rather than INT 16h cooked codes. **Recommendation: defer to a later band; BaK polls
INT 16h** (noted in `int16.zig:21`), so INT 16h cooked-code coverage (§2.2) is the v1 keyboard
contract. The scancode-table oracle becomes a "translation conformance" band reading the table
straight from dosbox-x source.

### 2.4 Determinism statement (keyboard)

INT 16h oracle: fully deterministic — the program seeds and reads its own ring; no host input. DOS
stdin: already proven (existing bands). INT 09h table: deterministic given a scripted scancode
stream at fixed cycles, with the golden sourced from dosbox-x's static translation table.

---

## 3. Sound

### 3.1 v1 contract: register-write TRACE + read-back, NOT synthesized samples

BaK uses PC-speaker (PIT channel 2) and AdLib/OPL2 FM (and optionally Sound Blaster). The
guest-observable, deterministic truth for all of these is the **ordered sequence of port writes**
the game issues, plus any device state read back:

- **PC speaker / PIT ch2:** ports 0x42 (ch2 counter), 0x43 (mode/command), 0x61 (speaker gate
  bits 0–1). Programming a tone is `out 0x43, mode; out 0x42, lo; out 0x42, hi; out 0x61, |3`.
  The derived frequency is a pure function of the loaded divisor (1193182 / divisor). zdos's PIT
  (`src/devices/pit.zig`) already models the counter; the oracle reads back the ch2 latched count
  and the speaker gate state.
- **AdLib / OPL2:** ports 0x388 (register select), 0x389 (data). A music driver writes a long,
  deterministic stream of (register, value) pairs. The OPL status port (0x388 read) returns timer
  flags — host-timer-ish, **exclude from the golden**.

**The v1 sound oracle is a register-write trace**, not audio. Two viable forms:

- **(a) Read-back form (preferred for v1, reuses oracle.sh text golden):** the program programs the
  device, then reads back what is guest-readable (PIT ch2 latched counter via the latch command +
  two 0x42 reads; the speaker gate bits via `inp(0x61)`) and prints the derived frequency / gate
  state. AdLib registers are write-only on real hardware, so for OPL the program can only assert
  the *status port* and its own computed register stream — which leads to form (b).
- **(b) Trace form (for OPL, a new sidecar):** the canonical golden is the **expected (port,value)
  write sequence** the driver emits. dosbox-x is not needed to *produce* this if the program's
  writes are deterministic from its own logic — but to make dosbox-x the oracle, capture the writes
  dosbox-x's OPL emitter *received*. dosbox-x has no headless port-trace dump, so the faithful path
  is: zdos records the (cycle, port, value) writes its CPU issues to 0x388/0x389/0x42/0x43/0x61 and
  asserts that trace is **stable run-to-run** (a determinism golden), while a *small* read-back
  band (form a) proves the PIT divisor math against dosbox-x. Pure FM synthesis fidelity (the
  actual samples) is **out of v1 scope**.

### 3.2 Why samples are deferred

Sample-accurate FM/PCM output requires bit-exact OPL/DAC emulation (dbopl/nukedopl,
`src/hardware/dbopl.cpp` etc.) and a defined sample-clock cadence — a large, separate workstream.
It is **deferrable for BaK v1**: the game is playable and deterministic with the register-write
contract honored; nothing in the determinism prime directive requires synthesized audio (CLAUDE.md
lists sound as "deferrable"). **USER DECISION D2** (§7): is sample-accurate audio in v1 scope?
Recommendation: NO — v1 sound contract is the register-write trace + PIT read-back oracle; full FM
synthesis is a post-v1 band with its own sample-hash oracle.

### 3.3 Determinism statement (sound)

Register-write trace: deterministic — the writes are a pure function of the guest instruction
stream and the (deterministic) PIT/OPL state, charged through the cycle ledger with synthetic costs
(CLAUDE hard-constraint #1). The only host-dependent reads (OPL status timer flags, PIT
out-pin/0x61 bit-5 toggle, which dosbox-x derives from emulated time) are **excluded** from goldens
or, where zdos derives them from the cycle counter, asserted only run-to-run within zdos.

---

## 4. Mouse (INT 33h)

Already modeled in `src/dos/int33.zig` (host-serviced trap; position/buttons/visibility/handler
far-ptr; `injectMotion` scripted seam). The oracle is the **same pattern as keyboard §2.2**: a
program calls INT 33h services (AX=0000 reset/present, AX=0003 get pos+buttons, AX=0004 set pos,
AX=000C/0014 handler install/swap) over a **scripted motion script** and prints the driver state it
observed. Scripted mouse events are a deterministic external-input seam (`int33.zig:77`), exactly
analogous to the `.in` keyboard stream — propose a `<STEM>.mouse` sidecar of `(dx,dy,buttons)`
records the oracle and zdos both consume.

dosbox-x's INT 33h is its own emulated driver, so its read-backs of position/buttons over a scripted
motion stream are a valid golden, deterministic if the motion is scripted (not real mouse). For v1,
mouse position semantics (mickeys, sensitivity, range clamping) need a recon pass against
`src/ints/mouse.cpp` to pin the exact arithmetic; the get/set/handler round-trip (what int33.zig
already does) is the first band. Golden format: text, reuse `oracle.sh`.

**Determinism:** deterministic given a scripted motion stream; no host mouse. Matches the existing
scripted-input discipline.

---

## 5. Test-harness integration (extending `oracle_test.zig`)

The existing `src/dos/oracle_test.zig` parses a **text** golden (`exit_code:` + CON bytes) and
diffs CON output. Two additions:

1. **Binary-blob assertions (VGA, sound-trace).** Add a parallel corpus list (e.g. `VGA_PASSING`)
   and a `runOnZdosVga` that boots the machine, runs the program, then — instead of (or in addition
   to) reading CON output — reads the **device blob the guest program wrote through zdos's own VFS**
   (the program does `fopen("OUT.BIN","wb")`, which lands in the zdos host-FS VFS just like any
   corpus file) and `expectEqualSlices(u8, golden_blob, zdos_blob)`. This requires no new capture
   surface in zdos: the program reads VGA state back through the *same ports/VRAM* zdos implements,
   and writes the blob through the *same DOS file I/O* already tested. The golden `<STEM>.vga` is
   the committed dosbox-x mint. This is the cleanest integration — it tests the VGA device by having
   a real program observe it, end to end, with zero test-only hooks.
   - Cleanup: a VGA program that writes `OUT.BIN` must delete it before exit (corpus hygiene, like
     the file bands) OR the harness reads it from a scratch dir. Prefer: program writes a fixed
     name, harness copies-then-deletes, mirroring `oracle.sh`'s `OUT.TXT` handling.
2. **Text read-back assertions (keyboard INT 16h, mouse, sound read-back).** These need NO new
   harness code — they print oracle-able values to CON and reuse the existing text-golden path. Just
   add the programs to `PASSING` and mint with `oracle.sh`. (INT 16h-seeded-ring, mouse-script, and
   PIT-divisor programs all fit the current harness as-is.)

`build.zig` already wires `examples/dos-src` as the corpus dir (`build.zig:18`) and `test-oracle`
(`build.zig:324`); the VGA blobs and new sidecars live in the same dir. Add a `<STEM>.vga` /
`<STEM>.mouse` to the sidecar reader (`readSidecar` already generalizes by extension,
`oracle_test.zig:332`).

---

## 6. Recommended BUILD ORDER (the next I/O "bands", continuing the loop)

Build the VGA device first (it is the largest BaK dependency and the validated oracle is ready),
then the input layers, then sound last (deferred contract).

**Band V1 — mode 13h framebuffer + the first video oracle.**
- Build `src/devices/vga.zig`: the A000–AFFF 64 KB linear window as one fixed block (memory
  discipline), wired into the bus per-region dispatch; the 256x3 6-bit DAC behind ports
  0x3C8 (write idx), 0x3C9 (data, R/G/B auto-advance), 0x3C7 (read idx) — port semantics per
  `vga_dac.cpp:261/371`. INT 10h AH=00 set mode 13h + AH=0F get mode (already partly stubbed in
  `int10.zig`), AH=0C/0D put/get pixel, AH=10 AL=10/12 DAC set (port-write path per
  `int10_pal.cpp:219`).
- First oracle program **`VGAINIT.C`**: set mode 13h, write a deterministic test pattern into VRAM
  (e.g. `vram[i] = i & 0xFF`), program a known 256-entry palette, read VRAM + DAC + BDA mode back,
  write the `VGA1` blob. Mint `VGAINIT.vga` with `tools/oracle-io.sh`. Assert byte-identical in the
  extended harness. (This is the §1.3 probe, productionized.)
- Second program **`VGABIOS.C`**: exercise INT 10h services specifically (AH=0C put-pixel across a
  span, AH=0D read-back, AH=10 single + block DAC set, AH=0F get-mode), so the BIOS path and the
  direct-port path are both proven against the device.

**Band V2 — palette/fade fidelity.** `VGAPAL.C`: program the DAC via both INT 10h block-set
(AL=12) and raw ports, do a fade-style sequence of overwrites, read back the final palette — the
exact pattern BaK fades use. Confirms 6-bit storage and block semantics.

**Band K1 — INT 16h keyboard ring.** `KBRING.C` (§2.2): seed the BDA ring with known scan:ascii
words, read back via AH=00/01/02, print results. Text golden via `oracle.sh`. No new harness.

(Then, as BaK recon lands: a mouse band `MOUSE1.C` §4, and sound band `SND1.C` §3.1a for PIT
divisor read-back. INT 09h scancode-table and FM synthesis are explicitly later/deferred.)

First three concrete deliverables: **VGAINIT, VGABIOS, KBRING** — the first two stand up the VGA
device against the validated blob oracle; the third extends the input loop to the BIOS keyboard
layer with no harness changes.

---

## 7. Open risks & USER DECISIONS

- **D1 — VGA oracle machine type. RESOLVED: `machine=vgaonly`** (faithful to BaK's plain-VGA scope,
  smaller register surface; no S3). PINNED in `tools/oracle-io.sh` (`-set "machine=vgaonly"`). The
  VGA device (`src/devices/vga.zig`) implements the plain-IBM-VGA mode-13h subset only — the S3
  register surface is never modeled.
- **D2 — Sound sample-accuracy scope for v1. RESOLVED: DEFERRED** — v1 sound is REGISTER-TRACE ONLY
  (no synthesis). `tools/oracle-io.sh` builds/pins nothing for audio; sample-accurate FM/PCM is a
  post-v1 band with its own sample-hash oracle.
- **D3 — VGA mode scope for v1. RESOLVED: MODE 13h ONLY** (320x200x256 linear, A000:0000, 64000
  bytes). No BaK recon performed; mode 13h is the v1 video target. The VGA device + INT 10h
  mode-set/pixel/DAC path are built for 13h only; any other mode records a coherent BDA but is not
  given the full register/VRAM program (flagged, not faked). VRAM goldens are FULL 64000 bytes (the
  exact, trivially-diffable artifact).
- **BaK recon gap.** There is currently **no BaK reconnaissance in the repo** (no
  `betrayal-at-krondor/`, no c-recon). The VGA scope here is from BaK's documented hardware profile,
  not from disassembly. Before locking mode/feature scope beyond mode 13h, a recon pass on a BaK EXE
  is needed to confirm it uses only mode 13h + INT 16h polling + INT 33h mouse and does **not** use
  Mode-X, planar EGA, raw INT 09h scancodes, or VESA. Flag, don't assume.
- **Retrace / status-register timing.** Never put 0x3DA retrace bits, current scanline, OPL/PIT
  timer-flag reads, or any draw-timing value into a cross-emulator golden — they are emulated-time
  derived and not a faithful oracle across emulators. zdos derives them from the cycle counter for
  internal determinism only.

### Later: a rendered-output (PNG/framebuffer-hash) oracle WITHOUT coupling the core

Guest-state fidelity (this doc) is the right v1 contract. Eventually we may want to assert the
*final rendered image* (e.g. to catch a palette/VRAM combination that is byte-correct but visually
wrong, or to validate a future host renderer). Add it as a **pure downstream consumer**:

- zdos's `src/host/` (the optional renderer) takes the deterministic VGA device state (VRAM + DAC)
  and produces a PNG; hash the PNG. This is `src/host/` → consumes machine output (module graph),
  **never** feeding back into emulation timing/ordering (CLAUDE constraint #4).
- The golden is a hash of zdos's *own* render of its *own* deterministic state — a self-consistency
  / regression check, **not** a dosbox-x screenshot diff (which would reintroduce scaler/aspect
  non-determinism). It is layered strictly above the core and can be added any time without touching
  cpu/bus/devices. The device-state oracle remains the source of truth; the PNG hash is a
  convenience view on top.

---

## 8. Summary

- **VGA:** capture VRAM + 6-bit DAC palette + BDA mode + a small register snapshot as a binary blob
  the guest reads back and writes via DOS file I/O. **Validated headless and triple-mint
  byte-identical** in this repo. First and main I/O target; build mode 13h only for BaK v1.
- **Keyboard:** DOS stdin already covered; add an INT 16h-seeded-ring band (deterministic, no real
  injection, text golden); INT 09h scancode-table translation deferred.
- **Sound:** register-write trace + PIT divisor read-back as the v1 contract; synthesized FM/PCM
  samples deferred (D2).
- **Mouse (INT 33h):** scripted-motion sidecar + driver-state read-back; `int33.zig` already fits.
- **Harness:** add binary-blob assertions for VGA (program writes blob through zdos VFS, diff vs
  committed dosbox-x `.vga` mint); text read-back bands need no harness change.
- **First three bands:** VGAINIT, VGABIOS, KBRING.
- **Decisions for the user:** D1 (vgaonly vs svga_s3), D2 (defer sound samples), D3 (full VRAM
  golden). Plus the BaK-recon gap to close before locking video scope beyond mode 13h.
