# zdos roadmap

Short index of what's built and what's next. **Keep this current** — add an entry when a
milestone/phase lands or a goal changes. Detailed plans live in `plans/`; session memory in
`.claude/.../memory/`.

## Now working
Real-mode 386 + DOS/BIOS core runs real BC3.1/TC++ programs deterministically. A full
**debugger** drives it: in-process control core + an **HTTP/JSON API** (breakpoints, step,
run-to-cycle, inspect/patch CPU+memory, **keyboard/mouse injection**, console read), with
in-process *and* black-box (real-binary-over-HTTP) test suites.

## Timeline (done)
1. **CPU / bus / devices / DOS kernel / BIOS** core (real-mode 386, PIT/PIC/VGA/8042, INT 21h/10h/13h/16h/33h…).
2. **DOS oracle loop** — DOS API complete (43-program BC3.1 corpus) + 4 I/O oracle modalities (VGA mode 13h, keyboard, mouse, sound). → `[[dos-oracle-loop]]`, `plans/dos-oracle-report.md`
3. **Real toolchain on zdos** — TC++ 1.0 compiles→links→runs end-to-end, byte-deterministic. → `[[real-toolchain-on-zdos]]`
4. **Debugger M1 — control core** (breakpoints: exec/cycle/interrupt/memory-watchpoint, step/run-to, side-effect-free inspect, mutate; cycle-neutral). Audited PASS. → `plans/debugger-milestone-1.md`
5. **Debugger M2 — HTTP/JSON API** (~21 endpoints over the core; one-command-in-flight worker, determinism-preserving). Audited PASS. → `plans/debugger-milestone-2.md`
6. **Black-box test harness** (Zig `Session`, spawns the real binary, drives HTTP).
7. **Input injection** (design v3): keyboard polling+blocking (8042 → IRQ1 → INT 09h → BDA ring → INT 16h) + mouse polling (INT 33h) over the API, deterministic; bridge primitives (`runGuestFarCall`, poll-loop emitter); black-box **KEYECHO.EXE** echo+ESC test. Bonus: INT 08h→INT 1Ch timer chaining fixed. → `plans/input-injection.md`, `[[input-injection]]`

## Decisions / next goals
- **[next] Input Phase 3** — mouse AH=0Ch event callback (via `runGuestFarCall`). Last *core* input feature.
- **[backlog] VGA 0x3DA vertical-retrace status bits** — without them, `putch`/retrace-polling VGA programs spin forever. Deterministic cycle-derived toggle.
- **[optional] Input Phase 4/5** — INT 21h-stdin blocking (`waiting_for_input`); cycle-scheduled injection (Model B).
- **[later] M3 — MCP layer** — thin adapter over the HTTP API (dispatch already transport-independent).
- **[later] 386 disassembler** — the API exposes raw instruction bytes only today.
- **[later] more debugger surface** — framebuffer/screenshot capture, memory search, device-state readers, I/O-port breakpoints.

## Standing invariants (the "why")
Determinism is the prime directive (byte-identical state at cycle N; emulated time = f(cycles), never host clock). The host-serviced trap-stub model is sound (research-validated); input injection is **cycle-keyed, never host-time-keyed**. See `CLAUDE.md`.
