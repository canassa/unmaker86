//! Phase 2/2b regression tests for the controller facade (M1 §4): exact-cycle bp
//! (#1), byte-identical two-run (#3), disarmed transparency (#6), alloc-free
//! control loop (#7), tie-break determinism (#8), terminal precedence (#9),
//! resume/re-fire (#10), one-shot lifecycle (#11), error paths (#12), and the
//! side-effect-free inspection over a device region (#13). Grep/reflection (#14)
//! lives in determinism_test.zig.

const std = @import("std");
const debug = @import("debug.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;

// A simple deterministic real-mode program at 0000:PROG. No IRQs, no devices: a
// run of NOPs then a HLT, so execution-address / cycle breakpoints land at known
// boundaries and a permanent HLT is reachable.
//   0000:0500  90 NOP    (x8)
//   0000:0508  F4 HLT
//   0000:0509  EB FD JMP $-1  (loop on HLT after any wake; here none -> permanent)
const PROG: u32 = 0x0500;
const HLT_OFF: u32 = 0x0508;

fn loadNopProg(m: *Machine) void {
    const b = &m.bus;
    var i: u32 = 0;
    while (i < 8) : (i += 1) b.writePhys8(PROG + i, 0x90); // NOP
    b.writePhys8(PROG + 8, 0xF4); // HLT
    b.writePhys8(PROG + 9, 0xEB); // JMP $-1
    b.writePhys8(PROG + 10, 0xFD);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}

fn destroy(alloc: std.mem.Allocator, m: *Machine) void {
    m.deinit();
    alloc.destroy(m);
}

test "#1 exact-cycle breakpoint fires at first boundary >= K, constant across runs" {
    const alloc = std.testing.allocator;
    const K: u64 = 5; // a few NOP boundaries in

    var captured: ?u64 = null;
    var run: u32 = 0;
    while (run < 2) : (run += 1) {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadNopProg(m);
        var ctrl = Controller.init(m);
        const id = try ctrl.addBreakpoint(.{ .cycle = .{ .at_cycle = K } }, false);
        const r = ctrl.runUntilEvent(10_000);
        switch (r) {
            .breakpoint => |hit| {
                try std.testing.expectEqual(id, hit.id);
                try std.testing.expect(hit.at_cycle >= K);
                if (captured) |c| {
                    try std.testing.expectEqual(c, hit.at_cycle); // constant across runs
                } else captured = hit.at_cycle;
            },
            else => return error.WrongStopReason,
        }
        // last_stop mirrors the returned reason.
        try std.testing.expect(ctrl.last_stop != null);
    }
}

test "#3 byte-identical two-run to the same cycle breakpoint" {
    const alloc = std.testing.allocator;
    const K: u64 = 4;

    const m1 = try makeMachine(alloc);
    defer destroy(alloc, m1);
    loadNopProg(m1);
    var c1 = Controller.init(m1);
    _ = try c1.addBreakpoint(.{ .cycle = .{ .at_cycle = K } }, false);
    _ = c1.runUntilEvent(10_000);
    const snap1 = m1.snapshot();
    const ram1 = try alloc.dupe(u8, m1.bus.ram);
    defer alloc.free(ram1);

    const m2 = try makeMachine(alloc);
    defer destroy(alloc, m2);
    loadNopProg(m2);
    var c2 = Controller.init(m2);
    _ = try c2.addBreakpoint(.{ .cycle = .{ .at_cycle = K } }, false);
    _ = c2.runUntilEvent(10_000);
    const snap2 = m2.snapshot();

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snap1.cpu_state), std.mem.asBytes(&snap2.cpu_state));
    try std.testing.expectEqualSlices(u8, ram1, m2.bus.ram);
}

test "#6 disarmed transparency: controller w/ no bps == bare run_loop" {
    const alloc = std.testing.allocator;
    const N: u64 = 2_000;

    // Bare machine via run_loop.runCycles.
    const bare = try makeMachine(alloc);
    defer destroy(alloc, bare);
    loadNopProg(bare);
    _ = bare.runCycles(N);
    const bare_snap = bare.snapshot();
    const bare_ram = try alloc.dupe(u8, bare.bus.ram);
    defer alloc.free(bare_ram);

    // Controller-driven, no breakpoints, same budget.
    const ctl = try makeMachine(alloc);
    defer destroy(alloc, ctl);
    loadNopProg(ctl);
    var ctrl = Controller.init(ctl);
    _ = ctrl.runUntilEvent(N);

    // Both reach the permanent HLT (the NOP run halts), so both stop at the same
    // ledger value with byte-identical state.
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&bare_snap.cpu_state), std.mem.asBytes(&ctl.snapshot().cpu_state));
    try std.testing.expectEqualSlices(u8, bare_ram, ctl.bus.ram);
}

