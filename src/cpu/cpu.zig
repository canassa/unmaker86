//! The 80386 core (real mode), generic over a comptime `Bus` (+ comptime hook
//! types). This file owns `State`, the run loop, `step()`, the single
//! logical->linear->physical memory choke point (`linearToPhys`), and the
//! public debugger/machine API.
//!
//! Scope: 386 real mode only (CLAUDE.md). PM/paging/V86/x87 are deferred; the
//! structural seams are present but not active.

const std = @import("std");
const builtin = @import("builtin");

pub const state = @import("state.zig");
pub const flags = @import("flags.zig");
pub const bus_mod = @import("bus.zig");
pub const alu = @import("alu.zig");
pub const decode = @import("decode.zig");
pub const segmentation = @import("segmentation.zig");
pub const interrupts = @import("interrupts.zig");
pub const cycles = @import("cycles.zig");

pub const State = state.State;
pub const StepResult = state.StepResult;
pub const StopReason = state.StopReason;
pub const Seg = state.Seg;
pub const Reg32 = state.Reg32;
pub const Flags = flags.Flags;
pub const TestBus = bus_mod.TestBus;

/// The error set every memory/decode/segment helper returns (D10). A fault is
/// recorded in `State.pending_fault` and delivered by the dispatcher's catch.
pub const CpuError = error{Fault};

/// Default no-op interrupt controller for tests that don't drive IRQs.
pub const NullPic = struct {
    pub fn getPendingInterrupt(_: *NullPic) ?u8 {
        return null;
    }
    pub fn ackIrq(_: *NullPic, _: u8) void {}
};

/// Default scheduler returning a fixed far-future next event (tests).
pub const NullScheduler = struct {
    next: u64 = std.math.maxInt(u64),
    pub fn nextEventCycle(self: *NullScheduler) u64 {
        return self.next;
    }
};

/// Default callback sink (D2): a `0xFE 0x38 <id>` callback opcode with no
/// registered sink faithfully raises `#UD` (never a silent NOP — ground rule).
/// The `dispatchCallback` method exists only to satisfy the contract; the Grp4
/// `/7` arm recognizes this type at comptime and takes the `#UD` path directly
/// (which must NOT pre-advance EIP, so the interrupts.zig fault rollback to
/// `instr_start_eip` stays correct).
pub const NullCallbackSink = struct {
    pub fn dispatchCallback(_: *NullCallbackSink, _: u8) void {}
};

/// Options bundling the comptime hook types alongside the Bus.
pub const Options = struct {
    Pic: type = NullPic,
    Scheduler: type = NullScheduler,
    CallbackSink: type = NullCallbackSink,
};

/// Build the CPU type for a given Bus (and optional hook types).
pub fn Cpu(comptime Bus: type) type {
    return CpuWith(Bus, .{});
}

