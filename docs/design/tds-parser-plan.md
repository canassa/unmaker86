# Borland TDS Debug-Info Parser + Host-Side Symbol Indices — Implementation Plan

**Status:** plan (no code). Zig 0.16, for the zdos / "unmaker" deterministic DOS emulator.

This plan specifies a **host-side, load-time TDS parser** (Borland C++ 3.1 / TLINK 5.1,
16-bit TDS 3.10, `0x52FB`) and the **read-only symbol indices** it builds. The indices are
consumed by the protocol-neutral debug core (`docs/design/debug-core-architecture.md`, the
"symbol layer"). They are **never** part of the deterministic machine state and **never** enter
`Machine.Snapshot`.

It builds directly on:
- `docs/research/borland-bcc3-debug-format.md` — **§0 "Empirical Confirmation" is authoritative**.
- `docs/research/bcc3-fixtures/` — `TEST.C` / `TEST.EXE` (real BC++3.1 build), `tdinfo_structs.py`
  (the validated `construct` schema), `decode.py` / `decode-output.txt` (the ground-truth oracle).
- `docs/design/debug-core-architecture.md` — the consumer (§3 boundaries, §7 stepping, §8 mapping).

> **Prime directive (CLAUDE.md §1): determinism.** The parser is a **pure function of the EXE
> bytes**. It does no host I/O of its own, reads no host clock/RNG/env, allocates only host-side
> memory tied to the loaded program, and produces byte-identical indices for identical input. It
> is re-attached on load exactly like `LoadRecipe`, never serialized.

---

## Table of Contents

