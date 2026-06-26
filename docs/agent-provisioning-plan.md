# Agent-Driven Machine Provisioning — Implementation Plan (v2)

Invert the provisioning model: the system starts **empty**; an MCP-client agent
**provisions** machines on demand (mount dir, program, CPU speed), **drives any of
them** by passing a machine handle as a tool argument, and **deprovisions** to free
memory. One agent can juggle multiple machines.

> **v2 changes** (from the v2 review): routing moved from the `Mcp-Session-Id` HEADER
> to a **tool ARGUMENT** (the header is client-library-owned and not model-controllable,
> so it can't select a machine per call); MCP runs **stateless** (no `Mcp-Session-Id`);
> added the **mount-dir fd close** on teardown (the v1 "leak-free" claim was false for
> the fd); merged P1's `initialize` handling; enumerated the full empty-start blast
> radius + the `initialize` test rewrites; fixed the **error-code granularity**; resolved
> the **cap-vs-LRU** contradiction (+ a `list_machines` tool); and corrected the
> **determinism framing** of the mount dir. Security/confinement is **out of scope**
> (local-only tool, per the maintainer).

## 1. Verified foundation (confirmed by the v2 review against source)

- **`SessionRegistry.create`/`destroy` already ARE the provision/teardown primitives.**
  `create` (session_registry.zig:131-207): reserve slot under mutex (errdefer rolls back
  `count`) → `gpa.create(Machine)`+`init`+`wire`+`boot` → `gpa.create(Controller)` →
  `Session.init` → mint `zdos-sess-<seq>` (monotonic, no clock/RNG) → spawn worker →
  publish — full reverse-order errdefer on partial failure. `destroy`/`teardown`
  (:243-279): `fetchRemove` → drain refcount on the clockless `drained` condvar → worker
  join → free machine/controller/session.
- **Deprovision truly frees the ~21 MiB (CONFIRMED).** EMS backing is an INLINE array in
  `Machine` (`dos.ems.backing: [BACKING_PAGES*PAGE_SIZE]u8`, ems.zig:157; `Dos` is inline
  in `Machine`), so it rides `gpa.destroy(m)` (~14.94 MiB). `m.deinit()` frees bus RAM
  (~1.06 MiB, bus.zig:241) + VGA VRAM (256 KiB, vga.zig:389); `session.deinit` frees the
  render buffers (~4 MiB) + shared_frame (~308 KiB). **Caveat (BLOCKER, see §5):** the
  per-session `mount_dir` fd is NOT freed today — v2 fixes that.
- **`setClockMult` at provision is safe + deterministic** — clamps `[1, MAX_MULT=55]`
  (machine.zig:963), applied on the create thread after boot and before the worker spawn
  (uncontended), and `clock.mult` rides `Machine.Snapshot` (machine.zig:857).
- **`boot` is idempotent** (resets first, machine.zig:561) so it is safe in `create`.

The work is plumbing: feed agent params (incl. `cpu_mult` + a per-session mount) into
`create`, **route per-machine tools by an argument**, add `list_machines`, close the
mount fd on teardown, and allow an empty start.

## 2. Routing model — machine handle as a TOOL ARGUMENT (the v2 core)

**Why not the header.** `Mcp-Session-Id` is per-request on the wire but, in practice,
the MCP client library binds ONE id per connection at `initialize` and the **LLM never
controls HTTP headers** — so the model cannot select a machine per call via the header.
To let one agent drive many machines, the selector must live where the model has
control: the **tool arguments**.

**The model.**
- **MCP runs stateless.** `initialize` becomes a pure handshake (mints nothing, sets no
  `Mcp-Session-Id`). No session header is issued or required on the MCP side. (HTTP
  `/api/*` keeps the `X-Zdos-Session` header — HTTP clients *do* control headers and are
  not the LLM; see §7.)
- **`provision_machine` returns a handle** (`zdos-sess-<seq>`) in the tool RESULT.
- **Every per-machine tool gains an OPTIONAL `machine` arg** (the handle). Resolution in
  `handleMcpToolCall` (it already has `params`): `machine` present → registry lookup
  (unknown/destroyed → a tool error, see §8); `machine` absent → the **default machine**
  if one exists (back-compat for `--serve PORT PROGRAM`), else a guided error
  ("no machine; call provision_machine first"). The refcount discipline is unchanged
  (resolve → pin for the call → `defer release`).
- **`provision_machine` / `deprovision` / `list_machines` are machine-agnostic** (they
  don't resolve a `machine` arg; `deprovision`/`list` take the handle as an explicit arg).

This makes routing uniform and model-controllable: the agent provisions, gets handles,
and threads `{"machine":"zdos-sess-3"}` into each `step`/`run`/`read_*` call.

## 3. The provisioning API

### provision_machine (machine-agnostic tool)
Request:
```json
{ "mount_dir": "games/bak", "file": "BAK.EXE", "cmdtail": "", "drive": 2, "cpu": { "mult": 12 } }
```
Response (in the tool result; NO header):
```json
{ "machine": "zdos-sess-3", "drive": 2, "mult": 12, "live_machines": 1, "max_machines": 8 }
```
inputSchema (cpu `mult` xor `mhz`, drive 0..25, required mount_dir+file):
```json
{"type":"object","properties":{
 "mount_dir":{"type":"string","minLength":1,"description":"host dir mounted as the DOS drive"},
 "file":{"type":"string","minLength":1,"description":"program (.COM/.EXE) within mount_dir"},
 "cmdtail":{"type":"string","maxLength":127},"drive":{"type":"integer","minimum":0,"maximum":25,"default":2},
 "cpu":{"type":"object","oneOf":[
   {"properties":{"mult":{"type":"integer","minimum":1}},"required":["mult"]},
   {"properties":{"mhz":{"type":"integer","minimum":1}},"required":["mhz"]}]}},
 "required":["mount_dir","file"],"additionalProperties":false}
```
`cpu` reuses `mapCpuSpeed` (mcp_tools.zig:414, integer-only). The schema↔acceptor drift
test (mcp_tools.zig) is extended to cover this oneOf **in the same phase that adds it**.

### deprovision (machine-agnostic tool) — arg `{ "machine": "zdos-sess-3" }`
→ `registry.destroy(handle)`. Result `{ "machine": "...", "deleted": true, "live_machines": 0 }`.
`DELETE /mcp` is kept ONLY as an HTTP transport convenience (header-addressed) for HTTP
clients; the MCP path uses the `deprovision` tool.

### list_machines (machine-agnostic tool, read-only) — arg `{}` (NEW, §9)
Returns the live handles + per-machine metadata so a model that lost a handle (context
truncation, crash) can recover or reclaim:
```json
{ "machines": [ { "machine":"zdos-sess-3", "file":"BAK.EXE", "drive":2, "mult":12, "cycles":123456 } ],
  "live_machines": 1, "max_machines": 8 }
```
Read-only, side-effect-free; it exposes handles/metadata only — never another machine's
guest memory/registers (that stays per-handle, via the per-machine tools).

### Per-machine tools (the existing 32) — add an optional `machine` arg
Each gains `"machine":{"type":"string","description":"handle from provision_machine; omit for the default machine"}` in its schema. Behavior is otherwise unchanged; omitting it
preserves today's single-machine experience.

### Registry delta
`create(recipe, mount_dir, cpu_mult)` — insert `_ = m.setClockMult(cpu_mult);` between
boot (session_registry.zig:157) and the worker spawn (:192). The handler opens the
per-session `mount_dir` (`Io.Dir`) and passes the handle; `create` stores it on the
`Session` and **teardown closes it** (§5).

## 4. `initialize` → pure handshake (+ the test rewrites)

`respondMcpInitialize` (server.zig:1975) is **gutted**: no recipe copy, no `registry.create`,
no minted id, no `Mcp-Session-Id`. It returns only `protocolVersion`/`serverInfo`/
`capabilities`. This MUST be guarded for empty mode (it currently derefs the default
session — see §6) and lands in the SAME phase as empty-start (they're coupled; v1's "P1
ships without touching initialize" was wrong).

**Shipped tests that assert `initialize` mints a machine (rewrite to `provision_machine`):**
mcp_test.zig:189 ("initialize provisions a session…"), :204 ("initialize twice mints two
distinct…"), :234 ("DELETE /mcp destroys…" — seeds via initialize), :262 ("blank
Mcp-Session-Id reaches the default" — meaningless once stateless). Enumerate these as
deliverables; each becomes "provision_machine → drive by `machine` arg → deprovision."
The sole client is updated in lockstep (this is an intended, observable MCP-contract
break — documented in docs/mcp.md).

**Guided failure:** a per-machine `tools/call` with no `machine` arg AND no default
machine returns a tool error `{code:"no_machine", message:"no machine; call
provision_machine first"}` (NOT a silent 404), so the agent self-corrects.

## 5. Mount-dir fd close on teardown (the v2 BLOCKER fix)

Today all sessions share `main.zig`'s one `Io.Dir`, closed once at `main.zig:110`. Once
`provision_machine` opens a FRESH `Io.Dir` per machine, **teardown must close it** or
every provision/deprovision cycle leaks a directory fd → an autonomous agent churning
machines exhausts host fds and the server dies. Fix:
- `Session` gains an `owns_mount: bool` (true for minted, false for the default which
  `main.zig` owns).
- `teardown`/`Session.deinit` does `if (session.owns_mount) session.mount_dir.close(io);`
  — minted machines close their own dir; the default's stays owned by `main.zig`.
- A test asserts the fd is closed on deprovision (see §11 — note `std.testing.allocator`
  catches memory leaks but NOT fd leaks, so this needs an explicit close-count/observable
  assertion).

## 6. Empty-start + the full blast radius (corrected)

`--serve PORT PROGRAM` keeps auto-provisioning a default machine (back-compat). `--serve
PORT` (no program) starts empty. `Server.session` becomes `?Session = null`. The review
showed the impact is **larger than v1's ~7 sites** — the complete list to audit:

- **`Server` methods** that deref `self.session`: `defaultSession` (server.zig:239),
  `wireStream` (248), `deinit` (257), `streamHub` (262), `runControl` (269), `liveMouse`
  (278), `queueRef` (283), **`bind`/default-worker-spawn (301-306)**, `joinWorker`
  (380-385). All gated on `if (self.session) |*s|` (or the call site in main.zig:152 for
  `bind`).
- **`defaultSession()` becomes `?*Session`**, forcing its callers: `Conn.init` (431) and
  the `serveOne` test entry (460/466), `resolveSession` (1603), `handleMcpDelete` (1684),
  `respondMcpInitialize` (1979).
- **`Conn.session` is a non-optional `*Session`** (server.zig:599/637) deref'd by every
  `/api/*` handler — it must become optional, or a `Conn` for a session-less request must
  refuse before any `self.session.X`.
- **The stream-upgrade path derefs `self.session.stream_hub` at server.zig:420 BEFORE any
  routing** — a guaranteed null-deref in empty mode; guard it (a stream upgrade with no
  default machine → 409/426).
- Pacer/stream wiring in `main.zig:175-204` runs only when a default machine exists.

This is the **largest piece of work**; budget for an audit of every `self.session.X` in
server.zig, not a 7-site patch.

## 7. HTTP `/api/*` reconciliation

HTTP clients control headers, so `/api/*` keeps **`X-Zdos-Session`** (header- or
query-addressed) — unchanged for the default machine when absent. In empty mode a
blank-header `/api/*` op → 409 "no machine provisioned." `/api/health` answers regardless.
(Only the MCP/LLM path needs arg-based routing; the HTTP path is fine with a header
because its clients aren't the model.)

## 8. Error model (per-failure granularity — the v2 fix)

`provision_machine` failures must NOT all collapse to `-32603 internal` (the LLM branches
on the code):
- **Client input errors → `-32602 invalid_params`** (tool result `isError` with a precise
  code): file not found in the mount, mount dir not found / not a directory, bad drive,
  malformed `cpu` (both/neither of mult/mhz). The agent should "fix the call."
- **At the cap → a distinct `machine_limit_reached`** tool error (not `internal`), telling
  the agent to `deprovision` or `list_machines`.
- **Genuine server faults → `-32603 internal`**: OOM, a worker-spawn failure, a program
  that loads but the emulator can't run.

This requires `create` (and the handler) to distinguish boot-failure causes
(file-not-found vs. corrupt-image vs. resource) rather than the current single
`error.BootFailed`. Map each to its code.

## 9. Cap + operability (resolve the v1 contradiction)

v1 kept reject-at-cap but the registry header advertises an unimplemented "LRU
safety net" (`last_request_seq` is stamped, never read). Resolve it:
- **Keep reject-at-cap** (simple, deterministic) and **DELETE the stale LRU promise** from
  the registry header — do not ship a half-promise.
- **Add `list_machines`** (§3) so a model that lost a handle can see and reclaim live
  machines — this removes the "lost handle = un-reclaimable ~21 MiB until restart"
  footgun without needing time/LRU eviction.
- `--max-machines N` launch flag.
- Document the accepted tradeoff: an agent must `deprovision` what it provisions; at the
  cap, `provision_machine` returns `machine_limit_reached` (recoverable via `list_machines`
  + `deprovision`), never a wedge that needs a restart for a well-behaved agent.

## 10. Determinism (corrected framing — the v2 honesty fix)

Mechanically clean (confirmed): deterministic `zdos-sess-<seq>` ids (no clock/RNG),
integer `mapCpuSpeed`/`setClockMult` (mult rides the snapshot), clockless teardown
barrier, each machine advancing only inside its own worker. A provisioned machine's guest
state at cycle N equals the same program launched via `--serve PORT PROGRAM` (the missing
pacer affects only host pacing cadence, never the cycle trajectory).

**But the mount dir is NOT a "fixed input that's a pure function of contents at provision
time" — state it plainly:**
1. The guest **writes** to the mount mid-run (INT 21h), so the dir's bytes are an
   **output** the first run mutates. Cycle-reproducibility therefore holds only for a
   mount that is **byte-stable for the whole run**; replaying a run that wrote files
   requires restoring the dir to its pre-run bytes (an external responsibility, not
   something zdos guarantees).
2. **Two concurrent machines sharing one writable mount inject host-scheduler ordering
   into guest state** (their INT 21h reads/writes interleave) — that breaks the prime
   directive for those machines. The plan must say: per-machine reproducibility holds only
   for a **non-shared-writable** mount. Distinct mount dirs (the natural per-machine
   provisioning) are isolated and reproducible; deliberately pointing two machines at one
   writable dir is a caller choice that voids reproducibility for both.

**Grep gate:** any NEW src/api source (e.g. a provisioning handler split into its own
file) MUST be added to `api_sources` in determinism_test.zig **in the same PR**. If the
provisioning code stays in server.zig/mcp_tools.zig/session_registry.zig (already
embedded), coverage is automatic — prefer that.

## 11. Phased rollout (revised)

- **P1 — empty-start + `initialize`→handshake (MERGED; the two are coupled).** `Server.session:
  ?Session`; `--serve PORT` empty, `--serve PORT PROGRAM` auto-provisions the default;
  gut `respondMcpInitialize`; audit the full §6 site list (incl. `Conn.session` optional +
  the stream-upgrade guard); rewrite the §4 `initialize` tests. *Verify:* existing
  `--serve PORT PROGRAM` + no-`machine`-arg behavior byte-identical; `--serve PORT` →
  `/api/health` ok, a per-machine tool with no machine → `no_machine` guided error.
- **P2 — `provision_machine`/`deprovision`/`list_machines` + the `machine` arg on per-machine
  tools + per-session mount (with the §5 fd close) + cpu.** Add the tools + the arg
  routing in `handleMcpToolCall`; `create(...,cpu_mult)`; the per-failure error codes (§8);
  the schema↔acceptor drift test extended to the new oneOf. *Verify (deterministic):*
  (a) provision two machines (two dirs) + write a file from each guest → FS isolation;
  (b) drive machine A by `{machine:A}` while B is untouched; (c) provision→deprovision→
  `list_machines` shows 0 + slot reusable + **fd closed** (explicit assertion); (d)
  `cpu:{mult:24}` reflected; (e) provision a missing file → `-32602` (not internal);
  (f) at the cap → `machine_limit_reached`.
- **P3 — HTTP `/api/*` empty-mode reconciliation + `--max-machines` + docs.** 409 on
  blank-header `/api/*` in empty mode; update docs/mcp.md (the stateless model, the
  `machine` arg, provision/deprovision/list, the determinism caveat), session.zig /
  session_registry.zig headers (§10 framing; remove the LRU promise), multi-machine-plan §8/§13.

## 12. Testing (close the v1 gaps)

Beyond the happy paths: **the fd-close-on-deprovision** test (§5 — not caught by the
memory leak checker); **deprovision-mid-request** (provision → start a request → deprovision
→ assert clean refcount drain, no UAF); **failed-create slot reuse** (a BootFailed create
must not leak the reserved slot — exercise the errdefer at session_registry.zig:144);
**no-machine-arg guided error**; the **explicit-`mult:12`-equals-launch** byte-identity
golden (proves an explicit default-speed provision == `--serve PORT PROGRAM`). Keep all
assertions on per-machine state at explicit cycle targets, never timing.

## 13. Risks / remaining open decisions

- **Long-lived refcount vs deprovision (verify):** the clockless `drained` condvar barrier
  is sound for short request/response calls, but a future minted-session streaming/keep-alive
  path holding a ref across an unbounded read would hang `deprovision` (no timeout, by
  design). Today `/api/stream` binds only the DEFAULT machine's `stream_hub`, so minted
  machines can't be streamed — state this invariant explicitly so it isn't broken later.
- **No pacer for minted machines:** they are debugger-driven only (the registry can't spawn
  a pacer without importing src/host). So `cpu:{mult}` at provision affects **cycle/emulated-time
  accounting**, not a wall-clock paced free-run (there's no pacer to retune). Document this —
  the cpu knob does less than it might appear. (A future wall-clock-paced minted machine
  would need the pacer/layering question solved.)
- **Handle naming:** the minted id stays `zdos-sess-<seq>` (internally a Session); the
  model-facing arg/field is `machine`. Renaming the id to `zdos-machine-<n>` is optional
  churn — deferred.
- **Bare (program-less) machines — out of scope** (`boot` always ends in `bootProgram`).
- **Per-session EMS/memory sizing — out of scope** (comptime constants today).
- **Security/mount-confinement — out of scope** (local-only tool, per the maintainer).
