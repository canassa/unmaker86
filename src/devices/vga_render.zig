//! The VGA rasterizer (plans/vga-spec/03-crtc-scanout-render.md, Phase 4) — a PURE
//! whole-frame render of guest state (VRAM + registers + DAC) into an index buffer
//! and a derived RGBA buffer. There is NO draw loop, NO per-scanline walk state, NO
//! host clock, NO render timer, NO float — the frame is a spatial function of the
//! LATCHED register state at a fixed cycle (CLAUDE prime directive §0). Every entry
//! takes a `*const Vga` (a const receiver: no device mutation) so the capture cannot
//! advance the DAC index / AC flip-flop / plane latches / cycle counter (§5.1, R3/R6).
//!
//! Determinism (this file is in the src/devices float/host-clock grep-gate, R1):
//!   - integer-only: no host clock, no floats, no RNG (the grep gate enforces it).
//!   - reads RAW device fields (`vram`, `dac_rgb`, `pel_mask`, `attr.regs`, the CRTC
//!     accessors) — never the mutating port state machine (`read3c9`/`in8(0x3DA)`/
//!     `memRead8`). The de-interleave reads the plane-major slab DIRECTLY (§5.1).
//!   - blink/cursor are rendered "high / solid" (the everything-visible phase, §6) —
//!     never a wall-clock phase.
//!
//! Module placement (§7.2): this lives in `src/devices/` (BELOW `bios` in the module
//! graph), so it CANNOT import the ROM font that lives in `src/bios/vga_font.zig`.
//! Faithful resolution: the rasterizer is font-source-agnostic — text rendering takes
//! a `FontView` (a glyph slice + cell height) supplied by the caller, who reads the
//! REAL staged ROM-font bytes from guest memory (the controller peeks `FONT*_PHYS`,
//! exactly the bytes a hardware character generator would fetch). No fake, no dup.

const std = @import("std");
const vga_mod = @import("vga.zig");

const Vga = vga_mod.Vga;
const PLANE_SIZE = vga_mod.PLANE_SIZE;

/// The widest standard VGA mode is 640x480 (modes 11h/12h). The capture buffers are
/// sized for it (the server owns one fixed pair, §3.5.3); a narrower mode fills the
/// `width*height` prefix.
pub const MAX_WIDTH: u32 = 640;
pub const MAX_HEIGHT: u32 = 480;
pub const MAX_INDEX_LEN: u32 = MAX_WIDTH * MAX_HEIGHT; // 307200
pub const MAX_RGBA_LEN: u32 = MAX_INDEX_LEN * 4; // 1228800

/// The widest TEXT raster: 90 cols * 8 dots, or 80 cols * 9 dots = 720 (the 9-dot
/// text family is WIDER than the 640 graphics max but SHORTER — 720*400 < 640*480, so
/// it still fits MAX_INDEX_LEN). The text post-pass scratch row is sized for it.
pub const MAX_TEXT_WIDTH: u32 = 720;

/// The rendered-frame family (which per-mode function rasterized it). Reported in the
/// descriptor + the streamed binary's headers so a consumer interprets the index/RGBA
/// correctly (e.g. text index = final DAC index, 256-color index = raw VRAM byte).
pub const Kind = enum(u8) {
    /// VGA 256-color, chained linear (mode 13h). Index = raw VRAM byte.
    vga256_linear,
    /// VGA 256-color, unchained planar (Mode-X/Y). Index = de-interleaved VRAM byte.
    vga256_planar,
    /// Text (modes 0-3 color, 7 mono). Index = final DAC index after the AC pipeline.
    text,
    /// EGA 16-color planar (0Dh-12h). Index = final DAC index after the AC pipeline.
    ega16,
    /// CGA 1bpp/2bpp (modes 4/5/6). Index = final DAC index after the AC pipeline.
    cga,
    /// The current mode has no faithful rasterizer wired yet (deferred-with-assert in
    /// the caller). Never produced by a render call.
    unsupported,
};

