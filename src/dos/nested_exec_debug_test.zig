//! Nested-EXEC debugger-visibility tests (plans/nested-exec-debug.md).
//!
//! Before the de-nest, an `INT 21h AH=4Bh` EXEC ran the child NESTED inside the
//! host handler (`bridge.runUntil`), so the controller's single between-steps
//! breakpoint scan was suspended for the child's entire lifetime: an
//! `interrupt:0x21` breakpoint saw ZERO of the child's INT 21h calls, no
//! memory/io/execution_address watchpoint tripped, `run-to-cycle N` inside the
//! child overshot, and `step`/`step-n` could not descend. After the de-nest the
//! child runs on the ONE controller-owned step loop, so ALL of those work inside
//! the child "for free". These tests prove each one fires, that pause->resume
//! returns the parent intact (the 18-byte register block), that a mid-child
//! snapshot ROUND-TRIPS through `snapshot()`/`restore()` into a fresh machine, and
//! that two runs across an EXEC are byte-identical (the prime directive).

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const debug = @import("debug");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;
const Seg = cpu_mod.state.Seg;

// ===========================================================================
// Test programs (COM, loaded at PSP:0x100; CS=DS=ES=SS=psp on entry).
// ===========================================================================

// CHILD.COM — does TWO identifiable INT 21h calls (AH=30 get-version, then the
// AH=4C exit), writes a sentinel byte to absolute linear 0x0510 (a `memory`
// watch target), and `OUT 0x80,AL` (the diagnostic port, unclaimed — an `io`
// watch target). Exits with code 7. Runtime addresses: file offset N -> 0x100+N.
const CHILD_MEM_LINEAR: u32 = 0x0510; // the sentinel write address (DS=0)
const CHILD_IO_PORT: u16 = 0x0080; // the OUT port
const CHILD_EXIT_CODE: u16 = 7;
const child_com = [_]u8{
    0xB4, 0x30, // MOV AH,0x30   ; get DOS version (interrupt:0x21 inside child #1)
    0xCD, 0x21, // INT 0x21
    0xB8, 0x00, 0x00, // MOV AX,0
    0x8E, 0xD8, // MOV DS,AX     ; DS=0 -> absolute addressing
    0xC6, 0x06, 0x10, 0x05, 0xAB, // MOV byte [0x0510],0xAB   ; memory-watch target
    0xB0, 0xAB, // MOV AL,0xAB
    0xE6, 0x80, // OUT 0x80,AL   ; io-watch target (write to port 0x80)
    0xB8, 0x07, 0x4C, // MOV AX,0x4C07
    0xCD, 0x21, // INT 0x21      ; terminate(7) (interrupt:0x21 inside child #2)
};

// PARENT.COM — builds an EXEC param block, launches CHILD.COM via INT 21h AH=4B
// AL=00 (load-and-execute), then reads the child's exit code via AH=4D and
// terminates with it (so the parent's exit code == the child's, proving the
// unwind restored the parent + AH=4D works). Param block + data live at fixed
// offsets in the COM image; the segment fields are filled from CS at runtime.
const PB_OFF: u16 = 0x140; // EXEC param block
const CMDTAIL_OFF: u16 = 0x150; // command tail: len=0, CR
const FCB_OFF: u16 = 0x154; // a blank 16-byte FCB (shared for fcb1/fcb2)
const PATH_OFF: u16 = 0x170; // "CHILD.COM\0"

