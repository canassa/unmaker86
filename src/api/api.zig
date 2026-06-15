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

// ---- the HTTP server (Phase 4) ----
pub const Server = server.Server;

test {
    _ = queue;
    _ = json_wire;
    _ = worker;
    _ = server;
    _ = @import("json_wire_test.zig");
    _ = @import("queue_test.zig");
    _ = @import("worker_test.zig");
    _ = @import("server_test.zig");
    _ = @import("determinism_test.zig");
}
