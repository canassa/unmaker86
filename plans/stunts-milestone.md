# Stunts 1.1 milestone — boot chain investigation

Target: run **Stunts (4D Sports Driving) 1.1** under zdos. The real entry is `ST.COM`
(a 203-byte launcher), NOT `LOAD.EXE` directly. The boot chain is:

```
ST.COM  → reads SETUP.DAT, INT 21h AH=4B EXECs STUNTS.COM (empty cmd tail)
STUNTS.COM (758-byte COM) → resize mem (AH=4A bx=0x3F6), read SETUP.DAT,
                            INT 21h AH=4B EXECs LOAD.EXE with args "/u MCGA  /ssb"
LOAD.EXE  → EXEPACK-compressed (0 relocs + "!Packed file is corrupt"); decompresses,
            runs the real game, sets VGA mode 13h (MCGA, per SETUP.DAT /u MCGA)
```

`SETUP.DAT` (host `/tmp/stunts/SETUP.DAT`):
```
rem 4 4 -1 -1 -1 -1
load.exe /u MCGA  /ssb
Stunts
disk 'B'
disk 'B'
tdy.cod
```

All driver assets are present (`MCGA.COD/.DIF`, `TDY.COD/.DIF`, `*.DRV`), VFS is
case-insensitive — so not a missing-file / case issue.

## Resolved: the "(null)" filename was a red herring (running LOAD.EXE directly)

The previous run launched `LOAD.EXE` directly with **no command tail**. With no `/u MCGA`
arg the loader's driver-name parse yields a NULL pointer → `printf("%s", NULL)` →
`Loading Stunts...Invalid file name (null).` → clean INT 21h AH=4Ch exit (cycle 580637).
That is **expected** for an argless launch — LOAD.EXE is meant to be EXEC'd by STUNTS.COM
with `/u MCGA`. Launch via `ST.COM` and the args arrive; no "(null)".

## Resolved (FIXED, commit `e143e97`): the TF single-step #DB infinite loop

Launching the real chain (`zdos --serve <P> ST.COM`), LOAD.EXE decompressed correctly
(zdos's A20-off POST + EXEPACK fix already handle this — note DOSBox-x WITHOUT `loadfix`
*also* reports "Packed file is corrupt" for this same high-load chain; zdos is more robust
here), ran the real game, then **span forever at F000:10D3** (~cycle 49M) — the exact
"separate downstream blocker" the EXEPACK done-item predicted, but it was NOT a timer/device
wait.

Root cause — a **CPU bug** in TF/#DB single-step delivery:
- Stunts runs a routine with **TF=1** (single-step) and an **unhooked INT 1 vector**
  (IVT[1] still = the zdos default do-nothing stub at F000:10D0). (The game *does* hook
  INT 0 / divide-error at 79F2:00B8, but not INT 1.)
- The default stub IRETs, popping a FLAGS image with TF still set.
- zdos checked the *post-instruction* TF in `serviceInterrupts`, so #DB re-fired on the
  IRET's own boundary → back to F000:10D0 → IRET → … forever (SP net-unchanged: IRET
  pops 6, INT pushes 6).

Fix (`src/cpu/interrupts.zig`): the single-step #DB is a TRAP recognized only when TF was
already set *entering* the instruction (Intel SDM Vol 3, "Single-Step Trap"). An
instruction that newly sets TF (POPF / IRET / flag store) does not itself trap; the trap
defers one instruction. `step()` now snapshots `tf_at_start` (mirroring the existing
one-instruction STI interrupt shadow, and DOSBox-x's `cpu.trap_skip`,
`core_normal.cpp:228-231`); `serviceInterrupts` gates the #DB on it. Regression test in
`interrupts_test.zig` ("IRET that restores TF=1 does not immediately re-trap"). Determinism
verified (byte-identical CPU state at cycle 120M across two runs). `zig build test` green,
556 tests.

After the fix Stunts single-steps **forward**, sets **MCGA mode 13h** (`/api/device/vga`
mode=19=0x13), and runs on past cycle 700M.

## RESOLVED (root cause found) — the TF loop and the 0xFF garbage jump are BOTH aftermath; the real wall is the game **EXEC-terminating with exit code 1** after the sound-driver phase

The previous session mis-framed the wall. The "permanent TF=1 single-stepping" and the
"jump into 0xFF garbage at 0210:5FBE" are NOT the failure — they are the symptom of the
launcher (`ST.COM`) resuming onto a clobbered stack frame *after the game already aborted*.
The chronology, pinned exactly (cycle-stamped), is below.

### What actually happens (the boot chronology, evidence-backed)

zdos's `INT 21h AH=4Bh` EXEC runs the child **nested to termination** inside the host handler
(`loader.zig:599-609` `br.runUntil` until `dos.terminated`). So the whole chain runs as
*nested* runs, invisible from the top level:

