//! `index.zig` — `SymbolIndex`: the Tier-1 derived lookups over a parsed `Tds`,
//! built once at load time. Everything is **image-relative** (a TDS `(segment,
//! offset)` paragraph:offset, or a `(file_id, line)` pair) — runtime relocation is
//! `map.zig`'s job, never this file's.
//!
//! All structures are **sorted arrays + binary search** — no hashing, no unordered
//! iteration (determinism gate, plan §4.2): the same `Tds` always yields byte-
//! identical index arrays. The returned "hit" PODs (`LineHit`/`FuncRef`/`SymRef`/
//! `ImageAddr`) hold only integers — no borrowed pointers — so they can never leak a
//! host address into a snapshot or the M2 JSON (plan §8.3 reflection gate).
//!
//! Two producers feed one index shape: `build` from a full `Tds` (names + functions +
//! lines), and `fromMap` from a `.map`'s public-symbol list (names + functions only;
//! `addrToLine`/`lineToAddr` always return null). Precedence is the caller's:
//! embedded TDS → `.TDS` → `.map` → none.
//!
//! Tier boundary: types/members are parsed into `Tds` already, but the type
//! graph / locals indices are Tier 2 — not built here.

const std = @import("std");
const format = @import("format.zig");
const tdsmod = @import("tds.zig");

pub const Tds = tdsmod.Tds;

/// A code (segment:offset) image address.
pub const ImageAddr = struct { segment: u16, offset: u16 };

/// addr→line result: the source line owning a code address, with its file.
pub const LineHit = struct { line: u16, file_id: u32, code_offset: u16 };

/// addr→function result: the function whose `[start, end)` code range owns an address.
/// `name_index` is the 1-based name-pool index of the function name (resolve via
/// `Tds.name` / `SymbolIndex.functionName`); 0 for a `.map`-backed index, which has no
/// shared name pool (recover its name via `nameToSymbol`).
pub const FuncRef = struct { sym_index: u16, segment: u16, start: u16, end: u16, name_index: u16 };

/// name→symbol result: a resolved symbol's raw fields (no borrowed name pointer).
/// `name_index` is the 1-based name-pool index (resolve via `Tds.name` /
/// `SymbolIndex.symbolName`); 0 for a `.map`-backed index.
pub const SymRef = struct { sym_index: u16, segment: u16, offset: u16, type_index: u16, name_index: u16 };

/// A public symbol `(segment, offset, name)` — the lowest-common-denominator row
/// both the TDS path and the `.map` path can produce (the `.map` adapter, §6.1).
pub const Public = struct { segment: u16, offset: u16, name: []const u8 };

/// A code segment's runtime-relocatable extent: image `paragraph` plus the `[start,
/// start+length)` offset window of its code. Carried in the index so addr→image
/// inversion (`AddressMap.imageAddrForLinear`) works for BOTH a TDS-backed index
/// (extents from `Tds.segments`) AND a `.map`-backed one (synthesized from the public
/// addresses) — the `.map` path has no `Tds.segments` to walk (§6.5 / D7).
pub const SegExtent = struct { paragraph: u16, start: u16, length: u32 };

/// One row of the addr→line table (sorted by `(segment, code_offset)`).
const LineEntry = struct { segment: u16, code_offset: u16, line: u16, file_id: u32 };
/// One row of the line→addr table (sorted by `(file_id, line, code_offset)`).
const LineAddrEntry = struct { file_id: u32, line: u16, segment: u16, code_offset: u16 };
/// One function range (sorted by `(segment, start)`).
const FuncEntry = struct { segment: u16, start: u16, end: u16, sym_index: u16, name_index: u16 };
/// One name→symbol row (sorted by name bytes).
const NameEntry = struct { name: []const u8, ref: SymRef };

