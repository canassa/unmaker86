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
    .{ .exe = "MEMALLOC.EXE" },
    .{ .exe = "FARHEAP.EXE" },
    .{ .exe = "DOSERR.EXE" },
    .{ .exe = "VECTORS.EXE" },
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
