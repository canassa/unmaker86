//! `src/debug/core/vars.zig` — the PURE scope/locals/variable-tree renderer (M-S2 §3).
//!
//! Generalizes the M-S1 integration proof's hardcoded `.auto=4 → SS:[BP+4]` read into a
//! `Storage`-driven dispatch (§3.3) + type-directed rendering (§3.4) + a lazy one-level
//! expansion handle (§3.5). It decides WHAT to read and produces neutral `core.Variable`
//! DTOs (name borrowed from the symbol arena, value rendered into a caller scratch buffer);
//! the WORKER emits them to JSON and streams the type name via `typeName` (T13).
//!
//! Determinism (CLAUDE.md §1): EVERY read is a side-effect-free peek —
//! `cpuSnapshot`/`peekMemPhys` — NEVER `bus.read*`/`portIn*`. It charges ZERO cycles and
//! leaves `ctrl.snapshot()` byte-identical. On the `src/debug` grep gate: no host clock,
//! RNG, FLOAT (a float local renders as raw hex bytes — no x87, §3.4), atomic, thread, or
//! unordered container. Ordering is dense/declaration-order (never hashed).
//!
//! No fabrication (CLAUDE.md §2): a value is either correct or HONESTLY flagged —
//! `outer_frame_register` (a callee-clobbered reg of a non-top frame), `unreadable` (the
//! address is not in mapped RAM — DISTINCT from a `<null>` pointer), `<null>` (an honest
//! zero pointer), `(?)` (an enum value with no declared enumerator), `no_storage` (an
//! unmodelled storage class). NEVER a guessed number.

const std = @import("std");
const core = @import("core.zig");
const debugger = @import("debugger.zig");
const types = @import("../symbols/types.zig");
const format = @import("../symbols/format.zig");

const SourceDebugger = debugger.SourceDebugger;
const ExpandNode = debugger.ExpandNode;
const Addr = core.Addr;
const Frame = core.Frame;
const Variable = core.Variable;
const Local = types.Local;
const TypeId = format.TypeId;

// ─────────────────────────── scope / locals gathering (§3.2) ───────────────────────────

/// Gather the locals VISIBLE at `frame`'s pc: the innermost scope covering the pc plus its
/// ancestors via `parentOf`, in dense `localsForScope` order (innermost first). Collapsed
/// into one flat list (T12 — no args/locals split). Returns `out[0..n]`.
///
/// De-duplicated by NAME, INNERMOST-WINS (the C shadowing rule): Borland re-declares an
/// optimized parameter in the inner block scope as a live REGISTER copy while the outer
/// function scope keeps its (now-stale) BP-home auto slot — showing both would list a name
/// twice with a stale value. The innermost binding is the live one, so a name already seen
/// on the way up shadows any ancestor re-declaration. (Matches the M-S1 integration proof's
/// single {v:auto, lo:BX, hi:CX, r:DX} set for `clamp`.)
pub fn frameLocals(sd: *SourceDebugger, frame: Frame, out: []Local) []const Local {
    const s = if (sd.syms) |*sy| sy else return out[0..0];
    const m = sd.map orelse return out[0..0];
    const tg = if (s.typegraph) |*g| g else return out[0..0];
    var scope = s.scopeForRuntimeAddr(m, frame.pc.linear) orelse return out[0..0];

    var n: usize = 0;
    var guard: usize = 0;
    while (guard <= core.MAX_LOCALS) : (guard += 1) {
        locals: for (tg.localsForScope(scope)) |l| {
            if (n >= out.len) return out[0..n];
            const nm = tdsName(sd, l.name_index);
            // Skip a name already bound by a more-inner scope (shadowing).
            for (out[0..n]) |seen| {
                if (std.mem.eql(u8, tdsName(sd, seen.name_index), nm)) continue :locals;
            }
            out[n] = l;
            n += 1;
        }
        scope = tg.parentOf(scope) orelse break;
    }
    return out[0..n];
}

// ─────────────────────────── local rendering (§3.3 Storage dispatch) ───────────────────────────

/// Render one local of `frame` into a `core.Variable` (value text written into `scratch`).
/// Frame-0 register locals read the LIVE registers; an OUTER frame's register local is
/// honestly `outer_frame_register` (§2.6). Auto/static reads are bounds-checked against the
/// RAM slab (`unreadable` on miss). Mints a `variables_ref` for an aggregate/array/pointer.
pub fn renderLocal(sd: *SourceDebugger, frame: Frame, local: Local, scratch: []u8) Variable {
    const name = tdsName(sd, local.name_index);
    const is_frame0 = frame.index == 0;
    switch (local.storage) {
        .auto => |off| {
            const snap = sd.ctrl.cpuSnapshot();
            const eff: u16 = @truncate(frame.frame_base +% @as(u16, @bitCast(off)));
            const linear = snap.ss_base +% eff;
            const a = Addr{ .seg = snap.ss, .off = eff, .linear = linear };
            return renderValueAt(sd, name, local.type_ref, .{ .mem = linear }, a, 0, frame.index, scratch);
        },
        .static => |st| {
            const linear = if (sd.map) |m| m.toRuntimeLinear(st.segment, st.offset) else return unreadableVar(name, local.type_ref);
            const a = Addr{ .seg = st.segment, .off = st.offset, .linear = linear };
            return renderValueAt(sd, name, local.type_ref, .{ .mem = linear }, a, 0, frame.index, scratch);
        },
        .register => |r| {
            if (!is_frame0) return .{ .name = name, .type_ref = local.type_ref, .avail = .outer_frame_register };
            return renderValueAt(sd, name, local.type_ref, .{ .reg = r }, null, 0, frame.index, scratch);
        },
        .constant => |c| return renderValueAt(sd, name, local.type_ref, .{ .imm = c }, null, 0, frame.index, scratch),
        .absolute => |aval| return renderValueAt(sd, name, local.type_ref, .{ .imm = @as(i64, aval) }, null, 0, frame.index, scratch),
        .other => return .{ .name = name, .type_ref = local.type_ref, .avail = .no_storage },
    }
}

