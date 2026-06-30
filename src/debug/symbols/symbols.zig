//! `src/debug/symbols/` — the host-side, load-time Borland TDS symbol overlay
//! (Tier 1). This is the module sub-root; it re-exports the public surface and
//! aggregates the unit tests (mirrors `src/debug/debug.zig`).
//!
//! Architecture (plan §1.2, the load_para seam):
//!
//!   EXE bytes ──parse──► Tds (raw, image-relative)
//!                          └─index──► SymbolIndex (image-relative lookups)
//!                                       └─attach(psp_seg)──► AddressMap (runtime-linear)
//!
//! Determinism (CLAUDE.md §1): the whole overlay is a *pure function of the EXE
//! bytes*. It reads no host clock/RNG/env, uses sorted arrays (never hashed/unordered
//! containers), allocates only host memory tied to the loaded program, is NEVER part
//! of `Machine.Snapshot`, and is re-attached on load exactly like `LoadRecipe`. The five
//! sources here are listed in `src/debug/determinism_test.zig`'s grep gate.
//!
//! Tier 1 builds `addrToLine` / `lineToAddr` / `addrToFunction` / `nameToSymbol` plus
//! the module / source-file tables. Types and members are *parsed* into `Tds` but the
//! type graph and locals indices are Tier 2 (deliberately deferred).

const std = @import("std");

// ── byte-exact format (spec §16) ──
pub const format = @import("format.zig");

// ── parser: EXE/TDS bytes → Tds ──
const tds = @import("tds.zig");
pub const Tds = tds.Tds;
pub const ParseError = tds.ParseError;
pub const parseExe = tds.parseExe;
pub const parseTds = tds.parseTds;

// ── image-relative indices ──
const index = @import("index.zig");
pub const SymbolIndex = index.SymbolIndex;
pub const ImageAddr = index.ImageAddr;
pub const LineHit = index.LineHit;
pub const FuncRef = index.FuncRef;
pub const SymRef = index.SymRef;
pub const Public = index.Public;

// ── Tier-2: type graph + member layout + enumerators + scope-locals ──
const types = @import("types.zig");
pub const TypeGraph = types.TypeGraph;
pub const TypeInfo = types.TypeInfo;
pub const MemberInfo = types.MemberInfo;
pub const EnumeratorInfo = types.EnumeratorInfo;
pub const Local = types.Local;
pub const Storage = types.Storage;
pub const PtrKind = types.PtrKind;
pub const primitiveName = types.primitiveName;

// ── runtime-linear mapping (the only load_para consumer) ──
const map = @import("map.zig");
pub const AddressMap = map.AddressMap;

// ── .map fallback (names/functions only) ──
pub const mapfile = @import("mapfile.zig");

// ─────────────────────────── owning façade ───────────────────────────

