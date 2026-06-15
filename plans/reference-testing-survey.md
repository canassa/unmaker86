# Reference emulator testing survey

How dosbox-x, dosbox-staging, and spice86 test their emulation, and what zdos can borrow.
Read-only research over the checked-out submodules under `references/`. Where a claim depends on
something *not* in the checkout (e.g. a NuGet-delivered test corpus), that is called out.

zdos's current approach, for reference:
- **CPU:** external SingleStepTests/ProcessorTests-style per-instruction vectors (MOO format), run
  as a guard (~2900 vectors) — `src/cpu/processor_tests.zig`.
- **DOS/BIOS/devices:** an *oracle loop* — real Borland C++ 3.1 `.EXE`s (`tools/bcc.sh`) run under
  dosbox-x HEADLESS to mint a golden (console+exit code via `tools/oracle.sh`, or a binary
  device-state blob via `tools/oracle-io.sh`), then asserted OFFLINE byte-for-byte
  (`src/dos/oracle_test.zig`, `src/dos/io_oracle_test.zig`). dosbox-x is the truth source.
  Graphics goldens capture guest-observable device STATE (VRAM/palette/regs the guest reads back),
  not rendered pixels.
- Plain Zig unit tests per module (`zig build test`).

---

## 1. Per-emulator summary

### dosbox-x  (`references/dosbox-x`)
Smallest, most inherited test surface of the three.

- **Unit tests:** `references/dosbox-x/tests/` — four gtest/gmock files inherited from upstream
  DOSBox: `dos_files_tests.cpp`, `drives_tests.cpp`, `shell_cmds_tests.cpp`,
  `shell_redirection_tests.cpp` (+ `dosbox_test_fixture.h`, `tests.h`). gtest/gmock sources are
  vendored under `tests/gtest/` and `tests/gmock/`. Coverage is DOS path/filename canonicalization,
  drive logic, and shell command/redirection parsing. No CPU, no device, no memory tests.
- **How run:** compiled INTO the emulator behind `C_DEBUG` (`tests/tests.h` `#include`s the .cpp
  files), launched as `dosbox-x -tests`. `tests/readme.txt` documents this. CI runs it on every
  push: `.github/workflows/linux.yml:59-64` (`dosbox-x-sdl1 -tests`, `dosbox-x-sdl2 -tests`),
  `macos.yml:72-73`, `vsbuild32.yml:52` etc.
- **CPU conformance:** none. Searched for `test386`, `singlestep`, `8088`, instruction-vector
  corpora — none present.
- **Integration/golden:** none automated. `references/dosbox-x/NOTES-TESTING-LOG/2018-07-*/` are
  hand-written human test reports (TXT). `pc98-testme-1/` is a manual PC-98 test artifact. No
  screenshot/framebuffer regression harness (searched `screenshot`, `golden`, `.png` in `tests/`).
- **Determinism:** none (only unrelated `determinis` hits in the bundled MT-32 reverb lib).

### dosbox-staging  (`references/dosbox-staging`)
The most polished *unit*-test setup, but still no CPU/device/integration emulation tests.

- **Unit tests:** `references/dosbox-staging/tests/` — ~30 gtest files (`tests/CMakeLists.txt` lists
  them). Most are pure-utility: `bit_view_tests.cpp`, `bitops_tests.cpp`, `rgb_tests.cpp`,
  `rect_tests.cpp`, `ring_buffer_tests.cpp`, `rwqueue_tests.cpp`, `fraction_tests.cpp`,
  `math_utils_tests.cpp`, `string_utils_tests.cpp`, `unicode_tests.cpp`, `fs_utils_tests.cpp`,
  `support_tests.cpp`, `port_containers_tests.cpp`, `multi_prefix_tests.cpp`. A few exercise DOS
  modules through a real DOSBox boot fixture: `dos_files_tests.cpp`, `drives_tests.cpp`,
  `dos_memory_struct_tests.cpp`, `shell_cmds_tests.cpp`, `shell_redirection_tests.cpp`,
  `batch_file_tests.cpp`, `cmd_move_tests.cpp`. One device-adjacent test: `int10_modes_tests.cpp`
  (parses CGA color prefs / `parse_color_token`) and `mixer_tests.cpp` / `program_mixer_tests.cpp`.
