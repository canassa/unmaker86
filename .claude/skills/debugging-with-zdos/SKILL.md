---
name: debugging-with-zdos
description: Use when debugging, reverse-engineering, or root-causing the runtime behavior of a guest DOS program under zdos — a crash/hang/wrong-output, a "where does it die", inspecting guest CPU/memory/devices, setting breakpoints or memory/IO watchpoints, disassembling guest code, searching guest RAM, stepping (incl. over CALL/INT/REP), capturing the screen, or oracle-diffing against DOSBox-x. NOT for writing zdos's own Zig (use zig-developer) — this is for driving zdos to debug the GUEST it runs.
---

# Debugging guest programs with zdos

zdos is itself a debugger: a **headless, cycle-reproducible** DOS emulator with an HTTP/JSON
API. Same binary + same inputs ⇒ byte-identical machine state at any cycle N, every run — so a
bug reproduces exactly and a fix can be proven to change *only* what you intended.

This skill is the workflow + the exact API moves for debugging a guest. The detailed worked
example (root-causing the EXEPACK "Packed file is corrupt" crash) and the open-tooling backlog
live in `plans/debugging-with-zdos.md` — read that for the narrative; use this for the moves.

> **curl note:** every `POST` with a body needs `-H 'Content-Type: application/json'` — without it
> you get `415 unsupported_media_type` (a non-empty body MUST be JSON; `server.zig:654`). `GET`s
> need no header.

## The recipe (the spine)

1. **Reproduce headless** with a cycle budget: `zdos --break-cycle N <PROG> [args]`. Record where
   it dies (cycle + symptom). Deterministic and cheap.
2. **Serve the REAL entry point**: `zdos --serve <PORT> <PROG> [args]` — it loads the program and
   **pauses at the entry point** before listening, so you inspect the pristine load for free.
   Beware **launcher chains**: many games ship a small launcher that `INT 21h AH=4Bh` EXECs the real
   binary with a specific command tail (e.g. `ST.COM` → `STUNTS.COM` → `LOAD.EXE /u MCGA`). Debug
   the *launcher*, not the inner EXE — running the inner EXE directly gives it no command tail / PSP
   args and produces misleading symptoms (a NULL-arg parse, a clean early exit) that aren't real.
   **Nested EXEC is now fully debuggable (de-nest landed).** zdos's `INT 21h AH=4Bh` no longer
   runs the child nested inside the host handler — it sets up the child and **returns INTO it**, so
   the child runs on the ONE controller-owned step loop. Your breakpoints / watchpoints / cycle-cap
   / step ALL fire inside a child, at any depth: an `interrupt:0x21` breakpoint counts the inner
   game's INT 21h calls; `run-to-cycle N` for an N inside the child stops AT N; `memory`/`io`/
   `execution_address` watchpoints trip mid-child; `step`/`step-n` descend; a breakpoint pauses
   mid-child and a later `run` resumes it, eventually unwinding to the parent at its INT 22h. So for
   a launcher chain (`ST.COM`→`STUNTS.COM`→`LOAD.EXE`) you can debug the inner game directly from
   the API — no need to re-instrument zdos's own Zig. (To learn the child's load segment so you can
   set an `execution_address` bp in it, run to the child's first INT 21h delivery — at that boundary
   the kernel's current PSP is already the child.) `step-over` of the `INT 21h AH=4Bh` EXEC itself
   is a documented fallback (it step-INTOs the child rather than running the whole child as one
   "call"), like the indirect-CALL case.
   Symptom note: the old "launcher single-steps garbage through INT 1 with TF=1 after the inner
   game already exited" symptom was an artifact of the nested-EXEC clobbering the resume frame; the
   faithful INT-22h unwind removes that class of confusion.
3. **Triage: terminated, hung, or crashed?** Run (`POST /api/run {"cycle_cap":N}`) then
   `GET /api/status` (`terminated` / `ret_code` / last stop) **and** `GET /api/console` FIRST. A
   program that *terminates* (e.g. INT 21h AH=4Ch with a non-zero exit + an error string on the
   console) is a completely different investigation from one that *hangs* (spins) — and the console
   message usually names the failure. Don't assume "hang"; check. (`run`/`run-to-cycle` return
   `program_terminated` once the guest exits.)