fn buildParentCom(buf: []u8) usize {
    @memset(buf, 0);
    const code = [_]u8{
        // Shrink our own memory block (a COM grabs ALL conventional RAM) so the
        // child has room — exactly what Borland's spawn() does via AH=4A before
        // AH=4B. ES = our PSP at COM entry.
        0xB4, 0x4A, // MOV AH,0x4A       ; resize memory block
        0xBB, 0x00, 0x02, // MOV BX,0x0200     ; new size = 512 paragraphs (8 KiB)
        0xCD, 0x21, // INT 0x21          ; ES:BX (ES=psp)
        0x8C, 0xC8, // MOV AX,CS
        0xA3, 0x44, 0x01, // MOV [0x0144],AX   ; param.cmdtail_seg = CS
        0xA3, 0x48, 0x01, // MOV [0x0148],AX   ; param.fcb1_seg = CS
        0xA3, 0x4C, 0x01, // MOV [0x014C],AX   ; param.fcb2_seg = CS
        0xBA, 0x70, 0x01, // MOV DX,0x0170     ; DS:DX = path (DS=psp)
        0xBB, 0x40, 0x01, // MOV BX,0x0140     ; ES:BX = param block (ES=psp)
        0xB8, 0x00, 0x4B, // MOV AX,0x4B00     ; EXEC load-and-execute
        0xCD, 0x21, // INT 0x21
        0xB4, 0x4D, // MOV AH,0x4D       ; get child return code -> AL
        0xCD, 0x21, // INT 0x21
        0xB4, 0x4C, // MOV AH,0x4C       ; exit(AL == child rc)
        0xCD, 0x21, // INT 0x21
    };
    @memcpy(buf[0..code.len], &code);

    // EXEC param block (offsets within the COM image == runtime off - 0x100).
    const f = struct {
        fn w(b: []u8, off: u16, v: u16) void {
            b[off - 0x100] = @truncate(v);
            b[off - 0x100 + 1] = @truncate(v >> 8);
        }
    };
    f.w(buf, PB_OFF + 0x00, 0x0000); // env_seg = 0 (copy parent env)
    f.w(buf, PB_OFF + 0x02, CMDTAIL_OFF); // cmdtail off
    // PB_OFF+0x04 cmdtail seg: filled from CS at runtime
    f.w(buf, PB_OFF + 0x06, FCB_OFF); // fcb1 off
    // PB_OFF+0x08 fcb1 seg: runtime
    f.w(buf, PB_OFF + 0x0A, FCB_OFF); // fcb2 off
    // PB_OFF+0x0C fcb2 seg: runtime

    // Command tail: length byte 0, then CR.
    buf[CMDTAIL_OFF - 0x100] = 0x00;
    buf[CMDTAIL_OFF - 0x100 + 1] = 0x0D;
    // FCB region (0x154..0x163) already zeroed.
    // Path string.
    const path = "CHILD.COM";
    @memcpy(buf[PATH_OFF - 0x100 .. PATH_OFF - 0x100 + path.len], path);
    buf[PATH_OFF - 0x100 + path.len] = 0;

    return PATH_OFF - 0x100 + path.len + 1; // total image length
}

// ===========================================================================
// Harness.
// ===========================================================================

const Ctx = struct {
    m: *Machine,
    td: std.testing.TmpDir,
    alloc: std.mem.Allocator,
    /// The root (parent) PSP — the EXEC switches `current_psp` to the child, so
    /// "are we inside the child?" is `current_psp != root_psp`.
    root_psp: u16,
    fn deinit(self: *Ctx) void {
        self.td.cleanup();
        self.m.deinit();
        self.alloc.destroy(self.m);
    }
    fn inChild(self: *const Ctx) bool {
        return self.m.dos.current_psp != self.root_psp;
    }
};

fn writeHostFile(td: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    const fil = try td.dir.createFile(std.testing.io, name, .{});
    defer fil.close(std.testing.io);
    var w = fil.writer(std.testing.io, &.{});
    try w.interface.writeAll(bytes);
}