/// `Symbols` — the single owning entry point the debug core holds. It bundles the
/// (optional) `Tds`, the `SymbolIndex`, and the (optional) `TypeGraph` under ONE
/// lifetime + ONE `deinit`, so the caller is freed of the 3-separate-arenas /
/// deinit-order burden (#6).
///
/// `open` applies the source precedence **embedded-TDS → `.map` → none**:
///   * a parseable embedded TDS gives full symbols (names + lines + types + scopes);
///   * else a `.map` gives names + functions only (`tds == null`, `typegraph == null`);
///   * else a graceful empty index (`source == .none`) that answers everything `null`.
///
/// Lifetime: the owned `Tds` is heap-allocated so its address is stable — the `index`
/// and `typegraph` back-reference it by pointer, and a `Symbols` value can be moved
/// (returned from `open`, stored in a field) without dangling. The caller must keep the
/// `Symbols` at a stable address while any `AddressMap` from `attach` is live (the map
/// borrows `&self.index`).
pub const Symbols = struct {
    pub const Error = error{OutOfMemory};

    /// Which symbol source `open` selected.
    pub const Source = enum { tds, map, none };

    gpa: std.mem.Allocator,
    source: Source,
    tds: ?*Tds, // heap-owned (stable address for index/typegraph back-refs)
    index: SymbolIndex, // always present (empty when source == .none)
    typegraph: ?TypeGraph, // present only for a TDS source (.tds points at the heap Tds)

    /// Open a symbol overlay for `exe_bytes`, optionally backed by a sidecar `.map`'s
    /// text. Precedence: embedded TDS → `.map` → none. Only `OutOfMemory` propagates;
    /// an unparseable TDS / `.map` is not an error — it just lowers the precedence.
    pub fn open(gpa: std.mem.Allocator, exe_bytes: []const u8, opt_map_bytes: ?[]const u8) Error!Symbols {
        // 1. embedded TDS (full symbols).
        if (try tryOpenTds(gpa, exe_bytes)) |s| return s;

        // 2. `.map` sidecar (names + functions only).
        if (opt_map_bytes) |mb| {
            if (mapfile.parse(gpa, mb)) |idx| {
                return .{ .gpa = gpa, .source = .map, .tds = null, .index = idx, .typegraph = null };
            } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        }

        // 3. none — a graceful empty index (every lookup returns null).
        const idx = try SymbolIndex.fromMap(gpa, &.{});
        return .{ .gpa = gpa, .source = .none, .tds = null, .index = idx, .typegraph = null };
    }

    /// Try to build a full TDS-backed `Symbols`. Returns null when `exe_bytes` carries
    /// no parseable embedded TDS; only `OutOfMemory` is an error.
    fn tryOpenTds(gpa: std.mem.Allocator, exe_bytes: []const u8) Error!?Symbols {
        var parsed = tds.parseExe(gpa, exe_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null, // no/!unsupported TDS → fall through to the .map path
        };
        const tds_ptr = gpa.create(Tds) catch |e| {
            parsed.deinit();
            return e;
        };
        tds_ptr.* = parsed;
        errdefer {
            tds_ptr.deinit();
            gpa.destroy(tds_ptr);
        }
        var idx = try SymbolIndex.build(gpa, tds_ptr);
        errdefer idx.deinit();
        const tg = try TypeGraph.build(gpa, tds_ptr);
        return Symbols{ .gpa = gpa, .source = .tds, .tds = tds_ptr, .index = idx, .typegraph = tg };
    }

    pub fn deinit(self: *Symbols) void {
        if (self.typegraph) |*tg| tg.deinit();
        self.index.deinit();
        if (self.tds) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
    }

    /// Attach the owned index to a concrete load (`psp_seg`), yielding the runtime-
    /// linear `AddressMap`. Borrows `&self.index` — keep `self` alive at a stable
    /// address while the returned map is in use.
    pub fn attach(self: *const Symbols, psp_seg: u16) AddressMap {
        return AddressMap.attach(&self.index, psp_seg);
    }

    /// PC-linear → innermost scope in one call (#7): runtime linear address → image
    /// `(seg, off)` (via `am`) → the 0-based innermost enclosing scope index. Null when
    /// there is no type graph (`.map` / none source) or no scope owns the address. Walk
    /// the parent chain with `TypeGraph.parentOf` for the full visible-local set.
    pub fn scopeForRuntimeAddr(self: *const Symbols, am: AddressMap, linear: u32) ?usize {
        const tg = if (self.typegraph) |*t| t else return null;
        const ia = am.imageAddrForLinear(linear) orelse return null;
        return tg.scopeForAddr(ia.segment, ia.offset);
    }
};

test {
    _ = format;
    _ = tds;
    _ = index;
    _ = types;
    _ = map;
    _ = mapfile;
    _ = @import("blackbox_test.zig");
}

// ───────────────────────────── façade tests ─────────────────────────────

const testing = std.testing;
const test_exe = @embedFile("testdata/TEST.EXE");
const rich_exe = @embedFile("testdata/RICH.EXE");

const sample_map =
    \\ Start  Stop   Length Name               Class
    \\ 00000H 0070FH 00710H _TEXT              CODE
    \\
    \\  Address         Publics by Name
    \\
    \\ 0000:0010       _main
    \\ 0000:0040       _helper
    \\
    \\Program entry point at 0000:0010
