//! BIOS tests (M1): POST lands the IVT + BDA + A20 + PIC/PIT; the curated BIOS INT
//! handlers (10h mode 13h, 16h keyboard buffer, 1Ah tick, 11h/12h, 08h tick bump)
//! work against the BDA; deferred INT 13h hits the D11 flag path. Each runs a
//! hand-assembled snippet through the FULL machine.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const bda_mod = @import("bios").Bda;

const Machine = machine_mod.Machine;
const Reg32 = cpu_mod.state.Reg32;

const CODE_SEG: u16 = 0x2000;

fn boot(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    return m;
}

fn loadCode(m: *Machine, code: []const u8) void {
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, CODE_SEG);
    m.cpu.loadSegment(.es, CODE_SEG);
    m.cpu.st.eflags.iff = true;
}

fn untilHalt(mm: *Machine) bool {
    return mm.cpu.st.halted;
}
fn run(m: *Machine) void {
    _ = m.runUntil(untilHalt, 100_000);
}

test "POST lands the IVT + BDA + A20 left disabled" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // A20 is NOT enabled by POST — real PC BIOS leaves it off so real-mode code
    // sees the 8086 1 MiB address wraparound (EXEPACK depends on this). Software
    // enables A20 explicitly via INT 15h AX=2401 / port 92h. (dosbox parity.)
    try std.testing.expect(!m.bus.a20Enabled());
    // INT 21h vector points at the F000 callback area (a real F000 pointer).
    const seg = m.bus.readPhys16(0x21 * 4 + 2);
    try std.testing.expectEqual(@as(u16, 0xF000), seg);
    // BDA: 640 KiB conventional memory, text video mode at boot.
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    try std.testing.expectEqual(@as(u16, 640), m.bus.readPhys16(0x400 + 0x13));
    try std.testing.expectEqual(@as(u8, 0x03), bda.videoMode());
}

test "INT 10h AH=00 set mode 13h updates the BDA video mode" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // MOV AX,0x0013 ; INT 0x10 ; HLT
    loadCode(m, &.{ 0xB8, 0x13, 0x00, 0xCD, 0x10, 0xF4 });
    run(m);
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    try std.testing.expectEqual(@as(u8, 0x13), bda.videoMode());
}

test "INT 16h reads a key enqueued into the BDA keyboard buffer" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Enqueue scancode:ascii 0x1E61 ('a') into the BDA ring (the INT 09h seam).
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    try std.testing.expect(bda.kbEnqueue(0x1E61));
    // AH=00 read key -> AX = the word.
    loadCode(m, &.{ 0xB4, 0x00, 0xCD, 0x16, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x1E61), m.cpu.st.getReg16(0));
}

test "INT 1Ah AH=00 returns the BDA tick (PIT-driven, not host clock)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    bda.setTickCount(0x00012345);
    // AH=00 INT 1Ah -> CX:DX = ticks.
    loadCode(m, &.{ 0xB4, 0x00, 0xCD, 0x1A, 0xF4 });
    run(m);
    const ticks = (@as(u32, m.cpu.st.getReg16(@intFromEnum(Reg32.ecx))) << 16) |
        m.cpu.st.getReg16(@intFromEnum(Reg32.edx));
    try std.testing.expectEqual(@as(u32, 0x00012345), ticks);
}

test "INT 11h / 12h return equipment + conventional memory from the BDA" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadCode(m, &.{ 0xCD, 0x11, 0xCD, 0x12, 0xF4 });
    // After INT 12h, AX = 640. (INT 11h ran first; INT 12h overwrites AX.)
    run(m);
    try std.testing.expectEqual(@as(u16, 640), m.cpu.st.getReg16(0));
}

test "INT 08h timer handler bumps the BDA tick" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    bda.setTickCount(100);
    loadCode(m, &.{ 0xCD, 0x08, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u32, 101), bda.tickCount());
}

test "INT 13h (deferred) hits the D11 unsupported flag path" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    machine_mod.Bios.last_unsupported = null;
    loadCode(m, &.{ 0xB4, 0x02, 0xCD, 0x13, 0xF4 }); // AH=02 read sectors (deferred)
    run(m);
    try std.testing.expect(machine_mod.Bios.last_unsupported != null);
    try std.testing.expectEqual(@as(u8, 0x13), machine_mod.Bios.last_unsupported.?.int);
}

// ---------------------------------------------------------------------------
// Text-mode video INT 10h services (P3-P5). The default boot mode is 0x03
// (80x25 color text), so the cells land in text_vram (B8000). Cell layout is
// flat {char,attr}: byte0 = char, byte1 = attr.
// ---------------------------------------------------------------------------

