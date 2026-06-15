//! Phase 9 determinism audit tests: zero allocation in step(), cycle ledger is
//! pure & advances on every dispatch key, State save/restore is lossless, and
//! the M6 sign-off audit (full-State round-trip, byte-identical-to-cycle-N
//! regressions incl. a faulting path, deterministic reset / no uninitialized
//! reads, snapshot-only-at-boundary invariant).

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const state = @import("state.zig");
const cycles = @import("cycles.zig");
const dispatch = @import("dispatch.zig");
const decode = @import("decode.zig");
const Reg32 = state.Reg32;
const Seg = state.Seg;

const TestBus = cpu_mod.TestBus;
const Cpu = cpu_mod.Cpu(TestBus);

/// Field-wise equality for State. std.meta.eql refuses to compare the untagged
/// `GenReg32` union, so we compare the register file by its `.dword` view and
/// the rest of the fields structurally. This is the byte-identical-State check
/// the determinism prime directive needs (no padding sensitivity).
fn stateEql(a: state.State, b: state.State) bool {
    inline for (@typeInfo(state.State).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "regs")) {
            for (a.regs, b.regs) |ra, rb| {
                if (ra.dword != rb.dword) return false;
            }
        } else {
            if (!std.meta.eql(@field(a, f.name), @field(b, f.name))) return false;
        }
    }
    return true;
}

/// A counting allocator wrapper that panics if any allocation happens
/// (memory-and-performance.md §7): used to assert zero alloc during step().
const PanicAllocator = struct {
    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        @panic("allocation during step()");
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        @panic("resize during step()");
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        @panic("remap during step()");
    }
    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        @panic("free during step()");
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

test "M6: no host time / RNG / thread / env reads anywhere in src/cpu (grep-enforced)" {
    // Phase 9 grep-enforced determinism audit. Embed each CPU SOURCE file (the
    // execution core — NOT the _test.zig harnesses, which legitimately use the
    // testing allocator) and assert none reference host time, RNG, threading, or
    // the environment. This backs the determinism constraints #2/#3 structurally.
    const sources = [_][]const u8{
        @embedFile("cpu.zig"),          @embedFile("state.zig"),      @embedFile("flags.zig"),
        @embedFile("bus.zig"),          @embedFile("alu.zig"),        @embedFile("decode.zig"),
        @embedFile("dispatch.zig"),     @embedFile("exec.zig"),       @embedFile("exec_data.zig"),
        @embedFile("exec_alu.zig"),     @embedFile("exec_shift.zig"), @embedFile("exec_muldiv.zig"),
        @embedFile("exec_bit.zig"),     @embedFile("exec_bcd.zig"),   @embedFile("exec_ctrl.zig"),
        @embedFile("exec_string.zig"),  @embedFile("exec_io.zig"),    @embedFile("exec_system.zig"),
        @embedFile("segmentation.zig"), @embedFile("interrupts.zig"), @embedFile("cycles.zig"),
    };
    const forbidden = [_][]const u8{
        "std.time", // host wall clock
        "std.Random", "std.rand", // RNG
        "std.Thread", // threading
        "std.posix.getenv", "std.process.getEnv", "std.os.getenv", // environment
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' found in a CPU source file\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

test "zero allocation during step()" {
    // Build a TestBus with only the flat region (no sparse pages), backed by a
    // panic allocator so any hot-path alloc aborts.
    var bus = TestBus.init(PanicAllocator.allocator());
    defer {
        // Only flat region used; nothing to free.
    }
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);
    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ds, 0);
    cpu.loadSegment(.ss, 0);
    cpu.st.eip = 0x2000;
    // MOV AX, 5 ; ADD AX, 3 ; INC AX -- all within the flat region.
    const prog = [_]u8{ 0xB8, 0x05, 0x00, 0x83, 0xC0, 0x03, 0x40 };
    for (prog, 0..) |b, i| bus.writeByte(@intCast(0x2000 + i), b);
    _ = cpu.step();
    _ = cpu.step();
    _ = cpu.step();
    try std.testing.expectEqual(@as(u16, 9), cpu.st.getReg16(0));
}

