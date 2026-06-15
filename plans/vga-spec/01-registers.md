# VGA register files — complete hardware-compliant specification

Status: **design spec** (no source changed by this document). This is the register-storage/protocol
reference for the full VGA implementation zdos is building (the Mode-Y/planar subsystem of
`plans/lamut-milestone.md` + `plans/mode-y-vga.md`, and the retrace work already landed in
`plans/vga-retrace.md`). It specifies **every register, every meaningful bit, the read/write
protocol, read-back behaviour, and reset/power-on value** for all six VGA register groups, with the
dosbox-staging vs spice86 comparison (file:line) and a recommended Zig representation.

> **Scope of THIS document (storage + protocol only).** This spec owns *how each register is
> stored, indexed, written, and read back*. It does **not** specify the downstream *effect* of a bit
> on the memory engine or scanout — those belong to `plans/mode-y-vga.md` (planar VRAM engine) and a
> later scanout/capture spec. Where a bit drives behaviour elsewhere, this document names it and
> points to the consuming spec, then stops at the storage boundary. The CLAUDE prime directive is
> satisfied trivially: **every register here is pure guest state** — written by guest `OUT`, read by
> guest `IN`, with no host clock, no float, no RNG; it is deterministic and snapshot-covered by
> construction. (The one cycle-derived value, Input Status #1, is specified in `plans/vga-retrace.md`
> and only cross-referenced here.)

---

## 0. The six groups + total register count

A standard IBM VGA exposes **six register groups**, addressed two ways: a handful of **directly
mapped** I/O ports (External/General + DAC), and four **indexed** files (an address/index port
latches an index, a data port reads/writes `regs[index]`). Total programmable registers:

| # | Group | Index port | Data port | Count | zdos today |
| - | --- | --- | --- | --- | --- |
| 1 | External / General | — (direct ports) | — | 4 (+2 status reads) | misc-output + 0x3DA status only |
| 2 | Sequencer (SEQ) | 0x3C4 | 0x3C5 | 5 (idx 0x00–0x04) | **none** (silent-drop) |
| 3 | CRT Controller (CRTC) | 0x3D4 / 0x3B4 | 0x3D5 / 0x3B5 | 25 (idx 0x00–0x18) | **none** (BDA stores 0x3D4 only) |
| 4 | Graphics Controller (GC) | 0x3CE | 0x3CF | 9 (idx 0x00–0x08) | **none** (silent-drop) |
| 5 | Attribute Controller (AC) | 0x3C0 (flip-flop) | 0x3C1 read | 21 (idx 0x00–0x14) | **none** (`assert(false)`) |
| 6 | DAC (RAMDAC palette) | 0x3C8 wr / 0x3C7 rd | 0x3C9 | 256×3 + pel-mask + state | **fully modeled** |

**Programmable indexed register total: 5 + 25 + 9 + 21 = 60 indexed registers**, plus the 4
External/General registers, plus the DAC's 256×3-byte palette RAM and its 4 control/state ports.
zdos models the DAC group and 2 of the External group fully today; **the other ~60 indexed registers
are absent** (silently dropped, returning 0xFF, or asserting false). This document specifies all of
them so the LAMUT/Mode-Y work can replace the gaps with real, read-back-able storage.

### Two access protocols (specified precisely, because guests depend on them)

- **Indexed (SEQ, CRTC, GC):** write the **index port** to latch `index`; subsequent reads/writes of
  the **data port** hit `regs[index]`. The index persists until rewritten. A **16-bit `OUT` to the
  index port** is the index+data-in-one-word idiom (`AL`=index, `AH`=data) — both refs implement it
  as "WriteByte(port, lo) then WriteByte(port+1, hi)" (spice86 `VgaIoPortHandler.cs:361-364`). Data
  ports are **fully read-back-able** on VGA (the engine's `f_1ca27.asm` does `OUT index; IN data`).
- **Attribute Controller (one port + flip-flop):** 0x3C0 is BOTH the index and the data port; an
  internal **address/data flip-flop** decides which. Writing 0x3C0 in the *address* phase latches the
  index (and the PAS bit); the *next* 0x3C0 write is the data for that index; each write toggles the
  flip-flop. **Reading Input Status #1 (0x3DA/0x3BA) resets the flip-flop to the address phase.** AC
  reads come from 0x3C1 (VGA only). See §6.
- **DAC (sub-state-machine):** 0x3C8 (write) / 0x3C7 (read) latch a palette index; 0x3C9 reads/writes
  a 3-byte R-G-B triplet then auto-increments the index. See §7.

---

## 1. External / General registers

Four directly-mapped registers (no index). dosbox: `vga_misc.cpp`; spice86:
`Registers/General/*.cs` + `Ports.cs`.

### 1.1 Miscellaneous Output (write 0x3C2 / read 0x3CC) — power-on `0x00`

Single byte. dosbox `write_p3c2` (`vga_misc.cpp:46-95`), `read_p3cc` (`:97-100`); spice86
`MiscellaneousOutput.cs`.

| Bit | Name | Semantics |
| - | --- | --- |
| 0 | **I/O Address Select** | 1 → CRTC at **0x3D4/0x3D5** and status#1 at **0x3DA** (colour); 0 → **0x3B4/0x3B5** + **0x3BA** (mono). *This is the CRTC-port-relocation bit.* |
| 1 | RAM Enable | 1 → enable CPU access to display buffer (A000) |
| 2-3 | Clock Select | 0 = 25.175 MHz (mode 13h/text), 1 = 28.322 MHz, 2 = external, 3 = reserved |
| 5 | Odd/Even Page Select | high 64K bank select in odd/even modes |
| 6 | Horizontal Sync Polarity | (with bit 7) encodes vertical size: 1→400, 2→350, 3→480 lines |
| 7 | Vertical Sync Polarity | (see bit 6) |

- **Read-back:** the same byte at **0x3CC** (dosbox `read_p3cc` returns `vga.misc_output`).
- **Reset:** `0x00` (hardware reset, per dosbox comment `vga_misc.cpp:65-66`). zdos already power-ons
  `misc_output = 0` (`vga.zig:189,242`).
- **Behaviour driven elsewhere:** bit 0 selects which port set the CRTC + status#1 answer on
  (the scanout/wiring spec). dosbox re-registers handlers on a 0x3C2 write (`vga_misc.cpp:73-94`).
  zdos's VGA-only mode-13h target is **always colour**, so zdos registers both 0x3D4/0x3B4 (and
  0x3DA/0x3BA) to the same handler and stores the bit faithfully (no re-routing needed for v1; see
  `plans/vga-retrace.md:451-455`). **Store the bit; document that re-routing is deferred.**

