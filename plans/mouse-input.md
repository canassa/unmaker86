# Live mouse input — low-latency coalesced ingest + absolute-seamless tracking (design)

Status: **DESIGN — reviewed (3 lenses: determinism, DOS-fidelity, architecture).** The
coalescing + determinism core is sound; the review's must-fixes are LOCKED below and
**override any contradicting text later in this doc**. No source changes yet.

## Review outcome — LOCKED revisions (implement exactly these)

1. **[BLOCKER → resolved here] Do NOT put the fold on `Controller`.** `LiveMouseState`
   lives in `src/api` (`live_mouse.zig`); `src/debug` is BELOW `src/api`, so a
   `Controller` field of type `*LiveMouseState` is a circular import that won't compile
   (`build.zig:153-158`; CLAUDE module graph). **The fold runs on the api/worker side:**
   the `input_mouse_fold` arm in `worker.zig` (which already has `ctrl`) reads the
   api-layer `LiveMouseState`, decodes it to **plain integers**, and calls a NEW
   `Controller.injectMouseSeamless(abs_x, abs_y, dx, dy, buttons …: plain ints)` that does
   the INT 33h math in `src/dos`. No `debug → api` import anywhere.
2. **Wire format is Q16 integer, never float.** `MouseReq` gains `nx_q16: ?u32` /
   `ny_q16: ?u32` (0..65536) — NOT `?f32` (the `src/api` determinism grep bans `f32`/`f64`,
   `determinism_test.zig:25-26`). `app.js` does the `[0,1]→Q16` conversion (`Math.round`).
3. **Mickeys come from a TRUE relative channel, not the absolute Δ.** dosbox feeds the
   OS's real `x_rel` into the mickey math and uses `x_abs` only for position
   (`mouseif_dos_driver.cpp` `move_cursor_seamless` :1312/:1334). The browser HAS the true
   channel — **`movementX/movementY` on `mousemove`**. Send those (as integers) ALONGSIDE
   the Q16 absolute; the fold feeds the real deltas into the existing `injectRelative`
   mickey path (AX=0B) and writes the absolute position separately (AX=03). Drop the
   "derive mickeys from the absolute Δ" model and stop calling it "faithful to dosbox."
4. **Keep the letterbox math in the browser mapping.** Normalize over the CONTAINED
   image rect (`object-fit:contain`: `(clientX-rect.left-offX)/dispW`, clamped [0,1]),
   reusing the existing `guestCoords` letterbox computation (`app.js`) — do NOT use the
   naive `(clientX-rect.left)/rect.width` (it skews when canvas aspect ≠ image aspect).
5. **No cross-thread race on the fold gate.** Remove the pacer's unsynchronized
   `dirty_seq` peek. Either: the pacer ALWAYS submits `input_mouse_fold` each slice and
   `takeFold()` returns null **under the mutex** when not dirty (simplest; still zero
   guest cycles when clean — the arm runs no `runUntilEvent`); OR make `dirty_seq`
   `std.atomic.Value(u64)` (acquire/release, like every `RunControl` field) with
   `last_folded_seq` kept pacer-local. Prefer the always-submit-null-under-lock variant.
6. **`LiveMouseState` carries `io: Io`** (set at construction, mirror `RunControl.init(io)`)
   so `ingest*`/`takeFold` can lock its `Io.Mutex` (`Io.zig` `lockUncancelable(m, io)`);
   these lock calls stay api-side (per §1).
7. **Pre-existing gap to flag (and fix in this work):** zdos updates the INT 33h range
   only on AX=00/21 reset, NOT on an INT 10h mode-set (dosbox calls
   `MOUSEDOS_AfterNewVideoMode` from int10). So "scale by the driver's *live* max" is only
   correct if the guest reset the mouse after the mode change (BaK does). Hook a
   range-update into the BIOS set-mode path (or document the dependency loudly).
8. **Claim precision (determinism):** a live fold runs the AX=0Ch far-call and **charges
   real guest cycles** at the slice boundary — within a live session the ledger genuinely
   advances (exactly as a real mouse IRQ would). It does NOT corrupt *headless/scripted*
   runs (which never construct a `LiveMouseState`) and leaves no ledger hole; it is simply
   not bit-reproducible across live sessions. Reword "cannot corrupt a deterministic run"
   to that.