// ─────────────────────────── expansion (§3.4 type-directed, one level) ───────────────────────────

/// The number of children a `variables_ref` node expands to (before paging). `.locals`
/// re-gathers the frame's locals; `.aggregate` = member (+ base) count; `.array` =
/// `elem_count`; `.pointee` = 1 (the single deref).
pub fn childCount(sd: *SourceDebugger, node: ExpandNode) usize {
    return switch (node.target) {
        .locals => blk: {
            var buf: [core.MAX_LOCALS]Local = undefined;
            break :blk frameLocalsForIndex(sd, node.frame_index, buf[0..]).len;
        },
        .aggregate => aggregateChildCount(sd, node.type_ref),
        .array => node.elem_count,
        .pointee => 1,
    };
}

/// Render the `index`-th child of an expansion `node` (value into `scratch`). Used by the
/// `variables{ref,start,count}` paging loop. `index` is 0-based over the node's children.
pub fn renderChild(sd: *SourceDebugger, node: ExpandNode, index: usize, scratch: []u8) Variable {
    switch (node.target) {
        .locals => {
            var buf: [core.MAX_LOCALS]Local = undefined;
            const ls = frameLocalsForIndex(sd, node.frame_index, buf[0..]);
            if (index >= ls.len) return .{ .name = "" };
            var fbuf: [core.MAX_FRAMES]Frame = undefined;
            const frame = frameByIndex(sd, node.frame_index, fbuf[0..]) orelse return .{ .name = "" };
            return renderLocal(sd, frame, ls[index], scratch);
        },
        .aggregate => return renderAggregateChild(sd, node, index, scratch),
        .array => {
            const elem_size = typeSize(sd, node.type_ref);
            const child_lin = node.base.linear +% @as(u32, @intCast(index)) *% elem_size;
            const a = Addr{ .seg = node.base.seg, .off = @truncate(node.base.off +% @as(u16, @intCast(index)) *% elem_size), .linear = child_lin };
            var nb: [16]u8 = undefined;
            const nm = std.fmt.bufPrint(&nb, "[{d}]", .{index}) catch "[?]";
            // The index label lives in a stack buffer that dies with this call — copy it into
            // the caller's scratch tail so the returned Variable.name stays valid.
            const nlen = @min(nm.len, scratch.len);
            @memcpy(scratch[0..nlen], nm[0..nlen]);
            const vt = renderValueAt(sd, scratch[0..nlen], node.type_ref, .{ .mem = child_lin }, a, 0, node.frame_index, scratch[nlen..]);
            return vt;
        },
        .pointee => {
            if (pointeeIsNull(node)) return .{ .name = "*", .value_text = "<null>", .avail = .ok };
            const a = Addr{ .seg = node.base.seg, .off = node.base.off, .linear = node.base.linear };
            return renderValueAt(sd, "*", node.type_ref, .{ .mem = node.base.linear }, a, 0, node.frame_index, scratch);
        },
    }
}

// ─────────────────────────── the value renderer ───────────────────────────

/// Where a value lives. `pub` so the M-S3 expression evaluator (`expr.zig`) composes the
/// same value-location union the M-S2 renderer/resolver use.
pub const Place = union(enum) {
    mem: u32, // physical linear (bounds-checked against the RAM slab on read)
    reg: u8, // frame-0 x86 register number (format.Reg)
    imm: i64, // a constant/absolute immediate
};

