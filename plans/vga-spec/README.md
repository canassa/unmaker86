# Full VGA implementation spec — master index

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
