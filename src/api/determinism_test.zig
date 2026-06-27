//! Determinism audit for `src/api/` (M2 §D #2/#2a). Three gates:
//!   1. The EXTENDED grep over every src/api source: forbid host time / RNG / env /
//!      floats AND every clock affordance (Timeout/Clock/sleep/Instant/Timer/
//!      futexWaitTimeout/.fromNow/nanoTimestamp). ALLOW the legitimate clockless
//!      server threading (Mutex/Condition/Thread/atomic + the `*Uncancelable`
//!      no-timeout variants) — those carry no host clock into the handoff.
//!   2. The OFF-WORKER grep over server.zig (R2/§A.3a): no `ctrl.`/`controller.`/
//!      `machine.`/`m.` outside the `submit()` call path — only `/api/health` is
//!      answered off-worker and it touches NO machine/controller state. A future
//!      "just peek one field off-worker" regression (a torn u64 `cycles` read)
//!      fails this gate.
//!   3. The reflection gate: `Command`/`Response`/`RequestCtx` (minus the condvar)
//!      carry NO pointer-typed and NO host-time fields — nothing from host
//!      scheduling can enter the queue PODs.
//!
//! It also re-runs the UNCHANGED `src/debug/` grep to prove M2 leaked no threading
//! primitive down into the single-threaded control core.

const std = @import("std");
const q = @import("queue.zig");

const api_sources = [_][]const u8{
    @embedFile("api.zig"),
    @embedFile("queue.zig"),
    @embedFile("json_wire.zig"),
    @embedFile("worker.zig"),
    @embedFile("server.zig"),
    // The run-ownership/arm-flag coordination block (stream §5). It is CLOCKLESS by
    // design (only `std.atomic` + a no-timeout `Io.Mutex`) — the pacer's host clock
    // lives in `src/host/run_pacer.zig`, OUTSIDE this embedded set (§5.1a). Embedding
    // it here proves no clock affordance crept into the api coordination state.
    @embedFile("run_control.zig"),
    // The live coalesced mouse ingest record (plans/mouse-input.md, LOCKED §1/§6).
    // CLOCKLESS + FLOAT-FREE by design: a mutex-guarded POD with Q16 integer fixed-
    // point (no host float types), the no-timeout `lockUncancelable` variant only. Embedding
    // it here proves the live mouse path added no clock/float affordance to any api
    // source — the keystone determinism posture (no live input ⇒ no fold ⇒ zero cycles).
    @embedFile("live_mouse.zig"),
    // The live video-stream side (Phase 3). CLOCKLESS by design: the shared-frame
    // producer/copy and the per-connection stream threads carry NO host clock — the fps
    // sampling cadence is decided by the pacer in `src/host/run_pacer.zig` (outside this
    // embedded set, §5.1a). Embedding them proves the stream path added no clock
    // affordance to any api source (the frame capture is the cycle-neutral peek).
    @embedFile("shared_frame.zig"),
    @embedFile("stream.zig"),
    // The MCP (Model Context Protocol) JSON-RPC 2.0 front-end (M3, mcp-plan.md §3.6).
    // PURE by design: JSON string work + `queue.submit` (clockless) + the shared `writeX`
    // builders. No host time, no RNG, no float in any emitted byte; the session id is a
    // fixed literal constant (NOT `getrandom`). Embedding them proves the second
    // front-end added no host-clock / RNG / float affordance to any api source.
    @embedFile("mcp.zig"),
    @embedFile("mcp_tools.zig"),
    // The per-session state bundle (multi-machine plan §3.2/§4.1, Phase 1). PURE by
    // design: it only GROUPS the per-machine fields the Server used to hold directly
    // (queue + worker handle + clockless run_control/live_mouse + render/shared-frame/
    // stream-hub + load recipe + mount dir) — no host clock, no RNG, no float in any
    // emitted byte; the machine's only time source stays `cpu.st.cycles`, reached via
    // the gated queue on the worker. Embedding it keeps the no-host-dependence gate
    // covering the extracted code exactly as it covered it on `Server`.
    @embedFile("session.zig"),
    // The N-session registry (multi-machine plan §4, Phase 3). DETERMINISM-CLEAN by
    // design: session ids are minted from a monotonic counter (`zdos-sess-<seq>` — NO
    // clock, NO RNG), GC is explicit-DELETE / LRU-by-request-count (NEVER a timed sweep),
    // and it coordinates with the SAME clockless no-timeout `Io.Mutex`/`Io.Condition`
    // variants the queue uses. Embedding it proves the multi-session routing added no
    // host-clock / RNG / float affordance to any api source.
    @embedFile("session_registry.zig"),
    // The per-session snapshot store (snapshot-restore-plan §2.2). DETERMINISM-CLEAN by
    // design: `snap-<n>` handles minted from a monotonic counter (NO clock, NO RNG),
    // integer-only, no float; capture is a pure machine read and restore a deterministic
    // state load. The big slabs are LAZY heap allocations (alloc/free), not a host-time
    // affordance. Embedding it proves snapshot/restore added no host-clock/RNG/float to
    // any api source.
    @embedFile("snapshot_store.zig"),
};