pub fn renderValueAt(
    sd: *SourceDebugger,
    name: []const u8,
    type_ref: u16,
    place: Place,
    addr: ?Addr,
    bit_width: u8,
    frame_index: u32,
    scratch: []u8,
) Variable {
    const s = if (sd.syms) |*sy| sy else return .{ .name = name, .type_ref = type_ref, .avail = .no_storage };
    const tg = if (s.typegraph) |*g| g else return .{ .name = name, .type_ref = type_ref, .avail = .no_storage };
    const ti = tg.typeInfo(type_ref) orelse return .{ .name = name, .type_ref = type_ref, .avail = .no_storage };

    // Read up to 8 bytes of the value into `bytes[0..size]` (LE). For `.mem`, an out-of-slab
    // read is HONESTLY `unreadable` — never the `unmapped_fill` byte rendered as a value.
    const size: u16 = @min(typeSize(sd, type_ref), 8);
    var bytes: [8]u8 = @splat(0);
    switch (place) {
        .mem => |lin| {
            if (!readMem(sd, lin, bytes[0..size])) return .{ .name = name, .type_ref = type_ref, .addr = addr, .avail = .unreadable };
        },
        .reg => |r| readReg(sd, r, bytes[0..size]),
        .imm => |v| std.mem.writeInt(u64, &bytes, @bitCast(v), .little),
    }

    var v = Variable{ .name = name, .type_ref = type_ref, .addr = addr, .bit_width = bit_width };
    switch (ti) {
        .primitive => |p| v.value_text = renderPrimitive(p.id, bytes[0..size], scratch),
        .enumeration => v.value_text = renderEnum(sd, type_ref, bytes[0..size], scratch),
        .pointer => |p| {
            v.value_text = renderPointer(sd, p.kind, bytes[0..size], scratch);
            // One-level deref on expand only (never inline — could read arbitrary memory).
            v.variables_ref = mintPointee(sd, p, bytes[0..size], frame_index);
        },
        .array => |arr| {
            v.value_text = renderAggregateSummary(scratch);
            if (addr) |a| v.variables_ref = sd.mintHandle(.{
                .target = .array,
                .frame_index = frame_index,
                .type_ref = arr.element,
                .base = a,
                .elem_count = arr.count,
            });
        },
        .aggregate => {
            v.value_text = renderAggregateSummary(scratch);
            if (addr) |a| v.variables_ref = sd.mintHandle(.{
                .target = .aggregate,
                .frame_index = frame_index,
                .type_ref = type_ref,
                .base = a,
            });
        },
        .function, .unknown, .typedef => v.value_text = "",
    }
    return v;
}

// ─────────────────────────── primitive / enum / pointer text ───────────────────────────

fn renderPrimitive(id: TypeId, bytes: []const u8, scratch: []u8) []const u8 {
    // Float family → raw hex bytes ONLY (no x87, no host float conversion — §3.4).
    switch (id) {
        .float, .double, .ldouble, .tpreal, .tbyte => return renderHexBytes(bytes, scratch),
        else => {},
    }
    const raw = leBytes(bytes);
    if (isSigned(id)) {
        const sval = signExtend(raw, bytes.len);
        return std.fmt.bufPrint(scratch, "{d} (0x{X})", .{ sval, raw }) catch "?";
    }
    return std.fmt.bufPrint(scratch, "{d} (0x{X})", .{ raw, raw }) catch "?";
}

/// Render an enum value as its declared enumerator NAME (e.g. `GRAPHICS`); an unmatched
/// value renders `<n> (?)` — NEVER an invented name (§3.4/§8).
fn renderEnum(sd: *SourceDebugger, type_ref: u16, bytes: []const u8, scratch: []u8) []const u8 {
    const s = if (sd.syms) |*sy| sy else return "?";
    const tg = if (s.typegraph) |*g| g else return "?";
    const val: i64 = signExtend(leBytes(bytes), bytes.len);
    for (tg.enumerators(type_ref)) |e| {
        if (@as(i64, e.value) == val) {
            const nm = tdsName(sd, e.name_index);
            return std.fmt.bufPrint(scratch, "{s} ({d})", .{ nm, val }) catch nm;
        }
    }
    return std.fmt.bufPrint(scratch, "{d} (?)", .{val}) catch "(?)";
}

fn renderPointer(sd: *SourceDebugger, kind: types.PtrKind, bytes: []const u8, scratch: []u8) []const u8 {
    _ = sd;
    if (bytes.len >= 4 and (kind == .far or kind == .huge)) {
        const off = std.mem.readInt(u16, bytes[0..2], .little);
        const seg = std.mem.readInt(u16, bytes[2..4], .little);
        return std.fmt.bufPrint(scratch, "{X:0>4}:{X:0>4}", .{ seg, off }) catch "?";
    }
    const off: u16 = @truncate(leBytes(bytes));
    return std.fmt.bufPrint(scratch, "0x{X:0>4}", .{off}) catch "?";
}

fn renderHexBytes(bytes: []const u8, scratch: []u8) []const u8 {
    if (scratch.len < 2 + bytes.len * 3) return "0x?";
    scratch[0] = '0';
    scratch[1] = 'x';
    var n: usize = 2;
    for (bytes, 0..) |b, i| {
        if (i != 0) {
            scratch[n] = ' ';
            n += 1;
        }
        _ = std.fmt.bufPrint(scratch[n..][0..2], "{X:0>2}", .{b}) catch return "0x?";
        n += 2;
    }
    return scratch[0..n];
}

fn renderAggregateSummary(scratch: []u8) []const u8 {
    _ = scratch;
    return "{...}";
}

// ─────────────────────────── aggregate expansion (§3.4) ───────────────────────────

