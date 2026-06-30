//! `SourceDebugger` — the protocol-neutral, source-level debug core object (M-S1).
//!
//! It holds a `*Controller` (the synchronous run/peek substrate) plus a host-side
//! Borland TDS symbol overlay (`Symbols` + the runtime `AddressMap`) re-attached on
//! every load — exactly the `LoadRecipe` precedent. It implements: attach-on-load,
//! `pcLocation`, source/function/addr breakpoint resolution (+ re-resolution across a
//! reload), and the four source-step kinds.
//!
//! Worker-side stepping split (debug-core-plan.md §5, Finding 1): this module is on the
//! `src/debug` determinism grep-gate, so it may NOT poll `RunControl.preemptRequested()`
//! (an atomic) and may NOT import `src/api`. It therefore exposes only the BOUNDED burst
//! primitive `stepBurst(budget) -> StepOutcome` (after a `beginStep`); the WORKER owns
//! the preempt-polling loop around it. A pure, non-preemptible convenience
//! (`stepLine`/`stepIn`/`stepOut`/`runToLine`) loops the burst to completion under the
//! fixed `STEP_WEDGE_CAP_CYCLES` ceiling — used by in-process tests and the simplest
//! blocking callers. Both share `beginStep` + `stepBurst` so the stop semantics are one
//! implementation.
//!
//! Determinism (CLAUDE.md §1): pure + synchronous. Run/step/run-to compose existing
//! `Controller` primitives; breakpoints are `execution_address{linear}` (no new kind);
//! inspection is the side-effect-free peek path. The only machine state the symbol path
//! consumes is `psp_seg`, via `AddressMap.attach`. No host clock/RNG/atomic/thread/float.

const std = @import("std");
const core = @import("core.zig");
const controller = @import("../controller.zig");
const symbols = @import("../symbols/symbols.zig");

const Controller = controller.Controller;
const StopReason = controller.StopReason;
const Symbols = symbols.Symbols;
const AddressMap = symbols.AddressMap;

const Addr = core.Addr;
const SourceLoc = core.SourceLoc;
const PcLocation = core.PcLocation;
const BreakpointSpec = core.BreakpointSpec;
const ResolvedBreakpoint = core.ResolvedBreakpoint;
const StopKind = core.StopKind;
const StopState = core.StopState;
const StepKind = core.StepKind;
const StepOutcome = core.StepOutcome;

pub const Error = error{
    /// An inspection / step op was issued while a (background) run was in flight — the
    /// live BP/SP/registers are only meaningful at a clean instruction boundary.
    NotStopped,
    /// A source/function op needs the symbol overlay, which is absent (stripped image).
    NoSymbols,
    /// A `file:line` / function name resolved to no code address.
    Unresolved,
    /// The fixed 64-slot breakpoint spec table is full.
    SpecTableFull,
    /// Propagated from `Controller.addBreakpoint`.
    BreakpointTableFull,
    NoSuchBreakpoint,
};

/// Max source/function/addr breakpoint specs (mirrors `BreakpointSet`'s 64).
pub const MAX_SPECS = 64;

const SlotKind = enum { addr, function, source };