- **Fixture:** `tests/dosbox_test_fixture.h` boots a minimal real DOSBox (`DOSBOX_Init`, `CPU_Init`,
  `BIOS_Init`, `DOS_Init`, `AUTOEXEC_Init`) with `tests/files/dosbox-staging-tests.conf`, then runs
  assertions against the live DOS module. Comment notes it inits the minimum modules for a "4-fold"
  speedup vs full init — a useful pattern (a lightweight bring-up of the real stack for tests).
- **How run:** GoogleTest via CMake/CTest. `tests/CMakeLists.txt` builds `dosbox_tests`, links
  `dosboxcommon` + `GTest::gmock_main`, registers with `gtest_discover_tests`. CI:
  `.github/workflows/linux.yml:175-178` runs `ctest -j 4 --preset ...`.
- **In-emulator test program / test-ROM runner:** `src/dos/programs/biostest.cpp` — a `BIOSTEST`
  debug command (gated `C_DEBUGGER`) that loads a BIOS ROM file into memory and executes it.
  Manual, not wired into CI. `tests/files/fpu_test.asm` is a self-modifying-code FPU smoke test
  (prints "ok"/"bad"); from issue #2247, also manual.
- **CPU conformance:** none. No SingleStepTests/test386 corpus.
- **Integration/golden/screenshot:** none automated. `resources/drives/y/testpics` exists but is
  shipped content, not a regression baseline. No image-diff harness (searched).
- **Determinism:** none (only doc-text hits).

### spice86  (`references/spice86`)
By far the richest and most directly relevant — a C# emulator with MCP/debug hooks like zdos, and
the only one of the three that tests the CPU against external per-instruction vectors AND runs real
guest test programs. 167 `*.cs` test files under `tests/Spice86.Tests/`.

