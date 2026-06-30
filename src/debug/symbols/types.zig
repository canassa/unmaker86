//! `types.zig` — Tier-2 of the Borland TDS symbol overlay: the **type graph**,
//! **struct/union/enum member layout**, **enum enumerators**, and the **scope-locals**
//! index. This is what turns the already-parsed `Tds.types` / `Tds.members` /
//! `Tds.scopes` / symbol-locals (Tier 1 only *parses* them) into the data a debug
//! frame needs for source-level variable inspection and typed rendering.
//!
//! Tier boundary (see `index.zig`): Tier 1 builds addr↔line / addr→function /
//! name→symbol. Tier 2 (here) builds:
//!   * `typeInfo` / `typeName` — resolve + render a type reference (§12 type-walk),
//!   * `members` — struct/union member layout with byte offsets (§13),
//!   * `enumerators` — enum → enumerator linkage via the aux range record (§12.3a),
//!   * `localsForScope` / `scopeForAddr` — the scope tree + per-scope locals (§4/§8).
//!
//! Type-reference model (spec §12, CONFIRMED-EMPIRICALLY): a type reference — a symbol
//! `type`, a member `type`, or a type record `member_type` — is a **1-based index into
//! `Tds.types`**. There is NO separate "predefined `< 0x18`" space: the predefined
//! primitives are materialised as real records at fixed low indices (slot 4 = `int`,
//! slot 6 = `long`, …). The bytes prove it: member `x` of `struct Point` carries
//! `type = 4`, which resolves to type record #4 (`id = SINT`), i.e. `int`. (The earlier
//! `ref - 0x18` scheme — which would map `4 → SCHAR` — is the model §12 explicitly
//! corrects; this file follows the confirmed 1-based-index model.)
//!
//! Determinism (CLAUDE.md §1): a *pure function of `Tds`*. No host clock / RNG / env /
//! threads / floats / unordered containers — only dense arrays and integer math, so same
//! `Tds` always yields byte-identical indices. The result PODs (`TypeInfo`, `MemberInfo`,
//! `EnumeratorInfo`, `Local`) hold only integers / enums — no borrowed name pointer —
//! so a host address can never leak into a snapshot or the M2 JSON (reflection gate).
//! Names are returned as 1-based `name_index`es; resolve them with `Tds.name`.

const std = @import("std");
const format = @import("format.zig");
const tdsmod = @import("tds.zig");

pub const Tds = tdsmod.Tds;
const TypeId = format.TypeId;

/// How a pointer reaches its target (the §12.2 pointer `class` byte, C-side flavor).
pub const PtrKind = enum {
    near, // near, segment unspecified
    far, // plain far pointer
    huge, // segment-normalising far pointer
    near_es, // _ES-relative near
    near_cs, // _CS-relative near
    near_ss, // _SS-relative near
    near_ds, // _DS-relative near
    near_fs, // _FS-relative near
    near_gs, // _GS-relative near
};

/// A resolved type reference (§12 type-walk). Pointer-free: aggregates / enums carry
/// only their tag `name_index` and the member/enumerator *ranges* (resolved lazily via
/// `members` / `enumerators`), never a borrowed slice — so cycles (e.g. a `struct Node`
/// whose member is `struct Node *`) terminate naturally (a pointer renders the pointee
/// by *name*, it does not expand it).
pub const TypeInfo = union(enum) {
    /// A type id this layer does not model (range markers, Pascal/Basic ids, …).
    unknown: struct { id: u8 },
    /// A built-in scalar — render via `primitiveName(id)`.
    primitive: struct { id: TypeId, size: u16 },
    pointer: struct { kind: PtrKind, pointee: u16, size: u16 },
    array: struct { element: u16, count: u32, size: u16 },
    aggregate: struct {
        name_index: u16,
        size: u16,
        is_union: bool,
        is_class: bool,
        first_member: u16, // 1-based member-table index (0 for a C++ class: §12.3)
        member_count: u16,
    },
    enumeration: struct {
        name_index: u16,
        size: u16,
        first_enumerator: u16, // 1-based member-table index of the first enumerator
        count: u16,
    },
    function: struct { ret: u16, far: bool, conv: format.FuncClass },
    /// A typedef alias. NB: typedefs are not type records — they live in the symbol
    /// table (class == typedef, `type` = the aliased type). `typeInfo` therefore never
    /// returns this variant; `typedefForSymbol` does.
    typedef: struct { name_index: u16, aliased: u16 },
};

/// What a class/struct member record encodes — decoded from the member `flags` byte's
/// C++ method-attribute bits (§13/§15). Plain C struct/union members are always `.data`.
/// BCC 3.1 emits methods as records *inside* the class member list (flags `0x41`–`0x60`);
/// their full bodies/vtable slots would live in the Browser/Overload tables, which BCC 3.1
/// emits **zero** of — so a method is recoverable as a typed *signature* (name + type), not
/// as callable/vtable detail. (No public/private/protected per-member access specifier is
/// present in BCC 3.1's 16-bit TDS at all — see `bases` / the limitation note in §17.)
pub const MemberKind = enum {
    data, // non-static data member (or any plain C struct/union member)
    method, // non-virtual member function (flags 0x48)
    virtual_method, // virtual member function (flags 0x44 / 0x4C)
    static_data, // static data member (flags 0x60; member.type → its symbol)
    static_method, // static member function (flags 0x50)
    constructor, // flags 0x42
    destructor, // flags 0x41
    conversion, // flags 0x43 (operator-conversion)
};

/// One struct/union/class member with its computed byte offset (§13). `bit_width == 0`
/// means "not a bitfield"; `byte_offset` is meaningful only for `.data` members (methods
/// and statics carry 0). Pointer-free (name via `Tds.name(name_index)`).
pub const MemberInfo = struct {
    name_index: u16,
    type_ref: u16,
    byte_offset: u16,
    bit_width: u8, // 0 = not a bitfield; else width in bits
    kind: MemberKind = .data, // C++ member-attribute decode; `.data` for plain C
};

/// One direct base class of a C++ class (§15.2 Parent table). Pointer-free: `type_ref` is
/// the base's `TID_CLASS` type record (render with `typeName`, walk with `members`),
/// `class_index` its 1-based Class-table index. NB: BCC 3.1's 16-bit TDS carries **no**
/// base-access specifier (`public`/`private`/`protected`) — only the virtual-base flag —
/// so access is not reported (it cannot be recovered; see §17).
pub const BaseInfo = struct {
    type_ref: u16, // base's TID_CLASS type record (0 if unresolvable)
    class_index: u16, // 1-based Class-table index of the base
    is_virtual: bool, // the Parent record's 0x8000 virtual-base flag
};

/// One enumerator `{ name, signed value }` (§12.3a). Pointer-free.
pub const EnumeratorInfo = struct {
    name_index: u16,
    value: i32,
};

/// Where a local lives (§4 symbol class). Pointer-free tagged union of integers.
pub const Storage = union(enum) {
    auto: i16, // BP-relative signed offset ([BP±n])
    register: u8, // x86 register number (CX=1, SI=6, …; see format.Reg)
    static: struct { segment: u16, offset: u16 }, // image-relative static/global
    constant: i16, // a CONSTANT symbol's value
    absolute: u16, // an ABSOLUTE symbol's address
    other: u8, // any other class (carries the raw class byte)
};

/// One scope-local variable: `{ name, type, storage }` (§4/§8). Pointer-free.
pub const Local = struct {
    name_index: u16,
    type_ref: u16,
    storage: Storage,
};

/// A `[start, count)` window into one of the flat backing arrays.
const Range = struct { start: u32, count: u32 };