/// Boot a fresh machine with PARENT.COM + CHILD.COM mounted as C:, started at
/// PARENT.COM (the root process). The controller drives from there.
fn bootParent(alloc: std.mem.Allocator) !Ctx {
    const m = try alloc.create(Machine);
    errdefer alloc.destroy(m);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    var td = std.testing.tmpDir(.{ .iterate = true });
    errdefer td.cleanup();
    var pbuf: [256]u8 = undefined;
    const pn = buildParentCom(&pbuf);
    try writeHostFile(&td, "PARENT.COM", pbuf[0..pn]);
    try writeHostFile(&td, "CHILD.COM", &child_com);
    m.dos.mountDrive(2, td.dir, std.testing.io);
    m.dos.current_drive = 2;
    try m.bootProgram(2, "PARENT.COM", "");
    return .{ .m = m, .td = td, .alloc = alloc, .root_psp = m.dos.current_psp };
}

// ===========================================================================
// Tests.
// ===========================================================================

// The parent issues 4 INT 21h calls (AH=4A resize, 4B EXEC, 4D get-rc, 4C exit);
// the child issues 2 (AH=30 get-version, 4C exit). Total deliveries = 6. Before
// the de-nest the child's 2 were invisible (the count would have been 4).
const TOTAL_INT21: u32 = 6;

test "interrupt:0x21 breakpoint fires INSIDE the child (was zero before de-nest)" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    // A persistent interrupt bp on vector 0x21. The child issues INT 21h (AH=30,
    // then AH=4C); at those firing boundaries the kernel's `current_psp` is the
    // CHILD (it switched at EXEC). Before the de-nest the child ran nested, so the
    // scan never saw them and `current_psp` was never the child at a scan boundary.
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);

    var saw_child_int = false;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const r = ctrl.runUntilEvent(50_000_000);
        switch (r) {
            .breakpoint => {
                if (ctx.inChild()) saw_child_int = true;
            },
            .program_terminated => break,
            else => return error.WrongStopReason,
        }
    }
    try std.testing.expect(saw_child_int);
}

test "launcher-chain regression: interrupt:0x21 counts the CHILD's INT 21h calls" {
    const alloc = std.testing.allocator;

    // Count every INT 0x21 delivery across the whole run, twice. The count must be
    // NONZERO, exact (= TOTAL_INT21), and identical across runs. At least 2 of
    // those deliveries happen with `current_psp` == the child (the inner program's
    // calls) — the prior session saw ZERO of those.
    var counts: [2]u32 = .{ 0, 0 };
    var child_counts: [2]u32 = .{ 0, 0 };
    for (0..2) |run| {
        var ctx = try bootParent(alloc);
        defer ctx.deinit();
        var ctrl = Controller.init(ctx.m);
        _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const r = ctrl.runUntilEvent(50_000_000);
            switch (r) {
                .breakpoint => {
                    counts[run] += 1;
                    if (ctx.inChild()) child_counts[run] += 1;
                },
                .program_terminated => break,
                else => return error.WrongStopReason,
            }
        }
    }
    try std.testing.expectEqual(TOTAL_INT21, counts[0]);
    try std.testing.expectEqual(counts[0], counts[1]); // deterministic
    try std.testing.expectEqual(@as(u32, 2), child_counts[0]); // the child's 2 INTs
    try std.testing.expectEqual(child_counts[0], child_counts[1]);
}

test "execution_address breakpoint inside the child fires" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    // Run until the kernel has switched to the child (the child's first INT 21h,
    // AH=30): then `current_psp` is the child and we know its load segment.
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);
    var entered_child = false;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const r = ctrl.runUntilEvent(50_000_000);
        try std.testing.expect(r == .breakpoint);
        if (ctx.inChild()) {
            entered_child = true;
            break;
        }
    }
    try std.testing.expect(entered_child);

    // Arm a one-shot execution_address bp at the child's `OUT 0x80` instruction
    // (child file offset 0x10 -> CHILD_PSP:0x110) and run to it: an exec bp lands
    // INSIDE the child.
    const child_seg = ctx.m.dos.current_psp;
    const target = (@as(u32, child_seg) << 4) + 0x110;
    const eid = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = target } }, true);
    const r2 = ctrl.runUntilEvent(50_000_000);
    try std.testing.expect(r2 == .breakpoint);
    try std.testing.expectEqual(eid, r2.breakpoint.id);
    try std.testing.expectEqual(target, ctx.m.cpu.st.seg_base[@intFromEnum(Seg.cs)] + ctx.m.cpu.st.eip);
    try std.testing.expect(ctx.inChild());
}

