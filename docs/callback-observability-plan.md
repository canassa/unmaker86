# Callback observability — making the INT 33h AX=0Ch mouse callback breakpointable (Option C)

Status: DESIGN proposal. No source change is made by this document.

## Revised per adversarial review

Three reviewers (determinism, mechanism, scope) hand-checked this design against the code
and converged: the design is **sound / correct / feasible**.

- **Determinism reviewer — sound with fixes.** No determinism break; the delivery cycle is
  `f(cycle counter)`. Required: explicitly clear `pending_event_mask` and lower the pending
  IRQ12 in the field-by-field `Int33.reset`; add the `Int33`→PIC raise/lower seam + IVT[0x74]
  plumbing to the snapshot/reset audit.
- **Mechanism reviewer — correct with fixes.** The trampoline (PUSHA/PUSH DS/ES → prep-trap →
  RETF into the foreground handler → handler RETF → EOI stub) hand-traces correctly; the
  `firing`-flag→PIC-ISR-bit swap is an improvement. Required: comptime placement assert; note
  the stub EOIs *after* the user sub (IF stays 0 through the handler); document the
  no-stack-switch foreground-stack model.
- **Scope reviewer — acceptable with additions.** The live/seamless path is already covered
  (both inject paths share the `fireEventCallback` sink). Required: correct the doc nits below.

What this revision changes vs the prior draft:

1. **Delivery is now CONDITIONAL, not forced.** Today `fireEventCallback` *forces* delivery
   (clears IF, un-halts a HLT). Under C the event is delivered only when the guest reaches an
   IF=1 boundary with IRQ12 unmasked; an IF=0 / IRQ12-masked / HLT-with-IF=0 foreground
   **defers or drops** it. More faithful, still deterministic, but it is a presence/absence
   change — not "only timing shifts." (BaK runs IF=1, so it is unaffected.) See §4.
2. **Unmask timing resolved** to `Int33.reset` (driver reset) **and** AX=000C handler-install
   (belt-and-suspenders), not POST. See §0/§4/§7.
