//! Black-box test of the TDS symbol layer.
//!
//! Unlike the per-record fixture tests (which assert internal byte offsets against the
//! TDUMP oracles), this test treats the parser as a black box: it `Symbols.open`s a
//! committed real artifact — `testdata/BB.EXE`, compiled from `BB.C` with `bcc -v -ms`
//! (BC++ 3.1) — and asserts only facts derivable from the SOURCE, through the PUBLIC API.
//! A future change that breaks function/line/type/local resolution fails here regardless
//! of how the bytes are laid out.
//!
//! Source (BB.C):
//!   struct Pixel { int x; int y; unsigned char color; };
//!   enum Mode { TEXT, GRAPHICS, HIRES };
//!   int g_frames;
//!   int clamp(int v, int lo, int hi) { int r; ... }   // body lines 9-12
//!   int main(void) { struct Pixel p; enum Mode m; int i; ... }  // body lines 20-27
//! Oracle for authorship: docs/research/bcc3-fixtures/BB.LST.

const std = @import("std");
const testing = std.testing;

const symbols = @import("symbols.zig");
const Symbols = symbols.Symbols;
const TypeGraph = symbols.TypeGraph;
const Storage = symbols.Storage;
const Tds = @import("tds.zig").Tds;

const bb_exe = @embedFile("testdata/BB.EXE");

fn typeStr(tg: *const TypeGraph, ref: u16, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    tg.typeName(ref, &w) catch unreachable;
    return w.buffered();
}

fn localNamed(tg: *const TypeGraph, t: *const Tds, scope: usize, want: []const u8) ?symbols.Local {
    for (tg.localsForScope(scope)) |l| {
        if (std.mem.eql(u8, t.name(l.name_index), want)) return l;
    }
    return null;
}

test "black-box BB.EXE: it opens as a full TDS source" {
    var syms = try Symbols.open(testing.allocator, bb_exe, null);
    defer syms.deinit();
    try testing.expectEqual(Symbols.Source.tds, syms.source);
    try testing.expect(syms.typegraph != null);
    try testing.expectEqual(@as(?u32, 0), syms.index.fileId("BB.C")); // the one source file
}

test "black-box BB.EXE: the two functions resolve by name and by address" {
    var syms = try Symbols.open(testing.allocator, bb_exe, null);
    defer syms.deinit();
    const idx = &syms.index;

    const clamp = idx.nameToSymbol("_clamp") orelse return error.NoClamp;
    const main_ = idx.nameToSymbol("_main") orelse return error.NoMain;

    // an address inside each function resolves back to that function (round-trip).
    const at_clamp = idx.addrToFunction(clamp.segment, clamp.offset) orelse return error.NoFn;
    const at_main = idx.addrToFunction(main_.segment, main_.offset) orelse return error.NoFn;
    try testing.expectEqualStrings("_clamp", idx.functionName(at_clamp).?);
    try testing.expectEqualStrings("_main", idx.functionName(at_main).?);

    // clamp precedes main in the single code segment (source order).
    try testing.expect(clamp.offset < main_.offset);
}

test "black-box BB.EXE: source line <-> address round-trips, bound to the right function" {
    var syms = try Symbols.open(testing.allocator, bb_exe, null);
    defer syms.deinit();
    const idx = &syms.index;

    // Every executable source line round-trips: addrToLine(lineToAddr(L)).line == L.
    // (lines 9/11 are in clamp's body, 20/24 in main's body — see BB.C.)
    inline for (.{ 9, 11, 20, 24 }) |L| {
        const a = idx.lineToAddr(0, L) orelse return error.NoLine;
        const hit = idx.addrToLine(a.segment, a.offset) orelse return error.NoHit;
        try testing.expectEqual(@as(u16, L), hit.line);
    }

    // a blank/declaration line emits no code → no address.
    try testing.expect(idx.lineToAddr(0, 3) == null); // blank line
    try testing.expect(idx.lineToAddr(0, 17) == null); // `struct Pixel p;` decl

    // line 9 lives in clamp, line 20 in main.
    const a9 = idx.lineToAddr(0, 9).?;
    const a20 = idx.lineToAddr(0, 20).?;
    try testing.expectEqualStrings("_clamp", idx.functionName(idx.addrToFunction(a9.segment, a9.offset).?).?);
    try testing.expectEqualStrings("_main", idx.functionName(idx.addrToFunction(a20.segment, a20.offset).?).?);

    // post-prologue entry = each function's first interior line (clamp→9, main→20).
    const fc = idx.addrToFunction(0, idx.nameToSymbol("_clamp").?.offset).?;
    const fm = idx.addrToFunction(0, idx.nameToSymbol("_main").?.offset).?;
    try testing.expectEqual(idx.lineToAddr(0, 9).?.offset, idx.entryOffsetForFunction(fc));
    try testing.expectEqual(idx.lineToAddr(0, 20).?.offset, idx.entryOffsetForFunction(fm));
}

