# Mode-Y / unchained planar VGA (the LAMUT headline subsystem)

Status: **design plan** (implementation-ready; **no source changed by this document**). This is work
item **W2** of `plans/lamut-milestone.md` (the headline new VGA subsystem) and the largest *code* item
in the LAMUT milestone. It fills the ROADMAP backlog "Mode-Y / unchained planar VGA"
(`plans/ROADMAP.md:30`).

> Scope discipline (CLAUDE ground rule "not a toy — no shortcuts, no fakes"): the LAMUT overlay
> (`Vmcode.ovl`) and the engine's own VGA helpers run as **real guest code** doing **real port I/O +
> real planar VRAM writes**. zdos models the *hardware behaviour* (register storage + planar VRAM
> semantics), NOT a reimplementation of the driver. Any write/read mode or register the overlay needs
> that zdos has not modeled must be a **LOUD flag** (assert / explicit "not implemented"), never a
> silent wrong result — replacing the current `else => {}` silent-drop and the `assert(false)` 0x3C0
> trap with real storage + faithful semantics.

Owner module: `src/devices/vga.zig` (the register files + the planar VRAM engine), plus one dispatch
line in `src/machine/machine.zig` (port registration) and the `Vga.Snapshot` extension. The
framebuffer-capture render (`/api/framebuffer`, W5/P6) is a *separate* plan — this document only
defines the **de-interleave model** that capture must agree with (§5).

---

## 1. Problem statement — what zdos models today and the exact gap

zdos models a **linear (chained) mode-13h** VGA only (`src/devices/vga.zig` header `:8-28`):

- **A0000 linear framebuffer** (`VRAM_PHYS=0xA0000`, `VRAM_WINDOW_LEN=0x10000`, `vga.zig:60-62`),
  mapped **RAM-like** via `mapMmio` with a `getHostPtr` fast path (`memGetHostPtr`, `vga.zig:288-293`).
  A guest `mov [es:di],al` to A000 lands straight in `vram[offset]` through the bus host-pointer fast
  path (`bus.zig:305-308`) — **bypassing any plane gate**. This is exactly mode 13h (one CPU byte =
  one pixel = one palette index), and it must keep working unchanged.
- **256 KiB VRAM slab** (`VRAM_SIZE=0x40000`, `vga.zig:63-66`) — 4 × 64 KiB — already reserved "so a
  faithful future planar mode has real storage (no fake)". The planar engine fills this reservation.
- The **6-bit DAC** (ports 0x3C6-0x3C9, `write3c9:411`/`read3c9:436`), **misc-output** (0x3C2/0x3CC,
  `portOut8:519`/`portIn8:507`), and the cycle-derived **0x3DA/0x3BA status** + attribute flip-flop
  field (`statusReg1:476`, `attr_flip_flop_is_index:207`) all exist.

**The gap — the planar register files and VRAM engine are absent:**

| Surface | State today | file:line |
| --- | --- | --- |
| Sequencer 0x3C4/0x3C5 (incl. **Map Mask** idx 2, **Memory Mode**/chain-4 idx 4) | **silently dropped** (`portOut8` `else => {}`) / read `0xFF` | `vga.zig:532`, `:513` |
| Graphics Controller 0x3CE/0x3CF (**Mode** idx 5, **Read Map** idx 4, **Bit Mask** idx 8, Set/Reset 0/1, Data Rotate 3, Misc 6) | **silently dropped** / read `0xFF`; engine **reads these back** (`f_1ca27.asm:102` `IN AL,DX`) so a drop is wrong | `vga.zig:532`, `:513` |
| CRTC 0x3D4/0x3D5 (start-address 0x0C/0x0D, unchain bits 0x14 b6 / 0x17 b6) | no device CRTC file (only the BDA stores 0x3D4 in `int10.zig`) | — |
| Attribute Controller 0x3C0 | **`assert(false)`** if driven — a LOUD flag, but the overlay's mode-set may drive it | `vga.zig:531` |
| Unchained 4-plane VRAM | slab exists but A000 is RAM-like fast-path only — no Map-Mask fan-out | `vga.zig:288-293`; `machine.zig` maps A000 RAM-like |

The A0000 window can no longer always use the `getHostPtr` fast path: **unchained writes must dispatch
through a planar handler** that consults the Map-Mask. The bus already supports this cleanly (§4.1).

---

## 2. What LAMUT actually pokes/reads — the minimum faithful subset (cited from the c-recon asm)

The LAMUT image-blit path is **vtable slot 29 `blit_sprite_indirect`** inside `Vmcode.ovl`
(`plans/lamut-milestone.md:88`). The overlay is a binary, but the engine's **own** VGA helpers
(migrated to asm under `betrayal-at-krondor/c-recon/staging/src/asm/`) are 1:1 transcriptions of the
real game's planar idiom and are the authoritative spec for what the VGA device must model. The
register set + write modes they use *is* the minimum faithful subset.

### 2.1 The Sequencer Map-Mask is the plane gate (the core idiom)

`f_204ce.asm` (`vgaplanar_clear_column_strip`, "Mode-X video RAM") is the textbook Mode-X plane fan-out
(`f_204ce.asm:62-104`):

