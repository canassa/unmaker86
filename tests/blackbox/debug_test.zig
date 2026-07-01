//! Black-box SOURCE-LEVEL debug test for the zdos M-S1 debugger.
//!
//! Spawns the REAL `./zig-out/bin/zdos --serve 0 examples/BB.EXE` child (full process
//! isolation) and drives the source-level debug core END-TO-END over the wire — exactly
//! as an external IDE/MCP client would. It never imports emulator internals; it only
//! speaks HTTP: the M-S1 debug ops are exposed over the MCP endpoint (`POST /mcp`,
//! JSON-RPC `tools/call`), and `run` uses the REST `/api/run` route. The same single
//! worker owns the controller, so a breakpoint set via MCP is honored by a REST run.
//!
//! Fixture: `examples/BB.EXE` — a Borland C++ 3.1 program compiled `bcc -v -ms` from
//! `examples/BB.C`, carrying embedded TDS debug info. zdos attaches that overlay at
//! serve-time (reading the EXE off the mount) and maps source `file:line` from the
//! TDS — it does NOT read `BB.C` itself (the debug info carries line references, not
//! source text); `BB.C` is committed alongside purely as the human oracle.
//!
//! Oracle (`docs/research/bcc3-fixtures/BB.{C,LST}`): `clamp()` body is lines 9–12;
//! line 9 (`r = v;`) is clamp's first post-prologue statement at image offset 0x02CB;
//! `main()`'s first statement (`m = GRAPHICS;`) is line 20; the `clamp(300,…)` call
//! site is line 21. These are the deterministic goldens asserted below.

const std = @import("std");
const Session = @import("session.zig").Session;

const testing = std.testing;

const FIXTURE = "examples/BB.EXE";

const CLAMP_LINE: u32 = 9; // clamp's first statement (`r = v;`)
const CLAMP_OFF: u16 = 0x02CB; // its image offset in the single small-model code segment
const NEXT_LINE: u32 = 10; // `if (r < lo) r = lo;` — one source line past line 9
const MAIN_LINE: u32 = 20; // main's first statement (`m = GRAPHICS;`)

// ── MCP tool-call helper over the real `/mcp` endpoint ──────────────────────

/// One content item of a `tools/call` result; only `text` is consumed (the inner
/// body is the SAME JSON the server's `writeX` serializers emit). `type` is ignored.
const Content = struct { text: []const u8 = "" };
const Envelope = struct {
    result: ?struct {
        content: []const Content = &.{},
        isError: bool = false,
    } = null,
};

const McpResult = struct { is_error: bool, text: []const u8 };

/// POST one JSON-RPC `tools/call` to `/mcp` and unwrap it to `{is_error, inner-text}`.
/// A JSON-RPC error envelope (no `result`) is reported as `is_error = true` with the
/// raw body as text, so an unresolvable-line tool error is observable either way. The
/// returned text lives in the session arena until the next request resets it.
fn mcpCall(s: *Session, tool: []const u8, args_json: []const u8) !McpResult {
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ tool, args_json },
    );
    const r = try s.requestRaw(.POST, "/mcp", body);
    if (r.status != .ok) {
        std.debug.print("MCP {s}: HTTP {d}: {s}\n", .{ tool, @intFromEnum(r.status), r.body });
        return error.McpHttpError;
    }
    const env = try std.json.parseFromSliceLeaky(Envelope, s.arena.allocator(), r.body, .{ .ignore_unknown_fields = true });
    if (env.result) |res| {
        if (res.content.len == 0) return error.McpNoContent;
        return .{ .is_error = res.isError, .text = res.content[0].text };
    }
    return .{ .is_error = true, .text = r.body }; // JSON-RPC error envelope
}

/// `mcpCall` + assert the tool did NOT error + parse the inner body into `T`.
fn mcpOk(s: *Session, comptime T: type, tool: []const u8, args_json: []const u8) !T {
    const m = try mcpCall(s, tool, args_json);
    if (m.is_error) {
        std.debug.print("MCP {s}: unexpected tool error: {s}\n", .{ tool, m.text });
        return error.McpToolError;
    }
    return std.json.parseFromSliceLeaky(T, s.arena.allocator(), m.text, .{ .ignore_unknown_fields = true });
}

// ── inner result shapes (mirror server.zig writeWhere / writeDbg* exactly) ──

const Addr = struct { seg: u16 = 0, off: u16 = 0, linear: u32 = 0 };
const Source = struct { file_id: u32 = 0, path: []const u8 = "", line: u32 = 0 };
/// The inlined source window (M-S1.5) — mirrors `server.zig:writeSourceWindow`.
const Line = struct { number: u32 = 0, active: bool = false, truncated: bool = false, text: []const u8 = "" };
const Window = struct {
    has: bool = false,
    clamped: bool = false,
    has_root: bool = false,
    root: u8 = 0,
    file_id: u32 = 0,
    active_line: u32 = 0,
    count: u8 = 0,
    lines: []const Line = &.{},
};
const Pc = struct { addr: Addr = .{}, function: ?[]const u8 = null, source: ?Source = null, window: Window = .{} };
/// breakpoint `spec` is a union shape on the wire (source→{file,line}, function→{name},
/// addr→{linear}); we model every field optional and only assert the relevant ones.
const Spec = struct { file: ?[]const u8 = null, line: u32 = 0, name: ?[]const u8 = null, linear: ?u32 = null };
const Bp = struct {
    id: u32 = 0,
    kind: []const u8 = "",
    verified: bool = false,
    spec: Spec = .{},
    resolved: ?Addr = null,
    source: ?Source = null,
    window: Window = .{},
};
/// `list_sources` result shape.
const SrcFile = struct { file_id: u32 = 0, path: []const u8 = "", cached: bool = false };
const SrcFiles = struct { files: []const SrcFile = &.{} };

