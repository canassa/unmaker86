//! Execution unit tests (M2+): runs full instructions through step()/executeOne.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const state = @import("state.zig");
const Seg = state.Seg;
const Reg32 = state.Reg32;

const TestBus = cpu_mod.TestBus;
const Cpu = cpu_mod.Cpu(TestBus);

pub const Harness = struct {
    bus: TestBus,
    pic: cpu_mod.NullPic = .{},
    sched: cpu_mod.NullScheduler = .{},
    cpu: Cpu = undefined,

    pub fn init(self: *Harness, alloc: std.mem.Allocator) void {
        self.bus = TestBus.init(alloc);
        self.cpu = Cpu.init(&self.bus, &self.pic, &self.sched);
        self.cpu.loadSegment(.cs, 0);
        self.cpu.loadSegment(.ds, 0);
        self.cpu.loadSegment(.ss, 0);
        self.cpu.loadSegment(.es, 0);
        self.cpu.st.eip = 0x2000;
        self.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xF000);
    }
    pub fn deinit(self: *Harness) void {
        self.bus.deinit();
    }
    pub fn lay(self: *Harness, bytes: []const u8) void {
        for (bytes, 0..) |b, i| self.bus.writeByte(@intCast(0x2000 + i), b);
        self.cpu.st.eip = 0x2000;
    }
    pub fn run1(self: *Harness) state.StepResult {
        return self.cpu.step();
    }
};

test "MOV r16, imm16 (B8)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{ 0xB8, 0x34, 0x12 }); // MOV AX, 0x1234
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x1234), h.cpu.st.getReg16(0));
    try std.testing.expectEqual(@as(u32, 0x2003), h.cpu.st.eip);
}

test "MOV r/m8, reg8 (88) to memory" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(0, 0xAB); // AL
    // MOV [0x3000], AL : 88 06 00 30
    h.lay(&.{ 0x88, 0x06, 0x00, 0x30 });
    _ = h.run1();
    try std.testing.expectEqual(@as(u8, 0xAB), h.bus.readByte(0x3000));
}

test "ADD AX, imm16 sets flags" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(0, 0xFFFF);
    h.lay(&.{ 0x05, 0x01, 0x00 }); // ADD AX, 1 -> 0, carry
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0), h.cpu.st.getReg16(0));
    try std.testing.expect(h.cpu.st.eflags.cf and h.cpu.st.eflags.zf);
}

test "Grp1 ADD r/m8, imm8 (80 /0)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(1, 0x10); // CL = reg index 1
    h.lay(&.{ 0x80, 0xC1, 0x05 }); // ADD CL, 5
    _ = h.run1();
    try std.testing.expectEqual(@as(u8, 0x15), h.cpu.st.getReg8(1));
}

test "0x82 aliases 0x80 (Grp1 r/m8 imm8)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(2, 0x20); // DL = reg index 2
    h.lay(&.{ 0x82, 0xC2, 0x01 }); // ADD DL, 1 via the 0x82 alias
    _ = h.run1();
    try std.testing.expectEqual(@as(u8, 0x21), h.cpu.st.getReg8(2));
}

test "INC/DEC reg16" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(@intFromEnum(Reg32.ecx), 0x00FF);
    h.lay(&.{0x41}); // INC CX
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x0100), h.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
}

test "PUSH/POP reg16 round-trip" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(0, 0xBEEF); // AX
    h.lay(&.{0x50}); // PUSH AX
    _ = h.run1();
    h.lay(&.{0x5B}); // POP BX
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0xBEEF), h.cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
}

test "operand-size prefix 0x66 makes 32-bit MOV" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{ 0x66, 0xB8, 0x78, 0x56, 0x34, 0x12 }); // MOV EAX, 0x12345678
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x12345678), h.cpu.st.getReg32(0));
}