pub const SymbolIndex = struct {
    arena: std.heap.ArenaAllocator,
    tds: ?*const Tds, // null when built from a `.map` (no record tables)

    addr_to_line: []LineEntry, // sorted by (segment, code_offset)
    line_to_addr: []LineAddrEntry, // sorted by (file_id, line, code_offset)
    funcs: []FuncEntry, // sorted by (segment, start)
    names: []NameEntry, // sorted by name bytes
    seg_extents: []SegExtent, // code-segment extents for addr→image inversion (D7)

    pub fn deinit(self: *SymbolIndex) void {
        self.arena.deinit();
    }

    // ─────────────────────────── construction ───────────────────────────

    /// Build the full Tier-1 index from a parsed `Tds`. Borrows `tds` (and the name
    /// slices in `tds.name_pool`); `tds` must outlive the returned index.
    pub fn build(gpa: std.mem.Allocator, tds: *const Tds) error{OutOfMemory}!SymbolIndex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        // ---- line tables: bind line records to a code segment via correlations ----
        // (spec §10: a correlation maps a contiguous run of line records to one
        // segment-table entry; the line's code_offset is relative to that code base.)
        var line_list: std.ArrayList(LineEntry) = .empty;
        for (tds.correlations) |c| {
            if (c.segment_index == 0 or c.segment_index > tds.segments.len) continue;
            const seg = tds.segments[c.segment_index - 1].code_segment;
            const file_id: u32 = if (c.source_index == 0) 0 else c.source_index - 1;
            const first: usize = if (c.line_first == 0) 0 else c.line_first - 1;
            const end = @min(first + c.line_count, tds.lines.len);
            var i = first;
            while (i < end) : (i += 1) {
                try line_list.append(a, .{
                    .segment = seg,
                    .code_offset = tds.lines[i].code_offset,
                    .line = tds.lines[i].line,
                    .file_id = file_id,
                });
            }
        }
        const addr_to_line = try line_list.toOwnedSlice(a);
        std.sort.pdq(LineEntry, addr_to_line, {}, lessLineEntry);

        const line_to_addr = try a.alloc(LineAddrEntry, addr_to_line.len);
        for (addr_to_line, line_to_addr) |src, *dst| {
            dst.* = .{ .file_id = src.file_id, .line = src.line, .segment = src.segment, .code_offset = src.code_offset };
        }
        std.sort.pdq(LineAddrEntry, line_to_addr, {}, lessLineAddrEntry);

        // ---- function ranges from code symbols, bounded by the segment records ----
        var func_list: std.ArrayList(FuncEntry) = .empty;
        for (tds.symbols, 0..) |s, i| {
            if (!s.isFunction()) continue;
            try func_list.append(a, .{
                .segment = s.segment,
                .start = s.offset,
                .end = 0, // filled below from the next function / segment extent
                .sym_index = @intCast(i + 1), // 1-based symbol index
                .name_index = s.name, // 1-based name-pool index of the function name
            });
        }
        const funcs = try func_list.toOwnedSlice(a);
        std.sort.pdq(FuncEntry, funcs, {}, lessFuncEntry);
        // A function's range ends at the next function in the same segment, clamped to
        // that segment's code extent (spec §9 code_offset+code_length).
        for (funcs, 0..) |*f, i| {
            var end: u32 = segmentEnd(tds, f.segment, f.start);
            if (i + 1 < funcs.len and funcs[i + 1].segment == f.segment) {
                end = @min(end, funcs[i + 1].start);
            }
            f.end = @intCast(@min(end, 0xFFFF));
        }

        // ---- name → symbol over every named symbol ----
        var name_list: std.ArrayList(NameEntry) = .empty;
        for (tds.symbols, 0..) |s, i| {
            const nm = tds.name(s.name);
            if (nm.len == 0) continue;
            try name_list.append(a, .{
                .name = nm,
                .ref = .{ .sym_index = @intCast(i + 1), .segment = s.segment, .offset = s.offset, .type_index = s.type, .name_index = s.name },
            });
        }
        const names = try name_list.toOwnedSlice(a);
        std.sort.pdq(NameEntry, names, {}, lessNameEntry);

        // ---- code-segment extents (for addr→image inversion; D7). The TDS path
        //      reads them straight from the segment table (paragraph + code window). ----
        const seg_extents = try a.alloc(SegExtent, tds.segments.len);
        for (tds.segments, seg_extents) |s, *e| {
            e.* = .{ .paragraph = s.code_segment, .start = s.code_offset, .length = s.code_length };
        }

        return .{
            .arena = arena,
            .tds = tds,
            .addr_to_line = addr_to_line,
            .line_to_addr = line_to_addr,
            .funcs = funcs,
            .names = names,
            .seg_extents = seg_extents,
        };
    }

    /// Build a names-only / functions-only index from a `.map`'s public-symbol list
    /// (no line tables). The `publics` name slices are duped into the index arena, so
    /// the caller's parse buffer need not outlive the index.
    pub fn fromMap(gpa: std.mem.Allocator, publics_in: []const Public) error{OutOfMemory}!SymbolIndex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        // The 1-based `sym_index` is a u16 (it mirrors the TDS symbol index). Cap the
        // public count at 0xFFFF so `@intCast(i + 1)` can never overflow — and LOG the
        // truncation (silent caps are forbidden, CLAUDE.md §2). A `.map` with > 64K
        // publics is pathological; the cap keeps the parser panic-free (BUG-3).
        var publics = publics_in;
        if (publics.len > 0xFFFF) {
            std.log.warn("symbol .map has {d} publics; capping at 65535 (TDS symbol index is u16)", .{publics.len});
            publics = publics_in[0..0xFFFF];
        }

        const funcs = try a.alloc(FuncEntry, publics.len);
        const names = try a.alloc(NameEntry, publics.len);
        for (publics, 0..) |p, i| {
            const nm = try a.dupe(u8, p.name);
            // A `.map` has no shared name pool, so `name_index` is 0 (recover the name
            // via `nameToSymbol`); the resolvable name lives in `NameEntry.name`.
            funcs[i] = .{ .segment = p.segment, .start = p.offset, .end = 0, .sym_index = @intCast(i + 1), .name_index = 0 };
            names[i] = .{ .name = nm, .ref = .{ .sym_index = @intCast(i + 1), .segment = p.segment, .offset = p.offset, .type_index = 0, .name_index = 0 } };
        }
        std.sort.pdq(FuncEntry, funcs, {}, lessFuncEntry);
        // No segment extents in a `.map` — bound each function by the next public in
        // the same segment, else run to the top of the segment.
        for (funcs, 0..) |*f, i| {
            var end: u32 = 0xFFFF;
            if (i + 1 < funcs.len and funcs[i + 1].segment == f.segment) end = funcs[i + 1].start;
            f.end = @intCast(end);
        }
        std.sort.pdq(NameEntry, names, {}, lessNameEntry);

        // Synthesize one code extent per distinct segment from the (already sorted)
        // function ranges, so `imageAddrForLinear` / `functionForRuntimeAddr` work
        // without a `Tds` (D7). The window spans from the first public's offset to the
        // last function's `end` in that segment.
        var ext_list: std.ArrayList(SegExtent) = .empty;
        var i: usize = 0;
        while (i < funcs.len) {
            const seg = funcs[i].segment;
            const start = funcs[i].start;
            var end: u32 = funcs[i].end;
            var j = i;
            while (j < funcs.len and funcs[j].segment == seg) : (j += 1) end = @max(end, funcs[j].end);
            try ext_list.append(a, .{ .paragraph = seg, .start = start, .length = end - start });
            i = j;
        }
        const seg_extents = try ext_list.toOwnedSlice(a);

        return .{
            .arena = arena,
            .tds = null,
            .addr_to_line = &.{},
            .line_to_addr = &.{},
            .funcs = funcs,
            .names = names,
            .seg_extents = seg_extents,
        };
    }

    // ─────────────────────────── Tier-1 lookups ───────────────────────────

    /// addr→line: the source line owning image address `(seg, off)` (the interval
    /// `[entry, next)` within the segment owns `off`). Null if no line covers it.
    pub fn addrToLine(self: *const SymbolIndex, seg: u16, off: u16) ?LineHit {
        const entries = self.addr_to_line;
        // First index of this segment, then the last entry with code_offset <= off.
        var lo: usize = 0;
        var hi: usize = entries.len;
        // lower bound of (seg, off+1) − 1 within the segment, never crossing segments.
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = entries[mid];
            if (e.segment < seg or (e.segment == seg and e.code_offset <= off)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const e = entries[lo - 1];
        if (e.segment != seg) return null;
        // Bound the open-ended last line entry: an address past the end of the function
        // that owns it has no source line (consistent with `addrToFunction`, which
        // bounds by `f.end`). Without this, any high offset in a segment would resolve
        // to the segment's final line record.
        if (self.addrToFunction(seg, off) == null) return null;
        return .{ .line = e.line, .file_id = e.file_id, .code_offset = e.code_offset };
    }

    /// line→addr: the lowest code address for `(file_id, line)`, for source
    /// breakpoints / runToLine. Null if the line maps to no code.
    pub fn lineToAddr(self: *const SymbolIndex, file_id: u32, line: u16) ?ImageAddr {
        const entries = self.line_to_addr;
        var lo: usize = 0;
        var hi: usize = entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = entries[mid];
            if (e.file_id < file_id or (e.file_id == file_id and e.line < line)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= entries.len) return null;
        const e = entries[lo];
        if (e.file_id != file_id or e.line != line) return null;
        return .{ .segment = e.segment, .offset = e.code_offset };
    }

    /// addr→function: the function whose `[start, end)` range owns `(seg, off)`.
    pub fn addrToFunction(self: *const SymbolIndex, seg: u16, off: u16) ?FuncRef {
        const fs = self.funcs;
        var lo: usize = 0;
        var hi: usize = fs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const f = fs[mid];
            if (f.segment < seg or (f.segment == seg and f.start <= off)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const f = fs[lo - 1];
        if (f.segment != seg or off >= f.end) return null;
        return .{ .sym_index = f.sym_index, .segment = f.segment, .start = f.start, .end = f.end, .name_index = f.name_index };
    }

    /// The post-prologue entry offset of `f` (design §7.6): the offset a function /
    /// source breakpoint should land on so BP-relative locals are already valid. It is
    /// the first line entry whose `code_offset` is strictly past the function start
    /// (the prologue), still inside `[start, end)`; falls back to `f.start` when the
    /// function has no interior line records (e.g. a `.map`-backed index). Image-
    /// relative — the runtime wrapper is `AddressMap.entryAddrForFunction`.
    pub fn entryOffsetForFunction(self: *const SymbolIndex, f: FuncRef) u16 {
        var best: ?u16 = null;
        for (self.addr_to_line) |e| {
            if (e.segment != f.segment) continue;
            if (e.code_offset <= f.start or e.code_offset >= f.end) continue;
            if (best == null or e.code_offset < best.?) best = e.code_offset;
        }
        return best orelse f.start;
    }

    /// name→symbol: binary search over the sorted name table.
    pub fn nameToSymbol(self: *const SymbolIndex, name: []const u8) ?SymRef {
        const ns = self.names;
        var lo: usize = 0;
        var hi: usize = ns.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, ns[mid].name, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return ns[mid].ref,
            }
        }
        return null;
    }

    /// module name for a 0-based module id (image compile-time name).
    pub fn module(self: *const SymbolIndex, module_id: u32) ?[]const u8 {
        const tds = self.tds orelse return null;
        if (module_id >= tds.modules.len) return null;
        return tds.name(tds.modules[module_id].name);
    }

    /// raw compile-time source-file path for a 0-based file id (path normalization
    /// is the frontend's job — plan R6).
    pub fn sourceFile(self: *const SymbolIndex, file_id: u32) ?[]const u8 {
        const tds = self.tds orelse return null;
        if (file_id >= tds.sources.len) return null;
        return tds.name(tds.sources[file_id].name);
    }

    /// The number of source files in the index (0 for a `.map`-backed index).
    pub fn sourceFileCount(self: *const SymbolIndex) u32 {
        const tds = self.tds orelse return 0;
        return @intCast(tds.sources.len);
    }

    /// 0-based file id for an exact source-file name (`fileId("TEST.C")` etc.), so a
    /// `file:line` source breakpoint can resolve through the API; null if no source
    /// file matches (path *normalization* stays a frontend concern — plan R6). The id
    /// is the same one `addrToLine`/`lineToAddr`/`sourceFile` use.
    pub fn fileId(self: *const SymbolIndex, name: []const u8) ?u32 {
        const tds = self.tds orelse return null;
        for (tds.sources, 0..) |sf, i| {
            if (std.mem.eql(u8, tds.name(sf.name), name)) return @intCast(i);
        }
        return null;
    }

    /// 0-based file id matched by BASENAME (the relaxed sibling of the strict-`eql`
    /// `fileId`): drops any drive/dir prefix from BOTH the recorded name and `name` before
    /// comparing, so a full-path-recorded TDS name (`C:\PROJ\BB.C`) still resolves to the
    /// bare basename an agent passes (`BB.C`) — `read_source`/the window resolver share one
    /// id space (plan finding #3). First match wins; null if none.
    pub fn fileIdByBasename(self: *const SymbolIndex, name: []const u8) ?u32 {
        const tds = self.tds orelse return null;
        const want = pathBasename(name);
        for (tds.sources, 0..) |sf, i| {
            if (std.mem.eql(u8, pathBasename(tds.name(sf.name)), want)) return @intCast(i);
        }
        return null;
    }

    /// The last path component of `s`, split on either DOS `\` or POSIX `/`.
    fn pathBasename(s: []const u8) []const u8 {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            if (c == '/' or c == '\\') start = i + 1;
        }
        return s[start..];
    }

    /// The function name behind a `FuncRef` (resolves its `name_index` through the name
    /// pool), so callers need not reach into the raw `Tds`. Null for a `.map`-backed
    /// index (no shared name pool — use `nameToSymbol` for `.map` names).
    pub fn functionName(self: *const SymbolIndex, f: FuncRef) ?[]const u8 {
        const tds = self.tds orelse return null;
        if (f.name_index == 0) return null;
        return tds.name(f.name_index);
    }

    /// The symbol name behind a `SymRef` (resolves its `name_index`). Null for a
    /// `.map`-backed index.
    pub fn symbolName(self: *const SymbolIndex, s: SymRef) ?[]const u8 {
        const tds = self.tds orelse return null;
        if (s.name_index == 0) return null;
        return tds.name(s.name_index);
    }

    /// The 1-based type-ref of the function symbol behind `f` (its
    /// `Tds.symbols[sym_index-1].type`), for the `stepOut` far/near-return decision
    /// (`TypeGraph.typeInfo(t).function.far`). The live-PC path yields a `FuncRef`, which
    /// (unlike `SymRef`) carries no `type_index`, so the function's return type cannot be
    /// reached without this accessor. Null for a `.map`-backed index (no `Tds` / no symbol
    /// type) or an out-of-range `sym_index`. Pure, integer-only — stays on both gates.
    pub fn typeRefForFunction(self: *const SymbolIndex, f: FuncRef) ?u16 {
        const tds = self.tds orelse return null;
        if (f.sym_index == 0 or f.sym_index > tds.symbols.len) return null;
        return tds.symbols[f.sym_index - 1].type;
    }
};