/// The per-capture mode view — the BDA/mode parameters the caller resolves (the
/// dispatch key + text geometry + font). Everything else the rasterizer needs comes
/// from the `*const Vga` registers/VRAM/DAC directly (§5.1). Kept a plain POD so the
/// caller (the controller) assembles it from a side-effect-free BDA peek.
pub const ModeView = struct {
    /// The BDA video mode byte (OFF_VIDEO_MODE) — the dispatch key.
    mode: u8,
    /// Text columns / rows (BDA OFF_VIDEO_COLS / OFF_NB_ROWS+1). Text modes only.
    cols: u16 = 80,
    rows: u16 = 25,
    /// Character cell height in scanlines (BDA OFF_CHAR_HEIGHT). Text modes only.
    char_height: u8 = 16,
    /// Cell width in dots (8 or 9). Text modes only; 9-dot is the 720-wide text family.
    char_width: u8 = 8,
    /// Active text page (BDA OFF_ACTIVE_PAGE) — selects the B8000/B0000 page slab.
    active_page: u8 = 0,
    /// Cursor cell (BDA OFF_CURSOR_POS): row/col, and the shape scanline span.
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_start: u8 = 0,
    cursor_end: u8 = 0,
    cursor_visible: bool = false,
    /// The active text-page cell slab (`cols*rows*2` flat {char,attr} bytes), peeked
    /// by the caller (B8000 color / B0000 mono). Text modes only.
    text_cells: []const u8 = &.{},
    /// The ROM glyph bytes for the active cell height (`256 * char_height` bytes),
    /// peeked by the caller from the staged BIOS ROM font. Text modes only.
    font: []const u8 = &.{},
};

/// The result descriptor (returned through the normal small-POD response path, §3.5.3).
/// The big index/RGBA payloads live in the caller-provided buffers, NOT here.
pub const Descriptor = struct {
    kind: Kind,
    width: u16,
    height: u16,
    index_len: u32,
    rgba_len: u32,
    /// Whether the CRTC double-scan bit (Max-Scan-Line bit 7) was set — recorded as a
    /// flag, NOT applied (the index/RGBA are at LOGICAL resolution, §2.3 / S1).
    double_scan: bool,
    /// The Max-Scan-Line row-repeat (S1): the displayed row advances every
    /// `(MaxScanLine & 0x1F) + 1` raster lines. Recorded for the consumer's aspect
    /// scaling; the logical-res image is repeat-independent.
    row_repeat: u8,
};

// ===========================================================================
// DAC 6->8 + the index->RGBA second pass (§3.7). Bit-replication, pinned (S/§3.7).
// ===========================================================================

/// 6-bit -> 8-bit DAC expansion: `(c << 2) | (c >> 4)` (spice86 convention, pinned at
/// comptime, §3.7). Integer-only bit replication: 0->0, 63->255, 32->130.
pub inline fn expand6to8(c: u8) u8 {
    const v: u8 = c & 0x3F; // the DAC stores 6-bit values
    return (v << 2) | (v >> 4);
}

/// Derive the RGBA image from a finished index image, via the DAC (+ pel mask, §3.7).
/// `rgba` MUST be `>= index.len * 4`. Pure: reads `vga.dac_rgb`/`vga.pel_mask` RAW
/// (never `read3c9`, which advances `dac_read_index`). RGBA byte order is R,G,B,A.
pub fn indexToRgba(vga: *const Vga, index: []const u8, rgba: []u8) void {
    std.debug.assert(rgba.len >= index.len * 4);
    const mask = vga.pel_mask;
    for (index, 0..) |idx, i| {
        const entry = vga.dac_rgb[idx & mask];
        const o = i * 4;
        rgba[o + 0] = expand6to8(entry.red);
        rgba[o + 1] = expand6to8(entry.green);
        rgba[o + 2] = expand6to8(entry.blue);
        rgba[o + 3] = 0xFF; // opaque
    }
}

// ===========================================================================
// The attribute pipeline (§3.6) — the shared <=16-color INDEX -> DAC-index path.
// 256-color modes BYPASS this entirely (the 8-bit pixel indexes the DAC directly).
// ===========================================================================