/// Find the window line with the given 1-based number (null if not present).
fn lineNo(win: Window, number: u32) ?Line {
    for (win.lines) |l| if (l.number == number) return l;
    return null;
}
fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}
const BpList = struct { breakpoints: []const Bp = &.{} };
const Stop = struct {
    kind: ?[]const u8 = null,
    running: bool = false,
    cycle: u64 = 0,
    bp_id: ?u32 = null,
    pc: ?Pc = null,
};

fn spawn(io: std.Io) !Session {
    return Session.spawn(testing.allocator, io, FIXTURE);
}

// ── M-S2 backtrace result shapes (mirror worker.zig:backtraceBody exactly) ──
const FrameAddr = struct { seg: u16 = 0, off: u16 = 0, linear: u32 = 0 };
const Frame = struct {
    index: u32 = 0,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    addr: FrameAddr = .{},
    frame_base: u16 = 0,
    is_far: bool = false,
    unreliable: bool = false,
};
const Backtrace = struct { frames: []const Frame = &.{}, truncated_reason: []const u8 = "" };

// ── M-S2 scopes / locals / variable-tree shapes (mirror worker.zig writeVariable) ──
const Variable = struct {
    name: []const u8 = "",
    type: []const u8 = "",
    avail: []const u8 = "",
    value: []const u8 = "",
    variables_ref: u64 = 0,
    bit_width: u8 = 0,
    addr: ?FrameAddr = null,
};
const FrameVars = struct { frame: u32 = 0, variables: []const Variable = &.{} };
const ExpandVars = struct { start: u32 = 0, count: u32 = 0, total: u32 = 0, variables: []const Variable = &.{} };
const ScopeRow = struct { kind: []const u8 = "", frame_index: u32 = 0, variables_ref: u64 = 0 };
const Scopes = struct { scopes: []const ScopeRow = &.{} };

// ── M-S2 inspect / context shapes (mirror worker.zig writeInspect / writeContext) ──
const Inspect = struct { path: []const u8 = "", result: Variable = .{} };
const CtxFrame = struct { index: u32 = 0, function: ?[]const u8 = null, file: ?[]const u8 = null, line: u32 = 0, addr: FrameAddr = .{} };
const CtxWindow = struct { has: bool = false, file_id: u32 = 0, active_line: u32 = 0, clamped: bool = false, lines: []const Line = &.{} };
const Context = struct {
    frame: CtxFrame = .{},
    window: ?CtxWindow = null,
    backtrace: []const Frame = &.{},
    truncated_reason: []const u8 = "",
    locals: []const Variable = &.{},
};

/// The named variable in a frame's locals (null if absent).
fn varNamed(fv: FrameVars, name: []const u8) ?Variable {
    for (fv.variables) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}
/// The named variable in a flat variable list (context `locals`, expansion children).
fn varInList(vars: []const Variable, name: []const u8) ?Variable {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}
/// GET a `dbg` JSON body and parse it into `T` (asserting HTTP 200). The parse borrows the
/// session arena — VALID ONLY until the next `requestRaw` (which resets it), so pull out any
/// value (a `variables_ref`) or finish assertions before the next request.
fn getDbg(s: *Session, comptime T: type, path: []const u8) !T {
    const r = try s.requestRaw(.GET, path, null);
    try testing.expectEqual(std.http.Status.ok, r.status);
    return std.json.parseFromSliceLeaky(T, s.arena.allocator(), r.body, .{ .ignore_unknown_fields = true });
}

test "source-level debug over the API: BB.EXE source bp -> run -> whereami -> step/out" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // 1. At entry the guest is paused in the C runtime startup (C0), which BB.C's debug
    //    info does not cover: whereami resolves an address but no function/source.
    {
        const w = try mcpOk(&s, Pc, "whereami", "{}");
        try testing.expect(w.function == null);
        try testing.expect(w.source == null);
    }

    // 2. Set a SOURCE breakpoint at BB.C:9 (clamp's first statement). It must verify and
    //    resolve to image offset 0x02CB — i.e. the symbol overlay's relocation matches
    //    the real loader placement.
    {
        const bp = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        try testing.expectEqualStrings("source", bp.kind);
        try testing.expect(bp.verified);
        try testing.expectEqual(CLAMP_OFF, bp.resolved.?.off);
        try testing.expectEqualStrings("BB.C", bp.source.?.path);
        try testing.expectEqual(CLAMP_LINE, bp.source.?.line);
    }

    // 3. Run (REST). The MCP-set breakpoint lives in the same controller breakpoint set,
    //    so the guest stops there.
    {
        const stop = try s.run(null);
        try testing.expect(stop.stop.breakpoint != null);
    }

    // 4. whereami now reports the SOURCE location: clamp(), BB.C:9.
    {
        const w = try mcpOk(&s, Pc, "whereami", "{}");
        try testing.expect(w.function != null);
        try testing.expectEqualStrings("_clamp", w.function.?);
        try testing.expectEqualStrings("BB.C", w.source.?.path);
        try testing.expectEqual(CLAMP_LINE, w.source.?.line);
    }

    // 5. step_line advances to the next source line (10), staying in clamp's frame.
    {
        const st = try mcpOk(&s, Stop, "step_line", "{}");
        try testing.expectEqualStrings("step", st.kind.?);
        try testing.expectEqualStrings("_clamp", st.pc.?.function.?);
        try testing.expectEqual(NEXT_LINE, st.pc.?.source.?.line);
    }

    // 6. A FUNCTION breakpoint resolves to main()'s first post-prologue statement (20).
    {
        const bp = try mcpOk(&s, Bp, "set_function_breakpoint", "{\"name\":\"_main\"}");
        try testing.expectEqualStrings("function", bp.kind);
        try testing.expect(bp.verified);
        try testing.expectEqual(MAIN_LINE, bp.source.?.line);
    }

    // 7. step_out leaves clamp() and returns to its caller, main().
    {
        const st = try mcpOk(&s, Stop, "step_out", "{}");
        try testing.expect(st.pc.?.function != null);
        try testing.expectEqualStrings("_main", st.pc.?.function.?);
        try testing.expectEqualStrings("BB.C", st.pc.?.source.?.path);
    }

    // 8. Both breakpoints (the source bp from step 2 + the function bp from step 6) list.
    {
        const list = try mcpOk(&s, BpList, "list_source_breakpoints", "{}");
        try testing.expectEqual(@as(usize, 2), list.breakpoints.len);
    }

    // 9. An unresolvable line is an HONEST tool error (no faked success).
    {
        const m = try mcpCall(&s, "run_to_line", "{\"file\":\"BB.C\",\"line\":999}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unresolved") != null);
    }

    // 10. ABSENCE: this spawn NEVER configured a source_path, so every window is
    //     has=false even though the location resolves — proving the API source path is the
    //     sole text source (NOT co-location of BB.C beside BB.EXE on the mount).
    {
        const w = try mcpOk(&s, Pc, "whereami", "{}");
        try testing.expect(!w.window.has);
    }
}