/// The code extent end for the segment record whose `code_segment` paragraph is
/// `seg` and which contains `off`; `0xFFFF` if none (spec §9).
fn segmentEnd(tds: *const Tds, seg: u16, off: u16) u32 {
    var best: u32 = 0xFFFF;
    var found = false;
    for (tds.segments) |s| {
        if (s.code_segment != seg) continue;
        if (off < s.code_offset) continue;
        const e: u32 = @as(u32, s.code_offset) + s.code_length;
        if (off < e) {
            best = e;
            found = true;
        }
    }
    return if (found) best else 0xFFFF;
}

fn lessLineEntry(_: void, x: LineEntry, y: LineEntry) bool {
    if (x.segment != y.segment) return x.segment < y.segment;
    if (x.code_offset != y.code_offset) return x.code_offset < y.code_offset;
    return x.line < y.line;
}
fn lessLineAddrEntry(_: void, x: LineAddrEntry, y: LineAddrEntry) bool {
    if (x.file_id != y.file_id) return x.file_id < y.file_id;
    if (x.line != y.line) return x.line < y.line;
    if (x.segment != y.segment) return x.segment < y.segment;
    return x.code_offset < y.code_offset;
}
fn lessFuncEntry(_: void, x: FuncEntry, y: FuncEntry) bool {
    if (x.segment != y.segment) return x.segment < y.segment;
    return x.start < y.start;
}
fn lessNameEntry(_: void, x: NameEntry, y: NameEntry) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;
const test_exe = @embedFile("testdata/TEST.EXE");
const rich_exe = @embedFile("testdata/RICH.EXE");

