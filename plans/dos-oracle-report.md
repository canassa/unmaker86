# DOS external-oracle divergence report — the second-pass worklist

**The oracle is dosbox-x** (a mature, correct DOS), used as an EXTERNAL TRUTH
SOURCE. Real DOS programs (Borland C++ 3.1 `.EXE`s) are run under dosbox-x
headless to MINT golden output (`tools/oracle.sh`), then zdos is asserted to
reproduce that golden offline (`zig build test-oracle`,
`src/dos/oracle_test.zig`). This is the DOS equivalent of the CPU's
ProcessorTests conformance vectors: the truth is external, not self-authored.

This file is the empirical second-pass worklist: for each corpus program, PASS
or the exact divergence, with the failing INT 21h call / behavior identified by
tracing the call stream, and cross-checked against
`references/dosbox-staging/src/dos/`. Ranked by how soon a real program (the BaK
v1 target) hits it.

Per the ground rule, **none of these divergences were "fixed" by tweaking zdos
to force a match.** The divergences ARE the deliverable. The harness keeps the
suite green by listing matched programs as permanent regressions (`PASSING`) and
known-divergent programs as a documented worklist (`DIVERGING`), each asserted to
STILL diverge so that a future fix promotes it loudly.

## How goldens are minted (the oracle harness)

```
tools/oracle.sh <program.exe> [data-files...]
```

Runs the program under dosbox-x headless (the proven `-silent -fastlaunch -nogui
-exit` flags + the device-off `-set` list from `tools/bcc.sh`; the program's dir
mounts as C:). DOS console output does not reach host stdout under headless
dosbox-x, so the program's stdout is redirected to a file on the mounted drive
(`prog.exe > OUT.TXT`) and read back; the exit code is captured with an
`if errorlevel N` append-ladder (dosbox-x's shell does not expand `%ERRORLEVEL%`
in `echo`, nor support nested `if`). The result is written to a committed golden
`<program>.expected` next to the EXE:

```
exit_code: <N>\r\n
--- output ---\r\n
<verbatim console bytes>
```

Bounded against the disk-fill hazard with `ulimit -f` (~16 MB) + `timeout 120`.
This is a MINT step (run once when adding a corpus program), NOT a `zig build
test`-time dependency — the golden is vendored and the test runs offline.

Programs whose golden depends on a command tail carry a `<STEM>.args` sidecar so
the oracle and the zdos harness pass the IDENTICAL argv.

## The corpus (each program + the DOS surface it exercises)

| Program       | DOS surface exercised                                             | Status     |
|---------------|------------------------------------------------------------------|------------|
| `HELLO.EXE`   | printf → CON; CRT startup (AH=30/4A memory-sizing)               | **PASS**   |
| `MALLOC.EXE`  | malloc/free 32 KB in chunks → CRT far heap on AH=48/4A           | **PASS**   |
| `FILEIO.EXE`  | fopen/fwrite/fseek/fread/fclose → AH=43/3D/40/3E/3C VFS          | **PASS**   |
| `ARGENV.EXE`  | argc/argv (PSP cmdtail) + getenv (PSP environment block)         | **PASS**   |
| `SUBDIR.EXE`  | fopen("SUB\\DATA.TXT") → subdirectory path resolution           | **PASS**   |

**SECOND PASS COMPLETE: all five corpus programs now reproduce the dosbox-x
goldens byte-for-byte (`zig build test-oracle` green; all five in `PASSING`,
`DIVERGING` empty).** The three fixes (below) are real DOS-semantics
implementations, not match-forcing tweaks. The remainder of this file is the
historical worklist that drove the fixes.

All five are real Borland C++ 3.1 `.EXE`s, compiled with `tools/bcc.sh` and
committed (small) alongside their `.expected` goldens; the 35 MB toolchain stays
gitignored.

---

## Divergence worklist (ranked by how soon a real program hits it)

### 1. `FILEIO.EXE` — AH=43 (get file attributes) does not check existence  ← HIGHEST PRIORITY