test "INT 10h AH=09 writes char+attr at the cursor (read back via B800 + AH=08)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // One snippet: set cursor (2,3); AH=09 write 'X' attr 0x1F; AH=08 read it back.
    //   AH=02 DX=0x0203 BH=0 (set cursor)
    //   AH=09 AL='X' BL=0x1F CX=1 (write char+attr, cursor unchanged)
    //   AH=08 BH=0 (read char+attr at cursor -> AL=char, AH=attr)
    loadCode(m, &.{
        0xB8, 0x00, 0x02, // MOV AX,0x0200
        0xBB, 0x00, 0x00, // MOV BX,0
        0xBA, 0x03, 0x02, // MOV DX,0x0203 (row=2,col=3)
        0xCD, 0x10, // INT 10h (AH=02)
        0xB8, 0x58, 0x09, // MOV AX,0x0958 (AH=09, AL='X')
        0xBB, 0x1F, 0x00, // MOV BX,0x001F (BL=attr 0x1F, BH=page 0)
        0xB9, 0x01, 0x00, // MOV CX,1
        0xCD, 0x10, // INT 10h (AH=09)
        0xB4, 0x08, // MOV AH,0x08
        0xCD, 0x10, // INT 10h (AH=08)
        0xF4, // HLT
    });
    run(m);
    // Cell (2,3) at B8000 + (2*80+3)*2 = 0xB8000 + 326.
    const at: u32 = 0xB8000 + (2 * 80 + 3) * 2;
    try std.testing.expectEqual(@as(u8, 'X'), m.bus.readPhys8(at));
    try std.testing.expectEqual(@as(u8, 0x1F), m.bus.readPhys8(at + 1));
    // AH=08 returned the same cell: AL='X', AH=0x1F.
    try std.testing.expectEqual(@as(u8, 'X'), m.cpu.st.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x1F), m.cpu.st.getReg8(4)); // AH
}

test "INT 10h AH=0A writes char only, preserving the attribute byte (F2)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Pre-set the attribute byte at cell (0,0) so we can prove AH=0A leaves it.
    m.bus.writePhys8(0xB8001, 0x4E);
    // Cursor (0,0); AH=0A AL='Q' BL=0x07 (ignored) CX=1.
    loadCode(m, &.{
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x00, 0x00, 0xCD, 0x10, // cursor (0,0)
        0xB8, 0x51, 0x0A, // MOV AX,0x0A51 (AH=0A, AL='Q')
        0xBB, 0x07, 0x00, // BL=0x07 (must be ignored)
        0xB9, 0x01, 0x00, // CX=1
        0xCD, 0x10, 0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 'Q'), m.bus.readPhys8(0xB8000));
    try std.testing.expectEqual(@as(u8, 0x4E), m.bus.readPhys8(0xB8001)); // untouched
}

test "INT 10h AH=0E teletype writes cells, advances + wraps the cursor" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Cursor (0,0); teletype 'H','i'. Cells (0,0)='H', (0,1)='i'; cursor -> (0,2).
    loadCode(m, &.{
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x00, 0x00, 0xCD, 0x10, // set cursor (0,0)
        0xB8, 0x48, 0x0E, 0xCD, 0x10, // MOV AX,0x0E48 ('H'); INT 10h
        0xB8, 0x69, 0x0E, 0xCD, 0x10, // MOV AX,0x0E69 ('i'); INT 10h
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 'H'), m.bus.readPhys8(0xB8000)); // cell (0,0)
    try std.testing.expectEqual(@as(u8, 'i'), m.bus.readPhys8(0xB8000 + 2)); // cell (0,1)
    // Cursor word at 0040:0050 = (row<<8)|col = 0x0002.
    try std.testing.expectEqual(@as(u16, 0x0002), m.bus.readPhys16(0x400 + 0x50));

    // CR resets col to 0; LF advances row (col unchanged) — on a fresh machine
    // (the previous one has halted; loadCode does not clear the halt flag).
    const m2 = try boot(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    loadCode(m2, &.{
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x02, 0x00, 0xCD, 0x10, // cursor (0,2)
        0xB8, 0x0D, 0x0E, 0xCD, 0x10, // CR -> col=0
        0xB8, 0x0A, 0x0E, 0xCD, 0x10, // LF -> row=1
        0xF4,
    });
    run(m2);
    try std.testing.expectEqual(@as(u16, 0x0100), m2.bus.readPhys16(0x400 + 0x50)); // (row=1,col=0)
}

test "INT 10h AH=0E end-of-screen scroll moves rows up, fills bottom with cursor attr" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Mark cell (1,0) so after one scroll-up it lands at (0,0). Put cursor at the
    // last row, last col with a known attr (0x1F) so the LF-driven scroll fills the
    // new bottom row with 0x1F, and the cursor stays on the last row.
    // Pre-write cell (1,0) = 'B' attr 0x07.
    m.bus.writePhys8(0xB8000 + (1 * 80 + 0) * 2, 'B');
    m.bus.writePhys8(0xB8000 + (1 * 80 + 0) * 2 + 1, 0x07);
    // Set cursor (24,0) with attr 0x1F via AH=09 (write a space attr there), then
    // teletype LF to force the scroll (row 24 -> 25 == nrows).
    loadCode(m, &.{
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x00, 0x18, 0xCD, 0x10, // cursor (24,0)
        0xB8, 0x20, 0x09, 0xBB, 0x1F, 0x00, 0xB9, 0x01, 0x00, 0xCD, 0x10, // AH=09 ' ' attr 0x1F at (24,0)
        0xB8, 0x0A, 0x0E, 0xCD, 0x10, // LF -> row 25 -> scroll up by 1
        0xF4,
    });
    run(m);
    // Old row 1 ('B') is now at row 0.
    try std.testing.expectEqual(@as(u8, 'B'), m.bus.readPhys8(0xB8000 + (0 * 80 + 0) * 2));
    // The new bottom row (24) is filled with space + the cursor's attr (0x1F).
    try std.testing.expectEqual(@as(u8, ' '), m.bus.readPhys8(0xB8000 + (24 * 80 + 0) * 2));
    try std.testing.expectEqual(@as(u8, 0x1F), m.bus.readPhys8(0xB8000 + (24 * 80 + 0) * 2 + 1));
    // Cursor stayed on the last row (row 24), col 0 (LF keeps col).
    try std.testing.expectEqual(@as(u16, (24 << 8) | 0), m.bus.readPhys16(0x400 + 0x50));
}