/// The Tier-2 type graph + locals index over a parsed `Tds`, built once at load time.
/// Borrows `tds`; `tds` must outlive the graph (member/enumerator/local PODs reference
/// it only by integer index). All backing arrays are dense / built in table order, so
/// the same `Tds` yields byte-identical arrays.
pub const TypeGraph = struct {
    arena: std.heap.ArenaAllocator,
    tds: *const Tds,

    member_layouts: []MemberInfo, // all aggregates' (struct/union/class) members, concatenated
    member_ranges: []Range, // indexed by (type_ref - 1); {0,0} for non-aggregates
    /// For a `TID_CLASS` type: the class's 1-based Member-table index (its `member_index`
    /// from the Class table, §15.1); 0 for every non-class type. This is the raw on-disk
    /// `first_member` a class reaches its member list through (vs a struct's `member_type`).
    class_first_member: []u16, // indexed by (type_ref - 1)
    bases_flat: []BaseInfo, // all classes' base lists, concatenated (§15.2)
    base_ranges: []Range, // indexed by (type_ref - 1); {0,0} for non-classes / root classes
    enumerators_flat: []EnumeratorInfo, // all enums' enumerators, concatenated
    enum_ranges: []Range, // indexed by (type_ref - 1); {0,0} for non-enums
    locals_flat: []Local, // all scopes' locals, concatenated
    scope_ranges: []Range, // indexed by (scope_idx); window into locals_flat
    scope_seg: []u16, // image-relative code paragraph owning each scope (0xFFFF = none)
    scope_depth: []u16, // parent-chain depth of each scope (0 = function top)

    pub fn deinit(self: *TypeGraph) void {
        self.arena.deinit();
    }

    // ─────────────────────────── construction ───────────────────────────

    pub fn build(gpa: std.mem.Allocator, tds: *const Tds) error{OutOfMemory}!TypeGraph {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const ntypes = tds.types.len;
        const member_ranges = try a.alloc(Range, ntypes);
        const enum_ranges = try a.alloc(Range, ntypes);
        const class_first_member = try a.alloc(u16, ntypes);
        const base_ranges = try a.alloc(Range, ntypes);
        @memset(member_ranges, .{ .start = 0, .count = 0 });
        @memset(enum_ranges, .{ .start = 0, .count = 0 });
        @memset(class_first_member, 0);
        @memset(base_ranges, .{ .start = 0, .count = 0 });

        // ---- reverse map: 1-based Class-table index → 1-based type_ref (§15.1). A
        //      TID_CLASS type record's `member_type` IS its Class-table index (empirically
        //      {1,2,3} in CLS/MI/LCLS — a type index there would be `void`), so this lets a
        //      Parent record (which names a base by Class-table index) resolve back to the
        //      base's renderable type record. Bounds-checked against a lying member_type. ----
        const class_to_type = try a.alloc(u16, tds.classes.len + 1);
        @memset(class_to_type, 0);
        for (tds.types, 0..) |t, i| {
            if (@as(TypeId, @enumFromInt(t.id)) != .class) continue;
            const ci = t.member_type;
            if (ci != 0 and ci <= tds.classes.len and class_to_type[ci] == 0)
                class_to_type[ci] = @intCast(i + 1);
        }

        // ---- struct/union member layouts (§13) + C++ class member layouts (§15.1):
        //      walk each aggregate's member list, accumulating byte offsets in declaration
        //      order (bitfields share a container; unions place every member at offset 0; a
        //      class reaches its list via the Class table and uses the C++ attribute byte). ----
        var member_list: std.ArrayList(MemberInfo) = .empty;
        var enums: std.ArrayList(EnumeratorInfo) = .empty;
        var base_list: std.ArrayList(BaseInfo) = .empty;
        for (tds.types, 0..) |t, i| {
            const id: TypeId = @enumFromInt(t.id);
            switch (id) {
                .@"struct", .@"union" => {
                    const start: u32 = @intCast(member_list.items.len);
                    try buildAggregate(tds, &member_list, a, t, id == .@"union");
                    member_ranges[i] = .{ .start = start, .count = @intCast(member_list.items.len - start) };
                },
                .class => {
                    // member_type = the class's 1-based Class-table index (§15.1).
                    const cls = classEntry(tds, t.member_type) orelse continue;
                    class_first_member[i] = cls.member_index;
                    const mstart: u32 = @intCast(member_list.items.len);
                    try buildClass(tds, &member_list, a, cls.member_index);
                    member_ranges[i] = .{ .start = mstart, .count = @intCast(member_list.items.len - mstart) };
                    // base classes via the Parent table (§15.2).
                    const bstart: u32 = @intCast(base_list.items.len);
                    try buildBases(tds, &base_list, a, cls, class_to_type);
                    base_ranges[i] = .{ .start = bstart, .count = @intCast(base_list.items.len - bstart) };
                },
                .@"enum" => {
                    const start: u32 = @intCast(enums.items.len);
                    buildEnum(tds, &enums, a, @intCast(i)) catch |e| return e;
                    enum_ranges[i] = .{ .start = start, .count = @intCast(enums.items.len - start) };
                },
                else => {},
            }
        }
        const member_layouts = try member_list.toOwnedSlice(a);
        const enumerators_flat = try enums.toOwnedSlice(a);
        const bases_flat = try base_list.toOwnedSlice(a);

        // ---- scope tree + per-scope locals (§4/§8) ----
        const nscopes = tds.scopes.len;
        const scope_ranges = try a.alloc(Range, nscopes);
        const scope_seg = try a.alloc(u16, nscopes);
        const scope_depth = try a.alloc(u16, nscopes);
        @memset(scope_seg, 0xFFFF);

        // Each scope's owning code segment is the back-reference from the segment
        // table (a scope record carries no segment field; §8/§9).
        for (tds.segments) |seg| {
            const first: usize = if (seg.scope_index == 0) 0 else seg.scope_index - 1;
            const end = @min(first + seg.scope_count, nscopes);
            var s = first;
            while (s < end) : (s += 1) scope_seg[s] = seg.code_segment;
        }

        // Parent-chain depth (parent is 1-based; 0 = none), guarded against a malformed
        // cycle by capping the walk at the scope count.
        for (tds.scopes, 0..) |sc, i| {
            var d: u16 = 0;
            var p: u16 = sc.parent;
            var guard: usize = 0;
            while (p != 0 and p <= nscopes and guard < nscopes) : (guard += 1) {
                d += 1;
                p = tds.scopes[p - 1].parent;
            }
            scope_depth[i] = d;
        }

        var locals: std.ArrayList(Local) = .empty;
        for (tds.scopes, 0..) |sc, i| {
            const start: u32 = @intCast(locals.items.len);
            const first: usize = if (sc.symbol_index == 0) 0 else sc.symbol_index - 1;
            const end = @min(first + sc.symbol_count, tds.symbols.len);
            var s = first;
            while (s < end) : (s += 1) {
                try locals.append(a, localFromSymbol(tds.symbols[s]));
            }
            scope_ranges[i] = .{ .start = start, .count = @intCast(locals.items.len - start) };
        }
        const locals_flat = try locals.toOwnedSlice(a);

        return .{
            .arena = arena,
            .tds = tds,
            .member_layouts = member_layouts,
            .member_ranges = member_ranges,
            .class_first_member = class_first_member,
            .bases_flat = bases_flat,
            .base_ranges = base_ranges,
            .enumerators_flat = enumerators_flat,
            .enum_ranges = enum_ranges,
            .locals_flat = locals_flat,
            .scope_ranges = scope_ranges,
            .scope_seg = scope_seg,
            .scope_depth = scope_depth,
        };
    }

    // ─────────────────────────── type-walk (§12) ───────────────────────────

    /// The raw type record for a 1-based `type_ref`, or null for ref 0 / out-of-range.
    fn typeRec(self: *const TypeGraph, type_ref: u16) ?format.Type {
        if (type_ref == 0 or type_ref > self.tds.types.len) return null;
        return self.tds.types[type_ref - 1];
    }

    /// Byte size of the type named by `type_ref` (0 for none / out-of-range).
    pub fn typeSize(self: *const TypeGraph, type_ref: u16) u16 {
        const rec = self.typeRec(type_ref) orelse return 0;
        return rec.size;
    }

    /// Resolve a 1-based type reference to its `TypeInfo` (§12 type-walk). Null for
    /// ref 0 / out-of-range. Never returns `.typedef` (typedefs are symbols, not type
    /// records — see `typedefForSymbol`).
    pub fn typeInfo(self: *const TypeGraph, type_ref: u16) ?TypeInfo {
        const rec = self.typeRec(type_ref) orelse return null;
        const id: TypeId = @enumFromInt(rec.id);
        return switch (id) {
            .void, .schar, .sint, .slong, .squad, .uchar, .uint, .ulong, .uquad, .pchar, .float, .tpreal, .double, .ldouble, .bool, .tbyte => .{
                .primitive = .{ .id = id, .size = rec.size },
            },
            .nearp, .farp => .{ .pointer = .{
                .kind = ptrKind(id, rec.class),
                .pointee = rec.member_type,
                .size = rec.size,
            } },
            .array => blk: {
                const elem_size = self.typeSize(rec.member_type);
                const count: u32 = if (elem_size == 0) 0 else @as(u32, rec.size) / elem_size;
                break :blk .{ .array = .{ .element = rec.member_type, .count = count, .size = rec.size } };
            },
            .@"struct", .@"union", .class => .{
                .aggregate = .{
                    .name_index = rec.name,
                    .size = rec.size,
                    .is_union = id == .@"union",
                    .is_class = id == .class,
                    // A struct/union links its first member via `member_type`; a C++ class
                    // reaches its member list through the Class table's `member_index` (§15.1),
                    // resolved at build time into `class_first_member`.
                    .first_member = if (id == .class) self.class_first_member[type_ref - 1] else rec.member_type,
                    .member_count = @intCast(self.member_ranges[type_ref - 1].count),
                },
            },
            .@"enum" => .{ .enumeration = .{
                .name_index = rec.name,
                .size = rec.size,
                .first_enumerator = firstEnumerator(self.tds, type_ref - 1),
                .count = @intCast(self.enum_ranges[type_ref - 1].count),
            } },
            .func, .specialfunc => .{ .function = .{
                .ret = rec.member_type,
                .far = (rec.class & 0x04) != 0,
                .conv = @enumFromInt(rec.class),
            } },
            else => .{ .unknown = .{ .id = rec.id } },
        };
    }

    /// The typedef view of a 1-based *symbol* index whose class is `typedef` (e.g.
    /// `PointT` → `struct Point`, `byte` → `unsigned char`). Null if the symbol is not
    /// a typedef. (Typedefs are transparent in C — a *variable* of a typedef'd type
    /// already carries the underlying type reference, so `typeInfo` never needs this.)
    pub fn typedefForSymbol(self: *const TypeGraph, sym_index: u16) ?TypeInfo {
        if (sym_index == 0 or sym_index > self.tds.symbols.len) return null;
        const s = self.tds.symbols[sym_index - 1];
        if (s.class() != .typedef) return null;
        return .{ .typedef = .{ .name_index = s.name, .aliased = s.type } };
    }

    /// The struct/union members (with byte offsets) of `type_ref`; empty if it is not
    /// an aggregate (§13). The slice is borrowed from the graph.
    pub fn members(self: *const TypeGraph, type_ref: u16) []const MemberInfo {
        if (type_ref == 0 or type_ref > self.member_ranges.len) return &.{};
        const r = self.member_ranges[type_ref - 1];
        return self.member_layouts[r.start..][0..r.count];
    }

    /// The direct base classes of `type_ref` in declaration order; empty if it is not a
    /// C++ class or is a root class (§15.2). Each `BaseInfo.type_ref` is the base's own
    /// `TID_CLASS` record (render with `typeName`, walk with `members`). The slice is
    /// borrowed from the graph.
    pub fn bases(self: *const TypeGraph, type_ref: u16) []const BaseInfo {
        if (type_ref == 0 or type_ref > self.base_ranges.len) return &.{};
        const r = self.base_ranges[type_ref - 1];
        return self.bases_flat[r.start..][0..r.count];
    }

    /// The enumerators of `type_ref`; empty if it is not an enum (§12.3a).
    pub fn enumerators(self: *const TypeGraph, type_ref: u16) []const EnumeratorInfo {
        if (type_ref == 0 or type_ref > self.enum_ranges.len) return &.{};
        const r = self.enum_ranges[type_ref - 1];
        return self.enumerators_flat[r.start..][0..r.count];
    }

    /// Render `type_ref` as a C-style type string (`"struct Point"`, `"int *"`,
    /// `"char [8]"`, `"unsigned long"`). Aggregates/enums render by *name only* — so a
    /// self-referential type (`struct Node { Node *next; }`) terminates. A depth cap is
    /// a belt-and-braces guard against any pathological chain.
    pub fn typeName(self: *const TypeGraph, type_ref: u16, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.renderType(type_ref, w, 0);
    }

    const max_render_depth: u8 = 24;

    fn renderType(self: *const TypeGraph, type_ref: u16, w: *std.Io.Writer, depth: u8) std.Io.Writer.Error!void {
        if (depth > max_render_depth) {
            try w.writeAll("...");
            return;
        }
        const info = self.typeInfo(type_ref) orelse {
            try w.writeAll("?");
            return;
        };
        switch (info) {
            .unknown => try w.writeAll("?"),
            .primitive => |p| try w.writeAll(primitiveName(p.id)),
            .pointer => |p| {
                try self.renderType(p.pointee, w, depth + 1);
                try w.writeAll(" *");
            },
            .array => |arr| {
                try self.renderType(arr.element, w, depth + 1);
                try w.print(" [{d}]", .{arr.count});
            },
            .aggregate => |ag| {
                try w.writeAll(if (ag.is_union) "union " else if (ag.is_class) "class " else "struct ");
                try w.writeAll(tagName(self.tds, ag.name_index));
            },
            .enumeration => |e| {
                try w.writeAll("enum ");
                try w.writeAll(tagName(self.tds, e.name_index));
            },
            .function => |f| {
                try self.renderType(f.ret, w, depth + 1);
                try w.writeAll(" ()");
            },
            .typedef => |td| try w.writeAll(tagName(self.tds, td.name_index)),
        }
    }

    // ─────────────────────────── scope-locals (§4/§8) ───────────────────────────

    /// This scope's own locals (the symbols `[symbol_index, +symbol_count)`); `scope_idx`
    /// is 0-based. Visible locals at a PC = this scope plus its ancestors via `parentOf`.
    pub fn localsForScope(self: *const TypeGraph, scope_idx: usize) []const Local {
        if (scope_idx >= self.scope_ranges.len) return &.{};
        const r = self.scope_ranges[scope_idx];
        return self.locals_flat[r.start..][0..r.count];
    }

    /// The 0-based parent scope index (null at a function top).
    pub fn parentOf(self: *const TypeGraph, scope_idx: usize) ?usize {
        if (scope_idx >= self.tds.scopes.len) return null;
        const p = self.tds.scopes[scope_idx].parent;
        if (p == 0 or p > self.tds.scopes.len) return null;
        return p - 1;
    }

    /// The 0-based index of the **innermost** scope whose `[offset, offset+length)`
    /// range (within code paragraph `seg`) contains `off`; null if none. Innermost =
    /// deepest in the parent chain (tie-break: the narrower range), so a debug frame can
    /// start here and walk `parentOf` for the full visible-local set.
    pub fn scopeForAddr(self: *const TypeGraph, seg: u16, off: u16) ?usize {
        var best: ?usize = null;
        var best_depth: i32 = -1;
        var best_len: u32 = std.math.maxInt(u32);
        for (self.tds.scopes, 0..) |sc, i| {
            if (self.scope_seg[i] != seg) continue;
            const start = sc.offset;
            const end: u32 = @as(u32, start) + sc.length;
            if (off < start or off >= end) continue;
            const d: i32 = self.scope_depth[i];
            if (best == null or d > best_depth or (d == best_depth and sc.length < best_len)) {
                best = i;
                best_depth = d;
                best_len = sc.length;
            }
        }
        return best;
    }
};

