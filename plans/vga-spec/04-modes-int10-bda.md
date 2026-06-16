# VGA BIOS layer — video modes, mode parameter tables, the full INT 10h API, and the BDA video state

Status: **design spec** (no source changed). Companion to `01-registers.md` (the register files INT 10h
programs) and `02-memory-engine.md` (the CPU↔VRAM path teletype/scroll/put-pixel drive). This section is
the **configuration / BIOS** side: how a faithful set-mode programs the hardware for each standard mode,
the complete INT 10h function set (every AH + AL/BL subfunction), the complete BDA video area, and the
ROM font / character-generator. Every behavior is cited `file:line` against **dosbox-staging** and
**spice86**, plus the authoritative IBM VGA BIOS behavior.

> Scope note: zdos's v1 target is BaK + LAMUT (real-mode 386, mode 13h linear + Mode-Y planar + text).
> This spec covers the **complete** standard mode set (text 0-3,7; CGA 4-6; EGA 0Dh-10h; VGA 11h,12h,13h)
> and Mode X/Y as the owner asked — "this is not a toy." VESA/SVGA (mode ≥ 0x100, INT 10h AH=4Fh) is
> explicitly **out of scope** (BaK/LAMUT are non-VESA; flag if a guest ever calls AH=4Fh). The text
> services AH=00/01/02/03/06/07/08/09/0A/0E/0F/13 are **already implemented** (`plans/text-mode-video.md`);
> this spec completes the set (AH=04/05/0B/0C/0D/10h full/11h/12h/1Ah/1Bh/1Ch) and the per-mode register
> programming behind AH=00.

---

## 0. The two reference structures — pick spice86's per-mode register table

There are two ways the references encode "what a set-mode programs":

1. **dosbox-staging — geometry table + computed registers.** `ModeList_VGA` is a `VideoModeBlock`
   table of *geometry* (`int10_modes.cpp:28-233`): `{mode, type, swidth, sheight, twidth, theight,
   cwidth, cheight, ptotal, pstart, plength, htotal, vtotal, hdispend, vdispend, special}`. The actual
   CRTC/SEQ/GC/AC **register values are computed at set-mode time** from that geometry by a long
   procedure (`INT10_SetVideoMode`, `int10_modes.cpp:1153-2203`) — e.g. CRTC reg 0 = `htotal-5`, the
   overflow bits are split out by hand, etc. Faithful, but the register values are scattered across ~600
   lines of arithmetic.

2. **spice86 — explicit per-mode register-value table (the IBM VGA BIOS format).** `VgaModes` is a
   `Dictionary<int, VideoMode>` keyed by mode number (`Data/RegisterValueSet.cs:41-58`), where each entry
   carries the **literal register blocks** the real IBM/clone BIOS POST tables contain:
   `{VgaMode geometry, PixelMask, Palette, SequencerRegisterValues[5], MiscellaneousRegisterValue,
   CrtControllerRegisterValues[25], AttributeControllerRegisterValues[21], GraphicsControllerRegisterValues[9]}`
   (`Records/VideoMode.cs:13-22`). Set-mode is then a trivial **blind register dump**
   (`FillRegisters`, `VgaFunctionality.cs` — AC, then SEQ, then GC, then disable CRTC write-protect,
   then the 25 CRTC regs, then misc-output). The register values are the **canonical IBM VGA BIOS mode
   tables** verbatim.