test "memory watchpoint trips on the child's write" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    const wid = try ctrl.addBreakpoint(.{ .memory = .{
        .linear = CHILD_MEM_LINEAR,
        .len = 1,
        .access = .write,
    } }, false);
    const r = ctrl.runUntilEvent(50_000_000);
    switch (r) {
        .breakpoint => |hit| {
            try std.testing.expectEqual(wid, hit.id);
            try std.testing.expect(hit.watch != null);
            try std.testing.expectEqual(CHILD_MEM_LINEAR, hit.watch.?.addr);
            try std.testing.expectEqual(@as(u8, 0xAB), hit.watch.?.value);
            try std.testing.expect(ctx.inChild()); // the write happened in the child
        },
        else => return error.WrongStopReason,
    }
}

test "io watchpoint trips on the child's OUT" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    const wid = try ctrl.addBreakpoint(.{ .io = .{
        .port = CHILD_IO_PORT,
        .access = .write,
    } }, false);
    const r = ctrl.runUntilEvent(50_000_000);
    switch (r) {
        .breakpoint => |hit| {
            try std.testing.expectEqual(wid, hit.id);
            try std.testing.expect(hit.watch != null);
            try std.testing.expectEqual(@as(u32, CHILD_IO_PORT), hit.watch.?.addr);
            try std.testing.expectEqual(@as(u8, 0xAB), hit.watch.?.value);
            try std.testing.expect(ctx.inChild());
        },
        else => return error.WrongStopReason,
    }
}

/// Learn the cycle at which the child's memory-write watchpoint trips (a known
/// mid-child boundary), on a throwaway run.
fn learnChildWriteCycle(alloc: std.mem.Allocator) !u64 {
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);
    _ = try ctrl.addBreakpoint(.{ .memory = .{
        .linear = CHILD_MEM_LINEAR,
        .len = 1,
        .access = .write,
    } }, false);
    const r = ctrl.runUntilEvent(50_000_000);
    try std.testing.expect(r == .breakpoint);
    return r.breakpoint.at_cycle;
}

test "cycle breakpoint / run-to-cycle stops AT N inside the child (no overshoot)" {
    const alloc = std.testing.allocator;
    const write_cycle = try learnChildWriteCycle(alloc);

    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);
    const target = write_cycle - 10; // a cycle strictly inside the child
    const r = try ctrl.runToCycle(target);
    switch (r) {
        .breakpoint => |hit| {
            try std.testing.expect(hit.at_cycle >= target);
            try std.testing.expect(hit.at_cycle < write_cycle); // did NOT overshoot
            try std.testing.expect(ctx.inChild());
        },
        else => return error.WrongStopReason,
    }
}

test "cycle-cap (runUntilEvent budget) returns mid-child at a boundary" {
    const alloc = std.testing.allocator;
    const write_cycle = try learnChildWriteCycle(alloc);

    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);
    const cap = write_cycle - 10;
    const r = ctrl.runUntilEvent(cap);
    switch (r) {
        .cycle_budget_exhausted => |e| {
            try std.testing.expect(e.at_cycle >= cap);
            try std.testing.expect(e.at_cycle < write_cycle);
            try std.testing.expect(ctx.inChild());
        },
        else => return error.WrongStopReason,
    }
}