test "source-code inlining (M-S1.5): load source_path -> windows in whereami/bp/step/read_source" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // Step 0 — configure the host source path via the API (NOT a CLI flag): re-load the
    // recipe with `source_path:"examples"` (the dir holding examples/BB.C). This reboots to
    // entry and eager-caches BB.C off the configured root.
    {
        const m = try mcpCall(&s, "load", "{\"file\":\"BB.EXE\",\"source_path\":\"examples\"}");
        try testing.expect(!m.is_error);
    }

    // R6 — set_source_breakpoint BB.C:9: the SET-confirm carries a placement window centered
    // on the bound line (default context → 11 lines, clamped-to-file 4..14).
    {
        const bp = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        try testing.expect(bp.verified);
        try testing.expect(bp.window.has);
        try testing.expectEqual(@as(u32, 9), bp.window.active_line);
        try testing.expectEqualStrings("r = v;", trimmed(lineNo(bp.window, 9).?.text));
        try testing.expect(lineNo(bp.window, 9).?.active);
        try testing.expectEqualStrings("int r;", trimmed(lineNo(bp.window, 8).?.text));
        try testing.expectEqualStrings("if (r < lo) r = lo;", trimmed(lineNo(bp.window, 10).?.text));
        try testing.expect(!lineNo(bp.window, 10).?.active);
    }

    // Run to the breakpoint.
    {
        const stop = try s.run(null);
        try testing.expect(stop.stop.breakpoint != null);
    }

    // R1 — whereami (default context): window 4..14, line 9 active + correct text.
    {
        const w = try mcpOk(&s, Pc, "whereami", "{}");
        try testing.expectEqual(@as(u32, 9), w.source.?.line);
        try testing.expect(w.window.has);
        try testing.expect(!w.window.clamped);
        try testing.expectEqual(@as(u32, 4), w.window.lines[0].number);
        try testing.expectEqual(@as(u32, 14), w.window.lines[w.window.lines.len - 1].number);
        try testing.expectEqualStrings("r = v;", trimmed(lineNo(w.window, 9).?.text));
    }

    // R1 — whereami {context:2}: exactly 5 lines (7..11), line 9 active, not clamped.
    {
        const w = try mcpOk(&s, Pc, "whereami", "{\"context\":2}");
        try testing.expectEqual(@as(u8, 5), w.window.count);
        try testing.expectEqual(@as(u32, 7), w.window.lines[0].number);
        try testing.expectEqual(@as(u32, 11), w.window.lines[4].number);
        try testing.expect(!w.window.clamped);
        try testing.expect(lineNo(w.window, 9).?.active);
    }

    // R1 — step_line {context:2}: advance to line 10, window re-centers (8..12).
    {
        const st = try mcpOk(&s, Stop, "step_line", "{\"context\":2}");
        try testing.expectEqual(NEXT_LINE, st.pc.?.source.?.line);
        try testing.expect(st.pc.?.window.has);
        try testing.expectEqual(@as(u32, 8), st.pc.?.window.lines[0].number);
        try testing.expectEqual(@as(u32, 12), st.pc.?.window.lines[st.pc.?.window.count - 1].number);
        try testing.expectEqualStrings("if (r < lo) r = lo;", trimmed(lineNo(st.pc.?.window, 10).?.text));
    }

    // R2 — read_source not stopped there, explicit context: line 20, ctx 3 → 7 lines 17..23.
    {
        const w = try mcpOk(&s, Window, "read_source", "{\"file\":\"BB.C\",\"line\":20,\"context\":3}");
        try testing.expect(w.has);
        try testing.expectEqual(@as(u32, 20), w.active_line);
        try testing.expectEqual(@as(u8, 7), w.count);
        try testing.expectEqual(@as(u32, 17), w.lines[0].number);
        try testing.expectEqual(@as(u32, 23), w.lines[6].number);
        try testing.expectEqualStrings("m = GRAPHICS;", trimmed(lineNo(w, 20).?.text));
    }

    // R2 — read_source context:0 → exactly the active line.
    {
        const w = try mcpOk(&s, Window, "read_source", "{\"file\":\"BB.C\",\"line\":20,\"context\":0}");
        try testing.expectEqual(@as(u8, 1), w.count);
        try testing.expect(w.lines[0].active);
        try testing.expectEqualStrings("m = GRAPHICS;", trimmed(w.lines[0].text));
    }

    // R2 — oversize context → clamped + count == whole file (28 lines), never silently dropped.
    {
        const w = try mcpOk(&s, Window, "read_source", "{\"file\":\"BB.C\",\"line\":6,\"context\":1000}");
        try testing.expect(w.clamped);
        try testing.expectEqual(@as(u8, 28), w.count);
    }

    // R2 — by file_id echo (one namespace): take whereami's file_id, read_source by id.
    {
        const w0 = try mcpOk(&s, Pc, "whereami", "{}");
        const fid = w0.source.?.file_id;
        var buf: [96]u8 = undefined;
        const args = try std.fmt.bufPrint(&buf, "{{\"file_id\":{d},\"line\":20}}", .{fid});
        const w = try mcpOk(&s, Window, "read_source", args);
        try testing.expect(w.has);
        try testing.expectEqualStrings("m = GRAPHICS;", trimmed(lineNo(w, 20).?.text));
    }

    // R2b — list_sources: BB.C is present with cached:true, and its id round-trips.
    {
        const sf = try mcpOk(&s, SrcFiles, "list_sources", "{}");
        var found = false;
        for (sf.files) |f| {
            if (std.mem.eql(u8, f.path, "BB.C")) {
                found = true;
                try testing.expect(f.cached);
                var buf: [96]u8 = undefined;
                const args = try std.fmt.bufPrint(&buf, "{{\"file_id\":{d},\"line\":9}}", .{f.file_id});
                const w = try mcpOk(&s, Window, "read_source", args);
                try testing.expectEqualStrings("r = v;", trimmed(lineNo(w, 9).?.text));
            }
        }
        try testing.expect(found);
    }

    // R2 — an unknown file name is an HONEST tool error (no faked success).
    {
        const m = try mcpCall(&s, "read_source", "{\"file\":\"NOPE.C\",\"line\":1}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unresolved") != null);
    }
}

