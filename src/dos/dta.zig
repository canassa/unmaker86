//! The Disk Transfer Area (DTA, 128 bytes) — a guest-RAM view (D9). The find-
//! first/find-next record is written here. Its date/time fields come from the
//! deterministic source (1993-01-01 epoch / replayed config), NEVER host stat
//! file timestamps (D13). Layout re-derived from the documented find record:
//!   +0x00  21 bytes  reserved (search state: drive, pattern, entry index)
//!   +0x15  1 byte    attribute of matched file
//!   +0x16  2 bytes   file time (packed)
//!   +0x18  2 bytes   file date (packed)
//!   +0x1A  4 bytes   file size
//!   +0x1E  13 bytes  filename (ASCIIZ, 8.3 with dot)

const std = @import("std");

pub const DTA_SIZE: u16 = 128;

pub const OFF_DRIVE: u16 = 0x00; // search drive (1-based)
pub const OFF_PATTERN: u16 = 0x01; // 11-byte FCB search pattern
pub const OFF_SEARCH_IDX: u16 = 0x0D; // entry index (for find-next resume)
pub const OFF_RESERVED_END: u16 = 0x15;
pub const OFF_ATTR: u16 = 0x15;
pub const OFF_TIME: u16 = 0x16;
pub const OFF_DATE: u16 = 0x18;
pub const OFF_SIZE: u16 = 0x1A;
pub const OFF_NAME: u16 = 0x1E;

pub fn Dta(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,
        seg: u16,
        off: u16,

        pub fn at(cpu: *Cpu, seg: u16, off: u16) Self {
            return .{ .cpu = cpu, .seg = seg, .off = off };
        }
        inline fn phys(self: Self, o: u16) u32 {
            return (@as(u32, self.seg) << 4) + self.off + o;
        }

        pub fn writeSearchState(self: Self, drive: u8, pattern: *const [11]u8, idx: u16) void {
            self.cpu.bus.writePhys8(self.phys(OFF_DRIVE), drive);
            for (pattern, 0..) |c, i| self.cpu.bus.writePhys8(self.phys(OFF_PATTERN + @as(u16, @intCast(i))), c);
            self.cpu.bus.writePhys16(self.phys(OFF_SEARCH_IDX), idx);
        }
        pub fn readSearchIdx(self: Self) u16 {
            return self.cpu.bus.readPhys16(self.phys(OFF_SEARCH_IDX));
        }
        pub fn readPattern(self: Self, out: *[11]u8) void {
            for (out, 0..) |*c, i| c.* = self.cpu.bus.readPhys8(self.phys(OFF_PATTERN + @as(u16, @intCast(i))));
        }
        pub fn readDrive(self: Self) u8 {
            return self.cpu.bus.readPhys8(self.phys(OFF_DRIVE));
        }

        /// Write the matched-file record (attr/time/date/size/name). `name` is the
        /// ASCIIZ 8.3-with-dot display form.
        pub fn writeFound(self: Self, attr: u8, time: u16, date: u16, fsize: u32, name: []const u8) void {
            self.cpu.bus.writePhys8(self.phys(OFF_ATTR), attr);
            self.cpu.bus.writePhys16(self.phys(OFF_TIME), time);
            self.cpu.bus.writePhys16(self.phys(OFF_DATE), date);
            self.cpu.bus.writePhys32(self.phys(OFF_SIZE), fsize);
            var i: u16 = 0;
            while (i < name.len and i < 12) : (i += 1) {
                self.cpu.bus.writePhys8(self.phys(OFF_NAME + i), name[i]);
            }
            self.cpu.bus.writePhys8(self.phys(OFF_NAME + i), 0); // ASCIIZ
        }
    };
}