test "INT 10h AH=06 scroll-up window + AH=07 clear; AH=01/03 cursor-shape round-trip" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Fill cells (0,0)='0', (1,0)='1', (2,0)='2'. Scroll the window rows [0..2]
    // up by 1 (AH=06 AL=1): row1->row0, row2->row1, row2 filled with BH attr+space.
    m.bus.writePhys8(0xB8000 + (0 * 80) * 2, '0');
    m.bus.writePhys8(0xB8000 + (1 * 80) * 2, '1');
    m.bus.writePhys8(0xB8000 + (2 * 80) * 2, '2');
    // AH=06 AL=1 BH=0x4E CH=0 CL=0 DH=2 DL=0 (window rows 0..2, col 0..0).
    loadCode(m, &.{
        0xB8, 0x01, 0x06, // MOV AX,0x0601 (AH=06 AL=1)
        0xBB, 0x00, 0x4E, // MOV BX,0x4E00 (BH=0x4E fill attr)
        0xB9, 0x00, 0x00, // MOV CX,0x0000 (CH=0 CL=0 upper-left)
        0xBA, 0x00, 0x02, // MOV DX,0x0200 (DH=2 DL=0 lower-right)
        0xCD, 0x10, 0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, '1'), m.bus.readPhys8(0xB8000 + (0 * 80) * 2)); // row1 -> row0
    try std.testing.expectEqual(@as(u8, '2'), m.bus.readPhys8(0xB8000 + (1 * 80) * 2)); // row2 -> row1
    try std.testing.expectEqual(@as(u8, ' '), m.bus.readPhys8(0xB8000 + (2 * 80) * 2)); // filled
    try std.testing.expectEqual(@as(u8, 0x4E), m.bus.readPhys8(0xB8000 + (2 * 80) * 2 + 1)); // fill attr

    // AH=01 set cursor shape CX=0x0A0B, then AH=03 read it back in CX.
    const m2 = try boot(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    loadCode(m2, &.{
        0xB8, 0x01, 0x01, // MOV AX,0x0101 (AH=01)
        0xB9, 0x0B, 0x0A, // MOV CX,0x0A0B
        0xCD, 0x10,
        0xB8, 0x03, 0x03, // MOV AX,0x0303 (AH=03)
        0xBB, 0x00, 0x00, // BH=0
        0xCD, 0x10, 0xF4,
    });
    run(m2);
    try std.testing.expectEqual(@as(u16, 0x0A0B), m2.cpu.st.getReg16(1)); // CX = the set shape
}

test "INT 10h AH=00 set text mode 3 clears the page with a 0x0720 word fill (F6)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Dirty a couple of cells, then AH=00 mode 3 must clear them to 0x0720.
    m.bus.writePhys8(0xB8000, 'Z');
    m.bus.writePhys8(0xB8000 + (24 * 80 + 79) * 2, 'E'); // last cell
    loadCode(m, &.{ 0xB8, 0x03, 0x00, 0xCD, 0x10, 0xF4 }); // MOV AX,0x0003; INT 10h
    run(m);
    try std.testing.expectEqual(@as(u16, 0x0720), m.bus.readPhys16(0xB8000)); // ' ', attr 0x07
    try std.testing.expectEqual(@as(u16, 0x0720), m.bus.readPhys16(0xB8000 + (24 * 80 + 79) * 2));
    // BDA programmed: mode 3, 80 cols, rows-1 = 24.
    try std.testing.expectEqual(@as(u16, 80), m.bus.readPhys16(0x400 + 0x4A));
    try std.testing.expectEqual(@as(u8, 24), m.bus.readPhys8(0x400 + 0x84)); // OFF_NB_ROWS
}

test "INT 10h AH=13 write-string places a row; bit0=0 restores the entry cursor" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Put the string "Hey" at DS:0x600 (ES=DS=CODE_SEG), write it at (3,5) with
    // attr 0x1E, AL=0 (bit0=0 => restore cursor, bit1=0 => fixed attr).
    const str_off: u32 = 0x600;
    const base = (@as(u32, 0x2000) << 4) + str_off;
    m.bus.writePhys8(base + 0, 'H');
    m.bus.writePhys8(base + 1, 'e');
    m.bus.writePhys8(base + 2, 'y');
    // Set an entry cursor (10,10) so we can prove bit0=0 restores it.
    loadCode(m, &.{
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x0A, 0x0A, 0xCD, 0x10, // cursor (10,10)
        // AH=13 AL=0 BH=0 BL=0x1E CX=3 DH=3 DL=5 ES:BP -> string
        0xBD, 0x00, 0x06, // MOV BP,0x0600
        0xB8, 0x00, 0x13, // MOV AX,0x1300 (AH=13, AL=0)
        0xBB, 0x1E, 0x00, // MOV BX,0x001E (BL=attr 0x1E, BH=page 0)
        0xB9, 0x03, 0x00, // MOV CX,3
        0xBA, 0x05, 0x03, // MOV DX,0x0305 (DH=3 row, DL=5 col)
        0xCD, 0x10, 0xF4,
    });
    run(m);
    // Cells (3,5),(3,6),(3,7) = 'H','e','y' with attr 0x1E.
    const c0: u32 = 0xB8000 + (3 * 80 + 5) * 2;
    try std.testing.expectEqual(@as(u8, 'H'), m.bus.readPhys8(c0));
    try std.testing.expectEqual(@as(u8, 0x1E), m.bus.readPhys8(c0 + 1));
    try std.testing.expectEqual(@as(u8, 'e'), m.bus.readPhys8(c0 + 2));
    try std.testing.expectEqual(@as(u8, 'y'), m.bus.readPhys8(c0 + 4));
    // bit0=0 restored the entry cursor (10,10).
    try std.testing.expectEqual(@as(u16, (10 << 8) | 10), m.bus.readPhys16(0x400 + 0x50));
}

