# zdos MCP (Model Context Protocol) API

zdos exposes a **JSON-RPC 2.0 / MCP** endpoint as a *second front-end* over the same
transport-independent worker core that backs the HTTP/JSON debugger API. An MCP client
drives the emulator with the SAME commands the HTTP routes use, and a tool result carries
**byte-for-byte the same body** the equivalent HTTP route emits (the two front-ends share
one serializer — see the anti-drift equivalence tests in `src/api/mcp_test.zig`).

The endpoint is **deterministic**: it does pure JSON work plus `queue.submit` (clockless);
no host clock, no RNG, no float ever reaches guest state or the emitted bytes. Re-running
the same `tools/call` sequence against a fresh machine yields byte-identical output.

## Endpoint

```
POST http://127.0.0.1:<PORT>/mcp
Content-Type: application/json
```

`/mcp` rides the existing `--serve PORT` (there is no separate flag/port). The **program is
optional**: with it, the default machine is booted; without it, the server starts **empty** and
an agent provisions machines on demand.

```sh
# default machine (back-compat):
zig-out/bin/zdos --serve 8099 examples/HELLO.COM
# [zdos] listening 127.0.0.1:8099
# [zdos] mcp endpoint: POST http://127.0.0.1:8099/mcp

# empty start (provision_machine to begin):
zig-out/bin/zdos --serve 8099
# [zdos] listening 127.0.0.1:8099
# [zdos] mcp endpoint: POST http://127.0.0.1:8099/mcp (empty start — provision_machine to begin)
```

One POST carries exactly one JSON-RPC request. The connection is closed after each
response (keep-alive off). Top-level JSON-RPC **batches (arrays) are not supported** (they
return `-32600`).

## Lifecycle

The standard MCP handshake:

| method | reply |
|---|---|
| `initialize` | a **pure handshake**: `result` with `protocolVersion` (`2025-06-18`), `serverInfo {name,version}`, `capabilities {tools:{}}`. MCP is **stateless** — `initialize` mints **nothing** and issues **no** `Mcp-Session-Id` header. Create a machine with the `provision_machine` tool (see *Machines* below); drive it with the `machine` tool argument. |
| `notifications/initialized` (any `notifications/*`) | a notification has no `id` → **HTTP 202, empty body** (fire-and-forget). |
| `tools/list` | `result {tools:[{name, description, inputSchema}, ...]}` — the full catalog below. |
| `tools/call` | run one tool → a tool `result` (or, for a protocol failure, a JSON-RPC `error`). |

`initialize` example:

```sh
curl -s http://127.0.0.1:8099/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18",
#   "serverInfo":{"name":"zdos","version":"0.1.0"},"capabilities":{"tools":{}}}}
```

### `id` echo

The request `id` is echoed verbatim: an **integer** → JSON number; a **string** → JSON
string; a JSON **number-string** (an integer too large for `i64`) → verbatim digits. A
**float or boolean** `id` is rejected with `-32600` (this also keeps non-integers out of
the emitted bytes). An absent `id` marks a notification (no response).

## Calling a tool

```sh
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"step","arguments":{}}}'
```

A successful call returns a tool `result` whose single text content block holds the inner
body (itself JSON, embedded as an escaped string — exactly the bytes `/api/step` returns):

```json
{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"stop\":{...}}"}],"isError":false}}
```

