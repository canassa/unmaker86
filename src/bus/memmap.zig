//! Real-mode physical memory map constants (B3): conventional / UMA / ROM / HMA
//! boundaries, page geometry, the `PageKind` enum, and the deterministic default
//! page-kind layout (`defaultPageKind`).
//!
//! Two distinct sizes (B3 — the CRITICAL OOB fix) live here:
//!   - `ram_total_size` (`0x110000`) — the ONE fixed RAM slab (1 MiB + HMA).
//!   - `page_count` (512) — the page-kind table size, the FULL A20-mask ceiling
//!     (`0x200000 >> 12`), NOT the slab. Pages beyond the slab default to
//!     `.unmapped` so an in-mask-but-beyond-slab address never indexes OOB.

const std = @import("std");

/// 4 KiB pages.
pub const page_size: u32 = 0x1000;
pub const page_shift: u5 = 12;

/// The ONE fixed RAM slab: 1 MiB + 64 KiB HMA wrap (matches `TestBus.flat_size`
/// so the real bus matches the contract surface the CPU already validates).
pub const ram_total_size: u32 = 0x110000;

/// The A20-mask ceiling (the largest address an enabled A20 can produce in the
/// low-21-bit form): `0x1FFFFF`. The page-kind table must span this whole range
/// so a masked address always resolves to a table entry (never an OOB index).
pub const a20_ceiling: u32 = 0x1FFFFF;

/// Page-kind table size = the A20-mask ceiling expressed in pages = 512.
pub const page_count: u32 = (a20_ceiling + 1) >> page_shift;

// --- Real-mode region boundaries (B3) ---
/// Conventional memory: 0x00000–0x9FFFF (640 KiB RAM).
pub const conventional_start: u32 = 0x00000;
pub const conventional_end: u32 = 0x9FFFF;
/// Upper Memory Area / VGA framebuffer + MMIO window: 0xA0000–0xBFFFF.
pub const uma_start: u32 = 0xA0000;
pub const uma_end: u32 = 0xBFFFF;
/// Option-ROM / BIOS window: 0xC0000–0xFFFFF.
pub const rom_window_start: u32 = 0xC0000;
pub const rom_window_end: u32 = 0xFFFFF;
/// The standard system BIOS ROM region installed `.rom` at init (B4 / Phase 3).
pub const bios_rom_start: u32 = 0xF0000;
pub const bios_rom_end: u32 = 0xFFFFF;
/// HMA wrap region reachable from real mode with A20 enabled: 0x100000–0x10FFEF
/// (FFFF:FFFF = 0x10FFEF). Backed by the same slab so wrap accesses land in real
/// storage. We mark whole pages, so the HMA spans 0x100000–0x10FFFF.
pub const hma_start: u32 = 0x100000;
pub const hma_end: u32 = 0x10FFFF;

/// Deterministic fill for an unmapped memory read (B7). Matches `TestBus.fill`
/// and the deterministic zero RAM init. (determinism-critical, CLAUDE #5.)
pub const unmapped_fill: u8 = 0x00;

/// The kind of each 4 KiB physical page (B1). Hot-path dispatch keys off this.
pub const PageKind = enum(u8) {
    /// Backed by the RAM slab; read+write hit the slab directly (fast path).
    ram,
    /// Backed by the RAM slab; reads hit the slab, writes are dropped (B4).
    rom,
    /// A registered MMIO handler owns this page (rare path).
    mmio,
    /// No backing; reads return `unmapped_fill`, writes are dropped (B7).
    unmapped,
};

// Size locks (memory-and-performance.md §5c — lock the layout so a refactor
// can't silently change the map or reintroduce the OOB gap, B3).
comptime {
    std.debug.assert(page_size == @as(u32, 1) << page_shift);
    // The page-kind table MUST be larger than the slab in pages so an
    // in-mask-but-beyond-slab address resolves via the table (→ .unmapped),
    // never as an OOB slab index (B3 critical OOB fix).
    std.debug.assert(ram_total_size < page_count << page_shift);
    std.debug.assert(page_count == 512);
    std.debug.assert(ram_total_size == 0x110000);
    // The slab must cover the HMA so A20-enabled wrap accesses land in storage.
    std.debug.assert(hma_end < ram_total_size);
}

/// The page index for a (already-A20-masked) physical address.
pub inline fn pageIndex(phys: u32) u32 {
    return phys >> page_shift;
}

/// The deterministic default page-kind for a page index — a pure function of the
/// page's address, NOT an ad-hoc choice (B2/Phase 2). Used at `init` and by
/// `unmapRegion` so "reset to what" is well-defined.
///
/// Layout: conventional → `.ram`; UMA → `.unmapped` (until a device claims it);
/// the BIOS ROM window → `.rom` (write-dropped, read-from-RAM, installed at
/// init independent of any image, B4); the rest of the ROM window → `.unmapped`
/// (option ROMs claim it explicitly); HMA → `.ram`; everything beyond the slab
/// → `.unmapped` (the 0x00 fill, never OOB, B3).
pub fn defaultPageKind(page: u32) PageKind {
    const addr = page << page_shift;
    if (addr <= conventional_end) return .ram;
    if (addr >= uma_start and addr <= uma_end) return .unmapped;
    if (addr >= bios_rom_start and addr <= bios_rom_end) return .rom;
    if (addr >= rom_window_start and addr < bios_rom_start) return .unmapped;
    if (addr >= hma_start and addr <= hma_end) return .ram;
    return .unmapped; // beyond the slab (and any gap)
}
