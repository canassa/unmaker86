//! `map.zig` — `AddressMap`: the **only** component in the symbol layer that knows
//! about runtime relocation (`load_para`). It layers the image→runtime seam over the
//! image-relative `SymbolIndex`.
//!
//! DOS loads the MZ image at paragraph `psp_seg + 0x10` (the loader sets
//! `load_seg = psp_seg + 16`; see `src/dos/loader.zig` ~:195/:206), then every TDS
//! `(segment, offset)` is image-relative to that base (spec §14):
//!
//!   runtime_linear = (psp_seg + 0x10 + tds_segment) * 16 + tds_offset
//!
//! `AddressMap` is rebuilt on every `load`/`reset+load` (a new `psp_seg`); it holds no
//! guest state and is never snapshotted. Determinism: a pure function of `(index,
//! psp_seg)` — no clock/RNG/alloc on the lookup path.

const std = @import("std");
const index_mod = @import("index.zig");

pub const SymbolIndex = index_mod.SymbolIndex;
pub const ImageAddr = index_mod.ImageAddr;
pub const LineHit = index_mod.LineHit;
pub const FuncRef = index_mod.FuncRef;

pub const AddressMap = struct {
    index: *const SymbolIndex,
    /// The runtime image-base paragraph: `psp_seg + 0x10`.
    base_para: u32,

    /// Attach an image-relative index to a concrete load. `psp_seg` is the PSP/MCB
    /// allocation paragraph the loader recorded (`dos.current_psp`); the image base
    /// is `psp_seg + 0x10`.
    pub fn attach(idx: *const SymbolIndex, psp_seg: u16) AddressMap {
        return .{ .index = idx, .base_para = @as(u32, psp_seg) + 0x10 };
    }

    /// Image `(segment, offset)` → 20-bit runtime linear address (spec §14).
    pub fn toRuntimeLinear(self: AddressMap, seg: u16, off: u16) u32 {
        return (self.base_para + seg) * 16 + off;
    }

    /// Inverse, for a code address: find the code segment whose runtime extent owns
    /// `linear` and recover its image `(segment, offset)`. Null if `linear` is not
    /// inside any known code segment. Drives off `index.seg_extents`, so it works for
    /// BOTH a TDS-backed index AND a `.map`-backed one (no `Tds` required — D7).
    pub fn imageAddrForLinear(self: AddressMap, linear: u32) ?ImageAddr {
        for (self.index.seg_extents) |s| {
            const seg_base = (self.base_para + s.paragraph) * 16;
            const start = seg_base + s.start;
            const end = start + s.length;
            if (linear >= start and linear < end) {
                return .{ .segment = s.paragraph, .offset = @intCast(linear - seg_base) };
            }
        }
        return null;
    }

    /// Runtime linear address of the first code for `(file_id, line)` (source bp).
    pub fn runtimeAddrForLine(self: AddressMap, file_id: u32, line: u16) ?u32 {
        const ia = self.index.lineToAddr(file_id, line) orelse return null;
        return self.toRuntimeLinear(ia.segment, ia.offset);
    }

    /// The source line at a live runtime linear address (e.g. CS:IP → line).
    pub fn lineForRuntimeAddr(self: AddressMap, linear: u32) ?LineHit {
        const ia = self.imageAddrForLinear(linear) orelse return null;
        return self.index.addrToLine(ia.segment, ia.offset);
    }

    /// The function owning a live runtime linear address.
    pub fn functionForRuntimeAddr(self: AddressMap, linear: u32) ?FuncRef {
        const ia = self.imageAddrForLinear(linear) orelse return null;
        return self.index.addrToFunction(ia.segment, ia.offset);
    }

    /// Runtime linear address of `f`'s post-prologue entry (design §7.6) — where a
    /// function / source breakpoint should land so BP-relative locals are valid. The
    /// image-relative offset comes from `SymbolIndex.entryOffsetForFunction`.
    pub fn entryAddrForFunction(self: AddressMap, f: FuncRef) u32 {
        const off = self.index.entryOffsetForFunction(f);
        return self.toRuntimeLinear(f.segment, off);
    }
};

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;
const tdsmod = @import("tds.zig");
const test_exe = @embedFile("testdata/TEST.EXE");
const rich_exe = @embedFile("testdata/RICH.EXE");

