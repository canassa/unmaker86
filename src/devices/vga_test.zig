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

test "0x3DA read resets the attribute-controller flip-flop to index phase (D-RT3)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    v.attr_flip_flop_is_index = false; // pretend a 0x3C0 access left it in data phase
    _ = v.in8(0x3DA);
    try std.testing.expect(v.attr_flip_flop_is_index); // reset to index phase

    // 0x3BA (mono alias) does the same.
    v.attr_flip_flop_is_index = false;
    _ = v.in8(0x3BA);
    try std.testing.expect(v.attr_flip_flop_is_index);
}

test "attr flip-flop is power-on index, reset-stable, and snapshot round-trips" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    try std.testing.expect(v.attr_flip_flop_is_index); // power-on index phase
    v.attr_flip_flop_is_index = false;
    const snap = v.snapshot();

    v.reset();
    try std.testing.expect(v.attr_flip_flop_is_index); // reset -> index phase

    v.restore(snap);
    try std.testing.expect(!v.attr_flip_flop_is_index); // restored data phase
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

// ---------------------------------------------------------------------------
// Indexed register files (SEQ/CRTC/GC/AC) — storage + index/data protocol +
// read-back, the AC flip-flop, CRTC write-protect, and snapshot round-trip
// (plans/vga-spec/01-registers.md §1-5,§8). Storage/protocol layer ONLY: this
// phase does not wire any bit's downstream effect (memory engine / rasterizer).
// ---------------------------------------------------------------------------

test "SEQ index/data read-back through the 0x3C4/0x3C5 protocol" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    // Latch idx 0x03, write data, read it back at the data port + the index port.
    v.out8(0x3C4, 0x03);
    v.out8(0x3C5, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x03), v.in8(0x3C4)); // index read-back
    try std.testing.expectEqual(@as(u8, 0x5A), v.in8(0x3C5)); // data read-back

    // Index is masked to bits 2-0 (idx 0-4 only): 0x0A -> 0x02.
    v.out8(0x3C4, 0x0A);
    try std.testing.expectEqual(@as(u8, 0x02), v.in8(0x3C4));
    // idx 0x02 is Map Mask, power-on 0x0F (reset default).
    try std.testing.expectEqual(@as(u8, 0x0F), v.in8(0x3C5));
}

test "GC index/data read-back through the 0x3CE/0x3CF protocol (index masked to bits 3-0)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3CE, 0x05); // GC Mode register
    v.out8(0x3CF, 0x41);
    try std.testing.expectEqual(@as(u8, 0x05), v.in8(0x3CE));
    try std.testing.expectEqual(@as(u8, 0x41), v.in8(0x3CF));

    // Index masked to bits 3-0: 0x18 -> 0x08 (Bit Mask, power-on 0xFF).
    v.out8(0x3CE, 0x18);
    try std.testing.expectEqual(@as(u8, 0x08), v.in8(0x3CE));
    try std.testing.expectEqual(@as(u8, 0xFF), v.in8(0x3CF));
}

test "CRTC index/data read-back + the mono 0x3B4/0x3B5 alias" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    v.out8(0x3D4, 0x0C); // Start Address High
    v.out8(0x3D5, 0xAB);
    v.out8(0x3D4, 0x0D); // Start Address Low
    v.out8(0x3D5, 0xCD);
    try std.testing.expectEqual(@as(u8, 0xAB), blk: {
        v.out8(0x3D4, 0x0C);
        break :blk v.in8(0x3D5);
    });
    // startAddress() accessor composes the two.
    try std.testing.expectEqual(@as(u16, 0xABCD), v.startAddress());

    // Mono alias addresses the same file.
    v.out8(0x3B4, 0x0D);
    try std.testing.expectEqual(@as(u8, 0xCD), v.in8(0x3B5));
}

test "16-bit OUT to a register index port splits to index(lo)+data(hi)" {
    // The bus default out16 splits to out8(port, lo) then out8(port+1, hi); with
    // both ports registered to the VGA handler this is the index+data idiom.
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const PortHandler = @import("bus").PortHandler;
    const h: PortHandler = v.portHandler();

    h.out16(0x3C4, 0x0F02); // AL=idx 0x02 (Map Mask), AH=data 0x0F
    try std.testing.expectEqual(@as(u8, 0x02), v.in8(0x3C4));
    try std.testing.expectEqual(@as(u8, 0x0F), v.in8(0x3C5));

    h.out16(0x3CE, 0x4105); // AL=idx 0x05 (GC Mode), AH=data 0x41
    try std.testing.expectEqual(@as(u8, 0x05), v.in8(0x3CE));
    try std.testing.expectEqual(@as(u8, 0x41), v.in8(0x3CF));
}

test "AC flip-flop: 0x3DA read resets to address phase; writes latch index then data" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // A status-reg read forces the address phase.
    _ = v.in8(0x3DA);
    try std.testing.expect(v.attr_flip_flop_is_index);

    // Address phase: latch idx 0x11 (Overscan Color, a non-palette reg so PAS
    // does not gate it) with PAS bit clear (bit5=0 => CPU may load palette).
    v.out8(0x3C0, 0x11);
    try std.testing.expect(!v.attr_flip_flop_is_index); // now data phase
    try std.testing.expectEqual(@as(u8, 0x11), v.attr.index);
    try std.testing.expect(!v.attr_pas);

    // Data phase: write the data, flip back to address phase.
    v.out8(0x3C0, 0x7E);
    try std.testing.expect(v.attr_flip_flop_is_index);
    // Read-back via 0x3C1 (does NOT toggle the flip-flop).
    try std.testing.expectEqual(@as(u8, 0x7E), v.in8(0x3C1));
    try std.testing.expect(v.attr_flip_flop_is_index);

    // 0x3C0 read returns index | (PAS<<5).
    v.out8(0x3C0, 0x05 | 0x20); // address phase: idx 0x05, PAS=1
    try std.testing.expect(v.attr_pas);
    // back to address phase via a status read so 0x3C0 read sees the index reg.
    _ = v.in8(0x3DA);
    try std.testing.expectEqual(@as(u8, 0x05 | 0x20), v.in8(0x3C0));
}

test "AC PAS gates internal palette writes (idx 0x00-0x0F)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // PAS=1 (locked): a palette-reg write is ignored.
    _ = v.in8(0x3DA);
    v.out8(0x3C0, 0x03 | 0x20); // idx 0x03, PAS=1
    v.out8(0x3C0, 0x2A); // data — should be dropped (palette locked)
    try std.testing.expectEqual(@as(u8, 0x00), v.attr.regs[0x03]);

    // PAS=0 (CPU owns palette): the write lands, masked to 6 bits.
    _ = v.in8(0x3DA);
    v.out8(0x3C0, 0x03); // idx 0x03, PAS=0
    v.out8(0x3C0, 0xFF); // -> 0x3F (6-bit palette mask)
    try std.testing.expectEqual(@as(u8, 0x3F), v.attr.regs[0x03]);
}

