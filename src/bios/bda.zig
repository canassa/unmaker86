//! The BIOS Data Area (BDA) at 0040:0000 (linear 0x400) — typed accessors over
//! guest RAM (D9 view model). The BDA is REAL bytes in conventional memory; a
//! guest reads them at byte-accurate offsets. Offsets re-derived from the public
//! BDA layout spec. All values are deterministic (CLAUDE #5).

const std = @import("std");

pub const BDA_SEG: u16 = 0x0040;
pub const BDA_PHYS: u32 = 0x0400;

// Field offsets within the BDA segment (public spec).
pub const OFF_EQUIPMENT: u16 = 0x10; // equipment word
pub const OFF_MEMSIZE_KB: u16 = 0x13; // conventional memory size in KiB
pub const OFF_KB_FLAG0: u16 = 0x17; // keyboard shift flags 0
pub const OFF_KB_FLAG1: u16 = 0x18; // keyboard shift flags 1
pub const OFF_KB_BUF_HEAD: u16 = 0x1A; // keyboard buffer head pointer
pub const OFF_KB_BUF_TAIL: u16 = 0x1C; // keyboard buffer tail pointer
pub const OFF_KB_BUF: u16 = 0x1E; // keyboard buffer ring (16 words)
pub const OFF_KB_BUF_START: u16 = 0x80; // ring start pointer
pub const OFF_KB_BUF_END: u16 = 0x82; // ring end pointer
pub const OFF_VIDEO_MODE: u16 = 0x49; // current video mode
pub const OFF_VIDEO_COLS: u16 = 0x4A; // text columns
pub const OFF_VIDEO_PAGE_SIZE: u16 = 0x4C; // page size in bytes
pub const OFF_CURSOR_POS: u16 = 0x50; // cursor positions (8 pages, word each)
pub const OFF_CURSOR_SHAPE: u16 = 0x60; // cursor shape
pub const OFF_ACTIVE_PAGE: u16 = 0x62; // active display page
pub const OFF_TICK_COUNT: u16 = 0x6C; // timer tick count (dword)
pub const OFF_TICK_OVERFLOW: u16 = 0x70; // 24h rollover flag
pub const OFF_RESET_FLAG: u16 = 0x72;

// The keyboard ring spans buffer offsets [0x1E, 0x3E) — 16 words.
pub const KB_BUF_LO: u16 = 0x1E;
pub const KB_BUF_HI: u16 = 0x3E;

