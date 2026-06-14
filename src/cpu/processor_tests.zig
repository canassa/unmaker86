//! SingleStepTests 80386 conformance harness (Phase 8).
//!
//! FORMAT: the 386 vectors (repo `SingleStepTests/80386`,
//! `v1_ex_real_mode/*.MOO.gz`) use the binary **MOO format** (spec:
//! github.com/dbalsom/moo, v1.1), NOT JSON (the original plan's assumption).
//! This harness implements a faithful MOO chunk parser per the spec.
//!
//! VENDORING: the vectors + 80386.csv + revocation_list.txt are vendored under
//! `src/cpu/testdata/80386/` (PUBLIC-DOMAIN data — license-safe). They are kept
//! gzipped and decompressed in-harness with `std.compress.flate` — no runtime
//! fetch (determinism / offline rule). The corpus is CYCL-stripped and capped at
//! 100 vectors/opcode (~19 MB, all 941 opcodes); see that directory's README.
//!
//! RUNNING:
//!   - `zig build conformance` runs the FULL sweep over all vendored vectors and
//!     prints per-failing-opcode + grand-total pass/fail/revoked counts
//!     (conformance_main.zig).
//!   - `zig build test` runs a fast curated regression guard (conformance_test.zig).
//!
//! ASSERTIONS (D8): final registers, flags, and memory bytes. NOT bus cycles.
//! Undefined EFLAGS bits are masked per the D9 policy (80386.csv `f_umask` +
//! a documented supplement for CSV gaps; see `undef_supplement`). Revoked
//! vectors (revocation_list.txt) are counted and skipped, never silently dropped.
//!
//! KNOWN RESIDUAL DIVERGENCES (documented, not bugs — each is a genuinely-
//! undefined 386 result for which there is no portable oracle):
//!   - SHLD/SHRD with shift count > operand size: the RESULT is architecturally
//!     undefined, so the derived SF/ZF/PF differ on a minority of vectors.
//!   - DIV/IDIV that fault #DE: the 386 leaves the arithmetic flags undefined and
//!     pushes them in the IVT frame, so the pushed-FLAGS word differs on a
//!     minority of divide-error vectors (the undefined bits cannot be masked once
//!     they are memory bytes).
//!   - A few rotate-by-CL vectors where the count is a non-1 multiple of the
//!     operand width (OF undefined per Intel).
//! These account for the residual sub-100% rate on the affected opcodes; the
//! defined state always matches.

