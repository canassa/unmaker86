# VGA display side — CRTC timing, scanout addressing, and the all-mode rasterizer

Status: **design plan / specification** (no source changed by this document). This is the
**framebuffer-capture-across-every-mode** spec: the CRTC timing model, the scanout addressing
pipeline, and the rasterizer that turns VRAM + register state into pixels for **all** standard VGA
modes — text (0-3, 7), CGA graphics (4/5/6), EGA 16-color planar (0Dh-12h), VGA 256-color (13h
linear + Mode-X/Y unchained planar). It is the read-side companion to the write/register subsystem
sketched in `plans/lamut-milestone.md` (W2/W5) and the deterministic 0x3DA model in
`plans/vga-retrace.md`.

> **Scope honesty.** zdos today renders nothing: mode-13h "capture" would be a direct VRAM+DAC read,
> and the only display surface that exists is the text-grid `/api/screen` peek
> (`src/debug/controller.zig:671-699`). There is **no general scanout/rasterizer**. This document
> specifies that rasterizer in full and pins it to zdos's prime directive: **the captured frame is a
> pure function of guest state (VRAM + all registers + DAC) at a fixed cycle — no host clock, no
> render-rate, no wall-clock blink.** It does not require the register subsystem (Sequencer / GC /
> CRTC / AC files) to exist yet; it specifies what the rasterizer reads from those files once they
> land (LAMUT P3/P4). Where a register file is absent today, the spec flags it as a prerequisite,
> never fakes a value.

---

## 0. The hard determinism rule for this spec (CLAUDE prime directive)

The rendered/captured frame MUST be a **pure read** `render(VRAM, registers, DAC) -> pixels`. No
emulation-state mutation, no cycle charge, no host time. The two consequences that dominate every
design decision below:

1. **No host frame clock.** Both references drive rendering off a real/emulated frame timer (dosbox
   `PIC_AddEvent(VGA_DrawSingleLine, ...)` per scanline, `vga_draw.cpp:1249`; spice86's
   `VgaTimingEngine` per-scanline event chain). zdos does **not** run a draw loop. There is no
   "current scanline being drawn", no `vga.draw.address` walking state, no back/front buffer swap.
   The capture renders the **whole frame at once** from the latched register state, on demand.
2. **No wall-clock blink / cursor-blink / refresh phase.** Both references toggle text blink and the
   text cursor visibility from a host/emulated millisecond timer (dosbox `vga.draw.blink`,
   `vga_draw.cpp:1534`; `VGA_SetBlinking` `:1334`; spice86 `BlinkPeriodMs = 500.0`,
   `VgaTimingEngine.cs:13`, `_blinkState.IsBlinkPhaseHigh`). zdos must NOT copy this. The blink/cursor
   phase, if shown at all, is a **deterministic function of `cpu.st.cycles`** or is **omitted/static**
   (see §6). The retrace status (0x3DA) is already cycle-derived (`vga.zig:476-498`,
   `plans/vga-retrace.md`); this spec keeps the **same** cycle-derived timing model and never
   introduces a second time source.

The do-not-copy list is consolidated in §7.

---

## 1. CRTC timing model (extends `plans/vga-retrace.md`)

### 1.1 What already exists, and the contract this spec must preserve

`plans/vga-retrace.md` (shipped: `src/devices/vga.zig:104-146,460-498`) pins the standard-VGA 70 Hz
frame as **fixed comptime constants** and derives the 0x3DA retrace/display-enable bits from
`cpu.st.cycles` with pure integer math:

```
FRAME_CYCLES = CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ = 204_293   (70.086 Hz)
LINE_CYCLES  = FRAME_CYCLES / VTOTAL_LINES = 454
HDE_CYCLES   = CPU_CLOCK_HZ * HDE_DOTS / DOT_CLOCK_HZ = 181
```

with `DOT_CLOCK_HZ = 25_175_000`, `HTOTAL_DOTS = 800`, `VTOTAL_LINES = 449`, `HDE_DOTS = 320`,
`VDE_LINES = 400`, `VRSTART_LINE = 412`, `VREND_LINE = 414` (`vga.zig:122-128`). This is **decision
D-RT1**: a faithful simplified duty cycle, fixed for the mode-13h / standard-text CRTC family, *not*
a programmable CRTC read.

**The contract this spec must not break:** the 0x3DA status and any timing the rasterizer references
stay **cycle-derived and integer-only**. The rasterizer itself reads no time at all (it is a spatial
render of a frame, not a temporal scan). The *only* place time enters the display side is (a) the
0x3DA poll (already done) and (b) the optional cursor/blink phase in the capture (§6), both
`f(cpu.st.cycles)`.

### 1.2 How the CRTC registers encode timing (the authoritative packing)

A full VGA computes the frame geometry from the CRTC register file. This is what zdos will read once
the CRTC register file lands (LAMUT P4). The packing is **identical** in both references and on real
hardware; dosbox's `VGA_SetupDrawing` is the cleanest statement
(`references/dosbox-staging/src/hardware/video/vga_draw.cpp:1833-1906`):

| Field | Base register (CRTC index) | High bits packed from |
|-------|---------------------------|------------------------|
| Horizontal total | 0x00 | (`vga_draw.cpp:1834`) `+2` correction (`:1881`) |
| Horizontal display end | 0x01 | `+1` correction (`:1883`) |
| Start horizontal blanking | 0x02 | (`:1837`) |
| End horizontal blanking | 0x03 bits 0-4 | + bit 5 from End-Horiz-Retrace 0x05 bit 7 (`:1858`) |
| Start horizontal retrace | 0x04 | (`:1838`) |
| End horizontal retrace | 0x05 bits 0-4 | wrap-relative to start (`:1890-1897`) |
| Vertical total | 0x06 | + Overflow 0x07 bit 0 (<<8) (`:1840`), `+2` (`:1882`) |
| Overflow | 0x07 | packs high bits of vtotal/vde/vbstart/vrstart/line-compare |
| Preset row scan (pan compensation) | 0x08 | byte-panning bias |
| Max scan line | 0x09 bits 0-4 | char height-1; bit 7 = double-scan; bit 6 = line-compare bit 9; bit 5 = vbstart bit 9 |
| Cursor start (scanline) + enable | 0x0A bits 0-4 + bit 5 | text cursor top scanline; bit5=1 disables cursor |
| Cursor end (scanline) | 0x0B bits 0-4 | text cursor bottom scanline |
| Start address high / low | 0x0C / 0x0D | the displayed page base (page flip) |
| Cursor location high / low | 0x0E / 0x0F | text cursor cell address |
| Vertical retrace start | 0x10 | + Overflow 0x07 bit 2 (<<6) + bit 7 (<<2 on VGA) (`:1849,1874`) |
| Vertical retrace end + IRQ enable | 0x11 bits 0-3; bit 4 = IRQ enable, bit 5 = IRQ clear | (`:1899`) |
| Vertical display end | 0x12 | + Overflow 0x07 bit 1 (<<7) + bit 6 (<<3 on VGA) (`:1843,1867`), `+1` (`:1884`) |
| Offset / logical line width (stride) | 0x13 | stride in 2-byte (word) units (`:1621,1628,1630`) |
| Underline location + DWORD-mode bit | 0x14 | bit 5 = count-by-4 (dword); bit 6 = dword addressing (`vga_crtc.cpp:312-330`) |
| Start vertical blanking | 0x15 | + Overflow bit 3 (<<5) + MaxScanLine bit 5 (`:1846,1870`) |
| End vertical blanking | 0x16 | wrap-relative (`:1876,1913-1919`) |
| CRTC Mode Control | 0x17 | bit 6 = byte/word addressing; bit 5 = address wrap; bit 0/1 = map13/14↔row-scan (CGA/MDA compat); bit 7 = sync enable |
| Line compare | 0x18 | + Overflow bit 4 (<<8) + MaxScanLine bit 6 (<<9) → 10-bit value (`vga_crtc.cpp:125,167,382`) |