test "text-video DETERMINISM: same INT 10h sequence -> byte-identical text page (two fresh machines)" {
    const alloc = std.testing.allocator;
    // A fixed INT 10h text sequence: set mode 3 (clears page), set cursor, AH=13
    // write-string "Hi", AH=09 write a char, teletype a CR/LF + char, scroll.
    const prog = [_]u8{
        0xB8, 0x03, 0x00, 0xCD, 0x10, // AH=00 mode 3 (clear to 0x0720)
        0xB8, 0x00, 0x02, 0xBB, 0x00, 0x00, 0xBA, 0x05, 0x01, 0xCD, 0x10, // cursor (1,5)
        0xB8, 0x21, 0x09, 0xBB, 0x4F, 0x00, 0xB9, 0x02, 0x00, 0xCD, 0x10, // AH=09 '!' attr 0x4F x2
        0xB8, 0x41, 0x0E, 0xCD, 0x10, // teletype 'A'
        0xB8, 0x0D, 0x0E, 0xCD, 0x10, // CR
        0xB8, 0x0A, 0x0E, 0xCD, 0x10, // LF
        0xB8, 0x42, 0x0E, 0xCD, 0x10, // teletype 'B'
        // AH=06 scroll the top 3-row window up by 1 (fill attr 0x17).
        0xB8, 0x01, 0x06, 0xBB, 0x00,
        0x17, 0xB9, 0x00, 0x00, 0xBA,
        0x00, 0x02, 0xCD, 0x10, 0xF4,
    };

    const m1 = try boot(alloc);
    defer {
        m1.deinit();
        alloc.destroy(m1);
    }
    loadCode(m1, &prog);
    run(m1);

    const m2 = try boot(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    loadCode(m2, &prog);
    run(m2);

    // The text page (color B8000) is byte-identical across the two fresh machines.
    try std.testing.expectEqualSlices(u8, m1.vga.text_vram, m2.vga.text_vram);
    try std.testing.expectEqualSlices(u8, m1.vga.text_vram_mono, m2.vga.text_vram_mono);
    // And the BDA video state (mode/cols/rows/cursor) matches too.
    try std.testing.expectEqual(m1.bus.readPhys16(0x400 + 0x50), m2.bus.readPhys16(0x400 + 0x50));
    try std.testing.expectEqual(m1.bus.readPhys8(0x400 + 0x49), m2.bus.readPhys8(0x400 + 0x49));
}

test "no host-time / RNG / thread in the BIOS sources (grep, Phase 9)" {
    const sources = [_][]const u8{
        @embedFile("bios.zig"),
        @embedFile("bda.zig"),
        @embedFile("int10.zig"),
        @embedFile("vga_rom.zig"),
        @embedFile("int16.zig"),
        @embedFile("int1a.zig"),
        @embedFile("int08.zig"),
        @embedFile("int11_12.zig"),
        @embedFile("int15.zig"),
    };
    const needles = [_][]const u8{
        &[_]u8{ 's', 't', 'd', '.', 't', 'i', 'm', 'e' },
        &[_]u8{ 's', 't', 'd', '.', 'R', 'a', 'n', 'd', 'o', 'm' },
        &[_]u8{ 's', 't', 'd', '.', 'T', 'h', 'r', 'e', 'a', 'd' },
        &[_]u8{ 'g', 'e', 't', 'e', 'n', 'v' },
    };
    for (sources) |src| {
        for (needles) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) return error.ForbiddenHostDependence;
        }
    }
}

const bda_off_dcc: u16 = 0x8A;

test "INT 10h AH=1A00 returns AX=0x1A, BL=0x08 (VGA color)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AH=1A, AL=00 (get DCC). MOV AX,0x1A00 ; INT 0x10 ; HLT.
    loadCode(m, &.{ 0xB8, 0x00, 0x1A, 0xCD, 0x10, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x1A), m.cpu.st.getReg16(0)); // AX = 0x1A
    try std.testing.expectEqual(@as(u8, 0x08), m.cpu.st.getReg8(3)); // BL = active DCC = 0x08
    try std.testing.expectEqual(@as(u8, 0x00), m.cpu.st.getReg8(7)); // BH = 0
}

