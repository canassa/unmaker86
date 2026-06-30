# Borland C++ 3.x / Turbo Debugger 16-bit Symbolic Debug Info — Documented-Format Extraction

Cross-reference for the **empirical** TDS parser in zdos. This file captures only what
the *documentation* specifies, with every item cited to its source, and explicitly flags
(a) where the docs are **silent/ambiguous** (so the empirical effort is the sole authority)
and (b) where a **documented size conflicts** with a known-empirical correction (the empirical
value wins).

> Scope: the **16-bit** in-`.EXE` debug block (magic `0x52FB` / bytes `FB 52`), version
> **3.10**, as emitted by **TLINK 5.0 / 5.1** (`/v`) shipped with **Borland C++ 3.0 / 3.1**
> and Turbo Debugger 3.x. This is the "TDInfo" / Borland symbolic debug image appended to
> the load image of an MZ executable. It is *not* the 32-bit TD32 (`FB09`/`FB0A`, `.debug`
> section) format used by BC4+/C++Builder — noted where relevant.

---

## 0. Provenance of sources (read this first)

| Tag | Source | URL | Authority |
|-----|--------|-----|-----------|
| **BOA-HDR** | Ralf-Brown/HelpPC-style reproduction of the **Borland Open Architecture Handbook** debug header ("Format of Borland debugging information header (following load image)") | https://faydoc.tripod.com/structures/16/1624.htm and mirror https://excbadacc.es/borland | Primary-derived (verbatim BOA header table). High. |
| **BOA-SYM** | Indexed BOA text snippet (symbol-record field breakdown) surfaced via search of the BOA / "Borland Symbolic Debugging Information" doc | https://www.scribd.com/document/699552909/Borland-Symbolic-Debugging-Information (full text gated) | Primary (BOA prose), partial. |
| **BOA-DOC** | "Borland Symbolic Debugging Information" / "Open Architecture Handbook — The Borland Developer's Technical Guide" (full PDF, copyright-gated, not reproduced verbatim) | https://www.scribd.com/document/699553170/ ; distributed historically as `BOA4.ZIP` (subdir `BC4.32`) via Borland BBS | Primary, **not fully reachable** this pass. |
| **PARSER** | `ramikg/tdinfo-parser` — `tdinfo_structs.py` (Python `construct` defs for the 16-bit format) | https://github.com/ramikg/tdinfo-parser/blob/master/tdinfo_structs.py | **Secondary, known-buggy** (see §6 conflicts). Used for struct field layouts the BOA prose wasn't reachable for. |
| **VER** | VOGONS thread "Turbo Debugger Symbols versions and TLINK.EXE versions" | https://www.vogons.org/viewtopic.php?t=110504 | Secondary, version mapping. |

**Reachability notes for the next pass:**
- The canonical plain-text BOA debug chapter (`download.xskernel.org/docs/file formats/omf/borland.txt`) is **404** as of this pass.
- `web.archive.org` and `stackoverflow.com` are **blocked** from this environment's fetcher — retry the Wayback copy of `borland.txt` and SO Q#20679019 from a browser.
- Scribd serves the document but the fetcher **refuses verbatim reproduction** (copyright). The two Scribd docs (699552909 = the debug-info chapter; 699553170 = the whole BOA) are the highest-value primary targets if obtained directly.
- The full BOA = **`BOA4.ZIP`** (documents the `FB09` 32-bit format; the 16-bit `FB52` format is the predecessor and shares the conceptual model). Look for it on archive.org / Borland museum mirrors.

---

## 1. Version identification & the FB52 family  [VER]

The debug block is located by a signature word at the **start of the debug header**, which
sits *after* the load image (see §7 for placement). The header signature is `0x52FB`
(little-endian bytes `FB 52`). Immediately following are two version bytes (minor, then major)
encoded as BCD-ish nibbles:

```
FB 52 10 03   ->  signature 0x52FB, version 3.10  (TDS "3.10")
```