/// Resolve a <=16-color 4-bit attribute index to a final DAC index through the
/// Attribute Controller (§3.6), with the S2 fix (Color-Plane-Enable masks the INDEX
/// before the palette lookup). Pure read of the raw `attr.regs[]` (never a port read).
///
///   0. index &= color_plane_enable            (AC 0x12 — gates the planes/index) [S2]
///   1. internal = AC.palette[index & 0x0F]     (AC 0x00-0x0F, 6-bit each)
///   2. if AC.mode_control bit7 (5-4-select):  dac = (internal & 0x0F) | (csel << 4)
///      else:                                   dac = internal
///   3. dac |= (color_select & 0x0C) << 4       (AC 0x14 high 2 bits)
inline fn acResolve(vga: *const Vga, index4: u8) u8 {
    const color_plane_enable = vga.attr.regs[0x12] & 0x0F; // §3.6 step 0 (S2)
    const masked = index4 & color_plane_enable;
    const internal = vga.attr.regs[masked & 0x0F]; // §3.6 step 1 (6-bit internal)
    const mode_control = vga.attr.regs[0x10];
    const color_select = vga.attr.regs[0x14];
    var dac: u8 = undefined;
    if ((mode_control & 0x80) != 0) {
        // Palette-bits-5-4 select: internal low 4 bits + color-select bits as 5-4.
        dac = (internal & 0x0F) | ((color_select & 0x03) << 4);
    } else {
        dac = internal & 0x3F;
    }
    // High 2 DAC-index bits from Color Select bits 3-2 (§3.6 step 3).
    dac |= (color_select & 0x0C) << 4;
    return dac;
}

// ===========================================================================
// Address pipeline helpers (§2). For the v1 targets (mode 13h, Mode-X, standard
// text) these collapse to the simple forms; the general formula is documented.
// ===========================================================================

/// The Max-Scan-Line row-repeat count (S1): `(CRTC 0x09 & 0x1F) + 1`. The displayed
/// row address advances every this-many raster lines. NOT the double-scan bit (bit 7).
inline fn rowRepeat(vga: *const Vga) u8 {
    return (vga.crtc.regs[0x09] & 0x1F) + 1;
}

/// The CRTC double-scan flag (Max-Scan-Line bit 7) — recorded, not applied (S1/§2.3).
inline fn doubleScan(vga: *const Vga) bool {
    return (vga.crtc.regs[0x09] & 0x80) != 0;
}

/// The first LOGICAL row of the bottom line-compare split (§2.4). The CRTC Line
/// Compare value is in RASTER lines; the bottom split begins at raster line
/// `line_compare + 1` (dosbox `split_line = (line_compare+1)/vdiv`, `vga_draw.cpp:1440`;
/// spice86 resets the counter at the END of the line_compare scanline so the NEXT row
/// reads from address 0, `Renderer.cs:225-228`). Our walk emits LOGICAL rows, so the
/// raster threshold is converted to a logical-row threshold by the row-repeat. For the
/// standard modes line_compare = 0x3FF (disabled) -> the threshold exceeds every row,
/// so the split never fires and the address walk is byte-identical to the no-split path.
inline fn splitLogicalRow(vga: *const Vga) u32 {
    const lc: u32 = vga.lineCompare();
    const rr: u32 = rowRepeat(vga);
    // Bottom split starts at raster line lc+1 -> logical row (lc+1)/row_repeat. With
    // lc = 0x3FF this is well beyond any standard height (480), so no effect.
    return (lc + 1) / rr;
}

/// The line-compare-aware base address (in row-counter units) for LOGICAL row `y`, and
/// whether panning must be SUPPRESSED for that row (§2.4 / §2.6). Top split (rows below
/// the compare line) renders from `start_address` (+ panning); the bottom split renders
/// from row-counter 0 with panning suppressed (the fixed HUD). `stride` is the per-
/// logical-row address advance in row-counter units. The bottom split's first row is at
/// counter 0 and advances by `stride` thereafter (the counter RESETS at the split line).
const RowBase = struct { addr: u32, suppress_pan: bool };
inline fn rowBase(start: u32, stride: u32, y: u32, split_row: u32) RowBase {
    if (y >= split_row) {
        return .{ .addr = (y - split_row) * stride, .suppress_pan = true };
    }
    return .{ .addr = start + y * stride, .suppress_pan = false };
}

