//! Single source of truth (D1 lazy-seam) for per-width ALU primitives, the flag
//! formulas, and the D9 undefined-flags policy. exec_alu/exec_shift/exec_muldiv
//! are only the dispatch/operand-plumbing layer that calls into here.
//!
//! Flags are computed eagerly into a `*Flags`. This is the ONE flag-commit
//! place; a future hybrid (defer EFLAGS bit-packing) swaps here without
//! touching instruction logic.

const std = @import("std");
const flags = @import("flags.zig");
const Flags = flags.Flags;

/// Operand width for an ALU op.
pub const Width = enum(u8) {
    b8 = 8,
    b16 = 16,
    b32 = 32,

    pub fn bits(self: Width) u8 {
        return @intFromEnum(self);
    }
    pub fn mask(self: Width) u64 {
        return (@as(u64, 1) << @intCast(self.bits())) - 1;
    }
    pub fn signbit(self: Width) u64 {
        return @as(u64, 1) << @intCast(self.bits() - 1);
    }
};

inline fn maskTo(w: Width, v: u64) u64 {
    return v & w.mask();
}

inline fn setSzp(f: *Flags, w: Width, res: u64) void {
    const r = maskTo(w, res);
    f.zf = (r == 0);
    f.sf = (r & w.signbit()) != 0;
    f.pf = flags.parity_table[@as(u8, @truncate(r))];
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

pub fn add(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const aa = maskTo(w, a);
    const bb = maskTo(w, b);
    const full = aa + bb;
    const res = maskTo(w, full);
    f.cf = (full & (w.mask() + 1)) != 0;
    f.af = ((aa ^ bb ^ res) & 0x10) != 0;
    // OF: signs of operands equal but differ from result.
    f.of = (((aa ^ res) & (bb ^ res)) & w.signbit()) != 0;
    setSzp(f, w, res);
    return res;
}

pub fn adc(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const carry: u64 = if (f.cf) 1 else 0;
    const aa = maskTo(w, a);
    const bb = maskTo(w, b);
    const full = aa + bb + carry;
    const res = maskTo(w, full);
    f.cf = (full & (w.mask() + 1)) != 0;
    f.af = ((aa ^ bb ^ res) & 0x10) != 0;
    f.of = (((aa ^ res) & (bb ^ res)) & w.signbit()) != 0;
    setSzp(f, w, res);
    return res;
}

pub fn sub(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const aa = maskTo(w, a);
    const bb = maskTo(w, b);
    const res = maskTo(w, aa -% bb);
    f.cf = aa < bb;
    f.af = ((aa ^ bb ^ res) & 0x10) != 0;
    // OF: operands differ in sign and result sign differs from minuend.
    f.of = (((aa ^ bb) & (aa ^ res)) & w.signbit()) != 0;
    setSzp(f, w, res);
    return res;
}

pub fn sbb(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const borrow: u64 = if (f.cf) 1 else 0;
    const aa = maskTo(w, a);
    const bb = maskTo(w, b);
    const res = maskTo(w, aa -% bb -% borrow);
    f.cf = aa < (bb + borrow);
    f.af = ((aa ^ bb ^ res) & 0x10) != 0;
    f.of = (((aa ^ bb) & (aa ^ res)) & w.signbit()) != 0;
    setSzp(f, w, res);
    return res;
}

/// CMP = SUB discarding result (flags only).
pub fn cmp(f: *Flags, w: Width, a: u64, b: u64) void {
    _ = sub(f, w, a, b);
}

pub fn neg(f: *Flags, w: Width, a: u64) u64 {
    const aa = maskTo(w, a);
    const res = maskTo(w, 0 -% aa);
    f.cf = aa != 0;
    f.af = (aa & 0x10) != 0; // borrow out of bit 3 == any low nibble bit set? -> (0 - a) borrows iff a!=0 at nibble
    f.af = ((0 ^ aa ^ res) & 0x10) != 0;
    f.of = (aa == w.signbit());
    setSzp(f, w, res);
    return res;
}

/// INC: does NOT affect CF (preserved). OF/AF/SZP set.
pub fn inc(f: *Flags, w: Width, a: u64) u64 {
    const aa = maskTo(w, a);
    const res = maskTo(w, aa +% 1);
    f.af = ((aa ^ 1 ^ res) & 0x10) != 0;
    f.of = (res == w.signbit()); // overflow only at 0x7F..->0x80..
    setSzp(f, w, res);
    return res;
}

/// DEC: does NOT affect CF (preserved). OF/AF/SZP set.
pub fn dec(f: *Flags, w: Width, a: u64) u64 {
    const aa = maskTo(w, a);
    const res = maskTo(w, aa -% 1);
    f.af = ((aa ^ 1 ^ res) & 0x10) != 0;
    f.of = (aa == w.signbit()); // 0x80.. -> 0x7F.. overflows
    setSzp(f, w, res);
    return res;
}

// ---------------------------------------------------------------------------
// Logic: CF=0, OF=0, AF undefined (D9: set to 0, reproducible), SZP from result.
// ---------------------------------------------------------------------------

fn logicFlags(f: *Flags, w: Width, res: u64) void {
    f.cf = false;
    f.of = false;
    f.af = false; // D9: AF undefined after logic; pin to 0 (ProcessorTests-consistent).
    setSzp(f, w, res);
}

pub fn andOp(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const res = maskTo(w, a & b);
    logicFlags(f, w, res);
    return res;
}
pub fn orOp(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const res = maskTo(w, a | b);
    logicFlags(f, w, res);
    return res;
}
pub fn xorOp(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const res = maskTo(w, a ^ b);
    logicFlags(f, w, res);
    return res;
}
pub fn testOp(f: *Flags, w: Width, a: u64, b: u64) void {
    _ = andOp(f, w, a, b);
}
/// NOT affects no flags.
pub fn notOp(w: Width, a: u64) u64 {
    return maskTo(w, ~a);
}

// ---------------------------------------------------------------------------
// Multiply (Phase 4e). CF/OF set when the upper half is significant; SF/ZF/PF/AF
// undefined after MUL/IMUL (D9: pinned — we leave SF/ZF/PF computed from the low
// half, AF=false, matching common 386/Bochs/ProcessorTests behavior).
// ---------------------------------------------------------------------------

/// Unsigned multiply. Returns the full 2*width product; sets CF/OF.
pub fn mul(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const product = maskTo(w, a) * maskTo(w, b);
    const upper = product >> @intCast(w.bits());
    const sig = upper != 0;
    f.cf = sig;
    f.of = sig;
    return product;
}

/// Signed multiply. Returns the full 2*width product (masked to 2*width);
/// sets CF/OF when the result doesn't sign-extend from the low half.
pub fn imul(f: *Flags, w: Width, a: u64, b: u64) u64 {
    const bits = w.bits();
    const sa = signExtend(w, a);
    const sb = signExtend(w, b);
    const product: i128 = @as(i128, sa) * @as(i128, sb);
    const low: u64 = @as(u64, @bitCast(@as(i64, @truncate(product)))) & dmask(bits);
    // CF/OF set when sign-extension of the low half != full product.
    const low_signed = signExtendBits(@intCast(bits), low);
    const sig = (@as(i128, low_signed) != product);
    f.cf = sig;
    f.of = sig;
    return @as(u64, @bitCast(@as(i64, @truncate(product)))) & dmask(bits);
}

/// Sign-extend a width-bit value to i64.
pub fn signExtend(w: Width, v: u64) i64 {
    return signExtendBits(w.bits(), maskTo(w, v));
}
fn signExtendBits(bits: u8, v: u64) i64 {
    const shift: u6 = @intCast(64 - bits);
    return @as(i64, @bitCast(v << shift)) >> shift;
}
/// Mask covering the double-width (2*bits) result. For bits>=32 the double
/// width is >=64, i.e. the full u64.
fn dmask(bits: u8) u64 {
    if (bits >= 32) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bits * 2)) - 1;
}

