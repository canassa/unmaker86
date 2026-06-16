//! Scancode set-1 → BIOS keycode tables for the INT 09h ISR (input Phase 1b).
//!
//! RE-DERIVED FROM THE PUBLIC AT SCANCODE SET-1 SPEC (the IBM PC/AT keyboard
//! technical reference and the public XT/AT make/break tables). This mirrors the
//! bridge's doctrine ("re-derived from the ISA").
//! The values are verified against, but not lifted from, dosbox's
//! `keyboard_scancodes.cpp` / `bios_keyboard.cpp` and spice86 `ScanCode1.cs`.
//!
//! Set-1 encoding (the bytes the 8042 puts on port 0x60):
//!   - a MAKE is the raw scancode (key-down);
//!   - a BREAK is `scancode | 0x80` (key-up);
//!   - an EXTENDED key is preceded by a 0xE0 prefix byte (e.g. right-Ctrl, the gray
//!     cursor cluster, KP-Enter, KP-/); 0xE1 begins the multi-byte Pause sequence.
//!
//! The BIOS-keycode table maps a (scancode, modifier-column) pair to the 16-bit
//! word the BDA ring holds: `(scancode << 8) | ascii`. Four columns:
//!   col 0 = normal, col 1 = shift, col 2 = ctrl, col 3 = alt.
//! A purely-special key (function/cursor) has ascii 0 in every applicable column,
//! so the word is `scancode << 8`. A column value of 0xFFFF means "this key
//! produces nothing in this modifier state" (the ISR enqueues nothing).
//!
//! This table is the *what-to-enqueue* half. The shift-flag state machine (§5.1a,
//! in int09.zig) decides *which column* applies (CapsLock XOR Shift for letters,
//! NumLock for the numpad, etc.) and maintains the lock state — it is a SEPARATE
//! concern from this lookup (input-injection.md §5.1a).
//!
//! Determinism: a comptime fixed array; no allocation, no host time, no float.

const std = @import("std");

/// Sentinel: this key produces no keystroke in this modifier column.
pub const NONE: u16 = 0xFFFF;

/// One key's four modifier columns, in `(scancode<<8)|ascii` form.
pub const Key = struct {
    normal: u16,
    shift: u16,
    ctrl: u16,
    alt: u16,
};

/// The modifier column the state machine selected.
pub const Column = enum(u2) { normal = 0, shift = 1, ctrl = 2, alt = 3 };

/// Build a Key whose four columns share one scancode `sc` with per-column ASCII.
fn k(sc: u8, n: u8, s: u8, c: u16, a: u16) Key {
    const hi = @as(u16, sc) << 8;
    return .{
        .normal = hi | n,
        .shift = hi | s,
        .ctrl = if (c == NONE) NONE else hi | (c & 0xFF),
        .alt = if (a == NONE) NONE else hi | (a & 0xFF),
    };
}

/// A special (non-ASCII) key: every column is the bare scancode word `sc<<8`,
/// except where an explicit Alt code differs (e.g. Alt+function keys shift by 0x2E).
fn special(sc: u8) Key {
    const hi = @as(u16, sc) << 8;
    return .{ .normal = hi, .shift = hi, .ctrl = hi, .alt = hi };
}

/// The highest base scancode the table covers (the main set-1 block, ESC..F12 and
/// the numpad). Codes above this in the non-extended space are unmapped.
pub const TABLE_LEN = 0x59;

