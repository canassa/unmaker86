//! EMS INT 67h service (D15) — the LIM EMS handler BaK needs, owning the EMS
//! manager that the bus's MMIO page-frame device remaps through (bus B8). The bus
//! side is an ordinary MMIO device registered via `mapMmio(0xE0000, 0x10000, ...)`;
//! the manager owns the backing store and "remaps" by changing which backing slice
//! its `getHostPtr` returns for a frame page. The `EMMXXXX0` character device
//! (devices.zig) is the documented presence probe.
//!
//! Determinism: synthetic D5 cost per call; deterministic backing zero-init; the
//! remap is a pure slice swap (no host state). Snapshot: the small EMS state
//! (handle table + frame map + bump cursor + page counts) round-trips by value
//! in `Ems.Snapshot`; the large ~15 MiB `backing` slab is captured OUT OF BAND
//! (`snapshotBacking`/`restoreBacking`), exactly like the bus RAM slab and VGA
//! VRAM — it is far too large to copy into a by-value `Snapshot` struct.

const std = @import("std");
const bus_mod = @import("bus");

pub const PAGE_SIZE: u32 = 16 * 1024; // 16 KiB EMS logical page
pub const FRAME_PAGES: u32 = 4; // 4 physical frame slots (64 KiB window)
pub const FRAME_SEG: u16 = 0xE000; // page-frame segment (0xE0000)
pub const FRAME_PHYS: u32 = 0xE0000;
pub const FRAME_LEN: u32 = FRAME_PAGES * PAGE_SIZE; // 64 KiB

pub const EMS_HANDLES: u8 = 64; // provisional / comptime-asserted cap

/// Reported total/free EMS pages — MATCHED to the dosbox-x oracle, pinned to
/// EMS *board mode* (the canonical reference config, see below).
///
/// EMS BOARD MODE — why 0x3BC and no system handle:
///   The canonical oracle (tools/oracle.sh) pins `xms=false` to match zdos's
///   deferred-XMS scope (band 8). dosbox-x, when XMS is disabled and ems=true,
///   DOWNGRADES the default EMS_MIXED mode to EMS_BOARD (ems.cpp:1845-1849:
///   "EMS changed to board mode ... because XMS is not enabled"). Board mode is
///   a pure hardware-EMS-board model: NO VCPI, NO EMM386/V86, and — critically —
///   it does NOT allocate the OS-dedicated system handle (the system-handle
///   alloc lives only in the non-board `else` branch, ems.cpp:1949-1950). This
///   is EXACTLY zdos's BaK-target model ("EMS via a host INT 67h handler, no
///   EMM386/V86" — CLAUDE.md), so board mode is the faithful match, not a
///   compromise.
///
///   Consequences vs the old xms=true (EMS_MIXED) goldens:
///     - No 24-page system handle (handle 0). Active handle count starts at 0
///       (EMSCOUNT base=0000), and the AH=4D array omits it (sumpages drops 24).
///     - Those 24 pages return to the pool: reported total/free rises
///       0x03A4 -> 0x03BC (EMSINFO free=total=03BC). 0x3BC - 0x3A4 = 24.
///   AH=42 free = REPORTED_PAGES - (user-allocated pages).
pub const REPORTED_PAGES: u16 = 0x03BC;

/// Physical backing store, in 16 KiB pages. THE INVARIANT: back every page we
/// advertise — `BACKING_PAGES == REPORTED_PAGES` — so zdos never reports more
/// EMS than it can actually hand out. Advertising more than is backed is a
/// FAKE: a program (e.g. Betrayal at Krondor's `ems_init`) that allocates ALL
/// reported pages at once (AH=43 BX=REPORTED_PAGES) would get NOT_ENOUGH_PAGES
/// and its memory-sufficiency gate aborts — the exact "looks supported but
/// isn't" hole CLAUDE.md forbids.
///
/// 0x3BC = 956 pages × 16 KiB ≈ 15 MiB. This is one fixed, up-front,
/// zero-initialized slab in the `Ems` struct (no per-op alloc; deterministic
/// init — CLAUDE constraint #5). It comfortably exceeds BaK's `minEMS = 1024`
/// KiB (64 pages). The slab is large, so it is captured OUT OF BAND on snapshot
/// (like the bus RAM slab / VGA VRAM), never inlined into the by-value
/// `Snapshot` struct — see `snapshotBacking`/`restoreBacking` below.
pub const BACKING_PAGES: u16 = REPORTED_PAGES;

pub const EMM_VERSION: u8 = 0x40; // LIM EMS 4.0 (dosbox-x AH=46 returns AL=0x40)

