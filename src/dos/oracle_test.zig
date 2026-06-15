//! EXTERNAL-ORACLE conformance: for each corpus `.EXE` under `examples/dos-src/`,
//! load + run it on zdos through the full machine, then assert zdos's CON output
//! + exit code == the committed dosbox-x-minted `<program>.expected` golden.
//!
//! dosbox-x is the TRUTH (a mature, correct DOS). The goldens are MINTED OFFLINE
//! by `tools/oracle.sh` (run once when adding a corpus program) and VENDORED next
//! to the EXE, exactly like the CPU's ProcessorTests conformance vectors. This
//! test runs offline, fast, deterministic — dosbox-x is NOT a test-time
//! dependency. It is SEPARATE from the determinism tests (run-to-N-twice
//! byte-identical): this asks "is zdos's behavior RIGHT?", determinism asks "is
//! it reproducible?".
//!
//! Divergences are EXPECTED and WANTED for some corpus programs (e.g. the
//! subdirectory reader). They are recorded in `plans/dos-oracle-report.md`. A
//! program whose zdos run matches its golden becomes a permanent regression and
//! is listed in `PASSING` below; a known-divergent program is listed in
//! `DIVERGING` with the reason, so the suite stays green while the divergence is
//! the documented deliverable (NOT papered over by tweaking zdos).
//!
//! Golden format (see tools/oracle.sh):
//!     exit_code: <N>\r\n
//!     --- output ---\r\n
//!     <verbatim console bytes the program wrote>

const std = @import("std");
const build_options = @import("build_options");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

/// One corpus program. `args` is the command tail passed to BOTH the oracle
/// (via the `<STEM>.args` sidecar) and zdos here, so the run is apples-to-apples.
const Program = struct {
    exe: []const u8,
    args: []const u8 = "",
};