test "SymbolIndex(TEST): addr↔line and name↔symbol" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // line → addr: TEST.C line 11 == _main entry at offset 730.
    const a = idx.lineToAddr(0, 11).?;
    try testing.expectEqual(@as(u16, 0), a.segment);
    try testing.expectEqual(@as(u16, 730), a.offset);

    // addr → line: offset 730 is line 11; 735 still inside [730,736) is line 11.
    try testing.expectEqual(@as(u16, 11), idx.addrToLine(0, 730).?.line);
    try testing.expectEqual(@as(u16, 11), idx.addrToLine(0, 735).?.line);
    // first line entry boundary.
    try testing.expectEqual(@as(u16, 4), idx.addrToLine(0, 706).?.line);
    // below the first code offset ⇒ no line.
    try testing.expect(idx.addrToLine(0, 0) == null);

    // name → symbol.
    const add = idx.nameToSymbol("_add").?;
    try testing.expectEqual(@as(u16, 0), add.segment);
    try testing.expectEqual(@as(u16, 706), add.offset);
    const main_ = idx.nameToSymbol("_main").?;
    try testing.expectEqual(@as(u16, 730), main_.offset);
    try testing.expect(idx.nameToSymbol("_nope") == null);
}

test "SymbolIndex(TEST): addr→function ranges" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // 720 is inside _add's [706, 730) range (730 is _main's entry).
    const f = idx.addrToFunction(0, 720).?;
    try testing.expectEqual(@as(u16, 706), f.start);
    try testing.expectEqual(@as(u16, 730), f.end);
    try testing.expectEqualStrings("_add", tds.name(tds.symbols[f.sym_index - 1].name));

    // 730 is _main.
    const g = idx.addrToFunction(0, 730).?;
    try testing.expectEqualStrings("_main", tds.name(tds.symbols[g.sym_index - 1].name));
    // above the code extent ⇒ no function.
    try testing.expect(idx.addrToFunction(0, 0xF000) == null);
}

