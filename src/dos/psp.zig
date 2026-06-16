//! The Program Segment Prefix (PSP) — a 256-byte structure as a guest-RAM VIEW
//! (D9). Real bytes at byte-accurate offsets a guest reads. The JFT file-table
//! access goes through the 0x34 far pointer (D9 corrected), not a hardcoded 0x18.

const std = @import("std");

pub const PSP_SIZE: u16 = 256;

// Field offsets (public DOS PSP layout).
pub const OFF_INT20: u16 = 0x00; // CD 20 (INT 20h)
pub const OFF_MEMTOP_SEG: u16 = 0x02; // segment of first byte beyond allocation
pub const OFF_FAR_CALL: u16 = 0x05; // far call to DOS dispatcher (legacy)
pub const OFF_INT22: u16 = 0x0A; // terminate address (dword)
pub const OFF_INT23: u16 = 0x0E; // Ctrl-C address (dword)
pub const OFF_INT24: u16 = 0x12; // critical-error address (dword)
pub const OFF_PARENT_PSP: u16 = 0x16; // parent PSP segment
pub const OFF_JFT: u16 = 0x18; // the default 20-byte JFT
pub const OFF_ENV_SEG: u16 = 0x2C; // environment segment
pub const OFF_STACK: u16 = 0x2E; // far ptr: SS:SP save point for INT 21h / EXEC
// NB: the real PSP has NO version field at 0x30 — that word is the HIGH half of
// the 0x2E saved-stack far pointer (the segment). AH=30 reports the version from
// the kernel constants, never from the PSP. (The old `OFF_DOS_VER=0x30` was a
// mis-derivation that would have aliased the saved-SP segment; removed for the
// EXEC unwind, which reads/writes the SS:SP save point at 0x2E.)
pub const OFF_JFT_SIZE: u16 = 0x32; // max open files (default 20)
pub const OFF_JFT_PTR: u16 = 0x34; // far pointer to the JFT
pub const OFF_FCB1: u16 = 0x5C; // first parsed FCB
pub const OFF_FCB2: u16 = 0x6C; // second parsed FCB
pub const OFF_CMDTAIL_LEN: u16 = 0x80; // command-tail length byte
pub const OFF_CMDTAIL: u16 = 0x81; // command-tail string (CR-terminated)

pub const DEFAULT_MAX_FILES: u16 = 20;
pub const JFT_FREE: u8 = 0xFF; // an unused JFT slot

