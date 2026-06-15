//! zbench -- a tiny command-line benchmarking tool.
//!
//! Runs one or more shell commands repeatedly, measures wall-clock time per
//! run, and prints an aligned table of min/max/mean/stddev. With more than one
//! command it marks the fastest and reports relative slowdown for the rest.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const stats = @import("stats.zig");
const Summary = stats.Summary;

const default_runs: usize = 10;

const usage =
    \\zbench -- a tiny command-line benchmark runner.
    \\
    \\Usage: zbench [options] <command> [<command> ...]
    \\
    \\Each <command> is a shell command string (run via `sh -c`). Every command
    \\is executed several times and its wall-clock time is summarised.
    \\
    \\Options:
    \\  --runs N      Number of timed runs per command (default: 10).
    \\  --no-color    Disable ANSI colors (also auto-disabled when not a TTY).
    \\  -h, --help    Show this help and exit.
    \\
    \\Examples:
    \\  zbench 'sleep 0.05' 'sleep 0.1'
    \\  zbench --runs 20 'ls -R /usr/include'
    \\
;

/// Fatal, user-facing errors. These are reported with a clean message and a
/// non-zero exit code rather than a Zig stack trace.
const CliError = error{
    UnknownOption,
    MissingRunsValue,
    InvalidRunsValue,
    NoCommands,
};

/// ANSI styling, resolved once based on TTY / `--no-color`.
const Style = struct {
    enabled: bool,

    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";

    fn on(s: Style, comptime code: []const u8) []const u8 {
        return if (s.enabled) code else "";
    }
};

/// Parsed command-line configuration.
const Config = struct {
    runs: usize,
    no_color: bool,
    /// Borrowed slices into the process arguments; valid for the whole program.
    commands: []const []const u8,

    fn deinit(self: *Config, gpa: Allocator) void {
        gpa.free(self.commands);
    }
};

/// One command together with the timings collected for it.
const Benchmark = struct {
    command: []const u8,
    summary: Summary,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const stdout = Io.File.stdout();
    const stderr = Io.File.stderr();

    var config = parseArgs(gpa, init.minimal.args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |cli_err| {
            try reportCliError(io, stderr, cli_err);
            std.process.exit(2);
        },
    };
    defer config.deinit(gpa);

    // Color only when stdout is a real terminal and the user did not opt out.
    const is_tty = stdout.isTty(io) catch false;
    const style: Style = .{ .enabled = is_tty and !config.no_color };

    const results = try gpa.alloc(Benchmark, config.commands.len);
    defer gpa.free(results);

    const samples = try gpa.alloc(f64, config.runs);
    defer gpa.free(samples);

    for (config.commands, results) |command, *result| {
        try printProgress(io, stderr, command, config.runs);
        for (samples) |*sample| {
            sample.* = runOnce(gpa, io, command) catch |err| {
                try reportRunError(io, stderr, command, err);
                std.process.exit(1);
            };
        }
        result.* = .{ .command = command, .summary = Summary.compute(samples) };
    }

    try printTable(io, stdout, style, results);
}

/// Parse argv (skipping argv[0]). Returns owned `commands` slice on success.
fn parseArgs(gpa: Allocator, args: std.process.Args) (CliError || Allocator.Error)!Config {
    var it: std.process.Args.Iterator = .init(args);
    _ = it.next(); // skip program name

    var runs: usize = default_runs;
    var no_color = false;

    var commands: std.ArrayList([]const u8) = .empty;
    errdefer commands.deinit(gpa);

    var positional_only = false;
    while (it.next()) |arg| {
        if (!positional_only and std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            if (std.mem.eql(u8, arg, "--")) {
                positional_only = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                // Help is handled here so it works even with no commands.
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                no_color = true;
            } else if (std.mem.eql(u8, arg, "--runs")) {
                const value = it.next() orelse return error.MissingRunsValue;
                runs = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRunsValue;
                if (runs == 0) return error.InvalidRunsValue;
            } else {
                return error.UnknownOption;
            }
        } else {
            // `arg` is borrowed from the iterator's internal storage, which on
            // POSIX lives for the whole process, so duping is unnecessary.
            try commands.append(gpa, arg);
        }
    }

    if (commands.items.len == 0) return error.NoCommands;

    return .{
        .runs = runs,
        .no_color = no_color,
        .commands = try commands.toOwnedSlice(gpa),
    };
}

/// Errors that can occur while executing a single command.
const RunError = error{NonZeroExit} || Io.Cancelable;

/// Spawn `command` via `sh -c`, wait for it, and return its wall-clock time in
/// seconds. The child's stdout/stderr are discarded so they do not pollute the
/// table; a non-zero exit (or a terminating signal) is reported as an error.
fn runOnce(gpa: Allocator, io: Io, command: []const u8) !f64 {
    _ = gpa;
    const argv = [_][]const u8{ "sh", "-c", command };

    const start = Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const elapsed = start.durationTo(Io.Clock.awake.now(io));

    switch (term) {
        .exited => |code| if (code != 0) return error.NonZeroExit,
        else => return error.NonZeroExit,
    }

    const ns: f64 = @floatFromInt(elapsed.nanoseconds);
    return ns / @as(f64, std.time.ns_per_s);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

fn reportCliError(io: Io, stderr: Io.File, err: CliError) !void {
    const msg = switch (err) {
        error.UnknownOption => "unknown option (see --help)",
        error.MissingRunsValue => "--runs requires a number",
        error.InvalidRunsValue => "--runs must be a positive integer",
        error.NoCommands => "no commands given (see --help)",
    };
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "zbench: error: {s}\n", .{msg}) catch return;
    try stderr.writeStreamingAll(io, line);
}

