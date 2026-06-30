//! LIVE source-level debugging integration test — the FIRST wiring of the host-side
//! Borland TDS symbol overlay (`src/debug/symbols/`) to a running emulated machine.
//!
//! The per-record + black-box symbol tests parse `BB.EXE` in isolation. This one
//! proves the WHOLE chain end-to-end against a real, running guest:
//!
//!   EXE file on a mounted C: ──loader──► live PSP/load segment in guest RAM
//!        │                                          │
//!     Symbols.open(bb_exe)                     dos.current_psp
//!        └──────────── attach(psp_seg) ───────────┘
//!                          │ AddressMap (the load_para seam)
//!     source `file:line` ──► runtime-linear addr ──► breakpoint ──► run ──► STOP
//!                                                                    │
//!                          live CS:IP ──────────────────────────────┘
//!                          └─► function / source line / scope locals (name/type/storage)
//!
//! The KEY real-world validation: the relocation `map.zig` assumes — image base
//! paragraph == `psp_seg + 0x10` — is checked against where the loader ACTUALLY
//! placed `BB.EXE` (its live CS), by setting a source breakpoint with the symbol
//! layer's address and asserting the machine stops at the live CS:IP we predicted.
//!
//! Determinism (CLAUDE.md §1): a normal zdos machine test — fixed binary, fixed
//! (empty) input, no host clock/RNG; every assertion is against a fixed expected
//! value derived from `BB.C` / `docs/research/bcc3-fixtures/BB.LST`.

const std = @import("std");
const testing = std.testing;

const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const debug = @import("debug");

const Machine = machine_mod.Machine;
const Controller = debug.Controller;
const Symbols = debug.Symbols;
const TypeGraph = debug.symbols.TypeGraph;
const Tds = debug.symbols.Tds;
const Storage = debug.symbols.Storage;
const Reg32 = cpu_mod.state.Reg32;
const Seg = cpu_mod.state.Seg;

// The committed BC++ 3.1 debug-info fixture (compiled `bcc -v -ms` from BB.C). Same
// bytes the black-box parser test uses, so the parse half is already covered; here we
// run it on a real machine.
const bb_exe = @embedFile("symbols/testdata/BB.EXE");

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

fn writeHostFile(ctx: *Ctx, name: []const u8, bytes: []const u8) !void {
    const f = try ctx.td.dir.createFile(std.testing.io, name, .{});
    defer f.close(std.testing.io);
    var w = f.writer(std.testing.io, &.{});
    try w.interface.writeAll(bytes);
}

/// The live runtime-linear PC (`seg_base[CS] +% EIP`) — exactly how the breakpoint
/// engine (`breakpoints.currentLinear`) and `cpu.readLogical8` form it.
fn livePc(m: *const Machine) u32 {
    return m.cpu.st.seg_base[@intFromEnum(Seg.cs)] +% m.cpu.st.eip;
}

fn typeStr(tg: *const TypeGraph, ref: u16, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    tg.typeName(ref, &w) catch unreachable;
    return w.buffered();
}

fn localNamed(tg: *const TypeGraph, t: *const Tds, scope: usize, want: []const u8) ?debug.symbols.Local {
    for (tg.localsForScope(scope)) |l| {
        if (std.mem.eql(u8, t.name(l.name_index), want)) return l;
    }
    return null;
}

// BB.C source facts (oracle: docs/research/bcc3-fixtures/BB.LST):
//   clamp() body lines 9-12; line 9 (`r = v;`) is clamp's post-prologue first
//   statement, at image offset 0x02CB in the single small-model code segment.
const CLAMP_LINE: u16 = 9;

