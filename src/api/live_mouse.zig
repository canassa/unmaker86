//! `LiveMouseState` — the coalesced latest-input record for the LIVE browser mouse
//! (plans/mouse-input.md §3, LOCKED §1/§5/§6). This is the low-latency ingest buffer
//! that decouples a `POST /api/input/mouse` from the worker: the POST handler folds
//! each move into THIS mutable record (absolute OVERWRITE, relative SUM, latest
//! buttons) without enqueuing a command or touching the submit-gate, and the pacer's
//! slice boundary later drains it through `takeFold()` → `input_mouse_fold` → the
//! `Controller.injectMouseSeamless` seam.
//!
//! WHERE IT SITS (LOCKED §1 — the BLOCKER the review caught): this lives in `src/api`,
//! a SIBLING of `run_control.zig`. The fold runs on the api/worker side (the
//! `input_mouse_fold` arm in `worker.zig`, which already holds `ctrl`): it reads this
//! api-layer record, decodes to PLAIN INTEGERS, and calls `Controller.injectMouseSeamless`
//! (which is `src/debug`, BELOW `src/api`). A `Controller` FIELD of type `*LiveMouseState`
//! would be a circular `debug → api` import that won't compile — so the record stays
//! api-side and the integers flow DOWN through the existing controller seam. No
//! `debug → api` import anywhere.
//!
//! Determinism (CLAUDE prime directive + #4; LOCKED §8): this is TRANSIENT host-side
//! ARRIVAL state — NOT machine state, NOT in `Machine.Snapshot`. Mutating it touches no
//! guest cycle (the POST never advances the machine). The keystone invariant: NO live
//! input ⇒ `takeFold()` returns null ⇒ the fold arm runs no `runUntilEvent` ⇒ ZERO
//! added cycles ⇒ byte-identical to today. The headless/scripted path never constructs
//! a `LiveMouseState`, so it is provably unaffected. The wire/stored math is exact
//! INTEGER (Q16 fixed-point) — no host floats (the `src/api` determinism grep bans the
//! float types); this file is `@embedFile`d by `determinism_test.zig`.
//!
//! Concurrency (LOCKED §5/§6): a CLOCKLESS `Io.Mutex` (`lockUncancelable`, the
//! no-timeout variant — no clock enters the api grep-gate) guards the whole record.
//! `ingest*` take it to mutate; `takeFold` takes it to snapshot+clear and returns null
//! UNDER THE LOCK when not dirty. There is no unsynchronized cross-thread `dirty_seq`
//! peek: the pacer ALWAYS submits `input_mouse_fold` each slice and the fold arm asks
//! `takeFold()`, which is the single race-free gate.

const std = @import("std");
const Io = std.Io;