```asm
mov dx,3c4h
mov ax,0e02h   ; SC idx 2 (Map Mask) = 0x0E -> planes 1+2+3 only
out dx,ax      ; word OUT: AL=index 0x02, AH=data 0x0E
... stosb ...  ; CPU byte fans out to the masked planes (write mode 0)
mov ax,0f02h   ; Map Mask = 0x0F -> all 4 planes
out dx,ax
... rep stosw ...
mov ax,0702h   ; Map Mask = 0x07 -> planes 0+1+2
out dx,ax
... stosb ...
```

- **SC index 2 = Map Mask**, written as a **16-bit OUT to 0x3C4** (`AL`=index, `AH`=data — the
  index+data-in-one-word idiom). zdos must handle a `out16(0x3C4, …)` as "index 0x02 then data".
- **Stride 0x50 = 80** (`sub di,51h` = `-0x50` net of `stosb +1`, `f_204ce.asm:73`) — i.e.
  `width/4 = 320/4 = 80` bytes per row. This pins the **unchained address→offset** mapping.
- Write mode is the **default (write mode 0)**: the CPU byte goes to the masked planes.

### 2.2 The main BaK blitter: `_vgablit_planar_runs` (`f_14c3c.asm`)

`f_14c3c.asm` is "the VGA Mode-X planar run/span blitter" — segment 0x14c1, the engine's real blit
path (`f_14c3c.asm:1-48`). Setup/teardown + the inner plane writes:

```asm
mov dx,3ceh
mov ax,4105h   ; GC idx 5 (Mode) = 0x41   (setup)        f_14c3c.asm:127-129
out dx,ax
mov dx,3c4h
mov al,2       ; SC index 2 (Map Mask)                    :130-132
out dx,al
inc dx         ; dx -> 0x3C5 (SC data port)
...
mov al,0fh
shl al,cl
and al,cs:[bx+_plane_mask]  ; _plane_mask = {0x0f,0x01,0x03,0x07}  :88,:156-160
out dx,al      ; write Map Mask (0x3C5) = leading-pixel plane mask
movsb          ; copy 1 source byte -> masked plane(s)   :161-162
...
mov al,0fh
out dx,al      ; Map Mask = all planes
rep movsb      ; bulk middle                              :186-188
...
mov dx,3ceh
mov ax,4005h   ; GC Mode = 0x40 (teardown)               :212-213
out dx,ax
```

Page-to-page copy `f_2ae26.asm` (`screen_frame_sync_buffers_rect`, `:78-99`):

```asm
out(0x3c4, 0x0f02)  ; Map Mask = all planes
out(0x3ce, 0x4105)  ; GC Mode = 0x41
rep movsb           ; VGA front-page -> page-2 copy
out(0x3ce, 0x4005)  ; GC Mode = 0x40 (restore)
```

### 2.3 Register **read-back** (`IN AL,DX`) — `f_1ca27.asm` `vga_save_and_setup_gc_sc`

`f_1ca27.asm` saves/restores GC + SC state by **reading registers back** before writing — this is why
a silent-drop / `0xFF`-read is wrong; the registers must store and return what was written
(`f_1ca27.asm:101-163`): GC indices **0** (Set/Reset), **1** (Enable Set/Reset), **4** (Read Map),
**5** (Mode), **8** (Bit Mask), **3** (Data Rotate) are each `OUT index; IN data`-read; SC index
**2** (Map Mask) is read back at 0x3C4/0x3C5. So the **whole register file must round-trip**, not just
the indices Mode-Y writes for effect.

### 2.4 Page bases — front 0xA000 / back 0xA400

`video_init` defaults `wGfxBlitDstPage = wVgaPage2Base` (back page 0xA400) and LAMUT re-points it to
`wVgaFrontPageBase` (0xA000) for the static hold (`plans/lamut-milestone.md:85-88`). The page base is a
**segment** the blit writes through (`mov es, wGfxBlitDstPage`), NOT a CRTC start-address program in
the LAMUT path — i.e. the offset within the A000 window is `(page_base - 0xA000)*16 + di`. The CRTC
start-address (0x0C/0x0D) selects what the *render* scans out (§5); LAMUT writes to the front page and
holds it, so for Stage-2 capture the displayed page base is 0xA000 (start address 0).

### 2.5 The minimum faithful subset (what to build)

| Register file | Indices Mode-Y uses | Why |
| --- | --- | --- |
| **Sequencer** (0x3C4/5) | **2 Map Mask** (plane write gate); **4 Memory Mode** (chain-4 bit 3 → chained/unchained) | the core plane gate + the chained/unchained selector |
| **Graphics Controller** (0x3CE/F) | **5 Mode** (write mode 0/1, read mode); **4 Read Map Select**; **8 Bit Mask**; **0/1 Set-Reset/Enable**; **3 Data Rotate**; **6 Misc** (read-back) | write/read semantics + full read-back (`f_1ca27`) |
| **CRTC** (0x3D4/5) | **0x0C/0x0D start address**; **0x14 b6 / 0x17 b6** unchain bits (read-back) | page-base/render scan-out + Mode-Y unchain (read-back) |
| **Attribute Controller** (0x3C0) | flip-flop + palette/mode regs (round-trip) | the mode-set may drive it; replace `assert(false)` |