test "cycle ledger advances by a non-zero table-consistent amount each step" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);
    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ds, 0);
    cpu.loadSegment(.ss, 0);
    cpu.st.eip = 0x2000;
    bus.writeByte(0x2000, 0x90); // NOP
    const before = cpu.st.cycles;
    const r = cpu.step();
    try std.testing.expect(r.cycles_consumed > 0);
    try std.testing.expectEqual(before + cycles.baseFor(0x90), cpu.st.cycles);
}

test "every dispatch key has a non-zero cycle entry (cost by construction)" {
    for (cycles.table) |e| {
        try std.testing.expect(e.base > 0);
    }
}

test "M6: exhaustive dispatch-key sweep charges a non-zero table-consistent base for EVERY key" {
    // Cost-charging by construction (Phase 1a / Theme E), verified END-TO-END:
    // for every opcode byte in BOTH the one-byte and 0F maps, at BOTH operand
    // sizes (the 0x66 prefix flips the 0x200 key bit), drive ONE executeOne and
    // assert the ledger advanced by AT LEAST baseFor(key) — the base is charged
    // at the choke point before dispatch, so this holds even when the arm then
    // faults (#UD) or reads further (zeroed) operand bytes. This covers the
    // #UD/default arm and every defined key (the hole-free guarantee).
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);

    // Build a key set that mirrors what the dispatcher can actually produce:
    // (op32?0x200) | (0F?0x100) | opcode, for every opcode 0..255.
    var keys_seen: usize = 0;
    for ([_]bool{ false, true }) |is_0F| {
        for ([_]bool{ false, true }) |op32| {
            var opcode: u16 = 0;
            while (opcode <= 0xFF) : (opcode += 1) {
                // Lay: optional 0x66 (operand-size) prefix, optional 0x0F, opcode,
                // then plenty of zero bytes for any ModR/M / imm / disp the arm reads.
                cpu.reset();
                cpu.loadSegment(.cs, 0);
                cpu.loadSegment(.ds, 0);
                cpu.loadSegment(.ss, 0);
                cpu.loadSegment(.es, 0);
                cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
                const at: u32 = 0x3000;
                // Zero a generous window so further operand fetches read 0.
                var z: u32 = 0;
                while (z < 32) : (z += 1) bus.writeByte(at + z, 0x00);
                var p: u32 = at;
                if (op32) {
                    bus.writeByte(p, 0x66);
                    p += 1;
                }
                if (is_0F) {
                    bus.writeByte(p, 0x0F);
                    p += 1;
                }
                bus.writeByte(p, @intCast(opcode));
                cpu.st.eip = at;

                const before = cpu.st.cycles;
                const key: u12 = (if (op32) @as(u12, 0x200) else 0) |
                    (if (is_0F) @as(u12, 0x100) else 0) |
                    @as(u12, @intCast(opcode));
                // executeOne charges baseFor(key) at the choke point, then dispatches.
                // It may fault (recorded in pending_fault) or read further bytes —
                // either way the base is already on the ledger.
                dispatch.executeOne(&cpu) catch {};
                const charged = cpu.st.cycles - before;
                try std.testing.expect(charged >= cycles.baseFor(key));
                try std.testing.expect(cycles.baseFor(key) > 0);
                keys_seen += 1;
            }
        }
    }
    // 2 maps * 2 sizes * 256 opcodes = 1024 = the full 0x400 key space.
    try std.testing.expectEqual(@as(usize, cycles.KEY_COUNT), keys_seen);
}

