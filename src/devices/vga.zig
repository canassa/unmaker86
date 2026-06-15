//! The IBM VGA device — the mode-13h-relevant subset for the BaK v1 video target
//! (USER DECISION D1: `machine=vgaonly`, plain IBM VGA, no S3 extensions; D3:
//! mode 13h only). It is an ordinary `src/devices/` module: it exposes a
//! `MemHandler` for the A0000-AFFFF linear framebuffer window AND a `PortHandler`
//! for the DAC ports (0x3C6/0x3C7/0x3C8/0x3C9) + the misc-output register (0x3C2).
//! The machine OWNS the `Vga` value and registers both seams at `wire`.
//!
//! Scope (faithful to dosbox-x `vgaonly`, the mode-13h subset + the text page):
//!   - 256 KiB linear VRAM (dosbox-x `vga.mem.memsize` for plain VGA). In mode 13h
//!     the CPU window A000:offset maps DIRECTLY to vram[offset] (the linear/chained
//!     256-color mapping, one byte = one pixel = one palette index). Only the first
//!     64 KiB is reachable through the 64 KiB A000 window — exactly mode 13h.
//!   - The TEXT-MODE video pages: color B800:0000 (modes 0-3) + mono B000:0000
//!     (mode 7), two 32 KiB slabs (`text_vram`/`text_vram_mono`) mapped as RAM-like
//!     MMIO exactly like the A000 framebuffer (getHostPtr fast path + peek8). They
//!     hold the flat interleaved {char,attr} cell the guest reads/writes — both a
//!     direct `putch` (direct video) and the INT 10h text services (src/bios/int10.zig
//!     AH=00/06/07/08/09/0A/0E/13) land here. The debugger reads the grid via a pure
//!     peek at `GET /api/screen`. Determinism: guest RAM (zero-init at reset,
//!     caller-copied in snapshot like vram); NO cursor blink, NO glyph rasterization
//!     (those are renderer/host-timed concerns zdos never models). → plans/text-mode-video.md.
//!   - The 256-entry x 3-byte 6-bit DAC palette, programmed/read through the
//!     0x3C8/0x3C7/0x3C9 port state machine with the exact index auto-advance
//!     dosbox-x implements (vga_dac.cpp:255-396, `vgaonly` => not Paradise).
//!   - The misc-output register (0x3C2) latch — the BIOS writes it at mode-set;
//!     read-back at 0x3CC. (Sequencer/CRTC/GFX/ATTR register files are present-but-
//!     inert for mode 13h: the BIOS sets them once, BaK does not reprogram them, and
//!     the v1 oracle does not read them back — see plans/io-oracle.md §1.4.)
//!
//! Determinism (CLAUDE prime directive):
//!   - VRAM is one fixed up-front block, zero-filled at reset (CLAUDE #5). The DAC
//!     rgb array + index state are zero-filled at reset. No host time/RNG anywhere.
//!   - The retrace / input-status (0x3DA / 0x3BA, Input Status Register #1) bits
//!     ARE modeled at the device layer (statusReg1, plans/vga-retrace.md): the
//!     vertical-retrace (bit 3) + display-enable (bit 0) status is a deterministic,
//!     cycle-derived pure function of cpu.st.cycles — integer only, no host clock,
//!     no float. This unblocks retrace-polling guests (Borland putch snow-avoid,
//!     mode-13h vsync) that would otherwise spin on the unmapped 0xFF default.
//!     These bits remain emulated-time-derived, so they are STILL excluded from
//!     every cross-emulator golden (io-oracle.md §1.5) — modeled for internal
//!     determinism + loop-termination, never as a golden value.
//!   - The DAC/VRAM port + MMIO handlers are pure functions of (device state,
//!     address/value): snapshot-serializable, deterministic on reset (B9).
//!
//! Cycle cost (D5 / CLAUDE hard-constraint #1): VRAM access goes through the bus's
//! RAM-like host-pointer fast path (getHostPtr), so a guest `mov [es:di],al` to
//! A000 is charged as a NORMAL guest memory write by the CPU — no host-serviced
//! trap, no hole. Port I/O to the DAC is charged by the CPU's IN/OUT instruction
//! cost (the bus port path adds nothing). The BIOS INT 10h palette path charges its
//! own synthetic base at the bridge. So there is no ungoverned VGA cycle hole.

