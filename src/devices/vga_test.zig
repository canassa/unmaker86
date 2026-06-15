//! VGA device unit tests (I/O band 1): the mode-13h-relevant subset — the DAC
//! port state machine (write/read index auto-advance, 6-bit masking) and the
//! linear VRAM round-trip through the MemHandler. Mirrors dosbox-x vga_dac.cpp
//! semantics so the device is faithful in isolation (the oracle then proves the
//! whole INT 10h + VRAM + DAC path end-to-end).

const std = @import("std");
const devices = @import("devices");

const Vga = devices.Vga;
const vga_mod = devices.vga;

fn makeVga(alloc: std.mem.Allocator) !*Vga {
    const v = try alloc.create(Vga);
    try v.init(alloc);
    return v;
}
fn freeVga(alloc: std.mem.Allocator, v: *Vga) void {
    v.deinit(alloc);
    alloc.destroy(v);
}

test "retrace timing constants resolve to the canonical 70.086 Hz frame" {
    // The constants are comptime-pinned in vga.zig; assert they are reachable via
    // `devices.Vga.*` (no new test-module import) and match the canonical figures.
    try std.testing.expectEqual(@as(u64, 204_293), Vga.FRAME_CYCLES);
    try std.testing.expectEqual(@as(u64, 454), Vga.LINE_CYCLES);
    try std.testing.expectEqual(@as(u64, 181), Vga.HDE_CYCLES);
    // Effective refresh: 14_318_184 / 204_293 = 70.086 Hz (integer hundredths = 7008).
    const timing = @import("timing");
    try std.testing.expectEqual(@as(u64, 7008), timing.CPU_CLOCK_HZ * 100 / Vga.FRAME_CYCLES);
}

// ---------------------------------------------------------------------------
// Input Status Register #1 (0x3DA / 0x3BA) — cycle-derived retrace / display-enable
// (plans/vga-retrace.md §5.1). The retrace tests need a controllable cycle source:
// give the test `Vga` a local u64 and point `v.cycles = &cycles` (the test-harness
// analog of machine.wire). All asserts are at hand-computed cycles.
// ---------------------------------------------------------------------------

test "0x3DA bit 3 (vertical retrace) toggles deterministically across a frame" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // Scanline 0 (top of frame): not in v-retrace -> bit 3 == 0.
    cycles = 0; // into_frame=0, scanline=0
    try std.testing.expectEqual(@as(u8, 0), v.in8(0x3DA) & 0x08);

    // A scanline inside [VRSTART_LINE, VREND_LINE) -> bit 3 == 1.
    cycles = Vga.VRSTART_LINE * Vga.LINE_CYCLES; // scanline == 412
    try std.testing.expectEqual(@as(u8, 0x08), v.in8(0x3DA) & 0x08);
    cycles = (Vga.VREND_LINE - 1) * Vga.LINE_CYCLES; // scanline == 413
    try std.testing.expectEqual(@as(u8, 0x08), v.in8(0x3DA) & 0x08);

    // The line at VREND_LINE is past the retrace pulse -> bit 3 == 0 again.
    cycles = Vga.VREND_LINE * Vga.LINE_CYCLES; // scanline == 414
    try std.testing.expectEqual(@as(u8, 0), v.in8(0x3DA) & 0x08);
}

test "0x3DA bit 0 (display-enable complement) duty: active vs hblank vs vblank" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // A display line (scanline 0), within the active span (into_line < HDE_CYCLES)
    // -> displaying -> bit 0 == 0.
    cycles = 0;
    try std.testing.expectEqual(@as(u8, 0), v.in8(0x3DA) & 0x01);
    cycles = Vga.HDE_CYCLES - 1; // still active
    try std.testing.expectEqual(@as(u8, 0), v.in8(0x3DA) & 0x01);

    // Same display line, past the active span (into_line >= HDE_CYCLES) -> hblank
    // -> bit 0 == 1.
    cycles = Vga.HDE_CYCLES; // first hblank cycle of scanline 0
    try std.testing.expectEqual(@as(u8, 0x01), v.in8(0x3DA) & 0x01);

    // Any scanline past the vertical display end -> vblank -> bit 0 == 1 regardless
    // of into_line.
    cycles = Vga.VDE_LINES * Vga.LINE_CYCLES; // scanline == 400, into_line == 0
    try std.testing.expectEqual(@as(u8, 0x01), v.in8(0x3DA) & 0x01);
}

