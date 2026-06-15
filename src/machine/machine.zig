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
const bridge_mod = @import("bridge");
const bios_mod = @import("bios");
const dos_mod = @import("dos");

pub const scheduler = @import("scheduler.zig");
pub const run_loop = @import("run_loop.zig");

const Bus = bus_mod.Bus;
const Pic = devices.Pic;
const Pit = devices.Pit;
const Vga = devices.Vga;
const Speaker = devices.Speaker;
const Scheduler = scheduler.Scheduler;
const EventKind = scheduler.EventKind;

/// The CPU specialized over the real Bus, the real Pic (InterruptController), the
/// Machine itself (Scheduler + FaultSink), and the `Services` aggregate as the
/// `CallbackSink` (D2). The instantiation IS the M0 integration gate (CpuWith runs
/// all four contract asserts). NOTE the mutual recursion Cpu <-> Services is
/// resolved by pointer indirection: Cpu holds `?*Services`, Services holds `*Cpu`
/// + `Bridge(Cpu)`-by-value; the pointer breaks the size cycle (acyclic layout).
pub const Cpu = cpu_mod.CpuWith(Bus, .{ .Pic = Pic, .Scheduler = Machine, .CallbackSink = Services });
pub const Bios = bios_mod.Bios(Cpu);
pub const Dos = dos_mod.Dos(Cpu);
pub const Bridge = bridge_mod.Bridge(Cpu);