;

test "Symbols.open: embedded TDS → full symbols (names + lines + types), clean deinit" {
    var syms = try Symbols.open(testing.allocator, test_exe, null);
    defer syms.deinit();

    try testing.expectEqual(Symbols.Source.tds, syms.source);
    try testing.expect(syms.tds != null);
    try testing.expect(syms.typegraph != null);

    // Names + lines resolve through the owned index.
    try testing.expectEqual(@as(u16, 730), syms.index.nameToSymbol("_main").?.offset);
    try testing.expectEqual(@as(u16, 11), syms.index.addrToLine(0, 730).?.line);
    try testing.expectEqual(@as(?u32, 0), syms.index.fileId("TEST.C"));

    // attach → runtime map round-trips.
    const am = syms.attach(0x0210);
    const lin = am.toRuntimeLinear(0, 730);
    try testing.expectEqualStrings("_main", syms.index.functionName(am.functionForRuntimeAddr(lin).?).?);
}

test "Symbols.open: no TDS but a .map → names + functions only" {
    // `exe_bytes` has no embedded TDS (too short to carry a trailer), so the .map wins.
    var syms = try Symbols.open(testing.allocator, "MZ", sample_map);
    defer syms.deinit();

    try testing.expectEqual(Symbols.Source.map, syms.source);
    try testing.expect(syms.tds == null);
    try testing.expect(syms.typegraph == null);

    try testing.expectEqual(@as(u16, 0x10), syms.index.nameToSymbol("_main").?.offset);
    // .map-backed reverse lookup (functionForRuntimeAddr) works without a Tds (D7).
    const am = syms.attach(0x0040);
    const f = am.functionForRuntimeAddr(am.toRuntimeLinear(0, 0x20)).?;
    try testing.expectEqual(@as(u16, 0x10), f.start);
    // no line data / no scope graph from a .map.
    try testing.expect(syms.index.addrToLine(0, 0x10) == null);
    try testing.expect(syms.scopeForRuntimeAddr(am, am.toRuntimeLinear(0, 0x20)) == null);
}

test "Symbols.open: neither TDS nor .map → graceful 'none'" {
    var syms = try Symbols.open(testing.allocator, "MZ", null);
    defer syms.deinit();

    try testing.expectEqual(Symbols.Source.none, syms.source);
    try testing.expect(syms.tds == null);
    try testing.expect(syms.typegraph == null);
    try testing.expect(syms.index.nameToSymbol("_main") == null);
    const am = syms.attach(0x0040);
    try testing.expect(am.functionForRuntimeAddr(am.toRuntimeLinear(0, 0)) == null);
}

test "Symbols.scopeForRuntimeAddr: RICH PC-linear → innermost scope (#7)" {
    var syms = try Symbols.open(testing.allocator, rich_exe, null);
    defer syms.deinit();
    const am = syms.attach(0x0040);

    // RICH F1 lives in code paragraph 0xC2; scope0 [0x06,0x52), scope1 [0x0d,0x52),
    // scope2 [0x39,0x48) — matches types.zig's scopeForAddr oracle.
    try testing.expectEqual(@as(?usize, 0), syms.scopeForRuntimeAddr(am, am.toRuntimeLinear(0xC2, 0x08)));
    try testing.expectEqual(@as(?usize, 1), syms.scopeForRuntimeAddr(am, am.toRuntimeLinear(0xC2, 0x20)));
    try testing.expectEqual(@as(?usize, 2), syms.scopeForRuntimeAddr(am, am.toRuntimeLinear(0xC2, 0x40)));
    // Well past the last (0xCB) code segment ⇒ no scope. (NB: an address just past a
    // far segment's code can physically land inside the next far segment's code — the
    // linear path is physical — so we probe an address beyond ALL code here.)
    try testing.expectEqual(@as(?usize, null), syms.scopeForRuntimeAddr(am, am.toRuntimeLinear(0xCB, 0x100)));
}
