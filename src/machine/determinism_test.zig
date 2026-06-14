//! Phase 6 determinism audit (the module gate): grep-enforced no host time / RNG /
//! thread / env / FLOAT in the scheduling/timing path (M-D2 — float keys are the
//! spice86/DOSBox anti-pattern), and zero per-op alloc in step()/fireDue() (the
//! emulation hot loop allocates nothing — memory-and-performance.md §7).

const std = @import("std");
const machine = @import("machine");
const cpu_mod = @import("cpu");

const Machine = machine.Machine;

test "no host time / RNG / thread / env / float anywhere in src/machine (grep)" {
    // The device + timing sources are grep-audited in src/devices/pit_test.zig
    // (an @embedFile cannot cross the module/package boundary).
    const sources = [_][]const u8{
        @embedFile("machine.zig"),
        @embedFile("scheduler.zig"),
        @embedFile("run_loop.zig"),
    };
    const forbidden = [_][]const u8{
        "std.time",
        "std.Random", "std.rand",
        "std.Thread",
        "std.posix.getenv", "std.process.getEnv", "std.os.getenv",
        // No floats in the scheduling/timing path (M-D2): reject f32/f64 keys.
        "f32", "f64",
    };
    for (sources) |src| {
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden pattern '{s}' in a machine/devices source\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}

/// Counting allocator (mirrors the bus determinism test): records every alloc/
/// free so the run path can be asserted alloc-free (memory-and-performance.md §7).
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawResize(m, a, nl, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawRemap(m, a, nl, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.backing.rawFree(m, a, ra);
    }
    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "step() / fireDue() / device handlers allocate nothing (counting allocator)" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const m = try std.testing.allocator.create(Machine);
    defer std.testing.allocator.destroy(m);
    try m.init(counting.allocator(), &.{}); // up-front slab alloc (allowed)
    m.wire();
    defer m.deinit();

    // Program the timer + PIC + a HLT/STI program that takes IRQs; then run a
    // burst that fires events, delivers IRQs, fast-forwards HLT — all alloc-free.
    m.programDefaultPic();
    // ISR: EOI + IRET.
    m.bus.writePhys16(0x08 * 4, 0x0400);
    m.bus.writePhys16(0x08 * 4 + 2, 0x0000);
    const isr = [_]u8{ 0xB0, 0x20, 0xE6, 0x20, 0xCF };
    for (isr, 0..) |byte, i| m.bus.writePhys8(0x0400 + @as(u32, @intCast(i)), byte);
    m.bus.portOut8(0x21, 0xFE); // unmask IRQ0
    m.bus.portOut8(0x43, 0x34); // ch0 mode 2
    m.bus.portOut8(0x40, 0x14);
    m.bus.portOut8(0x40, 0x00); // reload 20
    m.cpu.loadSegment(.cs, 0);
    m.cpu.loadSegment(.ss, 0);
    m.cpu.st.setReg16(@intFromEnum(cpu_mod.state.Reg32.esp), 0x7000);
    m.cpu.st.eip = 0x0500;
    m.bus.writePhys8(0x0500, 0xFB); // STI
    m.bus.writePhys8(0x0501, 0xF4); // HLT
    m.bus.writePhys8(0x0502, 0xEB); // JMP $-1 -> back to HLT
    m.bus.writePhys8(0x0503, 0xFD);

    const after_setup = counting.count;
    _ = m.runCycles(20_000);
    // No allocation occurred on the run path.
    try std.testing.expectEqual(after_setup, counting.count);
}
