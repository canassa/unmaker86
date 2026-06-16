//! INT 10h — video (D7). The pixel/palette STORE lives in the VGA *device*
//! (src/devices/vga.zig); INT 10h DRIVES it exactly the way the real VGA BIOS does
//! — through port writes (the DAC) and direct VRAM writes (the A000 window) via the
//! single bus choke point. The BDA holds the guest-visible mode/page state.
//!
//! Every behavior here is mirrored from dosbox-x's VGA BIOS, cited inline:
//!   - AH=00 set mode: int10_modes.cpp FinishSetMode (BDA fields) + the misc-output
//!     write (int10_modes.cpp:1552-1580) + VRAM clear (int10_modes.cpp:935).
//!   - AH=0C/0D put/get pixel (mode 13h linear): int10_put_pixel.cpp:200/293.
//!   - AH=0F get mode: int10.cpp:215.
//!   - AH=10 AL=10/12/15/17 DAC set/get single/block: int10.cpp:264-277 ->
//!     int10_pal.cpp:219/254/247/306 (a pure DAC port sequence).
//!
//! Determinism: no host time/RNG. All work is guest-register/guest-memory driven.

const std = @import("std");
const bda_mod = @import("bda.zig");
const cpu_state = @import("cpu").state;
const vga_modes = @import("vga_modes.zig");
const vga_palettes = @import("vga_palettes.zig");
const vga_font = @import("vga_font.zig");
const vga_rom = @import("vga_rom.zig");

const Reg32 = cpu_state.Reg32;
const Seg = cpu_state.Seg;

// VGA register ports (the BIOS is just a port-write sequencer, like dosbox-x).
const PORT_MISC_OUTPUT: u16 = 0x3C2; // misc output write
const PORT_AC: u16 = 0x3C0; // attribute controller index/data (flip-flop)
const PORT_SEQ_INDEX: u16 = 0x3C4; // sequencer index
const PORT_SEQ_DATA: u16 = 0x3C5; // sequencer data
const PORT_GC_INDEX: u16 = 0x3CE; // graphics-controller index
const PORT_GC_DATA: u16 = 0x3CF; // graphics-controller data
const PORT_STATUS1: u16 = 0x3DA; // input status #1 (read resets the AC flip-flop)
const PORT_DAC_PEL_MASK: u16 = 0x3C6; // DAC pixel (PEL) mask
const PORT_DAC_READ_ADDR: u16 = 0x3C7; // DAC read index (VGAREG_DAC_READ_ADDRESS)
const PORT_DAC_WRITE_ADDR: u16 = 0x3C8; // DAC write index (VGAREG_DAC_WRITE_ADDRESS)
const PORT_DAC_DATA: u16 = 0x3C9; // DAC data (VGAREG_DAC_DATA)

// Mode 13h linear framebuffer (one byte = one pixel = one palette index).
const VRAM_SEG: u32 = 0xA000;
const VRAM_PHYS: u32 = 0xA0000;
const MODE13_WIDTH: u32 = 320;

// Text-mode video page bases (mirror src/devices/vga.zig). The flat {char,attr}
// cell layout — byte0 = char, byte1 = attr — at pstart + page*PAGE_SIZE +
// (row*cols+col)*2 (dosbox int10_char.cpp:526-538; identical to spice86).
const TEXT_COLOR_PHYS: u32 = 0xB8000; // modes 0-3 (color)
const TEXT_MONO_PHYS: u32 = 0xB0000; // mode 7 (mono)
const TEXT_PAGE_SIZE: u32 = 0x1000; // dosbox plength for text modes

// ---------------------------------------------------------------------------
// ROM font staging (plans/vga-spec/04-modes-int10-bda.md §3.3/§4). The IBM VGA
// ROM fonts are staged at fixed addresses in the BIOS segment (0xF000) so AH=1130
// returns a real far pointer and IVT[0x1F]/[0x43] point at real glyph data. The
// region is clear of the bridge callback area (0xF1000-0xF1800) and the INT 16h
// hybrid block (0xF1800+). Each is a `<segment>:<offset>` real-mode far pointer.
// ---------------------------------------------------------------------------
pub const FONT_SEG: u16 = 0xF000;
pub const FONT16_OFF: u16 = 0x2000; // 8x16, 4096 bytes -> 0xF2000..0xF3000
pub const FONT14_OFF: u16 = 0x3000; // 8x14, 3584 bytes -> 0xF3000..0xF3E00
pub const FONT8_OFF: u16 = 0x4000; // 8x8 (256), 2048 bytes -> 0xF4000..0xF4800
pub const FONT8_2ND_OFF: u16 = FONT8_OFF + 128 * 8; // 8x8 second half (chars 128-255)

pub const FONT16_PHYS: u32 = (@as(u32, FONT_SEG) << 4) + FONT16_OFF;
pub const FONT14_PHYS: u32 = (@as(u32, FONT_SEG) << 4) + FONT14_OFF;
pub const FONT8_PHYS: u32 = (@as(u32, FONT_SEG) << 4) + FONT8_OFF;

/// Stage the ROM font bitmaps into the BIOS image at the fixed offsets above.
/// Called by the machine BEFORE `loadRom` (the F000 window is ROM — guest writes
/// are dropped), so the bytes are real guest-readable ROM. `image` is indexed from
/// 0xF0000 (Bridge.IMAGE_BASE), matching the bridge's stub planting.
pub fn stageFonts(image: []u8) void {
    @memcpy(image[FONT16_OFF .. FONT16_OFF + vga_font.font16.len], &vga_font.font16);
    @memcpy(image[FONT14_OFF .. FONT14_OFF + vga_font.font14.len], &vga_font.font14);
    @memcpy(image[FONT8_OFF .. FONT8_OFF + vga_font.font8.len], &vga_font.font8);
}