### 1.2 Input Status #0 (read 0x3C2) — no stored state

dosbox `read_p3c2` (`vga_misc.cpp:113-143`); spice86 `InputStatusRegister0.cs`.

| Bit | Name | VGA value |
| - | --- | --- |
| 4 | Switch Sense (SS) | reads the DAC/monitor sense line selected by misc-output CS; **dosbox sets bit 4 (0x10) on VGA** |
| 5-6 | Feature Status (EGA only) | 0 on VGA |
| 7 | Vertical Retrace Interrupt | 1 if a vertical-retrace IRQ is pending |
| 0-3 | reserved | 0xF on EGA, **0x0 on VGA** |

- dosbox returns `0x60` base on VGA, then `| 0x10` for switch-sense, then `| 0x80` if a vret IRQ is
  pending (`vga_misc.cpp:119-130`). zdos models **no** vertical-retrace IRQ (it polls — see
  `plans/vga-retrace.md:656-662`), so bit 7 is always 0.
- **zdos recommendation:** answer 0x3C2 reads with a deterministic constant `0x10` (switch-sense
  high, VGA), bits 7/5/6/0-3 = 0. No stored state. This is *not* a golden value (no oracle) but is a
  faithful constant. (Today 0x3C2 read is unmapped → 0xFF, which is wrong; add the constant.)

### 1.3 Input Status #1 (read 0x3DA colour / 0x3BA mono) — **already modeled**, cross-ref

Specified fully in `plans/vga-retrace.md` and implemented at `vga.zig:476-498`. The bits (bit 0 =
display-enable complement, bit 2 = 1, bit 3 = vertical retrace; 1/4-7 = 0) are a **cycle-derived pure
function** of `cpu.st.cycles` — see that doc. **The one register-protocol fact this group owns:** a
read of 0x3DA/0x3BA **resets the Attribute Controller flip-flop to the address phase**
(`vga.zig:479`, dosbox `vga_misc.cpp:24`, spice86 `VgaIoPortHandler.cs:162`). When the AC state
machine lands (§6), this read must set `attr.flip_is_index = true`. No new storage here.

### 1.4 Feature Control (write 0x3DA colour / 0x3BA mono; read 0x3CA) — power-on `0x00`

dosbox `read_p3ca` returns **0** unconditionally (`vga_misc.cpp:103-106`); spice86 maps
`FeatureControlRead = 0x3CA` and `FeatureControlWrite = 0x3BA` / `FeatureControlWriteAlt = 0x3DA`
(`Ports.cs:244,80,258`) but does not act on it. The register held two feature-connector control bits
(0-1) on EGA; **on VGA it is effectively inert**.

- **zdos recommendation:** store a `feature_control: u8 = 0` byte so a write/read round-trips
  (faithful), but it drives nothing. Read at 0x3CA returns the stored byte (dosbox returns a hard 0;
  storing-and-returning is a strict superset and round-trips a guest probe). **Low priority** — no
  surveyed BaK/LAMUT path touches it; a minimal faithful choice is "read 0x3CA → 0, write ignored,"
  but storing the byte costs 1 snapshot byte and is more honest. Pick storing-the-byte.

> **Note — write port collision.** 0x3DA is *read* = Input Status #1 and *write* = Feature Control;
> 0x3BA mirrors it in mono. zdos's `portOut8` currently drops writes to 0x3DA/0x3BA (the `else => {}`
> arm) — faithful enough for v1 (Feature Control is inert), but when §1.4 storage is added, route the
> 0x3DA/0x3BA **write** to `feature_control`.

---

## 2. Sequencer (SEQ) — index 0x3C4 / data 0x3C5

5 registers (idx 0x00–0x04). dosbox `vga_seq.cpp`; spice86 `SequencerRegisters.cs` + `Sequencer/*.cs`.
Index masked to **bits 2-0** (spice86 `SequencerRegisters.cs:17`; idx 0–4 only).

| Idx | Name | Bit layout / semantics | Reset |
| - | --- | --- | --- |
| 0x00 | **Reset** | bit0 = Asynchronous Reset (0=reset), bit1 = Synchronous Reset (0=reset). Both must be 1 to run. | `0x03` (typical; held value, no effect on emu) |
| 0x01 | **Clocking Mode** | bit0 = 8/9-dot char width (1=8), bit2 = dot-clock/2 load, bit3 = dot-clock divide-by-2 (pixel doubling), bit4 = shift-4 load, bit5 = **screen-off** (gives all mem cycles to CPU) | `0x00` |
| 0x02 | **Map Mask** | bits3-0 = **per-plane write enable** (bit p enables writes to plane p). *The Mode-X plane gate.* | `0x0F` (all planes) |
| 0x03 | **Character Map Select** | bits 0-1,4 = font map A; bits 2-3,5 = font map B (text-mode glyph banks) | `0x00` |
| 0x04 | **Memory Mode** | bit1 = Extended Memory (>64K), bit2 = **Odd/Even disable** (1=disable odd/even), bit3 = **Chain-4** (1=256-color chained linear, 0=unchained planar) | `0x06` (ext-mem + chained-ish power-on) |

