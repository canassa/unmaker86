//! Decode-only 386 real-mode disassembler (plans/disassembler.md).
//!
//! This is a PURE, side-effect-free pass: it never executes, never reads live
//! registers, never advances EIP, never charges a cycle, never raises a fault.
//! It reuses the CPU's pure decode front-end (`decode.zig`'s `OperandSize`,
//! `AddrSize`, `resolveSizes`, `rm16`) so prefix/size handling can never drift
//! from the executor, and owns a NEW operand-shape table for the back half
//! (mnemonic + operand descriptors), which is the only intentional duplication
//! of a fact (the Intel encoding) — pinned by the conformance length cross-check
//! and the comptime coverage test.
//!
//! Determinism: length is computed purely from the byte stream. An unreadable /
//! out-of-range byte (`read` returns null) is rendered as data (`db`), never a
//! block or a fake. Unknown opcodes render `db 0xNN` (length 1) — never a
//! fabricated mnemonic (ground rule).

const std = @import("std");
const decode = @import("decode.zig");
const state = @import("state.zig");
const Seg = state.Seg;
const OperandSize = decode.OperandSize;
const AddrSize = decode.AddrSize;

/// 386 maximum instruction length (#GP if exceeded). The walker never reads past
/// this many bytes for one instruction.
pub const MAX_INSTR_LEN: u8 = 15;

/// The result of decoding ONE instruction.
pub const Insn = struct {
    /// Total bytes consumed (1..15). Always >= 1 so a walker always advances.
    len: u8,
    /// The rendered Intel-syntax text, a slice into the caller's `out_text`.
    text: []const u8,
};

// ===========================================================================
// Register / segment name tables — indexed EXACTLY by the CPU's encodings
// (Reg32 / Seg in state.zig, the 8-bit AL..BH order in State.getReg8).
// ===========================================================================