const std = @import("std");
const bus_mod = @import("bus");
const timing = @import("timing");

const PortHandler = bus_mod.PortHandler;
const MemHandler = bus_mod.MemHandler;

/// The linear framebuffer window the CPU sees (mode 13h: A000:0000..A000:FFFF).
pub const VRAM_PHYS: u32 = 0xA0000;
/// 64 KiB window (one real-mode segment). Mode 13h uses the first 64000 bytes.
pub const VRAM_WINDOW_LEN: u32 = 0x10000;
/// Backing VRAM size — 256 KiB, dosbox-x `vgaonly` `vga.mem.memsize`. Only the
/// first 64 KiB is reachable through the linear A000 window in mode 13h; the rest
/// exists so a faithful future planar/bank mode has real storage (no fake).
pub const VRAM_SIZE: u32 = 0x40000;

/// Color text page window (modes 0-3): B800:0000. Mono (mode 7): B000:0000. The
/// text page is ordinary guest RAM (a backing slab, like the A0000 framebuffer):
/// a direct `putch` write and an INT 10h text service both land here, and the
/// debugger `/api/screen` peek reads it back. Modeled as the flat interleaved
/// {char,attr} cell (dosbox's plane split is an internal storage detail with no
/// guest-observable difference for the chained text mapping — D-TM1).
pub const TEXT_COLOR_PHYS: u32 = 0xB8000;
pub const TEXT_MONO_PHYS: u32 = 0xB0000;
/// One real-mode segment (32 KiB) is the addressable window for each text base
/// (dosbox MEM_SetPageHandler(VGA_PAGE_B8, 8 pages, ...) = 8 * 0x1000 = 32 KiB).
pub const TEXT_WINDOW_LEN: u32 = 0x8000;
/// Standard 80x25 text geometry (mode 3). The LIVE cols/rows live in the BDA
/// (OFF_VIDEO_COLS / OFF_NB_ROWS+1); these are only the v1 mode-set defaults.
pub const TEXT_COLS: u16 = 80;
pub const TEXT_ROWS: u16 = 25;
/// One display page = 0x1000 bytes (dosbox table plength for modes 2/3/7;
/// 80*25*2 = 4000, rounded up to 0x1000).
pub const TEXT_PAGE_SIZE: u32 = 0x1000;

/// Mode 13h geometry (dosbox-x int10_modes.cpp:100 — `M_VGA 320x200`).
pub const MODE13_WIDTH: u16 = 320;
pub const MODE13_HEIGHT: u16 = 200;
pub const MODE13_BYTES: u32 = @as(u32, MODE13_WIDTH) * MODE13_HEIGHT; // 64000

const page_size: u32 = 0x1000;

/// The DAC access direction (dosbox-x `DAC_READ`/`DAC_WRITE`, vga_dac.cpp:62).
pub const DacState = enum(u8) { read, write };

/// One 6-bit DAC palette entry. Stored as the raw 0..63 values the guest wrote
/// (D1/6-bit DAC: dosbox-x `vga.dac.bits=6`, vga_dac.cpp:444), NOT scaled to 8-bit
/// — palette read-backs must return exactly what was written (io-oracle.md §1.2).
pub const DacRgb = extern struct { red: u8 = 0, green: u8 = 0, blue: u8 = 0 };

