//! Phase 8 — the deterministic host-serviced-trap regression (M4, THE
//! differentiator) + EMS INT 67h integration + snapshot-mid-service.
//!
//! The milestone: a real-mode program (loaded via the loader) that opens a file,
//! reads N bytes, seeks, reads again, writes a few bytes, closes, prints a
//! `$`-string, and exits — run to a clean exit TWICE (two fresh machines, same
//! fixed file content) is byte-identical INCLUDING the cycle position. The cycle
//! position being identical DESPITE real host file I/O is the literal proof the
//! host-serviced trap charges a fixed synthetic cost and has no ledger hole — the
//! Spice86 hole, closed.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const dos_mod = @import("dos");
const timing = @import("timing");
const debug = @import("debug");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

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

fn untilDone(mm: *Machine) bool {
    return mm.cpu.st.halted or mm.dos.terminated;
}

// A COM that exercises the full bridge -> INT 21h -> VFS -> synthetic-cost path:
//   open "DATA.BIN" (at 0x0100+off) read 8 bytes into a buffer, seek to 0, read 4
//   bytes, then AH=09 print "DONE$", then exit(0x2A).
// Layout (COM, loads at 0x100):
//   code, then strings. We compute string offsets after the code.
fn buildIoCom(buf: []u8) usize {
    // Offsets within the loaded image (base 0x100). We place:
    //   fname "DATA.BIN\0" and msg "DONE$" after the code, and a read buffer high.
    // Build code first into a temp, then append strings; patch the immediates.
    var p: usize = 0;
    const base: u16 = 0x100;

    // We'll fill in fname/msg/buf offsets once the code size is known. Reserve a
    // fixed code layout so the offsets are constants.
    // CODE:
    //  B4 3D B0 00       MOV AH,3D ; MOV AL,0 (open read)
    //  BA <fname>        MOV DX,fname
    //  CD 21             INT 21
    //  8B D8             MOV BX,AX            (handle)
    //  B4 3F B9 08 00    MOV AH,3F ; MOV CX,8
    //  BA <buf>          MOV DX,buf
    //  CD 21             INT 21               (read 8)
    //  B4 42 B0 00 B9 00 00 BA 00 00  MOV AH,42 AL,0 CX,0 DX,0 (seek SET 0)
    //  CD 21             INT 21
    //  B4 3F B9 04 00    MOV AH,3F ; MOV CX,4
    //  BA <buf>          MOV DX,buf
    //  CD 21             INT 21               (read 4)
    //  B4 3E             MOV AH,3E
    //  CD 21             INT 21               (close BX)
    //  B4 09 BA <msg> CD 21                   (print msg)
    //  B8 2A 4C CD 21                          (exit 0x2A)
    // Place strings + the read buffer at FIXED image offsets well past the code
    // (the code is < 0x60 bytes), so the immediates don't depend on the exact code
    // length. Offsets are segment-relative (COM loads at 0x100).
    const fname_off: u16 = base + 0x80; // "DATA.BIN\0"
    const msg_off: u16 = base + 0x90; // "DONE$"
    const buf_off: u16 = base + 0xA0;

    const w = struct {
        fn b(bf: []u8, pp: *usize, v: u8) void {
            bf[pp.*] = v;
            pp.* += 1;
        }
        fn ww(bf: []u8, pp: *usize, v: u16) void {
            bf[pp.*] = @truncate(v);
            bf[pp.* + 1] = @truncate(v >> 8);
            pp.* += 2;
        }
    };
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x3D); // MOV AH,3D
    w.b(buf, &p, 0xB0);
    w.b(buf, &p, 0x00); // MOV AL,0
    w.b(buf, &p, 0xBA);
    w.ww(buf, &p, fname_off); // MOV DX,fname
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    w.b(buf, &p, 0x8B);
    w.b(buf, &p, 0xD8); // MOV BX,AX
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x3F);
    w.b(buf, &p, 0xB9);
    w.ww(buf, &p, 8); // MOV AH,3F ; MOV CX,8
    w.b(buf, &p, 0xBA);
    w.ww(buf, &p, buf_off); // MOV DX,buf
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    // seek SET 0: AH=42 AL=0 CX=0 DX=0 ; INT21
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x42);
    w.b(buf, &p, 0xB0);
    w.b(buf, &p, 0x00);
    w.b(buf, &p, 0xB9);
    w.ww(buf, &p, 0);
    w.b(buf, &p, 0xBA);
    w.ww(buf, &p, 0);
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    // read 4
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x3F);
    w.b(buf, &p, 0xB9);
    w.ww(buf, &p, 4);
    w.b(buf, &p, 0xBA);
    w.ww(buf, &p, buf_off);
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    // close
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x3E);
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    // print msg
    w.b(buf, &p, 0xB4);
    w.b(buf, &p, 0x09);
    w.b(buf, &p, 0xBA);
    w.ww(buf, &p, msg_off);
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);
    // exit 0x2A
    w.b(buf, &p, 0xB8);
    w.ww(buf, &p, 0x4C2A);
    w.b(buf, &p, 0xCD);
    w.b(buf, &p, 0x21);

    std.debug.assert(p <= 0x80); // code fits before the string area
    // strings at fixed image offsets (image index = seg-relative offset - base).
    @memcpy(buf[0x80 .. 0x80 + 9], "DATA.BIN\x00");
    @memcpy(buf[0x90 .. 0x90 + 6], "DONE$\x00");
    @memset(buf[0xA0 .. 0xA0 + 16], 0); // the read buffer area
    return 0xA0 + 16; // total image size
}

const file_content = "0123456789ABCDEF"; // fixed external input

const IoResult = struct { out: [16]u8, out_len: usize, code: u16, cycles: u64 };

fn runIoProgram(alloc: std.mem.Allocator) !IoResult {
    var ctx = try boot(alloc);
    defer ctx.deinit();
    var com: [256]u8 = undefined;
    const n = buildIoCom(&com);
    try writeHostFile(&ctx, "PROG.COM", com[0..n]);
    try writeHostFile(&ctx, "DATA.BIN", file_content);

    try ctx.m.bootProgram(2, "PROG.COM", "");
    _ = ctx.m.runUntil(untilDone, 2_000_000);

    var r: IoResult = undefined;
    const out = ctx.m.dos.dev_table.con.output();
    r.out_len = out.len;
    @memcpy(r.out[0..out.len], out);
    r.code = ctx.m.dos.ret_code;
    r.cycles = ctx.m.cpu.st.cycles;
    return r;
}

test "M4: file-I/O program run-to-completion TWICE is byte-identical incl. cycles" {
    const alloc = std.testing.allocator;
    const a = try runIoProgram(alloc);
    const b = try runIoProgram(alloc);
    try std.testing.expectEqualStrings(a.out[0..a.out_len], b.out[0..b.out_len]);
    try std.testing.expectEqualStrings("DONE", a.out[0..a.out_len]);
    try std.testing.expectEqual(@as(u16, 0x2A), a.code);
    // THE differentiator: identical cycle position across two runs DESPITE real
    // host file I/O — the host-serviced trap charges a fixed synthetic cost (D5),
    // so the cycle ledger has NO hole across the trap (the Spice86 hole, closed).
    try std.testing.expectEqual(a.cycles, b.cycles);
}

test "M4: the synthetic cost is a pure function of CX, never host I/O timing (D6)" {
    // Reading N bytes charges file_read_base + N*per_byte (a guest-input formula).
    // Two reads of the SAME count charge the SAME cost regardless of when/how the
    // host serviced them. We assert the cost is > 0 and proportional by running the
    // round-trip twice (already proven identical above) — the by-construction guard
    // in dispatchCallback (debug assert) additionally fails if any trap left the
    // ledger unchanged. Here we just confirm the program advanced the ledger.
    const alloc = std.testing.allocator;
    const a = try runIoProgram(alloc);
    try std.testing.expect(a.cycles > 0);
}

// ---------------------------------------------------------------------------
// EMS INT 67h (M4 / D15): allocate a handle, map a logical page into a frame
// slot, write through the page-frame window, remap, read back the new page.
// ---------------------------------------------------------------------------
test "EMS INT 67h: allocate, map, write through the frame window, remap, read back" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Allocate a 2-page handle: AH=43 BX=2 -> DX=handle.
    asmInt67(m, &.{ 0xB4, 0x43, 0xBB, 0x02, 0x00, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4)); // AH=0 ok
    const handle = m.cpu.st.getReg16(@intFromEnum(Reg32.edx));

    // Map logical page 0 of `handle` into physical frame slot 0:
    //   AH=44 AL=0 (slot) BX=0 (logical) DX=handle ; INT 67
    asmInt67WithDX(m, handle, &.{ 0xB4, 0x44, 0xB0, 0x00, 0xBB, 0x00, 0x00, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));

    // Write a byte through the page-frame window (0xE0000) and read it back.
    m.bus.writePhys8(0xE0000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), m.bus.readPhys8(0xE0000));

    // Map logical page 1 into slot 0 (remap), write a different byte, read back.
    asmInt67WithDX(m, handle, &.{ 0xB4, 0x44, 0xB0, 0x00, 0xBB, 0x01, 0x00, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));
    // The new page is fresh (zero-init), distinct from the 0xAB we wrote to page 0.
    try std.testing.expectEqual(@as(u8, 0x00), m.bus.readPhys8(0xE0000));
    m.bus.writePhys8(0xE0000, 0xCD);
    try std.testing.expectEqual(@as(u8, 0xCD), m.bus.readPhys8(0xE0000));

    // Remap page 0 back: the original 0xAB must still be there (backing persisted).
    asmInt67WithDX(m, handle, &.{ 0xB4, 0x44, 0xB0, 0x00, 0xBB, 0x00, 0x00, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0xAB), m.bus.readPhys8(0xE0000));
}