const reg8_names = [8][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh" };
const reg16_names = [8][]const u8{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di" };
const reg32_names = [8][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
/// Seg index order matches `state.Seg` (es,cs,ss,ds,fs,gs).
const seg_names = [6][]const u8{ "es", "cs", "ss", "ds", "fs", "gs" };
/// The MOV-to/from-seg `reg`-field order (0=ES,1=CS,2=SS,3=DS,4=FS,5=GS), per
/// `exec_data.segFromReg`.
const seg_reg_field = [8]?[]const u8{ "es", "cs", "ss", "ds", "fs", "gs", null, null };
const cr_names = [8][]const u8{ "cr0", "cr1", "cr2", "cr3", "cr4", "cr5", "cr6", "cr7" };
const dr_names = [8][]const u8{ "dr0", "dr1", "dr2", "dr3", "dr4", "dr5", "dr6", "dr7" };

/// The 16 Jcc / SETcc condition mnemonic suffixes, indexed by the low nibble of
/// the opcode (0x70+cc, 0x0F 0x80+cc, 0x0F 0x90+cc).
const cc_suffix = [16][]const u8{
    "o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g",
};

// ===========================================================================
// A tiny fixed-buffer writer so rendering never allocates and overflow is just
// a truncation (the text buffer is sized for the longest real-mode insn).
// ===========================================================================

const Out = struct {
    buf: []u8,
    n: usize = 0,

    fn str(self: *Out, s: []const u8) void {
        const room = self.buf.len - self.n;
        const k = @min(room, s.len);
        @memcpy(self.buf[self.n .. self.n + k], s[0..k]);
        self.n += k;
    }
    fn ch(self: *Out, c: u8) void {
        if (self.n < self.buf.len) {
            self.buf[self.n] = c;
            self.n += 1;
        }
    }
    /// Print `0x<hex>` (lowercase, no leading zeros beyond one digit) for an
    /// unsigned value already truncated to its operand width.
    fn hex(self: *Out, v: u64) void {
        self.str("0x");
        var tmp: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{x}", .{v}) catch return;
        self.str(s);
    }
    /// Print a signed displacement as `+0xN` / `-0xN`.
    fn signedDisp(self: *Out, d: i64) void {
        if (d < 0) {
            self.ch('-');
            self.hex(@intCast(-d));
        } else {
            self.ch('+');
            self.hex(@intCast(d));
        }
    }
    fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.n];
    }
};

// ===========================================================================
// The byte reader — wraps the caller's byte SOURCE (any value with a
// `read(off: u32) ?u8` method) and tracks length so the renderer cannot read
// past MAX_INSTR_LEN. A read that returns null marks the stream truncated; the
// decoder then bails to a `db` of the lead byte. Using a `.read()` METHOD (not a
// bare fn) lets the source capture state (a peeked buffer, a bus + base) — Zig
// has no bound-method values, so a closure-style `fn` can't carry context.
// ===========================================================================

fn Reader(comptime Source: type) type {
    return struct {
        src: Source,
        base: u32,
        len: u8 = 0,
        truncated: bool = false,
        /// Set when an opcode has no table entry: the caller falls back to a
        /// `db 0x<lead>` of length 1 so the walker advances one byte and can
        /// re-decode the rest (a stray prefix byte may begin a valid insn).
        bad: bool = false,

        const Self = @This();

        /// Fetch the next byte, advancing length. Sets `truncated` and returns 0
        /// on an unreadable byte or a length-limit overrun.
        fn next(self: *Self) u8 {
            if (self.len >= MAX_INSTR_LEN) {
                self.truncated = true;
                return 0;
            }
            const off = self.base +% self.len;
            const b = self.src.read(off) orelse {
                self.truncated = true;
                return 0;
            };
            self.len += 1;
            return b;
        }
        fn next16(self: *Self) u16 {
            const lo = self.next();
            const hi = self.next();
            return @as(u16, lo) | (@as(u16, hi) << 8);
        }
        fn next32(self: *Self) u32 {
            const lo = self.next16();
            const hi = self.next16();
            return @as(u32, lo) | (@as(u32, hi) << 16);
        }
    };
}

// ===========================================================================
// Decode state — the front-end facts mirrored from `dispatch.executeOne`, plus
// the rendering scratch (segment override, the ModR/M fields).
// ===========================================================================

const D = struct {
    seg_override: ?Seg = null,
    has_66: bool = false,
    has_67: bool = false,
    rep: bool = false, // F3
    repne: bool = false, // F2
    lock: bool = false,
    op_size: OperandSize = .b16,
    addr_size: AddrSize = .a16,
    is_0F: bool = false,
    opcode: u8 = 0,

    // ModR/M (filled lazily by readModRM).
    have_modrm: bool = false,
    mod: u2 = 0,
    reg: u3 = 0,
    rm: u3 = 0,
};

// ===========================================================================
// Operand descriptors — the "shape" half of the table. Each opcode maps to a
// mnemonic plus up to three operands; the renderer consumes the right bytes.
// ===========================================================================

const Op = enum {
    none,
    /// r/m operand at operand size (decodes ModR/M).
    Ev,
    /// r/m operand, byte.
    Eb,
    /// r/m operand, word (forced 16-bit regardless of op size, e.g. seg loads).
    Ew,
    /// r/m operand, dword (forced 32-bit regardless of op size, e.g. the GP
    /// register in MOV to/from CR/DR — always reg-direct, always 32-bit).
    Ed,
    /// reg-field register at operand size.
    Gv,
    /// reg-field register, byte.
    Gb,
    /// reg-field as a segment register.
    Sw,
    /// reg-field as a control register.
    Cd,
    /// reg-field as a debug register.
    Dd,
    /// immediate at operand size (16 or 32).
    Iv,
    /// immediate byte.
    Ib,
    /// immediate word (always 16-bit).
    Iw,
    /// signed immediate byte (rendered with sign; used by IMUL/PUSH imm8).
    Ibs,
    /// rel8 branch target.
    Jb,
    /// rel at operand size (rel16/rel32) branch target.
    Jv,
    /// ptr16:16 / ptr16:32 far pointer (direct far JMP/CALL).
    Ap,
    /// memory offset moffs (direct address by addr size), into AL/AX/EAX side.
    Ob,
    Ov,
    /// implied AL / AX-or-eAX / DX / CL / 1.
    AL,
    eAX,
    DX,
    CL,
    one,
    /// a fixed register by index (for XCHG eAX,reg etc.) — index in `imm` slot.
    fixedV,
    fixedB,
};

const Shape = struct {
    mn: []const u8,
    a: Op = .none,
    b: Op = .none,
    c: Op = .none,
    /// For `fixedV`/`fixedB` operands: the register index. Also reused as a
    /// flag bit (size-hint) by a couple of entries; documented at the use site.
    fixed_reg: u3 = 0,
};

// ===========================================================================
// decodeOne — the public entry. Decode ONE instruction at `base_off`.
// `read` is `fn(off: u32) ?u8`. `cs_big` is false in real mode.
// ===========================================================================

pub fn decodeOne(read: anytype, base_off: u32, cs_big: bool, out_text: []u8) Insn {
    var r = Reader(@TypeOf(read)){ .src = read, .base = base_off };
    var o = Out{ .buf = out_text };
    var d = D{};

    // --- Prefix scan (exact byte set from dispatch.executeOne) ---
    var op = r.next();
    while (!r.truncated) {
        switch (op) {
            0x2E => d.seg_override = .cs,
            0x36 => d.seg_override = .ss,
            0x3E => d.seg_override = .ds,
            0x26 => d.seg_override = .es,
            0x64 => d.seg_override = .fs,
            0x65 => d.seg_override = .gs,
            0x66 => d.has_66 = true,
            0x67 => d.has_67 = true,
            0xF0 => d.lock = true,
            0xF2 => d.repne = true,
            0xF3 => d.rep = true,
            else => break,
        }
        op = r.next();
    }
    if (r.truncated) return dbLead(read, base_off, &o);

    // --- Two-byte opcode map ---
    if (op == 0x0F) {
        d.is_0F = true;
        op = r.next();
        if (r.truncated) return dbLead(read, base_off, &o);
    }
    d.opcode = op;

    // --- Resolve sizes (shared with the executor) ---
    var dd = decode.Decoded{ .has_66 = d.has_66, .has_67 = d.has_67 };
    decode.resolveSizes(&dd, cs_big);
    d.op_size = dd.op_size;
    d.addr_size = dd.addr_size;

    // --- Render prefixes that print as leading tokens (rep/repne/lock) ---
    // The segment override is folded into the memory operand, not a token.
    renderRepLockPrefix(&d, op, &o);

    // --- Dispatch to the shape table + render ---
    renderInsn(&r, &o, &d);

    if (r.truncated or r.bad) {
        // A truncated/over-long encoding or an undecodable opcode: fall back to a
        // `db` of the lead byte so the walker advances by exactly one byte and can
        // re-decode the rest (never fabricates a mnemonic — ground rule).
        return dbLead(read, base_off, &o);
    }
    return .{ .len = r.len, .text = o.slice() };
}

/// Render `db 0x<lead>` for a single byte (the universal "could not decode /
/// truncated" fallback). Length is always 1.
fn dbLead(read: anytype, base_off: u32, o: *Out) Insn {
    o.n = 0;
    const b = read.read(base_off) orelse 0;
    o.str("db ");
    o.hex(b);
    return .{ .len = 1, .text = o.slice() };
}

/// REP/REPNE apply only to string ops; LOCK to RMW ops. We render the token
/// whenever the prefix byte is present (matching common debugger output). For
/// string ops F3=rep, F2=repne; we keep the raw token names rep/repne.
fn renderRepLockPrefix(d: *const D, op: u8, o: *Out) void {
    if (d.lock) o.str("lock ");
    // rep/repne are only meaningful on string ops (A4-A7, AA-AF, 6C-6F); on
    // other opcodes F2/F3 are mandatory/other prefixes — don't print a token.
    const is_string = (!d.is_0F) and switch (op) {
        0xA4...0xA7, 0xAA...0xAF, 0x6C...0x6F => true,
        else => false,
    };
    if (is_string) {
        if (d.rep) o.str("rep ");
        if (d.repne) o.str("repne ");
    }
}

// ===========================================================================
// ModR/M decode (length + symbolic operand). Mirrors the byte-consumption of
// dispatch.decodeMem16 / decodeMem32 but renders the SYMBOLIC form and ignores
// register contents. Fills d.{mod,reg,rm}; renders the rm operand into a small
// scratch via `renderRM`.
// ===========================================================================

fn readModRM(r: anytype, d: *D) void {
    const m = r.next();
    d.have_modrm = true;
    d.mod = @truncate(m >> 6);
    d.reg = @truncate(m >> 3);
    d.rm = @truncate(m);
}

/// Render the rm operand at the given width (.reg => register name; .mem =>
/// the symbolic effective address). Consumes the SIB/disp bytes from `r`.
fn renderRM(r: anytype, o: *Out, d: *D, width: enum { b8, b16, b32, seg }) void {
    if (!d.have_modrm) readModRM(r, d);
    if (d.mod == 0b11) {
        // Register direct.
        switch (width) {
            .b8 => o.str(reg8_names[d.rm]),
            .b16 => o.str(reg16_names[d.rm]),
            .b32 => o.str(reg32_names[d.rm]),
            .seg => o.str(reg16_names[d.rm]),
        }
        return;
    }
    // Memory: render `[seg:base+index*scale+disp]`. Segment override printed only
    // when present (default segment omitted — common debugger style).
    if (d.seg_override) |s| {
        o.str(seg_names[@intFromEnum(s)]);
        o.ch(':');
    }
    if (d.addr_size == .a16) {
        renderMem16(r, o, d);
    } else {
        renderMem32(r, o, d);
    }
}

fn renderMem16(r: anytype, o: *Out, d: *D) void {
    o.ch('[');
    if (d.mod == 0 and d.rm == 6) {
        // disp16 direct.
        const disp = r.next16();
        o.hex(disp);
        o.ch(']');
        return;
    }
    const t = decode.rm16(d.rm);
    var wrote = false;
    if (t.base_reg) |b| {
        o.str(reg16_names[b]);
        wrote = true;
    }
    if (t.index_reg) |ix| {
        if (wrote) o.ch('+');
        o.str(reg16_names[ix]);
        wrote = true;
    }
    switch (d.mod) {
        0 => {},
        1 => {
            const disp: i8 = @bitCast(r.next());
            o.signedDisp(disp);
        },
        2 => {
            const disp: i16 = @bitCast(r.next16());
            o.signedDisp(disp);
        },
        3 => unreachable,
    }
    o.ch(']');
}

fn renderMem32(r: anytype, o: *Out, d: *D) void {
    o.ch('[');
    if (d.rm == 4) {
        // SIB byte.
        const sib = r.next();
        const scale_shift: u2 = @truncate(sib >> 6);
        const index: u3 = @truncate(sib >> 3);
        const base: u3 = @truncate(sib);
        if (base == 5 and d.mod == 0) {
            // disp32, no base; index applies.
            const disp = r.next32();
            if (index != 4) {
                o.str(reg32_names[index]);
                emitScale(o, scale_shift);
                o.ch('+');
            }
            o.hex(disp);
            o.ch(']');
            return;
        }
        o.str(reg32_names[base]);
        if (index != 4) {
            o.ch('+');
            o.str(reg32_names[index]);
            emitScale(o, scale_shift);
        }
    } else if (d.mod == 0 and d.rm == 5) {
        // disp32 direct.
        const disp = r.next32();
        o.hex(disp);
        o.ch(']');
        return;
    } else {
        o.str(reg32_names[d.rm]);
    }
    switch (d.mod) {
        0 => {},
        1 => {
            const disp: i8 = @bitCast(r.next());
            o.signedDisp(disp);
        },
        2 => {
            const disp: i32 = @bitCast(r.next32());
            o.signedDisp(disp);
        },
        3 => unreachable,
    }
    o.ch(']');
}

fn emitScale(o: *Out, scale_shift: u2) void {
    if (scale_shift == 0) return;
    o.ch('*');
    o.ch('0' + (@as(u8, 1) << scale_shift));
}

// ===========================================================================
// Operand rendering — given an `Op` descriptor, consume the bytes + render.
// ModR/M-bearing operands (Ev/Eb/Ew/Gv/Gb/Sw/Cd/Dd) trigger the single ModR/M
// read; the renderer must order so the ModR/M is read before any trailing imm.
// ===========================================================================

fn opWidth(d: *const D) enum { b16, b32 } {
    return if (d.op_size == .b32) .b32 else .b16;
}

fn regvName(d: *const D, idx: u3) []const u8 {
    return if (d.op_size == .b32) reg32_names[idx] else reg16_names[idx];
}

/// Does this operand need the ModR/M byte? (Used to read it exactly once,
/// up front, so reg-then-rm ordering and trailing-immediate widths are correct.)
fn needsModRM(op: Op) bool {
    return switch (op) {
        .Ev, .Eb, .Ew, .Ed, .Gv, .Gb, .Sw, .Cd, .Dd => true,
        else => false,
    };
}

fn renderOperand(r: anytype, o: *Out, d: *D, op: Op, fixed_reg: u3, ip_after: u32) void {
    switch (op) {
        .none => {},
        .Ev => renderRM(r, o, d, if (d.op_size == .b32) .b32 else .b16),
        .Eb => renderRM(r, o, d, .b8),
        .Ew => renderRM(r, o, d, .seg),
        .Ed => renderRM(r, o, d, .b32),
        .Gv => o.str(regvName(d, d.reg)),
        .Gb => o.str(reg8_names[d.reg]),
        .Sw => o.str(seg_reg_field[d.reg] orelse "?seg"),
        .Cd => o.str(cr_names[d.reg]),
        .Dd => o.str(dr_names[d.reg]),
        .Iv => {
            if (d.op_size == .b32) o.hex(r.next32()) else o.hex(r.next16());
        },
        .Ib => o.hex(r.next()),
        .Iw => o.hex(r.next16()),
        .Ibs => {
            const v: i8 = @bitCast(r.next());
            // Render sign-extended to operand width as a plain hex value.
            if (v < 0) {
                o.ch('-');
                o.hex(@as(u64, @intCast(-@as(i16, v))));
            } else {
                o.hex(@as(u64, @intCast(v)));
            }
        },
        .Jb => {
            const rel: i8 = @bitCast(r.next());
            const target = ipAfterFull(ip_after, r) +% @as(u32, @bitCast(@as(i32, rel)));
            o.hex(maskIp(d, target));
        },
        .Jv => {
            const rel: i32 = if (d.op_size == .b32) @bitCast(r.next32()) else @as(i32, @as(i16, @bitCast(r.next16())));
            const target = ipAfterFull(ip_after, r) +% @as(u32, @bitCast(rel));
            o.hex(maskIp(d, target));
        },
        .Ap => {
            // ptr16:16 or ptr16:32 — offset then selector.
            const off: u32 = if (d.op_size == .b32) r.next32() else r.next16();
            const sel = r.next16();
            o.hex(sel);
            o.ch(':');
            o.hex(off);
        },
        .Ob => renderMoffs(r, o, d),
        .Ov => renderMoffs(r, o, d),
        .AL => o.str("al"),
        .eAX => o.str(if (d.op_size == .b32) "eax" else "ax"),
        .DX => o.str("dx"),
        .CL => o.str("cl"),
        .one => o.ch('1'),
        .fixedV => o.str(regvName(d, fixed_reg)),
        .fixedB => o.str(reg8_names[fixed_reg]),
    }
}

/// moffs direct memory address — `[seg:disp]` (addr-size displacement).
fn renderMoffs(r: anytype, o: *Out, d: *D) void {
    if (d.seg_override) |s| {
        o.str(seg_names[@intFromEnum(s)]);
        o.ch(':');
    }
    o.ch('[');
    if (d.addr_size == .a32) o.hex(r.next32()) else o.hex(r.next16());
    o.ch(']');
}

/// The absolute (linear-within-segment) address just past the FULL instruction,
/// used as the base for relative branch targets. At render time we know
/// `base_off` and the running length, but rel targets are computed against the
/// instruction END — so the caller passes `base_off` and we add the final
/// length. We can't know the final length until the imm is consumed, but a rel
/// operand is always LAST, so length-at-this-point == final length.
fn ipAfterFull(base_off: u32, r: anytype) u32 {
    return base_off +% r.len;
}

/// Mask a branch target to the effective instruction-pointer width (16-bit in
/// real mode unless a 32-bit operand size applies to a near branch).
fn maskIp(d: *const D, target: u32) u32 {
    return if (d.op_size == .b32) target else (target & 0xFFFF);
}

// ===========================================================================
// renderInsn — the dispatcher. Looks up the shape, reads ModR/M once (if any
// operand needs it), then renders operands in order. Special-cased families
// (groups, no-FPU ESC, the implicit-operand ops) are handled inline where the
// shape table cannot express them.
// ===========================================================================

fn renderInsn(r: anytype, o: *Out, d: *D) void {
    if (d.is_0F) {
        renderTwoByte(r, o, d);
    } else {
        renderOneByte(r, o, d);
    }
}

/// Emit the mnemonic, a space, then up to three operands separated by `, `.
fn emit(r: anytype, o: *Out, d: *D, sh: Shape) void {
    // A leading size-hint for ambiguous mem-immediate forms is handled by the
    // caller via a wrapper; here we just render mnemonic + operands.
    o.str(sh.mn);
    // Read the ModR/M up front if any operand needs it (so reg/rm + trailing
    // imm ordering is correct).
    const ip_base = r.base;
    if ((needsModRM(sh.a) or needsModRM(sh.b) or needsModRM(sh.c)) and !d.have_modrm) {
        readModRM(r, d);
    }
    var first = true;
    inline for (.{ sh.a, sh.b, sh.c }) |opnd| {
        if (opnd != .none) {
            if (first) o.ch(' ') else o.str(", ");
            first = false;
            renderOperand(r, o, d, opnd, sh.fixed_reg, ip_base);
        }
    }
}

/// Like `emit` but prefixes a `byte`/`word`/`dword` size hint when the
/// destination is a MEMORY operand (size is otherwise ambiguous, e.g. Grp1
/// imm-to-mem, Grp3 TEST/NOT, shifts, INC/DEC). Reads the ModR/M first to know.
fn emitSized(r: anytype, o: *Out, d: *D, sh: Shape, byte_width: bool) void {
    o.str(sh.mn);
    if (!d.have_modrm) readModRM(r, d);
    const is_mem = (d.mod != 0b11);
    o.ch(' ');
    if (is_mem) {
        if (byte_width) {
            o.str("byte ");
        } else if (d.op_size == .b32) {
            o.str("dword ");
        } else {
            o.str("word ");
        }
    }
    const ip_base = r.base;
    var first = true;
    inline for (.{ sh.a, sh.b, sh.c }) |opnd| {
        if (opnd != .none) {
            if (!first) o.str(", ");
            first = false;
            renderOperand(r, o, d, opnd, sh.fixed_reg, ip_base);
        }
    }
}

// ---------------------------------------------------------------------------
// One-byte opcode rendering.
// ---------------------------------------------------------------------------

/// ALU primary mnemonics indexed by (op >> 3) & 7 for the 0x00..0x3F block.
const alu_mn = [8][]const u8{ "add", "or", "adc", "sbb", "and", "sub", "xor", "cmp" };
const grp1_mn = alu_mn; // Grp1 (0x80-0x83) reuses ADD..CMP by reg field.
const grp2_mn = [8][]const u8{ "rol", "ror", "rcl", "rcr", "shl", "shr", "sal", "sar" };

fn renderOneByte(r: anytype, o: *Out, d: *D) void {
    const op = d.opcode;
    switch (op) {
        // ---- ALU r/m,reg / reg,r/m / AL,imm / eAX,imm (0x00-0x3D) ----
        0x00...0x05, 0x08...0x0D, 0x10...0x15, 0x18...0x1D, 0x20...0x25, 0x28...0x2D, 0x30...0x35, 0x38...0x3D => {
            const mn = alu_mn[(op >> 3) & 7];
            switch (op & 7) {
                0 => emit(r, o, d, .{ .mn = mn, .a = .Eb, .b = .Gb }),
                1 => emit(r, o, d, .{ .mn = mn, .a = .Ev, .b = .Gv }),
                2 => emit(r, o, d, .{ .mn = mn, .a = .Gb, .b = .Eb }),
                3 => emit(r, o, d, .{ .mn = mn, .a = .Gv, .b = .Ev }),
                4 => emit(r, o, d, .{ .mn = mn, .a = .AL, .b = .Ib }),
                5 => emit(r, o, d, .{ .mn = mn, .a = .eAX, .b = .Iv }),
                else => unreachable,
            }
        },

        // ---- INC/DEC reg (0x40-0x4F) ----
        0x40...0x47 => emit(r, o, d, .{ .mn = "inc", .a = .fixedV, .fixed_reg = @truncate(op - 0x40) }),
        0x48...0x4F => emit(r, o, d, .{ .mn = "dec", .a = .fixedV, .fixed_reg = @truncate(op - 0x48) }),

        // ---- PUSH/POP reg (0x50-0x5F) ----
        0x50...0x57 => emit(r, o, d, .{ .mn = "push", .a = .fixedV, .fixed_reg = @truncate(op - 0x50) }),
        0x58...0x5F => emit(r, o, d, .{ .mn = "pop", .a = .fixedV, .fixed_reg = @truncate(op - 0x58) }),

        // ---- PUSH/POP segment ----
        0x06 => emit(r, o, d, .{ .mn = "push es" }),
        0x07 => emit(r, o, d, .{ .mn = "pop es" }),
        0x0E => emit(r, o, d, .{ .mn = "push cs" }),
        0x16 => emit(r, o, d, .{ .mn = "push ss" }),
        0x17 => emit(r, o, d, .{ .mn = "pop ss" }),
        0x1E => emit(r, o, d, .{ .mn = "push ds" }),
        0x1F => emit(r, o, d, .{ .mn = "pop ds" }),

        // ---- BCD / segment-prefix (prefixes already consumed) ----
        0x27 => o.str("daa"),
        0x2F => o.str("das"),
        0x37 => o.str("aaa"),
        0x3F => o.str("aas"),

        // ---- PUSHA / POPA ----
        0x60 => o.str(if (d.op_size == .b32) "pushad" else "pusha"),
        0x61 => o.str(if (d.op_size == .b32) "popad" else "popa"),

        // ---- BOUND / ARPL / PUSH imm / IMUL imm / INS / OUTS ----
        0x62 => emit(r, o, d, .{ .mn = "bound", .a = .Gv, .b = .Ev }),
        0x63 => emit(r, o, d, .{ .mn = "arpl", .a = .Ew, .b = .Gv }),
        0x68 => emit(r, o, d, .{ .mn = "push", .a = .Iv }),
        0x69 => emit(r, o, d, .{ .mn = "imul", .a = .Gv, .b = .Ev, .c = .Iv }),
        0x6A => emit(r, o, d, .{ .mn = "push", .a = .Ibs }),
        0x6B => emit(r, o, d, .{ .mn = "imul", .a = .Gv, .b = .Ev, .c = .Ibs }),
        0x6C => o.str("insb"),
        0x6D => o.str(if (d.op_size == .b32) "insd" else "insw"),
        0x6E => o.str("outsb"),
        0x6F => o.str(if (d.op_size == .b32) "outsd" else "outsw"),

        // ---- Jcc rel8 ----
        0x70...0x7F => {
            var buf: [4]u8 = undefined;
            const mn = std.fmt.bufPrint(&buf, "j{s}", .{cc_suffix[op - 0x70]}) catch "j?";
            emit(r, o, d, .{ .mn = mn, .a = .Jb });
        },

        // ---- Grp1 0x80-0x83 (ADD..CMP imm to r/m) ----
        0x80 => emitSized(r, o, d, .{ .mn = grp1ByReg(r, d), .a = .Eb, .b = .Ib }, true),
        0x81 => emitSized(r, o, d, .{ .mn = grp1ByReg(r, d), .a = .Ev, .b = .Iv }, false),
        0x82 => emitSized(r, o, d, .{ .mn = grp1ByReg(r, d), .a = .Eb, .b = .Ib }, true),
        0x83 => emitSized(r, o, d, .{ .mn = grp1ByReg(r, d), .a = .Ev, .b = .Ibs }, false),

        // ---- TEST / XCHG r/m,reg ----
        0x84 => emit(r, o, d, .{ .mn = "test", .a = .Eb, .b = .Gb }),
        0x85 => emit(r, o, d, .{ .mn = "test", .a = .Ev, .b = .Gv }),
        0x86 => emit(r, o, d, .{ .mn = "xchg", .a = .Eb, .b = .Gb }),
        0x87 => emit(r, o, d, .{ .mn = "xchg", .a = .Ev, .b = .Gv }),

        // ---- MOV ----
        0x88 => emit(r, o, d, .{ .mn = "mov", .a = .Eb, .b = .Gb }),
        0x89 => emit(r, o, d, .{ .mn = "mov", .a = .Ev, .b = .Gv }),
        0x8A => emit(r, o, d, .{ .mn = "mov", .a = .Gb, .b = .Eb }),
        0x8B => emit(r, o, d, .{ .mn = "mov", .a = .Gv, .b = .Ev }),
        0x8C => emit(r, o, d, .{ .mn = "mov", .a = .Ew, .b = .Sw }),
        0x8D => emit(r, o, d, .{ .mn = "lea", .a = .Gv, .b = .Ev }),
        0x8E => emit(r, o, d, .{ .mn = "mov", .a = .Sw, .b = .Ew }),
        0x8F => emitSized(r, o, d, .{ .mn = "pop", .a = .Ev }, false),

        0x90 => o.str("nop"),
        0x91...0x97 => emit(r, o, d, .{ .mn = "xchg", .a = .eAX, .b = .fixedV, .fixed_reg = @truncate(op - 0x90) }),

        0x98 => o.str(if (d.op_size == .b32) "cwde" else "cbw"),
        0x99 => o.str(if (d.op_size == .b32) "cdq" else "cwd"),
        0x9A => emit(r, o, d, .{ .mn = "call far", .a = .Ap }),
        0x9B => o.str("wait"),
        0x9C => o.str(if (d.op_size == .b32) "pushfd" else "pushf"),
        0x9D => o.str(if (d.op_size == .b32) "popfd" else "popf"),
        0x9E => o.str("sahf"),
        0x9F => o.str("lahf"),

        // ---- MOV moffs ----
        0xA0 => emit(r, o, d, .{ .mn = "mov", .a = .AL, .b = .Ob }),
        0xA1 => emit(r, o, d, .{ .mn = "mov", .a = .eAX, .b = .Ov }),
        0xA2 => emit(r, o, d, .{ .mn = "mov", .a = .Ob, .b = .AL }),
        0xA3 => emit(r, o, d, .{ .mn = "mov", .a = .Ov, .b = .eAX }),

        // ---- String ops ----
        0xA4 => o.str("movsb"),
        0xA5 => o.str(if (d.op_size == .b32) "movsd" else "movsw"),
        0xA6 => o.str("cmpsb"),
        0xA7 => o.str(if (d.op_size == .b32) "cmpsd" else "cmpsw"),
        0xA8 => emit(r, o, d, .{ .mn = "test", .a = .AL, .b = .Ib }),
        0xA9 => emit(r, o, d, .{ .mn = "test", .a = .eAX, .b = .Iv }),
        0xAA => o.str("stosb"),
        0xAB => o.str(if (d.op_size == .b32) "stosd" else "stosw"),
        0xAC => o.str("lodsb"),
        0xAD => o.str(if (d.op_size == .b32) "lodsd" else "lodsw"),
        0xAE => o.str("scasb"),
        0xAF => o.str(if (d.op_size == .b32) "scasd" else "scasw"),

        // ---- MOV reg, imm ----
        0xB0...0xB7 => emit(r, o, d, .{ .mn = "mov", .a = .fixedB, .b = .Ib, .fixed_reg = @truncate(op - 0xB0) }),
        0xB8...0xBF => emit(r, o, d, .{ .mn = "mov", .a = .fixedV, .b = .Iv, .fixed_reg = @truncate(op - 0xB8) }),

        // ---- Grp2 shifts ----
        0xC0 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Eb, .b = .Ib }, true),
        0xC1 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Ev, .b = .Ib }, false),
        0xD0 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Eb, .b = .one }, true),
        0xD1 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Ev, .b = .one }, false),
        0xD2 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Eb, .b = .CL }, true),
        0xD3 => emitSized(r, o, d, .{ .mn = grp2ByReg(r, d), .a = .Ev, .b = .CL }, false),

        // ---- RET near ----
        0xC2 => emit(r, o, d, .{ .mn = "ret", .a = .Iw }),
        0xC3 => o.str("ret"),

        // ---- LES / LDS ----
        0xC4 => emit(r, o, d, .{ .mn = "les", .a = .Gv, .b = .Ev }),
        0xC5 => emit(r, o, d, .{ .mn = "lds", .a = .Gv, .b = .Ev }),

        // ---- MOV r/m, imm (Grp11) ----
        0xC6 => emitSized(r, o, d, .{ .mn = "mov", .a = .Eb, .b = .Ib }, true),
        0xC7 => emitSized(r, o, d, .{ .mn = "mov", .a = .Ev, .b = .Iv }, false),

        // ---- ENTER / LEAVE ----
        0xC8 => emit(r, o, d, .{ .mn = "enter", .a = .Iw, .b = .Ib }),
        0xC9 => o.str("leave"),

        // ---- RET far / INT / IRET ----
        0xCA => emit(r, o, d, .{ .mn = "retf", .a = .Iw }),
        0xCB => o.str("retf"),
        0xCC => o.str("int3"),
        0xCD => emit(r, o, d, .{ .mn = "int", .a = .Ib }),
        0xCE => o.str("into"),
        0xCF => o.str(if (d.op_size == .b32) "iretd" else "iret"),

        // ---- AAM / AAD / SALC / XLAT ----
        0xD4 => emit(r, o, d, .{ .mn = "aam", .a = .Ib }),
        0xD5 => emit(r, o, d, .{ .mn = "aad", .a = .Ib }),
        0xD6 => o.str("salc"),
        0xD7 => o.str("xlat"),

        // ---- ESC (0xD8-0xDF): no FPU. Consume ModR/M for length; render honest. ----
        0xD8...0xDF => {
            readModRM(r, d);
            // Consume any SIB/disp by rendering into a throwaway region of the
            // output (we then overwrite with the honest marker).
            var scratch: [32]u8 = undefined;
            var so = Out{ .buf = &scratch };
            renderRM(r, &so, d, .b32);
            o.str("(no-fpu) esc ");
            o.hex(d.opcode);
        },

        // ---- LOOP / JCXZ ----
        0xE0 => emit(r, o, d, .{ .mn = "loopne", .a = .Jb }),
        0xE1 => emit(r, o, d, .{ .mn = "loope", .a = .Jb }),
        0xE2 => emit(r, o, d, .{ .mn = "loop", .a = .Jb }),
        0xE3 => emit(r, o, d, .{ .mn = if (d.addr_size == .a32) "jecxz" else "jcxz", .a = .Jb }),

        // ---- IN/OUT imm8 ----
        0xE4 => emit(r, o, d, .{ .mn = "in", .a = .AL, .b = .Ib }),
        0xE5 => emit(r, o, d, .{ .mn = "in", .a = .eAX, .b = .Ib }),
        0xE6 => emit(r, o, d, .{ .mn = "out", .a = .Ib, .b = .AL }),
        0xE7 => emit(r, o, d, .{ .mn = "out", .a = .Ib, .b = .eAX }),

        // ---- CALL/JMP rel, far JMP, JMP rel8 ----
        0xE8 => emit(r, o, d, .{ .mn = "call", .a = .Jv }),
        0xE9 => emit(r, o, d, .{ .mn = "jmp", .a = .Jv }),
        0xEA => emit(r, o, d, .{ .mn = "jmp far", .a = .Ap }),
        0xEB => emit(r, o, d, .{ .mn = "jmp", .a = .Jb }),

        // ---- IN/OUT DX ----
        0xEC => emit(r, o, d, .{ .mn = "in", .a = .AL, .b = .DX }),
        0xED => emit(r, o, d, .{ .mn = "in", .a = .eAX, .b = .DX }),
        0xEE => emit(r, o, d, .{ .mn = "out", .a = .DX, .b = .AL }),
        0xEF => emit(r, o, d, .{ .mn = "out", .a = .DX, .b = .eAX }),

        // ---- misc / Grp3 / Grp4 / Grp5 / flag ops ----
        0xF1 => o.str("icebp"),
        0xF4 => o.str("hlt"),
        0xF5 => o.str("cmc"),
        0xF6 => renderGrp3(r, o, d, true),
        0xF7 => renderGrp3(r, o, d, false),
        0xF8 => o.str("clc"),
        0xF9 => o.str("stc"),
        0xFA => o.str("cli"),
        0xFB => o.str("sti"),
        0xFC => o.str("cld"),
        0xFD => o.str("std"),
        0xFE => renderGrp4(r, o, d),
        0xFF => renderGrp5(r, o, d),

        else => renderDbOpcode(r, o, d),
    }
}