3. **`Int33.reset` state-hole + seam:** reset must clear `pending_event_mask = 0` and lower a
   pending IRQ12; it currently has no PIC handle, so the plan adds a bound pic-raise/lower seam
   (mirroring the keyboard's `raise_fn`) + IVT[0x74] plumbing. See §4 checklist.
4. **`clickMouse` runs a short tick after the release inject** so a click stays self-contained
   (both press AND release callbacks delivered before it returns). See §4.
5. **Tests are RESTRUCTURED, not "re-blessed."** The synchronous "handler ran with no
   intervening run" assertions go RED and must become inject → run → assert. See §4/§7.
6. **Stack-footprint regression honestly stated:** the handler runs on the FOREGROUND stack
   with NO stack switch (~28 bytes), vs today's host-side save + ~4-byte sentinel. C is *more*
   foreground-stack-hungry and *less* faithful on stack handling than a real MS driver (which
   switches to its own ISR stack). Chosen anyway (simplicity); add an SP-floor overflow test.
7. **Sub-decisions A/B/C are SETTLED** (driver raises IRQ12 directly; OR-accumulate coalescing;
   INT 23h stays synchronous) and baked in below, with their limitations stated.
8. **Doc nits:** INT 23h uses `runGuestInt` not `runGuestFarCall`; after migration
   `runGuestFarCall` has ZERO production callers; the cycle cost goes UP (not "same set of
   instructions"); add the comptime placement assert.

## Problem

zdos fires the guest's INT 33h **AX=000C mouse event handler** SYNCHRONOUSLY, out of
band, as a host-driven far-call:

- `Int33.injectAndFire` / `Int33.injectSeamless` → `Int33.fireEventCallback`
  (`src/dos/int33.zig:699`) → `Bridge.runGuestFarCall` (`src/bridge/bridge.zig:657`).
- `runGuestFarCall` runs its OWN inner `while (!reentry_done)` loop
  (`src/bridge/bridge.zig:709-715`) calling the injected stepper `step_one`
  (= `Machine.stepOnceThunk` → `run_loop.step`, `src/machine/machine.zig:464-467`).

The debugger's per-instruction gate lives ABOVE the machine: `Controller.runUntilEvent`
captures `seqBefore`, calls `m.step()`, then `scanBreakpoints`
(`src/debug/controller.zig:444-464`). The bridge's inner loop calls `run_loop.step`
RAW — it never returns to `runUntilEvent` — so **breakpoints and watchpoints cannot
fire inside the callback**. Worse, a watched access inside the callback advances
`bus.last_mem_watch.seq` while the controller is parked at a command boundary; the next
`run`'s `seqBefore` baseline (`bp.seqBefore`, `src/debug/breakpoints.zig:193-198`) is
taken AFTER that, so the hit is silently swallowed (`bp.matches`,
`src/debug/breakpoints.zig:165-167`).

The mouse AX=0Ch callback is the LAST input modality that took the synchronous
host-serviced shortcut. The KEYBOARD already runs the faithful hardware way (8042 →
IRQ1 → INT 09h delivered through the one controller-owned loop), and so is fully
breakpointable. This plan makes the mouse callback match it.

---

## §0. FEASIBILITY VERDICT (this gates everything) — GREEN

**The PIC already fully models IRQ12 / INT 74h. No new interrupt-controller machinery
is required.**

Concretely, today, with no changes:

- The 8259 cascade is wired and the slave is initialized to vector base 0x70
  (`src/bios/bios.zig:256-259`: ICW1 0x11, ICW2 0x70, ICW3 0x02, ICW4 0x01). So slave
  line 4 = IRQ12 = vector **0x74**.
- `Pic.raiseIrq(12)` sets slave IRR bit4 AND master IRR bit2 (the cascade)
  (`src/devices/pic.zig:151-160`). `getPendingInterrupt` resolves the slave through
  master IRQ2 and returns 0x74; `ackIrq(0x74)` sets ISR on BOTH the slave and master
  IRQ2 (`src/devices/pic.zig:188-203`). This is **already covered by a passing test**:
  `src/devices/pic_test.zig:83-89` (`raiseIrq(12)` → `getPendingInterrupt()==0x74` →
  `ackIrq(0x74)`).
- The maskable-IRQ delivery path is generic: `serviceInterrupts` samples
  `pic.getPendingInterrupt()` at every instruction boundary when IF=1, acks, charges
  `cycles.interrupt_delivery`, and delivers through the IVT
  (`src/cpu/interrupts.zig:151-160`). `deliverViaIvt` pushes FLAGS/CS/IP and **clears IF
  and TF** (`src/cpu/interrupts.zig:212-219`) — exactly the hardware INT gate.
- A slave-EOI return tail already exists: `CbType.iret_eoi_pic2` =
  `PUSH AX; MOV AL,0x20; OUT 0xA0,AL; OUT 0x20,AL; POP AX; IRET`
  (`src/bridge/bridge.zig:254-264`).
- The bridge already builds **guest-asm trampolines** in the BIOS ROM image
  (`emitPollLoop`, `emitInt16Hybrid`, `emitExecRetf` — `src/bridge/bridge.zig:331-412`),
  which is the exact tool needed for the INT 74h stub.

What is MISSING (and is the whole scope of this change):

1. **No device raises IRQ12.** The 8042 aux/mouse channel is deliberately NOT wired
   (`src/devices/keyboard.zig:27-28, 470-473`); zdos models the INT 33h *driver*, not the
   PS/2 controller. So the INT 33h driver must raise IRQ12 itself (settled sub-decision A).
   **Limitation of this driver-level model:** the aux byte is never read, and a guest that
   installs its OWN INT 74h handler (expecting to read the PS/2 packet off port 0x60) is
   **unsupported** — zdos owns INT 74h and routes straight to the INT 33h AX=0Ch handler.
2. **IRQ12 is masked at POST.** `programPic` writes slave IMR = 0xFF
   (`src/bios/bios.zig:261`). On real hardware the mouse-driver TSR unmasks IRQ12 on
   install; the host-emulated INT 33h driver does the analogous unmask. **Settled:** unmask
   in **`Int33.reset`** (AX=0000 driver-reset) AND again at **AX=000C handler-install**
   (belt-and-suspenders — closes the silent-no-fire hole if a guest installs a handler
   without a fresh driver reset). NOT at POST: the slave IMR stays 0xFF from `programPic`
   until a driver reset, exactly as a real machine with no mouse TSR loaded.
3. **No INT 74h vector / ISR.** IVT[0x74] points at the unhandled-default stub
   (`initIvt`, `src/bios/bios.zig:275-301`). A host INT 74h ISR + a foreground
   trampoline to the user handler must be installed (re-planted at POST on every boot).

None of these need new PIC/IRQ primitives — they are device-side wiring on top of
machinery that is present and tested. **Verdict: Option C is feasible with the existing
architecture.**

---

## §1. Current mouse delivery path, exactly

Entry points (both fire-and-forget — no host use of the result):

- Scripted: `Controller.injectMouse` (`src/debug/controller.zig:948-966`) →
  `Int33.injectAndFire` (`src/dos/int33.zig:783-820`). The held-CLICK form
  `Controller.clickMouse` (`src/debug/controller.zig:994-1002`) presses, runs a dwell,
  releases — each press/release going through `injectMouse`.
- Live/seamless: `worker.foldLiveMouse` (`src/api/worker.zig:232-246`) →
  `Controller.injectMouseSeamless` → `Int33.injectSeamless`
  (`src/dos/int33.zig:858-900`).

Both converge on `Int33.fireEventCallback` (`src/dos/int33.zig:699-774`):

1. Re-entrancy guard `self.firing` (`int33.zig:700, 705-706`): early-return if already
   firing; set on entry, cleared on `defer`. TRANSIENT — deliberately NOT snapshotted
   (`int33.zig:145-153, 949-953`) because the far-call always completes within one
   command, so it is invariably false at a snapshot boundary.
2. Gate: a handler must be installed (`handler_seg|handler_off != 0`) and
   `condition & handler_mask != 0` (`int33.zig:701-703`).
3. **Save foreground context** (the ISR-frame model, `int33.zig:731-746`): the FULL GP
   register file `cpu.st.regs`, `eflags`, and DS/ES selector+base are saved and restored
   by `defer`, because `runGuestFarCall` only restores CS:IP/SP. Without this, the
   handler's scratch writes corrupt the parked foreground (observed as BaK top-of-screen
   VRAM corruption — `int33.zig:719-730`).
4. Set the Microsoft callback ABI into the live regs (`int33.zig:748-753`):
   AX=fire_bits, BL=buttons (BH=0), CX=POS_X, DX=POS_Y, SI=mickey_x, DI=mickey_y.
5. **Force IF=0** (`int33.zig:771`): the bare far-call, unlike a real INT, does not clear
   IF; an ambient IF=1 let a hardware IRQ be acknowledged INSIDE the far-call and
   stranded the PIC in-service bit with no EOI (the "BaK timer deadlock" —
   `plans/mouse-callback-irq-strand.md`, reproduced by `src/dos/integration_test.zig:1218-1244`).
   `runGuestFarCall` additionally force-clears `halted` for the run and restores it
   (`src/bridge/bridge.zig:686-687, 727`), because a halted foreground + IF=0 callback
   would otherwise spin forever.
6. `br.runGuestFarCall(seg, off)` (`int33.zig:773`): pushes a far-return frame pointing
   at the **stop-sentinel** slot (`src/bridge/bridge.zig:689-705`), sets CS:IP to the
   handler, and runs the inner step loop until the handler's `RETF` lands on the stop
   sentinel (`reentry_done`). It restores CS:IP/SP + the decode seam scratch
   (`bridge.zig:717-727`).

**Cycle charging:** every instruction the handler executes is retired by
`run_loop.step` inside the inner loop, charging real per-instruction cost through the
normal ledger — there is no hole. This part is already correct and is PRESERVED by
Option C (foreground execution retires the same instructions through the same
`run_loop.step`).

The defects are exactly (5)+(6): the inner loop is below the controller's gate (no
breakpoints/watchpoints), and the synchronous-far-call shape forced the IF=0 + halt
workarounds and the silent-swallow.