**The frame period in CPU cycles** is derived from the dot clock and the (htotal × vtotal) product,
exactly as today: `FRAME_CYCLES = CPU_CLOCK_HZ * htotal_dots * vtotal_lines / DOT_CLOCK_HZ`. The dot
clock is selected by Misc-Output bits 2-3 (`0x3C2`): `0 → 25.175 MHz` (the 640/320-wide 70 Hz
family), `1 → 28.322 MHz` (the 720-wide 9-dot text family). 320-wide modes pixel-double, so their
htotal in *dots* is the same 800 as 640-wide (dosbox doubles `horiz.total` for the half-clock,
`vga_draw.cpp:119-130`).

The standard-mode refresh rates (from `vtotal`, dot clock, dots/line) zdos must be able to reproduce:

| Modes | Active res | vtotal | dot clock | Refresh |
|-------|-----------|--------|-----------|---------|
| 0-3, 7, 4-6, 0Dh, 0Eh, 13h | (various, 200/400-line) | 449 | 25.175 MHz (text: 28.322) | **70.086 Hz** |
| 0Fh, 10h | 640×350 | 449 | 25.175 MHz | 70.086 Hz |
| 11h, 12h | 640×480 | **525** | 25.175 MHz | **59.94 Hz** |

(BIOS mode table `references/dosbox-staging/src/ints/int10_modes.cpp:30-45`. Note modes 11h/12h use
`vtot=525`, the only 60 Hz family in the standard set.)

### 1.3 zdos's decision: fixed-table timing now, programmable later (D-RT1 preserved)

Per D-RT1, zdos pins the 70 Hz frame for the mode-13h/text family and does **not** read the CRTC
totals today. **This spec extends that to a small per-mode timing table** keyed on the BDA video mode,
so 640×480 modes (11h/12h) get their 525-line / 59.94 Hz frame and the rest get 449/70.086 Hz. The
table is comptime-pinned integer cycles, mirroring the existing `vga.zig` comptime block
(`vga.zig:137-146`). The packing in §1.2 is the **specification for the eventual programmable path**
(when a guest reprograms the CRTC, e.g. a Mode-X tweak with a non-standard vtotal); structure the
timing as `mode -> TimingConstants` so the programmable path slots in without rework. **Flag, don't
pre-build** the full CRTC-derived path (CLAUDE ground rule): the v1 capture targets (BaK mode 13h,
LAMUT Mode-Y, text) all use standard totals.

The cycle-derived 0x3DA status (§1.1) already gives the only timing a guest observes. The rasterizer
(§3) does not consult `FRAME_CYCLES` at all — it renders a static frame from latched registers.

---

## 2. Scanout addressing — (x, y) → VRAM byte/plane/bit, every addressing mode

The scanout walks the displayed area and maps each output pixel to a VRAM location through the CRTC
addressing pipeline. zdos's capture computes this **per output pixel** (or per character cell), with
no walking draw state — but the address math is identical to the references' per-scanline walk. The
canonical sequence (dosbox `VGA_SetupDrawing` `vga_draw.cpp:1453-1654`; spice86 `Renderer` +
`VgaAddressMapper` `Renderer.cs:135-254,532-559`):

### 2.1 Start address (page base / page flip)

The first displayed character address is the CRTC **Start Address** (high 0x0C, low 0x0D), masked to
VRAM size: dosbox `vga.config.real_start = vga.config.display_start & (vga.vmemwrap-1)`
(`vga_draw.cpp:1379`); spice86 `_frameRowMemoryAddressCounter = ScreenStartAddress`
(`Renderer.cs:135`). **This is the page-flip mechanism**: a double-buffered game writes the back page
then reprograms 0x0C/0x0D to flip. The capture reads the *current* start address — the displayed page.
For mode 13h the BIOS leaves it 0; LAMUT's front/back page bases (`0xA000`/`0xA400` = start address
0 / 0x4000-words) come from this register (`plans/lamut-milestone.md` W5).

On real hardware the start address latches at vertical retrace (dosbox `VGA_DisplayStartLatch`
scheduled at `vrstart`, `vga_draw.cpp:1412`). For a **static capture** there is no mid-frame latch
race; the capture reads the live register value. (If a future need arises to model a mid-frame flip
at the exact retrace cycle, derive the latch phase from `cpu.st.cycles % FRAME_CYCLES` — never a host
timer.)

### 2.2 Offset / stride (logical line width)

CRTC **Offset register 0x13** gives the logical scanline width in **2-byte words** (or dwords in
dword mode). The address advances by `offset * 2` per character row (spice86
`_frameRowMemoryAddressCounter += Offset << 1`, `Renderer.cs:248`; dosbox `address_add = scan_len *
{16,8,4}` depending on mode, `vga_draw.cpp:1621-1630`). A logical width wider than the visible width
is how a game implements a virtual scroll buffer (the visible window pans within it via start
address + panning). The capture reads the live offset; for the standard modes it equals the visible
width in words.

### 2.3 Max Scan Line — char height / double-scan / line doubling

