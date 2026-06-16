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
        strategy: mcb_mod.Strategy = .first_fit,
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
            self.strategy = .first_fit;
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
                    .int21 => .dispatch,
                    .int67 => .dispatch,
                    .int33 => .dispatch,
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
            }
        }

        // -------------------------------------------------------------------
        // DOS init (Phase 4): install vectors, build the arena MCB, version,
        // DTA, drive table, device table + standard handles.
        // -------------------------------------------------------------------

        /// Initialize the DOS kernel structures in guest RAM. `arena_start_seg` is
        /// the segment of the first MCB header (top of low DOS, below the program
        /// load area). `arena_paras` is the arena size in paragraphs.
        pub fn dosInit(self: *Self, br: *Bridge, arena_start_seg: u16, arena_paras: u16) void {
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

            // The arena MCB chain: one big free block.
            self.arena_first_mcb = arena_start_seg;
            self.mcb().initArena(arena_paras - 1);

            // The List-of-Lists / SysVars block (AH=52, D20). Placed in the low
            // DOS data area at a fixed segment; the documented LoL pointer (BX) is
            // `sysvars_lol_off` into the block, and [block:LoL-2] is the first-MCB
            // segment — the REAL arena anchor (D9), not a faked pointer.
            self.sysvars_seg = 0x0070;
            const lol = Int21.sysvars_lol_off;
            // Zero the SysVars block region first (deterministic).
            var z: u16 = 0;
            while (z < 64) : (z += 1) self.cpu.bus.writePhys8((@as(u32, self.sysvars_seg) << 4) + z, 0);
            // First-MCB segment anchor at [block:LoL-2].
            self.cpu.bus.writePhys16((@as(u32, self.sysvars_seg) << 4) + lol - 2, self.arena_first_mcb);

            // Standard handles 0-4 -> CON/CON/CON/AUX/PRN (D17).
            self.sft.openDeviceAt(0, &self.dev_table.con, .read_only); // stdin
            self.sft.openDeviceAt(1, &self.dev_table.con, .write_only); // stdout
            self.sft.openDeviceAt(2, &self.dev_table.con, .write_only); // stderr
            self.sft.openDeviceAt(3, &self.dev_table.aux, .read_write); // aux
            self.sft.openDeviceAt(4, &self.dev_table.prn, .write_only); // prn

            // Build an INITIAL PSP so the JFT (file-table) exists even before a
            // program is loaded (real DOS always has a current PSP). The loader
            // builds the real program PSP later; this is the bootstrap PSP whose
            // JFT maps the standard handles 0-4 -> SFT slots 0-4. Placed at the
            // arena's first data segment.
            const boot_psp: u16 = arena_start_seg + 1;
            self.current_psp = boot_psp;
            const p = Psp.at(self.cpu, boot_psp);
            p.build(boot_psp + 0x10, 0, 0, "");
            var h: u16 = 0;
            while (h < 5) : (h += 1) p.jftSet(h, @intCast(h));
            // The DTA defaults to the boot PSP's 0x80 offset.
            self.dta_seg = boot_psp;
            self.dta_off = 0x80;
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
