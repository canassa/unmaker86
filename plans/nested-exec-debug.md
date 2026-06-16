# Debug INSIDE a nested INT 21h AH=4Bh EXEC (launcher chains)

Status: DONE — approach (B) implemented + all 7 LOCKED fixes landed. Phases 1-3 shipped
atomically; 11 new tests (`src/dos/nested_exec_debug_test.zig`) + the existing SPAWN oracle stay
green; `zig build test` = 567/567. Live-proven: an API `interrupt:0x21` breakpoint fires inside
`ST.COM`→`STUNTS.COM`→`LOAD.EXE` (returned zero before). No golden re-baseline was needed (the
re-baseline surface was empty — no committed golden pins an EXEC-spanning absolute cycle count).
Owner: dos / bridge / debug (`src/dos`, `src/bridge`, `src/debug`).

Implementation summary (what shipped):
- `bridge.zig`: added `emitExecRetf` + `execRetfSegOff` (a planted `RETF` stub at
  `EXEC_RETF_PHYS`, after the INT 16h hybrid block); DELETED `runUntil`. `machine.post` plants it.
- `loader.exec`: LOADNGO — sets INT 22 = parent resume, pushes the 18-byte parent register block
  on the parent stack + saves parent SS:SP into the parent PSP (0x2E), builds the child, then
  pushes the child entry CS:IP and redirects CS:IP at the RETF stub. DELETED `ParentSnapshot`.
  The boot/root program now self-parents (`buildPsp`), so `dos.terminate` keys "root?" off
  `parent == self`.
- `dos.terminate`: grew into the real `DOS_Terminate` unwind (`terminateTsr` with a TSR carve-out
  skipping CloseFiles+FreeProcessMemory). Non-root: restore parent SS:SP + the 18-byte block,
  build the INT-22h IRET frame on the parent stack, free child memory, leave `terminated=false`.
  Root: surface `program_terminated` as before.
- `psp.zig`: added `OFF_STACK=0x2E` + `setStack`/`getStackSeg`/`getStackOff`; removed the bogus
  `OFF_DOS_VER=0x30` (it aliased the saved-stack segment word).
- `machine.Snapshot`: added `current_psp`/`current_drive`/`dta_seg`/`dta_off`/`ret_code`/
  `ret_type`/`terminated` (the latent gap the de-nest made live).

## Review outcome — LOCKED decisions (implement exactly these)

Three independent reviews verified approach (B) against the code + `dos_execute.cpp`.
All agreed (B) is the right, fakes-free model; these are the binding corrections —
they override any older framing elsewhere in this doc:

1. **Faithful EXEC entry/exit — NOT the "byte-identical IRET-to-call-site" shortcut.**
   The faithful return resumes the parent at its **INT 22h (PSP 0x0A)**, not at the
   instruction after the `INT 21h AH=4Bh`. So:
   - **EXEC entry:** zdos's single shared INT-21h callback tail is a fixed `.iret`
     (`dos.zig:201`, `bridge.zig:226`) — it CANNOT be swapped per-subfunction, and
     reusing it would pop the parent frame and overwrite the child CS:IP (child never
     runs). `loader.exec` must therefore consume/redirect the parent's INT-21h IRET
     frame and enter the child via a dedicated stub (`.retf` CbType exists,
     `bridge.zig:235`; mirror the planted-far-frame pattern in `runGuestFarCall`,
     `bridge.zig:648`). Pin the exact entry mechanism before writing Phase 2/3.
   - **EXEC exit:** `dos.terminate` does the real unwind — restore parent SS:SP from
     the PSP saved-stack field, resume at INT 22h, mirroring `DOS_Terminate`
     (`dos_execute.cpp:114-178`).
   - This adds a fixed, deterministic handful of unwind cycles per EXEC return → **plan
     for re-baselining** (it's more faithful). Do NOT chase a zero-extra-instruction
     unwind. (Re-baseline surface is effectively empty today — no committed golden
     pins an EXEC-spanning cycle count; verify in Phase 0.)
2. **`dos.terminated` must unwind SYNCHRONOUSLY within the one trap.**
   `controller.terminalReason()` (`controller.zig:392`) returns `program_terminated`
   whenever `dos.terminated` is set, checked after EVERY step, terminal beats
   breakpoint. Under (B) there is no later host frame to clear it (the old
   `loader.exec` step 6 did). So `dos.terminate`, for a **non-root** PSP, must
   complete the entire parent switch (PSP/DTA/CS:IP/SS:SP/regs) AND leave
   `terminated == false` before the trap returns to the loop; only the self-parented
   ROOT exit leaves it set. Add a test that a child `AH=4C` does NOT stop the parent.
3. **Preserve the parent's registers across the unwind.** Real DOS restores the
   parent AX/BX/CX/DX/SI/DI/BP/DS/ES from an 18-byte block the EXEC caller pushed
   (`dos_execute.cpp:477`, `:149-160`). zdos never pushes it and currently relies on
   the host `ParentSnapshot.restore` (`loader.zig:649`). Deleting `ParentSnapshot`
   (Phase 3) WITHOUT pushing/restoring that block leaves the parent's registers =
   whatever the child left them — a correctness hole. **Push the 18-byte parent
   register block at EXEC and pop it in `terminate`** (full fidelity). Test it.
4. **Snapshot the host-side kernel state (B) makes live.** `Machine.Snapshot` does
   NOT cover `current_psp`, `current_drive`, `dta_seg/off`, `ret_code/ret_type`, or
   `terminated` (documented latent gap, `machine.zig:585-601`). De-nesting makes
   mid-child a first-class snapshot point, promoting the gap to a live bug. Add those
   POD fields to `Machine.Snapshot`/`snapshot`/`restore`, and add a snapshot-
   **roundtrip** mid-EXEC test (snapshot mid-child → restore into a FRESH machine →
   resume → byte-identical vs an uninterrupted run; the same-machine pause/resume
   test does NOT catch this).
5. **TSR (`AH=31h` / INT 27h) carve-out.** The grown `terminate` must branch on
   keep-resident: skip CloseFiles + FreeProcessMemory for the TSR path (mirror
   `DOS_Terminate(..., tsr)` `dos_execute.cpp:130-173`). `AH=31h` stays `unsupported`
   for now, but the unwind must not free memory a TSR keeps.
6. **Reframe the step-over-of-EXEC claim — it is a known gap, not a feature.**
   `stepOver` of `INT 21h AH=4Bh` reads the return site off the stack AFTER one
   `m.step()` (`controller.zig:697`/`741`); under (B) that step switches SS:SP to the
   CHILD, so the return-address one-shot is armed at a wrong address. Drop the "step-
   over runs the whole child" test claim; document it as a step-over fallback (like
   the indirect-CALL case, `controller.zig:684`).
7. **Land Phases 1–3 ATOMICALLY.** The EXEC path is not green between them (a half-
   converted `loader.exec` breaks SPAWN.EXE). Build + verify the entry stub +
   `terminate` unwind + deletion of `runUntil`/`ParentSnapshot` as ONE change.

Minors: add a PSP saved-SS:SP accessor at offset `0x2E` and reconcile with
`OFF_DOS_VER=0x30` (`psp.zig`); note overlay `AL=03` stays rejected (do not let
de-nesting make it transfer control); removing the `MAX_DEPTH=8` cap and surfacing
child faults/shutdown to the controller are improvements (keep them); `dos.terminate`
currently discards `br` — keep/remove per whether the chosen unwind needs it.

## Problem

zdos services `INT 21h AH=4Bh` (EXEC) by running the **child nested to
termination inside the host DOS handler**. `loader.exec` calls
`bridge.runUntil` (`src/dos/loader.zig:604-609`), and that loop
(`src/bridge/bridge.zig:703-718`) steps the machine with the RAW
`stepOnceThunk` (`src/machine/machine.zig:309-312` → `run_loop.step`) and
**never consults the debug controller**. The controller's single between-steps
breakpoint scan (`src/debug/controller.zig:367-387` `runUntilEvent`) is the ONLY
place breakpoints/watchpoints/cycle-cap are evaluated, and it is suspended for the
entire duration of a nested EXEC.

Consequences (all verified by the prior Stunts investigation —
`plans/stunts-milestone.md:164-180`):

- An `interrupt:0x21` breakpoint sees **zero** of the child's thousands of INT 21h
  calls; `memory`/`io`/`execution_address` watchpoints never trip.
- `run-to-cycle N` for any N inside the child (`ST.COM`→`STUNTS.COM`→`LOAD.EXE`,
  ~49M cycles) **overshoots** to the first boundary AFTER the outermost EXEC
  returns — `runUntil` does not honor the controller's one-shot cycle bp.
- `step`/`step-n`/`step-over` cannot descend into the child at all.
- The entire inner game (tens of millions of cycles, the actual program under
  investigation) is **opaque to the HTTP debugger**. The prior agent was forced to
  re-instrument zdos's own Zig to debug Stunts. This is "the #1 blocker" for
  launcher-chain games.

The emulation itself is faithful and deterministic — the child charges real cycles
for every instruction (no ledger hole, the whole point of zdos), byte-identical CPU
state at cycle 80M across two runs (`plans/stunts-milestone.md:180`). This is a
**debugger-plumbing / EXEC-structure** problem, not an emulation-correctness one.

