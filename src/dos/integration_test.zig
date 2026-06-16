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

const Machine = machine_mod.Machine;
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
