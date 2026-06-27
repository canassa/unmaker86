//! Control-flow branch trace + trap (docs/branch-trace-plan.md).
//!
//! A per-machine fixed ring buffer that records COMPUTED-TARGET control transfers
//! as they execute (`ret`/`iret`, indirect `call`/`jmp`, far transfers, near-direct
//! `call`, and IVT interrupt deliveries) so an operator can find WHERE guest control
//! derailed — plus a stop-on-matching-transfer TRAP that latches the first transfer
//! matching a predicate so the controller can pause AT the derail.
//!
//! It is a PURE host-side observer (CLAUDE prime directive): integer POD only, no
//! allocation, no host clock/RNG, ZERO effect on executed cycles or guest state. The
//! recording is gated by `armed` (a plain bool) and the trap match is an integer test
//! on the just-built entry — neither charges a cycle nor takes a guest-state branch.
//! `trace = f(execution)`, so two identical runs produce byte-identical traces.

const std = @import("std");

/// The fixed ring depth (docs/branch-trace-plan.md §2). A generous, per-machine slab —
/// no allocation. A full 4096-entry ring pages out in 4 dump requests (`MAX_TRACE_DUMP
/// = 1024`).
pub const TRACE_CAPACITY = 4096;

/// The kind tag of a recorded transfer. Encoded as `u8` in `BranchEntry` (the `1 <<
/// kind` mask bit selects it for recording / trapping). EXCLUDES the static intra-
/// function edges (`jcc`/near-`jmp`/`loop*`) — they are not hooked.
pub const BranchKind = enum(u8) {
    call_near_direct = 0, // E8 — default-ON call-chain context
    ret_near = 1, // C3 / C2
    ret_far = 2, // CB / CA
    iret = 3, // CF
    call_near_ind = 4, // FF /2
    jmp_near_ind = 5, // FF /4
    call_far = 6, // 9A
    call_far_ind = 7, // FF /3
    jmp_far = 8, // EA
    jmp_far_ind = 9, // FF /5
    interrupt = 10, // any IVT delivery (deliverViaIvt)
};

/// One recorded transfer — lean integer POD (no register/stack dumps). `from` is the
/// transferring instruction's own CS:IP; `to` is the freshly-committed target CS:IP;
/// `sp` is the post-transfer SP (stack-corruption is the leading crash hypothesis and
/// the field the SP-range trap tests); `at_cycle` is the ledger value (the stable
/// reveal coordinate). All real-mode 16-bit (IP masked with `ipMask`=0xFFFF).
pub const BranchEntry = struct {
    kind: u8 = 0, // BranchKind
    from_cs: u16 = 0,
    from_ip: u16 = 0,
    to_cs: u16 = 0,
    to_ip: u16 = 0,
    sp: u16 = 0,
    at_cycle: u64 = 0,
};

/// The stop-on-matching-transfer predicate — pure POD, evaluated in `push` after the
/// entry is built. OR semantics across the enabled clauses (stop at the first sign of
/// trouble). Integer-only, side-effect-free.
pub const TrapPredicate = struct {
    /// Master gate, independent of the record `armed`: a caller can trap on kinds it
    /// does not record.
    armed: bool = false,

    // (a) target OUTSIDE a linear code range — catches a transfer into data/garbage.
    to_range: bool = false,
    to_lo: u32 = 0,
    to_hi: u32 = 0xFFFFF, // trap if to_lin < to_lo OR to_lin > to_hi

    // (b) SP OUTSIDE a stack-bounds range — catches SP corruption. Real-mode offset-
    //     only (does not account for an SS reload); documented limitation, not a silent
    //     degrade (docs/branch-trace-plan.md §4.1b).
    sp_range: bool = false,
    sp_lo: u16 = 0,
    sp_hi: u16 = 0xFFFF, // trap if e.sp < sp_lo OR e.sp > sp_hi

    // (c) KIND mask — stop on any iret / any indirect jmp / etc.
    kind_match: bool = false,
    kind_trap_mask: u16 = 0, // trap if (1 << e.kind) & kind_trap_mask != 0

    pub fn matches(self: *const TrapPredicate, e: BranchEntry) bool {
        if (self.to_range) {
            // Same (cs<<4)+ip formula the execution-breakpoint matcher uses.
            const to_lin = (@as(u32, e.to_cs) << 4) +% e.to_ip;
            if (to_lin < self.to_lo or to_lin > self.to_hi) return true;
        }
        if (self.sp_range) {
            if (e.sp < self.sp_lo or e.sp > self.sp_hi) return true;
        }
        if (self.kind_match) {
            if ((self.kind_trap_mask >> @as(u4, @intCast(e.kind))) & 1 == 1) return true;
        }
        return false;
    }
};