4. **Verify the load** (rules out loader bugs): diff `GET /api/mem` against the file body and
   sanity-check `GET /api/cpu` (CS:IP / SS:SP / DS / ES, and the `*_base` fields) vs. the headers.
   Most "loader" bugs are actually downstream — a self-decompressor failing is almost always the
   *machine* (CPU/bus/BIOS), not the loader, which only has to place bytes correctly.
5. **Find the error/code path in memory**: `GET /api/mem/search?ascii=<text>` or `?pattern=<hex>`
   to locate a string / magic / opcode sequence in *guest RAM* (survives relocation, unlike a file
   grep).
6. **Localize the failing instruction**: `GET /api/disasm` around the suspect address; set a
   breakpoint (exec-address / cycle / interrupt / memory / io); `POST /api/run`; `step` / `step-n`
   / `step-over` while reading `GET /api/cpu`.
7. **Read the divergent state**: at the failing instruction, dump regs + the memory/ports it
   touches. The wrong value names the wrong layer (loader / CPU / bus / BIOS / device).
8. **Oracle-diff** against DOSBox-x (runnable here) or the reference sources when you need to know
   *which* behavior diverged.
9. **Fix + verify with determinism**: minimal faithful fix; re-run twice → byte-identical CPU
   state at a fixed cycle; add a self-contained regression test; keep `zig build test` green.

## The toolbox (exact API moves)

Start: `zdos --serve 8099 <PROG> [args]` → `[zdos] listening 127.0.0.1:8099`. Route shapes live in
`src/api/server.zig` (dispatch) + `src/api/json_wire.zig` (request structs).