fn aggregateChildCount(sd: *SourceDebugger, type_ref: u16) usize {
    const s = if (sd.syms) |*sy| sy else return 0;
    const tg = if (s.typegraph) |*g| g else return 0;
    var count: usize = 0;
    if (tg.typeInfo(type_ref)) |ti| {
        if (ti == .aggregate and ti.aggregate.is_class) count += tg.bases(type_ref).len;
    }
    count += tg.members(type_ref).len;
    return count;
}

/// Render the `index`-th child of an aggregate: base subobjects (class only) first, then
/// data/method members in declaration order, with bitfield extraction reconstructed by
/// tracking the packing (`MemberInfo` carries no bit-offset). Method/static members render
/// as a typed signature (no value).
fn renderAggregateChild(sd: *SourceDebugger, node: ExpandNode, index: usize, scratch: []u8) Variable {
    const s = if (sd.syms) |*sy| sy else return .{ .name = "" };
    const tg = if (s.typegraph) |*g| g else return .{ .name = "" };

    const is_class = if (tg.typeInfo(node.type_ref)) |ti| (ti == .aggregate and ti.aggregate.is_class) else false;
    const bs = if (is_class) tg.bases(node.type_ref) else &[_]types.BaseInfo{};
    if (index < bs.len) {
        const b = bs[index];
        const child_lin = node.base.linear +% b.byte_offset;
        const a = Addr{ .seg = node.base.seg, .off = node.base.off +% b.byte_offset, .linear = child_lin };
        return renderValueAt(sd, tagOrName(sd, b.type_ref), b.type_ref, .{ .mem = child_lin }, a, 0, node.frame_index, scratch);
    }
    const mi = index - bs.len;
    const ms = tg.members(node.type_ref);
    if (mi >= ms.len) return .{ .name = "" };
    const m = ms[mi];
    const name = tdsName(sd, m.name_index);

    // Non-data members (methods / statics) — a typed signature, no data offset (§3.4).
    if (m.kind != .data) return .{ .name = name, .type_ref = m.type_ref, .value_text = "", .avail = .no_storage };

    const child_lin = node.base.linear +% m.byte_offset;
    const a = Addr{ .seg = node.base.seg, .off = node.base.off +% m.byte_offset, .linear = child_lin };

    if (m.bit_width != 0) {
        // Reconstruct the bit start by re-walking the container run up to this member.
        const bit_start = bitfieldStart(ms, mi);
        return renderBitfield(sd, name, m, child_lin, a, bit_start, scratch);
    }
    return renderValueAt(sd, name, m.type_ref, .{ .mem = child_lin }, a, 0, node.frame_index, scratch);
}

/// The starting bit of member `mi` within its bitfield container: the sum of the widths of
/// the immediately-preceding bitfield members sharing the same `byte_offset`.
pub fn bitfieldStart(ms: []const types.MemberInfo, mi: usize) u32 {
    var start: u32 = 0;
    var k: usize = mi;
    while (k > 0) {
        k -= 1;
        if (ms[k].bit_width == 0 or ms[k].byte_offset != ms[mi].byte_offset) break;
        start += ms[k].bit_width;
    }
    return start;
}

fn renderBitfield(sd: *SourceDebugger, name: []const u8, m: types.MemberInfo, linear: u32, addr: Addr, bit_start: u32, scratch: []u8) Variable {
    return renderBitfieldAt(sd, name, m.type_ref, linear, addr, m.bit_width, bit_start, scratch);
}

/// Extract and render a bitfield of `width` bits starting at `bit_start` from the container
/// at `linear` (masked from the container's `typeSize` bytes, LE). An out-of-slab container
/// is HONESTLY `unreadable`. Shared by the member-expansion path and the `inspect` walk.
pub fn renderBitfieldAt(sd: *SourceDebugger, name: []const u8, type_ref: u16, linear: u32, addr: Addr, width: u8, bit_start: u32, scratch: []u8) Variable {
    const csize: u16 = @min(typeSize(sd, type_ref), 8);
    var bytes: [8]u8 = @splat(0);
    if (!readMem(sd, linear, bytes[0..csize])) return .{ .name = name, .type_ref = type_ref, .addr = addr, .bit_width = width, .avail = .unreadable };
    const container = leBytes(bytes[0..csize]);
    const mask: u64 = if (width >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width)) - 1;
    const field = (container >> @intCast(bit_start)) & mask;
    const vt = std.fmt.bufPrint(scratch, "{d} (0x{X})", .{ field, field }) catch "?";
    return .{ .name = name, .type_ref = type_ref, .value_text = vt, .addr = addr, .bit_width = width };
}

// ─────────────────────────── pointer deref minting ───────────────────────────

/// Decode a pointer's stored bytes into its target `{addr, is_null}` for `kind`, applying
/// the real-mode segment base (far/huge → the stored `seg:off`; a near pointer → the segment
/// implied by its `PtrKind`). Shared by the deref-minting path and the `inspect` walk so both
/// compute a pointee target identically.
/// A decoded pointer's target: the resolved `addr` (real-mode segment base applied per
/// `PtrKind`) and whether the stored pointer was null. `pub` so `expr.zig` names the type.
pub const PtrTarget = struct { addr: Addr, is_null: bool };