pub fn Psp(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,
        seg: u16,

        pub fn at(cpu: *Cpu, seg: u16) Self {
            return .{ .cpu = cpu, .seg = seg };
        }

        inline fn phys(self: Self, off: u16) u32 {
            return (@as(u32, self.seg) << 4) + off;
        }
        inline fn rd8(self: Self, off: u16) u8 {
            return self.cpu.bus.readPhys8(self.phys(off));
        }
        inline fn wr8(self: Self, off: u16, v: u8) void {
            self.cpu.bus.writePhys8(self.phys(off), v);
        }
        inline fn rd16(self: Self, off: u16) u16 {
            return self.cpu.bus.readPhys16(self.phys(off));
        }
        inline fn wr16(self: Self, off: u16, v: u16) void {
            self.cpu.bus.writePhys16(self.phys(off), v);
        }

        /// Build a fresh PSP at `self.seg` (D9). `mem_top_seg` = segment past the
        /// allocation; `env_seg` the environment block; `parent` the parent PSP
        /// (0 for the root); `cmdtail` the command tail (without the length byte).
        pub fn build(self: Self, mem_top_seg: u16, env_seg: u16, parent: u16, cmdtail: []const u8) void {
            // Zero the whole PSP first (deterministic, CLAUDE #5).
            var i: u16 = 0;
            while (i < PSP_SIZE) : (i += 1) self.wr8(i, 0);

            self.wr8(OFF_INT20, 0xCD); // INT 20h
            self.wr8(OFF_INT20 + 1, 0x20);
            self.wr16(OFF_MEMTOP_SEG, mem_top_seg);
            // 0x05: far call F000:?? — a long-call opcode + DOS entry (legacy; many
            // programs ignore it). Write the opcode 0x9A (CALL FAR) for shape.
            self.wr8(OFF_FAR_CALL, 0x9A);
            self.wr16(OFF_PARENT_PSP, parent);
            self.wr16(OFF_ENV_SEG, env_seg);

            // The JFT: 20 slots at 0x18, all free, then the 0x34 far pointer ->
            // PSP:0x18 + max_files=20 at 0x32 (D9). ALL JFT access goes through
            // 0x34, not a hardcoded 0x18.
            var j: u16 = 0;
            while (j < DEFAULT_MAX_FILES) : (j += 1) self.wr8(OFF_JFT + j, JFT_FREE);
            self.wr16(OFF_JFT_SIZE, DEFAULT_MAX_FILES);
            self.wr16(OFF_JFT_PTR, OFF_JFT); // offset
            self.wr16(OFF_JFT_PTR + 2, self.seg); // segment

            // Command tail: length byte + string + CR.
            const n: u8 = @intCast(@min(cmdtail.len, 126));
            self.wr8(OFF_CMDTAIL_LEN, n);
            var k: u16 = 0;
            while (k < n) : (k += 1) self.wr8(OFF_CMDTAIL + k, cmdtail[k]);
            self.wr8(OFF_CMDTAIL + n, 0x0D); // CR terminator
        }

        pub fn setParent(self: Self, parent_seg: u16) void {
            self.wr16(OFF_PARENT_PSP, parent_seg);
        }
        pub fn getParent(self: Self) u16 {
            return self.rd16(OFF_PARENT_PSP);
        }
        pub fn envSeg(self: Self) u16 {
            return self.rd16(OFF_ENV_SEG);
        }
        pub fn memTopSeg(self: Self) u16 {
            return self.rd16(OFF_MEMTOP_SEG);
        }

        // INT 22/23/24 save/restore (D-EXEC unwind).
        pub fn saveVectors(self: Self, v22: u32, v23: u32, v24: u32) void {
            self.cpu.bus.writePhys32(self.phys(OFF_INT22), v22);
            self.cpu.bus.writePhys32(self.phys(OFF_INT23), v23);
            self.cpu.bus.writePhys32(self.phys(OFF_INT24), v24);
        }
        pub fn getInt22(self: Self) u32 {
            return self.cpu.bus.readPhys32(self.phys(OFF_INT22));
        }
        pub fn setInt22(self: Self, v: u32) void {
            self.cpu.bus.writePhys32(self.phys(OFF_INT22), v);
        }
        pub fn getInt23(self: Self) u32 {
            return self.cpu.bus.readPhys32(self.phys(OFF_INT23));
        }
        pub fn getInt24(self: Self) u32 {
            return self.cpu.bus.readPhys32(self.phys(OFF_INT24));
        }

        // ---- Saved SS:SP (0x2E) — the parent-resume stack pointer the EXEC unwind
        // restores (DOS_PSP::SetStack/GetStack, dos.h:527-528). Stored as a real-
        // mode far pointer (seg<<16 | off); `seg`/`off` helpers split it. ----
        pub fn setStack(self: Self, seg: u16, off: u16) void {
            self.cpu.bus.writePhys32(self.phys(OFF_STACK), (@as(u32, seg) << 16) | off);
        }
        pub fn getStackSeg(self: Self) u16 {
            return @truncate(self.cpu.bus.readPhys32(self.phys(OFF_STACK)) >> 16);
        }
        pub fn getStackOff(self: Self) u16 {
            return @truncate(self.cpu.bus.readPhys32(self.phys(OFF_STACK)));
        }

        // ---- JFT access via the 0x34 far pointer (D9 corrected) ----
        fn jftPhys(self: Self) u32 {
            const off = self.rd16(OFF_JFT_PTR);
            const seg = self.rd16(OFF_JFT_PTR + 2);
            return (@as(u32, seg) << 4) + off;
        }
        pub fn maxFiles(self: Self) u16 {
            return self.rd16(OFF_JFT_SIZE);
        }
        pub fn jftGet(self: Self, handle: u16) u8 {
            return self.cpu.bus.readPhys8(self.jftPhys() + handle);
        }
        pub fn jftSet(self: Self, handle: u16, sft_index: u8) void {
            self.cpu.bus.writePhys8(self.jftPhys() + handle, sft_index);
        }
        /// Allocate a free JFT slot mapping to `sft_index`; returns the handle or
        /// null if the JFT is full.
        pub fn jftAlloc(self: Self, sft_index: u8) ?u16 {
            const max = self.maxFiles();
            var h: u16 = 0;
            while (h < max) : (h += 1) {
                if (self.jftGet(h) == JFT_FREE) {
                    self.jftSet(h, sft_index);
                    return h;
                }
            }
            return null;
        }
        pub fn jftFree(self: Self, handle: u16) void {
            self.jftSet(handle, JFT_FREE);
        }

        pub fn setMaxFiles(self: Self, n: u16) void {
            self.wr16(OFF_JFT_SIZE, n);
        }
        /// Repoint the JFT far pointer (0x34) at `seg:off` — used by AH=67 when a
        /// larger JFT is allocated outside the PSP's inline 20-byte table.
        pub fn setJftPtr(self: Self, seg: u16, off: u16) void {
            self.wr16(OFF_JFT_PTR, off);
            self.wr16(OFF_JFT_PTR + 2, seg);
        }
    };
}
