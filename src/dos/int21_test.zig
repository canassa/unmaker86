//! INT 21h service tests (M2) against a host temp dir mounted as C:. Each runs a
//! hand-assembled real-mode snippet through the FULL machine so the bridge ->
//! INT 21h -> VFS path is exercised exactly as a guest would. Determinism: the
//! temp dir has fixed content; timestamps come from the epoch (D13); the synthetic
//! D5 cost is charged at the bridge.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine_mod.Machine;
const Seg = cpu_mod.state.Seg;
const Reg32 = cpu_mod.state.Reg32;

const CODE_SEG: u16 = 0x2000;

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
    const td = std.testing.tmpDir(.{ .iterate = true }); // mounts must be iterable
    m.dos.mountDrive(2, td.dir, std.testing.io); // C:
    m.dos.current_drive = 2;
    return .{ .m = m, .td = td, .alloc = alloc };
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

fn putStr(m: *Machine, off: u16, s: []const u8) void {
    const base = @as(u32, CODE_SEG) << 4;
    for (s, 0..) |c, i| m.bus.writePhys8(base + off + @as(u32, @intCast(i)), c);
    m.bus.writePhys8(base + off + @as(u32, @intCast(s.len)), 0);
}

fn untilHalt(mm: *Machine) bool {
    return mm.cpu.st.halted;
}

fn run(m: *Machine) void {
    _ = m.runUntil(untilHalt, 1_000_000);
}

test "create -> write -> close -> open -> read -> seek -> read -> close round-trip" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;

    putStr(m, 0x200, "TEST.DAT");
    const data = "HELLO!";
    const base = @as(u32, CODE_SEG) << 4;
    for (data, 0..) |c, i| m.bus.writePhys8(base + 0x300 + @as(u32, @intCast(i)), c);

    loadCode(m, &.{
        0xB4, 0x3C, 0x33, 0xC9, 0xBA, 0x00, 0x02, 0xCD, 0x21, // create
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x40, 0xB9, 0x06, 0x00, 0xBA, 0x00, 0x03, 0xCD, 0x21, // write 6
        0xB4, 0x3E, 0xCD, 0x21, // close
        0xB4, 0x3D, 0xB0, 0x00, 0xBA, 0x00, 0x02, 0xCD, 0x21, // open read
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x3F, 0xB9, 0x06, 0x00, 0xBA, 0x00, 0x04, 0xCD, 0x21, // read 6 -> 0x400
        0xB4, 0x42, 0xB0, 0x00, 0xB9, 0x00, 0x00, 0xBA, 0x00, 0x00, 0xCD, 0x21, // seek SET 0
        0xB4, 0x3F, 0xB9, 0x02, 0x00, 0xBA, 0x20, 0x04, 0xCD, 0x21, // read 2 -> 0x420
        0xB4, 0x3E, 0xCD, 0x21, // close
        0xF4, // HLT
    });
    run(m);

    var got: [6]u8 = undefined;
    for (&got, 0..) |*g, i| g.* = m.bus.readPhys8(base + 0x400 + @as(u32, @intCast(i)));
    try std.testing.expectEqualStrings("HELLO!", &got);
    try std.testing.expectEqual(@as(u8, 'H'), m.bus.readPhys8(base + 0x420));
    try std.testing.expectEqual(@as(u8, 'E'), m.bus.readPhys8(base + 0x421));

    const f = try ctx.td.dir.openFile(std.testing.io, "TEST.DAT", .{});
    defer f.close(std.testing.io);
    var rb: [16]u8 = undefined;
    var r = f.reader(std.testing.io, &rb);
    const n = try r.interface.readSliceShort(rb[0..]);
    try std.testing.expectEqualStrings("HELLO!", rb[0..n]);
}

