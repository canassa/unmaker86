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
/// Per-plane stride in the **plane-major** VRAM layout (plans/vga-spec/02-memory-engine.md
/// §1.2): plane p occupies `vram[p*PLANE_SIZE .. (p+1)*PLANE_SIZE]`. The 256 KiB slab
/// is reused as 4 contiguous 64 KiB planes (no reshape). This is the ONE place zdos
/// deliberately diverges from both reference emulators' byte-interleaved layout
/// (`vram[off*4+plane]`); see the layout-trade note on `vram` below.
pub const PLANE_SIZE: u32 = 0x10000;

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

/// An indexed VGA register file (the SEQ/CRTC/GC/AC shape): an address/index
/// latch plus a flat array of data registers. `out(index_port, i)` latches
/// `index`; subsequent `out(data_port, v)` writes `regs[index]=v`, and
/// `in(data_port)` reads it back. `extern struct` keeps it snapshot-stable POD
/// (plans/vga-spec/01-registers.md §8.2). Bits are decoded at the use-site via
/// the accessors below, never stored as typed wrapper structs.
pub fn RegFile(comptime n: usize) type {
    return extern struct {
        index: u8 = 0,
        regs: [n]u8 = @splat(0),
    };
}

/// Power-on register-file contents that keep mode 13h the chained boot/fast path
/// (plans/vga-spec/01-registers.md §8.3). The single source of truth for both the
/// struct field defaults (bare `init`) and `reset()`.
const seq_power_on: [5]u8 = blk: {
    var r: [5]u8 = @splat(0);
    r[0x02] = 0x0F; // Map Mask: all four planes write-enabled
    r[0x04] = 0x08; // Memory Mode: Chain-4 set (chained() => true)
    break :blk r;
};
const gfx_power_on: [9]u8 = blk: {
    var r: [9]u8 = @splat(0);
    r[0x08] = 0xFF; // Bit Mask: every bit passes
    break :blk r;
};
const attr_power_on: [21]u8 = blk: {
    var r: [21]u8 = @splat(0);
    r[0x12] = 0x0F; // Color Plane Enable: all planes feed the AC
    break :blk r;
};
const crtc_power_on: [32]u8 = blk: {
    var r: [32]u8 = @splat(0);
    // Line Compare DISABLED (= 0x3FF) on every standard mode: the real VGA BIOS
    // programs the full 10-bit value to all-ones so the split-screen never fires
    // (plans/vga-spec/03 §2.4). Without this the rasterizer's line-compare walk would
    // treat the screen as one giant bottom-split (reset to address 0) on every mode.
    r[0x18] = 0xFF; // Line Compare low 8 bits
    r[0x07] = 0x10; // Overflow bit 4 = Line Compare bit 8
    r[0x09] = 0x40; // Max Scan Line bit 6 = Line Compare bit 9
    break :blk r;
};

/// The ALU / function-select op (GC idx 3 bits 4:3) that combines freshly-computed
/// write data with the latch (§2.5). Decoded once into `WriteConfig`.
pub const AluOp = enum(u2) { replace = 0, @"and" = 1, @"or" = 2, xor = 3 };

