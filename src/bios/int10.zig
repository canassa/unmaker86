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

const Reg32 = cpu_state.Reg32;
const Seg = cpu_state.Seg;

// VGA register ports (the BIOS is just a port-write sequencer, like dosbox-x).
const PORT_MISC_OUTPUT: u16 = 0x3C2; // misc output write
const PORT_DAC_READ_ADDR: u16 = 0x3C7; // DAC read index (VGAREG_DAC_READ_ADDRESS)
const PORT_DAC_WRITE_ADDR: u16 = 0x3C8; // DAC write index (VGAREG_DAC_WRITE_ADDRESS)
const PORT_DAC_DATA: u16 = 0x3C9; // DAC data (VGAREG_DAC_DATA)

// Mode 13h linear framebuffer (one byte = one pixel = one palette index).
const VRAM_SEG: u32 = 0xA000;
const MODE13_WIDTH: u32 = 320;

// Text-mode video page bases (mirror src/devices/vga.zig). The flat {char,attr}
// cell layout — byte0 = char, byte1 = attr — at pstart + page*PAGE_SIZE +
// (row*cols+col)*2 (dosbox int10_char.cpp:526-538; identical to spice86).
const TEXT_COLOR_PHYS: u32 = 0xB8000; // modes 0-3 (color)
const TEXT_MONO_PHYS: u32 = 0xB0000; // mode 7 (mono)
const TEXT_PAGE_SIZE: u32 = 0x1000; // dosbox plength for text modes

pub fn Int10(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00 => setMode(cpu, bda), // set video mode
                0x02 => { // set cursor position (DH=row, DL=col, BH=page)
                    const page = cpu.st.getReg8(7); // BH
                    const dx = cpu.st.getReg16(2); // DX = row:col
                    cpu.bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2, dx);
                },
                0x03 => { // get cursor position -> DX, cursor shape -> CX
                    const page = cpu.st.getReg8(7);
                    const dx = cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + @as(u16, page) * 2);
                    cpu.st.setReg16(2, dx);
                    cpu.st.setReg16(1, 0x0607); // standard underline cursor shape
                },
                0x08 => { // read char+attr at cursor -> AL=char, AH=attr
                    const page = cpu.st.getReg8(7); // BH
                    const c = readCharCellAtCursor(cpu, page);
                    cpu.st.setReg8(0, c.chr); // AL
                    cpu.st.setReg8(4, c.attr); // AH
                },
                0x09 => writeCharRep(cpu, true), // write char+attr at cursor x CX
                0x0A => writeCharRep(cpu, false), // write char (attr untouched) x CX
                0x0C => putPixel(cpu, bda), // write graphics pixel
                0x0D => getPixel(cpu, bda), // read graphics pixel
                0x0E => { // teletype output AL (best-effort; CON path is INT 21h)
                    // No VGA text device modeled (mode 13h is graphics); faithful
                    // no-op for the framebuffer. The DOS CON path carries text.
                },
                0x0F => { // get current video mode -> AL=mode, AH=cols, BH=page
                    cpu.st.setReg8(0, bda.videoMode());
                    cpu.st.setReg8(4, @truncate(cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS)));
                    cpu.st.setReg8(7, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE));
                },
                0x10 => palette(bios, cpu, br), // palette / DAC functions
                else => bios.unsupported(cpu, br, 0x10),
            }
        }

        // ------------------------------------------------------------------
        // AH=00 — set video mode. Faithful to dosbox-x for mode 13h; other modes
        // update the BDA + misc-output the same way (the device honors whatever the
        // BIOS programs). The D3 scope is mode 13h; anything else still lands a
        // documented BDA so AH=0F is coherent, but only 13h's full register/VRAM
        // path is exercised by the v1 oracle.
        // ------------------------------------------------------------------
        fn setMode(cpu: *Cpu, bda: bda_mod.Bda(Cpu)) void {
            const al = cpu.st.getReg8(0); // AL = mode (bit7 = no-clear)
            const mode = al & 0x7F;
            const clearmem = (al & 0x80) == 0;

            if (mode == 0x13) {
                setModeVga13(cpu, bda, clearmem);
            } else {
                // Non-13h: record the mode in the BDA (coherent AH=0F) without the
                // full VGA register program (out of D3 scope; not faked as 13h).
                bda.setVideoMode(mode);
            }
        }

        /// Mode 0x13 (M_VGA 320x200x256). Mirrors FinishSetMode for the BDA fields
        /// (int10_modes.cpp:942-985) + the misc-output write (int10_modes.cpp:1580)
        /// + the VRAM clear (int10_modes.cpp:935). All values are the mode-13h table
        /// entry (int10_modes.cpp:100): twidth=40, plength=0x2000, theight=25,
        /// cheight=8, vdispend=200 (=> misc_output 0x23 for color VGA).
        fn setModeVga13(cpu: *Cpu, bda: bda_mod.Bda(Cpu), clearmem: bool) void {
            const bus = cpu.bus;
            // Misc output: 0x2 | 0x1 (color) | 0x20 (vdispend==200). int10_modes.cpp
            // :1552-1575. The VGA device latches this (read back at 0x3CC).
            bus.portOut8(PORT_MISC_OUTPUT, 0x23);

            // VRAM clear (FinishSetMode M_VGA path). The whole linear framebuffer
            // window is zeroed via the bus -> VGA host-pointer fast path.
            if (clearmem) {
                var off: u32 = 0;
                while (off < 0x10000) : (off += 1) {
                    bus.writePhys8((VRAM_SEG << 4) + off, 0);
                }
            }

            // BDA fields (FinishSetMode, int10_modes.cpp:942-985).
            bda.setVideoMode(0x13); // BIOSMEM_CURRENT_MODE
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS, 40); // NB_COLS = twidth
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_PAGE_SIZE, 0x2000); // PAGE_SIZE = plength
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CRTC_ADDRESS, 0x3D4); // color CRTC base
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_NB_ROWS, 24); // theight - 1
            bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CHAR_HEIGHT, 8); // cheight
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_CTL, if (clearmem) 0x60 else 0xE0); // 0x60|(clearmem?0:0x80)
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_DCC_INDEX, 0x0B); // VGA DCC index

            // Cursor positions for pages 0..7 = (0,0); active page 0
            // (FinishSetMode:992-994). Mode 13h has no text cursor, but the BIOS
            // still resets these BDA words.
            var page: u16 = 0;
            while (page < 8) : (page += 1) {
                bus.writePhys16(bda_mod.BDA_PHYS + bda_mod.OFF_CURSOR_POS + page * 2, 0);
            }
            bus.writePhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE, 0);
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

        /// AH=09 (useattr=true: BL=attr) / AH=0A (useattr=false: char only). Writes
        /// AL (char) BL (attr) CX times at the CURRENT cursor WITHOUT advancing it
        /// (int10.cpp:105-111). v1 operates on page 0 (BH ignored beyond 0, D-TM2).
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
                0x10 => setSingleDac(cpu), // SET INDIVIDUAL DAC REGISTER
                0x12 => setDacBlock(cpu), // SET BLOCK OF DAC REGISTERS
                0x15 => getSingleDac(cpu), // GET INDIVIDUAL DAC REGISTER
                0x17 => getDacBlock(cpu), // GET BLOCK OF DAC REGISTERS
                else => bios.unsupported(cpu, br, 0x10),
            }
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

        /// Real-mode physical address of ES:DX (the DAC block buffer pointer).
        inline fn esDxPhys(cpu: *Cpu) u32 {
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const dx = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            return (@as(u32, eseg) << 4) + dx;
        }
    };
}