// ─────────────────────────── helpers ───────────────────────────

/// C-style spelling of a built-in scalar. Borland's plain `char` is `SCHAR` (signed by
/// default), so `schar` renders as `"char"` to match the source (`char name[8]` →
/// `"char [8]"`); `uchar` keeps its explicit `"unsigned char"`.
pub fn primitiveName(id: TypeId) []const u8 {
    return switch (id) {
        .void => "void",
        .schar => "char",
        .sint => "int",
        .slong => "long",
        .squad => "long long",
        .uchar => "unsigned char",
        .uint => "unsigned int",
        .ulong => "unsigned long",
        .uquad => "unsigned long long",
        .pchar => "char",
        .float => "float",
        .double => "double",
        .ldouble => "long double",
        .tpreal => "long double", // Turbo-Pascal 6-byte real; nearest C spelling
        .tbyte => "long double", // 10-byte predefined slot
        .bool => "bool",
        else => "?",
    };
}

fn tagName(tds: *const Tds, name_index: u16) []const u8 {
    const nm = tds.name(name_index);
    return if (nm.len == 0) "<anonymous>" else nm;
}

fn ptrKind(id: TypeId, class: u8) PtrKind {
    if (id == .farp) return if (class == 0x01) .huge else .far;
    // nearp: the class byte is the segment-register base (§12.2).
    return switch (class) {
        0x01 => .near_es,
        0x02 => .near_cs,
        0x03 => .near_ss,
        0x04 => .near_ds,
        0x05 => .near_fs,
        0x06 => .near_gs,
        else => .near,
    };
}

