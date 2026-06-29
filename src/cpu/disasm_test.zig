//! Disassembler tests (plans/disassembler.md §7):
//!   1. golden byte → {text, length} unit suite;
//!   2. length cross-check vs the CPU executor over the vendored conformance
//!      vectors (the anti-drift guard);
//!   3. comptime opcode-coverage (every dispatched opcode has a disasm entry).

const std = @import("std");
const disasm = @import("disasm.zig");
const cpu_mod = @import("cpu.zig");
const pt = @import("processor_tests.zig");
const build_options = @import("build_options");

const TestBus = cpu_mod.TestBus;
const RunCpu = cpu_mod.Cpu(TestBus);

/// Decode one instruction from a byte slice (real mode, cs_big=false unless set).
fn decode(bytes: []const u8, cs_big: bool, out: []u8) disasm.Insn {
    const R = struct {
        b: []const u8,
        pub fn read(self: @This(), off: u32) ?u8 {
            if (off >= self.b.len) return null;
            return self.b[off];
        }
    };
    return disasm.decodeOne(R{ .b = bytes }, 0, cs_big, out);
}

const Case = struct {
    bytes: []const u8,
    cs_big: bool = false,
    text: []const u8,
    len: u8,
};

test "disasm golden: byte -> text + length" {
    const cases = [_]Case{
        // MOV ax, imm16 (B8 34 12)
        .{ .bytes = &.{ 0xB8, 0x34, 0x12 }, .text = "mov ax, 0x1234", .len = 3 },
        // 0x66 MOV eax, imm32
        .{ .bytes = &.{ 0x66, 0xB8, 0x78, 0x56, 0x34, 0x12 }, .text = "mov eax, 0x12345678", .len = 6 },
        // MOV al, imm8
        .{ .bytes = &.{ 0xB0, 0x42 }, .text = "mov al, 0x42", .len = 2 },
        // ADD r/m, reg
        .{ .bytes = &.{ 0x01, 0xC3 }, .text = "add bx, ax", .len = 2 }, // add bx,ax
        // ADD reg, r/m (mem, BX+SI)
        .{ .bytes = &.{ 0x03, 0x00 }, .text = "add ax, [bx+si]", .len = 2 },
        // ADD AL, imm8
        .{ .bytes = &.{ 0x04, 0x10 }, .text = "add al, 0x10", .len = 2 },
        // INC reg
        .{ .bytes = &.{0x40}, .text = "inc ax", .len = 1 },
        .{ .bytes = &.{0x48}, .text = "dec ax", .len = 1 },
        // PUSH / POP reg
        .{ .bytes = &.{0x50}, .text = "push ax", .len = 1 },
        .{ .bytes = &.{0x5D}, .text = "pop bp", .len = 1 },
        // NOP
        .{ .bytes = &.{0x90}, .text = "nop", .len = 1 },
        // disp16-direct memory: MOV ax, [0x1234]
        .{ .bytes = &.{ 0x8B, 0x06, 0x34, 0x12 }, .text = "mov ax, [0x1234]", .len = 4 },
        // BP defaults to SS (symbolic only renders base): mov ax, [bp+0x4]
        .{ .bytes = &.{ 0x8B, 0x46, 0x04 }, .text = "mov ax, [bp+0x4]", .len = 3 },
        // negative disp8
        .{ .bytes = &.{ 0x8B, 0x46, 0xFC }, .text = "mov ax, [bp-0x4]", .len = 3 },
        // segment override: mov ax, es:[di]
        .{ .bytes = &.{ 0x26, 0x8B, 0x05 }, .text = "mov ax, es:[di]", .len = 3 },
        // 32-bit address SIB: mov eax, [eax+ecx*4]  (67 66 8B 04 88)
        .{ .bytes = &.{ 0x67, 0x66, 0x8B, 0x04, 0x88 }, .text = "mov eax, [eax+ecx*4]", .len = 5 },
        // 32-bit disp32 direct: mov ax, [0x12345678] (67 8B 05 ...)
        .{ .bytes = &.{ 0x67, 0x8B, 0x05, 0x78, 0x56, 0x34, 0x12 }, .text = "mov ax, [0x12345678]", .len = 7 },
        // REP MOVSW
        .{ .bytes = &.{ 0xF3, 0xA5 }, .text = "rep movsw", .len = 2 },
        // REPNE SCASB
        .{ .bytes = &.{ 0xF2, 0xAE }, .text = "repne scasb", .len = 2 },
        // near JMP rel8 forward: EB 05 -> target = 2 + 5 = 0x7
        .{ .bytes = &.{ 0xEB, 0x05 }, .text = "jmp 0x7", .len = 2 },
        // near JMP rel16: E9 00 01 -> 3 + 0x100 = 0x103
        .{ .bytes = &.{ 0xE9, 0x00, 0x01 }, .text = "jmp 0x103", .len = 3 },
        // CALL rel16: E8 fd ff -> 3 + (-3) = 0
        .{ .bytes = &.{ 0xE8, 0xFD, 0xFF }, .text = "call 0x0", .len = 3 },
        // Jcc rel8 (je)
        .{ .bytes = &.{ 0x74, 0x02 }, .text = "je 0x4", .len = 2 },
        // 0F Jcc rel16 (jne)
        .{ .bytes = &.{ 0x0F, 0x85, 0x00, 0x10 }, .text = "jne 0x1004", .len = 4 },
        // far JMP direct EA: jmp far 0x0010:0x1234
        .{ .bytes = &.{ 0xEA, 0x34, 0x12, 0x10, 0x00 }, .text = "jmp far 0x10:0x1234", .len = 5 },
        // far CALL direct 9A
        .{ .bytes = &.{ 0x9A, 0x00, 0x00, 0x20, 0x00 }, .text = "call far 0x20:0x0", .len = 5 },
        // RET / RET imm16 / RETF
        .{ .bytes = &.{0xC3}, .text = "ret", .len = 1 },
        .{ .bytes = &.{ 0xC2, 0x04, 0x00 }, .text = "ret 0x4", .len = 3 },
        .{ .bytes = &.{0xCB}, .text = "retf", .len = 1 },
        // INT n / INT3
        .{ .bytes = &.{ 0xCD, 0x21 }, .text = "int 0x21", .len = 2 },
        .{ .bytes = &.{0xCC}, .text = "int3", .len = 1 },
        // Grp1: ADD word [bx], imm8 (sign-extended) -- 83 /0 ib
        .{ .bytes = &.{ 0x83, 0x07, 0x05 }, .text = "add word [bx], 0x5", .len = 3 },
        // Grp1: CMP byte [bx], imm8 -- 80 /7 ib
        .{ .bytes = &.{ 0x80, 0x3F, 0x10 }, .text = "cmp byte [bx], 0x10", .len = 3 },
        // Grp3: TEST byte [bx], imm8 -- F6 /0
        .{ .bytes = &.{ 0xF6, 0x07, 0x01 }, .text = "test byte [bx], 0x1", .len = 3 },
        // Grp3: NEG reg
        .{ .bytes = &.{ 0xF7, 0xDB }, .text = "neg bx", .len = 2 },
        // Grp5: CALL r/m (near indirect)
        .{ .bytes = &.{ 0xFF, 0xD0 }, .text = "call ax", .len = 2 },
        // Grp5: PUSH r/m
        .{ .bytes = &.{ 0xFF, 0x37 }, .text = "push word [bx]", .len = 2 },
        // shifts: SHL reg, 1 (D1 /4)
        .{ .bytes = &.{ 0xD1, 0xE3 }, .text = "shl bx, 1", .len = 2 },
        // SHL reg, CL (D3 /4)
        .{ .bytes = &.{ 0xD3, 0xE3 }, .text = "shl bx, cl", .len = 2 },
        // SHL reg, imm8 (C1 /4)
        .{ .bytes = &.{ 0xC1, 0xE3, 0x03 }, .text = "shl bx, 0x3", .len = 3 },
        // MOVZX r, r/m8 (0F B6)
        .{ .bytes = &.{ 0x0F, 0xB6, 0xC3 }, .text = "movzx ax, bl", .len = 3 },
        // MOVSX r, r/m8 (0F BE)
        .{ .bytes = &.{ 0x0F, 0xBE, 0xC3 }, .text = "movsx ax, bl", .len = 3 },
        // SHLD r/m, reg, imm8 (0F A4)
        .{ .bytes = &.{ 0x0F, 0xA4, 0xC3, 0x04 }, .text = "shld bx, ax, 0x4", .len = 4 },
        // BT r/m, reg (0F A3)
        .{ .bytes = &.{ 0x0F, 0xA3, 0xC3 }, .text = "bt bx, ax", .len = 3 },
        // Grp8: BTS r/m, imm8 (0F BA /5)
        .{ .bytes = &.{ 0x0F, 0xBA, 0xEB, 0x02 }, .text = "bts bx, 0x2", .len = 4 },
        // SETcc (sete al) 0F 94 C0
        .{ .bytes = &.{ 0x0F, 0x94, 0xC0 }, .text = "sete al", .len = 3 },
        // MOV from CR0: 0F 20 C0  (mov eax, cr0)  -- CR moves are 32-bit operands
        .{ .bytes = &.{ 0x0F, 0x20, 0xC0 }, .text = "mov eax, cr0", .len = 3 },
        // Grp7 LIDT: 0F 01 /3
        .{ .bytes = &.{ 0x0F, 0x01, 0x1E, 0x00, 0x10 }, .text = "lidt [0x1000]", .len = 5 },
        // LEA
        .{ .bytes = &.{ 0x8D, 0x06, 0x00, 0x10 }, .text = "lea ax, [0x1000]", .len = 4 },
        // PUSH imm8 / imm16
        .{ .bytes = &.{ 0x6A, 0x05 }, .text = "push 0x5", .len = 2 },
        .{ .bytes = &.{ 0x68, 0x34, 0x12 }, .text = "push 0x1234", .len = 3 },
        // IN AL, imm8 / OUT imm8, AL
        .{ .bytes = &.{ 0xE4, 0x60 }, .text = "in al, 0x60", .len = 2 },
        .{ .bytes = &.{ 0xE6, 0x61 }, .text = "out 0x61, al", .len = 2 },
        // flag ops
        .{ .bytes = &.{0xFA}, .text = "cli", .len = 1 },
        .{ .bytes = &.{0xFB}, .text = "sti", .len = 1 },
        // no-FPU ESC range: render honestly, correct length (D8 modrm)
        .{ .bytes = &.{ 0xD8, 0x06, 0x00, 0x10 }, .text = "(no-fpu) esc 0xd8", .len = 4 },
        // unknown opcode -> db 0x<lead> length 1 (0F 0B = UD2, no entry)
        .{ .bytes = &.{ 0x0F, 0x0B }, .text = "db 0xf", .len = 1 },
    };

    var buf: [64]u8 = undefined;
    for (cases) |c| {
        const insn = decode(c.bytes, c.cs_big, &buf);
        std.testing.expectEqualStrings(c.text, insn.text) catch |e| {
            std.debug.print("FAIL bytes={x} got '{s}' len {d} want '{s}' len {d}\n", .{ c.bytes, insn.text, insn.len, c.text, c.len });
            return e;
        };
        try std.testing.expectEqual(c.len, insn.len);
    }
}

