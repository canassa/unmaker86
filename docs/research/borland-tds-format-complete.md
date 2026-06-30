# Borland C++ 3.1 / TLINK 5.1 — Complete 16-bit TDS (v3.10) Symbolic Debug Format

**Implementation-ready specification for the zdos Zig parser.**

Every structure below was decoded by correlating raw EXE bytes against the TDUMP 3.1 oracle on
the checked-in fixtures in `docs/research/bcc3-fixtures/`:

| Fixture | Build | Exercises |
|---------|-------|-----------|
| `TEST.EXE` (`TEST.C`) | `bcc -v -ms` (small) | 1 struct, 1 global, 2 near functions, coverage=6, include=1 |
| `RICH.EXE` (`F1.C`/`F2.C`/`F3.C`) | `bcc -v -mm` (medium) | 3 modules / 3 code segments, typedef, struct, nested struct, array, near `_DS` pointer, far functions |
| `ENUM.EXE` (`ENUM.C`) | `bcc -v -ml` (large) | enum, union, bitfields, far pointer, huge pointer, function pointer, double/float, large model |
| `CLS.EXE` (`CLS.CPP`) | `bcc -v -ml` (large, C++) | C++ single inheritance, 1 virtual method → Class/Parent/Module-Class tables |
| `MI.EXE` (`MI.CPP`) | `bcc -v -ml` (large, C++) | **multiple inheritance** (3 classes, 2 parents), virtual fns → splits `parent`@0x32 (=2) vs `module_class`@0x3A (=1) |
| `LCLS.EXE` (`LCLS.CPP`) | `bcc -v -ml` (large, C++) | **local class** (class declared inside a function) → populates the Scope-Class table (8 records) |
| `MMC/MMH/MMT.EXE` (`MM.C`) | `bcc -v -mc/-mh/-mt` | compact / huge / tiny memory-model bytes |
| `PTR.EXE` (`PTR.C`) | `bcc -v -ms` (small) | `_es`/`_cs`/`_ss` near pointers; `pascal`/`interrupt`/`cdecl` functions |
| `BENUM.EXE` (`BENUM.C`) | `bcc -v -ms` (small) | two enums (9- and 3-valued, incl. negative) → enum→enumerator linkage |
| `INC.EXE` (`INC.C`+`INCA.H`+`INCB.H`) | `bcc -v -ms` (small) | two code-bearing `#include`s → include-file records + coverage grouping |

Confidence tags: **[C]** = CONFIRMED-EMPIRICALLY (verified vs TDUMP **and** raw bytes, with a full
block-walk reconciling to zero residual at the EOF name pool), **[B]** = CONFIRMED-VIA-BOA (the
Borland Open Architecture Handbook documents the field; BC++ 3.1 emits a count of 0 here so it
cannot be byte-confirmed), **[I]** = INFERRED, **[U]** = UNCERTAIN.

Reproduce: the decoder scripts `decode2.py` (header/block-walk/trailing hexdump), `decode3.py`
(modules/types/members/srcfiles), `decode4.py` (structured trailing-table walk) and `names.py`
live alongside the fixtures; run e.g. `nix-shell -p python3 --run "python3 decode4.py CLS.EXE"`.

Reproduce any table: `nix-shell -p python3 --run "python3 <script>"` against the fixture EXEs.

---

## 0. Critical correction to the prior research (read first)

The earlier `borland-bcc3-debug-format.md` §0.2 claimed **correlation = 16 bytes** and
**member = 7 bytes**, "correcting" the `tdinfo_structs.py` values of 8 and 5. **That correction
is wrong.** The true sizes are **correlation = 8** and **member = 5** — exactly what
`tdinfo_structs.py` originally had.

§0.2 was fooled by an arithmetic coincidence: the EOF-anchored name-pool walk lands on zero
residual under *both* size sets, because the difference is exactly absorbed by trailing tables it
never modelled. (Walk B below splits those trailing bytes as `incl + cov`; that split is itself a
second coincidence — the real trailing tables are coverage-map + coverage-offset + module-opt-flags,
see §0.1/§11. The *totals* and the correlation=8/member=5 conclusion are unaffected.)

```
walk A (wrong): corr(3×16) + types(36×8) + member(12×7)                    = 48+288+84  = 420
walk B (right): corr(3×8)  + types(36×8) + member(12×5) + incl(3×6) + cov(15×2)= 24+288+60+18+30 = 420
```

Both reach the RICH name pool at file offset `0x196a`. Only **walk B decodes to clean data**
(correlation = {seg,src,line-range}, members = x/y/z with correct names and types); walk A yields
garbage. This document uses the verified walk B throughout. `tdinfo_structs.py` was right about
the record sizes; its real gaps were an undecoded module record, the two missing trailing tables,
and no extended-header parsing.

### 0.1 Second correction: the trailing region is **not** "include-files + coverage"  [C]

The earlier pass (and §3/§11 of an interim draft) modelled the bytes between the member table and
the name pool as `srcfiles_count×6` "include-files" records followed by `coverage_count×2`
coverage offsets. **That split is wrong — another arithmetic coincidence.** The trailing region is
actually three tables: **Coverage-Map** (`segments_count × u16`) + **Coverage-Offsets**
(`coverage_count × u16`) + **Module-Optimization-Flags** (`modules_count × u32`). For C programs:

```
TEST  (1 seg, cov=6,  1 mod):  covmap 1×2 + covoff 6×2  + modopt 1×4  = 2+12+4  = 18  (== old 6+12)
RICH  (3 seg, cov=15, 3 mod):  covmap 3×2 + covoff 15×2 + modopt 3×4  = 6+30+12 = 48  (== old 18+30)
```

The old `1×6` / `3×6` "include record" was really `covmap(2) + half of modopt`, and the modopt
dwords (all 0 here) padded the total to the same byte count. The real decode is verified to **zero
residual** with clean data on every fixture: RICH's covmap = `{1, 6, 13}` (per-segment 1-based
start indices into the 15-entry coverage-offset table → segment 1 owns offsets 1‑5, segment 2 owns
6‑12, segment 3 owns 13‑15), and every coverage offset is a monotonic basic-block code address.
There is **no separate include-files table**: the "Number of Include Files" (`srcfiles_count`) sizes
the *source-file table* in §6, which TDUMP itself labels "Include Files". See §11 and §15.

---

## 1. Container & trailer location  [C]

The TDS block is appended after the MZ load image. Locate its header (the "trailer block") at:

```
trailer_off = file_size_in_pages*512 - (512 - used_bytes_in_last_page)
              (treat used_bytes_in_last_page == 0 as 512)
```
where `used_bytes_in_last_page = u16@0x02`, `file_size_in_pages = u16@0x04` of the MZ header.
First word there is the magic `0x52FB`. Verified: TEST trailer @ `0x1170`, RICH @ `0x12B0`,
ENUM @ `0x1AAF`-region, CLS @ `0x1A72`-region (each = the EXE `Image Size` field value).

All multi-byte integers are **little-endian**. Name/type/symbol/member indices are **1-based**
(index 0 = "none"/anonymous).

---

## 2. The header

### 2.1 Base header — 48 bytes, offsets relative to the trailer  [C]

| Off | Sz | Field | Meaning |
|----:|---:|-------|---------|
| 0x00 | 2 | `magic` | `0x52FB` |
| 0x02 | 1 | `minor_version` | `0x10` |
| 0x03 | 1 | `major_version` | `0x03` (→ "Symbolic Information Version 3.10") |
| 0x04 | 4 | `names_pool_size` | total bytes of the name pool |
| 0x08 | 2 | `names_count` | # names in the pool |
| 0x0A | 2 | `types_count` | # type records |
| 0x0C | 2 | `members_count` | # member records (incl. list terminators) |
| 0x0E | 2 | `symbols_count` | # symbol records (globals **then** locals, one table) |
| 0x10 | 2 | `globals_count` | how many leading symbols are global (rest are locals) |
| 0x12 | 2 | `modules_count` | # module records ("Number of Source Modules") |
| 0x14 | 2 | `locals_count` | always 0 in BCC3.1 — locals live in the symbol table |
| 0x16 | 2 | `scopes_count` | # scope records |
| 0x18 | 2 | `lines_count` | # line-number records |
| 0x1A | 2 | `srcfiles_count` | # source-file records ("Number of Include Files") |
| 0x1C | 2 | `segments_count` | # segment records |
| 0x1E | 2 | `correlations_count` | # correlation records |
| 0x20 | 4 | `image_size` | load-image size (= trailer offset, image-relative) |
| 0x24 | 4 | `debugger_hook` | debugger hook addr (seg:off); 0 here |
| 0x28 | 1 | `program_flags` | bit0 = case-sensitive link (1=yes), bit1 = Pascal overlays |
| 0x29 | 2 | `string_seg_offset` | deprecated ("Basic RTL String Segment Offset"); 0 |
| 0x2B | 2 | `data_count` | data-pool size ("Data Count"); 0 |
| 0x2D | 1 | `filler` | 0 |
| 0x2E | 2 | `extension_size` | bytes of extended header that follow (= `0x20` for BCC3.1) |