```
cyc 1628   ST.COM   INT 21h AH=4B → runUntil depth=1   (EXEC STUNTS.COM)
cyc 4947   STUNTS.COM INT 21h AH=4B → runUntil depth=2 (EXEC LOAD.EXE = the game)
cyc 49,015,984  depth=2 TERMINATE: psp=0x87C, INT 21h AH=4Ch, **code=1**  ← the game exits with error 1
cyc 49,016,236  depth=1 TERMINATE: psp=0x832 (STUNTS.COM), AH=4Ch code=0  ← clean
cyc 49,016,248  first #DB — the TF single-step "loop" begins (see below)
```

So the game (LOAD.EXE) runs its whole init nested (~49M cycles), loads its assets, **sets MCGA
mode 13h**, then **calls `exit(1)`** from `2551:01FA` (its C-runtime `_exit`). The screen is
mode 13h but BLANK (it aborted before drawing) — `/tmp/stunts/shots/stunts_abort_80M.png`.

### Why the TF loop + 0xFF garbage are downstream noise (NOT separate bugs)

`ST.COM` is a COM launcher that `AH=4A`-shrinks itself to **29 paragraphs** (block ends at
seg 0x0827) but keeps `SS:SP = 080A:FFFE` (phys ~0x1809E) — its stack lives in *freed* memory,
the classic COM-launcher layout. The nested game (loaded high, segs 0x14EC / 0x272E … cover
phys 0x1809E) overwrites that memory while it runs. When `ST.COM`'s own `INT 21h AH=4B`
finally `IRET`s, the 6-byte frame at phys 98456 has been clobbered from the expected
`080A:0168` to **`14EC:148E, FLAGS=0x1586 (TF=1)`** (verified by reading the frame). So ST.COM
"returns" into stale game code at `14EC:148E` (one byte short of the real `call far 272e:3d7a`
at 148F) with TF set → it single-steps dead game memory through the unhooked INT 1, and much
later wanders into a 0xFF region → #UD loop. **All of that is ST.COM running off a corrupted
return frame; it is the consequence of the game's abort, not the cause.** The IVT[1] vector is
never written by the guest (confirmed: it stays `F000:10D0` throughout) — so the
"permanent-TF" theory of session 2 was a red herring.

### The actual question to answer next: WHY does the game `exit(1)`?

Instrumented ring buffer of the last INT 21h calls before the game's `AH=4Ch code=1`
(oldest→newest, all faithful — files open/seek/read/close fine):

```
… open+read mcga.dif, mcga.cod (graphics), tdy.cod (music)         ← all OK
… AH=30 (DOS ver), AH=44 IOCTL ×5, AH=62 (get PSP), AH=48/49/4A (mem)
   AH=3d 'ad15.drv'  (open the AdLib/SB sound driver — "/ssb" in SETUP.DAT)
   AH=42 seek, AH=3e close,
   AH=3d 'ad15.drv'  (reopen), AH=3f read, AH=3e close,
   AH=25 AL=00       (set INT 0 vector — the C runtime abort installing its handler)
   AH=4c AL=01       ← exit(1)
```

