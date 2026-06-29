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

pub fn McbChain(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        cpu: *Cpu,
        /// Segment of the first MCB header in the arena.
        first: u16,
        /// The INT 21h AH=58 allocation-strategy byte: fit-type = `strategy & 0x3f`
        /// (0=first, 1=best, >=2=last), UMB/high bits = `strategy & 0xc0` (inert here
        /// because zdos models no UMB region). Plumbed in from `Dos.strategy`.
        strategy: u8 = 0,

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

        /// Build the standard-PC pre-fragmented arena chain dosbox plants in
        /// `DOS_SetupMemory` for a non-Tandy/non-PCjr machine (dos_memory.cpp:
        /// 484-565). `self.first` MUST be `DOS_MEM_START` (0x16F). Four blocks,
        /// ending at `ARENA_TOP` (0x9FFE), leaving 0x9FFF a bare unowned paragraph
        /// (faithful real-DOS-without-UMBs — no 0x9FFF UMB-cover MCB):
        ///   first+0x00 (0x16F) 'M' owner 0x0008 (DOS)  size 1      — device dummy
        ///   first+0x02 (0x171) 'M' owner 0 (free)       size 4      — grown-env remnant
        ///   first+0x07 (0x176) 'M' owner 0x0040         size 16     — loadfix lock
        ///   first+0x18 (0x187) 'Z' owner 0 (free)       size 0x9E77 — big free, last
        /// All owner-name fields zeroed (determinism). The non-free dummy(8)/
        /// loadfix(0x40) blocks are non-coalescible, so the first user alloc lands
        /// in the 'Z' block (data ~0x188) — env then program ~0x190.
        pub fn initPreFragmented(self: Self) void {
            const dummy = self.first; // 0x16F
            const small = self.first + 2; // 0x171
            const lock = self.first + 7; // 0x176
            const big = self.first + 0x18; // 0x187
            self.setHeader(dummy, SIG_LINK, OWNER_DOS, 1);
            self.setHeader(small, SIG_LINK, OWNER_FREE, 4);
            self.setHeader(lock, SIG_LINK, 0x0040, 16);
            // The big free block is sized to end exactly at ARENA_TOP (0x9FFE):
            // size = 0x9FFE - big (== 0x9FFE - first - 0x18 == 0x9E77 for 0x16F).
            self.setHeader(big, SIG_LAST, OWNER_FREE, 0x9FFE - big);
            for ([_]u16{ dummy, small, lock, big }) |h| {
                var i: u16 = 8;
                while (i < 16) : (i += 1) self.wr8(h, i, 0);
            }
        }

        /// Allocate `paras` paragraphs for `owner_psp`, honoring the DOS allocation
        /// strategy (`self.strategy`): fit-type = `strategy & 0x3f` (0=first, 1=best,
        /// >=2=last). Returns the DATA segment, or null if nothing fits. The free list
        /// is compacted first — faithful DOS_AllocateMemory calls DOS_CompressMemory at
        /// entry (dos_memory.cpp:161); `free()` defers coalescing to here. The high/UMB
        /// bits are intentionally inert: dosbox only honors them when a UMB chain exists
        /// (`umb_start == umb_start_seg`, dos_memory.cpp:167-171,226), and zdos has no
        /// UMB region — so this byte-matches dosbox's no-UMB path. A future UMB region
        /// would wire the redirect/fallback at those reference lines.
        pub fn alloc(self: Self, paras: u16, owner_psp: u16) ?u16 {
            self.coalesce();
            const fit: u8 = self.strategy & 0x3f;
            var mcb = self.first;
            var found: ?u16 = null;
            var found_size: u16 = 0;
            while (true) {
                const s = self.sig(mcb);
                const blocksz = self.size(mcb);
                if (self.owner(mcb) == OWNER_FREE and blocksz >= paras) {
                    switch (fit) {
                        0 => return self.splitAndClaim(mcb, paras, owner_psp, false), // first-fit: claim now
                        1 => if (found == null or blocksz < found_size) { // best-fit: smallest fitting
                            found = mcb;
                            found_size = blocksz;
                        },
                        else => { // last-fit: keep overwriting -> the LAST fitting block
                            found = mcb;
                            found_size = blocksz;
                        },
                    }
                }
                if (s == SIG_LAST) break;
                const next: u32 = @as(u32, mcb) + 1 + blocksz;
                if (next > 0xFFFF) break; // corrupt-chain guard (no u16 wrap)
                mcb = @intCast(next);
            }
            const f = found orelse return null;
            return self.splitAndClaim(f, paras, owner_psp, fit >= 2);
        }

        /// Largest free block size in paragraphs (for AH=48 failure reporting + the COM
        /// loader "largest block" allocation). Compacts first so a just-freed region
        /// (since `free()` no longer coalesces) is reported at its merged size.
        pub fn largestFree(self: Self) u16 {
            self.coalesce();
            var mcb = self.first;
            var best: u16 = 0;
            while (true) {
                const s = self.sig(mcb);
                const blocksz = self.size(mcb);
                if (self.owner(mcb) == OWNER_FREE and blocksz > best) best = blocksz;
                if (s == SIG_LAST) break;
                const next: u32 = @as(u32, mcb) + 1 + blocksz;
                if (next > 0xFFFF) break;
                mcb = @intCast(next);
            }
            return best;
        }

        /// Claim `paras` paragraphs out of the free block at `mcb`; returns the DATA
        /// segment. `claim_high` = false puts the claimed block at the LOW end (first/
        /// best-fit) with the free remainder above; true puts it at the HIGH end (last-
        /// fit, dos_memory.cpp:260-269) with the free remainder below. When `blocksz >
        /// paras` the split ALWAYS happens — a 0-paragraph free-header remainder is left
        /// when `blocksz == paras+1` (matching faithful DOS; never absorbed). The block
        /// that inherits the original's LAST-ness differs: the remainder (low) vs the
        /// claimed block (high).
        fn splitAndClaim(self: Self, mcb: u16, paras: u16, owner_psp: u16, claim_high: bool) u16 {
            const blocksz = self.size(mcb);
            const was_last = self.sig(mcb) == SIG_LAST;
            if (blocksz == paras) {
                // Exact fit: claim the whole block, no split.
                self.setHeader(mcb, if (was_last) SIG_LAST else SIG_LINK, owner_psp, blocksz);
                return mcb + 1;
            }
            const rem_size = blocksz - paras - 1; // free remainder paras (0 when blocksz==paras+1)
            if (claim_high) {
                // Claimed block at the TOP; free remainder stays below at `mcb` as a
                // LINK block; the CLAIMED block inherits the original's LAST-ness.
                const claimed_mcb = mcb + 1 + rem_size; // == mcb + blocksz - paras
                self.setHeader(mcb, SIG_LINK, OWNER_FREE, rem_size);
                self.setHeader(claimed_mcb, if (was_last) SIG_LAST else SIG_LINK, owner_psp, paras);
                return claimed_mcb + 1;
            }
            // Claimed block at the LOW end; free remainder above inherits LAST-ness.
            const rem_mcb = mcb + 1 + paras;
            self.setHeader(rem_mcb, if (was_last) SIG_LAST else SIG_LINK, OWNER_FREE, rem_size);
            self.setHeader(mcb, SIG_LINK, owner_psp, paras);
            return mcb + 1;
        }

        /// Free the block whose DATA segment is `data_seg` (mcb = data_seg-1). Marks it
        /// free but does NOT coalesce — faithful DOS_FreeMemory defers compaction to the
        /// next alloc/resize/largestFree (dos_memory.cpp:377). Returns false if not a
        /// valid MCB.
        pub fn free(self: Self, data_seg: u16) bool {
            // Faithful DOS_FreeMemory (dos_memory.cpp:363-378): a segment below the
            // first MCB's data area (data_seg <= self.first, i.e. < DOS_MEM_START+1)
            // is an invalid block address — DOS sets DOSERR_MB_ADDRESS_INVALID and
            // returns false; it never lets `segment-1` underflow into a wild MCB.
            if (data_seg <= self.first) return false;
            const mcb = data_seg - 1;
            if (self.sig(mcb) != SIG_LINK and self.sig(mcb) != SIG_LAST) return false;
            self.wr16(mcb, OFF_OWNER, OWNER_FREE);
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
                const next: u32 = @as(u32, mcb) + 1 + blocksz;
                if (next > 0xFFFF) break;
                mcb = @intCast(next);
            }
            self.coalesce();
        }

        fn coalesce(self: Self) void {
            // Walk from `first`, merging adjacent free blocks (simple + correct).
            var cur = self.first;
            while (self.sig(cur) == SIG_LINK) {
                const next32: u32 = @as(u32, cur) + 1 + self.size(cur);
                if (next32 > 0xFFFF) break; // corrupt-chain guard
                const next: u16 = @intCast(next32);
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

        /// Resize the block at `data_seg` to `new_paras`. Returns the max available (for
        /// AH=4A failure) on failure, or new_paras on success. Compacts first — faithful
        /// DOS_ResizeMemory calls DOS_CompressMemory (dos_memory.cpp:296) so a grow can
        /// absorb a just-freed neighbour.
        pub fn resize(self: Self, data_seg: u16, new_paras: u16) struct { ok: bool, max: u16 } {
            // Faithful DOS_ResizeMemory (dos_memory.cpp:285-294): an out-of-range
            // segment (data_seg <= self.first, i.e. < DOS_MEM_START+1) or an MCB
            // whose signature isn't link/last is a destroyed-MCB error — fail
            // without underflowing `data_seg-1` and without touching the caller's
            // requested block count (dosbox leaves *blocks unchanged in this path).
            if (data_seg <= self.first) return .{ .ok = false, .max = new_paras };
            const mcb = data_seg - 1;
            if (self.sig(mcb) != SIG_LINK and self.sig(mcb) != SIG_LAST) return .{ .ok = false, .max = new_paras };
            self.coalesce();
            const cur_size = self.size(mcb);
            if (new_paras <= cur_size) {
                // Shrink: split off a free remainder. Always split when cur_size >
                // new_paras (a 0-paragraph remainder header when cur_size == new_paras+1).
                if (cur_size > new_paras) {
                    const was_last = self.sig(mcb) == SIG_LAST;
                    const rem_mcb = mcb + 1 + new_paras;
                    const rem_size = cur_size - new_paras - 1;
                    self.setHeader(rem_mcb, if (was_last) SIG_LAST else SIG_LINK, OWNER_FREE, rem_size);
                    self.wr8(mcb, OFF_SIG, SIG_LINK);
                    self.wr16(mcb, OFF_SIZE, new_paras);
                    // Faithful: DOS_ResizeMemory compacts after the shrink too
                    // (dos_memory.cpp:316), merging the new remainder with a following
                    // free block — keeps the chain byte-identical to dosbox.
                    self.coalesce();
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
                        return self.resize(data_seg, new_paras);
                    }
                    return .{ .ok = false, .max = cur_size + 1 + self.size(next) };
                }
            }
            return .{ .ok = false, .max = cur_size };
        }
    };
}

