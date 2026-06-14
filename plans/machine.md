# zdos machine module — implementation plan (`src/machine/` + the 8259 PIC / 8254 PIT devices)

This is the literal, ordered build plan for the **machine** — the module that wires `Cpu(Bus)` + the
bus + the deterministic **scheduler** + the **8259 PIC** + the **8254 PIT** into a runnable,
cycle-reproducible system — in **Zig 0.16**. The machine is the **top of the lower module graph**
(`src/machine/` imports `cpu`, `bus`, `devices`; nothing imports it except `src/dos`/`src/bios`/
`src/api`). It is where the CPU's **deferred determinism boundaries get closed**: the HLT/idle
fast-forward, the IRQ-recognition cycle position, and the fault-to-machine shutdown policy.

**Scope is the machine skeleton + scheduler + interrupt + timer subsystem.** It does NOT include the
DOS kernel, BIOS trampolines, VGA, keyboard/mouse, EMS, or sound — those are separate modules
(`src/dos/`, `src/bios/`, more `src/devices/`) wired in *later* against the seams this plan
establishes. This plan builds the machine far enough to run a real-mode program that programs the
PIT, takes a timer IRQ through the PIC, runs an ISR, and is **byte-identical run-to-cycle-N twice** —
the core determinism regression and the foundation BaK is built on.

**Why this scope, and why it is determinism-critical:** the v1 target is **Betrayal at Krondor
(1993)** (`CLAUDE.md` §"First target"). BaK's animation, music timing, and game clock are
**PIT/timer-driven** — getting timer determinism right *is* the BaK requirement. The PIT's IRQ0 must
land at a **deterministic cycle**, recognized at a **deterministic instruction boundary**, every run.
This is precisely the cycle-ledger hole that Spice86 smears across (frame N drifting 346k–3.6M cycles
between launches, `CLAUDE.md` §"Prime directive"). The whole module is on the reproducibility
surface: it must be a **pure function of (state, inputs, the cycle counter)** with **no host wall
clock, no host scheduling, no unordered iteration** anywhere.

