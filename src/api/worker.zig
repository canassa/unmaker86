//! The worker drain loop (M2 §A.1, Phase 3): the SOLE owner of `*Controller` /
//! `*Machine` at runtime. It dequeues one command, runs exactly one `Controller`
//! method (the 1:1 table from §0.1), fills a typed `Response`, and signals the
//! waiting producer. It NEVER reads host time, never accepts sockets, never parses
//! HTTP — it is a plain `wait → run one → publish → loop`.
//!
//! Transport-independence (D20): `drainOne` returns a typed `Response` carrying a
//! stable `ErrCode` for failures — NEVER an HTTP status. The `code → HTTP status`
//! map lives only in `server.zig`, so the M3 MCP layer reuses the same codes.
//!
//! Determinism: the guest advances ONLY inside the single `Controller.run*`/`step*`
//! call here; that call reads no host clock and charges only real/synthetic cycles
//! (M1 §4). Inspection uses the side-effect-free peek path.

const std = @import("std");
const debug = @import("debug");
const cpu_mod = @import("cpu");
const q = @import("queue.zig");
const json_wire = @import("json_wire.zig");
const png = @import("png.zig");
const live_mouse = @import("live_mouse.zig");
const snapshot_store = @import("snapshot_store.zig");
const run_control = @import("run_control.zig");

const LiveMouseState = live_mouse.LiveMouseState;
const SnapshotStore = snapshot_store.SnapshotStore;
const RunControl = run_control.RunControl;

/// The guest-cycle budget of ONE bounded burst between preempt polls (server-robustness:
/// the worker advances a run in bursts of this size and, between bursts, checks the
/// clockless abort flag so a wedged/unbounded run yields PROMPTLY to a `reset`/`stop`).
/// Sized to bound the abort latency to ~one burst (a few ms at typical emulation rates)
/// while adding negligible overhead to a normal run. DETERMINISM: a non-aborted run is
/// byte-identical regardless of this value — an absolute-target run-to fires its one-shot
/// at the same boundary however it is sliced, and a budgeted `run` tracks an ABSOLUTE
/// deadline so the final burst lands on the exact same cycle as a single `runUntilEvent`.
const PREEMPT_BURST_CYCLES: u64 = 1 << 20;

/// The instruction batch of `step_n` between preempt polls (exact stepping has no
/// overshoot, so `stepN(a)+stepN(b) == stepN(a+b)`; byte-identical regardless of batching).
const PREEMPT_STEP_BATCH: u64 = 1 << 16;

const Controller = debug.Controller;
const SourceDebugger = debug.SourceDebugger;
const core = debug.core;
const Seg = cpu_mod.Seg;
const Command = q.Command;
const Response = q.Response;
const RequestCtx = q.RequestCtx;
const ErrCode = q.ErrCode;
const Io = std.Io;

/// The host mount source for `POST /api/load` re-mounts. Held by the server (set at
/// `--serve` startup, never changed), passed to the worker, and used ONLY when
/// servicing a `load` command. `dir` is the host directory mounted as the DOS drive;
/// `io` is needed by `mountDrive`. When `dir` is null (in-process tests that never
/// drive `load`) a `load` command fails with `load_failed` rather than faking a mount.
pub const MountSource = struct {
    dir: ?Io.Dir = null,
    io: ?Io = null,
    /// The configured source-search roots (M-S1.5) — a SEPARATE host handle from the C:
    /// `dir` (the guest drive). Used ONLY to read debug SOURCE TEXT at load time; the
    /// Session owns the dirs (swapped by `load source_path`). Null ⇒ no source windows.
    source_roots: ?*const SourceRoots = null,
};

/// The per-session configured source-search path (debug-source-inlining-plan §A): an
/// ordered, bounded list of opened host directories the worker reads debug SOURCE TEXT
/// from at load time (resolution is deterministic: ascending root order, relative-path-
/// then-basename). The Session OWNS these `Io.Dir` handles (opened by `load source_path` /
/// `provision_machine source_path`, closed on swap / teardown) — they NEVER cross the
/// pointer-free queue; the worker only borrows a `*const SourceRoots`. `names[i]` is a
/// bounded display basename, NOT a full host path (finding #9 — no operator layout leak).
pub const MAX_SOURCE_ROOTS = 8;
pub const SOURCE_ROOT_NAME_CAP = 64;
pub const SourceRoots = struct {
    dirs: [MAX_SOURCE_ROOTS]Io.Dir = undefined,
    names: [MAX_SOURCE_ROOTS][SOURCE_ROOT_NAME_CAP]u8 = undefined,
    name_lens: [MAX_SOURCE_ROOTS]u8 = @splat(0),
    count: u8 = 0,

    /// Append an opened root + its display name (truncated to the cap). Silently ignores
    /// an over-cap push (bounded; the agent can re-order roots if it picked wrong).
    pub fn push(self: *SourceRoots, dir: Io.Dir, name: []const u8) void {
        if (self.count >= MAX_SOURCE_ROOTS) return;
        const i = self.count;
        self.dirs[i] = dir;
        const n = @min(name.len, SOURCE_ROOT_NAME_CAP);
        @memcpy(self.names[i][0..n], name[0..n]);
        self.name_lens[i] = @intCast(n);
        self.count += 1;
    }

    /// Close every opened root (swap / teardown). Idempotent (resets `count`).
    pub fn close(self: *SourceRoots, io: Io) void {
        for (self.dirs[0..self.count]) |*d| d.close(io);
        self.count = 0;
    }
};

/// The server-owned fixed render buffers (B1). Allocated ONCE at server startup and
/// reused for every `GET /api/framebuffer` capture (no per-op alloc; honors the
/// fixed-slab discipline). Sized for the widest standard VGA mode (640x480). The
/// worker renders into these via the pure peek; the server streams the selected
/// buffer as a raw binary body. NOT carried in the (pointer-free) Command — the
/// worker reaches them through a `*RenderBuffers` it holds, mirroring `mount_dir`.
pub const RenderBuffers = struct {
    /// Palette-index image (one byte per pixel). 640*480 = 307200 bytes.
    index: [debug.RENDER_INDEX_CAP]u8 = undefined,
    /// RGBA image (4 bytes per pixel). 640*480*4 = 1228800 bytes.
    rgba: [debug.RENDER_RGBA_CAP]u8 = undefined,
    /// The 256-entry expanded RGB palette (768 bytes), filled by the worker via the
    /// pure peek (PLTE source for the indexed-PNG path, §3.6 option a). The server reads
    /// only this slab — never the machine's DAC off-worker.
    palette: [768]u8 = undefined,
    /// The final PNG bytes streamed to the socket (`?format=png`). Worst case is a
    /// 640x480 RGB frame with deflate stored-block overhead; ~1.3 MiB is safe headroom.
    /// For mode 13h / TTM the real output is a few KiB. Streamed directly — never
    /// through resp_buf/JSON (B1).
    png_out: [PNG_OUT_CAP]u8 = undefined,
    /// Scratch the PNG encoder borrows (flate window + compressed-IDAT slab). Allocated
    /// once with the rest of the render buffers; no per-request alloc.
    png_work: png.Workspace = .{},
};

/// The server-owned PNG output slab cap (§3.7). A frame never expands past raw RGBA's
/// ~1.2 MiB by more than deflate stored-block + chunk overhead; 1.3 MiB covers it.
pub const PNG_OUT_CAP: usize = 1300 * 1024;

/// The bounded ceiling for ONE worker-serialized nested-JSON body (debug-m2-plan.md §1.1,
/// M-S2). The EXPLICIT nested-body cap: a body that would exceed it makes the fixed writer
/// fail → `response_too_large` (never a truncated JSON, CLAUDE.md §2). Sized to clear the
/// largest realistic single-level expansion (a deep BaK struct) with margin; the DAP-lazy
/// contract keeps any one body bounded in practice (narrow `max_frames` / page an array).
pub const DBG_JSON_CAP: usize = 256 * 1024;

/// The session-owned slab the worker serializes ONE nested-JSON debug body into while
/// Stopped (mirrors `RenderBuffers`, but for text). Owned by the `Session`, reached by the
/// worker OFF-Command via a `?*DebugJsonBuffer` field (never carried in the pointer-free
/// `Command`). The listener copies these OWNED bytes under `session.lock`, then streams.
pub const DebugJsonBuffer = struct {
    /// The worker-serialized JSON for one nested op; only `[0..body_len]` is meaningful.
    body: [DBG_JSON_CAP]u8 = undefined,
};

/// The addressable guest RAM slab size — the bound for memory containment checks
/// (§B.5/G3). The bus is host-OOB-safe regardless; this returns a clean
/// `address_out_of_range` BEFORE the controller call rather than silently reading
/// `unmapped_fill`. Sourced from the controller's static region table (the `.ram`
/// region's `len`), so there is one source of truth and no `bus` import here.
fn ramTotalSize(ctrl: *const Controller) u32 {
    for (ctrl.memoryRegions()) |r| {
        if (r.kind == .ram) return r.len;
    }
    unreachable; // the region table always contains a .ram region
}

/// True iff `[start, start+len)` is contained in `[0, ram_total_size)` (slab
/// containment — NOT "inside some region", since RAM/VRAM/EMS windows overlap).
fn inSlab(ctrl: *const Controller, start: u32, len: u32) bool {
    const total = ramTotalSize(ctrl);
    const end = @as(u64, start) + @as(u64, len); // widen to avoid u32 overflow
    return end <= total;
}

/// Dispatch exactly one command to one `Controller` method. Pure mapping; the only
/// state it touches is via `ctrl` (the worker owns it) and `ctx.scratch` (the
/// mem_write bytes, copied in by the handler before submit).
pub fn drainOne(ctrl: *Controller, ctx: *RequestCtx, mount: MountSource, render: ?*RenderBuffers, live: ?*LiveMouseState, snapshots: ?*SnapshotStore, run_ctl: ?*RunControl, sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer) Response {
    // T4 (debug-m2-plan.md §6): the MECHANICAL stop-epoch wrapper. Every command that
    // charges cycles / advances CS:IP / wipes the machine is a RESUME — BEFORE it runs we
    // invalidate every outstanding expansion handle + bump the (monotonic) `stop_epoch`
    // (`beginResume`), and AFTER it stops we re-stamp `sd.state`/`pc` (`noteStopped`),
    // whatever command drove it. Without this a prior-stop handle would survive a plain
    // `run`/`reset`/input-inject (which bypass `SourceDebugger`) as a SILENT stale read.
    // The `dbg_step_*` arms self-manage this via `beginStep`/`projectStop` (excluded here).
    const is_resume = isResumeCmd(ctx.cmd);
    if (is_resume) if (sd) |s| s.beginResume();
    const resp = dispatch(ctrl, ctx, mount, render, live, snapshots, run_ctl, sd, dbg_json);
    if (is_resume) if (sd) |s| noteResumeStop(s, resp);
    return resp;
}

/// The resume classification (T4): every `drainOne` arm that charges cycles, advances
/// CS:IP, or wipes the machine. `load`/`restore` are EXCLUDED (they invalidate handles via
/// `attachOnLoad`/`onMachineReverted`); the `dbg_step_*` arms are EXCLUDED (folded into
/// `beginStep`). `input_mouse_fold` is cycle-neutral (no CS:IP advance) and excluded.
fn isResumeCmd(cmd: q.Command) bool {
    return switch (cmd) {
        .run, .run_slice, .run_to_cycle, .run_to_address, .step, .step_n, .step_over, .reset, .input_key, .input_mouse => true,
        else => false,
    };
}

/// Re-stamp `sd.state`/`pc` after a resumed arm stopped (T4). Uses the arm's `StopReason`
/// when it carries one (`.stop`/`.step_over`); a `.ok`/`.err` (a `reset`, a cycle-neutral
/// inject, or a rejected inject) just flips the gate back to Stopped.
fn noteResumeStop(s: *SourceDebugger, resp: Response) void {
    switch (resp) {
        .stop => |reason| _ = s.noteStopped(reason),
        .step_over => |so| _ = s.noteStopped(so.reason),
        else => s.noteStoppedNoReason(),
    }
}