test "disasm: a NULL byte source yields db 0x00, length 1 (no fake, no crash)" {
    const R = struct {
        pub fn read(_: @This(), _: u32) ?u8 {
            return null;
        }
    };
    var buf: [64]u8 = undefined;
    const insn = disasm.decodeOne(R{}, 0, false, &buf);
    try std.testing.expectEqual(@as(u8, 1), insn.len);
    try std.testing.expectEqualStrings("db 0x0", insn.text);
}

// ---------------------------------------------------------------------------
// Length cross-check vs the CPU executor over the vendored conformance vectors.
// For each TEST vector, the bytes are the instruction-under-test followed by a
// 0xF4 HALT terminator. We run the CPU one step from the vector's initial state
// and compare the EIP delta (the bytes the CPU actually consumed) against the
// disassembler's reported length. This pins length parity across the executed
// ISA without needing golden TEXT per vector.
// ---------------------------------------------------------------------------

/// Opcode files to length-cross-check (a broad slice of the executed ISA). Kept
/// to the fully-passing curated set so a vector that the CPU itself diverges on
/// can never masquerade as a disasm length bug.
///
/// CONTROL-FLOW OPCODES ARE EXCLUDED ON PURPOSE: the cross-check infers the
/// executed instruction's length from the EIP delta (eip_after - eip_before),
/// which only equals the length for sequential (fall-through) instructions. A
/// TAKEN branch/call/jmp/ret sets EIP to its target, so the delta is the jump
/// distance, not the encoded length. Those lengths are pinned exactly by the
/// golden TEXT suite above (je/jne/jmp/call/ret/far cases) instead.
const length_check_files = [_][]const u8{
    "90", "00", "01", "02",   "03",   "05",
    "88", "89", "8A", "8B",   "40",   "48",
    "20", "08", "30", "38",   "0FAF", "50",
    "58", "AA", "AC", "0FB6", "0FBE",
};