test "LIVE source-level debug: BB.EXE source bp -> stop -> function/line/locals (full chain)" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    // 1. Put the real BC++ debug-info program on C: and load+start it through the
    //    actual DOS loader (PSP, relocation, CS/IP/SS/SP all set as a guest sees them).
    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");

    // The LIVE PSP segment the loader recorded — the same value the runtime relocation
    // keys off (NOT a constant; read back out of DOS state).
    const psp_seg = m.dos.current_psp;
    try testing.expect(psp_seg != 0);

    // 2. Attach the symbol overlay to THIS concrete load.
    var syms = try Symbols.open(alloc, bb_exe, null);
    defer syms.deinit();
    try testing.expectEqual(Symbols.Source.tds, syms.source); // embedded TDS, full symbols
    const am = syms.attach(psp_seg);

    // 3. Source breakpoint: resolve `BB.C:9` (clamp's first statement) to a runtime
    //    linear address purely through the symbol layer, then arm a real controller
    //    breakpoint there and run the guest to it.
    const file_id = syms.index.fileId("BB.C") orelse return error.NoSourceFile;
    const bp_linear = am.runtimeAddrForLine(file_id, CLAMP_LINE) orelse return error.NoLineAddr;

    // The relocation the symbol layer applies must match the loader's REAL placement:
    // BB.EXE is small-model (one code segment, image segment 0); the loader put it at
    // CS = load_seg = psp_seg + 0x10, which is exactly map.zig's base paragraph. So the
    // predicted linear is (psp_seg + 0x10) << 4 + 0x02CB.
    try testing.expectEqual(((@as(u32, psp_seg) + 0x10) << 4) + 0x02CB, bp_linear);

    var ctrl = Controller.init(m);
    const id = try ctrl.addBreakpoint(.{ .execution_address = .{ .linear = bp_linear } }, false);
    const stop = ctrl.runUntilEvent(50_000_000);

    // The run stopped at OUR source breakpoint (not a terminal / cap / watchdog) — the
    // guest reached clamp via the C runtime startup + main()'s `clamp(300, 0, 319)`.
    try testing.expect(stop == .breakpoint);
    try testing.expectEqual(id, stop.breakpoint.id);

    // 4. "Where am I": the live CS:IP linear == the address we set, and reverse-resolves
    //    back to clamp / source line 9 through the SAME AddressMap.
    const pc = livePc(m);
    try testing.expectEqual(bp_linear, pc);

    const f = am.functionForRuntimeAddr(pc) orelse return error.NoFunction;
    try testing.expectEqualStrings("_clamp", syms.index.functionName(f).?);
    try testing.expectEqual(CLAMP_LINE, am.lineForRuntimeAddr(pc).?.line);

    // 5. Locals at the stop: resolve the innermost scope from the live PC and assert
    //    clamp's variables carry the right name / type / storage (BB.LST scope 1):
    //      v  -> auto [BP+4]   (the first arg)   int
    //      lo -> register BX (3)                 int
    //      hi -> register CX (1)                 int
    //      r  -> register DX (2)                 int
    const tg = &syms.typegraph.?;
    const t = syms.tds.?;
    const scope = syms.scopeForRuntimeAddr(am, pc) orelse return error.NoScope;
    var buf: [64]u8 = undefined;

    const v = localNamed(tg, t, scope, "v") orelse return error.NoV;
    try testing.expectEqual(Storage{ .auto = 4 }, v.storage); // [BP+4]
    try testing.expectEqualStrings("int", typeStr(tg, v.type_ref, &buf));

    const lo = localNamed(tg, t, scope, "lo") orelse return error.NoLo;
    try testing.expectEqual(Storage{ .register = 3 }, lo.storage); // BX
    try testing.expectEqualStrings("int", typeStr(tg, lo.type_ref, &buf));

    const hi = localNamed(tg, t, scope, "hi") orelse return error.NoHi;
    try testing.expectEqual(Storage{ .register = 1 }, hi.storage); // CX
    try testing.expectEqualStrings("int", typeStr(tg, hi.type_ref, &buf));

    const r = localNamed(tg, t, scope, "r") orelse return error.NoR;
    try testing.expectEqual(Storage{ .register = 2 }, r.storage); // DX
    try testing.expectEqualStrings("int", typeStr(tg, r.type_ref, &buf));

    // 6. BONUS — read the live VALUE of a BP-relative local off the guest stack via the
    //    bus. `v` is clamp's first argument; main()'s first call is `clamp(300, 0, 319)`
    //    (assigned to p.x), so at the stop v == 300. This exercises the storage location
    //    end-to-end: name -> {auto, BP+4} -> SS:[BP+offset] -> the actual bytes.
    const bp = m.cpu.st.getReg16(@intFromEnum(Reg32.ebp));
    const ss_base = m.cpu.st.seg_base[@intFromEnum(Seg.ss)];
    const v_off: i32 = v.storage.auto; // +4
    const v_linear: u32 = ss_base +% @as(u32, @bitCast(@as(i32, bp) + v_off));
    try testing.expectEqual(@as(u16, 300), m.bus.readPhys16(v_linear));
}

test "LIVE relocation: psp_seg-based AddressMap matches the loader's actual BB.EXE placement" {
    // A focused restatement of the load_para validation: independent of any source line,
    // the inverse map (live linear -> image addr) must round-trip the function entries to
    // the SAME paragraph the loader chose (CS = psp_seg + 0x10 for this small model).
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");
    const psp_seg = m.dos.current_psp;

    var syms = try Symbols.open(alloc, bb_exe, null);
    defer syms.deinit();
    const am = syms.attach(psp_seg);

    // The loader placed the single code segment at CS = psp_seg + 0x10; map.zig's
    // base_para is exactly that, so a function's image (seg 0) relocates there and the
    // live linear reverse-resolves back to the right function.
    const clamp_off = syms.index.nameToSymbol("_clamp").?.offset;
    const main_off = syms.index.nameToSymbol("_main").?.offset;
    const clamp_linear = am.toRuntimeLinear(0, clamp_off);
    const main_linear = am.toRuntimeLinear(0, main_off);

    try testing.expectEqual(((@as(u32, psp_seg) + 0x10) << 4) + clamp_off, clamp_linear);
    try testing.expectEqualStrings("_clamp", syms.index.functionName(am.functionForRuntimeAddr(clamp_linear).?).?);
    try testing.expectEqualStrings("_main", syms.index.functionName(am.functionForRuntimeAddr(main_linear).?).?);
}
