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
/// `POST /api/run/start` — both optional; absent keeps the pacer's current tuning
/// (so `start {}` re-arms with the prior `slice_cycles`/`fps`). Parsed at the handler
/// into the clockless `RunControl` atomics (the pacer reads them each loop).
pub const RunStartReq = struct { slice_cycles: ?u64 = null, fps: ?u32 = null };
pub const RunToAddrReq = struct { linear: u32 };
pub const StepNReq = struct { n: u64 };

/// `POST /api/cpu/clock` — the live CPU-speed knob (Phase 3). INTEGER fields only
/// (the determinism grep-gate bans host floats): `mult` is the CPU:PIT multiplier
/// (cpu_hz = PIT_TICK_RATE * mult); `mhz` is a convenience the handler converts to a
/// nearest-integer mult. Provide exactly one (both → 400). The handler validates
/// (reject 0) and the worker clamps to `[1, MAX_MULT]`.
pub const CpuSpeedReq = struct { mult: ?u64 = null, mhz: ?u64 = null };

/// `POST /api/breakpoints` — `kind` is the discriminated `BreakpointKind`
/// (`{"execution_address":{"linear":N}}`, etc.); parsed by std.json's default
/// tagged-union decoding. All five kinds (execution_address, cycle, interrupt,
/// memory, io) are live — the worker arms the bus memory/port watch for memory/io.
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

    // Optional dwell, in MILLISECONDS of EMULATED time, that turns the `char` keystroke
    // into a held TAP: inject the make (+ any Shift bracket), ADVANCE the machine by the
    // dwell's worth of cycles (the machine's OWN configured clock — `Controller.dwellCycles`),
    // then inject the break. ABSENT ⇒ today's behavior (make+break injected back-to-back,
    // cycle-neutral; the BIOS keystroke buffer makes that enough for nearly every guest).
    // PRESENT ⇒ the key is physically DOWN across the dwell, so a guest that LEVEL-SAMPLES
    // raw key state (tracks make/break in its own INT 09h handler) observes the hold;
    // `hold_ms:0` is make+break at the same cycle. ONLY valid for the `char` form (a full
    // keystroke); a raw single-edge `scancode` has no hold. INTEGER ONLY (determinism grep).
    hold_ms: ?u32 = null,
};

