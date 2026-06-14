# zdos DOS-layer coverage gaps — READ-ONLY completeness audit (DOS API surface)

**Scope:** DOS API only (INT 21h, INT 2Fh, EMS INT 67h, XMS, DOS-installed INTs 22/23/24/28/2A/2E,
DOS character devices, EXEC/loader, DOS data structures). **NOT** hardware I/O (BIOS video/disk/kbd,
PIC/PIT, MSCDEX, network redirector, sound) — those are next phase and only noted where they intersect.

**Method (per the prompt):** "covered vs missing" is judged primarily against **our PLAN's scope**
(`plans/bios-dos.md`, D8a/D20 real-CRT baseline) vs **DOSBox-staging's full surface**
(`references/dosbox-staging/src/dos/` + `src/ints/`). `src/dos/` is mid-completion (another agent is
finishing it); where the impl differs from the plan it is noted, but the gap ranking is plan-vs-DOSBox.

**Marks:** **IMPL** = in plan AND visibly in `src/dos/` today · **PLAN** = in-plan, not-yet (checkbox
`[ ]`/`[~]` in bios-dos.md, or scoped but unwritten) · **GAP** = in DOSBox, **not in our re-scoped
plan** (the deliverable's point) · **DEFER** = explicitly out-of-scope in the plan (a deliberate, flagged
deferral — listed so nothing is "missed by omission").

Citations are `dosbox-staging/src/...` `file:line`.

---

## 1. The complete DOS API surface table

### 1.1 INT 21h — every AH (DOSBox `dos.cpp` `DOS_21Handler`)

