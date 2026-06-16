//! Phase 5 regression tests (M1 §5 / the rewritten Phase 5 checklist): memory
//! watchpoints via the runtime watched-page trap (modeled on Phase 4's
//! `last_delivered`). The headline test is (b) CYCLE-COST NEUTRALITY — arming a
//! watchpoint on a page the program touches must leave the run BYTE-IDENTICAL
//! (CPU state + RAM + ledger) versus an unwatched run, proving the watched
//! handler is a faithful, zero-cycle passthrough (the determinism prime
//! directive). The other tests cover (a) write/read/access firing at
//! deterministic cycles, (c) set/clear restoring the page kind + fast path +
//! alloc-freedom, and (d) passthrough returning/storing identical bytes.

const std = @import("std");
const debug = @import("debug.zig");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const bus_mod = @import("bus");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Reg32 = cpu_mod.state.Reg32;
const memmap = bus_mod.memmap;

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

// A deterministic program that touches a known data address WAT (0x3000) — a
// write then a read — then HLTs. DS=0 so linear(WAT) == WAT.
//   0500: B0 AB        MOV AL, 0xAB
//   0502: 88 06 00 30  MOV [0x3000], AL    (write to WAT)
//   0506: 8A 26 00 30  MOV AH, [0x3000]    (read  from WAT)  [8A /4 = AH]
//   050A: F4           HLT
const PROG: u32 = 0x0500;
const WAT: u32 = 0x3000;
const WRITE_INSN: u32 = 0x0502;
const READ_INSN: u32 = 0x0506;
fn loadTouchProg(m: *Machine) void {
    const b = &m.bus;
    const code = [_]u8{
        0xB0, 0xAB, // MOV AL, 0xAB
        0x88, 0x06, 0x00, 0x30, // MOV [0x3000], AL
        0x8A, 0x26, 0x00, 0x30, // MOV AH, [0x3000]
        0xF4, // HLT
    };
    for (code, 0..) |byte, i| b.writePhys8(PROG + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = PROG;
}

// ---- (a) firing at deterministic cycles -------------------------------------

test "(a) write watchpoint fires on the store, deterministically" {
    const alloc = std.testing.allocator;
    var captured: ?u64 = null;
    var run: u32 = 0;
    while (run < 2) : (run += 1) {
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadTouchProg(m);
        var ctrl = Controller.init(m);
        const id = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 1, .access = .write } }, false);

        const r = ctrl.runUntilEvent(10_000);
        switch (r) {
            .breakpoint => |hit| {
                try std.testing.expectEqual(id, hit.id);
                // Reported at the instruction boundary: after the store retired,
                // CS:IP is at the READ instruction (the next one).
                try std.testing.expectEqual(@as(u32, READ_INSN), m.cpu.st.eip);
                // The store landed (faithful passthrough).
                try std.testing.expectEqual(@as(u8, 0xAB), m.bus.peekPhys8(WAT));
                // The hit breadcrumb records the write to WAT.
                try std.testing.expectEqual(@as(u32, WAT), m.bus.last_mem_watch.linear);
                try std.testing.expectEqual(bus_mod.WatchAccess.write, m.bus.last_mem_watch.access);
                if (captured) |c| try std.testing.expectEqual(c, hit.at_cycle) else captured = hit.at_cycle;
            },
            else => return error.WrongStopReason,
        }
    }
}

test "(a) read watchpoint ignores the store, fires on the load" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadTouchProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 1, .access = .read } }, false);

    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => {
            // The store (a write) must NOT have fired a read watch — we are past
            // the load now, so CS:IP is at the HLT (READ_INSN + 4).
            try std.testing.expectEqual(@as(u32, READ_INSN + 4), m.cpu.st.eip);
            try std.testing.expectEqual(bus_mod.WatchAccess.read, m.bus.last_mem_watch.access);
            // The load read back the stored byte into AH.
            try std.testing.expectEqual(@as(u8, 0xAB), m.cpu.st.getReg8(4));
        },
        else => return error.WrongStopReason,
    }
}

test "(a) access watchpoint catches the FIRST touch (the store)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadTouchProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 1, .access = .access } }, false);

    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => {
            // access = read|write: the first touch is the store, so we stop right
            // after it (CS:IP at the read instruction).
            try std.testing.expectEqual(@as(u32, READ_INSN), m.cpu.st.eip);
            try std.testing.expectEqual(bus_mod.WatchAccess.write, m.bus.last_mem_watch.access);
        },
        else => return error.WrongStopReason,
    }
}