fn dispatch(ctrl: *Controller, ctx: *RequestCtx, mount: MountSource, render: ?*RenderBuffers, live: ?*LiveMouseState, snapshots: ?*SnapshotStore, run_ctl: ?*RunControl, sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer) Response {
    return switch (ctx.cmd) {
        // ---- run / step ----------------------------------------------------
        // Every run is PREEMPTIBLE: advanced in bounded bursts so a long/unbounded/wedged
        // run yields PROMPTLY (`stopped_by_request`) when a `reset`/`stop` raises the abort
        // flag — without that, one long run holds the single worker and jams the server.
        // A non-aborted run is byte-identical to the old single `runUntilEvent` (see
        // `PREEMPT_BURST_CYCLES`); `run_ctl == null` (in-process tests) ⇒ no poll, no chunking
        // overhead beyond the absolute-deadline loop, same result.
        .run => |c| runCapPreemptible(ctrl, run_ctl, c.cycle_cap),
        // A paced free-run slice — the host run-pacer submits this each wall-clock tick. Also
        // preemptible (a slice with a large `slice_cycles` against a wedged guest still yields),
        // and the returned `StopReason` lets the pacer disarm on a terminal / on a preemption (§10).
        .run_slice => |c| runCapPreemptible(ctrl, run_ctl, c.slice_cycles),
        .run_to_cycle => |c| blk: {
            const t = ctrl.beginRunToCycle(c.cycle) catch |e| break :blk errResp(e);
            break :blk runToTargetPreemptible(ctrl, run_ctl, t);
        },
        .run_to_address => |c| blk: {
            const t = ctrl.beginRunToAddress(c.linear) catch |e| break :blk errResp(e);
            break :blk runToTargetPreemptible(ctrl, run_ctl, t);
        },
        .step => .{ .stop = ctrl.stepInstruction() },
        .step_n => |c| stepNPreemptible(ctrl, run_ctl, c.n),
        .step_over => blk: {
            const r = ctrl.stepOver();
            break :blk .{ .step_over = .{ .reason = r.reason, .stepped_into = r.stepped_into } };
        },

        // ---- breakpoints ---------------------------------------------------
        .add_bp => |c| .{ .bp_id = ctrl.addBreakpoint(c.kind, c.one_shot) catch |e| return errResp(e) },
        .remove_bp => |c| blk: {
            ctrl.removeBreakpoint(c.id) catch |e| break :blk errResp(e);
            break :blk .ok;
        },
        .enable_bp => |c| blk: {
            ctrl.enableBreakpoint(c.id, c.on) catch |e| break :blk errResp(e);
            break :blk .ok;
        },
        .get_bp => |c| blk: {
            const b = ctrl.getBreakpoint(c.id) catch |e| break :blk errResp(e);
            break :blk .{ .bp_one = .{ .id = c.id, .kind = b.kind, .enabled = b.enabled, .one_shot = b.one_shot } };
        },
        .list_bp => listBreakpoints(ctrl),
        .clear_bp => clearBreakpoints(ctrl),

        // ---- cpu -----------------------------------------------------------
        .cpu_get => .{ .cpu = ctrl.cpuSnapshot() },
        .reg_set => |c| applyRegSet(ctrl, c),

        // ---- memory --------------------------------------------------------
        .mem_peek => |c| memPeekPhys(ctrl, c.phys, c.len),
        .mem_write => |c| memWritePhys(ctrl, ctx, c.phys, c.len),
        .mem_peek_seg => |c| memPeekSeg(ctrl, c.seg, c.off, c.len),
        .mem_write_seg => |c| memWriteSeg(ctrl, ctx, c.seg, c.off, c.len),

        // ---- ivt / stack ---------------------------------------------------
        .ivt_get => |c| blk: {
            const e = ctrl.peekIvtEntry(c.vector);
            break :blk .{ .ivt = .{ .vector = c.vector, .ip = e.ip, .cs = e.cs } };
        },
        .stack_get => |c| stackGet(ctrl, c.count),

        // ---- input ---------------------------------------------------------
        .input_key => |c| inputKey(ctrl, c),
        .input_mouse => |c| blk: {
            // A held CLICK (`hold_ms` present): press → advance the dwell's cycles →
            // release, so a level-sampling guest observes it. DOES advance the machine;
            // returns the run stop reason (the deterministic cycle delta), unlike the
            // pure inject below. The wire mapper already guaranteed a non-zero button
            // mask, so there is a real down→…→up edge to hold.
            if (c.hold_ms) |ms| break :blk .{ .stop = ctrl.clickMouse(c, ms) };
            // A PURE MOVE (absolute/relative motion, NO buttons) must be DELIVERED to a
            // callback-only guest — one that learns of the pointer ONLY via the INT 33h
            // AX=0Ch event callback (e.g. Betrayal at Krondor: it never polls AX=03/0B, so
            // its software cursor tracks ONLY the callback). The bare inject merely RAISES
            // IRQ12 (Option C, deferred); the live/browser fold path delivers continuously
            // (the pacer runs a slice every tick), but a one-shot MCP move runs nothing —
            // so the move would be a SILENT NO-OP and the cursor would never track.
            // `injectMouseDeliver` advances a short deterministic dwell to deliver the
            // callback (mirroring the live path); it stays CYCLE-NEUTRAL (returns null) when
            // nothing is pending (no handler / masked-out event), so a polling guest and the
            // scripted-inject seam are byte-unchanged. A buttons-carrying inject is NOT
            // routed here: a click already dwells (hold_ms above), and a `release:false`
            // drag press/move/release is the explicit cycle-neutral "run between" primitive
            // (the caller's own run delivers it) — both keep their existing semantics.
            const moved = c.set_x or c.set_y or c.set_nx or c.set_ny or c.set_dx or c.set_dy;
            if (moved and !c.set_buttons) {
                if (ctrl.injectMouseDeliver(c)) |stop| break :blk .{ .stop = stop };
                break :blk .ok;
            }
            // Pure buttons-bearing inject (a `release:false` drag press/move/release): mutate
            // INT 33h driver state at the one-command-in-flight boundary (no host clock, no
            // sample-rate gate, cycle-neutral, NO auto-release). Always succeeds — driver-
            // state injection has no FIFO to overflow (unlike the 8042 key path).
            ctrl.injectMouse(c);
            break :blk .ok;
        },
        .input_mouse_fold => foldLiveMouse(ctrl, live),

        // ---- session -------------------------------------------------------
        .console_get => consoleResp(ctrl),
        .mouse_get => .{ .mouse = ctrl.mouseSnapshot() },
        .screen_get => screenResp(ctrl),
        .framebuffer_get => framebufferResp(ctrl, render),
        .status => statusResp(ctrl),
        // Live CPU:PIT clock (Phase 3). Applied at THIS serialized command boundary
        // (a precise cycle), exactly like `reset` — a deterministic input. The
        // controller clamps + returns the APPLIED mult; the server derives the pacer
        // slice + displayed MHz from it. No re-arm (approach B: device-time domain).
        .set_clock => |c| .{ .clock = ctrl.setCpuMult(c.mult) },
        .clock_get => .{ .clock = ctrl.clockMult() },
        .reset => blk: {
            ctrl.reset() catch return .{ .err = .load_failed };
            break :blk .ok;
        },
        .load => |c| loadResp(ctrl, sd, c, mount),
        .mem_regions => regionsResp(ctrl),
        .disasm => |c| disasmResp(ctrl, c.origin, c.count),
        .devices_get => .{ .devices = ctrl.devicesSnapshot() },
        .io_shadow => |c| .{ .io_shadow = .{ .port = c.port, .value = ctrl.ioShadow(c.port) } },
        .mem_search => |c| memSearch(ctrl, ctx, c),

        // ---- snapshot / restore (snapshot-restore-plan §2.3) ---------------
        // Run ON THE WORKER (the machine owner); reach the per-session store via the
        // worker's `?*SnapshotStore` (like `render`/`live_mouse`), never via the queue.
        .snapshot => snapshotResp(ctrl, snapshots),
        .restore => |c| restoreResp(ctrl, sd, snapshots, c.seq),
        .list_snapshots => listSnapshotsResp(snapshots),
        .delete_snapshot => |c| deleteSnapshotResp(snapshots, c.seq),

        // ---- branch trace + trap (docs/branch-trace-plan.md §6) ------------
        .branch_trace_arm => |c| .{ .trace_status = wireTraceStatus(ctrl.armBranchTrace(c.on, c.kind_mask)) },
        .branch_trace_clear => .{ .trace_status = wireTraceStatus(ctrl.clearBranchTrace()) },
        .branch_trace_status => .{ .trace_status = wireTraceStatus(ctrl.branchTraceStatus()) },
        .branch_trace_dump => |c| branchTraceDump(ctrl, c),
        .branch_trap_arm => |a| .{ .trace_status = wireTraceStatus(ctrl.armBranchTrap(.{
            .armed = true,
            .to_range = a.to_range,
            .to_lo = a.to_lo,
            .to_hi = a.to_hi,
            .sp_range = a.sp_range,
            .sp_lo = a.sp_lo,
            .sp_hi = a.sp_hi,
            .kind_match = a.kind_match,
            .kind_trap_mask = a.kind_trap_mask,
        })) },
        .branch_trap_clear => .{ .trace_status = wireTraceStatus(ctrl.clearBranchTrap()) },

        // ---- source-level debug core (M-S1) --------------------------------
        // Delegate to the `?*SourceDebugger` the worker holds. A null `sd` (an in-
        // process test harness that never wired one) fails loud with `not_implemented`
        // rather than faking a debug result.
        .dbg_where => |c| dbgWhere(sd, c.context),
        .dbg_set_src_bp => |c| dbgSetSrcBp(sd, c),
        .dbg_set_fn_bp => |c| dbgSetFnBp(sd, c),
        .dbg_clear_bp => |c| dbgClearBp(sd, c.id),
        .dbg_list_bp => dbgListBp(sd),
        .dbg_step_line => |c| dbgStep(ctrl, sd, run_ctl, .line, null, 0, c.context),
        .dbg_step_in => |c| dbgStep(ctrl, sd, run_ctl, .in, null, 0, c.context),
        .dbg_step_out => |c| dbgStep(ctrl, sd, run_ctl, .out, null, 0, c.context),
        .dbg_run_to_line => |c| dbgStep(ctrl, sd, run_ctl, .to_line, c.file[0..c.file_len], c.line, c.context),
        .dbg_read_source => |c| dbgReadSource(sd, c),
        .dbg_list_sources => dbgListSources(sd),

        // ---- source-level debug M-S2 nested-JSON seam (M2-a) ----------------
        // The worker serializes the (variable-length, nested) body into the session-owned
        // `DebugJsonBuffer` slab while Stopped, and returns only a `DbgJsonResult{body_len}`.
        .dbg_json_selftest => |c| dbgJsonResp(sd, dbg_json, c, selfTestBody),

        // `backtrace` (M2-b): unwind the call stack (peek-only) + serialize the frame list.
        // TODO(M2-c): the stop-epoch / `beginResume`/`noteStopped` `drainOne` wiring (plan
        // §6/T4) is deferred to the locals stage — backtrace emits NO `variables_ref` handles,
        // so it has no epoch-invalidation dependency; the frame list is a pure function of the
        // stop cycle. The epoch table lands with the `ExpandTable` it protects (M2-c §3.5).
        .dbg_backtrace => |c| dbgJsonResp(sd, dbg_json, c, backtraceBody),

        // `scopes` / `frame_variables` / `variables` (M2-c, debug-m2-plan.md §3): per-frame
        // scope handles, that frame's locals, and one-level handle expansion. Each validates
        // (frame index / stale handle) BEFORE serializing, so `bad_frame`/`stale_handle`
        // reach the wire as typed errors rather than the generic `response_too_large`.
        .dbg_scopes => |c| dbgScopes(sd, dbg_json, c),
        .dbg_frame_variables => |c| dbgFrameVariables(sd, dbg_json, c),
        .dbg_variables => |c| dbgVariables(sd, dbg_json, c),

        // `inspect` (M2-d, §4): a bounded path-addressed peek. `context` (M2-d, §5/R3): the
        // combined one-call-per-stop body (frame + window + backtrace + top-frame locals).
        .dbg_inspect => |c| dbgInspect(sd, dbg_json, c),
        // `evaluate` (M3-a, §A): a READ-ONLY C-expression evaluator (peek-only, zero cycles).
        .dbg_evaluate => |c| dbgEvaluate(sd, dbg_json, c),
        // `set_variable` (M3-b, §B): a DELIBERATE, deterministic MUTATION arm — resolve the
        // lvalue + encode the value in the pure core, then commit the poke here (the same guarded
        // path memWritePhys/applyRegSet use). NOT in `isResumeCmd` → no CS:IP advance, no cycles,
        // no `stop_epoch` bump (B.5).
        .dbg_set_variable => |c| dbgSetVariable(sd, dbg_json, c),
        .dbg_context => |c| dbgContext(sd, dbg_json, c),

        .shutdown_worker => .ok,
    };
}

