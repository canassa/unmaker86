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

## The recipe (the spine)

1. **Reproduce headless** with a cycle budget: `zdos --break-cycle N <PROG> [args]`. Record where
   it dies (cycle + symptom). Deterministic and cheap.
2. **Serve it**: `zdos --serve <PORT> <PROG> [args]` — it loads the program and **pauses at the
   entry point** before listening, so you inspect the pristine load for free.
3. **Verify the load first** (rules out loader bugs): diff `GET /api/mem` against the file body and
   sanity-check `GET /api/cpu` (CS:IP / SS:SP / DS / ES, and the `*_base` fields) vs. the headers.
   Most "loader" bugs are actually downstream — a self-decompressor failing is almost always the
   *machine* (CPU/bus/BIOS), not the loader, which only has to place bytes correctly.
4. **Find the error/code path in memory**: `GET /api/mem/search?ascii=<text>` or `?pattern=<hex>`
   to locate a string / magic / opcode sequence in *guest RAM* (survives relocation, unlike a file
   grep).
5. **Localize the failing instruction**: `GET /api/disasm` around the suspect address; set a
   breakpoint (exec-address / cycle / interrupt / memory / io); `POST /api/run`; `step` / `step-n`
   / `step-over` while reading `GET /api/cpu`.
6. **Read the divergent state**: at the failing instruction, dump regs + the memory/ports it
   touches. The wrong value names the wrong layer (loader / CPU / bus / BIOS / device).
7. **Oracle-diff** against DOSBox-x (runnable here) or the reference sources when you need to know
   *which* behavior diverged.
8. **Fix + verify with determinism**: minimal faithful fix; re-run twice → byte-identical CPU
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
| **Chipset/A20/device state** | `GET /api/devices` · `GET /api/device/<a20\|pic\|pit\|vga\|kbc\|speaker\|ems>` |
| **I/O-port shadow** (non-mutating!) | `GET /api/io?port=N` → `{port,value,shadow:true}` |
| Console (DOS CON stream) | `GET /api/console` → `{"data":"<hex>"}` |
| Screenshot | `GET /api/framebuffer?format=png` (also `index`/`rgba`) |
| Add breakpoint | `POST /api/breakpoints {"kind":{…}}` → `{"id":N}` |
| List / get / delete / toggle bp | `GET /api/breakpoints` · `GET\|DELETE /api/breakpoints/<id>` · `PATCH /api/breakpoints/<id>` |
| Run with a cap | `POST /api/run {"cycle_cap":N}` |
| Run to a cycle | `POST /api/run-to-cycle {"cycle":N}` |
| Single step / N steps | `POST /api/step` · `POST /api/step-n {"n":N}` |
| **Step over** (CALL/INT/**REP**) | `POST /api/step-over` → `{"stop":{…},"stepped_into":bool}` |
| Inject input | `POST /api/input/key` · `POST /api/input/mouse` |
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
- **`step-over` runs a whole `REP` string op** (all iterations, real cycles) in one command, immune
  to a mid-REP IRQ. Plain `step` advances ONE rep iteration (EIP stays pinned at the REP) — faithful
  but looks like a hang on a large `rep movsb`; use `step-over` to skip past it.

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

- **DOS filenames must be UPPERCASE 8.3** on the host mount (the VFS is host-case-sensitive); a
  lowercase `load.exe` is "not found."
- Game assets are **not committed** — black-box tests are presence-gated and SKIP honestly when the
  assets are absent. Never fabricate a pass or a golden.
- Capture progress headlessly via `/api/console` + `/api/framebuffer?format=png` (no display
  needed).

## Ground rule

Same as the project's: **never fake it.** If a guest needs an unsupported DOS/BIOS/device behavior,
that is a real gap to surface (and often a useful finding), not something to paper over. The
introspection here is for finding the truth, not manufacturing a green result.