test "CRTC write-protect: idx 0x11 bit7 freezes idx 0x00-0x07 except line-compare-b8" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    // Seed a known value in idx 0x00, then enable write-protect via idx 0x11 bit7.
    v.out8(0x3D4, 0x00);
    v.out8(0x3D5, 0x55);
    v.out8(0x3D4, 0x11);
    v.out8(0x3D5, 0x80); // bit7 = write-protect

    // A write to a protected reg (idx 0x00) is ignored.
    v.out8(0x3D4, 0x00);
    v.out8(0x3D5, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), v.in8(0x3D5));

    // EXCEPTION: the line-compare bit (idx 0x07 bit 4) still latches under
    // protection; the other Overflow bits do NOT change.
    v.out8(0x3D4, 0x07);
    v.out8(0x3D5, 0x00); // (protected: ignored except bit4, currently 0)
    try std.testing.expectEqual(@as(u8, 0x00), v.in8(0x3D5));
    v.out8(0x3D5, 0xFF); // only bit4 (0x10) should latch
    try std.testing.expectEqual(@as(u8, 0x10), v.in8(0x3D5));

    // Clear write-protect; now idx 0x00 writes land again.
    v.out8(0x3D4, 0x11);
    v.out8(0x3D5, 0x00);
    v.out8(0x3D4, 0x00);
    v.out8(0x3D5, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), v.in8(0x3D5));
}

test "Input Status #0 (0x3C2 read) + Feature Control (0x3CA) round-trip" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    // Input Status #0: deterministic VGA constant 0x10 (switch-sense high).
    try std.testing.expectEqual(@as(u8, 0x10), v.in8(0x3C2));

    // Feature Control: write via 0x3DA / read via 0x3CA round-trips.
    v.out8(0x3DA, 0x02);
    try std.testing.expectEqual(@as(u8, 0x02), v.in8(0x3CA));
    v.out8(0x3BA, 0x01); // mono write alias
    try std.testing.expectEqual(@as(u8, 0x01), v.in8(0x3CA));
}

test "snapshot/restore round-trips the four register files + PAS + feature_control + flip-flop" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 0;
    v.cycles = &cycles;

    // Mutate each register file + the AC latches + feature_control.
    v.out8(0x3C4, 0x03);
    v.out8(0x3C5, 0x12);
    v.out8(0x3CE, 0x02);
    v.out8(0x3CF, 0x34);
    v.out8(0x3D4, 0x0C);
    v.out8(0x3D5, 0x56);
    _ = v.in8(0x3DA);
    v.out8(0x3C0, 0x10); // AC address phase, idx 0x10, PAS=0; leaves data phase
    v.out8(0x3DA, 0x03); // feature_control = 0x03

    const snap = v.snapshot();
    // Capture the live values to compare after restore.
    const seq3 = v.seq.regs[0x03];
    const gfx2 = v.gfx.regs[0x02];
    const crtc0c = v.crtc.regs[0x0C];
    const flip = v.attr_flip_flop_is_index;
    const pas = v.attr_pas;
    const ac_idx = v.attr.index;

    v.reset();
    try std.testing.expect(v.seq.regs[0x03] != seq3 or seq3 == 0);

    v.restore(snap);
    try std.testing.expectEqual(seq3, v.seq.regs[0x03]);
    try std.testing.expectEqual(gfx2, v.gfx.regs[0x02]);
    try std.testing.expectEqual(crtc0c, v.crtc.regs[0x0C]);
    try std.testing.expectEqual(@as(u8, 0x03), v.feature_control);
    try std.testing.expectEqual(flip, v.attr_flip_flop_is_index);
    try std.testing.expectEqual(pas, v.attr_pas);
    try std.testing.expectEqual(ac_idx, v.attr.index);
}

test "reset sets the mode-13h power-on register defaults" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);

    // Scribble, then reset and confirm the power-on defaults (§8.3) that keep
    // mode 13h the chained boot/fast path.
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x00);
    v.reset();
    try std.testing.expectEqual(@as(u8, 0x0F), v.mapMask()); // SEQ Map Mask
    try std.testing.expect(v.chained()); // SEQ Chain-4 set
    try std.testing.expectEqual(@as(u8, 0xFF), v.bitMask()); // GC Bit Mask
    try std.testing.expectEqual(@as(u8, 0x0F), v.attr.regs[0x12]); // Color Plane Enable
    try std.testing.expect(v.attr_pas);
    try std.testing.expectEqual(@as(u8, 0), v.feature_control);
}

// ===========================================================================
// Phase 3: the CPU↔VRAM memory engine (planar / Mode-X). Write modes 0/1, read
// mode 0, the 4 latches, the chained-vs-planar dispatch, and the F2/F4 fast
// path. plans/vga-spec/02-memory-engine.md.
// ===========================================================================

const PLANE = vga_mod.PLANE_SIZE;

/// Put the device in UNCHAINED planar mode (Mode-X): clear SEQ Memory-Mode
/// chain-4 (idx 4 bit 3), keep odd/even clear (idx 4 bit 2 set), Map-Mask all
/// planes. Drives the real OUT ports so the F4 `recomputeWriteConfig` fires.
fn setUnchainedPlanar(v: *Vga) void {
    // SEQ idx 4 Memory Mode: extended-mem (bit1)=1, odd/even (bit2)=1 (so
    // odd/even-mode is CLEAR), chain-4 (bit3)=0 → planar.
    v.out8(0x3C4, 0x04);
    v.out8(0x3C5, 0x06);
    // SEQ idx 2 Map Mask: all 4 planes write-enabled.
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x0F);
}

test "Mode-X round-trip: Map-Mask fan-out write, Read-Map-Select read, plane storage" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    try std.testing.expect(!v.chained());

    const h = v.memHandler();
    // getHostPtr must be null in unchained mode → routes to planar read8/write8.
    try std.testing.expectEqual(@as(?[*]u8, null), h.hostPtr(vga_mod.VRAM_PHYS >> 12));

    // Write pixel (x=5, y=3) → plane x&3=1, offset y*80 + x>>2 = 240 + 1 = 241.
    // In Mode-X you select ONE plane via the Map-Mask, then write the byte.
    const x: u32 = 5;
    const y: u32 = 3;
    const plane: u32 = x & 3;
    const poff: u32 = y * 80 + (x >> 2);
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, @as(u8, 1) << @intCast(plane)); // Map-Mask = just plane 1
    h.write8(vga_mod.VRAM_PHYS + poff, 0xBE);

    // The byte landed in plane-major storage at plane*PLANE + poff, and NOWHERE else.
    try std.testing.expectEqual(@as(u8, 0xBE), v.vram[plane * PLANE + poff]);
    for (0..4) |p| {
        if (p == plane) continue;
        try std.testing.expectEqual(@as(u8, 0), v.vram[p * PLANE + poff]);
    }

    // Read it back via Read-Map-Select (GC idx 4) = plane 1, read mode 0.
    v.out8(0x3CE, 0x04);
    v.out8(0x3CF, @intCast(plane));
    try std.testing.expectEqual(@as(u8, 0xBE), h.read8(vga_mod.VRAM_PHYS + poff));
    // A read loads ALL 4 latches (§3).
    try std.testing.expectEqual(@as(u8, 0xBE), v.latch[plane]);
    for (0..4) |p| {
        if (p == plane) continue;
        try std.testing.expectEqual(@as(u8, 0), v.latch[p]);
    }
}

