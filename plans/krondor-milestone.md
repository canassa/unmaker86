# Milestone: run the REAL Betrayal at Krondor (`KRONDOR.EXE`) deterministically

The v1 acceptance criterion (`CLAUDE.md` "First target"): launch the shipped 1993 retail
`KRONDOR.EXE` and have it boot far enough to reach a known game screen (intro / main menu),
deterministically — same binary + same inputs ⇒ byte-identical machine state at cycle N, every run.

This is the capstone of the LAMUT/TTM c-recon line: those proved zdos runs BaK's **real VGA driver
overlay** (`Vmcode.ovl`) and asset/movie engine as guest code. This milestone runs the **real game
executable**, not a reconstruction.

> STATUS (Stages 1–3 LANDED): the three boot-memory walls are CLEARED — EMS-driver presence (Stage 1),
> conventional-memory ceiling (Stage 2, a red herring), and the real gate, the EMS backing store
> (Stage 3: `BACKING_PAGES = REPORTED_PAGES = 956`). The game now boots past the memory gate, loads
> resources from `KRONDOR.001` over the VFS, enters VGA mode 13h, and reaches the **intro CREDITS**
> (animating), deterministically — two independent launches → byte-identical framebuffer + CPU at the
> 2-billion-cycle cap. Audio (`ADL.DRV`) degrades to silent without aborting; no 386-opcode (INT-6) hole
> surfaced. The remaining open part (Stage 4) is running PAST the intro to a stable main-menu plateau and
> minting the byte-identical acceptance frame.

---

## Confirmed run profile (don't re-derive)

- **Real-mode MZ.** `KRONDOR.EXE` = plain `MZ`, 453,904 bytes, 1993. No DPMI/extender/PE/LE/NE → no
  protected mode, paging, or FPU. zdos's real-mode 386 + MZ loader (`src/dos/loader.zig`) already
  loads and runs it.
- **`Resource.cfg`:** `soundDrv = ADL.DRV`, `mouseDrv = none`, `memoryDrv = none`, **`minEMS = 1024`**
  (≈1 MB EMS via INT 67h, no EMM386/V86 — `CLAUDE.md`), `minCPU = 386`, `minDOS = 500`, `size=15000`.