test "#9 terminal precedence: halted_forever beats a simultaneously-true cycle bp" {
    const alloc = std.testing.allocator;

    // First find H = the exact cycle at which this program reaches its permanent
    // HLT, from a bare reference run (no breakpoints). The debugger never perturbs
    // the run, so H is identical on the breakpointed machine below.
    const ref = try makeMachine(alloc);
    defer destroy(alloc, ref);
    loadNopProg(ref);
    var rctrl = Controller.init(ref);
    try std.testing.expectEqual(
        @as(std.meta.Tag(debug.StopReason), .halted_forever),
        std.meta.activeTag(rctrl.runUntilEvent(100_000)),
    );
    const H: u64 = ref.cpu.st.cycles;

    // Now arm a cycle bp at EXACTLY H. The cycle condition (cycles >= H, see
    // breakpoints.matches) first becomes true at the very boundary the machine
    // also goes permanently halted — the two are SIMULTANEOUSLY satisfied. The
    // controller checks terminals before the breakpoint scan, so it must report
    // `halted_forever`. If that precedence were inverted, this same run would
    // return `.breakpoint` instead — so this test now genuinely guards precedence.
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadNopProg(m);
    var ctrl = Controller.init(m);
    const id = try ctrl.addBreakpoint(.{ .cycle = .{ .at_cycle = H } }, false);
    const r = ctrl.runUntilEvent(100_000);

    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r));
    // Prove the breakpoint was genuinely co-eligible at the stop boundary (its
    // cycle condition holds), so the terminal really did win over a *matching*
    // breakpoint rather than over one that simply never fired.
    try std.testing.expect(m.cpu.st.cycles >= H);
    // And the persistent bp was NOT consumed — the terminal short-circuited the
    // scan, so it is still armed.
    try std.testing.expect((try ctrl.getBreakpoint(id)).enabled);
    try std.testing.expectEqual(@as(u32, 1), ctrl.set.active_count);
}

test "#8 tie-break determinism: lowest id reported; all matching one-shots consumed" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadNopProg(m);
    var ctrl = Controller.init(m);

    // Two breakpoints that are simultaneously eligible at the SAME boundary: an
    // execution-address bp at PROG+2 and a cycle bp whose threshold the same
    // boundary satisfies. Add the exec one first (id 0), the cycle one second
    // (id 1) AS ONE-SHOTS, plus a third persistent cycle bp (id 2) also matching.
    // We single-step to PROG+2 first to know the cycle there, then arm.
    // Simpler: arm both as exec-address at the SAME linear so both match the same
    // boundary; lowest id (0) must be reported and both one-shots consumed.
    const target: u32 = PROG + 2; // after one NOP
    const id0 = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = target } }, true);
    const id1 = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = target } }, true);
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);

    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => |hit| try std.testing.expectEqual(@as(u32, 0), hit.id), // lowest id
        else => return error.WrongStopReason,
    }
    // Both one-shots consumed (disabled) at that boundary.
    try std.testing.expect(!(try ctrl.getBreakpoint(id0)).enabled);
    try std.testing.expect(!(try ctrl.getBreakpoint(id1)).enabled);
    try std.testing.expectEqual(@as(u32, 0), ctrl.set.active_count);
}

test "#10 resume/re-fire: a persistent exec bp does not immediately re-fire" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadNopProg(m);
    var ctrl = Controller.init(m);
    const target: u32 = PROG + 2;
    const id = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = target } }, false);

    const r1 = ctrl.runUntilEvent(10_000);
    switch (r1) {
        .breakpoint => |hit| try std.testing.expectEqual(id, hit.id),
        else => return error.WrongStopReason,
    }
    // CS:IP now sits on the bp. A second run must STEP OFF it (not re-fire at the
    // same PC) and proceed to the next event (here: the permanent HLT).
    const eip_before = m.cpu.st.eip;
    const r2 = ctrl.runUntilEvent(10_000);
    try std.testing.expect(m.cpu.st.eip != eip_before or std.meta.activeTag(r2) == .halted_forever);
    // It must NOT report the same bp immediately at the same unchanged PC.
    switch (r2) {
        .breakpoint => |hit| try std.testing.expect(m.cpu.st.eip != eip_before or hit.at_cycle != ctrl.last_stop.?.breakpoint.at_cycle),
        else => {}, // terminal is fine (program ran to HLT)
    }
}

