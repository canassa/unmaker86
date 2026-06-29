//! The emulated DOS kernel (D12): INT 21h dispatch + PSP/MCB/DTA/SFT + the host-FS
//! VFS + the EXE/COM loader + EMS INT 67h + INT 33h mouse. Host-serviced: a guest
//! `INT 21h` traps to a host Zig handler that reads/writes guest regs + memory and
//! charges a deterministic synthetic cost (D5). Imports the shared bridge leaf; it
//! does NOT import `bios` (D12 reversed).

const std = @import("std");
const Io = std.Io;
const cpu_mod = @import("cpu");
const Seg = cpu_mod.state.Seg;
const Reg32 = cpu_mod.state.Reg32;
const bridge_mod = @import("bridge");
const vfs = @import("vfs.zig");
const devices = @import("devices.zig");
const sft_mod = @import("sft.zig");
const psp_mod = @import("psp.zig");
const mcb_mod = @import("mcb.zig");
const dta_mod = @import("dta.zig");

pub const Vfs = vfs;
pub const DeviceTable = devices.DeviceTable;
pub const Sft = sft_mod.Sft;
pub const name83 = @import("name83.zig");
pub const clock = @import("clock.zig");

/// EMS page-frame window (D15) — re-exported so the machine can register the MMIO
/// device at wire time without importing the ems sub-module.
pub const ems_frame_phys: u32 = @import("ems.zig").FRAME_PHYS;
pub const ems_frame_len: u32 = @import("ems.zig").FRAME_LEN;

/// Non-generic re-export so the machine can stage the resident "EMMXXXX0" EMM
/// device-driver header into the BIOS image (before `loadRom`) without naming a
/// concrete CPU type — the EMS-presence signature BaK's `ems_detect_driver`
/// reads at [INT 67h vector segment]:0x0A. See `ems.zig` "device-driver header".
pub const stageEmsDeviceHeader = @import("ems.zig").stageDeviceHeader;
pub const ems_driver_name_off: u16 = @import("ems.zig").DRIVER_NAME_OFF;
pub const ems_driver_signature = @import("ems.zig").DRIVER_SIGNATURE;
/// EMS page accounting (re-exported for tests/callers): the invariant is
/// `ems_backing_pages == ems_reported_pages` — zdos backs every page it reports.
pub const ems_reported_pages: u16 = @import("ems.zig").REPORTED_PAGES;
pub const ems_backing_pages: u16 = @import("ems.zig").BACKING_PAGES;

/// DOS version reported by AH=30 (5.0 — BaK's target).
pub const DOS_VER_MAJOR: u8 = 5;
pub const DOS_VER_MINOR: u8 = 0;

// ---- Real-DOS low-memory map (dosbox-staging dos.h:96-106, Phase 1) ----
// The fixed segments the resident COMMAND.COM shell + the conventional arena
// live at, mirroring dosbox `DOS_SetupMemory` / `SHELL_Init` so a guest sees a
// real low-DOS layout (a program loaded as a CHILD of the shell at ~0x190, not
// as a root at a tuned base). DOS_CONDRV/SDA/CDS are reserved for Phase 2 (real
// List-of-Lists sub-structures); zdos services those host-side today.
pub const DOS_INFOBLOCK_SEG: u16 = 0x80; // List-of-Lists / SysVars block (AH=52)
pub const DOS_CONDRV_SEG: u16 = 0xA0; // CON device header (Phase 2)
pub const DOS_CONSTRING_SEG: u16 = 0xA8; // "CON" >20-files detection strings (Phase 2)
pub const DOS_SDA_SEG: u16 = 0xB2; // Swappable Data Area (Phase 2)
pub const DOS_CDS_SEG: u16 = 0x108; // Current Directory Structure (Phase 2)
pub const DOS_FIRST_SHELL: u16 = 0x118; // the resident COMMAND.COM PSP
pub const DOS_MEM_START: u16 = 0x16F; // first MCB header (top of low DOS)
// DOS private table pool (dosbox DOS_PRIVATE_SEGMENT 0xC800..0xD000). zdos plants
// the secondary resident tables here at dosbox's exact bump-allocated segments; the
// region is .unmapped by default (ROM window) so dosInit `mapRam`s it first. The
// sub-segments below are the result of dosbox's DOS_GetMemory(pages) call order
// (dos_tables.cpp:64-184).
pub const DOS_PRIV_SEG: u16 = 0xC800;
pub const PRIV_DBCS_SEG: u16 = 0xC808; // double-byte lead-byte table (12 paras)
pub const PRIV_FNCHAR_SEG: u16 = 0xC814; // filename char table (2 paras)
pub const PRIV_COLLATE_SEG: u16 = 0xC816; // collating seq + upcase (25 paras)
pub const PRIV_FCBSFT_SEG: u16 = 0xC82F; // fake FCB system file table (4 paras)
pub const PRIV_DPB_SEG: u16 = 0xC833; // fake drive parameter block (16 paras)
pub const PRIV_DISKBUF_SEG: u16 = 0xC846; // fake disk buffer head (6 paras)
pub const PRIV_MUXSFT_SEG: u16 = 0xC84C; // fake SFT for MUX AX=1216 (60 paras)
pub const UMB_START_SEG: u16 = 0x9FFF; // no-UMB sentinel boundary (dos_memory.cpp:22)
pub const ARENA_TOP: u16 = 0x9FFE; // last owned conventional paragraph

/// The serviced DOS-layer INTs (each = one callback id; handler switches on AH).
pub const DosInt = enum {
    int20, // terminate
    int21, // the kernel
    int22, // terminate address (default)
    int23, // Ctrl-C (default)
    int24, // critical error (default)
    int27, // TSR
    int28, // idle
    int2f, // multiplex
    int67, // EMS
    int33, // mouse
    // The INT 74h (IRQ12) mouse-callback PREP trap (Option C). NOT an IVT-vectored
    // stub: the host INT 74h trampoline (planted in the BIOS image) embeds this id's
    // `FE 38 id`, so its own slot tail is never executed (inert, like the INT 16h
    // poll-loop has-key/dequeue slots). Routed to `Int33.prepareInt74`.
    int74,
};

/// A structural "unsupported DOS service" signal (D11). The API server observes
/// the latest record; the guest still gets faithful real-DOS behavior (AL=0/CF
/// clear), but the host/API sees the honest "we don't implement this".
pub const Unsupported = struct { int: u8, ah: u8, al: u8 };

