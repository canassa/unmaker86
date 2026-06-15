//! Phase 0 bridge tests (M0): the guest<->host callback round-trip, the D4 FLAGS
//! return, the D3 re-entrancy via the real-INT trampoline, determinism (byte-
//! identical incl. cycles), and the NullSink #UD path.
//!
//! These drive the FULL machine (real CPU + bus + PIC + PIT + BIOS + DOS) so the
//! callback path is exercised exactly as a guest would. We use INT 21h AH=30 (get
//! DOS version) as the round-trip probe — it traps to the DOS CallbackSink and
//! returns via IRET, the same path every host-serviced trap takes.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine_mod.Machine;
const Seg = cpu_mod.state.Seg;
const Reg32 = cpu_mod.state.Reg32;

/// Build + wire + POST a machine on the heap (pinned), ready to run a program.
fn bootMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    return m;
}

/// Place bytes at seg:off in guest RAM and point CS:IP there with a fresh stack.
fn loadCode(m: *Machine, seg: u16, code: []const u8) void {
    const base = @as(u32, seg) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, seg);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, seg);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, seg);
    m.cpu.loadSegment(.es, seg);
    m.cpu.st.eflags.iff = true;
}

fn untilHalt(mm: *Machine) bool {
    return mm.cpu.st.halted;
}

test "round-trip: guest INT 21h AH=30 reaches the DOS sink and returns via IRET" {
    const alloc = std.testing.allocator;
    const m = try bootMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    // MOV AH,0x30; INT 0x21; HLT
    loadCode(m, 0x2000, &.{ 0xB4, 0x30, 0xCD, 0x21, 0xF4 });
    const start_cycles = m.cpu.st.cycles;

    _ = m.runUntil(untilHalt, 100_000);

    try std.testing.expectEqual(@as(u8, 5), m.cpu.st.getReg8(0));
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));
    try std.testing.expect(m.cpu.st.cycles > start_cycles);
}

test "FLAGS return: a faithful DOS error path sets carry after IRET (D4)" {
    const alloc = std.testing.allocator;
    const m = try bootMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    m.dos.mountDrive(2, td.dir, std.testing.io); // C:
    m.dos.current_drive = 2;

    // MOV AH,0x41; MOV DX,0x0040; INT 0x21; PUSHF; POP AX; HLT (unlink missing).
    loadCode(m, 0x2000, &.{ 0xB4, 0x41, 0xBA, 0x40, 0x00, 0xCD, 0x21, 0x9C, 0x58, 0xF4 });
    const name = "NOPE.XYZ";
    const base = @as(u32, 0x2000) << 4;
    for (name, 0..) |c, i| m.bus.writePhys8(base + 0x40 + @as(u32, @intCast(i)), c);
    m.bus.writePhys8(base + 0x40 + name.len, 0);

    _ = m.runUntil(untilHalt, 100_000);

    // AX holds the FLAGS image (PUSHF/POP AX); CF (bit 0) must be set.
    try std.testing.expect((m.cpu.st.getReg16(0) & 0x0001) != 0);
}

test "re-entrancy: runGuestInt drives a real INT via the trampoline + restores the seam" {
    const alloc = std.testing.allocator;
    const m = try bootMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    loadCode(m, 0x3000, &.{0xF4}); // HLT (defines a CS:IP to verify restoration)
    m.cpu.st.setReg8(4, 0x30); // prime AH=30 for the re-entered INT 21h

    const save_cs = m.cpu.st.selector[@intFromEnum(Seg.cs)];
    const save_ip = m.cpu.st.eip;

    m.svc.bridge.runGuestInt(0x21);

    try std.testing.expectEqual(@as(u8, 5), m.cpu.st.getReg8(0));
    try std.testing.expectEqual(save_cs, m.cpu.st.selector[@intFromEnum(Seg.cs)]);
    try std.testing.expectEqual(save_ip, m.cpu.st.eip);
}