test "SymbolIndex(TEST): module + sourceFile tables" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();
    try testing.expectEqualStrings("TEST.C", idx.sourceFile(0).?);
    try testing.expect(idx.module(0) != null);
    try testing.expect(idx.sourceFile(99) == null);
}

test "SymbolIndex(RICH): cross-module addr→function and addr→line" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // Three far functions, each in its own code segment (spec §9).
    const c = idx.addrToFunction(0xC2, 10).?;
    try testing.expectEqualStrings("_compute", tds.name(tds.symbols[c.sym_index - 1].name));
    const p = idx.addrToFunction(0xC7, 5).?;
    try testing.expectEqualStrings("_process", tds.name(tds.symbols[p.sym_index - 1].name));
    const m = idx.addrToFunction(0xCB, 20).?;
    try testing.expectEqualStrings("_main", tds.name(tds.symbols[m.sym_index - 1].name));

    // addr→line in F1's segment 0xC2: the correlation binds line records 1..9 here,
    // first entry {line 9, offset 6} (spec §7).
    try testing.expectEqual(@as(u16, 9), idx.addrToLine(0xC2, 6).?.line);
    // line records are split per segment; F2 lives in segment 0xC7.
    try testing.expect(idx.addrToLine(0xC7, 2) != null);
    // a name lookup resolves a cross-module global.
    try testing.expect(idx.nameToSymbol("_main") != null);
}