test "INT 10h AH=1A01 stores the DCC byte; a later get returns it" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AH=1A AL=01 (set), BL=0x0C ; then AH=1A AL=00 (get) ; HLT.
    loadCode(m, &.{
        0xB8, 0x01, 0x1A, // MOV AX,0x1A01
        0xB3, 0x0C, // MOV BL,0x0C
        0xCD, 0x10, // INT 0x10
        0xB8, 0x00, 0x1A, // MOV AX,0x1A00
        0xCD, 0x10, // INT 0x10
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x0C), m.bus.readPhys8(0x400 + bda_off_dcc));
    try std.testing.expectEqual(@as(u8, 0x0C), m.cpu.st.getReg8(3)); // BL from the get
}

test "INT 10h AH=1130 BH=03 returns ES:BP at the staged ROM 8x8 font" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // MOV AX,0x1130 ; MOV BH,0x03 ; INT 0x10 ; HLT.
    loadCode(m, &.{ 0xB8, 0x30, 0x11, 0xB7, 0x03, 0xCD, 0x10, 0xF4 });
    run(m);
    const es = m.cpu.st.selector[@intFromEnum(cpu_mod.state.Seg.es)];
    const bp = m.cpu.st.getReg16(@intFromEnum(Reg32.ebp));
    const phys = (@as(u32, es) << 4) + bp;
    // The far pointer must address the staged 8x8 font; verify the first glyph (NUL,
    // all-zero) and glyph 'A' (0x41) match the dosbox int10_font_08 reference.
    for (0..8) |k| try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8(phys + @as(u32, @intCast(k))));
    const want_A = [_]u8{ 0x30, 0x78, 0xcc, 0xcc, 0xfc, 0xcc, 0xcc, 0x00 };
    for (want_A, 0..) |b, k| {
        try std.testing.expectEqual(b, m.bus.readPhys8(phys + 0x41 * 8 + @as(u32, @intCast(k))));
    }
    // CX = BDA CHAR_HEIGHT (boot text = 16), DL = NB_ROWS (24).
    try std.testing.expectEqual(@as(u16, 16), m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
    try std.testing.expectEqual(@as(u8, 24), m.cpu.st.getReg8(2)); // DL
}

test "INT 10h AH=00 set mode 13h dumps the §1.2 register block + DAC palette + BDA" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadCode(m, &.{ 0xB8, 0x13, 0x00, 0xCD, 0x10, 0xF4 });
    run(m);
    // SEQ7 = {03,01,0f,00,0e}.
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x01, 0x0f, 0x00, 0x0e }, &m.vga.seq.regs);
    // CRTC[9] = 0x41 (S1: max-scan-line low + line-compare bit9, NOT double-scan).
    try std.testing.expectEqual(@as(u8, 0x41), m.vga.crtc.regs[9]);
    // GFX[5] = 0x40 (256-color shift).
    try std.testing.expectEqual(@as(u8, 0x40), m.vga.gfx.regs[5]);
    // AC[0x10] = 0x41 (8-bit color mode reg).
    try std.testing.expectEqual(@as(u8, 0x41), m.vga.attr.regs[0x10]);
    // misc-output = 0x63.
    try std.testing.expectEqual(@as(u8, 0x63), m.vga.misc_output);
    // Default 256-color DAC palette: entry 0 = black, entry 1 = {0,0,0x2a} (VGA[1]).
    try std.testing.expectEqual(@as(u8, 0x00), m.vga.dac_rgb[0].red);
    try std.testing.expectEqual(@as(u8, 0x2a), m.vga.dac_rgb[1].blue);
    try std.testing.expectEqual(@as(u8, 0x3f), m.vga.dac_rgb[0xF].red); // VGA[15] = {3f,3f,3f}
    // BDA: mode, cols, page size, cheight, video-ctl.
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    try std.testing.expectEqual(@as(u8, 0x13), bda.videoMode());
    try std.testing.expectEqual(@as(u16, 40), m.bus.readPhys16(0x400 + 0x4A));
    try std.testing.expectEqual(@as(u16, 0x2000), m.bus.readPhys16(0x400 + 0x4C));
    try std.testing.expectEqual(@as(u16, 8), m.bus.readPhys16(0x400 + 0x85));
    try std.testing.expectEqual(@as(u8, 0x60), m.bus.readPhys8(0x400 + 0x87)); // clearmem => 0x60
}

test "INT 10h AH=00 set text mode 3 dumps the text register block + BDA (existing text behavior preserved)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadCode(m, &.{ 0xB8, 0x03, 0x00, 0xCD, 0x10, 0xF4 });
    run(m);
    // SEQ2 = {03,00,03,00,02}; misc-output 0x67.
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0x03, 0x00, 0x02 }, &m.vga.seq.regs);
    try std.testing.expectEqual(@as(u8, 0x67), m.vga.misc_output);
    // CRTC2[9] = 0x4f.
    try std.testing.expectEqual(@as(u8, 0x4f), m.vga.crtc.regs[9]);
    // BDA: 80 cols, 0x1000 page, cheight 16, rows-1 = 24, mode 3.
    const bda = bda_mod(machine_mod.Cpu).init(&m.cpu);
    try std.testing.expectEqual(@as(u8, 0x03), bda.videoMode());
    try std.testing.expectEqual(@as(u16, 80), m.bus.readPhys16(0x400 + 0x4A));
    try std.testing.expectEqual(@as(u16, 0x1000), m.bus.readPhys16(0x400 + 0x4C));
    try std.testing.expectEqual(@as(u16, 16), m.bus.readPhys16(0x400 + 0x85));
    try std.testing.expectEqual(@as(u8, 24), m.bus.readPhys8(0x400 + 0x84));
    // Page cleared with 0x0720 word fill (first cell at B8000).
    try std.testing.expectEqual(@as(u16, 0x0720), m.bus.readPhys16(0xB8000));
}