fn grp1ByReg(r: anytype, d: *D) []const u8 {
    if (!d.have_modrm) readModRM(r, d);
    return grp1_mn[d.reg];
}
fn grp2ByReg(r: anytype, d: *D) []const u8 {
    if (!d.have_modrm) readModRM(r, d);
    return grp2_mn[d.reg];
}

/// Grp3 (0xF6/0xF7): TEST/TEST/NOT/NEG/MUL/IMUL/DIV/IDIV by reg field. TEST(0/1)
/// takes an immediate; the rest take only the r/m operand.
fn renderGrp3(r: anytype, o: *Out, d: *D, byte: bool) void {
    if (!d.have_modrm) readModRM(r, d);
    const mn = switch (d.reg) {
        0, 1 => "test",
        2 => "not",
        3 => "neg",
        4 => "mul",
        5 => "imul",
        6 => "div",
        7 => "idiv",
    };
    switch (d.reg) {
        0, 1 => if (byte)
            emitSized(r, o, d, .{ .mn = mn, .a = .Eb, .b = .Ib }, true)
        else
            emitSized(r, o, d, .{ .mn = mn, .a = .Ev, .b = .Iv }, false),
        else => if (byte)
            emitSized(r, o, d, .{ .mn = mn, .a = .Eb }, true)
        else
            emitSized(r, o, d, .{ .mn = mn, .a = .Ev }, false),
    }
}