> **zdos decision — adopt spice86's explicit per-mode register table.** It IS the IBM VGA BIOS table
> (the authoritative source the prompt asks for), it is fixed comptime data (no host clock, perfectly
> deterministic — CLAUDE #5), and it makes set-mode a register dump into the device's SEQ/CRTC/GC/AC/DAC
> register files (already specified in `01-registers.md`). dosbox's computed approach would re-derive the
> same bytes through hundreds of lines of bit-twiddling that only matter for SVGA/VESA modes zdos doesn't
> support. **Copy the spice86 `VgaModes` table values** (`Data/RegisterValueSet.cs:7-58`), cross-checked
> against dosbox's computed values for the v1 modes (13h, 03h) — they agree. Keep dosbox's `VideoModeBlock`
> geometry table as the *reference* for `pstart`/`plength`/`ptotal`/`swidth`/`sheight` (the dimensions
> spice86 packs into its compact `VgaMode` record).

---

## 1. The standard video mode set + per-mode parameter table

### 1.1 The geometry table (dosbox `ModeList_VGA`, `int10_modes.cpp:28-45`)

The 14 standard modes zdos supports. Columns: `mode` (BIOS number), `type` (memory model),
`sw×sh` (pixel resolution), `tw×th` (text cols×rows), `cw×ch` (char cell w×h), `pt` (page count),
`pstart` (VRAM window base), `plength` (page size bytes). All values verbatim from
`int10_modes.cpp:30-45`.

| mode | type   | sw×sh   | tw×th | cw×ch | pt | pstart  | plength | colors | notes |
|------|--------|---------|-------|-------|----|---------|---------|--------|-------|
| 0x00 | M_TEXT | 360×400 | 40×25 | 9×16  | 8  | 0xB8000 | 0x0800  | 16     | 40-col color text, EGA_HALF_CLOCK |
| 0x01 | M_TEXT | 360×400 | 40×25 | 9×16  | 8  | 0xB8000 | 0x0800  | 16     | identical layout to 0 |
| 0x02 | M_TEXT | 720×400 | 80×25 | 9×16  | 8  | 0xB8000 | 0x1000  | 16     | 80-col color text |
| 0x03 | M_TEXT | 720×400 | 80×25 | 9×16  | 8  | 0xB8000 | 0x1000  | 16     | **boot mode** (`bda.zig:108`) |
| 0x04 | M_CGA4 | 320×200 | 40×25 | 8×8   | 1  | 0xB8000 | 0x4000  | 4      | CGA 4-color, EGA_HALF_CLOCK\|EGA_LINE_DOUBLE |
| 0x05 | M_CGA4 | 320×200 | 40×25 | 8×8   | 1  | 0xB8000 | 0x4000  | 4 (gray) | CGA 4-color (alt palette) |
| 0x06 | M_CGA2 | 640×200 | 80×25 | 8×8   | 1  | 0xB8000 | 0x4000  | 2      | CGA 2-color, EGA_LINE_DOUBLE |
| 0x07 | M_TEXT | 720×400 | 80×25 | 9×16  | 8  | 0xB0000 | 0x1000  | mono   | **mono text** (MDA window B0000) |
| 0x0D | M_EGA  | 320×200 | 40×25 | 8×8   | 8  | 0xA0000 | 0x2000  | 16     | EGA planar, HALF_CLOCK\|LINE_DOUBLE |
| 0x0E | M_EGA  | 640×200 | 80×25 | 8×8   | 4  | 0xA0000 | 0x4000  | 16     | EGA planar, LINE_DOUBLE |
| 0x0F | M_EGA  | 640×350 | 80×25 | 8×14  | 2  | 0xA0000 | 0x8000  | mono   | EGA mono planar (CRTC 0x3B4) |
| 0x10 | M_EGA  | 640×350 | 80×25 | 8×14  | 2  | 0xA0000 | 0x8000  | 16     | EGA hi-res planar |
| 0x11 | M_EGA  | 640×480 | 80×30 | 8×16  | 1  | 0xA0000 | 0xA000  | 2      | VGA 2-color planar |
| 0x12 | M_EGA  | 640×480 | 80×30 | 8×16  | 1  | 0xA0000 | 0xA000  | 16     | VGA 16-color planar |
| 0x13 | M_VGA  | 320×200 | 40×25 | 8×8   | 1  | 0xA0000 | 0x2000  | 256    | **linear 256-color** (BaK) |

Memory-model → memory engine cross-ref (`02-memory-engine.md`): `M_TEXT` = odd/even char/attr at
B8000/B0000 (`§4.3`); `M_CGA2`/`M_CGA4` = CGA-compat at B8000 (`§4.6`); `M_EGA` = 16-color planar
(`§4.5`); `M_VGA` = chained 256-color (`§4.1`). **Mode-Y** is mode 13h's geometry with the chain-4 bit
cleared — see §1.4.

> dosbox keeps four more VGA-internal text variants (`ModeList_VGA_Text_200lines`/`_350lines`,
> `int10_modes.cpp:235-250`) selected by the BDA `MODESET_CTL` scan-line bits (INT 10h AH=12h BL=30h).
> v1 uses the 400-line default (`int10_modes.cpp:30-45`); flag if a guest sets 200/350-line text via
> AH=12h BL=30h before a text mode-set (BaK/LAMUT don't).

### 1.2 The per-mode register parameter table (spice86 `VgaModes`, the IBM VGA BIOS tables)

For each mode, set-mode programs the **full register block**. The literal values below are the spice86
`VgaModes` entries (`Data/RegisterValueSet.cs:42-57`), which are the IBM/clone VGA BIOS POST mode
tables. Format the zdos table as comptime data indexed by mode number:

```zig
// src/bios/vga_modes.zig (NEW). Comptime-constant — deterministic (CLAUDE #5).
pub const MemModel = enum { text, cga, planar, packed_256 };
pub const ModeEntry = struct {
    mode: u16,
    model: MemModel,
    width: u16,        // pixel width
    height: u16,       // pixel height
    bpp: u8,           // bits per pixel (text: nominal 4)
    cwidth: u8,        // char cell width  (9 for text, 8 graphics)
    cheight: u8,       // char cell height (16/14/8)
    pstart: u32,       // VRAM window base (0xB8000/0xB0000/0xA0000)
    plength: u16,      // page size bytes
    ptotal: u8,        // page count
    misc_output: u8,   // 0x3C2 value
    seq: [5]u8,        // sequencer regs 0..4
    crtc: [25]u8,      // CRTC regs 0..0x18
    attr: [21]u8,      // attribute regs 0..0x14 (0x10-0x14 are mode/overscan/...)
    gfx: [9]u8,        // graphics-controller regs 0..8
    pixel_mask: u8,    // DAC pel mask (always 0xFF)
    palette: PaletteId,// which default DAC palette to load (ega/cga/vga/mono)
};
```

**The register-value sets** (deduplicated like spice86; `Data/RegisterValueSet.cs:7-39`). The per-mode
assignment uses these sets:

```
SEQ sets (reg 0..4):
  SEQ1 = {03,08,03,00,02}   modes 0/1   (40-col text, double-width)
  SEQ2 = {03,00,03,00,02}   modes 2/3/7 (80-col text)
  SEQ3 = {03,09,03,00,02}   modes 4/5   (CGA 4-color)
  SEQ4 = {03,01,01,00,06}   mode  6     (CGA 2-color)
  SEQ5 = {03,09,0f,00,06}   mode  0D    (EGA 40-col planar)
  SEQ6 = {03,01,0f,00,06}   modes 0E/0F/10/11/12 (EGA/VGA planar)
  SEQ7 = {03,01,0f,00,0e}   mode  13    (chain-4 256-color; reg4=0x0E)

CRTC sets (reg 0..0x18, 25 bytes):
  CRTC1 modes 0/1, CRTC2 modes 2/3, CRTC3 modes 4/5, CRTC4 mode 6,
  CRTC5 mode 7, CRTC6 mode 0D, CRTC7 mode 0E, CRTC8 mode 0F/10,
  CRTC9 mode 11/12, CRTC10 mode 13, CRTC11 mode 6A (800x600).
  e.g. CRTC10 (mode 13h) = {5f,4f,50,82,54,80,bf,1f,00,41,00,00,00,00,00,00,
                            9c,8e,8f,28,40,96,b9,a3,ff}
       — reg9=0x41 = 0b0100_0001: **bit0 (Max-Scan-Line low = 1 → 2-line row
         repeat) + bit6 (line-compare bit 9); bit7 (double-scan) is CLEAR**
         [FIX S1 — NOT the double-scan bit; see 03 §2.3]. reg0x14=0x40
         (underline, doubleword), reg0x17=0xa3 (mode control). Matches dosbox's
         computed M_VGA values (int10_modes.cpp:1471-1473,1603 → underline 0x40,
         max scanline |=1, mode_control 0xa3).
  e.g. CRTC2 (mode 3)  = {5f,4f,50,82,55,81,bf,1f,00,4f,0d,0e,00,00,00,00,
                          9c,8e,8f,28,1f,96,b9,a3,ff}

ATTR sets (reg 0..0x14, 21 bytes):
  ATTR1 modes 0/1/2/3 (text palette 0..F + mode 0x0C/0x08), ATTR2 modes 4/5,
  ATTR3 mode 6, ATTR4 mode 7 (mono), ATTR5 mode 0D/0E, ATTR6 mode 0F (mono gfx),
  ATTR7 mode 10/12/6A, ATTR8 mode 11, ATTR9 mode 13 (palette 0..F, mode reg 0x10=0x41).
  e.g. ATTR9 (mode 13h) = {00,01,...,0f, 0x41,00,0f,00,00}  (reg0x10=0x41: 8-bit color)

GFX sets (reg 0..8, 9 bytes):
  GFX1 = {00,00,00,00,00,10,0e,0f,ff}  text color (odd/even, mmap 0x0E=B8000)
  GFX2 = {00,00,00,00,00,30,0f,0f,ff}  CGA 4-color
  GFX3 = {00,00,00,00,00,00,0d,0f,ff}  CGA 2-color
  GFX4 = {00,00,00,00,00,10,0a,0f,ff}  mono text (mmap 0x0A=B0000)
  GFX5 = {00,00,00,00,00,00,05,0f,ff}  EGA/VGA planar (mmap 0x05=A0000/64K)
  GFX6 = {00,00,00,00,00,40,05,0f,ff}  mode 13h (reg5=0x40 256-color shift, mmap 0x05)

MISC_OUTPUT per mode:
  0x67 modes 0/1/2/3 (color, 28MHz 9-dot, 400-line)
  0x66 mode 7        (mono)
  0x63 modes 4/5/6/0D/0E/13 (color, 25MHz, 200/400-line)
  0xa3 mode 0F/10    (350-line)
  0xe3 mode 11/12    (480-line)
```

**Per-mode assignment** (`Data/RegisterValueSet.cs:42-57`):

| mode | misc | SEQ  | CRTC  | ATTR  | GFX  | palette | model         |
|------|------|------|-------|-------|------|---------|---------------|
| 0,1  | 0x67 | SEQ1 | CRTC1 | ATTR1 | GFX1 | EGA     | text 40×25    |
| 2,3  | 0x67 | SEQ2 | CRTC2 | ATTR1 | GFX1 | EGA     | text 80×25    |
| 4,5  | 0x63 | SEQ3 | CRTC3 | ATTR2 | GFX2 | CGA     | CGA 4-color   |
| 6    | 0x63 | SEQ4 | CRTC4 | ATTR3 | GFX3 | CGA     | CGA 2-color   |
| 7    | 0x66 | SEQ2 | CRTC5 | ATTR4 | GFX4 | mono    | text mono     |
| 0D   | 0x63 | SEQ5 | CRTC6 | ATTR5 | GFX5 | CGA     | EGA planar    |
| 0E   | 0x63 | SEQ6 | CRTC7 | ATTR5 | GFX5 | CGA     | EGA planar    |
| 0F   | 0xa3 | SEQ6 | CRTC8 | ATTR6 | GFX5 | mono    | EGA mono gfx  |
| 10   | 0xa3 | SEQ6 | CRTC8 | ATTR7 | GFX5 | EGA     | EGA hi-res    |
| 11   | 0xe3 | SEQ6 | CRTC9 | ATTR8 | GFX5 | EGA     | VGA 2-color   |
| 12   | 0xe3 | SEQ6 | CRTC9 | ATTR7 | GFX5 | EGA     | VGA 16-color  |
| 13   | 0x63 | SEQ7 | CRTC10| ATTR9 | GFX6 | VGA     | 256 linear    |

> **Cross-check vs dosbox (mode 13h).** dosbox computes misc-output `0x2|0x1|0x60` = `0x63`
> (`int10_modes.cpp:1240,1261`) — matches. dosbox SEQ for M_VGA: `seq[1]=0x01, seq[2]=0x0f, seq[4]=0x0e`
> (`:1270,1306,1307`) → `{03,01,0f,00,0e}` = SEQ7 — matches. dosbox GFX for M_VGA:
> `gfx[5]|=0x40, gfx[6]|=0x05, gfx[7]=0xf, gfx[8]=0xff` (`:1668-1694`) → GFX6 — matches. dosbox AC for
> M_VGA: `att[0..15]=ct, att[0x10]=0x41` (`:1872-1876`) → ATTR9 — matches. The two references agree
> byte-for-byte on the v1 modes; the spice86 literal table is the cleaner source.

### 1.3 The set-mode procedure (AH=00) — exact ordering

Mirror spice86 `VgaSetMode` (`VgaFunctionality.cs:229-284`); the dosbox ordering is equivalent
(`int10_modes.cpp:1153-2203`). zdos's set-mode is a **host-serviced trap** that does:

1. Resolve `mode = AL & 0x7F` (low 7 bits); `clearmem = (AL & 0x80) == 0` (bit 7 = no-clear). For mode
   ≥ 0x100, mask `& 0xFFF` and check bit 14/15 (VESA — out of scope, flag). dosbox `int10_modes.cpp:1157-1175`.
2. Look up the `ModeEntry`; if not found, return without changing state (real BIOS leaves AL undefined;
   dosbox logs + returns false `:1198`). **Flag** an unsupported standard mode rather than faking 13h.
3. **Load the default palette.** [FIX S3 — corrected gate location + scope.] The gating flag is the
   **MODESET_CTL byte at BDA 0x89 bit 3** ("default-palette-loading disabled"), **not** VIDEO_CTL 0x87
   — dosbox reads it via `vga_flags_rec` from the modeset-ctl offset (`:1186-1187,1898`), spice86
   `ModeFlags.NoPalette` (`:241`). It gates the **Attribute-Controller internal-palette load** (the 16
   EGA-attribute regs written in step 4); the **256-entry DAC palette is loaded unconditionally** at
   set-mode regardless of this bit. Writes 256×3 (or 16×3 for non-256 modes) 6-bit RGB to the DAC via
   `0x3C8`/`0x3C9` (the same port path INT 10h AL=12 uses; `01-registers.md §6`). The default palettes:
   `Palettes.Vga` (256-entry), `Palettes.Ega` (64-entry), `Palettes.Cga`, `Palettes.Monochrome`
   (spice86 `Data/Palettes.cs`; dosbox `palette.vga/.ega/.cga64/.mono_text`, `int10_modes.cpp:1936-1979`).
   *(Verify the exact AC-vs-DAC split against the set-mode oracle when implemented — surface, don't
   assume, if a corpus program sets the no-palette bit; the v1 BaK/LAMUT path leaves it clear.)*
4. **FillRegisters** (`VgaFunctionality.cs` FillRegisters; dosbox `:1326-1748,1903-1912`): write AC regs
   0..0x14 (via the 0x3C0 flip-flop), SEQ regs 0..4, GC regs 0..8, then disable CRTC write-protect
   (CRTC 0x11 bit 7 = 0), write CRTC regs 0..0x18, then write misc-output `0x3C2`. **This drives the
   device register files specified in `01-registers.md`.** Re-enable CRTC write-protect last
   (dosbox `:1604-1606`). All values are the §1.2 table.
5. **Enable video**: write `0x3C0 ← 0x20` (Palette Address Source = 1; AC index 0x20 turns the screen on,
   spice86 `:249`, dosbox `:1911,2192`).
6. **Clear VRAM** if `clearmem` (`finish_set_mode`, dosbox `int10_modes.cpp:811-864`; spice86 `:252`):
   - **M_TEXT**: word-fill the page with `0x0720` (space, attr 0x07) over the window (dosbox fills
     16K words at B800/B000, `:839`; zdos: fill `cols*rows` cells = `0x0720` — F6 in `text-mode-video.md`).
   - **M_VGA / M_EGA / planar**: zero the VRAM linear store (`memset(vga.mem.linear,0,...)`, dosbox `:857`).
   - **M_CGA2/M_CGA4**: word-fill B800 with `0x0000` (`:830`).
7. **Write fonts** to plane 2 for text modes (dosbox `INT10_ReloadFont`, `:2199`; spice86 `WriteFonts`,
   `:258`). zdos models the flat char/attr text slab (`text-mode-video.md` D-TM1), so the plane-2 font
   upload is **not guest-observable for text rendering** — but the ROM font bytes must still exist for
   AH=11h/AH=1130h (§4). Flag if a guest reads plane 2.
8. **Set the BDA** (`SetBiosDataArea`, `VgaFunctionality.cs:684-714`; dosbox `finish_set_mode:865-901`)
   — the complete field list in §3.2.
9. **Set INT 1Fh / INT 43h font vectors** to the ROM font matching `cheight` (dosbox `:883-891`; spice86
   `:264-281`): INT 1Fh → 8×8 second-half, INT 43h → the active cell-height font (8/14/16).
10. **Set cursor shape** `INT10_SetCursorShape(0x06,0x07)` for text (dosbox `:896`), **reset cursor pos
    pages 0..7** to (0,0), **set active page 0** (dosbox `:899-901`).

> zdos's existing `setMode` (`int10.zig:103-203`) does a *subset* of this for mode 13h + text (misc-output
> + BDA + VRAM clear). The gap: the full SEQ/CRTC/GC/AC register dump (steps 4-5) and the default DAC
> palette load (step 3). With `01-registers.md`'s register files + `02-memory-engine.md`'s engine in place,
> set-mode becomes the register dump above. **This is the central new work item for the BIOS layer.**

### 1.4 Mode X / Mode Y — derived unchained variants of mode 13h

Mode X/Y are **not BIOS modes** — no INT 10h number sets them. A program sets mode 13h via AH=00, then
**re-programs the registers directly via port writes** to clear chain-4 and (for Y) change the CRTC
height. zdos does NOT add a mode-table entry; it just must honor the port writes the guest issues
(the LAMUT overlay does exactly this — `lamut-milestone.md` W2). The canonical sequence (LAMUT's
`f_1ca27.asm`; the de-facto Mode-X recipe):

- **Unchain**: SEQ reg 4 (Memory Mode) clear bit 3 (chain-4) → `0x06`; SEQ reg 2 (Map Mask) = 0x0F
  (all planes). This is what flips the memory engine from chained (`02-memory-engine.md §4.1`) to
  planar (`§4.2`). zdos's engine must consult the live chain-4 bit (`02-memory-engine.md §6` — no
  `getHostPtr` fast path while unchained).