pub fn ptrTarget(sd: *SourceDebugger, kind: types.PtrKind, bytes: []const u8) PtrTarget {
    const snap = sd.ctrl.cpuSnapshot();
    if (bytes.len >= 4 and (kind == .far or kind == .huge)) {
        const off = std.mem.readInt(u16, bytes[0..2], .little);
        const seg = std.mem.readInt(u16, bytes[2..4], .little);
        return .{ .addr = .{ .seg = seg, .off = off, .linear = (@as(u32, seg) << 4) +% off }, .is_null = (off == 0 and seg == 0) };
    }
    const off: u16 = @truncate(leBytes(bytes));
    const base: u32 = switch (kind) {
        .near_cs => snap.cs_base,
        .near_ss => snap.ss_base,
        .near_es => snap.es_base,
        .near_fs => snap.fs_base,
        .near_gs => snap.gs_base,
        else => snap.ds_base, // near / near_ds default
    };
    return .{ .addr = .{ .seg = @truncate(base >> 4), .off = off, .linear = base +% off }, .is_null = (off == 0) };
}

fn mintPointee(sd: *SourceDebugger, p: anytype, bytes: []const u8, frame_index: u32) u64 {
    const t = ptrTarget(sd, p.kind, bytes);
    return sd.mintHandle(.{
        .target = .pointee,
        .frame_index = frame_index,
        .type_ref = p.pointee,
        .base = t.addr,
        .seg_sel = p.kind,
        .elem_count = if (t.is_null) 1 else 0, // reuse elem_count as the null marker (1 = null)
    });
}

fn pointeeIsNull(node: ExpandNode) bool {
    return node.target == .pointee and node.elem_count == 1;
}

// ─────────────────────────── low-level peek + helpers ───────────────────────────

/// Read `dst.len` bytes at physical `linear`, but ONLY if `[linear, linear+len)` is inside
/// the RAM slab — else return false (`unreadable`, never `unmapped_fill` as a value). This
/// is the pure core's own containment guard (worker `inSlab` analog, §3.3) via the public
/// `Controller.ramSlabSize`, keeping `vars.zig` off any `ctrl.m` internal.
pub fn readMem(sd: *SourceDebugger, linear: u32, dst: []u8) bool {
    const total = sd.ctrl.ramSlabSize();
    const end = @as(u64, linear) + @as(u64, dst.len);
    if (end > total) return false;
    sd.ctrl.peekMemPhys(linear, dst);
    return true;
}

/// Read an x86 register (frame 0) into `dst` (LE), per T7: Reg 0-7 → low 16 of eXX; Reg
/// 8-11 (al cl dl bl) → low byte; Reg 12-15 (ah ch dh bh) → (eXX>>8)&0xFF.
pub fn readReg(sd: *SourceDebugger, r: u8, dst: []u8) void {
    const snap = sd.ctrl.cpuSnapshot();
    const gp = [8]u32{ snap.eax, snap.ecx, snap.edx, snap.ebx, snap.esp, snap.ebp, snap.esi, snap.edi };
    var val: u32 = 0;
    if (r < 8) {
        val = gp[r] & 0xFFFF;
    } else if (r < 12) {
        val = gp[r - 8] & 0xFF;
    } else if (r < 16) {
        val = (gp[r - 12] >> 8) & 0xFF;
    }
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, val, .little);
    const n = @min(dst.len, 4);
    @memcpy(dst[0..n], b[0..n]);
    if (dst.len > n) @memset(dst[n..], 0);
}

pub fn leBytes(bytes: []const u8) u64 {
    var v: u64 = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        v = (v << 8) | bytes[i];
    }
    return v;
}

pub fn signExtend(raw: u64, size: usize) i64 {
    if (size == 0 or size >= 8) return @bitCast(raw);
    const bits: u6 = @intCast(size * 8);
    const sign_bit = @as(u64, 1) << (bits - 1);
    if (raw & sign_bit != 0) {
        const ext = ~((@as(u64, 1) << bits) - 1);
        return @bitCast(raw | ext);
    }
    return @bitCast(raw);
}

pub fn isSigned(id: TypeId) bool {
    return switch (id) {
        .schar, .sint, .slong, .squad, .pchar => true,
        else => false,
    };
}

pub fn typeSize(sd: *SourceDebugger, type_ref: u16) u16 {
    const s = if (sd.syms) |*sy| sy else return 0;
    const tg = if (s.typegraph) |*g| g else return 0;
    return tg.typeSize(type_ref);
}

pub fn tdsName(sd: *SourceDebugger, name_index: u16) []const u8 {
    const s = if (sd.syms) |*sy| sy else return "";
    if (s.tds) |t| return t.name(name_index);
    return "";
}

/// A base-class child's display name: the base's tag (via its type record). Falls back to
/// an empty string; the worker streams the full type name from `type_ref` regardless.
fn tagOrName(sd: *SourceDebugger, type_ref: u16) []const u8 {
    const s = if (sd.syms) |*sy| sy else return "";
    const tg = if (s.typegraph) |*g| g else return "";
    if (tg.typeInfo(type_ref)) |ti| {
        if (ti == .aggregate) return tdsName(sd, ti.aggregate.name_index);
    }
    return "";
}