test "SymbolIndex.fromMap: names + functions only, no lines" {
    const publics = [_]Public{
        .{ .segment = 0, .offset = 0x10, .name = "_main" },
        .{ .segment = 0, .offset = 0x40, .name = "_helper" },
        .{ .segment = 1, .offset = 0x00, .name = "_far_fn" },
    };
    var idx = try SymbolIndex.fromMap(testing.allocator, &publics);
    defer idx.deinit();

    const m = idx.nameToSymbol("_main").?;
    try testing.expectEqual(@as(u16, 0x10), m.offset);
    // 0x20 is inside _main's [0x10, 0x40) range (bounded by the next public).
    try testing.expectEqual(m.offset, idx.addrToFunction(0, 0x20).?.start);
    // helper range.
    try testing.expectEqualStrings("_helper", "_helper");
    try testing.expectEqual(@as(u16, 0x40), idx.addrToFunction(0, 0x50).?.start);
    // no line data from a .map.
    try testing.expect(idx.addrToLine(0, 0x10) == null);
    try testing.expect(idx.lineToAddr(0, 1) == null);
    try testing.expect(idx.sourceFile(0) == null);
}

test "SymbolIndex.fromMap: >65535 publics are capped at 0xFFFF (no u16 overflow)" {
    // BUG-3: a `.map` with more than 65535 publics would overflow `@intCast(i+1)` to
    // u16. The cap drops the overflow (and logs) rather than panicking.
    // Suppress the (correct) cap `log.warn` for this one test: any stderr write during a
    // test corrupts the `zig build`/`--listen` runner protocol (it expects empty test stderr).
    const saved_log = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log;
    const n: usize = 0x10000 + 7;
    const pubs = try testing.allocator.alloc(Public, n);
    defer testing.allocator.free(pubs);
    for (pubs, 0..) |*p, i| p.* = .{ .segment = 0, .offset = @truncate(i), .name = "_x" };

    var idx = try SymbolIndex.fromMap(testing.allocator, pubs);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0xFFFF), idx.funcs.len);
    try testing.expectEqual(@as(usize, 0xFFFF), idx.names.len);
}