test "M6: full serializable State round-trips byte-identically (every mutable boundary field)" {
    // Enumerate EVERY mutable field that survives an instruction boundary and
    // assert save -> restore -> compare is byte-identical. We populate the
    // instruction-boundary fields explicitly so the round-trip is not vacuous,
    // then compare the WHOLE struct with std.meta.eql (covers regs/seg/EIP/
    // EFLAGS, the interrupt-shadow flag, halted/shutdown, NMI latch/in-service,
    // the double-fault nesting counter, pending_fault, and cycles).
    var s: state.State = undefined;
    s.reset();
    // Touch GP/seg/EIP/EFLAGS.
    s.setReg32(@intFromEnum(Reg32.eax), 0xDEADBEEF);
    s.setReg32(@intFromEnum(Reg32.esp), 0x0000F000);
    s.eip = 0x00012345;
    s.eflags = @import("flags.zig").Flags.fromU32(0x00000202);
    s.seg_base[@intFromEnum(Seg.ds)] = 0x00010000;
    s.seg_limit[@intFromEnum(Seg.ds)] = 0x0000FFFF;
    s.selector[@intFromEnum(Seg.ds)] = 0x1000;
    s.cr0 = 0x1;
    s.idtr_base = 0x400;
    s.idtr_limit = 0x7FF;
    // The instruction-boundary survivors (the Theme E completeness audit).
    s.inhibit_irq_one_instruction = true;
    s.nmi_latched = true;
    s.nmi_in_service = true;
    s.halted = true;
    s.shutdown = false;
    s.fault_nesting = 1;
    s.pending_fault = .{ .vector = 13, .class = .fault, .error_code = null };
    s.last_delivered = .{ .vector = 0x21, .at_cycle = 0xAABBCCDD, .seq = 7 };
    s.cycles = 0x1122334455667788;

    // Save.
    const snapshot = s;
    // Mutate every field we set, then restore.
    s = .{};
    s = snapshot;

    try std.testing.expect(stateEql(snapshot, s));
    // Spot-check the boundary survivors individually (documentation of intent).
    try std.testing.expectEqual(true, s.inhibit_irq_one_instruction);
    try std.testing.expectEqual(true, s.nmi_latched);
    try std.testing.expectEqual(true, s.nmi_in_service);
    try std.testing.expectEqual(true, s.halted);
    try std.testing.expectEqual(false, s.shutdown);
    try std.testing.expectEqual(@as(u8, 1), s.fault_nesting);
    try std.testing.expect(s.pending_fault != null);
    try std.testing.expectEqual(@as(u8, 0x21), s.last_delivered.vector);
    try std.testing.expectEqual(@as(u64, 7), s.last_delivered.seq);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), s.cycles);

    // Audit guard: assert no NEW non-padding mutable field was added to State
    // without being covered here. If State grows, this count must be revisited.
    // (regs, eip, eflags, seg_base, seg_limit, selector, seg_desc, cr0, cr2,
    //  cr3, dr, idtr_base, idtr_limit, gdtr_base, gdtr_limit, ldtr, tr, cpl,
    //  inhibit_irq_one_instruction, halted, shutdown, nmi_latched,
    //  nmi_in_service, fault_nesting, pending_fault, last_delivered, cycles)
    try std.testing.expectEqual(@as(usize, 27), @typeInfo(state.State).@"struct".fields.len);
}

test "M6: deterministic to cycle N twice — byte-identical State + RAM, normal path" {
    // Run a fixed real-mode program for N steps twice; assert byte-identical
    // State and the full TestBus flat RAM region. CLAUDE constraint #6.
    const Program = [_]u8{
        0xB8, 0x05, 0x00, // MOV AX, 5
        0x83, 0xC0, 0x03, // ADD AX, 3
        0x40, // INC AX
        0x89, 0x06, 0x00, 0x30, // MOV [0x3000], AX
        0xF7, 0xE0, // MUL AX
        0x90, // NOP
    };
    var snap0: state.State = undefined;
    var ram0: [TestBus.flat_size]u8 = undefined;
    for (0..2) |run| {
        var bus = TestBus.init(std.testing.allocator);
        defer bus.deinit();
        var pic = cpu_mod.NullPic{};
        var sched = cpu_mod.NullScheduler{};
        var cpu = Cpu.init(&bus, &pic, &sched);
        cpu.loadSegment(.cs, 0);
        cpu.loadSegment(.ds, 0);
        cpu.loadSegment(.ss, 0);
        cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
        cpu.st.eip = 0x2000;
        for (Program, 0..) |b, i| bus.writeByte(@intCast(0x2000 + i), b);
        var n: u32 = 0;
        while (n < 6) : (n += 1) _ = cpu.step();
        if (run == 0) {
            snap0 = cpu.st;
            ram0 = bus.flat;
        } else {
            try std.testing.expect(stateEql(snap0, cpu.st));
            try std.testing.expect(std.mem.eql(u8, &ram0, &bus.flat));
        }
    }
}

