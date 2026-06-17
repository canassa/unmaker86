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

const devices = @import("devices");
const bios = @import("bios");
const vga_render = devices.vga_render;
const int10 = bios.int10_mod;

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
/// The reverse map (bus `WatchAccess` → debug `AccessKind`) for reporting a hit's
/// recorded access in the StopReason.
fn fromWatchAccess(a: WatchAccess) AccessKind {
    return switch (a) {
        .read => .read,
        .write => .write,
        .access => .access,
    };
}

/// The rich, debug-layer stop reason (a superset of `Machine.StopReason`). It is
/// part of the observable, reproducible result, so its production order is fixed
/// and tested (see `runUntilEvent`).
/// The access detail of a `memory`/`io` watchpoint hit, attached to a `breakpoint`
/// stop. Pointer-free POD; serializes (via std.json) as a nested object, or `null`
/// for exec/cycle/interrupt breakpoints. `value` is read SIDE-EFFECT-FREE (the peek
/// path for memory; the recorded access byte for io) — never a re-read that would
/// re-trip the watch or charge a cycle.
pub const WatchHit = struct {
    /// Which choke point tripped.
    kind: enum { memory, io },
    /// Linear address (memory) or port number (io).
    addr: u32,
    access: AccessKind,
    value: u8,
};