// ── M-S2 M2-a: the worker-side nested-JSON transport seam ────────────────────
// Drives the `dbg_selftest` producer (the plan's "trivial stub body") end-to-end over
// BOTH front-ends and asserts the seam's contract: the worker serializes ONE body into the
// session slab, the listener copies it under `session.lock` and streams it, HTTP and MCP
// emit BYTE-IDENTICAL bodies sharing one `DBG_JSON_CAP` ceiling, and an over-cap body is an
// EXPLICIT `response_too_large` (413 / isError), never a truncated JSON (CLAUDE.md §2).
test "M-S2 seam: nested-JSON body identical over HTTP+MCP; overflow -> 413/isError" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    // (a) A small body: the HTTP raw body equals the MCP inner text byte-for-byte (the
    //     worker produces the bytes ONCE; both front-ends emit the SAME body — no drift).
    {
        const http = try s.requestRaw(.GET, "/api/dbg/selftest?fill=7", null);
        try testing.expectEqual(std.http.Status.ok, http.status);
        // Copy off the arena BEFORE the MCP call resets it.
        var buf: [128]u8 = undefined;
        @memcpy(buf[0..http.body.len], http.body);
        const http_body = buf[0..http.body.len];
        try testing.expectEqualStrings("{\"selftest\":true,\"fill\":7,\"data\":\"xxxxxxx\"}", http_body);
        const m = try mcpCall(&s, "dbg_selftest", "{\"fill\":7}");
        try testing.expect(!m.is_error);
        try testing.expectEqualStrings(http_body, m.text); // BYTE-IDENTICAL
    }

    // (a') A LARGE body (~100 KB, far past the 48 KiB `resp_buf`) streams WHOLE on both
    //      transports — proving the MCP incremental-escape stream shares the `DBG_JSON_CAP`
    //      ceiling (T8), not `resp_buf`/2. (Identity is pinned at small scale above; here we
    //      assert each front-end delivers the full body, since a 100 KB compare cannot be
    //      staged across the request arena's reset.)
    {
        const http = try s.requestRaw(.GET, "/api/dbg/selftest?fill=100000", null);
        try testing.expectEqual(std.http.Status.ok, http.status);
        try testing.expect(http.body.len > 100000);
        try testing.expect(std.mem.endsWith(u8, http.body, "\"}"));
    }
    {
        const m = try mcpCall(&s, "dbg_selftest", "{\"fill\":100000}");
        try testing.expect(!m.is_error);
        try testing.expect(m.text.len > 100000);
        try testing.expect(std.mem.endsWith(u8, m.text, "\"}"));
    }

    // (b) Overflow: an over-`DBG_JSON_CAP` body is an EXPLICIT typed error on BOTH
    //     front-ends — 413 for HTTP, an `isError` tool result for MCP — never a clipped JSON.
    {
        const http = try s.requestRaw(.GET, "/api/dbg/selftest?fill=300000", null);
        try testing.expectEqual(std.http.Status.payload_too_large, http.status);
        try testing.expect(std.mem.indexOf(u8, http.body, "response_too_large") != null);
    }
    {
        const m = try mcpCall(&s, "dbg_selftest", "{\"fill\":300000}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "response_too_large") != null);
    }
}

// ── M-S2 M2-b: backtrace (stack unwinding) over the wire ─────────────────────
// Real 16-bit BP-chain unwinding, Stopped-gated, peek-only. Proves frame identity, the
// call-site (ret-1) line mapping, the far-frame pop (medium model), recursion frame
// identity (distinct frame_base per level), the anti-fabrication boundary, and byte-
// identical determinism across two fresh sessions. (debug-m2-plan.md §2/§11.)

fn countFn(bt: Backtrace, name: []const u8) usize {
    var n: usize = 0;
    for (bt.frames) |f| {
        if (f.function) |fn_name| if (std.mem.eql(u8, fn_name, name)) {
            n += 1;
        };
    }
    return n;
}

