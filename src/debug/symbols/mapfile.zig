//! `mapfile.zig` — the TLINK `/m` **`.map`** fallback parser. When an EXE carries no
//! embedded TDS (and no `.TDS` sidecar), a linker map is a strictly weaker symbol
//! source: **public function/global names + addresses only — no line numbers, no
//! types**. It parses the `seg:off  NAME` rows of the "Publics by Value/Name" tables
//! into the SAME `SymbolIndex` shape (`nameToSymbol` / `addrToFunction`) via
//! `SymbolIndex.fromMap`, so one interface serves embedded-TDS and `.map` alike.
//! Selection precedence is the caller's: embedded TDS → `.TDS` → `.map` → none.
//!
//! Determinism: a pure function of the map text (no clock/RNG/env). The `(seg, off)`
//! addresses are image-relative exactly like the TDS ones, so `AddressMap` relocates
//! them with the identical `psp_seg + 0x10` formula.

const std = @import("std");
const index_mod = @import("index.zig");

pub const SymbolIndex = index_mod.SymbolIndex;
pub const Public = index_mod.Public;

pub const ParseError = error{ NoPublics, OutOfMemory };

/// Parse a `.map`'s public-symbol rows into a names/functions-only `SymbolIndex`.
/// Rows look like ` 0002:0006       _main` (4-hex segment, 4-hex offset, then the
/// name). Both the "by Name" and "by Value" tables are scanned; duplicate names are
/// dropped (kept once). `error.NoPublics` if not a single public row is found.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!SymbolIndex {
    var publics: std.ArrayList(Public) = .empty;
    defer publics.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const p = parseRow(line) orelse continue;
        // Dedupe by name (the "by Name" and "by Value" tables list the same publics).
        var dup = false;
        for (publics.items) |q| {
            if (std.mem.eql(u8, q.name, p.name)) {
                dup = true;
                break;
            }
        }
        if (!dup) try publics.append(gpa, p);
    }
    if (publics.items.len == 0) return error.NoPublics;
    return SymbolIndex.fromMap(gpa, publics.items);
}

/// Parse one `seg:off  NAME` row. Returns null for header / blank / non-matching
/// lines. The name slice borrows from `line` (re-duped by `fromMap`).
fn parseRow(line: []const u8) ?Public {
    // Need at least "0:0 x".
    if (line.len < 5) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const seg = parseHex(line[0..colon]) orelse return null;

    var i = colon + 1;
    const off_start = i;
    while (i < line.len and isHex(line[i])) : (i += 1) {}
    if (i == off_start) return null;
    const off = parseHex(line[off_start..i]) orelse return null;

    // Skip whitespace to the name.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return null;
    const name_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    const name = line[name_start..i];
    // A real public starts with a letter, '_' or '@' (Borland mangling). This rejects
    // the segment-table rows (Class names like CODE/DATA appear after a length column,
    // not a seg:off pair, so they never reach here).
    if (name.len == 0) return null;
    const c0 = name[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_' or c0 == '@')) return null;

    return .{ .segment = seg, .offset = off, .name = name };
}

fn isHex(c: u8) bool {
    return std.ascii.isHex(c);
}

fn parseHex(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    var v: u16 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, 16) catch return null;
        v = v *% 16 +% d;
    }
    return v;
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

const sample_map =
    \\ Start  Stop   Length Name               Class
    \\ 00000H 0070FH 00710H _TEXT              CODE
    \\ 00710H 008FFH 001F0H _DATA              DATA
    \\
    \\  Address         Publics by Name
    \\
    \\ 0000:0040       _helper
    \\ 0000:0010       _main
    \\ 0001:0000       _far_fn
    \\
    \\  Address         Publics by Value
    \\
    \\ 0000:0010       _main
    \\ 0000:0040       _helper
    \\ 0001:0000       _far_fn
    \\
    \\Program entry point at 0000:0010
;

test "mapfile.parse: publics → nameToSymbol + addrToFunction" {
    var idx = try parse(testing.allocator, sample_map);
    defer idx.deinit();

    const m = idx.nameToSymbol("_main").?;
    try testing.expectEqual(@as(u16, 0), m.segment);
    try testing.expectEqual(@as(u16, 0x10), m.offset);
    const h = idx.nameToSymbol("_helper").?;
    try testing.expectEqual(@as(u16, 0x40), h.offset);
    const ff = idx.nameToSymbol("_far_fn").?;
    try testing.expectEqual(@as(u16, 1), ff.segment);

    // _main owns [0x10, 0x40) (bounded by the next public in segment 0).
    const f = idx.addrToFunction(0, 0x20).?;
    try testing.expectEqual(@as(u16, 0x10), f.start);
    try testing.expectEqual(@as(u16, 0x40), f.end);

    // names-only: no line data.
    try testing.expect(idx.addrToLine(0, 0x10) == null);
    try testing.expect(idx.lineToAddr(0, 1) == null);

    // The CODE/DATA segment-table rows are NOT mistaken for publics.
    try testing.expect(idx.nameToSymbol("CODE") == null);
    try testing.expect(idx.nameToSymbol("_TEXT") == null); // has a length col, no seg:off
}

test "mapfile.parse: empty / no publics ⇒ clean error" {
    try testing.expectError(error.NoPublics, parse(testing.allocator, ""));
    try testing.expectError(error.NoPublics, parse(testing.allocator, "no symbols here\njust text\n"));
}

test {
    testing.refAllDecls(@This());
}
