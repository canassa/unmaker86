//! The synthetic-cycle-cost contract (D5) — THE zdos differentiator.
//!
//! Every host-serviced callback trap (INT 21h, the BIOS INTs, INT 67h, ...) is
//! handled by host Zig code that runs ZERO guest instructions. On real hardware
//! those same services would execute thousands of guest cycles. Spice86 charges
//! NOTHING for the trap, so its cycle ledger has a hole: frame N drifts
//! 346k-3.6M cycles across launches. **zdos charges a fixed, deterministic
//! synthetic cost for every trap so the ledger has NO hole across a trap.** This
//! file is that contract.
//!
//! Rules (all four are load-bearing — CLAUDE.md hard constraint #1):
//!   1. The cost is charged at the bridge in `Services.dispatchCallback` BEFORE
//!      the leaf handler runs: `cpu.st.cycles += base(id)`.
//!   2. The handler MAY add a deterministic, work-proportional increment on top
//!      via a documented PURE formula of guest-register inputs (e.g. a file read
//!      of CX bytes charges `file_read_base + CX*per_byte`). The byte count comes
//!      from the GUEST's CX — a guest input, never a host measurement.
//!   3. It is a PURE function of (service id, guest-register work size). NO host
//!      time, NO host I/O latency, NO host scheduling may influence it.
//!   4. Every allocated callback id has a `base` (comptime-total; see the assert
//!      in `bridge.zig`). The unsupported-service path (D11) charges a defined
//!      cost too.
//!
//! The numbers are INTERIM / provisional-by-design (like cpu.md's flat cycle
//! model D6): they are FIXED (which satisfies the prime directive) but NOT
//! claimed to be PRM-accurate real-DOS service timings (real INT 21h cost varies
//! by FAT/disk state we do not model). The honest fidelity figure would be
//! measured DOS-on-386 timings; not available offline, so per the ground rule it
//! is NOT invented — fixed interim costs are used and labeled.

const std = @import("std");

/// The flat synthetic base cost charged for ANY callback trap that does not have
/// a per-service override (interim, like cpu.md FLAT_BASE). > 0 so the no-hole
/// guard (every trap advances the ledger) always holds.
pub const default_base: u64 = 200;

/// Per-service base overrides (interim). A simple service (get a register value)
/// is cheap; a file/dir/memory service stands in for more guest work. Keyed by
/// the SERVICE KIND (not the raw callback id) so the table is human-auditable;
/// `bridge.zig` maps id -> kind at registration.
pub const ServiceCost = struct {
    /// Charged unconditionally at dispatch (rule 1).
    base: u64,
    /// Per-byte increment for byte-proportional services (rule 2); 0 otherwise.
    /// The handler adds `count * per_byte` itself, reading `count` from a guest
    /// register (D5 rule 3: a guest input, never host timing).
    per_byte: u64 = 0,
};

/// Service kinds with distinct interim costs. Anything not listed uses `flat`.
pub const Kind = enum {
    /// The re-entrancy stop sentinel (D3). Cost-EXEMPT from the no-hole guard:
    /// it is pure control flow (exit the `runGuestInt` loop) that stands in for
    /// no guest work. Charged 0 (the guard carves this id out explicitly).
    stop_sentinel,
    /// A trivial register-in/register-out service (get version, get tick).
    trivial,
    /// A general INT 21h / BIOS dispatch (the AH-switch entry).
    dispatch,
    /// A file read/write (byte-proportional).
    file_io,
    /// A directory search / find (per-entry work folded into the base).
    dir_search,
    /// Memory (MCB) alloc/free/resize.
    mem_op,
    /// The program loader (EXE/COM image copy + relocations; per-byte).
    loader,
    /// An IRQ handler stub (INT 08h tick, etc.).
    irq,
    /// The unsupported-service default arm (D11).
    unsupported,
    /// A flat default for everything else.
    flat,
};

pub fn costFor(kind: Kind) ServiceCost {
    return switch (kind) {
        .stop_sentinel => .{ .base = 0 }, // guard-exempt (D3/0c)
        .trivial => .{ .base = 60 },
        .dispatch => .{ .base = default_base },
        .file_io => .{ .base = 400, .per_byte = 1 },
        .dir_search => .{ .base = 600 },
        .mem_op => .{ .base = 300 },
        .loader => .{ .base = 2000, .per_byte = 1 },
        .irq => .{ .base = 120 },
        .unsupported => .{ .base = default_base },
        .flat => .{ .base = default_base },
    };
}

test "every kind has a defined cost and only stop_sentinel is zero" {
    inline for (std.meta.fields(Kind)) |f| {
        const k: Kind = @enumFromInt(f.value);
        const c = costFor(k);
        if (k == .stop_sentinel) {
            try std.testing.expectEqual(@as(u64, 0), c.base);
        } else {
            try std.testing.expect(c.base > 0);
        }
    }
}
