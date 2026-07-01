# M-S3 — `evaluate` & `setVariable` for the Source-Level Debugger

**Status:** plan (no code). Zig 0.16, for the zdos deterministic, headless, cycle-reproducible
16-bit real-mode DOS emulator (MCP/HTTP debugger API). Companion to `debug-m2-plan.md`,
`debug-core-plan.md`, and `debug-core-architecture.md`.

This plan turns the **two pieces M-S2 explicitly deferred** (`debug-m2-plan.md §4`,
`§9 "(deferred) evaluate — M-S3"`, `§10 "(M-S3, separate)"`) into working tools:

- **`evaluate{frame, expr}`** — a real recursive-descent / Pratt C-expression evaluator over the
  symbol type graph + the peek path. It **GENERALIZES** the shipped bounded `inspect`
  (`vars.zig:inspectPath`, `:548`) from a path grammar (`ident (.f | ->f | [const])*`) to the full
  C-expression grammar, while keeping the *exact same* peek-only, no-fabrication contract.
- **`set_variable{frame, lvalue, value}`** — resolve an lvalue (reusing the evaluator) to an
  address/register + type, then perform a **deliberate, deterministic poke** through the *same*
  committed write path `/api/mem` write and `/api/cpu/reg` patch already use
  (`Controller.writeMemPhys`/`writeMem`/`setReg16`/`setReg8`, `controller.zig:1166/1171/1150/1153`).

> **Prime directive (CLAUDE.md §1): determinism.** `evaluate` is a **PURE, PEEK-ONLY, ZERO-CYCLE**
> function of the machine state at the stop cycle. It **NEVER executes the guest** (so **no function
> calls** in expressions — a call would charge cycles and inject an unrecorded input), **never** has
> side effects (no `=`, no `++`/`--`), never reads a host clock/RNG/float, never enters
> `Machine.Snapshot`. `set_variable` is a **DELIBERATE MUTATION** — a *new deterministic input*
> (CLAUDE.md §1 "same binary + SAME INPUTS"), exactly like the existing `writeMem`/`setReg` pokes:
> explicit, Stopped-gated, and it changes state deterministically without ever advancing CS:IP or
> charging cycles.
>
> **No fabrication (CLAUDE.md §2).** A wrong expression result or a mis-written variable is the
> *worst* possible outcome for a debugger — the exact failure mode this project exists to escape.
> Every form we cannot evaluate *faithfully* returns a **typed error** (`unsupported_expression`,
> `unresolved`, `not_lvalue`, `type_error`, `divide_by_zero`), **never a guessed value**. No
> regex-hack "evaluator"; C integer semantics (16-bit `int`, signedness, integer promotion, pointer
> arithmetic scaled by pointee size) are implemented *correctly* or refused honestly. The
> honest-degradation catalogue (§F) is the heart of this plan.

---

## Table of Contents