/// Scancode set-1 base table, index = make scancode (0x00 unused).
/// Re-derived from the AT set-1 layout + the standard US keyboard ASCII mapping.
pub const table = blk: {
    var t: [TABLE_LEN]Key = undefined;
    for (&t) |*e| e.* = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };

    // 0x01 ESC: 0x1B in normal/shift/ctrl; 0x0100 (no ASCII) on Alt.
    t[0x01] = .{ .normal = 0x011B, .shift = 0x011B, .ctrl = 0x011B, .alt = 0x0100 };

    // ---- number row 0x02..0x0D (1234567890-=) ----
    // ctrl on the number row mostly produces nothing; alt yields the scancode word.
    t[0x02] = .{ .normal = 0x0231, .shift = 0x0221, .ctrl = NONE, .alt = 0x7800 }; // 1 !
    t[0x03] = .{ .normal = 0x0332, .shift = 0x0340, .ctrl = 0x0300, .alt = 0x7900 }; // 2 @ (ctrl-@ = NUL)
    t[0x04] = .{ .normal = 0x0433, .shift = 0x0423, .ctrl = NONE, .alt = 0x7A00 }; // 3 #
    t[0x05] = .{ .normal = 0x0534, .shift = 0x0524, .ctrl = NONE, .alt = 0x7B00 }; // 4 $
    t[0x06] = .{ .normal = 0x0635, .shift = 0x0625, .ctrl = NONE, .alt = 0x7C00 }; // 5 %
    t[0x07] = .{ .normal = 0x0736, .shift = 0x075E, .ctrl = 0x071E, .alt = 0x7D00 }; // 6 ^ (ctrl-^ = RS)
    t[0x08] = .{ .normal = 0x0837, .shift = 0x0826, .ctrl = NONE, .alt = 0x7E00 }; // 7 &
    t[0x09] = .{ .normal = 0x0938, .shift = 0x092A, .ctrl = NONE, .alt = 0x7F00 }; // 8 *
    t[0x0A] = .{ .normal = 0x0A39, .shift = 0x0A28, .ctrl = NONE, .alt = 0x8000 }; // 9 (
    t[0x0B] = .{ .normal = 0x0B30, .shift = 0x0B29, .ctrl = NONE, .alt = 0x8100 }; // 0 )
    t[0x0C] = .{ .normal = 0x0C2D, .shift = 0x0C5F, .ctrl = 0x0C1F, .alt = 0x8200 }; // - _ (ctrl-_ = US)
    t[0x0D] = .{ .normal = 0x0D3D, .shift = 0x0D2B, .ctrl = NONE, .alt = 0x8300 }; // = +

    // 0x0E Backspace: 0x08; ctrl 0x7F (DEL); alt scancode word.
    t[0x0E] = .{ .normal = 0x0E08, .shift = 0x0E08, .ctrl = 0x0E7F, .alt = 0x0E00 };
    // 0x0F Tab: 0x09; shift = back-tab 0x0F00; ctrl 0x9400 (ext); alt 0xA500 (ext).
    t[0x0F] = .{ .normal = 0x0F09, .shift = 0x0F00, .ctrl = 0x9400, .alt = 0xA500 };

    // ---- QWERTY row 0x10..0x1B (qwertyuiop[]) ----
    // letters: ctrl = letter & 0x1F (control code), alt = scancode<<8 (alt code).
    t[0x10] = k(0x10, 'q', 'Q', 0x11, 0x1000); // q
    t[0x11] = k(0x11, 'w', 'W', 0x17, 0x1100); // w
    t[0x12] = k(0x12, 'e', 'E', 0x05, 0x1200); // e
    t[0x13] = k(0x13, 'r', 'R', 0x12, 0x1300); // r
    t[0x14] = k(0x14, 't', 'T', 0x14, 0x1400); // t
    t[0x15] = k(0x15, 'y', 'Y', 0x19, 0x1500); // y
    t[0x16] = k(0x16, 'u', 'U', 0x15, 0x1600); // u
    t[0x17] = k(0x17, 'i', 'I', 0x09, 0x1700); // i
    t[0x18] = k(0x18, 'o', 'O', 0x0F, 0x1800); // o
    t[0x19] = k(0x19, 'p', 'P', 0x10, 0x1900); // p
    t[0x1A] = .{ .normal = 0x1A5B, .shift = 0x1A7B, .ctrl = 0x1A1B, .alt = NONE }; // [ { (ctrl-[ = ESC)
    t[0x1B] = .{ .normal = 0x1B5D, .shift = 0x1B7D, .ctrl = 0x1B1D, .alt = NONE }; // ] } (ctrl-] = GS)

    // 0x1C Enter: 0x0D; ctrl 0x0A (LF); alt 0xA600 (ext).
    t[0x1C] = .{ .normal = 0x1C0D, .shift = 0x1C0D, .ctrl = 0x1C0A, .alt = 0xA600 };
    // 0x1D left-Ctrl: a modifier — no ring word (handled by the flag machine).
    t[0x1D] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };

    // ---- home row 0x1E..0x29 (asdfghjkl;'`) ----
    t[0x1E] = k(0x1E, 'a', 'A', 0x01, 0x1E00); // a
    t[0x1F] = k(0x1F, 's', 'S', 0x13, 0x1F00); // s
    t[0x20] = k(0x20, 'd', 'D', 0x04, 0x2000); // d
    t[0x21] = k(0x21, 'f', 'F', 0x06, 0x2100); // f
    t[0x22] = k(0x22, 'g', 'G', 0x07, 0x2200); // g
    t[0x23] = k(0x23, 'h', 'H', 0x08, 0x2300); // h
    t[0x24] = k(0x24, 'j', 'J', 0x0A, 0x2400); // j
    t[0x25] = k(0x25, 'k', 'K', 0x0B, 0x2500); // k
    t[0x26] = k(0x26, 'l', 'L', 0x0C, 0x2600); // l
    t[0x27] = .{ .normal = 0x273B, .shift = 0x273A, .ctrl = NONE, .alt = NONE }; // ; :
    t[0x28] = .{ .normal = 0x2827, .shift = 0x2822, .ctrl = NONE, .alt = NONE }; // ' "
    t[0x29] = .{ .normal = 0x2960, .shift = 0x297E, .ctrl = NONE, .alt = NONE }; // ` ~

    // 0x2A left-Shift: modifier — no ring word.
    t[0x2A] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };
    // 0x2B backslash | : ctrl-\ = FS (0x1C).
    t[0x2B] = .{ .normal = 0x2B5C, .shift = 0x2B7C, .ctrl = 0x2B1C, .alt = NONE };

    // ---- bottom row 0x2C..0x35 (zxcvbnm,./) ----
    t[0x2C] = k(0x2C, 'z', 'Z', 0x1A, 0x2C00); // z
    t[0x2D] = k(0x2D, 'x', 'X', 0x18, 0x2D00); // x
    t[0x2E] = k(0x2E, 'c', 'C', 0x03, 0x2E00); // c
    t[0x2F] = k(0x2F, 'v', 'V', 0x16, 0x2F00); // v
    t[0x30] = k(0x30, 'b', 'B', 0x02, 0x3000); // b
    t[0x31] = k(0x31, 'n', 'N', 0x0E, 0x3100); // n
    t[0x32] = k(0x32, 'm', 'M', 0x0D, 0x3200); // m
    t[0x33] = .{ .normal = 0x332C, .shift = 0x333C, .ctrl = NONE, .alt = NONE }; // , <
    t[0x34] = .{ .normal = 0x342E, .shift = 0x343E, .ctrl = NONE, .alt = NONE }; // . >
    t[0x35] = .{ .normal = 0x352F, .shift = 0x353F, .ctrl = NONE, .alt = NONE }; // / ?

    // 0x36 right-Shift: modifier — no ring word.
    t[0x36] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };
    // 0x37 KP-* (PrtSc on XT): '*'.
    t[0x37] = .{ .normal = 0x372A, .shift = 0x372A, .ctrl = 0x9600, .alt = NONE };
    // 0x38 left-Alt: modifier — no ring word.
    t[0x38] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };
    // 0x39 Space.
    t[0x39] = .{ .normal = 0x3920, .shift = 0x3920, .ctrl = 0x3920, .alt = 0x3920 };
    // 0x3A CapsLock: lock modifier — no ring word.
    t[0x3A] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };

    // ---- function keys F1..F10 (0x3B..0x44) — pure special; the BIOS keycodes for
    // each modifier state differ (the classic shift/ctrl/alt offsets). ----
    // Normal F1..F10 = 0x3B00..0x4400; Shift = 0x5400..; Ctrl = 0x5E00..; Alt = 0x6800..
    t[0x3B] = .{ .normal = 0x3B00, .shift = 0x5400, .ctrl = 0x5E00, .alt = 0x6800 }; // F1
    t[0x3C] = .{ .normal = 0x3C00, .shift = 0x5500, .ctrl = 0x5F00, .alt = 0x6900 }; // F2
    t[0x3D] = .{ .normal = 0x3D00, .shift = 0x5600, .ctrl = 0x6000, .alt = 0x6A00 }; // F3
    t[0x3E] = .{ .normal = 0x3E00, .shift = 0x5700, .ctrl = 0x6100, .alt = 0x6B00 }; // F4
    t[0x3F] = .{ .normal = 0x3F00, .shift = 0x5800, .ctrl = 0x6200, .alt = 0x6C00 }; // F5
    t[0x40] = .{ .normal = 0x4000, .shift = 0x5900, .ctrl = 0x6300, .alt = 0x6D00 }; // F6
    t[0x41] = .{ .normal = 0x4100, .shift = 0x5A00, .ctrl = 0x6400, .alt = 0x6E00 }; // F7
    t[0x42] = .{ .normal = 0x4200, .shift = 0x5B00, .ctrl = 0x6500, .alt = 0x6F00 }; // F8
    t[0x43] = .{ .normal = 0x4300, .shift = 0x5C00, .ctrl = 0x6600, .alt = 0x7000 }; // F9
    t[0x44] = .{ .normal = 0x4400, .shift = 0x5D00, .ctrl = 0x6700, .alt = 0x7100 }; // F10

    // 0x45 NumLock / 0x46 ScrollLock: lock modifiers — no ring word.
    t[0x45] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };
    t[0x46] = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };

    // ---- numeric keypad 0x47..0x53 ----
    // The "normal" column here is the NumLock-OFF cursor/edit keycode (scancode<<8);
    // the "shift" column is the NumLock-ON (or Shift-override) digit ASCII. The
    // §5.1a NumLock logic in int09.zig selects which applies.
    t[0x47] = .{ .normal = 0x4700, .shift = 0x4737, .ctrl = 0x7700, .alt = NONE }; // Home / 7
    t[0x48] = .{ .normal = 0x4800, .shift = 0x4838, .ctrl = 0x8D00, .alt = NONE }; // Up / 8
    t[0x49] = .{ .normal = 0x4900, .shift = 0x4939, .ctrl = 0x8400, .alt = NONE }; // PgUp / 9
    t[0x4A] = .{ .normal = 0x4A2D, .shift = 0x4A2D, .ctrl = 0x8E00, .alt = NONE }; // KP -
    t[0x4B] = .{ .normal = 0x4B00, .shift = 0x4B34, .ctrl = 0x7300, .alt = NONE }; // Left / 4
    t[0x4C] = .{ .normal = 0x4C00, .shift = 0x4C35, .ctrl = NONE, .alt = NONE }; // Center / 5
    t[0x4D] = .{ .normal = 0x4D00, .shift = 0x4D36, .ctrl = 0x7400, .alt = NONE }; // Right / 6
    t[0x4E] = .{ .normal = 0x4E2B, .shift = 0x4E2B, .ctrl = 0x9000, .alt = NONE }; // KP +
    t[0x4F] = .{ .normal = 0x4F00, .shift = 0x4F31, .ctrl = 0x7500, .alt = NONE }; // End / 1
    t[0x50] = .{ .normal = 0x5000, .shift = 0x5032, .ctrl = 0x9100, .alt = NONE }; // Down / 2
    t[0x51] = .{ .normal = 0x5100, .shift = 0x5133, .ctrl = 0x7600, .alt = NONE }; // PgDn / 3
    t[0x52] = .{ .normal = 0x5200, .shift = 0x5230, .ctrl = 0x9200, .alt = NONE }; // Ins / 0
    t[0x53] = .{ .normal = 0x5300, .shift = 0x532E, .ctrl = 0x9300, .alt = NONE }; // Del / .

    // 0x57 F11 / 0x58 F12 (MF2 extension).
    t[0x57] = .{ .normal = 0x8500, .shift = 0x8700, .ctrl = 0x8900, .alt = 0x8B00 }; // F11
    t[0x58] = .{ .normal = 0x8600, .shift = 0x8800, .ctrl = 0x8A00, .alt = 0x8C00 }; // F12

    break :blk t;
};

