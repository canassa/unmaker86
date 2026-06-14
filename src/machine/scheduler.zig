//! The deterministic, cycle-keyed event queue (M-D2/M-D3/M-D4) — the heart of
//! the machine's reproducibility surface.
//!
//! DESIGN (honoring the DECISIONS literally):
//!   - M-D2: every event is keyed on an absolute `fire_cycle: u64` derived from
//!     the CPU cycle ledger + an integer delta. NEVER host time / ms / floats.
//!   - M-D3: a FIXED-CAPACITY `[capacity]Event` array scanned linearly for the
//!     minimum — not a binary heap (whose post-sift order is not a documented
//!     stable function of insertion order, a determinism footgun). N is tiny so
//!     O(n) beats heap overhead and snapshots as plain bytes.
//!   - M-D4: same-cycle tie-break is a STRICT TOTAL ORDER `(fire_cycle ASC, then
//!     seq ASC)`. `seq` is a u64 incremented on every `schedule` and snapshotted,
//!     so the minimum is always unique and reproducible across runs/restore.
//!   - M-D11: events carry a STABLE `(source_id, kind)` — NO function pointer.
//!     The machine re-binds `(source_id, kind)` -> callback at dispatch/restore.
//!   - "<=1 live event per `(source_id, kind)`": asserted in `schedule`, so
//!     `cancel` degenerates to cancel-one (removing the slot-order dependence
//!     M-D4 rejects).
//!
//! The scheduler is PURE DATA + integer math. It does not read the CPU directly;
//! the machine passes the current cycle (`now == cpu.st.cycles`) into `schedule`
//! and `fireDue`, keeping the CPU the single time source while the queue stays a
//! decoupled, testable, snapshot-trivial structure.

const std = @import("std");

/// Names the device source of a scheduled event (M-D11). Stable across snapshot/
/// restore — the machine maps `(source_id, kind)` -> the device callback, so no
/// host function pointer is ever serialized. Extend as devices land (pit_ch2,
/// kbd, mouse, sound, ...).
pub const EventKind = enum(u8) {
    pit_ch0,
    pit_ch1,
    pit_ch2,
};

/// One scheduled event. Plain old data — snapshots verbatim (incl. `seq`).
pub const Event = struct {
    /// Absolute CPU cycle at/after which the event fires (M-D2).
    fire_cycle: u64,
    /// Strict total-order tie-break key (M-D4): lower `seq` == scheduled first.
    seq: u64,
    /// Stable device id (M-D11) — e.g. the PIT's id. With `kind` it resolves to
    /// the callback at dispatch; no function pointer stored.
    source_id: u16,
    /// Event source kind (M-D11).
    kind: EventKind,
    /// Opaque per-event payload (e.g. a channel selector); device-defined.
    val: u32,
};

/// Capacity sized from the FULL device roster (M-D3): PIT ch0/ch1/ch2 + keyboard
/// + mouse + sound + margin. 32 is comfortably above that with headroom; the
/// linear scan over so few slots is trivially cheap and deterministic. Overflow
/// is a LOUD assert (never a silent drop — ground rule / CLAUDE #1).
pub const capacity: usize = 32;

comptime {
    // Size locks (M-D3): catch an accidental field bloat / capacity change. The
    // two u64s dominate; (source_id u16 | kind u8 | val u32) pack into the third
    // 8-byte word -> 24 bytes total.
    std.debug.assert(@sizeOf(Event) == 24);
    std.debug.assert(capacity == 32);
}