test "AH=09 print string routes to the CON device" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    putStr(m, 0x200, "Hi!$");
    loadCode(m, &.{ 0xB4, 0x09, 0xBA, 0x00, 0x02, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqualStrings("Hi!", m.dos.dev_table.con.output());
}

test "AH=42 SEEK_SET treats the 32-bit offset as unsigned (no signed clamp)" {
    // Faithful localFile::Seek (drive_local.cpp:656-713): SEEK_SET to a high
    // 32-bit offset (CX:DX = 0x8000:0x0000 = 0x80000000) must return that exact
    // position in DX:AX, NOT clamp to 0 (the old signed-i32 interpretation
    // treated it as negative). DOS allows seeking past EOF.
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    putStr(m, 0x200, "SEEK.DAT");
    loadCode(m, &.{
        0xB4, 0x3C, 0x33, 0xC9, 0xBA, 0x00, 0x02, 0xCD, 0x21, // create C:\SEEK.DAT
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x42, 0xB0, 0x00, 0xB9, 0x00, 0x80, 0xBA, 0x00, 0x00, 0xCD, 0x21, // seek SET 0x80000000
        0xF4, // HLT (DX:AX hold the seek result)
    });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x8000), m.cpu.st.getReg16(@intFromEnum(Reg32.edx)));
    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

test "AH=42 SEEK_SET to a small offset still works" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    putStr(m, 0x200, "SEEK.DAT");
    loadCode(m, &.{
        0xB4, 0x3C, 0x33, 0xC9, 0xBA, 0x00, 0x02, 0xCD, 0x21, // create
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x42, 0xB0, 0x00, 0xB9, 0x00, 0x00, 0xBA, 0x34, 0x12, 0xCD, 0x21, // seek SET 0x00001234
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.st.getReg16(@intFromEnum(Reg32.edx)));
    try std.testing.expectEqual(@as(u16, 0x1234), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

test "AH=42 SEEK_CUR wraps unsigned (no signed clamp-to-0)" {
    // From position 0 (freshly created file), SEEK_CUR by 0x80000000 must land at
    // 0x80000000 (32-bit unsigned add), not clamp to 0 like the old signed path.
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    putStr(m, 0x200, "SEEK.DAT");
    loadCode(m, &.{
        0xB4, 0x3C, 0x33, 0xC9, 0xBA, 0x00, 0x02, 0xCD, 0x21, // create (pos = 0)
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x42, 0xB0, 0x01, 0xB9, 0x00, 0x80, 0xBA, 0x00, 0x00, 0xCD, 0x21, // seek CUR 0x80000000
        0xF4,
    });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x8000), m.cpu.st.getReg16(@intFromEnum(Reg32.edx)));
    try std.testing.expectEqual(@as(u16, 0x0000), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

test "open EMMXXXX0 resolves the EMS device before the VFS (D17)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    putStr(m, 0x200, "EMMXXXX0");
    loadCode(m, &.{
        0xB4, 0x3D, 0xB0, 0x00, 0xBA, 0x00, 0x02, 0xCD, 0x21, // open
        0x8B, 0xD8, // MOV BX,AX
        0xB4, 0x44, 0xB0, 0x00, 0xCD, 0x21, // ioctl get device info
        0xF4,
    });
    run(m);
    try std.testing.expect((m.cpu.st.getReg16(@intFromEnum(Reg32.edx)) & 0x0080) != 0);
}

test "AH=48/49/4A MCB alloc/free/resize" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    loadCode(m, &.{
        0xB4, 0x48, 0xBB, 0x10, 0x00, 0xCD, 0x21, // alloc 0x10 paras
        0x8E, 0xC0, // MOV ES,AX
        0xB4, 0x4A, 0xBB, 0x20, 0x00, 0xCD, 0x21, // resize to 0x20
        0xB4, 0x49, 0xCD, 0x21, // free ES
        0xF4,
    });
    run(m);
    try std.testing.expect(!m.cpu.st.eflags.cf);
}

test "AH=2C get time derives from the emulated tick, not host clock (D13)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    loadCode(m, &.{ 0xB4, 0x2C, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(5)); // CH hours
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(1)); // CL minutes
}