Minors: derive the callback's `moved` flag from the mickey delta (a sub-granularity drag
changes mickeys without changing the granularity-masked `self.x`); round+parenthesize the
Q16→virtual map as `((q16 * span) >> 16) + min` (add `0x8000` to round); the "texW=0 ⇒
null" justification is wrong (it falls back to `canvas.width`); fix citations
(`src/debug/controller.zig`; dosbox is `src/hardware/input/mouseif_dos_driver.cpp`);
state that live mouse delivers ONLY while paced-streaming (dead while the pacer is
disarmed / a paused debugger session — use the scripted `input_mouse` path there); and the
no-live-input byte-identity test must live at the **api** level (the machine/`src/dos`
determinism harness can't construct an api-layer `LiveMouseState`).

---

Original design follows (read through the LOCKED lens above). This is the implementation
contract for making the **live browser mouse** track the host cursor 1:1 with low latency,
without violating the determinism prime directive.

Scope: this is a **focused follow-on** to `plans/input-injection.md` (the v3 input
design — keyboard + mouse Models A/B, mouse Phases 0/2/3 already SHIPPED). It does
**not** restate the INT 33h driver semantics, the mickey fixed-point math, the AX=0Ch
callback ABI, or the scripted-injection determinism argument — all of that is built and
correct (`src/dos/int33.zig`). It **extends** the *delivery path* for the live,
interactive case and **reconciles** with input-injection.md rather than contradicting
it. Read input-injection.md §2 (time-keying models), §5.2 (mouse event model), §7
(determinism) first; this doc is the live-latency layer on top.

> **What is already done (verified in tree, do not rebuild):**
> - INT 33h driver: AX=00/01/02/03/04/07/08/0B/0C/0E/11/14/1A/1B/21/24 — absolute set
>   (`setClampedX/Y`, `int33.zig:353-358`), per-mode range + granularity on reset
>   (`reset`, `int33.zig:180-226`), AX=0003 granularity-masked read
>   (`posX/posY`, `int33.zig:170-175`), AX=000B accumulate-and-zero-on-read
>   (`int33.zig:283-298`).
> - `injectAbsolute` / `injectRelative` (the deterministic scripted seam, exact
>   fixed-point mickeys, `int33.zig:366-491`) and `injectAndFire` (+AX=0Ch callback via
>   `runGuestFarCall`, `int33.zig:611-636`).
> - Snapshot/restore of all mouse host state, threaded into `Machine.Snapshot`
>   (`int33.zig:669-748`, `machine.zig:628/664/689`).
> - The queued API path: `POST /api/input/mouse` → `wire.MouseReq` (`json_wire.zig:104`)
>   → `Command.input_mouse: MouseInject` (`queue.zig:112`) → `worker.drainOne`
>   (`worker.zig:146`) → `Controller.injectMouse` → `injectAndFire`
>   (`controller.zig:849`).
> - The browser: `mousemove` → `guestCoords` (pixel mapping) → `POST /api/input/mouse
>   {x,y}` (`app.js:453-472`), buttons via `sendButtons` (`app.js:486-499`).
>
> **What is BROKEN for live play (this doc fixes both):**
> 1. **Latency** — each move is a discrete `input_mouse` command on the
>    one-command-in-flight worker (`queue.zig:376` submit-gate; `worker.zig:146`), which
>    also runs the pacer's ~10 ms `run_slice`s (`run_pacer.zig:106-161`). Moves queue
>    behind a slice and apply **in arrival order**, so stale intermediate positions are
>    replayed late → the cursor lags.
> 2. **Tracking** — `app.js guestCoords` (`app.js:453-463`) maps to the **guest
>    framebuffer pixel** size (`texW`/`texH` = 320×200 in mode 13h), but the INT 33h
>    driver's virtual range is **0–639 × 0–199** with X granularity `0xFFFE`
>    (`int33.zig:194`, `:170-175`). So an absolute set of `x∈[0,319]` only ever reaches
>    the left half of the driver's X range; the guest cursor moves at half speed in X.

---

## References consulted (file:line)

**dosbox-staging** (`references/dosbox-staging/`):
- `src/hardware/mouse/mouseif_dos_driver.cpp:119-151` — the `pending` struct: latest
  absolute position (overwritten), accumulated relative `dx/dy` (summed), latest button
  state. The coalesced-latest-state model this doc adopts.
- `:1304-1349` `move_cursor_seamless` — writes the driver's INTERNAL ABSOLUTE position
  directly from the host absolute coords (normalize over the draw-rect → ×MaxPos), NOT
  through relative integration. This is what makes AX=03 pollers track 1:1.
- `:1090-1155` `MOUSEDOS_AfterNewVideoMode` — per-mode `maxpos_x/maxpos_y` + X
  granularity (mode 13h ⇒ 639×199, granularity `0xFFFE`).
- `:308-317` `get_pos_x` — the granularity mask applied on the AX=03 read.
- `:1531-1535` — the per-event fold of `pending` into the driver state.
- `:1932-1938` — AX=0B reads the accumulated mickeys then resets them (reset-on-read).
- `:261-274` `maybe_trigger_event` — the event/IRQ cadence rides the **PIC** (emulated
  ticks), rate-limited, NOT the host wall clock. The cadence model this doc adopts.
- `dos_driver_immediate` (the immediate-fold fast path so an AX=03 poll between IRQs
  returns the freshest position).

**spice86** (`references/spice86/`):
- `SharedMouseData` / `MouseDriver.cs` — lock-free **latest-state** record (absolute
  overwritten, deltas summed, latest buttons); the HTTP/UI side mutates it, the
  emulation side consumes it. The coalesced-ingest shape.
- `Mouse.cs:148-151` — **DO NOT COPY:** the sample-rate gate uses
  `Stopwatch.GetTimestamp()` (host wall clock). CLAUDE #2 forbids this; zdos's cadence
  must ride emulated cycles (the PIT/scheduler), never a host timestamp.
- `BiosMouseInt74Handler.cs:41-54` — IRQ12 (INT 74h) stub that only far-calls the AX=0Ch
  user callback then EOIs.

**zdos** (anchors this doc builds on):
- `src/dos/int33.zig` — the whole driver (see "what is already done" above).
- `src/api/queue.zig:112` (`input_mouse`), `:359-389` (submit-gate, one-in-flight),
  `:62-67` (`run_slice` kept distinct from `run`).
- `src/api/worker.zig:146-152` (the `input_mouse` drain arm).
- `src/api/server.zig:794-824` (`handleInputMouse`, the per-axis abs/rel exclusion).
- `src/api/run_control.zig:45-179` (`RunControl` — the clockless atomics the pacer reads).
- `src/host/run_pacer.zig:106-161` (the ~10 ms slice loop + frame-sample cadence;
  host-clock-only, OUTSIDE the api determinism grep set, `run_pacer.zig:1-11`).
- `src/api/web/app.js:453-499` (`guestCoords` + `mousemove`/`sendButtons`).
- `src/machine/scheduler.zig:31-35` (`EventKind`), `:108-130` (`schedule`, `delta>=1`
  clamp), `:88-100` (`nextEventCycle`); `src/devices/pit.zig:193-235` (the periodic
  re-arm idiom — `arm` cancels then schedules; `onPitCh0Fire` raises IRQ then re-arms
  from the SCHEDULED `fire_cycle`). The model for an emulated-time recurring cadence.
- `src/machine/machine.zig:454-466` (scheduler-callback thunks), `:545-553` (`fireDue`
  dispatch on `(source_id, kind)`), `:628/664/689` (`dos_mouse` already in
  `Machine.Snapshot`).
- `plans/input-injection.md` §2.1 (Model A inject-while-paused), §2.2 (Model B
  cycle-scheduled), §5.2 (mouse event model), §7.3/§7.4 (snapshot + host-clock leaks).

---

## 1. The two problems, precisely (and where the fix lands)

### 1.1 Latency — the per-move command queues behind run-slices

Today every `mousemove` is one full round-trip: `POST` → listener thread builds
`Command.input_mouse` → `queue.submit` blocks on the **submit-gate**
(`queue.zig:376`) → waits for the in-flight `run_slice` to finish on the worker →
`drainOne` runs `injectAndFire` → response. With the pacer running ~10 ms slices, a
burst of N moves serializes as N gate-acquisitions interleaved with slices: each move
waits ~one slice, and **every intermediate position is applied** (and may fire the
AX=0Ch callback) in arrival order. The guest sees a stale trail, not the current
cursor.

The fix is **coalescing**: collapse the unbounded move stream into a single mutable
"latest input state" the worker reads **once per consume point**, discarding stale
absolute positions (keeping only the newest) and summing relative deltas (losing no
motion). This is exactly dosbox's `pending` struct (`mouseif_dos_driver.cpp:119-151`)
and spice86's `SharedMouseData`.

**Where it lives in zdos's worker model (the load-bearing choice).** zdos has no
free-running emulation thread the HTTP handler can poke; the worker is the *sole* owner
of the machine and advances it only inside a `run_slice`/`run`/`step` command. So the
coalesced state must be a small **lock-protected POD record that lives OUTSIDE the
machine** (next to `RunControl`, owned by the server/host layer), with:

- **Non-blocking ingest:** the `mousemove` POST handler takes a short mutex, mutates the
  record (overwrite abs, sum rel, latest buttons), releases — **it does NOT go through
  the command queue / submit-gate at all.** No slice to wait behind; the handler returns
  immediately. (This mirrors how `/api/run/start|stop` mutate the clockless
  `RunControl` atomics without a queue round-trip, `run_control.zig:103-116`.)
- **Read-on-consume:** the worker folds the record into the driver at a controlled
  cadence (the pacer's slice boundary, see §4), via a single `Command.input_mouse_fold`
  drain arm that calls a new `Controller.foldLiveMouse()`. One fold per slice replaces
  the stale trail with the single freshest delta+position.

This keeps the module graph clean: the shared record sits in `src/api/` (a sibling of
`RunControl`), the worker reaches the machine only through the existing `Controller`
seam, and the machine/`int33.zig` code is reused unchanged (`foldLiveMouse` just builds
a `MouseInject` from the coalesced record and calls the existing `injectAndFire`). The
host/server thread NEVER touches the machine directly — it only mutates the POD record.

> **Why not "let the POST mutate the record and have the pacer submit the fold"?** That
> is exactly the design (§4): the pacer already owns the only legitimate cadence on the
> worker (its slice loop). The POST stays off the worker entirely; the pacer submits one
> `input_mouse_fold` per slice through the gate, same as it submits `run_slice`. The
> POST↔worker decoupling is the whole point.

### 1.2 Tracking — pixel mapping vs the INT 33h virtual range

`app.js guestCoords` (`app.js:453-463`) currently maps client px → **guest framebuffer
px** (`gw = texW`, `gh = texH`). In mode 13h that is 320×200, but the driver's absolute
range is 639×199. An absolute `injectAbsolute(x∈[0,319], …)` reaches only the left half
of X. The cursor tracks at half-speed horizontally and the right ~50% of the screen is
unreachable by absolute moves.

The fix is **absolute-normalized mapping into the DOS virtual range** (§5): the browser
normalizes client px → [0,1] over the canvas draw-rect, the *server* scales [0,1] ×
`MaxPosX`/`MaxPosY` (the driver's live range), and writes the driver's internal absolute
position directly — `move_cursor_seamless` (`mouseif_dos_driver.cpp:1304-1349`). The
granularity mask still applies on the AX=03 read, unchanged (`int33.zig:170-175`).

---

## 2. Recommended design (summary)

1. **Coalesced latest-input-state record** in `src/api/` (POD, mutex-guarded), mutated
   non-blocking by the mouse POST handler; never queued. Fields: latest absolute
   `{x_norm, y_norm}` (fixed-point or two i32, OVERWRITTEN), accumulated relative
   `{dx_sum, dy_sum}` (SUMMED), latest `buttons`, plus per-field `present` flags and a
   monotone `dirty` seq so the worker can skip a no-op fold.
2. **Absolute-seamless is the default** for the browser cursor. The fold writes the
   driver's internal ABSOLUTE position directly via `injectAbsolute` (range-clamped,
   read back by AX=03) — works because zdos services INT 33h in HOST code.
3. **Derived mickeys for AX=0B games** computed from successive absolute samples (`Δ =
   new_abs − last_abs`, scaled by mickeys/pixel) and folded into the SAME pass as the
   absolute write; accumulate sub-pixel in the existing fixed-point accumulators;
   reset-on-read is already AX=0B's behavior (`int33.zig:283-298`).
4. **Per-mode coordinate mapping** into 0–639 × 0–199 (mode 13h) using the driver's live
   `max_x`/`max_y` + granularity already maintained on reset (`int33.zig:180-226`).
5. **Emulated-time cadence** for the live fold + AX=0Ch callback: rate-limited on the
   pacer's slice boundary (a deterministic-cycle event), never the host wall clock.
6. **`app.js` mapping change:** send absolute-normalized coords (or guest virtual coords)
   instead of framebuffer pixels; keep the rAF throttle (it is already coalescing on the
   client side, `app.js:466-468`).
7. **Determinism split (explicit):** scripted/cycle-scheduled injection stays
   byte-reproducible (unchanged seam); live coalesced input is NOT bit-reproducible in
   its exact-cycle timing (arrival-dependent) and that is acceptable for live play — but
   it MUST be byte-identical to today when no live input is present.

---

## 3. The coalesced latest-input-state record

### 3.1 Shape (POD, pointer-free, mutex-guarded)

Lives in a new `src/api/live_mouse.zig` (a sibling of `run_control.zig`), owned by the
server, shared with the pacer (read) and the POST handler (write):

```
LiveMouseState = struct {
    mutex: Io.Mutex = .init,        // short critical sections only; no clock, no timeout
    // ABSOLUTE (overwritten): normalized over the canvas draw-rect, fixed-point.
    // Stored normalized [0,1] so the SERVER, not the browser, owns the per-mode
    // ×MaxPos scaling (one place to keep the range correct as the mode changes).
    abs_x_q16: u32 = 0,             // 0..0x1_0000 == [0.0, 1.0] (Q16 fixed-point)
    abs_y_q16: u32 = 0,
    have_abs: bool = false,
    // RELATIVE (summed): raw client deltas, never lost between folds.
    dx_sum: i32 = 0,
    dy_sum: i32 = 0,
    have_rel: bool = false,
    // BUTTONS (latest mask): bit0 L / bit1 R / bit2 M.
    buttons: u16 = 0,
    have_buttons: bool = false,
    // Monotone seq bumped on every mutate; the pacer skips a fold when unchanged.
    dirty_seq: u64 = 0,
    last_folded_seq: u64 = 0,
};
```

Q16 normalized absolute keeps the record mode-independent: the *server* converts to the
driver's live range at fold time (§5), so a video-mode change between samples can't
desync the stored coords. No floats (Q16 is exact integer arithmetic) — keeps it clear
of the determinism grep posture even though this is the live (non-deterministic-timing)
path.

### 3.2 Ingest (non-blocking, off the command queue)

`handleInputMouse` for the **live** case (`server.zig:794`) becomes: take
`LiveMouseState.mutex` (`Io.Mutex.lockUncancelable`, the clockless variant already used
by the queue gate, `queue.zig:12-13`), apply:
- absolute `{x,y}` (now normalized, §6): `abs_*_q16 = …; have_abs = true;` (**overwrite**)
- relative `{dx,dy}`: `dx_sum +%= dx; dy_sum +%= dy; have_rel = true;` (**sum**)
- `buttons`: `buttons = mask; have_buttons = true;` (**latest**)
- `dirty_seq +%= 1`
unlock, respond `{"ok":true}`. **No queue submit, no submit-gate, no slice wait.**

Per-axis abs/rel mutual-exclusion (today's `server.zig:800-805`) is preserved at ingest.

### 3.3 Consume (the worker, once per cadence tick)

A new `Command.input_mouse_fold` (no payload) drains to `Controller.foldLiveMouse()`,
which: locks the record, snapshots+clears the deltas (`dx_sum`/`dy_sum` → locals, reset
to 0; abs/buttons read, `have_*` cleared, `last_folded_seq = dirty_seq`), unlocks, then
builds ONE `MouseInject` and calls the existing `injectAndFire` (§4 covers when/how
often). The summed deltas are consumed exactly once (no double-count, no loss); the
absolute is the freshest only.

> The Controller needs a pointer to the `LiveMouseState`. Wire it the same way the
> stream/pacer get `RunControl` — passed at server construction; the Controller holds an
> optional `*LiveMouseState` (null in headless/test builds, see §7).

---

## 4. Emulated-time cadence — decouple the fold + IRQ from the run-slice

### 4.1 The rule (CLAUDE #2/#4)

- **Ingest** happens anytime (host-arrival-driven) — that only mutates the POD record,
  never the machine, so it is timing-neutral and cannot reorder emulation (CLAUDE #4:
  the API thread may thread but must not feed back into emulation timing/ordering).
- **Delivery** (the fold + any AX=0Ch callback) happens at a **cadence keyed to emulated
  cycles**, never the host wall clock. spice86's `Stopwatch` gate (`Mouse.cs:148-151`)
  is the anti-pattern — explicitly DO NOT copy it (CLAUDE #2).

### 4.2 Where the cadence comes from

zdos already has exactly one legitimate, emulated-time-bounded driver of the worker: the
**pacer's slice loop** (`run_pacer.zig:106-161`). Each ~10 ms wall tick it submits one
`run_slice` of a fixed `slice_cycles` (`run_control.zig:176`). The pacer is host-clock
for *wall pacing only*; the **number of guest cycles per slice is fixed and clockless**,
and "paced ≡ unpaced run-to-cycle N byte-identical" is its load-bearing contract
(`run_pacer.zig:13-19`). So:

- **Live fold cadence = one `input_mouse_fold` submitted by the pacer immediately
  AFTER each `run_slice`** (only when `dirty_seq != last_folded_seq`, i.e. there is new
  input). This bounds delivery latency to **at most one slice** (~10 ms) — the same
  bound the frame-sample already accepts (`run_pacer.zig:138-148`) — and the fold's cycle
  position is the **slice boundary**, a fixed function of `slice_cycles`, not of when the
  POST arrived. The POST's arrival time affects only *which* coalesced value is present
  at the boundary, not the boundary cycle itself.

This means the **per-event delivery cycle for live input is deterministic given the
slice schedule and the coalesced value present at each boundary** — but the coalesced
value present at a boundary depends on host arrival timing, so the live stream as a whole
is NOT bit-reproducible (§7). That is the accepted live-play stance, identical to the
paced video stream (whose sampled frames also depend on arrival-relative timing).

### 4.3 The AX=0Ch event callback under coalescing

`injectAndFire` already fires the AX=0Ch handler once per inject for the resulting
transition (`int33.zig:611-636`). Under coalescing the fold is one inject carrying the
combined transition (moved + button-delta vs the pre-fold state), so it fires **at most
once per slice** — exactly the rate-limit dosbox's `maybe_trigger_event`
(`mouseif_dos_driver.cpp:261-274`) provides via the PIC, achieved here by the
one-fold-per-slice cadence instead of a separate IRQ12 schedule. **The position state is
ALWAYS the latest** (folded every dirty slice); only the *callback* is rate-limited —
matching the dosbox contract ("always store the latest position; rate-limit only the
interrupt").

> **Immediate-fold fast path (AX=03 pollers between folds).** Games that poll AX=03
> (BaK menus, Stunts) read driver position directly; with one fold per ~10 ms slice the
> polled position is at most one slice stale, which is below human-perceptible for a
> 10 ms cadence. dosbox's `dos_driver_immediate` exists because its driver can be read
> mid-frame; zdos's AX=03 read already returns the live `self.x/self.y`
> (`int33.zig:242-246`), so the freshest *folded* value is always what a poll sees. If a
> tighter bound is ever needed, the fold can run more than once per slice (e.g. before
> each `run_slice` as well as after) — call this out as a tunable, not v1.

### 4.4 Why NOT a scheduled IRQ12 `EventKind`

input-injection.md §4.1/Phase 1·0(c) deliberately added **no** `EventKind` for the live
mouse — Model A raises interrupts directly / the callback rides `injectAndFire`. The
mouse has **no IRQ12 path in zdos** (OPEN-E: zdos models the INT 33h driver, not the PS/2
controller). Introducing a `scheduler.EventKind.mouse_irq` now would (a) add a real-mode
IRQ12 ISR zdos does not have, and (b) buy nothing over the one-fold-per-slice cadence for
the live case. **Decision: keep the cadence on the pacer's slice boundary; do NOT add an
`EventKind` for live mouse.** (Model B's *scripted* `input_mouse` at-cycle event remains
the future deterministic-scheduling path, input-injection.md §2.2 / Phase 5 — orthogonal
to this doc.)

---

## 5. Absolute-seamless write + derived mickeys + per-mode mapping

### 5.1 Absolute-seamless (the default for a browser cursor)

`foldLiveMouse` converts the normalized abs `{abs_x_q16, abs_y_q16}` to driver virtual
coords using the driver's **live** range and writes them via the existing
range-clamped absolute path (so AX=03 reads them back verbatim):

```
x_virt = (abs_x_q16 * (max_x - min_x)) >> 16 + min_x     // Q16 → [min_x, max_x]
y_virt = (abs_y_q16 * (max_y - min_y)) >> 16 + min_y
injectAbsolute(x_virt, y_virt, buttons, have_abs, have_abs, have_buttons)
```

This is `move_cursor_seamless` (`mouseif_dos_driver.cpp:1304-1349`): the absolute write
goes **directly** to the driver's internal position, NOT through relative integration —
which is exactly what makes AX=03 pollers (BaK, Stunts menus) track the host cursor 1:1.
It works in zdos specifically because INT 33h is host-serviced, so the driver position is
ours to set. The granularity mask (`gran_x=0xFFFE` in mode 13h) is applied on the AX=03
*read* (`posX/posY`, `int33.zig:170-175`) — unchanged.

`max_x`/`min_x`/`max_y`/`min_y` are read live from the driver (`int33.zig:124-127`), so a
guest that calls AX=07/08 to redefine the range, or AX=00 reset that re-derives per mode,
is automatically honored — the normalized [0,1] record is range-agnostic.

### 5.2 Derived mickeys for AX=0B games (in the SAME fold pass)

Some games (and BaK's callback) read **relative mickeys** (AX=0B / the AX=0Ch SI/DI), not
absolute position. Under absolute-seamless we must DERIVE mickeys from successive absolute
samples so AX=0B keeps working:

```
Δx_px = x_virt − last_abs_x   // pixel delta in driver virtual space since last fold
Δy_px = y_virt − last_abs_y
```

Convert pixel delta → mickeys with the driver's mickeys/pixel ratio
(`RATIO_X`/`RATIO_Y`, already constants, `int33.zig:110-111`) and feed it through the
existing mickey accumulator so the sub-pixel remainder and the 0.6 flip-flop threshold
carry exactly (`applyRelAxis`, `int33.zig:427-491`). This UPDATES BOTH the absolute
position (via 5.1) and the mickey counters in one pass; AX=0B's reset-on-read is already
the driver's behavior (`int33.zig:283-298`).

> **Mechanism note (keep the math in `int33.zig`).** Rather than have `foldLiveMouse`
> reach into the accumulators, add an `Int33` method `foldAbsoluteSeamless(x_q16, y_q16,
> buttons, set_*)` (or extend `InjectReq`/`injectAndFire` with an `abs_seamless` mode)
> that: (a) maps Q16→virtual using its own live range, (b) computes Δpx vs the prior
> internal position, (c) drives the absolute write AND the mickey accumulator from that
> Δ, (d) fires the AX=0Ch callback once. This keeps ALL mouse arithmetic + the
> determinism grep surface inside `src/dos/int33.zig` (the controller just forwards the
> coalesced POD). The mickeys-from-absolute conversion is the inverse of the existing
> pixels-from-mickeys path and reuses `RATIO_*` and the `precise_*` accumulators — no new
> float, no new constant.

### 5.3 Per-mode mapping is already maintained

The driver already sets `max_x/max_y` + `gran_x/gran_y` per BIOS video mode on reset
(`int33.zig:180-226`: mode 13h ⇒ `max_y=199`, `gran_x=0xFFFE`, `max_x=639`). Because the
fold scales the normalized record by the driver's *live* `max_*`, **no separate per-mode
table is needed in the API layer** — the driver is the single source of the range, and
the mapping in §5.1 follows it automatically. (This is strictly cleaner than dosbox,
which keeps `MaxPosX/MaxPosY` in the seamless layer; zdos reuses the driver's own range.)

---

## 6. Browser (`app.js`) mapping change

Change `guestCoords` (`app.js:453-463`) to emit **absolute-normalized** coords over the
canvas draw-rect, NOT framebuffer pixels:

```
function guestCoordsNorm(e) {
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return null;
  let nx = (e.clientX - rect.left) / rect.width;   // [0,1] over the rendered image
  let ny = (e.clientY - rect.top)  / rect.height;
  nx = Math.min(1, Math.max(0, nx));
  ny = Math.min(1, Math.max(0, ny));
  return { nx, ny };  // server scales ×MaxPos for the current mode
}
```

- `POST /api/input/mouse` body becomes `{ nx, ny }` (normalized) instead of `{ x, y }`
  (guest px). `MouseReq` gains `nx: ?f32`/`ny: ?f32` (or `?u32` Q16 to keep the wire
  integer) for the live path; the existing `x/y/dx/dy` integer fields STAY for the
  scripted/test path (so input-injection.md's deterministic seam is untouched). The
  server converts `nx/ny` → `abs_*_q16` at ingest.
- Keep the existing **rAF throttle** (`app.js:466-468`) — it already coalesces moves to
  ~display rate on the client, complementing the server-side coalescing. The throttle is
  client convenience; the server's `LiveMouseState` is the authority.
- Buttons (`sendButtons`, `app.js:486-499`) send `{ nx, ny, buttons }` the same way; the
  abs+buttons combine in one ingest mutate.
- The `texW/texH` reliance (`app.js:457-458`) is removed for mouse — the canvas rect is
  the mapping surface, independent of guest resolution. (This also fixes a latent bug:
  before the first frame, `texW/texH` are 0 and `guestCoords` returns null,
  `app.js:455`; normalized mapping needs only the DOM rect.)

> **Why normalize on the client but scale on the server?** The server owns the driver's
> per-mode range (it changes at runtime via AX=07/08/reset); the browser does not know it
> and should not. Sending [0,1] keeps the wire mode-agnostic and the single scaling site
> in `int33.zig` (§5.1), so a mode change can never desync the browser and the driver.

---

## 7. Determinism

This is the section CLAUDE #2/#4 demands be resolved explicitly. There are **two
distinct input paths** and they have **different determinism guarantees**:

### 7.1 Scripted / cycle-scheduled injection — FULLY DETERMINISTIC (unchanged)

The existing `Controller.injectMouse` (`controller.zig:849`) via `Command.input_mouse`
(integer `x/y/dx/dy/buttons` + `set_*`) stays exactly as today: applied at the
one-command-in-flight boundary, a pure function of the preceding command sequence
(input-injection.md §2.1 Model A), byte-identical across runs. Model B (at-cycle
scheduled, input-injection.md §2.2) likewise. **This doc adds NOTHING to that path and
must not perturb it** — the scripted seam (`injectAbsolute`/`injectRelative`) and its
wire fields are untouched. Tests, goldens, and the oracle corpus drive THIS path and stay
byte-reproducible.

### 7.2 Live interactive browser input — NOT bit-reproducible in exact-cycle timing (acceptable)

The coalesced live path's *exact cycle* of each delivered fold depends on which coalesced
value is present at a given slice boundary, which depends on host TCP/scheduler arrival
timing. **We do not pretend this is deterministic.** Its delivery *cadence* (the slice
boundary) is emulated-time (§4.2), so a *recorded input stream replayed at the same
cycles* reproduces identically — but a live human session is not bit-reproducible, and
that is the correct, honest stance for live play (the same stance the paced video stream
already takes, `run_pacer.zig:13-19`). Per CLAUDE: do not claim live input is
deterministic; do ensure it cannot corrupt a deterministic run.

### 7.3 No-live-input ⇒ byte-identical to today (HARD requirement)

When no live input is present, behavior MUST be byte-identical to current zdos:
- The pacer submits `input_mouse_fold` **only when `dirty_seq != last_folded_seq`**
  (§3.3) — with no POSTs, no fold is ever submitted, so a headless/no-input run executes
  the identical command stream it does today. The fold command, when it never runs, adds
  zero cycles.
- `Controller.foldLiveMouse` is a no-op when `live_mouse` is null (headless/test builds
  don't wire it) — the determinism test harness (`machine/determinism_test.zig`) and the
  oracle never construct a `LiveMouseState`, so they are provably unaffected.
- The scripted `Command.input_mouse` path is unchanged (§7.1).

This is the regression to assert (§8 tests): a run with the live plumbing present but no
POSTs is byte-identical (snapshot + RAM + VRAM + `cpu.st.cycles`) to a run without it.

### 7.4 Emulated-time cadence is itself cycle-deterministic

The cadence (one fold per dirty slice, at the slice boundary) rides `slice_cycles` (a
fixed clockless value, `run_control.zig:176`), NOT the host clock. So **given the same
sequence of `(slice_boundary, coalesced_value)` pairs, the resulting state is
byte-identical** — i.e. a replay that re-presents the same coalesced value at each
boundary reproduces exactly. This is what makes the live path *replayable from a record*
even though a fresh live session is not.

### 7.5 Snapshot / restore

- All mouse driver state (incl. the mickey accumulators) is already POD and in
  `Machine.Snapshot` via `dos_mouse` (`int33.zig:669-748`, `machine.zig:628/664/689`).
  The derived-mickey fold (§5.2) reuses those existing accumulator fields, so **no new
  snapshot field is needed in `int33.zig`** — verify the round-trip still covers them.
- The `LiveMouseState` record is **transient host-side ingest state, NOT machine state**
  — it is the live-arrival buffer, not part of the deterministic machine, so it is
  **deliberately NOT snapshotted** (snapshotting an arrival buffer would be meaningless
  and would couple the golden to host timing). Document this exclusion explicitly (it
  mirrors why `RunControl` and the stream buffers are not in `Machine.Snapshot`). At any
  snapshot boundary the coalesced record's only machine-visible effect has already been
  folded into `dos.mouse` (which IS snapshotted), so nothing observable is lost.
- A `last_folded_seq`/`dirty_seq` are POD counters on the host record only; not machine
  state, not snapshotted.

---

## 8. Implementation checklist (phased, each ~one focused commit, gates green)

**Phase 1 — coalesced ingest record + non-blocking POST (no machine change).**
- [ ] `src/api/live_mouse.zig`: `LiveMouseState` POD (§3.1) with `Io.Mutex` (clockless
  `lockUncancelable`), `ingestAbs(nx_q16, ny_q16)`, `ingestRel(dx, dy)`,
  `ingestButtons(mask)`, and `takeFold() ?FoldSnapshot` (locks, snapshots+clears deltas,
  bumps `last_folded_seq`, returns null when not dirty). Pointer-free; no clock, no RNG,
  no float in the stored math (Q16). Add to the `src/api` determinism grep set
  (`api/determinism_test.zig`) — it `@embedFile`s every `src/api` source.
- [ ] Server wiring: construct one `LiveMouseState`, share with the pacer + Controller
  (constructor params, like `RunControl`). Keep `live_mouse: ?*LiveMouseState` optional.

**Phase 2 — non-blocking mouse POST path.**
- [ ] `handleInputMouse` (`server.zig:794`): when `live_mouse` is wired, mutate the
  record and respond `{"ok":true}` **without** a queue submit. Accept the new
  `nx`/`ny` (normalized) fields in `MouseReq` (`json_wire.zig:104`); keep `x/y/dx/dy/
  buttons` for the scripted path. Per-axis abs/rel exclusion preserved. (If `live_mouse`
  is null — headless — fall back to today's `Command.input_mouse` submit, so the existing
  black-box tests keep working.)

**Phase 3 — the fold command + Controller seam (the only machine-touching arm).**
- [ ] `Command.input_mouse_fold` (no payload) in `queue.zig`; `worker.zig` drain arm →
  `Controller.foldLiveMouse()`.
- [ ] `Controller.foldLiveMouse()`: `live_mouse.takeFold()`; if present, build the abs/
  rel/buttons subset and call the new `Int33.foldAbsoluteSeamless(...)` (§5.2) — which
  maps Q16→virtual via the driver's live range, derives mickeys from the absolute Δ,
  writes the absolute position, and fires the AX=0Ch callback once. No-op when null or
  not dirty.
- [ ] `src/dos/int33.zig`: add `foldAbsoluteSeamless` (or an `abs_seamless` mode on
  `injectAndFire`) reusing `setClampedX/Y`, the `precise_*` accumulators, `RATIO_*`, and
  `fireEventCallback`. **All new math stays integer/fixed-point** (the `src/dos`
  determinism grep gate bans `f32`/`f64`).

**Phase 4 — emulated-time cadence on the pacer.**
- [ ] `run_pacer.zig runOneSlice`: after the `run_slice` (and after the existing frame
  sample, `:138-148`), if `live_mouse.dirty_seq != last_folded_seq`, submit ONE
  `input_mouse_fold` through the submit-gate. This is the only place the live fold reaches
  the worker; bounds delivery to ≤ one slice. (The fold submit, like the frame sample,
  goes through the gate so it serializes correctly with debugger commands.)

**Phase 5 — browser mapping.**
- [ ] `app.js`: replace `guestCoords` pixel mapping with `guestCoordsNorm` (§6); send
  `{nx, ny}` (and `{nx, ny, buttons}` for clicks). Remove the `texW/texH` reliance for
  mouse. Keep the rAF throttle.

**Phase 6 — tests (§9) + ROADMAP entry.**
- [ ] All tests below green; grep gates green (`src/dos`, `src/api`).
- [ ] **Add a `plans/ROADMAP.md` entry** when this lands (do NOT edit ROADMAP in this
  planning task) — a short line under the input/mouse milestone noting low-latency
  coalesced live mouse + absolute-seamless tracking.

---

## 9. Tests

Reuse the in-process + black-box idioms (input-injection.md §7; `machine/
determinism_test.zig`; `src/dos/integration_test.zig`).

**Tracking / mapping (in-process, deterministic — drive the SCRIPTED path):**
- [ ] **AX=03 absolute tracking maps into 0–639 per mode.** In mode 13h, fold a
  normalized `nx=1.0` and assert AX=03 reads `max_x` (639, masked by `gran_x=0xFFFE` →
  638); `nx=0.5` → ~319; `nx=0.0` → 0. Repeat in a mode with `max_y=479` to prove the
  range follows the driver, not a hardcoded 320. (This is the exact bug being fixed:
  before, `nx`-equivalent pixel coords only reached `max_x/2`.)
- [ ] **Granularity applied on read** — `gran_x=0xFFFE` rounds X to even on AX=03,
  unchanged from `int33.zig`.

**Derived mickeys (in-process, deterministic):**
- [ ] **AX=0B derived mickeys from successive absolute folds.** Fold abs A, then abs B;
  AX=0B returns the mickey delta for (B−A) scaled by `RATIO_*`, then reads 0 on the next
  AX=0B (reset-on-read). Assert exact fixed-point values (no drift over a multi-fold
  sequence; sub-pixel remainder carries).
- [ ] **Absolute write + mickeys in one pass** — after a fold, BOTH AX=03 (position) and
  AX=0B (mickeys) reflect the same Δ.

**Coalescing (in-process):**
- [ ] **Stale absolute positions dropped.** Ingest abs A, B, C (no fold between);
  `takeFold` yields only C; AX=03 reads C, never A/B. (Overwrite semantics.)
- [ ] **Relative deltas summed, not lost.** Ingest dx=+3, dx=+4, dx=−2 (no fold between);
  one fold applies dx=+5 total.
- [ ] **One callback per fold.** Install an AX=0Ch handler that counts invocations;
  ingest N moves, one fold → the handler ran exactly once (rate-limit), with the latest
  position/buttons.

**Determinism (the load-bearing guarantees):**
- [ ] **No-live-input byte-identical to today.** Two machines: one built WITH the live
  plumbing (record + Controller wired) but zero POSTs, one without; run-to-cycle N;
  assert `snapshot()` + RAM + VRAM + `cpu.st.cycles` byte-equal. Proves the fold-skip
  (no dirty ⇒ no fold ⇒ no cycle) holds.
- [ ] **Emulated-time cadence is cycle-deterministic (replay).** Record a sequence of
  `(fold-at-slice-boundary, coalesced_value)` pairs; replay it twice (re-presenting the
  same value at each boundary); assert byte-identical final state — proves the cadence
  rides cycles, not host time.
- [ ] **Snapshot round-trip.** snapshot → mutate `dos.mouse` via a fold (abs + derived
  mickeys + handler) → restore → byte-equal (extends `integration_test.zig:280`, which
  today doesn't touch mouse). Confirm the mickey accumulators round-trip.
- [ ] **Grep audit.** New `src/api/live_mouse.zig` passes the `api` determinism gate (no
  clock/RNG/thread/float); the `int33.zig` fold math passes the `src/dos` gate (no
  `f32`/`f64`).

**End-to-end (black-box, browser-style stream):**
- [ ] **Absolute stream → guest cursor tracks.** A program that polls AX=03 and writes
  the position to RAM: drive a sequence of normalized `POST /api/input/mouse {nx,ny}` +
  `run` slices, assert the guest-read position follows the normalized stream into the
  full 0–639 range (the 1:1 tracking acceptance criterion). For BaK-style callback games,
  install an AX=0Ch handler and assert it latches the folded position.

---

## 10. Honesty / structural notes

- **Live input is not bit-reproducible, and we say so.** §7.2 — the exact-cycle timing of
  a fresh live session depends on host arrival timing. We do NOT advertise it as
  deterministic. The deterministic guarantees are (a) the scripted/at-cycle path
  (unchanged), (b) no-live-input byte-identity, (c) replay from a recorded
  `(boundary, value)` stream. This is the same honest split the paced video stream uses.
- **No ledger holes.** The fold reuses `injectAndFire` → `runGuestFarCall`, which charges
  every callback instruction through the normal step loop (`int33.zig:601`,
  input-injection.md Phase 1·0(b)). Ingest touches no machine cycles; delivery is the
  same far-call as today. No synthetic-cost hand-wave is introduced.
- **AX=0B-self-integrating-game limit (documented, future work).** A game that does its
  OWN relative integration from raw mickeys (rather than reading AX=03 absolute) and
  applies its own acceleration will not perfectly match host-cursor *speed* under derived
  mickeys (the derived Δ-from-absolute is geometrically faithful but does not reproduce a
  host driver's ballistic curve). For absolute-position pollers (BaK, Stunts menus) this
  is a non-issue (they track 1:1). A **captured / relative-fallback mode** (pointer-lock
  in the browser → raw relative deltas → `injectRelative`, no absolute) is the future
  work for those games; the `LiveMouseState` already carries the summed-delta path
  (`dx_sum/dy_sum`) so the plumbing is ready, but a UI toggle + pointer-lock + the
  per-game choice is out of scope here. Flag, don't fake.
- **No PS/2 / IRQ12 (OPEN-E carried).** This doc does not add a PS/2 mouse device or an
  IRQ12 ISR; the cadence rides the pacer slice, not a scheduled `EventKind` (§4.4),
  consistent with input-injection.md's decision to model the INT 33h driver only. If a
  future target reads the mouse at the PS/2 level, that is OPEN-E work, separate from
  this.
- **The fold-skip is the determinism keystone.** The single most important invariant is
  "no dirty ⇒ no fold submitted ⇒ zero added cycles" (§7.3) — it is what keeps every
  existing deterministic run and the whole oracle corpus byte-identical. The test for it
  (§9) is non-negotiable.
- **ROADMAP** must get a one-line entry when this lands (Phase 6) — not edited in this
  planning task.
```