| AH | Description | DOSBox `dos.cpp` | Status | Notes |
|----|-------------|------------------|--------|-------|
| 00 | Terminate program | 470 | **IMPL** | int21.zig:30 → `dos.terminate` |
| 01 | Read char STDIN, echo | 473 | **IMPL** | int21.zig:71 |
| 02 | Write char STDOUT | 482 | **IMPL** | int21.zig:46 |
| 03 | Read char STDAUX | 490 | **GAP** | AUX device exists; AH=03 read-from-AUX not wired |
| 04 | Write char STDAUX | 501 | **GAP** | AUX write not wired |
| 05 | Write char PRINTER | 513 | **GAP** | PRN device exists; AH=05 not wired |
| 06 | Direct console I/O | 516 | **IMPL** | int21.zig:49 |
| 07 | Char input no echo | 546 | **IMPL** | int21.zig:65 |
| 08 | Char input no echo (break-checked) | 547 | **IMPL** | int21.zig:65 |
| 09 | Write `$`-string STDOUT | 554 | **IMPL** | int21.zig:70 `printString` |
| 0A | Buffered input (DS:DX buf) | 564 | **GAP** | line-input; CRT `gets`/console reads use it — Tier 2 |
| 0B | Get STDIN status | 608 | **GAP** | `kbhit`-style; Tier 2 |
| 0C | Flush buffer + read STDIN (AL=subfn) | 615 | **GAP** | dispatches to 01/06/07/08/0A; Tier 2 |
| 0D | Disk reset | 653 | **GAP** | flush; CRTs call it; trivially a no-op-success — Tier 2 |
| 0E | Select default drive → AL=drive count | 656 | **IMPL** | int21.zig:109 |
| 0F | Open file (FCB) | 660 | **DEFER** | FCB API (plan defers, D11/Out-of-scope) |
| 10 | Close file (FCB) | 668 | **DEFER** | FCB |
| 11 | Find first (FCB) | 676 | **DEFER** | FCB |
| 12 | Find next (FCB) | 681 | **DEFER** | FCB |
| 13 | Delete file (FCB) | 686 | **DEFER** | FCB |
| 14 | Sequential read (FCB) | 691 | **DEFER** | FCB |
| 15 | Sequential write (FCB) | 695 | **DEFER** | FCB |
| 16 | Create/truncate (FCB) | 699 | **DEFER** | FCB |
| 17 | Rename (FCB) | 704 | **DEFER** | FCB |
| 18 | NULL (CP/M compat) → AL=0 | 1603 | **GAP** | falls to default arm (AL=0/CF clear) — OK by accident, see §3 |
| 19 | Get current default drive | 753 | **IMPL** | int21.zig:108 |
| 1A | Set DTA = DS:DX | 756 | **IMPL** | int21.zig:80 |
| 1B | Get alloc info, default drive | 708 | **GAP** | returns FAT geometry (cluster size etc.); Tier 2/3 |
| 1C | Get alloc info, specific drive | 711 | **GAP** | as 1B; Tier 3 |
| 1D | NULL (CP/M) | 1604 | **GAP** | default arm |
| 1E | NULL (CP/M) | 1605 | **GAP** | default arm |
| 1F | Get DPB, default drive | 865 | **GAP** | Drive Parameter Block; some CRTs probe — Tier 3 |
| 20 | NULL (CP/M) | 1606 | **GAP** | default arm |
| 21 | Random read (FCB) | 714 | **DEFER** | FCB |
| 22 | Random write (FCB) | 721 | **DEFER** | FCB |
| 23 | Get file size (FCB) | 728 | **DEFER** | FCB |
| 24 | Set random record (FCB) | 732 | **DEFER** | FCB |
| 25 | Set interrupt vector | 759 | **IMPL** | int21.zig:94 (writes guest IVT) |
| 26 | Create new PSP | 762 | **GAP** | `DOS_NewPSP`; rare for CRTs, used by some loaders — Tier 3 |
| 27 | Random block read (FCB) | 735 | **DEFER** | FCB |
| 28 | Random block write (FCB) | 739 | **DEFER** | FCB |
| 29 | Parse filename into FCB | 743 | **IMPL** | int21.zig:142 `parseFilename` (D20) |
| 2A | Get system date | 766 | **IMPL** | int21.zig:88 (epoch/BDA, D13) |
| 2B | Set system date | 781 | **IMPL** | int21.zig:90 (AL=0 success) |
| 2C | Get system time | 791 | **IMPL** | int21.zig:89 |
| 2D | Set system time | 814 | **IMPL** | int21.zig:90 |
| 2E | Set verify flag | 835 | **GAP** | trivial; store a deterministic flag — Tier 3 |
| 2F | Get DTA → ES:BX | 838 | **IMPL** | int21.zig:84 |
| 30 | Get DOS version | 842 | **IMPL** | int21.zig:36 (5.0 from PSP) |
| 31 | TSR | 860 | **DEFER** | int21.zig:43 → unsupported flag (D11) |
| 32 | Get DPB, specific drive | 866 | **GAP** | as 1F — Tier 3 |
| 33 | Extended break checking | 881 | **IMPL** | int21.zig:141 `breakCheck` (D20); AL=00/01/02/05/06 |
| 34 | Get InDOS flag → ES:BX | 912 | **GAP** | **the InDOS/critical-section flag (part of SDA)** — see §3; Tier 2 |
| 35 | Get interrupt vector | 916 | **IMPL** | int21.zig:101 |
| 36 | Get free disk space | 920 | **GAP** | CRTs/installers call it; needs a deterministic synthetic free-space — Tier 1 |
| 37 | Get/set switch char & availdev | 949 | **GAP** | `SWITCHAR`; some CRTs probe AL=00 — Tier 2 |
| 38 | Get/set country info | 963 | **GAP** | **country info** (date/time/currency format); CRTs call AL=00 at startup — Tier 1/2 |
| 39 | MKDIR | 986 | **PLAN** | int21.zig:137 `mkdir` (D8b, VFS subdir-ops `[ ]`) |
| 3A | RMDIR | 996 | **PLAN** | int21.zig:138 `rmdir` (D8b) |
| 3B | CHDIR | 1007 | **PLAN** | int21.zig:136 `chdir` (D8b — must validate, not no-op) |
| 3C | Create/truncate file | 1017 | **IMPL** | int21.zig:119 |
| 3D | Open existing file | 1028 | **IMPL** | int21.zig:120 (device table before VFS, D17) |
| 3E | Close file | 1039 | **IMPL** | int21.zig:121 |
| 3F | Read file/device | 1050 | **IMPL** | int21.zig:122 |
| 40 | Write file/device | 1067 | **IMPL** | int21.zig:123 |
| 41 | Unlink (delete) | 1082 | **IMPL** | int21.zig:125 |
| 42 | LSEEK | 1091 | **IMPL** | int21.zig:124 (AL=0/1/2) |
| 43 | Get/set file attributes | 1106 | **IMPL** | int21.zig `getSetAttr`; AL=00/01 CLOSED (band 11, FILEATTR) — RO/ARCHIVE bits + vfs AttrOverride |
| 44 | IOCTL | 1138 | **IMPL/partial** | int21.zig:127; AL=00/01/06/07 impl — see §1.2 |
| 45 | DUP handle | 1146 | **IMPL** | int21.zig:129 (D20) |
| 46 | DUP2/FORCEDUP | 1154 | **IMPL** | int21.zig:130 (D20) |
| 47 | Get CWD | 1163 | **PLAN** | int21.zig:135 `getCwd` (D8b) |
| 48 | Allocate memory | 1173 | **IMPL** | int21.zig:147 |
| 49 | Free memory | 1186 | **IMPL** | int21.zig:148 |
| 4A | Resize memory block | 1194 | **IMPL** | int21.zig:149 |
| 4B | EXEC load/execute | 1207 | **PLAN** | int21.zig:153; AL=00 LOADNGO, AL=01 LOAD, AL=03 OVERLAY — see §1.3; EXEC unwind partial |
| 4C | Exit with code | 1219 | **IMPL** | int21.zig:31 |
| 4D | Get return code | 1225 | **IMPL** | int21.zig:32 |
| 4E | Find first | 1232 | **IMPL** | int21.zig:133 |
| 4F | Find next | 1242 | **IMPL** | int21.zig:134 |
| 50 | Set current PSP | 1252 | **IMPL** | int21.zig:115 |
| 51 | Get current PSP | 1443 | **IMPL** | int21.zig:116 (co-located with 62) |
| 52 | Get List of Lists (SysVars) | 1256 | **IMPL/partial** | int21.zig:144 `sysVars` — anchor completeness, see §3 |
| 53 | Translate BPB→DPB | 1267 | **GAP** | block-device; Tier 3 |
| 54 | Get verify flag | 1270 | **GAP** | pair of 2E; Tier 3 |
| 55 | Create child PSP | 1273 | **GAP** | `DOS_ChildPSP`; used by EXEC internally — Tier 2 (needed for full EXEC) |
| 56 | Rename file | 1278 | **IMPL** | int21.zig:128 |
| 57 | Get/set file date-time | 1288 | **IMPL** | int21.zig:91 (deterministic, D13) |
| 58 | Get/set alloc strategy | 1307 | **IMPL** | int21.zig:150 `allocStrategy` (also UMB-link AL=02/03) |
| 59 | Get extended error info | 1337 | **IMPL** | int21.zig:143 `extendedError` (D20) |
| 5A | Create temp file | 1348 | **GAP** | `tmpfile()` in CRTs; Tier 2 — DOS-generated name not proven stable across runs, deferred (band 11) |
| 5B | Create new file (fail if exists) | 1362 | **IMPL** | int21.zig `createNewFile`; exclusive create → EEXIST(80) (band 11, FILEATTR) |
| 5C | FLOCK (region lock/unlock) | 1379 | **GAP** | file locking; SHARE-aware programs — Tier 2/3, see §3 |
| 5D | Network/server functions | 1401 | **DEFER** | network; AL=06 returns SDA ptr (note: SDA leak) |
| 5E | Network/printer functions | 1413 | **DEFER** | network |
| 5F | Network redirection | 1428 | **DEFER** | redirector (note BaK-relevance: none) |
| 60 | Canonicalize filename (TRUENAME) | 1432 | **GAP** | `DOS_Canonicalize`; some CRTs/tools — Tier 2 |
| 61 | UNUSED | 1608 | **GAP** | default arm |
| 62 | Get current PSP | 1444 | **IMPL** | int21.zig:116 |
| 63 | DBCS lead-byte table | 1447 | **DEFER** | DBCS (plan defers) |
| 64 | Set device-driver lookahead | 1455 | **GAP** | rare; default arm — Tier 3 |
| 65 | Get extended country info | 1458 | **GAP** | AL=01..07 table ptrs + AL=20/21/22 (up)case — **see §1.4**; Tier 2 |
| 66 | Get/set global code page | 1537 | **GAP** | `chcp`; Tier 3 |
| 67 | Set handle count | 1546 | **GAP** | raises JFT >20; CRTs with many files — Tier 2 |
| 68 | FFLUSH (commit file) | 1555 | **GAP** | `fflush`/`fsync`; CRTs call it — Tier 1/2 |
| 69 | Get/set disk serial number | 1564 | **GAP** | AL=00/01; Tier 3 |
| 6A | Commit file (= 68) | 1554 | **GAP** | alias of 68 |
| 6B | NULL | 1607 | **GAP** | default arm |
| 6C | Extended open/create | 1585 | **GAP** | `DOS_OpenFileExtended`; newer CRTs/`_open` — Tier 2 |
| 71 | LFN / 4DOS detect | 1596 | **DEFER** | LFN (plan defers; returns AL=0/CF set as "unimplemented") |
| default | Unknown AH → AL=0, CF clear | 1610 | **IMPL** | int21.zig default arm + structural signal (D11b) |

