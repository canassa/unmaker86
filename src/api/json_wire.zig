//! The JSON wire format (M2 §C): pure serialize/parse helpers over the M1 shared
//! types. NO threads, NO sockets, NO machine access — this file is a pure mapping.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - Serialize: `std.json.Stringify.value(v, options, writer)`
//!     (`json/Stringify.zig:573`) into a fixed `std.Io.Writer` (`Io/Writer.zig:125`
//!     `fixed`), with `.{ .emit_nonportable_numbers_as_strings = true }`
//!     (`Stringify.zig:567`) so the `u64` `cycles`/`at_cycle` fields emit as base-10
//!     JSON strings when > 2^53 (R6: a lossy JS client cannot then produce a false
//!     golden pass). Tagged unions serialize as `{"<tag>": payload}`, void payloads
//!     as `{}` (`Stringify.zig:419-446`).
//!   - Parse: `std.json.parseFromSliceLeaky(T, arena.allocator(), body, opts)`
//!     (`json/static.zig:88`) over a per-request `ArenaAllocator` reset
//!     `.retain_capacity` — NOT `parseFromSlice`, which allocs a fresh arena per
//!     call (`static.zig:108`). The CALLER copies scalars + hex-decoded bytes into
//!     the `Command` POD before the next arena reset, so nothing borrowed escapes.
//!
//! Determinism: no host time, no RNG, no floats, no pointer/host-time fields in any
//! wire struct. Enforced by the §D grep + reflection audit in `determinism_test.zig`.

const std = @import("std");
const debug = @import("debug");
const cpu_mod = @import("cpu");

const Flags = cpu_mod.Flags;
const BreakpointKind = debug.BreakpointKind;

/// The single serialization option set for every response: emit `u64` cycle
/// fields > 2^53 as base-10 JSON strings (R6). Everything else is decimal/bool.
pub const stringify_options: std.json.Stringify.Options = .{
    .emit_nonportable_numbers_as_strings = true,
};

/// Parse option set for every request: tolerate extra fields a future client may
/// send (the server only reads the fields it knows), never alloc a fresh arena.
pub const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

// ===========================================================================
// Request structs (client → server). Parsed via `parseFromSliceLeaky`.
// ===========================================================================

/// `POST /api/run` — `cycle_cap` optional; absent maps to a documented large
/// default (NEVER unbounded) at the handler.
pub const RunReq = struct { cycle_cap: ?u64 = null };
pub const RunToCycleReq = struct { cycle: u64 };
pub const RunToAddrReq = struct { linear: u32 };
pub const StepNReq = struct { n: u64 };

/// `POST /api/breakpoints` — `kind` is the discriminated `BreakpointKind`
/// (`{"execution_address":{"linear":N}}`, etc.); parsed by std.json's default
/// tagged-union decoding. `io` parses but the handler rejects it (501).
pub const AddBpReq = struct { kind: BreakpointKind, one_shot: bool = false };
pub const EnableBpReq = struct { enabled: bool };

/// `POST /api/load` — all fields default to the server-held startup recipe when
/// omitted (so `POST /api/load {}` after a reset re-loads the original program).
pub const LoadReq = struct {
    drive: ?u8 = null,
    file: ?[]const u8 = null,
    cmdtail: ?[]const u8 = null,
};

pub const MemPeekReq = struct { phys: u32, len: u32 };
pub const MemWriteReq = struct { phys: u32, data: []const u8 };
pub const MemPeekSegReq = struct { seg: []const u8, off: u32, len: u32 };
pub const MemWriteSegReq = struct { seg: []const u8, off: u32, data: []const u8 };
pub const IvtReq = struct { vector: u8 };
pub const StackReq = struct { count: u16 };

/// `POST /api/input/key` — inject a keyboard key (input-injection.md §5.1e). Two
/// request shapes (§5.1):
///   - precise: `{"scancode": N, "make": true|false, "ext": false}` — push the raw
///     set-1 scancode (make) or break (`code|0x80`), with the 0xE0 prefix when
///     `ext`, then raise IRQ1.
///   - convenience: `{"char": "a"}` — the handler resolves the char to its make
///     scancode + shift requirement over the REAL set-1 table (scancodes.zig), not
///     a fabricated map; a char with no single set-1 key is a `400`.
/// At most one of `scancode`/`char` is given. `make` defaults true (key-down).
pub const KeyReq = struct {
    scancode: ?u8 = null,
    make: bool = true,
    ext: bool = false,
    char: ?[]const u8 = null,
};

