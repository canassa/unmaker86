# Agent-Driven Machine Provisioning — Implementation Plan

Invert the provisioning model: the system starts **empty**; the MCP-client agent
**provisions** machines on demand (mount dir, program, CPU speed, …) and
**deprovisions** to free memory.

## 1. Current state (verified)

`--serve PORT PROGRAM` boots one machine at launch and the registry clones it:
- `main.zig:99-130` splits PROGRAM → host dir (opened writable+iterate rel. cwd, `:104`) + filename; `init`+`wire`+`boot`.
- `Server.init` (`server.zig:207-231`) stands up one default `Session` (id `zdos-mcp-singleton`, `mcp.zig:38`) + an empty registry.
- `respondMcpInitialize` (`server.zig:1975-2021`) clones the default recipe+mount under `default.lock` → `registry.create` mints `zdos-sess-<seq>` sharing the same writable `Io.Dir`.
- `SessionRegistry.create` (`session_registry.zig:131-207`) IS the provisioning primitive (reserve slot → create+boot Machine → mint id → spawn worker → publish). `destroy`/`teardown` (`:243-279`) IS the deprovision primitive (drain refcount → join worker → free machine+buffers). `MAX_SESSIONS=8`, reject-at-cap.

**Key insight:** the machinery already exists in `create`/`destroy`. The work is to (a) feed agent params into `create`, (b) decouple it from `initialize`, (c) add mount confinement, (d) allow an empty start.

**Per-session memory ≈ 21 MiB**, EMS-dominated: EMS backing ≈14.94 MiB (inline in Machine, `ems.zig:47,57,157`); bus RAM ≈1.06 MiB (`bus.zig:227`); VRAM 256 KiB; render ≈4 MiB + frame ≈308 KiB (`session.zig:276,284,293`). `teardown` truly frees all of it — **deprovision is already leak-free; only a tool that calls it is missing.**

## 2. Recommended decisions

| Q | Recommendation |
|---|---|
| Default session in empty mode | `--serve PORT PROGRAM` keeps auto-provisioning a default session (back-compat); `--serve PORT` starts empty (`Server.session: ?Session = null`). |
| MCP lifecycle | `initialize` → pure handshake (mints nothing). New session-agnostic tools `provision_machine` (→ `registry.create`, returns `zdos-sess-<seq>`) and `deprovision` (→ `registry.destroy`). **Handle == session id (1:1).** |
| Bare machines | **No** — `provision_machine` requires a program and boots it (zdos has no program-less DOS prompt; `boot` always ends in `bootProgram`). |
| CPU speed at provision | `cpu:{mult|mhz}` → `mapCpuSpeed` validator → `m.setClockMult(applied)` inside `create` after boot, before worker spawn (uncontended, deterministic). |
| Resource model | Keep reject-at-cap; `--max-sessions N` flag. |
| Mount security | `--serve-root DIR`; provision opens `mount_dir` **relative to it**, reject absolute / `..`, realpath prefix-check. Default root = cwd. |

## 3. The provisioning API

**Model:** `provision_machine`/`deprovision` are session-agnostic tools (like `initialize`/`tools/list` — they don't resolve an existing `Mcp-Session-Id`). `handleMcp` peeks `params.name` for `tools/call` and dispatches them before the `resolveSession` other tools need (mirrors how `screenshot`/`load` branch as "server-special" in `handleMcpToolCall`). `provision_machine` returns the handle in the result AND as the `Mcp-Session-Id` header. The agent then drives via that id (`Mcp-Session-Id` for MCP, `X-Zdos-Session` for HTTP `/api/*`).

`respondMcpInitialize` is **gutted to a pure handshake** — no recipe copy, no `create`, no session minted, no `Mcp-Session-Id`.

**Request** (`provision_machine` args):
```json
{ "mount_dir": "games/bak", "file": "BAK.EXE", "cmdtail": "", "drive": 2, "cpu": { "mult": 12 } }
```
**Response** (+ `Mcp-Session-Id: zdos-sess-3`):
```json
{ "session": "zdos-sess-3", "drive": 2, "mult": 12, "cpu_hz": 14318184, "live_sessions": 1, "max_sessions": 8 }
```

**Registry delta:** `create(recipe, mount_dir, cpu_mult)` — after `boot`, before worker spawn: `_ = m.setClockMult(cpu_mult);`. The handler opens+confines the `Io.Dir` and passes the handle (keeps `session_registry.zig` host-path-free / grep-clean).

**`deprovision`** arg `{session}` → `registry.destroy(sid)` (refcount+condvar barrier handles in-flight). `DELETE /mcp` stays as a transport alias.

**inputSchema** (`provision_machine`, `cpu.mult` xor `cpu.mhz` via oneOf, drive 0..25, required mount_dir+file):
```json
{"type":"object","properties":{
 "mount_dir":{"type":"string","minLength":1,"description":"host dir mounted as the DOS drive; resolved within --serve-root, no '..'"},
 "file":{"type":"string","minLength":1},"cmdtail":{"type":"string","maxLength":127},
 "drive":{"type":"integer","minimum":0,"maximum":25,"default":2},
 "cpu":{"type":"object","oneOf":[
   {"properties":{"mult":{"type":"integer","minimum":1}},"required":["mult"]},
   {"properties":{"mhz":{"type":"integer","minimum":1}},"required":["mhz"]}]}},
 "required":["mount_dir","file"],"additionalProperties":false}
```

## 4. Mount-dir security / confinement

**Threat:** an agent-supplied `mount_dir` is an arbitrary host path → without confinement a guest reads/writes `/`, `/etc`, `~/.ssh` via INT 21h. (The guest-side resolver already rejects `..` and resolves relative to the mount handle, `vfs.zig:152-153`; the NEW surface is the host path named at provision.)

**Design:** `--serve-root DIR` opened once + realpath'd. Provision: reject leading `/` and `..` components, then `root.openDir(mount_dir, .iterate)` (openat-relative can't traverse above root), then realpath the opened dir and assert it's under `serve_root_real` (symlink-escape guard). Default root = cwd (matches today); `--no-default-root` = fail-closed (refuse provisioning until `--serve-root` set). **Faithful failure:** outside-root / missing / not-a-dir → real `-32602` MountDenied/MountNotFound, never a fake mount.