test "(a) a watch OUTSIDE the touched range never fires" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadTouchProg(m);
    var ctrl = Controller.init(m);
    // Watch a byte the program never touches (still on the same page so the page
    // is `.watched` and every byte is checked — the range-check must reject it).
    _ = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT + 1, .len = 1, .access = .access } }, false);
    const r = ctrl.runUntilEvent(10_000);
    // The program runs to its permanent HLT without the watch ever matching.
    try std.testing.expectEqual(@as(std.meta.Tag(debug.StopReason), .halted_forever), std.meta.activeTag(r));
}

// ---- (b) CYCLE-COST NEUTRALITY (the determinism lock) ------------------------

test "(b) arming a watchpoint is byte-identical to an unwatched run at cycle N" {
    const alloc = std.testing.allocator;
    const N: u64 = 6; // a couple of instructions in — past the store + load span

    // Unwatched reference run.
    const mu = try makeMachine(alloc);
    defer destroy(alloc, mu);
    loadTouchProg(mu);
    var cu = Controller.init(mu);
    _ = try cu.runToCycle(N);
    const ref_snap = mu.snapshot();
    const ref_ram = try alloc.dupe(u8, mu.bus.ram);
    defer alloc.free(ref_ram);

    // Watched run: arm an `access` watch on the page the program touches, then run
    // to the SAME cycle N (a cap, NOT a stop — the watch is a persistent bp, but
    // we run with runToCycle's one-shot cycle bp at N which has the lowest scan
    // precedence only by id; to guarantee we stop AT N regardless of a watch hit,
    // we DISABLE the memory bp's stop by removing it from the SET but keeping the
    // watch armed on the bus). Simplest faithful approach: arm the watch directly
    // on the bus (no breakpoint), so it records hits but never stops the run.
    const mw = try makeMachine(alloc);
    defer destroy(alloc, mw);
    loadTouchProg(mw);
    const wid = try mw.bus.setWatch(.{ .linear = WAT, .len = 1, .access = .access });
    var cw = Controller.init(mw);
    _ = try cw.runToCycle(N);
    const watched_snap = mw.snapshot();

    // The watch fired (it recorded a hit) — proving the page was actually on the
    // slow path, not silently skipped.
    try std.testing.expect(mw.bus.last_mem_watch.seq > 0);

    // BYTE-IDENTICAL CPU state + ledger + RAM. The cpu_state byte-compare includes
    // the cycle counter, so this also pins the ledger.
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ref_snap.cpu_state),
        std.mem.asBytes(&watched_snap.cpu_state),
    );
    try std.testing.expectEqualSlices(u8, ref_ram, mw.bus.ram);

    // Clearing the watch restores the page; the run state is unaffected.
    mw.bus.clearWatch(wid);
    try std.testing.expectEqual(memmap.PageKind.ram, mw.bus.page_kind[memmap.pageIndex(WAT)]);
}

// ---- (c) set/clear restores page kind + fast path; alloc-free ---------------

test "(c) setWatch promotes the page to .watched; clearWatch restores it exactly" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    const page = memmap.pageIndex(WAT);
    try std.testing.expectEqual(memmap.PageKind.ram, m.bus.page_kind[page]);

    const id0 = try m.bus.setWatch(.{ .linear = WAT, .len = 1, .access = .write });
    try std.testing.expectEqual(memmap.PageKind.watched, m.bus.page_kind[page]);
    try std.testing.expectEqual(memmap.PageKind.ram, m.bus.watch_prior[page]); // prior remembered

    // A second overlapping watch on the same page: ref count, still .watched.
    const id1 = try m.bus.setWatch(.{ .linear = WAT + 8, .len = 1, .access = .read });
    try std.testing.expectEqual(memmap.PageKind.watched, m.bus.page_kind[page]);

    // Clearing one watch keeps the page watched (the other still covers it).
    m.bus.clearWatch(id0);
    try std.testing.expectEqual(memmap.PageKind.watched, m.bus.page_kind[page]);
    // Clearing the LAST restores the prior kind exactly (fast path back).
    m.bus.clearWatch(id1);
    try std.testing.expectEqual(memmap.PageKind.ram, m.bus.page_kind[page]);
}

test "(c) removeBreakpoint(memory) clears the bus watch" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    const page = memmap.pageIndex(WAT);
    var ctrl = Controller.init(m);
    const id = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 4, .access = .access } }, false);
    try std.testing.expectEqual(memmap.PageKind.watched, m.bus.page_kind[page]);
    try ctrl.removeBreakpoint(id);
    // The page reverts and the watch slot frees.
    try std.testing.expectEqual(memmap.PageKind.ram, m.bus.page_kind[page]);
    try std.testing.expect(!m.bus.watch_used[0]);
}

test "(c) the watch run path is alloc-free (counting allocator)" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const m = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(m);
    try m.init(counting.allocator(), &.{});
    m.wire();
    defer m.deinit();
    loadTouchProg(m);

    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 1, .access = .access } }, false);
    const after_setup = counting.count;
    _ = ctrl.runUntilEvent(10_000);
    try std.testing.expectEqual(after_setup, counting.count); // zero alloc on the run
}