test "AddressMap(TEST): runtime linear + round-trip" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    const psp: u16 = 0x0210;
    const am = AddressMap.attach(&idx, psp);

    // _main is image (segment 0, offset 730); small-model single code segment.
    // The base-paragraph formula `(psp_seg + 0x10 + seg) * 16 + off` lives ONLY in
    // `AddressMap.toRuntimeLinear` (the single load_para seam) — assert it directly.
    const expect = (@as(u32, 0x0210) + 0x10) * 16 + 730;
    try testing.expectEqual(expect, am.toRuntimeLinear(0, 730));

    // round-trip through the inverse.
    const ia = am.imageAddrForLinear(expect).?;
    try testing.expectEqual(@as(u16, 0), ia.segment);
    try testing.expectEqual(@as(u16, 730), ia.offset);

    // line + function at the live address.
    try testing.expectEqual(@as(u16, 11), am.lineForRuntimeAddr(expect).?.line);
    const f = am.functionForRuntimeAddr(am.toRuntimeLinear(0, 720)).?;
    try testing.expectEqualStrings("_add", tds.name(tds.symbols[f.sym_index - 1].name));

    // source breakpoint resolution.
    try testing.expectEqual(am.toRuntimeLinear(0, 730), am.runtimeAddrForLine(0, 11).?);
}

test "AddressMap(RICH): far segments relocate by their own paragraph" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    const psp: u16 = 0x0040;
    const am = AddressMap.attach(&idx, psp);

    // _compute lives at image 0xC2:0006; its runtime address shifts by 0xC2 paras.
    const lin = am.toRuntimeLinear(0xC2, 6);
    try testing.expectEqual((@as(u32, 0x40) + 0x10 + 0xC2) * 16 + 6, lin);
    const ia = am.imageAddrForLinear(lin).?;
    try testing.expectEqual(@as(u16, 0xC2), ia.segment);
    try testing.expectEqual(@as(u16, 6), ia.offset);
    try testing.expectEqualStrings("_compute", tds.name(tds.symbols[am.functionForRuntimeAddr(lin).?.sym_index - 1].name));
}

test "AddressMap(TEST): entryAddrForFunction lands post-prologue (§7.6)" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    const psp: u16 = 0x0210;
    const am = AddressMap.attach(&idx, psp);

    // _main's post-prologue entry is image offset 736 (vs its start 730).
    const f = am.functionForRuntimeAddr(am.toRuntimeLinear(0, 730)).?;
    try testing.expectEqual(am.toRuntimeLinear(0, 736), am.entryAddrForFunction(f));
}

const mapfile = @import("mapfile.zig");

const small_model_map =
    \\ Start  Stop   Length Name               Class
    \\ 00000H 0007FH 00080H _TEXT              CODE
    \\
    \\  Address         Publics by Value
    \\
    \\ 0000:0010       _main
    \\ 0000:0040       _helper
    \\
    \\Program entry point at 0000:0010
;

test "AddressMap(.map): functionForRuntimeAddr resolves without a Tds (D7)" {
    var idx = try mapfile.parse(testing.allocator, small_model_map);
    defer idx.deinit();

    const am = AddressMap.attach(&idx, 0x0040);
    // A runtime PC inside _main's [0x10,0x40) range resolves back to _main even though
    // there is no Tds (the index carries the synthesized code extent).
    const f = am.functionForRuntimeAddr(am.toRuntimeLinear(0, 0x20)).?;
    try testing.expectEqual(@as(u16, 0x10), f.start);
    try testing.expectEqual(@as(u16, 0x40), f.end);
    // _helper resolves too (its synthesized extent runs to the top of the segment).
    try testing.expectEqual(@as(u16, 0x40), am.functionForRuntimeAddr(am.toRuntimeLinear(0, 0x50)).?.start);
    // an address below the first public's offset is outside the code extent ⇒ null.
    try testing.expect(am.functionForRuntimeAddr(am.toRuntimeLinear(0, 0x00)) == null);
}

test {
    testing.refAllDecls(@This());
}
