//! The comptime Bus contract (the CPU's only memory/port interface), plus the
//! comptime hook contracts (InterruptController, Scheduler, FaultSink) and a
//! `TestBus` — a REAL Bus implementation over a RAM array, not a fake.
//!
//! The CPU is generic over these at comptime so the per-instruction memory path
//! inlines to zero cost (no runtime vtable). Each contract is verified
//! independently with `@hasDecl`/`@TypeOf` and a `@compileError` on a mismatch.

const std = @import("std");

/// Verify that `Bus` implements the physical-memory + port contract.
///
/// readPhys* never fails (DECIDED Bus error model): physical access always
/// succeeds; unmapped reads return a deterministic fill (the bus's job per
/// CLAUDE constraint #5). Only CPU-side segmentation produces faults.
pub fn assertBusContract(comptime Bus: type) void {
    assertMethod(Bus, "readPhys8", fn (*Bus, u32) u8);
    assertMethod(Bus, "readPhys16", fn (*Bus, u32) u16);
    assertMethod(Bus, "readPhys32", fn (*Bus, u32) u32);
    assertMethod(Bus, "writePhys8", fn (*Bus, u32, u8) void);
    assertMethod(Bus, "writePhys16", fn (*Bus, u32, u16) void);
    assertMethod(Bus, "writePhys32", fn (*Bus, u32, u32) void);
    assertMethod(Bus, "portIn8", fn (*Bus, u16) u8);
    assertMethod(Bus, "portIn16", fn (*Bus, u16) u16);
    assertMethod(Bus, "portIn32", fn (*Bus, u16) u32);
    assertMethod(Bus, "portOut8", fn (*Bus, u16, u8) void);
    assertMethod(Bus, "portOut16", fn (*Bus, u16, u16) void);
    assertMethod(Bus, "portOut32", fn (*Bus, u16, u32) void);
}

/// Verify the InterruptController hook (the 8259 handshake, modeled faithfully:
/// IRR/ISR/priority live in the controller, not a one-way push). The CPU
/// recognizes via `getPendingInterrupt()` and acknowledges via `ackIrq()`.
pub fn assertInterruptControllerContract(comptime Pic: type) void {
    // getPendingInterrupt() -> ?u8 : highest-priority pending vector subject to
    // IF/priority, derived from the cycle ledger; null if none.
    assertMethod(Pic, "getPendingInterrupt", fn (*Pic) ?u8);
    // ackIrq(vector) : the acknowledge/EOI handshake so 8259 IRR/ISR/priority
    // stays modeled.
    assertMethod(Pic, "ackIrq", fn (*Pic, u8) void);
}

/// Verify the Scheduler hook (HLT/next-event coordination, D11).
pub fn assertSchedulerContract(comptime Sched: type) void {
    // nextEventCycle() -> u64 : the absolute cycle of the next scheduled event,
    // so the machine can fast-forward emulated time on a "halted" stop_reason.
    assertMethod(Sched, "nextEventCycle", fn (*Sched) u64);
}

/// Verify the fault/shutdown sink (the machine, not the CPU, decides reset
/// policy on triple-fault/shutdown).
pub fn assertFaultSinkContract(comptime Sink: type) void {
    assertMethod(Sink, "onShutdown", fn (*Sink) void);
}

fn assertMethod(comptime T: type, comptime name: []const u8, comptime Sig: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("Bus contract: type '" ++ @typeName(T) ++
            "' is missing required method '" ++ name ++
            "' with signature " ++ @typeName(Sig));
    }
    const Actual = @TypeOf(@field(T, name));
    if (Actual != Sig) {
        @compileError("Bus contract: method '" ++ name ++ "' on '" ++
            @typeName(T) ++ "' has type " ++ @typeName(Actual) ++
            ", expected " ++ @typeName(Sig));
    }
}

// ---------------------------------------------------------------------------
// TestBus — a real Bus over a RAM array, NOT a prohibited fake.
// ---------------------------------------------------------------------------

/// A single recorded port access (for IN/OUT vector verification).
pub const PortAccess = struct {
    kind: enum { in8, in16, in32, out8, out16, out32 },
    port: u16,
    value: u32,
};

/// A single recorded memory access (D8 opt-in access-trace baseline).
pub const MemAccess = struct {
    kind: enum { r8, r16, r32, w8, w16, w32 },
    addr: u32,
    value: u32,
};

