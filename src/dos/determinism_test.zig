//! Determinism grep-gate for the DOS-side INPUT code (input Phase 0). Mirrors the
//! `@embedFile` + forbidden-needle idiom of `src/machine/determinism_test.zig:12-40`
//! and `src/api/determinism_test.zig`. The goal: when the Phase-2 mouse mickey /
//! sensitivity / relative-motion math lands in `int33.zig` (and any future DOS-side
//! input math), it is ALREADY gated against the spice86/DOSBox float-key anti-pattern
//! and against any host-time / RNG / thread / env dependence.
//!
//! SCOPE — which files are gated, and WHY only these:
//!   - `int33.zig` (the mouse driver — where the Phase-2 mickey/sensitivity math
//!     lands) is embedded and MUST stay clean.
//! This gate deliberately does NOT embed `int21.zig`/`fcb.zig`. Those files contain
//! the substring "Random" — but it is the legitimate DOS *FCB random-access record*
//! concept (AH=21/22/24, `setRandom`, "Set Random Record"), NOT `std.Random` RNG.
//! Embedding them would force a FALSE needle hit on `Random`; narrowing the needle
//! to dodge it would weaken the gate. The honest resolution (per the Phase 0 caveat)
//! is to gate the files the input code lives in and document the pre-existing benign
//! match here rather than hide it. No actual host-dependence exists in those files.

const std = @import("std");

const dos_input_sources = [_][]const u8{
    @embedFile("int33.zig"),
    // EMS INT 67h handler + the resident "EMMXXXX0" device-driver header staged
    // at POST (Krondor milestone Stage 1). The header is fixed comptime data —
    // gated here so it can never grow a host-clock/RNG/float dependence.
    @embedFile("ems.zig"),
};

test "src/dos input grep: no host time / RNG / thread / env / float" {
    const forbidden = [_][]const u8{
        // No floats in the mickey/sensitivity/accumulator math (§5.2): the
        // float-key anti-pattern is exactly the spice86/DOSBox determinism hole.
        "f32",
        "f64",
        // No host clock driving emulation (constraint #2).
        "std.time",
        "nanoTimestamp",
        // No RNG (constraint #5 — deterministic init/state only).
        "std.Random",
        "std.rand",
        // No host threads feeding back into emulation (constraint #4).
        "std.Thread",
        "Thread",
        // No host environment (constraint #3).
        "std.posix.getenv",
        "std.process.getEnv",
        "std.os.getenv",
        "getenv",
    };
    for (dos_input_sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a src/dos input source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}
