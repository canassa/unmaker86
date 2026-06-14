//! Real-compiler regression: load + run a genuine Borland C++ 3.1 `.EXE` through
//! the full machine and assert the CON output + exit code.
//!
//! `examples/dos-src/HELLO.EXE` is a headless-dosbox-x-built BC 3.1 program whose
//! `main` is `printf("Hello from Borland C++ 3.1 on zdos!\n"); return 0;`. Its
//! `C0*.OBJ` startup runs a chain of DOS services BEFORE `main` (get version,
//! read PSP memtop/env, resize the program block via AH=4A sized against the
//! whole memory it was given, ...). This is the FIRST test that drives a real
//! CRT — the curated-INT-21h + hand-assembled-program suite never exercised the
//! startup's memory-sizing path, so a loader that ignored the EXE header's
//! max_alloc (handing the program only `minsize` paragraphs) silently passed
//! every other test yet made this CRT `abort()` with exit code 3.
//!
//! Determinism: running it twice (two fresh machines) must yield byte-identical
//! CON output AND an identical cycle count.

const std = @import("std");
const build_options = @import("build_options");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

const EXPECTED = "Hello from Borland C++ 3.1 on zdos!\r\n";

fn untilDone(m: *Machine) bool {
    return m.cpu.st.halted or m.dos.terminated;
}

const RunResult = struct { output: []const u8, ret_code: u16, cycles: u64, terminated: bool };

/// Boot a fresh machine, mount the examples dir as C:, load+run HELLO.EXE.
/// `out` receives a copy of the CON output (the device buffer is owned by the
/// machine which the caller frees). Returns the run summary.
fn runHello(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !RunResult {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, build_options.dos_examples_dir, .{ .iterate = true });
    defer dir.close(io);

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

    try m.bootProgram(2, "HELLO.EXE", "");
    _ = m.runUntil(untilDone, 500_000_000);

    try out.appendSlice(alloc, m.dos.dev_table.con.output());
    return .{
        .output = out.items,
        .ret_code = m.dos.ret_code,
        .cycles = m.cpu.st.cycles,
        .terminated = m.dos.terminated,
    };
}

test "Borland C++ 3.1 HELLO.EXE prints its message and exits 0" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const r = try runHello(alloc, &out);
    try std.testing.expect(r.terminated);
    try std.testing.expectEqual(@as(u16, 0), r.ret_code);
    try std.testing.expectEqualStrings(EXPECTED, r.output);
}

test "Borland C++ 3.1 HELLO.EXE is deterministic across two runs" {
    const alloc = std.testing.allocator;
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(alloc);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(alloc);

    const r1 = try runHello(alloc, &out1);
    const r2 = try runHello(alloc, &out2);

    try std.testing.expectEqualStrings(r1.output, r2.output);
    try std.testing.expectEqual(r1.ret_code, r2.ret_code);
    try std.testing.expectEqual(r1.cycles, r2.cycles);
}
