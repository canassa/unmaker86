# Debugging guest programs with zdos

zdos is itself a debugger: a headless, cycle-reproducible DOS emulator with an HTTP/JSON API.
This doc is the **reusable workflow** for debugging a guest DOS program with it, the **exact API
moves** that work, and **honest feedback on the tooling** (what helped, what hurt). It is the seed
for a future `debugging-with-zdos` skill.

It was written while root-causing a real bug: **the EXEPACK-compressed Stunts `LOAD.EXE` printed
"Packed file is corrupt" and exited at ~3854 cycles.** That investigation is the worked example
throughout. (Root cause: zdos's BIOS POST wrongly enabled the A20 gate, so the 8086 1 MiB
address wraparound EXEPACK's self-decompressor depends on was broken. Fix: leave A20 off at POST,
matching real hardware + DOSBox. One line in `src/bios/bios.zig`.)

---

## TL;DR recipe

1. **Reproduce headless** with a cycle budget: `zdos --break-cycle N <PROG> [args]`. Note where it
   dies (cycle count + symptom). Cheap, deterministic, repeatable.
2. **Serve it**: `zdos --serve <PORT> <PROG> [args]`. The program is loaded and **paused at its
   entry point** before the listener starts — you inspect the pristine load state for free.
3. **Verify the load** (bytes + segments): diff `GET /api/mem` against the file body; sanity-check
   `GET /api/cpu` (CS:IP/SS:SP/DS/ES) against the file's headers. Rules out loader bugs first.
4. **Find the error path in memory**: locate the error string in the file (`grep -aob`), map its
   file offset to a guest physical address, confirm it landed there with `GET /api/mem`.
5. **Localize the failing instruction**: set a breakpoint (execution-address / cycle / interrupt),
   `POST /api/run`, then `step`/`step-n` and watch `GET /api/cpu` to find the exact branch that
   goes wrong.
6. **Read the divergent state**: at the failing instruction, dump the registers + the memory the
   instruction reads. The wrong value points at the layer that's wrong (loader / CPU / bus / BIOS).
7. **Oracle-diff** against DOSBox-x (runnable here) or the `dos_execute.cpp` reference when you
   need to know which load parameter / behavior diverged.
8. **Fix + verify with cycle-determinism**: apply the minimal faithful fix; re-run twice and confirm
   byte-identical CPU state at a fixed cycle (the core regression test). Add a self-contained
   regression test. Keep `zig build test` green.

---

## The exact API moves (what actually worked)

Start the server (it loads + pauses at entry, then listens):

```sh
zdos --serve 8099 /tmp/stunts/LOAD.EXE /u MCGA
# prints: [zdos] listening 127.0.0.1:8099
```

Route shapes live in `src/api/server.zig` (dispatch table) and `src/api/json_wire.zig` (request
structs). The ones used here:

| Move | Call |
| --- | --- |
| Status (cycles, terminated, last stop) | `GET /api/status` |
| Full CPU (regs, **seg bases**, flags, cycles) | `GET /api/cpu` |
| Read memory (physical) | `GET /api/mem?phys=<dec>&len=<dec>` → `{"data":"<hex>"}` |
| Read memory (seg:off) | `GET /api/mem/seg?seg=<name>&off=<dec>&len=<dec>` |
| Console (DOS CON stream) | `GET /api/console` → `{"data":"<hex>"}` |
| Framebuffer PNG | `GET /api/framebuffer?format=png` (also `index`/`rgba`) |
| **Disassemble** | `GET /api/disasm?linear=N&count=K` (or `?seg=&off=`, or no-arg = CS:EIP) → `{"instructions":[{"linear","seg","off","bytes","length","text"},…]}` |
| **Search guest RAM** | `GET /api/mem/search?pattern=<hex>&start=&len=&max=` (or `?ascii=<text>`) → `{"count","truncated","matches":[{"phys","seg","off"},…]}` |
| **Chipset/A20/device state** | `GET /api/devices` (all groups) · `GET /api/device/<a20\|pic\|pit\|vga\|kbc\|speaker\|ems>` |
| **I/O-port shadow** (non-mutating) | `GET /api/io?port=N` → `{"port","value","shadow":true,…}` |
| Add breakpoint | `POST /api/breakpoints` `{"kind":{"execution_address":{"linear":N}}}` |
| Run with a cap | `POST /api/run` `{"cycle_cap":N}` |
| Run to a cycle | `POST /api/run-to-cycle` `{"cycle":N}` |
| Single step | `POST /api/step` → `{"stop":{"step_complete":{"at_cycle":N}}}` |
| **Step over** (CALL/INT/**REP**) | `POST /api/step-over` → `{"stop":{…},"stepped_into":bool}` |
| Reset + reload | `POST /api/reset` then `POST /api/load {}` |

### Breakpoint kinds (from `src/debug/breakpoints.zig`)

```
{"kind":{"execution_address":{"linear":N}}}            // linear = cs_base + eip  (NOT seg:off!)
{"kind":{"cycle":{"at_cycle":N}}}
{"kind":{"interrupt":{"vector":N}}}
{"kind":{"memory":{"linear":N,"len":L,"access":"read|write|access"}}}   // memory watchpoint
{"kind":{"io":{"port":N,"access":"read|write|access"}}}                 // I/O-port watchpoint
```

When a `memory`/`io` watchpoint fires, the stop carries the access detail:
`{"stop":{"breakpoint":{"id":N,"at_cycle":C,"watch":{"kind":"memory|io","addr":A,"access":"write","value":V}}}}`.
For exec/cycle/interrupt breakpoints `watch` is `null`. `value` is the byte at the
address/port at the stop boundary, read side-effect-free (no re-trip, no cycle charge).

`linear` is a **physical/linear address**, computed as `cs_base + eip` (see `currentLinear`). To break
at a guest `SEG:OFF`, compute `linear = SEG*16 + OFF` yourself — or read `cs_base` from `GET /api/cpu`
and add the offset. There is no `seg`/`off` form.

### Worked example — verify the load is byte-correct

The MZ header said: load module = `(pages-1)*512 + lastpage` = 20317 bytes, header = 512 bytes.
At entry `GET /api/cpu` gave `cs_base=52720` (= the EXEPACK header's guest address). Diff:

```sh
curl -s "http://127.0.0.1:8099/api/mem?phys=52720&len=18"   # guest bytes
xxd -s 20048 -l 18 /tmp/stunts/LOAD.EXE                      # file bytes (= same offset)
# → identical. Loader is NOT the bug; the bytes + segments are perfect.
```

This single check eliminated the most common loader failure (wrong last-page byte count /
`lastpage==0` mishandling that misplaces the trailing data) in one shot.

### Worked example — localize the failing instruction

The error string lives in the loaded image; hand-decoding the stub found the branch
`cmp al,0xb2 ; jne <error>` at the EXEPACK command-validity check. Breaking there and reading regs:

```sh
curl -s -X POST http://127.0.0.1:8099/api/breakpoints \
  -d '{"kind":{"execution_address":{"linear":53684}}}'
curl -s -X POST http://127.0.0.1:8099/api/run -d '{"cycle_cap":100000}'
curl -s http://127.0.0.1:8099/api/cpu
# → AL=0 (should be 0xB0/0xB2). DS=0xFCDF SI=0xFFF8 → phys 0x10CDE8 (ABOVE 1 MiB).
```

Then the decisive read — compare the address the CPU used vs. the 1 MiB-wrapped address:

```sh
curl -s "http://.../api/mem?phys=52715"     # 0x0CDEB (wrapped): b0 ff ...  ← valid command byte
curl -s "http://.../api/mem?phys=1100267"   # 0x10CDEB (unwrapped): 00 00 ... ← garbage zeros
```

EXEPACK deliberately underflows its source segment expecting the 8086 1 MiB wrap; zdos read above
1 MiB instead. That's the bug, with `/api/cpu` + `/api/mem` as the evidence.

### Worked example — confirm the fix with determinism

```sh
zdos --break-cycle 10000000 /tmp/stunts/LOAD.EXE /u MCGA   # run twice
# → both: CS:IP 793a:02bf EAX=00000346 ... byte-identical. Real game code, past the stub.
```

Byte-identical CPU state at a fixed cycle across two runs is the project's core regression check.

---

## The oracle method (compare to a reference)

zdos's whole premise is "compare to a known-good reference." Two oracles:

- **DOSBox-x** is runnable in this environment (`dosbox-x` on PATH; the **source** is under
  `references/dosbox-{staging,x}/`). For loader questions, the fastest path was diffing zdos's
  `src/dos/loader.zig` against `references/dosbox-staging/src/dos/dos_execute.cpp` **line by line**
  (it's where zdos's loader was re-derived from). That's how the candidate divergences — memory
  block sizing (`minsize`/`maxsize`/`maxfree`), `loadseg` (the high-load case for
  `minmemory==maxmemory==0`), relocation, A20 default — were enumerated and checked one by one.
- **Cycle-determinism is its own oracle.** Same binary + inputs ⇒ byte-identical state at cycle N.
  Use it to prove a fix changed *only* what you intended, and to bisect by cycle (`run-to-cycle`
  then `step`).

For this bug, the reference that closed it was `references/dosbox-staging/src/hardware/memory.cpp`:
DOSBox initializes A20 **disabled** (`MEM_A20_Enable(false)`), while zdos's POST forced it on.

---

## Tooling feedback (candid — this is the point of the doc)

### What worked well

- **Load-and-pause-at-entry** (`--serve` boots the program, then listens). You inspect the pristine
  load with zero setup. Huge.
- **`GET /api/cpu` exposes `*_base` segment bases**, not just selectors. Essential here — the entire
  bug was a base+offset → physical computation, and the bases made it visible.
- **`GET /api/mem?phys=` (raw physical) + the seg:off variant.** Being able to read an *arbitrary
  physical address* (including above 1 MiB) is exactly what proved wrap vs. no-wrap. The hex-string
  response diffs cleanly against `xxd` of the file.
- **Cycle-determinism + `--break-cycle`** as a reproducer and as the regression oracle. Re-running
  to a fixed cycle and getting identical registers is a debugging superpower.
- **`run-to-cycle` / `run` with a cap** for fast-forwarding, and **the runnable DOSBox-x +
  sources** as oracles.
- **Headless console + framebuffer capture** (`/api/console`, `/api/framebuffer?format=png`) to see
  guest progress without a display — confirmed Stunts printed "Loading Stunts..." and set mode 13h
  after the fix.

### Resolved by the debugger-tooling round (these gaps are now closed)

The frictions this worked example exposed have since been built — all side-effect-free, on the
worker, cycle-neutral (`plans/{disassembler,mem-search,device-state-reader,step-over-rep,
memory-watchpoints}.md`):

1. ✅ **Disassembler — `GET /api/disasm`.** No more hand-decoding x86. `?linear=N&count=K`, or
   `?seg=&off=`, or no-arg = the current CS:EIP. Returns `{linear,seg,off,bytes,length,text}` per
   instruction; unknown/truncated bytes render `db 0x..` (never a fabricated mnemonic). Reuses the
   CPU's own decode front-end, so it can't drift from the executor (pinned by a length cross-check).
   *Worked example, redone:* `curl ".../api/disasm?linear=53684&count=4"` shows the
   `cmp al,0xb2 ; jne …` branch directly.

2. ✅ **Memory search — `GET /api/mem/search`.** Search *guest RAM* (not the file): `?pattern=<hex>`
   or `?ascii=<text>` (percent-decoded), with `start`/`len`/`max`. Returns ascending, overlapping
   matches as `{phys,seg,off}` + a `truncated` flag. Finds an error string / magic / code sequence
   in memory in one call — no more `grep -aob` the file and hand-mapping offsets.

4. ✅ **Step over a whole REP — `POST /api/step-over`.** It now detects a `REP/REPE/REPNE` string op
   and runs the *entire* REP (all iterations, real cycles) in one command, stopping after — immune
   to an IRQ landing mid-REP. (Also still steps over direct CALL/INT; indirect CALL honestly reports
   `stepped_into:true`.) A 781-byte `rep movsb` is now one `step-over`, not 781 steps.

6. ✅ **A20 / chipset state — `GET /api/devices`.** `a20.enabled`/`mask` is one GET away (plus PIC/
   PIT/VGA/8042/speaker/EMS, and `GET /api/io?port=` for a non-mutating port shadow). The A20 root
   cause would have been a single `GET /api/device/a20` instead of inferring it from read behavior.

**Bonus (not in the original list): I/O-port watchpoints.** The `io` breakpoint kind is now live
(`{"kind":{"io":{"port":N,"access":"…"}}}`) and watchpoint stops now carry the access detail
(`watch:{addr,access,value}`) — so "what wrote this port / address, and with what value?" is a
breakpoint, not a guessing game.

### Still open (→ concrete recommendations)

3. **Breakpoints are linear-address only — brittle for self-relocating code.** EXEPACK copies its
   stub *up* in memory and `retf`s into the copy, so a breakpoint set on the error handler at its
   *load* address never fired (the code now runs at a different segment). I had to re-derive the
   relocated linear address by stepping. → **Add a `seg:off`-relative breakpoint** and/or a
   **"break on execution of these bytes/this pattern"** kind that survives relocation. (Partly eased
   now: `/api/mem/search` finds the relocated copy's bytes, then break on that linear address.) At
   minimum, the linear≠seg:off gotcha is documented here.

5. **No symbol / `.map` support.** Everything is bare addresses. For compressed/cracked retro
   binaries there are no symbols anyway, but for in-house/toolchain-built guests a symbol map would
   turn address soup into names. → **Optional: load a `.map`/symbol file, annotate `/api/cpu` +
   disasm + breakpoints by name.**

7. **No "break on interrupt with AH=" filter.** `interrupt` breakpoints match a vector only. To
   catch the EXEPACK error's `INT 21h AH=4C` exit vs. the `AH=40` write, I'd have had to break on
   every INT 21h and inspect AH. → **Add an optional `ah`/register predicate to interrupt
   breakpoints.**

### Staging / environment gotchas

- **DOS filenames must be UPPERCASE 8.3** on the host mount (the VFS is case-sensitive to the host).
  The Stunts files were pre-uppercased; a lowercase `load.exe` would "not be found."
- **EXEPACK is a *class* of loader issue**, not a one-off: any binary with **0 relocations + the
  "Packed file is corrupt" string** is EXEPACK'd and self-decompresses at runtime relying on
  real-mode quirks (1 MiB wrap, segment underflow, backward overlapping copy). LZEXE, PKLITE, and
  DIET are siblings. The lesson generalizes: **a self-decompressor failing is almost always the
  *machine* (CPU/bus/BIOS), not the loader** — the loader just has to place the bytes correctly,
  which is easy to verify first (step 3).
- **`run`/`run-to-cycle` stop on program termination even past the requested cycle** — if a program
  is already dead, you get `program_terminated`, so reset+reload (`POST /api/reset` then
  `POST /api/load {}`) between experiments to get a fresh, deterministic machine.

---

## What a `debugging-with-zdos` skill should contain

1. **The recipe** (the 8-step list above) as the spine.
2. **The exact API surface table** + the breakpoint-kind JSON shapes, with the **`linear = cs_base +
   eip`** gotcha called out loudly.
3. **The "verify the load first" discipline** — diff `/api/mem` vs. the file body and `/api/cpu` vs.
   the headers before suspecting anything deeper. Most "loader" bugs are actually downstream.
4. **The oracle workflow** — when to run DOSBox-x vs. diff the `dos_execute.cpp`/`memory.cpp`
   sources; and using cycle-determinism (`--break-cycle`, two runs, identical regs) as the
   regression oracle + a cycle-bisection tool.
5. **Common DOS loader / compression pitfalls** — EXEPACK/LZEXE/PKLITE self-decompressors and the
   real-mode behaviors they rely on (1 MiB wrap = A20 off, segment underflow, overlapping backward
   copy); the "0 relocations + a corrupt-string" fingerprint; MCB/`minalloc`/`maxalloc` sizing.
6. **The introspection toolbox** — disassemble (`/api/disasm`), search guest RAM (`/api/mem/search`),
   read chipset/A20 (`/api/devices`, `/api/io?port=`), step over CALL/INT/REP (`/api/step-over`),
   and watch a memory address or I/O port (`memory`/`io` breakpoints, with `{addr,access,value}` in
   the stop). Remaining workarounds: re-derive relocated addresses for self-modifying/relocating
   stubs (search for the relocated bytes, then break on that linear address); break on every vector
   then filter AH by hand (no register predicate yet); no symbol names; reset+reload between
   experiments.
7. **Staging hygiene** — uppercase 8.3 names, presence-gated assets, headless capture.
