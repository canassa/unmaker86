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
const Keyboard = devices.Keyboard;
const Opl = devices.Opl;
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
            .bios => {
                // Capture AH BEFORE the handler (the BIOS may clobber it) so the
                // post-dispatch set-mode hook sees the REQUESTED function.
                const ah_before = self.cpu.st.getReg8(4);
                self.bios.dispatch(id, self.cpu, &self.bridge);
                // INT 10h AH=00 (set video mode) — re-derive the INT 33h mouse range
                // from the new BDA mode (plans/mouse-input.md §7; dosbox calls
                // MOUSEDOS_AfterNewVideoMode from int10). `src/bios` can't reach the
                // driver (it is below `src/dos`), so the facade makes the call: the
                // BDA video-mode byte is already updated by `setMode`, and the driver
                // re-derives range/granularity + reclamps position WITHOUT a full
                // reset (cursor/handler preserved, matching dosbox).
                if (ah_before == 0x00 and self.bios.isInt10(id)) {
                    self.dos.mouse.afterNewVideoMode(self.cpu);
                }
            },
            .dos => self.dos.dispatch(id, self.cpu, &self.bridge),
            .none => std.debug.panic("callback id {d} dispatched with no owner", .{id}),
        }
    }
};

/// The machine's stable id for the PIT as a scheduler event source (M-D11).
pub const PIT_SOURCE_ID: u16 = 1;

