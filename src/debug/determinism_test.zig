//! Determinism audit for `src/debug/` (M1 §4 #14). The grep gate forbids host
//! time / RNG / threads / env / floats AND (new for the debug layer) HashMap /
//! unordered iteration (constraint #5) and atomics (M2 threading must never feed
//! back into emulation timing/ordering, constraint #4). The reflection gate
//! asserts the POD + StopReason types contain no pointer-typed fields, so no
//! ASLR'd pointer can leak into a snapshot or M2 JSON.

const std = @import("std");
const debug = @import("debug.zig");

test "no host time / RNG / thread / env / float / hashmap / atomic in src/debug (grep)" {
    const sources = [_][]const u8{
        @embedFile("debug.zig"),
        @embedFile("breakpoints.zig"),
        @embedFile("controller.zig"),
        // The host-side, load-time TDS symbol overlay (Tier 1). Pure function of the
        // EXE bytes; must stay free of host time/RNG/threads/HashMap/atomics/floats so
        // it produces byte-identical indices for identical input (CLAUDE.md §1).
        @embedFile("symbols/format.zig"),
        @embedFile("symbols/tds.zig"),
        @embedFile("symbols/index.zig"),
        @embedFile("symbols/types.zig"),
        @embedFile("symbols/map.zig"),
        @embedFile("symbols/mapfile.zig"),
        // The module root + owning façade — keep it on the gate so it can't silently
        // grow a host dependency (B).
        @embedFile("symbols/symbols.zig"),
    };
    const forbidden = [_][]const u8{
        "std.time",
        "std.Random",
        "std.rand",
        "std.Thread",
        "std.posix.getenv",
        "std.process.getEnv",
        "std.os.getenv",
        // No floats anywhere in the control core (CLAUDE #2 — emulated time is a
        // function of the cycle counter, never a float).
        "f32",
        "f64",
        // No unordered containers (constraint #5: unordered iteration order is
        // nondeterministic and could leak into a result / M2 JSON).
        "HashMap",
        "hash_map",
        "AutoHashMap",
        // No atomics (constraint #4: M2 may thread the server, but the control
        // core must never feed host scheduling back into emulation ordering).
        "std.atomic",
        "@atomic",
        // No threading primitives either (extended for M2, §D #2): the API server
        // may use std.Thread / std.Io.Mutex / std.Io.Condition, but the
        // single-threaded control core must never import them — that would be host
        // scheduling feeding into emulation ordering.
        "std.Io.Mutex",
        "std.Io.Condition",
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a src/debug source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

test "POD + StopReason types contain no pointer-typed fields (#14 reflection)" {
    try expectNoPointerFields(debug.Breakpoint);
    try expectNoPointerFields(debug.BreakpointSet);
    try expectNoPointerFields(debug.BreakpointKind);
    try expectNoPointerFields(debug.StopReason);
    try expectNoPointerFields(debug.CpuSnapshot);
    try expectNoPointerFields(debug.StepOverResult);
    // The symbol-layer lookup-result PODs hold only integers (sym/segment/offset/
    // line/file ids) — never a borrowed name pointer that could leak a host address
    // into a snapshot or the M2 JSON (plan §8.3).
    try expectNoPointerFields(debug.symbols.SymRef);
    try expectNoPointerFields(debug.symbols.FuncRef);
    try expectNoPointerFields(debug.symbols.LineHit);
    try expectNoPointerFields(debug.symbols.ImageAddr);
    // Tier-2 result PODs: the type-walk / member-layout / enumerator / scope-local
    // views hold only integers + enums (names as 1-based name_index'es), so no host
    // address can leak into a snapshot or the M2 JSON (plan §8.3 reflection gate).
    try expectNoPointerFields(debug.symbols.TypeInfo);
    try expectNoPointerFields(debug.symbols.MemberInfo);
    try expectNoPointerFields(debug.symbols.EnumeratorInfo);
    try expectNoPointerFields(debug.symbols.Local);
    try expectNoPointerFields(debug.symbols.Storage);
}

/// Recursively assert a type (and its struct/union/optional/array fields) has no
/// pointer field. Slices/many-pointers are `.pointer` too, so this also rejects
/// any `[]T`.
fn expectNoPointerFields(comptime T: type) !void {
    switch (@typeInfo(T)) {
        .pointer => return error.PointerFieldFound,
        .@"struct" => |s| inline for (s.fields) |f| try expectNoPointerFields(f.type),
        .@"union" => |u| inline for (u.fields) |f| try expectNoPointerFields(f.type),
        .optional => |o| try expectNoPointerFields(o.child),
        .array => |a| try expectNoPointerFields(a.child),
        else => {},
    }
}