/// The per-machine ring + trap. Owned by the `Machine` (a plain field, NOT in
/// `Machine.Snapshot` — observer state, like the controller's breakpoints). The CPU
/// reaches it via an optional back-pointer wired in `Machine.wire`.
pub const BranchTrace = struct {
    entries: [TRACE_CAPACITY]BranchEntry = @splat(.{}),
    head: u32 = 0, // next write slot
    len: u32 = 0, // valid entries, saturates at TRACE_CAPACITY
    total: u64 = 0, // monotonic count of all recorded transfers
    armed: bool = false, // record gate; default OFF (zero overhead until armed)
    kind_mask: u16 = 0xFFFF, // kind filter; default = all kinds (incl. call_near_direct)

    trap: TrapPredicate = .{}, // independent of `armed`
    trap_hit: ?BranchEntry = null, // latched on first match; consumed by the controller

    /// Record a transfer (and evaluate the trap). Called at the transfer site, after
    /// the target is committed to `State`. Pure: no allocation, no host clock, no
    /// guest-state branch.
    pub fn push(self: *BranchTrace, e: BranchEntry) void {
        // (1) TRAP first — evaluated on EVERY transfer, independent of the record gate,
        //     so a caller can trap on kinds it does not record. Latch the FIRST match
        //     only (a flurry of post-derail garbage cannot overwrite the culprit).
        if (self.trap.armed and self.trap_hit == null and self.trap.matches(e)) {
            self.trap_hit = e;
        }
        // (2) RECORD — gated by `armed` + `kind_mask`.
        if (!self.armed) return;
        if ((self.kind_mask >> @as(u4, @intCast(e.kind))) & 1 == 0) return;
        self.entries[self.head] = e;
        self.head = (self.head + 1) % TRACE_CAPACITY;
        if (self.len < TRACE_CAPACITY) self.len += 1;
        self.total += 1;
    }

    /// Clear the ring CONTENTS + a stale trap latch; leaves the config (`armed`,
    /// `kind_mask`, `trap` predicate) untouched. Used by the controller on `restore`
    /// (a new timeline) and by `resetTimeline` (a power-on).
    pub fn clear(self: *BranchTrace) void {
        self.head = 0;
        self.len = 0;
        self.total = 0;
        self.trap_hit = null;
    }

    /// Power-on contents clear (docs/branch-trace-plan.md §3 reset semantics): zero the
    /// timeline data but PRESERVE the observer config (armed/kind_mask/trap), mirroring
    /// how breakpoints survive a machine reset. Identical to `clear` today; named
    /// separately so the reset call site reads as intent.
    pub fn resetTimeline(self: *BranchTrace) void {
        self.clear();
    }

    /// Copy up to `out.len` entries oldest→newest (or reversed) into `out`, starting at
    /// chronological `offset` from the oldest valid entry. Returns the filled prefix. A
    /// pure copy (no allocation, no mutation). The ring's oldest valid slot is
    /// `(head - len)` mod capacity; `total` lets the caller compute absolute indices.
    pub fn copyOut(self: *const BranchTrace, out: []BranchEntry, offset: u32, newest_first: bool) []BranchEntry {
        if (self.len == 0 or offset >= self.len) return out[0..0];
        const avail = self.len - offset;
        const n = @min(@as(u32, @intCast(out.len)), avail);
        const oldest = (self.head + TRACE_CAPACITY - self.len) % TRACE_CAPACITY;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // chronological position from the oldest valid entry
            const chrono = if (newest_first) (self.len - 1 - offset - i) else (offset + i);
            const idx = (oldest + chrono) % TRACE_CAPACITY;
            out[i] = self.entries[idx];
        }
        return out[0..n];
    }

    /// The absolute index (in the monotonic `total` space) of the chronological entry at
    /// `offset` from the oldest valid entry. The oldest valid entry's absolute index is
    /// `total - len`. Used so a dump row reports a stable, wrap-aware index.
    pub fn absIndexAt(self: *const BranchTrace, chrono_from_oldest: u32) u64 {
        return self.total - self.len + chrono_from_oldest;
    }
};

test "push records gated by armed + kind_mask" {
    var t: BranchTrace = .{};
    // Disarmed: nothing recorded.
    t.push(.{ .kind = @intFromEnum(BranchKind.ret_near), .to_cs = 1, .to_ip = 2 });
    try std.testing.expectEqual(@as(u32, 0), t.len);

    t.armed = true;
    t.push(.{ .kind = @intFromEnum(BranchKind.ret_near), .to_cs = 1, .to_ip = 2, .at_cycle = 5 });
    try std.testing.expectEqual(@as(u32, 1), t.len);
    try std.testing.expectEqual(@as(u64, 1), t.total);

    // Mask off ret_near: it is now skipped, but call_near_direct still records.
    t.kind_mask = ~(@as(u16, 1) << @intFromEnum(BranchKind.ret_near));
    t.push(.{ .kind = @intFromEnum(BranchKind.ret_near) });
    try std.testing.expectEqual(@as(u32, 1), t.len); // unchanged
    t.push(.{ .kind = @intFromEnum(BranchKind.call_near_direct) });
    try std.testing.expectEqual(@as(u32, 2), t.len);
}

