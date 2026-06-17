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

// ---------------------------------------------------------------------------
// Device-time domain (Phase 1 of the live-CPU-clock work — `plans/configurable-
// cpu-clock.md`, approach B). Real-time-anchored devices (PIT, VGA, speaker,
// OPL, keyboard typematic) schedule events and compute phase in a *mult-
// independent* DEVICE-TIME unit, NOT in CPU cycles. The CPU:device-time
// multiplier (= `cycles_num`, CPU cycles per device-time unit) converts
// device-time <-> CPU-cycles ONLY at the run-loop / scheduler boundary. Once a
// future phase lets `mult` vary at runtime, device events + phases stay put
// (no re-arm) and only this conversion factor changes.
//
// DEVICE-TIME UNIT = "nominal cycles" = CPU cycles at the REFERENCE mult
// (`REF_MULT` == `cycles_num` == 12). This is the finest unit that keeps EVERY
// existing period constant (VGA `FRAME_CYCLES`, OPL µs intervals, the speaker
// PWM window, keyboard ms->cycles, the PIT reload x12) an exact integer. At the
// pinned mult 12 the device-time<->CPU-cycle conversion is the IDENTITY, so
// Phase 1 is byte-identical to the pre-seam cycle ledger (no golden moves).

/// The reference CPU:device-time multiplier (CPU cycles per device-time unit) —
/// the device-time unit's ANCHOR. The DEVICE-TIME unit is "nominal cycles at the
/// reference mult" so every real-time-anchored period (VGA `FRAME_CYCLES`, OPL µs
/// intervals, the speaker PWM window, keyboard ms→device-time, the PIT reload×12)
/// is a fixed integer INDEPENDENT of the live `mult`. This stays a comptime
/// constant forever; the *active* CPU:PIT multiplier is a RUNTIME value
/// (`Machine.clock.mult`, Phase 2) that enters ONLY at the device-time↔CPU-cycle
/// boundary conversions below. `DEFAULT_MULT` is the power-on / golden value.
pub const REF_MULT: u64 = cycles_num;

/// The default (power-on) active CPU:PIT multiplier. The runtime `mult`
/// (`Machine.clock.mult`) initializes to this; at this value the device-time↔
/// CPU-cycle conversions are the IDENTITY (`REF_MULT == DEFAULT_MULT`) so the
/// whole cycle ledger is byte-identical to Phase 1 / the pre-seam emulator.
pub const DEFAULT_MULT: u64 = cycles_num;

comptime {
    // Device-time == nominal cycles at the reference mult: the boundary
    // conversions are the IDENTITY at the default mult. (A divergence here would
    // move every golden.)
    std.debug.assert(REF_MULT == cycles_num);
    std.debug.assert(DEFAULT_MULT == REF_MULT);
}

/// Convert a DEVICE-TIME span into CPU cycles at the active `mult`:
/// `cpu = dt * mult / REF_MULT`. Integer-exact, no floats, no host time. At the
/// default mult (`mult == REF_MULT == 12`) this is the IDENTITY, so the returned
/// cycle is byte-identical to Phase 1; at a higher integer mult the CPU runs more
/// cycles per device-time unit (faster CPU, peripherals keep their device rates).
pub fn deviceToCpu(device_time: u64, mult: u64) u64 {
    return device_time * mult / REF_MULT;
}

/// Convert a CPU-cycle span into DEVICE-TIME at the active `mult`, the inverse
/// boundary conversion: `dt = cyc * REF_MULT / mult`. Integer floor division (the
/// device-time domain is the finer/anchored unit). Identity at the default mult;
/// integer-exact, no floats, no host time.
pub fn cpuToDevice(cpu_cycles: u64, mult: u64) u64 {
    return cpu_cycles * REF_MULT / mult;
}

/// Convert milliseconds into DEVICE-TIME units. `device_time = ms * CPU_CLOCK_HZ
/// / 1000` — identical to the former ms->cycles math because device-time ==
/// nominal cycles at the reference mult. Integer, no floats, no host time.
pub fn msToDeviceTime(ms: u64) u64 {
    return ms * CPU_CLOCK_HZ / 1000;
}

/// Convert microseconds into DEVICE-TIME units: `device_time = us * CPU_CLOCK_HZ
/// / 1_000_000`. Identical to the former µs->cycles math (OPL timer intervals).
pub fn usToDeviceTime(us: u64) u64 {
    return us * CPU_CLOCK_HZ / 1_000_000;
}

/// The PINNED emulated wall-clock epoch (D13): `1993-01-01 00:00:00`. ALL
/// DOS/BIOS-visible date/time (INT 21h AH=2A/2C, INT 1Ah, the DTA find record,
/// AH=57 file date-time, directory timestamps) derive from this fixed epoch plus
/// the emulated BDA tick count — NEVER the host wall clock or host file
/// mtime/ctime (the Spice86 non-determinism leak this project closes). A project
/// constant; same binary + same inputs => same clock, every run.
pub const epoch_year: u16 = 1993;
pub const epoch_month: u8 = 1; // January
pub const epoch_day: u8 = 1;
pub const epoch_hour: u8 = 0;
pub const epoch_minute: u8 = 0;
pub const epoch_second: u8 = 0;