/// Programs zdos reproduces byte-for-byte vs the dosbox-x golden. These are the
/// permanent regressions.
const PASSING = [_]Program{
    .{ .exe = "HELLO.EXE" },
    .{ .exe = "MALLOC.EXE" },
    .{ .exe = "FILEIO.EXE" },
    .{ .exe = "ARGENV.EXE", .args = "alpha beta gamma" },
    .{ .exe = "SUBDIR.EXE" },
    .{ .exe = "SPRINTF.EXE" },
    .{ .exe = "RENFILE.EXE" },
    .{ .exe = "APPEND.EXE" },
    .{ .exe = "FFLUSH.EXE" },
    .{ .exe = "COUNTRY.EXE" },
    .{ .exe = "DIRLIST.EXE" },
    .{ .exe = "DISKFREE.EXE" },
    .{ .exe = "EMSINFO.EXE" },
    .{ .exe = "EMSMAP.EXE" },
    .{ .exe = "EMSCOUNT.EXE" },
    .{ .exe = "EMSSAVE.EXE" },
    // Deep EMS handle/page-query + page-map save/restore re-entrancy band
    // (band 15): INT 67h AH=4B/4C/4D (handle count, pages-per-handle,
    // all-handle {handle,pages} array) plus AH=4E AL=03/00/01 (page-map size,
    // save, restore). EMSPAGE.EXE allocates two handles (3 + 5 pages), reads
    // every count/page query back, maps two distinct logical pages into two
    // frame slots, writes markers, AH=4E SAVEs the live two-slot map, remaps to
    // OTHER logical pages and overwrites the windows (proving they changed),
    // then AH=4E RESTOREs and confirms the ORIGINAL markers reappear through the
    // frame window — the re-entrancy primitive an EMS-using ISR relies on. Board
    // mode (oracle xms=false -> EMS_BOARD): no OS system handle, so the count is
    // 2 and the handles are 0/1. All printed values are oracle-able (counts,
    // page totals, the mapsize, and the marker bytes read back through mapped
    // pages — content is deterministic given the bump allocator + zero-init
    // backing). Proven deterministic by a triple-mint byte-identical diff. The
    // program creates no files, so the corpus stays byte-identical.
    .{ .exe = "EMSPAGE.EXE" },
    // LIM EMS 4.0 extensions band (band 16): INT 67h AH=50 (map/unmap multiple
    // pages — AL=00 by logical/physical page number AND AL=01 by logical/segment,
    // ems.cpp:1049), AH=51 (reallocate pages — grow + shrink, ems.cpp:1076),
    // AH=47/48 (per-handle save/restore page map — focused coverage), and the
    // AH=53/54 handle-name surface (set/get name, search-by-name, enumerate;
    // ems.cpp:805/766). EMSLIM.EXE allocates two handles (4 + 2 pages), bulk-maps
    // all four of H1's pages into the four frame slots in ONE AH=50 AL=00 call,
    // writes/reads-back a distinct byte per window, AH=47-saves then remaps then
    // AH=48-restores (window byte returns), bulk-UNMAPs two slots via the 0xFFFF
    // sentinel then bulk-maps H2 by SEGMENT (AH=50 AL=01), GROWs H2 2->5 (free
    // pool -3, kept pages still readable) and SHRINKs 5->1 (free pool +4),
    // set/get a handle name ("KRONDOR"), searches for it (returns the handle),
    // and enumerates all names (count). Board mode (oracle xms=false): the first
    // user handle is 1, not 0 — dosbox EMM_AllocateMemory scans from handle 1
    // (ems.cpp:425), handle 0 is the reserved system slot; zdos was fixed to
    // match (search returns found=0001). All printed values are oracle-able
    // (return codes, free-page deltas off the deterministic REPORTED total, the
    // bytes read back through mapped windows, and the program-supplied name);
    // proven deterministic by a triple-mint byte-identical diff. The program
    // creates no files, so the corpus stays byte-identical.
    .{ .exe = "EMSLIM.EXE" },
    .{ .exe = "MEMALLOC.EXE" },
    .{ .exe = "FARHEAP.EXE" },
    .{ .exe = "DOSERR.EXE" },
    .{ .exe = "VECTORS.EXE" },
    // Interrupt vector install/dispatch + Ctrl-Break band (band 17): the
    // "interruptions" surface. INTHOOK.EXE installs a REAL guest ISR (a Borland
    // 'interrupt' function) on the free user vector INT 0x61 via AH=25, then
    // dispatches it with int86 carrying a register frame: the ISR reads the
    // caller's BX/CX and writes their sum into the AX of the pushed frame, which
    // IRET pops back so int86's outregs.x.ax observes it (1000+337=1337, then
    // 40+2=42). This exercises the CORE interrupt path end to end — CD nn ->
    // deliverViaIvt (push FLAGS/CS/IP, jump to the guest-installed CS:IP) -> the
    // guest 'interrupt' routine runs with the caller's regs -> IRET restores the
    // (modified) AX -> back to the caller — not merely IVT memory get/set (which
    // VECTORS.EXE already covers via geninterrupt + a marker). It also round-
    // trips the AH=33 Ctrl-Break flag (AL=00 get / AL=01 set, dos.cpp:1796-1801)
    // and stores+reads-back the INT 24h critical-error vector (AH=25/35) the way
    // a program does at startup (no forced critical error — mostly-moot on the
    // VFS), restoring every vector and the break flag before exit (good DOS
    // citizenship + proves both get/set directions). Only oracle-able values are
    // printed (the computed register results, the boolean round-trip checks, the
    // break flag); the raw handler/vector seg:off is load-dependent so only the
    // read-back == stored equality is asserted. Proven deterministic by a triple-
    // mint byte-identical diff; the program creates no files, so the committed
    // corpus stays byte-identical.
    .{ .exe = "INTHOOK.EXE" },
    // XMS install-probe band (band 8): the canonical XMS install-check handshake
    // via INT 2Fh AX=4300. zdos defers XMS, so the faithful answer is "not
    // installed" (AL != 0x80); the program then falls back to EMS. The golden was
    // minted with the oracle pinned to xms=false (see tools/oracle.sh), matching
    // zdos's deferred-XMS scope.
    .{ .exe = "XMSPROBE.EXE" },
    // Child-process EXEC band: SPAWN.EXE launches CHILD.EXE via INT 21h AH=4B
    // AL=00 (load-and-execute, P_WAIT), captures its return code, and resumes —
    // the full EXEC / DOS_Terminate unwind. The golden interleaves parent+child
    // output and ends with the captured rc. CHILD.EXE lives next to it on C:.
    .{ .exe = "SPAWN.EXE" },
    // Console/stdin INPUT band (scripted stdin via "<STEM>.in"): AH=0A buffered
    // line, AH=01/08 char read+echo, AH=0B status + AH=0C flush/read, CRT
    // scanf/fgets (AH=3F on handle 0). Goldens minted with dosbox-x `< IN.TXT`.
    .{ .exe = "READLINE.EXE" },
    .{ .exe = "GETCH.EXE" },
    .{ .exe = "STDSTAT.EXE" },
    .{ .exe = "CSCANF.EXE" },
    // INT 23h Ctrl-C / Ctrl-Break handler dispatch band (band 18): the DOS
    // break-check callout. CTRLC.EXE installs a custom INT 23h 'interrupt'
    // handler (setvect 0x23) that sets a global flag and returns via IRET
    // (CONTINUE), then reads scripted stdin one char at a time with AH=08
    // (break-checked, dos.cpp:1218). The committed CTRLC.in stream "AB\x03CD\r"
    // carries a Ctrl-C (0x03): when AH=08 reads it, DOS fires the break path
    // (dos.cpp:1222 -> DOS_BreakAction + DOS_BreakTest, dos.cpp:652) which prints
    // "^C\r\n" to STDOUT, sets the caller CF, and INVOKES INT 23h as REAL guest
    // code (CALLBACK_RunRealInt(0x23)). zdos models this with the bridge
    // re-entrancy trampoline runGuestInt(0x23) — the guest handler actually runs
    // on the CPU and sets its flag (proven by VECTORS/INTHOOK that a Borland
    // 'interrupt' handler reaches a C global), then IRETs -> CONTINUE, so AH=08
    // returns AL=3 and the program is NOT aborted. The golden captures the DOS
    // "^C\r\n", the byte codes (incl. the 3), handler-ran=1, count=5,
    // saw-ctrlc=1, and exit_code=0 — all oracle-able and deterministic; the
    // handler/vector seg:off is load-dependent and NOT printed. Proven
    // deterministic by a triple-mint byte-identical diff (incl. exit code). The
    // program creates no files, so the committed corpus stays byte-identical.
    // (The RETF-with-CF ABORT return form is out of band scope — it cannot be
    // expressed by a C 'interrupt' routine; see int21.zig breakTest.)
    .{ .exe = "CTRLC.EXE" },
    // Deep subdirectory / multi-component path band (D8b — the BaK-critical
    // directory-tree area). These create their OWN tree at runtime and tear it
    // down, so reruns are stable with no committed fixture:
    //   MKTREE  — nested AH=39 mkdir + AH=3A rmdir (non-empty rmdir => AX=5) +
    //             create/read a file at SUB1\SUB2\DEEP.TXT (multi-level path).
    //   CDTEST  — per-drive CWD: AH=3B chdir into SUB1\SUB2, AH=47 getcwd, open
    //             a file relative to CWD and via "..\\", chdir ".." and "\\".
    //   DIRSCAN — AH=4E/4F findfirst with a directory-PATH-prefix mask
    //             ("SUB1\\*.*", "SUB1\\SUB2\\*.TXT") incl. the subdir ATTR bit.
    //   MOVEDIR — AH=56 rename moving a file across subdirectories.
    .{ .exe = "MKTREE.EXE" },
    .{ .exe = "CDTEST.EXE" },
    .{ .exe = "DIRSCAN.EXE" },
    .{ .exe = "MOVEDIR.EXE" },
    // File date/time band (band 9): INT 21h AH=57 get/set on an open handle. The
    // golden asserts the DETERMINISTIC slice — the program-computed packed words,
    // SET (AL=01) + GET (AL=00) success on a valid handle, and GET failure
    // (CF/AX=6 -> EBADF) on a closed handle. The GET *return value* is NOT in the
    // golden: dosbox-x derives it from the host mtime (non-deterministic; proven
    // by a double-mint diff — see plans/dos-oracle-report.md band 9). zdos keeps
    // the words in the SFT (epoch-seeded, SET-overwritten) so its own round-trip
    // is deterministic, while the golden only pins the host-independent behavior.
    .{ .exe = "FILEDATE.EXE" },
    // Find-first/find-next glob band (band 10): INT 21h AH=4E/4F directory
    // enumeration EXTENDING DIRLIST/DIRSCAN. FINDFILE.EXE creates a fresh FFDIR
    // subtree at runtime, enumerates with the '?' single-char wildcard
    // ("FILE?.DAT" -> FILE1/2/3 but NOT FILE10), a '*' extension glob, "*.*",
    // and a NO-MATCH glob ("*.XYZ"). It prints name + SIZE + attribute and tears
    // the tree down so the committed corpus stays clean. SIZE is oracle-able
    // (find_size = stat.st_size for fixed-content files); the find DATE/TIME are
    // NOT printed (dosbox-x derives them from host mtime — non-deterministic,
    // drive_local.cpp find_date/find_time = localtime(st_mtime); proven by a
    // triple-mint byte-identical diff — see plans/dos-oracle-report.md band 10).
    .{ .exe = "FINDFILE.EXE" },
    // File ATTRIBUTES + exclusive create band (band 11): INT 21h AH=43 AL=00/01
    // (get/set file attributes) and AH=5B (create-new / exclusive create).
    // FILEATTR.EXE creates a file, reads its attributes (ARCHIVE=0x20), sets
    // READ_ONLY (-> 0x21), confirms a write-open is STILL allowed (dosbox-x's
    // localDrive::FileOpen ignores the per-file read-only bit — only a read-only
    // MOUNT refuses writes; drive_local.cpp:1545), clears READ_ONLY (-> 0x20),
    // exclusive-creates a new name (succeeds), exclusive-creates the SAME name
    // (fails EEXIST/AX=80), gets a missing file's attr (AX=2), and removes every
    // file it created so the corpus stays byte-identical. The attribute bits are
    // inode-derived (oracle-able), NOT timestamps; proven deterministic by a
    // double-mint diff (see plans/dos-oracle-report.md band 11). zdos stores the
    // SET attribute in a per-drive override table (vfs.zig AttrOverride) rather
    // than chmod-ing the host file, so GET reflects SET, write-open is unaffected,
    // and no committed corpus file's permissions are ever touched.
    .{ .exe = "FILEATTR.EXE" },
    // Extended open/create + access-mode band (band 12): INT 21h AH=6C
    // (DOS_OpenFileExtended, dos_files.cpp:1138) and the AH=3D access mode.
    // OPENEXT.EXE drives 6C through every action arm — open-only on a missing
    // file (-> error 2), create-if-missing (taken=2), open-existing (taken=1),
    // replace/truncate (taken=3, size 0 after), fail-if-exists (-> error 80),
    // and the invalid action==0 (-> error 1). It then proves the access mode is
    // honored: open O_RDONLY + attempt a write -> DOSERR_ACCESS_DENIED (5)
    // (dosbox-x's live check is LocalFile::Write, drive_local.cpp:2819; the
    // DTA-layer check in DOS_WriteFile is commented out, dos_files.cpp:858), while
    // a read on the read-only handle succeeds. Only oracle-able values are printed
    // (action codes, error codes, sizes, byte counts — NO timestamps); proven
    // deterministic by a double-mint byte-identical diff. The one created file is
    // removed before exit so the committed corpus stays byte-identical.
    .{ .exe = "OPENEXT.EXE" },
    // File-handle management / Job File Table band (band 13): INT 21h AH=45 dup,
    // AH=46 dup2/force-dup, AH=67 set-handle-count. HANDLES.EXE proves the dup
    // SHARES one SFT entry (DOS_DuplicateEntry): writing/seeking via the dup moves
    // the original's file pointer (one shared position), and closing the original
    // leaves the file ALIVE through the dup (SFT refcount > 1 at close — the
    // structural requirement for dup). dup2 (DOS_ForceDuplicateEntry) redirects a
    // handle onto another's file, closing the target's prior file first (the
    // stdout/stdin redirection primitive). AH=67 (DOS_PSP::SetNumFiles,
    // dos_classes.cpp:428) raises the per-process limit above the default 20 by
    // allocating a larger JFT from the DOS arena and repointing the PSP's 0x34 JFT
    // far pointer, after which 25 simultaneous open handles all succeed. Only
    // oracle-able values are printed (byte counts, positions, content, error codes
    // — NO timestamps); proven deterministic by a triple-mint byte-identical diff.
    // The created files are all removed before exit so the corpus stays clean.
    .{ .exe = "HANDLES.EXE" },
    // FCB (File Control Block) legacy file API band (band 14): INT 21h AH=0F-24,
    // the pre-handle interface. FCBIO.EXE builds a 37-byte FCB in its own memory,
    // points DS:DX at it, and drives AH=16 create + AH=15 sequential write of
    // fixed records, AH=10 close, AH=0F open + AH=14 sequential read-back, AH=24
    // set-random-record + AH=21 random read, AH=22 random write, AH=23 get
    // file-size-in-records, AH=11/12 find-first/next over an FCB '?'-wildcard,
    // AH=17 rename, and AH=13 wildcard delete. The FCB maps onto the SAME SFT/VFS
    // machinery as the handle calls: an FCB-opened file gets a real SFT slot
    // (refcounted) whose index is stored in the FCB's file_handle byte, exactly
    // how dosbox-x passes the SFT index to DOS_ReadFile/WriteFile in fcb mode
    // (dos_files.cpp DOS_FCB*). Record I/O moves bytes through the current DTA
    // (AH=1A) at offset recno*rec_size. Only oracle-able values are printed
    // (record CONTENT, byte/record COUNTS, file SIZE, file-size-in-records, found
    // SIZE, AL return codes); the FCB date/time words (+0x14/+0x16) and the find-
    // result FCB's date/time (+0x17/+0x19) are EXCLUDED — dosbox-x derives them
    // from the host clock (DOS_FCBWrite: DOS_PackDate(dos.date)+BIOS_TIMER, and
    // SaveFindResult's SetResult), which is non-deterministic and not oracle-able.
    // Proven deterministic by a triple-mint byte-identical diff; every created
    // file is removed before exit so the committed corpus stays byte-identical.
    .{ .exe = "FCBIO.EXE" },
    // INT 16h BIOS keyboard ring band (I/O band K1): the keyboard services driven
    // through a PROGRAM-SEEDED BDA ring (plans/io-oracle.md §2.2 — no real key
    // injection; dosbox-x AUTOTYPE is timing-based and was rejected). KBRING.EXE
    // writes known scancode:ascii words directly into the BDA ring (0040:001E...,
    // advancing the tail at 0040:001C exactly as IRQ1 would), then reads them back
    // through INT 16h and prints the (scancode,ascii)/peek/empty/shift results.
    // It exercises AH=01 peek (non-empty + same-word-on-re-peek, then ZF=1 on the
    // drained ring — AX left UNCHANGED on the empty branch, matching dosbox's
    // reg_ax untouched), AH=00 read (drain in order), the ring WRAP across END
    // (seeded near 0x3A so a push wraps to START 0x1E and the dequeue follows),
    // AH=02 shift flags (seed 0040:0017=0x42, read back), and the AH=10/11 enhanced
    // vs AH=00/01 normal split: an enhanced F11 (0x8500, scancode 0x85>0x84) is
    // SKIPPED by AH=00/01 but RETURNED by AH=10/11, and the low-byte==0xF0 enhanced
    // transform (0x84F0 -> 0x8400) is applied by AH=10/11. Semantics matched
    // verbatim to bios_keyboard.cpp INT16_Handler/IsEnhancedKey/get_key/check_key.
    // All printed values are oracle-able (the pairs, booleans, the shift byte, the
    // wrapped head pointer); proven deterministic by a triple-mint byte-identical
    // diff. The program creates no files, so the committed corpus stays byte-
    // identical. The empty-ring blocking seam (AH=00/10 on an empty ring) is the
    // carried determinism seam (dos-coverage-gaps.md §3.1) and is never hit here.
    .{ .exe = "KBRING.EXE" },
    // INT 33h mouse driver DETERMINISTIC state round-trips (I/O band 4,
    // plans/io-oracle.md §4). The faithful, deterministic mouse oracle does NOT
    // drive a live host pointer (dosbox-x's real position depends on host pointer
    // events = non-deterministic, rejected). MOUSE1.EXE PLACES the cursor at known
    // coordinates via AX=0004 (Set Position) and reads it back via AX=0003 (Get
    // Position & Buttons), and sets/reads the other driver state through documented
    // calls — fully deterministic on BOTH dosbox-x and zdos (no host pointer).
    // It sets mode 13h FIRST so the AX=0000 reset reads BDA 0040:0049 and derives
    // the 320x200 defaults, then exercises: reset present/buttons (AX=0xFFFF /
    // MOUSE_BUTTONS=3, mouse.cpp:159) + center (320,100) = ((max_x+1)/2,(max_y+1)/2)
    // (Mouse_Reset:1570) + per-mode range x=0..639 y=0..199 and gran_x=0xfffe
    // (X rounded to EVEN — proven by set_odd 101->100 and clamp_hi 639->638) /
    // gran_y=0xffff (Mouse_AfterNewVideoMode:1422); AX=0004 signed clamp to range
    // (>=max->max, <=min->min, mouse.cpp:1659); AX=0007/0008 define range with the
    // min<->max swap + live-position reclamp (mouse.cpp:1732/1801); AX=001A/001B
    // sensitivity set/get clamped 0..100 (mouse.cpp:2008); AX=0024 version/type
    // (BX=0x0805, CH=0x04 PS/2; mouse.cpp:2074); AX=0021 software reset re-center.
    // AX=000B read-motion-counters is asserted as 0/0: headless dosbox-x is NOT
    // mouse-locked (MOUSE_IsLocked()=false, no SDL capture) and mickeys ONLY
    // accumulate from real host motion (Mouse_CursorMoved, mouse.cpp:898) — AX=0004
    // sets mouse.x directly and never touches mickey_x, so the counters are a
    // deterministic constant 0 (Mouse_Read_Motion_Data, mouse.cpp:1610), NOT a
    // host-dependent field. Show/hide (AX=0001/0002) is the `hidden` SHOW-COUNT
    // (mouse.cpp:1627/1633); the count is not directly readable so it is exercised
    // via show/show/hide-then-reread (position is unaffected -> stable round-trip).
    // All printed values are oracle-able; proven deterministic by a triple-mint
    // byte-identical diff. The program creates no files, so the committed corpus
    // stays byte-identical. zdos's int33.zig was rewritten to match these semantics
    // (the prior stub returned buttons=2, kept no range/granularity, and used a
    // boolean `visible` instead of the show-count).
    .{ .exe = "MOUSE1.EXE" },
};

