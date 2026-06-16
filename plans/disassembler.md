# Real-mode 386 disassembler — `GET /api/disasm`

Status: PLAN (no code yet). `GET /api/disasm` currently returns **501** at
`src/api/server.zig:609`. This plan replaces that with a faithful, deterministic,
read-only 386 real-mode disassembler exposed over the HTTP debugger API.

The motivating friction: today the debugger exposes only raw instruction *bytes*
(`/api/mem`, `/api/mem/seg`), so a human/agent debugging a real game must hand-decode
x86 — the #1 friction found while debugging. `/api/disasm` turns bytes into readable
Intel-syntax text + per-instruction length, so callers can walk code, set breakpoints
on the right address, and read a disassembly window around CS:EIP.

---

## 1. Reuse the CPU decoder? — analysis + recommendation

### 1.1 What the CPU decode path actually is

The CPU's decode is **decode-and-execute, fused** — there is no decode-only mode:

- `src/cpu/dispatch.zig` `executeOne(cpu)` does the prefix scan, the `0F` map, size
  resolution (`decode.resolveSizes`), the dispatch key, and then *immediately*
  **charges base cycles** (`cpu.st.cycles += cycles.baseFor(...)`, dispatch.zig:88)
  and **dispatches into execution** (`exec.execute(cpu)`).
- `fetch8/16/32` (dispatch.zig:27-46) **advance `cpu.st.eip`** and grow `cpu.dec.len`
  as a side effect of reading each byte — the only length counter is produced by
  executing the fetch.
- `decodeModRM` / `decodeMem16` / `decodeMem32` (dispatch.zig:149-276) compute a
  *concrete effective address* by reading **live register values**
  (`cpu.st.getReg16/32`) and fold the segment override in — they yield `mem_off`
  (a resolved number), **not** the symbolic operand (`[BX+SI+0x10]`) a disassembler
  must print. They also `raiseFault` (#UD/#GP) mid-decode.
- The displacement/immediate widths the disassembler needs to *render* are consumed
  **inside the per-opcode execution bodies** (`exec_*.zig`), e.g. `0xC2 RET imm16` calls
  `dispatch.fetch16(cpu)` from the dispatch arm (exec.zig:242). There is no central
  table of "opcode → operand shape"; the operand shape is implicit in each exec body.

So "reuse the decoder for length+operands without executing" is **not** available as a
seam today, and bolting it on would mean teaching every `exec_*.zig` body a
"decode-only, don't touch state, emit a symbolic operand" mode — invasive, and a
standing risk of perturbing the execution hot path (which is `comptime`-generic over
`Bus` precisely to inline to zero cost).

### 1.2 What the CPU decode path *can* faithfully share

The **front-end facts** are identical between execute and disassemble and live in
pure, side-effect-free helpers we SHOULD reuse verbatim (single source of truth, no
drift):

- `decode.OperandSize` / `decode.AddrSize`, `decode.resolveSizes(d, cs_big)`
  (decode.zig:63) — the exact 0x66/0x67 size-flip logic.
- `decode.rm16(rm)` (decode.zig:93) — the 16-bit ModR/M base/index/default-seg table,
  the canonical source for rendering `[BX+SI]`, `[BP+DI]`, the BP→SS / disp16 cases.
- The prefix-byte set + the `0F` two-byte map boundary (the `switch` in
  `executeOne`, dispatch.zig:57-79) — the disassembler's prefix scanner must accept
  exactly the same bytes so its length matches the CPU's.
- `dispatch.lockOpcodePossible` (dispatch.zig:112) and the SIB/disp encodings in
  `decodeMem32` — reusable as the reference for *which bytes are consumed* per
  addressing form (we mirror the byte-consumption, not the EA computation).

### 1.3 Recommendation: **separate decode-only module that REUSES the CPU's pure front-end helpers; a NEW operand-shape table for the back half.**

Build `src/cpu/disasm.zig` as a standalone **decode-only** pass that:

1. **Imports and reuses** `decode.zig`'s pure helpers (`OperandSize`, `AddrSize`,
   `resolveSizes`, `rm16`) and replays the *same* prefix scan + `0F` boundary as
   `executeOne`. This kills the highest-drift risk — prefix handling and size
   resolution — by sharing the actual code, not a copy.