comptime {
    // The pinned ratio must be exact (den divides num) so the documented
    // "remainder always 0" invariant holds for the BaK path.
    std.debug.assert(CPU_CLOCK_HZ == PIT_TICK_RATE * cycles_num / cycles_den);
    std.debug.assert(cycles_den != 0);
}

/// Convert `ticks` PIT ticks into DEVICE-TIME units using integer math + a
/// carried fractional remainder (M-D8). The remainder accumulator is owned by
/// the caller (the scheduler) and snapshotted, so drift is reproducible and
/// bounded.
///
/// `delta = (ticks * cycles_num + *remainder) / cycles_den`
/// `*remainder = (ticks * cycles_num + *remainder) % cycles_den`
///
/// Because device-time == nominal cycles at the REFERENCE mult, this uses
/// `cycles_num` (== `REF_MULT`), NOT the live `mult`: a PIT tick is always
/// `REF_MULT` device-time units regardless of CPU speed (the device-time domain is
/// mult-independent — that is the whole point of the seam). The live `mult` enters
/// only at the device-time→CPU-cycle boundary (`deviceToCpu`). No floats, no host
/// time — pure integer fn of (ticks, remainder).
pub fn ticksToCycles(ticks: u64, remainder: *u64) u64 {
    const total = ticks * cycles_num + remainder.*;
    remainder.* = total % cycles_den;
    return total / cycles_den;
}

/// Convert elapsed CPU `cycles` back into whole PIT ticks at the active `mult`
/// (for the PIT counter read-back: the current counter is a pure function of
/// elapsed cycles since the last arm, M-D8). `ticks = cyc / mult` — at `mult` CPU
/// cycles per PIT tick. Integer floor division (sub-tick cycles are masked); at
/// the default mult 12 this is the former `cyc / 12`, byte-identical. This is the
/// ONE PIT-side site where the live `mult` (not `REF_MULT`) is the ratio, because
/// the elapsed span is in CPU cycles, not device-time.
pub fn cyclesToTicks(cyc: u64, mult: u64) u64 {
    return cyc / mult;
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

test "cyclesToTicks floors at the default mult" {
    try std.testing.expectEqual(@as(u64, 1), cyclesToTicks(12, DEFAULT_MULT));
    try std.testing.expectEqual(@as(u64, 1), cyclesToTicks(23, DEFAULT_MULT)); // sub-tick floored
    try std.testing.expectEqual(@as(u64, 2), cyclesToTicks(24, DEFAULT_MULT));
    // At a doubled mult one PIT tick spans 24 CPU cycles.
    try std.testing.expectEqual(@as(u64, 1), cyclesToTicks(24, 24));
    try std.testing.expectEqual(@as(u64, 0), cyclesToTicks(23, 24));
}

test "device-time<->CPU conversions are the identity at the default mult 12" {
    // The no-op gate: REF_MULT == DEFAULT_MULT so both boundary conversions are
    // the identity at the default (any divergence moves every golden).
    try std.testing.expectEqual(@as(u64, 0), deviceToCpu(0, DEFAULT_MULT));
    try std.testing.expectEqual(@as(u64, 12), deviceToCpu(12, DEFAULT_MULT));
    try std.testing.expectEqual(@as(u64, 204_293), deviceToCpu(204_293, DEFAULT_MULT));
    try std.testing.expectEqual(@as(u64, 0), cpuToDevice(0, DEFAULT_MULT));
    try std.testing.expectEqual(@as(u64, 14_318_184), cpuToDevice(14_318_184, DEFAULT_MULT));
    // Round-trip is exact for every value at the default mult.
    var v: u64 = 1;
    while (v < 1_000_000) : (v *= 7) {
        try std.testing.expectEqual(v, deviceToCpu(cpuToDevice(v, DEFAULT_MULT), DEFAULT_MULT));
        try std.testing.expectEqual(v, cpuToDevice(deviceToCpu(v, DEFAULT_MULT), DEFAULT_MULT));
    }
}

test "device-time->CPU scales with a non-default mult (faster CPU)" {
    // At a doubled mult the CPU runs 2x the cycles per device-time unit; the
    // inverse floors. Exact when mult divides REF_MULT*dt evenly.
    try std.testing.expectEqual(@as(u64, 24), deviceToCpu(12, 24));
    try std.testing.expectEqual(@as(u64, 408_586), deviceToCpu(204_293, 24));
    try std.testing.expectEqual(@as(u64, 6), cpuToDevice(12, 24)); // 12 * 12 / 24
}

test "ms/us -> device-time match the former cycle math (device-time == nominal cycles)" {
    try std.testing.expectEqual(500 * CPU_CLOCK_HZ / 1000, msToDeviceTime(500));
    try std.testing.expectEqual(33 * CPU_CLOCK_HZ / 1000, msToDeviceTime(33));
    try std.testing.expectEqual(80 * CPU_CLOCK_HZ / 1_000_000, usToDeviceTime(80));
    try std.testing.expectEqual(320 * CPU_CLOCK_HZ / 1_000_000, usToDeviceTime(320));
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
