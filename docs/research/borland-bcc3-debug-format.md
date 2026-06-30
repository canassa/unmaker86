# Borland BCC 3.1 / TLINK 5.1 Symbolic Debug Information Format

**Implementation-grade reference for writing a Zig parser in zdos**

Compiled from: Borland Open Architecture Handbook (BOA), faydoc.tripod.com format tables,
excbadacc.es format notes, VOGONS version survey, JCL TclTD32.pas, tds2dbg/tdscvstructs.h,
and Troy Rollo's BFD patch research.

Confidence legend used throughout this document:
- **[CONFIRMED-EMPIRICALLY]** — validated against a real BC++ 3.1 build (see §0)
- **[DOCUMENTED]** — stated in the BOA or an official Borland document
- **[INFERRED]** — consistent across multiple independent parser sources
- **[UNCERTAIN]** — conflicting sources or single unverifiable source; verify with TDUMP
- **[TODO-TDUMP]** — cannot be confirmed without running TDUMP on a real BCC 3.1 binary

---

## 0. Empirical Confirmation (BC++ 3.1, validated) — READ FIRST

The sections below were written from web research with confidence tags. This section records
an **empirical validation pass** that resolves the major uncertainties — including the report's
single biggest open question (the line-number entry layout). Treat §0 as authoritative where it
contradicts a tagged claim downstream.

**Method.** Compiled `TEST.C` (18 lines, one struct, a global, two functions `add`/`main`) with
the actual BaK decomp toolchain — **Borland C++ 3.1** (`bcc -v -ms`) + **Turbo Link 5.1**
(`tlink`, debug info embedded) — run headless under `dosbox-x`. The resulting `TEST.EXE` (with
the `0x52FB` trailer) was then parsed two ways: (a) byte-for-byte by the `construct` schema from
`ramikg/tdinfo-parser` (`tdinfo_structs.py`), and (b) field-by-field manual decode of the
records that schema skips. Fixtures (the `.C`, the `.EXE`, `tdinfo_structs.py`, the decode script,
and its output) are checked in under `docs/research/bcc3-fixtures/` for reproduction.

**Confirmed facts:**

1. **Toolchain & version.** `bcc.exe` reports `Borland C++ Version 3.1`, linker `Turbo Link 5.1`.
   The TDS header reads **major_version = 3, minor_version = 0x10** (i.e. the 16-bit TDS "3.x"
   family, NOT TD32/CodeView). `[CONFIRMED-EMPIRICALLY]`

2. **Trailer location formula is exact.** For the fixture (MZ `pages=9`, `used_bytes_in_last_page
   =0x170`), the TDS header sits at `9*512 - (512-0x170) = 0x1170`, found there byte-for-byte.
   Use `file_size_in_pages*512 - (512 - used_bytes_in_last_page)` (treat a `0` last-page count as
   512). `[CONFIRMED-EMPIRICALLY]`

3. **The header + symbol + line + module + name-pool layout is byte-verified; the Tier-2 blocks
   are NOT.** ⚠️ CORRECTION (byte-re-verified against the fixture — supersedes an earlier draft of
   this section that said "every record size is validated"): the `construct` reference parser
   (`tdinfo_structs.py`) reads the name pool by seeking from **EOF**, so a clean symbol/name result
   does **NOT** prove the intermediate record sizes — only the header size and the symbol-record
   stride (both *before* the symbols) are actually pinned by it. Direct hex verification gives:
   - **Header = 80 bytes** (NOT 82): there are **12** `*_count` u16 fields, not 13. Layout:
     `magic(2) minor(1) major(1) names_pool_size(4) + 12×count(2)=24 + Padding(14) + extension_size(2)
     + Padding(extension_size)`; for the fixture `extension_size=0x20`, so header = `0x50` = 80, and
     the **symbol records begin at file offset `0x11C0`** (verified: indices run 1,2,3,…; records
     [8]/[9] are `_add`@off706 and `_main`@off730).
   - **symbol records** — `symbols_count × 9 bytes` `{u16 name_index(1-based), u16 type, u16 offset, u16 segment, u8 bitfield(5 pad + 3-bit class)}` `[CONFIRMED-EMPIRICALLY]`
   - **module records** — `modules_count × 16 bytes` (see §0.2; an earlier draft's "20" was an artifact of an unaccounted extra table — §0.3) `[CONFIRMED-EMPIRICALLY]`
   - **source-file records** — `source_files_count × 6 bytes` `[CONFIRMED]`
   - **line-number records** — `line_numbers_count × 4 bytes`, entry layout in fact #5 `[CONFIRMED-EMPIRICALLY]`
   - **name pool** — at EOF, `names_count` NUL-terminated ASCII strings, total `names_pool_size_in_bytes`; `name` fields are **1-based indices** `[CONFIRMED-EMPIRICALLY]`
   - ⚠️ **scopes / segments / correlations / types / members** — the flat-record sizes/order in
     `tdinfo_structs.py` and earlier drafts (`12 / 16 / 8 / 8 / 5`) **do NOT reconcile** with the
     EOF name pool (a **14-byte residual** on the fixture). **Do not trust them; the exact raw
     layout of these records is still TODO** — but it is now a *mechanical* derivation, see §0.1.

### 0.2 Tier-2 record sizes — DERIVED & double-fixture-verified `[CONFIRMED-EMPIRICALLY]`

Pinned by correlating raw bytes against the TDUMP oracle on BOTH fixtures (the sizes reconcile
the symbols-end→name-pool span EXACTLY for TEST=375 and RICH=706 — no residual):

| Record | Size | Layout (LE) | Note vs `tdinfo_structs.py` |
|--------|------|-------------|------------------------------|
| symbol | 9 | `{name(2), type(2), offset(2), segment(2), class(1: 5pad+3bit)}` | same |
| **module** | **16** | starts `{name(2), …}`; name-indices stride 16 (RICH `0x53/0x68/0x73`) | schema=16 ✓ (report draft "20" was WRONG) |
| source-file | 6 | `{name(2), dos_timestamp(4)}` | n/a |
| line | 4 | `{line(2), code_offset(2)}` offset rel. to the module code-base segment | same |
| scope | 12 | `{symbol_index(2), symbol_count(2), parent(2), function(2), offset(2), length(2)}` — verified vs TDUMP scope offset/length/local-count | same |
| segment | 16 | `{mod_index(2), code_seg(2), code_off(2), code_len(2), scopes_index(2), scopes_count(2), correlation_index(2), correlation_count(2)}` — the schema's "pad(4)" is actually the correlation index/count (BOA `segment info`) | refined |
| **correlation** | **8** | binds source-file↔segment↔line-range | **schema=8 ✓** |
| type | 8 | `{id(1), name(2), size(2), class(1), member_type(2)}` | same |
| **member** | **5** | `{info(1: bit_field_size:6/offset_rec:1/end_of_struct:1), name(2), type(2)}` (BOA `struct member_type`) | **schema=5 ✓** |

⚠️ **CORRECTION (this supersedes an earlier draft of §0.2 that claimed correlation=16 / member=7).**
Those were WRONG. The original `tdinfo_structs.py` sizes (correlation=**8**, member=**5**) are correct
— confirmed three ways: (a) the BOA `struct member_type` = `{1-byte bitfield, name, type}` = 5 bytes
in the 16-bit variant; (b) only 8/5 **decode to clean data** (16/7 produces garbage); (c) all four
fixtures parse with 8/5. My earlier "exact reconciliation" was an arithmetic coincidence: I never
modeled the **include-files** (`srcfiles×6`) and **coverage-offsets** (`cov×2`) tables, and those
absorb exactly the 132-byte difference so BOTH size sets land on zero residual. **Lesson: EOF-anchored
gap-arithmetic is NOT sufficient to pin sizes — you must decode to clean data.** Locals are NOT a
block (`locals_count=0`); a scope's `autos_index`/`autos_count` reference them (BOA `struct scope`).

The authoritative, fully-reconciled mapping now lives in **`borland-tds-format-complete.md`** (the
empirical pass, all 4 fixtures parsing) cross-checked against **the BOA** (`bcc3-fixtures/
borland-open-architecture-handbook.txt`, retrieved in full). The BOA gives the definitive block
ORDER (Correlation→Type→Members→Class→Parent→ScopeClass→ModuleClass→Coverage→Browser→OptSym→…→Names)
and confirms globals are a prefix of the symbols array (the `globals` count = how many leading
symbols are global). Note: the BOA documents the **32-bit (TD32)** variant (u32 counts/indices); BC++
3.1 emits the **16-bit** variant (u16) — field order/semantics shared, widths differ.

### 0.3 The flat model is INCOMPLETE — extra optional tables exist `[CONFIRMED-EMPIRICALLY]`

TDUMP's header lists tables `tdinfo_structs.py` ignores entirely, with their own counts (in the
**extended header**, the `extension_size`=0x20 region): Include Files, Class Entries, Parent
Entries, Overload Entries, Global Classes, Scope-Class, Module-Class, **Coverage-Analysis
Offsets**, Browser Entries, Optimized-Symbol Entries. Most are 0 in trivial builds, but **TEST has
`Coverage-Analysis Offsets = 6` and `Include Files = 1`** — that's the source of TEST's otherwise-
unexplained 4-byte delta. ⚠️ **The parser MUST read the extended-header counts and account for
these tables (and the exact extended-header field order is still TODO — map it from TDUMP's count
list + `RICH.LST`/`TEST.LST`).** A large real target like BaK will likely populate several.