const std = @import("std");
pub const cpu_mod = @import("cpu.zig");
const state = @import("state.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;
pub const TestBus = cpu_mod.TestBus;

// ---------------------------------------------------------------------------
// The ProcessorTest contract (format-agnostic). A MOO/JSON parser produces
// these; the runner consumes them.
// ---------------------------------------------------------------------------

/// One memory address/value entry.
pub const RamEntry = struct { addr: u32, value: u8 };

/// 32-bit register file snapshot (RG32 chunk order). null = not present.
pub const Regs32 = struct {
    cr0: ?u32 = null,
    cr3: ?u32 = null,
    eax: ?u32 = null,
    ebx: ?u32 = null,
    ecx: ?u32 = null,
    edx: ?u32 = null,
    esi: ?u32 = null,
    edi: ?u32 = null,
    ebp: ?u32 = null,
    esp: ?u32 = null,
    cs: ?u32 = null,
    ds: ?u32 = null,
    es: ?u32 = null,
    fs: ?u32 = null,
    gs: ?u32 = null,
    ss: ?u32 = null,
    eip: ?u32 = null,
    eflags: ?u32 = null,
    dr6: ?u32 = null,
    dr7: ?u32 = null,
};

pub const StateSnap = struct {
    regs: Regs32 = .{},
    ram: []RamEntry = &.{},
};

pub const ProcessorTest = struct {
    name: []const u8 = "",
    bytes: []const u8 = &.{},
    initial: StateSnap = .{},
    final: StateSnap = .{},
    /// Optional final register mask (RM32) for undefined-state suppression.
    final_mask: Regs32 = .{},
    hash: [16]u8 = @splat(0),
};

// ---------------------------------------------------------------------------
// MOO chunk parser (spec: dbalsom/moo v1.1). All fields little-endian.
// ---------------------------------------------------------------------------

pub const MooError = error{ BadMagic, Truncated, OutOfMemory };

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn rem(self: Cursor) usize {
        return self.data.len - self.pos;
    }
    fn readU8(self: *Cursor) !u8 {
        if (self.rem() < 1) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn readU16(self: *Cursor) !u16 {
        if (self.rem() < 2) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *Cursor) !u32 {
        if (self.rem() < 4) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn id(self: *Cursor) ![4]u8 {
        if (self.rem() < 4) return error.Truncated;
        const v = self.data[self.pos..][0..4].*;
        self.pos += 4;
        return v;
    }
    fn slice(self: *Cursor, n: usize) ![]const u8 {
        if (self.rem() < n) return error.Truncated;
        const v = self.data[self.pos..][0..n];
        self.pos += n;
        return v;
    }
};

/// The 20 RG32 register slots in bitmask order.
const rg32_order = [_][]const u8{
    "cr0", "cr3", "eax", "ebx", "ecx", "edx", "esi", "edi",    "ebp", "esp",
    "cs",  "ds",  "es",  "fs",  "gs",  "ss",  "eip", "eflags", "dr6", "dr7",
};

fn setRg32Field(regs: *Regs32, idx: usize, value: u32) void {
    inline for (rg32_order, 0..) |name, i| {
        if (i == idx) {
            @field(regs, name) = value;
            return;
        }
    }
}

/// Parse one MOO file (decompressed bytes) into a list of ProcessorTest.
/// Caller owns the returned slice and the arena it was allocated from.
pub fn parseMoo(arena: std.mem.Allocator, data: []const u8) MooError![]ProcessorTest {
    var c = Cursor{ .data = data };
    const magic = c.id() catch return error.Truncated;
    if (!std.mem.eql(u8, &magic, "MOO ")) return error.BadMagic;
    const hdr_len = c.readU32() catch return error.Truncated;
    _ = c.slice(hdr_len) catch return error.Truncated; // skip MOO header payload

    var tests: std.ArrayList(ProcessorTest) = .empty;

    while (c.rem() >= 8) {
        const ctype = try c.id();
        const clen = try c.readU32();
        const body = try c.slice(clen);
        if (std.mem.eql(u8, &ctype, "TEST")) {
            const t = try parseTest(arena, body);
            try tests.append(arena, t);
        }
        // META / RMSK / RM32 top-level chunks are skipped (undefined-flag masks
        // are handled per-test FINA RM32; a file-level RM32 could be applied to
        // all tests — left as a future refinement, flagged).
    }
    return tests.toOwnedSlice(arena);
}

fn parseTest(arena: std.mem.Allocator, body: []const u8) MooError!ProcessorTest {
    var c = Cursor{ .data = body };
    _ = try c.readU32(); // index
    var t = ProcessorTest{};
    while (c.rem() >= 8) {
        const ctype = try c.id();
        const clen = try c.readU32();
        const sub = try c.slice(clen);
        if (std.mem.eql(u8, &ctype, "NAME")) {
            var sc = Cursor{ .data = sub };
            const n = try sc.readU32();
            t.name = try arena.dupe(u8, try sc.slice(n));
        } else if (std.mem.eql(u8, &ctype, "BYTS")) {
            var sc = Cursor{ .data = sub };
            const n = try sc.readU32();
            t.bytes = try arena.dupe(u8, try sc.slice(n));
        } else if (std.mem.eql(u8, &ctype, "INIT")) {
            t.initial = try parseSnap(arena, sub, null);
        } else if (std.mem.eql(u8, &ctype, "FINA")) {
            t.final = try parseSnap(arena, sub, &t.final_mask);
        } else if (std.mem.eql(u8, &ctype, "HASH")) {
            if (sub.len >= 16) @memcpy(&t.hash, sub[0..16]);
        }
    }
    return t;
}

fn parseSnap(arena: std.mem.Allocator, payload: []const u8, mask_out: ?*Regs32) MooError!StateSnap {
    var c = Cursor{ .data = payload };
    var snap = StateSnap{};
    var ram: std.ArrayList(RamEntry) = .empty;
    while (c.rem() >= 8) {
        const ctype = try c.id();
        const clen = try c.readU32();
        const sub = try c.slice(clen);
        if (std.mem.eql(u8, &ctype, "RG32")) {
            snap.regs = try parseRg32(sub);
        } else if (std.mem.eql(u8, &ctype, "RM32")) {
            if (mask_out) |m| m.* = try parseRg32(sub);
        } else if (std.mem.eql(u8, &ctype, "RAM ")) {
            var sc = Cursor{ .data = sub };
            const n = try sc.readU32();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const addr = try sc.readU32();
                const val = try sc.readU8();
                try ram.append(arena, .{ .addr = addr, .value = val });
            }
        }
    }
    snap.ram = try ram.toOwnedSlice(arena);
    return snap;
}

fn parseRg32(sub: []const u8) MooError!Regs32 {
    var c = Cursor{ .data = sub };
    const mask = try c.readU32();
    var regs = Regs32{};
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if ((mask & (@as(u32, 1) << @intCast(i))) != 0) {
            setRg32Field(&regs, i, try c.readU32());
        }
    }
    return regs;
}