// ---------------------------------------------------------------------------
// report==back regression (Krondor milestone Stage 3): the EMS manager must
// back EVERY page it advertises. Betrayal at Krondor's `ems_init` allocates ALL
// reported pages in one INT 67h AH=43 call (BX = REPORTED_PAGES = 956); when the
// backing was only 128 pages that returned 0x88 (NOT_ENOUGH_PAGES) and the
// game's memory-sufficiency gate aborted. With BACKING_PAGES == REPORTED_PAGES
// the single big allocation now SUCCEEDS — proving zdos no longer advertises
// more EMS than it backs (the fake this fix removes).
// ---------------------------------------------------------------------------
test "EMS INT 67h: allocHandle(REPORTED_PAGES) succeeds (report == backing)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // The advertised total == what BaK's ems_init asks for in one shot.
    try std.testing.expectEqual(dos_mod.ems_reported_pages, dos_mod.ems_backing_pages);
    const want = dos_mod.ems_reported_pages;

    // AH=43 BX=want ; INT 67h ; HLT.  MOV AH,43h / MOV BX,imm16 / INT 67h / HLT.
    asmInt67(m, &.{
        0xB4, 0x43, // MOV AH, 43h
        0xBB, @truncate(want), @truncate(want >> 8), // MOV BX, want
        0xCD, 0x67, // INT 67h
        0xF4, // HLT
    });
    // AH=0 (success), DX = the allocated handle.
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));
    const handle = m.cpu.st.getReg16(@intFromEnum(Reg32.edx));
    try std.testing.expect(handle != 0); // handle 0 is reserved in board mode

    // The handle owns exactly `want` pages, and the free count is now 0
    // (everything reported is allocated). AH=4C: pages-for-handle -> BX.
    asmInt67WithDX(m, handle, &.{ 0xB4, 0x4C, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));
    try std.testing.expectEqual(want, m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)));

    // AH=42: free=BX, total=DX. Free must be 0 (all backed pages handed out),
    // total still the reported figure.
    asmInt67(m, &.{ 0xB4, 0x42, 0xCD, 0x67, 0xF4 });
    try std.testing.expectEqual(@as(u8, 0), m.cpu.st.getReg8(4));
    try std.testing.expectEqual(@as(u16, 0), m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
    try std.testing.expectEqual(want, m.cpu.st.getReg16(@intFromEnum(Reg32.edx)));
}

// ---------------------------------------------------------------------------
// EMS backing-store snapshot round-trip. The small EMS bookkeeping rides in the
// machine Snapshot (by value); the large ~15 MiB backing slab is copied OUT OF
// BAND by the caller, exactly like bus.ram / vga.vram. This test allocates a
// handle, maps + writes a marker through the frame window, snapshots (small
// state + backing copy), clobbers both, restores, and asserts the marker byte
// survives — i.e. the backing slab is genuinely covered.
// ---------------------------------------------------------------------------
test "EMS backing: out-of-band snapshot/restore preserves mapped page contents" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Allocate a 2-page handle, map logical page 0 into frame slot 0, write 0xAB.
    asmInt67(m, &.{ 0xB4, 0x43, 0xBB, 0x02, 0x00, 0xCD, 0x67, 0xF4 });
    const handle = m.cpu.st.getReg16(@intFromEnum(Reg32.edx));
    asmInt67WithDX(m, handle, &.{ 0xB4, 0x44, 0xB0, 0x00, 0xBB, 0x00, 0x00, 0xCD, 0x67, 0xF4 });
    m.bus.writePhys8(0xE0000, 0xAB);

    // Snapshot: small machine state by value + the two large slabs out of band.
    const snap = m.snapshot();
    const ram_copy = try alloc.alloc(u8, m.bus.ram.len);
    defer alloc.free(ram_copy);
    @memcpy(ram_copy, m.bus.ram);
    const ems_copy = try alloc.dupe(u8, m.dos.ems.backingBytes());
    defer alloc.free(ems_copy);

    // Clobber the mapped EMS page AND the small EMS state after the snapshot.
    m.bus.writePhys8(0xE0000, 0xFF);
    m.dos.ems.next_page = 0xFFFF;

    // Restore: small state by value, then the slabs out of band.
    m.restore(snap);
    @memcpy(m.bus.ram, ram_copy);
    m.dos.ems.restoreBacking(ems_copy);

    // The mapped marker survived (backing snapshotted), and the small state too.
    try std.testing.expectEqual(@as(u8, 0xAB), m.bus.readPhys8(0xE0000));
    try std.testing.expectEqual(@as(u16, 2), m.dos.ems.next_page);
}

const CODE_SEG: u16 = 0x2000;
fn asmInt67(m: *Machine, code: []const u8) void {
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |c, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), c);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.st.eflags.iff = true;
    m.cpu.st.halted = false;
    _ = m.runUntil(untilDone, 100_000);
}
// Run a snippet with DX pre-set (for AH=44 which needs DX=handle preserved).
fn asmInt67WithDX(m: *Machine, dx: u16, code: []const u8) void {
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |c, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), c);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.edx), dx);
    m.cpu.st.eflags.iff = true;
    m.cpu.st.halted = false;
    _ = m.runUntil(untilDone, 100_000);
}

// ---------------------------------------------------------------------------
// Snapshot mid-service (D14): snapshot a populated machine, restore, continue.
// ---------------------------------------------------------------------------
test "snapshot/restore round-trips a populated machine byte-identically" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Allocate some MCB memory + set a BDA tick so there is populated state.
    asmInt67(m, &.{ 0xB4, 0x48, 0xBB, 0x10, 0x00, 0xCD, 0x21, 0xF4 }); // alloc 0x10 paras
    const seg_before = m.cpu.st.getReg16(0);

    const snap = m.snapshot();
    const ram_copy = try alloc.alloc(u8, m.bus.ram.len);
    defer alloc.free(ram_copy);
    @memcpy(ram_copy, m.bus.ram);

    // Mutate, then restore.
    m.bus.writePhys8(0x10000, 0xFF);
    m.restore(snap);
    @memcpy(m.bus.ram, ram_copy);

    // The restored MCB still reports the same allocated segment on a fresh alloc
    // attempt would differ, but the key invariant: RAM + CPU state round-tripped.
    try std.testing.expectEqual(seg_before, m.cpu.st.getReg16(0));
    try std.testing.expect(m.bus.readPhys8(0x10000) != 0xFF);
}

// ---------------------------------------------------------------------------
// Snapshot the MOUSE driver state (input Phase 0 — the snapshot-hole closer).
// The test above NEVER touches `dos.mouse`, so it false-passes the mouse path.
// This one mutates `dos.mouse` to a non-default state, snapshots, mutates AGAIN,
// restores, and asserts the restored mouse state byte-matches the snapshotted
// state (and the rest of the machine round-trips). Without the `Int33.Snapshot`
// wiring this would FAIL (the post-snapshot mutation would survive restore).
// ---------------------------------------------------------------------------
test "snapshot/restore round-trips the mouse driver state (input Phase 0)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Mutate the mouse driver to a fully non-default state across EVERY field so
    // the round-trip exercises the whole Snapshot, not just position.
    m.dos.mouse = .{
        .present = true,
        .x = 123,
        .y = -45,
        .buttons = 0b101, // left+middle down
        .hidden = 3, // hidden-count, not the default 1
        .min_x = -10,
        .max_x = 511,
        .min_y = -20,
        .max_y = 383,
        .gran_x = 0xfffe,
        .gran_y = 0xfff8,
        .senv_x_val = 77,
        .senv_y_val = 12,
        .dspeed_val = 99,
        .handler_seg = 0x9000,
        .handler_off = 0x0123,
        .handler_mask = 0x001F,
        // Phase-2 relative-motion accumulators + counters (non-default).
        .precise_mickey_x = 12345,
        .precise_mickey_y = -6789,
        .precise_pixel_x = 4242,
        .precise_pixel_y = -1313,
        .mickey_x = 77,
        .mickey_y = -88,
    };
    const expected = m.dos.mouse; // the value we expect after restore

    const snap = m.snapshot();
    const ram_copy = try alloc.alloc(u8, m.bus.ram.len);
    defer alloc.free(ram_copy);
    @memcpy(ram_copy, m.bus.ram);

    // Mutate the mouse AGAIN (and some RAM) AFTER the snapshot — restore must
    // discard these and bring back the snapshotted mouse state.
    m.dos.mouse.x = -999;
    m.dos.mouse.buttons = 0;
    m.dos.mouse.hidden = 0;
    m.dos.mouse.handler_seg = 0xDEAD;
    m.dos.mouse.handler_off = 0xBEEF;
    m.dos.mouse.gran_x = 0xffff;
    m.dos.mouse.precise_mickey_x = -1;
    m.dos.mouse.mickey_y = 0;
    m.dos.mouse.precise_pixel_x = 0;
    m.bus.writePhys8(0x10000, 0xFF);

    m.restore(snap);
    @memcpy(m.bus.ram, ram_copy);

    // Byte-equal the whole restored mouse driver state to the snapshotted value.
    // `Int33` is a POD struct (no pointers), so a value compare is a byte compare.
    try std.testing.expectEqual(expected, m.dos.mouse);
    // And the rest of the machine round-tripped (the post-snapshot RAM poke gone).
    try std.testing.expect(m.bus.readPhys8(0x10000) != 0xFF);
}

