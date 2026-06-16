//! EXE/COM loader tests (M3) — the "zdos runs real DOS software" proof. A tiny COM
//! and a tiny EXE (with a relocation) are written to a host temp dir, loaded
//! through the loader, run on the real machine, and their printed output (via the
//! CON device) + exit code asserted. Both are byte-identical across two runs.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine_mod.Machine;
const Reg32 = cpu_mod.state.Reg32;

fn untilHalt(mm: *Machine) bool {
    return mm.cpu.st.halted or mm.dos.terminated;
}

const Ctx = struct {
    m: *Machine,
    td: std.testing.TmpDir,
    alloc: std.mem.Allocator,
    fn deinit(self: *Ctx) void {
        self.td.cleanup();
        self.m.deinit();
        self.alloc.destroy(self.m);
    }
};

fn boot(alloc: std.mem.Allocator) !Ctx {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    const td = std.testing.tmpDir(.{ .iterate = true });
    m.dos.mountDrive(2, td.dir, std.testing.io);
    m.dos.current_drive = 2;
    return .{ .m = m, .td = td, .alloc = alloc };
}

fn writeHostFile(ctx: *Ctx, name: []const u8, bytes: []const u8) !void {
    const f = try ctx.td.dir.createFile(std.testing.io, name, .{});
    defer f.close(std.testing.io);
    var w = f.writer(std.testing.io, &.{});
    try w.interface.writeAll(bytes);
}

// A tiny COM: print "OK$" via AH=09 then exit(7) via AH=4C.
//   MOV AH,09 ; MOV DX,0x010C ; INT 21 ; MOV AX,0x4C07 ; INT 21 ; "OK$"
// COM loads at PSP:0x100, so the string at file offset 0x0C is at 0x010C.
const com_program = [_]u8{
    0xB4, 0x09, // MOV AH,0x09
    0xBA, 0x0C, 0x01, // MOV DX,0x010C
    0xCD, 0x21, // INT 0x21
    0xB8, 0x07, 0x4C, // MOV AX,0x4C07
    0xCD, 0x21, // INT 0x21
    'O', 'K', '$', // the string at offset 0x0C
};

test "COM loads, prints via AH=09, exits with code (M3)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    try writeHostFile(&ctx, "HELLO.COM", &com_program);

    try ctx.m.bootProgram(2, "HELLO.COM", "");
    _ = ctx.m.runUntil(untilHalt, 1_000_000);

    try std.testing.expect(ctx.m.dos.terminated);
    try std.testing.expectEqualStrings("OK", ctx.m.dos.dev_table.con.output());
    try std.testing.expectEqual(@as(u16, 7), ctx.m.dos.ret_code);
}

// A tiny EXE with ONE relocation. The program:
//   PUSH CS ; POP DS            (DS = load_seg, where the message lives)
//   MOV AH,09 ; MOV DX,msg ; INT 21 ; MOV AX,0x4C05 ; INT 21
//   msg: "EX$"
// One relocation patches a far pointer word so we exercise the fixup path: we put
// a word in the image that should have load_seg added. We verify it post-load.
fn buildExe(buf: []u8) usize {
    // Header (28 bytes) + a small image. header_paras = 2 (32 bytes header), so the
    // relocation table can live at offset 0x1C (28).
    // The code is 14 bytes; the message "EX$" follows at offset 0x0E, then a
    // relocatable word at offset 0x11 (initially 0) that gets load_seg added.
    const code = [_]u8{
        0x0E, // PUSH CS                (offset 0x00)
        0x1F, // POP DS                 (0x01)
        0xB4, 0x09, // MOV AH,9         (0x02)
        0xBA, 0x0E, 0x00, // MOV DX,0x000E  (0x04) -> msg offset
        0xCD, 0x21, // INT 21           (0x07)
        0xB8, 0x05, 0x4C, // MOV AX,0x4C05  (0x09)
        0xCD, 0x21, // INT 21           (0x0C)
        'E', 'X', '$', // msg           (0x0E..0x10)
        0x00, 0x00, // relocatable word (0x11)
    };
    const header_paras: u16 = 2; // 32-byte header
    const header_bytes: u16 = header_paras * 16;
    const image_total = header_bytes + code.len;
    const pages: u16 = @intCast((image_total + 511) / 512);

    @memset(buf[0..image_total], 0);
    // MZ header.
    putW(buf, 0, 0x5A4D); // 'MZ'
    putW(buf, 2, @intCast(image_total % 512)); // extra bytes in last page
    putW(buf, 4, pages);
    putW(buf, 6, 1); // 1 relocation
    putW(buf, 8, header_paras);
    putW(buf, 10, 0x10); // min_alloc
    putW(buf, 12, 0xFFFF); // max_alloc
    putW(buf, 14, 0); // init_ss
    putW(buf, 16, 0x100); // init_sp
    putW(buf, 18, 0); // checksum
    putW(buf, 20, 0); // init_ip
    putW(buf, 22, 0); // init_cs (relative to load_seg)
    putW(buf, 24, 0x1C); // reloc_table offset
    putW(buf, 26, 0); // overlay
    // Relocation entry at 0x1C: offset:segment of the word to fix up. The word is
    // at code offset 0x11 -> segment 0, offset 0x11 within the load segment.
    putW(buf, 0x1C, 0x11); // offset
    putW(buf, 0x1E, 0x00); // segment
    // Code at header_bytes.
    @memcpy(buf[header_bytes .. header_bytes + code.len], &code);
    return image_total;
}