/// Grp4 (0xFE): INC/DEC r/m8.
fn renderGrp4(r: anytype, o: *Out, d: *D) void {
    if (!d.have_modrm) readModRM(r, d);
    switch (d.reg) {
        0 => emitSized(r, o, d, .{ .mn = "inc", .a = .Eb }, true),
        1 => emitSized(r, o, d, .{ .mn = "dec", .a = .Eb }, true),
        else => renderDbOpcode(r, o, d),
    }
}

/// Grp5 (0xFF): INC/DEC r/m, CALL/CALLF/JMP/JMPF r/m, PUSH r/m.
fn renderGrp5(r: anytype, o: *Out, d: *D) void {
    if (!d.have_modrm) readModRM(r, d);
    switch (d.reg) {
        0 => emitSized(r, o, d, .{ .mn = "inc", .a = .Ev }, false),
        1 => emitSized(r, o, d, .{ .mn = "dec", .a = .Ev }, false),
        2 => emitSized(r, o, d, .{ .mn = "call", .a = .Ev }, false),
        3 => emit(r, o, d, .{ .mn = "call far", .a = .Ev }), // m16:16/32 indirect
        4 => emitSized(r, o, d, .{ .mn = "jmp", .a = .Ev }, false),
        5 => emit(r, o, d, .{ .mn = "jmp far", .a = .Ev }),
        6 => emitSized(r, o, d, .{ .mn = "push", .a = .Ev }, false),
        7 => renderDbOpcode(r, o, d),
    }
}