fn reportRunError(io: Io, stderr: Io.File, command: []const u8, err: anyerror) !void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "zbench: error: command failed ({s}): {s}\n",
        .{ @errorName(err), command },
    ) catch return;
    try stderr.writeStreamingAll(io, line);
}

/// Brief, ephemeral progress note to stderr (kept off stdout so the table can
/// be piped cleanly).
fn printProgress(io: Io, stderr: Io.File, command: []const u8, runs: usize) !void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "benchmarking ({d} runs): {s}\n",
        .{ runs, command },
    ) catch return;
    try stderr.writeStreamingAll(io, line);
}

/// Render the results table to stdout.
fn printTable(io: Io, file: Io.File, style: Style, results: []const Benchmark) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    defer w.interface.flush() catch {};
    const out = &w.interface;

    // Column width for the command, capped so a pathological command does not
    // blow out the table.
    const cmd_header = "command";
    var cmd_width: usize = cmd_header.len;
    for (results) |r| cmd_width = @max(cmd_width, @min(r.command.len, 40));

    // Find the fastest mean for the "relative" column / fastest marker.
    var fastest_idx: usize = 0;
    for (results, 0..) |r, i| {
        if (r.summary.mean < results[fastest_idx].summary.mean) fastest_idx = i;
    }
    const fastest_mean = results[fastest_idx].summary.mean;
    const comparing = results.len > 1;

    // Header.
    try out.print("{s}", .{style.on(Style.bold)});
    try printPadded(out, cmd_header, cmd_width);
    try out.print("  {s:>11}  {s:>11}  {s:>11}  {s:>11}", .{ "min", "max", "mean", "stddev" });
    if (comparing) try out.print("  {s:>14}", .{"relative"});
    try out.print("{s}\n", .{style.on(Style.reset)});

    // Separator.
    const rel_width: usize = if (comparing) 14 + 2 else 0;
    try out.splatByteAll('-', cmd_width + 2 + (11 + 2) * 4 + rel_width);
    try out.writeByte('\n');

    // Rows.
    for (results, 0..) |r, i| {
        const is_fastest = comparing and i == fastest_idx;
        if (is_fastest) try out.print("{s}", .{style.on(Style.green)});

        try printPaddedTruncated(out, r.command, cmd_width);
        try printTimeCell(out, r.summary.min);
        try printTimeCell(out, r.summary.max);
        try printTimeCell(out, r.summary.mean);
        try printTimeCell(out, r.summary.stddev);

        if (comparing) {
            if (is_fastest) {
                try out.print("  {s:>14}", .{"fastest"});
            } else {
                var rbuf: [24]u8 = undefined;
                const ratio = r.summary.mean / fastest_mean;
                const rel = std.fmt.bufPrint(&rbuf, "{d:.2}x slower", .{ratio}) catch "?";
                try out.print("  {s:>14}", .{rel});
            }
        }

        if (is_fastest) try out.print("{s}", .{style.on(Style.reset)});
        try out.writeByte('\n');
    }
}

const time_cell_width = 11;

/// Format a duration in seconds with an appropriate unit and write it as a
/// right-aligned cell (preceded by a two-space gap) to `out`.
fn printTimeCell(out: *Io.Writer, seconds: f64) !void {
    var buf: [32]u8 = undefined;
    const text = fmtSeconds(&buf, seconds);
    try out.writeAll("  ");
    if (text.len < time_cell_width) try out.splatByteAll(' ', time_cell_width - text.len);
    try out.writeAll(text);
}

/// Format a duration in seconds into `buf`, choosing s/ms/us so the magnitude
/// stays readable. Returns a slice of `buf`.
fn fmtSeconds(buf: []u8, seconds: f64) []const u8 {
    if (seconds >= 1.0) {
        return std.fmt.bufPrint(buf, "{d:.3} s", .{seconds}) catch "??";
    } else if (seconds >= 1e-3) {
        return std.fmt.bufPrint(buf, "{d:.3} ms", .{seconds * 1e3}) catch "??";
    } else {
        return std.fmt.bufPrint(buf, "{d:.3} us", .{seconds * 1e6}) catch "??";
    }
}

fn printPadded(out: *Io.Writer, text: []const u8, width: usize) !void {
    try out.writeAll(text);
    if (text.len < width) try out.splatByteAll(' ', width - text.len);
}

/// Like `printPadded` but truncates `text` to `width`, marking truncation with
/// an ellipsis.
fn printPaddedTruncated(out: *Io.Writer, text: []const u8, width: usize) !void {
    if (text.len <= width) {
        try printPadded(out, text, width);
    } else {
        try out.writeAll(text[0 .. width - 1]);
        try out.writeByte(0xE2); // … (U+2026) UTF-8
        try out.writeByte(0x80);
        try out.writeByte(0xA6);
        // The 3-byte ellipsis replaces 1 column visually; the byte count differs
        // but terminal alignment is by display width, so add no extra padding.
    }
}

test {
    // Pull in stats.zig tests when running `zig build test`.
    std.testing.refAllDecls(@import("stats.zig"));
}
