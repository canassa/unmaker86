//! Branch-trace functional + determinism + no-flood tests (docs/branch-trace-plan.md
//! §9). Drives a bare `Cpu(TestBus)` with a stack-allocated `BranchTrace` wired via the
//! `cpu.branch_trace` back-pointer (exactly as `Machine.wire` does), single-stepping
//! known instructions and asserting the recorded entries (kind/from/to/sp/at_cycle).

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const state = @import("state.zig");
const bt = @import("branch_trace.zig");
const Reg32 = state.Reg32;

const TestBus = cpu_mod.TestBus;
const Cpu = cpu_mod.Cpu(TestBus);
const BranchKind = bt.BranchKind;

const H = struct {
    bus: TestBus,
    pic: cpu_mod.NullPic = .{},
    sched: cpu_mod.NullScheduler = .{},
    cpu: Cpu = undefined,
    trace: bt.BranchTrace = .{},

    fn init(self: *H, alloc: std.mem.Allocator) void {
        self.bus = TestBus.init(alloc);
        self.pic = .{};
        self.sched = .{};
        self.trace = .{};
        self.cpu = Cpu.init(&self.bus, &self.pic, &self.sched);
        self.cpu.branch_trace = &self.trace; // mirror Machine.wire
        self.cpu.loadSegment(.cs, 0);
        self.cpu.loadSegment(.ds, 0);
        self.cpu.loadSegment(.ss, 0);
        self.cpu.loadSegment(.es, 0);
        self.cpu.st.idtr_base = 0;
        self.cpu.st.idtr_limit = 0x3FF;
        self.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
        self.cpu.st.eip = 0x2000;
    }
    fn deinit(self: *H) void {
        self.bus.deinit();
    }
    fn lay(self: *H, addr: u32, bytes: []const u8) void {
        for (bytes, 0..) |b, i| self.bus.writeByte(@intCast(addr + i), b);
    }
    fn ivt(self: *H, vec: u8, cs: u16, ip: u16) void {
        self.bus.writePhys16(@as(u32, vec) * 4, ip);
        self.bus.writePhys16(@as(u32, vec) * 4 + 2, cs);
    }
    fn last(self: *const H) bt.BranchEntry {
        const t = &self.trace;
        return t.entries[(t.head + bt.TRACE_CAPACITY - 1) % bt.TRACE_CAPACITY];
    }
    fn at(self: *H, eip: u32) void {
        self.cpu.st.eip = eip;
    }
};

test "functional trace: near call / ret / indirect jmp+call / far jmp / int / iret" {
    var h: H = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.trace.armed = true;

    // --- near-direct CALL (E8) ---
    h.lay(0x2000, &.{ 0xE8, 0x06, 0x00 }); // CALL +6 -> 0x2009
    h.at(0x2000);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.call_near_direct), e.kind);
        try std.testing.expectEqual(@as(u16, 0x2000), e.from_ip);
        try std.testing.expectEqual(@as(u16, 0x2009), e.to_ip);
        try std.testing.expectEqual(@as(u16, 0), e.from_cs);
        try std.testing.expectEqual(@as(u16, 0), e.to_cs);
    }

    // --- near RET (C3): planted return address on the stack ---
    h.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    h.bus.writePhys16(0xF000, 0x1234); // [SS:SP] = 0x1234
    h.lay(0x2100, &.{0xC3});
    h.at(0x2100);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.ret_near), e.kind);
        try std.testing.expectEqual(@as(u16, 0x2100), e.from_ip);
        try std.testing.expectEqual(@as(u16, 0x1234), e.to_ip);
        try std.testing.expectEqual(@as(u16, 0xF002), e.sp); // popped one word
    }

    // --- indirect near JMP (FF /4): JMP BX ---
    h.cpu.st.setReg16(@intFromEnum(Reg32.ebx), 0x3456);
    h.lay(0x2200, &.{ 0xFF, 0xE3 }); // JMP BX
    h.at(0x2200);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.jmp_near_ind), e.kind);
        try std.testing.expectEqual(@as(u16, 0x3456), e.to_ip);
    }

    // --- indirect near CALL (FF /2): CALL BX ---
    h.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    h.cpu.st.setReg16(@intFromEnum(Reg32.ebx), 0x6789);
    h.lay(0x2300, &.{ 0xFF, 0xD3 }); // CALL BX
    h.at(0x2300);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.call_near_ind), e.kind);
        try std.testing.expectEqual(@as(u16, 0x6789), e.to_ip);
        try std.testing.expectEqual(@as(u16, 0xEFFE), e.sp); // pushed return ip
    }

    // --- far direct JMP (EA): ptr16:16 ---
    h.lay(0x2400, &.{ 0xEA, 0x00, 0x40, 0x00, 0x10 }); // JMP 0x1000:0x4000
    h.at(0x2400);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.jmp_far), e.kind);
        try std.testing.expectEqual(@as(u16, 0x0000), e.from_cs);
        try std.testing.expectEqual(@as(u16, 0x1000), e.to_cs);
        try std.testing.expectEqual(@as(u16, 0x4000), e.to_ip);
    }

    // --- software INT (CD 21): IVT funnel records `.interrupt` ---
    h.cpu.loadSegment(.cs, 0); // back to CS 0 for the next lay
    h.ivt(0x21, 0x0800, 0x0010); // handler 0x0800:0x0010
    h.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    h.lay(0x2500, &.{ 0xCD, 0x21 }); // INT 21h
    h.at(0x2500);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.interrupt), e.kind);
        // from = the pushed return address (the byte after CD 21).
        try std.testing.expectEqual(@as(u16, 0x2502), e.from_ip);
        try std.testing.expectEqual(@as(u16, 0x0800), e.to_cs);
        try std.testing.expectEqual(@as(u16, 0x0010), e.to_ip);
    }

    // --- IRET (CF): planted ip/cs/flags on the stack ---
    h.cpu.loadSegment(.cs, 0x0800);
    h.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x0100);
    h.bus.writePhys16(0x0100, 0x2502); // IP
    h.bus.writePhys16(0x0102, 0x0000); // CS
    h.bus.writePhys16(0x0104, 0x0202); // FLAGS
    h.lay(0x0800 * 16 + 0x0020, &.{0xCF}); // IRET at 0x0800:0x0020
    h.at(0x0020);
    _ = h.cpu.step();
    {
        const e = h.last();
        try std.testing.expectEqual(@intFromEnum(BranchKind.iret), e.kind);
        try std.testing.expectEqual(@as(u16, 0x0000), e.to_cs);
        try std.testing.expectEqual(@as(u16, 0x2502), e.to_ip);
    }

    // at_cycle is monotonic non-decreasing across the recorded entries.
    var prev: u64 = 0;
    var i: u32 = 0;
    while (i < h.trace.len) : (i += 1) {
        const oldest = (h.trace.head + bt.TRACE_CAPACITY - h.trace.len) % bt.TRACE_CAPACITY;
        const e = h.trace.entries[(oldest + i) % bt.TRACE_CAPACITY];
        try std.testing.expect(e.at_cycle >= prev);
        prev = e.at_cycle;
    }
}

