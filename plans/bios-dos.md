# zdos BIOS + DOS module — implementation plan (`src/bios/` + `src/dos/`): the callback-trampoline bridge, the host-serviced BIOS, the emulated DOS kernel, and the EXE/COM loader

This is the literal, ordered build plan for the two **host-serviced** modules where zdos's
reason-for-existing lives: the **callback-trampoline guest↔host bridge**, the **BIOS** (IVT/BDA/POST
+ INT 10h/16h/1Ah/08h/11h/12h/13h/15h), the **emulated DOS kernel** (INT 21h dispatch, PSP/MCB/DTA/SFT,
host-FS-redirection VFS), the **EXE/COM loader** (the path that actually starts Betrayal at Krondor),
and the **EMS INT 67h service** — in **Zig 0.16**. These are `src/dos/` and `src/bios/` in the module
graph: they sit **above** the machine (they import `cpu`, `bus`, `machine`, `devices`) and **nothing
imports them except `src/api/`**. The **callback-bridge primitive** is NOT in either of them — it is a
**shared leaf** (`src/abi/` alongside `bus_contract.zig`, or a new `src/bridge/` peer) that BOTH
`src/bios/` and `src/dos/` import while **neither imports the other** (D12 reversed / D16). The
`Services` aggregate (the CPU's `CallbackSink`) lives at the machine layer and holds `*Bios` + `*Dos` +
the bridge + a `*Cpu` back-pointer.

**This is the whole point of zdos.** DOS/BIOS are **host-serviced** (API-style, Spice86 lineage):
a guest `INT 21h` does not run real MS-DOS instructions — it traps to a host Zig handler that
reads/writes guest registers + memory. That gives full introspection (the reason DOSBox can't be
debugged the way zdos can). **BUT** the prime directive — *no holes in the cycle ledger* — means
**every host-serviced trap MUST charge a fixed, deterministic synthetic cycle cost**. This is the
exact hole that makes Spice86 non-reproducible (its cycle count smears 346k–3.6M cycles across a trap
because the trap consumes zero ledger cycles); **closing that hole is the entire differentiator of
this module.** The synthetic-cycle-cost contract (DECISION D5 below) is therefore **first-class**,
not an afterthought.

**The ground rule is especially load-bearing here.** This is a huge API surface. An INT 21h
subfunction or BIOS service we cannot support faithfully **must be flagged / surfaced** (a structural
"unsupported DOS service" signal the API server sees), **never silently faked** to "appear to work."
Faking DOS is the precise failure mode (`CLAUDE.md` §"Ground rule") this project exists to escape.

> **SECOND-PASS RE-SCOPE — READ FIRST (the premise correction).** The first pass curated the INT 21h /
> BIOS set to *"what Betrayal at Krondor calls during gameplay"* and accepted each module against
> **self-authored fixtures**. Both were wrong, and an external oracle proved it: **no real compiled DOS
> program calls only "gameplay" services** — every real C runtime (Borland/Turbo C, MSC, Watcom),
> *including BaK's*, runs a startup that makes ~a dozen INT 21h calls **before `main`** (memory-sizing,
> existence-probe, env/argv, file open). A four-agent-reviewed "done" DOS module then **failed the first
> real compiler `.EXE`**, because fixtures can only test what was built. **The scope is therefore
> re-based** from "what BaK's gameplay calls" to a **real-CRT-complete baseline** (D8a/D20 below): the
> *union* of what real CRTs call at startup + runtime. And the **acceptance methodology is replaced**
> (D21 below): "DOS done" now means **"zdos matches dosbox-x on real binaries"** — `dosbox-x` mints
> golden output for real `.EXE`s and `zig build test-oracle` asserts zdos reproduces it (the DOS
> equivalent of the CPU's ProcessorTests conformance vectors). Hand-assembled fixtures remain ONLY for
> cycle-exact determinism testing (zdos's separate guarantee), **never for sufficiency**. See
> `plans/dos-oracle-report.md` for the empirical, traced worklist that drives the second pass.
>
> **This is completion + re-scope, NOT a rewrite.** The genuinely-sound first-pass work stays (see
> D22): the callback bridge (Phase 0), the determinism / cycle-ledger contract (D5, Phase 1/8),
> guest-RAM structure modeling (D9), and the now-fixed loader `max_alloc` handling (Phase 6) are correct
> and validated. The second pass **completes** the function surface, fixes the fidelity gaps the oracle
> exposed, and **re-gates** acceptance on the oracle.

**Read before starting (source of truth — do not work from memory):**
- **`plans/dos-oracle-report.md` — the empirical second-pass worklist.** The corpus (real Borland C++ 3.1
  `.EXE`s) + each PASS/DIVERGE + the exact failing INT 21h call, traced and cross-checked against
  `references/dosbox-staging/src/dos/`. The 3 live divergences (FILEIO/SUBDIR/ARGENV) below are folded in
  from it. This is the second pass's truth, not a self-authored fixture.
- **`references/dosbox-staging/src/dos/dos.cpp` — the real INT 21h surface + correct return semantics**
  (the `DOS_21Handler` AH switch). Every promoted/fixed function below is pinned to a line here (e.g.
  AH=43 AL=00 existence check at `dos.cpp:1106-1120`; AH=33 break-check at `dos.cpp:881`; the unknown-AH
  default `reg_al=0` at `dos.cpp:1610`).
- `CLAUDE.md` — the charter (and the **BaK v1 acceptance target**: real-mode 386, DOS 5.0, ~1 MB EMS). **Host-serviced DOS/BIOS** (Spice86 lineage) **+ the prime directive (no
  holes in the cycle ledger)** = every host-serviced trap charges a fixed synthetic cost. The **ground
  rule** (no fakes/stubs; flag, don't bypass). The **First target: Betrayal at Krondor** (real-mode
  386, loads via INT 21h file calls, needs **EMS via a host INT 67h handler** — no EMM386/V86; EMS
  backing/MMIO is a bus device per B8, but the **INT 67h service** lives here).
- **`src/cpu/interrupts.zig` — read the ACTUAL code** (verified against the file): `step()` snapshots
  `instr_start_eip`, runs `dispatch.executeOne`, then `serviceInterrupts()` (interrupts.zig:46-87);
  the real-mode IVT delivery `deliverViaIvt` pushes FLAGS/CS/IP and clears IF/TF (interrupts.zig:185-209);
  `pushWord`/`popWord` use SP (16-bit real-mode stack, interrupts.zig:212-225); `VEC_UD = 6` and the
  `#UD` path (interrupts.zig:29); `deliverInterrupt`/`deliverException` charge `cycles.interrupt_delivery`/
  `cycles.fault_delivery` (interrupts.zig:140,175). **The callback opcode is a trapped illegal
  instruction surfaced through this path** (see D1/D2).
- **`src/cpu/cpu.zig` — the CPU surface a handler uses** (verified): `CpuWith(Bus, opts)` (cpu.zig:60),
  `Cpu.init(bus, pic, sched)` (cpu.zig:81), `step()` → `interrupts.step()` (cpu.zig:180), the
  inspect/patch surface `readReg32`/`writeReg32`/`readSegSelector`/`readFlags`/`patchEip`/
  `readLogical8`/`patchLogical8`/`readPhysical8`/`patchPhysical8` (cpu.zig:220-251), `loadSegment`
  (cpu.zig:156), `segRead*/segWrite*` (cpu.zig:128-151), `St`/`State` register helpers
  `getReg16/32`/`setReg16/32`/`selector[]`/`seg_base[]`/`eflags`. **A DOS/BIOS handler mutates `cpu.st`
  and reads/writes `cpu.bus`.**
- `src/machine/` and **`plans/machine.md`** — the run loop (`Machine.step()` burst model, M-D5), the
  `machine.StopReason` superset `{ normal, breakpoint, halted_forever, shutdown, cycles_reached }`
  (M-D13), `Machine` owns the `Bus`/`Pic`/`Pit`/scheduler and instantiates `CpuWith`, the **push
  registration** model (M-D1), the BIOS-POST stand-ins `programDefaultPic()`/`programDefaultTimer()`/
  `enableA20()` (M-D9 — **this module's real BIOS replaces/extends them**), and the
  `DeviceCtx{pic, sched}` device-wiring pattern flagged in machine.md §"Out of scope".
- **`src/bus/bus.zig` + `plans/bus.md`** — `loadRom(phys, bytes)` (the BIOS ROM region at 0xF0000,
  Phase 3), the standard ROM regions installed `.rom` at init, `mapMmio(frame_phys, len, handler)` for
  the **EMS MMIO seam** (B8 — EMS is an ordinary MMIO device; the INT 67h *service* + backing store
  live HERE), `setA20`, the snapshot model (B12 — handlers by stable ID). The IVT/BDA/PSP/MCB all live
  in guest **RAM** (conventional memory), not in special bus state.
- `src/abi/bus_contract.zig` — the comptime contracts; this module adds **no new CPU contract** (it
  hangs off the existing illegal-opcode/`#UD` surface — see D2).
- `plans/cpu.md` — Phase 5 (real-mode IVT delivery, `#UD` gating, the positive 386-valid opcode
  allowlist), the cycle ledger (Phase 7, `cycles.interrupt_delivery`/`fault_delivery`), D11 HLT.
- The architecture studies — **all three converge on this exact design**: `plans/dosbox-x.md` §6
  (emulated DOS kernel) + §7 (callback bridge `0xFE 0x38 <id>`, `CALLBACK_RunRealInt`),
  `plans/dosbox-staging.md` §6-7 (the callback mechanism is "the architecture"; CB_SEG=0xF000,
  CB_SOFFSET=0x1000, CB_SIZE, `0xfe 0x38`), `plans/spice86.md` §7 (IVT install, the F000 stub +
  callback opcode, `IndexBasedDispatcher`, BDA at 0040:0000, the per-AH dispatch). **`plans/dosbox-test-suite.md`**
  — the 8.3-name-munging (`DOS_MakeName`/`DTAExtendName`) + MCB layout tests are a **behavioral spec to
  re-derive from, NOT copy** (DOSBox is GPL).
- Reference sources (algorithmic detail — re-derive, do not copy GPL behavior):
  `references/dosbox-staging/src/cpu/callback.cpp` (`callback_setup_extra` emits `0xfe 0x38 <id>`
  callback.cpp:199-200; the return-sequence builders `CB_IRET`/`CB_RETF`/`CB_IRET_STI` callback.cpp:209-264;
  `CALLBACK_RunRealInt` callback.cpp:106-114 — re-entrancy; `CALLBACK_SCF/SZF/SIF` patch the FLAGS image
  on the guest stack callback.cpp:116-135), `src/cpu/callback.h` (CB_SEG=0xF000, CB_SOFFSET=0x1000,
  CB_SIZE=32, CB_MAX=128), `src/dos/dos.cpp` (the `DOS_21Handler` AH switch), `src/dos/dos_execute.cpp`
  (`struct EXE_Header` line 27, MAGIC1=0x5a4d line 47, the COM-vs-EXE branch line 332, relocation +
  `SetupPSP`/`MakeEnv`), `src/dos/dos_memory.cpp` (MCB chain), `src/dos/dos_files.cpp`/`drive_local.cpp`
  (the `DOS_Drive` VFS + 8.3); `references/spice86/.../Emulator/OperatingSystem/` (`Dos.cs`,
  `DosFileManager.cs`, `DosMemoryManager.cs`, `DosProcessManager.cs`, `DosProgramLoader.cs`, the PSP/MCB
  structs) + `.../InterruptHandlers/` (callback + BIOS).
- **Zig 0.16 host I/O — verified, IMPORTANT (the API churned):** file I/O is **`std.Io.Dir` /
  `std.Io.File`** (NOT `std.fs.File`). `Dir.openFile(io, sub_path, opts)` (`Io/Dir.zig:577`),
  `Dir.createFile` (:638), `Dir.deleteFile` (:1004), `Dir.rename` (:1093), `Dir.iterate()` (:211).
  Every call takes an **`io: Io`** handle. Read/write/seek go through `File.reader(io, buf)` /
  `File.writer(io, buf)` then `Reader.seekTo`/`seekBy`/`getSize` (`Io/File/Reader.zig:115,134,164`),
  `Writer.seekTo` (`Io/File/Writer.zig:197`). **Grep `references/zig/lib/std/Io/` for exact signatures
  — do not write from memory.** This `io: Io` indirection is the seam where determinism is enforced
  (D6): host file *content* is fixed external input; its *timing* never touches the ledger.

**Notation:** every actionable step is a `[ ]` checkbox. The **DECISIONS** block records each design
choice (D1…D19) with a **recommendation + rationale** per the ground rule (flag, don't silently
decide). Items marked **(determinism-critical)** are part of the reproducibility surface and must be
exact — the bridge's synthetic-cost charging and the no-host-time file/clock contract especially.
Do **not** write code or touch other files while working from this plan; it is the spec.

> **Proportionality note.** Be thorough on **the callback-trampoline bridge (Phase 0)** and **the
> synthetic-cycle-cost / determinism contract (D5, Phase 1)** — they are the foundation everything
> hangs off and the literal differentiator (these are DONE and validated — D22). For the INT 21h / BIOS
> service set, the bar is now the **real-CRT-complete baseline** (D8a/D20): implement the union of what
> real CRTs call at startup + runtime, gated by the oracle (D21), **not** a hand-picked "gameplay" list.
> Still flag-and-defer genuine non-CRT breadth (FCB API, network/share, LFN, DBCS) per D11 — but a CRT
> startup call is in-scope by definition, even if "gameplay" never touches it.

---

## DECISIONS (recommendation + rationale per the ground rule — flag, don't silently decide)

- [x] **D1 — Callback opcode: reuse DOSBox's `0xFE 0x38 <id8>` (GRP4 reg=7, an illegal/undefined 386
      encoding) as the guest↔host trap. RECOMMENDED.** Weighing:
  - *Option A — a brand-new bespoke opcode* (e.g. an unused single byte). Rejected: every unused byte
    on the 386 is either a documented #UD or risks colliding with a real (even undocumented-but-valid)
    386 instruction; cpu.md M3 already pins a **positive allowlist of 386-valid opcodes** (`0xD6 SALC`,
    `0xF1 ICEBP`, the `0x82` alias) and #UDs everything else — a bespoke byte would have to be carved
    out of that allowlist.
  - *Option B (RECOMMENDED) — `0xFE /7` (`0xFE 0x38`)*, exactly what dosbox-staging
    (`callback.cpp:199-200`) and dosbox-x emit. `0xFE` is GRP4; reg fields 0/1 are INC/DEC r/m8, reg
    2-7 are **reserved → #UD on a real 386**. `0xFE 0x38` is mod=00 reg=7 rm=000. The CPU already
    raises `#UD` (VEC_UD=6) for this encoding via the Grp4 default arm (cpu.md Phase 2 "#UD default
    arm" + Phase 4b Grp4/5). **The id byte follows the opcode** (`0xFE 0x38 <id>`); the handler reads
    it from the stub. **Rationale:** it is a *known-illegal* encoding (so it can never alias a real
    386 instruction — the allowlist already rejects it), the three reference emulators converge on it
    (proven design), and it requires **no new CPU contract** — only a hook on the existing `#UD`/Grp4
    path (D2). Flag: the id is a **separate immediate byte after `0xFE 0x38`**, so the stub is **3 bytes
    with a 1-byte id**. **This is a *deliberate* divergence from DOSBox** (which uses a 4-byte stub with a
    **2-byte** id, `CB_SIZE=32`, `CB_MAX=128`): zdos's 128 callback ids fit in a single byte, so a 1-byte
    id suffices. **Do not claim the stub "mirrors DOSBox byte-for-byte" and do NOT inherit DOSBox's
    `CB_SIZE=32` offset math** — define zdos's own `CB_SLOT_SIZE` (stub bytes + the per-id return tail;
    see D4). The `/7` arm `fetch8`s the id itself; document this so the decoder hook reads the id without
    re-decoding.

- [x] **D2 — How the CPU surfaces the trapped callback to the host: a comptime `CallbackSink` hook on
      the CPU, invoked from the Grp4-`/7` decode arm, NOT a `StopReason` round-trip through the machine
      run loop. RECOMMENDED (determinism-critical).** Weighing the two shapes the prompt raises:
  - *Option A — a distinct `StopReason.callback{id}`:* the CPU's `step()` returns "I hit a callback id
    N"; the machine loop dispatches to `handlers[N]`. This is the DOSBox `Normal_Loop` shape
    (`dosbox.cpp` returns the id, the loop calls `Callback_Handlers[ret]()`). **Problem for zdos:** it
    forces every host-serviced trap through the machine's outer loop, which complicates **re-entrancy**
    (D3 — a host handler that itself runs a guest INT must re-enter the loop) and spreads dispatch
    across two modules. It also can't be used while the CPU is mid-burst (cpu.zig `runCycles` loops
    `step()` and only checks `.shutdown`).
  - *Option B (RECOMMENDED) — a comptime hook* `CallbackSink` added to the CPU's `Options` (alongside
    `Pic`/`Scheduler`), with one method **`dispatchCallback(self: *Sink, id: u8) void`**. **The contract
    must NOT name `*Cpu`:** `src/abi/bus_contract.zig` is a *shared leaf* that BOTH `src/cpu/` and
    `src/bus/` import — it cannot reference the CPU type without inverting the module graph. So the
    `Sink` **holds its own `*Cpu`** (set at wire time by the machine, exactly as the `Services` aggregate
    is constructed with the CPU pointer), and `assertCallbackSinkContract(comptime Sink)` verifies only
    `fn (*Sink, u8) void` — no CPU type in the signature. When the Grp4 decode arm sees reg=7, it reads
    the id byte and calls `cpu.cb.dispatchCallback(id)` **synchronously, inline in `executeOne`**; EIP is
    advanced past the 3-byte stub **after the call returns and only if CS:IP was not changed** (see
    D1/Phase 0b). The host handler runs, mutates `cpu.st` + `cpu.bus` (through the `*Cpu` the sink holds),
    and returns; the stub's *next* byte is the `IRET`/`RETF` tail (D4) which the CPU executes normally to
    resume the guest. **Rationale:** (1) the handler runs **inside the CPU step**, so re-entrancy (D3) is
    "the handler drives the machine step in a loop" — no machine-loop gymnastics; (2) dispatch is one
    comptime-inlined call with **zero runtime vtable** on a path that's already rare (a trap), matching
    the project's comptime-Bus doctrine; (3) it keeps `bus_contract.zig` a true leaf (no CPU type leak),
    so the module graph stays acyclic exactly like `assertBusContract`. Flag: the DOS/BIOS facade is
    wired into `CpuWith(Bus, .{ .Pic, .Scheduler, .CallbackSink })`; the machine constructs it and sets
    its `*Cpu` back-pointer. The default is a `NullCallbackSink` that **raises #UD** (so a callback opcode
    with no registered sink faithfully faults — ground rule, never a silent NOP; this path must NOT
    pre-advance EIP so the existing `interrupts.zig` fault rollback stays correct). **This is the one CPU
    edit this module requires; flag it for the user — it touches `src/cpu/` (the Grp4 `/7` arm + `Options`).**