- **Mode Y (320×240)**: also CRTC unlock (reg 0x11 bit7=0), then reg 0x06=0x0D, 0x07=0x3E, 0x10=0xEA,
  0x11=0xAC, 0x12=0xDF, 0x15=0xE7, 0x16=0x06 (the 240-line timing), and misc-output `0xE3`. Mode X
  (320×200) keeps 13h's CRTC except the double-word / dword-mode bit.
- **Per-plane writes**: pixel `(x,y)` → plane `x & 3`, offset `start + y*(width/4) + (x>>2)`, gated by
  Map Mask (`02-memory-engine.md §4.2`).

> **Determinism + faithfulness:** Mode X/Y is **all guest port + VRAM writes**, fully deterministic, no
> BIOS involvement after the AH=00 mode-13h call. The only BIOS requirement is that AH=00(13h) leaves the
> registers in a state the overlay's reprogramming expects (the §1.2 mode-13h block), which the register
> dump (§1.3) provides. No mode-table entry, no fake.

---

## 2. The complete INT 10h function set

Dispatch on AH (`int10.zig:45` switch). dosbox dispatch: `int10.cpp:46-655`; spice86 dispatch table:
`VgaBios.cs:878-902`. **Legend:** ✅ present in `int10.zig` (cross-ref), 🔶 partial, ❌ missing.
**Essential for BaK/LAMUT** marked ★; the rest are specified for completeness.

