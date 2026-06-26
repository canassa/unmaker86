# zdos review remediation plan — findings #1–#4

Four confirmed correctness findings from the code review of the uncommitted
multi-machine/MCP/streaming change. All re-verified against source. Ground rules
(CLAUDE.md) govern: determinism is the prime directive; no fakes; surface
structural issues.

---

## Finding 1 — BLOCKER: unchecked `u64` multiply in `mapCpuSpeed` crashes the server

**Root cause.** `src/api/mcp_tools.zig:423` — `const mhz_hz: u64 = mv * 1_000_000;`
where `mv` is the user-supplied `mhz` (`?u64`); only guard is `mv == 0`. Any
`mv > ~1.8e13` overflows u64 → checked-arithmetic panic (Debug/ReleaseSafe) →
process dies (taking every session with it). Reachable from MCP `set_clock`
(mcp_tools.zig:638) and HTTP `POST /api/cpu/clock` (server.zig:1107) — shared mapper.

**Clock model = the correct bound.** The worker clamps: `Machine.setClockMult`
(machine.zig:958) does `clamp(mult, 1, MAX_MULT)`, `MAX_MULT = 55` (abi/timing.zig:74);
`worker_test.zig:304` pins that a huge mult CLAMPS, not rejects. `cpuClockHz(55) ≈
65.6 MHz`, so any `mhz >= ~66` already maps past MAX_MULT. Fix = bound `mhz` to that
ceiling before multiplying, then let the worker clamp.

```zig
if (mv == 0) return .{ .fail = ... };
const mhz_ceil: u64 = timing.cpuClockHz(timing.MAX_MULT) / 1_000_000 + 1; // ~66
const mv_b = @min(mv, mhz_ceil);
const mhz_hz: u64 = mv_b * 1_000_000; // <= 66_000_000, no overflow
```
In-range values (`<= 66`) are byte-identical to today. Both front-ends fixed by the
one shared mapper. **Audit:** the `mult` path and the slice-retune arithmetic run on
already-clamped values — safe; the `mhz` multiply is the only unchecked user-input arithmetic.

**Determinism:** none (the knob is an explicit non-determinism input; integer-only; default mult 12 untouched).

**Test:** unit-test `mapCpuSpeed` — `{mhz=maxInt(u64)}` returns `.ok` equal to `{mhz=66}`
(clamps), `{mhz=14}` still maps to 12; no panic.

---

## Finding 2 — HIGH (liveness): `session.lock` held across the socket write pauses emulation

**Root cause.** `handleMcpScreenshot` (server.zig:1784) and `submitAndRespondFramebuffer`
(server.zig:2009) hold `session.lock` (via `defer`-to-end) across the unbounded socket
write (screenshot stream at :1836-1843; framebuffer `req.respond` at :2056, where `body`
slices INTO `session.render`). The pacer calls `produceFrame` INLINE in its slice loop
(run_pacer.zig:157, after submitting `run_slice` at :126; `runLoop` issues the next slice
only after `runOneSlice` returns). `produceFrame` (stream.zig:134) takes the SAME lock
(`&session.lock`, wired session.zig:292). So a slow/non-reading capture client on the
default session, **while a stream client is connected** (the only time the pacer is armed),
holds the lock through the write → blocks `produceFrame` → pacer can't submit the next
`run_slice` → **the guest stops advancing.** The §13 contract's "wall-clock latency only"
claim is wrong because `produceFrame` is inline in the pacer loop.