The one exception is [`screenshot`](#inspection), whose result is an **image** content
block (`{"type":"image","data":"<base64 PNG>","mimeType":"image/png"}`) — image-capable
clients render it inline. The PNG is base64-encoded and streamed straight to the socket
with an exact `Content-Length`, so the response never buffers the (up to ~1.6 MiB) image.

## Tool catalog

`arguments` is a JSON object; omit it (or pass `{}`) for the no-argument tools.

Every **per-machine** tool (everything except the three machine-lifecycle tools below) takes an
optional `"machine":"<handle>"` argument selecting which machine to drive. Omit it to drive the
**default** machine (when one exists, i.e. `--serve PORT PROGRAM`); in empty-start mode (`--serve
PORT`) a per-machine call with no `machine` returns the `no_machine` tool error — `provision_machine`
first. See *Machines* below.

### Machine lifecycle (machine-agnostic — no `machine` arg)
| tool | arguments | does |
|---|---|---|
| `provision_machine` | `{mount_dir, file, cmdtail?, drive?=2, cpu?:{mult\|mhz}}` | open `mount_dir` as a DOS drive, boot `file`, and create a fresh in-process-isolated machine + worker. Returns `{machine, drive, mult, live_machines, max_machines}` — `machine` is the `zdos-sess-<N>` **handle** you thread into later calls. Errors: a missing file / bad dir / bad cpu → `-32602`; at the cap → the `machine_limit_reached` tool error; OOM / unrunnable image → `-32603`. |
| `deprovision` | `{machine}` | destroy that machine (stop + join its worker, free its ~21 MiB + close its owned mount fd). Returns `{machine, deleted, live_machines}`. An unknown handle → the `unknown_machine` tool error. |
| `list_machines` | `{}` | read-only: `{machines:[{machine,file,drive,mult,cycles}], live_machines, max_machines}` — recover/reclaim after a lost handle. Exposes handles/metadata only, never another machine's guest memory. |

### Execution control
| tool | arguments | does |
|---|---|---|
| `step` | `{}` | execute exactly one instruction; returns the StopReason. |
| `step_n` | `{n}` | execute `n` instructions (or until a stop event). |
| `step_over` | `{}` | step one instruction, running a CALL/INT/REP to completion (`stepped_into=false` when it was run over). |
| `run` | `{cycle_cap?}` | run until a breakpoint/stop event or the cap (defaults to a large bound; never unbounded). |
| `run_to_cycle` | `{cycle}` | run until the absolute machine cycle reaches `cycle`. |
| `run_to_address` | `{linear}` | run until CS:EIP reaches the linear (physical) address. |

### Breakpoints
| tool | arguments | does |
|---|---|---|
| `add_breakpoint` | `{kind, one_shot?}` | add a breakpoint; `kind` is the discriminated union, e.g. `{"execution_address":{"linear":N}}` or `{"cycle":{"at_cycle":N}}`. Returns the new `id`. |
| `remove_breakpoint` | `{id}` | remove the breakpoint with that id. |
| `list_breakpoints` | `{}` | list all breakpoints. |
| `clear_breakpoints` | `{}` | remove all; returns the count removed. |

### CPU / registers
| tool | arguments | does |
|---|---|---|
| `read_cpu` | `{}` | full CPU snapshot (registers, segments, flags, EIP, cycles). |
| `set_register` | one of `{reg32\|reg16\|reg8\|seg:{name,value}}`, `{eip:{value}}`, `{flags:{cf,zf,...}}` | set a register/segment/flags. Values are range-checked to the target width. |

### Memory
| tool | arguments | does |
|---|---|---|
| `read_memory` | `{phys, len}` | read `len` physical bytes at `phys`; returns lowercase hex. |
| `write_memory` | `{phys, data}` | write hex-encoded `data` at `phys`. |
| `read_memory_seg` | `{seg, off, len}` | read at a real-mode `seg:off` (`seg` = a segment-register name: `cs`/`ds`/`es`/`ss`/`fs`/`gs`). |
| `write_memory_seg` | `{seg, off, data}` | write hex `data` at `seg:off`. |
| `search_memory` | exactly one of `{pattern}` (hex) / `{ascii}` (literal text), plus `{start?, len?, max?}` | find a byte needle in guest RAM. `len=0` → to slab end; `max=0` → default hit cap. |
| `disassemble` | `{linear? \| seg?,off? \| (none)} {count?}` | disassemble a window. Origin precedence: `linear`, else `seg`(+`off`), else the live CS:EIP. `count` defaults to 16 (1..64). |

### Inspection
| tool | arguments | does |
|---|---|---|
| `read_screen` | `{attrs?}` | active VGA text page (char grid + cursor/mode); `attrs=true` also returns the per-cell attribute bytes as hex. |
| `screenshot` | `{}` | capture the current video frame as a PNG, returned as an **image** content block (`mimeType: image/png`, `data` = base64 PNG). Re-renders the live VGA mode deterministically (same machine state ⇒ byte-identical PNG). A video mode with no faithful rasterizer returns an `isError` `not_implemented` result rather than a fabricated frame. |
| `read_devices` | `{palette?, device?}` | grouped chipset/A20/device snapshot. `palette=true` widens the VGA DAC palette; `device` selects one group (`a20`/`pic`/`pit`/`vga`/`kbc`/`speaker`/`opl`/`ems`). |
| `read_stack` | `{count}` | read `count` 16-bit words from SS:SP. |
| `read_ivt` | `{vector}` | read one real-mode interrupt vector (0..255): its segment:offset. |
| `read_console` | `{}` | the guest's accumulated CON output as hex (side-effect-free — no clear-on-read). |
| `read_io_port` | `{port}` | the non-mutating shadow of one I/O port (never a live, stateful IN). |

### Input injection (scripted / deterministic)
| tool | arguments | does |
|---|---|---|
| `input_key` | exactly one of `{scancode, make?, ext?}` / `{char}` | inject a key. `char` is a single ASCII char resolved over the real set-1 table. |
| `input_mouse` | `{x?, y?, dx?, dy?, buttons?}` | inject a scripted mouse event. Absolute (`x`/`y`) vs relative (`dx`/`dy`) are mutually exclusive per axis; at least one field is required. (The live coalesced browser-cursor path is HTTP-only.) |

### Clock / lifecycle
| tool | arguments | does |
|---|---|---|
| `get_clock` | `{}` | the active CPU:PIT multiplier and the derived cpu_hz / MHz / pacer slice. |
| `set_clock` | exactly one of `{mult}` / `{mhz}` | set the CPU speed. `mhz` is converted to the nearest integer mult; the worker clamps to `[1, max_mult]`, and the pacer slice is retuned from the applied mult. |
| `reset` | `{}` | reset the machine to its post-boot state (re-load a program with `load`). |
| `load` | `{drive?, file?, cmdtail?}` | overlay the given fields onto the server-held load recipe, persist it, then (re)load. |
| `status` | `{}` | run status: `runnable`, `terminated`, `ret_code`, `cycles`, `last_stop`. |

## Error model

Two distinct failure channels (the dividing line: *validation before submit* vs
*emulator-domain failure after submit*):

### Protocol errors → a JSON-RPC `error` envelope (HTTP 200)
The request could not be dispatched. The reply is `{"jsonrpc":"2.0","id":...,"error":{"code":N,"message":...}}`.

| condition | code |
|---|---|
| body is not valid JSON | `-32700` |
| missing/invalid `jsonrpc:"2.0"`, missing `method`, a top-level array batch, a float/bool `id` | `-32600` |
| unknown `method` | `-32601` |
| `tools/call` with an unknown tool, or `arguments` that fail to parse/validate (wrong type, out-of-range value, mutually-exclusive fields, unknown enum name) | `-32602` |
| writer overflow / internal | `-32603` |

A `-32602` means **fix the call** (the schema/range/enum was wrong).

```json
{"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"unknown tool: nope"}}
```

### Tool errors → a `result` with `isError:true` (HTTP 200)
The tool **ran**, but the emulator returned a domain error. This is *not* a transport
error — it is a normal `result` whose content text is `{"error":{"code":...,"message":...}}`
and whose `isError` is `true`. A tool error means **fix the plan** (e.g. the address was
out of range), not the call.

```json
{"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"{\"error\":{\"code\":\"address_out_of_range\",\"message\":\"...\"}}"}],"isError":true}}
```

Tool error codes: `breakpoint_table_full`, `no_such_breakpoint`, `address_out_of_range`,
`out_of_range`, `bad_request`, `not_implemented`, `load_failed`, `input_buffer_full`,
`machine_limit_reached` (at the machine cap — deprovision one or `list_machines`),
`unknown_machine` (deprovision/route of an unknown/already-gone handle), `no_machine`
(a per-machine call with no `machine` and no default — `provision_machine` first).

## Machines

zdos is **multi-tenant**: one process runs several emulated machines concurrently (the
registry), each IN-PROCESS isolated — its own RAM/CPU/devices, its own worker thread, its
own guest cycle stream (per-machine determinism is preserved — cross-machine scheduling
changes only wall-clock latency, never any guest's instruction stream). **MCP is stateless:**
there is **no** `Mcp-Session-Id` and `initialize` is a pure handshake — the model selects a
machine by the `machine` tool **argument** (the LLM cannot set HTTP headers, so routing cannot
live in one).

**Two start modes.**

- **`--serve PORT PROGRAM` (default machine).** One **default machine** is booted at startup
  (internal handle `zdos-mcp-singleton`). A per-machine `tools/call` with **no** `machine` arg
  drives it — the shipped single-machine behavior, unchanged.
- **`--serve PORT` (empty start).** **No** default machine. A per-machine `tools/call` with no
  `machine` arg returns the `no_machine` tool error; `provision_machine` first. `/api/health`
  still answers (off-worker); any other blank `/api/*` request returns **409** until a machine
  exists.

**Provisioning.**

- **`provision_machine`** boots a machine and returns its `zdos-sess-<N>` **handle** in the tool
  *result* (`<N>` is a monotonic counter — deterministic, no clock/RNG). Thread that handle into
  later calls as `"machine":"zdos-sess-<N>"`.
- **`deprovision {machine}`** (or **`DELETE /mcp`** with the handle as the `Mcp-Session-Id`
  header — an HTTP alias) tears a machine down (stops + joins its worker, frees its ~21 MiB,
  closes its owned mount fd), race-free against in-flight requests. A per-machine call on a
  destroyed handle → the `unknown_machine` tool error. The default machine is process-owned and
  cannot be deprovisioned.
- **`list_machines`** recovers a lost handle (read-only handles/metadata).
- **Cap.** At most `MAX_SESSIONS` (8) machines live at once (each ≈ 21 MiB, the EMS slab
  dominating). At the cap, `provision_machine` returns `machine_limit_reached` rather than
  evicting an in-use machine — `deprovision` (or `list_machines`) to reclaim. There is **no**
  time/LRU eviction (it would inject host scheduling into which machine survives).

**HTTP `/api/*`.** HTTP clients *do* control headers, so the HTTP surface keeps the optional
`X-Zdos-Session` header: absent → the default machine (back-compat); a provisioned handle → that
machine; an unknown handle → 404. (Only the MCP/LLM path needs arg-based routing.)

### Determinism caveat — the mount dir

A provisioned machine's guest state at cycle N equals the same program launched via `--serve
PORT PROGRAM` (the missing pacer affects only host pacing cadence, never the cycle trajectory).
**But the mount dir is an input, not zdos state:** the guest *writes* to it mid-run (INT 21h), so
its bytes are an output the first run mutates — cycle-reproducibility holds only for a mount that
is **byte-stable** for the whole run (restoring it to its pre-run bytes is an external
responsibility). And per-machine reproducibility holds only for a **non-shared-writable** mount:
two machines pointed at one writable dir interleave their INT 21h reads/writes under the host
scheduler, voiding reproducibility for both. Distinct per-machine mount dirs (the natural
provisioning) are isolated and reproducible.

## Examples

```sh
# step once
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
 '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"step","arguments":{}}}'

# write then read 4 bytes back (round-trip)
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_memory","arguments":{"phys":8192,"data":"cafebabe"}}}'
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_memory","arguments":{"phys":8192,"len":4}}}'

# disassemble 5 instructions at the current CS:EIP
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"disassemble","arguments":{"count":5}}}'

# set the CPU speed multiplier
curl -s http://127.0.0.1:8099/mcp -H 'content-type: application/json' -d \
 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"set_clock","arguments":{"mult":12}}}'
```

## Notes

- **Images:** the `screenshot` tool exposes the rendered frame as an MCP image content
  block (a base64 PNG, streamed with an exact `Content-Length` so it never buffers). The
  **raw** framebuffer (index/rgba binary, 64 KiB–1.2 MiB) is not exposed over MCP — it does
  not fit a JSON-RPC result; use the HTTP `/api/framebuffer` route for raw pixels.
- Every tool maps to the same worker `q.Command` the HTTP API uses; the JSON bodies are
  pinned byte-identical to the matching HTTP route by the equivalence tests.