test "M-S2 backtrace (BB.EXE): clamp -> main(call site 21) -> c0_startup; honest at entry; deterministic" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    // (a) Honest degradation at entry: paused in the C runtime startup (C0), which BB.C's
    //     debug info does not cover — frame 0 is address-only (no function), and the walk
    //     stops with an honest reason, NEVER a fabricated user frame.
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        const bt = try mcpOk(&s, Backtrace, "backtrace", "{}");
        try testing.expect(bt.frames.len >= 1);
        try testing.expect(bt.frames[0].function == null);
        // C0 has no BP-framed caller we can trust → no_function (address-only frame 0).
        try testing.expectEqualStrings("no_function", bt.truncated_reason);
    }

    // (b) The real backtrace at the BB.C:9 stop inside clamp().
    var body_buf: [2048]u8 = undefined;
    var body_len: usize = 0;
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        const stop = try s.run(null);
        try testing.expect(stop.stop.breakpoint != null);

        const bt = try mcpOk(&s, Backtrace, "backtrace", "{}");
        try testing.expectEqual(@as(usize, 2), bt.frames.len);

        // frame 0 = clamp @ BB.C:9 (near, reliable, live).
        try testing.expectEqualStrings("_clamp", bt.frames[0].function.?);
        try testing.expectEqual(CLAMP_LINE, bt.frames[0].line);
        try testing.expectEqualStrings("BB.C", bt.frames[0].file.?);
        try testing.expect(!bt.frames[0].is_far and !bt.frames[0].unreliable);

        // frame 1 = main @ the clamp CALL SITE (line 21, NOT the next statement) — proves
        // the ret-1 mapping. Distinct, nonzero, strictly-ascending frame_base.
        try testing.expectEqualStrings("_main", bt.frames[1].function.?);
        try testing.expectEqual(@as(u32, 21), bt.frames[1].line);
        try testing.expect(bt.frames[0].frame_base != 0 and bt.frames[1].frame_base != 0);
        try testing.expect(bt.frames[1].frame_base > bt.frames[0].frame_base);

        // Terminated cleanly at the C runtime startup — no fabricated parent past main.
        try testing.expectEqualStrings("c0_startup", bt.truncated_reason);

        // Capture the raw HTTP body for the determinism compare below.
        const http = try s.requestRaw(.GET, "/api/dbg/backtrace", null);
        try testing.expectEqual(std.http.Status.ok, http.status);
        @memcpy(body_buf[0..http.body.len], http.body);
        body_len = http.body.len;
    }

    // (c) Determinism: a SECOND fresh session, same binary + same (empty) input, reaches
    //     the same stop cycle and emits a BYTE-IDENTICAL backtrace body (CLAUDE.md §1).
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);
        const http = try s.requestRaw(.GET, "/api/dbg/backtrace", null);
        try testing.expectEqual(std.http.Status.ok, http.status);
        try testing.expectEqualStrings(body_buf[0..body_len], http.body);
    }
}

test "M-S2 backtrace (BB2.EXE recursion): distinct frame_base per _fact level, same call-site line" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try Session.spawn(testing.allocator, threaded.io(), "examples/BB2.EXE");
    defer s.deinit();

    // Break at fact()'s entry; drive the recursion 5 levels deep (fact(5)..fact(1)).
    _ = try mcpOk(&s, Bp, "set_function_breakpoint", "{\"name\":\"_fact\"}");
    var depth: usize = 0;
    while (depth < 5) : (depth += 1) {
        const stop = try s.run(null);
        try testing.expect(stop.stop.breakpoint != null);
    }

    const bt = try mcpOk(&s, Backtrace, "backtrace", "{}");
    // 5 nested _fact frames + _main. (The innermost is fact(1), the base case.)
    try testing.expectEqual(@as(usize, 5), countFn(bt, "_fact"));
    try testing.expect(countFn(bt, "_main") == 1);
    for (0..5) |i| try testing.expectEqualStrings("_fact", bt.frames[i].function.?);
    try testing.expectEqualStrings("_main", bt.frames[5].function.?);
    try testing.expectEqualStrings("c0_startup", bt.truncated_reason);

    // Recursion frame identity: strictly-ascending, DISTINCT frame_base per level (SP-
    // relative identity), and every _fact CALLER frame maps to the SAME recursion call site.
    var prev: u16 = 0;
    for (bt.frames) |f| {
        try testing.expect(f.frame_base > prev); // strictly ascending toward the stack base
        prev = f.frame_base;
    }
    const call_site = bt.frames[1].line; // fact(k)'s `r = n * fact(n-1)` call site
    try testing.expect(call_site != 0);
    for (1..5) |i| try testing.expectEqual(call_site, bt.frames[i].line);
    // The innermost frame (fact(1), the live stop at fact's entry line) is a DIFFERENT line
    // than the recursion call site — it has not made the recursive call.
    try testing.expect(bt.frames[0].line != call_site);
}

test "M-S2 backtrace (BB2M.EXE medium model): far-frame pop resolves the far caller (is_far, cur_seg_base)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try Session.spawn(testing.allocator, threaded.io(), "examples/BB2M.EXE");
    defer s.deinit();

    // Medium model: fact/main are FAR (function far C). Stop at fact(5)'s entry.
    _ = try mcpOk(&s, Bp, "set_function_breakpoint", "{\"name\":\"_fact\"}");
    const stop = try s.run(null);
    try testing.expect(stop.stop.breakpoint != null);

    const bt = try mcpOk(&s, Backtrace, "backtrace", "{}");
    try testing.expect(bt.frames.len >= 2);
    try testing.expectEqualStrings("_fact", bt.frames[0].function.?);
    try testing.expect(!bt.frames[0].is_far); // frame 0 has no in-trace callee

    // frame 1 = main, reached by unwinding across a FAR call edge (fact is far): this is the
    // T2 regression guard — the caller resolves through the far ret_cs / cur_seg_base path,
    // which a frame-0-cs_base bug (near-only pop) would misread. is_far marks the far edge.
    try testing.expectEqualStrings("_main", bt.frames[1].function.?);
    try testing.expect(bt.frames[1].is_far);
    try testing.expect(bt.frames[1].frame_base > bt.frames[0].frame_base);
}

