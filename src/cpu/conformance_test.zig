//! Fast conformance regression guard (part of `zig build test`).
//!
//! Runs a curated set of vendored 80386 real-mode opcode files end-to-end (real
//! MOO data, real CPU) and asserts they pass at or above a pinned rate. This is
//! a true regression guard — it uses the actual vectors, not
//! fabricated results. The EXHAUSTIVE 941-opcode sweep lives in
//! `zig build conformance` (conformance_main.zig); this keeps the unit suite
//! fast while still catching regressions in the core ISA paths.

const std = @import("std");
const pt = @import("processor_tests.zig");
const build_options = @import("build_options");

/// Opcodes that currently pass 100% of their vendored vectors. A regression
/// that drops any of these below 100% fails the build.
const fully_passing = [_][]const u8{
    "90", // NOP
    "00", "01", "02", "03", "05", // ADD forms
    "88", "89", "8A", "8B", // MOV r/m<->reg
    "40", "48", // INC/DEC AX
    "20", "08", "30", "38", // AND/OR/XOR/CMP
    "0FAF", // IMUL r,r/m  (undefined flags masked)
    "74", "75", // JE/JNE rel8
    "0F84", // JE rel16
    "E8", // CALL rel
    "C3", // RET near
    "50", "58", // PUSH/POP AX
    "EB", // JMP rel8
    "AA", "AC", // STOS/LODS
    "0FB6", "0FBE", // MOVZX/MOVSX
};

fn loadAndRun(a: std.mem.Allocator, io: std.Io, undef: *const pt.UndefTable, rev: *const pt.Revocations, name: []const u8) !pt.FileResult {
    var dir = try std.Io.Dir.openDirAbsolute(io, build_options.testdata_80386, .{});
    defer dir.close(io);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "v1_ex_real_mode/{s}.MOO.gz", .{name});
    const gz = try dir.readFileAlloc(io, path, a, .limited(1 << 26));
    defer a.free(gz);
    const data = try pt.gunzip(a, gz);
    defer a.free(data);
    const key = pt.fileNameToOpKey(name);
    return pt.runMooFile(a, data, undef.lookup(key.op, key.reg), rev);
}

test "conformance regression: curated opcodes pass 100%" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.openDirAbsolute(io, build_options.testdata_80386, .{});
    defer dir.close(io);
    const csv = try dir.readFileAlloc(io, "80386.csv", a, .limited(1 << 24));
    defer a.free(csv);
    var undef = try pt.parseCsv(a, csv);
    defer undef.deinit(a);
    var rev = pt.Revocations{};
    defer rev.deinit(a);

    var total_pass: usize = 0;
    var total: usize = 0;
    for (fully_passing) |name| {
        const r = try loadAndRun(a, io, &undef, &rev, name);
        total_pass += r.pass;
        total += r.pass + r.fail;
        if (r.fail != 0) {
            std.debug.print("conformance regression: {s} dropped to {d}/{d}\n", .{ name, r.pass, r.pass + r.fail });
            return error.ConformanceRegression;
        }
    }
    try std.testing.expect(total > 0);
    std.debug.print("conformance guard: {d}/{d} vectors over {d} curated opcodes\n", .{ total_pass, total, fully_passing.len });
}
