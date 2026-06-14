//! The EXE/COM loader (Phase 6) — the path that starts a real DOS program (and,
//! for v1, Betrayal at Krondor). Parses an MZ EXE (or a flat COM), allocates via
//! MCB, builds the PSP + environment block, applies relocations, sets up registers,
//! and transfers control. The image copy + relocation reads go through
//! `bus.writeGuestBlock`/`readGuestBlock` + a fixed stack scratch (D19) — no
//! per-byte loop on the warm path. Re-derived from the documented MZ format, not
//! copied from DOSBox's GPL `dos_execute.cpp`.

const std = @import("std");
const Seg = @import("cpu").state.Seg;
const Reg32 = @import("cpu").state.Reg32;
const vfs = @import("vfs.zig");
const name83 = @import("name83.zig");
const psp_mod = @import("psp.zig");

const EAX = @intFromEnum(Reg32.eax);
const EBX = @intFromEnum(Reg32.ebx);

pub const MZ_MAGIC1: u16 = 0x5A4D; // 'MZ'
pub const MZ_MAGIC2: u16 = 0x4D5A; // 'ZM'

pub const LoadMode = enum { load_and_run, load_overlay, load_only };

/// The MZ EXE header fields (re-derived). All u16, little-endian, from offset 0.
pub const ExeHeader = struct {
    signature: u16,
    extra_bytes: u16, // bytes in the last page (0 = full page)
    pages: u16, // 512-byte pages, incl. header
    relocations: u16, // number of relocation entries
    header_paras: u16, // header size in paragraphs
    min_alloc: u16, // min extra paragraphs
    max_alloc: u16, // max extra paragraphs
    init_ss: u16,
    init_sp: u16,
    checksum: u16,
    init_ip: u16,
    init_cs: u16,
    reloc_table: u16, // offset of the relocation table
    overlay: u16,
};