- **Write protocol:** `out8(0x3C4, idx)` latches; `out8(0x3C5, v)` writes `seq.regs[idx]=v`. dosbox
  `write_p3c4`/`write_p3c5` (`vga_seq.cpp:17-123`). 16-bit `out16(0x3C4, 0x0F02)` = idx 0x02, data
  0x0F (the `f_204ce.asm:65` Map-Mask idiom) → split to two byte writes.
- **Read-back:** `read_p3c4` returns `index`; `read_p3c5` returns the stored reg (dosbox
  `vga_seq.cpp:12-15,125-140`; idx 0-4 each return their stored value).
- **Bits driving behaviour elsewhere (named, not specified here):**
  - **Map Mask (idx 2, bits3-0)** → the planar-write plane gate (`plans/mode-y-vga.md` §4.3,
    accessor `mapMask()`).
  - **Chain-4 (idx 4, bit3)** → chained vs unchained dispatch (`plans/mode-y-vga.md` §4.1, accessor
    `chained()` = `(seq.regs[4] & 0x08) != 0`). dosbox swaps the memory handler on this bit
    (`vga_seq.cpp:107-112`); zdos decides per-access in `getHostPtr` instead.
  - Odd/Even (idx 4 bit2), screen-off (idx 1 bit5): named, deferred-with-flag if a guest drives them.

---

## 3. CRT Controller (CRTC) — index 0x3D4/0x3B4 / data 0x3D5/0x3B5

25 registers (idx 0x00–0x18). dosbox `vga_crtc.cpp`; spice86 `CrtControllerRegisters.cs` +
`CrtController/*.cs` + `Enums/CrtControllerRegister.cs`. **Port base selected by misc-output bit 0**
(§1.1): 0x3D4/0x3D5 colour, 0x3B4/0x3B5 mono.

| Idx | Name | Bit layout / semantics (8-bit unless noted) | Reset (mode 13h-ish) |
| - | --- | --- | --- |
| 0x00 | Horizontal Total | char-clocks − 5 | per-mode |
| 0x01 | Horizontal Display End | displayed char-clocks − 1 | per-mode |
| 0x02 | Start Horizontal Blanking | char count where hblank starts | per-mode |
| 0x03 | End Horizontal Blanking | bits4-0 = hblank-end (low 6 of counter), bits6-5 = display-enable skew, **bit7 = 1 (must-be-set / "access vert-retrace regs")** | per-mode |
| 0x04 | Start Horizontal Retrace | char count where hretrace starts | per-mode |
| 0x05 | End Horizontal Retrace | bits4-0 = hretrace-end, bits6-5 = retrace skew, **bit7 = bit5 of End-Horiz-Blanking** | per-mode |
| 0x06 | Vertical Total | low 8 of vtotal (bit8→ovf b0, bit9→ovf b5) | per-mode |
| 0x07 | **Overflow** | **packs the high bits** — see packing table below | per-mode |
| 0x08 | Preset Row Scan | bits4-0 = pixel-row scroll, bits6-5 = byte panning | `0x00` |
| 0x09 | **Maximum Scan Line** | bits4-0 = max scan line within char, bit5 = start-vblank bit9, bit6 = **line-compare bit9**, **bit7 = double-scan enable** | per-mode (0x41 for mode 13h double-scan) |
| 0x0A | Cursor Start | bits4-0 = first cursor scanline, **bit5 = cursor disable** | text only |
| 0x0B | Cursor End | bits4-0 = last cursor scanline, bits6-5 = cursor skew | text only |
| 0x0C | **Start Address High** | high 8 of the display start address (page base) | `0x00` |
| 0x0D | **Start Address Low** | low 8 of the display start address | `0x00` |
| 0x0E | Cursor Location High | high 8 of text cursor address | text only |
| 0x0F | Cursor Location Low | low 8 of text cursor address | text only |
| 0x10 | Vertical Retrace Start | low 8 (bit8→ovf b2, bit9→ovf b7) | per-mode |
| 0x11 | **Vertical Retrace End** | bits3-0 = vretrace-end, bit4 = clear vert-IRQ, bit5 = disable vert-IRQ, bit6 = 5 refresh cycles, **bit7 = WRITE-PROTECT idx 0x00–0x07** | per-mode |
| 0x12 | Vertical Display End | low 8 (bit8→ovf b1, bit9→ovf b6) | per-mode |
| 0x13 | **Offset** (stride) | bytes-per-scanline / K (K=2 byte, 4 word, 8 dword mode) | per-mode (0x28=40 for mode 13h chained; 80/2 etc.) |
| 0x14 | **Underline Location** | bits4-0 = underline row, bit5 = count-by-4 (chain-2/dword clock), **bit6 = doubleword addressing** | per-mode |
| 0x15 | Start Vertical Blanking | low 8 (bit8→ovf b3) | per-mode |
| 0x16 | End Vertical Blanking | low 7 of counter compare | per-mode |
| 0x17 | **Mode Control** | bit0 = CMS0 (MA13 subst), bit1 = SRSC (MA14 subst), bit2 = vtiming/2, bit3 = count-by-2 (word mode), bit5 = address-wrap, **bit6 = byte/word select**, bit7 = CRTC timing enable (sync) | per-mode (0xA3/0xE3 typical) |
| 0x18 | Line Compare | low 8 of split-screen line (bit8→ovf b4, bit9→max-scan b6) | `0xFF` |

**Overflow (idx 0x07) bit-packing** — the high bits of vertical counters, packed into one byte
(dosbox `vga_crtc.cpp:137-144`; spice86 `OverflowRegister.cs`):