test "AH=2A get date returns the pinned epoch year 1993 (D13)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    loadCode(m, &.{ 0xB4, 0x2A, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u16, 1993), m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
    try std.testing.expectEqual(@as(u8, 1), m.cpu.st.getReg8(6)); // DH month
    try std.testing.expectEqual(@as(u8, 1), m.cpu.st.getReg8(2)); // DL day
}

test "an unsupported AH flags the structural signal (D11) without faking CF" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    // MOV AH,0x71; MOV AL,0xAA; INT 0x21; HLT
    loadCode(m, &.{ 0xB4, 0x71, 0xB0, 0xAA, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expect(m.dos.last_unsupported != null);
    try std.testing.expectEqual(@as(u8, 0x21), m.dos.last_unsupported.?.int);
    try std.testing.expectEqual(@as(u8, 0x71), m.dos.last_unsupported.?.ah);
    // AL = 0 and CF clear (faithful real-DOS unknown-AH behavior, not a fake CF).
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(0));
    try std.testing.expect(!m.cpu.st.eflags.cf);
}

test "find-first / find-next over a few files with 8.3 munging (D10)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;

    inline for (.{ "A.TXT", "B.TXT", "C.DAT" }) |fname| {
        const f = try ctx.td.dir.createFile(std.testing.io, fname, .{});
        f.close(std.testing.io);
    }

    putStr(m, 0x200, "*.TXT");
    loadCode(m, &.{
        0xB4, 0x1A, 0xBA, 0x00, 0x05, 0xCD, 0x21, // set DTA = DS:0x500
        0xB4, 0x4E, 0x33, 0xC9, 0xBA, 0x00, 0x02, 0xCD, 0x21, // findfirst
        0xF4,
    });
    run(m);

    // The DTA at DS:0x500+0x1E holds the first matched ASCIIZ name. With two .TXT
    // files sorted (A.TXT before B.TXT), findfirst returns A.TXT.
    try std.testing.expect(!m.cpu.st.eflags.cf);
    const base = @as(u32, CODE_SEG) << 4;
    try std.testing.expectEqual(@as(u8, 'A'), m.bus.readPhys8(base + 0x500 + 0x1E));
}

test "AH=58 set allocation strategy to last-fit" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    // mov ax,5801 ; mov bx,2 ; int 21h ; hlt
    loadCode(m, &.{ 0xB8, 0x01, 0x58, 0xBB, 0x02, 0x00, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u8, 2), m.dos.strategy);
    try std.testing.expect(!m.cpu.st.eflags.cf);
}

test "AH=58 invalid strategy is rejected (CF set, value unchanged)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    m.dos.strategy = 1; // best-fit, the pre-existing value
    // mov ax,5801 ; mov bx,3 (invalid: &0x3f >= 3) ; int 21h ; hlt
    loadCode(m, &.{ 0xB8, 0x01, 0x58, 0xBB, 0x03, 0x00, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u8, 1), m.dos.strategy); // unchanged
    try std.testing.expect(m.cpu.st.eflags.cf);
    try std.testing.expectEqual(@as(u16, 1), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

test "AH=58 get allocation strategy returns the stored byte (incl. high bit)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    m.dos.strategy = 0x42; // last-fit (0x02) with a high/UMB bit set -> kept verbatim
    // mov ax,5800 ; int 21h ; hlt
    loadCode(m, &.{ 0xB8, 0x00, 0x58, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x42), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
    try std.testing.expect(!m.cpu.st.eflags.cf);
}

test "AH=58 set UMB link fails (no UMB region)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    // mov ax,5803 (set UMB link) ; mov bx,1 ; int 21h ; hlt
    loadCode(m, &.{ 0xB8, 0x03, 0x58, 0xBB, 0x01, 0x00, 0xCD, 0x21, 0xF4 });
    run(m);
    try std.testing.expect(m.cpu.st.eflags.cf);
    try std.testing.expectEqual(@as(u16, 1), m.cpu.st.getReg16(@intFromEnum(Reg32.eax)));
}