pub fn Int10(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00 => setMode(cpu, bda), // set video mode
                0x04 => { // read light pen — unsupported on VGA; real BIOS returns AH=0
                    cpu.st.setReg16(0, 0); // AX = 0
                    cpu.st.setReg16(@intFromEnum(Reg32.ebx), 0);
                    cpu.st.setReg16(@intFromEnum(Reg32.ecx), 0);
                    cpu.st.setReg16(@intFromEnum(Reg32.edx), 0);
                },
                0x05 => setActivePage(cpu), // set active display page (page-flip)
                0x02 => { // set cursor position (DH=row, DL=col, BH=page)
                    const page = cpu.st.getReg8(7); // BH
                    const dx = cpu.st.getReg16(2); // DX = row:col
                    cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2, dx);
                },
                0x01 => { // set cursor shape: CX = start/end scanlines -> BDA
                    cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_SHAPE, cpu.st.getReg16(1));
                },
                0x03 => { // get cursor position -> DX, cursor shape -> CX
                    const page = cpu.st.getReg8(7);
                    const dx = cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2);
                    cpu.st.setReg16(2, dx);
                    // Read the BDA cursor shape (set-then-get round-trips; was a
                    // hardcoded 0x0607 before — the v1 fix).
                    cpu.st.setReg16(1, cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_SHAPE));
                },
                0x08 => { // read char+attr at cursor -> AL=char, AH=attr
                    const page = cpu.st.getReg8(7); // BH
                    const c = readCharCellAtCursor(cpu, page);
                    cpu.st.setReg8(0, c.chr); // AL
                    cpu.st.setReg8(4, c.attr); // AH
                },
                0x06 => scroll(cpu, false), // scroll window up (AL lines; AL=0 clear)
                0x07 => scroll(cpu, true), // scroll window down
                0x09 => writeCharRep(cpu, true), // write char+attr at cursor x CX
                0x0A => writeCharRep(cpu, false), // write char (attr untouched) x CX
                0x0C => putPixel(cpu, bda), // write graphics pixel
                0x0D => getPixel(cpu, bda), // read graphics pixel
                0x0E => { // teletype output AL (text mode: useattr=false, F2)
                    // Graphics modes (e.g. 13h) keep the framebuffer no-op as
                    // before — v1 text services are text-mode only (§3.2 deferral).
                    if (bda.videoMode() == 0x13) {
                        // no-op for the graphics framebuffer
                    } else {
                        const page = cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE);
                        teletype(cpu, page, cpu.st.getReg8(0), cpu.st.getReg8(3), false); // AL=char, BL=attr
                    }
                },
                0x0F => { // get current video mode -> AL=mode, AH=cols, BH=page
                    cpu.st.setReg8(0, bda.videoMode());
                    cpu.st.setReg8(4, @truncate(cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS)));
                    cpu.st.setReg8(7, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE));
                },
                0x10 => palette(bios, cpu, br), // palette / DAC functions
                0x11 => charGen(bios, cpu, br), // character generator (AH=1130 font ptr)
                0x12 => altSelect(cpu), // alternate select (BL subfns)
                0x13 => writeString(cpu), // write string (teletype, useattr=true)
                0x1A => dcc(cpu), // display combination code (LAMUT adapter detect)
                0x1B => funcStateInfo(cpu), // functionality / state information
                0x1C => bios.unsupported(cpu, br, 0x10), // save/restore video state — deferred (see §2.7)
                else => bios.unsupported(cpu, br, 0x10),
            }
        }

        // ------------------------------------------------------------------
        // AH=00 — set video mode (plans/vga-spec/04-modes-int10-bda.md §1.3). The
        // full IBM VGA BIOS register dump: resolve the mode + no-clear bit, look up
        // the per-mode register block (`vga_modes`), load the default DAC palette
        // unconditionally, dump SEQ/CRTC/GC/AC + misc-output through the PORT PATH
        // (so a BIOS set-mode and a raw-port guest are byte-identical), enable
        // video, clear VRAM, and write the full BDA field set. Unsupported standard
        // modes are FLAGGED, not faked as 13h (§1.3 step 2).
        // ------------------------------------------------------------------
        fn setMode(cpu: *Cpu, bda: bda_mod.Bda(Cpu)) void {
            const al = cpu.st.getReg8(0); // AL = mode (bit7 = no-clear)
            const mode = al & 0x7F;
            const clearmem = (al & 0x80) == 0;

            const entry = vga_modes.find(mode) orelse {
                // Unsupported standard mode. The real BIOS leaves AL undefined and
                // does not change state; zdos records nothing and surfaces it loudly
                // in a debug build (never fakes 13h — CLAUDE ground rule). VESA modes
                // (>= 0x100) never reach here (AL is only 8 bits).
                std.debug.assert(false); // unsupported INT 10h AH=00 mode — flag, don't fake
                return;
            };

            const bus = cpu.bus;

            // --- Step 3: load the default DAC palette UNCONDITIONALLY (S3). The
            // MODESET_CTL 0x89 bit 3 gate applies only to the AC internal-palette
            // load (the 16 EGA palette regs in the AC block), NOT the DAC. ---
            loadDacPalette(cpu, entry.palette);

            // --- Step 4: FillRegisters (spice86 VgaFunctionality.FillRegisters /
            // dosbox int10_modes.cpp:1326-1748). Order: AC regs, SEQ, GC, then the
            // CRTC (with the write-protect dance), then misc-output. ---
            const load_ac_internal = (bda.rawByte(bda_mod.OFF_MODESET_CTL) & 0x08) == 0;
            fillRegisters(cpu, entry, load_ac_internal);

            // --- Step 5: enable video (AC index 0x20 sets Palette Address Source). ---
            _ = bus.portIn8(PORT_STATUS1); // reset the AC flip-flop to the address phase
            bus.portOut8(PORT_AC, 0x20);

            // --- Step 6: clear VRAM (deterministic; word-fill text / zero gfx). ---
            if (clearmem) clearVram(cpu, entry);

            // --- Step 8: set the full BDA field set (§3.2). ---
            setBda(cpu, bda, entry, clearmem);
        }

        /// FillRegisters: dump the per-mode register block into the VGA device's
        /// register files via the port path (§1.3 step 4). `load_ac_internal` gates
        /// only the 16 internal AC palette regs (0x00-0x0F) — when false the rest of
        /// the AC block (mode/overscan/plane-enable/h-pel/color-select) still loads.
        fn fillRegisters(cpu: *Cpu, entry: *const vga_modes.ModeEntry, load_ac_internal: bool) void {
            const bus = cpu.bus;

            // Attribute Controller (0x3C0 flip-flop). Reset the flip-flop first
            // (read Input Status #1), then for each reg: write the index byte with
            // PAS=0 (bit5 clear) so the internal palette regs are CPU-writable, then
            // the data byte. The AC palette regs (0x00-0x0F) are gated.
            _ = bus.portIn8(PORT_STATUS1);
            for (entry.attr, 0..) |v, i| {
                const idx: u8 = @intCast(i);
                if (idx <= 0x0F and !load_ac_internal) continue;
                bus.portOut8(PORT_AC, idx); // address phase, PAS=0
                bus.portOut8(PORT_AC, v); // data phase
            }

            // Sequencer regs 0..4.
            for (entry.seq, 0..) |v, i| {
                bus.portOut8(PORT_SEQ_INDEX, @intCast(i));
                bus.portOut8(PORT_SEQ_DATA, v);
            }

            // Graphics Controller regs 0..8.
            for (entry.gfx, 0..) |v, i| {
                bus.portOut8(PORT_GC_INDEX, @intCast(i));
                bus.portOut8(PORT_GC_DATA, v);
            }

            // CRTC: disable write-protect (idx 0x11 bit 7 = 0) before writing
            // 0..0x18, since regs 0x00-0x07 are locked when bit 7 is set
            // (dosbox int10_modes.cpp:1604). The CRTC port base is mode-dependent
            // (0x3B4 mono / 0x3D4 color) — pick it from the misc-output bit 0.
            const crtc_index: u16 = if ((entry.misc_output & 0x01) != 0) 0x3D4 else 0x3B4;
            const crtc_data: u16 = crtc_index + 1;
            bus.portOut8(crtc_index, 0x11);
            bus.portOut8(crtc_data, entry.crtc[0x11] & 0x7F); // write-protect OFF
            for (entry.crtc, 0..) |v, i| {
                bus.portOut8(crtc_index, @intCast(i));
                bus.portOut8(crtc_data, v);
            }
            // The table value of reg 0x11 re-enables write-protect last (the table's
            // 0x11 byte has bit 7 = 0 for the v1 modes, but re-dump it verbatim).
            bus.portOut8(crtc_index, 0x11);
            bus.portOut8(crtc_data, entry.crtc[0x11]);

            // Misc output (0x3C2) + DAC pel mask (0x3C6) last.
            bus.portOut8(PORT_MISC_OUTPUT, entry.misc_output);
            bus.portOut8(PORT_DAC_PEL_MASK, entry.pixel_mask);
        }

        /// Load the default 6-bit DAC palette for the mode via the 0x3C8/0x3C9 port
        /// sequence (§1.3 step 3) — the SAME path INT 10h AL=12 uses, so the BIOS
        /// palette load and a raw-port guest are byte-identical.
        fn loadDacPalette(cpu: *Cpu, id: vga_modes.PaletteId) void {
            const bus = cpu.bus;
            const pal = vga_palettes.forId(id);
            bus.portOut8(PORT_DAC_WRITE_ADDR, 0);
            for (pal) |b| bus.portOut8(PORT_DAC_DATA, b);
        }

        /// Clear VRAM deterministically (§1.3 step 6): text modes word-fill the page
        /// with 0x0720 (space, attr 0x07); graphics/planar modes zero the window.
        fn clearVram(cpu: *Cpu, entry: *const vga_modes.ModeEntry) void {
            const bus = cpu.bus;
            switch (entry.model) {
                .text => {
                    const cells: u32 = @as(u32, entry.twidth) * entry.theight;
                    var i: u32 = 0;
                    while (i < cells) : (i += 1) bus.writePhys16(entry.pstart + i * 2, 0x0720);
                },
                .cga => {
                    // CGA word-fill B800 with 0x0000 (dosbox int10_modes.cpp:830).
                    var off: u32 = 0;
                    while (off < 0x4000) : (off += 2) bus.writePhys16(entry.pstart + off, 0x0000);
                },
                .planar, .packed_256 => {
                    var off: u32 = 0;
                    while (off < 0x10000) : (off += 1) bus.writePhys8(VRAM_PHYS + off, 0);
                },
            }
        }

        /// Write the full BDA field set the real BIOS programs at set-mode (§3.2).
        fn setBda(cpu: *Cpu, bda: bda_mod.Bda(Cpu), entry: *const vga_modes.ModeEntry, clearmem: bool) void {
            const bus = cpu.bus;
            const is_text = entry.model == .text;
            const mono = entry.mode == 0x07 or entry.mode == 0x0F;

            bda.setVideoMode(entry.mode); // CURRENT_MODE 0x49
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS, entry.twidth); // 0x4A
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_PAGE_SIZE, entry.plength); // 0x4C
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURRENT_START, 0); // 0x4E active page 0
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CRTC_ADDRESS, if (mono) 0x3B4 else 0x3D4); // 0x63
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS, @intCast(entry.theight - 1)); // 0x84
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, entry.cheight); // 0x85
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_CTL, 0x60 | @as(u8, if (clearmem) 0 else 0x80)); // 0x87
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_SWITCHES, 0x09); // 0x88
            // DCC: store the spice86 DCC VALUE 0x08 ("VGA with color analog
            // monitor"), NOT dosbox's table INDEX 0x0B — zdos adopts the spice86
            // BDA-byte AH=1A path (§2.5/§6), so AH=1A00 returns this byte directly.
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_DCC_INDEX, 0x08); // 0x8A
            // Per-mode 3D8/3B8 mode-control + 3D9 color-select shadows (CGA-era;
            // text 3 -> 0x29, mode 7 -> 0x29). dosbox int10_modes.cpp:2037-2065.
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_CURRENT_MSR, msrShadow(entry)); // 0x65
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_CURRENT_PAL, if (is_text) 0x30 else 0x00); // 0x66

            // Cursor shape (text only) + cursor positions + active page.
            if (is_text) {
                bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_SHAPE, 0x07); // last
                bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_SHAPE + 1, 0x06); // first
            }
            var page: u16 = 0;
            while (page < 8) : (page += 1) {
                bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + page * 2, 0);
            }
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE, 0);
        }

        /// The CGA mode-control (3D8/3B8) shadow byte the BDA caches per mode
        /// (dosbox int10_modes.cpp:2037-2065). Only meaningful for CGA-compatible
        /// modes; the documented defaults the real BIOS writes.
        fn msrShadow(entry: *const vga_modes.ModeEntry) u8 {
            return switch (entry.mode) {
                0x00, 0x01 => 0x2C,
                0x02, 0x03 => 0x29,
                0x04, 0x05 => 0x2A,
                0x06 => 0x1E,
                0x07 => 0x29,
                else => 0x00, // graphics modes don't use the CGA MSR shadow
            };
        }

        // ------------------------------------------------------------------
        // Shared register-port helpers (spice86 VgaFunctionality private port
        // sequences). EVERY palette/AC/CRTC subfn below drives the VGA device
        // through these EXACT sequences, so a BIOS call and a raw-port guest are
        // byte-identical (the zdos faithfulness principle). The AC path uses the
        // 0x3C0 flip-flop; the CRTC port base is mode-dependent (Misc-Output bit 0).
        // ------------------------------------------------------------------

        /// The live CRTC port base (Misc-Output bit 0 = color 0x3D4 / mono 0x3B4),
        /// read back via 0x3CC (spice86 GetCrtControllerPort, VgaFunctionality.cs:724).
        inline fn crtcPort(cpu: *Cpu) u16 {
            return if ((cpu.bus.portIn8(0x3CC) & 1) != 0) 0x3D4 else 0x3B4;
        }

        /// Write `value` to CRTC register `idx` at the live port base.
        fn writeCrtc(cpu: *Cpu, idx: u8, value: u8) void {
            const base = crtcPort(cpu);
            cpu.bus.portOut8(base, idx);
            cpu.bus.portOut8(base + 1, value);
        }

        /// Write `value` to Attribute-Controller register `idx` via the 0x3C0
        /// flip-flop (spice86 WriteToAttributeController, VgaFunctionality.cs:1248):
        /// reset the flip-flop (read 0x3DA), save the current index|PAS, write the
        /// index (PAS=0 so palette regs 0x00-0x0F are CPU-writable), write the data,
        /// then restore the saved index|PAS byte.
        fn acWrite(cpu: *Cpu, idx: u8, value: u8) void {
            const bus = cpu.bus;
            _ = bus.portIn8(PORT_STATUS1); // reset flip-flop -> index phase
            const orig = bus.portIn8(PORT_AC); // current index | (PAS<<5)
            bus.portOut8(PORT_AC, idx); // index phase, PAS=0
            bus.portOut8(PORT_AC, value); // data phase
            bus.portOut8(PORT_AC, orig); // restore the index/PAS latch
        }

        /// Read Attribute-Controller register `idx` (spice86 ReadAttributeController,
        /// VgaFunctionality.cs:1276): reset flip-flop, save index, write the index,
        /// read 0x3C1 data, reset flip-flop again, restore the saved index byte.
        fn acRead(cpu: *Cpu, idx: u8) u8 {
            const bus = cpu.bus;
            _ = bus.portIn8(PORT_STATUS1);
            const orig = bus.portIn8(PORT_AC);
            bus.portOut8(PORT_AC, idx);
            const value = bus.portIn8(0x3C1); // 0x3C1 = AttributeData read (no flip)
            _ = bus.portIn8(PORT_STATUS1);
            bus.portOut8(PORT_AC, orig);
            return value;
        }

        /// Read-modify-write an AC register (spice86 WriteMaskedToAttributeController).
        fn acWriteMasked(cpu: *Cpu, idx: u8, off_bits: u8, on_bits: u8) void {
            const bus = cpu.bus;
            _ = bus.portIn8(PORT_STATUS1);
            const orig = bus.portIn8(PORT_AC);
            bus.portOut8(PORT_AC, idx);
            const value = bus.portIn8(0x3C1);
            bus.portOut8(PORT_AC, (value & ~off_bits) | on_bits);
            bus.portOut8(PORT_AC, orig);
        }

        /// Set the AC index latch (spice86 SetAttributeControllerIndex) — used to
        /// re-enable video (idx 0x20 = Palette-Address-Source) after a palette walk.
        fn acIndex(cpu: *Cpu, value: u8) void {
            _ = cpu.bus.portIn8(PORT_STATUS1);
            cpu.bus.portOut8(PORT_AC, value);
        }

        // ------------------------------------------------------------------
        // AH=05 — set active display page (plans/vga-spec §2.1). Page -> BDA
        // CURRENT_PAGE(0x62) + CURRENT_START(0x4E)=page*page_size; program CRTC
        // 0x0C/0x0D start-address (the page-flip); move the cursor to that page's
        // saved position. Mirrors spice86 SetActivePage (VgaFunctionality.cs:175).
        // ------------------------------------------------------------------
        fn setActivePage(cpu: *Cpu) void {
            const page = cpu.st.getReg8(0); // AL
            if (page > 7) return;
            const bus = cpu.bus;
            const page_sz = bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_PAGE_SIZE);
            const address: u16 = @truncate(@as(u32, page) * page_sz); // byte offset of the page

            // Program the CRTC display Start Address (0x0C/0x0D). The CRTC value is
            // in display-memory units: text uses word (char/attr) units => ratio 2,
            // so start = address * 2 / 4 = address / 2 (spice86 SetDisplayStart /
            // GetVramRatio: Text=2, Planar=4, packed_256=1). v1: text + 13h.
            const mode = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_MODE);
            const ratio: u32 = vramRatio(mode);
            const start: u16 = @truncate(@as(u32, address) * ratio / 4);
            writeCrtc(cpu, 0x0C, @truncate(start >> 8));
            writeCrtc(cpu, 0x0D, @truncate(start));

            // Update the BDA page state.
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURRENT_START, address);
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE, page);

            // Move the hardware cursor to the new page's saved position (CRTC
            // 0x0E/0x0F, in word units), so the active page's cursor shows.
            const cur = bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2);
            const row: u16 = cur >> 8;
            const col: u16 = cur & 0xFF;
            const cols = blk: {
                const c = bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS);
                break :blk if (c == 0) @as(u16, 80) else c;
            };
            const cursor_off: u16 = @truncate((@as(u32, address) / 2) + row * cols + col);
            writeCrtc(cpu, 0x0E, @truncate(cursor_off >> 8));
            writeCrtc(cpu, 0x0F, @truncate(cursor_off));
        }

        /// VRAM-unit ratio for the CRTC start-address conversion (spice86
        /// GetVramRatio, VgaFunctionality.cs:749): text 2, planar 4, packed-256 1,
        /// CGA 4/bpp. v1 modes are text / 13h / EGA-planar.
        fn vramRatio(mode: u8) u32 {
            const e = vga_modes.find(mode) orelse return 1;
            return switch (e.model) {
                .text => 2,
                .planar => 4,
                .cga => 4, // CGA 2-color/4-color: 4/bpp; both round to a useful base
                .packed_256 => 1,
            };
        }

        // ==================================================================
        // Text-mode video — the flat {char,attr} cell helpers + the AH=08/09/0A
        // services. All geometry comes from the LIVE BDA (cols = OFF_VIDEO_COLS,
        // rows = OFF_NB_ROWS+1, Finding F1) — zdos has no text CurMode table, so
        // the BDA is the single source of truth (mirrors spice86 uniformly). Each
        // service is a host-serviced trap charged the bridge's synthetic base; the
        // cell read/writes go through the bus to text_vram + the BDA (no hole).
        // ==================================================================

        const CharCell = struct { chr: u8, attr: u8 };

        /// The physical base of the active text page (B8000 color / B0000 mono),
        /// chosen by the BDA video mode (mode 7 = mono). The slabs are always
        /// mapped, so this is purely "which window does the BDA mode designate".
        inline fn textBase(cpu: *Cpu) u32 {
            const mode = cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_MODE);
            return if (mode == 0x07) TEXT_MONO_PHYS else TEXT_COLOR_PHYS;
        }

        /// Live text columns from the BDA (OFF_VIDEO_COLS). Defaults sanely to 80
        /// so a stride is never zero even if the BDA is mid-mode-set.
        inline fn textCols(cpu: *Cpu) u16 {
            const c = cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS);
            return if (c == 0) 80 else c;
        }

        /// Live text rows from the BDA (OFF_NB_ROWS is rows-1, so +1).
        inline fn textRows(cpu: *Cpu) u16 {
            return @as(u16, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS)) + 1;
        }

        /// Physical address of the {char,attr} cell at (page,row,col) — the §2.2
        /// layout `pstart + page*PAGE_SIZE + (row*cols+col)*2` (int10_char.cpp:526).
        inline fn cellPhys(cpu: *Cpu, page: u8, row: u16, col: u16) u32 {
            const cols = textCols(cpu);
            const idx: u32 = (@as(u32, row) * cols + col) * 2;
            return textBase(cpu) + @as(u32, page) * TEXT_PAGE_SIZE + idx;
        }

        /// Write a {char,attr} cell. `useattr=false` writes the CHAR byte ONLY and
        /// leaves the attribute byte untouched (Finding F2 — preserve the existing
        /// color; do NOT write a default attr like spice86 does).
        fn writeCharCell(cpu: *Cpu, page: u8, row: u16, col: u16, chr: u8, attr: u8, useattr: bool) void {
            const at = cellPhys(cpu, page, row, col);
            cpu.bus.writePhys8(at, chr);
            if (useattr) cpu.bus.writePhys8(at + 1, attr);
        }

        /// Read a {char,attr} cell back (symmetric; used by AH=08 and the F4 scroll
        /// fill-attr).
        fn readCharCell(cpu: *Cpu, page: u8, row: u16, col: u16) CharCell {
            const at = cellPhys(cpu, page, row, col);
            return .{ .chr = cpu.bus.readPhys8(at), .attr = cpu.bus.readPhys8(at + 1) };
        }

        /// The BDA cursor for `page`, decomposed col = word&0xFF, row = word>>8
        /// (Finding F7; matches AH=02 DX = (DH=row)<<8 | (DL=col)).
        inline fn cursorRowCol(cpu: *Cpu, page: u8) struct { row: u16, col: u16 } {
            const w = cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2);
            return .{ .row = w >> 8, .col = w & 0xFF };
        }
        inline fn setCursorRowCol(cpu: *Cpu, page: u8, row: u16, col: u16) void {
            const w: u16 = (@as(u16, @truncate(row)) << 8) | @as(u16, @truncate(col));
            cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2, w);
        }

        fn readCharCellAtCursor(cpu: *Cpu, page: u8) CharCell {
            const c = cursorRowCol(cpu, page);
            return readCharCell(cpu, page, c.row, c.col);
        }

        /// Scroll/clear a text window (AH=06/07 → INT10_ScrollWindow,
        /// int10_char.cpp:193-294). Inclusive upper-left (rul,cul) / lower-right
        /// (rlr,clr); `rlr`/`clr` are clamped to rows-1/cols-1 and the column range
        /// is treated as inclusive `[cul,clr]` (dosbox's internal `clr++` is its
        /// exclusive-loop convention — F3). `nlines > 0` scrolls content UP by
        /// nlines (the bottom rows are freed + filled), `< 0` scrolls content DOWN,
        /// `== 0` clears the whole window. Exposed rows are filled with
        /// (attr<<8 | ' '). Text-mode only for v1 (page 0, D-TM2).
        fn scrollWindow(cpu: *Cpu, page: u8, rul_in: u8, cul: u8, rlr_in: u8, clr_in: u8, nlines_in: i32, attr: u8) void {
            const cols = textCols(cpu);
            const rows = textRows(cpu);
            if (rul_in > rlr_in) return;
            if (cul > clr_in) return;
            var rlr = rlr_in;
            var clr = clr_in;
            if (rlr >= rows) rlr = @intCast(rows - 1);
            if (clr >= cols) clr = @intCast(cols - 1);
            // The number of cells per row in the window is (clr - cul + 1).
            const fill_word: u16 = (@as(u16, attr) << 8) | ' ';
            const base = textBase(cpu) + @as(u32, page) * TEXT_PAGE_SIZE;

            const fillRow = struct {
                fn run(c: *Cpu, b: u32, ncols: u16, row: u16, cl: u8, cr: u8, fw: u16) void {
                    var x: u16 = cl;
                    while (x <= cr) : (x += 1) {
                        c.bus.writePhys16(b + (@as(u32, row) * ncols + x) * 2, fw);
                    }
                }
            }.run;
            const copyRow = struct {
                fn run(c: *Cpu, b: u32, ncols: u16, rold: u16, rnew: u16, cl: u8, cr: u8) void {
                    var x: u16 = cl;
                    while (x <= cr) : (x += 1) {
                        const v = c.bus.readPhys16(b + (@as(u32, rold) * ncols + x) * 2);
                        c.bus.writePhys16(b + (@as(u32, rnew) * ncols + x) * 2, v);
                    }
                }
            }.run;

            const nlines = nlines_in;
            if (nlines == 0) {
                // Clear the whole window: fill rows [rul, rlr].
                var r: u16 = rul_in;
                while (r <= rlr) : (r += 1) fillRow(cpu, base, cols, r, cul, clr, fill_word);
                return;
            }
            if (nlines > 0) {
                // Scroll UP by nlines: row r <- row r+nlines, for r in [rul, rlr-nlines].
                const n: u16 = @intCast(nlines);
                if (n > rlr - rul_in) {
                    // Scrolls everything off — just clear the window.
                    var r: u16 = rul_in;
                    while (r <= rlr) : (r += 1) fillRow(cpu, base, cols, r, cul, clr, fill_word);
                    return;
                }
                var r: u16 = rul_in;
                while (r + n <= rlr) : (r += 1) copyRow(cpu, base, cols, r + n, r, cul, clr);
                // Fill the exposed bottom n rows.
                var fr: u16 = rlr - n + 1;
                while (fr <= rlr) : (fr += 1) fillRow(cpu, base, cols, fr, cul, clr, fill_word);
            } else {
                // Scroll DOWN by |nlines|: row r <- row r-|nlines| from the bottom up.
                const n: u16 = @intCast(-nlines);
                if (n > rlr - rul_in) {
                    var r: u16 = rul_in;
                    while (r <= rlr) : (r += 1) fillRow(cpu, base, cols, r, cul, clr, fill_word);
                    return;
                }
                var r: u16 = rlr;
                while (r >= rul_in + n) : (r -= 1) copyRow(cpu, base, cols, r - n, r, cul, clr);
                // Fill the exposed top n rows.
                var fr: u16 = rul_in;
                while (fr < rul_in + n) : (fr += 1) fillRow(cpu, base, cols, fr, cul, clr, fill_word);
            }
        }

        /// Teletype output of one char to the active page (AH=0E text mode;
        /// int10_char.cpp:743-810). Honors BS/CR/LF + default-advance + col-wrap +
        /// end-of-screen scroll. `useattr=false` (AH=0E) writes the char byte only
        /// (F2); the AH=13 path passes `useattr=true`. End-of-screen scroll fills
        /// the new bottom line with the attribute AT THE CURSOR (F4). BEL (chr 7)
        /// is a deterministic SILENT no-op (D-TM-BEL — never dosbox's 333 ms
        /// PIC_FullIndex busy-wait). Reads/writes the BDA cursor (col=lo/row=hi, F7).
        fn teletype(cpu: *Cpu, page: u8, chr: u8, attr: u8, useattr: bool) void {
            const cols = textCols(cpu);
            const rows = textRows(cpu);
            const cur = cursorRowCol(cpu, page);
            var row = cur.row;
            var col = cur.col;
            switch (chr) {
                7 => return, // BEL: deterministic silent no-op (cursor unchanged)
                8 => if (col > 0) {
                    col -= 1;
                },
                '\r' => col = 0,
                '\n' => row += 1, // dosbox does NOT reset col on LF
                else => {
                    writeCharCell(cpu, page, row, col, chr, attr, useattr);
                    col += 1;
                },
            }
            if (col == cols) {
                col = 0;
                row += 1;
            }
            if (row == rows) {
                // End-of-screen scroll: fill the new bottom line with the attr at
                // the cursor (F4). dosbox reads INT10_ReadCharAttr at the BDA cursor
                // (still the ENTRY position — SetCursorPos runs at the end), so we
                // read the entry cursor cell's attr, not the advanced local cell.
                const fill = readCharCellAtCursor(cpu, page).attr;
                scrollWindow(cpu, page, 0, 0, @intCast(rows - 1), @intCast(cols - 1), 1, fill);
                row -= 1;
            }
            setCursorRowCol(cpu, page, row, col);
        }

        /// AH=13 write string (INT10_WriteString, int10_char.cpp:862-886). Each
        /// char routes through `teletype` with **useattr=true ALWAYS** (F5; the
        /// opposite of AH=0E). DH/DL = start row/col, AL = flags: bit0 = advance
        /// the cursor (bit0=0 ⇒ RESTORE the entry cursor afterwards), bit1 = the
        /// string is interleaved char/attr pairs (re-read attr per char). BL = the
        /// fixed attribute (bit1=0). ES:BP = the string. CX = char count. BEL inside
        /// is the same silent no-op as in teletype. v1 = page 0 (BH used for page).
        fn writeString(cpu: *Cpu) void {
            const page = cpu.st.getReg8(7); // BH
            const flag = cpu.st.getReg8(0); // AL
            var attr = cpu.st.getReg8(3); // BL
            var count = cpu.st.getReg16(@intFromEnum(Reg32.ecx)); // CX
            const row = cpu.st.getReg8(6); // DH
            const col = cpu.st.getReg8(2); // DL

            // Save the entry cursor (restored when bit0=0).
            const saved = cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2);
            // Position the cursor at the string start.
            setCursorRowCol(cpu, page, row, col);

            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            var ptr: u32 = (@as(u32, eseg) << 4) + cpu.st.getReg16(@intFromEnum(Reg32.ebp)); // ES:BP
            while (count > 0) : (count -= 1) {
                const chr = cpu.bus.readPhys8(ptr);
                ptr += 1;
                if ((flag & 2) != 0) {
                    attr = cpu.bus.readPhys8(ptr);
                    ptr += 1;
                }
                teletype(cpu, page, chr, attr, true); // useattr=true always (F5)
            }
            if ((flag & 1) == 0) {
                // Restore the entry cursor (the string did not advance it).
                cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2, saved);
            }
        }

        /// AH=06 (scroll up) / AH=07 (scroll down). AL=line count (0 ⇒ clear the
        /// whole window), BH=fill attribute, CH/CL = upper-left row/col, DH/DL =
        /// inclusive lower-right row/col (int10.cpp:96-100). v1 = page 0 (D-TM2).
        fn scroll(cpu: *Cpu, down: bool) void {
            const al = cpu.st.getReg8(0); // line count
            const bh = cpu.st.getReg8(7); // fill attribute
            const cul = cpu.st.getReg8(1); // CL
            const rul = cpu.st.getReg8(5); // CH
            const clr = cpu.st.getReg8(2); // DL
            const rlr = cpu.st.getReg8(6); // DH
            const n: i32 = if (down) -@as(i32, al) else @as(i32, al);
            scrollWindow(cpu, 0, rul, cul, rlr, clr, n, bh);
        }

        fn writeCharRep(cpu: *Cpu, useattr: bool) void {
            const page = cpu.st.getReg8(7); // BH
            const chr = cpu.st.getReg8(0); // AL
            const attr = cpu.st.getReg8(3); // BL
            var count = cpu.st.getReg16(@intFromEnum(Reg32.ecx)); // CX
            if (count == 0) return;
            const cur = cursorRowCol(cpu, page);
            const cols = textCols(cpu);
            var row = cur.row;
            var col = cur.col;
            while (count > 0) : (count -= 1) {
                writeCharCell(cpu, page, row, col, chr, attr, useattr);
                col += 1;
                if (col >= cols) {
                    col = 0;
                    row += 1;
                }
            }
        }

        // ------------------------------------------------------------------
        // AH=0C / AH=0D — put / get pixel (mode 13h linear). dosbox-x
        // int10_put_pixel.cpp:200 (`mem_writeb(0xa000:y*320+x, color)`) and :293.
        // CX=x (column), DX=y (row), AL=color (put), BH=page (ignored in 13h).
        // ------------------------------------------------------------------
        fn putPixel(cpu: *Cpu, bda: bda_mod.Bda(Cpu)) void {
            if (bda.videoMode() != 0x13) return; // only the v1 graphics mode
            const x = cpu.st.getReg16(@intFromEnum(Reg32.ecx));
            const y = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            const color = cpu.st.getReg8(0); // AL
            const off: u32 = @as(u32, y) * MODE13_WIDTH + x;
            cpu.bus.writePhys8((VRAM_SEG << 4) + off, color);
        }

        fn getPixel(cpu: *Cpu, bda: bda_mod.Bda(Cpu)) void {
            if (bda.videoMode() != 0x13) return;
            const x = cpu.st.getReg16(@intFromEnum(Reg32.ecx));
            const y = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            const off: u32 = @as(u32, y) * MODE13_WIDTH + x;
            cpu.st.setReg8(0, cpu.bus.readPhys8((VRAM_SEG << 4) + off)); // -> AL
        }

        // ------------------------------------------------------------------
        // AH=10 — palette / DAC functions. We implement the DAC subset BaK uses
        // (fades/day-night): AL=10 set single, AL=12 set block, AL=15 get single,
        // AL=17 get block. Each is the exact DAC port sequence dosbox-x's VGA BIOS
        // emits (int10_pal.cpp), so it drives our VGA device's DAC state machine
        // identically — the BIOS path and a guest's raw port writes are the SAME.
        // (The default BDA MODESET_CTL is 0, so int10_pal.cpp writes RGB directly,
        // never the gray-scale-summing branch — int10_pal.cpp:221/263.)
        // ------------------------------------------------------------------
        fn palette(bios: anytype, cpu: *Cpu, br: anytype) void {
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x00 => setSingleAcReg(cpu), // SET INDIVIDUAL AC PALETTE REGISTER
                0x01 => acWrite(cpu, 0x11, cpu.st.getReg8(7)), // SET OVERSCAN/BORDER (BH -> AC 0x11)
                0x02 => setAllAcRegs(cpu), // SET ALL 16 AC PALETTE + OVERSCAN
                0x03 => toggleBlink(cpu), // TOGGLE BLINK/INTENSITY (AC 0x10 bit 3)
                0x07 => getSingleAcReg(cpu), // GET INDIVIDUAL AC PALETTE REGISTER
                0x08 => cpu.st.setReg8(7, acRead(cpu, 0x11)), // GET OVERSCAN -> BH
                0x09 => getAllAcRegs(cpu), // GET ALL 16 AC PALETTE + OVERSCAN
                0x10 => setSingleDac(cpu), // SET INDIVIDUAL DAC REGISTER
                0x12 => setDacBlock(cpu), // SET BLOCK OF DAC REGISTERS
                0x13 => selectDacPage(cpu), // SELECT DAC COLOR PAGE
                0x15 => getSingleDac(cpu), // GET INDIVIDUAL DAC REGISTER
                0x17 => getDacBlock(cpu), // GET BLOCK OF DAC REGISTERS
                0x18 => cpu.bus.portOut8(PORT_DAC_PEL_MASK, cpu.st.getReg8(3)), // SET PEL MASK (BL)
                0x19 => cpu.st.setReg8(3, cpu.bus.portIn8(PORT_DAC_PEL_MASK)), // GET PEL MASK -> BL
                0x1A => readColorPageState(cpu), // GET DAC COLOR-PAGE STATE
                0x1B => grayScaleSum(cpu), // PERFORM GRAY-SCALE SUMMING
                else => bios.unsupported(cpu, br, 0x10),
            }
        }

        /// AL=00: BL=reg(0..15), BH=value -> AC palette reg (int10_pal.cpp; spice86
        /// SetEgaPaletteRegister, VgaFunctionality.cs:576). Reg must be <= 0x14.
        fn setSingleAcReg(cpu: *Cpu) void {
            const reg = cpu.st.getReg8(3); // BL
            if (reg > 0x14) return;
            acWrite(cpu, reg, cpu.st.getReg8(7)); // BH
        }

        /// AL=07: BL=reg -> BH=value (spice86 ReadPaletteRegister, only regs 0..15).
        fn getSingleAcReg(cpu: *Cpu) void {
            const reg = cpu.st.getReg8(3); // BL
            if (reg > 0x0F) return; // spice86 MaxPaletteRegister
            cpu.st.setReg8(7, acRead(cpu, reg)); // BH
        }

        /// AL=02: ES:DX -> 17 bytes (16 palette + 1 overscan) into AC 0..0x0F,0x11
        /// (spice86 SetAllPaletteRegisters, VgaFunctionality.cs:552).
        fn setAllAcRegs(cpu: *Cpu) void {
            var addr = esDxPhys(cpu);
            var i: u8 = 0;
            while (i < 0x10) : (i += 1) {
                acWrite(cpu, i, cpu.bus.readPhys8(addr));
                addr += 1;
            }
            acWrite(cpu, 0x11, cpu.bus.readPhys8(addr)); // overscan
        }

        /// AL=09: read AC 0..0x0F,0x11 -> ES:DX (17 bytes) (spice86
        /// GetAllPaletteRegisters, VgaFunctionality.cs:518).
        fn getAllAcRegs(cpu: *Cpu) void {
            var addr = esDxPhys(cpu);
            var i: u8 = 0;
            while (i < 0x10) : (i += 1) {
                cpu.bus.writePhys8(addr, acRead(cpu, i));
                addr += 1;
            }
            cpu.bus.writePhys8(addr, acRead(cpu, 0x11)); // overscan
        }

        /// AL=03: BL bit0 -> AC mode reg 0x10 bit 3 (blink vs intensity; spice86
        /// ToggleIntensity, VgaFunctionality.cs:542). bit0=1 => blink enabled.
        fn toggleBlink(cpu: *Cpu) void {
            const on = (cpu.st.getReg8(3) & 0x01) != 0; // BL bit0
            acWriteMasked(cpu, 0x10, 0x08, if (on) 0x08 else 0x00);
        }

        /// AL=13: BL=0 set paging mode (AC 0x10 bit7 from BH bit0); BL=1 select page
        /// (AC 0x14 from BH) (spice86 SetP5P4Select / SetColorSelectRegister, :502/507).
        fn selectDacPage(cpu: *Cpu) void {
            const bl = cpu.st.getReg8(3);
            const bh = cpu.st.getReg8(7);
            if (bl == 0) {
                acWriteMasked(cpu, 0x10, 0x80, if ((bh & 0x01) != 0) 0x80 else 0x00);
            } else {
                // Select page: in 4-page mode (AC 0x10 bit7 = 0) the page is shifted
                // left 2; masked to 4 bits, written to AC 0x14.
                var value = bh;
                if ((acRead(cpu, 0x10) & 0x80) == 0) value <<= 2;
                acWrite(cpu, 0x14, value & 0x0F);
            }
        }

        /// AL=1A: -> BL=mode (AC 0x10 bit7), BH=current page (AC 0x14) (spice86
        /// ReadColorPageState, VgaFunctionality.cs:476). BX = page<<8 | mode.
        fn readColorPageState(cpu: *Cpu) void {
            const p_mode: u8 = acRead(cpu, 0x10) >> 7;
            var cur_page: u8 = acRead(cpu, 0x14) & 0x0F;
            if ((p_mode & 0x01) == 0) cur_page >>= 2;
            cpu.st.setReg8(3, p_mode); // BL = paging mode
            cpu.st.setReg8(7, cur_page); // BH = current page
        }

        /// AL=1B: BX=start, CX=count -> sum the DAC entries to gray (spice86
        /// PerformGrayScaleSumming, VgaFunctionality.cs:415). Integer-only
        /// NTSC luma (77/151/28) — NO float (CLAUDE determinism). Reads/writes the
        /// DAC via the same port path as AL=10/12/15/17.
        fn grayScaleSum(cpu: *Cpu) void {
            const start = cpu.st.getReg8(3); // BL (low byte of BX start)
            const count = cpu.st.getReg16(@intFromEnum(Reg32.ecx)); // CX
            acIndex(cpu, 0x00); // spice86 brackets the walk (SetAttributeControllerIndex)
            var i: u16 = start;
            const end: u16 = @as(u16, start) + count;
            const bus = cpu.bus;
            while (i < end) : (i += 1) {
                const idx: u8 = @truncate(i);
                bus.portOut8(PORT_DAC_READ_ADDR, idx);
                const r: u32 = bus.portIn8(PORT_DAC_DATA);
                const g: u32 = bus.portIn8(PORT_DAC_DATA);
                const b: u32 = bus.portIn8(PORT_DAC_DATA);
                // intensity = (0.3R + 0.59G + 0.11B) in 6-bit, integer-rounded.
                var intensity: u32 = (77 * r + 151 * g + 28 * b + 0x80) >> 8;
                if (intensity > 0x3F) intensity = 0x3F;
                const v: u8 = @truncate(intensity);
                bus.portOut8(PORT_DAC_WRITE_ADDR, idx);
                bus.portOut8(PORT_DAC_DATA, v);
                bus.portOut8(PORT_DAC_DATA, v);
                bus.portOut8(PORT_DAC_DATA, v);
            }
            acIndex(cpu, 0x20); // re-enable video (Palette-Address-Source)
        }

        /// AL=10: index=BL, red=DH, green=CH, blue=CL (int10.cpp:265 ->
        /// int10_pal.cpp:219). Port sequence: 0x3C8=index, then 0x3C9 x3 (R,G,B).
        fn setSingleDac(cpu: *Cpu) void {
            const index = cpu.st.getReg8(3); // BL
            const red = cpu.st.getReg8(6); // DH
            const green = cpu.st.getReg8(5); // CH
            const blue = cpu.st.getReg8(1); // CL
            const bus = cpu.bus;
            bus.portOut8(PORT_DAC_WRITE_ADDR, index);
            bus.portOut8(PORT_DAC_DATA, red);
            bus.portOut8(PORT_DAC_DATA, green);
            bus.portOut8(PORT_DAC_DATA, blue);
        }

        /// AL=15: index=BL -> DH=red, CH=green, CL=blue (int10.cpp:274 ->
        /// int10_pal.cpp:247). Port sequence: 0x3C7=index, then 0x3C9 x3.
        fn getSingleDac(cpu: *Cpu) void {
            const index = cpu.st.getReg8(3); // BL
            const bus = cpu.bus;
            bus.portOut8(PORT_DAC_READ_ADDR, index);
            const red = bus.portIn8(PORT_DAC_DATA);
            const green = bus.portIn8(PORT_DAC_DATA);
            const blue = bus.portIn8(PORT_DAC_DATA);
            cpu.st.setReg8(6, red); // DH
            cpu.st.setReg8(5, green); // CH
            cpu.st.setReg8(1, blue); // CL
        }

        /// AL=12: start=BX, count=CX, data at ES:DX (int10.cpp:268 ->
        /// int10_pal.cpp:254). Port: 0x3C8=start, then for each entry 0x3C9 x3
        /// reading R,G,B from guest memory ES:DX++.
        fn setDacBlock(cpu: *Cpu) void {
            const start = cpu.st.getReg16(@intFromEnum(Reg32.ebx));
            const count = cpu.st.getReg16(@intFromEnum(Reg32.ecx));
            var data = esDxPhys(cpu);
            const bus = cpu.bus;
            bus.portOut8(PORT_DAC_WRITE_ADDR, @truncate(start));
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                const red = bus.readPhys8(data);
                const green = bus.readPhys8(data + 1);
                const blue = bus.readPhys8(data + 2);
                data += 3;
                bus.portOut8(PORT_DAC_DATA, red);
                bus.portOut8(PORT_DAC_DATA, green);
                bus.portOut8(PORT_DAC_DATA, blue);
            }
        }

        /// AL=17: start=BX, count=CX, dest at ES:DX (int10.cpp:277 ->
        /// int10_pal.cpp:306). Port: 0x3C7=start, then for each entry 0x3C9 x3
        /// writing R,G,B to guest memory ES:DX++.
        fn getDacBlock(cpu: *Cpu) void {
            const start = cpu.st.getReg16(@intFromEnum(Reg32.ebx));
            const count = cpu.st.getReg16(@intFromEnum(Reg32.ecx));
            var data = esDxPhys(cpu);
            const bus = cpu.bus;
            bus.portOut8(PORT_DAC_READ_ADDR, @truncate(start));
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                bus.writePhys8(data, bus.portIn8(PORT_DAC_DATA));
                bus.writePhys8(data + 1, bus.portIn8(PORT_DAC_DATA));
                bus.writePhys8(data + 2, bus.portIn8(PORT_DAC_DATA));
                data += 3;
            }
        }

        // ------------------------------------------------------------------
        // AH=11h — character generator (plans/vga-spec/04-modes-int10-bda.md §2.3).
        // Phase 2 implements AH=1130 (get-font-pointer, the LAMUT W1b blocker);
        // the font LOAD subfns (00-04/10-14/20-24) are Phase 5 — they upload to
        // plane 2, which zdos models as a flat text slab (no guest-observable plane
        // 2 yet), so they are flagged loudly rather than silently wrong.
        // ------------------------------------------------------------------
        fn charGen(bios: anytype, cpu: *Cpu, br: anytype) void {
            const al = cpu.st.getReg8(0); // AL = subfunction
            switch (al) {
                // Load font (no activate): user font / ROM 8x14 / ROM 8x8 / ROM 8x16.
                0x00 => loadUserFont(cpu, false),
                0x01 => loadRomFont(cpu, FONT14_OFF, 14, false),
                0x02 => loadRomFont(cpu, FONT8_OFF, 8, false),
                0x03 => setBlockSpecifier(cpu), // SEQ reg 3 char-map select
                0x04 => loadRomFont(cpu, FONT16_OFF, 16, false),
                // Load + activate (recompute CRTC max-scan-line + BDA rows).
                0x10 => loadUserFont(cpu, true),
                0x11 => loadRomFont(cpu, FONT14_OFF, 14, true),
                0x12 => loadRomFont(cpu, FONT8_OFF, 8, true),
                0x14 => loadRomFont(cpu, FONT16_OFF, 16, true),
                // Set INT 1Fh/43h font vectors + BDA char height/rows.
                0x20 => setFontVec(cpu, 0x1F, cpu.st.selector[@intFromEnum(Seg.es)], cpu.st.getReg16(@intFromEnum(Reg32.ebp))),
                0x21 => setGraphicsFontVec(cpu),
                0x22 => setRomGraphicsFontVec(cpu, FONT14_OFF, 14),
                0x23 => setRomGraphicsFontVec(cpu, FONT8_OFF, 8),
                0x24 => setRomGraphicsFontVec(cpu, FONT16_OFF, 16),
                0x30 => getFontPointer(cpu),
                else => bios.unsupported(cpu, br, 0x11),
            }
        }

        /// AH=11 AL=00/10 — load a user font (ES:BP=data) to plane 2 (int10.cpp:220;
        /// spice86 LoadUserFont). zdos models a flat char/attr text slab (D-TM1), so
        /// the plane-2 upload is NOT guest-observable for text rendering. We update
        /// the real STATE (BDA CHAR_HEIGHT, and on activate the rows + CRTC), but the
        /// glyph bytes are not visible. FLAG via the loud assert path if a guest ever
        /// reads plane 2 (src/devices/vga.zig assertSimplePlanar handles that case).
        fn loadUserFont(cpu: *Cpu, activate: bool) void {
            const height = cpu.st.getReg8(7); // BH = bytes per char (cell height)
            // Note: the actual glyph bytes (ES:BP, CX chars, DX first) would upload to
            // plane 2; D-TM1 means they have no text-render effect here. Flagged in
            // the spec — not silently dropped (the BDA/vector state is real).
            if (activate) {
                activateFont(cpu, height); // reads old CHAR_HEIGHT, then writes the new one
            } else {
                cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, height);
            }
        }

        /// AH=11 AL=01/02/04/11/12/14 — load a ROM font (8x8/8x14/8x16). The ROM
        /// bytes already live in BIOS ROM (the staged fonts); a real BIOS copies them
        /// into plane 2 (not guest-observable here, D-TM1). We update BDA CHAR_HEIGHT
        /// and, on activate, the CRTC max-scan-line + BDA rows.
        fn loadRomFont(cpu: *Cpu, font_off: u16, height: u8, activate: bool) void {
            _ = font_off;
            if (activate) {
                activateFont(cpu, height); // reads old CHAR_HEIGHT, then writes the new one
            } else {
                cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, height);
            }
        }

        /// Activate a freshly-loaded font: program CRTC Max-Scan-Line (idx 0x09 low
        /// 5 bits = height-1), recompute BDA rows from the vertical-display-end, and
        /// set CHAR_HEIGHT (spice86 SetScanLines, VgaFunctionality.cs:386). zdos has
        /// no live VDE read; derive rows from the current geometry (VDE = (rows+1)*
        /// old_height stays constant per mode), so rows = VDE/height.
        fn activateFont(cpu: *Cpu, height: u8) void {
            const bus = cpu.bus;
            // CRTC Max-Scan-Line (idx 0x09): keep the high 3 bits, set low 5 to height-1.
            const base = crtcPort(cpu);
            bus.portOut8(base, 0x09);
            const old = bus.portIn8(base + 1);
            bus.portOut8(base, 0x09);
            bus.portOut8(base + 1, (old & 0xE0) | ((height -% 1) & 0x1F));
            // Recompute rows from the constant vertical-display-end (rows*old_height).
            const old_rows: u16 = @as(u16, bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS)) + 1;
            const old_height = bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT);
            const vde: u32 = @as(u32, old_rows) * (if (old_height == 0) height else @as(u8, @truncate(old_height)));
            const rows: u16 = if (height == 0) old_rows else @as(u16, @truncate(vde / height));
            if (rows > 0) bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS, @truncate(rows - 1));
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, height);
        }

        /// AH=11 AL=03 — set block specifier -> SEQ reg 3 (char-map select; spice86
        /// SetFontBlockSpecifier, VgaFunctionality.cs:584). Driven via the SEQ port.
        fn setBlockSpecifier(cpu: *Cpu) void {
            cpu.bus.portOut8(PORT_SEQ_INDEX, 0x03);
            cpu.bus.portOut8(PORT_SEQ_DATA, cpu.st.getReg8(3)); // BL
        }

        /// Set an IVT font vector (seg:off) — INT 1Fh (AL=20) or INT 43h.
        fn setFontVec(cpu: *Cpu, vec: u8, seg: u16, off: u16) void {
            cpu.bus.writePhys16(@as(u32, vec) * 4, off);
            cpu.bus.writePhys16(@as(u32, vec) * 4 + 2, seg);
        }

        /// AH=11 AL=21 — set INT 43h = a user graphics font (ES:BP); BDA char height
        /// = CL, rows from DL/rowspec (spice86 LoadGraphicsFont/LoadUserGraphics).
        fn setGraphicsFontVec(cpu: *Cpu) void {
            const seg = cpu.st.selector[@intFromEnum(Seg.es)];
            const off = cpu.st.getReg16(@intFromEnum(Reg32.ebp));
            const height = cpu.st.getReg8(1); // CL = bytes/char
            setFontVec(cpu, 0x43, seg, off);
            setGraphicsRows(cpu, height, cpu.st.getReg8(3), cpu.st.getReg8(2)); // BL rowspec, DL rows
        }

        /// AH=11 AL=22/23/24 — set INT 43h = a ROM graphics font (8x14/8x8/8x16).
        fn setRomGraphicsFontVec(cpu: *Cpu, font_off: u16, height: u8) void {
            setFontVec(cpu, 0x43, FONT_SEG, font_off);
            setGraphicsRows(cpu, height, cpu.st.getReg8(3), cpu.st.getReg8(2)); // BL rowspec, DL rows
        }

        /// Apply the AL=21-24 row specifier (spice86 LoadGraphicsFont, :668): BL
        /// rowspec 0=DL rows, 1=14, 3=43, else=25; BDA NB_ROWS = rows-1, CHAR_HEIGHT.
        fn setGraphicsRows(cpu: *Cpu, height: u8, rowspec: u8, user_rows: u8) void {
            const rows: u8 = switch (rowspec) {
                0 => user_rows,
                1 => 14,
                3 => 43,
                else => 25,
            };
            if (rows > 0) cpu.bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS, rows - 1);
            cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, height);
        }

        /// AH=1130 — get font pointer (int10.cpp:352-415). BH selects the font;
        /// returns ES:BP = far ptr to the staged ROM font, CX = BDA CHAR_HEIGHT,
        /// DL = BDA NB_ROWS. LAMUT calls BH=03 (ROM 8x8 first 128). The staged
        /// fonts live at FONT*_PHYS in the BIOS segment.
        fn getFontPointer(cpu: *Cpu) void {
            const bh = cpu.st.getReg8(7); // BH = selector
            var seg: u16 = FONT_SEG;
            var off: u16 = undefined;
            switch (bh) {
                0x00 => { // INT 1Fh vector (gfx 8x8 high half)
                    seg = cpu.bus.readPhys16(0x1F * 4 + 2);
                    off = cpu.bus.readPhys16(0x1F * 4);
                },
                0x01 => { // INT 43h vector (active font)
                    seg = cpu.bus.readPhys16(0x43 * 4 + 2);
                    off = cpu.bus.readPhys16(0x43 * 4);
                },
                0x02 => off = FONT14_OFF, // ROM 8x14
                0x03 => off = FONT8_OFF, // ROM 8x8 first 128 (LAMUT)
                0x04 => off = FONT8_2ND_OFF, // ROM 8x8 second 128
                0x05 => off = FONT14_OFF, // 9x14 alternate -> 8x14 (no 9-dot alt staged)
                0x06 => off = FONT16_OFF, // ROM 8x16
                0x07 => off = FONT16_OFF, // 9x16 alternate -> 8x16
                else => off = FONT8_OFF, // documented default
            }
            // ES:BP = far ptr.
            cpu.st.selector[@intFromEnum(Seg.es)] = seg;
            cpu.st.setReg16(@intFromEnum(Reg32.ebp), off);
            // CX = char height, DL = rows-1 (both from the live BDA).
            cpu.st.setReg16(@intFromEnum(Reg32.ecx), cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT));
            cpu.st.setReg8(2, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS)); // DL
        }

        // ------------------------------------------------------------------
        // AH=1Ah — Display Combination Code (plans/vga-spec §2.5). The spice86
        // BDA-byte path (deterministic, no ROM-table walk): AL=00 get -> AX=0x1A,
        // BL = BDA DCC byte (default 0x08 = VGA color), BH=0; AL=01 set -> store BL
        // into the BDA DCC byte. THIS is LAMUT's adapter-detect (BL=0x08 => adapter=8).
        // ------------------------------------------------------------------
        fn dcc(cpu: *Cpu) void {
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x00 => { // get
                    cpu.st.setReg16(0, 0x1A); // AX = 0x1A (function supported)
                    cpu.st.setReg8(3, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_DCC_INDEX)); // BL = active DCC
                    cpu.st.setReg8(7, 0); // BH = inactive (no secondary)
                },
                0x01 => { // set
                    cpu.bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_DCC_INDEX, cpu.st.getReg8(3)); // BL -> BDA
                    cpu.st.setReg16(0, 0x1A);
                },
                else => {}, // other AL: undefined per spec; leave state unchanged
            }
        }

        // ------------------------------------------------------------------
        // AH=12h — alternate function select (plans/vga-spec §2.4). Dispatch on BL.
        // dosbox int10.cpp:431; spice86 VgaBios.cs:366. An unknown BL is a NO-OP
        // (not a fault — Prince of Persia / CheckIt probe invalid BLs; spice86 :397).
        // ------------------------------------------------------------------
        fn altSelect(cpu: *Cpu) void {
            const bus = cpu.bus;
            switch (cpu.st.getReg8(3)) { // BL
                0x10 => { // GET EGA/CONFIG INFO
                    // BH = color(0)/mono(1) from the CRTC base; BL = memory (3=256K);
                    // CH/CL = feature switches (BDA SWITCHES low nibble).
                    const crtc = bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CRTC_ADDRESS);
                    cpu.st.setReg8(7, if (crtc == 0x3B4) 1 else 0); // BH
                    cpu.st.setReg8(3, 0x03); // BL = 256K
                    const sw = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_SWITCHES) & 0x0F;
                    cpu.st.setReg8(5, sw); // CH
                    cpu.st.setReg8(1, sw); // CL
                },
                0x20 => {}, // alternate printscreen — no-op stub
                0x30 => { // SELECT SCAN LINES -> MODESET_CTL + SWITCHES; AL=0x12
                    selectScanLines(cpu, cpu.st.getReg8(0)); // AL = 0/1/2 = 200/350/400
                    cpu.st.setReg8(0, 0x12);
                },
                0x31 => { // PALETTE LOADING ON MODESET -> VIDEO_CTL bit3 (load-default)
                    const on = (cpu.st.getReg8(0) & 0x01) != 0; // AL bit0
                    rmwByte(cpu, bda_mod.OFF_VIDEO_CTL, 0x08, if (on) 0x08 else 0x00);
                    cpu.st.setReg8(0, 0x12);
                },
                0x32 => { // VIDEO ADDRESSING ON/OFF -> Misc-Output bit1 (RAM enable)
                    const on = (cpu.st.getReg8(0) & 0x01) == 0; // AL bit0=0 => enable (spice86)
                    const misc = bus.portIn8(0x3CC);
                    bus.portOut8(PORT_MISC_OUTPUT, (misc & ~@as(u8, 0x02)) | (if (on) @as(u8, 0x02) else 0));
                    cpu.st.setReg8(0, 0x12);
                },
                0x33 => { // GRAY-SCALE SUMMING -> MODESET_CTL bit1
                    const on = (cpu.st.getReg8(0) & 0x01) == 0; // AL bit0=0 => enable
                    rmwByte(cpu, bda_mod.OFF_MODESET_CTL, 0x02, if (on) 0x02 else 0x00);
                    cpu.st.setReg8(0, 0x12);
                },
                0x34 => { // CURSOR EMULATION -> VIDEO_CTL bit0
                    const on = (cpu.st.getReg8(0) & 0x01) == 0; // AL bit0=0 => enable
                    rmwByte(cpu, bda_mod.OFF_VIDEO_CTL, 0x01, if (on) 0x01 else 0x00);
                    cpu.st.setReg8(0, 0x12);
                },
                0x35 => cpu.st.setReg8(0, 0x12), // DISPLAY SWITCH (PS/2) — stub
                0x36 => { // VIDEO SCREEN ON/OFF -> SEQ reg 1 bit 5 (screen disable)
                    const off = (cpu.st.getReg8(0) & 0x01) != 0; // AL=1 => screen off
                    bus.portOut8(PORT_SEQ_INDEX, 0x01);
                    const old = bus.portIn8(PORT_SEQ_DATA);
                    bus.portOut8(PORT_SEQ_INDEX, 0x01);
                    bus.portOut8(PORT_SEQ_DATA, (old & ~@as(u8, 0x20)) | (if (off) @as(u8, 0x20) else 0));
                    cpu.st.setReg8(0, 0x12);
                },
                else => {}, // unknown BL: no-op (spice86 VgaBios.cs:397)
            }
        }

        /// AH=12 BL=30 — select scan lines (spice86 SelectScanLines, :318). Sets the
        /// BDA MODESET_CTL scan-line bits (4/7) + the SWITCHES low nibble.
        fn selectScanLines(cpu: *Cpu, al: u8) void {
            const bus = cpu.bus;
            var modeset = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_MODESET_CTL);
            var switches = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_SWITCHES);
            switch (al) {
                0x00 => { // 200 lines
                    modeset = (modeset & ~@as(u8, 0x10)) | 0x80;
                    switches = (switches & ~@as(u8, 0x0F)) | 0x08;
                },
                0x01 => { // 350 lines
                    modeset = modeset & ~@as(u8, 0x90);
                    switches = (switches & ~@as(u8, 0x0F)) | 0x09;
                },
                0x02 => { // 400 lines
                    modeset = (modeset & ~@as(u8, 0x80)) | 0x10;
                    switches = (switches & ~@as(u8, 0x0F)) | 0x09;
                },
                else => return, // invalid: leave state unchanged
            }
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_MODESET_CTL, modeset);
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_SWITCHES, switches);
        }

        /// Read-modify-write a single BDA byte (clear `off_bits`, set `on_bits`).
        fn rmwByte(cpu: *Cpu, bda_off: u16, off_bits: u8, on_bits: u8) void {
            const at = bda_mod.BDA_PHYS + bda_off;
            const v = cpu.bus.readPhys8(at);
            cpu.bus.writePhys8(at, (v & ~off_bits) | on_bits);
        }

        // ------------------------------------------------------------------
        // AH=1Bh — functionality / state information (plans/vga-spec §2.6). BX must
        // be 0. Fills a 64-byte block at ES:DI: the static-functionality far ptr,
        // a 30-byte BDA copy (0x49..0x66), rows/char-height, the DCC word, color
        // count, page count, scan-line code, misc flags, video memory (3=256K). Set
        // AL=0x1B. dosbox INT10_GetFuncStateInformation (int10_misc.cpp:96).
        // ------------------------------------------------------------------
        fn funcStateInfo(cpu: *Cpu) void {
            if (cpu.st.getReg16(@intFromEnum(Reg32.ebx)) != 0) return; // only BX=0
            const bus = cpu.bus;
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
            const save: u32 = (@as(u32, eseg) << 4) + di;

            // +0: far ptr to the static-functionality table in ROM (§3.3).
            bus.writePhys32(save, (@as(u32, vga_rom.ROM_SEG) << 16) | vga_rom.STATIC_FUNC_OFF);
            // +4: a 30-byte copy of BDA 0x49..0x66 (mode, cols, page-size, start,
            // cursor pos/type, page, CRTC, MSR, PAL). dosbox copies 0x1E bytes.
            var i: u16 = 0;
            while (i < 0x1E) : (i += 1) {
                bus.writePhys8(save + 4 + i, bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_MODE + i));
            }
            // +0x22: rows (NB_ROWS+1) then the two CHAR_HEIGHT bytes (NB_ROWS+1,+2).
            const nb_rows = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS);
            bus.writePhys8(save + 0x22, nb_rows +% 1);
            bus.writePhys8(save + 0x23, bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS + 1));
            bus.writePhys8(save + 0x24, bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS + 2));
            // Zero +0x25..+0x3F before filling the discrete fields (dosbox :112).
            var z: u16 = 0x25;
            while (z < 0x40) : (z += 1) bus.writePhys8(save + z, 0);
            // +0x25: DCC word (active in BL, inactive in BH = 0).
            bus.writePhys16(save + 0x25, bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_DCC_INDEX));
            // The remaining counts come from the current mode geometry.
            const mode = bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_MODE);
            const entry = vga_modes.find(mode);
            // +0x27: color count.
            bus.writePhys16(save + 0x27, colorCount(entry, mode));
            // +0x29: page count.
            bus.writePhys8(save + 0x29, if (entry) |e| e.ptotal else 1);
            // +0x2A: scan-line code (200->0,350->1,400->2,480->3).
            bus.writePhys8(save + 0x2A, scanLineCode(entry));
            // +0x2D: misc flags (text 0x21 / gfx 0x01).
            const is_text = if (entry) |e| e.model == .text else true;
            bus.writePhys8(save + 0x2D, if (is_text) 0x21 else 0x01);
            // +0x31: video memory available (3 = 256K).
            bus.writePhys8(save + 0x31, 3);
            cpu.st.setReg8(0, 0x1B); // AL = 0x1B (function supported)
        }

        /// The color count for AH=1B +0x27 (dosbox int10_misc.cpp:118-138).
        fn colorCount(entry: ?*const vga_modes.ModeEntry, mode: u8) u16 {
            const e = entry orelse return 16;
            return switch (e.model) {
                .text => if (mode == 0x07) @as(u16, 1) else 16,
                .cga => if (mode == 0x06) @as(u16, 2) else 4,
                .planar => if (mode == 0x11 or mode == 0x0F) @as(u16, 2) else 16,
                .packed_256 => 256,
            };
        }

        /// The scan-line code for AH=1B +0x2A (dosbox int10_misc.cpp:142-151).
        fn scanLineCode(entry: ?*const vga_modes.ModeEntry) u8 {
            const e = entry orelse return 2;
            return switch (e.height) {
                200 => 0,
                350 => 1,
                400 => 2,
                480 => 3,
                else => 2,
            };
        }

        /// Real-mode physical address of ES:DX (the DAC block buffer pointer).
        inline fn esDxPhys(cpu: *Cpu) u32 {
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const dx = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            return (@as(u32, eseg) << 4) + dx;
        }
    };
}