test "step / step-n descend into the child" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    // Run to the parent's EXEC INT (the AH=4B delivery — skip the AH=4A resize).
    _ = try ctrl.addBreakpoint(.{ .interrupt = .{ .vector = 0x21 } }, false);
    var at_exec = false;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const r = ctrl.runUntilEvent(50_000_000);
        try std.testing.expect(r == .breakpoint);
        if (ctx.m.cpu.st.getReg8(4) == 0x4B) {
            at_exec = true;
            break;
        }
    }
    try std.testing.expect(at_exec);
    try std.testing.expect(!ctx.inChild()); // still the parent

    // Single-stepping forward must land INSIDE the child: the EXEC return enters
    // the child via the RETF stub; a handful of steps reach the child entry.
    var reached_child = false;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const sr = ctrl.stepInstruction();
        try std.testing.expect(sr == .step_complete);
        if (ctx.inChild()) {
            reached_child = true;
            break;
        }
    }
    try std.testing.expect(reached_child);

    // step-n keeps progressing inside the child. (The persistent interrupt bp is
    // still armed, so crossing the child's own AH=4C INT may surface a breakpoint
    // stop — all three are valid "we advanced inside the child" outcomes; the
    // point is step-n descends, never errors/overshoots.)
    const cyc_before = ctx.m.cpu.st.cycles;
    const sr = ctrl.stepN(3);
    try std.testing.expect(sr == .step_complete or sr == .program_terminated or sr == .breakpoint);
    try std.testing.expect(ctx.m.cpu.st.cycles > cyc_before); // genuinely advanced
}

test "pause mid-child -> resume -> child exits -> parent resumes intact (18-byte block)" {
    const alloc = std.testing.allocator;
    var ctx = try bootParent(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);

    // Pause mid-child on its memory write.
    const wid = try ctrl.addBreakpoint(.{ .memory = .{
        .linear = CHILD_MEM_LINEAR,
        .len = 1,
        .access = .write,
    } }, true);
    var r = ctrl.runUntilEvent(50_000_000);
    try std.testing.expect(r == .breakpoint and r.breakpoint.id == wid);
    try std.testing.expect(ctx.inChild());
    const child_psp = ctx.m.dos.current_psp;
    try std.testing.expect(child_psp != ctx.root_psp);

    // Inspect (cycle-neutral) does not perturb the resume.
    const cyc_before = ctx.m.cpu.st.cycles;
    _ = ctrl.cpuSnapshot();
    try std.testing.expectEqual(cyc_before, ctx.m.cpu.st.cycles);

    // Resume: the child finishes and the parent resumes. The run ends at the
    // parent's OWN terminate; its exit code == the child's rc (7), which the parent
    // fetched via AH=4D AFTER the unwind — proving the parent resumed at INT 22
    // with the 18-byte register block restored AND that AH=4D returned the child's
    // code. (`ret_code` lives across the restore; the parent re-derives it.)
    r = ctrl.runUntilEvent(50_000_000);
    try std.testing.expect(r == .program_terminated);
    try std.testing.expectEqual(ctx.root_psp, ctx.m.dos.current_psp); // back in parent
    try std.testing.expectEqual(CHILD_EXIT_CODE, ctx.m.dos.ret_code);
}

