# zdos DOS-layer coverage audit — CURRENT (post-band-18, corpus 40)

**Scope:** DOS API only (INT 21h, INT 2Fh, EMS INT 67h, mouse INT 33h, XMS,
DOS-installed INTs 20/22/23/24/27/28, DOS character devices, EXEC/loader, DOS
data structures). **NOT** hardware I/O (BIOS video/disk/kbd, PIC/PIT, VGA, sound)
— that is the next phase and is only noted where it intersects.

**Status of this document.** This REPLACES the earlier plan-vs-staging audit,
which was written before the oracle work and is now stale (it listed dozens of
items as gaps that are now IMPLEMENTED and oracle-verified). This audit reflects
the actual `src/dos/*.zig` dispatch surface as of the 18 oracle bands and the
40-program byte-for-byte corpus (`zig build test-oracle` green, exit 0).

**Method.** Read the real dispatch switches: `int21.zig service()` (INT 21h),
`int21.zig handle2f()` (INT 2Fh), `ems.zig service()` (INT 67h), `int33.zig`
(mouse), `dos.zig dispatch()` (installed INTs), `loader.zig exec()` (EXEC). Each
AH/AX marked against dosbox-x:
- **IMPL** — implemented in zdos today (and, where noted, oracle-verified).
- **DEFER** — deliberate, justified boundary (not an oversight).
- **MISSING-material** — a well-behaved real-mode program (or BaK) would plausibly
  call it and would currently get `unsupported` or wrong behavior.
- **MISSING-irrelevant** — in dosbox-x, not in zdos, not reached by the target
  class.

dosbox-x refs are `references/dosbox-x/src/dos/...` `file:line` (line numbers are
the dosbox-x tree, which differs from the dosbox-staging numbers in the old doc).

---

## 0. Verdict

**The DOS API surface is solid for the BaK real-mode target and ready for the I/O
phase.** Every INT 21h / INT 67h call a Borland/MSC-CRT-built real-mode game makes
at startup and during normal file / memory / EMS / process / directory operation
is implemented and proven against dosbox-x. The remaining gaps are either
deliberate deferrals with faithful "not installed" answers (XMS), or functions no
member of the target class reaches (COM/LPT char I/O, FAT-geometry probes, DBCS /
code-page / LFN). **No MISSING-material gap remains for BaK.** The handful of
MISSING items below are all MISSING-irrelevant or Tier-3 niche.

The one structural note that carries into the I/O phase (not a DOS-API gap):
blocking console input (AH=01/07/08/0A) currently reads from a *scripted*
deterministic stdin seam and does not pump an INT 28h idle loop, because there is
no live keyboard yet. When the I/O phase adds a real keyboard, the blocking-input
services must drive the deterministic event loop (advance the scheduler / fire
INT 28h) instead of busy-waiting. Flagged for that phase — see §3.1.

---

## 1. The complete DOS API surface

### 1.1 INT 21h — every AH (dosbox-x `dos.cpp` `DOS_21Handler`)

