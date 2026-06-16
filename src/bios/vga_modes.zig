//! Per-mode VGA register parameter tables (Phase 2, plans/vga-spec/04-modes-int10-bda.md §1.2).
//!
//! The literal register blocks are the IBM/clone VGA BIOS POST mode tables, copied
//! VERBATIM from spice86's `VgaModes` dictionary
//! (`references/spice86/src/Spice86.Core/Emulator/InterruptHandlers/VGA/Data/RegisterValueSet.cs`:
//! the SequencerRegisterValueSet1..7, CrtControllerRegisterValueSet1..11,
//! AttributeControllerRegisterValueSet1..9, GraphicsControllerRegisterValueSet1..6
//! sets at lines 7-39, and the per-mode assignment at lines 41-58). The geometry
//! (pstart/plength/ptotal) is from dosbox-staging `ModeList_VGA`
//! (`int10_modes.cpp:30-45`); the two references agree byte-for-byte on the v1
//! modes (13h, 03h verified — spec §1.2 cross-check).
//!
//! Set-mode (`int10.zig`) dumps these blocks through the VGA device's register
//! files via the port path, so a BIOS set-mode and a raw-port guest are
//! byte-identical (the zdos faithfulness principle).
//!
//! S1 fix (spec README): the mode-13h CRTC reg9 value 0x41 is dumped verbatim —
//! it is Max-Scan-Line low bit (=1, 2-line row repeat) + line-compare bit 9
//! (bit 6); the double-scan bit (bit 7) is CLEAR. The render layer (Phase 4)
//! interprets it; set-mode just writes the table byte.
//!
//! Determinism (CLAUDE #5): fixed comptime data — no host clock, RNG, or float.

const std = @import("std");

/// Memory model selected by a mode (drives the VRAM-clear style + window base).
pub const MemModel = enum { text, cga, planar, packed_256 };

/// Which default DAC palette set-mode loads (the bytes live in `vga_palettes.zig`).
pub const PaletteId = enum { ega, cga, vga, mono };

/// One standard video mode's full register program + geometry.
pub const ModeEntry = struct {
    mode: u8,
    model: MemModel,
    width: u16, // pixel width
    height: u16, // pixel height
    twidth: u8, // text columns
    theight: u8, // text rows
    cwidth: u8, // char cell width (9 text, 8 graphics)
    cheight: u8, // char cell height (16/14/8)
    pstart: u32, // VRAM window base (0xB8000/0xB0000/0xA0000)
    plength: u16, // page size bytes
    ptotal: u8, // page count
    misc_output: u8, // 0x3C2 value
    seq: [5]u8, // sequencer regs 0..4
    crtc: [25]u8, // CRTC regs 0..0x18
    attr: [21]u8, // attribute regs 0..0x14
    gfx: [9]u8, // graphics-controller regs 0..8
    pixel_mask: u8, // DAC pel mask (always 0xFF)
    palette: PaletteId,
};

// ---------------------------------------------------------------------------
// Deduplicated register-value sets (RegisterValueSet.cs:7-39). Names match the
// reference 1:1 for auditability.
// ---------------------------------------------------------------------------

// SequencerRegisterValueSet1..7 (RegisterValueSet.cs:7-13).
const SEQ1 = [5]u8{ 0x03, 0x08, 0x03, 0x00, 0x02 };
const SEQ2 = [5]u8{ 0x03, 0x00, 0x03, 0x00, 0x02 };
const SEQ3 = [5]u8{ 0x03, 0x09, 0x03, 0x00, 0x02 };
const SEQ4 = [5]u8{ 0x03, 0x01, 0x01, 0x00, 0x06 };
const SEQ5 = [5]u8{ 0x03, 0x09, 0x0f, 0x00, 0x06 };
const SEQ6 = [5]u8{ 0x03, 0x01, 0x0f, 0x00, 0x06 };
const SEQ7 = [5]u8{ 0x03, 0x01, 0x0f, 0x00, 0x0e };

// CrtControllerRegisterValueSet1..11 (RegisterValueSet.cs:14-24).
const CRTC1 = [25]u8{ 0x2d, 0x27, 0x28, 0x90, 0x2b, 0xa0, 0xbf, 0x1f, 0x00, 0x4f, 0x0d, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x14, 0x1f, 0x96, 0xb9, 0xa3, 0xff };
const CRTC2 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x55, 0x81, 0xbf, 0x1f, 0x00, 0x4f, 0x0d, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x1f, 0x96, 0xb9, 0xa3, 0xff };
const CRTC3 = [25]u8{ 0x2d, 0x27, 0x28, 0x90, 0x2b, 0x80, 0xbf, 0x1f, 0x00, 0xc1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x14, 0x00, 0x96, 0xb9, 0xa2, 0xff };
const CRTC4 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0xc1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x00, 0x96, 0xb9, 0xc2, 0xff };
const CRTC5 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x55, 0x81, 0xbf, 0x1f, 0x00, 0x4f, 0x0d, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x0f, 0x96, 0xb9, 0xa3, 0xff };
const CRTC6 = [25]u8{ 0x2d, 0x27, 0x28, 0x90, 0x2b, 0x80, 0xbf, 0x1f, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x14, 0x00, 0x96, 0xb9, 0xe3, 0xff };
const CRTC7 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x00, 0x96, 0xb9, 0xe3, 0xff };
const CRTC8 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x83, 0x85, 0x5d, 0x28, 0x0f, 0x63, 0xba, 0xe3, 0xff };
const CRTC9 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0x0b, 0x3e, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xea, 0x8c, 0xdf, 0x28, 0x00, 0xe7, 0x04, 0xe3, 0xff };
const CRTC10 = [25]u8{ 0x5f, 0x4f, 0x50, 0x82, 0x54, 0x80, 0xbf, 0x1f, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x8e, 0x8f, 0x28, 0x40, 0x96, 0xb9, 0xa3, 0xff };