// =====================================================================
// Tests — the allocator in isolation over a fake byte-addressed bus (no
// Machine dependency; fully deterministic). MCB header = 16 bytes: +0 sig,
// +1 owner (u16), +3 size-in-paragraphs (u16). The `sig/owner/size/setHeader`
// helpers are file-private but reachable from same-file tests.
// =====================================================================
const TestCpu = struct {
    bus: Bus,
    const Bus = struct {
        ram: []u8,
        pub fn readPhys8(self: *Bus, a: u32) u8 {
            return self.ram[a];
        }
        pub fn writePhys8(self: *Bus, a: u32, v: u8) void {
            self.ram[a] = v;
        }
        pub fn readPhys16(self: *Bus, a: u32) u16 {
            return @as(u16, self.ram[a]) | (@as(u16, self.ram[a + 1]) << 8);
        }
        pub fn writePhys16(self: *Bus, a: u32, v: u16) void {
            self.ram[a] = @truncate(v);
            self.ram[a + 1] = @truncate(v >> 8);
        }
    };
};

const TestChain = McbChain(TestCpu);

test "initPreFragmented lays the standard-PC 4-block low-DOS chain" {
    // Needs a full conventional-memory buffer (the big block ends at 0x9FFE).
    const ram = try std.testing.allocator.alloc(u8, 0xA0000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x16F); // DOS_MEM_START
    ch.initPreFragmented();
    // device dummy: 'M', DOS-owned, 1 para.
    try std.testing.expectEqual(SIG_LINK, ch.sig(0x16F));
    try std.testing.expectEqual(OWNER_DOS, ch.owner(0x16F));
    try std.testing.expectEqual(@as(u16, 1), ch.size(0x16F));
    // small free: 'M', free, 4 paras.
    try std.testing.expectEqual(SIG_LINK, ch.sig(0x171));
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x171));
    try std.testing.expectEqual(@as(u16, 4), ch.size(0x171));
    // loadfix lock: 'M', owner 0x40, 16 paras.
    try std.testing.expectEqual(SIG_LINK, ch.sig(0x176));
    try std.testing.expectEqual(@as(u16, 0x0040), ch.owner(0x176));
    try std.testing.expectEqual(@as(u16, 16), ch.size(0x176));
    // big free: 'Z' (last), free, 0x9E77 paras; its data ends at 0x9FFF.
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x187));
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x187));
    try std.testing.expectEqual(@as(u16, 0x9E77), ch.size(0x187));
    try std.testing.expectEqual(@as(u32, 0x9FFF), @as(u32, 0x188) + 0x9E77);
    // largest free block == the big block.
    try std.testing.expectEqual(@as(u16, 0x9E77), ch.largestFree());
    // owner-name fields zeroed on every header.
    for ([_]u16{ 0x16F, 0x171, 0x176, 0x187 }) |h| {
        var i: u16 = 8;
        while (i < 16) : (i += 1) try std.testing.expectEqual(@as(u8, 0), ch.rd8(h, i));
    }
}