| AH | Description | Status | Where in zdos / note |
|----|-------------|--------|----------------------|
| 00 | Terminate program | **IMPL** | int21.zig:32 → `dos.terminate` |
| 01 | Read char STDIN, echo, break-checked | **IMPL** (oracle: GETCH/READLINE) | int21.zig:96 |
| 02 | Write char STDOUT | **IMPL** | int21.zig:63 |
| 03 | Read char STDAUX | **MISSING-irrelevant** | → unsupported; BaK has no COM char I/O. dos.cpp:1147 |
| 04 | Write char STDAUX | **MISSING-irrelevant** | → unsupported. dos.cpp:1158 |
| 05 | Write char PRINTER | **MISSING-irrelevant** | → unsupported. dos.cpp:1170 |
| 06 | Direct console I/O | **IMPL** (oracle: GETCH) | int21.zig:66 (DL=0xFF input w/ ZF) |
| 07 | Char input, no echo, not break-checked | **IMPL** (oracle: GETCH) | int21.zig:83 |
| 08 | Char input, no echo, break-checked | **IMPL** (oracle: CTRLC/GETCH) | int21.zig:88 |
| 09 | Write `$`-string STDOUT | **IMPL** | int21.zig:95 `printString` |
| 0A | Buffered line input | **IMPL** (oracle: READLINE) | int21.zig:104 `bufferedInput` |
| 0B | Get STDIN status | **IMPL** (oracle: STDSTAT) | int21.zig:105 |
| 0C | Flush + read STDIN (dispatch AL) | **IMPL** (oracle: STDSTAT) | int21.zig:108 `flushAndRead` |
| 0D | Disk reset | **MISSING-irrelevant** | → unsupported (AL=0/CF clear; a faithful flush no-op). Trivial if ever needed. |
| 0E | Select default drive → AL=count | **IMPL** | int21.zig:140 |
| 0F–17 | FCB open/close/find/seqIO/create/rename | **IMPL** (oracle: FCBIO) | int21.zig:48-56 (fcb.zig) |
| 18 | NULL (CP/M compat) | **IMPL (benign)** | → unsupported = AL=0/CF clear, matching dosbox `goto default_fallthrough`. dos.cpp:1441 |
| 19 | Get current default drive | **IMPL** | int21.zig:139 |
| 1A | Set DTA = DS:DX | **IMPL** | int21.zig:111 |
| 1B | Get alloc info, default drive | **MISSING-irrelevant** | → unsupported; FAT geometry, CRTs don't need it. dos.cpp:1450 |
| 1C | Get alloc info, specific drive | **MISSING-irrelevant** | as 1B. dos.cpp:1455 |
| 1D/1E/20 | NULL (CP/M compat) | **IMPL (benign)** | default arm = AL=0/CF clear, matching dosbox. |
| 1F | Get DPB, default drive | **MISSING-irrelevant** | → unsupported; no DPB chain (see §3.4). |
| 21–24 | FCB random IO / setrandom / filesize | **IMPL** (oracle: FCBIO) | int21.zig:57-60 |
| 25 | Set interrupt vector | **IMPL** (oracle: VECTORS/INTHOOK) | int21.zig:125 (writes guest IVT) |
| 26 | Create new PSP | **MISSING-irrelevant** | → unsupported; loaders/rare. EXEC builds child PSPs internally. |
| 27/28 | FCB random block IO | **MISSING-irrelevant** | → unsupported; corpus FCB uses 21/22 single-record (per-record loop covers the same path). |
| 29 | Parse filename into FCB | **IMPL** (oracle: ARGENV) | int21.zig:176 `parseFilename` |
| 2A | Get system date | **IMPL** | int21.zig:119 (deterministic epoch) |
| 2B | Set system date | **IMPL** | int21.zig:121 (AL=0 success) |
| 2C | Get system time | **IMPL** | int21.zig:120 |
| 2D | Set system time | **IMPL** | int21.zig:121 |
| 2E | Set verify flag | **MISSING-irrelevant** | → unsupported; trivial flag, no consumer. |
| 2F | Get DTA → ES:BX | **IMPL** | int21.zig:115 |
| 30 | Get DOS version (5.0) | **IMPL** (oracle: HELLO) | int21.zig:38 |
| 31 | TSR | **DEFER** | int21.zig:45 → unsupported (BaK is not a TSR). |
| 32 | Get DPB, specific drive | **MISSING-irrelevant** | as 1F. |
| 33 | Extended break checking (00/01/02/05/06) | **IMPL** (oracle: INTHOOK) | int21.zig:175 `breakCheck` |
| 34 | Get InDOS flag → ES:BX | **MISSING-irrelevant** | → unsupported; SDA/re-entrancy (see §3.2). Single-process BaK never reads it. |
| 35 | Get interrupt vector | **IMPL** (oracle: VECTORS) | int21.zig:132 |
| 36 | Get free disk space | **IMPL** (oracle: DISKFREE) | int21.zig:181 (deterministic synthetic geometry) |
| 37 | Get/set switch char | **MISSING-irrelevant** | → unsupported. |
| 38 | Get/set country info | **IMPL** (oracle: COUNTRY) | int21.zig:182 (fixed US block, AL=00 + set) |
| 39 | MKDIR | **IMPL** (oracle: MKTREE) | int21.zig:171 |
| 3A | RMDIR | **IMPL** (oracle: MKTREE) | int21.zig:172 |
| 3B | CHDIR (validates) | **IMPL** (oracle: CDTEST) | int21.zig:170 |
| 3C | Create/truncate file | **IMPL** (oracle: FILEIO) | int21.zig:150 |
| 3D | Open existing (device-first, access-mode) | **IMPL** (oracle: FILEIO/OPENEXT) | int21.zig:151 |
| 3E | Close file | **IMPL** | int21.zig:153 |
| 3F | Read file/device | **IMPL** | int21.zig:154 |
| 40 | Write file/device (access-mode enforced) | **IMPL** (oracle: OPENEXT) | int21.zig:155 |
| 41 | Unlink (delete) | **IMPL** | int21.zig:157 |
| 42 | LSEEK (0/1/2) | **IMPL** (oracle: FILEIO) | int21.zig:156 |
| 43 | Get/set file attributes (00/01) | **IMPL** (oracle: FILEATTR) | int21.zig:158 (inode bits + AttrOverride) |
| 44 | IOCTL (AL=00/01/06/07) | **IMPL/partial** (oracle: STDSTAT/GETCH) | int21.zig:160 — see §1.2 |
| 45 | DUP handle | **IMPL** (oracle: HANDLES) | int21.zig:162 |
| 46 | DUP2/FORCEDUP | **IMPL** (oracle: HANDLES) | int21.zig:163 |
| 47 | Get CWD | **IMPL** (oracle: CDTEST) | int21.zig:169 |
| 48 | Allocate memory | **IMPL** (oracle: MALLOC/MEMALLOC) | int21.zig:186 |
| 49 | Free memory | **IMPL** (oracle: MEMALLOC) | int21.zig:187 |
| 4A | Resize memory block | **IMPL** (oracle: MALLOC/MEMALLOC) | int21.zig:188 |
| 4B | EXEC load/execute (AL=00) | **IMPL** (oracle: SPAWN+CHILD) | int21.zig:192 → loader.zig (full INT 22 unwind, child PSP, env, mem-free) |
| 4B | EXEC AL=01 LOAD / AL=03 OVERLAY | **MISSING-irrelevant** | loader.zig:524 → unsupported; BaK direct-loads, child uses AL=00. See §3.3. |
| 4C | Exit with code | **IMPL** | int21.zig:33 |
| 4D | Get return code | **IMPL** (oracle: SPAWN) | int21.zig:34 |
| 4E | Find first | **IMPL** (oracle: DIRLIST/FINDFILE) | int21.zig:167 |
| 4F | Find next | **IMPL** (oracle: FINDFILE) | int21.zig:168 |
| 50 | **Set current PSP** | **IMPL** | int21.zig:146 (`dos.current_psp = BX`) — NOTE: distinct from EMS 67h AH=50 |
| 51 | **Get current PSP** | **IMPL** | int21.zig:147 (co-located with 62) — distinct from EMS 67h AH=51 |
| 52 | Get List of Lists (SysVars) | **IMPL** | int21.zig:178 `sysVars` — real firstMCB anchor; see §3.5 |
| 53 | Translate BPB→DPB | **MISSING-irrelevant** | block-device. |
| 54 | Get verify flag | **MISSING-irrelevant** | pair of 2E. |
| 55 | Create child PSP | **IMPL (folded into EXEC)** | loader.zig buildPsp builds the child PSP + SaveVectors inside AH=4B. The standalone AH=55 entry is → unsupported (no consumer reaches it directly). |
| 56 | Rename file | **IMPL** (oracle: RENFILE/MOVEDIR) | int21.zig:161 |
| 57 | Get/set file date-time | **IMPL** (oracle: FILEDATE) | int21.zig:122 (deterministic SFT-backed; GET *value* is a documented non-oracle boundary) |
| 58 | Get/set alloc strategy (+UMB link) | **IMPL** | int21.zig:189 `allocStrategy` |
| 59 | Get extended error (class/action/locus) | **IMPL** (oracle: DOSERR) | int21.zig:177 `extendedError` |
| 5A | Create temp file | **DEFER** | DOS-generated name not stable across dosbox runs → not oracle-able (band 11). |
| 5B | Create new (exclusive) | **IMPL** (oracle: FILEATTR) | int21.zig:159 → EEXIST(80) |
| 5C | FLOCK (region lock) | **DEFER** | SHARE/locking; BaK single-process. dos.cpp. |
| 5D | Network/server functions | **DEFER** | network; AL=06 SDA-ptr unavailable (no guest SDA, §3.2). |
| 5E/5F | Network/printer/redirector | **DEFER** | not BaK-relevant. |
| 60 | TRUENAME (canonicalize) | **MISSING-irrelevant** | → unsupported; tools/some CRTs. zdos canonicalizes internally in `resolve`. |
| 62 | Get current PSP | **IMPL** | int21.zig:147 |
| 63 | DBCS lead-byte table | **DEFER** | DBCS. |
| 64 | Set device-driver lookahead | **MISSING-irrelevant** | rare. |
| 65 | Get extended country info | **MISSING-irrelevant** | → unsupported; case tables / capitalize. |
| 66 | Get/set global code page | **MISSING-irrelevant** | `chcp`. |
| 67 | Set handle count | **IMPL** (oracle: HANDLES) | int21.zig:164 `setHandleCount` (grows JFT >20) |
| 68/6A | FFLUSH / commit file | **IMPL** (oracle: FFLUSH) | int21.zig:183 `commitFile` |
| 69 | Get/set disk serial | **MISSING-irrelevant** | → unsupported. |
| 6B | NULL | **IMPL (benign)** | default arm. dos.cpp:2999. |
| 6C | Extended open/create | **IMPL** (oracle: OPENEXT) | int21.zig:152 `extendedOpen` (DS:SI name, action arms) |
| 71 | LFN / 4DOS detect | **DEFER** | LFN; → unsupported (AL=0/CF clear "not implemented"). |
| default | Unknown AH → AL=0, CF clear + structural signal | **IMPL** | dos.zig `unsupported` (D11b) |

