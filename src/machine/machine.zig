//! The zdos `Machine` — the top of the lower module graph. It OWNS the `Bus`, the
//! `Pic`/`Pit` device values, the deterministic `Scheduler`, and the `Cpu(Bus)`
//! instance, and it IMPLEMENTS the `Scheduler` + `FaultSink` contracts itself
//! (M-D1): the CPU's `Scheduler` type parameter is `Machine`, so the CPU queries
//! `machine.nextEventCycle()` on HLT and notifies `machine.onShutdown()` on a
//! triple fault. The PIC is passed to the CPU as the `InterruptController`.
//!
//! PINNING INVARIANT (M-D1) — **the Machine must NOT be moved/copied after
//! `wire`.** Wiring captures back-pointers into the machine's own fields at FOUR
//! sites, all in `wire(self: *Machine)` after the struct has its final address:
//!   (a) the CPU's `*Bus`/`*Pic`/`*Machine` (Cpu.init);
//!   (b) the bus PortHandler.ctx = &self.pic at PIC port registration;
//!   (c) the same &self.pit at PIT port registration;
//!   (d) the scheduler-callback table mapping the PIT's event source -> &self.pit
//!       and the IRQ raise -> &self.pic.
//! A heap `*Machine` OR a pinned embedded/stack instance are BOTH acceptable; the
//! caller owns storage. A debug-only self-check assert in `wire`/`step` trips
//! LOUDLY on an accidental move. NOTE: `Cpu.init` is move-safe because the CPU
//! holds no self-pointer — only the three external pointers handed to `init`; a
//! future refactor caching a CPU self-pointer would silently break this embed.
//!
//! Determinism contract (the module audit gate, Phase 6):
//!   - The machine NEVER reads host time; the burst bound and the HLT fast-forward
//!     target are both `nextEventCycle()`, a pure function of the schedule.
//!   - The CPU is the SOLE writer of `cpu.st.cycles`; the HLT fast-forward goes
//!     through `cpu.fastForwardIdle(...)` — the machine never writes the ledger.
//!   - IRR bits are set only from cycle-derived event callbacks (`fireDue` ->
//!     `pic.raiseIrq`), never from host timing (M-D6).
//!   - No per-op alloc in `step`/`fireDue`/device handlers.

const std = @import("std");
const cpu_mod = @import("cpu");
const bus_mod = @import("bus");
const devices = @import("devices");
const contract = @import("bus_contract");
const timing = @import("timing");

pub const scheduler = @import("scheduler.zig");
pub const run_loop = @import("run_loop.zig");

const Bus = bus_mod.Bus;
const Pic = devices.Pic;
const Pit = devices.Pit;
const Scheduler = scheduler.Scheduler;
const EventKind = scheduler.EventKind;

/// The CPU specialized over the real Bus, the real Pic (InterruptController), and
/// the Machine itself (Scheduler + FaultSink). The instantiation IS the M0
/// integration gate (CpuWith runs all three contract asserts, cpu.zig:60-63).
pub const Cpu = cpu_mod.CpuWith(Bus, .{ .Pic = Pic, .Scheduler = Machine });

/// The machine's stable id for the PIT as a scheduler event source (M-D11).
pub const PIT_SOURCE_ID: u16 = 1;

/// The machine-level run/stop reason (M-D13) — a superset of the CPU's
/// `StopReason { normal, halted, shutdown }`.
pub const StopReason = enum {
    /// Normal: a step retired / predicate satisfied without a special condition.
    normal,
    /// A registered breakpoint predicate fired between steps (M-D10).
    breakpoint,
    /// HLT with no scheduled events AND the CPU not `wakeable()` — a real,
    /// deterministically-surfaced permanent halt (M-D13), not a host spin.
    halted_forever,
    /// Triple fault / shutdown latched (M-D12). The machine does not auto-reset.
    shutdown,
    /// The runCycles/runUntil cycle budget was exhausted (a bounded outcome).
    cycles_reached,
};

