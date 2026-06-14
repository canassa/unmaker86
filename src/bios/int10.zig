//! INT 10h — video (D7). The pixel store is the VGA *device* (out of scope here,
//! flagged in the plan); INT 10h DRIVES it via port/MMIO writes + the BDA. Until
//! the VGA device lands, mode/cursor/get-mode update the BDA (the guest-visible
//! source of truth) and emit the VGA register port writes the device will consume.
//! In scope for BaK: AH=00 set mode (incl. mode 13h), 02 set cursor, 03 get
//! cursor, 0E teletype, 0F get mode, 0C/0D write/read pixel, 10 palette/DAC.

const std = @import("std");
const bda_mod = @import("bda.zig");

pub fn Int10(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00 => { // set video mode
                    const mode = cpu.st.getReg8(0); // AL
                    bda.setVideoMode(mode & 0x7F);
                    // Emit the misc-output / mode select the VGA device consumes.
                    cpu.bus.portOut8(0x3C2, if (mode == 0x13) 0x63 else 0x67);
                    if ((mode & 0x80) == 0) clearVideoMem(cpu, mode & 0x7F);
                },
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
                0x0E => { // teletype output AL (best-effort; CON path is INT 21h)
                    // No VGA text device yet: record nothing, advance no cursor.
                    // Faithful no-op for the framebuffer; flag-free (a real service).
                },
                0x0F => { // get current video mode -> AL=mode, AH=cols, BH=page
                    cpu.st.setReg8(0, bda.videoMode());
                    cpu.st.setReg8(4, @truncate(cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_VIDEO_COLS)));
                    cpu.st.setReg8(7, cpu.bus.readPhys8(bda_mod.BDA_PHYS + bda_mod.OFF_ACTIVE_PAGE));
                },
                0x0C, 0x0D => {}, // write/read pixel -> VGA device (no device yet)
                0x10 => {}, // palette/DAC -> VGA device (no device yet)
                else => bios.unsupported(cpu, br, 0x10),
            }
        }

        fn clearVideoMem(cpu: *Cpu, mode: u8) void {
            // Clearing the (absent) framebuffer is a no-op until the VGA device
            // exists; mode 13h is graphics (0xA0000), text is 0xB8000.
            _ = cpu;
            _ = mode;
        }
    };
}