// AttributeControllerRegisterValueSet1..9 (RegisterValueSet.cs:25-33).
const ATTR1 = [21]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x0c, 0x00, 0x0f, 0x08, 0x00 };
const ATTR2 = [21]u8{ 0x00, 0x13, 0x15, 0x17, 0x02, 0x04, 0x06, 0x07, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x01, 0x00, 0x03, 0x00, 0x00 };
const ATTR3 = [21]u8{ 0x00, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x17, 0x01, 0x00, 0x01, 0x00, 0x00 };
const ATTR4 = [21]u8{ 0x00, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x10, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x0e, 0x00, 0x0f, 0x08, 0x00 };
const ATTR5 = [21]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x01, 0x00, 0x0f, 0x00, 0x00 };
const ATTR6 = [21]u8{ 0x00, 0x08, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00 };
const ATTR7 = [21]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x01, 0x00, 0x0f, 0x00, 0x00 };
const ATTR8 = [21]u8{ 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x00, 0x3f, 0x01, 0x00, 0x0f, 0x00, 0x00 };
const ATTR9 = [21]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x41, 0x00, 0x0f, 0x00, 0x00 };

// GraphicsControllerRegisterValueSet1..6 (RegisterValueSet.cs:34-39).
const GFX1 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0e, 0x0f, 0xff };
const GFX2 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x0f, 0x0f, 0xff };
const GFX3 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x0f, 0xff };
const GFX4 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0a, 0x0f, 0xff };
const GFX5 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x0f, 0xff };
const GFX6 = [9]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0f, 0xff };

// VRAM window bases (dosbox ModeList_VGA pstart, int10_modes.cpp:30-45).
const SEG_COLOR_TEXT: u32 = 0xB8000;
const SEG_MONO_TEXT: u32 = 0xB0000;
const SEG_GRAPHICS: u32 = 0xA0000;