// ---------------------------------------------------------------------------
// The runner: load initial state, execute until HALT (the test terminator),
// compare final registers/flags/memory. State-only by default (D8).
// ---------------------------------------------------------------------------

pub const RunResult = struct { ok: bool, detail: []const u8 = "" };

const RunCpu = cpu_mod.Cpu(TestBus);

/// Load a snapshot's registers into the CPU (real mode: bases from selectors).
pub fn loadRegs(cpu: *RunCpu, regs: Regs32) void {
    if (regs.eax) |v| cpu.st.setReg32(@intFromEnum(Reg32.eax), v);
    if (regs.ebx) |v| cpu.st.setReg32(@intFromEnum(Reg32.ebx), v);
    if (regs.ecx) |v| cpu.st.setReg32(@intFromEnum(Reg32.ecx), v);
    if (regs.edx) |v| cpu.st.setReg32(@intFromEnum(Reg32.edx), v);
    if (regs.esi) |v| cpu.st.setReg32(@intFromEnum(Reg32.esi), v);
    if (regs.edi) |v| cpu.st.setReg32(@intFromEnum(Reg32.edi), v);
    if (regs.ebp) |v| cpu.st.setReg32(@intFromEnum(Reg32.ebp), v);
    if (regs.esp) |v| cpu.st.setReg32(@intFromEnum(Reg32.esp), v);
    if (regs.eip) |v| cpu.st.eip = v;
    if (regs.eflags) |v| cpu.st.eflags = cpu_mod.flags.Flags.fromU32(v);
    if (regs.cr0) |v| cpu.st.cr0 = v;
    if (regs.cr3) |v| cpu.st.cr3 = v;
    if (regs.cs) |v| cpu.loadSegment(.cs, @truncate(v));
    if (regs.ds) |v| cpu.loadSegment(.ds, @truncate(v));
    if (regs.es) |v| cpu.loadSegment(.es, @truncate(v));
    if (regs.fs) |v| cpu.loadSegment(.fs, @truncate(v));
    if (regs.gs) |v| cpu.loadSegment(.gs, @truncate(v));
    if (regs.ss) |v| cpu.loadSegment(.ss, @truncate(v));
    // 386 real mode: all segment limits default to 0xFFFF (already at reset).
}

/// Per-run options. `undef_eflags` is the per-opcode EFLAGS undefined-bit mask
/// (from 80386.csv `f_umask`, D9): those bits are NOT compared because the 386
/// leaves them architecturally undefined for this opcode.
pub const RunOptions = struct {
    undef_eflags: u32 = 0,
};

/// EFLAGS bits the 386 architecturally defines (bits 0-17: CF..VM, including the
/// always-1 bit 1 and always-0 bits 3/5/15). Bits 18-31 do not exist on the 386
/// and are masked out of every comparison.
pub const EFLAGS_386_VALID: u32 = 0x0003_FFFF;

/// Detail of a single mismatch (for diagnosing conformance failures).
pub const Mismatch = enum {
    none,
    eax,
    ebx,
    ecx,
    edx,
    esi,
    edi,
    ebp,
    esp,
    eip,
    cs,
    ds,
    es,
    ss,
    fs,
    gs,
    eflags,
    memory,
};

/// Run a single ProcessorTest. Returns whether final state matches.
pub fn runOne(allocator: std.mem.Allocator, t: ProcessorTest) !bool {
    return (try runOneDetail(allocator, t, .{})) == .none;
}

