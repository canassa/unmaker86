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

const Controller = debug.Controller;
const Seg = cpu_mod.Seg;
const Command = q.Command;
const Response = q.Response;
const RequestCtx = q.RequestCtx;
const ErrCode = q.ErrCode;

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
pub fn drainOne(ctrl: *Controller, ctx: *RequestCtx) Response {
    return switch (ctx.cmd) {
        // ---- run / step ----------------------------------------------------
        .run => |c| .{ .stop = ctrl.runUntilEvent(c.cycle_cap) },
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

        // ---- session -------------------------------------------------------
        .status => statusResp(ctrl),
        .reset => blk: {
            ctrl.reset() catch return .{ .err = .load_failed };
            break :blk .ok;
        },
        .load => |c| loadResp(ctrl, c),
        .mem_regions => .{ .regions = {} }, // serialized from the static table at the handler

        .shutdown_worker => .ok,
    };
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

/// Re-apply the server-held load recipe (drive/file/cmdtail carried in the
/// command) via `Machine.bootProgram` — the only way to get a runnable machine
/// after `reset()` (§B.1/G16). NOT a controller change: the server re-drives
/// `bootProgram` exactly as `main.zig` does.
fn loadResp(ctrl: *Controller, c: q.LoadCmd) Response {
    ctrl.m.bootProgram(c.drive, c.file[0..c.file_len], c.cmdtail[0..c.cmdtail_len]) catch
        return .{ .err = .load_failed };
    // A fresh load invalidates any prior stop; mirror reset's clear so status is
    // coherent. (bootProgram does not own last_stop; clearing it is the server's
    // job — done here on the worker, the sole owner of controller state.)
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

    pub fn run(self: Worker) void {
        while (true) {
            const ctx = self.queue.waitDequeue();
            if (ctx.cmd == .shutdown_worker) {
                self.queue.complete(ctx, .ok);
                return;
            }
            const resp = drainOne(self.ctrl, ctx);
            self.queue.complete(ctx, resp);
        }
    }
};