pub const StopReason = union(enum) {
    /// A user (persistent or one-shot) breakpoint fired: which id, the ledger value
    /// at that boundary, and (for a memory/io watchpoint) the access detail.
    breakpoint: struct { id: u32, at_cycle: u64, watch: ?WatchHit = null },
    /// A step / stepN / stepOver finished one or more retired instructions.
    step_complete: struct { at_cycle: u64 },
    /// The cycle cap was reached with no terminal/breakpoint.
    cycle_budget_exhausted: struct { at_cycle: u64 },
    /// Deterministic permanent HLT (no pending events, not wakeable).
    halted_forever: struct { at_cycle: u64 },
    /// The DOS program terminated (INT 21h AH=4C / INT 20h). `ret_code` is the
    /// full DOS exit word (`dos.ret_code` is u16 — low byte = AL exit code, high
    /// byte = exit type per AH=4D), carried verbatim rather than truncated.
    program_terminated: struct { ret_code: u16, at_cycle: u64 },
    /// Triple fault / shutdown latched.
    shutdown: struct { at_cycle: u64 },
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
    kind: enum { ram, vram, text_vram, text_vram_mono, ems_frame },
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

/// Per-instruction rendered-text cap for a `/api/disasm` window. The longest
/// real-mode instruction text (e.g. `mov dword [eax+ecx*8+0x12345678],
/// 0x12345678`) fits comfortably under this.
pub const MAX_DISASM_TEXT = 64;
/// The max instructions a single `/api/disasm` request may return — a bounded
/// window. A larger `count` is REJECTED at the handler (never silently truncated).
pub const MAX_DISASM_INSNS = 64;

/// One disassembled instruction in a `/api/disasm` window. Pointer-free POD: the
/// rendered text + raw bytes are copied into fixed buffers so the result flows
/// through the queue/Response without borrowing machine memory.
pub const DisasmInsn = struct {
    /// The linear (physical) address the instruction starts at.
    linear: u32 = 0,
    /// The real-mode `seg:off` view, valid only when `has_seg` (the `seg`/`cs_eip`
    /// origins). The `linear`-only origin leaves `has_seg` false.
    seg: u16 = 0,
    off: u32 = 0,
    has_seg: bool = false,
    /// Encoded length in bytes (1..15; always ≥1 so a walk always advances).
    len: u8 = 0,
    /// The first `len` raw opcode bytes (the tail of `bytes` is undefined).
    bytes: [cpu_mod.disasm.MAX_INSTR_LEN]u8 = undefined,
    /// The rendered Intel-syntax text length (valid bytes in `text`).
    text_len: u8 = 0,
    text: [MAX_DISASM_TEXT]u8 = undefined,
};

pub const DisasmResult = struct {
    count: u16 = 0,
    items: [MAX_DISASM_INSNS]DisasmInsn = undefined,
};

/// Where a `/api/disasm` walk starts. Resolved to a (seg_base, offset) ON THE
/// WORKER — reading live CPU `seg_base`/`eip` off-worker would be a torn read.
pub const DisasmOrigin = union(enum) {
    /// Disassemble at a linear (physical) address; no segment context.
    linear: u32,
    /// Disassemble at a real-mode `seg:off` (linear = seg*16 + off).
    seg_off: struct { seg: u16, off: u32 },
    /// Disassemble at the current CS:EIP (resolved from live CPU state).
    cs_eip: void,
};

// ===========================================================================
// Device / chipset / A20 state reader (plans/device-state-reader.md). Every field
// below is a RAW device-struct field read or a pure `f(cpu.st.cycles)` compute —
// NEVER a call into a device's `in8`/port handler (those mutate: DAC index
// advance, FIFO pop, AC flip-flop reset). The whole snapshot is JSON-Stringify-able
// (enums render as strings, fixed arrays as JSON arrays).
// ===========================================================================

/// A20 gate. `enabled`/`mask` are the BUS's authoritative state; `kbc_output_port_bit1`
/// is the 8042 output-port LATCH (read-back only — the bus, not the 8042, owns A20).
pub const DevA20 = struct {
    enabled: bool,
    mask: u32,
    kbc_output_port_bit1: bool,
};

/// One PIT channel: raw programmed state + the two CYCLE-DERIVED values (`counter`,
/// `output`) computed from `cpu.st.cycles` via the pure `liveCounter`/`outBitAt`.
pub const DevPitChannel = struct {
    mode: devices.pit.PitMode,
    access: devices.pit.AccessMode,
    bcd: bool,
    reload: u32, // effective reload (0 programmed -> 65536)
    gate: bool,
    counter: u16, // computed: liveCounter(cyclesNow)
    output: bool, // computed: outBitAt(cyclesNow)
    latched: bool,
    status_latched: bool,
    new_mode: bool,
};

pub const DevPit = struct {
    channels: [3]DevPitChannel,
    /// True for the cycle-derived fields (`counter`/`output`): they move with the
    /// ledger. ch2 `output` is a cross-emulator non-determinism boundary (host-clock
    /// in other emulators) — here it is `f(cycles)`, so deterministic.
    cycle_derived: bool = true,
};

pub const DevSpeaker = struct {
    port_b: u8, // the 0x61 latch (speaker.port_61_data)
    ch2_gate: bool,
    ch2_out: bool, // computed: pit ch2 outBitAt(cyclesNow)
};

pub const DevVga = struct {
    mode: u8, // BDA video mode (peek of BDA 0x49, same source as /api/screen)
    misc_output: u8,
    feature_control: u8,
    pel_mask: u8,
    attr_flip_flop_is_index: bool,
    attr_pas: bool,
    seq_index: u8,
    seq: [5]u8,
    crtc_index: u8,
    crtc: [32]u8,
    gfx_index: u8,
    gfx: [9]u8,
    attr_index: u8,
    attr: [21]u8,
    dac_read_index: u8,
    dac_write_index: u8,
    dac_pel_index: u8,
    dac_state: devices.vga.DacState,
    /// COMPUTED (non-mutating) Input Status #1 byte — `statusReg1Peek(cyclesNow)`,
    /// NOT a read of 0x3DA (which would flip the AC flip-flop). Labeled so a client
    /// never mistakes it for a live port read.
    input_status1: u8,
    latch: [4]u8,
    /// The 256-entry DAC palette — only present when the request passed `?palette=1`
    /// (nulled server-side otherwise to keep the default snapshot small).
    palette: ?[256]devices.vga.DacRgb = null,
};

pub const DevOpl = struct {
    /// Currently-addressed OPL register (last write to port 0x388).
    reg_index: u8,
    /// COMPUTED (non-mutating) status byte — `statusPeek(cyclesNow)`, NOT a read of
    /// 0x388 (which latches overflow). Labeled so a client never mistakes it for a
    /// live port read. `(status & 0xE0) == 0xC0` is the AdLib-detected condition.
    status: u8,
    timer1_enabled: bool,
    timer1_masked: bool,
    timer1_reload: u8,
    timer2_enabled: bool,
    timer2_masked: bool,
    timer2_reload: u8,
};

pub const DevEms = struct {
    installed: bool,
    reported_pages: u16,
    backing_pages: u16,
    user_pages: u16,
    free_pages: u16,
    active_handles: u16,
    frame_pages: u8,
};

/// The grouped chipset snapshot for `GET /api/devices`. `dma` is always null:
/// zdos models no 8237 — surfacing the absence honestly (never fabricated regs).
pub const DevicesSnapshot = struct {
    a20: DevA20,
    pic: devices.Pic.Snapshot, // {master, slave} controllers, all raw fields
    pit: DevPit,
    vga: DevVga,
    kbc: devices.Keyboard.Snapshot, // fifo/status/config/output_port/pending/...
    speaker: DevSpeaker,
    /// AdLib / OPL2 timer + (computed) status — the AdLib-detection surface.
    opl: DevOpl,
    ems: DevEms,
    /// Not modeled — honest null, never a fabricated 8237 register set.
    dma: ?u0 = null,
};

/// The non-mutating shadow of one I/O port (`GET /api/io`): the value an `in8`
/// would currently return, computed from raw fields WITHOUT issuing the mutating
/// read. `null` => no stable shadow defined for that port.
pub const IoShadow = struct {
    port: u16,
    value: ?u8,
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
    /// For each breakpoint id, the bus PORT-watch slot an `io` breakpoint armed, or
    /// null. Parallel to `watch_ids` (a bp has exactly one kind, so at most one of
    /// the two is set).
    port_watch_ids: [bp.MAX_BREAKPOINTS]?u16 = @splat(null),

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
        const at = self.m.cpu.st.cycles;
        if (self.m.cpu.st.shutdown or self.m.shutdown) return .{ .shutdown = .{ .at_cycle = at } };
        if (self.m.dos.terminated) return .{ .program_terminated = .{ .ret_code = self.m.dos.ret_code, .at_cycle = at } };
        if (self.permanentlyHalted()) return .{ .halted_forever = .{ .at_cycle = at } };
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
                reported = .{ .breakpoint = .{
                    .id = id,
                    .at_cycle = self.m.cpu.st.cycles,
                    .watch = self.watchDetailFor(b),
                } };
            }
            // Consume EVERY matching one-shot (its contract is "at most once").
            if (b.one_shot) {
                b.enabled = false;
            }
        }
        if (reported != null) self.set.recomputeActive();
        return reported;
    }

    /// The watchpoint access detail for a reported `memory`/`io` breakpoint, read
    /// from the bus breadcrumb the matching hit just set. `value` for a memory hit
    /// is the byte at the hit address read via the SIDE-EFFECT-FREE peek path
    /// (cycle-neutral, no re-trip); for io it is the recorded access byte. Returns
    /// null for exec/cycle/interrupt breakpoints (no access detail).
    fn watchDetailFor(self: *const Controller, b: *const Breakpoint) ?WatchHit {
        switch (b.kind) {
            .memory => {
                const w = self.m.bus.last_mem_watch;
                return .{
                    .kind = .memory,
                    .addr = w.linear,
                    .access = fromWatchAccess(w.access),
                    .value = self.m.bus.peekPhys8(w.linear),
                };
            },
            .io => {
                const w = self.m.bus.last_io_watch;
                return .{
                    .kind = .io,
                    .addr = w.port,
                    .access = fromWatchAccess(w.access),
                    .value = w.value,
                };
            },
            else => return null,
        }
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
        // An `io` breakpoint arms a bus PORT watch (no page-kind flip needed; the
        // port path is gated by a single armed bool). Same roll-back-on-full policy.
        if (kind == .io) {
            const k = kind.io;
            const wid = self.m.bus.setPortWatch(.{
                .port = k.port,
                .access = toWatchAccess(k.access),
            }) catch {
                self.set.remove(id) catch unreachable;
                return error.BreakpointTableFull;
            };
            self.port_watch_ids[id] = wid;
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
            if (self.port_watch_ids[id]) |wid| {
                self.m.bus.clearPortWatch(wid);
                self.port_watch_ids[id] = null;
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

    /// Option A REP sizer (plans/step-over-rep.md): peek the bytes at CS:EIP and,
    /// IFF the instruction is a REP/REPE/REPNE-prefixed STRING op, return the linear
    /// address of the instruction that FOLLOWS it. REP legally prefixes only the
    /// single-byte, no-ModR/M, no-immediate string ops (MOVS/CMPS/STOS/LODS/SCAS =
    /// A4-A7, AA-AF; INS/OUTS = 6C-6F), so length = (prefix bytes) + 1. Pure peek
    /// (side-effect-free), no CPU surface. null => not a REP-string instruction.
    fn repStringNextLinear(self: *const Controller) ?u32 {
        const cs_base = self.m.cpu.st.seg_base[@intFromEnum(Seg.cs)];
        const start = cs_base +% self.m.cpu.st.eip;
        var i: u8 = 0;
        var saw_rep = false;
        while (i < 15) : (i += 1) { // bounded by MAX_INSTR_LEN
            const b = self.m.bus.peekPhys8(start +% i);
            switch (b) {
                0xF2, 0xF3 => saw_rep = true, // REPNE / REP(E)
                // segment / operand-size / address-size / lock prefixes: keep scanning.
                0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0 => {},
                else => {
                    // `b` is the opcode. Is it a REP-able string op?
                    const is_string = switch (b) {
                        0x6C...0x6F, 0xA4...0xA7, 0xAA...0xAF => true,
                        else => false,
                    };
                    if (saw_rep and is_string) return start +% (@as(u32, i) + 1);
                    return null;
                },
            }
        }
        return null; // 15 prefix bytes with no opcode: not a sane REP string
    }

    /// Step OVER a direct CALL/INT or a whole REP-string by running past it;
    /// otherwise == step into. Returns `StepOverResult{reason, stepped_into}` — the
    /// `stepped_into` flag reports a fallback to step-into (never a silent degrade).
    ///
    /// - Direct CALL/INT (`0xE8`/`0x9A`/`0xCD`): execute the call/INT (one step),
    ///   then a one-shot `execution_address` bp at the pushed return address,
    ///   SP-GUARDED so recursion is correct.
    /// - REP/REPE/REPNE string (`F2/F3` + string op): a one-shot at the REP's
    ///   next-instruction address; the REP runs ALL iterations (real cycles) and we
    ///   stop after. Immune to an IRQ landing mid-REP — the bp matches only when
    ///   CS:EIP has genuinely moved PAST the REP (mid-flight EIP stays pinned at the
    ///   REP opcode; an ISR runs at its own CS:EIP). No SP guard (REP pushes no
    ///   frame).
    /// - Everything else (indirect CALL / `FF`-group, LOOP, …) falls back to
    ///   `stepInstruction` with `stepped_into = true` — a known, intentional gap
    ///   pending a general instruction sizer/decoder.
    pub fn stepOver(self: *Controller) StepOverResult {
        self.last_stop = null;
        if (self.terminalReason()) |r| return .{ .reason = self.record(r), .stepped_into = false };

        // REP/REPE/REPNE string: step OVER the whole REP via a one-shot at the
        // next-instruction address (no SP guard — REP pushes no return frame).
        if (self.repStringNextLinear()) |next_linear| {
            const rid = self.set.add(.{ .execution_address = .{ .linear = next_linear } }, true) catch {
                // Table full: degrade to step-into rather than panic (ground rule).
                return .{ .reason = self.stepInstruction(), .stepped_into = true };
            };
            defer self.discardOneShot(rid);
            const r = self.runUntilEvent(std.math.maxInt(u64));
            switch (r) {
                .breakpoint => |hit| {
                    if (hit.id == rid) {
                        return .{ .reason = self.record(.{ .step_complete = .{ .at_cycle = self.m.cpu.st.cycles } }), .stepped_into = false };
                    }
                    return .{ .reason = r, .stepped_into = false }; // some OTHER user bp pre-empted
                },
                else => return .{ .reason = r, .stepped_into = false }, // terminal / budget
            }
        }

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
        if (!self.m.kbd.pushScancode(code)) return false;
        // Drive the keyboard's typematic state machine from this CLEAN make/break
        // edge (NOT by re-parsing raw FIFO bytes): a make arms auto-repeat (after the
        // delay), a break of the held key cancels it. Cycle-scheduled, never host
        // time — KEYSTONE: with no key held, no event is ever scheduled.
        self.m.kbd.noteEdge(scancode, make, ext);
        return true;
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
    /// (Phase 3) After updating driver position/buttons, FIRE the guest's INT 33h
    /// AX=0Ch event callback (if one is installed and the event intersects its
    /// mask). This is what real Betrayal at Krondor requires — it is callback-only
    /// and never polls AX=03, so injected movement/clicks reach it ONLY here. The
    /// far-call self-charges every instruction it runs (no ledger hole; see
    /// `Bridge.runGuestFarCall`). It runs on the worker (the machine owner) at this
    /// command boundary, so the call completes before the next command.
    pub fn injectMouse(self: *Controller, req: MouseInject) void {
        const mouse = &self.m.dos.mouse;
        mouse.injectAndFire(&self.m.cpu, &self.m.svc.bridge, .{
            .x = req.x,
            .y = req.y,
            .dx = req.dx,
            .dy = req.dy,
            .buttons = req.buttons,
            .set_x = req.set_x,
            .set_y = req.set_y,
            .set_dx = req.set_dx,
            .set_dy = req.set_dy,
            .set_buttons = req.set_buttons,
        });
    }

    /// LIVE-MOUSE seamless inject (plans/mouse-input.md, LOCKED §1). The coalesced
    /// browser-mouse fold path: the API/worker side drains `api.LiveMouseState` and
    /// forwards ONE sample as PLAIN INTEGERS (NO api type crosses this seam — `src/api`
    /// is ABOVE `src/debug`, so a `*LiveMouseState` field would be a circular import).
    /// `abs_*_q16` is the normalized [0,1] absolute (the driver owns the ×range
    /// mapping, per-mode); `dx`/`dy` are the browser's TRUE `movementX/Y` relative
    /// channel (the real mickey source, not derived from the absolute Δ); `buttons` is
    /// the latest mask. Forwards to `Int33.injectSeamless`, which writes the absolute
    /// directly (AX=03 tracks 1:1), feeds the relative through the existing fixed-point
    /// mickey path (AX=0B), and fires the AX=0Ch callback once. The far-call
    /// self-charges every instruction (no ledger hole). Like `injectMouse`, this runs
    /// on the worker (the machine owner) at a command boundary.
    ///
    /// Determinism (the keystone): this is reached ONLY from the live `input_mouse_fold`
    /// arm, which the pacer submits per slice and which is a NO-OP unless the api-layer
    /// `LiveMouseState` is dirty (a real POST arrived). No live input ⇒ no fold ⇒ this
    /// is never called ⇒ zero added cycles ⇒ byte-identical to today.
    pub fn injectMouseSeamless(
        self: *Controller,
        abs_x_q16: u32,
        abs_y_q16: u32,
        dx: i32,
        dy: i32,
        buttons: u16,
        set_abs: bool,
        set_rel: bool,
        set_buttons: bool,
    ) void {
        const mouse = &self.m.dos.mouse;
        mouse.injectSeamless(&self.m.cpu, &self.m.svc.bridge, .{
            .abs_x_q16 = abs_x_q16,
            .abs_y_q16 = abs_y_q16,
            .dx = dx,
            .dy = dy,
            .buttons = buttons,
            .set_abs = set_abs,
            .set_rel = set_rel,
            .set_buttons = set_buttons,
        });
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

    /// Side-effect-free RAM-slab search (`GET /api/mem/search`). Thin delegate to
    /// `Bus.searchRam` — the bus owns the slab + A20 invariants, so the raw `[]u8`
    /// never leaks up through the debug layer. Pure, cycle-neutral.
    pub fn searchRam(self: *const Controller, start: u32, len: u32, needle: []const u8, hits: []u32) bus_mod.Bus.SearchHits {
        return self.m.bus.searchRam(start, len, needle, hits);
    }

    /// The conventional+HMA RAM slab size (the search domain upper bound).
    pub fn ramSlabSize(self: *const Controller) u32 {
        return @intCast(self.m.bus.ram.len);
    }

    /// Side-effect-free read of `dst.len` bytes from a logical `seg:off` view.
    pub fn peekMem(self: *const Controller, seg: Seg, off: u32, dst: []u8) void {
        const linear = self.m.cpu.st.seg_base[@intFromEnum(seg)] +% off;
        self.m.bus.peekBlock(linear, dst);
    }

    /// A side-effect-free snapshot of the chipset / A20 / device state
    /// (plans/device-state-reader.md). Reads ONLY raw device fields (via each
    /// device's by-value `snapshot()`) and pure cycle-derived helpers
    /// (`liveCounter`/`outBitAt`/`statusReg1Peek`) — NEVER a port `in8`/read
    /// handler (those mutate). So `machine.snapshot()` is byte-identical before
    /// and after, and zero cycles are charged (the prime directive).
    pub fn devicesSnapshot(self: *const Controller) DevicesSnapshot {
        const cyclesNow = self.m.cpu.st.cycles;

        // ---- A20 (the thing that was invisible during the EXEPACK bug) ----
        const a20: DevA20 = .{
            .enabled = self.m.bus.a20Enabled(),
            .mask = self.m.bus.a20_mask,
            .kbc_output_port_bit1 = (self.m.kbd.output_port & 0x02) != 0,
        };

        // ---- PIT (raw fields + the two cycle-derived values) ----
        var pit: DevPit = .{ .channels = undefined };
        for (&self.m.pit.channels, 0..) |*ch, i| {
            pit.channels[i] = .{
                .mode = ch.mode,
                .access = ch.access,
                .bcd = ch.bcd,
                .reload = if (ch.reload == 0) 65536 else ch.reload,
                .gate = ch.gate,
                .counter = ch.liveCounter(cyclesNow),
                .output = ch.outBitAt(cyclesNow),
                .latched = ch.latched,
                .status_latched = ch.status_latched,
                .new_mode = ch.new_mode,
            };
        }

        // ---- VGA (register files + DAC indices + COMPUTED status, never 0x3DA) ----
        const vsnap = self.m.vga.snapshot();
        const vga: DevVga = .{
            .mode = self.m.bus.peekPhys8(0x449), // BDA video mode (== /api/screen)
            .misc_output = vsnap.misc_output,
            .feature_control = vsnap.feature_control,
            .pel_mask = vsnap.pel_mask,
            .attr_flip_flop_is_index = vsnap.attr_flip_flop_is_index,
            .attr_pas = vsnap.attr_pas,
            .seq_index = vsnap.seq.index,
            .seq = vsnap.seq.regs,
            .crtc_index = vsnap.crtc.index,
            .crtc = vsnap.crtc.regs,
            .gfx_index = vsnap.gfx.index,
            .gfx = vsnap.gfx.regs,
            .attr_index = vsnap.attr.index,
            .attr = vsnap.attr.regs,
            .dac_read_index = vsnap.dac_read_index,
            .dac_write_index = vsnap.dac_write_index,
            .dac_pel_index = vsnap.dac_pel_index,
            .dac_state = vsnap.dac_state,
            .input_status1 = self.m.vga.statusReg1Peek(cyclesNow),
            .latch = vsnap.latch,
            .palette = vsnap.dac_rgb, // server nulls this when ?palette not set
        };

        // ---- Speaker / KBC port B (latch + computed ch2 OUT) ----
        const speaker: DevSpeaker = .{
            .port_b = self.m.speaker.snapshot().port_61_data,
            .ch2_gate = self.m.pit.channels[2].gate,
            .ch2_out = self.m.pit.channels[2].outBitAt(cyclesNow),
        };

        // ---- AdLib / OPL2 timer + (computed) status ----
        const opl: DevOpl = .{
            .reg_index = self.m.opl.snapshot().reg_index,
            .status = self.m.opl.statusPeek(),
            .timer1_enabled = self.m.opl.timer1Enabled(),
            .timer1_masked = self.m.opl.timer1Masked(),
            .timer1_reload = self.m.opl.timer1Reload(),
            .timer2_enabled = self.m.opl.timer2Enabled(),
            .timer2_masked = self.m.opl.timer2Masked(),
            .timer2_reload = self.m.opl.timer2Reload(),
        };

        // ---- EMS config (the EMS-bug surface) ----
        const er = self.m.dos.ems.report();
        const ems: DevEms = .{
            .installed = er.installed,
            .reported_pages = er.reported_pages,
            .backing_pages = er.backing_pages,
            .user_pages = er.user_pages,
            .free_pages = er.free_pages,
            .active_handles = er.active_handles,
            .frame_pages = er.frame_pages,
        };

        return .{
            .a20 = a20,
            .pic = self.m.pic.snapshot(),
            .pit = pit,
            .vga = vga,
            .kbc = self.m.kbd.snapshot(),
            .speaker = speaker,
            .opl = opl,
            .ems = ems,
        };
    }

    /// The non-mutating shadow of a single I/O port (`GET /api/io`) — the value an
    /// `in8(port)` would currently return, computed from RAW fields/pure helpers
    /// WITHOUT issuing the mutating read (no DAC-index advance, no FIFO pop, no AC
    /// flip-flop reset). `null` => no stable shadow is defined for that port.
    pub fn ioShadow(self: *const Controller, port: u16) ?u8 {
        const cyclesNow = self.m.cpu.st.cycles;
        const vsnap = self.m.vga.snapshot();
        const ksnap = self.m.kbd.snapshot();
        return switch (port) {
            // VGA Input Status #1 — computed retrace/display bits (no flip-flop reset).
            0x3DA, 0x3BA => self.m.vga.statusReg1Peek(cyclesNow),
            0x3C6 => vsnap.pel_mask, // PEL mask
            0x3C7 => @intFromEnum(vsnap.dac_state), // DAC state (read/write)
            0x3C8 => vsnap.dac_write_index,
            // DAC data: the sub-byte at the current read entry/pel WITHOUT advancing.
            0x3C9 => switch (vsnap.dac_pel_index) {
                0 => vsnap.dac_rgb[vsnap.dac_read_index].red,
                1 => vsnap.dac_rgb[vsnap.dac_read_index].green,
                else => vsnap.dac_rgb[vsnap.dac_read_index].blue,
            },
            0x3CC => vsnap.misc_output, // Misc Output read-back
            // PIC: OCW3-selected IRR/ISR (master/slave), and the mask register.
            0x20 => if (self.m.pic.master.read_isr) self.m.pic.master.isr else self.m.pic.master.irr,
            0x21 => self.m.pic.master.imr,
            0xA0 => if (self.m.pic.slave.read_isr) self.m.pic.slave.isr else self.m.pic.slave.irr,
            0xA1 => self.m.pic.slave.imr,
            // PIT counters: the low byte of the live counter (best-defined shadow).
            0x40 => @truncate(self.m.pit.channels[0].liveCounter(cyclesNow)),
            0x41 => @truncate(self.m.pit.channels[1].liveCounter(cyclesNow)),
            0x42 => @truncate(self.m.pit.channels[2].liveCounter(cyclesNow)),
            // 8042 data: the FIFO head WITHOUT popping (or last response if empty).
            0x60 => if (ksnap.fifo_count > 0) ksnap.fifo[ksnap.fifo_head] else ksnap.last_response,
            // KBC port B: the 0x61 latch with bit5 reflecting computed ch2 OUT.
            0x61 => blk: {
                var v = self.m.speaker.snapshot().port_61_data;
                if (self.m.pit.channels[2].outBitAt(cyclesNow)) v |= 0x20 else v &= ~@as(u8, 0x20);
                break :blk v;
            },
            0x64 => ksnap.status, // 8042 status register
            // OPL2 status (port 0x388): computed timer-overflow bits WITHOUT latching
            // (a real read latches overflow into device state — this peek does not).
            0x388 => self.m.opl.statusPeek(),
            // Fast-A20 gate (port 0x92): bit1 = A20 enabled.
            0x92 => if (self.m.bus.a20Enabled()) @as(u8, 0x02) else 0x00,
            else => null,
        };
    }

    /// Disassemble up to `count` instructions starting at `origin`, filling `out`.
    /// PURE peek path (`bus.peekPhys8`) — never executes, never charges a cycle,
    /// never mutates machine state (determinism prime directive): a disasm leaves
    /// `machine.snapshot()` byte-identical. `count` MUST be ≤ MAX_DISASM_INSNS
    /// (the handler validates); a larger value is clamped here defensively.
    pub fn disasmWindow(self: *const Controller, origin: DisasmOrigin, count: u16, out: *DisasmResult) void {
        const n = @min(count, @as(u16, MAX_DISASM_INSNS));

        // Resolve the segment base + starting in-segment offset. `off` is what the
        // disassembler uses BOTH to read bytes (linear = seg_base + off) AND to
        // compute relative branch targets (in-segment), so it must be the segment
        // offset, not the linear address.
        var seg_base: u32 = 0;
        var off: u32 = 0;
        var seg_sel: u16 = 0;
        var has_seg = false;
        switch (origin) {
            .linear => |lin| off = lin, // seg_base 0, has_seg false
            .seg_off => |s| {
                seg_base = @as(u32, s.seg) << 4;
                off = s.off;
                seg_sel = s.seg;
                has_seg = true;
            },
            .cs_eip => {
                seg_base = self.m.cpu.st.seg_base[@intFromEnum(Seg.cs)];
                off = self.m.cpu.st.eip;
                seg_sel = @truncate(seg_base >> 4); // real-mode CS selector
                has_seg = true;
            },
        }

        // Real mode is 16-bit default (CS D-bit clear); zdos is real-mode only.
        const cs_big = false;
        // A side-effect-free byte source over the bus peek path. `read(o)` reads at
        // `seg_base + o`, so the disassembler's offset arithmetic maps to linear.
        const Src = struct {
            ctrl: *const Controller,
            base: u32,
            pub fn read(s: @This(), o: u32) ?u8 {
                return s.ctrl.m.bus.peekPhys8(s.base +% o);
            }
        };

        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const insn = &out.items[i];
            var textbuf: [MAX_DISASM_TEXT]u8 = undefined;
            const d = cpu_mod.disasm.decodeOne(Src{ .ctrl = self, .base = seg_base }, off, cs_big, &textbuf);
            insn.linear = seg_base +% off;
            insn.has_seg = has_seg;
            insn.seg = seg_sel;
            insn.off = off;
            insn.len = d.len;
            var b: u8 = 0;
            while (b < d.len) : (b += 1) insn.bytes[b] = self.m.bus.peekPhys8(seg_base +% off +% b);
            const tl: u8 = @intCast(@min(d.text.len, MAX_DISASM_TEXT));
            @memcpy(insn.text[0..tl], d.text[0..tl]);
            insn.text_len = tl;
            off +%= d.len;
        }
        out.count = n;
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

    /// A side-effect-free snapshot of the active text page — the cols×rows grid of
    /// flat {char,attr} cells plus the BDA scalars. Used by `GET /api/screen`. The
    /// `cells` buffer is filled via the pure peek path (`peekBlock` → the VGA text
    /// handler's `peek8`), so the read NEVER perturbs the machine (determinism).
    pub const ScreenView = struct {
        cols: u16,
        rows: u16,
        mode: u8,
        active_page: u8,
        cursor_row: u16,
        cursor_col: u16,
        /// The raw cell bytes (char,attr interleaved): `cols*rows*2` bytes written
        /// into the caller-provided `dst`. `cells` borrows that prefix.
        cells: []const u8,
    };

    /// Read the active text page into `dst` (≥ cols*rows*2 bytes). Pure peek of the
    /// BDA mode/cols/rows/cursor/active-page + the text-page cells at the BDA-implied
    /// base (B8000 color, or B0000 if mode 7). Mirrors `console()` (a pure read).
    pub fn screen(self: *const Controller, dst: []u8) ScreenView {
        // BDA video fields (linear 0x400; offsets per src/bios/bda.zig).
        const BDA: u32 = 0x400;
        const mode = self.m.bus.peekPhys8(BDA + 0x49); // OFF_VIDEO_MODE
        var cols: u16 = self.peekU16(BDA + 0x4A); // OFF_VIDEO_COLS
        if (cols == 0) cols = 80;
        const rows: u16 = @as(u16, self.m.bus.peekPhys8(BDA + 0x84)) + 1; // OFF_NB_ROWS+1
        const active_page = self.m.bus.peekPhys8(BDA + 0x62); // OFF_ACTIVE_PAGE
        const cursor_word = self.peekU16(BDA + 0x50 + @as(u32, active_page) * 2); // OFF_CURSOR_POS

        // Active text base: B0000 for mode 7 (mono), else B8000 (color). One page =
        // 0x1000 bytes (devices.vga.TEXT_PAGE_SIZE).
        const base: u32 = if (mode == 0x07) 0xB0000 else 0xB8000;
        const page_base = base + @as(u32, active_page) * 0x1000;

        const cell_bytes: usize = @as(usize, cols) * rows * 2;
        const n = @min(cell_bytes, dst.len);
        self.m.bus.peekBlock(page_base, dst[0..n]);

        return .{
            .cols = cols,
            .rows = rows,
            .mode = mode,
            .active_page = active_page,
            .cursor_row = cursor_word >> 8,
            .cursor_col = cursor_word & 0xFF,
            .cells = dst[0..n],
        };
    }

    inline fn peekU16(self: *const Controller, phys: u32) u16 {
        var b: [2]u8 = undefined;
        self.m.bus.peekBlock(phys, &b);
        return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
    }

    /// The framebuffer-capture descriptor returned through the normal small-POD path
    /// (plans/vga-spec/03 §3.5.3, B1). The large index/RGBA payloads are written into
    /// the CALLER-PROVIDED buffers (the server-owned render buffers), NOT returned by
    /// value — a frame is 64 KiB..1.2 MiB and must not flow through the 32 KiB resp_buf.
    pub const FramebufferView = struct {
        kind: vga_render.Kind,
        width: u16,
        height: u16,
        index_len: u32,
        rgba_len: u32,
        double_scan: bool,
        row_repeat: u8,
        /// True iff the current mode has a faithful rasterizer; false => the caller
        /// surfaces "no renderer for this mode" rather than streaming a wrong frame.
        supported: bool,
        /// True iff `palette_buf` was filled with the 256 expanded RGB triples (the
        /// indexed-PNG path needs it). All current supported kinds emit DAC indices, so
        /// this is true whenever `supported` — but it is reported explicitly so the
        /// screenshot serializer can pick the indexed vs. truecolor PNG by data, not by
        /// re-deriving the mode. False for an unsupported mode (nothing written).
        palette_present: bool,
        /// The live VGA `pel_mask` (DAC pixel mask). The indexed-PNG path must apply it
        /// to each index (`plte_index = idx & pel_mask`) to stay byte-identical to the
        /// RGBA peek (`indexToRgba`, §3.3). For BaK/TTM it is 0xFF (a no-op), but reported
        /// so the masking is correct under any program. Off-worker the server reads this
        /// (a small POD) rather than the machine's DAC.
        pel_mask: u8,
    };

    /// Capture the CURRENT VGA mode into `index_buf` (palette indices) and `rgba_buf`
    /// (index -> DAC -> 6->8 -> RGBA). A PURE peek of guest state (VRAM + registers +
    /// DAC) at the live cycle: it advances NO cycles and mutates NO device field
    /// (CLAUDE prime directive; the R3/R6 invariants). It reads RAW fields only — the
    /// VRAM/plane slab directly (never `memRead8`, which loads the 4 latches), the raw
    /// `dac_rgb`/`pel_mask` (never `read3c9`), the raw `attr.regs`/CRTC (never
    /// `in8(0x3DA)`). Blink is rendered high, the cursor solid (§6 — no wall clock).
    ///
    /// `index_buf` must be >= width*height; `rgba_buf` >= width*height*4 (the server's
    /// fixed 640x480 buffers always satisfy this). For an unsupported mode it returns
    /// `supported=false` with zero dims and writes nothing (no fake frame).
    ///
    /// `palette_buf` (optional, >= 768 bytes): when non-null AND the mode is supported,
    /// it is filled with the 256 expanded RGB triples (R,G,B per entry) the indexed-PNG
    /// path needs — `PLTE[i] = expand6to8(dac_rgb[i].{red,green,blue})`. The DAC is read
    /// RAW here (the same pure peek `indexToRgba` uses); `palette_present` reports
    /// whether it was filled. This keeps the DAC read ON the worker (the controller's
    /// machine), so the server reads only its own buffers off-worker (§3.6 option a).
    pub fn framebuffer(self: *const Controller, index_buf: []u8, rgba_buf: []u8, palette_buf: ?[]u8) FramebufferView {
        const BDA: u32 = 0x400;
        const mode = self.m.bus.peekPhys8(BDA + 0x49); // OFF_VIDEO_MODE
        var cols: u16 = self.peekU16(BDA + 0x4A); // OFF_VIDEO_COLS
        if (cols == 0) cols = 80;
        const rows: u16 = @as(u16, self.m.bus.peekPhys8(BDA + 0x84)) + 1; // OFF_NB_ROWS+1
        var char_height: u8 = @intCast(self.peekU16(BDA + 0x85) & 0xFF); // OFF_CHAR_HEIGHT
        if (char_height == 0) char_height = 16;
        const active_page = self.m.bus.peekPhys8(BDA + 0x62); // OFF_ACTIVE_PAGE
        const cursor_word = self.peekU16(BDA + 0x50 + @as(u32, active_page) * 2); // OFF_CURSOR_POS
        const cursor_shape = self.peekU16(BDA + 0x60); // OFF_CURSOR_SHAPE (start<<8|end)

        // Text-page cell slab (B0000 mono for mode 7, else B8000 color), one page =
        // 0x1000 bytes. Peeked into a fixed scratch — the same pure path /api/screen uses.
        var cell_scratch: [80 * 50 * 2]u8 = undefined; // headroom for 80x50
        const cell_bytes: usize = @min(@as(usize, cols) * rows * 2, cell_scratch.len);
        const text_base: u32 = if (mode == 0x07) 0xB0000 else 0xB8000;
        self.m.bus.peekBlock(text_base + @as(u32, active_page) * 0x1000, cell_scratch[0..cell_bytes]);

        // The staged ROM glyph slab for the active cell height — peeked from BIOS ROM
        // space (the real bytes a hardware character generator would fetch). 8/14/16.
        var font_scratch: [256 * 16]u8 = undefined;
        const font_phys: u32, const fh: u8 = switch (char_height) {
            8 => .{ int10.FONT8_PHYS, 8 },
            14 => .{ int10.FONT14_PHYS, 14 },
            else => .{ int10.FONT16_PHYS, 16 },
        };
        const font_bytes: usize = @as(usize, 256) * fh;
        self.m.bus.peekBlock(font_phys, font_scratch[0..font_bytes]);

        const mv: vga_render.ModeView = .{
            .mode = mode,
            .cols = cols,
            .rows = rows,
            .char_height = char_height,
            // Cell width from the Sequencer Clocking-Mode 8/9-dot bit (SEQ 0x01 bit 0):
            // 1 => 8-dot, 0 => 9-dot (the 720-wide text family, §3.1). Read raw (pure).
            .char_width = self.m.vga.charWidth(),
            .active_page = active_page,
            .cursor_row = cursor_word >> 8,
            .cursor_col = cursor_word & 0xFF,
            .cursor_start = @intCast(cursor_shape >> 8),
            .cursor_end = @intCast(cursor_shape & 0xFF),
            // Cursor enabled unless the start-scanline bit 5 (disable) is set — and it
            // is only shown for text modes. Rendered SOLID (no blink, §6).
            .cursor_visible = mode <= 0x03 or mode == 0x07,
            .text_cells = cell_scratch[0..cell_bytes],
            .font = font_scratch[0..font_bytes],
        };

        const d = vga_render.render(&self.m.vga, mv, index_buf);
        if (d.kind == .unsupported) {
            return .{
                .kind = .unsupported,
                .width = 0,
                .height = 0,
                .index_len = 0,
                .rgba_len = 0,
                .double_scan = false,
                .row_repeat = 1,
                .supported = false,
                .palette_present = false,
                .pel_mask = self.m.vga.pel_mask,
            };
        }
        // Second pass: index -> RGBA via the DAC (raw fields; no port mutation).
        vga_render.indexToRgba(&self.m.vga, index_buf[0..d.index_len], rgba_buf[0..d.rgba_len]);
        // Optional third pass: the expanded 256-entry RGB palette (the indexed-PNG
        // source). Reads the RAW `dac_rgb` via the pinned `expand6to8` — same pure path,
        // no port mutation. Filled on the worker so the server never reads the DAC.
        var palette_present = false;
        if (palette_buf) |pbuf| {
            if (pbuf.len >= 768) {
                for (self.m.vga.dac_rgb, 0..) |entry, i| {
                    pbuf[i * 3 + 0] = vga_render.expand6to8(entry.red);
                    pbuf[i * 3 + 1] = vga_render.expand6to8(entry.green);
                    pbuf[i * 3 + 2] = vga_render.expand6to8(entry.blue);
                }
                palette_present = true;
            }
        }
        return .{
            .kind = d.kind,
            .width = d.width,
            .height = d.height,
            .index_len = d.index_len,
            .rgba_len = d.rgba_len,
            .double_scan = d.double_scan,
            .row_repeat = d.row_repeat,
            .supported = true,
            .palette_present = palette_present,
            .pel_mask = self.m.vga.pel_mask,
        };
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
    // Text-mode video pages: color B8000 (modes 0-3) + mono B0000 (mode 7), each
    // one 32 KiB segment (devices.vga.TEXT_WINDOW_LEN). Mapped permanently like
    // the framebuffer; both reachable via the peek path for `/api/screen`.
    .{ .kind = .text_vram, .phys_start = 0xB8000, .len = 0x8000 },
    .{ .kind = .text_vram_mono, .phys_start = 0xB0000, .len = 0x8000 },
    .{ .kind = .ems_frame, .phys_start = 0xE0000, .len = 0x10000 },
};
