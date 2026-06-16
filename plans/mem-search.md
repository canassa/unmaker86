# Guest-memory search endpoint (`GET /api/mem/search`)

Status: PLAN (no code yet). Find a byte pattern / ASCII string in guest RAM, returning a
bounded list of matching physical addresses. Fills the gap left by `/api/mem`,
`/api/mem/seg`, and `/api/memory-regions` (read-only, no search) — the friction point that
forced dump-and-grep when chasing an error string in a real game.

## 1. Motivation & scope

The debugger can already READ memory (`GET /api/mem?phys&len`, `GET /api/mem/seg?seg&off&len`)
and report the region map (`GET /api/memory-regions`), but cannot SEARCH it. Locating a known
string/pattern (an error message, a magic number, a code sequence) requires dumping a range
and grepping by hand. This endpoint scans guest RAM for a needle and returns the matching
addresses.

v1 is intentionally minimal: **exact hex byte pattern** OR **ASCII string**, over the
conventional+HMA RAM slab, side-effect-free, bounded. Extensions (wildcards, case-insensitive,
per-region, alignment/stride) are noted but deferred.

## 2. References consulted

- `references/spice86/src/Spice86.Core/Emulator/Mcp/EmulatorMcpTools.cs:305` — `SearchMemory`:
  "Search conventional RAM for a hex-encoded byte pattern starting at segment:offset. Returns
  matching segmented addresses." Signature `SearchMemory(pattern, startSegment, startOffset,
  length, limit)` (`:306`); parses a hex pattern (`ParseHexPattern`), clamps the search length
  to memory size (`ComputeSearchLength`, `:313`), scans with a result cap and a `truncated`
  flag (`SearchRamMatches`, `:318`), returns matches + `Pattern`/`Length`. This is the model
  zdos adopts: hex needle, bounded start/len, result cap + truncated flag, matches as addresses.
- `references/dosbox-x/src/debug/debug.cpp:2010` — `MEMFIND`/`MEMS` commands. A *stateful*
  value-tracker (snapshot a seg:off range of B/W/D cells, then `MEMS` narrows to cells matching
  an entered value across iterations) — DOSBox's "cheat-engine" workflow, NOT a one-shot pattern
  scan. It reads each cell via `mem_readb_checked` (`:2046`) and bounds the range against
  `MEM_TotalPages()` (`:2099`). zdos does NOT replicate the stateful narrowing model; the
  one-shot needle scan (spice86 shape) is the right primitive for a REST endpoint. The stateful
  diff-search could be a later, separate feature if a use case appears.

## 3. Existing zdos anchors (file:line)

- `src/api/server.zig:561-575` — the `/api/mem` and `/api/mem/seg` route block; new route slots
  in right after.
- `src/api/server.zig:884-888` — `handleMemPeek`: query parse → build `Command` → `submitAndRespond`.
- `src/api/server.zig:926-943` — query helpers `queryValue` / `queryU32` (decimal) / `querySeg`.
- `src/api/server.zig:1134-1141` — `respondMem` + `wire.hexEncode` / `Std.Io.Writer.fixed`
  serialization pattern; `respondBpList`/`respondRegions` (`:1109`/`:1122`) show the
  `{"<key>":[...]}` array-serialization pattern via `std.json.Stringify.value`.
- `src/api/server.zig:435-436` — `/api/health` is the only off-worker route; the static-asset
  loop (`:617`) is the other cycle-neutral path. (Search does NOT use this — see §6.)
- `src/api/queue.zig:62-136` — `Command` union; `:85` `mem_peek`; `:269-291` `Response` union;
  `:182-186` `MemResult`; `:299-306` `RequestCtx` (incl. `scratch: [MAX_MEM_CHUNK]u8`); `:44`
  `MAX_MEM_CHUNK = 4096`.
- `src/api/worker.zig:83-87` — `inSlab(ctrl, start, len)` slab-containment check; `:74-79`
  `ramTotalSize(ctrl)`; `:255-261` `memPeekPhys`; `:132` dispatch table.
- `src/debug/controller.zig:636-646` — `peekMemPhys`/`peekMem` (the side-effect-free read,
  delegating to `bus.peekBlock`); `:905` `memoryRegions`; `:134-138` `Region`.
- `src/bus/bus.zig:631-682` — the SIDE-EFFECT-FREE inspection section: `peekPhys8` (`:651`),
  `peekBlock` (`:680`), `not_peekable_fill` (`:646`). Comment at `:632` states the peek path
  NEVER routes through a device READ handler.
- `src/bus/bus.zig:88-97` — the one fixed guest RAM slab `ram: []align(page_size) u8`.
- `src/bus/memmap.zig:14-46` — `ram_total_size = 0x110000` (1 MiB + HMA), `page_size`,
  conventional/UMA/ROM/HMA bounds.
- `src/api/worker_test.zig:48-55,135-151` — `drain(ctrl, cmd)` test harness + the mem
  out-of-range/over-cap test pattern to mirror.

## 4. Endpoint shape

```
GET /api/mem/search?pattern=<hex>&start=<phys>&len=<n>&max=<n>
GET /api/mem/search?ascii=<string>&start=<phys>&len=<n>&max=<n>
```

Exactly ONE of `pattern` (hex byte string) or `ascii` (text) is required; supplying both or
neither is `400 bad_request`.

| Param     | Required | Default        | Meaning |
|-----------|----------|----------------|---------|
| `pattern` | one-of   | —              | The needle as a hex byte string, e.g. `pattern=4d5a` (even-length, `[0-9a-fA-F]`). |
| `ascii`   | one-of   | —              | The needle as literal text, e.g. `ascii=Krondor`. URL-decoded (`%20` etc.) by the query parser; matched as raw bytes (CP437-agnostic — byte-exact). |
| `start`   | no       | `0`            | First physical address to scan (decimal, like `phys`/`off` today). |
| `len`     | no       | to slab end    | Number of bytes of the scan WINDOW (the haystack), from `start`. Clamped to the slab end. |
| `max`     | no       | `MAX_SEARCH_HITS` (e.g. 256) | Cap on returned matches; capped at `MAX_SEARCH_HITS`. |

Decimal ints for `start`/`len`/`max` (consistent with the existing `queryU32`); the NEEDLE is
hex (`pattern`) or text (`ascii`). Rationale: `phys`/`off`/`len` are already decimal across the
API, so addresses stay decimal; only the byte-payload needle is hex — matching `/api/mem`'s PUT
`data` field and spice86's hex pattern.

### Response (200)

```json
{
  "pattern": "4d5a",            // echo: hex of the needle actually searched (both modes)
  "needle_len": 2,
  "start": 0,
  "len": 1114112,               // the clamped haystack length actually scanned
  "count": 3,                   // number of matches RETURNED
  "truncated": false,           // true iff more matches exist beyond `max`
  "matches": [
    { "phys": 0,    "seg": 0,    "off": 0 },
    { "phys": 1234, "seg": 0x77, "off": 0x44 },
    ...
  ]
}
```

- `matches[].phys` is the absolute physical address of the match start.
- `seg`/`off` are a convenience real-mode decomposition: `seg = phys >> 4`, `off = phys & 0xF`
  (the canonical normalized form; the consumer can re-segment as needed). Cheap, pure, no CPU
  state read. Include them so a hit is directly usable with `/api/mem/seg`. (Decision: include;
  trivial to compute, removes a round-trip. Drop only if it bloats the payload — it doesn't.)
- `truncated` mirrors spice86's flag so the caller knows the result set was capped.
- v1 returns addresses only (no inline context dump). A caller follows up with `/api/mem` for
  surrounding bytes. (Extension §9: optional `&context=<n>` to inline a short hex dump per hit.)

### Error cases (all `400 bad_request` unless noted)

- Both `pattern` and `ascii`, or neither → `bad_request` ("specify exactly one of pattern/ascii").
- Odd-length or non-hex `pattern` → `bad_request` ("invalid hex in pattern").
- Empty needle (`pattern=` / `ascii=`) → `bad_request` ("empty search pattern").
- Needle longer than `MAX_SEARCH_NEEDLE` (e.g. 256 bytes) → `out_of_range`.
- `start` ≥ slab size → `address_out_of_range` (reuse the existing code; `:1228`).
- `start + len` overflow / `len` beyond slab → clamp `len` to the slab end (NOT an error;
  matches spice86's `ComputeSearchLength` clamp). If clamped window is empty (needle > window)
  → return `count:0, truncated:false`.

## 5. Search semantics

- **v1 match:** exact, case-SENSITIVE byte-for-byte (`std.mem.indexOfPos` over the slab slice;
  see §7). ASCII mode = the literal bytes of the string; hex mode = the decoded bytes. Identical
  scan once decoded to a `[]const u8` needle.
- **Overlapping matches:** report ALL start positions, including overlapping ones (e.g. needle
  `aa` in `aaaa` → matches at offsets 0,1,2). Advance the scan cursor by 1 after each hit, not
  by `needle_len`. (Deterministic, and what a debugger wants — every occurrence.)
- **Ascending order:** matches are returned in ascending `phys` order (the scan is a forward
  linear walk; the result array is naturally sorted — no container-iteration-order dependence,
  CLAUDE #5).
- **Deferred (note as extensions, do NOT build in v1):** wildcard byte `??` in the hex pattern
  (skip that byte position in the compare), case-insensitive ASCII (`&ci=1`), alignment/stride,
  word/dword value search (the DOSBox B/W/D modes), per-region scoping (`&region=ram|vram`).

## 6. Search domain & the purity boundary (load-bearing)

- **Domain = the conventional+HMA RAM slab only** (`[0, ram_total_size)` = `[0, 0x110000)`),
  bounded further by `start`/`len`. This is the `.ram`-kind region from the region table
  (`controller.zig:914`, `kind=.ram, len=ram_total_size`).
- **Search the RAM slab via the side-effect-free PEEK path** — NEVER through `read8`/`in8`/device
  read handlers. Reading a device window (VGA VRAM, a PIT latch, an EMS-mapped frame page)
  through the live read path can MUTATE device state (the bus comment at `bus.zig:632` is
  explicit: "NEVER routes through a device READ handler — those mutate device state, e.g. the
  PIT latch phase"). A search MUST leave `machine.snapshot()` byte-identical (determinism prime
  directive, CLAUDE #5/#6).
- v1 deliberately does NOT search MMIO/VRAM/EMS windows. The conventional+HMA slab is where
  guest data/strings live; VRAM/MMIO are device windows. If a later version wants to search VRAM,
  it MUST go through the peek path (`peekPhys8`, which reads VRAM via the backing host pointer
  side-effect-free) and be a per-region opt-in — stated here so no one wires `read8` in by
  reflex.
- **Implementation reads the slab DIRECTLY as a slice** for the scan (see §7) — this is sound
  because the `.ram` slab is pure backing store with NO device side effects on read (it IS what
  `peekPhys8` returns for `.ram` pages: `bus.zig:660`, `return self.ram[m]`). A direct
  `[]const u8` scan over `bus.ram[start..start+len]` is equivalent to a `peekBlock`-per-byte loop
  but allows `std.mem.indexOfPos` (a fast `memchr`-backed scan) and avoids a 1 MiB temp copy.
  The plan calls this out explicitly so it is a DELIBERATE, justified choice, not a shortcut.
  - Caveat to handle: **A20 masking.** `peekPhys8` applies the A20 mask per byte. The direct-slab
    scan addresses the slab linearly (no A20 fold). For the conventional+HMA slab this is the
    correct guest-physical view (the slab IS physical RAM; A20 only matters for the >1 MiB wrap
    aliasing into HMA, which is an addressing artifact, not distinct storage). Reporting `phys`
    as the slab offset is the honest physical address. Document this; do NOT silently A20-fold
    reported addresses.

## 7. Determinism, purity & cost

- **Pure read, zero cycle charge, zero mutation.** No `step()`, no device read, no CPU/flag
  read needed (the `seg`/`off` decomposition is pure arithmetic on `phys`, not a CPU-state read).
- **Off-worker vs on-worker:** the scan reads `bus.ram`, which the worker owns. Reading it from
  the listener thread would be a data race against a concurrent run (CLAUDE #4 — only `/api/health`
  is off-worker, and it reads ZERO machine state). Therefore the search runs **ON the worker** via
  the normal `Command`/`Response` path, exactly like `mem_peek`. It is cycle-neutral (charges no
  cycles) but still serialized through the queue so it never races the emulation. State this:
  on-worker, cycle-neutral, single-command-in-flight by construction.
- **Bounded cost:** worst case a `memchr`-style scan of ~1.06 MiB (`ram_total_size`). That's a
  sub-millisecond `std.mem.indexOfPos` scan — fine to run on the worker between commands. No
  per-op allocation: the needle decodes into the existing `RequestCtx.scratch` (≤ `MAX_MEM_CHUNK`)
  and matches accumulate into a fixed `SearchResult.hits` array (no heap). Result count capped by
  `max`/`MAX_SEARCH_HITS`; the scan SHORT-CIRCUITS once `max` hits are found (record
  `truncated=true` if a further match exists — do one extra `indexOfPos` past the cap to set the
  flag honestly, or set it when the cap is hit and another `indexOfPos` succeeds).
- **No undefined state:** `hits` is filled only up to `count`; serialization reads `hits[0..count]`.

## 8. Placement & data structures

Mirror the existing `mem_peek` plumbing end-to-end (no new module needed):

1. **`src/api/queue.zig`**
   - Add `Command.mem_search: MemSearchCmd` where
     `MemSearchCmd = struct { start: u32, len: u32, needle_len: u16, max: u16 }`.
     The needle BYTES live in `RequestCtx.scratch[0..needle_len]` (decoded by the handler before
     submit — the SAME pattern as `mem_write`, which carries only a length and puts bytes in
     `scratch`). Keep `MemSearchCmd` pointer-free POD.
   - Add `MAX_SEARCH_HITS` (e.g. 256) and `MAX_SEARCH_NEEDLE` (≤ `MAX_MEM_CHUNK`).
   - Add `SearchResult = struct { start: u32, len: u32, needle_len: u16, count: u16, truncated: bool, hits: [MAX_SEARCH_HITS]u32 = undefined }` (a `u32` phys per hit; `seg`/`off` derived at serialize time).
   - Add `Response.search: SearchResult`.

2. **`src/api/worker.zig`**
   - Dispatch `.mem_search => |c| memSearch(ctrl, ctx, c)` in `drainOne` (`:132` block).
   - `fn memSearch(ctrl, ctx, c) Response`: validate `c.needle_len != 0`
     (`out_of_range`/`bad_request` as appropriate), `inSlab(ctrl, c.start, 0)` /
     `c.start < ramTotalSize` else `address_out_of_range`; clamp `c.len` to
     `ramTotalSize - c.start`; obtain the slab slice via a NEW pure controller accessor (below),
     run `std.mem.indexOfPos`-based scan over `slab[start..start+clamped_len]`, fill `hits`,
     cap at `min(c.max, MAX_SEARCH_HITS)`, set `truncated`. Return `.{ .search = res }`.

3. **`src/debug/controller.zig`**
   - Add a side-effect-free accessor that exposes the RAM slab for the linear scan, e.g.
     `pub fn ramSlab(self: *const Controller) []const u8 { return self.m.bus.ram; }` — or, to keep
     the bus the single authority, add `pub fn searchRam(self: *const Controller, start, len, needle, hits) struct{count,truncated}` on the BUS (`src/bus/bus.zig`, in the side-effect-free
     section) and have the controller delegate. **Preferred:** put the scan on the BUS
     (`bus.zig` §"side-effect-free inspection") next to `peekBlock`, because the slab is a bus
     concern and the bus owns the A20/slab invariants; the controller just forwards. This keeps
     the raw `[]u8 ram` slice from leaking up through the debug layer.
   - Bus method sketch: `pub fn searchRam(self: *const Bus, start: u32, len: u32, needle: []const u8, hits: []u32) struct { count: u16, truncated: bool }` — scans `self.ram[start..][0..len]`
     with `std.mem.indexOfPos`, returns positions as absolute phys (`start + idx`), respects
     `hits.len` as the cap. Pure `*const Bus`.

4. **`src/api/server.zig`**
   - Route: in the `--- memory ---` block (`:561`), add
     `if (std.mem.eql(u8, path, "/api/mem/search")) { GET → handleMemSearch; else 405; }`.
     Place it BEFORE the `/api/mem` exact-`eql` check is irrelevant (these are exact matches, not
     prefixes), but group it with the other mem routes.
   - `fn handleMemSearch(self, req, query)`:
     - parse `start` (default 0) / `len` (default 0 → "to end", resolved on worker) / `max`
       (default 0 → `MAX_SEARCH_HITS`) via `queryU32`.
     - read `pattern` and `ascii` via `queryValue`; enforce exactly-one.
     - **URL-decode** the `ascii` value (the query parser currently does raw `=`/`&` splitting,
       no percent-decoding — verify and ADD a small percent-decoder, or document that `ascii`
       must be pre-encoded without `&`/`=`/`%`; PREFER adding percent-decode so spaces work).
       For `pattern`, `wire.hexDecode` into `ctx.scratch` (same as `handleMemWrite`, `:894`).
     - build `RequestCtx` with `cmd = .{ .mem_search = .{...} }` and the needle in `scratch`;
       `submitCtxAndRespond`.
   - `fn respondSearch(self, req, sr)`: serialize `{"pattern","needle_len","start","len","count",
     "truncated","matches":[{"phys","seg","off"},...]}` using the `Std.Io.Writer.fixed` +
     manual-loop pattern from `respondMem`/`respondBpList`. Echo `pattern` as the lowercase hex of
     the searched needle (re-encode `scratch[0..needle_len]` — but `scratch` is the listener's;
     simplest: carry `needle` hex echo by re-encoding from the RESULT is impossible since the
     result has no bytes → DECISION: serialize `pattern` from the listener-side decoded needle
     held in `ctx.scratch` BEFORE submit is wrong (worker may overwrite). Cleanest: the listener
     still owns `ctx` after the worker completes (`submitCtxAndRespond` blocks until done and the
     listener owns `ctx`), so `ctx.scratch[0..needle_len]` is intact for the echo. Use that.).
   - Wire `.search => |sr| self.respondSearch(req, sr)` into `serializeResponse` (`:1076`).

## 9. Extensions (explicitly deferred, documented for the next iteration)

- Wildcard byte `??` in hex patterns (mask-aware compare; `indexOfPos` no longer applies —
  needs a custom scan).
- Case-insensitive ASCII (`&ci=1`).
- Inline context dump per hit (`&context=<n>` → short hex window around each match).
- Word/dword typed value search (the DOSBox B/W/D modes) and the stateful narrowing
  (`MEMFIND`/`MEMS`) workflow as a separate stateful endpoint.
- Per-region scoping (`&region=ram|vram|...`) — VRAM/EMS via the peek path, opt-in only.
- Reverse search / "next match after phys" cursor for large result sets.

## 10. Tests

Mirror `worker_test.zig` (the `drain(ctrl, cmd)` harness) and `server_test.zig` /
`server_integration_test.zig`. Lay a KNOWN pattern into guest RAM via the controller's
`writeMemPhys` (`controller.zig:504`), then search and assert.

- [ ] **Hex pattern, single match.** Write `DE AD BE EF` at a known phys; search `pattern=deadbeef`;
      assert `count==1`, `matches[0].phys` == that address, `truncated==false`.
- [ ] **ASCII match.** Write `"Krondor"` bytes; search `ascii=Krondor`; assert the phys and the
      `seg`/`off` decomposition (`seg=phys>>4, off=phys&0xF`).
- [ ] **Multiple + ascending order.** Write the needle at three ascending addresses; assert
      `count==3` and `matches` is strictly ascending by `phys`.
- [ ] **Overlapping matches.** Write `aa aa aa aa`; search `pattern=aaaa`; assert matches at
      offsets 0,1,2 (overlap reported).
- [ ] **No match.** Search a needle absent from a zeroed region; assert `count==0`,
      `truncated==false`, empty `matches`.
- [ ] **Bounded results / truncated flag.** Fill many copies of the needle, set `max=2`; assert
      `count==2`, `truncated==true`.
- [ ] **`start`/`len` window.** Place a match outside `[start, start+len)`; assert it is NOT
      found; place one inside; assert it IS.
- [ ] **`len` clamp.** `start` near slab end with a huge `len`; assert no overflow/OOB and the
      scan clamps to the slab end (no error).
- [ ] **Error: both/neither needle.** `pattern=..&ascii=..` and (no needle) → `bad_request`.
- [ ] **Error: bad hex / empty needle / oversize needle.** Odd-length hex, `pattern=` → 400;
      needle > `MAX_SEARCH_NEEDLE` → `out_of_range`.
- [ ] **Error: `start` past slab.** `start >= ramTotalSize` → `address_out_of_range`.
- [ ] **Purity / determinism.** Snapshot `machine` state, run a search, re-snapshot; assert
      byte-identical (the search mutates nothing, charges no cycles — assert `cpu.st.cycles`
      unchanged). This is the load-bearing test.
- [ ] **Integration (`server_integration_test.zig`).** Real `GET /api/mem/search?...` over the
      HTTP path; assert the JSON body (count, first match phys, truncated). Cover one hex and one
      `ascii` (with a `%20` space) request to exercise the percent-decode.
- [ ] **Queue-drive == direct-call (worker_test #1 idiom).** Drive `mem_search` via `drainOne`
      and assert the result matches a direct bus `searchRam` call (byte-identical hits).

## 11. Build / verification

- [ ] `zig build` compiles clean.
- [ ] `zig build test` passes (new tests wired into the existing api/worker/bus test steps).
- [ ] `zig fmt --check src/` clean.
- [ ] Update `plans/ROADMAP.md` with the endpoint once landed (source-of-truth convention).

## 12. Task checklist (implementation order)

- [ ] `queue.zig`: add `MemSearchCmd`, `Command.mem_search`, `SearchResult`, `Response.search`,
      `MAX_SEARCH_HITS`, `MAX_SEARCH_NEEDLE`.
- [ ] `bus.zig`: add `searchRam` in the side-effect-free inspection section (pure `*const Bus`,
      `std.mem.indexOfPos`, overlapping, capped, `truncated`).
- [ ] `controller.zig`: add the thin delegating accessor (`searchRam`) to keep the raw slab from
      leaking through `debug`.
- [ ] `worker.zig`: add `memSearch` + dispatch entry; validate/clamp/bound.
- [ ] `server.zig`: add the `/api/mem/search` route, `handleMemSearch` (query parse, one-of
      enforcement, hex/ascii decode, percent-decode for `ascii`), `respondSearch`, and the
      `serializeResponse` arm.
- [ ] server query helper: add a percent-decoder (or confirm one exists) for the `ascii` value.
- [ ] Tests: all of §10.
- [ ] §11 build/fmt/roadmap.