**Symptom.** zdos exit 1 ("FAIL: fopen write"); golden exit 0 (writes + reads
the file back). The CRT's `fopen("SCRATCH.DAT","wb")` never even creates the
file.

**Traced call stream (zdos).** The decisive call is:

```
AH=43 AL=00   get file attributes of SCRATCH.DAT (a NON-existent file)
AH=3D AL=01   open SCRATCH.DAT write-only
AH=40         write 0x50 bytes
AH=4C AL=01   abort, exit 1
```

The CRT calls **AH=43 AL=00 to probe whether the file already exists**. On real
DOS a missing file returns **CF=1, AX=2** (file not found), which tells the CRT
to take the create path (AH=3C). zdos's `getSetAttr` (`src/dos/int21.zig`,
`fn getSetAttr`) **unconditionally** returns `CX=0x20, CF=0` for AL=00 — it never
consults the VFS. The CRT therefore believes the file exists, opens it for write
(AH=3D AL=01) instead of creating it, and the inconsistent state makes the
`fopen` fail. (Note: the program path that creates files — AH=3C — is implemented
and works; the bug is purely the existence-check stub.)

**Reference (truth).** `references/dosbox-staging/src/dos/dos.cpp:1106` case
0x43/al=00 calls `DOS_GetFileAttr(name1, ...)` and sets `CF=1, AX=dos.errorcode`
when the file does not exist. The zdos stub skips this.

**Fix for the second pass.** Make AH=43 AL=00 resolve the path through the VFS
and return `CF=1, AX=ERR_FILE_NOT_FOUND` when the file is absent (and the real
attribute bits when present). This is a small, localized fix — the VFS already
has the open/stat seam. **This is the most urgent: any program that creates a
file via the C runtime hits it.**

### 2. `SUBDIR.EXE` — no subdirectory path resolution (the known BaK blocker)

**Symptom.** zdos exit 1 ("FAIL: cannot open SUB\\DATA.TXT"); golden exit 0
(prints the file from the subdir).

**Root cause.** `fn resolve` in `src/dos/int21.zig` takes only the FINAL path
component (`std.mem.lastIndexOfAny(u8, p, "\\/")`) — a deliberate single-dir-VFS
shortcut. So `SUB\DATA.TXT` resolves to `DATA.TXT` at the mount ROOT, which does
not exist → AH=3D fails. The VFS (`src/dos/vfs.zig` `HostDirDrive`) has exactly
one `std.Io.Dir` and no notion of walking into a subdirectory.

**Reference (truth).** `references/dosbox-staging/src/dos/drive_local.cpp` +
`DOS_MakeName` (dos_files.cpp) canonicalize a full path and the local drive opens
it relative to the mounted root, walking `SUB\` as a real directory.

**Fix for the second pass.** Teach the VFS to resolve multi-component DOS paths:
either (a) open the leaf via the host path `SUB/DATA.TXT` relative to the mount
root (translate `\` → `/`, 8.3-munge each component), or (b) a small directory
cache. This is the **D8/D10 subdirectory work flagged in `plans/bios-dos.md`** —
BaK loads its data files from subdirectories, so this blocks the v1 target. Also
extend AH=3B chdir / AH=39/3A mkdir/rmdir (currently chdir is a no-op success,
mkdir/rmdir are deferred-unsupported).

### 3. `ARGENV.EXE` — empty environment block + placeholder argv[0]

**Symptom.** zdos exit 0 and **argv parsing is CORRECT** (argc=4, argv[1..3] =
alpha/beta/gamma — the PSP command-tail path works). Two sub-divergences remain:

```
            golden                         zdos
