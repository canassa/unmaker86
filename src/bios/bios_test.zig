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

test "POST lands the IVT + BDA + A20 enabled" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // A20 enabled by POST.
    try std.testing.expect(m.bus.a20Enabled());
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

test "no host-time / RNG / thread in the BIOS sources (grep, Phase 9)" {
    const sources = [_][]const u8{
        @embedFile("bios.zig"),
        @embedFile("bda.zig"),
        @embedFile("int10.zig"),
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
