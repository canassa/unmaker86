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

const Controller = debug.Controller;
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
pub fn drainOne(ctrl: *Controller, ctx: *RequestCtx, mount: MountSource, render: ?*RenderBuffers) Response {
    return switch (ctx.cmd) {
        // ---- run / step ----------------------------------------------------
        .run => |c| .{ .stop = ctrl.runUntilEvent(c.cycle_cap) },
        // A paced free-run slice — identical to `.run`, a bounded deterministic
        // `runUntilEvent`. The host run-pacer submits this each wall-clock tick;
        // the worker just runs the slice on the single owned controller. The
        // returned `StopReason` lets the pacer disarm on a terminal (§10).
        .run_slice => |c| .{ .stop = ctrl.runUntilEvent(c.slice_cycles) },
        .run_to_cycle => |c| .{ .stop = ctrl.runToCycle(c.cycle) catch |e| return errResp(e) },
        .run_to_address => |c| .{ .stop = ctrl.runToAddress(c.linear) catch |e| return errResp(e) },
        .step => .{ .stop = ctrl.stepInstruction() },
        .step_n => |c| .{ .stop = ctrl.stepN(c.n) },
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
            // Mutate INT 33h driver state at the one-command-in-flight boundary
            // (no host clock, no sample-rate gate). Always succeeds — driver-state
            // injection has no FIFO to overflow (unlike the 8042 key path).
            ctrl.injectMouse(c);
            break :blk .ok;
        },

        // ---- session -------------------------------------------------------
        .console_get => consoleResp(ctrl),
        .screen_get => screenResp(ctrl),
        .framebuffer_get => framebufferResp(ctrl, render),
        .status => statusResp(ctrl),
        .reset => blk: {
            ctrl.reset() catch return .{ .err = .load_failed };
            break :blk .ok;
        },
        .load => |c| loadResp(ctrl, c, mount),
        .mem_regions => regionsResp(ctrl),

        .shutdown_worker => .ok,
    };
}

/// Left-Shift make scancode (set-1) — used to bracket a shifted-char keystroke.
const SC_LSHIFT: u8 = 0x2A;

/// Inject a key at the 8042 + raise IRQ1 (Model A). A full output FIFO is a
/// transient resource limit -> input_buffer_full (HTTP 503); never a silent drop
/// (ground rule). For the `{"char"}` convenience (`press`), inject the full
/// make+break (and a Shift bracket when `shift`) as one deterministic command.
fn inputKey(ctrl: *Controller, c: anytype) Response {
    if (!c.press) {
        // A single precise edge.
        if (ctrl.injectScancode(c.scancode, c.make, c.ext)) return .ok;
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
fn loadResp(ctrl: *Controller, c: q.LoadCmd, mount: MountSource) Response {
    // The mount source MUST be present to re-establish the drive (no fake mount).
    const dir = mount.dir orelse return .{ .err = .load_failed };
    const io = mount.io orelse return .{ .err = .load_failed };
    ctrl.m.boot(c.drive, dir, io, c.file[0..c.file_len], c.cmdtail[0..c.cmdtail_len]) catch
        return .{ .err = .load_failed };
    // A fresh load invalidates any prior stop; mirror reset's clear so status is
    // coherent. (boot does not own last_stop; clearing it is the server's job —
    // done here on the worker, the sole owner of controller state.)
    ctrl.last_stop = null;
    return .ok;
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

    pub fn run(self: Worker) void {
        const mount: MountSource = .{ .dir = self.mount_dir, .io = self.io };
        while (true) {
            const ctx = self.queue.waitDequeue();
            if (ctx.cmd == .shutdown_worker) {
                self.queue.complete(ctx, .ok);
                return;
            }
            const resp = drainOne(self.ctrl, ctx, mount, self.render);
            self.queue.complete(ctx, resp);
        }
    }
};
