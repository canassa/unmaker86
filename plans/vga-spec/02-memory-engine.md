# VGA memory access engine — the CPU↔VRAM read/write path (complete spec)

Status: **specification** (no source changed by this document). This is the authoritative,
hardware-complete description of **everything that happens when the CPU reads or writes the VGA
memory window** (A0000–BFFFF), across **all VGA modes**: the 4-plane VRAM + latch model, all four
write modes, both read modes, every addressing/memory mode (chained 256-color, unchained planar,
odd/even, doubleword, EGA 16-color planar), and the GC-Misc memory-map window select. It supersedes
and completes the planar portions of `plans/mode-y-vga.md` (which is the implementation-phased
plan for the BaK/LAMUT subset); where this document and `mode-y-vga.md` differ, **this document is
the hardware spec and `mode-y-vga.md` is the build order**.

Sibling specs in `plans/vga-spec/` own the register *files* (Sequencer/GC/CRTC/AC port protocol),
the DAC, the retrace timing, and the framebuffer-capture render. This document owns **the memory
engine only**: given the current register state + VRAM + latches, what a CPU access at an A000/B000
physical address does. It cites the register decode it consumes but does not specify the port
protocol (that is `01-register-files.md` / `mode-y-vga.md §4.2`).

References cited throughout:
- dosbox-staging `references/dosbox-staging/src/hardware/video/vga_memory.cpp` (the canonical
  write/read-mode arithmetic + the page-handler dispatch).
- spice86 `references/spice86/src/Spice86.Core/Emulator/Devices/Video/VideoMemory.cs` (the clearest
  plane decode + explicit per-write-mode methods) and its register decoders under
  `.../Devices/Video/Registers/`.
- zdos current state: `src/devices/vga.zig`, `src/bus/bus.zig`.

---

## 0. The gap in zdos today (what this engine adds)

zdos models **only the linear/chained mode-13h path** (`src/devices/vga.zig`):

- A0000 is mapped RAM-like; `memGetHostPtr` (`vga.zig:288-293`) always returns
  `&vram[phys-0xA0000]`, so a guest `mov [es:di],al` lands straight in `vram[off]` through the bus
  host-pointer fast path (`bus.zig:305-308`) — **bypassing every plane gate**. That IS mode 13h
  (one CPU byte = one pixel = one palette index), and it must keep working unchanged.
- A 256 KiB slab (`VRAM_SIZE=0x40000`, `vga.zig:63-66`) — 4 × 64 KiB — is already reserved "so a
  faithful future planar mode has real storage (no fake)". This engine fills that reservation.
- `memRead8`/`memWrite8`/`memPeek8` (`vga.zig:295-308`) are pure linear `vram[off]` accessors.

**Absent today (everything below):** the 4 plane latches; write modes 0/1/2/3; read modes 0/1; the
Map-Mask plane gate; Set/Reset + Enable-Set/Reset; Data Rotate + the ALU ops; the Bit Mask; Color
Compare + Color Don't Care; the chained-vs-unchained / odd-even / doubleword address decode; and the
GC-Misc memory-map window select. The register *files* that drive all of this (Sequencer 0x3C4/5,
Graphics Controller 0x3CE/F, CRTC 0x3D4/5, Attribute Controller 0x3C0/1) are also absent — they are
specified in the register-file sibling/`mode-y-vga.md §4.2`; this engine only **consumes** their
decoded fields.

---

## 1. The VRAM model — 4 planes × 64 KiB + 4 latches

### 1.1 Physical model (hardware)

VGA video memory is **4 bit-planes of 64 KiB each = 256 KiB**. The CPU never addresses a plane
directly: a single CPU address selects an **offset** common to all four planes; *which* plane(s) a
read or write touches is decided by the **addressing mode** (chain-4 / odd-even / planar) + the
**Map Mask** (writes) / **Read Map Select** (reads). The four planes are read in parallel into four
**8-bit latch registers** on *every* CPU read; the latches feed the write-mode arithmetic.

This is identical in both references: spice86 `VRam = new byte[4 * 64 * 1024]` + `_latches = new
byte[4]` (`VideoMemory.cs:29-31`); dosbox `vga.mem.linear` addressed as `(uint32_t*)` (a packed
4-byte word per offset) with `vga.latch.d` the 32-bit latch (`vga_memory.cpp:131,283`).

### 1.2 Storage layout — interleaved (refs) vs plane-major (zdos choice)

Both references store VRAM **byte-interleaved**: `vram[offset*4 + plane]`, so the four planes of one
offset are four adjacent bytes and a read is a single `uint32_t` load (dosbox
`((uint32_t*)vga.mem.linear)[start]`, `vga_memory.cpp:131`; spice86 `baseIdx = offset*4`,
`VideoMemory.cs:47-51,270`).

**zdos uses a plane-major layout instead: `vram[plane*0x10000 + offset]`** (plane 0 =
0x00000..0x0FFFF, plane 1 = 0x10000.., …). Rationale — three concrete wins, one negligible cost:

1. **Reuses the existing `VRAM_SIZE=0x40000` slab as 4 contiguous 64 KiB planes** with no reshape.
2. **Plane 0's first 64 KiB stays byte-identical to the current linear mode-13h layout.** In chained
   256-color mode the chain-4 decode maps `off&3 → plane` (§4.1); when `off&3==0` the write lands at
   `vram[0*0x10000 + off>>2]` — i.e. mode-13h pixel data is "plane-major plane patterns", and the
   RAM-like fast path is undisturbed (chained mode keeps using `getHostPtr`; see §6). *(Note: the
   chain-4 byte→pixel mapping is the same conceptually in both layouts; the win is that we never
   reshape the slab and the existing fast path and snapshot/region contracts are untouched.)*
3. **The capture de-interleave is a trivial `vram[plane*0x10000 + start + y*80 + x/4]`** (the §7
   framebuffer render), the exact inverse of the write mapping.

