---
name: zig-developer
description: Use when writing, reviewing, debugging, or answering questions about Zig code in the zdos project (a DOS emulator). Targets Zig 0.16. Provides an offline, section-indexed Zig 0.16 language reference bundled in this skill (zig-langref/) plus pointers to the dosbox-x, dosbox-staging, and spice86 reference emulators. ALWAYS consult the Zig standard library source at references/zig/lib/std/ — it is the gold standard for idiomatic, well-written Zig 0.16, not just API docs. Invoke for any Zig syntax/semantics/stdlib/build-system question instead of relying on memory, since Zig's API churns between releases.
---

# Zig developer (Zig 0.16)

This project (`zdos`) is written in **Zig 0.16**. Zig has frequent breaking changes
between releases, so **do not answer Zig questions from memory** — Zig 0.15 and
earlier APIs are often wrong for 0.16. Look it up in the bundled reference.

**The Zig standard library source at `references/zig/lib/std/` is the gold standard for
how to write Zig — ALWAYS consult it.** It is not merely API documentation; it is the
reference for idiomatic, high-quality Zig 0.16 code. Read and imitate it.

**Memory & performance:** zdos is a long-running, memory-bound emulator. Do NOT
`alloc`/`free` per operation — it's slow, error-prone, and cache-hostile. Before designing
any subsystem's data structures or allocation, read **`memory-and-performance.md`** (in this
skill): two-allocator discipline, arena `reset(.retain_capacity)`, struct-of-arrays via
`MultiArrayList`, indexes-instead-of-pointers, and a per-subsystem decision table.

## Invoking the Zig CLI

Zig 0.16 is provided by a nix flake + direnv, so just run `zig` directly — direnv puts the
pinned 0.16 compiler on PATH in this repo. `zig version` must print `0.16.0`; if not, run
`direnv allow`.

Common commands (run from the repo root):

```sh
zig build                 # compile + install artifacts to zig-out/
zig build run             # compile and run the app (uses the build.zig "run" step)
zig build --summary all   # build with a full step summary (useful when debugging the build)
zig build test            # run the test step (must be wired in build.zig first)
zig build --list-steps    # show available build steps

zig test src/foo.zig      # compile & run the `test {}` blocks in a single file directly
zig fmt src/              # format code in place
zig fmt --check src/      # verify formatting without writing (use in CI / pre-commit)
zig init                  # scaffold a new build.zig / build.zig.zon (in a fresh dir)
```

Always `zig build` (and `zig build test` once a test step exists) after changes to confirm
the project compiles before reporting done.

## Authoritative references (offline, in-repo)

- **Language reference, split by section:** `zig-langref/` (in this skill directory) —
  one Markdown file per top-level section, converted from
  <https://ziglang.org/documentation/0.16.0/>. Index: `zig-langref/README.md`.
- **Standard library source — THE GOLD STANDARD (submodule):** `references/zig/lib/std/`
  on branch `0.16.x` (Codeberg `ziglang/zig`). **ALWAYS read it.** Treat it as more than
  live API documentation: it is the canonical example of well-written, idiomatic Zig 0.16.
  Before writing any non-trivial Zig in this project, find an analogous module in
  `references/zig/lib/std/` and mirror its conventions — naming, error handling, allocator
  threading, `comptime` usage, doc-comment style, file/struct layout, and test placement.
  When an API's exact current signature matters (signatures churn between versions), grep
  the real source here rather than guessing. The std docs are also viewable via `zig std`,
  but the *source* is the reference for how to write good Zig — not just what exists.
- **Compiler source (submodule):** `references/zig/src/` — consult for compiler/builtin
  behavior beyond the std library.
- **Reference emulator implementations (submodules):** for emulator design questions
  (CPU, DOS API, video/audio, memory layout) consult:
  - `references/dosbox-x/` — feature-rich DOSBox fork (C++)
  - `references/dosbox-staging/` — modernized DOSBox (C++)
  - `references/spice86/` — real-mode reverse-engineering PC emulator (.NET/C#)

## How to use the langref

Each section is ~1–20k tokens; the whole thing is ~130k. **Never load the whole
reference.** Pick the relevant file(s) and `grep`/Read just those. All files below
live in `zig-langref/` (relative to this skill). Use the table to map a topic to a file.

| Topic | File |
|-------|------|
| comptime, generics, type reflection | `34-comptime.md`, `38-builtin-functions.md` |
| error handling, `try`, error sets, `errdefer` | `29-errors.md`, `25-defer.md` |
| optionals, `?T`, `orelse` | `30-optionals.md` |
| pointers, slices, alignment, `[*]`, `[]` | `14-pointers.md`, `15-slices.md` |
| structs, fields, methods, packed/extern | `16-struct.md` |
| enums, unions, tagged unions | `17-enum.md`, `18-union.md`, `19-opaque.md` |
| control flow | `21-switch.md`, `22-while.md`, `23-for.md`, `24-if.md` |
| functions, calling convention | `28-functions.md` |
| integers, floats, operators, vectors, arrays | `09`–`13`, `12-arrays.md` |
| casting, coercion, `@intCast`/`@ptrCast` etc. | `31-casting.md`, `38-builtin-functions.md` |
| builtin functions (`@...`) | `38-builtin-functions.md` |
| undefined/illegal behavior, safety, panics | `41-illegal-behavior.md` |
| memory, allocators, alignment | `42-memory.md` |
| result location semantics | `33-result-location-semantics.md` |
| inline assembly | `35-assembly.md` |
| atomics, single-threaded | `36-atomics.md`, `40-single-threaded-builds.md` |
| build modes | `39-build-mode.md` |
| build system (`build.zig`, `std.Build`, `addExecutable`, modules, deps) | `45-zig-build-system.md` (full guide from ziglang.org/learn/build-system) |
| C interop, `@cImport`, ABI | `46-c.md` |
| WebAssembly, targets, cross-compile | `47-webassembly.md`, `48-targets.md` |
| testing (`test {}`, `std.testing`) | `07-zig-test.md` |
| variables, `const`/`var`, `comptime` vars | `08-variables.md` |
| keywords, style, source encoding | `49`–`51` |
| compile variables (`@import("builtin")`) | `43-compile-variables.md` |

Full list is in `zig-langref/README.md` (52 sections, numbered in doc order).

## Zig 0.16 gotchas (verify in the reference before relying on these)

- I/O has been reworked: `main` can take `std.process.Init`, and stdout is reached via
  `std.Io.File.stdout()` with streaming writes (see `03-hello-world.md`). The old
  `std.io.getStdOut().writer()` patterns from ≤0.15 are stale — confirm the current
  shape in the langref / `references/zig/lib/std/` before writing I/O code.
- When unsure whether an API changed, check the langref section first, then grep the
  std source in `references/zig/lib/std/` for the exact current signature.

## Workflow for a Zig task

1. Identify the concept(s) involved; open the matching `zig-langref/*.md` in this skill.
2. **ALWAYS** find an analogous module in `references/zig/lib/std/` and read it — both for
   the exact current API signatures and as the model for idiomatic, well-written Zig.
   Mirror its conventions in your code.
3. Write code matching std's idioms and the surrounding project style.
4. If it concerns emulator behavior, cross-check one of the reference emulators.