test "alloc first-fit claims the low end, remainder above" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40); // one free block, 0x40 paras, at seg 0x10
    ch.strategy = 0; // first-fit
    const seg = ch.alloc(0x10, 0x1234).?;
    try std.testing.expectEqual(@as(u16, 0x11), seg); // data seg = first+1
    try std.testing.expectEqual(SIG_LINK, ch.sig(0x10));
    try std.testing.expectEqual(@as(u16, 0x1234), ch.owner(0x10));
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x10));
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x21)); // free remainder above, inherits LAST
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x21));
    try std.testing.expectEqual(@as(u16, 0x2f), ch.size(0x21));
}

test "alloc last-fit claims the high end, remainder below" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 2; // last-fit
    const seg = ch.alloc(0x10, 0x1234).?;
    // claimed at the TOP: data seg = first + total - paras + 1 = 0x41
    try std.testing.expectEqual(@as(u16, 0x41), seg);
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x40)); // claimed block inherits LAST
    try std.testing.expectEqual(@as(u16, 0x1234), ch.owner(0x40));
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x40));
    try std.testing.expectEqual(SIG_LINK, ch.sig(0x10)); // free remainder below, LINK
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x10));
    try std.testing.expectEqual(@as(u16, 0x2f), ch.size(0x10));
}

