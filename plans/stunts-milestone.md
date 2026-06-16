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

## OPEN (next wall) — permanent TF=1 single-stepping, then a jump into 0xFF garbage

Two linked open questions remain; both are larger / uncertain, so they are PLANNED here
rather than speculatively patched.

1. **Why does the game run with TF=1 essentially the whole time?** After the fix the guest
   single-steps every instruction through the do-nothing INT 1 (execute one guest insn →
   #DB → stub → IRET → next). That is forward progress but absurdly slow (each guest
   instruction costs a full interrupt round-trip), and is unusual for a shipping game — it
   smells like either a copy-protection / timing trick that expects its OWN INT 1 handler
   to be installed, or TF getting set via a path zdos mishandles. The first #DB return frame
   is `14EC:1490, FLAGS=0x1586 (TF=1)` at cycle 49,016,248, but the static disassembly at
   `14EC` does NOT align with that return IP — the executing stream is relocated /
   self-modified, so the TF-setting instruction was not yet pinned. **Next: pin the exact
   instruction that first sets TF** (single-step backward from the first #DB; or a memory
   watchpoint on the FLAGS slot the setter reads), and decide: faithful guest behavior vs.
   a zdos POPF/IRET/PUSHF flags bug.

2. **The eventual crash into 0xFF garbage.** Around cycle ~700M the guest is executing at
   `0210:5FBE`, whose bytes are all `0xFF` (uninitialised RAM). `FF /7` → #UD → the same
   do-nothing stub → IRET back to the faulting byte → loop (now a #UD loop rather than a
   #DB loop). So the game's control flow jumped to a bad far address. **Whether this is a
   downstream zdos defect (a wrong value computed over the long single-stepped run) or a
   place Stunts also dies without SETUP/loadfix on real hardware is unknown** — it needs the
   TF question answered first (the slow single-stepping makes bispection painful) and an
   oracle diff against DOSBox-x WITH `loadfix` (DOSBox-x without loadfix can't even
   decompress this chain). Do NOT hack around the garbage jump; find why control transferred
   there.

### Method notes for the next session
- Drive via `ST.COM` (the real entry), not `LOAD.EXE`.
- `dosbox-x` oracle: this chain needs `loadfix` (e.g. `loadfix -32` before `ST.COM`) or it
  prints "Packed file is corrupt" — that is a DOSBox EXEPACK-load-address limitation, not a
  Stunts bug; zdos already gets past it.
- The single-stepping is slow: prefer `--break-cycle` headless + targeted breakpoints over
  large `run` caps. Interrupt breakpoints on vectors 1 and 6 catch the two stub loops.
- HARD RULES: faithful only; determinism is the prime directive; raise structural issues,
  don't paper over them.