pub fn CpuWith(comptime Bus: type, comptime opts: Options) type {
    bus_mod.assertBusContract(Bus);
    bus_mod.assertInterruptControllerContract(opts.Pic);
    bus_mod.assertSchedulerContract(opts.Scheduler);
    bus_mod.assertCallbackSinkContract(opts.CallbackSink);

    return struct {
        const Self = @This();
        pub const BusType = Bus;
        pub const PicType = opts.Pic;
        pub const SchedulerType = opts.Scheduler;
        pub const CallbackSink = opts.CallbackSink;

        st: State = .{},
        bus: *Bus,
        pic: *opts.Pic,
        sched: *opts.Scheduler,
        /// The guest->host callback-trap sink (D2). null until the machine wires
        /// the `Services` aggregate; a `0xFE 0x38` opcode with no sink #UDs.
        cb: ?*opts.CallbackSink = null,

        // ---- Per-instruction decode scratch (reset each step; no alloc) ----
        dec: decode.Decoded = .{},
        /// EIP at the start of the current instruction (fault rollback, Phase 6).
        instr_start_eip: u32 = 0,

        pub fn init(bus: *Bus, pic: *opts.Pic, sched: *opts.Scheduler) Self {
            var self: Self = .{ .bus = bus, .pic = pic, .sched = sched };
            self.st.reset();
            return self;
        }

        pub fn reset(self: *Self) void {
            self.st.reset();
        }

        // -------------------------------------------------------------------
        // Memory choke points (Phase 1c / Theme F).
        // -------------------------------------------------------------------

        /// The ONE logical->linear->physical translation seam. In real mode
        /// linear == physical (identity); paging slots in here later.
        pub inline fn linearToPhys(self: *Self, linear: u32) u32 {
            _ = self;
            return linear;
        }

        // Physical access, post-translation. The wide-access split is decided on
        // the LINEAR address (ascending sub-access order, contract-fixed); in
        // real mode linear==physical so we forward whole accesses to the bus.
        pub inline fn readLinear8(self: *Self, linear: u32) u8 {
            return self.bus.readPhys8(self.linearToPhys(linear));
        }
        pub inline fn readLinear16(self: *Self, linear: u32) u16 {
            return self.bus.readPhys16(self.linearToPhys(linear));
        }
        pub inline fn readLinear32(self: *Self, linear: u32) u32 {
            return self.bus.readPhys32(self.linearToPhys(linear));
        }
        pub inline fn writeLinear8(self: *Self, linear: u32, v: u8) void {
            self.bus.writePhys8(self.linearToPhys(linear), v);
        }
        pub inline fn writeLinear16(self: *Self, linear: u32, v: u16) void {
            self.bus.writePhys16(self.linearToPhys(linear), v);
        }
        pub inline fn writeLinear32(self: *Self, linear: u32, v: u32) void {
            self.bus.writePhys32(self.linearToPhys(linear), v);
        }

        // -------------------------------------------------------------------
        // Segmented access (goes through checkSegmentAccess -> linear).
        // -------------------------------------------------------------------

        pub fn segRead8(self: *Self, seg: Seg, off: u32) CpuError!u8 {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 1, .read);
            return self.readLinear8(lin);
        }
        pub fn segRead16(self: *Self, seg: Seg, off: u32) CpuError!u16 {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 2, .read);
            return self.readLinear16(lin);
        }
        pub fn segRead32(self: *Self, seg: Seg, off: u32) CpuError!u32 {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 4, .read);
            return self.readLinear32(lin);
        }
        pub fn segWrite8(self: *Self, seg: Seg, off: u32, v: u8) CpuError!void {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 1, .write);
            self.writeLinear8(lin, v);
        }
        pub fn segWrite16(self: *Self, seg: Seg, off: u32, v: u16) CpuError!void {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 2, .write);
            self.writeLinear16(lin, v);
        }
        pub fn segWrite32(self: *Self, seg: Seg, off: u32, v: u32) CpuError!void {
            const lin = try segmentation.checkSegmentAccess(self, seg, off, 4, .write);
            self.writeLinear32(lin, v);
        }

        // -------------------------------------------------------------------
        // Segment load (real-mode form: base = sel<<4 ONLY; limit untouched).
        // -------------------------------------------------------------------
        pub fn loadSegment(self: *Self, seg: Seg, selector: u16) void {
            segmentation.loadRealMode(self, seg, selector);
        }

        // -------------------------------------------------------------------
        // Fault raising (D10). Records pending_fault and returns error.Fault.
        // -------------------------------------------------------------------
        pub fn raiseFault(self: *Self, vector: u8, class: state.FaultClass, error_code: ?u32) CpuError {
            self.st.pending_fault = .{ .vector = vector, .class = class, .error_code = error_code };
            return error.Fault;
        }

        /// Shutdown sink (triple-fault). The machine decides reset policy; if the
        /// scheduler implements `onShutdown`, notify it. The CPU never resets
        /// itself — `st.shutdown` is the serializable signal.
        pub fn sched_onShutdown(self: *Self) void {
            if (comptime @hasDecl(opts.Scheduler, "onShutdown")) {
                self.sched.onShutdown();
            }
        }

        // -------------------------------------------------------------------
        // The primitive: step() (D11).
        // -------------------------------------------------------------------
        pub fn step(self: *Self) StepResult {
            return interrupts.step(self);
        }

        /// Fast-forward the idle (HLT) cycle ledger to an absolute cycle target.
        ///
        /// The CPU is the SOLE writer of `st.cycles` (the determinism ledger); the
        /// machine must NEVER poke `st.cycles` directly. On a `.halted` stop the
        /// machine computes the next scheduled event cycle (a pure function of the
        /// deterministic event schedule — never host time) and calls this so the
        /// idle span is charged through the CPU. `to_cycle` must be >= the current
        /// ledger (idle never rewinds time); a target at-or-before now is a no-op.
        /// This closes the cpu.md-deferred D11 HLT/idle-accounting boundary.
        pub fn fastForwardIdle(self: *Self, to_cycle: u64) void {
            std.debug.assert(self.st.halted); // only valid while halted (idle)
            if (to_cycle > self.st.cycles) self.st.cycles = to_cycle;
        }

        /// Thin wrapper: run at least `n` cycles (loops step()).
        pub fn runCycles(self: *Self, n: u64) StopReason {
            const target = self.st.cycles + n;
            while (self.st.cycles < target) {
                const r = self.step();
                if (r.stop_reason == .shutdown) return .shutdown;
            }
            return .normal;
        }

        /// Thin wrapper: run until `predicate(self)` is true (loops step()).
        pub fn runUntil(self: *Self, predicate: *const fn (*Self) bool) StopReason {
            while (!predicate(self)) {
                const r = self.step();
                if (r.stop_reason == .shutdown) return .shutdown;
            }
            return .normal;
        }

        // -------------------------------------------------------------------
        // Inspect / patch surface (MCP debugger).
        // -------------------------------------------------------------------
        pub fn readReg32(self: *const Self, r: Reg32) u32 {
            return self.st.getReg32(@intFromEnum(r));
        }
        pub fn writeReg32(self: *Self, r: Reg32, v: u32) void {
            self.st.setReg32(@intFromEnum(r), v);
        }
        pub fn readSegSelector(self: *const Self, s: Seg) u16 {
            return self.st.selector[@intFromEnum(s)];
        }
        pub fn readFlags(self: *const Self) Flags {
            return self.st.eflags;
        }
        pub fn patchEip(self: *Self, v: u32) void {
            self.st.eip = v;
        }

        /// Read memory by CPU-segmented (logical seg:offset) view.
        pub fn readLogical8(self: *Self, seg: Seg, off: u32) u8 {
            const lin = self.st.seg_base[@intFromEnum(seg)] +% off;
            return self.readLinear8(lin);
        }
        pub fn patchLogical8(self: *Self, seg: Seg, off: u32, v: u8) void {
            const lin = self.st.seg_base[@intFromEnum(seg)] +% off;
            self.writeLinear8(lin, v);
        }
        /// Read/patch memory by bus-physical view.
        pub fn readPhysical8(self: *Self, phys: u32) u8 {
            return self.bus.readPhys8(phys);
        }
        pub fn patchPhysical8(self: *Self, phys: u32, v: u8) void {
            self.bus.writePhys8(phys, v);
        }
    };
}

// ---------------------------------------------------------------------------
// Smoke tests (M0 gate).
// ---------------------------------------------------------------------------

test "Cpu(TestBus) instantiates, resets, reports reset-vector state" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = NullPic{};
    var sched = NullScheduler{};
    var cpu = Cpu(TestBus).init(&bus, &pic, &sched);
    try std.testing.expectEqual(@as(u32, 0xFFF0), cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 0xF000), cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), cpu.st.seg_base[@intFromEnum(Seg.cs)]);
}

test "public inspect/patch surface" {
    var bus = TestBus.init(std.testing.allocator);
    defer bus.deinit();
    var pic = NullPic{};
    var sched = NullScheduler{};
    var cpu = Cpu(TestBus).init(&bus, &pic, &sched);
    cpu.writeReg32(.eax, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), cpu.readReg32(.eax));
    cpu.patchEip(0x1000);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.st.eip);
    cpu.patchPhysical8(0x500, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), cpu.readPhysical8(0x500));
}
