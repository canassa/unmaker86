//! The command queue + the threaded handoff (M2 §A.2/§A.3). This is where the
//! determinism-critical "one command in flight" mechanism lives.
//!
//! Two threads, one queue:
//!   - the LISTENER thread builds a `Command`, `submit()`s it, and BLOCKS for the
//!     `Response`. It never touches the machine.
//!   - the WORKER thread (sole owner of `*Controller`/`*Machine`) `tryDequeue`s one
//!     command, runs exactly one `Controller` method, fills the `Response`, and
//!     signals the request's completion condition.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `std.Io.Mutex` (`Io.zig:1587`): `lockUncancelable(io)` (`:1623`),
//!     `unlock(io)` (`:1641`). No time-out variant — there is no clock in the handoff.
//!   - `std.Io.Condition` (`Io.zig:1653`): `waitUncancelable(io, &mutex)` (`:1675`),
//!     `signal(io)` (`:1726`). The `done` flag is read/written ONLY under the mutex,
//!     and the wait is a PREDICATE `while (!done)` loop (lost/spurious-wakeup safe).
//!
//! Determinism (constraint #4): the guest advances ONLY inside the single
//! `Controller.run*`/`step*` call on the worker thread (that call reads no host
//! clock). The listener's timing affects only how long the HTTP response takes to
//! come back — never which instructions ran or in what order. `Command`/`Response`
//! are pointer-free, host-time-free POD (reflection-tested in determinism_test.zig).

const std = @import("std");
const debug = @import("debug");
const cpu_mod = @import("cpu");

const Io = std.Io;

const BreakpointKind = debug.BreakpointKind;
const StopReason = debug.StopReason;
const CpuSnapshot = debug.CpuSnapshot;
const Region = debug.Region;
const Reg32 = cpu_mod.Reg32;
const Seg = cpu_mod.Seg;
const Reg16 = debug.Reg16;
const Reg8 = debug.Reg8;
const Flags = cpu_mod.Flags;
const json_wire = @import("json_wire.zig");

/// Bounded memory chunk per command (mirrors Spice86's 1-4096 `read_memory` cap).
/// A request larger than this is rejected at the handler BEFORE enqueue — never a
/// heap alloc on the hot path.
pub const MAX_MEM_CHUNK = 4096;
/// Bounded `peekStack` word count (per-slot scratch size).
pub const MAX_STACK_WORDS = 256;
/// The fixed ring depth (M1 §6 pin; power of two). With one-in-flight enforced the
/// ring is effectively 1-deep, but the masked-index shape generalizes to MPSC later
/// without a rewrite.
pub const QUEUE_CAP = 8;
const QUEUE_MASK = QUEUE_CAP - 1;

comptime {
    std.debug.assert(QUEUE_CAP & QUEUE_MASK == 0); // power of two
}

// ===========================================================================
// Command — exactly one per supported endpoint operation (§A.2). Pointer-free.
// Byte payloads for mem_write live in the owning `RequestCtx`'s scratch buffer.
// ===========================================================================

