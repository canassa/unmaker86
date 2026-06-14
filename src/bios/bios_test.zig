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