---

## §2. Does zdos model an IRQ12 / INT 74h path today?

**The PIC does; nothing drives it.** See §0 for the proof that `raiseIrq(12)` →
`getPendingInterrupt()==0x74` → `ackIrq(0x74)` works and is tested
(`src/devices/pic_test.zig:83-89`).

The KEYBOARD is the template to copy, and it proves the deferred-delivery shape end to
end:

- The 8042 device pushes a scancode and asserts IRQ1 by calling the bound PIC raise seam
  `Keyboard.raiseIrq1` → `picRaiseThunk` → `Pic.raiseIrq(1)`
  (`src/devices/keyboard.zig:196-198, 259-265`; wired at `src/machine/machine.zig:427-428`).
  Setting an IRR bit is **timing-neutral** — no scheduler entry, no ledger charge
  (`keyboard.zig:33-36`).
- The injection entry `Controller.injectScancode` (`src/debug/controller.zig:911-926`)
  is a deliberate new INPUT at the cycle-exact command boundary; it returns immediately.
- On the next `run`/`step`, `runUntilEvent`'s `m.step()` → `serviceInterrupts` (IF=1)
  acks IRQ1 and delivers INT 09h via the IVT (`src/cpu/interrupts.zig:151-160`). The host
  ISR `int09.handle` reads port 0x60 and fills the BDA ring; the EOI is discharged by the
  slot's `iret_eoi_pic1` return tail (`src/bios/int09.zig:1-7`,
  `src/bios/bios.zig:106`). Because delivery happens inside the ONE controller-owned
  loop, every ISR instruction is breakpointable.

An analogous IRQ12 → INT 74h mouse path is reachable with this exact machinery: the INT
33h driver raises IRQ12, and a host INT 74h ISR (planted like INT 09h, with a foreground
trampoline to the user handler) delivers it through the same loop. The only device-side
gap vs the keyboard is that there is no aux device object — the driver raises IRQ12
directly (see §7 sub-decision A).

---

## §3. The trampoline in zdos's vocabulary

zdos's "trampoline" vocabulary is: real guest-code stubs planted in the BIOS ROM image
(`emitPollLoop`/`emitInt16Hybrid`/`emitExecRetf`), `0xFE 0x38 <id>` host-trap stubs with
typed return tails, and far-return-frame pushes onto the guest stack
(`runGuestFarCall`). Option C composes these into a foreground INT 74h ISR.

### Mechanism (recommended)

Plant a new guest-asm stub in the BIOS image, immediately after `EXEC_RETF_PHYS`
(`src/bridge/bridge.zig:394`), and point IVT[0x74] at it. Call it
`emitInt74Trampoline`. It is the faithful PS/2-mouse-ISR shape:

```
INT74_ENTRY:                  ; IVT[0x74] -> here. CPU already pushed FLAGS/CS/IP, IF=0.
    PUSHA                     ; 60        save foreground GP regs (ISR discipline)
    PUSH DS                   ; 1E
    PUSH ES                   ; 06
    <trap int74_prep_id>      ; FE 38 id  host Int74.prepare(cpu): see below
    RETF                      ; CB        enter the user handler (or fall to EOI_STUB)
EOI_STUB:                     ; the user handler's RETF returns here
    POP ES                    ; 07
    POP DS                    ; 1F
    POPA                      ; 61        restore the foreground GP regs
    PUSH AX                   ; 50        preserve AL across the EOI MOV
    MOV AL,0x20               ; B0 20
    OUT 0xA0,AL               ; E6 A0     slave EOI
    OUT 0x20,AL               ; E6 20     master cascade EOI
    POP AX                    ; 58
    IRET                      ; CF        unwind the INT 74h frame; restores IF
```

`Int74.prepare` is the host trap (signature like `int09.handle(self, cpu, br)`). It runs
AFTER `PUSHA/PUSH DS/PUSH ES` saved the foreground context onto the guest stack, so it is
free to overwrite the live GP regs with the callback ABI. It:

1. Reads the driver's staged pending event (see §4). If there is no pending event, or no
   handler installed, or the mask does not intersect: push the EOI_STUB far-ptr as BOTH
   the return frame AND the RETF target (so the stub's `RETF` lands straight on EOI_STUB
   — a no-op delivery that still EOIs). Clear the pending flag. Return.
2. Otherwise set the live regs to the ABI (AX=fire_bits, BL=buttons, CX=POS_X, DX=POS_Y,
   SI=mickey_x, DI=mickey_y) — the SAME values `fireEventCallback` sets today
   (`int33.zig:748-753`), now applied AFTER `PUSHA` so the foreground copies are safely on
   the stack.