test "M6: deterministic to cycle N twice — byte-identical including a faulting path" {
    // Same idea but the program divides by zero (#DE) and the handler runs,
    // exercising fault delivery + IVT + a handler. Two runs must match exactly.
    var snap0: state.State = undefined;
    var ram0: [TestBus.flat_size]u8 = undefined;
    for (0..2) |run| {
        var bus = TestBus.init(std.testing.allocator);
        defer bus.deinit();
        var pic = cpu_mod.NullPic{};
        var sched = cpu_mod.NullScheduler{};
        var cpu = Cpu.init(&bus, &pic, &sched);
        cpu.loadSegment(.cs, 0);
        cpu.loadSegment(.ds, 0);
        cpu.loadSegment(.ss, 0);
        cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
        // #DE (vector 0) handler at 0x0500:0000 stores a marker then HLTs.
        bus.writePhys16(0, 0x0000); // IP
        bus.writePhys16(2, 0x0050); // CS (0x0050<<4 = 0x500)
        // Handler at phys 0x500: MOV [0x3100], 0xBEEF-ish ... keep simple: STOSB then HLT.
        bus.writeByte(0x500, 0xB0); // MOV AL, 0x42
        bus.writeByte(0x501, 0x42);
        bus.writeByte(0x502, 0xA2); // MOV [0x3100], AL
        bus.writeByte(0x503, 0x00);
        bus.writeByte(0x504, 0x31);
        bus.writeByte(0x505, 0xF4); // HLT
        // Main program at 0x2000: MOV AX,1 ; MOV CL,0 ; DIV CL  (#DE divide by zero)
        const Program = [_]u8{
            0xB8, 0x01, 0x00, // MOV AX, 1
            0xB1, 0x00, // MOV CL, 0
            0xF6, 0xF1, // DIV CL  -> #DE
        };
        for (Program, 0..) |b, i| bus.writeByte(@intCast(0x2000 + i), b);
        cpu.st.eip = 0x2000;
        // Step until halted or a step budget runs out.
        var n: u32 = 0;
        while (n < 16) : (n += 1) {
            const r = cpu.step();
            if (r.stop_reason == .halted) break;
        }
        if (run == 0) {
            snap0 = cpu.st;
            ram0 = bus.flat;
        } else {
            try std.testing.expect(stateEql(snap0, cpu.st));
            try std.testing.expect(std.mem.eql(u8, &ram0, &bus.flat));
        }
    }
    // The handler ran (marker written) and the CPU halted deterministically.
    try std.testing.expectEqual(@as(u8, 0x42), ram0[0x3100]);
}

test "M6: reset is deterministic — two fresh resets are byte-identical (no uninitialized reads)" {
    // State.reset() must set EVERY field deterministically (constraint #5): two
    // independently-poisoned-then-reset States compare byte-identical.
    var a: state.State = undefined;
    var b: state.State = undefined;
    // Poison with different garbage; reset must overwrite all of it.
    @memset(std.mem.asBytes(&a), 0xAA);
    @memset(std.mem.asBytes(&b), 0x55);
    a.reset();
    b.reset();
    try std.testing.expect(stateEql(a, b));
    // And equal to a fresh default-initialized + reset State.
    var c: state.State = .{};
    c.reset();
    try std.testing.expect(stateEql(a, c));
}

