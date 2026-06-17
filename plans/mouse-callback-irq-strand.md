# Mouse-callback IRQ strand — BaK timer deadlock (design / fix plan)

Status: **RESOLVED.** Phase 1 reproduced the strand deterministically (byte-identical to the
live frozen BaK PIC state); the exact mechanism is now PROVEN (see Resolution); Tier-1 fix
shipped; full suite green (586). Original investigation: 3 agents + the live frozen instance.

## Resolution (what shipped)

**Mechanism (proven, empirically + in source).** The strand is a narrow **sentinel-boundary
race**, NOT general nesting. `int33.fireEventCallback` fires BaK's AX=0Ch handler via
`bridge.runGuestFarCall` with the foreground's ambient IF=1. `runGuestFarCall`'s step loop is
`run_loop.step` = `executeOne` THEN `serviceInterrupts` (`cpu/interrupts.zig:80,91`). On the
step where the handler RETFs onto the stop sentinel, `executeOne` dispatches the sentinel →
`reentry_done=true`, then `serviceInterrupts` (IF=1) acks the due timer IRQ0 (`isr[0]=1`) and
vectors to the ISR — but the loop immediately sees `reentry_done` and exits, and the
unconditional CS:IP/SP restore returns to the foreground **before the ISR steps once**, so the
EOI never runs. `isr[0]` stuck → equal-rank IRQ0 blocked forever → timer dead → hang. A repro
test sweeping the IRQ0 due-cycle finds the strand only at the sentinel-step offsets
(delta=129..132 in the test), reproducing the live `isr=1 & irr=1`, `getPendingInterrupt=null`,
frozen-tick state exactly. (Offsets inside the handler body do NOT strand — the nested ISR
EOIs normally there, which is why the bug is intermittent.)

**Fix (Tier 1 + the halt-gate corollary).**
1. `int33.fireEventCallback` clears IF before the far-call (restored by the existing eflags
   `defer`): the callback models an INT 74h/IRQ12 ISR entry (real hardware clears IF on the
   gate), and a host-driven far-call owning no interrupt frame must NOT permit a maskable IRQ
   to be acked inside it. A pending IRQ stays latched in the PIC IRR and delivers normally on
   return. This closes the strand window.
2. `bridge.runGuestFarCall` now saves/clears/restores `cpu.st.halted`. Required corollary:
   with IF cleared, a *halted* foreground could no longer be un-halted by the wakeable-IRQ
   path, so the forced far-call must run the handler regardless of the foreground HLT (on real
   hardware the delivering IRQ also wakes the CPU). Without this, a halted foreground + IF=0
   spun the step loop forever (caught by the existing Phase-3 callback tests).

**Tests:** new regression `live mouse: AX=0Ch callback must not strand a hardware IRQ
in-service …` (cycle-sweep; RED before the fix, GREEN after); suite 585→586, all green; no
golden re-mint needed (the determinism/Phase-3 callback tests still pass). The byte-identity
no-input keystone is untouched.

**Follow-up (NOT shipped — Tier 2):** the faithful end-state is to deliver the callback as a
real IRQ12 frame (raise IRQ12, deliver via the normal hardware path so the EOI is frame-bound),
per the references. Tier 1 is the invariant-justified containment; issue (B) — `runGuestFarCall`
abandoning a delivered ISR — remains latent for NON-maskable deliveries (NMI/fault) at the
sentinel boundary and is worth a debug-assert guard. See §5 Tier 2 / §9.

---

Original plan (reproduction-gated) follows. Phase 1 is the gate that decided everything; it
PASSED (strand reproduced), so Tier 1 shipped per the §5 decision rule.

## 0. Symptom

A long BaK (Betrayal at Krondor) session under `zdos --serve` hangs. Live frozen instance
diagnosed read-only over the debugger API (port 8099):

- CPU busy-waits forever at `CS:IP = 0x41CB:0x2ADE`: `cmp word [0x2c55],0 / jne` — waiting
  for the countdown flag `DS:0x2C55` (=7) to reach 0. `cycles` advance, `eip`/regs frozen,
  `iff:true`, `halted:false` (genuine spin, not a freeze).