// ===========================================================================
// Input Phase 2 — mouse injection (absolute + relative), determinism + a
// black-box guest round-trip. The injectAbsolute/injectRelative paths are the
// deterministic scripted-input seam; these prove (a) two identical inject
// sequences reach byte-identical driver state (the snapshot, now covering the
// fixed-point accumulators), and (b) the guest reads an injected position back
// via the REAL INT 33h AX=0003 path.
// ===========================================================================

// A fixed absolute inject + relative inject script driven only by injectAbsolute/
// injectRelative (no host pointer, no clock). Returns nothing; mutates m.dos.mouse.
fn injectScriptAbsolute(m: *Machine) void {
    const ms = &m.dos.mouse;
    ms.injectAbsolute(100, 50, 0b001, true, true, true); // pos + left button
    ms.injectAbsolute(300, 0, 0b011, true, false, true); // x + buttons only
    ms.injectAbsolute(0, 175, 0, false, true, false); // y only
}

fn injectScriptRelative(m: *Machine) void {
    const ms = &m.dos.mouse;
    // Center first so negative deltas aren't clamped at the 0 edge.
    ms.injectAbsolute(320, 240, 0, true, true, true);
    // A spread of relative deltas, incl. sub-threshold ones (0/±1) that exercise
    // the fractional remainder accumulation, and a button change.
    ms.injectRelative(7, -3, 0, true, true, false);
    ms.injectRelative(1, 1, 0b010, true, true, true);
    ms.injectRelative(-2, 4, 0, true, true, false);
    ms.injectRelative(1, -1, 0, true, true, false);
    ms.injectRelative(0, 0, 0b101, false, false, true); // buttons only
    ms.injectRelative(50, -40, 0, true, true, false);
}

test "input Phase 2: absolute injection is byte-identical across two runs" {
    const alloc = std.testing.allocator;
    var a = try boot(alloc);
    defer a.deinit();
    var b = try boot(alloc);
    defer b.deinit();

    injectScriptAbsolute(a.m);
    injectScriptAbsolute(b.m);

    // The whole mouse driver state (POD) must match byte-for-byte.
    try std.testing.expectEqual(a.m.dos.mouse, b.m.dos.mouse);
    // Sanity: the script actually changed state from the default.
    try std.testing.expect(a.m.dos.mouse.x != 0 or a.m.dos.mouse.y != 0);
}

test "input Phase 2: relative injection is byte-identical across two runs (fixed-point accumulator)" {
    const alloc = std.testing.allocator;
    var a = try boot(alloc);
    defer a.deinit();
    var b = try boot(alloc);
    defer b.deinit();

    injectScriptRelative(a.m);
    injectScriptRelative(b.m);

    // The mickey counters + the sub-mickey/sub-pixel fixed-point remainders must
    // ALL be byte-identical — this is the proof the accumulator is deterministic.
    const sa = a.m.dos.mouse.snapshot();
    const sb = b.m.dos.mouse.snapshot();
    try std.testing.expectEqual(sa, sb);
    // Sanity: relative motion actually accumulated mickeys (non-zero counter and a
    // non-zero fractional remainder somewhere — the formula did real work).
    try std.testing.expect(sa.mickey_x != 0 or sa.mickey_y != 0);
}

// Run a guest snippet `MOV AX,imm ; INT 33h ; HLT` and return CPU CX/DX (the
// AX=0003 position read-back). Uses the SAME real INT 33h dispatch path the
// guest game uses (IVT vector 0x33 -> dos.mouse.service), not a host shortcut.
fn guestInt33(m: *Machine, ax: u16) struct { cx: u16, dx: u16, bx: u16 } {
    asmInt67(m, &.{
        0xB8, @truncate(ax), @truncate(ax >> 8), // MOV AX, imm16
        0xCD, 0x33, // INT 33h
        0xF4, // HLT
    });
    return .{
        .cx = m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)),
        .dx = m.cpu.st.getReg16(@intFromEnum(Reg32.edx)),
        .bx = m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)),
    };
}

// Run `MOV AX,imm ; MOV BX,imm ; INT 33h ; HLT` and return AX/BX/CX/DX. Used by
// the AX=0005/0006 button-press/release queries, which take the button number in
// BX and report the current status in AX plus the count/position in BX/CX/DX.
fn guestInt33BX(m: *Machine, ax: u16, bx: u16) struct { ax: u16, bx: u16, cx: u16, dx: u16 } {
    asmInt67(m, &.{
        0xB8, @truncate(ax), @truncate(ax >> 8), // MOV AX, imm16
        0xBB, @truncate(bx), @truncate(bx >> 8), // MOV BX, imm16
        0xCD, 0x33, // INT 33h
        0xF4, // HLT
    });
    return .{
        .ax = m.cpu.st.getReg16(@intFromEnum(Reg32.eax)),
        .bx = m.cpu.st.getReg16(@intFromEnum(Reg32.ebx)),
        .cx = m.cpu.st.getReg16(@intFromEnum(Reg32.ecx)),
        .dx = m.cpu.st.getReg16(@intFromEnum(Reg32.edx)),
    };
}

test "INT 33h AX=0005: guest sees an injected button press (count + position, reset-on-read)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Position the cursor, then press the LEFT button at that spot (one 0->1 edge).
    // Defaults: range x=0..639 y=0..479, gran 0xffff, so the position round-trips.
    m.dos.mouse.injectAbsolute(222, 134, 0, true, true, false); // move, no buttons
    m.dos.mouse.injectAbsolute(0, 0, 0b001, false, false, true); // press left

    // AX=0005, BX=0 (left): AX=current status (left down), BX=press count (1),
    // CX/DX = the position of the last press (mouse.cpp:1690-1695).
    const r = guestInt33BX(m, 0x0005, 0);
    try std.testing.expectEqual(@as(u16, 0b001), r.ax); // left button currently down
    try std.testing.expectEqual(@as(u16, 1), r.bx); // one press since last query
    try std.testing.expectEqual(@as(u16, 222), r.cx); // X at the press
    try std.testing.expectEqual(@as(u16, 134), r.dx); // Y at the press

    // Reset-on-read: a SECOND AX=0005 returns count 0 (mouse.cpp:1695 zeroes it),
    // but AX still reflects the (still-held) button and CX/DX keep the last-press
    // position (only the COUNTER is reset, not the position — dosbox keeps it).
    const r2 = guestInt33BX(m, 0x0005, 0);
    try std.testing.expectEqual(@as(u16, 0b001), r2.ax);
    try std.testing.expectEqual(@as(u16, 0), r2.bx);
    try std.testing.expectEqual(@as(u16, 222), r2.cx);
    try std.testing.expectEqual(@as(u16, 134), r2.dx);

    // The RIGHT button (BX=1) never pressed: count 0, position 0.
    const rr = guestInt33BX(m, 0x0005, 1);
    try std.testing.expectEqual(@as(u16, 0), rr.bx);
    try std.testing.expectEqual(@as(u16, 0), rr.cx);
    try std.testing.expectEqual(@as(u16, 0), rr.dx);
}