Cross-check: TEST `names_count=0x57`, `types=0x1A`, `members=3`, `symbols=0x54`,
`globals=0x4D`, `modules=1`, `scopes=4`, `lines=0xA`, `srcfiles=1`, `segments=1`,
`correlations=1` — all match `TEST.LST` exactly. `globals_count < symbols_count`: in RICH the
table holds 104 symbols where #1..81 are global and #82..104 are function-scope locals
referenced by scopes.

**`srcfiles_count` is the "Number of Include Files".** There is exactly one source-file table
(after the module table); TDUMP labels its count "Include Files".

### 2.2 Extended header — `extension_size` (=0x20) bytes at trailer+0x30  [C]

Every field name and offset below is now confirmed against TDUMP's own header listing (which prints
"Number of Class Entries", "…Global Classes", "…Parent Entries", "…Overload Entries", "…Scope Class
Entries", "…Module Class Entries", "…Coverage Analysis Offsets", "…Browser Entries", "…Optimized
Symbol Entries", "Debug Flags") and against the **MI** fixture, which moves `parent_entries` to 2
while `module_class_entries` stays 1 — splitting the two offsets that were ambiguous when only CLS
(both = 1) was available.

| Off | Sz | Field | TEST/RICH/ENUM/CLS/**MI**/LCLS | Tag |
|----:|---:|-------|-------|-----|
| 0x30 | 2 | `class_entries` | 0/0/0/2/**3**/2 | **[C]** |
| 0x32 | 2 | `parent_entries` | 0/0/0/1/**2**/0 | **[C]** (MI=2 ⇒ this is parent, not module_class) |
| 0x34 | 2 | `global_classes` | 0/0/0/0/0/0 | **[C]** (named by TDUMP; always 0 in BCC3.1) |
| 0x36 | 2 | `overload_entries` | 0/0/0/0/0/0 | **[C]** (TDUMP prints "Number of Overload Entries" here; always 0) |
| 0x38 | 2 | `scope_class_entries` | 0/0/0/0/0/**8** | **[C]** (LCLS local class ⇒ 8 = one record per scope) |
| 0x3A | 2 | `module_class_entries` | 0/0/0/1/**1**/1 | **[C]** (stays 1 when parent→2 ⇒ this is module_class) |
| 0x3C | 2 | `coverage_count` | 6/15/6/9/24/12 | **[C]** ("Coverage Analysis Offsets" = # coverage-offset entries) |
| 0x3E | 4 | `name_pool_offset` | 0x46B/0x66A/0x55B/0x574/0x763/… | **[C]** — name pool offset **from the end of the header** (trailer+0x30+extension_size) |
| 0x42 | 2 | `browser_entries` | 0 everywhere | **[B]** (TDUMP "Browser Entries"; BCC3.1 emits 0) |
| 0x44 | 2 | `opt_sym_entries` | 0 everywhere | **[B]** (TDUMP "Optimized Symbol Entries"; BCC3.1 emits 0) |
| 0x46 | 2 | `debug_flags` | 0 everywhere | **[B]** (bit0 `DBG_OPT`; 0 ⇒ unoptimized) |
| 0x48 | 4 | `ref_info_size` | 0 everywhere | **[B]** (bytes of Reference-Info table; BCC3.1 emits 0) |
| 0x4C | 4 | `filler` | 0 | [C] |

`name_pool_offset` is verified two independent ways (RICH: `header_end(0x1300)+0x66A = 0x196A`
= `file_size(0x1D09) − names_pool_size(0x39F)`). **The parser should use `name_pool_offset`
to locate the name pool** rather than walking the trailing tables.

Note: the BOA's `struct header_extension` (the 32-bit/TD32 variant) omits the `overload_entries`
word and orders the fields slightly differently; the 16-bit BC++ 3.1 layout above is the
authoritative one and is exactly what TDUMP labels. The C++ table *counts* (class/parent/scope-
class/module-class) drive the trailing tables in §15; `global_classes`, `overload_entries`,
`browser_entries`, `opt_sym_entries` and `ref_info_size` are always 0 for BCC3.1 output.

---

## 3. On-disk block order  [C]

Verified end-to-end on all four fixtures (lands exactly on `name_pool_offset`, zero residual):

```
[header: 0x30 + extension_size]
[symbols]        symbols_count       × 9
[modules]        modules_count       × 16
[source files]   srcfiles_count      × 6     ← this IS the "include files" table (§6)
[line numbers]   lines_count         × 4
[scopes]         scopes_count        × 12
[segments]       segments_count      × 16
[correlations]   correlations_count  × 8
[types]          types_count         × 8
[members]        members_count       × 5
———— C++ tables (all zero-length for plain C; §15) ————
[class]          class_entries       × 11
[parent]         parent_entries      × 2
[scope class]    scope_class_entries × 4
[module class]   module_class_entries× 4
[C++ cov prefix] (present iff class_entries>0) 4 bytes  ← undocumented {class_entries, segments?}; §15.6
———— trailing tables (present for every fixture) ————
[coverage map]   segments_count      × 2     ← 1-based start index into the coverage-offset table, per segment
[coverage offs]  coverage_count      × 2     ← basic-block code offsets
[module opt]     modules_count       × 4     ← per-module optimization flags (0 = unoptimized)
———— BC++ 3.1 always emits zero of the following (BOA-documented) ————
[browser]        browser_entries     × 6   (=0)
[optimized syms] opt_sym_entries     × 9   (=0)
[reference info] ref_info_size bytes        (=0)
[name pool]      names_pool_size bytes       ← at name_pool_offset; 1-based NUL-terminated strings
```

Source-file order is `srcfiles → lines → scopes` (TDUMP's documentation lists scopes before lines,
but the 16-bit on-disk order is lines before scopes — verified by clean decode). The C++ tables
(class…module-class + cov-prefix) sit between members and the coverage map; for plain C they are
empty, so members is immediately followed by the coverage map.

RICH reconciliation (C, no C++ tables; header_end `0x1300`): symbols→`0x16A8`, modules→`0x16D8`,
srcfiles→`0x16EA`, lines→`0x1742`, scopes→`0x1796`, segments→`0x17C6`, correlations→`0x17DE`,
types→`0x18FE`, members→`0x193A`, covmap(3×2)→`0x1940`, covoffs(15×2)→`0x195E`,
modopt(3×4)→`0x196A` = name pool, **zero residual**. ✓

CLS reconciliation (C++; after members @`0x1C3C`): class(2×11)→`0x1C52`, parent(1×2)→`0x1C54`,
scope-class(0)→`0x1C54`, module-class(1×4)→`0x1C58`, cov-prefix(4)→`0x1C5C`, covmap(1×2)→`0x1C5E`,
covoffs(9×2)→`0x1C70`, modopt(1×4)→`0x1C74` = name pool, **zero residual**. ✓

---

## 4. Symbol record — 9 bytes  [C]

```
+0  u16  name        1-based name-pool index
+2  u16  type        1-based type-table index (0 = none/Unknown)
+4  u16  offset      meaning depends on class (see below)
+6  u16  segment     image-relative paragraph (code/DGROUP), or 0
+8  u8   flags       bits0..2 = class; bit3 = param/BP-positive; bits4.. see below
```

`class = flags & 0x07`:

| class | name | `offset` / `segment` meaning |
|---:|------|------------------------------|
| 0 | STATIC | global/static: `segment:offset` = image address. [C] `_g_count` seg=0xCF off=0xAA |
| 1 | ABSOLUTE | absolute symbol [I] |
| 2 | AUTO | stack local: `offset` is **signed** BP-relative; `segment`=0. [C] `[BP+8]`=+8, `[BP-14]`=0xFFF2 |
| 3 | PASCAL_VAR | Pascal var-param [I] |
| 4 | REGISTER | `offset` = x86 register number; `segment`=0. [C] CX=1, SI=6 |
| 5 | CONSTANT | `offset` = the constant value; `segment`=0. [C] `__AHSHIFT`=0x000C, `__AHINCR`=0x1000 |
| 6 | TYPEDEF | typedef name; `type` = aliased type. [C] `byte`→uchar, `PointT`→struct Point |
| 7 | STRUCT_UNION_OR_ENUM | struct/union/enum **tag** symbol; `type` = the aggregate type [C] |

`flags` bit3 (`0x08`): set for parameters / positive-BP autos and register params; clear for
negative-BP locals. [C] (`b`@BP+8 → 0x0A, `inner`@BP-14 → 0x02; register param `n` → 0x0C,
register local `i` → 0x04). Functions carry `0x18` (bits 3,4) — [I] higher bits encode the
return-frame word count; not needed for address mapping.

**Register encoding** (class 4, `offset` field) = standard x86 ModRM reg index: [C] confirmed
`CX=1`, `SI=6`; [I] full set `AX=0,CX=1,DX=2,BX=3,SP=4,BP=5,SI=6,DI=7`, byte regs `AL=8…BH=11`,
seg regs `ES=…` per Borland's table.

---

## 5. Module record — 16 bytes  [C]

```
+0  u16  name                 module name (name-pool index)
+2  u8   language             0=unknown,1=C,2=Pascal,4=asm,5=C++.  [C] TEST/RICH/ENUM/INC=1, CLS/MI=5
+3  u8   memory_model         bits0..2 = MM code; bit3 = underbars_on. (see table below)  [C]
+4  u16  symbols_index        1-based symbol index of the module's tag/typedef-symbol block
+6  u16  symbols_count        count of those symbols
+8  u16  first_source_file    1-based source-file-table index
+0xA u16 source_file_count
+0xC u16 correlation_index    1-based correlation-table index  ← NOT a segment index (corrected)
+0xE u16 correlation_count    number of correlation records for this module
```

**Memory-model byte** (`+3`) — fully confirmed by `MM.C` built in all six models. The low 3 bits
are the BOA `MM_*` code and bit 3 is `underbars_on` (set for C/C++ cdecl underscoring, so always 1
in BCC3.1 C/C++ output):

| Model | `-m` flag | MM code (bits0‑2) | byte (underbars=1) | Tag |
|-------|-----------|------------------:|-------------------:|-----|
| tiny    | `-mt` | 0 (`MM_TINY`)    | `0x08` | **[C]** MMT |
| small   | `-ms` | 1 (`MM_SMALL`)   | `0x09` | **[C]** TEST/PTR/INC/BENUM |
| medium  | `-mm` | 2 (`MM_MEDIUM`)  | `0x0A` | **[C]** RICH |
| compact | `-mc` | 3 (`MM_COMPACT`) | `0x0B` | **[C]** MMC |
| large   | `-ml` | 4 (`MM_LARGE`)   | `0x0C` | **[C]** ENUM/CLS/MI |
| huge    | `-mh` | 5 (`MM_HUGE`)    | `0x0D` | **[C]** MMH |

(The earlier note "language bit0 = underbars" was wrong: `language` is the plain BOA language enum;
`underbars_on` lives in bit 3 of the memory-model byte.)

**`+0xC`/`+0xE` are correlation index/count, not segment index/count** — corrected via **CLS**, which
has `segments_count = 1` but `correlations_count = 3`, and the module record reads `{+0xC=1, +0xE=3}`
= 3, matching the correlation count. (RICH could not distinguish them because it has 3 segments and 3
correlations 1:1.) A module locates its segments through the back-reference `segment.module`, and its
correlations through this forward index; there is no module→segment forward pointer.

Verified RICH: F1 = `{name=53, lang=1, mmbyte=0x0A, symIdx=91, symCnt=4, firstSrc=1, srcCnt=1,
corrIdx=1, corrCnt=1}`. Symbols #91..94 are exactly the `byte/PointT/Rect/Point` tag symbols (class
6/7); src #1 = `F1.C`. F2/F3 step firstSrc/corrIdx to 2,3. F3 has `symIdx=0,symCnt=0`. [C]