pub const Vga = struct {
    // -----------------------------------------------------------------------
    // Input Status Register #1 (0x3DA / 0x3BA) — deterministic vertical-retrace
    // / display-enable timing (plans/vga-retrace.md). The retrace/display-enable
    // bits are a PURE FUNCTION of the CPU cycle counter (CLAUDE prime directive
    // #2/#3) — integer math only, NO host clock, NO float, NO RNG. See
    // `statusReg1`. Exposed `pub const` on the struct so tests read
    // `devices.Vga.FRAME_CYCLES` with no new test-module import.
    //
    // Canonical mode-13h / standard-VGA 70 Hz timing (also mode 03h text — same
    // CRTC family). The geometry is the canonical hardware triple; cycles are
    // derived from the pinned CPU clock (timing.CPU_CLOCK_HZ = 14_318_184) at
    // comptime via Zig integer `/` (FLOOR / truncating division — byte-stable).
    //   pixel (dot) clock      = 25_175_000 Hz  (dosbox Vga640PixelClockHz, vga.h:140)
    //   horizontal total       = 800 dots/line  (8 dots/char × 100 char-clocks;
    //                                             the BIOS table htot=100 is in CHARS)
    //   vertical total         = 449 lines/frame
    //   => vertical refresh    = 25_175_000 / (800*449) = 70.086 Hz (canonical)
    //   horizontal display end = 320 dots (active pixels per line, mode 13h)
    //   vertical display end   = 400 lines (double-scanned 200); v-retrace ~412..414
    pub const DOT_CLOCK_HZ: u64 = 25_175_000;
    pub const HTOTAL_DOTS: u64 = 800; // 8 dots/char × 100 char-clocks (table htot=100 is chars)
    pub const VTOTAL_LINES: u64 = 449;
    pub const HDE_DOTS: u64 = 320; // active pixels per line (display-enable high region)
    pub const VDE_LINES: u64 = 400; // last active scanline (display end)
    pub const VRSTART_LINE: u64 = 412; // vertical retrace pulse start (lines)
    pub const VREND_LINE: u64 = 414; // vertical retrace pulse end

    /// Frame period in CPU cycles: CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ.
    pub const FRAME_CYCLES: u64 = timing.CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ;
    /// One scanline in CPU cycles: FRAME_CYCLES / VTOTAL_LINES (floor).
    pub const LINE_CYCLES: u64 = FRAME_CYCLES / VTOTAL_LINES;
    /// The active (display-enable high) span of a scanline, in CPU cycles.
    pub const HDE_CYCLES: u64 = timing.CPU_CLOCK_HZ * HDE_DOTS / DOT_CLOCK_HZ;

    comptime {
        // Pin against the CANONICAL target, not a re-derivation that could
        // rubber-stamp a wrong input (mirrors src/abi/timing.zig:45-50). A future
        // edit to the geometry above that drifts off the 70.086 Hz frame fails here.
        std.debug.assert(FRAME_CYCLES == 204_293);
        std.debug.assert(LINE_CYCLES == 454);
        std.debug.assert(HDE_CYCLES == 181);
        // Effective refresh ≈ 70.08 Hz: 14_318_184 * 100 / 204_293 = 7008.
        std.debug.assert(timing.CPU_CLOCK_HZ * 100 / FRAME_CYCLES == 7008);
    }

    /// The one fixed VRAM block. Heap-allocated up-front (it is large) and freed
    /// at deinit, zero-filled at reset (determinism). NOT inlined into the struct.
    vram: []u8 = &.{},

    /// The text-mode video pages — ordinary guest RAM, mapped (like `vram`) as
    /// RAM-like MMIO so a direct write (Borland `putch` direct-video) hits the bus
    /// host-pointer fast path with no trap, and a `/api/screen` peek reads it back.
    /// `text_vram` is the color page (B8000, modes 0-3); `text_vram_mono` is the
    /// mono page (B0000, mode 7). Each is one 32 KiB segment (TEXT_WINDOW_LEN).
    /// Zero-filled at reset (CLAUDE #5). Like `vram`/`bus.ram` these are NOT placed
    /// in any Snapshot struct — they are caller-copied out-of-band (§3.4); the
    /// host pointer is re-derived by `wire()`'s `mapMmio` on restore.
    text_vram: []u8 = &.{},
    text_vram_mono: []u8 = &.{},

    // ---- DAC port state machine (vga_dac.cpp) ----
    /// 256 palette entries, each R/G/B in 0..63 (6-bit).
    dac_rgb: [256]DacRgb = @splat(.{}),
    /// The auto-incrementing write index (0x3C8 sets it; advances after a full RGB
    /// triple is written at 0x3C9). vga_dac.cpp:284/367.
    dac_write_index: u8 = 0,
    /// The auto-incrementing read index (0x3C7 sets it; advances after a full RGB
    /// triple is read at 0x3C9). vga_dac.cpp:263/388.
    dac_read_index: u8 = 0,
    /// Which of R(0)/G(1)/B(2) the next 0x3C9 access targets within the current
    /// entry. vga_dac.cpp `vga.dac.pel_index`.
    dac_pel_index: u8 = 0,
    /// Last direction set (READ via 0x3C7, WRITE via 0x3C8) — read back at 0x3C7.
    dac_state: DacState = .read,
    /// Partial-write accumulator for the three 0x3C9 data bytes. vga_dac.cpp
    /// `tmp_dac[3]`. We update the palette on EACH byte (dosbox-x default
    /// `vga_palette_update_on_full_load=false`, vga_dac.cpp:322).
    dac_tmp: [3]u8 = .{ 0, 0, 0 },

    /// The Pixel mask register (0x3C6). Power-on 0xFF (all bits pass). Not used by
    /// mode 13h rendering here, but it is a real readable/writable port the BIOS
    /// touches; model it so a read-back is faithful. vga_dac.cpp `pel_mask`.
    pel_mask: u8 = 0xFF,

    /// Miscellaneous output register (0x3C2 write / 0x3CC read). The BIOS writes it
    /// at mode-set (int10_modes.cpp:1580). Power-on 0.
    misc_output: u8 = 0,

    /// Back-pointer to the single time source `cpu.st.cycles` (the u64 CPU cycle
    /// counter), wired by the machine at `wire()` and re-bound on restore — mirrors
    /// `Pit.cycles` (src/devices/pit.zig:146). The Input Status Register #1
    /// (0x3DA/0x3BA) retrace + display-enable bits are derived from it. NOT
    /// snapshotted (a host pointer; re-bound by the machine, like the PIT/speaker).
    cycles: ?*const u64 = null,

    /// Attribute-controller (port 0x3C0) address/data flip-flop, in the *index*
    /// (address) phase when `true` (D-RT3). Reading 0x3DA/0x3BA resets it to the
    /// index phase — a real, deterministic, guest-visible side effect (both refs do
    /// it: dosbox `vga.attr.is_address_mode = true` vga_misc.cpp:24; spice86
    /// `_attributeDataMode = false`). Programs read 0x3DA precisely to guarantee the
    /// next 0x3C0 write is an index, not data. Power-on index phase => default true.
    /// Snapshotted (guest-visible, mutated by the read). The full 0x3C0 address/data
    /// state machine is NOT modeled until a guest needs it; this field is exactly the
    /// latch it will require — no rework (D-RT3).
    attr_flip_flop_is_index: bool = true,

    /// Allocate the fixed VRAM block. Must be called once before `wire`.
    pub fn init(self: *Vga, allocator: std.mem.Allocator) !void {
        const vram = try allocator.alloc(u8, VRAM_SIZE);
        errdefer allocator.free(vram);
        const tvram = try allocator.alloc(u8, TEXT_WINDOW_LEN);
        errdefer allocator.free(tvram);
        const tmono = try allocator.alloc(u8, TEXT_WINDOW_LEN);
        @memset(vram, 0); // deterministic zero init (CLAUDE #5)
        @memset(tvram, 0);
        @memset(tmono, 0);
        self.* = .{ .vram = vram, .text_vram = tvram, .text_vram_mono = tmono };
    }

    pub fn deinit(self: *Vga, allocator: std.mem.Allocator) void {
        allocator.free(self.vram);
        allocator.free(self.text_vram);
        allocator.free(self.text_vram_mono);
        self.* = .{};
    }

    /// Power-on / mode-set reset of device state. Zeroes VRAM + the DAC + indices
    /// (deterministic). The allocation is preserved.
    pub fn reset(self: *Vga) void {
        @memset(self.vram, 0);
        @memset(self.text_vram, 0); // heap slices => @memset (NOT @splat)
        @memset(self.text_vram_mono, 0);
        self.dac_rgb = @splat(.{});
        self.dac_write_index = 0;
        self.dac_read_index = 0;
        self.dac_pel_index = 0;
        self.dac_state = .read;
        self.dac_tmp = .{ 0, 0, 0 };
        self.pel_mask = 0xFF;
        self.misc_output = 0;
        self.attr_flip_flop_is_index = true; // power-on index phase (D-RT3)
    }

    /// Clear only the VRAM (the BIOS mode-set memory-clear — FinishSetMode's
    /// `memset(vga.mem.linear,0,...)` for M_VGA, int10_modes.cpp:935). The palette
    /// and registers are NOT cleared by a mode-set (the BIOS reprograms the DAC via
    /// its own default-palette path, not by zeroing — but BaK/oracle programs set
    /// their own palette, so we leave the DAC as-is and let the guest drive it).
    pub fn clearVram(self: *Vga) void {
        @memset(self.vram, 0);
    }

    /// The current CPU cycle counter (the single time source), read through the
    /// back-pointer wired by the machine. Mirrors `Pit.cyclesNow`
    /// (src/devices/pit.zig:154-156). Returns 0 if unwired (pre-`wire` / a bare
    /// test `Vga` that never set `.cycles`).
    fn cyclesNow(self: *const Vga) u64 {
        return (self.cycles orelse return 0).*;
    }

    // -----------------------------------------------------------------------
    // MMIO MemHandler — the A0000 linear framebuffer (mode 13h chained mapping).
    // RAM-like: getHostPtr returns a direct pointer so the bus fast path indexes
    // VRAM with zero overhead (no per-byte trap). vga_memory.cpp linear access.
    // -----------------------------------------------------------------------

    pub fn memHandler(self: *Vga) MemHandler {
        return .{ .ctx = self, .vtable = &mem_vtable };
    }

    const mem_vtable = MemHandler.VTable{
        .read8 = memRead8,
        .write8 = memWrite8,
        .getHostPtr = memGetHostPtr,
        // VRAM reads are already pure (a plain slab index); the debugger peek
        // path is identical to read8. getHostPtr also covers it for the bus fast
        // path, but provide peek8 too so a peek never depends on hostPtr.
        .peek8 = memPeek8,
    };

    /// The linear offset into VRAM for a guest physical address in the A000 window.
    inline fn vramOffset(phys: u32) u32 {
        return phys - VRAM_PHYS;
    }

    fn memGetHostPtr(ctx: *anyopaque, page: u32) ?[*]u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const phys = page * page_size;
        if (phys < VRAM_PHYS or phys >= VRAM_PHYS + VRAM_WINDOW_LEN) return null;
        return self.vram[vramOffset(phys)..].ptr;
    }

    fn memRead8(ctx: *anyopaque, phys: u32) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.vram[vramOffset(phys)];
    }
    fn memWrite8(ctx: *anyopaque, phys: u32, v: u8) void {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        self.vram[vramOffset(phys)] = v;
    }
    /// Side-effect-free inspection read (debugger peek path). A pure VRAM index;
    /// identical to read8 but contractually guaranteed to mutate nothing.
    fn memPeek8(ctx: *anyopaque, phys: u32) ?u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.vram[vramOffset(phys)];
    }

    // -----------------------------------------------------------------------
    // Text-page MemHandlers — the B8000 (color) + B0000 (mono) text windows.
    // RAM-like, exactly like the A0000 handler: getHostPtr is the direct-write
    // fast path (a `mov [es:di],al` to B800 is charged as a NORMAL guest write —
    // no trap, no ledger hole, CLAUDE #1), and peek8 is the side-effect-free
    // debugger path `/api/screen` uses (a handler with only getHostPtr would make
    // the peek return fill bytes, not real cells — R4: BOTH are mandatory).
    // -----------------------------------------------------------------------

    pub fn textMemHandler(self: *Vga) MemHandler {
        return .{ .ctx = self, .vtable = &text_mem_vtable };
    }
    pub fn textMonoMemHandler(self: *Vga) MemHandler {
        return .{ .ctx = self, .vtable = &text_mono_mem_vtable };
    }

    const text_mem_vtable = MemHandler.VTable{
        .read8 = textRead8,
        .write8 = textWrite8,
        .getHostPtr = textGetHostPtr,
        .peek8 = textPeek8,
    };
    const text_mono_mem_vtable = MemHandler.VTable{
        .read8 = textMonoRead8,
        .write8 = textMonoWrite8,
        .getHostPtr = textMonoGetHostPtr,
        .peek8 = textMonoPeek8,
    };

    fn textGetHostPtr(ctx: *anyopaque, page: u32) ?[*]u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const phys = page * page_size;
        if (phys < TEXT_COLOR_PHYS or phys >= TEXT_COLOR_PHYS + TEXT_WINDOW_LEN) return null;
        return self.text_vram[phys - TEXT_COLOR_PHYS ..].ptr;
    }
    fn textRead8(ctx: *anyopaque, phys: u32) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.text_vram[phys - TEXT_COLOR_PHYS];
    }
    fn textWrite8(ctx: *anyopaque, phys: u32, v: u8) void {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        self.text_vram[phys - TEXT_COLOR_PHYS] = v;
    }
    fn textPeek8(ctx: *anyopaque, phys: u32) ?u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.text_vram[phys - TEXT_COLOR_PHYS];
    }

    fn textMonoGetHostPtr(ctx: *anyopaque, page: u32) ?[*]u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const phys = page * page_size;
        if (phys < TEXT_MONO_PHYS or phys >= TEXT_MONO_PHYS + TEXT_WINDOW_LEN) return null;
        return self.text_vram_mono[phys - TEXT_MONO_PHYS ..].ptr;
    }
    fn textMonoRead8(ctx: *anyopaque, phys: u32) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.text_vram_mono[phys - TEXT_MONO_PHYS];
    }
    fn textMonoWrite8(ctx: *anyopaque, phys: u32, v: u8) void {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        self.text_vram_mono[phys - TEXT_MONO_PHYS] = v;
    }
    fn textMonoPeek8(ctx: *anyopaque, phys: u32) ?u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return self.text_vram_mono[phys - TEXT_MONO_PHYS];
    }

    // -----------------------------------------------------------------------
    // DAC + misc-output PortHandler (vga_dac.cpp / vga_misc.cpp).
    // -----------------------------------------------------------------------

    pub fn portHandler(self: *Vga) PortHandler {
        return .{ .ctx = self, .vtable = &port_vtable };
    }

    const port_vtable = PortHandler.VTable{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    /// 0x3C8 write: set the WRITE index, reset pel_index, state=WRITE; on a non-
    /// Paradise card the read index follows as (val-1). vga_dac.cpp:275-288.
    fn write3c8(self: *Vga, val: u8) void {
        self.dac_pel_index = 0;
        self.dac_state = .write;
        self.dac_write_index = val;
        self.dac_read_index = val -% 1; // vgaonly: not Paradise
    }

    /// 0x3C7 write: set the READ index, write index follows as (val+1), reset
    /// pel_index, state=READ. vga_dac.cpp:255-265.
    fn write3c7(self: *Vga, val: u8) void {
        self.dac_pel_index = 0;
        self.dac_state = .read;
        self.dac_read_index = val;
        self.dac_write_index = val +% 1;
    }

    /// 0x3C9 write: store one 6-bit component into the current write entry; after
    /// the third (blue) component, advance read_index=write_index then write_index++.
    /// vga_dac.cpp:302-369 (default partial-update path, masked to 6 bits).
    fn write3c9(self: *Vga, val_in: u8) void {
        const val = val_in & 0x3F; // 6-bit DAC (vga_dac.cpp:316-317)
        if (self.dac_pel_index >= 3) {
            // Defensive: never index out of the triple (dosbox-x guards <3).
            self.dac_pel_index = 0;
        }
        self.dac_tmp[self.dac_pel_index] = val;
        const entry = &self.dac_rgb[self.dac_write_index];
        switch (self.dac_pel_index) {
            0 => entry.red = self.dac_tmp[0],
            1 => entry.green = self.dac_tmp[1],
            2 => entry.blue = self.dac_tmp[2],
            else => unreachable,
        }
        self.dac_pel_index += 1;
        if (self.dac_pel_index >= 3) {
            self.dac_pel_index = 0;
            // Advance: read_index = write_index, then write_index++ (vga_dac.cpp:367).
            self.dac_read_index = self.dac_write_index;
            self.dac_write_index +%= 1;
        }
    }

    /// 0x3C9 read: return one component of the current read entry; after blue,
    /// advance read_index=write_index then write_index++. vga_dac.cpp:371-396.
    fn read3c9(self: *Vga) u8 {
        const entry = self.dac_rgb[self.dac_read_index];
        switch (self.dac_pel_index) {
            0 => {
                self.dac_pel_index = 1;
                return entry.red;
            },
            1 => {
                self.dac_pel_index = 2;
                return entry.green;
            },
            2 => {
                self.dac_pel_index = 0;
                self.dac_read_index = self.dac_write_index;
                self.dac_write_index +%= 1;
                return entry.blue;
            },
            else => {
                self.dac_pel_index = 0;
                return 0;
            },
        }
    }

    /// Input Status Register #1 (0x3DA / 0x3BA) — the deterministic, cycle-derived
    /// vertical-retrace + display-enable status (plans/vga-retrace.md §3.1/§3.3).
    /// Models a free-running CRT beam whose position is a PURE FUNCTION of the CPU
    /// cycle counter (`cpu.st.cycles`, via `cyclesNow`): integer `%`/`/` only — NO
    /// host clock, NO float, NO RNG. Mirrors the shape of `Pit.liveCounter`/
    /// `Pit.outBit` (src/devices/pit.zig:119-138, :398-423): `into = elapsed %
    /// period; bit = window-test`. Because each guest poll iteration burns cycles,
    /// `into_frame` advances and the bits flip at a deterministic cycle, so a
    /// retrace-poll loop terminates reproducibly (byte-identical across runs).
    ///
    /// Assembled low byte = `0x04 (bit2) | (bit3? 0x08) | (bit0? 0x01)`:
    ///   bit 0 = display-enable complement (1 = in horizontal OR vertical blank)
    ///   bit 2 = 1 (dosbox sets it unconditionally, "needed by Blues Brothers",
    ///           vga_misc.cpp:21 — D-RT2)
    ///   bit 3 = vertical retrace (1 = in v-retrace)
    /// Bits 1, 4-7 read 0 (light-pen obsolete on VGA; reserved bits low).
    fn statusReg1(self: *Vga) u8 {
        // Documented read side effect: reset the attribute-controller (0x3C0)
        // flip-flop to the index/address phase (D-RT3, §3.4). Idempotent at true.
        self.attr_flip_flop_is_index = true;

        const now = self.cyclesNow();
        const into_frame = now % FRAME_CYCLES; // 0 .. FRAME_CYCLES-1 (anchored at cycle 0)
        const scanline = into_frame / LINE_CYCLES; // 0 .. 449 (449 is harmless, see §3.2)
        const into_line = into_frame % LINE_CYCLES; // 0 .. LINE_CYCLES-1

        var status: u8 = 0x04; // bit 2 always set (D-RT2)

        // bit 3 — vertical retrace pulse.
        if (scanline >= VRSTART_LINE and scanline < VREND_LINE) status |= 0x08;

        // bit 0 — display-enable complement: 1 while NOT actively displaying, i.e.
        // in vertical blank (scanline past the display end) OR in horizontal blank
        // (past the active span of a display line).
        const displaying = scanline < VDE_LINES and into_line < HDE_CYCLES;
        if (!displaying) status |= 0x01;

        return status;
    }

    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return switch (port) {
            0x3C6 => self.pel_mask, // pixel mask read (vga_dac.cpp:249)
            0x3C7 => if (self.dac_state == .read) @as(u8, 0x3) else 0x0, // DAC state (vga_dac.cpp:271)
            0x3C8 => self.dac_write_index, // read_p3c8 (vga_dac.cpp:294)
            0x3C9 => self.read3c9(),
            0x3CC => self.misc_output, // misc output read-back (vga_misc.cpp)
            // Input Status Register #1 (colour 0x3DA / mono alias 0x3BA): the
            // cycle-derived retrace + display-enable status. 0x3BA returns the same
            // byte (zdos's VGA-only mode-13h target is always colour; both ports
            // map to one handler — see machine.wire / plans/vga-retrace.md §3.5).
            0x3DA, 0x3BA => self.statusReg1(),
            else => 0xFF,
        };
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        switch (port) {
            0x3C2 => self.misc_output = v, // misc output write (int10_modes.cpp:1580)
            0x3C6 => self.pel_mask = v, // pixel mask write (vga_dac.cpp:230)
            0x3C7 => self.write3c7(v),
            0x3C8 => self.write3c8(v),
            0x3C9 => self.write3c9(v),
            // Attribute-controller write (0x3C0): NOT MODELED. This is a LOUD flag,
            // never a silent no-op (D-RT3 / CLAUDE assert-don't-fake — mirrors the
            // PIT's BCD-bit assert, src/devices/pit.zig:260). The full 0x3C0
            // address/data state machine (palette/mode/overscan registers, toggling
            // `attr_flip_flop_is_index`) is deferred: BaK/oracle let the BIOS program
            // the palette via INT 10h, not raw 0x3C0. If a guest actually drives
            // 0x3C0, build the AC state machine — do not silently drop the write.
            0x3C0 => std.debug.assert(false), // VGA attribute controller (0x3C0) not modeled
            else => {},
        }
    }

    /// Direct typed port access (tests / internal callers).
    pub fn out8(self: *Vga, port: u16, v: u8) void {
        portOut8(self, port, v);
    }
    pub fn in8(self: *Vga, port: u16) u8 {
        return portIn8(self, port);
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (B12 / M-D11). VRAM + DAC + register state by value;
    // the allocation/back-pointers are re-established by the machine (the VRAM
    // bytes are copied separately, mirroring the bus RAM slab).
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        dac_rgb: [256]DacRgb,
        dac_write_index: u8,
        dac_read_index: u8,
        dac_pel_index: u8,
        dac_state: DacState,
        dac_tmp: [3]u8,
        pel_mask: u8,
        misc_output: u8,
        attr_flip_flop_is_index: bool,
    };

    pub fn snapshot(self: *const Vga) Snapshot {
        return .{
            .dac_rgb = self.dac_rgb,
            .dac_write_index = self.dac_write_index,
            .dac_read_index = self.dac_read_index,
            .dac_pel_index = self.dac_pel_index,
            .dac_state = self.dac_state,
            .dac_tmp = self.dac_tmp,
            .pel_mask = self.pel_mask,
            .misc_output = self.misc_output,
            .attr_flip_flop_is_index = self.attr_flip_flop_is_index,
        };
    }
    pub fn restore(self: *Vga, snap: Snapshot) void {
        self.dac_rgb = snap.dac_rgb;
        self.dac_write_index = snap.dac_write_index;
        self.dac_read_index = snap.dac_read_index;
        self.dac_pel_index = snap.dac_pel_index;
        self.dac_state = snap.dac_state;
        self.dac_tmp = snap.dac_tmp;
        self.pel_mask = snap.pel_mask;
        self.misc_output = snap.misc_output;
        self.attr_flip_flop_is_index = snap.attr_flip_flop_is_index;
    }
};
