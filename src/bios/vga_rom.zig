//! VGA BIOS save-pointer ROM chain (Phase 5c, plans/vga-spec/04-modes-int10-bda.md §3.3).
//!
//! Real VGA BIOS stages, in ROM, a chain of fixed tables reachable via the IVT
//! (INT 1Dh video-parameter-table) and the BDA video-save-pointer (0040:00A8):
//!   - the video parameter table        (INT 1Dh target)
//!   - the DCC (display-combination-code) table   — AH=1A walks it
//!   - the static-functionality table             — AH=1B's +0 far pointer
//!   - the video-save-pointer-table-2 (7 dwords: parameter table, dynamic save
//!     area, alpha/graphics charset overrides, save-pointer-table-2, reserved)
//!
//! The byte values are copied VERBATIM from dosbox-staging's
//! `INT10_SetupRomMemory` (`references/dosbox-staging/src/ints/int10_memory.cpp`):
//!   - static_functionality[0x10]      `int10_memory.cpp:11-25`
//!   - DCC table (count/version/max/16 codes) `int10_memory.cpp:282-302`
//!   - video_save_pointer_table (0x1A bytes) `int10_memory.cpp:304-315`
//!   - video_save_pointers (7 dwords)        `int10_memory.cpp:318-334`
//! zdos uses the simplified inline AH=1A/1B paths (the BDA DCC byte + a direct
//! BDA copy), so the chain is needed only to back AH=1B's +0 static-state pointer,
//! AH=1A's table, and a non-zero BDA VS_POINTER. The video parameter table is a
//! fixed placeholder (guests only test it for non-NULL / version != 0).
//!
//! These are staged into BIOS ROM space at POST (see `stage`) at fixed offsets in
//! the F000 segment, after the staged fonts (int10.zig FONT*_OFF). The BDA
//! VS_POINTER 0040:00A8 + IVT[0x1D] are pointed at them in `bios.post`.
//!
//! Determinism (CLAUDE #5): fixed comptime data — no host clock, RNG, or float.

const std = @import("std");

/// BIOS ROM segment the tables live in (same as the fonts; F000 is ROM, guest
/// writes are dropped, so the bytes are planted into the image before loadRom).
pub const ROM_SEG: u16 = 0xF000;

/// Offsets within the F000 segment, after the staged fonts (font8 ends at
/// FONT8_OFF + 2048 = 0x4800). Picked at 0x5000 to leave headroom. Each table is
/// paragraph-friendly; the layout is fixed (deterministic).
pub const PARAM_OFF: u16 = 0x5000; // video parameter table (placeholder)
pub const PARAM_LEN: u16 = 0x40; // a 64-byte non-NULL block
pub const STATIC_FUNC_OFF: u16 = PARAM_OFF + PARAM_LEN; // 0x5040
pub const STATIC_FUNC_LEN: u16 = 0x10;
pub const DCC_OFF: u16 = STATIC_FUNC_OFF + STATIC_FUNC_LEN; // 0x5050
pub const DCC_LEN: u16 = 4 + 16 * 2; // header (4) + 16 combination words
pub const SP_TABLE2_OFF: u16 = DCC_OFF + DCC_LEN; // 0x5074 (save-pointer-table-2)
pub const SP_TABLE2_LEN: u16 = 2 + 6 * 4; // length word + 6 dwords
pub const VS_POINTER_OFF: u16 = SP_TABLE2_OFF + SP_TABLE2_LEN; // 0x5090 (the 7-dword table)
pub const VS_POINTER_LEN: u16 = 7 * 4;

/// Physical addresses (F000:off) of the tables the BIOS points the IVT/BDA at.
pub const PARAM_PHYS: u32 = (@as(u32, ROM_SEG) << 4) + PARAM_OFF;
pub const STATIC_FUNC_PHYS: u32 = (@as(u32, ROM_SEG) << 4) + STATIC_FUNC_OFF;
pub const DCC_PHYS: u32 = (@as(u32, ROM_SEG) << 4) + DCC_OFF;
pub const VS_POINTER_PHYS: u32 = (@as(u32, ROM_SEG) << 4) + VS_POINTER_OFF;

/// The static-functionality table (dosbox `static_functionality`,
/// int10_memory.cpp:11-25). The 16-byte capability bitmap AH=1B's +0 ptr targets.
pub const static_functionality = [STATIC_FUNC_LEN]u8{
    0xff, // 0: all modes supported #1
    0xff, // 1: all modes supported #2
    0x0f, // 2: all modes supported #3
    0x00, 0x00, 0x00, 0x00, // 3-6: reserved
    0x07, // 7: 200/350/400 scan lines
    0x04, // 8: total character blocks in text modes
    0x02, // 9: max active character blocks in text modes
    0xff, // a: misc flags — everything supported
    0x0e, // b: DCC + intensity/blink + state save/restore supported
    0x00, 0x00, 0x00, 0x00, // c-f: reserved
};

/// The 16 display-combination-code words (dosbox int10_memory.cpp:287-302).
const dcc_codes = [16]u16{
    0x0000, 0x0100, 0x0200, 0x0102, 0x0400, 0x0104, 0x0500, 0x0502,
    0x0600, 0x0601, 0x0605, 0x0800, 0x0801, 0x0700, 0x0702, 0x0706,
};

