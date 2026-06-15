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
const BreakpointSet = bp.BreakpointSet;
const BreakpointKind = bp.BreakpointKind;
const Breakpoint = bp.Breakpoint;
const Error = bp.Error;

const memmap = @import("bus").memmap;

const SS = @intFromEnum(Seg.ss);
const ESP = @intFromEnum(Reg32.esp);

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

pub const Controller = struct {
    m: *Machine,
    set: BreakpointSet = .{},
    last_stop: ?StopReason = null,

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

            _ = self.m.step();

            if (self.terminalReason()) |r| return self.record(r);
            if (self.scanBreakpoints()) |r| return self.record(r);

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
    fn scanBreakpoints(self: *Controller) ?StopReason {
        if (self.set.active_count == 0) return null;
        var reported: ?StopReason = null;
        var id: u32 = 0;
        while (id < bp.MAX_BREAKPOINTS) : (id += 1) {
            if (!self.set.used[id]) continue;
            const b = &self.set.items[id];
            if (!bp.matches(b, self.m)) continue;
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
        return self.set.add(kind, one_shot);
    }
    pub fn removeBreakpoint(self: *Controller, id: u32) Error!void {
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
