# Design Doc: An MCP (Model Context Protocol) API for zdos

**Status:** plan / design only. **Scope:** add a JSON-RPC 2.0 MCP endpoint (`POST /mcp`) as a *second front-end* over the existing transport-independent worker core. No change to `queue.zig` / `worker.zig` / the Machine. Targets Zig 0.16.

---

## 1. Overview and the transport-independent-core insight

The HTTP API in `src/api/` is already split into a **transport layer** (`server.zig`) and a **transport-independent core** (`queue.zig` + `worker.zig`). Every HTTP handler does the same three steps:

1. **Parse** a request into a `wire.*Req` struct (`json_wire.zig`).
2. **Build** a pointer-free POD `q.Command` and `queue.submit()` it (`server.zig:1294-1318`). The single worker thread (`worker.zig:drainOne`, `worker.zig:95`) is the *only* accessor of the `Controller`/`Machine` and returns a pointer-free POD `q.Response`.
3. **Serialize** the `Response` to JSON via the `respondX` helper family and `serializeResponse` (`server.zig:1421`).

The `q.Command`/`q.Response`/`q.ErrCode` types are deliberately transport-neutral. `worker.zig`'s own header already says so (`worker.zig:7-9`): *"`drainOne` returns a typed `Response` carrying a stable `ErrCode` — NEVER an HTTP status. The `code → HTTP status` map lives only in `server.zig`, so the M3 MCP layer reuses the same codes."* `queue.zig:205` likewise: *"the M3 MCP layer reuses these same codes."* This was designed for exactly this work.

**MCP is therefore a pure second front-end.** It parses a different envelope (JSON-RPC) and emits a different wrapper (tool-result content), but it builds the **same `q.Command` values**, calls the **same `queue.submit()`**, and must reuse the **same body serializers** — never a second copy.

```
                         ┌──────────────────────────── listener thread ───────────────────────────┐
  HTTP client  ─POST /api/step─►  dispatch() ─► handleX ─► build q.Command ─┐
                                                                            │
  MCP client   ─POST /mcp──────►  handleMcp() ─► mcp_tools.buildCommand ────┤
                                  (JSON-RPC envelope)                       │
                                                                            ▼
                                                              queue.submit(ctx)   [submit-gate, clockless]
                                                                            │
   ════════════════════════════════════ thread boundary ═══════════════════│══════════════════════════
                                                                            ▼   worker thread (sole Machine owner)
                                                              drainOne() ─► Controller method ─► q.Response
                                                                            │
   ════════════════════════════════════ thread boundary ═══════════════════│══════════════════════════
                                                                            ▼
   HTTP body   ◄─ respondX / serializeResponse ◄── writeX(w, …) ──────────► tool-result content (◄ handleMcp)
                       (both front-ends share the SAME writeX body-builders — no drift)
```

The key refactor that makes "share the same serializers" true is splitting each `respondX` into a pure `writeX(w, …)` body-builder plus a thin HTTP wrapper (§4).

---

## 2. New files (decomposition)

Keep **all `*Server`-touching orchestration inside `server.zig`** (a single `handleMcp` method) and put the **pure, Server-independent pieces in two new files**. Rationale: the `writeX` serializers and the `queue`/`run_control` fields are private to `Server`; a separate file cannot call private methods, and making them `pub` just to reach across files would leak the transport-internal surface. The two new files are pure (no `*Server`, no machine access), which keeps them trivially unit-testable and keeps the determinism grep meaningful.