**Maintainer decision:** how permissive — cwd-default (recommended) vs fail-closed; symlink-escape hard-reject (recommended).

## 5. Per-session FS isolation (reconciles the prior decision)

Per-session mounts **fulfil** the "isolation is the caller's responsibility" decision mechanically: in-process always isolated; host-FS now caller-controllable per session (distinct dirs → real isolation; same dir → shared, caller's choice). Update the `session.zig:12-17` / `session_registry.zig:6-8` headers from "sessions share one mount" to "each session is provisioned with its own mount." Determinism: each machine's file I/O is a pure function of its own provisioned dir's contents at provision time.

## 6. CPU speed flow (determinism)

`cpu:{mult|mhz}` → `mapCpuSpeed` (integer-only) → `setClockMult` (clamps `[1,MAX_MULT]`, applied at a precise cycle, rides the snapshot). No pacer for registry-minted sessions. Omitting `cpu` → default mult 12 (byte-identical to today).

## 7. Empty-start + back-compat

- `--serve PORT PROGRAM`: unchanged (default session + pacer/stream).
- `--serve PORT`: `Server.session: ?Session = null`; no default worker/pacer; empty registry.
- `resolveSession`: blank/singleton id with no default → `null`. `/api/*` in empty mode REQUIRES `X-Zdos-Session`; a blank header → `409 "no machine provisioned; call provision_machine first"`. `/api/health` answers regardless.
- Guard the default-session call sites (`wireStream`/`queueRef`/`runControl`/`liveMouse`/`streamHub`/`joinWorker`/`deinit`) on `if (self.session) |*s|`.
- **Compat:** existing `--serve PORT PROGRAM` + no-header clients/tests are byte-identical (default present). Only `--serve PORT` and provisioning clients see new behavior.

## 8. Determinism analysis

1. Params are caller inputs (like launch args) → fixed inputs ⇒ byte-identical.
2. Independent per-machine determinism (own RAM/CPU/devices/worker).
3. Handle minting = the deterministic `next_seq` counter (no clock/RNG).
4. No host clock/RNG/float introduced (`mapCpuSpeed`/`setClockMult` integer; confinement is control-plane host I/O, never the guest ledger).
5. New code stays in the `src/api` determinism grep set; confinement uses `Io.Dir` ops + no-timeout mutex variants.

## 9. Phased rollout

- **P1 — empty-start + auto-provision** (no MCP API change): `Server.session: ?Session`; `--serve PORT` empty; `--serve PORT PROGRAM` auto-provisions default. *Verify:* existing tests unchanged; `--serve PORT` → `/api/health` ok, blank-session `/api/status` → 409.
- **P2 — `provision_machine`/`deprovision` + per-session mount + cpu + confinement**: add the tools, `--serve-root`, the `create(...,cpu_mult)` delta, gut `respondMcpInitialize`. *Verify (deterministic):* (a) two machines / two dirs → FS isolation; (b) provision→deprovision→slot reusable + memory freed; (c) `cpu:{mult:24}` reflected in `get_clock`; (d) `mount_dir:"/etc"` → `-32602`; (e) `"../../x"` → rejected.
- **P3 — HTTP reconciliation + cap config + docs/schemas**: `--max-sessions N`; empty-mode `/api/*` requires header; update docs + headers; schema↔acceptor drift test.

## 10. Risks / maintainer decisions

1. **Confinement permissiveness (decide):** cwd-default + `--serve-root` + `--no-default-root` fail-closed (recommended); symlink hard-reject.
2. **Handle == session id (recommend 1:1)** — reuses all routing/refcount/teardown; confirm no separate machine-handle layer.
3. **Default-session fate:** keep for `--serve PORT PROGRAM`, `null` for `--serve PORT`. Confirm we're not removing it (would break every no-header client/test).
4. **Bare machines out of scope** — `boot` always ends in `bootProgram`; a true bare DOS state needs a new `bootBare` (separate design).
5. **Future EMS/memory params** — `REPORTED_PAGES`/`ram_total_size` are comptime constants; per-session sizing requires making them runtime (+ re-pin the EMS oracle). Out of scope; schema leaves room.
6. **`initialize` contract change is observable/breaking** — it no longer mints a machine; clients must switch to `provision_machine`. Call out in `docs/mcp.md`.
