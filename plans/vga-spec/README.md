# Full VGA implementation spec — master index

**Status: v2** (folded in a 4-perspective review: determinism, hardware-fidelity, Zig/integration,
performance/cache — all returned "approve/correct WITH changes", no structural dead-end). The §"v2
review fold" section below lists every applied fix and where it landed.

A complete, hardware-compliant VGA specification for zdos, derived from dosbox-staging +
spice86 + the IBM VGA behavior. Goal: a **full VGA core** (not a minimal subset) so zdos
runs any VGA DOS program and no stubbed/skipped feature bites later. The first real consumer
is the LAMUT milestone (`plans/lamut-milestone.md`), which drives the *ordering* but not the
*completeness*.

## Sections (each a complete spec for its area)
1. **[01-registers.md](01-registers.md)** — all 6 register groups, every index/bit/protocol.
   60 indexed registers (SEQ 5, CRTC 25, GC 9, AC 21) + 4 external/general + the DAC.
   The 3 protocols (indexed index/data with read-back; AC flip-flop; DAC triple). Write-protect
   (CRTC idx 0x11 bit 7 over 0x00–0x07), the AC PAS bit, reset/power-on values.
2. **[02-memory-engine.md](02-memory-engine.md)** — the CPU↔VRAM path. Write modes 0–3, read
   modes 0–1, the 4 latches, Map-Mask / Set-Reset / Enable-Set-Reset / Bit-Mask / Data-Rotate+ALU
   / Color-Compare / Color-Don't-Care, and all addressing modes (chained-256 / unchained-planar
   Mode-X / EGA-16 / odd-even / doubleword) + the GC-Misc window select.
3. **[03-crtc-scanout-render.md](03-crtc-scanout-render.md)** — the display side. CRTC
   timing/addressing (start address, offset/stride, max-scan-line/double-scan, line-compare
   split-screen, panning, value-packing), and the **rasterizer for every mode** (text+font, CGA,
   EGA-16, VGA-256 linear, Mode-X) → attribute pipeline → DAC → RGB. The deterministic
   framebuffer-capture interface.
4. **[04-modes-int10-bda.md](04-modes-int10-bda.md)** — the BIOS layer. 14 standard modes +
   Mode-X, the per-mode register parameter tables, the **full INT 10h function set** (every AH +
   subfunctions), the complete BDA video area, and the ROM fonts. The LAMUT-critical gaps:
   **AX=1A00** (adapter detect) and **AH=1130** (font pointer).

