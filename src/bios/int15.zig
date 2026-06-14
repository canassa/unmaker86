//! INT 15h — system services (D7). Curated to what a 386 real-mode game touches;
//! the rest flags (D11). EMS does NOT go through INT 15h (it is INT 67h).

const std = @import("std");

pub fn Int15(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            switch (ah) {
                0x88 => { // get extended (>1MB) memory size in KiB -> AX
                    // zdos models 1 MiB + HMA only (no extended memory beyond it);
                    // a faithful answer for a 1 MiB real-mode machine is 0.
                    cpu.st.setReg16(0, 0);
                    br.setGuestCF(false);
                },
                0x24 => { // A20 gate control (AL=00 disable,01 enable,02 status,03 support)
                    const al = cpu.st.getReg8(0);
                    switch (al) {
                        0x00 => {
                            cpu.bus.setA20(false);
                            br.setGuestCF(false);
                        },
                        0x01 => {
                            cpu.bus.setA20(true);
                            br.setGuestCF(false);
                        },
                        0x02 => { // status -> AL = current A20 state
                            cpu.st.setReg8(0, if (cpu.bus.a20Enabled()) 1 else 0);
                            br.setGuestCF(false);
                        },
                        0x03 => { // support -> BX = supported methods
                            cpu.st.setReg16(3, 0x0003);
                            br.setGuestCF(false);
                        },
                        else => bios.unsupported(cpu, br, 0x15),
                    }
                },
                0xC0 => { // get system configuration -> ES:BX = config table
                    // Deferred-and-flagged: no config table modeled. Set CF (the
                    // faithful "not supported" return for AH=C0 on older BIOSes).
                    br.setGuestCF(true);
                    bios.unsupported(cpu, br, 0x15);
                },
                else => bios.unsupported(cpu, br, 0x15),
            }
        }
    };
}