// ---------------------------------------------------------------------------
// Two-byte (0F) opcode rendering.
// ---------------------------------------------------------------------------

fn renderTwoByte(r: anytype, o: *Out, d: *D) void {
    const op = d.opcode;
    switch (op) {
        0x00 => renderDbOpcode(r, o, d), // Grp6 (PM-only) -> #UD; render bytes honestly
        0x01 => renderGrp7(r, o, d), // Grp7
        0x02 => emit(r, o, d, .{ .mn = "lar", .a = .Gv, .b = .Ew }),
        0x03 => emit(r, o, d, .{ .mn = "lsl", .a = .Gv, .b = .Ew }),
        0x06 => o.str("clts"),
        0x08 => o.str("invd"),
        0x09 => o.str("wbinvd"),

        0x20 => emit(r, o, d, .{ .mn = "mov", .a = .Ed, .b = .Cd, .fixed_reg = 0 }),
        0x21 => emit(r, o, d, .{ .mn = "mov", .a = .Ed, .b = .Dd }),
        0x22 => emit(r, o, d, .{ .mn = "mov", .a = .Cd, .b = .Ed }),
        0x23 => emit(r, o, d, .{ .mn = "mov", .a = .Dd, .b = .Ed }),

        // ---- Jcc rel16/rel32 ----
        0x80...0x8F => {
            var buf: [4]u8 = undefined;
            const mn = std.fmt.bufPrint(&buf, "j{s}", .{cc_suffix[op - 0x80]}) catch "j?";
            emit(r, o, d, .{ .mn = mn, .a = .Jv });
        },
        // ---- SETcc r/m8 ----
        0x90...0x9F => {
            var buf: [6]u8 = undefined;
            const mn = std.fmt.bufPrint(&buf, "set{s}", .{cc_suffix[op - 0x90]}) catch "set?";
            emit(r, o, d, .{ .mn = mn, .a = .Eb });
        },

        0xA0 => o.str("push fs"),
        0xA1 => o.str("pop fs"),
        0xA3 => emit(r, o, d, .{ .mn = "bt", .a = .Ev, .b = .Gv }),
        0xA4 => emit(r, o, d, .{ .mn = "shld", .a = .Ev, .b = .Gv, .c = .Ib }),
        0xA5 => emit(r, o, d, .{ .mn = "shld", .a = .Ev, .b = .Gv, .c = .CL }),
        0xA8 => o.str("push gs"),
        0xA9 => o.str("pop gs"),
        0xAB => emit(r, o, d, .{ .mn = "bts", .a = .Ev, .b = .Gv }),
        0xAC => emit(r, o, d, .{ .mn = "shrd", .a = .Ev, .b = .Gv, .c = .Ib }),
        0xAD => emit(r, o, d, .{ .mn = "shrd", .a = .Ev, .b = .Gv, .c = .CL }),
        0xAF => emit(r, o, d, .{ .mn = "imul", .a = .Gv, .b = .Ev }),

        0xB2 => emit(r, o, d, .{ .mn = "lss", .a = .Gv, .b = .Ev }),
        0xB3 => emit(r, o, d, .{ .mn = "btr", .a = .Ev, .b = .Gv }),
        0xB4 => emit(r, o, d, .{ .mn = "lfs", .a = .Gv, .b = .Ev }),
        0xB5 => emit(r, o, d, .{ .mn = "lgs", .a = .Gv, .b = .Ev }),
        0xB6 => emit(r, o, d, .{ .mn = "movzx", .a = .Gv, .b = .Eb }),
        0xB7 => emit(r, o, d, .{ .mn = "movzx", .a = .Gv, .b = .Ew }),
        0xBA => renderGrp8(r, o, d),
        0xBB => emit(r, o, d, .{ .mn = "btc", .a = .Ev, .b = .Gv }),
        0xBC => emit(r, o, d, .{ .mn = "bsf", .a = .Gv, .b = .Ev }),
        0xBD => emit(r, o, d, .{ .mn = "bsr", .a = .Gv, .b = .Ev }),
        0xBE => emit(r, o, d, .{ .mn = "movsx", .a = .Gv, .b = .Eb }),
        0xBF => emit(r, o, d, .{ .mn = "movsx", .a = .Gv, .b = .Ew }),

        else => renderDbOpcode(r, o, d),
    }
}

