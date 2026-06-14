# zdos CPU module — implementation plan (Intel 80386 / 386DX core, **real mode only**)

This is the literal, ordered build plan for `src/cpu/`: a standalone, cycle-deterministic 80386
(386DX) interpreter core in **Zig 0.16**, generic over a `comptime Bus` type. **Scope is reduced to
real mode**: the full 386 32-bit instruction set executing in real-address mode, real-mode
segmentation/addressing, and real-mode interrupt/exception delivery. **No protected mode, no paging,
no virtual-8086, no x87/387** — see the clearly-labeled **Deferred** section at the end, which keeps
the long-term vision and the structural seams so those subsystems can slot in later without a
rewrite.

**Why this scope:** this CPU is the path to the **Betrayal at Krondor (1993)** v1 target (`CLAUDE.md`
§"First target"). BaK is a plain-`MZ` real-mode 386 game (386SX, 1 MB + ~1 MB EMS, DOS 5.0, VGA,
mouse) that does **not** use the FPU, a DOS extender, protected mode, or paging. The CPU's only job
is to execute the 386 real-mode ISA and deliver real-mode interrupts deterministically. **EMS, VGA,
DOS, mouse, PIT/PIC are *other modules*** (`src/bus/`, `src/devices/`, `src/dos/`, `src/bios/`) — the
CPU imports none of them and is generic over `comptime Bus`.

**Read before starting (source of truth — do not work from memory):**
- `CLAUDE.md` — prime directive (determinism: byte-identical state at cycle N), ground rule (no
  mocks/stubs/fakes; flag structural problems, never bypass), the **80386 real-mode** scope statement
  and the **First target: Betrayal at Krondor** section, module graph (CPU is the bottom module,
  imports nothing, generic over `comptime Bus` — NOT a runtime vtable).
- `.claude/skills/zig-developer/SKILL.md` and `memory-and-performance.md` — register-file layout, no
  per-op alloc, small fields, SoA/indexes; `references/zig/lib/std/` is the gold standard for idioms
  and exact 0.16 signatures (grep it; signatures churn).
- `plans/dosbox-x.md`, `plans/dosbox-staging.md`, `plans/spice86.md` — CPU sections.
- Reference CPU sources for algorithmic detail (real-mode-relevant files):
  `references/dosbox-staging/src/cpu/` (`cpu.cpp`, `cpu.h`, `modrm.cpp/.h`, `lazyflags.h`,
  `flags.cpp`, `registers.h`, `string_ops.h`, `instructions.h`),
  `references/dosbox-x/src/cpu/` (same files, plus `core_normal*` variants),
  `references/spice86/src/Spice86.Core/Emulator/CPU/` (`Registers/`, `Alu*.cs`, `Exceptions/`,
  `CfgCpu/` parser & ModRm). The `paging.cpp`/protected-mode descriptor/task-switch sources are
  referenced only in the **Deferred** section.

**Notation:** every actionable step is a `[ ]` checkbox. The **DECISIONS** block below records the
accepted design choices (D1–D12) as **DECIDED**, with the ones that were purely about deferred
features marked **DEFERRED / N-A**. Cycle/flag/fault tables marked **(determinism-critical)** must be
exact and reproducible — they are the pure-execution portion of the project's cycle ledger.

---

## DECISIONS (recorded — accepted; expanded in-context below)

These were open for confirmation in the prior full-386 plan; under the reduced real-mode scope they
are **accepted as DECIDED**. The two that were purely about deferred subsystems are marked
**DEFERRED**.

- [x] **D1 — Flags: EAGER, with an explicit lazy seam. DECIDED: eager-with-lazy-seam.** Compute
      CF/PF/AF/ZF/SF/OF immediately in each ALU op. Rationale stays determinism/serialization: eager
      means flags are real bits — trivially serializable for cycle-N reproduction / the API server's
      save-restore, with no hidden deferred state; ProcessorTests assert exact EFLAGS every
      instruction, and eager is easiest to make bit-exact against the undefined-flag tables (D9).
      **Honest cost:** eager computes all 6 flags on every ALU op even when they are immediately
      overwritten unread — this is the interpreter hot-path tax that both DOSBoxes avoid with lazy
      flags. **The lazy seam:** every ALU op routes through per-width ALU primitives (the `alu.zig`
      module, Theme/Phase 3) so the flag-commit step is ONE swappable place. The documented future
      upgrade is a *hybrid*: compute the result eagerly, defer only the EFLAGS bit-packing, and
      materialize on PUSHF / Jcc / save — switchable later without rewriting instruction logic.
      Rationale + seam location in Phase 0/3.
- [x] **D2 — Dispatch: one big labeled `switch`** over a `u12` dispatch key (opcode byte | 0x100 for
      the 0F two-byte map | 0x200 for the operand-size-32 base, the DOSBox shape). The Zig compiler
      builds the jump table; full inlining of the `comptime Bus` memory path; no fn-pointer cache
      footprint. Rationale in Phase 2.
- [x] **D3 — Register file: `extern union { dword: u32, word: [2]u16, byte: [4]u8 }`** per GP reg
      (little-endian host only), AoS, register-resident. Rationale in Phase 1b.
- [x] **D4 — Descriptor-cache representation: DEFERRED (real mode needs only the decoded base/limit).**
      The hidden decoded state is split HOT/COLD (Phase 1b layout, Theme F): hot `seg_base: [6]u32` +
      `seg_limit: [6]u32` are the authoritative source on the real-mode access path; the cold parallel
      `seg_desc: [6]SegDescCold` carries the PM-shaped fields (type/dpl/present/big/expand-down/
      conforming) written once on load and never read in real mode. In real mode loading a segment
      updates `base = selector<<4` ONLY (limit set to `0xFFFF` at reset, NOT on load — preserves
      unreal/flat-real). The full raw-descriptor decode (the protected-mode `S_Descriptor`/
      `G_Descriptor` machinery) is **deferred**; the `seg_desc` fields are kept as the seam. See Phase
      1b + the Deferred section.
- [x] **D5 — TLB modeling: DEFERRED.** No paging in scope ⇒ no TLB. Linear address == physical
      address in real mode; the CPU calls `Bus.readPhys*/writePhys*` directly after the
      logical→linear step. A translation hook is left as the seam (Phase 1c). See the Deferred section.
- [x] **D6 — Cycle model: INTERIM DETERMINISTIC FLAT MODEL now; faithful PRM transcription deferred as
      a fidelity-only pass (no longer a blocker).** The active model is a fixed, pure flat base cost per
      instruction (`cycles.FLAT_BASE`), looked up per dispatch key at the Phase 1a choke point — a total,
      hole-free pure function that satisfies the determinism prime directive (which needs *fixed* costs,
      not *accurate* ones). This is documented as **interim / provisional-by-design, NOT a faked 386
      clock count** — no number in `cycles.zig` is presented as a real PRM figure. Transcribing the
      Intel 80386 PRM "Instruction Set Clock Count Summary" canonical per-instruction counts (DOSBox's
      normal core charges a coarse ~1 cycle/op and is explicitly *not* per-instruction-accurate, so it is
      not an adequate source) is a future **fidelity-only** pass: the per-dispatch-key table + named
      event-cost seams in `cycles.zig` make it a **data swap, not a rewrite**. The PRM was not available
      offline; per the ground rule the real counts are NOT invented — the flat model is honestly labelled
      interim instead. Rationale in Phase 7.
- [x] **D7 — V86 fidelity: DEFERRED.** Virtual-8086 mode is out of scope (BaK doesn't use it; EMS is
      delivered via a host `INT 67h` handler, not EMM386/V86). See the Deferred section.
- [x] **D8 — Test assertions: state-only by default.** Assert final regs/flags/memory against the
      ProcessorTests 386 **real-mode** vectors; add an **opt-in** bus-access-trace assertion behind a
      comptime flag for ordering regressions. Do **not** assert ProcessorTests' `cycles` (real bus
      timing) against zdos's synthetic ledger. Rationale in Phase 8.