pub fn unreadableVar(name: []const u8, type_ref: u16) Variable {
    return .{ .name = name, .type_ref = type_ref, .avail = .unreadable };
}

// ─────────────────────────── frame helpers (for handle-based expansion) ───────────────────────────

/// Re-run the unwinder and return the frame at `frame_index` (a handle carries only the
/// index; expansion re-peeks at the same stop). Null if the index is now out of range.
fn frameByIndex(sd: *SourceDebugger, frame_index: u32, buf: []Frame) ?Frame {
    const bt = core.unwind.backtrace(sd, buf, buf.len);
    if (frame_index >= bt.frames.len) return null;
    return bt.frames[frame_index];
}

fn frameLocalsForIndex(sd: *SourceDebugger, frame_index: u32, out: []Local) []const Local {
    var fbuf: [core.MAX_FRAMES]Frame = undefined;
    const frame = frameByIndex(sd, frame_index, fbuf[0..]) orelse return out[0..0];
    return frameLocals(sd, frame, out);
}

// ─────────────────────────── inspect: bounded path-addressed peek (§4) ───────────────────────────
//
// A STRICTLY-bounded, path-addressed variable read — NOT a C-expression evaluator (that is
// deferred to M-S3, §4). The grammar is: a head identifier, then any number of `.field`
// (struct/class member), `->field` (pointer deref + member), and `[const]` (array/pointer
// element by a CONSTANT index) segments. ANYTHING else (operators / casts / `&` / `*` / a
// non-constant index / a function call) → `error.Unsupported` — the honest "use the future
// evaluator" signal, NEVER a guessed or partially-evaluated result (CLAUDE.md §2). A name /
// member / index that does not resolve → `error.Unresolved`. A null pointer along the path
// resolves to a `<null>` value (no wild read); an out-of-RAM address to `unreadable`.

/// The number of path segments an `inspect` path may carry (a `DBG_PATH_CAP`-bounded path
/// cannot exceed this — each segment is ≥2 chars). A deeper path → `error.Unsupported`.
const MAX_INSPECT_SEGS: usize = 64;

pub const InspectError = error{ Unresolved, Unsupported };

const Seg = union(enum) { field: []const u8, arrow: []const u8, index: u32 };

/// The current resolution position: a type plus WHERE its value lives, and (when the node is
/// a bitfield member) the extraction window for the terminal render.
pub const Cursor = struct {
    type_ref: u16,
    place: Place,
    addr: ?Addr,
    bit: ?struct { width: u8, start: u32 } = null,
};

/// One walk step outcome: either a new cursor, or a TERMINAL value that ends the walk (a
/// `<null>` deref or an `unreadable` address — honest short-circuits, not errors).
pub const StepOut = union(enum) { cur: Cursor, terminal: Variable };

/// Resolve `path` against `frame`'s locals + the type graph and render the resolved variable
/// (value + type + an expandable `variables_ref` for an aggregate/array/pointer), exactly like
/// a Stage-3 local. The head identifier is looked up by NAME in the frame's locals; segments
/// walk the type graph via peek reads. Pure (peek-only, zero cycles). See the section header
/// for the grammar + the honest-degradation contract.
pub fn inspectPath(sd: *SourceDebugger, frame: Frame, path: []const u8, scratch: []u8) InspectError!Variable {
    // 1. Tokenize the WHOLE path FIRST (before any name resolution) so a bad token (e.g. the
    //    `+` in `a+b`) is reported as `Unsupported` regardless of whether `a` resolves — the
    //    anti-eval boundary must not be masked by an unrelated `Unresolved`.
    var parser = Parser{ .src = path };
    const head = try parser.parseHead();
    var segs: [MAX_INSPECT_SEGS]Seg = undefined;
    var nseg: usize = 0;
    while (try parser.parseSeg()) |seg| {
        if (nseg >= segs.len) return error.Unsupported;
        segs[nseg] = seg;
        nseg += 1;
    }

    // 2. Resolve the head local by name in the selected frame.
    var lbuf: [core.MAX_LOCALS]Local = undefined;
    const ls = frameLocals(sd, frame, lbuf[0..]);
    var head_local: ?Local = null;
    for (ls) |l| {
        if (std.mem.eql(u8, tdsName(sd, l.name_index), head)) {
            head_local = l;
            break;
        }
    }
    const local = head_local orelse return error.Unresolved;
    const is_frame0 = frame.index == 0;

    var cur: Cursor = undefined;
    switch (local.storage) {
        .auto => |off| {
            const snap = sd.ctrl.cpuSnapshot();
            const eff: u16 = @truncate(frame.frame_base +% @as(u16, @bitCast(off)));
            const linear = snap.ss_base +% eff;
            cur = .{ .type_ref = local.type_ref, .place = .{ .mem = linear }, .addr = .{ .seg = snap.ss, .off = eff, .linear = linear } };
        },
        .static => |st| {
            const m = sd.map orelse {
                if (nseg != 0) return error.Unresolved;
                return unreadableVar(path, local.type_ref);
            };
            const linear = m.toRuntimeLinear(st.segment, st.offset);
            cur = .{ .type_ref = local.type_ref, .place = .{ .mem = linear }, .addr = .{ .seg = st.segment, .off = st.offset, .linear = linear } };
        },
        .register => |rn| {
            // An OUTER-frame register is honestly unrecoverable (§2.6): report it for a bare
            // name, refuse to descend (we cannot read the callee-clobbered value).
            if (!is_frame0) {
                if (nseg != 0) return error.Unresolved;
                return .{ .name = path, .type_ref = local.type_ref, .avail = .outer_frame_register };
            }
            cur = .{ .type_ref = local.type_ref, .place = .{ .reg = rn }, .addr = null };
        },
        // A constant/absolute has no addressable storage — a bare name renders it; a member/
        // index of a constant is not resolvable.
        .constant => |cval| {
            if (nseg != 0) return error.Unresolved;
            return renderValueAt(sd, path, local.type_ref, .{ .imm = cval }, null, 0, frame.index, scratch);
        },
        .absolute => |aval| {
            if (nseg != 0) return error.Unresolved;
            return renderValueAt(sd, path, local.type_ref, .{ .imm = @as(i64, aval) }, null, 0, frame.index, scratch);
        },
        .other => {
            if (nseg != 0) return error.Unresolved;
            return .{ .name = path, .type_ref = local.type_ref, .avail = .no_storage };
        },
    }

    // 3. Walk the segments. A `<null>`/`unreadable` terminal short-circuits honestly.
    for (segs[0..nseg]) |seg| {
        switch (try stepOne(sd, cur, seg, path)) {
            .cur => |c2| cur = c2,
            .terminal => |v| return v,
        }
    }

    // 4. Render the resolved location, exactly like a Stage-3 local (name = the full path).
    if (cur.bit) |bf| {
        const a = cur.addr orelse return error.Unresolved;
        return renderBitfieldAt(sd, path, cur.type_ref, a.linear, a, bf.width, bf.start, scratch);
    }
    return renderValueAt(sd, path, cur.type_ref, cur.place, cur.addr, 0, frame.index, scratch);
}