- **Unit tests (xunit + FluentAssertions + NSubstitute):** broad and deep. Highlights:
  - CPU/ALU: `AluTests.cs` (flag-exact SHLD/SHRD etc., table-driven `[Theory]`/`[InlineData]`).
  - Memory: `MainMemoryTest.cs`, `MemoryBasedDataStructureTest.cs`, `RealModeMmuTest.cs`,
    `StackBoundaryTest.cs`, `DataTypeTests.cs`.
  - Devices: `Video/DacTest.cs` (DAC 6-bit behavior), `Video/RendererTests.cs` +
    `VgaRenderer256Color*Tests.cs` + `RendererTestsBase.cs` (assert exact output pixels from known
    VRAM/palette/register state — see §3), `Video/VRamLayoutTests.cs`, `Video/VideoMemoryTests.cs`,
    `IOPortDispatcherTests.cs`, `TimePriorityQueueTests.cs`.
  - Debug infra (mirrors zdos's API server): `Breakpoint*Tests.cs`, `Conditional*`, `Http/Http*`,
    `McpServerToolStateTests.cs`, `EmulatorStateSerializationFolderTests.cs`.
  - The CFG/JIT recompiler: `CfgCpu/*`, `CfgCodeGeneration/*`, `GeneratedCodeMachineTest.cs`.
- **CPU instruction conformance — SingleStepTests 80386:** `tests/Spice86.Tests/CpuTests/
  SingleStepTests/`. `SingleStepTest.cs` runs the same SingleStepTests family zdos uses, split into
  5 opcode ranges (`00-65`, `66`, `67.00-67.7F`, `67.80-67.FF`, `68-FF`) as `[Theory]` cases.
  `CpuTestRunner.cs` loads each test's initial RAM+registers, executes via the CfgCpu, then asserts
  final registers + RAM (`CpuTestAsserter.cs`), with a per-opcode **EFLAGS mask** so documented
  "undefined" flag bits are ignored (`UndefinedFlagsTable.cs`, driven by `80386.csv`). The vector
  ZIPs are NOT in the repo — they come from **NuGet packages**
  `singlesteptests.intel80386.* @ 2025.11.5` (`tests/Spice86.Tests/Spice86.Tests.csproj:62-83`),
  copied next to the test binary at build time. A **revocation-list** mechanism
  (`RevocationListHelper.cs`, `revocation_list_80386_*.txt`, `eternal_revocation_list_80386.txt`)
  records hashes of known-failing vectors so they're skipped instead of red — i.e. a curated
  allow-list of currently-passing vectors, with a regen mode to refresh it. (zdos has no equivalent
  skip ledger.)
- **CPU conformance — test386:** `MachineTest.Test386ButNotProtectedMode`
  (`tests/Spice86.Tests/MachineTest.cs:931+`). Loads the community **test386.asm** ROM at 0xF0000
  / reset vector, runs it, and asserts the 8 POST codes it writes to port 0x999 end in 0xFF
  ("finished normally"); ASCII errors are captured on port 0x998 (`Test386PostPortHandler.cs`,
  duplicate-POST detection guards against looping). Run in BOTH emulated and JIT/generated-code
  modes via `[MemberData(JitModes)]`.
- **CPU regression — ASM memory-dump goldens:** `tests/Spice86.Tests/Resources/cpuTests/*.bin`
  (~45 NASM programs: `add`, `mul`, `div`, `rotate`, `strings`, `rep`, `segpr`, `selfmodify*`,
  `lockprefix`, …, sources in `asmsrc/`). `MachineTest.TestOneBin` runs each and compares full guest
  memory to a golden `res/MemoryDumps/<name>.bin`, plus the disassembled listing
  (`res/DumpedListing/<name>.txt`) and CFG-blocks JSON. This is a real cycle-of-real-instructions
  golden — closest in spirit to zdos's oracle blobs, but self-generated rather than minted from an
  external oracle.
- **DOS/BIOS/EMS/XMS integration — self-asserting guest programs:** the pattern zdos should study
  most. `tests/Spice86.Tests/Resources/{DosInt21Tests,EmsTests,XmsTests,DosExecTests,DosFcbTests,
  RtcTests,VgaTests,DosBatchTests,DosTsrTests,...}` hold paired `<name>.asm`/`<name>.com` programs
  (DosInt21Tests: 58 pairs; EmsTests: 38; RtcTests: 10; DosExecTests: 8; ...). Each `.com` exercises
  one API and writes a result byte to **port 0x999** (0x00=pass, 0xFF=fail) and optional detail
  bytes to **port 0x998** (`Utility/TestIoPortHandler.cs`). The xunit test runs the program through
  the full emulation stack and asserts `Results.Should().Contain(0x00).And.NotContain(0xFF)`
  (`Dos/DosInt21IntegrationTests.cs:241` `AssertResourcePasses`). Tests can pre-seed the host FS,
  inject keystrokes at a fixed cycle, or redirect stdin (e.g. `RunDosResource(..., keyInjectionAction
  ..., fileSystemSetup ...)`). `NativeDosTests/` ships C/asm sources + build scripts (`build.bat`,
  `c_exec.c`, `tsr.asm`) for an externally-built native-DOS comparison corpus.
- **How run:** `dotnet test --configuration Release` across macOS/Windows/Ubuntu — CI in
  `.github/workflows/pr.yml:27`, `nuget.yml:28`, `prerelease.yml:35`. So the full SingleStepTests +
  test386 + ASM goldens + DOS-program corpus all run on every PR.

---

## 2. CPU conformance approaches

| approach | who | notes vs zdos |
|---|---|---|
| External per-instruction vectors (SingleStepTests / ProcessorTests / MOO) | **zdos**, **spice86** | spice86 uses the SAME corpus family. Confirms zdos's choice is the right one and is shared by the most serious of the three. |
| test386.asm community POST ROM | **spice86** only | Complements vectors: exercises *sequences*, faults, and addressing across a whole boot, not isolated opcodes. zdos has nothing equivalent. |
| Self-built ASM programs → full-memory golden dump | **spice86** only | Per-instruction-family programs whose final RAM is the golden. Catches integration bugs vectors miss. |
| gtest unit tests on CPU helpers | dosbox-staging (ALU-ish via utils) , spice86 (`AluTests`) | Fine-grained flag/edge tests; complements but doesn't replace vectors. |
| No CPU conformance at all | **dosbox-x**, **dosbox-staging** | Neither validates the CPU core against any external truth. zdos is already ahead of both here. |

Net: zdos's external-vector guard already matches the strongest reference (spice86) on the
*per-instruction* axis. The two things spice86 has that zdos lacks: (a) **test386.asm** as a
whole-machine boot conformance ROM, and (b) a **revocation/skip ledger** so a partial vector pass is
green-with-known-gaps rather than all-or-nothing. zdos's MOO format already supports exception
vectors; the EFLAGS-undefined-bits masking spice86 does via `UndefinedFlagsTable`/`80386.csv` is
worth confirming zdos handles (otherwise legitimately-undefined flag bits cause false failures).

---

## 3. Integration / golden / screenshot approaches

- **dosbox-x / dosbox-staging:** no automated integration or golden tests. dosbox-staging boots the
  real DOS stack in a gtest fixture and checks DOS *module* behavior (file ops, drives) but does not
  run guest binaries to completion or compare output/state of a real program. No screenshot/
  framebuffer diffing in either (searched `screenshot`/`golden`/`.png`). Both rely on manual testing
  logs (dosbox-x `NOTES-TESTING-LOG/`) for real-software validation.
- **spice86:** three golden styles, none of which use rendered-pixel image files:
  1. **Self-asserting guest programs** (port 0x999/0x998 pass/fail) — see §1. This is the analogue
     of zdos's oracle loop, but the *assertion lives inside the guest program* rather than being a
     byte-compare against an external oracle's captured output.
  2. **Full-memory dump goldens** for ASM CPU programs (`res/MemoryDumps/*.bin`) — analogous to
     zdos's device-state blob, but covering general RAM and self-generated.
  3. **Computed-expected device output**: `Video/RendererTestsBase.cs` sets known VRAM + DAC/palette/
     attribute registers, runs the renderer, and asserts exact `uint` ARGB pixels
     (`frame[0].Should().Be(state.DacRegisters.PaletteMap[42])`, etc.). This is the same philosophy
     as zdos's "capture guest-observable device STATE, not pixels" — but spice86 *does* assert the
     final rendered framebuffer, just computing the expectation from first principles rather than
     storing a golden image. They also cross-check the SIMD (AVX2/SSE41) renderers against the
     scalar one (`VgaRenderer256ColorAvx2Tests` vs `...Tests`) — a self-consistency oracle.

Comparison: zdos's oracle loop is **stronger on truth-sourcing** (an independent emulator mints the
golden, so a bug shared between test-author and emulator can't hide), whereas spice86's
self-asserting programs can encode the author's wrong expectation. zdos's device-state-blob is
conceptually equal to spice86's memory-dump goldens. Neither project does rendered-image regression
(and for a headless determinism-first emulator, zdos's state-blob choice is the right one).

---

## 4. Determinism / reproducibility testing

- **dosbox-x:** none.
- **dosbox-staging:** none.
- **spice86:** no dedicated "run twice, assert byte-identical" determinism test — but it has the two
  ingredients zdos cares about:
  - **`ClockTests.cs`** verifies `CyclesClock` derives wall-clock time purely from the cycle counter
    (`CyclesClock(state, cyclesPerSecond, ..., startTime)`; advance N cycles → time = start + N/rate).
    That is exactly zdos's "emulated time = f(cycle counter)" constraint, expressed as a unit test —
    though spice86's assertion is `BeCloseTo(..., 100ms)` (tolerant), not byte-exact.
  - **`EmulatorStateSerializationFolderTests.cs`** + the state-serialization subsystem hash the
    program and can dump/restore full machine state to a folder keyed by program hash — the
    machinery a reproducibility check would build on, but it's tested for correct foldering/hashing,
    not for run-to-run identity.

So **no reference emulator tests determinism the way zdos's prime directive demands** (launch → run
to cycle N → byte-identical capture vs golden, every run). This is genuinely zdos's differentiator;
none of the three guards it, and spice86's own design notes (per zdos's CLAUDE.md) acknowledge it
smears cycles across traps. zdos should NOT expect to borrow a determinism harness — it has to build
the canonical one. spice86's `CyclesClock`/`ClockTests` is the only borrowable seed (the idea of a
unit test pinning time-as-a-function-of-cycles), and zdos can make it byte-exact rather than tolerant.