fn putW(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

test "EXE loads, applies a relocation, prints, exits (M3)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    var exe_buf: [256]u8 = undefined;
    const n = buildExe(&exe_buf);
    try writeHostFile(&ctx, "PROG.EXE", exe_buf[0..n]);

    try ctx.m.bootProgram(2, "PROG.EXE", "");
    // The load segment is current after bootProgram (DS=CS=load_seg). Capture it to
    // verify the relocation applied: the word at load_seg:0x14 should == load_seg.
    const load_seg = ctx.m.cpu.st.selector[@intFromEnum(cpu_mod.state.Seg.cs)];
    const reloc_word = ctx.m.bus.readPhys16((@as(u32, load_seg) << 4) + 0x11);
    try std.testing.expectEqual(load_seg, reloc_word);

    _ = ctx.m.runUntil(untilHalt, 1_000_000);
    try std.testing.expect(ctx.m.dos.terminated);
    try std.testing.expectEqualStrings("EX", ctx.m.dos.dev_table.con.output());
    try std.testing.expectEqual(@as(u16, 5), ctx.m.dos.ret_code);
}

// Real-mode 1 MiB address-wrap regression (the EXEPACK root cause). EXEPACK's
// self-decompressor reads its backward-overlapping source through a segment that
// it deliberately underflows, relying on the 8086 1 MiB wraparound (A20 OFF) to
// land back in conventional memory. A POST that wrongly enabled A20 broke that
// wrap and made every EXEPACK'd EXE print "Packed file is corrupt". This COM
// reproduces the exact pointer pattern at the guest level: it writes a sentinel
// (0xB0 — the EXEPACK "run" command byte, fittingly) to ABSOLUTE phys 0x200 via
// segment 0, then reads it back through 0xFFFF:0x210 (= phys 0x100200) which is
// only correct if the access wraps to 0x000200 (A20 off, post-POST default).
//   mov ax,0      ; ds=0 -> absolute addressing
//   mov ds,ax
//   mov byte [0x500],0xB0     ; sentinel at phys 0x500 (free DOS scratch, above BDA)
//   mov ax,0xFFFF ; ds=0xFFFF
//   mov ds,ax
//   mov al,[0x510]            ; phys 0xFFFF0+0x510 = 0x100500 -> wraps to 0x500
//   cmp al,0xB0
//   jne fail
//   mov ax,0x4C00 ; int21      ; exit(0)  -> wrap worked
//   fail: mov ax,0x4CB0 ; int21 ; exit(0xB0) -> no wrap (A20 was on)
const wrap_com = [_]u8{
    0xB8, 0x00, 0x00, //          MOV AX,0x0000        (0x00)
    0x8E, 0xD8, //                MOV DS,AX            (0x03)
    0xC6, 0x06, 0x00, 0x05, 0xB0, // MOV byte [0x0500],0xB0 (0x05)
    0xB8, 0xFF, 0xFF, //          MOV AX,0xFFFF        (0x0A)
    0x8E, 0xD8, //                MOV DS,AX            (0x0D)
    0xA0, 0x10, 0x05, //          MOV AL,[0x0510]      (0x0F) -> phys 0x100500
    0x3C, 0xB0, //                CMP AL,0xB0          (0x12)
    0x75, 0x04, //                JNE +4 (-> 0x1A)     (0x14)
    0xB8, 0x00, 0x4C, //          MOV AX,0x4C00        (0x16) exit(0)
    0xCD, 0x21, //                INT 0x21             (0x19) — never reached on fail
    0xB8, 0xB0, 0x4C, //          MOV AX,0x4CB0        (0x1A) exit(0xB0)
    0xCD, 0x21, //                INT 0x21             (0x1D)
};

test "real-mode 1 MiB wrap holds after POST (EXEPACK regression)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    // A normal boot: POST must leave A20 OFF so the wrap below resolves.
    try std.testing.expect(!ctx.m.bus.a20Enabled());
    try writeHostFile(&ctx, "WRAP.COM", &wrap_com);
    try ctx.m.bootProgram(2, "WRAP.COM", "");
    _ = ctx.m.runUntil(untilHalt, 1_000_000);
    try std.testing.expect(ctx.m.dos.terminated);
    // exit(0) means the read through 0xFFFF:0x210 wrapped to phys 0x200 and saw the
    // sentinel; exit(0xB0) would mean A20 was on (no wrap) — the original bug.
    try std.testing.expectEqual(@as(u16, 0), ctx.m.dos.ret_code);
}

test "the COM run is byte-identical across two runs incl. cycles" {
    const alloc = std.testing.allocator;
    var res: [2]struct { out: [8]u8, out_len: usize, code: u16, cycles: u64 } = undefined;
    for (0..2) |run| {
        var ctx = try boot(alloc);
        defer ctx.deinit();
        try writeHostFile(&ctx, "HELLO.COM", &com_program);
        try ctx.m.bootProgram(2, "HELLO.COM", "");
        _ = ctx.m.runUntil(untilHalt, 1_000_000);
        const out = ctx.m.dos.dev_table.con.output();
        res[run].out_len = out.len;
        @memcpy(res[run].out[0..out.len], out);
        res[run].code = ctx.m.dos.ret_code;
        res[run].cycles = ctx.m.cpu.st.cycles;
    }
    try std.testing.expectEqualStrings(res[0].out[0..res[0].out_len], res[1].out[0..res[1].out_len]);
    try std.testing.expectEqual(res[0].code, res[1].code);
    try std.testing.expectEqual(res[0].cycles, res[1].cycles);
}