### 1.2 AH=44 IOCTL subfunctions

| AL | Description | Status |
|----|-------------|--------|
| 00 | Get device info word | **IMPL** (int21.zig:943; device infoWord, file=drive index, bit 7 distinguishes) |
| 01 | Set device info word | **IMPL** (int21.zig:952; accepts, no host effect) |
| 06 | Get input status (0xFF ready / 0x00 EOF) | **IMPL** (int21.zig:959; file EOF-aware) |
| 07 | Get output status (0xFF) | **IMPL** (int21.zig:973) |
| 02/03 | Read/write device control channel | **MISSING-irrelevant** (device-specific) |
| 08 | Block device removable? | **MISSING-irrelevant** (installers; no consumer in class) |
| 09/0B/0D/0E | remote? / retry / generic block / drive map | **MISSING-irrelevant** |

`isatty()` (the prompt's concern) works: the CRT calls AH=44 AL=00 on handle
0/1/2; zdos returns the device infoWord (bit 7 set for an interactive CON, or
0x0000 for a redirected handle, deliberately matching dosbox-x under
`prog < IN > OUT` so the CRT's buffering — and thus output byte order — matches the
golden; see devices.zig `infoWord`). Oracle-verified by GETCH/STDSTAT.

### 1.3 INT 2Fh multiplex (`handle2f`, int21.zig:215)

| AX | Description | Status |
|----|-------------|--------|
| 4300 | XMS install check → AL set to 0x00 (≠0x80 = "no XMS") | **IMPL (faithful not-installed)** (oracle: XMSPROBE) |
| 4310 | XMS get entry point | **IMPL (faithful: registers untouched)** — a correct program never reaches here after a not-installed 4300 |
| default | any other AX → AL=0 ("available / not installed") | **IMPL (faithful default)** |

XMS itself is a deliberate **DEFER** (BaK is plain real-mode + EMS via INT 67h, no
extender). The probe answers correctly so an XMS-aware program falls back to
EMS/conventional. This is the canonical handshake and is oracle-verified
(XMSPROBE, minted with the oracle pinned `xms=false`). Other specific 2Fh probes
(SHARE 1000, ANSI 1A00, SFT-walk 1216, idle 1680, Windows 1607) fall to the
faithful AL=0 default — **MISSING-irrelevant** (no consumer in the target class).

### 1.4 EMS INT 67h (`ems.zig service()`)

| AH | Description | Status |
|----|-------------|--------|
| 40 | Get status | **IMPL** (oracle: EMSINFO) |
| 41 | Get page-frame segment (0xE000) | **IMPL** (oracle: EMSINFO) |
| 42 | Get page count (free/total=0x03A4) | **IMPL** (oracle: EMSINFO) |
| 43 | Allocate handle + pages | **IMPL** (oracle: EMSMAP/EMSCOUNT) |
| 44 | Map expanded page | **IMPL** (oracle: EMSMAP) |
| 45 | Release handle | **IMPL** (oracle: EMSMAP) |
| 46 | Get EMM version (0x40 = LIM 4.0) | **IMPL** (oracle: EMSINFO) |
| 47 | Save page map (per-handle) | **IMPL** (oracle: EMSLIM) |
| 48 | Restore page map (per-handle) | **IMPL** (oracle: EMSLIM) |
| 4B | Get handle count | **IMPL** (oracle: EMSCOUNT/EMSPAGE) |
| 4C | Get pages for one handle | **IMPL** (oracle: EMSCOUNT/EMSPAGE) |
| 4D | Get pages for all handles | **IMPL** (oracle: EMSCOUNT/EMSPAGE) |
| 4E | Save/restore page map (00/01/02/03) | **IMPL** (oracle: EMSSAVE/EMSPAGE) |
| 50 | Map/unmap multiple pages (LIM 4.0, AL=00/01) | **IMPL** (oracle: EMSLIM) |
| 51 | Reallocate pages (grow/shrink) | **IMPL** (oracle: EMSLIM) |
| 53 | Get/set handle name | **IMPL** (oracle: EMSLIM) |
| 54 | Handle directory / search-by-name | **IMPL** (oracle: EMSLIM) |
| 4F | Save/restore partial page map | **MISSING-irrelevant** → unsupported |
| 52 | Get/set handle attributes | **MISSING-irrelevant** → unsupported |
| 57 | Move/exchange memory region | **MISSING-irrelevant** → unsupported (LIM 4.0; no consumer yet) |
| 58/59/5A | mappable-array / hw config / raw pages | **MISSING-irrelevant** → unsupported |
| DE | VCPI | **DEFER** (extender / protected mode, out of scope) |

EMS is now the most complete subsystem — board mode (oracle `xms=false`), LIM 4.0
version, multi-page map, reallocate, named handles, page-map save/restore
re-entrancy — all byte-verified. If a BaK trace later needs AH=57 region-move, it
is the one remaining LIM-4.0 rung.

### 1.5 Mouse INT 33h (`int33.zig`)

Present and wired (`dos.mouse.service`). Functionally exercised by the machine
wiring; full mouse fidelity belongs to the I/O phase (the position/button state is
driven by scripted deterministic input, like CON). Not part of this DOS-API audit's
oracle corpus (the corpus programs are console/file/memory/EMS, no mouse).

### 1.6 Installed INTs (`dos.zig dispatch`)

| INT | zdos default | Note |
|-----|--------------|------|
| 20h | terminate | IMPL |
| 22h | terminate-address | IRET default; **EXEC sets it to the parent resume CS:IP and restores on child terminate** (loader.zig). Full unwind IMPL (oracle: SPAWN). |
| 23h | Ctrl-C | IRET default = CONTINUE; a guest-installed handler runs as real guest code via `runGuestInt(0x23)` (oracle: CTRLC). The RETF-with-CF ABORT return form is a documented out-of-scope boundary (cannot be expressed by a C `interrupt` routine). |
| 24h | critical error | default returns AL=3 (fail); store/retrieve of a guest handler works (AH=25/35). Can't be *triggered* on the VFS (no "drive not ready") — mostly-moot (oracle: INTHOOK stores/reads it). |
| 27h | TSR | → unsupported (deferred). |
| 28h | idle | IRET (determinism-neutral). See §3.1 for the I/O-phase note. |

### 1.7 XMS (full function set) — **DEFER**

The entire XMS entry-point set (AH=00–12, 88–8F) stays deferred. BaK uses EMS,
not XMS. Only the INT 2Fh AX=4300/4310 install probe must answer "not installed",
and it does (§1.3, oracle-verified). A future XMS-extender target would add the
set as a band.

### 1.8 DOS data structures

| Structure | Status | Note |
|-----------|--------|------|
| PSP (256 B, guest RAM) | **IMPL** | psp.zig; JFT/0x34 ptr/INT-vec save/parent/env/cmdtail/FCBs |
| MCB chain ('M'/'Z') | **IMPL** | mcb.zig; largestFree, resize-max, oracle: MEMALLOC/FARHEAP |
| DTA (128 B) | **IMPL** | dta.zig; find + FCB record I/O |
| SFT (host-side) + JFT-in-PSP | **IMPL** | sft.zig {device,file} union; refcount (dup), oracle: HANDLES |
| EXEC ParamBlock | **IMPL** | loader.zig (env/cmdtail/FCB ptrs), oracle: SPAWN |
| List of Lists / SysVars | **IMPL/partial** | int21.zig sysVars; real firstMCB anchor at [LoL-2]; other anchors zeroed (§3.5) |
| SDA (Swappable Data Area) | **MISSING-irrelevant** | host-side fields instead; AH=34/5D-06 unavailable (§3.2) |
| CDS (Current Directory Structure) | **MISSING-irrelevant** | per-drive cwd tracked host-side; AH=47 returns the right string (§3.4) |
| DPB chain | **MISSING-irrelevant** | not built; AH=1F/32 → unsupported (§3.4) |
| Country block | **IMPL (the AH=38 block)** | fixed US, oracle: COUNTRY; the AH=65 case tables are not built |

---

## 2. Ranked remaining gaps

There is **no Tier-1 material gap** for BaK. Everything below is MISSING-irrelevant
to the target class or a deliberate deferral; listed so nothing is missed by
omission.

### Tier 2 — would matter for a *broader* real-program corpus (not BaK)
1. **AH=03/04/05 STDAUX/PRN char I/O** — COM/LPT byte I/O. `dos.cpp:1147/1158/1170`.
   Currently → unsupported. Trivial to wire to the AUX/PRN device objects (which
   exist) if a serial/printer program ever enters the corpus.
2. **AH=5C local file-region locking** — clean lock/unlock once SHARE-mode bits are
   honored. Deferred (BaK single-process).
3. **AH=34 InDOS / a guest-RAM SDA** — re-entrancy/TSR awareness. Deferred (§3.2).
4. **EMS AH=57 region move** — the last LIM-4.0 rung; add if a BaK trace needs it.

### Tier 3 — niche (defer; note existence)
5. AH=1B/1C alloc-info, AH=1F/32 DPB, AH=2E/54 verify, AH=26 new-PSP, AH=37 switchar,
   AH=53 BPB→DPB, AH=60 TRUENAME, AH=64 lookahead, AH=65/66 country tables/codepage,
   AH=69 disk serial, AH=4B AL=01/03 (LOAD/OVERLAY), AH=27/28 FCB random-block.
6. EMS AH=4F/52/58/59/5A; EMS VCPI (DE) — DEFER.
7. XMS full set — DEFER.
8. IOCTL AL=02/03/08/09/0B/0D/0E.
9. INT 2Fh AX=1000/1216/1607/1680/1A00 (SHARE/SFT/Windows/idle/ANSI probes).

---

## 3. Behavioral / structural notes (beyond function presence)

### 3.1 Blocking input + INT 28h idle — carry into the I/O phase `[I/O-phase]`
Blocking char input (AH=01/07/08/0A) reads from a deterministic scripted stdin
seam (devices.zig CON `in_buf`, preloaded from a `.in` sidecar). It does NOT pump
an INT 28h idle loop, because there is no live keyboard yet — EOF on the script is
a deterministic stop. dosbox-x calls `CALLBACK_Idle()` inside its blocking-input
loops so INT 28h fires while waiting. When the I/O phase adds a real keyboard, the
blocking-input services MUST advance the deterministic event loop (fire INT 28h /
let the scheduler run) rather than busy-wait. This is the single DOS↔I/O seam to
honor; it is correct as-is for the scripted-input corpus.

### 3.2 SDA / InDOS flag `[ignorable for BaK]`
zdos keeps InDOS, current DTA/PSP, and the extended-error fields as host-side
fields on the `Dos` ctx, not as a guest-RAM SDA at a fixed seg:off. Consequences:
AH=34 (get InDOS) and AH=5D AL=06 (get SDA ptr) are → unsupported. BaK is a single
process with no TSR, so this is ignorable. For a "solid DOS" that runs arbitrary
re-entrancy-aware code, model the SDA as real guest RAM — a future band.

### 3.3 EXEC unwind — DONE (was the prior `[~]`) `[solid-DOS]`
The earlier audit flagged the INT 22 unwind + child PSP as partial. It is now
**complete and oracle-verified**: AH=4B AL=00 sets INT 22 = the caller resume CS:IP
off the IRET frame, snapshots the parent (CPU + PSP + DTA + INT22), builds the
child PSP with SaveVectors, runs the child NESTED through the deterministic stepper
(child cycles charged through the ledger — no hole), then on child terminate frees
the child's memory, restores the parent, and leaves the exit code in `ret_code` for
AH=4D. Exit-code propagation through EXEC is proven (SPAWN captures CHILD's rc) and
the nested run is determinism-tested (run-twice byte-identical incl. final cycle
count). AL=01 LOAD / AL=03 OVERLAY remain → unsupported (no consumer; flagged
faithfully, not faked).

### 3.4 CDS / DPB chains `[ignorable for BaK]`
Per-drive cwd is tracked host-side; AH=47 returns the correct ASCIIZ path
(oracle: CDTEST). No guest-RAM CDS array or DPB chain is built, so AH=1F/32 and a
program that *walks* the CDS/DPB from SysVars find nothing. No member of the target
class does this. Defer to a band only if a BaK trace walks them.

### 3.5 List-of-Lists anchors `[partly done]`
AH=52 returns ES:BX into a real SysVars block; `[ES:BX-2]` is the REAL first-MCB
segment (the arena anchor, so a `mem`-style MCB walk works). The other InfoBlock
anchors (firstDPB, firstFileTable, nulNextDriver, curDirStructure, UMB chain) are
zeroed placeholders — deterministic (CLAUDE.md #5 satisfied: no garbage), but not
real chains. Sufficient for BaK; a program walking those specific anchors would
read a clean zero rather than a structure. Build them out only if a trace needs it.

### 3.6 Access-mode vs read-only attribute `[done]`
AH=3D/6C access mode IS enforced on write (read-only open → ACCESS_DENIED 5,
oracle: OPENEXT). The per-file READ_ONLY *attribute* does NOT block a write-open —
deliberately matching dosbox-x's localDrive (only a read-only MOUNT refuses
writes), oracle-verified by FILEATTR. Full SHARE deny-mode bits (DENYALL/DENYWRITE)
are parsed-for-access only; cross-process deny is deferred with AH=5C.

### 3.7 Deterministic timestamp boundary `[documented]`
AH=57 GET, AH=4E/FCB find date/time, and FCB record date/time are host-mtime-derived
in dosbox-x — non-deterministic and NOT oracle-able. zdos returns the pinned 1993
epoch (or SFT-stored SET value) deterministically; the goldens pin only the
host-independent slice (success/failure, sizes, attrs, content). This is a
documented boundary, not a gap (bands 9/10/14).

---

## 4. What changed vs the prior audit

Items the stale doc listed as GAP that are now **IMPL + oracle-verified**: AH=0A/0B/0C
console input, AH=36 free space, AH=38 country, AH=43 attrs, AH=44 IOCTL 00/01/06/07,
AH=5B exclusive create, AH=6C extended open, AH=67 handle count, AH=68/6A commit,
AH=50/51/62 PSP get/set, AH=52 firstMCB anchor, AH=57 (deterministic), AH=59
class/action/locus, the full FCB API (0F–24), EXEC unwind + child PSP (AH=4B),
INT 2Fh 4300/4310 faithful XMS-not-installed, EMS AH=4B–54 + 50/51, subdir path
resolution, mkdir/rmdir/chdir/getcwd, dup/dup2, rename. The corpus grew from the
doc's "5 programs / harness not wired" to **40 programs, both gates green**.

Items confirmed still **DEFER** (unchanged, justified): XMS, AH=5A temp file, AH=5C
SHARE locking, network (5D–5F), DBCS/codepage/LFN (63/65/66/71), EMS VCPI, TSR (31/27).