test "snapshot mid-child ROUND-TRIPS through snapshot()/restore() into a fresh machine" {
    const alloc = std.testing.allocator;

    // --- reference run: pause mid-child, then run to termination uninterrupted ---
    var ref = try bootParent(alloc);
    defer ref.deinit();
    var rctrl = Controller.init(ref.m);
    const ref_wid = try rctrl.addBreakpoint(.{ .memory = .{
        .linear = CHILD_MEM_LINEAR,
        .len = 1,
        .access = .write,
    } }, true);
    var rr = rctrl.runUntilEvent(50_000_000);
    try std.testing.expect(rr == .breakpoint and rr.breakpoint.id == ref_wid);
    rr = rctrl.runUntilEvent(50_000_000); // continue to the end
    try std.testing.expect(rr == .program_terminated);
    const ref_snap = ref.m.snapshot();
    const ref_ram = try alloc.dupe(u8, ref.m.bus.ram);
    defer alloc.free(ref_ram);

    // --- restore run: pause at the SAME mid-child point, snapshot, restore into a
    // FRESH (init+wire+post) machine, then resume; must reach byte-identical end.
    var src = try bootParent(alloc);
    defer src.deinit();
    var sctrl = Controller.init(src.m);
    const swid = try sctrl.addBreakpoint(.{ .memory = .{
        .linear = CHILD_MEM_LINEAR,
        .len = 1,
        .access = .write,
    } }, true);
    const sr = sctrl.runUntilEvent(50_000_000);
    try std.testing.expect(sr == .breakpoint and sr.breakpoint.id == swid);
    const mid_snap = src.m.snapshot();
    const mid_ram = try alloc.dupe(u8, src.m.bus.ram);
    defer alloc.free(mid_ram);
    const mid_vram = try alloc.dupe(u8, src.m.vga.vram);
    defer alloc.free(mid_vram);

    const fresh = try alloc.create(Machine);
    defer {
        fresh.deinit();
        alloc.destroy(fresh);
    }
    try fresh.init(alloc, &.{});
    fresh.wire();
    fresh.post();
    fresh.dos.mountDrive(2, src.td.dir, std.testing.io);
    fresh.dos.current_drive = 2;
    fresh.restore(mid_snap);
    @memcpy(fresh.bus.ram, mid_ram);
    @memcpy(fresh.vga.vram, mid_vram);

    var fctrl = Controller.init(fresh);
    const fr = fctrl.runUntilEvent(50_000_000);
    try std.testing.expect(fr == .program_terminated);

    // Byte-identical end state vs the uninterrupted reference run — proving the
    // mid-EXEC host-side kernel state (current_psp/dta/ret_code/terminated) is
    // covered by the snapshot (the gap the de-nest made live).
    const fresh_snap = fresh.snapshot();
    try std.testing.expectEqual(ref_snap.cpu_state.cycles, fresh_snap.cpu_state.cycles);
    try std.testing.expectEqual(ref_snap.cpu_state.eip, fresh_snap.cpu_state.eip);
    try std.testing.expectEqual(ref_snap.dos_current_psp, fresh_snap.dos_current_psp);
    try std.testing.expectEqual(ref_snap.dos_ret_code, fresh_snap.dos_ret_code);
    try std.testing.expectEqual(ref_snap.dos_terminated, fresh_snap.dos_terminated);
    try std.testing.expectEqualSlices(u8, ref_ram, fresh.bus.ram);
}

test "two-run determinism across an EXEC (byte-identical end state + ledger)" {
    const alloc = std.testing.allocator;
    var ends: [2]struct { cycles: u64, rc: u16, psp: u16 } = undefined;
    var rams: [2][]u8 = undefined;
    for (0..2) |run| {
        var ctx = try bootParent(alloc);
        defer ctx.deinit();
        var ctrl = Controller.init(ctx.m);
        const r = ctrl.runUntilEvent(50_000_000);
        try std.testing.expect(r == .program_terminated);
        ends[run] = .{
            .cycles = ctx.m.cpu.st.cycles,
            .rc = ctx.m.dos.ret_code,
            .psp = ctx.m.dos.current_psp,
        };
        rams[run] = try alloc.dupe(u8, ctx.m.bus.ram);
    }
    defer alloc.free(rams[0]);
    defer alloc.free(rams[1]);
    try std.testing.expectEqual(ends[0].cycles, ends[1].cycles);
    try std.testing.expectEqual(ends[0].rc, ends[1].rc);
    try std.testing.expectEqual(ends[0].psp, ends[1].psp);
    try std.testing.expectEqual(CHILD_EXIT_CODE, ends[0].rc);
    try std.testing.expectEqualSlices(u8, rams[0], rams[1]);
}
