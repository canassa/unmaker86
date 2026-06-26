//! The JSON-RPC 2.0 / MCP envelope codec (M3, mcp-plan.md §2) — PURE: only `std`,
//! no `Server`, no `debug`/machine import. It frames the `POST /mcp` request/reply
//! envelope; the tool catalog + the args→`Command` mapping live in `mcp_tools.zig`,
//! and the only `Server`-touching orchestration lives in `server.zig:handleMcp`.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `std.json.parseFromSliceLeaky(Value, arena, body, opts)` (`json/static.zig:88`)
//!     parses the whole request body into a `std.json.Value` tree; the caller then
//!     walks the object map (the JSON-RPC `id` is a BARE scalar — number|string —
//!     which std.json's tagged-union decoding cannot map onto a Zig `union(enum)`,
//!     so we extract the envelope fields from the `Value` directly rather than
//!     `parseFromValueLeaky` into a struct; correction to the plan's §2 sketch).
//!   - `std.json.Stringify.encodeJsonString(s, opts, w)` (`json/Stringify.zig:670`)
//!     emits `s` as a properly escaped JSON string — used to embed the inner tool
//!     body (itself JSON text) into the `content[].text` field, and to echo a string
//!     `id`. `std.json.Stringify.value` (`:573`) emits the standard struct/scalar JSON.
//!
//! Determinism (CLAUDE prime directive): this file does pure JSON string work — no
//! host time, no RNG, no float in any emitted byte, no allocation on the write path.
//! The MCP session id is a fixed literal constant (NOT `getrandom`), so the api
//! determinism grep-gate stays green with no carve-out (mcp-plan.md §11 R7). The grep
//! over this source is wired in `determinism_test.zig` (§3.6).

const std = @import("std");

/// The MCP protocol revision this server speaks (mcp-plan.md §11 R5). Echoed back on
/// `initialize`; a pure string compare, no negotiation logic in Phase 1.
pub const PROTOCOL_VERSION = "2025-06-18";
pub const SERVER_NAME = "zdos";
pub const SERVER_VERSION = "0.1.0";

/// The single, FIXED session id (mcp-plan.md §11 R7, RESOLVED). There is one global
/// machine in Phase 1, so the id is a literal constant — never `getrandom` — which
/// keeps the determinism grep-gate green with no carve-out. `handleMcp` echoes this
/// on the `initialize` reply; the session-resolver seam (Server.resolveSession) maps
/// any/blank `Mcp-Session-Id` to the one instance. Model B (a per-session registry)
/// is a later extension of the seam, not a rewrite.
pub const SESSION_ID = "zdos-mcp-singleton";
pub const SESSION_HEADER = "mcp-session-id";

/// JSON-RPC 2.0 reserved error codes (the protocol-level "could not dispatch" set,
/// mcp-plan.md §6.2). An emulator-domain failure AFTER a successful dispatch is NOT
/// one of these — it is a tool `result` with `isError:true` (see `server.zig`).
pub const RpcError = enum(i32) {
    parse = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal = -32603,
};

/// A JSON-RPC request `id`. JSON-RPC allows a string OR a number; a fractional number
/// is rejected upstream (R6 — keeps non-integers out of our emitted bytes), and
/// `number_string` carries an integer too large for `i64` verbatim so it round-trips
/// losslessly (the same lossless-large-integer treatment json_wire uses for cycles).
pub const Id = union(enum) {
    int: i64,
    num_str: []const u8,
    str: []const u8,
};

/// Map a `std.json.Value` to an `Id`, or `null` if it is not a legal JSON-RPC id
/// shape (float/bool/object/array/null). The caller treats `null` on a PRESENT,
/// non-null id field as a malformed request (`-32600`, R6).
pub fn parseId(v: std.json.Value) ?Id {
    return switch (v) {
        .integer => |n| .{ .int = n },
        .number_string => |s| .{ .num_str = s },
        .string => |s| .{ .str = s },
        else => null,
    };
}

// ===========================================================================
// Writers — emit into a caller-supplied `*std.Io.Writer` (the `writeX` style used
// throughout server.zig). No allocation, no host time.
// ===========================================================================

/// Echo an `id`: integer → JSON number, `number_string` → verbatim digits, string →
/// escaped JSON string. Absent/`null` → the JSON literal `null` (per JSON-RPC, an
/// error reply with an unparseable id carries `id:null`).
pub fn writeId(w: *std.Io.Writer, id: ?Id) std.Io.Writer.Error!void {
    if (id) |x| switch (x) {
        .int => |n| try w.print("{d}", .{n}),
        .num_str => |s| try w.writeAll(s),
        .str => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
    } else {
        try w.writeAll("null");
    }
}

/// The leading frame of a SUCCESS reply: `{"jsonrpc":"2.0","id":<id>,"result":`. The
/// caller writes the `result` VALUE next (a tool-call `content` object, the
/// `initialize` capabilities object, or the `tools/list` object), then `writeResultSuffix`.
pub fn writeResultPrefix(w: *std.Io.Writer, id: ?Id) std.Io.Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":");
}

pub fn writeResultSuffix(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("}");
}

/// A complete JSON-RPC error envelope:
/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":<n>,"message":<msg>}}`. Used ONLY for
/// protocol-level failures (parse/invalid-request/method-not-found/invalid-params/
/// internal) — an emulator ErrCode is reported as an `isError` tool result instead.
pub fn writeErrorEnvelope(w: *std.Io.Writer, id: ?Id, code: RpcError, msg: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{@intFromEnum(code)});
    try std.json.Stringify.encodeJsonString(msg, .{}, w);
    try w.writeAll("}}");
}

test "writeId echoes the three legal shapes and null" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeId(&w, .{ .int = 7 });
    try std.testing.expectEqualStrings("7", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeId(&w, .{ .str = "abc" });
    try std.testing.expectEqualStrings("\"abc\"", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeId(&w, .{ .num_str = "18446744073709551615" });
    try std.testing.expectEqualStrings("18446744073709551615", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try writeId(&w, null);
    try std.testing.expectEqualStrings("null", w.buffered());
}

test "writeErrorEnvelope frames code + message" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeErrorEnvelope(&w, .{ .int = 9 }, .method_not_found, "unknown method: nope");
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"unknown method: nope\"}}",
        w.buffered(),
    );
}

test "parseId rejects float and bool ids (R6)" {
    try std.testing.expect(parseId(.{ .float = 1.5 }) == null);
    try std.testing.expect(parseId(.{ .bool = true }) == null);
    try std.testing.expect(parseId(.null) == null);
    try std.testing.expect(parseId(.{ .integer = 3 }).? == .int);
}
