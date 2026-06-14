//! Real-mode segmentation: the single access-path choke point
//! `checkSegmentAccess()` (Theme F) and the real-mode segment load.
//!
//! In real mode this does ONLY the limit/wrap check and returns the linear
//! address; it is the one place PM permission checks (read/write/exec, DPL/CPL)
//! slot in later. There is NO reference-emulator oracle for the real-mode limit
//! fault — pin with hand-written vectors (Phase 8).

const std = @import("std");
const state = @import("state.zig");

pub const AccessKind = enum { read, write, exec };

/// Translate logical (seg:offset) -> linear, checking the real-mode segment
/// limit. Faults iff the LAST byte's effective offset (ea + size - 1) exceeds
/// the cached limit. 16-bit-addressing offset wrap (mod 2^16) is masked by the
/// caller and does NOT fault here — the check is on the last-byte offset.
///
/// Fault selection: #SS(0) for SS-relative accesses, #GP(0) otherwise.
pub fn checkSegmentAccess(
    cpu: anytype,
    seg: state.Seg,
    offset: u32,
    size: u32,
    kind: AccessKind,
) !u32 {
    _ = kind; // real mode: no permission check (CPL=0). PM seam.
    const i = @intFromEnum(seg);
    const limit = cpu.st.seg_limit[i];
    // Last byte accessed. size >= 1 always.
    const last = offset +% (size - 1);
    // Limit violation predicate (Theme D): last-byte offset > limit. Note the
    // comparison is on the (already addr-size-masked) offset supplied by the
    // caller, against the cached limit.
    if (last > limit or last < offset) {
        // last < offset means the access itself wrapped past the 4 GiB end,
        // which is also a violation for a non-wrapping limit.
        const vector: u8 = if (seg == .ss) 12 else 13; // #SS(0) / #GP(0)
        return cpu.raiseFault(vector, .fault, 0);
    }
    return cpu.st.seg_base[i] +% offset;
}

/// Real-mode segment load: base = selector << 4 ONLY (D4). The limit is NOT
/// reset (preserves unreal/flat-real mode); it was set to 0xFFFF at reset.
/// Default cold descriptor flags are written once here but never read on access.
pub fn loadRealMode(cpu: anytype, seg: state.Seg, selector: u16) void {
    const i = @intFromEnum(seg);
    cpu.st.selector[i] = selector;
    cpu.st.seg_base[i] = @as(u32, selector) << 4;
    // Cold PM-shaped defaults (written once, unread in real mode).
    cpu.st.seg_desc[i] = .{};
}

test "checkSegmentAccess within limit returns base+offset" {
    const TestCpu = struct {
        st: state.State = .{},
        pub fn raiseFault(self: *@This(), v: u8, c: state.FaultClass, ec: ?u32) anyerror {
            self.st.pending_fault = .{ .vector = v, .class = c, .error_code = ec };
            return error.Fault;
        }
    };
    var cpu = TestCpu{};
    cpu.st.seg_base[@intFromEnum(state.Seg.ds)] = 0x1000;
    cpu.st.seg_limit[@intFromEnum(state.Seg.ds)] = 0xFFFF;
    const lin = try checkSegmentAccess(&cpu, .ds, 0x10, 4, .read);
    try std.testing.expectEqual(@as(u32, 0x1010), lin);
}

test "checkSegmentAccess past limit faults #GP" {
    const TestCpu = struct {
        st: state.State = .{},
        pub fn raiseFault(self: *@This(), v: u8, c: state.FaultClass, ec: ?u32) anyerror {
            self.st.pending_fault = .{ .vector = v, .class = c, .error_code = ec };
            return error.Fault;
        }
    };
    var cpu = TestCpu{};
    cpu.st.seg_limit[@intFromEnum(state.Seg.ds)] = 0xFFFF;
    try std.testing.expectError(error.Fault, checkSegmentAccess(&cpu, .ds, 0xFFFF, 2, .read));
    try std.testing.expectEqual(@as(u8, 13), cpu.st.pending_fault.?.vector);
}

test "checkSegmentAccess SS-relative past limit faults #SS" {
    const TestCpu = struct {
        st: state.State = .{},
        pub fn raiseFault(self: *@This(), v: u8, c: state.FaultClass, ec: ?u32) anyerror {
            self.st.pending_fault = .{ .vector = v, .class = c, .error_code = ec };
            return error.Fault;
        }
    };
    var cpu = TestCpu{};
    cpu.st.seg_limit[@intFromEnum(state.Seg.ss)] = 0xFFFF;
    try std.testing.expectError(error.Fault, checkSegmentAccess(&cpu, .ss, 0xFFFF, 4, .write));
    try std.testing.expectEqual(@as(u8, 12), cpu.st.pending_fault.?.vector);
}

test "loadRealMode sets base from sel<<4 without touching limit" {
    const TestCpu = struct { st: state.State = .{} };
    var cpu = TestCpu{};
    cpu.st.reset();
    loadRealMode(&cpu, .ds, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x12340), cpu.st.seg_base[@intFromEnum(state.Seg.ds)]);
    // limit preserved (unreal mode invariant).
    try std.testing.expectEqual(@as(u32, 0xFFFF), cpu.st.seg_limit[@intFromEnum(state.Seg.ds)]);
}
