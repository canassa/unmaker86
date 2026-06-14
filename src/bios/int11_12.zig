//! INT 11h (equipment list) + INT 12h (conventional memory size). Both read from
//! the BDA — complete and small.

const std = @import("std");
const bda_mod = @import("bda.zig");

pub fn Int1112(comptime Cpu: type) type {
    return struct {
        pub fn handle11(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            // INT 11h -> AX = equipment word.
            cpu.st.setReg16(0, cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_EQUIPMENT));
        }
        pub fn handle12(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            // INT 12h -> AX = conventional memory size in KiB.
            cpu.st.setReg16(0, cpu.bus.readPhys16(bda_mod.BDA_PHYS + bda_mod.OFF_MEMSIZE_KB));
        }
    };
}