### 1.2 AH=44 IOCTL subfunctions (DOSBox `dos_ioctl.cpp`)

| AL | Description | `dos_ioctl.cpp` | Status |
|----|-------------|-----------------|--------|
| 00 | Get device info word | 41 | **IMPL** (int21.zig:539, device bit 7) |
| 01 | Set device info word | 55 | **IMPL** (int21.zig:548) |
| 02 | Read device control channel | 74 | **GAP** (Tier 3 — device-specific) |
| 03 | Write device control channel | 94 | **GAP** (Tier 3) |
| 06 | Get input status | 114 | **IMPL** (int21.zig:555) |
| 07 | Get output status | 131 | **IMPL** (int21.zig:569) |
| 08 | Block device removable? | 145 | **GAP** (Tier 2 — installers probe removable media) |
| 09 | Block device remote? | 154 | **GAP** (Tier 3 — network) |
| 0B | Set sharing retry count | 165 | **GAP** (Tier 3) |
| 0D | Generic block IOCTL (CL=60 get params, 46/66 vol serial) | 171 | **GAP** (Tier 2 — `GetDeviceParameters` used to size disks) |
| 0E | Get logical drive map | 227 | **GAP** (Tier 3) |

### 1.3 AH=4B EXEC AL subfunctions (DOSBox `dos_execute.cpp`)