test "SHL r/m8, 1 (D0 /4)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(0, 0x81); // AL
    h.lay(&.{ 0xD0, 0xE0 }); // SHL AL,1
    _ = h.run1();
    try std.testing.expectEqual(@as(u8, 0x02), h.cpu.st.getReg8(0));
    try std.testing.expect(h.cpu.st.eflags.cf);
}

test "MUL r/m8 (F6 /4) AX = AL*op" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(0, 0x10); // AL = 16
    h.cpu.st.setReg8(1, 0x10); // CL = 16
    h.lay(&.{ 0xF6, 0xE1 }); // MUL CL
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x0100), h.cpu.st.getReg16(0));
}

test "DIV by zero raises #DE (restartable EIP)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg16(0, 0x0010); // AX
    h.cpu.st.setReg8(1, 0x00); // CL = 0
    h.lay(&.{ 0xF6, 0xF1 }); // DIV CL
    // IVT entry 0 (#DE) -> 0:0x1000
    h.bus.writeByte(0, 0x00);
    h.bus.writeByte(1, 0x10);
    h.bus.writeByte(2, 0x00);
    h.bus.writeByte(3, 0x00);
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x1000), h.cpu.st.eip);
    // The faulting instruction's EIP was pushed (restartable): popped IP = 0x2000.
    const sp = h.cpu.st.getReg16(@intFromEnum(Reg32.esp));
    const pushed_ip = h.bus.readPhys16(sp);
    try std.testing.expectEqual(@as(u16, 0x2000), pushed_ip);
}

test "JMP rel8 forward" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.lay(&.{ 0xEB, 0x05 }); // JMP +5
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x2002 + 5), h.cpu.st.eip);
}

test "Jcc taken/not-taken (JZ)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.eflags.zf = true;
    h.lay(&.{ 0x74, 0x10 }); // JZ +0x10
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x2002 + 0x10), h.cpu.st.eip);
}

test "CALL/RET near round-trip" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // CALL +0 then RET. At 0x2000: E8 00 00 (CALL to 0x2003). At 0x2003: C3 (RET)
    h.lay(&.{ 0xE8, 0x00, 0x00 });
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x2003), h.cpu.st.eip);
    h.bus.writeByte(0x2003, 0xC3); // RET
    h.cpu.st.eip = 0x2003;
    h.cpu.dec.reset();
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x2003), h.cpu.st.eip); // returned to after CALL
}

test "REP MOVSB copies a block" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // source at 0x4000, dest at 0x5000, count 4
    h.bus.writeByte(0x4000, 0xDE);
    h.bus.writeByte(0x4001, 0xAD);
    h.bus.writeByte(0x4002, 0xBE);
    h.bus.writeByte(0x4003, 0xEF);
    h.cpu.st.setReg16(@intFromEnum(Reg32.esi), 0x4000);
    h.cpu.st.setReg16(@intFromEnum(Reg32.edi), 0x5000);
    h.cpu.st.setReg16(@intFromEnum(Reg32.ecx), 4);
    h.cpu.st.eflags.df = false;
    // REP MOVSB at 0x2000 — re-enters until CX=0.
    h.lay(&.{ 0xF3, 0xA4 });
    var guard: u32 = 0;
    while (h.cpu.st.getReg16(@intFromEnum(Reg32.ecx)) != 0 and guard < 100) : (guard += 1) {
        _ = h.run1();
    }
    try std.testing.expectEqual(@as(u8, 0xDE), h.bus.readByte(0x5000));
    try std.testing.expectEqual(@as(u8, 0xEF), h.bus.readByte(0x5003));
    try std.testing.expectEqual(@as(u16, 0), h.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
}

test "DAA after addition" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // AL=0x15 + 0x27 = 0x3C; DAA -> 0x42
    h.cpu.st.setReg8(0, 0x15);
    h.lay(&.{ 0x04, 0x27, 0x27 }); // ADD AL, 0x27 ; then DAA at next
    _ = h.run1(); // ADD AL,0x27 -> 0x3C
    h.lay(&.{0x27}); // DAA
    _ = h.run1();
    try std.testing.expectEqual(@as(u8, 0x42), h.cpu.st.getReg8(0));
}