CRTC **Max Scan Line 0x09**: bits 0-4 = (character cell height − 1) in text, or the scan-line
**repeat count − 1** in graphics. **Bit 7 = double-scan** — a *separate* mechanism (the CRTC emits
each scanned line twice). dosbox `address_line_total` (`vga_draw.cpp:2253-2256`), `is_double_scanning`
(`:2260-2264`); spice86 `_frameMaximumScanline`, `_frameDrawLinesPerScanLine = CrtcScanDouble ? 2 :
1` (`Renderer.cs:316-317,239-252`). **The displayed-row address only advances after `MaxScanLine+1`
raster lines** — this is what makes a text glyph 16 raster lines tall reuse one cell address.

> **FIX (review S1) — mode 13h fills 400 lines via Max-Scan-Line, NOT the double-scan bit.** The IBM
> VGA BIOS programs CRTC 0x09 = **`0x41`** for mode 13h: `0b0100_0001` — **bit 7 (double-scan) is
> CLEAR**; the set bits are bit 6 (line-compare bit 9) and bit 0 (Max-Scan-Line low bit = 1). So
> `MaxScanLine = 1` ⇒ each of the 200 logical rows is repeated for **2 raster lines** (the cell-height
> repeat above), giving the 400-line raster. The earlier draft mislabeled this as "double-scan"; the
> rasterizer must derive the row repeat from `(MaxScanLine & 0x1F) + 1`, and treat bit 7 (double-scan)
> as the *additional* per-scan doubling it genuinely is (used by some 200-line modes, but not 13h).
> The 200-row→400-raster behavior is correct either way; the *register decode* must read bits 0-4, not
> bit 7. For the **capture output resolution**, zdos
emits the **logical** resolution (320×200, 640×200, etc.) and records whether double-scan was active;
the consumer scales for aspect if it wants (the index image and pixel hash are at logical res — §5).

### 2.4 Line Compare (split screen)

CRTC **Line Compare 0x18** (+ Overflow bit 4, + Max-Scan-Line bit 6 → 10-bit value): when the
displayed scanline reaches line-compare, the address counter **resets to 0** for the remainder of the
frame (the bottom split renders from VRAM offset 0, independent of start address / panning). dosbox
`VGA_ProcessSplit` (`vga_draw.cpp:1106`, scheduled when `lines_done == split_line`,
`:1243-1245,1440`); spice86 `if (_frameLineCounter == LineCompareValue) { _frameRowMemoryAddressCounter
= 0; _frameAboveLineCompare = false; }` (`Renderer.cs:226-229`). Used by status bars / scrolling
games (the top scrolls, the bottom HUD stays fixed at offset 0). The capture must honor it: rows
`[0, line_compare)` render from `start_address` (+panning), rows `[line_compare, vde)` render from
address 0 with panning suppressed in "pixel-panning-compatibility" mode (spice86
`_frameAboveLineCompare` gating, `Renderer.cs:443,459`). For standard modes line-compare = 0x3FF
(disabled); the capture handles it generically.

### 2.5 Byte / word / dword addressing (CRTC Mode Control 0x17 + Underline 0x14)

The address counter is transformed before indexing VRAM, per CRTC Mode Control 0x17 bit 6
(byte/word) and address-wrap bit 5, plus Underline 0x14 bit 6 (dword). The exact transform is
spice86's `VgaAddressMapper.ComputeAddress` (`Renderer.cs:547-557`), which is the cleanest statement
of the real hardware:

```
Byte    : p = counter
Word13  : p = (counter << 1) | ((counter >> 13) & 1)     // address bit 0 ← bit 13 (CGA-compat wrap)
Word15  : p = (counter << 1) | ((counter >> 15) & 1)
DWord   : p = (counter << 2) | ((counter >> 14) & 3)
```

then the optional CGA/MDA-compatibility row-scan bit substitution into address bits 13/14 (Mode
Control 0x17 bits 0/1, `VgaAddressMapper` `_andMask13/_orMask13`, `Renderer.cs:539-545`). dosbox does
the equivalent in `vga_memory.cpp` address generation. **Mode 13h is byte mode**; **text modes are
word mode** (the classic B8000 even=char/odd=attr interleave is the word transform); the CGA 4/6 modes
use the CGA-compat bit-13 wrap that produces the **interleaved scanline banks** (even rows at
0x0000, odd rows at 0x2000) — §3.3.

### 2.6 Pixel panning (AC 0x13 + the compensation)

Attribute Controller **Horizontal Pixel Panning 0x13** (bits 0-3) shifts the displayed image left by
N pixels (smooth horizontal scroll). dosbox `vga.config.pel_panning` → `vga.draw.panning`, added to
the line address (`vga_draw.cpp:1273,1385`; the byte-panning shift `:1477-1482`); spice86
`_framePanShift = HorizontalPixelPanning`, applied by rendering into a scratch row and copying from
`[panShift..]` (`Renderer.cs:148,216-219,473-486`). **256-color mode honors only bits 0-2, doubled**
(`pan*2`, spice86 `Render...PanShift` `Renderer.cs:439,446`; dosbox same `& 0x07`); planar/text honor
all 4 bits; 9-dot text with line-graphics adds +1 (spice86 `ComputeTextPanShift` `:462-464`). The
**preset-row-scan / byte-panning compensation** (CRTC 0x08) provides the coarse byte offset that
panning fine-tunes. The capture applies panning per the live AC 0x13 + the mode rules. For the
standard BIOS modes panning = 0; the capture handles it generically so a scrolling game captures
correctly.

### 2.7 The composite per-pixel address (the formula the capture implements)

For output pixel `(x, y)` (logical resolution), the VRAM character address is:

```
row_in_char   = (y * (double_scan ? 1 : 1)) ... advance addr every (MaxScanLine+1) raster lines
base_addr     = (y >= line_compare) ? 0 : start_address
char_addr     = base_addr + (y / char_height) * (offset * 2) + (x_char) ...
phys          = AddressMap(char_addr, byte/word/dword)        // §2.5
plane, bit    = mode-specific decode of (x within the char) → §3
```

The capture computes this directly; it does **not** maintain dosbox's walking `vga.draw.address`/
`address_line` state (those exist only because dosbox renders incrementally on a timer). For the
**linear chained mode 13h** the whole pipeline collapses to `phys = start_address_bytes + y*width +
x` (one byte per pixel) — which is why mode-13h capture is "just a VRAM+DAC read". The general
pipeline above is what makes the **other** modes work.

---

## 3. The rasterizer — every mode, VRAM + registers → RGB