**Write modes the asm uses:** write mode 0 (`f_204ce`, the Map-Mask + CPU-byte fan-out) and the
GC-Mode `0x41`/`0x40` toggle (`f_14c3c`/`f_2ae26`). **Read mode 0** (Read Map Select). See the
**fidelity flag in §6** about the `0x41` (write-mode-1 bit) vs the movsb-from-RAM behaviour — model
both write modes 0 and 1 faithfully and let the LAMUT probe decide which path the overlay actually
exercises.

---

## 3. How dosbox-staging vs spice86 model it (copy vs avoid)

Both derive the planar engine from the **same VGA hardware spec**; they differ in storage layout and
code shape. zdos should take **spice86's plane-major decode clarity** with **dosbox's compact
write-mode table**, and keep zdos's existing bus dispatch.

### 3.1 The register files

- **spice86** (cleaner OO, the model to follow structurally): an index port stores `Address`, the data
  port reads/writes `Registers[Address]` — both **read-back-able**
  (`VgaIoPortHandler.cs:113-160` reads, `:258-336` writes). Typed register classes decode bits
  (`GraphicsModeRegister.cs:22-67`: WriteMode = bits[1:0], ReadMode = bit 3, In256Color = bit 6). The
  attribute controller toggles `_attributeDataMode` per 0x3C0 write and **resets it on a 0x3DA read**
  (`VgaIoPortHandler.cs:162,294-308`). The Sequencer Map-Mask setter is a plain register store
  (`:283-291`).
- **dosbox-staging**: the Map-Mask write **precomputes a 32-bit fan-out mask**:
  `vga.config.full_map_mask = FillTable[val & 15]` (`vga_seq.cpp:63-65`), and the chain-4 bit drives a
  **handler swap**: `seq(memory_mode)` bit 3 sets `vga.config.chained` and calls `VGA_SetupHandlers()`
  (`vga_seq.cpp:107-112`) — swapping the chained vs `VGA_UnchainedEGA_Handler` page handler. **This is
  the exact dispatch model zdos adopts** (chained → fast path; unchained → planar handler), §4.1.

**zdos decision:** model each register file as a small indexed array (`[N]u8`) + an `index: u8` latch,
with read-back from the array — spice86's shape, but plain Zig POD (no class hierarchy). Decode bits at
*use* sites (one `mapMask()` / `writeMode()` accessor), not via typed wrapper structs (avoids
over-engineering — CLAUDE "underengineer when in doubt", and matches zdos's existing flat-field DAC
model). Replace `vga.zig:513` `else => 0xFF` and `:532` `else => {}` with index/data arms.

### 3.2 The planar VRAM engine — the four write modes + latches

- **dosbox** `ModeOperation(val)` (`vga_memory.cpp:65-93`) is the canonical compact write-mode switch:
  - **WM0**: `ExpandTable[val]` (replicate byte across 4 planes) → `RasterOp` with latch → bit-mask
    select (latch vs data) (`:68-73`).
  - **WM1**: `full = vga.latch.d` — copy the 32-bit latch verbatim; host data unused (`:75-77`).
  - **WM2**: `RasterOp(FillTable[val&0xF], full_bit_mask)` — replicate each of bits 3-0 across its
    plane (`:79-81`).
  - **WM3**: set/reset expanded by `ExpandTable[val] & bit_mask` (`:83-86`).
  - then `pixels &= full_not_map_mask; pixels |= data & full_map_mask` — the Map-Mask plane gate, on a
    **byte-interleaved `uint32_t` per address** (`mem.linear[start]` holds plane0..3 in bytes 0..3,
    `vga_memory.cpp:280-286`). Read: `latch.d = ((uint32_t*)linear)[start]; return latch.b[read_map]`
    (`:131-134`) for read mode 0; read mode 1 is the color-compare (`:135-138`).
- **spice86** `VideoMemory.Write/Read` (`VideoMemory.cs:101-307`) is the **clearest** reference: VRAM
  = 256 KiB **interleaved** (`offset*4 + plane`, `:269-272`), 4 plane **latches** loaded on every read
  (`:46-51`), all four write modes as explicit methods (`HandleWriteMode0..3`, `:168-242`) gated by
  `planeEnable[plane] && writePlane[plane]` (Map-Mask AND address-decoded planes). The **address
  decode** (`DecodeWriteAddress`/`DecodeReadAddress`, `:279-340`) is the key: in **chain-4** mode
  `plane = offset & 3; offset &= ~3`; in **planar (unchained)** mode `planes = 0b1111` (let Map-Mask
  decide), `offset = address` (NO division) — so the Map-Mask alone selects planes. This **exactly
  matches the BaK asm** (§2.1: the asm sets the Map-Mask per-plane and the offset steps by 80/row).

**Copy:**
- spice86's **planar decode** (chain-4 → plane=off&3; unchained → all-planes + Map-Mask gate) — it is
  the cleanest and matches the asm.
