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

// ===========================================================================
// M-S1 MVP — the SAME chain, now driven entirely through the protocol-neutral
// `SourceDebugger` core: attach-on-load → source breakpoint → run-to-it →
// pcLocation (function + line) → source-line step → stepOut. (debug-core-plan.md §9.)
// ===========================================================================

const SourceDebugger = debug.SourceDebugger;
const core = debug.core;

test "M-S1 core: attach -> source bp -> cont -> pcLocation -> stepLine -> stepOut (BB.EXE)" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");
    const psp_seg = m.dos.current_psp;

    var ctrl = Controller.init(m);
    var sd = SourceDebugger.init(alloc, &ctrl);
    defer sd.deinit();

    // 1. Attach-on-load: build + relocate the overlay for THIS concrete load.
    sd.attachOnLoad(bb_exe, null, psp_seg);

    // 2. Source breakpoint `BB.C:9` resolves through the core to the proof's invariant
    //    linear ((psp+0x10)<<4)+0x02CB — verified, with the spec retained.
    const rb = try sd.setBreakpoint(.{ .source = .{ .file = "BB.C", .line = CLAMP_LINE } });
    try testing.expect(rb.verified);
    try testing.expectEqual(((@as(u32, psp_seg) + 0x10) << 4) + 0x02CB, rb.resolved.?.linear);
    try testing.expectEqual(@as(u32, CLAMP_LINE), rb.source.?.line);

    // 3. Blocking `cont` (run to the next event), projected through the core's ONE
    //    StopReason→StopKind seam. The guest reaches clamp via C0 startup + main().
    const stop = sd.projectStop(ctrl.runUntilEvent(50_000_000));
    try testing.expectEqual(core.StopKind.breakpoint, stop.kind.?);
    try testing.expectEqual(rb.id, stop.bp_id.?);

    // 4. pcLocation reverse-resolves the live CS:IP to function + source line.
    const where = try sd.pcLocation();
    try testing.expectEqualStrings("_clamp", where.function.?);
    try testing.expectEqual(@as(u32, CLAMP_LINE), where.source.?.line);
    try testing.expectEqualStrings("BB.C", where.source.?.path);

    // 5. One source-line step: stays in _clamp (same frame) and advances off line 9.
    const after_step = try sd.stepLine();
    try testing.expectEqual(core.StopKind.step, after_step.kind.?);
    try testing.expect(after_step.pc.?.source.?.line != CLAMP_LINE);
    try testing.expectEqualStrings("_clamp", after_step.pc.?.function.?);

    // 6. stepOut runs to the caller's return — back in _main (small-model near return).
    //    Clear the clamp breakpoint first so a forward run cannot re-trip it.
    try sd.clearBreakpoint(rb.id);
    const out = try sd.stepOut();
    try testing.expectEqual(core.StopKind.step, out.kind.?);
    try testing.expectEqualStrings("_main", out.pc.?.function.?);
}

// ===========================================================================
// M-S1.5 — the PURE source-cache + window render (debug-source-inlining-plan §9).
// Drives `cacheSource`/`sourceWindow` directly (no wire, no machine), proving the
// render + flags + name lookup independent of the transport.
// ===========================================================================

// The exact bytes of examples/BB.C (the committed oracle): line 9 = "    r = v;",
// line 20 = "    m = GRAPHICS;". 28 lines, LF-terminated.
const bb_c =
    \\struct Pixel { int x; int y; unsigned char color; };
    \\enum Mode { TEXT, GRAPHICS, HIRES };
    \\
    \\int g_frames;
    \\
    \\int clamp(int v, int lo, int hi)
    \\{
    \\    int r;
    \\    r = v;
    \\    if (r < lo) r = lo;
    \\    if (r > hi) r = hi;
    \\    return r;
    \\}
    \\
    \\int main(void)
    \\{
    \\    struct Pixel p;
    \\    enum Mode m;
    \\    int i;
    \\    m = GRAPHICS;
    \\    p.x = clamp(300, 0, 319);
    \\    p.y = clamp(250, 0, 199);
    \\    p.color = 15;
    \\    for (i = 0; i < 3; i++) {
    \\        g_frames = g_frames + 1;
    \\    }
    \\    return p.x + p.y + (int)m;
    \\}
    \\
;

fn lineNamed(win: core.SourceWindow, number: u32) ?core.SrcLine {
    for (win.lines) |l| if (l.number == number) return l;
    return null;
}

test "M-S1.5 core: cacheSource + sourceWindow render (BB.C oracle, flags, name lookup)" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");
    const psp_seg = m.dos.current_psp;

    var ctrl = Controller.init(m);
    var sd = SourceDebugger.init(alloc, &ctrl);
    defer sd.deinit();
    sd.attachOnLoad(bb_exe, null, psp_seg);

    const file_id = sd.fileIdForName("BB.C") orelse return error.NoFile;
    // Name lookup: exact and basename resolve the SAME id `fileId` does.
    try testing.expectEqual(file_id, sd.fileIdForName("BB.C").?);

    // Feed the on-disk BB.C bytes (the worker would read these off a configured root).
    sd.cacheSource(file_id, 0, bb_c);
    try testing.expect(sd.isSourceCached(file_id));

    var scratch: [core.MAX_WINDOW_LINES]core.SrcLine = undefined;

    // Default context (5): 11 lines 4..14, line 9 active, text "    r = v;".
    {
        const w = sd.sourceWindow(file_id, 9, 5, &scratch).?;
        try testing.expectEqual(@as(usize, 11), w.lines.len);
        try testing.expectEqual(@as(u32, 4), w.lines[0].number);
        try testing.expectEqual(@as(u32, 14), w.lines[10].number);
        try testing.expect(!w.clamped);
        const active = lineNamed(w, 9).?;
        try testing.expect(active.active);
        try testing.expectEqualStrings("    r = v;", active.text);
        try testing.expect(!lineNamed(w, 8).?.active);
    }
    // context 0 → exactly the active line.
    {
        const w = sd.sourceWindow(file_id, 9, 0, &scratch).?;
        try testing.expectEqual(@as(usize, 1), w.lines.len);
        try testing.expect(w.lines[0].active);
        try testing.expectEqualStrings("    r = v;", w.lines[0].text);
    }
    // Oversize context → clamped, count == min(MAX_WINDOW_LINES, file length) = 28.
    {
        const w = sd.sourceWindow(file_id, 6, 1000, &scratch).?;
        try testing.expect(w.clamped);
        try testing.expectEqual(@as(usize, 28), w.lines.len);
        try testing.expectEqual(@as(u32, 1), w.lines[0].number);
        try testing.expectEqual(@as(u32, 28), w.lines[27].number);
    }
}