fn cpuConsumedLen(a: std.mem.Allocator, t: pt.ProcessorTest) !?u8 {
    var bus = TestBus.init(a);
    defer bus.deinit();
    bus.port_in_value = 0xFFFF_FFFF;
    var pic = cpu_mod.NullPic{};
    var sched = cpu_mod.NullScheduler{};
    var cpu = RunCpu.init(&bus, &pic, &sched);
    pt.loadRegs(&cpu, t.initial.regs);
    for (t.initial.ram) |e| bus.writeByte(e.addr, e.value);

    const cs_base = cpu.st.seg_base[@intFromEnum(cpu_mod.Seg.cs)];
    const start_eip = cpu.st.eip;
    const start_lin = cs_base +% start_eip;

    // One step executes exactly the instruction-under-test (the next is HALT).
    _ = cpu.step();
    // If the instruction faulted (e.g. #DE / #UD), EIP jumped to a handler — skip
    // (length is not the consumed bytes in that case).
    if (cpu.st.last_delivered.seq != 0) return null;
    if (cpu.st.halted or cpu.st.shutdown) {
        // The instruction-under-test WAS the HALT (degenerate); skip.
        return null;
    }
    const consumed = cpu.st.eip -% start_eip;
    if (consumed == 0 or consumed > 15) return null;

    // Disassemble the same bytes at the same linear address.
    const Mem = struct {
        bus: *TestBus,
        base: u32,
        pub fn read(self: @This(), off: u32) ?u8 {
            return self.bus.readByte(self.base +% off);
        }
    };
    var dbuf: [64]u8 = undefined;
    const m = Mem{ .bus = &bus, .base = start_lin };
    const insn = disasm.decodeOne(m, 0, false, &dbuf);
    if (insn.len != @as(u8, @truncate(consumed))) {
        std.debug.print("LEN MISMATCH '{s}': disasm {d} != cpu {d} (text '{s}')\n", .{ t.name, insn.len, consumed, insn.text });
        return error.LengthMismatch;
    }
    return @truncate(consumed);
}