test "0x3DA bit 2 always 1; bits 1,4-7 always 0 (D-RT2)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // Sweep a range of cycles; bit 2 must always be set and bits 1,4-7 always clear.
    var c: u64 = 0;
    while (c < Vga.FRAME_CYCLES * 2) : (c += 137) {
        cycles = c;
        const b = v.in8(0x3DA);
        try std.testing.expectEqual(@as(u8, 0x04), b & 0x04); // bit 2 set
        try std.testing.expectEqual(@as(u8, 0), b & 0b1111_0010); // bits 1,4-7 clear
    }
}

test "0x3BA mono alias returns the same byte as 0x3DA at the same cycle" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    var c: u64 = 0;
    while (c < Vga.FRAME_CYCLES) : (c += 251) {
        cycles = c;
        try std.testing.expectEqual(v.in8(0x3DA), v.in8(0x3BA));
    }
}

test "0x3DA is a pure function of the cycle counter: two reads at same cycle equal" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    cycles = 12_345;
    const a = v.in8(0x3DA);
    const b = v.in8(0x3DA);
    try std.testing.expectEqual(a, b);
}

test "0x3DA unwired cycle source reads as the deterministic cycle-0 status (no UB)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // No v.cycles wired -> cyclesNow() returns 0 -> the cycle-0 status byte (active,
    // not retrace) = bit2 only = 0x04. Never the unmapped 0xFF.
    try std.testing.expectEqual(@as(u8, 0x04), v.in8(0x3DA));
}

test "DAC: write a single entry via 0x3C8 + three 0x3C9, read it back via 0x3C7" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    // Set write index 5, write (0x3F, 0x00, 0x15) — the io-oracle.md §1.3 entry 5.
    v.out8(0x3C8, 5);
    v.out8(0x3C9, 0x3F);
    v.out8(0x3C9, 0x00);
    v.out8(0x3C9, 0x15);

    try std.testing.expectEqual(@as(u8, 0x3F), v.dac_rgb[5].red);
    try std.testing.expectEqual(@as(u8, 0x00), v.dac_rgb[5].green);
    try std.testing.expectEqual(@as(u8, 0x15), v.dac_rgb[5].blue);

    // Read it back via 0x3C7 read-index + three 0x3C9 reads.
    v.out8(0x3C7, 5);
    try std.testing.expectEqual(@as(u8, 0x3F), v.in8(0x3C9));
    try std.testing.expectEqual(@as(u8, 0x00), v.in8(0x3C9));
    try std.testing.expectEqual(@as(u8, 0x15), v.in8(0x3C9));
}

test "DAC: write index auto-advances after a full RGB triple (vga_dac.cpp:367)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3C8, 10);
    // Two consecutive entries written without re-setting the index.
    v.out8(0x3C9, 1);
    v.out8(0x3C9, 2);
    v.out8(0x3C9, 3); // entry 10 complete -> write_index advances to 11
    v.out8(0x3C9, 4);
    v.out8(0x3C9, 5);
    v.out8(0x3C9, 6); // entry 11 complete

    try std.testing.expectEqual(@as(u8, 1), v.dac_rgb[10].red);
    try std.testing.expectEqual(@as(u8, 3), v.dac_rgb[10].blue);
    try std.testing.expectEqual(@as(u8, 4), v.dac_rgb[11].red);
    try std.testing.expectEqual(@as(u8, 6), v.dac_rgb[11].blue);
    try std.testing.expectEqual(@as(u8, 12), v.dac_write_index); // advanced past 11
}