/// Programs that DIVERGE from the dosbox-x golden today — the documented
/// second-pass worklist (see plans/dos-oracle-report.md). Listed here (not in
/// PASSING) so the suite stays green while the divergence remains the
/// deliverable; each is asserted to STILL diverge (a NOT-equal check) so that if
/// zdos is later fixed, this test fails loudly and the program is promoted to
/// PASSING.
const DIVERGING = [_]Program{};

const Golden = struct { exit_code: u16, output: []const u8 };

/// Parse a minted `.expected` golden into (exit_code, output bytes).
fn parseGolden(bytes: []const u8) !Golden {
    // Line 1: "exit_code: <N>\r\n"
    const prefix = "exit_code: ";
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.BadGolden;
    var i: usize = prefix.len;
    var code: u32 = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1)
        code = code * 10 + (bytes[i] - '0');
    // Skip to end of line.
    const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse return error.BadGolden;
    // Line 2: the "--- output ---\r\n" marker; output is everything after it.
    const marker = "--- output ---";
    const marker_at = std.mem.indexOfPos(u8, bytes, nl + 1, marker) orelse return error.BadGolden;
    const after_marker = std.mem.indexOfScalarPos(u8, bytes, marker_at, '\n') orelse return error.BadGolden;
    return .{ .exit_code = @intCast(code), .output = bytes[after_marker + 1 ..] };
}