| TDS ver | Signature | TLINK | Product | Notes |
|---------|-----------|-------|---------|-------|
| 2.8 | (52FB family) | 2.0 | TASM 1.0 / Turbo C 2.0 | |
| 2.9 | | 3.0 | TASM 2.0 | |
| 3.0 | | 3.0 | BC++ 2.0 / TD 2.51 | |
| **3.10** | **52FB / 03.10** | **5.0 / 5.1** | **BC++ 3.0 / 3.1**, TD 3.x | **← zdos target** |
| 4.1 | | 5.x/6.1 | TASM 4.0 / BC++ 4.0/4.5 | start of 32-bit lineage tools |
| 4.3 | | 7.1 | TASM 5.0 / BC++ 5.0 | |

Source: [VER]. The 32-bit object/debug format documented in BOA4 uses different signatures
(`FB09`, and `FB0A` from the C++Builder linker) and lives in a `.debug` section, not appended
to an MZ load image. Treat 32-bit (TD32 / `tds2dbg` / `JclTD32`) docs as *related concepts only*.

---

## 2. Debug-information HEADER  [BOA-HDR — authoritative]

Reproduced from the BOA header table (faydoc 16/1624 ≡ excbadacc.es/borland). Offsets are
relative to the **signature word** (header start). All multi-byte fields little-endian.

### 2.1 Base header (0x00–0x2D) + extension-size word (0x2E)

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 00h | WORD | `signature` | `52FBh` |
| 02h | WORD | `version_id` | minor (lo byte) / major (hi byte); `03 10` ⇒ 3.10 |
| 04h | DWORD | `names_pool_size` | size of the name pool, in bytes |
| 08h | WORD | `names_count` | number of names in the name pool |
| 0Ah | WORD | `types_count` | number of **type** entries |
| 0Ch | WORD | `members_count` | number of **structure/class members** |
| 0Eh | WORD | `symbols_count` | number of **symbols** |
| 10h | WORD | `globals_count` | number of **global symbols** |
| 12h | WORD | `modules_count` | number of **modules** |
| 14h | WORD | `locals_count` | number of **locals** (optional) |
| 16h | WORD | `scopes_count` | number of **scopes** in scope table |
| 18h | WORD | `line_numbers_count` | number of **line-number** entries |
| 1Ah | WORD | `source_files_count` | number of **include / source files** |
| 1Ch | WORD | `segments_count` | number of **segment** records |
| 1Eh | WORD | `correlations_count` | number of **segment/file correlations** |
| 20h | DWORD | `load_image_size` | size of load image after removing uninitialized data + debug info |
| 24h | DWORD | `debugger_hook` | pointer into the debugged program (debugger hook) |
| 28h | BYTE | `program_flags` | see §2.3 |
| 29h | WORD | (reserved) | "no longer used" |
| 2Bh | WORD | `data_pool_size` | size of data pool, in bytes |
| 2Dh | BYTE | (padding) | |
| 2Eh | WORD | `extension_size` | size of the following header **extension** ("currently 00h, 10h, or 20h") |

**This is the complete set of "base 12 + extra" table counts** the task asked for. The base
counting tables are the 12 at 0x08–0x1E (names, types, members, symbols, globals, modules,
locals, scopes, line-numbers, source/include files, segments, correlations).

### 2.2 Header EXTENSION (0x30–0x48)  [BOA-HDR — version-gated, see caveat]

When `extension_size` (0x2E) is non-zero, these fields follow. These carry the **"extra"
tables** (C++ class/browser/optimizer metadata):

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 30h | WORD | `classes_count` | number of **class** entries |
| 32h | WORD | `parents_count` | number of **parent** (base-class) entries |
| 34h | WORD | `global_classes_count` | number of **global classes** |
| 36h | WORD | `overloads_count` | number of **overload** entries |
| 38h | WORD | `scope_classes_count` | number of **scope classes** |
| 3Ah | WORD | `module_classes_count` | number of **module classes** |
| 3Ch | WORD | `coverage_count` | number of **coverage-analysis** offsets |
| 3Eh | DWORD | `name_pool_offset` | offset (relative to symbol base) of the name pool |
| 42h | WORD | `browser_count` | number of **browser**-information records |
| 44h | WORD | `optimized_count` | number of **optimized-symbol** records |
| 46h | WORD | `debug_flags` | debugging flags |
| 48h | 8 BYTEs | (padding) | |