test "two POSTs are byte-identical (deterministic BDA/IVT)" {
    const alloc = std.testing.allocator;
    var snaps: [2][256]u8 = undefined;
    for (0..2) |i| {
        const m = try boot(alloc);
        defer {
            m.deinit();
            alloc.destroy(m);
        }
        // Capture the BDA (0x400..0x500).
        for (0..256) |k| snaps[i][k] = m.bus.readPhys8(0x400 + @as(u32, @intCast(k)));
    }
    try std.testing.expectEqualSlices(u8, &snaps[0], &snaps[1]);
}

// ===========================================================================
// Phase 5c — the completed INT 10h function set + save-pointer ROM chain.
// ===========================================================================

test "INT 10h AH=05 page-flip: CRTC start-address + BDA CURRENT_PAGE/START (text)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Set text mode 3 (page size 0x1000), then AH=05 select page 1.
    loadCode(m, &.{
        0xB8, 0x03, 0x00, 0xCD, 0x10, // MOV AX,0x0003 ; INT 0x10
        0xB8, 0x01, 0x05, 0xCD, 0x10, // MOV AX,0x0501 ; INT 0x10 (AH=05, AL=1)
        0xF4,
    });
    run(m);
    // BDA CURRENT_PAGE(0x62) = 1, CURRENT_START(0x4E) = 1*0x1000 = 0x1000.
    try std.testing.expectEqual(@as(u8, 1), m.bus.readPhys8(0x400 + 0x62));
    try std.testing.expectEqual(@as(u16, 0x1000), m.bus.readPhys16(0x400 + 0x4E));
    // CRTC start-address (0x0C high / 0x0D low). Text ratio 2 => start = 0x1000/2 = 0x800.
    try std.testing.expectEqual(@as(u8, 0x08), m.vga.crtc.regs[0x0C]);
    try std.testing.expectEqual(@as(u8, 0x00), m.vga.crtc.regs[0x0D]);
}

test "INT 10h AH=05 mode-13h render reads the flipped page" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Set mode 13h, then select page 1 (page size 0x2000); assert CRTC start = 0x2000/4 = 0x800.
    loadCode(m, &.{
        0xB8, 0x13, 0x00, 0xCD, 0x10,
        0xB8, 0x01, 0x05, 0xCD, 0x10,
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x2000), m.bus.readPhys16(0x400 + 0x4E));
    // start = 0x800 -> CRTC 0x0C = 0x08, 0x0D = 0x00. startAddress() composes them.
    try std.testing.expectEqual(@as(u16, 0x0800), m.vga.startAddress());
}

test "INT 10h AH=10 AL=00/07 single AC palette reg round-trip" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Mode 3, then AH=10 AL=00 set AC reg 5 = 0x2A (BL=5, BH=0x2A); then AL=07 get reg 5 -> BH.
    loadCode(m, &.{
        0xB8, 0x03, 0x00, 0xCD, 0x10, // set mode 3
        0xB8, 0x00, 0x10, 0xB3, 0x05, 0xB7, 0x2A, 0xCD, 0x10, // AX=0x1000,BL=5,BH=0x2A,INT
        0xB8, 0x07, 0x10, 0xB3, 0x05, 0xB7, 0x00, 0xCD, 0x10, // AX=0x1007,BL=5,BH=0,INT
        0xF4,
    });
    run(m);
    // The device AC reg 5 must equal 0x2A, and the get returned it in BH.
    try std.testing.expectEqual(@as(u8, 0x2A), m.vga.attr.regs[5]);
    try std.testing.expectEqual(@as(u8, 0x2A), m.cpu.st.getReg8(7)); // BH
    // The 0x3C0 flip-flop is left in the index phase (status read restores it).
}

test "INT 10h AH=10 AL=02/09 all-AC-palette set then get round-trip" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Build a 17-byte palette (regs 0..15 = 0x10..0x1F, overscan = 0x05) at DS:0x200.
    const buf: u16 = 0x0200;
    for (0..16) |k| m.bus.writePhys8((@as(u32, CODE_SEG) << 4) + buf + @as(u32, @intCast(k)), 0x10 + @as(u8, @intCast(k)));
    m.bus.writePhys8((@as(u32, CODE_SEG) << 4) + buf + 16, 0x05);
    // Mode 3; AH=10 AL=02 (ES:DX = DS:0x200); then clobber, AL=09 read back to DS:0x300.
    loadCode(m, &.{
        0xB8, 0x03, 0x00, 0xCD, 0x10, // set mode 3
        0xB8, 0x02, 0x10, 0xBA, 0x00, 0x02, 0xCD, 0x10, // AX=0x1002, DX=0x200, INT
        0xB8, 0x09, 0x10, 0xBA, 0x00, 0x03, 0xCD, 0x10, // AX=0x1009, DX=0x300, INT
        0xF4,
    });
    run(m);
    // The read-back block at DS:0x300 must equal what we wrote (16 palette + overscan).
    for (0..16) |k| {
        const got = m.bus.readPhys8((@as(u32, CODE_SEG) << 4) + 0x300 + @as(u32, @intCast(k)));
        try std.testing.expectEqual(@as(u8, 0x10 + @as(u8, @intCast(k))), got);
    }
    try std.testing.expectEqual(@as(u8, 0x05), m.bus.readPhys8((@as(u32, CODE_SEG) << 4) + 0x310));
}