/// Walk a struct/union member list from `t.member_type` until the `0xC0` terminator,
/// accumulating byte offsets (§13). A bitfield run shares its container (the member
/// type's size); a `0x40` offset-reset record sets the running offset (Pascal variants).
fn buildAggregate(
    tds: *const Tds,
    out: *std.ArrayList(MemberInfo),
    a: std.mem.Allocator,
    t: format.Type,
    is_union: bool,
) error{OutOfMemory}!void {
    var byte_off: u16 = 0;
    var bf_bits: u32 = 0; // bits used so far in the current bitfield container
    var bf_container: u16 = 0; // byte size of the current bitfield container
    var mi: usize = t.member_type; // 1-based first member
    var guard: usize = 0;
    while (mi != 0 and mi <= tds.members.len and guard <= tds.members.len) : (guard += 1) {
        const m = tds.members[mi - 1];
        if ((m.flags & 0xC0) == 0xC0) break; // 0xC0 = list terminator
        if ((m.flags & 0xC0) == 0x40) { // offset-reset record (no field emitted)
            byte_off = m.type;
            bf_bits = 0;
            bf_container = 0;
            mi += 1;
            continue;
        }
        const width: u8 = m.flags & 0x3F; // 0 = not a bitfield
        var this_off: u16 = 0;
        if (!is_union) {
            if (width != 0) {
                const csize = typeSizeOf(tds, m.type);
                if (bf_bits == 0) {
                    bf_container = csize;
                } else if (bf_bits + width > @as(u32, bf_container) * 8 or csize != bf_container) {
                    byte_off +|= bf_container; // close the full container, open a new one
                    bf_bits = 0;
                    bf_container = csize;
                }
                this_off = byte_off;
                bf_bits += width;
            } else {
                if (bf_bits > 0) { // flush a pending bitfield container
                    byte_off +|= bf_container;
                    bf_bits = 0;
                    bf_container = 0;
                }
                this_off = byte_off;
                // Saturating: member sizes are attacker-controlled (a crafted type
                // table can make them sum past 0xFFFF). `byte_offset` is u16 anyway —
                // saturate rather than overflow-panic (BUG-2).
                byte_off +|= typeSizeOf(tds, m.type);
            }
        }
        try out.append(a, .{
            .name_index = m.name,
            .type_ref = m.type,
            .byte_offset = this_off,
            .bit_width = width,
        });
        mi += 1;
    }
}

/// The Class-table entry for a 1-based class index (a `TID_CLASS` type record's
/// `member_type`, §15.1); null for index 0 / out-of-range (a lying type table).
fn classEntry(tds: *const Tds, class_index: u16) ?format.ClassRecord {
    if (class_index == 0 or class_index > tds.classes.len) return null;
    return tds.classes[class_index - 1];
}

/// Classify a C++ class member from its `flags` byte (the method-attribute byte, §13/§15).
/// Only reached for records with bit6 (0x40) set and a non-zero low nibble (a pure 0x40 is
/// an offset-reset, handled in `buildClass`; 0xC0 is the terminator). The low 6 bits select:
/// 0x20 static-data, 0x10 static-method, 0x04 virtual, 0x08 method, 1/2/3 dtor/ctor/conv.
fn classifyClassMember(flags: u8) MemberKind {
    const low: u8 = flags & 0x3F;
    if (low & 0x20 != 0) return .static_data; // 0x60
    if (low & 0x10 != 0) return .static_method; // 0x50
    if (low & 0x04 != 0) return .virtual_method; // 0x44 / 0x4C
    if (low & 0x08 != 0) return .method; // 0x48
    return switch (low) {
        1 => .destructor, // 0x41
        2 => .constructor, // 0x42
        3 => .conversion, // 0x43
        else => .method,
    };
}