/// Extended (0xE0-prefixed) keys → BIOS keycodes. Index is the byte that follows
/// the 0xE0 prefix (the same numeric scancode as its numpad twin). Only the keys a
/// standard program uses are mapped; an unmapped extended code yields NONE.
/// The high byte 0xE0 marker in some BIOS words is applied by INT 16h's classify
/// path; here we emit the canonical extended keycodes (cursor cluster, gray keys).
pub const ext_table = blk: {
    var t: [TABLE_LEN]Key = undefined;
    for (&t) |*e| e.* = .{ .normal = NONE, .shift = NONE, .ctrl = NONE, .alt = NONE };

    // Gray cursor / navigation cluster (0xE0-prefixed). These carry the SAME
    // BIOS keycodes as the numpad cursor keys but are produced regardless of
    // NumLock (the §5.1a machine forces the cursor column for the extended set).
    t[0x47] = .{ .normal = 0x4700, .shift = 0x4700, .ctrl = 0x7700, .alt = 0x9700 }; // Home
    t[0x48] = .{ .normal = 0x4800, .shift = 0x4800, .ctrl = 0x8D00, .alt = 0x9800 }; // Up
    t[0x49] = .{ .normal = 0x4900, .shift = 0x4900, .ctrl = 0x8400, .alt = 0x9900 }; // PgUp
    t[0x4B] = .{ .normal = 0x4B00, .shift = 0x4B00, .ctrl = 0x7300, .alt = 0x9B00 }; // Left
    t[0x4D] = .{ .normal = 0x4D00, .shift = 0x4D00, .ctrl = 0x7400, .alt = 0x9D00 }; // Right
    t[0x4F] = .{ .normal = 0x4F00, .shift = 0x4F00, .ctrl = 0x7500, .alt = 0x9F00 }; // End
    t[0x50] = .{ .normal = 0x5000, .shift = 0x5000, .ctrl = 0x9100, .alt = 0xA000 }; // Down
    t[0x51] = .{ .normal = 0x5100, .shift = 0x5100, .ctrl = 0x7600, .alt = 0xA100 }; // PgDn
    t[0x52] = .{ .normal = 0x5200, .shift = 0x5200, .ctrl = 0x9200, .alt = 0xA200 }; // Ins
    t[0x53] = .{ .normal = 0x5300, .shift = 0x5300, .ctrl = 0x9300, .alt = 0xA300 }; // Del

    // Gray KP-Enter (0xE0 0x1C) and KP-/ (0xE0 0x35): the BIOS marks the high byte
    // 0xE0 so INT 16h's classify path can translate them in place (int16.zig:59).
    t[0x1C] = .{ .normal = 0xE00D, .shift = 0xE00D, .ctrl = 0xE00A, .alt = 0xA600 }; // KP-Enter
    t[0x35] = .{ .normal = 0xE02F, .shift = 0xE02F, .ctrl = 0x9500, .alt = 0xA400 }; // KP-/

    break :blk t;
};