test "M6: TestBus init is deterministic — fresh buses are byte-identical (deterministic memory init)" {
    var b0 = TestBus.init(std.testing.allocator);
    defer b0.deinit();
    var b1 = TestBus.init(std.testing.allocator);
    defer b1.deinit();
    // Never-written memory reads back the deterministic fill, identically.
    try std.testing.expect(std.mem.eql(u8, &b0.flat, &b1.flat));
    try std.testing.expectEqual(TestBus.fill, b0.readPhys8(0x1234));
    try std.testing.expectEqual(b0.readPhys8(0x1234), b1.readPhys8(0x1234));
    // Sparse pages (32-bit addressing region) also init to the fill.
    try std.testing.expectEqual(TestBus.fill, b0.readPhys8(0x00200000));
    try std.testing.expectEqual(b0.readPhys8(0x00200000), b1.readPhys8(0x00200000));
}

test "M6: snapshot-only-at-instruction-boundary invariant" {
    // The API server may snapshot State ONLY at an instruction boundary: there
    // is no consistent partial-instruction State to serialize. step() is the
    // boundary; the decode scratch (cpu.dec / instr_start_eip) is rebuilt every
    // step() and is NOT part of the serializable State. We assert that the
    // serializable surface is exactly `cpu.st` (State) by snapshotting between
    // steps and restoring with full fidelity — proving no execution state lives
    // outside State across a boundary.
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);
    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ds, 0);
    cpu.loadSegment(.ss, 0);
    cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    cpu.st.eip = 0x2000;
    const Program = [_]u8{ 0xB8, 0x34, 0x12, 0x40, 0x40, 0x40 }; // MOV AX,0x1234 ; INC AX*3
    for (Program, 0..) |b, i| bus.writeByte(@intCast(0x2000 + i), b);

    _ = cpu.step(); // boundary after MOV
    const snap = cpu.st; // snapshot at a boundary — the ONLY valid snapshot point
    _ = cpu.step(); // INC
    _ = cpu.step(); // INC
    const advanced_ax = cpu.st.getReg16(0);
    // Restore the boundary snapshot into a fresh CPU; resuming reproduces state.
    var bus2 = TestBus.init(std.testing.allocator);
    defer bus2.deinit();
    for (Program, 0..) |b, i| bus2.writeByte(@intCast(0x2000 + i), b);
    var pic2 = cpu_mod.NullPic{};
    var sched2 = cpu_mod.NullScheduler{};
    var cpu2 = Cpu.init(&bus2, &pic2, &sched2);
    cpu2.st = snap; // restore ONLY State — nothing else needed across a boundary
    _ = cpu2.step();
    _ = cpu2.step();
    // Resuming from the restored boundary snapshot reproduces the same result,
    // proving State is the complete cross-boundary serializable surface.
    try std.testing.expectEqual(advanced_ax, cpu2.st.getReg16(0));
}

test "State save/restore is lossless (no hidden state outside State)" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = Cpu.init(&bus, &pic, &sched);
    cpu.loadSegment(.cs, 0);
    cpu.loadSegment(.ds, 0);
    cpu.loadSegment(.ss, 0);
    cpu.st.eip = 0x2000;
    // Run a few instructions to populate state, including a shadow-arming STI.
    const prog = [_]u8{ 0xB8, 0x34, 0x12, 0xFB }; // MOV AX,0x1234 ; STI
    for (prog, 0..) |b, i| bus.writeByte(@intCast(0x2000 + i), b);
    _ = cpu.step();
    _ = cpu.step();

    // Snapshot the entire State (the only mutable machine state).
    const snapshot = cpu.st;
    // Mutate, then restore.
    cpu.st.setReg16(0, 0);
    cpu.st.eip = 0;
    cpu.st = snapshot;
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.st.getReg16(0));
    try std.testing.expectEqual(snapshot.inhibit_irq_one_instruction, cpu.st.inhibit_irq_one_instruction);
    try std.testing.expectEqual(snapshot.cycles, cpu.st.cycles);
}