pub const Command = union(enum) {
    run: struct { cycle_cap: u64 },
    run_to_cycle: struct { cycle: u64 },
    run_to_address: struct { linear: u32 },
    step: void,
    step_n: struct { n: u64 },
    step_over: void,
    add_bp: struct { kind: BreakpointKind, one_shot: bool },
    remove_bp: struct { id: u32 },
    clear_bp: void,
    enable_bp: struct { id: u32, on: bool },
    get_bp: struct { id: u32 },
    list_bp: void,
    cpu_get: void,
    reg_set: RegSetCmd,
    mem_peek: struct { phys: u32, len: u32 },
    /// `len` bytes to write live in `RequestCtx.scratch[0..len]` (copied there by
    /// the handler before submit). Pointer-free: the queue only carries the length.
    mem_write: struct { phys: u32, len: u32 },
    /// Logical `seg:off` peek/write — resolved to a linear address ON THE WORKER
    /// (reading `seg_base` off-worker would be a torn-read race; A.3a). Bytes for
    /// the write live in `RequestCtx.scratch[0..len]`.
    mem_peek_seg: struct { seg: Seg, off: u32, len: u32 },
    mem_write_seg: struct { seg: Seg, off: u32, len: u32 },
    ivt_get: struct { vector: u8 },
    stack_get: struct { count: u16 },
    /// Inject a keyboard scancode at the 8042 controller + raise IRQ1 (Model A,
    /// input-injection.md §4.1). Pointer-free POD: the `char`→scancode(s)
    /// resolution over the real set-1 table is done at the HANDLER, so the queue
    /// carries only the resolved make scancode + flags.
    ///   - precise edge: `press=false` injects a single edge — `make` true = key-
    ///     down (raw code), false = key-up (break = code|0x80); `ext` = 0xE0 prefix.
    ///   - full keystroke: `press=true` (the `{"char"}` convenience) injects the
    ///     make THEN the break as one deterministic command; `shift` brackets it
    ///     with a left-Shift make/break (the resolved "scancode(s)" of a shifted
    ///     char). All edges go through the controller in one worker step.
    input_key: struct { scancode: u8, make: bool, ext: bool, press: bool, shift: bool },
    /// Inject a mouse event into the INT 33h driver state (Model A,
    /// input-injection.md §5.2). Pointer-free POD: the wire→resolved mapping
    /// (mutual-exclusion check + defaults) is done at the HANDLER; the queue
    /// carries the fully-resolved `MouseInject` (absolute x/y, relative dx/dy,
    /// buttons, each gated by a `set_*` flag).
    input_mouse: debug.MouseInject,
    /// Read the guest's accumulated CON (stdout/stderr) output — what the program
    /// has printed so far. Side-effect-free (no clear-on-read); the worker copies the
    /// device buffer into the response POD.
    console_get: void,
    status: void,
    reset: void,
    load: LoadCmd,
    mem_regions: void,
    /// The worker-shutdown sentinel: the worker loop exits when it dequeues this.
    shutdown_worker: void,
};

/// A fully-resolved register-set command (the string name was validated + mapped to
/// a typed enum at the handler; the queue carries no strings). `value` is the raw
/// value already range-checked to the target width at the handler.
pub const RegSetCmd = union(enum) {
    reg32: struct { reg: Reg32, value: u32 },
    reg16: struct { reg: Reg16, value: u16 },
    reg8: struct { reg: Reg8, value: u8 },
    seg: struct { seg: Seg, value: u16 },
    eip: struct { value: u32 },
    flags: Flags,
};

/// A resolved load command (`drive` + a fixed-capacity copy of `file`/`cmdtail`,
/// so the queue carries no borrowed slices). The handler fills these from the
/// `LoadReq` (or the server-held startup recipe) before submit.
pub const LoadCmd = struct {
    drive: u8,
    file_len: u8,
    file: [13]u8 = undefined, // DOS 8.3 + dot + NUL room
    cmdtail_len: u8,
    cmdtail: [127]u8 = undefined,
};

// ===========================================================================
// Response — the worker's typed result (§A.2). Pointer-free, host-time-free POD.
// Memory/stack/list payloads are carried inline as fixed arrays + a length.
// ===========================================================================

/// A stable, transport-INDEPENDENT error code (D20). The `code → HTTP status` map
/// lives only in `server.zig`; the M3 MCP layer reuses these same codes.
pub const ErrCode = enum {
    breakpoint_table_full,
    no_such_breakpoint,
    address_out_of_range,
    out_of_range,
    bad_request,
    not_implemented,
    load_failed,
    /// The 8042 output FIFO is full — a transient resource limit (input-injection.md
    /// §5.1b). Surfaced as HTTP 503 (the `breakpoint_table_full` idiom); the client
    /// can `run` to let the INT 09h ISR drain the controller, then retry.
    input_buffer_full,
};

pub const MemResult = struct {
    phys: u32,
    len: u32,
    bytes: [MAX_MEM_CHUNK]u8 = undefined,
};

pub const StackResult = struct {
    count: u16,
    words: [MAX_STACK_WORDS]u16 = undefined,
};

pub const BpListResult = struct {
    count: u32 = 0,
    items: [debug.MAX_BREAKPOINTS]json_wire.WireBreakpoint = undefined,
};

/// The guest's accumulated CON output, copied inline (the CON device's capture
/// buffer is 4096 bytes — `src/dos/devices.zig` `CharDevice.out_buf`). Pointer-free
/// POD: the worker copies the device buffer here so server.zig never reads machine
/// state off-worker (§A.3a).
pub const MAX_CONSOLE = 4096;
pub const ConsoleResult = struct {
    len: u32 = 0,
    bytes: [MAX_CONSOLE]u8 = undefined,
};

pub const StatusResult = struct {
    runnable: bool,
    terminated: bool,
    ret_code: u16,
    cycles: u64,
    last_stop: ?StopReason,
};