/// The horizontal pixel-pan amount in OUTPUT pixels for a non-256-color (planar/text/
/// CGA) family: AC 0x13 bits 3-0 directly (§2.6). Suppressed (0) on the bottom split.
inline fn planarPan(vga: *const Vga, suppress: bool) u32 {
    if (suppress) return 0;
    return vga.pixelPan();
}

/// The horizontal pixel-pan amount in OUTPUT pixels for a 256-color family: AC 0x13
/// honors only bits 2-0, DOUBLED (`pan*2`, §2.6 / spice86 `Renderer.cs:439`). Suppressed
/// (0) on the bottom split.
inline fn pan256(vga: *const Vga, suppress: bool) u32 {
    if (suppress) return 0;
    return @as(u32, vga.pixelPan() & 0x07) * 2;
}

// ===========================================================================
// §3.5 — VGA 256-color (the LAMUT-critical path, rendered FIRST).
// ===========================================================================

/// Mode 13h: linear chained 256-color. `index = vram[start_bytes + y*width + x]`
/// (§3.5 / §2.7 collapsed). Reads `vram[off]` DIRECTLY — chained is stored linearly
/// in plane 0's first 64 KiB, never through the planar decode (the §0 regression rule).
/// Pure: no latch load, no port read.
pub fn render256Linear(vga: *const Vga, width: u32, height: u32, index: []u8) void {
    std.debug.assert(index.len >= width * height);
    // Start address is in word units on hardware; chained mode 13h byte base is
    // start*2 (the byte/word transform, §2.5). The BIOS leaves it 0 for mode 13h; a
    // page-flipping game programs it, and the capture reads the live displayed page.
    const start_bytes: u32 = @as(u32, vga.startAddress()) * 2;
    const split_row = splitLogicalRow(vga);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        // Line-compare split (§2.4): rows at/below the split render from VRAM 0 with
        // panning suppressed; rows above render from start_address (+panning). For the
        // standard mode 13h (line_compare = 0x3FF) split_row > height -> top path only.
        const rb = rowBase(start_bytes, width, y, split_row);
        // 256-color panning honors bits 2-0, doubled (§2.6). Output pixel x shows the
        // source pixel x+pan (shift left). pan = 0 for the standard modes -> identical.
        const pan = pan256(vga, rb.suppress_pan);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const off = (rb.addr + x + pan) & (vga_mod.VRAM_SIZE - 1); // wrap to the slab
            index[y * width + x] = vga.vram[off];
        }
    }
}

/// Mode-X / Mode-Y: unchained planar 256-color. The de-interleave is the inverse of
/// the Phase-3 planar write decode (§3.5): `plane = x & 3`, `addr = start + y*stride +
/// (x >> 2)`, `index = vram[plane*PLANE_SIZE + addr]`. Reads the 4 planes DIRECTLY
/// from the plane-major slab — NOT through `memRead8` (which would load the 4 latches,
/// a forbidden side effect, §5.1). The 8-bit index goes straight to the DAC (no AC).
pub fn render256Planar(vga: *const Vga, width: u32, height: u32, index: []u8) void {
    std.debug.assert(index.len >= width * height);
    const start: u32 = vga.startAddress();
    // CRTC Offset is in word units; the per-row byte stride is offset*2. The BIOS
    // Mode-X setup programs offset = width/8 (e.g. 40 for 320-wide), so offset*2 =
    // width/4 = the per-row plane-byte stride. Fall back to width/4 if offset is 0.
    const off_words: u32 = vga.offset();
    const stride: u32 = if (off_words != 0) off_words * 2 else width / 4;
    const split_row = splitLogicalRow(vga);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const rb = rowBase(start, stride, y, split_row);
        const pan = pan256(vga, rb.suppress_pan);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const sx = x + pan; // shift left by pan: output x shows source x+pan
            const plane: u32 = sx & 3;
            const addr = (rb.addr + (sx >> 2)) & (PLANE_SIZE - 1);
            index[y * width + x] = vga.vram[plane * PLANE_SIZE + addr];
        }
    }
}

// ===========================================================================
// §3.1 — Text modes (ROM font + attribute pipeline).
// ===========================================================================