/// The `Services` aggregate (D2/D12/D16) — the CPU's `CallbackSink`. It MUST be a
/// plain `struct` decl (NOT a generic function call) so the mutual recursion
/// `Cpu <-> Services` resolves the SAME way `Scheduler = Machine` does: a struct
/// decl's fields/methods are analyzed lazily, and every cross-reference here is a
/// pointer (`cpu`/`bios`/`dos`) except `bridge` (by value, which only needs `Cpu`'s
/// size — and `Cpu` holds only a `?*Services` pointer to us). A generic
/// `Services(Cpu,...)` function would force full evaluation mid-`CpuWith` and
/// deadlock the comptime cycle.
pub const Services = struct {
    cpu: *Cpu = undefined,
    bios: *Bios = undefined,
    dos: *Dos = undefined,
    bridge: Bridge = .{},
    owner: [bridge_mod.CB_MAX]Owner = @splat(.none),

    pub const Owner = enum { none, stop, bios, dos };

    pub fn wire(self: *Services, cpu: *Cpu, bios: *Bios, dos: *Dos) void {
        self.cpu = cpu;
        self.bios = bios;
        self.dos = dos;
        self.owner = @splat(.none);
        self.bridge.init(cpu);
        self.owner[self.bridge.stop_id] = .stop;
        cpu.cb = self;
    }

    pub fn setOwner(self: *Services, id: u8, who: Owner) void {
        self.owner[id] = who;
    }

    /// The CallbackSink contract (D2): fn (*Services, u8) void. The Grp4 `/7` arm
    /// calls this synchronously, inline in executeOne, after fetch8-ing the id.
    pub fn dispatchCallback(self: *Services, id: u8) void {
        // (1) The synthetic cost (D5) is charged BEFORE the handler. The stop
        // sentinel is cost-exempt (base 0) and routed without a handler.
        _ = self.bridge.chargeBase(id);
        switch (self.owner[id]) {
            .stop => self.bridge.onStopSentinel(),
            .bios => self.bios.dispatch(id, self.cpu, &self.bridge),
            .dos => self.dos.dispatch(id, self.cpu, &self.bridge),
            .none => std.debug.panic("callback id {d} dispatched with no owner", .{id}),
        }
    }
};

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
    vga: Vga = .{},
    /// PC-speaker / KBC port-B (port 0x61) — register-trace sound (I/O band 5).
    speaker: Speaker = .{},
    sched: Scheduler = .{},
    cpu: Cpu = undefined,
    /// The host-serviced BIOS + DOS + the CallbackSink aggregate (D2/D12).
    bios: Bios = .{},
    dos: Dos = .{},
    svc: Services = .{},
    /// The BIOS ROM image the bridge plants stubs into (loaded at POST).
    bios_image: [Bridge.IMAGE_LEN]u8 = @splat(0),

    /// Shutdown latched by `onShutdown` (M-D12). The run loop observes it.
    shutdown: bool = false,

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
        // The VGA owns a large fixed VRAM block; allocate it up-front (no per-op
        // alloc). On a Bus.init failure the bus frees itself; on a VGA failure we
        // free the bus to avoid a leak.
        errdefer self.bus.deinit();
        try self.vga.init(allocator);
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
        // (c1) bus PortHandler.ctx = &self.speaker: KBC port-B / PC-speaker control
        //      (port 0x61). It drives PIT ch2's gate (bit 0) and samples ch2 OUT
        //      (bit 5 read-back) — wired to the PIT below. Registered AFTER the PIT
        //      so the snapshot replay order (registerPort by ID) is stable.
        _ = self.bus.registerPort(0x61, self.speaker.portHandler());
        // (c2) bus PortHandler.ctx = &self.vga: the DAC + pixel-mask ports
        //      (0x3C6-0x3C9), the misc-output write (0x3C2) and its read alias
        //      (0x3CC). VRAM (A0000-AFFFF) is registered as RAM-like MMIO so guest
        //      writes hit the bus host-pointer fast path (no trap, no cycle hole).
        _ = self.bus.registerPort(0x3C2, self.vga.portHandler());
        _ = self.bus.registerPortRange(0x3C6, 4, self.vga.portHandler()); // 0x3C6-0x3C9
        _ = self.bus.registerPort(0x3CC, self.vga.portHandler());
        _ = self.bus.mapMmio(devices.vga.VRAM_PHYS, devices.vga.VRAM_WINDOW_LEN, self.vga.memHandler());
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
        // (d1) PC-speaker back-pointers: the PIT (ch2 gate set + OUT read) and the
        //      cycle counter (the refresh bit is derived from the ledger, not host
        //      time). Re-bound on restore exactly like the PIT's pointers.
        self.speaker.pit = &self.pit;
        self.speaker.cycles = &self.cpu.st.cycles;
        // (e) the host-serviced BIOS + DOS + the CallbackSink aggregate (D2/D12).
        self.bios.init(&self.cpu);
        self.dos.init(&self.cpu);
        self.svc.wire(&self.cpu, &self.bios, &self.dos); // also sets cpu.cb = &svc
        // (e1) The EMS page-frame MMIO window (D15/B8) — FIXED power-on hardware like
        //      VRAM, so it is mapped here at WIRE time (after `dos.init` set up
        //      `self.dos.ems`), NOT in `post()`. Rationale: mapping it in `post()`
        //      made `post()` non-re-runnable after a `reset()` — `reset()` re-zeroes
        //      the EMS device state but does NOT release the bus MMIO claim, so a
        //      second `post()` tripped `mapMmio`'s "page already claimed" assert (and
        //      leaked a bus mem-handler each call). The handler ctx (`&self.dos.ems`)
        //      is pinned, so the mapping survives a reset's `dos.init` re-init. This
        //      makes `post()` cleanly re-runnable — what the `--serve` reset→load path
        //      needs to reproduce a fresh launch byte-identically.
        _ = self.bus.mapMmio(dos_mod.ems_frame_phys, dos_mod.ems_frame_len, self.dos.ems.memHandler());
        // Inject the machine's one-step primitive for the bridge's re-entrancy
        // (D3): runGuestInt drives `stepOnceThunk` (fireDue + cpu.step + HLT FF).
        self.svc.bridge.setStepper(self, stepOnceThunk);
        self.reset();
        self.assertWired();
    }

    /// The bridge's injected one-step primitive (D3): one machine step so PIT/IRQ
    /// events fire during re-entrancy. Used by `runGuestInt`.
    fn stepOnceThunk(ctx: *anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        _ = run_loop.step(self);
    }

    // setOwner thunks for BIOS/DOS callback registration (records id -> subsystem
    // in the Services routing table).
    fn biosOwnerThunk(ctx: *anyopaque, id: u8) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.svc.setOwner(id, .bios);
    }
    fn dosOwnerThunk(ctx: *anyopaque, id: u8) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.svc.setOwner(id, .dos);
    }

    /// Run the full BIOS POST + DOS init (Phase 2/4). Registers BIOS + DOS
    /// callbacks through the bridge, plants all stubs into the BIOS image, loads it
    /// into the BIOS ROM window, points the IVT at the stubs, programs PIC/PIT/A20,
    /// lands the BDA, builds the DOS arena MCB + standard handles. After this the
    /// machine can `bootProgram`.
    pub fn post(self: *Machine) void {
        const br = &self.svc.bridge;
        // Register callbacks (the stop sentinel id 0 was reserved in svc.wire).
        self.bios.registerCallbacks(br, self, biosOwnerThunk);
        self.dos.registerCallbacks(br, self, dosOwnerThunk);
        // Plant all stubs + the re-entrancy trampoline into the BIOS image, then
        // load it so the bytes are real guest code at the vectors (D4).
        @memset(&self.bios_image, 0);
        br.plantAll(&self.bios_image);
        self.bus.loadRom(Bridge.IMAGE_BASE, &self.bios_image);
        // The re-entrancy trampoline lives in conventional RAM (writable; its INT
        // immediate is patched per runGuestInt). Plant it after reset zeroed RAM.
        br.plantTrampoline();
        // BIOS POST: PIC/PIT/A20 + IVT (unhandled-default + serviced) + BDA.
        self.bios.post(br);
        // DOS init: vectors + arena MCB + standard handles. The arena spans low
        // DOS memory; place the first MCB at segment 0x0800 (32 KiB) and let it run
        // up to 0x9000 (just below the UMA), ~0x8800 paragraphs.
        self.dos.dosInit(br, 0x0800, 0x8800);
        // NOTE: the EMS page-frame MMIO window is mapped in `wire()` (fixed power-on
        // hardware, like VRAM), NOT here — so `post()` stays re-runnable after a
        // `reset()` (the `--serve` reset→load path re-runs `post()`). See `wire` (e1).
    }

    /// Load a program from a mounted drive and start it (the v1 boot path). The
    /// machine, after `post`, calls this to load BaK (or a test program) as the
    /// initial process, then runs.
    pub fn bootProgram(self: *Machine, drive: u8, host_name: []const u8, cmdtail: []const u8) !void {
        _ = try Dos.LoaderType.loadProgram(&self.dos, &self.cpu, drive, host_name, cmdtail, .load_and_run);
    }

    /// The complete deterministic fresh-launch boot sequence, factored out so the
    /// `--serve` initial launch AND a `POST /api/load` (after a `POST /api/reset`)
    /// drive the EXACT same path → byte-identical state. It runs the BIOS POST + DOS
    /// init (`post`), (re)mounts the host directory as the DOS drive, selects it, and
    /// loads+starts the program. This is required because `reset()` re-zeroes RAM and
    /// re-runs `bios.init`/`dos.init` (the latter wipes the mounted drives via
    /// `dos.init`'s `drives = @splat(null)`) but does NOT re-run `post()` — so after a
    /// reset the machine has no callbacks planted, no DOS arena/IVT, and no mount.
    /// Calling `boot` re-establishes all of it. PRECONDITION: the machine is at the
    /// post-`wire`/post-`reset` state (RAM zeroed, bridge allocator fresh) — `post`'s
    /// `registerCallbacks` allocates ids from a fresh bridge, which `reset`/`wire`
    /// guarantee. Mirrors what `main.zig` did inline before this method existed.
    pub fn boot(self: *Machine, drive: u8, dir: std.Io.Dir, io: std.Io, host_name: []const u8, cmdtail: []const u8) !void {
        self.post();
        self.dos.mountDrive(drive, dir, io);
        self.dos.current_drive = drive;
        try self.bootProgram(drive, host_name, cmdtail);
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
        self.vga.deinit(self.bus.allocator);
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
        self.bus.resetWatchHit(); // clear the per-run memory-watch breadcrumb (M1
        // Phase 5) — like cpu.reset clears last_delivered. The armed watch table +
        // `.watched` page markers PERSIST (a debug session's breakpoints outlive a
        // machine reset, mirroring the controller's surviving breakpoint set).
        self.pic.reset();
        self.pit.reset();
        self.speaker.reset(); // port_61_data=0; lowers ch2 gate (needs pit reset first)
        self.vga.reset(); // zero VRAM + DAC + indices (deterministic power-on)
        self.sched.reset();
        self.shutdown = false;
        // Re-init the host-serviced state (the callback ids + routing are re-
        // established by `post`; ids stay stable since registration order is fixed).
        self.bios.init(&self.cpu);
        self.dos.init(&self.cpu);
        self.svc.wire(&self.cpu, &self.bios, &self.dos);
        self.svc.bridge.setStepper(self, stepOnceThunk);
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
    // Breakpoints: NOT a machine concern (Milestone 1). The debugger control
    // core (`src/debug/`) owns the run loop and scans its own breakpoint set
    // BETWEEN `run_loop.step` calls — the machine is oblivious to the debugger.
    // (The former single-predicate stub was deleted in M1 Phase 0; it was dead
    // scaffolding wired to nothing.)
    // -----------------------------------------------------------------------

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
        /// VGA device-state subset (DAC + registers). VRAM bytes are large and
        /// captured separately (like the bus RAM slab) — the caller copies
        /// `machine.vga.vram` and restores it into the re-init'd machine's VRAM.
        vga: Vga.Snapshot,
        speaker: Speaker.Snapshot,
        sched: Scheduler.Snapshot,
        shutdown: bool,
    };

    pub fn snapshot(self: *const Machine) Snapshot {
        return .{
            .cpu_state = self.cpu.st,
            .bus = self.bus.snapshot(),
            .pic = self.pic.snapshot(),
            .pit = self.pit.snapshot(),
            .vga = self.vga.snapshot(),
            .speaker = self.speaker.snapshot(),
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
        self.vga.restore(snap.vga);
        self.speaker.restore(snap.speaker);
        self.sched.restore(snap.sched);
        self.shutdown = snap.shutdown;
    }
};