## Unified design decisions (all four sections agree)
- **Plane-major VRAM** `vram[plane*0x10000 + off]` over the existing 256 KiB slab — so mode-13h
  plane 0 stays byte-identical to today's linear VRAM (zero regression) and de-interleave is
  trivial. (Deliberate divergence from both refs' interleaved layout.)
- **One-line chain-4 dispatch:** `memGetHostPtr` returns the host pointer when *chained* (mode 13h
  fast path, 100% unchanged) and `null` when *unchained*, routing A000 through the planar
  `read8`/`write8`. No bus change, no `mapMmio` re-install, no handler-ID churn.
- **Register files = indexed POD** `{index, regs:[N]u8}` with full read-back, replacing today's
  silent-drop (`vga.zig:532`) / `assert(false)` (`:531`) / 0xFF (`:513`).
- **Integer rasterizer, on-demand whole-frame spatial render** (no per-scanline draw-state walk),
  index-buffer-first output (+ optional RGBA). DAC 6→8 expansion = **`(c<<2)|(c>>4)`**.
- **Pure-peek `GET /api/framebuffer`** mirroring `/api/screen` — produces a convention-independent
  **index image** (the LAMUT `lamut_0.idx` oracle) AND raw RGBA; cycle-neutral, two-run identical;
  PNG encoding stays host-side.
- **Determinism:** registers + VRAM + latches are pure guest state → deterministic, snapshot-
  covered. **Rejected host-coupled pieces from the refs** (do NOT copy): dosbox `read_delay`/
  `write_delay` (host-cycle hack — ledger hole), dosbox `fastmem`/`Expand16Table` (renderer cache),
  spice86 `Volatile`/`HasChanged` (threading), and ALL render/blink/refresh wall-clock timing.
  Cursor/blink, if shown, is `f(cpu.st.cycles)` or static. Input Status #1 stays the existing
  cycle-derived 0x3DA. New code stays float/host-clock-free (devices grep-gate).
- **No-fakes / probe-driven:** features off the LAMUT path (WM2/WM3, RM1, odd/even text fixups,
  doubleword, the EGA/CGA renderers, the rarely-used INT 10h subfns) are **specified now** but may
  be implemented on-probe behind a **LOUD assert** — never a silent wrong result.

## v2 review fold (applied fixes — what changed and where)

A 4-perspective review (determinism / hardware-fidelity / Zig-integration / performance-cache) cleared
the spec for implementation **with fixes**. All are now folded into the section docs:

**Blocking (1):**
- **B1 — `/api/framebuffer` transport.** It **cannot** mirror `/api/screen`'s value-returned inline-POD
  `Response` (a frame is 64 KB–1.2 MB; `resp_buf` is 32 KB, `RequestCtx` is stack-allocated). Fixed in
  **§3.5.3**: a **server-owned fixed render buffer** (allocated once) + **raw binary streaming**
  (`application/octet-stream`, `?format=index|rgba`), with only a tiny POD descriptor through the normal
  path. PNG stays host-side.

**Hardware fidelity (HIGH):**
- **S1 — mode-13h is NOT double-scan.** CRTC reg 9 = `0x41` has **bit 7 clear**; the 400-line raster
  comes from Max-Scan-Line bits 0-4 (`=1` → 2-line row repeat) + bit 6 (line-compare bit 9). Fixed in
  **§3.2.3** and **§4.1.2** (CRTC10 note); §1 reg-table note clarified.
- **S2 — Color-Plane-Enable masks the 4-bit INDEX before the palette lookup**, not the 6-bit output.
  Fixed in **§3.3.6** (new step 0).

**Hardware fidelity (MEDIUM):**
- **S3 — load-default-palette gate is MODESET_CTL 0x89 bit 3** (not VIDEO_CTL 0x87) and gates the AC
  internal palette (DAC loaded unconditionally). Fixed in **§4.1.3 step 3** (with a verify-on-implement
  flag).
- **S4 — odd/even plane offset is a bit-0 mask/OR fixup** (`off & 0xFFFE` standard case), **not**
  `off >> 1`. Fixed in **§2.4.3** and the §2.4.6 decode table.

**Determinism (all "YES with changes"):**
- **R1 — the float/host-clock grep-gate must cover the NEW files** (`vga_render.zig`, `vga_modes.zig`,
  `vga_font.zig`). This is a **blocking implementation checklist item** (see roadmap below) — adding a
  new device/bios source without adding it to the gate is the regression.
- **R2 — snapshot round-trip of the register files + 4 latches**, with a mid-render test + reset()
  power-on defaults. Already in §1.8.3 / §2.8; kept.
- **R3/R6 — `/api/framebuffer` cycle-neutrality test** asserting no DAC-index / AC-flip-flop / latch
  mutation. Fixed in **§3.5.1** (three explicit invariants + before/after snapshot equality).
- **H2 — the new register ports** (`0x3C0/1`, `0x3C4/5`, `0x3CE/F`, `0x3D4/5`, `0x3CA`) **must be
  registered in `wire()`**. Blocking checklist item (roadmap).

**Performance / cache (keep the design, fix the rationale):**
- **Plane-major stays**, but the "negligible cost" claim was wrong — it is a deliberate trade: ~4×
  cache-line/TLB blowup on all-plane latch loads/fills, an inverse 4× **win** on single-plane strips,
  decided by mode-13h byte-identity + zero reshape. Corrected in **§2.1.2**.
- **F2 — trivial-config bulk-write fast path** (`dataRotate==0 && enableSetReset==0 && alu==replace
  && bitMask==0xFF` → direct per-plane store) and **F4 — decode hot write-mode regs into a packed
  `WriteConfig` on the rare register write** (gives `trivial` for free). New **§2.2.6**; both are
  transparent (byte-identical VRAM, identical cycles, recomputed in `restore()` so no snapshot churn).

## Cross-section reconciliations (decide before implementing)
- **DAC 6→8 convention:** §1 noted the two refs differ; §3 pins **`(c<<2)|(c>>4)`** (spice86) — and
  the index-image oracle sidesteps it entirely. ADOPT `(c<<2)|(c>>4)`.
- **DAC read/write-index decoupling (a real correctness Q, §1):** zdos currently re-links
  `read_index`/`write_index` on a full 0x3C9 triple (`vga.zig:428-451`), but dosbox **deliberately
  decouples** them ("breaks Wari", `vga_dac.cpp:285-316`). **Verify against the DAC oracle corpus**
  and decouple if the oracle disagrees — flagged, not assumed.
- The §3 rasterizer's de-interleave (`plane=x&3, addr=x>>2`) must match §2's plane-major layout and
  §4's set-mode geometry — confirmed consistent across the three.

## Implementation roadmap (full-spec-complete, LAMUT-ordered)
Phased so the LAMUT probe gets further each step, but built to the full spec (nothing skipped —
deferred-with-assert is explicit, not silent):
1. **Register files** (§1) — SEQ/GC/CRTC/AC indexed POD + read-back + AC flip-flop + write-protect;
   snapshot. (Unblocks the overlay's register read-backs.)
2. **INT 10h AX=1A00 + AH=1130 + fonts** (§4) — the immediate LAMUT blockers; rewrite set-mode as
   the full register dump + default DAC palette; the mode parameter tables.
3. **Memory engine** (§2) — chain-4 dispatch + unchained planar WM0/WM1 + latches + RM0; WM2/3,
   RM1, odd/even, doubleword deferred-with-assert.
4. **Rasterizer + `/api/framebuffer`** (§3) — VGA-256 (13h + Mode-X) first (LAMUT Stage 2), then
   text/EGA/CGA to complete the spec.
5. **Remaining INT 10h subfns + modes + the deferred engine modes** — fill to full compliance.

Each phase: green gate, snapshot-covered, determinism-grep-clean, oracle-validated where a golden
exists (register/VRAM/framebuffer content are all valid cross-emulator goldens, unlike retrace).

**Blocking per-phase checklist items (from the v2 review fold — do NOT skip):**
- **[R1] Add every new source file to the float/host-clock grep-gate** the moment it is created —
  `vga_render.zig` (phase 4), `vga_modes.zig` + `vga_font.zig` (phase 2). A new device/bios file that
  isn't in the gate is the determinism regression the gate exists to catch.
- **[H2] Register the new VGA register ports in `wire()`** when phase 1 lands: `0x3C0`/`0x3C1`,
  `0x3C4`/`0x3C5`, `0x3CE`/`0x3CF`, `0x3D4`/`0x3D5`, `0x3CA` (read) — without this the register files
  are unreachable from guest `IN`/`OUT`.
- **[R2/R3] Snapshot round-trip + capture cycle-neutrality tests** ship with the phase that adds the
  state (register files in phase 1; latches in phase 3; framebuffer peek in phase 4).
