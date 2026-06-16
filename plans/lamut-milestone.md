# Milestone: run LAMUT.EXE (Mode-Y planar VGA + framebuffer capture)

Run **LAMUT.EXE** — a c-recon (reconstructed-from-disassembly) of Betrayal at Krondor's real VGA
asset-load + blit engine — on zdos, deterministically. LAMUT loads the game's VGA driver overlay
(`Vmcode.ovl`), detects the VGA adapter, sets **VGA Mode-Y** (unchained/planar 256-color, *not*
linear mode 13h), LZW-decompresses the Lamut city image, pushes the palette to the DAC, and
planar-blits the image. This is the first **visual** milestone and the original v1 acceptance
target (`CLAUDE.md` "First target: Betrayal at Krondor").

This pulls two backlog items forward (`plans/ROADMAP.md:30`): *framebuffer/screenshot capture* and
*Mode-Y / unchained planar VGA*.

> Scope honesty: this is a **large** milestone — a whole new VGA subsystem (planar/unchained) plus a
> graphics framebuffer-capture observability surface, gated by unknown CPU instruction coverage in
> the overlay. It is deliberately split into two independently-valuable stages. See
> [Risks / open questions](#risks--open-questions).

---

## Staged acceptance criteria

**Stage 1 — `LAMUT-OK` (console gate).** LAMUT.EXE runs to:

```
LAMUT-OK: adapter=8 296x101
```

observable via `/api/console` (DOS CON stream) or its `result.txt` stdout. This proves: `video_init`
+ adapter-detect + overlay load + the overlay's driver-init + the 100-entry vtable copy + Mode-Y
register program + asset-table load + LZW decode + palette load + the descriptor 296×101 check all
work — **without** requiring pixel-correct output (the blit can write garbage and Stage 1 still
passes, because `main.c` checks return values + descriptor dims, not pixels). This is the near-term
"load LAMUT.EXE" gate and the bulk of the CPU/VGA-port work.

**Stage 2 — visual oracle (framebuffer gate).** Run to a fixed cycle in the post-blit plateau,
capture the rendered framebuffer (planar VRAM de-interleave + 6-bit DAC → 320×200 RGB), and assert
it matches the golden Lamut image (raw-RGBA pixel hash). This proves the planar write path and DAC
are pixel-faithful, and lands the graphics-capture observability surface.

Each stage is a separate gate; Stage 1 does not depend on Stage 2 being green.

---

## Empirical findings so far (the probe)

LAMUT.EXE **already loads and runs on zdos**: the CPU, the DOS MZ loader (`src/dos/loader.zig`), the
Borland C runtime, and file open all work. It executes into
`video_init(8, 0xffff, "vmcode.ovl")` and that returns **adapter = 0**, so `main.c`'s guard fires:

```
LAMUT-FAIL: video_init adapter=0
```

plus Borland's "Null pointer assignment" CRT-epilogue check, exit code 33, at ~56,147 cycles.

`adapter == 0` is returned by `video_detect_adapter` (the spec is
`betrayal-at-krondor/c-recon/staging/src/asm/f_1ac53.asm`). That is **hole #1**: zdos's INT 10h has
no adapter-detect service (`AH=1Ah`), so the detect routine falls through to its `xor al,al` /
`adapter = 0` exit. Everything past `video_init` (Mode-Y, LZW, blit, framebuffer) is downstream and
unverified until the probe gets further — flagged below where that matters.

---

## Investigation summary (the authoritative spec)

### What LAMUT drives
`../bak-scratch-area/work/areas/lzhuf/tests/lamut/main.c` (read in full). The chain, calling **only
real migrated engine functions** and setting only DATA globals (the putpixel/playmus precedent — it
never fabricates a driver / decoded-pixel table):

1. `g_graphics_context.bVideoAutoDetectEnabled = 1;` then
   `adapter = video_init(8, 0xffff, g_szVmcodeOvl)` — mode 8 = VGA Mode-Y path; arg2 `0xffff` is a
   dead slot; arg3 = driver filename. Guard: `adapter == 0 || vtable.pfn_putpixel == NULL` →
   `LAMUT-FAIL`.
2. `record = resblit_load_asset_table("G_LAMUT.BMX", 0)` — opens the loose raw-0x1066 image set,
   reads the 12-byte header (magic `0x1066`, 1 sub-image), allocates a `(count+1)` pointer table +
   10-byte/entry descriptors, reads each record (size/flags/w/h at desc+2..+8) and the LZW payload
   into the **far heap** (`storage_mode 0`). Returns `int*`; `record[0]` = near offset of the first
   descriptor.
3. `palBuf = chunk_load_into_slot("G_LAMUT.PAL")` then `palette_set_active(off, seg)` — opens the
   loose `.PAL`, seeks the per-adapter PAL tag, `alloc_far`s + reads the 768-byte VGA palette, then
   pushes it to the DAC via **renderer vtable slot 20**.
4. `g_graphics_context.wGfxBlitDstPage = g_graphics_context.wVgaFrontPageBase;` — re-points the draw
   page at the *front* page (`0xA000`) so the static blit lands on the displayed page (no page flip
   for a static hold; `video_init`'s epilogue defaults the draw page to `wVgaPage2Base` = back page
   `0xA400`). This is the **front/back page base** distinction Mode-Y needs.
5. `blit_sprite_indirect(record[0], (320-w)/2, (200-h)/2, 0)` — **vtable slot 29** on-blit LZW expand
   + Mode-Y planar write to `wGfxBlitDstPage`. `record[0]+6` = width (296), `+8` = height (101).
6. `restore_text_mode()` (INT 10h AX=0003) → `LAMUT-OK: adapter=%d %dx%d`.

Headless mode (`argc > 1`, the `run.sh` path) skips the 3-second hold (`wait_seconds` via INT 1Ah).

### The run recipe
`../bak-scratch-area/work/areas/lzhuf/tests/lamut/{run.sh,dosbox.sh,assets.txt}`:
- Stages `Vmcode.ovl` + extracts `G_LAMUT.BMX` / `G_LAMUT.PAL` from `Krondor.001` (via the oracle's
  `read_resource_by_scan`).
- `bak_fopen` does a plain `fopen(name)` on disk → loose files open with no archive machinery.
- **`resblit_load_asset_table` rewrites the last char `.BMX`→`.BMx`** and relies on the FS resolving
  it case-insensitively to the staged uppercase file. zdos already does this (see VFS below).
- The DOSBox run is **bounded on time + output size** because of the **INT 6 hazard**: a
  crashing/looping LAMUT (an unimplemented 386 opcode → `#UD`/INT 6) must not fill the disk.

### The c-recon engine spec
- **`video_init`** = `betrayal-at-krondor/c-recon/staging/src/asm/f_1ab04.asm` (`_video_init`, far,
  290 bytes). It: clears gfx-state flags, sets `wScreen_width/height` = 320×200, frees any old
  palette scratch, calls `bios_get_video_mode_bits` (saves BIOS mode), calls **`video_detect_adapter`
  (f_1ac53.asm:84)** → `bVideoAdapter`, and if non-zero, `video_driver_load` (loads the overlay),
  stores `g_pfnVideoDriverInit`, **CALLF [g_pfnVideoDriverInit]** (runs the overlay's init entry),
  `REP MOVSW` copies the overlay's **100-entry vtable** into `g_renderer_vtable` (f_1ab04.asm:113),
  writes `0000:04F0 = DGROUP`, defaults `wGfxBlitSrcPage = wVgaFrontPageBase`,
  `wGfxBlitDstPage = wVgaPage2Base`, allocates the span-table, and issues **INT 10h AX=1130h BH=3**
  (get ROM 8×8 font pointer → `g_font_bitmap_data`, f_1ab04.asm:168-170). Returns the adapter id.
- **`video_detect_adapter`** = `f_1ac53.asm` (**hole #1, the authoritative adapter-detect spec**).
  With `bVideoAutoDetectEnabled = 1` and requested mode = 8 (`g_bRequestedVideoMode`), control
  reaches `L_2bdb` (off 0x48, f_1ac53.asm:88): it issues **`INT 10h AX=1A00h`** (Get Display
  Combination Code / VGA-MCGA detect), then branches on `BL`/`BH` for 7 or 8 (= VGA/PS2 display
  codes). Because the requested mode is non-zero (8), it returns the **requested** id 8 at `L_2bfe`
  (f_1ac53.asm:105-110) — but only if it does **not** fall through to the EGA branch `L_2c0c`. The
  fall-through is taken when `BL`/`BH` are neither 7 nor 8. **So the single thing zdos must do for
  `adapter = 8` is: implement `INT 10h AH=1Ah` returning `AL=0x1A` (function supported), `BL=0x08`
  (active display = VGA color).** Secondary paths (`AH=12h BL=10h` EGA info at `L_2c43`; the
  `0x3D4/0x3D5` CRTC index/data round-trip + `0x3BA` status poll at `L_2c7b`/`L_2cc3`) are **not**
  on the mode-8 auto-detect path, so they are not Stage-1 blockers — but see hole #1b.
- **`video_driver_load`** loads `Vmcode.ovl` as guest code (DOS open/read into the far heap) and
  returns a far ptr to the driver template. Confirm at probe time which INT 21h calls it uses (it is
  ordinary file I/O zdos already supports; flagged for verification).
- **The overlay** = `../betrayal-at-krondor/game/krondor/Vmcode.ovl` — a 100-entry renderer vtable
  whose entries are **the game's real VGA driver code**. Mode-Y setup + the planar blit + the DAC
  palette push run as **guest instructions inside the overlay**. The engine's own VGA helpers
  (e.g. `c-recon/staging/src/asm/f_1ca27.asm` `vga_save_and_setup_gc_sc`) show the exact register
  idiom: `MOV DX,0x3CE; IN AL,DX; ...; OUT DX,AL` (Graphics Controller index/data **with read-back**)
  and `MOV DX,0x3C4; OUT DX,AL` (Sequencer), with `MOV BX,0xA000` / `STOSB` planar VRAM writes. This
  is the SPEC for what the VGA device must model: **the requirement is faithful CPU + VGA-port +
  planar-VRAM emulation, not reimplementing the driver.**

### The oracle (how the frame is captured + compared)
- `../bak-scratch-area/tests/test_lamut_screenshot.py` — the model: launch LAMUT under Spice86
  headless, freeze at an exact emulated cycle (`--StopAfterCycles`), capture one screenshot over MCP,
  assert SHA-256 == `tests/golden/lamut.png`. Notes: the cycle cap (not a wall-clock sleep) fixes the
  frame; LAMUT blits then holds ~3 s (~26M cycles), so any cycle in the post-blit plateau (their
  `15M`) captures the identical static frame. **Caveat it raises:** the golden hashes the PNG
  *container*, stable only because the Skia encoder is pinned — they recommend a **raw-RGBA pixel
  hash** instead. zdos should adopt the raw-pixel hash from the start.
- `../betrayal-at-krondor/tools/lamut-oracle/` — `oracle.py` extracts the assets; the golden frame
  exists as `lamut_0.png` / `.ppm` / `.idx` + `lamut.pal.rgb` (the 768-byte palette). The `.idx` is
  the **palette-indexed** image (296×101 of color indices) — the ground truth that survives any
  DAC-scaling convention. "Plane-aware framebuffer read-back" = de-interleaving the 4 Mode-Y planes
  back to a linear 320×200 index buffer before the palette lookup.

### zdos's current state vs the gap (cited)
- **`src/devices/vga.zig`** models TODAY: linear mode 13h (chained `A0000`, first 64000 bytes,
  `VRAM_PHYS:60`), the 256-entry **6-bit DAC** (ports `0x3C6-0x3C9`, `write3c9:411` / `read3c9:436`),
  misc-output `0x3C2`/`0x3CC` (`portOut8:519`), the cycle-derived `0x3DA/0x3BA` retrace status
  (`statusReg1:476`), and the text pages (`B8000`/`B0000`). It does **NOT** model:
  - **Sequencer** `0x3C4/0x3C5` (incl. the **Map Mask** register, index 0x02 — the per-plane write
    gate) — `portOut8`'s `else => {}` silently drops these (vga.zig:532), and `portIn8` returns
    `0xFF` (vga.zig:513).
  - **Graphics Controller** `0x3CE/0x3CF` (Read Map Select 0x04, Mode 0x05, Misc/chain bit 0x06) —
    same silent-drop / `0xFF`-read. The engine **reads these back** (`f_1ca27.asm:101` `IN AL,DX`),
    so a register file with real storage is required, not a drop.
  - **CRTC data** `0x3D4/0x3D5` (the **unchain bit**, Underline Location reg 0x14 bit 6 = 0, Mode
    Control reg 0x17 bit 6 = 0; plus address/length for page bases). Only the BDA stores `0x3D4`
    today (int10.zig:189); the device has no CRTC index/data register file.
  - **The 4-plane unchained VRAM model.** Backing storage already exists — `VRAM_SIZE = 0x40000`
    (256 KiB = 4 × 64 KiB, vga.zig:66) was reserved "so a faithful future planar mode has real
    storage." But the `A0000` window is mapped **RAM-like** (`mapMmio(VRAM_PHYS, VRAM_WINDOW_LEN, …)`
    machine.zig:233) with a `getHostPtr` fast path — a write goes straight to the linear slab,
    **bypassing the Map Mask gate**. Unchained mode requires the write to dispatch through a planar
    handler (no `getHostPtr` fast path while unchained).
  - **The `0x3C0` attribute controller** asserts `false` if driven (vga.zig:531) — a LOUD flag. The
    overlay's Mode-Y setup likely programs the AC (palette/mode regs); this will trip the assert and
    must be built into a real AC state machine, not dropped.
  - **Front/back page bases** `0xA000` / `0xA400` (`wVgaFrontPageBase` / `wVgaPage2Base`): the render
    must read the *front* page base from the CRTC start-address (or the gfx-context, which the blit
    writes), not assume offset 0.
- **`src/bios/int10.zig`** has AH=00/01/02/03/06/07/08/09/0A/0C/0D/0E/0F/10/13 (handle:45-91). It has
  **no AH=1Ah** (hole #1), **no AH=12h** (EGA info — needed only if the detect falls to the EGA
  branch), and **no AH=1130h** (get ROM font — `video_init` calls it at f_1ab04.asm:168; it returns a
  font far ptr in `ES:BP`). `else => bios.unsupported` (int10.zig:92) is how an unhandled AH
  surfaces.
- **`src/cpu/`** raises a real **#UD** (INT 6) for unimplemented/illegal opcodes
  (`exec.ud`:25-28 → `raiseFault(VEC_UD=6, .fault, 0)`; gated 486+/Pentium opcodes #UD at
  exec.zig:374). 486+ instructions are honestly #UD-gated. **The INT 6 hazard:** the overlay /
  LZW / blit may use 386 instructions zdos has not implemented; each surfaces as INT 6. There is no
  default INT 6 IVT handler in DOS, so an INT 6 will jump to whatever the IVT slot holds (likely
  0000:0000 → crash/runaway) — observable as a hang or a wild PC. **The only way to enumerate these
  holes is to run further** (see the probe below).
- **`src/dos/`**: the VFS resolves paths **case-insensitively** component-by-component
  (`vfs.zig:10-13`, `resolveHostPath:141`, `findChild:228`) — so the `.BMX`→`.BMx` rewrite already
  works (no hole). Far-heap allocation is INT 21h AH=48/49/4A (int21.zig:186-188) backed by the MCB
  arena (`src/dos/mcb.zig`) — `alloc_far` runs as guest code over these. The MZ loader
  (`src/dos/loader.zig`) already loaded LAMUT. **Flag:** confirm at probe time that
  `video_driver_load`'s overlay open/read and `resblit`'s far-heap allocs succeed (the probe only got
  *to* `video_init`, not through `video_driver_load`).
- **The debugger/API**: `runToCycle` (controller.zig:353) is the deterministic fixed-cycle capture
  trigger; `/api/console` (worker.zig) reads the DOS CON stream (the `LAMUT-OK` line); `screen()`
  (controller.zig:671) is the **pure-peek** model the new framebuffer endpoint must follow
  (`peekBlock` → device `peek8`, never perturbs state). There is **no graphics framebuffer endpoint**
  today — `/api/screen` is text-only. The peekable regions table (controller.zig:757) already lists
  the `A0000` VRAM window.

---

## Gap-driven work items (ordered by what the empirical run hits next)

### W1 — VGA adapter detection (hole #1) → unblocks `adapter != 0`
`video_detect_adapter` (f_1ac53.asm:88) issues **INT 10h AX=1A00h** on the mode-8 auto-detect path.
Implement **INT 10h AH=1Ah** in `src/bios/int10.zig` (new case at int10.zig:45 switch):
- `AL=0x1A` (function supported), `BL=0x08` (active display code = VGA w/ color analog monitor),
  `BH=0x00` (inactive). These are the documented VGA Get-DCC values; `BL ∈ {7,8}` is exactly what
  f_1ac53.asm:92-95 tests for the VGA branch.
- This makes `video_detect_adapter` return 8 (requested mode, since `g_bRequestedVideoMode = 8 != 0`,
  f_1ac53.asm:106-110), so `video_init` proceeds to load the overlay.
- **W1b (likely, pending probe):** **INT 10h AH=1130h** (get font info) — `video_init` calls it at
  f_1ab04.asm:168 *after* the adapter check, so it executes once W1 passes. Implement AH=11 AL=30
  returning a ROM 8×8 font far ptr in `ES:BP` + `CX=char_height`, `DL=rows-1`. zdos has no ROM font
  table today — stage a real 8×8 font in BIOS ROM space (deterministic data, not a fake) and return
  its pointer. If skipped, `g_font_bitmap_data` gets a garbage ptr (only matters if text is later
  drawn in graphics mode — not on the LAMUT path, but the call must not crash).

### W2 — Mode-Y / unchained planar VGA (the headline new subsystem)
The overlay programs Mode-Y via guest port writes; zdos must model the registers + the planar VRAM.
All of this is **guest port writes + VRAM = fully deterministic** (no host clock, no float); the only
design question is the *model*. In `src/devices/vga.zig`:
- **Sequencer register file** (`0x3C4` index / `0x3C5` data), with real storage + read-back. Track
  the **Map Mask** (index 0x02): a 4-bit mask of which planes a write to `A0000` lands in. Track the
  Memory Mode (index 0x04) chain-4 bit (cleared → unchained).
- **Graphics Controller register file** (`0x3CE` index / `0x3CF` data), read-back-able
  (f_1ca27.asm needs `IN AL,DX`). Track Read Map Select (0x04, which plane a *read* returns), Mode
  (0x05), and Misc (0x06) chain-odd/even + memory-map bits.
- **CRTC register file** (`0x3D4` index / `0x3D5` data), read-back-able. Track the unchain bits
  (Underline Location 0x14 bit 6, Mode Control 0x17 bit 6) and the **start address** (0x0C/0x0D) that
  selects which page (`0xA000` front / `0xA400` back) the render scans out.
- **Attribute Controller state machine** (`0x3C0`) — replace the `assert(false)` (vga.zig:531) with
  a real index/data flip-flop (the `attr_flip_flop_is_index` field already exists, vga.zig:204) +
  register storage (palette regs 0x00-0x0F, mode 0x10, etc.). The overlay's mode set drives it.
- **The unchained VRAM model.** While unchained (chain-4 cleared): a write to `A0000+off` lands in
  **plane p iff Map-Mask bit p is set**, at `vram[p*0x10000 + off]` (planar layout) — i.e. one CPU
  address fans out to up-to-4 planes. A read returns `vram[ReadMapSelect*0x10000 + off]`. This means
  the `A0000` window can **no longer use the `getHostPtr` RAM-like fast path while unchained** — it
  must dispatch every write through a planar handler that consults the Map Mask. Design:
  `memHandler` returns `getHostPtr = null` (forcing the slow `write8`/`read8` path) **when the
  Sequencer reports unchained**, and a real planar `write8`/`read8`. Chained mode (mode 13h) keeps
  the fast path. Verify against `f_1ca27.asm` (`MOV BX,0xA000` / `STOSB`) and the real planar layout
  dosbox-x uses (`references/.../dosbox-x` vga_memory.cpp — consult the zig-developer skill's
  reference-emulator pointers).

### W3 — the overlay running as guest code (the INT 6 hazard)
**Confirmed approach:** run `Vmcode.ovl`'s **real driver instructions** (faithful) — do NOT
reimplement the driver. The requirement is therefore **correct CPU + VGA-port behavior**, which W2
provides. The risk is **CPU instruction holes**: the overlay (hand-tuned 386 asm) may use opcodes
zdos hasn't implemented, each surfacing as **#UD / INT 6** (exec.ud, vga.zig analog). Mitigation:
- Add a debugger hook / breakpoint on **INT 6** (the controller already supports interrupt
  breakpoints — `plans/debugger-milestone-1.md`) so an unimplemented opcode **stops** with the PC +
  the offending bytes instead of running wild into a null IVT slot.
- The probe: run LAMUT to completion under the API with an INT-6 breakpoint armed; each stop names a
  missing opcode → implement it in the relevant `src/cpu/exec_*.zig` → repeat. This is iterative and
  its size is **unknown until run** (see Risks).

### W4 — LZW decompression + file I/O + far-heap (verify as guest code)
LZW expand (vtable slot 29), the BMX/PAL file reads, and the far-heap allocs all run as **guest code**
on zdos's existing DOS/CPU. The probe already cleared the CRT + the first file open, and the VFS is
case-insensitive (no `.BMx` hole). **Verify at probe time** (not assumable until the run gets there):
`video_driver_load`'s overlay open/read, `resblit`'s `(count+1)` table + descriptor reads, and
`alloc_far` (INT 21h AH=48). Flag any DOS hole then; none is *predicted* but none is *proven absent*.

### W5 — framebuffer capture (new observability)
A side-effect-free **`GET /api/framebuffer`** mirroring `screen()` (controller.zig:671) — a pure peek
of guest device state (CLAUDE #1, like `/api/screen` for text). In `src/debug/controller.zig` +
`src/api/{queue,worker,server}.zig`:
- Read the live CRTC start-address (front-page base) + the Sequencer/GC unchain state + the 4 planes
  of VRAM + the 256-entry 6-bit DAC, **all via `peekBlock` / device `peek8`** (no port-read side
  effects — `statusReg1` mutates the AC flip-flop, so the capture must read raw fields, not via
  `in8`).
- **Render:** for each of 320×200 pixels, compute the planar address (Mode-Y: pixel `(x,y)` →
  plane `x & 3`, byte offset `start + y*80 + (x>>2)`), read the index, look up the DAC entry, scale
  6-bit → 8-bit (`v*255/63`, or `(v<<2)|(v>>4)` — pick ONE convention and pin it; document it), emit
  RGB(A). Output raw 320×200 RGBA bytes (and optionally encode PNG host-side in the test, not in the
  emulator, to keep the encoder out of the determinism boundary).
- Register the capture as a pure read (it must not advance cycles or mutate any device field — assert
  cycle-neutrality in a test, mirroring the M1/M2 cycle-neutral audits).

### W6 — the screenshot oracle (Stage 2 gate)
The framebuffer content is **guest-observable device state** (planar VRAM + DAC), so a deterministic
render at a fixed cycle is a **valid cross-emulator golden** *iff* zdos's plane layout + DAC scaling
match the golden's. Two strategies (decision needed — see Risks):
- **(A) Cross-check the Spice86/dosbox golden.** Reuse `tools/lamut-oracle/lamut_0.idx` (the
  palette-*index* image) as the ground truth — it is independent of DAC-scaling convention, so it
  isolates the planar de-interleave from the palette. Then check the full RGB against `lamut_0.ppm`.
- **(B) Mint a zdos golden** at a fixed cycle, commit it, and **separately** cross-check it once
  against `lamut_0.idx` to prove correctness. Future regressions compare against the zdos golden.
- Either way: capture at a fixed `runToCycle(N)` in the post-blit plateau; compare a **raw-RGBA pixel
  hash** (NOT the PNG container — heed the Spice86 test's Skia caveat). The fixed cycle N for zdos is
  unknown until the run completes (zdos's cycle ledger differs from Spice86's by design — zdos has no
  holes); pick N empirically once Stage 1 is green (e.g. the cycle right after `blit_sprite_indirect`
  returns, found via a breakpoint on its return).

---

## Determinism analysis (CLAUDE prime directive)

- **Mode-Y VRAM + the DAC are guest state** — written by guest `OUT`/`MOV` instructions, already
  snapshot-covered (`Vga.Snapshot` vga.zig:549; VRAM bytes copied separately, machine.zig:526). The 4
  planes are just the existing 256 KiB slab (`VRAM_SIZE`); no new non-determinism.
- **The new VGA registers** (Sequencer/GC/CRTC/AC) are plain device state → add them to
  `Vga.Snapshot` so a snapshot/restore round-trips the planar mode (regression-test it, like the
  existing VRAM round-trip machine_test.zig:245-270).
- **The framebuffer render is a pure read** of VRAM + DAC + register fields (W5) — no cycle charge,
  no port side effects, no host clock. Same class as `screen()`.
- **The capture trigger is `runToCycle(N)`** — emulated time, never the host wall clock (CLAUDE #2).
- **No new cycle-ledger holes:** Mode-Y is all guest instructions executing on the CPU core; the only
  host trap added is INT 10h AH=1Ah / AH=1130h (W1), which charge the fixed synthetic trap cost like
  every other BIOS trap (CLAUDE #1). The DAC scale convention (W5) is pinned at comptime (integer
  only).
- **Both gates are byte-reproducible:** `LAMUT-OK` is deterministic console output; the golden frame
  is a pure render of deterministic guest state at a deterministic cycle.

---

## RESULT — both stages LANDED (2026-06-16)

The full VGA build (P1–P6, ROADMAP #10/#10c/#11) closed every hole the gap analysis predicted.
The Stage-1/Stage-2 acceptance probe required **no further emulator changes** — it was a pure
verification run.

**Stage 1 — `LAMUT-OK` (PASS).** `./zig-out/bin/zdos /tmp/lamut-work/LAMUT.EXE headless` prints:

```
LAMUT-OK: adapter=8 296x101
[zdos] normal; exit code 28; 14860944 cycles
```

Deterministic: two headless runs are byte-identical at **14,860,944 cycles**. The no-argument run
(with the `wait_seconds` INT 1Ah 3-second hold) also reaches LAMUT-OK, at **56,637,088 cycles** —
the BIOS tick advances off the cycle counter, so the hold terminates with no host clock. (Exit code
28 is the Borland CRT epilogue "null-pointer-assignment" check, the same benign quirk DOSBox sees;
the `LAMUT-OK` line is the acceptance criterion per `main.c`, which checks return values + descriptor
dims, not the exit code.)

**Stage 2 — visual oracle (PASS, strategy A).** Driven over the HTTP API:
- Post-blit plateau located by scanning `GET /api/framebuffer?format=index` while running to
  successive cycles: the blit completes at **cycle 14,848,000** (nonzero pixels stabilize at 29,189),
  then `restore_text_mode()` flips to text mode at ~14,849,000. `run-to-cycle 14848000` lands at the
  next instruction boundary, **cycle 14,848,079**, inside the plateau.
- The framebuffer reports **kind=1 (vga256_linear, chained mode 13h)** — i.e. LAMUT/Vmcode.ovl
  drives the blit through the **chained** mode-13h path, not unchained Mode-Y, at capture time. (The
  blit's plane-cycling write pattern is visible in the diff signature below, but the SEQ chain-4 bit
  is set, so the rasterizer correctly de-interleaves via the linear path. This is faithful to what
  the overlay actually programs; the milestone's Mode-Y expectation was a prediction, not a
  requirement — the render classification follows the live SEQ register.)
- **Index-image match: EXACT.** Cropping the 320×200 index frame at (x=12, y=49, 296×101) — the
  centring `main.c` computes — yields a buffer **byte-identical** to `tools/lamut-oracle/lamut_0.idx`
  (the convention-independent ground truth, 296×101 = 29,896 bytes). 0 byte differences. Verified
  byte-identical across a second fresh run (determinism) and across two consecutive captures
  (purity).
- **Capture is cycle-neutral + a pure peek:** the status cycle is unchanged (14,848,079) before and
  after capture; two consecutive captures are byte-identical.
- **RGBA cross-check (documented reconciliation).** The `format=rgba` crop vs `lamut_0.ppm` differs
  in 27,220/29,896 pixels but with a **max per-channel delta of 3** — the expected DAC 6→8-bit
  scaling-convention difference (milestone Risk #4): the golden palette `lamut.pal.rgb` was minted
  with plain `c<<2` (its max byte is **252** = `63<<2`), while zdos uses the more hardware-faithful
  `(c<<2)|(c>>4)` (which gives 255 for c=63). Both are faithful; the ≤3 delta is the convention gap,
  which is exactly why the index image (`lamut_0.idx`) is the authoritative oracle — and it matches
  exactly. No fudge.

`zig build test` → exit 0, **476 tests** (unchanged; no emulator code touched).

> **Regression-test note (P7/P8 deferred, honestly).** A committed black-box test cannot bundle the
> inputs: `LAMUT.EXE` + `Vmcode.ovl` + `G_LAMUT.BMX/.PAL` are **Betrayal at Krondor game
> assets** (`assets.txt`: "Not committed"), and the oracle extraction (`oracle.py`) needs Python,
> which is absent on this host. The faithful path for a permanent gate is the milestone's Risk-#6
> option: stage the assets out-of-tree at test setup (gitignored) and gate the test on their
> presence (skip when absent), mirroring how `run.sh` stages from `Krondor.001`. The verification
> above is fully reproducible from the staged work dir; only the *committed CI gate* is deferred
> because the assets are not committed.

---

## Phased checklist (each ≈ one focused commit; gates stay green; independently testable)

- [ ] **P1 — INT 10h AH=1Ah (adapter detect).** Add the AH=1Ah case to `src/bios/int10.zig:45`
      (AL=0x1A, BL=0x08, BH=0x00). Unit-test the register values. Probe: re-run LAMUT, confirm
      `video_detect_adapter` returns 8 and `video_init` proceeds past the adapter check (it will now
      hit `video_driver_load` / AH=1130h / the overlay).
- [ ] **P2 — INT 10h AH=1130h + ROM 8×8 font.** Stage a real 8×8 font in BIOS ROM space; return its
      `ES:BP` ptr + `CX`/`DL`. (Only if P1's probe shows the run reaching f_1ab04.asm:168, which it
      should.) Probe: confirm `video_init`'s epilogue completes and the overlay's vtable copy ran.
- [ ] **P3 — VGA Sequencer + Graphics Controller register files** (`0x3C4/0x3C5`, `0x3CE/0x3CF`) with
      read-back, in `src/devices/vga.zig` (replace the `else => {}` drop at vga.zig:532 and the
      `0xFF` read at :513 for these ports); register the ports in `src/machine/machine.zig:222`.
      Test the index/data round-trip + read-back (the f_1ca27.asm idiom).
- [ ] **P4 — CRTC register file + Attribute Controller state machine** (`0x3D4/0x3D5`, `0x3C0`).
      Replace the `0x3C0` `assert(false)` (vga.zig:531) with a real AC flip-flop + register storage.
      Add CRTC index/data + start-address + unchain bits. Register `0x3D4/0x3D5/0x3C0/0x3C1` in
      machine.zig. Test round-trips. Probe: re-run; the overlay's Mode-Y *register* program now
      completes without an assert/drop.
- [ ] **P5 — unchained planar VRAM model.** Make the `A0000` memHandler consult the Sequencer
      chain-4 bit: chained → keep the `getHostPtr` fast path (mode 13h unchanged); unchained →
      `getHostPtr = null` + a planar `write8` (Map-Mask fan-out) / `read8` (Read-Map-Select). Add the
      new registers to `Vga.Snapshot` (vga.zig:549) + a snapshot round-trip test. Probe: re-run; the
      blit writes land in the planes (verify via a planar VRAM peek, even before the render exists).
- [ ] **P6 — `GET /api/framebuffer` (pure-peek render).** Add the controller method (mirror
      `screen()` controller.zig:671), the queue/worker/server plumbing
      (`src/api/{queue,worker,server}.zig`), the planar de-interleave + DAC 6→8-bit render, raw-RGBA
      output. Cycle-neutrality test. Probe: capture LAMUT at a post-blit cycle and eyeball / dump.
- [ ] **P7 — Stage 1 gate: `LAMUT-OK`.** A black-box test (the `Session` harness, ROADMAP item 6)
      runs LAMUT headless and asserts `/api/console` contains `LAMUT-OK: adapter=8 296x101`. **This is
      the Stage-1 acceptance gate.** Any INT-6 stops surfaced along the way (W3) become their own
      sub-commits implementing the missing opcode(s) in `src/cpu/exec_*.zig` — count unknown until run.
- [ ] **P8 — Stage 2 gate: visual oracle.** Pick the fixed capture cycle N (breakpoint on
      `blit_sprite_indirect` return), capture the framebuffer, compare a raw-RGBA pixel hash to the
      golden (strategy A or B per the decision below). Cross-check once against
      `tools/lamut-oracle/lamut_0.idx`. **This is the Stage-2 acceptance gate.**

---

## Risks / open questions (for the human)

1. **Size — this is a large milestone.** It is a new VGA subsystem (Sequencer + GC + CRTC + AC
   register files + an unchained planar VRAM model) *plus* a graphics-capture observability surface.
   Recommend committing to **Stage 1 first** (P1-P7) as the "load LAMUT.EXE" deliverable, and
   treating Stage 2 (P8) as a follow-on. **Decision: approve the two-stage split + sequencing?**
2. **CPU instruction coverage — the biggest unknown (INT 6 hazard).** The overlay is hand-tuned 386
   asm; how many opcodes zdos is missing is **unknowable until the run gets past `video_init`**. Each
   is one #UD stop → one fix. This could be 0 or it could be many. **Probe to find out: arm an INT-6
   breakpoint and run LAMUT to completion** (do this right after P1, before building the whole VGA
   subsystem, to size the CPU work early). **Decision: do the INT-6 probe first to de-risk?**
3. **Mode-Y modeling fidelity.** The plane layout, the Map-Mask fan-out, and the front/back page-base
   read-out must match the hardware exactly or the render is subtly wrong. The c-recon asm
   (`f_1ca27.asm` et al.) + dosbox-x `vga_memory.cpp` are the references. Lower-risk than #2 because
   it's pure deterministic state, but it's the largest *code* item.
4. **DAC 6→8-bit scaling convention.** `v*255/63` vs `(v<<2)|(v>>4)` give different bytes. The golden
   was minted by Spice86/dosbox; match their convention OR use the index-image (`lamut_0.idx`) as the
   convention-independent ground truth. **Decision: which DAC scale + which golden ground truth?**
5. **Golden strategy.** (A) cross-check the existing Spice86/dosbox golden (`lamut_0.idx`/`.ppm`), or
   (B) mint a zdos golden and cross-check it once. zdos's fixed capture cycle N **differs from
   Spice86's by design** (zdos has no cycle-ledger holes), so the *cycle* is not portable — only the
   *pixels* are. **Decision: strategy A or B?**
6. **Asset staging.** `G_LAMUT.BMX` / `G_LAMUT.PAL` / `Vmcode.ovl` are game assets (not committed —
   `assets.txt`). zdos's black-box test needs them staged at run time (extract from `Krondor.001` via
   the oracle, as `run.sh` does) or referenced from the bak repo. **Decision: stage in-repo
   (gitignored) at test setup, or reference the bak install path?**
7. **Not assessable until the run goes further.** `video_driver_load`'s overlay I/O, `resblit`'s
   far-heap allocs, and the LZW expand are *expected* to work as guest code (the CRT + first file open
   already do) but are **unproven** until P1's probe gets there. The plan flags each as
   verify-at-probe rather than assuming it.
