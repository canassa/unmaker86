//! `tds.zig` — the Borland TDS byte parser. `parseExe` / `parseTds` turn the raw
//! bytes of a BC++3.1 MZ EXE (with an appended TDS block) or a `.TDS` sidecar into a
//! `Tds`: the raw, owned, **image-relative** record tables plus the name pool.
//!
//! Determinism (CLAUDE.md §1): this is a *pure function of the input bytes*. It does
//! no host I/O, reads no clock/RNG/env, uses no floats/threads/hashmaps, and never
//! enters `Machine.Snapshot`. It allocates host memory (an arena tied to the loaded
//! program) because it runs at load time, never on the cycle-stepped path. Identical
//! input ⇒ byte-identical output.
//!
//! Boundary (plan §1.2): `tds.zig` is *image-relative only* — it knows nothing about
//! `load_para`/runtime relocation. That seam lives in `map.zig`. Every address it
//! emits is a TDS `(segment, offset)` pair exactly as stored on disk.
//!
//! Robustness (plan §6): a missing trailer / wrong magic / wrong version / truncated
//! or self-inconsistent block yields a clean `error` (→ "no symbols"), never a crash
//! or a half-built (silently wrong) index.

const std = @import("std");
const format = @import("format.zig");

pub const ParseError = error{
    NoTrailer,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    OutOfMemory,
};

/// Raw, owned TDS tables (image-relative). Everything is owned by `arena`; one
/// `deinit` frees the lot. All record arrays are exactly as they appear on disk;
/// 1-based name/type/member references are kept raw and resolved lazily (see `name`).
pub const Tds = struct {
    arena: std.heap.ArenaAllocator,
    header: format.Header,
    ext: format.ExtHeader,

    symbols: []format.Symbol,
    modules: []format.Module,
    sources: []format.SourceFile,
    lines: []format.Line,
    scopes: []format.Scope,
    segments: []format.Segment,
    correlations: []format.Correlation,
    types: []format.Type,
    members: []format.Member,

    /// Owned copy of the EOF name pool (1-based, NUL-terminated strings).
    name_pool: []u8,
    /// `name_starts[i]` = byte offset of the (i+1)-th string in `name_pool`.
    name_starts: []u32,

    /// Resolve a 1-based name-pool index to its string. Index 0 (and any
    /// out-of-range index) resolves to "" — the anonymous/none sentinel.
    pub fn name(self: *const Tds, idx: u16) []const u8 {
        if (idx == 0 or idx > self.name_starts.len) return "";
        const start = self.name_starts[idx - 1];
        const end = std.mem.indexOfScalarPos(u8, self.name_pool, start, 0) orelse self.name_pool.len;
        return self.name_pool[start..end];
    }

    pub fn deinit(self: *Tds) void {
        self.arena.deinit();
    }
};

/// Locate the TDS trailer in an MZ EXE and parse it. The trailer offset comes from
/// the MZ header's page fields (spec §1); if the word there is not the magic, scan
/// backwards for `0x52FB` (handles TLINK variants that include/exclude the block in
/// the page count — plan §3.1).
pub fn parseExe(gpa: std.mem.Allocator, exe_bytes: []const u8) ParseError!Tds {
    const base = try locateTrailer(exe_bytes);
    return parseTds(gpa, exe_bytes[base..]);
}