> **VERSION CAVEAT (important for the 3.10 target):** The extension block above is documented
> from the **BC++ 4.0 (debug-info 4.01)** lineage of the BOA header. For **TDS 3.10**, the C++
> browser / class / overload / coverage / optimizer tables largely **did not yet exist**, so
> `extension_size` is typically smaller (0x00 or 0x10) and most/all of 0x30–0x48 may be absent.
> **Do not assume these extra tables are present in 3.10 images** — gate on `extension_size`.
> [BOA-HDR + version reasoning; the empirical parser must confirm per-image.]
>
> Reconciliation with PARSER: `tdinfo-parser` models the header as base fields up to `0x2E`,
> then `Padding(14)` covering `0x20–0x2D` (it lumps load-image/hook/flags/data-pool into the
> pad), then `extension_size` (WORD), then `Padding(extension_size)` — i.e. it treats the whole
> 0x30+ extension as opaque. The BOA-HDR table above is the field-resolved version of that pad.

### 2.3 `program_flags` bits (0x28)  [BOA-HDR]

| Bit | Meaning |
|-----|---------|
| 0 | case-sensitive link |
| 1 | Pascal overlay program |
| 2–7 | **undocumented in reach** |

`debug_flags` (0x46) bit meanings are **not enumerated** in the reachable header doc — **silent**.

---

## 3. RECORD TABLES — on-disk order & placement  [PARSER, corroborated by header]

Per `tdinfo-parser`'s `DOS_MZ_EXE_STRUCT`, after the header the tables appear in this order;
the name pool is at the very **end** of the file (it is read by seeking back
`names_pool_size` bytes from EOF):

```
[header]
symbol_records   [symbols_count]
module_records   [modules_count]
source_files     [source_files_count]      (PARSER skips as count*6 bytes — layout undocumented)
line_numbers     [line_numbers_count]       (PARSER skips as count*4 bytes — layout undocumented)
scope_records    [scopes_count]
segment_records  [segments_count]
correlations     [correlations_count]        (PARSER skips as count*8 — EMPIRICAL: 16, see §6)
type_records     [types_count]
member_records   [members_count]             (PARSER models 5 — EMPIRICAL: 7, see §6)
...
name_pool        [names_count] NUL-terminated ASCII strings, at EOF-names_pool_size
```

> **Name references:** every `name` field below is a **1-based index into the name pool**
> (the i-th NUL-terminated string), *not* a byte offset. [PARSER; consistent with `names_count`.]

---

## 4. RECORD FORMATS

Where BOA prose was reachable it is used and tagged [BOA-SYM]; otherwise the field layout is
from [PARSER] and flagged as such (secondary, verify empirically).

### 4.1 Symbol record

**BOA-documented field breakdown** [BOA-SYM]: a symbol record carries
*symbol name, symbol type, symbol offset, symbol segment/class*, and the class byte is itself
a bitfield:

| Sub-field | Width | Meaning [BOA-SYM] |
|-----------|-------|-------------------|
| symbol class | 3 bits | storage class (see §5.2) |
| valid-BP indicator | 1 bit | whether BP-relative frame is valid |
| return-address word offset | 3 bits | word offset of the return address (for frame walking) |

**PARSER layout** (the byte view; secondary) [PARSER]:

| Off | Size | Field | Notes |
|-----|------|-------|-------|
| 0 | WORD | `index` | name-pool index (1-based) |
| 2 | WORD | `type` | index into type table |
| 4 | WORD | `offset` | offset within segment |
| 6 | WORD | `segment` | segment (linked value / selector — see §7) |
| 8 | BYTE | bitfield | PARSER decodes only `symbol_class` (low 3 bits) + `Padding(5)` |