test "black-box BB.EXE: struct Pixel and enum Mode render from source" {
    var syms = try Symbols.open(testing.allocator, bb_exe, null);
    defer syms.deinit();
    const idx = &syms.index;
    const tg = &syms.typegraph.?;
    const t = syms.tds.?;
    var buf: [64]u8 = undefined;

    // Reach the types through main's locals `p` (struct Pixel) and `m` (enum Mode).
    const main_off = idx.nameToSymbol("_main").?.offset;
    const scope = tg.scopeForAddr(0, idx.lineToAddr(0, 20).?.offset) orelse return error.NoScope;
    _ = main_off;

    const p = localNamed(tg, t, scope, "p") orelse return error.NoP;
    const m = localNamed(tg, t, scope, "m") orelse return error.NoM;

    // struct Pixel { int x@0; int y@2; unsigned char color@4; }  (16-bit: int == 2 bytes)
    try testing.expectEqualStrings("struct Pixel", typeStr(tg, p.type_ref, &buf));
    const ms = tg.members(p.type_ref);
    try testing.expectEqual(@as(usize, 3), ms.len);
    try testing.expectEqualStrings("x", t.name(ms[0].name_index));
    try testing.expectEqual(@as(u16, 0), ms[0].byte_offset);
    try testing.expectEqualStrings("int", typeStr(tg, ms[0].type_ref, &buf));
    try testing.expectEqualStrings("y", t.name(ms[1].name_index));
    try testing.expectEqual(@as(u16, 2), ms[1].byte_offset);
    try testing.expectEqualStrings("color", t.name(ms[2].name_index));
    try testing.expectEqual(@as(u16, 4), ms[2].byte_offset);
    try testing.expectEqualStrings("unsigned char", typeStr(tg, ms[2].type_ref, &buf));

    // enum Mode { TEXT=0, GRAPHICS=1, HIRES=2 }
    const es = tg.enumerators(m.type_ref);
    try testing.expectEqual(@as(usize, 3), es.len);
    try testing.expectEqualStrings("TEXT", t.name(es[0].name_index));
    try testing.expectEqual(@as(i32, 0), es[0].value);
    try testing.expectEqualStrings("GRAPHICS", t.name(es[1].name_index));
    try testing.expectEqual(@as(i32, 1), es[1].value);
    try testing.expectEqualStrings("HIRES", t.name(es[2].name_index));
    try testing.expectEqual(@as(i32, 2), es[2].value);
}

test "black-box BB.EXE: main's locals carry the right storage + types" {
    var syms = try Symbols.open(testing.allocator, bb_exe, null);
    defer syms.deinit();
    const idx = &syms.index;
    const tg = &syms.typegraph.?;
    const t = syms.tds.?;
    var buf: [64]u8 = undefined;

    const scope = tg.scopeForAddr(0, idx.lineToAddr(0, 20).?.offset) orelse return error.NoScope;

    // i : register SI ; m : auto @BP-8 (enum Mode) ; p : auto @BP-6 (struct Pixel)
    const i = localNamed(tg, t, scope, "i") orelse return error.NoI;
    const m = localNamed(tg, t, scope, "m") orelse return error.NoM;
    const p = localNamed(tg, t, scope, "p") orelse return error.NoP;

    try testing.expectEqual(Storage{ .register = 6 }, i.storage); // SI == 6
    try testing.expectEqualStrings("int", typeStr(tg, i.type_ref, &buf));
    try testing.expectEqual(Storage{ .auto = -8 }, m.storage);
    try testing.expectEqualStrings("enum Mode", typeStr(tg, m.type_ref, &buf));
    try testing.expectEqual(Storage{ .auto = -6 }, p.storage);
    try testing.expectEqualStrings("struct Pixel", typeStr(tg, p.type_ref, &buf));
}