/// The standard mode table (RegisterValueSet.cs:42-57 + the geometry columns from
/// dosbox ModeList_VGA). 800x600 mode 0x6A is intentionally omitted (not a
/// standard INT 10h mode; spice86 carries it for an extended set zdos does not).
pub const modes = [_]ModeEntry{
    .{ .mode = 0x00, .model = .text, .width = 360, .height = 400, .twidth = 40, .theight = 25, .cwidth = 9, .cheight = 16, .pstart = SEG_COLOR_TEXT, .plength = 0x0800, .ptotal = 8, .misc_output = 0x67, .seq = SEQ1, .crtc = CRTC1, .attr = ATTR1, .gfx = GFX1, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x01, .model = .text, .width = 360, .height = 400, .twidth = 40, .theight = 25, .cwidth = 9, .cheight = 16, .pstart = SEG_COLOR_TEXT, .plength = 0x0800, .ptotal = 8, .misc_output = 0x67, .seq = SEQ1, .crtc = CRTC1, .attr = ATTR1, .gfx = GFX1, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x02, .model = .text, .width = 720, .height = 400, .twidth = 80, .theight = 25, .cwidth = 9, .cheight = 16, .pstart = SEG_COLOR_TEXT, .plength = 0x1000, .ptotal = 8, .misc_output = 0x67, .seq = SEQ2, .crtc = CRTC2, .attr = ATTR1, .gfx = GFX1, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x03, .model = .text, .width = 720, .height = 400, .twidth = 80, .theight = 25, .cwidth = 9, .cheight = 16, .pstart = SEG_COLOR_TEXT, .plength = 0x1000, .ptotal = 8, .misc_output = 0x67, .seq = SEQ2, .crtc = CRTC2, .attr = ATTR1, .gfx = GFX1, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x04, .model = .cga, .width = 320, .height = 200, .twidth = 40, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_COLOR_TEXT, .plength = 0x4000, .ptotal = 1, .misc_output = 0x63, .seq = SEQ3, .crtc = CRTC3, .attr = ATTR2, .gfx = GFX2, .pixel_mask = 0xFF, .palette = .cga },
    .{ .mode = 0x05, .model = .cga, .width = 320, .height = 200, .twidth = 40, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_COLOR_TEXT, .plength = 0x4000, .ptotal = 1, .misc_output = 0x63, .seq = SEQ3, .crtc = CRTC3, .attr = ATTR2, .gfx = GFX2, .pixel_mask = 0xFF, .palette = .cga },
    .{ .mode = 0x06, .model = .cga, .width = 640, .height = 200, .twidth = 80, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_COLOR_TEXT, .plength = 0x4000, .ptotal = 1, .misc_output = 0x63, .seq = SEQ4, .crtc = CRTC4, .attr = ATTR3, .gfx = GFX3, .pixel_mask = 0xFF, .palette = .cga },
    .{ .mode = 0x07, .model = .text, .width = 720, .height = 400, .twidth = 80, .theight = 25, .cwidth = 9, .cheight = 16, .pstart = SEG_MONO_TEXT, .plength = 0x1000, .ptotal = 8, .misc_output = 0x66, .seq = SEQ2, .crtc = CRTC5, .attr = ATTR4, .gfx = GFX4, .pixel_mask = 0xFF, .palette = .mono },
    .{ .mode = 0x0D, .model = .planar, .width = 320, .height = 200, .twidth = 40, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_GRAPHICS, .plength = 0x2000, .ptotal = 8, .misc_output = 0x63, .seq = SEQ5, .crtc = CRTC6, .attr = ATTR5, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .cga },
    .{ .mode = 0x0E, .model = .planar, .width = 640, .height = 200, .twidth = 80, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_GRAPHICS, .plength = 0x4000, .ptotal = 4, .misc_output = 0x63, .seq = SEQ6, .crtc = CRTC7, .attr = ATTR5, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .cga },
    .{ .mode = 0x0F, .model = .planar, .width = 640, .height = 350, .twidth = 80, .theight = 25, .cwidth = 8, .cheight = 14, .pstart = SEG_GRAPHICS, .plength = 0x8000, .ptotal = 2, .misc_output = 0xa3, .seq = SEQ6, .crtc = CRTC8, .attr = ATTR6, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .mono },
    .{ .mode = 0x10, .model = .planar, .width = 640, .height = 350, .twidth = 80, .theight = 25, .cwidth = 8, .cheight = 14, .pstart = SEG_GRAPHICS, .plength = 0x8000, .ptotal = 2, .misc_output = 0xa3, .seq = SEQ6, .crtc = CRTC8, .attr = ATTR7, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x11, .model = .planar, .width = 640, .height = 480, .twidth = 80, .theight = 30, .cwidth = 8, .cheight = 16, .pstart = SEG_GRAPHICS, .plength = 0xA000, .ptotal = 1, .misc_output = 0xe3, .seq = SEQ6, .crtc = CRTC9, .attr = ATTR8, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x12, .model = .planar, .width = 640, .height = 480, .twidth = 80, .theight = 30, .cwidth = 8, .cheight = 16, .pstart = SEG_GRAPHICS, .plength = 0xA000, .ptotal = 1, .misc_output = 0xe3, .seq = SEQ6, .crtc = CRTC9, .attr = ATTR7, .gfx = GFX5, .pixel_mask = 0xFF, .palette = .ega },
    .{ .mode = 0x13, .model = .packed_256, .width = 320, .height = 200, .twidth = 40, .theight = 25, .cwidth = 8, .cheight = 8, .pstart = SEG_GRAPHICS, .plength = 0x2000, .ptotal = 1, .misc_output = 0x63, .seq = SEQ7, .crtc = CRTC10, .attr = ATTR9, .gfx = GFX6, .pixel_mask = 0xFF, .palette = .vga },
};

/// Look up a mode entry by BIOS mode number; null if unsupported (set-mode must
/// flag rather than fake 13h — spec §1.3 step 2).
pub fn find(mode: u8) ?*const ModeEntry {
    for (&modes) |*e| {
        if (e.mode == mode) return e;
    }
    return null;
}

test "mode 13h table matches the spec §1.2 block" {
    const e = find(0x13).?;
    try std.testing.expectEqual(@as(u8, 0x63), e.misc_output);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x01, 0x0f, 0x00, 0x0e }, &e.seq);
    try std.testing.expectEqual(@as(u8, 0x41), e.crtc[9]);
    try std.testing.expectEqual(@as(u8, 0x40), e.gfx[5]);
    try std.testing.expectEqual(@as(u8, 0x41), e.attr[0x10]);
    try std.testing.expectEqual(MemModel.packed_256, e.model);
    try std.testing.expectEqual(PaletteId.vga, e.palette);
}

test "mode 03h text geometry + register block" {
    const e = find(0x03).?;
    try std.testing.expectEqual(@as(u8, 0x67), e.misc_output);
    try std.testing.expectEqual(@as(u8, 80), e.twidth);
    try std.testing.expectEqual(@as(u16, 0x1000), e.plength);
    try std.testing.expectEqual(@as(u32, 0xB8000), e.pstart);
    try std.testing.expectEqual(@as(u8, 0x4f), e.crtc[9]); // CRTC2 reg9
}

test "unsupported mode returns null" {
    try std.testing.expectEqual(@as(?*const ModeEntry, null), find(0x6A));
}