/// Run a single ProcessorTest, returning the first mismatched field (or .none).
pub fn runOneDetail(allocator: std.mem.Allocator, t: ProcessorTest, ropts: RunOptions) !Mismatch {
    var bus = TestBus.init(allocator);
    defer bus.deinit();
    // SingleStepTests convention: every port read returns the floating-bus value
    // 0xFF (all bits high) — IN/INS vectors assume this deterministic input.
    bus.port_in_value = 0xFFFF_FFFF;
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = RunCpu.init(&bus, &pic, &sched);

    loadRegs(&cpu, t.initial.regs);
    for (t.initial.ram) |e| bus.writeByte(e.addr, e.value);

    // Execute up to (and INCLUDING) the terminating HALT. MOO convention: the
    // test bytes are the instruction-under-test FOLLOWED by a 0xF4 HALT marker,
    // and the FINA state is captured once the HALT has been fetched (EIP points
    // just past the 0xF4) and the CPU has entered the halted state. So we step
    // until `halted` (or `shutdown`) is latched. Bounded for safety.
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        if (cpu.st.halted or cpu.st.shutdown) break;
        _ = cpu.step();
    }

    // Compare final registers (apply RM32 mask: skip masked-out bits).
    if (!cmpReg(t.final.regs.eax, t.final_mask.eax, cpu.st.getReg32(@intFromEnum(Reg32.eax)))) return .eax;
    if (!cmpReg(t.final.regs.ebx, t.final_mask.ebx, cpu.st.getReg32(@intFromEnum(Reg32.ebx)))) return .ebx;
    if (!cmpReg(t.final.regs.ecx, t.final_mask.ecx, cpu.st.getReg32(@intFromEnum(Reg32.ecx)))) return .ecx;
    if (!cmpReg(t.final.regs.edx, t.final_mask.edx, cpu.st.getReg32(@intFromEnum(Reg32.edx)))) return .edx;
    if (!cmpReg(t.final.regs.esi, t.final_mask.esi, cpu.st.getReg32(@intFromEnum(Reg32.esi)))) return .esi;
    if (!cmpReg(t.final.regs.edi, t.final_mask.edi, cpu.st.getReg32(@intFromEnum(Reg32.edi)))) return .edi;
    if (!cmpReg(t.final.regs.ebp, t.final_mask.ebp, cpu.st.getReg32(@intFromEnum(Reg32.ebp)))) return .ebp;
    if (!cmpReg(t.final.regs.esp, t.final_mask.esp, cpu.st.getReg32(@intFromEnum(Reg32.esp)))) return .esp;
    if (!cmpReg(t.final.regs.eip, t.final_mask.eip, cpu.st.eip)) return .eip;
    if (!cmpReg16(t.final.regs.cs, cpu.readSegSelector(.cs))) return .cs;
    if (!cmpReg16(t.final.regs.ds, cpu.readSegSelector(.ds))) return .ds;
    if (!cmpReg16(t.final.regs.es, cpu.readSegSelector(.es))) return .es;
    if (!cmpReg16(t.final.regs.ss, cpu.readSegSelector(.ss))) return .ss;
    if (!cmpReg16(t.final.regs.fs, cpu.readSegSelector(.fs))) return .fs;
    if (!cmpReg16(t.final.regs.gs, cpu.readSegSelector(.gs))) return .gs;
    if (t.final.regs.eflags) |want| {
        // Compare only EFLAGS bits the 386 architecturally defines. Bits 18-31
        // do not exist on the 386 (AC is 486+, the rest are reserved); the
        // vectors capture them as 1s (raw-register reads), so they MUST be
        // masked out — they are not real flag state (D9 / determinism #5). Then
        // additionally ignore bits the vector author marked undefined (RM32) and
        // the per-opcode undefined-EFLAGS mask from 80386.csv f_umask (D9).
        const ignore: u32 = ~EFLAGS_386_VALID | (t.final_mask.eflags orelse 0) | ropts.undef_eflags;
        if ((cpu.st.eflags.toU32() & ~ignore) != (want & ~ignore)) return .eflags;
    }
    // Compare final memory bytes.
    for (t.final.ram) |e| {
        if (bus.readByte(e.addr) != e.value) return .memory;
    }
    return .none;
}

fn cmpReg(want: ?u32, mask: ?u32, got: u32) bool {
    const w = want orelse return true;
    const m = mask orelse 0;
    return (got & ~m) == (w & ~m);
}
fn cmpReg16(want: ?u32, got: u16) bool {
    const w = want orelse return true;
    return got == @as(u16, @truncate(w));
}

/// Run every test in a decompressed MOO byte buffer; report pass/fail counts.
pub fn runMooBytes(allocator: std.mem.Allocator, data: []const u8) !struct { pass: usize, fail: usize } {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tests = try parseMoo(arena, data);
    var pass: usize = 0;
    var fail: usize = 0;
    for (tests) |t| {
        if (try runOne(allocator, t)) pass += 1 else fail += 1;
    }
    return .{ .pass = pass, .fail = fail };
}

