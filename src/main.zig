//! zdos — a minimal headless runner frontend.
//!
//! Loads a real-mode DOS program (`.COM`/`.EXE`) from the host filesystem through
//! the emulated DOS loader, runs it to termination, and dumps whatever the program
//! wrote to the CON device (INT 21h AH=02/06/09, handle 1) to the host stdout.
//!
//! Determinism note: the CON output is captured in an internal buffer during the
//! run (never live host stdout — that would couple emulation to host I/O), and
//! flushed once at exit. The run itself touches no host clock.
//!
//! Usage: `zig build run -- <path/to/PROGRAM.COM>`  (or a `.EXE`)

const std = @import("std");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

/// Stop the run once the initial process terminates (INT 21h AH=4C / INT 20h) or
/// the CPU halts with no way to wake (`halted_forever` lands here via `halted`).
fn untilDone(m: *Machine) bool {
    return m.cpu.st.halted or m.dos.terminated;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    // ---- args: argv[1] = path to the DOS program ----------------------------
    var args_it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next(); // skip argv[0]
    const path = args_it.next() orelse {
        try stderr.writeStreamingAll(io, "usage: zig build run -- <PROGRAM.COM|PROGRAM.EXE> [args...]\n");
        std.process.exit(2);
    };

    // Any remaining host args become the guest DOS command tail (space-joined),
    // e.g. `... -- TCC.EXE -IINCLUDE HELLO.C` runs TCC with that command line.
    // psp.build formats the on-disk tail (count byte + leading space) to match
    // DOS, so the guest parses it exactly as it would under real DOS.
    var tail_buf: [127]u8 = undefined;
    var tail_len: usize = 0;
    while (args_it.next()) |a| {
        if (tail_len != 0 and tail_len < tail_buf.len) {
            tail_buf[tail_len] = ' ';
            tail_len += 1;
        }
        const n = @min(a.len, tail_buf.len - tail_len);
        @memcpy(tail_buf[tail_len .. tail_len + n], a[0..n]);
        tail_len += n;
    }
    const cmdtail = tail_buf[0..tail_len];

    // Split into a host directory (mounted as DOS drive C:) and the file name.
    const sep = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir_path = if (sep) |s| path[0..s] else ".";
    const file_name = if (sep) |s| path[s + 1 ..] else path;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "zdos: cannot open directory '{s}': {t}\n", .{ dir_path, err }) catch "zdos: cannot open directory\n";
        try stderr.writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer dir.close(io);

    // ---- build the machine (heap-pinned: wire() captures self-pointers) ------
    const m = try gpa.create(Machine);
    defer {
        m.deinit();
        gpa.destroy(m);
    }
    try m.init(gpa, &.{}); // empty BIOS image -> POST stand-in
    m.wire();
    m.post();
    m.dos.mountDrive(2, dir, io); // C:
    m.dos.current_drive = 2;

    // ---- load + run ----------------------------------------------------------
    m.bootProgram(2, file_name, cmdtail) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "zdos: cannot load '{s}': {t}\n", .{ file_name, err }) catch "zdos: cannot load program\n";
        try stderr.writeStreamingAll(io, msg);
        std.process.exit(1);
    };

    const reason = m.runUntil(untilDone, 500_000_000);

    // ---- flush CON output, then report exit status ---------------------------
    try stdout.writeStreamingAll(io, m.dos.dev_table.con.output());

    var sbuf: [160]u8 = undefined;
    const status = std.fmt.bufPrint(&sbuf, "\n[zdos] {s}; exit code {d}; {d} cycles\n", .{
        @tagName(reason),
        m.dos.ret_code,
        m.cpu.st.cycles,
    }) catch "\n[zdos] done\n";
    try stderr.writeStreamingAll(io, status);

    if (!m.dos.terminated) std.process.exit(1);
}