const RunResult = struct { output: []u8, ret_code: u16, terminated: bool, cycles: u64 };

/// Boot a fresh machine, mount examples/ as C:, load+run `exe` with `args`,
/// return a heap copy of the CON output + the exit code. Caller frees output.
fn runOnZdos(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, exe: []const u8, args: []const u8) !RunResult {
    const m = try alloc.create(Machine);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    m.dos.mountDrive(2, dir, io);
    m.dos.current_drive = 2;

    try m.bootProgram(2, exe, args);

    // Console-INPUT programs carry a "<STEM>.in" sidecar holding the EXACT bytes
    // dosbox-x fed to handle 0 via `prog < IN.TXT`. Preload them as the machine's
    // scripted stdin so the run is apples-to-apples with the golden. `loadInput`
    // marks the CON seam as REDIRECTED (status always ready, no AH=0C flush —
    // matching a dosbox-x redirected LocalFile).
    if (try readSidecar(alloc, dir, io, exe, ".in")) |in_bytes| {
        defer alloc.free(in_bytes);
        m.dos.dev_table.con.loadInput(in_bytes);
    }

    _ = m.runUntil(struct {
        fn done(mm: *Machine) bool {
            return mm.cpu.st.halted or mm.dos.terminated;
        }
    }.done, 500_000_000);

    const out = try alloc.dupe(u8, m.dos.dev_table.con.output());
    return .{ .output = out, .ret_code = m.dos.ret_code, .terminated = m.dos.terminated, .cycles = m.cpu.st.cycles };
}