**Fix.** The lock only protects the read/encode of `session.render`/`png_out`; the wire
transfer needs no lock. Snapshot the bytes to write into per-connection storage under the
lock, unlock, then write:
```zig
session.lock.lockUncancelable(io);
// submit framebuffer_get; encode; COPY finished bytes into Conn-owned scratch
session.lock.unlock(io);     // BEFORE any socket write
// stream self.capture_buf[0..n]
```
Apply to both the screenshot (base64) and the `/api/framebuffer` index/rgba/png paths
(the latter's `req.respond` slice must NOT outlive the lock — copy into the Conn buffer first).

**Memory trade-off.** Worst case ~1.7 MiB (base64-PNG) or ~1.2 MiB (rgba). `Conn` is
~192 KiB today, cap 16. Recommended: a **per-`Conn`, lazily heap-allocated, reused**
capture buffer sized to the PNG/base64 worst case — only capture-active connections pay;
static `Conn` footprint unchanged; total bounded. (A per-session double-buffer is rejected:
concurrent captures on one session need per-connection isolation.)

**Determinism:** unaffected — snapshot/encode under lock over an immutable worker snapshot
(cycle-neutral); the post-unlock write is pure transport. Releasing earlier only changes
wall-clock latency and lets the guest keep advancing.

**Test (key one):** armed pacer + a stalled capture client; assert the guest cycle counter
strictly increases across N pacer ticks while the capture's write is outstanding (pre-fix:
frozen). Assert on cycle monotonicity, never timing.

---

## Finding 3 — HIGH (race): MCP `initialize` reads `default.recipe` without the lock

**Root cause.** `respondMcpInitialize` (server.zig:1939-1940) reads `default.recipe`
(a ~143-byte multi-field `LoadRecipe`, session.zig:126-159) and `default.mount_dir` BY VALUE
with NO `default.lock`. Writers hold it (`handleLoad` :1245/:1264; `buildMcpLoad` lock
:1682, write :1900). Concurrent `POST /api/load` + `initialize` tears the copy → the minted
session boots a corrupt/wrong recipe. The remediation guarded WRITERS only.

