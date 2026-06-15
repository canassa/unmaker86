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
const debug_mod = @import("debug");

const Machine = machine_mod.Machine;
const Controller = debug_mod.Controller;

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

    // ---- args: [--break-cycle N] <PROGRAM> [guest args...] ------------------
    // The optional `--break-cycle N` flag (debugger opt-in) constructs a
    // Controller and stops the run deterministically at the first instruction
    // boundary at/after cycle N, dumping a CPU snapshot — instead of running to
    // termination. The default path (no flag) is unchanged.
    var args_it: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args_it.next(); // skip argv[0]
    var break_cycle: ?u64 = null;
    var first = args_it.next() orelse {
        try stderr.writeStreamingAll(io, "usage: zig build run -- [--break-cycle N] <PROGRAM.COM|PROGRAM.EXE> [args...]\n");
        std.process.exit(2);
    };
    if (std.mem.eql(u8, first, "--break-cycle")) {
        const n_str = args_it.next() orelse {
            try stderr.writeStreamingAll(io, "zdos: --break-cycle requires a cycle count\n");
            std.process.exit(2);
        };
        break_cycle = std.fmt.parseInt(u64, n_str, 10) catch {
            try stderr.writeStreamingAll(io, "zdos: --break-cycle expects a non-negative integer\n");
            std.process.exit(2);
        };
        first = args_it.next() orelse {
            try stderr.writeStreamingAll(io, "usage: zig build run -- [--break-cycle N] <PROGRAM.COM|PROGRAM.EXE> [args...]\n");
            std.process.exit(2);
        };
    }
    const path = first;

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

    if (break_cycle) |bc| {
        // Debugger path: drive the machine via the Controller and stop at cycle N.
        // The Controller observes/drives the machine synchronously; it never reads
        // host time and leaves the ledger exactly where the last retired step put
        // it (no smear) — the determinism property zdos exists to keep.
        var ctrl = Controller.init(m);
        const stop = ctrl.runToCycle(bc) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zdos: --break-cycle failed: {t}\n", .{err}) catch "zdos: --break-cycle failed\n";
            try stderr.writeStreamingAll(io, msg);
            std.process.exit(1);
        };

        // Flush whatever the program printed up to the break point.
        try stdout.writeStreamingAll(io, m.dos.dev_table.con.output());

        const snap = ctrl.cpuSnapshot();
        var sbuf: [320]u8 = undefined;
        const status = std.fmt.bufPrint(&sbuf,
            \\
            \\[zdos] stopped: {s}; cycle {d}
            \\  CS:IP {x:0>4}:{x:0>4}  EAX={x:0>8} EBX={x:0>8} ECX={x:0>8} EDX={x:0>8}
            \\  ESP={x:0>8} EBP={x:0>8} ESI={x:0>8} EDI={x:0>8}  FLAGS: CF={d} ZF={d} SF={d} IF={d}
            \\
        , .{
            @tagName(stop),
            snap.cycles,
            snap.cs,
            @as(u16, @truncate(snap.eip)),
            snap.eax,
            snap.ebx,
            snap.ecx,
            snap.edx,
            snap.esp,
            snap.ebp,
            snap.esi,
            snap.edi,
            @intFromBool(snap.cf),
            @intFromBool(snap.zf),
            @intFromBool(snap.sf),
            @intFromBool(snap.iff),
        }) catch "\n[zdos] stopped\n";
        try stderr.writeStreamingAll(io, status);
        return;
    }

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