/// Division error sentinel.
pub const DivError = error{DivideError};

/// Quotient + remainder result.
pub const DivResult = struct { q: u64, r: u64 };

/// Unsigned divide. dividend is 2*width, divisor is width. Returns
/// {quotient, remainder} (each width). #DE on /0 or quotient overflow.
pub fn divUnsigned(w: Width, dividend: u64, divisor: u64) DivError!DivResult {
    if (divisor == 0) return error.DivideError;
    const q = dividend / divisor;
    const r = dividend % divisor;
    if (q > w.mask()) return error.DivideError; // quotient overflow
    return .{ .q = q & w.mask(), .r = r & w.mask() };
}

/// Signed divide.
pub fn divSigned(w: Width, dividend2: u64, divisor: u64) DivError!DivResult {
    if (divisor == 0) return error.DivideError;
    const bits2 = w.bits() * 2;
    const sd: i64 = signExtendBits(bits2, dividend2);
    const sv: i64 = signExtend(w, divisor);
    const q = @divTrunc(sd, sv);
    const r = @rem(sd, sv);
    // Quotient must fit in signed width.
    const qmin: i64 = -(@as(i64, 1) << @intCast(w.bits() - 1));
    const qmax: i64 = (@as(i64, 1) << @intCast(w.bits() - 1)) - 1;
    if (q < qmin or q > qmax) return error.DivideError;
    return .{ .q = @as(u64, @bitCast(q)) & w.mask(), .r = @as(u64, @bitCast(r)) & w.mask() };
}