pub fn Dos(comptime Cpu: type) type {
    const Bridge = bridge_mod.Bridge(Cpu);
    const Psp = psp_mod.Psp(Cpu);
    const McbChain = mcb_mod.McbChain(Cpu);
    const Dta = dta_mod.Dta(Cpu);
    const Int21 = @import("int21.zig").Int21(Cpu);
    const Loader = @import("loader.zig").Loader(Cpu);
    const Ems = @import("ems.zig").Ems(Cpu);
    const Int33 = @import("int33.zig").Int33(Cpu);

    return struct {
        const Self = @This();
        pub const CpuType = Cpu;
        pub const BridgeType = Bridge;
        pub const DOS_VER_MAJOR = @import("dos.zig").DOS_VER_MAJOR;
        pub const DOS_VER_MINOR = @import("dos.zig").DOS_VER_MINOR;
        pub const PspView = Psp;
        pub const DtaView = Dta;
        pub const McbView = McbChain;
        pub const LoaderType = Loader;
        pub const EmsType = Ems;

        cpu: *Cpu = undefined,
        ids: std.enums.EnumArray(DosInt, u8) = .initFill(0xFF),

        // ---- Kernel state ----
        current_psp: u16 = 0,
        current_drive: u8 = 2, // C: (0=A)
        dta_seg: u16 = 0,
        dta_off: u16 = 0,
        arena_first_mcb: u16 = 0,
        strategy: u8 = 0, // INT 21h AH=58 strategy byte (fit-type & 0x3f, UMB bits & 0xc0)
        ret_code: u16 = 0, // last AH=4C/00 exit code (for AH=4D)
        ret_type: u8 = 0, // 0=normal exit, 1=Ctrl-C, 2=critical, 3=TSR
        last_error: u16 = 0, // last DOS error code (for AH=59 extended error)
        breakcheck: bool = false, // Ctrl-Break extended checking flag (AH=33)
        sysvars_seg: u16 = 0, // segment of the List-of-Lists / SysVars (AH=52)

        // Per-drive current directory (D8b), DOS-relative to the drive root (no
        // leading backslash, '\' separators). Empty = the root. A fixed inline
        // buffer per drive (no heap; deterministic).
        cwd: [26][64]u8 = @splat(@splat(0)),
        cwd_len: [26]u8 = @splat(0),

        // The active find-first/find-next search directory (DOS-relative). Only
        // one DTA search is active at a time by convention; the DTA reserved area
        // is too small for a full subdir path, so we keep it host-side (D8b).
        search_dir: [64]u8 = @splat(0),
        search_dir_len: u8 = 0,

        // The active FCB find-first/find-next search state (INT 21h AH=11/12).
        // The FCB find record lives in the DTA (too small for a full path), so the
        // search drive/pattern/index are kept host-side; one FCB search is active
        // at a time (the dosbox-x tempdta convention, dos_files.cpp:1898).
        fcb_search_drive: u8 = 0,
        fcb_search_pat: [11]u8 = @splat(' '),
        fcb_search_idx: usize = 0,
        fcb_search_ext: bool = false,

        // ---- Host-side state ----
        sft: Sft = .{},
        dev_table: DeviceTable = .{},
        drives: [26]?vfs.HostDirDrive = @splat(null),
        ems: Ems = .{},
        mouse: Int33 = .{},

        last_unsupported: ?Unsupported = null,
        /// Set true when the program calls AH=4C / INT 20h (the run loop stops).
        terminated: bool = false,

        pub fn init(self: *Self, cpu: *Cpu) void {
            self.cpu = cpu;
            self.ids = .initFill(0xFF);
            self.current_psp = 0;
            self.current_drive = 2;
            self.strategy = 0;
            self.ret_code = 0;
            self.ret_type = 0;
            self.last_error = 0;
            self.breakcheck = false;
            self.sysvars_seg = 0;
            self.cwd = @splat(@splat(0));
            self.cwd_len = @splat(0);
            self.search_dir = @splat(0);
            self.search_dir_len = 0;
            self.fcb_search_drive = 0;
            self.fcb_search_pat = @splat(' ');
            self.fcb_search_idx = 0;
            self.fcb_search_ext = false;
            self.sft.reset();
            self.dev_table.reset();
            self.drives = @splat(null);
            self.ems.init(cpu);
            self.mouse = .{};
            self.last_unsupported = null;
            self.terminated = false;
        }

        pub fn psp(self: *Self) Psp {
            return Psp.at(self.cpu, self.current_psp);
        }
        pub fn dta(self: *Self) Dta {
            return Dta.at(self.cpu, self.dta_seg, self.dta_off);
        }
        pub fn mcb(self: *Self) McbChain {
            var m = McbChain.init(self.cpu, self.arena_first_mcb);
            m.strategy = self.strategy;
            return m;
        }

        /// Mount a host directory as a DOS drive (D8). `drive` is 0='A'.
        pub fn mountDrive(self: *Self, drive: u8, dir: Io.Dir, io: Io) void {
            self.drives[drive] = vfs.HostDirDrive.init(dir, io);
        }

        pub fn drivePtr(self: *Self, drive: u8) ?*vfs.HostDirDrive {
            if (drive >= 26) return null;
            if (self.drives[drive]) |*d| return d;
            return null;
        }

        // -------------------------------------------------------------------
        // Callback registration (DOS-init). Mirrors the BIOS pattern.
        // -------------------------------------------------------------------
        pub fn registerCallbacks(
            self: *Self,
            br: *Bridge,
            ctx: *anyopaque,
            setOwner: *const fn (*anyopaque, u8) void,
        ) void {
            inline for (std.meta.fields(DosInt)) |f| {
                const dint: DosInt = @enumFromInt(f.value);
                const kind: bridge_mod.Kind = switch (dint) {
                    // The INT 74h prep trap is an IRQ-service callback (charges the
                    // `.irq` synthetic cost, like INT 08h/09h), not a DOS dispatch.
                    .int74 => .irq,
                    else => .dispatch,
                };
                const id = br.allocCallback(.iret, kind);
                self.ids.set(dint, id);
                setOwner(ctx, id);
            }
        }

        fn which(self: *Self, id: u8) DosInt {
            var it = self.ids.iterator();
            while (it.next()) |e| {
                if (e.value.* == id) return e.key;
            }
            return .int21;
        }

        pub fn dispatch(self: *Self, id: u8, cpu: *Cpu, br: *Bridge) void {
            switch (self.which(id)) {
                .int21 => Int21.service(self, cpu, br),
                .int20 => self.terminate(cpu, br, 0, 0),
                .int22 => {}, // default terminate target: IRET (run loop sees terminated)
                .int23 => {}, // default Ctrl-C: IRET (continue)
                .int24 => { // default critical-error: fail (AL=3 = fail)
                    cpu.st.setReg8(0, 3);
                },
                .int27 => self.unsupported(cpu, br, 0x27), // TSR deferred
                .int28 => {}, // idle: IRET
                .int2f => Int21.handle2f(self, cpu, br),
                .int67 => self.ems.service(self, cpu, br),
                .int33 => self.mouse.service(self, cpu, br),
                .int74 => self.mouse.prepareInt74(cpu),
            }
        }

        /// Emit the host INT 74h mouse-callback trampoline (Option C) into the BIOS
        /// ROM `image`. Called by the machine in POST after `registerCallbacks` (which
        /// assigned the prep id) and before `loadRom`, alongside `emitExecRetf` — so
        /// the stub is real guest code at `Bridge.INT74_PHYS`. IVT[0x74] is pointed at
        /// it in `dosInit`.
        pub fn emitInt74Trampoline(self: *Self, image: []u8) void {
            Bridge.emitInt74Trampoline(image, self.ids.get(.int74));
        }

        // -------------------------------------------------------------------
        // DOS init (Phase 4): install vectors, build the arena MCB, version,
        // DTA, drive table, device table + standard handles.
        // -------------------------------------------------------------------

        /// Initialize the DOS kernel structures in guest RAM, mirroring dosbox's
        /// `DOS_SetupMemory` + `SHELL_Init`: the 0x70 IRET stub, the List-of-Lists
        /// at 0x80, the standard-PC pre-fragmented MCB chain at DOS_MEM_START, and
        /// the resident COMMAND.COM shell PSP/env at DOS_FIRST_SHELL. The low map is
        /// FIXED (no memsize dependence — conventional memory is 640 KiB), so this
        /// takes no arena args. Every write is a compile-time constant (determinism).
        pub fn dosInit(self: *Self, br: *Bridge) void {
            // Vectors: point the DOS-serviced INTs at their stubs.
            br.setRealVec(self.ids.get(.int20), 0x20);
            br.setRealVec(self.ids.get(.int21), 0x21);
            br.setRealVec(self.ids.get(.int22), 0x22);
            br.setRealVec(self.ids.get(.int23), 0x23);
            br.setRealVec(self.ids.get(.int24), 0x24);
            br.setRealVec(self.ids.get(.int27), 0x27);
            br.setRealVec(self.ids.get(.int28), 0x28);
            br.setRealVec(self.ids.get(.int2f), 0x2F);
            br.setRealVec(self.ids.get(.int67), 0x67);
            br.setRealVec(self.ids.get(.int33), 0x33);
            // INT 74h points at the host TRAMPOLINE (in the BIOS image), NOT the
            // bare int74 slot: the trampoline (PUSHA/.../RETF/EOI_STUB) embeds the
            // prep id's `FE 38 id` and routes to `Int33.prepareInt74` (Option C). zdos
            // owns INT 74h (sub-decision A). Re-established on every driver reset.
            const t = Bridge.int74SegOff();
            self.cpu.bus.writePhys16(0x74 * 4, t.off);
            self.cpu.bus.writePhys16(0x74 * 4 + 2, t.seg);

            // ---- The 0x0070 IRET stub (dos_memory.cpp:474-481) ----
            // dosbox lets DOS claim a few BIOS interrupts so buggy games that
            // compare against the IVT (broken linked-list probes) see a real
            // handler. Plant a lone IRET at 0x70:0xF4 and point INT 01/02/03/04/0F
            // at it. Moving SysVars off 0x70 (to 0x80) frees this paragraph.
            self.cpu.bus.writePhys8((@as(u32, 0x70) << 4) + 0xF4, 0xCF); // IRET
            const iret_stub: u32 = (@as(u32, 0x70) << 16) | 0xF4;
            self.cpu.bus.writePhys32(0x01 * 4, iret_stub);
            self.cpu.bus.writePhys32(0x02 * 4, iret_stub);
            self.cpu.bus.writePhys32(0x03 * 4, iret_stub);
            self.cpu.bus.writePhys32(0x04 * 4, iret_stub);
            self.cpu.bus.writePhys32(0x0F * 4, iret_stub);

            // ---- The DOS private table pool (dos_tables.cpp:27-41) ----
            // dosbox carves resident tables from 0xC800 (DOS_PRIVATE_SEGMENT); that
            // segment is in zdos's .unmapped ROM window, so claim its first page as
            // RAM before planting. Idempotent + boot-invariant (re-run every post()).
            self.cpu.bus.mapRam(@as(u32, DOS_PRIV_SEG) << 4, 0x1000);

            // ---- The List-of-Lists / SysVars block + sub-structures (AH=52, D20) ----
            // dosbox places the DOS InfoBlock at DOS_INFOBLOCK_SEG (0x80); AH=52
            // returns ES:BX = 0x80:0x26 and [0x80:0x24] (= BX-2) is the firstMCB
            // anchor — the REAL arena MCB segment (DOS_MEM_START). NOTE (determinism,
            // correction G1): `sysvars_seg`/`arena_first_mcb` are boot-INVARIANT
            // constants recomputed by every `post()`; NOT snapshotted, NEVER mutated
            // at runtime — they survive a restore only because `post()` re-runs this.
            self.sysvars_seg = DOS_INFOBLOCK_SEG;
            self.arena_first_mcb = DOS_MEM_START;
            self.mcb().initPreFragmented(); // pre-fragmented arena (dos_memory.cpp:484)
            self.buildSysVars(); // full sDIB + SFT chain + CDS/device/table pointers
            self.buildDeviceChain(); // CON header @0xA0 + CON-detection strings @0xA8
            self.buildDosTables(); // fake FCB-SFT / DPB / disk-buffer / etc. @0xC800
            self.buildSda(); // Swappable Data Area @0xB2 (context filled by the shell)

            // Standard handles 0-4 -> CON/CON/CON/AUX/PRN (D17).
            self.sft.openDeviceAt(0, &self.dev_table.con, .read_only); // stdin
            self.sft.openDeviceAt(1, &self.dev_table.con, .write_only); // stdout
            self.sft.openDeviceAt(2, &self.dev_table.con, .write_only); // stderr
            self.sft.openDeviceAt(3, &self.dev_table.aux, .read_write); // aux
            self.sft.openDeviceAt(4, &self.dev_table.prn, .write_only); // prn

            // ---- The resident COMMAND.COM shell PSP + env (shell.cpp:1280-1357) ----
            self.installResidentShell();
        }

        /// Build the full DOS InfoBlock / List-of-Lists at DOS_INFOBLOCK_SEG (0x80),
        /// byte-faithful to dosbox `DOS_InfoBlock::SetLocation` (dos_classes.cpp:50-114)
        /// plus the device-chain / CDS / FCB / disk-buffer wiring from `DOS_SetupTables`
        /// (dos_tables.cpp). AH=52 returns ES:BX = 0x80:0x26; the documented LoL
        /// offsets are relative to that. Init is `memset(0xFF,144)` then `memset(0,14)`
        /// then every SSET (incl. the zero-valued ones), so the only bytes left 0xFF
        /// are dosbox's five gaps (0x14-0x19, 0x1E-0x21, 0x26-0x29, 0x2E-0x35, 0x7E-0x88
        /// — firstDPB/activeClock/activeCon/diskBufPtr/stuff/unknown3). Every write is a
        /// compile-time constant (determinism).
        fn buildSysVars(self: *Self) void {
            const cpu = self.cpu;
            const seg = self.sysvars_seg; // 0x80
            const base: u32 = @as(u32, seg) << 4;
            var i: u32 = 0;
            while (i < 0x90) : (i += 1) cpu.bus.writePhys8(base + i, 0xFF); // clear to 0xFF
            i = 0;
            while (i < 14) : (i += 1) cpu.bus.writePhys8(base + i, 0x00); // first 14 -> 0
            // Every SSET_* from SetLocation, in struct-offset order.
            cpu.bus.writePhys16(base + 0x04, 0x0001); // magicWord (DOS5+)
            cpu.bus.writePhys16(base + 0x0E, 0); // regCXfrom5e
            cpu.bus.writePhys16(base + 0x10, 0); // countLRUcache
            cpu.bus.writePhys16(base + 0x12, 0); // countLRUopens
            cpu.bus.writePhys16(base + 0x1A, 0); // sharingCount
            cpu.bus.writePhys16(base + 0x1C, 0); // sharingDelay
            cpu.bus.writePhys16(base + 0x22, 0); // ptrCONinput (no unread input)
            cpu.bus.writePhys16(base + 0x24, self.arena_first_mcb); // firstMCB anchor (D9)
            // firstFileTable -> seg:0xCC; a 2-node fake SFT chain of 100 files each so
            // programs see 100 handles (dos_classes.cpp:104-114). sft_offset =
            // offsetof(firstFileTable)+0xa2 = 0x2A+0xA2 = 0xCC; node #2 at seg+0x26=0xA6.
            cpu.bus.writePhys32(base + 0x2A, (@as(u32, seg) << 16) | 0xCC);
            cpu.bus.writePhys32(base + 0xCC, (@as(u32, seg + 0x26) << 16)); // node1.next -> 0xA6:0
            cpu.bus.writePhys16(base + 0xD0, 100); // node1.numFiles
            const n2: u32 = @as(u32, seg + 0x26) << 4;
            cpu.bus.writePhys32(n2 + 0x00, 0xFFFFFFFF); // node2.next = end
            cpu.bus.writePhys16(n2 + 0x04, 100); // node2.numFiles
            cpu.bus.writePhys16(base + 0x36, 0x0200); // maxSectorLength
            cpu.bus.writePhys32(base + 0x38, (@as(u32, seg) << 16) | 0x6D); // diskInfoBuffer -> self:0x6D
            cpu.bus.writePhys32(base + 0x3C, @as(u32, DOS_CDS_SEG) << 16); // curDirStructure -> 0x108:0
            cpu.bus.writePhys32(base + 0x40, @as(u32, PRIV_FCBSFT_SEG) << 16); // fcbTable -> 0xC82F:0
            cpu.bus.writePhys16(base + 0x44, 0); // protFCBs
            cpu.bus.writePhys8(base + 0x46, 0); // blockDevices (recomputed by AH=52)
            cpu.bus.writePhys8(base + 0x47, 0x01); // lastdrive (LASTDRIVE)
            cpu.bus.writePhys32(base + 0x48, @as(u32, DOS_CONDRV_SEG) << 16); // nulNextDriver -> CON 0xA0:0
            cpu.bus.writePhys16(base + 0x4C, 0x8004); // nulAttributes (NUL char dev)
            cpu.bus.writePhys32(base + 0x4E, 0); // nulStrategy
            cpu.bus.writePhys8(base + 0x52, 0x4E); // nulString "NUL     "
            cpu.bus.writePhys8(base + 0x53, 0x55);
            cpu.bus.writePhys8(base + 0x54, 0x4C);
            cpu.bus.writePhys8(base + 0x55, 0x20);
            cpu.bus.writePhys8(base + 0x56, 0x20);
            cpu.bus.writePhys8(base + 0x57, 0x20);
            cpu.bus.writePhys8(base + 0x58, 0x20);
            cpu.bus.writePhys8(base + 0x59, 0x20);
            cpu.bus.writePhys8(base + 0x5A, 0); // joindedDrives
            cpu.bus.writePhys16(base + 0x5B, 0); // specialCodeSeg
            cpu.bus.writePhys32(base + 0x5D, 0); // setverPtr
            cpu.bus.writePhys16(base + 0x61, 0); // a20FixOfs
            cpu.bus.writePhys16(base + 0x63, 0); // pspLastIfHMA
            cpu.bus.writePhys16(base + 0x65, 50); // buffers_x
            cpu.bus.writePhys16(base + 0x67, 50); // buffers_y
            cpu.bus.writePhys8(base + 0x69, 0); // bootDrive
            cpu.bus.writePhys8(base + 0x6A, 1); // useDwordMov
            // extendedSize = total extended KB. zdos models 1 MiB + HMA only and INT 15h
            // AH=88 reports 0 extended KB, so this is 0 (consistent, honest — no XMS).
            cpu.bus.writePhys16(base + 0x6B, 0); // extendedSize
            cpu.bus.writePhys32(base + 0x6D, @as(u32, PRIV_DISKBUF_SEG) << 16); // diskBufferHeadPt -> 0xC846:0
            cpu.bus.writePhys16(base + 0x71, 0); // dirtyDiskBuffers
            cpu.bus.writePhys32(base + 0x73, 0); // lookaheadBufPt
            cpu.bus.writePhys16(base + 0x77, 0); // lookaheadBufNumber
            cpu.bus.writePhys8(base + 0x79, 0); // bufferLocation
            cpu.bus.writePhys32(base + 0x7A, 0); // workspaceBuffer
            cpu.bus.writePhys8(base + 0x89, 0); // chainingUMB
            cpu.bus.writePhys16(base + 0x8A, 0); // minMemForExec
            cpu.bus.writePhys16(base + 0x8C, 0xFFFF); // startOfUMBChain (no UMBs)
            cpu.bus.writePhys16(base + 0x8E, DOS_MEM_START); // memAllocScanStart
        }

        /// Plant the resident device-driver chain head: the CON device header at
        /// DOS_CONDRV_SEG (0xA0) and the "CON" >20-files detection strings at
        /// DOS_CONSTRING_SEG (0xA8), byte-faithful to dos_tables.cpp:76-87. The LoL
        /// nulNextDriver field (set in buildSysVars) points here; CON's `next` ends the
        /// chain. NUL/LPT1 stay host-serviced (dosbox plants no RAM header for them);
        /// strategy/interrupt are invalid far pointers (device I/O is host-serviced).
        fn buildDeviceChain(self: *Self) void {
            const cpu = self.cpu;
            const con: u32 = @as(u32, DOS_CONDRV_SEG) << 4;
            cpu.bus.writePhys32(con + 0x00, 0xFFFFFFFF); // next -> end of chain
            cpu.bus.writePhys16(con + 0x04, 0x8013); // attr: char|special|stdout|stdin
            cpu.bus.writePhys32(con + 0x06, 0xFFFFFFFF); // strategy+interrupt (invalid)
            cpu.bus.writePhys32(con + 0x0A, 0x204E4F43); // name "CON " (43 4F 4E 20)
            cpu.bus.writePhys32(con + 0x0E, 0x20202020); // name "    " -> "CON     "
            const cs: u32 = @as(u32, DOS_CONSTRING_SEG) << 4;
            cpu.bus.writePhys32(cs + 0x0A, 0x204E4F43); // "CON " detection strings
            cpu.bus.writePhys32(cs + 0x1A, 0x204E4F43);
            cpu.bus.writePhys32(cs + 0x2A, 0x204E4F43);
            // The fake CDS: a single ASCIIZ "C:\" at DOS_CDS_SEG:0 (dos_tables.cpp:88-92);
            // the LoL curDirStructure (buildSysVars) points here. Directory state is kept
            // host-side (cwd[]/current_drive) exactly as dosbox keeps it in DOS_Drive.
            cpu.bus.writePhys32(@as(u32, DOS_CDS_SEG) << 4, 0x005C3A43); // "C:\\" + NUL
        }

        /// Plant the secondary resident tables in the 0xC800 private pool at dosbox's
        /// exact bump-allocated segments (dos_tables.cpp:96-184), so the LoL pointers
        /// (fcbTable, diskBufferHeadPt) and a literal-segment peek both resolve to real
        /// structures. Country/MUX tables are planted for byte-exactness even where
        /// zdos services the consuming call host-side.
        fn buildDosTables(self: *Self) void {
            const cpu = self.cpu;
            // DBCS lead-byte table: empty (a single 0 dword terminator).
            cpu.bus.writePhys32(@as(u32, PRIV_DBCS_SEG) << 4, 0);
            // Filename character table (dos_tables.cpp:100-123): a fixed 0x18-byte blob.
            const fnc: u32 = @as(u32, PRIV_FNCHAR_SEG) << 4;
            const fnchar = [_]u8{ 0x16, 0x00, 0x01, 0x00, 0xFF, 0x00, 0x00, 0x20, 0x02, 0x0E, 0x2E, 0x22, 0x2F, 0x5C, 0x5B, 0x5D, 0x3A, 0x7C, 0x3C, 0x3E, 0x2B, 0x3D, 0x3B, 0x2C };
            for (fnchar, 0..) |b, off| cpu.bus.writePhys8(fnc + @as(u32, @intCast(off)), b);
            // Collating sequence (word 0x100 + 256 identity bytes) + upcase table at
            // +258 (word 0x80 + 128 bytes 0x80+i) (dos_tables.cpp:126-131).
            const col: u32 = @as(u32, PRIV_COLLATE_SEG) << 4;
            cpu.bus.writePhys16(col, 0x100);
            var c: u32 = 0;
            while (c < 256) : (c += 1) cpu.bus.writePhys8(col + 2 + c, @intCast(c));
            cpu.bus.writePhys16(col + 258, 0x80);
            c = 0;
            while (c < 128) : (c += 1) cpu.bus.writePhys8(col + 258 + 2 + c, @intCast(0x80 + c));
            // Fake FCB system file table (LoL fcbTable -> here): next=end, 100 files.
            const fcb: u32 = @as(u32, PRIV_FCBSFT_SEG) << 4;
            cpu.bus.writePhys32(fcb + 0, 0xFFFFFFFF);
            cpu.bus.writePhys16(fcb + 4, 100);
            // Fake DPB array: per drive {drive#, unit#, 0x0200 bytes/sector, mediaid 0}.
            const dpb: u32 = @as(u32, PRIV_DPB_SEG) << 4;
            var d: u32 = 0;
            while (d < 26) : (d += 1) {
                cpu.bus.writePhys8(dpb + d * 9 + 0, @intCast(d)); // drive number
                cpu.bus.writePhys8(dpb + d * 9 + 1, @intCast(d)); // unit number
                cpu.bus.writePhys16(dpb + d * 9 + 2, 0x0200); // bytes per sector
                cpu.bus.writePhys16(dpb + 0x17 + d * 9, 0); // media id
            }
            // Fake disk-buffer head (LoL diskBufferHeadPt -> here): first 0x20 zeroed,
            // then fwd/back ptr 0xFFFF, not-in-use 0xFF, #FATs 1, DPB ptr 0xFFFFFFFF.
            const db: u32 = @as(u32, PRIV_DISKBUF_SEG) << 4;
            var k: u32 = 0;
            while (k < 0x20) : (k += 1) cpu.bus.writePhys8(db + k, 0);
            cpu.bus.writePhys16(db + 0x00, 0xFFFF);
            cpu.bus.writePhys16(db + 0x02, 0xFFFF);
            cpu.bus.writePhys8(db + 0x04, 0xFF);
            cpu.bus.writePhys8(db + 0x0A, 0x01);
            cpu.bus.writePhys32(db + 0x0D, 0xFFFFFFFF);
            // Fake SFT for MUX AX=1216 (separate from firstFileTable): hdr next=end,
            // 16 entries (dos_tables.cpp:172-183). SftNextTableOffset=0, NumFiles@4.
            const mux: u32 = @as(u32, PRIV_MUXSFT_SEG) << 4;
            cpu.bus.writePhys32(mux + 0, 0xFFFFFFFF);
            cpu.bus.writePhys8(mux + 4, 16);
        }

        /// Build the Swappable Data Area at DOS_SDA_SEG (0xB2), 26 bytes, byte-faithful
        /// to dosbox `DOS_SDA::Init` (dos_classes.cpp:635-640): zero-filled, then
        /// drive_crit_error (+0x02) = 0xFF. The InDOS flag (+0x01) and critical-error
        /// flag (+0x00) stay 0 — dosbox never increments InDOS, so a TSR polling it
        /// always sees "DOS idle" (matched exactly). The live context fields (current
        /// PSP/DTA/drive) are mirrored from the host kernel state by `writeSdaContext`.
        fn buildSda(self: *Self) void {
            const cpu = self.cpu;
            const base: u32 = @as(u32, DOS_SDA_SEG) << 4;
            var i: u32 = 0;
            while (i < 0x1A) : (i += 1) cpu.bus.writePhys8(base + i, 0);
            cpu.bus.writePhys8(base + 0x02, 0xFF); // drive_crit_error
        }

        /// Mirror the authoritative host kernel context (current PSP / DTA / drive) into
        /// the SDA's guest-RAM bytes, so a raw guest peek of 0xB2:0x10/0x0C/0x16 (the
        /// redirector / TSR pattern) is always current — exactly dosbox, where the SDA
        /// in RAM is the single source of truth. Called at every context-mutation site.
        /// All writes are deterministic projections of already-serialized state.
        pub fn writeSdaContext(self: *Self) void {
            const cpu = self.cpu;
            const base: u32 = @as(u32, DOS_SDA_SEG) << 4;
            cpu.bus.writePhys16(base + 0x0C, self.dta_off); // current DTA off
            cpu.bus.writePhys16(base + 0x0E, self.dta_seg); // current DTA seg
            cpu.bus.writePhys16(base + 0x10, self.current_psp); // current PSP
            cpu.bus.writePhys8(base + 0x16, self.current_drive); // current drive
        }

        /// Install the resident COMMAND.COM shell as the current process so the
        /// boot program loads as its CHILD (shell.cpp:1280-1357): the shell PSP at
        /// DOS_FIRST_SHELL (0x118) + env at 0x12B, both as MCB-owned blocks BELOW
        /// DOS_MEM_START (so a DOS MCB-walk from firstMCB never sees them — exactly
        /// dosbox). The shell has no command loop: its INT22 is a guest HLT (the
        /// byte-faithful analog of dosbox's `call_shellstop`/`CBRET_STOP`); the real
        /// machine-stop is `terminateTsr`'s parent==shell branch. INT24 chains to
        /// the old critical-error vector via a far-jmp; INT23 -> shell PSP:0; INT2E
        /// -> the safe 0x70 IRET (zdos does NOT fake an INT 2Eh command handler).
        fn installResidentShell(self: *Self) void {
            const cpu = self.cpu;
            const shell = DOS_FIRST_SHELL; // 0x118
            const env_seg: u16 = shell + 19; // 0x12B (dosbox: DOS_FIRST_SHELL+19)
            const stub_off: u16 = 0x110; // (16+1)<<4 — the stub paragraph at PSP+0x11 (0x129)

            // Shell PSP-MCB at 0x117 (owner=shell, size 0x12) and env-MCB at 0x12A
            // (owner=shell, size DOS_MEM_START-env_seg=0x44). 'M' (link) headers;
            // standalone (not anchored by firstMCB). owner-name fields zeroed.
            plantMcb(cpu, shell - 1, mcb_mod.SIG_LINK, shell, 0x10 + 2);
            plantMcb(cpu, env_seg - 1, mcb_mod.SIG_LINK, shell, DOS_MEM_START - env_seg);

            // The shell PSP: self-parented (root-of-DOS, like shell.cpp:1345), mem
            // top at shell+0x12, env at 0x12B, empty command tail.
            const p = Psp.at(cpu, shell);
            p.build(shell + 0x12, env_seg, shell, "");

            // The environment block (shell.cpp:1311-1320): PATH / COMSPEC, the
            // double-NUL terminator, the 0x0001 entry-count word, then the program
            // path. These advertise the Z: utility-drive structure statically.
            var eoff: u32 = @as(u32, env_seg) << 4;
            writeEnvStr(cpu, &eoff, "PATH=Z:\\");
            writeEnvStr(cpu, &eoff, "COMSPEC=Z:\\COMMAND.COM");
            cpu.bus.writePhys8(eoff, 0); // second NUL of the double-NUL
            eoff += 1;
            cpu.bus.writePhys16(eoff, 0x0001); // entry-count word
            eoff += 2;
            writeEnvStr(cpu, &eoff, "Z:\\COMMAND.COM");

            // The stub paragraph at 0x118:0x110 (= 0x129:0). INT24 far-jmp chaining
            // to the OLD critical-error vector, then the INT22 HLT backstop at
            // +0x115 (NOT +0x110, which the far-jmp occupies — correction E/F).
            const sbase: u32 = (@as(u32, shell) << 4) + stub_off;
            const old_int24 = cpu.bus.readPhys32(0x24 * 4);
            cpu.bus.writePhys8(sbase + 0, 0xEA); // JMP FAR ptr16:16
            cpu.bus.writePhys32(sbase + 1, old_int24); // -> old INT24 handler
            cpu.bus.writePhys8(sbase + 5, 0xF4); // HLT — the INT22 byte-faithful stop

            // Repoint the vectors at the shell stubs (shell.cpp:1287-1297):
            //   INT24 -> 0x118:0x110 (the far-jmp), INT23 -> 0x118:0 ("int 20"),
            //   INT22 -> 0x118:0x115 (the HLT), INT2E -> 0x70:0xF4 (safe IRET).
            cpu.bus.writePhys32(0x24 * 4, (@as(u32, shell) << 16) | stub_off);
            cpu.bus.writePhys32(0x23 * 4, @as(u32, shell) << 16);
            cpu.bus.writePhys32(0x22 * 4, (@as(u32, shell) << 16) | (stub_off + 5));
            cpu.bus.writePhys32(0x2E * 4, (@as(u32, 0x70) << 16) | 0xF4);

            // The shell PSP's saved INT22/23/24 capture the just-installed vectors
            // (dosbox MakeNew SaveVectors order — IVT set BEFORE the PSP snapshots).
            // So the boot program's own `saveVectors` at load time inherits the
            // shell-halt INT22 as its parent-resume address (correction E).
            p.saveVectors(
                cpu.bus.readPhys32(0x22 * 4),
                cpu.bus.readPhys32(0x23 * 4),
                cpu.bus.readPhys32(0x24 * 4),
            );

            // The shell becomes the current process; its JFT maps the standard
            // handles 0-4 -> SFT slots 0-4. DTA defaults to shell:0x80.
            self.current_psp = shell;
            var h: u16 = 0;
            while (h < 5) : (h += 1) p.jftSet(h, @intCast(h));
            self.dta_seg = shell;
            self.dta_off = 0x80;
            self.writeSdaContext(); // mirror the initial PSP/DTA/drive into the SDA
        }

        /// Plant a fixed MCB header (sig + owner + size + zeroed 8-byte name) for a
        /// permanently-resident block (an install, not an allocation).
        fn plantMcb(cpu: *Cpu, seg: u16, sig: u8, own: u16, sz: u16) void {
            const base: u32 = @as(u32, seg) << 4;
            cpu.bus.writePhys8(base + mcb_mod.OFF_SIG, sig);
            cpu.bus.writePhys16(base + mcb_mod.OFF_OWNER, own);
            cpu.bus.writePhys16(base + mcb_mod.OFF_SIZE, sz);
            var i: u32 = 8;
            while (i < 16) : (i += 1) cpu.bus.writePhys8(base + i, 0);
        }

        /// Write a NUL-terminated string into the environment block and advance the
        /// running physical offset past the terminator.
        fn writeEnvStr(cpu: *Cpu, off: *u32, s: []const u8) void {
            for (s) |c| {
                cpu.bus.writePhys8(off.*, c);
                off.* += 1;
            }
            cpu.bus.writePhys8(off.*, 0);
            off.* += 1;
        }

        // -------------------------------------------------------------------
        // D11: the unsupported-service policy. Generic unknown-AH default: AL=0,
        // CF CLEAR (faithful real DOS) + the structural signal.
        // -------------------------------------------------------------------
        pub fn unsupported(self: *Self, cpu: *Cpu, br: *Bridge, int: u8) void {
            self.last_unsupported = .{
                .int = int,
                .ah = cpu.st.getReg8(4),
                .al = cpu.st.getReg8(0),
            };
            cpu.st.setReg8(0, 0); // AL = 0 (dos.cpp:1610 behavior)
            br.setGuestCF(false); // real DOS does NOT set CF for an unknown AH
        }

        /// A faithful DOS error return (rule a): CF=1, AX=error code. Used ONLY
        /// where real DOS itself sets an error (e.g. open a missing file -> AX=2).
        /// Records the code as `last_error` (the `dos.errorcode` AH=59 returns).
        pub fn dosError(self: *Self, cpu: *Cpu, br: *Bridge, code: u16) void {
            self.last_error = code;
            cpu.st.setReg16(0, code);
            br.setGuestCF(true);
        }

        /// The per-drive current directory (DOS-relative, no leading '\'). Empty
        /// = the root. `drive` is 0='A'.
        pub fn cwdOf(self: *Self, drive: u8) []const u8 {
            if (drive >= 26) return "";
            return self.cwd[drive][0..self.cwd_len[drive]];
        }
        pub fn setCwd(self: *Self, drive: u8, path: []const u8) bool {
            if (drive >= 26) return false;
            if (path.len > self.cwd[drive].len) return false;
            @memcpy(self.cwd[drive][0..path.len], path);
            self.cwd_len[drive] = @intCast(path.len);
            return true;
        }

        pub fn searchDir(self: *Self) []const u8 {
            return self.search_dir[0..self.search_dir_len];
        }
        pub fn setSearchDir(self: *Self, path: []const u8) bool {
            if (path.len > self.search_dir.len) return false;
            @memcpy(self.search_dir[0..path.len], path);
            self.search_dir_len = @intCast(path.len);
            return true;
        }

        // -------------------------------------------------------------------
        // Terminate (AH=4C / AH=00 / INT 20h) — the full DOS_Terminate unwind
        // (dos_execute.cpp:114-178). For a NON-ROOT process this restores the
        // parent's stack + registers and resumes the parent at INT 22h, all
        // SYNCHRONOUSLY within this one trap, and leaves `terminated == false`
        // (LOCKED §2 — there is no later host frame to clear it, and
        // `controller.terminalReason()` stops the parent if it is still set). The
        // ROOT process (self-parented PSP) leaves `terminated == true` so the run
        // loop / controller stops there exactly as before.
        // -------------------------------------------------------------------
        pub fn terminate(self: *Self, cpu: *Cpu, br: *Bridge, code: u8, kind: u8) void {
            self.terminateTsr(cpu, br, code, kind, false);
        }

        /// `terminate` with the TSR (keep-resident) carve-out exposed (LOCKED §5):
        /// when `tsr` is true the parent switch still happens but the child's open
        /// files are NOT closed and its memory is NOT freed (it stays resident),
        /// mirroring `DOS_Terminate(..., is_terminate_and_stay_resident)`
        /// (dos_execute.cpp:130-173). AH=31h / INT 27h remain `unsupported` for now
        /// (no caller passes `tsr = true`), but the unwind is correct if/when wired.
        pub fn terminateTsr(self: *Self, cpu: *Cpu, br: *Bridge, code: u8, kind: u8, tsr: bool) void {
            self.ret_code = code;
            self.ret_type = kind;

            const child_psp_seg = self.current_psp;
            const child = Psp.at(cpu, child_psp_seg);
            const parent_psp_seg = child.getParent();

            // ROOT process: PSP is self-parented (dos_execute.cpp:124-126). Restore
            // its own INT 22/23/24 and surface termination to the run loop /
            // controller (no unwind, no parent to resume).
            if (parent_psp_seg == child_psp_seg or parent_psp_seg == 0) {
                cpu.bus.writePhys32(0x22 * 4, child.getInt22());
                cpu.bus.writePhys32(0x23 * 4, child.getInt23());
                cpu.bus.writePhys32(0x24 * 4, child.getInt24());
                self.terminated = true;
                return;
            }

            // TERMINATE-TO-SHELL (correction A): a program whose parent IS the
            // resident COMMAND.COM shell terminates ROOT-STYLE — the shell has no
            // command loop to resume into and its PSP carries NO valid saved stack
            // (0x2E == 0), so running the normal unwind below would read the IVT as
            // the parent register block and plant an IRET frame over page 0 (the
            // INT 3/4 vectors). Instead restore the child's INT22/23/24, reclaim the
            // child's files + memory, and surface termination (the dosbox
            // `call_shellstop`/`CBRET_STOP` analog — the shell just halts). This is
            // detected EARLY, before any SS:SP restore / register pop / IRET-frame
            // write. A grandchild whose parent != shell still takes the full unwind
            // below; only an unwind whose parent IS the shell stops here. (Mutually
            // exclusive with the root guard above: the shell self-parents, so the
            // shell terminating itself is caught there, never here.)
            if (parent_psp_seg == DOS_FIRST_SHELL) {
                cpu.bus.writePhys32(0x22 * 4, child.getInt22());
                cpu.bus.writePhys32(0x23 * 4, child.getInt23());
                cpu.bus.writePhys32(0x24 * 4, child.getInt24());
                if (!tsr) self.closeProcessFiles(cpu, child_psp_seg);
                if (!tsr) self.mcb().freeByOwner(child_psp_seg);
                self.terminated = true;
                return;
            }

            // --- Non-root unwind (mirrors dos_execute.cpp:134-177) ---
            // (a) the parent resume CS:IP saved in the child PSP's INT 22.
            const old22 = child.getInt22();
            // (b) restore INT 22/23/24 from the terminating (child) PSP.
            cpu.bus.writePhys32(0x22 * 4, child.getInt22());
            cpu.bus.writePhys32(0x23 * 4, child.getInt23());
            cpu.bus.writePhys32(0x24 * 4, child.getInt24());
            // (c) close the child's files (skipped for a keep-resident TSR).
            if (!tsr) self.closeProcessFiles(cpu, child_psp_seg);
            // (d) switch back to the parent PSP + its DTA (PSP:0x80).
            self.current_psp = parent_psp_seg;
            self.dta_seg = parent_psp_seg;
            self.dta_off = 0x80;
            self.writeSdaContext(); // mirror the restored parent context into the SDA
            // (e) restore the parent SS:SP from the parent PSP's saved-stack field.
            const parent = Psp.at(cpu, parent_psp_seg);
            const pss = parent.getStackSeg();
            var psp_sp = parent.getStackOff();
            cpu.loadSegment(.ss, pss);
            const pbase: u32 = @as(u32, pss) << 4;
            // (f) pop the 18-byte parent register block (AX,BX,CX,DX,SI,DI,BP,DS,ES
            //     ascending from the saved SP); then SP += 18.
            cpu.st.setReg16(@intFromEnum(Reg32.eax), cpu.bus.readPhys16(pbase + psp_sp + 0));
            cpu.st.setReg16(@intFromEnum(Reg32.ebx), cpu.bus.readPhys16(pbase + psp_sp + 2));
            cpu.st.setReg16(@intFromEnum(Reg32.ecx), cpu.bus.readPhys16(pbase + psp_sp + 4));
            cpu.st.setReg16(@intFromEnum(Reg32.edx), cpu.bus.readPhys16(pbase + psp_sp + 6));
            cpu.st.setReg16(@intFromEnum(Reg32.esi), cpu.bus.readPhys16(pbase + psp_sp + 8));
            cpu.st.setReg16(@intFromEnum(Reg32.edi), cpu.bus.readPhys16(pbase + psp_sp + 10));
            cpu.st.setReg16(@intFromEnum(Reg32.ebp), cpu.bus.readPhys16(pbase + psp_sp + 12));
            cpu.loadSegment(.ds, cpu.bus.readPhys16(pbase + psp_sp + 14));
            cpu.loadSegment(.es, cpu.bus.readPhys16(pbase + psp_sp + 16));
            psp_sp +%= 18;
            // (g) build the IRET frame the int21 trap's `.iret` tail will pop so the
            //     parent resumes at INT 22 (old22): IP, CS, FLAGS ascending. IF set,
            //     test flags cleared, bit1 reserved (dos_execute.cpp:163-168 writes
            //     0x7202; in real mode the IOPL/NT bits are inert, so 0x0202 — IF +
            //     reserved — is the faithful, deterministic real-mode value).
            psp_sp -%= 6;
            cpu.bus.writePhys16(pbase + psp_sp + 0, @truncate(old22)); // IP
            cpu.bus.writePhys16(pbase + psp_sp + 2, @truncate(old22 >> 16)); // CS
            cpu.bus.writePhys16(pbase + psp_sp + 4, 0x0202); // FLAGS (IF set)
            cpu.st.setReg16(@intFromEnum(Reg32.esp), psp_sp);
            // (h) free the child's memory (skipped for a keep-resident TSR).
            if (!tsr) self.mcb().freeByOwner(child_psp_seg);
            // (i) the parent keeps running — do NOT leave `terminated` set, or the
            //     controller's terminalReason() would stop the parent (LOCKED §2).
            self.terminated = false;
            // The int21 trap stub's `.iret` tail now pops the frame at (g) off the
            // PARENT stack (SS:SP was switched in (e)) and resumes the parent at
            // INT 22. The child's own abandoned INT 21h frame is dead (child memory
            // freed). CF is irrelevant — the parent resumes via the planted IRET
            // frame, not via the EXEC caller's CF check (it reads the rc via AH=4D).
            _ = br;
        }

        /// Close every open file the process `psp_seg` owns (DOS_PSP::CloseFiles,
        /// dos_execute.cpp:131). Walks the PSP JFT and closes each non-free handle
        /// the SAME way AH=3E does (refcount-aware: dup'd aliases keep the file open;
        /// real files close the host file + free the SFT slot at refcount 1; the
        /// shared CON/AUX/PRN device slots stay open). So a child that exits without
        /// closing its files does not leak SFT slots.
        fn closeProcessFiles(self: *Self, cpu: *Cpu, psp_seg: u16) void {
            const p = Psp.at(cpu, psp_seg);
            const max = p.maxFiles();
            var h: u16 = 0;
            while (h < max) : (h += 1) {
                const idx = p.jftGet(h);
                if (idx == psp_mod.JFT_FREE) continue;
                p.jftFree(h);
                const e = self.sft.get(idx);
                if (!e.in_use) continue;
                if (e.refcount > 1) {
                    e.refcount -= 1;
                    continue;
                }
                switch (e.ref) {
                    .file => |hf| {
                        if (self.drivePtr(e.drive)) |d| d.close(hf);
                        self.sft.freeSlot(idx);
                    },
                    .device => {}, // CON/AUX/PRN persist (shared slots)
                }
            }
        }

        // ---- DOS error codes (subset) ----
        pub const ERR_FILE_NOT_FOUND: u16 = 2;
        pub const ERR_PATH_NOT_FOUND: u16 = 3;
        pub const ERR_TOO_MANY_OPEN: u16 = 4;
        pub const ERR_ACCESS_DENIED: u16 = 5;
        pub const ERR_INVALID_HANDLE: u16 = 6;
        pub const ERR_NOT_ENOUGH_MEM: u16 = 8;
        pub const ERR_INVALID_FUNC: u16 = 1;
        pub const ERR_NO_MORE_FILES: u16 = 18;
        pub const ERR_INVALID_DRIVE: u16 = 15;
        pub const ERR_FILE_EXISTS: u16 = 80; // DOSERR_FILE_ALREADY_EXISTS (AH=5B)
    };
}