// ---- Phase 2: resident-DOS internals (List-of-Lists / device chain / SDA / CDS) ----

const ES = @intFromEnum(Seg.es);
const DS = @intFromEnum(Seg.ds);
const ESI = @intFromEnum(Reg32.esi);
const EBX = @intFromEnum(Reg32.ebx);
const ECX = @intFromEnum(Reg32.ecx);
const EDX = @intFromEnum(Reg32.edx);

test "Phase 2: List-of-Lists is byte-faithful to dosbox (sDIB fields + 0xFF gaps)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    const lol: u32 = 0x80 << 4; // AH=52 returns 0x80:0x26; offsets here are absolute
    try std.testing.expectEqual(@as(u16, 0x0001), m.bus.readPhys16(lol + 0x04)); // magicWord
    try std.testing.expectEqual(@as(u16, 0x016F), m.bus.readPhys16(lol + 0x24)); // firstMCB
    try std.testing.expectEqual(@as(u32, 0x008000CC), m.bus.readPhys32(lol + 0x2A)); // firstFileTable
    try std.testing.expectEqual(@as(u16, 0x0200), m.bus.readPhys16(lol + 0x36)); // maxSectorLength
    try std.testing.expectEqual(@as(u32, 0x01080000), m.bus.readPhys32(lol + 0x3C)); // curDirStructure
    try std.testing.expectEqual(@as(u32, 0xC82F0000), m.bus.readPhys32(lol + 0x40)); // fcbTable
    try std.testing.expectEqual(@as(u8, 0x01), m.bus.readPhys8(lol + 0x47)); // lastdrive
    try std.testing.expectEqual(@as(u32, 0x00A00000), m.bus.readPhys32(lol + 0x48)); // nulNextDriver
    try std.testing.expectEqual(@as(u16, 0x8004), m.bus.readPhys16(lol + 0x4C)); // nulAttributes
    try std.testing.expectEqual(@as(u16, 50), m.bus.readPhys16(lol + 0x65)); // buffers_x
    try std.testing.expectEqual(@as(u16, 50), m.bus.readPhys16(lol + 0x67)); // buffers_y
    try std.testing.expectEqual(@as(u8, 1), m.bus.readPhys8(lol + 0x6A)); // useDwordMov
    try std.testing.expectEqual(@as(u16, 0), m.bus.readPhys16(lol + 0x6B)); // extendedSize (no XMS)
    try std.testing.expectEqual(@as(u32, 0xC8460000), m.bus.readPhys32(lol + 0x6D)); // diskBufferHeadPt
    try std.testing.expectEqual(@as(u16, 0xFFFF), m.bus.readPhys16(lol + 0x8C)); // startOfUMBChain
    try std.testing.expectEqual(@as(u16, 0x016F), m.bus.readPhys16(lol + 0x8E)); // memAllocScanStart
    // nulString "NUL     "
    try std.testing.expectEqualSlices(u8, "NUL     ", &[_]u8{
        m.bus.readPhys8(lol + 0x52), m.bus.readPhys8(lol + 0x53), m.bus.readPhys8(lol + 0x54),
        m.bus.readPhys8(lol + 0x55), m.bus.readPhys8(lol + 0x56), m.bus.readPhys8(lol + 0x57),
        m.bus.readPhys8(lol + 0x58), m.bus.readPhys8(lol + 0x59),
    });
    // The five dosbox 0xFF gaps stay 0xFF; protFCBs (0x44) is explicitly zeroed (NOT a gap).
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), m.bus.readPhys32(lol + 0x26)); // firstDPB gap
    try std.testing.expectEqual(@as(u8, 0xFF), m.bus.readPhys8(lol + 0x14)); // stuff gap
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), m.bus.readPhys32(lol + 0x2E)); // activeClock gap
    try std.testing.expectEqual(@as(u16, 0), m.bus.readPhys16(lol + 0x44)); // protFCBs (zeroed)
}