// ---------------------------------------------------------------------------
// Resident EMM device-driver header (the "EMMXXXX0" presence signature).
//
// A real EMS driver (EMM386/QEMM/a hardware EMS board's resident) installs a
// standard DOS character-device header whose 8-byte name field (offset 0x0A)
// is the magic "EMMXXXX0". The documented EMS-presence probe (Phar Lap / the
// EMS spec, and exactly what BaK's `ems_detect_driver` does) is:
//   1. INT 21h AH=35h to fetch the INT 67h vector -> its segment S.
//   2. compare the 8 bytes at S:0x0A to "EMMXXXX0".
// Only on a match does the program issue any INT 67h subfunction.
//
// zdos already exposes `EMMXXXX0` as a named DOS character device (devices.zig
// — the OTHER, open()-by-name probe), and its INT 67h handler set is complete;
// the only missing piece was this resident header at the vector's segment.
//
// PLACEMENT (option A, per plans/krondor-milestone.md "Hole #1"): the INT 67h
// vector lives in the BIOS-ROM callback segment 0xF000 (the trap stub at
// F000:1160), so the vector's segment IS 0xF000. The BIOS image's first
// paragraph (offset 0x0000..0x1000) is FREE — the callback slot table starts
// at offset 0x1000 (Bridge.CB_OFFSET), the INT 16h hybrid + fonts + VGA save-
// pointer tables all live higher. So a proper 18-byte char-device header is
// staged at image offset 0x0000, putting the "EMMXXXX0" name at F000:000A
// exactly where the probe reads it, while leaving the INT 67h vector + trap
// stub at F000:1160 untouched. This is faithful — it is the real resident
// header a DOS EMS driver installs, not a fake. Determinism: fixed comptime
// data staged at POST (no host clock / RNG / float).
//
// Standard DOS device-header layout (18 bytes):
//   +0x00 dword  next-device pointer (offset:segment) = FFFF:FFFF (last/only)
//   +0x04 word   attribute = 0x8000 (bit15 = character device)
//   +0x06 word   strategy-routine offset (within this segment)
//   +0x08 word   interrupt-routine offset (within this segment)
//   +0x0A 8      device name = "EMMXXXX0"

/// The 8-byte EMM driver-header name field the presence probe matches.
pub const DRIVER_SIGNATURE = [8]u8{ 'E', 'M', 'M', 'X', 'X', 'X', 'X', '0' };

/// Offset of the device-driver header within the BIOS image (= F000:0000), so
/// the name lands at image offset 0x0A == F000:000A (the probe's read site).
pub const DRIVER_HEADER_OFF: u16 = 0x0000;
/// Offset of the 8-byte name field within the header (DOS device-header spec).
pub const DRIVER_NAME_OFF: u16 = DRIVER_HEADER_OFF + 0x0A;
/// Total device-header length staged into the image.
pub const DRIVER_HEADER_LEN: u16 = 0x12; // 18 bytes

/// Stage the resident EMM device-driver header into the BIOS ROM `image`
/// (indexed from 0xF0000, matching `int10.stageFonts`). Called by the machine
/// BEFORE `loadRom` (the F000 window is ROM — guest writes are dropped, so the
/// bytes must be planted in the image). `entry_off` is the INT 67h trap-stub
/// offset within the F000 segment (the same offset the INT 67h vector points
/// at, i.e. F000:<entry_off>), so the header's interrupt-routine field is
/// self-consistent with the live vector — a faithful real header, not a squat.
pub fn stageDeviceHeader(image: []u8, entry_off: u16) void {
    const base = DRIVER_HEADER_OFF;
    // +0x00 next-device pointer = FFFF:FFFF (this is the last/only EMM header).
    std.mem.writeInt(u32, image[base..][0..4], 0xFFFFFFFF, .little);
    // +0x04 attribute word: bit15 set = character device.
    std.mem.writeInt(u16, image[base + 0x04 ..][0..2], 0x8000, .little);
    // +0x06 strategy offset, +0x08 interrupt offset: both reference the resident
    // entry (the existing INT 67h trap stub). A driver's strategy/interrupt
    // entry points are the real resident code; pointing them at the trap stub
    // keeps the header self-consistent without a second code path.
    std.mem.writeInt(u16, image[base + 0x06 ..][0..2], entry_off, .little);
    std.mem.writeInt(u16, image[base + 0x08 ..][0..2], entry_off, .little);
    // +0x0A the 8-byte name field — the "EMMXXXX0" presence signature.
    @memcpy(image[base + 0x0A ..][0..8], &DRIVER_SIGNATURE);
}

pub const EmsHandle = struct {
    active: bool = false,
    pages: u16 = 0,
    /// Index of this handle's first logical page in the backing store.
    base_page: u16 = 0,
    /// AH=47/48 save/restore-page-map state for THIS handle.
    saved_page_map: bool = false,
    saved_map: [FRAME_PAGES]?u16 = @splat(null),
    /// AH=53/54 handle name — 8 program-supplied bytes, zero-init (dosbox-x
    /// `EMM_Handle.name[8]`, ems.cpp:149). Blank by default; never NUL-terminated
    /// internally (compared/copied as a fixed 8-byte field, ems.cpp:776/785/810).
    name: [8]u8 = @splat(0),
};