/// The decoded write-mode pipeline configuration (§2.6 / review F4). A small POD,
/// recomputed on the rare GC/SEQ register write (and in `restore()`) so the per-byte
/// write path never re-decodes the registers. `trivial` (review F2) flags the
/// overwhelmingly-common Mode-X fan-out where the whole §2.1 pipeline reduces to
/// `out = v` per masked plane, enabling a direct per-plane store.
pub const WriteConfig = struct {
    write_mode: u2 = 0,
    data_rotate: u3 = 0,
    alu: AluOp = .replace,
    bit_mask: u8 = 0xFF,
    set_reset: u4 = 0,
    enable_set_reset: u4 = 0,
    map_mask: u4 = 0,
    /// review F2: dataRotate==0 && enableSetReset==0 && alu==replace && bitMask==0xFF
    /// (only meaningful for write mode 0). When set, a masked-plane write is just
    /// `vram[p*PLANE_SIZE + off] = v` — the full pipeline is a no-op shortcut.
    trivial: bool = false,
};

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

    /// Frame period in DEVICE-TIME units (Phase 1 device-time seam): the VGA dot
    /// clock is real-time-anchored, so the frame/line/active spans live in the
    /// mult-independent device-time domain. `FRAME_CYCLES = CPU_CLOCK_HZ *
    /// HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ`. Device-time == nominal cycles at
    /// the reference mult, so these are byte-identical to the former cycle spans;
    /// `statusReg1Peek` converts the ledger CPU→device-time before the phase math.
    pub const FRAME_CYCLES: u64 = timing.CPU_CLOCK_HZ * HTOTAL_DOTS * VTOTAL_LINES / DOT_CLOCK_HZ;
    /// One scanline in device-time units: FRAME_CYCLES / VTOTAL_LINES (floor).
    pub const LINE_CYCLES: u64 = FRAME_CYCLES / VTOTAL_LINES;
    /// The active (display-enable high) span of a scanline, in device-time units.
    pub const HDE_CYCLES: u64 = timing.CPU_CLOCK_HZ * HDE_DOTS / DOT_CLOCK_HZ;

    // The geometry pins moved from a `comptime {}` block to a RUNTIME self-test
    // (`vga.zig` "VGA frame geometry pins ..." below). Once a future phase makes
    // the active mult a runtime value the frame period is no longer a comptime
    // constant, and floor division means a naive exact assert could trip on a
    // legal mult — so the canonical-target pins (and the mult-invariant 70.086 Hz
    // refresh identity) are checked at the default mult 12 WITH a ±1 rounding band
    // (plans/configurable-cpu-clock.md, LOCKED §"VGA comptime asserts").

    /// The one fixed VRAM block. Heap-allocated up-front (it is large) and freed
    /// at deinit, zero-filled at reset (determinism). NOT inlined into the struct.
    ///
    /// LAYOUT — **plane-major** `vram[plane*PLANE_SIZE + off]` (§1.2). The 256 KiB
    /// slab is 4 contiguous 64 KiB planes. This is a deliberate divergence from both
    /// references' byte-interleaved `vram[off*4+plane]` layout — a real trade, not a
    /// free win: an all-four-plane access (latch load / 4-plane fan-out) touches 4
    /// bytes 64 KiB apart (up to 4 cache lines/TLB entries vs the interleaved
    /// `uint32_t`'s one), but a single-plane strip (the common Mode-X case) is
    /// contiguous (the inverse 4× win). It is chosen because **mode-13h plane 0's
    /// first 64 KiB stays byte-identical to the existing linear slab** (zero
    /// regression, the chained fast path is untouched) and the slab/snapshot/region
    /// contracts need no reshape. Chained mode 13h is stored LINEARLY (`vram[off]`)
    /// and reaches the slab through the host-pointer fast path — it is NEVER routed
    /// through the planar plane-major decode (§6.1, the §0 regression rule).
    vram: []u8 = &.{},

    /// The four VGA plane latches (§1.3). Loaded from `vram[p*PLANE_SIZE + off]` on
    /// EVERY unchained CPU read of the A000 window (real hardware always latches the
    /// 4 planes; that is what makes Write-Mode-1 and the Bit-Mask latch-merge work)
    /// and consumed by the write-mode arithmetic. Pure guest state → snapshot-covered
    /// (§8). dosbox `vga.latch.d` (32-bit union); spice86 `_latches[4]`; zdos `[4]u8`.
    latch: [4]u8 = @splat(0),

    /// Decoded write-mode configuration (§2.6 / review F4). The GC/SEQ write-path
    /// registers change ~once per blit setup; VRAM bytes change millions of times, so
    /// the per-byte write path reads this packed POD instead of re-decoding ~7
    /// register fields each byte. It is a pure function of the snapshot-covered raw
    /// registers (NOT separate state) — recomputed by `recomputeWriteConfig()` on
    /// every GC/SEQ register write and in `restore()`, so it needs no snapshot
    /// coverage of its own.
    wc: WriteConfig = .{},

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
    /// The active CPU:PIT multiplier (Phase 2) — points at `&machine.clock.mult`,
    /// bound at `wire`, re-bound on `restore`. `statusReg1Peek` converts the elapsed
    /// CPU ledger → device-time at this live ratio before the frame/line phase math
    /// (the VGA dot clock is independent of the CPU clock). Defaults to
    /// `timing.DEFAULT_MULT` (12) when unbound (stand-alone tests). NOT snapshotted
    /// (a host pointer; re-bound by the machine, like `cycles`).
    mult: ?*const u64 = null,

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

    // -----------------------------------------------------------------------
    // The four indexed register files (plans/vga-spec/01-registers.md §8.2).
    // These are pure guest state: written by guest OUT, read back by guest IN,
    // with no host clock / float / RNG (CLAUDE prime directive). This phase owns
    // their STORAGE + the index/data protocol + read-back ONLY; the downstream
    // EFFECT of any bit (the planar memory engine, the rasterizer) is wired in
    // later phases via the accessors at the bottom of this struct.
    // -----------------------------------------------------------------------

    /// Sequencer (index 0x3C4 / data 0x3C5), 5 registers (idx 0x00-0x04). Index
    /// masked to bits 2-0 on write (spice86 SequencerRegisters.cs:17). §2. The
    /// field default carries the power-on values (§8.3) so a bare `init`-only
    /// device matches `reset()`: Map Mask (idx 2) = 0x0F, Chain-4 (idx 4 bit3) set.
    seq: RegFile(5) = .{ .regs = seq_power_on },
    /// CRT Controller (index 0x3D4/0x3B4 / data 0x3D5/0x3B5). 32 slots for
    /// headroom; valid idx 0x00-0x18. Write-protect (idx 0x11 bit7) gates idx
    /// 0x00-0x07 except the line-compare bit in Overflow. §3.
    crtc: RegFile(32) = .{ .regs = crtc_power_on },
    /// Graphics Controller (index 0x3CE / data 0x3CF), 9 registers (idx
    /// 0x00-0x08). Index masked to bits 3-0 on write (dosbox vga_gfx.cpp:16). §4.
    /// Field default carries the power-on Bit Mask (idx 8) = 0xFF.
    gfx: RegFile(9) = .{ .regs = gfx_power_on },
    /// Attribute Controller (port 0x3C0 flip-flop / read 0x3C1), 21 registers
    /// (idx 0x00-0x14). Uses the shared `attr_flip_flop_is_index` latch + the
    /// PAS bit (`attr_pas`). §5. Field default carries Color Plane Enable
    /// (idx 0x12) = 0x0F.
    attr: RegFile(21) = .{ .regs = attr_power_on },

    /// Attribute Controller Palette Address Source (0x3C0 address-phase bit 5,
    /// §5.2). PAS=1 (true) => normal operation, the AC feeds the display and the
    /// internal palette regs (0x00-0x0F) are LOCKED against CPU writes. PAS=0 =>
    /// CPU may load the internal palette. Power-on locked/display state (true),
    /// matching the dosbox `disabled` semantics inverted. Snapshotted.
    attr_pas: bool = true,

    /// Feature Control register (write 0x3DA colour / 0x3BA mono, read 0x3CA).
    /// Inert on VGA (held two feature-connector control bits on EGA). Stored so
    /// a guest probe round-trips; drives nothing. §1.4. Power-on 0.
    feature_control: u8 = 0,

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
        self.recomputeWriteConfig(); // F4: derive `wc` from the power-on registers
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
        self.latch = @splat(0); // power-on plane latches (§8)
        self.dac_rgb = @splat(.{});
        self.dac_write_index = 0;
        self.dac_read_index = 0;
        self.dac_pel_index = 0;
        self.dac_state = .read;
        self.dac_tmp = .{ 0, 0, 0 };
        self.pel_mask = 0xFF;
        self.misc_output = 0;
        self.attr_flip_flop_is_index = true; // power-on index phase (D-RT3)

        // Indexed register files: zero, then set the power-on defaults that keep
        // mode 13h the boot/fast path so existing tests are undisturbed
        // (plans/vga-spec/01-registers.md §8.3). Map Mask = all planes, chain-4
        // set (chained linear 256-color), Bit Mask = all bits pass, Color Plane
        // Enable = all planes; feature_control 0; PAS locked/display.
        self.seq = .{ .regs = seq_power_on };
        self.crtc = .{ .regs = crtc_power_on };
        self.gfx = .{ .regs = gfx_power_on };
        self.attr = .{ .regs = attr_power_on };
        self.attr_pas = true; // PAS locked/display state (palette regs CPU-locked)
        self.feature_control = 0;

        self.recomputeWriteConfig(); // F4: derive `wc` from the power-on registers
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

    fn multNow(self: *const Vga) u64 {
        return (self.mult orelse return timing.DEFAULT_MULT).*;
    }

    // =======================================================================
    // MMIO MemHandler — the A0000 VGA memory window (the CPU↔VRAM engine).
    // plans/vga-spec/02-memory-engine.md. Two paths share ONE handler:
    //   - CHAINED (mode 13h, the default): `memGetHostPtr` returns a direct
    //     pointer so the bus fast path indexes `vram[off]` LINEARLY with zero
    //     overhead (no per-byte trap). 100% the existing behavior — plane 0's
    //     first 64 KiB of the plane-major slab IS the linear mode-13h slab.
    //   - UNCHAINED (Mode-X / EGA planar): `memGetHostPtr` returns null, so every
    //     A000 byte routes through `memWrite8`/`memRead8` — the §2 write-mode
    //     fan-out and the §3 latch-load read. Cycle-neutral either way (§6.3): the
    //     CPU instruction charges the cost; the handler adds zero cycles. NO
    //     `read_delay`/`write_delay` host-cycle hack (the ledger hole zdos avoids).
    //
    // Wide 16/32-bit accesses are intentionally NOT given native vtable methods:
    // the bus's default `read16/32`/`write16/32` already decompose into the byte
    // path in ASCENDING address order (regions.zig:71-93), which is exactly the
    // per-byte semantics §6.2 requires (each byte re-runs the full pipeline, the
    // latch reloads per read, the bit-mask applies per byte) — matching both refs'
    // per-byte handlers. Widening the pipeline to 16/32 bits would be wrong.
    // =======================================================================

    pub fn memHandler(self: *Vga) MemHandler {
        return .{ .ctx = self, .vtable = &mem_vtable };
    }

    const mem_vtable = MemHandler.VTable{
        .read8 = memRead8,
        .write8 = memWrite8,
        .getHostPtr = memGetHostPtr,
        .peek8 = memPeek8,
    };

    /// The linear offset into VRAM for a guest physical address in the A000 window.
    inline fn vramOffset(phys: u32) u32 {
        return phys - VRAM_PHYS;
    }

    /// Rotate-right an 8-bit value (GC Data Rotate, §2.1). Pure integer.
    inline fn ror8(v: u8, count: u3) u8 {
        return std.math.rotr(u8, v, @as(u32, count));
    }

    /// Apply the GC function-select ALU combining fresh data with the latch (§2.5).
    inline fn aluApply(op: AluOp, data: u8, latch: u8) u8 {
        return switch (op) {
            .replace => data,
            .@"and" => data & latch,
            .@"or" => data | latch,
            .xor => data ^ latch,
        };
    }

    /// (F4) Recompute the decoded `WriteConfig` from the live GC/SEQ registers.
    /// Called on every GC/SEQ register write and in `restore()` — never per VRAM
    /// byte. A pure function of the snapshot-covered raw registers (§2.6).
    fn recomputeWriteConfig(self: *Vga) void {
        const dr: u3 = @truncate(self.dataRotate());
        const alu: AluOp = @enumFromInt(self.rasterOp());
        const bm = self.bitMask();
        const esr: u4 = @truncate(self.enableSetReset());
        const wm: u2 = @truncate(self.writeMode());
        self.wc = .{
            .write_mode = wm,
            .data_rotate = dr,
            .alu = alu,
            .bit_mask = bm,
            .set_reset = @truncate(self.setReset()),
            .enable_set_reset = esr,
            .map_mask = @truncate(self.mapMask()),
            // F2: the trivial fan-out shortcut is valid only for write mode 0 with
            // the identity pipeline (no rotate, no set/reset, replace ALU, full mask).
            .trivial = wm == 0 and dr == 0 and esr == 0 and alu == .replace and bm == 0xFF,
        };
    }

    // ---- Address decode (§4) ---------------------------------------------
    // The same write/read-mode arithmetic (§2/§3) runs in every addressing mode;
    // what changes is how a CPU offset decodes to (plane set, read plane, plane
    // offset). Chained mode never reaches the slow path (it uses the host-pointer
    // fast path; §4.1 is the linear `vram[off]` it already implements). The slow
    // path handles UNCHAINED PLANAR (Mode-X / EGA-16, §4.2/§4.5) and ODD/EVEN
    // (text/CGA chain-2, §4.3). Doubleword (§4.4) is not a separate CPU-access
    // decode and a GC-Misc graphics-window relocation (§5) stays a LOUD guard.

    /// The decoded non-chained access (§4.2/§4.3/§4.5/§4.6 table). `plane_set` is
    /// the addressing-mode plane enable (ANDed further with the Map-Mask on a
    /// write); `read_plane` is the plane a read-mode-0 read returns; `plane_off` is
    /// the per-plane offset into a 64 KiB plane.
    const PlanarDecode = struct { plane_set: u4, read_plane: u2, plane_off: u32 };

    /// Decode an UNCHAINED A000-window offset (§4). Covers unchained planar (Mode-X
    /// / EGA-16, §4.2/§4.5) and odd/even (§4.3); never called for chained (§4.1) or
    /// for a relocated graphics window (guarded in the caller via `assertSimplePlanar`).
    inline fn decodePlanar(self: *const Vga, off: u32) PlanarDecode {
        if (self.oddEven()) {
            // Odd/even (text/CGA chain-2, §4.3 + FIX S4). Even addr → planes {0,2},
            // odd → {1,3}; read plane = off&1; plane-offset is a bit-0 mask/OR fixup
            // of `off` (NOT `off >> 1`). Mirrors spice86 Decode{Read,Write}Address.
            const even = (off & 1) == 0;
            const plane_set: u4 = if (even) 0b0101 else 0b1010;
            const read_plane: u2 = @intCast(off & 1);
            var poff = off;
            if ((self.gfx.regs[0x06] & 0x02) != 0) {
                // ChainOddMapsToEven (GC-Misc idx 6 bit 1): replace off bit 0 with a
                // high-order page bit (shift 16 if Extended-Memory else 14).
                const shift: u5 = if ((self.seq.regs[0x04] & 0x02) != 0) 16 else 14;
                const mask: u32 = (@as(u32, 1) << shift) - 2;
                const high_bit: u32 = (off >> shift) & 1;
                poff = off & (mask + high_bit);
            } else if ((self.misc_output & 0x20) != 0) {
                // EvenPageSelect (Misc-Output bit 5): clear bit 0 (the standard
                // even-page text/CGA case — `off & 0xFFFE`).
                poff = off & 0xFFFE;
            } else {
                poff = off | 1;
            }
            return .{ .plane_set = plane_set, .read_plane = read_plane, .plane_off = poff & (PLANE_SIZE - 1) };
        }
        // Unchained planar (Mode-X 256 / EGA-16, §4.2/§4.5): all planes enabled
        // (the Map-Mask AND in the write loop does the real gating); read plane is
        // Read-Map-Select; the plane offset is the CPU offset with NO division.
        return .{
            .plane_set = 0b1111,
            .read_plane = @intCast(self.readMapSelect()),
            .plane_off = off & (PLANE_SIZE - 1),
        };
    }

    /// Odd/even-mode active (Seq Memory Mode idx 4 bit 2 == 0, §4.3). spice86
    /// `MemoryModeRegister.OddEvenMode = !GetBit(2)`.
    inline fn oddEven(self: *const Vga) bool {
        return (self.seq.regs[0x04] & 0x04) == 0;
    }

    /// LOUD-assert guard for the addressing/window modes that are faithfully
    /// SPECIFIED but not wired. Doubleword (§4.4) is not a separate CPU-access
    /// decode (chain-4's `off>>2` is its CPU manifestation; the DW/byte/word CRTC
    /// bits affect only the render's address walk — §4.4). The remaining guard is a
    /// GC-Misc graphics-window relocation off A0000+64K (§5): the bus keeps all
    /// windows mapped statically; relocating the graphics window is not wired.
    /// Never a silent drop or silent wrong result (CLAUDE: no fakes).
    fn assertSimplePlanar(self: *const Vga) void {
        const gc_misc_window = (self.gfx.regs[0x06] >> 2) & 0x03;
        if (gc_misc_window != 0 and gc_misc_window != 1) {
            std.debug.assert(false); // GC-Misc relocates the graphics window off A0000+64K (§5) not implemented — extend the static window map to handle it
        }
    }

    /// Chained-vs-planar dispatch (§6): the host pointer (RAM-like fast path) iff
    /// chained (mode 13h, linear `vram[off]`), else null → planar read8/write8.
    fn memGetHostPtr(ctx: *anyopaque, page: u32) ?[*]u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        if (!self.chained()) return null; // unchained → planar slow path
        const phys = page * page_size;
        if (phys < VRAM_PHYS or phys >= VRAM_PHYS + VRAM_WINDOW_LEN) return null;
        return self.vram[vramOffset(phys)..].ptr;
    }

    /// Planar / chained read (§3). Reached for chained access only off the fast
    /// path (a 16-bit straddle, the debugger). Loads all 4 latches on an unchained
    /// read (the documented side effect, §3 / §6.1) then returns per read mode.
    fn memRead8(ctx: *anyopaque, phys: u32) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const off = vramOffset(phys);
        if (self.chained()) return self.vram[off]; // §4.1 linear (regression rule §0)

        self.assertSimplePlanar();
        const dec = self.decodePlanar(off);
        // Load all 4 plane latches (§3 — a read ALWAYS latches the 4 planes).
        inline for (0..4) |p| self.latch[p] = self.vram[p * PLANE_SIZE + dec.plane_off];

        if (self.readMode() == 0) {
            // Read Mode 0: return the addressed plane (§3.1) — Read-Map-Select in
            // planar mode, off&1 in odd/even mode (folded into `dec.read_plane`).
            return self.latch[dec.read_plane];
        }
        // Read Mode 1: color compare across planes, gated by Color Don't Care (§3.2).
        return self.readMode1();
    }

    /// Read Mode 1 — color compare (§3.2). Returns 8 bits, one per horizontal pixel:
    /// bit i is set iff the 4-bit pixel formed from bit i of the 4 latches matches
    /// Color Compare under the Color Don't-Care mask (a 0 don't-care bit forces that
    /// plane to match). spice86's per-bit loop (8 iterations × 4 planes), pure
    /// integer. The latches must already be loaded by the caller (memRead8).
    inline fn readMode1(self: *const Vga) u8 {
        const dont_care = self.colorDontCare(); // GC idx 7, bits 3-0
        const compare = self.colorCompare(); // GC idx 2, bits 3-0
        var result: u8 = 0;
        inline for (0..8) |i| {
            var pixel: u8 = 0;
            inline for (0..4) |p| {
                pixel |= ((self.latch[p] >> i) & 1) << p;
            }
            if ((pixel & dont_care) == (compare & dont_care)) result |= @as(u8, 1) << i;
        }
        return result;
    }

    /// Planar / chained write (§2). Chained lands linearly (§4.1, regression rule);
    /// unchained runs the §2 write-mode pipeline, fanning out to the Map-Masked
    /// planes (§4.2/§4.5). Reached for chained only off the fast path.
    fn memWrite8(ctx: *anyopaque, phys: u32, v: u8) void {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const off = vramOffset(phys);
        if (self.chained()) {
            self.vram[off] = v; // §4.1 linear (regression rule §0)
            return;
        }
        self.assertSimplePlanar();
        const dec = self.decodePlanar(off);
        const poff = dec.plane_off;
        const wc = self.wc;
        // The effective per-plane write gate: the addressing-mode plane enable
        // (all-four for planar, {0,2}/{1,3} for odd/even) ANDed with the Map-Mask
        // (§2 stage 5 / §4.6). In unchained planar `plane_set == 0b1111` so this
        // reduces to the Map-Mask alone (the common Mode-X case).
        const gate: u4 = dec.plane_set & wc.map_mask;

        // F2: trivial-config fast path — a plain Map-Mask fan-out of `v` (the
        // common Mode-X blit). Byte-identical to the full pipeline; verified in a
        // fuzz test. Single-plane strips are contiguous here (plane-major win).
        if (wc.trivial) {
            inline for (0..4) |p| {
                if ((gate & (1 << p)) != 0) self.vram[p * PLANE_SIZE + poff] = v;
            }
            return;
        }

        switch (wc.write_mode) {
            0 => self.writeMode0(poff, v, gate),
            1 => self.writeMode1(poff, gate),
            2 => self.writeMode2(poff, v, gate),
            3 => self.writeMode3(poff, v, gate),
        }
    }

    /// Write Mode 0 — the full §2.1 pipeline, per plane in the Map-Mask set.
    /// Data-Rotate → Set/Reset select (via Enable-Set/Reset) → ALU with latch →
    /// Bit-Mask latch-merge → Map-Mask plane gate. spice86's separated per-plane
    /// `u8` form (§2.5). Default config reduces to `out = v` (the trivial path).
    inline fn writeMode0(self: *Vga, poff: u32, v: u8, gate: u4) void {
        const wc = self.wc;
        const b = ror8(v, wc.data_rotate); // (1) Data Rotate
        inline for (0..4) |p| {
            if ((gate & (1 << p)) != 0) {
                // (2) Enable-Set/Reset selects host data vs the Set/Reset value.
                const src: u8 = if ((wc.enable_set_reset & (1 << p)) != 0)
                    (if ((wc.set_reset & (1 << p)) != 0) @as(u8, 0xFF) else 0x00)
                else
                    b;
                // (3) ALU with the latch.
                const res = aluApply(wc.alu, src, self.latch[p]);
                // (4) Bit-Mask merge with the latch.
                const out = (res & wc.bit_mask) | (self.latch[p] & ~wc.bit_mask);
                // (5) plane write (Map-Mask gate already passed).
                self.vram[p * PLANE_SIZE + poff] = out;
            }
        }
    }

    /// Write Mode 1 — latch copy (§2.2). The 4 latches go straight to the 4 planes
    /// (host byte unused, Bit-Mask ignored); only the Map-Mask gates. The engine of
    /// a `rep movsb` VRAM→VRAM copy: a read loaded the latches, this write stores them.
    inline fn writeMode1(self: *Vga, poff: u32, gate: u4) void {
        inline for (0..4) |p| {
            if ((gate & (1 << p)) != 0) self.vram[p * PLANE_SIZE + poff] = self.latch[p];
        }
    }

    /// Write Mode 2 — fill each plane from one low bit of the CPU byte, via the
    /// Bit-Mask (§2.3). Bit p of the host byte is replicated across all 8 bits of
    /// plane p (→ 0x00/0xFF); then ALU with the latch, then the Bit-Mask latch-merge,
    /// then the Map-Mask gate. Data-Rotate and Set/Reset are IGNORED in this mode.
    inline fn writeMode2(self: *Vga, poff: u32, v: u8, gate: u4) void {
        const wc = self.wc;
        inline for (0..4) |p| {
            if ((gate & (1 << p)) != 0) {
                // (1) bit p of v replicated across the plane byte.
                const src: u8 = if ((v >> p) & 1 != 0) 0xFF else 0x00;
                // (2) ALU with the latch.
                const res = aluApply(wc.alu, src, self.latch[p]);
                // (3) Bit-Mask merge with the latch.
                const out = (res & wc.bit_mask) | (self.latch[p] & ~wc.bit_mask);
                self.vram[p * PLANE_SIZE + poff] = out;
            }
        }
    }

    /// Write Mode 3 — Bit-Mask from rotated CPU data, color from Set/Reset (§2.4).
    /// Set/Reset is used as if Enable-Set/Reset were 1111b (each plane's source is
    /// `setReset[p] ? 0xFF : 0x00`). The host byte is rotated then ANDed with the
    /// Bit-Mask register to form the EFFECTIVE bit-mask, which selects Set/Reset
    /// expansion vs latch. ALU/Function-Select and the Enable-Set/Reset register are
    /// IGNORED (spice86's plain-merge form, §2.4 note — the faithful one).
    inline fn writeMode3(self: *Vga, poff: u32, v: u8, gate: u4) void {
        const wc = self.wc;
        const rotated = ror8(v, wc.data_rotate);
        const eff_mask = rotated & wc.bit_mask;
        inline for (0..4) |p| {
            if ((gate & (1 << p)) != 0) {
                // Set/Reset selects the plane source (Enable-Set/Reset forced on).
                const src: u8 = if ((wc.set_reset & (1 << p)) != 0) 0xFF else 0x00;
                const out = (src & eff_mask) | (self.latch[p] & ~eff_mask);
                self.vram[p * PLANE_SIZE + poff] = out;
            }
        }
    }

    /// Side-effect-free inspection read (debugger peek path, §6.1). Mirrors the
    /// READ decode but MUST NOT load the latches (a peek mutates nothing — CLAUDE
    /// #5/#6, the bus peek contract is side-effect-free). Chained → `vram[off]`;
    /// unchained read-mode-0 → the Read-Map plane WITHOUT latching.
    fn memPeek8(ctx: *anyopaque, phys: u32) ?u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        const off = vramOffset(phys);
        if (self.chained()) return self.vram[off]; // §4.1 linear
        // Note: do NOT call assertSimplePlanar() here — a debugger peek must never
        // panic on an exotic-but-stored mode; return the addressed read plane
        // (read-mode-0 view), the most useful side-effect-free approximation. The
        // latches are explicitly NOT loaded (the bus peek contract is pure).
        const dec = self.decodePlanar(off);
        return self.vram[@as(u32, dec.read_plane) * PLANE_SIZE + dec.plane_off];
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
        // The status BYTE itself is pure `f(cycles)` — computed by the non-mutating
        // peek so the live read and the debugger's device reader share the bit math.
        return self.statusReg1Peek(self.cyclesNow());
    }

    /// The Input Status #1 byte as a PURE function of `cycles_now` — the exact bit
    /// math of `statusReg1` MINUS its one documented mutation (the AC flip-flop
    /// reset). The side-effect-free device reader (`/api/devices`, `/api/io`) calls
    /// THIS so an inspect never perturbs `attr_flip_flop_is_index` (the prime
    /// directive: snapshot-before == snapshot-after).
    pub fn statusReg1Peek(self: *const Vga, cycles_now: u64) u8 {
        // Phase from cycle 0 in DEVICE-TIME (Phase 1/2 seam): convert the CPU ledger
        // CPU→device-time, then take the frame/line phase against the device-time
        // periods. Identity at the pinned mult 12, so the retrace/display bits are
        // byte-identical; a future runtime mult keeps the phase continuous (the
        // VGA dot clock is independent of the CPU clock — no anchor re-arm).
        const now_dt = timing.cpuToDevice(cycles_now, self.multNow());
        const into_frame = now_dt % FRAME_CYCLES; // 0 .. FRAME_CYCLES-1 (anchored at cycle 0)
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

    /// CRTC data write (0x3D5 / 0x3B5) with the write-protect gate (§3). When
    /// idx 0x11 bit 7 (`vga.crtc.read_only` in dosbox) is set, writes to idx
    /// 0x00-0x07 are IGNORED — EXCEPT the Line-Compare bit 8 in Overflow (idx
    /// 0x07 bit 4), which dosbox latches BEFORE the read_only early-out
    /// (vga_crtc.cpp:124-126,260-264). We replicate exactly: gate idx 0-7 on the
    /// protect bit, but still merge idx 0x07 bit 4 even while protected.
    fn writeCrtc(self: *Vga, val: u8) void {
        const idx = self.crtc.index;
        if (idx >= self.crtc.regs.len) return; // out of valid range (>0x1F): drop
        const write_protected = (self.crtc.regs[0x11] & 0x80) != 0;
        if (write_protected and idx <= 0x07) {
            // Protected idx 0x00-0x07: only the Overflow line-compare bit (idx
            // 0x07 bit 4) is still latched; everything else is ignored.
            if (idx == 0x07) {
                self.crtc.regs[0x07] = (self.crtc.regs[0x07] & ~@as(u8, 0x10)) | (val & 0x10);
            }
            return;
        }
        self.crtc.regs[idx] = val;
    }

    /// Attribute Controller write (port 0x3C0) — the address/data flip-flop state
    /// machine (§5.1). In the address (index) phase: low 5 bits latch `attr.index`,
    /// bit 5 latches the PAS bit; flip to data phase. In the data phase: write
    /// `attr.regs[index]` (palette regs 0x00-0x0F masked to 6 bits and gated on
    /// PAS=0); flip back to address phase. Reading 0x3DA/0x3BA resets to the
    /// address phase (statusReg1). Replaces the old `assert(false)`.
    fn writeAttr(self: *Vga, val: u8) void {
        if (self.attr_flip_flop_is_index) {
            // Address phase: latch index (bits 4-0) + PAS (bit 5).
            self.attr.index = val & 0x1F;
            self.attr_pas = (val & 0x20) != 0;
            self.attr_flip_flop_is_index = false; // -> data phase
        } else {
            // Data phase: write regs[index], then flip back to address phase.
            const idx = self.attr.index;
            if (idx < self.attr.regs.len) {
                if (idx <= 0x0F) {
                    // Internal palette regs: 6-bit, and only writable when the CPU
                    // owns the palette (PAS=0). When PAS=1 the palette is locked
                    // (dosbox only writes when `disabled`, vga_attr.cpp:133-136).
                    if (!self.attr_pas) self.attr.regs[idx] = val & 0x3F;
                } else {
                    self.attr.regs[idx] = val;
                }
            }
            self.attr_flip_flop_is_index = true; // -> address phase
        }
    }

    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Vga = @ptrCast(@alignCast(ctx));
        return switch (port) {
            // External / General reads.
            // Input Status #0 (0x3C2): deterministic VGA constant 0x10 (switch-
            // sense high; no vert-retrace IRQ, EGA feature bits 0). §1.2.
            0x3C2 => 0x10,
            // Attribute Controller: 0x3C0 returns the index | (PAS<<5); 0x3C1
            // returns regs[index] (VGA only; neither toggles the flip-flop). §5.1.
            0x3C0 => self.attr.index | (@as(u8, @intFromBool(self.attr_pas)) << 5),
            0x3C1 => if (self.attr.index < self.attr.regs.len) self.attr.regs[self.attr.index] else 0,
            // Sequencer index / data read-back (§2).
            0x3C4 => self.seq.index,
            0x3C5 => if (self.seq.index < self.seq.regs.len) self.seq.regs[self.seq.index] else 0,
            0x3C6 => self.pel_mask, // pixel mask read (vga_dac.cpp:249)
            0x3C7 => if (self.dac_state == .read) @as(u8, 0x3) else 0x0, // DAC state (vga_dac.cpp:271)
            0x3C8 => self.dac_write_index, // read_p3c8 (vga_dac.cpp:294)
            0x3C9 => self.read3c9(),
            // Feature Control read-back (§1.4) — stored byte (dosbox returns a hard
            // 0; storing-and-returning is a strict superset that round-trips).
            0x3CA => self.feature_control,
            0x3CC => self.misc_output, // misc output read-back (vga_misc.cpp)
            // Graphics Controller index / data read-back (§4).
            0x3CE => self.gfx.index,
            0x3CF => if (self.gfx.index < self.gfx.regs.len) self.gfx.regs[self.gfx.index] else 0,
            // CRT Controller index / data read-back — colour 0x3D4/0x3D5 + mono
            // alias 0x3B4/0x3B5 (§3). zdos is always colour for v1; both map here.
            0x3D4, 0x3B4 => self.crtc.index,
            0x3D5, 0x3B5 => if (self.crtc.index < self.crtc.regs.len) self.crtc.regs[self.crtc.index] else 0,
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
            // Attribute Controller (0x3C0): the address/data flip-flop machine (§5.1).
            0x3C0 => self.writeAttr(v),
            // Sequencer: index masked to bits 2-0 (§2); data => regs[index].
            0x3C4 => self.seq.index = v & 0x07,
            0x3C5 => if (self.seq.index < self.seq.regs.len) {
                self.seq.regs[self.seq.index] = v;
                self.recomputeWriteConfig(); // F4: Map-Mask / chain-4 feed the write path
            },
            0x3C6 => self.pel_mask = v, // pixel mask write (vga_dac.cpp:230)
            0x3C7 => self.write3c7(v),
            0x3C8 => self.write3c8(v),
            0x3C9 => self.write3c9(v),
            // Graphics Controller: index masked to bits 3-0 (§4); data => regs[index].
            0x3CE => self.gfx.index = v & 0x0F,
            0x3CF => if (self.gfx.index < self.gfx.regs.len) {
                self.gfx.regs[self.gfx.index] = v;
                self.recomputeWriteConfig(); // F4: GC write-mode/rotate/ALU/bit-mask/set-reset
            },
            // CRT Controller — colour 0x3D4/0x3D5 + mono alias 0x3B4/0x3B5 (§3).
            // Index full byte (idx 0x00-0x18 valid, rest dropped in writeCrtc);
            // data write goes through the write-protect gate.
            0x3D4, 0x3B4 => self.crtc.index = v,
            0x3D5, 0x3B5 => self.writeCrtc(v),
            // Feature Control write (0x3DA colour / 0x3BA mono): inert, round-trips
            // via 0x3CA read (§1.4). 0x3DA/0x3BA READ is Input Status #1 (statusReg1).
            0x3DA, 0x3BA => self.feature_control = v,
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
    // Register-bit accessors (decode at the use-site, §8.2). Defined now; the
    // memory engine (Phase 3) and rasterizer (Phase 4) consume them. The EFFECT
    // of each bit is specified in those later specs — here they are pure reads.
    // -----------------------------------------------------------------------

    /// SEQ Map Mask (idx 0x02, bits 3-0): per-plane write enable (the Mode-X
    /// plane gate).
    pub inline fn mapMask(self: *const Vga) u8 {
        return self.seq.regs[0x02] & 0x0F;
    }
    /// SEQ Memory Mode Chain-4 (idx 0x04 bit 3): chained linear 256-color when
    /// set (mode 13h fast path), unchained planar Mode-X when clear.
    pub inline fn chained(self: *const Vga) bool {
        return (self.seq.regs[0x04] & 0x08) != 0;
    }
    /// GC Mode write mode (idx 0x05, bits 1-0): 0-3.
    pub inline fn writeMode(self: *const Vga) u8 {
        return self.gfx.regs[0x05] & 0x03;
    }
    /// GC Mode read mode (idx 0x05, bit 3): 0 or 1.
    pub inline fn readMode(self: *const Vga) u8 {
        return (self.gfx.regs[0x05] >> 3) & 0x01;
    }
    /// GC Read Map Select (idx 0x04, bits 1-0): which plane a read-mode-0 read
    /// returns.
    pub inline fn readMapSelect(self: *const Vga) u8 {
        return self.gfx.regs[0x04] & 0x03;
    }
    /// GC Bit Mask (idx 0x08): per-bit write enable within the byte.
    pub inline fn bitMask(self: *const Vga) u8 {
        return self.gfx.regs[0x08];
    }
    /// GC Set/Reset (idx 0x00, bits 3-0): the set/reset value per plane.
    pub inline fn setReset(self: *const Vga) u8 {
        return self.gfx.regs[0x00] & 0x0F;
    }
    /// GC Enable Set/Reset (idx 0x01, bits 3-0): which planes take the set/reset
    /// value vs the CPU byte.
    pub inline fn enableSetReset(self: *const Vga) u8 {
        return self.gfx.regs[0x01] & 0x0F;
    }
    /// GC Data Rotate count (idx 0x03, bits 2-0): rotate-right count (write mode 0).
    pub inline fn dataRotate(self: *const Vga) u8 {
        return self.gfx.regs[0x03] & 0x07;
    }
    /// GC raster-op / function select (idx 0x03, bits 4-3): 0=copy,1=AND,2=OR,3=XOR.
    pub inline fn rasterOp(self: *const Vga) u8 {
        return (self.gfx.regs[0x03] >> 3) & 0x03;
    }
    /// GC Color Compare (idx 0x02, bits 3-0): the 4-bit reference pixel read-mode-1
    /// compares each horizontal pixel against (§3.2).
    pub inline fn colorCompare(self: *const Vga) u8 {
        return self.gfx.regs[0x02] & 0x0F;
    }
    /// GC Color Don't Care (idx 0x07, bits 3-0): per-plane compare enable for
    /// read-mode-1; a 0 bit forces that plane to "match" (§3.2).
    pub inline fn colorDontCare(self: *const Vga) u8 {
        return self.gfx.regs[0x07] & 0x0F;
    }
    /// CRTC display Start Address (page base): (idx 0x0C << 8) | idx 0x0D.
    pub inline fn startAddress(self: *const Vga) u16 {
        return (@as(u16, self.crtc.regs[0x0C]) << 8) | self.crtc.regs[0x0D];
    }
    /// CRTC Offset / stride (idx 0x13): bytes-per-scanline / K.
    pub inline fn offset(self: *const Vga) u8 {
        return self.crtc.regs[0x13];
    }
    /// CRTC Line Compare full value (split-screen line): combines idx 0x18 (low
    /// 8), Overflow idx 0x07 bit 4 (bit 8), Max-Scan-Line idx 0x09 bit 6 (bit 9).
    pub inline fn lineCompare(self: *const Vga) u16 {
        const low: u16 = self.crtc.regs[0x18];
        const b8: u16 = @as(u16, (self.crtc.regs[0x07] >> 4) & 1) << 8;
        const b9: u16 = @as(u16, (self.crtc.regs[0x09] >> 6) & 1) << 9;
        return low | b8 | b9;
    }
    /// AC Horizontal Pixel Panning (idx 0x13, bits 3-0): shifts the displayed
    /// image left by N pixels (smooth horizontal scroll, §2.6). 256-color honors
    /// only bits 2-0 (doubled); planar/text honor all 4 bits. Raw 4-bit read.
    pub inline fn pixelPan(self: *const Vga) u8 {
        return self.attr.regs[0x13] & 0x0F;
    }
    /// SEQ Clocking Mode 8/9-dot (idx 0x01 bit 0): 1 => 8-dot cells, 0 => 9-dot
    /// (the 720-wide text family, §3.1). Returns the cell width in dots.
    pub inline fn charWidth(self: *const Vga) u8 {
        return if ((self.seq.regs[0x01] & 0x01) != 0) 8 else 9;
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
        // The 4 plane latches — pure guest state (§8). The decoded `wc` is NOT
        // snapshotted: it is a pure function of the registers, recomputed in
        // `restore()` (§2.6).
        latch: [4]u8,
        // The four indexed register files + AC PAS + Feature Control (R2). Plain
        // POD; the VRAM/text slabs stay caller-copied out-of-band (unchanged).
        seq: RegFile(5),
        crtc: RegFile(32),
        gfx: RegFile(9),
        attr: RegFile(21),
        attr_pas: bool,
        feature_control: u8,
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
            .latch = self.latch,
            .seq = self.seq,
            .crtc = self.crtc,
            .gfx = self.gfx,
            .attr = self.attr,
            .attr_pas = self.attr_pas,
            .feature_control = self.feature_control,
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
        self.latch = snap.latch;
        self.seq = snap.seq;
        self.crtc = snap.crtc;
        self.gfx = snap.gfx;
        self.attr = snap.attr;
        self.attr_pas = snap.attr_pas;
        self.feature_control = snap.feature_control;
        self.recomputeWriteConfig(); // F4: `wc` is derived from the restored registers
    }
};