test "alloc best-fit picks the smallest fitting hole" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    // big free (0x20) | DOS-owned (0x05, blocks coalescing) | small free (0x10, LAST)
    ch.setHeader(0x10, SIG_LINK, OWNER_FREE, 0x20);
    ch.setHeader(0x31, SIG_LINK, OWNER_DOS, 0x05);
    ch.setHeader(0x37, SIG_LAST, OWNER_FREE, 0x10);
    ch.strategy = 1; // best-fit
    const seg = ch.alloc(0x08, 0x1234).?;
    try std.testing.expectEqual(@as(u16, 0x38), seg); // claimed from the SMALL hole, low end
    try std.testing.expectEqual(@as(u16, 0x1234), ch.owner(0x37));
    try std.testing.expectEqual(@as(u16, 0x08), ch.size(0x37));
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x10)); // big hole untouched
    try std.testing.expectEqual(@as(u16, 0x20), ch.size(0x10));
}

test "split leaves a 0-paragraph remainder header (off-by-one)" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x11); // a free block of exactly paras+1 for a 0x10 request
    ch.strategy = 0;
    const seg = ch.alloc(0x10, 0x1234).?;
    try std.testing.expectEqual(@as(u16, 0x11), seg);
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x10)); // claimed exactly paras, not paras+1
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x21)); // a 0-para FREE remainder header survives
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x21));
    try std.testing.expectEqual(@as(u16, 0x00), ch.size(0x21));
}