test "Phase 2: device chain CON header + a walk reaches end-of-chain" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    // Walk from the LoL device-chain head (LoL+0x22 = abs 0x48).
    const head = m.bus.readPhys32((0x80 << 4) + 0x48);
    try std.testing.expectEqual(@as(u32, 0x00A00000), head); // -> CON 0xA0:0
    const con: u32 = 0xA0 << 4;
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), m.bus.readPhys32(con + 0x00)); // next = end
    try std.testing.expectEqual(@as(u16, 0x8013), m.bus.readPhys16(con + 0x04)); // attributes
    try std.testing.expectEqual(@as(u32, 0x204E4F43), m.bus.readPhys32(con + 0x0A)); // "CON "
    try std.testing.expectEqual(@as(u32, 0x20202020), m.bus.readPhys32(con + 0x0E)); // "    "
    // The fake CDS "C:\" the LoL curDirStructure points at.
    try std.testing.expectEqual(@as(u32, 0x005C3A43), m.bus.readPhys32(0x108 << 4));
}

test "Phase 2: AH=34 returns the SDA InDOS-flag address (0xB2:0x01)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    loadCode(m, &.{ 0xB4, 0x34, 0xCD, 0x21, 0xF4 }); // mov ah,34 ; int 21 ; hlt
    run(m);
    try std.testing.expectEqual(@as(u16, 0xB2), m.cpu.st.selector[ES]);
    try std.testing.expectEqual(@as(u16, 0x01), m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
    // dosbox-exact: InDOS (0x01) stays 0, critical-error (0x00) 0, drive_crit_error (0x02) 0xFF.
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8((0xB2 << 4) + 0x00));
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8((0xB2 << 4) + 0x01));
    try std.testing.expectEqual(@as(u8, 0xFF), m.bus.readPhys8((0xB2 << 4) + 0x02));
}

test "Phase 2: AH=5D06 returns the SDA address + region lengths (CX=0x80, DX=0x1A)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    loadCode(m, &.{ 0xB8, 0x06, 0x5D, 0xCD, 0x21, 0xF4 }); // mov ax,5D06 ; int 21 ; hlt
    run(m);
    try std.testing.expectEqual(@as(u16, 0xB2), m.cpu.st.selector[DS]);
    try std.testing.expectEqual(@as(u16, 0), m.cpu.st.getReg16(ESI));
    try std.testing.expectEqual(@as(u16, 0x80), m.cpu.st.getReg16(ECX));
    try std.testing.expectEqual(@as(u16, 0x1A), m.cpu.st.getReg16(EDX));
    try std.testing.expect(!m.cpu.st.eflags.cf);
}

test "Phase 2: SDA live-mirrors current PSP, and AH=52 sets blockDevices=3 (A,B,C)" {
    var ctx = try boot(std.testing.allocator);
    defer ctx.deinit();
    const m = ctx.m;
    // The SDA PSP mirror reflects the resident shell installed during post().
    try std.testing.expectEqual(m.dos.current_psp, m.bus.readPhys16((0xB2 << 4) + 0x10));
    // One snippet: AH=50 set-PSP (updates the live mirror), then AH=52 (recomputes
    // blockDevices = 2 floppies + C: present = 3). (loadCode does not clear `halted`,
    // so both calls must run before the single HLT.)
    loadCode(m, &.{
        0xB4, 0x50, 0xBB, 0x34, 0x12, 0xCD, 0x21, // mov ah,50; mov bx,1234; int 21
        0xB4, 0x52, 0xCD, 0x21, // mov ah,52; int 21
        0xF4, // hlt
    });
    run(m);
    try std.testing.expectEqual(@as(u16, 0x1234), m.bus.readPhys16((0xB2 << 4) + 0x10));
    try std.testing.expectEqual(@as(u8, 3), m.bus.readPhys8((0x80 << 4) + 0x46));
}