pub const Machine = struct {
    bus: Bus,
    pic: Pic = .{},
    pit: Pit = .{},
    sched: Scheduler = .{},
    cpu: Cpu = undefined,

    /// Shutdown latched by `onShutdown` (M-D12). The run loop observes it.
    shutdown: bool = false,
    /// True if any breakpoint predicate is armed (M-D10) — gates the burst fast
    /// path off so the debugger always uses the per-step loop.
    breakpoints_armed: bool = false,
    /// The registered breakpoint predicate (M-D10) — checked BETWEEN steps in the
    /// machine, never in the CPU loop.
    bp_predicate: ?*const fn (*Machine) bool = null,

    comptime {
        // Contract conformance — comptime-verified, no drift (the load-bearing
        // gate). CpuWith does NOT assert FaultSink (it only @hasDecl-checks
        // onShutdown), so the machine asserts it itself to catch drift early.
        contract.assertSchedulerContract(Machine);
        contract.assertFaultSinkContract(Machine);
    }

    // -----------------------------------------------------------------------
    // Scheduler contract (M-D2) — the CPU queries this on HLT.
    // -----------------------------------------------------------------------
    pub fn nextEventCycle(self: *Machine) u64 {
        return self.sched.nextEventCycle();
    }

    // -----------------------------------------------------------------------
    // FaultSink contract (M-D12) — the CPU calls this on triple fault.
    // -----------------------------------------------------------------------
    pub fn onShutdown(self: *Machine) void {
        self.shutdown = true; // record; the run loop surfaces .shutdown (no reset)
    }

    // -----------------------------------------------------------------------
    // Two-phase construction (M-D1): init builds values; wire captures all four
    // self-pointer sites AFTER the struct has its final address.
    // -----------------------------------------------------------------------

    /// Phase 1 of construction: allocate the bus + build device/scheduler values
    /// in place. Does NOT capture self-pointers (the struct may still move). The
    /// caller MUST call `wire()` on the FINAL-address `*Machine` before use.
    /// `bios_image` is copied to the BIOS window (a placeholder seam — the real
    /// BIOS is a later module; for tests pass an empty slice).
    pub fn init(self: *Machine, allocator: std.mem.Allocator, bios_image: []const u8) !void {
        self.* = .{ .bus = try Bus.init(allocator) };
        if (bios_image.len != 0) {
            self.bus.loadRom(bus_mod.memmap.bios_rom_start, bios_image);
        }
    }

    /// Phase 2 (M-D1): capture ALL four self/field pointer sites in a fixed order,
    /// then reset to power-on. Must be called on the machine's FINAL address; the
    /// machine must not move/copy after this.
    pub fn wire(self: *Machine) void {
        // (a) the CPU's *Bus/*Pic/*Machine.
        self.cpu = Cpu.init(&self.bus, &self.pic, self);
        // (b) bus PortHandler.ctx = &self.pic (PIC ports 0x20/0x21/0xA0/0xA1).
        _ = self.bus.registerPort(0x20, self.pic.portHandler());
        _ = self.bus.registerPort(0x21, self.pic.portHandler());
        _ = self.bus.registerPort(0xA0, self.pic.portHandler());
        _ = self.bus.registerPort(0xA1, self.pic.portHandler());
        // (c) bus PortHandler.ctx = &self.pit (PIT ports 0x40-0x43).
        _ = self.bus.registerPortRange(0x40, 4, self.pit.portHandler());
        // (d) scheduler-callback binding: PIT raise -> &self.pic; PIT schedule/
        //     cancel -> &self (the machine, which owns the scheduler).
        self.pit.cycles = &self.cpu.st.cycles;
        self.pit.raise_ctx = &self.pic;
        self.pit.raise_fn = picRaiseThunk;
        self.pit.sched = .{
            .ctx = self,
            .schedule = schedThunk,
            .cancel = cancelThunk,
        };
        self.reset();
        self.assertWired();
    }

    /// Debug-only self-check (M-D1): trips LOUDLY if the machine moved after wire.
    fn assertWired(self: *Machine) void {
        std.debug.assert(self.cpu.bus == &self.bus);
        std.debug.assert(self.cpu.pic == &self.pic);
        std.debug.assert(self.cpu.sched == self);
        // The registered PortHandler.ctx for the PIC ports must point at &self.pic.
        const id = self.bus.port_handler_id[0x20];
        std.debug.assert(self.bus.port_handlers[id].?.ctx == @as(*anyopaque, &self.pic));
        std.debug.assert(self.pit.sched.?.ctx == @as(*anyopaque, self));
        std.debug.assert(self.pit.raise_ctx == @as(*anyopaque, &self.pic));
    }

    pub fn deinit(self: *Machine) void {
        self.bus.deinit();
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Scheduler-callback thunks (M-D11 — the (source_id, kind) -> device binding).
    // These are the re-bound-on-restore mapping; they carry an opaque ctx so the
    // device module never imports the machine.
    // -----------------------------------------------------------------------

    fn picRaiseThunk(ctx: *anyopaque, line: u4) void {
        const pic: *Pic = @ptrCast(@alignCast(ctx));
        pic.raiseIrq(line);
    }
    fn schedThunk(ctx: *anyopaque, from: u64, ticks: u64, val: u32) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        const delta = timing.ticksToCycles(ticks, &self.sched.remainder);
        self.sched.schedule(from, delta, PIT_SOURCE_ID, .pit_ch0, val);
    }
    fn cancelThunk(ctx: *anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.sched.cancel(PIT_SOURCE_ID, .pit_ch0);
    }

    // -----------------------------------------------------------------------
    // Reset (Phase 1) — deterministic power-on for every subsystem.
    // -----------------------------------------------------------------------
    pub fn reset(self: *Machine) void {
        self.cpu.reset(); // 386 power-on (EIP=0xFFF0, CS base 0xFFFF0000, ...)
        self.bus.setA20(false); // A20 disabled at power-on (BIOS POST enables it)
        @memset(self.bus.ram, 0); // re-zero RAM for reproducibility
        self.pic.reset();
        self.pit.reset();
        self.sched.reset();
        self.shutdown = false;
    }

    // -----------------------------------------------------------------------
    // BIOS-POST stand-in helpers (M-D9). These issue the SAME port writes the
    // real BIOS would; the devices process them normally (no special-casing —
    // ground rule). Replace with the real BIOS module when it lands.
    // -----------------------------------------------------------------------

    /// Program the master+slave 8259 to the standard real-mode configuration:
    /// master vectors INT 08h-0Fh, slave INT 70h-77h, cascade on IRQ2. ICW1
    /// clears IMR to 0, so we MUST write the BIOS OCW1 mask afterward — unmask
    /// IRQ0/IRQ1/IRQ2 (the cascade) or the whole slave is dead (M-D9).
    pub fn programDefaultPic(self: *Machine) void {
        const b = &self.bus;
        // Master ICW1..ICW4.
        b.portOut8(0x20, 0x11); // ICW1: edge, cascade, ICW4 needed
        b.portOut8(0x21, 0x08); // ICW2: master vector base 0x08
        b.portOut8(0x21, 0x04); // ICW3: slave on IRQ2 (bit 2)
        b.portOut8(0x21, 0x01); // ICW4: 8086 mode
        // Slave ICW1..ICW4.
        b.portOut8(0xA0, 0x11);
        b.portOut8(0xA1, 0x70); // ICW2: slave vector base 0x70
        b.portOut8(0xA1, 0x02); // ICW3: slave cascade id 2
        b.portOut8(0xA1, 0x01);
        // OCW1: BIOS runtime mask — unmask IRQ0, IRQ1, IRQ2 on the master; mask
        // the rest. (ICW1 cleared IMR to 0, so we re-establish the mask.)
        b.portOut8(0x21, 0xF8); // master: bits 0,1,2 clear (unmasked)
        b.portOut8(0xA1, 0xFF); // slave: all masked until a device unmasks
    }

    /// Program PIT channel 0 to the BIOS default: mode 3 (square wave), reload 0
    /// (= 65536) -> ~18.2 Hz IRQ0 (M-D9). This arms the first IRQ0 event via the
    /// PIT's normal mode-3 programming path.
    pub fn programDefaultTimer(self: *Machine) void {
        const b = &self.bus;
        b.portOut8(0x43, 0x36); // ch0, lobyte/hibyte, mode 3, binary
        b.portOut8(0x40, 0x00); // reload LSB
        b.portOut8(0x40, 0x00); // reload MSB -> 0 = 65536
    }

    /// A20 enable seam (the BIOS POST does this; until then tests call it).
    pub fn enableA20(self: *Machine) void {
        self.bus.setA20(true);
    }

    // -----------------------------------------------------------------------
    // The run loop (delegated to run_loop.zig, Phase 3).
    // -----------------------------------------------------------------------

    /// Fire all events due at the current cycle (M-D5 step 1). Dispatches each to
    /// the device callback resolved from `(source_id, kind)` (M-D11). Timing-
    /// neutral (M-D7).
    pub fn fireDue(self: *Machine) void {
        const now = self.cpu.st.cycles;
        while (self.sched.popDue(now)) |ev| {
            switch (ev.kind) {
                .pit_ch0 => self.pit.onPitCh0Fire(ev.fire_cycle),
                .pit_ch1, .pit_ch2 => {}, // not wired in this plan (ch0 only)
            }
        }
    }

    pub fn step(self: *Machine) run_loop.StepOutcome {
        return run_loop.step(self);
    }

    pub fn runCycles(self: *Machine, n: u64) StopReason {
        return run_loop.runCycles(self, n);
    }

    pub fn runUntil(
        self: *Machine,
        predicate: *const fn (*Machine) bool,
        max_cycles: u64,
    ) StopReason {
        return run_loop.runUntil(self, predicate, max_cycles);
    }

    // -----------------------------------------------------------------------
    // Breakpoints (M-D10) — checked BETWEEN steps in the machine, never in the
    // CPU loop. Registration toggles `breakpoints_armed` (gates off the burst
    // fast path so the debugger is always per-step).
    // -----------------------------------------------------------------------
    pub fn setBreakpoint(self: *Machine, predicate: ?*const fn (*Machine) bool) void {
        self.bp_predicate = predicate;
        self.breakpoints_armed = (predicate != null);
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore of the whole timing subsystem (M-D11). The bus + CPU
    // snapshot themselves; handlers/events are re-bound by stable ID on restore
    // (the caller re-runs init+wire, then restore).
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        cpu_state: cpu_mod.State,
        bus: Bus.Snapshot,
        pic: Pic.Snapshot,
        pit: Pit.Snapshot,
        sched: Scheduler.Snapshot,
        shutdown: bool,
    };

    pub fn snapshot(self: *const Machine) Snapshot {
        return .{
            .cpu_state = self.cpu.st,
            .bus = self.bus.snapshot(),
            .pic = self.pic.snapshot(),
            .pit = self.pit.snapshot(),
            .sched = self.sched.snapshot(),
            .shutdown = self.shutdown,
        };
    }

    /// Restore onto an already-init'd + wired machine (so handler IDs + callback
    /// bindings already match). Copies RAM separately via `restoreRam`.
    pub fn restore(self: *Machine, snap: Snapshot) void {
        self.cpu.st = snap.cpu_state;
        self.bus.restore(snap.bus);
        self.pic.restore(snap.pic);
        self.pit.restore(snap.pit);
        self.sched.restore(snap.sched);
        self.shutdown = snap.shutdown;
    }
};
