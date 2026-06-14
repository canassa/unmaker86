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
    .{ .exe = "MEMALLOC.EXE" },
    .{ .exe = "FARHEAP.EXE" },
    .{ .exe = "DOSERR.EXE" },
    .{ .exe = "VECTORS.EXE" },
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