/// Read a corpus golden file from the examples dir.
fn readGolden(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, exe: []const u8) ![]u8 {
    return (try readSidecar(alloc, dir, io, exe, ".expected")) orelse error.FileNotFound;
}

/// Read a "<STEM><ext>" sidecar next to the EXE (e.g. ".expected", ".in").
/// Returns null if the file does not exist; caller frees the returned bytes.
fn readSidecar(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, exe: []const u8, ext: []const u8) !?[]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, exe, '.').?;
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ exe[0..dot], ext });
    var f = dir.openFile(io, name, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer f.close(io);
    var rbuf: [64]u8 = undefined;
    var reader = f.reader(io, &rbuf);
    const sz = try reader.getSize();
    const buf = try alloc.alloc(u8, sz);
    try reader.interface.readSliceAll(buf);
    return buf;
}

test "external oracle: PASSING corpus reproduces the dosbox-x goldens" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, build_options.dos_examples_dir, .{ .iterate = true });
    defer dir.close(io);

    for (PASSING) |prog| {
        const golden_bytes = try readGolden(alloc, dir, io, prog.exe);
        defer alloc.free(golden_bytes);
        const golden = try parseGolden(golden_bytes);

        const r = try runOnZdos(alloc, dir, io, prog.exe, prog.args);
        defer alloc.free(r.output);

        std.testing.expect(r.terminated) catch |e| {
            std.debug.print("oracle PASS-program {s}: did not terminate\n", .{prog.exe});
            return e;
        };
        std.testing.expectEqual(golden.exit_code, r.ret_code) catch |e| {
            std.debug.print("oracle PASS-program {s}: exit code zdos={d} golden={d}\n", .{ prog.exe, r.ret_code, golden.exit_code });
            return e;
        };
        std.testing.expectEqualStrings(golden.output, r.output) catch |e| {
            std.debug.print("oracle PASS-program {s}: output divergence\n  golden: {s}\n  zdos:   {s}\n", .{ prog.exe, golden.output, r.output });
            return e;
        };
    }
}