/// Render a text page to an index image at `cols*char_width x rows*char_height`. Each
/// cell: fetch `{char, attr}` from the peeked cell slab; fetch the glyph row from the
/// peeked ROM font; resolve fg/bg through the AC pipeline (§3.6) to final DAC indices.
/// Blink is rendered HIGH (text lit, §6 — never a wall-clock phase); the cursor is
/// drawn SOLID on its shape scanlines. Pure: no port reads, no mutation.
pub fn renderText(vga: *const Vga, mv: ModeView, index: []u8) void {
    const cw: u32 = mv.char_width;
    const ch: u32 = mv.char_height;
    const width: u32 = @as(u32, mv.cols) * cw;
    std.debug.assert(index.len >= width * @as(u32, mv.rows) * ch);
    // AC Mode Control bit 3: blink-enable. When set, attr bit 7 = blink (bg uses
    // bits 4-6); when clear, attr bit 7 = high-intensity background (16 bg colors).
    const blink_enabled = (vga.attr.regs[0x10] & 0x08) != 0;

    // Line-compare split, in RASTER lines (§2.4). The bottom split's cell address
    // resets to cell row 0; in text mode panning is also suppressed below it. For the
    // standard text modes line_compare = 0x3FF -> split_raster > total height, so the
    // remap is the identity and the standard-mode output is byte-identical.
    const lc: u32 = vga.lineCompare();
    const split_raster: u32 = lc + 1;

    var r: u32 = 0;
    while (r < mv.rows) : (r += 1) {
        var c: u32 = 0;
        while (c < mv.cols) : (c += 1) {
            const cell_i = (r * mv.cols + c) * 2;
            const glyph: u8 = if (cell_i < mv.text_cells.len) mv.text_cells[cell_i] else 0;
            const attr: u8 = if (cell_i + 1 < mv.text_cells.len) mv.text_cells[cell_i + 1] else 0x07;

            const fg_idx: u8 = attr & 0x0F;
            const bg_idx: u8 = if (blink_enabled) (attr >> 4) & 0x07 else (attr >> 4) & 0x0F;
            const fg_dac = acResolve(vga, fg_idx);
            const bg_dac = acResolve(vga, bg_idx);

            const on_cursor = mv.cursor_visible and r == mv.cursor_row and c == mv.cursor_col;

            var sl: u32 = 0;
            while (sl < ch) : (sl += 1) {
                // Glyph row byte (MSB = leftmost pixel). The font slab is
                // 256 * char_height bytes; index = char*char_height + scanline.
                const grow_i = @as(u32, glyph) * ch + sl;
                const grow: u8 = if (grow_i < mv.font.len) mv.font[grow_i] else 0;
                // The cursor overlay: on its shape scanlines the whole cell row is fg.
                const cursor_row_on = on_cursor and sl >= mv.cursor_start and sl <= mv.cursor_end;

                var px: u32 = 0;
                while (px < cw) : (px += 1) {
                    // 9-dot text: the 9th column replicates bit 0 of the 8-bit glyph
                    // only for the line-graphics range (0xC0-0xDF), else background
                    // (§3.1). Columns 0-7 are the glyph bits MSB-first.
                    var lit: bool = undefined;
                    if (px < 8) {
                        lit = (grow >> @intCast(7 - px)) & 1 != 0;
                    } else {
                        lit = (glyph >= 0xC0 and glyph <= 0xDF) and ((grow & 1) != 0);
                    }
                    if (cursor_row_on) lit = true;
                    const out_x = c * cw + px;
                    const out_y = r * ch + sl;
                    index[out_y * width + out_x] = if (lit) fg_dac else bg_dac;
                }
            }
        }
    }

    // Post-pass: line-compare split + pixel panning (§2.4 / §2.6). The loop above wrote
    // the NATURAL (unpanned, unsplit) grid; this remaps it into the displayed image. For
    // the standard text modes (line_compare = 0x3FF, pan = 0) both transforms are the
    // identity, so `index` is left byte-for-byte as the natural grid (the regression
    // rule). Text panning shifts the characters left by N pixels (all 4 bits, §2.6); the
    // bottom split suppresses panning and reads cell row 0 onward.
    const total_h: u32 = @as(u32, mv.rows) * ch;
    const pan_top: u32 = vga.pixelPan();
    if (pan_top == 0 and split_raster >= total_h) return; // standard-mode fast path
    // One scratch row of the natural image, then write the displayed row back. The
    // widest text mode is 720 px (90 cols * 8, or 80 * 9); MAX_WIDTH covers it.
    var scratch: [MAX_TEXT_WIDTH]u8 = undefined;
    var oy: u32 = total_h; // iterate from the BOTTOM up so a split shift never reads an
    // already-overwritten source row (the bottom split's source rows are ABOVE oy).
    while (oy > 0) {
        oy -= 1;
        const below_split = oy >= split_raster;
        const src_y = if (below_split) oy - split_raster else oy;
        const pan = if (below_split) 0 else pan_top;
        const src_row = index[src_y * width ..][0..width];
        @memcpy(scratch[0..width], src_row);
        var ox: u32 = 0;
        while (ox < width) : (ox += 1) {
            const sx = ox + pan;
            // Beyond the rendered row width the hardware would show the next (off-screen)
            // char column; we replicate the last natural column as the faithful edge.
            index[oy * width + ox] = if (sx < width) scratch[sx] else scratch[width - 1];
        }
    }
}