// ---- (d) passthrough returns/stores identical bytes -------------------------

test "(d) watched-page passthrough is byte-identical to the normal path" {
    const alloc = std.testing.allocator;

    // Reference: plain bus writes/reads, no watch.
    const mref = try makeMachine(alloc);
    defer destroy(alloc, mref);
    mref.bus.writePhys8(WAT, 0x11);
    mref.bus.writePhys16(WAT + 1, 0x2233);
    mref.bus.writePhys32(WAT + 3, 0x44556677);
    const r8 = mref.bus.readPhys8(WAT);
    const r16 = mref.bus.readPhys16(WAT + 1);
    const r32 = mref.bus.readPhys32(WAT + 3);

    // Watched: arm a watch over the whole touched span, then the SAME ops must
    // return/store identical bytes (the watch only adds a side-channel breadcrumb).
    const mw = try makeMachine(alloc);
    defer destroy(alloc, mw);
    _ = try mw.bus.setWatch(.{ .linear = WAT, .len = 16, .access = .access });
    mw.bus.writePhys8(WAT, 0x11);
    mw.bus.writePhys16(WAT + 1, 0x2233);
    mw.bus.writePhys32(WAT + 3, 0x44556677);
    try std.testing.expectEqual(r8, mw.bus.readPhys8(WAT));
    try std.testing.expectEqual(r16, mw.bus.readPhys16(WAT + 1));
    try std.testing.expectEqual(r32, mw.bus.readPhys32(WAT + 3));

    // The slab bytes themselves match the unwatched slab exactly.
    try std.testing.expectEqualSlices(u8, mref.bus.ram[WAT .. WAT + 16], mw.bus.ram[WAT .. WAT + 16]);
    // And the watch actually fired (it was on the slow path, not skipped).
    try std.testing.expect(mw.bus.last_mem_watch.seq > 0);
}

test "(d) a wide access only PARTLY covered by a watch still fires" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    // Watch only the high byte of a 4-byte store.
    _ = try m.bus.setWatch(.{ .linear = WAT + 3, .len = 1, .access = .write });
    m.bus.writePhys32(WAT, 0xAABBCCDD); // touches WAT..WAT+3
    try std.testing.expect(m.bus.last_mem_watch.seq > 0);
    try std.testing.expectEqual(@as(u32, WAT + 3), m.bus.last_mem_watch.linear);
}

// ---- Phase 2: the StopReason carries the watch access detail -----------------

test "Phase2 a memory write watchpoint stop carries {linear, .write, value}" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadTouchProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .memory = .{ .linear = WAT, .len = 1, .access = .write } }, false);

    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => |hit| {
            const w = hit.watch orelse return error.MissingWatchDetail;
            try std.testing.expectEqual(@as(u32, WAT), w.addr);
            try std.testing.expectEqual(debug.AccessKind.write, w.access);
            // `value` is the peek of WAT at the boundary == the just-written byte.
            try std.testing.expectEqual(@as(u8, 0xAB), w.value);
            try std.testing.expectEqual(@as(@TypeOf(w.kind), .memory), w.kind);
        },
        else => return error.WrongStopReason,
    }
}

test "Phase2 a non-memory breakpoint stop carries watch=null" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadTouchProg(m);
    var ctrl = Controller.init(m);
    // An execution-address bp at the HLT — not a watchpoint, so no access detail.
    _ = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = 0x050A } }, false);
    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => |hit| try std.testing.expect(hit.watch == null),
        else => return error.WrongStopReason,
    }
}

// ---- Phase 3: I/O-port watchpoints (the `io` breakpoint kind) ----------------

// MOV AL,0x5A ; OUT 0x80,AL ; IN AL,0x80 ; HLT. Port 0x80 (POST) — its mapping
// does not matter: the watch records on the port ACCESS, mapped or not.
const IOPROG: u32 = 0x0500;
const IOPORT: u16 = 0x80;
fn loadPortProg(m: *Machine) void {
    const b = &m.bus;
    const code = [_]u8{
        0xB0, 0x5A, // MOV AL, 0x5A
        0xE6, 0x80, // OUT 0x80, AL
        0xE4, 0x80, // IN  AL, 0x80
        0xF4, // HLT
    };
    for (code, 0..) |byte, i| b.writePhys8(IOPROG + @as(u32, @intCast(i)), byte);
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ds, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = IOPROG;
}