---

## 6. Source-file record — 6 bytes  [C]

```
+0  u16  name        name-pool index of the file name (e.g. "F1.C")
+2  u32  timestamp   DOS packed date/time (FFh-style), e.g. 0x5CDE021B
```
Verified RICH: F1.C/F2.C/F3.C each with the same build timestamp; TEST: `TEST.C 0x5CDDB81B`.

**This table IS the "Include Files" table** (TDUMP labels its count "Number of Include Files" =
`srcfiles_count`). Each source file that contains executable code — the main `.C` *and* every
code-bearing `#include`d header — gets exactly one record here, in compilation order (main file
first). Confirmed by **INC** (`INC.C` `#include`s `INCA.H` and `INCB.H`, both defining functions):
`srcfiles_count = 3` and the records are `{INC.C, INCA.H, INCB.H}`. There is **no second include
table** in the trailing region (see §0.1/§11). The per-file line ranges are bound to segments by the
correlation table (§10): INC's three correlations are `{seg1,src2(INCA.H),line1}`,
`{seg1,src3(INCB.H),line2}`, `{seg1,src1(INC.C),line3}` — all three files share the one small-model
code segment, each contributing one line-record range. [C]

---

## 7. Line-number record — 4 bytes  [C]

```
+0  u16  line_number     source line (absolute, not delta-encoded)
+2  u16  code_offset     offset within the module's code-base segment
```
Verified RICH F1: `{9,0x06}{15,0x0D}{16,0x16}{17,0x1B}{18,0x28}{21,0x39}{22,0x42}{24,0x48}
{25,0x4D}` — matches `RICH.LST` line list one-for-one. The correlation record binds a line range
to its segment (§9); `code_offset` is relative to that segment's code base.

---

## 8. Scope record — 12 bytes  [C]

```
+0  u16  symbol_index   1-based index of this scope's first local symbol
+2  u16  symbol_count   number of locals belonging to this scope
+4  u16  parent         parent scope (1-based; 0 = none / function top)
+6  u16  function       owning-function symbol index (member fns); 0 for plain C
+8  u16  offset         scope start offset within the code-base segment
+0xA u16 length         scope length in bytes
```
Verified RICH scope[0] = `{82,2,0,0,6,76}` → TDUMP "Parent Scope 0, Scope Offset 0006,
Length 004C", with symbols #82=`b`(BP+8), #83=`a`(BP+6). Nested scope[1]=`{85,6,1,0,0x0D,0x45}`
references SI-register `ap`, `pt`, `local2`, `local1`, `a`, `b`. The `function` field is the
symbol index of the enclosing member function (CLS: "Parent Function: Derived::who()"). [C]

---

## 9. Segment record — 16 bytes  [C]

```
+0  u16  module             owning module (1-based)
+2  u16  code_segment       image-relative paragraph of the code base (e.g. 0xC2)
+4  u16  code_offset        start offset (e.g. 0x06)
+6  u16  code_length        code length in bytes (e.g. 0x4C)
+8  u16  scope_index        1-based first scope for this segment
+0xA u16 scope_count        number of scopes
+0xC u16 correlation_index  1-based first correlation record
+0xE u16 correlation_count  number of correlation records
```
Verified RICH: `{1, 0xC2, 6, 0x4C, 1, 3, 1, 1}` / `{2, 0xC7, 2, 0x42, 4, 2, 2, 1}` /
`{3, 0xCB, 4, 0x34, 6, 2, 3, 1}` — `code_segment:code_offset:code_length` exactly equal
`RICH.LST`'s "Code Base 00C2:0006 Code Length 004C" per module, and scope ranges match §8. The
last two words (previously called "pad") are the correlation index/count. [C]

---

## 10. Correlation record — 8 bytes  [C]

```
+0  u16  segment_index   1-based segment-table index
+2  u16  source_index    1-based source-file-table index
+4  u16  line_first      1-based first line-record index of this range
+6  u16  line_count      number of line records
```
Verified RICH: `{1,1,1,9}{2,2,10,8}{3,3,18,5}` — F1 owns line records 1..9 (9 entries),
F2 10..17 (8), F3 18..22 (5); total = `lines_count` = 22. [C] (`segment_index` vs
`source_index` are both 1/2/3 here so their *order* within the record is [I]; both fields are
present and 1-based.)

---

## 11. Trailing tables: coverage map, coverage offsets, module-optimization flags  [C]

After the member table (and after the C++ tables of §15, which are empty for plain C) sit three
fixed-stride tables, then the name pool. All three are confirmed by a zero-residual block walk on
every fixture.

### 11.1 Coverage-Map table — `segments_count × u16`  [C]

One `u16` per segment, in segment-table order. Each entry is the **1-based start index into the
Coverage-Offset table** for that segment's run of offsets. RICH (3 segments) = `{1, 6, 13}`: segment
1 owns coverage offsets 1‑5, segment 2 owns 6‑12, segment 3 owns 13‑15 (total 15 = `coverage_count`).
TEST/ENUM/INC (1 segment) = `{1}`. An entry of 0 means "no coverage offsets for this segment".