test "M-S2 locals (BB.EXE clamp): frame-0 values + outer-frame-register honesty + enum name/(?)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
    const stop = try s.run(null);
    try testing.expect(stop.stop.breakpoint != null);

    // --- frame 0 clamp: v (auto BP+4) == 300; lo (BX) == 0; hi (CX) == 319; r present. ---
    // The M-S1 integration proof's facts, now through the vars.zig Storage dispatch + wire.
    {
        const fv = try getDbg(&s, FrameVars, "/api/dbg/frame-variables?frame=0");
        try testing.expectEqual(@as(u32, 0), fv.frame);
        // De-duplicated by NAME (innermost-wins): exactly one entry each for v/lo/hi/r.
        try testing.expectEqual(@as(usize, 4), fv.variables.len);

        const v = varNamed(fv, "v").?;
        try testing.expectEqualStrings("ok", v.avail);
        try testing.expectEqualStrings("int", v.type);
        try testing.expect(std.mem.startsWith(u8, v.value, "300 ")); // "300 (0x12C)"
        try testing.expect(v.addr != null); // an auto local carries its SS:BP+off address

        const lo = varNamed(fv, "lo").?;
        try testing.expect(std.mem.startsWith(u8, lo.value, "0 "));
        try testing.expect(lo.addr == null); // a register local has no memory address

        const hi = varNamed(fv, "hi").?;
        try testing.expect(std.mem.startsWith(u8, hi.value, "319 "));
        try testing.expect(hi.addr == null);

        try testing.expect(varNamed(fv, "r") != null); // clamp's `int r` (register DX), live at frame 0
    }

    // --- frame 1 main (OUTER): m == GRAPHICS (enum NAME); p expandable; a register local
    //     of main is honestly `outer_frame_register` (the anti-guess proof). ---
    var m_linear: u32 = 0;
    {
        const fv = try getDbg(&s, FrameVars, "/api/dbg/frame-variables?frame=1");
        const m = varNamed(fv, "m").?;
        try testing.expectEqualStrings("ok", m.avail);
        try testing.expectEqualStrings("enum Mode", m.type);
        try testing.expect(std.mem.indexOf(u8, m.value, "GRAPHICS") != null); // the enumerator NAME, not "1"
        m_linear = m.addr.?.linear;

        const p = varNamed(fv, "p").?;
        try testing.expectEqualStrings("struct Pixel", p.type);
        try testing.expect(p.variables_ref != 0); // an aggregate is expandable

        // main's `int i` lives in a register the callee (clamp) may overwrite — for a NON-top
        // frame it is honestly unrecoverable, NEVER a guessed value.
        const i = varNamed(fv, "i").?;
        try testing.expectEqualStrings("outer_frame_register", i.avail);
        try testing.expectEqualStrings("", i.value); // no fabricated value
    }

    // --- enum (?) : poke an out-of-range value (7) into m's slot; it renders `7 (?)`, never
    //     an invented enumerator name (the honest no-match signal, §8). ---
    {
        var poke: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&poke, "{{\"phys\":{d},\"data\":\"0700\"}}", .{m_linear});
        const wr = try s.requestRaw(.PUT, "/api/mem", body);
        try testing.expectEqual(std.http.Status.ok, wr.status);

        const fv = try getDbg(&s, FrameVars, "/api/dbg/frame-variables?frame=1");
        const m = varNamed(fv, "m").?;
        try testing.expect(std.mem.indexOf(u8, m.value, "(?)") != null); // "7 (?)"
        try testing.expect(std.mem.indexOf(u8, m.value, "GRAPHICS") == null);
    }
}

test "M-S2 variable tree (BB2.EXE): struct/bitfield/array/pointer/null expand + paging" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try Session.spawn(testing.allocator, threaded.io(), "examples/BB2.EXE");
    defer s.deinit();

    // Break at BB2.C:54 (`sum = sum + fact(5);`) — after arr/p/np/bits are all assigned.
    _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB2.C\",\"line\":54}");
    const stop = try s.run(null);
    try testing.expect(stop.stop.breakpoint != null);

    // Pull the four aggregate/array/pointer handles (u64 values survive the arena reset).
    var arr_ref: u64 = 0;
    var bits_ref: u64 = 0;
    var p_ref: u64 = 0;
    var np_ref: u64 = 0;
    {
        const fv = try getDbg(&s, FrameVars, "/api/dbg/frame-variables?frame=0");
        arr_ref = varNamed(fv, "arr").?.variables_ref;
        bits_ref = varNamed(fv, "bits").?.variables_ref;
        p_ref = varNamed(fv, "p").?.variables_ref;
        np_ref = varNamed(fv, "np").?.variables_ref;
        try testing.expect(arr_ref != 0 and bits_ref != 0 and p_ref != 0 and np_ref != 0);
    }

    // --- ARRAY: full expand → [0..3] == 10,20,30,40. ---
    {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{arr_ref});
        const ev = try getDbg(&s, ExpandVars, path);
        try testing.expectEqual(@as(u32, 4), ev.total);
        try testing.expectEqual(@as(usize, 4), ev.variables.len);
        try testing.expectEqualStrings("[0]", ev.variables[0].name);
        try testing.expect(std.mem.startsWith(u8, ev.variables[0].value, "10 "));
        try testing.expect(std.mem.startsWith(u8, ev.variables[3].value, "40 "));
    }
    // --- ARRAY PAGING: start=1,count=2 → [1]==20,[2]==30 (never silently clipped). ---
    {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}&start=1&count=2", .{arr_ref});
        const ev = try getDbg(&s, ExpandVars, path);
        try testing.expectEqual(@as(u32, 1), ev.start);
        try testing.expectEqual(@as(u32, 2), ev.count);
        try testing.expectEqual(@as(usize, 2), ev.variables.len);
        try testing.expectEqualStrings("[1]", ev.variables[0].name);
        try testing.expect(std.mem.startsWith(u8, ev.variables[0].value, "20 "));
        try testing.expect(std.mem.startsWith(u8, ev.variables[1].value, "30 "));
    }
    // --- BITFIELD struct Bits {a:3==5, b:5==17, c:8==200}: extracted field values + widths. ---
    {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{bits_ref});
        const ev = try getDbg(&s, ExpandVars, path);
        const a = blk: {
            for (ev.variables) |vv| if (std.mem.eql(u8, vv.name, "a")) break :blk vv;
            return error.NoBitfieldA;
        };
        try testing.expectEqual(@as(u8, 3), a.bit_width);
        try testing.expect(std.mem.startsWith(u8, a.value, "5 "));
        for (ev.variables) |vv| {
            if (std.mem.eql(u8, vv.name, "b")) {
                try testing.expectEqual(@as(u8, 5), vv.bit_width);
                try testing.expect(std.mem.startsWith(u8, vv.value, "17 "));
            } else if (std.mem.eql(u8, vv.name, "c")) {
                try testing.expectEqual(@as(u8, 8), vv.bit_width);
                try testing.expect(std.mem.startsWith(u8, vv.value, "200 "));
            }
        }
    }
    // --- POINTER p = &arr[0]: one deref child "*" == arr[0] == 10. ---
    {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{p_ref});
        const ev = try getDbg(&s, ExpandVars, path);
        try testing.expectEqual(@as(usize, 1), ev.variables.len);
        try testing.expectEqualStrings("*", ev.variables[0].name);
        try testing.expect(std.mem.startsWith(u8, ev.variables[0].value, "10 "));
    }
    // --- NULL POINTER np = 0: the deref child is an honest "<null>", never a wild read. ---
    {
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{np_ref});
        const ev = try getDbg(&s, ExpandVars, path);
        try testing.expectEqual(@as(usize, 1), ev.variables.len);
        try testing.expectEqualStrings("<null>", ev.variables[0].value);
    }
}

