# DOSBox Test Suites — Inventory & Reusability for zdos

Assessment of the test code/data in the bundled reference emulators and whether
any of it can be reused for `zdos` (Zig 0.16, 386 real-mode CPU first, target
game: Betrayal at Krondor). Focus is DOSBox; spice86 noted where directly
relevant to the CPU path.

**Bottom line up front:** DOSBox's test suites contain **no CPU instruction /
flags / ModR-M / decoding tests at all**. They cover utility libraries, DOS
filesystem/memory helpers, shell, and rendering helpers. They are all
**GPL-2.0-or-later**, so copying their code/data is a license problem for zdos.
The best CPU oracle is the public **SingleStepTests/ProcessorTests 386 JSON
vectors** (already in our CPU plan), and the most useful *harness* reference is
**spice86's Apache-2.0 SingleStepTests runner**, not DOSBox.

---

## 1. Inventory

### dosbox-staging (`references/dosbox-staging/tests/`) — primary, modern fork
- **Framework:** GoogleTest + GoogleMock (`find_package(GTest REQUIRED)`,
  links `GTest::gmock_main`). See `references/dosbox-staging/tests/CMakeLists.txt:2,52`.
- **Build:** CMake target `dosbox_tests`, sources listed in
  `CMakeLists.txt:4-35`; auto-discovered via `gtest_discover_tests(...)`
  (`CMakeLists.txt:65-69`). Links the whole emulator (`dosboxcommon`) + SDL2
  (`CMakeLists.txt:51-55`).
- **Fixture:** `tests/dosbox_test_fixture.h` boots a real (minimal) DOSBox:
  `DOSBOX_Init(); CPU_Init(); BIOS_Init(); SERIAL_Init(); DOS_Init();
  AUTOEXEC_Init();` against `tests/files/dosbox-staging-tests.conf`
  (`dosbox_test_fixture.h:46-53,23`). Any test using this fixture pulls in the
  full C++ codebase.
- **Size:** 31 `*.cpp` test files + 2 headers, ~9,450 lines total
  (`wc -l tests/*`). Some files contain dozens of `TEST`/`TEST_F` cases
  (e.g. `string_utils_tests.cpp` 71, `dos_files_tests.cpp` 35,
  `math_utils_tests.cpp` 29, `bit_view_tests.cpp` 28).
- **Test data:** `tests/files/` — a config, an `fpu_test.asm`, path fixtures.
  No instruction vector tables.