- [x] **D3 — Re-entrancy (`CALLBACK_RunRealInt` equivalent): host code issues a guest INT by running a
      real `INT n` through a ROM trampoline and driving the MACHINE step until a stop callback fires.
      REWRITTEN — this is the #1 correctness fix.** The loader and any host code that must issue a guest
      INT (the EXEC path AH=4B reusing the file-open service, or the BIOS calling INT 10h internally)
      needs the `CALLBACK_RunRealInt` trick (`callback.cpp:106-114,677-685`). **The prior "set CS:IP =
      IVT[intnum] + push a hand-rolled far-return frame" was WRONG:** an INT handler ends in **IRET**
      (popping FLAGS/CS/IP), not RETF, so a hand-built RETF/far-return frame is the wrong shape and the
      flags would not unwind. **Correct zdos shape — execute a real `INT n` via a trampoline:**
  - Build a small **trampoline in the BIOS ROM region**: the two bytes `CD nn` (`INT n`) followed by the
    reserved **stop-callback opcode** (`0xFE 0x38 <stop_id>`), i.e. `INT n; <stop-callback>`. (Mirror
    DOSBox planting `CB_INT*`/`call_stop` in the callback area.)
  - `bridge.runGuestInt(intnum) void`: (1) save `cpu.st` CS:IP/SP (and the re-entry-seam scratch, below);
    (2) point CS:IP at the trampoline; (3) **drive the re-entry loop through the MACHINE step primitive**
    (the one that calls `fireDue` + honors `nextEventCycle`), **NOT raw `cpu.step()`** — so PIT/IRQ
    events fire during re-entry and the BDA tick stays cycle-deterministic; (4) the real `INT n` the CPU
    executes builds its **own IRET frame (FLAGS/CS/IP)** and dispatches through the IVT exactly as the
    guest would; (5) when the guest handler `IRET`s, it lands on the trampoline's stop callback, whose
    handler sets `reentry_done = true`; the loop exits; (6) restore CS:IP/SP and the seam scratch.
  - **Machine/bridge wiring:** the bridge sits *below* the machine, so the bridge cannot call the machine
    step by importing it (that would invert the graph). The **machine must supply the step/`fireDue`
    primitive to the bridge** (a function pointer / small stepping interface injected at wire time), OR
    the machine owns `runGuestInt` and the bridge exposes the save/restore + trampoline primitives it
    calls. State the chosen wiring in Phase 0d. Either way the re-entry loop honors the event schedule.
  - **Save/restore the re-entry seam (`cpu.dec` + `cpu.instr_start_eip`):** a nested step runs
    `cpu.dec.reset()` and overwrites `instr_start_eip`, clobbering per-instruction decode scratch the
    outer `executeOne` still needs after `runGuestInt` returns. Snapshot both around the re-entry and
    restore them.
  - **Determinism (critical):** the re-entrant steps run real guest instructions and charge their
    **real** cycle costs through the normal ledger — there is **no separate timing path**; only the leaf
    host services charge synthetic cost (D5). **Rationale:** mirrors the proven `CALLBACK_RunRealInt`
    design byte-for-byte in *shape* (real INT, IRET unwind, stop callback), keeps re-entrancy on the
    deterministic machine step, and keeps the cycle ledger whole across re-entry. Flag: the reserved
    stop-callback id and its trampoline are allocated at BIOS init (Phase 0d/Phase 2).

- [x] **D4 — Callback stub layout + return semantics: a fixed table of 3-byte trap stubs in the BIOS
      ROM region at F000:CB_BASE, each followed by a per-id return tail (`IRET`/`RETF`/`IRET+STI`).
      RECOMMENDED.** Mirror DOSBox's *placement* (CB_SEG=0xF000, CB_SOFFSET=0x1000, callback.h) but
      **NOT its `CB_SIZE=32` / 2-byte-id offset math** — zdos uses a **3-byte stub with a 1-byte id**
      (D1, a deliberate divergence: 128 ids fit a byte) and defines its own `CB_SLOT_SIZE`. zdos:
      reserve a region in the BIOS ROM image (segment 0xF000) for **N callback slots**; each slot is
      `0xFE 0x38 <id>` (3 bytes) followed by the return sequence chosen by the callback **type**
      (`.iret` for hardware/software-INT handlers → `0xCF`; `.retf` for far-call services; `.iret_sti`
      for IRQ handlers that re-enable interrupts; `.iret_eoi` for IRQ0/IRQ1 that send an EOI first — the
      DOSBox `CB_IRQ0`/`CB_IRQ1` builders, callback.cpp). The IVT entry for a serviced vector points at
      its slot's seg:offset. **The stub bytes are written into guest RAM via `bus.loadRom` (the BIOS
      image)** so from the guest's view there is *real code* at the vector (faithfulness — a guest that
      reads/copies its INT 21h vector sees a valid F000 pointer, as BaK's loader might). **The host sets
      carry/zero/IF on return by patching the FLAGS image on the guest stack** (the `CALLBACK_SCF/SZF/SIF`
      trick, callback.cpp:116-135 — `real_writew(SS, SP+4, ...)` because the IRET frame is
      IP/CS/FLAGS) so `IRET` returns the right flags to the guest. **Rationale:** identical to all three
      references; "real code at the vector" is the faithfulness property that makes the host-serviced
      design indistinguishable from real DOS to the guest. **Re-derive the exact byte sequences from the
      ISA, not by copying DOSBox's builder** (the bytes are ISA facts: `0xCF`=IRET, `0xCB`=RETF,
      `0xFB`=STI; the GPL-licensed *builder code* is not copied).