/// The M-S2 nested-JSON seam entry point (debug-m2-plan.md §1.3). The worker, while
/// Stopped, serializes `build(state, writer)` into the session-owned slab as fully-
/// materialized OWNED bytes and returns only the `body_len` descriptor. It stays clockless
/// and host-RNG-free: it builds JSON from owned bytes + integer indices + peek reads (no
/// host clock, no host RNG). Degrades HONESTLY — a null `sd`/slab or a running machine yields a
/// typed error, never a fake body; an over-`DBG_JSON_CAP` body makes the fixed writer fail
/// → `response_too_large` (the EXPLICIT overflow, never a truncated JSON).
fn dbgJsonResp(
    sd: ?*SourceDebugger,
    dbg_json: ?*DebugJsonBuffer,
    args: anytype,
    comptime build: fn (s: *SourceDebugger, a: @TypeOf(args), w: *std.Io.Writer) std.Io.Writer.Error!void,
) Response {
    const s = sd orelse return .{ .err = .no_symbols }; // no debug core wired — honest, never a fake body
    const buf = dbg_json orelse return .{ .err = .load_failed }; // no slab wired (in-process harness)
    // §6 gating: the live BP/SP/registers are meaningful only at a clean instruction
    // boundary. A mid-run peek is refused with a typed error, not a fabricated stop.
    if (s.state == .running) return .{ .err = .not_stopped };
    var w = std.Io.Writer.fixed(buf.body[0..]);
    build(s, args, &w) catch return .{ .err = .response_too_large }; // fixed-writer overrun → explicit 413
    return .{ .dbg_json = .{ .body_len = @intCast(w.buffered().len) } };
}

/// The M2-a transport self-test body builder (the plan's "trivial stub body"). Emits a
/// deterministic `{"selftest":true,"fill":N,"data":"<N × 'x'>"}` document — a pure
/// function of `fill`, so two runs are byte-identical and HTTP/MCP emit the same bytes. A
/// large `fill` overruns the fixed slab writer, exercising the `response_too_large` path.
/// (No machine state is read; the real M2-b..d producers replace this with the backtrace/
/// locals/context renderers.)
fn selfTestBody(s: *SourceDebugger, args: q.DbgSelfTestCmd, w: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = s;
    try w.print("{{\"selftest\":true,\"fill\":{d},\"data\":\"", .{args.fill});
    try w.splatByteAll('x', args.fill);
    try w.writeAll("\"}");
}

/// The `backtrace` body builder (M2-b, debug-m2-plan.md §2.7). Runs the PURE unwinder
/// (`core.unwind.backtrace`, peek-only) over the current stop and serializes the frame list
/// innermost-first: `{index, function, file, line, addr:{seg,off,linear}, frame_base,
/// is_far, unreliable}` plus the always-present `truncated_reason` (WHY the walk stopped —
/// never a hidden cap or a fabricated parent). Every guest string is CP437→UTF-8 transcoded
/// before `encodeJsonString` (T16c). A deterministic function of the stop cycle.
fn backtraceBody(s: *SourceDebugger, args: q.DbgBacktraceCmd, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var frames: [core.MAX_FRAMES]core.Frame = undefined;
    const want = @min(@as(usize, args.max_frames), core.MAX_FRAMES);
    const bt = core.unwind.backtrace(s, frames[0..], want);

    try w.writeAll("{\"frames\":");
    try writeFrameList(bt.frames, w);
    try w.print(",\"truncated_reason\":\"{s}\"}}", .{@tagName(bt.truncated_reason)});
}

/// Emit a `[...]` array of frames (shared by `backtrace` and `context`, §5 — one renderer, no
/// divergence). Each frame: `{index, function, file, line, addr, frame_base, is_far, unreliable}`.
fn writeFrameList(frames: []const core.Frame, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (frames, 0..) |f, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.print("{{\"index\":{d},\"function\":", .{f.index});
        if (f.function) |name| try writeGuestJsonString(w, name) else try w.writeAll("null");
        try w.writeAll(",\"file\":");
        if (f.source) |src| try writeGuestJsonString(w, src.path) else try w.writeAll("null");
        try w.print(",\"line\":{d},\"addr\":{{\"seg\":{d},\"off\":{d},\"linear\":{d}}},\"frame_base\":{d},\"is_far\":{s},\"unreliable\":{s}}}", .{
            if (f.source) |src| src.line else 0,
            f.pc.seg,
            f.pc.off,
            f.pc.linear,
            f.frame_base,
            if (f.is_far) "true" else "false",
            if (f.unreliable) "true" else "false",
        });
    }
    try w.writeByte(']');
}

// ─────────────────────────── scopes / locals / variable tree (M2-c, §3) ───────────────────────────

/// Common preamble for the three §3 handlers: null-check the debug core + slab and enforce
/// the Stopped gate (§6). Returns the slab pointer, or a typed-error `Response`.
fn dbgReady(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer) union(enum) { ok: struct { s: *SourceDebugger, buf: *DebugJsonBuffer }, err: Response } {
    const s = sd orelse return .{ .err = .{ .err = .no_symbols } };
    const buf = dbg_json orelse return .{ .err = .{ .err = .load_failed } };
    if (s.state == .running) return .{ .err = .{ .err = .not_stopped } };
    return .{ .ok = .{ .s = s, .buf = buf } };
}

/// Finish a §3 body: seal the fixed writer (an over-`DBG_JSON_CAP` body → `response_too_large`).
fn sealJson(buf: *DebugJsonBuffer, w: *std.Io.Writer) Response {
    _ = buf;
    return .{ .dbg_json = .{ .body_len = @intCast(w.buffered().len) } };
}

/// Resolve `frame` to its unwound `core.Frame`, or a `bad_frame` error. Fills the caller's
/// on-stack frame buffer (re-peeked at the current stop — a pure function of the stop cycle).
fn frameOrBad(s: *SourceDebugger, frame: u16, buf: []core.Frame) ?core.Frame {
    const bt = core.unwind.backtrace(s, buf, buf.len);
    if (frame >= bt.frames.len) return null;
    return bt.frames[frame];
}