> **CONFLICT / refinement:** PARSER models the class byte as `class(3) + pad(5)` and *drops*
> the **valid-BP** bit and **return-address word-offset** field that BOA-SYM documents inside
> that same byte. The BOA breakdown is richer; the empirical parser should decode all of:
> `class[0:3]`, `valid_bp[3]`, `ret_addr_word_off[4:7]`. **BOA wins on field meaning.**
> Total symbol-record size = **9 bytes** per PARSER (4 WORDs + 1 byte).

### 4.2 Module record  [PARSER — layout, mostly undocumented]

| Off | Size | Field | Notes |
|-----|------|-------|-------|
| 0 | WORD | `name` | name-pool index |
| 2 | 14 bytes | (opaque pad in PARSER) | **undocumented in reach** |

> **Documentation gap:** BOA prose (per search snippets) says the module header contains
> `language`, `memory_model`, an underscore flag, symbol/source-file **indices and counts**,
> and correlation index/count — i.e. the 14 "pad" bytes are *structured*: language code,
> memory-model code, flag byte, and several WORD index/count pairs. **The exact field order/
> widths within those 14 bytes are NOT pinned down by the reachable docs — EMPIRICAL is the
> authority here.** [BOA-DOC mentions the fields; layout silent. PARSER pads them out.]

### 4.3 Source-file record  [UNDOCUMENTED in reach]

PARSER does not model it — it skips `source_files_count * 6` bytes, implying a **6-byte**
record. Field semantics (name index + ?line-base/?count, or name index + time/size) are
**not specified** in any reached source. **EMPIRICAL is the sole authority on the 6-byte layout.**

### 4.4 Line-number record  [UNDOCUMENTED in reach]

PARSER skips `line_numbers_count * 4` bytes, implying a **4-byte** record. The conventional
encoding is `(line_number: WORD, code_offset: WORD)` correlating a source line to a segment
offset, but the reached docs **do not confirm** field order/widths or how runs are grouped
per source file. **EMPIRICAL authority.**

### 4.5 Scope record  [PARSER]

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 0 | WORD | `symbol_index` | first symbol of this scope (into symbol table) |
| 2 | WORD | `symbol_count` | number of symbols local to this scope |
| 4 | WORD | `parent` | parent scope index (lexical nesting) |
| 6 | WORD | `function` | owning function (symbol index) |
| 8 | WORD | `offset` | code offset where scope begins |
| 10 | WORD | `length` | code length covered by scope |

Size = **12 bytes**. Cross-refs: `symbol_index/symbol_count` slice the symbol table;
`parent` gives lexical nesting; `function` ties the scope to its function symbol. [PARSER]

### 4.6 Segment record  [PARSER]

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 0 | WORD | `module` | owning module index |
| 2 | WORD | `code_segment` | segment value |
| 4 | WORD | `code_offset` | start offset |
| 6 | WORD | `code_length` | byte length of the code region |
| 8 | WORD | `scope_index` | first scope for this segment |
| 10 | WORD | `scope_count` | number of scopes |
| 12 | 4 bytes | (pad in PARSER) | **undocumented in reach** |

Size = **16 bytes** per PARSER. The trailing 4 pad bytes are likely additional index/count
or correlation fields — **layout undocumented; EMPIRICAL authority.** [PARSER]

### 4.7 Correlation record (segment/file correlation)  [**SIZE CONFLICT — see §6**]

PARSER skips `correlations_count * 8` — i.e. it assumes an **8-byte** record and does **not**
decode any field.

> 🔴 **DOCUMENTED/PARSER SIZE CONFLICTS WITH EMPIRICAL.** The empirical zdos work proved the
> correlation record is **16 bytes, not 8**. **The empirical value (16) wins.** PARSER's `*8`
> is wrong. Field semantics (which source file ↔ which segment offsets / line-table slice) are
> **undocumented in reach** — EMPIRICAL is the sole authority on the 16-byte field layout.

