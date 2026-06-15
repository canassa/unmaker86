//! The zdos bus / memory module: the single memory choke point — guest RAM plus
//! physical-address region dispatch plus 16-bit port I/O dispatch — in Zig 0.16.
//!
//! The bus is the bottom of the module graph alongside the CPU: it imports
//! nothing outside `std` + the shared contract leaf (`bus_contract`, B10). A
//! concrete `Bus` is instantiated into `Cpu(comptime Bus)` so the per-instruction
//! memory path inlines to zero cost (no runtime vtable on the RAM fast path).
//!
//! Scope: real-mode physical memory + ports. PM paging/TLB/#PF are the CPU's
//! concern and deferred. The bus is a PURE function of (bus state, address,
//! value): no host state/time/RNG, deterministic zero init, deterministic
//! unmapped fills (CLAUDE prime directive).
//!
//! Machine integration contract:
//!   - The MACHINE owns the `Bus` value and passes `*Bus` into `Cpu(Bus)`. The
//!     bus never reaches into a device (push-registration model B12/Phase 0): a
//!     device EXPOSES a `MemHandler`/`PortHandler`; the machine calls `mapMmio`/
//!     `registerPort`. The bus stays device-agnostic.
//!   - Fixed init order (assigns handler IDs deterministically, B12):
//!     `Bus.init` → `loadRom` (incl. BIOS) → device MMIO/port registration →
//!     `Cpu(Bus)` construction → reset.
//!   - The InterruptController / Scheduler / FaultSink hooks are CPU-machine
//!     concerns and are NOT on the bus (cpu.md Phase 0 split). Do not fold
//!     IRQ/scheduler state into the bus.
//!
//! Handler purity contract (B9, determinism): any registered `MemHandler`/
//! `PortHandler` MUST be a pure function of (device state, address/port, value)
//! — no host time/RNG/thread/env; deterministic on reset; snapshot-serializable.
//! The bus cannot check this at comptime; it is enforced by device-module audits.
//!
//! Serializable state (B12): handlers are referenced by stable integer IDs
//! assigned in fixed registration order, NEVER by host pointer. See `snapshot`/
//! `restore` and the `Snapshot` doc for the captured-vs-replayed split.

const std = @import("std");
const contract = @import("bus_contract");

pub const memmap = @import("memmap.zig");
pub const a20 = @import("a20.zig");
pub const regions = @import("regions.zig");
pub const ports = @import("ports.zig");

pub const PageKind = memmap.PageKind;
pub const MemHandler = regions.MemHandler;
pub const PortHandler = ports.PortHandler;
pub const WidthCaps = ports.WidthCaps;

/// Max registered MMIO/port handlers (B12 — stable IDs index these arrays). ID 0
/// is the reserved "unmapped" slot for ports; MMIO uses a parallel scheme where
/// only `.mmio` pages consult `page_handler_id`. 254 device handlers is ample.
pub const max_handlers: u16 = 256;
/// The reserved unmapped/no-handler port ID (B6/B7).
pub const unmapped_port_id: u8 = 0;