/// Walk a C++ class's member list (§15.1/§15) from its Class-table `member_index` until the
/// `0xC0` terminator, emitting both data members (with accumulated byte offsets) and method
/// records (typed signatures; no data offset). Differs from `buildAggregate` in three ways
/// the C++ encoding requires: (1) a `0x40` offset-reset record carries the new running
/// offset in its **name** field (empirically: CLS `New Offset 02` ⇐ name=2; it sits before
/// the first data member to skip the vtable pointer); (2) method records (flags `0x41`–`0x60`,
/// i.e. bit6 set with a non-zero low nibble) are emitted with their `MemberKind` and do not
/// advance the data offset; (3) the list is reached via the Class table, not `member_type`.
/// Bounds/overflow are saturating like `buildAggregate` (a lying class table must not panic).
fn buildClass(
    tds: *const Tds,
    out: *std.ArrayList(MemberInfo),
    a: std.mem.Allocator,
    member_index: u16,
) error{OutOfMemory}!void {
    var byte_off: u16 = 0;
    var bf_bits: u32 = 0; // bits used so far in the current bitfield container
    var bf_container: u16 = 0; // byte size of the current bitfield container
    var mi: usize = member_index; // 1-based first member
    var guard: usize = 0;
    while (mi != 0 and mi <= tds.members.len and guard <= tds.members.len) : (guard += 1) {
        const m = tds.members[mi - 1];
        if ((m.flags & 0xC0) == 0xC0) break; // 0xC0 = list terminator
        if ((m.flags & 0x40) != 0) {
            if ((m.flags & 0x3F) == 0) {
                // Pure offset-reset (0x40): the new running offset is in the NAME field.
                byte_off = m.name;
                bf_bits = 0;
                bf_container = 0;
            } else {
                // A method / static record — a typed signature, no data layout (§15.5: its
                // body/vtable slot would live in the Browser/Overload tables BCC 3.1 omits).
                try out.append(a, .{
                    .name_index = m.name,
                    .type_ref = m.type,
                    .byte_offset = 0,
                    .bit_width = 0,
                    .kind = classifyClassMember(m.flags),
                });
            }
            mi += 1;
            continue;
        }
        // bit6 clear ⇒ a data member (plain or bitfield), laid out like a struct.
        const width: u8 = m.flags & 0x3F; // 0 = not a bitfield
        var this_off: u16 = byte_off;
        if (width != 0) {
            const csize = typeSizeOf(tds, m.type);
            if (bf_bits == 0) {
                bf_container = csize;
            } else if (bf_bits + width > @as(u32, bf_container) * 8 or csize != bf_container) {
                byte_off +|= bf_container; // close the full container, open a new one
                bf_bits = 0;
                bf_container = csize;
            }
            this_off = byte_off;
            bf_bits += width;
        } else {
            if (bf_bits > 0) { // flush a pending bitfield container
                byte_off +|= bf_container;
                bf_bits = 0;
                bf_container = 0;
            }
            this_off = byte_off;
            byte_off +|= typeSizeOf(tds, m.type); // saturating (attacker-controlled sizes)
        }
        try out.append(a, .{
            .name_index = m.name,
            .type_ref = m.type,
            .byte_offset = this_off,
            .bit_width = width,
            .kind = .data,
        });
        mi += 1;
    }
}

/// Resolve a class's direct base list from the Parent table (§15.2): the `parent_count`
/// records starting at the 1-based `parent_index`. Each Parent record names a base by
/// 1-based Class-table index (`class_to_type` maps it back to a renderable type record);
/// bit15 (0x8000) is the virtual-base flag. Bounds-checked against a lying class table.
fn buildBases(
    tds: *const Tds,
    out: *std.ArrayList(BaseInfo),
    a: std.mem.Allocator,
    cls: format.ClassRecord,
    class_to_type: []const u16,
) error{OutOfMemory}!void {
    if (cls.parent_count == 0 or cls.parent_index == 0) return;
    const first: usize = cls.parent_index - 1; // 1-based
    var k: usize = 0;
    while (k < cls.parent_count and first + k < tds.parents.len) : (k += 1) {
        const p = tds.parents[first + k];
        const ci: u16 = p.class_index & 0x7FFF;
        const tref: u16 = if (ci < class_to_type.len) class_to_type[ci] else 0;
        try out.append(a, .{
            .type_ref = tref,
            .class_index = ci,
            .is_virtual = (p.class_index & 0x8000) != 0,
        });
    }
}

/// Walk an enum's enumerators (§12.3a). The type record at 0-based `enum_idx0` is the
/// `ENUM`; the record immediately after it is the aux ordinal-range record whose 5th
/// byte (the high byte of `size`) is the 1-based index of the first enumerator. The list
/// runs until a member with the `0x80` (end-of-list) bit set.
fn buildEnum(
    tds: *const Tds,
    out: *std.ArrayList(EnumeratorInfo),
    a: std.mem.Allocator,
    enum_idx0: usize,
) error{OutOfMemory}!void {
    const first = firstEnumerator(tds, enum_idx0);
    if (first == 0) return;
    var mi: usize = first;
    var guard: usize = 0;
    while (mi != 0 and mi <= tds.members.len and guard <= tds.members.len) : (guard += 1) {
        const m = tds.members[mi - 1];
        if ((m.flags & 0xC0) == 0xC0) break; // safety: a struct terminator never belongs here
        const val: i32 = @as(i16, @bitCast(m.type)); // enumerator value lives in the type field (signed)
        try out.append(a, .{ .name_index = m.name, .value = val });
        if ((m.flags & 0x80) != 0) break; // end-of-list bit on the final enumerator
        mi += 1;
    }
}

/// The 1-based first-enumerator member index for the enum type at 0-based `enum_idx0`,
/// read from the aux ordinal-range record that follows it (§12.3a); 0 if absent.
fn firstEnumerator(tds: *const Tds, enum_idx0: usize) u16 {
    const aux_idx = enum_idx0 + 1; // the aux record sits immediately after the ENUM record
    if (aux_idx >= tds.types.len) return 0;
    return tds.types[aux_idx].size >> 8; // 5th byte (offset +4) = high byte of `size`
}

fn typeSizeOf(tds: *const Tds, type_ref: u16) u16 {
    if (type_ref == 0 or type_ref > tds.types.len) return 0;
    return tds.types[type_ref - 1].size;
}

/// Decode a local symbol's storage from its class (§4).
fn localFromSymbol(s: format.Symbol) Local {
    const storage: Storage = switch (s.class()) {
        .auto => .{ .auto = @bitCast(s.offset) },
        .register => .{ .register = @truncate(s.offset) },
        .static => .{ .static = .{ .segment = s.segment, .offset = s.offset } },
        .constant => .{ .constant = @bitCast(s.offset) },
        .absolute => .{ .absolute = s.offset },
        else => .{ .other = @as(u8, @intFromEnum(s.class())) },
    };
    return .{ .name_index = s.name, .type_ref = s.type, .storage = storage };
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;
const rich_exe = @embedFile("testdata/RICH.EXE");
const enum_exe = @embedFile("testdata/ENUM.EXE");
const benum_exe = @embedFile("testdata/BENUM.EXE");
const ptr_exe = @embedFile("testdata/PTR.EXE");
const cls_exe = @embedFile("testdata/CLS.EXE");
const mi_exe = @embedFile("testdata/MI.EXE");
const lcls_exe = @embedFile("testdata/LCLS.EXE");

/// Render a type to a stack buffer and return the written slice (for assertions).
fn renderToBuf(tg: *const TypeGraph, type_ref: u16, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    tg.typeName(type_ref, &w) catch unreachable;
    return w.buffered();
}

/// Find a 1-based symbol index by name (locals included).
fn symIndexByName(tds: *const Tds, name: []const u8) ?u16 {
    for (tds.symbols, 0..) |s, i| {
        if (std.mem.eql(u8, tds.name(s.name), name)) return @intCast(i + 1);
    }
    return null;
}

test "RICH: predefined primitive type-walk (1-based index, NOT ref-0x18)" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    var buf: [64]u8 = undefined;
    // type ref 4 → record #4 (id=SINT) → "int"  (ref-0x18 would wrongly give SCHAR).
    try testing.expectEqualStrings("int", renderToBuf(&tg, 4, &buf));
    try testing.expectEqualStrings("long", renderToBuf(&tg, 6, &buf));
    try testing.expectEqualStrings("unsigned char", renderToBuf(&tg, 8, &buf));
    try testing.expectEqualStrings("unsigned long", renderToBuf(&tg, 12, &buf));
    // and the structural view agrees.
    switch (tg.typeInfo(4).?) {
        .primitive => |p| {
            try testing.expectEqual(TypeId.sint, p.id);
            try testing.expectEqual(@as(u16, 2), p.size);
        },
        else => return error.WrongVariant,
    }
}