Cost (corrected — review perf headline; the earlier "negligible" claim was wrong): the plane-major
layout has a **real, asymmetric cache cost** vs the refs' interleaved layout, and the decision stands
*despite* it, not because it's free:
- **All-four-planes access (latch load on read; a 4-plane fan-out fill)** touches 4 bytes that are
  **64 KiB apart** → up to **4 distinct cache lines and 4 TLB entries** where the interleaved layout
  touches **one** line (the `uint32_t`). That is a ~4× cache-line / TLB blowup on the planar latch
  load and the all-plane write.
- **Single-plane strip access (the common Mode-X case: write one plane across a scanline, Map-Mask =
  one bit)** is the **inverse 4× win**: consecutive pixels of one plane are contiguous in plane-major
  (`vram[p*0x10000 + off], off+1, …`) but 4 bytes apart in interleaved. Plane-major is *better* here.

**Net: keep plane-major.** The decisive reason is unchanged and dominates — **mode-13h plane 0 stays
byte-identical to the existing linear slab (zero regression, fast path untouched)** and the slab/
snapshot/region contracts need no reshape. The planar path is the slow per-access path regardless
(taken only when unchained). But the rationale must be honest: it is a *deliberate trade* (single-plane
locality + zero-reshape + mode-13h identity, at the cost of 4-line latch loads), **not** a free choice.
**This is the one place zdos deliberately diverges from both refs' layout.** Document this trade in the
`vga.zig` header.

### 1.3 The 4 latches are device state

```zig
latch: [4]u8 = @splat(0),   // plane 0..3 latch; loaded on EVERY CPU read of the A000/B000 window
```

The latches are **pure guest state** (loaded by guest reads, consumed by guest writes), so they are
snapshot-covered (§8). dosbox: `vga.latch.d` (a 32-bit union over 4 bytes). spice86:
`_latches[4]`. zdos: `[4]u8`, one byte per plane.

---

## 2. Write modes 0, 1, 2, 3 — the exact data path

A write to the VGA window runs a fixed pipeline. The **per-mode** stage is `ModeOperation` (dosbox)
/ `HandleWriteModeN` (spice86); the **common tail** is the Bit-Mask latch-merge and the Map-Mask
plane gate. The full pipeline (write mode 0, the superset):

```
CPU byte v
  └─(1) Data Rotate:        v = ror(v, rotate_count)          [GC idx 3 bits 2:0]
  └─(2) Set/Reset select:   per plane p, if EnableSetReset bit p:  byte = (SetReset bit p ? 0xFF : 0x00)
                                          else:                     byte = v
                                          [GC idx 0 = Set/Reset, idx 1 = Enable Set/Reset]
  └─(3) ALU (Data Rotate fn): byte = aluop(byte, latch[p])    [GC idx 3 bits 4:3: 00 replace,01 AND,10 OR,11 XOR]
  └─(4) Bit Mask merge:      byte = (byte & bitMask) | (latch[p] & ~bitMask)   [GC idx 8]
  └─(5) Map Mask gate:       if (mapMask bit p) write byte to plane p; else leave plane p   [SC idx 2]
```

Stages 1–4 produce the per-plane data; stage 5 is the plane-write gate shared by *all* four write
modes (and by all addressing modes — §4). Each write mode selects a different subset of stages 1–4.

### 2.1 Write Mode 0 — full path (the common BaK Mode-X fan-out case)

Host data rotated → Enable-Set/Reset selects host-data-or-Set/Reset → ALU with latch → Bit-Mask
selects resulting-data-vs-latch → Map-Mask gates planes.

- dosbox `ModeOperation` case 0 (`vga_memory.cpp:68-74`): `val = ror(val, data_rotate); full =
  ExpandTable[val]` (replicate the byte across all 4 plane-bytes of the 32-bit word); `full = (full
  & full_not_enable_set_reset) | full_enable_and_set_reset` (Enable-Set/Reset select, precomputed
  32-bit masks); `full = RasterOp(full, full_bit_mask)` (the ALU + Bit-Mask merge in one — see §2.5).
- spice86 `HandleWriteMode0` (`VideoMemory.cs:218-242`): per plane: `ror`; if `setResetEnable[p]`
  then `0xFF/0x00` from `setReset[p]`; `ApplyAluFunction`; `&= BitMask; |= latch[p] & ~BitMask`.

**zdos per-plane formula (plane p in the Map-Mask set):**
```
b   = ror(v, dataRotate)
src = enableSetReset[p] ? (setReset[p] ? 0xFF : 0x00) : b
res = alu(src, latch[p])                       // alu ∈ {replace, AND, OR, XOR}
out = (res & bitMask) | (latch[p] & ~bitMask)
vram[p*0x10000 + off] = out
```
Default Data-Rotate=0, Enable-Set/Reset=0, ALU=replace, Bit-Mask=0xFF ⇒ `out = v` for each masked
plane — the plain Map-Mask fan-out the BaK Mode-X blitter uses (`mode-y-vga.md §2.1`).

### 2.2 Write Mode 1 — latch copy (the page-to-page / GC-Mode-0x41 path)

Data goes **directly from the 4 latches to the 4 planes**; the host byte is unused; Bit-Mask is
ignored; only the Map-Mask gates. This is the engine of a `rep movsb` VRAM→VRAM copy: a read loads
the 4 latches, the paired write stores them.

- dosbox `ModeOperation` case 1 (`vga_memory.cpp:76-77`): `full = vga.latch.d`.
- spice86 `HandleWriteMode1` (`VideoMemory.cs:208-216`): per masked plane `WriteValue(p, off,
  latch[p])`.

**zdos:** `vram[p*0x10000 + off] = latch[p]` for each plane p in the Map-Mask set.

### 2.3 Write Mode 2 — fill planes from the low 4 CPU bits, via Bit-Mask

Bits 3..0 of the host byte are each **replicated across all 8 bits** of their plane (bit p →
0x00/0xFF for plane p). Then ALU with latch, then Bit-Mask merge, then Map-Mask. Data-Rotate and
Set/Reset are **ignored**.