/// The machine's stable id for the keyboard (typematic auto-repeat) as a scheduler
/// event source (M-D11). Stable across snapshot/restore so the live repeat event
/// round-trips and `fireDue` re-binds it to `kbd.onRepeatFire`.
pub const KBD_SOURCE_ID: u16 = 2;

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
    /// 8042 keyboard controller (ports 0x60/0x64) — the keyboard hardware *fill*
    /// path (input-injection.md §4.1). Asserts IRQ1 via the PIC.
    kbd: Keyboard = .{},
    /// AdLib / OPL2 (ports 0x388/0x389) — register-trace timer+status only (no FM
    /// synthesis, D2). Lets an AdLib/SB driver's presence probe succeed (Stunts'
    /// AD15.DRV). Overflow is derived from the cycle ledger (wired below).
    opl: Opl = .{},
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
        // (c1b) bus PortHandler.ctx = &self.kbd: the 8042 keyboard controller
        //       (port 0x60 data, port 0x64 status/command). Registered AFTER the
        //       speaker so the snapshot replay order (registerPort by ID) is stable.
        _ = self.bus.registerPort(0x60, self.kbd.portHandler());
        _ = self.bus.registerPort(0x64, self.kbd.portHandler());
        // (c2) bus PortHandler.ctx = &self.vga: the DAC + pixel-mask ports
        //      (0x3C6-0x3C9), the misc-output write (0x3C2) and its read alias
        //      (0x3CC). VRAM (A0000-AFFFF) is registered as RAM-like MMIO so guest
        //      writes hit the bus host-pointer fast path (no trap, no cycle hole).
        _ = self.bus.registerPort(0x3C2, self.vga.portHandler());
        _ = self.bus.registerPortRange(0x3C6, 4, self.vga.portHandler()); // 0x3C6-0x3C9
        _ = self.bus.registerPort(0x3CC, self.vga.portHandler());
        // (c2a) Input Status Register #1 — colour base 0x3DA + mono alias 0x3BA.
        //       The cycle-derived vertical-retrace / display-enable status so that
        //       retrace-polling guests (Borland putch snow-avoid, mode-13h vsync)
        //       make progress instead of spinning on the unmapped 0xFF default.
        //       Registered AFTER the other VGA ports so the snapshot replay order
        //       (registerPort by ID) stays stable (plans/vga-retrace.md §3.5).
        _ = self.bus.registerPort(0x3DA, self.vga.portHandler());
        _ = self.bus.registerPort(0x3BA, self.vga.portHandler());
        // (c2b) The four indexed register files + Input Status #0 / Feature
        //       Control (plans/vga-spec/01-registers.md, H2). Registered AFTER
        //       the retrace ports so the snapshot replay order (registerPort by
        //       ID) stays stable. Both index AND data ports must be reachable so a
        //       16-bit OUT to an index port splits to index(lo)+data(hi) via the
        //       bus's default out16 byte-split (ports.zig:65-71): port+1 lands on
        //       the data port registered here. Mono CRTC aliases 0x3B4/0x3B5 follow
        //       the existing 0x3BA convention (zdos is always colour for v1).
        _ = self.bus.registerPort(0x3C0, self.vga.portHandler()); // AC index/data (flip-flop)
        _ = self.bus.registerPort(0x3C1, self.vga.portHandler()); // AC data read
        _ = self.bus.registerPort(0x3C4, self.vga.portHandler()); // SEQ index
        _ = self.bus.registerPort(0x3C5, self.vga.portHandler()); // SEQ data
        _ = self.bus.registerPort(0x3CA, self.vga.portHandler()); // Feature Control read
        _ = self.bus.registerPort(0x3CE, self.vga.portHandler()); // GC index
        _ = self.bus.registerPort(0x3CF, self.vga.portHandler()); // GC data
        _ = self.bus.registerPort(0x3D4, self.vga.portHandler()); // CRTC index (colour)
        _ = self.bus.registerPort(0x3D5, self.vga.portHandler()); // CRTC data (colour)
        _ = self.bus.registerPort(0x3B4, self.vga.portHandler()); // CRTC index (mono alias)
        _ = self.bus.registerPort(0x3B5, self.vga.portHandler()); // CRTC data (mono alias)
        // (c3) bus PortHandler.ctx = &self.opl: the AdLib / OPL2 timer+status card
        //      (port 0x388 address/status, 0x389 data). Registered AFTER all the
        //      VGA ports so the snapshot replay order (registerPort by ID) stays
        //      stable. This is register-trace sound (no FM synthesis, D2): it only
        //      models the two timers + the status byte an AdLib/SB presence probe
        //      reads back. Cycle back-pointer bound at (d3) below.
        _ = self.bus.registerPort(0x388, self.opl.portHandler());
        _ = self.bus.registerPort(0x389, self.opl.portHandler());
        _ = self.bus.mapMmio(devices.vga.VRAM_PHYS, devices.vga.VRAM_WINDOW_LEN, self.vga.memHandler());
        // (c1) The text-mode video pages — color B8000 (modes 0-3) + mono B0000
        //      (mode 7). Both are permanently mapped RAM-like MMIO (like A0000):
        //      real hardware has both windows addressable, the CRTC just scans one;
        //      the BDA mode says which is "active". A direct `putch` write or an INT
        //      10h text service lands in these slabs (no trap, no ledger hole), and
        //      `/api/screen` peeks them — closing the text-mode observability gap.
        _ = self.bus.mapMmio(devices.vga.TEXT_COLOR_PHYS, devices.vga.TEXT_WINDOW_LEN, self.vga.textMemHandler());
        _ = self.bus.mapMmio(devices.vga.TEXT_MONO_PHYS, devices.vga.TEXT_WINDOW_LEN, self.vga.textMonoMemHandler());
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
        // (d1b) VGA cycle back-pointer: the Input Status Register #1 (0x3DA/0x3BA)
        //       retrace + display-enable bits are derived from the cycle ledger,
        //       not host time. Re-bound on restore exactly like the PIT/speaker.
        self.vga.cycles = &self.cpu.st.cycles;
        // (d3) OPL2 cycle back-pointer: the timer-overflow state read back through
        //      the status register (port 0x388) is derived from the cycle ledger,
        //      not host time. Re-bound on restore exactly like the PIT/speaker/VGA.
        self.opl.cycles = &self.cpu.st.cycles;
        // (d2) 8042 keyboard controller back-pointer: it asserts IRQ1 through the
        //      PIC (the same `picRaiseThunk` the PIT uses for IRQ0). Re-bound on
        //      restore exactly like the PIT/speaker pointers.
        self.kbd.raise_ctx = &self.pic;
        self.kbd.raise_fn = picRaiseThunk;
        // (d2a) keyboard typematic auto-repeat scheduler seam: schedule/cancel a
        //       repeat event on the machine scheduler (mirror the PIT ch0 seam).
        //       The cycle back-pointer feeds the "now" the first repeat is scheduled
        //       from. Re-bound on restore exactly like the PIT/speaker pointers; the
        //       live repeat event itself rides the scheduler snapshot.
        self.kbd.cycles = &self.cpu.st.cycles;
        self.kbd.sched = .{
            .ctx = self,
            .schedule = kbdSchedThunk,
            .cancel = kbdCancelThunk,
        };
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
        // Emit the INT 16h host/guest-asm HYBRID block (preamble + poll loop) into
        // the BIOS image AFTER the slot table (Phase 1d). INT 16h's IVT vector is
        // pointed at it in `bios.post`/initIvt, not at the bare int16 slot.
        self.bios.emitInt16Hybrid(&self.bios_image);
        // Plant the EXEC "return into the child" RETF stub (nested-EXEC de-nest):
        // `loader.exec` redirects CS:IP here after pushing the child entry CS:IP.
        Bridge.emitExecRetf(&self.bios_image);
        // Stage the VGA ROM fonts into the BIOS image (the F000 window is ROM;
        // writes are dropped, so the bytes must be planted in the image before
        // loadRom). AH=1130 / IVT[0x1F]/[0x43] then return real font pointers.
        bios_mod.int10_mod.stageFonts(&self.bios_image);
        // Stage the VGA save-pointer ROM chain (video parameter / DCC / static-
        // functionality / video-save-pointer tables) into the same BIOS image;
        // POST then points IVT[0x1D] + BDA VS_POINTER at them (plans/vga-spec §3.3).
        bios_mod.vga_rom.stage(&self.bios_image);
        // Stage the resident "EMMXXXX0" EMM device-driver header into the BIOS
        // image at F000:0000 (the free first paragraph; the callback slot table
        // starts at F000:1000). The INT 67h vector's segment is 0xF000, so this
        // puts the name signature at F000:000A — exactly where an EMS-presence
        // probe (BaK's `ems_detect_driver`) reads it. The header's interrupt-
        // entry field references the live INT 67h trap-stub offset so the header
        // is self-consistent with the vector; the vector + stub at F000:1160 are
        // untouched, so EMS dispatch is unchanged.
        dos_mod.stageEmsDeviceHeader(
            &self.bios_image,
            Bridge.slotSegOff(self.dos.ids.get(.int67)).off,
        );
        self.bus.loadRom(Bridge.IMAGE_BASE, &self.bios_image);
        // The re-entrancy trampoline lives in conventional RAM (writable; its INT
        // immediate is patched per runGuestInt). Plant it after reset zeroed RAM.
        br.plantTrampoline();
        // BIOS POST: PIC/PIT/A20 + IVT (unhandled-default + serviced) + BDA.
        self.bios.post(br);
        // DOS init: vectors + arena MCB + standard handles. The arena spans low
        // DOS memory; place the first MCB at segment 0x0800 (32 KiB) and let it run
        // up to 0xA000 — the 640 KiB video-RAM wall (the UMA/VGA framebuffer starts
        // at 0xA0000; see src/bus/memmap.zig conventional_end=0x9FFFF). That is the
        // faithful real-DOS conventional-memory ceiling (no EBDA is modeled, so the
        // wall is the full 640 KiB, exactly what INT 12h / BDA 0040:0013 report).
        // 0xA000 - 0x0800 = 0x9800 paragraphs. This makes the largest free far block
        // ~275 KiB > BaK's MEM.DAT minimum (243,000 bytes) so check_memory_or_die
        // passes. Keep this CONSISTENT with bda.OFF_MEMSIZE_KB (640) and INT 12h.
        self.dos.dosInit(br, 0x0800, 0x9800);
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
    /// Keyboard typematic schedule seam: the keyboard passes CYCLES directly (an
    /// ms→cycle conversion, not a PIT-tick count), so no `ticksToCycles`.
    fn kbdSchedThunk(ctx: *anyopaque, from: u64, delta_cycles: u64) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.sched.schedule(from, delta_cycles, KBD_SOURCE_ID, .kbd_repeat, 0);
    }
    fn kbdCancelThunk(ctx: *anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.sched.cancel(KBD_SOURCE_ID, .kbd_repeat);
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
        self.kbd.reset(); // 8042 FIFO/status/config back to power-on (IRQ ptr kept)
        self.vga.reset(); // zero VRAM + DAC + indices (deterministic power-on)
        self.opl.reset(); // OPL2 timers + reg index to power-on (no overflow)
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
                .kbd_repeat => self.kbd.onRepeatFire(ev.fire_cycle),
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
        /// The text-mode pages `machine.vga.text_vram` (B8000) and
        /// `machine.vga.text_vram_mono` (B0000) are handled the same way: copied
        /// out-of-band by the caller, NOT placed in any Snapshot struct; `wire()`
        /// re-maps them on restore (§3.4 of plans/text-mode-video.md).
        vga: Vga.Snapshot,
        speaker: Speaker.Snapshot,
        /// OPL2 (AdLib) timer + status + register-index state. The `cycles`
        /// back-pointer is re-bound by the machine on restore, never snapshotted.
        opl: Opl.Snapshot,
        /// 8042 keyboard-controller state (FIFO + status + config). The PIC raise
        /// back-pointer is re-bound by the machine on restore, never snapshotted.
        kbd: Keyboard.Snapshot,
        sched: Scheduler.Snapshot,
        /// Host-side DOS input state not covered by the bus RAM slab. `Dos` field
        /// audit (input Phase 0, §7.3) — each field classified as
        /// (a) guest-RAM-covered, (b) immutable/config, or (c) mutable-host-side:
        ///   - ids: (b) callback-ID table; re-bound by stable ID on restore.
        ///   - current_psp/current_drive/dta_seg/dta_off/arena_first_mcb/strategy/
        ///     ret_code/ret_type/last_error/breakcheck/sysvars_seg: (c) host-side
        ///     kernel state — pre-existing snapshot gap, NOT input state, OUT OF
        ///     Phase 0 scope (Phase 0 is narrowly the uncovered *input* state).
        ///   - cwd/cwd_len/search_dir*/fcb_search_*: (c) host-side, also a
        ///     pre-existing non-input gap (out of Phase 0 scope).
        ///   - sft/dev_table/drives: (c) host-side device/VFS state, NOT input
        ///     state (out of Phase 0 scope). NOTE: `dev_table`'s CON
        ///     `CharDevice.in_buf`/`in_pos`/`in_len` (the stdin cursor,
        ///     devices.zig:33-35) IS mutable-host-side input state, but nothing in
        ///     input Phase 0–3 exercises the INT 21h-stdin injection path — it only
        ///     becomes injection-relevant if Phase 4 lands. DEFERRED-COVERAGE
        ///     ITEM, flagged here deliberately (not silently skipped); it gets
        ///     added to the snapshot if/when Phase 4 wires that path.
        ///   - mouse: (c) mutable-host-side INPUT state, NOT in guest RAM — the
        ///     known Phase 0 case. INCLUDED below.
        ///   - last_unsupported/terminated: (c) host-side, not input state.
        /// The keyboard ring lives in guest BDA RAM (bda.zig:18) and is already
        /// covered by the bus RAM-slab snapshot — needs no field here.
        dos_mouse: @TypeOf(@as(Dos, undefined).mouse).Snapshot,
        /// EMS host-side state (INT 67h handler table + frame map + bump cursor +
        /// page counts). This is the SMALL by-value bookkeeping; the large ~15 MiB
        /// EMS `backing` slab is copied OUT OF BAND by the caller (like `bus.ram`
        /// and `vga.vram` above — `self.dos.ems.backingBytes()` /
        /// `restoreBacking`), never inlined into this struct. Now that BACKING ==
        /// REPORTED (956 pages) the slab is far too large for a by-value snapshot.
        dos_ems: Dos.EmsType.Snapshot,
        /// Host-side DOS KERNEL state the bus RAM slab does NOT cover. Before the
        /// nested-EXEC de-nest these were a documented latent gap (machine.zig
        /// audit above): mid-EXEC was never a first-class snapshot point because the
        /// child ran nested inside one host trap. De-nesting makes mid-child a real
        /// pause/snapshot boundary (a child breakpoint returns to the API with the
        /// machine paused mid-child), so these MUST round-trip or a restore into a
        /// fresh machine would resume the WRONG process/DTA. POD; snapshot-safe.
        dos_current_psp: u16,
        dos_current_drive: u8,
        dos_dta_seg: u16,
        dos_dta_off: u16,
        dos_ret_code: u16,
        dos_ret_type: u8,
        dos_terminated: bool,
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
            .opl = self.opl.snapshot(),
            .kbd = self.kbd.snapshot(),
            .sched = self.sched.snapshot(),
            .dos_mouse = self.dos.mouse.snapshot(),
            .dos_ems = self.dos.ems.snapshot(),
            .dos_current_psp = self.dos.current_psp,
            .dos_current_drive = self.dos.current_drive,
            .dos_dta_seg = self.dos.dta_seg,
            .dos_dta_off = self.dos.dta_off,
            .dos_ret_code = self.dos.ret_code,
            .dos_ret_type = self.dos.ret_type,
            .dos_terminated = self.dos.terminated,
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
        self.opl.restore(snap.opl);
        self.kbd.restore(snap.kbd);
        self.sched.restore(snap.sched);
        self.dos.mouse.restore(snap.dos_mouse);
        self.dos.ems.restore(snap.dos_ems);
        self.dos.current_psp = snap.dos_current_psp;
        self.dos.current_drive = snap.dos_current_drive;
        self.dos.dta_seg = snap.dos_dta_seg;
        self.dos.dta_off = snap.dos_dta_off;
        self.dos.ret_code = snap.dos_ret_code;
        self.dos.ret_type = snap.dos_ret_type;
        self.dos.terminated = snap.dos_terminated;
        self.shutdown = snap.shutdown;
    }
};