test "RICH: struct Rect member layout (tl@0, br@6, area@12, name@16) + char[8]" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Rect is type record #27 (see the byte dump / spec §12.5).
    const info = tg.typeInfo(27).?;
    try testing.expectEqualStrings("Rect", tds.name(info.aggregate.name_index));
    try testing.expectEqual(@as(u16, 24), info.aggregate.size);
    try testing.expect(!info.aggregate.is_union);

    const ms = tg.members(27);
    try testing.expectEqual(@as(usize, 4), ms.len);
    try testing.expectEqualStrings("tl", tds.name(ms[0].name_index));
    try testing.expectEqual(@as(u16, 0), ms[0].byte_offset);
    try testing.expectEqualStrings("br", tds.name(ms[1].name_index));
    try testing.expectEqual(@as(u16, 6), ms[1].byte_offset);
    try testing.expectEqualStrings("area", tds.name(ms[2].name_index));
    try testing.expectEqual(@as(u16, 12), ms[2].byte_offset);
    try testing.expectEqualStrings("name", tds.name(ms[3].name_index));
    try testing.expectEqual(@as(u16, 16), ms[3].byte_offset);

    var buf: [64]u8 = undefined;
    // tl/br are struct Point; area is long; name is char[8].
    try testing.expectEqualStrings("struct Point", renderToBuf(&tg, ms[0].type_ref, &buf));
    try testing.expectEqualStrings("long", renderToBuf(&tg, ms[2].type_ref, &buf));
    try testing.expectEqualStrings("char [8]", renderToBuf(&tg, ms[3].type_ref, &buf));
}

test "RICH: struct Point members are three ints" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    const ms = tg.members(25); // Point = type #25
    try testing.expectEqual(@as(usize, 3), ms.len);
    var buf: [16]u8 = undefined;
    for (ms, [_][]const u8{ "x", "y", "z" }, [_]u16{ 0, 2, 4 }) |m, nm, off| {
        try testing.expectEqualStrings(nm, tds.name(m.name_index));
        try testing.expectEqual(off, m.byte_offset);
        try testing.expectEqualStrings("int", renderToBuf(&tg, m.type_ref, &buf));
    }
}

test "RICH: self-referential struct Node renders without infinite recursion (cycle)" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Node = type #30; member `next` is `struct Node *` (a _DS near pointer, #29).
    const ms = tg.members(30);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqualStrings("value", tds.name(ms[0].name_index));
    try testing.expectEqualStrings("next", tds.name(ms[1].name_index));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("int", renderToBuf(&tg, ms[0].type_ref, &buf));
    // The pointer renders the pointee by NAME only ⇒ terminates.
    try testing.expectEqualStrings("struct Node *", renderToBuf(&tg, ms[1].type_ref, &buf));
    // Rendering Node itself is just the tag.
    try testing.expectEqualStrings("struct Node", renderToBuf(&tg, 30, &buf));
    // The pointer's kind is a _DS near pointer.
    switch (tg.typeInfo(29).?) {
        .pointer => |p| {
            try testing.expectEqual(PtrKind.near_ds, p.kind);
            try testing.expectEqual(@as(u16, 30), p.pointee);
        },
        else => return error.WrongVariant,
    }
}

test "RICH: typedefs PointT → struct Point, byte → unsigned char" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    const pt = symIndexByName(&tds, "PointT").?;
    const td = tg.typedefForSymbol(pt).?;
    try testing.expectEqualStrings("PointT", tds.name(td.typedef.name_index));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("struct Point", renderToBuf(&tg, td.typedef.aliased, &buf));

    const byte = symIndexByName(&tds, "byte").?;
    const td2 = tg.typedefForSymbol(byte).?;
    try testing.expectEqualStrings("unsigned char", renderToBuf(&tg, td2.typedef.aliased, &buf));
}