### `src/api/mcp.zig` — the JSON-RPC 2.0 envelope codec (pure)
Responsibilities (no `Server`, no `debug`/machine import — only `std`):
- `pub const PROTOCOL_VERSION = "2025-06-18";` and `SERVER_NAME`/`SERVER_VERSION` constants.
- `pub const Envelope = struct { jsonrpc: []const u8, id: ?Id, method: []const u8, params: std.json.Value = .null }` where `Id = union(enum){ int: i64, num_str: []const u8, str: []const u8 }`. Parse by `std.json.parseFromValueLeaky` over a whole-body `std.json.Value` tree (so we can carry `params` as a sub-`Value` for the tool layer). `parseFromValueLeaky` verified at `references/zig/lib/std/json/static.zig:177`.
- Envelope error codes: `pub const RpcError = enum(i32){ parse=-32700, invalid_request=-32600, method_not_found=-32601, invalid_params=-32602, internal=-32603 }`.
- Writers (into a caller-supplied `*std.Io.Writer`, matching the existing `writeX` style): `writeErrorEnvelope(w, id, code, msg)`, `writeResultPrefix(w, id)` / `writeResultSuffix(w)`, and `writeId(w, id)` (echo `int` as a number, `num_str` verbatim, `str` as a JSON string). No host time, no allocation on the write path.

### `src/api/mcp_tools.zig` — the tool catalog + arguments→Command mapping (pure)
Responsibilities (imports `std`, `queue.zig` (`q`), `json_wire.zig` (`wire`), `debug`, `cpu` — exactly like `server.zig`, but **no `Server`**):
- `pub const Tool = struct { name, description, input_schema: []const u8 };` and `pub const tools = [_]Tool{ … }` — the static catalog (hand-authored `inputSchema` JSON strings, §8 decision).
- `pub fn writeToolsList(w: *std.Io.Writer) !void` — emits the `tools/list` `result` array from `tools` (each `{name, description, inputSchema}`; `inputSchema` is spliced as a raw JSON object literal — already valid JSON).
- `pub fn buildCommand(arena, name, args: std.json.Value, ctx: *q.RequestCtx) BuildResult` — the heart. Replicates the validation/mapping logic currently inside each `handleX` (range-checks, `std.meta.stringToEnum` for register/segment names, `wire.hexDecode` into `ctx.scratch`, mutual-exclusion checks). It parses `args` into the right `wire.*Req` via `std.json.parseFromValueLeaky` and returns:
  ```zig
  pub const BuildResult = union(enum) {
      command: struct { cmd: q.Command, needs_debugger: bool },
      // a *validation* failure → JSON-RPC -32602 (model fixes the call)
      invalid_params: []const u8,
  };
  ```
  Crucially `buildCommand` is the *same code* that lives in `server.zig`'s `handleRegSet`/`handleMemWrite`/`handleMemSearch`/`handleInputMouse`/etc. The plan is to **extract that mapping logic** out of the `handleX` methods into `mcp_tools.buildCommand`, then have the HTTP `handleX` methods call the same helper. Recommended: extract incrementally per tool as each tool is added, so HTTP and MCP converge on one mapping with zero drift.

No `build.zig` change is needed to *register* these files: they are relative `@import("mcp.zig")`/`@import("mcp_tools.zig")` inside the already-registered `api` module. The only build-adjacent edits are the test aggregator and the determinism grep list (§3, §9).

---

## 3. Exact edits to existing files

### 3.1 `server.zig` — add the route (in `dispatch`, `server.zig:454`)
Insert before the static-asset loop (`server.zig:670`) and the 404 catch-all (`server.zig:674`):
```zig
if (std.mem.eql(u8, path, "/mcp")) {
    if (method != .POST) return self.methodNotAllowed(req);
    return self.handleMcp(req, body, is_json);
}
```

### 3.2 `server.zig` — the `writeX` serializer refactor (the anti-drift requirement)
Refactor each `respondX` into a pure `writeX(self, w: *std.Io.Writer, …) std.Io.Writer.Error!void` body builder (using `try`) + a thin `respondX` wrapper:
```zig
var w = std.Io.Writer.fixed(self.resp_buf[0..]);
self.writeX(&w, …) catch return self.respondError(req, .service_unavailable, "internal", "response too large");
self.respondJson(req, .ok, w.buffered());
```