| Ovf bit | Carries |
| - | --- |
| 0 | Vertical Total bit 8 |
| 1 | Vertical Display End bit 8 |
| 2 | Vertical Retrace Start bit 8 |
| 3 | Start Vertical Blanking bit 8 |
| 4 | Line Compare bit 8 |
| 5 | Vertical Total bit 9 |
| 6 | Vertical Display End bit 9 |
| 7 | Vertical Retrace Start bit 9 |

**Line Compare full value** = `(maxscanline.bit6 << 9) | (overflow.bit4 << 8) | crtc.regs[0x18]`
(dosbox `vga_crtc.cpp:125-126,167-168,382-383`). **Double-scan** = `maxscanline.bit7` (idx 0x09 b7).
**Start Address (page base)** = `(crtc.regs[0x0C] << 8) | crtc.regs[0x0D]` — accessor
`startAddress()`; consumed by the scanout/capture render (`plans/mode-y-vga.md` §5).

- **Write protocol:** `out8(0x3D4, idx)` latches; `out8(0x3D5, v)` writes `crtc.regs[idx]=v`. dosbox
  `vga_write_p3d4`/`vga_write_p3d5` (`vga_crtc.cpp:18-402`). The `f_1ac53.asm` adapter-detect probe
  does a 0x3D4/0x3D5 index/data round-trip (`plans/lamut-milestone.md:123`) — so **read-back is
  required** (dosbox `vga_read_p3d5` `vga_crtc.cpp:404-442` returns each stored reg).
- **WRITE-PROTECT (idx 0x11 bit 7):** when set, writes to idx 0x00–0x07 are **ignored** (dosbox
  `vga.crtc.read_only`, set at `vga_crtc.cpp:260-264`, checked at the top of each of idx 0–6's write
  arms `:38,47,59,68,83,93,107`). **Exception:** the Line Compare bit in Overflow (idx 0x07 bit 4) is
  written *regardless* of write-protect (dosbox `vga_crtc.cpp:124-126` writes `line_compare` before
  the `read_only` early-out). zdos must replicate: gate idx 0–7 writes on `(regs[0x11] & 0x80)`,
  except still latch line-compare-bit-8 from idx 0x07 bit 4.
- **Bits driving behaviour elsewhere (named):** Start Address (0x0C/0x0D) → scanout page base
  (`plans/mode-y-vga.md` §5); Mode Control byte/word/dword (0x17 b6) + Underline dword (0x14 b6) →
  address shift for the memory engine; Offset (0x13) → row stride; the LAMUT/Mode-Y "unchain" probe
  reads idx 0x14 b6 / 0x17 b6 back (`plans/mode-y-vga.md:147`). **All must round-trip.**

---

## 4. Graphics Controller (GC) — index 0x3CE / data 0x3CF

9 registers (idx 0x00–0x08). dosbox `vga_gfx.cpp`; spice86 `GraphicsControllerRegisters.cs` +
`Graphics/*.cs`. **Index masked to bits 3-0** (dosbox `write_p3ce` `vga_gfx.cpp:16`).

| Idx | Name | Bit layout / semantics | Reset |
| - | --- | --- | --- |
| 0x00 | **Set/Reset** | bits3-0 = the set/reset value per plane (used in write modes 0 [if enabled] & 3) | `0x00` |
| 0x01 | **Enable Set/Reset** | bits3-0 = which planes take the Set/Reset value vs the CPU byte (write mode 0) | `0x00` |
| 0x02 | **Color Compare** | bits3-0 = the color to match in read mode 1 | `0x00` |
| 0x03 | **Data Rotate** | bits2-0 = rotate-right count (write mode 0), bits4-3 = function select (0=copy,1=AND,2=OR,3=XOR with latch) | `0x00` |
| 0x04 | **Read Map Select** | bits1-0 = plane a read-mode-0 read returns | `0x00` |
| 0x05 | **Mode** | bits1-0 = **write mode 0-3**, bit3 = **read mode 0/1**, bit4 = odd/even, bit5 = shift-register (CGA), bit6 = **256-color (shift-256)** | `0x00` |
| 0x06 | **Miscellaneous** | bit0 = graphics/alpha select, bit1 = chain odd/even, **bits3-2 = memory map** (0=A000-BFFF/128K, 1=A000-AFFF/64K, 2=B000-B7FF/32K, 3=B800-BFFF/32K) | `0x00` (varies by mode-set) |
| 0x07 | **Color Don't Care** | bits3-0 = which planes participate in read-mode-1 compare (0=ignore) | `0x00` |
| 0x08 | **Bit Mask** | bits7-0 = per-bit write enable within the byte (write modes 0/2/3) | `0xFF` |

- **Write protocol:** `out8(0x3CE, idx&0x0F)` latches; `out8(0x3CF, v)` writes `gfx.regs[idx]=v`.
  dosbox `write_p3ce`/`write_p3cf` (`vga_gfx.cpp:13-182`). 16-bit `out16(0x3CE, 0x4105)` = idx 0x05,
  data 0x41 (the `f_14c3c.asm:128` GC-Mode setup) → split.
- **Read-back:** `read_p3ce` returns `index`; `read_p3cf` returns the stored reg (dosbox
  `vga_gfx.cpp:19-22,184-212`). The `f_1ca27.asm` save/restore reads idx 0,1,3,4,5,8 back — **the
  whole file must round-trip** (`plans/mode-y-vga.md:123-130`).