/// Parse a TDS block whose first bytes are the `0x52FB` header (an embedded block
/// already sliced at the trailer, or a `.TDS` sidecar that begins at the header).
/// The name pool runs to the end of `tds_bytes`.
pub fn parseTds(gpa: std.mem.Allocator, tds_bytes: []const u8) ParseError!Tds {
    if (tds_bytes.len < format.stride(format.Header) + format.stride(format.ExtHeader))
        return error.Truncated;

    const header = readRec(format.Header, tds_bytes, 0) orelse return error.Truncated;
    if (header.magic != format.MAGIC) return error.BadMagic;
    // Target TDS 3.10 (16-bit BC++ 3.1). Reject 2.x and the TD32 variants.
    if (header.major_version != 3) return error.UnsupportedVersion;

    const ext_off = format.stride(format.Header);
    const ext = readRec(format.ExtHeader, tds_bytes, ext_off) orelse return error.Truncated;

    // The name pool is anchored at EOF: start = len - names_pool_size (spec §3.4).
    if (header.names_pool_size > tds_bytes.len) return error.Truncated;
    const names_pool_start: usize = tds_bytes.len - header.names_pool_size;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var cur = Cursor{ .bytes = tds_bytes, .off = ext_off + header.extension_size };

    // ---- the fixed-stride record blocks, in the confirmed on-disk order (spec §3) ----
    const symbols = try cur.readTable(a, format.Symbol, header.symbols_count);
    const modules = try cur.readTable(a, format.Module, header.modules_count);
    const sources = try cur.readTable(a, format.SourceFile, header.srcfiles_count);
    const lines = try cur.readTable(a, format.Line, header.lines_count);
    const scopes = try cur.readTable(a, format.Scope, header.scopes_count);
    const segments = try cur.readTable(a, format.Segment, header.segments_count);
    const correlations = try cur.readTable(a, format.Correlation, header.correlations_count);
    const types = try cur.readTable(a, format.Type, header.types_count);
    const members = try cur.readTable(a, format.Member, header.members_count);

    // ---- C++ extension tables (all zero-length for plain C; spec §15) ----
    try cur.skip(format.stride(format.ClassRecord) * ext.class_entries);
    try cur.skip(format.stride(format.ParentRecord) * ext.parent_entries);
    try cur.skip(format.stride(format.ClassRange) * ext.scope_class_entries);
    try cur.skip(format.stride(format.ClassRange) * ext.module_class_entries);
    // The 4-byte C++ coverage-prefix word is present iff class_entries > 0 (spec §15.6).
    if (ext.class_entries > 0) try cur.skip(4);

    // ---- trailing tables (present on every fixture; spec §11) ----
    try cur.skip(@as(usize, 2) * header.segments_count); // coverage map
    try cur.skip(@as(usize, 2) * ext.coverage_count); // coverage offsets
    try cur.skip(@as(usize, 4) * header.modules_count); // module-opt flags
    // ---- BC++ 3.1 always emits zero of these, but honor the counts anyway ----
    try cur.skip(format.stride(format.BrowserRecord) * ext.browser_entries);
    try cur.skip(format.stride(format.OptSymRecord) * ext.opt_sym_entries);
    try cur.skip(@as(usize, ext.ref_info_size));

    // The catch-all correctness guard (plan §3.3): the cumulative block walk must
    // land EXACTLY on the EOF-anchored name pool. Any wrong record size, missing
    // table, or count drift trips this — the single assertion that validates the
    // entire layout against the bytes.
    if (cur.off != names_pool_start) return error.Truncated;

    // ---- name pool (owned copy) + 1-based string-start table ----
    const name_pool = try a.dupe(u8, tds_bytes[names_pool_start..]);
    const name_starts = try a.alloc(u32, header.names_count);
    {
        var pos: usize = 0;
        var i: usize = 0;
        while (i < header.names_count) : (i += 1) {
            if (pos > name_pool.len) return error.Truncated;
            name_starts[i] = @intCast(pos);
            const nul = std.mem.indexOfScalarPos(u8, name_pool, pos, 0) orelse return error.Truncated;
            pos = nul + 1;
        }
    }

    return .{
        .arena = arena,
        .header = header,
        .ext = ext,
        .symbols = symbols,
        .modules = modules,
        .sources = sources,
        .lines = lines,
        .scopes = scopes,
        .segments = segments,
        .correlations = correlations,
        .types = types,
        .members = members,
        .name_pool = name_pool,
        .name_starts = name_starts,
    };
}

/// MZ page math: `base = file_size_in_pages*512 - (512 - used_bytes_in_last_page)`,
/// treating `used == 0` as 512 (spec §1). Falls back to a backward `0x52FB` scan.
fn locateTrailer(exe: []const u8) ParseError!usize {
    if (exe.len < 6) return error.NoTrailer;
    const used_raw = std.mem.readInt(u16, exe[0x02..0x04], .little);
    const pages = std.mem.readInt(u16, exe[0x04..0x06], .little);
    // `used` is the untrusted "bytes in the last page" field: a well-formed image has
    // it in `1..=512` (with 0 meaning a full 512-byte page). Anything > 512 is
    // malformed — clamp it so `512 - used` can never underflow `usize` (BUG-1). A
    // clamped value just fails the page-math magic check below and falls through to
    // the backward `0x52FB` scan, which yields a clean error rather than a panic.
    const used: usize = if (used_raw == 0) 512 else @min(@as(usize, used_raw), 512);
    const computed: usize = @as(usize, pages) * 512;
    if (computed >= 512 - used) {
        const base = computed - (512 - used);
        if (base + 2 <= exe.len and std.mem.readInt(u16, exe[base..][0..2], .little) == format.MAGIC)
            return base;
    }
    // Fallback: scan backwards in 2-byte steps for the magic (plan §3.1).
    if (exe.len >= 2) {
        var off: usize = exe.len - 2;
        while (true) : (off -= 2) {
            if (std.mem.readInt(u16, exe[off..][0..2], .little) == format.MAGIC) return off;
            if (off < 2) break;
        }
    }
    return error.NoTrailer;
}