/// Look up the BIOS keycode word for a base (non-extended) scancode in `col`.
/// Returns null if the key is unmapped or produces nothing in that column.
pub fn lookup(scancode: u8, col: Column) ?u16 {
    if (scancode >= TABLE_LEN) return null;
    const w = columnOf(table[scancode], col);
    return if (w == NONE) null else w;
}

/// Look up the BIOS keycode word for an extended (0xE0-prefixed) scancode.
pub fn lookupExt(scancode: u8, col: Column) ?u16 {
    if (scancode >= TABLE_LEN) return null;
    const w = columnOf(ext_table[scancode], col);
    return if (w == NONE) null else w;
}

fn columnOf(key: Key, col: Column) u16 {
    return switch (col) {
        .normal => key.normal,
        .shift => key.shift,
        .ctrl => key.ctrl,
        .alt => key.alt,
    };
}

// ---------------------------------------------------------------------------
// char → scancode(s) reverse resolution (the §5.1 `{"char": "x"}` convenience).
// A *real* reverse map over the table above (NOT a fabricated mapping): we scan
// the normal/shift columns for the ASCII low byte. Returns the make scancode and
// whether Shift is required. Chars with no single set-1 key (or that need more
// than a shift modifier) are reported unmapped — documented, not invented.
// ---------------------------------------------------------------------------
pub const CharResolve = struct {
    scancode: u8,
    shift: bool,
};