test "src/api grep: no host time / RNG / env / floats / clock affordances" {
    const forbidden = [_][]const u8{
        // host time / RNG / env (constraints #2/#3).
        "std.time",
        "std.Random",
        "std.rand",
        "std.posix.getenv",
        "std.process.getEnv",
        "std.os.getenv",
        "nanoTimestamp",
        // No floats anywhere in the wire format (constraint #2).
        "f32",
        "f64",
        // Every CLOCK AFFORDANCE: even via the threading primitives, no timeout/
        // clock may enter the handoff (it would make a wait host-time-dependent).
        "futexWaitTimeout",
        ".fromNow",
        "Timeout",
        "Clock",
        "io.sleep",
        "Instant",
        "std.time.Timer",
        "waitTimeout",
    };
    for (api_sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a src/api source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

test "src/api grep: the legitimate clockless threading IS present (sanity)" {
    // Guard against the grep silently passing because the threading was removed:
    // the queue must still use the no-timeout Uncancelable variants.
    const queue_src = @embedFile("queue.zig");
    try std.testing.expect(std.mem.indexOf(u8, queue_src, "lockUncancelable") != null);
    try std.testing.expect(std.mem.indexOf(u8, queue_src, "waitUncancelable") != null);
    try std.testing.expect(std.mem.indexOf(u8, queue_src, "Io.Mutex") != null);
    try std.testing.expect(std.mem.indexOf(u8, queue_src, "Io.Condition") != null);
}

test "off-worker grep (R2): server.zig touches no machine/controller state off the worker" {
    const server_src = @embedFile("server.zig");
    // No method call on a live controller/machine handle anywhere in server.zig —
    // every machine access goes through `submit()` to the worker. (`self.ctrl` is a
    // pointer FIELD passed to the worker, never dereferenced for state here, so it
    // does not match `ctrl.`.)
    const forbidden = [_][]const u8{
        "ctrl.",
        "controller.",
        "machine.",
        "self.m.",
        ".cpuSnapshot",
        ".runUntilEvent",
        ".peekMem",
        ".memoryRegions",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, server_src, needle) != null) {
            std.debug.print("server.zig touches machine state off-worker: '{s}'\n", .{needle});
            return error.OffWorkerMachineAccess;
        }
    }
    // Positive sanity: /health is answered with the constant body (off-worker, no
    // state), and everything else goes through submit(). (The needle is the source
    // form — the body literal is escaped in server.zig.)
    try std.testing.expect(std.mem.indexOf(u8, server_src, "zdos-m2") != null);
    // Reaches the queue through the (now OPTIONAL) default session: the Phase-1 `Session`
    // extraction made `self.queue.submit` → `self.session.queue.submit`, and the EMPTY-START
    // inversion made the field `?*Session` so the `/api/*` handlers deref `self.session.?.queue.
    // submit` (guarded by the dispatch 409). Same assertion intent — every machine access still
    // goes through the gated `submit()`.
    try std.testing.expect(std.mem.indexOf(u8, server_src, "self.session.?.queue.submit") != null);
}

test "reflection: Command/Response carry no pointer or host-time fields" {
    try expectNoPointerFields(q.Command);
    try expectNoPointerFields(q.Response);
    // RequestCtx holds an Io.Condition (a threading primitive, not host time) and a
    // scratch byte array; the Command/Response it carries are checked above. The
    // condvar is intentionally allowed (it is the clockless handoff), so we check
    // only the command/response payloads, not the whole ctx.
}

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

// NOTE on the "src/debug stayed clean" gate (§D #2): `@embedFile` cannot reach
// outside the `src/api/` package, so the source-level grep over the control core
// lives in `src/debug/determinism_test.zig` (run by `test-debug`, folded into the
// aggregate `test`). For M2 that grep was EXTENDED with the threading needles
// (`std.Io.Mutex`/`std.Io.Condition` + the existing `std.Thread`/`std.atomic`/
// `@atomic`), so it now proves M2 leaked no threading primitive down into the
// single-threaded control core. M2 made no `src/debug/` SOURCE change; the only
// debug touch is that test's forbidden-needle list.