/// One persisted breakpoint spec ↔ its resolved `Controller` breakpoint id. The spec
/// text is OWNED (copied) so it survives the frontend's buffer and a reload.
const SpecSlot = struct {
    active: bool = false,
    kind: SlotKind = .addr,
    ctrl_id: ?u32 = null, // the underlying Controller breakpoint id (null ⇒ unresolved)
    linear: u32 = 0,
    verified: bool = false,
    line: u32 = 0,
    name_len: u8 = 0,
    name_buf: [128]u8 = undefined, // file path (source) or function name (function)

    fn name(self: *const SpecSlot) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn setName(self: *SpecSlot, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

const LineKey = struct { file_id: u32, line: u16 };

/// The cross-burst state of an in-flight source step (the `beginRunToAddress` analog).
const StepSession = struct {
    active: bool = false,
    kind: StepKind = .line,
    start_line: ?LineKey = null,
    start_sp: u32 = 0, // the 16-bit SP captured at begin (frame anchor)
    oneshot_id: ?u32 = null, // the return / target one-shot (stepOut / runToLine)
    ret_linear: u32 = 0, // the stepOut return address (re-armed past a recursion false-hit)
    guard_sp: u32 = 0, // SP once the stepped-out frame tears down
};

const State = enum { configuring, running, stopped, terminated };

pub const SourceDebugger = struct {
    gpa: std.mem.Allocator,
    ctrl: *Controller,
    /// The symbol overlay for the currently-loaded program (rebuilt by `attachOnLoad`).
    /// Heap-stable address (the SourceDebugger itself is heap-owned by the Session), so
    /// `map` may borrow `&self.syms.?.index`.
    syms: ?Symbols = null,
    map: ?AddressMap = null,
    specs: [MAX_SPECS]SpecSlot = @splat(.{}),
    step: StepSession = .{},
    state: State = .configuring,

    pub fn init(gpa: std.mem.Allocator, ctrl: *Controller) SourceDebugger {
        return .{ .gpa = gpa, .ctrl = ctrl };
    }

    pub fn deinit(self: *SourceDebugger) void {
        if (self.syms) |*s| s.deinit();
        self.syms = null;
        self.map = null;
    }

    // ─────────────────────────── attach-on-load ───────────────────────────

    /// Re-attach the symbol overlay for a fresh load (load / reset+load). Frees the prior
    /// overlay, opens a new one from the EXE bytes (precedence embedded-TDS → `.map` →
    /// none), attaches the runtime map at `psp_seg`, and re-resolves every breakpoint spec
    /// to its NEW linear (load_para changed). An OOM / unreadable image ⇒ `syms = none`,
    /// never a panic. Load-path only (never per-cycle), so determinism-safe.
    pub fn attachOnLoad(self: *SourceDebugger, exe: ?[]const u8, opt_map: ?[]const u8, psp_seg: u16) void {
        if (self.syms) |*old| old.deinit();
        self.syms = null;
        self.map = null;
        if (exe) |bytes| {
            self.syms = Symbols.open(self.gpa, bytes, opt_map) catch null;
        }
        if (self.syms != null) self.map = self.syms.?.attach(psp_seg);
        self.reresolveBreakpoints();
        self.step = .{};
        self.state = .configuring;
    }

    /// A restore reverted the machine to a prior cycle (load_para unchanged). Only the
    /// live frame/step caches are invalidated; symbols / specs persist. No reparse, no
    /// guest effect (debug-core-plan.md §2.2 / architecture §3.3).
    pub fn onMachineReverted(self: *SourceDebugger) void {
        self.step = .{};
        self.state = .stopped;
    }

    fn reresolveBreakpoints(self: *SourceDebugger) void {
        for (0..MAX_SPECS) |i| {
            if (self.specs[i].active) self.resolveSlot(i) catch {};
        }
    }

    // ─────────────────────────── breakpoints ───────────────────────────

    pub fn setBreakpoint(self: *SourceDebugger, spec: BreakpointSpec) Error!ResolvedBreakpoint {
        const slot = self.freeSlot() orelse return error.SpecTableFull;
        var s = &self.specs[slot];
        s.* = .{ .active = true };
        switch (spec) {
            .addr => |a| {
                s.kind = .addr;
                s.linear = a.linear;
            },
            .function => |f| {
                s.kind = .function;
                s.setName(f.name);
            },
            .source => |src| {
                s.kind = .source;
                s.setName(src.file);
                s.line = src.line;
            },
        }
        try self.resolveSlot(slot);
        return self.resolvedFor(slot);
    }

    pub fn clearBreakpoint(self: *SourceDebugger, id: u32) Error!void {
        if (id >= MAX_SPECS or !self.specs[id].active) return error.NoSuchBreakpoint;
        const s = &self.specs[id];
        if (s.ctrl_id) |cid| self.ctrl.removeBreakpoint(cid) catch {};
        s.* = .{};
    }

    pub fn listBreakpoints(self: *SourceDebugger, out: []ResolvedBreakpoint) []ResolvedBreakpoint {
        var n: usize = 0;
        for (0..MAX_SPECS) |i| {
            if (n >= out.len) break;
            if (self.specs[i].active) {
                out[n] = self.resolvedFor(i);
                n += 1;
            }
        }
        return out[0..n];
    }

    fn freeSlot(self: *SourceDebugger) ?usize {
        for (0..MAX_SPECS) |i| if (!self.specs[i].active) return i;
        return null;
    }

    /// (Re)compute a slot's linear + arm/replace its `Controller` breakpoint.
    fn resolveSlot(self: *SourceDebugger, slot: usize) Error!void {
        var s = &self.specs[slot];
        if (s.ctrl_id) |cid| {
            self.ctrl.removeBreakpoint(cid) catch {};
            s.ctrl_id = null;
        }
        s.verified = false;
        if (self.resolveLinear(s)) |linear| {
            s.linear = linear;
            s.ctrl_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = linear } }, false);
            s.verified = true;
        }
    }

    fn resolveLinear(self: *SourceDebugger, s: *const SpecSlot) ?u32 {
        switch (s.kind) {
            .addr => return s.linear,
            .function => {
                const m = self.map orelse return null;
                const idx = &self.syms.?.index;
                const sym = idx.nameToSymbol(s.name()) orelse return null;
                const f = idx.addrToFunction(sym.segment, sym.offset) orelse return null;
                return m.entryAddrForFunction(f);
            },
            .source => {
                const m = self.map orelse return null;
                const idx = &self.syms.?.index;
                const fid = idx.fileId(s.name()) orelse return null;
                return m.runtimeAddrForLine(fid, @intCast(s.line));
            },
        }
    }

    fn resolvedFor(self: *SourceDebugger, slot: usize) ResolvedBreakpoint {
        const s = &self.specs[slot];
        var rb = ResolvedBreakpoint{
            .id = @intCast(slot),
            .spec = self.specOf(s),
            .verified = s.verified,
        };
        if (s.verified) {
            rb.resolved = self.addrFor(s.linear);
            if (self.map) |m| {
                if (m.lineForRuntimeAddr(s.linear)) |lh| rb.source = self.sourceLocOf(lh.file_id, lh.line);
            }
        }
        return rb;
    }

    fn specOf(self: *SourceDebugger, s: *const SpecSlot) BreakpointSpec {
        _ = self;
        return switch (s.kind) {
            .addr => .{ .addr = .{ .linear = s.linear } },
            .function => .{ .function = .{ .name = s.name() } },
            .source => .{ .source = .{ .file = s.name(), .line = s.line } },
        };
    }

    // ─────────────────────────── location ───────────────────────────

    /// Where the PC is, fully resolved. Rejected when a run is in flight (the live
    /// CS:IP would be a mid-burst value). Valid in Configuring / Stopped.
    pub fn pcLocation(self: *SourceDebugger) Error!PcLocation {
        if (self.state == .running) return error.NotStopped;
        return self.pcLocationUnchecked();
    }

    fn pcLocationUnchecked(self: *SourceDebugger) PcLocation {
        const snap = self.ctrl.cpuSnapshot();
        const pc = snap.cs_base +% snap.eip;
        var loc = PcLocation{ .addr = .{ .seg = snap.cs, .off = @truncate(snap.eip), .linear = pc } };
        if (self.map) |m| {
            if (m.functionForRuntimeAddr(pc)) |f| loc.function = self.syms.?.index.functionName(f);
            if (m.lineForRuntimeAddr(pc)) |lh| loc.source = self.sourceLocOf(lh.file_id, lh.line);
        }
        return loc;
    }

    fn sourceLocOf(self: *SourceDebugger, file_id: u32, line: u16) SourceLoc {
        const path = if (self.syms) |*s| (s.index.sourceFile(file_id) orelse "") else "";
        return .{ .file_id = file_id, .path = path, .line = line };
    }

    fn addrFor(self: *SourceDebugger, linear: u32) Addr {
        var a = Addr{ .seg = 0, .off = 0, .linear = linear };
        if (self.map) |m| {
            if (m.imageAddrForLinear(linear)) |ia| {
                a.seg = ia.segment;
                a.off = ia.offset;
            }
        }
        return a;
    }

    // ─────────────────────────── stop projection ───────────────────────────

    /// The ONE place the raw `Controller.StopReason` union is read (design §4.6). Sets
    /// the session `state` and (unless terminated) resolves the stop's `PcLocation`.
    pub fn projectStop(self: *SourceDebugger, reason: StopReason) StopState {
        var ss = StopState{ .running = false, .kind = null, .pc = null, .cycle = 0 };
        switch (reason) {
            .breakpoint => |b| {
                ss.cycle = b.at_cycle;
                if (self.isOwnOneshot(b.id)) {
                    ss.kind = .step;
                } else {
                    ss.kind = .breakpoint;
                    ss.bp_id = self.handleForCtrlId(b.id);
                }
            },
            .step_complete => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .target_reached => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .dwell_complete => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .cycle_budget_exhausted => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .program_terminated => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .exit;
                ss.exit_code = c.ret_code;
            },
            .shutdown => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .halted_forever => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .terminated;
            },
            .branch_trap => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .no_progress => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .stopped_by_request => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .pause;
            },
        }
        self.state = switch (ss.kind.?) {
            .exit, .terminated => .terminated,
            else => .stopped,
        };
        if (self.state != .terminated) ss.pc = self.pcLocationUnchecked();
        return ss;
    }

    fn isOwnOneshot(self: *SourceDebugger, id: u32) bool {
        return self.step.active and self.step.oneshot_id != null and self.step.oneshot_id.? == id;
    }

    fn handleForCtrlId(self: *SourceDebugger, id: u32) ?u32 {
        for (0..MAX_SPECS) |i| {
            const sl = &self.specs[i];
            if (sl.active and sl.ctrl_id != null and sl.ctrl_id.? == id) return @intCast(i);
        }
        return null;
    }

    // ─────────────────────────── stepping ───────────────────────────

    /// Begin a source step (the `beginRunToAddress` analog). Captures the frame anchor
    /// (`start_line` + `start_sp`) and arms any one-shot (`stepOut` return / `runToLine`
    /// target). `file`/`line` are only consulted for `.to_line`.
    pub fn beginStep(self: *SourceDebugger, kind: StepKind, file: ?[]const u8, line: u32) Error!void {
        const snap = self.ctrl.cpuSnapshot();
        self.step = .{
            .active = true,
            .kind = kind,
            .start_line = self.lineKey(snap.cs_base +% snap.eip),
            .start_sp = @as(u16, @truncate(snap.esp)),
        };
        self.state = .running;
        switch (kind) {
            .line, .in => {},
            .out => try self.armStepOut(snap),
            .to_line => {
                const m = self.map orelse {
                    self.step = .{};
                    return error.NoSymbols;
                };
                const f = file orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                const fid = self.syms.?.index.fileId(f) orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                const lin = m.runtimeAddrForLine(fid, @intCast(line)) orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                self.step.oneshot_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = lin } }, true);
            },
        }
    }

    fn armStepOut(self: *SourceDebugger, snap: anytype) Error!void {
        const bpv: u16 = @truncate(snap.ebp);
        // far/near from the CURRENT function's TDS return type (`FuncRef` carries none).
        var far = false;
        if (self.map) |m| {
            if (m.functionForRuntimeAddr(snap.cs_base +% snap.eip)) |f| {
                if (self.syms.?.index.typeRefForFunction(f)) |t| {
                    if (self.syms.?.typegraph) |*tg| {
                        if (tg.typeInfo(t)) |ti| {
                            if (ti == .function) far = ti.function.far;
                        }
                    }
                }
            }
        }
        var b2: [2]u8 = undefined;
        self.ctrl.peekMem(.ss, @as(u32, bpv) +% 2, &b2);
        const retip = std.mem.readInt(u16, &b2, .little);
        var ret_linear: u32 = undefined;
        if (far) {
            var b4: [2]u8 = undefined;
            self.ctrl.peekMem(.ss, @as(u32, bpv) +% 4, &b4);
            const retcs = std.mem.readInt(u16, &b4, .little);
            ret_linear = (@as(u32, retcs) << 4) +% retip;
        } else {
            ret_linear = snap.cs_base +% retip;
        }
        self.step.ret_linear = ret_linear;
        self.step.guard_sp = @as(u32, bpv) + (if (far) @as(u32, 4) else @as(u32, 2));
        self.step.oneshot_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = ret_linear } }, true);
    }

    /// End / cancel the in-flight step (removes a still-armed one-shot). Idempotent.
    pub fn endStep(self: *SourceDebugger) void {
        if (self.step.oneshot_id) |oid| self.ctrl.removeBreakpoint(oid) catch {};
        self.step = .{};
    }

    /// One BOUNDED step burst (Finding 1). Runs up to `budget` stepped cycles, returning
    /// either a real `.stopped` (qualifying line / terminal / user-breakpoint) or
    /// `.budget_exhausted` (no qualifying stop yet — the WORKER then polls preempt and
    /// re-enters). NO atomics, NO preempt poll. `beginStep` must precede it.
    pub fn stepBurst(self: *SourceDebugger, budget: u64) StepOutcome {
        std.debug.assert(self.step.active);
        const start = self.ctrl.currentCycle();
        while (self.ctrl.currentCycle() -% start < budget) {
            switch (self.step.kind) {
                .line => if (self.lineStepOnce()) |ss| {
                    self.endStep();
                    return .{ .stopped = ss };
                },
                .in => if (self.inStepOnce()) |ss| {
                    self.endStep();
                    return .{ .stopped = ss };
                },
                // run-to-one-shot kinds consume the rest of the burst in one run.
                .out, .to_line => return self.targetBurst(budget, start),
            }
        }
        return .budget_exhausted;
    }

    /// `stepLine` / `next` inner step (§5.2): step OVER calls, stop at the next source
    /// line at the same-or-shallower frame. Null ⇒ keep going.
    fn lineStepOnce(self: *SourceDebugger) ?StopState {
        const res = self.ctrl.stepOver();
        if (res.reason != .step_complete) return self.projectStop(res.reason);
        const snap = self.ctrl.cpuSnapshot();
        const cur = self.lineKey(snap.cs_base +% snap.eip);
        const cur_sp: u32 = @as(u16, @truncate(snap.esp));
        if (cur) |ck| {
            const changed = if (self.step.start_line) |sl|
                !(sl.file_id == ck.file_id and sl.line == ck.line)
            else
                true;
            if (changed and cur_sp >= self.step.start_sp)
                return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
            if (cur_sp > self.step.start_sp)
                return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
        }
        return null;
    }

    /// `stepIn` inner step (§5.3): plain step (enters calls); stop on a NEW symbolized
    /// line. A callee with no debug info degrades to `stepLine` carrying the ORIGINAL
    /// `start_sp` anchor (so it runs back out instead of stranding one instruction in).
    fn inStepOnce(self: *SourceDebugger) ?StopState {
        const res = self.ctrl.stepInstruction();
        if (res != .step_complete) return self.projectStop(res);
        const pc = self.livePc();
        const cur = self.lineKey(pc);
        if (cur) |ck| {
            const changed = if (self.step.start_line) |sl|
                !(sl.file_id == ck.file_id and sl.line == ck.line)
            else
                true;
            if (changed) {
                if (self.map.?.functionForRuntimeAddr(pc) != null)
                    return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
                // unsymbolized callee: run back out with the original frame anchor.
                self.step.kind = .line;
            }
        }
        return null;
    }

    /// `stepOut` / `runToLine` burst: run to the armed one-shot. For `stepOut`, a hit
    /// below `guard_sp` is a recursion false-hit (re-arm, yield); a hit at/above it is
    /// the real return.
    fn targetBurst(self: *SourceDebugger, budget: u64, start: u64) StepOutcome {
        const elapsed = self.ctrl.currentCycle() -% start;
        const rem = if (budget > elapsed) budget - elapsed else 1;
        const r = self.ctrl.runUntilEvent(rem);
        switch (r) {
            .cycle_budget_exhausted => return .budget_exhausted,
            .breakpoint => |b| {
                if (self.step.oneshot_id != null and b.id == self.step.oneshot_id.?) {
                    const cur_sp: u32 = @as(u16, @truncate(self.ctrl.cpuSnapshot().esp));
                    if (self.step.kind == .to_line or cur_sp >= self.step.guard_sp) {
                        const ss = self.projectStop(.{ .step_complete = .{ .at_cycle = b.at_cycle } });
                        self.endStep();
                        return .{ .stopped = ss };
                    }
                    // recursion false-hit: the one-shot auto-removed itself; re-arm.
                    self.step.oneshot_id = self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = self.step.ret_linear } }, true) catch null;
                    return .budget_exhausted;
                }
                const ss = self.projectStop(r);
                self.endStep();
                return .{ .stopped = ss };
            },
            else => {
                const ss = self.projectStop(r);
                self.endStep();
                return .{ .stopped = ss };
            },
        }
    }

    // ── pure, non-preemptible convenience (tests / simplest blocking callers) ──

    pub fn stepLine(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.line, null, 0);
    }
    pub fn stepIn(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.in, null, 0);
    }
    pub fn stepOut(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.out, null, 0);
    }
    pub fn runToLine(self: *SourceDebugger, file: []const u8, line: u32) Error!StopState {
        return self.runStepBlocking(.to_line, file, line);
    }

    fn runStepBlocking(self: *SourceDebugger, kind: StepKind, file: ?[]const u8, line: u32) Error!StopState {
        try self.beginStep(kind, file, line);
        var spent: u64 = 0;
        while (true) {
            switch (self.stepBurst(core.STEP_BURST_CYCLES)) {
                .stopped => |ss| return ss,
                .budget_exhausted => {
                    spent +|= core.STEP_BURST_CYCLES;
                    if (spent >= core.STEP_WEDGE_CAP_CYCLES) {
                        self.endStep();
                        return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
                    }
                },
            }
        }
    }

    // ─────────────────────────── helpers ───────────────────────────

    fn livePc(self: *SourceDebugger) u32 {
        const snap = self.ctrl.cpuSnapshot();
        return snap.cs_base +% snap.eip;
    }

    fn lineKey(self: *SourceDebugger, linear: u32) ?LineKey {
        const m = self.map orelse return null;
        const lh = m.lineForRuntimeAddr(linear) orelse return null;
        return .{ .file_id = lh.file_id, .line = lh.line };
    }
};

test {
    std.testing.refAllDecls(@This());
}