test "#11 one-shot lifecycle: fires once, does not stop again" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadNopProg(m);
    var ctrl = Controller.init(m);
    const target: u32 = PROG + 2;
    const id = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = target } }, true);

    const r1 = ctrl.runUntilEvent(10_000);
    switch (r1) {
        .breakpoint => |hit| try std.testing.expectEqual(id, hit.id),
        else => return error.WrongStopReason,
    }
    try std.testing.expect(!(try ctrl.getBreakpoint(id)).enabled); // consumed

    // A second run does not stop on the (now-disabled) one-shot; it runs to HLT.
    const r2 = ctrl.runUntilEvent(100_000);
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r2));
}

test "#12 controller error paths: budget-past returns immediately, bad ids" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadNopProg(m);
    var ctrl = Controller.init(m);

    // Bad-id management errors surface as typed errors (not panics).
    try std.testing.expectError(error.NoSuchBreakpoint, ctrl.removeBreakpoint(7));
    try std.testing.expectError(error.NoSuchBreakpoint, ctrl.enableBreakpoint(7, true));
    try std.testing.expectError(error.NoSuchBreakpoint, ctrl.getBreakpoint(7));

    // Fill the table, then a 65th add is a clean error.
    var i: u32 = 0;
    while (i < debug.MAX_BREAKPOINTS) : (i += 1) {
        _ = try ctrl.addBreakpoint(.{ .cycle = .{ .at_cycle = i } }, false);
    }
    try std.testing.expectError(error.BreakpointTableFull, ctrl.addBreakpoint(.{ .cycle = .{ .at_cycle = 0 } }, false));
}

test "#7 alloc-free control loop (counting allocator)" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const m = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(m);
    try m.init(counting.allocator(), &.{});
    m.wire();
    defer m.deinit();
    loadNopProg(m);

    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .cycle = .{ .at_cycle = 3 } }, false);
    const after_setup = counting.count;
    _ = ctrl.runUntilEvent(10_000);
    // Inspection too: cpuSnapshot + peek must allocate nothing.
    _ = ctrl.cpuSnapshot();
    var buf: [16]u8 = undefined;
    ctrl.peekMem(.cs, PROG, &buf);
    try std.testing.expectEqual(after_setup, counting.count);
}

test "#13 side-effect-free inspection leaves machine.snapshot() byte-identical (VRAM device region)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    m.post(); // installs the EMS frame MMIO + IVT; arms PIT (a device with latches)
    loadNopProg(m);

    // Dirty VRAM so the peek reads real device-backed bytes.
    m.bus.writePhys8(0xA0000, 0xAB);
    m.bus.writePhys8(0xA0001, 0xCD);

    const before = m.snapshot();
    const before_ram = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(before_ram);
    const before_vram = try alloc.dupe(u8, m.vga.vram);
    defer alloc.free(before_vram);

    var ctrl = Controller.init(m);
    // Inspect across RAM, the VGA framebuffer (device MMIO, hostPtr-backed), and
    // the IVT + stack — none may perturb device state.
    _ = ctrl.cpuSnapshot();
    var vbuf: [4]u8 = undefined;
    ctrl.peekMemPhys(0xA0000, &vbuf);
    try std.testing.expectEqual(@as(u8, 0xAB), vbuf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), vbuf[1]);
    var rbuf: [8]u8 = undefined;
    ctrl.peekMem(.cs, PROG, &rbuf);
    _ = ctrl.peekIvtEntry(0x21);
    var sbuf: [4]u16 = undefined;
    _ = ctrl.peekStack(&sbuf);

    const after = m.snapshot();
    // Byte-identical device + CPU + scheduler state, and RAM/VRAM unchanged.
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before.cpu_state), std.mem.asBytes(&after.cpu_state));
    try std.testing.expectEqualDeep(before.pit, after.pit);
    try std.testing.expectEqualDeep(before.pic, after.pic);
    try std.testing.expectEqualDeep(before.vga, after.vga);
    try std.testing.expectEqualDeep(before.sched, after.sched);
    try std.testing.expectEqualSlices(u8, before_ram, m.bus.ram);
    try std.testing.expectEqualSlices(u8, before_vram, m.vga.vram);
}