test "Phase3 an io WRITE watch fires on OUT with {port, .write, value}" {
    const alloc = std.testing.allocator;
    var captured: ?u64 = null;
    var run: u32 = 0;
    while (run < 2) : (run += 1) { // determinism: same cycle both runs
        const m = try makeMachine(alloc);
        defer destroy(alloc, m);
        loadPortProg(m);
        var ctrl = Controller.init(m);
        const id = try ctrl.addBreakpoint(.{ .io = .{ .port = IOPORT, .access = .write } }, false);
        const r = ctrl.runUntilEvent(10_000);
        switch (r) {
            .breakpoint => |hit| {
                try std.testing.expectEqual(id, hit.id);
                // Stopped right after the OUT (CS:IP at the IN instruction).
                try std.testing.expectEqual(@as(u32, 0x0504), m.cpu.st.eip);
                const w = hit.watch orelse return error.MissingWatchDetail;
                try std.testing.expectEqual(@as(u32, IOPORT), w.addr);
                try std.testing.expectEqual(debug.AccessKind.write, w.access);
                try std.testing.expectEqual(@as(u8, 0x5A), w.value); // the OUT byte
                try std.testing.expectEqual(@as(@TypeOf(w.kind), .io), w.kind);
                if (captured) |c| try std.testing.expectEqual(c, hit.at_cycle) else captured = hit.at_cycle;
            },
            else => return error.WrongStopReason,
        }
    }
}

test "Phase3 an io READ watch ignores the OUT, fires on IN" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    loadPortProg(m);
    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .io = .{ .port = IOPORT, .access = .read } }, false);
    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => |hit| {
            // Past the IN now: CS:IP at the HLT (0x0506).
            try std.testing.expectEqual(@as(u32, 0x0506), m.cpu.st.eip);
            const w = hit.watch orelse return error.MissingWatchDetail;
            try std.testing.expectEqual(debug.AccessKind.read, w.access);
            try std.testing.expectEqual(@as(u32, IOPORT), w.addr);
        },
        else => return error.WrongStopReason,
    }
}

test "Phase3 arming an io watch is byte-identical to an unwatched run (cycle-neutral)" {
    const alloc = std.testing.allocator;

    // Unwatched reference: step exactly MOV ; OUT ; IN (3 instructions).
    const mu = try makeMachine(alloc);
    defer destroy(alloc, mu);
    loadPortProg(mu);
    var cu = Controller.init(mu);
    _ = cu.stepN(3);
    const ref_snap = mu.snapshot();

    // Watched: arm a bus port watch directly (records hits, never stops), same 3 steps.
    const mw = try makeMachine(alloc);
    defer destroy(alloc, mw);
    loadPortProg(mw);
    _ = try mw.bus.setPortWatch(.{ .port = IOPORT, .access = .access });
    var cw = Controller.init(mw);
    _ = cw.stepN(3);

    try std.testing.expect(mw.bus.last_io_watch.seq > 0); // it actually fired
    // Byte-identical CPU state + ledger: a port watch charges zero cycles.
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&ref_snap.cpu_state),
        std.mem.asBytes(&mw.snapshot().cpu_state),
    );
}

test "Phase3 an io watch on a real device port still dispatches the device (passthrough)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    const b = &m.bus;
    // OUT 0x21, 0x55 sets the master PIC interrupt mask. Watch the port, then run.
    b.writePhys8(0x0500, 0xB0);
    b.writePhys8(0x0501, 0x55); // MOV AL, 0x55
    b.writePhys8(0x0502, 0xE6);
    b.writePhys8(0x0503, 0x21); // OUT 0x21, AL
    b.writePhys8(0x0504, 0xF4); // HLT
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0x7000);
    m.cpu.st.eip = 0x0500;

    var ctrl = Controller.init(m);
    _ = try ctrl.addBreakpoint(.{ .io = .{ .port = 0x21, .access = .write } }, false);
    const r = ctrl.runUntilEvent(10_000);
    switch (r) {
        .breakpoint => |hit| {
            const w = hit.watch orelse return error.MissingWatchDetail;
            try std.testing.expectEqual(@as(u8, 0x55), w.value);
            // The device ALSO saw the write (faithful passthrough): the PIC mask is set.
            try std.testing.expectEqual(@as(u8, 0x55), m.pic.master.imr);
        },
        else => return error.WrongStopReason,
    }
}

test "Phase3 removeBreakpoint(io) clears the port watch + disarms the gate" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer destroy(alloc, m);
    var ctrl = Controller.init(m);
    const id = try ctrl.addBreakpoint(.{ .io = .{ .port = IOPORT, .access = .access } }, false);
    try std.testing.expect(m.bus.any_port_watch_armed);
    try ctrl.removeBreakpoint(id);
    try std.testing.expect(!m.bus.any_port_watch_armed); // gate back to free
    try std.testing.expect(!m.bus.port_watch_used[0]);
}

/// Counting allocator (mirrors controller_test.zig): records every alloc/free so
/// the watch run path can be asserted alloc-free.
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