/// The coalesced latest-input record (POD, pointer-free, mutex-guarded). One per
/// server, shared by the mouse POST handler (write) and the worker's fold arm (read).
pub const LiveMouseState = struct {
    /// Guards the whole record. CLOCKLESS (`lockUncancelable`/`unlock`, no timeout) so
    /// no clock affordance enters the api grep-gate. Short critical sections only.
    mutex: Io.Mutex = .init,

    /// Held once at construction (mirror `RunControl.init(io)` / `SharedFrame.init(io)`)
    /// so the `ingest*`/`takeFold` helpers need no `io` argument: an uncontended
    /// lock/unlock is a CAS pair; only a contended wait touches a bare futex (no clock).
    io: Io,

    // --- ABSOLUTE (overwritten) -------------------------------------------------
    /// Latest normalized absolute position over the CONTAINED image rect, Q16 fixed-
    /// point in [0, 0x1_0000] == [0.0, 1.0]. Stored NORMALIZED so the SERVER (the fold,
    /// via the driver's live range) owns the per-mode ×MaxPos scaling — one place keeps
    /// the range correct as the video mode changes (LOCKED §2/§7). OVERWRITTEN on each
    /// ingest: stale intermediate positions are dropped (only the freshest survives).
    abs_x_q16: u32 = 0,
    abs_y_q16: u32 = 0,
    have_abs: bool = false,

    // --- RELATIVE (summed) ------------------------------------------------------
    /// Accumulated TRUE relative deltas from the browser's `movementX/movementY`
    /// channel (LOCKED §3) — the real mickey source, NOT derived from the absolute Δ.
    /// SUMMED so no motion is lost between folds. Wrapping add (a fold consumes + zeroes
    /// them; an unfolded overflow over a 10 ms slice is not physically reachable).
    dx_sum: i32 = 0,
    dy_sum: i32 = 0,
    have_rel: bool = false,

    // --- BUTTONS (latest) -------------------------------------------------------
    /// Latest button mask: bit0=left, bit1=right, bit2=middle (matches the INT 33h /
    /// `MouseInject` layout). LATEST wins.
    buttons: u16 = 0,
    have_buttons: bool = false,

    // --- fold gate --------------------------------------------------------------
    /// Monotone seq bumped on every mutate. `takeFold` compares it to `last_folded_seq`
    /// UNDER THE LOCK and returns null when unchanged (the race-free gate, LOCKED §5).
    dirty_seq: u64 = 0,
    last_folded_seq: u64 = 0,

    /// One drained, coalesced sample — PLAIN INTEGERS the fold arm forwards to
    /// `Controller.injectMouseSeamless`. The Q16 absolute is carried as-is (the driver
    /// owns the ×range mapping, so the api layer never imports `int33`'s range); the
    /// relative deltas are the raw summed `movementX/Y`.
    pub const Fold = struct {
        abs_x_q16: u32,
        abs_y_q16: u32,
        dx: i32,
        dy: i32,
        buttons: u16,
        set_abs: bool,
        set_rel: bool,
        set_buttons: bool,
    };

    pub fn init(io: Io) LiveMouseState {
        return .{ .io = io };
    }

    /// Ingest a normalized ABSOLUTE position (Q16, clamped 0..0x1_0000 by the caller).
    /// OVERWRITE semantics: a later absolute replaces any pending one (no stale replay).
    pub fn ingestAbs(self: *LiveMouseState, nx_q16: u32, ny_q16: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.abs_x_q16 = nx_q16;
        self.abs_y_q16 = ny_q16;
        self.have_abs = true;
        self.dirty_seq +%= 1;
    }

    /// Ingest a RELATIVE delta (the browser's true `movementX/Y` channel). SUM
    /// semantics: deltas accumulate so a fold consumes the total motion, never a stale
    /// fraction.
    pub fn ingestRel(self: *LiveMouseState, dx: i32, dy: i32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dx_sum +%= dx;
        self.dy_sum +%= dy;
        self.have_rel = true;
        self.dirty_seq +%= 1;
    }

    /// Ingest the LATEST button mask.
    pub fn ingestButtons(self: *LiveMouseState, mask: u16) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.buttons = mask;
        self.have_buttons = true;
        self.dirty_seq +%= 1;
    }

    /// Ingest a combined event (absolute and/or relative and/or buttons) under ONE lock
    /// so a click that also carries a position folds as a single coalesced mutate — and
    /// an ingest between the worker's read and clear cannot be lost (LOCKED §5 lock
    /// correctness). `set_*` gate which fields apply.
    pub fn ingest(
        self: *LiveMouseState,
        nx_q16: u32,
        ny_q16: u32,
        dx: i32,
        dy: i32,
        mask: u16,
        set_abs: bool,
        set_rel: bool,
        set_buttons: bool,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (set_abs) {
            self.abs_x_q16 = nx_q16;
            self.abs_y_q16 = ny_q16;
            self.have_abs = true;
        }
        if (set_rel) {
            self.dx_sum +%= dx;
            self.dy_sum +%= dy;
            self.have_rel = true;
        }
        if (set_buttons) {
            self.buttons = mask;
            self.have_buttons = true;
        }
        if (set_abs or set_rel or set_buttons) self.dirty_seq +%= 1;
    }

    /// Drain the coalesced record (worker side, once per fold cadence tick). Locks,
    /// returns null UNDER THE LOCK when nothing changed since the last fold (the
    /// race-free gate — zero guest cycles when clean, LOCKED §5), otherwise snapshots
    /// the latest absolute + the SUMMED relative + latest buttons, CLEARS the deltas /
    /// `have_*` flags, marks the seq folded, and returns the `Fold`. The summed deltas
    /// are consumed EXACTLY ONCE (reset to 0 here): no double-count, no loss.
    pub fn takeFold(self: *LiveMouseState) ?Fold {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.dirty_seq == self.last_folded_seq) return null;

        const fold: Fold = .{
            .abs_x_q16 = self.abs_x_q16,
            .abs_y_q16 = self.abs_y_q16,
            .dx = self.dx_sum,
            .dy = self.dy_sum,
            .buttons = self.buttons,
            .set_abs = self.have_abs,
            .set_rel = self.have_rel,
            .set_buttons = self.have_buttons,
        };
        // Consume the summed relative exactly once; clear the per-field present flags.
        // The absolute value itself is left in place (harmless — a later fold without a
        // new absolute won't re-apply it because `have_abs` is cleared and `dirty_seq`
        // gates re-entry).
        self.dx_sum = 0;
        self.dy_sum = 0;
        self.have_abs = false;
        self.have_rel = false;
        self.have_buttons = false;
        self.last_folded_seq = self.dirty_seq;
        return fold;
    }
};