/// Advance the cursor by one path segment.
fn stepOne(sd: *SourceDebugger, cur: Cursor, seg: Seg, path: []const u8) InspectError!StepOut {
    switch (seg) {
        .field => |nm| return fieldAccess(sd, cur, nm),
        .arrow => |nm| {
            // `->field` = deref one level, then a member on the pointee aggregate.
            switch (try derefStep(sd, cur, path)) {
                .terminal => |v| return .{ .terminal = v },
                .cur => |pc| return fieldAccess(sd, pc, nm),
            }
        },
        .index => |i| return indexAccess(sd, cur, i, path),
    }
}

/// `.field` — a struct/class DATA member by name. Non-aggregate / non-memory / method or
/// missing member → `Unresolved` (a typed refusal, never a wild read).
pub fn fieldAccess(sd: *SourceDebugger, cur: Cursor, name: []const u8) InspectError!StepOut {
    if (cur.bit != null) return error.Unresolved; // a bitfield scalar has no members
    const addr = cur.addr orelse return error.Unresolved; // a register/immediate aggregate is not addressable
    const ti = typeInfoOf(sd, cur.type_ref) orelse return error.Unresolved;
    if (ti != .aggregate) return error.Unresolved;
    const s = if (sd.syms) |*sy| sy else return error.Unresolved;
    const tg = if (s.typegraph) |*g| g else return error.Unresolved;
    const ms = tg.members(cur.type_ref);
    for (ms, 0..) |m, mi| {
        if (!std.mem.eql(u8, tdsName(sd, m.name_index), name)) continue;
        if (m.kind != .data) return error.Unresolved; // a method/static has no data offset
        const child_lin = addr.linear +% m.byte_offset;
        const a = Addr{ .seg = addr.seg, .off = addr.off +% m.byte_offset, .linear = child_lin };
        var out = Cursor{ .type_ref = m.type_ref, .place = .{ .mem = child_lin }, .addr = a };
        if (m.bit_width != 0) out.bit = .{ .width = m.bit_width, .start = bitfieldStart(ms, mi) };
        return .{ .cur = out };
    }
    return error.Unresolved;
}

/// Dereference the pointer AT `cur` one level, yielding a cursor at the pointee (an aggregate
/// base for a following `->field`). A null pointer → a `<null>` terminal; an out-of-slab
/// pointer read → an `unreadable` terminal (both honest — never a wild read).
pub fn derefStep(sd: *SourceDebugger, cur: Cursor, path: []const u8) InspectError!StepOut {
    const ti = typeInfoOf(sd, cur.type_ref) orelse return error.Unresolved;
    if (ti != .pointer) return error.Unresolved;
    const p = ti.pointer;
    const psize: u16 = @min(typeSize(sd, cur.type_ref), 8);
    var bytes: [8]u8 = @splat(0);
    switch (cur.place) {
        .mem => |lin| if (!readMem(sd, lin, bytes[0..psize])) return .{ .terminal = unreadableVar(path, cur.type_ref) },
        .reg => |r| readReg(sd, r, bytes[0..psize]),
        .imm => |v| std.mem.writeInt(u64, &bytes, @bitCast(v), .little),
    }
    const t = ptrTarget(sd, p.kind, bytes[0..psize]);
    if (t.is_null) return .{ .terminal = nullVar(path) };
    return .{ .cur = .{ .type_ref = p.pointee, .place = .{ .mem = t.addr.linear }, .addr = t.addr } };
}