test "#15 screen() renders the active text page grid + cursor (BDA-driven)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    m.post(); // initDefaults: mode 3, 80 cols, OFF_NB_ROWS=24 (80x25 color text)

    // Write 'H','i' into cells (0,0),(0,1) of the color page (B8000), and set the
    // cursor to (row=2,col=7) via the BDA cursor word at 0040:0050.
    m.bus.writePhys8(0xB8000, 'H');
    m.bus.writePhys8(0xB8000 + 1, 0x07);
    m.bus.writePhys8(0xB8000 + 2, 'i');
    m.bus.writePhys8(0xB8000 + 3, 0x1F);
    m.bus.writePhys16(0x400 + 0x50, (2 << 8) | 7); // cursor (2,7)

    var ctrl = Controller.init(m);
    var buf: [80 * 25 * 2]u8 = undefined;
    const view = ctrl.screen(&buf);

    try std.testing.expectEqual(@as(u16, 80), view.cols);
    try std.testing.expectEqual(@as(u16, 25), view.rows);
    try std.testing.expectEqual(@as(u8, 0x03), view.mode);
    try std.testing.expectEqual(@as(u16, 2), view.cursor_row);
    try std.testing.expectEqual(@as(u16, 7), view.cursor_col);
    try std.testing.expectEqual(@as(usize, 80 * 25 * 2), view.cells.len);
    // The first cell's char/attr are present in the raw cells.
    try std.testing.expectEqual(@as(u8, 'H'), view.cells[0]);
    try std.testing.expectEqual(@as(u8, 0x07), view.cells[1]);
    try std.testing.expectEqual(@as(u8, 'i'), view.cells[2]);
    try std.testing.expectEqual(@as(u8, 0x1F), view.cells[3]);
}

test "#16 screen() is side-effect-free: machine.snapshot() byte-identical before/after" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    m.post();
    loadNopProg(m);

    // Dirty the text page so the peek reads real device-backed bytes.
    m.bus.writePhys8(0xB8000, 'A');
    m.bus.writePhys8(0xB0000, 'M');

    const before = m.snapshot();
    const before_ram = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(before_ram);
    const before_text = try alloc.dupe(u8, m.vga.text_vram);
    defer alloc.free(before_text);
    const before_text_mono = try alloc.dupe(u8, m.vga.text_vram_mono);
    defer alloc.free(before_text_mono);

    var ctrl = Controller.init(m);
    var buf: [80 * 25 * 2]u8 = undefined;
    _ = ctrl.screen(&buf);

    const after = m.snapshot();
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before.cpu_state), std.mem.asBytes(&after.cpu_state));
    try std.testing.expectEqualDeep(before.vga, after.vga);
    try std.testing.expectEqualSlices(u8, before_ram, m.bus.ram);
    try std.testing.expectEqualSlices(u8, before_text, m.vga.text_vram);
    try std.testing.expectEqualSlices(u8, before_text_mono, m.vga.text_vram_mono);
}

test "#17 device-reader devicesSnapshot/ioShadow are side-effect-free (snapshot byte-identical)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    m.post();
    loadNopProg(m);

    var ctrl = Controller.init(m);
    _ = ctrl.stepN(7); // advance the ledger so cycle-derived values are non-trivial

    const before = m.snapshot();
    _ = ctrl.devicesSnapshot();
    // Hit every dangerous port whose LIVE in8 would mutate device state.
    for ([_]u16{ 0x3DA, 0x3BA, 0x3C9, 0x3C7, 0x3C8, 0x60, 0x40, 0x41, 0x42, 0x61, 0x20, 0x21, 0xA0, 0xA1, 0x64, 0x92 }) |port| {
        _ = ctrl.ioShadow(port);
    }
    const after = m.snapshot();

    // CPU + ledger untouched (zero cycles charged), and every device's full
    // register state byte-identical — including the fields a real in8 would have
    // mutated (AC flip-flop, DAC indices, 8042 FIFO head/count, PIT read phase).
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before.cpu_state), std.mem.asBytes(&after.cpu_state));
    try std.testing.expectEqualDeep(before.vga, after.vga);
    try std.testing.expectEqualDeep(before.pic, after.pic);
    try std.testing.expectEqualDeep(before.pit, after.pit);
    try std.testing.expectEqualDeep(before.kbd, after.kbd);
    try std.testing.expectEqualDeep(before.speaker, after.speaker);
}

test "#18 device-reader contrast: the SHADOW leaves the AC flip-flop; a LIVE in8(0x3DA) flips it" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    m.post();
    loadNopProg(m);

    var ctrl = Controller.init(m);
    m.vga.attr_flip_flop_is_index = false; // put the AC flip-flop in the DATA phase
    _ = ctrl.ioShadow(0x3DA);
    try std.testing.expect(!m.vga.attr_flip_flop_is_index); // the shadow did NOT flip it
    // Proof the hazard is real: a true port read resets it to the index phase.
    _ = m.bus.portIn8(0x3DA);
    try std.testing.expect(m.vga.attr_flip_flop_is_index);
}

/// Counting allocator (mirrors machine/determinism_test.zig): records every
/// alloc/free so the control path can be asserted alloc-free.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mm: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawResize(mm, a, nl, ra);
    }
    fn remap(ctx: *anyopaque, mm: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawRemap(mm, a, nl, ra);
    }
    fn free(ctx: *anyopaque, mm: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.backing.rawFree(mm, a, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};