// ===========================================================================
// Tests — coalescing + concurrency (no machine; pure record behavior).
// ===========================================================================

const testing = std.testing;

test "coalescing: stale absolute positions dropped, latest survives" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    s.ingestAbs(0x1000, 0x2000);
    s.ingestAbs(0x3000, 0x4000);
    s.ingestAbs(0x5000, 0x6000); // the latest

    const f = s.takeFold().?;
    try testing.expect(f.set_abs);
    try testing.expectEqual(@as(u32, 0x5000), f.abs_x_q16);
    try testing.expectEqual(@as(u32, 0x6000), f.abs_y_q16);
}

test "coalescing: relative deltas summed, not lost" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    s.ingestRel(3, 1);
    s.ingestRel(4, -2);
    s.ingestRel(-2, 5); // sum: dx=+5, dy=+4

    const f = s.takeFold().?;
    try testing.expect(f.set_rel);
    try testing.expectEqual(@as(i32, 5), f.dx);
    try testing.expectEqual(@as(i32, 4), f.dy);
}

test "fold gate: clean record yields null (zero-cycle keystone)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    // No ingest yet → null.
    try testing.expect(s.takeFold() == null);

    s.ingestAbs(0x8000, 0x8000);
    try testing.expect(s.takeFold() != null);
    // A second fold with no new ingest → null again (the gate).
    try testing.expect(s.takeFold() == null);
}

test "fold consumes summed relative exactly once" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    s.ingestRel(10, 20);
    const f1 = s.takeFold().?;
    try testing.expectEqual(@as(i32, 10), f1.dx);
    try testing.expectEqual(@as(i32, 20), f1.dy);

    // New motion after the fold accumulates from zero.
    s.ingestRel(1, 2);
    const f2 = s.takeFold().?;
    try testing.expectEqual(@as(i32, 1), f2.dx);
    try testing.expectEqual(@as(i32, 2), f2.dy);
}

test "combined ingest folds abs + buttons in one mutate" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    s.ingest(0x4000, 0xC000, 0, 0, 0b001, true, false, true);
    const f = s.takeFold().?;
    try testing.expect(f.set_abs and f.set_buttons and !f.set_rel);
    try testing.expectEqual(@as(u32, 0x4000), f.abs_x_q16);
    try testing.expectEqual(@as(u16, 0b001), f.buttons);
}

test "concurrency: an ingest between read and clear is not lost" {
    // Drive many concurrent ingests against repeated folds and assert the TOTAL summed
    // relative motion is conserved (no delta dropped by a read/clear race). Each fold's
    // dx is added to a running total; the grand total must equal N_ingests * step.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = LiveMouseState.init(io);

    const Ctx = struct {
        s: *LiveMouseState,
        n: usize,
        fn producer(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) ctx.s.ingestRel(1, 0);
        }
    };
    var ctx: Ctx = .{ .s = &s, .n = 100_000 };
    const t = try std.Thread.spawn(.{}, Ctx.producer, .{&ctx});

    var total: i64 = 0;
    // Fold repeatedly while the producer runs and after it joins, accumulating motion.
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (s.takeFold()) |f| total += f.dx;
        // Cheap liveness break: once we've collected everything, stop early.
        if (total == @as(i64, @intCast(ctx.n))) break;
    }
    t.join();
    // Final drain to catch any tail produced after the last fold.
    if (s.takeFold()) |f| total += f.dx;

    try testing.expectEqual(@as(i64, @intCast(ctx.n)), total);
}