/// A RAM-backed Bus for unit/conformance tests.
///
/// `flat` covers low memory + the HMA wrap region densely; `pages` is a sparse
/// map so arbitrary 32-bit addresses (from 32-bit-addressing forms /
/// ProcessorTests) work without a 4 GiB allocation. Deterministic init (the
/// fill byte). No allocation on the hot path once a page exists.
pub const TestBus = struct {
    pub const flat_size: usize = 0x110000; // 1 MiB + 64 KiB (HMA wrap)
    pub const page_size: usize = 0x1000;
    /// Deterministic fill for never-written sparse bytes (constraint #5).
    pub const fill: u8 = 0;

    flat: [flat_size]u8 = @splat(fill),
    pages: std.AutoHashMapUnmanaged(u32, *[page_size]u8) = .empty,
    allocator: std.mem.Allocator,

    // Recording (off by default; enabled per test).
    record_ports: bool = false,
    record_mem: bool = false,
    port_log: std.ArrayList(PortAccess) = .empty,
    mem_log: std.ArrayList(MemAccess) = .empty,
    /// Deterministic value returned by every portIn (no host I/O).
    port_in_value: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) TestBus {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TestBus) void {
        var it = self.pages.valueIterator();
        while (it.next()) |p| self.allocator.destroy(p.*);
        self.pages.deinit(self.allocator);
        self.port_log.deinit(self.allocator);
        self.mem_log.deinit(self.allocator);
    }

    /// Pointer to the byte at `addr`, lazily creating the sparse page if needed.
    fn byteptr(self: *TestBus, addr: u32) *u8 {
        if (addr < flat_size) return &self.flat[addr];
        const page = addr & ~@as(u32, page_size - 1);
        const off = addr & (page_size - 1);
        const gop = self.pages.getOrPut(self.allocator, page) catch @panic("OOM in TestBus");
        if (!gop.found_existing) {
            const buf = self.allocator.create([page_size]u8) catch @panic("OOM in TestBus");
            @memset(buf, fill);
            gop.value_ptr.* = buf;
        }
        return &gop.value_ptr.*[off];
    }

    pub fn readByte(self: *TestBus, addr: u32) u8 {
        return self.byteptr(addr).*;
    }
    pub fn writeByte(self: *TestBus, addr: u32, v: u8) void {
        self.byteptr(addr).* = v;
    }

    // --- Bus contract: physical memory (little-endian, ascending sub-bytes) ---
    pub fn readPhys8(self: *TestBus, phys: u32) u8 {
        const v = self.readByte(phys);
        if (self.record_mem) self.logMem(.r8, phys, v);
        return v;
    }
    pub fn readPhys16(self: *TestBus, phys: u32) u16 {
        const v = @as(u16, self.readByte(phys)) |
            (@as(u16, self.readByte(phys +% 1)) << 8);
        if (self.record_mem) self.logMem(.r16, phys, v);
        return v;
    }
    pub fn readPhys32(self: *TestBus, phys: u32) u32 {
        const v = @as(u32, self.readByte(phys)) |
            (@as(u32, self.readByte(phys +% 1)) << 8) |
            (@as(u32, self.readByte(phys +% 2)) << 16) |
            (@as(u32, self.readByte(phys +% 3)) << 24);
        if (self.record_mem) self.logMem(.r32, phys, v);
        return v;
    }
    pub fn writePhys8(self: *TestBus, phys: u32, v: u8) void {
        self.writeByte(phys, v);
        if (self.record_mem) self.logMem(.w8, phys, v);
    }
    pub fn writePhys16(self: *TestBus, phys: u32, v: u16) void {
        self.writeByte(phys, @truncate(v));
        self.writeByte(phys +% 1, @truncate(v >> 8));
        if (self.record_mem) self.logMem(.w16, phys, v);
    }
    pub fn writePhys32(self: *TestBus, phys: u32, v: u32) void {
        self.writeByte(phys, @truncate(v));
        self.writeByte(phys +% 1, @truncate(v >> 8));
        self.writeByte(phys +% 2, @truncate(v >> 16));
        self.writeByte(phys +% 3, @truncate(v >> 24));
        if (self.record_mem) self.logMem(.w32, phys, v);
    }

    // --- Bus contract: ports (deterministic; logged) ---
    pub fn portIn8(self: *TestBus, port: u16) u8 {
        const v: u8 = @truncate(self.port_in_value);
        if (self.record_ports) self.logPort(.in8, port, v);
        return v;
    }
    pub fn portIn16(self: *TestBus, port: u16) u16 {
        const v: u16 = @truncate(self.port_in_value);
        if (self.record_ports) self.logPort(.in16, port, v);
        return v;
    }
    pub fn portIn32(self: *TestBus, port: u16) u32 {
        const v: u32 = self.port_in_value;
        if (self.record_ports) self.logPort(.in32, port, v);
        return v;
    }
    pub fn portOut8(self: *TestBus, port: u16, v: u8) void {
        if (self.record_ports) self.logPort(.out8, port, v);
    }
    pub fn portOut16(self: *TestBus, port: u16, v: u16) void {
        if (self.record_ports) self.logPort(.out16, port, v);
    }
    pub fn portOut32(self: *TestBus, port: u16, v: u32) void {
        if (self.record_ports) self.logPort(.out32, port, v);
    }

    fn logPort(self: *TestBus, kind: anytype, port: u16, value: u32) void {
        self.port_log.append(self.allocator, .{ .kind = kind, .port = port, .value = value }) catch {};
    }
    fn logMem(self: *TestBus, kind: anytype, addr: u32, value: u32) void {
        self.mem_log.append(self.allocator, .{ .kind = kind, .addr = addr, .value = value }) catch {};
    }
};

comptime {
    assertBusContract(TestBus);
}

test "TestBus is a valid Bus and round-trips bytes" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.writePhys32(0x100, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), bus.readPhys32(0x100));
    try std.testing.expectEqual(@as(u8, 0xEF), bus.readPhys8(0x100));
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.readPhys16(0x100));
}

test "TestBus sparse page works for high 32-bit addresses" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    bus.writePhys16(0xFFEE_0010, 0xCAFE);
    try std.testing.expectEqual(@as(u16, 0xCAFE), bus.readPhys16(0xFFEE_0010));
    // Untouched sparse bytes read the deterministic fill.
    try std.testing.expectEqual(@as(u8, TestBus.fill), bus.readPhys8(0xAABB_CCDD));
}