fn loadMoo(a: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, build_options.testdata_80386, .{});
    defer dir.close(io);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "v1_ex_real_mode/{s}.MOO.gz", .{name});
    const gz = try dir.readFileAlloc(io, path, a, .limited(1 << 26));
    defer a.free(gz);
    return pt.gunzip(a, gz);
}

test "disasm length == cpu-consumed length over conformance vectors" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var checked: usize = 0;
    for (length_check_files) |name| {
        const data = try loadMoo(a, io, name);
        defer a.free(data);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tests = try pt.parseMoo(arena.allocator(), data);
        // Cross-check a bounded slice per file (vectors per opcode are uniform in
        // length; 25 is plenty to catch a wrong operand-width table entry).
        const n = @min(tests.len, 25);
        for (tests[0..n]) |t| {
            if (try cpuConsumedLen(a, t)) |_| checked += 1;
        }
    }
    // The `> 100` floor is the coverage guard. No stderr diagnostic: a unit
    // test that writes to stderr makes `zig build test`'s `--listen` Run step
    // report the command as failed (the build runner expects the test child's
    // stderr to be empty), even though every assertion passes.
    try std.testing.expect(checked > 100);
}

// ---------------------------------------------------------------------------
// Comptime coverage: every one-byte and 0F opcode the CPU DISPATCHES (does not
// #UD) must produce a non-`(bad)` disasm. We assert this at runtime over all 512
// opcodes by feeding a canonical encoding and checking the disasm did not bail to
// the `db`/`(bad)` fallback for an opcode the executor handles.
// ---------------------------------------------------------------------------

