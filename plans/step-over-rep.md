# Step-over a whole REP-prefixed instruction (and step-over completeness)

Status: PLAN (no code written yet). Owner: debugger / `src/debug`.

## Problem

zdos models REP **per-iteration**: one `step` advances exactly one REP iteration,
leaving `EIP` at the REP opcode (`cpu.instr_start_eip`) until `CX` hits 0 / the
ZF condition is met (`src/cpu/exec_string.zig:51-76`; the same re-entry pattern is
used by REP'd port-string ops in `src/cpu/exec_io.zig:101`). This is **correct and
faithful** — real x86 REP is interruptible at each iteration, and zdos has a
determinism test for an IRQ landing mid-REP (`src/cpu/interrupts_test.zig:254`,
"IRQ-during-REP determinism").

The gap is purely **debugger convenience**: there is no command to step *past* an
entire REP in one action. `stepOver` (`src/debug/controller.zig:394-452`)
deliberately handles only direct `CALL`/`INT` (opcodes `0xE8`/`0x9A`/`0xCD`) by
running to the return; for everything else — REP, indirect CALL, etc. — it falls
back to step-into and reports `stepped_into = true` (the no-silent-degrade ground
rule). So stepping a large `rep movsb` (e.g. CX = 60000) requires 60000 `step`
commands and *looks like a hang* to anyone using `/api/step-over`.

## Goal

Make `stepOver` step **past a whole REP** in one command — let the REP run all its
iterations (charging their real cycles, fully deterministic) and stop on the
instruction *after* the REP. Headline = REP; review the other fallbacks
(indirect CALL, software INT) and decide what to cover now vs. later. Keep the
existing direct-CALL behavior unchanged.

## References consulted

- **dosbox-x** `references/dosbox-x/src/debug/debug.cpp:961-984` (`StepOver`):
  disassembles the current instruction to get its `size`, and for
  `call`/`int`/`loop`/`rep` sets a **temporary breakpoint at `reg_eip + size`**
  (the next-instruction address) and resumes. Exactly the next-address one-shot.
- **spice86** `references/spice86/src/Spice86.Core/Emulator/Debugger/DebuggerStepHelper.cs`:
  `SetupStepOverBreakpoint(nextAddress, …)` registers a one-shot
  `CPU_EXECUTION_ADDRESS` breakpoint at the linear address of the instruction
  following the current one; `SetupStepIntoBreakpoint` is a one-shot at
  `cycles + 1`. Confirms: step-over = one-shot at the next-instruction address.
- zdos current code paths:
  - `src/debug/controller.zig:394-471` — `stepOver` + `returnSiteAfterCall`
    (the existing CALL/INT one-shot + SP-guard mechanism we mirror).
  - `src/debug/controller.zig:368-380` — `runToAddress` / `discardOneShot`
    (the one-shot `execution_address` primitive).
  - `src/debug/breakpoints.zig:27-42,152-156` — `execution_address` breakpoint
    kind + `matches` (`currentLinear(m) == k.linear`).
  - `src/cpu/dispatch.zig:52-98` — `executeOne`: prefix scan sets
    `dec.rep`/`dec.repne`; `dec.len` accumulates the byte length; sizes resolved
    by `decode.resolveSizes`.
  - `src/cpu/exec_string.zig:51-76` — the per-iteration REP re-entry
    (`cpu.st.eip = cpu.instr_start_eip` while not done).
  - `src/cpu/state.zig` / `src/cpu/cpu.zig:95` — `instr_start_eip`.
  - API: `src/api/server.zig:526-529` (`/api/step-over`),
    `src/api/worker.zig:105-108` (`.step_over` → `ctrl.stepOver()`),
    `src/api/queue.zig:76,273` (`step_over` cmd + `StepOverResult`),
    `src/api/server.zig:1081` (response: `{stop, stepped_into}`).

## Mechanism: a one-shot breakpoint at the REP's next-instruction address

"Step over a REP" = let the REP run to completion (all iterations, real cycles),
then stop. Implement it exactly like the references and like the existing CALL
path:

1. At the boundary, detect the current instruction is REP-prefixed (peek the
   bytes at CS:EIP — see "Sizing" below; the prefix is `0xF2`/`0xF3` before a
   string opcode).
2. Compute `next_linear = cs_base + instr_start_eip + instr_len`
   (the REP's own linear address plus its decoded byte length).
3. Add a **one-shot `execution_address` breakpoint at `next_linear`**
   (`set.add(.{ .execution_address = .{ .linear = next_linear } }, true)`),
   `defer discardOneShot(id)`.
4. `runUntilEvent(maxInt)`; when our one-shot fires return `step_complete` with
   `stepped_into = false`. If some *other* user breakpoint / terminal / budget
   fires first, return that (still `stepped_into = false`: we did set up a clean
   step-over, an unrelated event simply pre-empted it — same convention the CALL
   path uses).

No SP guard is needed for REP (unlike CALL): REP does not recurse and does not
push a return frame. The single equality `currentLinear == next_linear` is the
exact post-REP boundary.

### Why this is correct under an IRQ landing mid-REP (the key argument)

The naive alternative — "read CX, step CX times" — is **wrong**: if an IRQ fires
mid-REP, the CPU vectors into the ISR (pushing FLAGS/CS/IP, clearing IF), runs the
whole ISR, IRETs back to the REP opcode (because EIP was left at
`instr_start_eip`), and *resumes* the remaining iterations. A fixed iteration
count would either stop **inside the ISR** or miscount, and it would also charge
the wrong cycles.

The next-address one-shot is immune to this. The breakpoint only matches when
`currentLinear == next_linear`, i.e. when execution has genuinely *moved past* the
REP. While the REP is mid-flight, EIP is pinned at the REP opcode
(`instr_start_eip`), never at `next_linear`. While inside an IRQ ISR, CS:EIP is the
handler's address, never `next_linear` (and even if an ISR happened to contain an
instruction whose linear address equaled `next_linear`, that would be a different
CS:EIP only if segments alias — see the edge note below). The one-shot fires
**only** when the REP has truly finished and the CPU has fallen through to the
following instruction. Cycles are whatever the REP + any interleaved ISRs really
cost — no synthetic count, no perturbation, fully deterministic. This is the same
reason `runToAddress` is robust; we are reusing it.

Edge note (segment aliasing): an `execution_address` breakpoint matches on the
**linear** address. In real-mode an ISR reached through the IVT runs at its own
CS:IP; its linear address equals `next_linear` only in the pathological case where
the handler's code is mapped to the same linear bytes that follow the REP. This is
the identical caveat the existing CALL/INT one-shot already lives with (it relies
on linear-address matching plus an SP guard). For REP we add no SP guard because
REP has no stack frame; if we later want belt-and-suspenders we can additionally
require `getCx() == 0` *or* the ZF condition at the match (a REP that finished has
exhausted CX or tripped its ZF exit) — noted as an optional hardening, not
required for v1.

### Sizing the REP instruction without a full disassembler

Computing `next_linear` needs the REP's byte length. zdos has **no standalone
instruction sizer / disassembler today** — `dec.len` is produced only as a side
effect of `executeOne` (`src/cpu/dispatch.zig:31`). A general
`/api/disasm`/sizer is a separate planned milestone (task #31). **We must not
execute the REP just to learn its length** (that would advance one iteration and
defeat single-command step-over for CX-large loops, and complicate the
boundary). Two viable options:

- **Option A (recommended, no new CPU surface): size REP locally in the
  controller via the peek path.** REP *only* legally prefixes string ops, and
  every REP-able string opcode is **single-byte, no ModR/M, no immediate**:
  `MOVS/CMPS/STOS/LODS/SCAS` (`A4–A7`, `AA–AF`) and `INS/OUTS` (`6C–6F`). So the
  instruction length is fully determined by counting prefix bytes + 1. Walk the
  bytes at `cs_base + eip` with `bus.peekPhys8` (side-effect-free): consume the
  legal prefix set (`0x26/0x2E/0x36/0x3E/0x64/0x65` segment, `0x66/0x67`
  size, `0xF0` lock, `0xF2/0xF3` rep), remembering whether an `0xF2`/`0xF3` was
  seen and what the final opcode is; classify as REP-string iff a rep prefix was
  present AND the terminating opcode is one of the string opcodes above. Length =
  (bytes consumed up to and including the opcode). This is ~15 lines, bounded by
  `MAX_INSTR_LEN` (15), and needs no CPU changes. It is the *narrow* sizer: it
  only has to size REP-string forms, which are trivially regular.
- **Option B (broader, deferred): add a side-effect-free `decodeOnly`/`sizeOf`
  entry to the CPU** that runs the existing fetch+prefix-scan+ModR/M path against
  the peek bus and returns `{len, is_rep, is_string, …}` without executing or
  charging cycles. This is the right long-term home (it also unblocks `/api/disasm`
  and a general step-over-any-instruction), but it is a larger change touching
  `dispatch.zig` and a peek-mode fetch. **Defer to the disasm milestone; do not
  build it for REP step-over.**

Decision: **Option A now.** It is self-contained in `src/debug`, adds no CPU
surface, and is exactly sufficient for the headline (REP). When the disasm
milestone lands, `stepOver` can switch to the general sizer (Option B) and cover
all fallbacks uniformly.

## Scope: what step-over covers after this change

| Form | Today | After this plan |
| --- | --- | --- |
| Direct near/far CALL (`0xE8`/`0x9A`) | step-over (run to return, SP-guarded) | unchanged |
| Software INT (`0xCD imm8`) | step-over (run to return, SP-guarded) | unchanged |
| **REP/REPE/REPNE string** (`F2/F3` + string op) | step-into fallback (looks like hang) | **step-over via next-addr one-shot** (this plan) |
| Indirect CALL (`FF /2`, `FF /3`) | step-into fallback | **deferred** — needs the general sizer (Option B) to compute next-addr and an SP guard; note below |
| `LOOP`/`LOOPE`/`LOOPNE` (`E0–E2`), `JCXZ` | step-into fallback | out of scope (a LOOP is one instruction per iter that *does* move EIP each time; "step over a loop" means run-to-after-the-branch-target, a different feature — leave as step-into) |

Indirect CALL: the existing CALL path keys off the *first opcode byte* and reads
the pushed return frame *after* executing the call (`returnSiteAfterCall`,
`controller.zig:459-471`). That same after-the-fact return-frame read works for an
indirect CALL too — the only blocker is classifying `FF /2`(near)/`FF /3`(far)
vs. other `FF`-group members (`INC`/`DEC`/`JMP`/`PUSH`), which needs the ModR/M
`reg` field, i.e. a sizer/decoder. **Cover it when Option B lands**; until then it
stays a reported step-into fallback (no silent degrade). Note this explicitly in
the code comment so it is a known, intentional gap, not an oversight.

## Determinism

The stepped-over REP/CALL executes its **real instructions and real cycles**;
the debugger merely stops afterward. No synthetic cycle is charged, no host clock
is read, the one-shot is the existing state-only `execution_address` breakpoint
(matched purely on guest CS:EIP). A double-run from the same machine state lands
on the same instruction at the **same cycle** every time — including the
IRQ-mid-REP case, because the ISR's real cost is on the ledger like any other
instruction. This satisfies the prime directive with zero new timing surface.

## API decision

**Extend the existing `/api/step-over`** (and the `.step_over` queue command /
`StepOverResult`); do **not** add a flag or a new endpoint. Rationale:

- "Step over" already promises "advance past this whole instruction's effect and
  stop on the next one." REP-as-one-step is the natural completion of that
  promise, not a new mode. dosbox-x and spice86 both fold REP into the single
  step-over command.
- The response already carries `stepped_into: bool` (`server.zig:1081`,
  `controller.zig:76-81`). After this change, a `rep movsb` returns
  `stepped_into = false` (clean step-over). The indirect-CALL / other fallbacks
  still return `stepped_into = true` until Option B lands — so the API keeps
  honestly reporting "could not step over, fell back" per the ground rule, with
  no new wire fields and no breaking change for clients.

No queue/wire/JSON schema changes are required; only `controller.zig`'s
`stepOver` body changes.

## Implementation tasks

- [ ] In `src/debug/controller.zig`, add a private helper `repStringNextLinear`
      (Option A): peek bytes at `cs_base + eip` via `bus.peekPhys8`, scan the
      legal prefix set, return `?{ next_linear: u32 }` — non-null **iff** a
      `0xF2`/`0xF3` rep prefix is present AND the terminating opcode is a REP-able
      string opcode (`6C–6F`, `A4–A7`, `AA–AF`). Bound the scan by
      `MAX_INSTR_LEN`. (No CPU changes.)
- [ ] In `stepOver`, BEFORE the existing direct-CALL classification, check
      `repStringNextLinear`. If it returns a next address: add a one-shot
      `execution_address` breakpoint there, `defer discardOneShot`,
      `runUntilEvent(maxInt)`, and return `step_complete` /
      `stepped_into = false` when our id fires (else return the pre-empting
      event, `stepped_into = false`). Mirror the result-shaping of the CALL path;
      no SP guard.
- [ ] Update the `stepOver` doc-comment: REP now steps over via the next-address
      one-shot; spell out the IRQ-mid-REP correctness argument in one line; and
      note that indirect CALL / `FF`-group remain reported step-into fallbacks
      pending the general sizer (Option B / disasm milestone).
- [ ] Confirm no API/queue/wire changes are needed (only `controller.zig`).
      Leave `/api/step-over`, `worker.zig`, `queue.zig`, `server.zig` untouched.
- [ ] `zig build` + `zig build test` green.

### Tests (add to `src/debug/stepping_test.zig`, mirroring the existing CALL tests)

- [ ] **REP movsb, CX large**: lay `F3 A4` with CX = N (e.g. 64), a known source
      block; one `stepOver` lands EIP on the instruction AFTER the REP, with
      `stepped_into = false`, the full copy done (ES:DI region == source), CX = 0,
      and the cycle count == "REP fully executed" (assert equal to running N
      `stepInstruction`s from the same start).
- [ ] **REP interrupted by an IRQ mid-way** (reuse the harness style of
      `interrupts_test.zig:254`): arm IRQ to fire after k iterations into an ISR
      that IRETs; one `stepOver` still lands on the instruction AFTER the REP
      (NOT inside the ISR), with the copy complete and CX = 0. Asserts the
      one-shot did not trip inside the ISR.
- [ ] **REP with CX = 0** (no-op REP): one `stepOver` lands on the next
      instruction (the REP is a single no-op step), `stepped_into = false`.
- [ ] **Direct CALL still steps over**: regression — an existing-style CALL test
      still returns `stepped_into = false` and lands at the return site.
- [ ] **Indirect CALL still reports step-into**: `FF /2` returns
      `stepped_into = true` (documents the intentional deferred gap).
- [ ] **Determinism double-run**: from one machine state, two `stepOver`s over the
      same REP (with the mid-REP IRQ) reach byte-identical CPU snapshot + cycle.
- [ ] **Integration test** (`src/api/server_integration_test.zig` or
      `src/debug/determinism_test.zig`): boot a tiny program containing a
      CX-large `rep movsb`, drive `POST /api/step-over` once, assert the response
      `stepped_into = false` and that `GET` of CPU state shows EIP past the REP at
      the expected cycle.

## Open questions / notes

- Optional hardening (not required for v1): at the one-shot match, additionally
  assert the REP actually finished (CX exhausted or ZF-exit) as a belt-and-
  suspenders against linear-address aliasing with an ISR. Cheap; can fold into
  the match handler if a real program ever trips the aliasing edge.
- The general step-over-any-instruction (indirect CALL, `FF`-group, and dropping
  Option A in favor of a real sizer) is gated on the disassembler milestone
  (task #31). When it lands, revisit this file's scope table.