// ---------------------------------------------------------------------------
// 80386.csv undefined-EFLAGS table (D9) + revocation list, and the full
// directory sweep over the vendored gzipped MOO vectors.
//
// Design (cited): this mirrors the spice86 conformance harness — a per-opcode
// undefined-EFLAGS mask (their UndefinedFlagsTable.cs / 80386.csv) plus a
// revocation list of known-bad vectors (their RevocationListHelper.cs). We
// re-implement the *design* in Zig from the public-domain 80386.csv data; no
// spice86/DOSBox code is copied.
// ---------------------------------------------------------------------------

/// EFLAGS bit positions used to translate the CSV `o..szapc` letter columns.
/// Letters (high→low in the CSV string): o d i t s z - a - p - c, but the CSV
/// uses the compact 8-char "o..szapc" arithmetic-flag set. We instead use the
/// ready-made `f_umask` hex column (the compare-mask) directly — it already
/// encodes which EFLAGS bits are defined for the opcode.
///
/// `f_umask` semantics: a 1 bit = "this EFLAGS bit IS defined, compare it";
/// a 0 bit = "undefined for this opcode, ignore it". So the zdos *ignore* mask
/// is `~f_umask` restricted to the real arithmetic EFLAGS bits.
pub const ARITH_FLAGS: u32 = 0x0000_08D5; // CF PF AF ZF SF OF

/// Map: CSV opcode key string (e.g. "90", "0FAF", "F7/7") -> undefined-EFLAGS
/// ignore mask. Built once from 80386.csv.
pub const UndefTable = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *UndefTable, a: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.map.deinit(a);
    }

    /// Look up the undefined (ignore) mask for an opcode key + optional reg.
    pub fn lookup(self: *const UndefTable, op_key: []const u8, reg: ?u8) u32 {
        if (reg) |r| {
            var buf: [16]u8 = undefined;
            const k = std.fmt.bufPrint(&buf, "{s}/{d}", .{ op_key, r }) catch return 0;
            if (self.map.get(k)) |m| return m;
        }
        return self.map.get(op_key) orelse 0;
    }
};

/// Parse 80386.csv into the per-opcode undefined-EFLAGS ignore table.
pub fn parseCsv(a: std.mem.Allocator, csv: []const u8) !UndefTable {
    var table = UndefTable{};
    errdefer table.deinit(a);
    var lines = std.mem.splitScalar(u8, csv, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Columns: 1=op .. 5=ex(reg) .. 40=f_umask (1-indexed).
        var fields: [44][]const u8 = @splat("");
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |f| {
            if (n < fields.len) fields[n] = f;
            n += 1;
        }
        if (n < 40) continue;
        const op = std.mem.trim(u8, fields[0], " \r");
        const reg_s = std.mem.trim(u8, fields[4], " \r");
        const umask_s = std.mem.trim(u8, fields[39], " \r");
        if (op.len == 0) continue;
        // f_umask: a defined-bits compare mask (e.g. "0xFFEF"). If absent, all
        // arithmetic flags are defined for this opcode (ignore nothing).
        var ignore: u32 = 0;
        if (umask_s.len != 0) {
            const compare = parseHex(umask_s) orelse 0;
            ignore = (~compare) & ARITH_FLAGS;
        }
        if (ignore == 0) continue; // nothing to record
        var keybuf: [16]u8 = undefined;
        const key = if (reg_s.len != 0)
            std.fmt.bufPrint(&keybuf, "{s}/{s}", .{ op, reg_s }) catch continue
        else
            op;
        const owned = try a.dupe(u8, key);
        const gop = try table.map.getOrPut(a, owned);
        if (gop.found_existing) {
            a.free(owned);
            // OR masks if multiple rows share a key (group sub-encodings).
            gop.value_ptr.* |= ignore;
        } else {
            gop.value_ptr.* = ignore;
        }
    }
    // Merge the documented undefined-flag supplements (CSV gaps, D9).
    for (undef_supplement) |s| {
        const owned = try a.dupe(u8, s.key);
        const gop = try table.map.getOrPut(a, owned);
        if (gop.found_existing) {
            a.free(owned);
            gop.value_ptr.* |= s.ignore;
        } else {
            gop.value_ptr.* = s.ignore;
        }
    }
    return table;
}

