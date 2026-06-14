//! The File Control Block (FCB) — the legacy pre-handle file interface (INT 21h
//! AH=0F-24). A guest-RAM VIEW (like psp.zig / dta.zig): the 37-byte block lives
//! in the program's own memory at DS:DX and the DOS calls read/write its fields
//! in place. Layout is byte-accurate to dosbox-x `sFCB` (include/dos_inc.h:746):
//!
//!   +0x00  drive        u8   0 = default drive, 1 = A, 2 = B, ...
//!   +0x01  filename[8]   8   space-padded 8.3 name
//!   +0x09  ext[3]        3   space-padded extension
//!   +0x0C  cur_block    u16  current block (sequential I/O)
//!   +0x0E  rec_size     u16  logical record size (defaults to 128)
//!   +0x10  filesize     u32  file size in bytes
//!   +0x14  date         u16  packed date  (host-derived in dosbox; NOT oracle-able)
//!   +0x16  time         u16  packed time  (host-derived in dosbox; NOT oracle-able)
//!   +0x18  reserved[8]       sft_entries/share/extra/file_handle/reserved[4]
//!   +0x20  cur_rec      u8   current record within the block
//!   +0x21  rndm         u32  random relative record number
//!
//! An EXTENDED FCB has a 7-byte prefix: byte +0x00 = 0xFF, bytes +1..+5 reserved,
//! +0x06 = the search/file attribute, and the regular FCB begins at +0x07. The
//! `at()` constructor detects the 0xFF flag and advances `base` past the prefix
//! (mirroring dosbox-x `DOS_FCB::DOS_FCB`, dos_classes.cpp:563), so all field
//! accessors are uniform regardless of extended/normal.
//!
//! `file_handle` (the byte at +0x1B = reserved[3]) holds the OPEN file's SFT slot
//! index directly (not a JFT/guest handle): dosbox-x's FCB calls pass this index
//! to DOS_ReadFile/WriteFile with the `fcb`-mode flag, which treats it as a raw
//! SFT entry — so an FCB-opened file uses the SAME SFT machinery as a handle-
//! opened one (reference-counted, snapshot-consistent). 0xFF = closed.

const std = @import("std");

pub const FCB_DRIVE: u16 = 0x00;
pub const FCB_NAME: u16 = 0x01;
pub const FCB_EXT: u16 = 0x09;
pub const FCB_CUR_BLOCK: u16 = 0x0C;
pub const FCB_REC_SIZE: u16 = 0x0E;
pub const FCB_FILESIZE: u16 = 0x10;
pub const FCB_DATE: u16 = 0x14;
pub const FCB_TIME: u16 = 0x16;
pub const FCB_FILE_HANDLE: u16 = 0x1B; // reserved[3] (offsetof file_handle in sFCB)
pub const FCB_CUR_REC: u16 = 0x20;
pub const FCB_RANDOM: u16 = 0x21;

pub const DEFAULT_REC_SIZE: u16 = 128;
pub const HANDLE_CLOSED: u8 = 0xFF;