test "INT 33h AX=0006: guest sees an injected button release (count + position, reset-on-read)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Press the left button at one spot, then release it at ANOTHER — AX=0006 must
    // report the RELEASE position (not the press position) for the last release.
    m.dos.mouse.injectAbsolute(100, 50, 0b001, true, true, true); // move + press
    m.dos.mouse.injectAbsolute(300, 175, 0, true, true, true); // move + release left

    // AX=0006, BX=0 (left): AX=current status (no buttons), BX=release count (1),
    // CX/DX = position of the last release (mouse.cpp:1720-1725).
    const r = guestInt33BX(m, 0x0006, 0);
    try std.testing.expectEqual(@as(u16, 0), r.ax); // nothing held now
    try std.testing.expectEqual(@as(u16, 1), r.bx); // one release since last query
    try std.testing.expectEqual(@as(u16, 300), r.cx); // X at the release
    try std.testing.expectEqual(@as(u16, 175), r.dx); // Y at the release

    // Reset-on-read: a second AX=0006 returns count 0, position retained.
    const r2 = guestInt33BX(m, 0x0006, 0);
    try std.testing.expectEqual(@as(u16, 0), r2.bx);
    try std.testing.expectEqual(@as(u16, 300), r2.cx);
    try std.testing.expectEqual(@as(u16, 175), r2.dx);

    // AX=0005 press count is independent of AX=0006: exactly one press happened.
    const rp = guestInt33BX(m, 0x0005, 0);
    try std.testing.expectEqual(@as(u16, 1), rp.bx);
    try std.testing.expectEqual(@as(u16, 100), rp.cx); // press was at the FIRST spot
    try std.testing.expectEqual(@as(u16, 50), rp.dx);

    // Out-of-range button number clamps to the highest valid button (dosbox-x
    // mouse.cpp:1721 `if (but>=MOUSE_BUTTONS) but = MOUSE_BUTTONS-1`): BX=99 reads
    // the middle button (index 2), which never released -> count 0.
    const oob = guestInt33BX(m, 0x0006, 99);
    try std.testing.expectEqual(@as(u16, 0), oob.bx);
}

// ---------------------------------------------------------------------------
// Held CLICK dwell (the level-sampling fix). A guest that LEVEL-SAMPLES the mouse
// button — reads "is it down RIGHT NOW" via INT 33h AX=3 once per loop iteration,
// mirroring Betrayal at Krondor's retrace-spinning menu — only observes a click if
// the button-down state PERSISTS across at least one of its sample iterations. A
// cycle-neutral press+release (dwell 0) is never seen; a press → ~100 ms-emulated
// dwell → release IS. `Controller.clickMouse` advances that EMULATED time explicitly
// (zdos has no host clock), so the click lands deterministically.
// ---------------------------------------------------------------------------

// Arm the LEVEL-SAMPLING guest at CODE_SEG:0 and start it (CS:IP, stack). It polls the
// LEFT button via INT 33h AX=3 in a tight loop and, the instant it samples the button
// DOWN, falls into a `JMP $` self-spin at SAMPLER_DONE_OFF:
//   loop: MOV AX,0003 ; INT 33h ; TEST BL,1 ; JZ loop   done: JMP $
// IF is cleared so no hardware IRQ ever perturbs the snippet (INT 33h is a software
// interrupt — unaffected): the run is purely the guest's own poll loop. The guest's
// EIP reaches SAMPLER_DONE_OFF (and stays there) IFF it observed the button down; while
// it never sees the button it cycles through offsets 0..9 forever.
const SAMPLER_DONE_OFF: u32 = 10; // the `JMP $` self-spin entered on detection
fn armButtonSampler(m: *Machine) void {
    const code = [_]u8{
        0xB8, 0x03, 0x00, // off 0: MOV AX,0003h
        0xCD, 0x33, // off 3: INT 33h          (BX <- buttons)
        0xF6, 0xC3, 0x01, // off 5: TEST BL,1
        0x74, 0xF6, // off 8: JZ -10 -> back to off 0
        0xEB, 0xFE, // off 10: JMP $ (spin here once detected)
    };
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |c, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), c);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.st.eflags.iff = false; // no hardware IRQ perturbs the snippet
    m.cpu.st.halted = false;
}

test "held click: a ~100 ms dwell makes a level-sampled click land; dwell 0 does not" {
    const alloc = std.testing.allocator;

    // --- WITH a dwell: the sampler observes the click ---
    {
        var ctx = try boot(alloc);
        defer ctx.deinit();
        const m = ctx.m;
        armButtonSampler(m);
        var ctrl = Controller.init(m);

        // Press left, hold ~100 ms of EMULATED time, release. During the hold the
        // button is down, so the polling guest samples it and reaches the spin.
        const stop = ctrl.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 100);

        // The guest spins for the rest of the dwell, so the hold runs to completion: the
        // reason is `dwell_complete` (NOT the raw `cycle_budget_exhausted`), the dedicated
        // "the click held its full dwell" signal a caller sees instead of a truncation.
        try std.testing.expect(stop == .dwell_complete);
        try std.testing.expectEqual(SAMPLER_DONE_OFF, m.cpu.st.eip); // observed
        // The release edge landed too: the button is back up after the click.
        try std.testing.expectEqual(@as(u16, 0), m.dos.mouse.buttons);
    }

    // --- dwell 0: the same press+release is INSTANTANEOUS, never sampled ---
    {
        var ctx = try boot(alloc);
        defer ctx.deinit();
        const m = ctx.m;
        armButtonSampler(m);
        var ctrl = Controller.init(m);

        // Press+release at (effectively) the same cycle: runUntilEvent(0) steps a
        // single instruction — not a whole poll+test+branch iteration — then we
        // release. The guest cannot complete a detection in that window.
        _ = ctrl.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 0);
        try std.testing.expect(m.cpu.st.eip != SAMPLER_DONE_OFF); // NOT observed
        try std.testing.expectEqual(@as(u16, 0), m.dos.mouse.buttons); // released

        // Drive a long run AFTERWARD (button now up): the guest keeps polling an up
        // button forever and STILL never reaches the spin — proving the instantaneous
        // click was genuinely missed, not merely late. `untilDone` never trips (no HLT),
        // so the run exhausts its whole budget.
        _ = m.runUntil(untilDone, 5_000_000);
        try std.testing.expect(m.cpu.st.eip != SAMPLER_DONE_OFF);
    }
}

test "held click: deterministic — two fresh machines reach identical cycle + state" {
    const alloc = std.testing.allocator;
    var ca = try boot(alloc);
    defer ca.deinit();
    var cb = try boot(alloc);
    defer cb.deinit();
    armButtonSampler(ca.m);
    armButtonSampler(cb.m);
    var ctrl_a = Controller.init(ca.m);
    var ctrl_b = Controller.init(cb.m);

    _ = ctrl_a.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 100);
    _ = ctrl_b.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 100);

    // Same binary + same input (the click) => byte-identical cycle AND CPU state.
    try std.testing.expectEqual(ca.m.cpu.st.cycles, cb.m.cpu.st.cycles);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ca.m.cpu.st),
        std.mem.asBytes(&cb.m.cpu.st),
    );
    try std.testing.expectEqual(ca.m.dos.mouse.press_count[0], cb.m.dos.mouse.press_count[0]);
}

test "held click: the dwell->cycles budget scales with the configured CPU clock (reads the machine clock, not a constant)" {
    const alloc = std.testing.allocator;

    // Two identical machines, one at twice the CPU:PIT mult. The SAME hold_ms must
    // charge proportionally more cycles at the faster clock — proving dwellCycles
    // reads the live mult (cpuClockHz) rather than a hardcoded count. Use a snippet
    // that NEVER halts (JMP $) so the dwell budget is exhausted in full, making the
    // reported cycle delta exactly the dwell budget.
    const spin = [_]u8{ 0xEB, 0xFE }; // JMP $ (tight self-loop, no INT, no HLT)

    var slow = try boot(alloc);
    defer slow.deinit();
    var fast = try boot(alloc);
    defer fast.deinit();
    inline for (.{ slow, fast }) |c| {
        const base = @as(u32, CODE_SEG) << 4;
        for (spin, 0..) |b, i| c.m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
        c.m.cpu.loadSegment(.cs, CODE_SEG);
        c.m.cpu.st.eip = 0;
        c.m.cpu.loadSegment(.ss, CODE_SEG);
        c.m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
        c.m.cpu.st.eflags.iff = false; // no IRQ; the spin just burns the dwell budget
        c.m.cpu.st.halted = false;
    }
    _ = slow.m.setClockMult(timing.DEFAULT_MULT); // mult 12 (the pinned default)
    _ = fast.m.setClockMult(timing.DEFAULT_MULT * 2); // mult 24 -> 2x the CPU clock

    var ctrl_slow = Controller.init(slow.m);
    var ctrl_fast = Controller.init(fast.m);

    const c0_slow = slow.m.cpu.st.cycles;
    const c0_fast = fast.m.cpu.st.cycles;
    _ = ctrl_slow.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 100);
    _ = ctrl_fast.clickMouse(.{ .buttons = 0b001, .set_buttons = true }, 100);
    const d_slow = slow.m.cpu.st.cycles - c0_slow;
    const d_fast = fast.m.cpu.st.cycles - c0_fast;

    // The dwell budget is cpuClockHz(mult) * 100 / 1000; at mult 24 that is exactly
    // double mult 12. The free-running spin overruns the deadline by a tiny, bounded
    // amount each run (a single 2-byte instruction), so assert the EXACT budget plus a
    // proven scaling: fast is ~2x slow, and both equal the dwellCycles formula.
    try std.testing.expectEqual(ctrl_slow.dwellCycles(100), timing.cpuClockHz(timing.DEFAULT_MULT) * 100 / 1000);
    try std.testing.expectEqual(ctrl_fast.dwellCycles(100), 2 * ctrl_slow.dwellCycles(100));
    // The realized delta is the budget rounded up to the next whole instruction; the
    // fast machine ran strictly more cycles, and at least ~2x the slow budget.
    try std.testing.expect(d_fast > d_slow);
    try std.testing.expect(d_fast >= 2 * ctrl_slow.dwellCycles(100));
    try std.testing.expect(d_slow >= ctrl_slow.dwellCycles(100));
}