test "Write mode 1: latch copy performs a VRAM->VRAM plane copy" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    // Seed distinct per-plane bytes at the SOURCE offset (write each plane via WM0).
    const src_off: u32 = 100;
    const seed = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    for (seed, 0..) |b, p| {
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, @as(u8, 1) << @intCast(p));
        h.write8(vga_mod.VRAM_PHYS + src_off, b);
    }

    // Switch to write mode 1 (GC idx 5 bit1:0 = 01), Map-Mask all planes.
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x0F);
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x01); // write mode 1

    // rep-movsb pair: a READ loads the 4 latches from src; the paired WRITE to dst
    // stores them. Host byte is ignored in WM1.
    const dst_off: u32 = 500;
    _ = h.read8(vga_mod.VRAM_PHYS + src_off);
    h.write8(vga_mod.VRAM_PHYS + dst_off, 0x00);

    for (seed, 0..) |b, p| {
        try std.testing.expectEqual(b, v.vram[p * PLANE + dst_off]);
    }
}

test "Write mode 0: partial Bit-Mask + XOR ALU produces the spec result" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    const off: u32 = 42;
    // Seed plane 0 with a known latch background.
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x01); // Map-Mask = plane 0 only
    h.write8(vga_mod.VRAM_PHYS + off, 0b1010_1010);

    // Load the latch with that value (a read latches the planes).
    _ = h.read8(vga_mod.VRAM_PHYS + off);
    try std.testing.expectEqual(@as(u8, 0b1010_1010), v.latch[0]);

    // Configure WM0 with: ALU=XOR (GC idx3 bits4:3=11 → 0x18), Bit-Mask=0x0F.
    v.out8(0x3CE, 0x03);
    v.out8(0x3CF, 0x18); // data rotate 0, function select XOR
    v.out8(0x3CE, 0x08);
    v.out8(0x3CF, 0x0F); // Bit Mask = low nibble only
    // GC idx 5 write mode 0 (default), Enable-Set/Reset = 0 (host data).
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x00);

    // Write v=0xFF. Per §2.1: src=0xFF; res = 0xFF ^ latch = 0x55; out = (0x55 & 0x0F)
    // | (latch & ~0x0F) = 0x05 | 0xA0 = 0xA5.
    h.write8(vga_mod.VRAM_PHYS + off, 0xFF);
    try std.testing.expectEqual(@as(u8, 0xA5), v.vram[0 * PLANE + off]);
}

test "F2 fast path == full pipeline on fuzzed configs (byte-identical VRAM)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const h = v.memHandler();

    // A small deterministic LCG over (dataRotate, enableSetReset, alu, bitMask,
    // mapMask, value, latch). For each config, run BOTH the trivial fast path (when
    // applicable) AND the full pipeline by forcing it, and compare. We compare the
    // engine's chosen path against a hand-rolled full-pipeline reference.
    var seed: u32 = 0x1234_5678;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const data_rotate: u3 = @truncate(seed >> 3);
        const esr: u4 = @truncate(seed >> 6);
        const alu_code: u2 = @truncate(seed >> 10);
        const bit_mask: u8 = @truncate(seed >> 12);
        const map_mask: u4 = @truncate(seed >> 20);
        const set_reset: u4 = @truncate(seed >> 24);
        const value: u8 = @truncate(seed >> 1);
        const latch0: u8 = @truncate(seed >> 9 ^ seed);

        setUnchainedPlanar(v);
        // Program the registers via the real ports (drives recomputeWriteConfig).
        v.out8(0x3CE, 0x00);
        v.out8(0x3CF, set_reset); // Set/Reset
        v.out8(0x3CE, 0x01);
        v.out8(0x3CF, esr); // Enable Set/Reset
        v.out8(0x3CE, 0x03);
        v.out8(0x3CF, (@as(u8, alu_code) << 3) | data_rotate); // rotate + ALU
        v.out8(0x3CE, 0x05);
        v.out8(0x3CF, 0x00); // write mode 0
        v.out8(0x3CE, 0x08);
        v.out8(0x3CF, bit_mask); // Bit Mask
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, map_mask); // Map Mask

        const off: u32 = 1000;
        // Seed each plane's latch + storage deterministically.
        var latches: [4]u8 = undefined;
        for (0..4) |p| {
            latches[p] = latch0 +% @as(u8, @intCast(p)) *% 37;
            v.vram[p * PLANE + off] = latches[p];
        }
        // Compute the hand-rolled full-pipeline reference (§2.1).
        var expect: [4]u8 = latches;
        const b = std.math.rotr(u8, value, @as(u32, data_rotate));
        const alu: vga_mod.AluOp = @enumFromInt(alu_code);
        for (0..4) |p| {
            if ((map_mask & (@as(u4, 1) << @intCast(p))) == 0) continue;
            const src: u8 = if ((esr & (@as(u4, 1) << @intCast(p))) != 0)
                (if ((set_reset & (@as(u4, 1) << @intCast(p))) != 0) @as(u8, 0xFF) else 0x00)
            else
                b;
            const res: u8 = switch (alu) {
                .replace => src,
                .@"and" => src & latches[p],
                .@"or" => src | latches[p],
                .xor => src ^ latches[p],
            };
            expect[p] = (res & bit_mask) | (latches[p] & ~bit_mask);
        }

        // The engine must produce `expect` whether or not it took the F2 shortcut.
        // (Set the latch fields directly — a read would clobber them; here we want
        // exactly the seeded latches to drive the write arithmetic.)
        v.latch = latches;
        h.write8(vga_mod.VRAM_PHYS + off, value);
        for (0..4) |p| {
            try std.testing.expectEqual(expect[p], v.vram[p * PLANE + off]);
        }
    }
}

test "F2 fast path == forced full pipeline on trivial-eligible configs" {
    // The fuzz test above validates the FULL pipeline (writeMode0) against a
    // hand-rolled reference, but a random config almost never satisfies the
    // trivial predicate, so the F2 shortcut itself is rarely exercised. This test
    // closes that gap directly (§2.6): for trivial-ELIGIBLE inputs it runs the SAME
    // inputs through BOTH the F2 shortcut (wc.trivial=true) and the forced full
    // pipeline (wc.trivial=false → writeMode0) and asserts byte-identical VRAM.
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const h = v.memHandler();

    var seed: u32 = 0x0BAD_F00D;
    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const map_mask: u4 = @truncate(seed >> 20);
        const value: u8 = @truncate(seed >> 1);
        const latch0: u8 = @truncate((seed >> 9) ^ seed);
        var latches: [4]u8 = undefined;
        for (0..4) |p| latches[p] = latch0 +% @as(u8, @intCast(p)) *% 37;

        setUnchainedPlanar(v);
        // Program a TRIVIAL-eligible write-mode-0 config via the real ports:
        // Set/Reset=0, Enable-Set/Reset=0, rotate=0+ALU=replace, write mode 0,
        // Bit Mask=0xFF, random Map Mask. recomputeWriteConfig sets trivial=true.
        v.out8(0x3CE, 0x00);
        v.out8(0x3CF, 0x00); // Set/Reset = 0
        v.out8(0x3CE, 0x01);
        v.out8(0x3CF, 0x00); // Enable Set/Reset = 0
        v.out8(0x3CE, 0x03);
        v.out8(0x3CF, 0x00); // rotate=0, ALU=replace
        v.out8(0x3CE, 0x05);
        v.out8(0x3CF, 0x00); // write mode 0
        v.out8(0x3CE, 0x08);
        v.out8(0x3CF, 0xFF); // Bit Mask = 0xFF
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, map_mask); // Map Mask
        try std.testing.expect(v.wc.trivial); // precondition: shortcut would fire

        const off_a: u32 = 1000; // F2 fast path lands here
        const off_b: u32 = 2000; // forced full pipeline lands here
        for (0..4) |p| {
            v.vram[p * PLANE + off_a] = latches[p];
            v.vram[p * PLANE + off_b] = latches[p];
        }

        // Path A — the F2 shortcut (trivial=true from the port programming above).
        v.latch = latches;
        h.write8(vga_mod.VRAM_PHYS + off_a, value);

        // Path B — force the FULL pipeline (writeMode0) on the identical config.
        v.wc.trivial = false;
        v.latch = latches;
        h.write8(vga_mod.VRAM_PHYS + off_b, value);

        // The two code paths must produce byte-identical VRAM, every plane.
        for (0..4) |p| {
            try std.testing.expectEqual(v.vram[p * PLANE + off_a], v.vram[p * PLANE + off_b]);
        }
    }
}