### 11.2 Coverage-Offset table — `coverage_count × u16`  [C]

One `u16` per entry = a code offset (basic-block boundary) within the offset's owning segment, taken
pairwise to delimit "atomic" blocks for the coverage analyser. The offsets are monotonic within a
segment's run. TEST = `{0x2C2,0x2C8,0x2D6,0x2DA,0x2E0,0x2FD}` (= `add`/`main` block addresses);
RICH segment 1 (F1) = `{6,0x0D,0x39,0x48,0x4D}`, etc.

### 11.3 Module-Optimization-Flags table — `modules_count × u32`  [C]

One `u32` of optimization flags per module, in module-table order (`MO_*` bits per the BOA:
`MO_globalCSEs 0x1 … MO_noAliasing 0x1000`). **Always emitted by BCC3.1, even when `debug_flags`'s
`DBG_OPT` bit is clear** — every fixture here has all-zero entries (unoptimized `-v` builds). This
table is exactly what padded the old (wrong) "include-files" arithmetic to the right byte count.

The parser **skips all three** — the name pool is located directly via `name_pool_offset` (§2.2) —
but they are now fully mapped, not merely sized.

---

## 12. Type record — 8 bytes, and the type-walk  [C]

```
+0  u8   id            TypeId (see §12.1)
+1  u16  name          name-pool index for tagged struct/union/enum; else 0
+3  u16  size          byte size of the type
+5  u8   class         modifier byte (meaning depends on id; see §12.2)
+6  u16  member_type   context-dependent reference (see §12.3)
```

Type references everywhere (symbol `type`, member `type`, `member_type`) are **1-based indices
into this table** — there is no separate "predefined < 0x18" space; the predefined primitives
are materialised as real records at fixed low indices (see §12.4).

### 12.1 TypeId (`id` byte) — complete observed set  [C]

| id | name | seen as |
|---:|------|---------|
| 0x00 | VOID | `void`; also the bound/range filler records (§12.4) |
| 0x04 | SCHAR | `signed char` |
| 0x05 | SINT | `signed int`/`short` |
| 0x06 | SLONG | `signed long` |
| 0x07 | SQUAD | signed 64-bit (predefined slot) |
| 0x08 | UCHAR | `unsigned char` |
| 0x09 | UINT | `unsigned int` |
| 0x0A | ULONG | `unsigned long` |
| 0x0B | UQUAD | unsigned 64-bit (predefined slot) |
| 0x0C | PCHAR | 1-byte char (predefined slot) |
| 0x0D | FLOAT | `float` (size 4) |
| 0x0E | TPREAL | Turbo-Pascal 6-byte real (predefined slot) |
| 0x0F | DOUBLE | `double` (size 8) |
| 0x10 | LDOUBLE | `long double` (size 10) |
| 0x15 | NEARP | near pointer |
| 0x16 | FARP | far pointer |
| 0x1A | ARRAY | array |
| 0x1E | STRUCT | struct / **C++ class** |
| 0x1F | UNION | union |
| 0x22 | ENUM | enum |
| 0x23 | FUNC | function |
| 0x28 | BOOL | bool (size 1, predefined slot) |
| 0x2B | TBYTE | 10-byte predefined slot (`TID_TBYTE`) |
| 0x2D | SPECIALFUNC | **C++ member / overloaded / duplicate function** (`TID_SPECIALFUNC`) — seen in CLS/MI for `who`/`fa`/… [C] |
| 0x2E | CLASS | **C++ class** (`TID_CLASS`) — CLS/MI emit `Base`/`Derived`/`A`/`B`/`C` as `id=0x2E`, **not** 0x1E [C] |
| 0x80 | — | bound/range marker in the predefined preamble & enum aux record ([C]; skippable, see §12.3) |

**Correction:** plain C `struct` is `id=0x1E` (STRUCT), but a **C++ `class` is `id=0x2E`**
(TID_CLASS). The earlier note "STRUCT (0x1E) = struct / C++ class" held only because CLS was first
read before the class records were decoded; CLS/MI in fact emit `Base`/`Derived` as TID_CLASS=0x2E
type records (named, sized) that are *cross-indexed* by the Class table (§15.1). The full BOA TypeId
set (0x00..0x3F, incl. Pascal/Basic/386 ids `TID_SEG 0x17`, `TID_NEAR386 0x18`, `TID_VLARRAY 0x1B`,
`TID_VLSTRUCT 0x20`, `TID_LABEL 0x24`, `TID_SET 0x25`, `TID_PWORD 0x2A`, `TID_MEMBERPTR 0x33`,
`TID_NREF 0x34`, `TID_FREF 0x35`) is in §16's `TypeId` enum; BCC3.1 C/C++ only emits the subset above
plus the ordinal-range partner records.

Names match the `tdinfo_structs.py` `TypeId` enum (which is **correct**): e.g. NEAR=21=0x15,
FAR=22=0x16, ARRAY=26=0x1A, STRUCT=30=0x1E, UNION=31=0x1F, ENUM=34=0x22, FUNCTION=35=0x23,
BOOL=40=0x28. [C] Pointer ids 0x15/0x16 are "near/far pointer" (the enum's `NEAR`/`FAR`).

### 12.2 `class` modifier byte  [C]/[I]

**Near/far pointer `class`** = the segment-register base (matches BOA `TID_NEAR`/`TID_FAR` exactly).
Confirmed by `PTR.C` (`char _es/_cs/_ss *` near pointers → types with class 0x01/0x02/0x03) and by
RICH/ENUM (`_DS` near = 0x04; far = 0x00; huge = 0x01):

| id | class | meaning | Tag |
|----|------:|---------|-----|
| NEARP (0x15) | 0x00 | near, segment unspecified | [B] |
| NEARP (0x15) | 0x01 | near, **`_ES`**-relative | **[C]** PTR `g_esp` |
| NEARP (0x15) | 0x02 | near, **`_CS`**-relative | **[C]** PTR `g_csp` |
| NEARP (0x15) | 0x03 | near, **`_SS`**-relative | **[C]** PTR `g_ssp` |
| NEARP (0x15) | 0x04 | near, **`_DS`**-relative | **[C]** RICH `Node*` |
| NEARP (0x15) | 0x05 / 0x06 | near, `_FS` / `_GS`-relative | [B] |
| FARP (0x16) | 0x00 | plain far pointer (no segment adjust) | **[C]** |
| FARP (0x16) | 0x01 | **huge** pointer (segment-normalising) | **[C]** ENUM `char huge *` |

**Function `class`** = calling-convention + distance byte. Confirmed by `PTR.C` (small model, so all
near): `_cadd`/`_main` (cdecl) → 0x00, `PADD` (`pascal`) → 0x01, `_isr` (`interrupt`) → 0x07; plus
RICH/ENUM far cdecl → 0x04. Bit 2 (`0x04`) = far modifier; the low bits select the convention:

| id | class | meaning | Tag |
|----|------:|---------|-----|
| FUNC (0x23) | 0x00 | near cdecl/C | **[C]** TEST/PTR `add`/`cadd`/`main` |
| FUNC (0x23) | 0x01 | near **pascal** | **[C]** PTR `padd` |
| FUNC (0x23) | 0x04 | far cdecl/C | **[C]** RICH/ENUM `compute`/`main` |
| FUNC (0x23) | 0x05 | far pascal | [I] (0x04 far ∣ 0x01 pascal) |
| FUNC (0x23) | 0x07 | **interrupt** | **[C]** PTR `isr` (the `interrupt` symbol also carries flag bit7 in its symbol record) |

### 12.3 `member_type` field by id  [C]

| id | `member_type` means |
|----|---------------------|
| STRUCT/UNION (0x1E/0x1F) | 1-based **member-table index** of the first member |
| CLASS (0x2E) | the class's **1-based Class-table index** (§15.1) — its member list is then reached via that Class-table entry's `member_index`. *(Correction: this is NOT a type index; in CLS/MI/LCLS/BBCPP `member_type` reads `{1,2,3}` mapping 1:1 onto the Class table — a type index there would be `void`. CONFIRMED by the Tier-3 decoder, which resolves a TID_CLASS record to its Class entry via this field.)* |
| ENUM (0x22) | **0** — the enumerator-list link lives in the following aux record, see §12.3a |
| NEARP/FARP (0x15/0x16) | **pointee** type index |
| ARRAY (0x1A) | **element** type index; element_count = `size / sizeof(element)` |
| FUNC (0x23) | **return** type index |
| primitive | self-index or 0 |

### 12.3a Enum → enumerator linkage  [C]

An ENUM type record carries `member_type = 0`; it does **not** point at its enumerators directly.
Instead, **the type record immediately following the ENUM record is an auxiliary "ordinal-range"
record** (`id = 0x00`, byte pattern `00 80 ff 7f XX 00 00 00`), and its 5th byte (**offset +4**,
i.e. the high byte of the `size` field in the fixed-8 view) is `XX` = the **1-based index of the
first enumerator in the member table**. The enumerator list runs from there until a member whose
`flags` has bit 7 (`0x80`, `end_of_list`) set. Confirmed by `BENUM.C`:

```
enum Small{SA,SB,SC}        t25: id=0x22 "Small"  member_type=0
  aux t26: 00 80 ff 7f 01.. → first enumerator = member 1  →  m1{SA=0} m2{SB=1} m3{0x80,SC=2}
enum Big{Z0,Z1,Z2,Z3=10..Z8=-4}  t27: id=0x22 "Big" member_type=0
  aux t28: 00 80 ff 7f 04.. → first enumerator = member 4  →  m4{Z0=0}…m12{0x80,Z8=-4}
enum Color (ENUM.C)         t32: id=0x22 "Color" member_type=0
  aux t33: 00 80 ff 7f 0a.. → first enumerator = member 10 →  m10{RED}…m12{0x80,BLUE}
```

Three independent enums (first index 1, 4, 10) all carry the value at aux+4 — confirmed. The rest of
the aux record's bytes (`80 ff 7f`, plus the trailing zeros) are opaque ordinal-range sentinels (the
same family of skippable bound records that pad the predefined preamble, §12.4); only the
first-enumerator byte is load-bearing. As a cross-check, enumerator lists are also laid down in the
member table contiguously in enum-declaration order, so a parser may instead walk member ranges in
type order — but the aux+4 link is explicit and direct.