- **Bits driving behaviour elsewhere (named):** Mode write/read mode (0x05 b1-0 / b3), Read Map
  Select (0x04), Bit Mask (0x08), Set/Reset (0x00) + Enable (0x01), Data Rotate + raster-op (0x03) →
  the planar VRAM read/write engine (`plans/mode-y-vga.md` §4.3, accessors `writeMode()`/`readMode()`
  /`readMapSelect()`/`bitMask()`/`setReset()`/`enableSetReset()`/`dataRotate()`/`rasterOp()`).
  Memory-map select (0x06 b3-2) → which CPU window decodes to VRAM (spice86
  `MiscellaneousGraphicsRegister.cs:43-49`). **Store all; the effect lives in the memory-engine spec.**

---

## 5. Attribute Controller (AC) — port 0x3C0 (flip-flop) + read 0x3C1

21 registers (idx 0x00–0x14). dosbox `vga_attr.cpp`; spice86 `AttributeControllerRegisters.cs` +
`AttributeController/*.cs`. **This group's defining feature is the address/data flip-flop on one
port.**

### 5.1 The flip-flop protocol (specify precisely)

- The AC has a one-bit internal flip-flop: **address phase** vs **data phase**.
- **Power-on / after a 0x3DA(0x3BA) read → address phase.** zdos's field
  `attr_flip_flop_is_index: bool = true` already models exactly this latch (`vga.zig:207`), reset by
  the status read (`vga.zig:479`). The full state machine reuses it.
- **Write to 0x3C0 in the address phase:** the low 5 bits (`val & 0x1F`) latch `attr.index`; **bit 5
  is the Palette Address Source (PAS)** (see §5.2). Then flip to data phase. (dosbox `write_p3c0`
  `vga_attr.cpp:97-108`; spice86 `VgaIoPortHandler.cs:294-299` masks `value & 0b11111`.)
- **Write to 0x3C0 in the data phase:** write `attr.regs[index] = val` (palette regs masked to 6 bits,
  see §5.3); then flip back to address phase. (dosbox `:110-273`; spice86 `:300-309`.)
- **Each 0x3C0 write toggles the flip-flop** (spice86 `_attributeDataMode = !_attributeDataMode`
  `:308`; dosbox toggles `is_address_mode` per branch `:98,111`).
- **Read 0x3C1** returns `attr.regs[index]` (VGA only — does NOT toggle the flip-flop; dosbox
  `read_p3c1` `vga_attr.cpp:277-322`, spice86 `VgaIoPortHandler.cs:143-148`).
- **Read 0x3C0** returns the index register `attr.index` with bit 5 = PAS state (dosbox `read_p3c0`
  `vga_attr.cpp:83-91`). Faithful but rarely used; model the read for completeness.

> This **replaces the `assert(false)` at `vga.zig:531`** with a real state machine. The flip-flop is
> guest-visible state → snapshot it (zdos already snapshots `attr_flip_flop_is_index` `vga.zig:558`).

### 5.2 Palette Address Source (PAS) — 0x3C0 bit 5 (in address phase)

The address-phase write's **bit 5** gates whether the AC drives the **display** or accepts **CPU
palette access**:
- **PAS = 1 (bit 5 set):** normal operation — the AC feeds the display; the internal palette is
  **locked** against CPU writes (writes to palette regs 0x00–0x0F are ignored/undefined).
- **PAS = 0 (bit 5 clear):** CPU may load the internal palette regs.

dosbox stores this as `vga.attr.disabled & 0x1` (`vga_attr.cpp:103-107`) and only writes palette regs
when `disabled` (`:133-136`). spice86 tracks it via the same address-write path. **zdos
recommendation:** store a `attr_pas: bool` (or the equivalent `disabled` bit); gate palette-reg
writes on it; default PAS to the locked/display state at reset. (For LAMUT/BaK this is low-stakes —
the palette is pushed via the DAC, not the AC — but the BIOS mode-set drives 0x3C0, so model it.)

### 5.3 The 21 AC registers