### dosbox-x (`references/dosbox-x/tests/`) — older, strict subset
- Same GoogleTest approach, run via `dosbox-x -tests` (`tests/readme.txt`).
- Only 4 test files: `dos_files_tests.cpp` (396), `drives_tests.cpp` (178),
  `shell_cmds_tests.cpp` (176), `shell_redirection_tests.cpp` (154). These are
  older forks of the same staging tests (`dos_files_tests.cpp` differs from
  staging's). Ships a **vendored copy of gtest/gmock** under `tests/gtest/` and
  `tests/gmock/`.
- Nothing dosbox-x has that staging doesn't have a newer version of.

### spice86 (`references/spice86/tests/Spice86.Tests/`) — C#, noted for CPU relevance
- xUnit. Crucially contains **`CpuTests/SingleStepTests/`** — a runner for the
  SingleStepTests/ProcessorTests **80386** JSON vectors (`SingleStepTest.cs`
  header: "Executes tests from https://github.com/SingleStepTests/"). This is
  the exact conformance suite zdos's CPU plan targets.
- Supporting infra worth knowing: `UndefinedFlagsTable.cs` (parses the upstream
  `80386.csv` `f_umask` column to know which EFLAGS bits are defined per opcode
  and must be masked out when comparing), `CpuTestAsserter.cs` (per-register +
  masked-flags comparison), `RevocationListHelper.cs` + the
  `Resources/cpuTests/singleStepTests/*revocation_list*` files (a curated list
  of upstream vectors known to be wrong/contentious to skip), `InvalidSibFilter.cs`.
- Also `Resources/Dos*Tests/`, `EmsTests`, `XmsTests`, `VgaTests` — DOS/BIOS
  behavioral fixtures (binary/asm test programs), not table data.

---

## 2. Coverage map (what's actually tested)

DOSBox-staging, grouped; "meaningful" = real logic exercised, "trivial" =
sanity/smoke.

| Area | Files | Quality |
|---|---|---|
| **CPU instructions / flags / ModR-M / decode** | **none** | **Not covered at all** |
| Bit utilities | `bitops_tests.cpp` (9 TESTs), `bit_view_tests.cpp` (28) | Meaningful, table-ish — set/clear/flip/mask semantics on 8/16/32-bit |
| Math helpers | `math_utils_tests.cpp` (29) | Meaningful — `left_shift_signed`, overflow/clamp edge cases (`math_utils_tests.cpp:11-45`) |
| String/format | `string_utils_tests.cpp` (71), `unicode_tests.cpp`, `ansi_code_markup_tests.cpp`, `support_tests.cpp` | Meaningful, lots of edge cases |
| DOS memory structs | `dos_memory_struct_tests.cpp` (6 TEST_F) | Meaningful but **fixture-coupled**: boots DOSBox, uses `DOS_AllocateMemory`, `PhysicalMake`, SSET/SGET macros (`dos_memory_struct_tests.cpp:14-19,59`) |
| DOS filesystem / name parsing | `dos_files_tests.cpp` (35), `drives_tests.cpp` | Meaningful behavioral (8.3 name munging `DOS_MakeName`, DTA name split `DTAExtendName` — `dos_files_tests.cpp:41-55`); fixture-coupled, `#include`s the `.cpp` under test |
| Shell / batch / redirection | `shell_cmds_tests.cpp`, `shell_redirection_tests.cpp`, `batch_file_tests.cpp`, `cmd_move_tests.cpp`, `multi_prefix_tests.cpp` | Behavioral, DOSBox-coupled |
| Video / int10 modes | `int10_modes_tests.cpp` | Color-token/CGA-palette parsing (`int10_modes_tests.cpp:24-30`) — config parsing, not video timing |
| RGB / render / scaler | `rgb_tests.cpp`, `rect_tests.cpp`, `fraction_tests.cpp` | Meaningful, self-contained math (color conversion, rect geometry) |
| Containers / queues | `ring_buffer_tests.cpp`, `rwqueue_tests.cpp`, `port_containers_tests.cpp` | Meaningful, generic data-structure tests |
| Config / i18n / mixer / shaders | `language_territory_tests.cpp`, `messages_adjust_tests.cpp`, `mixer_tests.cpp`, `program_mixer_tests.cpp`, `shader_pragma_parser_tests.cpp`, `fs_utils_tests.cpp` | Meaningful but DOSBox-specific subsystems irrelevant to zdos now |

**Most-relevant-to-zdos verdict:** the things we "care most about" (CPU
instruction behavior, flags, ModR-M, memory access, DOS-level behavior) are
*mostly absent*. Closest hits are the **DOS filesystem name-munging** and **DOS
memory allocation** tests — useful behavioral oracles, but they assert against
running DOSBox internals, not portable data.

---

## 3. Reusability for zdos (Zig)

All DOSBox tests are C++ and link the emulator; none can run against Zig. Classified:

- **Portable data/vectors → essentially none.** No table-driven instruction or
  flag vectors exist in DOSBox. The bit/math/string tests are
  expression-by-expression assertions, not input→output tables; re-encoding them
  as Zig data is low value and would copy GPL expression.

- **Behavioral oracle (translate semantics, rewrite harness) → the best DOSBox
  category:**
  - `dos_files_tests.cpp` — 8.3 filename canonicalization and DTA name/ext
    splitting (`DOS_MakeName`, `DTAExtendName`, `dos_files_tests.cpp:41-55`).
    The *expected outputs* (how DOS mangles paths) are real DOS semantics worth
    reproducing when zdos reaches DOS file APIs.
  - `dos_memory_struct_tests.cpp` — MCB/allocation layout expectations
    (`DOS_AllocateMemory` block sizing, segment layout, `dos_memory_struct_tests.cpp:14-24`).
  - `math_utils_tests.cpp` overflow/clamp edge cases — translatable but trivial
    to re-derive ourselves.
  These encode *DOS behavior we'd otherwise have to discover*, but we should
  re-derive the expectations from DOS documentation/our own runs, not copy.

- **Conceptual only (imitate structure) → the GoogleTest fixture pattern.**
  `dosbox_test_fixture.h`'s "init only the minimum modules" idea
  (`dosbox_test_fixture.h:40-53`) is a good pattern for a future zdos
  integration harness (boot minimal machine, run, assert). Imitate, don't copy.

- **Not useful → everything else** (mixer, shaders, i18n, containers, rect/rgb,
  shell) — coupled to DOSBox subsystems zdos doesn't mirror, or trivially
  re-derivable.

**spice86 (not DOSBox, but the standout for CPU):** `SingleStepTests/` is the
single most reusable *reference* across all three repos for zdos's CPU-first
goal — not as code to copy (C#), but as a **proven blueprint**: how to load the
JSON vectors, how to mask undefined EFLAGS per opcode via `80386.csv`
(`UndefinedFlagsTable.cs`), and a **revocation list** of bad upstream vectors to
skip (`RevocationListHelper.cs` + `Resources/cpuTests/singleStepTests/*revocation_list*`).
That list, in particular, captures hard-won knowledge of which 386 vectors are
wrong — valuable to know about even if we re-derive our own.

---

## 4. Overlap with our existing CPU plan (ProcessorTests JSON vectors)

Our `plans/cpu.md` already targets the SingleStepTests/ProcessorTests 386 JSON
vectors. Assessment:

- **For the CPU itself, the JSON vectors are strictly the better oracle.** They
  are per-opcode, per-case `initial → final` register/flag/memory snapshots —
  exactly instruction behavior, flags, ModR-M, and memory access. DOSBox has
  **nothing** in this space, so for CPU work DOSBox is **redundant / empty**.
- DOSBox adds value only **above the CPU**: DOS file API name munging, MCB/memory
  allocation layout, shell behavior. None of that is in the JSON vectors. So the
  two are complementary, not competing — but the DOSBox part only matters once
  zdos has a working CPU and starts on DOS/BIOS services (needed eventually for
  Betrayal at Krondor, which is a DOS app, but not for the CPU milestone).
- **Honest call:** for the current 386-real-mode milestone, DOSBox's tests are
  not useful as a CPU oracle. Use the JSON vectors; revisit DOSBox's DOS-level
  *expectations* (as documentation, re-derived) when building DOS services.

---

## 5. Licensing — FLAG (do not bypass; user decides)

- **All dosbox-staging test files are `GPL-2.0-or-later`** (30/30 files carry
  `// SPDX-License-Identifier: GPL-2.0-or-later`; project license file is
  `references/dosbox-staging/LICENSE`). Example header:
  `tests/dosbox_test_fixture.h:1-2`.
- **dosbox-x test files are also `GPL-2.0-or-later`** (full GPLv2 header, e.g.
  `references/dosbox-x/tests/dos_files_tests.cpp:1-19`).
- **Implication, stated plainly:** copying DOSBox test *code or test data*
  verbatim (or as a close derivative/translation) into zdos would make that
  copied portion a derivative work under GPL-2.0-or-later, which would likely
  impose GPL obligations on zdos. If zdos intends a non-GPL license, this is a
  conflict. **This is a flag for the user to decide — not a final legal opinion.**
- **License-safe alternatives:**
  1. Use the **ProcessorTests/SingleStepTests 386 JSON vectors** directly — they
     are distributed separately under their own (permissive) terms; confirm the
     exact license on that repo before vendoring.
  2. **Independently re-derive** any DOS-behavior expectations from primary docs
     (RBIL, Intel 386 manual) or from our own runs, rather than copying DOSBox's
     assertions.
  3. **Write our own** tests in Zig `test {}` blocks.
  4. spice86 is **Apache-2.0** (`references/spice86/LICENSE`) — its *harness
     design* is permissively licensed; still, re-implement rather than
     line-copy, and keep attribution if any code is adapted.

---

## 6. Recommendation (CPU-first → Betrayal at Krondor)

- **CPU milestone (now): do NOT use DOSBox tests.** They contain zero
  instruction/flags/ModR-M/decode coverage. Proceed with the **ProcessorTests
  386 JSON vectors** as planned; verify that repo's license before vendoring the
  JSON.
- **Steal the *design*, not the code, from spice86's `SingleStepTests/`** (it's
  Apache-2.0): (a) JSON load + per-case run/assert loop, (b) **per-opcode
  undefined-EFLAGS masking** via the upstream `80386.csv` `f_umask`
  (`UndefinedFlagsTable.cs`), (c) a **revocation list** of known-bad vectors to
  skip (`RevocationListHelper.cs`). Re-implement all of this in Zig.
- **Write CPU tests ourselves in Zig** for things the JSON doesn't cover well or
  that aid debugging: targeted ModR-M decode unit tests, flag-by-flag checks for
  ADD/SUB/shifts/rotates, segment+offset address computation.
- **Defer DOSBox entirely until DOS/BIOS service work.** When zdos implements
  INT 21h file APIs / memory (MCB) management for Betrayal at Krondor,
  DOSBox-staging's `dos_files_tests.cpp` and `dos_memory_struct_tests.cpp` are
  worth reading as a **behavioral spec** — but **re-derive** expectations into
  our own Zig tests rather than copying (GPL). spice86's `Resources/Dos*Tests/`
  binary fixtures are an additional reference at that stage.
- **Skip dosbox-x's tests** — strict, older subset of staging's, no unique
  value; it also vendors a full gtest/gmock copy we don't need.
- **Imitate** the "init minimal subsystems" fixture pattern
  (`dosbox_test_fixture.h:40-53`) if/when zdos grows an integration-level test
  harness that boots a minimal machine.

### Quick reference — top files
- CPU oracle blueprint (Apache-2.0, reusable design): `references/spice86/tests/Spice86.Tests/CpuTests/SingleStepTests/` (`SingleStepTest.cs`, `UndefinedFlagsTable.cs`, `CpuTestAsserter.cs`, `RevocationListHelper.cs`)
- DOS behavior spec (GPL — read, re-derive): `references/dosbox-staging/tests/dos_files_tests.cpp`, `references/dosbox-staging/tests/dos_memory_struct_tests.cpp`
- Fixture pattern to imitate: `references/dosbox-staging/tests/dosbox_test_fixture.h`
- Build integration reference: `references/dosbox-staging/tests/CMakeLists.txt`
