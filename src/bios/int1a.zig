//! INT 1Ah — time of day (D13). The tick comes from the BDA tick count (PIT-
//! driven by INT 08h), NEVER the host clock.

const std = @import("std");
const bda_mod = @import("bda.zig");

pub fn Int1a(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00 => { // get tick count -> CX:DX = ticks, AL = overflow
                    const t = bda.tickCount();
                    cpu.st.setReg16(1, @truncate(t >> 16)); // CX = high word
                    cpu.st.setReg16(2, @truncate(t)); // DX = low word
                    cpu.st.setReg8(0, bda.tickOverflow());
                    bda.clearTickOverflow();
                },
                0x01 => { // set tick count from CX:DX
                    const t = (@as(u32, cpu.st.getReg16(1)) << 16) | cpu.st.getReg16(2);
                    bda.setTickCount(t);
                    bda.clearTickOverflow();
                },
                else => bios.unsupported(cpu, br, 0x1A),
            }
        }
    };
}