/// Supplement the CSV with documented undefined-EFLAGS ignore masks for opcodes
/// whose 80386.csv flag columns are EMPTY but which the Intel 386 PRM lists as
/// leaving flags undefined. Each entry is a justified D9 known-divergence (the
/// vectors capture the 386's specific undefined values, for which there is no
/// portable oracle — DOSBox itself leaves these flags `t_UNKNOWN`). We compare
/// only the architecturally-DEFINED flag(s); the undefined bits are ignored.
///
/// `ignore` masks (EFLAGS bit positions): CF=0 PF=2 AF=4 ZF=6 SF=7 OF=11.
const undef_supplement = [_]struct { key: []const u8, ignore: u32 }{
    // BSF/BSR: only ZF is defined; CF/PF/AF/SF/OF undefined (PRM; DOSBox leaves
    // them unknown). ignore = all arith flags except ZF.
    .{ .key = "0FBC", .ignore = ARITH_FLAGS & ~@as(u32, 0x40) },
    .{ .key = "0FBD", .ignore = ARITH_FLAGS & ~@as(u32, 0x40) },
    // IMUL r,r/m (0F AF): like the other IMUL forms — only CF/OF defined;
    // SF/ZF/AF/PF undefined (matches 0x69/0x6B f_umask=0xFF2B).
    .{ .key = "0FAF", .ignore = (~@as(u32, 0xFF2B)) & ARITH_FLAGS },
    // SHLD/SHRD: AF undefined always; OF undefined for shift counts != 1
    // (PRM). The vectors exercise arbitrary counts, so OF is treated undefined.
    .{ .key = "0FA4", .ignore = 0x10 | 0x800 }, // AF | OF
    .{ .key = "0FA5", .ignore = 0x10 | 0x800 },
    .{ .key = "0FAC", .ignore = 0x10 | 0x800 },
    .{ .key = "0FAD", .ignore = 0x10 | 0x800 },
    // BT/BTS/BTR/BTC: only CF is defined; OF/SF/ZF/AF/PF undefined (PRM).
    .{ .key = "0FA3", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FAB", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FB3", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FBB", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FBA/4", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FBA/5", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FBA/6", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
    .{ .key = "0FBA/7", .ignore = ARITH_FLAGS & ~@as(u32, 0x01) },
};

fn parseHex(s: []const u8) ?u32 {
    const body = if (s.len >= 2 and (s[1] == 'x' or s[1] == 'X')) s[2..] else s;
    return std.fmt.parseInt(u32, body, 16) catch null;
}

/// The revocation set: hashes (as raw bytes) of known-bad vectors to skip.
pub const Revocations = struct {
    set: std.AutoHashMapUnmanaged([16]u8, void) = .empty,
    pub fn deinit(self: *Revocations, a: std.mem.Allocator) void {
        self.set.deinit(a);
    }
    pub fn contains(self: *const Revocations, h: [16]u8) bool {
        return self.set.contains(h);
    }
};

/// Parse revocation_list.txt (one hex hash per non-comment line).
pub fn parseRevocations(a: std.mem.Allocator, txt: []const u8) !Revocations {
    var rev = Revocations{};
    errdefer rev.deinit(a);
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var h: [16]u8 = @splat(0);
        // Accept a 32-hex-char MD5-style hash; ignore malformed lines.
        if (line.len < 32) continue;
        var ok = true;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            h[i] = std.fmt.parseInt(u8, line[i * 2 ..][0..2], 16) catch {
                ok = false;
                break;
            };
        }
        if (ok) try rev.set.put(a, h, {});
    }
    return rev;
}

/// Decompress a gzip buffer into an arena-owned slice.
pub fn gunzip(a: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .gzip, &dbuf);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    var list = out.toArrayList();
    return list.toOwnedSlice(a);
}

/// Translate a vector filename stem (e.g. "6766F7.7", "660FAF", "90") into the
/// CSV opcode key + optional group reg. Strips 66/67 size-prefix bytes (they do
/// not change the undefined-flag set), keeps a leading 0F two-byte map prefix.
pub const OpKey = struct { op: []const u8, reg: ?u8 };

pub fn fileNameToOpKey(stem: []const u8) OpKey {
    var s = stem;
    // Split off ".reg" group suffix.
    var reg: ?u8 = null;
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
        const tail = s[dot + 1 ..];
        if (tail.len <= 2) {
            if (std.fmt.parseInt(u8, tail, 10) catch null) |r| {
                reg = r;
                s = s[0..dot];
            }
        }
    }
    // Strip leading 66 / 67 size-prefix byte pairs.
    while (s.len >= 4 and (std.mem.eql(u8, s[0..2], "66") or std.mem.eql(u8, s[0..2], "67"))) {
        s = s[2..];
    }
    return .{ .op = s, .reg = reg };
}

