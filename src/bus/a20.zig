//! The A20 gate (B5) — the single documented owner of A20 masking.
//!
//! Representation: a `u32` address mask ANDed into every incoming physical
//! address. A20 is DISABLED at power-on (real hardware powers on with A20 off;
//! both DOSBox and spice86 model this). The BIOS/machine enables it via
//! `setA20(true)` during POST.
//!
//! Masking semantics (determinism-critical): A20-off forces **only bit 20** to
//! zero — it does NOT clamp bits 21+. Addresses above the addressable range are
//! resolved by the page-kind table (→ `.unmapped`/fill, B3), never by clamping.
//! The mask is the low-21-bit form: `0x1F_FFFF` (on) / `0x0F_FFFF` (off).
//!
//! The wide-access slow path re-applies `mask()` PER BYTE (spice86-style) so a
//! word straddling the 1 MiB seam wraps each byte independently.

/// A20 enabled: bit 20 passes through (low-21-bit form).
pub const mask_enabled: u32 = 0x1F_FFFF;
/// A20 disabled (power-on): bit 20 forced to zero (low-21-bit form).
pub const mask_disabled: u32 = 0x0F_FFFF;

/// The mask for a given A20 state. `enabled=false` is the power-on default.
pub inline fn maskFor(enabled: bool) u32 {
    return if (enabled) mask_enabled else mask_disabled;
}

/// Apply the A20 mask to a physical address.
pub inline fn apply(a20_mask: u32, phys: u32) u32 {
    return phys & a20_mask;
}