### 12.4 Predefined preamble  [C]

Every BCC3.1 TDS begins its type table with an identical fixed preamble (indices 1..~23):
`1=void, 2=char, 4=int, 6=long, 8=uchar, 10=uint, 12=ulong, 14=float, 15=double, 16=ldouble,
17=tpreal(6B), 18=bool, 19=pchar, 21=squad, 22=uquad, 23=10-byte`. The **odd** slots
(3,5,7,9,11,13,20) are ordinal **range/bound** records (`id=0x80` or `id=0x00` carrying
`0x7FFF…/0xFFFF…/0xFFFFFFFF` min/max sentinels) paired with the preceding ordinal type — they
are skippable for C type rendering. User-defined types begin after the preamble.

### 12.5 Worked type-walks (verified vs `RICH.LST` / `ENUM.LST`)  [C]

```
struct Point{int x,y,z;}            idx25: id=STRUCT name="Point" size=6 member_type=1
  → members[1..]: m1{flags=0,name="x",type=4(int)} m2{"y",4} m3{"z",4} m4{flags=0xC0=END}

struct Rect{Point tl,br;long area;char name[8];}  idx27: STRUCT "Rect" size=24 member_type=5
  → m5{"tl",type=25(=struct Point)} m6{"br",25} m7{"area",6(long)} m8{"name",28} m9{END}
    idx28: id=ARRAY size=8 member_type=2(char) → char[8]  (count = 8/1 = 8)

struct Node{int value; struct Node *next;}  idx30: STRUCT "Node" size=4 member_type=10
  → m10{"value",4(int)} m11{"next",29} m12{END};  idx29: NEARP class=0x04(_DS) → type30 (Node)

int (*FuncPtr)(int,int)   idx26: FARP class=0 member_type=27 → idx27: FUNC class=0x04(far) ret=int
char far  *               idx29(ENUM.EXE): FARP class=0 member_type=2(char)
char huge *               idx28(ENUM.EXE): FARP class=0x01(huge) member_type=2

enum Color{RED,GREEN=5,BLUE}  idx32: id=ENUM "Color" size=2
  → enumerators in member table: m10{flags=0,name="RED",type=0}  ← type field = ENUM VALUE
                                 m11{"GREEN",type=5}  m12{flags=0x80,"BLUE",type=6}
union Variant{int i;long l;double d;char c;}  idx31: id=UNION "Variant" size=8 member_type=5
  → m5{"i",4} m6{"l",6} m7{"d",15(double)} m8{"c",2} m9{END};  all members at offset 0
```

---

## 13. Member record — 5 bytes  [C]

```
+0  u8   flags     bits0..5 = bit_field_size; bit6 = offset_rec; bit7 = end_of_structure / end_of_list
+1  u16  name      member/enumerator name (name-pool index)
+3  u16  type      struct/union member: type-table index
                   enum member:         the enumerator's integer VALUE (signed)
                   offset/terminator:   leftover, ignore
```

The `flags` byte is the BOA `member_rec` discriminant (`bit_field_size:6, offset_rec:1,
end_of_structure:1`). For **plain C data members** only bits 0‑5 (bitfield width, 0 = not a
bitfield), bit 7 (`0x80` = last field), and the offset/terminator record matter. For **C++ class
members** the byte additionally uses Borland's method-attribute encoding (also OR-able):