- The **4 plane latches loaded on read**, used by WM1/WM2/WM3 + the bit-mask in WM0 — both refs do
  this; it is real hardware. (BaK's `f_2ae26` WM1 page copy depends on it.)
- dosbox's compact write-mode arithmetic as the *reference* for each mode's formula.

**Avoid:**
- dosbox's **`vga.fastmem` / `Expand16Table` pixel-cache** (`vga_memory.cpp:287-297`) — that is a
  *renderer* acceleration structure (it pre-expands planes into a draw buffer); zdos's capture is a
  pure read at a fixed cycle (§5), so it needs no fastmem. **Do not copy.**
- dosbox's `read_delay()` / `CPU_Cycles -= delay_cycles` VRAM access delay (`vga_memory.cpp:115-124`) —
  that is a host-cycle-budget timing hack; zdos charges VRAM access via the CPU's own instruction cost
  (CLAUDE #1) — **do not copy**.
- spice86's `HasChanged`/`Volatile`/`Interlocked` (`VideoMemory.cs:18-19,161-167,275`) — that is a
  renderer dirty-flag for its *threaded UI*; zdos's emulation core is single-threaded and capture is a
  pure peek — **do not copy** (it would also violate the no-host-thread-feedback determinism rule).
- spice86's `IsOutsideCurrentlyMappedRange` log-and-drop (`:94-98,102-108`) — zdos's bus already gates
  the A000 window by page kind; no per-access range log.

**Storage-layout decision (differs from both refs on purpose):** zdos uses a **plane-major** layout
`vram[plane*0x10000 + offset]` (plane 0 = bytes 0x00000..0x0FFFF, plane 1 = 0x10000.., …), NOT the
byte-interleaved `offset*4+plane` both refs use. Rationale: (1) it reuses the existing
`VRAM_SIZE=0x40000` slab as 4 contiguous 64 KiB planes with no reshape; (2) **plane 0's 64 KiB stays
byte-identical to the current linear mode-13h layout** when chain-4 maps `off&3==0` — i.e. linear mode
13h is "plane-major plane patterns" and the fast path is undisturbed; (3) the de-interleave for capture
(§5) is a trivial `plane*0x10000 + start + y*80 + x/4`. The trade-off: a read loads 4 latches from 4
non-adjacent slab bytes (`vram[p*0x10000+off]` for p=0..3) instead of one `uint32_t` — negligible (the
planar path is the slow per-access path anyway, only taken when unchained). Document this layout choice
in the `vga.zig` header.

---

## 4. The design

### 4.1 Chained-vs-unchained dispatch — keep linear mode 13h working

The bus `.mmio` path tries `h.getHostPtr(page)` first; if non-null it uses the RAM-like fast path,
else it calls `h.read8`/`h.write8` (`bus.zig:283-284,305-309`). So the dispatch is a **one-line
decision inside the VGA's `getHostPtr`**:

```zig
// memGetHostPtr (A000 window): chained (chain-4 set) -> fast path into plane 0;
// unchained -> null, forcing the planar write8/read8 slow path.
fn memGetHostPtr(self, page) ?[*]u8 {
    if (!self.chained()) return null;          // unchained Mode-Y: route to planar read8/write8
    ... existing return self.vram[off..].ptr;  // chained mode 13h: unchanged fast path
}
```

- `self.chained()` reads Sequencer index 4 (Memory Mode) **bit 3** (chain-4): set ⇒ chained (mode 13h,
  fast path), clear ⇒ unchained (Mode-Y, planar). Mirrors dosbox `vga.config.chained`
  (`vga_seq.cpp:107-112`).
- **Chained (default / mode 13h): the fast path is 100% unchanged** — plane 0 of the plane-major slab
  IS the existing linear `vram[0..64000]`, so `mov [es:di],al` still hits `vram[off]` with zero
  overhead. No regression risk to the existing mode-13h tests.
- **Unchained: `getHostPtr` returns null** → every A000 byte access goes through the planar
  `memWrite8`/`memRead8` (the Map-Mask fan-out / Read-Map select). This is the **slow per-access path**
  — acceptable because it is only taken in Mode-Y (the perf-sensitive linear case keeps the fast path).
  No bus change needed; the bus already supports a handler returning a null hostPtr.

This is cleaner than dosbox's `VGA_SetupHandlers()` page-handler swap: zdos keeps **one** MemHandler and
decides per-access via `getHostPtr` — no re-`mapMmio` on a chain-4 toggle, so no snapshot-replay
handler-ID churn.

> **Peek path:** `memPeek8` (the debugger `/api/framebuffer` path) must mirror the **read** decode
> (chained → `vram[off]`; unchained → `vram[ReadMapSelect*0x10000 + off]`) — but it must NOT load the
> latches (a peek mutates nothing, CLAUDE #5). So `memPeek8` reads the Read-Map-selected plane byte
> directly without touching `self.latch`. (The capture render in §5 de-interleaves all 4 planes
> directly from the slab, bypassing Read-Map — even simpler.)

### 4.2 The register files (indexed, with read-back)

Add four indexed register files to `Vga`, each `{ index: u8, regs: [N]u8 }`, snapshot-covered POD:

```zig
seq:  struct { index: u8 = 0, regs: [8]u8  = @splat(0) },  // Sequencer    0x3C4/0x3C5
gfx:  struct { index: u8 = 0, regs: [16]u8 = @splat(0) },  // Gfx Ctrl     0x3CE/0x3CF
crtc: struct { index: u8 = 0, regs: [32]u8 = @splat(0) },  // CRTC         0x3D4/0x3D5
attr: struct { index: u8 = 0, regs: [32]u8 = @splat(0),    // Attr Ctrl    0x3C0/0x3C1
               flip_is_index: bool = true },               // (reuse attr_flip_flop_is_index)
```

**Port protocol** (in `portOut8`/`portIn8`, replacing `:513` and `:532`):

- **0x3C4 / 0x3CE / 0x3D4 (index ports):** `out8` stores the low bits as the index; `in8` returns the
  index (read-back). A **16-bit `out16(0x3C4, w)`** = index `w&0xFF` then data `w>>8` (the `0x0f02`
  idiom, §2.1) — handle in the wide port path (the bus splits or the device sees a 16-bit out; confirm
  which at P3 against `bus.zig` port width handling — see §7 risk).
- **0x3C5 / 0x3CF / 0x3D5 (data ports):** `out8` writes `file.regs[index] = v`; `in8` returns
  `file.regs[index]` (full round-trip — `f_1ca27` read-back).
- **0x3C0 (attr address/data, the flip-flop):** if `flip_is_index` → store index (low 5 bits) + handle
  the palette-address bit; else store data at `regs[index]`. **Toggle `flip_is_index` each 0x3C0 write**
  (spice86 `:294-308`). **0x3C1** reads `regs[index]`. The existing **0x3DA/0x3BA read already resets
  the flip-flop** (`statusReg1:479`) — unify `attr_flip_flop_is_index` with `attr.flip_is_index`.
  **This replaces the `assert(false)` at `vga.zig:531` with a real state machine.**

> **Indices unused by Mode-Y still round-trip** (the design requirement): because the data port writes
> `regs[index]` for *any* index and reads it back, a guest writing+reading any index gets its byte —
> the register *files* are general, only their *effect* is scoped to the Mode-Y indices. No assert on
> an "unknown index"; an assert/flag belongs only on an unmodeled *write-mode* or *read-mode* effect
> (§6), not on register storage.

**Accessors** the planar engine + capture read:
- `mapMask() u4` = `seq.regs[2] & 0x0F`
- `chained() bool` = `(seq.regs[4] & 0x08) != 0` (chain-4)
- `writeMode() u2` = `gfx.regs[5] & 0x03`; `readMode() u1` = `(gfx.regs[5] >> 3) & 1`
- `readMapSelect() u2` = `gfx.regs[4] & 0x03`
- `bitMask() u8` = `gfx.regs[8]`; `setReset() u4` = `gfx.regs[0] & 0x0F`; `enableSetReset() u4` =
  `gfx.regs[1] & 0x0F`; `dataRotate() u3` = `gfx.regs[3] & 0x07`; `rasterOp() u2` = `(gfx.regs[3]>>3)&3`
- `startAddress() u16` = `(crtc.regs[0x0C] << 8) | crtc.regs[0x0D]`

### 4.3 The unchained planar read/write engine

The 4 plane latches are device state: `latch: [4]u8 = @splat(0)` (snapshot-covered).

**Read** (`memRead8`, unchained branch):
```
off  = phys - 0xA0000
// load all 4 latches (real hw: any read loads the 32-bit latch)
for p in 0..4: latch[p] = vram[p*0x10000 + off]
readMode 0: return latch[readMapSelect()]
readMode 1: color-compare (defer with a flag if LAMUT never uses it — §6)
```

**Write** (`memWrite8`, unchained branch) — per the §3 reference formulas, gated by Map-Mask:
```
off = phys - 0xA0000
for p in 0..4:
    if (mapMask() & (1<<p)) == 0: continue          // plane not enabled -> skip
    data = case writeMode():
        0 => bitmaskSelect( rasterOp( setResetSel(rotate(v), p), latch[p] ), v_or_bitmask, latch[p] )
        1 => latch[p]                                // copy latch (the 0x41 path)
        2 => bitmaskSelect( rasterOp( fill(v bit p), latch[p] ), bitMask, latch[p] )
        3 => bitmaskSelect( setReset(p), rotate(v) & bitMask, latch[p] )
    vram[p*0x10000 + off] = data
```
(WM0 with default Data Rotate=0, Set/Reset disabled, Bit Mask=0xFF reduces to `vram[p*0x10000+off]=v`
for each masked plane — the common §2.1 case. Model the full formula so Set/Reset/Bit-Mask round-trip,
but the LAMUT-critical reduction is the plain Map-Mask fan-out.)

**Address→plane mapping (unchained):** offset = `phys - 0xA0000` (NO `>>2`); the **Map-Mask selects the
plane(s) written**, **Read-Map selects the plane read**. This is spice86's planar decode
(`VideoMemory.cs:333-337,302-304`) and matches the BaK asm stride (one CPU offset step = one byte
within each plane; the §5 de-interleave puts pixel x at `plane=x&3, off=y*80+x/4`).

### 4.4 Cycle cost — no ledger hole

- **Unchained** writes/reads now take the device `write8`/`read8` path (no hostPtr). They are still
  charged by the **CPU's `mov`/`movsb`/`stosb` instruction cost** (the bus handler adds zero cycles —
  same as the existing A000 fast path, `vga.zig:45-50`). No host-serviced trap, no synthetic cost, **no
  hole** (CLAUDE #1). The dispatch (fast path vs handler) is invisible to the cycle ledger — the
  instruction cost is identical either way.
- Port I/O to the register files is charged by the CPU's `IN`/`OUT` cost (the bus port path adds
  nothing), exactly like the DAC ports today.
- **Do NOT** import dosbox's `read_delay` VRAM-access cycle adjustment (§3 "avoid").

---

## 5. CRTC start-address / page base + the de-interleave (capture agreement)

The framebuffer-capture render (W5/P6, a *separate* plan) must agree with this model. Define it here so
both sides match:

- **Displayed page base** = the CRTC **start address** (`crtc.regs[0x0C]<<8 | crtc.regs[0x0D]`,
  §4.2), in display-words. For LAMUT (front-page static hold, §2.4) the start address is 0 (page
  0xA000); the back page 0xA400 is `start = (0xA400-0xA000)*16/?` — but LAMUT blits to the **front**
  page and holds, so capture reads `start = 0`. The render reads the **live** start address (not a
  hardcoded 0) so a page-flip is captured correctly.
- **De-interleave** (Mode-Y, 320×200, stride 80 = width/4):
  ```
  pixel (x, y)  ->  plane  = x & 3
                    offset = start + y*80 + (x >> 2)
                    index  = vram[plane*0x10000 + offset]      // plane-major slab (§3)
                    rgb    = dac_rgb[index]  scaled 6->8 bit
  ```
  This is the inverse of the write mapping (§4.3) and the BaK stride (§2.1). The capture plan must use
  **exactly** this formula; pin the DAC 6→8 scale convention there (the milestone flags `v*255/63` vs
  `(v<<2)|(v>>4)` — `plans/lamut-milestone.md:373-375` — that decision belongs to the capture plan, not
  here; this plan only owns the plane de-interleave).
- For **Stage-1 `LAMUT-OK`** no render is needed at all — `main.c` checks return values + descriptor
  dims, not pixels (`plans/lamut-milestone.md:30-33`). The planar engine need only **store** the blit
  bytes correctly; a planar VRAM **peek** (`/api/memory` over the A000 window, already a listed region)
  verifies the bytes landed in the right planes before the render exists.

---

## 6. Faithfulness / no-fakes — what's v1, what's deferred-with-a-flag

- **v1 (model fully):** Sequencer (Map Mask, Memory Mode/chain-4) + GC (Mode, Read Map, Bit Mask,
  Set/Reset, Data Rotate) + CRTC (start address, unchain bits) + AC (flip-flop + register round-trip)
  register files with read-back; the unchained planar VRAM engine with **write modes 0 and 1** and
  **read mode 0**; the Map-Mask plane gate; the 4 latches; chained mode 13h unchanged.
- **Deferred WITH A LOUD FLAG (assert / explicit "not implemented", never silent):**
  - **Write modes 2 and 3, read mode 1 (color-compare):** the asm surveyed uses WM0 + WM1 + RM0.
    Implement WM0/WM1/RM0 v1; for WM2/WM3/RM1, `std.debug.assert(false)` with a message naming the
    mode (mirror the existing `0x3C0` discipline `vga.zig:531` and the PIT BCD assert
    `pit.zig:260`). If the LAMUT probe trips it, implement that mode (the dosbox/spice86 formulas in
    §3 are the spec) — **probe-driven**, not pre-built (CLAUDE "underengineer").
  - **Odd/even mode** (chain-2 / text-plane mapping): not on the Mode-Y path; flag if driven.
  - **The full Attribute Controller palette pipeline** (internal palette → DAC): the LAMUT path pushes
    the palette via the DAC directly (vtable slot 20, `plans/lamut-milestone.md:83`), so the AC palette
    regs only need to **round-trip** (read-back), not feed the render. Flag if a guest relies on AC
    palette remap into the capture.

> **FIDELITY FLAG (resolve via the probe — §7 Q1).** The blitters set GC Mode = **0x41** at setup
> (`f_14c3c.asm:128`, `f_2ae26.asm:84`) — bit[1:0]=01 = **write mode 1** (latch copy, host data
> unused) — yet then do `movsb` from a **RAM source segment** (not VRAM) into VRAM
> (`f_14c3c.asm:162,188`). Write mode 1 would copy the (stale) latch, not the source byte — which
> contradicts a RAM→VRAM blit. Either (a) the real fan-out is the **Map-Mask + write mode 0** path and
> the `0x41`/`0x40` toggle is the engine's convention with bit 6 (256-color) the operative bit, or (b)
> the overlay's actual blit (slot 29) differs from these engine helpers. **zdos must model write modes
> 0 AND 1 exactly per the reference formulas (§3) and let the LAMUT run reveal which the overlay
> drives** — do not guess and hardcode one. This is the single biggest unknown in this subsystem and
> the reason the checklist is probe-ordered (§8).

---

## 7. Determinism & snapshot

- **All of it is guest state → deterministic.** The 4 register files, the 4 plane latches, the start
  address, and the 256 KiB planar VRAM are written by guest `OUT`/`MOV` instructions; the planar
  read/write is a **pure function** of (register state, latches, VRAM, address, value) — no host clock,
  no float, no RNG (CLAUDE #2/#3, the bus handler-purity contract `bus.zig:26-30`).
- **Snapshot:** add `seq`/`gfx`/`crtc`/`attr` (each `{index, regs}`) + `latch: [4]u8` to
  `Vga.Snapshot` (`vga.zig:549-559`) and `snapshot`/`restore` (`:561-584`). They are plain POD. The
  256 KiB VRAM slab is already caller-copied out-of-band like the text page (`vga.zig:157-159`) — **no
  change** (the planes live in the same slab). Unify the existing `attr_flip_flop_is_index` field
  (`:207`) into `attr.flip_is_index` (or keep the field and have `attr` reference it) — one flip-flop,
  not two.
- **Reset** (`vga.zig:231`): zero all four register files + the latches; default chain-4 **set**
  (chained / mode-13h-compatible power-on) so the fast path is the boot default and existing tests are
  undisturbed. (Real VGA power-on is chained-ish; the BIOS mode-set programs the rest — and BaK's
  overlay explicitly clears chain-4 to enter Mode-Y.)
- **No new cycle-ledger hole** (§4.4). **No new port-read side effect on the peek path** (port reads
  aren't peekable; the capture peek reads raw VRAM + DAC + register *fields*, never `in8`).
- **Determinism grep-gate:** `vga.zig` is already in the devices float/host-clock gate
  (`src/devices/pit_test.zig` sources, added by the retrace plan). The new planar code is pure integer
  — keep it float/`std.time`/RNG-free; the gate already covers it. **Add a snapshot round-trip test**
  for the register files + latches (mirror the existing VRAM round-trip).

---

## 8. Phased checklist (each ≈ one focused commit; gates stay green; independently testable)

Probe-ordered: build the registers first, run LAMUT further, see which planar feature it hits next
(per the milestone's probe discipline, `plans/lamut-milestone.md:368`).

- [ ] **MY1 — Sequencer + Graphics Controller register files with read-back.** Add `seq`/`gfx`
      `{index, regs}` to `Vga` (`vga.zig:102+`); add 0x3C4/0x3C5/0x3CE/0x3CF index+data arms to
      `portOut8`/`portIn8` (replace `:513` `0xFF` read + `:532` `else => {}` for these ports); handle
      the 16-bit `out16(0x3C4, w)` index+data idiom (confirm the bus wide-port path, §7 Q2). Register
      the ports in `machine.wire()` (near the existing VGA registrations). **Unit-test** the index/data
      round-trip + read-back (the `f_1ca27.asm` `OUT idx; IN data` idiom; Map Mask, GC Mode/Read
      Map/Bit Mask).
- [ ] **MY2 — CRTC register file + Attribute Controller state machine.** Add `crtc`/`attr`
      `{index, regs}`; add 0x3D4/0x3D5 index+data + the 0x3C0/0x3C1 flip-flop state machine (replace
      the `assert(false)` at `vga.zig:531`); unify `attr_flip_flop_is_index` (`:207`) with the AC file
      and the 0x3DA-read reset (`:479`). Register the ports. **Unit-test** round-trips + the flip-flop
      reset-on-0x3DA-read + start-address read-back. **Probe:** re-run LAMUT — the overlay's Mode-Y
      *register* program now completes without an assert/drop (it should reach the planar VRAM writes).
- [ ] **MY3 — chain-4 detect + the dispatch decision (no planar effect yet).** Add `chained()`
      (`seq.regs[4] & 0x08`) and make `memGetHostPtr` (`vga.zig:288`) return `null` when unchained
      (chained keeps the existing fast path verbatim). Add a stub planar `memRead8`/`memWrite8` that —
      for now — does the **plane-0 / linear** behaviour (so nothing changes functionally yet) plus an
      assert that flags an unchained access reaching it. **Test:** mode-13h fast path unchanged (all
      existing VGA tests green); an unchained write reaches the handler.
- [ ] **MY4 — unchained planar write mode 0 + Map-Mask fan-out + 4 latches.** Implement the real
      `memWrite8` (WM0 fan-out gated by `mapMask()`, with Set/Reset/Bit-Mask/Data-Rotate formula) and
      `memRead8` (load 4 latches; read mode 0 returns `latch[readMapSelect()]`), plane-major layout
      `vram[p*0x10000+off]`. Add `latch: [4]u8`. **Test:** a Map-Mask=0x0E write touches planes 1-3
      only; Map-Mask=0x0F touches all; a Read-Map=2 read returns plane 2 (the `f_204ce.asm` pattern).
      **Probe:** re-run LAMUT — the blit's WM0 writes land in the planes (verify via a planar VRAM peek
      over A000, even before the render exists).
- [ ] **MY5 — write mode 1 (latch copy).** Implement WM1 (`vram[p*0x10000+off] = latch[p]` for masked
      planes) — the `f_2ae26.asm` / `f_14c3c.asm` GC-Mode-0x41 path. **Test:** a VRAM→VRAM `rep movsb`
      under Map-Mask=0x0F copies all 4 planes via latches. **Probe:** re-run LAMUT — resolve the §6
      fidelity flag (does the overlay's slot-29 blit use WM0 via Map-Mask, or WM1 latch-copy?).
- [ ] **MY6 — snapshot + reset coverage.** Add `seq`/`gfx`/`crtc`/`attr`/`latch` to `Vga.Snapshot` +
      `snapshot`/`restore` (`vga.zig:549-584`); zero them in `reset` with chain-4 default set
      (`vga.zig:231`). **Test:** a snapshot/restore round-trips an unchained Mode-Y machine state
      byte-identically (mirror the existing VRAM round-trip test).
- [ ] **MY7 — write/read modes 2/3 + read mode 1 (ONLY if the probe trips them).** Each is one
      assert→implement sub-commit using the §3 dosbox/spice86 formula, ordered by what LAMUT actually
      hits. Likely **not needed** (the asm uses WM0/WM1/RM0) — keep as deferred-with-a-flag until the
      run proves otherwise.
- [ ] **MY8 — the de-interleave contract (shared with the capture plan).** Land the §5 de-interleave as
      a `pub fn` (`pixelIndex(x, y) u8` reading `vram[(x&3)*0x10000 + startAddress() + y*80 + (x>>2)]`)
      so the W5/P6 framebuffer-capture render calls **one** function and cannot disagree with the write
      mapping. **Test:** write a known pattern via the planar engine (WM0 + Map-Mask), read it back via
      `pixelIndex`, assert the round-trip (the inverse-mapping proof).

(MY1-MY6 are the headline subsystem; MY7 is probe-contingent; MY8 is the seam to the separate
framebuffer-capture plan. This composes with the milestone: MY1/MY2 unblock the overlay's register
program, MY3-MY5 the planar blit, MY8 the Stage-2 visual oracle.)

---

## 9. Risks / open questions (for the human)

1. **Q1 — the GC-Mode 0x41 / write-mode-1 fidelity flag (the biggest unknown).** The engine blitters
   set GC Mode = 0x41 (write mode 1) but `movsb` from RAM (§6 flag). zdos models WM0 and WM1 exactly
   per the reference and lets the **LAMUT probe** (MY5) reveal which the overlay's slot-29 blit uses —
   do NOT guess/hardcode. **Decision: approve the probe-driven approach (model both, observe), vs
   pre-committing to one?** Recommend: model both (cheap; faithful).
2. **Q2 — the 16-bit index+data OUT path (`out 0x3C4, 0x0f02`).** The asm uses **word OUTs** to the
   index ports (`f_204ce.asm:65`, `f_2ae26.asm:80-85`). Need to confirm whether zdos's bus delivers a
   16-bit port write to the device as one `out16` or splits it into two `out8`s (index then data) — the
   register-file protocol must handle whichever (`bus.zig` port width handling; check at MY1). **Flag:
   verify the bus wide-port dispatch before MY1.**
3. **Q3 — plane-major vs interleaved VRAM layout.** zdos picks **plane-major** (`p*0x10000+off`) so
   mode-13h plane 0 == the current linear slab and the fast path is undisturbed; both refs use
   interleaved (`off*4+p`). The trade-off is a 4-byte-scattered latch load (negligible, slow path
   only). **Decision: approve plane-major** (recommended — zero mode-13h regression, trivial
   de-interleave) **or match the refs' interleaved layout?**
4. **Q4 — scope of write/read modes up front.** Recommend WM0 + WM1 + RM0 in v1 (what the asm uses),
   WM2/WM3/RM1 deferred-with-an-assert (MY7, probe-contingent). **Decision: approve the minimal
   probe-driven scope, or model all four modes up front** (more code now, but no probe surprise)?
5. **Q5 — Attribute Controller depth.** The LAMUT path pushes the palette via the DAC directly, so the
   AC regs only need to round-trip (read-back), not feed a render. Recommend: real flip-flop + register
   round-trip, no AC→DAC palette pipeline. **Decision: confirm the AC round-trip-only scope** (flag if
   a guest drives AC palette remap into the capture).
6. **Q6 — the existing mode-13h snapshot/region.** No reshape needed (the planes live in the existing
   `VRAM_SIZE=0x40000` slab, caller-copied out-of-band). The only `Vga.Snapshot` growth is the POD
   register files + latches. **Confirm: no change to the VRAM caller-copy contract.**
7. **Q7 — interaction with framebuffer capture (W5/P6).** The §5 de-interleave (MY8) is the shared
   contract; the DAC 6→8 scale convention belongs to the capture plan, not here. **Confirm: this plan
   owns the plane de-interleave; the capture plan owns the DAC scale + the golden.**
8. **Q8 — not assessable without running LAMUT further.** Which write/read modes the overlay's slot-29
   blit actually drives, whether it programs the CRTC start address (vs only the page-base segment),
   and whether it touches the AC are **unproven until the run gets past `video_init`** (the probe only
   reached `video_init` per `plans/lamut-milestone.md:48-60`). Each is flagged verify-at-probe in the
   checklist, not assumed.