pub const StepOverResult = struct {
    reason: StopReason,
    stepped_into: bool,
};

pub const IvtResult = struct { vector: u8, ip: u16, cs: u16 };

/// The static peekable region table, copied inline so server.zig never reads
/// `ctrl.memoryRegions()` off-worker (keeps the §A.3a off-worker grep clean).
pub const MAX_REGIONS = 8;
pub const RegionsResult = struct {
    count: u8 = 0,
    items: [MAX_REGIONS]Region = undefined,
};

pub const Response = union(enum) {
    /// `{"ok":true}` — reset/load/enable/remove/clear (clear carries a count).
    ok: void,
    stop: StopReason,
    step_over: StepOverResult,
    bp_id: u32, // add_bp
    bp_one: json_wire.WireBreakpoint, // get_bp
    bp_list: BpListResult, // list_bp
    cleared: u32, // clear_bp removed count
    cpu: CpuSnapshot,
    mem: MemResult, // mem_peek
    mem_written: struct { phys: u32, len: u32 }, // mem_write
    ivt: IvtResult,
    stack: StackResult,
    status: StatusResult,
    console: ConsoleResult,
    regions: RegionsResult,
    /// A typed error. The handler maps `code` → HTTP status.
    err: ErrCode,
};

// ===========================================================================
// RequestCtx — one per in-flight request, owned by the listener thread for the
// lifetime of the call. Holds the command, the response slot, the per-request
// completion condition, and the `done` flag + the mem_write scratch buffer.
// ===========================================================================

pub const RequestCtx = struct {
    cmd: Command,
    response: Response = .ok,
    cond: Io.Condition = .init,
    done: bool = false,
    /// mem_write payload (bytes to write); the command carries only the length.
    scratch: [MAX_MEM_CHUNK]u8 = undefined,
};

// ===========================================================================
// CommandQueue — the fixed-array masked-index ring + the mutex/condvar handoff.
// ===========================================================================

pub const CommandQueue = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// Worker wakes on this when a command is enqueued.
    work_ready: Io.Condition = .init,
    ring: [QUEUE_CAP]?*RequestCtx = @splat(null),
    head: usize = 0, // worker dequeues here
    tail: usize = 0, // producer enqueues here

    pub fn init(io: Io) CommandQueue {
        return .{ .io = io };
    }

    /// Producer side: enqueue `ctx` and BLOCK until the worker completes it,
    /// returning the filled `Response`. The "one command in flight" mechanism: after
    /// taking the mutex we ASSERT the queue is empty — a second concurrent producer
    /// (impossible in v1's single-listener/one-connection design) would trip this in
    /// a debug build, surfacing a regression instead of silently smearing ordering.
    pub fn submit(self: *CommandQueue, ctx: *RequestCtx) Response {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        // Mechanism, not discipline: at most one command in flight.
        std.debug.assert(self.head == self.tail);
        ctx.done = false;
        self.ring[self.tail & QUEUE_MASK] = ctx;
        self.tail +%= 1;
        self.work_ready.signal(io);
        // Predicate while-loop (lost/spurious-wakeup safe). `done` is read only
        // under the mutex.
        while (!ctx.done) ctx.cond.waitUncancelable(io, &self.mutex);
        const resp = ctx.response;
        self.mutex.unlock(io);
        return resp;
    }

    /// Worker side: block until a command is available, then return it (still under
    /// the mutex's protection only for the dequeue — the worker runs `drainOne`
    /// OUTSIDE the lock so a long run does not hold the queue mutex). The worker
    /// calls `complete()` afterward to publish the response.
    pub fn waitDequeue(self: *CommandQueue) *RequestCtx {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        while (self.head == self.tail) self.work_ready.waitUncancelable(io, &self.mutex);
        const ctx = self.ring[self.head & QUEUE_MASK].?;
        self.ring[self.head & QUEUE_MASK] = null;
        self.head +%= 1;
        self.mutex.unlock(io);
        return ctx;
    }

    /// Worker side: publish `resp` into `ctx` and wake the waiting producer. The
    /// `done` flag is set under the mutex, then the request's condition is signaled
    /// (the producer re-checks the predicate on wake).
    pub fn complete(self: *CommandQueue, ctx: *RequestCtx, resp: Response) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        ctx.response = resp;
        ctx.done = true;
        ctx.cond.signal(io);
        self.mutex.unlock(io);
    }
};