| flags | member kind |
|------:|-------------|
| `0x00` | non-static, non-bitfield data member |
| `0x01`–`0x3F` | bitfield, value = width in bits |
| `0x40` | **offset-reset record** (`offset_rec`) — next `u16` is the new running struct offset (Pascal variants / alignment) |
| `0x48` | (non-virtual) **method** / member function — `ACC @Acc@method$qi` [C] |
| `0x49` | **destructor** (`0x48 ∣ 0x01`) — `ACC @Acc@$bdtr$qv` [C] |
| `0x4A` | **constructor** (`0x48 ∣ 0x02`) — `ACC @Acc@$bctr$qv` [C] |
| `0x4B` | **conversion** method (`0x48 ∣ 0x03`) — not emitted by the corpus [B] |
| `0x4C` | **virtual method** (`0x48 ∣ 0x04`) — CLS `@Base@who$qv`, `@Derived@who$qv` [C] |
| `0x50` | static member function — not emitted by the corpus [B] |
| `0x60` | static data member (`member.type` → the member's symbol) — `ACC @Acc@s_count` [C] |
| `0x80` | last member of the list (sign bit) / last enumerator (`end_of_list`) |
| `0xC0` | list terminator (`end_of_structure ∣ offset_rec`) — the trailing record closing a struct/union |

**Correction (`ACC`):** an earlier draft mapped ctor/dtor/conversion to `0x41`/`0x42`/`0x43`. The real
bytes show a **function** record carries bit `0x08` (so all are `0x48`-based), and the low 3 bits then
select the kind: `0x4C` virtual, `0x4A` ctor, `0x49` dtor, `0x4B` conversion, plain `0x48` method.
`0x60`/`0x50` are static data/method. (No per-member **access** bit exists — `pub_data` and
`priv_data` both read `flags=0x00`; access is unrecoverable, §17.)

[C] Bitfields: `struct Bits{unsigned a:3; unsigned b:5; int s:4;}` →
`m1{flags=3,"a",10(uint)} m2{flags=5,"b",10} m3{flags=4,"s",4(int)} m4{0xC0}`. The bit *width*
is in `flags`; the bit *position* and struct member byte offsets are **not stored** — the parser
computes them by accumulating member sizes in declaration order (bitfields packed into their
container). Each struct/union member list ends with a `0xC0` terminator record; enum lists end by
setting `0x80` on the final enumerator (no separate terminator). `members_count` includes the
terminators.

---

## 14. Address / segment model  [C]

A symbol/segment stores an **image-relative paragraph** in its `segment`/`code_segment` field
(e.g. code at `0xC2`, DGROUP at `0xCF`), and an `offset` within it. DOS loads the image at
paragraph `PSP_seg + 0x10` (= the entry `CS`), then adds that base to every MZ relocation. So:

```
runtime_seg   = (psp_seg + 0x10) + tds_segment        // tds_segment is image-relative
runtime_flat  = runtime_seg*16 + tds_offset
```

Verified: TDUMP renders `_compute` as `00C2:0006` (the stored `segment:offset`); at runtime the
loader-base `(psp_seg+0x10)` is added to `0xC2`. Near functions/small-model symbols store
`segment=0` (relative to image base 0). Line offsets bind through the correlation record: a line's
`code_offset` is within the segment named by `correlation.segment_index` → `segment.code_segment`,
so its runtime address uses the same formula with `tds_segment = segment.code_segment` and
`tds_offset = code_offset`.

zdos already tracks `psp_seg` (the MCB/PSP allocation), so the whole map is available at load time
with no MAP file needed — the segment table carries the image-relative paragraphs directly.

---

## 15. C++ extension tables  [C]

These tables sit between the member table and the coverage map (§3), in this order: Class, Parent,
Scope-Class, Module-Class, then a 4-byte C++ coverage prefix. For plain C every count is 0 and the
whole block is absent. Byte layouts below are confirmed by `CLS` (single inheritance, 1 virtual),
`MI` (multiple inheritance: 3 classes, 2 parents), and `LCLS` (a class declared inside a function).
The BOA documents the 32-bit/TD32 variants where `member_index`/`name_index` are `unsigned long`; in
the 16-bit BC++ 3.1 output decoded here they are `unsigned short` — confirmed because the
`name_index` of `Base`(96) and `Derived`(97) lie exactly **11 bytes apart** in CLS, pinning an
11-byte record.

A C++ class is represented in **two** places: a **type record** `id=0x2E` (TID_CLASS, §12.1) that is
named and sized, and a **Class-table entry** (below) that carries the inheritance/member/vtable info.
The two are linked by the TID_CLASS record's **`member_type` field = the 1-based Class-table index**
(§12.3): resolve `types[ref].member_type → classes[member_type-1]`, then walk `classes[…].member_index`
for the members and `classes[…].parent_index/parent_count` for the bases. *(DECODED & retained by the
Tier-3 parser — `src/debug/symbols/{tds,types}.zig` — which renders `class Foo` with its data members,
inheritance, and method signatures; verified against `CLS`/`MI`/`LCLS` and the new `BBCPP` fixture.)*

### 15.1 Class table — `class_entries × 11 bytes`  [C]

```
+0  u16  parent_index   1-based index into the Parent table where this class's parent list starts
+2  u16  parent_count   number of parents (0 = a root/base class)
+4  u16  member_index   1-based index into the Member table of this class's first member
+6  u16  name_index     name-pool index of the class tag (e.g. "Base")
+8  u16  virtual_ptr    byte offset of the vtable pointer within the object (0 ⇒ vptr at offset 0)
+0xA u8  info           bit0 = virtual base; rest = object descriptor (NOT access — see below)
```

**`info` does NOT encode base/member access.** The earlier "bit1 = public" reading is **WRONG**:
the new **`ACC`** fixture derives one base `Base` three ways — `Pub : public Base`,
`Pri : private Base`, `Prot : protected Base` — and every Class record (incl. `Base` itself) reads
the *identical* `info = 0x0C`; the three derived classes' Parent records are byte-identical too. No
bit anywhere distinguishes `public`/`private`/`protected`. `info`'s upper bits are the constant
`far 'this' ptr / near vbase` object descriptor TDUMP prints, not an access specifier. Access is
therefore **unrecoverable** from BCC 3.1's TDS (§17). [CONFIRMED by `ACC`.]

CLS: `cls1 Base   {parent_index=1, parent_count=0, member_index=1, name=96, vptr=0, info=0x0C}`,
`cls2 Derived {parent_index=1, parent_count=1, member_index=5, name=97, vptr=0, info=0x0C}`.
MI: `cls3 C {parent_index=1, parent_count=2, member_index=10, name=106, …}` — `parent_count=2`
proves multiple inheritance is in the `parent_count` field. `member_index` lands on the class's
member list (CLS `Base`→m1, `Derived`→m5; the lists hold data members like `bx`/`dy` and virtual
methods like `@Base@who$qv` with `flags=0x4C`, §13).

### 15.2 Parent table — `parent_entries × 2 bytes`  [C]

```
+0  u16  class_index    1-based Class-table index of the parent (high bit 0x8000 ⇒ virtual base)
```

CLS = `{1}` (Derived's parent is class 1 = Base). MI = `{2, 1}` (class C's two parents, referenced
by `cls3.parent_index=1, parent_count=2`). No virtual bases in the corpus, so the 0x8000 virtual-base
flag is **[B]**.

**Base-subobject offsets (computed, not stored):** a Parent record names the base but not where its
subobject sits in the derived object. The offset is the running sum of the sizes of the *preceding
non-virtual* bases in declaration order (the first base is at 0). CONFIRMED by **MI** `C : public A,
public B`: A (4 bytes) at offset 0, B (4 bytes) at offset 4, so C's own `cx` lands at 8. Single
(leading) inheritance ⇒ base at 0 (CLS/BBCPP/ACC). The decoder exposes this as `BaseInfo.byte_offset`
(`src/debug/symbols/types.zig`). A *virtual* base's true offset is not this running sum (it is laid
out separately) — but no fixture has a virtual base, so that case is **[B]**.

### 15.3 Scope-Class table — `scope_class_entries × 4 bytes`  [C]

```
+0  u16  class_index    1-based Class-table index
+2  u16  class_count    number of classes defined in this scope
```

Present **only when a class is declared inside a scope** (a local class). One record per scope
record, so `scope_class_entries == scopes_count` when present. Confirmed by `LCLS` (`class Local`
inside `use()`): `scope_class_entries = 8 = scopes_count`, records
`{1,0}{1,1}{2,0}{2,0}{2,0}{2,0}{2,0}{2,0}` — the `{1,1}` record is the function scope that defines
one local class. CLS/MI define all classes at file scope, so their `scope_class_entries = 0` and the
table is absent.

### 15.4 Module-Class table — `module_class_entries × 4 bytes`  [C]

```
+0  u16  class_index    1-based Class-table index of the module's first class
+2  u16  class_count    (observed 0 in BCC3.1 output)
```

One record per module that defines classes. CLS/MI/LCLS each = `{1, 0}`. `class_index=1` points at
the first class of the module; the second word reads 0 in all three fixtures (the per-module class
*count* appears to be tracked via the Class table rather than here). [C] for the bytes; the exact
meaning of the second word is **[U-minor]** (always 0 in the corpus).

### 15.5 Browser, Overload, Optimized-Symbol, Reference-Info tables  [B]

BC++ 3.1 emits **zero** records of each of these for the entire corpus (and TDUMP confirms all four
counts = 0), so their byte layouts cannot be empirically populated. The BOA-documented 16-bit forms
(translate each `unsigned long` index to `unsigned short`) are:

```
Browser definition   (browser_entries × 6):   u16 symbol_index, u16 file_index, u16 line_number
Optimized symbol     (opt_sym_entries × 9):    u16 next, u16 offset(reg-enum), u8 class,
                                               u16 code_offset_start, u16 code_offset_end
Overload             (overload_entries × ?):   never emitted by BCC3.1 (count always 0; no record
                                               layout is documented for the linked 16-bit table)
Reference info       (ref_info_size bytes):    variable-length ref objects, each terminated by 2
                                               zero bytes; absent (ref_info_size = 0)
```

These are skippable in every case (the parser uses `name_pool_offset`).

### 15.6 The C++ coverage-prefix word  [C size/pos]/[U-minor semantics]

When `class_entries > 0`, a single extra **4-byte record** sits between the Module-Class table and
the Coverage-Map table; it is **absent for plain C**. Observed values: CLS `{2, 1}`, MI `{3, 1}`,
LCLS `{2, 1}` — i.e. `{class_entries, 1}`. The first word equals `class_entries`; the second is 1 in
every fixture (= both `segments_count` and `modules_count`, which are 1 here, so the two cannot be
separated). Its size and position are **CONFIRMED** (it is required for the C++ block walk to reach
the name pool at zero residual); its exact field meaning is the **one remaining [U-minor]** in the
format. It is not BOA-documented and is irrelevant to parsing (skipped via `name_pool_offset`). To
fully disambiguate the second word, build a C++ program whose `segments_count ≠ modules_count`.

---

## 16. Zig definitions (drop-in)