**Fix.** Take `default.lock` around the read, copy out, then call `create` OUTSIDE the lock
(don't nest the registry mutex under `session.lock` — §13 lock order):
```zig
default.lock.lockUncancelable(io);
const recipe = default.recipe; const mount_dir = default.mount_dir;
default.lock.unlock(io);
const created = registry.create(recipe, mount_dir) catch ...;
```
**Audit:** the only unlocked reader of shared session state is this one site (recipe/render/
run_control/mount_dir all otherwise locked or by-design). Fixing it closes the class.

**Determinism:** restores deterministic provisioning (today the torn read is interleaving-dependent).

**Test:** one thread toggles `/api/load` between two recipes, another `initialize`s; assert
every minted session booted one of the two WHOLE recipes — never a torn `file_len`/`file` mismatch.

---

## Cross-cutting: lock-contract generalization (from Finding 3)

1. **Make the §13 rule symmetric** (in `session.zig` header AND `docs/multi-machine-plan.md` §13):
   "Any access — read OR write — to shared per-session state that is not a single queue command
   holds `session.lock` across the whole critical section." Add `initialize`'s recipe/mount_dir
   read to the enumerated spans.
2. **Span-declaration follow-up.** The lock span is selected by ad-hoc tool-name string-matching
   (`if eql(name,"load")` etc.) — fragile; it's how Finding 3 slipped in. A per-tool descriptor
   (`{name, span: enum{none,recipe,debugger,capture}}`) read by the dispatcher would make a missing
   entry a compile-time omission, not a silent lock-free path. Larger than the immediate fixes —
   track as follow-up.

---

## Finding 4 — RESOLVED as WON'T-FIX (by design) + doc-honesty correction

**Decision (maintainer, 2026-06-26):** multi-session host filesystem isolation is the
**caller's responsibility, not zdos's.** zdos deliberately shares the one writable host mount
dir across sessions and will NOT add per-session FS isolation (no scratch dir, no overlay, no
read-only minted mounts). This is consistent with the determinism prime directive: the host
filesystem is an EXTERNAL INPUT the caller controls — zdos stays deterministic given fixed
inputs; a caller that lets two sessions mutate a shared dir has fed a shared-mutating input.

**The only required change** (ground rule 2 — no overclaiming): the in-process "share nothing
mutable" / "fully isolated" comments overclaim re: the filesystem. Qualify them to
"share nothing mutable IN-PROCESS (RAM/CPU/devices); the host mount dir is a shared,
caller-managed external input." Spots to correct: `src/api/session.zig:12`,
`src/api/session_registry.zig:5`, `docs/multi-machine-plan.md:191,593`, `docs/mcp.md:180,189`.
No code/behavior change; documentation truthfulness only.

(Note: the unlocked `mount_dir` READ in `respondMcpInitialize` is still covered by Finding 3's
lock fix — sharing the handle is by design, but the read must not tear against a concurrent load.)

---

### (Original analysis retained for reference — the isolation OPTIONS, now not pursued)

**Root cause.** `respondMcpInitialize` passes `default.mount_dir` to `registry.create`
(server.zig:1940); `create` (session_registry.zig:148) hands the SAME `Io.Dir` to every
minted machine's `boot` (machine.zig:561 → `dos.mountDrive`). Guest writes go through to the
host (`HostDirDrive.create`/`writeFile`, vfs.zig:331; mount opened writable at main.zig:104,
no overlay). Two sessions running a program that writes files (real toolchain → OBJ/EXE)
corrupt each other — violating session.zig:12 ("share nothing mutable") and breaking
per-session reproducibility (two sessions writing one host file ⇒ neither reproducible).

**Options.**
- **(a) Per-session writable scratch dir** named `zdos-sess-<seq>` (RNG-free, the registry's
  existing id) under a startup-captured base; created in `create` before `boot`, torn down in
  `teardown`. Needs the program file readable too → seed it by copying the recipe's program
  file into the scratch dir at create (simple, bounded), or combine with (c)'s read-only fallback.
- **(b) Copy-on-write / overlay drive** — read-only base + per-session writable layer. Most
  faithful long-term; the current `HostDirDrive` has NO overlay support → substantial new VFS code.
- **(c) Read-only base mount for minted sessions + per-session writable target.** Open the
  shared base read-only (safe to share concurrently), redirect writes to a per-session location.
  Matches what a debug session needs (mostly READ to load; toolchain WRITES isolated). `(c)-lite`:
  just make the minted mount read-only (a real DOS write-protect error, not a fake) and defer the
  overlay — restores isolation by construction.
- **(d) Document + forbid concurrent writers** — least faithful; conflicts with ground rule 2;
  only with explicit maintainer sign-off.

**Recommendation needs a SCOPE decision:**
- writable FS isolation in v1 → **(a)** with program-file seeding;
- read-only acceptable for v1 → **(c)-lite** (minted mounts read-only; real DOS write-protect
  error; overlay (b) as follow-up).
The default session (`--serve`) keeps its writable mount either way.

**Determinism:** central — two sessions writing one host file is a cross-session non-deterministic
input. Both (a) and (c)-lite restore per-session reproducibility. The host path never enters guest
state, so the dir name is determinism-neutral, but use `zdos-sess-<seq>` (RNG-free, collision-free).

**Test:** two-session file-write isolation — A writes file X = `a*`, B writes X = `b*`; assert A
sees `a*`, B sees `b*` (option a). For (c)-lite: assert a guest write returns a DOS write-protect
error and the base file is unchanged.

---

## Ordered remediation sequence

1. **Finding 1** (BLOCKER, ~5 lines + test, independent) — bound `mhz`. Do first; it's a one-request crash.
2. **Finding 3** (HIGH, ~6 lines + doc + test, independent) — lock the recipe read; make the contract symmetric.
3. **Finding 2** (HIGH, medium) — per-`Conn` capture buffer; release lock before the socket write; both capture paths; update §13.
4. **Finding 4** (HIGH, largest, **gated on the scope decision**) — per-session writable scratch (a) or read-only minted mounts (c)-lite.

1 and 3 are small and independent — land immediately. Then 2, then 4.

## Open questions / maintainer decisions
- **Finding 4 scope** (the fork): writable per-session FS isolation in v1 (a) vs read-only minted mounts (c)-lite vs full overlay later (b)? Needs a product call.
- **Finding 4 cleanup:** per-session scratch dirs must be removed on DELETE/teardown AND on crash (sweep-on-startup); host-side leak otherwise.
- **Finding 2 memory:** ~1.7 MiB × up to 16 conns ≈ 27 MiB worst case; lazy/heap allocation recommended, or cap concurrent captures.
- **Span-declaration follow-up** (from #3): descriptor-driven lock spans to prevent recurrence — larger, track separately.