### 4.8 Type record  [PARSER; matches BOA conceptual model]

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 0 | BYTE | `id` | type-ID / kind (see §5.1 enum) |
| 1 | WORD | `name` | name-pool index (0 if anonymous) |
| 3 | WORD | `size` | size in bytes of the type |
| 5 | BYTE | `class_type` | type "class"/sub-code qualifier (see §5.3 — **undocumented values**) |
| 6 | WORD | `member_type` | reference: index of element/return/member-list/pointed-to type |

Size = **8 bytes**. `member_type` is the polymorphic cross-reference used by the type system
(see §6/type-system below). [PARSER]

### 4.9 Member record  [**SIZE CONFLICT — see §6**]

PARSER layout (secondary):

| Off | Size | Field | Meaning |
|-----|------|-------|---------|
| 0 | BYTE | `info` | member info/attribute byte (bit meanings **undocumented in reach**) |
| 1 | WORD | `name` | name-pool index |
| 3 | WORD | `type` | member's type (index into type table) |

PARSER total = **5 bytes**.

> 🔴 **DOCUMENTED/PARSER SIZE CONFLICTS WITH EMPIRICAL.** The empirical zdos work proved the
> member record is **7 bytes, not 5**. **The empirical value (7) wins.** The extra 2 bytes
> (vs PARSER's 5) are most plausibly a bit-field-offset / member-offset WORD that PARSER omits;
> exact field is **undocumented in reach — EMPIRICAL authority.**

---

## 5. ENUMS

### 5.1 Type IDs (`TypeId`) — full table  [PARSER; these are Borland's documented 16-bit TIDs]

| Hex | Dec | Name | Meaning |
|-----|-----|------|---------|
| 0x00 | 0 | VOID | void |
| 0x01 | 1 | LSTR | Pascal long (4-byte len) string |
| 0x02 | 2 | DSTR | Pascal dynamic string |
| 0x03 | 3 | PSTR | Pascal string (length-prefixed) |
| 0x04 | 4 | SCHAR | signed char |
| 0x05 | 5 | SINT | signed int |
| 0x06 | 6 | SLONG | signed long |
| 0x08 | 8 | UCHAR | unsigned char |
| 0x09 | 9 | UINT | unsigned int |
| 0x0A | 10 | ULONG | unsigned long |
| 0x0C | 12 | PCHAR | pointer-to-char / near char* convention |
| 0x0D | 13 | FLOAT | float |
| 0x0E | 14 | TPREAL | Turbo Pascal 6-byte real |
| 0x0F | 15 | DOUBLE | double |
| 0x10 | 16 | LDOUBLE | long double (80-bit) |
| 0x11 | 17 | BCD4 | 4-byte BCD |
| 0x12 | 18 | BCD8 | 8-byte BCD |
| 0x13 | 19 | BCD10 | 10-byte BCD |
| 0x14 | 20 | BCDCOB | COBOL BCD |
| 0x15 | 21 | NEAR | near pointer |
| 0x16 | 22 | FAR | far pointer |
| 0x17 | 23 | SEG | segment pointer |
| 0x18 | 24 | NEAR386 | 32-bit near pointer |
| 0x19 | 25 | FAR386 | 48-bit far pointer |
| 0x1A | 26 | ARRAY | array |
| 0x1C | 28 | PARRAY | Pascal array |
| 0x1E | 30 | STRUCT | struct |
| 0x1F | 31 | UNION | union |
| 0x22 | 34 | ENUM | enum |
| 0x23 | 35 | FUNCTION | function |
| 0x24 | 36 | LABEL | label |
| 0x25 | 37 | SET | Pascal set |
| 0x26 | 38 | TFILE | Pascal text file |
| 0x27 | 39 | BFILE | Pascal binary file |
| 0x28 | 40 | BOOL | boolean |
| 0x29 | 41 | PENUM | Pascal enum |
| 0x2C | 44 | FUNCPROTOTYPE | function prototype |
| 0x2D | 45 | SPECIALFUNC | special function |
| 0x2E | 46 | OBJECT | C++/Pascal object |
| 0x34 | 52 | NREF | near reference (C++ ref) |
| 0x35 | 53 | FREF | far reference |
| 0x36 | 54 | WORDBOOL | word boolean |
| 0x37 | 55 | LONGBOOL | long boolean |
| 0x3E | 62 | GLOBALHANDLE | Windows global handle |
| 0x3F | 63 | LOCALHANDLE | Windows local handle |

> Gaps in the numbering (7, 11, 27, 29, 32–33, 42–43, 47–51, 56–61) are **reserved/unused or
> undocumented** in PARSER. The full BOA TID table may define some of these — **verify against
> the BOA PDF if a record carries an id not listed here.**

### 5.2 Symbol storage classes (`SymbolClass`, low 3 bits of class byte)  [PARSER + BOA-SYM]

| Val | Name | Meaning |
|-----|------|---------|
| 0 | STATIC | statically allocated (fixed seg:off) |
| 1 | ABSOLUTE | absolute address |
| 2 | AUTO | automatic (BP-relative stack local) |
| 3 | PASCAL_VAR | Pascal var parameter |
| 4 | REGISTER | in a register (register var) |
| 5 | CONSTANT | constant |
| 6 | TYPEDEF | type definition |
| 7 | STRUCT_UNION_OR_ENUM | tag for struct/union/enum |

> **Register encoding for `REGISTER` (class 4) and AUTO frame details:** the *which-register*
> code and the storage-location encoding for locals are **NOT specified in reach** — for a
> `REGISTER` symbol, how the register number is stored (likely in the symbol `offset`/`segment`
> field or in the upper bits of the class byte) is **undocumented; EMPIRICAL authority.**

### 5.3 Type `class_type` sub-codes (type record byte @ off 5)  [**UNDOCUMENTED**]

PARSER reads it as an opaque `Byte` with **no enum**. The sub-code distinguishes variants
within an id (e.g. signed/unsigned qualifiers, struct vs class, near/far flavor, bitfield
host). **Values are NOT enumerated in any reached source — EMPIRICAL is the sole authority.**

### 5.4 Language & memory-model codes (module record)  [**UNDOCUMENTED layout**]

BOA prose references `language` and `memory_model` fields in the module header, but the
reached docs do **not** give the code tables (e.g. C=?, C++=?, Pascal=?, ASM=?; tiny/small/
compact/medium/large/huge model values) **nor their byte offsets** within the module record.
**EMPIRICAL authority on both the codes and their placement.**

### 5.5 `program_flags` / `debug_flags` bits — see §2.3 (only bits 0–1 of program_flags documented).

---

## 6. Type-system encoding (how complex types reference others)  [PARSER + model]

Each entry in the **type table** is one 8-byte type record (§4.8). Complex types are built by
cross-referencing via the `member_type` field and the **member table**:

- **Pointer / reference** (`NEAR`/`FAR`/`SEG`/`NEAR386`/`FAR386`/`NREF`/`FREF`): `member_type`
  → the **pointed-to / referenced** type index. `size` = pointer width.
- **Array** (`ARRAY`/`PARRAY`): `member_type` → **element** type. `size` = total bytes
  (element count = size / element-size). Index-type encoding is **undocumented in reach**.
- **Struct / union / object** (`STRUCT`/`UNION`/`OBJECT`): `member_type` → index of the **first
  member record**; member count is **not in the type record** (delimited by run / by the next
  type's member base) — exact delimiting rule **undocumented; EMPIRICAL authority**. Each
  member record (§4.9) gives member `name` + member `type` (+ the empirically-confirmed extra
  offset/bitfield bytes that make it 7, not 5, bytes).
- **Enum** (`ENUM`/`PENUM`): `member_type` → member list of enumerators (name + value);
  value storage is **undocumented in reach**.
- **Function / prototype** (`FUNCTION`/`FUNCPROTOTYPE`/`SPECIALFUNC`): `member_type` → **return**
  type; parameter-type list encoding is **undocumented in reach**.
- **Typedef**: represented at the **symbol** level via `SymbolClass.TYPEDEF` (the symbol's
  `type` field points at the aliased type), not as a distinct type-record id.

> All "first-member index + count delimiting" and parameter-list rules above are the parts the
> **empirical effort owns** — the reachable documentation does not pin them down.

---

## 7. Address / segment model & image placement  [BOA-HDR + PARSER]

- The debug block is **appended to the MZ load image**. PARSER locates the header start as
  `file_size_in_pages*512 - (512 - used_bytes_in_last_page)` — i.e. it begins at the MZ-declared
  end-of-image (the `e_cblp`/`e_cp` fields at MZ offsets 2 and 4), **not** at physical EOF. The
  name pool then sits at the actual EOF, read by seeking `names_pool_size` back from EOF. [PARSER]
- `load_image_size` (header 0x20) = size of the runnable image *after* uninitialized data and
  the debug block are removed — i.e. it bounds where real code/data ends and debug info begins. [BOA-HDR]
- Symbol/segment `segment` fields hold **linked segment values** (paragraph values as fixed up
  in the EXE, relative to the load base), and `offset` is the offset within that segment. The
  **exact relocation relationship** (whether segment values are file-relative paragraphs needing
  the runtime load segment added, vs. already-relative) is **not spelled out in reach** — this
  is a determinism-relevant detail the **empirical effort must nail down** against actual zdos
  load addresses. [BOA-HDR partial; EMPIRICAL authority on the relocation math.]
- `debugger_hook` (0x24) is a far pointer into the program used by the debugger; not needed for
  static symbolication.

---

## 8. Summary: what the docs cover vs. where the empirical effort is sole authority

**Fully documented (BOA-authoritative):**
- The **header** — every table count incl. all extra tables (§2.1/2.2), program-flags bits 0–1,
  the load-image/name-pool placement model.
- **Symbol-record bit breakdown** (class + valid-BP + return-addr-word-offset) [BOA-SYM].
- The **type-ID table** and **symbol storage-class enum** (via PARSER; these are Borland's TIDs).

**Layout known only from the (secondary, buggy) PARSER — verify empirically:**
- Module (16-byte total, fields opaque), scope (12B), segment (16B), type (8B) records.

**Undocumented in reach — EMPIRICAL is the SOLE authority:**
- Source-file record fields (6B), line-number record fields (4B), **correlation record fields**.
- Module record's internal layout (language/model/flag/index-count fields within its 14 bytes).
- Type `class_type` sub-code enum; register/storage-location encoding for `REGISTER`/`AUTO`.
- Language & memory-model code tables and their offsets; `debug_flags` bit meanings.
- Struct/enum/function member-list delimiting & parameter encoding; array index-type.
- Exact segment-value↔runtime-load-address relocation math.

**🔴 Documented/parser size CONFLICTS — empirical value WINS:**

| Record | PARSER/doc size | **EMPIRICAL (correct)** | Status |
|--------|-----------------|------------------------|--------|
| Correlation | 8 bytes (`tdinfo-parser` `*8`) | **16 bytes** | PARSER wrong; use 16 |
| Member | 5 bytes (`Byte+WORD+WORD`) | **7 bytes** | PARSER wrong; use 7 |
| Symbol class byte | class(3)+pad(5) | class(3)+validBP(1)+retAddrOff(3) | PARSER under-decodes; BOA-SYM richer |

---

### Most valuable single source
**The BOA header table reproduced at faydoc.tripod.com/structures/16/1624.htm (≡ excbadacc.es/borland)** —
the only reachable *primary-derived* spec, and it fully resolves the header (all table counts +
extension fields) that the parser source only pads over. The `ramikg/tdinfo-parser` source is
the most valuable *secondary* (record byte-layouts), but must be used with the two known size
corrections above.