```zig
const std = @import("std");

pub const MAGIC: u16 = 0x52FB;

/// Base header — 48 bytes at the trailer offset. `packed struct` so byte-exact LE layout
/// (note the u16 fields at odd offsets 0x29/0x2B — only a packed struct represents these).
/// Read any record with `@bitCast` from its fixed-size byte array.
pub const Header = packed struct {
    magic: u16, // 0x52FB
    minor_version: u8, // 0x10
    major_version: u8, // 0x03
    names_pool_size: u32,
    names_count: u16,
    types_count: u16,
    members_count: u16,
    symbols_count: u16,
    globals_count: u16,
    modules_count: u16,
    locals_count: u16, // always 0 in BCC3.1
    scopes_count: u16,
    lines_count: u16,
    srcfiles_count: u16, // == "Number of Include Files"
    segments_count: u16,
    correlations_count: u16,
    image_size: u32,
    debugger_hook: u32,
    program_flags: u8, // bit0 case-sensitive, bit1 pascal-overlays
    string_seg_offset: u16, // deprecated
    data_count: u16,
    filler: u8,
    extension_size: u16, // 0x20 for BCC3.1
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 0x30);
    }
};

/// Extended header — at trailer+0x30, length == Header.extension_size (0x20).
pub const ExtHeader = packed struct {
    class_entries: u16, // 0x30
    parent_entries: u16, // 0x32
    global_classes: u16, // 0x34
    overload_entries: u16, // 0x36
    scope_class_entries: u16, // 0x38
    module_class_entries: u16, // 0x3A
    coverage_count: u16, // 0x3C
    name_pool_offset: u32, // 0x3E  (relative to end of header = trailer+0x30+extension_size)
    browser_entries: u16, // 0x42
    opt_sym_entries: u16, // 0x44
    debug_flags: u16, // 0x46
    ref_info_size: u32, // 0x48
    filler: u32, // 0x4C
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 0x20);
    }
};

pub const SymbolClass = enum(u3) {
    static = 0, // global/static: segment:offset is an image address
    absolute = 1,
    auto = 2, // offset = signed BP-relative; segment = 0
    pascal_var = 3,
    register = 4, // offset = x86 register number; segment = 0
    constant = 5, // offset = the constant value
    typedef = 6, // type = aliased type
    tag = 7, // struct/union/enum tag symbol
};

/// x86 register numbers used when SymbolClass.register (in the `offset` field).
pub const Reg = enum(u16) { ax = 0, cx = 1, dx = 2, bx = 3, sp = 4, bp = 5, si = 6, di = 7, al = 8, cl = 9, dl = 10, bl = 11, ah = 12, ch = 13, dh = 14, bh = 15, _ };

pub const Symbol = packed struct { // 9 bytes
    name: u16,
    type: u16,
    offset: u16, // signed when class==auto
    segment: u16,
    flags: u8, // bits0..2 class, bit3 param/BP+, bits4.. ret-frame words
    pub fn class(s: Symbol) SymbolClass {
        return @enumFromInt(@as(u3, @truncate(s.flags)));
    }
    pub fn isParam(s: Symbol) bool {
        return (s.flags & 0x08) != 0;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 9);
    }
};

pub const Language = enum(u8) { unknown = 0, c = 0x01, pascal = 0x02, basic = 0x03, @"asm" = 0x04, cpp = 0x05, _ };

/// Low 3 bits of the module `memory_model` byte (bit 3 is `underbars_on`).
pub const MemoryModel = enum(u3) { tiny = 0, small = 1, medium = 2, compact = 3, large = 4, huge = 5, _ };

pub const Module = packed struct { // 16 bytes
    name: u16,
    language: u8, // Language enum (plain), NOT a bitfield
    memory_model: u8, // bits0..2 = MemoryModel, bit3 = underbars_on
    symbols_index: u16, // 1-based first tag/typedef symbol of the module
    symbols_count: u16,
    first_source_file: u16,
    source_file_count: u16,
    correlation_index: u16, // 1-based first correlation record (NOT a segment index)
    correlation_count: u16,
    pub fn model(m: Module) MemoryModel {
        return @enumFromInt(@as(u3, @truncate(m.memory_model)));
    }
    pub fn underbars(m: Module) bool {
        return (m.memory_model & 0x08) != 0;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 16);
    }
};

pub const SourceFile = packed struct { // 6 bytes
    name: u16,
    timestamp: u32, // DOS packed date/time
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 6);
    }
};

pub const Line = packed struct { // 4 bytes
    line: u16,
    code_offset: u16, // within the correlation's segment code base
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 4);
    }
};

pub const Scope = packed struct { // 12 bytes
    symbol_index: u16, // first local symbol (1-based)
    symbol_count: u16,
    parent: u16,
    function: u16, // owning fn symbol (C++); 0 for C
    offset: u16, // within code-base segment
    length: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 12);
    }
};

pub const Segment = packed struct { // 16 bytes
    module: u16,
    code_segment: u16, // image-relative paragraph
    code_offset: u16,
    code_length: u16,
    scope_index: u16,
    scope_count: u16,
    correlation_index: u16,
    correlation_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 16);
    }
};

pub const Correlation = packed struct { // 8 bytes
    segment_index: u16,
    source_index: u16,
    line_first: u16, // 1-based into line table
    line_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 8);
    }
};

pub const TypeId = enum(u8) {
    void = 0x00,
    schar = 0x04,
    sint = 0x05,
    slong = 0x06,
    squad = 0x07,
    uchar = 0x08,
    uint = 0x09,
    ulong = 0x0A,
    uquad = 0x0B,
    pchar = 0x0C,
    float = 0x0D,
    tpreal = 0x0E,
    double = 0x0F,
    ldouble = 0x10,
    nearp = 0x15,
    farp = 0x16,
    seg = 0x17, // TID_SEG
    near386 = 0x18,
    far386 = 0x19,
    array = 0x1A, // TID_CARRAY
    vlarray = 0x1B,
    parray = 0x1C,
    @"struct" = 0x1E,
    @"union" = 0x1F,
    vlstruct = 0x20,
    vlunion = 0x21,
    @"enum" = 0x22,
    func = 0x23,
    label = 0x24,
    set = 0x25,
    bool = 0x28,
    pword = 0x2A,
    tbyte = 0x2B, // 10-byte predefined slot
    specialfunc = 0x2D, // C++ member / overloaded / duplicate function
    class = 0x2E, // C++ class (named, sized; cross-indexed by the Class table)
    memberptr = 0x33,
    nref = 0x34,
    fref = 0x35,
    _,
};

/// Near/far pointer modifier byte (Type.class when id == nearp/farp).
pub const PointerClass = enum(u8) {
    near_unspec = 0x00, // for nearp: unspecified segment    / for farp: plain far
    es_or_far = 0x01, // nearp: _ES-relative                / farp: huge
    cs = 0x02, // _CS-relative (near only)
    ss = 0x03, // _SS-relative (near only)
    ds = 0x04, // _DS-relative (near only)
    fs = 0x05,
    gs = 0x06,
    _,
};

/// Function modifier byte (Type.class when id == func). bit2 (0x04) = far modifier.
pub const FuncClass = enum(u8) {
    near_c = 0x00, // near cdecl/C
    near_pascal = 0x01,
    far_c = 0x04,
    far_pascal = 0x05, // inferred
    interrupt = 0x07,
    _,
};

pub const Type = packed struct { // 8 bytes
    id: u8, // TypeId
    name: u16, // tag name (struct/union/enum); else 0
    size: u16,
    class: u8, // modifier: ptr 0x04=near _DS, 0x01=huge, 0x00=far; func 0x00=near 0x04=far
    member_type: u16, // first member (struct/union) | pointee (ptr) | element (array) | return (func)
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 8);
    }
};

pub const Member = packed struct { // 5 bytes
    flags: u8, // 0 normal | 1..63 bitfield width | 0x80 last enum | 0xC0 list terminator
    name: u16,
    type: u16, // struct/union: type index | enum: enumerator value
    pub fn isTerminator(m: Member) bool {
        return (m.flags & 0xC0) == 0xC0;
    }
    pub fn bitWidth(m: Member) ?u6 {
        const w: u8 = m.flags & 0x3F;
        return if (m.flags & 0xC0 == 0 and w != 0) @intCast(w) else null;
    }
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 5);
    }
};

// ————— Trailing tables (present on every fixture) —————

pub const CoverageMapEntry = packed struct { // 2 bytes, one per segment
    start_index: u16, // 1-based start into the coverage-offset table (0 = none)
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 2);
    }
};
pub const CoverageOffset = u16; // basic-block code offset within the owning segment
pub const ModuleOptFlags = u32; // MO_* bits, one per module (0 = unoptimized)

// ————— C++ extension tables (empty for plain C; §15) —————

pub const ClassRecord = packed struct { // 11 bytes
    parent_index: u16, // 1-based into Parent table
    parent_count: u16, // number of parents (0 = base/root)
    member_index: u16, // 1-based into Member table (class's first member)
    name_index: u16, // class tag name-pool index
    virtual_ptr: u16, // vtable-pointer offset within the object
    info: u8, // bit0 virtual-base, bit1 public, bits2..7 vtable slot
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 11);
    }
};

pub const ParentRecord = packed struct { // 2 bytes
    class_index: u16, // 1-based Class-table index; bit15 (0x8000) = virtual base
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 2);
    }
};

/// Scope-Class and Module-Class share this 4-byte shape.
pub const ClassRange = packed struct { // 4 bytes
    class_index: u16,
    class_count: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 4);
    }
};
pub const ScopeClassRecord = ClassRange; // one per scope, when local classes exist
pub const ModuleClassRecord = ClassRange; // one per module that defines classes

// ————— Tables BC++ 3.1 never populates (count always 0); BOA-documented 16-bit forms —————

pub const BrowserRecord = packed struct { // 6 bytes
    symbol_index: u16,
    file_index: u16,
    line_number: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 6);
    }
};

pub const OptSymRecord = packed struct { // 9 bytes
    next: u16, // index of next record for this symbol (0 = end of list)
    offset: u16, // register-enum, as in Symbol
    sym_class: u8, // combined class/has_valid_BP/ret-words, as in Symbol.flags
    code_offset_start: u16,
    code_offset_end: u16,
    comptime {
        std.debug.assert(@bitSizeOf(@This()) == 8 * 9);
    }
};

/// runtime flat address of an image-relative (segment-paragraph, offset).
pub fn runtimeFlat(tds_segment: u16, tds_offset: u16, psp_seg: u16) u32 {
    const seg: u32 = @as(u32, psp_seg) + 0x10 + tds_segment;
    return seg * 16 + tds_offset;
}
```