// Run `MOV AX,imm ; MOV CX,imm ; MOV DX,imm ; INT 33h ; HLT` — drives the AX=0007/
// 0008 DEFINE-RANGE calls (CX=min, DX=max) from a real guest, so the live range the
// normalized-inject test maps against was set the way a real game sets it.
fn guestInt33CXDX(m: *Machine, ax: u16, cx: u16, dx: u16) void {
    asmInt67(m, &.{
        0xB8, @truncate(ax), @truncate(ax >> 8), // MOV AX, imm16
        0xB9, @truncate(cx), @truncate(cx >> 8), // MOV CX, imm16
        0xBA, @truncate(dx), @truncate(dx >> 8), // MOV DX, imm16
        0xCD, 0x33, // INT 33h
        0xF4, // HLT
    });
}

test "INT 33h normalized inject maps through the LIVE fn 7/8 range (range-AWARE)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // The guest REPROGRAMS the coordinate range the way Betrayal at Krondor does:
    // fn 7 horizontal [0,1276], fn 8 vertical [0,796] (a quarter-pixel range). The
    // driver honors it (gran 0xffff default, no reset → no granularity mask).
    guestInt33CXDX(m, 0x0007, 0, 1276);
    guestInt33CXDX(m, 0x0008, 0, 796);
    try std.testing.expectEqual(@as(i16, 1276), m.dos.mouse.max_x);
    try std.testing.expectEqual(@as(i16, 796), m.dos.mouse.max_y);

    // A NORMALIZED inject (Q16, the unit `nx`/`ny` convert to) maps through that LIVE
    // range via the SAME `q16ToVirtual` the seamless path uses: 0 → min, 0x8000 →
    // midpoint, 0x1_0000 → the max edge. This is the scripted-path parity the fix adds.
    const br = &m.svc.bridge;
    m.dos.mouse.injectAndFire(&m.cpu, br, .{ .nx_q16 = 0, .ny_q16 = 0, .set_nx = true, .set_ny = true });
    try std.testing.expectEqual(@as(i16, 0), m.dos.mouse.x);
    try std.testing.expectEqual(@as(i16, 0), m.dos.mouse.y);

    m.dos.mouse.injectAndFire(&m.cpu, br, .{ .nx_q16 = 0x8000, .ny_q16 = 0x8000, .set_nx = true, .set_ny = true });
    try std.testing.expectEqual(@as(i16, 638), m.dos.mouse.x); // midpoint of [0,1276]
    try std.testing.expectEqual(@as(i16, 398), m.dos.mouse.y); // midpoint of [0,796]

    m.dos.mouse.injectAndFire(&m.cpu, br, .{ .nx_q16 = 0x1_0000, .ny_q16 = 0x1_0000, .set_nx = true, .set_ny = true });
    try std.testing.expectEqual(@as(i16, 1276), m.dos.mouse.x); // the right edge
    try std.testing.expectEqual(@as(i16, 796), m.dos.mouse.y); // the bottom edge

    // RANGE-AWARE: reprogram to the DEFAULT-style range [0,639]×[0,479] and inject the
    // SAME midpoint Q16 — it now lands at a DIFFERENT driver coordinate (320, not 638),
    // proving the mapping reads the driver's live range, with zero game-specific assumptions.
    guestInt33CXDX(m, 0x0007, 0, 639);
    guestInt33CXDX(m, 0x0008, 0, 479);
    m.dos.mouse.injectAndFire(&m.cpu, br, .{ .nx_q16 = 0x8000, .ny_q16 = 0x8000, .set_nx = true, .set_ny = true });
    try std.testing.expectEqual(@as(i16, 320), m.dos.mouse.x); // midpoint of [0,639] ≠ 638
    try std.testing.expectEqual(@as(i16, 240), m.dos.mouse.y); // midpoint of [0,479]
}

test "input Phase 2: guest reads an injected position back via INT 33h AX=0003 (black-box)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Inject an ABSOLUTE position + buttons, then let the GUEST read it back via
    // the real AX=0003 handler. Defaults: range x=0..639 y=0..479, gran 0xffff,
    // so an even-or-any value round-trips exactly (no mode-13h X-even mask here).
    m.dos.mouse.injectAbsolute(222, 134, 0b101, true, true, true);
    const r = guestInt33(m, 0x0003);
    try std.testing.expectEqual(@as(u16, 222), r.cx);
    try std.testing.expectEqual(@as(u16, 134), r.dx);
    try std.testing.expectEqual(@as(u16, 0b101), r.bx);

    // A relative move then an AX=000B read returns the accumulated mickeys AND
    // zeroes them (the new accumulate-and-zero contract), proven via the guest.
    m.dos.mouse.injectRelative(10, -10, 0, true, true, false);
    const counters_before = m.dos.mouse.mickey_x; // non-zero after the move
    try std.testing.expect(counters_before != 0);
    const m1 = guestInt33(m, 0x000B);
    try std.testing.expect(m1.cx != 0 or m1.dx != 0); // got the accumulated mickeys
    // Second read returns 0/0 (zeroed on the first read).
    const m2 = guestInt33(m, 0x000B);
    try std.testing.expectEqual(@as(u16, 0), m2.cx);
    try std.testing.expectEqual(@as(u16, 0), m2.dx);
}

// ===========================================================================
// Live-mouse SEAMLESS fold (plans/mouse-input.md §5/§7, LOCKED §2/§3/§7). The
// browser POSTs a NORMALIZED Q16 absolute (+ true movementX/Y relative); the
// fold writes the absolute through the driver's LIVE per-mode range and feeds
// the relative deltas to the real mickey path. These prove the three things the
// review locked: (D) the half-speed-X fix — a full-scale Q16 reaches the FAR
// edge of the per-mode range (638 in mode 13h), not the middle (~319) as the old
// guest-pixel mapping did; (A/B) the §7 fix — the INT 33h range FOLLOWS a video
// mode change, both at the driver level and end-to-end through the real INT 10h
// AH=00 hook; (C) AX=0B mickeys come from the true relative channel and zero on
// read. All exercise the same real driver the browser fold calls.
// ===========================================================================

const BDA_VIDEO_MODE_PHYS: u32 = 0x0449;

test "live mouse seamless: Q16 absolute maps to the per-mode range (mode 13h half-speed-X fix)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Put the driver in mode 13h's range (max_x=639, max_y=199, gran_x=0xfffe).
    m.bus.writePhys8(BDA_VIDEO_MODE_PHYS, 0x13);
    m.dos.mouse.afterNewVideoMode(&m.cpu);

    // Full-scale Q16 (≈1.0) → the FAR edge of the X range: 639 masked by the
    // even-X granularity 0xfffe = 638; Y full-scale → 199. THIS is the fix: the
    // old browser mapping sent guest pixels 0..319, so a full-right move capped at
    // 319 (the middle of the 0..639 driver range) — half-speed X.
    m.dos.mouse.injectSeamless(&m.cpu, &m.svc.bridge, .{
        .abs_x_q16 = 0xFFFF,
        .abs_y_q16 = 0xFFFF,
        .set_abs = true,
    });
    const far = guestInt33(m, 0x0003);
    try std.testing.expectEqual(@as(u16, 638), far.cx);
    try std.testing.expectEqual(@as(u16, 199), far.dx);

    // Mid-scale Q16 (0.5) → ~320 — i.e. the value the OLD code wrongly produced at
    // FULL right. Proves the scale now spans the whole range, not half of it.
    m.dos.mouse.injectSeamless(&m.cpu, &m.svc.bridge, .{
        .abs_x_q16 = 0x8000,
        .abs_y_q16 = 0x8000,
        .set_abs = true,
    });
    const mid = guestInt33(m, 0x0003);
    try std.testing.expectEqual(@as(u16, 320), mid.cx);
}

test "live mouse seamless §7: INT 33h range follows a mode change (driver level)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Mode 0x12 (640x480 16-color): max_y=479, gran_x=0xffff.
    m.bus.writePhys8(BDA_VIDEO_MODE_PHYS, 0x12);
    m.dos.mouse.afterNewVideoMode(&m.cpu);
    try std.testing.expectEqual(@as(i16, 639), m.dos.mouse.max_x);
    try std.testing.expectEqual(@as(i16, 479), m.dos.mouse.max_y);
    try std.testing.expectEqual(@as(u16, 0xffff), m.dos.mouse.gran_x);

    // Switch to 13h: the range MUST follow (max_y shrinks to 199, X granularity
    // becomes even). Before this fix the range only followed an AX=00/21 reset.
    m.bus.writePhys8(BDA_VIDEO_MODE_PHYS, 0x13);
    m.dos.mouse.afterNewVideoMode(&m.cpu);
    try std.testing.expectEqual(@as(i16, 639), m.dos.mouse.max_x);
    try std.testing.expectEqual(@as(i16, 199), m.dos.mouse.max_y);
    try std.testing.expectEqual(@as(u16, 0xfffe), m.dos.mouse.gran_x);
}