- `[0x2C55]` is decremented only by the game's **INT 08h timer ISR** at `0x1027:5528`
  (a music/timing tick that walks an AdLib channel table). That ISR's exit is **correct**:
  `pop`s, `mov al,0x20 / out 0x20,al` (EOI to master), `iret`.
- The ISR never runs anymore: master PIC `irr[0]=1` (timer pending), `isr[0]=1`
  (in-service, **never EOI'd**), `imr` bit0=0 (unmasked), PIT ch0 actively counting
  (mode3, reload 5041 ≈ 236 Hz). An in-service IRQ0 blocks the equal-rank re-pending IRQ0
  (`pic.zig pendingLine()` rank gate) → `getPendingInterrupt()` returns null forever →
  no tick → `[0x2C55]` frozen → infinite spin.

## 1. Confirmed (high confidence)

1. **It is a zdos bug, not a BaK bug.** The game's ISR EOIs correctly; the CPU is not in
   the ISR (eip in the spin loop, regs static). An IRQ0 was acknowledged (`isr` set) and its
   EOI never executed. `[0x2C55]` is NOT decremented → the stranded ISR died in its prologue,
   before its `dec`/`mov [0x2c55]`. *(Verified live + against `src/devices/pic.zig:67-129`,
   `src/cpu/interrupts.zig:151-160`.)*
2. **The design is structurally wrong vs every reference.** dosbox-staging, dosbox-x, and
   spice86 are unanimous: the INT 33h AX=0Ch user callback is invoked **only as the body of a
   real INT 74h/IRQ12 interrupt frame**, with **the IRQ12 EOI bound to that same frame**
   (dosbox `CB_IRQ12`: `sti … out 0xA0/0x20 … retf` *before* the user sub; spice86:
   `AcknowledgeInterrupt(12)` after, but in-frame), plus an in-progress guard for *mouse*
   re-entry while higher-priority IRQs (timer/sound) nest safely. zdos instead fires it as a
   **bare `runGuestFarCall` with ambient IF and zero PIC/EOI discipline**.
3. **`fireEventCallback` never clears IF.** `src/dos/int33.zig:596-653` saves/restores
   `cpu.st.eflags` (629/638) but runs the callback via `runGuestFarCall` (`bridge.zig:657`)
   with the foreground's IF — which for the BaK spin is **IF=1**.
4. **`runGuestFarCall` runs the guest interruptibly.** Its step loop drives `run_loop.step`
   (`src/machine/run_loop.zig:41`) = `fireDue()` + `cpu.step()` each iteration, so with IF=1
   a hardware timer IRQ0 **can be acknowledged (and `isr` set) inside the callback**.
5. **New, not pre-existing.** The AX=0Ch far-call shipped earlier, but the live-mouse commits
   `408990d`/`f04da3d` made the pacer submit `input_mouse_fold` **every slice during paced
   streaming** (`src/host/run_pacer.zig:170-173`), so the callback now fires out-of-band
   repeatedly with IF=1 — which is what exposed the strand. Pre-live-mouse, the callback
   fired only on discrete scripted injects, far less often and never interleaved with live
   paced timer activity.

## 2. The two structural issues

- **(A) No interrupt-frame discipline.** The out-of-band callback runs guest code in a
  context that owns no PIC in-service bit and discharges no EOI. A hardware IRQ acknowledged
  here lands in a "frame" that can never EOI it.
- **(B) `runGuestFarCall`'s unconditional restore.** On sentinel/`reentry_done`, it restores
  CS:IP/SP unconditionally (`bridge.zig:705-714`); if a delivered (isr-set) ISR is in flight
  across that boundary, it is abandoned before its EOI.

A and B compound: (A) lets an IRQ get acked inside the far-call; (B) can drop it before EOI.

## 3. What is NOT yet proven (the honest gap)

The **exact instruction-level strand ordering is unproven.** Under strict sequential
execution, the obvious nesting (timer IRQ0 delivered inside the callback) appears to run the
ISR to *completion* (its `iret` returns before the sentinel dispatches) — i.e. it should NOT
strand. The investigating agents split:
- The mechanism-trace agent asserted a strand (RETF-to-sentinel interleaving + unconditional
  restore) with "orphaned sentinel+ISR frame on the stack" as evidence.
- The independent verifier **refuted** that stack evidence (no coherent IRET triple / the
  claimed bytes not present) — it was over-reading stale stack.

So: the **mechanism CLASS is certain** (out-of-band callback, IF=1, no EOI frame — §1.2-1.4),
but the precise ordering that yields "isr set, ISR abandoned in prologue, no EOI" is not
demonstrated. **Phase 1 exists to settle this before any fix.**

## 4. Phase 1 — Deterministic reproduction (THE GATE)

Goal: make `isr[0]` strand on demand in a hermetic test, OR prove the leading hypothesis
wrong. Emulated time is cycle-deterministic, so we can place the PIT fire at a precise cycle
that lands inside the callback.

Construct (in a new `src/dos`/`src/machine` test, machine-level so it can wire the PIT + PIC
+ a guest ISR):

1. Boot a machine. Program the PIT ch0 to a fast period (mirror BaK: mode3, a small reload).
2. Plant a guest **INT 08h ISR** in RAM that: increments a known RAM counter, `out 0x20,0x20`
   (EOI), `iret`. Point IVT[8] at it. (A faithful self-EOI timer ISR, like BaK's.)
3. Plant a guest **AX=0Ch mouse handler** that runs *several* instructions (so a timer IRQ
   has boundaries to land on mid-callback), then `retf`. Install it via the real INT 33h
   AX=0Ch path; arm the event mask.
4. Set the foreground to a spin (or any code) with **IF=1**.
5. Schedule the PIT IRQ0 to come due at a cycle that falls **inside** the callback's
   execution window, then fire the callback the way the live path does:
   `foldLiveMouse` → `injectSeamless` → `fireEventCallback` (or `injectAndFire` directly).
6. **Assert the bug:** after the callback returns, is `pic.master.isr & 1` stuck set with no
   matching EOI? Is the timer counter NOT advancing afterward (delivery dead)? Sweep the PIT
   due-cycle across the whole callback window (every offset) to find the stranding boundary.

Outcomes:
- **Strand reproduces** → mechanism PROVEN; this test is the regression. Proceed to Phase 2.
- **No strand at any offset** → the IF=1-nesting hypothesis is WRONG/incomplete. Do NOT ship
  the IF-clear. Re-open investigation (suspects: `runGuestFarCall` restore semantics in
  isolation; a mid-ISR slice-park then fold; `fireDue` double-accounting; the shared
  `reentry_done` under nesting). Update this plan with the new finding before any fix.

## 5. Phase 2 — Fix (tier chosen by what Phase 1 shows)

**Tier 1 (minimal, principled):** clear **IF for the duration of the callback far-call**.
Invariant: *a host→guest far-call with no interrupt-frame/EOI discipline must not permit
hardware-IRQ delivery* — a real mouse ISR is entered through a gate that clears IF anyway.
`fireEventCallback` already saves/restores `eflags`, so the foreground IF is restored after.
With IF=0 no IRQ can be acked inside the far-call → the strand class is closed regardless of
the exact ordering. Apply in `fireEventCallback` (and/or `runGuestFarCall` for all its
callers — note `runGuestInt`/INT 16h poll share the same risk).
- Decision rule: ship Tier 1 **iff** Phase 1 shows the strand requires an IRQ acked *inside*
  the far-call (i.e., IF=0 demonstrably stops the repro).

**Tier 2 (proper, faithful — follow-up or primary if Tier 1 insufficient):** deliver the
callback as a **real IRQ12 frame** — raise IRQ12 in the PIC and let the normal hardware
interrupt path deliver it (interrupt-gate IF clear, correct in-service nesting, in-frame EOI
all fall out of the existing timer machinery), per the reference design (§6). Also fixes
issue (B) for this path. Larger; do only if Phase 1 shows Tier 1 leaves a strand (e.g. a
mid-ISR slice-park + fold path independent of in-callback nesting).

Either tier must also address issue (B) if Phase 1 implicates the unconditional restore
directly (e.g. guard `runGuestFarCall` from returning while it left a PIC bit in-service it
acknowledged — at minimum a debug assertion to catch a future regression).

## 6. Determinism (prime directive — must hold)

- The fix changes guest-visible interrupt *timing* during the callback. That is fine **iff**
  it is a pure function of machine state (IF is), so it stays byte-identical across runs.
- **Scripted/at-cycle injects also fire `injectAndFire`** (the `input_mouse` + `fire_callback`
  seam). Clearing IF there changes their behavior vs today → **re-mint/justify any affected
  golden or `*_test` and the determinism suite**; confirm the no-input keystone is untouched.
- No host clock, no new ledger holes: a nested IRQ that IS delivered must still self-charge
  (the existing far-call charges every inner instruction).

## 7. Phase 3 — Verify

- Phase-1 repro test goes from FAILING → PASSING with the fix; `isr` never strands across the
  full PIT-due-cycle sweep.
- `zig build test` green (currently 585); re-mint any golden the IF change legitimately moves,
  with justification.
- Re-run BaK (`games/bak/KRONDOR.EXE`) under `--serve` and exercise the mouse; confirm the
  timer keeps ticking (BDA 0x46C advances) and no hang. (Can't reproduce the *original* hang
  on demand, so the hermetic Phase-1 test is the real guarantee; the live run is corroboration.)

## 8. References (agent 3, file:line)

- dosbox-staging: `src/hardware/input/mouse.cpp:445,458` (INT74 handler + `dos_cb_running`
  guard); `src/hardware/input/mouseif_dos_driver.cpp:2504-2544` (push user sub);
  `src/cpu/callback.cpp:331-360` (`CB_IRQ12`/`_RET`: `sti` + EOI-before-`retf`), `266-281`
  (`CB_IRQ0` timer self-EOI in-frame).
- dosbox-x: `src/ints/mouse.cpp:2254-2296` (INT74_Handler), `2255/2282/2308` (`in_UIR`),
  `2369-2399` (CB_IRQ12 setup, leading `sti`).
- spice86: `MouseDriver.cs:128-150` (`CanCallUserRoutine` guard + `InterruptFlag=true`),
  `305-308`; `BiosMouseInt74Handler.cs:37-64` (INT74 + `AcknowledgeInterrupt(12)` in-frame);
  `TimerInt8Handler.cs:25-50` (IRQ0 self-EOI in-frame); `InstructionExecutionHelper.cs:154`
  (IRQ entry clears IF); `Intel8259Pic.cs:349` / `DualPic.cs:392` (ISR set/clear).
- zdos (to fix): `src/dos/int33.zig:596-653` (fires via far-call, no IF/PIC discipline);
  `src/bridge/bridge.zig:657-715` (`runGuestFarCall`, ambient IF, unconditional restore);
  `src/machine/run_loop.zig:41-83`, `src/cpu/interrupts.zig:151-160`,
  `src/devices/pic.zig:67-129`, `src/host/run_pacer.zig:160-173`.

## 9. Honesty / structural notes

- We are fixing a CONFIRMED deadlock with a PARTIALLY-PROVEN mechanism. Phase 1 is mandatory:
  no fix lands on a hypothesis. If Phase 1 can't reproduce, that is a finding, not a failure —
  it redirects the investigation.
- The live `:8099` frozen instance is preserved (read-only) as ground truth; keep it until the
  Phase-1 repro matches its PIC/flag state.
- The real architectural answer is Tier 2 (route the callback through a true IRQ12 frame);
  Tier 1 is a sound, invariant-justified containment that may be sufficient. Phase 1 decides.