test "latch snapshot round-trips" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    v.latch = .{ 0xDE, 0xAD, 0xBE, 0xEF };
    const snap = v.snapshot();
    v.reset();
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, v.latch);
    v.restore(snap);
    try std.testing.expectEqual([4]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, v.latch);
}

test "peek purity: memPeek8 mutates neither the latches nor any field" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    // Seed plane 2 and select it for reads.
    const off: u32 = 64;
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x04);
    h.write8(vga_mod.VRAM_PHYS + off, 0x77);
    v.out8(0x3CE, 0x04);
    v.out8(0x3CF, 0x02); // Read-Map-Select = plane 2

    const before = v.snapshot();
    const peeked = h.peek8(vga_mod.VRAM_PHYS + off);
    const after = v.snapshot();
    try std.testing.expectEqual(@as(?u8, 0x77), peeked);
    // A peek must NOT load the latches or change any snapshot-covered field.
    try std.testing.expectEqualSlices(u8, &before.latch, &after.latch);
    try std.testing.expect(std.meta.eql(before, after));
}

test "no mode-13h regression: chained linear write/read + fast path unchanged" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // Power-on default is chained (mode 13h). The fast path is still present.
    try std.testing.expect(v.chained());
    const h = v.memHandler();
    const page = vga_mod.VRAM_PHYS >> 12;
    try std.testing.expect(h.hostPtr(page) != null); // chained → host pointer present

    // Linear write/read still land at vram[off] (plane 0's region), untouched.
    h.write8(vga_mod.VRAM_PHYS + 100, 0x2A);
    try std.testing.expectEqual(@as(u8, 0x2A), v.vram[100]);
    try std.testing.expectEqual(@as(u8, 0x2A), h.read8(vga_mod.VRAM_PHYS + 100));
    try std.testing.expectEqual(@as(u8, 0x2A), h.peek8(vga_mod.VRAM_PHYS + 100).?);
}

// ===========================================================================
// Phase 5a: the deferred memory-engine modes filled to full compliance —
// write modes 2 & 3, read mode 1 (color compare), and the odd/even planar
// decode. plans/vga-spec/02-memory-engine.md §2.3/§2.4/§3.2/§4.3.
// ===========================================================================

test "Write mode 2: low-bit plane fill + partial Bit-Mask + AND ALU (spec result)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    const off: u32 = 77;
    // Seed a distinct latch background in every plane (write each via WM0 first),
    // then load the latches with a read so WM2's ALU/merge sees them.
    const bg = [4]u8{ 0b1111_0000, 0b0000_1111, 0b1010_1010, 0b0101_0101 };
    for (bg, 0..) |b, p| {
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, @as(u8, 1) << @intCast(p));
        h.write8(vga_mod.VRAM_PHYS + off, b);
    }
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x0F); // Map-Mask = all four planes
    _ = h.read8(vga_mod.VRAM_PHYS + off); // load the 4 latches
    try std.testing.expectEqual(bg, v.latch);

    // Configure write mode 2 (GC idx5 bits1:0=10), ALU=AND (GC idx3 bits4:3=01 →
    // 0x08), Bit-Mask=0xF0 (only the high nibble passes from the result).
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x02); // write mode 2
    v.out8(0x3CE, 0x03);
    v.out8(0x3CF, 0x08); // rotate 0, ALU = AND (ignored-rotate is fine in WM2)
    v.out8(0x3CE, 0x08);
    v.out8(0x3CF, 0xF0); // Bit Mask = high nibble

    // Write v=0b0000_1010 → bit0=0, bit1=1, bit2=0, bit3=1. So src per plane:
    // p0=0x00, p1=0xFF, p2=0x00, p3=0xFF. res = src & latch; out = (res & 0xF0) |
    // (latch & 0x0F).
    const value: u8 = 0b0000_1010;
    h.write8(vga_mod.VRAM_PHYS + off, value);

    // Hand-rolled reference (§2.3).
    inline for (0..4) |p| {
        const src: u8 = if ((value >> p) & 1 != 0) 0xFF else 0x00;
        const res: u8 = src & bg[p];
        const out: u8 = (res & 0xF0) | (bg[p] & 0x0F);
        try std.testing.expectEqual(out, v.vram[p * PLANE + off]);
    }
}

test "Write mode 3: rotated CPU data forms the effective mask, color from Set/Reset" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    const off: u32 = 33;
    const bg = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    for (bg, 0..) |b, p| {
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, @as(u8, 1) << @intCast(p));
        h.write8(vga_mod.VRAM_PHYS + off, b);
    }
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x0F); // Map-Mask = all four planes
    _ = h.read8(vga_mod.VRAM_PHYS + off); // load latches
    try std.testing.expectEqual(bg, v.latch);

    // write mode 3 (GC idx5 bits1:0=11), Set/Reset = 0b1010 (planes 1,3 → 0xFF;
    // planes 0,2 → 0x00), Data-Rotate = 2, Bit-Mask = 0xCC.
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x03); // write mode 3
    v.out8(0x3CE, 0x00);
    v.out8(0x3CF, 0x0A); // Set/Reset = 0b1010
    v.out8(0x3CE, 0x03);
    v.out8(0x3CF, 0x02); // Data Rotate = 2 (ALU/function-select ignored in WM3)
    v.out8(0x3CE, 0x08);
    v.out8(0x3CF, 0xCC); // Bit Mask

    const value: u8 = 0b1001_0011;
    h.write8(vga_mod.VRAM_PHYS + off, value);

    // Hand-rolled reference (§2.4): rotated = ror(v,2); eff = rotated & 0xCC;
    // src = setReset[p] ? 0xFF : 0; out = (src & eff) | (latch & ~eff).
    const rotated = std.math.rotr(u8, value, @as(u32, 2));
    const eff: u8 = rotated & 0xCC;
    const set_reset: u8 = 0x0A;
    inline for (0..4) |p| {
        const src: u8 = if ((set_reset >> p) & 1 != 0) 0xFF else 0x00;
        const out: u8 = (src & eff) | (bg[p] & ~eff);
        try std.testing.expectEqual(out, v.vram[p * PLANE + off]);
    }
}

