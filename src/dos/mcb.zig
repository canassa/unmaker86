//! The Memory Control Block (MCB) chain (D9) — 16-byte headers in the conventional-
//! memory arena, as guest-RAM views. Layout RE-DERIVED from the documented MCB
//! spec + the dosbox-test-suite behavioral spec:
//!   +0  signature: 'M' (0x4D) = link, 'Z' (0x5A) = last block
//!   +1  owner PSP segment (0 = free, 8 = DOS)
//!   +3  size in paragraphs (16-byte units) of the block FOLLOWING the header
//!   +8  owner name (8 bytes, optional)
//! The block's data starts at (mcb_seg + 1):0000.

const std = @import("std");

pub const SIG_LINK: u8 = 0x4D; // 'M'
pub const SIG_LAST: u8 = 0x5A; // 'Z'
pub const OWNER_FREE: u16 = 0x0000;
pub const OWNER_DOS: u16 = 0x0008;

pub const OFF_SIG: u16 = 0x00;
pub const OFF_OWNER: u16 = 0x01;
pub const OFF_SIZE: u16 = 0x03;

/// Allocation strategy (AH=58). Default first-fit.
pub const Strategy = enum(u8) { first_fit = 0, best_fit = 1, last_fit = 2 };

pub fn McbChain(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,
        /// Segment of the first MCB header in the arena.
        first: u16,
        strategy: Strategy = .first_fit,

        pub fn init(cpu: *Cpu, first_seg: u16) Self {
            return .{ .cpu = cpu, .first = first_seg };
        }

        inline fn rd8(self: Self, seg: u16, off: u16) u8 {
            return self.cpu.bus.readPhys8((@as(u32, seg) << 4) + off);
        }
        inline fn wr8(self: Self, seg: u16, off: u16, v: u8) void {
            self.cpu.bus.writePhys8((@as(u32, seg) << 4) + off, v);
        }
        inline fn rd16(self: Self, seg: u16, off: u16) u16 {
            return self.cpu.bus.readPhys16((@as(u32, seg) << 4) + off);
        }
        inline fn wr16(self: Self, seg: u16, off: u16, v: u16) void {
            self.cpu.bus.writePhys16((@as(u32, seg) << 4) + off, v);
        }

        fn sig(self: Self, mcb: u16) u8 {
            return self.rd8(mcb, OFF_SIG);
        }
        fn owner(self: Self, mcb: u16) u16 {
            return self.rd16(mcb, OFF_OWNER);
        }
        fn size(self: Self, mcb: u16) u16 {
            return self.rd16(mcb, OFF_SIZE);
        }
        fn setHeader(self: Self, mcb: u16, s: u8, own: u16, sz: u16) void {
            self.wr8(mcb, OFF_SIG, s);
            self.wr16(mcb, OFF_OWNER, own);
            self.wr16(mcb, OFF_SIZE, sz);
        }

        /// Create the initial single free block spanning [first+1, arena_end).
        /// `total_paras` is the paragraph count of the whole arena MINUS the first
        /// header. Marks it last + free.
        pub fn initArena(self: Self, total_paras: u16) void {
            self.setHeader(self.first, SIG_LAST, OWNER_FREE, total_paras);
            // Clear the owner-name field for determinism.
            var i: u16 = 8;
            while (i < 16) : (i += 1) self.wr8(self.first, i, 0);
        }

        /// Allocate `paras` paragraphs for `owner_psp`. Returns the DATA segment
        /// (mcb+1) or null if none fits. First-fit (default).
        pub fn alloc(self: Self, paras: u16, owner_psp: u16) ?u16 {
            var mcb = self.first;
            while (true) {
                const s = self.sig(mcb);
                const blocksz = self.size(mcb);
                if (self.owner(mcb) == OWNER_FREE and blocksz >= paras) {
                    self.splitAndClaim(mcb, paras, owner_psp);
                    return mcb + 1;
                }
                if (s == SIG_LAST) return null;
                mcb = mcb + 1 + blocksz;
            }
        }

        /// Largest free block size in paragraphs (for AH=48 failure reporting +
        /// the COM loader "largest block" allocation).
        pub fn largestFree(self: Self) u16 {
            var mcb = self.first;
            var best: u16 = 0;
            while (true) {
                const s = self.sig(mcb);
                const blocksz = self.size(mcb);
                if (self.owner(mcb) == OWNER_FREE and blocksz > best) best = blocksz;
                if (s == SIG_LAST) break;
                mcb = mcb + 1 + blocksz;
            }
            return best;
        }

        fn splitAndClaim(self: Self, mcb: u16, paras: u16, owner_psp: u16) void {
            const blocksz = self.size(mcb);
            const was_last = self.sig(mcb) == SIG_LAST;
            if (blocksz > paras + 1) {
                // Split: claimed block (paras), then a new free remainder block.
                const rem_mcb = mcb + 1 + paras;
                const rem_size = blocksz - paras - 1;
                self.setHeader(rem_mcb, if (was_last) SIG_LAST else SIG_LINK, OWNER_FREE, rem_size);
                self.setHeader(mcb, SIG_LINK, owner_psp, paras);
            } else {
                // Claim the whole block (cannot split a 1-para remainder).
                self.setHeader(mcb, if (was_last) SIG_LAST else SIG_LINK, owner_psp, blocksz);
            }
        }

        /// Free the block whose DATA segment is `data_seg` (mcb = data_seg-1).
        /// Coalesces with a following free block. Returns false if not a valid MCB.
        pub fn free(self: Self, data_seg: u16) bool {
            const mcb = data_seg - 1;
            if (self.sig(mcb) != SIG_LINK and self.sig(mcb) != SIG_LAST) return false;
            self.wr16(mcb, OFF_OWNER, OWNER_FREE);
            self.coalesce();
            return true;
        }

        /// Free every block owned by `owner_psp` (DOS_FreeProcessMemory on a child
        /// terminate, dos_execute.cpp:172) and coalesce. Walks the whole chain.
        pub fn freeByOwner(self: Self, owner_psp: u16) void {
            var mcb = self.first;
            while (true) {
                const s = self.sig(mcb);
                const blocksz = self.size(mcb);
                if (self.owner(mcb) == owner_psp) self.wr16(mcb, OFF_OWNER, OWNER_FREE);
                if (s == SIG_LAST) break;
                mcb = mcb + 1 + blocksz;
            }
            self.coalesce();
        }

        fn coalesce(self: Self) void {
            // Walk from `first`, merging adjacent free blocks (simple + correct).
            var cur = self.first;
            while (self.sig(cur) == SIG_LINK) {
                const next = cur + 1 + self.size(cur);
                if (self.owner(cur) == OWNER_FREE and self.owner(next) == OWNER_FREE) {
                    const merged = self.size(cur) + 1 + self.size(next);
                    self.wr16(cur, OFF_SIZE, merged);
                    if (self.sig(next) == SIG_LAST) self.wr8(cur, OFF_SIG, SIG_LAST);
                    // do not advance: re-check cur against the new following block
                    continue;
                }
                cur = next;
            }
        }

        /// Resize the block at `data_seg` to `new_paras`. Returns the max
        /// available (for AH=4A failure) on failure, or new_paras on success.
        pub fn resize(self: Self, data_seg: u16, new_paras: u16) struct { ok: bool, max: u16 } {
            const mcb = data_seg - 1;
            const cur_size = self.size(mcb);
            if (new_paras <= cur_size) {
                // Shrink: split off a free remainder.
                if (cur_size > new_paras + 1) {
                    const was_last = self.sig(mcb) == SIG_LAST;
                    const rem_mcb = mcb + 1 + new_paras;
                    const rem_size = cur_size - new_paras - 1;
                    self.setHeader(rem_mcb, if (was_last) SIG_LAST else SIG_LINK, OWNER_FREE, rem_size);
                    self.wr8(mcb, OFF_SIG, SIG_LINK);
                    self.wr16(mcb, OFF_SIZE, new_paras);
                }
                return .{ .ok = true, .max = new_paras };
            }
            // Grow: try to absorb a following free block.
            if (self.sig(mcb) == SIG_LINK) {
                const next = mcb + 1 + cur_size;
                if (self.owner(next) == OWNER_FREE) {
                    const combined = cur_size + 1 + self.size(next);
                    if (combined >= new_paras) {
                        const next_last = self.sig(next) == SIG_LAST;
                        self.wr16(mcb, OFF_SIZE, combined);
                        if (next_last) self.wr8(mcb, OFF_SIG, SIG_LAST);
                        // Re-split to exactly new_paras.
                        const r = self.resize(data_seg, new_paras);
                        return r;
                    }
                    return .{ .ok = false, .max = cur_size + 1 + self.size(next) };
                }
            }
            return .{ .ok = false, .max = cur_size };
        }
    };
}