| Goal | Call |
| --- | --- |
| Status (cycles, terminated, last stop) | `GET /api/status` |
| Full CPU (regs, **seg bases**, flags, cycles) | `GET /api/cpu` |
| Read memory (physical / seg:off) | `GET /api/mem?phys=<dec>&len=<dec>` · `GET /api/mem/seg?seg=<name>&off=&len=` → `{"data":"<hex>"}` |
| **Search guest RAM** | `GET /api/mem/search?pattern=<hex>&start=&len=&max=` (or `?ascii=<text>`) → `{count,truncated,matches:[{phys,seg,off}]}` |
| **Disassemble** | `GET /api/disasm?linear=N&count=K` (or `?seg=&off=`, or no-arg = CS:EIP) → `{instructions:[{linear,seg,off,bytes,length,text}]}` |
| **Chipset/A20/device state** | `GET /api/devices` · `GET /api/device/<a20\|pic\|pit\|vga\|kbc\|speaker\|opl\|ems>` |
| **I/O-port shadow** (non-mutating!) | `GET /api/io?port=N` → `{port,value,shadow:true}` |
| Console (DOS CON stream) | `GET /api/console` → `{"data":"<hex>"}` |
| Screenshot | `GET /api/framebuffer?format=png` (also `index`/`rgba`) |
| Add breakpoint | `POST /api/breakpoints {"kind":{…}}` → `{"id":N}` |
| List / get / delete / toggle bp | `GET /api/breakpoints` · `GET\|DELETE /api/breakpoints/<id>` · `PATCH /api/breakpoints/<id>` |
| Run with a cap | `POST /api/run {"cycle_cap":N}` |
| Run to a cycle | `POST /api/run-to-cycle {"cycle":N}` |
| Single step / N steps | `POST /api/step` · `POST /api/step-n {"n":N}` |
| **Step over** (CALL/INT/**REP**) | `POST /api/step-over` → `{"stop":{…},"stepped_into":bool}` |
| Inject input | `POST /api/input/key {"char":"a"}` (or `{"scancode":N,"make":bool,"ext":bool}`) · `POST /api/input/mouse` |
| Reset + reload | `POST /api/reset` then `POST /api/load {}` |

### Breakpoint & watchpoint kinds (`src/debug/breakpoints.zig`)

```
{"kind":{"execution_address":{"linear":N}}}            // linear = cs_base + eip  (NOT seg:off!)
{"kind":{"cycle":{"at_cycle":N}}}
{"kind":{"interrupt":{"vector":N}}}
{"kind":{"memory":{"linear":N,"len":L,"access":"read|write|access"}}}   // memory watchpoint
{"kind":{"io":{"port":N,"access":"read|write|access"}}}                 // I/O-port watchpoint
```

- **`linear` is physical** = `cs_base + eip` (see `currentLinear`). To break at a guest `SEG:OFF`,
  compute `linear = SEG*16 + OFF` yourself (or read `cs_base` from `GET /api/cpu`). **There is no
  seg/off breakpoint form** — and a load-address breakpoint will NOT fire if the code relocates
  itself (EXEPACK/LZEXE/PKLITE copy their stub up and `retf` into it). Workaround: `/api/mem/search`
  the relocated bytes, then break on *that* linear address.
- When a `memory`/`io` watchpoint fires, the stop carries the access detail:
  `{"stop":{"breakpoint":{"id":N,"at_cycle":C,"watch":{"kind":"memory|io","addr":A,"access":"write","value":V}}}}`.
  `watch` is `null` for exec/cycle/interrupt. `value` is the byte at the address/port read
  side-effect-free at the boundary — answers "what wrote this, and with what value?".
- **`/api/disasm` of a near-CALL/JMP target can look like garbage** when the offset lands in code
  that overlays runtime-populated data (e.g. a driver's BSS, or bytes a relocator hasn't filled at
  pause time), or when you mis-compute `linear` (always `SEG*16 + OFF`). If a disasm window is
  nonsense, don't trust it — `step` INTO the call instead and read the actual executed instruction +
  its `bytes` from `GET /api/cpu` + a 1-count disasm at the live CS:IP. That single-step reveals the
  real opcode (it was how `in al, dx` on the OPL status port 0x388 was found behind a garbage-looking
  `call 0x16b5`).
- **`step-over` runs a whole `REP` string op** (all iterations, real cycles) in one command, immune
  to a mid-REP IRQ. Plain `step` advances ONE rep iteration (EIP stays pinned at the REP) — faithful
  but looks like a hang on a large `rep movsb`; use `step-over` to skip past it. `stepped_into:true`
  in the response means it could NOT step over (e.g. an indirect CALL) and fell back to a single
  step-in — so CS:IP may now be *inside* the callee, not past it.
- **`run`/`run-to-cycle`/`step` stop at the FIRST matching ENABLED breakpoint**, not just the one
  you care about. A leftover `interrupt`/exec breakpoint will pre-empt a cycle-targeted run (e.g. an
  enabled `interrupt:33` stops `run-to-cycle 574000` at the first INT 21h). **Disable/delete
  unrelated breakpoints before a targeted run** (`DELETE /api/breakpoints/<id>` or PATCH-disable).
- **An `interrupt` breakpoint stops at the BIOS/handler entry (CS=F000…), not the guest call
  site.** To recover the caller, read the INT-pushed return frame off the stack:
  `phys = ss_base + sp` → IP, then `+2` → CS, `+4` → FLAGS (via `GET /api/mem`).
- **To NAME a fault/trap spin loop, sweep `interrupt` breakpoints on the CPU exception vectors
  (0–13)** and run. Whichever fires identifies the loop: 0=#DE, 1=#DB (TF single-step), 3=INT3,
  6=#UD (executing garbage), 8=#DF, 13=#GP. This is often the single decisive move on a "spins
  forever" bug — e.g. a vector-1 hit means a single-step (#DB) loop. (The delivered vector is NOT
  exposed by any GET — `cpu.st.last_delivered.vector` has no endpoint — so a per-vector `interrupt`
  breakpoint is the way to discover it.)

### Reading a DOS call's arguments (INT 21h)

The single most useful move for DOS-call debugging — "what file/string/buffer is this call acting
on?" Most INT 21h calls pass a pointer in **DS:DX**. At the call boundary:
`phys = ds_base + (edx & 0xFFFF)` (read `ds_base`/`edx` from `GET /api/cpu`), then
`GET /api/mem?phys=<that>&len=…` to read the filename/string. (For the buffer of an AH=40h write,
the length is in CX.) This turns "INT 21h AH=3Dh failed" into "it tried to open `<name>`".

**Trace the INT 21h call STREAM** (the decisive move for "the game aborts after loading X"): set
one `interrupt:0x21` breakpoint and loop `POST /api/run {"cycle_cap":HUGE}` → `GET /api/cpu`,
decoding `AH=(eax>>8)&0xFF`, `AL`, `BX`/`CX`, and the `DS:DX` target each hit, until
`program_terminated`. A short shell loop prints the whole sequence of file opens/seeks/reads/IOCTLs
the program made right up to its `AH=4Ch` exit — the last few calls usually name the failing
subsystem (e.g. for Stunts: `AH=3D 'ad15.drv'` … `AH=3F read` … `AH=4C AL=01` pinpointed the
sound-driver init as the aborter). The breakpoint fires inside nested children too (the de-nest),
so this works for the inner game of a launcher chain.

### Purity / determinism guarantees (rely on these)

Every inspection above is **side-effect-free and charges zero cycles** — `machine.snapshot()` is
byte-identical before and after. Notably `/api/io` is a *shadow* (it does NOT do a real `IN`, which
would advance the DAC index / pop the 8042 FIFO / flip the AC flip-flop) — that's why it's named
`/api/io`, not `/api/in`, and carries `"shadow":true`.

## The oracle method (compare to a reference)

zdos's whole premise is "compare to a known-good reference." Two oracles:

- **DOSBox-x** is runnable here (`dosbox-x` on PATH; sources under `references/dosbox-{staging,x}/`,
  spice86 under `references/spice86/`). For loader/behavior questions, diff the relevant zdos source
  against the reference line-by-line (e.g. `src/dos/loader.zig` vs.
  `references/dosbox-staging/src/dos/dos_execute.cpp`; A20/memory vs. `hardware/memory.cpp`).
  Caveat: a high-load **EXEPACK** program can report "Packed file is corrupt" under DOSBox-x unless
  you `loadfix` it — that's a DOSBox load-*address* limitation, not a guest or zdos bug, so a
  DOSBox failure there is not evidence against zdos (zdos's A20-off POST handles the 1 MiB wrap).
- **Cycle-determinism is itself an oracle.** Re-run to a fixed cycle and compare registers to prove
  a fix changed only what you intended; bisect a divergence by cycle (`run-to-cycle` then `step`).

## DOS loader / compression pitfalls

- **Self-decompressors** (EXEPACK, LZEXE, PKLITE, DIET) rely on real-mode quirks: the **1 MiB
  address wrap (A20 OFF)**, segment underflow, overlapping backward copies. Fingerprint: **0
  relocations + a "Packed file is corrupt" string**. When one fails, suspect the *machine*
  (A20/CPU/bus), verify the placed bytes first.
- **A20**: real PCs boot A20 **disabled**; software enables it via INT 15h AX=2401 / port 0x92.
  Check it instantly with `GET /api/device/a20`.
- **`run`/`run-to-cycle` stop on program termination** even past the requested cycle. If a program
  is already dead you get `program_terminated`; `POST /api/reset` then `POST /api/load {}` for a
  fresh, deterministic machine between experiments.

## Staging hygiene

- **The VFS matches host filenames CASE-INSENSITIVELY** (`src/dos/vfs.zig:264` `eqlIgnoreCase`, plus
  8.3-munge for long names) — a guest opening lowercase `load.exe` resolves to host `LOAD.EXE` fine.
  Uppercase 8.3 host names are still good hygiene (they ARE the DOS name, no munge), but a
  "file not found" is **not** caused by case — look elsewhere (wrong path, a NULL filename the guest
  built, a missing file).
- Game assets are **not committed** — black-box tests are presence-gated and SKIP honestly when the
  assets are absent. Never fabricate a pass or a golden.
- Capture progress headlessly via `/api/console` + `/api/framebuffer?format=png` (no display
  needed).
- **Keep `--serve` alive across calls:** a server started with a trailing `&` inside a one-shot
  shell gets reaped when that shell exits. **Prefer the harness's own background mode** (the most
  reliable: the server survives and answers every `curl`). `setsid … & disown` / `nohup … & disown`
  were observed to be FLAKY here (the server answered the first `/api/status` then died, making
  every later `curl` look like a "hang") — if you see a server die after one request, that's the
  launch method, not an emulator bug; relaunch via the harness background mode. Sanity-check it's up
  with `GET /api/status` BEFORE a `POST /api/run`. If you only need a fixed cycle target and one
  state dump, **`--break-cycle N` headless is the simplest reliable path** (no server lifecycle at
  all; it prints regs at the stop) and is fast even through a multi-million-cycle nested EXEC.

## Ground rule

Same as the project's: **never fake it.** If a guest needs an unsupported DOS/BIOS/device behavior,
that is a real gap to surface (and often a useful finding), not something to paper over. The
introspection here is for finding the truth, not manufacturing a green result.