**Read before starting (source of truth — do not work from memory):**
- `CLAUDE.md` — prime directive (byte-identical state at cycle N; **emulated time = f(cycle
  counter)**; no host time/scheduling; **deterministic interleaving**, hard constraint #4;
  reproducibility is the regression test, #6), ground rule (no fakes; **flag, don't bypass**), the
  module graph (machine wires cpu+bus+devices; lower modules never import upper), and the **First
  target: Betrayal at Krondor** — its animation is PIT-driven.
- **`src/abi/bus_contract.zig` — the EXACT contracts this module implements**, verbatim:
  `assertInterruptControllerContract` (the PIC implements `getPendingInterrupt() ?u8` + `ackIrq(u8)`),
  `assertSchedulerContract` (the machine implements `nextEventCycle() u64`), `assertFaultSinkContract`
  (the machine implements `onShutdown()`). These are comptime-verified the same way the Bus contract
  is — do not invent a different shape.
- **`src/cpu/cpu.zig` + `src/cpu/interrupts.zig` — how the CPU consumes the contracts.** Read the
  *actual* code: `CpuWith(Bus, .{ .Pic, .Scheduler })` asserts all three contracts (cpu.zig:60-63);
  `Cpu.init(bus, pic, sched)` takes three pointers (cpu.zig:81); `step()` delegates to
  `interrupts.step()` (cpu.zig:180-182); `runCycles`/`runUntil` are thin loops over `step()`
  (cpu.zig:184-201); `sched_onShutdown()` calls `sched.onShutdown()` if present (cpu.zig:171-175);
  `interrupts.step()` already implements the **HLT fast-forward query** (`sched.nextEventCycle()`,
  interrupts.zig:54-63), the **`wakeable()` HLT-wake rule** (IF-gated PIC poll + NMI/fault,
  interrupts.zig:90-98), the **`serviceInterrupts()` priority order** (fault→TF→NMI→maskable IRQ,
  interrupts.zig:102-149), the **`getPendingInterrupt`/`ackIrq` handshake** (interrupts.zig:137-145),
  and the **triple-fault → `shutdown` + `sched_onShutdown()`** escalation (interrupts.zig:152-168).
  The machine plan must MATCH these — the CPU is done (M4 implemented); this plan supplies the *other
  side* of every one of those calls.
- `src/bus/bus.zig` — the machine **OWNS** the `Bus`, instantiates `Cpu(Bus)`, and wires devices via
  `mapMmio`/`registerPort`/`registerPortRange`/`loadRom`/`setA20` in the bus's documented fixed init
  order (`plans/bus.md` Phase 0 "Machine integration contract" + Phase 3). Devices expose
  `PortHandler`/`MemHandler` structs; the **machine** performs the registration (push model) — the
  bus never reaches into a device.
- `plans/cpu.md` — Phase 5 (interrupts/exceptions, the `serviceInterrupts` priority, the
  one-instruction interrupt shadow, NMI nesting, IRQ recognition timing), the **D11 HLT contract**,
  and the **determinism items the CPU explicitly DEFERRED to the machine** (Phase 5
  "IRQ-recognition POSITION is a pure function of … the deterministic event schedule … the PIC
  computes pending status from the cycle ledger"; Phase 8 "Testing-strategy gap" — the IRQ handshake,
  HLT/scheduler coordination, and fault-to-machine propagation are "machine-level integration tests
  OUTSIDE this plan's scope"; M6 note "they belong to the machine module"). **This plan RESOLVES
  those.** `plans/bus.md` — the machine-integration contract (Phase 0/Phase 3) + B12 snapshot model.
- `.claude/skills/zig-developer/SKILL.md` + `memory-and-performance.md` — no per-op alloc, allocate
  up front, dense-int-keyed tables over maps/pointers, comptime size locks, hot/cold field ordering;
  `references/zig/lib/std/` is the gold standard for exact 0.16 signatures (grep it — do not write
  Zig from memory; check `std.sort`, `std.PriorityQueue`, `std.mem.readInt`/`writeInt` shapes there).
- Reference timing/scheduler/PIC/PIT code (algorithmic detail — two designs to weigh):
  `references/dosbox-staging/src/hardware/pic.cpp` (the **PIC event queue** `pic_queue` + `PIC_AddEvent`
  + `PIC_RunQueue` burst model, "1 tick = 1 ms", `CPU_CycleMax` budgeting; `PIC_Controller` IRR/ISR/
  IMR/priority/EOI), `references/dosbox-staging/src/hardware/timer.cpp` + `timer.h`
  (`PIT_TICK_RATE = 1193182`, the 3 channels, modes, latch/read-back), `references/dosbox-staging/src/
  dosbox.cpp` (the top run loop); `references/dosbox-x/src/hardware/{pic,timer}.cpp`;
  `references/spice86/src/Spice86.Core/Emulator/VM/{EmulationLoop.cs,DeviceScheduler/DeviceScheduler.cs}`
  (step-and-poll loop + a `double`-ms-keyed event queue — the **anti-pattern** for zdos: ms/host-time
  keying is exactly what we must NOT copy), `.../Devices/ExternalInput/{DualPic,Intel8259Pic}.cs`,
  `.../Devices/Timer/{PitTimer,PitChannel,PitMode}.cs` + their snapshot types (a clean serializable
  PIT/PIC design to mirror in spirit). Also `plans/dosbox-staging.md` / `dosbox-x.md` / `spice86.md`
  timing sections.

**Notation:** every actionable step is a `[ ]` checkbox. The **DECISIONS** block records each design
choice (M-D1 … M-D14) with a **recommendation + rationale** per the ground rule (flag, don't silently
decide). Items marked **(determinism-critical)** are part of the reproducibility surface and must be
exact — the timing/scheduler/IRQ items especially. Do **not** write code or touch other files while
working from this plan; it is the spec, the CPU/bus are already built against these contracts.

> **Proportionality note.** Be thorough on **timing, the scheduler, IRQ-recognition cycle position,
> and HLT/idle accounting** — those are the heart and the determinism-critical core. Do not pad the
> PIC/PIT register-decode minutiae or the build wiring beyond what faithfulness needs.

---

## DECISIONS (recommendation + rationale per the ground rule — flag, don't silently decide)

- [x] **M-D1 — PIC/PIT placement: live in `src/devices/`, implementing the contracts; the machine
      OWNS them and passes the PIC in as the CPU's `InterruptController`. RECOMMENDED.** Weighing the
      two options the prompt raises:
  - *Option A — PIC owned by `src/machine/` because it IS the `InterruptController`.* Tempting since
    the CPU is generic over the PIC and the machine supplies it. But the PIC is a programmable device
    with ports (0x20/0x21, 0xA0/0xA1) wired through the **same `registerPort` seam every other device
    uses** (`plans/bus.md` Phase 3), and `CLAUDE.md`'s module graph puts "PIT, PIC, VGA, SB … self-
    registering devices" explicitly in `src/devices/`. Folding the PIC into the machine would make it
    a special case unlike VGA/SB and break that uniformity.
  - *Option B (RECOMMENDED) — PIC + PIT are ordinary `src/devices/` modules.* The PIC `struct`
    implements **both** the bus-side `PortHandler` (so the machine wires its four ports like any
    device) **and** the CPU-side `InterruptController` contract (`getPendingInterrupt`/`ackIrq`,
    `src/abi/bus_contract.zig:41-48`). The PIT implements `PortHandler` for ports 0x40-0x43 and a
    **scheduler-event source** (arms IRQ0 on the machine's scheduler; calls `pic.raiseIrq(0)` from its
    event callback). The **machine owns the values** (holds the `Pic` and `Pit` by value/field),
    constructs `CpuWith(Bus, .{ .Pic = Pic, .Scheduler = Machine })` passing `&self.pic` as the
    interrupt controller, and registers their ports. **Rationale:** matches `CLAUDE.md`'s device
    placement, reuses the existing push-registration seam (`plans/bus.md` Phase 0), keeps the PIC a
    faithful programmable device (not a machine-internal shortcut), and keeps the module graph clean
    (`devices` import only the bus contract leaf; the machine imports `devices`). The PIC is special
    only in that the machine *also* hands its pointer to the CPU as the `InterruptController` — a wiring
    detail, not an ownership change.
  - *DECIDED:* **the `Scheduler` and `FaultSink` contracts are implemented by the MACHINE, not by a
    device** (`src/abi/bus_contract.zig:51-55` — `nextEventCycle`). So `Cpu`'s `Scheduler` type
    parameter is the **`Machine` type itself** (the machine is the scheduler facade the CPU queries on
    HLT, and the `FaultSink` it notifies on shutdown). The PIT *uses* the scheduler but does not *be*
    the scheduler. This is the only shape that satisfies both `assertSchedulerContract` and
    `assertFaultSinkContract` pointing at one owner the CPU already takes as `sched`.
  - *DECIDED — the self-pointer PINNING invariant covers FOUR capture sites, not one.* The wiring
    stores back-pointers into the machine's own fields at **four** places, ALL done in one centralized
    `wire(self: *Machine)` AFTER the struct has its final address, in a **fixed order**:
    (a) the CPU's `*Bus`/`*Pic`/`*Machine` pointers captured at `Cpu.init` (cpu.zig:81-85);
    (b) the bus's `PortHandler.ctx = &self.pic` at PIC port registration (`ports.zig:29` —
    `ctx: *anyopaque`); (c) the same for `&self.pit` at PIT port registration; (d) the scheduler's
    callback-resolution table mapping `(source_id, kind)` → `&self.pit`/`&self.pic` (M-D11 re-bind).
    **REFINEMENT — do NOT mandate heap:** the `Machine` must be **pinned** (stable address) after
    `wire`, but a **heap-allocated `*Machine` OR a pinned embedded/stack instance are BOTH acceptable**
    — neither is mandatory; the caller picks. The load-bearing safety is a **debug-only self-check
    assert** in `wire`/`step` (e.g. `assert(cpu.bus == &self.bus)` and an equivalent for the registered
    `PortHandler.ctx` pointing back at `&self.pic`) that catches an accidental move/copy LOUDLY, plus a
    loud doc-comment "**Machine must not be moved/copied after `wire`.**" Note: `Cpu.init` returns by
    value and is move-safe *precisely because the CPU holds no self-pointer* (it holds only the three
    external pointers handed to `init`) — state this so a future refactor that caches a CPU self-pointer
    doesn't silently break the embed.

- [x] **M-D2 — The scheduler keys on the u64 CYCLE COUNTER, never on host time or ms. DECIDED
      (determinism-critical).** DOSBox keys its `pic_queue` on a `double` "tick index" (1 tick = 1 ms)
      and multiplies by `CPU_CycleMax` to get cycles (`pic.cpp:544-545`); spice86 keys its
      `DeviceScheduler` on a `double` ms `Priority` driven by an `IEmulatedClock`. **Both use
      floating-point time as the key — REJECTED for zdos**: floating-point is a determinism hazard
      (rounding/ordering), and ms-derived timing reintroduces exactly the host-time coupling
      `CLAUDE.md` constraint #2 forbids. **zdos: every event is keyed on an absolute `fire_cycle: u64`
      computed from `cpu.st.cycles` + an integer delta.** `nextEventCycle()` returns the minimum
      `fire_cycle` (or `maxInt(u64)` when empty — matching `NullScheduler`, cpu.zig:42-47). PIT
      reload→cycle conversion is **integer-only** (M-D8). **Rationale:** `CLAUDE.md` "emulated time =
      f(cycle counter)"; a u64 integer key is exactly reproducible, sortable, and snapshot-trivial.

- [x] **M-D3 — Scheduler data structure: a small FIXED-CAPACITY array of event slots with a stable
      total order, scanned linearly for the minimum. RECOMMENDED over a binary heap.** Weighing:
  - `std.PriorityQueue` (a binary heap) gives O(log n) insert/pop but its internal array order after
    sift operations is **not a documented stable function of insertion order** — two events with the
    same `fire_cycle` can pop in heap-dependent order, a determinism footgun, and it allocates a
    backing slice (avoidable churn). DOSBox uses an insertion-sorted linked list (`pic.cpp:427-460`);
    spice86 uses a `TimePriorityQueue`.
  - **RECOMMENDED:** a fixed-capacity `events: [N]Event` inline array (N small — the system has very
    few concurrent timed events: PIT ch0, later PIT ch2/keyboard/mouse/sound; cap at e.g. 32 with a
    comptime size lock) plus an `active: u32` count. `nextEventCycle()` linearly scans for the minimum
    `(fire_cycle, tie_break)` pair. **Rationale:** memory-and-performance.md (no per-op alloc;
    dense-array over heap/map; the set is tiny so O(n) scan beats heap overhead and is trivially
    deterministic), it makes the **tie-break (M-D4) an explicit total order** we control rather than
    inheriting heap internals, and the whole array snapshots as plain bytes (M-D11). Flag: if a future
    device count makes the linear scan hot, swap to a heap *that we keep stably ordered by the
    `(fire_cycle, seq)` key* — but for the BaK device set the array is correct and simplest.

- [x] **M-D4 — Same-cycle tie-break: a fixed total order = `(fire_cycle ASC, then a monotonically
      increasing per-schedule `seq: u64` ASC)`. DECIDED (determinism-critical).** When two events have
      the same `fire_cycle`, the one **scheduled first** (lower `seq`) fires first. `seq` is a u64
      counter on the scheduler, incremented on every `schedule()` and **captured in the snapshot**
      (M-D11) so restore reproduces the order. This is a **strict total order** (no two live events
      share a `seq`), so the "minimum" is always unique and reproducible. **Rationale:** `CLAUDE.md`
      constraint #4 (deterministic interleaving) + #5 (no unordered iteration); the prompt's explicit
      "must be a fixed, documented total order". Rejected alternatives: ordering by a *device ID* (two
      events from the *same* device on the same cycle would still tie); ordering by array slot index
      (slot reuse after cancel makes it non-deterministic across runs). `seq` is the only key that is
      both total and stable across schedule/cancel churn.

- [x] **M-D5 — Run loop: the DOSBox-style BURST model (run the CPU bounded to the next scheduled
      event, then fire due events), NOT spice86 step-and-poll. RECOMMENDED.** Weighing:
  - *spice86 step-and-poll* (`EmulationLoop.RunLoop`: `ExecuteNext()` then poll the scheduler every
    instruction): simple, but polls the event queue on **every** instruction (overhead) and couples
    the loop to a host-time `RegulateCycles()` — host coupling we forbid.
  - *DOSBox burst* (`dosbox.cpp` top loop + `PIC_RunQueue`: compute cycles-to-next-event, run the CPU
    that many cycles, then drain due events): the CPU runs in a tight uninterrupted burst up to the
    next event boundary, events fire, repeat. **RECOMMENDED for zdos** because (a) it polls the
    scheduler **once per burst**, not per instruction — perf; (b) it makes the event-firing point a
    **single, well-defined boundary** — determinism; (c) it composes exactly with the CPU's existing
    `step()` contract: the CPU's `runCycles(n)` already loops `step()` (cpu.zig:184-192), and on HLT
    the CPU itself returns `.halted` with idle-to-next-event so the machine fast-forwards. **The
    machine's burst bound is `nextEventCycle() - cpu.st.cycles`.** Because the *interim flat cycle
    model* (cpu.md D6) means an instruction may slightly overshoot the exact event cycle, the burst is
    **"run until `cpu.st.cycles >= fire_cycle`"** (run-past-then-fire), which is deterministic: the
    overshoot is a pure function of the instruction stream, and the event fires at the **first
    instruction boundary at or after `fire_cycle`** (documented, M2). Flag: this means an event's
    *effect* (e.g. IRQ0 raised in the PIC) becomes visible to `serviceInterrupts` at the next boundary
    ≥ `fire_cycle`, never before — which is the **exact deterministic IRQ-recognition position** the
    CPU plan deferred here (resolved in M-D6 / Phase 4).

- [x] **M-D6 — IRQ-recognition cycle position = the first instruction boundary at or after the PIT
      event's `fire_cycle` AT WHICH `IF=1 AND inhibit_irq_one_instruction == false`, driven by the burst
      boundary; the PIC's pending status is a pure function of (PIC state, cycle ledger). DECIDED
      (determinism-critical — this RESOLVES cpu.md Phase 5's deferred C2 / Theme A).** Note the naive
      "first boundary ≥ `fire_cycle`" rule is WRONG when an interrupt shadow (STI/MOV-SS/POP-SS)
      straddles `fire_cycle`: the correct recognition cycle is the first boundary at or after `fire_cycle`
      where BOTH IF=1 and the one-instruction inhibit is clear (interrupts.zig:116, 137). The chain is
      fully cycle-derived: (1) the PIT schedules IRQ0 at an
      integer `fire_cycle` (M-D8); (2) the burst runs the CPU until `cpu.st.cycles >= fire_cycle`,
      then fires the event, whose callback calls `pic.raiseIrq(0)` — setting the PIC's IRR bit **at a
      cycle that is a pure function of the schedule, not of host injection**; (3) the CPU's next
      `serviceInterrupts()` (interrupts.zig:137-145) samples `pic.getPendingInterrupt()`, which is a
      pure function of (IRR, ISR, IMR, priority) — recognized only at an instruction boundary, IF=1,
      not in an interrupt shadow. So the *cycle at which the IRQ is recognized* is reproducible
      byte-for-byte. **The machine MUST NEVER set `irq_pending` as a side effect of host timing** —
      there is no host-timing path; IRR is set only from event callbacks fired at cycle-derived
      boundaries. **Rationale:** `CLAUDE.md` #2/#4/#6; cpu.md Phase 5 "the PIC computes pending status
      from the cycle ledger … recognition reproduces byte-identically." This is the literal
      determinism boundary the CPU deferred to the machine.

- [x] **M-D7 — Host-serviced event cycle cost: events charge NO extra cycles; the cost is already in
      the cycle ledger via the CPU's interrupt-delivery charge. DECIDED (determinism-critical — closes
      the cycle-ledger-completeness question for events).** When an event fires (PIT callback →
      `pic.raiseIrq`), the *event itself* is bookkeeping (setting an IRR bit) and is **timing-neutral**
      — it adds nothing to `cpu.st.cycles` (mirrors the bus's B9 "bus does not charge cycles"). The
      cost that *does* enter the ledger is the **CPU's `interrupt_delivery` charge** when
      `serviceInterrupts` acknowledges the IRQ (interrupts.zig:140, `cpu.st.cycles +=
      cycles.interrupt_delivery`) plus the ISR's own instructions. Port I/O to the PIC/PIT (OUT to
      0x21, etc.) charges the CPU's normal IN/OUT instruction cost (cpu.md Phase 4 exec_io) — the
      device handler is timing-neutral. **There are NO holes:** every cycle is charged by a CPU
      instruction or by the CPU's interrupt-delivery path; the scheduler/PIC/PIT add zero host-derived
      cycles. **Flag for confirmation:** if PIT counter latching/read-back is later found to need a
      device-side synthetic cost, it would be added as a *named, fixed* device cost (like the bus's
      drop-counter pattern) — but for the BaK path no such cost exists; recorded here as a decision,
      not an omission. **Rationale:** `CLAUDE.md` #1 (no holes; fixed synthetic costs); the CPU
      already owns the only cycle-charging surface, so events stay timing-neutral and the ledger has a
      single owner.

- [x] **M-D8 — PIT reload→cycle conversion is integer-only, derived from a fixed
      `cpu_cycles_per_pit_tick` ratio. DECIDED (determinism-critical).** The 8254 ticks at
      `PIT_TICK_RATE = 1193182` Hz (`timer.h:16`). A channel with reload value `R` (R=0 means 65536)
      fires every `R` PIT ticks. To schedule on the CPU cycle counter we need cycles-per-PIT-tick.
      DOSBox derives this from `CPU_CycleMax` (a host-tunable cycles/ms) — **REJECTED** (host-tunable
      ⇒ non-reproducible across configs). **zdos pins a fixed emulated CPU clock** (e.g. a documented
      386 clock such that `cpu_cycles_per_pit_tick` is an exact rational) and converts with **integer
      math + an explicit fractional-remainder accumulator** so no PIT tick is silently dropped or
      double-counted: `delta_cycles = (R * cycles_num + remainder) / cycles_den; remainder = (R *
      cycles_num + remainder) % cycles_den`. The remainder is **scheduler/PIT state captured in the
      snapshot** (M-D11) so the cycle drift is reproducible and bounded. **M-D8a — DECIDED:** the emulated
      CPU clock is pinned at **`CPU_CLOCK_HZ = PIT_TICK_RATE * 12 = 14_318_184`** (~14.32 MHz), i.e.
      **`cpu_cycles_per_pit_tick = 12` exactly** (`cycles_num = 12`, `cycles_den = 1`; the remainder
      accumulator is therefore always 0, but kept for generality / future non-integer ratios). Chosen
      as an exact integer ratio with `PIT_TICK_RATE` (no fractional drift) and comfortably above BaK's
      386SX-12 floor; it is not PRM-accurate (the cycle model is interim-flat per cpu.md D6), only
      **fixed**. Documented in a shared `timing.zig` alongside `PIT_TICK_RATE`. **Rationale:** `CLAUDE.md` #2; integer-only conversion is
      exactly reproducible; the remainder accumulator prevents the gradual integer-truncation drift
      that would otherwise make long runs diverge.

- [x] **M-D9 — PIT channel-0 default for the BIOS tick: mode 3 (square wave), reload 0 (= 65536),
      giving the classic ~18.2 Hz IRQ0. RECOMMENDED.** Real BIOS POST programs ch0 to mode 3, reload
      0x0000 (65536 ticks → 1193182/65536 ≈ 18.2065 Hz). The PIT reset state per `timer.cpp` is
      `PitMode::Inactive` until programmed; the **machine's BIOS-init step** (Phase 1) programs ch0 to
      the 18.2 Hz default so a guest that relies on the BIOS having set it up (most do) sees it.
      **Rationale:** faithfulness to the IBM PC/AT BIOS, and BaK's timer-driven animation expects the
      standard tick to exist from boot. Flag: until the real BIOS module exists, this is done by a
      documented machine-init helper (`programDefaultTimer()`), **clearly labeled as standing in for
      BIOS POST, not faking PIT behavior** — it issues the same port writes the BIOS would; the PIT
      device processes them normally (no special-casing inside the PIT — ground rule).

- [x] **M-D10 — Public machine API: `step()`, `runCycles(n)`, `runUntil(predicate)`, plus
      breakpoints checked BETWEEN steps IN THE MACHINE (not in the CPU loop). DECIDED (cpu.md Theme
      B).** The machine's `step()` is the burst-aware primitive: it fires due events, then calls
      `cpu.step()` (which itself runs `serviceInterrupts` at its boundary), handling the `.halted`
      fast-forward and `.shutdown`. `runCycles`/`runUntil` loop `machine.step()`. **Breakpoints,
      MCP/debugger inspection, and run-to-event live in the machine** between `step()` calls — the
      CPU's `step()` stays branch-clean (cpu.md Phase 0 "Breakpoints are checked BETWEEN steps in the
      machine, NOT inside the CPU loop"). **Rationale:** the API server (`src/api/`) observes the
      machine and must never feed back into timing (`CLAUDE.md` #4); putting breakpoint checks in the
      machine keeps the emulation core's hot loop untouched and the debugger interposition
      deterministic.

- [x] **M-D11 — Snapshot/restore of scheduler + PIC + PIT is part of the module from day one; events
      and handlers are serialized by STABLE ID / by value, never by host pointer. DECIDED
      (determinism-critical, `CLAUDE.md` #6, `plans/bus.md` B12).** The snapshot set: (scheduler) the
      `events` array (each `Event` carries a **stable `source_id` + `kind` enum**, NOT a function
      pointer), `active`, `seq`, the PIT remainder accumulator; (PIC) both controllers' IRR/ISR/IMR/
      priority-rotation/ICW-programming state, the cascade wiring; (PIT) per-channel mode/reload/
      counter/latch/access-state/output. On **restore**, the machine **re-binds `source_id` → the
      device's event callback** (the same way the bus re-binds handler IDs, B12) — function pointers
      are ASLR-varying and unsnapshotable. **Rationale:** `CLAUDE.md` #5/#6; the reproducibility
      regression (run to N → snapshot → restore → run → byte-identical) requires the timing subsystem
      to round-trip exactly, and "events by stable ID" is the only pointer-free way.

- [x] **M-D12 — Fault/shutdown policy: on triple-fault the machine HALTS the run deterministically
      (returns a `.shutdown` stop reason to the caller); it does NOT auto-reset. DECIDED.** The CPU
      surfaces triple-fault by setting `st.shutdown`, returning `.shutdown` from `step()`, and calling
      `sched_onShutdown()` (interrupts.zig:155-157). The machine implements `onShutdown()`
      (`assertFaultSinkContract`, `src/abi/bus_contract.zig:59-61`) by **recording the shutdown in
      machine state and stopping the run loop** — it surfaces the condition to the API/test harness
      rather than silently resetting (which would hide a real bug and break reproducibility). A
      *deliberate* reset is an explicit `machine.reset()` call. **Rationale:** `CLAUDE.md` ground rule
      (flag, don't paper over) + #6; the machine "decides reset policy" per the contract, and the
      deterministic policy is "stop and surface," not "silently recover."

- [x] **M-D13 — The machine run/stop contract: an explicit `machine.StopReason` superset + a bounded
      `runUntil`. DECIDED (load-bearing for the API/MCP debugger).** Define
      **`machine.StopReason = { normal, breakpoint, halted_forever, shutdown, cycles_reached }`** (a
      superset of the CPU's `StopReason { normal, halted, shutdown }`, state.zig:69-77) plus a
      `machine.StepResult`/run-result type. The **exact mapping** from the CPU side: CPU `.normal` →
      machine `.normal`; CPU `.shutdown` → machine `.shutdown`; CPU `.halted` → the machine fast-forwards
      and either continues (an event wakes it) or, if permanently stuck, returns `.halted_forever`. The
      machine adds `.breakpoint` (a registered predicate fired between steps, M-D10) and `.cycles_reached`
      (the `runCycles`/`runUntil` budget was hit). **`runUntil(predicate)` takes a `max_cycles` budget**
      and returns the defined `StopReason` (predicate-satisfied → `.normal`/`.breakpoint`,
      budget-exhausted → `.cycles_reached`, plus `.halted_forever`/`.shutdown`) — it is **never an
      unbounded host loop**. **`.halted_forever` = "no scheduled events AND the CPU's `wakeable()` is
      false"** — mirror the CPU's *actual* `wakeable()` (interrupts.zig:90-98: wakes on a pending IRQ
      when IF=1, on NMI, OR on a pending fault regardless of IF), NOT the current IF-only subset. **Prefer
      deriving the permanent-halt decision from the CPU side** (e.g. a CPU-exposed `wakeable()`/an empty
      `nextEventCycle()`) so the two can't drift. **Document the "armed-but-unwakeable" periodic case:** a
      HLT with everything masked that fast-forwards through periodic events keeps advancing to the
      `runCycles` budget **deterministically** and returns `.cycles_reached` (a documented bounded
      outcome, NOT a hang) — add it to the test matrix. **Rationale:** the API server needs a precise,
      enumerable reason every run stopped; an unbounded `runUntil` would be a host-side hang and break
      reproducible debugging.

- [x] **M-D14 — PIC `ackIrq` re-resolves the line; it does NOT cache or reverse-map the vector.
      DECIDED (robustness/correctness fix).** `getPendingInterrupt` stays a **pure query** that resolves
      the highest-priority unmasked `IRR & ~ISR` line and returns `vector_base + line`. **`ackIrq(vector)`
      MUST RE-RUN the same priority resolution** to select the line and set ISR — it must NOT reverse-map
      `vector` → line via `vector_base`, and must NOT cache a line from the prior `getPendingInterrupt`.
      It then **asserts `vector == vector_base + resolved_line`** (flag a mismatch loudly, don't paper
      over). This keeps `getPendingInterrupt` callable twice per boundary (`wakeable` interrupts.zig:95 +
      `serviceInterrupts` interrupts.zig:138) recomputing identically, and is the acknowledge half of the
      handshake (interrupts.zig:139). **Rationale:** BaK uses the default vector bases where a
      reverse-map *happens* to work, but **non-default bases break a reverse-map** (two controllers, or a
      remapped base, alias vectors); re-resolving from the same pure priority logic is correct under all
      bases and can't drift from `getPendingInterrupt`.

---

## Phase 0: Module skeleton, contract conformance, build wiring

Goal: a compiling `src/machine/` + `src/devices/` that wires `Cpu(Bus)` with a real `Pic`
(`InterruptController`) and the `Machine` as the `Scheduler`/`FaultSink`, with a `test-machine` step.
**Done when** `zig build` and `zig build test-machine` pass, the machine instantiates `CpuWith(Bus,
.{ .Pic = Pic, .Scheduler = Machine })` (all four contracts comptime-verified), and a smoke test
resets the machine to 386 power-on state.

- [x] Create the file split (one responsibility per file):
  - [x] `src/machine/machine.zig` — the `pub const Machine = struct { ... }` (or `pub fn Machine(...)`
        if a comptime Bus parameter is wanted — see below): owns the `Bus` value, the `Pic`/`Pit`
        device values, the `Scheduler`, and the `CpuWith(Bus, .{...})` instance. Implements
        `nextEventCycle() u64` (`assertSchedulerContract`) and `onShutdown() void`
        (`assertFaultSinkContract`). Exposes `init`/`deinit`/`reset`/`step`/`runCycles`/`runUntil` +
        the debugger inspect/patch surface (M-D10). Module root.
  - [x] `src/machine/scheduler.zig` — the deterministic cycle-keyed event queue (M-D2/M-D3/M-D4):
        `Event`, `schedule`/`cancel`/`nextEventCycle`/`fireDue`, the `seq` total order, the snapshot
        fields. Pure data + integer math; no host time.
  - [x] `src/machine/run_loop.zig` — the burst run loop (M-D5): `step()` (fire-due → cpu.step →
        handle halted/shutdown), `runCycles`, `runUntil`, breakpoint interposition (M-D10). (May fold
        into `machine.zig` if small; keep the burst logic documented in one place.)
  - [x] `src/devices/pic.zig` — the 8259 master+slave (`Pic = struct`): implements `PortHandler`
        (ports 0x20/0x21/0xA0/0xA1) **and** the CPU `InterruptController`
        (`getPendingInterrupt`/`ackIrq`) + a `raiseIrq(line: u4)`/`lowerIrq` input the PIT/devices
        call. IRR/ISR/IMR, cascade, ICW/OCW, EOI, priority.
  - [x] `src/devices/pit.zig` — the 8254 (`Pit = struct`): 3 `PitChannel`s, `PortHandler` (ports
        0x40-0x43), the channel-0 → scheduler event arming + re-arm, latch/read-back, mode handling.
  - [x] `src/devices/timing.zig` (or `src/machine/timing.zig`) — the shared `PIT_TICK_RATE`, the
        pinned emulated CPU clock constant, and the integer `cpu_cycles_per_pit_tick` ratio +
        conversion helper (M-D8). (Single source so the PIT and any future PIT-derived device agree.)
  - [x] Test roots: `src/machine/machine_test.zig`, `src/devices/pic_test.zig`,
        `src/devices/pit_test.zig`, `src/machine/scheduler_test.zig`, and a separate
        `src/machine/integration_test.zig` (imports cpu+bus+devices+machine — the milestone
        determinism test; built as its own artifact like the bus's `integration_test.zig`).
- [x] **Build wiring** (mirror cpu/bus wiring in `build.zig` — verified APIs `b.addModule`,
      `b.createModule`, `b.addTest`, `b.addRunArtifact`, `b.step`; the existing `bus_contract_mod`,
      `cpu_mod`, `bus_mod` are at build.zig:16/25/35):
  - [x] `const devices_mod = b.addModule("devices", .{ .root_source_file = b.path(
        "src/devices/devices.zig"), ... });` with `addImport("bus_contract", bus_contract_mod)` (the
        device PIC implements the `InterruptController` contract from the shared leaf; PortHandler/
        MemHandler shapes come from `bus`). Devices import the **contract leaf** and the **bus module's
        public handler interfaces**, never the cpu or machine (module graph: devices ← bus contract).
  - [x] `const machine_mod = b.addModule("machine", .{ ... });` with `addImport("cpu", cpu_mod)`,
        `addImport("bus", bus_mod)`, `addImport("devices", devices_mod)`.
  - [x] `const machine_test_step = b.step("test-machine", "Run machine + PIC + PIT + scheduler tests");`
        over a `b.addTest` rooted at the unit-test root; wire the separate `integration_test` artifact
        into it too; wire `test-machine` into the top-level `test` step (build.zig:89,
        `test_step.dependOn(...)`), alongside `test-cpu`/`test-bus`.
- [x] **Contract conformance — comptime-verified, no drift (the load-bearing gate):**
  - [x] In `src/devices/pic.zig`: `comptime { bus_contract.assertInterruptControllerContract(Pic); }`
        — proves `Pic` has `getPendingInterrupt(*Pic) ?u8` + `ackIrq(*Pic, u8) void` EXACTLY
        (`src/abi/bus_contract.zig:41-48`). No hand-copied signature mirror (drift vector).
  - [x] In `src/machine/machine.zig`: `comptime {
        bus_contract.assertSchedulerContract(Machine); bus_contract.assertFaultSinkContract(Machine); }`
        — proves the machine has `nextEventCycle(*Machine) u64` + `onShutdown(*Machine) void`
        (`src/abi/bus_contract.zig:51-61`). (Note `CpuWith` does NOT assert the FaultSink contract —
        it only checks for `onShutdown` via `@hasDecl` at the call site, cpu.zig:172 — so the machine
        asserts it itself to catch drift early.)
  - [x] **The instantiation IS the integration gate:** `CpuWith(Bus, .{ .Pic = Pic, .Scheduler =
        Machine })` compiling proves all of Bus + InterruptController + Scheduler line up
        (cpu.zig:60-63 runs the three asserts at instantiation). Add a comptime smoke that this type
        builds.
- [x] **`Machine.init(allocator) !Machine` / `deinit()`** — the **fixed construction/wiring order**
      (Phase 1 details the reset specifics; this establishes the call sequence):
  1. `Bus.init(allocator)` (allocates the one fixed RAM slab, installs standard ROM regions,
     A20 **off** — `plans/bus.md` B5/Phase 0).
  2. `bus.loadRom(0xF0000, bios_image)` (the BIOS image; for now a minimal/empty image or a test
     stub — the real BIOS is a later module; flag that this is a placeholder seam, not a fake BIOS).
  3. Construct `Pic` (master+slave at reset state) and `Pit` (channels `Inactive`).
  4. Register PIC ports (`registerPort(0x20,...)`, `0x21`, `0xA0`, `0xA1`) and PIT ports
     (`registerPortRange(0x40, 4, ...)`) via the machine (push model — `plans/bus.md` Phase 0/3).
  5. Construct the `Scheduler` (empty queue, `seq=0`).
  6. Construct `CpuWith(Bus, .{...})` via `Cpu.init(&self.bus, &self.pic, &self.machine_as_scheduler)`
     — note the CPU takes `&self` (the machine) as both the scheduler and the fault sink, and
     `&self.pic` as the interrupt controller.
  7. `machine.reset()` → 386 power-on (Phase 1).
  - [x] **Self-reference (DECIDED — two-phase `init` + a centralized `wire`; M-D1 pinning invariant):**
        the wiring captures back-pointers into the machine's own fields at **FOUR** sites, so the
        `Machine` must not be **moved/copied** after wiring (Zig structs are movable by value). **DECIDED:**
        use a two-phase `init(self: *Machine, …)` + `wire(self: *Machine)` where the caller owns the
        `Machine`'s storage (a **heap `*Machine` OR a pinned embedded/stack instance — both acceptable,
        neither mandated**) and `wire` captures ALL self/field pointers only after the struct has its
        final address.
    - [x] **All four captures happen in ONE `wire(self: *Machine)`, in a fixed order:** (a) CPU→
          Machine/Bus/Pic at `Cpu.init` (cpu.zig:81-85); (b) the bus's `PortHandler.ctx = &self.pic` at
          PIC port registration (`ports.zig:29`); (c) the same `&self.pit` at PIT port registration;
          (d) the scheduler's callback-resolution table mapping `(source_id, kind)` → `&self.pit`/
          `&self.pic` (M-D11). No ad-hoc pointer capture outside `wire`.
    - [x] **Debug-only self-check assert (the load-bearing safety):** in `wire` (and re-checked in
          `step`) assert `cpu.bus == &self.bus`, `cpu.pic == &self.pic`, and that the registered
          `PortHandler.ctx` for the PIC ports equals `&self.pic` (equivalently for `&self.pit`) — so an
          accidental move/copy after `wire` trips LOUDLY rather than corrupting silently. A dangling
          self-pointer would be a determinism/UB disaster.
    - [x] **Loud doc-comment: "Machine must not be moved/copied after `wire`."** Also note `Cpu.init`
          returns by value and is move-safe *because the CPU holds no self-pointer* — it holds only the
          three external pointers passed to `init`; flag that a future refactor caching a CPU self-pointer
          would silently break the embed. Grep `references/zig/lib/std/` for the idiomatic "struct that
          holds pointers to its own fields" pattern and match it.
- [x] **Smoke test (`machine_test.zig`):** `Machine.init` → assert CS:IP = F000:FFF0, CS base
      0xFFFF0000, A20 disabled (read it back through the bus), PIC/PIT at documented reset state, the
      scheduler empty (`nextEventCycle() == maxInt(u64)`). `deinit` frees with no leak
      (`std.testing.allocator`). **Run `zig build test-machine`.**

---

## Phase 1: Reset & fixed init order (reconciled with the bus + CPU reset states)

Goal: a deterministic power-on/reset that brings up the full machine to 386 power-on, reconciling the
CPU's reset state, the bus's A20-off + ROM regions, and the PIC/PIT device reset states, then
programs the default BIOS timer tick (M-D9). **Done when** a `reset()` round-trip lands every
subsystem in its documented power-on state and two resets are byte-identical.

- [x] **`Machine.reset()` order (deterministic; documented):**
  - [x] `cpu.reset()` — 386 power-on via `State.reset()` (cpu.zig:87-89): EIP=0xFFF0, CS sel 0xF000 /
        base 0xFFFF0000, all `seg_limit=0xFFFF`, EFLAGS=0x00000002, CR0=0, IDTR base=0/limit=0x3FF
        (cpu.md Phase 1b reset; verified in state.zig — `idtr_limit = 0x3FF`). The CPU does NOT touch
        A20 or devices — the machine does.
  - [x] `bus`: A20 **disabled** (`a20_mask = 0x0F_FFFF` — `plans/bus.md` B5; reconcile: the bus's own
        `init` already sets this, `reset()` re-asserts it). Standard ROM regions already `.rom`. RAM
        slab zero (deterministic, B2) — re-zero on reset for reproducibility.
  - [x] `pic.reset()` — both controllers to power-on: IMR = all-masked (0xFF) until ICW programming,
        IRR/ISR = 0, awaiting ICW1; cascade unconfigured until the BIOS programs vector bases. Mirror
        the reset state in `Intel8259Pic.cs` / `pic.cpp` (`PIC_Controller` fields zeroed, `icw_index`
        reset). **Determinism:** every field set explicitly; no uninitialized state (`CLAUDE.md` #5).
  - [x] `pit.reset()` — all 3 channels to `PitMode::Inactive`, latches cleared, counters at a
        documented value (`timer.cpp` reset), access-state at "expect ICW/control word." No event
        scheduled yet.
  - [x] `scheduler.reset()` — empty queue, `active=0`, `seq=0`, remainder accumulator = 0.
  - [x] `machine`: `shutdown=false`.
- [x] **Programmable-interrupt-controller + timer init that the BIOS POST would do (M-D9):** since the
      real BIOS module is later, the machine provides documented init helpers that issue the **same
      port writes the BIOS would**, processed by the devices normally (no device special-casing —
      ground rule):
  - [x] `programDefaultPic()` — ICW1/ICW2/ICW3/ICW4 to set the standard real-mode vector bases
        (master IRQ0→IRQ7 = INT 08h-0Fh, slave IRQ8→IRQ15 = INT 70h-77h), cascade on IRQ2. Since ICW1
        clears IMR to 0, **`programDefaultPic` MUST then write the BIOS OCW1 mask that unmasks IRQ0,
        IRQ1, and IRQ2 (the cascade)** — otherwise the entire slave (IRQ8–15) is dead. **State the
        cascade-unmask requirement explicitly. Flag:** this stands in for BIOS POST and must be replaced
        by the real BIOS when that module lands; document the seam, do not fake the PIC's response.
  - [x] `programDefaultTimer()` — OUT 0x43 (mode 3, ch0, lobyte/hibyte) + OUT 0x40 reload 0,0
        (= 65536) → ~18.2 Hz (M-D9). This is the step that **arms the first IRQ0 event on the
        scheduler** (via the PIT's normal mode-3 programming path, Phase 5).
  - [x] **A20 enable seam:** the BIOS POST enables A20; until the BIOS module exists, leave A20 **off**
        at reset (correct power-on) and provide `machine.enableA20()` for tests that need HMA. Do NOT
        silently enable it (would diverge from real boot).
- [x] **Determinism test (`machine_test.zig`):** two `reset()` calls on the same `Machine` produce
      byte-identical CPU `State`, bus RAM, PIC state, PIT state, and scheduler state (field-wise +
      byte-for-byte on RAM). A fresh `Machine.init` matches a `reset()` of a dirtied machine.

---

## Phase 2: The deterministic scheduler (the heart — determinism-critical)

Goal: a cycle-keyed, totally-ordered event queue with deterministic schedule/cancel/fire and a
documented same-cycle tie-break, snapshot-serializable. **Done when** scheduler unit tests pass for
ordering, tie-break, cancel, and the empty-queue `maxInt` contract, and the snapshot round-trips.

- [x] **`Event` struct (M-D3/M-D11):** `{ fire_cycle: u64, seq: u64, source_id: u16, kind: EventKind,
      val: u32 }` where `EventKind` is an enum naming the event source (`pit_ch0`, later
      `pit_ch2`/`kbd`/`mouse`/`sound`). **No function pointer** — the machine maps `(source_id, kind)`
      → the device callback (M-D11; mirrors the bus's handler-by-ID, B12).
  - [x] **Comptime `@sizeOf(Event)` lock + `[N]Event` capacity lock** (assert with `comptime`).
        **One-line AoS-not-SoA rationale:** N is tiny so a struct-of-arrays split buys nothing — the
        dense `[N]Event` array is simplest and snapshots as plain bytes.
  - [x] **Size N from the FULL device roster:** PIT ch0/ch1/ch2 + keyboard + mouse + sound + margin →
        **~16–64**; document the derivation. Keep the **loud assert-on-overflow** (never silently drop).
- [x] **`schedule(delta_cycles: u64, source_id, kind, val) void`** — compute `fire_cycle =
      cpu.st.cycles + delta_cycles` (the scheduler reads the CPU's current cycle counter — the single
      time source); assign `seq = self.next_seq; self.next_seq += 1`; place in the first free slot;
      `active += 1`. **Assert capacity not exceeded** (flag overflow loudly — never silently drop an
      event; `CLAUDE.md` ground rule + DOSBox's `PIC_QUEUESIZE` overflow is a hard error). **For periodic
      sources, also assert no live event already shares `(source_id, kind)`** (the uniqueness invariant
      below).
  - [x] **Cycle source caveat:** `delta_cycles` must be derived from device state via integer math
        (the PIT uses M-D8's ratio), never from host time. Document that `schedule` is the ONLY entry
        and it always keys on `cpu.st.cycles`.
- [x] **`cancel(source_id, kind) void`** — mark the matching slot free (`active -= 1`). Needed when a
      PIT channel is reprogrammed mid-flight (the old IRQ0 schedule must be canceled and re-armed,
      Phase 5).
  - [x] **`cancel` uniqueness invariant — "≤1 live event per `(source_id, kind)`":** for periodic
        sources, **assert in `schedule` that no live event already shares `(source_id, kind)`** so cancel
        degenerates to cancel-one — this removes the slot-order dependence M-D4 rejected. (If a source
        legitimately needs multiple live events of the same kind, instead **define `cancel` to act on the
        lowest-`seq` match** — documented; but the periodic-source assert is the preferred form.)
- [x] **`nextEventCycle() u64`** (the `Scheduler` contract method, `src/abi/bus_contract.zig:54`) —
      linear scan over active slots for the minimum **`(fire_cycle, seq)`** pair (M-D4); return its
      `fire_cycle`, or `maxInt(u64)` when empty (matches `NullScheduler`, cpu.zig:42-47, which the
      CPU's HLT fast-forward already handles, interrupts.zig:59-61). This is what the CPU queries on
      HLT and what the burst loop bounds against. **The scan runs over a compacted `0..active` prefix**
      (keep live slots packed) — or document a full-N scan as intentional/cheap given the tiny N; pick
      one and state it.
- [x] **`fireDue(machine) void`** — while there is an active event with `fire_cycle <= cpu.st.cycles`,
      pop the **minimum-`(fire_cycle, seq)`** event (M-D4 total order), free its slot, and dispatch it
      to the device callback resolved from `(source_id, kind)`. **Fire in `(fire_cycle, seq)` order**
      — if multiple are due, the earliest-scheduled at the earliest cycle fires first; this is the
      deterministic interleaving (`CLAUDE.md` #4). **Events are timing-neutral (M-D7): firing adds no
      cycles to the ledger.** A callback may `schedule()` a follow-up (the PIT re-arms IRQ0) — the
      follow-up's `fire_cycle` is in the future, so it does not re-fire this drain (guard against an
      event scheduling itself in the past: clamp `delta_cycles >= 1`, documented, mirrors spice86's
      "avoid putting events in the past" note). **The O(n²) drain (re-scan for the minimum each pop) is
      intentional and bounded at this N** — note it; no heap needed for the BaK device set.
- [x] **Snapshot/restore (M-D11) — `seq` round-trips verbatim:** the snapshot serializes the `events`
      array **verbatim (including each event's `seq`) AND `next_seq`**; restore copies BOTH without
      renumbering/compacting, so the `(fire_cycle, seq)` order is **identical pre/post restore**.
      `active`/remainder are also plain serializable state. On restore the machine re-binds
      `(source_id, kind)` → callbacks. Add the round-trip to the determinism test, **including an
      assertion that a snapshot's `next_seq` equals the from-scratch run's `next_seq` at the same
      cycle**.
- [x] **Unit tests (`scheduler_test.zig`):**
  - [x] Empty queue → `nextEventCycle() == maxInt(u64)`.
  - [x] Schedule three events at distinct cycles → they fire in cycle order; `nextEventCycle` returns
        the minimum each time.
  - [x] **Tie-break:** schedule two events at the SAME `fire_cycle` → the one scheduled first (lower
        `seq`) fires first; reverse the schedule order → the firing order reverses accordingly
        (proves `seq`, not slot index, is the key).
  - [x] Cancel a scheduled event → it never fires; `nextEventCycle` reflects the removal.
  - [x] **`cancel` uniqueness:** reprogram ch0 **exactly at the cycle its event is due** → exactly one
        event survives (the re-armed one), and the cadence is **byte-identical across two runs**.
  - [x] Re-arm (a callback schedules a follow-up) does not re-fire in the same drain.
  - [x] Snapshot a populated scheduler → restore → `nextEventCycle` + firing order byte-identical; the
        restored `next_seq` equals the from-scratch run's `next_seq` at the same cycle.
  - [x] **Capacity overflow asserts/flags** (does not silently drop).

---

## Phase 3: The run loop (burst model) — closing the HLT/idle boundary (determinism-critical)

Goal: the burst run loop that runs the CPU bounded to the next event, fires due events, and makes the
**D11 HLT fast-forward** concrete — the CPU charging zero host-derived idle. **Done when** a
no-interrupt program runs to a target cycle deterministically, and a HLT span fast-forwards to the
next event with a byte-identical cycle ledger across two runs.

- [x] **`Machine.step() StepResult`** — the burst-aware primitive (M-D5/M-D10). Exact order at each
      call:
  1. **Fire due events** first: `scheduler.fireDue(self)` (any event with `fire_cycle <=
     cpu.st.cycles` — e.g. an IRQ0 that came due during the previous burst raises its IRR bit in the
     PIC now, **before** the CPU's next boundary check). This is the single, well-defined event-firing
     boundary (M-D5).
  2. **Run the CPU one step:** `const r = cpu.step()`. The CPU internally runs `serviceInterrupts`
     (fault→TF→NMI→maskable IRQ, interrupts.zig:102-149), sampling `pic.getPendingInterrupt()` — so
     the IRQ raised in step 1 is recognized here if IF=1 and not shadowed (M-D6). **The CPU's
     interrupt-delivery cycle charge (interrupts.zig:140) is the only cost added** (M-D7).
  3. **Handle the stop reason:**
     - `.normal` → return; the outer loop continues.
     - `.halted` → **the HLT fast-forward (D11):** `r.cycles_consumed` is the CPU's idle-to-next-event
       (computed in interrupts.zig:59-61 as `nextEventCycle() - cpu.st.cycles`). **The CPU is the ONLY
       writer of its cycle ledger — the machine MUST NOT poke `cpu.st.cycles` directly** (same
       prohibition the plan already states for `irq_pending`, M-D6). Apply the fast-forward by either
       (i) consuming the CPU's returned `cycles_consumed` and having the CPU apply it, OR (ii) calling a
       public **`cpu.fastForwardIdle(to_cycle)`** that advances the ledger to `nextEventCycle()` (a pure
       function of the event schedule — NO host clock). Then loop so the next `step()` fires the now-due
       event and the CPU's `wakeable()` (interrupts.zig:90-98) clears `halted` on the IF-gated pending
       IRQ / NMI / fault.
       - **Permanent halt → `.halted_forever` (M-D13):** `.halted_forever` = **"no scheduled events
         (`nextEventCycle() == maxInt(u64)`) AND the CPU's `wakeable()` is false."** Mirror the CPU's
         *actual* `wakeable()` (interrupts.zig:90-98: pending IRQ when IF=1, NMI, OR a pending fault
         regardless of IF), NOT an IF-only subset — **prefer deriving the decision from the CPU side** so
         the two can't drift. Surface it deterministically (do not spin forever — a real hang the API
         server should report, not paper over).
       - **Armed-but-unwakeable periodic case (M-D13):** a HLT with everything masked that fast-forwards
         through periodic events keeps advancing to the `runCycles` budget **deterministically** and
         returns `.cycles_reached` (a documented bounded outcome, NOT a hang). Add to the test matrix.
     - `.shutdown` → triple fault; record machine shutdown (M-D12), stop the loop, surface `.shutdown`.
  - [x] **Determinism invariants (assert/document):** the machine NEVER reads host time; the burst
        bound and the HLT fast-forward target are both `nextEventCycle()`, a pure function of the
        schedule; `cpu.st.cycles` only ever advances (by CPU instruction cost, interrupt-delivery
        cost, or the HLT fast-forward) — no host-derived increment anywhere. **The machine NEVER writes
        `cpu.st.cycles` directly** — the HLT fast-forward goes through `cpu.fastForwardIdle(...)` (or the
        CPU applying its own returned `cycles_consumed`); the CPU is the sole owner of its cycle ledger
        (same prohibition as `irq_pending`). This is the literal closing of cpu.md's deferred D11
        idle-accounting boundary.
- [x] **`runCycles(n) machine.StopReason`** — loop `machine.step()` until `cpu.st.cycles >= start + n`
      (matches the CPU's own `runCycles` shape, cpu.zig:184-192, but at the machine level so events
      fire). Return the machine `StopReason` superset (M-D13): `.cycles_reached` when the budget is hit,
      else `.shutdown`/`.halted_forever`/`.breakpoint`. **Breakpoint check between steps (M-D10):** if a
      breakpoint predicate is registered, check it after each `step()` and return `.breakpoint` —
      interposed in the machine, not the CPU loop.
- [x] **`runUntil(predicate, max_cycles) machine.StopReason` (M-D13 — BOUNDED, never an unbounded host
      loop)** — loop `machine.step()` until `predicate(self)` (→ `.normal`), the `max_cycles` budget is
      exhausted (→ `.cycles_reached`), a breakpoint fires (→ `.breakpoint`), or `.halted_forever`/
      `.shutdown`. Same between-steps breakpoint interposition.
- [ ] **Breakpoint granularity under bursting (the canonical relationship):** a true DOSBox-style burst
      can call `cpu.runCycles(nextEventCycle() - cpu.st.cycles)` to run a tight CPU burst with no
      per-instruction machine overhead, then `fireDue`. **The debugger ALWAYS uses the per-`step()`
      loop; the burst `cpu.runCycles(...)` fast path is OPT-IN and gated OFF whenever ANY breakpoint is
      armed.** Specify how "any breakpoint armed" is detected — e.g. a non-empty breakpoint set / a
      `breakpoints_armed: bool` the registration toggles — checked once before choosing the loop.
      (Alternative noted, not chosen: an exec-breakpoint comptime hook inside the CPU `step`.) **Both
      loops MUST produce byte-identical cycle ledgers** (the event still fires at the first boundary ≥
      `fire_cycle`, M-D5); add the burst form behind a determinism test that asserts byte-identical
      results vs the per-step form. Choose the per-step form first (correctness/debuggability).
      > PARTIAL: the per-step form IS implemented and is the only loop (correct/debuggable, chosen
      > first per the plan). `breakpoints_armed: bool` exists and gates the (would-be) fast path. The
      > OPT-IN burst `cpu.runCycles(...)` fast path + its byte-identical-vs-per-step determinism test are
      > NOT yet built — deferred as a perf optimization (the per-step loop is byte-identical & correct).
- [x] **Tests (`scheduler_test.zig` / `integration_test.zig`):**
  - [x] A no-interrupt program (MOV/ADD/.../HLT with no scheduled event) → `runCycles` reaches the
        target (`.cycles_reached`); with no events and `wakeable()` false after HLT → `.halted_forever`
        (deterministic, not a spin).
  - [x] **Armed-but-unwakeable periodic case (M-D13):** a HLT with everything masked while a periodic
        PIT event is armed → the machine fast-forwards through the periodic events to the `runCycles`
        budget and returns `.cycles_reached` (bounded, NOT a hang); byte-identical across two runs.
  - [x] **HLT fast-forward:** schedule an event at cycle K, run a program that STIs then HLTs at cycle
        H < K → assert `cpu.st.cycles` jumps to K (via `cpu.fastForwardIdle`, NOT a direct machine
        write), the event fires, the CPU wakes, and the **whole run is byte-identical across two
        executions** (validates D11 no-host-time).

---

## Phase 4: 8259 PIC (implements `InterruptController`) — determinism-critical

Goal: a faithful master+slave 8259 with IRR/ISR/IMR, priority, ICW/OCW programming, EOI, cascade, and
the `getPendingInterrupt`/`ackIrq` handshake the CPU expects — with pending status a **pure function
of (PIC state, cycle ledger)**. **Done when** PIC unit tests pass (priority, EOI, masking, cascade)
and an IRQ raised by a scheduled event is recognized at a deterministic cycle.

- [x] **State (`pic.zig`, mirror `PIC_Controller` in `pic.cpp` + `Intel8259Pic.cs` / `PicSnapshot`):**
      two controllers (master, slave), each with `irr: u8`, `isr: u8`, `imr: u8`, `vector_base: u8`,
      `priority_base` (rotation), `icw_index`/`icw_words`/`single`/`auto_eoi`/`rotate_on_auto_eoi`/
      `special` (ICW/OCW programming state), and the cascade wiring (slave on master IRQ2). Every field
      explicitly reset (`CLAUDE.md` #5). **Snapshot-serializable by value (M-D11).**
- [x] **`raiseIrq(line: u4) void` / `lowerIrq(line: u4) void`** — the device-facing input (the PIT
      calls `raiseIrq(0)` from its event callback; later devices call their lines). Sets/clears the IRR
      bit on the right controller (lines 8-15 → slave, which asserts master IRQ2). **This is the ONLY
      way IRR bits get set** — never from host timing (M-D6).
- [x] **`getPendingInterrupt(*Pic) ?u8`** (the contract method, `src/abi/bus_contract.zig:44`) —
      compute the highest-priority unmasked, not-in-service request: `(irr & ~imr)` gated by ISR
      priority (a higher-or-equal in-service IRQ blocks lower ones — the `check_for_irq` logic in
      `pic.cpp:67-86`), resolve master vs slave cascade (a slave request surfaces only if master IRQ2
      is unmasked and wins priority), and return `vector_base + line`. Return `null` if none.
      **CRITICAL: `getPendingInterrupt` is a PURE QUERY — it must NOT mutate ISR/IRR** (the CPU calls
      it possibly multiple times per boundary via `wakeable()` interrupts.zig:95 AND
      `serviceInterrupts` interrupts.zig:138). Mutation happens only in `ackIrq` (M-D6 — pending status
      is a pure function of state).
  - [x] **Spurious IRQ7/15 — NOT modeled (one-line decision):** the references don't model it and the
        cycle-derived IRR model has no INTA window in which a line vanishes; `getPendingInterrupt`
        returns `null` if nothing is pending (no synthesized vector 7/15), **matching spice86**.
- [x] **`ackIrq(*Pic, u8) void`** (the contract method, `src/abi/bus_contract.zig:47`; M-D14) — the
      acknowledge half of the handshake the CPU calls when it recognizes an IRQ (interrupts.zig:139).
      **REFINEMENT — re-resolve, do NOT cache, do NOT reverse-map:** `ackIrq` **MUST RE-RUN the same
      priority resolution `getPendingInterrupt` uses** to select the line — it must NOT reverse-map
      `vector` → line via `vector_base`, and must NOT cache a line from the prior `getPendingInterrupt`.
      Then **clear the IRR bit, set the ISR bit** (the IRQ is now in service, blocking lower priority
      until EOI), handle the cascade (acking a slave IRQ sets ISR on both slave and master IRQ2), and
      **assert `vector == vector_base + resolved_line`** (flag a mismatch loudly, don't paper over).
      Re-resolving keeps `getPendingInterrupt` callable twice per boundary and can't drift from it; it
      is a **robustness/correctness fix** (BaK uses default bases where a reverse-map happens to work,
      but non-default bases break a reverse-map). This is what keeps the 8259 faithfully modeled
      (IRR→ISR transition on ack), not a one-way push (cpu.md / `src/abi/bus_contract.zig:38-40`).
- [x] **Port programming (`PortHandler` for 0x20/0x21 master, 0xA0/0xA1 slave; mirror `pic.cpp`
      `write_command`/`write_data` + `read`):**
  - [x] **ICW1 (port 0x20/0xA0, bit 4 set)** → start init sequence (expect ICW2/3/4), reset
        IRR/ISR/priority per the 8259 init spec. **ICW1 MUST clear IMR to 0** (datasheet) — the BIOS
        OCW1 then re-establishes the runtime mask.
  - [x] **ICW2 (port 0x21/0xA1)** → set `vector_base` (the real-mode BIOS sets master=0x08, slave=0x70).
  - [x] **ICW3** → cascade config (master: slave-on-IRQ2 bitmask; slave: its cascade ID).
  - [x] **ICW4** → 8086 mode, auto-EOI flag.
  - [x] **OCW1 (port 0x21/0xA1 after init)** → write `imr` (the mask register; `set_imr` in
        `pic.cpp`). **The most common runtime write** (guests mask/unmask IRQ0 etc.).
  - [x] **OCW2 (port 0x20/0xA0)** → **EOI handling:** non-specific EOI (clear the highest in-service
        ISR bit), specific EOI (clear a named bit), rotate-on-EOI. Mirror `pic.cpp`
        `check_after_EOI`/`update_active_irq`. **Cascade EOI — each EOI is processed PER-CONTROLLER
        INDEPENDENTLY:** the slave's ISR-clear does NOT touch master IRQ2; **the guest ISR issues the
        second EOI itself.** Master single-EOI (IRQ0) is the happy path; slave two-EOI is the cascade
        path, not a forced pairing — do not auto-clear master IRQ2 from a slave EOI. **Guard:** a
        non-specific EOI to an **idle controller (no in-service IRQ) is a no-op.**
  - [x] **OCW3 (port 0x20/0xA0)** → read-register select (IRR vs ISR read-back), special-mask-mode,
        poll. `read` (IN 0x20/0xA0) returns IRR or ISR per the last OCW3; IN 0x21/0xA1 returns IMR.
- [x] **Determinism (M-D6, the resolution of cpu.md Phase 5's deferred C2):**
  - [x] **No host time, no RNG, no unordered iteration** anywhere in `pic.zig` (grep-enforced test).
  - [x] **Pending status is a pure function of (PIC state, which is set only from cycle-derived event
        callbacks).** Document that `raiseIrq` is called only from `fireDue` (a cycle-keyed boundary),
        so the cycle at which an IRR bit appears is a pure function of the schedule.
  - [x] **Priority resolution is a fixed total order** (master 0,1,2(→slave 8-15),3,4,5,6,7 with
        rotation state explicit) — no ambiguity.
- [x] **Unit tests (`pic_test.zig`):**
  - [x] **Priority:** two simultaneous IRRs → `getPendingInterrupt` returns the higher-priority vector;
        after `ackIrq` of the higher, the lower is blocked until EOI, then surfaces.
  - [x] **Masking:** an IMR-masked line never surfaces in `getPendingInterrupt`; unmasking it surfaces
        it.
  - [x] **EOI:** non-specific + specific EOI clear the right ISR bit; a second pending IRQ surfaces
        only after EOI.
  - [x] **Cascade:** a slave IRQ (8-15) surfaces only when master IRQ2 is unmasked; acking it sets ISR
        on both; the two-EOI return sequence (per-controller, M-D14) clears both. A non-specific EOI to
        an idle controller is a no-op.
  - [x] **ICW/OCW programming:** ICW1-4 sets vector bases; **ICW1 clears IMR to 0**; IN read-back of
        IRR/ISR/IMR per OCW3.
  - [x] **Purity:** calling `getPendingInterrupt` twice without `ackIrq` returns the same vector and
        does not mutate ISR/IRR.
  - [x] **`ackIrq` re-resolves (M-D14):** with **non-default vector bases**, `ackIrq(vector)` sets the
        ISR bit for the re-resolved highest-priority line (NOT a reverse-map of `vector`); a deliberately
        wrong `vector` trips the `vector == vector_base + resolved_line` assert.
  - [x] **Spurious not modeled:** nothing pending → `getPendingInterrupt` returns `null` (no synthesized
        vector 7/15).

---

## Phase 5: 8254 PIT — the BaK-critical device (determinism-critical)

Goal: a faithful 3-channel 8254 with the modes BaK needs (esp. mode 2/3 for the system tick), counter/
reload/latch/read-back, and **channel 0 scheduling its next IRQ0 as a deterministic future-cycle event
on the scheduler** and re-arming. **Done when** PIT mode/reload/latch unit tests pass and channel-0
IRQ0 fires at the correct, deterministic cycle and re-arms.

- [x] **State (`pit.zig`, mirror `PIT_Block`/the channel struct in `timer.cpp` + `PitChannel.cs` /
      `PitChannelSnapshot`):** 3 `PitChannel` each with `mode: PitMode`, `reload: u16` (0 = 65536),
      `counter: u16`, `read_latch`/`write_latch`, `read_mode`/`write_mode` (lobyte/hibyte/both —
      `timer.cpp:22-26`), `latched: bool`, `output: bool`, the write-state machine (awaiting control
      word / lobyte / hibyte), and **the channel's last-arm cycle + the PIT remainder accumulator**
      (M-D8). Every field explicitly reset; **snapshot-serializable by value (M-D11).**
- [x] **Modes (implement the ones the BIOS/BaK use; `timer.cpp:190-264`, `PitMode.cs`):**
  - [x] **Mode 2 (rate generator)** and **Mode 3 (square wave)** — the system-timer modes (ch0). **Pin:
        the IRQ0 period = R ticks for modes 2 AND 3 alike**; the square-wave half-period (mode 3) affects
        only the OUT pin / read-back, NOT the scheduled IRQ0 event. Model the period faithfully and
        document the mode-3 half-period for the speaker/read-back path. **Mode-2 `R=1` is illegal —
        flag/guard it (do NOT schedule a degenerate 1-tick re-arm).**
  - [x] **Mode 0 (interrupt on terminal count)** — one-shot; needed by some timing code. Schedules a
        single IRQ0 at `reload` ticks, does not re-arm.
  - [x] **Other modes (1/4/5)** — implement the register/counter behavior faithfully; flag any mode a
        BaK trace doesn't exercise as "implemented per datasheet, not yet exercised by the target" —
        do NOT stub (ground rule). (Mode 1/5 use the gate input; ch0's gate is tied high.)
- [x] **Control word (port 0x43) + counter access (ports 0x40/0x41/0x42):** decode the control byte
      (channel select, access mode lobyte/hibyte/both, mode, BCD bit), the lobyte/hibyte write sequence
      to load `reload`, and counter writes. On a **complete reload write to channel 0, (re)arm the IRQ0
      event** (below). **BCD — choose ONE: implement BCD↔binary conversion OR assert-on-BCD-bit (flag);
      do NOT silently treat BCD as binary** (ground rule).
- [x] **Counter read-back + latch (the read paths guests use to measure time):**
  - [x] **Counter latch command (OUT 0x43, latch a channel)** → snapshot the *current* counter into
        `read_latch` so a subsequent IN 0x40 reads a stable value. **The current counter is a pure
        function of (reload, the cycle elapsed since the last arm, the M-D8 ratio)** — compute it from
        `cpu.st.cycles - last_arm_cycle` converted to PIT ticks, NOT from host time
        (`timer.cpp:270-302` does this with `elapsed_ms`; zdos does it with elapsed *cycles*).
        **(determinism-critical: the read-back value is reproducible.)**
    - [x] **IN/OUT cost-vs-handler ordering (one sentence, don't over-spec):** pin that the port handler
          observes `cpu.st.cycles` at a **defined point relative to the instruction's cycle charge**, and
          the read-back's `cpu.st.cycles - last_arm_cycle` references that defined snapshot; note it is
          currently sub-tick/masked at `cpu_cycles_per_pit_tick = 12` (M-D8a) and matters mainly once PRM
          cycles land.
  - [x] **Read-back command (8254-specific, OUT 0x43 with bits 7-6 = 11)** → latch counter and/or
        status for multiple channels; the status byte encodes mode/access/output/null-count
        (`timer.cpp:235-264`). Implement faithfully (BaK and DOS clock code use read-back).
  - [x] **Per-access-mode read state machine — point to dosbox-x `src/hardware/timer.cpp` `read_state`:**
        the lobyte/hibyte toggle, latch-clear-after-full-read, and how the **null-count bit** and the
        **OUT bit** are computed. Name the reference; do NOT fully transcribe it. **This is BaK's
        elapsed-time path.**
  - [x] **IN 0x40/0x41/0x42** → return latched or live counter per access mode (lobyte/hibyte/both
        toggling), clearing the latch after a full read.
- [x] **Channel-0 IRQ0 scheduling on the deterministic scheduler (M-D6/M-D8 — the core of the
      BaK requirement):**
  - [x] On a complete ch0 reload (or `programDefaultTimer`, M-D9): compute `delta_cycles` for `reload`
        PIT ticks via the **integer M-D8 conversion** (with the remainder accumulator), record
        `last_arm_cycle = cpu.st.cycles`, and `scheduler.schedule(delta_cycles, pit_source_id,
        .pit_ch0, 0)`. **If a previous ch0 event is live, `cancel` it first** (reprogramming re-arms).
  - [x] **The event callback (`onPitCh0Fire`)** — called by `fireDue` at the deterministic
        `fire_cycle`: `pic.raiseIrq(0)` (sets IRR bit 0 — the deterministic IRQ-recognition trigger,
        M-D6); then **re-arm** for periodic modes (2/3): compute the next `delta_cycles` (with the
        remainder accumulator so the period doesn't drift), update `last_arm_cycle = fire_cycle` (NOT
        `cpu.st.cycles` — re-arm from the scheduled fire cycle so the period is exact and overshoot in
        the burst doesn't accumulate), and `scheduler.schedule(...)` the next one. Mode 0 (one-shot)
        does not re-arm. **(determinism-critical: re-arm from `fire_cycle`, integer period, remainder
        carried — the IRQ0 cadence is a pure function of the cycle counter.)**
  - [x] **Mode/reload change mid-flight:** cancel the live event and re-arm from `cpu.st.cycles` with
        the new reload; the counter read-back reflects the new programming. Document the exact
        semantics (matches the 8254: a new reload takes effect per mode).
- [x] **Determinism (M-D6/M-D7/M-D8):** no host time, no RNG, no float in the scheduling path
      (grep-enforced); the PIT adds zero cycles to the ledger (M-D7 — only the CPU's interrupt-delivery
      charge counts); the reload→cycle conversion is integer + remainder (M-D8).
- [x] **Unit tests (`pit_test.zig`):**
  - [x] Mode 3 ch0, reload 0 → period = 65536 ticks → the IRQ0 event is scheduled at the correct
        `delta_cycles` (assert against the M-D8 integer conversion); it re-arms with the next event at
        +period (remainder carried).
  - [x] Reload write sequence (lobyte then hibyte) loads `reload` correctly; a partial write does not
        arm.
  - [x] Counter latch → IN 0x40 returns a value consistent with elapsed *cycles* (compute the expected
        from `cpu.st.cycles - last_arm_cycle`); two latches at different cycles return different,
        deterministic values.
  - [x] **Mode 2/3 both schedule IRQ0 at period = R ticks** (the mode-3 half-period does not change the
        event period); read-back/OUT differs between the two but the IRQ0 cadence is identical.
  - [x] **Mode-2 `R=1` illegal guard** flags rather than scheduling a degenerate 1-tick re-arm.
  - [x] Read-back status byte encodes mode/access/output/null-count correctly (dosbox-x `read_state`).
  - [x] **BCD bit** behaves per the chosen policy (converted, or asserted/flagged — never silently
        treated as binary).
  - [x] Mode 0 one-shot fires once and does not re-arm.
  - [x] Reprogramming ch0 cancels the old event and arms the new period.

---

## Phase 6: FaultSink / shutdown + the module determinism contract (the audit gate)

Goal: deterministic fault-to-machine propagation, and a written-down, tested determinism contract for
the whole module (cycle-ledger completeness, event ordering, snapshot round-trip, no host time).
**Done when** the shutdown path is deterministic and the determinism/snapshot tests are green.

- [x] **`onShutdown(*Machine) void`** (`assertFaultSinkContract`, `src/abi/bus_contract.zig:59-61`) —
      called by the CPU on triple fault (interrupts.zig:155-157 via `sched_onShutdown`). Implementation
      (M-D12): set `machine.shutdown = true`; the run loop observes it and returns `.shutdown` (do NOT
      auto-reset — surface it). Document that a deliberate reset is an explicit `machine.reset()`.
  - [x] **Reconcile with the CPU:** the CPU also sets `st.shutdown` and returns `.shutdown` from
        `step()` (interrupts.zig:49-50, 111, 158) — the machine's `step()` must handle both signals
        (the `onShutdown` callback AND the `.shutdown` stop reason) idempotently (Phase 3 step 3).
- [x] **The module determinism contract (write it down in `machine.zig` header + assert in tests):**
  - [x] **Cycle-ledger completeness across the run loop (`CLAUDE.md` #1):** every cycle is charged by
        a CPU instruction, the CPU's interrupt-delivery path, or the HLT fast-forward; the
        scheduler/PIC/PIT charge **zero** host-derived cycles (M-D7). **The CPU is the sole writer of
        `cpu.st.cycles` — the machine never writes it directly** (the HLT fast-forward goes through
        `cpu.fastForwardIdle`/the CPU applying its returned `cycles_consumed`). There are no holes —
        state this explicitly as the closing of the cpu.md-deferred boundary.
  - [x] **Deterministic event ordering + tie-break (M-D4):** the `(fire_cycle, seq)` total order;
        documented and tested (Phase 2).
  - [x] **IRQ-recognition position is a pure function of the cycle ledger (M-D6):** documented as the
        resolution of cpu.md Phase 5's deferred C2 — "the PIC computes pending status from the cycle
        ledger; the machine never mutates IRR from host timing."
  - [x] **HLT/idle accounting (D11):** the machine fast-forwards `cpu.st.cycles` to `nextEventCycle()`;
        no host-derived idle — documented as the resolution of cpu.md's deferred D11 idle boundary.
  - [x] **No host time / RNG / thread / env reads** anywhere in `src/machine/` or `src/devices/`
        (grep-enforced test, mirroring cpu.md Phase 9 / bus.md Phase 4: `@embedFile` every source,
        reject `std.time`, `std.Random`, `std.Thread`, `getenv`, `process.getEnv`; **also reject `f32`/
        `f64` in the scheduling/timing path** — float keys are the spice86/DOSBox anti-pattern, M-D2).
  - [x] **No uninitialized state:** the machine, scheduler, PIC, PIT all `reset()` every field; two
        fresh machines are byte-identical (`CLAUDE.md` #5).
  - [x] **No per-op alloc:** the scheduler array, PIC, PIT are preallocated; `step()`/`fireDue`/the
        device handlers allocate nothing (counting-allocator guard, memory-and-performance.md §7).
- [x] **Snapshot/restore of the whole timing subsystem (M-D11, `CLAUDE.md` #6):** enumerate the
      snapshot set — scheduler (`events`/`active`/`next_seq`/remainder), PIC (both controllers' full
      state), PIT (all channels), machine `shutdown` flag — plus delegate to the bus snapshot
      (`plans/bus.md` B12) and CPU `State`. **Handlers/events re-bound by stable ID** on restore
      (M-D11). Test: a **populated** machine (PIT armed, an IRQ partway through an ISR, A20 toggled,
      RAM dirtied) round-trips **snapshot → restore → run-to-cycle-N → byte-identical**.
- [x] **Tests (`machine_test.zig` / `integration_test.zig`):** the determinism/grep/alloc/snapshot
      audits above.

---

## Phase 7: Milestone integration test — the deterministic timer-tick regression

Goal: the milestone integration test the prompt requires — a tiny real-mode program exercising the
full PIT→PIC→CPU→ISR chain, run-to-cycle-N-twice → byte-identical, plus IRQ-arrival-at-deterministic-
cycle. **Done when** the integration test is green and is byte-identical across two runs.

- [x] **The tiny real-mode program (hand-assembled bytes, loaded into RAM via the bus — like the
      bus's `integration_test.zig`):**
  - [x] Set up a real-mode IVT entry for the timer interrupt vector (INT 08h, the master IRQ0 vector
        per the default PIC programming) pointing at a small ISR in RAM.
  - [x] Program PIT channel 0 (OUT 0x43 control word, OUT 0x40 reload) to a **short period** so the
        IRQ0 fires within a small cycle budget. **Exercise REPROGRAMMING ch0 to a faster tick (mode
        2/3), like BaK does** — not just the 18.2 Hz boot default — so the cancel-and-rearm path is
        covered end-to-end.
  - [x] Unmask IRQ0 in the PIC (OUT 0x21 clearing bit 0).
  - [x] `STI` then `HLT` (or a tight idle loop) — wait for the timer IRQ.
  - [x] The ISR: increment a tick counter in RAM, send EOI to the PIC (OUT 0x20, non-specific EOI),
        `IRET`.
- [x] **Run it through the machine** (`Cpu(Bus)` + real `Pic` + real `Pit` + real `Scheduler`,
      wired by `Machine`): `machine.runCycles(N)` for an N spanning several timer ticks.
- [x] **The core determinism regression (`CLAUDE.md` #6):** run the whole thing **twice** (two fresh
      `Machine.init`s, same program), and assert **byte-identical**: CPU `State` (regs/flags/eip/cycles),
      bus RAM (the tick counter), PIC state, PIT state, scheduler state. This is the regression that
      separates zdos from Spice86 — the timer-driven path reproduces exactly.
- [x] **IRQ-arrival-at-deterministic-cycle test (capture-and-compare + targeted shadow case, M-D6):**
  - [x] **Capture-and-compare across two runs:** record the `cpu.st.cycles` when the ISR's first
        instruction executes and assert it is the **same exact value** across two runs. This is valid
        regardless of the exact recognition formula and pins reproducibility.
  - [x] **Targeted STI-shadow test (golden value by the CORRECT rule):** place IRQ0's `fire_cycle`
        **inside an `STI`-shadowed instruction** and assert recognition **slips exactly one instruction**
        (the first boundary at or after `fire_cycle` where IF=1 AND `inhibit_irq_one_instruction ==
        false`, M-D6) — golden value computed by the correct rule, NOT the naive "first boundary ≥
        `fire_cycle`."
- [x] **HLT-fast-forward-in-the-loop test:** the `HLT` variant of the program → assert the machine
      fast-forwards to the IRQ0 event cycle (no host time), the ISR runs, and the run is byte-identical
      twice (validates D11 end-to-end through the real PIT/PIC, not just the scheduler stub).
- [x] **Snapshot-mid-ISR test (M-D11):** run to a cycle inside the ISR, snapshot, restore into a fresh
      machine, run to N → byte-identical vs the un-snapshotted run.

---

## Milestone ordering & "done when" criteria

- [x] **M0 — Machine skeleton wires `Cpu(Bus)` + bus + PIC + scheduler; reset + run a no-interrupt
      program.** `zig build` + `zig build test-machine` green; `CpuWith(Bus, .{ .Pic = Pic, .Scheduler
      = Machine })` instantiates (all four contracts comptime-verified, `src/abi/bus_contract.zig`);
      the machine owns the `Bus`/`Pic`/`Pit`/scheduler and the self-pointer wiring is pinned (M-D1
      caveat); `Machine.init`/`reset` lands every subsystem at 386 power-on (A20 off, CS:IP F000:FFF0,
      PIC/PIT/scheduler at documented reset); a tiny no-interrupt real-mode program runs to a target
      cycle deterministically. (Phases 0-1)
- [x] **M1 — Deterministic scheduler + HLT fast-forward.** The cycle-keyed event queue
      (`nextEventCycle`/`schedule`/`cancel`/`fireDue`) with the `(fire_cycle, seq)` total order
      (M-D4) passes ordering/tie-break/cancel/snapshot tests; the burst run loop (M-D5) runs the CPU
      bounded to the next event; **HLT fast-forwards `cpu.st.cycles` to `nextEventCycle()` with zero
      host-derived idle (D11), byte-identical across two runs**; `halted_forever` is surfaced
      deterministically. (Phases 2-3)
- [x] **M2 — PIC + IRQ delivery.** The 8259 master+slave with IRR/ISR/IMR, priority, ICW/OCW
      programming, specific+non-specific EOI, cascade, and the `getPendingInterrupt`/`ackIrq`
      handshake (pure-query pending status, M-D6) passes the priority/EOI/masking/cascade tests; a
      `raiseIrq` from a scheduled event is recognized at the CPU's next IF-gated boundary at a
      deterministic cycle. (Phase 4)
- [x] **M3 — PIT IRQ0 + the deterministic timer-tick integration test.** The 8254 with modes 2/3 (+
      mode 0), reload/latch/read-back, and **channel-0 IRQ0 scheduled as a deterministic future-cycle
      event that re-arms from `fire_cycle` with integer period + remainder (M-D8)** passes the PIT unit
      tests; the **milestone integration test** (program PIT, STI, HLT, take a timer IRQ via the PIC,
      run the ISR, EOI, IRET) is **run-to-cycle-N-twice → byte-identical** (the core determinism
      regression), the **IRQ-arrives-at-deterministic-cycle** assertion holds, and the snapshot-mid-ISR
      round-trip is byte-identical. This is the BaK-prerequisite timer determinism, proven end-to-end.
      (Phases 5-7)
- [x] **M4 — Module sign-off.** All DECISIONS (M-D1…M-D14) recorded/honored; the determinism contract
      (Phase 6) is green — grep-enforced no-host-time/no-float-in-timing audit, deterministic reset /
      no-uninitialized-reads, zero-alloc step/fireDue, the snapshot→restore→byte-identical round-trip,
      and the two-run byte-identical timer-tick regression. `src/machine/` imports only `cpu`/`bus`/
      `devices`; `src/devices/` imports only the bus contract leaf + bus handler interfaces (module
      graph clean). The CPU's deferred determinism boundaries (HLT/idle accounting D11,
      IRQ-recognition cycle position, fault-to-machine shutdown) are **explicitly closed and tested
      here**. `zig build` / `zig build test` / `zig build test-machine` all green. Ready for `src/dos/`
      + `src/bios/` to wire INT 21h/BIOS against the machine toward the **Betrayal at Krondor** target.

---

## Out of scope (kept as seams, not built here)

- **DOS kernel / BIOS / EXE loader (INT 21h, INT 10h/13h/16h, IVT setup, callback trampolines):**
  `src/dos/` + `src/bios/`. The machine's `programDefaultPic()`/`programDefaultTimer()`/`enableA20()`
  helpers (M-D9) are **temporary stand-ins for BIOS POST**, clearly flagged — they issue the real port
  writes the BIOS would; they are replaced when the BIOS module lands. The IVT entries the integration
  test installs are test scaffolding, not a real BIOS.
- **VGA, keyboard, mouse (INT 33h), Sound Blaster, EMS (INT 67h):** later `src/devices/` modules +
  `src/dos`/`src/bios`. They wire through the **same scheduler-event + PIC-IRQ + bus-registration seams**
  this plan builds (keyboard/mouse on their IRQs, sound on the PIT/its own timing). EMS is an ordinary
  MMIO device (`plans/bus.md` B8) — no machine-special surface. **Device→PIC/Scheduler wiring will follow
  ONE documented pattern** (e.g. a `DeviceCtx{ pic, sched }` handed to each device at `wire`, or a
  `registerDevice` machine method that captures the device's ports + IRQ/scheduler back-pointers in one
  step) so VGA/keyboard/mouse don't re-derive ad-hoc wiring — **to formalize when the first non-PIT
  device lands** (named here, not fully specced).
- **PIT channel 1 (DRAM refresh) and channel 2 (PC speaker) device effects:** the channel structs and
  modes are implemented faithfully, but the **refresh timing** and **speaker audio output** are not
  wired (ch2's gate/speaker port 0x61 is a later device seam). Channel 0 (the system tick) is the only
  channel scheduling IRQ0 in this plan.
- **PIC auto-EOI / special-mask-mode / poll-mode runtime use beyond what the BIOS programs:**
  implemented per the 8259 datasheet (the programming paths exist), but only the BIOS-default
  configuration (fixed priority, cascade, specific/non-specific EOI) is exercised by the milestone
  test; exotic modes are implemented-not-yet-exercised (flagged, not stubbed).
- **The PRM-accurate per-instruction cycle counts:** the cycle ledger uses the CPU's interim flat
  model (cpu.md D6); the **fixed emulated CPU clock constant** the PIT ratio depends on (M-D8a) is a
  pinned project constant, not a PRM-accurate figure (it only needs to be *fixed* for determinism).
- **Protected mode / paging / V86 / DPMI:** CPU-deferred (cpu.md Deferred section); the machine wires
  only the real-mode CPU. A protected-mode interrupt path (IDT gates, error codes) is a future addition
  to the CPU's shared delivery dispatcher, not the machine.
- **Multi-threaded API server feedback:** `src/api/` observes the machine and may thread, but **must
  never feed back into emulation timing or ordering** (`CLAUDE.md` #4); the breakpoint interposition
  (M-D10) is the only debugger touchpoint and it is between deterministic steps.
```

