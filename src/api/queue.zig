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
    /// A single paced free-run slice (video-stream §5). Identical to `.run` —
    /// `Controller.runUntilEvent(slice_cycles)`, a bounded deterministic run — but
    /// it is the command the host-side run-pacer (`src/host/run_pacer.zig`) submits
    /// each wall-clock tick. Kept distinct from `.run` so the pacer's slices are
    /// self-documenting on the wire and a future change to one path cannot silently
    /// alter the other. Pointer-free POD; returns the `StopReason` so the pacer can
    /// disarm on a terminal (program_terminated/shutdown/halted_forever).
    run_slice: struct { slice_cycles: u64 },
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
    /// Drain the coalesced LIVE-mouse record and fold it into the INT 33h driver
    /// (plans/mouse-input.md, LOCKED §1/§5). No payload — the worker reads the
    /// server-owned `*LiveMouseState` it holds (reached like `render`/`mount`, NOT via
    /// the Command, so the queue stays pointer-free). The pacer ALWAYS submits this
    /// each slice; the arm is a NO-OP (zero guest cycles, no `runUntilEvent`) unless
    /// `takeFold()` returns a dirty sample — the determinism keystone. When dirty it
    /// forwards PLAIN INTEGERS to `Controller.injectMouseSeamless` (the abs write +
    /// the true-relative mickeys + the AX=0Ch callback, each self-charging cycles).
    input_mouse_fold: void,
    /// Read the guest's accumulated CON (stdout/stderr) output — what the program
    /// has printed so far. Side-effect-free (no clear-on-read); the worker copies the
    /// device buffer into the response POD.
    console_get: void,
    /// Read the active VGA text page (B8000/B0000 cells) — the side-effect-free
    /// screen grid for `GET /api/screen`. A `void` command: the `?attrs=1` flag is
    /// parsed server-side and drives JSON serialization only (Finding 5), so the
    /// worker always fills the full cells buffer.
    screen_get: void,
    /// Capture the current VGA framebuffer (any mode) — the side-effect-free
    /// rasterizer peek for `GET /api/framebuffer` (plans/vga-spec/03 §3.5.3, B1). A
    /// `void` command: the `?format=index|rgba` flag is parsed server-side and selects
    /// which server-owned buffer is streamed; the worker always renders BOTH the index
    /// + RGBA into the server-owned render buffers and returns only the small
    /// `FramebufferResult` descriptor through the normal path (the large payload is
    /// streamed from the server buffer, NOT routed through `resp_buf`).
    framebuffer_get: void,
    status: void,
    /// Set the active CPU:PIT multiplier at the serialized worker-command boundary
    /// (Phase 3 of the live-CPU-clock work). Integer `mult` (NO float on the wire —
    /// the determinism grep-gate bans host floats); the handler validated/parsed it,
    /// the worker calls `Controller.setCpuMult(mult)` which CLAMPS to `[1, MAX_MULT]`
    /// and returns the APPLIED mult in the `.clock` response. A live change is a
    /// deterministic input applied at a precise cycle, exactly like `reset` — NOT the
    /// non-blocking live-mouse fold. Pointer-free POD.
    set_clock: struct { mult: u64 },
    /// Read the active CPU:PIT multiplier (the GET path). Cycle-neutral peek.
    clock_get: void,
    reset: void,
    load: LoadCmd,
    mem_regions: void,
    /// Disassemble a window of instructions (`GET /api/disasm`). The `origin`
    /// (linear / seg:off / CS:EIP) is resolved to a (seg_base, offset) ON THE
    /// WORKER — reading live CPU state off-worker would be a torn read. Pure
    /// peek path; cycle-neutral (charges no ledger cost). `count` is validated
    /// ≤ MAX_DISASM_INSNS at the handler.
    disasm: struct { origin: debug.DisasmOrigin, count: u16 },
    /// Side-effect-free chipset/A20/device snapshot (`GET /api/devices`). A `void`
    /// command: the `?palette=1` flag is parsed server-side and only widens the
    /// JSON (the worker always fills the DAC palette; the server nulls it when the
    /// flag is absent). Cycle-neutral, pure peek path.
    devices_get: void,
    /// The non-mutating shadow of one I/O port (`GET /api/io?port=N`). Pure
    /// per-port raw-field read; NEVER issues the mutating `in8`.
    io_shadow: struct { port: u16 },
    /// Search the guest RAM slab for a byte needle (`GET /api/mem/search`). The
    /// needle BYTES live in `RequestCtx.scratch[0..needle_len]` (decoded by the
    /// handler before submit, like `mem_write`); the command carries only the
    /// length + window. Pure peek path; cycle-neutral.
    mem_search: MemSearchCmd,
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

/// Max match addresses a single `/api/mem/search` returns (the result cap).
pub const MAX_SEARCH_HITS = 256;
/// Max needle length (bytes). Bounded by the per-request scratch buffer.
pub const MAX_SEARCH_NEEDLE = MAX_MEM_CHUNK;