/// Resolve a printable ASCII byte to its make scancode + shift requirement by
/// scanning the real table. Letters resolve via their lowercase normal column
/// (Shift selects the uppercase); other printables via normal then shift columns.
pub fn resolveChar(ch: u8) ?CharResolve {
    var sc: u8 = 0x01;
    while (sc < TABLE_LEN) : (sc += 1) {
        const key = table[sc];
        if (key.normal != NONE and (key.normal & 0xFF) == ch and (key.normal >> 8) == sc) {
            // A real key whose unshifted ASCII is `ch`.
            return .{ .scancode = sc, .shift = false };
        }
    }
    sc = 0x01;
    while (sc < TABLE_LEN) : (sc += 1) {
        const key = table[sc];
        if (key.shift != NONE and (key.shift & 0xFF) == ch and (key.shift >> 8) == sc) {
            return .{ .scancode = sc, .shift = true };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests (1b translation-conformance over a representative key set).
// ---------------------------------------------------------------------------

test "letter 'a' across columns (index 0x1E)" {
    try std.testing.expectEqual(@as(?u16, 0x1E61), lookup(0x1E, .normal)); // 'a'
    try std.testing.expectEqual(@as(?u16, 0x1E41), lookup(0x1E, .shift)); // 'A'
    try std.testing.expectEqual(@as(?u16, 0x1E01), lookup(0x1E, .ctrl)); // ctrl-A
    try std.testing.expectEqual(@as(?u16, 0x1E00), lookup(0x1E, .alt)); // alt-A
}

test "letter 'q' (index 0x10) matches the AT-spec word set" {
    try std.testing.expectEqual(@as(?u16, 0x1071), lookup(0x10, .normal));
    try std.testing.expectEqual(@as(?u16, 0x1051), lookup(0x10, .shift));
    try std.testing.expectEqual(@as(?u16, 0x1011), lookup(0x10, .ctrl)); // ctrl-Q = DC1
    try std.testing.expectEqual(@as(?u16, 0x1000), lookup(0x10, .alt));
}

test "digit '1' normal/shift, alt special" {
    try std.testing.expectEqual(@as(?u16, 0x0231), lookup(0x02, .normal)); // '1'
    try std.testing.expectEqual(@as(?u16, 0x0221), lookup(0x02, .shift)); // '!'
    try std.testing.expectEqual(@as(?u16, null), lookup(0x02, .ctrl)); // ctrl-1 nothing
    try std.testing.expectEqual(@as(?u16, 0x7800), lookup(0x02, .alt)); // alt-1
}

test "Enter and Backspace control transforms" {
    try std.testing.expectEqual(@as(?u16, 0x1C0D), lookup(0x1C, .normal)); // CR
    try std.testing.expectEqual(@as(?u16, 0x1C0A), lookup(0x1C, .ctrl)); // ctrl-Enter = LF
    try std.testing.expectEqual(@as(?u16, 0x0E08), lookup(0x0E, .normal)); // BS
    try std.testing.expectEqual(@as(?u16, 0x0E7F), lookup(0x0E, .ctrl)); // ctrl-BS = DEL
}

test "function key F1 across modifier columns" {
    try std.testing.expectEqual(@as(?u16, 0x3B00), lookup(0x3B, .normal));
    try std.testing.expectEqual(@as(?u16, 0x5400), lookup(0x3B, .shift));
    try std.testing.expectEqual(@as(?u16, 0x5E00), lookup(0x3B, .ctrl));
    try std.testing.expectEqual(@as(?u16, 0x6800), lookup(0x3B, .alt));
}

test "modifier scancodes (Shift/Ctrl/Alt/Caps) produce no ring word" {
    try std.testing.expectEqual(@as(?u16, null), lookup(0x2A, .normal)); // LShift
    try std.testing.expectEqual(@as(?u16, null), lookup(0x36, .normal)); // RShift
    try std.testing.expectEqual(@as(?u16, null), lookup(0x1D, .normal)); // LCtrl
    try std.testing.expectEqual(@as(?u16, null), lookup(0x38, .normal)); // LAlt
    try std.testing.expectEqual(@as(?u16, null), lookup(0x3A, .normal)); // CapsLock
}

test "numpad digit vs cursor columns (NumLock selects via §5.1a)" {
    // NumLock OFF -> cursor keycode (normal column).
    try std.testing.expectEqual(@as(?u16, 0x4700), lookup(0x47, .normal)); // Home
    // NumLock ON -> digit ASCII (shift column here holds the digit).
    try std.testing.expectEqual(@as(?u16, 0x4737), lookup(0x47, .shift)); // '7'
}

test "extended cursor keys (0xE0 prefix)" {
    try std.testing.expectEqual(@as(?u16, 0x4800), lookupExt(0x48, .normal)); // gray Up
    try std.testing.expectEqual(@as(?u16, 0x4D00), lookupExt(0x4D, .normal)); // gray Right
    try std.testing.expectEqual(@as(?u16, 0x5300), lookupExt(0x53, .normal)); // gray Del
}

test "char→scancode reverse map over the real table" {
    const a = resolveChar('a').?;
    try std.testing.expectEqual(@as(u8, 0x1E), a.scancode);
    try std.testing.expect(!a.shift);
    const A = resolveChar('A').?;
    try std.testing.expectEqual(@as(u8, 0x1E), A.scancode);
    try std.testing.expect(A.shift);
    const one = resolveChar('1').?;
    try std.testing.expectEqual(@as(u8, 0x02), one.scancode);
    try std.testing.expect(!one.shift);
    const bang = resolveChar('!').?;
    try std.testing.expectEqual(@as(u8, 0x02), bang.scancode);
    try std.testing.expect(bang.shift);
    const space = resolveChar(' ').?;
    try std.testing.expectEqual(@as(u8, 0x39), space.scancode);
    // A char with no single set-1 key resolves to null (documented, not faked).
    try std.testing.expectEqual(@as(?CharResolve, null), resolveChar(0x80));
}