The rasterizer is dispatched on the current mode (from BDA `OFF_VIDEO_MODE` + the GC/AC/Sequencer
mode bits once those exist). Output is, per pixel, a **palette index** and an **RGBA** value (§5
defines which the capture emits). The plane/bit decode for each family follows.

> **VRAM plane layout (commit to one).** A 4-plane VGA stores plane P byte at a fixed offset.
> spice86 interleaves: byte for address A is `VRam[A*4 + plane]` (`Renderer.cs:403,522-527,590`).
> dosbox keeps planes contiguous: `plane*0x10000 + addr`. The LAMUT plan already commits zdos to the
> **contiguous** layout `vram[plane*0x10000 + off]` (`plans/lamut-milestone.md` W2/P5, matching the
> 256 KiB `VRAM_SIZE = 0x40000` = 4×64 KiB slab, `vga.zig:63-66`). The rasterizer uses that:
> `plane_byte(P, addr) = vram[P*0x10000 + addr]`. Mode 13h's chained linear mapping is the special
> case where the BIOS programs chain-4 so the CPU's A000 window already lands one-byte-per-pixel in
> plane order — the capture reads `vram[off]` directly there (matching `vga.zig:284-308`).

### 3.1 Text modes (0-3 color, 7 mono): char-cell → glyph → attribute → DAC

Per cell (read as the flat `{char, attr}` word from the active text page — `text_vram`/`text_vram_mono`,
`vga.zig:160-161`, addressed per §2 word mode):

1. **Glyph fetch.** `font_byte = font[char * char_height + scanline_in_cell]`. The font is the
   **character generator** (real VGA: plane 2, uploaded by INT 10h AH=11; spice86 reads
   `VRam[(32*char + scanline)*4 + 2]`, `Renderer.cs:564,590`; dosbox `vga.draw.font_tables`,
   `vga_draw.cpp:866`). zdos models the **flat char/attr slab**, not the plane-2 font upload
   (D-TM1, `plans/text-mode-video.md`), so the capture uses a **bundled ROM font** staged in BIOS
   space — the 8×16 (modes 2/3/7), 8×14 (0Fh/10h text), and 8×8 (modes 0/1, 43-row) IBM VGA fonts,
   selected by the BDA char height (`OFF_CHAR_HEIGHT`). This is **real deterministic font data**, not
   a fake (same status as the AH=1130h ROM-font requirement in LAMUT W1b). Cell width is 8 or **9**
   dots (9-dot text doubles the 8th column for line-graphics chars 0xC0-0xDF; Misc/Clocking-Mode
   bit). The 9th column is `font_byte` bit-0 replicated only for the line-draw range
   (spice86 9-dot handling via `DotsPerClock`, `Renderer.cs:588-595`).
2. **Attribute decode.** `attr` byte: bits 0-3 = foreground index, bits 4-6 = background index, bit
   7 = blink-or-intensity. The fg/bg are **internal-palette indices** routed through the AC pipeline
   (§3.5). The classic table mapping is dosbox `TXT_FG_Table[col & 0xf]` / `TXT_BG_Table[col >> 4]`
   (`vga_draw.cpp:871-872`) and spice86 `attrMap[index]` / `attrMap[(plane1>>4)&0xF]`
   (`Renderer.cs:566,581`).
3. **Blink / intensity (AC Mode Control 0x10 bit 3).** If blink is *enabled* and `attr` bit 7 set,
   the foreground blinks (background uses `bg & 0x7`); if blink is *disabled*, bit 7 is the
   high-intensity background bit (16 background colors). dosbox `FontMask[col>>7]` gated by
   `vga.draw.blink` (`vga_draw.cpp:868,1534`); spice86 `BlinkingEnabled && (plane1&0x80) &&
   !IsBlinkPhaseHigh` (`Renderer.cs:582-586`). **zdos do-not-copy:** the blink *phase* is host-timed
   in both refs. zdos renders the **blink-high (text fully visible)** phase by default — i.e. blinking
   text is shown lit — OR derives the phase from `cpu.st.cycles` (§6). Never from wall clock.
4. **Cursor (CRTC 0x0A/0x0B start/end scanlines, 0x0E/0x0F location).** The text cursor is drawn at
   the cell whose address equals the cursor location, on raster lines `[cursor_start, cursor_end]`,
   as the foreground color. dosbox `SkipCursor` + the cursor overlay (`vga_draw.cpp:849-892`);
   the cursor *blinks* on a host timer (`cursor.count & 0x10`, `:851`) — **do-not-copy**. zdos draws
   the cursor **solid** (always-on) or omits it, or derives blink from `cpu.st.cycles` (§6). The
   cursor cell comes from the BDA `OFF_CURSOR_POS` (already exposed by `/api/screen`,
   `controller.zig:679`) and shape from `OFF_CURSOR_SHAPE`.
5. **Index → DAC.** The resolved fg/bg internal indices pass through the AC → Color Select → DAC
   (§3.5/§3.6) to RGB.

Output resolution: `cols*char_width × rows*char_height` (e.g. 720×400 for mode 3, or 640×400 if
8-dot). The **index image** (§5) for text can be the cell grid itself (chars+attrs) — already what
`/api/screen` returns — plus a rendered pixel image for full-fidelity capture.

### 3.2 (reserved — text covered in 3.1)

### 3.3 CGA graphics (modes 4/5 = 320×200 2bpp, 6 = 640×200 1bpp)

CGA modes store pixels packed and use **interleaved scanline banks**: even scanlines at VRAM offset
0x0000, odd scanlines at 0x2000 (the CGA-compat bit-13 address wrap, §2.5; dosbox `address = (address*2)
& 0x1fff` for M_CGA4, `vga_draw.cpp:1542`; the 1bpp/2bpp draw uses `vidstart & 0x1fff` masks via
`tandy.addr_mask`). Per output pixel:

- **Mode 6 (640×200×1):** `bit = (byte >> (7 - (x & 7))) & 1`; 2-color (CGA palette index 0/1). dosbox
  `VGA_Draw_1BPP_Line` (`vga_draw.cpp:110-123`, `CGA_2_Table` expands a byte to 8 pixels).
- **Modes 4/5 (320×200×2):** `pix = (byte >> (6 - 2*(x & 3))) & 3`; 4 colors from the CGA palette
  (palette set + intensity from the CGA color-select; mode 5 is the alt cyan/magenta/white palette).
  dosbox `VGA_Draw_2BPP_Line` + `CGA_4_Table` (`vga_draw.cpp:125-137`); spice86's CGA-shift decode
  `DrawCgaModeGraphics` interleaves planes 0/2 then 1/3 (`Renderer.cs:607-619`) — that is the VGA's
  emulation of CGA on planar memory; on a true CGA the 2 bits come from one packed byte.