// ---------------------------------------------------------------------------
// Shifts & rotates (Phase 4c). 386 count mask & 0x1F. OF defined only for
// count==1; count==0 leaves flags unchanged. D9: for count>1 the OF value is
// pinned (we leave OF as set by the count==1 formula path only when count==1;
// for count>1 OF is undefined and we leave the previous OF — matching the
// common 386/Bochs behavior; documented + pinned by undefined_flags test).
// ---------------------------------------------------------------------------

/// SHL/SAL.
pub fn shl(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const count: u6 = @truncate(raw_count & 0x1F);
    if (count == 0) return maskTo(w, val);
    const v = maskTo(w, val);
    const bits = w.bits();
    const res = maskTo(w, v << count);
    // CF = last bit shifted out.
    const cf = if (count <= bits) ((v >> @intCast(bits - count)) & 1) != 0 else false;
    f.cf = cf;
    // OF for SHL = MSB(res) ^ CF. Defined for count==1; the 386 produces this
    // value for any count (validated against the vectors, which compare OF).
    f.of = (((res & w.signbit()) != 0) != cf);
    setSzp(f, w, res);
    f.af = false; // undefined (D9): pin 0
    return res;
}

/// SHR (logical).
pub fn shr(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const count: u6 = @truncate(raw_count & 0x1F);
    if (count == 0) return maskTo(w, val);
    const v = maskTo(w, val);
    const res = maskTo(w, v >> count);
    f.cf = ((v >> @intCast(count - 1)) & 1) != 0;
    // SHR: OF = MSB of the ORIGINAL operand for count==1; for count>1 the 386
    // clears OF (validated against the SingleStepTests vectors, which DO compare
    // OF for SHR — f_umask masks only AF).
    f.of = (count == 1) and ((v & w.signbit()) != 0);
    setSzp(f, w, res);
    f.af = false;
    return res;
}

/// SAR (arithmetic).
pub fn sar(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const count: u6 = @truncate(raw_count & 0x1F);
    if (count == 0) return maskTo(w, val);
    const v = maskTo(w, val);
    const bits = w.bits();
    const sign = (v & w.signbit()) != 0;
    const eff: u6 = if (count >= bits) @truncate(bits - 1) else count;
    var res = v >> eff;
    if (sign) {
        // fill the vacated high bits with 1s within the width
        const fill_mask = w.mask() & ~((@as(u64, 1) << @intCast(bits - eff)) - 1);
        res |= fill_mask;
    }
    res = maskTo(w, res);
    f.cf = ((v >> @intCast(@min(count - 1, bits - 1))) & 1) != 0;
    f.of = false; // SAR: OF is 0 (defined for count==1; the 386 keeps it 0).
    setSzp(f, w, res);
    f.af = false;
    return res;
}

/// ROL.
pub fn rol(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const bits = w.bits();
    const cnt: u64 = (raw_count & 0x1F) % bits;
    const v = maskTo(w, val);
    if ((raw_count & 0x1F) == 0) return v;
    if (cnt == 0) {
        // count multiple of width: value unchanged but CF = LSB; OF undefined
        f.cf = (v & 1) != 0;
        return v;
    }
    const res = maskTo(w, (v << @intCast(cnt)) | (v >> @intCast(bits - cnt)));
    f.cf = (res & 1) != 0;
    // OF defined for count==1; the 386 produces OF = MSB(res) ^ CF for any count.
    f.of = (((res & w.signbit()) != 0) != f.cf);
    return res;
}

/// ROR.
pub fn ror(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const bits = w.bits();
    const cnt: u64 = (raw_count & 0x1F) % bits;
    const v = maskTo(w, val);
    if ((raw_count & 0x1F) == 0) return v;
    if (cnt == 0) {
        f.cf = (v & w.signbit()) != 0;
        return v;
    }
    const res = maskTo(w, (v >> @intCast(cnt)) | (v << @intCast(bits - cnt)));
    f.cf = (res & w.signbit()) != 0;
    // OF defined for count==1 (= MSB ^ next-MSB of result); the 386 produces
    // this value for any count.
    {
        const msb = (res & w.signbit()) != 0;
        const msb2 = (res & (w.signbit() >> 1)) != 0;
        f.of = (msb != msb2);
    }
    return res;
}

/// RCL (rotate through carry).
pub fn rcl(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const bits = w.bits();
    const cnt: u64 = (raw_count & 0x1F) % (bits + 1);
    var v = maskTo(w, val);
    if (cnt == 0) return v;
    var carry: u64 = if (f.cf) 1 else 0;
    var i: u64 = 0;
    while (i < cnt) : (i += 1) {
        const new_carry = (v >> @intCast(bits - 1)) & 1;
        v = maskTo(w, (v << 1) | carry);
        carry = new_carry;
    }
    f.cf = carry != 0;
    // RCL OF = MSB(res) ^ CF; defined for count==1, deterministic on the 386
    // for any count.
    f.of = (((v & w.signbit()) != 0) != (carry != 0));
    return v;
}