test "DAC: 0x3C9 writes are masked to 6 bits (vga_dac.cpp:316)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3C8, 0);
    v.out8(0x3C9, 0xFF); // -> 0x3F
    v.out8(0x3C9, 0xC0); // -> 0x00
    v.out8(0x3C9, 0x7F); // -> 0x3F
    try std.testing.expectEqual(@as(u8, 0x3F), v.dac_rgb[0].red);
    try std.testing.expectEqual(@as(u8, 0x00), v.dac_rgb[0].green);
    try std.testing.expectEqual(@as(u8, 0x3F), v.dac_rgb[0].blue);
}

test "DAC: 0x3C7 read-state byte (vga_dac.cpp:271) and 0x3C8 write-index read-back" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3C8, 0x42); // state = WRITE
    try std.testing.expectEqual(@as(u8, 0x42), v.in8(0x3C8)); // write index read-back
    try std.testing.expectEqual(@as(u8, 0x0), v.in8(0x3C7)); // state != READ -> 0

    v.out8(0x3C7, 0x10); // state = READ
    try std.testing.expectEqual(@as(u8, 0x3), v.in8(0x3C7)); // state == READ -> 0x3
}

test "DAC: 0x3C8 sets read_index = val-1 (vgaonly, vga_dac.cpp:287)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    v.out8(0x3C8, 7);
    try std.testing.expectEqual(@as(u8, 7), v.dac_write_index);
    try std.testing.expectEqual(@as(u8, 6), v.dac_read_index);
}

test "pixel mask 0x3C6 round-trip; power-on 0xFF" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    try std.testing.expectEqual(@as(u8, 0xFF), v.in8(0x3C6));
    v.out8(0x3C6, 0x3F);
    try std.testing.expectEqual(@as(u8, 0x3F), v.in8(0x3C6));
}

test "misc output 0x3C2 write / 0x3CC read-back" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    v.out8(0x3C2, 0x23);
    try std.testing.expectEqual(@as(u8, 0x23), v.in8(0x3CC));
}

test "VRAM MemHandler: linear A000 round-trip + host-pointer fast path" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    const h = v.memHandler();
    // Write through the handler at A000:0064 (offset 100, io-oracle.md §1.3 probe).
    h.write8(vga_mod.VRAM_PHYS + 100, 0x2A);
    try std.testing.expectEqual(@as(u8, 0x2A), v.vram[100]);
    try std.testing.expectEqual(@as(u8, 0x2A), h.read8(vga_mod.VRAM_PHYS + 100));

    // getHostPtr returns a direct pointer to the page's VRAM bytes (RAM-like MMIO).
    const page = vga_mod.VRAM_PHYS >> 12;
    const hp = h.hostPtr(page).?;
    try std.testing.expectEqual(@as(u8, 0x2A), hp[100]);
    // A page outside the window has no host pointer.
    try std.testing.expectEqual(@as(?[*]u8, null), h.hostPtr((vga_mod.VRAM_PHYS + vga_mod.VRAM_WINDOW_LEN) >> 12));
}

test "reset zeroes VRAM + DAC + indices deterministically" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.vram[0] = 0xAB;
    v.out8(0x3C8, 3);
    v.out8(0x3C9, 0x10);
    v.reset();
    try std.testing.expectEqual(@as(u8, 0), v.vram[0]);
    try std.testing.expectEqual(@as(u8, 0), v.dac_rgb[3].red);
    try std.testing.expectEqual(@as(u8, 0), v.dac_write_index);
    try std.testing.expectEqual(@as(u8, 0xFF), v.pel_mask);
}

test "snapshot/restore round-trips the DAC + register state" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3C8, 9);
    v.out8(0x3C9, 0x11);
    v.out8(0x3C9, 0x22);
    v.out8(0x3C9, 0x33);
    v.out8(0x3C2, 0x23);
    const snap = v.snapshot();

    v.reset();
    try std.testing.expectEqual(@as(u8, 0), v.dac_rgb[9].red);
    v.restore(snap);
    try std.testing.expectEqual(@as(u8, 0x11), v.dac_rgb[9].red);
    try std.testing.expectEqual(@as(u8, 0x22), v.dac_rgb[9].green);
    try std.testing.expectEqual(@as(u8, 0x33), v.dac_rgb[9].blue);
    try std.testing.expectEqual(@as(u8, 0x23), v.misc_output);
}