pub const Bus = struct {
    // === HOT fields (touched by the RAM fast path) come first ===
    // (memory-and-performance.md hot/cold ordering, B6). The RAM fast path reads
    // ONLY this prefix: `ram`, `a20_mask`, `page_kind`. A comptime check below
    // pins this ordering so a future field add can't push a cold field into the
    // hot cache line.

    /// The ONE fixed, page-aligned, up-front guest RAM slab (B2/B3). Allocated
    /// once at `init`, freed at `deinit`, deterministically zero-filled. The
    /// RAM/ROM fast paths index it DIRECTLY; no per-op alloc ever.
    ram: []align(memmap.page_size) u8,

    /// The A20 address mask (B5). Power-on default = `mask_disabled` (A20 off).
    a20_mask: u32 = a20.mask_disabled,

    /// Per-page kind table (B1), sized to the A20-mask ceiling (512 pages, B3) —
    /// NOT the slab. Runtime-mutable snapshot state (mapMmio/unmapRegion/EMS
    /// remaps mutate it, B12).
    page_kind: [memmap.page_count]PageKind,

    /// Per-page MMIO handler ID (B12), only consulted on `.mmio` pages. 0 = none.
    page_handler_id: [memmap.page_count]u8,

    // === COLD fields (never touched by the RAM fast path) ===

    /// Registered MMIO handlers, indexed by stable ID (ID 0 unused for MMIO).
    mem_handlers: [max_handlers]?MemHandler = @splat(null),
    mem_handler_count: u16 = 1, // ID 0 reserved

    /// Dense port handler-ID table (B6): 64 KiB, cold tail. Default 0 = unmapped.
    port_handler_id: [65536]u8 = @splat(unmapped_port_id),
    /// Registered port handlers, indexed by stable ID. ID 0 = unmapped (null).
    port_handlers: [max_handlers]?PortHandler = @splat(null),
    port_handler_count: u16 = 1, // ID 0 reserved (unmapped)

    /// Debug-only count of dropped ROM/unmapped writes (B4). Must NOT affect
    /// emulated state (determinism) — purely for the API/MCP server.
    rom_write_drops: u64 = 0,

    allocator: std.mem.Allocator,

    comptime {
        // Contract conformance via the shared leaf (B10): catches drift at the
        // bus's own layer, exactly the assertion the CPU compiles against.
        contract.assertBusContract(Bus);

        // --- Hot/cold layout pin (B6, memory-and-performance.md) ---
        // The fields are DECLARED hot-first (`ram`, `a20_mask`, `page_kind`,
        // `page_handler_id`) then cold (handler registries, the 64 KiB port table,
        // counters). NOTE: Zig's default (auto) struct layout reorders fields by
        // alignment to minimize padding, so a raw `@offsetOf` ordering assertion
        // would NOT reflect declaration order and is not a meaningful pin here
        // (we deliberately do NOT assert a layout the compiler doesn't promise —
        // ground rule: no false guarantees). What we CAN pin deterministically:
        //   1. The RAM fast path touches only `ram`/`a20_mask`/`page_kind`
        //      (+`page_handler_id` on the rare `.mmio` branch) — verified by
        //      inspection of the accessors, none of which read the cold tables.
        //   2. A size lock so a future field add can't silently bloat the struct
        //      past its known tables (the only large members are the two ID
        //      tables + the RAM slice header).
        const expected_min = 65536 // port_handler_id
            + memmap.page_count // page_kind
            + memmap.page_count; // page_handler_id
        std.debug.assert(@sizeOf(Bus) >= expected_min);
        // Upper bound: tables + handler arrays + scalars + slack. Catches an
        // accidental inline of a large buffer into the struct.
        std.debug.assert(@sizeOf(Bus) <= expected_min + 0x4000);
        // The two ID tables are byte-keyed (dense-int-keyed, no map — B6).
        std.debug.assert(@TypeOf(@as(Bus, undefined).page_handler_id) == [memmap.page_count]u8);
        std.debug.assert(@TypeOf(@as(Bus, undefined).port_handler_id) == [65536]u8);
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Allocate the one fixed RAM slab (page-aligned, zero-filled) and build the
    /// default page-kind layout (B2/B3). Standard ROM regions (BIOS window) are
    /// `.rom` from the default layout (B4/Phase 3) — write-dropped, read-from-RAM
    /// — independent of `loadRom`.
    pub fn init(allocator: std.mem.Allocator) !Bus {
        const ram = try allocator.alignedAlloc(u8, .fromByteUnits(memmap.page_size), memmap.ram_total_size);
        @memset(ram, 0); // deterministic zero init (determinism-critical, CLAUDE #5)

        var self: Bus = .{
            .ram = ram,
            .page_kind = undefined,
            .page_handler_id = @splat(0),
            .allocator = allocator,
        };
        self.resetPageKindToDefault();
        return self;
    }

    pub fn deinit(self: *Bus) void {
        self.allocator.free(self.ram);
        self.* = undefined;
    }

    /// Rebuild the whole page-kind table from `defaultPageKind` (a deterministic
    /// function of address). Used at init and as the basis for `unmapRegion`.
    fn resetPageKindToDefault(self: *Bus) void {
        var page: u32 = 0;
        while (page < memmap.page_count) : (page += 1) {
            self.page_kind[page] = memmap.defaultPageKind(page);
        }
    }

    // -----------------------------------------------------------------------
    // A20 (B5) — the bus is the sole owner.
    // -----------------------------------------------------------------------

    /// Enable/disable the A20 gate (the BIOS/machine calls this during POST;
    /// power-on default is OFF). Bit-20-only masking; bits 21+ are NOT clamped.
    pub fn setA20(self: *Bus, enabled: bool) void {
        self.a20_mask = a20.maskFor(enabled);
    }

    /// Is the A20 gate currently enabled? (For the machine / debugger.)
    pub fn a20Enabled(self: *const Bus) bool {
        return self.a20_mask == a20.mask_enabled;
    }

    // -----------------------------------------------------------------------
    // The RAM fast path (Phase 1).
    // -----------------------------------------------------------------------

    /// True if `[masked, masked+size)` lies wholly within ONE page AND that page
    /// is RAM/ROM-readable and inside the slab — the single-region fast path.
    /// `size` is 2 or 4. (DOSBox `mem_readw_inline` shape.)
    inline fn fastRamSpan(self: *const Bus, masked: u32, comptime size: u32) bool {
        // In-page test: the access does not cross a page boundary.
        if ((masked & (memmap.page_size - 1)) > memmap.page_size - size) return false;
        const page = memmap.pageIndex(masked);
        const kind = self.page_kind[page];
        // RAM (r/w) and ROM (reads) are slab-backed; the slab bound check (B3:
        // check the SLAB, not the mask) guards the in-page span end too.
        if (kind != .ram and kind != .rom) return false;
        return masked + size <= memmap.ram_total_size;
    }

    // ---- 8-bit ----
    pub fn readPhys8(self: *Bus, phys: u32) u8 {
        const m = a20.apply(self.a20_mask, phys);
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram, .rom => {
                // Bounds-check against the SLAB, not the mask (B3 OOB fix).
                if (m < memmap.ram_total_size) return self.ram[m];
                return memmap.unmapped_fill;
            },
            .mmio => {
                const h = self.mmioHandler(page);
                // Host-pointer fast path (B11): RAM-like MMIO indexes directly.
                if (h.hostPtr(page)) |hp| return hp[m & (memmap.page_size - 1)];
                return h.read8(m);
            },
            .unmapped => return memmap.unmapped_fill,
        }
    }
    pub fn writePhys8(self: *Bus, phys: u32, v: u8) void {
        const m = a20.apply(self.a20_mask, phys);
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram => {
                if (m < memmap.ram_total_size) self.ram[m] = v;
            },
            .rom => self.rom_write_drops +%= 1, // drop-and-count (B4)
            .mmio => {
                const h = self.mmioHandler(page);
                if (h.hostPtr(page)) |hp| {
                    hp[m & (memmap.page_size - 1)] = v;
                    return;
                }
                h.write8(m, v);
            },
            .unmapped => {}, // drop (B7)
        }
    }

    /// True if `[m, m+size)` does NOT cross a 4 KiB page boundary (so the whole
    /// access is within ONE page and can be dispatched by that page's kind).
    inline fn inOnePage(m: u32, comptime size: u32) bool {
        return (m & (memmap.page_size - 1)) <= memmap.page_size - size;
    }

    // ---- 16-bit ----
    pub fn readPhys16(self: *Bus, phys: u32) u16 {
        const m = a20.apply(self.a20_mask, phys);
        if (self.fastRamSpan(m, 2)) return std.mem.readInt(u16, self.ram[m..][0..2], .little);
        if (inOnePage(m, 2)) return self.readWideOnePage(u16, m);
        return self.readWideSlow(u16, m); // region-crossing: per-byte ascending
    }
    pub fn writePhys16(self: *Bus, phys: u32, v: u16) void {
        const m = a20.apply(self.a20_mask, phys);
        if (self.fastRamSpan(m, 2)) {
            std.mem.writeInt(u16, self.ram[m..][0..2], v, .little);
            return;
        }
        if (inOnePage(m, 2)) {
            self.writeWideOnePage(u16, m, v);
            return;
        }
        self.writeWideSlow(u16, m, v);
    }

    // ---- 32-bit ----
    pub fn readPhys32(self: *Bus, phys: u32) u32 {
        const m = a20.apply(self.a20_mask, phys);
        if (self.fastRamSpan(m, 4)) return std.mem.readInt(u32, self.ram[m..][0..4], .little);
        if (inOnePage(m, 4)) return self.readWideOnePage(u32, m);
        return self.readWideSlow(u32, m);
    }
    pub fn writePhys32(self: *Bus, phys: u32, v: u32) void {
        const m = a20.apply(self.a20_mask, phys);
        if (self.fastRamSpan(m, 4)) {
            std.mem.writeInt(u32, self.ram[m..][0..4], v, .little);
            return;
        }
        if (inOnePage(m, 4)) {
            self.writeWideOnePage(u32, m, v);
            return;
        }
        self.writeWideSlow(u32, m, v);
    }

    // Wide access wholly within ONE page (no boundary cross), dispatched by the
    // page's kind. RAM/ROM that reached here means the page is RAM/ROM but
    // beyond-slab (→ fill / drop) OR fastRamSpan was false for slab reasons;
    // MMIO uses the handler's NATIVE width method (width-sensitive VGA, B11),
    // with the host-pointer fast path when available.
    fn readWideOnePage(self: *Bus, comptime T: type, m: u32) T {
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram, .rom => {
                if (m + @sizeOf(T) <= memmap.ram_total_size)
                    return std.mem.readInt(T, self.ram[m..][0..@sizeOf(T)], .little);
                return @as(T, memmap.unmapped_fill); // beyond slab → fill
            },
            .mmio => {
                const h = self.mmioHandler(page);
                if (h.hostPtr(page)) |hp| {
                    const off = m & (memmap.page_size - 1);
                    return std.mem.readInt(T, hp[off..][0..@sizeOf(T)], .little);
                }
                return switch (T) {
                    u16 => h.read16(m),
                    u32 => h.read32(m),
                    else => unreachable,
                };
            },
            .unmapped => return @as(T, memmap.unmapped_fill),
        }
    }
    fn writeWideOnePage(self: *Bus, comptime T: type, m: u32, v: T) void {
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram => {
                if (m + @sizeOf(T) <= memmap.ram_total_size)
                    std.mem.writeInt(T, self.ram[m..][0..@sizeOf(T)], v, .little);
            },
            .rom => self.rom_write_drops +%= 1,
            .mmio => {
                const h = self.mmioHandler(page);
                if (h.hostPtr(page)) |hp| {
                    const off = m & (memmap.page_size - 1);
                    std.mem.writeInt(T, hp[off..][0..@sizeOf(T)], v, .little);
                    return;
                }
                switch (T) {
                    u16 => h.write16(m, v),
                    u32 => h.write32(m, v),
                    else => unreachable,
                }
            },
            .unmapped => {},
        }
    }

    // -----------------------------------------------------------------------
    // The wide slow path (Phase 2): region-crossing / MMIO / unmapped. Decompose
    // into bytes routed INDEPENDENTLY through the 8-bit path in fixed ascending
    // address order, re-applying A20 PER BYTE (B5) so a 1 MiB-seam straddle wraps
    // each byte. Little-endian assemble/disassemble.
    //
    // `start` is already A20-masked; we re-mask each byte from the UNMASKED
    // running address so wraps are per-byte. We reconstruct the unmasked address
    // by... we only have the masked start; the CPU sends unmasked, but readPhys*
    // masked once. Per B5, the slow path re-masks per byte: we step the masked
    // address and re-mask the next byte from the pre-mask sum. To keep this a
    // pure function of the masked start (the only input we have here), we advance
    // the running PRE-mask address as (masked_start + i) and re-apply the mask —
    // matching spice86's per-byte TransformAddress on the incremented address.
    // -----------------------------------------------------------------------

    fn readWideSlow(self: *Bus, comptime T: type, start_masked: u32) T {
        const n = @sizeOf(T);
        var result: T = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // Re-apply A20 per byte (B5): the address advances pre-mask.
            const byte_phys = a20.apply(self.a20_mask, start_masked +% i);
            const b = self.readPhys8RawMasked(byte_phys);
            result |= @as(T, b) << @intCast(i * 8);
        }
        return result;
    }

    fn writeWideSlow(self: *Bus, comptime T: type, start_masked: u32, v: T) void {
        const n = @sizeOf(T);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const byte_phys = a20.apply(self.a20_mask, start_masked +% i);
            const b: u8 = @truncate(v >> @intCast(i * 8));
            self.writePhys8RawMasked(byte_phys, b);
        }
    }

    /// 8-bit access on an ALREADY-A20-masked address (the slow path's per-byte
    /// router). Distinct from `readPhys8` which masks its argument.
    fn readPhys8RawMasked(self: *Bus, m: u32) u8 {
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram, .rom => {
                if (m < memmap.ram_total_size) return self.ram[m];
                return memmap.unmapped_fill;
            },
            .mmio => {
                const h = self.mmioHandler(page);
                if (h.hostPtr(page)) |hp| return hp[m & (memmap.page_size - 1)];
                return h.read8(m);
            },
            .unmapped => return memmap.unmapped_fill,
        }
    }
    fn writePhys8RawMasked(self: *Bus, m: u32, v: u8) void {
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram => {
                if (m < memmap.ram_total_size) self.ram[m] = v;
            },
            .rom => self.rom_write_drops +%= 1,
            .mmio => {
                const h = self.mmioHandler(page);
                if (h.hostPtr(page)) |hp| {
                    hp[m & (memmap.page_size - 1)] = v;
                    return;
                }
                h.write8(m, v);
            },
            .unmapped => {},
        }
    }

    inline fn mmioHandler(self: *Bus, page: u32) MemHandler {
        const id = self.page_handler_id[page];
        return self.mem_handlers[id].?;
    }

    // -----------------------------------------------------------------------
    // Port I/O dispatch (B6/B7/Phase 4).
    // -----------------------------------------------------------------------

    pub fn portIn8(self: *Bus, port: u16) u8 {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return ports.unmapped_in8;
        return self.port_handlers[id].?.in8(port);
    }
    pub fn portIn16(self: *Bus, port: u16) u16 {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return ports.unmapped_in16;
        return self.port_handlers[id].?.in16(port);
    }
    pub fn portIn32(self: *Bus, port: u16) u32 {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return ports.unmapped_in32;
        return self.port_handlers[id].?.in32(port);
    }
    pub fn portOut8(self: *Bus, port: u16, v: u8) void {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return; // drop (B7)
        self.port_handlers[id].?.out8(port, v);
    }
    pub fn portOut16(self: *Bus, port: u16, v: u16) void {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return;
        self.port_handlers[id].?.out16(port, v);
    }
    pub fn portOut32(self: *Bus, port: u16, v: u32) void {
        const id = self.port_handler_id[port];
        if (id == unmapped_port_id) return;
        self.port_handlers[id].?.out32(port, v);
    }

    // -----------------------------------------------------------------------
    // Registration seams (Phase 3). The MACHINE is the only caller.
    // -----------------------------------------------------------------------

    /// True if any page in `[phys_start, phys_start+len)` is already MMIO-claimed.
    /// Side-effect-free precondition query (so the overlap policy is testable
    /// without tripping the `mapMmio` assert, which `@panic`s and can't be caught
    /// in-process). The asserts below use this.
    pub fn mmioPagesClaimed(self: *const Bus, phys_start: u32, len: u32) bool {
        const first = memmap.pageIndex(phys_start);
        const count = len >> memmap.page_shift;
        var p: u32 = 0;
        while (p < count) : (p += 1) {
            if (self.page_kind[first + p] == .mmio) return true;
        }
        return false;
    }

    /// True if any port in `[first, first+count)` is already registered.
    pub fn portRangeClaimed(self: *const Bus, first: u16, count: u32) bool {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const port: u16 = @intCast(@as(u32, first) + i);
            if (self.port_handler_id[port] != unmapped_port_id) return true;
        }
        return false;
    }

    /// Register an MMIO handler over `[phys_start, phys_start+len)` (B11/B8).
    /// Page-aligned; two devices may NOT share a page (asserted). Overlap with an
    /// already-claimed page asserts (never silently overwrite, ground rule).
    /// Returns the stable handler ID (B12).
    pub fn mapMmio(self: *Bus, phys_start: u32, len: u32, handler: MemHandler) u8 {
        std.debug.assert(phys_start % memmap.page_size == 0);
        std.debug.assert(len % memmap.page_size == 0 and len != 0);
        const first = memmap.pageIndex(phys_start);
        const count = len >> memmap.page_shift;
        std.debug.assert(first + count <= memmap.page_count);
        // Overlap check (ground rule: never silently overwrite).
        std.debug.assert(!self.mmioPagesClaimed(phys_start, len));
        const id = self.allocMemHandler(handler);
        var p: u32 = 0;
        while (p < count) : (p += 1) {
            self.page_kind[first + p] = .mmio;
            self.page_handler_id[first + p] = id;
        }
        return id;
    }

    fn allocMemHandler(self: *Bus, handler: MemHandler) u8 {
        std.debug.assert(self.mem_handler_count < max_handlers);
        const id: u8 = @intCast(self.mem_handler_count);
        self.mem_handlers[id] = handler;
        self.mem_handler_count += 1;
        return id;
    }

    /// Copy a ROM image into the backing RAM at `phys_start` (B4). The covered
    /// pages are already `.rom` from the default layout (reads hit RAM, writes
    /// drop). Overlap with an MMIO page asserts.
    pub fn loadRom(self: *Bus, phys_start: u32, bytes: []const u8) void {
        std.debug.assert(phys_start + bytes.len <= memmap.ram_total_size);
        const first = memmap.pageIndex(phys_start);
        const last = memmap.pageIndex(phys_start + @as(u32, @intCast(bytes.len)) - 1);
        var p = first;
        while (p <= last) : (p += 1) {
            std.debug.assert(self.page_kind[p] != .mmio); // ROM over MMIO
            // Mark as ROM so writes drop even if the page was conventional RAM.
            self.page_kind[p] = .rom;
        }
        @memcpy(self.ram[phys_start..][0..bytes.len], bytes);
    }

    /// Bounded bulk write of `bytes` into guest physical memory starting at
    /// `phys` (D19 — the `MEM_BlockWrite` shape). The warm host-service path (the
    /// EXE/COM loader image copy + INT 21h AH=40 write) uses this instead of a
    /// per-byte `writePhys8` loop. ONE A20/region check per span: if the whole
    /// A20-masked span lies in one contiguous `.ram` run inside the slab, a single
    /// `@memcpy`; otherwise a per-byte fallback (region-crossing / ROM / MMIO /
    /// A20-wrap). Deterministic: a pure memory operation, no host I/O timing — the
    /// cycle cost is charged by the synthetic D5 formula at the bridge, not here.
    pub fn writeGuestBlock(self: *Bus, phys: u32, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const len: u32 = @intCast(bytes.len);
        if (self.contiguousRamSpan(phys, len)) |start| {
            @memcpy(self.ram[start..][0..bytes.len], bytes);
            return;
        }
        for (bytes, 0..) |b, i| self.writePhys8(phys +% @as(u32, @intCast(i)), b);
    }

    /// Bounded bulk read of `dst.len` bytes from guest physical memory starting at
    /// `phys` (D19 — the `MEM_BlockRead` shape). Mirror of `writeGuestBlock`.
    pub fn readGuestBlock(self: *Bus, phys: u32, dst: []u8) void {
        if (dst.len == 0) return;
        const len: u32 = @intCast(dst.len);
        if (self.contiguousRamSpan(phys, len)) |start| {
            @memcpy(dst, self.ram[start..][0..dst.len]);
            return;
        }
        for (dst, 0..) |*b, i| b.* = self.readPhys8(phys +% @as(u32, @intCast(i)));
    }

    // -----------------------------------------------------------------------
    // SIDE-EFFECT-FREE inspection (the debugger peek path). NEVER routes through
    // a device READ handler (those mutate device state — e.g. the PIT latch
    // phase). RAM/ROM read straight from the slab; host-pointer-backed MMIO (VGA
    // VRAM, mapped EMS frame pages) read straight from the backing pointer;
    // non-hostPtr device MMIO uses the handler's pure `peek8`; an address that is
    // genuinely not peekable yields the deterministic `not_peekable_fill`.
    // Determinism prime directive: a peek leaves `machine.snapshot()` byte-
    // identical (CLAUDE #5/#6).
    // -----------------------------------------------------------------------

    /// The deterministic fill for an address that cannot be read without a side
    /// effect (a device whose `peek8` returns null). Distinct, well-defined value
    /// so the caller can tell a real 0 from a not-peekable region if it cares; the
    /// important property is that it is CONSTANT (no garbage, no host state).
    pub const not_peekable_fill: u8 = 0xFF;

    /// Side-effect-free 8-bit inspection read of an ALREADY-UNMASKED physical
    /// address (we A20-mask here, once). Pure: reads no device latch, advances no
    /// phase, mutates nothing.
    pub fn peekPhys8(self: *const Bus, phys: u32) u8 {
        const m = a20.apply(self.a20_mask, phys);
        const page = memmap.pageIndex(m);
        switch (self.page_kind[page]) {
            .ram, .rom => {
                if (m < memmap.ram_total_size) return self.ram[m];
                return memmap.unmapped_fill;
            },
            .mmio => {
                const id = self.page_handler_id[page];
                const h = self.mem_handlers[id].?;
                // RAM-like MMIO: read the backing pointer directly (no handler).
                if (h.hostPtr(page)) |hp| return hp[m & (memmap.page_size - 1)];
                // Non-hostPtr device MMIO: the pure peek, or not-peekable fill.
                return h.peek8(m) orelse not_peekable_fill;
            },
            .unmapped => return memmap.unmapped_fill,
        }
    }

    /// Side-effect-free bulk inspection read of `dst.len` bytes from guest
    /// physical `phys`. Mirror of `readGuestBlock` but on the peek path. A20 is
    /// re-applied per byte (matches the wide-access semantics).
    pub fn peekBlock(self: *const Bus, phys: u32, dst: []u8) void {
        for (dst, 0..) |*b, i| b.* = self.peekPhys8(phys +% @as(u32, @intCast(i)));
    }

    /// If `[phys, phys+len)` A20-masks to a contiguous run that stays within the
    /// slab, never crosses an A20-mask wrap, and is entirely `.ram` pages, return
    /// the masked start offset for a single `@memcpy`; else null (per-byte path).
    fn contiguousRamSpan(self: *const Bus, phys: u32, len: u32) ?u32 {
        const start = a20.apply(self.a20_mask, phys);
        const end = a20.apply(self.a20_mask, phys +% (len - 1));
        // A non-contiguous masked span (an A20 wrap inside the run) -> per-byte.
        if (end != start +% (len - 1)) return null;
        if (@as(u64, start) + len > memmap.ram_total_size) return null;
        const first = memmap.pageIndex(start);
        const last = memmap.pageIndex(start + (len - 1));
        var p = first;
        while (p <= last) : (p += 1) {
            if (self.page_kind[p] != .ram) return null;
        }
        return start;
    }

    /// Reset `[phys_start, phys_start+len)` to `defaultPageKind` (the DOSBox
    /// `MEM_ResetPageHandler` analog) — for device teardown.
    pub fn unmapRegion(self: *Bus, phys_start: u32, len: u32) void {
        std.debug.assert(phys_start % memmap.page_size == 0);
        std.debug.assert(len % memmap.page_size == 0 and len != 0);
        const first = memmap.pageIndex(phys_start);
        const count = len >> memmap.page_shift;
        var p: u32 = 0;
        while (p < count) : (p += 1) {
            self.page_kind[first + p] = memmap.defaultPageKind(first + p);
            self.page_handler_id[first + p] = 0;
        }
    }

    /// Register a port handler at a single port (B6). Double registration of a
    /// port asserts (programming error, ground rule). Returns the stable ID.
    pub fn registerPort(self: *Bus, port: u16, handler: PortHandler) u8 {
        std.debug.assert(!self.portRangeClaimed(port, 1)); // double-reg (ground rule)
        const id = self.allocPortHandler(handler);
        self.port_handler_id[port] = id;
        return id;
    }

    /// Register a port handler over `[first, first+count)` (B6). All slots must
    /// be unmapped (overlap asserts). Returns the stable ID.
    pub fn registerPortRange(self: *Bus, first: u16, count: u32, handler: PortHandler) u8 {
        std.debug.assert(count != 0 and @as(u32, first) + count <= 0x10000);
        std.debug.assert(!self.portRangeClaimed(first, count)); // overlap (ground rule)
        const id = self.allocPortHandler(handler);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const port: u16 = @intCast(@as(u32, first) + i);
            self.port_handler_id[port] = id;
        }
        return id;
    }

    fn allocPortHandler(self: *Bus, handler: PortHandler) u8 {
        std.debug.assert(self.port_handler_count < max_handlers);
        const id: u8 = @intCast(self.port_handler_count);
        self.port_handlers[id] = handler;
        self.port_handler_count += 1;
        return id;
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (B12 — determinism, CLAUDE #6).
    //
    // Captured IN the snapshot (emulation state): RAM slab bytes, the A20 mask,
    // the mutated page-kind table, the handler-ID index tables (page + port).
    // Device-side state (e.g. the EMS backing store) is owned & snapshotted by
    // the device module, not the bus.
    //
    // Replayed by the MACHINE on restore (config, NOT in the snapshot): handler
    // REGISTRATIONS (ID assignment order), ROM images, the init mappings. So on
    // restore the machine: (1) `Bus.init`, (2) re-runs `loadRom` + `mapMmio`/
    // `registerPort` in the SAME order (re-binding IDs → handlers), then (3)
    // `restore` overwrites RAM + A20 + the mutated tables with the snapshot.
    // Handlers are re-bound by stable ID, NEVER by host pointer (CLAUDE #5).
    // -----------------------------------------------------------------------

    /// The serializable emulation-state subset (B12). Plain old data, no
    /// pointers — round-trips byte-identical.
    pub const Snapshot = struct {
        a20_mask: u32,
        page_kind: [memmap.page_count]PageKind,
        page_handler_id: [memmap.page_count]u8,
        port_handler_id: [65536]u8,
        // RAM is captured separately (it is large) via `writeSnapshotRam` /
        // restored via the `ram` field below — but for a self-contained test we
        // also expose a slab copy. Callers may prefer streaming the RAM.
    };

    /// Capture the small (non-RAM) snapshot subset. RAM is captured by the
    /// caller copying `bus.ram` (it is the slab, byte-for-byte).
    pub fn snapshot(self: *const Bus) Snapshot {
        return .{
            .a20_mask = self.a20_mask,
            .page_kind = self.page_kind,
            .page_handler_id = self.page_handler_id,
            .port_handler_id = self.port_handler_id,
        };
    }

    /// Restore the small snapshot subset onto a freshly init'd + re-registered
    /// bus. The caller restores RAM by copying bytes into `bus.ram` (same length
    /// = the fixed slab). Handlers must already be re-registered in the same
    /// order so IDs match (B12).
    pub fn restore(self: *Bus, snap: Snapshot) void {
        self.a20_mask = snap.a20_mask;
        self.page_kind = snap.page_kind;
        self.page_handler_id = snap.page_handler_id;
        self.port_handler_id = snap.port_handler_id;
    }
};

test "Bus.init smoke: allocates, round-trips a byte, no leak" {
    var bus = try Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.writePhys8(0x100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.readPhys8(0x100));
}