2. Owns a **new, explicit opcode→operand-shape table** (mnemonic + a small operand
   descriptor list: `r/m`, `reg`, `imm8/v`, `rel8/v`, `moffs`, `ptr16:16`, implied
   regs, the group sub-decodes by ModR/M.reg). This table is the *only* duplication,
   and it is duplication of a *fact* (the Intel encoding) that is already implicitly
   spread across `exec.zig` + `exec_*.zig`. Centralizing it in one readable table is a
   net reduction in scattered truth, and it is testable in isolation against the
   conformance byte vectors (§7).
3. Reads guest bytes through a **caller-supplied byte source** (`fn(off) ?u8`) so the
   module is bus-agnostic and trivially unit-testable, and never touches CPU state,
   EIP, or the cycle ledger.

**Trade-off stated plainly.** *Reuse-the-executor* (a decode-only execution mode) would
give zero operand-table duplication but couples the disassembler to the execution hot
path, forces a "don't mutate / emit-symbolic" flag through dozens of exec bodies, and
risks the determinism-critical execute path for a debug-only feature — a bad trade
against CLAUDE's "execute path inlines to zero cost" and "not a toy" rules.
*Separate-table* accepts one well-contained, test-pinned table as the cost of keeping
the disassembler decoupled and the executor pristine. The drift risk is mitigated three
ways: (a) the front-end (prefixes/sizes/rm16) is *shared code*, not copied; (b) every
opcode the CPU executes gets a disasm-table entry, enforced by a **comptime coverage
test** that walks `exec.zig`'s dispatch arms (or a shared opcode-list) and asserts the
disasm table has an entry for each; (c) the conformance byte vectors (§7) cross-check
that disasm's reported length equals the bytes the CPU consumed.

**Net recommendation: separate `src/cpu/disasm.zig`, reusing the CPU's pure decode
front-end helpers, with a new operand-shape table for mnemonics/operands.**

---

## 2. References consulted