Helpers to split (current line numbers): `respondValue` (1490), `respondBpList` (1495), `respondRegions` (1508), `respondMem` (1520), `respondConsole` (1529), `respondScreen` (1544), `respondDisasm` (1598), `respondStack` (1626), `respondIoShadow` (1475), `respondDevices` (1465), `respondSearch` (1138), `respondCpuSpeed` (861). Leave `respondRunStatus` (763) HTTP-only.

Also factor the `ErrCode → (status, code_str, msg)` switch out of `respondErrCode` (`server.zig:1642`) into a pure `fn errInfo(code: q.ErrCode) struct { status, code, msg }`. `respondErrCode` uses all three; `handleMcp` uses `.code`/`.msg` to build the `isError` text. One source of truth.

Refactor `serializeResponse` (`server.zig:1421`) so the per-arm body building lives in a shared `fn writeResponseBody(self, w, resp: q.Response, opts: BodyOpts) !void` that switches the arms and calls the `writeX` builders (`opts` carries `want_attrs`/`want_palette`/the search needle). HTTP `serializeResponse` and `handleMcp` both call `writeResponseBody` — the single point guaranteeing byte-identical JSON between the two front-ends.

### 3.3 `server.zig` — the new `handleMcp` method
~70 lines, the only MCP code touching `Server` privates (`self.queue`, `self.run_control`, `self.arena`, `self.resp_buf`, a body scratch, the `writeX`/`writeResponseBody`/`errInfo` helpers). Algorithm in §5. Add a dedicated `mcp_body_buf: [RESPONSE_BUF]u8 = undefined;` for the inner tool body (envelope built in `resp_buf`; inner body escaped into it as a JSON string). See R2.

### 3.4 `main.zig` — banner only (optional, Phase 3)
No new flag. `/mcp` rides the existing `--serve PORT`. Add a banner line after the listen banner (`main.zig:160`): `"[zdos] mcp endpoint: POST http://127.0.0.1:<PORT>/mcp\n"`.

### 3.5 `api.zig` — test aggregator (`api.zig:68-85`)
Add `_ = @import("mcp.zig"); _ = @import("mcp_tools.zig"); _ = @import("mcp_test.zig");`.

### 3.6 `determinism_test.zig` — extend the grep set (`determinism_test.zig:22-46`)
Add `@embedFile("mcp.zig")` and `@embedFile("mcp_tools.zig")` to `api_sources` so the "no host time / RNG / float / clock-affordance" grep covers the new code. **Mandatory.**

### 3.7 `build.zig` — no change required
The `api` module (`build.zig:153-162`) already imports everything `mcp_tools.zig` needs. The `test-api` step (`build.zig:524`) builds `src/api/api.zig` whose `test {}` now pulls the new files.

---

## 4. The tool catalog (tools-only surface)

`needs_debugger = true` means `handleMcp` wraps the submit in `run_control.beginDebugger()/endDebugger()` like `submitDebuggerAndRespond` (`server.zig:1308`).