// ===========================================================================
// §3.4 — EGA 16-color planar (modes 0Dh-12h).
// ===========================================================================

/// EGA 16-color planar: each pixel's 4-bit index is assembled one bit per plane at the
/// same byte address (§3.4): `index4 = p3p2p1p0[bit]`, `bit = 7 - (x & 7)`. Reads the
/// 4 planes DIRECTLY from the plane-major slab (no latch load). The 4-bit index goes
/// through the AC pipeline (§3.6) to a final DAC index. Pure.
pub fn renderEga(vga: *const Vga, width: u32, height: u32, index: []u8) void {
    std.debug.assert(index.len >= width * height);
    const start: u32 = vga.startAddress();
    const off_words: u32 = vga.offset();
    const stride: u32 = if (off_words != 0) off_words * 2 else width / 8;
    const split_row = splitLogicalRow(vga);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const rb = rowBase(start, stride, y, split_row);
        // Planar/text panning honors all 4 bits (§2.6). Output x shows source x+pan.
        const pan = planarPan(vga, rb.suppress_pan);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const sx = x + pan;
            const addr = (rb.addr + (sx >> 3)) & (PLANE_SIZE - 1);
            const bit: u3 = @intCast(7 - (sx & 7));
            var index4: u8 = 0;
            inline for (0..4) |p| {
                const pb = vga.vram[p * PLANE_SIZE + addr];
                index4 |= @as(u8, (pb >> bit) & 1) << p;
            }
            index[y * width + x] = acResolve(vga, index4);
        }
    }
}

// ===========================================================================
// §3.3 — CGA graphics (modes 4/5 = 320x200x2bpp, 6 = 640x200x1bpp).
// ===========================================================================

/// CGA 1bpp (mode 6) / 2bpp (modes 4/5). CGA uses interleaved scanline banks: even
/// rows at offset 0x0000, odd rows at 0x2000 (the CGA-compat bit-13 wrap, §2.5/§3.3),
/// stored in plane 0 of the slab (the BIOS chains it linearly there for CGA emulation).
/// The packed bits expand to the 2/4 CGA colors, routed through the AC->DAC (§3.3).
/// `bpp` is 1 (mode 6) or 2 (modes 4/5). Pure.
pub fn renderCga(vga: *const Vga, width: u32, height: u32, bpp: u8, index: []u8) void {
    std.debug.assert(index.len >= width * height);
    std.debug.assert(bpp == 1 or bpp == 2);
    // Bytes per CGA scanline: 80 for both families (320*2bpp/8 = 80, 640*1bpp/8 = 80).
    const bytes_per_line: u32 = (width * bpp) / 8;
    const split_row = splitLogicalRow(vga);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        // Line-compare split (§2.4): below the compare line the address counter resets,
        // so the bottom split's effective row counts from the split start. Above it, the
        // row is `y` directly. For the standard CGA modes (line_compare = 0x3FF) the
        // split never fires -> ey == y -> the bank addressing is byte-identical.
        const suppress = y >= split_row;
        const ey = if (suppress) y - split_row else y;
        // Interleaved banks: even row -> 0x0000+, odd row -> 0x2000+.
        const bank: u32 = if (ey & 1 == 0) 0 else 0x2000;
        const row_off = bank + (ey >> 1) * bytes_per_line;
        // CGA panning is in pixels (planar-style, all bits, §2.6); suppressed on the
        // bottom split. pan = 0 for the standard modes -> identical.
        const pan = planarPan(vga, suppress);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const sx = x + pan;
            var pix: u8 = undefined;
            if (bpp == 1) {
                const byte = vga.vram[(row_off + (sx >> 3)) & (PLANE_SIZE - 1)];
                pix = (byte >> @intCast(7 - (sx & 7))) & 1;
            } else {
                const byte = vga.vram[(row_off + (sx >> 2)) & (PLANE_SIZE - 1)];
                const shift: u3 = @intCast(6 - 2 * (sx & 3));
                pix = (byte >> shift) & 3;
            }
            index[y * width + x] = acResolve(vga, pix);
        }
    }
}