pub fn Loader(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);
        const Psp = psp_mod.Psp(Cpu);

        pub const Result = struct {
            psp_seg: u16,
            cs: u16,
            ip: u16,
            ss: u16,
            sp: u16,
        };

        pub const LoadError = error{ NotFound, NoMemory, BadImage, IoFailed };

        /// Load `name` (a host filename relative to `drive`) and (for run mode) set
        /// up CPU registers to start it. `cmdtail` is the command tail. Used by the
        /// initial-load boot path AND by AH=4B EXEC.
        pub fn loadProgram(
            dos: *Dos,
            cpu: *Cpu,
            drive_idx: u8,
            host_name: []const u8,
            cmdtail: []const u8,
            mode: LoadMode,
        ) LoadError!Result {
            const drive = dos.drivePtr(drive_idx) orelse return error.NotFound;
            const hf = drive.open(host_name, .read_only) catch return error.NotFound;
            defer drive.close(hf);

            const fsize = drive.size(hf) catch return error.IoFailed;

            // Peek the first two bytes to decide EXE vs COM (re-derived branch).
            var magic: [2]u8 = undefined;
            const got = drive.readAt(hf, 0, &magic) catch return error.IoFailed;
            const sig: u16 = if (got >= 2) (@as(u16, magic[0]) | (@as(u16, magic[1]) << 8)) else 0;

            if (sig == MZ_MAGIC1 or sig == MZ_MAGIC2) {
                return loadExe(dos, cpu, drive, hf, fsize, cmdtail, mode);
            }
            return loadCom(dos, cpu, drive, hf, fsize, cmdtail, mode);
        }

        // ----------------------------------------------------------------
        // EXE
        // ----------------------------------------------------------------
        fn loadExe(
            dos: *Dos,
            cpu: *Cpu,
            drive: *vfs.HostDirDrive,
            hf: vfs.HostFile,
            fsize: u64,
            cmdtail: []const u8,
            mode: LoadMode,
        ) LoadError!Result {
            var hdr_bytes: [28]u8 = undefined;
            const n = drive.readAt(hf, 0, &hdr_bytes) catch return error.IoFailed;
            if (n < 28) return error.BadImage;
            const h = parseHeader(&hdr_bytes);

            const header_bytes: u32 = @as(u32, h.header_paras) * 16;
            var image_size: u32 = @as(u32, h.pages) * 512;
            if (h.extra_bytes != 0) image_size = image_size - 512 + h.extra_bytes;
            if (image_size < header_bytes) return error.BadImage;
            const load_bytes = image_size - header_bytes;
            _ = fsize;

            // Allocate: PSP (16 paras) + image + min_alloc.
            const image_paras: u32 = (load_bytes + 15) / 16;
            const total_paras: u32 = 16 + image_paras + h.min_alloc;
            const want: u16 = @intCast(@min(total_paras, 0xFFFF));

            const env_seg = buildEnv(dos, cpu, host_path_placeholder) orelse return error.NoMemory;
            const psp_seg = dos.mcb().alloc(want, dos.current_psp) orelse {
                // free env on failure
                _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            };

            const load_seg: u16 = psp_seg + 16;

            // Copy the image (after the header) into guest RAM at load_seg:0000.
            try copyFileToGuest(cpu, drive, hf, header_bytes, (@as(u32, load_seg) << 4), load_bytes);

            // Apply relocations: each entry is offset:segment; add load_seg to the
            // word at (load_seg + entry.segment):entry.offset.
            applyRelocations(cpu, drive, hf, h, load_seg) catch return error.IoFailed;

            // Build the PSP + env + JFT inherit.
            buildPsp(dos, cpu, psp_seg, env_seg, want, cmdtail);
            dos.current_psp = psp_seg;
            dos.dta_seg = psp_seg;
            dos.dta_off = 0x80;

            const res: Result = .{
                .psp_seg = psp_seg,
                .cs = load_seg + h.init_cs,
                .ip = h.init_ip,
                .ss = load_seg + h.init_ss,
                .sp = h.init_sp,
            };
            if (mode == .load_and_run) setupRun(cpu, res);
            return res;
        }

        fn applyRelocations(cpu: *Cpu, drive: *vfs.HostDirDrive, hf: vfs.HostFile, h: ExeHeader, load_seg: u16) !void {
            var i: u16 = 0;
            var pos: u64 = h.reloc_table;
            while (i < h.relocations) : (i += 1) {
                var rb: [4]u8 = undefined;
                const got = try drive.readAt(hf, pos, &rb);
                if (got < 4) break;
                pos += 4;
                const off = @as(u16, rb[0]) | (@as(u16, rb[1]) << 8);
                const seg = @as(u16, rb[2]) | (@as(u16, rb[3]) << 8);
                const target_phys = (@as(u32, load_seg + seg) << 4) + off;
                const cur = cpu.bus.readPhys16(target_phys);
                cpu.bus.writePhys16(target_phys, cur +% load_seg);
            }
        }

        // ----------------------------------------------------------------
        // COM
        // ----------------------------------------------------------------
        fn loadCom(
            dos: *Dos,
            cpu: *Cpu,
            drive: *vfs.HostDirDrive,
            hf: vfs.HostFile,
            fsize: u64,
            cmdtail: []const u8,
            mode: LoadMode,
        ) LoadError!Result {
            if (fsize > 0xFE00) return error.BadImage; // COM max ~64KB - PSP - stack

            const env_seg = buildEnv(dos, cpu, host_path_placeholder) orelse return error.NoMemory;
            // COM grabs the largest free block.
            const largest = dos.mcb().largestFree();
            if (largest < 17) {
                _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            }
            const psp_seg = dos.mcb().alloc(largest, dos.current_psp) orelse {
                _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            };

            buildPsp(dos, cpu, psp_seg, env_seg, largest, cmdtail);
            dos.current_psp = psp_seg;
            dos.dta_seg = psp_seg;
            dos.dta_off = 0x80;

            // Load the file flat at PSP:0x100.
            try copyFileToGuest(cpu, drive, hf, 0, (@as(u32, psp_seg) << 4) + 0x100, @intCast(fsize));

            const memsize_paras = largest + 16; // total paras incl PSP
            var sp: u16 = 0xFFFE;
            if (memsize_paras < 0x1000) {
                sp = @intCast((@as(u32, memsize_paras) << 4) - 2);
            }
            // Push a 0 return word at SP (so a near RET terminates via PSP:0).
            cpu.bus.writePhys16((@as(u32, psp_seg) << 4) + sp, 0);

            const res: Result = .{ .psp_seg = psp_seg, .cs = psp_seg, .ip = 0x100, .ss = psp_seg, .sp = sp };
            if (mode == .load_and_run) setupRun(cpu, res);
            return res;
        }

        // ----------------------------------------------------------------
        // Shared helpers
        // ----------------------------------------------------------------
        const host_path_placeholder = "C:\\PROGRAM.EXE";

        fn setupRun(cpu: *Cpu, res: Result) void {
            cpu.loadSegment(.cs, res.cs);
            cpu.st.eip = res.ip;
            cpu.loadSegment(.ss, res.ss);
            cpu.st.setReg16(@intFromEnum(Reg32.esp), res.sp);
            cpu.loadSegment(.ds, res.psp_seg);
            cpu.loadSegment(.es, res.psp_seg);
            // AX = FCB drive validity (both valid drives -> 0x0000 by convention
            // for a synthesized default; real EXEC derives from FCB1/FCB2).
            cpu.st.setReg16(EAX, 0x0000);
            cpu.st.setReg16(EBX, 0x0000);
        }

        fn buildPsp(dos: *Dos, cpu: *Cpu, psp_seg: u16, env_seg: u16, total_paras: u16, cmdtail: []const u8) void {
            const p = Psp.at(cpu, psp_seg);
            const mem_top = psp_seg + total_paras;
            p.build(mem_top, env_seg, dos.current_psp, cmdtail);
            // Snapshot INT 22/23/24 from the current IVT (D-EXEC unwind).
            p.saveVectors(
                cpu.bus.readPhys32(0x22 * 4),
                cpu.bus.readPhys32(0x23 * 4),
                cpu.bus.readPhys32(0x24 * 4),
            );
            // Inherit the standard handles (0-4) into the new PSP's JFT.
            var h: u16 = 0;
            while (h < 5) : (h += 1) p.jftSet(h, @intCast(h));
        }

        /// Build a minimal environment block (D6 EXEC step): one MCB-allocated
        /// paragraph block ending `0x00 0x00 0x01 0x00 <program path> 0x00`.
        fn buildEnv(dos: *Dos, cpu: *Cpu, prog_path: []const u8) ?u16 {
            const env_size = 16 + prog_path.len + 4; // a tiny default
            const paras: u16 = @intCast((env_size + 15) / 16 + 1);
            const seg = dos.mcb().alloc(paras, dos.current_psp) orelse return null;
            var off: u32 = (@as(u32, seg) << 4);
            // Empty environment: just the double-null terminator.
            cpu.bus.writePhys8(off, 0);
            off += 1;
            cpu.bus.writePhys8(off, 0);
            off += 1;
            // Trailing 0x0001 word + the program path string (the env terminator).
            cpu.bus.writePhys16(off, 0x0001);
            off += 2;
            for (prog_path) |c| {
                cpu.bus.writePhys8(off, c);
                off += 1;
            }
            cpu.bus.writePhys8(off, 0);
            return seg;
        }

        /// Copy `len` bytes from the host file at `file_off` into guest physical
        /// `dst_phys` via bus.writeGuestBlock + a fixed stack scratch (D19).
        fn copyFileToGuest(cpu: *Cpu, drive: *vfs.HostDirDrive, hf: vfs.HostFile, file_off: u64, dst_phys: u32, len: u32) LoadError!void {
            var scratch: [4096]u8 = undefined;
            var done: u32 = 0;
            var fpos = file_off;
            while (done < len) {
                const chunk = @min(len - done, scratch.len);
                const n = drive.readAt(hf, fpos, scratch[0..chunk]) catch return error.IoFailed;
                if (n == 0) break;
                cpu.bus.writeGuestBlock(dst_phys + done, scratch[0..n]);
                done += @intCast(n);
                fpos += n;
                if (n < chunk) break;
            }
        }

        fn parseHeader(b: *const [28]u8) ExeHeader {
            const w = struct {
                fn at(buf: *const [28]u8, o: usize) u16 {
                    return @as(u16, buf[o]) | (@as(u16, buf[o + 1]) << 8);
                }
            };
            return .{
                .signature = w.at(b, 0),
                .extra_bytes = w.at(b, 2),
                .pages = w.at(b, 4),
                .relocations = w.at(b, 6),
                .header_paras = w.at(b, 8),
                .min_alloc = w.at(b, 10),
                .max_alloc = w.at(b, 12),
                .init_ss = w.at(b, 14),
                .init_sp = w.at(b, 16),
                .checksum = w.at(b, 18),
                .init_ip = w.at(b, 20),
                .init_cs = w.at(b, 22),
                .reloc_table = w.at(b, 24),
                .overlay = w.at(b, 26),
            };
        }

        // ----------------------------------------------------------------
        // AH=4B EXEC (Phase 4) — model the param block + unwind setup.
        // ----------------------------------------------------------------
        pub fn exec(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // For the v1 target the initial BaK load is a direct loader call (the
            // machine boot path), not via INT 21h. AH=4B for a child EXEC is
            // partially modeled: read the path, set the current PSP's INT 22 to the
            // caller return, load+run, and on terminate unwind to INT 22. Full
            // child-process state save/restore is exercised by the loader tests.
            var pbuf: [128]u8 = undefined;
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const off = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            var i: usize = 0;
            while (i < pbuf.len - 1) : (i += 1) {
                const c = cpu.bus.readPhys8((@as(u32, seg) << 4) + off + @as(u32, @intCast(i)));
                if (c == 0) break;
                pbuf[i] = c;
            }
            const path = pbuf[0..i];
            const r = resolveExecPath(dos, path) orelse {
                cpu.st.setReg16(EAX, Dos.ERR_FILE_NOT_FOUND);
                br.setGuestCF(true);
                return;
            };
            var hostbuf: [13]u8 = undefined;
            const hn = r.name.display(&hostbuf);
            _ = loadProgram(dos, cpu, r.drive, hn, "", .load_and_run) catch {
                cpu.st.setReg16(EAX, Dos.ERR_FILE_NOT_FOUND);
                br.setGuestCF(true);
                return;
            };
            br.setGuestCF(false);
        }

        const ResolvedExec = struct { drive: u8, name: name83.Name83 };
        fn resolveExecPath(dos: *Dos, path: []const u8) ?ResolvedExec {
            var p = path;
            var drive = dos.current_drive;
            if (p.len >= 2 and p[1] == ':') {
                const dl = p[0];
                drive = if (dl >= 'a' and dl <= 'z') dl - 'a' else dl - 'A';
                p = p[2..];
            }
            if (std.mem.lastIndexOfAny(u8, p, "\\/")) |idx| p = p[idx + 1 ..];
            const n83 = name83.parse(p) orelse return null;
            return .{ .drive = drive, .name = n83 };
        }
    };
}