test "runGuestFarCall: a far-call into guest code returns at RETF + charges every inner cycle (no hole)" {
    const alloc = std.testing.allocator;
    const m = try bootMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    // A tiny guest routine at 0x3000:0x0010 — a few NOPs then RETF. The far call
    // pushes a return frame to the stop sentinel; the RETF lands on it -> return.
    const routine_seg: u16 = 0x3000;
    const routine_off: u16 = 0x0010;
    const routine = [_]u8{ 0x90, 0x90, 0x90, 0xCB }; // NOP; NOP; NOP; RETF
    const base = (@as(u32, routine_seg) << 4) + routine_off;
    for (routine, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);

    // Give the guest a valid SS:SP so the far-return frame has somewhere to live.
    // IF stays clear: the routine is pure NOPs+RETF, no IRQ needed — keeps the
    // far-call isolated (no PIT tick landing mid-routine).
    m.cpu.loadSegment(.ss, 0x4000);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.st.eflags.iff = false;

    // Define an outer CS:IP to verify it is restored after the re-entry.
    m.cpu.loadSegment(.cs, 0x2000);
    m.cpu.st.eip = 0x1234;
    const save_cs = m.cpu.st.selector[@intFromEnum(Seg.cs)];
    const save_ip = m.cpu.st.eip;
    const save_sp = m.cpu.st.getReg16(@intFromEnum(Reg32.esp));

    const start_cycles = m.cpu.st.cycles;
    m.svc.bridge.runGuestFarCall(routine_seg, routine_off);

    // (i) Returns correctly: the outer CS:IP/SP seam is restored exactly.
    try std.testing.expectEqual(save_cs, m.cpu.st.selector[@intFromEnum(Seg.cs)]);
    try std.testing.expectEqual(save_ip, m.cpu.st.eip);
    try std.testing.expectEqual(save_sp, m.cpu.st.getReg16(@intFromEnum(Reg32.esp)));

    // (ii) Every inner instruction charged REAL cycles through the normal ledger —
    // the no-hole proof. The 3 NOPs + RETF (+ the cost-exempt stop-sentinel trap)
    // must advance the ledger; a host re-entry that skipped step_one would not.
    try std.testing.expect(m.cpu.st.cycles > start_cycles);
}

test "runGuestFarCall: inner-instruction cycle charge is deterministic across two runs (no hole)" {
    const alloc = std.testing.allocator;
    var charged: [2]u64 = undefined;
    for (0..2) |run| {
        const m = try bootMachine(alloc);
        defer {
            m.deinit();
            alloc.destroy(m);
        }
        const routine = [_]u8{ 0x90, 0x90, 0x90, 0xCB }; // NOP; NOP; NOP; RETF
        const base = (@as(u32, 0x3000) << 4) + 0x0010;
        for (routine, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
        m.cpu.loadSegment(.ss, 0x4000);
        m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
        m.cpu.st.eflags.iff = false;
        m.cpu.loadSegment(.cs, 0x2000);
        m.cpu.st.eip = 0x1234;

        const before = m.cpu.st.cycles;
        m.svc.bridge.runGuestFarCall(0x3000, 0x0010);
        charged[run] = m.cpu.st.cycles - before;
    }
    // The inner work is a pure function of the cycle ledger -> byte-identical.
    try std.testing.expectEqual(charged[0], charged[1]);
    try std.testing.expect(charged[0] > 0); // and it is non-zero (no hole).
}

test "determinism: the round-trip is byte-identical across two runs incl. cycles" {
    const alloc = std.testing.allocator;
    var results: [2]struct { ax: u16, cycles: u64 } = undefined;
    for (0..2) |run| {
        const m = try bootMachine(alloc);
        defer {
            m.deinit();
            alloc.destroy(m);
        }
        loadCode(m, 0x2000, &.{ 0xB4, 0x30, 0xCD, 0x21, 0xF4 });
        _ = m.runUntil(untilHalt, 100_000);
        results[run] = .{ .ax = m.cpu.st.getReg16(0), .cycles = m.cpu.st.cycles };
    }
    try std.testing.expectEqual(results[0].ax, results[1].ax);
    // Cycle position identical DESPITE the host-serviced trap — the no-hole proof.
    try std.testing.expectEqual(results[0].cycles, results[1].cycles);
}

test "NullSink: a callback opcode with no registered sink raises #UD" {
    const TestBus = cpu_mod.TestBus;
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = cpu_mod.Cpu(TestBus).init(&bus, &pic, &sched);

    bus.writePhys16(6 * 4, 0x0100); // IVT[6] (#UD) -> 0000:0100
    bus.writePhys16(6 * 4 + 2, 0x0000);
    bus.writePhys8(0x0100, 0xF4); // HLT

    cpu.loadSegment(.cs, 0x0000);
    cpu.st.eip = 0x0200;
    cpu.loadSegment(.ss, 0x0000);
    cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x0FF0);
    bus.writePhys8(0x0200, 0xFE);
    bus.writePhys8(0x0201, 0x38);
    bus.writePhys8(0x0202, 0x05);

    _ = cpu.step(); // 0xFE 0x38 -> #UD raised + delivered
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0x0100), cpu.st.eip);
}