test "free defers coalescing; largestFree compacts" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 0;
    const a = ch.alloc(0x08, 0x1111).?; // block at 0x10
    const b = ch.alloc(0x08, 0x2222).?; // block at 0x19, adjacent above a
    try std.testing.expect(ch.free(b));
    try std.testing.expect(ch.free(a));
    // free() did NOT merge: both still distinct free blocks
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x10));
    try std.testing.expectEqual(@as(u16, 0x08), ch.size(0x10));
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x19));
    try std.testing.expectEqual(@as(u16, 0x08), ch.size(0x19));
    // largestFree compacts the whole arena back to one block
    try std.testing.expectEqual(@as(u16, 0x40), ch.largestFree());
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x10));
    try std.testing.expectEqual(@as(u16, 0x40), ch.size(0x10));
}

test "alloc last-fit exact fit claims the whole block (no high split)" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x10); // a free block of EXACTLY the requested size
    ch.strategy = 2; // last-fit
    const seg = ch.alloc(0x10, 0x1234).?;
    // exact fit: whole block claimed at the low end regardless of strategy (no remainder)
    try std.testing.expectEqual(@as(u16, 0x11), seg);
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x10));
    try std.testing.expectEqual(@as(u16, 0x1234), ch.owner(0x10));
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x10));
}

test "resize shrink frees the tail and compacts" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 0;
    const a = ch.alloc(0x20, 0x1111).?; // block 0x10 size 0x20; free remainder 0x31 size 0x1f
    const r = ch.resize(a, 0x10);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x10)); // shrunk to 0x10
    // the freed 0xf-para remainder merged with the following 0x1f free block -> 0x2f, LAST
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x21));
    try std.testing.expectEqual(@as(u16, 0x2f), ch.size(0x21));
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x21));
}

test "free of an invalid data segment returns false without underflow" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 0;
    // data_seg == 0 must NOT underflow `data_seg - 1` (would u16-wrap to 0xFFFF
    // and PANIC a safe build) — faithful DOS returns the error instead.
    try std.testing.expect(!ch.free(0));
    // Any segment at/below the first MCB header is out of range -> false.
    try std.testing.expect(!ch.free(ch.first)); // == self.first, < first+1
    // A segment ABOVE the arena that isn't an actual MCB header -> false (sig check).
    try std.testing.expect(!ch.free(0x100));
    // The arena is still pristine (nothing was freed/corrupted).
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x10));
    try std.testing.expectEqual(OWNER_FREE, ch.owner(0x10));
    try std.testing.expectEqual(@as(u16, 0x40), ch.size(0x10));
}

test "resize of an invalid data segment returns ok=false without underflow" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 0;
    // resize(0, ..) must not underflow `data_seg - 1`; returns ok=false, max=req.
    const r0 = ch.resize(0, 0x10);
    try std.testing.expect(!r0.ok);
    try std.testing.expectEqual(@as(u16, 0x10), r0.max); // request left unchanged
    // Segment at/below the first MCB header is out of range.
    const rf = ch.resize(ch.first, 0x10);
    try std.testing.expect(!rf.ok);
    // A segment whose MCB signature isn't link/last is a destroyed-MCB error.
    const rb = ch.resize(0x100, 0x10);
    try std.testing.expect(!rb.ok);
    // Arena untouched.
    try std.testing.expectEqual(SIG_LAST, ch.sig(0x10));
    try std.testing.expectEqual(@as(u16, 0x40), ch.size(0x10));
}

test "resize grow absorbs a freed neighbour" {
    const ram = try std.testing.allocator.alloc(u8, 0x1000);
    defer std.testing.allocator.free(ram);
    @memset(ram, 0);
    var cpu = TestCpu{ .bus = .{ .ram = ram } };
    var ch = TestChain.init(&cpu, 0x10);
    ch.initArena(0x40);
    ch.strategy = 0;
    const a = ch.alloc(0x08, 0x1111).?; // 0x10 size 8
    const b = ch.alloc(0x08, 0x2222).?; // 0x19 size 8 (adjacent above a)
    try std.testing.expect(ch.free(b)); // free b; NOT coalesced yet
    const r = ch.resize(a, 0x10); // grow a over the freed b (+ part of the tail)
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u16, 0x10), ch.size(0x10));
    try std.testing.expectEqual(@as(u16, 0x1111), ch.owner(0x10));
}