---

## 5. Concrete recommendations for zdos (ranked)

1. **Adopt test386.asm as a whole-machine boot conformance ROM.** *(High value, medium effort.)*
   Per-instruction MOO vectors validate opcodes in isolation; test386 validates the CPU executing a
   real instruction *stream* with faults, segment arithmetic, and addressing modes across a boot —
   exactly the integration gaps vectors miss, and it's free, deterministic, and headless. Fit: it's
   a real-mode-ish boot ROM that writes POST codes to a port; zdos can run it through the machine
   facade and assert the POST sequence ends in 0xFF, mirroring `MachineTest.Test386PostPortHandler`
   (`references/spice86/tests/Spice86.Tests/Test386PostPortHandler.cs`). Wire as one `zig build test`
   case. Caveat: test386 is built for an i386 boot at 0xF0000/reset-vector; zdos must confirm its
   bring-up can host it (it targets a 386 real-mode game, so the ISA is in scope).

2. **Add a self-asserting in-guest test-program corpus (port-write pass/fail), alongside the oracle
   loop — not replacing it.** *(High value, low-medium effort.)* spice86's
   `Resources/DosInt21Tests/*.com` (58 programs) writing 0x00/0xFF to a result port
   (`Utility/TestIoPortHandler.cs`, `AssertResourcePasses`) is the cheapest way to grow DOS/EMS/XMS
   coverage fast: each program self-checks, so no oracle round-trip is needed and tests run fully
   offline at native speed. zdos already compiles guest C with `tools/bcc.sh`; have those programs
   write a pass/fail byte to a chosen debug port and assert it in `zig build test`. Keep the existing
   dosbox-x-minted oracle goldens for cases where independent truth-sourcing matters (the
   self-asserting form can encode an author's wrong expectation; the oracle form can't). Use both:
   self-assert for breadth, oracle for the cases you don't trust yourself to predict. Bonus: spice86
   shows how to inject keystrokes at a *fixed cycle* and pre-seed the host FS deterministically
   (`RunDosResource(keyInjectionAction:, fileSystemSetup:)`) — a clean pattern for scripted,
   reproducible input that fits zdos's determinism rules.