test "Read mode 1: color compare across planes, gated by Color Don't Care" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);
    const h = v.memHandler();

    // Seed the 4 planes at one offset with chosen bytes so each horizontal pixel
    // (the 4-bit value across planes at bit i) is known.
    const off: u32 = 200;
    const seed = [4]u8{ 0b1100_1010, 0b1010_0110, 0b0000_1111, 0b1111_0000 };
    for (seed, 0..) |b, p| {
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, @as(u8, 1) << @intCast(p));
        h.write8(vga_mod.VRAM_PHYS + off, b);
    }

    // Enable read mode 1 (GC idx5 bit3=1 → 0x08), Color Compare = 0x5 (0b0101),
    // Color Don't Care = 0b0111 (plane 3 is a don't-care → forced match).
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x08); // read mode 1, write mode 0
    v.out8(0x3CE, 0x02);
    v.out8(0x3CF, 0x05); // Color Compare
    v.out8(0x3CE, 0x07);
    v.out8(0x3CF, 0x07); // Color Don't Care (plane 3 ignored)

    const got = h.read8(vga_mod.VRAM_PHYS + off);

    // Hand-rolled reference (§3.2): for each bit i, build the 4-bit pixel; set the
    // result bit iff (pixel & dontCare) == (compare & dontCare).
    const compare: u8 = 0x05;
    const dont_care: u8 = 0x07;
    var expect: u8 = 0;
    inline for (0..8) |i| {
        var pixel: u8 = 0;
        inline for (0..4) |p| pixel |= ((seed[p] >> i) & 1) << p;
        if ((pixel & dont_care) == (compare & dont_care)) expect |= @as(u8, 1) << i;
    }
    try std.testing.expectEqual(expect, got);
    // The read still loaded all 4 latches (§3).
    try std.testing.expectEqual(seed, v.latch);
}

test "F2 trivial shortcut is gated to write-mode-0 identity only (not WM2/WM3)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setUnchainedPlanar(v);

    // An otherwise-identity config: rotate 0, ESR 0, ALU replace, Bit-Mask 0xFF.
    const setIdentity = struct {
        fn f(d: *Vga) void {
            d.out8(0x3CE, 0x00);
            d.out8(0x3CF, 0x00); // Set/Reset
            d.out8(0x3CE, 0x01);
            d.out8(0x3CF, 0x00); // Enable Set/Reset
            d.out8(0x3CE, 0x03);
            d.out8(0x3CF, 0x00); // rotate 0, ALU replace
            d.out8(0x3CE, 0x08);
            d.out8(0x3CF, 0xFF); // Bit Mask 0xFF
        }
    }.f;
    setIdentity(v);

    // write mode 0 with the identity config → trivial.
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x00);
    try std.testing.expect(v.wc.trivial);

    // write mode 2 → NOT trivial (even with the identity config).
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x02);
    try std.testing.expect(!v.wc.trivial);

    // write mode 3 → NOT trivial.
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x03);
    try std.testing.expect(!v.wc.trivial);

    // write mode 1 → NOT trivial.
    v.out8(0x3CE, 0x05);
    v.out8(0x3CF, 0x01);
    try std.testing.expect(!v.wc.trivial);
}

/// Put the device in ODD/EVEN planar mode (§4.3): SEQ Memory-Mode chain-4 clear
/// (bit3=0) AND odd/even bit2 CLEAR (→ odd/even-mode ACTIVE), extended-mem set.
/// Misc-Output EvenPageSelect (bit5) left clear (the `off|1` odd branch), GC-Misc
/// ChainOddMapsToEven (idx6 bit1) clear. Map-Mask all planes.
fn setOddEven(v: *Vga) void {
    v.out8(0x3C4, 0x04);
    v.out8(0x3C5, 0x02); // extended-mem set, odd/even bit2=0, chain-4 bit3=0
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x0F); // Map Mask = all planes
}

test "Odd/even decode: even/odd addrs hit plane pairs {0,2}/{1,3} at off&0xFFFE (EvenPageSelect)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setOddEven(v);
    // EvenPageSelect (Misc-Output bit 5) → the standard `off & 0xFFFE` case.
    v.out8(0x3C2, 0x20);
    try std.testing.expect(!v.chained());
    const h = v.memHandler();
    try std.testing.expectEqual(@as(?[*]u8, null), h.hostPtr(vga_mod.VRAM_PHYS >> 12));

    // A char/attr-style interleave: even cell @ off=10 (char), odd cell @ off=11
    // (attr). Both map to plane-offset 10 (off & 0xFFFE); even → planes {0,2},
    // odd → planes {1,3}.
    h.write8(vga_mod.VRAM_PHYS + 10, 0x41); // 'A' char → planes 0 & 2 @ poff 10
    h.write8(vga_mod.VRAM_PHYS + 11, 0x1F); // attr     → planes 1 & 3 @ poff 10

    try std.testing.expectEqual(@as(u8, 0x41), v.vram[0 * PLANE + 10]);
    try std.testing.expectEqual(@as(u8, 0x41), v.vram[2 * PLANE + 10]);
    try std.testing.expectEqual(@as(u8, 0x1F), v.vram[1 * PLANE + 10]);
    try std.testing.expectEqual(@as(u8, 0x1F), v.vram[3 * PLANE + 10]);

    // Read-back: even addr → read plane (off&1)=0 → 0x41; odd addr → plane 1 → 0x1F.
    try std.testing.expectEqual(@as(u8, 0x41), h.read8(vga_mod.VRAM_PHYS + 10));
    try std.testing.expectEqual(@as(u8, 0x1F), h.read8(vga_mod.VRAM_PHYS + 11));
    // peek mirrors the read decode without latching.
    try std.testing.expectEqual(@as(?u8, 0x41), h.peek8(vga_mod.VRAM_PHYS + 10));
    try std.testing.expectEqual(@as(?u8, 0x1F), h.peek8(vga_mod.VRAM_PHYS + 11));
}

test "Odd/even decode: default (no EvenPageSelect) uses off|1; Map-Mask further gates planes" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    setOddEven(v); // EvenPageSelect clear → the `off | 1` branch
    const h = v.memHandler();

    // Gate the write further with Map-Mask = plane 0 only: an even write should hit
    // ONLY plane 0 (plane 2 is in plane_set but masked off).
    v.out8(0x3C4, 0x02);
    v.out8(0x3C5, 0x01); // Map Mask = plane 0
    // even off=20 → plane_set {0,2}; off|1 = 21 plane-offset.
    h.write8(vga_mod.VRAM_PHYS + 20, 0x99);
    try std.testing.expectEqual(@as(u8, 0x99), v.vram[0 * PLANE + 21]);
    try std.testing.expectEqual(@as(u8, 0), v.vram[2 * PLANE + 21]); // masked off
    try std.testing.expectEqual(@as(u8, 0), v.vram[0 * PLANE + 20]); // off|1 fixup applied
}

// ---------------------------------------------------------------------------
// Rasterizer (Phase 4, plans/vga-spec/03 §3.5/§3.7). PURE-render tests over a
// bare Vga: the index image, the DAC→RGBA pass, and the Mode-X de-interleave.
// ---------------------------------------------------------------------------

const vga_render = devices.vga_render;

test "DAC 6->8 expansion is bit-replication (c<<2)|(c>>4)" {
    try std.testing.expectEqual(@as(u8, 0), vga_render.expand6to8(0));
    try std.testing.expectEqual(@as(u8, 255), vga_render.expand6to8(63));
    try std.testing.expectEqual(@as(u8, 130), vga_render.expand6to8(32));
    try std.testing.expectEqual(@as(u8, 4), vga_render.expand6to8(1));
    // Values above 6 bits are masked to 6 bits first.
    try std.testing.expectEqual(@as(u8, 255), vga_render.expand6to8(0xFF));
}

