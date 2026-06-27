//! Test root: imports every CPU module so `zig build test-cpu` runs all the
//! `test {}` blocks and the dedicated *_test.zig files.

const std = @import("std");

comptime {
    _ = @import("cpu.zig");
    _ = @import("state.zig");
    _ = @import("flags.zig");
    _ = @import("bus.zig");
    _ = @import("alu.zig");
    _ = @import("decode.zig");
    _ = @import("disasm.zig");
    _ = @import("dispatch.zig");
    _ = @import("exec.zig");
    _ = @import("exec_data.zig");
    _ = @import("exec_alu.zig");
    _ = @import("exec_shift.zig");
    _ = @import("exec_muldiv.zig");
    _ = @import("exec_bit.zig");
    _ = @import("exec_bcd.zig");
    _ = @import("exec_ctrl.zig");
    _ = @import("exec_string.zig");
    _ = @import("exec_io.zig");
    _ = @import("exec_system.zig");
    _ = @import("segmentation.zig");
    _ = @import("interrupts.zig");
    _ = @import("cycles.zig");
    _ = @import("branch_trace.zig");
    _ = @import("decode_test.zig");
    _ = @import("branch_trace_test.zig");
    _ = @import("disasm_test.zig");
    _ = @import("exec_test.zig");
    _ = @import("interrupts_test.zig");
    _ = @import("determinism_test.zig");
    _ = @import("processor_tests.zig");
    _ = @import("conformance_test.zig");
}

test {
    std.testing.refAllDecls(@This());
}