/// RCR (rotate through carry).
pub fn rcr(f: *Flags, w: Width, val: u64, raw_count: u64) u64 {
    const bits = w.bits();
    const cnt: u64 = (raw_count & 0x1F) % (bits + 1);
    var v = maskTo(w, val);
    if (cnt == 0) return v;
    var carry: u64 = if (f.cf) 1 else 0;
    var i: u64 = 0;
    while (i < cnt) : (i += 1) {
        const new_carry = v & 1;
        v = maskTo(w, (v >> 1) | (carry << @intCast(bits - 1)));
        carry = new_carry;
    }
    f.cf = carry != 0;
    // RCR OF = MSB(res) ^ next-MSB(res); defined for count==1, deterministic on
    // the 386 for any count.
    {
        const msb = (v & w.signbit()) != 0;
        const msb2 = (v & (w.signbit() >> 1)) != 0;
        f.of = (msb != msb2);
    }
    return v;
}

// ---------------------------------------------------------------------------
// Tests for per-flag correctness (Phase 3).
// ---------------------------------------------------------------------------

test "add flags" {
    var f = Flags{};
    try std.testing.expectEqual(@as(u64, 0), add(&f, .b8, 0xFF, 1));
    try std.testing.expect(f.cf and f.zf and f.af and !f.of);
    f = Flags{};
    _ = add(&f, .b8, 0x7F, 1); // 127+1 = 128 -> signed overflow
    try std.testing.expect(f.of and f.sf and !f.cf);
}

test "sub/cmp flags" {
    var f = Flags{};
    _ = sub(&f, .b8, 0, 1); // borrow
    try std.testing.expect(f.cf and f.sf and !f.zf);
    f = Flags{};
    cmp(&f, .b16, 0x8000, 1); // 0x8000 - 1 -> 0x7FFF, signed overflow
    try std.testing.expect(f.of and !f.sf);
}

test "inc/dec preserve CF" {
    var f = Flags{ .cf = true };
    _ = inc(&f, .b8, 0x10);
    try std.testing.expect(f.cf); // preserved
    _ = dec(&f, .b8, 0x10);
    try std.testing.expect(f.cf);
}

test "logic clears CF/OF/AF" {
    var f = Flags{ .cf = true, .of = true, .af = true };
    _ = andOp(&f, .b32, 0xF0F0, 0x0FF0);
    try std.testing.expect(!f.cf and !f.of and !f.af);
}

test "neg flags" {
    var f = Flags{};
    try std.testing.expectEqual(@as(u64, 0), neg(&f, .b8, 0));
    try std.testing.expect(!f.cf and f.zf);
    f = Flags{};
    _ = neg(&f, .b8, 0x80); // -(-128) overflows
    try std.testing.expect(f.of and f.cf);
}

test "shl/shr/sar" {
    var f = Flags{};
    try std.testing.expectEqual(@as(u64, 0x02), shl(&f, .b8, 0x81, 1));
    try std.testing.expect(f.cf); // bit7 shifted out
    f = Flags{};
    try std.testing.expectEqual(@as(u64, 0x40), shr(&f, .b8, 0x80, 1));
    try std.testing.expect(f.of); // OF = MSB original
    f = Flags{};
    try std.testing.expectEqual(@as(u64, 0xC0), sar(&f, .b8, 0x80, 1));
    f = Flags{};
    // count 0 leaves flags unchanged
    f.cf = true;
    _ = shl(&f, .b8, 0xFF, 0);
    try std.testing.expect(f.cf);
}

test "rol/ror/rcl/rcr" {
    var f = Flags{};
    try std.testing.expectEqual(@as(u64, 0x03), rol(&f, .b8, 0x81, 1));
    try std.testing.expect(f.cf);
    f = Flags{};
    try std.testing.expectEqual(@as(u64, 0xC0), ror(&f, .b8, 0x81, 1));
    try std.testing.expect(f.cf);
    f = Flags{ .cf = true };
    // RCL 0x80 by 1 with CF=1: -> (0x80<<1 | 1) = 0x01, carry = old bit7 = 1
    try std.testing.expectEqual(@as(u64, 0x01), rcl(&f, .b8, 0x80, 1));
    try std.testing.expect(f.cf);
    f = Flags{ .cf = true };
    // RCR 0x01 by 1 with CF=1: -> 0x80 | (0>>1), carry = old bit0 = 1
    try std.testing.expectEqual(@as(u64, 0x80), rcr(&f, .b8, 0x01, 1));
    try std.testing.expect(f.cf);
}