/// `[i]` — an array element (bounds-checked against the declared count) or a pointer element
/// (deref + `i * sizeof(pointee)`). Anything else → `Unresolved`; an out-of-bounds array
/// index → `Unresolved` (a typed refusal, never a wild read past the array).
pub fn indexAccess(sd: *SourceDebugger, cur: Cursor, i: u32, path: []const u8) InspectError!StepOut {
    if (cur.bit != null) return error.Unresolved;
    const ti = typeInfoOf(sd, cur.type_ref) orelse return error.Unresolved;
    switch (ti) {
        .array => |arr| {
            const addr = cur.addr orelse return error.Unresolved;
            if (i >= arr.count) return error.Unresolved; // out of bounds — refuse, never a wild read
            const esize = typeSize(sd, arr.element);
            const child_lin = addr.linear +% i *% esize;
            const a = Addr{ .seg = addr.seg, .off = @truncate(addr.off +% @as(u16, @truncate(i *% esize))), .linear = child_lin };
            return .{ .cur = .{ .type_ref = arr.element, .place = .{ .mem = child_lin }, .addr = a } };
        },
        .pointer => |p| {
            const psize: u16 = @min(typeSize(sd, cur.type_ref), 8);
            var bytes: [8]u8 = @splat(0);
            switch (cur.place) {
                .mem => |lin| if (!readMem(sd, lin, bytes[0..psize])) return .{ .terminal = unreadableVar(path, cur.type_ref) },
                .reg => |r| readReg(sd, r, bytes[0..psize]),
                .imm => |v| std.mem.writeInt(u64, &bytes, @bitCast(v), .little),
            }
            const t = ptrTarget(sd, p.kind, bytes[0..psize]);
            if (t.is_null) return .{ .terminal = nullVar(path) };
            const esize = typeSize(sd, p.pointee);
            const child_lin = t.addr.linear +% i *% esize;
            const a = Addr{ .seg = t.addr.seg, .off = @truncate(t.addr.off +% @as(u16, @truncate(i *% esize))), .linear = child_lin };
            return .{ .cur = .{ .type_ref = p.pointee, .place = .{ .mem = child_lin }, .addr = a } };
        },
        else => return error.Unresolved,
    }
}

pub fn nullVar(name: []const u8) Variable {
    return .{ .name = name, .value_text = "<null>", .avail = .ok };
}

pub fn typeInfoOf(sd: *SourceDebugger, type_ref: u16) ?types.TypeInfo {
    const s = if (sd.syms) |*sy| sy else return null;
    const tg = if (s.typegraph) |*g| g else return null;
    return tg.typeInfo(type_ref);
}

/// The bounded-grammar path tokenizer. `parseHead` returns the head identifier (or
/// `Unsupported` if the path does not start with one); `parseSeg` returns the next segment or
/// null at end, and `Unsupported` on ANY token outside the grammar (an operator, a cast, a
/// non-constant index, a stray character).
const Parser = struct {
    src: []const u8,
    i: usize = 0,

    fn skipws(self: *Parser) void {
        while (self.i < self.src.len and (self.src[self.i] == ' ' or self.src[self.i] == '\t')) self.i += 1;
    }

    fn ident(self: *Parser) ?[]const u8 {
        if (self.i >= self.src.len) return null;
        const c0 = self.src[self.i];
        if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.src.len) : (self.i += 1) {
            const c = self.src[self.i];
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
        }
        return self.src[start..self.i];
    }

    fn parseHead(self: *Parser) InspectError![]const u8 {
        self.skipws();
        return self.ident() orelse error.Unsupported;
    }

    fn parseSeg(self: *Parser) InspectError!?Seg {
        self.skipws();
        if (self.i >= self.src.len) return null;
        switch (self.src[self.i]) {
            '.' => {
                self.i += 1;
                return Seg{ .field = self.ident() orelse return error.Unsupported };
            },
            '-' => {
                if (self.i + 1 >= self.src.len or self.src[self.i + 1] != '>') return error.Unsupported;
                self.i += 2;
                return Seg{ .arrow = self.ident() orelse return error.Unsupported };
            },
            '[' => {
                self.i += 1;
                self.skipws();
                const dstart = self.i;
                while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.i += 1;
                if (self.i == dstart) return error.Unsupported; // empty / non-constant index
                const idx = std.fmt.parseInt(u32, self.src[dstart..self.i], 10) catch return error.Unsupported;
                self.skipws();
                if (self.i >= self.src.len or self.src[self.i] != ']') return error.Unsupported;
                self.i += 1;
                return Seg{ .index = idx };
            },
            // Any other character (an operator, `&`, `*`, `(`, a cast, …) is outside the subset.
            else => return error.Unsupported,
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