### 2.1 Function-by-function

| AH | AL/BL sub | name | in → out / BDA effect | status | cite |
|----|-----------|------|----------------------|--------|------|
| **00** ★ | AL=mode, bit7=no-clear | **Set video mode** | AL → §1.3 full program; BDA mode/cols/page-size/rows/cheight/CRTC/MSR/PAL/DCC; clear VRAM | 🔶 (13h+text BDA only; **missing the SEQ/CRTC/GC/AC dump + default DAC palette**) | int10.cpp:47-51; int10_modes.cpp:1153; int10.zig:103 |
| **01** | CH=start,CL=end scanline | **Set cursor shape** | CX → BDA `CURSOR_TYPE`(0x60); program CRTC 0x0A/0x0B; CGA-emul shape conversion | ✅ (BDA write; CRTC program missing) | int10.cpp:52-54; int10_char.cpp:330; int10.zig:52 |
| **02** ★ | BH=page,DH=row,DL=col | **Set cursor pos** | DX → BDA `CURSOR_POS`+page*2; if active page, program CRTC 0x0E/0x0F | ✅ (BDA; CRTC reg program deferred) | int10.cpp:55-57; int10.zig:47 |
| **03** ★ | BH=page | **Get cursor pos+shape** | → DX=pos, CX=`CURSOR_TYPE` | ✅ | int10.cpp:58-63; int10.zig:55 |
| **04** | — | **Read light pen** | → AX=0 (not supported; real VGA returns AH=0) | ❌ (one-liner) | int10.cpp:64-67 |
| **05** | AL=page | **Set active page** | page → BDA `CURRENT_PAGE`(0x62) + `CURRENT_START`(0x4E)=page*page_size; program CRTC 0x0C/0x0D start-addr; move cursor | ❌ (needed for text page-flip; **LAMUT W2 reads front/back page base from CRTC start**) | int10.cpp:68-95; int10_char.cpp:298 |
| **06** | AL=lines,BH=attr,CX=ul,DX=lr | **Scroll up** | scroll window up; AL=0 clears | ✅ | int10.cpp:96-97; int10.zig:69 |
| **07** | same | **Scroll down** | scroll window down | ✅ | int10.cpp:99-100; int10.zig:70 |
| **08** ★ | BH=page | **Read char+attr at cursor** | → AL=char, AH=attr | ✅ | int10.cpp:102-103; int10.zig:63 |
| **09** | AL=char,BL=attr,BH=page,CX=count | **Write char+attr ×CX** | write CX cells at cursor (attr used); cursor NOT advanced | ✅ | int10.cpp:105-108; int10.zig:71 |
| **0A** | AL=char,BL=attr,BH=page,CX=count | **Write char ×CX** | write char only (attr untouched, F2) ×CX | ✅ | int10.cpp:110-111; int10.zig:72 |
| **0B** | BH=00:BL=border / BH=01:BL=palette | **Set palette/border (CGA)** | BH=0 → overscan/border (AC 0x11); BH=1 → CGA color-select (BDA `CURRENT_PAL` 0x66) | ❌ (CGA-era; rarely used by VGA games) | int10.cpp:113-123 |
| **0C** | AL=color,BH=page,CX=x,DX=y | **Write pixel** | put pixel (mode 13h linear ✅; EGA/CGA planar deferred) | ✅ (13h) | int10.cpp:124-125; int10_put_pixel.cpp:14; int10.zig:73 |
| **0D** | BH=page,CX=x,DX=y | **Read pixel** | → AL=color (13h ✅) | ✅ (13h) | int10.cpp:127-128; int10.zig:74 |
| **0E** ★ | AL=char,BL=fg(gfx) | **Teletype output** | write char + advance cursor + wrap + scroll; BEL=silent no-op (D-TM-BEL) | ✅ (text) | int10.cpp:130-132; int10_char.cpp:743; int10.zig:75 |
| **0F** ★ | — | **Get video mode** | → AL=mode(\|0x80 no-clear bit from VIDEO_CTL), AH=cols, BH=page | ✅ | int10.cpp:133-140; int10.zig:85 |
| **10** | AL subfns (§2.2) | **Palette / DAC** | see §2.2 | 🔶 (DAC 10/12/15/17 ✅; **AC palette regs + overscan + blink + DAC page missing**) | int10.cpp:141-204; int10.zig:90 |
| **11** ★ | AL subfns (§2.3) | **Character generator** | font load + **AH=1130 get font ptr** (LAMUT) | ❌ (**all missing; AH=1130 is LAMUT W1b**) | int10.cpp:207-425; int10_memory.cpp:160 |
| **12** | BL subfns (§2.4) | **Alternate select** | BL=10 EGA info; 30 scan lines; 31-36 toggles | ❌ (BL=10 may be hit by LAMUT EGA fallback; others rare) | int10.cpp:427-592 |
| **13** ★ | AL=flags,BL=attr,DX=pos,CX=len,ES:BP=str | **Write string** | teletype each char (useattr always); bit0=advance/restore, bit1=interleaved attr | ✅ | int10.cpp:594-596; int10_char.cpp:862; int10.zig:91 |
| **1A** ★ | AL=00 get / AL=01 set | **Display Combination Code** | **AL=00 → AL=0x1A, BL=active DCC=0x08(VGA color), BH=0x00; AL=01 set BDA DCC** | ❌ (**LAMUT W1 adapter-detect; THE missing call for `adapter=8`**) | int10.cpp:598-606; int10_misc.cpp:58; lamut W1 |
| **1B** | BX=0 | **Functionality/state info** | fill 64-byte block at ES:DI (static-state ptr + BDA copy + DCC + colors/pages/scanlines/flags); AL=0x1B | ❌ (some games probe it; specify) | int10.cpp:608-624; int10_misc.cpp:96 |
| **1C** | AL=00 size / 01 save / 02 restore | **Save/restore video state** | CX=state mask (1=hw,2=BDA,4=DAC); AL=0x1C on success | ❌ (rarely used; dosbox only — **spice86 does NOT implement it**) | int10.cpp:626-655; int10_video_state.cpp |
| **4F** | — | **VESA** | **OUT OF SCOPE** (S3-only in dosbox; BaK/LAMUT non-VESA) | ❌ (flag if called) | int10.cpp:657; int10_vesa.cpp |

### 2.2 AH=10h — Palette / DAC sub-functions (full set)

Dispatch on AL (`int10.cpp:147-203`; spice86 `VgaBios.cs:472-548`). The DAC subset (10/12/15/17) is
already in `int10.zig:495-571` as a port sequence. The **missing** ones operate on the Attribute
Controller palette registers + DAC page state:

| AL | name | in → out / port path | status | cite |
|----|------|----------------------|--------|------|
| 00 | Set single AC palette reg | BL=reg(0..15), BH=value → `0x3C0`(flip-flop: index then data) | ❌ | int10.cpp:148-150; int10_pal.cpp |
| 01 | Set overscan/border color | BH=value → AC reg 0x11 | ❌ | int10.cpp:151-153 |
| 02 | Set all 16 AC palette + overscan | ES:DX→17 bytes (16 palette + 1 overscan) → AC 0..0x10,0x11 | ❌ | int10.cpp:154-156 |
| 03 | Toggle blink/intensity bit | BL bit0 → AC mode reg 0x10 bit 3 | ❌ | int10.cpp:157-159 |
| 07 | Get single AC palette reg | BL=reg → BH=value | ❌ | int10.cpp:160-162 |
| 08 | Read overscan reg | → BH=value | ❌ | int10.cpp:163-165 |
| 09 | Read all AC palette + overscan | → ES:DX (17 bytes) | ❌ | int10.cpp:166-168 |
| **10** ★ | Set single DAC reg | BL=idx, DH=R,CH=G,CL=B → `0x3C8`,`0x3C9`×3 | ✅ | int10.cpp:169-171; int10.zig:508 |
| **12** ★ | Set block of DAC regs | BX=start,CX=count,ES:DX=data → `0x3C8`,`0x3C9`×3n | ✅ | int10.cpp:172-174; int10.zig:537 |
| 13 | Select DAC color page | BL=0:set paging mode (AC 0x10 bit7); BL=1:select page (AC 0x14) | ❌ | int10.cpp:175-177 |
| **15** | Get single DAC reg | BL=idx → DH/CH/CL=R/G/B | ✅ | int10.cpp:178-180; int10.zig:522 |
| **17** | Get block of DAC regs | BX=start,CX=count → ES:DX | ✅ | int10.cpp:181-183; int10.zig:558 |
| 18 | Set PEL mask (undoc) | BL → `0x3C6` | ❌ | int10.cpp:184-186 |
| 19 | Get PEL mask (undoc) | → BL | ❌ | int10.cpp:187-190 |
| 1A | Get DAC color page state | → BL=mode, BH=current page | ❌ | int10.cpp:191-193 |
| 1B | Perform gray-scale summing | BX=start,CX=count → sum DAC entries to gray | ❌ | int10.cpp:194-196 |

> All AC-palette subfns (00-09) drive the Attribute Controller via the `0x3C0` flip-flop
> (`01-registers.md §5`); all DAC subfns drive `0x3C6-0x3C9` (`§6`). **The recommended implementation is
> identical to the present DAC code** (`int10.zig:495-571`): emit the exact port sequence so the BIOS path
> and a raw-port guest are byte-identical. BaK uses 10/12/15/17 (fades); flag if it touches AC-palette set
> (it programs the AC directly in Mode-X via ports, not via AH=10 — `lamut-milestone.md`).

### 2.3 AH=11h — Character generator (full set)

Dispatch on AL (`int10.cpp:216-421`; spice86 `VgaBios.cs:406-470`). **All missing in zdos.** ★=LAMUT.

| AL | name | in → effect | cite |
|----|------|-------------|------|
| 00 | Load user font | ES:BP=data, CX=count, DX=first, BL=block, BH=cheight → upload to plane 2 | int10.cpp:220-236; int10_memory.cpp:160 |
| 01 | Load ROM 8×14 font | BL=block → upload `font_14` | int10.cpp:239-255 |
| 02 | Load ROM 8×8 font | BL=block → upload `font_8` | int10.cpp:258-274 |
| 03 | Set block specifier | BL → SEQ reg 3 (char map select) | int10.cpp:277-280 |
| 04 | Load ROM 8×16 font | BL=block → upload `font_16` | int10.cpp:283-303 |
| 10 | Load+activate user font | as 00, then recompute CRTC/BDA rows | int10.cpp:222-236 |
| 11 | Load+activate ROM 8×14 | as 01 + activate | int10.cpp:241-255 |
| 12 | Load+activate ROM 8×8 | as 02 + activate | int10.cpp:260-274 |
| 14 | Load+activate ROM 8×16 | as 04 + activate | int10.cpp:285-303 |
| 20 | Set INT 1Fh ptr (gfx 8×8 hi) | ES:BP → IVT[0x1F] | int10.cpp:307-309 |
| 21 | Set INT 43h ptr (user gfx) | ES:BP → IVT[0x43]; BDA cheight=CX; set rows | int10.cpp:311-314 |
| 22 | Set INT 43h = ROM 8×14 | → IVT[0x43]=font_14; rows | int10.cpp:316-319 |
| 23 | Set INT 43h = ROM 8×8 | → IVT[0x43]=font_8; rows | int10.cpp:321-324 |
| 24 | Set INT 43h = ROM 8×16 | → IVT[0x43]=font_16; rows | int10.cpp:326-332 |
| **1130** ★ | **Get font pointer** | BH selects font → ES:BP=font addr, CX=cheight, DL=rows-1 | int10.cpp:352-415; **lamut W1b** |

**AH=1130 BH selector** (`int10.cpp:353-409`): BH=00 → INT 1Fh vec; 01 → INT 43h vec; 02 → ROM 8×14;
03 → ROM 8×8 first 128; 04 → ROM 8×8 second 128; 05 → 9×14 alt; 06 → ROM 8×16; 07 → 9×16 alt. Returns
`ES:BP` = far ptr, `CX` = BDA `CHAR_HEIGHT`, `DL` = BDA `NB_ROWS`. **LAMUT calls AH=1130 BH=03**
(`f_1ab04.asm:168`) to get the ROM 8×8 font — it just stores the pointer; only fails if the call
crashes. zdos must (a) stage a real 8×8 ROM font at a fixed address (§4) and (b) return its `ES:BP`.

### 2.4 AH=12h — Alternate function select (full set)

Dispatch on BL (`int10.cpp:431-591`; spice86 `VgaBios.cs:366-404`).

| BL | name | in → out / BDA effect | cite |
|----|------|----------------------|------|
| 10 | Get EGA/config info | → BH=color(0)/mono(1), BL=memory(3=256K), CH/CL=feature switches | int10.cpp:432-437 |
| 20 | Alternate printscreen | (no-op stub) | int10.cpp:439-440 |
| 30 | Select scan lines | AL=0(200)/1(350)/2(400) → BDA `MODESET_CTL` + `SWITCHES`; AL=0x12 ok | int10.cpp:442-484 |
| 31 | Palette loading on modeset | AL bit0 → BDA `VIDEO_CTL` "load default palette"; AL=0x12 | int10.cpp:485-503 |
| 32 | Video addressing on/off | AL bit0 → enable/disable CPU VRAM access; AL=0x12 | int10.cpp:504-519 |
| 33 | Gray-scale summing | AL bit0 → BDA `MODESET_CTL` bit1; AL=0x12 | int10.cpp:521-538 |
| 34 | Cursor emulation | AL bit0 → BDA `VIDEO_CTL` bit0; AL=0x12 | int10.cpp:539-556 |
| 35 | Display switch (PS/2) | AL=0x12 stub | int10.cpp:557-563 |
| 36 | Video screen on/off (refresh) | AL=0(on)/1(off) → SEQ reg 1 bit 5; AL=0x12 | int10.cpp:565-584 |