## Goal

Make the debugger's existing controls — `execution_address`/`cycle`/`interrupt`/
`memory`/`io` breakpoints, `step`/`step-n`/`step-over`, `run-to-cycle`, the
cycle-cap — **effective inside a nested EXEC**, including the hard part: a
breakpoint that fires inside the child must return to the API with the machine
**paused mid-child**, and a subsequent `run`/`step` must continue the child
correctly, then eventually return to the parent on the child's `INT 21h AH=4Ch`.

## References consulted (file:line)

zdos:
- `src/dos/loader.zig:505-623` — `exec` (AH=4B AL=00): the host-serviced nested
  shape. Comment at `:505-520` documents the deliberate "run the child NESTED like
  `runGuestInt`" decision; `:580` `ParentSnapshot.capture`; `:603-609` the
  `br.runUntil(... d.terminated)` nested loop; `:617-622` the unwind
  (`freeProcessMemory` + `save.restore` + clear `terminated` + `setGuestCF`).
- `src/dos/loader.zig:628-659` — `ParentSnapshot`: saves `cpu.st`, `cpu.dec`,
  `instr_start_eip`, `current_psp`, `dta_seg/off`, `parent_int22`; `restore`
  keeps `cpu.st.cycles` (no ledger hole) and overwrites everything else.
- `src/dos/loader.zig:315-326` — `setupRun`: how the child entry CS:IP/SS:SP/DS/ES/
  AX/BX are set (the LOADNGO register state).