The CGA palette → DAC: on a real CGA these are fixed RGBI colors; on VGA-emulating-CGA they route
through the AC's 16 internal entries → DAC (the BIOS loads the CGA palette into the DAC). zdos
captures via the same AC→DAC path (§3.5) so the CGA color-select register selects among the standard
palettes. Output res: 320×200 or 640×200 (double-scanned to 400 raster lines, §2.3).

### 3.4 EGA 16-color planar (modes 0Dh-10h; 12h = 640×480×16)

Four bit-planes; each output pixel's 4-bit index is assembled one bit per plane at the same address:

```
bit = 7 - (x & 7)
index4 = (plane3>>bit & 1)<<3 | (plane2>>bit & 1)<<2 | (plane1>>bit & 1)<<1 | (plane0>>bit & 1)
```

(spice86 `DrawEgaModeGraphics` `Renderer.cs:621-626`; dosbox routes EGA/LIN4 through the planar reader
into `vga.attr.palette[]` then DAC). The 4-bit index → the AC's 16 internal-palette entries → Color
Select → DAC (§3.5). **Color Plane Enable (AC 0x12)** can mask planes out before the lookup (spice86
`_framePlanesEnabled`, `Renderer.cs:524-527`). Per-plane fetch uses the contiguous layout
`vram[P*0x10000 + addr]`. Modes:

| Mode | Res | Planes used | Notes |
|------|-----|-------------|-------|
| 0Dh | 320×200×16 | 4 | double-scan |
| 0Eh | 640×200×16 | 4 | double-scan |
| 0Fh | 640×350×2 (mono) | 1-2 | EGA mono |
| 10h | 640×350×16 | 4 | |
| 11h | 640×480×2 | 1 | 60 Hz (525-line) |
| 12h | 640×480×16 | 4 | 60 Hz (525-line) |

### 3.5 VGA 256-color (13h linear; Mode X/Y unchained planar)

- **Mode 13h (linear chained 256):** one byte per pixel, `index = vram[start_bytes + y*width + x]`.
  The 8-bit index goes **straight to the DAC** (the AC is in 256-color "8-bit" mode — see §3.6;
  no 16-entry indirection). dosbox `draw_unwrapped_line_from_dac_palette` / `VGA_Draw_Linear_Line`
  (`vga_draw.cpp:401-474`); spice86 256-color path `RenderDirect256` reads `VRam[physical*4+plane]`
  but for chained the 4 consecutive plane bytes are the 4 consecutive pixels (`Renderer.cs:407-419`).
  zdos's chained capture reads `vram[off]` directly (matching the A000 mapping, `vga.zig:295-308`).
