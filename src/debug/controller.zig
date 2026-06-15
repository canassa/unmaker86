//! The debugger control core (M1 §3): the synchronous, in-process facade that
//! OWNS the run loop and drives the machine's `run_loop.step` primitive directly,
//! scanning its own `BreakpointSet` between steps. It is ABOVE `machine` in the
//! module graph, so holding a `*Machine` is legal. No function pointer on the
//! machine, no `*anyopaque`, no type erasure.
//!
//! Determinism (CLAUDE prime directive): the controller only READS the cycle
//! ledger — the CPU stays the sole writer. It never reads host time, never spawns
//! a thread, never polls. "Pausing" = returning from `runUntilEvent`, leaving the
//! ledger exactly where the last retired step put it (no smear, no host-time gap —
//! the whole point vs. Spice86's wall-clock poll). Inspection is side-effect-free
//! (the bus peek path), so an inspect leaves `machine.snapshot()` byte-identical.
//!
//! Created AFTER `Machine.wire()` (pinning invariant). It holds a `*Machine` and
//! must not outlive the machine. Every method is synchronous and returns a value
//! or a typed error.

const std = @import("std");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const bp = @import("breakpoints.zig");

const Machine = machine_mod.Machine;
const Reg32 = cpu_mod.Reg32;
const Seg = cpu_mod.Seg;
const Flags = cpu_mod.Flags;
const BreakpointSet = bp.BreakpointSet;
const BreakpointKind = bp.BreakpointKind;
const Breakpoint = bp.Breakpoint;
const Error = bp.Error;

const bus_mod = @import("bus");
const memmap = bus_mod.memmap;
const WatchAccess = bus_mod.WatchAccess;
const AccessKind = bp.AccessKind;

const SS = @intFromEnum(Seg.ss);
const ESP = @intFromEnum(Reg32.esp);

/// Map the debug-layer `AccessKind` onto the bus `WatchAccess` (1:1 by value; the
/// bus cannot import `debug`, so the enum is duplicated and bridged here).
fn toWatchAccess(a: AccessKind) WatchAccess {
    return switch (a) {
        .read => .read,
        .write => .write,
        .access => .access,
    };
}

/// The rich, debug-layer stop reason (a superset of `Machine.StopReason`). It is
/// part of the observable, reproducible result, so its production order is fixed
/// and tested (see `runUntilEvent`).
pub const StopReason = union(enum) {
    /// A user (persistent or one-shot) breakpoint fired: which id, and the ledger
    /// value at that boundary.
    breakpoint: struct { id: u32, at_cycle: u64 },
    /// A step / stepN / stepOver finished one or more retired instructions.
    step_complete: struct { at_cycle: u64 },
    /// The cycle cap was reached with no terminal/breakpoint.
    cycle_budget_exhausted: struct { at_cycle: u64 },
    /// Deterministic permanent HLT (no pending events, not wakeable).
    halted_forever,
    /// The DOS program terminated (INT 21h AH=4C / INT 20h). `ret_code` is the
    /// full DOS exit word (`dos.ret_code` is u16 — low byte = AL exit code, high
    /// byte = exit type per AH=4D), carried verbatim rather than truncated.
    program_terminated: struct { ret_code: u16 },
    /// Triple fault / shutdown latched.
    shutdown,
};

pub const StepOverResult = struct {
    reason: StopReason,
    /// true if we could not step *over* and fell back to step-into (reported,
    /// never silent — ground rule).
    stepped_into: bool,
};

/// A side-effect-free CPU register/flag/cycle snapshot. Field order for the GP
/// registers mirrors `Reg32`'s encoding `{eax,ecx,edx,ebx,esp,ebp,esi,edi}` —
/// filled FIELD-BY-FIELD via the typed enum, never an index loop over a struct
/// whose field order differs from the enum.
pub const CpuSnapshot = struct {
    eax: u32,
    ecx: u32,
    edx: u32,
    ebx: u32,
    esp: u32,
    ebp: u32,
    esi: u32,
    edi: u32,
    cs: u16,
    ds: u16,
    es: u16,
    fs: u16,
    gs: u16,
    ss: u16,
    cs_base: u32,
    ds_base: u32,
    es_base: u32,
    fs_base: u32,
    gs_base: u32,
    ss_base: u32,
    eip: u32,
    cf: bool,
    pf: bool,
    af: bool,
    zf: bool,
    sf: bool,
    df: bool,
    of: bool,
    iff: bool,
    tf: bool,
    nt: bool,
    rf: bool,
    vm: bool,
    ac: bool,
    cycles: u64,
    halted: bool,
    shutdown: bool,
};