| Tool name | `q.Command` | wire struct / inputSchema sketch | dbg |
|---|---|---|---|
| `step` | `.step` | `{}` | — |
| `step_n` | `.step_n{n}` | `wire.StepNReq` `{n:u64}` | yes |
| `step_over` | `.step_over` | `{}` | — |
| `run` | `.run{cycle_cap}` | `wire.RunReq` `{cycle_cap?:u64}` (absent→`1<<32`) | yes |
| `run_to_cycle` | `.run_to_cycle{cycle}` | `wire.RunToCycleReq` `{cycle:u64}` | yes |
| `run_to_address` | `.run_to_address{linear}` | `wire.RunToAddrReq` `{linear:u32}` | yes |
| `add_breakpoint` | `.add_bp{kind,one_shot}` | `wire.AddBpReq` (tagged union kind) | — |
| `remove_breakpoint` | `.remove_bp{id}` | `{id:u32}` | — |
| `list_breakpoints` | `.list_bp` | `{}` | — |
| `clear_breakpoints` | `.clear_bp` | `{}` | — |
| `set_register` | `.reg_set` | `wire.RegSetReq` union (reg32/reg16/reg8/seg/eip/flags) — fiddly arm (§8) | — |
| `read_memory` | `.mem_peek{phys,len}` | `wire.MemPeekReq` `{phys:u32,len:u32}` | — |
| `write_memory` | `.mem_write{phys,len}` | `wire.MemWriteReq` `{phys:u32,data:hex}` | — |
| `read_memory_seg` | `.mem_peek_seg{seg,off,len}` | `wire.MemPeekSegReq` `{seg:str,off,len}` | — |
| `write_memory_seg` | `.mem_write_seg{…}` | `wire.MemWriteSegReq` `{seg,off,data:hex}` | — |
| `search_memory` | `.mem_search{…}` | `{pattern?:hex \| ascii?:str, start?, len?, max?}` (exactly one) | — |
| `disassemble` | `.disasm{origin,count}` | `{linear? \| (seg?,off?) \| cs:eip, count?:1..64}` | — |
| `read_cpu` | `.cpu_get` | `{}` | — |
| `read_screen` | `.screen_get` | `{attrs?:bool}` | — |
| `read_devices` | `.devices_get` | `{palette?:bool, device?:"a20\|pic\|pit\|vga\|kbc\|speaker\|opl\|ems"}` | — |
| `read_stack` | `.stack_get{count}` | `{count:u16}` | — |
| `read_ivt` | `.ivt_get{vector}` | `{vector:u8}` | — |
| `read_console` | `.console_get` | `{}` | — |
| `input_key` | `.input_key{…}` | `wire.KeyReq` `{scancode? \| char?, make?, ext?}` | — |
| `input_mouse` | `.input_mouse` | `wire.MouseReq` **scripted path only** `{x?,y?,dx?,dy?,buttons?}` | — |
| `read_io_port` | `.io_shadow{port}` | `{port:u16}` (non-mutating shadow) | — |
| `get_clock` | `.clock_get` | `{}` | — |
| `set_clock` | `.set_clock{mult}` | `{mult? \| mhz?}` (+ pacer-slice retune, §4.4) | — |
| `reset` | `.reset` | `{}` | — |
| `load` | `.load` | `wire.LoadReq` `{drive?,file?,cmdtail?}` (+ recipe persist, §4.4) | — |
| `status` | `.status` | `{}` | — |

`input_mouse` maps to the scripted/deterministic path, NOT the live coalesced browser-cursor path (wrong tool for a deterministic client). `framebuffer` deferred from v1 (§7).

### 4.4 Tools needing a server-side post-step
- `load`: replicate `handleLoad` (`server.zig:1032`) — overlay `LoadReq` onto `self.recipe`, persist, then submit `recipe.toCmd()`.
- `set_clock`: replicate `handleCpuSpeedSet` (`server.zig:819`) — submit `.set_clock`, then `self.run_control.setSlice(...)` from the applied mult (`server.zig:851`).

These two are the only tools where `handleMcp` does more than submit + serialize.

---

## 5. JSON-RPC + MCP lifecycle handling (`handleMcp` algorithm)

```
handleMcp(self, req, body, is_json):
  reset arena (.retain_capacity)
  tree = parseFromSliceLeaky(std.json.Value, arena, body, wire.parse_options)
         on failure → JSON-RPC error envelope {code:-32700} (id:null), HTTP 200
  if tree is .array → (batch) v1: -32600 "batches unsupported" (R3)
  env = parse Envelope (method:str required; id optional; params:Value)
        missing/!="2.0"/no method → -32600
  switch (env.method):
    "initialize": result = {protocolVersion, serverInfo:{name,version}, capabilities:{tools:{}}}
    "notifications/*": no id → HTTP 202, empty body; return
    "tools/list": {result:{tools:[…]}} via mcp_tools.writeToolsList
    "tools/call":
        name = params.name (missing → -32602)
        args = params.arguments orelse {}
        br = mcp_tools.buildCommand(arena, name, args, &ctx)
        switch (br):
          .invalid_params(msg) → -32602
          .command(cmd, needs_debugger):
            if needs_debugger: restore = beginDebugger(); defer endDebugger(restore)
            ctx.cmd = cmd; resp = self.queue.submit(&ctx)
            if resp == .err(code): body=errInfo→{"error":…}; isError=true
            else: writeResponseBody(body, resp, opts-from-args); isError=false
            apply load/set_clock post-step here (sees self.recipe / run_control)
            emit {"jsonrpc":"2.0","id":echo,"result":{"content":[{"type":"text","text":<body as escaped string>}],"isError":isError}}
    else: -32601
```