### 0.1 TDUMP is the authoritative oracle — Tier-2 structure mapped `[CONFIRMED-EMPIRICALLY]`

`bc31/BIN/TDUMP.EXE` produces a full human-readable decode of the symbol table. The working
invocation (headless, dosbox-x) takes the **listfile as a positional arg** (NOT stdout redirect):
`tdump INPUT.EXE OUTPUT.LST`. This is the ground-truth decoder — any remaining raw-byte question
is resolved by correlating its output against the file bytes, not by guessing. Checked-in oracle
fixtures: `bcc3-fixtures/RICH.EXE` (3-module / multi-segment / rich-type build of `F1-3.C`),
`RICH.LST`, `TEST.LST`. TDUMP confirms `Symbolic Information Version: 3.10`, and the table file
bases (e.g. Global/symbol table @ image+`0x1300`, Module table @ `0x16A8`).

The Tier-2 **semantic structure** (from TDUMP) — supersedes the flat-independent-blocks model:
- The debug info is **hierarchical**: each **Module** owns its source file(s), **type
  definitions** (typedef / struct / union / enum, each with members → name + type), and
  **correlation records**. A correlation binds a *source file* to a **code base** (`seg:offset`)
  + **code length**, and contains **scopes** and **line numbers**.
- A **scope** = `{parent scope, scope offset, scope length}` plus its **locals**, each rendered as
  a **storage location** (`[BP+8]`, `[BP-12]`, or a register like `SI`/`CX`) + storage class
  (`auto` / `register`) + type. **This resolves the `locals_count = 0` mystery: locals are NOT a
  separate block — they live inside the scope records.**
- **Line numbers** are `line:offset` pairs where `offset` is relative to that module's **code
  base segment** (e.g. F1 `Code Base 00C2:0006`, lines `9:0006h 15:000Dh …`). Confirms the
  `{u16 line, u16 offset}` entry and pins how offsets bind to a segment (via the correlation's
  code base) — the missing piece for multi-module address↔line mapping.

Net: **Tier-1** (symbols, line table, modules, source files, name pool) is solid and coded
against confirmed bytes. **Tier-2** semantics are fully mapped and we have an on-demand oracle;
only the exact flat **type/member/scope/correlation/segment record byte-layouts** remain to be
pinned by mechanical TDUMP-vs-bytes correlation (a bounded task, no longer open research).

4. **`SymbolClass` (3-bit) and `TypeId` enums confirmed** as listed in `tdinfo_structs.py`:
   SymbolClass `{0 STATIC, 1 ABSOLUTE, 2 AUTO, 3 PASCAL_VAR, 4 REGISTER, 5 CONSTANT, 6 TYPEDEF,
   7 STRUCT_UNION_OR_ENUM}`. TypeId `{0 VOID, 4 SCHAR, 5 SINT, 6 SLONG, 8 UCHAR, 9 UINT,
   10 ULONG, 13 FLOAT, 15 DOUBLE, 21 NEAR, 22 FAR, 26 ARRAY, 30 STRUCT, 31 UNION, 34 ENUM,
   35 FUNCTION, …}` (full list in §7 / the fixture). `[CONFIRMED-EMPIRICALLY]`