/// `scopes{frame}` (§3.2): the frame's scope handles — one `locals` scope always, plus a
/// `registers` scope for frame 0 (the live CPU regs). Each carries a lazy `variables_ref`.
fn dbgScopes(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgScopesReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var fbuf: [core.MAX_FRAMES]core.Frame = undefined;
    if (frameOrBad(r.s, c.frame, fbuf[0..]) == null) return .{ .err = .bad_frame };

    const locals_ref = r.s.mintHandle(.{ .target = .locals, .frame_index = c.frame });
    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeScopes(r.s, c.frame, locals_ref, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeScopes(s: *SourceDebugger, frame: u16, locals_ref: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = s;
    try w.print("{{\"scopes\":[{{\"kind\":\"locals\",\"frame_index\":{d},\"variables_ref\":{d}}}", .{ frame, locals_ref });
    if (frame == 0) try w.writeAll(",{\"kind\":\"registers\",\"frame_index\":0,\"variables_ref\":0}");
    try w.writeAll("]}");
}

/// `frame_variables{frame}` (§3.6): the frame's locals rendered inline (scopes + locals in
/// one body — the one-shot an LLM calls per stop). Aggregates/arrays/pointers carry a
/// `variables_ref` for `variables{ref}`.
fn dbgFrameVariables(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgFrameVarsReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var fbuf: [core.MAX_FRAMES]core.Frame = undefined;
    const frame = frameOrBad(r.s, c.frame, fbuf[0..]) orelse return .{ .err = .bad_frame };

    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeFrameVariables(r.s, frame, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeFrameVariables(s: *SourceDebugger, frame: core.Frame, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"frame\":{d},\"variables\":", .{frame.index});
    try writeLocalsArray(s, frame, w);
    try w.writeByte('}');
}

/// Emit a `[...]` array of `frame`'s rendered locals (shared by `frame_variables` and
/// `context`, §5 — the same renderer, so the two bodies never diverge).
fn writeLocalsArray(s: *SourceDebugger, frame: core.Frame, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var locals: [core.MAX_LOCALS]core.Local = undefined;
    const ls = core.vars.frameLocals(s, frame, locals[0..]);
    try w.writeByte('[');
    for (ls, 0..) |l, idx| {
        if (idx != 0) try w.writeByte(',');
        var scratch: [256]u8 = undefined;
        const v = core.vars.renderLocal(s, frame, l, scratch[0..]);
        try writeVariable(s, v, w);
    }
    try w.writeByte(']');
}

/// `variables{ref,start,count}` (§3.5): expand/page one handle ONE level. A prior-epoch
/// handle → `stale_handle` (never a silent stale read); a struct ignores `start`/`count`,
/// an array pages `[start, start+count)`.
fn dbgVariables(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgVarsReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    const node = r.s.resolveHandle(c.ref) catch return .{ .err = .stale_handle };

    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeVariables(r.s, node, c.start, c.count, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeVariables(s: *SourceDebugger, node: core.ExpandNode, start: u32, count: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const total = core.vars.childCount(s, node);
    // An array pages via [start, start+count); a struct/pointee ignores the window (count==0
    // ⇒ the whole node). NEVER a silent clip — the emitted `start`/`count` bound the page.
    const first: usize = @min(@as(usize, start), total);
    const want: usize = if (count == 0) total else @min(@as(usize, count), total - first);
    try w.print("{{\"start\":{d},\"count\":{d},\"total\":{d},\"variables\":[", .{ first, want, total });
    var i: usize = 0;
    while (i < want) : (i += 1) {
        if (i != 0) try w.writeByte(',');
        var scratch: [256]u8 = undefined;
        const v = core.vars.renderChild(s, node, first + i, scratch[0..]);
        try writeVariable(s, v, w);
    }
    try w.writeAll("]}");
}

// ─────────────────────────── inspect (M2-d, §4) ───────────────────────────

/// `inspect{frame,path}` (§4): a bounded, path-addressed peek. Resolves `path` against the
/// frame's locals + type graph (the PURE `core.vars.inspectPath`, reusing the Stage-3 render)
/// and serializes the resolved `core.Variable`. HONEST typed errors: an out-of-grammar form →
/// `unsupported_expression` (the anti-eval boundary — never a guessed value); an unresolvable
/// name/member/index → `unresolved`; a bad frame index → `bad_frame`. A `<null>` deref /
/// `unreadable` address is a SUCCESSFUL body carrying the honest `avail`/value.
fn dbgInspect(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgInspectReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var fbuf: [core.MAX_FRAMES]core.Frame = undefined;
    const frame = frameOrBad(r.s, c.frame, fbuf[0..]) orelse return .{ .err = .bad_frame };

    const path = c.path[0..@min(@as(usize, c.path_len), c.path.len)];
    var scratch: [512]u8 = undefined;
    const v = core.vars.inspectPath(r.s, frame, path, scratch[0..]) catch |e| switch (e) {
        error.Unsupported => return .{ .err = .unsupported_expression },
        error.Unresolved => return .{ .err = .unresolved },
    };

    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeInspect(r.s, path, v, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeInspect(s: *SourceDebugger, path: []const u8, v: core.Variable, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, w);
    try w.writeAll(",\"result\":");
    try writeVariable(s, v, w);
    try w.writeByte('}');
}

// ─────────────────────────── evaluate (M3-a, §A) ───────────────────────────

/// `evaluate{frame,expr}` (§A): a READ-ONLY C-expression evaluator. Parses + evaluates `expr`
/// against the frame's locals/globals + type graph (`core.expr.evaluate`) — PURE, peek-only,
/// zero cycles, NO guest execution. HONEST typed errors, never a guessed value:
/// `unsupported_expression` (out-of-subset / float arith / call), `unresolved` (unknown name/
/// member), `not_lvalue` (`&` of a non-lvalue), `type_error` (bad operand types / OOB index),
/// `divide_by_zero`. A `<null>` deref / `unreadable` address is a SUCCESSFUL body (honest avail).
fn dbgEvaluate(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgEvaluateReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var fbuf: [core.MAX_FRAMES]core.Frame = undefined;
    const frame = frameOrBad(r.s, c.frame, fbuf[0..]) orelse return .{ .err = .bad_frame };

    const expr = c.expr[0..@min(@as(usize, c.expr_len), c.expr.len)];
    var scratch: [512]u8 = undefined;
    const v = core.expr.evaluate(r.s, frame, expr, scratch[0..]) catch |e| return .{ .err = evalErr(e) };

    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeEvaluate(r.s, expr, v, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeEvaluate(s: *SourceDebugger, expr: []const u8, v: core.Variable, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"expr\":");
    try std.json.Stringify.encodeJsonString(expr, .{}, w);
    try w.writeAll(",\"result\":");
    try writeVariable(s, v, w);
    try w.writeByte('}');
}

// ─────────────────────────── set_variable (M3-b, §B) — a DELIBERATE MUTATION ───────────────────────────

/// `set_variable{frame,lvalue,value}` (§B): a DELIBERATE, deterministic poke (the debugger
/// sibling of write_memory/set_register). The PURE core (`core.expr.resolveWrite`) resolves the
/// lvalue + type-directed encodes the value into a neutral `{destination, bytes}` plan (D1);
/// THIS handler commits it through the SAME guarded path memWritePhys/applyRegSet use
/// (`inSlab` + `writeMemPhys`/`setReg16`/`setReg8`). It does NOT advance CS:IP, charges ZERO
/// cycles, and does NOT bump `stop_epoch` (B.5). Honest typed errors, never a partial / neighbor-
/// clobbering / silently-wrapped write: `not_lvalue`, `type_error`, `unresolved`,
/// `address_out_of_range` (out-of-slab), `unsupported_expression` (float target). After the
/// write it RE-RENDERS the lvalue (re-resolve + render) so the agent confirms the new value.
fn dbgSetVariable(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgSetVarReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var fbuf: [core.MAX_FRAMES]core.Frame = undefined;
    const frame = frameOrBad(r.s, c.frame, fbuf[0..]) orelse return .{ .err = .bad_frame };

    const lvalue = c.lvalue[0..@min(@as(usize, c.lvalue_len), c.lvalue.len)];
    const value = c.value[0..@min(@as(usize, c.value_len), c.value.len)];

    // 1. PURE: resolve the lvalue + encode the value (the write EFFECT stays off the core).
    const plan = core.expr.resolveWrite(r.s, frame, lvalue, value) catch |e| return .{ .err = evalErr(e) };

    // 2. COMMIT the poke — the SAME guarded path the mem-write / reg-patch handlers use. S6: the
    //    memory write ALWAYS routes through `inSlab(computed_linear)` + `writeMemPhys`, so an
    //    out-of-slab target is an honest `address_out_of_range`, never a wild host write.
    switch (plan.dest) {
        .mem => |m| {
            if (!inSlab(r.s.ctrl, m.linear, m.len)) return .{ .err = .address_out_of_range };
            r.s.ctrl.writeMemPhys(m.linear, plan.bytes[0..m.len]);
        },
        .reg => |rg| {
            // format.Reg 0-7 (ax..di) → setReg16; 8-15 (al..bh) → setReg8(r-8) — the exact
            // applyRegSet mapping. The width guard (S3) already ran in the core.
            if (rg.num < 8) {
                const v16 = std.mem.readInt(u16, plan.bytes[0..2], .little);
                r.s.ctrl.setReg16(@enumFromInt(rg.num), v16);
            } else {
                r.s.ctrl.setReg8(@enumFromInt(rg.num - 8), plan.bytes[0]);
            }
        },
    }

    // 3. RE-RENDER the lvalue (re-resolve + render through the SAME evaluator) so the agent
    //    confirms the write landed with the new value.
    var scratch: [512]u8 = undefined;
    const v = core.expr.evaluate(r.s, frame, lvalue, scratch[0..]) catch |e| return .{ .err = evalErr(e) };

    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeSetVar(r.s, lvalue, v, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

/// Map the pure-core `EvalError` vocabulary to the wire `ErrCode` (shared by evaluate + set_variable).
fn evalErr(e: core.expr.EvalError) q.ErrCode {
    return switch (e) {
        error.Unsupported => .unsupported_expression,
        error.Unresolved => .unresolved,
        error.NotLvalue => .not_lvalue,
        error.TypeError => .type_error,
        error.DivByZero => .divide_by_zero,
    };
}

fn writeSetVar(s: *SourceDebugger, lvalue: []const u8, v: core.Variable, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"lvalue\":");
    try std.json.Stringify.encodeJsonString(lvalue, .{}, w);
    try w.writeAll(",\"result\":");
    try writeVariable(s, v, w);
    try w.writeByte('}');
}

// ─────────────────────────── context / R3 (M2-d, §5) ───────────────────────────

/// `context{frame,window,max_frames}` (§5/R3): the combined one-call-per-stop body — the
/// current frame, its source window (radius `window`, reusing the M-S1.5 `sourceWindow`), the
/// backtrace (reusing the §2 unwinder), and the top-frame locals (reusing the §3 renderer) —
/// all in ONE `dbg_json` body via the SHARED frame/window/locals renderers (no divergence).
fn dbgContext(sd: ?*SourceDebugger, dbg_json: ?*DebugJsonBuffer, c: q.DbgContextReq) Response {
    const r = switch (dbgReady(sd, dbg_json)) {
        .err => |e| return e,
        .ok => |ok| ok,
    };
    var w = std.Io.Writer.fixed(r.buf.body[0..]);
    (writeContext(r.s, c, &w)) catch return .{ .err = .response_too_large };
    return sealJson(r.buf, &w);
}

fn writeContext(s: *SourceDebugger, c: q.DbgContextReq, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var frames: [core.MAX_FRAMES]core.Frame = undefined;
    const want = @min(@as(usize, c.max_frames), core.MAX_FRAMES);
    const bt = core.unwind.backtrace(s, frames[0..], want);
    // The selected top frame (default 0). If the requested frame is out of range, fall back to
    // frame 0 (always present when Stopped) rather than fail — `context` is the always-on stop
    // snapshot; the `frame` arg only re-centers the window/locals.
    const sel: usize = if (c.frame < bt.frames.len) c.frame else 0;
    const top = bt.frames[sel];

    // 1. frame — the resolved Pc location of the selected frame.
    try w.writeAll("{\"frame\":{\"index\":");
    try w.print("{d},\"function\":", .{top.index});
    if (top.function) |name| try writeGuestJsonString(w, name) else try w.writeAll("null");
    try w.writeAll(",\"file\":");
    if (top.source) |src| try writeGuestJsonString(w, src.path) else try w.writeAll("null");
    try w.print(",\"line\":{d},\"addr\":{{\"seg\":{d},\"off\":{d},\"linear\":{d}}}}}", .{
        if (top.source) |src| src.line else 0,
        top.pc.seg,
        top.pc.off,
        top.pc.linear,
    });

    // 2. window — the M-S1.5 source window centered on the selected frame's line (null when the
    //    frame has no source line, honest).
    try w.writeAll(",\"window\":");
    try writeContextWindow(s, top, c.window, w);

    // 3. backtrace — the full frame list (shared renderer).
    try w.writeAll(",\"backtrace\":");
    try writeFrameList(bt.frames, w);
    try w.print(",\"truncated_reason\":\"{s}\"", .{@tagName(bt.truncated_reason)});

    // 4. locals — the selected frame's locals (shared renderer; may carry variables_ref handles
    //    minted in this stop epoch).
    try w.writeAll(",\"locals\":");
    try writeLocalsArray(s, top, w);
    try w.writeByte('}');
}

/// Serialize the source window for `frame` (radius `window`) as `{has,...,lines:[...]}` or
/// `null` when the frame carries no source line / no cached text. Text is already UTF-8 in the
/// source cache (CP437-transcoded at admission), so it streams straight through `encodeJsonString`.
fn writeContextWindow(s: *SourceDebugger, frame: core.Frame, window: u16, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const src = frame.source orelse return w.writeAll("null");
    var linebuf: [core.MAX_WINDOW_LINES]core.SrcLine = undefined;
    const win = s.sourceWindow(src.file_id, src.line, window, linebuf[0..]) orelse return w.writeAll("null");
    try w.print("{{\"has\":true,\"file_id\":{d},\"active_line\":{d},\"clamped\":{s},\"lines\":[", .{
        win.file_id,
        win.active_line,
        if (win.clamped) "true" else "false",
    });
    for (win.lines, 0..) |ln, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"number\":{d},\"active\":{s},\"truncated\":{s},\"text\":", .{
            ln.number,
            if (ln.active) "true" else "false",
            if (ln.truncated) "true" else "false",
        });
        try std.json.Stringify.encodeJsonString(ln.text, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Emit one `core.Variable` as JSON. Every guest-derived string (`name`, `value_text`, the
/// streamed type name) is CP437→UTF-8 transcoded (T16c) so a raw high byte never reaches
/// `encodeJsonString`. `avail != "ok"` carries NO `value_text` — the honest signal.
fn writeVariable(s: *SourceDebugger, v: core.Variable, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try writeGuestJsonString(w, v.name);
    try w.writeAll(",\"type\":");
    // G1: a SYNTHESIZED result (M-S3 `evaluate` literal/arith/`sizeof`/`&`) carries its type
    // as `type_text` (no `type_ref`); prefer it. A graph-typed result (empty `type_text`)
    // streams `typeName(type_ref)` exactly as M-S2 — so those bodies stay byte-identical.
    if (v.type_text.len != 0) {
        try writeGuestJsonString(w, v.type_text);
    } else {
        try writeTypeName(s, v.type_ref, w);
    }
    try w.print(",\"avail\":\"{s}\"", .{@tagName(v.avail)});
    if (v.avail == .ok) {
        try w.writeAll(",\"value\":");
        try writeGuestJsonString(w, v.value_text);
    }
    if (v.addr) |a| try w.print(",\"addr\":{{\"seg\":{d},\"off\":{d},\"linear\":{d}}}", .{ a.seg, a.off, a.linear });
    if (v.bit_width != 0) try w.print(",\"bit_width\":{d}", .{v.bit_width});
    // An lvalue result advertises `writable` (M-S3 `set_variable` targets it); omitted (false)
    // for the M-S2 read paths so their bodies are unchanged.
    if (v.writable) try w.writeAll(",\"writable\":true");
    try w.print(",\"variables_ref\":{d}}}", .{v.variables_ref});
}

/// Stream `type_ref`'s C-style type name straight into the JSON as a string value (T13 —
/// `typeName` returns void). Renders `"?"` when no symbol overlay covers it. Type names are
/// C identifiers/punctuation (ASCII), emitted via the escaping stringify writer.
fn writeTypeName(s: *SourceDebugger, type_ref: u16, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var scratch: [256]u8 = undefined;
    var sw: std.Io.Writer = .fixed(scratch[0..]);
    if (s.syms) |*sy| {
        if (sy.typegraph) |*tg| {
            tg.typeName(type_ref, &sw) catch {};
        }
    }
    const name = sw.buffered();
    try writeGuestJsonString(w, if (name.len == 0) "?" else name);
}

/// Emit `raw` (guest CP437 bytes — a symbol name or source path) as a JSON string value,
/// transcoding to UTF-8 FIRST (T16c) so a raw high byte can never reach `encodeJsonString`
/// as invalid UTF-8 / a panic. Bounded scratch; a string longer than it is truncated on a
/// codepoint boundary (an honest cap, never a smear — names this long do not occur in the
/// TDS corpus).
fn writeGuestJsonString(w: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    var scratch: [1024]u8 = undefined;
    var n: usize = 0;
    for (raw) |b| {
        var enc: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(core.cp437Scalar(b), &enc) catch continue;
        if (n + len > scratch.len) break;
        @memcpy(scratch[n..][0..len], enc[0..len]);
        n += len;
    }
    try std.json.Stringify.encodeJsonString(scratch[0..n], .{}, w);
}

// ===========================================================================
// Preemptible run drivers (server robustness). The control core runs only deterministic
// bounded bursts and knows nothing of host scheduling (its `src/debug` determinism gate
// forbids atomics); the WORKER (here, `src/api`) drives the burst loop and polls the
// clockless abort flag between bursts. The abort stops the run at a CLEAN INSTRUCTION
// BOUNDARY — the same property a breakpoint/interactive stop has — so the cycles that ran
// are charged identically and the resulting state is a valid deterministic state at that
// cycle (constraint #1). A non-aborted run is byte-identical to the old single call.
// ===========================================================================

/// True iff a control command (`reset`/`stop`) is waiting to seize the worker.
fn preempting(run_ctl: ?*RunControl) bool {
    return if (run_ctl) |rc| rc.preemptRequested() else false;
}

/// A worker-synthesized preemption stop at the current (clean) boundary. Stamps
/// `last_stop` so `status()` stays coherent; the ledger is untouched.
fn stoppedByRequest(ctrl: *Controller) Response {
    return .{ .stop = ctrl.recordExternalStop(.{ .stopped_by_request = .{ .at_cycle = ctrl.currentCycle() } }) };
}

/// Advance a `run`/`run_slice` up to `cycle_cap` cycles, preemptibly. Tracks an ABSOLUTE
/// deadline so the FINAL burst's deadline is exactly `start + cap` — making the chunked run
/// byte-identical to one `runUntilEvent(cap)` (the intermediate bursts only change WHERE the
/// deadline is evaluated, never the instruction stream). A small/bounded cap runs in one shot
/// (no behavioral change at all). Returns `stopped_by_request` if a control command intervenes.
fn runCapPreemptible(ctrl: *Controller, run_ctl: ?*RunControl, cycle_cap: u64) Response {
    // Already-bounded caps (the common case, incl. pacer slices and small runs) run directly:
    // identical to before, and nothing larger than one burst to preempt.
    if (cycle_cap <= PREEMPT_BURST_CYCLES) return .{ .stop = ctrl.runUntilEvent(cycle_cap) };
    const target = ctrl.currentCycle() +| cycle_cap; // saturating: maxInt cap ⇒ run forever (preemptibly)
    while (true) {
        if (preempting(run_ctl)) return stoppedByRequest(ctrl);
        const cur = ctrl.currentCycle();
        if (cur >= target) return .{ .stop = ctrl.recordExternalStop(.{ .cycle_budget_exhausted = .{ .at_cycle = cur } }) };
        const burst = @min(target - cur, PREEMPT_BURST_CYCLES);
        const r = ctrl.runUntilEvent(burst);
        // Only a burst that merely ran out of its budget (target not yet reached) is resumed;
        // any real event (terminal / breakpoint / no_progress) is surfaced immediately.
        if (r != .cycle_budget_exhausted) return .{ .stop = r };
    }
}

/// Drive an armed run-to-target (`run_to_cycle`/`run_to_address`) in bounded bursts,
/// preemptibly. The one-shot fires at the same absolute boundary however the run is sliced,
/// so the result is byte-identical to the single unbounded `runToCycle`/`runToAddress`.
fn runToTargetPreemptible(ctrl: *Controller, run_ctl: ?*RunControl, t: Controller.RunTarget) Response {
    if (t.already) return .{ .stop = ctrl.recordExternalStop(.{ .cycle_budget_exhausted = .{ .at_cycle = ctrl.currentCycle() } }) };
    defer ctrl.endRunTarget(t);
    while (true) {
        if (preempting(run_ctl)) return stoppedByRequest(ctrl);
        const r = ctrl.runTargetBurst(t, PREEMPT_BURST_CYCLES);
        if (r != .cycle_budget_exhausted) return .{ .stop = r }; // target_reached / breakpoint / terminal
    }
}

/// `step_n` in preempt-polled batches. Exact stepping has no overshoot, so this is
/// byte-identical to a single `stepN(n)` (it just stops early on an event or a preemption).
fn stepNPreemptible(ctrl: *Controller, run_ctl: ?*RunControl, n: u64) Response {
    var remaining = n;
    while (remaining > 0) {
        if (preempting(run_ctl)) return stoppedByRequest(ctrl);
        const batch = @min(remaining, PREEMPT_STEP_BATCH);
        const r = ctrl.stepN(batch);
        if (r != .step_complete) return .{ .stop = r };
        remaining -= batch;
    }
    return .{ .stop = ctrl.recordExternalStop(.{ .step_complete = .{ .at_cycle = ctrl.currentCycle() } }) };
}

/// Map the debug-layer `TraceStatus` to the wire `q.TraceStatus` (identical fields).
fn wireTraceStatus(s: debug.TraceStatus) q.TraceStatus {
    return .{
        .armed = s.armed,
        .len = s.len,
        .capacity = s.capacity,
        .total = s.total,
        .kind_mask = s.kind_mask,
        .trap_armed = s.trap_armed,
    };
}

/// Fill a `q.TraceDumpResult` from the ring (mirrors `listBreakpoints`: a stack result
/// filled element-by-element, no alloc). Maps each raw `BranchEntry` to the wire row,
/// computing `from_lin`/`to_lin` (`(seg<<4)+ip`) and the absolute `index`.
fn branchTraceDump(ctrl: *Controller, c: anytype) Response {
    const limit: u32 = @min(c.limit, @as(u32, q.MAX_TRACE_DUMP));
    var scratch: [q.MAX_TRACE_DUMP]cpu_mod.branch_trace.BranchEntry = undefined;
    const entries = ctrl.dumpBranchTrace(scratch[0..limit], c.offset, c.newest_first);
    const status = ctrl.branchTraceStatus();
    var res: q.TraceDumpResult = .{ .capacity = status.capacity, .total = status.total };
    for (entries, 0..) |e, i| {
        // chronological position (from the oldest valid entry) of this row.
        const ii: u32 = @intCast(i);
        const chrono: u32 = if (c.newest_first) (status.len - 1 - c.offset - ii) else (c.offset + ii);
        res.items[i] = .{
            .kind = @enumFromInt(e.kind),
            .from_cs = e.from_cs,
            .from_ip = e.from_ip,
            .to_cs = e.to_cs,
            .to_ip = e.to_ip,
            .from_lin = (@as(u32, e.from_cs) << 4) +% e.from_ip,
            .to_lin = (@as(u32, e.to_cs) << 4) +% e.to_ip,
            .sp = e.sp,
            .at_cycle = e.at_cycle,
            .index = status.total - status.len + chrono,
        };
        res.count += 1;
    }
    return .{ .trace_dump = res };
}

/// Left-Shift make scancode (set-1) — used to bracket a shifted-char keystroke.
const SC_LSHIFT: u8 = 0x2A;

/// Inject a key at the 8042 + raise IRQ1 (Model A). A full output FIFO is a
/// transient resource limit -> input_buffer_full (HTTP 503); never a silent drop
/// (ground rule). For the `{"char"}` convenience (`press`), inject the full
/// make+break (and a Shift bracket when `shift`) as one deterministic command.
fn inputKey(ctrl: *Controller, c: anytype) Response {
    if (!c.press) {
        // A single precise edge (no hold — the mapper rejects `hold_ms` on a raw edge).
        if (ctrl.injectScancode(c.scancode, c.make, c.ext)) return .ok;
        return .{ .err = .input_buffer_full };
    }
    // A held TAP (`hold_ms` present): make (+ Shift bracket) → advance the dwell's
    // cycles → break, so a guest that level-samples raw key state observes the hold.
    // Returns the run stop reason (the cycle delta); a full FIFO surfaces as before.
    if (c.hold_ms) |ms| {
        if (ctrl.tapKey(c.scancode, c.ext, c.shift, ms)) |stop| return .{ .stop = stop };
        return .{ .err = .input_buffer_full };
    }
    // A full keystroke: shift-make? ; key-make ; key-break ; shift-break?
    if (c.shift) {
        if (!ctrl.injectScancode(SC_LSHIFT, true, false)) return .{ .err = .input_buffer_full };
    }
    if (!ctrl.injectScancode(c.scancode, true, c.ext)) return .{ .err = .input_buffer_full };
    if (!ctrl.injectScancode(c.scancode, false, c.ext)) return .{ .err = .input_buffer_full };
    if (c.shift) {
        if (!ctrl.injectScancode(SC_LSHIFT, false, false)) return .{ .err = .input_buffer_full };
    }
    return .ok;
}

/// Drain the coalesced LIVE-mouse record into the INT 33h driver (plans/mouse-input.md,
/// LOCKED §1/§5). The pacer ALWAYS submits `input_mouse_fold` each slice; this is the
/// race-free gate: `takeFold()` returns null UNDER THE MUTEX when the record is clean,
/// so a no-input slice runs NO machine work (zero added cycles — the determinism
/// keystone) and a dirty slice forwards ONE coalesced sample as PLAIN INTEGERS to
/// `Controller.injectMouseSeamless` (the abs write + true-relative mickeys + RAISING
/// IRQ12 for the AX=0Ch callback, which is delivered FOREGROUND via INT 74h on a
/// subsequent slice's run — Option C). No-op when `live` is null (headless/test builds
/// never wire a record).
fn foldLiveMouse(ctrl: *Controller, live: ?*LiveMouseState) Response {
    const lm = live orelse return .ok;
    const fold = lm.takeFold() orelse return .ok; // clean ⇒ zero guest cycles
    ctrl.injectMouseSeamless(
        fold.abs_x_q16,
        fold.abs_y_q16,
        fold.dx,
        fold.dy,
        fold.buttons,
        fold.set_abs,
        fold.set_rel,
        fold.set_buttons,
    );
    return .ok;
}

fn errResp(e: debug.Error) Response {
    return .{ .err = switch (e) {
        error.BreakpointTableFull => .breakpoint_table_full,
        error.NoSuchBreakpoint => .no_such_breakpoint,
    } };
}

// --- breakpoint list / clear (no controller change; via forEachBreakpoint) ---

const ListCtx = struct { out: *q.BpListResult };

fn collectBp(ctx: ListCtx, id: u32, b: *const debug.Breakpoint) void {
    const i = ctx.out.count;
    ctx.out.items[i] = .{ .id = id, .kind = b.kind, .enabled = b.enabled, .one_shot = b.one_shot };
    ctx.out.count += 1;
}

fn listBreakpoints(ctrl: *Controller) Response {
    var result: q.BpListResult = .{};
    ctrl.forEachBreakpoint(ListCtx{ .out = &result }, collectBp);
    return .{ .bp_list = result };
}

const ClearCtx = struct { ids: *[debug.MAX_BREAKPOINTS]u32, n: *u32 };

fn collectId(ctx: ClearCtx, id: u32, b: *const debug.Breakpoint) void {
    _ = b;
    ctx.ids[ctx.n.*] = id;
    ctx.n.* += 1;
}

fn clearBreakpoints(ctrl: *Controller) Response {
    var ids: [debug.MAX_BREAKPOINTS]u32 = undefined;
    var n: u32 = 0;
    ctrl.forEachBreakpoint(ClearCtx{ .ids = &ids, .n = &n }, collectId);
    var removed: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        ctrl.removeBreakpoint(ids[i]) catch continue;
        removed += 1;
    }
    return .{ .cleared = removed };
}

// --- register set (the name→enum mapping happened at the handler) -------------

fn applyRegSet(ctrl: *Controller, c: q.RegSetCmd) Response {
    switch (c) {
        .reg32 => |r| ctrl.setReg32(r.reg, r.value),
        .reg16 => |r| ctrl.setReg16(r.reg, r.value),
        .reg8 => |r| ctrl.setReg8(r.reg, r.value),
        .seg => |r| ctrl.setSegment(r.seg, r.value),
        .eip => |r| ctrl.setEip(r.value),
        .flags => |f| ctrl.setFlags(f),
    }
    return .ok;
}

// --- memory ------------------------------------------------------------------

fn memPeekPhys(ctrl: *Controller, phys: u32, len: u32) Response {
    if (len > q.MAX_MEM_CHUNK) return .{ .err = .out_of_range };
    if (!inSlab(ctrl, phys, len)) return .{ .err = .address_out_of_range };
    var res: q.MemResult = .{ .phys = phys, .len = len };
    ctrl.peekMemPhys(phys, res.bytes[0..len]);
    return .{ .mem = res };
}

fn memWritePhys(ctrl: *Controller, ctx: *RequestCtx, phys: u32, len: u32) Response {
    if (len > q.MAX_MEM_CHUNK) return .{ .err = .out_of_range };
    if (!inSlab(ctrl, phys, len)) return .{ .err = .address_out_of_range };
    ctrl.writeMemPhys(phys, ctx.scratch[0..len]);
    return .{ .mem_written = .{ .phys = phys, .len = len } };
}

// --- memory search -----------------------------------------------------------

fn memSearch(ctrl: *Controller, ctx: *RequestCtx, c: q.MemSearchCmd) Response {
    if (c.needle_len == 0) return .{ .err = .bad_request };
    if (c.needle_len > q.MAX_SEARCH_NEEDLE) return .{ .err = .out_of_range };
    const slab = ctrl.ramSlabSize();
    if (c.start >= slab) return .{ .err = .address_out_of_range };
    // Clamp the haystack window to the slab end (NOT an error — mem-search.md §4).
    const avail = slab - c.start;
    const len = if (c.len == 0) avail else @min(c.len, avail);
    const cap: u16 = if (c.max == 0 or c.max > q.MAX_SEARCH_HITS) q.MAX_SEARCH_HITS else c.max;

    var res: q.SearchResult = .{ .start = c.start, .len = len, .needle_len = c.needle_len, .count = 0, .truncated = false };
    const needle = ctx.scratch[0..c.needle_len];
    const r = ctrl.searchRam(c.start, len, needle, res.hits[0..cap]);
    res.count = r.count;
    res.truncated = r.truncated;
    return .{ .search = res };
}

// --- disassembly -------------------------------------------------------------

fn disasmResp(ctrl: *Controller, origin: debug.DisasmOrigin, count: u16) Response {
    // Reject (never silently truncate) a window larger than the bounded cap.
    if (count == 0 or count > debug.MAX_DISASM_INSNS) return .{ .err = .out_of_range };
    var res: debug.DisasmResult = .{};
    ctrl.disasmWindow(origin, count, &res);
    return .{ .disasm = res };
}

fn segLinear(ctrl: *const Controller, seg: Seg, off: u32) u32 {
    // Mirror the controller's logical→linear computation (real-mode base+off).
    return ctrl.m.cpu.st.seg_base[@intFromEnum(seg)] +% off;
}

fn memPeekSeg(ctrl: *Controller, seg: Seg, off: u32, len: u32) Response {
    if (len > q.MAX_MEM_CHUNK) return .{ .err = .out_of_range };
    const linear = segLinear(ctrl, seg, off);
    if (!inSlab(ctrl, linear, len)) return .{ .err = .address_out_of_range };
    var res: q.MemResult = .{ .phys = linear, .len = len };
    ctrl.peekMem(seg, off, res.bytes[0..len]);
    return .{ .mem = res };
}

fn memWriteSeg(ctrl: *Controller, ctx: *RequestCtx, seg: Seg, off: u32, len: u32) Response {
    if (len > q.MAX_MEM_CHUNK) return .{ .err = .out_of_range };
    const linear = segLinear(ctrl, seg, off);
    if (!inSlab(ctrl, linear, len)) return .{ .err = .address_out_of_range };
    ctrl.writeMem(seg, off, ctx.scratch[0..len]);
    return .{ .mem_written = .{ .phys = linear, .len = len } };
}

fn stackGet(ctrl: *Controller, count: u16) Response {
    if (count > q.MAX_STACK_WORDS) return .{ .err = .out_of_range };
    var res: q.StackResult = .{ .count = count };
    _ = ctrl.peekStack(res.words[0..count]);
    return .{ .stack = res };
}

/// Copy the guest's accumulated CON output into the response POD (side-effect-free:
/// `Controller.console()` reads the device buffer without mutating it, so a read
/// never perturbs the machine — the determinism prime directive). Truncates to the
/// fixed result capacity (the device buffer is the same size, so no truncation in
/// practice).
fn consoleResp(ctrl: *Controller) Response {
    const out = ctrl.console();
    var res: q.ConsoleResult = .{};
    const n = @min(out.len, res.bytes.len);
    @memcpy(res.bytes[0..n], out[0..n]);
    res.len = @intCast(n);
    return .{ .console = res };
}

/// Fill the full text-page cell grid (side-effect-free: `Controller.screen` peeks
/// guest RAM via the bus peek path, never a device read handler). The `?attrs`
/// decision is deferred to serialization (Finding 5), so the worker always copies
/// the complete cells buffer here.
fn screenResp(ctrl: *Controller) Response {
    var res: q.ScreenResult = .{};
    const view = ctrl.screen(res.cells[0..]);
    res.cols = view.cols;
    res.rows = view.rows;
    res.mode = view.mode;
    res.active_page = view.active_page;
    res.cursor_row = view.cursor_row;
    res.cursor_col = view.cursor_col;
    res.len = @intCast(view.cells.len);
    return .{ .screen = res };
}

/// Render the current VGA mode into the SERVER-OWNED render buffers (B1) via the pure
/// peek (`Controller.framebuffer` — side-effect-free: no cycle charge, no DAC-index /
/// AC-flip-flop / latch / device mutation). Returns only the small descriptor; the
/// server streams the selected buffer (index|rgba) as a raw binary body. When the
/// render buffers are absent (an in-process test that never set them) we fail loud
/// with `load_failed` rather than faking a capture into a stack buffer.
fn framebufferResp(ctrl: *Controller, render: ?*RenderBuffers) Response {
    const rb = render orelse return .{ .err = .load_failed };
    const v = ctrl.framebuffer(rb.index[0..], rb.rgba[0..], rb.palette[0..]);
    return .{ .framebuffer = .{
        .kind = v.kind,
        .width = v.width,
        .height = v.height,
        .index_len = v.index_len,
        .rgba_len = v.rgba_len,
        .double_scan = v.double_scan,
        .row_repeat = v.row_repeat,
        .supported = v.supported,
        .palette_present = v.palette_present,
        .pel_mask = v.pel_mask,
    } };
}

fn statusResp(ctrl: *Controller) Response {
    const s = ctrl.status();
    // Map the controller's `running` field to the wire key `runnable` (§B.1/G11).
    return .{ .status = .{
        .runnable = s.running,
        .terminated = s.terminated,
        .ret_code = s.ret_code,
        .cycles = s.cycles,
        .last_stop = s.last_stop,
    } };
}

/// Copy the static region table inline into the response (so server.zig never
/// reads controller state off-worker — keeps the §A.3a grep clean).
fn regionsResp(ctrl: *Controller) Response {
    var res: q.RegionsResult = .{};
    for (ctrl.memoryRegions()) |r| {
        res.items[res.count] = r;
        res.count += 1;
    }
    return .{ .regions = res };
}

/// Re-apply the server-held load recipe (drive/file/cmdtail carried in the
/// command) via `Machine.boot` — the only way to get a runnable machine after
/// `reset()` (§B.1/G16). NOT a controller change: the server re-drives the EXACT
/// fresh-launch boot sequence `main.zig` uses (`Machine.boot` = post + mount +
/// bootProgram), so `reset → load {} → run` reaches byte-identical state vs. a
/// fresh launch. The re-MOUNT is the bug fix: `reset()` wipes the drive table via
/// `dos.init` (`drives = @splat(null)`); `bootProgram` alone would then fail to find
/// the file because drive C: is no longer mounted. `boot` re-establishes the mount
/// (host `dir` + `io` from the server-held `MountSource`) before loading.
fn loadResp(ctrl: *Controller, sd: ?*SourceDebugger, c: q.LoadCmd, mount: MountSource) Response {
    // The mount source MUST be present to re-establish the drive (no fake mount).
    const dir = mount.dir orelse return .{ .err = .load_failed };
    const io = mount.io orelse return .{ .err = .load_failed };
    ctrl.m.boot(c.drive, dir, io, c.file[0..c.file_len], c.cmdtail[0..c.cmdtail_len]) catch
        return .{ .err = .load_failed };
    // Re-attach the host-side symbol overlay for THIS fresh load (debug-core-plan.md
    // §2.1). Host-side, LOAD-TIME ONLY (never the per-cycle path), so determinism-safe:
    // it reads the EXE/.MAP back off the same mount the boot used and re-resolves every
    // retained breakpoint spec against the new load_para. An unreadable image ⇒ no
    // symbols (graceful), never a panic.
    if (sd) |s| attachSymbols(s, dir, io, c.file[0..c.file_len], ctrl.m.dos.current_psp, mount.source_roots);
    // A fresh load invalidates any prior stop; mirror reset's clear so status is
    // coherent. (boot does not own last_stop; clearing it is the server's job —
    // done here on the worker, the sole owner of controller state.)
    ctrl.last_stop = null;
    return .ok;
}

// ===========================================================================
// Snapshot / restore (snapshot-restore-plan §2.3). All four run on the worker (the
// sole machine owner) and reach the per-session `SnapshotStore` via the worker's
// `?*SnapshotStore` back-pointer. When the store is absent (an in-process test harness
// that never wired one) they fail loud with `load_failed` rather than faking a capture.
// ===========================================================================

/// Capture the full live machine into a snapshot slot (PURE READ — charges no cycles,
/// like the other peeks). A full store is `snapshot_limit_reached`; an alloc failure is
/// surfaced as a clean error, never a panic.
fn snapshotResp(ctrl: *Controller, snapshots: ?*SnapshotStore) Response {
    const store = snapshots orelse return .{ .err = .load_failed };
    const info = store.capture(ctrl.m) catch |e| return .{ .err = switch (e) {
        error.LimitReached => .snapshot_limit_reached,
        error.OutOfMemory => .load_failed,
    } };
    return .{ .snapshot_done = .{ .seq = info.seq, .cycle = info.cycle, .bytes = info.bytes } };
}

/// Rewind the machine to a captured snapshot (a deterministic state load at the
/// serialized command boundary; charges no cycles). `Machine.restore` resets
/// `cpu.st.cycles` to the snapshot's; we then re-sync the bus watches with the live
/// breakpoint set (clear-then-rebuild) and clear `last_stop` for a coherent status —
/// breakpoints PERSIST (LOCKED, like `reset`/`load`).
fn restoreResp(ctrl: *Controller, sd: ?*SourceDebugger, snapshots: ?*SnapshotStore, seq: u64) Response {
    const store = snapshots orelse return .{ .err = .load_failed };
    if (!store.applyTo(ctrl.m, seq)) return .{ .err = .no_such_snapshot };
    // Re-arm the snapshot-reverted bus watches from the live breakpoint set (§1.2 #2/D2).
    ctrl.rearmWatches();
    // A revert keeps the same load (load_para unchanged), so neither the Symbols nor the
    // AddressMap rebuilds — only the live frame/step caches are invalidated (debug-core-
    // plan.md §2.2). No reparse, no guest effect.
    if (sd) |s| s.onMachineReverted();
    // A rewind invalidates any prior stop; mirror reset/load's clear so status is coherent.
    ctrl.last_stop = null;
    // Auto-clear the branch trace (docs/branch-trace-plan.md §3/§7): a restore starts a
    // NEW timeline, so prior `at_cycle` coordinates are invalid — a later dump would
    // otherwise interleave two timelines with overlapping `at_cycle`. The clear also
    // drops a stale `trap_hit`. The trace CONFIG (armed/kind_mask/trap) persists, like
    // the breakpoint set; only the timeline CONTENTS are cleared.
    _ = ctrl.clearBranchTrace();
    return .{ .snapshot_restored = .{ .seq = seq } };
}

fn listSnapshotsResp(snapshots: ?*SnapshotStore) Response {
    const store = snapshots orelse return .{ .err = .load_failed };
    return .{ .snapshot_list = store.list() };
}

fn deleteSnapshotResp(snapshots: ?*SnapshotStore, seq: u64) Response {
    const store = snapshots orelse return .{ .err = .load_failed };
    const remaining = store.delete(seq) orelse return .{ .err = .no_such_snapshot };
    return .{ .snapshot_deleted = .{ .seq = seq, .count = remaining } };
}

// ===========================================================================
// Source-level debug core (M-S1). The worker owns the `?*SourceDebugger`; every op
// runs here, on the single machine-owning thread, exactly like every other inspect/
// run command (debug-core-plan.md §1: "no second path to the machine"). The pure core
// stays free of atomics/`src/api`; the WORKER drives the preempt-poll step loop and
// flattens the slice-bearing neutral DTOs into the pointer-free `q.Response` PODs.
// ===========================================================================

/// The largest debug IMAGE (EXE/.MAP) the load-time symbol read will pull off the host
/// mount. A guest program + its embedded TDS is comfortably under this; a larger file ⇒
/// no symbols (graceful), never an unbounded host allocation. Load-path only.
const MAX_DEBUG_IMAGE_BYTES: u64 = 64 * 1024 * 1024;

/// Read a whole host file off the mount `dir` into a fresh `gpa` buffer (caller frees).
/// Host-side, LOAD-TIME ONLY (never the per-cycle path) — it introduces no cycle-time
/// host dependency, so it is determinism-safe (CLAUDE.md §1 governs EMULATED time). Any
/// open/size/read failure ⇒ null (the caller degrades to "no symbols"), never a panic.
fn readHostFile(gpa: std.mem.Allocator, dir: Io.Dir, io: Io, name: []const u8) ?[]u8 {
    var f = dir.openFile(io, name, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    if (len == 0 or len > MAX_DEBUG_IMAGE_BYTES) return null;
    const buf = gpa.alloc(u8, @intCast(len)) catch return null;
    var r = f.reader(io, &.{});
    r.interface.readSliceAll(buf) catch {
        gpa.free(buf);
        return null;
    };
    return buf;
}

/// Swap an 8.3 file's extension for `ext` (e.g. `"BB.EXE"` → `"BB.MAP"`) into `out`,
/// returning the slice (or null if it would not fit). A name with no dot gets `ext`
/// appended. Load-path only; pure string work.
fn sameStem(out: []u8, file: []const u8, ext: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;
    const stem = file[0..dot];
    if (stem.len + ext.len > out.len) return null;
    @memcpy(out[0..stem.len], stem);
    @memcpy(out[stem.len..][0..ext.len], ext);
    return out[0 .. stem.len + ext.len];
}

/// Re-attach the symbol overlay for a fresh load: read the EXE (+ optional `.MAP`
/// sidecar) back off the same mount, then call `SourceDebugger.attachOnLoad`. The temp
/// read buffers are freed once `Symbols.open` has parsed them (it copies what it
/// retains). Load-path only (debug-core-plan.md §2.1).
fn attachSymbols(sd: *SourceDebugger, dir: Io.Dir, io: Io, file: []const u8, psp_seg: u16, roots: ?*const SourceRoots) void {
    const gpa = sd.gpa;
    const exe = readHostFile(gpa, dir, io, file);
    defer if (exe) |b| gpa.free(b);
    var map_name_buf: [16]u8 = undefined;
    const map_bytes = if (sameStem(&map_name_buf, file, ".MAP")) |mn|
        readHostFile(gpa, dir, io, mn)
    else
        null;
    defer if (map_bytes) |b| gpa.free(b);
    sd.attachOnLoad(exe, map_bytes, psp_seg);
    // EAGER source-text cache (debug-source-inlining-plan §A.3): after the overlay exists,
    // resolve every recorded source name across the CONFIGURED roots and hand the owned
    // bytes to the core. Load-time host I/O only (never per-cycle), so determinism-safe.
    if (roots) |r| cacheSourcesFromRoots(sd, io, r);
}

/// Resolve + read every source file the overlay knows, across the configured roots, in
/// ASCENDING `file_id` order (so the cache-admission decision is query-order-independent —
/// finding #8). For each file: try the RELATIVE path (drive/leading-sep stripped, `\`→`/`)
/// under each root in order, then the BASENAME; first hit (root, form) wins and is cached
/// with its root index. Misses are skipped (`window.has=false`). Load-path only.
fn cacheSourcesFromRoots(sd: *SourceDebugger, io: Io, roots: *const SourceRoots) void {
    const gpa = sd.gpa;
    const n = sd.sourceFileCount();
    var file_id: u32 = 0;
    while (file_id < n) : (file_id += 1) {
        const recorded = sd.sourceFileName(file_id) orelse continue;
        var rel_buf: [q.DBG_PATH_CAP]u8 = undefined;
        const rel = relativeSourcePath(&rel_buf, recorded);
        const base = sourceBasename(recorded);
        var root_index: u8 = 0;
        const bytes: ?[]u8 = blk: while (root_index < roots.count) : (root_index += 1) {
            const d = roots.dirs[root_index];
            if (rel) |rp| {
                if (readHostFile(gpa, d, io, rp)) |b| break :blk b;
            }
            if (readHostFile(gpa, d, io, base)) |b| break :blk b;
        } else null;
        if (bytes) |b| {
            defer gpa.free(b);
            sd.cacheSource(file_id, root_index, b);
        }
    }
}

/// The RELATIVE form of a recorded source name: drop a `X:` drive prefix and any leading
/// separators, keep inner dirs, normalize `\`→`/`. Returns null when there is no inner
/// directory (a bare basename — the basename probe alone covers it). `out` must be ≥ the
/// recorded length; an over-long name yields null (basename fallback still applies).
fn relativeSourcePath(out: []u8, recorded: []const u8) ?[]const u8 {
    var s = recorded;
    if (s.len >= 2 and s[1] == ':') s = s[2..]; // drop drive prefix
    while (s.len > 0 and (s[0] == '\\' or s[0] == '/')) s = s[1..]; // leading seps
    // A relative path is only meaningful if it still contains an inner separator.
    var has_sep = false;
    for (s) |c| {
        if (c == '\\' or c == '/') has_sep = true;
    }
    if (!has_sep or s.len == 0 or s.len > out.len) return null;
    for (s, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out[0..s.len];
}

/// The basename of a recorded source name (split on `\` or `/`).
fn sourceBasename(recorded: []const u8) []const u8 {
    var start: usize = 0;
    for (recorded, 0..) |c, i| {
        if (c == '\\' or c == '/') start = i + 1;
    }
    return recorded[start..];
}

/// Map a `core.Error` to the transport-neutral `q.ErrCode`.
fn dbgErr(e: core.Error) Response {
    return .{ .err = switch (e) {
        error.NotStopped => .not_stopped,
        error.NoSymbols => .no_symbols,
        error.Unresolved => .unresolved,
        error.SpecTableFull => .spec_table_full,
        error.BreakpointTableFull => .breakpoint_table_full,
        error.NoSuchBreakpoint => .no_such_breakpoint,
    } };
}

/// Copy `s` into `dst` (truncating to the fixed cap), returning the copied length.
fn copyInline(dst: []u8, s: []const u8) u8 {
    const n = @min(s.len, dst.len);
    @memcpy(dst[0..n], s[0..n]);
    return @intCast(n);
}

/// Flatten a `core.PcLocation` into the pointer-free wire POD.
fn flattenPc(loc: core.PcLocation) q.PcLocationResult {
    var r = q.PcLocationResult{ .seg = loc.addr.seg, .off = loc.addr.off, .linear = loc.addr.linear };
    if (loc.function) |f| {
        r.has_function = true;
        r.func_len = copyInline(&r.func, f);
    }
    if (loc.source) |s| {
        r.has_source = true;
        r.line = s.line;
        r.file_id = s.file_id;
        r.path_len = copyInline(&r.path, s.path);
    }
    return r;
}

/// Flatten a `core.ResolvedBreakpoint` into the pointer-free wire POD (set confirm /
/// list row).
fn flattenBp(rb: core.ResolvedBreakpoint) q.DbgBreakpoint {
    var r = q.DbgBreakpoint{ .id = rb.id, .verified = rb.verified };
    switch (rb.spec) {
        .addr => r.kind = .addr,
        .function => |f| {
            r.kind = .function;
            r.name_len = copyInline(&r.name, f.name);
        },
        .source => |sp| {
            r.kind = .source;
            r.spec_line = sp.line;
            r.name_len = copyInline(&r.name, sp.file);
        },
    }
    if (rb.resolved) |a| {
        r.seg = a.seg;
        r.off = a.off;
        r.linear = a.linear;
    }
    if (rb.source) |s| {
        r.has_source = true;
        r.src_line = s.line;
        r.file_id = s.file_id;
        r.path_len = copyInline(&r.path, s.path);
    }
    return r;
}

/// Flatten a `core.StopState` (source-step / run-to result) into the wire POD.
fn flattenStop(ss: core.StopState) q.DbgStopResult {
    var r = q.DbgStopResult{ .running = ss.running, .cycle = ss.cycle };
    if (ss.kind) |k| {
        r.has_kind = true;
        r.kind = k;
    }
    if (ss.bp_id) |id| {
        r.has_bp_id = true;
        r.bp_id = id;
    }
    if (ss.exit_code) |c| {
        r.has_exit_code = true;
        r.exit_code = c;
    }
    if (ss.pc) |pc| {
        r.has_pc = true;
        r.pc = flattenPc(pc);
    }
    return r;
}

/// Flatten a neutral `core.SourceWindow` into the pointer-free wire POD (copies the
/// borrowed UTF-8 line slices — already transcoded — into the fixed `[DBG_SRC_LINE_CAP]u8`
/// buffers; the core already truncated each to `MAX_LINE_BYTES` on a codepoint boundary).
fn flattenWindow(win: core.SourceWindow) q.SourceWindow {
    var r = q.SourceWindow{
        .has = true,
        .clamped = win.clamped,
        .file_id = win.file_id,
        .active_line = win.active_line,
        .count = @intCast(win.lines.len),
    };
    if (win.root_index) |ri| {
        r.has_root = true;
        r.root = ri;
    }
    for (win.lines, 0..) |ln, i| {
        var sl = q.SourceLine{ .number = ln.number, .active = ln.active, .truncated = ln.truncated };
        const n = @min(ln.text.len, sl.text.len);
        @memcpy(sl.text[0..n], ln.text[0..n]);
        sl.len = @intCast(n);
        r.lines[i] = sl;
    }
    return r;
}

/// Build the inlined source window for `(file_id, line, context)`; `has=false` when the
/// file is not cached (no source root configured / basename in no root / over cap). Pure
/// in-memory render — no host I/O, no machine touch.
fn buildWindow(s: *SourceDebugger, file_id: u32, line: u32, context: u16) q.SourceWindow {
    var scratch: [core.MAX_WINDOW_LINES]core.SrcLine = undefined;
    const win = s.sourceWindow(file_id, line, context, &scratch) orelse return .{};
    return flattenWindow(win);
}

fn dbgWhere(sd: ?*SourceDebugger, context: u16) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    const loc = s.pcLocation() catch |e| return dbgErr(e);
    var r = flattenPc(loc);
    if (r.has_source) r.window = buildWindow(s, r.file_id, r.line, context);
    return .{ .dbg_where = r };
}

fn dbgSetSrcBp(sd: ?*SourceDebugger, c: q.DbgSrcBpCmd) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    const rb = s.setBreakpoint(.{ .source = .{ .file = c.file[0..c.file_len], .line = c.line } }) catch |e| return dbgErr(e);
    return .{ .dbg_bp_set = bpSet(s, rb, c.context) };
}

fn dbgSetFnBp(sd: ?*SourceDebugger, c: q.DbgFnBpCmd) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    const rb = s.setBreakpoint(.{ .function = .{ .name = c.name[0..c.name_len] } }) catch |e| return dbgErr(e);
    return .{ .dbg_bp_set = bpSet(s, rb, q.DBG_CONTEXT_DEFAULT) };
}

/// The R6 set-confirm POD: the flattened breakpoint + a placement window centered on the
/// BOUND source line (so the agent visually confirms the resolution). No source ⇒ has=false.
fn bpSet(s: *SourceDebugger, rb: core.ResolvedBreakpoint, context: u16) q.DbgBpSetResult {
    var r = q.DbgBpSetResult{ .bp = flattenBp(rb) };
    if (r.bp.has_source) r.window = buildWindow(s, r.bp.file_id, r.bp.src_line, context);
    return r;
}

/// `read_source` — a windowed view of any source file, addressed by an echoed `file_id`
/// or a name (resolved exact→basename). NOT gated on Stopped (a pure cache read).
fn dbgReadSource(sd: ?*SourceDebugger, c: q.DbgReadSrcCmd) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    var file_id: u32 = undefined;
    if (c.has_file_id) {
        file_id = c.file_id;
    } else {
        if (s.sourceFileCount() == 0) return .{ .err = .no_symbols };
        file_id = s.fileIdForName(c.file[0..c.file_len]) orelse return .{ .err = .unresolved };
    }
    return .{ .dbg_source = buildWindow(s, file_id, c.line, c.context) };
}

/// `list_sources` — a thin pass-through over `sourceFileCount`/`sourceFileName`, plus the
/// per-file `cached` flag (so the agent knows which files have windows).
fn dbgListSources(sd: ?*SourceDebugger) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    var res: q.SourceFilesResult = .{};
    const n = @min(s.sourceFileCount(), @as(u32, q.DBG_MAX_SOURCES));
    var file_id: u32 = 0;
    while (file_id < n) : (file_id += 1) {
        const name = s.sourceFileName(file_id) orelse continue;
        var row = q.SourceFile{ .file_id = file_id, .cached = s.isSourceCached(file_id) };
        row.path_len = copyInline(&row.path, name);
        res.items[res.count] = row;
        res.count += 1;
    }
    return .{ .dbg_sources = res };
}

fn dbgClearBp(sd: ?*SourceDebugger, id: u32) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    s.clearBreakpoint(id) catch |e| return dbgErr(e);
    return .ok;
}

fn dbgListBp(sd: ?*SourceDebugger) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    var specs: [q.DBG_MAX_SPECS]core.ResolvedBreakpoint = undefined;
    const list = s.listBreakpoints(&specs);
    var res: q.DbgBpListResult = .{};
    for (list) |rb| {
        res.items[res.count] = flattenBp(rb);
        res.count += 1;
    }
    return .{ .dbg_bp_list = res };
}

/// The WORKER-side preempt-poll source-step DRIVER (debug-core-plan.md §5, Finding 1).
/// Mirrors `runToTargetPreemptible`: `beginStep` then loop the pure BOUNDED
/// `stepBurst(STEP_BURST_CYCLES)`, polling the clockless preempt flag BETWEEN bursts so
/// a `pause`/`reset`/new-breakpoint from another frontend lands at a burst boundary as a
/// `.pause` stop — under the fixed anti-wedge `STEP_WEDGE_CAP_CYCLES` ceiling. The pure
/// core never polls an atomic / imports `src/api`; the budget + cap are FIXED compile-
/// time cycle constants (defined in the core), never host-derived.
fn dbgStep(ctrl: *Controller, sd: ?*SourceDebugger, run_ctl: ?*RunControl, kind: core.StepKind, file: ?[]const u8, line: u32, context: u16) Response {
    const s = sd orelse return .{ .err = .not_implemented };
    s.beginStep(kind, file, line) catch |e| return dbgErr(e);
    var spent: u64 = 0;
    while (true) {
        if (preempting(run_ctl)) {
            s.endStep();
            const reason = ctrl.recordExternalStop(.{ .stopped_by_request = .{ .at_cycle = ctrl.currentCycle() } });
            return .{ .dbg_stop = stopWithWindow(s, s.projectStop(reason), context) };
        }
        switch (s.stepBurst(core.STEP_BURST_CYCLES)) {
            .stopped => |ss| return .{ .dbg_stop = stopWithWindow(s, ss, context) },
            .budget_exhausted => {
                spent +|= core.STEP_BURST_CYCLES;
                if (spent >= core.STEP_WEDGE_CAP_CYCLES) {
                    s.endStep();
                    const reason = ctrl.recordExternalStop(.{ .step_complete = .{ .at_cycle = ctrl.currentCycle() } });
                    return .{ .dbg_stop = stopWithWindow(s, s.projectStop(reason), context) };
                }
            },
        }
    }
}

/// Flatten a stop and inline the source window on its `pc` (M-S1.5), when the PC resolved
/// to a source line. No source ⇒ `pc.window.has=false`.
fn stopWithWindow(s: *SourceDebugger, ss: core.StopState, context: u16) q.DbgStopResult {
    var r = flattenStop(ss);
    if (r.has_pc and r.pc.has_source) r.pc.window = buildWindow(s, r.pc.file_id, r.pc.line, context);
    return r;
}

// ===========================================================================
// The worker thread entry: loop `waitDequeue → drainOne → complete`; exit on the
// shutdown sentinel.
// ===========================================================================

pub const Worker = struct {
    queue: *q.CommandQueue,
    ctrl: *Controller,
    /// The host mount source for `load` re-mounts (set by the server at startup).
    mount_dir: ?Io.Dir = null,
    io: ?Io = null,
    /// The server-owned render buffers for `GET /api/framebuffer` (B1). Null in a test
    /// harness that never drives a capture; a `framebuffer_get` then fails loud.
    render: ?*RenderBuffers = null,
    /// The server-owned coalesced LIVE-mouse record (plans/mouse-input.md, LOCKED §1).
    /// Null in headless/test builds (the keystone: no record ⇒ the fold arm is a no-op
    /// ⇒ zero added cycles ⇒ byte-identical to today). Set by the server at `--serve`.
    live_mouse: ?*LiveMouseState = null,
    /// The server-owned per-session snapshot store (snapshot-restore-plan §2.2). Null in
    /// a test harness that never wired one (snapshot/restore then fail loud). Set by the
    /// server at both worker-spawn sites, exactly like `render`/`live_mouse`.
    snapshots: ?*SnapshotStore = null,
    /// The session's clockless run-control block — the worker polls its abort flag
    /// (`preemptRequested`) BETWEEN bounded run bursts so a wedged/unbounded run yields
    /// promptly to a `reset`/`stop`. Null in in-process tests (no preemption ⇒ a run still
    /// completes byte-identically). Set by the server / registry at the worker-spawn sites,
    /// exactly like `render`/`live_mouse`/`snapshots`.
    run_ctl: ?*RunControl = null,
    /// The session's source-level debug core (debug-core-plan.md §1). Null in a test
    /// harness that never wired one (the `dbg_*` commands then fail loud). Set by the
    /// server / registry at the worker-spawn sites, exactly like `render`/`run_ctl`.
    sd: ?*SourceDebugger = null,
    /// The session-owned nested-JSON slab (M-S2 seam, debug-m2-plan.md §1.1). The worker
    /// serializes ONE nested debug body into it while Stopped and returns only the
    /// `body_len`. Null in a test harness that never wired one (a `dbg_json_*` command then
    /// fails loud with `load_failed`). Set by the server / registry at the worker-spawn
    /// sites, exactly like `render`/`sd` (missing one regresses provisioned machines).
    dbg_json: ?*DebugJsonBuffer = null,
    /// The session's configured source-search roots (M-S1.5) — a stable `*const SourceRoots`
    /// the worker borrows for the load-time source-text reads. Null ⇒ no source windows.
    /// Set by the server / registry at the worker-spawn sites, beside `.sd`/`.mount_dir`.
    source_roots: ?*const SourceRoots = null,
    /// The initially-loaded program (from the session recipe), for the STARTUP symbol
    /// attach (investigation point #3): the default `--serve` session boots via
    /// `bootProgram` BEFORE any debug command, so without this initial `attachOnLoad`
    /// `whereami` would see no symbols until an explicit `load`. Copied from the recipe
    /// at the construction site (worker.zig must not import session.zig — a cycle).
    initial_file: [13]u8 = undefined,
    initial_file_len: u8 = 0,

    pub fn run(self: Worker) void {
        const mount: MountSource = .{ .dir = self.mount_dir, .io = self.io, .source_roots = self.source_roots };
        // Startup symbol attach for the program the machine already booted (investigation
        // point #3): read the EXE/.MAP off the mount and build the overlay for the live
        // load, on THIS (the machine-owning) thread, before servicing any command — so a
        // freshly-served program answers `whereami` without an explicit `load` first.
        if (self.sd) |sd| {
            if (self.initial_file_len != 0) {
                if (mount.dir) |dir| if (mount.io) |io|
                    attachSymbols(sd, dir, io, self.initial_file[0..self.initial_file_len], self.ctrl.m.dos.current_psp, self.source_roots);
            }
        }
        // Publish the initial settled status so a never-commanded machine reports correct
        // cycles/mult to `GET /api/machines` (which reads these atomics off-worker).
        self.publishStatus();
        while (true) {
            const ctx = self.queue.waitDequeue();
            if (ctx.cmd == .shutdown_worker) {
                self.queue.complete(ctx, .ok);
                return;
            }
            const resp = drainOne(self.ctrl, ctx, mount, self.render, self.live_mouse, self.snapshots, self.run_ctl, self.sd, self.dbg_json);
            self.queue.complete(ctx, resp);
            // Stamp the published cycle/mult AFTER each command so `/api/machines` can report
            // this machine's status WITHOUT submitting to (and being blocked by) this worker —
            // the keystone that keeps the machine LIST responsive while a guest wedges.
            self.publishStatus();
        }
    }

    /// Stamp the session's clockless published cycle/mult from the live machine (a pure read;
    /// host-observability only — never an emulation input). No-op when no run-control is wired
    /// (in-process tests), which simply leaves `/api/machines` to fall back to a `status` submit.
    fn publishStatus(self: Worker) void {
        if (self.run_ctl) |rc| rc.publishStatus(self.ctrl.currentCycle(), self.ctrl.clockMult());
    }
};
