# zdos

A **headless, cycle-reproducible DOS emulator** in **Zig 0.16**, built for debugging and reverse
engineering via a built-in **API/MCP server**. Greenfield. Deep references: `plans/` and
`.claude/skills/zig-developer/`.

API-style emulation: DOS/BIOS are serviced in host Zig code (Spice86 lineage), so the machine is
fully introspectable/hookable. Headless by default — framebuffer and state are captured on demand,
not rendered. The API/MCP server (breakpoints, step, run-to-event, inspect/patch CPU+memory,
capture framebuffer, code overrides, scripted resume) is a core feature, not an add-on.

## Ground rule: not a toy — no shortcuts, no fakes

Outranks any task goal.
- Write well-engineered, performant, idiomatic Zig. Quality before "works for the demo."
- **Never mock, stub, fake, or hardcode** to make something appear to work. Faking is the exact
  failure mode (faked DOS) this project exists to escape.
- **Flag structural problems; never bypass them.** If something can't be done faithfully (an
  unsupportable DOS/BIOS API, an unknown cycle cost, a determinism constraint we can't honor),
  STOP and surface it with specifics. Don't paper over or silently degrade.
- If a goal is only reachable by violating these, the goal is wrong — escalate.

## Prime directive: determinism

Same binary + same inputs ⇒ **byte-identical machine state at any cycle N, every run**. Break at
cycle 578 → identical result, always (for a pure program).

Why zdos exists: DOSBox offers no introspection. Spice86 has the hooks but **fakes DOS in host
code**, so INT 21h/BIOS/disk calls skip the thousands of guest instructions they'd run on real
hardware — leaving **holes in the cycle ledger**. Its cycle count is faithful only between traps;
across a trap it smears (frame N drifts 346k–3.6M cycles across launches). The same choice that
gives the hooks creates the hole. **zdos keeps the hooks AND closes the hole** with a complete,
deterministic cycle ledger.

### Hard constraints (never violate)

1. **No holes in the cycle ledger.** Every host-serviced trap (INT 21h, BIOS, port I/O, device
   interaction) charges a fixed, deterministic synthetic cycle cost. This is what separates zdos
   from Spice86.
2. **Emulated time = f(cycle counter).** Never read the host wall clock to drive emulation.
3. **No dependence on host scheduling or real I/O timing.** Inputs/data are fixed/scripted/seeded.
4. **Deterministic interleaving.** Emulation core is single-threaded; the API server and other
   host concerns may thread but must never feed back into emulation timing or ordering.
5. **No uninitialized/undefined state in results.** Deterministic memory init and device reset; no
   reliance on garbage, pointer values, ASLR, or unordered-container iteration order.
6. **Reproducibility is the core regression test.** Launch → run to cycle/event N → capture state
   + framebuffer → byte-identical vs golden. A change that breaks this is wrong.

## First target: Betrayal at Krondor (1993)

The v1 acceptance criterion — run it, deterministically. BaK is a real-mode 386 game (386SX, 1 MB
RAM + ~1 MB EMS, DOS 5.0, VGA, mouse); it does **not** use the FPU, a DOS extender, protected mode,
or paging. Path to it: real-mode 386 CPU → bus + guest RAM → PIT/PIC → BIOS + DOS kernel + EXE
loader → VGA mode 13h → keyboard + mouse (`INT 33h`) → **EMS via a host `INT 67h` handler** (no
EMM386/V86 needed) → sound (deferrable). Confirm real-mode by checking the `.EXE` is a plain `MZ`.

## Architecture

The three reference emulators (see `plans/`) converge on one skeleton: emulated DOS kernel,
callback-trampoline guest↔host bridge, single memory choke point with per-region dispatch,
single-threaded event-queue scheduler, uniform device contract (ports + IRQ + DMA). zdos adopts
it **plus** the deterministic cycle ledger.

Module graph — lower modules never import upper ones:

```
src/cpu/      80386 core, real mode (32-bit ISA), comptime Bus         ← nothing
src/bus/      guest RAM (one fixed block) + page/port dispatch     ← nothing
src/devices/  PIT, PIC, VGA, SB, … self-registering devices        ← bus contract
src/dos/      INT 21h kernel, EXE/COM loader, host-FS VFS          ← bus + machine facade
src/bios/     IVT, INT 10/13/16, callback trampolines              ← bus
src/machine/  wires cpu + bus + devices + dos + bios               ← all above
src/api/      MCP/debug server                                      ← observes machine; never drives timing
src/host/     optional rendering/input/audio                        ← consumes machine output
```

The CPU is an **80386 core in real mode** (full 32-bit instruction set, real-mode addressing),
standalone and independently tested, generic over `Bus` at `comptime` (not a runtime vtable) so the
per-instruction memory path inlines to zero cost. Validate it against public 386 single-step
conformance vectors. **Protected mode, paging, and virtual-8086 are deferred** — added later when a
DOS-extender/DPMI target needs them; structure the code so they can be slotted in.

## Conventions

- **Use the `zig-developer` skill** for all Zig work. Don't write Zig from memory (0.16 ≠ ≤0.15);
  `references/zig/lib/std/` is the gold standard.
- **Memory discipline (also a determinism concern):** no per-op alloc/free; allocate up front;
  guest RAM is one fixed block; prefer SoA / indexes over pointers. See
  `.claude/skills/zig-developer/memory-and-performance.md`.