So the game aborts **immediately after loading the sound driver `AD15.DRV`**. Notably it does
**NO Sound-Blaster / AdLib port I/O at all** (instrumented ports 0x220-0x22F + 0x388/0x389 →
zero hits before the abort), so the abort is NOT a hardware port-probe failure. It is decided
in `326d:02B6`: `call far 2551:019C` → `cmp byte [bp-0x0E],?` → `je` (skip) — i.e. a host-/
DOS-level check returned "fail". Candidates (rank order for next session):
  1. **A `BLASTER=` environment-variable / config check** the SB driver does (env not set in
     zdos's synthesized env). Removing `/ssb` from SETUP.DAT did NOT change the abort (the
     game still loads AD15.DRV and exits 1 — ST.COM may ignore SETUP line 2's flags), so the
     sound selection lives elsewhere (likely a binary config the game reads).
  2. An **EMS / XMS expectation** during the same init window (BaK-style EMS via INT 67h; the
     `AH=48/49/4A` cluster right before suggests conventional-mem juggling that may precede an
     EMS request).
  3. A genuine **zdos behavioral gap** in one of the IOCTL (`AH=44`) / get-PSP / mem calls
     that makes the driver-init validation fail.

**ORACLE VERDICT (this session): zdos GAP, not faithful behavior.** Under DOSBox-x with
`loadfix -32` + `[sblaster] sbtype=sb16 sbbase=220 irq=7 dma=1`, headless, the `ST.COM` chain
**does NOT exit** — across a 30s run the autoexec's post-`ST.COM` `echo`/`exit` never executes
(the game keeps running), DOSBox performs **3 video-mode switches**, and reaches `INT 15h mouse
reset` (mouse init) — i.e. it gets PAST the AD15.DRV phase that aborts zdos. zdos sets mode 13h
exactly once then `exit(1)`. So Stunts progresses further on the oracle → **zdos fails to
provide something the SB-driver init validates, and the guest aborts.** Next: bisect the
diverging INT 21h/67h call between the two (the AH=44 IOCTL cluster, the env block the driver
reads for `BLASTER=`, or an EMS/XMS expectation are the prime suspects). The debugger
limitation below is the blocker to doing that bisection from the API.

A SECOND, independent DOSBox-x oracle run (89 full machine savestates, 5s/1s/10s intervals, up
to ~3 min) corroborates every structural fact and adds the decisive divergence evidence:
  - **TF is NEVER set under DOSBox-x** (0/89 snapshots; reserved-bit cross-check valid in all
    89). DOSBox runs Stunts with TF=0, normal flow. This independently confirms the zdos
    "permanent TF=1" is the corrupted-return-frame artifact, not guest behavior.
  - **INT 1 = a single `CF` (IRET) do-nothing stub under DOSBox too** (vector `0070:000E`), and
    INT 0/8/9 ARE real game handlers — byte-for-byte the same hook picture zdos sees.
  - **DOSBox's VGA savestate holds REAL rendered content** (a 64000-byte, ~100-distinct-color
    mode-13h image) — the game is actively drawing — whereas zdos aborts with a blank mode-13h
    screen. (Caveat the oracle flagged honestly: the `0xA0000` slice of the plain Memory dump
    is filler; the authoritative pixels live in the savestate's separate `Vga` component, which
    is non-blank.)
  - Oracle build note: the `dosbox-x` on PATH is NOT compiled with the interactive heavy
    debugger (`BPINT`/register-window/CPU-log/`-break-start` are absent); the savestate-parse
    route (parse the `CPU` + `Vga` savestate components) is the working oracle method here.
    Artifacts in `/tmp/sx_work/` (configs, `saves*/`, and C parsers `finder.c`/`fb.c`/`vgacomp.c`).

### STRUCTURAL DEBUGGER LIMITATION discovered (flag, do not paper over)

`bridge.runUntil` (the nested-EXEC driver, `bridge.zig:703`) steps the machine with the RAW
`stepOnceThunk` and **does NOT consult the debug controller's breakpoints / watchpoints /
cycle-cap between steps**. Consequences, all reproduced:
  - `run-to-cycle N` for ANY N inside a nested EXEC (here cyc 1628 … 49,016,236) cannot stop —
    it overshoots to the first boundary AFTER the outermost EXEC returns.
  - `interrupt` / `memory` / `io` / `execution_address` breakpoints set from the API DO NOT
    FIRE for anything the nested child does (the game made thousands of INT 21h calls in that
    window; an `interrupt:0x21` breakpoint saw **zero** of them).
  - The game's entire 49M-cycle init is opaque to the HTTP debugger; it can only be observed
    by re-instrumenting zdos's own Zig (which is how the chronology above was obtained).
This is the #1 thing to fix to make Stunts (and any launcher-chain game) debuggable: the
nested-EXEC loop should route through the controller's step+scan (or the controller should
expose a "step that descends into nested runUntil" mode). It is a debugger-plumbing change, not
an emulation change — the emulation itself is faithful and deterministic (byte-identical CPU
state at cycle 80M across two runs, verified this session).

### Method notes / corrections for the next session
- Drive via `ST.COM`. **Launch `--serve` ONLY via the harness background mode** (or a true
  daemon). `setsid … &`/trailing-`&` inside a one-shot shell gets reaped → the server dies
  after answering one request and every subsequent `curl` "hangs"/fails. (`--break-cycle`
  headless is the reliable, fast path: `--break-cycle 60000000 … ST.COM` reaches the post-abort
  TF loop at F000:10D3 in ~2s.)
- The HTTP debugger CANNOT see inside the nested EXEC (above). To inspect the game's init,
  either fix `runUntil` to honor breakpoints, or temporarily instrument `int21.zig` /
  `dos.terminate` (a last-N-calls ring + a terminate dump pinned this whole investigation).
- `dosbox-x` oracle: needs `loadfix` (EXEPACK load-address quirk, not a Stunts bug) AND should
  set `[sblaster] sbtype=sb16 sbbase=220 irq=7 dma=1` so the SB-driver path matches "/ssb".
- HARD RULES: faithful only; determinism is the prime directive; the exit(1) is the GUEST's
  own decision — find what zdos fails to provide (or what it corrupts) that makes the guest
  decide to abort; do NOT patch around the exit(1) or the downstream TF/garbage symptoms.
