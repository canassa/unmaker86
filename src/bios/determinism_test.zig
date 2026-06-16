//! Determinism grep-gate for the BIOS-side INPUT code (input Phase 0). Mirrors the
//! `@embedFile` + forbidden-needle idiom of `src/machine/determinism_test.zig:12-40`.
//! The goal: when the Phase-1 INT 09h ISR + shift-flag state machine land in
//! `src/bios/int09.zig` (and the BDA keyboard-ring offsets in `bda.zig`), they are
//! ALREADY gated against floats (the spice86/DOSBox key-as-float anti-pattern) and
//! against any host-time / RNG / thread / env dependence.
//!
//! SCOPE — every CURRENT `src/bios` source is clean of the needles (verified by grep
//! before writing this gate), so the whole BIOS surface is embedded: the keyboard
//! input ISR (`int09.zig`) will live alongside `int16.zig`/`bda.zig` here, and the
//! tick/IVT/video/equip handlers must stay host-clock-free too (emulated time is a
//! function of the cycle counter, constraint #2). When `int09.zig` is added it must
//! be appended to the embed list below.

const std = @import("std");

const bios_sources = [_][]const u8{
    @embedFile("bios.zig"),
    @embedFile("bda.zig"),
    @embedFile("int08.zig"),
    @embedFile("int09.zig"),
    @embedFile("int10.zig"),
    @embedFile("int11_12.zig"),
    @embedFile("int15.zig"),
    @embedFile("int16.zig"),
    @embedFile("int1a.zig"),
    @embedFile("scancodes.zig"),
    // VGA Phase 2 (plans/vga-spec/04-modes-int10-bda.md, R1): the new font /
    // mode-table / palette comptime-data files must be in the gate the moment
    // they exist — a new bios source not in the gate IS the determinism regression.
    @embedFile("vga_font.zig"),
    @embedFile("vga_modes.zig"),
    @embedFile("vga_palettes.zig"),
    // VGA Phase 5c (R1): the save-pointer / DCC / static-functionality ROM-table
    // comptime-data file — float-gated here alongside the other VGA ROM data.
    @embedFile("vga_rom.zig"),
};

test "src/bios grep: no host time / RNG / thread / env / float" {
    const forbidden = [_][]const u8{
        // No floats anywhere in the BIOS path (the spice86/DOSBox anti-pattern):
        // the upcoming keyboard/keycode math must not introduce f32/f64 keys.
        "f32",
        "f64",
        // No host clock driving emulation (constraint #2): emulated time is a
        // function of the cycle counter; the INT 08h/1Ah tick reads the PIT/BDA.
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
    for (bios_sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a src/bios source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}