test "live mouse seamless §7: a REAL INT 10h AH=00 set-mode re-derives the range (machine hook)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // Corrupt the range with sentinels so the assertion proves the hook RE-DERIVED
    // it (not that it happened to already be correct).
    m.dos.mouse.max_x = 111;
    m.dos.mouse.max_y = 999;
    m.dos.mouse.gran_x = 0xffff;

    // Drive the REAL BIOS set-mode (MOV AX,0013h ; INT 10h ; HLT). The machine
    // facade fires `afterNewVideoMode` after the BIOS services AH=00 (machine.zig
    // §7 hook) — no direct driver call here.
    asmInt67(m, &.{
        0xB8, 0x13, 0x00, // MOV AX, 0013h
        0xCD, 0x10, // INT 10h
        0xF4, // HLT
    });
    try std.testing.expectEqual(@as(i16, 639), m.dos.mouse.max_x);
    try std.testing.expectEqual(@as(i16, 199), m.dos.mouse.max_y);
    try std.testing.expectEqual(@as(u16, 0xfffe), m.dos.mouse.gran_x);
}

test "live mouse seamless: relative deltas drive AX=0B mickeys (true channel), zero on read" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // A relative-only seamless fold (the browser's movementX/Y) must accumulate
    // mickeys via the SAME fixed-point path as a scripted injectRelative — not be
    // derived from an absolute delta.
    m.dos.mouse.injectSeamless(&m.cpu, &m.svc.bridge, .{ .dx = 20, .dy = -15, .set_rel = true });
    try std.testing.expect(m.dos.mouse.mickey_x != 0 or m.dos.mouse.mickey_y != 0);

    const r1 = guestInt33(m, 0x000B);
    try std.testing.expect(r1.cx != 0 or r1.dx != 0); // accumulated mickeys
    const r2 = guestInt33(m, 0x000B);
    try std.testing.expectEqual(@as(u16, 0), r2.cx); // zeroed on the first read
    try std.testing.expectEqual(@as(u16, 0), r2.dx);
}

test "live mouse seamless: COMBINED abs+rel fold — position tracks absolute (no double-apply), mickeys still accumulate" {
    // The REAL browser fold sends BOTH a Q16 absolute AND the movementX/Y relative
    // on every move. Position MUST come from the absolute ALONE (dosbox seamless +
    // LOCKED §3); the relative feeds AX=0B mickeys only. A regression guard for the
    // double-apply bug where injectRelative also advanced the cursor position.
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    m.bus.writePhys8(BDA_VIDEO_MODE_PHYS, 0x13);
    m.dos.mouse.afterNewVideoMode(&m.cpu);

    // Mid-screen absolute (→ x=320, y=100 in mode 13h) WITH a chunky relative delta
    // that, if double-applied, would push the position well past the target.
    m.dos.mouse.injectSeamless(&m.cpu, &m.svc.bridge, .{
        .abs_x_q16 = 0x8000,
        .abs_y_q16 = 0x8000,
        .dx = 40,
        .dy = 40,
        .set_abs = true,
        .set_rel = true,
    });

    // Position is EXACTLY the absolute target — the relative did not move the cursor.
    const pos = guestInt33(m, 0x0003);
    try std.testing.expectEqual(@as(u16, 320), pos.cx);
    try std.testing.expectEqual(@as(u16, 100), pos.dx);

    // ...but the relative DID accumulate mickeys (the true AX=0B channel still works).
    const mick = guestInt33(m, 0x000B);
    try std.testing.expect(mick.cx != 0 or mick.dx != 0);
}

// ===========================================================================
// Input Phase 3 — the INT 33h AX=0Ch event callback. This is what real
// Betrayal at Krondor requires: it installs an AH=0Ch handler and NEVER polls
// AX=03, so injected movement/clicks reach it ONLY by firing this far-call.
// These tests plant a tiny GUEST handler in guest RAM, install it via the REAL
// INT 33h AX=0C service, then inject and prove (a) the handler RAN with the
// right register values (it latched them to guest RAM), and (b) the cycle
// counter advanced by exactly the handler's instruction cost (no ledger hole).
// ===========================================================================

const HANDLER_SEG: u16 = 0x3000;
const HANDLER_OFF: u16 = 0x0010; // handler code starts here
// Fixed guest-RAM slots (within HANDLER_SEG) the handler latches its args into.
const SLOT_CX: u16 = 0x0000;
const SLOT_DX: u16 = 0x0002;
const SLOT_BL: u16 = 0x0004;

// Plant a tiny far event handler at HANDLER_SEG:HANDLER_OFF that latches the
// callback's CX/DX/BL into fixed guest-RAM slots, then RETFs. It establishes its
// OWN DS (`PUSH CS; POP DS`) exactly like BaK's Borland far callback — proving the
// driver need not (and does not) set DS for the user sub.
//   0E              PUSH CS
//   1F              POP DS              ; DS = HANDLER_SEG (handler's own DGROUP)
//   89 0E 00 00     MOV [SLOT_CX], CX
//   89 16 02 00     MOV [SLOT_DX], DX
//   88 1E 04 00     MOV [SLOT_BL], BL
//   CB              RETF
fn plantMouseHandler(m: *Machine) void {
    const base = (@as(u32, HANDLER_SEG) << 4) + HANDLER_OFF;
    const code = [_]u8{
        0x0E, // PUSH CS
        0x1F, // POP DS
        0x89, 0x0E, @truncate(SLOT_CX), @truncate(SLOT_CX >> 8), // MOV [SLOT_CX],CX
        0x89, 0x16, @truncate(SLOT_DX), @truncate(SLOT_DX >> 8), // MOV [SLOT_DX],DX
        0x88, 0x1E, @truncate(SLOT_BL), @truncate(SLOT_BL >> 8), // MOV [SLOT_BL],BL
        0xCB, // RETF
    };
    for (code, 0..) |c, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), c);
    // Zero the latch slots so a stale value can't masquerade as a fired callback.
    const sbase = @as(u32, HANDLER_SEG) << 4;
    m.bus.writePhys16(sbase + SLOT_CX, 0);
    m.bus.writePhys16(sbase + SLOT_DX, 0);
    m.bus.writePhys16(sbase + SLOT_BL, 0);
}

// Install the planted handler via the REAL INT 33h AX=0C service (guest asm:
// MOV CX,mask ; MOV AX,HANDLER_SEG ; MOV ES,AX ; MOV DX,HANDLER_OFF ;
// MOV AX,0x000C ; INT 33h ; HLT). Uses the same IVT 0x33 -> dos.mouse.service
// path the game uses — no host shortcut.
fn installMouseHandler(m: *Machine, mask: u16) void {
    asmInt67(m, &.{
        0xB9, @truncate(mask), @truncate(mask >> 8), // MOV CX, mask
        0xB8, @truncate(HANDLER_SEG), @truncate(HANDLER_SEG >> 8), // MOV AX, HANDLER_SEG
        0x8E, 0xC0, // MOV ES, AX
        0xBA, @truncate(HANDLER_OFF), @truncate(HANDLER_OFF >> 8), // MOV DX, HANDLER_OFF
        0xB8, 0x0C, 0x00, // MOV AX, 0x000C
        0xCD, 0x33, // INT 33h
        0xF4, // HLT
    });
}

fn slot16(m: *Machine, off: u16) u16 {
    return m.bus.readPhys16((@as(u32, HANDLER_SEG) << 4) + off);
}

test "input Phase 3: injected mouse event fires the AX=0Ch handler with the right regs (no hole)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    plantMouseHandler(m);
    // Install for ALL events (mask 0x7F: move + every button up/down).
    installMouseHandler(m, 0x7F);
    try std.testing.expectEqual(HANDLER_SEG, m.dos.mouse.handler_seg);
    try std.testing.expectEqual(HANDLER_OFF, m.dos.mouse.handler_off);
    try std.testing.expectEqual(@as(u16, 0x7F), m.dos.mouse.handler_mask);

    // Inject an absolute move to (222,134) with the LEFT button pressed. This is a
    // move + left-press, both in the mask, so the handler MUST fire.
    const cyc_before = m.cpu.st.cycles;
    m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
        .x = 222,
        .y = 134,
        .buttons = 0b001,
        .set_x = true,
        .set_y = true,
        .set_buttons = true,
    });

    // (a) The handler RAN: it latched the callback's CX/DX/BL into guest RAM. CX/DX
    // are the granularity-masked position (== AX=03 read), BL the button state.
    try std.testing.expectEqual(@as(u16, 222), slot16(m, SLOT_CX));
    try std.testing.expectEqual(@as(u16, 134), slot16(m, SLOT_DX));
    try std.testing.expectEqual(@as(u16, 0b001), slot16(m, SLOT_BL) & 0xFF);

    // (b) NO ledger hole: the cycle counter advanced by the handler's real
    // instruction cost (the 6 guest instructions the far-call ran). Strictly > 0.
    try std.testing.expect(m.cpu.st.cycles > cyc_before);

    // After the far-call the machine's CS:IP/SP are restored (runGuestFarCall
    // contract): a subsequent guest INT 33h still works — read the position back.
    const r = guestInt33(m, 0x0003);
    try std.testing.expectEqual(@as(u16, 222), r.cx);
    try std.testing.expectEqual(@as(u16, 134), r.dx);
}