test "M-S2 handle lifecycle: stale after step AND after a bare run/reset; peek-only; determinism" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    // (a) One fresh session: capture the frame-1 body (for the determinism compare) + a
    //     handle, prove the inspection path is CYCLE-NEUTRAL (peek-only), then STEP and
    //     confirm the handle is rejected as stale (never a silent wrong read).
    var det_body: [4096]u8 = undefined;
    var det_len: usize = 0;
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);

        // Cycle-neutral proof: a full backtrace + frame_variables + a struct expansion must
        // charge ZERO cycles (side-effect-free peeks; CLAUDE.md §1).
        const cyc_before = (try s.status()).cycles;
        _ = try getDbg(&s, Backtrace, "/api/dbg/backtrace");
        var p_ref: u64 = 0;
        {
            const r = try s.requestRaw(.GET, "/api/dbg/frame-variables?frame=1", null);
            try testing.expectEqual(std.http.Status.ok, r.status);
            @memcpy(det_body[0..r.body.len], r.body);
            det_len = r.body.len;
            const fv = try std.json.parseFromSliceLeaky(FrameVars, s.arena.allocator(), r.body, .{ .ignore_unknown_fields = true });
            p_ref = varNamed(fv, "p").?.variables_ref;
        }
        {
            var pbuf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{p_ref});
            _ = try getDbg(&s, ExpandVars, path);
        }
        try testing.expectEqual(cyc_before, (try s.status()).cycles); // NOT ONE cycle charged

        // STEP invalidates the epoch → the held handle is rejected 409 stale_handle.
        _ = try s.step();
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{p_ref});
        const r = try s.requestRaw(.GET, path, null);
        try testing.expectEqual(std.http.Status.conflict, r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "stale_handle") != null);
    }

    // (b) Determinism: a SECOND fresh session, same binary + same (empty) input, reaches the
    //     same stop cycle/epoch and emits a BYTE-IDENTICAL frame_variables body (handles and
    //     all — the epoch is a pure function of the resume sequence).
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);
        const r = try s.requestRaw(.GET, "/api/dbg/frame-variables?frame=1", null);
        try testing.expectEqual(std.http.Status.ok, r.status);
        try testing.expectEqualStrings(det_body[0..det_len], r.body);
    }

    // (c) The T4 proof: a BARE `run` (not a source step) also invalidates the handle — the
    //     universal, path-independent epoch bump, not folded into `beginStep`.
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);
        var p_ref: u64 = 0;
        {
            const fv = try getDbg(&s, FrameVars, "/api/dbg/frame-variables?frame=1");
            p_ref = varNamed(fv, "p").?.variables_ref;
        }
        _ = try s.run(null); // bare run — bypasses SourceDebugger, must still bump the epoch
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/api/dbg/variables?ref={d}", .{p_ref});
        const r = try s.requestRaw(.GET, path, null);
        try testing.expectEqual(std.http.Status.conflict, r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "stale_handle") != null);
    }
}

test "M-S2 inspect (BB2.EXE): path reads + honest boundaries (array/pointer/null/oob/scalar-field/operator)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try Session.spawn(testing.allocator, threaded.io(), "examples/BB2.EXE");
    defer s.deinit();

    // Break at BB2.C:54 (frame 0 = main; arr/p/np/bits all assigned) — the same stop the
    // variable-tree test uses, so the path reads have known goldens.
    _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB2.C\",\"line\":54}");
    const stop = try s.run(null);
    try testing.expect(stop.stop.breakpoint != null);

    // --- ARRAY element by constant index: arr[2] == 30 (the 3rd element). ---
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"arr[2]\"}");
        try testing.expectEqualStrings("arr[2]", r.path);
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expectEqualStrings("int", r.result.type);
        try testing.expect(std.mem.startsWith(u8, r.result.value, "30 ")); // "30 (0x1E)"
    }

    // --- BARE POINTER: p == &arr[0] (non-null) → a pointer value + an expandable ref. ---
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"p\"}");
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expect(r.result.variables_ref != 0); // a pointer is expandable
    }

    // --- POINTER INDEX (deref): p[0] == arr[0] == 10 (a nested deref path). ---
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"p[0]\"}");
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expect(std.mem.startsWith(u8, r.result.value, "10 "));
    }

    // --- STRUCT MEMBER (bitfield): bits.c == 200, width 8 (the `.field` descent). ---
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"bits.c\"}");
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expectEqual(@as(u8, 8), r.result.bit_width);
        try testing.expect(std.mem.startsWith(u8, r.result.value, "200 "));
    }

    // --- NULL POINTER DEREF: np == 0 → "<null>", never a wild read. ---
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"np[0]\"}");
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expectEqualStrings("<null>", r.result.value);
    }

    // --- OUT-OF-BOUNDS index (arr has 4 elements) → a typed `unresolved` error. ---
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"arr[9]\"}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unresolved") != null);
    }

    // --- `.field` on a SCALAR (sum is int) → a typed `unresolved` error, not a wild read. ---
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"sum.x\"}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unresolved") != null);
    }

    // --- OPERATOR (the anti-eval proof): `a+b` → unsupported_expression, never a guess. ---
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"a+b\"}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unsupported_expression") != null);
    }
    // ...even when the head IS a real local: `arr + 1` must still be unsupported (the grammar
    // is rejected BEFORE name resolution — it never leaks as `unresolved`).
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"arr + 1\"}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unsupported_expression") != null);
    }
}

