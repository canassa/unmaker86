//! ModR/M + SIB decode tests (Phase 2 / M1).

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decode = @import("decode.zig");
const dispatch = @import("dispatch.zig");
const state = @import("state.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;

const TestBus = cpu_mod.TestBus;
const Cpu = cpu_mod.Cpu(TestBus);

const Harness = struct {
    bus: TestBus,
    pic: cpu_mod.NullPic = .{},
    sched: cpu_mod.NullScheduler = .{},
    cpu: Cpu = undefined,

    fn init(self: *Harness, alloc: std.mem.Allocator) void {
        self.bus = TestBus.init(alloc);
        self.cpu = Cpu.init(&self.bus, &self.pic, &self.sched);
        // Put code at a known place: CS=0, DS=0, addr-size from CS.D=0 => 16-bit.
        self.cpu.loadSegment(.cs, 0);
        self.cpu.loadSegment(.ds, 0);
        self.cpu.loadSegment(.ss, 0);
        self.cpu.loadSegment(.es, 0);
        self.cpu.st.eip = 0x2000;
    }
    fn deinit(self: *Harness) void {
        self.bus.deinit();
    }
    /// Lay bytes at CS:EIP (which is linear 0x2000) and reset decode scratch.
    fn lay(self: *Harness, bytes: []const u8) void {
        for (bytes, 0..) |b, i| self.bus.writeByte(@intCast(0x2000 + i), b);
        self.cpu.st.eip = 0x2000;
        self.cpu.dec.reset();
    }
};

fn decodeModRMOnly(h: *Harness, addr32: bool) !void {
    // Skip the opcode-fetch path; set up sizes manually then decode the ModR/M.
    h.cpu.dec.addr_size = if (addr32) .a32 else .a16;
    h.cpu.dec.op_size = .b16;
    try dispatch.decodeModRM(&h.cpu);
}

test "16-bit ModR/M [BX+SI] mod00 rm000" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(@intFromEnum(Reg32.ebx), 0x1000);
    h.cpu.st.setReg16(@intFromEnum(Reg32.esi), 0x0020);
    h.lay(&.{0x00}); // mod00 reg000 rm000
    try decodeModRMOnly(&h, false);
    try std.testing.expectEqual(decode.OperandKind.mem, h.cpu.dec.kind);
    try std.testing.expectEqual(@as(u32, 0x1020), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ds, h.cpu.dec.mem_seg);
}

test "16-bit ModR/M [BP+disp8] selects SS" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(@intFromEnum(Reg32.ebp), 0x0100);
    h.lay(&.{ 0x46, 0x10 }); // mod01 rm110 ([BP]+disp8) , disp=0x10
    try decodeModRMOnly(&h, false);
    try std.testing.expectEqual(@as(u32, 0x0110), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ss, h.cpu.dec.mem_seg);
}

test "16-bit ModR/M disp16 direct mod00 rm110" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{ 0x06, 0x34, 0x12 }); // mod00 rm110, disp16=0x1234
    try decodeModRMOnly(&h, false);
    try std.testing.expectEqual(@as(u32, 0x1234), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ds, h.cpu.dec.mem_seg);
}

test "16-bit ModR/M register direct mod11" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{0xC3}); // mod11 reg000 rm011
    try decodeModRMOnly(&h, false);
    try std.testing.expectEqual(decode.OperandKind.reg, h.cpu.dec.kind);
    try std.testing.expectEqual(@as(u3, 3), h.cpu.dec.rm);
}

test "32-bit ModR/M [EAX] mod00 rm000" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg32(@intFromEnum(Reg32.eax), 0x0001_2345);
    h.lay(&.{0x00});
    try decodeModRMOnly(&h, true);
    try std.testing.expectEqual(@as(u32, 0x0001_2345), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ds, h.cpu.dec.mem_seg);
}

test "32-bit ModR/M disp32 direct mod00 rm101" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{ 0x05, 0x78, 0x56, 0x34, 0x12 });
    try decodeModRMOnly(&h, true);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), h.cpu.dec.mem_off);
}

test "32-bit SIB [EAX+ECX*4] mod00 rm100" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg32(@intFromEnum(Reg32.eax), 0x1000);
    h.cpu.st.setReg32(@intFromEnum(Reg32.ecx), 0x0010);
    // mod00 rm100 ; SIB scale=2(=>*4) index=001(ECX) base=000(EAX)
    h.lay(&.{ 0x04, 0x88 });
    try decodeModRMOnly(&h, true);
    try std.testing.expectEqual(@as(u32, 0x1000 + 0x10 * 4), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ds, h.cpu.dec.mem_seg);
}

test "32-bit SIB no-index (index=ESP) base=EBP+disp32 -> disp32 only, mod00" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // mod00 rm100; SIB scale=0 index=100(none) base=101 => disp32, no base
    h.lay(&.{ 0x04, 0x25, 0x00, 0x10, 0x00, 0x00 });
    try decodeModRMOnly(&h, true);
    try std.testing.expectEqual(@as(u32, 0x1000), h.cpu.dec.mem_off);
}

test "32-bit SIB base=EBP with mod01 selects SS" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg32(@intFromEnum(Reg32.ebp), 0x2000);
    // mod01 rm100; SIB index=none(100) base=101(EBP); disp8=4
    h.lay(&.{ 0x44, 0x25, 0x04 });
    try decodeModRMOnly(&h, true);
    try std.testing.expectEqual(@as(u32, 0x2004), h.cpu.dec.mem_off);
    try std.testing.expectEqual(Seg.ss, h.cpu.dec.mem_seg);
}

test "exhaustive 16-bit modrm decode consumes correct byte count" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    var modrm: u16 = 0;
    while (modrm < 256) : (modrm += 1) {
        const m: u8 = @intCast(modrm);
        // Provide enough trailing bytes for any disp.
        h.lay(&.{ m, 0x11, 0x22 });
        try decodeModRMOnly(&h, false);
        const consumed = h.cpu.st.eip - 0x2000;
        const mod: u2 = @truncate(m >> 6);
        const rm: u3 = @truncate(m);
        var expect: u32 = 1;
        if (mod == 0b11) {
            expect = 1;
        } else if (mod == 0 and rm == 6) {
            expect = 3; // disp16
        } else if (mod == 1) {
            expect = 2;
        } else if (mod == 2) {
            expect = 3;
        }
        try std.testing.expectEqual(expect, consumed);
    }
}