argv[0]     C:\ARGENV.EXE                  C:\PROGRAM.EXE   (placeholder)
PATH=...    Z:\;Z:\SYSTEM;Z:\BIN;...       (null)           (empty env)
```

**Root cause.**
- **argv[0]:** the CRT derives argv[0] from the program-path string the env
  block ends with. `fn buildEnv` (`src/dos/loader.zig`) writes a fixed
  `host_path_placeholder` ("PROGRAM.EXE") instead of the real `C:\<exe name>`.
- **PATH / env vars:** `buildEnv` writes an EMPTY environment (just the
  double-null + the `0x0001` + placeholder path). zdos has no environment-block
  population, so `getenv("PATH")` returns null. dosbox-x inherits a populated
  environment (PATH on its Z: utility drive).

**Reference (truth).** `references/dosbox-staging/src/dos/dos_execute.cpp`
`MakeEnv` copies the parent environment AND appends the program's full path so
argv[0] is the real name.

**Fix for the second pass.** (a) Write the real `C:\<EXE>` path into the env
block's trailing program-path field (argv[0] fidelity). (b) Decide on a
deterministic environment-block policy: a pinned, reproducible env (e.g. a fixed
PATH/COMSPEC constant) so a program that reads env vars sees stable values
without coupling to the host env (a determinism concern — must NOT read the host
environment). **Lower priority than 1 & 2 for BaK** (a game rarely depends on
PATH), but argv[0] fidelity matters for any program that prints its own name.

---

## Summary (ranked second-pass worklist)

1. **AH=43 AL=00 must check file existence** (CF=1/AX=2 when absent) — blocks any
   C-runtime file creation. Smallest, most urgent fix.
2. **Subdirectory path resolution in the VFS** (`SUB\FILE`) + chdir/mkdir/rmdir —
   the known BaK blocker; D8/D10 work.
3. **Environment block: real argv[0] path + a deterministic populated env** —
   argv[0] fidelity + a pinned reproducible env policy.

## RESOLUTION (second pass — all PASS)

1. **AH=43 AL=00 — FIXED** (`int21.zig fn getSetAttr`). Now resolves the path
   through the VFS and `stat`s it: returns CF=1/AX=2 when absent, the real
   attribute bits + CF=0 when present (`dos.cpp:1106`). FILEIO's `fopen("wb")`
   existence probe now correctly takes the create path.
2. **Subdirectory path resolution — IMPLEMENTED** (`vfs.zig`, `int21.zig fn
   resolve`). The VFS now walks multi-component DOS paths against the host tree
   (fast statFile path for identical names; deterministic sorted-iteration munge
   fallback for intermediate dirs). `int21.zig resolve` returns the full
   DOS-relative path (drive-prefix-stripped, CWD-joined when relative) instead of
   only the final component. AH=3B chdir / AH=39 mkdir / AH=3A rmdir / AH=47
   get-cwd now back this. SUBDIR resolves `SUB\DATA.TXT` correctly.
3. **Environment block + argv[0] — IMPLEMENTED** (`loader.zig fn buildEnv` +
   `canonicalProgPath`). The env block now carries dosbox-x's EXACT pinned env
   (`COMSPEC`, `PATH`, `PROMPT`, in that order — captured from `dosbox-x` `SET`,
   never the host process env), the 0x0001 word, then the canonical `C:\<EXE>`
   path so the CRT derives the real argv[0]. Matching dosbox-x's env exactly was
   also necessary for MALLOC: the Borland near-heap geometry (the `environ[]`
   array size) is env-dependent, and a divergent env shifted it enough to clobber
   2 heap bytes; the exact env restores byte-parity (32768 verified).

PASSING (permanent regressions): all five corpus programs.

This worklist is empirical: it is exactly what real compiler-built programs need
that zdos lacks, surfaced by an external oracle rather than by self-authored
fixtures.

---

## EMS band (LIM Expanded Memory, INT 67h) — all PASS

Four real BC++ 3.1 programs (direct INT 67h via `int86`/`int86x`, no EMS
library) added to the corpus, goldens minted from dosbox-x:

- **EMSINFO** — presence probe (open `EMMXXXX0` via AH=3D + IOCTL device-bit
  check) then AH=46 version / AH=40 status / AH=41 page-frame seg / AH=42 page
  count. Golden: `version=40 status=00 frame=E000 free=03A4 total=03A4`.
- **EMSMAP** — the core correctness proof: alloc 4 pages (AH=43), map logical
  page 0 → slot 0, write pattern A; map page 1, write pattern B; map page 0
  back and read pattern A again, then page 1 back. Proves logical pages persist
  across remap. Free (AH=45). Golden read-backs `11..18` / `A0..A7`.
- **EMSCOUNT** — AH=4B handle count / AH=4C pages-per-handle / AH=4D
  all-handles array. Allocates two handles (3 + 5 pages). Golden:
  `base=0001 after=0003`, `h1pages=0003 h2pages=0005`,
  `entries=0003 sumpages=0020`.
- **EMSSAVE** — AH=4E save/restore page map (AL=03 size, AL=00 save, AL=01
  restore). Maps page 0, saves, remaps to page 1, restores, reads page 0 back.
  Golden: `before: C3 C4 C5 C6`, `after: 5A 5B 5C 5D`, `mapsize=10`. Minted
  TWICE — byte-identical, golden is stable/deterministic.

### zdos EMS fixes to match the dosbox-x oracle (all cited to `ems.cpp`)

1. **AH=46 version 0x32 → 0x40.** dosbox-x reports LIM EMS **4.0**
   (`EMM_VERSION 0x40`, ems.cpp:32/805). zdos returned 0x32 (3.2). Fixed.
2. **AH=42 page count 64 → 0x03A4.** dosbox-x reports free=total=0x03A4 on a
   default-memsize machine (`get_total_pages`/`get_free_pages`, ems.cpp:93/98).
   zdos now reports `REPORTED_PAGES=0x03A4` total, free = total − user-allocated
   pages. (dosbox-x's free does NOT subtract the OS system handle; mirrored.)
3. **OS system handle (handle 0, 24 pages) created at EMS init**
   (`EMM_AllocateSystemHandle(24)`, ems.cpp:1481). Never freed (ems.cpp:438).
   This makes AH=4B base count = 1 and the AH=4D array carry handle 0 with 24
   pages (24+3+5 = 0x20 sum). User handles now start at index 1 (ems.cpp:273).
4. **AH=4B/4C/4D implemented** (ems.cpp:813/818/823/493): handle count over all
   active handles; pages for one handle; the {handle:u16,pages:u16} array to
   ES:DI with BX = entry count.
5. **AH=4E implemented** (ems.cpp:826): AL=03 array-size (16 bytes = 4 phys ×
   {handle,page}), AL=00 save to ES:DI, AL=01 restore from DS:SI, AL=02
   save+restore. Frame map serialized as {handle,page} per slot (NULL=0xFFFF).
6. **AH=47/48 now real per-handle save/restore** (were no-op accepts):
   ems.cpp:448/477, with EMM_PAGE_MAP_SAVED (0x8D) / EMM_NO_SAVED (0x8E) errors.
7. **AH=43 zero-page rejection (0x89)** + free-count check vs REPORTED_PAGES;
   **AH=45 refuses handle 0** (ems.cpp:266/438).

### Page-frame-segment parity

zdos's `FRAME_SEG = 0xE000` already matched dosbox-x's `EMM_PAGEFRAME 0xE000`
(ems.cpp:26) — EMSINFO's `frame=E000` golden passes with no change.

### Status

Full corpus now **16 programs** (12 prior + 4 EMS), all PASSING in
`zig build test-oracle` (exit 0). Full `zig build test` green (exit 0).
No regressions. The EMS MMIO page-frame device (`src/dos/ems.zig`,
bus-registered in `src/machine/machine.zig`) was the only module touched on the
EMS side — no `src/bus/` edit was needed (the bus side is an ordinary MMIO
device whose handler is owned by the EMS manager).

### Next uncovered DOS area

Highest-value remaining gap (per `dos-coverage-gaps.md` Tier 1): **INT 2Fh
AX=4300/4310 (XMS install-check + entry point)** — XMS itself is a deliberate
DEFER, but the probe must answer "not installed" (AL≠0x80) cleanly so XMS-aware
programs fall back to EMS/conventional, rather than hitting the structural
`unsupported` stop. After that, **AH=34 InDOS / the SDA structure** (Tier 2) and
**EMS LIM 4.0 AH=50/57** (multi-page map / region move) if a trace needs them.