5. **LINE-NUMBER ENTRY LAYOUT — RESOLVED (was the #1 open question).**
   Each 4-byte entry is **`{ u16 line_number; u16 code_offset; }`** (little-endian, **line first**).
   Proof from the fixture: `add()` (source lines 4–9) starts at code offset 706; `main()` opens at
   **source line 11 / code offset 730**, and line-entry [3] is exactly `{line=11, offset=730}`. The
   offsets are strictly monotonic (712, 721, 726, **730**, 736, 741, 746, 760, 765) and the line
   numbers (7,8,9,11,14,15,16,17,18) match `TEST.C`'s executable lines one-for-one. The
   offset-first reading would yield line numbers in the hundreds — ruled out. Offsets are within
   the code segment named by the segment/correlation record. `[CONFIRMED-EMPIRICALLY]`
   (supersedes §6 "[PARTIALLY DOCUMENTED] line number entries")

**Still only partially resolved (low priority for MVP):**
- **source-file record (6 bytes)** — fixture raw `dd5c0400c202`. Plausibly `{u16/u32 name ref,
  u16 first-or-count}`; the `0x02c2 = 706` tail equals `_add`'s offset, suggesting a start-address
  field. Field semantics not pinned — confirm with a multi-file build.
- **correlation record (8 bytes)** — fixture raw `00000000da022700` → `(0,0,730,39)`; `730` is
  `main`'s offset, `39` likely a line/count. Ties source files↔segments↔line ranges; exact field
  meaning TBD with a multi-segment build.
- **TDUMP human-readable dump** — `TDUMP.EXE` 3.1 is present and runs, but its full symbolic
  dump did not capture cleanly via `dosbox-x` output redirection (only the banner came through).
  Not needed: the binary-level `construct` validation is stronger ground truth. Revisit under a
  real DOS console or `xvfb-run` if a human-readable cross-check is wanted.

**Reproduce:** `cd docs/research/bcc3-fixtures && nix-shell -p "python3.withPackages(p:[p.construct])" --run "python3 decode.py"`.

---

## Table of Contents

1. [Scope and Versioning](#1-scope-and-versioning)
2. [Container and Location in MZ EXE](#2-container-and-location-in-mz-exe)
3. [Top-Level Structure: The Debug Block Header](#3-top-level-structure-the-debug-block-header)
4. [Record and Subsection Types](#4-record-and-subsection-types)
5. [Symbol Records](#5-symbol-records)
6. [Line-Number and Correlation Tables](#6-line-number-and-correlation-tables)
7. [Type System](#7-type-system)
8. [Address and Segment Model](#8-address-and-segment-model)
9. [Tooling: TDUMP, TDSTRIP, TDDEBUG](#9-tooling-tdump-tdstrip-tddebug)
10. [Contrast with Microsoft CodeView and DWARF](#10-contrast-with-microsoft-codeview-and-dwarf)
11. [Existing Open-Source Parsers](#11-existing-open-source-parsers)
12. [Implementation Guidance for the Zig Parser](#12-implementation-guidance-for-the-zig-parser)
13. [References](#13-references)

---

## 1. Scope and Versioning

### What BCC 3.1 produces

Borland C++ 3.1 ships with **TLINK 5.1** (internal: "5.0" in header). When linked with
`TLINK /v` (or equivalently the IDE option "Include debug information"), the linker appends a
block of **Turbo Debugger Symbols (TDS)** to the end of the DOS MZ executable. The compiler
itself must also be invoked with `-v` (or IDE option "Debug information in OBJs") to emit
per-object OMF debug records that TLINK collects and reshapes.

### Version number emitted **[DOCUMENTED via VOGONS]**

The debug block carries a 2-byte BCD version field. BCC 3.0 and BCC 3.1 both produce **TDS
version 3.10** (bytes `0x10, 0x03` = BCD 3.10). The full 4-byte trailer bytes at the very
beginning of the debug block are:

```
FB 52 10 03
```

- `FB 52` = signature word 0x52FB (little-endian)
- `10 03` = version word 0x0310 (BCD: version 3.10)

### TLINK / TDS version table **[DOCUMENTED via VOGONS survey]**

| TLINK version | Internal header | Produces TDS | Product(s)                           |
|---------------|-----------------|--------------|--------------------------------------|
| 1.0 / 1.1     | 1.0             | None         | Turbo C 1.0, 1.5                     |
| 2.0a / 2.0b   | 2.0             | 2.8          | Turbo C 2.0, TASM 1.0                |
| 3.0 / 3.01    | 3.0             | 2.9          | TASM 2.0, TC++ 1.0                   |
| 4.0           | 3.0             | 3.0          | Borland C++ 2.0                      |
| **5.0 / 5.1** | **5.0**         | **3.10**     | **Borland C++ 3.0, 3.1 ← target**   |
| 6.00          | 5.0             | 4.1          | TASM 4.0, Borland C++ 4.0           |
| 7.0a          | 6.1             | 4.1          | Borland C++ 4.5, 4.52               |
| 7.1.30.1      | 7.1             | 4.3          | TASM 5.0                            |
| 7.1.32.2      | 7.1             | 4.3          | Borland C++ 5.0, 5.02               |

There is no evidence of a TDS 4.2; the sequence jumps from 4.1 to 4.3.

### Two distinct format families — do not confuse them

There are **two different Borland debug formats** in circulation. Implementers frequently
conflate them.

| Property           | **16-bit TDS** (this document)            | **32-bit TD32**                             |
|--------------------|-------------------------------------------|---------------------------------------------|
| Signature          | 2-byte word `0x52FB`                      | 4-byte ASCII string `"FB09"` or `"FB0A"`    |
| Versions           | 2.8 / 2.9 / 3.0 / 3.10                   | 4.1 / 4.3                                   |
| Targets            | 16-bit DOS MZ EXE                         | 32-bit Windows PE EXE (Delphi, C++Builder)  |
| Produced by        | BCC 3.x, TC++ 1-3, TASM 1-4              | BCC 4.x+, Delphi 2+                        |
| Structure          | Flat sequential tables, proprietary       | CodeView-compatible directory + subsections |
| Primary reference  | Borland Open Architecture Handbook (BOA)  | BOA (newer), JclTD32.pas, tds2dbg           |

The **zdos target (BCC 3.1 / KRONLINK.EXE)** uses the 16-bit TDS 3.10 format exclusively.
Everything below describes that format unless explicitly noted.

### Differences between TDS 2.x and TDS 3.10 **[DOCUMENTED]**

According to the BOA, the main changes from 2.x to 3.10 were:
- Field sizes and arrangements were modified to maintain natural alignment of data.
- Signatures were added/changed to indicate the version of symbolic information.
- Format of symbol and type records and the organization of related segments were changed.
- C++ class/browser extensions were added (the extension header at offset 0x30).

---

## 2. Container and Location in MZ EXE

### Where the debug block lives **[DOCUMENTED]**

The debug block is **appended after the MZ load image**. It is not part of the load image
itself; the DOS loader ignores everything past the image. The image size is determined by the
two MZ header fields:

```
image_size_bytes = (MZ.e_cp - 1) * 512 + MZ.e_cblp
                   (if e_cblp == 0: image_size_bytes = MZ.e_cp * 512)
```

The debug block starts at `image_size_bytes` from the start of the file. (Note: if
`image_size_bytes` is not `MZ.e_cparhdr * 16 + MZ.e_minalloc * 16 + ... `, be careful—use the
`image_size` field in the debug header itself to cross-check).

### Locating the block at load time **[DOCUMENTED / INFERRED]**

The debug block's first 4 bytes are:

```
[offset 0x00, 2 bytes] = 0x52FB  (signature, always this value)
[offset 0x02, 2 bytes] = version in BCD (e.g., 0x0310 for TDS 3.10)
```

**Important nuance on MZ header field semantics**: Whether TLINK includes the debug block in
`e_cp`/`e_cblp` or not varies by TLINK version and is **[UNCERTAIN]**. Two strategies:

**Strategy A — use MZ-derived total file size** (works if TLINK includes debug block):
1. `total_file = (MZ.e_cp - 1) * 512 + MZ.e_cblp` (if `e_cblp != 0`)
   or `total_file = MZ.e_cp * 512` (if `e_cblp == 0`)
2. The debug block's end is at `total_file`. Since you don't know the debug block size yet,
   seek to what you think is the image end and look for 0x52FB.
   For Borland 3.1: the load image (header + code/data) ends at
   `MZ.e_cparhdr * 16 + image_size_in_memory`. But `image_size_in_memory` is not the same
   as MZ's `e_cp` calculation.

**Recommended strategy for zdos** — the most robust method:
1. Compute the "official" file content end: `declared_end = (e_cp-1)*512 + e_cblp`
   (or `e_cp*512` if `e_cblp==0`).
2. Seek to `declared_end` and check for signature `0x52FB`. If found: debug block starts here.
3. If not found at that offset: scan backwards from `file_size - 4` in 2-byte steps looking
   for `0x52FB`. This handles TLINK versions that do or don't include the debug block in
   `e_cp`/`e_cblp`.
4. As a cross-check: once you've found the debug block and parsed its `image_size` field
   (offset 0x20 in the debug header), verify that
   `debug_block_start == file_start + MZ.e_cparhdr * 16 + image_size` (approximately).

**DO NOT** assume the debug block is at a fixed offset from the beginning of the file without
verifying the signature first. The debug block's location is content-determined.

Once the debug block is found:
- Read 2 bytes; verify they equal `0x52FB` (fail gracefully if not).
- Read the next 2 bytes as the BCD version (log it; compare against 0x0310 for BCC 3.1).

### Standalone .TDS sidecar file **[DOCUMENTED]**

When the EXE is stripped with `TDSTRIP -s` (strip-to-sidecar), the debug block is removed
from the EXE and written to a companion file with the `.TDS` extension. The `.TDS` file starts
immediately with `0x52FB` and contains the same block that was appended to the EXE. The EXE
loses all debug information; the TDS file contains it all.

When `TDSTRIP` is run without `-s`, it removes the debug block entirely (no sidecar). The EXE
shrinks by the debug block size.

The standalone `.TDS` file layout is identical byte-for-byte to the embedded block: it begins
with the 4-byte header (signature + version) and continues with the rest of the structure
described below.

### What TDSTRIP does **[DOCUMENTED]**

TDSTRIP modifies the MZ EXE in-place:
- Reads the MZ header and recalculates `e_cp`/`e_cblp` to reflect the smaller image.
- Zeroes out or truncates everything past `image_size_bytes`.
- With `-s`: copies the debug block to a `.TDS` file before truncating.
- Does NOT relink; it is a pure binary editor.

### Alignment **[UNCERTAIN]**

No alignment requirement for the debug block start is documented. It typically starts at the
next byte after the image with no padding, but **TODO-TDUMP**: verify there is no 16-byte
paragraph alignment.

---

## 3. Top-Level Structure: The Debug Block Header

The debug block begins with a fixed-size header. This header describes the size and count of
each table that follows. **[DOCUMENTED via BOA / excbadacc.es / faydoc.tripod.com]**

### Main header (always present)

```
Offset  Size  Field                    Description
------  ----  -----                    -----------
0x00    WORD  signature                Always 0x52FB
0x02    WORD  version                  BCD version (e.g., 0x0310 = TDS 3.10)
0x04    DWORD names_size               Size of the name pool in bytes
0x08    WORD  names_count              Number of names in the name pool
0x0A    WORD  types_count              Number of type records in the type table
0x0C    WORD  members_count            Number of struct/union member records
0x0E    WORD  symbols_count            Number of symbol records (module-local)
0x10    WORD  globals_count            Number of global symbol records
0x12    WORD  modules_count            Number of module records
0x14    WORD  locals_count             Number of local variable records (optional)
0x16    WORD  scopes_count             Number of scope/block records
0x18    WORD  lines_count              Number of line-number table entries
0x1A    WORD  source_count             Number of source file (include) records
0x1C    WORD  segment_count            Number of segment records
0x1E    WORD  correlation_count        Number of segment/file correlation records
0x20    DWORD image_size               Load image size (after removing uninit data and debug)
0x24    DWORD debugger_hook            Pointer into debugged program (meaning depends on flags)
0x28    BYTE  program_flags            Bit 0: case-sensitive link; Bit 1: Pascal overlay program
0x29    WORD  stringsegoffset          Deprecated (no longer used)
0x2B    WORD  data_count               Size of data pool in bytes
0x2D    BYTE  filler1                  Padding byte
0x2E    WORD  extension_size           Size of optional header extension (0x00, 0x10, or 0x20)
```

Total base header size: 0x30 bytes (48 bytes).

### Extended header (if extension_size >= 0x10)

Present when `extension_size` > 0. Starts immediately after the base header at offset 0x30:

```
Offset  Size  Field                    Description
------  ----  -----                    -----------
0x30    WORD  class_entries            Number of C++ class entries
0x32    WORD  parent_entries           Number of parent class entries
0x34    WORD  global_classes           Number of global class entries
0x36    WORD  overload_count           Number of overloaded name entries
0x38    WORD  scope_class_entries      Scope-class associations
0x3A    WORD  module_class_entries     Module-class associations
0x3C    WORD  coverage_offset_count    Number of coverage offset entries
0x3E    DWORD name_pool_offset         Offset of name pool from start of debug block
0x42    WORD  browser_entries          Number of class browser entries
0x44    WORD  opt_sym_entries          Number of optimized symbol records
0x46    WORD  debug_flags              Debug flags
0x48    DWORD ref_info_size            Size of reference info in bytes
0x4C    14*BYTE filler2               Padding
```

If `extension_size == 0x20`, an additional 0x10 bytes (16 bytes) are present after the above.
**[UNCERTAIN]**: The exact fields for the second extension block are not confirmed; TODO-TDUMP.

For TDS 3.10 (BCC 3.1), the extension header is present with basic C++ browser fields. For
TDS 2.9 and earlier, `extension_size == 0` and no extension is present.

### Data tables layout in the file **[INFERRED]**

Following the header (at byte offset 0x30 + extension_size, rounded up if needed),
the tables are stored sequentially. The order, inferred from the BOA chapter structure and
parser implementations, is:

```
[header + extensions]
[type table]          — types_count entries of variable size
[member table]        — members_count entries (struct/union/enum members)
[symbol table]        — symbols_count local symbol records
[global symbol table] — globals_count global symbol records
[module table]        — modules_count module records
[locals table]        — locals_count local variable records
[scope table]         — scopes_count scope/block records
[line number table]   — lines_count line-number entries
[source file table]   — source_count source file records
[segment table]       — segment_count segment records
[correlation table]   — correlation_count correlation records
[name pool]           — names_size bytes of null-terminated strings
```

**[UNCERTAIN]**: This order is inferred. The `name_pool_offset` field in the extension header
provides the absolute offset of the name pool from the start of the debug block. For TDS 3.10,
use that if available; for TDS 2.9, the name pool is simply at the end after all other tables.
**TODO-TDUMP**: Verify table order empirically with a real BCC 3.1 binary.

---

## 4. Record and Subsection Types

Unlike the 32-bit TD32 format (which has a CodeView-style directory of named subsections),
the 16-bit TDS format does NOT use a directory or named subsections. All tables are flat
sequential arrays; the header tells you how many entries each table has and (by fixed record
sizes or by offsets) where each starts.

### 4.1 Name Pool (string table)

The name pool is a flat byte array of null-terminated C strings packed end-to-end. Names are
referenced by a 1-based index (name index 1 = first string, etc.). To retrieve name N:

```
Skip N-1 null-terminators from the start of the pool.
The name starts at the next byte after the (N-1)th null.
```

Name index 0 means "no name" / anonymous.

**String encoding**: Plain ASCII, null-terminated. No length prefix. Maximum name length is
not documented but is practically limited to ≤255 chars. **[INFERRED]**

### 4.2 Type Table

Each entry in the type table is a **type record** of variable length. A type record describes
one complex type (pointer, array, struct, etc.). The record begins with a 1-byte **type kind**
byte (the TID_ constant), followed by type-kind-specific fields.

Type indices work as follows **[DOCUMENTED via BOA snippet]**:
- Indices 0x00 through 0x17 (0–23 decimal) are **predefined primitive types** — no record
  appears in the type table for them; they are encoded directly by their index value.
- Indices 0x18 (24) and above are **complex type indices**: the entry at position
  `(index - 0x18)` in the type table describes the type.

**Predefined primitive types (index 0x00–0x17)** **[DOCUMENTED via BOA; note: two
slightly different numbering schemes appear in sources — these are the values cross-checked
against the most frequently cited source]**:

```
Index  TID constant    Description
-----  ------------    -----------
0x00   TID_VOID        void (unknown/void type)
0x01   TID_LNEAR       Near function pointer (Pascal-style)   [UNCERTAIN]
0x02   TID_LFAR        Far function pointer (Pascal-style)    [UNCERTAIN]
0x03   TID_VOID2       Alternate void representation          [UNCERTAIN]
0x04   TID_SCHAR       Signed 8-bit integer (char)
0x05   TID_SINT        Signed 16-bit integer (int/short)
0x06   TID_SLONG       Signed 32-bit integer (long)
0x07   TID_SQUAD       Signed 64-bit integer                  [UNCERTAIN]
0x08   TID_UCHAR       Unsigned 8-bit integer (unsigned char)
0x09   TID_UINT        Unsigned 16-bit integer (unsigned int)
0x0A   TID_ULONG       Unsigned 32-bit integer (unsigned long)
0x0B   TID_UQUAD       Unsigned 64-bit integer                [UNCERTAIN]
0x0C   TID_PCHAR       Pascal char (1 byte)                   [UNCERTAIN]
0x0D   TID_FLOAT       IEEE 32-bit real (float)
0x0E   TID_TPFLOAT     Turbo Pascal 6-byte real               [UNCERTAIN]
0x0F   TID_DOUBLE      IEEE 64-bit real (double)
0x10   TID_LDOUBLE     IEEE 80-bit extended real (long double)
0x11   TID_BCD4        4-byte BCD                             [UNCERTAIN]
0x12   TID_BCD8        8-byte BCD                             [UNCERTAIN]
0x13   TID_BCD10       10-byte BCD                            [UNCERTAIN]
0x14   TID_BCDCOB      COBOL BCD                              [UNCERTAIN]
0x15   TID_DATE        Date type                              [UNCERTAIN]
0x16   TID_TIME        Time type                              [UNCERTAIN]
0x17   TID_BOOL        Boolean (Pascal)                       [UNCERTAIN]
```

Note: indices 0x01–0x03 and 0x0B–0x17 carry significant uncertainty; the ones that matter
most for C programs are 0x00 (void), 0x04 (char), 0x05 (int), 0x06 (long), 0x08 (unsigned
char), 0x09 (unsigned int), 0x0A (unsigned long), 0x0D (float), 0x0F (double), 0x10 (long
double). **TODO-TDUMP**: Confirm by compiling a program that uses each type and examining the
symbol type indices in TDUMP output.

**ALTERNATIVE numbering seen in BOA snippets** (1-based, possibly for a different TDS sub-version):

```
Index  Type
1      void
2      signed char
4      signed short int
6      signed long int
8      unsigned char
10     unsigned short int
12     unsigned long int
14     float
15     double
16     long double
23     10-byte value (tbyte / COBOL BCD)
```

The discrepancy between 0-based (`TID_SCHAR = 0x04`) and 1-based (`signed char = index 2`)
representations is not yet reconciled. **TODO-TDUMP**: Inspect a symbol's `symbol_type` WORD
field that refers to a `char` variable; the hex value of that WORD is the ground truth.

### 4.3 Type record layouts for complex types

Each entry (index >= 0x18) in the type table starts with:

```
Offset  Size  Field         Description
0x00    BYTE  type_kind     TID_ code for this record kind
```

Then type-kind-specific data follows. Known complex type record kinds
**[DOCUMENTED via BOA / excbadacc.es]**:

#### Near pointer (TID_NEARP = 0x10) **[UNCERTAIN exact value; TODO-TDUMP]**

```
+0  BYTE  type_kind = TID_NEARP
+1  WORD  pointee_type    type index of the type being pointed to
```

#### Far pointer (TID_FARP = 0x11) **[UNCERTAIN]**

```
+0  BYTE  type_kind = TID_FARP
+1  WORD  pointee_type
```

#### Huge pointer (TID_HUGEP = 0x12) **[UNCERTAIN]**

```
+0  BYTE  type_kind = TID_HUGEP
+1  WORD  pointee_type
```

#### Array (TID_ARRAY = 0x13) **[UNCERTAIN exact value]**

```
+0  BYTE  type_kind = TID_ARRAY
+1  WORD  element_type    type index of element
+3  WORD  index_type      type of index variable (usually TID_UINT)
+5  WORD  size            total byte size of array
+7  WORD  element_count   number of elements
```

#### Very-large array (TID_VLARRAY = 0x1B) **[DOCUMENTED]**

Used when the array exceeds 64 KB. Contains an extra high-word for size.

```
+0  BYTE  type_kind = TID_VLARRAY (0x1B)
+1  WORD  element_type
+3  WORD  index_type
+5  WORD  size_lo         lower 16 bits of total size
+7  WORD  element_count
+9  WORD  size_hi         upper 16 bits: (size_hi << 16) | size_lo = total bytes
```

#### Struct (TID_STRUCT = 0x17) **[UNCERTAIN exact value]**

```
+0  BYTE  type_kind = TID_STRUCT
+1  WORD  member_count    number of members
+3  WORD  field_type      index into member table for first member
+5  WORD  size            size of struct in bytes
+7  WORD  name_index      name pool index (for tagged structs)
```

#### Very-large struct (TID_VLSTRUCT = 0x20) **[DOCUMENTED]**

For structs >= 64 KB:
```
+0  BYTE  type_kind = TID_VLSTRUCT (0x20)
+1  WORD  member_count
+3  WORD  field_type
+5  WORD  size_lo
+7  WORD  name_index
+9  WORD  size_hi
```
Combined: `dword_size = (size_hi << 16) | size_lo`.

#### Union (TID_UNION = 0x18) **[UNCERTAIN exact value]**

Similar layout to struct; size is the size of the largest member.

#### Very-large union (TID_VLUNION = 0x21) **[DOCUMENTED]**

Same as TID_VLSTRUCT but for unions.

#### Enum (TID_ENUM = 0x19) **[UNCERTAIN exact value]**

```
+0  BYTE  type_kind = TID_ENUM
+1  WORD  member_count
+3  WORD  field_type      first member in member table
+5  WORD  base_type       underlying integral type
+7  WORD  name_index
```

#### Function / procedure (TID_FUNCTION = 0x14) **[UNCERTAIN]**

```
+0  BYTE  type_kind = TID_FUNCTION
+1  BYTE  calling_conv    calling convention (0=C near, 1=C far, 4=Pascal near, ...)
+2  WORD  return_type     return type index
+4  WORD  parm_count      number of formal parameters
+6  WORD  parm_types[N]   N entries of WORD type indices (variable length)
```

#### Label (TID_LABEL = 0x15) **[UNCERTAIN]**

```
+0  BYTE  type_kind = TID_LABEL
+1  BYTE  near_far        0 = near, 1 = far
```

#### Membership (struct member record, in member table)

Each entry in the **member table** describes one member of a struct/union/enum:

```
Offset  Size  Field         Description
0x00    WORD  name_index    name pool index for member name
0x02    WORD  type_index    type index of the member
0x04    WORD  offset        byte offset within struct (for struct/union)
                            or integer value (for enum members)
```

Size: 6 bytes per member entry. **[UNCERTAIN]**: TODO-TDUMP to confirm exact size.

---

## 5. Symbol Records

There are two symbol tables: the **local symbol table** (per-module, `symbols_count` entries)
and the **global symbol table** (`globals_count` entries). Both use the same record format.

### Symbol record format **[DOCUMENTED via BOA / excbadacc.es]**

```
Offset  Size  Field               Description
0x00    WORD  name_index          1-based index into name pool
0x02    WORD  type_index          type index (predefined if < 0x18, else complex)
0x04    WORD  symbol_offset       offset within its segment
0x06    WORD  symbol_segment      1-based logical segment number (0 = unknown/extern)
0x08    BYTE  flags               Packed bit field (see below)
```

Total: 9 bytes per record.

The `flags` byte at offset 0x08 is packed as follows:

```
Bits 2:0  (3 bits)  symbol_class        Storage class
Bit  3    (1 bit)   has_valid_bp        1 if a valid BP-relative address exists
Bits 6:4  (3 bits)  return_word_offset  Stack words used as return address
Bit  7    (1 bit)   reserved
```

**symbol_class values** **[UNCERTAIN — partial; TODO-TDUMP for complete enum]**:

```
0  = sLocal / auto                      (BP-relative local variable)
1  = sStatic                            (static in file/function scope)
2  = sGlobal / extern                   (globally visible, in data segment)
3  = sRegister                          (register variable)
4  = sCode (near label/function)        (in code segment)
5  = sCode far                          (far code label/function)
6  = sUndefined                         [UNCERTAIN]
7  = sPublic                            [UNCERTAIN]
```

### Interpreting symbol addresses

- If `symbol_class == sLocal` (BP-relative): the address is **not** in `symbol_offset`/
  `symbol_segment`. Instead, `symbol_offset` is a signed WORD giving the BP-relative stack
  offset (positive = above BP, negative = below BP, i.e., local variable). `symbol_segment`
  is unused or zero in this case. The `has_valid_bp` flag confirms this.

- If `symbol_class == sGlobal` or `sStatic`: `symbol_segment` is the 1-based logical segment
  number, and `symbol_offset` is the byte offset within that segment. Together they give
  an image-relative address (see Section 8 for how to map to runtime).

- If `symbol_class == sRegister`: `symbol_segment` encodes the register number. The exact
  encoding is **[UNCERTAIN]**; TODO-TDUMP.

### Register variable encoding **[UNCERTAIN]**

For register variables, the `symbol_segment` field likely encodes the x86 register:
```
0 = AX, 1 = CX, 2 = DX, 3 = BX, 4 = SP, 5 = BP, 6 = SI, 7 = DI
(byte registers: AL=8, CL=9, DL=10, BL=11 ...)
```
This is **[TODO-TDUMP]** to confirm.

---

## 6. Line-Number and Correlation Tables

Line-number info in the 16-bit TDS format is stored in two separate structures:
the **source file table** and the **correlation table**, plus the **line number table**.

### Source file records

Each source file record corresponds to one source file (including included headers):

```
Offset  Size  Field         Description
0x00    WORD  name_index    name pool index for the file path
```

Size: 2 bytes per entry. **[UNCERTAIN]**: There may be additional fields; TODO-TDUMP.

### Segment records

A segment record describes one logical code or data segment:

```
Offset  Size  Field         Description
0x00    WORD  segment_num   The OMF-level segment number (maps to OMF SEGDEF)
0x02    WORD  flags         Bit 0: 0=data, 1=code  [UNCERTAIN bit interpretation]
0x04    WORD  size          Size of segment in bytes
```

Size: **[UNCERTAIN]** — approximately 6 bytes. TODO-TDUMP.

### Correlation records

A correlation record ties a range of line-number entries to a specific source file and segment:

```
Offset  Size  Field         Description
0x00    WORD  source_index  1-based index into source file table
0x02    WORD  segment_index 1-based index into segment table
0x04    WORD  lines_start   first index into line-number table for this range
0x06    WORD  lines_count   number of line-number entries in this range
```

Size: 8 bytes per entry. **[UNCERTAIN]**: TODO-TDUMP.

### Module → source file and correlation relationship

Each module record references a range of source file records and a range of correlation
records. The correlation records link line-number ranges to segments. To map a line in a
source file to a code address:

1. Find the module containing the source file.
2. Find the correlation records for that module.
3. Filter correlations by source file index.
4. Look up the line-number entries in those correlations.

### Line number entries **[PARTIALLY DOCUMENTED]**

Line number entries are **delta-encoded**. Each entry gives a delta from the previous line
number (starting at 0 for the first entry in a correlation range) and an address offset within
the segment.

From the BOA (as cited in search results, single source):

```
Each line number is stored as a delta from the previous line number.
The delta by default is stored in a byte:
  - Bits 5:0 (6 bits): line number delta
  - Bit 6 (1 bit): escape / overflow flag
  - Bit 7 (1 bit): reference/assignment toggle [UNCERTAIN interpretation]

If bit 6 is set (overflow or special), additional bytes follow.
```

However, the address associated with each line-number entry is **[UNCERTAIN]**. Two possible
formats exist:

**Format A** (offset only, paired with a separate offset array):
```
WORD  line_offset    offset within segment for this line
WORD  line_delta     packed delta (see above)
```

**Format B** (compact):
```
BYTE  line_delta     packed delta byte
WORD  offset         offset within segment
```

**TODO-TDUMP**: Run `TDUMP -d yourfile.exe` on a BCC 3.1 binary and examine the line table
output to determine the exact layout.

---

## 7. Type System

### Overview

The 16-bit TDS type system has three layers:
1. **Predefined/primitive types**: indices 0x00–0x17, no records in the type table.
2. **Complex types**: indices 0x18+, described by records in the type table.
3. **Type references**: every symbol, member, and type record that references a type uses
   a WORD type index.

### Calling conventions **[INFERRED from BOA / tds2dbg]**

In function type records, the calling convention byte encodes:
```
0 = C near call (cdecl, near model)
1 = C far call (cdecl, far model)
2 = Pascal near
3 = Pascal far
4 = Fortran near   [UNCERTAIN]
5 = Interrupt       [UNCERTAIN]
...
```

### C++ types (TDS 3.10 extension)

TDS 3.10 adds C++ class types. These are encoded as struct-like records but use the C++ class
extension fields in the extended header (class_entries, parent_entries, etc.). The exact
encoding of vtable pointers, base class lists, and virtual function tables is **[UNCERTAIN]**
and goes beyond what most implementations (including MVP zdos) need.

---

## 8. Address and Segment Model

This section is **CRITICAL** for the zdos implementation.

### How TDS uses segment numbers

The 16-bit TDS format uses **1-based logical segment indices**. These correspond to the
physical segments laid out by TLINK, which in turn originate from the OMF SEGDEF records in
each `.OBJ` file.

A symbol record's `(symbol_segment, symbol_offset)` pair gives an **image-relative address**:
- `symbol_segment` is the 1-based index of the logical segment (from the segment table).
- `symbol_offset` is the byte offset within that segment.

The segment table records give additional information (see Section 6) about what each segment
is (code vs. data) and its size.

### DOS MZ relocation and runtime segment mapping

When DOS loads a 16-bit MZ EXE:
1. DOS selects a paragraph address `LOAD_PARA` for the PSP.
2. The EXE image starts at paragraph `LOAD_PARA + 0x10` (16 paragraphs for the PSP).
3. For each entry in the MZ relocation table, DOS adds `LOAD_PARA + 0x10` to the stored
   segment word at that location.

For the debugger to map a debug-info address to a runtime address:

```
runtime_linear = (LOAD_PARA + 0x10) * 16 + segment_image_offset + symbol_offset
```

Where `segment_image_offset` is the linear byte offset from the start of the image to the
beginning of that logical segment.

In 16:16 segment:offset notation:
```
runtime_segment = (LOAD_PARA + 0x10) + (segment_image_offset >> 4)
runtime_offset  = symbol_offset + (segment_image_offset & 0xF)
```

(Assuming the segment is paragraph-aligned within the image, which is the common case; if
not, adjust accordingly.)

The key insight: **`LOAD_PARA` is not known until runtime**. The zdos DOS emulator tracks the
segment where it loaded the image. The formula above requires the emulator to know:
- `LOAD_PARA` (tracked by zdos as the MCB/PSP allocation address)
- `segment_image_offset` for each TDS segment index (from the segment table or from the OMF
  segment map, which TLINK encodes)

### Getting segment_image_offset **[PARTIALLY INFERRED]**

The TDS segment table has `segment_count` entries. Each entry encodes:
- The OMF logical segment number.
- Its size.

The segment table does NOT necessarily encode the image-relative linear offset. However,
TLINK produces a MAP file (`TLINK /m`) that lists the final segment addresses explicitly.
Cross-referencing the TDS segment indices with the MAP file is a reliable way to establish
the offset table during implementation and testing.

Alternatively: the OMF `SEGDEF` records in the OBJ files, combined with the linker-resolved
segment addresses visible in the MZ relocation table, allow computing `segment_image_offset`
for each segment.

### DGROUP and the data segment

Borland C++ typically groups all data segments into a group called `DGROUP`. In the 16-bit
small/compact/medium models:
- `DS` at runtime points to `DGROUP`.
- All global and static variables' `symbol_segment` values point to segments within DGROUP.

For the zdos MVP, the practical mapping approach is:
1. Parse the TDS segment table to enumerate TDS-segment-index → OMF-segment-number.
2. Read the MZ MAP file (produced by `TLINK /m`) to get the linear image address of each
   OMF segment at link time.
3. At runtime, adjust each segment's address by adding `(LOAD_PARA + 0x10) * 16` minus the
   link-time image base address (usually 0).

### Address mapping formula (for zdos implementation)

```
# Given:
#   tds_segment    — 1-based TDS segment index from a symbol record
#   tds_offset     — offset within that segment from a symbol record
#   load_para      — paragraph address assigned by DOS loader (from MCB tracking)
#   seg_tbl[i]     — map from TDS segment index to image_linear_offset (built at parse time)

image_linear  = seg_tbl[tds_segment] + tds_offset
runtime_seg   = (load_para + 0x10) + (image_linear >> 4)
runtime_off   = image_linear & 0xF   # (if segment is para-aligned, runtime_off ≈ tds_offset)
runtime_flat  = runtime_seg * 16 + runtime_off  # flat 20-bit address
```

For line-number correlation:
- The correlation record's `segment_index` gives the TDS segment.
- Line table entries give offsets within that segment.
- Apply the same formula to obtain the runtime address for each source line.

---

## 9. Tooling: TDUMP, TDSTRIP, TDDEBUG

### TDUMP **[DOCUMENTED]**

`TDUMP.EXE` ships with Borland C++ and displays the structure of EXE, OBJ, and LIB files,
including debug information content.

Key invocations:
```
TDUMP yourfile.exe        # show EXE header, relocation table, debug info
TDUMP -b100 yourfile.exe  # start hex dump at offset 0x100
TDUMP yourfile.obj        # show OMF records in object file
TDUMP -oc yourfile.obj    # validate CRC checksums on OBJ records
```

When run on a debug EXE, TDUMP displays:
- The debug block header with all count fields
- Each module with its symbol range and source file range
- Symbol records (name, type, offset, segment, class)
- Type records (type kind, size, members)
- Line number tables (file : line : offset)

**For zdos implementation**: Use TDUMP output as ground truth to verify your parser.
Specifically compare:
1. The count fields in your parsed header vs. TDUMP's counts.
2. A handful of symbol records: name, segment, offset.
3. A few source lines: verify address mapping produces the correct runtime address.

TDUMP is a 16-bit DOS-extended application; run it in DOSBOX or on a real DOS system with
the same Borland tools.

### TDSTRIP **[DOCUMENTED]**

```
TDSTRIP yourfile.exe          # remove debug info, shrink EXE
TDSTRIP -s yourfile.exe       # remove debug info, write yourfile.TDS sidecar
TDSTRIP -c yourfile.exe yourfile.com  # strip and convert (for COM files from EXE)
```

TDSTRIP ships separately from TDUMP and modifies the MZ EXE in-place. It adjusts `e_cp` and
`e_cblp` in the MZ header.

### TDDEBUG / TD.EXE **[DOCUMENTED]**

Turbo Debugger (`TD.EXE`, 16-bit DOS) automatically loads TDS debug info from either the
embedded block in the EXE or the companion `.TDS` file (it searches both). When loaded:
- Source files are displayed and can be browsed.
- Breakpoints can be set by source line.
- Local variables and their types are shown in the locals window.
- The CPU window shows disassembly with symbol annotations.

For implementation verification, running `TD yourfile.exe` and observing what it displays
provides strong empirical evidence that your parser is correct if it agrees.

---

## 10. Contrast with Microsoft CodeView and DWARF

### Borland 16-bit TDS vs. Microsoft CodeView (CV3/CV4, NB0x signatures)

| Property                  | Borland 16-bit TDS (0x52FB)                | Microsoft CodeView (NB0x)                     |
|---------------------------|---------------------------------------------|-----------------------------------------------|
| Signature                 | 2-byte word 0x52FB at start of debug block  | 4-byte ASCII "NB04"/"NB09" at end of section  |
| Discovery                 | Block appended at image_size offset          | Trailing 8-byte footer pointing to directory  |
| Directory structure       | No directory; flat sequential count tables  | Explicit subsection directory with offsets    |
| Subsection types          | Implicit by table position in file          | Named (0x120=MODULE, 0x127=SRCMODULE, etc.)   |
| Name storage              | Flat null-terminated pool, 1-based index    | 0-byte-length-prefixed or zero-terminated     |
| Type indices              | 0x00–0x17 = predefined; 0x18+ = complex     | 0x0000–0x0FFF = special; above = index        |
| Symbol record header      | No length prefix; fixed-size fields         | 2-byte length + 2-byte type                   |
| Line number format        | Delta-encoded per correlation record        | Pairs of (offset, line) arrays per segment    |
| BP-relative encoding      | Signed WORD offset in `symbol_offset`       | Signed DWORD in dedicated BPREL record        |
| 32-bit mode               | Not supported (16-bit only)                 | Fully 32-bit capable (NB09 / PDB)             |
| Public access             | Partially documented (BOA)                  | Documented by Microsoft                       |

**Critical distinction**: CodeView NB09 (used in 32-bit Microsoft linkers) is completely
different from Borland's 32-bit TD32 format (FB09/FB0A), even though both use "NB09" in some
contexts. Borland's 32-bit format *borrows the directory structure* from CodeView but uses
different record types and name encoding. Do not confuse them.

The 16-bit TDS (0x52FB) format is Borland's own unique format with no structural relationship
to CodeView NB-formats. The tds2dbg project explicitly converts TDS → CodeView DBG format,
which requires a full semantic translation.

### Borland 16-bit TDS vs. DWARF/stabs

| Property                  | Borland 16-bit TDS                        | DWARF 2+                                      | stabs (ELF)                               |
|---------------------------|-------------------------------------------|-----------------------------------------------|-------------------------------------------|
| Target                    | DOS 16-bit MZ EXE (1990s)                | Unix/Linux ELF, macOS, etc.                   | ELF .stab sections (older Unix)           |
| Location                  | Appended after MZ load image              | Separate ELF sections (.debug_*)              | .stab / .stabstr ELF sections             |
| Type encoding             | Flat table with TID_ identifiers          | TAG-based tree (DIE tree)                     | Stab strings (N_LSYM etc.)                |
| Line numbers              | Delta-encoded correlation records         | DW_LNS_advance_line finite state machine      | N_SLINE stab entries                      |
| Endianness                | Little-endian (x86)                       | Target endianness                             | Target endianness                         |
| Complexity                | Moderate                                  | High (multi-section, abbreviation tables)     | Low (text-based)                          |
| C++ support               | Partial (TDS 3.10 adds class entries)     | Full (templates, namespaces, inheritance)     | Minimal                                   |

The 16-bit TDS format is simpler than DWARF but more complex than stabs. Its closest
conceptual relative is perhaps the original Intel OMF debug record format (LINNUM records).

---

## 11. Existing Open-Source Parsers

### ramikg/tdinfo-parser (IDAPython) **[PRIMARY — 16-bit TDS format]**

- **URL**: https://github.com/ramikg/tdinfo-parser
- **Language**: Python (IDAPython, Construct library)
- **Targets**: 16-bit DOS TDS format (inspired by pwnable.kr dos4fun challenge)
- **Files**: `tdinfo_structs.py` (Construct definitions), `tdinfo_parser.py` (IDA import)
- **Completeness**: **Highest known completeness for the 16-bit format** — parses header,
  name pool, symbol table, type table, module table, and line numbers; imports into IDA.
- **Note**: The `tdinfo_structs.py` file could not be directly fetched during this research
  (404 on raw GitHub CDN path); obtain a local copy via `git clone` and study it as
  implementation ground truth.
- **Reliability**: High (actively maintained, tested on real DOS binaries).

### Josko/tds2pdb (C++) **[SECONDARY — 32-bit TD32 format only]**

- **URL**: https://github.com/Josko/tds2pdb
- **Language**: C++11
- **Targets**: 32-bit TD32 format (FB0A, Windows PE, C++Builder/Delphi)
- **Completeness**: Partial (validates magic, reads directory header; full parsing TBD)
- **Note**: Useful for understanding the 32-bit format but NOT directly applicable to BCC 3.1.

### tds2dbg (C++) **[SECONDARY — 32-bit TD32 format]**

- **URL**: https://sourceforge.net/projects/tds2dbg/
- **Language**: C++
- **Key file**: `tdscvstructs.h` — defines C++ structs for both TDS and CodeView equivalents
- **Targets**: 32-bit TD32 (Windows PE), converts to Microsoft DBG format
- **Completeness**: Reasonably complete for 32-bit; not applicable to 16-bit TDS
- **Reliability**: Good — was actually used for production Delphi debugging

### project-jedi/jcl JclTD32.pas (Pascal) **[SECONDARY — 32-bit TD32 format]**

- **URL**: https://github.com/project-jedi/jcl/blob/master/jcl/source/windows/JclTD32.pas
- **Language**: Object Pascal (Delphi)
- **Targets**: 32-bit TD32 format (FB09 Delphi / FB0A C++Builder)
- **Completeness**: Very complete for 32-bit — full struct definitions, module, source,
  symbol, type parsing
- **Note**: Contains the most comprehensive Pascal struct definitions for the 32-bit format.
  The struct layouts partially guide understanding of the 16-bit format's evolution.

### andremussche/map2dbg tds2pdb (mixed) **[TERTIARY]**

- **URL**: https://github.com/andremussche/map2dbg/tree/master/tds2pdb
- **Language**: Delphi
- **Targets**: 32-bit TD32, Windows PE
- **Completeness**: Partial, derivative of other projects

### GDB snapshot with TDS support (gdbwtds) **[TERTIARY — mixed format]**

- **URL**: https://sourceforge.net/projects/gdbwtds/
- **Language**: C (GDB fork)
- **Targets**: Unclear; based on Troy Rollo's 2001 BFD patch
- **Completeness**: "Rudimentary" per project description
- **Note**: Source contains TDS parsing in `tds.c`/`tds.h` but files could not be fetched
  during this research. The SVN repository is accessible at the SourceForge URL above.

### Troy Rollo's BFD/binutils patch (2001) **[HISTORICAL]**

- **Reference**: https://sourceware.org/legacy-ml/binutils/2001-02/msg00408.html
- **Language**: C (auto-generated from `tds.ds` spec)
- **Note**: The attached files (`bfd-diffs`, `bfd-newfiles.tar.gz`) were not merged into
  binutils mainline and are not easily accessible; they represent the earliest public
  attempt at machine-readable TDS format documentation.

---

## 12. Implementation Guidance for the Zig Parser

### MVP scope for zdos (priority order)

For source-level debugging of KRONLINK.EXE, the minimal useful implementation needs:

1. **Address-to-line mapping**: Given a runtime CS:IP, find the source file and line number.
   Required: parse header, segment table, correlation table, line-number table, source file
   table.

2. **Global/public symbol lookup**: Given a name, find its runtime address; given an address,
   find the nearest symbol name.
   Required: parse header, symbol table (both local and global), segment table, module table.

3. **Function entry/exit**: Given an address, know which function it belongs to.
   Required: same as #2, plus scope records.

**Defer for later**: type graph, local variable decoding (BP-relative), struct member layout,
C++ class browser entries. These require more work for less immediate debugging value.

### Parse-first checklist

```
Step 1: Find the debug block
  - Compute image_size from MZ e_cp/e_cblp
  - Read 2 bytes at that offset; verify == 0x52FB
  - Read version WORD; log it; check for 0x0310

Step 2: Parse the main header (48 bytes)
  - Read all count fields into a struct
  - Log all counts to stderr for verification vs. TDUMP output

Step 3: Determine table offsets
  - base = image_size + 0x30 + extension_size (rounded to alignment if needed)
  - Build offset for each table using cumulative sizes

Step 4: Parse name pool (seek to end, read names_size bytes)
  - Build an ArrayList([]const u8) indexed 1..names_count

Step 5: Parse segment table
  - Read segment_count segment records
  - For each, record: segment_number, flags, size
  - Cross-reference with TLINK MAP file to get image_linear_offset per segment

Step 6: Parse source file table
  - Read source_count records; extract name_index per record

Step 7: Parse correlation table
  - Read correlation_count records

Step 8: Parse line-number table
  - Read lines_count entries; decode delta encoding

Step 9: Build address → line mapping
  - For each correlation: (source_index, segment_index, lines range)
  - For each line entry: decode cumulative line number + offset

Step 10: Parse symbol table
  - Read symbols_count + globals_count records
  - For globals: segment != 0, compute runtime address from segment map

Step 11: Verify against TDUMP output
```

### Endianness and alignment

All multibyte integers are **little-endian** (x86 native). Fields in the header are NOT
necessarily naturally aligned to their size (the header is packed). Use `@bitCast` or packed
structs in Zig, or read individual bytes and assemble.

In Zig 0.16, use `std.mem.readInt(u16, buf[0..2], .little)` for reading WORDs.

### Zig struct definitions (starter)

```zig
// Debug block header — at image_size offset in EXE
const TDSHeader = extern struct {
    signature:         u16,   // Must be 0x52FB
    version:           u16,   // BCD version, e.g., 0x0310
    names_size:        u32,   // Name pool size in bytes
    names_count:       u16,   // Number of names
    types_count:       u16,   // Type table entries
    members_count:     u16,   // Member table entries
    symbols_count:     u16,   // Local symbol entries
    globals_count:     u16,   // Global symbol entries
    modules_count:     u16,   // Module entries
    locals_count:      u16,   // Local variable entries
    scopes_count:      u16,   // Scope entries
    lines_count:       u16,   // Line-number entries
    source_count:      u16,   // Source file entries
    segment_count:     u16,   // Segment records
    correlation_count: u16,   // Correlation records
    image_size:        u32,   // Load image size
    debugger_hook:     u32,   // Debugger hook pointer
    program_flags:     u8,    // Bit 0: case-sensitive; Bit 1: pascal overlay
    _str_seg_offset:   u16,   // Deprecated
    data_count:        u16,   // Data pool size
    _filler1:          u8,    // Padding
    extension_size:    u16,   // Size of optional extension (0, 0x10, or 0x20)
};
comptime { std.debug.assert(@sizeOf(TDSHeader) == 0x30); }

// Symbol record (9 bytes each)
const TDSSymbol = extern struct {
    name_index:    u16,
    type_index:    u16,
    sym_offset:    u16,   // or signed i16 for BP-relative
    sym_segment:   u16,
    flags:         u8,    // class(3) | has_bp(1) | ret_word_offs(3) | reserved(1)
};
comptime { std.debug.assert(@sizeOf(TDSSymbol) == 9); }

// Extract symbol class from flags byte
fn symbolClass(flags: u8) u3 { return @truncate(flags & 0x07); }
fn hasValidBP(flags: u8) bool { return (flags & 0x08) != 0; }
```

### Known gotchas

1. **Type index ambiguity**: When you read a `type_index` of, say, `0x09`, you must check
   whether it's < 0x18 (predefined: TID_UINT = unsigned int) or >= 0x18 (index into type
   table). Do NOT treat all type indices as table offsets.

2. **Line number delta encoding**: The delta encoding is easy to get wrong. Start at line 0
   for each correlation boundary. Each entry adds a delta to the current line. If the high bit
   of the delta byte is set, the interpretation changes (reference vs. assignment toggle).
   Verify each line number against TDUMP output before trusting your decoder.

3. **Name pool 1-based indexing**: Name index 0 = "no name". Don't off-by-one. When you build
   your ArrayList, store `""` at index 0 and real names starting at index 1, OR just use
   `index - 1` as the ArrayList offset.

4. **Segment number 1-based**: TDS segment indices in symbol records are 1-based. Your segment
   table array should be indexed starting at 1, or subtract 1 before lookup.

5. **Table ordering uncertainty**: The order of tables within the debug block is inferred, not
   confirmed from a primary source. If your parser gets confused, the safest strategy is: use
   the `name_pool_offset` field in the extended header (if present) to locate the name pool
   directly by absolute offset, then work backwards to locate other tables. TODO-TDUMP: This
   is the #1 empirical thing to verify first.

6. **Extension size affects base offset**: The data tables start at `0x30 + extension_size`.
   For BCC 3.1, `extension_size` is either `0x10` or `0x20`. Always add it before seeking.

7. **version field BCD interpretation**: The `version` WORD is in BCD. `0x0310` = "3.10"
   (NOT "0x310" = 784 decimal). Parse it as: `major = (version >> 8) & 0xFF;
   minor = version & 0xFF;`. For TDS 3.10: `major = 0x03, minor = 0x10`.

8. **The 32-bit TD32 structs from tds2dbg/JclTD32.pas are NOT applicable here**: They use
   32-bit type indices, 32-bit name indices, and a directory-based structure. Do not use them
   as a model for the 16-bit parser.

### Address mapping in zdos runtime

```zig
// Given:
//   load_para_seg: the PSP paragraph assigned by DOS loader (zdos tracks this)
//   image_para_base: first_segment_paragraph - (PSP+0x10) = 0 for standard images
//   seg_image_offsets: [segment_count]u32  — linear byte offsets built from MAP file

fn runtimeAddress(
    tds_seg: u16,
    tds_off: u16,
    load_para_seg: u16,          // paragraph of PSP
    seg_image_offsets: []u32,    // indexed 0-based: offset [tds_seg-1]
) u32 {
    const image_linear: u32 = seg_image_offsets[tds_seg - 1] + tds_off;
    const image_seg: u16 = @intCast(image_linear >> 4);
    const image_off: u16 = @intCast(image_linear & 0xF);
    const runtime_seg: u32 = @as(u32, load_para_seg) + 0x10 + image_seg;
    return runtime_seg * 16 + image_off;
}
```

---

## 13. References

All sources with reliability notes:

### Primary sources (highest reliability)

1. **Borland Open Architecture Handbook (BOA)** — The canonical Borland specification for the
   debug format and OMF extensions. Available in two related forms:
   - Original text file: `http://download.xskernel.org/docs/file%20formats/omf/borland.txt`
     (URL was 404 during this research; was cited as the definitive text version)
   - Scribd scan (preview only): https://www.scribd.com/document/699553170/Open-Architecture-Handbook-The-Borland-Developer-s-Technical-Guide
   - Scribd scan of debug chapter: https://www.scribd.com/document/699552909/Borland-Symbolic-Debugging-Information
   - BOA4.ZIP / bc4boa.zip — original Borland BBS distribution; covers BC++ 3.x and 4.x
   - **Reliability**: Definitive when accessible; most web sources cite it secondhand.

2. **excbadacc.es/borland** — Reverse-engineering reference page with the complete 16-bit
   TDS header field table and symbol/module record layouts:
   `https://excbadacc.es/borland`
   - **Reliability**: High — matches BOA field names and offsets; independently confirms
     header structure.

3. **faydoc.tripod.com format table** — "Format of Borland debugging information header
   (following load image)": `https://faydoc.tripod.com/structures/16/1624.htm`
   - **Reliability**: High (connection refused during this research; field names match other
     sources). Access via archive.org or alternative network.

4. **VOGONS TLINK/TDS version survey**: `https://www.vogons.org/viewtopic.php?t=110504`
   - Comprehensive empirical survey of TLINK and TDS version bytes in real binaries.
   - **Reliability**: High (community-verified against real binaries).

### Parser source code (high reliability)

5. **ramikg/tdinfo-parser** (IDAPython): `https://github.com/ramikg/tdinfo-parser`
   - Best available open-source parser for the 16-bit TDS format. **Read this first.**
   - `tdinfo_structs.py` contains ground-truth Construct definitions for the 16-bit format.

6. **tds2dbg/tdscvstructs.h** (C++): `https://sourceforge.net/p/tds2dbg/code/HEAD/tree/trunk/tdscvstructs.h`
   - Complete C++ struct definitions for 32-bit TD32 format (NOT the 16-bit format, but
     illuminates the evolutionary relationship).

7. **project-jedi/jcl JclTD32.pas**: `https://github.com/project-jedi/jcl/blob/master/jcl/source/windows/JclTD32.pas`
   - Comprehensive Pascal implementation for the 32-bit TD32 format with full struct
     definitions and parsing code. Very readable.

### Supporting references

8. **Borland newsgroup on TDS documentation**: `https://groups.google.com/g/borland.public.cpp.ide/c/_X-EYT5ZYRU`
   - Community confirms BOA covers FB09 (old) but not FB0A (new); implementation requires
     reverse-engineering.

9. **TDUMP.TXT documentation**: `https://corexor.wordpress.com/tdump-txt/`
   - TDUMP utility documentation; useful for understanding TDUMP invocations.

10. **Troy Rollo's BFD TDS patch (2001)**: `https://sourceware.org/legacy-ml/binutils/2001-02/msg00408.html`
    - Historical: describes the auto-generated `tds.c`/`tds.h`/`tds.ds` parsing code for BFD.
    - The actual files were in the attachment and are not publicly hosted.

11. **GDB with TDS support**: `https://sourceforge.net/projects/gdbwtds/`
    - Based on Troy Rollo's 2001 patch; parses TDS for GDB debugging. Source in SVN.

12. **CodeView format (for contrast)**: VirtualBox codeview.h:
    `https://www.virtualbox.org/svn/vbox/trunk/include/iprt/formats/codeview.h`
    - Complete CodeView struct definitions; critical for understanding what Borland is NOT.

13. **OMF specification (Intel TIS)**: `https://openwatcom.org/ftp/devel/docs/omf.pdf`
    - Ground truth for OMF records (PUBDEF, LINNUM, SEGDEF, GRPDEF) that TLINK processes
      before generating the TDS block.

14. **Wikipedia Borland Turbo Debugger**: `https://en.wikipedia.org/wiki/Borland_Turbo_Debugger`
    - Background/overview; low technical depth.

15. **Bitsavers BCC 3.1 User Guides** (for TDUMP/TDSTRIP documentation):
    - Tools guide: `https://www.bitsavers.org/pdf/borland/borland_C++/Borland_C++_Version_3.1_Tools_and_Utilities_1992.pdf`
    - Users guide: `https://archive.org/details/bitsavers_borlandborn3.1UsersGuide1992_9890437`

---

## Appendix A: Quick-Reference Header Offsets

```
0x00  WORD   signature          = 0x52FB
0x02  WORD   version            BCD (0x0310 for TDS 3.10)
0x04  DWORD  names_size
0x08  WORD   names_count
0x0A  WORD   types_count
0x0C  WORD   members_count
0x0E  WORD   symbols_count
0x10  WORD   globals_count
0x12  WORD   modules_count
0x14  WORD   locals_count
0x16  WORD   scopes_count
0x18  WORD   lines_count
0x1A  WORD   source_count
0x1C  WORD   segment_count
0x1E  WORD   correlation_count
0x20  DWORD  image_size
0x24  DWORD  debugger_hook
0x28  BYTE   program_flags
0x29  WORD   stringsegoffset    (deprecated)
0x2B  WORD   data_count
0x2D  BYTE   filler1
0x2E  WORD   extension_size     → 0, 0x10, or 0x20
[0x30 WORD  class_entries]      ← only if extension_size > 0
[0x3E DWORD name_pool_offset]   ← 8 bytes into extension (offset 0x38 from ext start)
```

## Appendix B: Predefined Type Index Summary

Type indices 0x00–0x17 are predefined. The most important ones for C:

```
0x00  void
0x04  signed char       (char)
0x05  signed int        (int, short)
0x06  signed long       (long)
0x08  unsigned char
0x09  unsigned int      (unsigned, unsigned short)
0x0A  unsigned long
0x0D  float             (IEEE 32-bit)
0x0F  double            (IEEE 64-bit)
0x10  long double       (IEEE 80-bit extended)
```

Type indices 0x18+ → index into type table at position (index - 0x18).

**[UNCERTAIN]**: The exact hex values for 0x01–0x03, 0x0B–0x0C, 0x0E, 0x11–0x17 need
empirical verification with TDUMP.

## Appendix C: Biggest Open Questions (for implementer follow-up)

1. **Table order in the file**: What is the exact order of the sequential tables after the
   header? (Best verified: `git clone ramikg/tdinfo-parser`, read `tdinfo_structs.py`.)

2. **Line number entry exact byte format**: Is it `(WORD offset, BYTE delta)` or
   `(BYTE delta, WORD offset)` or something else? (TDUMP output on real binary is ground truth.)

3. **Predefined type index values**: The hex values 0x00–0x17 and their exact C type
   mappings need one TDUMP run on a BCC 3.1 binary with one `int`, `char`, `long`, `float`,
   `double` variable each.

4. **Segment table record size**: Is it 6 bytes (seg_num, flags, size) or does it include the
   image-relative offset too?

5. **Module record exact size**: Estimated ~14 bytes but not confirmed byte-exact.

6. **TID_ constants for complex type records** (TID_NEARP, TID_FARP, TID_ARRAY, etc.):
   Exact byte values are uncertain. Read `tdinfo_structs.py` or run TDUMP on a binary with
   pointer-to-int, array-of-int, and struct members.