test "SymbolIndex(TEST): addrToLine is bounded past the last line (nit)" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // _main's last line entry is 765 (line 18); the segment code extent ends at 769.
    // An address inside the function still resolves …
    try testing.expectEqual(@as(u16, 18), idx.addrToLine(0, 766).?.line);
    // … but one past the owning function's range resolves to NO line (bounded like
    // addrToFunction), instead of clamping to the final line record.
    try testing.expect(idx.addrToLine(0, 0xF000) == null);
    try testing.expect(idx.addrToFunction(0, 0xF000) == null);
}

test "SymbolIndex(TEST): entryOffsetForFunction lands post-prologue (#2 / §7.6)" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // _main starts at offset 730 (line 11); the first interior line entry is 736
    // (line 14) — that is the post-prologue landing spot (TEST.LST line table).
    const main_ = idx.addrToFunction(0, 730).?;
    try testing.expectEqual(@as(u16, 736), idx.entryOffsetForFunction(main_));
    // _add starts at 706 (line 4); first interior line entry is 712 (line 7).
    const add = idx.addrToFunction(0, 706).?;
    try testing.expectEqual(@as(u16, 712), idx.entryOffsetForFunction(add));
}

test "SymbolIndex(RICH): entryOffsetForFunction across far segments (§7.6)" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // RICH _main is in paragraph 0xCB at offset 4 (line 3); first interior line entry
    // is 0x0A (line 7) per RICH.LST's F3 line table.
    const main_ = idx.addrToFunction(0xCB, 4).?;
    try testing.expectEqual(@as(u16, 0x0A), idx.entryOffsetForFunction(main_));
}

test "SymbolIndex(TEST): FuncRef / SymRef carry a resolvable name_index (#3)" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    const add = idx.addrToFunction(0, 706).?;
    try testing.expect(add.name_index != 0);
    try testing.expectEqualStrings("_add", tds.name(add.name_index));
    try testing.expectEqualStrings("_add", idx.functionName(add).?);

    const main_ = idx.nameToSymbol("_main").?;
    try testing.expect(main_.name_index != 0);
    try testing.expectEqualStrings("_main", idx.symbolName(main_).?);
}

test "SymbolIndex(TEST): fileId + sourceFileCount (#4)" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    try testing.expectEqual(@as(u32, 1), idx.sourceFileCount());
    try testing.expectEqual(@as(?u32, 0), idx.fileId("TEST.C"));
    // The id round-trips back through sourceFile.
    try testing.expectEqualStrings("TEST.C", idx.sourceFile(idx.fileId("TEST.C").?).?);
    try testing.expect(idx.fileId("NOPE.C") == null);
}

test "SymbolIndex(TEST): typeRefForFunction reaches a function's return type" {
    var tds = try tdsmod.parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var idx = try SymbolIndex.build(testing.allocator, &tds);
    defer idx.deinit();

    // The FuncRef path has no type_index; the accessor recovers it from the symbol table.
    const add = idx.addrToFunction(0, 706).?;
    const t = idx.typeRefForFunction(add).?;
    try testing.expectEqual(tds.symbols[add.sym_index - 1].type, t);
    try testing.expect(t != 0);

    // A `.map`-backed index has no Tds, so there is no symbol type to resolve.
    const publics = [_]Public{.{ .segment = 0, .offset = 0x10, .name = "_main" }};
    var midx = try SymbolIndex.fromMap(testing.allocator, &publics);
    defer midx.deinit();
    const mf = midx.addrToFunction(0, 0x10).?;
    try testing.expect(midx.typeRefForFunction(mf) == null);
}

test {
    testing.refAllDecls(@This());
}