| AL | Description | line | Status |
|----|-------------|------|--------|
| 00 | LOADNGO (load and run) | 51 | **PLAN** (loader.zig `load_and_run`) |
| 01 | LOAD (load, don't run) | 52 | **PLAN** (`load_only`) |
| 03 | OVERLAY (load into caller seg, no PSP) | 53 | **PLAN** (`load_overlay`, BaK may use) |
| (full param block, child PSP, env, INT 22 unwind) | | 300+ | **PLAN/partial** (bios-dos.md Phase 4 EXEC item is `[~]`) |

### 1.4 AH=65 extended-country subfunctions (DOSBox `dos.cpp:1458`)

AL=01 get ext country info; AL=02 uppercase table ptr; AL=03 lowercase ptr; AL=04 filename-uppercase
ptr; AL=05 filename-terminator table ptr; AL=06 collating-sequence ptr; AL=07 DBCS table ptr; AL=20
capitalize char; AL=21 capitalize string (CX len); AL=22 capitalize ASCIZ. **All GAP** (none in plan).
Tier 2/3 — some CRTs and `strupr`/locale code touch AL=20/21/22.

### 1.5 INT 2Fh multiplex (DOSBox `dos_misc.cpp` + `xms.cpp` + `ems.cpp`)

| AX | Description | source | Status |
|----|-------------|--------|--------|
| 1000 | INSTALL CHECK (SHARE) → AL=0xFF | dos_misc.cpp:53 | **GAP** (Tier 2 — SHARE probe) |
| 1216 | Get SFT entry address (ES:DI from BX) | dos_misc.cpp:60 | **GAP** (Tier 2 — TSRs/CRTs walk SFT) |
| 1607 | Windows/DOSMGR identify (sub 0000/0001/0003/0004/0005) | dos_misc.cpp:169 | **DEFER** (Windows awareness — Tier 3) |
| 1680 | Release time-slice (idle) | dos_misc.cpp:204 | **GAP** (Tier 2 — idle/yield; AL=0) |
| 1689 | Kernel idle call | dos_misc.cpp:207 | **GAP** (Tier 3) |
| 168F | Close awareness | dos_misc.cpp:208 | **DEFER** (Tier 3) |
| 1A00 | ANSI.SYS install check → AL=0xFF | dos_misc.cpp:211 | **GAP** (Tier 2 — ANSI probe) |
| 4300 | XMS install check → AL=0x80 | xms.cpp:473 | **GAP** (Tier 1 if XMS used — see §4) |
| 4310 | XMS get entry point (ES:BX) | xms.cpp:476 | **GAP** (Tier 1 if XMS used) |
| 4A01/4A02 | HMA query/alloc | dos_misc.cpp:220 | **DEFER** (HMA — Tier 3) |
| default | Unhandled → fall through (faithful "not installed") | dos_misc.cpp:42 | **IMPL** (int21.zig:154 `handle2f`, plan D18 default) |

Our plan: INT 2Fh = "faithful not-installed default; trace-driven probes" (D18, M1). **None of the
specific AX above are implemented**; they currently fall to the default. The XMS 4300/4310 pair is the
notable gap (§4).

### 1.6 EMS INT 67h function set (DOSBox `ints/ems.cpp`)

| AH | Description | `ems.cpp` | Status |
|----|-------------|-----------|--------|
| 40 | Get status | 782 | **IMPL** (ems.zig; oracle band EMSINFO) |
| 41 | Get page-frame segment | 785 | **IMPL** (ems.zig FRAME_SEG=0xE000; EMSINFO) |
| 42 | Get number of pages (total/free) | 789 | **IMPL** (ems.zig; total/free=0x3A4 per dosbox-x; EMSINFO) |
| 43 | Allocate handle + pages | 794 | **IMPL** (ems.zig `allocHandle`; EMSMAP/EMSCOUNT) |
| 44 | Map expanded page | 797 | **IMPL** (ems.zig `mapPage`; EMSMAP) |
| 45 | Release handle + free pages | 800 | **IMPL** (ems.zig `freeHandle`; EMSMAP) |
| 46 | Get EMM version | 803 | **IMPL** (ems.zig; AL=0x40 = LIM 4.0 per dosbox-x; EMSINFO) |
| 47 | Save page map | 807 | **IMPL** (ems.zig `savePageMap`, per-handle) |
| 48 | Restore page map | 810 | **IMPL** (ems.zig `restorePageMap`, per-handle) |
| 4B | Get handle count | 813 | **IMPL** (ems.zig `getHandleCount`; oracle band EMSCOUNT) |
| 4C | Get pages for one handle | 818 | **IMPL** (ems.zig `getPagesForHandle`; EMSCOUNT) |
| 4D | Get pages for all handles | 823 | **IMPL** (ems.zig `getPagesAllHandles`; EMSCOUNT) |
| 4E | Save/restore page map (00/01/02/03) | 826 | **IMPL** (ems.zig `savRestPageMap`; oracle band EMSSAVE) |
| 4F | Save/restore partial page map | 851 | **GAP** (Tier 3) |
| 50 | Map/unmap multiple pages (LIM 4.0) | 854 | **GAP** (Tier 2 — LIM 4.0 programs) |
| 51 | Reallocate pages | 881 | **GAP** (Tier 2) |
| 52 | Get/set handle attributes | 884 | **GAP** (Tier 3) |
| 53 | Get/set handle name | 887 | **GAP** (Tier 3) |
| 54 | Handle directory functions | 890 | **GAP** (Tier 3) |
| 57 | Move/exchange memory region | 893 | **GAP** (Tier 2 — LIM 4.0) |
| 58 | Get mappable physical-address array | 897 | **GAP** (Tier 3) |
| 59 | Get hardware config / raw page count | 910 | **GAP** (Tier 3) |
| 5A | Allocate standard/raw pages | 933 | **GAP** (Tier 3) |
| DE | VCPI functions | 941 | **DEFER** (VCPI = protected-mode/extender; out of scope) |

Plan EMS set = AH=40–48 "curated to BaK" (Phase 7). **AH=4B–5A are all GAP** — see §4 for which a real
expanded-memory program needs.

### 1.7 XMS function set (DOSBox `ints/xms.cpp`) — the XMS entry (after INT 2Fh AX=4310)

| AH | Description | `xms.cpp` | Status |
|----|-------------|-----------|--------|
| 00 | Get XMS version | 508 | **GAP** |
| 01 | Request HMA | 513 | **GAP** |
| 02 | Release HMA | 530 | **GAP** |
| 03 | Global enable A20 | 549 | **GAP** |
| 04 | Global disable A20 | 559 | **GAP** |
| 05 | Local enable A20 | 569 | **GAP** |
| 06 | Local disable A20 | 572 | **GAP** |
| 07 | Query A20 | 575 | **GAP** |
| 08 | Query free extended memory | 579 | **GAP** |
| 09 | Allocate extended memory block | 586 | **GAP** |
| 0A | Free extended memory block | 592 | **GAP** |
| 0B | Move extended memory block | 595 | **GAP** |
| 0C | Lock extended memory block | 599 | **GAP** |
| 0D | Unlock extended memory block | 610 | **GAP** |
| 0E | Get handle information | 613 | **GAP** |
| 0F | Reallocate EMB | 618 | **GAP** |
| 10 | Request UMB | 621 | **GAP** |
| 11 | Release UMB | 662 | **GAP** |
| 12 | Realloc UMB | 675 | **GAP** |
| 88/89/8E/8F | Super-XMS (>64MB, 32-bit) | 680–701 | **DEFER** (Tier 3) |

Plan: **XMS is explicitly DEFER** (bios-dos.md Out-of-scope: "XMS / DPMI / DOS extenders / protected
mode — CPU-deferred; BaK is plain real-mode with EMS via INT 67h"). So the entire XMS surface +
INT 2Fh AX=4300/4310 is a **deliberate deferral**, not an oversight. See §4 for the BaK-relevance call.

### 1.8 DOS data structures (DOSBox `dos.h` / `dos_classes.cpp`)

| Structure | DOSBox | Status | Notes |
|-----------|--------|--------|-------|
| PSP (256 B, guest RAM) | `dos.h:494` DOS_PSP | **IMPL** | psp.zig; JFT/0x34/0x32/FCB/INT-vec fields (D9) |
| MCB chain (16-B headers) | `dos.h:893` DOS_MCB | **IMPL** | mcb.zig; 'M'/'Z' signatures |
| DTA (128 B) | `dos.h:744` DOS_DTA | **IMPL** | dta.zig |
| SFT (host-side) + JFT-in-PSP | `dos.h` / `dos_classes.cpp` | **IMPL** | sft.zig `{device,file}` union (D17) |
| ParamBlock (EXEC) | `dos.h:597` | **PLAN** | loader.zig (EXEC partial) |
| List of Lists / SysVars (InfoBlock) | `dos.h:632` DOS_InfoBlock | **IMPL/partial** | int21.zig sysVars; **anchor completeness, see §3** |
| **SDA (Swappable Data Area)** | `dos.h:928` DOS_SDA | **GAP** | not modeled — see §3 (InDOS, current DTA, error, re-entrancy) |
| **CDS (Current Directory Structure)** | `dos.h` / `drives.*` | **GAP** | per-drive cwd tracked ad-hoc in VFS, not a guest-RAM CDS array — see §3 |
| **DPB (Drive Parameter Block)** | `dos.h` DOS_InfoBlock.firstDPB | **GAP** | AH=1F/32/52-anchor; no DPB chain built — see §3 |
| Country info block | `dos_locale.*` | **GAP** | AH=38/65 (§1.4) |

---

## 2. The gap list (MISSING-FROM-PLAN, ranked)

Format: **what** · **who needs it** · DOSBox file:line · **Tier** (1 = real programs hit it commonly,
2 = BaK-class games, 3 = rare/niche).

### Tier 1 — real programs hit these commonly (fold into corpus/worklist)

1. **AH=36 Get free disk space.** CRT/installer/save-game code calls it before writing.
   `dos.cpp:920`. Needs a deterministic synthetic free-space report (not host `statvfs`).
2. **AH=68/6A FFLUSH (commit file).** Buffered-stdio CRTs (`fflush`, `fclose` flush, `_commit`) issue
   it. `dos.cpp:1555/1554`. Trivial: flush the host file / no-op-success faithfully.
3. **AH=38 Get country info (AL=00).** Borland/MSC CRT locale init reads date/time/currency format at
   startup. `dos.cpp:963`. Needs a fixed deterministic country block (not host locale).
4. **INT 2Fh AX=4300/4310 (XMS install check + entry).** Even programs that *prefer* XMS first call
   4300; a faithful "not installed" (AL≠0x80) is required so they fall back to EMS/conventional.
   `xms.cpp:473/476`. (The plan defers XMS itself; but the **probe must answer faithfully** — currently
   it falls to the 2Fh default, which is arguably OK, but should be verified to return "no XMS" cleanly,
   not the structural-unsupported stop. See §3 / Recommendations.)

### Tier 2 — BaK-class games / fuller real-program support

5. **AH=0A buffered input / AH=0B STDIN status / AH=0C flush+read.** Console-input programs and any
   CRT `gets`/`kbhit` path. `dos.cpp:564/608/615`.
6. **AH=34 Get InDOS flag (SDA).** TSRs and re-entrancy-aware code; also the structural anchor for the
   SDA (§3). `dos.cpp:912`.
7. **AH=5A create temp file / AH=5B create-new (exclusive).** `tmpfile()`, `O_EXCL`/`fopen("x")`.
   `dos.cpp:1348/1362`.
8. **AH=5C FLOCK file region locking.** SHARE-aware multi-handle programs; save-file integrity.
   `dos.cpp:1379`. (See §3 sharing/locking.)
9. **AH=55 Create child PSP.** Needed by a *complete* AH=4B EXEC (DOSBox uses it internally).
   `dos.cpp:1273`. Folds into the EXEC-unwind follow-up already flagged in the plan.
10. **AH=60 TRUENAME (canonicalize path).** Tools/CRTs that resolve a full path. `dos.cpp:1432`.
11. **AH=67 Set handle count.** Programs opening >20 files raise the JFT. `dos.cpp:1546`.
12. **AH=6C Extended open/create.** Newer CRTs / `_open` with sharing+action flags. `dos.cpp:1585`.
13. **AH=44 IOCTL AL=08 (removable?) / AL=0D CL=60 (get device params).** Installers/copy-protection
    size the drive. `dos_ioctl.cpp:145/171`.
14. **INT 2Fh AX=1000 (SHARE check), AX=1A00 (ANSI check), AX=1216 (SFT entry), AX=1680 (yield).**
    Common TSR/idle probes. `dos_misc.cpp:53/211/60/204`.
15. **EMS AH=4B/4C/4D/4E/50/51/57.** A program that actually *uses* expanded memory beyond a single
    static mapping needs page-count queries (4B/4C/4D), page-map save/restore across calls (4E), and —
    if LIM 4.0 — multi-page map (50) and region move (57). `ems.cpp:813–893`. See §4.
16. **AH=03/04/05 STDAUX/PRN char I/O.** Programs that write to COM/LPT. `dos.cpp:490/501/513`.

### Tier 3 — rare/niche (defer; note existence)

17. AH=1B/1C alloc info; AH=1F/32 DPB; AH=2E/54 verify flag; AH=26 new PSP; AH=37 switchar; AH=53 BPB→DPB;
    AH=64 lookahead; AH=65 country tables/capitalize (§1.4); AH=66 code page; AH=69 disk serial; AH=18/1D/1E/20/61/6B NULL.
18. EMS AH=4F/52/53/54/58/59/5A; EMS VCPI (AH=DE) — DEFER (extender).
19. XMS full set — DEFER (plan, §4).
20. IOCTL AL=02/03/09/0B/0E.
21. INT 2Fh AX=1607/168F/4A01/4A02 (Windows/HMA) — DEFER.

---

## 3. Behavioral / structural gaps (beyond function presence)

These are correctness/structure issues that "function is present" does not capture. Flagged
**[solid-DOS]** (needed for a robust DOS that runs arbitrary real programs) vs **[ignorable]** for v1.

1. **SDA — Swappable Data Area `[solid-DOS, but Tier 2 for BaK]`.** `dos.h:928`, `dos_classes.cpp`.
   DOSBox keeps the InDOS flag, current DTA, current PSP, the extended-error fields, and the
   critical-error/re-entrancy state in a guest-RAM SDA at a fixed seg:off (`DOS_SDA_SEG`). zdos keeps
   these as host-side fields on the `Dos` ctx instead. **Consequences:** (a) AH=34 (get InDOS) has no
   real flag to return; (b) AH=5D AL=06 (get SDA ptr) cannot return a real pointer; (c) a TSR/handler
   that reads InDOS to decide re-entrancy sees nothing. For BaK (single process, no TSR) this is
   **largely ignorable**, but for "solid DOS" the SDA should be a real guest-RAM structure so InDOS
   and current-DTA are guest-visible at the documented offsets.

2. **InDOS / critical-section flag `[Tier 2]`.** Tied to the SDA. AH=34 returns ES:BX → InDOS byte;
   without it, re-entrancy-aware code mis-detects.

3. **INT 28h idle `[solid-DOS]`.** Plan installs an INT 28h vector that **IRETs** (dos.zig:200).
   DOSBox calls `CALLBACK_Idle()` inside the blocking char-input loops (`dos.cpp:335/373/411`) so the
   idle INT fires while a program waits for a key. zdos's blocking input (AH=01/07/08/0A) must drive
   the deterministic event loop the same way (it cannot busy-spin without advancing the scheduler).
   **Verify** AH=01/07/08 blocking reads pump the machine step (like `runGuestInt`) — otherwise a
   program waiting for input deadlocks. Flag for the input-blocking design.

4. **INT 24h critical-error contract `[solid-DOS]`.** Plan: default INT 24h returns AL=3 (fail)
   (dos.zig:196). Real DOS: on a disk error DOS *invokes* INT 24h with a documented register frame
   (AX/DI error code, BP:SI → device header) and the handler returns AL=0/1/2/3 (ignore/retry/
   abort/fail) which DOS then acts on. zdos never *triggers* INT 24h (the VFS can't have a "drive not
   ready"), so the contract is mostly moot — but a program that **installs** its own INT 24h handler
   (many CRTs do, to suppress the "Abort/Retry/Fail" prompt) expects its handler to be stored and
   chained. Confirm AH=25/35 on vector 0x24 store/return the guest's handler (they do via the guest
   IVT) and that nothing zdos does bypasses it. **Mostly ignorable for BaK**; flag for completeness.

5. **INT 23h Ctrl-C `[ignorable for BaK]`.** Default IRETs (dos.zig:195). Fine; Ctrl-C is scripted
   input, never host-driven. Only matters if a program installs a handler — same IVT path as 24h.

6. **INT 22h terminate-address + EXEC unwind `[solid-DOS]`.** This is the **partial** flagged in the
   plan (Phase 4 `[~]`, M3). Without the "set INT 22 = caller return CS:IP before child snapshots,
   transfer to saved INT 22 on terminate" path, **AH=4B EXEC of a child cannot return to the parent**.
   The initial BaK load doesn't need it (direct loader call), but any program that spawns a child does.
   Tier 2. Already on the plan's worklist.

7. **Extended-error (AH=59) classes `[solid-DOS]`.** AH=59 is implemented (int21.zig:143) but the plan
   notes it returns the code + class/action/locus bytes. Verify the **class/action/locus** bytes
   (BH/BL/CH) match `dos.cpp:1337` per error, not just AX. CRTs map these to `errno`. Tier 1.5.

8. **FCB API (AH=0F–24, 29) `[ignorable for BaK; flag for solid-DOS]`.** Plan DEFERs the FCB file API.
   **Question the prompt raises — does a BC/TC CRT need it?** Borland/Turbo C and MSC CRT *startup*
   uses **AH=29 (parse filename into FCB)** to build `argv` (already IMPL) and builds the **two FCBs in
   the PSP at 0x5C/0x6C** (loader does this), but does **NOT** use the FCB *file* calls (0F–24) for I/O
   — those use handle calls (3C–42). So **the FCB file API is correctly deferrable**; only AH=29 + the
   PSP FCB fields are needed, and both are in scope. Confirmed safe to defer 0F–24.

9. **PSP field completeness `[solid-DOS]`.** Plan covers INT 20h@0, memtop@2, INT 22/23/24@0A/0E/12,
   parent@16, JFT@18, version bytes, env@2C, max_files@32, JFT-ptr@34, FCBs@5C/6C, cmdtail@80. **Verify
   present:** the **default DTA = PSP:0x80** is set, and offset 0x06 (CP/M FAR-CALL dispatch / available
   bytes in segment) — some CRTs read PSP:0x06 (the `.COM` segment-size word). Minor.

10. **Device-driver chain + attribute words `[Tier 2-3]`.** DOSBox builds a NUL device header chain
    anchored from the List-of-Lists (`nulNextDriver`, `dos.h:632`) with the device attribute word
    (char/block, IOCTL bit, etc.). zdos models devices as host objects (`{device,file}` union) but does
    **not** plant a guest-RAM device-driver chain. A program that walks the device chain from SysVars
    (rare; some TSRs, MSCDEX detection) won't find it. The **EMMXXXX0 device-header probe** (the
    secondary EMS detection path) is the one concrete case — plan flags it PARTIAL (Phase 7). Tier 2.

11. **CDS — Current Directory Structure `[solid-DOS]`.** zdos tracks per-drive cwd inside the VFS
    (host-side). Real DOS keeps a CDS array in guest RAM, anchored from SysVars (`curDirStructure`,
    `dos.h:632`). AH=47 (getcwd) reads it; a program that walks the CDS (rare) won't see it. For solid
    DOS, AH=47/3B should be backed by a guest-visible CDS; for BaK the host-side tracking suffices if
    AH=47 returns the right string. Tier 2.

12. **DPB chain `[Tier 3]`.** AH=1F/32 and the SysVars `firstDPB` anchor expect a Drive Parameter
    Block chain in guest RAM. Not built. A program walking DPBs (disk utilities) fails; BaK doesn't.

13. **List-of-Lists anchor completeness `[solid-DOS]`.** AH=52 is implemented, but DOSBox's InfoBlock
    has many anchors (`firstMCB`@-2, `firstDPB`@0, `firstFileTable`@4, `nulNextDriver`@0x22,
    `curDirStructure`, `fcbTable`, `startOfUMBChain`@0x66, `blockDevices`). Verify the **firstMCB anchor
    is real** (the plan's D20 explicitly requires this — a program that walks the MCB chain from SysVars,
    e.g. a `mem`-style probe or a CRT computing free memory, needs it). The other anchors can be
    deterministic placeholders but should be present and self-consistent. Tier 2.

14. **File-sharing / open-access modes `[Tier 2]`.** AH=3D/6C take sharing-mode bits (DENYALL,
    DENYWRITE, …) in AL bits 4-6. The VFS likely ignores them. SHARE-aware programs and AH=5C locking
    depend on them. BaK is single-process → ignorable for v1; flag for solid DOS.

---

## 4. EMS + XMS coverage check (the user called these out)

### EMS (INT 67h)

- **Plan implements AH=40–48** ("curated to BaK", Phase 7). That covers: status, page-frame seg,
  page count, allocate, **map**, free, version, save/restore page map. **This is enough for a program
  that allocates a handle and maps logical pages into the 4-slot frame** — the classic LIM 3.2 model,
  which is what BaK (1993, ~1 MB EMS) uses.
- **Missing for a fuller expanded-memory program (GAP):**
  - **AH=4B/4C/4D** (get handle count / pages-per-handle / pages-all-handles) — a program that
    *manages* multiple handles or reports EMS usage. `ems.cpp:813–823`. **Tier 2.**
  - **AH=4E (save/restore page map, sub 00–03)** — required by code that maps EMS in an interrupt or
    library call and must restore the caller's mapping. Common in any non-trivial EMS user.
    `ems.cpp:826`. **Tier 2 — likely needed if BaK maps EMS from more than one code path.**
  - **AH=50 (map multiple pages), AH=51 (reallocate), AH=57 (region move)** — LIM **4.0** features. A
    LIM 4.0 program needs 50/57. `ems.cpp:854/881/893`. **Tier 2** (verify BaK's EMS version expectation
    via AH=46; if it expects 4.0, 50/57 matter).
  - **AH=52/53/54/58/59/5A, AH=DE (VCPI)** — Tier 3 / DEFER (VCPI is extender territory, out of scope).
- **Recommendation:** the plan's AH=40–48 is the right floor; **add AH=4B–4E** to the "solid EMS" set
  (cheap, deterministic, and the save/restore map is a real correctness need for re-entrant EMS use).
  Defer 50/51/57 until a BaK trace shows LIM 4.0; flag 50/57 as the next rung if AH=46 reports 4.0.

### XMS (INT 2Fh AX=4300/4310 + the entry-point function set)

- **Plan DEFERs XMS entirely** (Out-of-scope: "BaK is plain real-mode with EMS via INT 67h, no
  extender"). This is a **deliberate, justified deferral** for the BaK target — BaK uses EMS, not XMS.
- **However (the gap to flag):** the **install-check probe INT 2Fh AX=4300** is not the same as using
  XMS. A CRT or game that is XMS-*aware* will call 4300 first; it must get a faithful **"not installed"**
  (AL ≠ 0x80) so it falls back to EMS/conventional. Right now AX=4300 falls to the INT 2Fh default
  (faithful not-installed) — **verify this returns cleanly and does NOT raise the structural
  `unsupported` stop** (which would halt a program that's merely probing). This is the one XMS-related
  item that matters before the next phase. `xms.cpp:473`.
- **The full XMS function set (00–12, 88–8F) stays DEFER** — correct for v1. If a later target uses an
  XMS-based DOS extender or a game that requires XMS, the whole set (esp. 08/09/0A/0B alloc/free/move,
  03/05 A20, 10/11 UMB) is a future rung. Note: A20 (03–07) overlaps the bus `setA20` already present.

---

## 5. Recommendations

### Fold into the corpus / worklist now ("must for solid DOS")

| Gap | Test program that exercises it |
|-----|-------------------------------|
| AH=43 AL=00 existence FIX (already worklist, FILEIO) | `FILEIO.EXE` (plan corpus) |
| AH=36 free disk space | a `.EXE` calling `getdfree()` / `_dos_getdiskfree` before a write |
| AH=68/6A fflush | a `.EXE` doing buffered write + `fflush` + read-back |
| AH=38 country info (AL=00) | any Borland/MSC `.EXE` — CRT startup calls it (add as a trace assertion to existing corpus) |
| AH=59 class/action/locus completeness | a `.EXE` that fails an open then reads `errno`/`_doserrno` |
| INT 2Fh AX=4300 faithful "no XMS" | a `.EXE` that probes XMS then falls back (assert no stop, AL≠0x80) |
| AH=0A/0B/0C console input | a `.EXE` reading a line via `gets`/DOS 0Ah (also exercises INT 28h idle) |
| INT 28h idle pumping on blocking input | the same console-input program run-to-cycle-N twice (determinism) |
| EXEC unwind (INT 22) + AH=55 child PSP | a parent `.EXE` that `system()`/`spawn`s a child and resumes |
| EMS AH=4B–4E | an EMS program that queries handle/page counts + save/restore map |

### Structural items to make "solid DOS" (beyond function presence)

- **Model the SDA as a real guest-RAM structure** (InDOS flag, current DTA, current PSP, extended-error
  fields) so AH=34 and AH=5D AL=06 return real pointers and re-entrancy state is guest-visible.
- **Wire INT 28h idle into the blocking-input loops** (AH=01/07/08/0A must pump the deterministic
  machine step, not busy-wait) — this is both a correctness and a determinism requirement.
- **Complete the List-of-Lists anchors** (real firstMCB — already D20; plus self-consistent
  firstDPB/firstFileTable/nulNextDriver/curDirStructure placeholders) so a program walking SysVars
  doesn't read garbage (violates `CLAUDE.md` #5).
- **Finish the EXEC INT-22 unwind + AH=55** (already flagged `[~]`) — needed for any child process.
- **Honor open-access/sharing-mode bits** in AH=3D/6C (at least parse them) so AH=5C locking and
  SHARE-aware programs behave; full SHARE can stay deferred.

### Explicitly defer (later rung — note, don't build for v1)

- **All of XMS** (00–12, 88–8F) + HMA (INT 2Fh 4A01/4A02) — defer; only the AX=4300 probe must answer.
- **EMS LIM 4.0 (AH=50/51/57) + VCPI (AH=DE)** — defer until a trace shows LIM 4.0 / extender need.
- **FCB file API (AH=0F–24)** — confirmed safe to defer (CRTs use only AH=29 + PSP FCB fields).
- **Network/redirector (AH=5C–5F, INT 2Fh redirector)** — defer; **not BaK-relevant** (BaK loads from
  a local directory, no network paths). Only AH=5C *local* file locking is a (Tier 2) solid-DOS item.
- **DBCS (AH=63/65 DBCS table), code pages (AH=66, AH=65 tables), LFN (AH=71)** — defer (plan already).
- **DPB/CDS as full guest-RAM chains, device-driver chain** — defer beyond the EMMXXXX0 header probe;
  build only if a BaK trace walks them.
- **MSCDEX (INT 2Fh AH=15), Windows awareness (INT 2Fh 1607/168F)** — out of scope / defer.

---

## Appendix — where `src/dos/` is mid-completion (in-flux, per the prompt)

These plan items are `[ ]`/`[~]` in `bios-dos.md` and visibly partial in `src/dos/` today (another agent
is completing them — do not treat as final "missing"):

- ~~**AH=43 AL=00 existence FIX** (FILEIO divergence)~~ — CLOSED (band 11, FILEATTR). `getSetAttr`
  now returns the real RO/ARCHIVE bits (inode-derived + a per-drive `vfs.AttrOverride` table that
  records AH=43 AL=01 SETs without chmod-ing the host file); AH=5B exclusive create also landed.
- **AH=3B/47/39/3A subdir path support** (SUBDIR divergence) — VFS multi-component resolution `[ ]`
  (Phase 5); `chdir`/`getCwd`/`mkdir`/`rmdir` present in int21.zig but the VFS subdir-ops backend `[ ]`.
- **Real env block + canonical argv[0]** (ARGENV divergence) — loader `[ ]` (Phase 6).
- **EXEC param-block parse + INT 22 unwind + child PSP** — `[~]` (Phase 4); initial BaK load via direct
  `loadProgram` is complete, full INT 21h AH=4B child spawn is not.
- **SFT snapshot integrity (content hash + re-open compare on restore)** — `[~]` (Phase 4, D14).
- **EMS** (ems.zig) — AH=40–48 planned; the secondary EMMXXXX0 device-header probe path `[~]` (Phase 7).
- **The oracle harness** (`tools/oracle.sh`, `oracle_test.zig`, `zig build test-oracle`) — `[ ]`
  (Phase 10a) — this is the **real acceptance gate (D21)** and is not yet wired.