test "MOVZX r32, r/m8 (0F B6)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(1, 0xFF); // CL
    // 66 0F B6 C1 : MOVZX EAX, CL
    h.lay(&.{ 0x66, 0x0F, 0xB6, 0xC1 });
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x000000FF), h.cpu.st.getReg32(0));
}

test "MOVSX r16, r/m8 (0F BE)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.cpu.st.setReg8(1, 0xFF); // CL = -1
    h.lay(&.{ 0x0F, 0xBE, 0xC1 }); // MOVSX AX, CL
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0xFFFF), h.cpu.st.getReg16(0));
}

test "LGDT/SGDT round-trip via memory" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // Build a GDTR image at 0x3000: limit=0x1234, base=0x00ABCDEF
    h.bus.writePhys16(0x3000, 0x1234);
    h.bus.writePhys32(0x3002, 0x00ABCDEF);
    // LGDT [0x3000] : 0F 01 /2, mod00 rm110 disp16
    h.lay(&.{ 0x0F, 0x01, 0x16, 0x00, 0x30 });
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x1234), h.cpu.st.gdtr_limit);
    try std.testing.expectEqual(@as(u32, 0x00ABCDEF), h.cpu.st.gdtr_base);
}

test "PM-only LLDT raises #UD in real mode (Grp6)" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.bus.writeByte(6 * 4, 0x00);
    h.bus.writeByte(6 * 4 + 1, 0x10); // #UD vector -> 0:0x1000
    h.lay(&.{ 0x0F, 0x00, 0xD0 }); // 0F 00 /2 LLDT
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x1000), h.cpu.st.eip);
}

test "BSWAP is #UD on 386" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    h.bus.writeByte(6 * 4, 0x00);
    h.bus.writeByte(6 * 4 + 1, 0x10);
    h.lay(&.{ 0x0F, 0xC8 }); // BSWAP EAX (486+)
    _ = h.run1();
    try std.testing.expectEqual(@as(u32, 0x1000), h.cpu.st.eip);
}

test "INT n delivers via IVT and IRET returns" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // IVT entry 0x21 -> 0x100:0x0000
    h.bus.writePhys16(0x21 * 4, 0x0000); // IP
    h.bus.writePhys16(0x21 * 4 + 2, 0x0100); // CS
    h.lay(&.{ 0xCD, 0x21 }); // INT 0x21
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x0100), h.cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0), h.cpu.st.eip);
    try std.testing.expect(!h.cpu.st.eflags.iff); // IF cleared
    // Now IRET at CS:IP = 0x100:0
    h.bus.writeByte(0x1000, 0xCF); // IRET at linear 0x100<<4 + 0 = 0x1000
    h.cpu.dec.reset();
    _ = h.run1();
    try std.testing.expectEqual(@as(u16, 0x0000), h.cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0x2002), h.cpu.st.eip);
}

test "unmapped opcode raises #UD" {
    var h: Harness = undefined;
    h.init(std.testing.allocator);
    defer h.deinit();
    // 0x0F 0xFF is not mapped.
    h.lay(&.{ 0x0F, 0xFF });
    // step delivers via IVT; set up IVT entry 6 (#UD) at 0:0x18.
    h.bus.writeByte(6 * 4, 0x00);
    h.bus.writeByte(6 * 4 + 1, 0x10); // IP=0x1000
    h.bus.writeByte(6 * 4 + 2, 0x00);
    h.bus.writeByte(6 * 4 + 3, 0x00); // CS=0
    _ = h.run1();
    // EIP should be at the #UD handler (0x1000).
    try std.testing.expectEqual(@as(u32, 0x1000), h.cpu.st.eip);
}
