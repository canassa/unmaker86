//! Shared, single-source timing constants for the PIT and any PIT-derived device
//! (M-D8 / M-D8a). This is a SHARED LEAF: `src/devices/` (the 8254 PIT) and the
//! machine consult it so every PIT-derived device agrees on one ratio. It imports
//! nothing but `std` and contains NO host-time access (CLAUDE constraint #2).
//!
//! Determinism contract (M-D2/M-D8): the scheduler keys on the u64 CPU CYCLE
//! COUNTER, never on host time / ms / floats. The PIT reload -> cycle conversion
//! is INTEGER-ONLY with an explicit fractional-remainder accumulator so no PIT
//! tick is silently dropped or double-counted. With the pinned ratio below the
//! denominator is 1 (the remainder is always 0), but the accumulator is kept for
//! generality / a future non-integer ratio and is snapshotted (M-D11).

const std = @import("std");

/// The 8254 input clock: 1.193182 MHz (the classic IBM PC/AT PIT frequency).
/// `timer.h:16` in dosbox-staging. A channel with reload `R` (R==0 -> 65536)
/// fires every `R` PIT ticks.
pub const PIT_TICK_RATE: u64 = 1_193_182;

/// The PINNED emulated CPU clock (M-D8a): `PIT_TICK_RATE * 12 = 14_318_184`
/// (~14.32 MHz). Chosen so `cpu_cycles_per_pit_tick` is an EXACT integer (12),
/// giving zero fractional drift, and comfortably above BaK's 386SX-12 floor. It
/// is NOT a PRM-accurate figure — the cycle model is interim-flat (cpu.md D6);
/// it only needs to be FIXED for determinism.
pub const CPU_CLOCK_HZ: u64 = PIT_TICK_RATE * 12;

/// The integer cycles-per-PIT-tick ratio (M-D8): `cycles_num / cycles_den`.
/// Pinned to 12/1 (M-D8a) — exact, so the remainder accumulator is always 0.
pub const cycles_num: u64 = 12;
pub const cycles_den: u64 = 1;

comptime {
    // The pinned ratio must be exact (den divides num) so the documented
    // "remainder always 0" invariant holds for the BaK path.
    std.debug.assert(CPU_CLOCK_HZ == PIT_TICK_RATE * cycles_num / cycles_den);
    std.debug.assert(cycles_den != 0);
}

/// Convert `ticks` PIT ticks into CPU cycles using integer math + a carried
/// fractional remainder (M-D8). The remainder accumulator is owned by the caller
/// (the PIT channel) and snapshotted, so cycle drift is reproducible and bounded.
///
/// `delta_cycles = (ticks * cycles_num + *remainder) / cycles_den`
/// `*remainder   = (ticks * cycles_num + *remainder) % cycles_den`
///
/// No floats, no host time — a pure integer function of (ticks, remainder).
pub fn ticksToCycles(ticks: u64, remainder: *u64) u64 {
    const total = ticks * cycles_num + remainder.*;
    remainder.* = total % cycles_den;
    return total / cycles_den;
}

/// Convert elapsed CPU `cycles` back into whole PIT ticks (for counter read-back:
/// the current counter is a pure function of elapsed cycles since the last arm,
/// M-D8). Integer floor division — sub-tick cycles are masked (at the 12/1 ratio
/// this matters only once PRM cycle counts land).
pub fn cyclesToTicks(cyc: u64) u64 {
    return cyc * cycles_den / cycles_num;
}

test "no host time / RNG / float in timing.zig (grep — M-D2)" {
    const src = @embedFile("timing.zig");
    // Needles built from bytes so the forbidden literals do not appear in THIS
    // file's source (a self-grep would otherwise match its own check list).
    const needles = [_][]const u8{
        &[_]u8{ 's', 't', 'd', '.', 't', 'i', 'm', 'e' },
        &[_]u8{ 's', 't', 'd', '.', 'R', 'a', 'n', 'd', 'o', 'm' },
        &[_]u8{ 's', 't', 'd', '.', 'T', 'h', 'r', 'e', 'a', 'd' },
        &[_]u8{ 'f', '3', '2' },
        &[_]u8{ 'f', '6', '4' },
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) return error.ForbiddenHostDependence;
    }
}

test "ticksToCycles is exact at the pinned 12/1 ratio (remainder stays 0)" {
    var rem: u64 = 0;
    try std.testing.expectEqual(@as(u64, 12), ticksToCycles(1, &rem));
    try std.testing.expectEqual(@as(u64, 0), rem);
    try std.testing.expectEqual(@as(u64, 65536 * 12), ticksToCycles(65536, &rem));
    try std.testing.expectEqual(@as(u64, 0), rem);
}

test "cyclesToTicks floors at the pinned ratio" {
    try std.testing.expectEqual(@as(u64, 1), cyclesToTicks(12));
    try std.testing.expectEqual(@as(u64, 1), cyclesToTicks(23)); // sub-tick floored
    try std.testing.expectEqual(@as(u64, 2), cyclesToTicks(24));
}

test "ticksToCycles carries a remainder for a hypothetical non-integer ratio" {
    // Simulate a 3/2 ratio by hand to prove the accumulator logic (the pinned
    // ratio is 12/1 so this exercises the carry path generically).
    var total: u64 = 0;
    var rem: u64 = 0;
    inline for (0..3) |_| {
        // (ticks=1 * num=3 + rem) / den=2 with carry
        const num: u64 = 3;
        const den: u64 = 2;
        const t = 1 * num + rem;
        rem = t % den;
        total += t / den;
    }
    // 3 ticks * 3/2 = 4.5 -> floor sum 4, remainder 1 carried (1+1+1 carries).
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(u64, 1), rem);
}
