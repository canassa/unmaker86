//! `src/api/` — the HTTP/JSON API server (Milestone 2) layered over the M1
//! `Controller`. This is the module ROOT; it re-exports the public surface.
//!
//! Placement in the module graph (CLAUDE.md): `src/api/` sits ABOVE `debug` +
//! `machine` ("observes machine; never drives timing"). It imports `debug` (for
//! the `Controller` + the shared types) and `cpu` (for the `Reg32`/`Seg`/`Flags`
//! enums needed to decode register-set requests). NOTHING below `api` imports it.
//!
//! Determinism (CLAUDE prime directive + constraint #4): the emulation core stays
//! single-threaded. The HTTP listener runs on its own thread but NEVER touches the
//! machine — it enqueues a `Command` and blocks for the `Response`. A single
//! worker thread owns `*Controller`/`*Machine` and runs exactly one `Controller`
//! method per command. The guest advances ONLY inside a synchronous
//! `Controller.run*`/`step*` call; no host clock anywhere in the handoff. One
//! command in flight is enforced by MECHANISM (the queue asserts empty on submit),
//! not discipline. See the per-file headers for the cited 0.16 stdlib APIs.

const queue = @import("queue.zig");
const json_wire = @import("json_wire.zig");
const worker = @import("worker.zig");
const server = @import("server.zig");
const run_control = @import("run_control.zig");
const live_mouse = @import("live_mouse.zig");
const stream = @import("stream.zig");
const shared_frame = @import("shared_frame.zig");
const mcp = @import("mcp.zig");
const mcp_tools = @import("mcp_tools.zig");
const session_mod = @import("session.zig");
const session_registry = @import("session_registry.zig");
const snapshot_store_mod = @import("snapshot_store.zig");

// ---- the per-session bundle + the N-session registry (multi-machine plan §4, Phase 3) ----
pub const Session = session_mod.Session;
pub const SessionId = session_mod.SessionId;
pub const SessionRegistry = session_registry.SessionRegistry;
pub const SnapshotStore = snapshot_store_mod.SnapshotStore;

// ---- the command queue + handoff (Phase 2) ----
pub const Command = queue.Command;
pub const Response = queue.Response;
pub const CommandQueue = queue.CommandQueue;
pub const RequestCtx = queue.RequestCtx;
pub const MAX_MEM_CHUNK = queue.MAX_MEM_CHUNK;
pub const MAX_STACK_WORDS = queue.MAX_STACK_WORDS;
pub const QUEUE_CAP = queue.QUEUE_CAP;

// ---- the wire format (Phase 1) ----
pub const wire = json_wire;

// ---- the worker drain loop (Phase 3) ----
pub const drainOne = worker.drainOne;
pub const Worker = worker.Worker;
pub const MountSource = worker.MountSource;

// ---- the HTTP server (Phase 4) ----
pub const Server = server.Server;
pub const LoadRecipe = server.LoadRecipe;

// ---- run-ownership arbitration + the clockless pacer arm flag (stream §5) ----
// The host-side pacer (`src/host/run_pacer.zig`) drives the paced free-run loop; it
// flips/polls THIS clockless control block (no host clock here — see §5.1a).
pub const RunControl = run_control.RunControl;
pub const RunOwner = run_control.RunOwner;
pub const StopTag = run_control.StopTag;

// ---- the live coalesced mouse ingest record (plans/mouse-input.md, LOCKED §1) ----
// Host-side ARRIVAL state (NOT machine state, NOT snapshotted). The mouse POST handler
// folds each move in non-blocking; the pacer drains it at the slice boundary via
// `input_mouse_fold` → `Controller.injectMouseSeamless`.
pub const LiveMouseState = live_mouse.LiveMouseState;

// ---- the live video stream (Phase 3): shared latest-frame + per-conn threads ----
// All host-side observation through the gated queue (cycle-neutral peek). The host
// pacer drives the producer via `StreamHub.produceFrame` each fps tick.
pub const StreamHub = stream.StreamHub;
pub const SharedFrame = shared_frame.SharedFrame;
pub const stream_wire = shared_frame; // the §6.3 wire-protocol helpers (writeHeader, flags)

test {
    _ = queue;
    _ = json_wire;
    _ = worker;
    _ = server;
    _ = run_control;
    _ = live_mouse;
    _ = stream;
    _ = shared_frame;
    _ = mcp;
    _ = mcp_tools;
    _ = session_mod;
    _ = session_registry;
    _ = snapshot_store_mod;
    _ = @import("json_wire_test.zig");
    _ = @import("snapshot_store_test.zig");
    _ = @import("queue_test.zig");
    _ = @import("worker_test.zig");
    _ = @import("server_test.zig");
    _ = @import("determinism_test.zig");
    _ = @import("png_test.zig");
    _ = @import("run_control_test.zig");
    _ = @import("stream_test.zig");
    _ = @import("mcp_test.zig");
    _ = @import("session_registry_test.zig");
    _ = @import("concurrency_stress_test.zig");
}
