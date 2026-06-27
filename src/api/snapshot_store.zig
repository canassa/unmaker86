//! Per-session snapshot store (snapshot-restore-plan §2.2/§3). Owns up to
//! `MAX_SNAPSHOTS` checkpoints of the WHOLE machine, each a `Machine.Snapshot` POD
//! plus the five large out-of-band slabs (`bus.ram`, `vga.vram`, the two text pages,
//! and the EMS backing) captured into ONE contiguous heap slab per slot.
//!
//! LAZY SLABS (the §2.2/§3 budget rule): a slot's ~16.31 MiB slab is `gpa.alloc`'d ONLY
//! on the first `capture` that lands in it (and reused on every re-capture into the same
//! slot), so an idle / never-snapshotted session pays ZERO for its slabs — only the
//! small POD slot array (the `Machine.Snapshot` PODs + counters) is allocated up front.
//! The matching teardown rule (`deinit`) frees every non-null slab BEFORE the session
//! frees the store, or the lazy slabs leak.
//!
//! Reached SOLELY from the worker thread (the machine owner) via the worker's
//! `?*SnapshotStore` back-pointer (exactly like `render`/`live_mouse`), so it needs no
//! lock. Determinism (CLAUDE prime directive): handles are `snap-<n>` minted from a
//! monotonic counter — NO host clock, NO RNG, integer-only; capture is a pure read of
//! the machine (cycle-neutral) and restore is a deterministic state load applied at the
//! serialized worker-command boundary.

const std = @import("std");
const q = @import("queue.zig");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

pub const MAX_SNAPSHOTS = q.MAX_SNAPSHOTS;

/// One snapshot slot. `snap` is the by-value machine POD; `slab` is the lazily-allocated
/// out-of-band region buffer (null until the first capture into this slot). A deleted
/// slot keeps its `slab` allocated for reuse (the lazy-alloc payoff) and is freed only
/// at `deinit`.
pub const Slot = struct {
    occupied: bool = false,
    seq: u64 = 0,
    cycle: u64 = 0,
    bytes: u64 = 0,
    slab: ?[]u8 = null,
    snap: Machine.Snapshot = undefined,
};

pub const CaptureError = error{ LimitReached, OutOfMemory };

pub const SnapshotStore = struct {
    gpa: std.mem.Allocator,
    slots: [MAX_SNAPSHOTS]Slot = @splat(.{}),
    /// The monotonic handle minter (`snap-<n>`). Never reused, never reset — clockless,
    /// RNG-free (mirrors the session registry's `zdos-sess-<seq>` discipline).
    next_seq: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) SnapshotStore {
        return .{ .gpa = gpa };
    }

    /// Free every lazily-allocated slab. MUST run before the session `gpa.destroy`s the
    /// store struct (snapshot-restore-plan §3 "Cleanup") — otherwise each allocated slab
    /// leaks. Idempotent: a slot whose slab is null (never captured into) is skipped.
    pub fn deinit(self: *SnapshotStore) void {
        for (&self.slots) |*slot| {
            if (slot.slab) |s| self.gpa.free(s);
            slot.slab = null;
        }
    }

    /// The five out-of-band region slices of the live machine, in the FIXED order they
    /// are laid out inside a slot's slab. All five are constant-size for a given wired
    /// machine, so the contiguous slab length is a constant across captures/restores.
    fn machineSlabs(m: *Machine) [5][]u8 {
        return .{
            m.bus.ram,
            m.vga.vram,
            m.vga.text_vram,
            m.vga.text_vram_mono,
            m.dos.ems.backingBytes(),
        };
    }

    fn totalBytes(m: *Machine) usize {
        var total: usize = 0;
        for (machineSlabs(m)) |s| total += s.len;
        return total;
    }

    fn freeSlot(self: *SnapshotStore) ?*Slot {
        for (&self.slots) |*slot| {
            if (!slot.occupied) return slot;
        }
        return null;
    }

    fn find(self: *SnapshotStore, seq: u64) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.occupied and slot.seq == seq) return slot;
        }
        return null;
    }

    /// Live (occupied) slot count.
    pub fn liveCount(self: *const SnapshotStore) u32 {
        var n: u32 = 0;
        for (&self.slots) |*slot| {
            if (slot.occupied) n += 1;
        }
        return n;
    }

    /// Capture the full live machine into a free slot (PURE READ — no cycle charge).
    /// Lazily `gpa.alloc`s the slot's slab on first use; a clean `error.OutOfMemory` on
    /// alloc failure (never a panic). Returns the deterministic handle + cycle + size.
    pub fn capture(self: *SnapshotStore, m: *Machine) CaptureError!q.SnapshotInfo {
        const slot = self.freeSlot() orelse return error.LimitReached;
        const slabs = machineSlabs(m);
        var total: usize = 0;
        for (slabs) |s| total += s.len;
        // Lazy first-use alloc (reused on a re-capture into a previously-used slot).
        if (slot.slab == null) {
            slot.slab = try self.gpa.alloc(u8, total);
        }
        const buf = slot.slab.?;
        std.debug.assert(buf.len == total);
        var off: usize = 0;
        for (slabs) |s| {
            @memcpy(buf[off..][0..s.len], s);
            off += s.len;
        }
        slot.snap = m.snapshot();
        slot.seq = self.next_seq;
        self.next_seq += 1;
        slot.cycle = m.cpu.st.cycles;
        slot.bytes = total;
        slot.occupied = true;
        return .{ .seq = slot.seq, .cycle = slot.cycle, .bytes = slot.bytes };
    }

    /// Restore the machine from the slot with handle `seq` (a deterministic state load).
    /// Restores the by-value POD via `Machine.restore` (which resets `cpu.st.cycles` to
    /// the snapshot's) then copies the five slabs back IN PLACE. Returns false if no slot
    /// matches. The CONTROLLER-level re-sync (`rearmWatches`, `last_stop = null`, the
    /// branch-trace clear) is the worker's job AFTER this returns — the store only owns
    /// machine state.
    pub fn applyTo(self: *SnapshotStore, m: *Machine, seq: u64) bool {
        const slot = self.find(seq) orelse return false;
        m.restore(slot.snap);
        const buf = slot.slab.?;
        var off: usize = 0;
        for (machineSlabs(m)) |s| {
            @memcpy(s, buf[off..][0..s.len]);
            off += s.len;
        }
        return true;
    }

    /// Enumerate the live slots (handle/cycle/bytes) in slot order + the cap.
    pub fn list(self: *const SnapshotStore) q.SnapshotListResult {
        var res: q.SnapshotListResult = .{};
        for (&self.slots) |*slot| {
            if (!slot.occupied) continue;
            res.items[res.count] = .{ .seq = slot.seq, .cycle = slot.cycle, .bytes = slot.bytes };
            res.count += 1;
        }
        return res;
    }

    /// Free the slot with handle `seq` (explicit reclamation). The slab stays ALLOCATED
    /// for reuse by a later capture (lazy-alloc payoff); it is released at `deinit`.
    /// Returns the remaining live count, or null if no slot matched.
    pub fn delete(self: *SnapshotStore, seq: u64) ?u32 {
        const slot = self.find(seq) orelse return null;
        slot.occupied = false;
        return self.liveCount();
    }
};