Sample success (inner JSON is the SAME bytes `/api/step` returns, embedded as an escaped string):
```
→ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"step","arguments":{}}}
← {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"stop\":{…}}"}],"isError":false}}
```
Tool ran but emulator ErrCode (model-recoverable, NOT a transport error):
```
← {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"{\"error\":{\"code\":\"address_out_of_range\",…}}"}],"isError":true}}
```
Protocol error:
```
← {"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"unknown tool: nope"}}
```
Notification → HTTP 202, empty body.

`id` echo: `integer`→number, `string`→JSON string, `number_string`→verbatim. Absent id ⇒ notification ⇒ no response.

---

## 6. Error mapping

### 6.1 `q.ErrCode` (the tool *ran*) → MCP tool error (`result`, `isError:true`)
content text = `{"error":{"code":<code>,"message":<msg>}}` from shared `errInfo`. HTTP status ignored for MCP.

| `q.ErrCode` | content `code` | (HTTP, ref) |
|---|---|---|
| `breakpoint_table_full` | `breakpoint_table_full` | 503 |
| `no_such_breakpoint` | `no_such_breakpoint` | 404 |
| `address_out_of_range` | `address_out_of_range` | 400 |
| `out_of_range` | `out_of_range` | 400 |
| `bad_request` | `bad_request` | 400 |
| `not_implemented` | `not_implemented` | 501 |
| `load_failed` | `load_failed` | 503 |
| `input_buffer_full` | `input_buffer_full` | 503 |

### 6.2 JSON-RPC protocol errors (could not dispatch) → JSON-RPC `error`
| Condition | code |
|---|---|
| body not valid JSON | `-32700` |
| missing `jsonrpc:"2.0"` / missing `method` / top-level array batch (v1) | `-32600` |
| unknown method | `-32601` |
| `tools/call` unknown tool, or `arguments` fail to parse/validate | `-32602` |
| writer overflow / internal | `-32603` |

Dividing line: **validation before submit** (schema/range/enum) = `-32602` (model fixes the *call*); **emulator-domain failures after submit** = `isError` content (model fixes its *plan*). `/mcp` returns HTTP **200** for any well-formed JSON-RPC response (including `error`), **202** for a notification.

---

## 7. Framebuffer deferral

`framebuffer_get` is a 64 KiB–1.2 MiB binary body streamed straight from server-owned render buffers, never through `resp_buf`/JSON (`server.zig:1338-1388`). It does not fit a JSON-RPC text result. **Excluded from v1.** Future (Phase 3+): a `read_framebuffer` tool returning an MCP **image content block** `{"type":"image","data":"<base64 PNG>","mimeType":"image/png"}`, reusing `framebuffer_get` + `encodePng` (`server.zig:1397`) then base64 (pure/deterministic).

---

## 8. Open sub-decision: inputSchema authoring

