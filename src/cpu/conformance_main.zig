//! Full 80386 real-mode conformance sweep entry point.
//!
//! Run with `zig build conformance`. This decompresses and runs EVERY vendored
//! SingleStepTests/80386 real-mode vector (src/cpu/testdata/80386), applying the
//! D9 per-opcode undefined-EFLAGS mask (80386.csv f_umask) and the revocation
//! list, and prints a per-failing-opcode report plus grand totals.
//!
//! It is a single `test` block (filtered into its own build step) so it does not
//! slow the normal `zig build test`. The data is committed and read offline — no
//! network fetch at test time (determinism rule, CLAUDE.md).

const std = @import("std");
const pt = @import("processor_tests.zig");
const build_options = @import("build_options");

test "FULL CONFORMANCE SWEEP — 80386 real-mode vectors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Per-failing-opcode detail is verbose (hundreds of lines); printing it
    // through the `zig build` test-runner IPC can overflow the protocol pipe, so
    // it is off here. Run the test binary directly for the per-opcode breakdown,
    // or flip this to `true` when invoking standalone.
    const totals = try pt.runDirectory(allocator, io, build_options.testdata_80386, false);

    const total = totals.pass + totals.fail;
    std.debug.print(
        "\n==== 80386 real-mode conformance ====\n" ++
            "opcode files : {d}\n" ++
            "vectors run  : {d}\n" ++
            "  pass       : {d}\n" ++
            "  fail       : {d}\n" ++
            "  revoked    : {d}\n" ++
            "failing opcodes: {d}/{d}\n" ++
            "=====================================\n",
        .{ totals.files, total, totals.pass, totals.fail, totals.revoked, totals.failing_opcodes, totals.files },
    );
}