3. **Add a CPU vector "skip ledger" (revocation list) + EFLAGS-undefined-bit masking.** *(Medium
   value, low effort.)* spice86's `RevocationListHelper` + `revocation_list_80386_*.txt` +
   `UndefinedFlagsTable`/`80386.csv` let the vector suite be green-with-known-gaps and avoid false
   failures on documented-undefined flag bits. For zdos this means: (a) a checked-in list of
   vector hashes that are known-failing-for-a-reason (so the guard stays green and regressions still
   surface), and (b) per-opcode masking of undefined EFLAGS bits before comparison. Low effort, and
   it keeps the ~2900-vector guard from being all-or-nothing as coverage grows. Fit: extend
   `src/cpu/processor_tests.zig`.

Lower-priority / honest notes:
- **Deliver the vector corpus out-of-band, not in-repo** (spice86 ships SingleStepTests via NuGet
  `singlesteptests.intel80386.* @ 2025.11.5`, `Spice86.Tests.csproj:62-83`). If zdos's MOO vectors
  bloat the repo, fetch them at test time / cache them, pinned to a version. Optional.
- **A minimal-bring-up test fixture** (dosbox-staging's `dosbox_test_fixture.h` inits only the
  modules a test needs, ~4x faster) is a good pattern to keep zdos's `zig build test` fast as the
  machine grows — but zdos's module graph already favors this, so it's more a principle to preserve
  than something to copy.
- **Determinism:** nothing to borrow except the *idea* behind spice86's `ClockTests` (pin
  time = f(cycles) as a test). zdos's launch→cycle-N→byte-identical golden is already stronger than
  anything in the three references and is the project's actual differentiator — build it as the
  canonical regression test; don't expect prior art.
- Where zdos is **already as good or better**: independent truth-sourcing of golden output (the
  oracle loop beats spice86's self-asserting programs on trust), device-state-blob goldens (equal to
  spice86's memory dumps), and per-instruction conformance (matches spice86, beats both DOSBoxes).