**Recommendation: (a) hand-authored static JSON Schema strings for v1; (b) comptime reflection as a Phase-3 follow-up.**
- **(a) Static strings** in `mcp_tools.zig`. Full control over descriptions/`oneOf`/`required` and awkward shapes (`search_memory` exactly-one-of, `disassemble` origin precedence, `input_key` scancode-xor-char). Sync to `wire.*Req` enforced by the round-trip equivalence test (§9).
- **(b) Comptime reflection** from `wire.*Req` (zero drift) — but `RegSetReq` is a `union(enum)` → `oneOf` (fiddly), and hex `data` fields are `[]const u8` semantically "hex string" (reflection can't know). Defer; reflect the simple structs and keep hand-authored overrides later.

---

## 9. Testing plan

New file `src/api/mcp_test.zig`, wired via `api.zig`, run by `test-api`. Reuse the in-process `serveOne` harness from `server_test.zig` (`server_test.zig:100-143`) — real machine + Controller + queue + worker thread, requests over in-memory streams, no socket. Helper `mcp(ts, json_rpc_body, out)` wraps `post(ts, "/mcp", …)` + `splitResponse`.

Cases:
- **lifecycle**: `initialize` capabilities/protocolVersion; `notifications/initialized`→HTTP 202 empty; `tools/list` length == `tools.len`, each has name/description/inputSchema.
- **tool dispatch**: `step` then `status` shows cycles increased; `read_cpu` text parses as CpuSnapshot; `read_memory` hex body; `add_breakpoint` returns id.
- **protocol errors**: garbage→-32700; unknown method→-32601; missing jsonrpc→-32600; unknown tool→-32602; bad arg type→-32602.
- **tool error vs transport error** (load-bearing): `read_memory {phys:huge}` → HTTP 200, `result.isError==true`, text contains `address_out_of_range`, no top-level JSON-RPC `error`.
- **anti-drift equivalence** (strongest): for representative tools, inner tool body text == byte-for-byte the equivalent HTTP route body (`step`↔`/api/step`, `read_cpu`↔`/api/cpu`, `read_memory`↔`/api/mem`). Proves the `writeX`/`writeResponseBody` reuse.
- **determinism reflection**: existing `expectNoPointerFields(q.Command/q.Response)` passes unchanged (MCP adds no new Command/Response). Add the two `@embedFile`s to `api_sources`.
- **repeatability**: same `tools/call` sequence twice against fresh machines → byte-identical bodies.

---

## 10. Phased rollout

- **Phase 1 — PoC plumbing.** `mcp.zig` (envelope) + `mcp_tools.zig` with **4 tools** (`step`, `read_cpu`, `read_memory`, `add_breakpoint`). Split only the `writeX` builders those need (`writeValue`, `writeMem`). `handleMcp` with `initialize`/`notifications/initialized`/`tools/list`/`tools/call`. Add `/mcp` route. Prove with `curl` + first `mcp_test.zig` cases.
- **Phase 2 — full tool surface.** Finish the `writeX`/`writeResponseBody`/`errInfo` refactor; add remaining tools; full error mapping; `load` recipe persist + `set_clock` retune; `needs_debugger` wrapping. Extract per-tool mapping so HTTP `handleX` and `buildCommand` share one copy (resolves R4). Land anti-drift equivalence tests.
- **Phase 3 — polish.** `main.zig` banner; `docs/mcp.md`; optional comptime schemas for simple structs; optional `read_framebuffer` image tool; optional real-socket black-box test.

---

## 11. Risks / open questions / structural issues

- **R1 — `writeX` refactor is a wide, mechanical edit.** ~13 helpers + `serializeResponse`. Mitigation: equivalence tests catch any changed body; do it helper-by-helper.
- **R2 — Buffer budget.** Tool body (≤32 KiB) is escaped *into* `resp_buf` (32 KiB) as a JSON string; escaping can expand it. Recommend: inner body in `mcp_body_buf` (32 KiB), envelope in `read_scratch` (64 KiB, free post-read). **Confirm.**
- **R3 — Batch requests.** v1 rejects top-level-array batches (`-32600`) to keep "one command per HTTP request". Open: do target clients send batches? If yes, Phase 3 serializes them sequentially.
- **R4 — Temporary duplicate mapping logic.** If `buildCommand` copies validation while `handleX` stays intact, two copies exist briefly (drift risk). Mitigation: extract-and-share per tool; equivalence tests pin them meanwhile.
- **R5 — `protocolVersion` negotiation.** Echo the client's version if supported, else default `"2025-06-18"`. Pure string compare. **Confirm version string.**
- **R6 — `id` types.** Echo integer/string/number_string; reject a `.float` id with `-32600` (keeps floats out of emitted bytes). **Confirm.**
- **R7 — Sessions: target Model B, defer it; fixed session ID for now.** *Resolved.* The end state is **Model B (multi-tenant single process)**: one `/mcp` endpoint, `Mcp-Session-Id` routes to one of N in-process machines, each with its own machine + queue + worker and per-session (not global) command serialization. **Not built now.** For v1: a **single machine and a fixed, constant session ID** (a literal string constant — NOT `getrandom`, so the determinism grep stays green with no carve-out). `handleMcp` resolves its `(machine, queue, run_control)` through a **session resolver seam** — today a trivial function returning the one global instance for any/blank session ID — so Model B is a later *extension* (swap the resolver for a registry; split the worker per session) rather than a rewrite.
  - *Correction vs the earlier draft:* a real (random) session ID would **not** violate ground rule 1 — it lives in the transport layer, never enters guest memory, charges no cycle, and never changes which instructions run (same category as the TCP source port / request latency). The only real-world hook of a random ID is the source-grep determinism guard, which a transport-only carve-out would satisfy. We use a fixed ID now purely because there's nothing to route yet.
  - *Model B determinism (future):* preserved — each machine is independently deterministic; the session ID only selects which one. Session lifecycle must avoid wall-clock GC: expire via explicit `DELETE /mcp` or LRU-by-request-count, never a time-based sweep.

### Determinism analysis (ground rule 1)
1. **No host clock.** `handleMcp`/`mcp.zig`/`mcp_tools.zig` do JSON string work + `queue.submit` (clockless, no timeout) + pure `writeX`. No `std.time`/`Instant`/`Timer`. Grep-enforced (§3.6).
2. **No RNG / no env.** None introduced; grep-enforced.
3. **No floats in our bytes.** We read only integer/string `std.json.Value` variants; `stringify_options` emit `u64 > 2^53` as strings. The `"f32"/"f64"` grep stays green.
4. **Session-keyed, fixed ID for now.** A single fixed/constant `Mcp-Session-Id` (no `getrandom`) resolving to the one global machine via the session-resolver seam (R7); no cross-request state beyond the machine; arena reset per request; `id` echoed verbatim. Re-running yields byte-identical output. Model B keeps this per session — independent deterministic machines selected by ID.
5. **All machine effects via the existing queue.** Same `q.Command` PODs, same `queue.submit`; never dereferences `ctrl`/`machine`. Reflection gate over Command/Response unchanged.
6. **Identical ordering & guest advance.** One connection at a time, keep-alive off; submit-gate serializes producers; run/step go through `beginDebugger`/`endDebugger` exactly like HTTP — byte-identical cycle execution.

**Residual risk:** none violating ground rule 1, provided R3 (batches rejected/serialized), R6 (no float id), and §3.6 (grep extended) are honored. The only structural tension is R7, a surfaced trade-off in service of determinism.

---

### Critical files
- `src/api/server.zig` — `/mcp` route (`:454`), `handleMcp`, `respondX`→`writeX` split (`:1421`–`:1657`), `errInfo` extraction.
- `src/api/queue.zig` — transport-neutral `Command`/`Response`/`ErrCode` PODs reused unchanged (`:62`, `:206`, `:330`).
- `src/api/json_wire.zig` — `wire.*Req`, `parse_options`, `stringify_options`, `hexDecode` reused by `buildCommand`.
- `src/api/api.zig` — register new files + `mcp_test.zig` in `test {}` (`:68`).
- `src/api/determinism_test.zig` — add `mcp.zig`/`mcp_tools.zig` to `api_sources` (`:22`).
- New files: `src/api/mcp.zig`, `src/api/mcp_tools.zig`, `src/api/mcp_test.zig`.