test "mode 13h capture: index == VRAM bytes, RGBA == DAC->6->8" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // chained (mode 13h) by default. Write a known pattern + a known palette.
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) v.vram[i] = @truncate(i * 7 + 3);
    // Palette: entry k = (k mod 64, (k*2) mod 64, (k*3) mod 64) 6-bit.
    var k: u16 = 0;
    while (k < 256) : (k += 1) {
        v.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = @truncate((k *% 2) & 0x3F), .blue = @truncate((k *% 3) & 0x3F) };
    }
    var index: [320 * 200]u8 = undefined;
    var rgba: [320 * 200 * 4]u8 = undefined;
    const mv: vga_render.ModeView = .{ .mode = 0x13 };
    const d = vga_render.render(v, mv, &index);
    try std.testing.expectEqual(vga_render.Kind.vga256_linear, d.kind);
    try std.testing.expectEqual(@as(u16, 320), d.width);
    try std.testing.expectEqual(@as(u16, 200), d.height);
    // Index image == the raw VRAM bytes.
    try std.testing.expectEqualSlices(u8, v.vram[0 .. 320 * 200], index[0..]);
    // RGBA == DAC[index]→6→8.
    vga_render.indexToRgba(v, index[0..], rgba[0..]);
    var p: u32 = 0;
    while (p < 320 * 200) : (p += 1) {
        const idx = index[p];
        try std.testing.expectEqual(vga_render.expand6to8(v.dac_rgb[idx].red), rgba[p * 4 + 0]);
        try std.testing.expectEqual(vga_render.expand6to8(v.dac_rgb[idx].green), rgba[p * 4 + 1]);
        try std.testing.expectEqual(vga_render.expand6to8(v.dac_rgb[idx].blue), rgba[p * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 0xFF), rgba[p * 4 + 3]);
    }
}

test "Mode-X capture: de-interleave round-trips the planar write decode" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // Mode-X: SEQ Memory Mode = 0x06 — chain-4 off (bit 3 clear) AND odd/even off
    // (bit 2 set, sequential addressing). This is the real Mode-X sequencer setup;
    // it keeps the planar write engine on its simple-planar path (no odd/even assert).
    v.out8(0x3C4, 0x04);
    v.out8(0x3C5, 0x06);
    try std.testing.expect(!v.chained());
    // Program Offset = 40 words (320-wide Mode-X): the render's per-row plane stride
    // is offset*2 = 80 = width/4 plane bytes.
    v.out8(0x3D4, 0x13);
    v.out8(0x3D5, 40);
    // Write a known value at (x,y) via the Phase-3 planar engine (Map-Mask = the one
    // target plane), reading back through the render de-interleave.
    const W: u32 = 320;
    // Place a sentinel at several (x,y); the engine fans the byte to the masked plane.
    const pts = [_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 1 }, .{ 3, 5 }, .{ 17, 9 }, .{ 319, 199 } };
    const h = v.memHandler();
    for (pts, 0..) |pt, n| {
        const x = pt[0];
        const y = pt[1];
        const plane: u8 = @intCast(x & 3);
        const addr = 40 * 2 * y + (x >> 2); // start=0, stride=offset*2=80, plane byte
        // Set Map Mask to only this plane, write the byte through the engine.
        v.out8(0x3C4, 0x02);
        v.out8(0x3C5, @as(u8, 1) << @intCast(plane));
        const val: u8 = @truncate(0x40 + n);
        h.write8(vga_mod.VRAM_PHYS + addr, val);
    }
    var index: [W * 200]u8 = undefined;
    const mv: vga_render.ModeView = .{ .mode = 0x13 };
    const d = vga_render.render(v, mv, &index);
    try std.testing.expectEqual(vga_render.Kind.vga256_planar, d.kind);
    for (pts, 0..) |pt, n| {
        const x = pt[0];
        const y = pt[1];
        const val: u8 = @truncate(0x40 + n);
        try std.testing.expectEqual(val, index[y * W + x]);
    }
}

test "capture is cycle-neutral + pure (snapshot byte-identical, no field mutation)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var cycles: u64 = 123_456;
    v.cycles = &cycles;
    // Seed VRAM + palette so the render does real work.
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) v.vram[i] = @truncate(i);
    var k: u16 = 0;
    while (k < 256) : (k += 1) v.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 1, .blue = 2 };
    const before = v.snapshot();
    var index: [640 * 480]u8 = undefined;
    const mv: vga_render.ModeView = .{ .mode = 0x13 };
    _ = vga_render.render(v, mv, &index);
    var rgba: [320 * 200 * 4]u8 = undefined;
    vga_render.indexToRgba(v, index[0 .. 320 * 200], rgba[0..]);
    const after = v.snapshot();
    // The full device snapshot is byte-identical (DAC index / AC flip-flop / latch /
    // every field unchanged), and the cycle source did not advance.
    try std.testing.expect(std.meta.eql(before, after));
    try std.testing.expectEqual(@as(u64, 123_456), cycles);
}

test "two-run determinism: same state -> byte-identical index + RGBA" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) v.vram[i] = @truncate(i * 5 + 1);
    var k: u16 = 0;
    while (k < 256) : (k += 1) v.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = @truncate(k & 0x1F), .blue = 7 };
    var idx1: [320 * 200]u8 = undefined;
    var idx2: [320 * 200]u8 = undefined;
    var rgba1: [320 * 200 * 4]u8 = undefined;
    var rgba2: [320 * 200 * 4]u8 = undefined;
    const mv: vga_render.ModeView = .{ .mode = 0x13 };
    _ = vga_render.render(v, mv, &idx1);
    vga_render.indexToRgba(v, idx1[0..], rgba1[0..]);
    _ = vga_render.render(v, mv, &idx2);
    vga_render.indexToRgba(v, idx2[0..], rgba2[0..]);
    try std.testing.expectEqualSlices(u8, idx1[0..], idx2[0..]);
    try std.testing.expectEqualSlices(u8, rgba1[0..], rgba2[0..]);
}

test "text-mode render: glyph pixels from the ROM font + AC colors" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // A minimal 8x16 font: char 'A' (0x41) = a solid top row, blank elsewhere; the
    // attribute pipeline maps fg index 0x0F→DAC, bg index 0x00→DAC via AC palette.
    var font: [256 * 16]u8 = @splat(0);
    font[0x41 * 16 + 0] = 0xFF; // glyph 'A', scanline 0 = all 8 pixels lit
    // AC internal palette identity-ish: palette[0x0F] = 0x3F (fg dac), palette[0]=0.
    // Power-on AC palette regs are 0; set a couple so fg != bg.
    v.attr.regs[0x0F] = 0x2A; // fg internal value
    v.attr.regs[0x00] = 0x00; // bg internal value
    v.attr.regs[0x12] = 0x0F; // color-plane-enable all
    v.attr.regs[0x10] = 0x00; // mode control: no 5-4 select
    v.attr.regs[0x14] = 0x00; // color select 0
    // One cell: char 'A', attr 0x0F (fg=15, bg=0).
    var cells: [2]u8 = .{ 0x41, 0x0F };
    var index: [8 * 16]u8 = undefined;
    const mv: vga_render.ModeView = .{
        .mode = 0x03,
        .cols = 1,
        .rows = 1,
        .char_height = 16,
        .char_width = 8,
        .text_cells = cells[0..],
        .font = font[0..],
        .cursor_visible = false,
    };
    const d = vga_render.render(v, mv, &index);
    try std.testing.expectEqual(vga_render.Kind.text, d.kind);
    try std.testing.expectEqual(@as(u16, 8), d.width);
    try std.testing.expectEqual(@as(u16, 16), d.height);
    // Scanline 0: all 8 pixels are fg (acResolve(0x0F)); scanline 1: all bg.
    const fg = index[0]; // top-left pixel
    const bg = index[8]; // (x=0, y=1)
    try std.testing.expect(fg != bg);
    var x: u32 = 0;
    while (x < 8) : (x += 1) try std.testing.expectEqual(fg, index[x]);
    x = 0;
    while (x < 8) : (x += 1) try std.testing.expectEqual(bg, index[8 + x]); // y=1 row (width=8)
}