- `src/dos/loader.zig:567-577` — INT 22 = caller return CS:IP read off the INT 21h
  IRET frame (so the child PSP's SaveVectors captures the parent resume).
- `src/dos/dos.zig:343-355` — `terminate` (AH=4C/00/INT20): sets `ret_code`/
  `ret_type`/`terminated`, restores INT 22/23/24 from the terminating PSP. The
  comment at `:353-354` notes "Memory free + transfer to INT 22 are exercised by
  the EXEC path" — i.e. terminate today is a FLAG, not a real stack unwind.
- `src/bridge/bridge.zig:560-610` — `runGuestInt` (the re-entrancy trampoline:
  save seam, patch `INT nn`, drive `step_one` until the stop sentinel, restore
  seam). `:628-686` `runGuestFarCall` (far-return-frame variant). `:695-718`
  `runUntil` (the nested-EXEC driver; raw stepper; bounded; panics on overrun).
- `src/bridge/bridge.zig:16-22, 160-198` — the no-machine-import doctrine: the
  bridge is BELOW the machine and takes an injected `step_one: *const fn
  (*anyopaque) void` via `setStepper`. It already holds a `*anyopaque` stepper —
  but that is the MACHINE's step, not the controller's.
- `src/debug/controller.zig:1-16` — the design rule we must honor: "It is ABOVE
  `machine` in the module graph … No function pointer on the machine, no
  `*anyopaque`, no type erasure." `:367-387` `runUntilEvent`; `:417-440`
  `scanBreakpoints`; `:556-580` `stepInstruction`/`stepN`; `:586-607`
  `runToCycle`/`runToAddress`.
- `src/debug/breakpoints.zig:133-204` — `SeqBefore` / `matches` / `seqBefore`:
  the cycle-neutral between-steps scan (interrupt-delivery seq, mem/io watch seq).
  `interrupt` matches on `last_delivered.seq` advancing AND vector match —
  works for ANY INT delivery, parent or child, IF the scan runs each child step.
- `src/machine/machine.zig:300-312` — `setStepper`/`stepOnceThunk`; `:534-535`
  `Machine.step` → `run_loop.step`.
- `src/machine/run_loop.zig:41-83` — `step` (the burst primitive: fireDue +
  cpu.step + HLT fast-forward). `:104-130` `runCycles`/`runUntil` note explicitly
  "Breakpoints are NOT a machine concern in M1 — the debug control core owns its
  own run loop over `step`."
- `src/cpu/interrupts.zig:46-91` — `step`: snapshots `tf_at_start`; the
  instruction boundary the controller drives. `:114-134` `serviceInterrupts`.

Reference emulators (the faithful EXEC/terminate model — child runs on the MAIN
loop, NOT a nested host loop):
- `references/dosbox-staging/src/dos/dos_execute.cpp:546-572` — `DOS_Execute`
  `LOADNGO`: sets the child SS:SP, **`CPU_Push16(CS); CPU_Push16(IP)`** of the
  child entry, sets flags (`IF` set, test flags cleared), then **`reg_ip++` to
  land on a RETF** so "we only need to store cs:ip on the stack". The child then
  runs on the ordinary CPU loop. There is **no nested interpreter call** — EXEC
  returns and the next fetched instruction is the child's first.
- `references/dosbox-staging/src/dos/dos_execute.cpp:114-178` — `DOS_Terminate`:
  restores INT 22/23/24, sets `dos.psp(parent)`, **restores parent SS:SP from the
  parent PSP's saved stack** (`parentpsp.GetStack()`), pops the parent's
  AX..ES off that stack, then **writes the INT-22 address (parent resume CS:IP) +
  a flags word onto the stack** so the AH=4Ch handler's IRET returns into the
  parent's EXEC call site. Again — pure main-loop; terminate is a real stack
  unwind, not a flag.
- `references/dosbox-staging/src/dos/dos_execute.cpp:474-491` — the EXEC caller
  saves its own SS:SP into the child PSP stack field and snapshots INT 22 from the
  caller frame (mirrors `loader.zig:567-580`).
- `references/spice86/.../Dos/DosInt21Handler` + `DosProcessManager` — same model:
  EXEC builds the child PSP, pushes the child entry, and **returns into the child
  on the shared CPU loop**; terminate (`Int21` 0x4C) pops the saved parent frame.
  spice86's debugger breakpoints are evaluated on that one shared loop, which is
  why spice86 CAN see inside a child (its hole is the cycle ledger, not visibility
  — the inverse of zdos's current trade-off).
- `references/dosbox-x/src/debug/debug.cpp` (`StepOver`, temporary-bp model) — the
  one-shot-next-address technique zdos already mirrors in `controller.stepOver`;
  unaffected by this change but must keep working across an EXEC boundary.

## Approaches evaluated

### (A) Minimal — inject a between-steps observer into `bridge.runUntil`

Make `runUntil` comptime-generic over an observer type that, between child steps,
runs the controller's `seqBefore` + `scanBreakpoints` + cycle-cap check (NOT a
runtime fnptr — a comptime type param so it inlines, satisfying the no-`*anyopaque`
rule mechanically).

The fatal problem is **PAUSE/RESUME**, not the scan. When a child breakpoint fires,
the host call stack is:

```
worker → controller.runUntilEvent → machine.step (parent INT 21h instr)
  → cpu dispatches INT 21h → Services sink → loader.exec
    → bridge.runUntil  ← we are HERE, mid-loop, mid-child
```

To return to the API "paused mid-child" we must unwind ALL of these host frames
while leaving the GUEST mid-child and the EXEC bookkeeping (ParentSnapshot, INT 22,
the not-yet-freed child MCBs) pending — then, on the next `run`/`step`, RE-ENTER
exactly this nested loop with the same host-side state. Zig has no
coroutines/stackful fibers in 0.16; the only faithful ways to suspend a native call
stack are (a) a saved/longjmp-style escape (not available / not idiomatic / leaves
`defer`s and the depth guard in an undefined state), or (b) hoisting all of
`loader.exec`'s mid-flight state into a heap/struct continuation so the host frames
can fully unwind and be rebuilt. (b) is a restructure that is strictly larger and
uglier than (B) — and it STILL leaves two breakpoint scanners (top-level
`runUntilEvent` and the nested observer) with subtly different precedence to keep in
sync. **Rejected**: solves visibility but makes pause/resume a continuation-passing
nightmare, and keeps the nested loop (the root cause) alive.

### (B) Faithful restructure — the child runs on the MAIN step loop (RECOMMENDED)

Adopt the real-DOS / dosbox / spice86 model: **EXEC sets up the child and returns
INTO it; the child runs on the ONE controller-owned step loop; terminate is a
trampoline that unwinds back to the parent's EXEC call site.** There is no nested
host loop, so there is exactly ONE place breakpoints are scanned — and
breakpoints/watchpoints/step/pause/resume work inside the child "for free,"
identically to top-level code.

Mechanism (mirrors `dos_execute.cpp:546-572` + `:114-178`, re-modeled to zdos's
trap-callback bridge):

1. **`loader.exec` becomes "set up child, return into it" (LOADNGO).** It keeps
   steps (1)-(4) almost verbatim: parse path + param block, set INT 22 = caller
   return CS:IP, load the child, build the child PSP (links parent, SaveVectors).
   It then DELETES steps (5)/(6) (the `br.runUntil` nested run + the immediate
   unwind). Instead, exactly like `setupRun` already does for the boot program, it
   leaves the CPU pointed at the child entry (CS:IP/SS:SP/DS/ES/AX/BX per
   `setupRun`). The INT 21h trap stub's own `IRET`/return tail then "returns into"
   the child's first instruction on the next `controller` step — the child IS the
   next thing fetched. No state is snapshotted into a host `ParentSnapshot`; the
   parent's resume state lives where real DOS keeps it: **in the child PSP** (the
   saved parent SS:SP stack pointer, the saved INT 22/23/24).

   Note the return-shape subtlety: zdos's INT 21h is a host-serviced trap that
   ends in `IRET` (it consumes the INT 21h frame the CPU pushed). Real DOS EXEC
   returns to the caller via that same IRET, then the child runs. zdos must NOT let
   the trap's IRET return to the PARENT and ALSO start the child — it must make the
   child the next-executed code. The clean way: after `loader.exec` sets the child
   registers, the AH=4B trap returns normally (its IRET pops the parent's INT 21h
   frame), but `loader.exec` has already overwritten CS:IP/SS:SP to the child, so
   the IRET-restored CS:IP would be wrong. **Resolution:** AH=4B uses a return tail
   that does NOT IRET back to the parent — it discards the INT 21h frame and jumps
   to the child. The simplest faithful realization is the dosbox trick: have
   `loader.exec` set the child SS:SP, `push16(child_cs); push16(child_ip)` onto the
   child stack, and point the trap's resumption at a **`RETF`** (a 1-byte stub in
   the callback area). The AH=4B trap stub's tail becomes "load child SS:SP, then
   RETF" rather than "IRET". This is a NEW `CbType` tail (see Phase 1) — the
   faithful analogue of `dos_execute.cpp:557` "Jump to retf."