// A small deterministic stub that exercises several recorded transfers in a chain.
// 0x2000: CALL 0x2010      (E8 0D 00)   -> sub
// 0x2003: JMP 0x2003       (EB FE)      spin (we run a bounded number of steps)
// 0x2010: RET              (C3)
fn layChain(h: *H) void {
    h.lay(0x2000, &.{ 0xE8, 0x0D, 0x00 }); // CALL +0x0D -> 0x2010
    h.lay(0x2003, &.{ 0xEB, 0xFE }); // JMP $ (spin)
    h.lay(0x2010, &.{0xC3}); // RET
    h.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    h.at(0x2000);
}

test "determinism: two identical runs produce byte-identical rings" {
    var rings: [2]bt.BranchTrace = undefined;
    for (0..2) |run| {
        var h: H = undefined;
        h.init(std.testing.allocator);
        defer h.deinit();
        h.trace.armed = true;
        layChain(&h);
        var n: u32 = 0;
        while (n < 6) : (n += 1) _ = h.cpu.step();
        rings[run] = h.trace;
    }
    try std.testing.expectEqual(rings[0].head, rings[1].head);
    try std.testing.expectEqual(rings[0].len, rings[1].len);
    try std.testing.expectEqual(rings[0].total, rings[1].total);
    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&rings[0].entries),
        std.mem.asBytes(&rings[1].entries),
    ));
}

test "no flood: a jcc/dec loop records ZERO entries (statics not hooked)" {
    var h: H = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.trace.armed = true;
    // MOV CX, 0x40 ; DEC CX ; JNZ -3   (loop 64 times)
    h.lay(0x2000, &.{ 0xB9, 0x40, 0x00, 0x49, 0x75, 0xFD });
    h.at(0x2000);
    // Run until CX hits 0 (well-bounded): MOV + 64*(DEC+JNZ) + the final fallthrough.
    var n: u32 = 0;
    while (n < 200) : (n += 1) {
        _ = h.cpu.step();
        if (h.cpu.st.getReg16(@intFromEnum(Reg32.ecx)) == 0 and h.cpu.st.eip > 0x2005) break;
    }
    // None of MOV/DEC/JNZ is a hooked transfer → the ring stayed empty.
    try std.testing.expectEqual(@as(u32, 0), h.trace.len);
    try std.testing.expectEqual(@as(u64, 0), h.trace.total);
}

test "kind_mask off call_near_direct: E8 not recorded, RET still recorded" {
    var h: H = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.trace.armed = true;
    h.trace.kind_mask = ~(@as(u16, 1) << @intFromEnum(BranchKind.call_near_direct));
    layChain(&h);
    var n: u32 = 0;
    while (n < 4) : (n += 1) _ = h.cpu.step(); // CALL, RET, then spin
    // The CALL was masked off; only the RET recorded.
    try std.testing.expectEqual(@as(u32, 1), h.trace.len);
    try std.testing.expectEqual(@intFromEnum(BranchKind.ret_near), h.last().kind);
}

test "cycle-neutral: recording charges no cycles vs. an unwired run" {
    // Run the chain with the trace ARMED, then with the back-pointer NULL; the cycle
    // ledger after N steps must be identical (the observer charges nothing).
    var cyc_armed: u64 = 0;
    var cyc_null: u64 = 0;
    for (0..2) |mode| {
        var h: H = undefined;
        h.init(std.testing.allocator);
        defer h.deinit();
        if (mode == 0) {
            h.trace.armed = true;
        } else {
            h.cpu.branch_trace = null; // unwired: a pure no-op at every hook
        }
        layChain(&h);
        var n: u32 = 0;
        while (n < 6) : (n += 1) _ = h.cpu.step();
        if (mode == 0) cyc_armed = h.cpu.st.cycles else cyc_null = h.cpu.st.cycles;
    }
    try std.testing.expectEqual(cyc_armed, cyc_null);
}
