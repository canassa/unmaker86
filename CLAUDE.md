# zdos

A headless, cycle-reproducible **DOS emulator** in **Zig 0.16**, built for debugging and
reverse-engineering guest DOS programs through a built-in HTTP/JSON debugger API. DOS and
BIOS services are emulated in host Zig code, so the machine is fully introspectable.

## Ground rules

These outrank any task goal.

1. **Determinism is the prime directive.** Same binary + same inputs ⇒ byte-identical machine
   state at any cycle N, every run. Emulated time is a function of the cycle counter — never the
   host wall clock. Every host-serviced trap charges a fixed, deterministic cycle cost (no holes
   in the ledger). No reliance on host scheduling, real I/O timing, RNG, or uninitialized state.

2. **Write proper code. No shortcuts, no workarounds, no fakes.** Never mock, stub, hardcode, or
   smear over a behavior to make something appear to work — faking DOS is the exact failure mode
   this project exists to escape. Quality before "works for the demo."

3. **Raise structural issues.** If something can't be done faithfully (an unsupportable DOS/BIOS
   API, an unknown cycle cost, a determinism constraint that can't be honored), STOP and surface
   it with specifics. Don't paper over it or silently degrade. If a goal is only reachable by
   violating these rules, the goal is wrong — escalate.

## Commands

Run from the repo root (Zig 0.16 is on PATH via direnv; `zig version` must print `0.16.0`).

```sh
zig build                 # compile -> zig-out/bin/zdos (Debug; ~5x slower interpreter)
zig build -Doptimize=ReleaseFast   # ALWAYS use this for any server/guest you'll actually run — Debug is too slow for real-time guest play (e.g. games slow-motion)
zig build test            # run the test suite (keep it green)
zig fmt src/              # format in place
zig fmt --check src/      # verify formatting

# Run a guest program:
zig build run -- <PROGRAM.COM|EXE> [guest args...]
zig build run -- --break-cycle N <PROGRAM>      # run headless, stop at cycle N
zig build run -- --serve PORT <PROGRAM>         # load, pause at entry, serve the debugger API

# Or use the built binary directly:
zig-out/bin/zdos --serve 8099 <PROGRAM>
```