0. [Ground truth this plan builds on](#0-ground-truth-this-plan-builds-on)
1. [A. `evaluate` — the expression language](#a-evaluate--the-expression-language)
2. [B. `set_variable` — writing a resolved lvalue](#b-set_variable--writing-a-resolved-lvalue)
3. [C. Cross-cutting: tool surface, transport, gates](#c-cross-cutting-tool-surface-transport-gates)
4. [D. Milestone sequencing](#d-milestone-sequencing)
5. [E. Test plan](#e-test-plan)
6. [F. Determinism / no-fakes checklist + honest-degradation catalogue](#f-determinism--no-fakes-checklist--honest-degradation-catalogue)
7. [G. Open `TODO(verify):` items](#g-open-todoverify-items)

---

## 0. Ground truth this plan builds on

Read these first; this plan cites them by `file:line` and stays consistent with them. **M-S3 does
NOT re-do M-S2** — it reuses the shipped resolver + renderer + transport + handle lifecycle.

**The M-S2 foundation `evaluate`/`setVariable` extend:**

- `src/debug/core/vars.zig` — **THE foundation.**
  - `inspectPath` (`:548`) — the bounded path resolver evaluate generalizes: tokenize (the private
    `Parser`, `:736`) → resolve head local by name (`frameLocals`, `:47`) → walk `.field`/`->`/`[const]`
    segments (`stepOne`/`fieldAccess`/`derefStep`/`indexAccess`, `:633/:649/:672/:691`) → render.
  - `renderValueAt` (`:163`) — the type-directed renderer producing a `core.Variable` (value text +
    hex + type + a minted `variables_ref` for aggregate/array/pointer). Its `Place` union
    (`:157` = `mem:u32 | reg:u8 | imm:i64`) is exactly the value-location the evaluator needs.
  - `Cursor` (`:532` = `{type_ref, place, addr, bit}`) — a resolved position (type + where its value
    lives + optional bitfield window). The evaluator's lvalue == a `Cursor`.
  - `ptrTarget` (`:371`) — decode a stored pointer's bytes → `{addr, is_null}` applying the real-mode
    segment base per `PtrKind`; `mintPointee` (`:390`); `renderBitfieldAt` (`:354`) + `bitfieldStart`
    (`:336`); the scalar helpers `readMem` (`:412`, RAM-slab-bounds-checked via `ramSlabSize`),
    `readReg` (`:422`, T7 high-byte decode), `leBytes` (`:440`), `signExtend` (`:450`), `isSigned`
    (`:461`), `typeSize` (`:468`), `typeInfoOf` (`:726`); `renderPrimitive` (`:224`, float→hex),
    `renderEnum` (`:240`), `renderPointer` (`:253`); `nullVar` (`:722`), `unreadableVar` (`:491`).
  - The `VarAvail` honest signals (`core.zig`: `ok/outer_frame_register/unreadable/no_storage`).
- `src/debug/core/debugger.zig` — `SourceDebugger` (`:200`): `mintHandle` (`:314`)/`resolveHandle`
  (`:325`), the strictly-monotonic `stop_epoch` (`:216`) + `ExpandTable`/`ExpandNode` (`:181`),
  `beginResume` (`:291`)/`noteStopped` (`:299`)/`invalidateHandles` (`:282`), `state` (`:210` =
  `configuring/running/stopped/terminated`). The §6 stop-epoch wiring is DONE.
- `src/debug/symbols/types.zig` — `TypeGraph`: `typeInfo` (`:338`) → `TypeInfo` (`:55`:
  `primitive{id,size} | pointer{kind,pointee,size} | array{element,count,size} |
  aggregate{name_index,size,is_union,is_class,…} | enumeration{…} | function{ret,far,conv} |
  unknown`); `typeSize` (`:330`), `members` (`:396`), `bases` (`:406`), `enumerators` (`:413`),
  `typeName` (`:423`, **STREAMS into a `*std.Io.Writer`, returns void** — T13, never a slice),
  `primitiveName` (`:512`, free fn), `localsForScope`/`parentOf` (`:469`/`:476`). `TypeId`
  (`format.zig:185`: `schar/sint/slong/squad/pchar` signed; `uchar/uint/ulong/uquad` unsigned;
  `char=1 int=2 long=4 quad=8` bytes; `float/double/ldouble/tpreal/tbyte` the FP family).
  `Storage` (`:146` = `auto:i16 | register:u8 | static:{segment,offset} | constant:i16 |
  absolute:u16 | other:u8`). `PtrKind` (`:38`), `format.Reg` (`:83`, `ax=0…di=7 al=8…bh=15`).
- `src/debug/symbols/index.zig` — `nameToSymbol(name) -> ?SymRef` (`:323`); `SymRef{sym_index,
  segment, offset, type_index, name_index}` (`:41`) — **this is the global/static identifier
  resolver** (a name not in the frame's locals). `addrToFunction` (`:287`), `functionName` (`:397`),
  `typeRefForFunction` (`:417`).
- `src/debug/controller.zig` — reads: `cpuSnapshot` (`:1478`), `peekMemPhys` (`:1526`), `ramSlabSize`
  (`:1538`, `= self.m.bus.ram.len`). **The WRITE path `set_variable` REUSES:** `writeMem(seg, off,
  src)` (`:1166`), `writeMemPhys(phys, src)` (`:1171`), `setReg16(Reg16, u16)` (`:1150`),
  `setReg8(Reg8, u8)` (`:1153`), `setReg32` (`:1147`). `Reg16 = enum(u3){ax cx dx bx sp bp si di}`
  (`:215`), `Reg8 = enum(u3){al cl dl bl ah ch dh bh}` (`:216`).
- `src/api/queue.zig` — Command arms (`:250`-region; the M-S2 precedents `dbg_inspect: DbgInspectReq`
  `:272`/`:294` with the **FLATTENED** `path:[DBG_PATH_CAP]u8 + path_len` — T9), the ONE nested-result
  arm `dbg_json: DbgJsonResult{body_len}` (`:324`/`:827`), `ErrCode` (`:506`: `not_stopped` `:528`,
  `unresolved` `:533`, `unsupported_expression` `:553`, `stale_handle` `:545`, `bad_frame` `:548`,
  `response_too_large` `:540`, `address_out_of_range` `:509`), `RegSetCmd` (`:479`, the reg-patch
  wire), `mem_write` (`:88`, payload in `RequestCtx.scratch`).
- `src/api/worker.zig` — the pattern evaluate/set_variable copy: `dbgInspect` (`:600`) → `dbgReady`
  gate → `frameOrBad` (`:494`) → `core.vars.inspectPath` → `writeInspect` (`:620`,
  `{"path":…,"result":<Variable>}`) → `sealJson`; `writeVariable` (`:712`); `dbgVariables` (`:563`);
  `inSlab` (`:160`, uses `ramTotalSize` `:151` = the region-table `.ram` len); the committed-write
  handlers `memWritePhys` (`:997`)/`applyRegSet` (`:975`).
- `src/api/server.zig` — `submitDebuggerJsonAndRespond` (`:2760`, HTTP) +
  `submitMcpDebuggerJsonAndRespond` (used `:2483`, MCP): copy-under-`session.lock`, stream owned
  bytes; `writeResponseBody` (`:3120`); `errInfo` (`:3529`, `ErrCode → {status,code,msg}`); the
  worker-spawn `.dbg_json` field (`:391`).
- `src/api/mcp_tools.zig` — `Tool{name,description,input_schema,per_machine}` catalog; `buildCommand`;
  `set_register`/`write_memory`/`write_memory_seg` tools (`:183/:198/:212`) + `handleRegSet` (`:616`)
  — the mutation-tool precedent `set_variable`'s wire follows; the `inspect` tool row (`:459`).
- **The gates:** `src/debug/determinism_test.zig:sources` (grep gate — add `core/expr.zig`);
  `src/api/determinism_test.zig:155` (`expectNoPointerFields(q.Command)` + `(q.Response)`).

**The M-S3 test fixtures (already in-tree).** `examples/BB2.C`/`BB2.EXE` and `examples/BB2M.C`/
`BB2M.EXE` (the M-S2 "richer fixture", T17) exercise pointer + array + bitfield + recursion — the
exact features the evaluator must get right. `examples/BB.C`/`BB.EXE` remains the canonical
`clamp`/`main` worked example (`v=300`, `lo=BX`, `hi=CX`, `r=DX`;
`symbols_integration_test.zig:153-187`).

---

## A. `evaluate` — the expression language

### A.1 Grammar (EBNF) — a proper C-expression subset

Parsed by a **Pratt (precedence-climbing) parser** in a new pure module `src/debug/core/expr.zig`
(recursive-descent for the unary/postfix layer, precedence climbing for binary — NOT ad-hoc string
matching, forbidden by CLAUDE.md §2). Included forms:

```ebnf
expr        = ternary ;
ternary     = binary [ "?" expr ":" ternary ] ;
binary      = unary { binop unary } ;                (* precedence climbing, table A.2 *)
unary       = ( "*" | "&" | "-" | "+" | "~" | "!" ) unary
            | "sizeof" ( "(" typename ")" | unary )   (* UNEVALUATED operand, A.6 *)
            | "(" typename ")" unary                  (* C cast, A.5 *)
            | postfix ;
postfix     = primary { "." ident | "->" ident | "[" expr "]" } ;   (* [] is now a FULL sub-expr *)
primary     = ident | integer | charlit | "(" expr ")" ;
integer     = dec | "0x" hex | "0" oct ;              (* with optional u / l / ul suffix *)
charlit     = "'" ( char | escape ) "'" ;             (* value = the byte, type int *)
typename    = ( "int" | "char" | "short" | "long" | "unsigned" | "signed" | "void" )+
            | ( "struct" | "union" | "enum" ) ident   (* A.5: needs a tag→type_ref resolver *)
            { "*" } ;                                  (* pointer suffixes *)
ident       = ( alpha | "_" ) { alnum | "_" } ;
```

**EXCLUDED — honest `unsupported_expression`, NEVER a partial-eval (state the boundary + WHY):**

| Form | Why excluded (the CLAUDE.md rule it would break) |
|---|---|
| **Function call `f(...)`** | Running the guest charges cycles and injects an **unrecorded input** — breaks determinism + the peek-only invariant (CLAUDE.md §1; `debug-core-plan.md §10 risk 4`). There is no faithful way to "call" without executing. |
| **Assignment `=`, compound `+=`…** | A **side effect** — that is `set_variable`'s job (a deliberate, explicit mutation). `evaluate` is pure/read-only. |
| **`++` / `--`** (pre or post) | A side effect (mutation of a scalar) — same as assignment. **C2: the lexer must tokenize `++`/`--` by MAXIMAL MUNCH as distinct tokens** — otherwise `++x` parses as `+(+x) == x` and `x--` leaves a trailing `--`, both **fabricating** a result. A `++`/`--` token → the parser rejects with `unsupported_expression`. |
| **Comma operator `a, b`** | Its *only* use is sequencing side effects; with no side effects it is a pointless discard of `a`. Excluded to avoid a misleading "evaluated `a`" impression. |
| **Float arithmetic** (any operator whose operand is `float`/`double`/`ldouble`/`tpreal`) | zdos has **no x87** (memory *no-FPU-constraint*) and the core grep gate **forbids `f32`/`f64`** (`determinism_test.zig`). A host float computation would be a gate violation *and* host-rounding nondeterminism. (Reading a *bare* float value still works — it renders as hex bytes, A.7.) |

**C2 — explicit end-of-input (no partial evaluation).** After parsing a complete `expr`, **any
leftover token is a hard error** — so `a, b`, `x = y`, `x++`, `a b` NEVER return a partial `a`/`x`.
The top-level `evaluate` asserts the cursor reached end-of-input (mirroring the `vars.zig` path
parser, whose `parseSeg` rejects any stray character, `:788`); a residual token → the error the
residual implies (`,`/`=`/`++` → `unsupported_expression`; a stray identifier/paren → same).

The parser is bounded and **total** (P3/P4 — a parser is an attack surface): `expr` ≤ **`DBG_EXPR_CAP`
= 256** bytes; recursion depth ≤ **`MAX_EVAL_DEPTH` = 64** enforced at *every* recursive entry (A.8);
**every input byte is either a token or a typed error, never `unreachable`/panic**; an integer literal
that overflows `u64` → a typed error via `std.fmt.parseInt` refusal (never a silent wrap/panic,
`vars.zig:781` precedent); a string literal `"…"` / an unrecognized byte has no production →
`unsupported_expression`. A deeper/longer input → `unsupported_expression`. (Mirrors `inspectPath`'s
`MAX_INSPECT_SEGS` posture, `vars.zig:524`.)

### A.2 Precedence / associativity (Pratt binding powers, lowest→highest)

*(Panel-validated against C: binary `&` correctly binds BELOW `==`; short-circuit `&&`/`||` and the
unevaluated `sizeof` operand are preserved — do not regress.)*

| Level | Operators | Assoc |
|---|---|---|
| 1 | `?:` (ternary) | right |
| 2 | `\|\|` | left (short-circuit, A.4) |
| 3 | `&&` | left (short-circuit) |
| 4 | `\|` | left |
| 5 | `^` | left |
| 6 | `&` (binary AND) | left |
| 7 | `==` `!=` | left |
| 8 | `<` `>` `<=` `>=` | left |
| 9 | `<<` `>>` | left |
| 10 | `+` `-` | left |
| 11 | `*` `/` `%` | left |
| 12 (prefix) | `* & - + ~ !` `(cast)` `sizeof` | right |
| 13 (postfix) | `.` `->` `[…]` | left |

### A.3 The internal value/type representation (a tagged `{type, bytes|scalar, optional address}`)

The evaluator carries a pure-function-of-machine-state value:

```zig
// src/debug/core/expr.zig
const EvalVal = struct {
    ty:    EvalType,        // the resolved C type (for signedness / size / pointee-scaling / render)
    store: Store,           // where/what the value is
};
const Store = union(enum) {
    /// An addressable object NOT materialized — reuse of vars.zig's Cursor (place+addr[+bit]).
    /// This is what makes a result an LVALUE (assignable / address-takeable / member/index-navigable).
    lvalue: vars.Cursor,
    /// A materialized rvalue: an integer or pointer BIT PATTERN (sign per `ty`), width ≤ 8 bytes.
    rvalue: u64,
};
const EvalType = union(enum) {
    graph:   u16,                                   // a TypeGraph type_ref (identifiers, members, derefs)
    scalar:  struct { bits: u8, signed: bool },     // a SYNTHESIZED int (literal / arith result / sizeof)
    pointer: struct { pointee: u16, kind: PtrKind, far: bool }, // SYNTHESIZED by `&` (pointee is a graph type_ref)
};
```

Key invariants that keep this bounded and faithful:

- **Every lvalue is graph-typed** (`ty = .graph`): you can only navigate/address an object that came
  from an identifier/member/element, and those always carry a `TypeGraph` type_ref. So a synthesized
  `.pointer` produced by `&` always has a *graph* pointee — **no pointer-to-synthetic recursion**
  (`&&x` fails earlier: `&x` is an rvalue, so the outer `&` → `not_lvalue`).
- **Pointer arithmetic keeps the graph pointer type_ref.** `p + 1` (p: `int*`) → `ty = .graph(int*
  type_ref)`, `store = .rvalue(new_offset_bits)`. No synthetic pointer type is needed for arithmetic;
  only `&` needs one (the type "pointer to X" may have no type record).
- An **rvalue** never has an address (that's what makes `&rvalue` → `not_lvalue`).

**C1 — the integer-literal type LADDER (sets `EvalType.scalar{bits,signed}` at the leaf; wrong here
= wrong signedness/width silently, e.g. `0xFFFF > 0` must be `1`, `40000 + 40000` must be `80000`).**
A literal's type is the **first** type on its ladder that represents its value:
  - **Decimal, no suffix:** `int → long → long long` (all **signed**). `40000` → `long` (32-bit
    signed), so `40000 + 40000 == 80000`, not a 16-bit wrap.
  - **Hex / octal, no suffix:** `int → unsigned int → long → unsigned long`. `0xFFFF` → `unsigned
    int` (fits u16), so `0xFFFF > 0 == 1` (unsigned), not `-1 > 0`.
  - **Suffixes:** `u` forces unsigned (drop the signed rungs); `l`/`ll` raise the minimum rank; `ul`
    both. A value that fits no rung → the P3 parse error.
Char literals are `int` (signed, value = the byte). This is the ONLY place synthetic scalar types are
minted; all downstream widths flow from `typeSize`/`TypeId`.

- **C4 — the width-masking invariant.** `Store.rvalue: u64` always holds the value **masked to its
  type width** (`bits/8` bytes). Every binary/unary op FIRST re-derives each operand's true value via
  `signExtend(rvalue, bits/8)` **when `signed`** (zero-extend when unsigned), computes in `i64`/`u64`,
  then **masks the result to the result width** before storing. (Without this, `30000 + 30000` stored
  as a raw `int` would read back `-5536` and `> 0` would wrongly yield `0`.)

**Loading a scalar** from an lvalue for use in arithmetic (`loadScalar(cursor) -> {u64 bits, signed,
size}`) reuses `vars.readMem`/`readReg` + `leBytes` + `signExtend` (promoted to `pub`), with these
type-specific rules:
- **C7 — enum operands.** An enum lvalue must NOT route through `isSigned` (which returns `false` for
  `.enumeration`, `vars.zig:461`). `loadScalar` on an `.enumeration` sign-extends by `typeSize` and
  promotes to **signed `int`** (mirroring `renderEnum`, `vars.zig:243`) — so a negative enumerator
  (`Z7 = -5`) reads `-5`, not `65531`.
- **Array/aggregate operand.** An **array lvalue** used where a scalar is required (a binary operand,
  a condition) → **array-to-pointer decay** (a synthesized `pointer` rvalue = the array's address,
  pointee = element type); an **aggregate** operand → `type_error` (C forbids struct arithmetic).

### A.4 C-semantics fidelity (get it RIGHT or refuse)

- **16-bit `int`.** `int`/`unsigned int` are 16-bit; `long`/`unsigned long` 32-bit; `char` 8-bit
  (**signed** — Borland default, `pchar` is signed). `sizeof` and all widths come from
  `typeSize`/`TypeId`, never hardcoded per-operator.
- **Integer promotion.** Any operand of rank < `int` (an 8-bit `char`, an extracted bitfield, an
  `enum`) is promoted to **`int` (16-bit signed)** before use, since `int` represents all `uchar`
  values. Enums promote to `int` (C7).
- **Usual arithmetic conversions.** After promotion, the two operands are brought to a common type by
  rank (`long` > `int`) then signedness (if same rank and one is unsigned → unsigned). Implemented as
  a `commonType(a, b)` over `EvalType` that yields the result `{bits, signed}`; the operation is done
  in `u64`/`i64` then **masked + sign-interpreted** to the result width (C4). *(Note: this rank logic
  relies on this type graph's STRICT-DOUBLING widths `char=1 < int=2 < long=4 < quad=8`; a future
  32-bit port must revisit `int`-width and the promotion target.)*
- **C3 — signed `/` and `%` truncate toward ZERO.** Use `@divTrunc`/`@rem` (NOT `@divFloor`/`@mod`):
  `-7 / 2 == -3`, `-7 % 3 == -1`. When BOTH operands are unsigned, use unsigned division. (`@divFloor`
  would give `-4`/`+2` — a silently wrong number.)
- **C6 — shift-count validation.** `<<`/`>>`: result type = the (promoted) LEFT operand; a right shift
  of a signed value is **arithmetic** (sign-preserving `@shr` on the signed value), of an unsigned
  value **logical** — chosen by the left operand's signedness. A shift count `< 0` **or** `≥
  width(promoted-left)` → **`type_error`** (validated/clamped BEFORE any `@shl`/`@shr`, which would
  otherwise panic in Zig on an out-of-range count).
- **Pointer arithmetic scaled by `typeSize(pointee)`.** `ptr ± int` and `int + ptr` add
  `int * typeSize(pointee)` to the pointer's *offset* (real-mode: masked to `u16` for a near pointer;
  for a far/huge pointer the offset is adjusted, and huge is segment-normalized). `ptr - ptr` (same
  pointee type) → `ptrdiff` = `(off_a - off_b) / typeSize(pointee)`, result type `int`. A `ptr ± int`
  where `typeSize(pointee) == 0` (incomplete/void*) → `type_error`.
- **`&` (address-of)** — requires an lvalue → a synthesized `pointer{pointee = operand.type_ref,
  kind}` rvalue whose bits are the operand's `addr.off` (near) or `seg:off` (far). A non-lvalue
  operand → `not_lvalue`. A register-resident lvalue has **no address** → `not_lvalue` (you cannot
  take the address of a register). **H1 — `&` of a BITFIELD member → `type_error`:** a bitfield
  `Cursor` carries a real container `addr` (`cur.bit != null`), so a naive `&` would fabricate the
  *container's* address; C forbids `&bitfield`, so it is refused explicitly.
- **`*` (deref)** — requires a pointer (or a decayed array); reuse `ptrTarget` → the pointee
  `Cursor` (an lvalue). A **null** pointer → the honest `<null>` terminal (`vars.nullVar`), an
  out-of-slab target → `unreadable` (`vars.unreadableVar`) — same as `inspect`, never a wild read.
  Deref of a non-pointer → `type_error`.
- **`[expr]`** — `a[i]` ≡ `*(a + i)`; the index is now a **full sub-expression** (vs `inspect`'s
  constant). Handled by **`indexAccessExpr` (NEW code**, generalizing `vars.indexAccess` from a `u32`
  const to a runtime `i`); an array index is **bounds-checked** against `arr.count` (out of range →
  `type_error`, never a wild read past the array); a pointer index scales by `typeSize(pointee)`.
  **H3 — `&arr[N]` one-past-end** (legal C) is refused by the bounds check (an honest over-refusal —
  acceptable and noted; a debugger rarely needs the end sentinel address).
- **`.`/`->`** — reuse `fieldAccess`/`derefStep` (`vars.zig:649/:672`) verbatim; a member of a
  non-aggregate → `type_error`; a missing member → `unresolved`.
- **`sizeof`** — A.6.
- **Casts** — A.5.
- **Division / modulo by zero** → **`divide_by_zero`** (a typed error), **never a CPU trap** (the
  evaluator computes host-side; it just refuses). `INT_MIN / -1` overflow → `type_error`.
- **Comparisons/`!`/`&&`/`||`** yield `int` `0`/`1`. `&&`/`||` **short-circuit for real** (do not
  evaluate the dead branch) — so a dead `x && (1/0)` does *not* raise `divide_by_zero`, matching C.
- **Pointer relational/equality** (a real-mode nuance, documented): near pointers compare by
  `offset`; `==`/`!=` on far pointers compares the full `seg:off` pair (C semantics); `<`/`>` on far
  pointers compares the **normalized linear** address (well-defined only for `huge` in C — flagged as
  a documented approximation, never silently wrong: it is a real address ordering, just not
  standard-portable). `ptr == 0` / `ptr == NULL` tests the null representation.

**Where fidelity degrades honestly:** float operands in arithmetic → `unsupported_expression` (A.1);
aggregate cast targets without a tag resolver → `unsupported_expression` (A.5); an unreadable operand
mid-arithmetic → `type_error` (a bare unreadable lvalue still renders with `avail=unreadable`, A.7).

### A.5 Casts

`(typename) unary`. The `(`-ambiguity (cast vs parenthesized expr) is resolved by **peeking whether
the token after `(` begins a type-name** (a type keyword, or `struct`/`union`/`enum`, or — with the
resolver below — a known tag). Supported cast targets:

- **Scalar primitives** (`int`, `char`, `unsigned`, `long`, `short`, signedness combos). **C5 — the
  conversion order:** first sign/zero-**extend the operand by the SOURCE signedness** to a full width,
  then **mask to the target width** and **reinterpret per the target signedness**. So
  `(unsigned long)(int)-1 == 0xFFFFFFFF` (the `int -1` sign-extends to `0xFFFFFFFF`, then
  reinterpreted unsigned), **not** `65535`. Pointer→integer and integer→pointer casts are allowed
  (a bit reinterpret, real-mode). **A cast whose SOURCE is a float** (`(int)fval`) →
  `unsupported_expression` (no x87; would need a host float conversion).
- **Pointer types `T *`** where `T` is a primitive **or** a resolvable aggregate/enum tag — the
  common debugger idiom `((struct Foo *)p)->x`, `*(int *)addr`. The result is a synthesized/graph
  pointer; the operand's scalar becomes the pointer bits.

**G2 — typedef cast targets are NOT resolvable by the cast grammar (explicit degradation).** DOS C
casts through typedef names constantly (`(BYTE)x`, `(word)v`, `(size_t)n`), but `typeInfo` never
returns `.typedef` (typedefs are *symbols*, resolved via `typedefForSymbol`, `types.zig:388`) — so a
typedef type-name is invisible to the cast type parser. **For M-S3 a typedef cast target →
`unsupported_expression`** (an honest refusal; §F catalogue). A typedef resolver in the cast grammar
(threading `nameToSymbol` → `typedefForSymbol` → the aliased type_ref) is a clean follow-up, deferred
to keep M-S3 bounded.

**Structural issue (raised, not papered over):** casting to an aggregate/enum **by tag** needs a
`name → type_ref` reverse lookup that the symbol layer does **not** currently expose (`TypeGraph`
only maps `type_ref → tag`, `types.zig:tagName`). This plan proposes the **single symbol-layer
addition M-S3 needs** — `TypeGraph.typeRefForTag(name: []const u8, kind: enum{struct_,union_,class_,
enum_}) -> ?u16` (a bounded scan over the type records matching `id ∈ {struct,union,class,enum}` and
`Tds.name(name_index) == name`) — analogous to M-S2's single addition `typeRefForFunction`
(`debug-m2-plan.md §0`). **Without it, aggregate-tag casts degrade to `unsupported_expression`**
(honest); scalar + pointer-to-scalar casts work regardless. (Decision: implement `typeRefForTag`, so
`((struct Pixel *)p)->x` works on BB2.)

### A.6 `sizeof` — an UNEVALUATED operand

C requires `sizeof` to **not evaluate** its operand (`sizeof *wildptr` must not deref). The evaluator
therefore has a separate **`typeOfExpr` pass (NEW code)** that computes an expression's *type* (walking
identifiers/members/casts/`&`/`*`/`[]` structurally) **without any peek read or side effect** — a
pure type walk. `sizeof(typename)` → `typeSize(type_ref)` (or the primitive size). Result type =
`unsigned int` (`size_t`, 16-bit — Borland small-model). `sizeof` of an incomplete type / size 0 →
`type_error`. This pass is also what makes `sizeof` deterministic and zero-read. **P2 — the
`MAX_EVAL_DEPTH` cap fires at every recursive entry of `typeOfExpr` too** (not only the value
evaluator), so a deeply-nested `sizeof(((…)))` operand hits the cap before native stack overflow.

### A.7 Identifier resolution + result rendering

- **Resolution order (decision):** (1) **frame locals** via the M-S2 scope walk
  (`frameLocals`, `vars.zig:47`, innermost-shadowing), exactly as `inspectPath` head resolution
  (`:562`); (2) if not a local, **globals/statics** via `index.nameToSymbol(name)` (`index.zig:323`)
  → a `SymRef{segment, offset, type_index}` resolved to a static `Cursor`
  (`map.toRuntimeLinear(segment, offset)`, `type_ref = type_index`). (3) An unknown name →
  **`unresolved`** (never a guess).
  - **H2 — bare designators (decision, no scope-guessing).** A **bare enumerator name**: there is no
    "enums in scope" API on the symbol layer, so the scope rule is undefined — rather than silently
    pick some enum, an enumerator name that is not a local/global variable → **`unresolved`** (an
    agent can spell it as `(enum Mode)1` or read it via a struct member). A **bare function name /
    `&func`**: consistent with C's function-to-pointer decay, a function designator in a value
    context yields its **address** (a code pointer rvalue via `addrToFunction`/`typeRefForFunction`,
    **no call**); `&func` yields the same address. This resolves the §A.7-vs-§G ambiguity in favor of
    "yield the address."
- **Result → a `core.Variable`** — but **G1: `writeVariable` is NOT reused unchanged.** `core.Variable`
  carries the type only as `type_ref: u16`, so a *synthesized* result (a literal `42`, an arithmetic
  result, `sizeof`→`unsigned int`, `&x`→`T *`) has **no `type_ref`** and would serialize as `"?"`.
  **Additive fix:** add `type_text: []const u8 = ""` to `core.Variable` (gate-safe — `core.Variable`
  is a worker-side render DTO, NOT the pointer-free wire POD; it already holds `name`/`value_text`
  slices, `debug-m2-plan.md §3.1`), and `writeVariable` (`worker.zig:712`, `:728` type-name streamer)
  **prefers `type_text` when non-empty, else streams `typeName(type_ref)`**. Rendering:
  - An **lvalue** result → `vars.renderValueAt(sd, name=expr, cursor.type_ref, cursor.place,
    cursor.addr, bit, frame, scratch)` (the exact `inspect` terminal, `vars.zig:629`) — so an
    aggregate/array/pointer result **mints a `variables_ref`** and carries its `addr` for free
    (`type_text` stays `""`; the graph type_ref renders).
  - An **rvalue scalar** with a *graph pointer* type → render via `renderValueAt` with `place =
    .{ .imm = bits }` (renders the pointer text *and* mints a pointee handle via `mintPointee`).
  - An **rvalue scalar** of a *synthesized* `.scalar`/`.pointer` type → **`renderSyntheticScalar`
    (NEW code)**: decimal + hex value, and `type_text` = `"int"`/`"unsigned int"`/`"long"` or (for a
    synthesized pointer) the pointee streamed via `typeName` + `" *"`; a synthesized pointer also
    `mintHandle`s a `.pointee` node so `&x` is expandable.
- **Body shape** (mirrors `writeInspect`, `worker.zig:620`): `{"expr":"<echo>","result":<Variable>}`.

### A.8 Parser architecture + module placement (pure core, gated)

- New module **`src/debug/core/expr.zig`** — **added to the `src/debug/determinism_test.zig:sources`
  grep gate** (`:12-44`), so the existing host-time/RNG/float/atomic/thread needles apply. It imports
  `vars.zig` and reuses its resolver/renderer; it decides *what to read* and produces a
  `core.Variable`. The **worker** does the JSON emission AND (D1) the write commit (§B/§C).
- **D1 — the evaluator is STRICTLY peek-only; the WRITE EFFECT lives on the WORKER, not in
  `expr.zig`.** For `set_variable`, `expr.zig` (pure) resolves the lvalue `Cursor` and produces a
  neutral **`{destination, validated_bytes}`** plan (destination = `.mem{linear}` / `.reg{n}` /
  `.bitfield{linear, csize, start, width, new_bits}`); the **worker** commits it via its existing
  `inSlab` + `writeMemPhys`/`writeMem`/`setReg16`/`setReg8` (exactly like `memWritePhys` `:997` /
  `applyRegSet` `:975`). Thus `expr.zig` never calls a `ctrl` mutator, and its peek-only + zero-cycle
  invariant is **structurally grep-gateable**. To *enforce* it, add an `expr.zig`-scoped assertion of
  guest-exec / side-effect needles (`runUntilEvent`, `stepInstruction`, `writeMem`, `writeMemPhys`,
  `setReg`, `bus.write`, `portIn`, `portOut`, `beginResume`, `inject`) — a **dedicated** check, NOT
  the shared blanket `forbidden` list (which is applied to `debugger.zig` too, and `debugger.zig`
  legitimately *defines* `beginResume`).
- **`vars.zig` refactor (an enumerated, real change — NOT re-doing M-S2):** promote to `pub` (or
  extract) the primitives `expr.zig` composes: `Place`, `Cursor`, `fieldAccess`, `derefStep`,
  `ptrTarget`, `typeSizeOf`, `typeInfoOf`, `readMem`, `readReg`, `leBytes`, `signExtend`, `isSigned`,
  `renderValueAt`. **NEW code (not reuse):** `resolveHead`, `indexAccessExpr`, `typeOfExpr`,
  `renderSyntheticScalar`. **G3 — `resolveHead` needs a RICHER return than `?Cursor`**: the extracted
  head block (`inspectPath` `:562-614`) has non-`Cursor` early outcomes — `outer_frame_register`,
  `constant`/`absolute` (render-only, no address), `other`/`no_storage`. So
  `resolveHead(sd, frame, name) -> ResolveError!union(enum){ cursor: Cursor, terminal: Variable }`
  (the `.terminal` carries the render-only/honest-`avail` variable; a `.cursor` is navigable). The
  evaluator turns a `.terminal` head that is then subscripted (`.field`/`[]`/`->`) into a typed error,
  and renders a bare `.terminal` head as-is. `inspectPath` is re-expressed over the same shared
  resolver (or left as-is; the evaluator is a strict superset).
- **Bounded internally (P2/P4):** `MAX_EVAL_DEPTH = 64` checked at every recursive entry (binary
  climb, unary/cast/postfix descent, AND the `typeOfExpr`/`sizeof` pass); token buffer sized to
  `DBG_EXPR_CAP`; a fixed operand/value working set (no heap; the core takes a caller scratch buffer,
  like `renderChild`). Tokenization is TOTAL: every byte → a token or a typed error, never
  `unreachable`/panic (C2 maximal-munch for `++`/`--`/`->`/`<<`/`>>`/`<=`/`>=`/`==`/`!=`/`&&`/`||`).
- **Peek-only evaluation model:** the evaluator computes over VALUES obtained by `peek`
  (`cpuSnapshot`/`peekMemPhys`, RAM-slab-bounds-checked). It is a **pure function of the machine
  state at the stop** — deterministic, zero cycles, `snapshot()` byte-identical before/after.

---

## B. `set_variable` — writing a resolved lvalue

`set_variable{frame, lvalue, value}` = **resolve lvalue** (reuse the evaluator, require an lvalue) →
**parse + type-directed encode** the value → **committed deterministic write** → **re-render**.

### B.1 Lvalue resolution (reuse the evaluator)

The `lvalue` string is parsed by the **same `expr.zig` evaluator**, then the result is required to be
an **lvalue** (`store == .lvalue`, i.e. it ends at a `Cursor` with a `place`/`addr`). This gives
full-power targets for free: `n`, `p.x`, `node->next->value`, `arr[i]`, `*p`, `((struct Foo*)q)->f`.
A **non-lvalue** target (a literal, an arithmetic result, `&x`, a function) → **`not_lvalue`**.

**S2 — refuse a `<null>` / `unreadable` lvalue BEFORE any write (a silent-wild-write guard).** The
deref/index walk returns a null or out-of-slab pointee as a **terminal** `Variable` (`vars.zig:684`
`nullVar` / `:679` `unreadableVar`), not a navigable `Cursor`. Critically, a **null NEAR pointer
decodes to `DS:0000`, which IS inside the RAM slab** — so `inSlab` would NOT catch `*p = …` on a null
`p`; it would be a silent wild write to `DS:0`. `resolveLvalue` therefore **refuses to form a write
target from a `.terminal`** (null/unreadable) result → a typed error (`type_error` for unreadable,
and a distinct "null pointer" `type_error` for null) *before* the encode/commit ever runs.

**S5 — the frame-0 register gate MUST survive the `resolveHead` extraction (§A.8).** `renderLocal`'s
`is_frame0` guard (`vars.zig:594`) makes an OUTER-frame register local a non-writable terminal; the
extracted `resolveHead` preserves this invariant, so `set_variable v` on an *outer* frame whose `v`
lives in a register can NEVER poke the LIVE frame-0 register. (An outer-frame register lvalue → the
§B.4 honest error, not a mis-directed write.)

The resolved `Cursor` yields the write destination:

| `Cursor.place` / source | destination | note |
|---|---|---|
| `.mem` from `.auto` local | `SS:[frame_base+off]` → physical `linear` | any frame (the outer `frame_base` is that frame's BP) |
| `.mem` from `.static`/global | `seg:off` → `toRuntimeLinear` → `linear` | frame-independent |
| `.mem` from a member/element/deref | the walked child `linear` | incl. bitfield (B.3) |
| `.reg` (frame 0) | the CPU register (B.4) | frame-0 register locals only |
| `.reg` (**outer frame**) | — | **honest error** (B.4) |
| `.imm` (constant/absolute) | — | **`not_lvalue`** (a constant is not assignable) |

### B.2 Value parse + type-directed encode

The `value` string is parsed against the **target type**:

1. If the target is an **enum** → accept an **enumerator NAME** (matched via `enumerators`,
   `types.zig:413`) *or* an integer. An unknown name → `unresolved`.
2. Else parse an **integer/char/pointer literal** (`42`, `-1`, `0x1F`, `'A'`, `0`/`NULL`, or a
   far `seg:off` hex). 
3. Else (a non-literal like `lo + 1`) → run it through the **evaluator**, requiring a **scalar/pointer
   rvalue** result (pure, deterministic — assigning a computed value is safe). An aggregate result →
   `type_error`.

**Encode per the target `TypeId`/`TypeInfo`:**

- **Integer primitive** → **S4, the cross-signedness FIT rule (range-check FIRST, never a silent
  wrap).** Accept any value representable in `w = 8*typeSize` bits under **either** signedness — i.e.
  `v ∈ [-2^(w-1), 2^w - 1]` — then store the low `typeSize` bytes LE. So `-1 → char` writes `0xFF`
  and `0xFF → char` writes `0xFF` (both legal reinterprets), while `300 → char` (outside `[-128,
  255]`) → **`type_error`** (explicit). No `%`/silent truncation.
- **Enum** → the resolved enumerator value (or integer), fit-checked as above, `typeSize` bytes LE.
- **Pointer** → 2 bytes (near) / 4 bytes (far `seg:off`) LE.
- **Bitfield** (`m.bit_width != 0`) → **S1, read-modify-write — all three parts:**
  1. Read the container's **`csize = @min(typeSize, 8)`** bytes (bounds-checked) and **write back
     EXACTLY `csize` bytes** — NOT a full 8-byte u64 (which would clobber adjacent members past the
     unit).
  2. **AND-clear then OR-insert** (a naive `|=` cannot write a 0 bit):
     `container = (container & ~(mask << start)) | ((val & mask) << start)`, where
     `mask = (1<<width)-1`, `start = bitfieldStart(ms, mi)` (`vars.zig:336`).
  3. **Borland `int b:5` is SIGNED** (range `-16..15`): mask the value to `width` bits (so `-1`
     stores as `0x1F`) rather than range-rejecting negatives; range-check the *magnitude* fits
     `width` bits under either signedness (`v ∈ [-2^(w-1), 2^w-1]`, w=`width`) → else `type_error`.
     *(Read-side gap to flag, §G: `renderBitfieldAt` currently renders a bitfield UNSIGNED,
     `vars.zig:361` — so a signed `b:5 = -1` reads back as `31`; a pre-existing M-S2 read gap, not
     introduced here, tracked in §G.)*
- **Aggregate/array target** → `type_error` ("cannot assign a scalar to an aggregate").
- **Float target** → `unsupported_expression` (no x87; cannot parse/encode a float faithfully).

### B.3 The committed write (reuse the existing deterministic poke)

**D1 — `expr.zig` produces a neutral `{destination, validated_bytes}` plan; the WORKER commits** the
write through the **same committed path** `/api/mem` write + `/api/cpu/reg` patch use, on the
**worker, while Stopped** — never a new write surface, and `expr.zig` never touches a `ctrl` mutator:

- **Memory** (`.mem`): **S6 — always route through `inSlab(computed_linear)` + `writeMemPhys(linear,
  bytes)`** (`worker.zig:160` guard, exactly `memWritePhys` `:997`; `controller.zig:1171`). Apply
  `inSlab` to the **COMPUTED linear** (`ss_base +% frame_base +% off` for an auto; `toRuntimeLinear`
  for a static) — the auto `Cursor` already carries `.mem = linear`. **Drop the `writeMem(.ss, off)`
  alternative** (it takes a raw offset and would skip the computed-linear guard). Out-of-slab →
  **`address_out_of_range`** (the existing mem-write ErrCode; honest, never a wild write).
- **Register** (`.reg`, frame 0): **S3 — reject a `.reg` lvalue whose `typeSize` exceeds the
  register's natural width** (`type_error`): a `long` (4-byte) local parked in a 16-bit register
  passes the value fit-check but `setReg16` writes only the low 16 bits → silent truncation. So
  require `typeSize ≤ 2` for `format.Reg` 0-7 (`ax..di`) and `typeSize ≤ 1` for 8-15 (`al..bh`),
  else `type_error`. On a legal width, map `format.Reg` (0-15) → the controller enums via the
  existing patch (`applyRegSet` `:975`): Reg 0-7 (`ax..di`) → `setReg16(@enumFromInt(r), val)`
  (`:1150`); Reg 8-15 (`al/cl/dl/bl/ah/ch/dh/bh`) → `setReg8(@enumFromInt(r-8), val)` (Reg8 `= al cl
  dl bl ah ch dh bh`, so `r-8` maps 8→`al`…15→`bh` directly, `controller.zig:216`).

### B.4 Outer-frame register writes — an honest refusal

A frame-0 register is live and writable. For an **outer** frame, the local's register was
callee-clobbered and the symbol layer does not map where it was spilled (the read side already
surfaces this as `avail = outer_frame_register`, `vars.zig:94`). We **cannot** faithfully write it →
**`type_error`** ("cannot write an outer-frame register: callee-clobbered, unmapped"), consistent
with the M-S2 read honesty. This mirrors the frame-0-only register rule and is documented in §F.

### B.5 Determinism + snapshot + handle-invalidation (the explicit decision)

- `set_variable` **does NOT advance CS:IP and charges ZERO cycles** — it is a byte/register poke,
  exactly like `writeMem`/`setReg`. It is a **deliberate new input** (CLAUDE.md §1), flagged as a
  mutation op (vs the read-only inspection ops).
- **It does NOT bump `stop_epoch` and does NOT invalidate handles.** Rationale (stated explicitly per
  the task): the write does not change *which* structure lives at *which* address — an outstanding
  `variables_ref` encodes `{frame, base address, type}` (`ExpandNode`, `debugger.zig:181`), all
  unchanged; a subsequent `variables{ref}` re-peek simply reads the **new** value. No stale-handle
  hazard is created, so bumping the epoch (which would needlessly invalidate every handle the agent
  holds) is wrong here.
- **One documented nuance (raised, not papered over):** a `.pointee` handle minted *before* a write
  stored the pointee's *resolved target address* at mint time. If `set_variable` then changes that
  pointer's value, the pre-existing pointee handle still re-reads the **old** target (the object it
  was minted for) — it is not "stale" (same epoch, honest re-read of its minted address), but the
  agent should re-fetch `locals` to see the new pointer's target. This is benign and honest (never a
  wrong value for what the handle names); noted in §G for a confirming test.
- **Result:** re-render the lvalue *after* the write (re-resolve the same `Cursor` + `renderValueAt`)
  so the agent confirms: `{"lvalue":"<echo>","result":<Variable>}` — the new value.

---

## C. Cross-cutting: tool surface, transport, gates

### C.1 New DTOs / PODs (pointer-free, reflection-gate-clean)

```zig
// src/api/queue.zig
pub const DBG_EXPR_CAP  = 256;   // max expression / lvalue length (T9 flatten, like DBG_PATH_CAP)
pub const DBG_VALUE_CAP = 64;    // max set_variable value literal length

// Command union — two new arms (integers + fixed arrays ⇒ pass expectNoPointerFields(q.Command)):
pub const DbgEvaluateReq = struct {
    frame: u16 = 0,
    expr_len: u16 = 0,
    expr: [DBG_EXPR_CAP]u8 = @splat(0),          // FLATTENED (T9); worker parses expr[0..expr_len]
};
pub const DbgSetVarReq = struct {
    frame: u16 = 0,
    lvalue_len: u16 = 0,
    value_len: u16 = 0,
    lvalue: [DBG_EXPR_CAP]u8 = @splat(0),
    value:  [DBG_VALUE_CAP]u8 = @splat(0),
};
//   dbg_evaluate:     DbgEvaluateReq,
//   dbg_set_variable: DbgSetVarReq,
// Response: BOTH reuse the existing `dbg_json: DbgJsonResult{body_len}` arm (:324) — the nested
// result can be an aggregate/pointer Variable with a variables_ref, so it MUST ride the JSON seam.
```

**P1 — the flatten seam must REJECT over-length input, never `@min`-truncate (TOP PRIORITY).** The
`inspect` flatten the PODs copy (`server.zig:2478-2480`, `const n = @min(p.len, cmd.path.len);
@memcpy(...)`) silently **truncates**. For the evaluator a truncated expression is a *valid different
expression* → a silently wrong number (CLAUDE.md §2 fabrication). At **every** flatten site — the
`evaluate` `expr`, the `set_variable` `lvalue` and `value`, on **both** the MCP `buildCommand` path
and the HTTP handlers — if `s.len > DBG_EXPR_CAP` (resp. `DBG_VALUE_CAP`) **return a typed error**
(`invalid_params` at the MCP/HTTP parse boundary, or `unsupported_expression` from the worker) — NEVER
`@min`-copy. (The M-S2 `inspect` path should adopt the same reject-not-truncate rule; flagged in §G.)

**New `ErrCode`s** (add to `q.ErrCode` `:506` + `errInfo` `server.zig:3529`): `not_lvalue`
(→ HTTP 400), `type_error` (→ 400), `divide_by_zero` (→ 400). Reuse the existing
`unsupported_expression`/`unresolved`/`not_stopped`/`bad_frame`/`address_out_of_range`/
`response_too_large`. (`set_variable`'s out-of-slab write reuses `address_out_of_range`, matching
`memWritePhys`.)

**G1 — the additive `core.Variable.type_text` field** (see §A.7): add `type_text: []const u8 = ""`
to `core.Variable`; it is gate-safe (a worker-side render DTO, already slice-bearing, excluded from
the pointer-free wire gate) and lets a synthesized result carry a real type name instead of `"?"`.
`writeVariable` (`worker.zig:712/:728`) prefers `type_text` when non-empty.

### C.2 Worker handlers (mirror `dbgInspect`)

Two new `drainOne` arms in `worker.zig` (`:393` region), each mirroring `dbgInspect` (`:600`):

- `.dbg_evaluate => |c| dbgEvaluate(sd, dbg_json, c)` — `dbgReady` gate (→ `not_stopped`/`no_symbols`)
  → `frameOrBad` (→ `bad_frame`) → `core.expr.evaluate(r.s, frame, expr, scratch)` mapping
  `error.Unsupported→unsupported_expression`, `Unresolved→unresolved`, `NotLvalue→not_lvalue`,
  `TypeError→type_error`, `DivByZero→divide_by_zero` → `writeEvaluate` (`{"expr":…,"result":<Var>}`)
  → `sealJson`.
- `.dbg_set_variable => |c| dbgSetVariable(sd, dbg_json, c)` — same gate → `core.expr.resolveLvalue`
  + `core.expr.encodeAndWrite` (the write via `ctrl.writeMemPhys`/`writeMem`/`setReg16`/`setReg8`,
  `inSlab`-guarded) → re-render → `writeSetVar`. **This is a mutation arm** (like `memWritePhys`/
  `regSet`, `:258`/`:977`): it does NOT call `beginResume`/`noteStopped` (no CS:IP advance, no
  cycles), so the stop-epoch is untouched (B.5).

Both are Stopped-gated by `dbgReady` (`state == .running → not_stopped`). Both `sealJson` into the
session `DebugJsonBuffer`; the listener copies-under-`session.lock` and streams (`server.zig:2760`).

### C.3 Transport / listener

Both tools route through the existing `submitDebuggerJsonAndRespond` (HTTP, `server.zig:2760`) and
`submitMcpDebuggerJsonAndRespond` (MCP, `:2483`) — identical body bytes on both front-ends (the seam
*removes* drift, `debug-m2-plan.md §1.4`). The command-string flattening (T9) keeps `q.Command`
pointer-free; `DbgJsonResult` keeps `q.Response` pointer-free — **both `expectNoPointerFields` gates
stay green unchanged** (`api/determinism_test.zig:155`). HTTP routes: `POST /api/dbg/evaluate`,
`POST /api/dbg/set-variable` (mirroring `/api/dbg/inspect`, `server.zig:1230`). MCP: `buildCommand`
arms parse `expr`/`lvalue`/`value` into the flattened PODs (the `fillSrcBp` precedent,
`mcp_tools.zig`).

### C.4 MCP tool schemas (dap_mcp-style descriptions)

```jsonc
// src/api/mcp_tools.zig — two new rows (per_machine), bodies via the dbg_json seam.
{
  "name": "evaluate",
  "description": "Evaluate a C expression in the selected stopped frame and return the resulting \
value {value, type, addr?, variables_ref}. READ-ONLY: pure peek, zero cycles, NO guest execution \
— so function calls f(...) are refused (unsupported_expression), as are assignment/++/-- (use \
set_variable). Full 16-bit C integer semantics: promotion, signedness, pointer arithmetic scaled by \
pointee size, casts, sizeof, &, *, [], ., ->, ?:, && || (short-circuit). An aggregate/pointer result \
carries a variables_ref (expand via `variables`). Honest typed errors, never a guessed value: \
unsupported_expression (out-of-subset / float arithmetic / call), unresolved (unknown name/member), \
not_lvalue (& of a non-lvalue), type_error (bad operand types / out-of-bounds index / scalar-vs-\
aggregate), divide_by_zero. Valid only when stopped.",
  "input_schema": {"type":"object","properties":{
     "expr":{"type":"string","minLength":1,"description":"C expression (e.g. v + lo, *p, &arr[2], p->next->val, sizeof(struct Pixel), (int)c)"},
     "frame":{"type":"integer","minimum":0,"description":"0-based frame from backtrace (default 0)"}},
     "required":["expr"],"additionalProperties":false}
},
{
  "name": "set_variable",
  "description": "MUTATES guest state: write `value` into the lvalue `lvalue` in the selected \
stopped frame — a DELIBERATE, deterministic poke (the debugger sibling of write_memory/set_register; \
does NOT advance the CPU or charge cycles). The lvalue is any assignable target (n, p.x, arr[i], \
*p, node->next->val, incl. bitfields); a non-lvalue → not_lvalue. `value` is an integer/char/pointer \
literal, an enum enumerator NAME, or an expression reducing to a scalar. Out-of-range for the target \
type → type_error (never a silent wrap). Writing an outer-frame register → type_error (callee-\
clobbered, unmapped). Returns the RE-RENDERED variable so you can confirm the new value. Valid only \
when stopped.",
  "input_schema": {"type":"object","properties":{
     "lvalue":{"type":"string","minLength":1,"description":"assignable target (e.g. n, p.color, arr[2], *p)"},
     "value":{"type":"string","minLength":1,"description":"integer/char/pointer literal, enum name, or a scalar expression"},
     "frame":{"type":"integer","minimum":0,"description":"0-based frame (default 0)"}},
     "required":["lvalue","value"],"additionalProperties":false}
}
```

(T16d parity: the two rows add ~2 KiB; the M-S2 catalog already fit inside `RESPONSE_BUF = 48 KiB`
with margin, so the §E test re-asserts `tools/list` returns 200 and parses.)

---

## D. Milestone sequencing

| Step | Scope | Provable at this step |
|---|---|---|
| **M3-a — evaluate (read-only)** | `expr.zig` (Pratt parser, `EvalVal`/`Store`/`EvalType`, promotion + usual conversions + pointer arith + casts + `sizeof` + short-circuit), the `vars.zig` `pub`-promotion refactor, `typeRefForTag`, `dbg_evaluate` arm + tool + HTTP/MCP routes, the new ErrCodes. | On BB2: `v + lo`, `hi - 1`, `*p`, `&arr[2]`, `arr[i]`, `p->next->val`, `sizeof(struct …)`, `(int)c`, comparisons — all correct; `f()`/`x=1`/`++x`/float-arith → honest typed errors; `1/0` → `divide_by_zero`; two runs byte-identical; `snapshot()` unchanged across an evaluate. |
| **M3-b — set_variable** | `resolveLvalue` (evaluator, lvalue-required), value parse + type-directed encode (incl. bitfield RMW, enum-by-name), the committed write reuse, `dbg_set_variable` arm + tool + routes, `not_lvalue`/`type_error`. | On BB2: set a local `int` + re-read; set a struct member; set a bitfield; set an enum by NAME; `not_lvalue`/outer-register/out-of-range → honest errors; a write leaves cycles/CS:IP unchanged and does NOT bump `stop_epoch` (existing handles still valid, re-read shows the new value). |

M3-a first proves the pure-read evaluator (de-risking the C semantics) before the mutation path
leans on the same resolver — exactly how M-S2 built `inspect` (read) before deferring the write.

---

## E. Test plan

Black-box over the wire (extending `tests/blackbox/debug_test.zig`: `mcpCall`/`mcpOk`, the `Variable`
result shape) on `examples/BB2.EXE`/`BB2M.EXE` (pointer/array/bitfield/recursion) + `BB.EXE`
(`clamp`/`main`, the integration goldens). Plus in-process unit tests driving `core.expr.evaluate`
directly at a known stop.

**evaluate (M3-a):**

1. **Arithmetic + locals.** Stop in `clamp` (BB.C:9). `evaluate v + lo` == `300 + BX`;
   `evaluate hi - 1` == `CX - 1`; `evaluate v * 2 + 1`; `evaluate v > lo` == `1`; verify signedness
   (a negative `int` renders decimal-negative + hex).
2. **Pointer arith + deref + address-of.** On BB2 (pointer/array fixture): `evaluate *p` reads the
   pointee; `evaluate p + 1` advances by `sizeof(*p)` bytes (assert the offset delta); `evaluate
   *(p + 1)`; `evaluate &arr[2]` yields the element address (assert `= &arr[0] + 2*elem`); a null
   `p` → `evaluate *p` returns `<null>` (no wild read); a pointer set out of RAM → `unreadable`.
3. **Index by a local + member chains.** `evaluate arr[i]` with `i` a live local == `arr[i]`;
   `evaluate node->next->value` walks the chain; `evaluate p->x` / `evaluate (*p).x` agree.
4. **sizeof + casts.** `evaluate sizeof(struct Pixel)` == the struct size; `evaluate sizeof arr` ==
   array bytes; `evaluate sizeof *p` does NOT deref (assert it works even with `p` null/wild);
   `evaluate (int)c` truncates a `char`; `evaluate ((struct Pixel*)q)->x` (needs `typeRefForTag`).
5. **Ternary + short-circuit.** `evaluate v > 0 ? lo : hi`; `evaluate 0 && (1/0)` == `0` **without**
   `divide_by_zero` (dead branch not evaluated).
6. **The EXCLUSIONS (honest, never partial-eval).** `evaluate foo()` → `unsupported_expression`;
   `evaluate v = 1` → `unsupported_expression`; `evaluate ++v` / `evaluate v--` →
   `unsupported_expression` (NOT a fabricated `v`, C2); `evaluate fval + 1` (float operand) →
   `unsupported_expression`; `evaluate zzz` (unknown) → `unresolved`; `evaluate &300` → `not_lvalue`;
   `evaluate 1/0` → `divide_by_zero`; `evaluate arr[999]` (out of bounds) → `type_error`;
   `evaluate *v` (v not a pointer) → `type_error`.
7. **T2 — the C-semantics DISTINGUISHING matrix (each asserts a specific number the naive impl gets
   wrong):** `0xFFFF > 0` → **1** (C1 unsigned literal); `40000 + 40000` → **80000** (C1 `long`
   literal, no wrap); `30000 + 30000 > 0` → **1** (C4 masking); `0x8000 >> 1` → **16384** (C6 logical
   shift of unsigned); `-7 / 2` → **-3** and `-7 % 3` → **-1** (C3 `@divTrunc`/`@rem`);
   `(unsigned long)(int)-1` → **0xFFFFFFFF** (C5 source-signed extend then reinterpret); `Z7 + 0` →
   **-5** for a negative enumerator (C7); `1 << 20` → `type_error` (C6 count ≥ width);
   `a, b`/`x = y`/`x++` → `unsupported_expression` (C2 end-of-input, no partial `a`/`x`).
8. **T1 — the ADVERSARIAL-PARSER bucket** (each → a clean typed error, **no crash/hang/panic**):
   `1 +`, `)(`, `a..b`, unterminated `(`, `a[`, `"a string"`, a > `DBG_EXPR_CAP`-length expression
   (P1 REJECT, not truncate), an integer literal overflowing `u64` (P3), and a `((((…))))` nest
   past `MAX_EVAL_DEPTH` (P2 — fits in 256 B, must hit the cap before native stack overflow).
9. **T3 — typedef cast, `&bitfield`, far/huge relational.** `evaluate (BYTE)x` (a typedef target) →
   `unsupported_expression` (G2); `evaluate &bits.flag` → `type_error` (H1); on BB2M (a larger-model
   build, if compiled far) a far-pointer relational `p1 < p2` follows the documented rule (§A.4/§G).
10. **Determinism + peek-only.** Run the whole scenario **twice** → byte-identical result JSON;
    **bracket an `evaluate` with `ctrl.snapshot()`** and assert bytes identical + `currentCycle()`
    unchanged (proves zero-cycle, side-effect-free).

**set_variable (M3-b):**

11. **Local int + re-read.** `set_variable n = 7` → the returned re-rendered value is `7`; a
    follow-up `evaluate n` == `7`; `read_memory` at the local's addr confirms the bytes.
12. **Struct member + bitfield + enum-by-name.** `set_variable p.x = 42` (member); `set_variable
    bits.flag = 1` (bitfield RMW — assert only the field's bits changed, neighbors intact, and a
    subsequent `set_variable bits.flag = 0` **clears** it, proving AND-clear-then-OR, S1b);
    `set_variable bits.sfield = -1` on a signed `b:5` writes `0x1F` (S1c); `set_variable m = GRAPHICS`
    (enum by NAME) → re-read renders `GRAPHICS`.
13. **Honest write errors.** `set_variable 3 = 1` → `not_lvalue`; `set_variable v = 1` on an
    **outer** frame where `v` is register → `type_error` (outer-register, S5); `set_variable c =
    99999` (out of `char` range) → `type_error` (no silent wrap, S4); `set_variable longvar = 5`
    where `longvar` is a `long` in a 16-bit register → `type_error` (S3 width guard); a write to an
    out-of-slab static → `address_out_of_range`.
14. **S2 — null/unreadable lvalue refusal (silent-wild-write guard).** With `p` a **null** near
    pointer, `set_variable *p = 1` → `type_error` (null), and NO byte at `DS:0000` changes (bracket
    `read_memory DS:0` before/after); with `p` pointing out of slab, `set_variable *p = 1` →
    `type_error` (unreadable).
15. **Mutation determinism + no epoch bump (D2).** A `set_variable` leaves `currentCycle()` unchanged
    and CS:IP unchanged; it does **not** bump `stop_epoch` — a `variables_ref` held across the write
    still resolves (no `stale_handle`) and a re-expand shows the new value. Two runs byte-identical.
16. **Pointee-handle-retarget (D2/§G nuance).** Mint a `.pointee` handle from a pointer local,
    `set_variable` the pointer to a new target, then re-expand the OLD handle → it honestly re-reads
    its MINTED target (not "stale"); re-fetching `locals` re-derives the new target.

**Gates:** add `src/debug/core/expr.zig` to `src/debug/determinism_test.zig:sources` (grep gate
green); assert `expectNoPointerFields(q.Command)` + `(q.Response)` still pass with the two new arms;
`tools/list` returns 200 and parses after the two new rows.

---

## F. Determinism / no-fakes checklist + honest-degradation catalogue

**Checklist:**

- [ ] **evaluate is peek-only, zero-cycle.** Every read is `cpuSnapshot`/`peekMemPhys` (via
      `vars.readMem`/`readReg`), never `bus.read*`/`portIn*`, never `runUntilEvent`/`step*`. Bracketed
      by a `snapshot()` byte-identity + `currentCycle()`-unchanged assertion (§E7).
- [ ] **No guest execution, ever.** Function calls are a *parse-level* rejection
      (`unsupported_expression`) — the evaluator has no path that advances the machine.
- [ ] **D1 — the write effect is on the WORKER, not `expr.zig`.** `expr.zig` produces a neutral
      `{destination, validated_bytes}` plan; only the worker calls `writeMemPhys`/`setReg*`. An
      `expr.zig`-scoped grep asserts it has NO guest-exec/side-effect symbol (`runUntilEvent`/
      `stepInstruction`/`writeMem*`/`setReg*`/`bus.write`/`portIn`/`portOut`/`beginResume`/`inject`).
- [ ] **P1 — no `@min`-truncation at any flatten site.** Over-`DBG_EXPR_CAP`/`DBG_VALUE_CAP` input →
      a typed error, never a silently-truncated (different) expression.
- [ ] **No host clock/RNG/float/atomic/thread** in `expr.zig` — on the grep gate. Float operands →
      `unsupported_expression`; a bare float value → hex bytes (`renderPrimitive`, no host `std.fmt`
      float).
- [ ] **Deterministic C semantics.** All widths/signedness from `TypeId`/`typeSize`; masked integer
      math in `u64`/`i64`; short-circuit is real; no undefined-behavior guess (div-by-0 →
      `divide_by_zero`, not a trap; overflow is well-defined 2's-complement wrap or a typed refusal).
- [ ] **set_variable is a deliberate, deterministic input.** The same committed `writeMem*`/`setReg*`
      path; `inSlab`-bounds-checked; no CS:IP advance, no cycles; no `stop_epoch` bump (B.5).
- [ ] **Command/Response stay pointer-free.** `DbgEvaluateReq`/`DbgSetVarReq` are integers + fixed
      arrays; the result rides the existing `dbg_json` seam. Both gates unchanged.
- [ ] **Explicit overflow / truncation.** A body over `DBG_JSON_CAP` → `response_too_large`; a
      write value that does not fit the target → `type_error` (never a silent wrap).

**Honest-degradation catalogue (each with its exact typed signal):**

| Case | Why it cannot be done faithfully | Signal |
|---|---|---|
| **Function call `f(x)`** | Would execute the guest (cycles + unrecorded input) — forbidden. | `unsupported_expression` |
| **Assignment / `++` / `--` in evaluate** | A side effect; evaluate is pure (use `set_variable`). `++`/`--` are maximal-munch tokens, never `+(+x)` (C2). | `unsupported_expression` |
| **Comma / trailing token after a complete expr** | End-of-input enforced; no partial-eval (C2). | `unsupported_expression` (the residual's implied error) |
| **Float operand in arithmetic / float-source cast** | No x87; host float = gate violation + rounding nondeterminism. | `unsupported_expression` (a bare float value still renders as hex bytes) |
| **Aggregate/enum cast by tag, no resolver** | Needs `typeRefForTag`; without it a struct-tag cast is unresolvable. | `unsupported_expression` (scalar + pointer-to-scalar casts still work) |
| **Typedef cast target (`(BYTE)x`, `(size_t)n`)** | `typeInfo` never returns `.typedef`; the cast grammar can't see typedef names (G2; resolver is a follow-up). | `unsupported_expression` |
| **`&bitfield` (`&bf.field`)** | C forbids it; the bitfield Cursor's `addr` is the container, not the field (H1). | `type_error` |
| **String literal / multi-char / wide char (`"…"`, `'ab'`, `L'a'`)** | No production in the grammar (P4). | `unsupported_expression` |
| **Integer literal overflowing `u64`** | `parseInt` refusal, never a silent wrap/panic (P3). | `unsupported_expression` |
| **Bare enumerator name** | No "enums in scope" API; the scope rule is undefined — never silently pick an enum (H2). | `unresolved` |
| **Bare function name / `&func`** | Function-to-pointer decay → its address (no call), consistent with C (H2). | *(success: the function address as a code pointer)* |
| **Shift count `<0` or `≥ width`** | Out-of-range shift; Zig `@shl`/`@shr` would panic (C6). | `type_error` |
| **Division / modulo by zero** | Cannot compute; must not trap the guest. | `divide_by_zero` |
| **Unknown identifier** | Not a local, not a global/static, not an enumerator in scope. | `unresolved` |
| **Missing member / deref of non-pointer / member of non-aggregate** | The type graph has no such member / wrong kind. | `unresolved` (missing name) / `type_error` (wrong kind) |
| **Array index out of `arr.count`** | A wild read past the array would fabricate a value. | `type_error` (never a wild read) |
| **`&` of a non-lvalue / a register lvalue** | An rvalue has no address; a register has no memory address. | `not_lvalue` |
| **Pointer into unmapped memory (deref)** | `peekMemPhys` of an out-of-slab linear is not a real value. | terminal bare `*p` → `avail=unreadable`; mid-arithmetic → `type_error` |
| **Null pointer deref** | Reading through a zero pointer. | `<null>` value (bare); mid-arithmetic → `type_error` |
| **set_variable target not an lvalue** | A literal/arith/`&x` cannot be written. | `not_lvalue` |
| **set_variable through a null/unreadable pointer (`*p = …`)** | A null NEAR pointer is `DS:0000`, IN-slab — `inSlab` would NOT catch it → silent wild write (S2). | `type_error` (refused at lvalue resolution, before any write) |
| **set_variable outer-frame register** | Callee-clobbered, spill site unmapped by TDS (S5). | `type_error` |
| **set_variable to a register wider than its natural width** | A `long` in a 16-bit reg would truncate silently on `setReg16` (S3). | `type_error` |
| **set_variable value out of target range** | Would silently corrupt / wrap (S4). | `type_error` (explicit, never a silent wrap) |
| **set_variable out-of-slab write / scalar-into-aggregate / float target** | Wild write / undefined encode. | `address_out_of_range` / `type_error` / `unsupported_expression` |
| **No symbols (stripped image)** | No TDS overlay to resolve names/types. | `no_symbols` |
| **Not stopped** | Live BP/SP/regs meaningful only at a clean boundary. | `not_stopped` |
| **Body over the slab cap** | A genuinely huge aggregate result. | `response_too_large` |

---

## G. Open `TODO(verify):` items

- `TODO(verify):` the `typeRefForTag` addition (A.5) — confirm a bounded scan over `Tds` type
  records (matching `id ∈ {struct,union,class,enum}` + name) is the right seam, that it is the ONLY
  symbol-layer addition M-S3 needs (analogous to M-S2's `typeRefForFunction`), and that it stays
  deterministic (table-order scan, first match). If a program has duplicate tags across modules,
  document the resolution rule (first in table order).
- `TODO(verify):` the exact set of `vars.zig` helpers to promote to `pub` vs extract (A.8) — confirm
  `renderValueAt`/`ptrTarget`/`fieldAccess`/`derefStep`/`readMem`/`readReg`/`leBytes`/`signExtend`/
  `isSigned`/`typeSize`/`typeInfoOf` can be shared, that the NEW `resolveHead` (richer
  `union{cursor, terminal}` return, G3) / `indexAccessExpr` (runtime index, generalizing
  `indexAccess`) / `typeOfExpr` / `renderSyntheticScalar` slot in cleanly, and that `inspectPath`
  stays behaviorally identical after the refactor (its tests stay green).
- `TODO(verify):` the far/huge **pointer relational** rule (A.4) — confirm comparing normalized
  linear for `<`/`>` on far pointers (well-defined only for `huge` in C) is acceptable as a
  documented approximation on the BB2/BaK memory models, or restrict `<`/`>` on far pointers to
  `type_error` (more conservative). Pick per what BB2M (a larger-model build, if compiled far)
  actually needs.
- `TODO(verify):` the **pointee-handle-retarget** nuance (B.5) — add a test that mints a `.pointee`
  handle, `set_variable`s the pointer, and asserts the OLD handle honestly re-reads its minted target
  (not "stale"), and that re-fetching `locals` re-derives the new target. Confirm this is the desired
  contract (vs bumping the epoch on a write, which we rejected as over-broad).
- `TODO(verify):` `size_t` width for `sizeof` (A.6) — confirm Borland small-model `size_t` is
  `unsigned int` (16-bit) so `sizeof` of a > 64 KiB huge array is representable (huge model) or
  documented as clamped; align with `typeSize`'s `u16` return.
- `TODO(verify):` `set_variable`'s value-as-expression path (B.2 step 3) — confirm allowing a full
  evaluate-expression RHS (`n = lo + 1`) is desirable, or restrict M-S3 to literals + enum names
  (simpler, still covers the common case) and defer expression-RHS.
- **D2 [VALIDATED — keep, do not regress]:** the **no-`stop_epoch`-bump on `set_variable`** decision
  (B.5) is confirmed consistent with `mem_write`/`applyRegSet` (which already do not bump); the
  frozen-pointee-target re-read is pre-existing + deterministic; bumping would over-invalidate every
  handle. Keep it; keep the §E16 confirming test.
- `TODO(verify):` **D3 — the read vs write address domains must be EQUAL.** `evaluate` reads via
  `vars.readMem` → `ramSlabSize` (`= bus.ram.len`, `controller.zig:1539`); `set_variable` writes via
  `inSlab` → `ramTotalSize` (`= the region-table .ram len`, `worker.zig:151`). Confirm these are the
  same byte count (no peek-but-can't-poke / poke-but-can't-peek asymmetry); if they can differ, pick
  ONE domain for both paths.
- `TODO(verify):` **S1c read-side gap** — `renderBitfieldAt` (`vars.zig:361`) renders a bitfield
  **unsigned**, so a signed `int b:5 = -1` written by `set_variable` reads back as `31`. This is a
  **pre-existing M-S2 read gap** (not introduced by M-S3), but `set_variable`'s signed-bitfield write
  makes it visible; decide whether to fix the read side (sign-extend by `width` when the member type
  is signed) as part of M-S3 or track separately.
- `TODO(verify):` **P1 back-port** — the M-S2 `inspect` flatten (`server.zig:2478-2480`) still
  `@min`-truncates; adopt the same reject-not-truncate rule there so a truncated *path* can't silently
  address a different variable.
- `TODO(verify):` the **typedef cast resolver** (G2) — decide whether to promote the deferred
  `nameToSymbol → typedefForSymbol → aliased type_ref` resolver into M-S3 (DOS C uses `(BYTE)`/
  `(word)`/`(size_t)` casts heavily) or ship M-S3 with the honest `unsupported_expression` degradation.
  The bare-**function-name** designator decision is now LOCKED (H2: yield the address, no call).