/// A little-endian word store into the BIOS image (indexed from F0000).
inline fn w16(image: []u8, off: u16, v: u16) void {
    std.mem.writeInt(u16, image[off..][0..2], v, .little);
}
/// A little-endian dword store (a real-mode far pointer is off:seg = lo:hi word).
inline fn w32(image: []u8, off: u16, v: u32) void {
    std.mem.writeInt(u32, image[off..][0..4], v, .little);
}

/// Stage the save-pointer ROM chain into the BIOS image (indexed from 0xF0000,
/// matching `int10.stageFonts`). Called by the machine BEFORE `loadRom`. All
/// values are the fixed dosbox/spice86 IBM VGA BIOS tables (§3.3).
pub fn stage(image: []u8) void {
    // --- Video parameter table (placeholder, non-NULL). Real BIOS fills per-mode
    // CRTC timing here; zdos sets modes from vga_modes directly, so this only has
    // to be a real readable block (guests test bx != 0). Mark it with a version
    // byte so a probe sees structure, not zeros. ---
    @memset(image[PARAM_OFF .. PARAM_OFF + PARAM_LEN], 0);
    image[PARAM_OFF] = 0x01; // a non-zero leading byte (version-ish marker)

    // --- Static-functionality table (AH=1B +0 target). ---
    @memcpy(image[STATIC_FUNC_OFF .. STATIC_FUNC_OFF + STATIC_FUNC_LEN], &static_functionality);

    // --- DCC table: header {count=0x10, version=1, max-code=8, reserved} then the
    // 16 combination words (AH=1A walks this; the standard VGA-color entry is
    // 0x08). int10_memory.cpp:282-302. ---
    image[DCC_OFF + 0] = 0x10; // number of entries
    image[DCC_OFF + 1] = 0x01; // version
    image[DCC_OFF + 2] = 0x08; // maximum display code
    image[DCC_OFF + 3] = 0x00; // reserved
    for (dcc_codes, 0..) |code, i| {
        w16(image, DCC_OFF + 4 + @as(u16, @intCast(i)) * 2, code);
    }

    // --- Save-pointer-table-2 (int10_memory.cpp:304-315): a length word then 6
    // dwords; [0] -> the DCC table, the rest reserved (0). This is entry [4] of the
    // 7-dword video-save-pointer table below. ---
    w16(image, SP_TABLE2_OFF, 0x1A); // length of table
    w32(image, SP_TABLE2_OFF + 2, far(DCC_OFF)); // -> DCC table
    w32(image, SP_TABLE2_OFF + 6, 0); // alphanumeric charset override
    w32(image, SP_TABLE2_OFF + 10, 0); // user palette table
    w32(image, SP_TABLE2_OFF + 14, 0);
    w32(image, SP_TABLE2_OFF + 18, 0);
    w32(image, SP_TABLE2_OFF + 22, 0);

    // --- The video-save-pointer table (7 dwords, int10_memory.cpp:318-334). BDA
    // 0040:00A8 points here. [0] parameter table, [1] dynamic save area, [2] alpha
    // charset override, [3] graphics charset override, [4] save-pointer-table-2
    // (-> DCC), [5][6] reserved. ---
    w32(image, VS_POINTER_OFF + 0, far(PARAM_OFF)); // video parameter table
    w32(image, VS_POINTER_OFF + 4, 0); // dynamic save area
    w32(image, VS_POINTER_OFF + 8, 0); // alphanumeric charset override
    w32(image, VS_POINTER_OFF + 12, 0); // graphics charset override
    w32(image, VS_POINTER_OFF + 16, far(SP_TABLE2_OFF)); // save-pointer-table-2
    w32(image, VS_POINTER_OFF + 20, 0); // reserved
    w32(image, VS_POINTER_OFF + 24, 0); // reserved
}

/// A real-mode far pointer (seg:off) packed as a dword (offset low word, segment
/// high word). All our tables live in ROM_SEG.
inline fn far(off: u16) u32 {
    return (@as(u32, ROM_SEG) << 16) | off;
}

test "static-functionality table matches the dosbox bytes" {
    try std.testing.expectEqual(@as(u8, 0xff), static_functionality[0]);
    try std.testing.expectEqual(@as(u8, 0x0f), static_functionality[2]);
    try std.testing.expectEqual(@as(u8, 0x07), static_functionality[7]);
    try std.testing.expectEqual(@as(u8, 0x0e), static_functionality[0xb]);
}

test "stage writes a non-zero VS pointer + DCC header into the image" {
    var image: [0x10000]u8 = @splat(0);
    stage(&image);
    // VS pointer [0] -> the parameter table (F000:PARAM_OFF), non-zero.
    const vs0 = std.mem.readInt(u32, image[VS_POINTER_OFF..][0..4], .little);
    try std.testing.expectEqual(far(PARAM_OFF), vs0);
    try std.testing.expect(vs0 != 0);
    // DCC header.
    try std.testing.expectEqual(@as(u8, 0x10), image[DCC_OFF]);
    try std.testing.expectEqual(@as(u8, 0x08), image[DCC_OFF + 2]);
}
