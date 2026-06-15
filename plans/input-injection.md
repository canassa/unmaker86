# Input injection from the debugger API — keyboard & mouse (design)

Status: DESIGN ONLY. No source changes. This is the implementation contract for
sending keyboard/mouse events into the running guest through the M2 HTTP/JSON API,
without violating the determinism prime directive.

Audience: the human owner — several genuine forks are surfaced as **DECISIONS**
rather than silently pre-decided.

> **Status: v2.** Revised after a concrete comparison of how dosbox-staging and
> spice86 implement keyboard/mouse (every claim below cites verified `file:line` in
> `references/`). The biggest changes from v1: (a) a new **§1.5 reference
> implementations** section lifting the liftable specs (full HW keyboard path,
> scancode set-1 + scancode→BIOS-keycode tables, the INT 33h AH=0Ch callback ABI,
> and the now-known mickey/sensitivity formulas); (b) **DECISION-2/OPEN-B replaced**
> — the mouse callback now uses spice86's **installed-asm trampoline** (guest handler
> runs inside the normal fetch/execute loop, so it is cycle-charged for free and the
> "guest advances only in run/step" invariant is *preserved*, not bent); (c)
> **relative mouse motion un-deferred** — the mickey math is a known port, not a
> guess, so v1 ships `dx/dy`; (d) the **Phase-0 snapshot fix narrowed** to the
> mouse-driver host state (the keyboard ring is in guest BDA RAM, already snapshot-
> covered); (e) **OPEN-A RESOLVED: full hardware keyboard path (Option 2)** — v1
> models the 8042 controller, scancode set-1, IRQ1, a guest INT 09h ISR, and an
> INT 16h fed by that chain; injection enters at the controller (scancode + IRQ1),
> the most faithful layer, and this subsumes the blocking-read problem (no
> `waiting_for_input` needed for the keyboard); (f) explicit **host-clock-leak "do
> not copy" notes** for the two emulators' input timing.
>
> **Status: v3.** Revised after a 3-perspective review + a 3-agent architecture/
> behavior research pass; every new `file:line` re-verified against the real source.
> Targeted edits, structure preserved. The biggest changes from v2:
> (1) **Bridge-primitives pre-phase** — a new **Phase 1·0** in §8 adds the small
> bridge infrastructure several phases assume. Research corrected the framing: it is a
> **modest extension of the existing emitter, NOT a general assembler** — `plantStub`
> (`src/bridge/bridge.zig:200-241`) already composes multi-instruction tails from ISA
> bytes (e.g. the `iret_eoi_pic2` EOI sequence). The §8 "each phase independently
> buildable" claim is **fixed**: the *polling* keyboard/mouse slice needs NO new
> bridge infra and builds first; only the guest-asm phases (INT 16h blocking loop,
> mouse callback) depend on Phase 1·0, which is reordered to sit between them.
> (2) **Full keyboard spec** — the shift-flag state machine is now its own subsection
> + checklist item (§5.1a, enumerating FLAGS1/2/3 + the alt-keypad accumulator), and
> §5.1b adds the **8042 command-set table** (device cmds on 0x60, controller cmds on
> 0x64, with expected responses and the consequence of missing ACKs). The **INT 16h
> host/guest-asm hybrid** is specified: the guest-asm loop intercepts AH=00/10,
> AH=01/02/05/11/12 fall through to the existing host handler (`src/bios/int16.zig`),
> and AH=00's **cycle cost changes** so the **K1 oracle golden must be re-baselined**.
> (3) **Determinism fixes** — mickey math is **integer/fixed-point, not f32/f64**; the
> sensitivity formula (mis-transcribed in v2) and acceleration condition are
> corrected; determinism grep-gates are added for `src/dos`+`src/bios` (none exist
> today); the **IRQ1-timing contradiction is resolved** (Model A raises IRQ1 directly,
> no `EventKind` needed; Model B optionally schedules); `runGuestFarCall` is a HARD
> requirement to drive `step_one`; and **AX=000B becomes accumulate-and-zero-on-read**
> once relative injection accumulates mickeys (its `int33.zig` oracle re-baselines).
> (4) **Freeze-time-forbidden rule + architecture justification of record** added to
> §3/§4. (5) Minors: A20 owned by the bus (not the 8042); input-buffer-full status
> **409→503** to match the `breakpoint_table_full` idiom; tightened accumulator/
> AH=0Bh citations; OPEN-E flagged as needing a trace before locking.

---

## 0. The determinism problem (state it plainly)

CLAUDE.md prime directive: *same binary + same inputs ⇒ byte-identical machine
state at any cycle N, every run.* Hard constraints (CLAUDE.md §"Hard constraints"):

- #2 **Emulated time = f(cycle counter)** — never the host wall clock.
- #3 **No dependence on host scheduling or real I/O timing** — inputs must be
  fixed/scripted/seeded.
- #4 **Deterministic interleaving** — the emulation core is single-threaded; the
  API server may thread but must NEVER feed back into emulation timing/ordering.