test "INT 10h AH=10 AL=18/19 PEL mask set + get" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AH=10 AL=18 BL=0x3C (set pel mask); then AL=19 (get) -> BL.
    loadCode(m, &.{
        0xB8, 0x18, 0x10, 0xB3, 0x3C, 0xCD, 0x10, // AX=0x1018,BL=0x3C,INT
        0xB8, 0x19, 0x10, 0xB3, 0x00, 0xCD, 0x10, // AX=0x1019,BL=0,INT
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x3C), m.vga.pel_mask);
    try std.testing.expectEqual(@as(u8, 0x3C), m.cpu.st.getReg8(3)); // BL
}

test "INT 10h AH=10 AL=03 blink toggle sets AC 0x10 bit 3" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Mode 3 (AC 0x10 from ATTR1 = 0x0C, bit3 clear); AH=10 AL=03 BL=1 -> set bit3.
    loadCode(m, &.{
        0xB8, 0x03, 0x00, 0xCD, 0x10,
        0xB8, 0x03, 0x10, 0xB3, 0x01, 0xCD, 0x10, // AX=0x1003,BL=1,INT
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x08), m.vga.attr.regs[0x10] & 0x08);
}

test "INT 10h AH=11 AL=03 sets SEQ reg 3 (block specifier)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AH=11 AL=03 BL=0x05 -> SEQ reg 3 = 0x05.
    loadCode(m, &.{ 0xB8, 0x03, 0x11, 0xB3, 0x05, 0xCD, 0x10, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x05), m.vga.seq.regs[3]);
}

test "INT 10h AH=11 AL=20-24 set INT 1F/43 vectors + BDA char height/rows" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AL=20: set INT 1Fh = ES:BP (ES=0x1234, BP=0x5678).
    // AL=22: set INT 43h = ROM 8x14, rowspec 1 => 14 rows, char height 14.
    loadCode(m, &.{
        // ES = 0x1234 via MOV AX,0x1234 ; MOV ES,AX
        0xB8, 0x34, 0x12, 0x8E, 0xC0,
        0xBD, 0x78, 0x56, // MOV BP,0x5678
        0xB8, 0x20, 0x11, 0xCD, 0x10, // AX=0x1120 (AL=20), INT
        0xB8, 0x22, 0x11, 0xB3, 0x01, 0xB2, 0x00, 0xCD, 0x10, // AX=0x1122,BL=1(rowspec),DL=0,INT
        0xF4,
    });
    run(m);
    // INT 1Fh vector = 0x1234:0x5678.
    try std.testing.expectEqual(@as(u16, 0x5678), m.bus.readPhys16(0x1F * 4));
    try std.testing.expectEqual(@as(u16, 0x1234), m.bus.readPhys16(0x1F * 4 + 2));
    // INT 43h vector = the staged ROM 8x14 font (FONT_SEG:FONT14_OFF).
    const int10 = @import("bios").int10_mod;
    try std.testing.expectEqual(int10.FONT14_OFF, m.bus.readPhys16(0x43 * 4));
    try std.testing.expectEqual(int10.FONT_SEG, m.bus.readPhys16(0x43 * 4 + 2));
    // BDA char height = 14, rows-1 = 13 (rowspec 1 => 14 rows).
    try std.testing.expectEqual(@as(u16, 14), m.bus.readPhys16(0x400 + 0x85));
    try std.testing.expectEqual(@as(u8, 13), m.bus.readPhys8(0x400 + 0x84));
}

test "INT 10h AH=12 BL=10 returns EGA/config info" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Boot is color text (CRTC 0x3D4) => BH=0; BL=3 (256K); CX = SWITCHES nibble.
    loadCode(m, &.{ 0xB4, 0x12, 0xB3, 0x10, 0xCD, 0x10, 0xF4 }); // MOV AH,0x12 ; MOV BL,0x10 ; INT
    run(m);
    try std.testing.expectEqual(@as(u8, 0x00), m.cpu.st.getReg8(7)); // BH = color
    try std.testing.expectEqual(@as(u8, 0x03), m.cpu.st.getReg8(3)); // BL = 256K
}

test "INT 10h AH=12 BL=36 toggles SEQ reg 1 bit 5" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Mode 3 (SEQ reg1 from SEQ2 = 0x00); BL=36 AL=1 (screen off) -> SEQ reg1 bit5 set.
    loadCode(m, &.{
        0xB8, 0x03, 0x00, 0xCD, 0x10, // set mode 3
        0xB4, 0x12, 0xB3, 0x36, 0xB0, 0x01, 0xCD, 0x10, // AH=12,BL=36,AL=1,INT
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x20), m.vga.seq.regs[1] & 0x20);
    try std.testing.expectEqual(@as(u8, 0x12), m.cpu.st.getReg8(0)); // AL=0x12 success
}

