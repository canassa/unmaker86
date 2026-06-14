//! Machine unit tests (Phase 0/1/3/6): smoke/reset state, two-reset determinism,
//! the HLT fast-forward, halted_forever, the armed-but-unwakeable periodic case,
//! and the snapshot round-trip.

const std = @import("std");
const machine = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine.Machine;
const StopReason = machine.StopReason;
const Seg = cpu_mod.Seg;
const Reg32 = cpu_mod.state.Reg32;

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}

/// Compare two CPU States byte-for-byte (the GenReg32 union can't be deep-compared
/// by std.testing, but the whole State is plain serializable bytes — CLAUDE #6).
fn expectStateEqual(a: cpu_mod.State, b: cpu_mod.State) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

test "smoke: init+wire lands 386 power-on; A20 off; PIC/PIT/scheduler at reset" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try std.testing.expectEqual(@as(u32, 0xFFF0), m.cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 0xF000), m.cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), m.cpu.st.seg_base[@intFromEnum(Seg.cs)]);
    try std.testing.expect(!m.bus.a20Enabled());
    try std.testing.expectEqual(@as(u8, 0xFF), m.pic.master.imr);
    try std.testing.expectEqual(@as(u8, 0xFF), m.pic.slave.imr);
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle());
    try std.testing.expect(!m.shutdown);
}

test "two resets are byte-identical (CPU state + PIC + PIT + scheduler)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Dirty the machine: program devices, dirty RAM.
    m.programDefaultPic();
    m.programDefaultTimer();
    m.bus.writePhys8(0x500, 0xAB);
    m.cpu.writeReg32(.eax, 0xDEAD);

    m.reset();
    const a = m.snapshot();
    m.reset();
    const b = m.snapshot();
    try expectStateEqual(a.cpu_state, b.cpu_state);
    try std.testing.expectEqualDeep(a.pic, b.pic);
    try std.testing.expectEqualDeep(a.pit, b.pit);
    try std.testing.expectEqualDeep(a.sched, b.sched);
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8(0x500)); // RAM re-zeroed
}

test "no-interrupt program runs to a target cycle (.cycles_reached)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Real-mode flat program at 0:0x0500 — a tight loop (JMP $).
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    // EB FE = JMP $ (infinite loop, no HLT, no interrupt).
    m.bus.writePhys8(0x0500, 0xEB);
    m.bus.writePhys8(0x0501, 0xFE);
    const r = m.runCycles(100);
    try std.testing.expectEqual(StopReason.cycles_reached, r);
    try std.testing.expect(m.cpu.st.cycles >= 100);
}

test "HLT with no events and IF=0 -> halted_forever (deterministic, not a spin)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.cpu.st.eflags.iff = false; // interrupts disabled
    m.bus.writePhys8(0x0500, 0xF4); // HLT
    const r = m.runCycles(10_000);
    try std.testing.expectEqual(StopReason.halted_forever, r);
}

test "HLT fast-forward: STI;HLT jumps cpu.st.cycles to the next event cycle" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    // Program ch0 to a short period so the event is at a known cycle.
    m.bus.portOut8(0x43, 0x34); // ch0 mode 2 lohi
    m.bus.portOut8(0x40, 0x0A); // reload 10
    m.bus.portOut8(0x40, 0x00);
    // The event was armed at cycle 0 (the OUT writes happen before stepping but
    // the PIT reads cpu.st.cycles which is 0 here): fire_cycle = 10*12 = 120.
    const event_cycle = m.nextEventCycle();
    try std.testing.expectEqual(@as(u64, 120), event_cycle);

    // STI; HLT at 0:0x0500.
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.bus.writePhys8(0x0500, 0xFB); // STI
    m.bus.writePhys8(0x0501, 0xF4); // HLT
    // Mask IRQ0 so the IRQ doesn't get delivered (no IVT set up) — we only test
    // that the fast-forward lands cpu.st.cycles at the event cycle.
    m.bus.portOut8(0x21, 0x01); // mask IRQ0
    // Run a bounded budget past the event; the HLT fast-forwards to event_cycle.
    _ = m.runCycles(1000);
    try std.testing.expect(m.cpu.st.cycles >= event_cycle);
}

test "armed-but-unwakeable periodic: masked IRQ0, IF=0, HLT -> cycles_reached" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    m.bus.portOut8(0x21, 0x01); // mask IRQ0
    m.bus.portOut8(0x43, 0x34); // ch0 mode 2
    m.bus.portOut8(0x40, 0x0A);
    m.bus.portOut8(0x40, 0x00); // periodic event armed
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.cpu.st.eflags.iff = false; // everything masked / IF=0
    m.bus.writePhys8(0x0500, 0xF4); // HLT
    const r = m.runCycles(5000);
    // Periodic events keep coming but never wake the CPU -> bounded cycles_reached.
    try std.testing.expectEqual(StopReason.cycles_reached, r);
    try std.testing.expect(m.cpu.st.cycles >= 5000);
}

test "snapshot round-trip of a populated machine restores identically" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    m.programDefaultTimer();
    m.pic.raiseIrq(1);
    m.bus.writePhys8(0x1234, 0x77);
    const snap = m.snapshot();
    const ram_copy = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ram_copy);

    // Restore into a fresh, re-wired machine.
    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    m2.restore(snap);
    @memcpy(m2.bus.ram, ram_copy);

    const s2 = m2.snapshot();
    try expectStateEqual(snap.cpu_state, s2.cpu_state);
    try std.testing.expectEqualDeep(snap.pic, s2.pic);
    try std.testing.expectEqualDeep(snap.pit, s2.pit);
    try std.testing.expectEqualDeep(snap.sched, s2.sched);
    try std.testing.expectEqual(@as(u8, 0x77), m2.bus.readPhys8(0x1234));
}
