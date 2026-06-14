//! INT 16h — keyboard (D7). Reads the BDA keyboard ring (filled by the INT 09h/
//! IRQ1 handler from the keyboard device — out of scope here). Determinism: key
//! input is scripted/seeded external input delivered at deterministic cycles via
//! the device->PIC->IRQ path; INT 16h reads the buffer, never the host.

const std = @import("std");
const bda_mod = @import("bda.zig");

pub fn Int16(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00, 0x10 => { // read key (blocking) -> AX = scancode:ascii
                    if (bda.kbDequeue()) |w| {
                        cpu.st.setReg16(0, w);
                    } else {
                        // No key available. A faithful blocking read would spin in
                        // the guest; the host-serviced form returns 0 and the guest
                        // re-issues. (BaK polls via AH=01 first.) Return AX=0.
                        cpu.st.setReg16(0, 0);
                    }
                },
                0x01, 0x11 => { // check key (peek) -> ZF=1 if none, AX = key if any
                    if (bda.kbPeek()) |w| {
                        cpu.st.setReg16(0, w);
                        br.setGuestZF(false);
                    } else {
                        cpu.st.setReg16(0, 0);
                        br.setGuestZF(true);
                    }
                },
                0x02 => { // get shift flags -> AL
                    cpu.st.setReg8(0, bda.kbShiftFlags());
                },
                else => bios.unsupported(cpu, br, 0x16),
            }
        }
    };
}