test "M-S2 inspect (BB.EXE): struct member `.` path + operator anti-eval on a real struct" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawn(threaded.io());
    defer s.deinit();

    _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
    _ = try s.run(null);

    // frame 1 = main, where `struct Pixel p` lives: p.x resolves to its int member x.
    {
        const r = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"p.x\",\"frame\":1}");
        try testing.expectEqualStrings("ok", r.result.avail);
        try testing.expectEqualStrings("int", r.result.type);
    }
    // `p.x+1` — an operator on a resolvable member path → unsupported_expression (plan item 7).
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"p.x+1\",\"frame\":1}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unsupported_expression") != null);
    }
    // A non-top register local descended through a member path is honestly unresolvable, not a
    // fabricated value: main's `i` is a register local, `i.x` → unresolved.
    {
        const m = try mcpCall(&s, "inspect", "{\"path\":\"nope\"}");
        try testing.expect(m.is_error);
        try testing.expect(std.mem.indexOf(u8, m.text, "unresolved") != null);
    }
}

test "M-S2 context (BB.EXE): one call = frame + window + backtrace + locals; deterministic + peek-only" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var det_body: [8192]u8 = undefined;
    var det_len: usize = 0;
    {
        var s = try spawn(threaded.io());
        defer s.deinit();

        // Configure the HOST source dir (examples/) so the window carries text, then break at
        // clamp's first statement (BB.C:9).
        {
            const m = try mcpCall(&s, "load", "{\"file\":\"BB.EXE\",\"source_path\":\"examples\"}");
            try testing.expect(!m.is_error);
        }
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);

        // Cycle-neutral: an inspect + a context charge ZERO cycles (peek-only, CLAUDE.md §1).
        const cyc_before = (try s.status()).cycles;
        _ = try mcpOk(&s, Inspect, "inspect", "{\"path\":\"v\"}");

        const ctx = try mcpOk(&s, Context, "context", "{}");
        // (1) frame: _clamp at BB.C:9.
        try testing.expectEqualStrings("_clamp", ctx.frame.function.?);
        try testing.expectEqualStrings("BB.C", ctx.frame.file.?);
        try testing.expectEqual(@as(u32, CLAMP_LINE), ctx.frame.line);
        // (2) window: present, active line 9, and line 9 marked active in the numbered list.
        try testing.expect(ctx.window != null);
        try testing.expect(ctx.window.?.has);
        try testing.expectEqual(@as(u32, CLAMP_LINE), ctx.window.?.active_line);
        var saw_active = false;
        for (ctx.window.?.lines) |ln| {
            if (ln.number == CLAMP_LINE) {
                try testing.expect(ln.active);
                saw_active = true;
            }
        }
        try testing.expect(saw_active);
        // (3) backtrace: clamp -> main (>= 2 frames), main at the call site line 21.
        try testing.expect(ctx.backtrace.len >= 2);
        try testing.expectEqualStrings("_clamp", ctx.backtrace[0].function.?);
        try testing.expectEqualStrings("_main", ctx.backtrace[1].function.?);
        try testing.expectEqual(@as(u32, 21), ctx.backtrace[1].line); // the clamp(300,..) CALL site
        // (4) locals: clamp's v/lo/hi/r all present in the same body.
        try testing.expect(varInList(ctx.locals, "v") != null);
        try testing.expect(varInList(ctx.locals, "lo") != null);
        try testing.expect(varInList(ctx.locals, "hi") != null);
        try testing.expect(varInList(ctx.locals, "r") != null);
        try testing.expectEqualStrings("300 (0x12C)", varInList(ctx.locals, "v").?.value);

        try testing.expectEqual(cyc_before, (try s.status()).cycles); // NOT one cycle charged

        // Capture the raw context body over HTTP for the byte-identity determinism compare.
        const r = try s.requestRaw(.GET, "/api/dbg/context", null);
        try testing.expectEqual(std.http.Status.ok, r.status);
        @memcpy(det_body[0..r.body.len], r.body);
        det_len = r.body.len;
    }

    // Determinism: a SECOND fresh session, same binary + same (empty) input, reaches the same
    // stop cycle and emits a BYTE-IDENTICAL context body.
    {
        var s = try spawn(threaded.io());
        defer s.deinit();
        {
            const m = try mcpCall(&s, "load", "{\"file\":\"BB.EXE\",\"source_path\":\"examples\"}");
            try testing.expect(!m.is_error);
        }
        _ = try mcpOk(&s, Bp, "set_source_breakpoint", "{\"file\":\"BB.C\",\"line\":9}");
        _ = try s.run(null);
        const r = try s.requestRaw(.GET, "/api/dbg/context", null);
        try testing.expectEqual(std.http.Status.ok, r.status);
        try testing.expectEqualStrings(det_body[0..det_len], r.body);
    }
}