/// A typed view over the BDA. Generic over the CPU type so it uses the existing
/// physical-memory surface (the BDA is at a fixed linear address).
pub fn Bda(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,

        pub fn init(cpu: *Cpu) Self {
            return .{ .cpu = cpu };
        }

        inline fn rd16(self: Self, off: u16) u16 {
            return self.cpu.bus.readPhys16(BDA_PHYS + off);
        }
        inline fn wr16(self: Self, off: u16, v: u16) void {
            self.cpu.bus.writePhys16(BDA_PHYS + off, v);
        }
        inline fn rd32(self: Self, off: u16) u32 {
            return self.cpu.bus.readPhys32(BDA_PHYS + off);
        }
        inline fn wr32(self: Self, off: u16, v: u32) void {
            self.cpu.bus.writePhys32(BDA_PHYS + off, v);
        }
        inline fn rd8(self: Self, off: u16) u8 {
            return self.cpu.bus.readPhys8(BDA_PHYS + off);
        }
        inline fn wr8(self: Self, off: u16, v: u8) void {
            self.cpu.bus.writePhys8(BDA_PHYS + off, v);
        }

        /// Deterministic BDA init at POST (CLAUDE #5). Documented values for a
        /// 640 KiB / VGA / 1-floppy real-mode PC, matching BaK's expectations.
        pub fn initDefaults(self: Self) void {
            // Equipment word: VGA color (bits 4-5 = 00), 1 floppy present (bit 0),
            // 80x87 absent (bit 1 = 0). 0x0021 = floppy present + bit5 (initial
            // video mode). Use the classic 0x0021 from a typical VGA POST.
            self.wr16(OFF_EQUIPMENT, 0x0021);
            self.wr16(OFF_MEMSIZE_KB, 640); // 640 KiB conventional
            self.wr8(OFF_KB_FLAG0, 0);
            self.wr8(OFF_KB_FLAG1, 0);
            // Keyboard ring: head == tail == ring start (empty).
            self.wr16(OFF_KB_BUF_HEAD, KB_BUF_LO);
            self.wr16(OFF_KB_BUF_TAIL, KB_BUF_LO);
            self.wr16(OFF_KB_BUF_START, KB_BUF_LO);
            self.wr16(OFF_KB_BUF_END, KB_BUF_HI);
            self.wr8(OFF_VIDEO_MODE, 0x03); // 80x25 text at boot
            self.wr16(OFF_VIDEO_COLS, 80);
            self.wr8(OFF_ACTIVE_PAGE, 0);
            self.wr32(OFF_TICK_COUNT, 0);
            self.wr8(OFF_TICK_OVERFLOW, 0);
        }

        // ---- Timer tick (INT 08h / INT 1Ah, D13) ----
        pub fn tickCount(self: Self) u32 {
            return self.rd32(OFF_TICK_COUNT);
        }
        pub fn setTickCount(self: Self, v: u32) void {
            self.wr32(OFF_TICK_COUNT, v);
        }
        /// Increment the tick; set the 24h overflow flag at the BIOS rollover
        /// value 0x1800B0 (1573040 ticks/day). Returns true on rollover.
        pub fn incTick(self: Self) bool {
            var t = self.tickCount() +% 1;
            var rolled = false;
            if (t >= 0x1800B0) {
                t = 0;
                rolled = true;
                self.wr8(OFF_TICK_OVERFLOW, self.rd8(OFF_TICK_OVERFLOW) +% 1);
            }
            self.setTickCount(t);
            return rolled;
        }
        pub fn tickOverflow(self: Self) u8 {
            return self.rd8(OFF_TICK_OVERFLOW);
        }
        pub fn clearTickOverflow(self: Self) void {
            self.wr8(OFF_TICK_OVERFLOW, 0);
        }

        // ---- Video ----
        pub fn videoMode(self: Self) u8 {
            return self.rd8(OFF_VIDEO_MODE);
        }
        pub fn setVideoMode(self: Self, m: u8) void {
            self.wr8(OFF_VIDEO_MODE, m);
        }

        // ---- Keyboard ring (INT 09h fills, INT 16h drains) ----
        pub fn kbHead(self: Self) u16 {
            return self.rd16(OFF_KB_BUF_HEAD);
        }
        pub fn kbTail(self: Self) u16 {
            return self.rd16(OFF_KB_BUF_TAIL);
        }
        pub fn kbEmpty(self: Self) bool {
            return self.kbHead() == self.kbTail();
        }
        /// Enqueue a scancode:ascii word; returns false if the ring is full.
        pub fn kbEnqueue(self: Self, word: u16) bool {
            const tail = self.kbTail();
            var next = tail + 2;
            if (next >= KB_BUF_HI) next = KB_BUF_LO;
            if (next == self.kbHead()) return false; // full
            self.wr16(tail, word);
            self.wr16(OFF_KB_BUF_TAIL, next);
            return true;
        }
        /// Peek the head word without consuming (null if empty).
        pub fn kbPeek(self: Self) ?u16 {
            if (self.kbEmpty()) return null;
            return self.rd16(self.kbHead());
        }
        /// Dequeue the head word (null if empty).
        pub fn kbDequeue(self: Self) ?u16 {
            if (self.kbEmpty()) return null;
            const head = self.kbHead();
            const w = self.rd16(head);
            var next = head + 2;
            if (next >= KB_BUF_HI) next = KB_BUF_LO;
            self.wr16(OFF_KB_BUF_HEAD, next);
            return w;
        }
        pub fn kbShiftFlags(self: Self) u8 {
            return self.rd8(OFF_KB_FLAG0);
        }
    };
}
