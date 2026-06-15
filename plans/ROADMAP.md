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
8. **VGA 0x3DA Input Status Register #1** — deterministic, cycle-derived vertical-retrace (bit 3) + display-enable (bit 0) status (0x3DA / 0x3BA), integer-only `f(cpu.st.cycles)`, no host clock/float. Unblocks retrace-polling guests (Borland `putch` snow-avoid, mode-13h vsync) that previously spun on the unmapped 0xFF. Excluded from cross-emulator goldens (oracle-non-determinism boundary). → `plans/vga-retrace.md`.
9. **VGA text-mode video (B8000/B0000) + INT 10h text services + `GET /api/screen`** — the text page is backed as guest-RAM-like MMIO (color B8000 / mono B0000, two 32 KiB slabs, `getHostPtr` fast path + `peek8`); INT 10h text services (AH=00 text mode-set, 01/03 cursor shape, 06/07 scroll, 08 read-char, 09/0A write-char, 0E teletype, 13 write-string) are deterministic host traps over the BDA + text page (BDA-width, `useattr=false` attr-preserve, cursor-attr scroll fill, 0x0720 word fill, BEL silent no-op — no host clock, no cursor blink). A side-effect-free `GET /api/screen` renders the BDA active page as a char grid (+ optional `?attrs=1`). **Acceptance gate PASSED:** KEYECHO with real Borland `putch()` (direct B800 video) is now observable on `/api/screen` (ESC terminates ret 0). → `plans/text-mode-video.md`.

## Decisions / next goals
- **[next] Input Phase 3** — mouse AH=0Ch event callback (via `runGuestFarCall`). Last *core* input feature.
- **[backlog] CON → text-page mirror (`/api/screen` follow-up)** — done item #9 keeps `/api/console` (DOS CON device stream) and `/api/screen` (B8000 text page) as DISTINCT surfaces (D-TM5, LOCKED v1). A faithful follow-up routes DOS CON output through the same INT 10h teletype helper so `/api/screen` also shows `printf`/`INT 21h AH=09` output (as a real screen would). Also deferred from #9: display pages 1–7 (AH=05), graphics-mode INT 10h text output, AH=11 font RAM, and a text-buffer-content oracle band (text cells ARE a valid cross-emulator golden). → `plans/text-mode-video.md` §7.
- **[optional] Input Phase 4/5** — INT 21h-stdin blocking (`waiting_for_input`); cycle-scheduled injection (Model B).
- **[later] M3 — MCP layer** — thin adapter over the HTTP API (dispatch already transport-independent).
- **[later] 386 disassembler** — the API exposes raw instruction bytes only today.
- **[later] more debugger surface** — framebuffer/screenshot capture, memory search, device-state readers, I/O-port breakpoints.

## Standing invariants (the "why")
Determinism is the prime directive (byte-identical state at cycle N; emulated time = f(cycles), never host clock). The host-serviced trap-stub model is sound (research-validated); input injection is **cycle-keyed, never host-time-keyed**. See `CLAUDE.md`.