pub const Scheduler = struct {
    /// Dense live-prefix array: slots `[0, active)` are live, scanned for the min.
    events: [capacity]Event = undefined,
    /// Number of live events (the live prefix length).
    active: u32 = 0,
    /// Monotonic schedule counter — the M-D4 total-order key. Snapshotted so
    /// restore reproduces firing order exactly (M-D11).
    next_seq: u64 = 0,
    /// PIT-style fractional-remainder accumulator (M-D8). Lives here so it is
    /// part of the scheduler snapshot set; the PIT carries it across re-arms.
    /// (At the pinned 12/1 ratio it is always 0, kept for generality.)
    remainder: u64 = 0,

    pub fn reset(self: *Scheduler) void {
        self.* = .{};
    }

    /// The absolute cycle of the next event, or `maxInt(u64)` when empty (matches
    /// `NullScheduler`, which the CPU's HLT fast-forward already handles). This is
    /// the `Scheduler` contract method the CPU queries on HLT and the burst loop
    /// bounds against. Linear scan over the live prefix for the min `(fire_cycle,
    /// seq)` — returns its `fire_cycle`.
    pub fn nextEventCycle(self: *const Scheduler) u64 {
        var best: u64 = std.math.maxInt(u64);
        var best_seq: u64 = std.math.maxInt(u64);
        var i: u32 = 0;
        while (i < self.active) : (i += 1) {
            const e = self.events[i];
            if (e.fire_cycle < best or (e.fire_cycle == best and e.seq < best_seq)) {
                best = e.fire_cycle;
                best_seq = e.seq;
            }
        }
        return best;
    }

    /// Schedule an event `delta_cycles` in the future from `now` (== cpu.st.cycles
    /// — the single time source, M-D2). `delta_cycles` is clamped to >= 1 so an
    /// event can never be scheduled in the past / on the firing cycle of the drain
    /// that scheduled it (mirrors spice86's "avoid events in the past"). Assigns
    /// the next `seq` (the total-order key). Asserts capacity (LOUD overflow, never
    /// a silent drop) AND the "<=1 live per (source_id, kind)" uniqueness invariant.
    pub fn schedule(
        self: *Scheduler,
        now: u64,
        delta_cycles: u64,
        source_id: u16,
        kind: EventKind,
        val: u32,
    ) void {
        const delta = if (delta_cycles >= 1) delta_cycles else 1;
        // Uniqueness invariant (M-D3/M-D4): no live event may share (source_id,
        // kind) — keeps cancel a cancel-one and removes slot-order dependence.
        std.debug.assert(!self.hasLive(source_id, kind));
        std.debug.assert(self.active < capacity); // LOUD overflow (CLAUDE #1)
        const slot = self.active;
        self.events[slot] = .{
            .fire_cycle = now +% delta,
            .seq = self.next_seq,
            .source_id = source_id,
            .kind = kind,
            .val = val,
        };
        self.next_seq += 1;
        self.active += 1;
    }

    /// Cancel the (unique) live event matching `(source_id, kind)`. A no-op if
    /// none is live. Needed when a PIT channel is reprogrammed mid-flight (the old
    /// IRQ0 schedule is canceled and re-armed, Phase 5). Compacts by swapping the
    /// last live slot into the freed one — order-independent because the total
    /// order is `(fire_cycle, seq)`, never slot index (M-D4).
    pub fn cancel(self: *Scheduler, source_id: u16, kind: EventKind) void {
        var i: u32 = 0;
        while (i < self.active) : (i += 1) {
            if (self.events[i].source_id == source_id and self.events[i].kind == kind) {
                self.events[i] = self.events[self.active - 1];
                self.active -= 1;
                return;
            }
        }
    }

    /// True if a live event matches `(source_id, kind)`.
    pub fn hasLive(self: *const Scheduler, source_id: u16, kind: EventKind) bool {
        var i: u32 = 0;
        while (i < self.active) : (i += 1) {
            if (self.events[i].source_id == source_id and self.events[i].kind == kind) return true;
        }
        return false;
    }

    /// Pop the minimum `(fire_cycle, seq)` event IF it is due (`fire_cycle <=
    /// now`), removing it from the queue and returning it; else `null`. The caller
    /// (the machine's `fireDue`) loops this, dispatching each popped event to the
    /// device callback resolved from `(source_id, kind)`. Events are timing-neutral
    /// (M-D7): popping/firing adds NO cycles to the ledger. A callback may
    /// `schedule()` a follow-up whose `fire_cycle` is in the future (delta >= 1),
    /// so it cannot re-fire this drain.
    ///
    /// O(n) re-scan per pop is intentional and bounded at this tiny N (M-D3) — no
    /// heap needed for the BaK device set.
    pub fn popDue(self: *Scheduler, now: u64) ?Event {
        var best_idx: ?u32 = null;
        var best_cycle: u64 = std.math.maxInt(u64);
        var best_seq: u64 = std.math.maxInt(u64);
        var i: u32 = 0;
        while (i < self.active) : (i += 1) {
            const e = self.events[i];
            if (e.fire_cycle > now) continue;
            if (e.fire_cycle < best_cycle or (e.fire_cycle == best_cycle and e.seq < best_seq)) {
                best_cycle = e.fire_cycle;
                best_seq = e.seq;
                best_idx = i;
            }
        }
        const idx = best_idx orelse return null;
        const ev = self.events[idx];
        self.events[idx] = self.events[self.active - 1];
        self.active -= 1;
        return ev;
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (M-D11) — events + next_seq + remainder serialize
    // VERBATIM (incl. each event's seq) so the `(fire_cycle, seq)` order is
    // identical pre/post restore. No renumbering, no compaction, no pointers.
    // -----------------------------------------------------------------------

    pub const Snapshot = struct {
        events: [capacity]Event,
        active: u32,
        next_seq: u64,
        remainder: u64,
    };

    pub fn snapshot(self: *const Scheduler) Snapshot {
        return .{
            .events = self.events,
            .active = self.active,
            .next_seq = self.next_seq,
            .remainder = self.remainder,
        };
    }

    pub fn restore(self: *Scheduler, snap: Snapshot) void {
        self.events = snap.events;
        self.active = snap.active;
        self.next_seq = snap.next_seq;
        self.remainder = snap.remainder;
    }
};