/// `PATCH /api/cpu/reg` — a single valid `std.json` tagged union (§B.4/G2). One
/// key names which thing to set; its payload carries the target name + value. The
/// `flags` arm is the SAME 13-bool object `cpuSnapshot` emits (symmetric read/write).
pub const RegSetReq = union(enum) {
    reg32: NamedVal,
    reg16: NamedVal,
    reg8: NamedVal,
    seg: NamedVal,
    eip: struct { value: u32 },
    flags: FlagsPayload,

    /// A register/segment target name + the value to set. `value` is carried as a
    /// `u32` and range-checked to the register width at the handler (`400` if it
    /// overflows, e.g. 256 for a `reg8`).
    pub const NamedVal = struct { name: []const u8, value: u32 };
};

/// The 13-bool flags object — field order per `src/cpu/flags.zig:11`
/// (`cf,pf,af,zf,sf,df,of,iff,tf,nt,rf,vm,ac`). Symmetric with `CpuSnapshot`'s
/// flag fields (§B.4/G1).
pub const FlagsPayload = struct {
    cf: bool = false,
    pf: bool = false,
    af: bool = false,
    zf: bool = false,
    sf: bool = false,
    df: bool = false,
    of: bool = false,
    iff: bool = false,
    tf: bool = false,
    nt: bool = false,
    rf: bool = false,
    vm: bool = false,
    ac: bool = false,

    /// Build a `cpu.Flags` FIELD-BY-FIELD from the 13 bools (no `fromU32`, no
    /// controller/cpu change — §B.4/G1). The reserved bits keep their packed-struct
    /// defaults (bit1=1, the rest 0).
    pub fn toFlags(self: FlagsPayload) Flags {
        return .{
            .cf = self.cf,
            .pf = self.pf,
            .af = self.af,
            .zf = self.zf,
            .sf = self.sf,
            .df = self.df,
            .of = self.of,
            .iff = self.iff,
            .tf = self.tf,
            .nt = self.nt,
            .rf = self.rf,
            .vm = self.vm,
            .ac = self.ac,
        };
    }
};

// ===========================================================================
// Response structs (server → client).
// ===========================================================================

/// A list entry / single-breakpoint response: the core `Breakpoint{kind,enabled,
/// one_shot}` PLUS the injected `id` (the slot index, from `forEachBreakpoint`),
/// so a list entry is self-identifying (§C.3). Field order is fixed → golden-stable.
pub const WireBreakpoint = struct {
    id: u32,
    kind: BreakpointKind,
    enabled: bool,
    one_shot: bool,
};

/// The one error shape for all failures (§B.8). `code` is a stable string; the
/// `code → HTTP status` mapping lives ONLY in `server.zig` (D20).
pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

// ===========================================================================
// Serialize helpers — write into a caller-provided fixed buffer (no alloc on the
// response path). Return the written slice. `error.WriteFailed` if it overflows.
// ===========================================================================

pub const SerializeError = std.Io.Writer.Error;

/// Serialize any value with the project response options into `buf`; returns the
/// written prefix. Used for `StopReason`/`CpuSnapshot`/`WireBreakpoint`/`Region`/
/// `ErrorBody` and the small `{"ok":true}`-style wrapper structs.
pub fn serialize(buf: []u8, v: anytype) SerializeError![]u8 {
    var w = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(v, stringify_options, &w);
    return w.buffered();
}

// ===========================================================================
// Hex encode / decode for `data` fields (§C.1). Lowercase hex, even length.
// ===========================================================================

pub const HexError = error{ OddLength, InvalidHexDigit, BufferTooSmall };

/// Decode a lowercase/uppercase hex string into `out`; returns the decoded prefix.
/// Rejects odd length and non-hex digits (→ `400 bad_request` at the handler).
pub fn hexDecode(out: []u8, hex: []const u8) HexError![]u8 {
    if (hex.len % 2 != 0) return error.OddLength;
    const n = hex.len / 2;
    if (n > out.len) return error.BufferTooSmall;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        out[i] = (@as(u8, hi) << 4) | lo;
    }
    return out[0..n];
}

fn hexNibble(c: u8) HexError!u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHexDigit,
    };
}

const hex_digits = "0123456789abcdef";

/// Encode `bytes` as lowercase hex into `out`; returns the written prefix.
pub fn hexEncode(out: []u8, bytes: []const u8) error{BufferTooSmall}![]u8 {
    if (out.len < bytes.len * 2) return error.BufferTooSmall;
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_digits[b >> 4];
        out[i * 2 + 1] = hex_digits[b & 0xf];
    }
    return out[0 .. bytes.len * 2];
}