/// Grp7 (0F 01): SGDT/SIDT/LGDT/LIDT/SMSW/LMSW (+ INVLPG) by reg field.
fn renderGrp7(r: anytype, o: *Out, d: *D) void {
    if (!d.have_modrm) readModRM(r, d);
    const mn = switch (d.reg) {
        0 => "sgdt",
        1 => "sidt",
        2 => "lgdt",
        3 => "lidt",
        4 => "smsw",
        6 => "lmsw",
        7 => "invlpg",
        else => null,
    };
    if (mn) |m| {
        // SMSW takes a word operand; the rest take a memory (m16:32 / m) operand.
        emit(r, o, d, .{ .mn = m, .a = if (d.reg == 4) .Ew else .Ev });
    } else {
        renderDbOpcode(r, o, d);
    }
}

/// Grp8 (0F BA): BT/BTS/BTR/BTC r/m, imm8 by reg field (4..7).
fn renderGrp8(r: anytype, o: *Out, d: *D) void {
    if (!d.have_modrm) readModRM(r, d);
    const mn = switch (d.reg) {
        4 => "bt",
        5 => "bts",
        6 => "btr",
        7 => "btc",
        else => null,
    };
    if (mn) |m| {
        emit(r, o, d, .{ .mn = m, .a = .Ev, .b = .Ib });
    } else {
        renderDbOpcode(r, o, d);
    }
}

/// Mark the instruction undecodable. `decodeOne` then falls back to a single
/// `db 0x<lead>` (length 1), so the walker advances one byte and re-decodes the
/// rest — never a fabricated mnemonic, and length never silently smears.
fn renderDbOpcode(r: anytype, o: *Out, d: *D) void {
    _ = o;
    _ = d;
    r.bad = true;
}

test {
    std.testing.refAllDecls(@This());
}