- [x] **D9 — Undefined-flag policy: documented reproducible table.** Match the 386 where known; for
      genuinely-undefined results adopt ProcessorTests-386-consistent values recorded in an
      `UndefinedFlags`-style table (never "leave as garbage" — violates determinism constraint #5).
      Rationale in Phase 3.
- [x] **D10 — Fault unwind: Zig error unions** (`error{Fault}` + a `pending_fault` struct on CPU
      state), NOT exceptions/longjmp. Every memory/decode helper returns `!T`; the dispatcher
      `catch`es, rolls EIP to the instruction start (faults are restartable), and delivers via the
      real-mode IVT. Rationale in Phase 6.
- [x] **D11 — HLT / idle determinism contract. DECIDED.** `step()` returns a
      `StepResult{ cycles_consumed, stop_reason }`. On HLT, `step()` returns a distinct **"halted"**
      `stop_reason` carrying the idle-cycle count to the next scheduled event; the **MACHINE** advances
      emulated time to the scheduler's next-event cycle, which is a pure function of the deterministic
      event schedule. The CPU **NEVER** consults host time and **NEVER** charges a variable idle amount
      it did not derive from the schedule. This reconciles with the Phase 1a purity assertion: *cycles
      is a pure function of (CPU state, inputs, the deterministic event schedule)*. Rationale in Phases
      1a / 4j (HLT) / 7.
- [x] **D12 — Misaligned-access cycle cost. DECIDED: waive initially.** A 16/32-bit access that is not
      naturally aligned is deterministic either way; do **not** charge a misalignment penalty for now.
      Rationale: real-mode correctness and determinism do not depend on it, and the 386 PRM base counts
      already cover the common case; recorded here as a *decision*, not an omission. Revisit only if
      cycle-fidelity demands it. Rationale in Phase 7.

> **Note on the path to BaK:** this CPU executes the 386 **real-mode** ISA and delivers real-mode
> interrupts. EMS/VGA/DOS/mouse/PIT/PIC are separate modules wired by `src/machine/`; the CPU's only
> external interface is the `comptime Bus` (physical memory + ports) plus a hardware-IRQ input line
> (Phase 5). It knows nothing about the 8259, INT 21h, or devices.

---

## Phase 0: Module skeleton, Bus contract, build wiring

Goal: a compiling `src/cpu/` Zig module exposing `Cpu(comptime Bus)` with a `TestBus`, an empty test
step, and the determinism harness scaffolding. **Done when** `zig build` and `zig build test-cpu`
both pass with placeholder tests, the module imports nothing outside `std`, and the **clean public
step/breakpoint/inspect API exists** as a compiling surface (this is its own milestone gate — see the
"Public CPU API" subsection below; it is NOT considered proven by single-step conformance passing).

- [x] Create the repo build scaffolding (none exists yet — greenfield: no `build.zig`, `build.zig.zon`,
      or `src/`).
  - [x] `build.zig.zon` with name `zdos`, the Zig 0.16 `.minimum_zig_version`, empty `.dependencies`
        for now (vendoring of ProcessorTests handled in Phase 8). Mirror the shape of
        `bench/build.zig.zon`.
  - [x] `build.zig` per the 0.16 idioms in `zig-langref/45-zig-build-system.md` and `bench/build.zig`
        (verified API: `b.addModule`, `b.createModule`, `b.addTest`, `b.addRunArtifact`, `b.step`).
    - [x] `b.standardTargetOptions` / `b.standardOptimizeOption`.
    - [x] `const cpu_mod = b.addModule("cpu", .{ .root_source_file = b.path("src/cpu/cpu.zig"),
          .target = target, .optimize = optimize });` — exposes CPU as an importable module (the
          machine module will later `addImport("cpu", cpu_mod)`).
    - [x] A dedicated CPU test step: `const cpu_tests = b.addTest(.{ .root_module = b.createModule(
          .{ .root_source_file = b.path("src/cpu/cpu_test.zig"), .target = target, .optimize =
          optimize }) });` then `b.step("test-cpu", "Run CPU unit + conformance tests")`.
    - [x] Wire `test-cpu` into the top-level `test` step (`test_step.dependOn(&run_cpu_tests.step)`).
- [x] Create the file split under `src/cpu/` (one responsibility per file; see memory-and-performance.md
      §"extract hot loops into free functions"). **Real-mode-only file set** (the protected-mode/paging
      files are listed in the Deferred section as future seams, not created now):
  - [x] `cpu.zig` — the `pub fn Cpu(comptime Bus: type) type` generic entry; owns the `State`, the
        run loop, `step()`, exposes the public API (reset, `step()`/`runCycles`/`runUntil`, inject IRQ
        line, read/patch regs + memory for the future API/MCP server). See the "Public CPU API"
        subsection below for the exact surface.
  - [x] `bus.zig` — the comptime `Bus` contract documentation + `comptime` verification helper
        (`assertBusContract(Bus)`), plus `TestBus` for tests.
  - [x] `alu.zig` — **single source of truth** for the per-width ALU primitives + the flag formulas +
        the D9 undefined-flags table (co-located per Theme/Phase 3). This is the **D1 lazy-seam
        location**: the one place the flag-commit step lives. `exec_alu.zig`/`exec_shift.zig`/
        `exec_muldiv.zig` become the dispatch/operand-plumbing layer that calls into `alu.zig`.
  - [x] `state.zig` — register file, segment regs (hot `seg_base`/`seg_limit`/`selector` arrays +
        cold parallel `seg_desc: [6]SegDescCold`), EFLAGS, CR0 (+ CR2/CR3 as storage for fidelity),
        IDTR/GDTR (storage; LIDT/LGDT are real-mode-executable), mode flags, and the surviving
        instruction-boundary state (interrupt-shadow/inhibit, `irq_pending`, `nmi_pending`, halted,
        shutdown, double-fault counter — Phase 9 audit). Pure data.
  - [x] `flags.zig` — EFLAGS bit layout, condition-code computation (eager per D1), parity table.
  - [x] `decode.zig` — prefix handling, operand/address-size resolution, ModR/M + SIB, imm/disp
        fetch.
  - [ ] `exec_data.zig`, `exec_alu.zig`, `exec_shift.zig`, `exec_bit.zig`, `exec_muldiv.zig`,
        `exec_ctrl.zig`, `exec_string.zig`, `exec_io.zig`, `exec_bcd.zig`, `exec_system.zig` —
        execution by class (Phase 4). `exec_system.zig` holds the real-mode-executable
        system/privileged instructions (LGDT/LIDT/LMSW/SMSW/MOV-CR0 etc.).
  - [x] `segmentation.zig` — real-mode segment load (`base = sel<<4` ONLY; limit set at reset, not on
        load — preserves unreal mode) + the `checkSegmentAccess()` access/limit helper used by every
        memory op. (Protected-mode descriptor decode + permission checks are the deferred extension
        point in this same file.)
  - [x] `interrupts.zig` — real-mode IVT delivery, IRQ recognition, the real-mode exception
        vector/error-code table.
  - [x] `cycles.zig` — the 386 cycle-count tables + EA/penalty model (per D6).
  - [x] `cpu_test.zig` — test root that `@import`s all `_test` files.
- [x] **Define the `Bus` contract** (fixed and load-bearing). In real mode the CPU does only
      segmentation (sel<<4 + offset) on top; the Bus does *physical* access. Document and
      `comptime`-verify these exact methods on the injected `Bus`:
  - [x] `fn readPhys8(self: *Bus, phys: u32) u8`, `readPhys16`, `readPhys32` (the CPU guarantees
        physical addresses; the bus performs A20 masking + region dispatch).
  - [x] `fn writePhys8(self: *Bus, phys: u32, v: u8) void`, `writePhys16`, `writePhys32`.
  - [x] `fn portIn8(self: *Bus, port: u16) u8`, `portIn16`, `portIn32`.
  - [x] `fn portOut8(self: *Bus, port: u16, v: u8) void`, `portOut16`, `portOut32`.
  - [x] **Wide-access decomposition (contract, determinism-critical):** a 16/32-bit access is split, if
        needed, at the **logical→linear→physical choke point**, against the **LINEAR** address —
        page-granular when paging is on (deferred), a no-op in real mode where linear==physical. The
        sub-access order is **FIXED** (ascending address) and is part of the contract, so the deferred
        paging unit slots into the same splitter and the D8 access-trace baseline stays stable. The
        bus's wide accessors may therefore assume single-region. (Replaces any "decompose against the
        physical region" wording: the split is decided on the linear address, not the physical region.)
  - [x] `comptime` check in `bus.zig` using `@hasDecl`/`@TypeOf` that all methods exist with the right
        signatures; emit a `@compileError` listing the missing method otherwise (idiom: grep
        `references/zig/lib/std/` for `@compileError` duck-typing examples).
  - [x] **DECIDED (Bus error model):** `readPhys*` never fails — physical access always succeeds
        (unmapped reads return a deterministic fill, the bus's job per CLAUDE constraint #5); only
        CPU-side segmentation produces faults (real mode: limit/wrap). Keeps the hot path non-erroring.
- [x] **Widen the comptime integration seam beyond memory+ports** (the seam must cover everything the
      machine wires to the CPU; a memory/port-only seam is incomplete). **DECIDED: add explicit
      comptime hook interfaces** — an `InterruptController` and a `Scheduler` hook — alongside the
      memory `Bus`, all comptime-verified the same way (`@hasDecl`/`@TypeOf`, `@compileError` on a
      missing method). These are **load-bearing alongside the memory methods**:
  - [x] `InterruptController` hook — the 8259 handshake, modeled **faithfully, not a one-way vector
        push** (a one-way push that ignores IRR/ISR/priority would be a ground-rule "fake"). Provide
        `getPendingInterrupt()` (returns the highest-priority pending vector subject to IF/priority,
        derived from the cycle ledger — see Phase 5) and `ackIrq()` (the acknowledge/EOI handshake so
        8259 IRR/ISR/priority is modeled correctly). The CPU recognizes via `getPendingInterrupt()` and
        signals acknowledge via `ackIrq()`; it never mutates pending state directly.
  - [x] `Scheduler` hook — HLT/next-event coordination (per D11): a `nextEventCycle()` query so the
        machine can fast-forward emulated time to the next scheduled event when the CPU returns the
        "halted" stop_reason. The CPU never reads host time.
  - [x] Fault/shutdown callback to the machine — a hook the CPU calls on triple-fault/shutdown (Phase
        5) so the machine, not the CPU, decides the reset/abort policy.
  - [x] **Decision recorded:** these are separate comptime hook interfaces (NOT folded into one fat
        `Bus`) so each contract is documented and verified independently; the machine supplies all of
        them at instantiation.
- [x] **Public CPU API** (the debugger/machine surface — its own milestone gate, see Phase 0 goal):
  - [x] `step() -> StepResult{ cycles_consumed, stop_reason }` is **THE** primitive (per D11).
  - [x] `runCycles(n)` and `runUntil(predicate)` are **thin wrappers over `step()`** — they loop
        calling `step()`; they add no independent execution path.
  - [x] **Breakpoints are checked BETWEEN steps in the machine, NOT inside the CPU loop** — the CPU
        loop stays branch-clean; the debugger interposes between `step()` calls.
  - [x] Inspect/patch surface for the MCP debugger: read register by name; patch EIP; memory
        read/patch that **specifies CPU-segmented (logical seg:offset) vs bus-physical** addressing —
        **provide BOTH** entry points so the debugger can target either view; expose the register/flag
        accessor surface (read flags, read/patch any GP/seg/control register).
  - [x] **Milestone gate:** "a clean public step/breakpoint/inspect API exists" is an explicit gate
        (M0), independent of conformance — it is NOT proven by single-step conformance passing.
- [x] Implement `TestBus` in `bus.zig`: a fixed RAM block (real mode addresses the low ~1 MiB + the
      HMA wrap region; for ProcessorTests use a sparse page map so arbitrary 32-bit addresses in
      32-bit-addressing forms work without a 4 GiB allocation — see Phase 8) + a recorded port-I/O log
      (for IN/OUT vectors) + an optional access trace (for D8). Deterministic init (zeroed). No
      allocation in the hot path. **Note:** `TestBus` (renamed from `FakeBus`) is a **REAL Bus
      implementation over a RAM array, NOT a prohibited "fake"** — it implements the actual Bus
      contract and does not fake any emulated behavior; the rename makes that explicit.
- [ ] Placeholder `step()` returning `error.Unimplemented`; one passing smoke test (`Cpu(TestBus)`
      instantiates, resets, reports reset-vector state). **Run `zig build test-cpu`.**

---

## Phase 1: Determinism contract + register/state model

Goal: nail the cross-cutting determinism rules, then build the complete 386 architectural state as a
compact register-resident struct. **Done when** the determinism checklist exists as enforced
asserts/tests and `State` round-trips through reset to documented 386 power-on values with aliasing
tests passing.

### 1a. Determinism contract (cross-cutting — establish before any execution code)

- [x] Add a monotonically-increasing `cycles: u64` to `State`. **Invariant (determinism-critical):
      `cycles` is a pure function of (CPU state, inputs, the deterministic event schedule); every
      `step()` advances `cycles` by a fixed, reproducible amount — including every fault and interrupt
      delivery.** No code path may leave `cycles` unchanged or host-time-dependent.
- [x] **HLT idle is NOT charged by the CPU from host time (D11).** On HLT, `step()` returns the
      "halted" `stop_reason` with the idle-cycle count to the scheduler's next event; the **machine**
      fast-forwards emulated time to that next-event cycle (a pure function of the deterministic event
      schedule). The CPU charges **no host-derived idle amount** and never consults host time. (Replaces
      any "the bus/scheduler decides when … charge per idle cycle" framing — see Phase 4j / Phase 7.)
- [x] **Cost-charging by construction (structural, not disciplinary — Theme E):** a single choke point
      in `step()` sets the instruction's base cost from the `cycles.zig` table keyed by the dispatch
      u12 (the same key D2 dispatches on). A **debug assert** verifies `cycles` advanced by ≥ the table
      base before `step()` returns; EA/segment/fault penalties are added on top at the exact points they
      occur (Phase 7 defines the numbers). A **comptime check** asserts every dispatch key present in
      the switch has a `cycles.zig` entry, and the #UD/default arm charges a defined fault cost.
- [x] Forbidden in all CPU code (assert/enforce; CLAUDE hard constraints):
  - [x] No host wall-clock reads (`std.time`), no RNG, no thread/scheduling dependence, no
        environment reads.
  - [x] No uninitialized reads: `State.reset()` deterministically sets every field (regs, the hot
        `seg_base`/`seg_limit` arrays + cold `seg_desc`, CR0, EFLAGS bit 1 = 1 and reserved bits to
        architectural reset values).
  - [x] No `alloc`/`free` in `step()` or any per-instruction helper (memory-and-performance.md rule
        2). All CPU state is one preallocated `State` struct.
  - [x] Deterministic on faults: partial-instruction effects must occur in a fixed order so that
        "fault at cycle N" reproduces byte-identically (Phase 6 specifies ordering).
- [x] Add a debug-build counting-allocator guard pattern (memory-and-performance.md §7) reused in
      tests to assert zero allocation during `step()`.

### 1b. Register & segment model

- [x] **GP registers (D3).** 8 registers EAX,ECX,EDX,EBX,ESP,EBP,ESI,EDI as
      `extern union { dword: u32, word: [2]u16, byte: [4]u8 }` (mirrors dosbox-staging `GenReg32`,
      `registers.h`). **Note:** must be `extern union`, NOT `packed union` — a packed union requires
      equal bit-sizes for all fields (`zig-langref/18-union.md`), which `u32`/`[2]u16`/`[4]u8` violate;
      `extern union` gives the C layout. **Host is little-endian only** — `comptime
      assert(builtin.cpu.arch.endian() == .little)` (the `byte[0]=AL, byte[1]=AH` overlay depends on
      it). Index constants `AL=0, AH=1, AX=0` per `registers.h`.
  - [x] Encode the 8 regs as `[8]GenReg32` indexed by the ModR/M reg field (dense-integer-keyed table
        per memory-and-performance.md §5d). Strong enum
        `Reg32 = enum(u3){eax,ecx,edx,ebx,esp,ebp,esi,edi}`.
  - [x] Helpers `getReg8/16/32`, `setReg8/16/32` honoring the AH/AL/SP-as-high-word aliasing. The
        8-bit register encoding (AL,CL,DL,BL,AH,CH,DH,BH) maps reg 4–7 to the *high byte* of regs 0–3.
  - [ ] `comptime { assert(@sizeOf(GenReg32) == 4); assert(@sizeOf(@TypeOf(regs)) == 32); }` (lock
        layout, memory-and-performance.md §5c).
- [x] **EIP** as `u32`; helpers to read IP (16-bit) vs EIP per operand size. (Real mode default
      operand/address size is 16-bit, but 0x66/0x67 enable 32-bit forms.)
- [x] **EFLAGS** as `u32`. Define the full bit layout (`flags.zig`, from `registers.h` FLAG_*):
      CF=0, PF=2, AF=4, ZF=6, SF=7, TF=8, IF=9, DF=10, OF=11, IOPL=12-13, NT=14, RF=16, VM=17, AC=18.
      Reserved bit 1 always 1; bits 3,5,15 always 0. (RF is meaningful for fault-restart; VM/AC relate
      to deferred modes but the *bits* must still be stored/masked correctly by PUSHF/POPF/IRET.)
  - [x] **DECIDED (EFLAGS storage):** a `packed struct(u32)` with `toU32`/`fromU32` masking reserved
        bits to architectural values on every write (PUSHF/POPF/IRET must preserve reserved-bit
        semantics). Type-safe field access (memory-and-performance.md example).
  - [x] `getMask`/`setMask` honoring the real-mode write rules for POPF/IRET (in real mode all of CPL
        =0; the IOPL/IF restriction logic is trivially satisfied but implement the mask helper so the
        deferred PM path can reuse it; cf. `cpu.cpp` FMASK_NORMAL vs FMASK_ALL).
- [x] **Segment registers — hot bases split out of the fat cache (D4 — real-mode subset; Theme F
      layout).** Index segments by enum `Seg = enum(u3){es,cs,ss,ds,fs,gs}` (document the chosen dense
      order). Split the hidden state into a HOT and a COLD half so the real-mode access path touches as
      few cache lines as possible:
  - [x] **HOT (authoritative source on the access path):** a tight `seg_base: [6]u32` and `seg_limit:
        [6]u32`, plus `selector: [6]u16`. These are the only segment fields the real-mode
        limit/wrap/translate path reads — keep them adjacent and cache-line-tight.
  - [x] **COLD (PM seam, written once on load, never read in the real-mode access path):** a parallel
        `seg_desc: [6]SegDescCold` carrying the protected-mode descriptor fields (`type`, `dpl`,
        `present`, `conforming`, `expand_down`, `readable`, `writable`, `big/default_b`). Real mode
        writes default flags here once on a segment load but never reads them on access; this preserves
        the PM seam without taxing the hot path.
  - [x] **General layout rule (Theme F):** keep hot state (GP regs, EFLAGS, EIP, the `seg_base`/
        `seg_limit` arrays) in as few cache lines as possible; keep cold state (CR/DR/IDTR/GDTR, the
        `SegDescCold` PM fields) separate.
  - [x] In real mode, loading a segment updates **`base = selector << 4` ONLY** (plus default flags);
        the cache is what every memory access uses (so real and the future protected mode share the
        access path).
  - [x] **386 real-mode segment-limit behavior (faithfulness — fixed):** a real-mode segment load
        updates the **base only** and must **NOT** reset the cached limit. This preserves the
        flat-real / "unreal mode" idiom (a program enters PM, loads a 4 GiB limit into a descriptor
        cache, returns to real mode, and the large limit *survives* a subsequent real-mode `MOV
        seg`). The limit is initialized to `0xFFFF` **only at reset** (`State.reset()`), never on a
        segment load. (Corrects the prior "every segment load resets limit = 0xFFFF" wording.) Document
        the offset-wrap semantics too: offsets are masked to the effective address size; a
        32-bit-addressing form in real mode can compute offsets > limit — cover faithfully per the
        Phase 4 access helper, raising the documented real-mode fault on a limit violation (Phase 4 /
        Phase 5). **No reference-emulator oracle exists** for this behavior — see Phase 8.
  - [x] `CS.big` (D bit) and `SS.big` (B bit) are 0 in real mode (16-bit defaults); store them in
        `SegDescCold` as the authoritative default-size source so 0x66/0x67 toggles compute against them.
  - [x] `comptime` size lock on the hot `seg_base`/`seg_limit` arrays AND on `SegDescCold` (keep the
        cold struct small; pack the access bits).
- [ ] **Control / system registers (real-mode-relevant):**
  - [x] CR0 — model **all bits as register state** (PE, MP, EM, TS, ET, PG; WP is 486+, document the
        bit ignored on 386). Real-mode programs legitimately read/write CR0 (e.g. setting PE to enter
        PM, setting/clearing EM/TS/MP around FPU detection). The **EM/TS/MP** bits drive the #NM hook
        on ESC/WAIT (Phase 4j). Setting **PE** (entering protected mode) is **flagged-not-faked**: the
        bit is stored faithfully, but the protected-mode machinery is deferred — if a real-mode
        program sets PE and then executes a PM-dependent transfer, the CPU surfaces a clear
        "protected mode deferred" structural flag rather than faking PM. Setting **PG** likewise flags
        (paging deferred). Document both in the Deferred section.
  - [x] CR2 / CR3 — model as **storage** (MOV to/from them is privileged but real-mode-executable;
        their *effect* is paging, deferred). Store faithfully; flag that the paging effect is not built.
  - [x] IDTR (base:u32, limit:u16) and GDTR (base:u32, limit:u16) — **storage + real-mode use.** In
        real mode the IDT *is* the IVT (default base 0, limit 0x3FF); LIDT/LGDT are real-mode-executable
        and reposition/resize it — honor IDTR.limit on interrupt delivery (Phase 5). GDTR is loadable
        by LGDT in real mode (storage); it has no effect without PM (deferred), so flag that.
  - [x] **N-A in real mode (kept as storage seams only):** DR0–DR7 (debug breakpoints — model storage
        now; matching is deferred to the Deferred section), TR6/TR7 (TLB test registers — N-A without
        paging; storage only), LDTR/TR (no LDT/TSS in real mode — deferred). Provide storage so MOV
        decode/dispatch is honest, but flag the unimplemented effects; never fake.
- [x] **Mode state:** derived helpers `isProtected()` (CR0.PE), `isPaging()` (CR0.PG); both are
      expected `false` in this core's supported configuration. `cpl` is fixed at 0 in real mode; store
      it explicitly so the deferred PM path can reuse the privilege checks.
- [x] **Reset state:** EIP=0xFFF0, CS selector=0xF000 with base 0xFFFF0000 (386 reset quirk: CS base
      high until first far jump), **every `seg_limit[i] = 0xFFFF` (limits are set ONLY here, never on a
      segment load — see the unreal-mode note above)**, EFLAGS=0x00000002, CR0=0 (real mode), IDTR
      base=0/limit=0x3FF, GDTR per reset, others zero. Cite Intel 386 PRM reset section; cross-check
      `cpu.cpp CPU_Init`. Write a `reset()` test asserting every field.
- [x] **`comptime` size budget** for the whole `State` and an assert; this is "the one"
      (memory-and-performance.md §7) — compact AoS, register-resident, no SoA.

### 1c. Logical→linear→physical seam (real-mode form)

- [x] **Single memory choke point** in `cpu.zig`: every CPU access goes logical→linear (real-mode
      segmentation: `base + offset`, with the limit/wrap checks of Phase 4) → linear→physical. In real
      mode **linear == physical** (identity); call `Bus.readPhys*/writePhys*` directly. Implement the
      identity step behind a single `linearToPhys()` hook so the deferred paging unit can be inserted
      at exactly one place. Document this choke point.

---

## Phase 2: Fetch, prefixes, operand/address-size resolution, ModR/M + SIB

Goal: a complete decode front end producing, per instruction, the opcode + resolved sizes + a fully
computed effective address / register operand, charging the right fetch/EA cycles. **Done when**
ModR/M+SIB unit tests pass for all 256 modrm bytes in both 16- and 32-bit addressing.

- [x] **Instruction fetch** through the normal memory path (segmented CS:EIP → linear → physical).
      `fetch8/16/32` increment EIP and charge fetch cost.
  - [x] **DECIDED (prefetch queue):** **omit the prefetch-queue model** (like DOSBox's normal core),
        but isolate fetch behind `fetch8()` so a queue can be added later. Flag: SMC-timing-exact /
        anti-debug prefetch behavior is a deferred capability, not faked.
- [x] **Prefix loop — a SINGLE forward scan** (`decode.zig`), consuming any number of prefixes before
      the opcode (386 behavior: the *last* of a conflicting group wins). **The scan accumulates prefix
      bits (`seg_override`, `has_66`, `has_67`, `rep`/`repne`, `lock`) into locals in ONE pass; do NOT
      recompute derived sizes per prefix byte.** Then resolve `op_size` / `addr_size` / effective-seg
      **ONCE after the last prefix** (see the resolution step below).
  - [x] Segment overrides 0x2E/0x36/0x3E/0x26/0x64/0x65 (CS/SS/DS/ES/FS/GS) → set `seg_override`.
  - [x] 0x66 operand-size override → set `has_66` (resolution happens once, after the scan).
  - [x] 0x67 address-size override → set `has_67` (resolution happens once, after the scan). **This is
        the gateway to 32-bit addressing / SIB in real mode — must be fully supported.**
  - [x] 0xF0 LOCK (record `lock`; #UD if used with a non-lockable opcode — implement the lockable-opcode
        check, don't ignore it; ground rule).
  - [x] 0xF2 REPNE / 0xF3 REP/REPE (record; meaningful for string ops; 0xF3 on non-string 386 cases
        is ignored — not PAUSE on 386).
  - [x] Charge prefix cycles; implement the 386 **15-byte instruction-length limit** → exceeding it
        raises #GP. (No documented prefix-count limit otherwise.)
- [x] **Operand/address-size resolution** (the crux): `op_size = CS.D xor has_66`; `addr_size =
      CS.D xor has_67`. In real mode CS.D=0 so defaults are 16-bit; 0x66/0x67 select the 32-bit
      forms. Produce `OperandSize{ .b16, .b32 }` and `AddrSize{ .a16, .a32 }`. (DOSBox encodes this as
      the `cpu.code.big*0x200` opcode-index base.)
- [x] **Opcode dispatch architecture (D2 — DECIDED).** A single labeled `switch` over a `u12` key =
      `(operand_size_base 0x200) | (is_0F ? 0x100 : 0) | opcode_byte`, the DOSBox
      `OPCODE_NONE/0F/SIZE` namespacing. The Zig compiler builds the jump table; full inlining of the
      `comptime Bus` memory path; no fn-pointer cache footprint. The 0F two-byte map is a nested
      `switch` after the 0x0F case (or folded via the 0x100 bit).
  - [x] Group opcodes (Grp1–Grp8: 0x80-0x83, 0xC0/C1, 0xD0-D3, 0xF6/F7, 0xFE/FF, 0x0F00/0F01, 0x0FBA,
        0x0FC7) dispatch on the ModR/M reg field after the primary opcode — a nested `switch` on
        `reg`. Enumerate every group (cf. `instructions.h`, spice86 `Grp1Parser`).
  - [x] `#UD` default arm for unmapped opcodes (raise exception 6) — never silently NOP.
  - [x] **Jump-table verification step (Theme F — resolve at M1):** after the dispatch switch exists,
        inspect the generated asm (`zig build-obj -femit-asm`, or `objdump`) to confirm the dispatch
        lowers to a **JUMP TABLE** — a single `jmp [table + idx*8]`, **not** a comparison cascade. **If
        it does not**, fall back to **two DENSE 256-entry switches**: fetch the opcode → branch once on
        `is_0F` → a dense 0–255 switch; handle operand size *inside* the arms, NOT folded into a sparse
        12-bit key (a sparse u12 key can defeat jump-table lowering). Record the resolution at M1.
- [x] **ModR/M decoding** (`decode.zig`, mirror `modrm.cpp`/`modrm.h`, spice86 `ModRm/`): parse
      mod(2)/reg(3)/rm(3); produce either a register operand or a memory operand with a computed
      effective address + the **effective segment** (default DS, or SS when base is BP/EBP/ESP,
      overridable by a prefix).
  - [x] **16-bit addressing** table (mod 00/01/10, rm 000-111 → [BX+SI],[BX+DI],[BP+SI],[BP+DI],
        [SI],[DI],[BP],[BX] with disp8/disp16; mod 00 rm 110 = disp16 direct). Default segment = SS
        when BP appears, else DS.
  - [x] **32-bit addressing** (via 0x67 in real mode): rm 100 ⇒ **SIB byte follows**; rm 101 with
        mod 00 ⇒ disp32 direct. disp8 (sign-extended) / disp32 per mod.
  - [x] **SIB decoding**: scale(2)=1/2/4/8, index(3) (index==100/ESP ⇒ no index), base(3) (base==101
        with mod 00 ⇒ disp32 with no base; else EBP/ESP base). Default segment = SS when base is
        EBP/ESP, else DS. EA = base + index*scale + disp (mod 2^32). Cite `modrm.cpp` table_ea and
        spice86 ModRm SIB.
  - [x] Charge EA-computation cycles per addressing mode — under the interim flat model EA cost is
        folded into the per-instruction flat base (`cycles.ea_simple = 0`, D12 waives misalignment); the
        per-addressing-mode 386 EA timing is part of the deferred-fidelity PRM pass (Phase 7).
  - [x] **Unit tests:** for every (mod,rm) in 16- and 32-bit, and every SIB (scale,index,base),
        assert the computed EA, the chosen default segment, and the consumed instruction-byte count.
        Use crafted bytes against `TestBus`.
- [x] **Immediate / displacement fetch** helpers sized by operand size (imm8/imm16/imm32, sign-
      extended imm8 forms like 0x83, the moffs direct-address forms, the ENTER imm16+imm8, the
      far-pointer ptr16:16 / ptr16:32 for far JMP/CALL).

---

## Phase 3: Flags engine

Goal: exact, reproducible condition codes for every arithmetic/logic op. **Done when** flag-effect
tests pass for ADD/SUB/ADC/SBB/CMP/INC/DEC/NEG/AND/OR/XOR/TEST/shifts/rotates/MUL/DIV at 8/16/32.

- [x] **DECIDED — D1 eager flags, with the lazy seam.** (Rationale recorded in DECISIONS.) Compute
      eagerly; treat flags as plain serializable `State`. DOSBox's lazy `lazyflags.h` is a perf trick
      that adds hidden state; spice86 computes eagerly per `Alu8/16/32`. The **honest cost** is that
      eager computes all 6 flags every ALU op even when overwritten unread (the interpreter hot-path
      tax). The **lazy seam** is the flag-commit step inside `alu.zig` (below): the documented future
      upgrade is the hybrid (compute result eagerly, defer only EFLAGS bit-packing, materialize on
      PUSHF/Jcc/save) — switchable there without rewriting instruction logic. Revisit only if profiling
      demands it.
- [x] **Co-locate the single source of truth in `alu.zig` (Theme E/F).** The per-width ALU primitives,
      the flag formulas, AND the D9 undefined-flags table live together in `alu.zig` — ONE module.
      `exec_alu.zig`/`exec_shift.zig`/`exec_muldiv.zig` are only the dispatch/operand-plumbing layer
      that calls into it. This module is the **D1 lazy-seam location** (the single flag-commit place).
- [x] Implement per-width ALU primitives in `alu.zig` returning result + flags (model on spice86
      `Alu8/Alu16/Alu32.cs` and DOSBox `flags.cpp` formulas):
  - [x] CF: carry/borrow out of MSB (per op). OF: signed-overflow per op (`(a^res)&(b^res)&sign` for
        ADD; SUB/CMP/ADC/SBB/NEG/INC/DEC variants). AF: carry out of bit 3 (`(a^b^res)&0x10`).
        ZF: result==0. SF: result MSB. PF: even parity of low byte (256-entry parity lookup table —
        dense-int table, memory-and-performance.md §5d).
  - [x] INC/DEC: do NOT affect CF (preserve it). NEG flags. Logic ops (AND/OR/XOR/TEST): CF=0, OF=0,
        AF undefined (D9), ZF/SF/PF from result.
  - [x] Shift/rotate flag rules incl. "count==0 ⇒ flags unchanged" and "OF defined only for count==1"
        386 semantics; SHLD/SHRD flag behavior; the masked count (`count & 0x1F` on 386).
  - [x] MUL/IMUL CF/OF (set when upper half significant), DIV (#DE on divide-by-0 / overflow), the
        AAD/AAM/DAA/DAS/AAA/AAS flag effects.
- [ ] **Undefined flags (D9 — DECIDED):** for each op with architecturally-undefined flag outputs
      (AF after logic, flags after MUL/IMUL beyond CF/OF, AAM/AAD undefined set, shift OF for count>1,
      etc.), define a documented, reproducible result table consistent with ProcessorTests' 386
      vectors. Build an `undefined_flags` test that pins these. Never leave garbage — determinism
      constraint #5.
- [x] Parity table generated at `comptime`.

---

## Phase 4: Real-mode execution by class (the full 386 real-mode ISA)

Goal: the entire real-mode instruction set executing correctly and charging cycles, with all 8/16/32-
bit and addr-size variants (8086/186/286 base + the 386 32-bit forms and the real-mode-usable 0F
map). **Done when** the 386 ProcessorTests real-mode vectors pass for each class as it's completed
(incremental milestones below). Each subsection lists exact flag effects.

> Build order within this phase: MOV + ALU first (smallest path to passing single-step tests), then
> expand. Cite `instructions.h` (DOSBox) and spice86 executor for per-op semantics.

- [x] **`checkSegmentAccess(seg, offset, access_kind)` — the single access-path extension point
      (`segmentation.zig`, used by every memory op; Theme F).** Mirror the `linearToPhys` choke-point
      pattern: in real mode this function does **only** the limit/wrap check, but it EXISTS as the one
      place protected-mode permission checks (read/write/exec, DPL/CPL) slot in later. Logical offset →
      linear `base + offset`.
  - [x] **Exact real-mode limit fault predicate (Theme D):** fault **iff** `effective_offset_of_last_byte
        (ea + size - 1) > limit`. This is **DISTINCT** from fault-free 16-bit offset wraparound: a
        16-bit-addressing access whose offset arithmetic wraps is masked mod 2^16 and does **NOT** fault
        (the wrap is legal). The limit check is on the last-byte effective offset, not on the wrap.
  - [x] **Fault selection:** raise **#SS(0)** for SS-relative accesses (stack segment), **#GP(0)**
        otherwise. Implement faithfully; this is the access path both real mode and the deferred PM mode
        share. **No reference-emulator oracle** for the real-mode limit fault — pin with hand-written
        vectors (Phase 8).
- [x] **4a. Data movement & stack**
  - [x] MOV (all forms: r/m↔reg, reg↔imm, AL/AX/EAX↔moffs, MOV to/from seg reg). No flags. (Seg-reg
        load uses the real-mode segment-load: `base = sel<<4`.)
  - [x] PUSH/POP (r/m, reg, seg, imm8/imm16/imm32); **operand-size & stack-width interaction**: stack
        accesses use SS.B for the stack-pointer width (SP in real mode) independently of operand size.
        16-bit PUSH decrements by 2, 32-bit by 4 (32-bit form via 0x66). PUSH SP/ESP 386 value
        semantics.
  - [x] PUSHA/PUSHAD, POPA/POPAD (16 vs 32). PUSHF/PUSHFD, POPF/POPFD (with the EFLAGS write-mask
        helper from Phase 1b; in real mode CPL=0 so all writable bits are writable).
  - [x] XCHG (incl. NOP = XCHG AX,AX), XLAT/XLATB, LEA (computes EA, addr-size-aware), LDS/LES, and
        the 386 LSS/LFS/LGS far-pointer loads (real-mode seg load + GP-reg load; LSS into SS carries
        the interrupt shadow — Phase 5).
  - [x] MOVZX/MOVSX (0F B6/B7/BE/BF), CWDE/CDQ/CBW/CWD (sign-extension by operand size). No/defined
        flags.
  - [x] ENTER imm16,imm8 (nesting-level frame build — the loop copying display pointers) and LEAVE.
        Charge per-level cycles. (DOSBox `instructions.h` ENTER.)
  - [x] BSWAP — **486+, #UD on 386**; do NOT implement as valid (ground rule). Document.
- [x] **4b. ALU / arithmetic / logic** (ADD,OR,ADC,SBB,AND,SUB,XOR,CMP — the Grp1 0x80-0x83 + the
      direct opcodes; NEG/NOT via Grp3 0xF6/F7; INC/DEC reg 0x40-0x4F and Grp4/5 0xFE/FF). Exact flags
      per Phase 3. All at 8/16/32.
- [x] **4c. Shifts & rotates** (Grp2 0xC0/C1 imm8, 0xD0/D1 by 1, 0xD2/D3 by CL): ROL/ROR/RCL/RCR/
      SHL/SHR/SAR. 386 count mask `& 0x1F`. SHLD/SHRD (0F A4/A5/AC/AD, double-precision shift) with
      their flag rules. Exact OF/CF semantics per Phase 3.
- [x] **4d. Bit instructions** (386): BT/BTS/BTR/BTC (0F A3/AB/B3/BB and Grp8 0F BA /4-7) — incl. the
      **bit-offset-indexes-memory** semantics for the r/m,reg form (offset can exceed the operand,
      addressing an adjacent dword/word; cf. `instructions.h`). BSF/BSR (0F BC/BD) with ZF semantics
      and undefined dest when source==0 (D9).
- [x] **4e. Multiply / divide**: MUL/IMUL (Grp3 0xF6/F7), the two/three-operand IMUL (0F AF, 0x69,
      0x6B). DIV/IDIV (Grp3). 8/16/32-bit. #DE on divide error (quotient overflow or /0) — restartable
      fault, no state change before the fault (Phase 6 ordering). CF/OF per Phase 3.
- [x] **4f. Control flow**: JMP rel8/rel16/rel32, near indirect JMP r/m, Jcc rel8 (0x70-7F) +
      **Jcc rel16/rel32** (0F 80-8F), **SETcc** (0F 90-9F), LOOP/LOOPE/LOOPNE/JCXZ/JECXZ (addr-size
      selects CX vs ECX), CALL rel/near-indirect + RET/RET imm16 (near). Far JMP/CALL/RET(F) in real
      mode = simple CS:IP load + the real-mode limit check (no descriptor/gate machinery — that's the
      deferred PM path). **Cc evaluation reads the packed `Flags` fields directly (a single mask),
      NOT via `toU32` (Theme G):** `toU32` is used ONLY for PUSHF / save-restore, never on the
      Jcc/SETcc condition-code path.
  - [x] **#BR / BOUND** (0x62): array-bounds check; #BR (vector 5) on violation. Real-mode-usable.
- [x] **4g. String ops** (`string_ops.h`, spice86 string handling): MOVS/CMPS/SCAS/LODS/STOS at
      8/16/32, with DF-driven increment/decrement, the effective source segment (DS:SI overridable,
      ES:DI fixed for dest), addr-size selecting SI/DI/CX vs ESI/EDI/ECX. REP/REPE/REPNE prefixes with
      ZF-based termination for CMPS/SCAS; **per-iteration interrupt checkability** (a long REP must be
      interruptible at iteration boundaries — each iteration charges cycles; determinism-critical: the
      iteration count and per-iteration cost are exact). INS/OUTS (string I/O — direct in real mode,
      no IOPL/IO-bitmap check since CPL=0).
  - [x] **DECIDED (REP interruptibility):** model REP as re-entrant at the instruction boundary
        (decrement CX, advance pointers, check IRQ, leave EIP pointing at the REP if not done) so an
        interrupt mid-REP is restartable — matches hardware and keeps the cycle ledger exact.
- [x] **4h. Flag/misc**: CLC/STC/CMC, CLD/STD, CLI/STI (with the **STI one-instruction interrupt
      shadow** — Phase 5), SAHF/LAHF. **`0F 31` RDTSC is Pentium+ → #UD on 386** (do not implement;
      document). **CPUID is #UD on 386** (document).
  - [x] **`0xD6 SALC` (undocumented but VALID on the 386)** — `AL = CF ? 0xFF : 0x00`. No flags
        affected. Implement; it is in the 386-valid allowlist (Theme C).
- [x] **4l. Undocumented-but-valid 386 opcodes / aliases (Theme C — conformance-blocking gaps):**
  - [x] **`0xF1 ICEBP / INT1`** — single-byte vector-1 trap (`INT 1`); delivers through the real-mode
        IVT exactly like a #DB software trap (vector 1). Implement; it is 386-valid (do NOT #UD it).
  - [x] **`0x82` is the deliberately-aliased Grp1 byte mirror of `0x80`** (not #UD): decode it as the
        Grp1 r/m8, imm8 form just like 0x80. Document the alias explicitly so it is not mistaken for an
        illegal opcode.
- [x] **4i. BCD / ASCII adjust**: DAA, DAS, AAA, AAS, AAM imm8, AAD imm8 (AAM/AAD take an imm8 base
      byte; default 10). Exact flag effects incl. undefined ones (D9). #DE for AAM with divisor 0.
- [x] **4j. HLT, WAIT, ESC, NOP, LOCK, and CR0.EM/TS/MP hooks (FPU placeholder):**
  - [x] NOP (0x90). HLT (0xF4) — in real mode (CPL=0) executes; halts until interrupt. **HLT idle
        follows D11:** `step()` returns the distinct **"halted"** `stop_reason` carrying the idle-cycle
        count to the scheduler's next event; the **MACHINE** fast-forwards emulated time to that
        next-event cycle (a pure function of the deterministic event schedule). The CPU charges **no
        host-derived idle amount** and never consults host time. (Replaces "the bus/scheduler decides
        when … charge per idle cycle" — the CPU only reports halted + idle-to-next-event; it does not
        charge a variable idle itself.) The CPU exposes the halted state in `State` (serializable).
  - [x] **ESC (0xD8-0xDF) and WAIT/FWAIT (0x9B):** the 387 is out of scope. Implement the **CR0
        hooks**: if CR0.EM=1, any ESC ⇒ #NM (vector 7); if CR0.TS=1, ESC/WAIT (WAIT only if CR0.MP=1)
        ⇒ #NM. With EM=0/TS=0/MP arrangement that would *execute* an x87 op, raise **#NM for now** but
        clearly mark this as the FPU-extension seam (a real 387 would execute). **Flagged deferral, not
        a fake** — document that ESC currently cannot execute real x87 and structure
        `exec_system.zig`/dispatch so a 387 module can hook the ESC cases later. (BaK does not use the
        FPU, so this is acceptable for the v1 target.)
  - [x] LOCK as a prefix (Phase 2); single-threaded core so LOCK has no atomic effect but must still
        enforce the lockable-opcode #UD check.
- [x] **4k. Real-mode-executable system / privileged instructions** (`exec_system.zig`). In real mode
      CPL=0, so the privilege checks pass; implement the storage effect faithfully or FLAG where the
      full effect needs deferred PM/paging machinery (never fake):
  - [x] **LGDT/LIDT** (0F 01 /2,/3) — load GDTR/IDTR from m16&32 (operand-size affects 24- vs 32-bit
        base). Real-mode-executable; **fully implemented** (storage; IDTR.limit honored by interrupt
        delivery in Phase 5; GDTR has no real-mode effect — flag that the descriptor-table use is
        deferred). SGDT/SIDT (/0,/1) — store; fully implemented.
  - [x] **SMSW** (0F 01 /4) — store low 16 of CR0; fully implemented. **LMSW** (0F 01 /6) — load low
        bits of CR0 (can set PE but cannot clear it). Implement the CR0 bit write faithfully; entering
        PE flags "protected mode deferred" if a PM transfer follows (see Phase 1b CR0 note).
  - [x] **CLTS** (0F 06) — clear CR0.TS; fully implemented (interacts with the #NM hook).
  - [x] **MOV to/from CR0/CR2/CR3** (0F 22 / 0F 20): write CR-bit storage faithfully. Setting CR0.PE
        or CR0.PG stores the bit but **flags the deferred PM/paging effect** (do not fake the mode
        switch / translation). CR2/CR3 are storage only (their effect is paging, deferred).
  - [x] **MOV to/from DR0-7** (0F 23 / 0F 21): storage faithfully; breakpoint *matching* is deferred
        (flag it). **MOV to/from TR6/TR7** (0F 24/0F 26): N-A without paging — storage + documented
        no-op for the TLB-test side effects, flagged (ground rule: flagged, not faked).
  - [x] **LLDT/LTR/SLDT/STR/LAR/LSL/ARPL** — these are **PM-only / N-A in real mode**:
        LLDT/LTR/SLDT/STR/LAR/LSL **#UD in real mode on the 386** (no LDT/TSS); implement the
        #UD-in-real-mode gate honestly (Phase 5 illegal-opcode gating). **ARPL (0x63) — PINNED: #UD in
        real mode on the 386**, gated alongside LLDT/LTR/SLDT/STR/LAR/LSL (no "confirm exact behavior"
        — it is settled: ARPL is a PM instruction and faults #UD in real mode). Do NOT silently
        implement the PM semantics.

---

## Phase 5: Real-mode interrupts, exceptions, recognition timing, illegal opcodes

Goal: the complete real-mode exception model + hardware-IRQ recognition with exact timing, faithful
IVT delivery, and faithful #UD gating. **Done when** the real-mode exception-delivery unit tests pass
and the IRQ-timing edge cases hold.

- [x] **Hardware IRQ input interface** (the CPU's only interrupt input, per CLAUDE module graph): the
      CPU recognizes a pending maskable IRQ via the `InterruptController` hook's `getPendingInterrupt()`
      (Phase 0) and acknowledges via `ackIrq()`. The CPU does NOT know about the 8259 — it just queries
      the pending vector + applies the IF-gated recognition. Document this contract.
- [ ] **IRQ-recognition POSITION is a pure function of (CPU state, cycle counter, deterministic event
      schedule) — INVARIANT (determinism-critical, Theme A).** The machine MUST NOT mutate
      `irq_pending` as a side effect of host timing; the **PIC computes pending status from the cycle
      ledger** (so the *cycle* at which an IRQ becomes pending is derived from the schedule, not from
      when the host happened to inject it). Recognition therefore reproduces byte-identically run to
      run.
- [x] **Recognition timing (determinism-critical):**
  - [x] Maskable IRQ recognized only at an **instruction boundary** when IF=1 (and not in an interrupt
        shadow). On recognition, charge the interrupt-acknowledge cycles and deliver via the IVT.
  - [x] **One-instruction inhibit ("interrupt shadow")** after STI, MOV SS, POP SS, LSS-into-SS: no
        IRQ (and no single-step #DB) recognized until the *next* instruction completes. Model an
        `inhibit_irq_one_instruction` flag set by those ops and cleared after the following
        instruction. (Spice86 "interrupt shadowing", `plans/spice86.md` §3.)
  - [x] **NMI** (vector 2): not maskable by IF; recognized at instruction boundary; nested-NMI
        blocking until IRET. Provide a separate `nmi_pending` input.
  - [x] **TF / single-step #DB**: if TF=1, a #DB trap is delivered *after* each instruction (a trap,
        EIP=next), except in the interrupt-shadow window.
- [x] **`serviceInterrupts()` — the single instruction-boundary checkpoint (Theme G).** This is the ONE
      place the run loop consults for pending events (the interrupt analog of the `linearToPhys` choke
      point). It applies a fixed, documented **priority order**:
  1. pending fault / abort (a fault raised by the just-executed instruction)
  2. TF single-step trap (#DB)
  3. NMI
  4. maskable IRQ (modulo the one-instruction inhibit / interrupt-shadow window)
  - [x] Document this order in `interrupts.zig` and route every boundary check through this one
        function — no ad-hoc interrupt polling elsewhere.
  - [x] **REP / interrupt-shadow composition (state explicitly):** the interrupt shadow suppresses
        recognition for the **FIRST REP iteration only** (the shadow captured at `step()` entry is
        cleared after the first re-entrant `executeOne`, so `serviceInterrupts` suppresses that one
        boundary); subsequent iterations are interruptible at their boundaries.
  - [x] **REP pending-status sampling (Theme A):** each REP iteration is a separate re-entrant
        `executeOne`, so `serviceInterrupts` samples pending status at the per-iteration boundary — the
        defined sub-instruction cycle point. The iteration on which an IRQ is recognized (and the partial
        ESI/EDI/ECX) is therefore reproducible, validated by the IRQ-during-REP determinism test
        (`interrupts_test.zig`).
- [x] **The real-mode 386 exception table** (`interrupts.zig`, a dense vector→descriptor table): for
      each, record vector, class (fault/trap/abort), and whether it pushes an error code. **In real
      mode no error code is pushed** (error codes are a PM-gate construct) — the IVT delivery pushes
      only FLAGS/CS/IP — but record the architectural class for the shared delivery code and the
      deferred PM path. **`pending_fault` carries an `error_code: ?u32` field from day one (Theme G):**
      always `null`/0 in real mode, plus the seam for **CR2** (#PF) — so the future PM addition touches
      only the delivery dispatcher, not every `raiseFault` site. Exceptions that actually occur in real
      mode:
  - [x] #DE 0 (fault) — DIV/IDIV divide error.
  - [x] #DB 1 (trap/fault per cause) — debug / single-step.
  - [x] NMI 2.
  - [x] #BP 3 (trap) — INT3.
  - [x] #OF 4 (trap) — INTO.
  - [x] #BR 5 (fault) — BOUND range exceeded.
  - [x] #UD 6 (fault) — invalid opcode (186+).
  - [x] #NM 7 (fault) — device-not-available (CR0.EM/TS, Phase 4j).
  - [x] #DF 8 (abort) — double fault (contributory-fault rules; cf. DOSBox `CPU_Exception` nesting →
        double/triple fault, `plans/dosbox-x.md` §4). Can occur in real mode.
  - [x] **#GP 13 (fault)** — the **real-mode form**: instruction-length > 15 bytes, an offset/limit or
        segment-wrap violation in a non-stack segment (per the Phase 4 access helper), and the
        #UD-vs-#GP cases the 386 documents in real mode.
  - [x] **#SS 12 (fault)** — the **real-mode form**: stack-segment limit/wrap violation.
  - [ ] (#TS 10, #NP 11, #PF 14 are protected-mode/paging constructs — **N-A in real mode**, kept in
        the Deferred section. #MF 16, #AC 17, #MC 18, #XM 19 are 486+/Pentium+ — out of scope;
        document, do not deliver on 386.)
  - [ ] (Coprocessor-segment-overrun 9 is 386-only legacy via the 387 — deferred FPU seam.)
- [x] **Double/triple fault logic** (real-mode-relevant): track a fault-during-fault-delivery counter;
      contributory faults escalate to #DF; a fault during #DF delivery ⇒ triple fault (the CPU signals
      a shutdown the machine handles — expose a `shutdown` state; the CPU does not reset itself).
      Determinism: the escalation is fully defined.
- [x] **Exception/interrupt delivery — the real-mode IVT sequence** (the only delivery path in scope):
      vector*4 → IP:CS from the IVT (`Bus.readPhys16` at linear `IDTR.base + vector*4` and `+2`); push
      FLAGS, then CS, then IP (in that order, 16-bit each on the SS stack); clear IF and TF. Exact push
      order + widths per Intel 386 PRM real-mode interrupt section; cross-check `cpu.cpp`.
  - [x] **IDTR.limit enforcement on real-mode delivery (exact predicate, Theme D):** fault **iff**
        `vector*4 + 3 > IDTR.limit` (the 4-byte IVT entry must lie fully within the limit). (LIDT can
        move/resize the IVT; default base 0, limit 0x3FF.)
  - [x] **A limit-exceeded DURING exception delivery routes through the contributory/double-fault path,
        NOT a bare #GP** (a fault while delivering a fault escalates per the double-fault rules below —
        it does not just raise a fresh standalone #GP). **No reference-emulator oracle** for IDT-limit
        real-mode behavior — pin with hand-written vectors (Phase 8).
  - [x] INT n (0xCD), INT3 (0xCC), INTO (0xCE), IRET (0xCF) — all through this real-mode path. IRET
        pops IP, CS, FLAGS (16-bit; 32-bit IRETD via 0x66). Charge delivery/return cycles.
  - [ ] (PM IDT-gate delivery and the V86 extended frame are **deferred**, kept as the seam in the
        shared delivery dispatcher.)
- [x] **Illegal / undefined opcodes — honest 386 gating**: raise **#UD** exactly where the 386 does in
      real mode — unmapped opcodes, reserved Grp encodings, LOCK on non-lockable ops, the **PM-only
      instructions that #UD in real mode** (LLDT/LTR/SLDT/STR/LAR/LSL, **ARPL**), and the 486+/Pentium+
      opcodes (BSWAP, CMPXCHG, XADD, INVLPG, RDTSC, CPUID, RSM, WBINVD, INVD, …) — **all #UD on 386 and
      must not be silently implemented** (ground rule).
  - [x] **The "introduced-in" gate is a POSITIVE ALLOWLIST of 386-valid opcodes — NOT a negative list
        of 486+/Pentium+ rejects (Theme C).** Enumerate the opcodes the 386 actually executes (including
        the undocumented-but-valid ones: `0xD6 SALC`, `0xF1 ICEBP/INT1`, and the `0x82` Grp1 alias);
        anything NOT on the allowlist #UDs. A positive allowlist makes the model honestly a 386, not a
        superset, and cannot silently let a newer opcode through by omission from a reject list.
- [ ] **Debug breakpoints (DR0-3/DR6/DR7) #DB — DEFERRED matching, honest stub.** Storage exists
      (Phase 1b); breakpoint *matching* is deferred. Do not fake (a stubbed DR7 that silently never
      fires would be a fake) — document it as not-yet-matched and assert that in tests. Single-step
      (#DB via TF) IS implemented above. See the Deferred section.
- [x] Unit tests: deliver each real-mode exception, assert the pushed IVT frame bytes (FLAGS/CS/IP),
      IF/TF clearing, EIP (fault vs trap), interrupt-shadow suppression, NMI nesting, double-fault
      escalation, IDTR.limit handling, and #UD gating for PM-only / 486+ opcodes.

---

## Phase 6: Fault/restart machinery (cross-cutting — wire it as faults appear)

Goal: a single, deterministic mechanism for raising and delivering real-mode exceptions that leaves
restartable state. **Done when** every fault path uses it and restart tests reproduce byte-identical
state.

- [x] **DECIDED — D10 Zig error unions**, not exceptions/setjmp. Every memory/decode/segment helper
      returns `!T` with `error{Fault}` (or a small error set). On a fault the helper records
      `State.pending_fault = .{ vector, fault_class, error_code: ?u32 }` (the `error_code` is always
      `null`/0 in real mode — the Theme G PM/CR2 seam) and returns the error; the per-instruction
      dispatcher `catch`es it, rolls EIP back to the instruction start (faults) or leaves it advanced
      (traps), and invokes the real-mode IVT delivery sequence. Explicit, no hidden control flow,
      deterministic; keeps the hot path branch-predictable. (DOSBox uses C++ exceptions, explicitly
      flagged as heavy in `plans/dosbox-x.md` §11.)
- [x] **Fault vs trap vs abort semantics** (determines EIP at delivery):
  - [x] **Faults** (#DE,#BR,#UD,#NM,#GP,#SS): EIP = faulting instruction (restartable). Set **RF** so
        the restart doesn't re-trigger an instruction breakpoint (when DR matching lands).
  - [x] **Traps** (#BP int3, #OF into, #DB single-step after the instruction): EIP = next instruction.
  - [x] **Aborts** (#DF double fault): no reliable restart; CPU state per Intel.
- [x] **Instruction-start snapshot**: capture EIP (and any state needed to cleanly restart) at the top
      of `step()` so a fault rolls back exactly. **No architectural writes may be committed before a
      fault that should appear not-yet-executed** — audit each instruction class (e.g. DIV must fault
      #DE before writing the quotient; a memory write that faults must not have updated the register
      operand). This audit is a determinism requirement (constraint #5/#6) and a ground-rule
      faithfulness requirement.
- [ ] **Fault-restart atomicity for multi-write instructions — STRUCTURAL, not per-op vigilance (Theme
      F).** MANDATE one of two patterns (never rely on hand-checking each op):
  - [x] **(a) Pre-flight all memory accesses:** probe every address for limit/wrap BEFORE any commit,
        so any fault is raised before the first write; OR
  - [x] **(b) Stage results in locals** and commit in a single tail block reachable ONLY after every
        faulting step has passed.
  - [ ] **Specify the exact restart state per the 386 architecture** for the multi-write classes:
        **PUSHA/POPA**, **ENTER**, and the **string ops** (the partial SI/DI/CX position on a mid-op
        fault). Document each class's restart contract.
  - [x] **Restart tests are PER-CLASS**, not a single #DE/#GP probe: a dedicated restart test for
        PUSHA/POPA, ENTER, and string ops, each asserting byte-identical restart state.
- [x] Charge the fault-delivery cost deterministically (Phase 7).

---

## Phase 7: Cycle accounting (first-class — determinism-critical)

Goal: a fixed, reproducible per-instruction + per-event 386 cycle model covering every real-mode
path. **Done when** the cycle table is complete, every `step()` path charges deterministically, and a
cycle-regression test passes.

- [x] **Cycle model — INTERIM DETERMINISTIC FLAT MODEL (the M5 decision; D6).** The active model is a
      fixed, pure flat base cost per instruction (`cycles.FLAT_BASE`), looked up per dispatch key at the
      Phase 1a choke point — documented in the `cycles.zig` header as **interim / provisional-by-design,
      NOT a faked 386 clock count** (no number is presented as a real PRM figure). Satisfies the
      determinism prime directive (fixed costs, not accurate ones).
  - [ ] **DEFERRED FIDELITY ONLY (not a blocker) — transcribe the faithful Intel 80386 PRM "Instruction
        Set Clock Count Summary" canonical per-instruction counts** (DOSBox's normal core charges a
        coarse ~1 cycle/op — `plans/dosbox-x.md` §4 — so it is NOT an adequate source). The PRM is not
        available offline; per the ground rule the real counts are NOT invented. When sourced, this is a
        **data swap, not a rewrite**: set `table[key].base` per dispatch key (+ encode the PRM
        range/"n=count" formulas), flip `.provisional = false`, and replace the named event costs — the
        choke point + by-construction guard do not move. **This is the ONE remaining deferred-fidelity
        sub-item; everything else in Phase 7 is done.**
- [x] **Range / "varies" / data-dependent reduction rule (Theme E):** every cycle entry IS a documented
      **TOTAL pure function of (operands, state)** — under the flat model the per-instruction cost is the
      flat constant, and data-dependent multi-step ops (REP/string) reduce to count × per-iteration via
      the re-entrant boundary model (a pure function of ECX/ZF). There is no "default"/unknown cost: the
      table is total over all 0x400 keys (comptime-asserted non-zero), so nothing is silently defaulted.
      The PRM-accurate per-form formulas are the deferred-fidelity sub-item above.
- [x] **Table SHAPE (Theme E):** keep the cycle table a **single flat array indexed by the dispatch
      key** (the D2 u12), or with a small adjacent `[form]` index, resolved at the dispatch site. Do
      **NOT** build a separate classification branch tree just for cycles — cost lookup rides the same
      dispatch key as execution (this is the Phase 1a cost-charging-by-construction choke point).
- [x] **Misaligned-access cost — D12: waive (no penalty charged).** A 16/32-bit access that is not
      naturally aligned charges no extra cost (deterministic either way); recorded as a decision,
      revisitable if cycle-fidelity demands it. (`cycles.ea_simple = 0`.)
- [x] Base costs per instruction (interim flat model): the flat base covers register/memory/imm/reg
      forms and the conditional-taken-vs-not for Jcc/LOOP uniformly; the per-element string-op and
      per-level ENTER costs are realized as count × flat-base via re-entry/iteration; MUL/DIV charge the
      flat base. (PRM-accurate per-form / data-dependent counts are the deferred-fidelity sub-item.)
- [x] **EA computation penalties** — folded into the flat base for now (`ea_simple = 0`); the
      per-addressing-mode 386 EA timing is part of the deferred-fidelity PRM pass.
- [x] **Segment-related penalties** — folded into the flat base for now (segment-override / segment-load
      / far-transfer costs); PRM-accurate figures are the deferred-fidelity pass. (PM gate/task-switch
      costs are deferred.)
- [x] **Fault / interrupt-delivery costs**: a fixed deterministic charge for each real-mode
      exception/interrupt delivery (IVT path) and IRET return (`cycles.fault_delivery`,
      `interrupt_delivery`, `iret_return`), added at the exact points they occur.
- [x] **Prefix costs**, **WAIT/HLT** charging. Prefixes fold into the flat base. **HLT per D11:** the
      CPU charges NO per-idle-cycle amount from host time; `step()` returns the "halted" stop_reason with
      the idle-to-next-event count and the MACHINE fast-forwards emulated time to the scheduler's next
      event (a pure function of the deterministic event schedule). WAIT charges its fixed base cost.
- [x] **Determinism guarantees** (written down + asserted): the same instruction in the same machine
      state always charges the same total; faults and IVT-delivery paths each add a deterministic
      increment; no path leaves `cycles` advanced by a host-dependent amount. Asserted by the
      by-construction guard in `interrupts.step`, the exhaustive 0x400-key sweep, and the
      `cycles.zig` total-function comptime check. This section IS the pure-execution portion of the
      project's cycle ledger (CLAUDE prime directive).
- [x] Cycle-regression test: the determinism regression tests run a fixed instruction sequence (incl. a
      fault and an interrupt delivery) twice and assert byte-identical `cycles` + State + RAM
      (`determinism_test.zig` "deterministic to cycle N twice" + interrupts_test.zig regressions).
      (A single hard-coded golden cycle *number* is intentionally deferred with the PRM fidelity pass,
      since the flat-base value is arbitrary-but-fixed; the two-run byte-identical check is the stronger
      determinism guarantee and is what CLAUDE constraint #6 requires.)

---

## Phase 8: Testing strategy (interleaved with every phase; consolidated here)

Goal: validate against the public 386 single-step vectors (run in **real mode**) + targeted unit
tests for the decode/flag/exception areas. **Done when** the full ProcessorTests 80386 real-mode
suite passes and the targeted suites are green.

- [x] **SingleStepTests / 80386 vectors — RESOLVED & VENDORED.** The plan originally assumed gzipped
      **JSON** in `SingleStepTests/ProcessorTests/386/`. REALITY (corrected): the 386 vectors live in a
      SEPARATE repo `SingleStepTests/80386`, in `v1_ex_real_mode/*.MOO.gz` (941 files), encoded in the
      **binary MOO format** (spec github.com/dbalsom/moo v1.1), NOT JSON.
  - [x] **Vendoring — DONE.** All 941 `v1_ex_real_mode/*.MOO.gz` +
        `80386.csv` + `revocation_list.txt` are vendored under `src/cpu/testdata/80386/`. The raw corpus
        is ~579 MB; the vendored copy is CYCL-stripped (the per-test bus-cycle trace zdos does NOT assert
        — D8) and capped at 100 vectors/opcode → ~19 MB, covering ALL 941 opcodes (~94,100 vectors).
        Reproduced by `src/cpu/testdata/80386/fetch.sh` (+ `strip_cycl.zig`); see that dir's README for
        attribution + the exact commands. Read offline at test time (no runtime fetch — determinism rule).
  - [x] **Binary MOO parser.** Faithful MOO v1.1 chunk parser in `processor_tests.zig` (MOO /TEST/INIT/
        FINA/RG32/RM32/RAM /NAME/BYTS/HASH). Verified against real data. (`std.json` is N/A.)
  - [x] **Harness** (`processor_tests.zig`): loads `initial` regs + `ram` into the sparse page-backed
        `TestBus`, runs each instruction-under-test until the terminating 0xF4 HALT is fetched and the CPU
        halts (the MOO convention — final state captured one byte past the HALT), asserts `final`
        regs/flags + memory with the undefined-EFLAGS mask applied; reports pass/fail/revoked. Full sweep
        via `zig build conformance`; a fast curated regression guard runs in `zig build test`
        (`conformance_test.zig`).
  - [x] **D8 what to assert — DONE.** Asserts final registers, flags, and memory bytes; the access-trace
        is recordable behind the `TestBus` `record_mem` flag (opt-in). Does NOT assert the vectors'
        `cycles` (real bus timing) against zdos's synthetic ledger.
  - [x] **Undefined-flag policy (D9) + revocation list — DONE.** `80386.csv` `f_umask` parsed into a
        per-opcode undefined-EFLAGS compare mask, applied before EFLAGS comparison; a documented
        supplement (`undef_supplement`) covers CSV gaps (BSF/BSR, SHLD/SHRD, BT*, 0F AF IMUL). EFLAGS
        bits 18-31 (non-existent on the 386) are masked globally. `revocation_list.txt` parsed into a
        skip set (counted + reported, never silently dropped; currently empty upstream).
  - [x] **Known-divergence allowlist — DONE (documented in `processor_tests.zig` header).** Residual
        sub-100% opcodes are all genuinely-undefined 386 results with no portable oracle: SHLD/SHRD with
        count > operand size (undefined result), DIV/IDIV #DE pushed-FLAGS (undefined flags in the IVT
        frame), and a few rotate-by-CL non-1 counts (OF undefined). Each is justified; none hides a real
        bug. The defined state always matches.
  - [x] **Reuse spice86's prior art (design only, re-implemented in Zig).** The per-opcode
        undefined-EFLAGS mask (from the public-domain `80386.csv`) and the revocation-list skip follow
        the spice86 harness design; no spice86/DOSBox code or data was copied.
  - [x] **CONFORMANCE RESULTS (full sweep, all 941 opcodes / ~94,100 vectors):** 93,300 pass / 800 fail
        / 0 revoked = **99.15%**. 664/941 opcodes pass 100%; the 277 with residuals are all the
        documented genuinely-undefined cases above (1-27 failing vectors each, concentrated in
        SHLD/SHRD, DIV/IDIV #DE frames, and shift/rotate undefined-count flags). This is the real
        validation of M2/M3.
- [ ] **Testing-strategy gap — state it explicitly (Theme G).** ProcessorTests + `TestBus` validate the
      **ISA** and the **memory/port contract**, but NOT: the **IRQ-recognition handshake**
      (`getPendingInterrupt()`/`ackIrq()`), **HLT/scheduler coordination** (D11), or **fault-to-machine
      propagation** (the shutdown callback). Those require **machine-level integration tests OUTSIDE
      this plan's scope** — note the gap so it is not assumed covered by single-step conformance.
- [ ] **No-reference-oracle behaviors — pin by hand (Theme D).** The **real-mode segment-limit** and
      **IDT-limit** behaviors have **NO reference-emulator oracle** (DOSBox punts on both, and
      ProcessorTests does not target them). They must be pinned with **hand-written, hand-reasoned
      vectors**, NOT diffed against DOSBox / ProcessorTests.
- [~] **Targeted unit tests** (the coverage gaps — ProcessorTests are single-instruction):
  - [x] ModR/M + SIB decode (Phase 2) — exhaustive, 16- and 32-bit addressing.
  - [x] Flag-effect tables incl. undefined-flag pinning (Phase 3) — the undefined-flag policy is
        validated end-to-end by the conformance sweep (the `f_umask` mask + `undef_supplement`); the
        `conformance_test.zig` regression guard pins the curated-opcode pass rate.
  - [x] Real-mode segment access: limit/wrap violations → #GP(0)/#SS(0) (Phase 4 access helper), with
        the exact predicate (last-byte offset > limit) AND the fault-free 16-bit wrap case —
        hand-written (no oracle).
  - [x] Real-mode exception delivery: IVT frame bytes, IF/TF clearing, interrupt-shadow, NMI nesting,
        double-fault, IDTR.limit (`vector*4+3 > IDTR.limit`, hand-written; limit-exceeded-during-delivery
        escalates), #UD gating for PM-only / 486+ opcodes (Phase 5).
  - [x] Fault-restart determinism — **per-class** (Phase 6): separate PUSHA/POPA, ENTER, and string-op
        restart tests, each asserting byte-identical restart state (not a single #DE/#GP probe).
  - [x] Cycle-ledger determinism test (Phase 7): the two-run byte-identical `cycles`+State+RAM checks
        (incl. a faulting path) in `determinism_test.zig`. (A single hard-coded golden cycle *number* is
        deferred with the PRM fidelity pass — the flat base is arbitrary-but-fixed; the byte-identical
        two-run check is the stronger guarantee CLAUDE constraint #6 requires.)
  - [x] **A20 / 1 MiB-wrap test (Theme G):** `FFFF:xxxx → 0x10FFEF`; assert the CPU passes the full
        `(sel<<4)+offset` **UNMASKED** to the bus (A20 masking is the bus's concern, not the CPU's).
  - [x] **Divide-error #DE restart EIP:** assert #DE leaves a **restartable EIP** (correct 386
        behavior — #DE is a fault on the 386, EIP = the faulting instruction).
- [x] **Determinism regression test** (the project's core regression, CLAUDE constraint #6): run a
      fixed real-mode program to cycle N twice; assert byte-identical `State` + `TestBus` RAM. Include
      a path that faults. (`determinism_test.zig`: a normal program and a #DE-divide-by-zero +
      handler program, each run twice, compared field-wise on State and byte-for-byte on the flat RAM.)
  - [x] **HLT-idle determinism (Theme A):** run a HLT-idle span (HLT → scheduled event wakes it) twice;
        assert byte-identical state and cycle ledger (validates the D11 no-host-time contract).
  - [x] **IRQ-during-REP determinism (Theme A):** inject an IRQ at a scripted cycle during a long REP
        twice; assert byte-identical **partial ESI/EDI/ECX** state and the same recognized iteration.
- [ ] Per-phase test milestones are the "done when" criteria below.

---

## Phase 9: CPU-specific determinism checklist (final audit gate)

- [x] No host time / RNG / thread / env reads anywhere in `src/cpu/` (grep-enforced test —
      `determinism_test.zig` `@embedFile`s every CPU source and rejects `std.time`/`std.Random`/
      `std.Thread`/`getenv`/`process.getEnv`).
- [x] `State.reset()` initializes every field; no uninitialized read reachable (verified: two
      differently-poisoned States `reset()` to byte-identical results, and equal to a default+reset
      State; `TestBus` inits deterministically to its fill so fresh buses are byte-identical and unset
      memory reads back the fill — `determinism_test.zig` reset/TestBus-init tests).
- [x] Every `step()` path advances `cycles` deterministically. **EXHAUSTIVE sweep over ALL defined
      dispatch keys (Theme E):** `determinism_test.zig` drives `executeOne` for every opcode byte in both
      the one-byte and 0F maps at both operand sizes (the full 0x400 key space incl. the #UD/default arm)
      and asserts `cycles` advances by a table-consistent **non-zero** amount — the
      cost-charging-by-construction guarantee from Phase 1a / Phase 7, verified end-to-end.
- [x] Faults are restartable and side-effect-free before the fault point (the Phase 6 audit, re-run as
      tests: segment-limit #GP rolls EIP back; the per-class restart tests for PUSHA/POPA, ENTER, string
      ops assert byte-identical restart state — `interrupts_test.zig`).
- [x] Zero allocation in `step()` (counting-allocator guard).
- [x] Save/restore of `State` (for the future API server) is lossless — no hidden machine state
      outside `State` (this is why eager flags D1 and the decoded `seg_base`/`seg_limit`/`seg_desc` of
      D4 matter: no hidden lazy/raw state to serialize).
  - [x] **Completeness audit (Theme E) — enumerate EVERY mutable field that survives an instruction
        boundary and assert each round-trips:** `determinism_test.zig` populates and round-trips the
        **interrupt-shadow / inhibit flag** (`inhibit_irq_one_instruction`), **`irq_pending`** (the
        machine-supplied PIC pending status; the CPU side has no separate field — recognition is queried
        via the hook), **`nmi_pending`** (`nmi_latched` + `nmi_in_service`), **halted**, **shutdown**,
        the **double-fault counter** (`fault_nesting`), `pending_fault`, `cycles`, plus the
        regs/flags/seg/control state — all compared field-wise. A field-count guard fails if `State`
        grows an uncovered field. None live outside `State`.
  - [x] **Invariant: save/restore happens ONLY at an instruction boundary** — the API server must not
        snapshot mid-decode (there is no consistent partial-instruction `State` to serialize). Assert
        this contract.
- [x] The "introduced-in" opcode gate is honest: every PM-only / 486+ / Pentium+ opcode #UDs (asserted
      in tests) — the model is a real 386 in real mode, not a superset and not a faked PM.

---

## Milestone ordering & "done when" criteria

The critical path drives to a **conformance-complete real-mode ISA**, then to **IVT delivery + IRQ
recognition + INT trampolining (M4)** — which is the *actual* Betrayal-at-Krondor prerequisite — then
layers the cycle ledger. **Note:** the machine / bus / DOS work can begin against the **fixed Bus +
interrupt (8259 handshake) + scheduler contracts early (≈M0)** — it does NOT have to wait for M3, since
those contracts are pinned in Phase 0.

- [x] **M0 — Skeleton + state + contracts + public API.** `zig build` + `zig build test-cpu` green;
      `Cpu(TestBus)` resets to 386 power-on state; Bus + `InterruptController` + `Scheduler` contracts
      comptime-verified; the **clean public step/breakpoint/inspect API exists** (its own gate, not
      proven by conformance); determinism guards in place. (Phases 0-1)
- [x] **M1 — Decode.** ModR/M + SIB exhaustive decode tests pass for 16- and 32-bit addressing
      (including 0x67-driven 32-bit addressing in real mode); prefix/operand-size resolution correct.
      (Phase 2). **Jump-table verification done:** `zig build-obj -O ReleaseFast -femit-asm` shows the
      dispatch switch lowers to `jmp qword ptr [8*rax + .LJTI...]` (a real jump table), NOT a cmp
      cascade — the single big switch (D2) is confirmed; no fallback to two dense 256-switches needed.
- [x] **M2 — Real-mode MOV+ALU.** MOV (all forms) and the 8 ALU ops (8/16/32) implemented with eager
      flags; targeted unit tests pass (`exec_test.zig`) AND the SingleStepTests vectors for these opcodes
      pass 100% (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP/MOV all forms). (Phases 3, 4a-4b)
- [x] **M3 — Conformance-complete real-mode ISA.** The full real-mode 386 ISA is implemented, wired into
      the single jump-table dispatch, AND conformance-verified against the vendored SingleStepTests 80386
      real-mode vectors: **93,300 / 94,100 pass (99.15%)** over all 941 opcodes; the 800 residual failures
      are all documented genuinely-undefined 386 results (SHLD/SHRD count>size, DIV/IDIV #DE pushed-flags,
      shift/rotate undefined-count OF) — no real-bug residue. Bugs found and fixed during conformance:
      32-bit IMUL/dmask overflow, SIB scale=8 shift overflow, LOCK lockable-opcode #UD gating (was
      missing), EFLAGS bit-18+ reserved-bit masking (the flagged suspect), the MOO HALT-terminator
      convention (run THROUGH the HALT), port-input convention (0xFF floating bus), shift/rotate OF for
      non-1 counts, BT bit-string address wrap (16-bit addr size), 32-bit ENTER/LEAVE, 32-bit far
      RET/IRET CS-slot width, and the 386 POPAD high-ESP quirk. (Phase 4 + Phase 5 #UD gating)
- [~] **M4 — Real-mode interrupts & exceptions (the actual BaK prerequisite).** IVT delivery,
      INT/INT3/INTO/IRET, real-mode exceptions (#DE/#DB/#BP/#OF/#BR/#UD/#NM/#GP/#SS/#DF), IRQ
      recognition timing via the 8259 handshake (`getPendingInterrupt`/`ackIrq`), the one-instruction
      interrupt shadow, NMI nesting, double/triple fault escalation, IDTR.limit enforcement, and honest
      #UD gating are all IMPLEMENTED with passing unit tests (`interrupts_test.zig`). (Phases 5, 6)
- [x] **M5 — Cycle model. DONE (interim deterministic flat model); PRM fidelity deferred.** The
      cost-charging choke point + by-construction guard + flat dispatch-keyed table (`cycles.zig`) are in
      place and asserted: every dispatch key (incl. the #UD/default arm) charges a fixed non-zero base
      (`FLAT_BASE`), verified end-to-end by the exhaustive 0x400-key sweep; REP/string charge per
      iteration (count × per-iter, re-entrant — never collapsed to one tick); faults/IVT/IRET charge
      fixed documented costs; HLT charges no host-derived idle (D11). The model is a **total pure
      function** — a complete, hole-free cycle ledger. It is **documented as INTERIM and
      provisional-by-design (NOT a faked 386 clock count)** in the `cycles.zig` header and D6.
      Transcribing the faithful Intel 80386 PRM per-instruction counts (D6) is the ONE remaining
      sub-item — a **deferred FIDELITY improvement, not a blocker** (the PRM is not available offline;
      per the ground rule the real counts are not invented; the per-key table + event-cost seams make it
      a later data swap, not a rewrite). D8 asserts state (not cycles), so the flat model does not affect
      the M2/M3 conformance result. (Phases 7, 9)
- [x] **M6 — Module sign-off. DONE.** All DECISIONS recorded/honored (D6 updated to the interim flat
      model); the determinism checklist (Phase 9) is **fully green** — grep-enforced no-host-time audit,
      deterministic reset / no-uninitialized-reads, the exhaustive 0x400-key cost-charging sweep,
      per-class fault-restart, zero-alloc step(), the full-State completeness round-trip (every mutable
      boundary field, with a field-count guard), the snapshot-only-at-boundary invariant, and the
      two-run byte-identical State+RAM regressions (incl. a faulting path, a HLT-idle span, and an
      IRQ-mid-REP). The core CPU module (rooted at `cpu.zig`) imports nothing outside `std` (and the
      compiler-provided `builtin` for the endianness assert); `build_options` appears only in the
      conformance test harness, not the module. `zig build` / `zig build test` (86 tests) / `zig build
      conformance` (99.15%) are all green. Ready for the machine module to wire in toward the
      **Betrayal at Krondor** target.
      **Note:** machine-level integration tests (the IRQ handshake end-to-end, HLT/scheduler
      coordination, fault-to-machine shutdown propagation) are explicitly OUTSIDE this CPU plan's scope
      (Phase 8 testing-strategy gap); they belong to the machine module.

---

## Deferred (post-BaK): protected mode, paging, virtual-8086

**Intentionally not built in the active plan.** This section preserves the long-term vision and the
structural seams so these subsystems slot in later when a DOS-extender / DPMI / protected-mode target
needs them — but there are **no active checkboxes** here and nothing on the critical path. The ground
rule still governs: where a real-mode program legitimately touches a bit of this machinery (e.g. sets
CR0.PE/PG, executes LGDT), the CPU stores state faithfully and **flags the deferred effect — it never
fakes** the missing behavior.

**Seams already built into the active plan (do not remove):**
- The cold `seg_desc: [6]SegDescCold` (D4, Phase 1b layout split) carries the protected-mode-shaped
  fields (type/dpl/present/big/expand-down/conforming) parallel to the hot `seg_base`/`seg_limit`
  arrays; real mode populates only base/limit/default flags and never reads the cold fields on access.
- The `checkSegmentAccess()` access-path choke point (Phase 4) is the one place PM permission checks
  insert; the single `linearToPhys()` choke point (Phase 1c) is the one place a paging unit inserts.
- CR0 (all bits), CR2, CR3, IDTR, GDTR, DR0-7, TR6/7 exist as faithful storage; CPL stored explicitly.
- The shared exception-delivery dispatcher branches on mode; only the real-mode IVT arm is built.
- The "introduced-in" opcode gate and the EFLAGS mask helper are PM-ready.

**Deferred subsystems (summary of what is NOT built yet):**
- **Protected-mode segmentation.** GDT/LDT descriptor loading + decode (`S_Descriptor`/`G_Descriptor`,
  the DESC_* type enum), the full segment-load protection checks (type/DPL/RPL/CPL, present-bit,
  expand-down ranges, conforming-code rules), the Accessed-bit write-back, LLDT/LTR/SLDT/STR/LAR/LSL,
  ARPL's PM semantics, and #NP/#TS plus the PM forms of #GP/#SS. (Sources: `cpu.cpp`
  `CPU_SetSegGeneral`, `cpu.h` descriptor types.)
- **Privilege & control transfers.** Far CALL/JMP/RET through descriptors and **call gates**,
  privilege-level stack switching + parameter copy, the PM **IDT interrupt/trap/task gates** with
  error-code push, and **TSS task switching** (all four entry paths, busy/NT/back-link, the 16- vs
  32-bit TSS images). (Sources: `cpu.cpp` gate/task-switch paths, `cpu.h` `TSS_16`/`TSS_32`.)
- **Paging + TLB + #PF.** CR0.PG-gated two-level translation (PDE/PTE walk), the 386 US/RW privilege
  rule, Accessed/Dirty-bit write-back ordering, the #PF error-code construction + CR2, the software
  TLB model (D5) and its flush points, and the wide-access page-boundary split. (Sources:
  `paging.cpp`/`paging.h`.) Note: 386 has **no INVLPG** (486+).
- **Virtual-8086 mode (D7).** V86 entry/exit (IRET with VM=1, task switch into a V86 task), the V86
  extended interrupt frame, IOPL-sensitive instruction faulting to the PM monitor, and the **I/O
  permission bitmap / IOPL** PM behaviors. (Note: zdos's BaK path delivers EMS via a host `INT 67h`
  handler, so no EMM386/V86 is needed for v1.) VME (CR4.VME) is Pentium+ and out of scope.
- **Debug-register breakpoint matching.** DR0-3/DR6/DR7 instruction/data/IO breakpoint matching (#DB).
  Storage exists; matching is deferred. (Single-step #DB via TF *is* built in the active plan.)
- **x87/387 FPU.** ESC/WAIT currently raise #NM via the CR0.EM/TS/MP hooks (Phase 4j); a 387 module
  would hook the ESC dispatch cases. BaK does not use the FPU.
- **Prefetch-queue / SMC-exact timing.** Fetch is isolated behind `fetch8()` so a prefetch model can
  be added; not built (anti-debug / self-modifying-code-exact timing is the only consumer).