/// Result of running one MOO file (one opcode).
pub const FileResult = struct {
    pass: usize = 0,
    fail: usize = 0,
    revoked: usize = 0,
    first_fail_name: [64]u8 = @splat(0),
    first_fail_field: Mismatch = .none,
};

/// Run every vector in a (decompressed) MOO buffer for one opcode file.
pub fn runMooFile(
    allocator: std.mem.Allocator,
    data: []const u8,
    undef_mask: u32,
    rev: *const Revocations,
) !FileResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tests = try parseMoo(arena, data);
    var res = FileResult{};
    for (tests) |t| {
        if (rev.contains(t.hash)) {
            res.revoked += 1;
            continue;
        }
        const m = try runOneDetail(allocator, t, .{ .undef_eflags = undef_mask });
        if (m == .none) {
            res.pass += 1;
        } else {
            if (res.fail == 0) {
                res.first_fail_field = m;
                const n = @min(t.name.len, res.first_fail_name.len - 1);
                @memcpy(res.first_fail_name[0..n], t.name[0..n]);
            }
            res.fail += 1;
        }
    }
    return res;
}

pub const SweepTotals = struct {
    files: usize = 0,
    pass: usize = 0,
    fail: usize = 0,
    revoked: usize = 0,
    failing_opcodes: usize = 0,
};

/// Run the full conformance sweep over the vendored directory. `print` controls
/// whether per-failing-opcode lines are written to stderr.
pub fn runDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    print: bool,
) !SweepTotals {
    // Load support files.
    const base = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    var bd = base;
    defer bd.close(io);

    const csv = try bd.readFileAlloc(io, "80386.csv", allocator, .limited(1 << 24));
    defer allocator.free(csv);
    var undef = try parseCsv(allocator, csv);
    defer undef.deinit(allocator);

    const revtxt = bd.readFileAlloc(io, "revocation_list.txt", allocator, .limited(1 << 20)) catch &.{};
    defer if (revtxt.len != 0) allocator.free(revtxt);
    var rev = try parseRevocations(allocator, revtxt);
    defer rev.deinit(allocator);

    var vdir = try bd.openDir(io, "v1_ex_real_mode", .{ .iterate = true });
    defer vdir.close(io);

    var totals = SweepTotals{};
    var it = vdir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".MOO.gz")) continue;
        const stem = entry.name[0 .. entry.name.len - ".MOO.gz".len];
        const key = fileNameToOpKey(stem);
        const undef_mask = undef.lookup(key.op, key.reg);

        const gz = try vdir.readFileAlloc(io, entry.name, allocator, .limited(1 << 26));
        defer allocator.free(gz);
        const data = try gunzip(allocator, gz);
        defer allocator.free(data);

        const r = try runMooFile(allocator, data, undef_mask, &rev);
        totals.files += 1;
        totals.pass += r.pass;
        totals.fail += r.fail;
        totals.revoked += r.revoked;
        if (r.fail != 0) {
            totals.failing_opcodes += 1;
            if (print) {
                const name = std.mem.sliceTo(&r.first_fail_name, 0);
                std.debug.print(
                    "FAIL {s}: {d}/{d} pass, {d} fail (e.g. '{s}' field={s})\n",
                    .{ stem, r.pass, r.pass + r.fail, r.fail, name, @tagName(r.first_fail_field) },
                );
            }
        }
    }
    return totals;
}

// ---------------------------------------------------------------------------
// Self-tests: build MOO bytes IN MEMORY and run them. These prove the parser +
// runner are correct end-to-end. They are NOT conformance results (no vendored
// data) — they are harness self-tests, clearly labeled (ground rule).
// ---------------------------------------------------------------------------

const MooBuilder = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn putId(self: *MooBuilder, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }
    fn putU32(self: *MooBuilder, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.a, &b);
    }
    fn putU16(self: *MooBuilder, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.a, &b);
    }
};

/// Build a chunk: TYPE + len + body.
fn chunk(a: std.mem.Allocator, ty: []const u8, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, ty);
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, @intCast(body.len), .little);
    try out.appendSlice(a, &lb);
    try out.appendSlice(a, body);
    return out.toOwnedSlice(a);
}