Parser flow: read `Header`+`ExtHeader` at the trailer; resolve the name pool at
`trailer + 0x30 + extension_size + ext.name_pool_offset` (length `names_pool_size`); then read the
fixed-stride tables in the §3 order (symbols, modules, source-files, lines, scopes, segments,
correlations, types, members). For C++ output continue with the `class_entries × ClassRecord`,
`parent_entries × ParentRecord`, `scope_class_entries × ScopeClassRecord`,
`module_class_entries × ModuleClassRecord` tables, plus the 4-byte C++ coverage-prefix word (§15.6)
when `class_entries > 0`; then the Coverage-Map / Coverage-Offset / Module-Opt trailing tables. All
trailing tables are **skippable** — the name pool is already located via `name_pool_offset`. Use
`member.isTerminator()` to delimit per-aggregate member lists and accumulate member sizes for struct
field offsets; for an enum, follow the aux record (§12.3a) to its first enumerator.

---

## 17. Status: 100% mapped

Every table named in the BOA EXE-format block order (§3, lines mirroring the handbook's "Symbol
Table … Names Table" list) now has a confirmed 16-bit byte layout, and every enum is enumerated.
All six previously-open `[U]` items are closed:

| # | Item | Resolution | How |
|---|------|------------|-----|
| 1 | ext-header `parent`@0x32 vs `module_class`@0x3A split, + `overload`@0x36 | **[C]** parent@0x32, module_class@0x3A | **MI** (parent→2, module_class stays 1); overload@0x36 named by TDUMP |
| 2 | `memory_model` byte for compact/huge/tiny | **[C]** tiny=0x08, compact=0x0B, huge=0x0D (all six models) | `MMC`/`MMH`/`MMT` — byte = `(underbars<<3) ∣ MM_code` |
| 3 | pointer `class` `_CS`/`_ES`; func `class` `pascal`/`interrupt` | **[C]** ES=1,CS=2,SS=3,DS=4; func cdecl=0,pascal=1,far=4,interrupt=7 | `PTR.C` |
| 4 | enum → enumerator linkage | **[C]** aux record after the ENUM type record, byte +4 = first enumerator | `BENUM.C` (3 enums) |
| 5 | include-files records & coverage grouping | **[C]** includes = the source-file table (§6); coverage = Coverage-Map (per-segment start) + Coverage-Offset; module-opt-flags trailing | `INC.C`; full zero-residual walk |
| 6 | C++ Class/Parent/Scope-Class/Module-Class/Coverage/Browser/Overload/OptSym/RefInfo/Module-Opt layouts | **[C]** Class(11B), Parent(2B), Scope-Class(4B), Module-Class(4B), Coverage-Map(2B), Coverage-Offset(2B), Module-Opt(4B); Browser(6B)/OptSym(9B)/Overload/RefInfo **[B]** (BCC3.1 emits 0) | `CLS`/`MI`/`LCLS`/`BBCPP` |

**Tier-3 status (DECODED, not merely sized):** the **Class** and **Parent** tables (and the
**Scope-Class** / **Module-Class** tables) are no longer skipped — the parser RETAINS them and the
type layer renders a `TID_CLASS` as `class Foo` with its **data members** (name / type / byte offset,
honouring the `0x40` offset-reset record whose new running offset lives in the member **name** field —
e.g. CLS `New Offset 02`), its **direct base classes** (declaration order, with the `0x8000`
virtual-base flag and the computed `byte_offset` of each base subobject, §15.2), and its **method
signatures** (function records with flags `0x48`-based — `0x48` method / `0x49` dtor / `0x4A` ctor /
`0x4C` virtual — plus `0x60` static data, classified into `MemberKind`). The TID_CLASS→Class-table
link is `member_type` (§12.3, corrected). Verified by the C++ fixtures **`BBCPP`** (`Entity` base +
`Monster : public Entity` + `enum Shape`) and **`ACC`** (access keywords + every member kind + MI
offsets).

**Honest limit on C++ method/vtable recovery in BCC 3.1:** what is recoverable per method is only its
**typed signature** (the mangled name + the SPECIALFUNC return-type record). The callable body, vtable
slot assignment, overload sets, and RTTI live in the **Browser / Overload / Optimized-Symbol /
Reference-Info** tables, which **BCC 3.1 emits a count of 0 for on every fixture** (§15.5) — so vtable
layout and method bodies are *not* recoverable. Likewise, **no per-member or per-base access specifier**
(`public`/`private`/`protected`) is present anywhere in BCC 3.1's 16-bit Class (11B), member (5B), or
Parent (2B) records — TDUMP itself renders none — so access is **not** reported (only the virtual-base
flag is). This is now **empirically CONFIRMED** by the **`ACC`** fixture, which derives one base three
ways (`Pub : public`, `Pri : private`, `Prot : protected`) plus a class with a public and a private
data member: the Class `info` byte is a constant `0x0C` for *all* of them, the three Parent records are
byte-identical, and `pub_data`/`priv_data` both read `flags=0x00`. (The earlier "Class `info` bit1 =
public" reading was wrong, §15.1.) What **is** newly confirmed by `ACC`: the C++ member-kind flag bytes
— `0x48` method, `0x49` dtor, `0x4A` ctor, `0x60` static data — and the multiple-inheritance
**base-subobject offsets** (`BaseInfo.byte_offset`, §15.2).

**Fully mapped & CONFIRMED structures:** base header, extended header, symbol, module, source-file,
line, scope, segment, correlation, type (+ ordinal/enum aux record), member, class, parent,
scope-class, module-class, coverage-map, coverage-offset, module-optimization-flags. **Enums:**
SymbolClass, Language, MemoryModel (all 6), TypeId (full BOA set), PointerClass, FuncClass, the
register encoding, and the C++ member-attribute byte. §16 provides drop-in Zig definitions with
comptime size asserts for **every** table and enum above.

**Empirically unreachable (honest residuals), all skippable via `name_pool_offset`:**
- The **Browser / Optimized-Symbol / Overload / Reference-Information** tables: BC++ 3.1 emits a
  count of 0 for all four on every fixture (TDUMP confirms), so their bytes cannot be populated. The
  BOA-documented 16-bit forms are given in §15.5 / §16 and tagged **[B]**. (They surface only with
  the browser/optimizer/RTTI features BC++ 3.1's plain `-v` builds never enable.)
- The **virtual-base flag (0x8000)** in a Parent record, and pointer `class` 0x05/0x06 (`_FS`/`_GS`),
  are 16-bit real-mode never exercised — **[B]** from the BOA.
- One **[U-minor]**: the second `u16` of the C++ coverage-prefix word (§15.6). Its **size and
  position are confirmed** (the C++ block walk reaches the name pool at zero residual only with it
  present); only the meaning of that one always-`1` word is open. It reads `{class_entries, 1}` where
  `1` = `segments_count` = `modules_count` (both 1 across the corpus, hence inseparable). A C++ build
  with `segments_count ≠ modules_count` would close it. It is BOA-undocumented and parser-irrelevant.

Fixtures checked in this pass: **`MI`, `LCLS`, `MMC`, `MMH`, `MMT`, `PTR`, `BENUM`, `INC`** (+ their
`.LST`s and sources), alongside the pre-existing `TEST`, `RICH`, `ENUM`, `CLS`. Decoder scripts
`decode2.py`/`decode3.py`/`decode4.py`/`names.py` reproduce every claim above. The Tier-3 C++ pass
adds **`BBCPP`** (`BBCPP.CPP`/`.EXE`/`.LST`) — a base class with data members + a virtual method, a
single-inheritance derived class, and an `enum` — as the black-box oracle for class decoding. The
Tier-3 review pass adds **`ACC`** (`ACC.CPP`/`.EXE`/`.LST`) — one base derived `public`/`private`/
`protected`, plus a class with a non-virtual method, ctor, dtor, static data member, and a public +
private data member — proving access is unrecorded and confirming the member-kind flag bytes.