3. Push the far frames onto SS:SP using the existing `cpu.segWrite16(.ss, …)` +
   SP-decrement idiom (identical to `src/bridge/bridge.zig:694-699`), in this order so
   real-mode `RETF` semantics (pop IP then CS) route correctly:
   `push EOI_seg; push EOI_off; push handler_seg; push handler_off`.
   The stub's `RETF` pops `handler_off,handler_seg` → enters the user handler as
   FOREGROUND code. The handler's terminating `RETF` pops `EOI_off,EOI_seg` → EOI_STUB.
4. Clear the driver pending flag (the IRQ has now been consumed; the slave ISR-in-service
   bit, set by `ackIrq`, blocks any re-delivery until the EOI in the stub — the hardware
   handles re-entrancy, so the host `firing` flag is no longer needed).

`int74_prep_id` is a normal `allocCallback(.iret, .irq)` slot; its 3-byte trap is what
the stub's `FE 38 id` invokes; its OWN return tail is never executed (the stub continues
into `RETF`), exactly like the poll-loop has-key/dequeue slots whose `cb_type` is inert
(`src/bios/bios.zig:113-117`). It charges the `.irq` synthetic cost (120,
`src/bridge/cb_cost.zig:86`).

**Placement assert (required).** Plant the stub at a fixed `INT74_PHYS` after
`EXEC_RETF_PHYS` and add a comptime guard mirroring `EXEC_RETF_PHYS`
(`src/bridge/bridge.zig:396-400`): `std.debug.assert(INT74_PHYS + INT74_LEN <= 0x100000)`,
so the multi-byte stub provably fits inside the BIOS ROM window.

**EOI-after-the-user-sub (a deliberate divergence).** The stub EOIs the slave+master PIC
only AFTER the user handler returns (in EOI_STUB, just before `IRET`). Because the INT gate
cleared IF (`src/cpu/interrupts.zig:212-219`) and nothing re-enables it inside the stub, IF
stays 0 for the entire handler duration. This blocks mouse-callback re-entrancy for as long
as the handler runs — the slave ISR-in-service bit set by `ackIrq` is still up, so a fresh
IRQ12 cannot be recognized even if one is raised mid-handler. Real dosbox EOIs *before* the
callout and STIs, allowing re-entry. zdos's order is safe and simpler, and BaK's handler
never STIs, so the divergence is unobservable for the target program. Stated, not hidden.

**Foreground-stack footprint (chosen no-stack-switch model).** The handler runs on the
FOREGROUND SS:SP with NO stack switch. The stub consumes PUSHA(16) + DS(2) + ES(2) +
far-return frame(8) ≈ **28 bytes** of the foreground stack, vs today's host-side register
save + ~4-byte stop-sentinel frame. A real MS mouse driver switches to its own private ISR
stack before calling the handler. So Option C is BOTH more foreground-stack-hungry AND less
faithful on stack handling than real hardware. This is the deliberately chosen model
(simplicity; no second stack to allocate/snapshot) — do NOT claim "strictly more faithful."
The risk (a deep guest stack near a segment floor overflowing under the extra ISR frame) is
covered by an SP-near-segment-floor overflow test (see §7).

### Contrast with today's host-C `runGuestFarCall`

| | Today (`runGuestFarCall`) | Option C (INT 74h trampoline) |
|---|---|---|
| Who drives the handler's steps | host `while` loop in the bridge, below the controller gate | the ONE controller-owned `runUntilEvent` loop |
| Breakpoints/watchpoints inside handler | invisible | scanned per instruction (free) |
| Register save/restore | host-side in `fireEventCallback` (`int33.zig:731-746`) + a `defer` | guest `PUSHA/PUSH DS/ES` … `POPA` — all on the guest stack, snapshot-free, faithful |
| IF handling | forced IF=0 + halt-clear workarounds (`int33.zig:771`, `bridge.zig:686-687`) | the real INT gate clears IF (`interrupts.zig:218`); EOI_STUB IRET restores it |
| EOI / PIC discipline | none (the strand bug) | slave+master EOI in the stub, in-band, before IRET |
| Delivery timing | synchronous at inject (out of band) | deferred to the next IF=1 boundary during a `run` |

The host `runGuestFarCall` is no longer on the mouse path — and the mouse was its ONLY
production caller, so after migration `runGuestFarCall` has ZERO production callers (only
`src/bridge/bridge_test.zig` exercises it). The genuinely host-needs-the-result re-entrant
call that remains is INT 23h, which uses `runGuestInt` (NOT `runGuestFarCall`) at
`src/dos/int21.zig:359` (see §5).

---

## §4. Determinism + timing

**Invariant preserved: emulated time is a pure function of the cycle counter, never host
scheduling.**

- **Raising IRQ12 is timing-neutral and cycle-exact.** Inject sets the slave IRR bit at
  the current command boundary (same as `Keyboard.pushScancode`); no scheduler entry, no
  ledger charge. The *delivery* cycle is the next instruction boundary at which the
  guest itself has IF=1 — a function of the GUEST's own deterministic execution, not the
  host clock. This is identical in shape to the keyboard, which is already proven
  deterministic (double-mint tests).

- **Deferred state is fully snapshotted.** The pending event lives in exactly two places,
  both already (or newly) captured: (a) the PIC slave IRR/ISR (`Pic.Snapshot`,
  `src/devices/pic.zig:344-354`), and (b) a NEW `Int33` field
  `pending_event_mask: u16` (the accumulated `condition & handler_mask` bits awaiting
  service), added to `Int33.Snapshot`/`restore` (`src/dos/int33.zig:955-1053`). A
  snapshot taken with an IRQ12 in flight restores byte-identically. This is *cleaner*
  than today: the transient `firing` flag (deliberately un-snapshotted, `int33.zig:949`)
  goes away — re-entrancy is now enforced by the slave ISR-in-service bit, which IS
  snapshotted.

