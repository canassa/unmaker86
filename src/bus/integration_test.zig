//! M0 end-to-end gate: instantiate `Cpu(Bus)` with the REAL bus (not TestBus),
//! load a tiny hand-assembled real-mode program into RAM, and step it — proving
//! the real bus runs the CPU end to end (beyond the CPU's TestBus conformance).
//!
//! This is the machine-level test the plan designates (Phase 1 "Integration
//! check" / M0): it is the ONLY test that imports both `cpu` and `bus`. The real
//! `Bus` is no fake — it is the production module.

const std = @import("std");
const cpu_mod = @import("cpu");
const bus_mod = @import("bus");

const Bus = bus_mod.Bus;
const Cpu = cpu_mod.Cpu(Bus);
const Reg32 = cpu_mod.state.Reg32;
const Seg = cpu_mod.Seg;

test "M0: a tiny real-mode program runs on Cpu(Bus) against the real bus" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);

    // Real-mode flat setup: all segments at 0, code at 0x0500.
    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ds, 0);
    cpu.loadSegment(.ss, 0);
    cpu.loadSegment(.es, 0);
    cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    const org: u32 = 0x0500;
    cpu.st.eip = org;

    // 16-bit real-mode program:
    //   B8 05 00     MOV AX, 0x0005
    //   83 C0 03     ADD AX, 3          ; AX = 8
    //   A3 00 20     MOV [0x2000], AX   ; store AX to DS:0x2000
    //   F4           HLT
    const prog = [_]u8{
        0xB8, 0x05, 0x00,
        0x83, 0xC0, 0x03,
        0xA3, 0x00, 0x20,
        0xF4,
    };
    for (prog, 0..) |b, i| bus.writePhys8(org + @as(u32, @intCast(i)), b);

    // Step until HLT (bounded so a bug can't hang the test).
    var steps: usize = 0;
    while (steps < 100) : (steps += 1) {
        const r = cpu.step();
        if (r.stop_reason == .halted) break;
        if (r.stop_reason == .shutdown) return error.UnexpectedShutdown;
    }
    try std.testing.expect(steps < 100);

    // AX = 8 in the CPU register file.
    try std.testing.expectEqual(@as(u16, 8), cpu.st.getReg16(@intFromEnum(Reg32.eax)));
    // ...and the store landed in the REAL bus's RAM at 0x2000 (little-endian).
    try std.testing.expectEqual(@as(u16, 8), bus.readPhys16(0x2000));
    try std.testing.expectEqual(@as(u8, 0x08), bus.readPhys8(0x2000));
    try std.testing.expectEqual(@as(u8, 0x00), bus.readPhys8(0x2001));
}

test "M0: stack push/pop through the real bus (SS-relative RAM)" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);

    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ss, 0);
    cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    const org: u32 = 0x0600;
    cpu.st.eip = org;

    //   B8 CD AB     MOV AX, 0xABCD
    //   50           PUSH AX
    //   5B           POP BX
    //   F4           HLT
    const prog = [_]u8{ 0xB8, 0xCD, 0xAB, 0x50, 0x5B, 0xF4 };
    for (prog, 0..) |b, i| bus.writePhys8(org + @as(u32, @intCast(i)), b);

    var steps: usize = 0;
    while (steps < 100) : (steps += 1) {
        const r = cpu.step();
        if (r.stop_reason == .halted) break;
        if (r.stop_reason == .shutdown) return error.UnexpectedShutdown;
    }
    try std.testing.expect(steps < 100);
    // BX got AX's value via a push then pop that round-tripped through real RAM.
    try std.testing.expectEqual(@as(u16, 0xABCD), cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
}