/// 8/16-bit register identity — explicit enums (the State setters take a raw u3;
/// AH..BH are indices 4..7). The facade owns the mapping; it does NOT pretend
/// `Reg32` covers 8/16-bit.
pub const Reg16 = enum(u3) { ax, cx, dx, bx, sp, bp, si, di };
pub const Reg8 = enum(u3) { al, cl, dl, bl, ah, ch, dh, bh };

/// A memory region descriptor (so an M2 readMem client can validate ranges).
pub const Region = struct {
    kind: enum { ram, vram, ems_frame },
    phys_start: u32,
    len: u32,
};

/// A fully-resolved mouse injection (input-injection.md §5.2, Phase 2). Pointer-
/// free POD: it carries both ABSOLUTE (`x`/`y`) and RELATIVE (`dx`/`dy`) motion +
/// a `buttons` mask, each gated by its `set_*` flag, so a caller can update any
/// subset. The wire→this resolution (mutual-exclusion check, defaults) happens at
/// the server; the controller just applies it.
pub const MouseInject = struct {
    x: i16 = 0,
    y: i16 = 0,
    dx: i16 = 0,
    dy: i16 = 0,
    buttons: u16 = 0,
    set_x: bool = false,
    set_y: bool = false,
    set_dx: bool = false,
    set_dy: bool = false,
    set_buttons: bool = false,
};

