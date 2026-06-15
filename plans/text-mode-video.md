# Text-mode video (B8000/B0000) + INT 10h text services + `/api/screen` observability

Status: **design plan** (implementation-ready; no source changed by this document). Fills the
ROADMAP backlog item "VGA text-mode video (B8000) + console mirror" (`plans/ROADMAP.md:25`).

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
| VRAM snapshot | VGA `Snapshot` is DAC+regs only; **VRAM bytes copied separately** (large slab), like the bus RAM slab | `src/machine/machine.zig:515-518`; `src/devices/vga.zig:433-468` |
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
(`ReadCharAttr`, `:431-444`: `mem_readw(where)`).

**Teletype (AH=0E), the load-bearing semantics** (`int10_char.cpp:743-810`, `teletype_output_attr`):
- `chr == 7` (BEL): **busy-waits on `PIC_FullIndex()` for 333 ms** to beep (`:749-766`) —
  **HOST-TIMING-DEPENDENT, MUST NOT COPY** (see §3 determinism lens).
- `chr == 8` (BS): `if (cur_col>0) cur_col--`.
- `chr == '\r'`: `cur_col = 0`.
- `chr == '\n'`: `cur_row++` (note: dosbox does NOT reset col on LF — `:475` "Seems to break an old
  chess game"; we copy this faithfully).
- default: `WriteChar(cur_col,cur_row,page,chr,attr,useattr)`; `cur_col++`.
- wrap: `if (cur_col==ncols) { cur_col=0; cur_row++; }`.
- scroll: `if (cur_row==nrows) { fill = attr-at-cursor (text); INT10_ScrollWindow(0,0,nrows-1,ncols-1,-1,fill,page); cur_row--; }`.
- finally `INT10_SetCursorPos(cur_row,cur_col,page)`.

**Scroll (AH=06/07 → `INT10_ScrollWindow`)** (`int10_char.cpp:193-294`): clamps the window to
`nrows-1`/`ncols-1`; computes `base = pstart + page*page_size`; copies rows (`TEXT_CopyRow`) by
`nlines` then fills exposed rows with `(attr<<8|' ')` (`TEXT_FillRow`). `nlines==0` ⇒ clear the whole
window. AH=06 passes `-reg_al` (scroll up), AH=07 passes `+reg_al` (down); `reg_al==0` ⇒ clear
(`references/dosbox-staging/src/ints/int10.cpp:96-100`).

**Write char/attr (AH=09/0A → `INT10_WriteChar`)** (`int10.cpp:105-112`): AH=09 uses BL as the
attribute (`useattr=true`), AH=0A ignores attr; both write CX copies at the **current cursor** without
advancing it.

**INT 10h dispatch** (`references/dosbox-staging/src/ints/int10.cpp:47-135`): AH=00 SetVideoMode,
02 SetCursorPos, 03 get cursor+shape, 06/07 ScrollWindow, 09/0A WriteChar, 0E TeletypeOutput,
0F get videomode, 13 WriteString.

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

**Backing store.** Allocate a text-page slab in the VGA device exactly like `vram`
(`src/devices/vga.zig:122,171-175`): `text_vram: []u8 = &.{}` of `TEXT_WINDOW_LEN` bytes (or the full
0x8000 covering both color and mono if a single base is reused; **recommend separate slabs is
unnecessary** — one 0x8000 slab per base is the faithful window size, but for v1 a single 32 KiB
color slab at B8000 covers mode 3; mono B0000 is a separate small slab, see D-TM3). Zero-filled at
reset (CLAUDE #5).

**Bus mapping.** Add a `textMemHandler()` (a second `MemHandler`, ctx=self) with `read8/write8/
getHostPtr/peek8` indexing `text_vram` by `phys - TEXT_COLOR_PHYS` — structurally identical to the
A0000 handler (`src/devices/vga.zig:220-259`). In `machine.wire()` after the A0000 mapping
(`src/machine/machine.zig:233`):

```zig
_ = self.bus.mapMmio(devices.vga.TEXT_COLOR_PHYS, devices.vga.TEXT_WINDOW_LEN, self.vga.textMemHandler());
```

Direct guest writes (Borland `putch` direct-video) now land in `text_vram` and read back. The
`getHostPtr` fast path means a `mov [es:di],al` to B800 is charged as a **normal guest memory write**
(no trap, no ledger hole — CLAUDE #1), exactly as the A0000 path is (`src/devices/vga.zig:36-41`).

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

**Determinism / snapshot.** `text_vram` is guest memory → it must be snapshot-covered. It is **MMIO,
not in the bus RAM slab** (the UMA window is `.unmapped` by default, claimed by `mapMmio`), so —
exactly like `vram` — the machine copies `text_vram` bytes separately on snapshot/restore
(`src/machine/machine.zig:515-518` documents this pattern for `vram`; add `text_vram` the same way).
Add `text_vram` zeroing to `Vga.reset` (`src/devices/vga.zig:184-195`). Add the region to the
debugger `regions_table` (`src/debug/controller.zig:702-706`):
`.{ .kind = .text_vram, .phys_start = 0xB8000, .len = 0x8000 }` (extend the `kind` enum at `:130`).

### 3.2 INT 10h text services — v1 scope, deferrals honest

Add to `src/bios/int10.zig` the dispatch + handlers. **Each is a host-serviced trap charging the
bridge's deterministic synthetic cost** (the same path AH=00/02/03/0F already use — no ledger hole,
CLAUDE #1). Reads/writes go through the bus to `text_vram` + the BDA. The active page is **page 0
only** for v1 (D-TM2). All semantics mirror `int10_char.cpp` (cited inline).

**v1 services:**

| AH | Service | Semantics (mirror dosbox) | cite |
| --- | --- | --- | --- |
| 00 | Set mode | text modes 0–3 (color, B8000) + 7 (mono, B0000): set BDA mode/cols/page-size/rows/CRTC-base; clear the text page if `!no-clear` (fill with `0x0720` = space, gray-on-black); reset cursor pos pages 0–7 + active page | `int10_modes.cpp:30-37`, FinishSetMode |
| 02 | Set cursor pos | **already implemented** (BDA `OFF_CURSOR_POS+page*2 = DX`) | `src/bios/int10.zig:40-44`; `int10_char.cpp:384-406` |
| 03 | Get cursor pos+shape | **already implemented** (DX from BDA, CX shape) | `src/bios/int10.zig:45-50` |
| 06 | Scroll window up | `INT10_ScrollWindow(CH,CL,DH,DL,-AL,BH,0xFF)`; AL=0 ⇒ clear window | `int10.cpp:96-97`; `int10_char.cpp:193-294` |
| 07 | Scroll window down | `INT10_ScrollWindow(CH,CL,DH,DL,+AL,BH,0xFF)` | `int10.cpp:99-100` |
| 09 | Write char+attr at cursor ×CX | `WriteChar(col,row,page,AL,BL,useattr=true)` ×CX; cursor NOT advanced | `int10.cpp:105-108` |
| 0A | Write char at cursor ×CX | `WriteChar(...,useattr=false)` ×CX | `int10.cpp:110-111` |
| 0E | Teletype output AL | the full control-char + wrap + scroll path (BS/CR/LF/default+advance), attr BL in graphics only; advances + writes BDA cursor; **BEL = deterministic no-op** | `int10_char.cpp:743-810` |
| 0F | Get mode | **already implemented** | `src/bios/int10.zig:57-61` |
| 13 | Write string | `INT10_WriteString(DH,DL,AL,BL,ES:BP,CX,BH)` — AL bit0=advance cursor, bit1=cells carry attr; loops chars handling CR/LF/BS/BEL like teletype | `int10.cpp:594-595`; `int10_char.cpp` WriteString |

**Shared helpers to add (mirroring dosbox's externally-callable functions):**
- `writeCharCell(cpu, page, row, col, chr, attr, useattr)` — the §2.2 cell write to
  `pstart + page*PAGE_SIZE + (row*cols+col)*2` via `cpu.bus.writePhys8/16`. `pstart` = B8000 for a
  color text mode, B0000 for mode 7 (from the BDA `OFF_CRTC_ADDRESS` or mode number).
- `readCharCell(...)` — symmetric read (for the scroll fill-attr and AH=08).
- `scrollWindow(cpu, rul,cul,rlr,clr, nlines, attr, page)` — the copy-rows-then-fill logic
  (`int10_char.cpp:193-294`), text-mode only for v1.
- `teletype(cpu, chr, attr, useattr)` — the §2.2 control-char machine, reading/writing the BDA
  cursor (`OFF_CURSOR_POS`), cols (`OFF_VIDEO_COLS`), rows (`OFF_NB_ROWS`+1), calling `writeCharCell`
  + `scrollWindow`. Replaces the AH=0E no-op at `src/bios/int10.zig:53-56`.

> **Decision D-TM-BEL: BEL (chr 7) is a deterministic no-op, NOT dosbox's busy-wait.** dosbox beeps
> by programming PIT ch2 + busy-waiting on `PIC_FullIndex()` for 333 ms
> (`int10_char.cpp:749-766`) — a host-wall-clock dependence that violates CLAUDE #2/#3. spice86 makes
> it a no-op (`VgaFunctionality.cs:601-603` `//FIXME should beep`). zdos follows spice86: teletype of
> BEL leaves the cursor unchanged and does nothing else. (A future faithful beep would program PIT
> ch2 — which zdos already models, `src/devices/pit.zig` — and let cycle-derived emulated time gate
> the duration; out of v1 scope, flag.)

**Deferred (flagged, not faked):**

> **Decision D-TM2: display pages 1–7 deferred — v1 is page 0 only.** The BDA already stores 8 cursor
> positions and an active-page byte (`bda.zig:25,27`), and `setModeVga13` already resets all 8
> (`int10.zig:121-125`), so the *state* is present and snapshot-covered. But v1 INT 10h services
> operate on page 0 (BH ignored beyond 0), and `/api/screen` renders page 0. Multi-page (AH=05 set
> active page + the page-start-address CRTC scroll) is deferred until a guest needs it (BaK is
> graphics; the utility-UI class generally uses page 0). The cell-address helper already takes a
> `page` param so adding page 1–7 later is a parameter change, not a rewrite.

> **Decision D-TM3: mono text (mode 7 / B0000) — minimal backing, v1 focus is color.** Map a B0000
> slab too (real machines have both) so a mode-7 program's writes are not lost, but the v1 test
> corpus + `/api/screen` default to the **color** page (B8000) since `initDefaults` boots mode 3 and
> BaK/Borland conio are color. If the human prefers to defer mono entirely, drop the B0000 mapping
> and assert-flag a mode-7 set-mode (CLAUDE assert-don't-fake) — see §7 Q3.

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

- `text_vram` is guest memory: deterministic (zero-init at reset), snapshot-covered (copied
  separately like `vram`).
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

Render **page 0** of the color text page (B8000) as the 80×25 character grid. The wire shape:

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
- `cursor`: from BDA `OFF_CURSOR_POS` (page 0).
- `attrs`: **optional, omitted (null) by default** (D-TM4). A `?attrs=1` query param returns a
  parallel 2000-byte attribute array (byte1 of each cell) hex-encoded or as a second grid — see Q2.

> **Decision D-TM4: plain-text rows by default; attributes opt-in.** The KEYECHO gate and the bulk of
> black-box assertions care about *which characters appear where*, not colors. Default to the
> character grid (small, human-readable, trivially assertable); expose attributes behind `?attrs=1`
> for tests that assert color (e.g. a TUI highlight). Keeps the common response small and the
> assertion path clean.

### 4.2 Plumbing (mirror `/api/console`)

The screen read is **a pure observation** like `console_get`, so it reuses that exact flow:

1. **Controller** (`src/debug/controller.zig`): add `pub fn screen(self, dst) ScreenView` that
   `peekMemPhys(0xB8000 + page0_off, dst[0..cols*rows*2])` (pure peek) and reads the BDA
   mode/cols/rows/cursor via `peekMemPhys(BDA_PHYS+off,...)`. Returns the raw cell bytes + the BDA
   scalars; the worker/JSON layer formats the grid. Mirrors `console()` at `:641-650`.
2. **Queue** (`src/api/queue.zig`): add `screen_get: void` to `Command` (`:108` alongside
   `console_get`); add a `ScreenResult` POD (cols/rows/mode/cursor + a `[80*25*2]u8 cells` fixed
   array + len) and a `screen:` arm to `Response` (`:210`). Note `MAX_CONSOLE=4096`
   (`:181`) is enough for 80×25 chars (2000) but the cells buffer needs 4000 bytes → add a
   `MAX_SCREEN_CELLS = 80*25*2 = 4000` constant; the result is pointer-free fixed array (the
   project's POD discipline, `:142-184`).
3. **Worker** (`src/api/worker.zig`): add a `screenResp(ctrl)` (mirror `consoleResp` at `:267-274`)
   that fills `ScreenResult` from `ctrl.screen(...)`; dispatch `.screen_get => screenResp(ctrl)`
   (`:120` alongside `console_get`).
4. **JSON wire** (`src/api/json_wire.zig`): serialize `ScreenResult` → the §4.1 shape (decode cells
   into the `text` string rows; include `attrs` only when requested).
5. **Server** (`src/api/server.zig`): add the route after `/api/console` (`:273-278`):
   ```zig
   if (std.mem.eql(u8, path, "/api/screen")) {
       if (method != .GET) return self.methodNotAllowed(req);
       return self.submitAndRespond(req, .screen_get); // (attrs flag parsed from query)
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

**Keep both surfaces.** They answer different questions and both are needed.

> **Decision D-TM5: do NOT mirror INT 10h teletype into the CON capture (and vice-versa).** It is
> tempting to also push teletype/`putch` output into `/api/console` so existing CON-based tests catch
> it. Reject: that conflates two distinct architectural surfaces and would make `/api/console` lie
> about what the DOS CON device received. The faithful design is two independent reads. (If a future
> convenience "combined view" is wanted, add it as a third, clearly-labeled endpoint — never silently
> merge.)

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
by construction. Add `text_vram` to whatever full-snapshot determinism test asserts VRAM
byte-identity (it must round-trip through snapshot/restore like `vram`).

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

`src/devices/vga.zig` is already in the float/host-clock grep gate (added by the retrace work,
`plans/vga-retrace.md:608-609` P5; `src/devices/pit_test.zig:53-58`). The text-page code is pure
integer/byte work, but **confirm the gate still passes** after the edits (no `std.time`/float/RNG
creeps into the cell/teletype helpers). `src/bios/int10.zig` should be **added to the gate's
`sources` array** too (the teletype/scroll code is determinism-critical and currently ungated) — flag
this as a P-step.

---

## 6. Phased checklist

Each box ≈ one focused commit; `zig build test` (+ `test-blackbox`, `test-oracle`) stay green
throughout. Ordered so each phase is independently testable.

- [ ] **P1 — Text-page backing region.** Add the §3.1 geometry/cell constants + a `text_vram` slab
      (alloc in `Vga.init`, free in `deinit`, zero in `reset`) + a `textMemHandler()` (`read8/write8/
      getHostPtr/peek8` indexing `text_vram`) to `src/devices/vga.zig` (mirror `:122,171-259`). Map it
      in `machine.wire()` after `src/machine/machine.zig:233`:
      `mapMmio(TEXT_COLOR_PHYS, TEXT_WINDOW_LEN, self.vga.textMemHandler())`. Unit-test: a direct bus
      write to B800:0000 reads back (it was dropped before). No INT 10h change yet.
- [ ] **P2 — Snapshot coverage for `text_vram`.** Copy `text_vram` bytes separately on snapshot/
      restore alongside `vram` (`src/machine/machine.zig:515-518` pattern). Add `.text_vram` to the
      debugger `regions_table` (`src/debug/controller.zig:130,702-706`). Test: write B800, snapshot,
      mutate, restore, assert bytes round-trip byte-identical (mirror `controller_test.zig:304,329`).
- [ ] **P3 — INT 10h cell helpers + AH=09/0A write-char.** Add `writeCharCell`/`readCharCell` (§3.2)
      and the AH=09 (attr) / AH=0A (no-attr) dispatch arms to `src/bios/int10.zig` (replace the `else`
      fallthrough at `:63` for these AHs). Unit/black-box test: AH=09 writes a char+attr at the cursor,
      read back via B800 + via AH=08.
- [ ] **P4 — INT 10h AH=0E teletype + AH=06/07 scroll.** Add `scrollWindow` (§3.2,
      `int10_char.cpp:193-294`) and the full `teletype` control-char machine (BS/CR/LF/wrap/scroll,
      **BEL no-op**, D-TM-BEL) replacing the AH=0E no-op at `src/bios/int10.zig:53-56`. Wire AH=06/07.
      Test: teletype a string → cells land + cursor advances + wraps + scrolls (§5.2).
- [ ] **P5 — INT 10h AH=00 text mode-set + AH=13 write-string.** Extend `setMode` to handle text
      modes 0–3 (B8000) / 7 (B0000): program BDA + clear page (fill `0x0720`) per FinishSetMode
      (`int10_modes.cpp:30-37`). Add AH=13 WriteString. Test: set mode 3 clears the page; write-string
      places a row.
- [ ] **P6 — `/api/screen` read.** Add `Controller.screen` (pure peek, §4.2.1), `screen_get` Command +
      `ScreenResult` POD (`queue.zig`), `screenResp` (`worker.zig`), JSON serialization (`json_wire.zig`,
      §4.1 shape, `attrs` opt-in D-TM4), and the `/api/screen` route (`server.zig` after `:278`).
      Test: write cells, `GET /api/screen`, assert the grid string + cursor; assert the read is
      side-effect-free (snapshot unchanged before/after).
- [ ] **P7 — KEYECHO real-`putch` acceptance gate.** Revert `examples/dos-src/KEYECHO.C:42-56` to real
      `putch()`, recompile (`tools/bcc.sh`), update `tests/blackbox/keyecho_test.zig` to assert the
      echo via `/api/screen` (§5.1). Confirm ESC still terminates (ret 0). **This green is the gate.**
- [ ] **P8 — Determinism + grep-gate + VIDTEXT.** Two-run byte-identity of `text_vram` + `/api/screen`
      (§5.3). Add `src/bios/int10.zig` to the float/host-clock grep gate (`pit_test.zig:53-58`, §5.5)
      and confirm `vga.zig` still passes. Update `examples/dos-src/VIDTEXT.C` to assert teletype now
      that it is modeled (§5.2), removing the "deferred text-subsystem" boundary note.
- [ ] **P9 — Docs + (optional) text oracle band.** Flip the ROADMAP backlog item
      (`plans/ROADMAP.md:25`) to done; update the `KEYECHO.C` header note (no longer "unobservable").
      Add the text-buffer-content oracle band note to `plans/io-oracle.md` §1 (§5.4 — text cells ARE a
      valid cross-emulator golden, unlike retrace bits). The oracle program itself can be a follow-up.

---

## 7. Risks / open questions for the human

1. **Q1 — v1 INT 10h scope.** Proposed v1: AH=00 (text modes 0–3/7), 02/03 (done), 06/07 scroll,
   09/0A write-char, 0E teletype, 0F (done), 13 write-string. Deferred: pages 1–7 (D-TM2),
   graphics-mode text output, AH=11 font RAM (D-TM1/§3.2), AH=08 read-char (cheap — include it?),
   AH=01 set cursor shape (cosmetic — include as a BDA write?). **Confirm the v1 set; is AH=08/AH=01
   in or out?**

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

5. **Q5 — Plane/font machinery (D-TM1) and CON–screen mirroring (D-TM5).** v1 models the flat
   char/attr slab (no `seq.map_mask` plane split, no font upload) and keeps `/api/console` and
   `/api/screen` as separate surfaces (no mirroring). **Confirm** no v1 target needs plane-2 font
   upload or a merged CON+screen view (flag if BaK's intro/credits use a custom font via AH=11 — a
   recon gap, like the BaK-recon gap already noted in `plans/io-oracle.md:394-398`).

6. **Q6 — BEL deterministic no-op (D-TM-BEL).** v1 teletype of chr 7 does nothing (follows spice86),
   rather than dosbox's host-timed 333 ms beep busy-wait (which violates determinism). **Confirm** a
   silent BEL is acceptable for v1 (a faithful cycle-derived PIT-ch2 beep is a flagged later item).