The naive design — "the HTTP handler receives `POST /api/input/key` and pushes the
key into the guest right now" — **directly violates #2/#3/#4**. The instant the
guest sees the key would be a function of *when the host TCP packet arrived and
when the OS scheduled the worker thread*, i.e. host wall-clock + host scheduling.
Two replays of the identical command sequence would diverge: the guest trajectory
between "issue run" and "key observed" would differ by however many cycles elapsed
before the packet landed. That is exactly the Spice86 smear (CLAUDE.md §"Prime
directive") we exist to escape, reintroduced through the front door.

**The crux of this design: an injected event must become a function of the cycle
counter / a deterministic command-ordering boundary, never of arrival time.** The
good news is that M2 already gives us the boundary for free: the command queue is
*one-command-in-flight*, the worker is the *sole owner of the machine*, and the
guest advances *only* inside a single `Controller.run*`/`step*` call
(`src/api/queue.zig:18-22`, `src/api/worker.zig:10-13`). Between commands the guest
is **paused at a known, cycle-exact boundary**. An injection command that runs at
that boundary mutates input state at a deterministic cycle; the *next* `run`/`step`
delivers it. The "when" is therefore "after exactly the commands that preceded it
in the queue" — a total order independent of host time. Replaying the same command
log replays byte-identically. That property is the spine of everything below.

### 0.1 RULE: freezing emulated time during a blocking wait is FORBIDDEN

A real blocking INT 16h AH=00 **spins WITH INTERRUPTS ENABLED** — while it loops,
emulated time advances: IRQ0/the timer ticks (incrementing the BDA tick count at
0040:006C), INT 1Ch fires, and the awaited key arrives via IRQ1 → INT 09h *during
the loop*. The loop exits only because a hardware interrupt delivered the key. This
is observable in both references: dosbox's INT 16h callback is built as an STI
spin-loop (`references/dosbox-staging/src/cpu/callback.cpp:393-403` — `CB_INT16`
emits `0xfb` STI, the native callback, `iret`, NOPs, then `0xeb 0xed` jmp-back),
its idle helper force-enables IF and runs the machine
(`callback.cpp:55-71` — `CALLBACK_Idle` sets `IF=true`, `DOSBOX_RunMachine()`),
and AH=01 force-enables IF on IRET so a guest poll loop keeps IRQs alive
(`bios_keyboard.cpp:555-556` — `// enable interrupt-flag after IRET of this int16`
`CALLBACK_SIF(true)`); spice86's blocking AH=00 is a guest-asm STI loop that
re-issues `INT 09h` (`KeyboardInt16Handler.cs:168-206`).

**Therefore: never "freeze the clock and busy-poll the host" while a guest blocks on
input. Doing so is a HOLE in the cycle ledger — the prime-directive violation zdos
exists to escape** (CLAUDE.md §"Hard constraints" #1/#2). The two faithful designs
are (a) the **guest-asm STI loop** (the committed v1 keyboard mechanism — every
spin iteration charges real cycles through the normal fetch/execute loop), or (b) a
host handler that drives `step_one` each pass (the same ledger discipline
`runGuestInt` already uses, `bridge.zig:378-390`). zdos must match dosbox's
IF-force behavior on the poll/check path so injected keys can arrive mid-loop.

---

## 1. Investigation summary (current code, cited)

### 1.1 Keyboard — what exists

- **`src/bios/int16.zig`** — BIOS INT 16h keyboard services (AH=00/10 get,
  AH=01/11 check, AH=02 shift flags). It *drains* the BDA ring; it never reads the
  host (`int16.zig:5-7`). It is registered as a host-serviced callback with an
  `IRET` tail (`src/bios/bios.zig:75`, dispatched at `bios.zig:110`).
- **`src/bios/bda.zig`** — the BDA ring lives in **real guest RAM** at 0040:001E
  with head/tail at 0040:001A/001C (`bda.zig:16-18,38-40`). Typed accessors:
  `kbEnqueue(word) bool` (false if full, `bda.zig:157-165`), `kbPeek`/`kbDequeue`
  (`bda.zig:167-180`), `kbShiftFlags` reads 0040:0017 (`bda.zig:181-184`).
  `initDefaults` sets head==tail==ring start and shift flags 0 at POST
  (`bda.zig:97-103`).
- **The carried seam (now closed by the resolution).** INT 16h AH=00 on an
  **empty** ring currently does *not* block — it returns AX=0 ("no key") without
  spinning, and the file documents this as the determinism seam (`int16.zig:36-44`):
  a faithful blocking read would idle via INT 28h, but with no live keyboard a true
  block would hang and busy-waiting against host time is forbidden. The K1 oracle
  pre-seeds the ring so AH=00 never blocks. Cross-referenced in
  `plans/dos-coverage-gaps.md §3.1`. **OPEN-A is RESOLVED in favor of the full
  hardware keyboard path (§4.1, §9), which closes this seam outright:** a blocking
  INT 16h AH=00 is implemented as a guest-asm handler that loops `INT 09h` until the
  ring is non-empty, so an injected scancode + IRQ1 unblocks it through the normal
  guest loop (cycle-charged, no host stop) — there is no empty-ring seam left to
  paper over.
- **There is NO INT 09h ISR and NO keyboard controller device today.** Grep
  confirms: no `int09` registration, no 0x60/0x64 port handler, no scancode
  tables (`src/bios/bios.zig:19-28` lists int08/10/11/12/13/15/16/1a/1c only; the
  device roster is PIC/PIT/VGA/speaker — `src/devices/`). The BDA comment
  "INT 09h fills, INT 16h drains" (`bda.zig:146`) describes the intended split,
  but the *fill* side (INT 09h / IRQ1 / scancode→ASCII) is **not yet implemented**.
  This is the single biggest faithfulness gap for the keyboard, and **OPEN-A is
  RESOLVED to build exactly this fill side** (the 8042 device + INT 09h ISR +
  scancode set-1 + IRQ1) as v1 work — see §4.1 and §9.

### 1.2 Mouse — what exists

- **`src/dos/int33.zig`** — a host-serviced INT 33h *driver* (not a device half).
  It is snapshot-style driver state: `x/y/buttons/hidden/min..max/gran/senv/
  handler_*` (`int33.zig:57-83`). Services modeled: AX=0000/0021 reset, 0001/0002
  show/hide, 0003 get pos+buttons, 0004 set pos, 0007/0008 ranges, 000B motion
  counters (**today hardcoded 0/0**, `int33.zig:196-202` — this MUST change once
  relative injection accumulates mickeys, see §5.2 / OPEN below), **000C/0014
  set/swap event-handler far-ptr**, 0011
  id, 001A/001B sensitivity, 0024 version (`int33.zig:139-249`).
- The driver instance lives on the DOS ctx: `mouse: Int33 = .{}` (`src/dos/dos.zig:115`),
  serviced at `dos.zig:216`, vector planted at `dos.zig:239`.
- **The event-callback far-ptr is captured but NEVER invoked.** AX=000C stores
  `handler_seg/off/mask` (`int33.zig:203-207`); AX=0014 swaps them
  (`int33.zig:213-223`). Nothing in the codebase ever *calls back into* that guest
  far-ptr on a mouse event. The trampoline mechanism to do so exists
  (`Bridge.runGuestInt`, `src/bridge/bridge.zig:350-400`) but is not wired to the
  mouse. This is surfaced as **OPEN-B**.
- **The injection seam already exists, host-side:** `Int33.injectMotion(x, y,
  buttons)` sets driver position+buttons directly (`int33.zig:254-259`). It is the
  deterministic external-input seam the io-oracle describes (`plans/io-oracle.md
  §4`). It does NOT fire the event callback and is absolute-position only.
- **There is no mouse hardware device, no IRQ12, no PS/2 0x60/0x64 mouse path.**

### 1.3 The "scripted input" seam today — what it actually means

Two distinct seams exist, and they are NOT the same surface:

1. **DOS CON stdin** (`src/dos/devices.zig`) — `CharDevice` with `in_buf`
   preloaded by `loadInput` from a `.in` sidecar (`devices.zig:33-36,109-115`).
   INT 21h blocking char input (AH=01/07/08/0A) reads this; EOF on the script is a
   deterministic stop (`dos-coverage-gaps.md §3.1`). **This is the DOS-kernel
   keyboard surface, reached only by `INT 21h`, not by INT 16h or the BDA ring.**
2. **BDA ring seeding** (`int16.zig:3`, `io-oracle.md §2.2`) — oracle programs
   write `scancode:ascii` words *themselves* into the BDA ring, then read them back
   via INT 16h. There is no host injector; the *guest* seeds its own ring.
3. **`Int33.injectMotion`** — the host-side mouse seam, but it is currently only
   called from tests, never from a live API path.

**The new live-injection path must reconcile with these:** it is a *new* host-side
injector that, unlike the oracle's self-seeding, originates outside the guest — and
so must be keyed to a deterministic cycle boundary (§2), and must keep the
no-host-time discipline the seams already honor. Note the keyboard injector does
**not** write the BDA ring host-side like seam (2): it injects at the 8042 controller
(scancode + IRQ1) and the guest INT 09h ISR fills the ring (OPEN-A RESOLVED, §4.1).
The mouse injector generalizes seam (3) (`Int33.injectMotion`).

### 1.4 M2 control + API model we must fit 1:1

- `src/debug/controller.zig` — the synchronous facade owning the run loop; reads
  the ledger only, never host time, never threads (`controller.zig:6-12`). Mutators
  (`setReg*`, `writeMem*`) are explicitly framed as *"a debugger write is a
  deliberate new INPUT"* under "same binary + SAME INPUTS" (`controller.zig:449-454`).
  **Input injection is exactly this category** — a deliberate new input applied at
  a deterministic boundary.
- `src/api/queue.zig` — `Command`/`Response` tagged unions, pointer-free POD; the
  one-in-flight mechanism (`queue.zig:62-94,232-247`).
- `src/api/worker.zig` — `drainOne` is a pure 1:1 command→`Controller`-method map
  (`worker.zig:62-120`); each new endpoint is a new arm here.
- `src/api/json_wire.zig` — request/response struct ↔ JSON; `u64` emitted as
  string > 2^53 (`json_wire.zig:30-32`); typed `ErrCode` (`queue.zig:126-134`).
- `src/api/server.zig` — route table (`server.zig:262-370`); the `code → HTTP
  status` map lives only here (D20).
- `src/machine/run_loop.zig` — `step` (fireDue → cpu.step → HLT fast-forward);
  the HLT fast-forward target is `nextEventCycle()`, a pure schedule function
  (`run_loop.zig:39-83`).
- `src/machine/scheduler.zig` — the cycle-keyed event queue; events keyed on
  absolute `fire_cycle: u64` (`scheduler.zig:38-50`), `EventKind` is an extendable
  enum currently `{pit_ch0,pit_ch1,pit_ch2}` (`scheduler.zig:31-35`), `schedule`/
  `popDue`/`cancel` with a strict `(fire_cycle, seq)` total order
  (`scheduler.zig:108-187`). **This is the vehicle for cycle-scheduled injection
  (§2.2).**

### 1.5 Reference implementations (dosbox-staging + spice86) — liftable specs

A concrete comparison of the two reference emulators. Each spec below is verified
against the cited `file:line` in `references/` and is reusable by the zdos
implementer (re-derive tables from the public AT spec, do **not** copy GPL source
verbatim — but the *shapes* and *formulas* are confirmed here).

**Keyboard — both emulators run the FULL hardware path.** Neither fakes the BIOS
buffer; both run host→8042 (ports 0x60/0x64)→IRQ1→guest INT 09h ISR→BDA ring→INT
16h. dosbox: `references/dosbox-staging/src/hardware/input/{keyboard,intel8042}.cpp`
+ `src/ints/bios_keyboard.cpp` (INT 16h at `bios_keyboard.cpp:15` `call_int16`, IRQ1
at `:16` `call_irq1`). spice86: `references/spice86/src/Spice86.Core/Emulator/Devices/
Input/Keyboard/{Intel8042Controller,PS2Keyboard}.cs` +
`.../InterruptHandlers/Input/Keyboard/{BiosKeyboardInt9Handler,KeyboardInt16Handler,
BiosKeyboardBuffer}.cs`. This means zdos's v1 hardware keyboard path (OPEN-A
RESOLVED, §4.1) is a fully specified, lifted-from-two-sources quantity, not a vague
band.

- **Scancode set-1 table** (logical key → make = code / break = code|0x80, with an
  ext-prefix 0xE0 and special Pause/PrintScreen sequences): dosbox
  `keyboard_scancodes.cpp` — `KEYBOARD_GetScanCode1()` switch begins at `:34`,
  per-key codes `:43-199` (e.g. esc=0x01 `:43`, A=0x1E `:66`-equiv mapping).
- **Scancode → BIOS-keycode table** in the exact BDA-ring format
  `uint16 = (scancode<<8)|ascii`, with `{normal, shift, control, alt}` columns:
  dosbox `bios_keyboard.cpp` — `struct KeyCodes` `:21-26`, `static constexpr
  KeyCodes keyboard[]` table `:34-157` (116 indices, 0..115; e.g. index 30 'A' =
  `{0x1e61,0x1e41,0x1e01,0x1e00}` `:66`). spice86's equivalent map is in
  `BiosKeyboardInt9Handler.cs`. These map 1:1 to the words zdos's INT 16h already
  drains (`int16.zig:92`) and to the K1 oracle words (e.g. `0x1E61` = scancode
  0x1E, 'a').
- **The keyboard buffer lives in GUEST BDA memory in BOTH** (0040:001E ring) — same
  place zdos keeps it (`bda.zig:18` `OFF_KB_BUF=0x1E`). So it is automatically
  snapshot-covered by the bus snapshot in all three (relevant to §7.3 / #4).
- **spice86's blocking INT 16h AH=00 is guest-asm that loops `int 09h`** until a key
  arrives: `KeyboardInt16Handler.cs WriteAssemblyInRam` `:168-206` — `CMP AH,00` →
  JZ to `HasKey` callback → JNZ have_key → else `INT 09h` → `JMP short` back; only
  `DequeueAndSetAx` + IRET when a key is present (`:192-203`). **This is the v1
  keyboard blocking-read mechanism** (OPEN-A RESOLVED, §4.1/§9): with the full
  hardware path in place, a blocking read "just works" via the guest loop — an
  injected scancode + IRQ1 makes the next `int 09h` find a key and the handler
  returns. No `waiting_for_input` stop is needed for the keyboard.

**Mouse — the two diverge, and the divergence validates OPEN-E.** dosbox is heavily
layered (PS/2 hardware IRQ12 in `mouseif_ps2_bios.cpp` + INT 15h C2 BIOS + INT 33h
driver in `mouseif_dos_driver.cpp` + serial + VMware in `mouseif_virtual_machines.cpp`)
because it is a *general-purpose* emulator: different DOS software talks to the mouse
at different levels (raw PS/2, INT 15h, INT 33h, serial), so it must service every
level. spice86 services INT 33h **entirely in host code** with IRQ12 (INT 74h) as a
stub that only far-calls the AH=0Ch user callback (`BiosMouseInt74Handler.cs:41-54`)
— sufficient for a targeted, standard-INT-33h program. **This validates OPEN-E:
zdos models the INT 33h driver, NOT the PS/2 controller.** dosbox's layering is the
cost of generality zdos does not pay; a targeted emulator only needs the level its
target (BaK, standard INT 33h) actually uses.

- **INT 33h AH=0Ch callback ABI — both agree.** On entry: `AX` = event mask, `BX` =
  button state (b0 L / b1 R / b2 M), `CX` = X px, `DX` = Y px, `SI` = Δmickeys X
  (signed), `DI` = Δmickeys Y (signed). The driver saves all regs before and
  restores after, and fires only if `LastTrigger & TriggerMask` and not re-entrant.
  dosbox `mouseif_dos_driver.cpp` — `MOUSEDOS_DoInterrupt()` builds the mask and
  skips if `!(GetUserCallbackMask() & mask)` `:2441-2502`; `MOUSEDOS_DoCallback()`
  sets `reg_al=mask, reg_bl=buttons, reg_cx=X, reg_dx=Y, reg_si/di=mickeys`
  `:2532-2538` and pushes the user far-ptr return frame `:2540-2543` (exits via the
  IRQ12 retf shell). spice86 `MouseDriver.cs` — `SetRegistersToMouseState()`
  `:359-368` (AX=LastTrigger, BX=ButtonFlags, CX/DX=X/Y, SI/DI=mickeys),
  `SaveRegisters`/`RestoreRegisters` `:370-393`, exit via the trampoline FAR RET
  (§2/OPEN-B). Event-mask bits: b0 move, b1/2 L down/up, b3/4 R down/up, b5/6 M
  down/up.
- **Mickey / sensitivity formulas — now KNOWN (no longer a guess).** dosbox
  `mouseif_dos_driver.cpp`: `set_mickey_pixel_rate()` `:800-815` —
  `MickeysPerPixel = ratio / pixels` and `PixelsPerMickey = pixels / ratio` where
  **`pixels` is the constant `8.0`** (`:807`, `:811-814`; NOT `ratio/8` — v2
  mis-stated this); sensitivity coefficient in `set_sensitivity()` (fn `:829-857`):
  `tmp = min(100, s) - 1; coeff = (tmp*tmp)/3600 + 1/3`, **and `if (s == 0) coeff = 0`
  so the cursor stops at sensitivity 0** (clamp `:834-836`, `value==0→0` `:848-850`,
  `tmp = value - 1` `:852`, coeff `:853`); per-move `d = rel * PixelsPerMickey`, then
  `d *= coeff` only when `!is_input_raw || fabs(rel) > 1.0 || coeff < 1.0`
  (`:1230-1244`, condition `:1237-1239`); with raw input forced (zdos's case) this
  reduces to `fabs(rel) > 1.0 || coeff < 1.0`. Defaults `set_mickey_pixel_rate(8,16)`
  (`:1170`) and double-speed default 64 (`set_double_speed_threshold`, value-set in
  `MouseDriver.cs:341`). Sub-integer accumulator threshold 0.6 for +1/-1 flip-flop
  protection: `mouse_common.cpp:103`, inside **`MOUSE_HasAccumulatedInt` (`:100-104`)**
  — NOT the ballistics fn `MOUSE_GetBallisticsCoeff` (`:25`). spice86 `MouseDriver.cs`:
  `GetDeltaXMickeys = HorizontalMickeysPerPixel * (DeltaX * VirtualScreenWidth)`
  (`:311-316`), `GetDeltaYMickeys = VerticalMickeysPerPixel * (DeltaY * vgaHeight)`
  (`:318-322`); AH=0Fh stores `value >> 3` (`MouseInt33Handler.cs:444-445`), AH=0Bh
  `GetMotionDistance` returns motion distance and **zeroes the deltas** to prevent
  drift (registration `:603`, body `:624-638`, zero-comment `:635`); reset defaults
  `HorizontalMickeysPerPixel=8, VerticalMickeysPerPixel=16, DoubleSpeedThreshold=64`
  (`MouseDriver.cs:339-341`). Mode-13h virtual width is fixed 640 (spice86
  `VirtualScreenWidth = 640`, `MouseDriver.cs:38`). These formulas are a **port**, used
  in §5.2. **zdos ports them in integer/fixed-point arithmetic, NOT f32/f64** (§5.2,
  §7 grep-gate) — the references use floats, which are a banned determinism
  anti-pattern in zdos.

**Determinism caveat for both (the gap zdos closes):** see §7.4 — neither emulator
cycle-stamps input or supports deterministic record/replay, and each has at least
one host-clock leak in the mouse path. The reusable parts are the *tables* and the
*arithmetic*, not the timing.

---

## 2. Design decision: the time-keying model (THE core decision)

Three candidate models for expressing "when" without host time.

### 2.1 Model A — inject-while-paused (the primitive to ship first)

The guest is paused at a cycle-exact boundary between commands. An injection
command runs as one worker command (`drainOne` arm → one `Controller` method),
mutates input state at exactly `cpu.st.cycles == C`, and returns. The next
`run`/`step` command delivers it.

- **Determinism: by construction.** The mutation happens at a boundary that is a
  pure function of the *preceding command sequence*, not host time. Identical
  command logs ⇒ identical `C` ⇒ identical state. This is the same argument that
  already makes `setReg*`/`writeMem` deterministic (`controller.zig:449-454`).
- **Replay/golden story:** record the ordered command log `(load, …, inject_key
  A, run 5000, inject_mouse …, run 5000, …)`. Re-issuing it byte-for-byte
  reproduces every intermediate snapshot. This is the canonical regression
  (CLAUDE.md #6) and what the black-box harness drives.
- **Cost:** simplest possible; reuses the entire M2 machinery unchanged. **Ship
  this first.**

### 2.2 Model B — cycle-scheduled injection ("deliver at cycle N")

A command `inject … at_cycle N` enqueues the event into the **existing scheduler**
(`scheduler.zig`) with `fire_cycle = N`. During a subsequent `run`, when the
ledger reaches N, the machine's `fireDue` (`machine.zig:440`) dispatches it: it
applies the input mutation (enqueue scancode / set mouse state / fire callback) at
exactly cycle N. Requires:

- A new `EventKind.input_key` / `input_mouse` (extend `scheduler.zig:31-35` — the
  comment already anticipates "kbd, mouse"), with the scancode word / mouse delta
  packed into `Event.val` (u32 — fits a 16-bit key word; mouse needs more, see
  §5/OPEN-C).
- A binding in the machine's `(source_id, kind) → callback` dispatch
  (`machine.zig:438-475`) that performs the injection.

- **Determinism:** the scheduler is already the determinism backbone — keyed on
  `u64` cycles, strict total order, snapshot-verbatim (`scheduler.zig:10-23,
  195-217`). An event placed at N fires at N every run. **This is the model that
  lets a *whole session* be scripted deterministically in advance** (queue 50
  keystrokes at cycles N1…N50, then one long `run`).
- **Constraint:** `N` must be `> cpu.st.cycles` at enqueue (`schedule` clamps
  delta ≥ 1, `scheduler.zig:116`); a past N is a `bad_request` (don't silently
  clamp — that would smear). Scheduler capacity is 32 (`scheduler.zig:56`); a full
  queue is a LOUD error surfaced as an `ErrCode`, never a silent drop.
- **Cost:** medium. Compose: Model A is "inject at the current boundary" — i.e.
  Model B with `N = current + small fixed delta` is *not* needed; A mutates state
  directly without the scheduler. Keep A and B as distinct primitives; A is for
  interactive debugging, B is for scripted sessions.

### 2.3 Model C — blocking/event-driven (`waiting_for_input` stop) — OPTIONAL, NOT the keyboard mechanism

> **Scope (post OPEN-A resolution):** Model C is **NOT** the v1 keyboard mechanism.
> With the full hardware keyboard path (OPEN-A RESOLVED, §4.1), a blocking INT 16h
> AH=00 is faithful for free — the guest-asm INT 16h handler loops `INT 09h` until a
> key arrives (spice86 `KeyboardInt16Handler.cs:168-206`), and an injected scancode +
> IRQ1 unblocks it through the normal guest loop. So Model C is **demoted to an
> optional, deferred mechanism** whose only remaining candidate use is **INT 21h CON
> stdin blocking** (the OPEN-D surface, §3.1/§9) and possibly a mouse-wait — **not the
> keyboard**. The rest of this subsection (the `waiting_for_input` stop, the EIP
> rewind) is kept as the design for that deferred INT 21h-stdin case only.

When a guest does a blocking *INT 21h CON stdin* read on an empty script (the only
remaining home of this mechanism), the run loop could return a new
`StopReason.waiting_for_input` to the API instead of spinning or returning a fake
"no input". The client injects, then resumes. This is the **deferred resolution of
the carried INT 28h/idle seam for INT 21h stdin** (§3, OPEN-D); the keyboard no
longer needs it.

- **Keyboard note:** the keyboard busy-loop-forever pathology that *would* motivate
  Model C is **eliminated by the v1 hardware path** — INT 16h AH=00 loops `INT 09h`
  and an injected scancode + IRQ1 makes it progress (§1.5, §4.1). Model C is only the
  API-facing half of the *deferred INT 21h-stdin* case.
- **What it must become (§3, deferred).** See the blocking-input resolution below;
  Model C is the API-facing half of it, scoped to INT 21h stdin only.

### 2.4 RECOMMENDATION

Ship in this order (the §8 phases give the commit-level breakdown + dependencies —
note the keyboard path is NOT a single independent unit: its polling slice builds
before Phase 1·0, its guest-asm blocking loop after):

1. **Model A (inject-while-paused)** — the primitive. Smallest, reuses M2 whole.
2. **The full hardware keyboard path (OPEN-A Option 2, §4.1)** — the 8042 controller
   + scancode set-1 + INT 09h ISR + IRQ1 (the **polling slice**, no bridge infra),
   then **Phase 1·0 bridge primitives**, then the **guest-asm INT 16h loop** (§8). This
   is v1 keyboard work. With it, blocking reads "just work" via the guest loop, so no
   `waiting_for_input` is needed for the keyboard.
3. **Model B (cycle-scheduled)** — scripted whole-session determinism, built on
   the scheduler. Optional/later; sketch it now so the wire format and `EventKind`
   don't have to change later.
4. **Model C (`waiting_for_input` stop)** — OPTIONAL/later, scoped to **INT 21h CON
   stdin only** (OPEN-D); not needed for the keyboard.

The primary interactive path is **"inject a scancode + raise IRQ1; the guest loop
picks it up on the next `run`/`step`"** — Model A provides the inject-while-paused
primitive, and the hardware keyboard chain (IRQ1 → INT 09h → BDA ring → INT 16h)
delivers it through real guest instructions. Model A raises IRQ1 **directly** at the
inject boundary (no `EventKind`, §4.1 DECISION); Model B is an orthogonal convenience
that schedules an `EventKind.input_key` (Phase 5) and produces identical state to "A
whose IRQ1 is recognized at cycle N" — document that (clamp-aware) equivalence test
(§7.1).

---

## 3. The blocking-input / idle problem — DOES NOT APPLY TO THE KEYBOARD (deferred, INT 21h stdin only)

> **Scope note (OPEN-A RESOLVED):** this whole section **no longer applies to the
> keyboard at all.** With the v1 full hardware keyboard path (Option 2, §4.1), a
> blocking INT 16h AH=00 is faithful for free — the guest-asm INT 16h handler loops
> `INT 09h` until a key arrives (spice86 `KeyboardInt16Handler.cs:168-206`), so an
> injected scancode + IRQ1 unblocks it through the normal guest loop. There is no
> empty-ring seam to resolve and `waiting_for_input` is **unnecessary** for keyboard
> input. The mechanism below (the `waiting_for_input` stop, DECISION-1a/EIP rewind)
> is retained ONLY as the **deferred, optional** design for **INT 21h CON stdin
> blocking** (OPEN-D) and possibly a mouse-wait — not v1, and not the keyboard.

For the *deferred INT 21h-stdin* case, the same shape applies: a blocking stdin read
on an exhausted script must be both faithful AND deterministic. Options (read "the
blocking read" below as the INT 21h CON case, not the keyboard):

- **(i) Busy-spin in host code until input arrives** — FORBIDDEN. Couples to host
  time (#2/#3) and can hang headless.
- **(ii) Fast-forward the ledger to a fixed synthetic cost and return AX=0** —
  a fake; the guest never gets the key it asked for. Violates no-fakes.
- **(iii) Return a `waiting_for_input` StopReason from the run loop** (Model C).
  The guest is paused *inside* the INT 16h handler at the exact instruction that
  found the ring empty; the API surfaces a stop; the client injects; resume
  re-enters and the ring is now non-empty. **No cycles burned waiting** — the
  ledger sits exactly where the blocking read paused. Fully deterministic: the
  pause cycle is a pure function of the program + prior inputs.
- **(iv) Pump INT 28h** (the dosbox `CALLBACK_Idle` faithful path,
  `dos-coverage-gaps.md §3.1`). INT 28h is the DOS idle interrupt; faithful TSRs
  hook it. For BaK (single process, no TSR) INT 28h is currently an IRET stub
  (`dos-coverage-gaps.md` line 233). Pumping it would advance the scheduler (let
  IRQ0 fire) deterministically, but **only matters once a guest hooks INT 28h** —
  out of scope unless a BaK trace shows an INT 28h hook. **Note:** INT 28h is issued
  by the **DOS-layer INT 21h char-input handlers** on each idle pass (the AH=01/07/08/
  0A CON wait), **NOT by BIOS INT 16h** — so it is relevant *only* to this deferred
  INT 21h-stdin path, never to the keyboard (which blocks via the guest INT 16h→INT
  09h loop).

**RECOMMENDATION: (iii)** as the API/run-loop contract, with (iv) reserved.

### 3.1 Mechanism for `waiting_for_input` — DEFERRED/OPTIONAL (INT 21h stdin only)

> **Deferred:** this mechanism is **not v1** and **not the keyboard** (OPEN-A
> RESOLVED — the keyboard blocks via the guest INT 16h→INT 09h loop). It is kept as
> the design for the **INT 21h CON stdin** blocking case (OPEN-D) if/when that surface
> needs a non-busy block. Read the "INT 16h" references below as the *shape* of the
> mechanism; the actual deferred application is INT 21h AH=01/07/08/0A on CON.

The blocking read happens *deep inside a host-serviced INT 21h CON callback*
(the analogue of the INT 16h path `bios.zig:110` → `int16.zig:92`), which runs
synchronously within one `cpu.step()`. Returning a stop *from inside a callback* is
not how the current run loop works (the callback fills registers and returns; the
stub IRETs). Two ways to surface the wait:

- **DECISION-1a (recommended, deferred — INT 21h stdin only): detect-before-commit.**
  The blocking INT 21h CON read checks "script empty" *first*; if empty AND a new
  `block_on_empty` machine mode is set, it does NOT consume the instruction's effect —
  instead it sets a machine-level `pending_input_wait` flag and **rewinds CS:IP to
  re-issue the same INT 21h** on resume (the IVT entry is real, so re-pointing EIP to
  the INT instruction is clean). The run loop, after `cpu.step`, checks
  `pending_input_wait` and the controller surfaces `waiting_for_input`. On resume, the
  same INT re-runs; the stdin buffer is now non-empty so it proceeds. This keeps the
  *whole* guest path faithful and adds no fake cycles. The rewind must be exact (the
  INT was a single `0xCD 0x21` or a vectored call); **FLAG:** re-deriving the
  re-issue point needs care for the call-via-pointer case — scope it (§ checklist,
  the deferred Model-C band). **Note: this is NOT used for the keyboard**, which
  blocks via the guest INT 16h→INT 09h loop (OPEN-A RESOLVED).
- **DECISION-1b (alternative): let the empty read complete returning AX=0 (today's
  behavior) but have the *controller* recognize a "blocked-on-input" idiom** — e.g.
  a configurable watch that detects the AH=00 poll loop and surfaces the stop. This
  is heuristic and fragile (pattern-matching guest loops) — **not recommended**,
  documented only to reject it.

If this deferred mechanism is built, the default machine mode stays today's
non-blocking behavior (preserves the oracle corpus); `waiting_for_input` is
**opt-in** per session (a flag set via the API or at launch) so existing K1 oracle
behavior is byte-unchanged. This must be an explicit decision because it changes a
documented seam.

> **OPEN-D (human):** Should `waiting_for_input` cover INT 21h blocking stdin
> (AH=01/07/08/0A on CON when not redirected, `devices.zig:128-131`)? This is now
> the **only** home of the `waiting_for_input` mechanism (the keyboard is handled by
> the v1 hardware path, OPEN-A RESOLVED). Recommend: yes, same StopReason, but a
> later/optional phase (BaK uses INT 16h, not INT 21h stdin, so it is not v1).

---

## 4. Injection layer / faithfulness (per device)

### 4.0 Architecture justification of record (the host-serviced trap-stub model is sound)

The research pass asked whether zdos's host-serviced model — DOS/BIOS serviced in
host Zig with a trap stub at the IVT vector — can faithfully support keyboard/mouse
input, or whether it forces the kind of fakery zdos exists to escape. The answer is
**the model is sound for zdos's targeted scope**, for concrete reasons:

- **The trap stub is REAL guest-RAM code at a real IVT seg:off.** Each callback is
  planted as `0xFE 0x38 <id>` + a return tail into the BIOS ROM image
  (`bridge.zig:200-241` `plantStub`; planted + `loadRom`-ed at `machine.zig:284-286`),
  and IVT[int] is pointed at that seg:off (`setRealVec`, `bridge.zig:268-273`). So
  vector get/set (AH=25/35 read/write the *same* guest-RAM IVT), chaining-into,
  JMP/CALL reachability, and relocation all work on real bytes — proven by the
  43-program oracle corpus that exercises this surface end-to-end. A guest that
  *replaces* INT 09h simply overwrites IVT[9]; the bridge's stub is no longer
  reached and the guest's ISR takes over — the IVT is the single source of truth
  (§2 keyboard-access-patterns note).
- **dosbox is host-serviced at its core too.** It uses the *same* `0xFE 0x38`
  callback opcode (`references/dosbox-staging/src/cpu/callback.cpp:200`,
  `:651-652`) and services INT 16h/INT 33h in host C++. Its guest-asm-everywhere is
  for **generality** (it must serve the whole DOS universe at every API level), NOT
  for faithfulness per se — a targeted emulator does not pay that cost.
- **The general guest-asm *writer* is NOT needed up front.** Only a modest extension
  of the existing emitter tail (Phase 1·0, §8) is required: a poll-loop shell for the
  INT 16h blocking loop, an INT 1Ch chain tail for INT 08h, and a `runGuestFarCall`
  sibling of `runGuestInt`. `plantStub` already composes multi-instruction tails from
  ISA bytes (the `iret_eoi_pic2` sequence, `bridge.zig:228-238`), so this is an
  incremental addition, not a new assembler.

**Bounded limitation class (documented honestly, per CLAUDE.md "flag, never bypass"):**
the host-serviced model needs a small, enumerable set of guest-asm/device pieces, each
addressed by a phase:
- blocking wait → guest-asm STI loop (Phase 1d);
- direct port reads (0x60/0x64) → the real 8042 device (Phase 1a);
- INT 08h → INT 1Ch chain → stub-tail extension (Phase 1·0, currently deferred at
  `int08.zig:7-13`);
- mouse user callback → installed-asm trampoline / far-call (Phase 3);
- authentic-BIOS-byte checksums / signature scans → **out of scope** (dosbox shares
  this limitation; zdos's BIOS ROM is synthetic, not an IBM image).

### 4.1 Keyboard — where the key enters

**v1 injects at the 8042 controller (scancode + IRQ1) — the full hardware path
(OPEN-A RESOLVED, Option 2).** A key enters by pushing a scancode (make or break)
into the keyboard controller's output buffer (port 0x60) and raising IRQ1. The
guest's INT 09h ISR then reads 0x60, translates scancode→ASCII, updates the BDA
shift-flags, and enqueues the cooked word into the BDA ring; INT 16h drains it. This
is the most faithful layer — the guest's real ISR path runs, charged cycle-for-cycle
through the normal fetch/execute loop. It is *the whole point of zdos vs. Spice86's
faking*: no host-side `bda.kbEnqueue` shortcut, no skipped guest instructions. The
BDA ring is still where keys land, but it is **filled by the guest INT 09h ISR**, not
by a direct host write.

This path is **fully specified and liftable** — both reference emulators run exactly
it (§1.5), and the pieces are known quantities, not a vague band:

- **Scancode set-1 table** (logical key → make = code / break = code|0x80, ext-prefix
  0xE0): `keyboard_scancodes.cpp:34-199`; spice86 `ScanCode1.cs`.
- **Scancode→BIOS-keycode table** with {normal, shift, control, alt} columns, in the
  exact BDA-ring word format `(scancode<<8)|ascii`: `bios_keyboard.cpp:34-157`;
  spice86's equivalent in `BiosKeyboardInt9Handler.cs`. These map 1:1 to the words
  zdos's INT 16h already drains (`int16.zig:92`) and the K1 oracle words (`0x1E61` =
  scancode 0x1E, 'a').
- **The shift-flag state machine** (0040:0017/0018 updates on make/break of the
  modifier scancodes): `bios_keyboard.cpp` (scancode→keycode lookup feeds the same
  table); spice86 `BiosKeyboardInt9Handler.cs`.
- **The guest-asm blocking INT 16h loop:** spice86
  `KeyboardInt16Handler.cs WriteAssemblyInRam:168-206` — `CMP AH,00` → JNZ have_key →
  else `INT 09h` → `JMP back`, dequeue+IRET only when a key is present. This makes a
  blocking AH=00 faithful for free: an injected scancode + IRQ1 unblocks it through
  the guest loop, cycle-charged, no host stop. It **subsumes the §3 blocking-read
  problem for the keyboard entirely** (no `waiting_for_input`, no EIP rewind).
- **The 8042 controller** (ports 0x60 data / 0x64 cmd-status): dosbox
  `intel8042.cpp`; spice86 `Intel8042Controller.cs`.

> **v1 keyboard implementation scope (the full hardware path — now required, not
> conditional):**
> 1. `src/devices/keyboard.zig` — an 8042 controller device: 0x60 output buffer,
>    0x64 status/command + config byte, a small scancode FIFO, IRQ1 assert.
>    Self-registering on the bus like `pic.zig`/`pit.zig`. (Refs: dosbox
>    `intel8042.cpp`; spice86 `Intel8042Controller.cs`.)
> 2. `src/bios/int09.zig` — the INT 09h ISR (host-serviced, `iret_eoi_pic1` tail,
>    like INT 08h at `bios.zig:69`): read 0x60, run the scancode→ASCII translation
>    via the keycode table, update the BDA shift-flags (0040:0017/0018), enqueue the
>    cooked word. Register in `bios.zig:19-28`, plant a vector for 0x09. (Refs:
>    dosbox `bios_keyboard.cpp` scancode→keycode table `:34-157` + shift-flag state
>    machine; spice86 `BiosKeyboardInt9Handler.cs`.)
> 3. The **scancode set-1 table** (`keyboard_scancodes.cpp:34-199` / spice86
>    `ScanCode1.cs`) and the **scancode→ASCII / BIOS-keycode tables** (4 columns:
>    normal/shift/ctrl/alt, `bios_keyboard.cpp:34-157`) re-derived from the public
>    AT set-1 spec (NOT copied from GPL dosbox), with a `[I/O-phase]` translation-
>    conformance oracle (`io-oracle.md §2.3`).
> 4. **IRQ1 wiring** through the PIC. **DECISION (singular — resolves the v2 §4.1-vs-
>    Phase-1e contradiction): Model A raises IRQ1 DIRECTLY at the inject boundary**
>    (`pic.raiseIrq(1)`) — no scheduler entry, no `EventKind` needed. Setting the PIC's
>    IRR is **timing-neutral** (it just records a pending request); the *cost* is borne
>    by the guest INT 09h ISR on the next `run`, charged cycle-for-cycle through the
>    normal loop — **so there is no ledger hole.** The recognition cycle is the
>    machine's existing deterministic IRQ-recognition point (M-D6), a pure function of
>    the ledger. **Model B (optional, §2.2 / Phase 5) MAY schedule an
>    `EventKind.input_key`** for *cycle-N-scripted* delivery (it raises IRQ1 on fire);
>    that variant is the only keyboard path that needs a new `EventKind`. The two are
>    equivalent only up to the scheduler's `delta >= 1` clamp
>    (`scheduler.zig:116`): "inject now" (A) recognizes IRQ1 at the next recognition
>    boundary ≥ the current cycle, while "schedule at N" (B) requires `N > now` and
>    fires at exactly N — define the equivalence as "A ≡ B with N = the cycle at which
>    A's directly-raised IRQ1 is recognized," not as an unconditional identity.
> 5. The **guest-asm INT 16h handler** that loops `INT 09h` for blocking reads
>    (spice86 `KeyboardInt16Handler.cs:168-206`), so AH=00 blocks faithfully via the
>    guest loop. **This piece needs Phase 1·0 (the bridge poll-loop emitter)** and is
>    sequenced as Phase 1d, *after* the no-bridge-infra polling slice (§8).
> This is a multi-commit band (see §8 Phases for the order: the 8042 device, scancode
> tables, INT 09h ISR + shift-flag machine, controller-level injection, determinism
> tests — all **no-bridge-infra, build first** — then Phase 1·0 bridge primitives, then
> the guest-asm INT 16h loop). It is **v1 work**, not deferred.

**INT 16h host/guest-asm HYBRID (load-bearing — specify precisely).** The existing
INT 16h is **fully host-serviced** today (`src/bios/int16.zig`, the `handle` switch
drains the BDA ring and returns). The v1 guest-asm loop does **not** replace the whole
handler — it intercepts only the **blocking AH=00/10** path; **AH=01/02/05/11/12 fall
through to the existing host handler unchanged.** (spice86 splits exactly this way:
AH=01/02/05/11 are host actions, `KeyboardInt16Handler.cs:48-53`, while AH=00/10 run
the guest-asm `INT 09h` loop, `:168-206`.) Concretely: the INT 16h stub's AH=00/10 arm
is the STI poll loop (`CMP AH,00` → if a key is ready, dequeue+IRET; else `INT 09h` →
JMP back); all other AH values reach `int16.handle`.

> **Load-bearing golden change — the K1 keyboard oracle MUST be re-baselined.**
> Today AH=00 on an empty ring returns AX=0 *immediately* with a single synthetic
> dispatch charge — the documented determinism seam at `int16.zig:36-44` (the
> return-AX=0 code at `:101-102`). The v1 hybrid **deletes that seam**: AH=00 now
> *spins in the guest-asm loop* until a key arrives, so its **cycle cost CHANGES** —
> the single synthetic dispatch charge is replaced by the real per-iteration guest-loop
> cycles (and any IRQ0/INT 09h cycles that land during the spin). This **moves the K1
> oracle golden**; it is a **deliberate, documented re-baseline, NOT a no-op**. The K1
> programs that pre-seed the ring still terminate (the first loop pass finds a key), but
> their exact cycle ledger shifts and the golden must be regenerated. dosbox also
> **force-enables IF on the AH=01 check-keystroke return** (`bios_keyboard.cpp:555-556`
> `CALLBACK_SIF(true)`) so a guest poll loop keeps IRQs alive — **zdos must match this**
> on the host-serviced AH=01 path, or an injected key can never arrive mid-loop.

**Injection seam:** at the controller level — `injectScancode(code, make_break)`
pushes the make (or break = code|0x80, with the 0xE0 ext prefix for extended keys)
into the 8042 output buffer and raises IRQ1. The cooked word is produced by the
guest INT 09h ISR, never written host-side. A `char` convenience maps via the real
scancode tables (§5.1), not a fake reverse map.

### 4.2 Mouse — where the event enters

The mouse has **no standard BIOS IRQ path** the way the keyboard does. A real PS/2
mouse uses IRQ12 + the mouse driver's IRQ12 ISR, which updates driver state and
(if armed) calls the user's AX=000C far-ptr callback. zdos models the *driver*
(INT 33h) host-side, not the hardware. So the faithful entry point for zdos's
current model is **the INT 33h driver state**, mutated the same way `injectMotion`
already does (`int33.zig:254`), PLUS firing the event callback (OPEN-B).

- **Hardware level (PS/2 IRQ12):** would require a PS/2 mouse device, IRQ12 on the
  slave PIC (`machine.zig:399` notes the cascade), and an IRQ12 ISR that mirrors
  the driver's internal accumulation. **Out of scope / OPEN-E** — zdos deliberately
  models the driver, not the PS/2 controller, and dosbox's internal motion
  accumulation (`mouse.cpp` / `mouse_common.cpp`) is the layer zdos replaces with
  `injectMotion`. **The §1.5 comparison validates this:** dosbox is heavily layered
  (PS/2 IRQ12 + INT 15h C2 + INT 33h + serial + VMware) *because different DOS
  software talks to the mouse at different levels* and a general-purpose emulator
  must serve all of them; spice86 services INT 33h in host code with IRQ12 as a stub
  that only fires the AH=0Ch callback (`BiosMouseInt74Handler.cs:41-54`), which is
  sufficient for a standard-INT-33h target. A *targeted* emulator only needs the
  level its target actually uses — so zdos pays for the INT 33h driver level (BaK's
  level) and not the PS/2-controller level. dosbox's layering is the cost of
  generality zdos does not pay.
- **Driver-state level (recommended):** extend the injection seam to:
  1. set position (absolute) and/or apply relative motion (mickeys → position via
     sensitivity), and button mask — generalizing `injectMotion` (§5).
  2. **fire the AX=000C event callback** if armed and the event bit is in
     `handler_mask`, via the **installed-asm trampoline** pattern (OPEN-B, below) —
     set up the documented INT 33h callback register contract (§1.5: AX=event mask,
     BX=buttons, CX=X, DX=Y, SI=Δmickeys X, DI=Δmickeys Y) and far-call the guest
     handler from *inside the normal fetch/execute loop*, so every instruction is
     cycle-charged automatically.

**RECOMMENDATION (mouse): ship driver-state injection (position + buttons) now,
generalize `injectMotion`; implement the AX=000C callback via the installed-asm
trampoline as its own sub-phase (OPEN-B).** This is faithful to zdos's driver model
and not a fake.

> **OPEN-B scope (mouse event callback) — installed-asm trampoline (replaces the
> v1 "synchronous-inside-inject" recommendation).** Lifted from spice86's verified
> pattern (`references/spice86/src/Spice86.Core/Emulator/InterruptHandlers/Common/
> MemoryWriter/{MemoryAsmWriter,InMemoryAddressSwitcher}.cs`,
> `.../Common/Callback/CallbackHandler.cs`,
> `.../Input/Mouse/{MouseDriver,BiosMouseInt74Handler}.cs`):
>
> 1. **Install, once at init, a small asm routine in guest RAM** shaped:
>    `[host-callback "before"] [FAR CALL to a hot-patchable seg:off operand]
>    [host-callback "after"] [FAR RET]`. spice86 builds exactly this in
>    `MouseDriver.WriteAssemblyInRam` `:398-419`: a default FAR RET (the no-op user
>    handler), then `RegisterAndWriteCallback(BeforeUserHandlerExecution)`, then
>    `WriteFarCallToSwitcherDefaultAddress(...)` (the hot-patchable far call), then
>    `RegisterAndWriteCallback(AfterUserHandlerExecution)`, then a final FAR RET.
> 2. **The IRQ12 (INT 74h) stub far-calls that routine.** spice86's
>    `BiosMouseInt74Handler.WriteAssemblyInRam` `:41-54` far-calls the driver address
>    then EOIs the PIC.
> 3. **The "before" hook** decides whether the event matches the installed
>    `handler_mask`, saves the guest regs (`SaveRegisters` `MouseDriver.cs:370-374`),
>    sets the INT 33h ABI registers (`SetRegistersToMouseState` `:359-368`), and
>    **hot-patches the far-call operand to the guest's ES:DX handler** via the
>    `InMemoryAddressSwitcher` (`SetAddress` `:36-42`), or to the default far-ret
>    no-op when nothing is armed (`SetAddressToDefault` `:48-54`).
> 4. **The "after" hook** restores the saved regs (`RestoreRegisters` `:376-393`)
>    and clears the re-entrancy flag.
>
> **The crucial property:** because the FAR CALL into the guest handler executes as
> ordinary guest instructions, **the guest handler runs inside the normal
> fetch/execute loop, so every instruction is cycle-charged automatically — no
> ledger hole, no synchronous host re-entry, and it stays single-threaded.** This is
> strictly better than the v1 "fire synchronously inside the inject command" idea.
>
> **Resolves the old DECISION-2 / the "guest advances only in run/step" tension:**
> with the trampoline, the callback runs during a normal `run`/`step` (when IRQ12 is
> delivered on a subsequent run), **NOT inside the inject command**. So the M2
> invariant ("the guest advances only inside `run*`/`step*`") is *preserved*, not
> bent — `inject` only mutates driver state + arms/schedules the IRQ12; the actual
> guest callback fires on the next `run`. (Model B / §2.2: the IRQ12 is delivered via
> a cycle-scheduled `EventKind.mouse_irq`, keeping firing cycle-deterministic.)
>
> **Note for zdos (HARD requirement, not a recommendation):** if the handler is
> driven via a `Bridge.runGuestFarCall(seg,off)` sibling of `runGuestInt`
> (`bridge.zig:350-400`), that path **MUST drive `step_one` so every inner instruction
> charges its real cycle cost through the normal ledger** — exactly as `runGuestInt`
> already does (its re-entry loop calls `self.step_one.?(...)` per instruction,
> `bridge.zig:384-390`, with only leaf services adding synthetic cost). A host
> re-entry that runs the guest handler *outside* the ledger (a synchronous nested
> call that skips `step_one`) is **FORBIDDEN** — it is the precise Spice86 ledger-hole
> failure mode zdos exists to escape (CLAUDE.md prime directive). The installed-asm
> trampoline gets this for free (the instructions go through the normal fetch/execute
> loop), which is why it is the chosen Phase-3 mechanism; `runGuestFarCall`, if built
> as Phase 1·0 infrastructure, is held to the same `step_one`-driving contract.

### 4.3 Faithfulness summary

| Device | v1 layer (ship) | Faithful? | Deferred faithful layer |
|---|---|---|---|
| Keyboard | Full hardware path: 8042 controller (0x60/0x64) + INT 09h ISR + scancode set-1 tables + IRQ1; inject = scancode + IRQ1 | Yes — the faithful layer IS v1; guest INT 09h→ring→INT 16h all run, cycle-charged; no host-side ring write | N/A — the faithful layer is shipped in v1 (OPEN-A RESOLVED, Option 2) |
| Mouse | INT 33h driver state (pos/buttons) + AX=000C callback | Yes — matches zdos's driver model | OPEN-E: PS/2 device + IRQ12 ISR |

---

## 5. Event models

### 5.1 Keyboard event model

The hardware path is in v1, so the canonical injected event is **scancode-centric**:
a raw scancode + make/break, pushed into the 8042 + IRQ1. The guest INT 09h ISR
cooks it into the BDA-ring word; nothing host-side fabricates the cooked word.

- **Representation: scancode + make/break (canonical) OR convenience character.**
  Two request shapes:
  - `{"scancode": N, "make": true|false}` → push scancode N as a **make** (key-down,
    raw code) or **break** (key-up, `scancode|0x80`), with the **0xE0 ext prefix**
    automatically emitted for extended keys; then raise IRQ1. The guest INT 09h ISR
    reads 0x60, looks up the scancode→keycode table, updates the shift-flags, and
    enqueues the cooked word that INT 16h drains (`int16.zig:92-110`). This is the
    precise, fully-faithful path and the primary contract — it produces the same K1
    oracle words (`0x1E61` = scancode 0x1E, 'a', `bios_test.zig:84`) *via the real
    ISR*, not by host-side enqueue.
  - `{"char": "a"}` convenience → server maps the ASCII char to its scancode(s) via
    the **real** scancode→keycode table (the same table the INT 09h ISR uses, now
    present in v1 — `bios_keyboard.cpp:34-157` / spice86 `ScanCode1.cs`), emits the
    make (and, if requested, the matching break, plus any shift make/break for
    shifted chars), and raises IRQ1. Because the scancode tables exist in v1, this is
    a *real* reverse mapping over the actual table, not a fake — but it is still a
    convenience over the precise `scancode`+`make` path; chars with no single
    scancode (or that need modifier sequencing) are documented as such. Do NOT invent
    a mapping outside the real table.
- **make/break (key-down/key-up):** **modeled in v1** at the hardware layer. A make
  is the raw scancode; a break is `scancode|0x80`; extended keys carry the 0xE0
  prefix. The injected event is therefore a true make/break pair (or single edge),
  exactly as a real keyboard sends; the cooked keystroke that lands in the BDA ring
  is produced by the INT 09h ISR's translation of those edges.
- **Modifiers (shift/ctrl/alt) and the BDA shift-flags bytes:** these are maintained
  by the **INT 09h ISR's shift-flag state machine** (specified in §5.1a) when
  shift/ctrl/alt make/break scancodes are injected — not set host-side. The cooked
  word reflects the modifier (e.g. shift-make then a-make = 'A') because the ISR
  consults the live shift-flags. An optional `{"shift_flags": N}` may still be offered
  to force-set 0040:0017 (`bda.kbShiftFlags` reads it, `bda.zig:181`) for tests that
  want to seed a modifier without injecting its scancode, but the faithful path is to
  inject the modifier's make/break. Auto-repeat (typematic) is **out of scope** for
  injection (it is a hardware-timer behavior; the client injects discrete events).
- **Two access patterns must be supported simultaneously.** The design must serve
  BOTH (a) **high-level** consumers — INT 16h and INT 21h stdin (which reads CON,
  ultimately fed by the same ring) — AND (b) **low-level** consumers — a guest that
  hooks INT 09h directly and/or reads port 0x60 itself. This is exactly why the
  keyboard **cannot be "INT 16h-only in host code":** it needs the real 8042 device
  (so a guest reading 0x60/0x64 sees real bytes) *and* a trap-stub INT 09h whose
  **IVT vector the guest can override** (a guest that installs its own INT 09h must
  take over — the trap-stub-via-IVT model already supports this; the IVT entry is the
  single authoritative source, AH=25/35 read/write the same guest-RAM IVT,
  `bridge.zig:268-273` / §4.0). Injecting at the controller (scancode + IRQ1) feeds
  *both* paths identically: a guest's own INT 09h ISR runs if installed, otherwise the
  bridge's INT 09h fills the ring for INT 16h.

### 5.1a Shift-flag state machine (BDA flag bytes — SEPARATE from the keycode table)

This is its own concern, distinct from the scancode→keycode lookup (§1.5): the INT 09h
ISR maintains a small state machine over the BDA shift/lock flag bytes as modifier and
lock scancodes make/break. **It is the authoritative state machine for keyboard
modifiers** — cite dosbox `references/dosbox-staging/src/ints/bios_keyboard.cpp:262-495`
(`IRQ1_Handler`, which reads `BIOS_KEYBOARD_FLAGS1/2/3` at `:268-273` and switches on
the scancode from `:288` onward) and spice86
`BiosKeyboardInt9Handler.cs:321` (`UpdateKeyboardFlagsByInterpretingScanCode`).

The flag bytes and the transitions the ISR must implement:

- **FLAGS1 (0040:0017)** — the byte AH=02 returns. Bit layout (AT spec; dosbox sets
  these at `bios_keyboard.cpp:288-378`): bit0 right-Shift, bit1 left-Shift, bit2 Ctrl,
  bit3 Alt, bit4 ScrollLock(locked), bit5 NumLock(locked), bit6 CapsLock(locked),
  bit7 Insert(locked). zdos already defines `OFF_KB_FLAG0 = 0x17` (`bda.zig:14`).
- **FLAGS2 (0040:0018)** — `OFF_KB_FLAG1 = 0x18` (`bda.zig:15`). Holds the
  *pressed-vs-latched* state for the lock keys plus: bit0 left-Ctrl pressed, bit1
  left-Alt pressed, bit3 Pause/Hold active, bit2 SysReq, bit4 ScrollLock pressed,
  bit5 NumLock pressed, bit6 CapsLock pressed, bit7 Insert pressed (dosbox toggles
  these alongside FLAGS1, e.g. CapsLock `:336-337`, NumLock `:365-375`, ScrollLock
  `:378-379`, Pause `:343-350`).
- **FLAGS3 (0040:0096)** — enhanced-keyboard flags: right-Ctrl / right-Alt held,
  and the **E0/E1 prefix latches** the ISR uses to disambiguate extended keys
  (dosbox tests `flags3 & 0x04` for right-Ctrl, `flags3 & 0x08` for right-Alt at
  `:297` / `:327`). **zdos does NOT yet define 0040:0096** — `bda.zig` has only 0x17
  and 0x18; FLAGS3 is a **new BDA offset Phase 1c must add** (flag this).
- **Alt-keypad numeric accumulator (0040:0019)** — holds the digits typed on the
  numpad while Alt is held; on Alt-release the accumulated code is emitted as one
  keystroke. dosbox keeps this in `BIOS_KEYBOARD_TOKEN` (read/accumulate `:415-419`,
  emit-on-Alt-release `:329-332`). **zdos does NOT yet define 0040:0019** — a **new
  BDA offset Phase 1c must add** (flag this).

Transitions Phase 1c must implement (all in the INT 09h ISR, never host-side):
- **CapsLock vs Shift cancellation for A-Z:** the effective case of a letter is
  `CapsLock XOR Shift` (CapsLock alone uppercases; Shift while CapsLock-on lowercases).
- **NumLock numpad handling:** numpad scancodes resolve to digits when NumLock is on
  (and no Shift) vs. the cursor/edit keys otherwise.
- **0xE0 / 0xE1 extended-prefix handling:** a 0xE0 byte latches "next scancode is
  extended" (distinguishes e.g. right-Ctrl/right-Alt and the gray cursor keys from
  their numpad twins); 0xE1 begins the multi-byte Pause/Break sequence. The ISR
  consumes the prefix and resolves the following code accordingly.

This state machine is **separate from the scancode→keycode table** (§1.5): the table
maps a *resolved* (scancode, modifier-column) pair to the 16-bit BDA-ring word; this
machine decides *which column* (normal/shift/ctrl/alt) applies and maintains the
lock state. Phase 1c builds both.

### 5.1b 8042 command set (minimum set + expected responses)

A real INT 09h ISR (and many games' own keyboard init) issues 8042 commands and
**waits for the ACK/response bytes**. v2 said only "config byte"; that is materially
under-specified — a driver that sends `0xFF` (reset) and never sees `0xFA` then `0xAA`
**retries 3× then hangs / beeps / skips init**. So Phase 1a must service this minimum
set (spice86 `Devices/Input/Keyboard/PS2Keyboard.cs:280-398` +
`Intel8042Controller.cs`, `KeyboardCommand.cs`, `WellKnownKeyboardResponses.cs`):

**Keyboard-device commands (written to port 0x60):**

| Cmd | Meaning | Response |
|---|---|---|
| 0xED | set LEDs | 0xFA (ACK), then ACK the following LED-mask param byte |
| 0xEE | echo | 0xEE (echoes; **no** 0xFA ACK) |
| 0xF2 | identify | 0xFA, then 0xAB, 0x83 (MF2 101/102-key) |
| 0xF3 | set typematic rate/delay | 0xFA, then ACK the following rate param |
| 0xF4 | enable scanning | 0xFA |
| 0xF5 | disable scanning (set defaults) | 0xFA |
| 0xF6 | set defaults | 0xFA |
| 0xFE | resend last byte | (re-sends the previous response byte) |
| 0xFF | reset + self-test (BAT) | 0xFA, then 0xAA (BAT-OK) |

**Controller commands (written to port 0x64):**

| Cmd | Meaning | Response |
|---|---|---|
| 0x20 | read config byte | the config byte on 0x60 |
| 0x60 | write config byte | (consumes the next 0x60 write as the new config) |
| 0xAA | controller self-test | 0x55 (passed) |
| 0xAB | test keyboard port | 0x00 (no error) |
| 0xAD | disable keyboard port | (no response; used by INT 09h around the 0x60 read) |
| 0xAE | enable keyboard port | (no response; the AD/AE pair brackets the read) |
| 0xD0 | read output port | the output-port byte on 0x60 |
| 0xD1 | write output port | (consumes the next 0x60 write) |
| 0xFE | pulse output line (CPU reset) | (deferred — see below) |

Source line anchors: device ACKs `PS2Keyboard.cs:284-389` (each arm calls
`AddKeyboardByte(WellKnownKeyboardResponses.Ack)`); response byte values
`WellKnownKeyboardResponses.cs` (Ack=0xFA `:15`, BatOk=0xAA `:30`, Echo=0xEE `:25`,
IdentifyPrefix=0xAB `:35`, IdentifyMf2=0x83 `:40`, Resend=0xFE `:20`); command enum
`KeyboardCommand.cs` (SelfTest/TestController=0xAA `:131`, DisablePortKbd=0xAD `:146`,
EnableKeyboardPort=0xAE `:151`, ReadByteConfig=0x20 `:106`, WriteByteConfig=0x60
`:111`, ReadOutputPort=0xD0 `:176`, WriteOutputPort=0xD1 `:181`); controller config/
status state `Intel8042Controller.cs` (`_config` `:52`, `_status` `:59`, `_buffer`
FIFO `:29`).

**Consequence of missing ACKs (state it loudly, do not silently drop):** a driver
that sends a command and does not get the expected byte(s) on 0x60 typically retries
up to 3× then **hangs, beeps, or skips keyboard init**. The 0xFF reset specifically
expects **0xFA then 0xAA** — both, in order. So Phase 1a's FIFO + status-byte
sequencing must be correct, not approximate; a partial 8042 is worse than none.

**Honest deferrals (flag, don't fake):**
- **A20 via controller cmd 0xD1 (write output port, bit1) is DEFERRED** — in zdos the
  **bus owns A20** (`src/bus/a20.zig` is "the single documented owner", enabled at
  POST via `bios.zig:152` `bus.setA20(true)`), so the 8042 device **must NOT** also
  drive A20 (no double-owner, §"Minors"). If a guest pulses 0xD1 to toggle A20, that
  is a structural gap to surface, not to route through the keyboard device.
- **Auxiliary/mouse channel (0xA8 enable-aux, 0xD4 write-to-aux) is DEFERRED under
  OPEN-E** — zdos models the INT 33h driver, not the PS/2 mouse controller, so the
  8042's aux path is not wired. spice86 *does* wire aux (`KeyboardCommand.cs`
  EnablePortAux=0xA8 `:121`, SimulateInputAux=0xD3 `:191`); zdos deliberately omits
  it pending an OPEN-E trace.
- **Controller cmd 0xFE (pulse reset line)** is out of scope (zdos has no CPU-reset-
  via-keyboard path).
- **Buffer-full case:** if the BDA ring is full when the INT 09h ISR tries to enqueue
  (`kbEnqueue` returns false, `bda.zig:161`), the real BIOS drops the key and beeps —
  the ISR honors that. For the *injection* API, if the 8042 output buffer / scancode
  FIFO is full, surface a typed `ErrCode.input_buffer_full` (new) → **HTTP 503**
  (matching the existing `breakpoint_table_full` → `service_unavailable` idiom,
  `server.zig:654` — a full transient resource is 503, not 409); never silently drop
  (ground rule). The client can `run` to let the ISR drain the controller and INT 16h
  drain the ring, then retry.

### 5.2 Mouse event model

- **Absolute vs relative:** support **both, in v1**. `{"x": X, "y": Y}` = absolute
  (the current `injectMotion` semantics, clamped to range like AX=0004,
  `int33.zig:156-168`); `{"dx": DX, "dy": DY}` = relative motion. **The mickey /
  sensitivity arithmetic is now a known PORT, not a guess** (§1.5), so relative
  motion ships in v1 — it is no longer deferred. Port the documented formulas:
  - **Pixels-per-mickey / mickeys-per-pixel:** dosbox `set_mickey_pixel_rate`
    (`mouseif_dos_driver.cpp:800-815`, `MickeysPerPixel = ratio/pixels`,
    `PixelsPerMickey = pixels/ratio`, **`pixels` = the constant 8.0** at `:807` — NOT
    `ratio/8`; defaults 8,16 `:1170`). spice86's read-side equivalents:
    `GetDeltaXMickeys = HMickeysPerPixel*(Δx*VirtualScreenWidth)`,
    `GetDeltaYMickeys = VMickeysPerPixel*(Δy*vgaHeight)`
    (`MouseDriver.cs:311-322`); mode-13h virtual width fixed 640 (`MouseDriver.cs:38`).
  - **Sensitivity coefficient (CORRECTED — v2 transcribed it wrong):**
    `tmp = min(100, s) - 1; coeff = (tmp*tmp)/3600 + 1/3; if (s == 0) coeff = 0`
    (the `s==0` case stops the cursor) — dosbox `set_sensitivity`
    (`mouseif_dos_driver.cpp:829-857`; `value==0→0` `:848-850`, `tmp=value-1` `:852`,
    coeff `:853`). Applied to the per-move delta only when
    `!is_input_raw || fabs(rel) > 1.0 || coeff < 1.0` (`:1230-1244`, condition
    `:1237-1239`); with raw input **forced** (zdos's case), that reduces to
    `fabs(rel) > 1.0 || coeff < 1.0`. Double-speed default 64 (`MouseDriver.cs:341`).
  - **Sub-integer accumulator:** carry the fractional pixel remainder; the +1/-1
    flip-flop-protection threshold is 0.6 — `mouse_common.cpp:103`, inside
    **`MOUSE_HasAccumulatedInt` (`:100-104`)** (NOT the ballistics fn at `:25`).
    AH=0Bh-style motion-counter reads return and **zero** the accumulated deltas to
    prevent drift (spice86 `MouseInt33Handler.cs` `GetMotionDistance` body `:624-638`,
    zero-on-read `:635`; AH=0Fh stores `ratio>>3`, `:444-445`).
  - **Integer / fixed-point ONLY (determinism, prime-directive):** the references
    compute this in `float`/`double`. zdos **must NOT use `f32`/`f64` for mickey,
    sensitivity-coeff, or accumulator math** — float ops are the banned
    non-determinism anti-pattern caught by the determinism grep audit (§7.1). Carry
    the fractional remainder as a fixed-point integer (e.g. a scaled-integer
    accumulator, comparing against a fixed-point 0.6 threshold), so the result is
    byte-identical across builds and hosts. This is a new `src/dos` grep-gate
    deliverable (§7.1).
  Keep the no-fakes spirit: this ports the **real** driver arithmetic and forces raw
  relative input — it must NOT apply host-OS pointer acceleration (force raw input),
  and must NOT read the host clock for a sample-rate gate (§7.4). Absolute remains
  the simplest path and is what the existing get/set round-trip oracle exercises;
  relative is layered on top using the formulas above.
- **AX=000B motion counters — contract CHANGE (required for internal consistency).**
  Today AX=000B is **hardcoded to return 0/0** with the comment "mickeys only
  accumulate from real host motion, which the deterministic oracle never injects"
  (`int33.zig:196-202`). That comment is the *entire* basis of v2's "mickeys never
  accumulate, so AX=000B can be 0" story. **Once relative injection accumulates
  mickeys (above), that basis no longer holds** — a driver that has accepted `dx/dy`
  but still reports 0/0 from AX=000B is internally inconsistent. So AX=000B must
  become **accumulate-and-zero-on-read**: return the signed mickey deltas accumulated
  since the last AX=000B call, then zero them (matching dosbox case 0x0b and spice86
  `MouseInt33Handler.cs` `GetMotionDistance` `:624-638`, which zeroes the deltas at
  `:635` to prevent drift). **Update the `int33.zig:196-202` contract + comment** and
  **re-baseline its oracle golden** (the existing get/set round-trip never read 000B,
  so this is a new, documented golden — not a no-op). The accumulator is the new
  mutable host-side state covered by Phase 0's snapshot (§7.3).
- **Buttons:** `{"buttons": N}` bit mask (bit0 left / bit1 right / bit2 middle,
  `int33.zig:63`). Press/release is the delta between the previous and new mask;
  the event-callback mask bits (AX=000C `handler_mask`) distinguish move /
  press / release events (per the INT 33h ABI). The callback (OPEN-B) fires for
  the bits that match.
- **Coordinate system / mode 13h scaling:** positions are in the driver's virtual
  coordinate space (0..max_x/max_y set by range/reset, `int33.zig:99-125`); mode
  13h uses gran_x=0xfffe (X rounded even). Injection uses the SAME space the guest
  reads via AX=0003 — no separate scaling; the granularity mask applies on read
  (`posX/posY`, `int33.zig:86-91`).
- **Callback timing:** see OPEN-B (§4.2) — the installed-asm trampoline fires the
  AX=000C handler during the *next* `run`/`step` (via the cycle-scheduled IRQ12), not
  inside the inject command; the M2 "guest advances only in run/step" invariant is
  preserved.

---

## 6. API surface

All new endpoints fit the M2 model 1:1: one route → one `Command` arm → one
`drainOne` arm → one `Controller`/machine method, on the single worker thread
(`worker.zig:62`, `server.zig:262`).

### 6.1 Endpoints

| Method | Path | Body | Maps to |
|---|---|---|---|
| POST | `/api/input/key` | `KeyReq` | `Command.input_key` (Model A: scancode + make/break → 8042 + IRQ1) |
| POST | `/api/input/mouse` | `MouseReq` | `Command.input_mouse` (Model A) |
| POST | `/api/input/at-cycle` | `AtCycleReq` | `Command.input_at_cycle` (Model B, optional/later) |

A blocking keyboard read needs **no special endpoint or StopReason** — it blocks via
the guest INT 16h→INT 09h loop and an injected scancode + IRQ1 unblocks it on the
next `run`/`step`. The `waiting_for_input` StopReason and the `/api/input/mode`
`block_on_empty` toggle are **optional/later and scoped to INT 21h CON stdin only**
(OPEN-D); they are not part of the v1 keyboard surface.

### 6.2 Wire shapes (`json_wire.zig` additions)

```
// POST /api/input/key  — exactly one of {scancode} or {char}.
// Canonical: a raw scancode + make/break, pushed into the 8042 + IRQ1; the guest
// INT 09h ISR cooks it. The `char` convenience maps via the real scancode table.
KeyReq = struct {
    scancode: ?u8 = null,           // raw set-1 scancode (make form)
    make:     bool = true,          // true = key-down (make); false = key-up (break = scancode|0x80)
    ext:      bool = false,         // emit the 0xE0 extended prefix before the code
    char:     ?[]const u8 = null,   // convenience: maps via the real scancode table (§5.1)
    shift_flags: ?u8 = null,        // optional test-only force-set of BDA 0040:0017 (§5.1)
};
// Response: {"ok":true} on accept; {"code":"input_buffer_full",...} if the 8042
// FIFO is full. The cooked BDA-ring word is produced by the guest INT 09h ISR on the
// next run, not host-side.

// POST /api/input/mouse — absolute position and/or relative motion and/or buttons.
MouseReq = struct {
    x: ?i16 = null, y: ?i16 = null,     // absolute (clamped like AX=0004)
    dx: ?i16 = null, dy: ?i16 = null,   // relative (ported mickey/sensitivity, §5.2)
    buttons: ?u16 = null,               // bit0 L / bit1 R / bit2 M
    fire_callback: bool = true,         // arm AX=000C trampoline if handler set (OPEN-B)
};
// Response: {"ok":true} (plus, if a callback fired, the cycles it charged — optional).

// POST /api/input/at-cycle — Model B; the inner event is a key or mouse payload.
AtCycleReq = struct { cycle: u64, key: ?KeyReq = null, mouse: ?MouseReq = null };
// Response: {"ok":true}; {"code":"bad_request"} if cycle <= now;
//           {"code":"schedule_full"} if the scheduler is at capacity.

// OPTIONAL/LATER, INT 21h stdin only (OPEN-D) — NOT the keyboard:
// POST /api/input/mode — Model C opt-in for INT 21h CON stdin blocking.
// InputModeReq = struct { block_on_empty: bool };
```

`Command` additions (`queue.zig:62`, pointer-free POD): `input_key:
ResolvedKey` (resolved scancode + make/break/ext), `input_mouse: ResolvedMouse`,
`input_at_cycle: struct{cycle:u64, payload:…}`. (`input_mode` is deferred with
Model C / INT 21h stdin.) The handler resolves `char`→scancode(s) via the real
table and validates ranges BEFORE accept (mirrors how `reg_set` resolves the
name→enum at the handler, `queue.zig:96-106`).

`Controller` additions (the facade, framed as deliberate input like `setReg*`,
`controller.zig:449`): `injectScancode(code, make, ext) bool` (false = 8042 FIFO
full; pushes the scancode into the 8042 and raises IRQ1),
`injectMouse(...)`, `scheduleInput(cycle, payload)`. (`setBlockOnEmpty(bool)` is
deferred with the INT 21h-stdin Model C.) These call the 8042 device's
`injectScancode`+`pic.raiseIrq(1)` / `Int33.injectMotion`(+callback) /
`sched.schedule`.

### 6.3 Error model

New `ErrCode` variants (`queue.zig:126`): `input_buffer_full` (8042 FIFO full),
`schedule_full` (scheduler at 32, `scheduler.zig:56`), reuse `bad_request`
(invalid scancode/past cycle/both-and-neither of scancode/char). Relative `dx/dy`
is implemented in v1 (§5.2 ports the mickey/sensitivity formulas), so it no longer
returns `not_implemented`. The `code → HTTP status` map stays in `server.zig` (D20).
Both "full transient resource" codes map to **503** to match the existing
`breakpoint_table_full` → `.service_unavailable` idiom (`server.zig:654`):
`input_buffer_full` → **503**, `schedule_full` → **503**, `bad_request` → 400.

### 6.4 Black-box harness usage

The existing harness (M2 black-box suite) drives these as HTTP: `POST /api/load`
→ `POST /api/input/key {"scancode":30,"make":true}` (scancode 0x1E = 'a') →
`POST /api/run {...}` → `GET /api/cpu`/`POST /api/mem` to assert the guest INT 09h
ISR cooked it and the program saw 'a' via INT 16h. For a **blocking** read, no
special handshake is needed: `run` a program that loops INT 16h AH=00, then `POST
/api/input/key` + `run` again — the injected scancode + IRQ1 makes the guest loop's
`INT 09h` find a key and proceed. Re-running the identical request log must yield
identical responses (the determinism black-box, §7).

---

## 7. Determinism & test strategy

Prove injection is deterministic, reusing existing idioms.

### 7.1 In-process (gold standard)

- **Same-sequence byte-identity.** Two fresh machines, identical
  `load → injectScancode(code,make) → runToCycle(N)`; assert `machine.snapshot()` +
  RAM/VRAM byte-equal across both (the CLAUDE.md #6 idiom; `machine/
  determinism_test.zig`, `machine.zig:493`). **PREREQUISITE — see §7.3.**
- **Inject-while-paused reproducibility.** `load → run 1000 → injectScancode →
  run 1000` twice; byte-identical final state incl. `cpu.st.cycles`.
- **Blocking-read round-trip (hardware path).** A tiny program that loops INT 16h
  AH=00 until non-zero: `run` (it busy-loops in the guest INT 16h→INT 09h asm,
  burning deterministic cycles), inject a scancode + IRQ1, `run` to completion. The
  injected key makes the next `INT 09h` enqueue and the loop returns; run the whole
  scenario twice → byte-identical, incl. the cycle at which the loop exits. Proves no
  host-time leak and that the block is resolved entirely by the guest loop (no
  `waiting_for_input` stop).
- **Model A ≡ Model B equivalence (precise form).** `injectScancode then
  runToCycle(N)` (A, which directly raises IRQ1 at the pause cycle and lets it be
  *recognized* at cycle C) vs. `scheduleInput(at_cycle=C) then runToCycle(N)` (B,
  with C the cycle at which A's IRQ1 is recognized — `C > now` to satisfy the
  `delta >= 1` clamp, `scheduler.zig:116`): assert identical final snapshot. The
  equivalence is **A ≡ B-with-N=C**, not an unconditional identity (§4.1 DECISION) —
  it proves the two primitives produce the same deterministic function once B's target
  cycle is chosen to match A's recognition cycle.
- **Mouse callback determinism (OPEN-B).** Program installs an AX=000C handler that
  writes a counter to RAM; inject a mouse event twice across two machines; assert
  the handler ran identically (counter + cycles) — proves the trampoline charges
  the ledger deterministically (no hole, like the EXEC nested-run test,
  `dos-coverage-gaps.md §3.3`).
- **Grep audit (existing).** The new wire/queue/controller code must pass the existing
  no-host-time/RNG/thread/float grep (`machine/determinism_test.zig:12-40`,
  `api/determinism_test.zig`). `Command`/`Response` stay pointer-free POD
  (reflection test, `queue.zig:22`).
- **NEW grep gates for `src/dos` and `src/bios` (Phase-0/Phase-1 deliverable).** There
  is **no `determinism_test.zig` under `src/dos` or `src/bios` today** — `find src
  -name determinism_test.zig` returns only `api/`, `bus/`, `cpu/`, `debug/`, `machine/`.
  Yet the new mouse mickey/sensitivity math lands in `src/dos/int33.zig` and the INT
  09h ISR + shift-flag state machine land in `src/bios/`. Add `src/dos/
  determinism_test.zig` and `src/bios/determinism_test.zig` mirroring the existing grep
  gate (ban `f32`/`f64` in the mickey/sensitivity/accumulator math — §5.2 mandates
  integer/fixed-point — plus no host clock / RNG / threads). Make these an explicit
  Phase-0 (mouse math lands in Phase 2 but the gate scaffolding is Phase 0) / Phase-1
  (INT 09h ISR) deliverable, not an afterthought.

### 7.2 Black-box

Drive a real program that reads a keystroke (INT 16h) / polls the mouse (INT 33h
AX=0003) over the HTTP API; assert the captured console/RAM output is byte-stable
across two identical request logs. Reuse `oracle.sh`/the I/O-oracle pattern
(`io-oracle.md §2.2` for keyboard, §4 for mouse) — the injected stream replaces the
program-self-seeded ring.

### 7.3 PREREQUISITE / STRUCTURAL FLAG — snapshot coverage of input state

**`Machine.Snapshot` does NOT include `dos` state** (`machine.zig:479-491`
covers cpu/bus/pic/pit/vga/speaker/sched — **not** `dos`). The gap is therefore
**specifically the host-side input state not held in guest RAM**, which is the
**INT 33h mouse driver state** (`dos.mouse`: position, buttons, `handler_*`, ranges,
sensitivity, plus the relative-motion accumulator added in §5.2 — `dos.zig:115`,
`int33.zig:57-83`). It is **not currently captured by snapshot/restore.**

**The keyboard ring is NOT part of this gap** — it lives in guest BDA RAM
(`bda.zig:18` `OFF_KB_BUF=0x1E`), which the bus snapshot already covers. §1.5
confirms this is the same design in BOTH reference emulators (the BDA 0040:001E ring
is guest memory in dosbox and spice86), so keyboard injection is automatically
snapshot-correct in zdos with no snapshot change. The narrow fix is the mouse driver
host state. But:

- Any determinism test that uses `machine.snapshot()` to compare mouse-injection
  results will **miss** the injected mouse state — a false pass.
- Snapshot/restore (the reproducibility regression, CLAUDE.md #6) will **silently
  drop** injected mouse driver state across a restore.

**This must be fixed as part of mouse injection:** add `dos.mouse` (and any other
*mutable host-side* `Dos` state — see the audit below) to `Machine.Snapshot`/
`snapshot`/`restore` (`machine.zig:479-517`, which today covers cpu/bus/pic/pit/vga/
speaker/sched). Concretely:

- Add an **`Int33.Snapshot`** (POD copy of `int33.zig:57-83`'s currently-existing
  fields: `present/x/y/buttons/hidden/min..max/gran/senv/dspeed/handler_seg/off/mask`)
  with `snapshot`/`restore`, and thread it into `Machine.Snapshot` next to `pic`/`pit`/
  `speaker`. **Scope the Phase-0 `Int33.Snapshot` to the fields that exist today** —
  the **Phase-2 relative-motion accumulator** and the **Phase-3 callback re-entrancy
  flag** do not exist yet, so they are added to `Int33.Snapshot` **when those phases
  introduce them** (this fixes the v2 forward-reference to a not-yet-existing field;
  Phase 0 must not name fields that Phase 2/3 will add).
- **The new 8042 keyboard device (Phase 1a) state must ALSO enter `Machine.Snapshot`**
  — its scancode FIFO, status byte, and config byte — exactly like `pic`/`pit`/
  `speaker` already do (`machine.zig:482-489`). The keyboard *ring* is guest BDA RAM
  (covered), but the *controller* state is host-side device state and is NOT.
- **Add a *mutating* round-trip test.** The existing snapshot/restore test mutates
  only MCB memory + a BDA tick and **never touches mouse state**
  (`src/dos/integration_test.zig:280`), so it **false-passes** for mouse — it cannot
  detect a dropped `dos.mouse`. The Phase-0 test must: snapshot → **mutate the mouse
  driver state** (position/buttons/handler) → restore → assert byte-equal.

**Scope the fix to the actually-uncovered mutable input state**, not "snapshot all of
`dos`" blindly. The **`Dos` field audit** (`src/dos/dos.zig`), classified:
- **(a) already in guest RAM (covered):** the keyboard ring (BDA 0040:001E,
  `bda.zig:18`), the PSP/MCB chain, the environment block — all live in the bus RAM
  slab that `Bus.Snapshot` captures.
- **(b) immutable / derived-at-load:** mounted-drive VFS handles, the SFT/DTA *views*
  (thin accessors over guest RAM), version constants — no snapshot needed.
- **(c) mutable host-side state that MUST enter the snapshot:**
  - **`dos.mouse: Int33`** (`dos.zig:115`) — the known case, above.
  - **The CON device's stdin cursor** — `CharDevice.in_buf` / `in_len` / `in_pos`
    (`src/dos/devices.zig:33-35`) is the scripted-stdin buffer + read position; the
    cursor `in_pos` is **mutated during a run** (each INT 21h CON read advances it,
    `devices.zig:86-100`) and is **host-side, not mirrored in guest RAM**. It is
    therefore un-snapshotted today — **relevant if/when the INT 21h-stdin path lands**
    (the deferred OPEN-D / Model C surface). Flag it now; include it in the snapshot
    only when that path is built (it is not part of v1 keyboard work).

Flagging per CLAUDE.md "flag structural problems; never bypass" — do NOT write a mouse
determinism test against a snapshot that can't see the mouse. (Scoped as Phase 0
below.)

### 7.4 Host-clock leaks in the reference emulators — what to reuse vs. what to NOT copy

The §1.5 comparison surfaced exactly where each emulator's input path is and is not
deterministic. Reuse the emulated-time parts; **do not port the host-clock parts**.

- **Safe to reuse (already on emulated time):**
  - dosbox keeps the 8042 / typematic on PIC ticks: `intel8042.cpp` `PortDelayMs =
    0.300` (`:41`, the ~0.3 ms serial-clock buffer delay) and typematic driven by
    `PIC_Ticks` (`keyboard.cpp:196,242`). For zdos, model any equivalent 8042 buffer
    delay / typematic on the **cycle ledger** (an `EventKind`), never the host clock.
  - spice86 runs the 8042 on its `DeviceScheduler` event system
    (`Intel8042Controller.cs` comment `:35`, field `:81`) — the same emulated-time
    discipline; mirror it on zdos's scheduler.
- **Do NOT copy (host-clock leaks) — must be re-keyed to cycles in zdos:**
  - **spice86 mouse sample-rate gate uses `Stopwatch.GetTimestamp()`**
    (`Mouse.cs:148-151`: `if (timestamp - _lastUpdateTimestamp < _sampleRateTicks)
    return;`). That ties whether an update is delivered to **host wall-clock**, a
    direct violation of CLAUDE.md #2. If zdos models a sample-rate gate at all,
    re-key it to the emulated clock / cycle counter (e.g. gate on `cpu.st.cycles` or
    an IRQ12 schedule), never on a host timestamp.
  - **dosbox `MouseSpeedCalculator`** is a PIC-tick-window speed accelerator
    (`mouse_common.cpp:138-185`, reads `PIC_Ticks`). It is *emulated*-time, so not a
    wall-clock leak, but it is **speed-dependent ballistics** that makes pixel motion
    a function of inter-event timing — undesirable for reproducible injection. zdos
    should NOT apply speed-based acceleration to injected `dx/dy`; port the plain
    mickey/sensitivity arithmetic (§5.2) only.
  - **dosbox relies on host-OS mouse acceleration** for live input; zdos **forces
    raw input** (no host pointer ballistics) — injected deltas are the literal
    relative motion the formulas consume.
- **The gap zdos closes:** *neither* reference emulator cycle-stamps input or
  supports deterministic record/replay. zdos's whole contribution here is keying
  every injected event to a cycle boundary (§2) — re-running the command/event log
  reproduces byte-identically. The reusable artifacts from the references are the
  *scancode/keycode tables* and the *mickey/sensitivity formulas*, NOT their timing.

---

## 8. Implementation checklist (phased, each ~one focused commit, gates stay green)

Each phase leaves the build + all existing tests green. **Dependency note (corrects
the v2 "each phase independently buildable" claim):** the phases are NOT all
independent. The **polling** slice needs **no new bridge infrastructure** and builds
first — the 8042 device, scancode tables, the INT 09h ISR, IRQ1 wiring, controller-
level scancode injection, and mouse position/button injection all run through existing
mechanisms (host-serviced callbacks, `pic.raiseIrq`, direct driver-state mutation).
Only the **guest-asm-dependent** phases — the INT 16h blocking poll-loop (1d) and the
mouse callback trampoline (Phase 3) — depend on **Phase 1·0 (bridge primitives)**, so
Phase 1·0 is sequenced *after* the no-bridge-infra keyboard slice and *before* those
guest-asm phases. The ordering below reflects that dependency.

**Ordering at a glance:** Phase 0 (snapshot + grep-gate scaffolding) → Phase 1
polling slice (1a 8042, 1b tables, 1c INT 09h ISR, 1e controller injection + API, 1f
polling determinism tests — **no bridge infra**) → **Phase 1·0 (bridge primitives)** →
1d (guest-asm INT 16h blocking loop) → Phase 2 (mouse Model A) → Phase 3 (mouse
callback, needs Phase 1·0) → Phase 4/5 (optional/later).

**Phase 0 — close the snapshot hole + determinism grep-gates (prerequisite,
structural; NARROW scope).**
- [x] Add the uncovered *mutable host-side* DOS input state — the known case is
  `dos.mouse: Int33` (the **currently-existing** fields: position, buttons, ranges,
  sensitivity, handler ptr/mask — `int33.zig:57-83`) — to `Machine.Snapshot` +
  `snapshot()` + `restore()` (`src/machine/machine.zig:479-517`). Add an
  `Int33.Snapshot`/`snapshot`/`restore` (POD copy) to `src/dos/int33.zig`.
  **Scope Phase 0 to fields that exist TODAY:** the Phase-2 relative-motion accumulator
  and the Phase-3 callback re-entrancy flag are added to `Int33.Snapshot` **when those
  phases introduce them** (do not forward-reference not-yet-existing fields here).
  **Do NOT blindly snapshot all of `dos`:** the keyboard ring is in guest BDA RAM
  (`bda.zig:18`) and already bus-snapshot-covered (§7.3), so it needs no change.
  **Audit `Dos` field-by-field** (§7.3): classify each as guest-RAM-covered /
  immutable / mutable-host-side; include only the mutable-host-side ones and flag any
  deliberate exclusions. Test: snapshot→**mutate mouse**→restore→byte-equal (the
  existing snapshot test at `integration_test.zig:280` never touches mouse, so it
  false-passes — the new test MUST mutate `dos.mouse`).
- [x] **Add `src/dos/determinism_test.zig` + `src/bios/determinism_test.zig`** grep
  gates (none exist today — only api/bus/cpu/debug/machine, §7.1) mirroring
  `machine/determinism_test.zig:12-40`: ban `f32`/`f64` in the mickey/sensitivity/
  accumulator math (§5.2), no host clock / RNG / threads. Scaffold them in Phase 0 so
  the mouse math (Phase 2) and INT 09h ISR (Phase 1) land already gated.

**Phase 1 — keyboard POLLING slice (OPEN-A Option 2, v1; NO bridge infra) — 1a–1c
+ 1e–1f.** Each ~one focused commit. Inject enters at the 8042 controller (scancode +
IRQ1) and runs the guest chain through *existing* mechanisms. **1d (the guest-asm
blocking loop) is deferred to after Phase 1·0** because it needs the new emitter tail.

- [ ] **1a — 8042 controller device.** `src/devices/keyboard.zig`: 0x60 data /
  0x64 status+command ports, a small scancode output FIFO, status/config bytes, the
  **command set of §5.1b** (0x60 device cmds + 0x64 controller cmds with the expected
  ACK/response bytes — getting these wrong hangs drivers, §5.1b), and IRQ1 assert.
  Self-registering on the bus like `pic.zig`/`pit.zig` (refs: dosbox `intel8042.cpp`;
  spice86 `Intel8042Controller.cs`, `PS2Keyboard.cs:280-398`, `KeyboardCommand.cs`,
  `WellKnownKeyboardResponses.cs`). **A20 is NOT handled here** — the bus owns it
  (§5.1b / §"Minors"). Add the device's FIFO + status + config to `Machine.Snapshot`
  (§7.3). Test: port read/write + status-byte round-trips; FIFO push pops in order;
  the §5.1b command/response pairs (0xFF→0xFA,0xAA; 0xAA→0x55; 0xF2→0xFA,0xAB,0x83).
- [ ] **1b — scancode set-1 tables.** Re-derive from the public AT set-1 spec (NOT
  copied from GPL dosbox) the set-1 codes (make/break/0xE0-ext) and the
  scancode→ASCII / BIOS-keycode table (4 columns: normal/shift/ctrl/alt) in the
  `(scancode<<8)|ascii` BDA-ring format (refs: dosbox `keyboard_scancodes.cpp:34-199`,
  `bios_keyboard.cpp` struct `:21-26` + table `:34-157`, e.g. index 30 'A' =
  `{0x1e61,0x1e41,0x1e01,0x1e00}` `:66`; spice86 `ScanCode1.cs`). Test: a `[I/O-phase]`
  translation-conformance oracle (`io-oracle.md §2.3`) over a representative key set.
- [ ] **1c — INT 09h ISR + shift-flag state machine.** `src/bios/int09.zig`,
  host-serviced with an `iret_eoi_pic1` tail (like INT 08h at `bios.zig:69`): read
  0x60, run the **shift-flag state machine of §5.1a** (update FLAGS1 0040:0017 / FLAGS2
  0040:0018, **add the new FLAGS3 0040:0096 and alt-keypad accumulator 0040:0019 BDA
  offsets** — not yet in `bda.zig`; CapsLock/Shift cancellation, NumLock numpad,
  0xE0/0xE1 prefixes), translate via the 1b keycode table, and `bda.kbEnqueue` the
  cooked word. Register in `bios.zig:19-28`; plant the 0x09 vector — and note a guest
  may **override IVT[9]** to take over (§4.0 / §5.1 access patterns). Refs: dosbox
  `bios_keyboard.cpp:262-495` (`IRQ1_Handler`); spice86 `BiosKeyboardInt9Handler.cs:321`
  (`UpdateKeyboardFlagsByInterpretingScanCode`). Test: inject a scancode via 1a + raise
  IRQ1, step, assert the cooked word lands in the BDA ring and FLAGS1/2/3 update.
- [ ] **1e — controller-level injection + API.** `Controller.injectScancode(code,
  make, ext) bool` (false = 8042 FIFO full): push the make (or break = `code|0x80`,
  with the 0xE0 prefix when `ext`) into the 8042 and **`pic.raiseIrq(1)` DIRECTLY**
  (Model A, §4.1 DECISION — no scheduler/`EventKind` needed; the IRR set is timing-
  neutral, cost borne by the guest INT 09h on the next `run`), framed as deliberate
  input (`src/debug/controller.zig` near `:456-482`). `Command.input_key` + `drainOne`
  arm (`src/api/queue.zig:62`, `src/api/worker.zig:62-120`); `ErrCode.input_buffer_full`
  (`queue.zig:126`). `KeyReq` wire + `char`→scancode(s) resolution over the real 1b
  table at the handler; route `POST /api/input/key` (`src/api/json_wire.zig`,
  `src/api/server.zig:262+`); `input_buffer_full` → **503** (the `breakpoint_table_full`
  idiom, `server.zig:654`).
- [ ] **1f — determinism tests (polling path).** In-process same-sequence
  byte-identity (inject + run-to-cycle byte-identical across two runs); 8042-FIFO-full
  error; black-box INT 16h read-back via the AH=01/02 host path; grep audit (the new
  `src/dos`/`src/bios` gates from Phase 0). *(The blocking-read round-trip moves to
  Phase 1d.)*

**Phase 1·0 — bridge primitives (prerequisite for the guest-asm phases ONLY).**
zdos's `src/bridge` lacks a small amount of infrastructure that the blocking INT 16h
loop (1d) and the mouse callback (Phase 3) assume. **Framing (research-corrected):
this is a MODEST EXTENSION of the existing emitter, NOT a general assembler.**
`plantStub` (`bridge.zig:200-241`) *already* composes multi-instruction tails from ISA
bytes — see the `iret_eoi_pic2` EOI sequence (`bridge.zig:228-238`), which emits PUSH
AX / MOV AL,EOI / OUT / OUT / POP AX / IRET. Phase 1·0 adds three things in that idiom:
- [ ] **(a) A few more fixed emitted shapes:** a **poll-loop shell** for the guest-asm
  INT 16h blocking loop (1d) — `CMP AH,00` → conditional dequeue+IRET → else `INT 09h`
  → JMP back (the spice86 `KeyboardInt16Handler.cs:168-206` shape), and an **INT 1Ch
  chain tail** for INT 08h (`<host-tick>; INT 1Ch; EOI; IRET` — the stub-level chain
  currently deferred at `int08.zig:7-13`). These are new `CbType` tail variants beside
  the existing `iret`/`iret_sti`/`iret_eoi_pic1`/`iret_eoi_pic2`.
- [ ] **(b) `runGuestFarCall(seg, off)`** — a sibling of `runGuestInt`
  (`bridge.zig:350-400`) that drives `step_one` per inner instruction (the same
  ledger-honoring loop at `bridge.zig:384-390`), for the mouse-callback far-call. **It
  MUST drive `step_one`** so every inner instruction charges real cycles — a host
  re-entry that skips the ledger is FORBIDDEN (§4.2, the Spice86 ledger-hole failure).
- [ ] **(c) The new `EventKind` variant(s) for *scheduled* delivery — scoped
  narrowly.** Per the §4.1 IRQ1-timing DECISION, **Model A needs NONE** (it raises
  IRQ1 directly, timing-neutral). So new `EventKind`s are needed only for: **Model B**
  (Phase 5 — the cycle-scheduled key/mouse *injection* events `input_key`/`input_mouse`,
  which on fire perform the injection + raise the IRQ) and the **Phase-3 mouse callback**
  (`mouse_irq` — the scheduled IRQ12 that drives the trampoline). Extend
  `scheduler.zig:31-35` (whose comment already anticipates "kbd, mouse" at `:29-30`)
  only when those phases land — do NOT add any for the v1 polling slice.
- [ ] Test: emit each new tail/shape into a scratch image and assert the exact ISA
  bytes; a `runGuestFarCall` round-trip that asserts the inner instructions charged
  cycles (no ledger hole), mirroring the `runGuestInt` re-entry test.

**Phase 1d — guest-asm INT 16h blocking loop (needs Phase 1·0).** Install the guest-asm
INT 16h handler (using the Phase-1·0 poll-loop shell) that loops `INT 09h` for the
blocking **AH=00/10** path (spice86 `KeyboardInt16Handler.cs:168-206`): `CMP AH,00` →
have-key→dequeue+IRET → else `INT 09h` → `JMP back`. **AH=01/02/05/11/12 fall through
to the existing host `int16.handle`** (§4.1 hybrid). **Re-baseline the K1 oracle golden:
AH=00's cycle cost CHANGES** (real guest-loop cycles replace the single synthetic
dispatch charge; the `int16.zig:36-44`/`:101-102` return-AX=0 seam is deleted) — this is
a deliberate, documented golden move (§4.1). Force IF on the AH=01 host path to match
dosbox (`bios_keyboard.cpp:555-556`). Test: the blocking-read round-trip (a program that
loops AH=00 unblocks deterministically when a scancode + IRQ1 is injected, §7.1).

**Phase 2 — mouse inject-while-paused (Model A, driver-state, absolute + relative).**
- [ ] Generalize `Int33.injectMotion` → `injectAbsolute(x,y,buttons, set_x,
  set_y, set_buttons)` honoring AX=0004 clamping (`int33.zig:156-168,254-259`).
- [ ] Add `injectRelative(dx,dy,buttons,...)` porting the §5.2 mickey/sensitivity
  formulas **in integer/fixed-point, NOT float** (dosbox
  `mouseif_dos_driver.cpp:800-815` [`pixels`=8.0], `set_sensitivity :829-857`
  [`tmp=min(100,s)-1`, `s==0→0`], accel condition `:1237-1239`; spice86
  `MouseDriver.cs:311-322`): apply `pixels-per-mickey`, the sensitivity coeff, the
  sub-integer accumulator (threshold 0.6, `MOUSE_HasAccumulatedInt`,
  `mouse_common.cpp:100-104`), force raw input, no host-OS acceleration, no host-clock
  sample gate (§7.4). The accumulator field is new mutable state — add it to
  `Int33.Snapshot` *now* (it was deferred from Phase 0).
- [ ] **Change AX=000B to accumulate-and-zero-on-read** (§5.2): replace the hardcoded
  0/0 (`int33.zig:196-202`) with "return accumulated signed mickeys, then zero", update
  the contract comment, and **re-baseline its oracle golden** (dosbox case 0x0b /
  spice86 `MouseInt33Handler.cs` `GetMotionDistance :624-638`).
- [ ] `Controller.injectMouse(...)`, `Command.input_mouse`, `drainOne` arm,
  `MouseReq` wire (x/y/buttons AND dx/dy — relative ships in v1, no
  `not_implemented`), route `POST /api/input/mouse`.
- [ ] Tests: byte-identity (now valid thanks to Phase 0) for both absolute and
  relative; black-box AX=0003 round-trip; relative-motion accumulator reproducibility
  across two identical inject sequences.

**Phase 3 — mouse event callback (OPEN-B, installed-asm trampoline; needs Phase 1·0
for `EventKind.mouse_irq` and, if used, `runGuestFarCall`).**
- [ ] At init, install the asm trampoline in guest RAM (spice86 pattern,
  `MouseDriver.cs:398-419`): `[before-hook callback] [hot-patchable FAR CALL operand]
  [after-hook callback] [FAR RET]`, with a default FAR RET no-op handler. Add the
  hot-patch helper (analogous to `InMemoryAddressSwitcher.SetAddress`,
  `InMemoryAddressSwitcher.cs:36-54`).
- [ ] Wire IRQ12 (INT 74h) as a cycle-scheduled event (`EventKind.mouse_irq`,
  introduced in Phase 1·0) whose stub far-calls the trampoline (spice86
  `BiosMouseInt74Handler.cs:41-54`, far-call `:52`, EOI `:53`). The
  before-hook checks `LastTrigger & handler_mask`, saves regs, sets the INT 33h ABI
  registers (§1.5: AX=mask, BX=buttons, CX=X, DX=Y, SI/DI=mickeys), and hot-patches
  the far-call operand to the guest `handler_seg:handler_off` (or the default
  no-op). The after-hook restores regs and clears the re-entrancy flag.
- [ ] On inject: arm the event + schedule the IRQ12 on the ledger. The guest handler
  then runs on the **next `run`/`step`** through the normal fetch/execute loop, so
  every instruction is cycle-charged automatically — **no ledger hole, no
  synchronous host re-entry, and the M2 "guest advances only in run/step" invariant
  is preserved** (do NOT advance the guest inside the inject command). If a
  `Bridge.runGuestFarCall` path is ever used instead, it MUST charge cycles for every
  inner instruction or it reintroduces the hole — prefer the installed-asm pattern.
- [ ] Tests: callback-ran determinism (counter + cycles byte-identical x2);
  re-entrancy guard; default no-op path when no handler is armed.

**Phase 4 (OPTIONAL / LATER band) — `waiting_for_input` for INT 21h CON stdin only
(Model C).**
> **Not v1 and not the keyboard.** The keyboard blocks via the guest INT 16h→INT 09h
> loop (Phase 1d). This band exists only if the **INT 21h CON stdin** blocking case
> (OPEN-D) ever needs a non-busy block. `pending_input_wait`, the EIP rewind, and
> DECISION-1a apply to INT 21h, not INT 16h.
- [ ] `block_on_empty` machine/session mode (default off — preserves the K1
  oracle behavior) + `Controller.setBlockOnEmpty`, `Command.input_mode`, route
  `POST /api/input/mode`.
- [ ] INT 21h AH=01/07/08/0A-on-CON detect-before-commit (DECISION-1a): on empty
  script + mode set, set `pending_input_wait` and rewind to re-issue the INT 21h
  (`src/dos/devices.zig:128-131`); scope the re-issue point for the call-via-pointer
  case.
- [ ] Run loop surfaces it: new `StopReason.waiting_for_input{at_cycle}` in
  `Machine.StopReason`/`debug.StopReason` (`run_loop.zig`, `controller.zig:53-69`);
  worker/wire serialize it.
- [ ] Tests: blocking-stdin round-trip reproducibility (§7.1 shape, INT 21h);
  existing oracle corpus unchanged (mode off) — re-run the K1 oracle, byte-identical.

**Phase 5 — cycle-scheduled injection (Model B, optional/later).**
- [ ] `EventKind.input_key`/`input_mouse` (`src/machine/scheduler.zig:31-35`);
  pack payload into `Event.val` (key fits; mouse needs OPEN-C — a side table or a
  wider event, decide here).
- [ ] Machine `(source_id,kind)→callback` binding performs the injection at
  `fire_cycle` (`src/machine/machine.zig:438-475`).
- [ ] `Command.input_at_cycle`, `AtCycleReq` wire, route `POST /api/input/at-cycle`;
  `schedule_full`/`bad_request` errors.
- [ ] Tests: Model A ≡ Model B equivalence (§7.1); scheduler-full error.

**Phase 6 — (folded into Phase 1 / 1·0 / 1d).** The hardware keyboard path (8042 device
+ INT 09h ISR + shift-flag state machine + scancode set-1 table
[`keyboard_scancodes.cpp:34-199`] + scancode→keycode table [`bios_keyboard.cpp:34-157`]
+ IRQ1 delivery + guest-asm INT 16h loop) is **v1 work** (OPEN-A RESOLVED, Option 2),
built in the Phase 1 polling slice (1a–1c, 1e–1f) plus Phase 1·0 (bridge primitives)
and Phase 1d (the guest-asm blocking loop) — not deferred to a later phase.

---

## 9. Risks & open questions for the human

- **OPEN-A (keyboard layer) — RESOLVED: full hardware keyboard path (Option 2),
  built in v1 (Phase 1, see §4.1).** Rationale: it is the most faithful layer (the
  guest 8042→IRQ1→INT 09h→BDA ring→INT 16h chain all runs, cycle-charged, no host
  ring-write); it **subsumes the blocking-read problem** (a blocking INT 16h AH=00
  loops `INT 09h` and an injected scancode + IRQ1 unblocks it via the guest loop, so
  no `waiting_for_input` / EIP rewind is needed for the keyboard); and the required
  pieces are **liftable from two sources** (scancode set-1 + scancode→keycode tables,
  `keyboard_scancodes.cpp:34-199` / `bios_keyboard.cpp:34-157` / spice86 `ScanCode1.cs`
  + `BiosKeyboardInt9Handler.cs`, and the guest-asm INT 16h loop
  `KeyboardInt16Handler.cs:168-206`). Injection enters at the controller level
  (scancode + IRQ1). No "Option 1 / BIOS-ring" path is taken.
- **OPEN-B (mouse callback) — RESOLVED to the installed-asm trampoline (§4.2),
  supersedes the old DECISION-2.** The AX=000C handler runs via an installed guest
  asm routine `[before-hook][hot-patchable FAR CALL][after-hook][FAR RET]` (spice86
  `MouseDriver.cs:398-419`), fired by the cycle-scheduled IRQ12 on a subsequent
  `run`. Because the guest handler executes through the normal fetch/execute loop, it
  is cycle-charged automatically (no ledger hole) and **the M2 "guest advances only
  in run/step" invariant is preserved — the inject command does NOT advance the
  guest.** This is strictly better than the v1 "synchronous-inside-inject" idea,
  which is withdrawn. **Resolved:** zdos schedules IRQ12 as `EventKind.mouse_irq`
  (introduced in Phase 1·0, §8), not host-side.
- **DECISION-1 (waiting_for_input mechanism) — DEFERRED, INT 21h stdin only.** Not
  needed for the keyboard (OPEN-A RESOLVED). If the INT 21h CON stdin block (OPEN-D)
  is ever built: detect-before-commit + EIP rewind (1a, recommended) vs.
  controller-side poll-loop heuristic (1b, rejected); the rewind needs care for
  vectored INT 21h calls.
- **OPEN-C (Model B mouse payload).** `Event.val` is u32 (`scheduler.zig:48`); a
  full mouse event (x,y,buttons,flags) doesn't fit. Side table indexed by a token
  in `val`, or widen the event? **Decide if Phase 5 is in v1.**
- **OPEN-D (INT 21h stdin blocking).** This is now the **only** home of the
  `waiting_for_input` / Model C mechanism (the keyboard is handled by the v1 hardware
  path). Should INT 21h CON stdin (`devices.zig:128`) get a non-busy block via
  `waiting_for_input`? Separate surface; recommend later/optional (BaK uses INT 16h).
- **OPEN-E (mouse hardware / IRQ12).** Deferred; zdos models the driver, not the
  PS/2 controller, by design. **Caveat (confirm before locking):** this rests on the
  assumption that *the target program talks to the mouse via INT 33h, not raw PS/2*
  (ports 0x60/0x64 aux, IRQ12). That assumption is currently **asserted without a
  trace**. Before the PS/2-controller path is permanently declared out of scope,
  confirm it against an **actual BaK trace** (does BaK ever issue 8042 aux commands
  0xA8/0xD4 or hook IRQ12 / INT 74h?). If it does, OPEN-E re-opens and the 8042 aux
  channel + IRQ12 ISR move into scope.
- **Snapshot scope (Phase 0).** Confirm whether the FULL `Dos` host-side state
  (not just `dos.mouse`) should enter `Machine.Snapshot` — this affects every
  future determinism/restore test, not just input. Recommended: audit and include
  what's mutable, document deliberate exclusions.
- **Relative motion / mickeys / sensitivity — RESOLVED, ships in v1 (§5.2).** The
  arithmetic is now a known PORT, not a guess: dosbox `mouseif_dos_driver.cpp`
  (`set_mickey_pixel_rate :800-815` with `pixels`=constant 8.0 at `:807`; sensitivity
  `set_sensitivity :829-857` — `tmp=min(100,s)-1`, coeff `:853`, `s==0→0` `:848-850`;
  accel condition `:1237-1239`; defaults 8,16/64) + accumulator threshold 0.6 in
  `MOUSE_HasAccumulatedInt` (`mouse_common.cpp:100-104`); spice86
  `MouseDriver.cs:311-322`, AH=0Fh `>>3` (`MouseInt33Handler.cs:444-445`) / AH=0Bh
  zero-on-read (`GetMotionDistance :624-638`, zero `:635`). v1 ships both absolute and
  relative; `dx/dy` no longer returns `not_implemented`. **Computed in integer/
  fixed-point, NOT float** (§5.2). No-fakes preserved (port the real formula, force raw
  input, no host-OS acceleration, no host-clock sample gate — §7.4).
- **`char`→scancode convenience uses the real table** (the scancode→keycode table is
  in v1, OPEN-A RESOLVED), so it is a genuine reverse mapping, not a fake — but the
  precise/canonical path is `scancode`+`make/break`; chars needing modifier
  sequencing or with no single scancode are documented as such. Not faked.
- **Two deliberate, documented golden re-baselines (not no-ops).** (a) **K1 keyboard
  oracle:** the guest-asm INT 16h blocking loop (Phase 1d) deletes the
  `int16.zig:36-44`/`:101-102` "AH=00 returns AX=0 immediately" seam, so AH=00's cycle
  cost changes — the K1 golden moves and must be regenerated (§4.1). (b) **INT 33h
  AX=000B oracle:** the contract changes from hardcoded 0/0 to accumulate-and-zero-on-
  read once relative injection lands (§5.2, `int33.zig:196-202`), so that golden
  re-baselines. Both are required for internal consistency, not optional.