/// `POST /api/input/mouse` — inject a mouse event into the INT 33h driver
/// (input-injection.md §5.2, Phase 2). Absolute position and/or relative motion
/// and/or buttons; every field is optional, and a field is applied only when
/// present:
///   - `{"x": X, "y": Y}` — ABSOLUTE position, clamped to the live range like
///     AX=0004 (read back verbatim by the guest via AX=0003).
///   - `{"dx": DX, "dy": DY}` — RELATIVE motion (the ported fixed-point mickey /
///     sensitivity math; raw input forced, no host clock). Drives both the cursor
///     position AND the AX=000B mickey counters. Ships in v1 (NOT `not_implemented`).
///   - `{"buttons": N}` — button mask, bit0 left / bit1 right / bit2 middle.
/// Absolute and relative are MUTUALLY EXCLUSIVE PER AXIS (mixing `x` with `dx`, or
/// `y` with `dy`, is a `400`); they may otherwise be combined (e.g. `x` + `dy`).
/// `fire_callback` is accepted for forward-compat (the AX=000C event callback is
/// Phase 3) and is a no-op in this phase.
pub const MouseReq = struct {
    // --- the SCRIPTED / deterministic path (unchanged; input-injection.md §5.2) ---
    // Absolute guest-virtual position (x/y) or relative driver-units (dx/dy). These
    // drive `Command.input_mouse` → `Controller.injectMouse` (the byte-reproducible
    // seam the oracle + tests rely on). LEFT EXACTLY AS-IS.
    x: ?i16 = null,
    y: ?i16 = null,
    dx: ?i16 = null,
    dy: ?i16 = null,
    buttons: ?u16 = null,
    fire_callback: bool = true,

    // --- the SCRIPTED NORMALIZED absolute path (range-independent addressing) ---
    // `nx`/`ny` address the screen in PER-MYRIAD units: 0 = the left/top edge, 10000
    // = the right/bottom edge, 5000 = the center — INDEPENDENT of the driver's live
    // coordinate range (which a guest may reprogram via INT 33h fn 7/8, e.g. Betrayal
    // at Krondor → 0..1276 × 0..796). The server converts per-myriad → Q16 at the wire
    // mapper (`mapMouseScripted`) and the DRIVER maps that Q16 through its LIVE
    // `min_x/max_x`/`min_y/max_y` via the SAME `q16ToVirtual` the seamless browser path
    // uses — so a caller can reach the whole screen without knowing the live range.
    // INTEGER ONLY (the `src/api` determinism grep bans float types). Per axis, `nx` is
    // MUTUALLY EXCLUSIVE with the raw `x` and the relative `dx` (and `ny` with `y`/`dy`).
    nx: ?u32 = null,
    ny: ?u32 = null,

    // --- the LIVE coalesced browser path (plans/mouse-input.md, LOCKED §2/§3) ---
    // Q16 normalized absolute over the CONTAINED image rect (0..65536 == [0,1]). The
    // SERVER scales these by the driver's LIVE per-mode `max_x/max_y` at fold time, so
    // the wire stays mode-agnostic and the half-speed-X bug is fixed (the old `x/y`
    // mapped to 320 guest px, not the driver's 0–639). INTEGER ONLY — never a host
    // float (the `src/api` determinism grep bans float types).
    nx_q16: ?u32 = null,
    ny_q16: ?u32 = null,
    // The browser's TRUE relative channel (`movementX/movementY`), as integers. Fed
    // into the EXISTING fixed-point mickey path (AX=0B) — the real mickey source, NOT
    // derived from the absolute Δ (LOCKED §3). Carried as i32 (movement can exceed i16
    // over a burst before a fold; the driver saturates to i16 for the mickey math).
    mdx: ?i32 = null,
    mdy: ?i32 = null,

    // --- click vs. hold (the level-sampling fix) ---
    // A button press is, BY DEFAULT, a momentary CLICK: the server presses `buttons`,
    // ADVANCES the machine by a human-realistic dwell of EMULATED time (DEFAULT_CLICK_MS
    // ≈ 100 ms — derived from the machine's OWN configured clock, see
    // `Controller.dwellCycles`), then releases back to the pre-press mask. Both edges go
    // through the single edge-detecting button writer, so the AX=5/6 counters + the
    // AX=000C callback fire exactly as a real held click would. This makes the click
    // OBSERVABLE to a guest that LEVEL-SAMPLES the button once per video frame / timer
    // tick (e.g. Betrayal at Krondor's retrace-spinning menu): a pure instantaneous
    // press+release is never seen by such a guest because injection is cycle-neutral.
    // The default is the click because it is the FOOTGUN-FREE common case — a bare
    // `{buttons:1}` "just works". `hold_ms` OVERRIDES the dwell (ms of EMULATED time);
    // `hold_ms:0` presses+releases at the SAME cycle (instant; edge-latched AX=5/6
    // catches it, a level-sampler does not). One 70 Hz frame ≈ 14 ms, one 18.2 Hz tick
    // ≈ 55 ms, so the ~100 ms default comfortably covers any per-frame/per-tick sampler.
    // INTEGER ONLY (the `src/api` determinism grep bans floats).
    hold_ms: ?u32 = null,
    // `release:false` opts OUT of the auto-release: the `buttons` mask is set RAW and
    // HELD (the pure, cycle-neutral inject — no dwell, no release). This is the
    // press-and-hold a DRAG needs: press (`{buttons:1, release:false}`) → move (`{dx,
    // buttons:1, release:false}`, with a `run` between) → release (`{buttons:0}`).
    // Mutually exclusive with `hold_ms` (a dwell implies a release). Default `true`, so
    // a plain press is a click; only an explicit `release:false` holds.
    release: bool = true,
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