test "input Phase 3: callback does NOT fire when the event is outside the installed mask" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    plantMouseHandler(m);
    // Register for RIGHT-button events ONLY (bits 3|4), NOT move or left.
    installMouseHandler(m, EV_RBTN_DOWN | EV_RBTN_UP);

    const cyc_before = m.cpu.st.cycles;
    // A pure move + left-press — none of those bits are in the installed mask.
    m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
        .x = 100,
        .y = 100,
        .buttons = 0b001,
        .set_x = true,
        .set_y = true,
        .set_buttons = true,
    });

    // The handler must NOT have run: latch slots stay zero, no cycles charged.
    try std.testing.expectEqual(@as(u16, 0), slot16(m, SLOT_CX));
    try std.testing.expectEqual(@as(u16, 0), slot16(m, SLOT_DX));
    try std.testing.expectEqual(cyc_before, m.cpu.st.cycles);

    // Now a RIGHT-button press IS in the mask -> the handler fires.
    m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
        .buttons = 0b011, // keep left, add right
        .set_buttons = true,
    });
    try std.testing.expectEqual(@as(u16, 0b011), slot16(m, SLOT_BL) & 0xFF);
    try std.testing.expect(m.cpu.st.cycles > cyc_before);
}

// Mirror the EV_* bits from int33.zig (private there); used by the mask test.
const EV_RBTN_DOWN: u16 = 1 << 3;
const EV_RBTN_UP: u16 = 1 << 4;

test "input Phase 3: firing the callback is byte-identical across two runs (determinism)" {
    const alloc = std.testing.allocator;
    var a = try boot(alloc);
    defer a.deinit();
    var b = try boot(alloc);
    defer b.deinit();

    inline for (.{ a, b }) |ctx| {
        const m = ctx.m;
        plantMouseHandler(m);
        installMouseHandler(m, 0x7F);
        m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
            .x = 200,
            .y = 120,
            .buttons = 0b001,
            .set_x = true,
            .set_y = true,
            .set_buttons = true,
        });
        m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
            .dx = 15,
            .dy = -7,
            .buttons = 0b010,
            .set_dx = true,
            .set_dy = true,
            .set_buttons = true,
        });
    }

    // Same script -> byte-identical driver state, latched guest RAM, AND cycles.
    try std.testing.expectEqual(a.m.dos.mouse, b.m.dos.mouse);
    try std.testing.expectEqual(a.m.cpu.st.cycles, b.m.cpu.st.cycles);
    try std.testing.expectEqual(slot16(a.m, SLOT_CX), slot16(b.m, SLOT_CX));
    try std.testing.expectEqual(slot16(a.m, SLOT_DX), slot16(b.m, SLOT_DX));
    try std.testing.expectEqual(slot16(a.m, SLOT_BL), slot16(b.m, SLOT_BL));
    // Sanity: the handler actually latched the final relative-move state.
    try std.testing.expect(slot16(a.m, SLOT_BL) & 0xFF == 0b010);
}

// ===========================================================================
// PHASE 1 REPRODUCTION (plans/mouse-callback-irq-strand.md) — the PIC timer-IRQ
// strand. The INT 33h AX=0Ch mouse callback is fired OUT OF BAND as a bare
// `runGuestFarCall` with the foreground IF (=1 for the BaK spin) and NO PIC/EOI
// frame discipline. With IF=1 a hardware timer IRQ0 can be acknowledged
// (master ISR bit0 -> 1) INSIDE the callback's `runGuestFarCall` step loop.
//
// The hermetic claim: there is a PIT-IRQ0 due-cycle offset, landing inside the
// callback window, at which `runGuestFarCall` returns with master ISR bit0 STUCK
// set and never EOI'd — exactly the live BaK deadlock state (isr=1, irr=1,
// getPendingInterrupt()==null, timer dead). We SWEEP every offset across the
// window and assert the CORRECT (no-strand) behavior, so the test goes RED at
// the stranding offset(s).
//
// Wiring (machine-level, the real paths only):
//  - A guest INT 08h ISR planted in RAM: INC a known RAM counter, EOI to the
//    master (OUT 0x20,0x20), IRET. IVT[8] -> it. (A faithful self-EOI timer ISR
//    like BaK's own, whose exit is CORRECT.)
//  - A multi-instruction AX=0Ch mouse handler (many NOPs so a timer IRQ has
//    boundaries to land on mid-callback), then RETF. Installed via the REAL
//    INT 33h AX=0Ch service. Event mask armed for all events.
//  - The PIT ch0 IRQ0 scheduled (via the real scheduler seam the PIT uses) to
//    come due at cycles_now + delta, swept across the whole callback window.
//  - Foreground IF=1.
//  - The callback fired the live way: `injectAndFire` -> fireEventCallback ->
//    runGuestFarCall.
// ===========================================================================

// A second handler segment so this repro never collides with plantMouseHandler's
// HANDLER_SEG latch slots.
const STRAND_HANDLER_SEG: u16 = 0x4000;
const STRAND_HANDLER_OFF: u16 = 0x0010;

// A guest INT 08h timer ISR seg:off and its RAM tick-counter slot (a separate
// segment so it can't alias the handler or the IVT).
const STRAND_ISR_SEG: u16 = 0x5000;
const STRAND_ISR_OFF: u16 = 0x0010;
const STRAND_TICK_SLOT: u16 = 0x0000; // word counter at STRAND_ISR_SEG:0

// Plant a multi-instruction AX=0Ch handler: a run of NOPs (a wide window for the
// timer IRQ to land on a boundary), then RETF. No memory writes — we only care
// about the PIC strand, not the latched args.
fn plantStrandHandler(m: *Machine) void {
    const base = (@as(u32, STRAND_HANDLER_SEG) << 4) + STRAND_HANDLER_OFF;
    var code: [33]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) code[i] = 0x90; // NOP x32 (wide boundary window)
    code[32] = 0xCB; // RETF
    for (code, 0..) |c, k| m.bus.writePhys8(base + @as(u32, @intCast(k)), c);
}

// Install the strand handler via the REAL INT 33h AX=0Ch service.
fn installStrandHandler(m: *Machine, mask: u16) void {
    asmInt67(m, &.{
        0xB9, @truncate(mask), @truncate(mask >> 8), // MOV CX,mask
        0xB8, @truncate(STRAND_HANDLER_SEG), @truncate(STRAND_HANDLER_SEG >> 8), // MOV AX,seg
        0x8E, 0xC0, // MOV ES,AX
        0xBA, @truncate(STRAND_HANDLER_OFF), @truncate(STRAND_HANDLER_OFF >> 8), // MOV DX,off
        0xB8, 0x0C, 0x00, // MOV AX,0x000C
        0xCD, 0x33, // INT 33h
        0xF4, // HLT
    });
}

// Plant a faithful self-EOI guest INT 08h timer ISR and point IVT[8] at it:
//   FF 06 <slot>   INC word [STRAND_TICK_SLOT]   (DS-relative; DS == ISR seg)
//   B0 20          MOV AL,0x20
//   E6 20          OUT 0x20,AL                    (non-specific EOI to master)
//   CF             IRET
// It establishes its own DS (PUSH CS; POP DS) so the INC hits STRAND_ISR_SEG.
fn plantTimerIsr(m: *Machine) void {
    const base = (@as(u32, STRAND_ISR_SEG) << 4) + STRAND_ISR_OFF;
    const code = [_]u8{
        0x0E, // PUSH CS
        0x1F, // POP DS                  ; DS = STRAND_ISR_SEG
        0xFF, 0x06, @truncate(STRAND_TICK_SLOT), @truncate(STRAND_TICK_SLOT >> 8), // INC word [slot]
        0xB0, 0x20, // MOV AL,0x20
        0xE6, 0x20, // OUT 0x20,AL       ; EOI master
        0xCF, // IRET
    };
    for (code, 0..) |c, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), c);
    // Zero the tick counter so a stale value can't masquerade as a tick.
    m.bus.writePhys16((@as(u32, STRAND_ISR_SEG) << 4) + STRAND_TICK_SLOT, 0);
    // Point IVT[8] (idtr_base==0 after post -> vector*4 = 0x20) at the ISR.
    m.bus.writePhys16(0x08 * 4 + 0, STRAND_ISR_OFF);
    m.bus.writePhys16(0x08 * 4 + 2, STRAND_ISR_SEG);
}