pub const Controller = struct {
    m: *Machine,
    set: BreakpointSet = .{},
    last_stop: ?StopReason = null,
    /// For each breakpoint id, the bus watch-table slot it armed (M1 Phase 5), or
    /// null for a non-`memory` breakpoint. Lets `removeBreakpoint` clear exactly
    /// the watch a `memory` breakpoint armed. Parallel to `set.items[]`; defined
    /// POD (no pointers), so it is snapshot-safe like the rest.
    watch_ids: [bp.MAX_BREAKPOINTS]?u16 = @splat(null),

    /// Construct a controller over an ALREADY-wired machine (pinning invariant).
    /// The controller must not outlive the machine.
    pub fn init(m: *Machine) Controller {
        return .{ .m = m };
    }

    // -----------------------------------------------------------------------
    // Run / step (Phase 2: runUntilEvent; stepping lands in Phase 3).
    // -----------------------------------------------------------------------

    /// Advance until a terminal, a breakpoint, or `cycle_cap` cycles elapse.
    /// Synchronous. Steps AT LEAST ONCE before checking breakpoints (the resume
    /// rule: a continue from a persistent exec bp must step off it, not re-fire).
    ///
    /// Per-boundary precedence (fixed & tested, constraint #5/#6):
    ///   1. Terminal beats breakpoint: shutdown → program_terminated →
    ///      halted_forever (the first that holds).
    ///   2. Else the lowest-id matching enabled breakpoint (ascending-id scan is
    ///      the total tie-break). EVERY matching one-shot at this boundary is
    ///      consumed (disabled), not only the reported one; persistent matches are
    ///      untouched.
    ///   3. Else, if the cycle cap is reached, cycle_budget_exhausted.
    pub fn runUntilEvent(self: *Controller, cycle_cap: u64) StopReason {
        self.last_stop = null; // clear so a stale value can't leak
        const deadline = self.m.cpu.st.cycles +| cycle_cap;
        while (true) {
            // Resume rule: step at least once before evaluating breakpoints. We
            // also check terminals AFTER stepping (you cannot step a terminal
            // machine — but the first thing we do each loop is step, and a
            // terminal machine's step is a no-op that surfaces the terminal).
            if (self.terminalReason()) |r| return self.record(r);

            const seq_before = bp.seqBefore(self.m);
            _ = self.m.step();

            if (self.terminalReason()) |r| return self.record(r);
            if (self.scanBreakpoints(seq_before)) |r| return self.record(r);

            if (self.m.cpu.st.cycles >= deadline) {
                return self.record(.{ .cycle_budget_exhausted = .{ .at_cycle = self.m.cpu.st.cycles } });
            }
        }
    }

    /// The fixed terminal-precedence check at a boundary (returns null if the
    /// machine is not terminal). Order: shutdown → program_terminated →
    /// halted_forever.
    fn terminalReason(self: *const Controller) ?StopReason {
        if (self.m.cpu.st.shutdown or self.m.shutdown) return .shutdown;
        if (self.m.dos.terminated) return .{ .program_terminated = .{ .ret_code = self.m.dos.ret_code } };
        if (self.permanentlyHalted()) return .halted_forever;
        return null;
    }

    /// A permanent HLT: the CPU is halted, no events are scheduled, and it is not
    /// wakeable. Mirrors `run_loop`'s `.halted_forever` rule WITHOUT mutating
    /// state (a pure read-only query — getPendingInterrupt is pure).
    fn permanentlyHalted(self: *const Controller) bool {
        const st = &self.m.cpu.st;
        if (!st.halted) return false;
        if (self.m.sched.nextEventCycle() != std.math.maxInt(u64)) return false;
        if (st.pending_fault != null) return false;
        if (st.nmi_pending() and !st.nmi_in_service) return false;
        if (st.eflags.iff and self.m.pic.getPendingInterrupt() != null) return false;
        return true;
    }

    /// Scan `items[]` in ascending id order. Consume EVERY matching one-shot at
    /// this boundary; report the lowest-id match (one-shot or persistent). Returns
    /// null if nothing matched. The `active_count` gate short-circuits the common
    /// no-breakpoints case in one bool test.
    fn scanBreakpoints(self: *Controller, seq_before: bp.SeqBefore) ?StopReason {
        if (self.set.active_count == 0) return null;
        var reported: ?StopReason = null;
        var id: u32 = 0;
        while (id < bp.MAX_BREAKPOINTS) : (id += 1) {
            if (!self.set.used[id]) continue;
            const b = &self.set.items[id];
            if (!bp.matches(b, self.m, seq_before)) continue;
            // Lowest id wins (the scan is ascending, so the first match is it).
            if (reported == null) {
                reported = .{ .breakpoint = .{ .id = id, .at_cycle = self.m.cpu.st.cycles } };
            }
            // Consume EVERY matching one-shot (its contract is "at most once").
            if (b.one_shot) {
                b.enabled = false;
            }
        }
        if (reported != null) self.set.recomputeActive();
        return reported;
    }

    fn record(self: *Controller, r: StopReason) StopReason {
        self.last_stop = r;
        return r;
    }

    // -----------------------------------------------------------------------
    // Breakpoint management (typed errors, not asserts — reachable from M2).
    // -----------------------------------------------------------------------

    pub fn addBreakpoint(self: *Controller, kind: BreakpointKind, one_shot: bool) Error!u32 {
        const id = try self.set.add(kind, one_shot);
        // A `memory` breakpoint arms a bus watch over its range (M1 Phase 5): the
        // covered page(s) become `.watched` so accesses are checked per byte. We
        // remember the watch slot to clear it exactly on removal. Mapping the
        // debug `AccessKind` onto the bus `WatchAccess` 1:1 (same encoding).
        if (kind == .memory) {
            const k = kind.memory;
            const wid = self.m.bus.setWatch(.{
                .linear = k.linear,
                .len = k.len,
                .access = toWatchAccess(k.access),
            }) catch {
                // Bus watch table full: roll back the breakpoint slot and surface a
                // clean error (never a panic; reachable from the M2 API). We reuse
                // BreakpointTableFull rather than inventing a new Error variant so
                // the public Error set stays stable (M2 maps it to a 4xx).
                self.set.remove(id) catch unreachable;
                return error.BreakpointTableFull;
            };
            self.watch_ids[id] = wid;
        }
        return id;
    }
    pub fn removeBreakpoint(self: *Controller, id: u32) Error!void {
        // Clear the bus watch first (if this bp armed one), then the slot. Order
        // matters only for the (impossible) re-entrant case; both are local.
        if (id < bp.MAX_BREAKPOINTS) {
            if (self.watch_ids[id]) |wid| {
                self.m.bus.clearWatch(wid);
                self.watch_ids[id] = null;
            }
        }
        return self.set.remove(id);
    }
    pub fn enableBreakpoint(self: *Controller, id: u32, on: bool) Error!void {
        return self.set.enable(id, on);
    }
    pub fn getBreakpoint(self: *const Controller, id: u32) Error!Breakpoint {
        return self.set.get(id);
    }
    pub fn forEachBreakpoint(
        self: *const Controller,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), u32, *const Breakpoint) void,
    ) void {
        self.set.forEach(ctx, f);
    }

    // -----------------------------------------------------------------------
    // Stepping & run-to (Phase 3) — built on one-shot breakpoints + run_loop.step.
    // -----------------------------------------------------------------------

    /// Execute exactly ONE retired instruction. If the machine is ALREADY terminal
    /// (shutdown / program_terminated / permanent-HLT) it does NOT step — it
    /// returns the terminal reason (you cannot step a terminal machine; a shutdown
    /// CPU's `step` is a 0-cycle no-op, which would punch a hole in the ledger
    /// semantics). Otherwise charges exactly the instruction's real cycles (one
    /// `run_loop.step`) and returns `step_complete`.
    pub fn stepInstruction(self: *Controller) StopReason {
        self.last_stop = null;
        if (self.terminalReason()) |r| return self.record(r);
        _ = self.m.step();
        // A step may itself reach a terminal (e.g. the instruction was HLT with no
        // events, or it triple-faulted) — surface that, else step_complete.
        if (self.terminalReason()) |r| return self.record(r);
        return self.record(.{ .step_complete = .{ .at_cycle = self.m.cpu.st.cycles } });
    }

    /// `n`× `stepInstruction`, stopping early on any fired persistent/one-shot
    /// breakpoint or terminal. Returns the reason of the stop (`step_complete` if
    /// all `n` retired without an event).
    pub fn stepN(self: *Controller, n: u64) StopReason {
        self.last_stop = null;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.terminalReason()) |r| return self.record(r);
            const seq_before = bp.seqBefore(self.m);
            _ = self.m.step();
            if (self.terminalReason()) |r| return self.record(r);
            if (self.scanBreakpoints(seq_before)) |r| return self.record(r);
        }
        return self.record(.{ .step_complete = .{ .at_cycle = self.m.cpu.st.cycles } });
    }

    /// Set a one-shot cycle breakpoint at `c`, then `runUntilEvent`. If `c <=`
    /// current cycles, returns IMMEDIATELY (no step) with
    /// `cycle_budget_exhausted{at_cycle = current}` — documented (the requested
    /// cycle is already in the past).
    pub fn runToCycle(self: *Controller, c: u64) Error!StopReason {
        if (c <= self.m.cpu.st.cycles) {
            return self.record(.{ .cycle_budget_exhausted = .{ .at_cycle = self.m.cpu.st.cycles } });
        }
        const id = try self.set.add(.{ .cycle = .{ .at_cycle = c } }, true);
        defer self.discardOneShot(id);
        return self.runUntilEvent(std.math.maxInt(u64));
    }

    /// Set a one-shot `execution_address` breakpoint at `linear`, then
    /// `runUntilEvent`.
    pub fn runToAddress(self: *Controller, linear: u32) Error!StopReason {
        const id = try self.set.add(.{ .execution_address = .{ .linear = linear } }, true);
        defer self.discardOneShot(id);
        return self.runUntilEvent(std.math.maxInt(u64));
    }

    /// Remove a transient one-shot used by run-to/step-over (idempotent: it may
    /// already have been consumed+disabled, but the slot is still `used`).
    fn discardOneShot(self: *Controller, id: u32) void {
        self.set.remove(id) catch {};
    }

    /// Step OVER a direct CALL/INT by running to its return; otherwise == step
    /// into. Returns `StepOverResult{reason, stepped_into}` — the `stepped_into`
    /// flag reports a fallback to step-into (never a silent degrade, ground rule).
    ///
    /// We classify only the opcodes we can size cheaply from the FIRST byte at
    /// CS:IP (read via the side-effect-free peek path): `0xE8` near `CALL rel`,
    /// `0x9A` far `CALL ptr`, `0xCD` `INT imm8`. For these we execute the call/INT
    /// itself (one step), then set a one-shot `execution_address` bp at the pushed
    /// return linear address, SP-GUARDED so recursion is correct (a deeper re-entry
    /// to the same address does not trip it). Everything else (indirect CALL, REP,
    /// prefixed, far RET sizing) falls back to `stepInstruction` with
    /// `stepped_into = true`.
    pub fn stepOver(self: *Controller) StepOverResult {
        self.last_stop = null;
        if (self.terminalReason()) |r| return .{ .reason = self.record(r), .stepped_into = false };

        const cs_base = self.m.cpu.st.seg_base[@intFromEnum(Seg.cs)];
        const ip_linear = cs_base +% self.m.cpu.st.eip;
        const opcode = self.m.bus.peekPhys8(ip_linear);
        const direct_call = opcode == 0xE8 or opcode == 0x9A or opcode == 0xCD;
        if (!direct_call) {
            // Fall back to step-into (reported).
            return .{ .reason = self.stepInstruction(), .stepped_into = true };
        }

        // A far CALL (0x9A) and INT (0xCD) push CS too, so the return CS is the
        // pushed value; a near CALL (0xE8) pushes only IP and returns in the
        // current CS. We classified this from the opcode BEFORE stepping.
        const is_far = opcode == 0x9A or opcode == 0xCD;

        // The return CS:IP and SP-at-return are known only AFTER the call/INT
        // executes (it pushes them). Execute the call itself (one step), then read
        // the pushed return address off the stack via the peek path and the new SP.
        _ = self.m.step();
        // The call may itself terminate (an INT that triple-faults, etc).
        if (self.terminalReason()) |r| return .{ .reason = self.record(r), .stepped_into = false };

        const ret_linear = self.returnSiteAfterCall(is_far);
        const guard_sp = self.m.cpu.st.getReg16(ESP); // SP just after the push(es)
        const id = self.set.add(
            .{ .execution_address = .{ .linear = ret_linear } },
            true,
        ) catch {
            // Table full: degrade to step-into rather than panic (ground rule).
            return .{ .reason = self.record(.{ .step_complete = .{ .at_cycle = self.m.cpu.st.cycles } }), .stepped_into = true };
        };
        defer self.discardOneShot(id);

        // Run to the return, but the one-shot must only fire when SS:SP has unwound
        // back to (>=) the guard SP — so a recursive re-entry to the same linear at
        // a deeper SP does not trip it. We loop runUntilEvent and re-arm until the
        // SP guard is satisfied (or a different event/terminal fires).
        while (true) {
            const r = self.runUntilEvent(std.math.maxInt(u64));
            switch (r) {
                .breakpoint => |hit| {
                    if (hit.id != id) return .{ .reason = r, .stepped_into = false }; // some OTHER user bp
                    // Our return bp fired. Honor the SP guard: only accept it once
                    // the stack has unwound to or above the post-call SP.
                    if (self.m.cpu.st.getReg16(ESP) >= guard_sp) {
                        return .{ .reason = self.record(.{ .step_complete = .{ .at_cycle = self.m.cpu.st.cycles } }), .stepped_into = false };
                    }
                    // Recursive re-entry at a deeper SP: re-arm the one-shot and
                    // keep running (the address matched but the guard rejects it).
                    self.set.items[id].enabled = true;
                    self.set.recomputeActive();
                },
                else => return .{ .reason = r, .stepped_into = false }, // terminal / budget
            }
        }
    }

    /// The linear return address pushed by the just-executed direct CALL/INT,
    /// read SIDE-EFFECT-FREE from the top of the SS stack. Real-mode pushes are
    /// 16-bit; IP is at [SS:SP] (the lowest word). For a near CALL the return runs
    /// in the CURRENT CS (unchanged); for a far CALL / INT the caller CS was pushed
    /// at [SS:SP+2], so the return runs there. `is_far` selects which.
    fn returnSiteAfterCall(self: *const Controller, is_far: bool) u32 {
        const ss_base = self.m.cpu.st.seg_base[SS];
        const sp = self.m.cpu.st.getReg16(ESP);
        var w: [4]u8 = undefined;
        self.m.bus.peekBlock(ss_base +% sp, &w);
        const ret_ip = @as(u16, w[0]) | (@as(u16, w[1]) << 8);
        const ret_cs = @as(u16, w[2]) | (@as(u16, w[3]) << 8);
        const cs_base = if (is_far)
            @as(u32, ret_cs) << 4
        else
            self.m.cpu.st.seg_base[@intFromEnum(Seg.cs)];
        return cs_base +% ret_ip;
    }

    // -----------------------------------------------------------------------
    // Mutate (Phase 3). A debugger write is a deliberate new INPUT; the
    // determinism guarantee is "same binary + SAME INPUTS". The core never
    // mutates implicitly — only on an explicit set*/writeMem. Writes go through
    // the real bus write path.
    // -----------------------------------------------------------------------

    pub fn setReg32(self: *Controller, r: Reg32, v: u32) void {
        self.m.cpu.writeReg32(r, v);
    }
    pub fn setReg16(self: *Controller, r: Reg16, v: u16) void {
        self.m.cpu.st.setReg16(@intFromEnum(r), v);
    }
    pub fn setReg8(self: *Controller, r: Reg8, v: u8) void {
        self.m.cpu.st.setReg8(@intFromEnum(r), v);
    }
    pub fn setSegment(self: *Controller, s: Seg, sel: u16) void {
        self.m.cpu.loadSegment(s, sel); // recomputes the base (real-mode sel<<4)
    }
    pub fn setEip(self: *Controller, v: u32) void {
        self.m.cpu.patchEip(v);
    }
    pub fn setFlags(self: *Controller, f: Flags) void {
        self.m.cpu.st.eflags = f;
    }
    /// Write `src` to a logical `seg:off` view (through the real bus write path).
    pub fn writeMem(self: *Controller, seg: Seg, off: u32, src: []const u8) void {
        const linear = self.m.cpu.st.seg_base[@intFromEnum(seg)] +% off;
        self.m.bus.writeGuestBlock(linear, src);
    }
    /// Write `src` to a guest physical address (through the real bus write path).
    pub fn writeMemPhys(self: *Controller, phys: u32, src: []const u8) void {
        self.m.bus.writeGuestBlock(phys, src);
    }

    /// Inject a keyboard scancode at the 8042 controller and raise IRQ1 directly
    /// (Model A, input-injection.md §4.1). A debugger key injection is a deliberate
    /// new INPUT (the "same binary + SAME INPUTS" category, like setReg/writeMem):
    /// it mutates the 8042 output buffer at the current cycle-exact boundary, and
    /// the guest INT 09h ISR delivers it on the NEXT `run`/`step`. Setting the PIC
    /// IRR via `pushScancode` is timing-neutral (M-D6) — no scheduler entry, no
    /// ledger hole; the ISR's cost is charged by the normal fetch/execute loop.
    ///
    /// `make` false pushes a key-up (break = `scancode|0x80`); `ext` true prepends
    /// the 0xE0 extended prefix. Returns false if the 8042 output FIFO is full (the
    /// caller surfaces `input_buffer_full`); never silently drops (ground rule).
    pub fn injectScancode(self: *Controller, scancode: u8, make: bool, ext: bool) bool {
        const code = if (make) scancode else scancode | 0x80;
        if (ext) {
            // The 0xE0 prefix + the code are two output-buffer bytes; require room
            // for BOTH so a half-injected extended key never strands a lone prefix.
            if (self.m.kbd.fifoFree() < 2) return false;
            _ = self.m.kbd.pushScancode(0xE0);
        }
        return self.m.kbd.pushScancode(code);
    }

    /// Inject a mouse event into the INT 33h driver state (Model A,
    /// input-injection.md §5.2, Phase 2). A debugger mouse injection is a
    /// deliberate new INPUT (the "same binary + SAME INPUTS" category, like
    /// setReg/injectScancode): it mutates `dos.mouse` driver state at the current
    /// cycle-exact boundary, with NO host clock and NO sample-rate gate, and the
    /// guest observes it on the next AX=0003/AX=000B (the next `run`/`step`).
    ///
    /// `req` carries both ABSOLUTE (x/y) and RELATIVE (dx/dy) motion plus buttons;
    /// each is applied only when its `set_*` flag is set. Absolute and relative are
    /// mutually exclusive per axis at the API layer (the server rejects mixing);
    /// here we apply absolute first (verbatim range-clamped) then relative (the
    /// fixed-point mickey path), so a caller that sets neither leaves position
    /// untouched. Buttons are applied once (a relative call carries the same mask).
    pub fn injectMouse(self: *Controller, req: MouseInject) void {
        const mouse = &self.m.dos.mouse;
        if (req.set_x or req.set_y) {
            // Buttons ride with the absolute set if relative isn't also setting them.
            const btn_here = req.set_buttons and !(req.set_dx or req.set_dy);
            mouse.injectAbsolute(req.x, req.y, req.buttons, req.set_x, req.set_y, btn_here);
        }
        if (req.set_dx or req.set_dy or req.set_buttons) {
            mouse.injectRelative(req.dx, req.dy, req.buttons, req.set_dx, req.set_dy, req.set_buttons);
        }
    }

    // -----------------------------------------------------------------------
    // Session reset (Phase 3, open question #5 resolved: included in M1).
    // -----------------------------------------------------------------------

    /// Re-initialize the machine deterministically to power-on state. Honors the
    /// pinning invariant (`Machine.reset` re-establishes the callback routing /
    /// re-wires `svc`; it does NOT move the machine). RAM is re-zeroed and every
    /// device is reset, so a reset reaches byte-identical power-on state every
    /// time. NOTE: the caller is responsible for re-loading the same program /
    /// inputs afterward (exactly as `main.zig` does post()+bootProgram()) — the
    /// controller does not own the program-load recipe, and faking one here would
    /// violate the ground rule. Clears `last_stop`; the breakpoint set survives
    /// (a debug session's breakpoints outlive a machine reset).
    pub fn reset(self: *Controller) !void {
        self.m.reset();
        self.last_stop = null;
    }

    // -----------------------------------------------------------------------
    // Inspect — SIDE-EFFECT-FREE peek path (never routes through device read
    // handlers, which mutate device state).
    // -----------------------------------------------------------------------

    /// Pure register/flag/cycle snapshot. Filled field-by-field via the typed
    /// enums (Reg32 / Seg) so field order can never silently diverge.
    pub fn cpuSnapshot(self: *const Controller) CpuSnapshot {
        const cpu = &self.m.cpu;
        const st = &cpu.st;
        const f = st.eflags;
        return .{
            .eax = cpu.readReg32(.eax),
            .ecx = cpu.readReg32(.ecx),
            .edx = cpu.readReg32(.edx),
            .ebx = cpu.readReg32(.ebx),
            .esp = cpu.readReg32(.esp),
            .ebp = cpu.readReg32(.ebp),
            .esi = cpu.readReg32(.esi),
            .edi = cpu.readReg32(.edi),
            .cs = cpu.readSegSelector(.cs),
            .ds = cpu.readSegSelector(.ds),
            .es = cpu.readSegSelector(.es),
            .fs = cpu.readSegSelector(.fs),
            .gs = cpu.readSegSelector(.gs),
            .ss = cpu.readSegSelector(.ss),
            .cs_base = st.seg_base[@intFromEnum(Seg.cs)],
            .ds_base = st.seg_base[@intFromEnum(Seg.ds)],
            .es_base = st.seg_base[@intFromEnum(Seg.es)],
            .fs_base = st.seg_base[@intFromEnum(Seg.fs)],
            .gs_base = st.seg_base[@intFromEnum(Seg.gs)],
            .ss_base = st.seg_base[@intFromEnum(Seg.ss)],
            .eip = st.eip,
            .cf = f.cf,
            .pf = f.pf,
            .af = f.af,
            .zf = f.zf,
            .sf = f.sf,
            .df = f.df,
            .of = f.of,
            .iff = f.iff,
            .tf = f.tf,
            .nt = f.nt,
            .rf = f.rf,
            .vm = f.vm,
            .ac = f.ac,
            .cycles = st.cycles,
            .halted = st.halted,
            .shutdown = st.shutdown,
        };
    }

    /// Side-effect-free read of `dst.len` bytes from guest physical `phys` (the
    /// bus peek path — never the device read handlers).
    pub fn peekMemPhys(self: *const Controller, phys: u32, dst: []u8) void {
        self.m.bus.peekBlock(phys, dst);
    }

    /// Side-effect-free read of `dst.len` bytes from a logical `seg:off` view.
    pub fn peekMem(self: *const Controller, seg: Seg, off: u32, dst: []u8) void {
        const linear = self.m.cpu.st.seg_base[@intFromEnum(seg)] +% off;
        self.m.bus.peekBlock(linear, dst);
    }

    /// Side-effect-free read of a real-mode IVT entry (IP at base+vec*4, CS at +2).
    pub fn peekIvtEntry(self: *const Controller, vector: u8) struct { ip: u16, cs: u16 } {
        const base = self.m.cpu.st.idtr_base +% (@as(u32, vector) * 4);
        var b: [4]u8 = undefined;
        self.m.bus.peekBlock(base, &b);
        const ip = @as(u16, b[0]) | (@as(u16, b[1]) << 8);
        const cs = @as(u16, b[2]) | (@as(u16, b[3]) << 8);
        return .{ .ip = ip, .cs = cs };
    }

    /// Side-effect-free read of the guest's accumulated CON (stdout/stderr) output —
    /// the bytes the program has written to the console device so far. This is a pure
    /// debugger observation: it reads the DOS CON device's capture buffer WITHOUT
    /// mutating it (no clear-on-read), so repeated reads return the same prefix and a
    /// read never perturbs the machine (the determinism prime directive). The returned
    /// slice borrows the device's internal buffer and is valid until the next
    /// `run`/`step` advances the guest; the worker copies it out before responding.
    pub fn console(self: *const Controller) []const u8 {
        return self.m.dos.dev_table.con.output();
    }

    /// Side-effect-free read of up to `out.len` 16-bit words from SS:SP upward
    /// (no SP mutation). Returns the filled prefix.
    pub fn peekStack(self: *const Controller, out: []u16) []u16 {
        const ss_base = self.m.cpu.st.seg_base[SS];
        const sp = self.m.cpu.st.getReg16(ESP);
        for (out, 0..) |*w, i| {
            const off: u16 = sp +% @as(u16, @intCast(i * 2));
            var b: [2]u8 = undefined;
            self.m.bus.peekBlock(ss_base +% off, &b);
            w.* = @as(u16, b[0]) | (@as(u16, b[1]) << 8);
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // Session / status.
    // -----------------------------------------------------------------------

    pub fn status(self: *const Controller) struct {
        running: bool,
        terminated: bool,
        ret_code: u16,
        cycles: u64,
        last_stop: ?StopReason,
    } {
        const st = &self.m.cpu.st;
        const running = !(st.shutdown or self.m.shutdown or self.m.dos.terminated or self.permanentlyHalted());
        return .{
            .running = running,
            .terminated = self.m.dos.terminated,
            .ret_code = self.m.dos.ret_code,
            .cycles = st.cycles,
            .last_stop = self.last_stop,
        };
    }

    /// The peekable guest memory regions (so an M2 readMem client can validate
    /// ranges before calling). Conventional+HMA RAM, the VGA framebuffer window,
    /// the EMS page frame.
    pub fn memoryRegions(self: *const Controller) []const Region {
        _ = self;
        return &regions_table;
    }
};

// Region bounds mirror the machine's `wire`/`post` mappings: conventional+HMA
// RAM slab (memmap.ram_total_size), the VGA framebuffer (devices.vga.VRAM_PHYS /
// VRAM_WINDOW_LEN = 0xA0000 / 0x10000), and the EMS page frame (dos/ems
// FRAME_PHYS / FRAME_LEN = 0xE0000 / 0x10000). debug imports only cpu+machine, so
// the device/dos constants are inlined here as literals matching those modules.
const regions_table = [_]Region{
    .{ .kind = .ram, .phys_start = 0, .len = memmap.ram_total_size },
    .{ .kind = .vram, .phys_start = 0xA0000, .len = 0x10000 },
    .{ .kind = .ems_frame, .phys_start = 0xE0000, .len = 0x10000 },
};