fn rg32Chunk(a: std.mem.Allocator, pairs: []const struct { idx: u5, val: u32 }) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var mask: u32 = 0;
    for (pairs) |p| mask |= (@as(u32, 1) << p.idx);
    var mb: [4]u8 = undefined;
    std.mem.writeInt(u32, &mb, mask, .little);
    try body.appendSlice(a, &mb);
    // Values must be in ascending bit order.
    var i: u5 = 0;
    while (true) : (i += 1) {
        for (pairs) |p| {
            if (p.idx == i) {
                var vb: [4]u8 = undefined;
                std.mem.writeInt(u32, &vb, p.val, .little);
                try body.appendSlice(a, &vb);
            }
        }
        if (i == 19) break;
    }
    return chunk(a, "RG32", try body.toOwnedSlice(a));
}

fn ramChunk(a: std.mem.Allocator, entries: []const RamEntry) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var cb: [4]u8 = undefined;
    std.mem.writeInt(u32, &cb, @intCast(entries.len), .little);
    try body.appendSlice(a, &cb);
    for (entries) |e| {
        var ab: [4]u8 = undefined;
        std.mem.writeInt(u32, &ab, e.addr, .little);
        try body.appendSlice(a, &ab);
        try body.append(a, e.value);
    }
    return chunk(a, "RAM ", try body.toOwnedSlice(a));
}

test "MOO parser + runner: synthetic INC AX test passes (harness self-test)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = arena.allocator();

    // RG32 bit indices: eax=2, cs=10, ss=15, eip=16, eflags=17, esp=9.
    const init_regs = try rg32Chunk(z, &.{
        .{ .idx = 2, .val = 0x0000_0004 }, // eax = 4
        .{ .idx = 9, .val = 0x0000_1000 }, // esp
        .{ .idx = 10, .val = 0 }, // cs = 0
        .{ .idx = 15, .val = 0 }, // ss = 0
        .{ .idx = 16, .val = 0x0000_2000 }, // eip
        .{ .idx = 17, .val = 0x0000_0002 }, // eflags
    });
    // RAM: code at 0x2000 = INC AX (0x40), then HALT (0xF4).
    const init_ram = try ramChunk(z, &.{
        .{ .addr = 0x2000, .value = 0x40 },
        .{ .addr = 0x2001, .value = 0xF4 },
    });
    const init_chunk = try chunk(z, "INIT", try std.mem.concat(z, u8, &.{ init_regs, init_ram }));

    // FINA: eax = 5; eip is past the HALT terminator. MOO convention: the final
    // state is captured once the HALT (0xF4 at 0x2001) has been fetched and the
    // CPU is halted, so eip = 0x2002 (one past the HALT byte).
    const fina_regs = try rg32Chunk(z, &.{
        .{ .idx = 2, .val = 0x0000_0005 }, // eax = 5
        .{ .idx = 16, .val = 0x0000_2002 }, // eip past the HALT
    });
    const fina_chunk = try chunk(z, "FINA", fina_regs);

    const name = try chunk(z, "NAME", &[_]u8{ 3, 0, 0, 0, 'i', 'n', 'c' });
    const byts = try chunk(z, "BYTS", &[_]u8{ 1, 0, 0, 0, 0x40 });

    // TEST chunk: index(4) + subchunks.
    var test_body: std.ArrayList(u8) = .empty;
    try test_body.appendSlice(z, &[_]u8{ 0, 0, 0, 0 }); // index
    try test_body.appendSlice(z, name);
    try test_body.appendSlice(z, byts);
    try test_body.appendSlice(z, init_chunk);
    try test_body.appendSlice(z, fina_chunk);
    const test_chunk = try chunk(z, "TEST", try test_body.toOwnedSlice(z));

    // File: "MOO " + hdr(len, payload) + TEST.
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(z, "MOO ");
    const moo_payload = [_]u8{ 1, 1, 0, 0, 1, 0, 0, 0, '3', '8', '6', 'E' };
    var pl: [4]u8 = undefined;
    std.mem.writeInt(u32, &pl, moo_payload.len, .little);
    try file.appendSlice(z, &pl);
    try file.appendSlice(z, &moo_payload);
    try file.appendSlice(z, test_chunk);

    const result = try runMooBytes(a, file.items);
    try std.testing.expectEqual(@as(usize, 1), result.pass);
    try std.testing.expectEqual(@as(usize, 0), result.fail);
}

test "MOO parser rejects bad magic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadMagic, parseMoo(arena.allocator(), "NOPE\x00\x00\x00\x00"));
}