- **Mode X / Mode Y (unchained planar 256):** chain-4 cleared, so the 4 planes hold every 4th pixel.
  Pixel `(x, y)` → `plane = x & 3`, `addr = start + y*(offset*2) + (x >> 2)`, `index = vram[plane*0x10000
  + addr]`. This is the **Mode-X de-interleave** (`plans/lamut-milestone.md` W5: "plane `x & 3`, byte
  offset `start + y*80 + (x>>2)`" for 320-wide). The 8-bit index → DAC directly. **This is LAMUT's
  capture mode** — the planar VRAM write path (Map Mask fan-out) is W2/P5; this spec is the read-back
  de-interleave.

> **Note on x&3 vs x&4.** The prompt's "plane = x&4" shorthand refers to the *write*-side latch
> stride some Mode-X engines use; the *display* de-interleave is `plane = x & 3` (4 planes, every 4th
> pixel), `addr = x >> 2`. zdos uses `x & 3` / `x >> 2` for read-back (consistent with the LAMUT plan).

### 3.6 The attribute pipeline (the shared 16-color → DAC index path)

For text + CGA + EGA (the ≤16-color modes), the resolved 4-bit index is NOT a DAC index directly — it
passes through the Attribute Controller, exactly as hardware does (dosbox `VGA_ATTR_SetPalette`,
`vga_attr.cpp:60-81`; spice86 builds `AttributeMap[16]`, `DacRegisters.cs:33`):

```
0. index &= AC.color_plane_enable                 // Color Plane Enable masks the INDEX (planes feeding
                                                  //   the AC), BEFORE the palette lookup (AC 0x12)  [FIX S2]
1. internal = AC.palette[index & 0x0F]            // 16 internal-palette regs (AC 0x00-0x0F), 6-bit each
2. if AC.mode_control.palette_bits_5_4_select:    // AC 0x10 bit 7
        dac_idx = (internal & 0x0F) | (color_select << 4)        (vga_attr.cpp:71-73)
   else:
        dac_idx = internal                                       // 6-bit internal value
3. dac_idx |= (color_select & 0x0C) << 4          // high 2 bits from Color Select (AC 0x14) (vga_attr.cpp:77)
4. rgb = DAC[dac_idx & pel_mask]                  // §3.7
```

> **FIX (review S2) — Color-Plane-Enable masks the INDEX, not the 6-bit palette output.** The earlier
> draft applied `& color_plane_enable` to the *internal* (post-lookup, 6-bit) value. On real hardware
> (dosbox `vga_attr.cpp:68`: `vga.attr.palette[i & vga.attr.color_plane_enable]`) the mask is applied
> to the **4-bit attribute index** — i.e. it gates which display *planes* reach the palette lookup —
> so it must come *before* `AC.palette[index]`, as step 0 above. Masking the 6-bit output would zero
> palette bits, not disable planes — a different, wrong result.

**The 256-color bypass:** in 8-bit (256-color) mode (AC Mode Control 0x10 bit 6 / GC 256-color bit),
the 8-bit pixel skips steps 1-4 entirely and indexes the DAC directly (dosbox `M_VGA`/`M_LIN8` use the
`palette_map` directly; spice86 `in256ColorMode` path uses `paletteMap` not `attrMap`,
`Renderer.cs:192-213`). zdos's mode-13h/Mode-X capture takes this bypass.

### 3.7 The DAC (6-bit → 8-bit) and the Pel Mask

The DAC stores 256 entries of 6-bit R/G/B (`dac_rgb`, `vga.zig:165`). The lookup:

```
masked_idx = dac_idx & pel_mask          // Pixel Mask register 0x3C6 (vga.zig:185)
(r6, g6, b6) = dac_rgb[masked_idx]
r8 = expand6to8(r6); g8 = ...; b8 = ...
```

**6→8 expansion — pick ONE convention and pin it.** The two references disagree:
- spice86: `c8 = (c << 2) | (c >> 4)` (`ArgbPalette.cs:22-24`) — bit replication.
- dosbox-staging: `c8 = (c*259 + 33) >> 6` (`utils/rgb.h:22-27`), which equals the rounded
  `(c*255 + 31)/63`.

These produce **different bytes** (e.g. c=63: both give 255; c=32: replication → 130, rounded →
130; c=1: replication → 4, rounded → 4; divergence is small but nonzero mid-range). **zdos pins the
bit-replication form `(c << 2) | (c >> 4)`** — it is the spice86 convention, integer-only, matches
the `plans/lamut-milestone.md` W5 candidate, and is the most common emulator convention. Document the
choice at the call site; it is comptime-fixed. **Determinism note:** for the index-image oracle (§5)
the 6→8 convention is irrelevant (indices compared pre-DAC), so the only place it matters is the RGBA
byte hash — and that hash is compared against a zdos-minted golden using the same convention (LAMUT
W6 strategy B), so the divergence with dosbox's rounding is a non-issue.

The **Pel Mask 0x3C6** (default 0xFF, `vga.zig:185`) ANDs the DAC index before lookup — palette-split
effects use it. The capture honors it.

---

## 4. dosbox-staging vs spice86 — copy / avoid table (file:line)

| Aspect | dosbox-staging | spice86 | zdos decision |
|--------|----------------|---------|---------------|
| Per-pixel address pipeline (start/offset/byte-word-dword/line-compare/panning) | `vga_draw.cpp:1379-1654` (walking draw state) | `Renderer.cs:135-254,532-559` (clean `VgaAddressMapper`) | **Copy spice86's `ComputeAddress` formulas** (clearest); compute per-pixel in the capture (no walking state) |
| CRTC register packing (overflow/max-scan-line high bits) | `vga_draw.cpp:1833-1919` | `Crt*Registers` per-field | **Copy dosbox's packing** as the eventual programmable-CRTC spec (§1.2); use fixed table now (D-RT1) |
| Text glyph + attr + fg/bg | `vga_draw.cpp:857-893` | `Renderer.cs:561-596` | Copy decode; **font from bundled ROM** (no plane-2 upload, D-TM1) |
| EGA 4-plane bit assembly | planar reader → `attr.palette` | `DrawEgaModeGraphics` `Renderer.cs:621-626` | **Copy spice86** (explicit bit loop) |
| CGA 1bpp/2bpp decode | `VGA_Draw_1BPP/2BPP_Line` `vga_draw.cpp:110-137` | `DrawCgaModeGraphics` `Renderer.cs:607-619` | Copy dosbox packed decode (true CGA byte layout) |
| 256-color linear | `draw_unwrapped_line_from_dac_palette` `vga_draw.cpp:435-474` | `RenderDirect256` `Renderer.cs:396-424` | Copy; chained → direct `vram[off]` |
| Mode-X de-interleave | (planar reader) | (planar reader) | **`plane=x&3, addr=x>>2`** (LAMUT W5) |
| Attribute pipeline (plane-enable / color-select / 5-4-select) | `vga_attr.cpp:60-81` | `AttributeMap` build | **Copy dosbox `VGA_ATTR_SetPalette`** (exact) |
| 256-color AC bypass | `M_VGA` uses `palette_map` | `in256ColorMode` path `Renderer.cs:192-213` | Copy (bypass AC for 8-bit) |
| DAC 6→8 | `(c*259+33)>>6` rounding `rgb.h:22` | `(c<<2)\|(c>>4)` replication `ArgbPalette.cs:22` | **Pick spice86 replication**, pin at comptime (§3.7) |
| Pel mask | `dac.pel_mask` `vga_dac.cpp:170` | `PixelMask` | Copy (AND before lookup) |
| **Frame draw loop (per-scanline event)** | `PIC_AddEvent(VGA_DrawSingleLine,...)` `vga_draw.cpp:1249` | `VgaTimingEngine` scanline events | **AVOID** — capture renders whole frame on demand, no draw loop |
| **Text blink phase** | `vga.draw.blink` host ms `vga_draw.cpp:1534`; `VGA_SetBlinking:1334` | `BlinkPeriodMs=500.0` `VgaTimingEngine.cs:13` | **AVOID** — render blink-high, or `f(cycles)` (§6) |
| **Cursor blink** | `cursor.count & 0x10` host-timed `vga_draw.cpp:851` | host blink state | **AVOID** — solid cursor / omit / `f(cycles)` |
| **Refresh / frame timer** | `PIC_FullIndex()` ms `vga_misc.cpp` | `IEmulatedClock + _jitter` `CyclesClock.cs` | **AVOID** — already replaced by cycle-derived 0x3DA (`vga.zig:476`); capture uses no timer |
| Front/back buffer swap on retrace | `RENDER_EndUpdate` | `CompleteFrame` buffer swap `Renderer.cs:260-275` | **AVOID** — no buffering; capture reads live VRAM |
| Hardware mouse cursor overlay | `VGA_Draw_LIN*_HWMouse` `vga_draw.cpp:661,743` | n/a | **Omit** (SVGA only; out of scope) |

---

## 5. The framebuffer-capture interface (`GET /api/framebuffer`)

A side-effect-free render mirroring the text `/api/screen` peek (`controller.zig:671-699`) — a pure
read of guest state producing a `width×height` buffer for the **current** mode. Used by a future
`GET /api/framebuffer` (LAMUT W5/P6).

### 5.1 What it reads (all via the pure peek path)

- BDA `OFF_VIDEO_MODE` (+ the GC/AC/Sequencer mode bits once those register files exist) → dispatch.
- The CRTC start address / offset / max-scan-line / line-compare / mode-control (§2) — from the CRTC
  register file (LAMUT P4) or, until then, the fixed per-mode defaults.
- The AC internal palette / color-plane-enable / color-select / mode-control (§3.6) — AC file (P4).
- VRAM planes (`vram`, via `peekBlock`/`peek8`, never `read8`, never `in8` — `in8` would mutate the
  0x3DA attribute flip-flop, `vga.zig:479`).
- The 256-entry 6-bit DAC + pel mask (`dac_rgb`, `pel_mask`) — read as **raw fields**, not through the
  port state machine (`read3c9` mutates `dac_read_index`, `vga.zig:436-458`).

All reads are pure; the capture **must not** advance cycles or mutate any device field (assert
cycle-neutrality in a test, mirroring the M1/M2 cycle-neutral audits referenced in
`plans/lamut-milestone.md` W5). **The test must explicitly assert these three side-effect-free
invariants (review R3/R6),** since each has a tempting mutating accessor the render must avoid:
- **DAC read/write index unchanged** — render via the raw `dac_rgb`/`pel_mask` fields, never `read3c9`
  (which advances `dac_read_index`, `vga.zig:436-458`).
- **AC flip-flop unchanged** — render via the raw `attr.regs[]`/`attr.index`, never an `in8(0x3DA)`
  (which resets `attr_flip_flop_is_index`, `vga.zig:479`) or a 0x3C0 read.
- **The 4 plane latches unchanged** — the de-interleave reads the planes directly from the slab
  (§2/§7), never through `memRead8` (which loads all 4 latches, `02-memory-engine.md §3`).
Snapshot the full `Vga.Snapshot` before and after a capture and assert byte-equality.

### 5.2 Output format

The response provides BOTH, per the LAMUT oracle plan:

1. **Index image** (`width × height` bytes of palette indices, pre-DAC) — the
   **convention-independent oracle** (`plans/lamut-milestone.md`: `lamut_0.idx` ground truth survives
   any DAC-scaling convention). For ≤16-color modes the index is the final DAC index after the AC
   pipeline (§3.6); for 256-color it is the raw VRAM byte. This is the primary regression surface.
2. **RGBA image** (`width × height × 4` bytes, raw) — index → DAC → 6→8 expand → RGBA (§3.7). For the
   pixel-hash golden. PNG encoding, if wanted, happens **host-side in the test**, never in the
   emulator (keep the encoder out of the determinism boundary — `plans/lamut-milestone.md` W6).

Dimensions per mode (logical resolution; double-scan recorded as a flag, §2.3):

| Mode | Width × Height | bpp / kind |
|------|----------------|------------|
| 0, 1 | 40×25 cells (320×200 px @ 8-dot, or 360×400 @ 9-dot) | text |
| 2, 3 | 80×25 cells (640×400 / 720×400 px) | text |
| 7 | 80×25 cells (720×400 px) | mono text |
| 4, 5 | 320×200 | CGA 2bpp |
| 6 | 640×200 | CGA 1bpp |
| 0Dh | 320×200 | EGA 16 |
| 0Eh | 640×200 | EGA 16 |
| 0Fh | 640×350 | EGA mono |
| 10h | 640×350 | EGA 16 |
| 11h | 640×480 | EGA 2 |
| 12h | 640×480 | EGA 16 |
| 13h | 320×200 | VGA 256 linear |
| Mode-X/Y | 320×200 (or 320×240, 360×240 per CRTC) | VGA 256 planar |

For text modes the capture also returns the existing `/api/screen` cell grid (chars+attrs) — the two
endpoints coexist: `/api/screen` is the cheap text-grid peek (already shipped), `/api/framebuffer` is
the rendered pixel/index image for any mode.

### 5.3 Plumbing — server-owned render buffer + binary streaming (NOT the inline-POD `Response`) [FIX B1]

> **BLOCKING FIX (review B1).** `/api/framebuffer` **cannot** mirror `/api/screen`'s pattern. `screen()`
> returns its grid inside the value-returned `Response` struct through a stack-allocated `RequestCtx`
> into a **32 KiB `resp_buf`** — but a rendered frame is **64 KiB (mode 13h index) to ~1.2 MB
> (640×480 RGBA)**. It does not fit in `resp_buf`, and copying it by value through `Response`/`RequestCtx`
> would blow the stack. The framebuffer needs a different transport:
>
> - **A server-owned, fixed-capacity render buffer**, allocated once at startup (NOT per-request, NOT
>   on the stack): `index_buf: [640*480]u8` + `rgba_buf: [640*480*4]u8` (≈ 1.5 MB total, owned by the
>   API server, reused every capture). This honors the project's no-per-op-alloc / fixed-slab discipline.
> - **The controller command writes the rendered index (and optionally RGBA) into that server buffer**
>   via the pure peek render (§5.1), returning only a small POD descriptor `{mode, width, height,
>   index_len, rgba_len}` through the normal `Response` path.
> - **The server then streams the buffer as a raw binary body** (`Content-Type: application/octet-stream`,
>   `Content-Length: <len>`), writing directly from the server-owned buffer to the socket — it does
>   **not** route the pixels through `resp_buf`/JSON. Query `?format=index|rgba` (default index) selects
>   which buffer to stream; the descriptor goes in headers (e.g. `X-Frame-Width`) or a tiny JSON
>   prefix the client reads before the binary body. PNG, if wanted, is encoded **host-side in the
>   client/test**, never in the emulator (keeps the encoder out of the determinism boundary).
>
> Everything else still mirrors `screen()`: the `queue`/`worker`/`server` one-command-in-flight model,
> the side-effect-free render, the determinism guarantees. Only the **transport of the large payload**
> differs — server-owned buffer + raw stream instead of value-returned struct.

Cycle-neutrality test mandatory (§5.1) — and additionally a **two-run byte-identity** test of the
streamed index + RGBA buffers at a fixed cycle.

### 5.4 The oracle (Stage 2, `plans/lamut-milestone.md`)

Capture at a fixed `runToCycle(N)` in the post-blit plateau; compare a **raw-RGBA pixel hash** (not a
PNG container — heed the Skia caveat). Cross-check the **index image** once against
`tools/lamut-oracle/lamut_0.idx` (DAC-convention-independent), then regress against a zdos-minted
golden (strategy B). The fixed cycle N is zdos-specific (no cycle-ledger holes → differs from
spice86's), picked empirically once the run is green.

---

## 6. Determinism: blink / cursor / refresh — the deterministic substitutes

The references' host-timed display state and zdos's required substitute:

| Host-timed thing (do not copy) | Reference | zdos substitute |
|--------------------------------|-----------|-----------------|
| Per-scanline draw timer | dosbox `PIC_AddEvent(VGA_DrawSingleLine)` `vga_draw.cpp:1249`; spice86 scanline events | **None** — render whole frame on demand, spatially |
| Text blink phase | dosbox `vga.draw.blink` `:1534`; spice86 `BlinkPeriodMs=500` `VgaTimingEngine.cs:13` | **Blink-high (text lit) by default**, OR `phase = (cpu.st.cycles / BLINK_CYCLES) & 1` with `BLINK_CYCLES` a comptime integer (≈ `FRAME_CYCLES*16`, the hardware 16-frame blink) |
| Cursor blink | dosbox `cursor.count & 0x10` `:851` | **Solid cursor** (always drawn) OR omit OR same `f(cycles)` phase |
| Refresh / frame start time | dosbox `PIC_FullIndex()`; spice86 `_clock.ElapsedTimeMs + _jitter` | Already replaced: cycle-derived 0x3DA (`vga.zig:476-498`); capture uses **no** time |
| Frame buffer swap on retrace | dosbox `RENDER_EndUpdate`; spice86 `CompleteFrame` swap `Renderer.cs:268` | **None** — capture reads live VRAM (the displayed page via start address) |
| `_jitter.Advance()` in clock | spice86 `CyclesClock.cs:21-22` | **Never** — pure `u64` cycles only |
| `double`/`fmod` ms timing | both | **Never** — integer cycles only (the `vga.zig` grep gate, `pit_test.zig:53-58`, must cover the new render code too) |

**Recommendation:** default the capture to **blink-high + solid cursor** (the "everything visible"
phase). This is the most useful for black-box assertions (text is always present), is trivially
deterministic, and matches what an index-image oracle wants. Expose the optional cycle-derived phase
behind a flag if a test ever needs to assert a blink-off frame. **Never** read a host clock for any of
it. Add the new render module to the float/host-clock grep gate.

---

## 7. zdos's gap and the recommended Zig design

### 7.1 The gap (cited)

- **No rasterizer at all.** `vga.zig` has VRAM + DAC + 0x3DA + text slabs but no
  index/pixel render. `/api/framebuffer` does not exist; `/api/screen` is text-grid only
  (`controller.zig:671-699`).
- **No CRTC / Sequencer / GC / AC register files.** The capture's addressing (§2) and attribute
  pipeline (§3.6) need them; today `0x3C0` asserts (`vga.zig:531`), `0x3C4/0x3CE/0x3D4` data is
  dropped / reads 0xFF (`vga.zig:513,532`). **These register files are a prerequisite** (LAMUT P3/P4);
  this spec defines what the rasterizer reads from them.
- **No bundled ROM font** (text glyph render, §3.1) — same staging requirement as LAMUT AH=1130h W1b.
- **No per-mode timing table** beyond the single 70 Hz family (`vga.zig:122-128`); §1.3 adds the
  525-line 60 Hz entry for 11h/12h.

### 7.2 Recommended design

- **A pure `render` module** (e.g. `src/devices/vga_render.zig` or methods on `Vga`) taking
  `*const Vga` (+ a BDA/CRTC view) and a destination buffer, dispatching on mode to per-family
  functions: `renderText`, `renderCga`, `renderEga`, `render256Linear`, `render256Planar`. Each is a
  **pure function** (no `self` mutation; `const` receiver where possible). The address math uses
  spice86's `ComputeAddress` formulas (§2.5) as small inline helpers; the attribute pipeline (§3.6)
  is one shared `acResolve(index) -> dac_idx` helper; the DAC expand (§3.7) is one
  `expand6to8` + `dacRgba(idx)` helper.
- **Output: index buffer first, RGBA derived.** Render to a `[]u8` of palette indices (the oracle
  surface), then a second pass `indices → RGBA` via the DAC. Keep both as fixed-capacity buffers
  (the project's POD/no-per-op-alloc discipline; max = 640×480 indices + ×4 RGBA).
- **No walking state.** Compute each pixel's address from `(x, y)` + latched registers (§2.7). This
  is *simpler* than the references (which carry draw-loop state) and is the natural fit for a static
  capture.
- **Determinism gate.** Add the render module to the float/host-clock grep gate
  (`src/devices/pit_test.zig:53-58`); assert cycle-neutrality of the capture (no `cpu.st.cycles`
  change across a render); two-run byte-identity of the index + RGBA buffers at a fixed cycle.
- **Bundle the IBM VGA fonts** (8×8, 8×14, 8×16) as comptime byte arrays (real ROM data) selected by
  BDA char height — shared with the AH=1130h ROM-font requirement (LAMUT W1b).

### 7.3 Phasing (defer to / align with the LAMUT milestone)

1. Mode-13h linear capture (index + RGBA) — needs only the existing VRAM + DAC; no register files.
   This is the **first deliverable** and unblocks the simplest visual oracle.
2. Mode-X/Y planar capture — after LAMUT W2/P5 (planar VRAM + Sequencer/GC). The LAMUT Stage-2 gate.
3. Text-mode pixel capture — needs the bundled ROM font + AC pipeline (for color); the cell grid is
   already available via `/api/screen`.
4. EGA/CGA capture — after the AC register file (P4); lower priority (no v1 target uses them, but the
   spec is complete so they can be added without redesign).

---

## 8. Synthesis (the checklist this spec satisfies)

**Modes the rasterizer must cover (none omitted):** text 0,1 (40×25), 2,3 (80×25 color), 7 (80×25
mono); CGA 4,5 (320×200×2), 6 (640×200×1); EGA 0Dh (320×200×16), 0Eh (640×200×16), 0Fh (640×350
mono), 10h (640×350×16), 11h (640×480×2), 12h (640×480×16); VGA 13h (320×200×256 linear) and
Mode-X/Y (320×200/240 256 planar).

**Addressing features:** start address (page flip), offset/stride (logical width), max-scan-line
(char height / double-scan / line doubling), line compare (split screen → address resets to 0),
byte/word/dword address transforms (CRTC Mode Control 0x17 + Underline 0x14), pixel panning (AC 0x13,
256-color bits 0-2 ×2, 9-dot +1, line-compare-compat gating). Composite formula in §2.7.

**Pipelines:** attribute (internal-16 → color-plane-enable → color-select 4+2 high bits → DAC index)
with the **256-color bypass**; DAC 6→8 via `(c<<2)|(c>>4)` (pinned) AND pel-mask.

**Host-timing-to-avoid list:** per-scanline draw timer; text blink phase; cursor blink; refresh/
frame-start wall/emulated-ms clock; front/back buffer swap on retrace; `_jitter`; `double`/`fmod`
timing. All replaced by: whole-frame on-demand spatial render, blink-high+solid-cursor default (or
`f(cpu.st.cycles)`), the existing cycle-derived 0x3DA, no buffering, integer-only math, grep-gated.

**Capture interface:** `GET /api/framebuffer` — a pure peek (no cycle charge, no field mutation, no
`in8`/`read3c9`) returning, for the current mode, an **index image** (convention-independent oracle)
AND a **raw RGBA image** at logical resolution; mirrors `screen()` plumbing; cycle-neutral; two-run
byte-identical; compared via raw-pixel hash + index cross-check (`lamut_0.idx`).