/// A bounds-checked forward walk over the TDS block.
const Cursor = struct {
    bytes: []const u8,
    off: usize,

    /// Read `count` records of `T` into a freshly allocated slice, advancing past
    /// them. Bounds-checked: an out-of-range read is `error.Truncated`.
    fn readTable(self: *Cursor, a: std.mem.Allocator, comptime T: type, count: usize) ParseError![]T {
        const sz = format.stride(T);
        const need = sz * count;
        if (self.off + need > self.bytes.len) return error.Truncated;
        const out = try a.alloc(T, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = readRec(T, self.bytes, self.off + i * sz).?;
        }
        self.off += need;
        return out;
    }

    /// Advance past a region (a skipped table), bounds-checked.
    fn skip(self: *Cursor, n: usize) ParseError!void {
        if (self.off + n > self.bytes.len) return error.Truncated;
        self.off += n;
    }
};

/// Decode a fixed packed-struct record at `off` via `@bitCast` from its byte array.
/// Returns null if the record would read past the buffer end (caller maps to
/// `error.Truncated`). The on-disk width is `format.stride(T)` (the byte-exact
/// `@bitSizeOf/8`, NOT `@sizeOf`, which over-aligns the backing integer).
fn readRec(comptime T: type, bytes: []const u8, off: usize) ?T {
    const sz = comptime format.stride(T);
    if (off + sz > bytes.len) return null;
    return @bitCast(bytes[off..][0..sz].*);
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

const test_exe = @embedFile("testdata/TEST.EXE");
const rich_exe = @embedFile("testdata/RICH.EXE");

const all_fixtures = [_]struct { name: []const u8, bytes: []const u8 }{
    .{ .name = "TEST", .bytes = @embedFile("testdata/TEST.EXE") },
    .{ .name = "RICH", .bytes = @embedFile("testdata/RICH.EXE") },
    .{ .name = "ENUM", .bytes = @embedFile("testdata/ENUM.EXE") },
    .{ .name = "CLS", .bytes = @embedFile("testdata/CLS.EXE") },
    .{ .name = "MI", .bytes = @embedFile("testdata/MI.EXE") },
    .{ .name = "LCLS", .bytes = @embedFile("testdata/LCLS.EXE") },
    .{ .name = "MMC", .bytes = @embedFile("testdata/MMC.EXE") },
    .{ .name = "MMH", .bytes = @embedFile("testdata/MMH.EXE") },
    .{ .name = "MMT", .bytes = @embedFile("testdata/MMT.EXE") },
    .{ .name = "PTR", .bytes = @embedFile("testdata/PTR.EXE") },
    .{ .name = "BENUM", .bytes = @embedFile("testdata/BENUM.EXE") },
    .{ .name = "INC", .bytes = @embedFile("testdata/INC.EXE") },
};

test "parseExe: TEST.EXE trailer + header counts" {
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();

    const h = tds.header;
    try testing.expectEqual(@as(u16, format.MAGIC), h.magic);
    try testing.expectEqual(@as(u8, 3), h.major_version);
    try testing.expectEqual(@as(u8, 0x10), h.minor_version);
    try testing.expectEqual(@as(u16, 0x20), h.extension_size);
    try testing.expectEqual(@as(u16, 87), h.names_count);
    try testing.expectEqual(@as(u16, 26), h.types_count);
    try testing.expectEqual(@as(u16, 3), h.members_count);
    try testing.expectEqual(@as(u16, 84), h.symbols_count);
    try testing.expectEqual(@as(u16, 77), h.globals_count);
    try testing.expectEqual(@as(u16, 1), h.modules_count);
    try testing.expectEqual(@as(u16, 0), h.locals_count);
    try testing.expectEqual(@as(u16, 4), h.scopes_count);
    try testing.expectEqual(@as(u16, 10), h.lines_count);
    try testing.expectEqual(@as(u16, 1), h.srcfiles_count);
    try testing.expectEqual(@as(u16, 1), h.segments_count);
    try testing.expectEqual(@as(u16, 1), h.correlations_count);
    try testing.expectEqual(@as(u32, 773), h.names_pool_size);

    // Header byte size = 0x30 base + 0x20 ext = 80 (regression guard for the fix).
    try testing.expectEqual(@as(usize, 80), format.stride(format.Header) + h.extension_size);
}

test "parseExe: TEST.EXE table sizes match the header" {
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    try testing.expectEqual(@as(usize, 84), tds.symbols.len);
    try testing.expectEqual(@as(usize, 1), tds.modules.len);
    try testing.expectEqual(@as(usize, 1), tds.sources.len);
    try testing.expectEqual(@as(usize, 10), tds.lines.len);
    try testing.expectEqual(@as(usize, 4), tds.scopes.len);
    try testing.expectEqual(@as(usize, 1), tds.segments.len);
    try testing.expectEqual(@as(usize, 1), tds.correlations.len);
    try testing.expectEqual(@as(usize, 26), tds.types.len);
    try testing.expectEqual(@as(usize, 3), tds.members.len);
}

test "parseExe: TEST.EXE name pool 1-based resolution" {
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    // index 0 = anonymous "".
    try testing.expectEqualStrings("", tds.name(0));
    try testing.expectEqualStrings("__AHSHIFT", tds.name(1));
    try testing.expectEqualStrings("__cleanup", tds.name(2));
    try testing.expectEqualStrings("__checknull", tds.name(3));
    // last name (index 87) is the source file TEST.C.
    try testing.expectEqualStrings("TEST.C", tds.name(87));
    // out-of-range resolves to "" rather than panicking.
    try testing.expectEqualStrings("", tds.name(88));
}

test "parseExe: TEST.EXE line table is byte-exact (module=16 regression)" {
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    const want = [_][2]u16{
        .{ 4, 706 },  .{ 7, 712 },  .{ 8, 721 },  .{ 9, 726 },  .{ 11, 730 },
        .{ 14, 736 }, .{ 15, 741 }, .{ 16, 746 }, .{ 17, 760 }, .{ 18, 765 },
    };
    try testing.expectEqual(want.len, tds.lines.len);
    for (want, tds.lines) |w, got| {
        try testing.expectEqual(w[0], got.line);
        try testing.expectEqual(w[1], got.code_offset);
    }
}

test "parseExe: TEST.EXE _add / _main symbol addresses" {
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    var add: ?format.Symbol = null;
    var main_: ?format.Symbol = null;
    for (tds.symbols) |s| {
        const nm = tds.name(s.name);
        if (std.mem.eql(u8, nm, "_add")) add = s;
        if (std.mem.eql(u8, nm, "_main")) main_ = s;
    }
    try testing.expect(add != null);
    try testing.expect(main_ != null);
    try testing.expectEqual(@as(u16, 0), add.?.segment);
    try testing.expectEqual(@as(u16, 706), add.?.offset);
    try testing.expect(add.?.isFunction());
    try testing.expectEqual(@as(u16, 0), main_.?.segment);
    try testing.expectEqual(@as(u16, 730), main_.?.offset);
    try testing.expect(main_.?.isFunction());
}

test "parseExe: TEST.EXE source-file record {name=87, timestamp=0x5cddb81b}" {
    // NOTE: the plan §8.1 example bytes `dd 5c 04 00 c2 02` were wrong; the real
    // record is `57 00 1b b8 dd 5c` = {name: u16 = 87, timestamp: u32 = 0x5cddb81b},
    // which matches the spec §6 ("TEST.C 0x5CDDB81B"). Asserting the spec value.
    var tds = try parseExe(testing.allocator, test_exe);
    defer tds.deinit();
    try testing.expectEqual(@as(usize, 1), tds.sources.len);
    try testing.expectEqual(@as(u16, 87), tds.sources[0].name);
    try testing.expectEqual(@as(u32, 0x5cddb81b), tds.sources[0].timestamp);
    try testing.expectEqualStrings("TEST.C", tds.name(tds.sources[0].name));
}

test "parseExe: RICH.EXE is multi-module (3 modules / 3 segments / 3 correlations)" {
    var tds = try parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    try testing.expectEqual(@as(usize, 3), tds.modules.len);
    try testing.expectEqual(@as(usize, 3), tds.segments.len);
    try testing.expectEqual(@as(usize, 3), tds.correlations.len);
    // The three far code segments at their image-relative paragraphs (spec §9).
    try testing.expectEqual(@as(u16, 0xC2), tds.segments[0].code_segment);
    try testing.expectEqual(@as(u16, 0xC7), tds.segments[1].code_segment);
    try testing.expectEqual(@as(u16, 0xCB), tds.segments[2].code_segment);
    // Correlations bind contiguous line-record runs to each segment (spec §10).
    try testing.expectEqual(@as(u16, 1), tds.correlations[0].line_first);
    try testing.expectEqual(@as(u16, 9), tds.correlations[0].line_count);
    try testing.expectEqual(@as(u16, 10), tds.correlations[1].line_first);
    try testing.expectEqual(@as(u16, 8), tds.correlations[1].line_count);
    try testing.expectEqual(@as(u16, 18), tds.correlations[2].line_first);
    try testing.expectEqual(@as(u16, 5), tds.correlations[2].line_count);
}

test "parseExe: the block walk lands exactly on the name pool for all 12 fixtures" {
    // This is the catch-all guard: if any record size / table count is wrong, the
    // cumulative walk misses names_pool_start and parseTds returns error.Truncated.
    for (all_fixtures) |fx| {
        var tds = parseExe(testing.allocator, fx.bytes) catch |e| {
            std.debug.print("fixture {s} failed to parse: {}\n", .{ fx.name, e });
            return e;
        };
        defer tds.deinit();
        // Sanity: the resolved name count is exactly what the header promised.
        try testing.expectEqual(@as(usize, tds.header.names_count), tds.name_starts.len);
    }
}

test "parseExe: parsing is deterministic (byte-identical tables on re-parse)" {
    var a = try parseExe(testing.allocator, rich_exe);
    defer a.deinit();
    var b = try parseExe(testing.allocator, rich_exe);
    defer b.deinit();
    try testing.expectEqualSlices(format.Symbol, a.symbols, b.symbols);
    try testing.expectEqualSlices(format.Line, a.lines, b.lines);
    try testing.expectEqualSlices(format.Segment, a.segments, b.segments);
    try testing.expectEqualSlices(u8, a.name_pool, b.name_pool);
    try testing.expectEqualSlices(u32, a.name_starts, b.name_starts);
}

test "parseExe: malformed inputs degrade to a clean error (never a crash)" {
    // Empty / too-short slice ⇒ no trailer.
    try testing.expectError(error.NoTrailer, parseExe(testing.allocator, ""));
    try testing.expectError(error.NoTrailer, parseExe(testing.allocator, "MZ"));

    // BUG-1: a crafted MZ whose "bytes-in-last-page" word (0x02) is 0xFFFF (> 512)
    // must NOT underflow `512 - used` in locateTrailer. With the clamp it falls
    // through to the backward scan and (finding no 0x52FB) returns a clean error.
    {
        var buf = [_]u8{0} ** 64;
        buf[0] = 'M';
        buf[1] = 'Z';
        buf[2] = 0xFF; // used_raw low
        buf[3] = 0xFF; // used_raw high  ⇒ 0xFFFF, far past 512
        buf[4] = 0x01; // pages low
        buf[5] = 0x00; // pages high     ⇒ 1 page
        try testing.expectError(error.NoTrailer, parseExe(testing.allocator, &buf));
    }

    // Truncated mid-record-block: keep the MZ page fields (so the trailer is located)
    // but cut the file short so the block walk overruns ⇒ Truncated.
    {
        const cut = test_exe[0 .. test_exe.len - 200];
        try testing.expectError(error.Truncated, parseExe(testing.allocator, cut));
    }

    // Clobber the trailer magic to 0x0000; the backward scan finds no 0x52FB ⇒ NoTrailer.
    {
        const buf = try testing.allocator.dupe(u8, test_exe);
        defer testing.allocator.free(buf);
        for (buf, 0..) |b, i| {
            if (b == 0xFB and i + 1 < buf.len and buf[i + 1] == 0x52) {
                buf[i] = 0;
                buf[i + 1] = 0;
            }
        }
        try testing.expectError(error.NoTrailer, parseExe(testing.allocator, buf));
    }

    // Patch major_version to 2 ⇒ UnsupportedVersion (locate trailer first).
    {
        const buf = try testing.allocator.dupe(u8, test_exe);
        defer testing.allocator.free(buf);
        const base = try locateTrailer(buf);
        buf[base + 3] = 2;
        try testing.expectError(error.UnsupportedVersion, parseExe(testing.allocator, buf));
    }

    // names_pool_size larger than the file ⇒ Truncated.
    {
        const buf = try testing.allocator.dupe(u8, test_exe);
        defer testing.allocator.free(buf);
        const base = try locateTrailer(buf);
        std.mem.writeInt(u32, buf[base + 4 ..][0..4], 0x0010_0000, .little);
        try testing.expectError(error.Truncated, parseExe(testing.allocator, buf));
    }
}

test {
    testing.refAllDecls(@This());
}