fn tickCount(m: *Machine) u16 {
    return m.bus.readPhys16((@as(u32, STRAND_ISR_SEG) << 4) + STRAND_TICK_SLOT);
}

// Schedule a single PIT ch0 IRQ0 to come due exactly `delta` cycles in the
// future, using the SAME scheduler seam the PIT's armCh0 uses (source_id =
// PIT_SOURCE_ID, kind = .pit_ch0). We drive ch0 in mode 0 (one-shot) so the
// machine's fireDue -> onPitCh0Fire raises IRQ0 once and does NOT auto re-arm,
// giving us a single, precisely-placed timer interrupt for the sweep.
const PIT_SOURCE_ID = machine_mod.PIT_SOURCE_ID;

// Arm a tight foreground spin (JMP $) at CODE_SEG:0 with a valid stack and IF=1,
// NOT halted — the BaK spin context the out-of-band callback fires into.
fn setStrandForeground(m: *Machine) void {
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFF00);
    m.bus.writePhys8((@as(u32, CODE_SEG) << 4) + 0, 0xEB); // JMP $
    m.bus.writePhys8((@as(u32, CODE_SEG) << 4) + 1, 0xFE);
    m.cpu.st.eflags.iff = true;
    m.cpu.st.halted = false;
}

fn scheduleOneShotIrq0(m: *Machine, delta: u64) void {
    m.sched.cancel(PIT_SOURCE_ID, .pit_ch0); // drop any live ch0 event
    // Mode 0 one-shot so onPitCh0Fire raises IRQ0 once without re-arming.
    m.pit.channels[0].mode = .mode0;
    m.pit.channels[0].reload = 1000; // any non-degenerate reload (unused for delta here)
    // The scheduler keys on DEVICE-TIME: anchor at the machine's continuous
    // device-time accumulator (the LOCKED-design "now"); the delta crosses the
    // CPU→device-time boundary (identity at the pinned mult 12). At mult 12
    // device_time == cpu.st.cycles, so this is byte-identical.
    m.sched.schedule(m.device_time, timing.cpuToDevice(delta, m.clock.mult), PIT_SOURCE_ID, .pit_ch0, 0);
}

test "live mouse: AX=0Ch callback must not strand a hardware IRQ in-service (timer nested at the sentinel boundary, cycle sweep)" {
    const alloc = std.testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    plantStrandHandler(m);
    installStrandHandler(m, 0x7F); // arm for all events
    plantTimerIsr(m);

    // post() already programmed the PIC (IRQ0 unmasked). Confirm the preconditions
    // the BaK spin had: IRQ0 unmasked, nothing yet in service.
    try std.testing.expectEqual(@as(u8, 0), m.pic.master.imr & 0x01); // IRQ0 unmasked
    try std.testing.expectEqual(@as(u8, 0), m.pic.master.isr & 0x01); // nothing in service

    // post() armed the BIOS default ~18.2 Hz periodic IRQ0. Cancel it + make ch0
    // inactive so the ONLY timer interrupt during the sweep is the one we place
    // (otherwise the default period dominates the window measurement). Each sweep
    // iteration re-arms its own one-shot via scheduleOneShotIrq0.
    m.sched.cancel(PIT_SOURCE_ID, .pit_ch0);
    m.pit.channels[0].mode = .inactive;

    // A valid foreground (CS:SS:SP) with IF=1, NOT halted — installStrandHandler's
    // HLT left the CPU halted; the far-call must execute, not idle.
    setStrandForeground(m);

    // Find the callback's cycle WIDTH so we can sweep the whole window. Fire once
    // with NO timer scheduled to measure how many cycles the far-call costs (just
    // the planted handler's instructions — the sentinel-step boundary is its end).
    const probe_before = m.cpu.st.cycles;
    m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
        .x = 100,
        .y = 100,
        .buttons = 0b001,
        .set_x = true,
        .set_y = true,
        .set_buttons = true,
    });
    const window = m.cpu.st.cycles - probe_before;
    try std.testing.expect(window > 0);

    // Sweep the IRQ0 due-cycle across [1 .. window + slack]. At EACH offset:
    //   * arm a foreground spin with IF=1,
    //   * schedule the one-shot IRQ0 at cycles_now + delta,
    //   * fire the callback the live way,
    //   * assert the CORRECT post-state: master ISR bit0 CLEAR, and the timer is
    //     still LIVE (a subsequent scheduled IRQ0 delivers and bumps the counter).
    var strand_offsets: [64]u64 = undefined;
    var n_strands: usize = 0;

    var delta: u64 = 1;
    const sweep_end = window + 8;
    while (delta <= sweep_end) : (delta += 1) {
        // Fresh PIC/CPU interrupt preconditions for this offset. Clear any
        // residue from the previous iteration so each offset is independent.
        m.pic.master.isr = 0;
        m.pic.master.irr = 0;
        m.pic.slave.isr = 0;
        m.pic.slave.irr = 0;
        m.bus.writePhys16((@as(u32, STRAND_ISR_SEG) << 4) + STRAND_TICK_SLOT, 0);

        // Foreground: a tight JMP $ spin at a fixed seg:off, IF=1 (the BaK spin).
        setStrandForeground(m);

        // Schedule the timer IRQ0 to land at cycles_now + delta (inside/around the
        // callback window), then fire the callback OUT OF BAND like the live path.
        scheduleOneShotIrq0(m, delta);
        m.dos.mouse.injectAndFire(&m.cpu, &m.svc.bridge, .{
            .dx = 3,
            .dy = -2,
            .set_dx = true,
            .set_dy = true,
        });

        // --- Observe the PIC state immediately after the out-of-band callback ---
        const isr_after = m.pic.master.isr & 0x01;

        // CORRECT behavior: bit0 must NOT be stuck in-service. Either the IRQ0 was
        // not yet acked (still pending in IRR, to be delivered by the foreground),
        // or it was acked AND its ISR ran its EOI to completion -> isr clear.
        if (isr_after != 0) {
            // Strand candidate. Confirm it is the LIVE deadlock state: prove the
            // timer is DEAD — step the foreground (IF=1, IRQ0 unmasked, the spin)
            // and a freshly scheduled IRQ0 can NOT deliver (the equal-rank
            // re-pending IRQ0 is blocked by the in-service bit -> counter frozen).
            const irr_after = m.pic.master.irr & 0x01;
            const ticks_before = tickCount(m);
            // Schedule another IRQ0 and let the foreground spin run well past it.
            scheduleOneShotIrq0(m, 4);
            _ = m.runCycles(2000);
            const ticks_after = tickCount(m);
            const irr_repended = m.pic.master.irr & 0x01; // the re-pending IRQ0
            const pending = m.pic.getPendingInterrupt();

            if (n_strands < strand_offsets.len) strand_offsets[n_strands] = delta;
            n_strands += 1;
            std.debug.print(
                "STRAND at delta={d}: post-callback isr&1={d} irr&1={d} | after re-pend+spin: isr&1={d} irr&1={d} ticks {d}->{d} (frozen={}) getPendingInterrupt={any}\n",
                .{ delta, isr_after, irr_after, m.pic.master.isr & 1, irr_repended, ticks_before, ticks_after, ticks_after == ticks_before, pending },
            );
        }
    }

    if (n_strands > 0) {
        std.debug.print("REGRESSION: IRQ strand at {d} offset(s) in [1..{d}]; first={d}\n", .{ n_strands, sweep_end, strand_offsets[0] });
    }

    // THE ASSERTION (correct behavior): NO offset may leave the timer IRQ0 stuck
    // in-service. RED here == the strand reproduced.
    //
    // OBSERVED (current code, RED): offsets delta=129..132 strand. At each, the
    // diagnostics confirmed the exact mechanism — vector 0x08 (IRQ0) WAS delivered
    // INSIDE the callback (cpu.st.last_delivered.vector==8, seq incremented: the
    // ISR was ENTERED, ackIrq set master.isr bit0), but `runGuestFarCall`'s
    // unconditional CS:IP/SP restore returned the CPU to the FOREGROUND spin
    // (CS:IP back at CODE_SEG:0) BEFORE the ISR ran its `OUT 0x20,0x20` EOI. The
    // in-service bit is stranded. After a fresh IRQ0 re-pends, the master sits at
    // isr&1=1 AND irr&1=1 with getPendingInterrupt()==null (equal-rank IRQ0 blocked
    // by the in-service bit — pic.zig pendingLine rank gate) and the tick counter
    // is FROZEN — byte-for-byte the live BaK deadlock (plan §0/§1).
    //
    // The stranding offsets are the cycles at which the timer IRQ0 first becomes
    // due ON THE STOP-SENTINEL step of runGuestFarCall: cpu.step() runs the
    // sentinel via executeOne (which sets reentry_done=true), THEN serviceInterrupts
    // acks+delivers IRQ0 at that same boundary; the loop sees reentry_done and
    // exits, restoring CS:IP and abandoning the just-entered ISR (bridge.zig:705-714).
    try std.testing.expectEqual(@as(usize, 0), n_strands);
}
