//! EMS INT 67h service (D15) — the LIM EMS handler BaK needs, owning the EMS
//! manager that the bus's MMIO page-frame device remaps through (bus B8). The bus
//! side is an ordinary MMIO device registered via `mapMmio(0xE0000, 0x10000, ...)`;
//! the manager owns the backing store and "remaps" by changing which backing slice
//! its `getHostPtr` returns for a frame page. The `EMMXXXX0` character device
//! (devices.zig) is the documented presence probe.
//!
//! Determinism: synthetic D5 cost per call; deterministic backing zero-init; the
//! remap is a pure slice swap (no host state). Snapshot: handle table + frame map
//! + backing store (D14).

const std = @import("std");
const bus_mod = @import("bus");

pub const PAGE_SIZE: u32 = 16 * 1024; // 16 KiB EMS logical page
pub const FRAME_PAGES: u32 = 4; // 4 physical frame slots (64 KiB window)
pub const FRAME_SEG: u16 = 0xE000; // page-frame segment (0xE0000)
pub const FRAME_PHYS: u32 = 0xE0000;
pub const FRAME_LEN: u32 = FRAME_PAGES * PAGE_SIZE; // 64 KiB

pub const EMS_HANDLES: u8 = 64; // provisional / comptime-asserted cap
pub const TOTAL_PAGES: u16 = 64; // 1 MiB of EMS (64 * 16 KiB) — BaK's ~1 MiB

pub const EmsHandle = struct {
    active: bool = false,
    pages: u16 = 0,
    /// Index of this handle's first logical page in the backing store.
    base_page: u16 = 0,
};

pub fn Ems(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        cpu: *Cpu = undefined,
        /// The deterministic backing store: TOTAL_PAGES * 16 KiB, zero-init.
        backing: [TOTAL_PAGES * PAGE_SIZE]u8 = @splat(0),
        handles: [EMS_HANDLES]EmsHandle = @splat(.{}),
        /// Which (logical page in `backing`) each of the 4 frame slots maps to.
        frame_map: [FRAME_PAGES]?u16 = @splat(null),
        /// Next free logical page (simple bump allocator over the backing store).
        next_page: u16 = 0,
        installed: bool = false,

        pub fn init(self: *Self, cpu: *Cpu) void {
            self.cpu = cpu;
            @memset(&self.backing, 0);
            self.handles = @splat(.{});
            self.frame_map = @splat(null);
            self.next_page = 0;
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
                    const used = self.next_page;
                    cpu.st.setReg16(@intFromEnum(@import("cpu").state.Reg32.ebx), TOTAL_PAGES - used);
                    cpu.st.setReg16(@intFromEnum(@import("cpu").state.Reg32.edx), TOTAL_PAGES);
                    cpu.st.setReg8(4, 0);
                },
                0x43 => allocHandle(self, cpu),
                0x44 => mapPage(self, cpu),
                0x45 => freeHandle(self, cpu),
                0x46 => { // get EMS version -> AL=0x32 (4.0), AH=0
                    cpu.st.setReg8(0, 0x32);
                    cpu.st.setReg8(4, 0);
                },
                0x47, 0x48 => { // save/restore page map -> AH=0 (accepted)
                    cpu.st.setReg8(4, 0);
                },
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
            if (self.next_page + want > TOTAL_PAGES) {
                cpu.st.setReg8(4, 0x88); // not enough pages
                return;
            }
            var h: u8 = 0;
            while (h < EMS_HANDLES) : (h += 1) {
                if (!self.handles[h].active) {
                    self.handles[h] = .{ .active = true, .pages = want, .base_page = self.next_page };
                    self.next_page += want;
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
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83); // invalid handle
                return;
            }
            if (slot >= FRAME_PAGES) {
                cpu.st.setReg8(4, 0x8B); // invalid physical page
                return;
            }
            if (logical_in_handle == 0xFFFF) {
                // unmap this frame slot
                self.frame_map[slot] = null;
                cpu.st.setReg8(4, 0);
                return;
            }
            if (logical_in_handle >= self.handles[handle].pages) {
                cpu.st.setReg8(4, 0x8A); // invalid logical page
                return;
            }
            self.frame_map[slot] = self.handles[handle].base_page + logical_in_handle;
            cpu.st.setReg8(4, 0);
        }

        fn freeHandle(self: *Self, cpu: *Cpu) void {
            const Reg32 = @import("cpu").state.Reg32;
            const handle = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            if (handle >= EMS_HANDLES or !self.handles[handle].active) {
                cpu.st.setReg8(4, 0x83);
                return;
            }
            self.handles[handle].active = false;
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
            cpu.st.setReg8(4, 0);
        }
    };
}

comptime {
    std.debug.assert(FRAME_LEN % 0x1000 == 0);
}