test "ring wraps and copyOut is chronological" {
    var t: BranchTrace = .{};
    t.armed = true;
    var i: u32 = 0;
    while (i < TRACE_CAPACITY + 10) : (i += 1) {
        t.push(.{ .kind = @intFromEnum(BranchKind.call_near_direct), .to_ip = @truncate(i), .at_cycle = i });
    }
    try std.testing.expectEqual(@as(u32, TRACE_CAPACITY), t.len);
    try std.testing.expectEqual(@as(u64, TRACE_CAPACITY + 10), t.total);

    var buf: [4]BranchEntry = undefined;
    // newest-first: the most recent push had at_cycle = TRACE_CAPACITY+9.
    const newest = t.copyOut(&buf, 0, true);
    try std.testing.expectEqual(@as(u64, TRACE_CAPACITY + 9), newest[0].at_cycle);
    try std.testing.expectEqual(@as(u64, TRACE_CAPACITY + 8), newest[1].at_cycle);
    // oldest-first: the oldest surviving entry is at_cycle = 10 (0..9 evicted).
    const oldest = t.copyOut(&buf, 0, false);
    try std.testing.expectEqual(@as(u64, 10), oldest[0].at_cycle);
}

test "trap latches the first matching transfer only" {
    var t: BranchTrace = .{};
    t.trap = .{ .armed = true, .to_range = true, .to_lo = 0x1000, .to_hi = 0x2000 };
    // In range: no trap.
    t.push(.{ .to_cs = 0x100, .to_ip = 0x500 }); // lin 0x1500
    try std.testing.expect(t.trap_hit == null);
    // Out of range (below): trap latches.
    t.push(.{ .kind = @intFromEnum(BranchKind.ret_near), .to_cs = 0, .to_ip = 0x10, .at_cycle = 7 });
    try std.testing.expect(t.trap_hit != null);
    try std.testing.expectEqual(@as(u64, 7), t.trap_hit.?.at_cycle);
    // A second out-of-range transfer must NOT overwrite the latch.
    t.push(.{ .kind = @intFromEnum(BranchKind.ret_far), .to_cs = 0xF000, .to_ip = 0xFFFF, .at_cycle = 99 });
    try std.testing.expectEqual(@as(u64, 7), t.trap_hit.?.at_cycle);
}

test "sp_range and kind_match trap clauses" {
    var t: BranchTrace = .{};
    t.trap = .{ .armed = true, .sp_range = true, .sp_lo = 0x100, .sp_hi = 0xF000 };
    t.push(.{ .sp = 0x800 }); // in bounds
    try std.testing.expect(t.trap_hit == null);
    t.push(.{ .sp = 0x10, .at_cycle = 3 }); // below sp_lo
    try std.testing.expectEqual(@as(u64, 3), t.trap_hit.?.at_cycle);

    var k: BranchTrace = .{};
    k.trap = .{ .armed = true, .kind_match = true, .kind_trap_mask = @as(u16, 1) << @intFromEnum(BranchKind.iret) };
    k.push(.{ .kind = @intFromEnum(BranchKind.ret_near) }); // not iret
    try std.testing.expect(k.trap_hit == null);
    k.push(.{ .kind = @intFromEnum(BranchKind.iret), .at_cycle = 42 });
    try std.testing.expectEqual(@as(u64, 42), k.trap_hit.?.at_cycle);
}

test "clear wipes contents but keeps config" {
    var t: BranchTrace = .{};
    t.armed = true;
    t.kind_mask = 0x00FF;
    t.trap = .{ .armed = true, .to_range = true, .to_lo = 1, .to_hi = 2 };
    t.push(.{ .to_cs = 0, .to_ip = 0, .at_cycle = 1 }); // out of [1,2] -> latches
    try std.testing.expect(t.trap_hit != null);
    t.clear();
    try std.testing.expectEqual(@as(u32, 0), t.len);
    try std.testing.expectEqual(@as(u64, 0), t.total);
    try std.testing.expect(t.trap_hit == null);
    // config survives
    try std.testing.expect(t.armed);
    try std.testing.expectEqual(@as(u16, 0x00FF), t.kind_mask);
    try std.testing.expect(t.trap.armed);
}