test "external oracle: DIVERGING corpus still diverges (documented worklist)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, build_options.dos_examples_dir, .{ .iterate = true });
    defer dir.close(io);

    for (DIVERGING) |prog| {
        const golden_bytes = try readGolden(alloc, dir, io, prog.exe);
        defer alloc.free(golden_bytes);
        const golden = try parseGolden(golden_bytes);

        const r = try runOnZdos(alloc, dir, io, prog.exe, prog.args);
        defer alloc.free(r.output);

        // A divergence is EITHER an output mismatch OR an exit-code mismatch OR a
        // non-termination. If a "diverging" program starts matching, FAIL so it
        // gets promoted to PASSING (we never silently keep a now-correct program
        // on the divergence list).
        const matches = r.terminated and
            r.ret_code == golden.exit_code and
            std.mem.eql(u8, golden.output, r.output);
        if (matches) {
            std.debug.print("oracle DIVERGING-program {s}: now MATCHES the golden — promote it to PASSING!\n", .{prog.exe});
            return error.DivergenceResolved;
        }
    }
}

// The nested child EXEC (AH=4B) re-enters the machine step loop to run the child
// to termination. That re-entry MUST be cycle-deterministic: two runs of the
// parent-spawns-child program must produce byte-identical output AND an identical
// final cycle ledger (the child's cycles are real work charged through the normal
// ledger — no hole, no host-time leak). This guards the EXEC run-loop integration.
test "EXEC determinism: SPAWN (parent+nested child) run-twice byte-identical" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, build_options.dos_examples_dir, .{ .iterate = true });
    defer dir.close(io);

    const a = try runOnZdos(alloc, dir, io, "SPAWN.EXE", "");
    defer alloc.free(a.output);
    const b = try runOnZdos(alloc, dir, io, "SPAWN.EXE", "");
    defer alloc.free(b.output);

    try std.testing.expect(a.terminated and b.terminated);
    try std.testing.expectEqual(a.ret_code, b.ret_code);
    try std.testing.expectEqualStrings(a.output, b.output);
    try std.testing.expectEqual(a.cycles, b.cycles);
}