// ===========================================================================
// Phase 5b: line-compare split, pixel panning, 9-dot text, EGA/CGA round-trips.
// plans/vga-spec/03 §2.4 / §2.6 / §3.1 / §3.3 / §3.4.
// ===========================================================================

/// Program the CRTC line-compare to a raster line via the raw register fields (the
/// render reads `lineCompare()` = idx 0x18 | overflow-b8 | maxscan-b9). `lc` is the
/// 10-bit raster value; the bottom split begins at raster lc+1.
fn setLineCompare(v: *Vga, lc: u16) void {
    v.crtc.regs[0x18] = @truncate(lc & 0xFF);
    v.crtc.regs[0x07] = (v.crtc.regs[0x07] & ~@as(u8, 0x10)) | (@as(u8, @truncate((lc >> 8) & 1)) << 4);
    v.crtc.regs[0x09] = (v.crtc.regs[0x09] & ~@as(u8, 0x40)) | (@as(u8, @truncate((lc >> 9) & 1)) << 6);
}

test "line-compare split (mode 13h): top from start-address, bottom from offset 0" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const W: u32 = 320;
    const H: u32 = 200;
    // Top split renders from start_address; bottom from VRAM offset 0. Program a
    // start address (in WORDS; byte base = start*2) that points past offset 0 so the
    // two regions read DISTINCT data. start = 0x4000 words -> byte base 0x8000.
    const start_words: u16 = 0x4000;
    const start_bytes: u32 = @as(u32, start_words) * 2; // 0x8000
    v.crtc.regs[0x0C] = @truncate(start_words >> 8);
    v.crtc.regs[0x0D] = @truncate(start_words & 0xFF);
    // Fill offset-0 region with 0x11, the start-address region with 0x22.
    @memset(v.vram[0 .. start_bytes + W * H], 0x11);
    @memset(v.vram[start_bytes .. start_bytes + W * H], 0x22);
    // Split mid-screen: bottom begins at raster line 101 (row_repeat = 1 here since
    // CRTC 0x09 low bits = 0). With logical=raster the threshold logical row = 101.
    const lc: u16 = 100;
    setLineCompare(v, lc);
    // row_repeat: default 0x09 low bits 0 -> 1. splitLogicalRow = (100+1)/1 = 101.
    var index: [W * H]u8 = undefined;
    const d = vga_render.render(v, .{ .mode = 0x13 }, &index);
    try std.testing.expectEqual(vga_render.Kind.vga256_linear, d.kind);
    // Rows [0,101) come from start-address (0x22); rows [101,200) from offset 0 (0x11).
    try std.testing.expectEqual(@as(u8, 0x22), index[0]);
    try std.testing.expectEqual(@as(u8, 0x22), index[100 * W]);
    try std.testing.expectEqual(@as(u8, 0x11), index[101 * W]);
    try std.testing.expectEqual(@as(u8, 0x11), index[199 * W]);
}

test "pixel panning 256-color: image shifts left by pan*2" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const W: u32 = 320;
    // Distinct per-column data on row 0: vram[x] = x. A pan of N shifts left by N*2
    // (256-color honors bits 2-0, doubled, §2.6): output[x] == source[x + pan*2].
    var x: u32 = 0;
    while (x < W) : (x += 1) v.vram[x] = @truncate(x);
    // AC 0x13 = 3 -> pan*2 = 6. (Set raw; the render reads pixelPan().)
    v.attr.regs[0x13] = 3;
    var index: [W * 200]u8 = undefined;
    _ = vga_render.render(v, .{ .mode = 0x13 }, &index);
    // output[x] == source[x+6] for x where x+6 < W.
    try std.testing.expectEqual(@as(u8, @truncate(@as(u32, 0 + 6))), index[0]);
    try std.testing.expectEqual(@as(u8, @truncate(@as(u32, 10 + 6))), index[10]);
    try std.testing.expectEqual(@as(u8, @truncate(@as(u32, 100 + 6))), index[100]);
}

test "pixel panning planar (EGA): image shifts left by pan (all 4 bits)" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const W: u32 = 320;
    // EGA: encode a single lit pixel in plane 0 at x = 8 (byte 1, bit 7). With pan = 3
    // (planar honors all 4 bits, §2.6) the lit pixel appears at output x = 8 - 3 = 5.
    v.vram[0 * PLANE + 1] = 0x80; // plane 0, byte 1 -> x=8 bit set
    v.attr.regs[0x13] = 3; // pan = 3 (planar -> shift left by 3)
    // Identity-ish AC so index4 maps to a distinguishable DAC index; plane-enable all.
    v.attr.regs[0x12] = 0x0F;
    v.attr.regs[0x10] = 0x00;
    v.attr.regs[0x14] = 0x00;
    var i: u8 = 0;
    while (i < 16) : (i += 1) v.attr.regs[i] = i; // AC palette identity
    var index: [W * 200]u8 = undefined;
    const d = vga_render.render(v, .{ .mode = 0x0D }, &index);
    try std.testing.expectEqual(vga_render.Kind.ega16, d.kind);
    // Pixel x=8 (index4 = 1) shows up at output x = 5 after panning by 3.
    const lit = index[5];
    try std.testing.expect(lit != index[0]); // the lit pixel moved to x=5
    // x=8 in the OUTPUT is now background (the lit source pixel moved left).
    try std.testing.expectEqual(index[0], index[8]);
}

test "9-dot text: 9th column replicates for line-graphics (0xC0-0xDF), bg otherwise" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // Font: every glyph row = 0x01 (only bit 0 set -> rightmost of the 8 columns lit).
    var font: [256 * 16]u8 = @splat(0x01);
    // AC: fg index 0x0F -> a nonzero DAC; bg index 0 -> 0. Distinguishable.
    v.attr.regs[0x0F] = 0x3F;
    v.attr.regs[0x00] = 0x00;
    v.attr.regs[0x12] = 0x0F;
    v.attr.regs[0x10] = 0x00;
    v.attr.regs[0x14] = 0x00;
    // Two cells: cell0 = a line-graphics char (0xC4), cell1 = a normal char ('A').
    var cells: [4]u8 = .{ 0xC4, 0x0F, 0x41, 0x0F };
    // 2 cells * 9 dots = 18 wide, 16 tall.
    var index: [18 * 16]u8 = undefined;
    const mv: vga_render.ModeView = .{
        .mode = 0x03,
        .cols = 2,
        .rows = 1,
        .char_height = 16,
        .char_width = 9,
        .text_cells = cells[0..],
        .font = font[0..],
        .cursor_visible = false,
    };
    const d = vga_render.render(v, mv, &index);
    try std.testing.expectEqual(@as(u16, 18), d.width);
    const fg = index[7]; // column 7 (bit 0) of cell0 is lit (glyph 0x01)
    const bg = index[0]; // column 0 of cell0 is bg
    try std.testing.expect(fg != bg);
    // Cell0 (line-graphics 0xC4): the 9th column (x=8) REPLICATES the rightmost lit bit.
    try std.testing.expectEqual(fg, index[8]);
    // Cell1 (normal 'A' at x=9..17): its 9th column (x = 9+8 = 17) is BACKGROUND, even
    // though bit 0 of the glyph is lit (col 9+7 = 16 is fg).
    try std.testing.expectEqual(fg, index[9 + 7]); // cell1 col 7 lit
    try std.testing.expectEqual(bg, index[9 + 8]); // cell1 col 8 (9th) = bg (not 0xC0-0xDF)
}