> **BL=10 (Get EGA info)** is the only AH=12h call possibly on LAMUT's path — its adapter-detect EGA
> *fallback* `L_2c43` uses it (`lamut-milestone.md` hole #1b), but the mode-8 auto-detect path uses
> AH=1A00 and never falls through, so BL=10 is **not** a Stage-1 blocker. Specify it anyway (one-liner):
> `BH = (BDA CRTC_ADDRESS==0x3B4)`, `BL=3`, `CL/CH` = `SWITCHES` nibbles. BL=30/31/33 touch the
> `MODESET_CTL`/`VIDEO_CTL` BDA bytes that gate set-mode's scan-line / palette-load behavior (§1.3 step 3).

### 2.5 AH=1Ah — Display Combination Code (the LAMUT adapter-detect, ★ critical)

dosbox `int10.cpp:598-606` → `INT10_DisplayCombinationCode` (`int10_misc.cpp:58-94`); spice86
`VgaBios.cs:338-364`. Two subfns:

- **AL=00 (get):** read BDA `DCC_INDEX` (0x8A), look it up in the ROM DCC table (the save-pointer chain,
  §3.3), return `BL` = active display code, `BH` = inactive. Set `AX = 0x1A` (function-supported marker).
- **AL=01 (set):** find the DCC in the ROM table, write its index to BDA `DCC_INDEX`; `AX=0x1A`.

> **zdos minimal faithful path (LAMUT W1).** The full DCC-table walk requires the save-pointer chain in
> ROM (§3.3). The **simplest faithful** implementation spice86 uses: AL=00 → `BL = BDA DisplayCombinationCode`
> (default 0x08 = "VGA with color analog monitor"), `BH = 0` (no secondary), `AX=0x1A`; AL=01 → store
> `BL` into the BDA DCC byte (`VgaBios.cs:339-360`, default `0x08` at `:266,792`). This is NOT a fake — it
> reads/writes the real BDA DCC byte initialized to the documented VGA value. **`BL=0x08` is exactly what
> LAMUT's `video_detect_adapter` tests for** (`f_1ac53.asm:92-95`, `BL ∈ {7,8}`), so `adapter=8`.
> Recommend the spice86 BDA-byte path (deterministic, no ROM-table dependency); the dosbox ROM-table walk
> is the fuller version if a guest ever sets/queries multi-monitor combos (none does).

### 2.6 AH=1Bh — Functionality / state information

`int10.cpp:608-624` → `INT10_GetFuncStateInformation` (`int10_misc.cpp:96-157`); spice86
`VgaBios.cs:900` → `GetFunctionalityInfo`. BX must be 0. Fills a **64-byte block at ES:DI**:
- +0: far ptr to the static-functionality table in ROM (§3.3).
- +4: a 30-byte copy of BDA `0x49..0x66` (mode, cols, page-size, start, cursor pos/type, page, CRTC,
  MSR, PAL).
- +0x22: BDA `NB_ROWS+1` then `NB_ROWS+1`, `NB_ROWS+2` (rows + char height bytes).
- +0x25: DCC word; +0x27: color count (text=16/mono=1, CGA2=2, CGA4=4, EGA=16/2, VGA=256);
  +0x29: page count (`ptotal`); +0x2A: scan-line code (200→0,350→1,400→2,480→3);
  +0x2D: misc flags (text 0x21 / gfx 0x01); +0x31: video memory (3=256K). Set `AL=0x1B`.

> Specify it for completeness; some sniffers call it. Deterministic (pure BDA + fixed ROM table). Needs
> the static-functionality table in ROM (§3.3).

### 2.7 AH=1Ch — Save/restore video state (dosbox-only)

`int10.cpp:626-655`; `int10_video_state.cpp`. AL=0 returns the buffer size (BX) for the state mask in CX
(bit0=hardware regs, bit1=BDA, bit2=DAC); AL=1 saves to ES:BX; AL=2 restores. **spice86 does NOT
implement this** (not in its dispatch, `VgaBios.cs:878-902`). It is rarely used (TUI screen-savers).
zdos can defer it (return AL=0 = unsupported) but **specify** the state-mask semantics for completeness;
implement only if a corpus program needs it. Determinism note: it serializes the exact device register
files (`01-registers.md`) + BDA + DAC into guest memory — fully deterministic if implemented.

---

## 3. The complete BDA video area

### 3.1 dosbox/spice86 vs zdos — field map

The BDA video fields live at `0040:0049..0040:008A` plus the save-pointer at `0040:00A8`. Offsets from
dosbox `int10.h:37-76`; zdos offsets from `bda.zig:22-34`.

| off | name (dosbox define) | bytes | meaning | zdos `bda.zig` |
|-----|----------------------|-------|---------|----------------|
| 0x10 | (equipment word) | 2 | bits 4-5 = startup video mode | ✅ `OFF_EQUIPMENT` |
| 0x49 | BIOSMEM_CURRENT_MODE | 1 | current video mode | ✅ `OFF_VIDEO_MODE` |
| 0x4A | BIOSMEM_NB_COLS | 2 | text columns | ✅ `OFF_VIDEO_COLS` |
| 0x4C | BIOSMEM_PAGE_SIZE | 2 | page size bytes | ✅ `OFF_VIDEO_PAGE_SIZE` |
| 0x4E | BIOSMEM_CURRENT_START | 2 | active-page start offset in VRAM | ❌ **missing** (needed by AH=05) |
| 0x50 | BIOSMEM_CURSOR_POS | 16 | cursor pos, 8 pages × word (col=lo,row=hi) | ✅ `OFF_CURSOR_POS` |
| 0x60 | BIOSMEM_CURSOR_TYPE | 2 | cursor shape (end=lo, start=hi) | ✅ `OFF_CURSOR_SHAPE` |
| 0x62 | BIOSMEM_CURRENT_PAGE | 1 | active display page | ✅ `OFF_ACTIVE_PAGE` |
| 0x63 | BIOSMEM_CRTC_ADDRESS | 2 | CRTC base port (0x3D4 color / 0x3B4 mono) | ✅ `OFF_CRTC_ADDRESS` |
| 0x65 | BIOSMEM_CURRENT_MSR | 1 | mode-control register shadow (3D8/3B8) | ❌ **missing** |
| 0x66 | BIOSMEM_CURRENT_PAL | 1 | CGA palette/color-select shadow (3D9) | ❌ **missing** |
| 0x84 | BIOSMEM_NB_ROWS | 1 | text rows − 1 (EGA/VGA) | ✅ `OFF_NB_ROWS` |
| 0x85 | BIOSMEM_CHAR_HEIGHT | 2 | char cell height (scanlines) | ✅ `OFF_CHAR_HEIGHT` |
| 0x87 | BIOSMEM_VIDEO_CTL | 1 | EGA/VGA control flags (bit7=no-clear, bit3=load-palette, bit0=cursor-emul) | ✅ `OFF_VIDEO_CTL` |
| 0x88 | BIOSMEM_SWITCHES | 1 | EGA feature switches | ❌ **missing** |
| 0x89 | (BIOSMEM_MODESET_CTL) | 1 | VGA flags rec (scan-lines bits 4/7, gray-sum bit1, palette bit3) | ❌ **missing** (gates set-mode §1.3) |
| 0x8A | BIOSMEM_DCC_INDEX | 1 | display combination code index | ✅ `OFF_DCC_INDEX` |
| 0xA8 | BIOSMEM_VS_POINTER | 4 | far ptr to the video save-pointer table (ROM) | ❌ **missing** (§3.3) |

> **Note on dosbox `BiosDataArea::VgaFlagsRecOffset`** (the "modeset ctl" byte). dosbox reads/writes it at
> a single offset used by AH=12h BL=30/31/33 and read by set-mode (`int10_modes.cpp:1186-1187`,
> `int10.cpp:454,480,498,533`). This is the IBM "VGA flags record" at **0x89** (the byte between SWITCHES
> 0x88 and DCC 0x8A). spice86 calls it `ModesetCtl`/`VideoFeatureSwitches` (`VgaFunctionality.cs:309,320`).
> zdos must add it (`OFF_MODESET_CTL = 0x89`) so set-mode's palette-load / scan-line behavior (§1.3 step 3)
> is honored; default `0x51` (color, 400-line — IBM POST value).

### 3.2 What set-mode writes to the BDA (the complete list)

From `finish_set_mode` (`int10_modes.cpp:866-901`) + the special-mode MSR/PAL block (`:2037-2070`) +
spice86 `SetBiosDataArea` (`VgaFunctionality.cs:684-714`):

```
CURRENT_MODE(0x49) = mode (mode-0x98 if ≥128, S3 quirk — n/a for v1)
NB_COLS(0x4A)      = twidth
PAGE_SIZE(0x4C)    = plength
CURRENT_START(0x4E)= 0          (active page 0 start)
CRTC_ADDRESS(0x63) = (mode==7||mode==0xF) ? 0x3B4 : 0x3D4
NB_ROWS(0x84)      = theight-1                 (EGA/VGA)
CHAR_HEIGHT(0x85)  = cheight                   (EGA/VGA)
VIDEO_CTL(0x87)    = 0x60 | (clearmem?0:0x80)  (EGA/VGA)
SWITCHES(0x88)     = 0x09                       (EGA/VGA)
DCC_INDEX(0x8A)    = 0x0B                       (VGA — index into DCC table)
CURRENT_MSR(0x65)  = per-mode 3D8/3B8 shadow (text 3→0x29, 13h→n/a; :2037-2065)
CURRENT_PAL(0x66)  = per-mode 3D9 shadow / AC palette select (:1817,1844,1863)
CURSOR_TYPE(0x60)  = 0x0607 (text only)
CURSOR_POS(0x50)+page*2 = 0 for pages 0..7
CURRENT_PAGE(0x62) = 0
```

> zdos's `setModeVga13`/`setModeText` (`int10.zig:126-203`) already writes mode/cols/page-size/CRTC/
> rows/cheight/video-ctl/dcc/cursor-shape/cursor-pos/active-page. **Gaps:** `CURRENT_START(0x4E)`,
> `CURRENT_MSR(0x65)`, `CURRENT_PAL(0x66)`, `SWITCHES(0x88)`, `MODESET_CTL(0x89)`. Add these so AH=0F's
> no-clear bit (from VIDEO_CTL), AH=05's page-start, and AH=1B's BDA copy are all coherent.

### 3.3 The save-pointer table + the four font/data vectors (INT 1Dh/1Fh/43h/44h)

Real VGA BIOS stages, in ROM at segment 0xC000, a chain of tables reachable via the IVT and the BDA
save-pointer (`int10_memory.cpp:267-335`):

- **INT 1Dh** → video parameter table (CRTC/SEQ/etc. timing per mode; dosbox `video_parameter_table`,
  `int10_memory.cpp:277`). Used by the legacy "set mode from params" path; zdos uses the §1.2 table
  directly, but the vector must point at a real table for guests that read it.
- **INT 1Fh** → graphics font, **8×8 chars 128-255** (the high-half CP437 glyphs for graphics text;
  `RealSetVec(0x1F, font_8_second)`, `int10_memory.cpp:274`).
- **INT 43h** → the active character-cell font (8×8 / 8×14 / 8×16 per current mode; set by set-mode
  `:883-891` and AH=11h AL=2x).
- **INT 44h** → PCjr/Tandy font (n/a for VGA; dosbox sets it only on Tandy `:341`).
- **BDA 0x40:00A8 (VS_POINTER)** → the **video save-pointer table** (`video_save_pointers`,
  `int10_memory.cpp:318-335`): 7 dwords — [0] video parameter table, [1] dynamic save area, [2] alpha
  charset override, [3] graphics charset override, [4] save-pointer-table-2 (→ the **DCC table** for
  AH=1A and the static-functionality table for AH=1B), [5][6] reserved.
- **DCC table** (`int10_memory.cpp:281-302`): `{count=0x10, version=1, max-code=8, reserved, then
  16 display-combination words}` — the table AH=1A walks. The standard VGA-color entry is `0x08`.
- **Static-functionality table** (`int10_memory.cpp:267-270`, `static_functionality[0x10]`): the
  16-byte capability bitmap AH=1B's +0 pointer references.

> **zdos requirement:** stage these as **fixed comptime data in BIOS ROM space (0xC000 segment, or the
> 0xF000 BIOS area zdos already owns)** at POST, and set IVT[0x1D]/[0x1F]/[0x43] + BDA VS_POINTER. This
> is deterministic fixed data (CLAUDE #5), NOT a fake. For v1, AH=1A/1B can use the **simplified
> BDA-byte / inline path** (§2.5, §2.6) and the font vectors point at the ROM fonts (§4); the full
> save-pointer chain is only needed if a guest dereferences VS_POINTER directly (none in the v1 corpus —
> flag if so).

---

## 4. Font / character generator

### 4.1 What zdos must provide

The ROM fonts are **fixed glyph bitmap data** that must exist at known ROM addresses for:
- **AH=11h** load-font sub-functions (text rendering / custom fonts).
- **AH=1130 BH=0..7** get-font-pointer (LAMUT calls BH=3 = 8×8 → stores `g_font_bitmap_data`,
  `f_1ab04.asm:168-170`).
- **INT 1Fh / INT 43h** vectors (graphics-mode glyph rendering).

The three standard cell sizes (dosbox `int10_memory.cpp:243-265`; spice86 `Data/Fonts.cs` + `VgaRom.cs`):

| font | size | dosbox symbol | use |
|------|------|---------------|-----|
| 8×8  | 256×8 = 2048 B (two 128-char halves) | `int10_font_08` (`font_8_first`/`_second`) | 8×8 cell modes, INT 1Fh (hi half), AH=1130 BH=3/4 |
| 8×14 | 256×14 = 3584 B | `int10_font_14` | EGA 350-line text (mode 0F/10), AH=1130 BH=2 |
| 8×16 | 256×16 = 4096 B | `int10_font_16` | VGA 400-line text (modes 0-3/7), AH=1130 BH=6 |

Plus the 9-dot alternate fonts (`font_14_alternate`/`font_16_alternate`, ~20 chars) for the 9-pixel
text cell columns — minor; the 9th column is the font-byte replicate for box-drawing chars 0xC0-0xDF.

### 4.2 Where the font tables live

- **dosbox:** ROM at 0xC000, laid out by `INT10_SetupRomMemory` (`int10_memory.cpp:243-265`); the raw
  bitmap arrays are in `int10_memory.cpp:656+` (`int10_font_14`, `:1107` `int10_font_16`, and
  `int10_font_08` elsewhere). The 8×8 first-half is also copied to the legacy 0xF000:0xFA6E
  (`:271-273`).
- **spice86:** `Data/Fonts.cs` (`VgaFont8`/`VgaFont14`/`VgaFont16` byte arrays); placed at 0xC000 by
  `VgaRom.cs:34-37` (`VgaFont8Address`@offset 64, `VgaFont8Address2`, `VgaFont14Address`,
  `VgaFont16Address`).

> **zdos approach:** `@embedFile` (or a comptime byte array) of the standard CP437 VGA font bitmaps
> in a new `src/bios/vga_font.zig`, staged into BIOS ROM space at POST with fixed offsets. Set
> IVT[0x1F]=8×8-second, IVT[0x43]=active-cell font, BDA VS_POINTER per §3.3. AH=1130 returns the matching
> `ES:BP` + `CX=CHAR_HEIGHT` + `DL=NB_ROWS`. **This is deterministic fixed data — copy the dosbox/spice86
> font bytes verbatim** (they are the IBM VGA ROM font; either reference's array is fine, they match).
> Mandatory for LAMUT (AH=1130 must not crash); the bytes only matter for *content* if a guest renders
> glyphs in graphics mode (BaK draws its own; LAMUT only stores the pointer).

---

## 5. Determinism

Every INT 10h service is a **host-serviced trap** dispatched at the BIOS bridge (same mechanism the
existing AH=00/02/03/0F/10 handlers use, `int10.zig:40-94`), charging the bridge's **fixed synthetic
base cost** per trap — no host clock, no per-trap variation (CLAUDE #1). Confirmation by area:

- **Set-mode (AH=00)** is a fixed sequence of register writes (the §1.2 comptime table dumped to the
  device register files via `0x3C0-0x3CF`/`0x3D4-0x3D5`/`0x3C2` port writes) + a deterministic VRAM
  clear (word-fill `0x0720` for text / zero for graphics) + fixed BDA writes. **The mode table is fixed
  comptime data.** No host time, no RNG, no float. The register-write port path is the same one a raw
  guest uses, so BIOS set-mode and a hand-rolled mode-set are byte-identical (the zdos faithfulness
  principle, `int10.zig:489-493`).
- **Default DAC palette load (AH=00 step 3)** writes fixed comptime palette bytes to the DAC via
  `0x3C8/0x3C9` — deterministic; reproducible across runs.
- **DAC / AC / GC sub-functions (AH=10/11/12)** are pure port sequences over fixed inputs (guest
  registers / guest memory). Deterministic.
- **AH=1A (DCC)** reads/writes the BDA DCC byte (fixed default `0x08`) — deterministic, no host state.
- **Teletype / scroll / put-pixel** drive the memory engine (`02-memory-engine.md`) + BDA, all guest RAM
  — already deterministic; **BEL is a silent no-op** (never dosbox's 333 ms `PIC_FullIndex` busy-wait,
  D-TM-BEL — the one host-clock dependence in dosbox's INT 10h, which zdos must NOT copy).
- **Font / save-pointer tables** are fixed comptime ROM data set once at POST. Deterministic.
- **The BDA + all register writes are guest RAM / device register state** → snapshot-covered
  (BDA via `bus.ram`; register files via `Vga.Snapshot`, `01-registers.md §8.3`) and byte-reproducible
  at cycle N (CLAUDE #6).

**Nothing in the INT 10h layer reads the host wall clock.** The single host-timed item in the references
(dosbox's BEL busy-wait) is explicitly rejected. **Flagged structural items** (surface, don't fake):
AH=1Ch save/restore (defer; specify the mask), AH=4Fh VESA (out of scope), and any guest read of plane-2
font RAM or the VS_POINTER chain (the flat-text-slab / simplified-DCC simplifications — `text-mode-video.md`
D-TM1, §2.5/§3.3 here).

---

## 6. dosbox vs spice86 — what to copy, recommended zdos approach

| Area | dosbox-staging | spice86 | zdos decision |
|------|----------------|---------|---------------|
| Mode parameter table | geometry table + ~600 lines of computed register arithmetic (`int10_modes.cpp:1153-2203`) | **explicit per-mode register-value table** = the IBM VGA BIOS tables (`Data/RegisterValueSet.cs:7-58`) | **COPY spice86's `VgaModes` literals**; use dosbox's `ModeList_VGA` geometry (`:28-45`) for `pstart`/`plength`/`ptotal`/dims; cross-checked, they agree on v1 modes |
| Set-mode apply | per-register `IO_Write` with computed values | **blind register dump** `FillRegisters` (`VgaFunctionality.cs`) | **COPY spice86** — dump the §1.2 block into the `01-registers.md` register files |
| INT 10h dispatch | `int10.cpp:46-655` (incl. AH=1C) | `VgaBios.cs:878-902` (no AH=1C) | **COPY the union**; AH=1C defer (spice86 omits it; rare) |
| AH=1A (DCC) | full ROM-table walk (`int10_misc.cpp:58`) | **BDA-byte read/write** (`VgaBios.cs:338-364`) | **COPY spice86's BDA-byte path** (deterministic, no ROM-chain dependency); dosbox walk if multi-monitor ever needed |
| AH=1B (func info) | `int10_misc.cpp:96-157` | `GetFunctionalityInfo` | **COPY dosbox** (more complete BDA copy) |
| BEL in teletype | **333 ms busy-wait** (`int10_char.cpp:752-772`) | `//FIXME should beep` no-op | **COPY spice86's no-op** (host-clock dependence — CLAUDE #2) |
| Fonts | `int10_font_08/14/16` at 0xC000 | `Data/Fonts.cs` at 0xC000 (`VgaRom.cs`) | **COPY either** (identical IBM ROM bytes); embed in `src/bios/vga_font.zig` |
| Save-pointer / DCC / static-func ROM tables | full chain (`int10_memory.cpp:267-335`) | minimal | **stage fixed ROM data** at POST; v1 uses simplified inline AH=1A/1B; flag if VS_POINTER dereferenced |

**Recommended zdos structure:**
- `src/bios/vga_modes.zig` (NEW): the `ModeEntry` table (§1.1 geometry + §1.2 register blocks), comptime.
- `src/bios/vga_font.zig` (NEW): the 8×8/8×14/8×16 ROM font bytes + POST staging into ROM + IVT vectors.
- `src/bios/int10.zig` (EXTEND): add the missing AH cases (04/05/0B/0C-planar/10h-full/11h/12h/1Ah/1Bh,
  1Ch optional) and rewrite `setMode` to (1) look up the `ModeEntry`, (2) load the default DAC palette,
  (3) dump SEQ/CRTC/GC/AC via the existing port path, (4) clear VRAM, (5) write the full BDA set (§3.2).
- `src/bios/bda.zig` (EXTEND): add `OFF_CURRENT_START(0x4E)`, `OFF_CURRENT_MSR(0x65)`,
  `OFF_CURRENT_PAL(0x66)`, `OFF_SWITCHES(0x88)`, `OFF_MODESET_CTL(0x89)`, `OFF_VS_POINTER(0xA8)`.

**Interplay with the other spec sections.** Set-mode (this §1.3) *writes the registers specified in
`01-registers.md`* (SEQ/CRTC/GC/AC/DAC) — it is the largest "writer" of those files. Teletype/scroll/
write-char/put-pixel (this §2, the already-present services) *drive the memory engine in
`02-memory-engine.md`* (text odd/even cells, planar/chained pixel writes) and the scanout. Mode X/Y
(§1.4) is a guest-driven re-program of mode 13h's registers — the BIOS only guarantees the 13h register
baseline; the engine (`02-memory-engine.md §6`) honors the chain-4 flip.

---

## 7. Synthesis (for the implementer)

- **Mode set + table structure.** 14 standard modes (text 0-3,7; CGA 4-6; EGA 0Dh-10h; VGA 11h,12h,13h)
  plus Mode X/Y as a *guest-driven* unchained variant of 13h (no table entry). The table is the **spice86
  `VgaModes` per-mode register-value block** (= the IBM VGA BIOS tables): each entry carries geometry +
  `misc_output` + SEQ[5] + CRTC[25] + ATTR[21] + GFX[9] + pel_mask + default-palette id. Set-mode is a
  blind dump of that block into the `01-registers.md` device register files + a default DAC palette load
  + a deterministic VRAM clear + the full BDA write. Cross-checked dosbox-vs-spice86: they agree
  byte-for-byte on the v1 modes (13h, 03h verified).
- **INT 10h present vs missing.** **Present** (✅, text services from the recent work + DAC subset):
  AH=00 (13h+text BDA only), 01, 02, 03, 06, 07, 08, 09, 0A, 0C/0D (13h), 0E, 0F, 10h AL=10/12/15/17, 13.
  **Missing** (❌): AH=04 (light pen, trivial), **05 (set active page — LAMUT page base)**, 0B (CGA
  palette/border), full AH=10h (AC palette 00-09, DAC page 13/1A, blink 03, pel-mask 18/19, gray-sum 1B),
  **AH=11h (all — incl. ★AH=1130 get-font, LAMUT W1b)**, AH=12h (BL=10 EGA info + 30-36 toggles),
  **★AH=1A00 (DCC — THE LAMUT adapter-detect, return BL=0x08)**, AH=1B (func/state info), AH=1C
  (save/restore — defer), AH=4F (VESA — out of scope). The **two LAMUT-critical missing calls** are
  **AX=1A00** (returns AL=0x1A, BL=0x08 → `adapter=8`) and **AH=1130** (return the ROM 8×8 font ptr).
  AH=00 needs the **SEQ/CRTC/GC/AC register dump + default DAC palette** added (currently only misc-output
  + BDA + VRAM clear for 13h/text).
- **BDA + font needs.** BDA video fields mostly present; **missing**: `CURRENT_START(0x4E)`,
  `CURRENT_MSR(0x65)`, `CURRENT_PAL(0x66)`, `SWITCHES(0x88)`, `MODESET_CTL(0x89)`, `VS_POINTER(0xA8)`.
  Fonts: stage the 8×8/8×14/8×16 IBM ROM font bitmaps in BIOS ROM (new `vga_font.zig`), set IVT 1Dh/1Fh/
  43h + BDA VS_POINTER; AH=1130 returns the matching pointer (mandatory for LAMUT). The save-pointer /
  DCC / static-functionality ROM tables are fixed comptime data; v1 may use the simplified inline AH=1A/1B
  paths and flag any direct VS_POINTER dereference.
- **Determinism.** Every INT 10h service is a fixed-cost host trap over guest registers/memory + the
  device register files; the mode tables, palettes, and fonts are fixed comptime data; the only host-timed
  item in the references (dosbox's BEL busy-wait) is rejected for a silent no-op. The BDA bytes and the
  register files are snapshot-covered and byte-reproducible at cycle N. **No host clock anywhere in the
  INT 10h layer.**