- **`MEM.DAT` = `38 b5 03 00` = 0x0003B538 = 243,000** — the minimum-conventional-bytes the
  boot-time memory gate reads (see below). NOT 600000 (that's the fallback when MEM.DAT is absent).
- **DOS 5.0 reported** (`src/dos/dos.zig:29` `DOS_VER_MAJOR=5`, `DOS_VER_MINOR=0`) — satisfies
  `minDOS=500`. INT 21h AH=30h returns 5.0 (`src/dos/int21.zig:38`). No DOS-version hole.
- **EMS is already implemented** (`src/dos/ems.zig`, INT 67h, LIM EMS 4.0, board mode): page-frame
  MMIO at 0xE0000, AH=40/41/42/43/44/45/46/47/48/4B/4C/4D/4E/50/51/53/54, reports total/free
  **0x3BC = 956 pages**. The handler set is complete for this game. The gap is NOT the handlers — see
  hole #1.

---

## Empirical result — how far KRONDOR.EXE gets TODAY

Staged the full game dir UPPERCASE into `/tmp/krondor-probe/` (every file in
`../bak-scratch-area/game/` copied to its uppercase 8.3 name — `KRONDOR.EXE`, `RESOURCE.CFG`,
`KRONDOR.CFG`, `MEM.DAT`, `KRONDOR.001`, `STARTUP.GAM`, `VMCODE.OVL`, `ADL.DRV`, …). Ran both
headless (`--break-cycle 200000000`) and over the HTTP API (`--serve 8099`).

**It boots, then aborts at the EMS memory-sufficiency gate:**

```
You do not have enough memory to run Betrayal at Krondor.
Try using the Make Boot Disk option from INSTALL.

[zdos] stopped: program_terminated; cycle 7777778
  CS:IP f000:10f3  EAX=00034c01 EBX=0000000e ECX=00003782 EDX=00000007
```

- **Deterministic:** two independent headless runs stop at the **identical** cycle **7,777,778** with
  byte-identical CPU state. The probe itself is reproducible.
- The game restored **text mode 3** before printing (the abort path calls `video_shutdown()`), so
  `/api/screen` shows the message in the 80×25 text page and `/api/framebuffer?format=png` returns a
  valid 200 (text-mode frame).
- **Crucially, the "You have %lu bytes free" line did NOT print.** That line is gated on
  `mem.dat == NULL` (`check_memory_or_die`, KRONDOR-flat.c:97206). Its absence proves `MEM.DAT`
  **opened successfully** → the failing condition is **NOT** conventional memory. It is the EMS page
  count.

### Boot sequence reached (grounded in the decomp)
`subsystems_init()` (`../betrayal-at-krondor/KRONDOR-flat.c:51641`) runs, in order:
1. `engine_hardware_init()` — `video_init(8, 0xffff, "vmcode.ovl")` (the LAMUT path, **proven on
   zdos**), `mouse_install()` (INT 33h), `keyboard_install()` (IRQ1/INT 09h), `font_load("GAME.FNT")`,
   archive-buffer far-alloc. zdos clears ALL of this — it reaches the gate at 7.78M cycles, so video
   + mouse + keyboard + font + far-heap all work on the real EXE.
2. `startup_screen_show()`.
3. `ems_init()` (KRONDOR-flat.c:48204) — **fails** (see hole #1) → `g_free_memory_kb = 0`.
4. **`check_memory_or_die()` (KRONDOR-flat.c:97192)** — aborts. ← THE WALL.
5. *(unreached)* `audio_init()` (ADL.DRV), `krondor_cfg_load_settings()`, `load_resource_set_1ec()`.

**Evidence files:** `/tmp/krondor-probe/console_abort.json`, `/tmp/krondor-probe/screen_abort.json`,
`/tmp/krondor-probe/fb_abort.bin` (PNG, text mode).

---

## The ordered hole list

### Hole #1 (the ONLY wall today) — EMS driver-header signature "EMMXXXX0" is missing

**What the guest does** (`ems_detect_driver`, KRONDOR-flat.c:48415, comment at :48409):
1. **INT 21h AH=35h** to fetch the **INT 67h vector** → segment `S` (the EMM driver's resident
   segment).
2. Compares **8 bytes at `S:0x0A`** against `s_ems_driver_signature` = **`"EMMXXXX0"`** (the standard
   DOS character-device-header name field — offset 0x0A of a device header is the 8-byte name).
3. **Only on a match** does it issue the INT 67h status/version/page-count/frame-segment queries
   (AH=40 status→AH=0; AH=46 version→AL>0x31; AH=42 page count→`g_ems_total_pages=BX`≠0; AH=41
   frame-seg→DX, AH=0) and set `_g_ems_present=1`, `g_ems_total_pages`, etc.
4. On signature mismatch → `_g_ems_present = 0` immediately (KRONDOR-flat.c:48448).

Then `ems_init` (KRONDOR-flat.c:48204) checks the detect result; on failure `g_free_memory_kb` stays
**0**. `check_memory_or_die` (KRONDOR-flat.c:97192) tests `((int)local_4 < 0x40)` — i.e.
`g_free_memory_kb < 64` — which is `0 < 64` = **true** → abort.

**What zdos returns (the hole, verified over the API):**
- INT 67h vector = **`F000:1160`** (segment 0xF000 — the bridge callback area;
  `/api/ivt/103` → `{"cs":61440,"ip":4448}`).
- The 16 bytes at **`F000:000A`** (phys 0xF00A) read **all zeros** (`/api/mem?phys=983050&len=16` →
  `00000000000000000000000000000000`). They should be `45 4D 4D 58 58 58 58 30` ("EMMXXXX0").

So the signature check fails, detection bails before ever calling an INT 67h subfunction, EMS reports
0 free pages, and the gate aborts. **zdos's complete INT 67h handler set is never even reached** —
the wall is purely the missing **resident device-driver header**, not the EMS service logic.

> Note: zdos *does* expose `EMMXXXX0` as a named DOS character device (`src/dos/devices.zig:147`,
> resolvable via `open("EMMXXXX0")`). That is the *other* documented EMS probe (open the device by
> name). BaK does NOT use it — it uses the **vector-segment + offset-0x0A signature** probe. The
> name-device presence is necessary-but-insufficient; the header signature is what BaK reads.

**What a faithful fix needs (Stage 1).** Make the segment that the INT 67h vector points into carry a
real EMM device-driver header whose name field (offset 0x0A) = `"EMMXXXX0"`. This is faithful — it is
exactly the resident header a real EMM386/EMS driver installs, and it's the documented EMS-presence
contract. Two faithful options (decide in Stage 1):
- **(A) Stage the 8-byte signature into the BIOS image at `F000:000A`** at POST (the bridge already
  builds a flat BIOS ROM image, `src/bridge/bridge.zig:164` `IMAGE_BASE=0xF0000`, and stages stubs +
  fonts into it). Since INT 67h's vector segment is `0xF000`, writing `"EMMXXXX0"` at image offset
  0x0A makes `[F000:000A]` read the signature. Smallest change; but offset 0x0A of the BIOS segment
  is a slightly arbitrary squat (it works only because the trap stub happens to live in 0xF000).
- **(B) Build a proper resident EMM device-driver header** as a tiny data block (the 18-byte DOS
  device header: next-ptr `FFFF:FFFF`, attribute word `0x8000` = char device, strategy/interrupt
  entry offsets, then the 8-byte name `"EMMXXXX0"` at +0x0A), staged at a known seg `E`, with the
  **INT 67h vector re-pointed to `E:<entry>`** where `<entry>` is the trap stub (or a 2-byte jump to
  it). This is the most faithful (it's literally what loads on real DOS) and decouples the signature
  location from the bridge's stub placement. Recommended.

  Either way the INT 67h **entry point** still resolves to the existing `0xFE 0x38 <id>` trap stub
  that dispatches into `Ems.service` (`src/dos/ems.zig:164`) — no service logic changes.

**Determinism:** the header is fixed comptime data staged at POST; no host clock, no RNG. The INT 67h
trap already charges the synthetic D5 cost (no ledger hole). Snapshot-safe (BIOS image / IVT already
snapshot-covered).

### Holes #2+ — UNVERIFIED until #1 is cleared (downstream of the wall)

These are *predicted* from the decomp boot order but **cannot be observed until Stage 1 lands**. Flag,
do not assume.

- **#2 — `audio_init()` / ADL.DRV (Resource.cfg `soundDrv = ADL.DRV`).** `subsystems_init` calls
  `audio_init()` right after the memory gate (KRONDOR-flat.c:51668). ADL.DRV is the AdLib/OPL2 driver
  (the `*.DRV` are loadable sound-driver overlays run as guest code, like `Vmcode.ovl`). The decomp
  has full driver audits (`../betrayal-at-krondor/audit-adl.md`, `driver.md`). **Open question: does
  `audio_init` ABORT if the OPL2 ports (0x388/0x389) / driver probe fail, or does it degrade
  gracefully to silent?** Sound output is deferrable per `CLAUDE.md`, but if the driver-load or a
  hardware probe **hangs/aborts**, it becomes a BOOT blocker, not a gameplay feature. Must verify at
  probe time: does zdos model ports 0x388/0x389 (OPL2 index/data) at all? (grep `src/devices/` —
  likely not; an unmapped IN returns 0xFF, which may or may not satisfy the driver's status poll.)
  This is the most likely **next** wall.
- **#3 — resource/asset subsystem (`KRONDOR.001` 11 MB archive, `STARTUP.GAM`, `KRONDOR.RMF`).**
  `load_resource_set_1ec()` + `krondor_cfg_load_settings()` open the archive and load the startup
  resource set. This is ordinary buffered file I/O (`bak_fopen`/`cached_file_*`) over the VFS, which
  LAMUT/TTM already exercised — *expected* to work, but the resource manager's seek/read patterns on
  the real 11 MB `.001` (and the `.RMF` resource-map format) are unverified. The case-insensitive VFS
  (`src/dos/vfs.zig`) already handles the `.001`/`.GAM` mixed-case→uppercase staging.
- **#4 — 386 opcode coverage in the larger game code (the INT 6 hazard).** `KRONDOR.EXE` is far more
  code than `Vmcode.ovl`. Any unimplemented 386 opcode surfaces as **#UD / INT 6** (`src/cpu` raises
  a real fault; no default INT 6 IVT handler → wild PC). Size is **unknowable until the run gets past
  the wall** — could be 0 (LAMUT needed none) or several. Mitigation: arm an **INT-6 breakpoint**
  (the controller supports interrupt breakpoints) and run; each stop names a missing opcode → one
  fix. Same iterative method as LAMUT's W3.
- **#5 — intro movie / main-menu screen (the success target).** Past audio + resources, the game runs
  its intro (`INTRO` script / `STARTUP.GAM`) and reaches the main menu. The TTM movie engine path is
  already proven in c-recon; running it from the *real* EXE is the visual acceptance frame.

---

## Staged plan

### Stage 1 — clear the EMS wall: EMS now detects `[x]` (but exposes a NEW conventional-memory wall)
Goal: satisfy the `EMMXXXX0` signature so `ems_detect_driver` succeeds and EMS is present. DONE — the
EMS half of `check_memory_or_die`'s gate (EMS pages ≥ 64) is now satisfied. **The probe revealed the
abort is now `check_memory_or_die`'s SECOND clause (conventional memory), not EMS — see "Hole #2a".**
- [x] **S1.1 — stage the `EMMXXXX0` EMM device-driver header** (chose **option A**, given the actual
      BIOS-image layout). The BIOS image's first paragraph `F000:0000..0x1000` is FREE (the callback
      slot table starts at `F000:1000` = `Bridge.CB_OFFSET`; INT 16h hybrid, fonts, and the VGA
      save-pointer tables all live higher — verified). Since the INT 67h vector segment IS `0xF000`,
      a proper 18-byte DOS char-device header staged at image offset 0x0000 puts `"EMMXXXX0"` at
      `F000:000A` exactly where the probe reads it, leaving the INT 67h vector + trap stub at
      `F000:1160` untouched (EMS dispatch unchanged). The header's interrupt/strategy fields reference
      the live trap-stub offset (0x1160), so the header is self-consistent — faithful, not a squat.
      Files: `src/dos/ems.zig` (`DRIVER_SIGNATURE`/`stageDeviceHeader`, fixed comptime data),
      `src/dos/dos.zig` (non-generic re-export `stageEmsDeviceHeader`), `src/machine/machine.zig`
      (POST staging, after `vga_rom.stage`, before `loadRom`). Added `ems.zig` to the dos determinism
      grep-gate (`src/dos/determinism_test.zig`).
- [x] **S1.2 — unit test** (`src/machine/machine_test.zig` "EMS driver signature: INT 67h vector
      segment + 0x0A reads EMMXXXX0"): after `post()`, asserts the live IVT[0x67] segment is `0xF000`,
      `[seg:0x0A..+8]` reads `"EMMXXXX0"`, the header framing (next-ptr FFFF:FFFF, attribute bit15),
      AND that the vector's entry offset still resolves to the `0xFE 0x38 <id>` EMS trap stub (EMS
      dispatch preserved). Whole suite green: 486/486.
- [x] **S1.3 — probe re-run** (real game UPPERCASE in `/tmp/krondor-stage1/`, over the API on :8131).
      `[F000:000A]` now reads `45 4D 4D 58 58 58 58 30`. With an exec breakpoint on the EMS stub
      (`linear 0xF1160`) confirmed `ems_detect_driver` now runs ALL four queries in order and they
      succeed: **AH=40** (status→0), **AH=41** (frame-seg), **AH=46** (version→AL=0x40 > 0x31),
      **AH=42** (page count→DX=0x3BC=956). EMS is detected (a later **AH=43** allocate-handle is
      reached — only possible if `_g_ems_present=1`). So the EMS-pages clause (`956 < 64` = false)
      PASSES. Evidence: `/tmp/krondor-stage1/evidence/{console_stage1.json,fb_stage1.png}`.
- [x] **S1.4 — Stage-1 gate result:** EMS detection cleared, BUT the game STILL prints "You do not
      have enough memory" and terminates at cycle **7,778,950** (was 7,777,778 — moved +1,172 because
      the signature now matches and detection runs the 4 subfunction queries). Deterministic: two runs
      → identical cycle 7,778,950 + ret_code 1; two framebuffer captures → byte-identical
      (sha256 `de5cb334…`). **The abort is now `check_memory_or_die`'s conventional-memory clause**
      `(alloc_far(0xffffffff,0,0) < MEM.DAT)` — see Hole #2a below.

#### NEXT WALL (Stage-2 handoff) — Hole #2a: conventional-memory arena ceiling

`check_memory_or_die` (KRONDOR-flat.c:97192) aborts if EITHER `(EMS pages < 0x40)` OR
`(largest_free_conventional < local_8)`, where `local_8` = `MEM.DAT` = **243,000 bytes**. The EMS
clause now passes (956 ≥ 64). The abort is therefore the SECOND clause: `alloc_far(0xffffffff,0,0)`
(BaK's "query largest free far-heap block") returns **210,080 bytes < 243,000**.

Root cause (verified by walking the DOS MCB chain over the API): zdos's DOS conventional-memory arena
is capped at segment **0x9000** (`machine.zig:372` `dos.dosInit(br, 0x0800, 0x8800)` — "just below the
UMA", 0x0800..0x9000 ≈ 557 KB). The program's largest free block is bounded by that ceiling: the
terminal free Z-block runs `0x5CB5..0x9000` = `0x334B` paras ≈ **210,096 bytes** — matching the
observed 210,080 exactly. A real DOS 5.0 hands a low-loaded program conventional memory up to ~`0x9FFF`
(640 KB) minus DOS; extending the arena ceiling toward ~`0xA000` would put the largest free block at
`(0xA000-0x5CB5)` ≈ 275 KB > 243,000 → the gate passes. **Stage 2 fix candidate: raise the DOS arena
ceiling from 0x9000 toward the 0xA000 UMA boundary** (faithful — real DOS conventional memory ends at
the 640 KB video-RAM wall, not 0x9000), then re-probe. This is a clean DOS-arena sizing change, NOT a
new subsystem. **Do this BEFORE audio (#2)/resources (#3)** — it is the literal next instruction-level
wall.

> Secondary observation (downstream, not the abort cause): the post-detect **AH=43** (EMS allocate)
> with BX=956 returns AH=0x88 (NOT_ENOUGH_PAGES) because `ems.zig`'s backing store is `BACKING_PAGES`
> = 128 pages (2 MiB) while the program asks for all 956 reported pages at once. This is a *reported-
> vs-backed* page mismatch (zdos reports 0x3BC but backs only 128). It does NOT cause the current
> abort (that AH=43 runs before the `check_memory_or_die` print and the program tolerates the EMS
> failure), but it WILL bite once the conventional-memory wall is cleared and the resource subsystem
> migrates the 11 MB `.001` into EMS. Flag for Stage 2/3: either back the full reported page count or
> reduce the reported total to what is actually backed (the latter risks failing `minEMS=1024`).

### Stage 2 — conventional-memory ceiling raised; the REAL gate is the EMS backing store `[x]`
Goal (as handed off): raise the DOS conventional-memory arena ceiling so the conventional clause of
`check_memory_or_die` passes. DONE — **and the re-probe CORRECTED the prior diagnosis: the conventional
clause was never the gate.**
- [x] **S2-conv.1 — raised the arena ceiling 0x9000 → 0xA000** (`machine.zig` `dosInit(0x0800, 0x9800)`).
      Faithful: real-DOS conventional memory ends at the 640 KiB video-RAM wall (`bus/memmap.zig`
      `conventional_end=0x9FFFF`, UMA/VGA at `0xA0000`); **no EBDA is modeled** (BDA `0040:0013` already
      reports a FULL 640, not 639), so 0xA000 — not 0x9FC0 — is correct. CONSISTENT with INT 12h / BDA
      (both already 640; no change needed there) and with the MCB terminal block. The largest free far
      block is now **275,616 bytes** (`0x434A` paras; MCB chain walked over the API: terminal Z-block
      `0x5CB5..0xA000`), comfortably > `MEM.DAT` (243,000). No test golden was tied to the old 0x9000
      ceiling (the AH=48/49/4A test allocates 0x10 paras, ceiling-agnostic; the BDA/INT-12h tests already
      assert 640) → 486/486 still green, nothing to update.
- [x] **S2-conv.2 — re-probe: the abort is UNCHANGED (same cycle 7,778,950, byte-identical CPU).** This
      proves the conventional clause was NEVER the deciding one. Decompiling `alloc_far(0xffffffff,0,0)`
      (KRONDOR-flat.c:15849): for `size==0xffffffff` it issues the AH=48h call and returns
      `CONCAT22(BX, (int)size<<4)` = `(largest_free_paras << 16) | 0xfff0` — a value ≥ 0x4000_0000, always
      ≫ `MEM.DAT`. So `(uVar1 < local_8)` is always FALSE. **The gating clause is `((int)local_4 < 0x40)`
      where `local_4 = get_free_memory() = g_free_memory_kb`, which stays 0.** (The handoff's 210,080-byte
      figure matched the OLD terminal block size but that clause was a red herring — `alloc_far`'s actual
      return is the huge composite, not the paragraph count.)

#### NEXT WALL (Stage-3 handoff) — Hole #2b: EMS backing-store exhaustion (the REAL memory gate)

`g_free_memory_kb` is set to `g_ems_total_pages` (956) ONLY when the game's EMS bring-up succeeds; on
failure it stays 0 → `0 < 64` → abort. Tracing INT 67h over the API (exec breakpoint on the EMS trap stub
`linear 0xF1160`), the bring-up runs **AH=40 (status→0), AH=41 (frame-seg), AH=46 (version→0x40>0x31),
AH=42 (page count→BX=DX=956), then AH=43 (ALLOCATE HANDLE, BX=956 = all reported pages)**. zdos's
`ems.zig allocHandle` returns **0x88 (NOT_ENOUGH_PAGES)** because `next_page(0)+want(956) > BACKING_PAGES
(128)` — zdos REPORTS `REPORTED_PAGES=0x3BC=956` but BACKS only `BACKING_PAGES=128` (2 MiB). The allocation
fails, the EMS free-list is never built (verified: the ascending free-list `01 00 02 00 03 00 …` is absent
from all of conventional memory), `g_free_memory_kb` stays 0, and `check_memory_or_die` aborts at the
identical 7,778,950.

**Decisive confirmation:** a throwaway `BACKING_PAGES = 956` build makes the abort **VANISH** — the game
boots past the memory gate and runs to a **2-billion-cycle cap with no abort/crash/hang** (CS:IP 566e:10cf,
deep in guest code). So the EMS backing is the single next wall, and very little blocks immediately past it.

**Stage-3 fix candidates (faithful, decide at implementation):**
- **(A) Back the full reported page count.** Set `BACKING_PAGES = REPORTED_PAGES` (956 = ~15 MiB static
  array). Most faithful to the advertised total; the cost is a large fixed `backing` slab in the EMS struct
  (still one up-front allocation, determinism-clean). Verify the slab size is acceptable for the machine
  struct / snapshot size.
- **(B) Report only what is backed.** Lower `REPORTED_PAGES` to `BACKING_PAGES` — but BaK's
  `Resource.cfg minEMS=1024` (≈1 MiB = 64 pages) must still be met, and 128 pages (2 MiB) clears that, so
  this *might* work — EXCEPT the game's AH=43 asks for ALL reported pages, so it would then ask for 128 and
  get a handle, which is fine. Risk: other reported-total consumers. **(A) is the safer faithful choice.**
- Either way the `ems.zig` handler logic is unchanged; only the backing/reported sizing moves.
- **Determinism:** the backing store is zero-init fixed comptime-sized data; no host clock/RNG. No ledger
  hole (the AH=43 trap already charges the synthetic D5 cost).

#### Stage 3 — EMS backing matches the advertisement; the game now reaches the intro CREDITS `[x]`
Goal (the Stage-3 handoff): back every EMS page zdos advertises so BaK's `ems_init` (AH=43 BX=956) succeeds.
DONE — chose **candidate (A): `BACKING_PAGES = REPORTED_PAGES` (956 pages ≈ 15 MiB)**. Rationale: the
invariant is REPORTED == BACKING (never advertise more EMS than you back — the fake CLAUDE.md forbids), and
BaK allocates ALL reported pages at init in one AH=43, so the report total must be fully backed. 956 was the
already-proven-good value (the throwaway 956 build cleared the abort). Candidate (B) (lower REPORTED to 128)
was rejected: it would still satisfy `minEMS=1024` but risks other reported-total consumers and is strictly
less faithful.

- [x] **S3.1 — `BACKING_PAGES = REPORTED_PAGES`** (`src/dos/ems.zig`). The `backing` slab is ONE fixed,
      up-front, `@splat(0)` zero-init inline array in the `Ems` struct (no per-op alloc; deterministic init,
      CLAUDE #5). `Machine` is always heap-allocated (`gpa.create(Machine)`), so the 15 MiB inline slab does
      not touch the stack. `allocHandle` already checks `next_page+want > BACKING_PAGES`, so with 956 backing
      the BX=956 allocation succeeds.
- [x] **S3.2 — snapshot/restore made faithful for the larger slab.** Added `Ems.Snapshot` (handle table +
      frame_map + bump cursor + page counts, by value) and `snapshot`/`restore` + out-of-band
      `backingBytes()`/`restoreBacking()` accessors — the SAME split the bus uses (small POD by value; the
      large slab caller-copied out of band like `bus.ram`/`vga.vram`). Wired `dos_ems` into the machine
      `Snapshot` (the old comment classified `ems` as a deferred snapshot gap — now closed). The 15 MiB slab
      is NEVER inlined into the by-value `Snapshot` struct (would be a per-snapshot 15 MiB copy / stack blow).
      `ems.zig` stays in the dos determinism grep-gate (no float/clock/RNG added).
- [x] **S3.3 — tests.** Two new tests in `src/dos/integration_test.zig`, run via real INT 67h guest code:
      (1) "allocHandle(REPORTED_PAGES) succeeds (report == backing)" — asserts AH=43 BX=956 returns AH=0 +
      a handle, AH=4C reports 956 pages, AH=42 free drops to 0; (2) "EMS backing: out-of-band snapshot/restore
      preserves mapped page contents" — writes a marker through the frame window, snapshots (small state +
      out-of-band backing copy), clobbers both, restores, asserts the marker + bump cursor survive. NO oracle
      golden changed: the EMS oracle programs (EMSINFO/EMSPAGE/EMSLIM) allocate small handles and assert on
      REPORTED-page deltas + the bump-allocator base pages, none of which move when BACKING grows 128→956.
      `dos_mod` re-exports `ems_reported_pages`/`ems_backing_pages` for the report==back assertion.
      Whole suite green: **488/488** (was 486; +2).

#### Stage-3 PROBE RESULT — the game now reaches the intro CREDITS, deterministically
Staged the full game UPPERCASE into `/tmp/krondor-stage3/game/`, ran `--serve 8231 KRONDOR.EXE` (ReleaseFast),
advanced via `POST /api/run-to-cycle` at 10M/50M/100M/300M/1B/2B and captured `GET /api/framebuffer?format=png`.

- **The "You do not have enough memory" abort is GONE.** `/api/console` is EMPTY at every cycle point; the
  machine never terminates (`terminated:false`, `ret_code:0`) — it sails past the old 7,778,950 wall.
- **10M–300M cycles:** VGA **mode 13h** (320×200 indexed, `x-frame-kind:1` — switched out of text mode) showing
  **"Loading Betrayal at Krondor… please wait."** (the `startup_screen_show` loading screen; resource subsystem
  loading the 11 MB `KRONDOR.001` over the VFS — Hole #3, working).
- **1B cycles:** the **"Betrayal at Krondor — CREDITS"** parchment screen (Game Text/Event Design: Neal Hallford,
  Assistant Designer: Tim McClure, Background Paintings: D. Brent Burkett, Artists: Kraft/Murphy/Hippler;
  "Portions © Raymond E. Feist or Midkemia Press", "© 1993 Dynamix, Inc.").
- **2B cycles:** a DIFFERENT credits page (Kevin Barclay, Thyra Boyd, Stan Jackson, Jan Paul Moorhead, Peter
  Lewis, Dennis Williams, John Gilpatrick, Allen Beausoleil) — i.e. the intro is **actively animating/paging**,
  not stuck. CS:IP `566e:10cf` (= the throwaway-956 probe's predicted PC), IFF set, not halted.
- **No NEW abort/hang/crash within 2 billion cycles** — no `audio_init`/ADL.DRV abort (Hole #2 degrades
  gracefully), no resource-load hole (Hole #3 works over the VFS), no INT-6 #UD opcode fault (Hole #4 = 0 so far).
  Audio output is silent (deferrable per CLAUDE.md) but does not block boot.
- **Determinism:** same-cycle double-capture at 2B → byte-identical PNG (sha256 `6f7cdb0c…`). A SECOND
  independent process launch (`--serve 8232`) advanced 0→2B reaches a **byte-identical** 2B framebuffer
  (`6f7cdb0c…`) AND byte-identical CPU state (CS:IP 566e:10cf, EDX=965, all regs equal, cycles=2000000003).
- **Saved PNGs:** `/tmp/krondor-stage3/final/{01_loading_10M.png, 02_loading_100M.png, 03_credits_1B.png,
  04_credits_2B.png}`.

#### NEXT WALL (Stage-4 handoff) — reach a STABLE post-intro plateau (intro → main menu)
The game is animating the intro credits at the 2B cap; it has NOT yet been observed to settle on the main menu.
Stage 4: run further / past the intro credit roll (the intro may be input-gated or run on a fixed timeline) to a
stable post-render plateau, find a fixed cycle N, and capture a byte-identical framebuffer golden (the v1
acceptance frame). No new subsystem is implicated — this is "run longer / drive past the intro," not a new hole.

### Stage 3+ (historical — the 956-backing probe prediction, now CONFIRMED above)
The deep throwaway-956 probe predicted #2 (audio) degrades gracefully and #3 (resources) work over the VFS within
2 billion cycles. Stage 3 (real, landed) CONFIRMS this: the game reaches the intro CREDITS with no audio/resource/
opcode wall. Remaining open item is the main-menu acceptance frame (Stage 4 above).

### (deferred) Stage — audio_init survives (sound driver load) `[ ]`
Goal: `audio_init()` (ADL.DRV) does not hang/abort; boot proceeds to resource load.
- [ ] **S2.1 — probe `audio_init`.** From Stage 1's stop, single-step / breakpoint into `audio_init`;
      determine whether it loads ADL.DRV as guest code, what ports it touches (expect OPL2
      0x388/0x389), and whether it aborts on a failed probe or degrades to silent.
- [ ] **S2.2 — model the minimum OPL2 port surface** *iff* required to BOOT (deterministic register
      file; no audio output needed — silent is fine per `CLAUDE.md`). If `audio_init` degrades
      gracefully on an unmapped probe, no work — document that. **Do not build a synth; only what the
      driver-load needs to not abort.** Cross-ref `../betrayal-at-krondor/audit-adl.md`, `driver.md`.
- [ ] **S2.3 — Stage-2 gate:** boot reaches `krondor_cfg_load_settings()` / `load_resource_set_1ec()`.

### Stage 3 — resource subsystem loads the startup set `[ ]`
Goal: the real `KRONDOR.001` / `STARTUP.GAM` / `KRONDOR.RMF` load without a DOS/VFS hole.
- [ ] **S3.1 — probe the resource manager** opening `KRONDOR.001` + the `.RMF` map; verify the VFS
      seek/read on the 11 MB archive and the far-heap allocs succeed. Fix any DOS hole surfaced.
- [ ] **S3.2 — Stage-3 gate:** `subsystems_init` returns; the game enters its main loop / intro.

### Stage 4 — reach a known screen (the v1 acceptance frame) `[ ]`
Goal: deterministically reach the intro or main menu; capture a framebuffer golden.
- [ ] **S4.1 — run to the main-menu / intro plateau** (resolve INT-6 opcode holes #4 iteratively as
      they appear). Find a fixed post-render cycle N.
- [ ] **S4.2 — capture `GET /api/framebuffer?format=index` at cycle N**; assert byte-identical across
      two runs (determinism) + cycle-neutral capture (purity), exactly like the LAMUT Stage-2 method.
- [ ] **S4.3 — visual oracle (optional cross-check).** If a Spice86/dosbox golden of the same screen
      exists, cross-check the index image (convention-independent, per the LAMUT DAC-scaling lesson).
      Otherwise mint a zdos golden and cross-check once.

---

## Determinism considerations

- **The probe is already deterministic** (two runs → identical 7,777,778-cycle stop + CPU state).
- **EMS is guest-deterministic:** the page-frame backing is zero-init, the handler set charges fixed
  synthetic costs, the header (Stage 1) is fixed comptime data staged at POST. No ledger hole.
- **Nondeterminism risks to watch as the run goes deeper:**
  - **Real-time clock / INT 1Ah / INT 21h AH=2C (get time):** if the game seeds a PRNG or times an
    intro from the clock, zdos must drive it off the cycle counter (already the model — the BIOS tick
    is `f(cycles)`; `LAMUT`'s 3-second hold terminated off the cycle counter, no host clock). The
    `_rand_reset_indices()` call right after the memory gate (KRONDOR-flat.c:51667) seeds the RNG —
    verify it is NOT clock-seeded (if it is, that's a determinism boundary to pin).
  - **Uninitialized memory:** guest RAM is zero-init (`src/machine` re-zeros at boot) — no garbage
    reliance.
  - **EMS frame backing:** zero-init; a program reading an unmapped frame slot gets 0 (deterministic).

---

## What success looks like

- **Stages 1–3 (DONE):** `KRONDOR.EXE` boots **past** the EMS memory gate (no "not enough memory"),
  loads resources, enters VGA mode 13h, and reaches the **intro CREDITS** screen — deterministically
  (two launches → byte-identical 2B-cycle framebuffer + CPU). The three boot-memory walls are cleared.
- **Stage 4 (the v1 goal, REMAINING):** `KRONDOR.EXE` reaches a known STABLE screen (past the intro —
  main menu) and a framebuffer captured at a fixed cycle N is **byte-identical across runs** (the
  reproducibility regression test, `CLAUDE.md` constraint #6).

## Big new subsystems — required to BOOT vs. for gameplay

| Subsystem | Status | Required to BOOT? |
|---|---|---|
| **EMS header signature (#1)** | DONE (Stage 1) | YES — cleared |
| **EMS backing store (#2b)** | DONE (Stage 3: BACKING==REPORTED==956) | YES — cleared (the real memory gate) |
| **OPL2 / ADL.DRV audio (#2)** | not modeled | NO — `audio_init` degrades to silent (verified: 2B cycles, no abort); sound output gameplay-only (deferrable) |
| **Resource manager (#3)** | VFS + far-heap exist | YES — works (loads `KRONDOR.001` over the VFS, verified to the intro CREDITS) |
| **386 opcode holes (#4)** | core is real-#UD-gated | NONE so far (0 INT-6 faults in 2B cycles) |

**Honest scope:** Stages 1–3 cleared every boot-memory wall; the probe confirms audio/resources/opcodes
hold to the intro CREDITS with no further emulator change. Stage 4 (run past the intro to a stable
main-menu plateau + the acceptance frame) is the remaining iterative step.

---

## Decomp references used (all under `../betrayal-at-krondor/`)
- `KRONDOR-flat.c:97192` `check_memory_or_die` — the boot-time memory gate (the wall).
- `KRONDOR-flat.c:48415` `ems_detect_driver` — the INT 21h AH=35h + `[seg]:0x0A` "EMMXXXX0" signature
  probe (hole #1, the exact failing comparison).
- `KRONDOR-flat.c:48204` `ems_init`, `:48239` `get_free_memory`, `:48228` `g_free_memory_kb` —
  the EMS→free-memory plumbing that the gate reads.
- `KRONDOR-flat.c:51641` `subsystems_init` — the boot order (engine_hardware_init → startup_screen →
  ems_init → check_memory_or_die → audio_init → resources).
- `tools/relink-experiments/08-clean-c-chunks/game/sboot.c` — the reconstructed boot/string chunk
  (confirms the exact "You do not have enough memory…" message string).
- `audit-adl.md`, `driver.md` — the ADL.DRV / sound-driver model for Stage 2.
- zdos: `src/dos/ems.zig` (INT 67h handler set), `src/dos/dos.zig:238` (vector wiring),
  `src/bridge/bridge.zig:164` (BIOS-image staging), `src/dos/devices.zig:147` (the EMMXXXX0 name
  device), `plans/lamut-milestone.md` (the proven `engine_hardware_init`/VGA path + the
  index-image-oracle method reused in Stage 4).