test "EGA 16-color round-trip: 4-plane -> 4-bit index -> AC -> DAC" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    const W: u32 = 320;
    const H: u32 = 200;
    // Hand-compute a known 4-bit index for pixel x=0 (bit 7 of byte 0 in each plane):
    // set planes {0,2} -> index4 = 0b0101 = 5. Pixel x=1 (bit 6): set plane 3 only ->
    // index4 = 0b1000 = 8.
    v.vram[0 * PLANE + 0] = 0b1000_0000; // plane0 bit7 -> x0 bit0
    v.vram[2 * PLANE + 0] = 0b1000_0000; // plane2 bit7 -> x0 bit2
    v.vram[3 * PLANE + 0] = 0b0100_0000; // plane3 bit6 -> x1 bit3
    // AC palette identity (internal[i] = i), no 5-4-select, color-select 0, plane-en all.
    var i: u8 = 0;
    while (i < 16) : (i += 1) v.attr.regs[i] = i;
    v.attr.regs[0x12] = 0x0F;
    v.attr.regs[0x10] = 0x00;
    v.attr.regs[0x14] = 0x00;
    // DAC: entry k = (k, k, k) so index -> RGBA is predictable.
    var k: u16 = 0;
    while (k < 256) : (k += 1) v.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = @truncate(k & 0x3F), .blue = @truncate(k & 0x3F) };
    var index: [W * H]u8 = undefined;
    var rgba: [W * H * 4]u8 = undefined;
    const d = vga_render.render(v, .{ .mode = 0x0D }, &index);
    try std.testing.expectEqual(vga_render.Kind.ega16, d.kind);
    // x0 -> index4 = 5 -> acResolve identity -> DAC index 5.
    try std.testing.expectEqual(@as(u8, 5), index[0]);
    // x1 -> index4 = 8 -> DAC index 8.
    try std.testing.expectEqual(@as(u8, 8), index[1]);
    // x2 onward -> index4 = 0.
    try std.testing.expectEqual(@as(u8, 0), index[2]);
    // RGBA: index 5 -> dac entry 5 -> expand6to8(5) on each channel.
    vga_render.indexToRgba(v, index[0..], rgba[0..]);
    try std.testing.expectEqual(vga_render.expand6to8(5), rgba[0]);
    try std.testing.expectEqual(vga_render.expand6to8(8), rgba[1 * 4]);
}

test "CGA round-trip: 2bpp (mode 4) + 1bpp (mode 6) packed decode -> palette -> DAC" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // AC palette identity + plane-enable all so acResolve(pix) == pix (pix in 0..3).
    var i: u8 = 0;
    while (i < 16) : (i += 1) v.attr.regs[i] = i;
    v.attr.regs[0x12] = 0x0F;
    v.attr.regs[0x10] = 0x00;
    v.attr.regs[0x14] = 0x00;
    var k: u16 = 0;
    while (k < 256) : (k += 1) v.dac_rgb[k] = .{ .red = @truncate(k & 0x3F), .green = 0, .blue = 0 };

    // --- 2bpp (mode 4), 320x200. Byte 0 of the EVEN bank (row 0) = 0b00_01_10_11 ->
    //     pixels 0,1,2,3 = 0,1,2,3 (MSB pair first, §3.3). ---
    @memset(v.vram[0..0x4000], 0);
    v.vram[0] = 0b00_01_10_11; // even bank (row 0), byte 0
    // Row 1 (ODD bank at 0x2000) byte 0 = 0b11_10_01_00 -> pixels 3,2,1,0.
    v.vram[0x2000] = 0b11_10_01_00;
    {
        var index: [320 * 200]u8 = undefined;
        const d = vga_render.render(v, .{ .mode = 0x04 }, &index);
        try std.testing.expectEqual(vga_render.Kind.cga, d.kind);
        try std.testing.expectEqual(@as(u16, 320), d.width);
        // Row 0 pixels 0..3 (even bank).
        try std.testing.expectEqual(@as(u8, 0), index[0]);
        try std.testing.expectEqual(@as(u8, 1), index[1]);
        try std.testing.expectEqual(@as(u8, 2), index[2]);
        try std.testing.expectEqual(@as(u8, 3), index[3]);
        // Row 1 pixels 0..3 (odd bank at 0x2000).
        try std.testing.expectEqual(@as(u8, 3), index[320 + 0]);
        try std.testing.expectEqual(@as(u8, 2), index[320 + 1]);
        try std.testing.expectEqual(@as(u8, 1), index[320 + 2]);
        try std.testing.expectEqual(@as(u8, 0), index[320 + 3]);
    }

    // --- 1bpp (mode 6), 640x200. Byte 0 of the even bank = 0b1010_0000 -> pixels
    //     0,2 lit; 1,3 clear (MSB first, §3.3). ---
    @memset(v.vram[0..0x4000], 0);
    v.vram[0] = 0b1010_0000;
    {
        var index: [640 * 200]u8 = undefined;
        const d = vga_render.render(v, .{ .mode = 0x06 }, &index);
        try std.testing.expectEqual(vga_render.Kind.cga, d.kind);
        try std.testing.expectEqual(@as(u16, 640), d.width);
        try std.testing.expectEqual(@as(u8, 1), index[0]);
        try std.testing.expectEqual(@as(u8, 0), index[1]);
        try std.testing.expectEqual(@as(u8, 1), index[2]);
        try std.testing.expectEqual(@as(u8, 0), index[3]);
    }
}

test "standard-mode path unchanged: line-compare disabled + pan=0 byte-identical" {
    const alloc = std.testing.allocator;
    const v = try makeVga(alloc);
    defer freeVga(alloc, v);
    // After reset/init the CRTC defaults disable line-compare (= 0x3FF) and AC 0x13
    // panning = 0. A mode-13h capture must be EXACTLY the raw VRAM bytes (the §0 rule).
    try std.testing.expectEqual(@as(u16, 0x3FF), v.lineCompare());
    try std.testing.expectEqual(@as(u8, 0), v.pixelPan());
    var i: u32 = 0;
    while (i < 320 * 200) : (i += 1) v.vram[i] = @truncate(i *% 7 + 3);
    var index: [320 * 200]u8 = undefined;
    const d = vga_render.render(v, .{ .mode = 0x13 }, &index);
    try std.testing.expectEqual(vga_render.Kind.vga256_linear, d.kind);
    try std.testing.expectEqualSlices(u8, v.vram[0 .. 320 * 200], index[0..]);
}