| Idx | Name | Bit layout / semantics | Reset |
| - | --- | --- | --- |
| 0x00–0x0F | **Palette** 0-15 | bits5-0 = 6-bit index into the DAC's first 64 entries (the internal palette LUT); writes masked to `& 0x3F` (spice86 `AttributeControllerRegisters.cs:79`) | `0x00` |
| 0x10 | **Mode Control** | bit0 = graphics/alpha, bit1 = mono emulation, bit2 = line-graphics enable (9th-dot), bit3 = blink enable, bit5 = pixel-panning compat (split-screen), **bit6 = 8-bit (256-color) pixel**, bit7 = palette-bits-5-4-select (use Color Select for bits 4-5) | `0x00` |
| 0x11 | **Overscan Color** | bits7-0 = border color (DAC index) | `0x00` |
| 0x12 | **Color Plane Enable** | bits3-0 = which display planes feed the AC; bits5-4 = video status MUX (diagnostic → status#1 bits 4-5) | `0x0F` |
| 0x13 | **Horizontal Pixel Panning** | bits3-0 = pixels to shift the display left | `0x00` |
| 0x14 | **Color Select** | bits1-0 = DAC index bits 5-4 (when mode-ctrl b7 set), bits3-2 = DAC index bits 7-6 (except 256-color) | `0x00` |

- **Read-back:** 0x3C1 returns `regs[index]` for all 21 indices (dosbox `vga_attr.cpp:279-321`;
  spice86 `:57-70`). Indices 0x15–0x1F read 0 (unmodeled), no toggle.
- **Bits driving behaviour elsewhere (named):** the internal palette (0x00–0x0F) + Color Select
  (0x14) + Mode-Control b7/b6 form the **4-bit-attribute → DAC-index translation** for text/16-color
  modes (spice86 `DacRegisters.RebuildAttributeMap` `:175-187`). **Mode 13h / Mode-Y bypass the AC
  palette** (256-color reads the DAC directly), so for the LAMUT path these regs only need to
  **round-trip** (read-back), not feed the render (`plans/mode-y-vga.md:407-410`). Specify storage +
  the flip-flop here; flag the AC→DAC pipeline as deferred-with-a-flag if a guest drives a 16-color
  mode into the capture.

---

## 6. DAC (RAMDAC palette) — write-index 0x3C8 / read-index 0x3C7 / data 0x3C9 / pel-mask 0x3C6

**zdos models this group fully** (`vga.zig:163-185,390-458,500-523`). This section is a cross-ref +
a precise note of the (tiny) gaps vs the full spec. dosbox `vga_dac.cpp`; spice86 `DacRegisters.cs`.

### 6.1 The 256×18-bit palette + protocol

- **Storage:** 256 entries × 3 components × **6 bits** (the VGA DAC is 6-bit per channel: 0..63 →
  18-bit color). zdos: `dac_rgb: [256]DacRgb` storing raw 0..63 (`vga.zig:100,165`), masked `& 0x3F`
  on write (`vga.zig:412`). **Stored as written, not scaled** — read-back must return exactly what
  was written (`vga.zig:98-99`, io-oracle §1.2). ✓ correct.
- **Write protocol (0x3C8 → 0x3C9×3):** `out8(0x3C8, idx)` sets the **write index**, `pel_index=0`,
  `state=write`, and (non-Paradise) `read_index = idx-1`. Then 3 successive `out8(0x3C9, v)` write
  R, G, B (each `& 0x3F`); after the 3rd, the index auto-increments. dosbox `write_p3c8`/`write_p3c9`
  (`vga_dac.cpp:214-297`); zdos `write3c8`/`write3c9` (`vga.zig:392-432`). ✓
- **Read protocol (0x3C7 → 0x3C9×3):** `out8(0x3C7, idx)` sets the **read index**, `pel_index=0`,
  `state=read`, `write_index = idx+1`. Then 3 `in8(0x3C9)` return R, G, B; after the 3rd,
  `read_index` auto-increments. dosbox `write_p3c7`/`read_p3c9` (`vga_dac.cpp:196-212,299-326`); zdos
  `write3c7`/`read3c9` (`vga.zig:401-458`). ✓
- **DAC State Register (read 0x3C7):** bits1-0 = `0x3` if last access was a read (0x3C7 set),
  `0x0` if a write (0x3C8 set). dosbox `read_p3c7` (`vga_dac.cpp:205-212`); zdos `vga.zig:504`. ✓
- **Write-index read-back (read 0x3C8):** returns the current write index. dosbox `read_p3c8`
  (`vga_dac.cpp:223-226`); zdos `vga.zig:505`. ✓
- **Pel Mask (0x3C6, R/W):** AND-mask applied to the palette index at scanout; power-on `0xFF`.
  dosbox `write_p3c6`/`read_p3c6` (`vga_dac.cpp:175-194`); zdos `pel_mask` (`vga.zig:185,503,520`). ✓

### 6.2 Gaps vs full spec (minor, flagged)

1. **Index auto-advance on a full read triple — `write_index` coupling.** Real dosbox **does not**
   re-link `write_index` after a 0x3C9 *read* triple (it explicitly disables it: "breaks wari",
   `vga_dac.cpp:285-286,315-316`). zdos's `read3c9` **does** set `read_index = write_index;
   write_index +%= 1` after blue (`vga.zig:448-451`), and `write3c9` likewise couples them
   (`vga.zig:428-430`). **This diverges from dosbox's de-coupled behaviour** and is the one place to
   double-check against hardware/oracle: on real VGA, a read triple increments `read_index` only
   (and a write triple increments `write_index` only). **Flag:** verify zdos's coupling against the
   DAC oracle corpus (io-oracle §1.2) — if the oracle shows decoupled increment, change `read3c9`/
   `write3c9` to advance only their own index (matching dosbox). This is a real correctness question,
   not a fake; surface it rather than paper over.
2. **6-bit vs 8-bit DAC.** zdos pins 6-bit (dosbox `vga.dac.bits=6`, `vga_dac.cpp:365`). The DAC has
   no 8-bit mode on plain VGA; correct. (The 6→8 *scale for rendering* belongs to the capture spec,
   not here — `plans/mode-y-vga.md:382-386`.)
3. **`read_p3c8 = 0x10` quirk.** dosbox returns a hardcoded `0x10` from 0x3C8 **only on non-VGA**
   (EGA path, `vga_misc.cpp:108-111,155`); on VGA, 0x3C8 returns the write index (`vga_dac.cpp:223`).
   zdos correctly returns the write index. ✓ (No action; noted so a reader doesn't "fix" it.)

### 6.3 Determinism note (DAC read-delay hack — DO NOT COPY)

Some emulators model a DAC read settling delay; **zdos must not** (host-timing). zdos charges DAC
port I/O via the CPU's `IN`/`OUT` instruction cost only (`vga.zig:46-50`); no synthetic DAC delay, no
host clock. dosbox-staging does not add a per-read DAC cycle delay here either (that hack lives in
`vga_memory.cpp` for VRAM, flagged in `plans/mode-y-vga.md:218-220` as "do not copy").

---

## 7. dosbox vs spice86 — what to copy, what to avoid (with file:line)

| Aspect | dosbox-staging | spice86 | zdos decision |
| --- | --- | --- | --- |
| **Register storage** | flat named fields per group (`vga.h:869-983` `VgaSeq`/`VgaCrtc`/`VgaGfx`/`VgaAttr`/`VgaDac`) | typed register **classes**, `regs[index]` via `ReadRegister/WriteRegister` switch (`SequencerRegisters.cs:49-93`, etc.) | **indexed `[N]u8` POD + `index:u8` latch** (spice86's indexed shape, dosbox's flatness) — see §8 |
| **Index/data protocol** | index port stores `index`; data port switches on it (`vga_seq.cpp:12-21`) | identical (`VgaIoPortHandler.cs:125-160,276-335`) | copy: latch index, `regs[index]` data |
| **16-bit OUT (index+data)** | (handled by IO width split) | `WriteWord = WriteByte(lo)+WriteByte(hi+1)` (`VgaIoPortHandler.cs:361-364`) | **copy spice86**: split a `out16(0x3C4,…)` to index-then-data (verify bus wide-port path, `plans/mode-y-vga.md` Q2) |
| **AC flip-flop** | `is_address_mode` toggled per write (`vga_attr.cpp:97-111`) | `_attributeDataMode` toggled per write, reset on 0x3DA read (`VgaIoPortHandler.cs:162,294-309`) | copy: reuse `attr_flip_flop_is_index` (`vga.zig:207`); reset on 0x3DA read (`vga.zig:479`) |
| **Bit decoding** | precomputes lookup tables (`FillTable`/`ExpandTable`, `vga_seq.cpp:64`, `vga_gfx.cpp:162`) for the *renderer* | typed bit-field accessors (`GraphicsModeRegister.cs:22-70`) | **decode at use-site** (one accessor each), **not** typed wrapper structs — matches zdos's flat DAC model; avoid dosbox's render-side fan-out tables (those are renderer accel, not storage) |
| **Read-back** | every data port returns its stored reg (`vga_seq.cpp:128-140`, `vga_gfx.cpp:186-211`, `vga_crtc.cpp:407-442`, `vga_attr.cpp:279-321`) | same (`ReadRegister` switches) | copy: full round-trip from the `[N]u8` array |
| **CRTC write-protect** | `read_only` gates idx 0-7, except line-compare-b8 (`vga_crtc.cpp:124-126,260-264`) | (modeled in reg classes) | **copy dosbox** exactly (§3) |
| **CGA "snow" / read-delay** | VRAM read-delay `CPU_Cycles -= delay` (`vga_memory.cpp`) | jitter/threaded dirty flags | **AVOID** (host-timing / non-determinism) — `plans/mode-y-vga.md:218-226` |
| **Renderer-side palette maps** | `palette_map`/`Bgrx8888` (`vga_dac.cpp:163`) | `PaletteMap`/`AttributeMap` rebuilt on write (`DacRegisters.cs:150-187`) | **AVOID at the storage layer** — zdos's capture is a pure peek at a fixed cycle; render from raw regs, no precomputed cache (`plans/mode-y-vga.md:214-217`) |

**Net pattern to copy:** spice86's **indexed register-file shape with full read-back** + its
**16-bit-OUT split** + its **AC flip-flop reset-on-status-read**, but stored as **plain Zig POD
arrays** (dosbox's flatness, no class hierarchy, no typed wrapper structs), decoding bits at the use
site. **Avoid** both refs' renderer-side precomputed palette/pixel caches and dosbox's VRAM
read-delay — they are render acceleration / host-timing, hostile to zdos's pure-peek determinism.

---

## 8. zdos's current gap + recommended Zig representation

### 8.1 The precise gap (cited)

| Group | zdos today | file:line |
| --- | --- | --- |
| External: Misc Output | **modeled** (0x3C2 wr / 0x3CC rd, stored `misc_output`) | `vga.zig:189,507,519` |
| External: Input Status #1 | **modeled** (cycle-derived 0x3DA/0x3BA) | `vga.zig:476-498,512` |
| External: Input Status #0 (0x3C2 rd) | **absent** → reads 0xFF (unmapped) | `vga.zig:513` |
| External: Feature Control (0x3CA rd / 0x3DA wr) | **absent** → 0xFF / dropped | `vga.zig:513,532` |
| **Sequencer** 0x3C4/0x3C5 | **absent** → write `else => {}` dropped, read 0xFF | `vga.zig:532,513` |
| **CRTC** 0x3D4/0x3D5 | **absent** (no device CRTC file; BDA stores 0x3D4 in int10 only) | — |
| **Graphics Controller** 0x3CE/0x3CF | **absent** → dropped / 0xFF; engine reads them back (wrong to drop) | `vga.zig:532,513` |
| **Attribute Controller** 0x3C0/0x3C1 | **`assert(false)`** on write; flip-flop field exists | `vga.zig:531,207` |
| **DAC** 0x3C6-0x3C9 | **fully modeled** (one read/write-coupling to verify, §6.2) | `vga.zig:390-458` |

### 8.2 Recommended representation — indexed POD register files

Add four indexed register files to `Vga` (matches `plans/mode-y-vga.md:282-288`):

```zig
seq:  RegFile(5)  = .{},   // Sequencer    0x3C4/0x3C5  (idx 0x00-0x04)
crtc: RegFile(32) = .{},   // CRTC         0x3D4/0x3D5  (idx 0x00-0x18; 32 for headroom)
gfx:  RegFile(9)  = .{},   // Gfx Ctrl     0x3CE/0x3CF  (idx 0x00-0x08)
attr: RegFile(21) = .{},   // Attr Ctrl    0x3C0/0x3C1  (idx 0x00-0x14)
feature_control: u8 = 0,   // 0x3CA rd / 0x3DA wr (inert, round-trip)

fn RegFile(comptime n: usize) type {
    return extern struct { index: u8 = 0, regs: [n]u8 = @splat(0) };
}
```

(The exact array sizes can round up to powers of two if that simplifies index masking; the spec
requires the *valid* index ranges above to round-trip. `extern struct` keeps them snapshot-stable
POD.) The AC flip-flop reuses the existing `attr_flip_flop_is_index` field (`vga.zig:207`) — do not
add a second flip-flop; unify (`plans/mode-y-vga.md:300-301`).

**Port arms** (replace `vga.zig:513` `else => 0xFF` and `:531-532`):

```text
in8:   0x3C2 -> 0x10 (Input Status #0 const)        0x3CA -> feature_control
       0x3C4 -> seq.index    0x3C5 -> seq.regs[seq.index]
       0x3CE -> gfx.index    0x3CF -> gfx.regs[gfx.index]
       0x3D4 -> crtc.index   0x3D5 -> crtc.regs[crtc.index]
       0x3C0 -> attr.index | (PAS<<5)               0x3C1 -> attr.regs[attr.index]
out8:  0x3C4 -> seq.index=v   0x3C5 -> seq write (see §2)
       0x3CE -> gfx.index=v&0x0F   0x3CF -> gfx write
       0x3D4 -> crtc.index=v  0x3D5 -> crtc write (write-protect §3)
       0x3C0 -> AC flip-flop state machine (§5.1)
       0x3DA,0x3BA -> feature_control = v
out16: 0x3C4/0x3CE/0x3D4 -> index=lo, then data write of hi (§0)
```

**Accessors** the memory engine + scanout consume (decode at use-site, defined here for reference,
*effect* specified elsewhere): `mapMask() = seq.regs[2] & 0x0F`,
`chained() = (seq.regs[4] & 0x08) != 0`, `writeMode() = gfx.regs[5] & 3`,
`readMode() = (gfx.regs[5] >> 3) & 1`, `readMapSelect() = gfx.regs[4] & 3`, `bitMask() = gfx.regs[8]`,
`setReset() = gfx.regs[0] & 0x0F`, `enableSetReset() = gfx.regs[1] & 0x0F`,
`dataRotate() = gfx.regs[3] & 7`, `rasterOp() = (gfx.regs[3] >> 3) & 3`,
`startAddress() = (@as(u16, crtc.regs[0x0C]) << 8) | crtc.regs[0x0D]`.

### 8.3 Snapshot + reset + determinism

- **Snapshot:** add `seq`/`crtc`/`gfx`/`attr` (each `{index, regs}`) + `feature_control` to
  `Vga.Snapshot` (`vga.zig:549-559`) and `snapshot`/`restore` (`:561-584`). Plain POD; the existing
  DAC + misc + flip-flop fields stay. The 256 KiB VRAM slab is caller-copied out-of-band (unchanged).
- **Reset** (`vga.zig:231`): zero the four files, then set the **power-on defaults that keep mode 13h
  the boot path** — Map Mask = 0x0F (`seq.regs[2]`), chain-4 set (`seq.regs[4] |= 0x08`), Bit Mask =
  0xFF (`gfx.regs[8]`), Color Plane Enable = 0x0F (`attr.regs[0x12]`), `feature_control = 0`,
  `pel_mask = 0xFF` (already), `attr_flip_flop_is_index = true` (already). These match real VGA
  power-on closely enough that the chained fast path is the default and existing mode-13h tests are
  undisturbed (`plans/mode-y-vga.md:437-440`).
- **Determinism:** every register is pure guest state; the read/write paths are pure functions of
  (device state, port, value) — no host clock, float, or RNG (CLAUDE #2/#3, bus handler-purity
  contract). zdos's float/host-clock grep-gate already covers `vga.zig` (`plans/vga-retrace.md:567-573`)
  — the new code is pure integer; keep it that way. **Add a snapshot round-trip test** for the four
  register files (mirror the existing DAC/VRAM round-trip).
- **No cycle-ledger hole:** register port I/O is charged by the CPU's `IN`/`OUT` cost; the handler
  adds zero cycles, exactly like the DAC ports today (`vga.zig:46-50`). No synthetic trap, no hole.

---

## 9. Synthesis (for the implementer)

- **6 groups, 60 indexed registers** (SEQ 5 + CRTC 25 + GC 9 + AC 21) **+ 4 External/General + the
  DAC** (256×3 palette RAM + pel-mask + 2 index ports + state). zdos models the **DAC + Misc Output +
  Input Status #1** today; the **~60 indexed registers + Input Status #0 + Feature Control are the
  gap**.
- **Three protocols:** (1) indexed SEQ/CRTC/GC — index port latches `index`, data port hits
  `regs[index]`, **16-bit OUT = index+data**, full read-back; (2) AC — one port (0x3C0) with an
  **address/data flip-flop** reset by a 0x3DA/0x3BA read, plus the **PAS bit 5** gating display vs CPU
  palette access, read-back at 0x3C1; (3) DAC — index (0x3C8 wr / 0x3C7 rd) + 3-byte auto-incrementing
  R-G-B at 0x3C9, state at 0x3C7, pel-mask at 0x3C6.
- **What zdos must add:** four indexed POD register files (`{index, regs:[N]u8}`) with full read-back,
  the AC flip-flop state machine (replacing `assert(false)` at `vga.zig:531`), the Input Status #0
  constant + Feature Control byte, the CRTC write-protect gate (idx 0x11 b7 over idx 0x00–0x07, except
  line-compare-b8), and snapshot/reset coverage. Decode bits at use-site accessors, not typed wrapper
  structs.
- **Copy spice86's indexed shape + 16-bit-OUT split + AC flip-flop; avoid both refs' renderer-side
  palette/pixel caches and dosbox's VRAM read-delay.**
- **Determinism caveats:** (a) all registers are pure guest state → trivially deterministic +
  snapshot-covered; no host clock anywhere. (b) The **only** flagged correctness question is the DAC
  read/write index coupling (§6.2 item 1): zdos re-links `read_index`/`write_index` on a full triple
  where dosbox deliberately does **not** ("breaks Wari") — verify against the DAC oracle and decouple
  if the oracle says so (do not paper over). (c) Input Status #1 stays cycle-derived and **excluded
  from every cross-emulator golden** (`plans/vga-retrace.md`); the new register files, being pure
  guest state, **are** valid goldens (a snapshot/peek of them is byte-stable).
