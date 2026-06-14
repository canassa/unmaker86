//! Test root for the bus module: imports every `_test` file plus `bus.zig`
//! itself (so its inline tests + the comptime contract assertion run under
//! `zig build test-bus`).

const std = @import("std");

comptime {
    _ = @import("bus.zig");
    _ = @import("memmap.zig");
    _ = @import("a20.zig");
    _ = @import("ram_test.zig");
    _ = @import("regions_test.zig");
    _ = @import("a20_test.zig");
    _ = @import("ports_test.zig");
    _ = @import("determinism_test.zig");
    // integration_test.zig is built as a SEPARATE artifact (it imports the `cpu`
    // and `bus` MODULES, whose roots can't also live in this `root` module).
}

test {
    std.testing.refAllDecls(@This());
}