// ===========================================================================
// Mode dispatch + dimension table (§5.2).
// ===========================================================================

/// The logical resolution + kind for a BDA video mode (§5.2 dimension table). Returns
/// null kind=`unsupported` for a mode with no faithful rasterizer wired — the caller
/// surfaces that with a LOUD signal (never a silent wrong image).
pub const Dims = struct { width: u16, height: u16, kind: Kind, bpp: u8 = 0 };

pub fn dimsForMode(mv: ModeView) Dims {
    return switch (mv.mode) {
        // Text modes — logical = cols*char_width x rows*char_height.
        0, 1, 2, 3, 7 => .{
            .width = @intCast(@as(u32, mv.cols) * mv.char_width),
            .height = @intCast(@as(u32, mv.rows) * mv.char_height),
            .kind = .text,
        },
        0x04, 0x05 => .{ .width = 320, .height = 200, .kind = .cga, .bpp = 2 },
        0x06 => .{ .width = 640, .height = 200, .kind = .cga, .bpp = 1 },
        0x0D => .{ .width = 320, .height = 200, .kind = .ega16 },
        0x0E => .{ .width = 640, .height = 200, .kind = .ega16 },
        0x0F, 0x10 => .{ .width = 640, .height = 350, .kind = .ega16 },
        0x11, 0x12 => .{ .width = 640, .height = 480, .kind = .ega16 },
        0x13 => .{ .width = 320, .height = 200, .kind = .vga256_linear },
        else => .{ .width = 0, .height = 0, .kind = .unsupported },
    };
}

/// Render the current mode into `index` and produce a descriptor. For mode 13h the
/// chained/unchained choice is the SEQ chain-4 bit (`vga.chained()`): chained ->
/// `render256Linear`, unchained -> `render256Planar` (Mode-X). Returns a descriptor
/// with `kind = .unsupported` (and zero dims) if no rasterizer is wired — the caller
/// must check and surface it (never stream a wrong frame). Pure (const `vga`).
pub fn render(vga: *const Vga, mv: ModeView, index: []u8) Descriptor {
    var d = dimsForMode(mv);
    // For VGA 256-color, the chain-4 SEQ bit decides linear vs Mode-X de-interleave.
    if (d.kind == .vga256_linear and !vga.chained()) d.kind = .vga256_planar;

    const width: u32 = d.width;
    const height: u32 = d.height;
    switch (d.kind) {
        .vga256_linear => render256Linear(vga, width, height, index),
        .vga256_planar => render256Planar(vga, width, height, index),
        .text => renderText(vga, mv, index),
        .ega16 => renderEga(vga, width, height, index),
        .cga => renderCga(vga, width, height, d.bpp, index),
        .unsupported => return .{
            .kind = .unsupported,
            .width = 0,
            .height = 0,
            .index_len = 0,
            .rgba_len = 0,
            .double_scan = false,
            .row_repeat = 1,
        },
    }
    return .{
        .kind = d.kind,
        .width = d.width,
        .height = d.height,
        .index_len = width * height,
        .rgba_len = width * height * 4,
        .double_scan = doubleScan(vga),
        .row_repeat = rowRepeat(vga),
    };
}