test "ENUM: union Variant places every member at offset 0" {
    var tds = try tdsmod.parseExe(testing.allocator, enum_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Variant = type #31 (union, size 8).
    const info = tg.typeInfo(31).?;
    try testing.expect(info.aggregate.is_union);
    const ms = tg.members(31);
    try testing.expectEqual(@as(usize, 4), ms.len);
    for (ms) |m| try testing.expectEqual(@as(u16, 0), m.byte_offset);
    try testing.expectEqualStrings("i", tds.name(ms[0].name_index));
    try testing.expectEqualStrings("d", tds.name(ms[2].name_index));
}

test "ENUM: Color enumerators RED=0, GREEN=5, BLUE=6" {
    var tds = try tdsmod.parseExe(testing.allocator, enum_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Color = type #32; the aux record #33 links to the first enumerator (member 10).
    const info = tg.typeInfo(32).?;
    try testing.expectEqualStrings("Color", tds.name(info.enumeration.name_index));
    const es = tg.enumerators(32);
    try testing.expectEqual(@as(usize, 3), es.len);
    try testing.expectEqualStrings("RED", tds.name(es[0].name_index));
    try testing.expectEqual(@as(i32, 0), es[0].value);
    try testing.expectEqualStrings("GREEN", tds.name(es[1].name_index));
    try testing.expectEqual(@as(i32, 5), es[1].value);
    try testing.expectEqualStrings("BLUE", tds.name(es[2].name_index));
    try testing.expectEqual(@as(i32, 6), es[2].value);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("enum Color", renderToBuf(&tg, 32, &buf));
}

test "ENUM: bitfield widths for struct Bits {a:3, b:5, s:4}" {
    var tds = try tdsmod.parseExe(testing.allocator, enum_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Bits = type #30 (size 2); three bitfields packed into one int container.
    const ms = tg.members(30);
    try testing.expectEqual(@as(usize, 3), ms.len);
    try testing.expectEqual(@as(u8, 3), ms[0].bit_width);
    try testing.expectEqual(@as(u8, 5), ms[1].bit_width);
    try testing.expectEqual(@as(u8, 4), ms[2].bit_width);
    // all three fit in the single 2-byte container ⇒ byte offset 0.
    for (ms) |m| try testing.expectEqual(@as(u16, 0), m.byte_offset);
}

test "ENUM: far + huge pointer kinds" {
    var tds = try tdsmod.parseExe(testing.allocator, enum_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // #28 = `char huge *`, #29 = `char far *` (both point at char = #2).
    var buf: [32]u8 = undefined;
    switch (tg.typeInfo(28).?) {
        .pointer => |p| try testing.expectEqual(PtrKind.huge, p.kind),
        else => return error.WrongVariant,
    }
    switch (tg.typeInfo(29).?) {
        .pointer => |p| try testing.expectEqual(PtrKind.far, p.kind),
        else => return error.WrongVariant,
    }
    try testing.expectEqualStrings("char *", renderToBuf(&tg, 29, &buf));
}

test "BENUM: two enums with negative enumerators (Small + Big)" {
    var tds = try tdsmod.parseExe(testing.allocator, benum_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // Small = #25 (first enumerator = member 1): SA=0, SB=1, SC=2.
    const small = tg.enumerators(25);
    try testing.expectEqual(@as(usize, 3), small.len);
    try testing.expectEqual(@as(i32, 0), small[0].value);
    try testing.expectEqual(@as(i32, 2), small[2].value);
    try testing.expectEqualStrings("SC", tds.name(small[2].name_index));

    // Big = #27 (first enumerator = member 4): Z0..Z8, ending Z7=-5, Z8=-4.
    const big = tg.enumerators(27);
    try testing.expectEqual(@as(usize, 9), big.len);
    try testing.expectEqualStrings("Z0", tds.name(big[0].name_index));
    try testing.expectEqual(@as(i32, 0), big[0].value);
    try testing.expectEqual(@as(i32, 10), big[3].value); // Z3
    try testing.expectEqual(@as(i32, 100), big[5].value); // Z5
    try testing.expectEqual(@as(i32, 101), big[6].value); // Z6
    try testing.expectEqual(@as(i32, -5), big[7].value); // Z7
    try testing.expectEqual(@as(i32, -4), big[8].value); // Z8
    try testing.expectEqualStrings("Z8", tds.name(big[8].name_index));
}

test "PTR: _SS / _CS / _ES near-pointer kinds" {
    var tds = try tdsmod.parseExe(testing.allocator, ptr_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // #28 = _SS, #29 = _CS, #30 = _ES near pointers (all to char = #2).
    const want = [_]struct { ref: u16, kind: PtrKind }{
        .{ .ref = 28, .kind = .near_ss },
        .{ .ref = 29, .kind = .near_cs },
        .{ .ref = 30, .kind = .near_es },
    };
    var buf: [32]u8 = undefined;
    for (want) |c| {
        switch (tg.typeInfo(c.ref).?) {
            .pointer => |p| try testing.expectEqual(c.kind, p.kind),
            else => return error.WrongVariant,
        }
        try testing.expectEqualStrings("char *", renderToBuf(&tg, c.ref, &buf));
    }
}

test "RICH F1: scope-locals with exact BP offsets / registers / types" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // scope[0] (F1 top) = params b@[BP+8], a@[BP+6].
    const top = tg.localsForScope(0);
    try testing.expectEqual(@as(usize, 2), top.len);
    try testing.expectEqualStrings("b", tds.name(top[0].name_index));
    try testing.expectEqual(Storage{ .auto = 8 }, top[0].storage);
    try testing.expectEqualStrings("a", tds.name(top[1].name_index));
    try testing.expectEqual(Storage{ .auto = 6 }, top[1].storage);

    // scope[1] = ap(SI reg, int*), pt(BP-12, Point), local2(BP-6, long),
    //            local1(BP-2, int), a(BP+6), b(BP+8) — matches RICH.LST exactly.
    const s1 = tg.localsForScope(1);
    try testing.expectEqual(@as(usize, 6), s1.len);
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("ap", tds.name(s1[0].name_index));
    try testing.expectEqual(Storage{ .register = 6 }, s1[0].storage); // SI = 6
    try testing.expectEqualStrings("int *", renderToBuf(&tg, s1[0].type_ref, &buf));

    try testing.expectEqualStrings("pt", tds.name(s1[1].name_index));
    try testing.expectEqual(Storage{ .auto = -12 }, s1[1].storage);
    try testing.expectEqualStrings("struct Point", renderToBuf(&tg, s1[1].type_ref, &buf));

    try testing.expectEqualStrings("local2", tds.name(s1[2].name_index));
    try testing.expectEqual(Storage{ .auto = -6 }, s1[2].storage);
    try testing.expectEqualStrings("long", renderToBuf(&tg, s1[2].type_ref, &buf));

    try testing.expectEqualStrings("local1", tds.name(s1[3].name_index));
    try testing.expectEqual(Storage{ .auto = -2 }, s1[3].storage);
    try testing.expectEqualStrings("int", renderToBuf(&tg, s1[3].type_ref, &buf));

    // scope[2] = inner@[BP-14], int.
    const s2 = tg.localsForScope(2);
    try testing.expectEqual(@as(usize, 1), s2.len);
    try testing.expectEqualStrings("inner", tds.name(s2[0].name_index));
    try testing.expectEqual(Storage{ .auto = -14 }, s2[0].storage);
}

test "RICH F1: scopeForAddr finds the innermost enclosing scope" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    // F1 lives in code paragraph 0xC2. Scope ranges: scope0 [0x06,0x52),
    // scope1 [0x0d,0x52), scope2 [0x39,0x48).
    try testing.expectEqual(@as(?usize, 0), tg.scopeForAddr(0xC2, 0x08)); // only top
    try testing.expectEqual(@as(?usize, 1), tg.scopeForAddr(0xC2, 0x20)); // mid
    try testing.expectEqual(@as(?usize, 2), tg.scopeForAddr(0xC2, 0x40)); // inner
    try testing.expectEqual(@as(?usize, null), tg.scopeForAddr(0xC2, 0x60)); // past code
    try testing.expectEqual(@as(?usize, null), tg.scopeForAddr(0x00, 0x40)); // wrong seg

    // The innermost scope chains back up to the function top via parentOf.
    try testing.expectEqual(@as(?usize, 1), tg.parentOf(2));
    try testing.expectEqual(@as(?usize, 0), tg.parentOf(1));
    try testing.expectEqual(@as(?usize, null), tg.parentOf(0));

    // Register decode at the innermost frame in F2's segment 0xC7: i = CX (reg 1).
    const f2_inner = tg.scopeForAddr(0xC7, 0x20).?;
    var found_cx = false;
    for (tg.localsForScope(f2_inner)) |l| {
        if (std.mem.eql(u8, tds.name(l.name_index), "i")) {
            try testing.expectEqual(Storage{ .register = 1 }, l.storage); // CX = 1
            found_cx = true;
        }
    }
    try testing.expect(found_cx);
}

test "CLS: class Base / Derived render with data members + single inheritance (§15)" {
    var tds = try tdsmod.parseExe(testing.allocator, cls_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();
    var buf: [64]u8 = undefined;

    // Base = type record #25 (id=TID_CLASS 0x2E): renders "class Base", no bases.
    try testing.expectEqualStrings("class Base", renderToBuf(&tg, 25, &buf));
    switch (tg.typeInfo(25).?) {
        .aggregate => |ag| {
            try testing.expect(ag.is_class);
            try testing.expect(!ag.is_union);
            try testing.expectEqualStrings("Base", tds.name(ag.name_index));
            try testing.expectEqual(@as(u16, 4), ag.size); // vptr(2) + bx(2)
            try testing.expectEqual(@as(u16, 1), ag.first_member); // Class-table member_index
        },
        else => return error.WrongVariant,
    }
    try testing.expectEqual(@as(usize, 0), tg.bases(25).len);

    // Base members: data `bx` @offset 2 (after the vtable pointer), then virtual `who`.
    const bm = tg.members(25);
    try testing.expectEqual(@as(usize, 2), bm.len);
    try testing.expectEqualStrings("bx", tds.name(bm[0].name_index));
    try testing.expectEqual(@as(u16, 2), bm[0].byte_offset);
    try testing.expectEqual(MemberKind.data, bm[0].kind);
    try testing.expectEqualStrings("int", renderToBuf(&tg, bm[0].type_ref, &buf));
    try testing.expectEqualStrings("@Base@who$qv", tds.name(bm[1].name_index));
    try testing.expectEqual(MemberKind.virtual_method, bm[1].kind);
    try testing.expectEqual(@as(u16, 0), bm[1].byte_offset); // methods carry no data offset

    // Derived = #27: "class Derived", base = Base (#25), non-virtual.
    try testing.expectEqualStrings("class Derived", renderToBuf(&tg, 27, &buf));
    const db = tg.bases(27);
    try testing.expectEqual(@as(usize, 1), db.len);
    try testing.expectEqual(@as(u16, 25), db[0].type_ref);
    try testing.expectEqual(@as(u16, 1), db[0].class_index);
    try testing.expect(!db[0].is_virtual);
    try testing.expectEqualStrings("class Base", renderToBuf(&tg, db[0].type_ref, &buf));

    // Derived adds `dy` @offset 4 (vptr + base bx + this dy), plus its own virtual who.
    const dm = tg.members(27);
    try testing.expectEqual(@as(usize, 2), dm.len);
    try testing.expectEqualStrings("dy", tds.name(dm[0].name_index));
    try testing.expectEqual(@as(u16, 4), dm[0].byte_offset);
    try testing.expectEqual(MemberKind.data, dm[0].kind);
    try testing.expectEqual(MemberKind.virtual_method, dm[1].kind);
}

test "MI: class C reports BOTH base classes A, B in declaration order (§15.2)" {
    var tds = try tdsmod.parseExe(testing.allocator, mi_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();
    var buf: [64]u8 = undefined;

    // Type records: #25=B, #27=A, #29=C (see decode oracle). C : public A, public B.
    try testing.expectEqualStrings("class C", renderToBuf(&tg, 29, &buf));
    const cb = tg.bases(29);
    try testing.expectEqual(@as(usize, 2), cb.len);
    // declaration order is A then B (Parent table {2,1} → class 2=A, class 1=B).
    try testing.expectEqualStrings("class A", renderToBuf(&tg, cb[0].type_ref, &buf));
    try testing.expectEqual(@as(u16, 27), cb[0].type_ref);
    try testing.expectEqualStrings("class B", renderToBuf(&tg, cb[1].type_ref, &buf));
    try testing.expectEqual(@as(u16, 25), cb[1].type_ref);
    for (cb) |b| try testing.expect(!b.is_virtual);

    // C's own member `cx` lands at offset 8 (A subobject 4 + B subobject 4), then 3 methods.
    const cm = tg.members(29);
    try testing.expectEqualStrings("cx", tds.name(cm[0].name_index));
    try testing.expectEqual(@as(u16, 8), cm[0].byte_offset);
    try testing.expectEqual(MemberKind.data, cm[0].kind);
    var methods: usize = 0;
    for (cm) |m| if (m.kind == .virtual_method) {
        methods += 1;
    };
    try testing.expectEqual(@as(usize, 3), methods); // fa, fb, fc all virtual in C

    // The single-inheritance roots A and B carry no bases.
    try testing.expectEqual(@as(usize, 0), tg.bases(27).len);
    try testing.expectEqual(@as(usize, 0), tg.bases(25).len);
}

test "LCLS: a local class and a global class both decode their members" {
    var tds = try tdsmod.parseExe(testing.allocator, lcls_exe);
    defer tds.deinit();
    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();
    var buf: [64]u8 = undefined;

    // #24 = the function-local `class Local`, #28 = file-scope `class Glob`.
    try testing.expectEqualStrings("class Local", renderToBuf(&tg, 24, &buf));
    const lm = tg.members(24);
    try testing.expectEqualStrings("lx", tds.name(lm[0].name_index));
    try testing.expectEqual(@as(u16, 2), lm[0].byte_offset);
    try testing.expectEqual(MemberKind.data, lm[0].kind);
    try testing.expectEqual(MemberKind.virtual_method, lm[1].kind); // Local::g

    try testing.expectEqualStrings("class Glob", renderToBuf(&tg, 28, &buf));
    const gm = tg.members(28);
    try testing.expectEqualStrings("gx", tds.name(gm[0].name_index));
    try testing.expectEqual(@as(u16, 2), gm[0].byte_offset);
    // Neither class inherits.
    try testing.expectEqual(@as(usize, 0), tg.bases(24).len);
    try testing.expectEqual(@as(usize, 0), tg.bases(28).len);
}

test "C++ class decode is robust against a lying class/member table (no panic)" {
    // A type record claims to be a TID_CLASS whose member_type points past the (empty)
    // class table, and a parent_index/count that would overrun the parent table. The
    // bounds-checked resolution must yield empty members/bases, never a panic.
    var tds: Tds = undefined;
    tds.arena = .init(testing.allocator);
    defer tds.deinit();
    const a = tds.arena.allocator();

    const types = try a.alloc(format.Type, 1);
    types[0] = .{ .id = @intFromEnum(TypeId.class), .name = 0, .size = 0, .class = 0, .member_type = 99 };
    const classes = try a.alloc(format.ClassRecord, 1);
    classes[0] = .{ .parent_index = 50, .parent_count = 40, .member_index = 9, .name_index = 0, .virtual_ptr = 0, .info = 0 };

    tds.header = std.mem.zeroes(format.Header);
    tds.ext = std.mem.zeroes(format.ExtHeader);
    tds.symbols = &.{};
    tds.modules = &.{};
    tds.sources = &.{};
    tds.lines = &.{};
    tds.scopes = &.{};
    tds.segments = &.{};
    tds.correlations = &.{};
    tds.types = types;
    tds.members = &.{};
    tds.classes = classes;
    tds.parents = &.{};
    tds.scope_classes = &.{};
    tds.module_classes = &.{};
    tds.name_pool = &.{};
    tds.name_starts = &.{};

    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();
    // member_type=99 is out of range → no class entry → empty members + bases.
    try testing.expectEqual(@as(usize, 0), tg.members(1).len);
    try testing.expectEqual(@as(usize, 0), tg.bases(1).len);
}

test "TypeGraph: build is deterministic (byte-identical arrays on re-build)" {
    var tds = try tdsmod.parseExe(testing.allocator, rich_exe);
    defer tds.deinit();
    var a = try TypeGraph.build(testing.allocator, &tds);
    defer a.deinit();
    var b = try TypeGraph.build(testing.allocator, &tds);
    defer b.deinit();
    try testing.expectEqualSlices(MemberInfo, a.member_layouts, b.member_layouts);
    try testing.expectEqualSlices(BaseInfo, a.bases_flat, b.bases_flat);
    try testing.expectEqualSlices(u16, a.class_first_member, b.class_first_member);
    try testing.expectEqualSlices(EnumeratorInfo, a.enumerators_flat, b.enumerators_flat);
    try testing.expectEqualSlices(Local, a.locals_flat, b.locals_flat);
    try testing.expectEqualSlices(u16, a.scope_seg, b.scope_seg);
    try testing.expectEqualSlices(u16, a.scope_depth, b.scope_depth);
}

test "BUG-2: aggregate member sizes summing past 0xFFFF saturate (no overflow panic)" {
    // A crafted type table: a struct of two members, each of a type whose size is
    // 0xFFFF. The running byte offset would overflow u16 on the second member — the
    // saturating add must clamp it at 0xFFFF instead of panicking.
    var tds: Tds = undefined;
    tds.arena = .init(testing.allocator);
    defer tds.deinit();
    const a = tds.arena.allocator();

    const types = try a.alloc(format.Type, 2);
    // #1: the struct itself; member list begins at member #1.
    types[0] = .{ .id = @intFromEnum(TypeId.@"struct"), .name = 0, .size = 0, .class = 0, .member_type = 1 };
    // #2: a giant member type (size 0xFFFF) referenced by both members.
    types[1] = .{ .id = @intFromEnum(TypeId.array), .name = 0, .size = 0xFFFF, .class = 0, .member_type = 0 };

    const members = try a.alloc(format.Member, 3);
    members[0] = .{ .flags = 0, .name = 0, .type = 2 };
    members[1] = .{ .flags = 0, .name = 0, .type = 2 };
    members[2] = .{ .flags = 0xC0, .name = 0, .type = 0 }; // list terminator

    tds.header = std.mem.zeroes(format.Header);
    tds.ext = std.mem.zeroes(format.ExtHeader);
    tds.symbols = &.{};
    tds.modules = &.{};
    tds.sources = &.{};
    tds.lines = &.{};
    tds.scopes = &.{};
    tds.segments = &.{};
    tds.correlations = &.{};
    tds.types = types;
    tds.members = members;
    tds.classes = &.{};
    tds.parents = &.{};
    tds.scope_classes = &.{};
    tds.module_classes = &.{};
    tds.name_pool = &.{};
    tds.name_starts = &.{};

    var tg = try TypeGraph.build(testing.allocator, &tds);
    defer tg.deinit();

    const ms = tg.members(1);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqual(@as(u16, 0), ms[0].byte_offset);
    // Second member's offset saturated at 0xFFFF (would have wrapped to 0xFFFE / panicked).
    try testing.expectEqual(@as(u16, 0xFFFF), ms[1].byte_offset);
}

test {
    testing.refAllDecls(@This());
}