2. **`dos.terminate` becomes the real unwind trampoline** (today it only sets a
   flag + restores 22/23/24 — `dos.zig:343-355`). On AH=4C/00/INT20 from the
   child, it must (mirroring `dos_execute.cpp:114-178`):
   - record `ret_code`/`ret_type`;
   - restore INT 22/23/24 from the terminating PSP (already done);
   - `freeProcessMemory(child_psp)` (moved here from `loader.exec` step 6);
   - set `current_psp`/`dta` back to the parent (from the child PSP's parent link);
   - restore parent SS:SP from the parent PSP's saved stack field, and set CS:IP =
     the saved INT 22 (parent resume) so control returns to the parent's EXEC call
     site. zdos's AH=4B caller did NOT push the parent GP regs on its stack the way
     COMMAND.COM does, so we adopt the **PSP-saved-stack + INT22** path: terminate
     sets CS:IP:SS:SP directly from the child PSP's saved parent-stack + INT22
     fields and returns; the AH=4C trap tail is then a plain `IRET`/RETF onto the
     parent. (Whether we push a synthetic IRET frame or set CS:IP directly is a
     Phase-2 detail; both are main-loop, no nested call.)
   - clear `terminated` for the parent.
   The **initial (root) process** keeps today's behavior: its PSP is self-parented
   (`psp_seg == parent`, `dos_execute.cpp:124-126`), so terminate detects "no
   parent" and surfaces `program_terminated` to the controller, which stops — no
   unwind, the controller's `terminalReason` fires exactly as now.

3. **Delete `bridge.runUntil` entirely** (`bridge.zig:695-718`). Nothing else uses
   it (grep-verified during implementation). `runGuestInt`/`runGuestFarCall` stay —
   they are for genuinely re-entrant host→guest→host calls (mouse callback, INT 16h
   poll), which are bounded and correct as nested loops; EXEC is NOT that pattern.

Module-graph faithfulness: this approach **adds no observer to the bridge at all**.
`src/bridge` and `src/dos` lose code; they gain nothing that points up at
`src/debug`. The controller is the sole driver, exactly as its header promises.
There is no machine fnptr, no `*anyopaque` for debug, no vtable. The child is just
more guest instructions on the one loop the controller already scans between.

Scope: `loader.exec` (delete the nested run + ParentSnapshot; keep child setup),
`dos.terminate` (grow the parent unwind), one new bridge `CbType` tail for the
EXEC RETF return (or reuse `runGuestFarCall`'s far-return-frame idea as a stub),
delete `bridge.runUntil`. The PSP already stores the parent link + saved vectors;
add a saved-parent-SS:SP field write at EXEC time (the PSP "user stack" field at
offset 0x2E, which real DOS uses for exactly this — `dos_execute.cpp:480/491`
`SetStack`).

### (C) Hybrid

Not warranted. (A)'s only advantage is "smaller diff," but its pause/resume
continuation machinery is larger and more fragile than (B)'s restructure, and it
preserves the root cause (the nested loop) and a second breakpoint scanner. (B)
dominates on correctness, determinism clarity, and long-term simplicity.

## Recommended approach: (B), and why

- **One loop ⇒ all controls work uniformly.** Breakpoints, watchpoints, the
  cycle-cap, `step`/`step-n`/`step-over`, `run-to-cycle`, and pause/resume already
  work at top level via `controller.runUntilEvent`. Once the child runs on that same
  loop, every one of them works inside the child with **no new debug code** — the
  `seqBefore`/`matches` scan (`breakpoints.zig:154-204`) already matches `interrupt`
  on any delivery and watchpoints on any bus access, parent or child.
- **Pause/resume is trivial.** A child breakpoint is just `runUntilEvent` returning
  at a child instruction boundary; the host stack is the same shallow
  `worker → runUntilEvent → step` it is for any stop. Resume is the next
  `run`/`step` continuing the same loop. No continuation, no suspended native
  frames, no second scanner. (A)'s hard part disappears because we removed the
  nesting that created it.
- **It is the faithful model.** Real DOS, dosbox-staging, dosbox-x, and spice86 all
  run the child on the shared CPU and unwind via the PSP-saved stack + INT 22.
  zdos's current nested-host-loop is the ONLY divergence, and it is the source of
  the opacity. (B) removes a fake-shaped shortcut, consistent with the ground rule.
- **Module graph honored by construction** (see above).

## Determinism

The prime directive: same binary + same inputs ⇒ byte-identical machine state at
cycle N, every run. (B) must be **byte-identical to today for a no-breakpoint run**,
and the cycle ledger must be unchanged.

- **Cycle ledger unchanged.** Today the child's instructions are stepped via
  `run_loop.step` inside `runUntil`; under (B) the SAME `run_loop.step` runs them
  via the controller loop. Same instructions, same order, same per-instruction
  charge, same fireDue boundary, same HLT fast-forward. The synthetic trap costs
  (`bridge.chargeBase`/`chargeWork`) are charged at the same INT 21h dispatch
  points. **No ledger hole is created or closed** — zdos already has no hole across
  EXEC; (B) preserves that.
- **The one ordering change to scrutinize: the EXEC return shape.** Today
  `loader.exec` snapshots the parent CPU state, runs the child, then `restore`s the
  parent (keeping `cpu.st.cycles`). Under (B) the parent state is restored by
  `dos.terminate` from the PSP-saved stack + INT22 instead of from a host struct.
  These must produce the **identical parent register state and the identical total
  cycle count**. This is the determinism-critical equivalence to prove:
  - The set of instructions executed between EXEC-entry and parent-resume is the
    same (child entry → child body → child AH=4C). The ONLY added/removed guest
    instructions are the **return-plumbing** ones: today the parent resumes via a
    host `ParentSnapshot.restore` (0 guest instructions for the unwind) and the
    AH=4B trap's IRET; under (B) the unwind runs a RETF/IRET trampoline (a handful
    of real guest instructions in the callback area). **This is a
    determinism-affecting change to the instruction stream of the EXEC seam** (a few
    extra guest instructions, hence a few extra cycles, per EXEC return).
  - **Therefore (B) is NOT byte-identical to today across an EXEC boundary** — the
    parent will resume a few cycles later than today (the cost of the real RETF/IRET
    unwind that today is faked away by a host struct restore). It IS byte-identical
    *within* the child (the child instruction stream is untouched) and for any
    program with no EXEC.
  - **Honest call-out (re-baselining):** any golden that spans an EXEC return — i.e.
    captures parent state at a cycle AFTER an EXEC completes, or a total cycle count
    of a program that EXECs a child and continues — **must be re-baselined**. The
    new values are MORE faithful (they include the real unwind cost real DOS pays),
    so the re-baseline is a correctness improvement, not a regression. Goldens that
    stop *inside or at the end of* a child (the common debug case) are unaffected.
    The existing EXEC black-box tests (see Tests) must be checked: those that assert
    only the child's exit code / child-visible state stay identical; any that assert
    the parent's post-EXEC cycle count get new goldens (documented in the commit).
    *(LOCKED per review §1: do NOT chase a zero-extra-instruction unwind — the
    faithful return targets the parent's INT 22h and pays a fixed real unwind cost,
    so re-baseline the affected goldens. The "set CS:IP directly + IRET to the EXEC
    call site" shape is the LESS faithful one and is rejected. Keep the unwind cost
    fixed and data-independent — no branch on child state — so determinism holds.)*
- **Mid-EXEC pause/resume stays deterministic.** A pause is `runUntilEvent`
  returning — it leaves `cpu.st.cycles` exactly where the last retired child step
  put it (controller header guarantee, `controller.zig:6-12`: pausing reads only the
  ledger, never host time). Resume re-enters the same loop and steps the next child
  instruction. Because nothing host-side is snapshotted/restored across the pause
  (the machine just sits at a boundary), two runs that pause at the same child cycle
  N and resume reach byte-identical state — exactly the top-level pause/resume
  guarantee, now extended to the child by construction.
- **Inspection cycle-neutrality is preserved.** The peek path, disasm, devices
  snapshot, watch-detail read (`controller.zig:447-469`) are unchanged and remain
  side-effect-free whether the paused PC is in the parent or the child.

## Phased roadmap

### Phase 0 — Pin the mechanism (no code)
- [ ] Enumerate every current caller of `bridge.runUntil` (expect: only
      `loader.exec`). Confirm `runGuestInt`/`runGuestFarCall` are untouched.
- [ ] Pin the FAITHFUL EXEC entry stub + INT-22h exit unwind per LOCKED §1 (dedicated
      `.retf`/redirect stub for entry — NOT the shared `.iret` tail; `terminate`
      restores parent SS:SP from PSP-saved-stack + resumes at INT 22h). Specify the
      18-byte parent register block (LOCKED §3): pushed at EXEC, popped in terminate.
- [ ] Confirm the re-baseline surface: inventory goldens/tests that span an EXEC
      return (expect none pin an EXEC-spanning cycle count today — verify).

### Phase 1 — EXEC return plumbing in the bridge (if a stub is needed)
- [ ] Add the EXEC return `CbType`/stub (e.g. "load child SS:SP then RETF", or
      reuse the `runGuestFarCall` far-return-frame idea as a planted stub). Byte-
      emission test like the existing `plantStub`/`emitPollLoop` tests
      (`bridge.zig:747-825`). No machine/debug import; pure ISA bytes.

### Phase 2 — `dos.terminate` real unwind
- [ ] Save the parent SS:SP into the child PSP at EXEC time (PSP user-stack field
      0x2E; mirror `dos_execute.cpp:480/491`). Verify `buildPsp`/`saveVectors`
      already capture INT 22/23/24 = parent resume (they do, `loader.zig:328-342`).
- [ ] Grow `dos.terminate` (`dos.zig:343-355`) to the full `DOS_Terminate` unwind
      for a non-root PSP: free child memory, switch to parent PSP/DTA, restore
      parent SS:SP, set CS:IP = saved INT 22, clear `terminated`. Root PSP
      (self-parented) keeps surfacing `program_terminated` to the controller.

### Phase 3 — `loader.exec` LOADNGO conversion
- [ ] Delete steps (5)/(6) (`loader.zig:599-623`): the `br.runUntil` nested run,
      `ParentSnapshot`, the in-EXEC `freeProcessMemory`/`save.restore`. EXEC now
      ends by leaving the CPU at the child entry (via `setupRun`) + the return stub.
- [ ] Delete `ParentSnapshot` (`loader.zig:628-659`) and `bridge.runUntil`
      (`bridge.zig:695-718`).
- [ ] Keep the EXEC failure path faithful: on load error, restore parent INT 22 and
      return CF=1 WITHOUT having altered parent CS:IP/SS:SP (no child was entered).

### Phase 4 — Verify the controller sees the child (no debug code expected)
- [ ] Confirm `runUntilEvent`/`scanBreakpoints` now fire on child instructions with
      ZERO changes to `src/debug` (the payoff). If anything in `breakpoints.zig`
      assumes top-level-only, fix it here (none expected — the scan is state-based).

### Phase 5 — Tests + golden re-baseline (see Tests)

### Phase 6 — Docs
- [ ] Update `plans/stunts-milestone.md` (mark the "STRUCTURAL DEBUGGER LIMITATION"
      resolved) and the `debugging-with-zdos` skill (the debugger now descends into
      EXEC). **Do NOT edit `plans/ROADMAP.md` in this plan** — but ROADMAP MUST get
      an entry when this lands (per CLAUDE.md: keep ROADMAP current on milestone).

## Tests

New (`src/dos/loader_test.zig` / a new `nested_exec_debug_test.zig` + `src/api`):

- [ ] **Breakpoint inside a child fires.** Parent EXECs a child that does a known
      `INT 21h`; an `interrupt:0x21` breakpoint set before the run stops INSIDE the
      child (assert CS:IP is in the child's segment, the breakpoint id, the child's
      cycle < the EXEC-return cycle). Today: zero hits.
- [ ] **`execution_address` breakpoint inside a child** at the child's entry / a
      known child instruction fires; CPU snapshot shows child registers.
- [ ] **`memory` watchpoint** on an address the child writes trips during the child;
      the `WatchHit` detail (`controller.zig:447-457`) reports the child's write.
- [ ] **`io` watchpoint** on a port the child touches trips during the child.
- [ ] **`cycle` breakpoint / `run-to-cycle N`** for an N strictly inside the child
      stops AT N inside the child (not overshooting past the EXEC return). Regression
      against `plans/stunts-milestone.md:170-172`.
- [ ] **cycle-cap** passed to `runUntilEvent` returns `cycle_budget_exhausted` at a
      child instruction boundary.
- [ ] **`step`/`step-n`/`step-over` descend into the child.** A `step` at the AH=4B
      boundary lands on the child's first instruction; `step-over` of a parent
      `INT 21h AH=4B` (the EXEC itself) runs the WHOLE child and stops on the parent
      instruction after EXEC (this is the desirable "treat EXEC as one call" case —
      verify it works via the existing return-address one-shot + SP guard).
- [ ] **Pause-mid-child then resume.** Run to a breakpoint mid-child; inspect (CPU/
      mem) leaves state byte-identical; resume reaches the child's `AH=4C` exit; a
      further resume returns to the PARENT and runs the parent's post-EXEC code,
      ending at the parent's own terminate. Assert the parent resumes at the EXEC
      call site (INT 22) with the right registers + the child's exit code in
      `ret_code` (AH=4D).
- [ ] **Launcher-chain regression (`interrupt:0x21` count).** A 2-level EXEC
      (parent→child→grandchild, or `ST.COM`-shaped) with an `interrupt:0x21` counting
      breakpoint observes a NONZERO, exact count of the inner program's INT 21h calls
      (the prior session saw zero). Determinism: identical count across two runs.
- [ ] **Two-run determinism.** Run the chain to a fixed child cycle N twice; assert
      byte-identical `machine.snapshot()` / CPU snapshot. Pause/resume variant: pause
      at N, resume to M, twice; byte-identical.

Existing tests that MUST stay byte-identical (or be re-baselined with a documented
reason):
- [ ] The current EXEC black-box tests (child exit code, child-visible state,
      env/PSP/parent-link, FCB copy) — these stop in/at the child and MUST remain
      byte-identical (no re-baseline).
- [ ] Any test/golden asserting the **parent's post-EXEC cycle count or state** —
      re-baseline IFF Phase 0 chose the extra-instruction unwind shape; the new
      number includes the real unwind cost. Each re-baseline gets a one-line "why"
      in the commit (more faithful, not a regression).
- [ ] `src/api/determinism_test.zig` off-worker grep (no `ctrl.` in `server.zig`)
      stays green — (B) adds no debug coupling to the server.
- [ ] Full `zig build test` green; the prior Stunts determinism check (byte-identical
      CPU state at a fixed cycle across two runs) still holds.

## Honesty / structural notes

- **(B) removes a fake-shaped shortcut, not a working feature.** The nested host
  loop made EXEC *look* like a black box that "just returns the child's result"; the
  faithful machine runs the child on the same CPU and unwinds through the PSP. The
  restructure aligns zdos with real DOS + all three references — exactly the project's
  charter (escape faked DOS).
- **Determinism trade is explicit, not hidden.** (B) is byte-identical within the
  child and for non-EXEC programs; across an EXEC RETURN it is byte-identical ONLY
  if Phase 0 picks the zero-extra-instruction unwind. Otherwise it adds a few real
  cycles (the unwind real DOS pays) and a small set of parent-post-EXEC goldens
  re-baseline. This is called out so the reviewer can choose the unwind shape with
  eyes open; the recommendation is to PREFER the byte-identical shape if it is
  faithful, and re-baseline only if the faithful unwind genuinely costs cycles.
- **`runGuestInt`/`runGuestFarCall` are intentionally left as nested loops.** They
  model genuinely re-entrant, bounded host→guest→host calls (mouse callback, INT 16h
  blocking read) that DO return to the host mid-flight by design. EXEC is not that
  pattern — it is a control transfer, not a call-and-return-to-host — so only EXEC's
  `runUntil` is removed. (A future enhancement could also route these through the
  controller, but that is out of scope and not a blocker; flagged, not papered over.)
- **Depth/recursion.** The bridge `MAX_DEPTH` guard (`bridge.zig:171`) protected the
  nested EXEC stack; under (B) EXEC no longer recurses host-side, so deep launcher
  chains (3+ levels) are bounded only by guest memory (real-DOS behavior), not by
  `MAX_DEPTH`. This REMOVES an artificial limit — a strict improvement — but note it
  in the commit so the depth guard's remaining users (`runGuestInt`) are understood.
- **ROADMAP:** do not edit it in this plan; it MUST be updated when this lands
  (CLAUDE.md ground rule).
```