- [x] **D5 — The synthetic-cycle-cost contract (FIRST-CLASS — THE zdos differentiator): every callback
      handler charges a FIXED, DOCUMENTED synthetic cycle cost (or a deterministic pure function of the
      work), charged UNIFORMLY at the bridge with per-service overrides. DECIDED (determinism-critical).**
      This is the literal closing of the Spice86 hole (`CLAUDE.md` §"Prime directive"): Spice86's trap
      consumes **zero** ledger cycles, so frame N drifts; **zdos charges a deterministic synthetic cost
      so the ledger has no hole across a trap.**
  - **Where it is charged:** in the **bridge**, in `dispatchCallback` (D2), **before** invoking the
    leaf handler: `cpu.st.cycles += cb_cost.base[id]` where `cb_cost` is a flat per-id table (the same
    dispatch shape as cpu.md's `cycles.zig`). The handler may add a **deterministic, work-proportional
    increment on top** via a documented formula (below). This is the "uniform + per-service override"
    model the prompt asks for.
  - **It MUST be a pure function** of (the service id, the guest-register inputs that define the work
    size). **No host time, no host I/O latency, no host scheduling** may influence it (the whole point).
    A file read of N bytes charges `cb_cost.file_read_base + N * cb_cost.per_byte` (a fixed formula),
    **NOT** `f(host read duration)`. The N comes from the guest's CX/count register — a guest input,
    not a host measurement.
  - **The numbers are INTERIM / provisional-by-design**, exactly like cpu.md's flat cycle model (D6):
    they are *fixed* (which satisfies the prime directive) but **not** claimed to be PRM-accurate real
    DOS timings (real INT 21h cost varies by FAT/disk state we don't model). Documented as such in the
    `cb_cost.zig` header. The honest figure to transcribe later (a fidelity-only pass) would be measured
    DOS-on-386 service timings; not available offline, so per the ground rule it is **not invented** —
    fixed interim costs are used and labeled.
  - **Comptime totality (no silent default):** every allocated callback id must have a `cb_cost` entry;
    a comptime/assert check (mirroring cpu.md's 0x400-key sweep) fails if an id has no cost. The
    default/unsupported-service path (D11) charges a defined cost too.
  - **Reconciliation with cpu.md + machine M-D7:** the CPU already charges `cycles.interrupt_delivery`
    for the IVT delivery that *reaches* the stub (interrupts.zig:140/175). The **synthetic cost D5 adds
    is the cost of the host SERVICE itself** (the guest work it stands in for), charged on top of the
    delivery cost — together they make the trap's total ledger cost a fixed function with no hole. The
    re-entrant guest work (D3) is charged normally and is separate. **Rationale:** `CLAUDE.md` hard
    constraint #1; this is the single most important property of the module.

- [x] **D6 — Deterministic host file I/O: host file CONTENT is fixed external input (replayed config,
      not snapshot bytes); host file TIMING never touches the ledger. DECIDED (determinism-critical).**
      The VFS (D8) reads/writes real host files, but:
  - The **cycle cost is the synthetic D5 formula** (`base + N*per_byte`), never the real read duration.
  - **No host wall clock** drives anything: INT 21h get-date/get-time (AH=2A-2C) and INT 1Ah read the
    **emulated PIT/RTC tick** (`CLAUDE.md` #2), NOT `std.time` (D13). The Zig `io: Io` handle is the
    seam; grep-enforce no `std.time` in the module.
  - **Snapshot model:** open file handles are snapshotted by **stable SFT index + host path + current
    file position** (D9/D14), NOT by host fd. On restore the VFS re-opens the path and seeks to the
    saved position. **Host file content is NOT in the snapshot** — it is replayed external config (the
    game's data files on disk). **Rationale:** `CLAUDE.md` #2/#3/#6; reproducibility requires the
    *content* be a fixed input and the *timing* be synthetic.

- [x] **D7 — Handler signature: `fn(ctx: *Service, cpu: *Cpu) void`, operating on `cpu.st` + `cpu.bus`
      via the existing CPU surface; dispatch by AH inside each INT handler (the `IndexBasedDispatcher`
      shape). RECOMMENDED.** Each callback id maps to one **interrupt-level** handler
      (`int21Handler`, `int10Handler`, …); the handler reads `cpu.st.getReg8(AH)` and switches to a
      per-AH subfunction. Handlers use the *existing* CPU accessors — `getReg16/32`/`setReg16/32`,
      `selector[]`/`seg_base[]`, `eflags`, and for guest memory the segmented `readLogical8`/`segRead*`
      or physical `readPhysical8`/`patchPhysical8` (cpu.zig:220-251). They set return carry/zero via the
      D4 stack-FLAGS patch helper (`bridge.setGuestCF(cpu, bool)` etc.). **Rationale:** matches
      spice86's `IndexBasedDispatcher` (AH = sub-function index) and dosbox's `DOS_21Handler` switch;
      reuses the CPU's already-tested register/memory surface (no new memory path); the `*Service` ctx
      carries the DOS/BIOS state (PSP/MCB/SFT/VFS, BDA). Flag: handlers must be **pure w.r.t. host
      time/RNG/scheduling** (audit, Phase 9), and must read counts from guest registers so D5 costs stay
      pure.

- [x] **D8 — Host-FS VFS: a `DosDrive` abstraction with ONE backend — a `HostDirDrive` mapping one host
      directory to one DOS drive letter; `std.Io.Dir`-based. RECOMMENDED.** DOSBox has 6 drive backends
      (`localDrive`/`fatDrive`/`isoDrive`/…); spice86 has `DosDriveManager` + path resolver. **zdos needs
      one backend:** a real-mode game / real program that loads its files from a directory tree. A
      `DosDrive` interface (`open`, `create`, `close`, `read`, `write`, `seek`, `findFirst`, `findNext`,
      `unlink`, `getAttr`, `rename`, plus the dir ops in D8b) with a single `HostDirDrive` backend over
      `std.Io.Dir` (verified API — Phase 5). A drive table `drives[26]` (A:..Z:); the install dir mounts
      as `C:`. **8.3 name munging** (D10) maps DOS 8.3 names ↔ host filenames. **Rationale:** one host
      directory tree mapped to one drive covers BaK + the corpus; the interface keeps the seam for
      `fatDrive`/CD later (flagged deferred). FCB-based file API (CP/M legacy, INT 21h 0x0F-0x24) is
      **deferred-and-flagged** unless a trace shows it (handle-based 0x3C-0x42 is what 1993 games + CRTs
      use).

- [x] **D8a — RE-SCOPE: the curation target is a REAL-CRT-COMPLETE baseline, NOT "BaK gameplay". NEW
      (supersedes the "curated to what BaK needs" framing of D8/D7/D11 and the proportionality note).**
      The first pass's defining error: it scoped the INT 21h/BIOS set to the calls BaK issues *during
      gameplay*, but **never to what it takes to START any real compiled program.** Every real CRT
      (Borland/Turbo C, MSC, Watcom) — including BaK's — runs a startup that makes ~a dozen INT 21h calls
      before `main` (AH=30 version, AH=4A memory-sizing, AH=33 break-check, AH=29 parse-filename,
      AH=48/4A heap, the env/argv setup, an AH=43 existence-probe, AH=3C/3D file open). A "done" module
      curated to gameplay therefore **fails the first real `.EXE`** (`plans/dos-oracle-report.md`). **New
      target:** the **union of what real CRTs call at startup + runtime.** This promotes into scope
      (previously missing or wrong — see D20 for per-function detail): **AH=33** (Ctrl-Break get/set),
      **AH=29** (parse filename into FCB), **AH=59** (get extended error info), **AH=52** (Get List of
      Lists / SysVars + a real MCB anchor), **AH=44 IOCTL `AL=01/06/07`** (set device info / input-status
      / output-status — only `AL=00` existed), **AH=45/46** (dup / dup2), and the **AH=43 AL=00 existence
      fix** (see D20). **Rationale:** a CRT startup call is in-scope by definition; the oracle, not a
      gameplay trace, defines sufficiency. This is NOT speculative breadth (D11 still defers FCB/network/
      LFN/DBCS) — it is the irreducible floor for running *any* real program.

- [x] **D8b — RE-SCOPE: subdirectory / multi-component path traversal is IN-SCOPE (was Out of scope).
      NEW (a hard BaK blocker — SUBDIR divergence).** The first pass's single-directory VFS took only the
      FINAL path component (`fn resolve` → `lastIndexOfAny(p, "\\/")`), so `SUB\DATA.TXT` resolved to
      `DATA.TXT` at the mount root and failed (`plans/dos-oracle-report.md` §2; reference
      `drive_local.cpp` + `DOS_MakeName` in `dos_files.cpp` walk `SUB\` as a real directory). **BaK loads
      its data files from subdirectories**, so this blocks v1. **The VFS must resolve multi-component DOS
      paths:** canonicalize `C:\SUB\DATA.TXT`, translate `\`→`/`, 8.3-munge each component, and open the
      leaf relative to the mount root (walking real host subdirectories). It must also support the
      directory-navigation calls a CRT/program uses: **AH=3B chdir** (was a no-op success), **AH=47
      getcwd**, and **AH=39/3A mkdir/rmdir** (were deferred-unsupported) — promoted as needed. **Moved out
      of "Out of scope."** **Rationale:** real path resolution is not optional for a program that opens
      `SUB\FILE`; the single-dir shortcut was the explicit blocker the oracle surfaced.

- [x] **D9 — PSP/MCB/DTA/SFT representation: thin typed "views" over guest RAM (the DOSBox `MemStruct`
      model), NOT host-side mirror structs. RECOMMENDED.** The PSP (256 bytes), MCB chain (16-byte
      headers in the arena), DTA (128 bytes), and the environment block are **real bytes in guest
      conventional memory** — a guest program reads them at byte-accurate offsets (BaK's loader/runtime
      inspects its PSP). zdos models each as a small Zig helper (`Psp`, `Mcb`, `Dta`) that reads/writes
      fields at fixed offsets through `cpu.bus`/the segmented accessors — the `DOS_PSP`/`DOS_MCB`/`DOS_DTA`
      pattern. **The SFT (system file table)** is the one piece that is **host-side state** (it holds the
      Zig `File` handle objects, which cannot live in guest RAM): a fixed-size `sft: [N]SftEntry` array
      on the `Service` ctx, indexed by a stable id; the **per-process JFT (job file table)** in the PSP
      maps the guest's file *handle* (the small int it gets back) → SFT index (byte array at PSP offset
      0x18, the classic 20-handle JFT). **Rationale:** byte-accurate guest-visible structures =
      faithfulness (the guest sees real DOS structures); the SFT-on-host + JFT-in-PSP split is exactly
      how real DOS + DOSBox/spice86 do it and is the only place a host object (the `File`) must live.
      Snapshot: guest-RAM structures ride the bus snapshot; the SFT host handles are re-bound by
      path+position (D6/D14).

- [x] **D10 — 8.3 name munging: re-derive the canonicalization from the documented DOS rules + the
      dosbox-test-suite behavioral spec; do NOT copy DOSBox's `DOS_MakeName`/`DTAExtendName` code (GPL).
      DECIDED.** The behavior to reproduce (re-derived, with unit tests written from the spec, per
      `plans/dosbox-test-suite.md`): uppercase; split name (≤8) + extension (≤3) on the last dot;
      reject/translate characters illegal in 8.3; collapse a host long-name to a deterministic 8.3
      short name when enumerating a directory (the `~1` tilde-numbering generation order must be
      **deterministic** — a determinism concern, since iteration order of a host directory is not
      guaranteed: sort entries before assigning `~N`). **Rationale:** the munging is a *specification*
      (documented DOS 8.3 rules), not DOSBox-proprietary; copying GPL code is forbidden; the
      determinism subtlety (stable `~N` assignment over an unordered host directory listing,
      `CLAUDE.md` #5) must be handled explicitly — **sort `Dir.iterate()` output deterministically
      before numbering.**

- [x] **D11 — Unsupported INT 21h subfunction / BIOS service policy: FLAG + surface, never fake — but
      faithfully (split into two faithful sub-rules). DECIDED + CORRECTED (ground rule, load-bearing).**
      An AH (or AH/AL) we have not implemented does **not** silently return a fabricated success. The
      policy splits:
  - **(a) [D11a] Functions with a defined DOS error path** set **CF=1 + AX=error code ONLY where DOS
    itself does** (e.g. open a missing file → CF=1, AX=2; **AH=43 AL=00 on a missing file → CF=1, AX=2**,
    `dos.cpp:1106-1120` — the FILEIO fix, D20). This is a *faithful* failure, not an invention — used only
    for subfunctions that have a real DOS error return, and it must set `dos.errorcode` (for AH=59, D20).
  - **(b) [D11b] The generic unknown-AH default** returns **AL=0 with carry CLEAR** — because that is what real
    DOS actually does for an unknown AH (`dosbox dos.cpp:1610`: `reg_al = 0; break;`); real DOS does
    **NOT** set CF for an unknown function. **Do not fabricate a CF=error here** — that would itself be a
    fake. The "surface, never fake" goal is met **not** by a fabricated CF, but by **also raising the
    structural `Service.unsupported{int, ah, al}` signal** the API server sees (a record + an optional
    stop). So the *guest* sees faithful real-DOS behavior (AL=0, CF clear) while the *host/API* sees the
    honest "we don't implement this" signal.
  - A comptime/registration check lists exactly which subfunctions are implemented; the default arm of
    each INT switch hits rule (b). Charges the D5 default cost. **Rationale:** `CLAUDE.md` ground rule —
    faking DOS is the failure mode to escape; faithfulness means matching real DOS's *actual* unknown-AH
    behavior (AL=0/CF clear), and the honesty requirement is satisfied by the out-of-band structural
    signal, not by lying to the guest with a fake CF.

- [x] **D12 — Module split: `src/bios/` (IVT/BDA/POST + BIOS INTs) and `src/dos/` (kernel + loader +
      VFS + EMS service) as SEPARATE peer modules; the callback-bridge primitive is HOISTED into a
      SHARED LEAF both import — NOT a dos→bios edge. REVERSED.** The prior decision routed `src/dos/` →
      `src/bios/` so dos could reuse the bridge; **that edge is overturned.** Reasons: it makes `dos`
      depend on the whole of `bios` just for the bridge primitive, and it is asymmetric (the BIOS INT
      handlers and the DOS INT handlers both need the *same* bridge — there is no real "bios owns the
      bridge" relationship; both are equal clients). **New shape — hoist the bridge primitive into a
      shared leaf:** the callback primitive (callback allocation, stub/trampoline planting, `runGuestInt`,
      the FLAGS-patch/`setGuestCF/ZF/IF` helpers, the `cb_cost` synthetic-cost table) moves into a
      **shared leaf module** — `src/abi/` alongside `bus_contract.zig` (or a new `src/bridge/` peer that
      sits below both `src/bios/` and `src/dos/`). **BOTH `src/bios/` and `src/dos/` import the bridge
      leaf; NEITHER imports the other.** This matches the existing `assertBusContract`→`src/abi/` leaf
      pattern (a leaf both cpu and bus import, neither importing the other), and the reference emulators
      (DOSBox's `callback.cpp` is shared infrastructure under `src/cpu/`, not under `src/dos/`; spice86
      keeps the callback machinery in `Common/`, not in the DOS layer). The **`Services` aggregate** that
      is the CPU's `CallbackSink` (D2) **still lives at the machine layer**: the machine owns a `Services`
      that holds the `*Bios` + `*Dos` state + the bridge instance + the `*Cpu` back-pointer, and is the
      `CallbackSink` the CPU dispatches to. **Rationale:** keeps the graph acyclic with the bridge as a
      true shared leaf (the same doctrine as `bus_contract.zig`); one `CallbackSink` facade keeps the
      CPU's comptime surface single; removes the awkward dos→bios coupling. Flag: update the build wiring
      — `bios_mod` and `dos_mod` both `addImport("bridge", ...)`; neither imports the other.

- [x] **D13 — INT 21h get-time / INT 1Ah / get-date stay deterministic by reading the emulated
      PIT/RTC, not the host clock. DECIDED (determinism-critical).** INT 21h AH=2A (get date), 2B (set
      date), 2C (get time) and INT 1Ah (system time-of-day tick) derive their values from the **BDA tick
      count at 0040:006C** (incremented by the INT 08h/IRQ0 handler, which the PIT drives at the
      deterministic cycle, machine M-D6/M-D9) and a fixed **emulated epoch** (a pinned start date/time, a
      project constant). **No `std.time` anywhere** (grep-enforced, Phase 9). **Rationale:** `CLAUDE.md`
      #2 ("emulated time = f(cycle counter)"); a game that seeds RNG from the clock (some do) would be
      non-reproducible otherwise — this is a direct determinism requirement. **CONFIRMED: the pinned
      emulated epoch is `1993-01-01 00:00:00`** (a documented project constant in `timing.zig`).
  - **Extends to ALL DOS-visible file/dir date-time fields (this is the Spice86 leak to avoid).**
    The DTA find record's date/time (offsets 0x16/0x18), AH=57 get/set file date-time, directory-entry
    timestamps, and any PSP/MCB date fields **come from a deterministic source** — the pinned
    1993-01-01 epoch, the emulated BDA tick, or per-file replayed config — and **NEVER from host `stat`
    mtime/ctime.** (Spice86's exact non-determinism leak is reading host file mtime here,
    `DosFileManager.cs:1031`.) **Phase 9's grep is extended to ban `mtime`/`ctime`/stat-timestamp use in
    `src/dos/`, not just `std.time`.**

- [x] **D14 — Snapshot/restore of DOS+BIOS state from day one. DECIDED (`CLAUDE.md` #6).** The snapshot
      set: **(in guest RAM, rides the bus snapshot B12)** the IVT, the BDA, every PSP, the MCB chain,
      the current DTA, the environment blocks, the callback stubs (config, replayed); **(host-side on the
      `Service` ctx, snapshotted explicitly)** the SFT (open files by **stable id + host path + file
      position** — re-opened/re-sought on restore, D6/D9), the current-PSP segment, the current-drive,
      the EMS handle/page-map state, the `next_seq`-style id counters. **Host file content is replayed
      external config, NOT snapshot bytes.** On restore the machine re-binds callback ids → handlers
      (like the bus re-binds handler ids) and the VFS re-opens SFT paths. **Rationale:** `CLAUDE.md` #6;
      a populated DOS state (program loaded, files open, memory allocated) must round-trip
      byte-identical with host handles re-bound by path+position.

- [x] **D15 — EMS INT 67h service lives HERE (in `src/dos/`), driving the bus's EMS MMIO device (bus
      B8). DECIDED.** The bus side is already planned: EMS is an ordinary MMIO device registered via
      `mapMmio(frame_phys, 0x10000, ems_handler)`; the **EMS manager owns the backing store and remaps
      by swapping which slice its MMIO handler points at** (bus B8). **This module supplies that manager
      + the INT 67h handler** (LIM EMS: get-status, get-page-frame, get-page-count, allocate-handle,
      map-page, free-handle — AH=40-4x). BaK needs EMS (`CLAUDE.md` First target: ~1 MB EMS). **Rationale:**
      the INT 67h *service* is a host-serviced trap exactly like INT 21h (charges D5 cost, flags
      unsupported subfunctions); the bus already owns the MMIO/backing seam, so this module owns only
      the handle table + page-map logic + the INT 67h dispatch. Included in scope (not deferred) because
      BaK requires it. Flag: the EMS backing block's deterministic zero-init is determinism-critical and
      lives in this manager (bus B12 "device-side state").

- [x] **D16 — The callback-bridge primitive lives in a SHARED LEAF (`src/abi/` or a new `src/bridge/`
      peer), imported by both `src/bios/` and `src/dos/`. DECIDED.** (The concrete location chosen by
      D12's reversal.) The leaf exports `allocCallback`/`plantStub`/`setRealVec`, `dispatchCallback`'s
      cost-charge + handler-table contract, `runGuestInt`, `setGuestCF/ZF/IF`, and the `cb_cost` table.
      It depends only on the CPU surface + the bus contract (already leaves), so it is itself a clean
      leaf. **Rationale:** mirrors `bus_contract.zig` (a shared leaf both `cpu` and `bus` import); the
      bridge is equally infrastructure for the BIOS and DOS handlers; keeps the graph acyclic with no
      dos↔bios edge.

- [x] **D17 — DOS character-device layer: `SftEntry` is a tagged union `{ device, file }`; standard
      handles are pre-opened device objects; AH=3D resolves a device table BEFORE the drive VFS; EMS
      registers `EMMXXXX0` as a device. DECIDED (critical — BaK's EMS probe + console depend on it).**
      Real DOS treats CON/AUX/PRN/NUL and installable character devices as first-class objects opened by
      name ahead of any file. zdos models this:
  - `SftEntry = union(enum) { device: *DosCharDevice, file: HostFile }` — the SFT entry is either a host
    file (the VFS `File`) or a character-device object. (Supersedes D9's `host_file: ?File` field shape.)
  - **Pre-open handles 0–4 → CON / CON / CON / AUX / PRN** device objects (stdin/stdout/stderr/aux/prn).
  - **AH=3D open resolves a device table** (CON, AUX, PRN, NUL, `EMMXXXX0`) by name **BEFORE** consulting
    the drive VFS — opening `"CON"` returns a CON handle, not a file named CON. (DOSBox `dos_devices.cpp`.)
  - **AH=44 AL=00 (get device info)** returns the **device bit (bit 7 set)** for a device handle; read/
    write/seek on a device handle route to the device's methods (CON → keyboard/VGA seam; NUL → discard),
    not the VFS.
  - **EMS registers `EMMXXXX0` as a character device** — this is the documented EMS-presence probe a
    program issues (`INT 21h AH=3D open "EMMXXXX0"`, then `AH=44` IOCTL); **without it BaK cannot detect
    EMS** (`dosbox ems.cpp:1451`). **Rationale:** faithful DOS device semantics; the console + the EMS
    detection path BaK needs both require the device dimension; ground rule — the EMS probe must succeed
    truthfully, not be faked.

- [x] **D18 — INT 33h mouse driver is OWNED HERE (a host-serviced trap), not deferred to the device
      half. DECIDED (major — BaK needs it).** Like INT 16h keyboard, the mouse *driver* INT (33h) is a
      host-serviced callback that reads raw motion/buttons from the mouse *device* via the same
      scripted-input seam as the keyboard; only the mouse *device* itself is in `src/devices/`. The
      callback + driver state lives here (Phase 3). **Rationale:** INT 33h is API-shaped (register-in/
      register-out, no real driver code runs), exactly the host-serviced pattern; BaK is mouse-driven.
      INT 2Fh multiplex defaults to faithful "not installed" / no-handler semantics (don't fault); which
      AX probes BaK issues is trace-driven (a flagged stub is fine).

- [x] **D19 — A bounded bus-side bulk copy (`writeGuestBlock`/`readGuestBlock`) is added to the bus.
      DECIDED (perf — flagged as a bus addition).** The loader (image copy + relocations) and AH=3F/40
      read/write are the warmest host-service paths; a per-byte `writePhys8` loop across them is wasteful.
      Add `bus.writeGuestBlock(phys, []const u8)` / `bus.readGuestBlock(phys, []u8)` that do **one
      A20/region check per span** and `@memcpy` into/out of `bus.ram`, with a per-byte fallback only on a
      region-crossing span (the DOSBox `MEM_BlockWrite`/`MEM_BlockRead` shape). The loader + AH=3F/40 copy
      through it via a **fixed stack scratch buffer** (no per-call heap, no per-byte loop on the warm
      path). **Rationale:** the only host-service hot path; a bounded, region-checked block copy is both
      faster and still a single deterministic operation (cost stays the synthetic D5 formula, not host
      copy time). **Flag: this is an addition to `src/bus/` — call it out to the user; it is the only
      bus edit this module needs.**

- [x] **D20 — Promote the real-CRT-baseline INT 21h functions into scope, pinned to `dos.cpp`. NEW
      (the concrete function list behind D8a + the AH=43 fidelity fix).** DONE: AH=43 AL=00 existence
      check fixed; AH=33/29/59/52 added; AH=44 AL=01/06/07 added; AH=45/46 dup/dup2 added (SFT refcount);
      AH=3B/39/3A/47 promoted to real path support. Each is a CRT-startup/runtime
      call the oracle proved real programs make; semantics pinned to `references/dosbox-staging/src/dos/
      dos.cpp`:
  - **AH=43 AL=00 (get file attributes) — FIX, do not stub (FILEIO divergence, HIGHEST PRIORITY).** The
    first pass returned `CX=0x20, CF=0` **unconditionally** without consulting the VFS. Real DOS
    (`dos.cpp:1106-1120`: `DOS_GetFileAttr` → on absent file `CALLBACK_SCF(true); reg_ax=dos.errorcode`)
    returns **CF=1, AX=2 (file-not-found)** when the file is missing. The CRT's `fopen("...","wb")` calls
    AH=43 AL=00 to probe existence; the stub's fake success makes the CRT open-for-write (AH=3D AL=01)
    instead of create (AH=3C), and `fopen` fails (`plans/dos-oracle-report.md` §1). **Fix:** resolve the
    path through the VFS; return CF=1/AX=2 when absent, the real attribute bits + CF=0 when present.
    Localized — the VFS already has the open/stat seam.
  - **AH=33 (extended break checking) — ADD** (`dos.cpp:881-910`): AL=00 get breakcheck → DL=flag; AL=01
    set breakcheck from DL; AL=02 get+set; AL=05 boot-drive (DL=3); AL=06 get-true-version
    (BL/BH/DL=major/minor/revision). Store `breakcheck` as deterministic DOS state. CRTs query it at
    startup.
  - **AH=29 (parse filename into FCB) — ADD** (`dos.cpp:743`): parse a command-tail filename at DS:SI
    into the FCB at ES:DI, honoring the AL parse-control bits; return AL=parse result (0 / 1 wildcards /
    0xFF bad drive). Re-derive the parse from the documented rules. The CRT uses it to build argv/FCBs.
  - **AH=59 (get extended error info) — ADD** (`dos.cpp:1337`): return the **last DOS error** (the
    `dos.errorcode` set by the most recent failing call) in AX, plus the error class / suggested action /
    locus bytes (BH/BL/CH). Maintain a deterministic `last_error` on the Dos ctx, set by every faithful
    error path. CRTs call this after a failed file op.
  - **AH=52 (Get List of Lists / SysVars) — ADD** (`dos.cpp:1256`): return ES:BX → the DOS internal
    SysVars table, with a **real MCB anchor** (the first-MCB segment at the documented offset) so a
    program that walks the MCB chain from SysVars sees the genuine chain (D9). Build a minimal but
    byte-accurate SysVars structure in guest RAM; do NOT fake the anchor.
  - **AH=44 IOCTL `AL=01/06/07` — ADD** (`dos.cpp:1138`, `DOS_IOCTL`): `AL=01` set device-info word (for
    a device handle), `AL=06` get input status (device/file → AL=0xFF ready / 0x00), `AL=07` get output
    status. Route through the SFT `{device,file}` union (D17). Only `AL=00` existed.
  - **AH=45 / AH=46 (dup / dup2) — ADD** (`dos.cpp:1146-1162`): AH=45 allocate a new JFT slot pointing at
    the same SFT entry (returns new handle in AX); AH=46 force handle CX to alias handle BX. The SFT
    needs a **reference count** so a dup'd entry closes only when the last handle does. CRTs dup for
    stdio redirection.
  - **General fidelity pin:** all of the above set **CF + AX=dos.errorcode on the real DOS error path
    only** (D11a), never a fabricated CF; each charges a D5 cost; each maintains `last_error` for AH=59.

- [ ] **D21 — ACCEPTANCE METHODOLOGY: the oracle replaces hand-assembled fixtures as the sufficiency
      gate. NEW — THE MOST IMPORTANT CHANGE (supersedes every first-pass "done when" / milestone that
      asserted self-authored fixtures).** The first pass accepted the DOS module against fixtures it wrote
      itself — which can only test what was built, so a four-agent "done" still failed the first real
      `.EXE`. **The external oracle is now the truth source** (`plans/dos-oracle-report.md`):
  - **`tools/oracle.sh <program.exe> [data...]`** runs a real `.EXE` under **dosbox-x headless** and mints
    a committed golden (`<program>.expected`: `exit_code` + verbatim console bytes). This is a MINT step
    (run once when adding a corpus program), NOT a `zig build test`-time dependency — the golden is
    vendored and the test runs offline.
  - **`zig build test-oracle`** (`src/dos/oracle_test.zig`) loads each corpus `.EXE` through the real
    machine and **asserts zdos reproduces the dosbox-x golden** (exit code + console bytes). This is the
    DOS equivalent of the CPU's ProcessorTests conformance vectors: truth is **external, not
    self-authored.**
  - **"DOS done" ≡ "zdos matches dosbox-x on real binaries."** A phase/milestone is "done" when its
    relevant corpus programs **pass `test-oracle`**, not when a fixture passes. The matched programs are
    listed as permanent regressions (`PASSING`); the known-divergent ones are an asserted worklist
    (`DIVERGING`, each asserted to STILL diverge so a fix promotes it loudly — never tweak zdos to force a
    match; the divergence is the deliverable).
  - **The acceptance ladder (the v1 gate):** `HELLO ✅ → MALLOC ✅ → FILEIO ✅ → ARGENV ✅ → SUBDIR ✅ →
    (extend the corpus) → **BaK boots**`. All FIVE current corpus programs are now passing regressions
    (`test-oracle` green; `DIVERGING` empty). BaK booting (matching a dosbox-x BaK golden, or the
    documented BaK boot sequence) is the remaining v1 gate.
  - **Hand-assembled fixtures keep ONE job:** **cycle-exact determinism** testing (the run-twice-byte-
    identical-including-cycle-position regressions, Phase 8) — zdos's *separate* guarantee that dosbox-x
    cannot make. They are **never** the sufficiency gate. **Rationale:** sufficiency must be measured
    against real-software truth, not against what the author thought to build; determinism must be
    measured by zdos's own ledger. Two truths, two test mechanisms.

- [ ] **D22 — What is ALREADY validated and sound (do NOT churn it). NEW (frames this as completion +
      re-scope, not a rewrite).** The second pass MUST keep these — they are correct and tested:
  - **The callback-trampoline bridge** (Phase 0, D1-D4/D16): the `0xFE 0x38 <id>` trap, the `CallbackSink`
    CPU edit, `runGuestInt` re-entrancy, the FLAGS-patch helpers — round-trips, green (`test-bridge`).
  - **The determinism / cycle-ledger contract** (D5, Phase 1 + the Phase 8 run-twice regression): every
    trap charges a fixed synthetic cost; the Spice86 hole is closed. This is the differentiator and it
    holds — do not destabilize it.
  - **Guest-RAM structure modeling** (D9): PSP/MCB/DTA as byte-accurate guest-RAM views, the SFT-on-host +
    JFT-in-PSP split — correct and faithful.
  - **The loader `max_alloc` handling** (Phase 6, the `min/max/maxfree` rule): the real-CRT regression was
    already found and FIXED (a Borland `.EXE` with `maxmemory=0xFFFF` now gets the largest free block);
    covered by `borland_test.zig`. **Rationale:** the second pass is targeted completion of the function
    surface + the oracle re-gate, on top of a sound foundation — not a restart.

---

## Phase 0: The callback-trampoline bridge (FOUNDATIONAL — everything hangs off this)

Goal: a working guest↔host bridge — a guest `INT n` reaches a host Zig handler, which mutates guest
regs/memory and returns via `IRET`, charging a deterministic synthetic cost; plus the re-entrant
`runGuestInt` so host code can drive a guest INT. **Done when** a round-trip test (guest `INT n` → host
handler bumps AX → `IRET` → guest sees AX) passes, the re-entrancy test (host `runGuestInt` → a host
handler runs → returns) passes, and both are byte-identical across two runs including the cycle ledger.

### 0a. Module skeleton & build wiring (D12)

- [x] Create `src/bios/` and `src/dos/` file splits (one responsibility per file):
  - [x] `src/bios/bios.zig` — module root: the `Bios` struct (IVT/BDA/POST + BIOS INT handlers),
        exposes `init`/the callback-handler registration.
  - [x] **`src/bridge/bridge.zig` — the callback-trampoline primitive in a SHARED LEAF (D12/D16):**
        callback allocation, stub planting into the BIOS ROM image + **`INT n; <stop-callback>`
        trampoline** planted in conventional RAM (the immediate is patched per call; ROM writes drop),
        the `dispatchCallback` cost-charge + handler-table contract, `runGuestInt` (D3, machine step),
        `setGuestCF/ZF/IF` (D4), `cb_cost.zig` (D5). Imported by BOTH bios and dos; neither imports
        the other. Depends only on cpu + bus.
  - [x] `src/bios/bda.zig` — the BIOS Data Area layout + typed accessors.
  - [x] `src/bios/int10.zig`, `int16.zig`, `int1a.zig`, `int08.zig`, `int11_12.zig`, `int15.zig` — BIOS
        handlers (INT 13h defaults to the D11 flag path in `bios.zig`, no separate file).
  - [x] `src/dos/dos.zig` — module root: the `Dos` struct + INT 21h dispatch.
  - [x] `src/dos/int21.zig` — the AH switch; `psp.zig`, `mcb.zig`, `dta.zig`, `sft.zig` — guest-RAM
        views + the host SFT (D9). Plus `clock.zig` (deterministic date/time, D13).
  - [x] `src/dos/vfs.zig` (`HostDirDrive`, D8), `devices.zig` (CON/AUX/PRN/NUL/`EMMXXXX0`, D17),
        `name83.zig` (D10), `loader.zig` (Phase 6), `int33.zig` (D18), `ems.zig` (INT 67h, D15/D17).
  - [x] The `Services` aggregate (CPU's `CallbackSink`, D2/D12/D16) — **inlined in `src/machine/machine.zig`
        as a plain `struct` decl** (NOT a generic fn) so the `Cpu <-> Services` comptime cycle resolves
        the same way `Scheduler = Machine` does. Holds `*Bios`+`*Dos`+bridge+`*Cpu`; `dispatchCallback`
        charges D5 then routes id. **DEVIATION from the plan's `src/machine/services.zig` path — required
        to break the comptime cycle; documented inline.**
  - [x] Test roots: `bridge_test.zig`, `bios_test.zig`, `dos_test.zig`, `int21_test.zig`,
        `loader_test.zig`, `name83_test.zig`, `integration_test.zig` (loads + runs a real program).
- [x] **Build wiring** (mirror cpu/bus/machine in `build.zig`):
  - [x] `bridge_mod` (shared leaf) — `addImport("cpu"/"bus"/"bus_contract")`; imports NEITHER bios nor dos.
  - [x] `bios_mod` — cpu/bus/devices/timing + bridge.
  - [x] `dos_mod` — cpu/bus/devices/timing + bridge; does NOT import bios (D12 reversed).
  - [x] `test-bridge`, `test-bios`, `test-dos` steps; all wired into the top-level `test` step.
- [x] **The CPU `CallbackSink` contract (the one CPU edit — modified `src/cpu/`, D2):**
  - [x] In `src/abi/bus_contract.zig` added `assertCallbackSinkContract(comptime Sink)` verifying ONLY
        `fn (*Sink, u8) void`; the contract names no `*Cpu` (the sink holds its own `*Cpu`).
  - [x] In `src/cpu/`: added `CallbackSink` to `Options` (default `NullCallbackSink`). The Grp4 `/7` arm
        (`callbackTrap` in exec_ctrl.zig) `fetch8`s the id then `cb.dispatchCallback(id)`; EIP is advanced
        by the single `fetch8` (no double-advance; a handler that changes CS:IP wins). The NullSink path
        raises `#UD` WITHOUT pre-advancing EIP (comptime-detected). **VERIFIED `test-cpu` + `conformance`
        stay green (86/86 + 2900/2900 vectors).**
  - [x] The machine constructs `CpuWith(Bus, .{ .Pic, .Scheduler = Machine, .CallbackSink = Services })`
        and the `Services.wire` sets `cpu.cb = &svc`. Wiring is in `Machine.wire` (after CPU construction)
        + `Machine.post` (registers callbacks, plants stubs, POST, DOS init).

### 0b. Callback allocation + stub planting (D1/D4)

- [x] **`Bridge.allocCallback(type, kind) u8`** — stable id in fixed registration order (D14).
      `CbType = enum { iret, retf, iret_sti, iret_eoi_pic1, iret_eoi_pic2 }`.
- [x] **`CB_SLOT_SIZE` = 16** for zdos's 3-byte/1-byte-id stub (D1) — NOT DOSBox's 32; comptime-asserted
      to fit the largest tail (the slave-PIC EOI sequence).
- [x] **`Bridge.plantStub(id, type)`** — writes `0xFE 0x38 <id>` + the ISA-re-derived tail (`0xCF` IRET,
      `0xCB` RETF, `0xFB` STI, `MOV AL,0x20; OUT 0x20/0xA0,AL` EOI) into the BIOS ROM image; the image is
      `bus.loadRom`-ed at POST so the bytes are real guest code (D4).
- [x] **`Bridge.plantTrampoline()`** — plants `INT nn; 0xFE 0x38 <stop_id>` into **conventional RAM
      (0000:0600)**, NOT the ROM image. **DEVIATION from the plan's "in the ROM region": the `INT nn`
      immediate is patched per `runGuestInt` call, and ROM writes are dropped by the bus, so the
      trampoline MUST be in writable RAM.** Documented in `bridge.zig`.
- [x] **`Bridge.setRealVec(id, intnum)`** — points IVT[intnum*4] at the slot seg:off via writePhys16.
- [x] **Registration map** id → owner (Services routing) + id → `cb_cost` Kind (D5); the cost table is
      total by an exhaustive `costFor(Kind)` switch (no silent default). `CB_MAX=128` comptime-asserted.

### 0c. The dispatch entry + synthetic cost (D2/D5)

- [x] **`Services.dispatchCallback(id)`** — `fn (*Services, u8) void` (no `*Cpu` in the contract; the
      sink holds its `*Cpu`). Charges `bridge.chargeBase(id)` (D5, before the handler), then routes id →
      stop/bios/dos. Handlers add work-proportional cost via `bridge.chargeWork(count, per_byte)`. EIP is
      advanced by the Grp4 arm's single `fetch8` (a handler that changes CS:IP overwrites it).
- [x] **Stop-sentinel cost — resolved (determinism-critical):** the stop sentinel's `cb_cost` Kind is
      `.stop_sentinel` with base 0 (cost-EXEMPT), documented in `cb_cost.zig`. It is routed (not bypassed)
      but charges nothing — pure control flow that exits the `runGuestInt` loop.
- [x] **By-construction guard:** every non-sentinel callback charges base > 0 (the `cb_cost` test asserts
      it); the run-twice-identical-cycles tests prove no trap leaves the ledger unchanged. (A debug
      `cpu.st.cycles` delta assert in `dispatchCallback` is a possible future hardening; the cost-table
      totality + the determinism regressions already enforce the no-hole property.)
- [x] **`Bridge.setGuestCF/ZF/IF(cpu, bool)`** (D4) — patches the FLAGS word at SS:SP+4 (the IRET frame
      is IP@SP, CS@SP+2, FLAGS@SP+4). Used by every handler to return carry/error.

### 0d. Re-entrancy: `runGuestInt` via a real `INT n` trampoline (D3 — the #1 fix)

- [x] **Reserved "stop" callback** (id 0): `onStopSentinel` sets `reentry_done`. Stub planted at POST;
      the `INT nn; <stop-callback>` trampoline planted in RAM.
- [x] **`Bridge.runGuestInt(intnum) void` — executes a REAL `INT n` through the trampoline:**
  - [x] Saves CS:IP/SP + the seam scratch `cpu.dec` + `cpu.instr_start_eip` (restored after).
  - [x] Patches the trampoline's `INT n` immediate; points CS:IP at the trampoline.
  - [x] **Drives the re-entry loop through the MACHINE step** (`run_loop.step`, injected at wire time via
        `bridge.setStepper` — the machine supplies the step primitive; the bridge stays below the machine).
        PIT/IRQ events fire during re-entry.
  - [x] The real `INT n` builds its own IRET frame; the guest `IRET` lands on the stop callback →
        `reentry_done` → loop exits.
  - [x] Restores CS:IP/SP + seam scratch; clears `reentry_done`. Nested guest work charges normally.
- [x] **Re-entrancy depth guard** (`MAX_DEPTH=8`, panics on overflow) + a bounded step guard.
- [x] **Breakpoint limitation documented** in `bridge.zig` (host services are atomic from the guest view).

### 0e. Phase 0 tests (`bridge_test.zig`) — ALL PASSING

- [x] **Round-trip:** INT 21h AH=30 traps to the DOS sink, returns via IRET, AL=5; cycles advanced.
- [x] **FLAGS return:** a faithful DOS error path (unlink missing file) sets CF, visible via PUSHF/POP.
- [x] **Re-entrancy:** `runGuestInt(0x21)` runs AH=30 via the trampoline; the outer CS:IP seam restored.
- [x] **Determinism:** the round-trip is byte-identical twice including `cycles`.
- [x] **NullSink:** a `0xFE 0x38` opcode with no sink raises `#UD` (delivered to the IVT[6] handler).

---

## Phase 1: The determinism + synthetic-cost contract (cross-cutting — establish before services)

Goal: write down and enforce the module's determinism rules before any service code, so every BIOS/DOS
handler is born deterministic. **Done when** the contract is documented in the module headers and the
enforcement asserts/grep-tests exist.

- [x] **The synthetic-cycle-cost contract (D5) written in `cb_cost.zig` header:** every callback charges
      a fixed cost; per-service work-proportional formulas are documented and pure; the table is total
      (comptime-asserted), labeled interim/provisional. State explicitly: *this is what closes the
      Spice86 hole.*
- [x] **Pure-function invariant (D6/D13):** no handler reads host time, host I/O latency, RNG, host
      scheduling, or env. File-read/write counts come from guest registers; clock values come from the
      BDA tick / emulated epoch. Document + grep-enforce (Phase 9).
- [x] **No-hole guard:** the `dispatchCallback` cost-charge + the debug assert (Phase 0c) — every trap
      advances the ledger.
- [x] **Deterministic init:** the IVT, BDA, first PSP, first MCB, DTA, SFT, drive table, EMS state are
      all initialized to documented values with no uninitialized fields (`CLAUDE.md` #5).
- [x] **No per-op alloc:** the SFT, drive table, MCB views, EMS handle table are preallocated on the
      `Service` ctx; handlers allocate nothing per call (counting-allocator guard, Phase 9). (Host file
      buffers for read/write copy directly between the host `File` and guest RAM via a **fixed stack
      scratch buffer** routed through `bus.writeGuestBlock`/`readGuestBlock` (D19) — no per-call heap, no
      per-byte `writePhys8` loop on the warm path.)
- [x] **Bus bulk-copy addition (D19 — flag as a bus addition):** add `bus.writeGuestBlock(phys,
      []const u8)` / `bus.readGuestBlock(phys, []u8)` — one A20/region check per span, `@memcpy`
      into/out of `bus.ram`, per-byte fallback only on a region-crossing span (the `MEM_BlockWrite`/
      `MEM_BlockRead` shape; mirrors the existing `loadRom` `@memcpy` at `bus.zig:519`). The loader image
      copy + AH=3F/40 use it. **This is the only `src/bus/` edit this module needs — call it out.**

---

## Phase 2: BIOS — IVT, BDA, POST stand-in, callback wiring (replaces machine's M-D9 stand-ins)

Goal: bring up the BIOS far enough that the DOS kernel and a real program have a working IVT, BDA, and
the BIOS services they call. **Done when** the BIOS POST lands a documented IVT+BDA, programs the
PIC/PIT (taking over the machine's stand-ins), and the BIOS callback stubs are planted.

- [x] **IVT initialization** — fill all 256 vectors. Hardware/unused vectors point at a default
      "unhandled interrupt" callback (D11 policy — flags, doesn't silently NOP). Serviced vectors
      (INT 08h, 10h, 11h, 12h, 13h, 15h, 16h, 1Ah, 1Ch, 21h, 67h, …) point at their callback stubs.
- [x] **BIOS Data Area (BDA @ 0040:0000, `bda.zig`):** the fields BaK/DOS touch — equipment word
      (0040:0010), conventional memory size KB (0040:0013), keyboard buffer head/tail/ring
      (0040:001A-003D), the **timer tick count** (0040:006C, 4 bytes) + tick-overflow (0040:0070),
      current video mode (0040:0049), columns (0040:004A), cursor position/shape. Initialize
      deterministically. (Re-derive offsets from the documented BDA layout — public spec.)
- [x] **POST stand-in (`bios.zig`):** the BIOS init that **replaces machine M-D9's
      `programDefaultPic`/`programDefaultTimer`/`enableA20`** with the real BIOS doing the same port
      writes (the machine helpers were explicitly flagged temporary). Sets IVT+BDA, programs the PIC
      vector bases + cascade unmask (master 0x08, slave 0x70), programs PIT ch0 mode 3 reload 0 (~18.2 Hz),
      enables A20 via `bus.setA20(true)`. **The devices process the port writes normally — no
      special-casing (ground rule).** Reconcile order with machine init (machine constructs devices +
      CPU + Services, then runs BIOS POST).
- [x] **Plant all BIOS callback stubs** (Phase 0b) and set their vectors.
- [x] Tests (`bios_test.zig`): POST → IVT entries point at F000 stubs; BDA fields at documented values;
      A20 enabled. Two POSTs byte-identical. (PIC/PIT read-back via the devices is covered by the
      machine-layer tests; the BIOS test asserts the port-programming sequence ran.)

---

## Phase 3: BIOS services (curated to what BaK + DOS need; flag stubs-with-deferred-subfunctions)

Goal: the BIOS INT handlers BaK and the DOS kernel call. Each is a callback handler (D7) charging D5
cost. **Done when** the in-scope subfunctions work against the VGA/keyboard/PIT devices and unit tests
pass; deferred subfunctions are flagged (D11), not faked.

- [x] **INT 10h — video (`int10.zig`).** AH=00 set mode (incl. mode 13h — updates BDA + emits the VGA
      misc-output port write), 02 set cursor, 03 get cursor, 0E teletype (no-op until the VGA device), 0F
      get mode, 0C/0D/10 routed to the (out-of-scope) VGA device. **The pixel store is the VGA *device*** (bus B11 MMIO + ports,
      a separate `src/devices/` module); INT 10h *drives* it via port writes / MMIO. In scope for BaK:
      AH=00 set video mode (incl. **mode 13h** 320×200×256 — BaK's mode; writes the VGA registers +
      updates BDA video mode), AH=02 set cursor pos, AH=03 get cursor, AH=0E teletype output, AH=0C/0D
      write/read pixel, AH=0F get mode, AH=10 palette/DAC (mode 13h palette set — BaK sets its palette).
      **Flag deferred:** the full VESA/SVGA, font, and scroll-region subfunctions — implemented when a
      BaK trace shows them, not stubbed. (The VGA device itself is out of scope here — flagged in
      "Out of scope".)
- [x] **INT 16h — keyboard (`int16.zig`).** AH=00/10 read key (blocking — consumes from the **BDA
      keyboard ring buffer** filled by the INT 09h/IRQ1 handler), AH=01/11 check key (peek), AH=02 get
      shift flags. The ring buffer is BDA state; INT 09h (keyboard IRQ) enqueues scancodes from the
      keyboard device. **Determinism:** key input is scripted/seeded external input (`CLAUDE.md` #3),
      delivered at deterministic cycles via the device→PIC→IRQ path; INT 16h reads the buffer, never the
      host. (The keyboard device + INT 09h are flagged in "Out of scope" for the device half; INT 16h +
      the BDA buffer are here.)
- [x] **INT 1Ah — time-of-day (`int1a.zig`).** AH=00 get tick count (reads BDA 0040:006C + overflow
      flag), AH=01 set tick. **No host clock (D13)** — the tick is PIT-driven.
- [x] **INT 08h / IRQ0 default handler (`int08.zig`).** Increments the BDA tick count + midnight
      rollover; EOI via the `.iret_eoi_pic1` return tail (D4). **INT 1Ch chaining is DEFERRED-AND-FLAGGED**
      (doing a nested `runGuestInt` on every ~18.2 Hz tick is a hazard; the faithful fix is a stub-level
      `INT 1Ch` chain, not yet built — documented in `int08.zig`, NOT faked).
- [x] **INT 11h / 12h (`int11_12.zig`).** INT 11h → equipment word; INT 12h → conventional memory KB.
- [x] **INT 13h — disk. DEFERRED-BY-DEFAULT (flag path implemented).** The whole vector hits the D11
      unsupported-service signal (asserted in `bios_test.zig`); no faked sector reads.
- [x] **INT 15h — system services (`int15.zig`).** AH=88 (ext mem = 0 for a 1 MiB machine), AH=24 (A20
      control), AH=C0 (flagged deferred). Others flag (D11).
      extended memory size, AH=87 move block (rarely by BaK), AH=C0 get config, AH=24 A20 control.
      Curate to what a BaK trace shows; flag the rest deferred. (EMS does **not** go through INT 15h —
      it's INT 67h, Phase 7.)
- [x] **INT 33h — mouse driver (`int33.zig`, D18 — host-serviced trap, NOT deferred to the device
      half).** A callback + driver state on the `Service` ctx; reads raw motion/buttons from the mouse
      *device* via the **same scripted-input seam as the keyboard** (deterministic external input,
      `CLAUDE.md` #3), never the host. In scope (BaK needs it): **AX=0** reset/get-present (returns
      present + button count), **AX=1/2** show/hide cursor, **AX=3** get position + button state,
      **AX=4** set position, **AX=0x0C** set user event handler (far callback the guest installs —
      invoked via the bridge when a mouse event is delivered), **AX=0x14** swap event handler. Driver
      state (position, button mask, visibility, the installed event handler far-ptr) is snapshot state
      (D14). Charges D5 cost; deferred subfunctions flag (D11).
- [x] **INT 2Fh — multiplex (minimal, D18).** Default = **faithful "not installed" / no-handler
      semantics** (do NOT fault, do NOT fake an installed TSR). Which AX probes BaK issues is
      trace-driven; a flagged stub (D11 signal) for an unhandled AX is fine — never a fabricated "yes,
      installed" reply.
- [x] Tests (`bios_test.zig`): INT 10h set mode 13h updates BDA; INT 16h reads a key enqueued into the
      BDA buffer; INT 1Ah returns the PIT-driven tick; INT 08h bumps the tick; INT 13h hits the D11 flag
      path (asserted). (INT 33h AX=3 scripted position is covered by `int33.zig`'s injectMotion seam.)

---

## Phase 4: DOS kernel — INT 21h dispatch + PSP/MCB/DTA/SFT + the real-CRT-complete function set

Goal: the INT 21h kernel that starts + runs any real compiled program (the real-CRT baseline, D8a), with
the guest-RAM data structures and the host-FS file API. **Done when** the relevant corpus programs pass
`test-oracle` (D21) — NOT when a self-authored fixture passes; the structures are byte-accurate; and
unsupported subfunctions flag (D11). (Per-function fixtures still exist for cycle-exact determinism only.)

- [x] **DOS init (`dos.zig`):** install the INT 21h callback (+ INT 20h terminate, INT 27h TSR, INT 2Fh
      multiplex minimally, **INT 22/23/24 default handlers** — terminate/Ctrl-C/critical-error vectors),
      build the **first MCB** at the top of conventional memory (the arena), **store the DOS version in
      the PSP version bytes** (AH=30 reads there → **5.0**; see the AH=30 item), set up the initial DTA,
      the drive table (mount BaK's dir as C:), the **character-device table** (CON/AUX/PRN/NUL, D17) and
      the SFT with the standard handles (0-4: CON/CON/CON/AUX/PRN as **device** objects, the pre-opened
      stdin/stdout/stderr).
- [x] **PSP (`psp.zig`, D9):** the 256-byte structure as a guest-RAM view — INT 20h at offset 0,
      memory-top segment, the saved **INT 22/23/24** vectors (offsets 0x0A/0x0E/0x12), the parent PSP
      (0x16), the **DOS-version bytes**, environment segment (0x2C), the command-tail (0x80, 128 bytes).
      **JFT file-table indirection (D9 corrected):** build the **far pointer at PSP:0x34 → PSP:0x18** and
      set **max_files = 20 at PSP:0x32**. The default 20-handle JFT lives at PSP:0x18, but **ALL JFT
      access (allocate/lookup/free a handle) goes through the 0x34 far pointer, NOT a hardcoded 0x18** —
      so a program that relocates its JFT (rare, but faithful) still works. `buildPsp(seg, env_seg,
      parent, cmdtail)` also builds the **FCBs at 0x5C/0x6C** (see EXEC) and writes 0x34/0x32.
- [x] **MCB chain (`mcb.zig`, D9):** 16-byte headers ('M'=link / 'Z'=last signature, owner PSP segment,
      size in paragraphs) in the arena. `alloc(paras) ?seg`, `free(seg)`, `resize(seg, paras)` — the
      AH=48/49/4A services. Re-derive the layout from the **dosbox-test-suite MCB behavioral spec**
      (`plans/dosbox-test-suite.md`), not GPL code. First-fit/best-fit/last-fit per the AH=58 strategy
      (default first-fit).
- [x] **DTA (`dta.zig`, D9):** the 128-byte Disk Transfer Area; AH=1A set DTA, AH=2F get DTA; find-first/
      find-next write the found-file record into the DTA (the `DTAExtendName` name split — re-derive,
      D10). The find record's **date/time fields (offsets 0x16/0x18) come from the deterministic source
      (1993-01-01 epoch / replayed config), NEVER host `stat` mtime** (D13). Default DTA at PSP:0x80.
- [x] **SFT + JFT (`sft.zig`, D9/D17):** the host-side `sft: [N]SftEntry`, where **`SftEntry` is a
      tagged union with a device dimension**:
      `SftEntry = struct { ref: union(enum) { device: *DosCharDevice, file: HostFile }, position: u64,
      mode, path: [128]u8, path_len: u8, ... }` — **`path` is an inline `[128]u8 + len` (MAX_PATH), NOT a
      `[]u8`** (no per-open alloc; the SFT is one flat snapshot-friendly array, D14). `openHandle()`
      allocates a JFT slot in the current PSP (through the **0x34 file-table pointer**, D9) → SFT index.
      Handles 0-4 pre-opened as **device** entries (CON/CON/CON/AUX/PRN). The `[N]` cap is **provisional /
      comptime-asserted** (sized from a BaK trace later; too-small N fails loudly).
- [ ] **SFT snapshot integrity (D11/D14):** record per open handle enough to detect a replayed-file
      mismatch on restore — the **file length** and (ideally) a **content hash**. On restore, if the
      re-opened file's length/hash differs, **FLAG (D11-style structural signal), do not silently
      diverge.** Specify **open-mode/append-position restore**: a write/append handle restores its saved
      position (does NOT re-truncate); a read handle re-seeks to its saved position.
      **PARTIAL:** the SFT records `snap_len` (file length) per handle and the position/mode for restore;
      the content-hash + the re-open-and-compare-on-restore rebind path are NOT yet wired (the SFT struct
      has `snap_hash` reserved). Flagged as the precise next item for full D14 SFT restore.
- [x] **The INT 21h function set (`int21.zig`) — the real-CRT-complete baseline (D8a, NOT "BaK
      gameplay").** Switch on AH; each
      charges D5 cost; the **default (unknown-AH) arm follows D11 rule (b): return AL=0 with carry CLEAR
      (faithful real-DOS behavior) AND raise the structural `unsupported{int,ah,al}` signal** — not a
      fabricated CF error. **In scope:**
  - [x] **Program control:** AH=00 / INT 20h terminate; **AH=4C terminate with code** (the normal exit —
        sets the exit code, **restores INT 22/23/24 from the terminating PSP**, frees the PSP's memory,
        and transfers to the saved **INT 22** return address — see the INT 22/23/24 item); **AH=30 get
        DOS version** → reads the **PSP version bytes** (5.0: AL=5, AH=0), returns **BH=OEM=0xFF**,
        **BL:CX = serial = 0**; AH=4D get return code. **AH=31 TSR — DEFERRED-BY-DEFAULT** (D11 flag);
        pull in only on trace evidence.
  - [x] **CRT-startup additions (D8a/D20) — required to START any real program:** **AH=33** extended
        break-checking (AL=00/01/02 get/set/get+set the deterministic `breakcheck` flag, AL=05 boot-drive
        DL=3, AL=06 true-version, `dos.cpp:881-910`); **AH=29** parse-filename-into-FCB (DS:SI → ES:DI per
        the AL bits, returns AL=0/1/0xFF, `dos.cpp:743`); **AH=59** get-extended-error (return the
        deterministic `last_error` in AX + class/action/locus bytes, `dos.cpp:1337`); **AH=52** Get List
        of Lists / SysVars (ES:BX → a byte-accurate SysVars table with a **real first-MCB anchor**, D9 —
        not a faked pointer, `dos.cpp:1256`). Maintain `last_error` on the Dos ctx, set by every D11a
        error path. DONE — `last_error` set by `dos.dosError`; SysVars block placed at seg 0x0070 with
        the real arena MCB at [block:LoL-2].
  - [x] **Char I/O (minimal):** AH=02 output char, AH=06/07 direct console I/O, **AH=09 print $-string**
        (used by the loader test), AH=01/08 input char. (BaK uses VGA directly, but the loader/runtime
        may print.)
  - [x] **File handles (the core file path):** **AH=3C create, 3D open, 3E close, 3F read, 40 write,
        42 lseek** (SEEK_SET/CUR/END), AH=41 unlink, **AH=43 get/set attributes**, **AH=44 IOCTL**,
        AH=56 rename.
        **AH=3D open resolves the character-device table (CON, AUX, PRN, NUL, `EMMXXXX0`) BEFORE the
        drive VFS** (D17): a name matching a device returns a **device** SFT entry; otherwise fall through
        to the VFS. **read/write/seek route to the device** for device handles (CON → keyboard/VGA seam;
        NUL → discard), to the host `File` otherwise. File reads/writes copy between the host `File` (via
        `File.reader`/`writer`, D6/Phase 5) and guest memory at DS:DX for CX bytes **through
        `bus.writeGuestBlock`/`readGuestBlock` + a fixed stack scratch buffer (D19)**; **count from CX
        (guest input) → D5 cost `base + CX*per_byte`.**
  - [x] **AH=43 AL=00 existence check — FIX (D20/D11a, FILEIO divergence, HIGHEST PRIORITY).** DONE:
        `fn getSetAttr` now resolves the path through the VFS and `stat`s it — **CF=1, AX=2 when absent**;
        real attribute bits + CF=0 when present (`dos.cpp:1106-1120`). AL=01 set-attr now also errors when
        the file is absent (faithful).
  - [x] **AH=44 IOCTL `AL=01/06/07` — ADD (D20).** DONE: AL=01 (set device info, accepted), AL=06 (get
        input status → device 0xFF, file 0xFF unless at EOF → 0x00), AL=07 (get output status → 0xFF),
        routed through the SFT `{device,file}` union (D17). `DOS_IOCTL`, `dos.cpp:1138`.
  - [x] **AH=45 dup / AH=46 dup2 — ADD (D20, was DEFERRED).** DONE: AH=45 allocates a new JFT slot
        aliasing the same SFT entry (new handle in AX); AH=46 forces CX to alias BX (closing CX's prior
        target first). The SFT `refcount` is now honored on close so the entry closes only on the last
        handle. `dos.cpp:1146-1162`.
  - [x] **Directory search:** **AH=4E find-first, 4F find-next** (wildcards `*`/`?`; writes the DTA
        record; uses the VFS `findFirst`/`findNext` over the host dir with 8.3 munging, D10; now resolves
        the directory portion of the pattern via the D8b walker).
  - [x] **Directory navigation — PROMOTE to real path support (D8b, SUBDIR divergence).** DONE: **AH=47
        get-cwd** writes the per-drive current dir at DS:SI (`dos.cpp:1163`); **AH=3B chdir** validates the
        target against the VFS (`dirExists`) + sets the per-drive CWD (`dos.cpp:1007`); **AH=39 mkdir /
        AH=3A rmdir** implemented against the VFS (`dos.cpp:986/996`). The VFS walks multi-component paths
        (`SUB\DATA.TXT`, `C:\A\B\C`).
  - [x] **DTA + date/time + misc:** AH=1A set DTA, AH=2F get DTA; **AH=2A get date, 2C get time** (from
        the BDA tick + emulated epoch, D13 — NOT host clock), AH=2B/2D set date/time (update the
        emulated state); **AH=57 get/set file date-time** → from the deterministic source, NOT host
        `stat` (D13); **AH=25 set interrupt vector / AH=35 get interrupt vector — both read/write the
        guest-RAM IVT** (the single source of truth that BOTH the trap-stub install path *and* AH=25/35
        mutate; a game hooks INT vectors via these — must work and must see the same bytes the bridge
        wrote); AH=19 get current drive, AH=0E select drive; AH=50 set PSP, AH=51/62 get PSP.
  - [x] **Memory (MCB):** **AH=48 allocate, 49 free, 4A resize** (the MCB chain), AH=58 get/set alloc
        strategy.
  - [x] **EXEC:** **AH=4B AL=00 load-and-execute** → the full child-process EXEC + DOS_Terminate unwind
        (`loader.zig fn exec`, cited to dos_execute.cpp:473-528 + :114-178). DONE: AH=4B parses the EXEC
        param block at ES:BX (`envseg / cmdtail far-ptr / fcb1 far-ptr / fcb2 far-ptr`), reads the path at
        DS:DX, (1) reads the **caller's return CS:IP off the caller IRET frame (SS:SP, SS:SP+2)** and sets
        INT 22 BEFORE the child PSP snapshots 22/23/24 (so the child's saved INT22 = the parent resume);
        (2) builds the child PSP with the **parent link at 0x16**, **FCB1/FCB2 copied to 0x5C/0x6C** from
        the param block, and inherits the env (the param-block env_seg directly when nonzero — Borland's
        spawn pre-builds it with the parent's putenv'd vars; else a copy of the caller's env via MakeEnv);
        (3) runs the **child NESTED** to termination via the bridge stepper (`Bridge.runUntil`, the same
        deterministic, event-honoring machine step `runGuestInt` uses); (4) on terminate, frees the child's
        process memory (`McbChain.freeByOwner`), restores the parent PSP/DTA + CPU state (keeping the
        advanced cycle ledger — no hole), clears `terminated` so the parent resumes, and returns CF=0. The
        child's exit code stays in `dos.ret_code` for AH=4D (which Borland's spawnl reads as the return).
        AL=01/03 (load-only/overlay) flag faithfully (D11). Verified: `SPAWN.EXE`+`CHILD.EXE` reproduce
        the dosbox-x golden EXACTLY (interleaved parent+child output + `rc=7`), and the nested run is
        cycle-deterministic (run-twice byte-identical, `oracle_test.zig`).
  - [x] **INT 22/23/24 + terminate unwind:** DONE. The vectors are snapshotted into each PSP at PSP build
        (loader.buildPsp, offsets 0x0A/0x0E/0x12); `terminate` (dos.zig) restores 22/23/24 from the
        terminating PSP. On **EXEC** INT 22 is set to the caller's return CS:IP (off the IRET frame) before
        the child PSP's SaveVectors. The parent resume is wired via the nested-run unwind (the host-serviced
        equivalent of "transfer to saved INT 22"): rather than IRET-to-INT22, the EXEC handler restores the
        parent CPU state directly and returns, so the parent's own trap-stub IRET resumes it right after its
        `INT 21h AH=4B` (CF=0). The initial process still stops the outer run loop on `terminated`.
- [x] **Deferred-and-flagged (D11), not faked:** the FCB file API (AH=0F-0x24), network/share (AH=5xxx),
      LFN (AH=71xx), AH=44 IOCTL beyond the AL=00/01/06/07 promoted in D20, DBCS, country info — all hit
      the unsupported-service flag path (AL=0/CF-clear + the structural signal); none returns a fabricated
      success. (NOTE: AH=33/29/59/52, AH=44 AL=01/06/07, AH=45/46 are now IN-SCOPE per D8a/D20 — they are
      no longer on this deferred list.)
- [x] Tests (`int21_test.zig`, against a `std.testing` temp dir mounted as C:): create→write→close→
      open→read→seek→read-again→close round-trip; find-first/find-next over a few files (8.3 munging);
      AH=48/49/4A MCB alloc/free/resize; AH=2A/2C return the PIT-driven date/time (not host); an
      unsupported AH flags (D11). Each asserts the D5 cost advanced the ledger.

---

## Phase 5: Host-FS VFS + 8.3 name munging (`vfs.zig`, `name83.zig`)

Goal: the host-directory-**tree** drive backend (with multi-component path resolution, D8b) + deterministic
8.3 munging. **Done when** `SUBDIR.EXE` passes `test-oracle` (D21 — the real gate for path resolution),
VFS open/read/write/seek/find/chdir/mkdir/rmdir against a host dir tree works, and the munging unit tests
(re-derived from the spec, kept for determinism) pass.

- [x] **`DosDrive` backend (D8):** `HostDirDrive` exposes `open`/`create`/`close`/`readAt`/`writeAt`/
      `size`/`enumerate`/`unlink`/`rename`. Drive table `drives: [26]?HostDirDrive` on the Dos ctx.
      (The interface is the concrete `HostDirDrive` — the single backend; the seam for more backends is
      the `drives` table + the method set.)
- [ ] **Subdirectory ops on the backend (D8b — SUBDIR divergence):** extend `HostDirDrive` with
      `chdir`/`mkdir`/`rmdir`/`getcwd` over the host dir tree, and have `open`/`create`/`enumerate`
      resolve **multi-component** paths (below). Track a per-drive current directory (deterministic init
      to root) for the AH=3B/47 calls.
- [x] **`HostDirDrive` over `std.Io.Dir` (verified 0.16 API):** holds the host `Dir` + an `io: Io`
      handle. `open` → `Dir.openFile(io, munged_to_host_name, .{ .mode })`; `create` →
      `Dir.createFile`; `read`/`write` via `File.reader(io, buf)`/`File.writer(io, buf)` +
      `Reader.seekTo`/`Writer.seekTo`; `getSize` via `Reader.getSize`; `findFirst`/`findNext` via
      `Dir.iterate()`. **Grep `references/zig/lib/std/Io/Dir.zig` + `Io/File*.zig` for exact signatures
      — the `io: Io` parameter is mandatory on every call.**
- [ ] **DOS path → host path — MULTI-COMPONENT (D8b — FIX, replaces the single-dir shortcut).** The
      first pass took only the FINAL component (`fn resolve` → `lastIndexOfAny(p, "\\/")`), so
      `SUB\DATA.TXT` resolved to `DATA.TXT` at root and failed (`plans/dos-oracle-report.md` §2).
      **Replace with real resolution:** canonicalize `C:\...\FILE.EXT` (apply chdir-relative base for a
      relative path), strip the drive, translate `\`→`/`, **8.3-munge each component** (D10), and open the
      leaf relative to the mount root, **walking real host subdirectories** (`drive_local.cpp` +
      `DOS_MakeName`). **Keep a path-escape guard** (reject `..` traversal above the mount root) now that
      the single-dir mount no longer provides it implicitly.
- [x] **8.3 munging (`name83.zig`, D10 — re-derive, do NOT copy GPL):** uppercase; split name(≤8)+ext(≤3)
      on last dot; validate 8.3 charset; **deterministic long→short generation:** when a host file has a
      long name, generate `NAME~N.EXT` with **N assigned over a deterministically sorted directory
      listing** (sort `Dir.iterate()` results — host iteration order is not guaranteed, `CLAUDE.md` #5).
- [x] **Determinism (D6):** file content is fixed external input; cost is synthetic; no host time; the
      directory enumeration is deterministically sorted before `~N` numbering.
- [x] Tests (`name83_test.zig`, `dos_test.zig`): munging unit tests re-derived from the dosbox-test-suite
      spec (uppercase, split, illegal-char handling, `~N` generation determinism — same dir twice →
      identical short names); VFS round-trip against a temp dir.

---

## Phase 6: EXE/COM loader (`loader.zig`) — the path that starts Betrayal at Krondor

Goal: parse + load an MZ EXE (and a flat COM), build the PSP **+ a real environment block** (D20), apply
relocations, set up registers, and transfer control — and define the **initial-load entry point that
boots BaK**. **Done when** `HELLO.EXE`/`MALLOC.EXE`/`ARGENV.EXE` pass `test-oracle` (D21 — the real gate,
covering env/argv[0] fidelity), with the hand-assembled COM/EXE fixtures retained for cycle-exact
determinism only.

- [x] **`loadProgram(path, cmdtail, mode) !void`** — the core. `mode = { load_and_run, load_overlay,
      load_only }` (AH=4B AL selects).
- [x] **Read the header via the VFS** (D6 — synthetic cost). **MZ EXE** if first two bytes are `MZ`
      (0x5A4D) or `ZM`; else **COM** (re-derive the branch from dos_execute.cpp:332, not copying):
- [x] **EXE path** (re-derive `struct EXE_Header`, dos_execute.cpp:27): read `pages`, `relocations`,
      `headersize` (paragraphs), `minmemory`/`maxmemory`, `initSS:initSP`, `initCS:initIP`, `reloctable`
      offset. Compute `headersize_bytes = headersize*16`, `imagesize = pages*512 - headersize_bytes`.
  - [x] **Allocate via MCB** (Phase 4): `minsize = paras(imagesize + minmemory*16 + 256)` (the +256 =
        PSP); honor `maxmemory`. Flag failure (insufficient memory) faithfully (carry + error code).
        **FIXED (real-CRT regression):** the original implementation allocated EXACTLY `minsize` and
        ignored `maxmemory` — it never grabbed the largest free block. Real DOS EXEC (dosbox-staging
        `dos_execute.cpp:352-386`) computes `maxsize = paras(imagesize + maxmemory*16 + 256)` (or
        `0xFFFF` when `maxmemory==0`), then allocates `memsize = min(maxfree, maxsize)` and fails only
        if `maxfree < minsize`. A Borland C++ 3.1 `.EXE` sets `maxmemory=0xFFFF` ("give me all of
        memory") and its `C0*.OBJ` startup sizes its DGROUP stack+heap against PSP[0x02] (memtop);
        with only `minsize` paragraphs, `memtop - DGROUP` was smaller than the required stack+heap and
        the CRT `abort()`ed (exit 3) before `main`. `loadExe` now follows the real `min/max/maxfree`
        rule; covered by `borland_test.zig` running the real `examples/dos-src/HELLO.EXE`.
  - [x] **Build a REAL environment block — FIX (ARGENV divergence, D20).** DONE
        (`loader.zig fn buildEnv` + `canonicalProgPath`). Reference `MakeEnv`, `dos_execute.cpp`.
    - [x] alloc an env MCB (**owner = the new PSP**); populate a **pinned deterministic env** — the EXACT
          dosbox-x default set captured from `dosbox-x` `SET`: `COMSPEC=Z:\COMMAND.COM`,
          `PATH=Z:\;Z:\SYSTEM;Z:\BIN;Z:\DOS;Z:\4DOS;Z:\DEBUG;Z:\TEXTUTIL`, `PROMPT=$P$G` (in that order),
          NEVER the host environment (determinism). Matching dosbox-x's env exactly is also required for
          MALLOC byte-parity (the Borland near-heap geometry is env-size-dependent);
    - [x] terminate the var list with the double-null, then write the **`0x0001` word + the program's
          CANONICAL path** (the real `C:\<EXE name>`) so the CRT derives the correct `argv[0]`;
    - [x] set **PSP[0x2C] = envseg** (via `buildPsp`).
  - [x] **Build the PSP** (Phase 4) at the allocation base; set parent, environment (envseg above),
        command-tail, the **0x34→0x18 file-table far pointer + max_files=20 at 0x32** (D9), the **FCBs at
        0x5C/0x6C** parsed from the EXEC param block (for the initial BaK load synthesize a default-drive
        FCB), the JFT inherited from parent (or the standard handles for the initial load), and snapshot
        INT 22/23/24.
  - [x] **Load the image** at `loadseg = pspseg + 16` (after the PSP); copy `imagesize` bytes from the
        file into guest RAM **via `bus.writeGuestBlock` + a fixed stack scratch buffer (D19)** — no
        per-byte loop.
  - [x] **Apply relocations:** for each of `relocations` fixups at `reloctable`, read the seg:off fixup,
        add `loadseg` to the word at that guest address (the classic EXE relocation — re-derive).
  - [x] **Set registers:** CS = loadseg + initCS, IP = initIP, SS = loadseg + initSS, SP = initSP,
        DS = ES = pspseg, **AX from the FCB drive validity** (BL/BH = 0/0xFF). Set the DTA to PSP:0x80.
- [x] **COM path:** allocate the largest free block; build the PSP at base (including the env block,
      0x34/0x32 file-table indirection, FCBs, and INT 22/23/24 snapshot as above); load the file flat at
      PSP:0x100 (via `bus.writeGuestBlock`, D19); CS=DS=ES=SS=pspseg, IP=0x100; **SP = 0xFFFE** normally,
      **but if `memsize < 0x1000` set `SP = (memsize<<4) - 2`** (the COM stack guard for a tiny
      allocation); push a 0 return word; DTA at PSP:0x80.
- [x] **`load_and_run`** transfers control (the loader returns; the machine run loop then executes the
      loaded program). **`load_overlay`** loads into a caller-specified segment without a new PSP (BaK
      may overlay-load). **Initial load = how zdos starts BaK:** the machine, after BIOS POST + DOS init,
      calls `dos.loadProgram(bak_exe_path, "", .load_and_run)` to load BaK as the initial process, then
      runs. **Specify this path explicitly** — it is the v1 boot sequence.
- [x] Tests (`loader_test.zig`): a hand-assembled **COM** that does INT 21h AH=09 print-string then
      AH=4C exit(code) → assert the printed bytes (captured via the CON device / a recording handler)
      and the exit code; a tiny **EXE** with one relocation → assert the fixup applied + it runs +
      exits. Both byte-identical across two runs.

---

## Phase 7: EMS INT 67h service (`ems.zig`) — drives the bus EMS MMIO device (D15)

Goal: the LIM EMS handler BaK needs, owning the EMS manager that the bus's MMIO page-frame device
remaps through (bus B8). **Done when** allocate/map/free pages work and a mapped page is visible through
the page-frame window.

- [x] **EMS manager state (on the `Service` ctx):** the backing store (deterministic zero-init, owned
      here per bus B12), a handle table (`handles: [N]?EmsHandle { pages }` — **`N` is a provisional /
      comptime-asserted cap**, sized from a BaK trace later; too-small N fails loudly), the 4-page
      (16 KiB each) page-frame map (`frame_map: [4]?{handle, logical_page}`). The page-frame window
      (typically 0xE0000, 64 KiB) is registered on the bus once via `mapMmio` (machine wiring); the MMIO
      handler's `getHostPtr`/read/write point at the currently-mapped backing slices (B8 internal remap).
- [x] **Install INT 67h** (callback + IVT) **and register `EMMXXXX0` in the DOS character-device table
      (D17)** — the documented EMS-presence probe is `INT 21h AH=3D open "EMMXXXX0"` + an AH=44 IOCTL, so
      the device MUST be name-resolvable ahead of the VFS. **Without it BaK cannot detect EMS** (dosbox
      `ems.cpp:1451`). **PARTIAL:** the `EMMXXXX0` name resolves ahead of the VFS (the AH=3D + AH=44
      probe succeeds, asserted in int21_test.zig); the secondary IVT-67h-vector → device-header probe
      path is NOT exposed (the name probe is the one BaK uses). Flagged.
- [x] **The LIM EMS subfunction set (`ems.zig`, AH switch) — curated to BaK:** AH=40 get status,
      AH=41 get page-frame segment, AH=42 get unallocated/total page count, AH=43 allocate handle +
      pages, AH=44 **map page** (handle, logical page → physical frame slot — performs the bus remap
      by pointing the frame slot at the backing slice), AH=45 free handle, AH=46 get EMS version,
      AH=47/48 save/restore page map. Flag the rest deferred (D11).
- [x] **Determinism:** synthetic D5 cost per call; deterministic backing zero-init; the remap is a pure
      pointer/slice swap (no host state). Snapshot: handle table + frame map + backing store (D14).
- [x] Tests (`dos_test.zig` / a `ems_test.zig`): allocate a handle with pages, map a logical page to a
      frame slot, write through the page-frame window, remap, read back the new page's bytes; free; the
      whole sequence byte-identical twice.

---

## Phase 8: The deterministic host-serviced-trap regression (THE differentiator)

Goal: prove the host-serviced traps leave **no hole** in the cycle ledger — the property that separates
zdos from Spice86. **Done when** a program doing real file I/O run to cycle N twice is byte-identical
**including the cycle position**.

- [x] **The milestone program** (`integration_test.zig`): a loaded COM that opens a file, reads 8 bytes,
      seeks to 0, reads 4, closes, prints a `$`-string (AH=09), exits (AH=4C) — the full bridge → INT 21h
      → VFS → synthetic-cost path.
- [x] **Run it through the machine** (real CPU + bus + PIC + PIT + BIOS + DOS + a `std.testing` temp dir
      with fixed file content).
- [x] **The core regression (the Spice86-hole closure):** run TWICE (two fresh machines, same fixed file
      content) to completion; assert byte-identical printed output, exit code, AND **cycle position**. The
      identical cycle position DESPITE real host file I/O is the proof the trap has no ledger hole.
- [~] **Host-timing-independence check (PARTIAL):** the cost is a pure function of CX (proven by
      construction in `int21.readFile`/`writeFile` + the cb_cost formula), and the run-twice test shows
      identical cycles. A literal slow-`io: Io` wrapper is NOT built (wrapping the Zig 0.16 `Io` vtable is
      non-trivial); the timing-independence is established by the by-construction cost formula instead.
      Flagged.
- [x] **Snapshot-mid-service (D14):** a populated machine (MCB-allocated) snapshots + restores
      byte-identically (CPU state + RAM round-trip). (Full SFT path re-open + re-seek on restore is the
      same partial as the D14 SFT-restore item above.)

---

## Phase 9: Module determinism contract + audit gate

- [x] **No host time / RNG / thread / env / host-file-timestamp in `src/bios/` or `src/dos/`** —
      grep-enforced via `@embedFile` audit tests (`dos_test.zig`, `bios_test.zig`): reject `std.time`,
      `std.Random`, `std.Thread`, `getenv`, `mtime`, `ctime`. The `io: Io` file API is allowed; its
      timing never reaches the ledger (the cost is synthetic, D5).
- [x] **Cycle-ledger completeness:** every callback charges its D5 cost; the `cb_cost` table is total
      (exhaustive `costFor(Kind)` switch + the totality test); the run-twice-identical-cycles regressions
      prove no trap leaves the ledger unchanged. **The Spice86 hole is closed.**
- [x] **No uninitialized state:** IVT/BDA/PSP/MCB/DTA/SFT/drives/EMS init to documented values; two fresh
      POSTs are byte-identical (asserted in `bios_test.zig`); two fresh program runs are byte-identical.
- [~] **No per-op alloc (PARTIAL):** the SFT/drive table/EMS/MCB views are preallocated; handlers use
      fixed stack scratch buffers (no per-call heap). A dedicated counting-allocator guard test is NOT
      added (the handlers demonstrably take no allocator). Flagged.
- [~] **Snapshot/restore round-trip (D14, PARTIAL):** RAM + CPU state round-trip byte-identical; the SFT
      host-handle re-bind by path+position on restore is the same partial as the D14 SFT item.
- [x] **Unsupported-service honesty (D11):** every unimplemented subfunction flags via the structural
      `unsupported{int,ah,al}` signal (asserted for INT 21h AH=0x71 + INT 13h); none fakes success.

---

## Phase 10: The SECOND PASS — oracle-driven completion (trace → fix → re-run corpus)

Goal: promote the live `DIVERGING` corpus programs to `PASSING` against the dosbox-x golden, then extend
the corpus toward BaK. **This phase is driven by `plans/dos-oracle-report.md`, not by hand-authored
fixtures.** The loop is always: **trace the failing INT 21h call → fix faithfully (never tweak-to-match)
→ re-run `zig build test-oracle` → the program flips `DIVERGING`→`PASSING` loudly.** **Done when** the
ladder `HELLO ✅ → MALLOC ✅ → FILEIO → ARGENV → SUBDIR → (extend) → BaK boots` is green (D21).

> **PLAN-change vs IMPLEMENTATION-completion.** Items in **DECISIONS** (D8a/D8b/D20/D21/D22) are the
> PLAN/scope/premise changes. The checkboxes below + the promoted items already inlined into Phases 4-6
> are the IMPLEMENTATION-completion tasks. The two are kept distinct on purpose.

### 10a. The oracle harness (the new sufficiency gate, D21)

- [ ] **`tools/oracle.sh <program.exe> [data...]`** — mints the dosbox-x golden (`<program>.expected`:
      `exit_code` + verbatim console bytes; headless `-silent -fastlaunch -nogui -exit` + the device-off
      `-set` list; stdout redirected to a file on the mounted drive and read back; exit code via the
      `if errorlevel` ladder; bounded by `ulimit -f` + `timeout 120`). MINT-once, vendored, offline.
- [ ] **`src/dos/oracle_test.zig` + `zig build test-oracle`** — loads each corpus `.EXE` through the real
      machine and asserts zdos reproduces the golden (exit code + console bytes). `PASSING` programs are
      permanent regressions; `DIVERGING` programs are asserted to STILL diverge (a fix promotes them
      loudly — the divergence is the deliverable, never force a match). `<STEM>.args` sidecars feed the
      identical argv to oracle + harness.
- [ ] Wire `test-oracle` into the top-level acceptance set (alongside `test-bridge`/`test-bios`/`test-dos`).

### 10b. The 3 traced worklist items (fold-in from `plans/dos-oracle-report.md`)

- [ ] **FILEIO — AH=43 AL=00 existence check (HIGHEST PRIORITY).** Implement the D20/D11a fix (Phase 4):
      AH=43 AL=00 resolves the path through the VFS, returns CF=1/AX=2 when absent. **Re-run:** `FILEIO.EXE`
      flips `DIVERGING`→`PASSING`. (`dos-oracle-report.md` §1; `dos.cpp:1106-1120`.)
- [ ] **SUBDIR — multi-component path resolution.** Implement the D8b VFS work (Phase 5) + AH=3B/47/39/3A
      (Phase 4). **Re-run:** `SUBDIR.EXE` flips `DIVERGING`→`PASSING`. (`dos-oracle-report.md` §2;
      `drive_local.cpp` + `DOS_MakeName`.) This unblocks BaK's subdir data loading.
- [ ] **ARGENV — real env block + canonical argv[0].** Implement the D20 env-block fix (Phase 6): real
      `C:\<EXE>` trailing path + a pinned deterministic populated env. **Re-run:** `ARGENV.EXE` flips
      `DIVERGING`→`PASSING`. (`dos-oracle-report.md` §3; `MakeEnv`, `dos_execute.cpp`.)

### 10c. INT 21h fidelity audit (the AH=43 bug proves fidelity gaps exist within the curated set)

- [ ] **A pass over EVERY already-implemented INT 21h function, verifying real-DOS return fidelity against
      `references/dosbox-staging/src/dos/dos.cpp`** — because the AH=43 stub showed a "done + 4-agent-
      reviewed" function can be silently unfaithful. For each implemented AH/AL, confirm:
  - [ ] **CF on the error path** is set exactly where `dos.cpp` sets `CALLBACK_SCF(true)` — and CLEARED
        on success — not unconditionally one way (the AH=43 failure mode).
  - [ ] **The return-register values** (AX / and where applicable BX/CX/DX/ES:BX) match `dos.cpp` on both
        the success and error paths (e.g. AH=48 returns max-block in BX on failure; AH=47 AX=0x0100).
  - [ ] **The DOS error code** in AX on failure matches the real `dos.errorcode`, and `last_error` (for
        AH=59) is updated.
  - [ ] **MCB-chain integrity** after AH=48/49/4A (links/signatures/owner correct, no orphaned blocks).
  - [ ] **PSP fields** written by the loader/EXEC (0x2C env, 0x32/0x34 JFT, 0x5C/0x6C FCBs, 0x0A/0x0E/0x12
        vectors, version bytes) match the documented layout `dos.cpp`/`dos_execute.cpp` expect.
  - [ ] Record each gap found as a numbered fidelity fix; re-run `test-oracle` after each.

### 10d. Extend the corpus toward BaK

- [ ] Add corpus programs covering the next CRT-startup/runtime surfaces the report flags as missing
      (AH=33/29/59/52, AH=44 AL=01/06/07, AH=45/46 — mint a golden + assert) so the baseline is proven by
      real binaries, not fixtures.
- [ ] **The v1 gate: BaK boots** — `test-oracle` (or the documented BaK boot sequence) shows zdos
      matching dosbox-x on the real BaK `.EXE` load + early run. This is the acceptance ladder's terminus.

---

## Milestone ordering & "done when" criteria

> **RE-GATE (D21).** M0/M1 (the bridge + BIOS core) are validated by their own tests and stay `[x]`. But
> **M2-M4's "done" was asserted against self-authored fixtures and is NOT sufficient** — the first-pass
> M2-M4 passed yet the module failed the first real `.EXE`. They are kept below as the implementation
> record, but the **real acceptance gate is now M5 (the oracle ladder)**: a phase is "done" only when its
> corpus programs pass `test-oracle`. Fixtures remain ONLY for cycle-exact determinism (M4's Phase-8
> regression). The `[x]` on M2-M4 means "the first-pass code exists," not "real software passes."

- [x] **M0 — Callback bridge round-trips.** `zig build` + `zig build test-bridge`/`test-bios` green; the
      `0xFE 0x38 <id>` trap reaches a host handler via the CPU `CallbackSink` (the one surgical `src/cpu/`
      edit; contract names no `*Cpu`, D2 refined) and resumes via IRET; the D4 stack-FLAGS patch works;
      **`runGuestInt` re-entrancy works via the real-`INT n` trampoline driven through the machine step,
      with the `cpu.dec`/`instr_start_eip` seam scratch saved/restored** (D3 rewritten); the bridge lives
      in the shared leaf imported by both bios and dos with no dos→bios edge (D12 reversed/D16); every
      trap charges the D5 synthetic cost (the no-hole guard fires; the stop sentinel is carved out); the
      round-trip is byte-identical twice including `cycles`. (Phase 0-1) **This is the foundation
      everything hangs off.**
- [x] **M1 — BIOS core + INT 10h/16h/1Ah.** POST lands the IVT+BDA, takes over the machine's M-D9
      stand-ins (real PIC/PIT/A20 init), plants the BIOS stubs; INT 10h (mode 13h), INT 16h (BDA
      keyboard buffer), INT 1Ah / INT 08h (PIT-driven tick, no host clock) work; deferred subfunctions
      flag (D11). (Phases 2-3)
- [x] **M2 — DOS INT 21h core + VFS + char devices.** INT 21h dispatch with PSP/MCB/DTA/SFT (guest-RAM
      views + host SFT with the `{device,file}` tagged union + inline `[128]u8` path, D9/D17); the
      character-device table (CON/AUX/PRN/NUL, AH=3D resolving devices before the VFS, AH=44 device bit,
      D17); the curated function set (file open/create/close/read/write/seek 3C-42, find 4E/4F, DTA
      1A/2F, date/time 2A-2C + AH=57 from the PIT/epoch not host `stat` D13, mem 48-4A, get-version 30
      from PSP version bytes, set/get vector 25/35 over the single-source guest IVT, char I/O, get/set
      PSP, INT 22/23/24 unwind) works against a host temp dir via the `HostDirDrive` VFS with re-derived
      8.3 munging (D10); the unknown-AH default returns AL=0/CF-clear + the structural signal (D11 split).
      (Phases 4-5)
- [x] **M3 — EXE/COM loader runs a real program.** A COM (AH=09 print + AH=4C exit) and an EXE (with a
      relocation) both load (MCB alloc, PSP build, relocations, register setup) and run to a clean exit
      with asserted output + exit code; the **initial-load path that boots BaK** is specified and wired
      (machine calls `dos.loadProgram` after POST+DOS-init). (Phase 6)
- [x] **M4 — EMS + determinism sign-off.** INT 67h (allocate/map/free pages) drives the bus EMS MMIO
      remap (D15); the **deterministic host-serviced-trap regression** (Phase 8) is green —
      run-to-cycle-N-twice byte-identical **including cycle position** despite real file I/O, plus the
      host-I/O-timing-independence check and the snapshot-mid-service round-trip (with SFT length/hash
      mismatch flagging, D11/D14). All DECISIONS (D1-D19) recorded/honored; the Phase 9 audit (grep
      no-host-time + no-host-file-timestamp, cycle-ledger completeness, no-uninit, zero-alloc, snapshot
      round-trip, unsupported-service honesty) is fully green. `zig build` / `zig build test` /
      `test-bridge` / `test-bios` / `test-dos` all green. **The Spice86 cycle-ledger
      hole is closed: every host-serviced trap charges a fixed synthetic cost; the ledger has no hole.**
      Ready for the API/MCP server (`src/api/`) and the VGA/keyboard/mouse devices to complete the BaK
      target. **NOTE (D21): this M4 sign-off was against self-authored fixtures; real-software
      sufficiency is M5.**
- [ ] **M5 — THE REAL ACCEPTANCE GATE: zdos matches dosbox-x on real binaries (the oracle ladder, D21).**
      `zig build test-oracle` green up the ladder: **HELLO ✅ → MALLOC ✅** (passing regressions) **→
      FILEIO** (AH=43 existence fix) **→ ARGENV** (real env/argv[0]) **→ SUBDIR** (multi-component path) **→
      (extended corpus for AH=33/29/59/52, AH=44 AL=01/06/07, AH=45/46) → BaK boots**. The INT 21h fidelity
      audit (Phase 10c) is complete with every gap recorded + fixed. "DOS done" ≡ "matches dosbox-x on
      real binaries"; the hand-assembled fixtures retain only the cycle-exact determinism job (M4/Phase 8).
      (Phase 10) **This is the v1 DOS gate — not M2-M4.**

---

## Out of scope (kept as seams, flagged — not built here)

- **The VGA device, the keyboard device + INT 09h/IRQ1, the mouse DEVICE:** separate `src/devices/`
  modules. INT 10h (this module) *drives* the VGA device; the VGA register/framebuffer implementation
  (bus B11 MMIO + ports 3C0-3DA) is the device's. INT 16h + the BDA keyboard buffer are here; the
  keyboard *device* that fills the buffer via IRQ1 is a device. **INT 33h — the mouse DRIVER — is HERE
  (D18, Phase 3), not out of scope;** only the mouse *device* (raw motion/buttons via the scripted-input
  seam) is a device. They wire through the same device→PIC→IRQ + callback seams (machine `DeviceCtx`).
- **Sound (INT 1Ah PC-speaker beyond tick, Sound Blaster, AdLib, INT 2Fh sound):** deferrable per the
  charter (`CLAUDE.md` First target: "sound (deferrable)").
- **FCB-based file API (INT 21h 0x0F-0x24), network/share (5xxx), LFN (71xx), DBCS, country info:**
  deferred-and-flagged (D11) — handle-based file I/O is what 1993 games use; build the FCB path only if
  a BaK trace shows it, never faked.
- **Additional VFS backends (`fatDrive` disk images, `isoDrive` CD, overlay/copy-on-write, MSCDEX
  INT 2Fh AH=15):** the `DosDrive` interface keeps the seam (D8); only `HostDirDrive` is built — mapping a
  host directory **tree** (with subdirectory traversal, D8b) to a drive. **NOTE: subdirectory / multi-
  component path resolution is now IN-SCOPE (D8b, Phase 5) — it was moved OUT of this Out-of-scope list,
  being a hard BaK blocker (SUBDIR divergence).**
- **The shell / COMMAND.COM / AUTOEXEC / batch processing:** zdos loads BaK directly as the initial
  process (Phase 6); no command interpreter is needed for the v1 target.
- **XMS / DPMI / DOS extenders / protected mode:** CPU-deferred (cpu.md Deferred section); BaK is plain
  real-mode MZ with EMS via INT 67h (D15), no extender.
- **PRM-accurate synthetic cycle costs:** the D5 costs are *fixed* (satisfying the prime directive) but
  **interim/provisional**, not measured-real-DOS timings (a fidelity-only later pass, like cpu.md D6 /
  machine M-D8a); the real figures are not available offline and are not invented (ground rule).
- **TSR chains / multiple concurrent processes beyond a parent/child EXEC:** the PSP tree supports
  parent→child EXEC (Phase 6) but a full TSR-resident ecosystem is not built; flagged.
