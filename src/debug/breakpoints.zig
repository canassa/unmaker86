//! The breakpoint representation (M1 §2): fixed up-front storage, NO per-op alloc,
//! DEFINED POD (never `undefined`). Every slot is a valid default-initialized
//! `Breakpoint`, so a tag read is never illegal behavior (reading an `undefined`
//! tagged-union tag is IB in Zig 0.16) and a snapshot never captures garbage.
//!
//! Stable ids = slot index. `add` finds the lowest free slot; `remove` clears the
//! slot back to default. Ids are stable across add/remove (an M2 REST handle and a
//! future snapshot both reference by id) — mirroring the bus's stable-integer-ID
//! discipline.
//!
//! No pointer-typed fields anywhere in these PODs (constraint #5: no ASLR'd
//! pointer may leak into a snapshot or M2 JSON). A comptime reflection test in
//! `determinism_test.zig` asserts this.

const std = @import("std");
const machine_mod = @import("machine");

const Machine = machine_mod.Machine;

/// Access classification for memory/IO watchpoints. `access` = read|write.
pub const AccessKind = enum(u2) { read, write, access };

/// The discriminated kind of a breakpoint. The `memory`/`io` arms are DECLARED now
/// (so ids/handles/serialization stay stable) but only `execution_address` +
/// `cycle` are matched in M1 Phases 1-3; `interrupt` lands in Phase 4; `memory`
/// in Phase 5; `io` later.
pub const BreakpointKind = union(enum) {
    /// Fires when, after a retired step, `linear(CS:IP)` == `linear`
    /// (= `cpu.st.seg_base[CS] +% cpu.st.eip`).
    execution_address: struct { linear: u32 },
    /// Fires at the first step boundary where `cpu.st.cycles >= at_cycle`.
    cycle: struct { at_cycle: u64 },
    /// Fires when interrupt `vector` was delivered this step (Phase 4; needs the
    /// `State.last_delivered` field).
    interrupt: struct { vector: u8 },
    // ---- declared now so ids/handles/serialization are stable; built later ----
    memory: struct { linear: u32, len: u32, access: AccessKind }, // Phase 5+
    io: struct { port: u16, access: AccessKind }, // deferred
};

/// A well-defined default so unused slots are valid POD (NOT `undefined`).
pub const default_kind: BreakpointKind = .{ .cycle = .{ .at_cycle = 0 } };

pub const Breakpoint = struct {
    kind: BreakpointKind = default_kind,
    enabled: bool = false,
    /// One-shot: auto-disabled after it fires (stepping / run-to use these).
    one_shot: bool = false,
};

pub const MAX_BREAKPOINTS = 64;
pub const Error = error{ BreakpointTableFull, NoSuchBreakpoint };

pub const BreakpointSet = struct {
    /// DEFINED POD — every slot is a valid Breakpoint (default-init), so a tag
    /// read is never illegal behavior and a snapshot never captures garbage.
    items: [MAX_BREAKPOINTS]Breakpoint = @splat(.{}),
    used: [MAX_BREAKPOINTS]bool = @splat(false),
    /// O(1) "any enabled breakpoint?" gate. Single source of truth; recomputed on
    /// every mutation. (A linear scan of <=64 defined PODs is one cache-friendly
    /// pass — no derived fast indices; don't memoize cheap work.)
    active_count: u32 = 0,

    /// Add a breakpoint into the lowest free slot. Returns its stable id, or
    /// `error.BreakpointTableFull` when all `MAX_BREAKPOINTS` slots are used
    /// (NEVER a panic — this is reachable from the M2 HTTP API; a 65th
    /// breakpoint must be a clean error response).
    pub fn add(self: *BreakpointSet, kind: BreakpointKind, one_shot: bool) Error!u32 {
        var id: u32 = 0;
        while (id < MAX_BREAKPOINTS) : (id += 1) {
            if (!self.used[id]) {
                self.items[id] = .{ .kind = kind, .enabled = true, .one_shot = one_shot };
                self.used[id] = true;
                self.recomputeActive();
                return id;
            }
        }
        return error.BreakpointTableFull;
    }

    /// Remove a breakpoint by id. Clears the slot back to default POD. A bad /
    /// stale / out-of-range id is `error.NoSuchBreakpoint` (idempotent-safe: a
    /// double-remove is also `error.NoSuchBreakpoint`, which the caller may
    /// ignore).
    pub fn remove(self: *BreakpointSet, id: u32) Error!void {
        if (id >= MAX_BREAKPOINTS or !self.used[id]) return error.NoSuchBreakpoint;
        self.items[id] = .{}; // reset to default POD (not undefined)
        self.used[id] = false;
        self.recomputeActive();
    }

    /// Enable / disable a breakpoint by id.
    pub fn enable(self: *BreakpointSet, id: u32, on: bool) Error!void {
        if (id >= MAX_BREAKPOINTS or !self.used[id]) return error.NoSuchBreakpoint;
        self.items[id].enabled = on;
        self.recomputeActive();
    }

    /// Get a copy of a breakpoint by id (M2 `GET /bp/{id}`).
    pub fn get(self: *const BreakpointSet, id: u32) Error!Breakpoint {
        if (id >= MAX_BREAKPOINTS or !self.used[id]) return error.NoSuchBreakpoint;
        return self.items[id];
    }

    /// Visit each used (valid) breakpoint with `(ctx, id, *const Breakpoint)`.
    /// Skips unused slots. A visitor (not a `[]const Breakpoint` view) is used
    /// because `items[]` is sparse — a slice would expose non-active slots.
    pub fn forEach(
        self: *const BreakpointSet,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), u32, *const Breakpoint) void,
    ) void {
        var id: u32 = 0;
        while (id < MAX_BREAKPOINTS) : (id += 1) {
            if (self.used[id]) f(ctx, id, &self.items[id]);
        }
    }

    /// Recompute `active_count` from scratch (single source of truth).
    pub fn recomputeActive(self: *BreakpointSet) void {
        var n: u32 = 0;
        var id: u32 = 0;
        while (id < MAX_BREAKPOINTS) : (id += 1) {
            if (self.used[id] and self.items[id].enabled) n += 1;
        }
        self.active_count = n;
    }
};

/// True if `bp` matches the machine's CURRENT (post-retired-step) state. Only
/// `execution_address` + `cycle` are live in Phases 1-3; the others are `false`
/// for now (filled by later phases). A disabled breakpoint never matches.
///
/// NOTE: `matches` is side-effect-free — it only READS machine state. The
/// controller (not this function) handles tie-break, one-shot consumption, and
/// terminal precedence.
pub fn matches(bp: *const Breakpoint, m: *const Machine) bool {
    if (!bp.enabled) return false;
    switch (bp.kind) {
        .execution_address => |k| return currentLinear(m) == k.linear,
        .cycle => |k| return m.cpu.st.cycles >= k.at_cycle,
        .interrupt => return false, // Phase 4
        .memory => return false, // Phase 5+
        .io => return false, // deferred
    }
}

/// CS index into the segment-base array (Seg encoding: es=0, cs=1, ...).
const cpu_cs_index: usize = @intFromEnum(@import("cpu").Seg.cs);

/// The linear address of the next instruction to execute: `seg_base[CS] +% EIP`
/// (mirrors `segmentation.zig` and `cpu.readLogical8`'s linear computation).
pub fn currentLinear(m: *const Machine) u32 {
    return m.cpu.st.seg_base[cpu_cs_index] +% m.cpu.st.eip;
}
