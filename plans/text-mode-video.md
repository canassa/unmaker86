# Text-mode video (B8000/B0000) + INT 10h text services + `/api/screen` observability

Status: **design plan** (implementation-ready; no source changed by this document). Fills the
ROADMAP backlog item "VGA text-mode video (B8000) + console mirror" (`plans/ROADMAP.md:25`).

> **Status: v2.** Revised after a 3-perspective review (determinism, INT 10h/VGA fidelity, Zig
> 0.16/integration); every `file:line` re-verified against the real source. Targeted edits, structure
> preserved. Changes by area:
> (1) **CRITICAL false-snapshot fix.** v1 claimed `text_vram` is "snapshot-covered like `vram`" citing
> `machine.zig:515-518` as if `vram` were a `Snapshot` struct field — it is **not**: `:515-517` is a
> *doc comment*, and large slabs (`vram`, `bus.ram`) are copied **out-of-band by the snapshot caller**
> (`controller_test.zig:304,329` — `alloc.dupe` + `expectEqualSlices`; `bus.zig:933-936,940` excludes
> `ram` from `Bus.Snapshot`). §3.1/§3.4 + P2 rewritten: `text_vram` is dupe'd/restored by the caller,
> NOT placed in any `Snapshot`; the hostPtr is correctly NOT snapshotted (re-established by `wire()`'s
> `mapMmio` on restore).
> (2) **INT 10h fidelity (F1–F8)** folded into §2.2/§3.2: single width source = BDA `OFF_VIDEO_COLS`
> everywhere; AH=0E teletype `useattr=false` writes char ONLY (don't touch attr byte — reject spice86's
> default-attr overwrite); scroll inclusive lower-right bounds; teletype end-of-screen scroll fills with
> the attr at the cursor (not 0); AH=13 always `useattr=true` + cursor-restore when AL bit0=0; set-mode
> writes `OFF_NB_ROWS=rows-1` and clears with a 16-bit `0x0720` word fill; cursor word `col=lo,row=hi`.
> (3) **Determinism/grep-gate corrections:** `int10.zig` is **ALREADY** in the BIOS gate
> (`determinism_test.zig:22`) and `controller.zig`/`src/api/*` are gated too, so the only genuine new
> surface is keeping `vga.zig` clean in the *devices* gate; do NOT add `int10.zig` to the devices gate
> (cross-module `@embedFile` won't compile). BEL = silent no-op in AH=13 too. peek8 + getHostPtr both
> mandatory.
> (4) **Zig 0.16/integration:** two `[0x8000]u8` slabs (`text_vram`@B8000 + `text_vram_mono`@B0000);
> `@memset(slab,0)` in reset (NOT `@splat`); `?attrs=1` parsed server-side (command stays `void`);
> `MAX_SCREEN_CELLS=4000`; `/api/screen` renders the BDA active page with BDA cols/rows.
> (5) **Scope:** AH=08 (read char+attr) + AH=01 (set cursor shape) added to v1, and the existing AH=03
> hardcoded `0x0607` (`int10.zig:49`) fixed to read the BDA shape.
> (6) **Q5/D-TM5 locked:** `/api/console` (DOS CON) and `/api/screen` (B8000) stay DISTINCT for v1;
> CON→text-page mirroring is a documented follow-up.

Owner modules: `src/devices/vga.zig` (text-page backing + geometry), `src/bios/int10.zig` (text
services), `src/bios/bda.zig` (already has the fields), `src/machine/machine.zig` (one mapping line),
`src/debug/controller.zig` + `src/api/{queue,worker,server}.zig` (the `/api/screen` read),
`tests/blackbox/keyecho_test.zig` (the acceptance gate).

---

## 1. Problem statement

zdos models mode-13h **graphics** VRAM (A0000, `src/devices/vga.zig:51-57`, mapped at
`src/machine/machine.zig:233`) but has **no text-mode video at all**:

- **The text page B800:0000 (color) / B000:0000 (mono) is not backed.** The UMA region
  0xA0000–0xBFFFF defaults to `.unmapped` (`src/bus/memmap.zig:104-105`): only A0000 is claimed by
  the VGA device's `mapMmio`. So a guest write to B800:0000 is **silently dropped** and a read
  returns the unmapped fill 0x00 (`src/bus/ports.zig` / `src/bus/memmap.zig:48-50`).
- **INT 10h text-output services are incomplete.** `src/bios/int10.zig` implements AH=00 (mode-set,
  but only mode 13h has a full path), AH=02/03 (cursor pos via BDA), AH=0C/0D (graphics pixel),
  AH=0F (get-mode), AH=10 (DAC). **AH=0E teletype is an explicit no-op** (`src/bios/int10.zig:53-56`),
  and AH=09/0A (write char+attr), AH=06/07 (scroll), AH=13 (write string) are **missing** (fall
  through to `bios.unsupported`, `:63`).

This was surfaced by the KEYECHO recon and documented in `plans/vga-retrace.md:610-624` (P6) and
`examples/dos-src/KEYECHO.C:15-29`: Borland's default-conio `putch()` echoes a character by
reading/advancing the cursor via INT 10h (AH=03/AH=02) **then writing the char byte DIRECTLY to
text-mode video RAM at B800:0000** — not via INT 21h, not via INT 10h AH=0Eh. Because zdos models
neither the B8000 text page nor teletype, the echoed byte lands in unmodeled memory and is lost, so
**the screen output of real text-mode DOS programs (TUIs, menus, editors, `putch`/`cprintf`, the bulk
of DOS utility UIs) is invisible**. KEYECHO therefore keeps a `bdos(2,...)` INT-21h workaround
(`examples/dos-src/KEYECHO.C:42-45`) to stay observable.

**Goal:** model text-mode video faithfully AND make the text screen **observable over the debugger
HTTP API** (`GET /api/screen`), so direct-video / teletype programs can be black-box tested —
closing the KEYECHO real-`putch` gate. All deterministic (CLAUDE prime directive: byte-identical
state at cycle N; no host wall clock; no fakes).

### What makes this tractable and deterministic

The text page is **just guest RAM** (a backing slab, like A0000 VRAM). INT 10h text services are
**host-serviced traps** that read/write that RAM + the BDA, each charged a deterministic synthetic
cost at the bridge (no ledger hole, CLAUDE #1). Cursor position/shape/mode/active-page are **BDA
state** (already byte-accurate guest RAM, `src/bios/bda.zig`). **Cursor *blink* is cosmetic and is
NOT modeled** (it is the one host-timing dependence both references carry — see §3). The
`/api/screen` read is a **pure peek** of the text-page bytes (the existing side-effect-free peek
path, `src/debug/controller.zig:621-622`), so it never perturbs the machine.

---

## 2. Investigation summary

### 2.1 zdos current state (cited)

| Surface | State today | file:line |
| --- | --- | --- |
| A0000 graphics VRAM | mapped as RAM-like MMIO via `mapMmio` + `getHostPtr` fast path | `src/devices/vga.zig:51-57,220-244`; `src/machine/machine.zig:233` |
| B8000/B0000 text page | **not backed** — UMA defaults `.unmapped`, writes dropped | `src/bus/memmap.zig:104-105`; `src/devices/vga.zig:53` (only A000 window) |
| INT 10h AH=00 set-mode | mode 13h full; non-13h records BDA only (`bda.setVideoMode`) | `src/bios/int10.zig:74-126` |
| INT 10h AH=02/03 cursor | pure BDA read/write at `OFF_CURSOR_POS+page*2`; AH=03 returns shape 0x0607 | `src/bios/int10.zig:40-50` |
| INT 10h AH=0E teletype | **explicit no-op** ("No VGA text device modeled") | `src/bios/int10.zig:53-56` |
| INT 10h AH=09/0A/06/07/13 | **missing** → `bios.unsupported` | `src/bios/int10.zig:63` |
| INT 10h AH=0F get-mode | reads BDA mode/cols/active-page | `src/bios/int10.zig:57-61` |
| BDA video fields | **ALL present**: mode(0x49), cols(0x4A), page-size(0x4C), cursor-pos(0x50, 8 pages), shape(0x60), active-page(0x62), CRTC base(0x63), rows(0x84), char-height(0x85) | `src/bios/bda.zig:22-34` |
| BDA boot defaults | mode=0x03, cols=80, active-page=0 (80×25 color text at boot) | `src/bios/bda.zig:108-110` |
| Bus region mechanism | `mapMmio(phys, len, MemHandler)` sets pages `.mmio`, device exposes `read8/write8/getHostPtr/peek8` | `src/bus/bus.zig:560-575`; `src/devices/vga.zig:220-259` |
| VRAM snapshot | `vram` is **NOT** in any `Snapshot` struct — `Vga.Snapshot` is DAC+regs only; VRAM bytes are dupe'd by the **snapshot caller** (out-of-band, like `bus.ram`) | `src/machine/machine.zig:515-517` (doc comment only); `src/debug/controller_test.zig:304,329`; `src/bus/bus.zig:933-936,940` |
| Debugger peek | `peekMemPhys`/`peekMem` via `bus.peekBlock` — pure, never device read handlers | `src/debug/controller.zig:619-629` |
| Memory-regions API | `regions_table` lists ram / vram(A0000) / ems_frame | `src/debug/controller.zig:702-706` |
| `/api/console` | mirrors the **DOS CON device** capture buffer (INT 21h stream), NOT the VGA screen | `src/debug/controller.zig:641-650`; `src/dos/devices.zig:14-32` |
| API command flow | `server.zig` route → `queue.Command` → `worker.drainOne` → typed `Response` | `src/api/server.zig:273-277`; `src/api/worker.zig:62-120`; `src/api/queue.zig:62-235` |
| Corpus text fixture | `VIDTEXT.C` exercises AH=0F/02/03 + AH=0E (cursor advance NOT asserted — deferred text subsystem) | `examples/dos-src/VIDTEXT.C:22-35` |
| KEYECHO | real `putch()` no longer hangs (0x3DA modeled) but echo unobservable; keeps `bdos(2,...)` | `examples/dos-src/KEYECHO.C:15-29` |

**Key finding — the BDA is already complete.** Every text-mode field this plan needs already exists
in `src/bios/bda.zig` with the correct offsets, and `initDefaults` already boots the machine into
mode 0x03 / 80 cols / page 0. The mode-13h `setModeVga13` already resets cursor positions for pages
0..7 and the active page (`src/bios/int10.zig:118-125`). So this plan adds **a text-page backing
region + the INT 10h text services that read/write it + a `/api/screen` read** — it does NOT need
new BDA plumbing.

### 2.2 How dosbox-staging models the text page + text output

**Text-page memory mapping.** The BIOS mode table marks modes 0–3 / 7 as `M_TEXT` at base 0xB8000
(0xB0000 for mode 7 mono), page size 0x1000, 8 pages
(`references/dosbox-staging/src/ints/int10_modes.cpp:30-37`):

```
{ 0x003, M_TEXT, 720, 400, 80, 25, 9, 16, 8, 0xB8000, 0x1000, 100, 449, 80, 400, 0 }
{ 0x007, M_TEXT, 720, 400, 80, 25, 9, 16, 8, 0xB0000, 0x1000, 100, 449, 80, 400, 0 }
```

In `M_TEXT` mode the page handler at VGA_PAGE_B8 (0xB8000/4096) is `vgaph.text`
(`references/dosbox-staging/src/hardware/video/vga_memory.cpp:1057-1061`), and the
window-base/mask is chosen by `(vga.gfx.miscellaneous >> 2) & 3` — case 3 maps VGA_PAGE_B8
(`:1102-1106`). The `VGA_TEXT_PageHandler` (`:556-596`) splits writes into plane 0 (char) / plane 1
(attr) / plane 2 (font) by `vga.seq.map_mask`, but the **CPU-visible layout the guest sees is the
flat interleaved char/attr cell** (byte0=char, byte1=attr) — the plane split is an internal storage
detail. zdos does **not** need the plane machinery: it models the flat char/attr slab the guest
reads/writes (this is exactly what INT 10h `WriteChar` and a direct `putch` both produce).

**Char/attribute cell format.** Confirmed in `WriteChar` M_TEXT path
(`references/dosbox-staging/src/ints/int10_char.cpp:526-538`):

```cpp
uint16_t address = page*PAGE_SIZE + (row*cols+col)*2;
PhysPt where = CurMode->pstart + address;   // pstart = 0xB8000 (color) / 0xB0000 (mono)
mem_writeb(where, chr);
if (useattr) mem_writeb(where+1, attr);
```

So cell = `{char, attr}` at `pstart + page*page_size + (row*cols + col)*2`. Read-back is symmetric
(`ReadCharAttr`, `:431-446`: `mem_readw(where)`).

> **Finding F1 — single width source = the BDA.** `WriteChar` reads `cols` from BDA `NB_COLS`
> (`int10_char.cpp:524`) but `INT10_ScrollWindow` reads `ncols`/`nrows` from `CurMode` geometry
> (`twidth`/`theight`, `:196` `BIOS_NCOLS;BIOS_NROWS`). zdos has **no text `CurMode` table** — the BDA
> is the single source of truth — so **all** zdos helpers (`writeCharCell`, `teletype`, `scrollWindow`)
> read the *live* BDA `OFF_VIDEO_COLS` for the stride and `OFF_NB_ROWS+1` for the row count, NOT the
> §3.1 `TEXT_COLS/TEXT_ROWS` constants. spice86 already does this uniformly (BDA `ScreenColumns`
> everywhere). For all v1 modes BDA-cols == twidth, so this is harmless, but uniform BDA prevents a
> shear bug on 40-col modes / scroll.

> **Finding F2 — teletype attribute byte is NOT touched.** The AH=0E text-mode path is
> `WriteChar(..., useattr=false)`: it writes the **char byte ONLY and leaves the attribute byte
> untouched** (`int10_char.cpp:535-536`: `mem_writeb(where,chr); if (useattr) mem_writeb(where+1,attr);`)
> — this preserves the cell's existing color. zdos copies dosbox/real-BIOS exactly: **`useattr=false`
> ⇒ do not write `cell+1`.** Do NOT copy spice86's `WriteCharacter`, which writes `DefaultAttribute`
> (0x07) when `!useattr` (`VgaFunctionality.cs:1103-1104`) — that would erase colored backgrounds.

**Teletype (AH=0E), the load-bearing semantics** (`int10_char.cpp:743-810`, `teletype_output_attr`):
- `chr == 7` (BEL): **busy-waits on `PIC_FullIndex()` for 333 ms** to beep (`:752-772`) —
  **HOST-TIMING-DEPENDENT, MUST NOT COPY** (see §3 determinism lens).
- `chr == 8` (BS): `if (cur_col>0) cur_col--`.
- `chr == '\r'`: `cur_col = 0`.
- `chr == '\n'`: `cur_row++` (note: dosbox does NOT reset col on LF — `:475` "Seems to break an old
  chess game"; we copy this faithfully).
- default: `WriteChar(cur_col,cur_row,page,chr,attr,useattr)`; `cur_col++`.
- wrap: `if (cur_col==ncols) { cur_col=0; cur_row++; }`.
- scroll (**Finding F4**): `if (cur_row==nrows) { fill = attr-at-cursor (text); INT10_ScrollWindow(0,0,nrows-1,ncols-1,-1,fill,page); cur_row--; }`.
  The fill attribute is the **attr byte of the cell at the current cursor**, read via `INT10_ReadCharAttr`
  at the cursor *before* the scroll (`int10_char.cpp:798-804`: `chat=ReadCharAttr; fill=(chat>>8)`).
  zdos copies this — the `readCharCell` helper reads the cursor cell's attr first. Do **NOT** copy
  spice86, which fills the new bottom line with attr 0/black (`VgaFunctionality.cs:628`
  `new CharacterPlusAttribute(' ', 0, false)`). (Note: AH=06/07 scroll fills with **BH**, a distinct
  caller-supplied attr — keep the two fill sources separate.)
- finally `INT10_SetCursorPos(cur_row,cur_col,page)`. The BDA cursor word is decomposed
  **`col = word & 0xFF`, `row = word >> 8`** and re-packed `(row<<8)|col` (`int10_char.cpp:389-390`:
  col at `CURSOR_POS+page*2`, row at `+1`; matches AH=02 DX = `(DH=row)<<8 | (DL=col)`) — **Finding F7**.

**Scroll (AH=06/07 → `INT10_ScrollWindow`)** (`int10_char.cpp:193-294`): takes the **inclusive
lower-right** corner — CX = upper-left (`CH=rul,CL=cul`), DX = lower-right (`DH=rlr,DL=clr`). It clamps
`rlr` to `nrows-1` and `clr` to `ncols-1` (`:199-200`), then internally does `clr++` (`:201`) to make
the column range exclusive; computes `base = pstart + page*page_size`; copies rows (`TEXT_CopyRow`) by
`nlines` then fills exposed rows with `(attr<<8|' ')` (`TEXT_FillRow`). `nlines==0` ⇒ clear the whole
window (`rlr-rul+1` rows, `:233-235`). AH=06 passes `-reg_al` (scroll up), AH=07 passes `+reg_al`
(down); `reg_al==0` ⇒ clear (`references/dosbox-staging/src/ints/int10.cpp:96-100`).

> **Finding F3 — scroll bounds (spell out for the implementer):** zdos's `scrollWindow` clamps `rlr`
> to `nrows-1` and `clr` to `ncols-1`, treats the **column range as inclusive `[cul,clr]`** (loop
> `clr-cul+1` cells per row; dosbox's internal `clr++` is just its exclusive-loop convention), and
> `AL=0` clears the **whole window** (`rlr-rul+1` rows). Cite `int10_char.cpp:197-236,264-295`.

**Write char/attr (AH=09/0A → `INT10_WriteChar`)** (`int10.cpp:105-112`): AH=09 uses BL as the
attribute (`useattr=true`), AH=0A ignores attr; both write CX copies at the **current cursor** without
advancing it.

**Write string (AH=13 → `INT10_WriteString`)** (`int10_char.cpp:862-886`): routes each char through
`teletype_output_attr` with **`use_attribute = true` ALWAYS** (`:879`; distinct from F2's AH=0E
text-mode `useattr=false`), honoring CR/LF/BS/BEL exactly like teletype. AL bit1 (`flag&2`) ⇒ the
string is interleaved char/attr pairs (re-read per char, `:875-878`); AL bit0 ⇒ cursor advances/stays,
and when **bit0=0** the routine **restores the cursor to its original (saved) position** (`:883-884`).

> **Finding F5 — AH=13 specifics:** zdos's AH=13 saves the entry cursor, routes each char through
> `teletype(..., useattr=true)` (always write the attr byte — opposite of AH=0E), and **restores the
> saved cursor when AL bit0=0** (only advances/keeps when bit0=1). BEL inside the string is the same
> deterministic silent no-op as in teletype (see D-TM-BEL). Cite `int10_char.cpp:862-886`.

**INT 10h dispatch** (`references/dosbox-staging/src/ints/int10.cpp:47-135`): AH=00 SetVideoMode,
02 SetCursorPos, 03 get cursor+shape, 06/07 ScrollWindow, 08 ReadCharAttr (`:102-103`), 09/0A
WriteChar, 0E TeletypeOutput, 0F get videomode, 13 WriteString.

**Text→display render path** (`VGA_TEXT_Draw_Line`,
`references/dosbox-staging/src/hardware/video/vga_draw.cpp:857-895`): reads char/attr cells, looks
up the font glyph, applies fg/bg from the attribute, **and overlays a blinking cursor** driven by
`vga.draw.cursor.count` and `vga.draw.blink` (`:943,1019-1027,1527-1532`; `VGA_SetBlinking`
`:1334-1345`). **This entire path — glyph rasterization, blink phase — is a renderer concern and is
host-timing-driven; zdos does NOT model it.** zdos's "render" of the text screen is the
character-grid string the `/api/screen` peek produces from the raw cells (§4), not a pixel raster.

### 2.3 How spice86 models the text page + text output

**Text-page memory mapping.** spice86 registers a single `VideoMemory` device at A0000 spanning the
whole VGA window (`references/spice86/.../Devices/Video/Renderer.cs:81-83`:
`memory.RegisterMapping(0xA0000, _memory.Size, _memory)`), with text segments
ColorText=0xB800 / Mono=0xB000 (`.../Memory/MemoryMap.cs:40,70`;
`.../InterruptHandlers/VGA/VgaConstants.cs:15,20`). Text cells are addressed through normal memory.

**Char/attribute cell format + address** (`VgaFunctionality.cs`):
- `TextAddress(cp)` (`:711-715`): `stride = ScreenColumns*2; pageOffset = VideoPageSize*page;
  return pageOffset + y*stride + x*2` — **identical to dosbox**.
- `WriteCharacter` text path (`:1096-1113`):
  `_memory.UInt16[StartSegment, offset] = (attr<<8 | char)` — flat cell write through normal memory.
- `ReadChar` (`:133-145`) reads the same word back.

**Teletype** (`WriteTeletype`, `VgaFunctionality.cs:598-625`): identical control-char handling
(BS/CR/LF/default+advance, then wrap+scroll) — **except BEL is `//FIXME should beep` (a deterministic
no-op)**, NOT dosbox's busy-wait. spice86 also resets cursor positions for 8 pages and active page at
mode-set (`:700-718`), like zdos's `setModeVga13`.

**Observability / introspection (spice86 is introspection-focused — relevant precedent).** spice86
exposes per-cell text reads over its MCP server (`references/spice86/.../Mcp/EmulatorMcpTools.cs`):
- `video_read_character` (page,x,y) → char+attribute (`:967-987`).
- `read_video_cursor` → cursor pos + char/attr at cursor (`:936-948`).
- `read_video_state_detailed` → BIOS video mode, cursor, ScreenColumns/ScreenRows
  (`:885-905`).
- `VideoWriteText` → `WriteString` (a mutator; not what we want for a side-effect-free read).
- `TakeScreenshot` (`:1201-1218`) → renders pixels (the renderer, host-ish — avoid).

spice86 offers **per-cell** reads but **no whole-screen grid dump**. zdos's `/api/screen` (§4)
improves on this: a single side-effect-free read returning the full 80×25 grid as text — better
suited to black-box assertions than 2000 per-cell calls.

### 2.4 Determinism lens — what to copy vs avoid

| Aspect | dosbox-staging | spice86 | zdos decision |
| --- | --- | --- | --- |
| Text cell layout | flat `{char,attr}` at `pstart+page*sz+(row*cols+col)*2` | identical | **COPY** — guest RAM slab, flat cells |
| Cell-stride width source | `WriteChar` BDA cols, `ScrollWindow` `CurMode` twidth (mixed) | BDA `ScreenColumns` everywhere | **FOLLOW spice86 (F1)** — BDA `OFF_VIDEO_COLS`/`OFF_NB_ROWS+1` uniformly (zdos has no text CurMode table) |
| AH=0E teletype attr byte | char only; attr untouched (`:535-536` `useattr=false`) | writes `DefaultAttribute` 0x07 (`:1103-1104`) | **COPY dosbox (F2)** — `useattr=false` ⇒ never touch `cell+1` (don't erase colors) |
| Teletype end-of-screen scroll fill | attr **at cursor** via `ReadCharAttr` (`:798-804`) | 0/black (`:628`) | **COPY dosbox (F4)** — fill with the cursor cell's attr (AH=06/07 still fill with BH) |
| Teletype BS/CR/LF/wrap/scroll | `int10_char.cpp:743-810` | identical (`:598-625`) | **COPY** the exact control-char + scroll semantics |
| LF does not reset column | yes (`:475` chess-game note) | (cursor.X unchanged on `\n`) | **COPY** (faithful) |
| BEL (chr 7) | **busy-wait 333 ms on `PIC_FullIndex()`** | `//FIXME should beep` no-op | **AVOID dosbox; follow spice86's no-op** (host-timing; see §3) |
| Cursor **blink** | `vga.draw.cursor.count`/`vga.draw.blink` host-timed | renderer | **NEVER model** (cosmetic, host-timed) |
| Glyph rasterization / font tables | full raster path | full raster path | **NOT modeled** (renderer concern; `/api/screen` returns chars, not pixels) |
| Cursor **position/shape** | BDA `CURSOR_POS`/`CURSOR_TYPE` | BDA | **COPY** — already in `src/bios/bda.zig`, deterministic |
| Multiple display pages | 8 pages, active-page start address | 8 pages | **v1 = page 0 only** (defer 1–7, §3 D-TM2) |
| Screen read | screenshot (pixels) | per-cell text reads | **whole-grid text peek** (`/api/screen`, §4) — pure |

---

## 3. Design — text page region + INT 10h text services

### 3.1 The text page as a memory region

Back the text page in the VGA device and map it through the bus, exactly mirroring the A0000 path.

**Geometry / cell format constants** (add to `src/devices/vga.zig`, alongside the mode-13h block at
`:50-64`):

```zig
/// Color text page window (mode 0-3): B800:0000. Mono (mode 7): B000:0000.
pub const TEXT_COLOR_PHYS: u32 = 0xB8000;
pub const TEXT_MONO_PHYS:  u32 = 0xB0000;
/// One real-mode segment (32 KiB) is the addressable window for each text base
/// (dosbox MEM_SetPageHandler(VGA_PAGE_B8, 8, ...) = 8 pages = 32 KiB).
pub const TEXT_WINDOW_LEN: u32 = 0x8000;
/// Standard 80x25 text geometry (mode 3). cols/rows live in the BDA; these are
/// the v1 defaults the mode-set programs.
pub const TEXT_COLS: u16 = 80;
pub const TEXT_ROWS: u16 = 25;
/// One display page = 0x1000 bytes (dosbox table plength for modes 2/3/7).
pub const TEXT_PAGE_SIZE: u32 = 0x1000;  // 80*25*2 = 4000, rounded to 0x1000
```

**Backing store (Finding 2 — commit to two `[0x8000]u8` slabs).** Allocate **two** text-page slabs in
the VGA device exactly like `vram` (`src/devices/vga.zig:122,171-175`), both decl'd `[]u8 = &.{}`:
- `text_vram: []u8 = &.{}` — color text, mapped at B8000, `len = TEXT_WINDOW_LEN = 0x8000`.
- `text_vram_mono: []u8 = &.{}` — mono text, mapped at B0000, `len = 0x8000`.

Each is `0x8000` (page-multiple); they are **adjacent and non-overlapping**, together covering
B0000–BFFFF. (Mapping both is the same mechanism, so it costs nothing extra over color-only — recommend
both; see D-TM3. If the human insists on deferring mono per Q3, map only B8000 and assert-flag a mode-7
set-mode — but the plan picks **both**.) Zero-filled at reset (CLAUDE #5).

**Init / deinit / reset (Finding 3 — Zig 0.16 idioms).** Allocate both slabs in `Vga.init` and assign
them in the **single struct literal** (mirror `vga.zig:171-175`):
`self.* = .{ .vram = vram, .text_vram = tvram, .text_vram_mono = tmono };`. Free **both** in `deinit`.
In `reset`, zero both with **`@memset(self.text_vram, 0)`** / `@memset(self.text_vram_mono, 0)`
alongside the existing `@memset(self.vram, 0)` at `vga.zig:185` — **NOT `@splat`** (`@splat` is for
fixed arrays/vectors, not heap slices like these).

**Bus mapping.** Add a `textMemHandler()` and a `textMonoMemHandler()` (two `MemHandler`s, ctx=self),
each indexing its slab by `phys - TEXT_COLOR_PHYS` / `phys - TEXT_MONO_PHYS` — structurally identical
to the A0000 handler (`src/devices/vga.zig:220-259`). In `machine.wire()` after the A0000 mapping
(`src/machine/machine.zig:233`):

```zig
_ = self.bus.mapMmio(devices.vga.TEXT_COLOR_PHYS, devices.vga.TEXT_WINDOW_LEN, self.vga.textMemHandler());
_ = self.bus.mapMmio(devices.vga.TEXT_MONO_PHYS,  devices.vga.TEXT_WINDOW_LEN, self.vga.textMonoMemHandler());
```

> **R4 — both `getHostPtr` AND `peek8` are mandatory on each text handler.** `getHostPtr` is the
> direct-write fast path: a `mov [es:di],al` to B800 is charged as a **normal guest memory write** (no
> trap, no ledger hole — CLAUDE #1), exactly as the A0000 path is (`src/devices/vga.zig:36-41`). `peek8`
> is what the debugger read path uses — `/api/screen`'s `peekBlock` → `peekPhys8` calls `h.peek8(m)` and
> falls back to `not_peekable_fill` if it is absent (`src/bus/bus.zig:664-670`). A handler with only
> `getHostPtr` would make `/api/screen` return fill bytes, not real cells. Implement **both** (the
> A0000 handler already does, `:220-259` — copy the pattern). Direct guest writes (Borland `putch`
> direct-video) now land in `text_vram` and read back.

> **Decision D-TM1: model the flat char/attr slab, NOT the plane machinery.** dosbox's
> `VGA_TEXT_PageHandler` splits writes into char/attr/font planes via `seq.map_mask`/`read_map_select`
> (`vga_memory.cpp:556-596`). The CPU-visible layout is the flat interleaved `{char,attr}` cell, which
> is what every text-mode guest (direct-video and INT 10h) reads/writes. zdos models the flat slab;
> the plane split is an internal dosbox storage choice with no guest-observable difference for the
> chained text mapping. Flag (don't fake) if a guest ever drives `seq.map_mask` for plane-2 font
> upload — that is the deferred character-generator-RAM feature (§7 Q5).

**Mode selection (which page is active).** Set-mode (INT 10h AH=00) selects text vs graphics:
- mode 13h → the A0000 graphics path (`setModeVga13`, already present).
- mode 0/1/2/3 → 80×25 (or 40×25) **color text** at B8000; mode 7 → 80×25 **mono text** at B0000.
- The active text page slab is always **backed** (mapped at `wire`), so a direct write works
  regardless of the BDA mode; the BDA `OFF_VIDEO_MODE`/`OFF_VIDEO_COLS` records which mode the INT 10h
  services and `/api/screen` should interpret. No remapping is needed — both A0000 and B8000 are
  permanently mapped (real hardware does the same; the CRTC just scans one or the other). This is
  simpler and more faithful than dosbox's per-mode `MEM_SetPageHandler` remap and is fully
  deterministic.

**Determinism / snapshot (CRITICAL — `text_vram` is NOT a `Snapshot` struct field).** `text_vram`
(and `text_vram_mono`) is guest memory that must round-trip across snapshot/restore — but, **exactly
like `vram` and `bus.ram`, it is NOT placed in any `Snapshot` struct.** Those large slabs are copied
**out-of-band by the snapshot caller**: the caller `alloc.dupe(u8, machine.vga.vram)` before, and
`expectEqualSlices`/restores it into the re-init'd machine's slab after (`controller_test.zig:304,329`);
`Bus.Snapshot` deliberately excludes `ram` (`bus.zig:933-936,940`); `machine.zig:515-517` is a *doc
comment* describing this caller-copy pattern, not a struct field. So:
- The snapshot caller dupes `machine.vga.text_vram` (and `text_vram_mono`) **byte-for-byte** and
  restores them into the re-init'd machine's slabs — the same treatment as `vram`/`bus.ram`. **Do NOT
  add `text_vram` to `Vga.Snapshot` or `Machine.Snapshot`.**
- The handler's host pointer (`getHostPtr` mapping) is **correctly NOT snapshotted**: `wire()` re-runs
  `mapMmio` on restore, which re-establishes the slab→bus pointer. A snapshotted host pointer would be
  a determinism hazard (CLAUDE #5); re-deriving it from `wire()` is the faithful path.
- **Instruction:** extend the `machine.zig:515-517` doc comment to mention `text_vram`/`text_vram_mono`
  alongside `vram` (so the caller-copy contract is documented for both).

Add `text_vram`/`text_vram_mono` zeroing to `Vga.reset` (`src/devices/vga.zig:184-195`, via `@memset`).
Add the region to the debugger `regions_table` (`src/debug/controller.zig:702-706`):
`.{ .kind = .text_vram, .phys_start = 0xB8000, .len = 0x8000 }` (extend the `kind` enum at `:130`).

### 3.2 INT 10h text services — v1 scope, deferrals honest

Add to `src/bios/int10.zig` the dispatch + handlers. **Each is a host-serviced trap charging the
bridge's deterministic synthetic cost** (the same path AH=00/02/03/0F already use — no ledger hole,
CLAUDE #1). Reads/writes go through the bus to `text_vram` + the BDA. The active page is **page 0
only** for v1 (D-TM2). All semantics mirror `int10_char.cpp` (cited inline).

**v1 services:**

| AH | Service | Semantics (mirror dosbox) | cite |
| --- | --- | --- | --- |
| 00 | Set mode | text modes 0–3 (color, B8000) + 7 (mono, B0000): set BDA mode/cols/page-size, **`OFF_NB_ROWS = rows-1`** (= 24 for 80×25, mirror `int10.zig:113`), CRTC-base; clear the text page if `!no-clear` with a **16-bit `0x0720` word fill** (space, gray-on-black) over cols*rows cells — NOT a byte memset (mode 7 uses `0x0720` too, mono attr 0x07); reset cursor pos pages 0–7 + active page | `int10_modes.cpp:30-37`, FinishSetMode |
| 01 | Set cursor shape | **new (v1):** write CX (start/end scanlines) to BDA `OFF_CURSOR_SHAPE` | `int10.cpp` AH=01; `bda.zig:26` |
| 02 | Set cursor pos | **already implemented** (BDA `OFF_CURSOR_POS+page*2 = DX`) | `src/bios/int10.zig:40-44`; `int10_char.cpp:384-406` |
| 03 | Get cursor pos+shape | **already impl for DX; FIX shape:** read CX from BDA `OFF_CURSOR_SHAPE` instead of hardcoded `0x0607` (`int10.zig:49`) so set-then-get round-trips | `src/bios/int10.zig:45-50`; `bda.zig:26` |
| 06 | Scroll window up | `INT10_ScrollWindow(CH,CL,DH,DL,-AL,BH,0xFF)`; inclusive lower-right (F3); AL=0 ⇒ clear window | `int10.cpp:96-97`; `int10_char.cpp:197-236,264-295` |
| 07 | Scroll window down | `INT10_ScrollWindow(CH,CL,DH,DL,+AL,BH,0xFF)` | `int10.cpp:99-100` |
| 08 | Read char+attr at cursor | **new (v1):** `readCharCell` at the BDA cursor → AL=char, AH=attr (one-liner reusing F4's helper) | `int10.cpp:102-103` |
| 09 | Write char+attr at cursor ×CX | `WriteChar(col,row,page,AL,BL,useattr=true)` ×CX; cursor NOT advanced | `int10.cpp:105-108` |
| 0A | Write char at cursor ×CX | `WriteChar(...,useattr=false)` ×CX (char only, attr untouched — F2) | `int10.cpp:110-111` |
| 0E | Teletype output AL | the full control-char + wrap + scroll path (BS/CR/LF/default+advance), **`useattr=false`** in text mode (attr byte untouched — F2); end-of-screen scroll fills with attr-at-cursor (F4); advances + writes BDA cursor; **BEL = deterministic no-op** | `int10_char.cpp:743-810` |
| 0F | Get mode | **already implemented** | `src/bios/int10.zig:57-61` |
| 13 | Write string | `INT10_WriteString(DH,DL,AL,BL,ES:BP,CX,BH)` — routes each char through teletype with **`useattr=true` ALWAYS** (F5), AL bit0=advance/keep cursor (bit0=0 ⇒ **restore original cursor**), bit1=cells carry attr; CR/LF/BS/BEL like teletype | `int10.cpp:594-595`; `int10_char.cpp:862-886` |

**Shared helpers to add (mirroring dosbox's externally-callable functions).** **All read the LIVE BDA
for geometry** — cols from `OFF_VIDEO_COLS`, rows from `OFF_NB_ROWS+1` (Finding F1) — NOT the §3.1
`TEXT_COLS/TEXT_ROWS` constants (those are only the set-mode defaults):
- `writeCharCell(cpu, page, row, col, chr, attr, useattr)` — the §2.2 cell write to
  `pstart + page*PAGE_SIZE + (row*cols+col)*2` (cols = live BDA cols) via `cpu.bus.writePhys8`.
  `pstart` = B8000 for a color text mode, B0000 for mode 7 (from the BDA mode / `OFF_CRTC_ADDRESS`).
  **`useattr=false` ⇒ write the char byte ONLY; do NOT touch `cell+1`** (Finding F2 — never write a
  default attr).
- `readCharCell(cpu, page, row, col) -> {chr, attr}` — symmetric read (used by the F4 scroll fill-attr
  AND AH=08).
- `scrollWindow(cpu, rul,cul,rlr,clr, nlines, attr, page)` — the copy-rows-then-fill logic
  (`int10_char.cpp:197-236,264-295`), text-mode only for v1: clamp `rlr→rows-1`, `clr→cols-1`, inclusive
  `[cul,clr]` columns, `nlines==0 ⇒ clear whole window` (Finding F3). Fill attr is the **caller's** arg
  (BH for AH=06/07; attr-at-cursor for the teletype end-of-screen scroll, F4).
- `teletype(cpu, chr, attr, useattr)` — the §2.2 control-char machine, reading/writing the BDA
  cursor (`OFF_CURSOR_POS`, decomposed `col=word&0xFF`/`row=word>>8`, re-packed `(row<<8)|col` — F7),
  cols (`OFF_VIDEO_COLS`), rows (`OFF_NB_ROWS`+1). On end-of-screen it reads the cursor cell's attr
  (`readCharCell`) **before** scrolling and passes it as the fill (F4). **BEL = silent no-op** (cursor
  unchanged). Calls `writeCharCell(..., useattr)` + `scrollWindow`. Replaces the AH=0E no-op at
  `src/bios/int10.zig:53-56`. (AH=13 calls the same `teletype` with `useattr=true` always — F5.)

> **Decision D-TM-BEL: BEL (chr 7) is a deterministic no-op, NOT dosbox's busy-wait.** dosbox beeps
> by programming PIT ch2 + busy-waiting on `PIC_FullIndex()` for 333 ms
> (`int10_char.cpp:752-772`, busy-wait loop `:760-767`) — a host-wall-clock dependence that violates
> CLAUDE #2/#3. spice86 makes
> it a no-op (`VgaFunctionality.cs:601-603` `//FIXME should beep`). zdos follows spice86: teletype of
> BEL leaves the cursor unchanged and does nothing else. **This applies to BOTH the AH=0E teletype path
> AND the AH=13 write-string path** (write-string routes each char through the same `teletype` helper,
> so BEL is the same silent no-op there) — never copy dosbox's `PIC_FullIndex` busy-wait in either
> path. (A future faithful beep would program PIT
> ch2 — which zdos already models, `src/devices/pit.zig` — and let cycle-derived emulated time gate
> the duration; out of v1 scope, flag.)

**Deferred (flagged, not faked):**

> **Decision D-TM2: display pages 1–7 deferred — v1 is page 0 only.** The BDA already stores 8 cursor
> positions and an active-page byte (`bda.zig:25,27`), and `setModeVga13` already resets all 8
> (`int10.zig:121-125`), so the *state* is present and round-trips via the bus-RAM snapshot. But v1 INT
> 10h services operate on page 0 (BH ignored beyond 0), and there is **no AH=05 set-active-page in v1**,
> so the BDA `OFF_ACTIVE_PAGE` stays 0. `/api/screen` reads the **BDA active page** (Finding 12) — which
> is page 0 in v1, but the read is written against the active-page byte so it is already correct when
> AH=05 lands. Multi-page (AH=05 + the page-start-address CRTC scroll) is deferred until a guest needs
> it (BaK is graphics; the utility-UI class generally uses page 0). The cell-address helper already takes
> a `page` param so adding page 1–7 later is a parameter change, not a rewrite.

> **Decision D-TM3: map BOTH text bases (color B8000 + mono B0000) — they share one mechanism.** v1
> allocates `text_vram` (B8000) and `text_vram_mono` (B0000), each a `[0x8000]u8` slab, and maps both at
> `wire()` (Finding 2). Mapping mono costs nothing extra over color-only (same `mapMmio` + handler
> pattern), and real machines have both, so a mode-7 program's writes are never lost. The v1 test corpus
> + `/api/screen` still **default to the active page** the BDA reports (mode 3 boots color B8000;
> `initDefaults` `bda.zig:108`), but `/api/screen` reads the base implied by the BDA mode so a mode-7
> guest renders from B0000. (If the human insists on deferring mono per Q3, drop the B0000 mapping and
> assert-flag a mode-7 set-mode — but the plan picks **both**.)

> **Deferred: graphics-mode INT 10h text (AH=0E/09 in mode 13h).** dosbox rasterizes the glyph into
> the framebuffer via the font tables (`int10_char.cpp:526-730` non-text branch). zdos's AH=0E stays
> a no-op in graphics modes (as today) — flagged; the v1 text services are text-mode only. (BaK draws
> its own glyphs; it does not use BIOS text output in mode 13h.)

> **Deferred: character-generator / font RAM (INT 10h AH=11, plane-2 font upload).** Not needed for
> the flat char/attr model (D-TM1); flag if a guest uploads a custom font.

### 3.3 Cycle cost (no ledger hole)

Each INT 10h text service is a **host-serviced trap** dispatched at the BIOS bridge, which already
charges a fixed synthetic base cost per trap (the same mechanism AH=00/02/03/0F/10 use today). The
text services add only guest-memory writes (to `text_vram` + BDA) through the bus, each charged as
normal memory accesses. **Direct guest writes** to B8000 (the `putch` path) go through the
`getHostPtr` fast path and are charged as ordinary `mov` memory writes by the CPU — no trap, no
synthetic cost, no hole (identical to the A0000 reasoning, `src/devices/vga.zig:36-41`). So there is
**no ungoverned text-video cycle hole** (CLAUDE #1).

### 3.4 Determinism & snapshot summary

- `text_vram`/`text_vram_mono` are guest memory: deterministic (zero-init at reset), and round-trip
  via the **caller-copy** path (dupe + restore, like `vram`/`bus.ram`) — **NOT** a `Snapshot` struct
  field. The hostPtr is re-derived by `wire()`'s `mapMmio` on restore, so it is correctly unsnapshotted.
- Cursor pos/shape/mode/cols/active-page are **BDA bytes** = guest RAM, already in the bus RAM slab
  snapshot, already deterministic.
- INT 10h text services are pure host traps over guest RAM — no host time, no RNG, no float.
- **NO cursor blink, NO glyph render timing, NO host clock, NO BEL busy-wait.**
- `/api/screen` is a pure peek (§4) — never perturbs `machine.snapshot()`.

---

## 4. Observability — `GET /api/screen` (the headline goal)

Add a **side-effect-free screen read** that renders the active text page to a character grid string,
reading guest RAM via the existing peek path (`src/debug/controller.zig:621-622`) — never the device
read handlers, never mutating state. This is what makes text-mode output black-box testable and
closes the KEYECHO real-`putch` gate.

### 4.1 Rendering format

Render the **BDA active page** (`OFF_ACTIVE_PAGE`) of the active text base — color B8000 (or mono
B0000 if the BDA mode is 7) — as the cols×rows character grid (**Finding 12**: not a hardcoded page 0;
cols/rows read from the BDA so 40-col modes render correctly; the cell peek is `cols*rows*2` bytes).
The wire shape:

```json
{
  "cols": 80,
  "rows": 25,
  "mode": 3,
  "cursor": { "row": 2, "col": 7, "page": 0 },
  "text": "row0...\nrow1...\n...\nrow24...",
  "attrs": null
}
```

- `text`: 25 rows joined by `\n`, each row = the 80 cell **characters** (byte0 of each cell). Trailing
  spaces preserved (fixed-width grid). Non-printable bytes (< 0x20) rendered as-is or mapped to a dot
  — recommend **raw bytes** (faithful; the test can assert exact bytes) with a documented note. CP437
  high bytes (≥ 0x80) emitted as raw bytes too (the consumer decodes if it wants glyphs).
- `cols`/`rows`/`mode`: read from BDA (`OFF_VIDEO_COLS`, `OFF_NB_ROWS`+1, `OFF_VIDEO_MODE`).
- `cursor`: from BDA `OFF_CURSOR_POS` at the active page (`col = word & 0xFF`, `row = word >> 8` — F7).
- `attrs`: **optional, omitted (null) by default** (D-TM4). A `?attrs=1` query param returns a
  parallel attribute array (byte1 of each cell) hex-encoded — see Q2. The `?attrs=1` flag is parsed
  **server-side** (Finding 5): the worker always fills the full cells buffer (cheap); only the JSON
  serialization decides whether to emit the attribute array.

> **Decision D-TM4: plain-text rows by default; attributes opt-in.** The KEYECHO gate and the bulk of
> black-box assertions care about *which characters appear where*, not colors. Default to the
> character grid (small, human-readable, trivially assertable); expose attributes behind `?attrs=1`
> for tests that assert color (e.g. a TUI highlight). Keeps the common response small and the
> assertion path clean.

### 4.2 Plumbing (mirror `/api/console`)

The screen read is **a pure observation** like `console_get`, so it reuses that exact flow:

1. **Controller** (`src/debug/controller.zig`): add `pub fn screen(self, dst) ScreenView` that reads
   the BDA mode/cols/rows/cursor/**active-page** via `peekMemPhys(BDA_PHYS+off,...)`, picks the base
   (B8000, or B0000 if mode 7), then `peekMemPhys(base + active_page*page_size, dst[0..cols*rows*2])`
   (pure peek, Finding 12). Returns the raw cell bytes + the BDA scalars; the worker/JSON layer formats
   the grid. Mirrors `console()` at `:641-650`.
2. **Queue** (`src/api/queue.zig`): add `screen_get: void` to `Command` (a **`void`** command — the
   `?attrs` flag is NOT in the command; Finding 5); add a `ScreenResult` POD (cols/rows/mode/cursor +
   active-page + a `[MAX_SCREEN_CELLS]u8 cells` fixed array + len) and a `screen:` arm to `Response`.
   `MAX_CONSOLE=4096` (`:181`) is enough for the 80×25 char grid (2000) but the **cells** buffer needs
   4000 bytes → add a `MAX_SCREEN_CELLS = 80*25*2 = 4000` constant next to `MAX_CONSOLE` (Finding 4);
   the result is a pointer-free fixed array (the project's POD discipline, `queue.zig:182-185`).
3. **Worker** (`src/api/worker.zig`): add a `screenResp(ctrl)` (mirror `consoleResp`) that **always**
   fills the full `ScreenResult` cells from `ctrl.screen(...)` (cheap; the attrs decision is deferred to
   serialization); dispatch `.screen_get => screenResp(ctrl)` alongside `console_get`.
4. **JSON wire** (`src/api/json_wire.zig`): serialize `ScreenResult` → the §4.1 shape (decode cell
   byte0 into the `text` string rows). It receives an `attrs: bool` (from the server's query parse) and
   emits the hex attribute array only when set. **Sizing (Finding 4):** confirm `respondScreen` writes
   into `self.resp_buf` (32 KiB, `server.zig:103` `RESPONSE_BUF`) — the grid (~2 KiB) + optional hex
   attrs (~4 KiB) + JSON scaffolding fit comfortably.
5. **Server** (`src/api/server.zig`): add the route after `/api/console` (`:273-278`); parse `?attrs=1`
   from the **query** server-side (like `handleMemPeek`'s `queryU32`, `server.zig:587-589`) and pass it
   to the serializer (the command itself stays `void`, Finding 5):
   ```zig
   if (std.mem.eql(u8, path, "/api/screen")) {
       if (method != .GET) return self.methodNotAllowed(req);
       const want_attrs = (self.queryU32(query, "attrs") orelse 0) != 0;
       return self.submitAndRespondScreen(req, want_attrs); // void command; attrs drives serialization
   }
   ```

### 4.3 Relationship to `/api/console` — keep both

`/api/console` mirrors the **DOS CON device stream** (bytes a program wrote via INT 21h AH=02/09/40
to handle 1, `src/dos/devices.zig:14-32`). `/api/screen` reads the **VGA text screen** (the B8000
cell grid, where direct-video `putch` + INT 10h teletype land). They are **different surfaces**:
- A program using `bdos(2,...)`/`printf` (INT 21h) → visible on `/api/console`, NOT necessarily on
  `/api/screen` (DOS CON in zdos is a capture device, it does not also poke B8000).
- A program using `putch()` direct-video or INT 10h AH=0E → visible on `/api/screen`, NOT on
  `/api/console`.
- Real DOS CON *does* write the screen too, but zdos's CON is a capture seam (deterministic, headless)
  — see D-TM5.

**Keep both surfaces (LOCKED for v1).** They answer different questions and both are needed.

**Consumer impact (state it bluntly).** Because zdos's CON is a *capture* device that does **not** also
poke B8000, **`INT 21h AH=09` / `printf` output appears on `/api/console` but NOT on `/api/screen`**,
and `putch` / INT 10h teletype output appears on `/api/screen` but NOT on `/api/console`. So a TUI that
mixes `printf` (or `cprintf`/`puts`) with `putch`/direct-video has its output **split across the two
surfaces** — a test asserting the full screen of such a program must read both. This is the deliberate
v1 trade-off (faithful, deterministic capture seams over a synthesized merge).

> **Decision D-TM5 (LOCKED v1): `/api/console` and `/api/screen` stay DISTINCT — no mirroring.** It is
> tempting to push teletype/`putch` output into `/api/console` (or DOS CON output into the text page) so
> one read catches everything. Reject for v1: that conflates two distinct architectural surfaces and
> would make `/api/console` lie about what the DOS CON device received. The faithful v1 design is two
> independent reads.
>
> **Documented follow-up (NOT v1):** mirror DOS CON output into the text page so `/api/screen` shows
> everything a real screen would (real DOS CON *does* write the screen via the BIOS teletype). That is a
> faithful enhancement — route the CON device's writes through the same `teletype` helper — but it is
> out of v1 scope; flag it as a follow-up, do not silently merge the two reads.

---

## 5. Test strategy

### 5.1 The acceptance gate — KEYECHO with real `putch()`

**This is the headline test that closes the gate.** Revert the `bdos(2,...)` workaround in
`examples/dos-src/KEYECHO.C:42-56` to the real Borland `putch()` echo path; recompile via
`tools/bcc.sh`. Then in `tests/blackbox/keyecho_test.zig`:

1. Inject keys (the existing scancode-injection path, `:113-...`), run a bounded cap.
2. Read `GET /api/screen` and assert the echoed characters appear **at the cursor positions** the
   teletype/`putch` advanced to (row 0 fills left-to-right: `a` at (0,0), next key at (0,1), …).
3. Inject ESC → assert the program prints its `!` marker and **terminates cleanly** (ret 0) — the
   existing termination assertions (`:99-106`) stay.

This proves the whole direct-video / teletype class is observable and black-box testable. State it
plainly: **KEYECHO with real `putch()` echoing onto `/api/screen` is THE acceptance gate.**

> NOTE on `putch` exact path: BCC-3.1 `putch()` calls INT 10h AH=03 (get cursor) / AH=02 (set
> cursor) and writes the char byte directly to B800:0000 (`KEYECHO.C:20-24`). With the text page now
> backed, that direct write lands in `text_vram` and `/api/screen` reads it back. If `putch` also
> relies on the cursor having advanced via its own AH=02 calls, the grid + the BDA cursor stay
> consistent. (If a recon shows `putch` uses AH=0E instead on some build, the teletype path covers it
> identically.)

### 5.2 INT 10h teletype test (new corpus program or extend VIDTEXT)

Extend `examples/dos-src/VIDTEXT.C` (or a new `VTTYPE.C`) to **assert** the teletype output now that
it is modeled. Today VIDTEXT explicitly does NOT assert the post-teletype cursor (`VIDTEXT.C:22-35`,
"deferred text-subsystem"). Update it: set cursor (2,0), teletype `"Hi!"`, then either:
- a black-box test reads `/api/screen` and asserts cells (2,0..2)=`'H','i','!'` and the cursor
  advanced to (2,3); OR
- the program reads the cells back via AH=08 (read char+attr at cursor) / direct B800 read and prints
  them to CON, asserting via the oracle (see §5.4).

Add an explicit wrap+scroll case: teletype a string longer than 80 chars → assert it wraps to the
next row; teletype past row 24 → assert the screen scrolled up by one row (row 0 = old row 1).

### 5.3 Determinism (two-run byte-identity)

Mirror the existing determinism discipline (`tests/blackbox/keyecho_test.zig:86-106`,
`src/machine/determinism_test.zig`): run the same INT 10h text sequence on two fresh
machines/processes and assert (a) the `text_vram` bytes are byte-identical, AND (b) the `/api/screen`
render string is identical. The text page is guest RAM + the services are pure traps, so this holds
by construction. Assert `text_vram`/`text_vram_mono` round-trip via the **caller-copy** snapshot path
(dupe + restore + `expectEqualSlices`, exactly like the existing `vram` assertion at
`controller_test.zig:304,329`) — **NOT** via a `Snapshot` struct field (they are not in one).

### 5.4 Oracle angle — dosbox-x CAN give a golden for the text buffer

Unlike the 0x3DA retrace bits (excluded from goldens, `plans/io-oracle.md:172-179,399-402`), the
**text-buffer content after a deterministic INT 10h sequence IS a faithful cross-emulator golden** —
it is pure guest-observable device state (the same VRAM-readback discipline that already works for
mode 13h, `plans/io-oracle.md:105-132`, proven triple-mint byte-identical). A text-oracle band:
- A BC3.1 program issues a fixed INT 10h text sequence (set mode 3, teletype/write-char/scroll a
  known pattern), then **reads back the B800:0000 cells** (the first `cols*rows*2` bytes) and writes
  them as a binary blob via `fwrite` (the §1.2 capture mechanism, `plans/io-oracle.md:76-103`).
- Mint the golden under headless dosbox-x (`tools/oracle-io.sh`, `machine=vgaonly`); zdos reproduces
  it byte-identically offline (the cells are a pure function of the guest's INT 10h calls).
- This is the **K1/V-band analog for text** — slot it into the existing binary-blob harness
  (`src/dos/oracle_test.zig`, the `VGA_PASSING`-style corpus, `plans/io-oracle.md:315-341`). **Note
  it as a recommended follow-up band**, not a blocker for the feature.

**The one text value to EXCLUDE from a golden:** cursor *blink* phase (not modeled) and anything
render-timed — but the cursor *position* (BDA) IS a valid golden. The cell bytes are the deterministic
artifact.

### 5.5 Determinism grep-gate

The new text code is determinism-critical (integer/byte work; no `std.time`/float/RNG), and the gates
that cover it **already exist** — there is no new gate to add, only the existing ones to keep green:
- `src/bios/int10.zig` is **ALREADY embedded in the BIOS determinism gate**
  (`src/bios/determinism_test.zig:22`), so the new teletype/scroll/write-string helpers are
  auto-covered the moment they land. **Do NOT add `int10.zig` to the devices gate** (`pit_test.zig`):
  the devices gate `@embedFile`s only `src/devices/*` sources (`pit_test.zig:53-62`), and a
  cross-module `@embedFile("../bios/int10.zig")` would not compile / is the wrong module boundary.
- `src/devices/vga.zig` is **ALREADY** in the devices grep gate (`pit_test.zig:61`, added by the
  retrace work). This is the **only genuine new device surface** — the `text_vram`/`text_vram_mono`
  slabs + the two MMIO handlers — so the work just keeps `vga.zig` clean of the needles.
- `src/debug/controller.zig` (the `/api/screen` read path) is in the debug gate
  (`src/debug/determinism_test.zig:15`); `src/api/{queue,worker,server,json_wire}.zig` are in the api
  gate (`src/api/determinism_test.zig:23-27`). The new `screen` read + `ScreenResult` + serialization
  are auto-covered there.

**So P8's grep step is simply: confirm the existing BIOS / devices / api / debug gates still pass with
the new code.** No new `sources`-array entry is correct or needed.

---

## 6. Phased checklist

Each box ≈ one focused commit; `zig build test` (+ `test-blackbox`, `test-oracle`) stay green
throughout. Ordered so each phase is independently testable.

- [x] **P1 — Text-page backing region (two slabs).** Add the §3.1 geometry/cell constants + **two**
      `[0x8000]u8` slabs (`text_vram`@B8000, `text_vram_mono`@B0000) — alloc both in `Vga.init` (single
      struct literal), free both in `deinit`, `@memset(...,0)` both in `reset` (NOT `@splat`) — plus
      `textMemHandler()` / `textMonoMemHandler()` each with **both `getHostPtr` AND `peek8`** (+
      `read8/write8`) indexing its slab (mirror `vga.zig:122,171-259`). Map both in `machine.wire()`
      after `src/machine/machine.zig:233`:
      `mapMmio(TEXT_COLOR_PHYS, …, textMemHandler())` + `mapMmio(TEXT_MONO_PHYS, …, textMonoMemHandler())`.
      Unit-test: a direct bus write to B800:0000 (and B000:0000) reads back (both were dropped before).
      No INT 10h change yet.
- [x] **P2 — Snapshot round-trip for `text_vram` (caller-copy, NOT a struct field).** Confirm the
      snapshot **caller** dupes `machine.vga.text_vram`/`text_vram_mono` and restores them into the
      re-init'd machine's slabs (the same out-of-band path as `vram`/`bus.ram`; do **NOT** add a
      `Snapshot` struct field — see §3.1/§3.4). Extend the `machine.zig:515-517` doc comment to mention
      `text_vram` alongside `vram`. Add `.text_vram` to the debugger `regions_table`
      (`src/debug/controller.zig:130,702-706`). Test: write B800, snapshot (dupe slab), mutate, restore,
      `expectEqualSlices` byte-identical — **mirror the caller-copy pattern at `controller_test.zig:304,329`**
      (dupe + restore + `expectEqualSlices`), NOT a `Vga.Snapshot`/`Machine.Snapshot` field round-trip.
- [x] **P3 — INT 10h cell helpers + AH=09/0A write-char + AH=08 read.** Add `writeCharCell` (F2:
      `useattr=false` ⇒ char only) / `readCharCell` (§3.2, live BDA cols) and the AH=09 (attr) / AH=0A
      (no-attr) / **AH=08** (read char+attr — a one-liner on `readCharCell`) dispatch arms to
      `src/bios/int10.zig` (replace the `else` fallthrough at `:63` for these AHs). Unit/black-box test:
      AH=09 writes a char+attr at the cursor, read back via B800 + via AH=08.
- [x] **P4 — INT 10h AH=0E teletype + AH=06/07 scroll + AH=01/03 cursor shape.** Add `scrollWindow`
      (§3.2, `int10_char.cpp:197-236,264-295`, inclusive bounds F3) and the full `teletype` control-char
      machine (BS/CR/LF/wrap/scroll, **BEL no-op** D-TM-BEL, end-of-screen fill = attr-at-cursor F4,
      cursor word col=lo/row=hi F7) replacing the AH=0E no-op at `src/bios/int10.zig:53-56`. Wire AH=06/07.
      **Also: add AH=01 (write CX → BDA `OFF_CURSOR_SHAPE`) and FIX AH=03 to read the BDA shape** instead
      of the hardcoded `0x0607` (`int10.zig:49`), so set-then-get cursor shape round-trips. Test:
      teletype a string → cells land + cursor advances + wraps + scrolls (§5.2); AH=01 then AH=03 returns
      the set shape.
- [x] **P5 — INT 10h AH=00 text mode-set + AH=13 write-string.** Extend `setMode` to handle text
      modes 0–3 (B8000) / 7 (B0000): program BDA mode/cols/page-size, **`OFF_NB_ROWS = rows-1`** (F8),
      CRTC-base + clear the page with a **16-bit `0x0720` word fill** over cols*rows cells (F6 — NOT a
      byte memset) per FinishSetMode (`int10_modes.cpp:30-37`). Add AH=13 WriteString (each char via
      `teletype`, **`useattr=true` always** F5, restore cursor when AL bit0=0). Test: set mode 3 clears
      the page to 0x0720; write-string places a row and bit0=0 leaves the cursor put.
- [x] **P6 — `/api/screen` read.** Add `Controller.screen` (pure peek of the **BDA active page** at the
      BDA-implied base, cols/rows from BDA, §4.2.1), `screen_get` **`void`** Command + `ScreenResult`
      POD with a `[MAX_SCREEN_CELLS=4000]u8` cells buffer (`queue.zig`), `screenResp` filling the full
      cells (`worker.zig`), JSON serialization (`json_wire.zig`, §4.1 shape) with `attrs` driven by a
      **server-side `?attrs=1` query parse** (D-TM4 / Finding 5), and the `/api/screen` route
      (`server.zig` after `:278`). Test: write cells, `GET /api/screen`, assert the grid string + cursor;
      assert the read is **side-effect-free** — snapshot before == after (mirror
      `controller_test.zig:321-329`).
- [x] **P7 — KEYECHO real-`putch` acceptance gate.** Revert `examples/dos-src/KEYECHO.C:42-56` to real
      `putch()`, recompile (`tools/bcc.sh`), update `tests/blackbox/keyecho_test.zig` to assert the
      echo via `/api/screen` (§5.1). Confirm ESC still terminates (ret 0). **This green is the gate.**
- [x] **P8 — Determinism + grep-gate + VIDTEXT.** Two-run byte-identity of `text_vram`/`text_vram_mono`
      + `/api/screen` via the caller-copy path (§5.3). **Confirm the existing BIOS / devices / api / debug
      grep gates still pass** with the new code (`int10.zig` is ALREADY in the BIOS gate
      `determinism_test.zig:22`; `vga.zig` in the devices gate `pit_test.zig:61`; controller/api modules
      gated) — **do NOT add `int10.zig` to the devices gate** (§5.5). Update `examples/dos-src/VIDTEXT.C`
      to assert teletype now that it is modeled (§5.2), removing the "deferred text-subsystem" boundary
      note.
- [x] **P9 — Docs + (optional) text oracle band.** Flip the ROADMAP backlog item
      (`plans/ROADMAP.md:25`) to done; update the `KEYECHO.C` header note (no longer "unobservable").
      Add the text-buffer-content oracle band note to `plans/io-oracle.md` §1 (§5.4 — text cells ARE a
      valid cross-emulator golden, unlike retrace bits). The oracle program itself can be a follow-up.

---

## 7. Risks / open questions for the human

1. **Q1 — v1 INT 10h scope (RESOLVED — AH=08/AH=01 are IN).** v1: AH=00 (text modes 0–3/7), 01 (set
   cursor shape → BDA), 02 (done), **03 fixed to read BDA shape** (was hardcoded `0x0607`), 06/07
   scroll, **08 read char+attr** (a one-liner on `readCharCell`, already needed for the F4 scroll
   fill-attr), 09/0A write-char, 0E teletype, 0F (done), 13 write-string. Deferred: pages 1–7 (D-TM2),
   graphics-mode text output, AH=11 font RAM (D-TM1/§3.2). **AH=08 and AH=01 are now in v1** (both are
   nearly free; AH=01/03 also fixes a latent set-then-get-cursor-shape inconsistency the text work
   touches). Confirm the v1 set is otherwise complete.

2. **Q2 — `/api/screen` format + attributes.** Proposed: default = `text` grid (25 `\n`-joined
   80-char rows, raw bytes incl. CP437 high bytes) + cursor + mode; attributes opt-in via `?attrs=1`
   returning a parallel 2000-byte attr array (D-TM4). **Confirm: (a) raw bytes vs a printable
   substitution for control/high bytes; (b) attrs as a separate array vs interleaved cells vs a
   second grid; (c) is `?attrs=1` the right opt-in shape?**

3. **Q3 — Mono text (mode 7 / B0000) in v1?** Proposed: map a B0000 slab so mode-7 writes aren't lost,
   but default the tests/`/api/screen` to color B8000 (D-TM3). **Alternative:** defer mono entirely
   and assert-flag a mode-7 set-mode (CLAUDE assert-don't-fake). **Pick one.**

4. **Q4 — Both A0000 and B8000 permanently mapped (no per-mode remap).** Proposed: leave both windows
   mapped at all times (real hardware scans one; the BDA mode says which is "active") rather than
   dosbox's per-mode `MEM_SetPageHandler` remap (`vga_memory.cpp:1057-1106`). Simpler, deterministic,
   faithful for the guest-observable layout. **Risk:** a guest that probes "is B8000 RAM?" to detect a
   graphics mode would see it always-RAM — but real text/graphics coexistence means both windows ARE
   addressable; this matches hardware. **Confirm acceptable** (it is, for the BaK + utility-UI scope).

5. **Q5 — Plane/font machinery (D-TM1) and CON–screen mirroring (D-TM5 — LOCKED).** v1 models the flat
   char/attr slab (no `seq.map_mask` plane split, no font upload) and keeps `/api/console` and
   `/api/screen` as **separate surfaces (decided: no mirroring in v1; CON→text-page mirror is a
   documented follow-up, §4.3)**. **Confirm** no v1 target needs plane-2 font upload (flag if BaK's
   intro/credits use a custom font via AH=11 — a recon gap, like the BaK-recon gap already noted in
   `plans/io-oracle.md:394-398`).

6. **Q6 — BEL deterministic no-op (D-TM-BEL).** v1 teletype of chr 7 does nothing (follows spice86),
   rather than dosbox's host-timed 333 ms beep busy-wait (which violates determinism). **Confirm** a
   silent BEL is acceptable for v1 (a faithful cycle-derived PIT-ch2 beep is a flagged later item).