pub fn Fcb(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,
        /// Physical address of the FCB base (past the extended prefix, if any).
        base: u32,
        extended: bool,
        /// Physical address of the extended attribute byte (base - 1), or 0.
        attr_phys: u32,

        /// Construct an FCB view at guest seg:off, detecting the extended prefix.
        pub fn at(cpu: *Cpu, seg: u16, off: u16) Self {
            const real = (@as(u32, seg) << 4) + off;
            if (cpu.bus.readPhys8(real) == 0xFF) {
                // Extended FCB: regular fields begin at real+7; attr at real+6.
                return .{ .cpu = cpu, .base = real + 7, .extended = true, .attr_phys = real + 6 };
            }
            return .{ .cpu = cpu, .base = real, .extended = false, .attr_phys = 0 };
        }

        inline fn rd8(self: Self, o: u16) u8 {
            return self.cpu.bus.readPhys8(self.base + o);
        }
        inline fn wr8(self: Self, o: u16, v: u8) void {
            self.cpu.bus.writePhys8(self.base + o, v);
        }
        inline fn rd16(self: Self, o: u16) u16 {
            return self.cpu.bus.readPhys16(self.base + o);
        }
        inline fn wr16(self: Self, o: u16, v: u16) void {
            self.cpu.bus.writePhys16(self.base + o, v);
        }
        inline fn rd32(self: Self, o: u16) u32 {
            return self.cpu.bus.readPhys32(self.base + o);
        }
        inline fn wr32(self: Self, o: u16, v: u32) void {
            self.cpu.bus.writePhys32(self.base + o, v);
        }

        /// The drive index this FCB names (0='A'). Per dosbox-x GetDrive: an FCB
        /// drive byte of 0 means the default drive (the caller resolves that).
        pub fn driveByte(self: Self) u8 {
            return self.rd8(FCB_DRIVE);
        }
        pub fn setDriveByte(self: Self, d: u8) void {
            self.wr8(FCB_DRIVE, d);
        }

        /// Read the 11-byte (8+3) FCB name into `out` (space-padded, as stored).
        pub fn readName(self: Self, out: *[11]u8) void {
            var i: u16 = 0;
            while (i < 8) : (i += 1) out[i] = self.rd8(FCB_NAME + i);
            i = 0;
            while (i < 3) : (i += 1) out[8 + i] = self.rd8(FCB_EXT + i);
        }
        /// Write the 11-byte FCB name (8+3) from `nm`.
        pub fn writeName(self: Self, nm: *const [11]u8) void {
            var i: u16 = 0;
            while (i < 8) : (i += 1) self.wr8(FCB_NAME + i, nm[i]);
            i = 0;
            while (i < 3) : (i += 1) self.wr8(FCB_EXT + i, nm[8 + i]);
        }

        pub fn fileHandle(self: Self) u8 {
            return self.rd8(FCB_FILE_HANDLE);
        }
        pub fn setFileHandle(self: Self, h: u8) void {
            self.wr8(FCB_FILE_HANDLE, h);
        }

        pub fn recSize(self: Self) u16 {
            return self.rd16(FCB_REC_SIZE);
        }
        pub fn setRecSize(self: Self, v: u16) void {
            self.wr16(FCB_REC_SIZE, v);
        }
        pub fn curBlock(self: Self) u16 {
            return self.rd16(FCB_CUR_BLOCK);
        }
        pub fn setCurBlock(self: Self, v: u16) void {
            self.wr16(FCB_CUR_BLOCK, v);
        }
        pub fn curRec(self: Self) u8 {
            return self.rd8(FCB_CUR_REC);
        }
        pub fn setCurRec(self: Self, v: u8) void {
            self.wr8(FCB_CUR_REC, v);
        }
        pub fn random(self: Self) u32 {
            return self.rd32(FCB_RANDOM);
        }
        pub fn setRandom(self: Self, v: u32) void {
            self.wr32(FCB_RANDOM, v);
        }
        pub fn fileSize(self: Self) u32 {
            return self.rd32(FCB_FILESIZE);
        }
        pub fn setFileSize(self: Self, v: u32) void {
            self.wr32(FCB_FILESIZE, v);
        }
        pub fn setDate(self: Self, v: u16) void {
            self.wr16(FCB_DATE, v);
        }
        pub fn setTime(self: Self, v: u16) void {
            self.wr16(FCB_TIME, v);
        }

        /// The extended search/file attribute (dosbox-x GetAttr): only meaningful
        /// for an extended FCB; a normal FCB has no attribute (returns ARCHIVE).
        pub fn attr(self: Self) u8 {
            if (self.extended) return self.cpu.bus.readPhys8(self.attr_phys);
            return 0x20; // DOS_ATTR_ARCHIVE (dosbox-x DOS_FCBCreate default)
        }
    };
}
