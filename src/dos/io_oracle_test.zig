//! I/O-phase EXTERNAL-ORACLE conformance (band 1): the BINARY device-blob variant
//! of `oracle_test.zig`. For each VGA corpus `.EXE` under `examples/dos-src/`, boot
//! a fresh machine, run it through the full machine (the program sets mode 13h,
//! writes VRAM, programs the DAC, reads it all back, and writes a binary blob to a
//! DOS file via the VFS), then assert the blob zdos produced == the committed
//! dosbox-x-minted `<program>.expected` golden, BYTE-FOR-BYTE.
//!
//! dosbox-x is the TRUTH (pinned `machine=vgaonly`, USER DECISION D1). The goldens
//! are MINTED OFFLINE by `tools/oracle-io.sh` (double-mint determinism-proven) and
//! VENDORED next to the EXE, exactly like the console oracle's `.expected` files
//! and the CPU conformance vectors. This test runs offline — dosbox-x is NOT a
//! test-time dependency (plans/io-oracle.md §1.2/§5).
//!
//! How the blob is captured (no test-only hooks — the cleanest integration,
//! io-oracle.md §5.1): the guest program does `fopen("VGAOUT.BIN","wb")`, which
//! lands in the zdos host-FS VFS like any corpus file. After the run the harness
//! reads `VGAOUT.BIN` back from the host dir and compares it to the golden, then
//! DELETES it (corpus hygiene — the committed corpus stays byte-identical;
//! mirrors oracle.sh's OUT.TXT copy-then-delete discipline). The exit code is
//! checked against the `<STEM>.exitcode` sidecar (binary goldens can't carry an
//! exit-code header line without corrupting the blob).

const std = @import("std");
const build_options = @import("build_options");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

/// The fixed blob filename every I/O-oracle program writes (matches oracle-io.sh).
const BLOB_NAME = "VGAOUT.BIN";

const Program = struct { exe: []const u8 };

/// VGA programs zdos reproduces byte-for-byte vs the dosbox-x binary golden.
const VGA_PASSING = [_]Program{
    // Band V1: set mode 13h, write a deterministic VRAM pattern, program a 256-
    // entry palette via INT 10h AX=1010, read VRAM + DAC (raw ports) + BDA mode
    // back, write the self-describing "VGA1" blob. Proves mode-set + direct VRAM
    // round-trip + DAC set(BIOS)/get(port) round-trip + the BDA mode byte.
    .{ .exe = "VGAINIT.EXE" },
    // Band V1 cont.: exercise the INT 10h SERVICE path specifically — AH=0C put
    // pixel across a span, AH=0D read pixel back, AH=10 AL=12 block DAC set, AH=0F
    // get mode — so the BIOS pixel/block-DAC paths AND the device are both proven.
    .{ .exe = "VGABIOS.EXE" },
    // Band V2: DAC palette / FADE fidelity. Program the whole 256-entry palette via
    // INT 10h AH=10 AL=12, run a BaK-style multi-step fade-to-black (rewriting the
    // entire palette each step), then exercise the raw OUT 0x3C8/0x3C9 path + AL=10
    // single + the 6-bit boundary (write > 63), and read the final palette back BOTH
    // ways (AL=17 get-block AND raw 0x3C7/0x3C9). Proves 6-bit masking, write/read
    // index auto-advance, block set/get, and index-latch read-backs (the "VGA2" blob).
    .{ .exe = "VGAPAL.EXE" },
};

const RunResult = struct { blob: []u8, ret_code: u16, terminated: bool };

/// Boot a fresh machine, mount examples/ as C:, run `exe`, read back the binary
/// blob the program wrote through the VFS, and return it. Caller frees `blob`.
fn runOnZdos(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, exe: []const u8) !RunResult {
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

    try m.bootProgram(2, exe, "");

    _ = m.runUntil(struct {
        fn done(mm: *Machine) bool {
            return mm.cpu.st.halted or mm.dos.terminated;
        }
    }.done, 5_000_000_000);

    // The program wrote VGAOUT.BIN into the mounted host dir via the VFS. Read it
    // back from the host dir, then delete it (corpus hygiene).
    const blob = try readBlob(alloc, dir, io);
    dir.deleteFile(io, BLOB_NAME) catch {};

    return .{ .blob = blob, .ret_code = m.dos.ret_code, .terminated = m.dos.terminated };
}

fn readBlob(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    var f = try dir.openFile(io, BLOB_NAME, .{});
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = f.reader(io, &rbuf);
    const sz = try reader.getSize();
    const buf = try alloc.alloc(u8, sz);
    try reader.interface.readSliceAll(buf);
    return buf;
}

/// Read a "<STEM><ext>" sidecar next to the EXE. Null if absent; caller frees.
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

/// Parse the `<STEM>.exitcode` sidecar (one decimal line) into a u16.
fn parseExitCode(bytes: []const u8) u16 {
    var code: u32 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') break;
        code = code * 10 + (c - '0');
    }
    return @intCast(code);
}

test "I/O oracle: VGA_PASSING corpus reproduces the dosbox-x binary goldens" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, build_options.dos_examples_dir, .{ .iterate = true });
    defer dir.close(io);

    for (VGA_PASSING) |prog| {
        const golden = (try readSidecar(alloc, dir, io, prog.exe, ".expected")) orelse return error.GoldenNotFound;
        defer alloc.free(golden);
        const ec_bytes = (try readSidecar(alloc, dir, io, prog.exe, ".exitcode")) orelse return error.ExitCodeNotFound;
        defer alloc.free(ec_bytes);
        const golden_exit = parseExitCode(ec_bytes);

        const r = try runOnZdos(alloc, dir, io, prog.exe);
        defer alloc.free(r.blob);

        std.testing.expect(r.terminated) catch |e| {
            std.debug.print("io-oracle {s}: did not terminate\n", .{prog.exe});
            return e;
        };
        std.testing.expectEqual(golden_exit, r.ret_code) catch |e| {
            std.debug.print("io-oracle {s}: exit code zdos={d} golden={d}\n", .{ prog.exe, r.ret_code, golden_exit });
            return e;
        };
        std.testing.expectEqual(golden.len, r.blob.len) catch |e| {
            std.debug.print("io-oracle {s}: blob length zdos={d} golden={d}\n", .{ prog.exe, r.blob.len, golden.len });
            return e;
        };
        std.testing.expectEqualSlices(u8, golden, r.blob) catch |e| {
            // Find the first differing byte for a useful failure message.
            var i: usize = 0;
            while (i < golden.len and i < r.blob.len) : (i += 1) {
                if (golden[i] != r.blob[i]) break;
            }
            std.debug.print("io-oracle {s}: first byte diff at offset 0x{X}: zdos=0x{X:0>2} golden=0x{X:0>2}\n", .{ prog.exe, i, r.blob[i], golden[i] });
            return e;
        };
    }
}