- **Composition with the held-CLICK dwell + the clickMouse fix** (`Controller.clickMouse`,
  `src/debug/controller.zig:994-1002`): press → `injectMouse` raises IRQ12 → `runDwell` runs
  the machine for `dwellCycles(hold_ms)` → IRQ12 is delivered DURING the dwell run, so the
  press handler executes inside the controller loop, fully observable and breakpointable, at
  a deterministic cycle. The release inject, however, raises IRQ12 and then `clickMouse`
  RETURNS with no further run — under the old synchronous path the release callback fired
  before return, so the post-condition "a click delivers BOTH callbacks" would regress.
  **Fix (settled):** `clickMouse` runs a SHORT tick (`runUntilEvent` of a small fixed budget)
  after the release inject so the release callback is delivered before it returns, preserving
  today's self-contained-click post-condition. The dwell's `dwell_complete`/breakpoint
  reasons (`src/debug/controller.zig:1010-1016`) are unchanged; a breakpoint inside the press
  callback now correctly pre-empts the dwell (today it cannot fire at all). The release tick's
  stop reason must be surfaced (a breakpoint inside the release handler is a real stop, not
  swallowed).

- **`Int33.reset` state-hole + the missing PIC seam (required fix).** `Int33.reset`
  (`src/dos/int33.zig:268-294`) is FIELD-BY-FIELD (CLAUDE rule 5: every field reset), so it
  must EXPLICITLY clear the new `pending_event_mask = 0` and LOWER any pending IRQ12 — a stale
  pending mask or a stuck slave IRR bit surviving a reset would deliver a phantom callback on
  the next `run` and break determinism across reset boundaries. But `Int33.reset` has NO PIC
  handle today. The plan adds a bound **pic-raise/lower seam** on `Int33` (mirroring the
  keyboard's `raise_ctx`/`raise_fn` at `src/machine/machine.zig:427-428`), wired in
  `machine.wire`, plus IVT[0x74] plumbing so reset can re-point the vector at the stub. Both
  the seam (a function pointer, re-bound on restore) and `pending_event_mask` (POD) are
  snapshot-safe. See the determinism-audit checklist.
- **AX=5/6 press/release counters and INT 33h state are unaffected.** Those are updated
  by `setButtons` (`int33.zig:474-493`) at inject time, BEFORE the callback, and are
  independent of when/whether the callback runs. The callback only READS driver state.

- **Coalescing semantics (settled sub-decision B).** Today each inject fires its callback
  synchronously. Under Option C, if a second event injects before INT 74h is serviced, only
  one IRQ12 is pending; `pending_event_mask` **OR-accumulates** the condition bits across
  injects (matching dosbox-staging, where the driver tracks pending event bits and reports
  them on the next IRQ service). The reported CX/DX/BL/SI/DI are the LIVE driver state at
  prepare time (current position/buttons; the mickey counters SI/DI are the current
  accumulator, zeroed on the next AX=0B as usual). This is faithful to real PS/2 (one IRQ per
  "the driver has news", state read live by the ISR).
  - **Deterministic for scripted injects** (the OR-accumulate result is a pure function of the
    inject sequence + the guest's IF/mask timeline).
  - **Wall-time-dependent for the LIVE path** (`worker.foldLiveMouse`): whether two browser
    mouse events coalesce depends on how many guest cycles elapsed between them, which tracks
    host arrival time. This is already a non-golden path (the live mouse is interactive, never
    cycle-reproduced), so coalescing introduces no NEW non-determinism there.
  - **Dwell press+release coalescing under IF=0** (the case to call out): if the guest sits at
    IF=0 (or HLT-with-IF=0, or IRQ12 masked) across BOTH the press and the release of a
    `clickMouse`, the two events OR-accumulate into one `pending_event_mask`, and exactly ONE
    INT 74h is delivered when IF next goes 1 — reporting the LIVE (post-release) button state,
    i.e. the net "button is now up" with both down+up bits set in AX. Under the old
    synchronous path BOTH callbacks fired (delivery was forced regardless of IF). This is the
    delivery presence/absence change spelled out below — faithful to real PS/2 (an ISR that is
    masked out simply misses edges) but a behavior change a test or golden can see.

### What changes observably (two distinct changes: cycle position AND delivery presence)

Two things change. Be honest about BOTH.

**(1) Cost goes UP, and position shifts.** Today the callback runs as a bare far-call.
Under Option C it runs as a real interrupt, so it charges STRICTLY MORE than today, not
"the same set of instructions in a shifted position":

- `cycles.interrupt_delivery` for the INT gate (`src/cpu/interrupts.zig:155`),
- the prep trap's `.irq` synthetic cost = 120 (`src/bridge/cb_cost.zig:86`),
- the stub's own instructions: PUSHA / PUSH DS / PUSH ES / RETF / (handler) / POP×2 / POPA /
  PUSH AX / MOV / OUT×2 / POP AX / IRET.

Plus the delivery *position* moves from the inject boundary to the next IF=1 boundary during
a `run`. So both the absolute cycle counts AND latch-vs-cycle pinning move.

**(2) Delivery is now CONDITIONAL — a presence/absence change.** Today `fireEventCallback`
FORCES delivery: it clears IF (`int33.zig:771`) and un-halts a HLT
(`src/bridge/bridge.zig:686-687`) so the handler always runs at inject time. Under Option C
the handler runs only when the guest reaches an instruction boundary with **IF=1 AND IRQ12
unmasked**. A foreground at IF=0, with IRQ12 masked, or halted with IF=0 **defers** the event
(it fires later when IF goes 1) or, if coalesced with a newer event first, effectively
**drops** the older edge (only the OR-accumulated mask survives). This is MORE faithful (a
masked-out ISR misses edges on real hardware) and still fully deterministic for scripted
injects, but it is a real behavioral change: **delivery now REQUIRES guest IF=1 + IRQ12
unmasked.** BaK runs its event handler with IF=1 and unmasks via the driver reset, so BaK is
unaffected; a contrived guest that injects under IF=0 will see different delivery.

**Test impact — RESTRUCTURE, not "re-bless".** The existing mouse-callback tests assert the
handler ran with NO intervening run (they call `injectAndFire` then immediately read the latch
slots). Under Option C nothing runs at inject time, so those assertions go RED and must be
RESTRUCTURED to **inject → run → assert**:

- `src/dos/integration_test.zig:1098-1216`: the "handler RAN" assertions
  (`1125-1131`, `1162-1172`, `1215`) and their `cycles > cyc_before` checks (`1131`, `1172`)
  break and must move after an explicit `run`. NOTE: that inserted run is itself perturbed —
  the pending IRQ12 is delivered at its HEAD (the first IF=1 boundary), BEFORE the test's
  intended AX=03 body, so the test must account for the handler running first. The "callback
  does NOT fire outside the mask" test (`1140-1173`) still holds (a masked-out event raises no
  IRQ12), but its `cyc_before == cycles` check (`1164`) now also depends on no spurious IRQ12.
- The **double-mint EQUALITY lines** (`1209-1213`) stay GREEN — determinism (run A == run B)
  is preserved by construction; only the absolute values move.
- `src/dos/integration_test.zig:1218-1464` (the IRQ-strand reproduction): under Option C the
  strand is structurally impossible (INT 74h owns a real frame and EOIs in-band), so this test
  is **re-purposed** to assert that an IRQ0 landing anywhere in the callback window is delivered
  and EOI'd normally with IRQ12 also cleanly EOI'd — the *opposite* assertion. The IF=0 forcing
  and the halt-clear hack (`int33.zig:771`, `bridge.zig:686-687`) are deleted.
- The BaK driving recipe (`plans/krondor-milestone.md`): BaK installs an AX=0Ch handler and
  never polls AX=03. Under Option C its handler runs on IRQ12 service during each `run`, with
  the same register ABI it gets today. Re-validate end-to-end (cursor tracks, menu clicks
  register), and re-establish any cycle-pinned golden against the new (faithful) path.

Determinism itself is NOT weakened: the new delivery cycle is `f(cycle counter)`, every
retired instruction charges through the normal ledger, the deferred state is snapshotted, and
there is no host clock/RNG/scheduling dependence on the scripted path. What changes is the
faithfulness contract (delivery now respects IF/mask) and the absolute cost — both improvements,
both visible to current tests.

---

## §5. Scope: which callbacks migrate

Production re-entrant host→guest call sites (verified by grep):

| Call site | What it is | Host needs the result? | Classification | Outcome |
|---|---|---|---|---|
| `Int33.fireEventCallback` → `runGuestFarCall` (`int33.zig:773`); reached by `injectAndFire`/`injectSeamless` (scripted + live mouse) | the AX=0Ch mouse event handler | NO — the return value is discarded; the `defer` only restores foreground regs | **fire-and-forget** | **MIGRATE to the INT 74h foreground trampoline → becomes first-class debuggable** |
| `breakTest` → `runGuestInt(0x23)` (`src/dos/int21.zig:350-363`) | the INT 23h Ctrl-C handler, invoked mid-INT-21h host dispatch | YES — continue-vs-abort is decided by the handler's return form; the host service resumes based on it (`int21.zig:331-349`) | **host-needs-the-result** | **STAYS synchronous** (`runGuestInt`); same observability gap, out of scope here |
| EXEC child launch | — | — | already de-nested | runs on the controller loop via `emitExecRetf` (`src/bridge/bridge.zig:385-412`, `src/dos/loader.zig`); already breakpointable |
| EMS / BIOS dispatch (`int67`, the BIOS INTs) | host-only services | n/a — they run ZERO guest instructions | not re-entrant | unaffected |

`runGuestFarCall` has exactly ONE production caller (the mouse). `runGuestInt` has exactly
ONE (INT 23h). After this change `runGuestFarCall` has no production callers; keep it (and
its tests `src/bridge/bridge_test.zig:110-173`) for now as the documented host→guest
primitive, or remove it in a follow-up.

**Why leaving INT 23h synchronous is acceptable:** it is a host-needs-control-flow
re-entrant call mid-INT-21h, the supported path is the IRET/CONTINUE case
(`int21.zig:331-344`), Ctrl-C is scripted input that is rarely the debugging target, and a
correct foreground migration requires modeling the abort-by-RETF-with-CF return form
(explicitly out of scope today, `int21.zig:338-344`). It can adopt the same trampoline
pattern later if a user needs to breakpoint inside a Ctrl-C handler. This is stated, not
hidden.

---

## §6. The watchpoint silent-swallow

**Option C fixes it automatically — no separate fix needed.**

The swallow happens because `runGuestFarCall`'s inner loop calls `run_loop.step` raw,
below the controller, while the controller is parked at a command boundary; a watched
access advances `bus.last_mem_watch.seq`, but the next `run`'s `seqBefore`
(`src/debug/breakpoints.zig:193-198`) is taken AFTER that, so `bp.matches`
(`src/debug/breakpoints.zig:165-167`) sees a stale seq and drops it.

Under Option C the handler runs as foreground inside `runUntilEvent`: every instruction
is bracketed by `seq_before = bp.seqBefore(...)` / `m.step()` / `scanBreakpoints`
(`src/debug/controller.zig:454-458`). A watched read/write inside the handler advances
`last_mem_watch.seq` exactly one step before it is scanned with the matching baseline, so
the hit fires at that boundary like any other. The same applies to `io` watchpoints
(`last_io_watch.seq`) and to `interrupt` breakpoints (`last_delivered.seq`) — all are
scanned per foreground step. The fix is a consequence of moving the gate, not extra code.

---

## §7. Plan + risk

### Phased implementation

**Phase A — INT 74h trampoline plumbing (bridge + BIOS).**
- `src/bridge/bridge.zig`: add `emitInt74Trampoline(image)` (guest-asm:
  PUSHA/PUSH DS/PUSH ES / `FE 38 prep_id` / RETF / EOI_STUB) next to `emitExecRetf`; add an
  `INT74_PHYS = EXEC_RETF_PHYS + 1` + `INT74_LEN` + `int74SegOff`, and the comptime placement
  assert `std.debug.assert(INT74_PHYS + INT74_LEN <= 0x100000)` mirroring
  `src/bridge/bridge.zig:396-400`; add a byte-exact emit test (mirror `bridge_test`/the
  `emitPollLoop` test style). ~80 LOC + test.
- `src/bios/bios.zig` (or DOS — sub-decision A puts the driver-facing wiring in DOS): register
  `int74_prep` via `allocCallback(.iret, .irq)`, emit the stub into `bios_image` in `post`
  (`machine.zig:485-524` order), and point IVT[0x74] at the stub. Re-confirm `Machine.boot`
  resets-first so POST re-plants IVT[0x74] + the stub on EVERY boot (boot-idempotency, per the
  load-without-reset fix already in place). ~30 LOC.

**Phase B — driver-side deferral (INT 33h).**
- `src/dos/int33.zig`: add `pending_event_mask: u16` (+ Snapshot/restore — extend
  `Int33.Snapshot`/`snapshot`/`restore` at `src/dos/int33.zig:955-1053`, and DROP the now-dead
  `firing` flag and its snapshot exemption comment at `int33.zig:949-953`); replace
  `fireEventCallback`'s synchronous body with: OR-accumulate the masked condition into
  `pending_event_mask` and call the driver's `raiseIrq12()` seam; DELETE the foreground
  save/restore block, the IF=0 force, and the `firing` flag. Add `Int74.prepare` (sets the
  ABI regs + pushes the far frames, or the no-op-EOI fallback). ~120 LOC net (much of it
  deletions).
- **The `Int33`→PIC seam + IVT plumbing (the under-counted piece).** `Int33` gains a bound
  PIC raise/lower seam (`raise_ctx`/`raise_fn`/`lower_fn`, mirroring `Keyboard` at
  `src/machine/machine.zig:427-428`), wired in `machine.wire`, plus an IVT[0x74] re-point
  helper. Without this seam `Int33.reset` cannot lower a pending IRQ12. ~25 LOC (decl + wire +
  restore re-bind).
- **`Int33.reset` state-hole (required, CLAUDE rule 5).** `Int33.reset`
  (`src/dos/int33.zig:268-294`) is field-by-field, so it MUST add `pending_event_mask = 0`,
  call the seam to LOWER any pending IRQ12, and re-point IVT[0x74] at the stub; AND unmask IRQ12
  in the slave PIC (the "mouse-driver TSR unmasks its IRQ on install" step). ~15 LOC.
- **AX=000C handler-install unmask (belt-and-suspenders).** In the AX=000C arm of
  `Int33.service`, also unmask IRQ12 — closes the silent-no-fire hole for a guest that installs
  a handler without a fresh driver reset. ~3 LOC.

**Phase C — clickMouse fix + test RESTRUCTURE (not re-bless).**
- `src/debug/controller.zig:994-1002`: add a short tick (`runUntilEvent` of a small fixed
  budget) after the release inject in `clickMouse` so both press and release callbacks are
  delivered before it returns; surface the tick's stop reason. ~6 LOC.
- RESTRUCTURE `src/dos/integration_test.zig:1098-1216`: convert the "handler ran" assertions
  (`1125-1131`, `1162-1172`, `1215`) to inject → run → assert, accounting for the pending IRQ12
  delivering at the head of the inserted run; keep the double-mint EQUALITY lines (`1209-1213`)
  green. Re-purpose `src/dos/integration_test.zig:1218-1464` to assert clean IRQ12+IRQ0 EOI
  under foreground delivery. Add a save/restore-across-pending-IRQ12 test and an
  **SP-near-segment-floor overflow test** (run the trampoline with the foreground SP a few
  bytes above the segment floor; assert the ~28-byte ISR frame is detected/handled, not a
  silent wrap).
- `src/bridge/bridge.zig:676-728`: remove the mouse-specific halt-clear/IF rationale (the mouse
  no longer uses `runGuestFarCall`). `runGuestFarCall` keeps only its `bridge_test.zig` callers;
  INT 23h is untouched — it uses `runGuestInt` (`src/dos/int21.zig:359`), a different primitive.

**Phase D — validate.** `zig build test`; drive BaK end-to-end; confirm a breakpoint set
inside BaK's `mouse_event_callback` now stops normally (returns from `runUntilEvent`), and
a memory watchpoint on its latch slots fires.

**Revised size (honest).** ~350–450 LOC of source + test. The prior ~250–350 undercounted:
the `Int33`→PIC seam + restore re-bind (~25), the IVT[0x74] plumbing, the `clickMouse` tick
(~6), and especially the **test restructuring** — five existing assertions move from
synchronous to inject→run, plus two NEW tests (save/restore-across-pending, SP-floor overflow)
and the strand re-purpose. Source-logic net is still modest (much is deletion of the
save/restore/IF/halt workarounds); the test work is the bulk.

### Determinism-audit checklist

- [ ] IRQ12 raise sets only the slave IRR bit (timing-neutral); no scheduler entry, no
      ledger charge at inject.
- [ ] Delivery cycle is `f(cycle counter)` — IRQ recognized at a guest IF=1 boundary in
      `serviceInterrupts`, not at the host command boundary.
- [ ] `Int33.reset` (field-by-field) clears `pending_event_mask = 0` AND lowers any pending
      IRQ12 via the seam AND re-points IVT[0x74] — no stale pending state survives a reset
      (CLAUDE rule 5). The `Int33`→PIC seam (`raise_fn`/`lower_fn`) is re-bound on restore like
      `Keyboard.raise_fn`.
- [ ] IRQ12 is unmasked at BOTH `Int33.reset` (AX=0000) and AX=000C install; a test asserts
      slave IMR bit4 clear and IVT[0x74] → stub after driver reset.
- [ ] `pending_event_mask` is in `Int33.Snapshot`; the `firing` flag is REMOVED; the PIC
      IRR/ISR is in `Pic.Snapshot`; a snapshot mid-flight restores byte-identically (add a
      save/restore-across-pending test).
- [ ] No host clock / RNG / float / host scheduling on the path (the `src/dos`,
      `src/devices`, `src/bridge` grep gates still pass).
- [ ] Every handler instruction charges through `run_loop.step`; the `int74_prep` trap
      charges `.irq` (120); the INT gate charges `cycles.interrupt_delivery`
      (`src/cpu/interrupts.zig:155`). No ledger hole (`cb_cost` "every kind has a cost" test).
- [ ] Double-mint: two identical input scripts ⇒ byte-identical machine state AND cycles
      (`integration_test.zig` mouse double-mint).

### Re-validate

- `zig build test` whole suite (esp. `src/dos/integration_test.zig`,
  `src/debug/watchpoint_test.zig`, `src/devices/pic_test.zig`, `src/bridge/bridge_test.zig`).
- BaK drive-through (`plans/krondor-milestone.md`): cursor tracking + menu clicks, with a
  breakpoint and a watchpoint set INSIDE the callback to prove observability.

### Settled sub-decisions (baked into this design)

- **A. Driver raises IRQ12 directly (SETTLED).** The host-emulated INT 33h driver raises IRQ12
  itself and owns the INT 74h stub (consistent with zdos modeling the *driver*, not the PS/2
  controller — `keyboard.zig:27-28`). The heavier alternative — wiring the full 8042 aux
  channel (0xA8/0xD4, packet protocol, a resident guest INT 74h ISR) — is more hardware-pure
  but is NOT what BaK needs and is a much larger change. **Limitation:** the aux byte is never
  read, and a guest that installs its OWN INT 74h handler (expecting a real PS/2 packet on port
  0x60) is **unsupported** under this driver-level model.
- **B. Coalescing (SETTLED).** OR-accumulate `pending_event_mask` across injects that arrive
  before INT 74h is serviced; report live driver state at service time. Deterministic for
  scripted injects; wall-time-dependent (but already non-golden) for the live path; covers the
  dwell press+release-under-IF=0 case (one delivery, net state). See §4.
- **C. INT 23h Ctrl-C stays synchronous (SETTLED, documented limitation).** It uses
  `runGuestInt` (`src/dos/int21.zig:359`), needs the handler's continue-vs-abort result, and a
  faithful migration requires modeling the abort-by-RETF-with-CF form (out of scope). It keeps
  the same observability gap and can adopt the same trampoline later. See §5.

### Residual open question for the user

- **D. `runGuestFarCall` fate.** After migration it has ZERO production callers (only
  `src/bridge/bridge_test.zig` exercises it). KEEP it as the documented host→guest primitive,
  or DELETE it (and its tests) in a follow-up? This is the only decision left; it does not
  block implementation either way.

### Top risks

1. **Delivery presence/absence + cost change, not just position** (§4): under Option C the
   callback retires at the next IF=1 boundary, charges MORE (interrupt-delivery +
   `.irq`=120 + stub instructions), and is DROPPED/DEFERRED if the guest is IF=0 / IRQ12-masked.
   Existing synchronous-delivery assertions go RED and must be RESTRUCTURED (inject → run →
   assert), not re-blessed in place. Mitigation: the test restructure in Phase C; the
   double-mint *equality* tests guard determinism regardless.
2. **IRQ12 must be unmasked + IVT[0x74] installed at the right deterministic point**
   (driver install/reset), or the callback silently never fires. Mitigation: unmask in
   `Int33.reset` (AX=0000) AND at AX=000C install (belt-and-suspenders); re-plant IVT[0x74] at
   POST on every boot; a test asserts slave IMR bit4 clear and IVT[0x74] → stub after driver
   reset.
3. **`Int33.reset` state-hole** (CLAUDE rule 5): the field-by-field reset must clear
   `pending_event_mask` and lower a pending IRQ12 via the new seam, or a phantom callback fires
   after a reset and determinism breaks across reset boundaries. Mitigation: the explicit reset
   additions + the save/restore-across-pending test.
4. **Trampoline stack-frame correctness + foreground-stack footprint** (RETF pop order,
   PUSHA/POPA bracketing, ~28-byte frame on the foreground stack with NO stack switch): a wrong
   push order corrupts the foreground or mis-enters the handler; a deep guest stack near a
   segment floor can overflow under the extra frame. Mitigation: byte-exact emit test + a
   focused integration test that runs a known multi-instruction handler under foreground IRQ12
   and checks foreground regs are restored bit-for-bit (reuse the `plantStrandHandler` harness,
   `integration_test.zig:1260-1267`), plus the SP-near-segment-floor overflow test.