test "M-S1.5 core: line truncation + CP437/CRLF/TAB transcode (no silent smear)" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    var ctrl = Controller.init(ctx.m);
    var sd = SourceDebugger.init(alloc, &ctrl);
    defer sd.deinit();
    sd.attachOnLoad(null, null, 0); // no symbols needed for the pure cache path

    // A long line (> MAX_LINE_BYTES) on line 1; a short line 2 (so line_starts is exercised).
    {
        var buf: [core.MAX_LINE_BYTES + 50]u8 = undefined;
        @memset(buf[0..], 'x');
        buf[buf.len - 1] = '\n';
        buf[buf.len - 2] = 'b'; // line 2 = "b"
        buf[buf.len - 3] = '\n';
        // The cache is keyed by id, independent of the (absent) symbols.
        sd.cacheSource(7, 0, buf[0..]);
        var scratch: [core.MAX_WINDOW_LINES]core.SrcLine = undefined;
        const w = sd.sourceWindow(7, 1, 0, &scratch).?;
        try testing.expect(w.lines[0].truncated);
        try testing.expectEqual(@as(usize, core.MAX_LINE_BYTES), w.lines[0].text.len);
    }
    // CP437 high byte (0xC9 → ═ U+2550) + CRLF + a leading TAB: assert valid UTF-8, CR
    // stripped, TAB expanded to spaces (the one place "no silent smear" is at risk).
    {
        const raw = "\tA\xC9B\r\nnext\r\n"; // line 1 = TAB A ═ B (CRLF)
        sd.cacheSource(8, 1, raw);
        var scratch: [core.MAX_WINDOW_LINES]core.SrcLine = undefined;
        const w = sd.sourceWindow(8, 1, 0, &scratch).?;
        const text = w.lines[0].text;
        try testing.expect(std.unicode.utf8ValidateSlice(text)); // valid UTF-8
        try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null); // CR stripped
        // TAB at column 0 expands to 8 spaces, then "A", the ═ glyph (U+2550 = E2 95 90), "B".
        try testing.expectEqualStrings("        A\u{2550}B", text);
    }
}

test "M-S1 core: source breakpoint re-resolves across a reload (new load_para)" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");
    const psp_seg = m.dos.current_psp;

    var ctrl = Controller.init(m);
    var sd = SourceDebugger.init(alloc, &ctrl);
    defer sd.deinit();

    sd.attachOnLoad(bb_exe, null, psp_seg);
    const rb = try sd.setBreakpoint(.{ .source = .{ .file = "BB.C", .line = CLAMP_LINE } });
    try testing.expect(rb.verified);
    const first = rb.resolved.?.linear;

    // A reload at a DIFFERENT psp (load_para) shifts every runtime address by 16 bytes
    // per paragraph; the RETAINED spec re-resolves to the new linear without re-sending.
    sd.attachOnLoad(bb_exe, null, psp_seg + 1);
    var out: [4]core.ResolvedBreakpoint = undefined;
    const list = sd.listBreakpoints(&out);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expect(list[0].verified);
    try testing.expectEqual(first + 0x10, list[0].resolved.?.linear);
}

test "M-S1 core: graceful no-symbols (stripped image) — addr bp works, source does not" {
    const alloc = testing.allocator;
    var ctx = try boot(alloc);
    defer ctx.deinit();
    const m = ctx.m;

    try writeHostFile(&ctx, "BB.EXE", bb_exe);
    try m.bootProgram(2, "BB.EXE", "");

    var ctrl = Controller.init(m);
    var sd = SourceDebugger.init(alloc, &ctrl);
    defer sd.deinit();

    // No EXE bytes ⇒ a graceful empty overlay (`source == .none`): every symbol lookup
    // returns null, source/function breakpoints are unverified, address bp still works.
    sd.attachOnLoad(null, null, m.dos.current_psp);

    const src = try sd.setBreakpoint(.{ .source = .{ .file = "BB.C", .line = CLAMP_LINE } });
    try testing.expect(!src.verified);

    const fnbp = try sd.setBreakpoint(.{ .function = .{ .name = "_clamp" } });
    try testing.expect(!fnbp.verified);

    const where = try sd.pcLocation();
    try testing.expect(where.function == null);
    try testing.expect(where.source == null);

    const addr = try sd.setBreakpoint(.{ .addr = .{ .linear = 0x12340 } });
    try testing.expect(addr.verified);
    try testing.expectEqual(@as(u32, 0x12340), addr.resolved.?.linear);
}