0. [Byte-verification log + corrections to the research doc](#0-byte-verification-log--corrections-to-the-research-doc)
1. [A. Scope & boundary](#1-a-scope--boundary)
2. [B. Module layout & public API](#2-b-module-layout--public-api)
3. [C. Parse pipeline (step by step)](#3-c-parse-pipeline-step-by-step)
4. [D. Data model & derived indices](#4-d-data-model--derived-indices)
5. [E. Memory management & lifetime](#5-e-memory-management--lifetime)
6. [F. Error handling & degradation (+ `.map` fallback)](#6-f-error-handling--degradation--map-fallback)
7. [G. Tier phasing → milestones](#7-g-tier-phasing--milestones)
8. [H. Testing (TEST.EXE as golden fixture)](#8-h-testing-testexe-as-golden-fixture)
9. [I. Open questions & risks](#9-i-open-questions--risks)
10. [Appendix: codebase anchors](#10-appendix-codebase-anchors)

---

## 0. Authoritative byte layout → `borland-tds-format-complete.md`

⚠️ **The byte-level format is now FULLY mapped and authoritative in
`docs/research/borland-tds-format-complete.md`** (every structure confirmed against the BOA *and*
12 real BC++3.1 fixtures; its **§16 Zig definitions compile under Zig 0.16 with all `comptime`
size asserts passing**). **Use that document — and copy its §16 `packed struct`/`enum` definitions
verbatim — as the single source of truth for every offset/width.** This section only summarizes;
where any older prose (research-doc §0, an earlier draft of this plan, or `tdinfo_structs.py`'s
original) disagrees, the complete spec wins.

**Corrected record sizes (the values this plan now uses):**

| Record | Size | Note |
|---|---|---|
| header | `0x30` base + `extension_size` | `0x50`=80 for the fixture (`ext=0x20`); symbols start at base+header |
| symbol | 9 | `{name(2), type(2), offset(2), segment(2), flags(1: class:3/has_BP:1/ret_words:4)}` |
| **module** | **16** | NOT 20 — an earlier draft of this plan and the research doc both got this wrong (the *same* arithmetic-coincidence trap). Confirmed 16 by the multi-module fixtures (`RICH`/`CLS`/`MI`) + the BOA `module_header`. Fields: `{name, language, model+underbars, symbols_index, symbols_count, source_files_index/count, correlation_index/count}` |
| source-file | 6 | `{name(2), dos_timestamp(4)}` |
| line | 4 | `{line(2), code_offset(2)}` (line first), offset rel. to the module's code-base segment |
| scope | 12 | `{autos_index, autos_count, parent, function_symbol, offset, length}` (BOA names) |
| segment | 16 | `{mod_index, code_seg, code_off, code_len, scopes_index, scopes_count, correlation_index, correlation_count}` |
| correlation | 8 | bound to a source file + segment |
| type | 8 | `{id(1), name(2), size(2), class(1), member_type(2)}` |
| member | 5 | `{info(1: bit_field_size:6/offset_rec:1/end:1), name(2), type(2)}` (BOA `member_type`) |

**Two corrections vs earlier drafts of THIS plan** (both were arithmetic coincidences — the lesson
is *decode to clean data, never trust EOF gap-arithmetic alone*):
1. **module = 16, not 20.** With module=16 the line block starts one entry **earlier** than the
   old draft computed — at `{line 4, code_offset 706}` (the function-declaration line). The
   `(78,2)` "anomalous trailing entry" the old draft worried about was a **phantom** caused by
   reading one entry too far under the wrong module size; with module=16 the 10 line entries are
   all clean and in `TEST.C`'s range. (Risk R5 is therefore closed.)
2. The post-records "~14-byte gap before the name pool" is **not** unaccounted — it is the
   **include-files + coverage / module-opt trailing tables** (counts in the extended header). The
   complete spec maps them.

**`load_para` re-derivation (machine-side):** zdos's loader sets `dos.current_psp = psp_seg` and
`load_seg = psp_seg + 16` (`src/dos/loader.zig:195,206`), so the runtime image-base paragraph is
`psp_seg + 0x10`. The mapping layer reads `psp_seg` from the machine; the **parser never sees it**.

> The record ORDER, the enums (`SymbolClass`/`TypeId`/`MemoryModel`/pointer & func class), the
> name-pool-at-EOF 1-based indexing, and the trailer formula are all in the complete spec and used
> as-is. The unit tests (§8) re-prove every constant against the fixtures, so a wrong size fails loudly.

---

## 1. A. Scope & boundary

### 1.1 What the parser does

- **Input:** the raw bytes of a Borland MZ EXE that carries an appended TDS block (or a
  standalone `.TDS` sidecar; §1.4). The bytes are supplied by the caller — the parser performs
  **no file I/O** (keeps it a pure, testable, host-side function; the load path already has the
  file open via the VFS, `src/dos/vfs.zig:HostDirDrive.open/readAt`).
- **Output:** host-side, **read-only** parsed records + derived indices (§4). All addresses the
  parser emits are **IMAGE-RELATIVE** — a TDS `(segment, offset)` pair plus, for line entries, a
  `(segment_index, offset)`. The parser has **zero knowledge of runtime relocation**.

### 1.2 The clean parser ↔ mapping boundary (the load_para seam)

This is the single most important boundary in the design.

```
   EXE bytes ──parse──►  Tds (raw records, image-relative)  ──index──►  SymbolIndex (image-relative lookups)
                                                                              │
                                          load_para (read from machine) ──►  AddressMap  ──►  runtime-linear lookups
```

- **Parser + SymbolIndex** speak only `(tds_segment, tds_offset)` / `(file_id, line)`. Pure
  function of the bytes. Deterministic and snapshot-neutral by construction.
- **AddressMap** (the mapping layer) is the *only* component that knows `load_para`. It applies
  research §8:
  `runtime_linear = (psp_seg + 0x10) * 16 + seg_image_offset[tds_segment] + tds_offset`.
  It is rebuilt on every `load`/`reset+load` (new `psp_seg`); `seg_image_offset[]` is built from
  the TDS **segment records** (and, for multi-segment images, cross-checked against a `.map` file
  — Risk R1).

This mirrors research §8 and the design-doc rule (§3.3): *"the symbol layer re-derives `load_para`
from the machine at attach time… the breakpoint specs persist, their resolved linear addresses are
recomputed."* `load_para` is a deterministic property of the load, not invented by the core.

### 1.3 Determinism stance (explicit)

- **Pure function of EXE bytes.** No `std.time`, `std.Random`, `std.Thread`, `getenv`, floats, or
  unordered containers — which is also exactly what the `src/debug/` determinism grep-gate forbids
  (`src/debug/determinism_test.zig`); the new files live under `src/debug/` and **must be added to
  that gate's `@embedFile` list** (§8). Indices are sorted arrays + binary search, never `HashMap`.
- **Not snapshotted.** The parsed `Tds`/`SymbolIndex`/`AddressMap` are host-side config,
  re-attached on load (the `LoadRecipe` / `rearmWatches` precedent, §10). They contain no guest
  state and charge no cycles.
- **No host-pointer leakage.** Indices store integer offsets / slice-relative ranges, not absolute
  host pointers, so they never carry ASLR noise (the same property the debug PODs already assert in
  `determinism_test.zig`'s reflection gate).

### 1.4 `.TDS` sidecar variant

`TDSTRIP -s` writes the identical block to a `FILE.TDS` companion (research §2). The sidecar
begins **directly** with `0x52FB` (no MZ header, no trailer-offset math). Handle it as a thin entry
point: `parseTds(allocator, tds_bytes)` consumes bytes starting at the header; `parseExe(allocator,
exe_bytes)` first locates the trailer (§3.1) then calls the same inner routine. The loader path
should prefer the embedded block and fall back to a same-stem `.TDS` if absent (Risk R8).

---

## 2. B. Module layout & public API

Per the design doc §9.2 ("Symbol layer: `src/debug/symbols/` (new) — pure TDS parse + indices +
`load_para` map. Imports only `std`… No atomics; snapshot-neutral."). Placing it under `src/debug/`
keeps it on the pure side of the graph (the gate forbids atomics/threads/floats/hashmaps there) and
above `machine` (`build.zig:133` — `debug_mod` imports `cpu` + `machine`).

```
src/debug/symbols/
  symbols.zig     ── module root: re-exports the public surface (mirrors src/debug/debug.zig style)
  tds.zig         ── the byte parser: EXE/TDS bytes → Tds (raw records + owned name pool)
  index.zig       ── SymbolIndex: derived, sorted lookup indices over a *const Tds (image-relative)
  map.zig         ── AddressMap: load_para + seg_image_offset[]; image↔runtime-linear mapping
  mapfile.zig     ── the .map fallback parser (names-only) feeding the SAME nameToSymbol/addrToFunction
  format.zig      ── packed `extern struct` record layouts + enums (the tdinfo_structs.py mirror)
  tds_test.zig    ── unit tests vs TEST.EXE ground truth + malformed-input tests
```

Wire `symbols.zig` into `src/debug/debug.zig`'s root re-exports and its `test { … }` block, and add
`tds.zig`/`index.zig`/`map.zig`/`mapfile.zig`/`format.zig` to the determinism gate's embed list.
No `build.zig` change is needed (the `debug` module root already globs its own tree via imports);
confirm `symbols.zig` is reached from `debug.zig`.

### 2.1 Public API surface (consumed by `src/debug/source.zig`, the debug core)

```zig
// ── format.zig ──────────────────────────────────────────────────────────────
// AUTHORITATIVE: copy these verbatim from borland-tds-format-complete.md §16 (they compile
// under Zig 0.16 with passing comptime size asserts). Sketch only — full set incl. ModuleRec,
// SourceFileRec, CorrelationRec, the extended header, and the C++/trailing tables is in §16.
pub const Header = packed struct { … };            // base 0x30 + extension; see §16
pub const SymbolRec = packed struct { name: u16, type: u16, offset: u16, segment: u16, flags: u8 }; // 9B
pub const ModuleRec = packed struct { name: u16, language: u8, model: u3, underbars: u1, _r: u4,
                                      symbols_index: u16, symbols_count: u16,
                                      source_files_index: u16, source_files_count: u16,
                                      correlation_index: u16, correlation_count: u16 };       // 16B
pub const SourceFileRec = packed struct { name: u16, dos_timestamp: u32 };                    // 6B
pub const TypeRec   = packed struct { id: u8, name: u16, size: u16, class_type: u8, member_type: u16 }; // 8B
pub const MemberRec = packed struct { info: u8, name: u16, type: u16 };                       // 5B
pub const SegmentRec= packed struct { mod_index: u16, code_segment: u16, code_offset: u16,
                                      code_length: u16, scopes_index: u16, scopes_count: u16,
                                      correlation_index: u16, correlation_count: u16 };        // 16B
pub const CorrelationRec = packed struct { … };    // 8B — see §16
pub const ScopeRec  = packed struct { autos_index: u16, autos_count: u16, parent: u16,
                                      function_symbol: u16, offset: u16, length: u16 };        // 12B
pub const LineRec   = packed struct { line: u16, code_offset: u16 };                          // 4B
pub const SymbolClass = enum(u3) { static, absolute, auto, pascal_var, register, constant, typedef, struct_union_enum };
pub const TypeId = enum(u8) { void = 0, schar = 4, sint = 5, slong = 6, uchar = 8, uint = 9,
                              ulong = 10, float = 13, double = 15, near = 21, far = 22,
                              array = 26, @"struct" = 30, @"union" = 31, @"enum" = 34, function = 35, _ };

// ── tds.zig ─────────────────────────────────────────────────────────────────
pub const ParseError = error{ NoTrailer, BadMagic, UnsupportedVersion, Truncated, OutOfMemory };
pub const Tds = struct { /* owned arrays + name pool; see §4.1 */ };
pub fn parseExe(gpa: std.mem.Allocator, exe_bytes: []const u8) ParseError!Tds;   // locates trailer, then →
pub fn parseTds(gpa: std.mem.Allocator, tds_bytes: []const u8) ParseError!Tds;   // bytes start at the 0x52FB header
pub fn deinit(self: *Tds) void;

// ── index.zig (image-relative) ────────────────────────────────────────────────
pub const SymbolIndex = struct {
    pub fn build(gpa: std.mem.Allocator, tds: *const Tds) error{OutOfMemory}!SymbolIndex;
    pub fn deinit(self: *SymbolIndex) void;
    pub fn lineForImageAddr(self: *const SymbolIndex, seg: u16, off: u16) ?LineHit;     // addr→line
    pub fn imageAddrForLine(self: *const SymbolIndex, file_id: u32, line: u32) ?ImageAddr; // line→addr
    pub fn functionForImageAddr(self: *const SymbolIndex, seg: u16, off: u16) ?FuncRef;  // addr→fn range
    pub fn symbolByName(self: *const SymbolIndex, name: []const u8) ?SymRef;             // name→sym
    pub fn sourceFile(self: *const SymbolIndex, file_id: u32) ?[]const u8;               // raw compile-time path
};

// ── map.zig (runtime-linear; the only load_para consumer) ─────────────────────
pub const AddressMap = struct {
    pub fn attach(gpa, tds: *const Tds, psp_seg: u16) error{OutOfMemory}!AddressMap; // rebuilt each load
    pub fn toRuntimeLinear(self, seg: u16, off: u16) u32;        // image (seg,off) → 20-bit linear
    pub fn imageAddrForLinear(self, linear: u32) ?ImageAddr;     // inverse, for addr→line at a live CS:IP
};
```

The debug core's stepping primitives (design §7.1: `lineForAddr`, `functionForAddr`,
`addrForLine`, `entryAddr`, `name→addr`) are thin compositions of `AddressMap` + `SymbolIndex` —
`lineForAddr(linear) = lineForImageAddr(imageAddrForLinear(linear))`, etc. A `source/function`
breakpoint spec resolves to a `Controller` `execution_address{linear}` (research §8 linear ==
`breakpoints.zig:currentLinear`), so **no new breakpoint kind** is introduced.

---

## 3. C. Parse pipeline (step by step)

All multibyte fields are **little-endian**. Read with `std.mem.readInt(uN, buf[a..][0..k], .little)`
(or `@bitCast`/`extern struct` for the fixed records — but bounds-check the slice first; do not
`@ptrCast` past the buffer end). Every step that indexes the buffer must be guarded against
`Truncated`.

### 3.1 Locate the TDS trailer (EXE path only)

From the MZ header (`src/dos/loader.zig:40` `ExeHeader` mirrors these): read
`used_bytes_in_last_page` (off 0x02) and `file_size_in_pages` (off 0x04).

```
used = (used_bytes_in_last_page == 0) ? 512 : used_bytes_in_last_page
base = file_size_in_pages * 512 - (512 - used)
```

(Confirmed exact for the fixture: `9*512 - (512-0x170) = 0x1170`.) If `base + 4 > exe_bytes.len`
⇒ `error.NoTrailer`. Robustness fallback (research §2 "Recommended strategy"): if the word at
`base` ≠ `0x52FB`, scan **backwards** from `exe_bytes.len-4` in 2-byte steps for `0x52FB` before
giving up — handles TLINK variants that include/exclude the block in `e_cp`/`e_cblp`. For the
`.TDS` sidecar, `base = 0`.

### 3.2 Validate + read the header

- `signature == 0x52FB` else `error.BadMagic`.
- `major_version == 3` else `error.UnsupportedVersion` (log `major.minor`; we target 3.10).
  Accept `minor` 0x00/0x10 (TDS 3.0/3.10); reject 2.x and TD32 (`"FB09"/"FB0A"`).
- Read the 0x30-byte fixed prefix into `Header` (the count fields per §0 table). **Header byte
  size = `0x30 + extension_size`**; the `extension_size` bytes (C++ browser extension; 0x00 / 0x10
  / 0x20) are **skipped, not parsed** (Tier-1/2 ignore C++ browser data). Record block #0 (symbols)
  begins at `base + 0x30 + extension_size`.

### 3.3 Walk the record blocks in confirmed order

Compute each block's start by cumulative size from the post-header offset, using the **corrected
sizes**:

| # | Block | Count field | Record size | Decode |
|---|---|---|---|---|
| 1 | symbols | `symbols_count` | **9** | `SymbolRec` (§2.1). class = `flags & 0x07`; `has_bp = flags & 0x08`; ret-words = `(flags>>4)&0x07` |
| 2 | modules | `modules_count` | **16** | `ModuleRec` — all fields confirmed (complete-spec §5) |
| 3 | source-files | `source_files_count` | **6** | `{ u16 name; u32 dos_timestamp }` (complete-spec §6) |
| 4 | line-numbers | `line_numbers_count` | **4** | `{ u16 line; u16 code_offset }` (line first) |
| 5 | scopes | `scopes_count` | **12** | `ScopeRec` |
| 6 | segments | `segments_count` | **16** | `SegmentRec` (last 4B = `correlation_index/count`) |
| 7 | correlations | `correlations_count` | **8** | `CorrelationRec` — confirmed (complete-spec §10) |
| 8 | types | `types_count` | **8** | `TypeRec` (Tier-2 stored now, indexed later) |
| 9 | members | `members_count` | **5** | `MemberRec` (Tier-2) |
| 10+ | trailing tables | extended-header counts | — | include-files / coverage-map / coverage-offset / module-opt (+ C++ class/parent/etc.) — **skip via `name_pool_offset`** unless a consumer needs them (complete-spec §11/§15) |

After each block, assert `offset <= names_pool_start`; overrun ⇒ `error.Truncated`. (Simplest:
seek the name pool directly via the extended header's `name_pool_offset` and treat the region
between block #9 and the pool as the trailing tables — you do not need to size every C++ table to
find the names.)

### 3.4 Load the name pool (seek to EOF)

`names_pool_start = exe_bytes.len - names_pool_size` (for the embedded block the pool runs to EOF;
research §0/§4.1 and the `construct` `Seek(-names_pool_size, EOF)`). Validate
`names_pool_start >= block#9 end`. Copy the `names_pool_size` bytes into an owned buffer. Build a
`name_starts: []u32` of length `names_count` by scanning NUL terminators: index *i* (1-based) =
the *i*-th string. Resolve `name(i)` = slice from `name_starts[i-1]` to the next NUL; **index 0 =
"" (anonymous)**. (Off-by-one is the classic bug — research gotcha #3.)

### 3.5 Resolve 1-based references

`SymbolRec.name`, `TypeRec.name`, `MemberRec.name`, module/source-file name fields are **1-based**
name-pool indices (0 = anonymous). `SymbolRec.type < 0x18` ⇒ a predefined `TypeId`; `>= 0x18` ⇒
index `type-0x18` into the type table (research §4.2). Keep these as raw indices in `Tds`; resolve
lazily in `SymbolIndex`/rendering so the parse stays a straight byte walk.

---

## 4. D. Data model & derived indices

### 4.1 `Tds` (raw, owned, image-relative)

```zig
pub const Tds = struct {
    arena: std.heap.ArenaAllocator,     // owns everything below (§5)
    header: Header,
    symbols:   []SymbolRec,
    modules:   []ModuleRec,             // 16B, all fields confirmed (complete-spec §5)
    sources:   []SourceFileRec,         // { name: u16, dos_timestamp: u32 } (complete-spec §6)
    lines:     []LineRec,               // { line: u16, offset: u16 }
    scopes:    []ScopeRec,
    segments:  []SegmentRec,
    correls:   []CorrelRec,             // 8B, confirmed (complete-spec §10)
    types:     []TypeRec,
    members:   []MemberRec,
    name_pool: []u8,                    // owned copy
    name_starts: []u32,                 // 1-based resolver (name_starts[i-1] → string i)
    pub fn name(self: *const Tds, idx: u16) []const u8; // idx 0 ⇒ ""
};
```

### 4.2 Tier-1 derived indices (`SymbolIndex`)

All "sorted array + binary search", no `HashMap` (gate-compliant + cache-friendly + deterministic).

- **`addrToLine`** — per (module/segment) a slice of `{ code_offset, line, file_id }` **sorted by
  `code_offset`**. `lineForImageAddr(seg,off)` = `upperBound(off)-1` within that segment's slice
  (the interval `[entry, next_entry)` owns `off`). Drives "where am I" + line stepping (design §7.2).
- **`lineToAddr`** — `{ file_id, line }` → lowest `code_offset`. Built by sorting line entries by
  `(file_id, line, code_offset)`; `imageAddrForLine` returns the first (lowest-offset) match for a
  `(file_id, line)` (a line can map to several ranges — design §7.6; pick the lowest). Drives
  source breakpoints + `runToLine`.
- **`addrToFunction`** — function ranges. Source: code-class symbols (`SymbolClass.static` with a
  code segment, i.e. `_add`/`_main`) give entry points; **`ScopeRec { function, offset, length }`**
  + `SegmentRec { scope_index, scope_count }` give the *range* `[offset, offset+length)`. Build a
  per-segment list of `{ offset, length, sym_index }` sorted by `offset`; `functionForImageAddr`
  does the interval lookup. `entryAddr(fn)` = post-prologue first line (the function's first
  `LineRec.offset` ≥ entry; design §7.6 "stop post-prologue so locals are valid").
- **`nameToSymbol`** — `{ name_slice, sym_index }` sorted by name bytes; `symbolByName` does a
  `std.mem.order` binary search. Feeds function breakpoints + `evaluate` name lookup.
- **`modules` / `sourceFiles`** — small tables: `module_id → name`, `file_id → raw path`
  (path normalization deferred to the frontend — Risk R6 / design §11.5).

### 4.3 Grouping line entries → (source file, segment)

Line entries bind to a (source file, segment) via the **correlation record** (now fully decoded —
complete-spec §10): each module's `correlation_index/count` (and segment's) select the correlation
rows that map a contiguous run of line entries to a source file + code-base segment. The line
`code_offset` is relative to that segment's code base. Multi-module is confirmed (`RICH` = 3
modules / 3 segments / 3 correlations), so the grouping is general — no single-module special case
and no dropped "sentinel" (the old `(78,2)` was a phantom of the wrong module size; with module=16
every entry is real, starting at the function-declaration line).

For **multi-file / multi-segment** images the binding must come from the **segment records**
(`SegmentRec.module`, `code_segment`, `scope_index/scope_count`) and the **correlation records**
(8B, partially decoded — fixture `(0,0,730,39)`). **TODO (R1):** confirm the correlation field
semantics with a multi-file BC++3.1 build before claiming full multi-file line coverage. Until then
the index carries a `multi_file_unverified: bool` flag and the core degrades gracefully (address-
level still works; line binding falls back to the nearest preceding segment record).

### 4.4 Tier-2 (parsed now, indexed later)

`types` + `members` are stored in `Tds` from day one (the parse already walks them — §3.3) but no
type-graph/locals indices are built in Tier 1. Tier 2 adds: a `type_graph` (resolve
predefined-vs-complex, struct member layout via `MemberRec`, pointer/array via `TypeRec.id`) and a
`scopeLocals(scope) → []SymbolRec` index (BP-relative `auto` symbols, where `offset` is a signed
i16 stack delta and `has_bp` is set). These feed `scopes`/`variables` (design §4.3, Tier-2).

---

## 5. E. Memory management & lifetime

- **Parse once, at load time.** `parseExe` is called from the load path (alongside
  `worker.zig:loadResp` → `ctrl.m.boot`, §10) after the EXE is read into a host buffer via the VFS.
- **Own everything in a single arena.** `Tds.arena` (`std.heap.ArenaAllocator` over the session
  `gpa`) owns the name-pool copy, every record array, and the `SymbolIndex` sorted arrays. This
  matches the zdos `gpa.create` + per-session ownership convention (`session.zig:315` `init`) while
  bounding the symbol layer to one free point.
- **Lifetime = the loaded program.** On `reset` / `load` / `reset+load` the prior `Tds`/
  `SymbolIndex` are `deinit`'d (arena reset) and rebuilt from the new EXE bytes — the exact shape of
  how `LoadRecipe` is re-applied and `rearmWatches` re-syncs on reload (`controller.zig`,
  `worker.zig:loadResp`). On `restore` (`worker.zig:restoreResp`) `load_para` is unchanged (same
  load) ⇒ **no reparse**; only `AddressMap` need not even rebuild. Add a `onMachineReverted()`
  no-op hook next to `rearmWatches` for symmetry (design §3.3).
- **Host-side allocation is fine here — and bounded.** This is the load step, **not** the
  deterministic per-cycle step path, so a host allocator is legal (CLAUDE.md §1 governs *emulated*
  time, which this never touches). Bound: parse is `O(file_size)`; indices are
  `O(symbols+lines)·log` to sort; total memory ≈ `names_pool_size + Σ records + a few sorted
  copies` (tens of KB for the BaK relink, ~2 KB for the fixture). An OOM is a clean
  `error.OutOfMemory` → "no symbols" (§6), never a panic.

---

## 6. F. Error handling & degradation (+ `.map` fallback)

**Graceful "no symbols" is mandatory** — the debugger must keep working at the address level
(disasm, instruction breakpoints, register/memory peek all already exist in `Controller`).

- Any of `error.{NoTrailer, BadMagic, UnsupportedVersion, Truncated, OutOfMemory}` ⇒ the load path
  logs once and proceeds with `symbol_index = null`. The debug core checks `?*SymbolIndex`: absent
  ⇒ `lineForAddr`/`functionForAddr` return `null`, source/function breakpoints resolve
  `verified=false` (design §4.2), and the `module_loaded` event reports `symbols=false`.
- **No partial-trust.** A record-block overrun (`offset > names_pool_start`) fails the whole parse
  to `error.Truncated` rather than emitting half a (silently wrong) index — faking symbols is the
  exact failure mode CLAUDE.md §2 forbids.

### 6.1 `.map` fallback (names-only, no lines)

`mapfile.zig` parses a TLINK `/m` **`.map`** file (plain text: a "Publics by Value" table of
`SEG:OFFSET  NAME` rows, plus a segment table). It is a strictly weaker source — **function/global
names + addresses only, no line numbers, no types** — but it feeds the **same** `nameToSymbol` and
`addrToFunction` indices via a small adapter that emits synthetic `SymRef`/`FuncRef` rows. Design so
both producers (TDS and `.map`) target one index type:

```
SymbolIndex.build(gpa, .{ .tds = &tds })       // full
SymbolIndex.fromMap(gpa, parsed_map)           // names/funcs only; lineForImageAddr always null
```

Selection order at load: embedded TDS → same-stem `.TDS` sidecar → same-stem `.MAP` → none. The
`.map` segment table also gives the `seg_image_offset[]` cross-check for `AddressMap` (research §8).

---

## 7. G. Tier phasing → milestones

| Tier | Deliverable | Indices built | Enables | Milestone |
|---|---|---|---|---|
| **Tier 1** | parser + image-relative indices + `AddressMap` | `addrToLine`, `lineToAddr`, `addrToFunction`, `nameToSymbol`, modules/source-files | source & function breakpoints, "where am I" (`pcLocation`), line stepping (`stepLine`/`stepIn`/`stepOut`), `runToLine`, frame-0 location | **D1** (design §10 Tier 1) |
| **Tier 2** | type graph + locals | `type_graph`, `scopeLocals` | `scopes` / `variables` / `setVariable`, type-name + value rendering | **D2** |
| **Tier 2.5 (gated by R1)** | multi-file/segment correlation | refined `addrToLine` grouping via segment+correlation records | full multi-module line coverage (BaK is multi-`.obj`) | between D1/D2 |

Tier 1 is the high-value slice and is fully reachable from the fixture (single module). Tier 2 only
needs *parsing* added in Tier 1 (types/members already walked), so it is purely additive
index-building. Tier 2.5 is the one tier blocked on new ground truth (R1).

---

## 8. H. Testing (TEST.EXE as golden fixture)

`TEST.EXE` is the **canonical golden fixture** — checked in, a real BC++3.1 build, with a fully
decoded oracle (`decode-output.txt`). Tests live in `src/debug/symbols/tds_test.zig`, registered in
`src/debug/debug.zig`'s `test { … }` block, and embed the fixture with
`@embedFile("../../docs/research/bcc3-fixtures/TEST.EXE")` (verify the relative path from the module
root; otherwise copy the fixture under `src/debug/symbols/testdata/`).

### 8.1 Ground-truth assertions (parse `TEST.EXE`, assert exact values)

- **Trailer + header:** `base == 0x1170`; `signature == 0x52FB`; `major==3, minor==0x10`;
  `extension_size == 0x20`; counts = `{names 87, types 26, members 3, symbols 84, globals 77,
  modules 1, locals 0, scopes 4, lines 10, sources 1, segments 1, correlations 1}`;
  `names_pool_size == 773`. **Header byte size == 80** (regression guard for the 0x30+ext fix).
- **Block placement (regression guard for the 16-byte module fix).** The test computes each block
  start by cumulating the §0 sizes and asserts them; anchored checkpoints (all independently
  verified): symbols@**0x11C0** (= header end), modules@**0x14B4** (= symbols end, 84×9), and
  name_pool@**0x162B** (= EOF 0x1930 − 773). With **module=16** the intermediate blocks are
  sources@0x14C4, lines@0x14CA, scopes@0x14F2, segments@0x1522, correlations@0x1532, types@0x153A,
  members@0x160A; the ~18-byte region between members-end (0x1619) and the name pool is the
  include-files/coverage trailing tables. **The test must assert the cumulative walk lands exactly
  on name_pool_start — that single assertion catches any wrong record size.**
- **Symbols:** `symbolByName("_add")` ⇒ `(segment 0, offset 706)`; `symbolByName("_main")` ⇒
  `(segment 0, offset 730)`. First three name-pool strings = `__AHSHIFT`, `__cleanup`,
  `__checknull` (1-based). Symbol record #8 has `name_index == 9` (== `_add`).
- **Line table:** the 10 entries equal (verbatim from `TEST.LST`'s "Line Numbers" oracle —
  `4:02C2 7:02C8 8:02D1 9:02D6 11:02DA 14:02E0 15:02E5 16:02EA 17:02F8 18:02FD`):
  `{(4,706),(7,712),(8,721),(9,726),(11,730),(14,736),(15,741),(16,746),(17,760),(18,765)}`.
  Note the **first** entry is `(4,706)` (the function-declaration line) and there is **no** trailing
  `(78,2)` — an earlier draft's list (starting `(7,712)`, ending `(78,2)`) was the off-by-one
  artifact of the wrong module=20. Asserts: `imageAddrForLine(file 0, 11) == 730`;
  `lineForImageAddr(0, 730).line == 11`; `lineForImageAddr(0, 735).line == 11` (interval, 730 ≤ 735 < 736).
- **Source-file record:** raw bytes == `dd 5c 04 00 c2 02`.
- **Functions:** `functionForImageAddr(0, 720)` resolves to `_add` (730 is `_main`'s entry, so the
  `[706,730)` range is `_add`).
- **AddressMap:** with a synthetic `psp_seg`, `toRuntimeLinear(0, 730) == (psp_seg+0x10)*16 + 730`
  for the small-model single code segment, and `imageAddrForLinear` round-trips it.

### 8.2 Malformed-input tests (graceful, never panic)

- Empty / `< MZ header` slice ⇒ `error.NoTrailer`.
- `TEST.EXE` truncated mid-record-block ⇒ `error.Truncated` (no partial index).
- Trailer word clobbered to `0x0000` ⇒ `error.BadMagic` (and the backward-scan fallback finds none).
- `major_version` patched to 2 or 4 ⇒ `error.UnsupportedVersion`.
- A `names_pool_size` larger than the file ⇒ `error.Truncated`.

### 8.3 Determinism

- Parsing the same bytes twice yields **byte-identical** `Tds` + index arrays (trivial: pure
  function; assert via a deep-equal/hash of the sorted index arrays). No host clock/RNG/thread is
  touched.
- **Add the five new source files to the grep gate** (`src/debug/determinism_test.zig` `sources`
  list): `format.zig`, `tds.zig`, `index.zig`, `map.zig`, `mapfile.zig` — so they stay free of
  `std.time`/`Random`/`Thread`/`HashMap`/`std.atomic`/`f32`/`f64`/`Io.Mutex`. (The index design is
  already HashMap-free; this just locks it.) Also extend the reflection gate to assert the public
  PODs (`SymbolRec`, lookup-hit structs) hold no pointer-typed fields that could leak host
  addresses — name slices are fine as *borrowed* views but must never be snapshotted.

---

## 9. I. Open questions & risks

**RESOLVED since this plan was first drafted** (the format is now 100% mapped — see
`borland-tds-format-complete.md`; fixtures `RICH`/`CLS`/`MI`/`ENUM`/`PTR`/`MMx`/`INC`/`BENUM`):
- ~~**R1** correlation/source-file semantics~~ — **CLOSED.** correlation=8 and source-file=6
  `{name, dos_timestamp}` fully decoded; multi-module/multi-segment binding confirmed via `RICH`
  (3 modules) and `CLS`. No `multi_file_unverified` gate needed.
- ~~**R2** `seg_image_offset[]`~~ — **CLOSED.** `SegmentRec` fully decoded (incl. `correlation_index/
  count`); the `.map` cross-check remains a cheap belt-and-suspenders, not a dependency.
- ~~**R3** predefined `TypeId` values~~ — **CLOSED.** Full `TypeId`/`TID_*` set confirmed (BOA + fixtures).
- ~~**R4** register-class symbols~~ — **CLOSED.** Register encoding confirmed (`CX=1`,`SI=6`, …) and the
  BP-relative auto encoding (complete-spec §4/§8); render locals directly.
- ~~**R5** the `(78,2)` line entry~~ — **CLOSED.** It was a phantom of the wrong module=20; with
  module=16 the line block starts at `{4,706}` and all entries are clean. No drop-heuristic needed.
- ~~**R7** "unvalidated" module / source-file / trailing-gap bytes~~ — **CLOSED.** module record (16B)
  fully decoded; the trailing gap is the include-files + coverage/module-opt tables (skip via
  `name_pool_offset`).

**Still genuinely open (architecture/host decisions, not format gaps):**
- **R6 — Source path normalization.** TDS stores compile-time DOS paths (8.3, uppercase, possibly
  relative, e.g. `TEST.C` / `C:\BAK\FOO.C`). The symbol layer keeps the **raw** path; the
  compile-path→host-path remap and source-serving belong to the **frontend** (design §11.5 — it is
  IDE/host-specific, not a debugging semantic). The index exposes `sourceFile(file_id) → raw bytes`
  only.
- **R8 — `.TDS` sidecar discovery.** Resolve precedence (embedded → `.TDS` → `.map` → none) and
  case-folding for the sidecar stem on the case-preserving host mount (`vfs.zig` already does 8.3
  case folding — reuse it, don't reinvent).
- **R9 — C++-only tables** (Browser/OptSym/Overload/RefInfo) have BOA-documented but
  empirically-unconfirmable layouts (BC++3.1 emits 0 of each). The parser **skips** them via the
  extended-header counts + `name_pool_offset`; only revisit if a future consumer needs C++ RTTI/
  browse info (irrelevant to C source-level debugging).

---

## 10. Appendix: codebase anchors

The implementer builds primarily on these (absolute paths under the repo root):

**Top 3 files to build on:**

1. `src/dos/loader.zig` — `Loader(Cpu)`: `loadExe` (`:135`), `ExeHeader` (`:40`, the MZ fields the
   trailer formula reuses), `load_seg = psp_seg + 16` (`:195`), `dos.current_psp = psp_seg`
   (`:206`), `applyRelocations` (`:222`). **`psp_seg` is the `load_para` the `AddressMap` reads;
   image base paragraph = `psp_seg + 0x10`.** This is the only machine state the symbol layer
   touches, and only via the mapping layer.
2. `src/api/session.zig` + `src/api/worker.zig` — `LoadRecipe` (`session.zig:145`) and `Session`
   (`session.zig:201`, the `gpa.create` per-session ownership + `mount_dir`/`recipe` re-attach
   pattern) are the **exact precedent** the symbol layer copies: host-side config rebuilt on load,
   never snapshotted. `worker.zig:loadResp` (`:655`, calls `ctrl.m.boot`) is where the parse is
   triggered; `restoreResp` (`:692`, calls `rearmWatches`) is where the `onMachineReverted` hook
   sits (no reparse — `load_para` unchanged).
3. `src/debug/determinism_test.zig` — the grep + reflection gate the new files must pass (forbids
   `std.time`/`Random`/`Thread`/`getenv`/`HashMap`/`std.atomic`/`f32`/`f64`/`Io.Mutex`; asserts
   PODs hold no pointer fields). Add the five `src/debug/symbols/*.zig` to its `@embedFile` list.

**Supporting:**

- `src/debug/debug.zig` — module root + `test { … }` registration style to mirror for
  `symbols.zig`. `build.zig:133` (`debug_mod`, root `src/debug/debug.zig`, imports `cpu`+`machine`).
- `src/debug/breakpoints.zig` — `BreakpointKind.execution_address{linear}` + `currentLinear`
  (`:212`, `seg_base[CS] +% EIP`): the exact linear that `AddressMap.toRuntimeLinear` must produce
  so source/function breakpoints reduce to `execution_address`.
- `src/dos/vfs.zig` — `HostDirDrive.open`/`readAt` (`:329`+): how the load path already has the EXE
  bytes; the parser consumes a byte slice, it does not open files.
- `docs/research/borland-bcc3-debug-format.md` (§0 authoritative, §6 line/correlation, §7 types, §8
  address/segment + `load_para`) and `docs/research/bcc3-fixtures/{TEST.EXE,decode-output.txt,
  tdinfo_structs.py}` — the spec + golden oracle.
```