/// True iff the CPU's dispatch maps this opcode to something OTHER than #UD.
/// Derived from exec.zig's dispatch arms (the source of truth). Kept here as the
/// shared opcode-list the plan's §7.3 coverage test asserts against; a new CPU
/// opcode that lands without a disasm entry fails this test.
fn cpuHandlesOneByte(op: u8) bool {
    return switch (op) {
        0x63 => false, // ARPL #UD in real mode (PINNED) — but disasm still renders it
        else => true, // every other one-byte opcode is dispatched
    };
}

fn cpuHandlesTwoByte(op: u8) bool {
    return switch (op) {
        0x01, 0x02, 0x03, 0x06, 0x08, 0x09, 0x20, 0x21, 0x22, 0x23 => true,
        0x80...0x8F, 0x90...0x9F => true,
        0xA0, 0xA1, 0xA3, 0xA4, 0xA5, 0xA8, 0xA9, 0xAB, 0xAC, 0xAD, 0xAF => true,
        0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF => true,
        else => false,
    };
}

test "disasm coverage: every dispatched opcode renders a mnemonic (no (bad))" {
    var buf: [64]u8 = undefined;
    // One-byte opcodes: encode `<op> 00 00 00 ...` (ModR/M 00 = [bx+si], lots of
    // trailing zeros for immediates). 0x0F is the two-byte escape, skip here.
    var op: u16 = 0;
    while (op <= 0xFF) : (op += 1) {
        if (op == 0x0F) continue;
        if (!cpuHandlesOneByte(@truncate(op))) continue;
        const bytes = [_]u8{ @truncate(op), 0x00, 0x00, 0x00, 0x00, 0x00 };
        const insn = decode(&bytes, false, &buf);
        if (std.mem.startsWith(u8, insn.text, "(bad)") or std.mem.startsWith(u8, insn.text, "db ")) {
            std.debug.print("uncovered one-byte opcode 0x{x}: '{s}'\n", .{ op, insn.text });
            return error.UncoveredOpcode;
        }
    }
    // Two-byte (0F) opcodes.
    op = 0;
    while (op <= 0xFF) : (op += 1) {
        if (!cpuHandlesTwoByte(@truncate(op))) continue;
        // ModR/M `00` selects reg-field 0, which is fine for most opcodes. But
        // 0F BA is Grp8 (BT/BTS/BTR/BTC), where ONLY reg 4-7 are defined — reg
        // 0-3 are #UD, so a `db` fallback there is correct, not "uncovered".
        // Feed a defined reg (mod=3,reg=4=BT,rm=0 -> 0xE0) for that opcode.
        const modrm: u8 = if (op == 0xBA) 0xE0 else 0x00;
        const bytes = [_]u8{ 0x0F, @truncate(op), modrm, 0x00, 0x00, 0x00, 0x00 };
        const insn = decode(&bytes, false, &buf);
        if (std.mem.startsWith(u8, insn.text, "(bad)") or std.mem.startsWith(u8, insn.text, "db ")) {
            std.debug.print("uncovered 0F opcode 0x{x}: '{s}'\n", .{ op, insn.text });
            return error.UncoveredOpcode;
        }
    }
}