test "INT 10h AH=12 BL=30/31/33 touch the right BDA bytes" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // BL=30 AL=0 (200 lines) -> MODESET_CTL bit7 set, bit4 clear; SWITCHES low nibble 8.
    // BL=33 AL=0 (gray-sum enable) -> MODESET_CTL bit1 set.
    // BL=31 AL=1 (palette load) -> VIDEO_CTL bit3 set.
    loadCode(m, &.{
        0xB4, 0x12, 0xB3, 0x30, 0xB0, 0x00, 0xCD, 0x10, // 200 lines
        0xB4, 0x12, 0xB3, 0x33, 0xB0, 0x00, 0xCD, 0x10, // gray-sum on
        0xB4, 0x12, 0xB3, 0x31, 0xB0, 0x01, 0xCD, 0x10, // palette load on
        0xF4,
    });
    run(m);
    const modeset = m.bus.readPhys8(0x400 + 0x89);
    try std.testing.expectEqual(@as(u8, 0x80), modeset & 0x80); // 200-line bit7
    try std.testing.expectEqual(@as(u8, 0x00), modeset & 0x10); // bit4 clear
    try std.testing.expectEqual(@as(u8, 0x02), modeset & 0x02); // gray-sum bit1
    try std.testing.expectEqual(@as(u8, 0x08), m.bus.readPhys8(0x400 + 0x88) & 0x08); // SWITCHES nibble 8
    try std.testing.expectEqual(@as(u8, 0x08), m.bus.readPhys8(0x400 + 0x87) & 0x08); // VIDEO_CTL bit3
}

test "INT 10h AH=1B fills the 64-byte block (static ptr, BDA copy, counts, AL=0x1B)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Mode 13h, then AH=1B BX=0 ES:DI = DS:0x400.
    loadCode(m, &.{
        0xB8, 0x13, 0x00, 0xCD, 0x10, // set mode 13h
        0xB4, 0x1B, // MOV AH,0x1B
        0xBB, 0x00, 0x00, // MOV BX,0
        0xBF, 0x00, 0x04, // MOV DI,0x400
        0xCD, 0x10, 0xF4,
    });
    run(m);
    const save: u32 = (@as(u32, CODE_SEG) << 4) + 0x400;
    // +0: static-functionality far ptr (F000:STATIC_FUNC_OFF). The first ROM byte = 0xff.
    const sf_ptr = m.bus.readPhys32(save);
    const sf_off: u16 = @truncate(sf_ptr);
    const sf_seg: u16 = @truncate(sf_ptr >> 16);
    try std.testing.expect(sf_ptr != 0);
    try std.testing.expectEqual(@as(u8, 0xff), m.bus.readPhys8((@as(u32, sf_seg) << 4) + sf_off));
    // +4: BDA copy — video mode (0x49) = 0x13.
    try std.testing.expectEqual(@as(u8, 0x13), m.bus.readPhys8(save + 4));
    // +0x27: color count = 256 for mode 13h.
    try std.testing.expectEqual(@as(u16, 256), m.bus.readPhys16(save + 0x27));
    // +0x29: page count = 1.
    try std.testing.expectEqual(@as(u8, 1), m.bus.readPhys8(save + 0x29));
    // +0x2A: scan-line code = 0 (200-line mode 13h).
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8(save + 0x2A));
    // +0x2D: misc flags = 0x01 (graphics). +0x31: video memory = 3.
    try std.testing.expectEqual(@as(u8, 0x01), m.bus.readPhys8(save + 0x2D));
    try std.testing.expectEqual(@as(u8, 3), m.bus.readPhys8(save + 0x31));
    // AL = 0x1B.
    try std.testing.expectEqual(@as(u8, 0x1B), m.cpu.st.getReg8(0));
}

test "INT 10h AH=1A00 returns BL=0x08 AND VS_POINTER (0xA8) is staged + non-zero" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // AH=1A00 still returns BL=0x08 (the LAMUT adapter-detect).
    loadCode(m, &.{ 0xB8, 0x00, 0x1A, 0xCD, 0x10, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u8, 0x08), m.cpu.st.getReg8(3));
    // BDA VS_POINTER 0040:00A8 is a non-zero far ptr into the staged DCC-bearing chain.
    const vs = m.bus.readPhys32(0x400 + 0xA8);
    try std.testing.expect(vs != 0);
    const vs_off: u16 = @truncate(vs);
    const vs_seg: u16 = @truncate(vs >> 16);
    // The video-save-pointer table entry [4] points at save-pointer-table-2, whose
    // [0] (after the length word) points at the DCC table; the DCC header byte = 0x10.
    const sp2 = m.bus.readPhys32((@as(u32, vs_seg) << 4) + vs_off + 16);
    try std.testing.expect(sp2 != 0);
    const sp2_off: u16 = @truncate(sp2);
    const sp2_seg: u16 = @truncate(sp2 >> 16);
    const dcc = m.bus.readPhys32((@as(u32, sp2_seg) << 4) + sp2_off + 2); // skip length word
    const dcc_off: u16 = @truncate(dcc);
    const dcc_seg: u16 = @truncate(dcc >> 16);
    try std.testing.expectEqual(@as(u8, 0x10), m.bus.readPhys8((@as(u32, dcc_seg) << 4) + dcc_off));
}