/// A resolved memory-search command. Pointer-free POD: the needle bytes live in
/// `RequestCtx.scratch[0..needle_len]`; this carries the window + lengths.
pub const MemSearchCmd = struct {
    start: u32,
    len: u32, // 0 => "to slab end" (resolved/clamped on the worker)
    needle_len: u16,
    max: u16, // 0 => MAX_SEARCH_HITS (resolved on the worker)
};

pub const SearchResult = struct {
    start: u32,
    len: u32, // the clamped haystack length actually scanned
    needle_len: u16,
    count: u16,
    truncated: bool,
    hits: [MAX_SEARCH_HITS]u32 = undefined, // phys addresses; seg/off derived at serialize
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

/// The active text page's cell grid, copied inline (80x25x2 = 4000 bytes of flat
/// {char,attr} cells). Pointer-free POD: the worker fills `cells` from
/// `Controller.screen(...)` so server.zig never reads machine state off-worker.
pub const MAX_SCREEN_CELLS = 80 * 25 * 2; // 4000
pub const ScreenResult = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    mode: u8 = 0,
    active_page: u8 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    len: u32 = 0, // valid bytes in `cells` (= cols*rows*2)
    cells: [MAX_SCREEN_CELLS]u8 = undefined,
};

/// The framebuffer-capture descriptor (B1) — a SMALL POD returned through the normal
/// path. The large index/RGBA payloads are NOT here: the worker renders them into the
/// server-owned render buffers (reached via the worker's `*RenderBuffers`, not the
/// Command), and the server streams the selected buffer as a raw binary body.
pub const FramebufferResult = struct {
    kind: debug.FramebufferKind = .unsupported,
    width: u16 = 0,
    height: u16 = 0,
    index_len: u32 = 0,
    rgba_len: u32 = 0,
    double_scan: bool = false,
    row_repeat: u8 = 1,
    /// False => no faithful rasterizer for the current mode; the server replies 501
    /// rather than streaming a wrong frame (no fake).
    supported: bool = false,
    /// True iff the worker filled the server-owned expanded-palette slab (the indexed-
    /// PNG PLTE source). True whenever `supported` for the current rasterizers.
    palette_present: bool = false,
    /// The live VGA `pel_mask`; the indexed-PNG path applies it to each index so the
    /// PLTE lookup matches the RGBA peek (§3.3). 0xFF for BaK/TTM (a no-op).
    pel_mask: u8 = 0xFF,
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
    /// The applied CPU:PIT multiplier (`set_clock` / `clock_get`). The server derives
    /// the displayed ≈MHz + the pacer slice from this integer (no float on the wire).
    clock: u64,
    mem: MemResult, // mem_peek
    mem_written: struct { phys: u32, len: u32 }, // mem_write
    ivt: IvtResult,
    stack: StackResult,
    status: StatusResult,
    console: ConsoleResult,
    screen: ScreenResult,
    /// The framebuffer-capture descriptor; pixels live in the server render buffers.
    framebuffer: FramebufferResult,
    regions: RegionsResult,
    /// A disassembly window (`/api/disasm`). Pointer-free POD filled by the worker.
    disasm: debug.DisasmResult,
    /// A chipset/A20/device snapshot (`/api/devices`). Pointer-free POD.
    devices: debug.DevicesSnapshot,
    /// A single I/O-port shadow (`/api/io`). Pointer-free POD.
    io_shadow: debug.IoShadow,
    /// A memory-search result (`/api/mem/search`). Pointer-free POD.
    search: SearchResult,
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
    /// The SUBMIT-GATE (video-stream §5/§9, the multi-producer correctness fix).
    /// Held by a producer for the ENTIRE submit-and-wait, so concurrent host
    /// producers (the run-pacer, a frame producer, per-connection input) strictly
    /// SERIALIZE. Without it the internal `mutex` is RELEASED by the condvar
    /// `waitUncancelable` below — letting a second producer acquire `mutex` in that
    /// window and trip the `head==tail` assert (`submit`), since the one-in-flight
    /// invariant is NOT multi-producer-safe by itself. With the gate, exactly one
    /// producer is ever inside `submit` at a time → the assert + the one-in-flight
    /// invariant hold BY CONSTRUCTION. No timeout (`*Uncancelable`, clockless), so
    /// the determinism grep-gate is unaffected. Single-producer callers are
    /// unchanged: an uncontended gate lock/unlock is a single CAS pair.
    submit_gate: Io.Mutex = .init,
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
    /// taking the mutex we ASSERT the queue is empty — with the SUBMIT-GATE held
    /// across the whole call (taken first here, released last), only one producer is
    /// ever inside this body, so the assert holds even with multiple host producers
    /// (the run-pacer, frame producer, per-connection input). The gate is what makes
    /// concurrent producers safe: the internal condvar wait below RELEASES `mutex`,
    /// so without the gate a second producer could race the assert.
    pub fn submit(self: *CommandQueue, ctx: *RequestCtx) Response {
        const io = self.io;
        // Serialize producers for the ENTIRE submit-and-wait (the multi-producer fix).
        self.submit_gate.lockUncancelable(io);
        defer self.submit_gate.unlock(io);
        self.mutex.lockUncancelable(io);
        // Mechanism, not discipline: at most one command in flight (gate-enforced).
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
