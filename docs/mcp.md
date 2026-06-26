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

`/mcp` rides the existing `--serve PORT` (there is no separate flag/port):

```sh
zig-out/bin/zdos --serve 8099 examples/HELLO.COM
# [zdos] listening 127.0.0.1:8099
# [zdos] mcp endpoint: POST http://127.0.0.1:8099/mcp
```

One POST carries exactly one JSON-RPC request. The connection is closed after each
response (keep-alive off). Top-level JSON-RPC **batches (arrays) are not supported** (they
return `-32600`).

## Lifecycle

The standard MCP handshake:

| method | reply |
|---|---|
| `initialize` | `result` with `protocolVersion` (`2025-06-18`), `serverInfo {name,version}`, `capabilities {tools:{}}`. The response also carries an `Mcp-Session-Id` header (see *Sessions* below). |
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
`out_of_range`, `bad_request`, `not_implemented`, `load_failed`, `input_buffer_full`.

## Sessions

zdos is **multi-tenant**: one process runs several emulated machines concurrently (the
Model-B registry), each IN-PROCESS isolated — its own RAM/CPU/devices, its own worker
thread, its own guest cycle stream (per-machine determinism is preserved — cross-session
scheduling changes only wall-clock latency, never any guest's instruction stream). The
machines are **not** isolated on the host filesystem: they share one writable mount dir,
a caller-managed external input (host-FS isolation is the caller's responsibility).

- **Default session.** At `--serve` startup one **default machine** is booted, behind the
  fixed id `zdos-mcp-singleton`. A client that never calls `initialize`, or sends a blank
  / `zdos-mcp-singleton` `Mcp-Session-Id`, drives this one machine — the shipped
  single-machine behavior is unchanged.
- **`initialize` mints a session.** Each MCP `initialize` provisions a **fresh, in-process-
  isolated booted machine** (same program + the same shared host mount as the default) and returns its new id
  `zdos-sess-<N>` in the `Mcp-Session-Id` response header (`<N>` is a monotonic counter —
  deterministic, no clock/RNG). Subsequent requests carrying that id route to that machine.
- **`tools/call` routes by id.** A known minted id reaches its machine; a blank / singleton
  id reaches the default. An **unknown or destroyed** id returns **HTTP 404** (re-`initialize`
  to get a fresh one) — matching the MCP Streamable-HTTP convention.
- **`DELETE /mcp`** with an `Mcp-Session-Id` tears that minted session down (stops + joins
  its worker, frees its machine), races-free against in-flight requests on it. The default
  session is process-owned and cannot be deleted (404).
- **HTTP `/api/*`** drives the default session by default; an optional `X-Zdos-Session`
  header routes a `/api/*` request to a named minted session (an unknown id → 404), so the
  HTTP debugger can address the same machines MCP `initialize` mints.
- **Cap.** At most `MAX_SESSIONS` (8) minted sessions live at once (each ≈ 21 MiB, the EMS
  slab dominating). At the cap a new `initialize` is rejected rather than evicting an in-use
  session; `DELETE` a session to free a slot.

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

- **Framebuffer / images are not exposed over MCP in v1.** A frame is a 64 KiB–1.2 MiB
  binary that the HTTP `/api/framebuffer` route streams raw; it does not fit the JSON-RPC
  text/image result within the fixed response buffers. Use the HTTP framebuffer route for
  pixels.
- Every tool maps to the same worker `q.Command` the HTTP API uses; the JSON bodies are
  pinned byte-identical to the matching HTTP route by the equivalence tests.