- dosbox `ModeOperation` case 2 (`vga_memory.cpp:79-81`): `full = RasterOp(FillTable[val&0xF],
  full_bit_mask)` (`FillTable[n]` expands the 4 bits of `n` into a 32-bit word, one plane-byte each).
- spice86 `HandleWriteMode2` (`VideoMemory.cs:186-206`): per plane: `unpacked[p] = bit p of value`;
  `temp = unpacked[p] ? 0xFF : 0x00`; `ApplyAluFunction`; `&= BitMask; |= latch[p] & ~BitMask`.

**zdos per-plane formula:**
```
src = ((v >> p) & 1) != 0 ? 0xFF : 0x00
res = alu(src, latch[p])
out = (res & bitMask) | (latch[p] & ~bitMask)
vram[p*0x10000 + off] = out      // for each masked plane
```

### 2.4 Write Mode 3 — Bit-Mask from rotated CPU data, color from Set/Reset

Set/Reset is used **as if Enable-Set/Reset were 1111b** (so each plane's source is `setReset[p] ?
0xFF : 0x00`). The host byte is rotated, then ANDed with the Bit-Mask register to form the
*effective* bit-mask; that effective mask then selects expansion-of-Set/Reset vs latch. ALU/Function
Select and the Enable-Set/Reset register are **ignored**.

- dosbox `ModeOperation` case 3 (`vga_memory.cpp:83-86`): `val = ror(val, data_rotate); full =
  RasterOp(full_set_reset, ExpandTable[val] & full_bit_mask)` — i.e. the *mask* argument to RasterOp
  is `ExpandTable[rotated_val] & bit_mask`, and the *input* is the Set/Reset expansion.
- spice86 `HandleWriteMode3` (`VideoMemory.cs:168-184`): `value.Ror(rotate)`; `bitMask = value &
  BitMask`; per plane: `temp = setReset[p] ? 0xFF : 0x00`; `temp &= bitMask; temp |= latch[p] &
  ~bitMask`.

**zdos per-plane formula:**
```
rotated   = ror(v, dataRotate)
eff_mask  = rotated & bitMask
src       = setReset[p] ? 0xFF : 0x00          // Enable-Set/Reset forced on
out       = (src & eff_mask) | (latch[p] & ~eff_mask)
vram[p*0x10000 + off] = out                    // for each masked plane
```
*(Note: dosbox routes WM3's source through `RasterOp` with `raster_op` still applied; spice86 does a
plain Bit-Mask merge with no ALU. Per the hardware spec — and the GraphicsModeRegister.cs WM3 doc,
`GraphicsModeRegister.cs:17-20` — "the SR and Function Select fields are ignored in Write mode 3",
so the spice86 plain-merge form is the faithful one and the one zdos adopts. Either reduces
identically when ALU=replace, which is the common case.)*

### 2.5 The shared ALU (`aluop` / `RasterOp` / `ApplyAluFunction`)

GC index 3 bits 4:3 select the logical op combining the freshly-computed data with the **latch**:

| code | op       | per-plane result (over 8 bits) |
|------|----------|--------------------------------|
| 00   | replace  | `data`                         |
| 01   | AND      | `data & latch[p]`              |
| 10   | OR       | `data \| latch[p]`             |
| 11   | XOR      | `data ^ latch[p]`              |

dosbox folds the ALU **and** the Bit-Mask merge into one `RasterOp(input, mask)` where `mask =
full_bit_mask` and the latch is `vga.latch.d` (`vga_memory.cpp:51-63`): e.g. op 00 returns `(input &
mask) | (latch & ~mask)` — that IS "ALU=replace then Bit-Mask merge". spice86 keeps them separate
(`ApplyAluFunction` then `&= BitMask; |= latch & ~BitMask`, `VideoMemory.cs:244-267`), which is
clearer. **zdos copies spice86's separation:** `alu(src, latch[p])` then a distinct Bit-Mask merge,
because per-plane `u8` arithmetic is trivial and the two-step form maps 1:1 to the hardware prose.

### 2.6 Performance — decode-on-write `WriteConfig` + a trivial-config bulk fast path (review perf F2/F4)

The §2 pipeline as written re-reads and re-decodes ~7 GC/SEQ register fields **on every single byte**
written to VRAM. In a planar blit (`rep stosb` across a scanline) that is the hot path. Two fixes,
both pure (no host clock, no determinism impact — they only *cache decoded guest state*):

- **F4 — decode the hot write-mode registers into a packed `WriteConfig` on the rare register write,
  not on every VRAM byte.** The GC/SEQ registers change ~once per blit setup; the VRAM bytes change
  millions of times. On each `out` to a GC/SEQ data port, recompute a small POD:
  ```zig
  const WriteConfig = struct {
      write_mode: u2, data_rotate: u3, alu: u2, bit_mask: u8,
      set_reset: u4, enable_set_reset: u4, map_mask: u4,
      trivial: bool,   // see F2
  };
  ```
  `memWrite8` then reads `self.wc.*` fields directly — no per-byte register decode. (This is *not* a
  renderer cache like dosbox's `Expand16Table`; it is the decoded form of live guest registers,
  recomputed deterministically on the register write that changes them, and it needs no snapshot
  coverage because it is a pure function of the snapshot-covered raw registers — recompute it in
  `restore()`.)
- **F2 — a trivial-config bulk-write fast path.** The overwhelmingly common Mode-X fan-out is
  `dataRotate==0 && enableSetReset==0 && alu==replace && bitMask==0xFF` — for which the entire §2.1
  pipeline reduces to `out = v` per masked plane. Precompute `trivial` once (in the `WriteConfig`
  decode) and, when set, the write is just: for each plane `p` in `map_mask`, `vram[p*0x10000 + off] = v`.
  This skips the ror / set-reset select / ALU / bit-mask-merge entirely. With the plane-major layout
  (§1.2) the single-plane trivial case is also contiguous (the §1.2 "inverse 4× win"), so a
  trivial-config single-plane strip is the best case on both counts. The non-trivial path runs the
  full §2 pipeline unchanged (correctness first; the fast path is a pure shortcut that must produce
  byte-identical results — assert it in a test by running both paths on a fuzzed config and comparing).

Both are **transparent optimizations**: identical observable VRAM, identical cycles (the bus handler
adds zero cycles either way, §6.3), identical snapshot. They make the planar hot path fast without
touching the determinism boundary.

---

## 3. Read modes 0 and 1 — and the latch-load on every read

**Every** CPU read of the VGA window first loads all 4 plane latches from the addressed offset (real
hardware: a read always latches the 4 planes; that is what makes write mode 1 / Bit-Mask work).
dosbox: `vga.latch.d = ((uint32_t*)vga.mem.linear)[start]` then dispatch on `read_mode`
(`vga_memory.cpp:131-139`). spice86: load `_latches[0..3]` then dispatch on `ReadMode`
(`VideoMemory.cs:46-89`).

### 3.1 Read Mode 0 — return the Read-Map-Selected plane

Return the byte of the plane named by **Read Map Select** (GC index 4 bits 1:0). The other 3 latches
are still loaded (for a following write).

- dosbox case 0: `return vga.latch.b[vga.config.read_map_select]` (`vga_memory.cpp:133-134`).
- spice86 `ReadMode0`: `result = _latches[plane]` where `plane = ReadMapSelectRegister.PlaneSelect`
  (`VideoMemory.cs:54-57,303`).

**zdos:** `return latch[readMapSelect()]`.

### 3.2 Read Mode 1 — color compare across planes, gated by Color Don't Care

Returns 8 bits, one per horizontal pixel: bit i is set iff the 4-bit pixel formed from bit i of the
4 latches **matches Color Compare** (GC index 2), considering only the planes selected by **Color
Don't Care** (GC index 7 — a 0 bit forces that plane's comparison to match).

- dosbox case 1 (`vga_memory.cpp:135-138`): `templatch.d = (latch.d & FillTable[color_dont_care]) ^
  FillTable[color_compare & color_dont_care]; return ~(b0|b1|b2|b3)`. (A plane outside Don't-Care
  contributes 0 to the XOR ⇒ always "matches"; the final `~OR` makes a matching pixel a 1.)
- spice86 `ReadMode1` (`VideoMemory.cs:59-86`): per pixel i (0..7) build the 4-bit pixel from
  `(latch[j] >> i) & 1`; if `(pixel | ~colorDontCare) == (colorCompare | ~colorDontCare)` set bit i.

**zdos:** the spice86 per-bit loop (clearest); 8 iterations, 4 planes each — pure integer. Formula:
```
dontCare = colorDontCare() & 0x0F          // GC idx 7
compare  = colorCompare()  & 0x0F          // GC idx 2
result   = 0
for i in 0..8:
    pixel = 0
    for p in 0..4: pixel |= ((latch[p] >> i) & 1) << p
    if (pixel & dontCare) == (compare & dontCare): result |= 1 << i
return result
```

---

## 4. All addressing / memory modes — CPU address → plane(s) + offset

This is the crux. The **same** write/read-mode arithmetic (§2/§3) runs in every mode; what changes
is **how a CPU physical address decodes to (plane set, plane offset)** and which **window** it lives
in (§5). The decode is driven by Sequencer Memory Mode (chain-4 bit 3, odd/even bit 2, extended-mem
bit 1) + GC Misc (odd/even bit 1, memory-map bits 3:2). Both refs centralize this:
spice86 `DecodeWriteAddress`/`DecodeReadAddress` (`VideoMemory.cs:279-340`); dosbox via the
handler-swap (`VGA_SetupHandlers`, `vga_memory.cpp:963-1109`) — a different handler class per mode.

Let `off = phys - window_base` (window_base from §5; A0000 for the BaK target). The five decodes:

### 4.1 Chained 256-color (mode 13h)

**Condition:** Sequencer Memory Mode chain-4 bit set (`seq[4] & 0x08`). The 2 low address bits select
the plane; the rest is the per-plane offset.
- spice86: `plane = off & 3; off &= ~3` (write: `planes = 1 << (off&3)`)
  (`VideoMemory.cs:283-286,313-317`).
- dosbox `VGA_ChainedVGA_Handler::ToLinear`: `&linear[((addr & ~3) << 2) + (addr & 3)]`
  (`vga_memory.cpp:352-355`) — the interleaved-storage equivalent.

**zdos mapping (plane-major):** plane = `off & 3`, plane-offset = `off >> 2`, address
`vram[(off&3)*0x10000 + (off>>2)]`. One CPU byte = one pixel = one palette index. **In practice zdos
keeps mode 13h on the RAM-like fast path entirely** (§6): `getHostPtr` returns `&vram[off]` and the
chain-4 decode is implicit in how mode 13h was set up — the fast path is byte-for-byte the current
behavior and is *not* re-routed through this decode. The decode above is the faithful model for any
non-fast-path chained access (debugger, 16-bit straddle), and confirms the fast path is equivalent.

### 4.2 Unchained planar (Mode X / Mode Y)

**Condition:** chain-4 clear AND odd/even clear (planar). **The Map-Mask alone selects the written
planes; Read-Map selects the read plane; the offset is the CPU offset with NO division.**
- spice86 write: `planes = 0b1111` (all four enabled; the Map-Mask AND in the write loop does the
  real gating); `offset = off` (`VideoMemory.cs:334-337`). Read: `plane = ReadMapSelect`
  (`:302-304`).
- dosbox: `VGA_UnchainedVGA_Handler` — `CHECKED2(addr)` (the offset is used directly as the planar
  index, /4 of the linear space), `pixels &= full_not_map_mask; pixels |= data & full_map_mask`
  (`vga_memory.cpp:504-515`).

**zdos mapping:** offset = `off` (no `>>2`); writes fan out to `vram[p*0x10000 + off]` for each plane
p where `mapMask() & (1<<p)`; reads return `vram[readMapSelect()*0x10000 + off]` (after latch load).
This pins the Mode-Y stride: width/4 = 320/4 = 80 bytes per row, pixel (x,y) → plane `x&3`, offset
`y*80 + x/4` (matches the BaK asm stride `0x50`, `mode-y-vga.md §2.1`, and the §7 de-interleave).

### 4.3 Odd/even (text + CGA-compat planar, the chain-2 mapping)

**Condition:** Sequencer odd/even-mode bit set (= `!(seq[4] & 0x04)`) [and GC Misc odd/even bit 1
set]. Even CPU addresses → plane pair {0,2}; odd → {1,3}. This is how alphanumeric text stores
char/attribute (plane 0 = character codes, plane 1 = attributes) and how CGA-compat 4-color graphics
work.
- spice86 read: `plane = off & 1`; write: `planes = (off&1)==0 ? 0b0101 : 0b1010`
  (`VideoMemory.cs:288-300,319-331`). Then an offset-fixup that depends on `ChainOddMapsToEven`
  (GC Misc bit 1), `EvenPageSelect` (Misc Output), and Extended-Memory (Seq bit 1):
  `ChainOddMapsToEven` ⇒ replace CPU addr bit 0 with a high-order bit; else `EvenPageSelect` ⇒
  `off &= 0xFFFE`; else `off |= 1`.
- dosbox: in M_TEXT it swaps to `vgaph.map` when GC Misc bit 1 is set (`vga_memory.cpp:1058-1061`),
  and `VGA_TEXT_PageHandler` does the explicit char/attr/font split via `vga.seq.map_mask`
  (`vga_memory.cpp:556-595`): map_mask 0x1 → char index plane, 0x2 → attribute plane, 0x4 → font map.

**zdos mapping:** read plane = `off & 1`; write plane set = `(off&1)==0 ? 0b0101 : 0b1010` (planes
{0,2} for even, {1,3} for odd), gated further by the Map-Mask. **Plane-offset is a bit-0 mask/OR
fixup of `off`, NOT `off >> 1`** [FIX S4]: the address bit that selected the plane pair is *not*
shifted out — it is rewritten. The three cases (spice86 `VideoMemory.cs:319-331`): chain-odd-maps-to-even
(GC-Misc bit 1) ⇒ replace `off` bit 0 with a high-order page bit; else EvenPageSelect (Misc-Output
bit 5) ⇒ `off &= 0xFFFE` (clear bit 0); else ⇒ `off |= 1`. The standard text/CGA even-page case is
**`off & 0xFFFE`** (plane-offset = the address with bit 0 cleared) — *not* a halving. (The earlier
draft's `off >> 1` was wrong: it would compress the plane address by 2× and misplace every odd cell.)
These fixups are implemented only when a guest drives odd/even planar mode — §9 flag. **zdos's existing B8000/B0000 text pages are a *flat interleaved {char,attr}* slab**
(`vga.zig:68-78`, D-TM1) — guest-observationally identical to odd/even for the chained text mapping
BaK/oracle uses; the odd/even *planar* decode here is the faithful model for a guest that reprograms
the text planes (e.g. font upload to plane 2 via map_mask 0x4) and is **not on the BaK path** — flag
if driven.

### 4.4 Doubleword addressing

**Condition:** CRTC mode-control (idx 0x17) bit 6 = 0 (DW mode) — the complement of "byte mode". In
DW mode the two **low** address bits are ignored for the offset and instead the CRTC address
counter's high bits wrap differently; for **CPU memory access** the practical effect with chain-4 is
already captured by §4.1 (the `& ~3` offset). Doubleword vs byte vs word addressing is primarily a
**display address-counter** concern (how the CRTC scans VRAM out — §7's start-address walk), not a
distinct CPU-access decode beyond chain-4's `off>>2`.
- dosbox does not model a separate DW CPU-access handler; the CRTC mode bits 5–6 (word/byte/dword)
  affect `vga.draw` address generation (in `vga_draw.cpp`/`vga_crtc.cpp`), not `vga_memory.cpp`.
- spice86 likewise: `DecodeWriteAddress`/`DecodeReadAddress` have no doubleword branch — chain-4
  covers the CPU side.

**zdos:** doubleword is **not a separate CPU-access mode**; the chain-4 `off>>2` (§4.1) is its CPU
manifestation. The DW/byte/word CRTC bits affect the *render's* address walk (the framebuffer
de-interleave, §7) and the start-address scaling — owned by the capture spec. Model the CRTC bits as
stored register state (round-trip); apply them in the render, not in this engine. **Flag** if a
guest's CPU-access pattern appears to depend on DW addressing independent of chain-4 (none expected
for the BaK target, which is plain chain-4-off Mode-Y + chain-4-on mode 13h).

### 4.5 EGA 16-color planar (modes 0Dh/0Eh/10h/12h)

**Condition:** chain-4 clear, odd/even clear, GC Misc 256-color bit (GC idx 5 bit 6) clear — i.e.
*the same unchained planar decode as §4.2*, but the renderer treats a pixel as 4 bits (one bit per
plane at the same bit position) rather than as an 8-bit chain-4 index. **For the memory engine the
EGA 16-color path is byte-identical to §4.2 unchained planar**: writes fan out to the Map-Masked
planes at `vram[p*0x10000 + off]` (no `>>2`); reads load 4 latches and return the Read-Map plane
(read mode 0) or color-compare (read mode 1). The *only* difference from Mode-X is downstream (the
render packs 4 planes' bits into a 4-bit index instead of de-interleaving an 8-bit chain-4 index).
- dosbox: `VGA_UnchainedEGA_Handler` (`vga_memory.cpp:277-344`) — identical write arithmetic to
  `VGA_UnchainedVGA_Handler`, differing only in the `fastmem` pixel-cache expansion (a renderer
  concern zdos does not copy, §3-avoid). The shared base is `VGA_UnchainedRead_Handler`
  (`vga_memory.cpp:127-174`) — same read modes 0/1 as VGA.
- spice86: there is **no separate EGA path** — the same `VideoMemory.Write/Read` + the planar branch
  of the decode handle both; the bit-depth interpretation is the renderer's.

**zdos:** **one** planar engine serves both Mode-X 256-color *and* EGA 16-color (they share §4.2's
decode and §2/§3's arithmetic). The 16-color-vs-256-color distinction is the GC-Misc 256-color bit,
consumed by the *render*, not by the memory engine. This is why zdos needs only **one** unchained
planar read/write path, not two — a simplification over dosbox's two handler classes, faithful
because their memory arithmetic is identical.

### 4.6 Decode summary table

| Mode | Condition (Seq MemMode / GC) | Write plane set | Read plane | Plane offset |
|------|------------------------------|-----------------|------------|--------------|
| Chained 256 (13h) | chain-4 set (`seq4 b3=1`) | `1 << (off&3)` | `off&3` | `off>>2` |
| Unchained planar (Mode-X) | chain-4 clr, odd/even clr | `0b1111` & MapMask | ReadMapSel | `off` |
| EGA 16-color planar | chain-4 clr, odd/even clr, 256 bit clr | `0b1111` & MapMask | ReadMapSel | `off` |
| Odd/even (text/CGA) | odd/even-mode set (`seq4 b2=0`) | even→{0,2} odd→{1,3}, & MapMask | `off&1` | `off&0xFFFE` (bit-0 fixup, §4.3 — NOT `off>>1`) |
| Doubleword | (CRTC 0x17 b6=0) | — same as chain-4 for CPU access — | — | `off>>2` |

In all rows the final write is still gated by the **Map Mask** (§2 stage 5) and the read still
**loads all 4 latches** before returning (§3). The "Write plane set" column is the addressing-mode
plane enable; it is ANDed with the Map Mask (spice86: `planeEnable[p] && writePlane[p]`,
`VideoMemory.cs:172,194,211,226`).

---

## 5. The memory-map window (GC Misc bits 3:2) — which guest window the VGA claims

GC Misc register (GC index 6) bits 3:2 select the physical window the VGA decodes (the
`window_base`/length used as `off = phys - window_base` in §4):

| bits 3:2 | window      | length | typical use |
|----------|-------------|--------|-------------|
| 0 (00)   | A0000       | 128 KiB (A0000–BFFFF) | EGA/VGA graphics full window |
| 1 (01)   | A0000       | 64 KiB  (A0000–AFFFF) | VGA graphics (mode 13h / Mode-X) |
| 2 (10)   | B0000       | 32 KiB  (B0000–B7FFF) | monochrome text (mode 7) |
| 3 (11)   | B8000       | 32 KiB  (B8000–BFFFF) | color text (modes 0–3) / CGA gfx |

- spice86 `MiscellaneousGraphicsRegister.BaseAddress`/`MemorySize` (`MiscellaneousGraphicsRegister.cs:35-60`)
  — the exact table above; `IsOutsideCurrentlyMappedRange` (`VideoMemory.cs:94-98`) drops accesses
  outside the claimed window.
- dosbox `VGA_SetupHandlers` `switch ((vga.gfx.miscellaneous >> 2) & 3)` (`vga_memory.cpp:1068-1103`):
  case 0 → A0000 32 pages (128K), case 1 → A0000 16 pages (64K) + B0000 empty, case 2 → B0000 8
  pages, case 3 → B8000 8 pages — same mapping, expressed as page-handler installs.

**zdos integration:** zdos's bus claims A0000 (64 KiB, `VRAM_WINDOW_LEN`) for graphics and B8000 /
B0000 (32 KiB each) for the text pages at `wire()` time, statically (the BaK target is window-mode 1
for graphics + the standard text windows). The GC-Misc window-select bits are **stored register
state** the engine reads to compute `window_base` for an access; for the BaK v1 target the value is
1 (A0000+64K) for Mode-Y/13h and the text windows are separately mapped. zdos does **not** dynamically
re-`mapMmio` on a GC-Misc change (unlike dosbox's `VGA_SetupHandlers` re-install) — it keeps all the
graphics+text windows mapped and lets the engine's decode pick the right plane/offset per access. A
GC-Misc value that would *move* the graphics window (0/2/3) on the BaK path is a §9 flag: store it,
and if a guest actually relocates the graphics window, assert/extend rather than silently misroute.
*(This matches `bus.zig`'s static page-kind model: a window is mapped once; the device decode, not a
re-map, distinguishes modes — cleaner than dosbox's TLB-clearing handler swap.)*

---

## 6. Bus dispatch — chained fast path vs planar slow path; getHostPtr/read8/write8 contract

The bus `.mmio` path tries `h.hostPtr(page)` first; non-null ⇒ RAM-like fast path
(`bus.zig:283,305-308`); null ⇒ the per-access `read8`/`write8`/`peek8` handler path
(`bus.zig:284,309`; `peekPhys8` at `:664-671`). So the entire chained-vs-planar dispatch is **one
decision inside the VGA's `memGetHostPtr`** — no bus change, no handler-ID churn on a mode toggle:

```zig
fn memGetHostPtr(self, page) ?[*]u8 {
    if (!self.chained()) return null;          // unchained/planar → planar read8/write8 slow path
    ... existing return &vram[off];            // chained mode 13h → unchanged RAM-like fast path
}
```

- `chained()` = `(seq[4] & 0x08) != 0` (chain-4). Mirrors dosbox `vga.config.chained`
  (`vga_seq.cpp` / `vga_memory.cpp:1039`).
- **Chained (mode 13h, the default):** `getHostPtr` returns the direct pointer; the fast path is
  100% unchanged (zero overhead, zero regression to existing mode-13h tests). Plane 0's first 64 KiB
  of the plane-major slab *is* the existing linear `vram[0..64000]`.
- **Unchained (Mode-X / EGA planar):** `getHostPtr` returns null ⇒ every A000 byte access goes
  through the planar `memWrite8`/`memRead8` (the §2 fan-out / §3 read). Slow per-access path,
  acceptable because it is taken only in planar modes (the perf-sensitive linear case keeps the fast
  path). The bus already supports a handler returning null hostPtr (`bus.zig:283-284,305-309`).

This is cleaner than dosbox's `VGA_SetupHandlers()` page-handler swap: zdos keeps **one** MemHandler
and decides per-access via `getHostPtr` — no re-`mapMmio` on a chain-4 toggle, so **no snapshot/replay
handler-ID churn** (the bus snapshots `page_handler_id`, `bus.zig:923`; a stable single handler keeps
it constant across a mode switch).

### 6.1 The handler methods (the `MemHandler` contract, `vga.zig:273-281`)

- **`memWrite8(phys, v)`**: `off = phys - window_base`; decode addressing mode (§4) → plane set +
  offset; run the write mode (§2) per masked plane. (Reached only when unchained, since chained uses
  the host pointer.)
- **`memRead8(phys) u8`**: `off = phys - window_base`; **load all 4 latches** from
  `vram[p*0x10000 + plane_offset]`; return per read mode (§3). The latch load is the documented side
  effect — so `read8` is **not** pure-peekable.
- **`memPeek8(phys) ?u8`** (debugger path, `bus.zig:664-671`): mirror the *read* decode (chained →
  `vram[off]`; unchained → `vram[readMapSelect()*0x10000 + off]`) but **must NOT load the latches**
  (a peek mutates nothing — CLAUDE #5/#6, the determinism prime directive; the bus peek path is
  contractually side-effect-free, `bus.zig:631-640`). The §7 capture render de-interleaves all 4
  planes directly from the slab, bypassing Read-Map entirely — even simpler.
- **`memGetHostPtr(page) ?[*]u8`**: §6 (chained → pointer, unchained → null).

### 6.2 Wide accesses (16/32-bit)

The bus decomposes a non-fast-path wide MMIO access via the handler's native `read16/read32` /
`write16/write32` (`bus.zig:382-392,416-428`) or, when crossing regions, per-byte ascending
(`readWideSlow`/`writeWideSlow`, `bus.zig:454-475`). For the VGA planar handler, a 16/32-bit access
must be **the byte sequence applied in ascending address order** — exactly as dosbox does
(`writeHandler(addr+0,...); writeHandler(addr+1,...)`, `vga_memory.cpp:528-553`) — because each byte
re-runs the full write-mode pipeline (the latch is reloaded per read, the bit-mask applies per byte).
zdos should implement the VGA handler's `write16/write32`/`read16/read32` as a loop over `write8`/
`read8` (do **not** widen the pipeline to 16/32 bits), matching both refs' per-byte handlers.

### 6.3 Cycle cost — no ledger hole

Unchained writes/reads take the device handler path (no hostPtr) but are still charged by the **CPU's
own `mov`/`movsb`/`stosb` instruction cost** — the bus handler adds zero cycles, identical to the
existing A000 fast path (`vga.zig:45-50`). The dispatch (fast path vs handler) is **invisible to the
cycle ledger**: same instruction cost either way. No host-serviced trap, no synthetic cost, **no
hole** (CLAUDE #1). **Do NOT import dosbox's `read_delay`/`write_delay`** (`vga_memory.cpp:107-125`)
— that subtracts host `CPU_Cycles` for a VRAM-access timing model; it is exactly the host-cycle hack
zdos exists to avoid (and it would make VRAM access non-deterministic w.r.t. the host cycle budget).

---

## 7. The framebuffer de-interleave (the read-side inverse; capture contract)

The framebuffer-capture render (a separate spec) must agree with the write mapping. Define the
inverse here so both sides match (Mode-Y 320×200, stride 80 = width/4):

```
pixel (x, y) →  plane  = x & 3
                offset = startAddress() + y*80 + (x >> 2)
                index  = vram[plane*0x10000 + offset]      // plane-major slab (§1.2)
                rgb    = dac_rgb[index]  (6→8 bit, convention owned by the capture spec)
```

`startAddress()` = `(crtc[0x0C] << 8) | crtc[0x0D]` — the displayed page base. For LAMUT's static
front-page hold the start address is 0; the render reads the **live** start address so a page flip is
captured. This is the exact inverse of §4.2's write decode. For EGA 16-color the de-interleave packs
one bit per plane into a 4-bit index instead of reading an 8-bit byte; the plane/offset arithmetic is
the same. The render reads the 4 planes **directly from the slab** (it does not go through
`memRead8`/Read-Map and never loads the latches), so capture is a pure peek.

---

## 8. Determinism & snapshot

**All of the memory engine is a pure function of guest state.** The four register files (consumed
here, owned by the register-file spec), the 4 plane latches, the start address, and the 256 KiB
planar VRAM are all written by guest `OUT`/`MOV` instructions; the planar read/write is a **pure
function of (register state, latches, VRAM, address, value)** — no host clock, no float, no RNG (the
bus handler-purity contract, `bus.zig:26-30`). Confirmed: **nothing in the memory path is host-timed.**

The one host-timed thing in dosbox's memory file — `read_delay`/`write_delay` (`vga_memory.cpp:107-125`)
— is explicitly **not** adopted (§6.3). spice86's `HasChanged`/`Volatile`/`Interlocked`
(`VideoMemory.cs:18-19,161-167,275`) is a renderer dirty-flag for its threaded UI — **not** adopted
(it would violate the single-threaded-emulation / no-host-thread-feedback determinism rule, CLAUDE
#4); zdos's capture is a pure peek at a fixed cycle and needs no dirty tracking. dosbox's
`fastmem`/`Expand16Table` pixel cache (`vga_memory.cpp:187-204,287-304`) is a renderer accel
structure — **not** adopted (zdos renders on demand from the planes, §7).

**Snapshot coverage:** add the 4 latches (`latch: [4]u8`) to `Vga.Snapshot` (`vga.zig:549-559`) +
`snapshot`/`restore` (`:561-584`); the register files (`seq`/`gfx`/`crtc`/`attr`) are added by the
register-file spec. The 256 KiB VRAM slab is already caller-copied out-of-band like the text page
(`vga.zig:148-159` doc; the planes live in the same slab, no reshape) — **no change to the VRAM
caller-copy contract**. All POD, round-trips byte-identical. Reset (`vga.zig:231`) zeroes the latches
and defaults chain-4 set (chained/mode-13h-compatible power-on) so the fast path is the boot default
and existing tests are undisturbed.

---

## 9. dosbox vs spice86 — copy / avoid, and the recommended zdos design

| Concern | dosbox-staging | spice86 | zdos decision |
|---------|----------------|---------|---------------|
| VRAM layout | interleaved `linear[off*4+p]` (`vga_memory.cpp:131,283`) | interleaved `VRam[off*4+p]` (`VideoMemory.cs:47,270`) | **plane-major `vram[p*0x10000+off]`** (§1.2) — reuses slab, mode-13h plane 0 == linear, trivial de-interleave |
| Latches | `vga.latch.d` 32-bit union (`:131`) | `_latches[4]` (`:31,46-51`) | `latch: [4]u8`, loaded on every read (§1.3, §3) |
| Write modes | compact `ModeOperation` switch (`:65-93`) — **the reference formulas** | explicit `HandleWriteMode0..3` (`:168-242`) — **the clearest** | spice86 per-plane shape, cross-checked vs dosbox arithmetic (§2) |
| ALU + Bit-Mask | folded into `RasterOp` (`:51-63`) | separate `ApplyAluFunction` + merge (`:244-267`) | **separate** (spice86) — maps 1:1 to hardware prose (§2.5) |
| Read modes | `read_map` + color-compare (`:131-138`) | `ReadMode0/1` (`:53-89`) | spice86 per-bit color-compare loop (§3) |
| Address decode | handler-class swap (`VGA_SetupHandlers`, `:963-1109`) | `Decode{Read,Write}Address` (`:279-340`) | **spice86's centralized decode** (§4) — chain-4/planar/odd-even in one place |
| EGA vs VGA planar | two handler classes (uega/uvga) | one `VideoMemory` path | **one** planar engine (§4.5) — memory arithmetic is identical |
| Dispatch | re-`MEM_SetPageHandler` + `PAGING_ClearTLB` on mode change (`:1108`) | per-access decode | **per-access `getHostPtr` returns null when unchained** (§6) — one handler, no handler-ID churn |
| Window select | re-map per GC-Misc (`:1068-1103`) | `BaseAddress`/`MemorySize` lookup (`MiscGfx.cs:43-60`) | **stored field, static windows, decode picks offset** (§5) |
| VRAM access delay | `read_delay`/`write_delay` (`:107-125`) | none | **avoid** — host-cycle hack, breaks the ledger (§6.3, CLAUDE #1/#2) |
| Pixel cache | `fastmem`/`Expand16Table` (`:187-204,287-304`) | none | **avoid** — renderer accel, not needed (§7, §8) |
| Dirty flag | `MEM_CHANGED` (`:41-44`) | `HasChanged`/`Volatile` (`:18,161-167`) | **avoid** — threaded-UI concern, capture is a pure peek (§8) |

### Recommended zdos shape (Zig)

- **Storage:** the existing `vram: []u8` slab, addressed plane-major (§1.2); `latch: [4]u8`.
- **Accessors** (decoding register fields at use sites, flat — no typed wrapper structs, matching
  the existing flat-field DAC model and CLAUDE "underengineer"): `chained()`, `mapMask() u4`,
  `writeMode() u2`, `readMode() u1`, `readMapSelect() u2`, `bitMask() u8`, `setReset() u4`,
  `enableSetReset() u4`, `dataRotate() u3`, `aluOp() u2`, `colorCompare()`, `colorDontCare()`,
  `startAddress() u16`, `gcMiscWindow()`.
- **One decode fn** `decode(off) -> {plane_set: u4, read_plane: u2, plane_off: u32}` covering all of
  §4 (a `switch` on chain-4 / odd-even / planar), consumed by both `memRead8` and `memWrite8`.
- **One write fn** `applyWrite(p, off, v)` running §2's pipeline for plane p; the write loop iterates
  the 4 planes, gating on `plane_set & mapMask & (1<<p)`.
- **One read fn** `memRead8` loading 4 latches then dispatching §3.
- **Dispatch:** `memGetHostPtr` returns the pointer iff `chained()`, else null (§6).
- **Peek:** `memPeek8` mirrors the read decode without loading latches (§6.1).
- **Wide:** `read16/32`/`write16/32` loop over the byte path (§6.2).

### Deferred-with-a-LOUD-flag (faithful, probe-driven — never silent)

The BaK/LAMUT path uses **write modes 0 + 1** and **read mode 0** with the unchained planar decode
(`mode-y-vga.md §2.5, §6`). This spec models **all four write modes, both read modes, and all five
addressing decodes** as the complete hardware truth. For a v1 *implementation* that wants to stage
the work, the parts not on the BaK path may be `std.debug.assert(false)` with a naming message
(mirroring the existing `0x3C0` discipline `vga.zig:531` and the PIT BCD assert `pit.zig:260`) until
a probe trips them — but **the formula is specified here for each**, so implementing a flagged mode
is transcription, not design. Specifically flag-if-driven (not on the BaK path): write modes 2/3,
read mode 1 (color compare), the odd/even planar text decode (§4.3 fixups), the doubleword CRTC
interaction (§4.4), and a GC-Misc window relocation off A0000+64K (§5). **Never** a silent drop or a
silent wrong result — that is the exact failure mode (faked DOS) this project exists to escape.
