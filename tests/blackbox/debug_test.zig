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
