//! INT 08h / IRQ0 — the timer-tick handler (D13). Increments the BDA tick count
//! and handles 24h rollover. The EOI is emitted by the callback's
//! `iret_eoi_pic1` return tail (D4), NOT here. Determinism: fires at the
//! deterministic IRQ-recognition cycle (machine M-D6); the value is a pure
//! function of the cycle ledger.
//!
//! INT 1Ch chaining (RESOLVED, Phase 1·0a): real BIOS INT 08h executes a guest
//! `INT 1Ch` (the user timer tick a guest may hook). Doing that from this
//! host-serviced handler would require nested machine-stepping on EVERY tick
//! (~18.2/s) — a correctness/perf hazard. The faithful way (now done) is the INT
//! 08h stub tail `<host-tick>; INT 1Ch; EOI; IRET` — a stub-level chain through
//! the REAL IVT, no nested host step (the `int1c_chain_eoi_pic1` CbType variant,
//! registered for INT 08h in `bios.zig`). This `handle` runs only the host tick
//! (the BDA increment below); the stub tail then chains to INT 1Ch and EOIs.
//! INT 1Ch defaults to its own IRET stub a guest may override (AH=25h).

const std = @import("std");
const bda_mod = @import("bda.zig");

pub fn Int08(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            const bda = bda_mod.Bda(Cpu).init(cpu);
            _ = bda.incTick();
        }
    };
}