pub fn Ems(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        cpu: *Cpu = undefined,
        /// The deterministic backing store: BACKING_PAGES * 16 KiB, zero-init.
        backing: [BACKING_PAGES * PAGE_SIZE]u8 = @splat(0),
        handles: [EMS_HANDLES]EmsHandle = @splat(.{}),
        /// Which (logical page in `backing`) each of the 4 frame slots maps to.
        frame_map: [FRAME_PAGES]?u16 = @splat(null),
        /// Next free logical page (simple bump allocator over the backing store).
        next_page: u16 = 0,
        /// Pages allocated to user handles, used for the AH=42 free-page report
        /// so it matches dosbox-x's accounting (board mode: all handles are user
        /// handles).
        user_pages: u16 = 0,
        installed: bool = false,

        /// A side-effect-free summary of EMS config/usage for the debugger device
        /// reader (plans/device-state-reader.md). Pure field reads + the module
        /// page constants — never mutates, charges no cycle.
        pub const Report = struct {
            installed: bool,
            reported_pages: u16,
            backing_pages: u16,
            user_pages: u16,
            free_pages: u16,
            active_handles: u16,
            frame_pages: u8,
        };
        pub fn report(self: *const Self) Report {
            var active: u16 = 0;
            for (self.handles) |h| {
                if (h.active) active += 1;
            }
            var mapped: u8 = 0;
            for (self.frame_map) |f| {
                if (f != null) mapped += 1;
            }
            return .{
                .installed = self.installed,
                .reported_pages = REPORTED_PAGES,
                .backing_pages = BACKING_PAGES,
                .user_pages = self.user_pages,
                .free_pages = REPORTED_PAGES -| self.user_pages,
                .active_handles = active,
                .frame_pages = mapped,
            };
        }

        pub fn init(self: *Self, cpu: *Cpu) void {
            self.cpu = cpu;
            @memset(&self.backing, 0);
            self.handles = @splat(.{});
            self.frame_map = @splat(null);
            self.next_page = 0;
            self.user_pages = 0;
            // EMS BOARD MODE (canonical oracle pins xms=false -> dosbox-x EMS
            // board mode, ems.cpp:1845): NO OS system handle is allocated. All
            // handles 0..N are user handles, the bump allocator starts at page 0,
            // and the active handle count starts at 0. See REPORTED_PAGES above.
        }

        /// The MMIO MemHandler the machine registers at the page-frame window.
        pub fn memHandler(self: *Self) bus_mod.MemHandler {
            return .{
                .ctx = self,
                .vtable = &vtable,
            };
        }

        const vtable = bus_mod.regions.MemHandler.VTable{
            .read8 = read8,
            .write8 = write8,
            .getHostPtr = getHostPtr,
            // EMS frame reads are pure (a backing-store index); the debugger peek
            // path matches read8 exactly. An unmapped frame slot reads 0 here too.
            .peek8 = peek8,
        };

        /// Return a host pointer into the backing store for a mapped frame page, so
        /// the bus can index it directly (RAM-like MMIO). `page` is the absolute
        /// bus page index; we map it to a frame slot + offset.
        fn getHostPtr(ctx: *anyopaque, page: u32) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const bus_page_size: u32 = 0x1000;
            const phys = page * bus_page_size;
            if (phys < FRAME_PHYS or phys >= FRAME_PHYS + FRAME_LEN) return null;
            const window_off = phys - FRAME_PHYS;
            const slot = window_off / PAGE_SIZE;
            const within = window_off % PAGE_SIZE;
            const logical = self.frame_map[slot] orelse return null;
            const back_off = @as(u32, logical) * PAGE_SIZE + within;
            return self.backing[back_off..].ptr;
        }

        fn read8(ctx: *anyopaque, phys: u32) u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const window_off = phys - FRAME_PHYS;
            const slot = window_off / PAGE_SIZE;
            const within = window_off % PAGE_SIZE;
            const logical = self.frame_map[slot] orelse return 0;
            return self.backing[@as(u32, logical) * PAGE_SIZE + within];
        }
        fn write8(ctx: *anyopaque, phys: u32, v: u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const window_off = phys - FRAME_PHYS;
            const slot = window_off / PAGE_SIZE;
            const within = window_off % PAGE_SIZE;
            const logical = self.frame_map[slot] orelse return;
            self.backing[@as(u32, logical) * PAGE_SIZE + within] = v;
        }
        /// Side-effect-free inspection read (debugger peek path). A pure backing-
        /// store index; an unmapped frame slot reads 0 (same as read8), mutating
        /// nothing.
        fn peek8(ctx: *anyopaque, phys: u32) ?u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const window_off = phys - FRAME_PHYS;
            const slot = window_off / PAGE_SIZE;
            const within = window_off % PAGE_SIZE;
            const logical = self.frame_map[slot] orelse return 0;
            return self.backing[@as(u32, logical) * PAGE_SIZE + within];
        }

        // -------------------------------------------------------------------
        // INT 67h dispatch (the LIM EMS subfunction set, AH switch).
        // -------------------------------------------------------------------
        pub fn service(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const ah = cpu.st.getReg8(4);
            switch (ah) {
                0x40 => { // get status -> AH=0 (ok)
                    cpu.st.setReg8(4, 0);
                },
                0x41 => { // get page-frame segment -> BX, AH=0
                    cpu.st.setReg16(@intFromEnum(@import("cpu").state.Reg32.ebx), FRAME_SEG);
                    cpu.st.setReg8(4, 0);
                },
                0x42 => { // get page count -> BX=free, DX=total, AH=0
                    const Reg32 = @import("cpu").state.Reg32;
                    cpu.st.setReg16(@intFromEnum(Reg32.ebx), REPORTED_PAGES - self.user_pages);
                    cpu.st.setReg16(@intFromEnum(Reg32.edx), REPORTED_PAGES);
                    cpu.st.setReg8(4, 0);
                },
                0x43 => allocHandle(self, cpu),
                0x44 => mapPage(self, cpu),
                0x45 => freeHandle(self, cpu),
                0x46 => { // get EMS version -> AL=EMM_VERSION (4.0), AH=0
                    cpu.st.setReg8(0, EMM_VERSION);
                    cpu.st.setReg8(4, 0);
                },
                0x47 => savePageMap(self, cpu),
                0x48 => restorePageMap(self, cpu),
                0x4B => getHandleCount(self, cpu),
                0x4C => getPagesForHandle(self, cpu),
                0x4D => getPagesAllHandles(self, dos, cpu, br),
                0x4E => savRestPageMap(self, dos, cpu, br),
                0x50 => mapMultiple(self, dos, cpu, br), // LIM 4.0 bulk map/unmap
                0x51 => reallocatePages(self, cpu), // LIM 4.0 reallocate
                0x53 => getSetHandleName(self, dos, cpu, br), // LIM 4.0 handle name
                0x54 => handleNameSearch(self, dos, cpu, br), // LIM 4.0 names dir
                else => {
                    // Unsupported EMS subfunction: AH = 0x84 (function not
                    // supported) — the faithful EMS error, AND the structural flag.
                    dos.unsupported(cpu, br, 0x67);
                    cpu.st.setReg8(4, 0x84);
                },
            }
        }

        fn allocHandle(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const want = cpu.st.getReg16(@intFromEnum(Reg32.ebx)); // BX = pages
            // dosbox-x rejects a zero-page allocation (EMM_AllocateMemory,
            // ems.cpp:266: EMM_ZERO_PAGES=0x89) and checks the REPORTED free
            // count, not the backing store (ems.cpp:270).
            if (want == 0) {
                cpu.st.setReg8(4, 0x89); // attempted to allocate zero pages
                return;
            }
            if (want > REPORTED_PAGES - self.user_pages) {
                cpu.st.setReg8(4, 0x88); // not enough pages
                return;
            }
            if (self.next_page + want > BACKING_PAGES) {
                cpu.st.setReg8(4, 0x88); // backing exhausted
                return;
            }
            // Handle 0 is RESERVED, even in board mode: dosbox-x's
            // EMM_AllocateMemory starts its free-handle scan at `handle = 1`
            // (ems.cpp:425), so the first user handle is always 1 (handle 0 is
            // the system/VCPI slot, simply never handed out in board mode). Match
            // that — a program that reads back its handle number (AH=54 search,
            // AH=4D array) must see 1, not 0.
            var h: u8 = 1;
            while (h < EMS_HANDLES) : (h += 1) {
                if (!self.handles[h].active) {
                    self.handles[h] = .{ .active = true, .pages = want, .base_page = self.next_page };
                    self.next_page += want;
                    self.user_pages += want;
                    cpu.st.setReg16(@intFromEnum(Reg32.edx), h); // DX = handle
                    cpu.st.setReg8(4, 0);
                    return;
                }
            }
            cpu.st.setReg8(4, 0x85); // no more handles
        }

        fn mapPage(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const logical_in_handle = cpu.st.getReg16(@intFromEnum(Reg32.ebx)); // BX
            const slot = cpu.st.getReg8(0); // AL = physical frame slot
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx)); // DX = handle
            cpu.st.setReg8(4, self.mapOneByPhys(slot, handle, logical_in_handle));
        }

        /// Core single-page (un)map by PHYSICAL frame slot — shared by AH=44 and
        /// AH=50 AL=00 (dosbox-x `EMM_MapPage`, ems.cpp:505). Returns the EMS
        /// error code (0 = success). A `logical` of 0xFFFF (NULL_PAGE) unmaps the
        /// slot and — like dosbox — does NOT require a valid handle.
        fn mapOneByPhys(self: *Self, slot: u8, handle: u16, logical: u16) u8 {
            if (slot >= FRAME_PAGES) return 0x8B; // invalid physical page
            if (logical == 0xFFFF) { // unmap (no handle validation)
                self.frame_map[slot] = null;
                return 0;
            }
            if (handle >= EMS_HANDLES or !self.handles[handle].active) return 0x83; // invalid handle
            if (logical >= self.handles[handle].pages) return 0x8A; // invalid logical page
            self.frame_map[slot] = self.handles[handle].base_page + logical;
            return 0;
        }

        /// Core single-page (un)map by SEGMENT — AH=50 AL=01 (dosbox-x
        /// `EMM_MapSegment`, ems.cpp:551). Board mode only accepts a segment that
        /// lands inside the page frame [FRAME_SEG, FRAME_SEG+0x1000); the segment
        /// → slot conversion mirrors dosbox: slot = (seg-FRAME_SEG)/(0x1000/4).
        /// Mapping graphics memory (0xA000) is a documented dosbox board-mode
        /// option but is not backed by zdos's page-frame MMIO device, so it is
        /// faithfully rejected as ILL_PHYS rather than silently no-op'd.
        fn mapOneBySegment(self: *Self, segment: u16, handle: u16, logical: u16) u8 {
            if (segment < FRAME_SEG or segment >= FRAME_SEG + 0x1000) return 0x8B; // ILL_PHYS
            const slot: u8 = @intCast((segment - FRAME_SEG) / (0x1000 / FRAME_PAGES));
            return self.mapOneByPhys(slot, handle, logical);
        }

        fn freeHandle(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                // Board mode: no reserved system handle — handle 0 is a normal
                // user handle and may be freed like any other.
                cpu.st.setReg8(4, 0x83);
                return;
            }
            // Unmap any frame slots pointing into this handle.
            for (&self.frame_map) |*fm| {
                if (fm.*) |lp| {
                    if (lp >= self.handles[handle].base_page and
                        lp < self.handles[handle].base_page + self.handles[handle].pages)
                    {
                        fm.* = null;
                    }
                }
            }
            self.user_pages -= self.handles[handle].pages;
            self.handles[handle].active = false;
            self.handles[handle].pages = 0;
            self.handles[handle].saved_page_map = false;
            cpu.st.setReg8(4, 0);
        }

        // -------------------------------------------------------------------
        // AH=50 — Map/Unmap Multiple Handle Pages (LIM 4.0, ems.cpp:1049). One
        // call (un)maps CX pages from a DS:SI array. AL=00: each entry is
        // {logical_page:u16, physical_page:u16}; AL=01: {logical_page:u16,
        // segment:u16}. A logical_page of 0xFFFF (NULL_PAGE) unmaps. dosbox
        // applies each entry in order via EMM_MapPage/EMM_MapSegment and STOPS at
        // the first error, leaving the partial map in place (ems.cpp:1058/1066).
        // -------------------------------------------------------------------
        fn mapMultiple(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;
            const al = cpu.st.getReg8(0);
            const count = cpu.st.getReg16(@intFromEnum(Reg32.ecx)); // CX = entries
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx)); // DX = handle
            const ds = cpu.st.selector[@intFromEnum(Seg.ds)];
            const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
            var data: u32 = (@as(u32, ds) << 4) + si;
            if (al != 0x00 and al != 0x01) {
                dos.unsupported(cpu, br, 0x67);
                cpu.st.setReg8(4, 0x8F); // invalid subfunction
                return;
            }
            var err: u8 = 0;
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                const logical = cpu.bus.readPhys16(data);
                const target = cpu.bus.readPhys16(data + 2);
                data += 4;
                err = if (al == 0x00)
                    self.mapOneByPhys(@truncate(target), handle, logical)
                else
                    self.mapOneBySegment(target, handle, logical);
                if (err != 0) break;
            }
            cpu.st.setReg8(4, err);
        }

        // -------------------------------------------------------------------
        // AH=51 — Reallocate Pages (LIM 4.0, ems.cpp:1076). BX = new page count
        // for handle DX; grows or shrinks the handle, returning the freed/consumed
        // pages to/from the pool (the AH=42 free count moves by the delta, exactly
        // as dosbox-x's MEM_ReAllocatePages changes MEM_FreeTotal).
        //
        // zdos backs handles with a bump allocator over one contiguous store, so:
        //   * SHRINK: keep base_page, drop the page count; the tail pages return
        //     to the pool (user_pages -= delta). Any frame slot now pointing past
        //     the shrunk range is unmapped (its logical page no longer exists).
        //   * GROW: if the handle is the last allocation (base_page+pages ==
        //     next_page) we extend in place; otherwise we RELOCATE it to a fresh
        //     region at the bump pointer, copying the live page bytes and
        //     rewriting any frame slots that pointed into the old range. Content is
        //     preserved (a real reallocate keeps the handle's data), which the
        //     oracle program verifies by reading kept pages back after a grow.
        // -------------------------------------------------------------------
        fn reallocatePages(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            const new_pages = cpu.st.getReg16(@intFromEnum(Reg32.ebx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83); // invalid handle
                return;
            }
            const old_pages = self.handles[handle].pages;
            if (new_pages == old_pages) {
                cpu.st.setReg8(4, 0);
                return;
            }
            if (new_pages < old_pages) {
                // Shrink: free the tail pages back to the pool.
                const new_top = self.handles[handle].base_page + new_pages;
                for (&self.frame_map) |*fm| {
                    if (fm.*) |lp| {
                        if (lp >= new_top and lp < self.handles[handle].base_page + old_pages)
                            fm.* = null;
                    }
                }
                self.user_pages -= (old_pages - new_pages);
                self.handles[handle].pages = new_pages;
                cpu.st.setReg8(4, 0);
                return;
            }
            // Grow: need (new_pages - old_pages) more pages from the pool.
            const delta = new_pages - old_pages;
            if (delta > REPORTED_PAGES - self.user_pages) {
                cpu.st.setReg8(4, 0x88); // not enough pages
                return;
            }
            const h = &self.handles[handle];
            if (h.base_page + old_pages == self.next_page) {
                // Last allocation: extend in place.
                if (self.next_page + delta > BACKING_PAGES) {
                    cpu.st.setReg8(4, 0x88); // backing exhausted
                    return;
                }
                self.next_page += delta;
                h.pages = new_pages;
                self.user_pages += delta;
                cpu.st.setReg8(4, 0);
                return;
            }
            // Interior handle: relocate to a fresh contiguous region, preserving
            // the existing page contents and any active frame mappings.
            if (self.next_page + new_pages > BACKING_PAGES) {
                cpu.st.setReg8(4, 0x88); // backing exhausted
                return;
            }
            const old_base = h.base_page;
            const new_base = self.next_page;
            const copy_bytes = @as(u32, old_pages) * PAGE_SIZE;
            const src = @as(u32, old_base) * PAGE_SIZE;
            const dst = @as(u32, new_base) * PAGE_SIZE;
            std.mem.copyForwards(u8, self.backing[dst .. dst + copy_bytes], self.backing[src .. src + copy_bytes]);
            // Rewrite frame slots that pointed into the old range.
            for (&self.frame_map) |*fm| {
                if (fm.*) |lp| {
                    if (lp >= old_base and lp < old_base + old_pages)
                        fm.* = new_base + (lp - old_base);
                }
            }
            h.base_page = new_base;
            h.pages = new_pages;
            self.next_page += new_pages; // old region is left fallow (bump store)
            self.user_pages += delta;
            cpu.st.setReg8(4, 0);
        }

        // -------------------------------------------------------------------
        // AH=53 — Get/Set Handle Name (LIM 4.0, ems.cpp:805). AL=00 writes the
        // handle's 8-byte name to ES:DI; AL=01 reads 8 bytes from DS:SI into it.
        // Names are program-supplied strings → fully deterministic.
        // -------------------------------------------------------------------
        fn getSetHandleName(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;
            const al = cpu.st.getReg8(0);
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (al != 0x00 and al != 0x01) {
                dos.unsupported(cpu, br, 0x67);
                cpu.st.setReg8(4, 0x8F); // invalid subfunction
                return;
            }
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83); // invalid handle
                return;
            }
            if (al == 0x00) { // get -> ES:DI
                const es = cpu.st.selector[@intFromEnum(Seg.es)];
                const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
                var off: u32 = (@as(u32, es) << 4) + di;
                for (self.handles[handle].name) |b| {
                    cpu.bus.writePhys8(off, b);
                    off += 1;
                }
            } else { // set <- DS:SI
                const ds = cpu.st.selector[@intFromEnum(Seg.ds)];
                const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
                var off: u32 = (@as(u32, ds) << 4) + si;
                for (&self.handles[handle].name) |*b| {
                    b.* = cpu.bus.readPhys8(off);
                    off += 1;
                }
            }
            cpu.st.setReg8(4, 0);
        }

        // -------------------------------------------------------------------
        // AH=54 — Handle name directory (LIM 4.0, ems.cpp:766). AL=00 writes the
        // {handle:u16, name:8} array of all active handles to ES:DI and returns
        // AL = active count; AL=01 searches DS:SI's 8-byte name and returns the
        // matching handle in DX (or AH=0xA0 not-found); AL=02 returns BX = total
        // handle slots.
        // -------------------------------------------------------------------
        fn handleNameSearch(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x00 => { // get all handle names -> ES:DI
                    const es = cpu.st.selector[@intFromEnum(Seg.es)];
                    const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
                    var off: u32 = (@as(u32, es) << 4) + di;
                    var n: u8 = 0;
                    for (self.handles, 0..) |hd, i| {
                        if (!hd.active) continue;
                        n += 1;
                        cpu.bus.writePhys16(off, @intCast(i));
                        off += 2;
                        for (hd.name) |b| {
                            cpu.bus.writePhys8(off, b);
                            off += 1;
                        }
                    }
                    cpu.st.setReg8(0, n); // AL = count
                    cpu.st.setReg8(4, 0);
                },
                0x01 => { // search for a handle by name <- DS:SI
                    const ds = cpu.st.selector[@intFromEnum(Seg.ds)];
                    const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
                    const base: u32 = (@as(u32, ds) << 4) + si;
                    var want: [8]u8 = undefined;
                    for (&want, 0..) |*b, k| b.* = cpu.bus.readPhys8(base + @as(u32, @intCast(k)));
                    for (self.handles, 0..) |hd, i| {
                        if (hd.active and std.mem.eql(u8, &hd.name, &want)) {
                            cpu.st.setReg16(@intFromEnum(Reg32.edx), @intCast(i));
                            cpu.st.setReg8(4, 0);
                            return;
                        }
                    }
                    cpu.st.setReg8(4, 0xA0); // handle name not found
                },
                0x02 => { // total number of handle slots -> BX
                    cpu.st.setReg16(@intFromEnum(Reg32.ebx), EMS_HANDLES);
                    cpu.st.setReg8(4, 0);
                },
                else => {
                    dos.unsupported(cpu, br, 0x67);
                    cpu.st.setReg8(4, 0x8F); // invalid subfunction
                },
            }
        }

        // -------------------------------------------------------------------
        // AH=47/48 — per-handle save/restore page map (ems.cpp:448/477).
        // -------------------------------------------------------------------
        fn savePageMap(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83); // invalid handle
                return;
            }
            if (self.handles[handle].saved_page_map) {
                cpu.st.setReg8(4, 0x8D); // page map already saved
                return;
            }
            self.handles[handle].saved_map = self.frame_map;
            self.handles[handle].saved_page_map = true;
            cpu.st.setReg8(4, 0);
        }

        fn restorePageMap(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83); // invalid handle
                return;
            }
            if (!self.handles[handle].saved_page_map) {
                cpu.st.setReg8(4, 0x8E); // no saved page map
                return;
            }
            self.frame_map = self.handles[handle].saved_map;
            self.handles[handle].saved_page_map = false;
            cpu.st.setReg8(4, 0);
        }

        // -------------------------------------------------------------------
        // AH=4B — get active handle count (ems.cpp:813). Board mode: counts the
        // active user handles only (no OS system handle exists).
        // -------------------------------------------------------------------
        fn getHandleCount(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            var count: u16 = 0;
            for (self.handles) |h| {
                if (h.active) count += 1;
            }
            cpu.st.setReg16(@intFromEnum(Reg32.ebx), count);
            cpu.st.setReg8(4, 0);
        }

        // AH=4C — pages owned by one handle -> BX (ems.cpp:818).
        fn getPagesForHandle(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83);
                return;
            }
            cpu.st.setReg16(@intFromEnum(Reg32.ebx), self.handles[handle].pages);
            cpu.st.setReg8(4, 0);
        }

        // AH=4D — pages for all handles -> ES:DI array of {handle:u16, pages:u16},
        // BX = entry count (ems.cpp:823/493). Board mode: walks the active user
        // handles only (no system handle exists).
        fn getPagesAllHandles(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = dos;
            _ = br;
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;
            const es = cpu.st.selector[@intFromEnum(Seg.es)];
            const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
            var table: u32 = (@as(u32, es) << 4) + di;
            var count: u16 = 0;
            for (self.handles, 0..) |h, i| {
                if (!h.active) continue;
                cpu.bus.writePhys16(table, @intCast(i));
                cpu.bus.writePhys16(table + 2, h.pages);
                table += 4;
                count += 1;
            }
            cpu.st.setReg16(@intFromEnum(Reg32.ebx), count);
            cpu.st.setReg8(4, 0);
        }

        // -------------------------------------------------------------------
        // AH=4E — save/restore page map across calls (ems.cpp:826). The mapping
        // array is 4 physical pages * {handle:u16, page:u16} = 16 bytes. We
        // serialize the live frame_map into that 16-byte guest buffer so AL=00
        // (save) and AL=01 (restore) round-trip exactly, and AL=03 reports the
        // size. The serialized form mirrors dosbox-x's emm_mappings dump.
        // -------------------------------------------------------------------
        const MAP_ARRAY_BYTES: u8 = FRAME_PAGES * 4; // 16

        fn savRestPageMap(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const Reg32 = @import("cpu").state.Reg32;
            const Seg = @import("cpu").state.Seg;
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x00 => { // save -> ES:DI
                    const es = cpu.st.selector[@intFromEnum(Seg.es)];
                    const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
                    self.serializeMap(cpu, (@as(u32, es) << 4) + di);
                    cpu.st.setReg8(4, 0);
                },
                0x01 => { // restore <- DS:SI
                    const ds = cpu.st.selector[@intFromEnum(Seg.ds)];
                    const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
                    self.deserializeMap(cpu, (@as(u32, ds) << 4) + si);
                    cpu.st.setReg8(4, 0);
                },
                0x02 => { // save (ES:DI) AND restore (DS:SI)
                    const es = cpu.st.selector[@intFromEnum(Seg.es)];
                    const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
                    self.serializeMap(cpu, (@as(u32, es) << 4) + di);
                    const ds = cpu.st.selector[@intFromEnum(Seg.ds)];
                    const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
                    self.deserializeMap(cpu, (@as(u32, ds) << 4) + si);
                    cpu.st.setReg8(4, 0);
                },
                0x03 => { // get array size -> AL
                    cpu.st.setReg8(0, MAP_ARRAY_BYTES);
                    cpu.st.setReg8(4, 0);
                },
                else => {
                    dos.unsupported(cpu, br, 0x67);
                    cpu.st.setReg8(4, 0x8F); // invalid subfunction
                },
            }
        }

        /// Write the live frame_map to a 16-byte guest buffer: per phys slot a
        /// {handle:u16, page:u16} pair. An unmapped slot is encoded as
        /// {0xFFFF, 0xFFFF} (NULL_HANDLE/NULL_PAGE, ems.cpp:38).
        fn serializeMap(self: *Self, cpu: *Cpu, base: u32) void {
            for (self.frame_map, 0..) |fm, slot| {
                const off = base + @as(u32, @intCast(slot)) * 4;
                if (fm) |lp| {
                    cpu.bus.writePhys16(off, self.handleOfPage(lp));
                    cpu.bus.writePhys16(off + 2, self.pageInHandle(lp));
                } else {
                    cpu.bus.writePhys16(off, 0xFFFF);
                    cpu.bus.writePhys16(off + 2, 0xFFFF);
                }
            }
        }

        fn deserializeMap(self: *Self, cpu: *Cpu, base: u32) void {
            for (&self.frame_map, 0..) |*fm, slot| {
                const off = base + @as(u32, @intCast(slot)) * 4;
                const handle = cpu.bus.readPhys16(off);
                const page = cpu.bus.readPhys16(off + 2);
                if (handle == 0xFFFF or handle >= EMS_HANDLES or !self.handles[handle].active or page >= self.handles[handle].pages) {
                    fm.* = null;
                } else {
                    fm.* = self.handles[handle].base_page + page;
                }
            }
        }

        /// Reverse-lookup: which handle owns absolute backing page `lp`.
        fn handleOfPage(self: *Self, lp: u16) u16 {
            for (self.handles, 0..) |h, i| {
                if (h.active and lp >= h.base_page and lp < h.base_page + h.pages)
                    return @intCast(i);
            }
            return 0xFFFF;
        }

        /// Reverse-lookup: the logical page-within-handle for absolute page `lp`.
        fn pageInHandle(self: *Self, lp: u16) u16 {
            for (self.handles) |h| {
                if (h.active and lp >= h.base_page and lp < h.base_page + h.pages)
                    return lp - h.base_page;
            }
            return 0xFFFF;
        }

        // -------------------------------------------------------------------
        // Snapshot / restore (CLAUDE #6). The EMS state splits the same way the
        // bus does: the SMALL bookkeeping (handle table, frame map, bump cursor,
        // page counts) round-trips by value in `Snapshot`; the LARGE ~15 MiB
        // `backing` slab is captured OUT OF BAND by the caller via `backingBytes`
        // (read) + `restoreBacking` (write), exactly like `bus.ram`/`vga.vram`.
        // Putting `backing` in `Snapshot` would make the by-value struct ~15 MiB
        // (it is returned on the stack) — and would copy the whole slab on every
        // snapshot, which is the quadratic trap the task warns against.
        // -------------------------------------------------------------------
        pub const Snapshot = struct {
            handles: [EMS_HANDLES]EmsHandle,
            frame_map: [FRAME_PAGES]?u16,
            next_page: u16,
            user_pages: u16,
            installed: bool,
        };

        pub fn snapshot(self: *const Self) Snapshot {
            return .{
                .handles = self.handles,
                .frame_map = self.frame_map,
                .next_page = self.next_page,
                .user_pages = self.user_pages,
                .installed = self.installed,
            };
        }

        pub fn restore(self: *Self, snap: Snapshot) void {
            self.handles = snap.handles;
            self.frame_map = snap.frame_map;
            self.next_page = snap.next_page;
            self.user_pages = snap.user_pages;
            self.installed = snap.installed;
        }

        /// The large backing slab, for the caller's out-of-band snapshot copy
        /// (mirrors `bus.ram` / `vga.vram`). Read for capture; pair with
        /// `restoreBacking` to write it back onto a freshly-init'd machine.
        pub fn backingBytes(self: *Self) []u8 {
            return &self.backing;
        }

        /// Overwrite the backing slab from a previously-captured copy (same
        /// fixed length). The caller copies bytes in after `restore`.
        pub fn restoreBacking(self: *Self, bytes: []const u8) void {
            std.debug.assert(bytes.len == self.backing.len);
            @memcpy(&self.backing, bytes);
        }
    };
}

comptime {
    std.debug.assert(FRAME_LEN % 0x1000 == 0);
}