- **dosbox-x** `references/dosbox-x/src/debug/debug_disasm.cpp` (1365 lines) +
  `disasm_tables.h` (191 lines). MAME/2asm-derived ("Ripped out some stuff
  from the mame release… for 386's", header lines 1-40). Table-driven; useful as a
  *structure/behavior reference for the operand-shape table and Intel rendering*.
- **dosbox-staging** `references/dosbox-staging/src/debugger/debugger_disasm.cpp`
  (1128 lines) — same lineage.
- **spice86** `references/spice86/src/Spice86.Core/Emulator/CPU/CfgCpu/InstructionRenderer/`
  and `.../ParsedInstruction/` (C#) — shows the *clean separation* this plan
  adopts: a parsed-instruction representation distinct from execution, then a renderer
  over it. Good model for the `Decoded → text` split; mnemonic/operand formatting only.
- zdos CPU decode front-end: `src/cpu/decode.zig`, `src/cpu/dispatch.zig`,
  `src/cpu/exec.zig` (the dispatch arms = the implicit operand-shape source of truth).
- zdos API patterns: off-worker `/api/health` (`server.zig` dispatch ~line 436) and
  `serveStatic` (server.zig:1279); the worker peek model `memPeekPhys`/`memPeekSeg`
  (`src/api/worker.zig:255-282`) and Controller peek (`src/debug/controller.zig:638-645`,
  `cpuSnapshot` at :591); the queue Command/Response/RequestCtx (`src/api/queue.zig`).

---

## 3. Scope

Real-mode 386, matching exactly the ISA `src/cpu/` executes:

- Default 16-bit operand & address size (real mode, CS.D=0); `0x66` → 32-bit operand,
  `0x67` → 32-bit address (incl. the SIB byte for 32-bit addressing).
- Full integer ISA the CPU implements: ALU, MOV family, INC/DEC, PUSH/POP (reg/seg/
  imm/all), Grp1-5 + Grp8, shifts/rotates (incl. SHLD/SHRD), MUL/DIV/IMUL (1/2/3-op),
  BCD, string ops + REP/REPNE prefixes, Jcc (rel8 + 0F rel16/32), LOOP/JCXZ, near/far
  CALL/JMP/RET, INT/INTO/IRET, ENTER/LEAVE, LES/LDS/LSS/LFS/LGS, MOVZX/MOVSX, BT/BTS/
  BTR/BTC/BSF/BSR, SETcc, MOV CR/DR, Grp7 (LGDT/LIDT/SGDT/SIDT/SMSW/LMSW), CLTS, the
  flag ops, XLAT, segment-override prefixes.
- **No x87** — zdos has no FPU (per MEMORY no-FPU constraint). The ESC range
  `0xD8..0xDF` (and `0x9B` WAIT) is rendered honestly: print the bytes with a clear
  marker (e.g. `(no-fpu) esc` / the raw opcode), since the CPU itself raises #NM there
  (exec.zig:320). We do NOT invent x87 mnemonics; we DO consume the ModR/M so length is
  correct (mirroring `escFpu`'s ModR/M consume, exec.zig:322).
- PM/V86/paging-only opcodes that the CPU #UDs in real mode (ARPL, LAR/LSL, Grp6,
  486+/Pentium opcodes) are rendered as their real mnemonic where unambiguous, or as a
  `(bad)`/`db 0xNN` token where the byte does not decode — never silently skipped.
- Anything not in a table → emit `db 0x<bytes>` for the lead byte (length 1) so the
  walker always advances. **Never fabricate** a plausible mnemonic for unknown bytes.

---

## 4. Module design

### 4.1 `src/cpu/disasm.zig` (new) — pure decode-only core

- Lives in `src/cpu/` (it shares `decode.zig`'s front-end helpers; module graph:
  `cpu` imports nothing upward, so this is clean). Pure: no allocation, no globals, no
  clock, no CPU-state mutation.
- Public surface (sketch — finalize against `references/zig/lib/std/` idioms):

  ```
  pub const Insn = struct {
      len: u8,                  // total bytes consumed (1..15)
      // rendered text written into a caller-provided fixed buffer; the fn returns the slice
  };
  /// Decode ONE instruction. `read(off) ?u8` is the side-effect-free byte source
  /// (returns null for not-readable/out-of-range → caller renders `db`/`(bad)`).
  /// `text_buf` is a caller-owned fixed buffer (e.g. [48]u8). Returns len + text slice.
  pub fn decodeOne(read: anytype, base_off: u32, cs_big: bool, out_text: []u8) Insn;
  ```

  `read` is `anytype` taking an offset → `?u8`, so callers pass a closure over a guest
  byte window (the worker passes a peeked buffer; tests pass a slice). 15-byte max
  length enforced (matches `MAX_INSTR_LEN`).
- Internals: prefix scan (reusing the exact byte set from dispatch.zig), `0F` switch,
  `resolveSizes`, then `OPCODE_TABLE[key]` → `{mnemonic, operand[]}`; per-operand the
  renderer consumes the right bytes (ModR/M via shared `rm16`/SIB logic, disp, imm,
  rel) and formats into `out_text`. No EIP, no cycles, no faults.
- **Rendering helpers** kept here: register-name tables (`al..bh`, `ax..di`,
  `eax..edi`, `es..gs`, `cr0..`, indexed exactly by the same `Reg32`/`Seg` indices the
  CPU uses, sourced from `state.zig`), hex formatting, the memory-operand formatter
  (`[seg:base+index*scale+disp]`).

### 4.2 Worker command (reuses the established peek model)

The disassembler needs guest memory, which lives on the worker side. Reading it
**off-worker** while a `run` is mutating guest RAM would be a torn-read data race (the
exact reason `mem_peek` goes through the worker — queue.zig:90 comment). So disasm is a
**worker command**, mirroring `memPeekSeg`:

- `queue.zig`: add `disasm: struct { linear: u32, count: u16 }` to `Command`, and a
  `DisasmResult` POD + `disasm: DisasmResult` to `Response`. `DisasmResult` is a
  **fixed-capacity** struct (no alloc): `count`, and a fixed array of per-insn records
  `{ linear: u32, len: u8, text: [N]u8, text_len: u8 }` plus the raw bytes (or recover
  bytes from len in the server). Cap `count` (e.g. ≤64) to bound the POD; the handler
  range-checks and returns `out_of_range` past the cap.
- `worker.zig`: `fn disasm(ctrl, linear, count)`: bounds-check the address window
  (`inSlab`, like memPeek), **peek** up to `count*15` bytes via
  `ctrl.peekMemPhys(linear, buf)` (side-effect-free `bus.peekBlock`), then loop
  `disasm.decodeOne` over the buffer `count` times, filling the result. **Charges no
  cycles, mutates nothing** — the determinism boundary (§5).
- The worker passes `cs_big = false` for real mode (or derives it from the live
  segment desc if a seg:off form is used; real mode CS.D=0 always today).

### 4.3 Address forms — `?linear=` and `?seg=&off=`

Two query shapes (mirroring `/api/mem` vs `/api/mem/seg`):

- `GET /api/disasm?linear=<n>&count=<n>` — disassemble at a physical/linear address.
- `GET /api/disasm?seg=<name>&off=<n>&count=<n>` — disassemble at a logical seg:off;
  the worker resolves `linear = seg_base[seg] +% off` (mirroring `segLinear`,
  worker.zig:270) so the result carries both `linear` and `seg:off`.
- Default `count` if omitted: a small window (e.g. 16). If neither `linear` nor `seg`
  is given, default to **current CS:EIP** (read on-worker from `cpuSnapshot`) so
  `GET /api/disasm` with no args gives "disassemble where we are" — the most common
  debugging call.

### 4.4 Server handler

`server.zig`: replace the 501 stub (line 609) with `handleDisasm(req, query)`:
parse `linear`/`seg`/`off`/`count` (reuse `queryU32`/`querySeg`), build the `disasm`
Command, `submitAndRespond`. Add JSON serialization of `DisasmResult` in `json_wire.zig`
(or wherever responses are serialized) producing the §6 shape.

---

## 5. Determinism / purity boundary (load-bearing)

This is a **pure read**, and the plan must keep it so:

1. **Side-effect-free reads only.** Bytes come from `bus.peekBlock` / `peekPhys8` (the
   inspection path that "leaves `machine.snapshot()` byte-identical", bus.zig:638) —
   **never** `read8`/`in8`, which can mutate device state. A not-peekable byte yields
   the deterministic `not_peekable_fill` (0xFF) and the disassembler renders it as data
   like any other byte; it never blocks or fakes.
2. **No cycle charge.** Unlike `executeOne` (which does `cpu.st.cycles += baseFor(...)`),
   the disassembler touches no ledger. Decode is cycle-neutral.
3. **No machine mutation.** No EIP advance, no register read-for-EA that could be
   confused with a write, no fault raised. The disassembler computes length purely from
   the byte stream, not from live registers (a key difference from `decodeMem16/32`,
   which fold register values into a concrete EA — the disassembler renders the
   *symbolic* operand and ignores register contents).
4. **Concurrency placement.** Because it reads guest RAM, it runs **on the worker**
   (one-command-in-flight), NOT off-worker like `/api/health` — to avoid a torn read
   during a paced/free run. It is still cycle-neutral and snapshot-irrelevant: running
   `/api/disasm` between two `run` slices does not change the machine's cycle N state.
   (The brief floats "off-worker if it only needs memory peek"; we reject that because
   the peek races the running worker — the worker is the correct serialization point,
   and it adds zero cycles, so the determinism goal is fully met without going
   off-worker.)
5. **Two-run byte-identity.** A determinism test asserts the same `/api/disasm` request
   at the same machine state yields byte-identical JSON across runs, and that disasm
   between run slices does not perturb the final-cycle snapshot.

---

## 6. Output format (Intel syntax)

`GET /api/disasm` → JSON: `{ "items": [ <insn>, ... ], "count": <n> }`, each insn:

```json
{
  "linear": 268435,          // linear address (decimal, like /api/mem)
  "seg": "cs", "off": 4096,  // present when the seg:off form was used (or CS:EIP default)
  "bytes": "B8 34 12",       // space-separated hex of the consumed bytes
  "length": 3,
  "text": "mov ax, 0x1234"   // Intel syntax, lowercase mnemonic
}
```

Formatting decisions (Intel convention):

- **Intel syntax**, `dest, src` order, lowercase mnemonics.
- **Immediates / displacements**: `0x`-prefixed hex (e.g. `0x1234`); signed
  displacements rendered with sign (`[bx+si-0x4]`).
- **Memory operands**: `[seg:base+index*scale+disp]`; segment shown **only** when an
  override prefix is present (e.g. `es:[di]`); default segment omitted (matches common
  debugger output and dosbox-x's "no ptr" style).
- **Size hints**: emit `byte`/`word`/`dword` only when operand size is ambiguous from
  the operands (e.g. `byte [bx], 0x1` for Grp1 imm-to-mem) — otherwise omit.
- **Prefixes**: `rep`/`repne`/`repe`/`lock` rendered as leading tokens
  (`rep movsw`); segment override folded into the memory operand, not a separate token.
- **Branches**: relative targets resolved to the **absolute offset** and shown
  (`jmp 0x1234` / `call 0x0010:0x1234` for far). The 16- vs 32-bit operand/address
  size affects register names (`ax` vs `eax`, `[bx+si]` vs `[ebx+esi*2]`) and immediate
  widths — driven by `resolveSizes`.
- **Unknown/`db`**: `db 0x66` (length 1) for bytes with no table entry; `(bad)` only
  where an encoding is structurally invalid. No fabricated mnemonics.

---

## 7. Tests

1. **`src/cpu/disasm_test.zig` — golden byte→text+length** (the core suite). A table of
   `{ bytes, cs_big, expected_text, expected_len }` covering, at minimum:
   - plain ops (`mov ax,imm`, `add`, `inc`, `push`/`pop`);
   - ModR/M reg & all mem forms incl. disp16-direct, BP→SS default, SIB (32-bit);
   - `0x66`/`0x67` size flips (16↔32 operand & address);
   - segment overrides (`es:`, `fs:`);
   - `REP`/`REPNE` string ops;
   - near & far JMP/CALL/RET, Jcc rel8 + `0F` Jcc rel16/32, LOOP/JCXZ;
   - groups (Grp1-5, Grp8) dispatched by ModR/M.reg;
   - SHLD/SHRD, MOVZX/MOVSX, BT-family, SETcc, MOV CR/DR, Grp7;
   - the no-FPU ESC range renders honestly with correct length;
   - unknown byte → `db` length 1.
2. **Length cross-check vs CPU (the anti-drift guard).** For each opcode file in the
   vendored conformance vectors (`src/cpu/testdata/80386/`, the ProcessorTests/MOO
   byte+state vectors used by `conformance_test.zig`), feed the instruction bytes to
   `disasm.decodeOne` and assert **disasm's reported length == the bytes the CPU
   actually consumes** (run the same bytes through `executeOne` and read the resulting
   EIP delta / `dec.len`). This pins length parity across the whole executed ISA
   without needing golden *text* for every vector. Text is golden-checked only for the
   curated set in test (1).
3. **Comptime coverage test.** Assert every opcode the CPU dispatches (the arms in
   `exec.zig` `dispatchOne`/`dispatch0F`, or a shared opcode-list extracted for both)
   has a `disasm` table entry — fails the build if a new CPU opcode lands without a
   disassembler entry (closes the drift gap structurally).
4. **`/api/disasm` integration test** (`server_integration_test.zig`): lay known bytes
   at CS:EIP, `GET /api/disasm?count=N` (and the `?linear=`/`?seg=&off=` forms),
   assert the JSON items' `text`/`length`/`bytes`/`linear` match; assert the no-arg form
   defaults to CS:EIP; assert bad/oversized `count` → 400/out_of_range; assert the
   address-out-of-range case is reported, not faked.
5. **Determinism test** (`src/api/determinism_test.zig`): same request twice → byte-
   identical JSON; disasm between two `run` slices leaves the final-cycle snapshot
   byte-identical (cycle-neutrality + purity per §5).

---

## 8. Phased roadmap

### Phase 0 — front-end reuse seam
- [ ] Confirm `decode.zig` exports the pure helpers needed (`OperandSize`, `AddrSize`,
      `resolveSizes`, `rm16`); if any prefix/`0F`-boundary fact is only inside
      `dispatch.executeOne`, extract it into a small shared pure fn in `decode.zig` so
      both the executor and disasm use one copy (no behavior change to the executor).
- [ ] Decide & document the shared opcode-list source used by the §7.3 coverage test.

### Phase 1 — `src/cpu/disasm.zig` core (decode-only, pure)
- [ ] Module skeleton: `decodeOne(read, base_off, cs_big, out_text) Insn`; byte-source
      `anytype`; fixed text buffer; no alloc/clock/state.
- [ ] Prefix scan + `0F` map mirroring `executeOne`; `resolveSizes`; 15-byte cap.
- [ ] Operand-shape table (from the Intel 386 manual): mnemonic + operand
      descriptors for the full executed ISA (one-byte + `0F`), incl. the ModR/M groups.
- [ ] Register/segment/CR-DR name tables indexed to match `state.zig`.
- [ ] Memory-operand renderer (16-bit via `rm16`; 32-bit base+index*scale+disp via the
      SIB rules); segment-override folding; signed-disp formatting.
- [ ] Immediate/disp/rel consumption per operand shape; branch-target resolution.
- [ ] No-FPU ESC range: consume ModR/M, render honest marker (no x87 mnemonics).
- [ ] Unknown byte → `db 0x..` length 1 (never fabricate).

### Phase 2 — tests for the core
- [ ] `src/cpu/disasm_test.zig` golden byte→text+length suite (§7.1).
- [ ] Length cross-check vs `executeOne` over the conformance vectors (§7.2).
- [ ] Comptime opcode-coverage test (§7.3).
- [ ] Wire the new test file into the build (`zig build test`).

### Phase 3 — worker command + API
- [ ] `queue.zig`: `Command.disasm`, `DisasmResult` POD (fixed cap), `Response.disasm`.
- [ ] `worker.zig`: `disasm(ctrl, linear, count)` — bounds-check, peek bytes, loop
      `decodeOne`, fill result; zero cycles; resolve `seg:off`→linear for that form;
      default to CS:EIP via `cpuSnapshot` when no address given.
- [ ] `server.zig`: replace the 501 (line 609) with `handleDisasm`; parse
      `linear`/`seg`/`off`/`count`; range-check `count`; `submitAndRespond`.
- [ ] `json_wire.zig`: serialize `DisasmResult` to the §6 JSON shape.

### Phase 4 — integration + determinism + docs
- [ ] `/api/disasm` HTTP integration tests (§7.4): all address forms, defaults,
      error cases.
- [ ] Determinism test (§7.5): two-run JSON identity + snapshot-irrelevance.
- [ ] Update the static UI / `plans/debugging-with-zdos.md` to mention `/api/disasm`
      (optional; a disassembly pane in the web UI is a later nice-to-have).
- [ ] `zig build test` green; add a `plans/ROADMAP.md` entry for the milestone.

---

## 9. Open questions (resolve during Phase 1, none blocking)

- **`DisasmResult` text capacity / count cap.** Pick `text` width (≈48 bytes covers the
  longest real-mode insn) and `count` cap (≈64) to bound the POD; document and
  range-check. Larger windows = multiple requests (paging by `linear`), consistent with
  `/api/mem`'s `MAX_MEM_CHUNK` model.
- **Default `count`** when omitted (proposed 16).
- **Far/relative target rendering** detail (segment:offset vs flat) — settle in §6 when
  writing the renderer; keep it unambiguous and reversible.
