//! The EXE/COM loader (Phase 6) — the path that starts a real DOS program (and,
//! for v1, Betrayal at Krondor). Parses an MZ EXE (or a flat COM), allocates via
//! MCB, builds the PSP + environment block, applies relocations, sets up registers,
//! and transfers control. The image copy + relocation reads go through
//! `bus.writeGuestBlock`/`readGuestBlock` + a fixed stack scratch (D19) — no
//! per-byte loop on the warm path. Re-derived from the documented MZ format.

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

/// Parsed AH=4B EXEC parameter block (the data at ES:BX), threaded into the
/// loader so a child inherits the caller's environment + command tail + FCBs and
/// links to the parent PSP. Absent (null) for the initial boot load, which
/// synthesizes a default env + empty tail + root parent. Re-derived from the
/// documented EXEC param-block layout + dos_execute.cpp:473-528.
pub const ExecParams = struct {
    /// Environment segment from the block (+0x00). 0 = copy the caller's env.
    env_seg: u16,
    /// Far pointer to the command tail (+0x02): { len byte, chars, 0x0D }.
    cmdtail_seg: u16,
    cmdtail_off: u16,
    /// Far pointers to the two parsed FCBs (+0x06, +0x0A) -> child PSP 0x5C/0x6C.
    fcb1_seg: u16,
    fcb1_off: u16,
    fcb2_seg: u16,
    fcb2_off: u16,
    /// The parent (caller) PSP segment -> child PSP 0x16 (parent link).
    parent_psp: u16,
};

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
            return loadProgramExec(dos, cpu, drive_idx, host_name, cmdtail, mode, null);
        }

        /// Like `loadProgram` but with the optional parsed EXEC param block (a child
        /// EXEC). `params == null` is the initial boot load (synthesized env, empty
        /// tail, root parent).
        pub fn loadProgramExec(
            dos: *Dos,
            cpu: *Cpu,
            drive_idx: u8,
            host_name: []const u8,
            cmdtail: []const u8,
            mode: LoadMode,
            params: ?ExecParams,
        ) LoadError!Result {
            const drive = dos.drivePtr(drive_idx) orelse return error.NotFound;
            const hf = drive.open(host_name, .read_only) catch return error.NotFound;
            defer drive.close(hf);

            const fsize = drive.size(hf) catch return error.IoFailed;

            // Peek the first two bytes to decide EXE vs COM (re-derived branch).
            var magic: [2]u8 = undefined;
            const got = drive.readAt(hf, 0, &magic) catch return error.IoFailed;
            const sig: u16 = if (got >= 2) (@as(u16, magic[0]) | (@as(u16, magic[1]) << 8)) else 0;

            // The canonical DOS program path (C:\<NAME>) the env block ends with —
            // the CRT derives argv[0] from it (dos_execute.cpp MakeEnv).
            var path_buf: [MAX_PROG_PATH]u8 = undefined;
            const prog_path = canonicalProgPath(drive_idx, host_name, &path_buf);

            if (sig == MZ_MAGIC1 or sig == MZ_MAGIC2) {
                return loadExe(dos, cpu, drive, hf, fsize, cmdtail, mode, prog_path, params);
            }
            return loadCom(dos, cpu, drive, hf, fsize, cmdtail, mode, prog_path, params);
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
            prog_path: []const u8,
            params: ?ExecParams,
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

            // Decide the program memory-block size exactly like real DOS EXEC
            // (dosbox-staging dos_execute.cpp:352-386):
            //   minsize = para(imagesize + min_alloc*16 + 256)   ; PSP (256B) + image + min
            //   maxsize = para(imagesize + max_alloc*16 + 256)   ; or 0xFFFF if max_alloc==0
            //   memsize = min(maxfree, maxsize), and fail if maxfree < minsize
            // The block size INCLUDES the 16-paragraph PSP; loadseg = pspseg + 16.
            // Honoring max_alloc (0xFFFF => "give me all of memory") is essential:
            // the Borland C0 startup sizes its DGROUP stack/heap against PSP[2]
            // (memtop) and aborts if the block is only `minsize` (D6).
            const minsize: u16 = long2para(load_bytes + (@as(u32, h.min_alloc) << 4) + 256);
            const maxsize: u16 = if (h.max_alloc != 0)
                long2para(load_bytes + (@as(u32, h.max_alloc) << 4) + 256)
            else
                0xFFFF;

            // The child's environment: when a param block supplies a nonzero env
            // segment (Borland's spawn builds a fresh env block holding the
            // parent's putenv'd vars), use it directly (dos_execute.cpp MakeEnv:
            // *segment != 0 path). Otherwise synthesize/copy (boot or env_seg==0).
            const owner_for_alloc = if (params) |pp| pp.parent_psp else dos.current_psp;
            const env_seg = resolveEnv(dos, cpu, prog_path, params, owner_for_alloc) orelse return error.NoMemory;
            const env_owned = envWasAllocated(params);

            const maxfree = dos.mcb().largestFree();
            if (maxfree < minsize) {
                if (env_owned) _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            }
            const want: u16 = @min(maxfree, maxsize);

            const psp_seg = dos.mcb().alloc(want, owner_for_alloc) orelse {
                // free env on failure
                if (env_owned) _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            };

            const load_seg: u16 = psp_seg + 16;

            // Copy the image (after the header) into guest RAM at load_seg:0000.
            try copyFileToGuest(cpu, drive, hf, header_bytes, (@as(u32, load_seg) << 4), load_bytes);

            // Apply relocations: each entry is offset:segment; add load_seg to the
            // word at (load_seg + entry.segment):entry.offset.
            applyRelocations(cpu, drive, hf, h, load_seg) catch return error.IoFailed;

            // Build the PSP + env + JFT inherit.
            buildPsp(cpu, psp_seg, env_seg, want, cmdtail, params);
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
            prog_path: []const u8,
            params: ?ExecParams,
        ) LoadError!Result {
            if (fsize > 0xFE00) return error.BadImage; // COM max ~64KB - PSP - stack

            const owner_for_alloc = if (params) |pp| pp.parent_psp else dos.current_psp;
            const env_seg = resolveEnv(dos, cpu, prog_path, params, owner_for_alloc) orelse return error.NoMemory;
            const env_owned = envWasAllocated(params);
            // COM grabs the largest free block.
            const largest = dos.mcb().largestFree();
            if (largest < 17) {
                if (env_owned) _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            }
            const psp_seg = dos.mcb().alloc(largest, owner_for_alloc) orelse {
                if (env_owned) _ = dos.mcb().free(env_seg);
                return error.NoMemory;
            };

            buildPsp(cpu, psp_seg, env_seg, largest, cmdtail, params);
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
        const MAX_PROG_PATH = 80;

        /// The pinned, DETERMINISTIC environment the child inherits (D13). dosbox-x
        /// seeds these on its Z: utility drive; we replicate the exact strings so a
        /// program reading PATH/COMSPEC sees stable values WITHOUT ever touching the
        /// host environment (never the host process env). Each entry is NUL-terminated; the
        /// block ends with a double-NUL, then the 0x0001 word + program path.
        const pinned_env = [_][]const u8{
            "COMSPEC=Z:\\COMMAND.COM",
            "PATH=Z:\\;Z:\\SYSTEM;Z:\\BIN;Z:\\DOS;Z:\\4DOS;Z:\\DEBUG;Z:\\TEXTUTIL",
            "PROMPT=$P$G",
        };

        /// Build the canonical DOS path `<DRIVE>:\<HOSTNAME>` (uppercased) into
        /// `buf` so the env block's trailing program-path yields a real argv[0].
        fn canonicalProgPath(drive_idx: u8, host_name: []const u8, buf: []u8) []const u8 {
            var i: usize = 0;
            buf[i] = 'A' + drive_idx;
            i += 1;
            buf[i] = ':';
            i += 1;
            buf[i] = '\\';
            i += 1;
            for (host_name) |c| {
                if (i >= buf.len - 1) break;
                buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
                i += 1;
            }
            return buf[0..i];
        }

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

        fn buildPsp(cpu: *Cpu, psp_seg: u16, env_seg: u16, total_paras: u16, cmdtail: []const u8, params: ?ExecParams) void {
            const p = Psp.at(cpu, psp_seg);
            const mem_top = psp_seg + total_paras;
            // The parent link (PSP 0x16): the caller PSP for a child EXEC, else
            // SELF (the root program self-parents, exactly like the DOS shell —
            // shell.cpp:1345 `psp.SetParent(psp_seg)`). `dos.terminate` keys "is
            // this the root?" off `parent == self`: a self-parented PSP surfaces
            // `program_terminated` to the controller (no unwind); a child PSP runs
            // the full parent unwind. (Before the nested-EXEC de-nest the root's
            // parent was the throwaway boot PSP, which `terminate` only ever
            // flagged on — the de-nest makes the parent link load-bearing.)
            const parent = if (params) |pp| pp.parent_psp else psp_seg;
            p.build(mem_top, env_seg, parent, cmdtail);
            // Snapshot INT 22/23/24 from the current IVT (dos_execute.cpp:486
            // SaveVectors) — done by the EXEC caller AFTER setting INT 22 to the
            // caller's return CS:IP, so the child's saved INT22 = parent resume.
            p.saveVectors(
                cpu.bus.readPhys32(0x22 * 4),
                cpu.bus.readPhys32(0x23 * 4),
                cpu.bus.readPhys32(0x24 * 4),
            );
            // Copy the two parsed FCBs from the EXEC param block into the child PSP
            // at 0x5C/0x6C (dos_execute.cpp:488-489 SetFCB1/SetFCB2).
            if (params) |pp| {
                copyFcb(cpu, pp.fcb1_seg, pp.fcb1_off, psp_seg, psp_mod.OFF_FCB1);
                copyFcb(cpu, pp.fcb2_seg, pp.fcb2_off, psp_seg, psp_mod.OFF_FCB2);
            }
            // Inherit the standard handles (0-4) into the new PSP's JFT.
            var h: u16 = 0;
            while (h < 5) : (h += 1) p.jftSet(h, @intCast(h));
        }

        /// Copy a 16-byte FCB (the unopened/parsed part DOS forwards) from a far
        /// source into the child PSP at `dst_off`.
        fn copyFcb(cpu: *Cpu, src_seg: u16, src_off: u16, psp_seg: u16, dst_off: u16) void {
            const src = (@as(u32, src_seg) << 4) + src_off;
            const dst = (@as(u32, psp_seg) << 4) + dst_off;
            var i: u16 = 0;
            while (i < 16) : (i += 1) cpu.bus.writePhys8(dst + i, cpu.bus.readPhys8(src + i));
        }

        /// True iff the loader (not the caller) allocated the env block — so it is
        /// freed on a load failure. The loader allocates env only when there is no
        /// param block, or the param block's env_seg is 0 (copy-the-caller case).
        fn envWasAllocated(params: ?ExecParams) bool {
            if (params) |pp| return pp.env_seg == 0;
            return true;
        }

        /// Resolve the child's environment segment. A child EXEC with a nonzero
        /// param-block env_seg uses it directly (Borland's spawn already built the
        /// block with the parent's vars — dos_execute.cpp MakeEnv *segment!=0).
        /// Otherwise the loader allocates a fresh block: copying the caller's env
        /// (env_seg==0 child case) or the pinned default (boot), then appends the
        /// 0x0001 word + the canonical program path so the CRT derives argv[0].
        fn resolveEnv(dos: *Dos, cpu: *Cpu, prog_path: []const u8, params: ?ExecParams, owner: u16) ?u16 {
            if (params) |pp| {
                if (pp.env_seg != 0) return pp.env_seg;
                // env_seg==0: copy the caller's environment block.
                return copyEnv(dos, cpu, dos.current_psp, prog_path, owner);
            }
            return buildEnv(dos, cpu, prog_path);
        }

        /// Copy the parent's environment block (the NUL-terminated var list up to
        /// the double-NUL) into a fresh MCB block owned by `owner`, then append the
        /// 0x0001 word + the program path (MakeEnv, dos_execute.cpp:180-227).
        fn copyEnv(dos: *Dos, cpu: *Cpu, parent_psp: u16, prog_path: []const u8, owner: u16) ?u16 {
            const parent_env = Psp.at(cpu, parent_psp).envSeg();
            if (parent_env == 0) return buildEnv(dos, cpu, prog_path);
            const src_base: u32 = @as(u32, parent_env) << 4;
            // Find the double-NUL that ends the var list (bounded scan).
            var vlen: u32 = 0;
            while (vlen < 0x7FFF) : (vlen += 1) {
                if (cpu.bus.readPhys8(src_base + vlen) == 0 and
                    cpu.bus.readPhys8(src_base + vlen + 1) == 0) break;
            }
            vlen += 1; // include the first NUL of the double-NUL
            const env_bytes: usize = vlen + 1 + 2 + prog_path.len + 1;
            const paras: u16 = @intCast((env_bytes + 15) / 16 + 1);
            const seg = dos.mcb().alloc(paras, owner) orelse return null;
            var off: u32 = @as(u32, seg) << 4;
            var i: u32 = 0;
            while (i < vlen) : (i += 1) {
                cpu.bus.writePhys8(off, cpu.bus.readPhys8(src_base + i));
                off += 1;
            }
            cpu.bus.writePhys8(off, 0); // second NUL of the double-NUL
            off += 1;
            cpu.bus.writePhys16(off, 0x0001);
            off += 2;
            for (prog_path) |c| {
                cpu.bus.writePhys8(off, c);
                off += 1;
            }
            cpu.bus.writePhys8(off, 0);
            return seg;
        }

        /// Build the environment block (D6 EXEC step, dos_execute.cpp MakeEnv): the
        /// pinned env vars (each NUL-terminated), a double-NUL terminator, the
        /// 0x0001 word, then the canonical program path NUL-terminated (so the CRT
        /// derives the real argv[0]). MCB-allocated; deterministic (D13).
        fn buildEnv(dos: *Dos, cpu: *Cpu, prog_path: []const u8) ?u16 {
            var env_bytes: usize = 0;
            for (pinned_env) |v| env_bytes += v.len + 1; // var + NUL
            env_bytes += 1; // the closing NUL of the double-NUL
            env_bytes += 2; // the 0x0001 word
            env_bytes += prog_path.len + 1; // program path + NUL
            const paras: u16 = @intCast((env_bytes + 15) / 16 + 1);
            const seg = dos.mcb().alloc(paras, dos.current_psp) orelse return null;
            var off: u32 = (@as(u32, seg) << 4);
            for (pinned_env) |v| {
                for (v) |c| {
                    cpu.bus.writePhys8(off, c);
                    off += 1;
                }
                cpu.bus.writePhys8(off, 0); // NUL after each var
                off += 1;
            }
            cpu.bus.writePhys8(off, 0); // the second NUL of the double-NUL
            off += 1;
            cpu.bus.writePhys16(off, 0x0001); // entry-count word
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

        /// Round a byte count up to paragraphs (16-byte units), saturating at
        /// 0xFFFF (real DOS long2para — dosbox-staging dos.h:354).
        fn long2para(bytes: u32) u16 {
            if (bytes > 0xFFFF0) return 0xFFFF;
            return @intCast(if (bytes & 0xF != 0) (bytes >> 4) + 1 else bytes >> 4);
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
        // AH=4B EXEC (Phase 3) — LOADNGO: set up the child and RETURN INTO IT.
        // ----------------------------------------------------------------
        /// The 18-byte parent register block the EXEC caller's frame pushes (real
        /// DOS reads it back in DOS_Terminate, dos_execute.cpp:149-160): AX, BX, CX,
        /// DX, SI, DI, BP (7 GP words), then DS, ES (2 segment words) = 18 bytes, in
        /// ascending stack order (AX lowest). zdos PUSHES it explicitly at EXEC time
        /// (LOCKED §3 — full fidelity, not relying on the caller having done it) and
        /// POPS it in `dos.terminate`, so the parent's registers survive the child
        /// byte-for-byte.
        pub const PARENT_REG_BLOCK_BYTES: u16 = 18;

        /// AH=4B AL=00 — LOADNGO. The faithful real-DOS / dosbox model
        /// (dos_execute.cpp:473-572): build the child PSP, save the parent resume
        /// state IN THE PSP (INT 22 + the parent SS:SP + the 18-byte register block),
        /// then RETURN INTO the child — the child runs on the ONE controller-owned
        /// step loop (NO nested host loop). `dos.terminate` is the matching unwind:
        /// on the child's AH=4C it restores the parent stack/regs and resumes the
        /// parent at INT 22. Because there is no nesting, every child instruction is
        /// visible to the debugger's between-steps scan.
        ///   (1) parse path (DS:DX) + the EXEC param block (ES:BX);
        ///   (2) set INT 22 = caller return CS:IP off the caller IRET frame, so the
        ///       child PSP's SaveVectors captures the parent resume address;
        ///   (3) push the 18-byte parent register block on the PARENT stack + save
        ///       the parent SS:SP into the PARENT PSP's saved-stack field (0x2E);
        ///   (4) load + build the child (child PSP links to the parent, inherits env);
        ///   (5) set the child SS:SP, push the child entry CS:IP, and redirect CS:IP
        ///       at the RETF stub so the trap "returns into" the child.
        pub fn exec(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            if (al != 0) {
                // AL=01 load-but-don't-run / AL=03 overlay are not in scope for the
                // child-EXEC band; flag faithfully (D11) without faking a run. (The
                // de-nest must NOT make AL=03 transfer control — it stays rejected.)
                dos.unsupported(cpu, br, 0x21);
                return;
            }

            // (1a) The program path at DS:DX (ASCIIZ).
            var pbuf: [128]u8 = undefined;
            const dseg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const doff = cpu.st.getReg16(@intFromEnum(Reg32.edx));
            var i: usize = 0;
            while (i < pbuf.len - 1) : (i += 1) {
                const c = cpu.bus.readPhys8((@as(u32, dseg) << 4) + doff + @as(u32, @intCast(i)));
                if (c == 0) break;
                pbuf[i] = c;
            }
            const path = pbuf[0..i];
            const r = resolveExecPath(dos, path) orelse {
                dos.dosError(cpu, br, Dos.ERR_FILE_NOT_FOUND);
                return;
            };

            // (1b) The EXEC param block at ES:BX (re-derived layout).
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const ebx = cpu.st.getReg16(@intFromEnum(Reg32.ebx));
            const pb: u32 = (@as(u32, eseg) << 4) + ebx;
            const params: ExecParams = .{
                .env_seg = cpu.bus.readPhys16(pb + 0x00),
                .cmdtail_off = cpu.bus.readPhys16(pb + 0x02),
                .cmdtail_seg = cpu.bus.readPhys16(pb + 0x04),
                .fcb1_off = cpu.bus.readPhys16(pb + 0x06),
                .fcb1_seg = cpu.bus.readPhys16(pb + 0x08),
                .fcb2_off = cpu.bus.readPhys16(pb + 0x0A),
                .fcb2_seg = cpu.bus.readPhys16(pb + 0x0C),
                .parent_psp = dos.current_psp,
            };

            // The child's command tail: the byte-counted string at the far ptr
            // (len byte, then chars; a trailing 0x0D follows). Copied so the loader
            // can write it into the child PSP at 0x80.
            var ctbuf: [128]u8 = undefined;
            const ct = readCmdtail(cpu, params.cmdtail_seg, params.cmdtail_off, &ctbuf);

            // (2) Set INT 22 = the caller's return CS:IP, read off the IRET frame
            // the CPU pushed for this INT 21h (IP@SS:SP, CS@SS:SP+2 —
            // interrupts.zig push order FLAGS,CS,IP). dos_execute.cpp:476 reads the
            // same words. The child PSP's SaveVectors (buildPsp) then captures this
            // as the child's INT22 = the parent resume address. Preserve the old
            // INT22 so a load failure can restore it (no child was entered).
            const old_int22 = cpu.bus.readPhys32(0x22 * 4);
            const frame_sp = cpu.st.getReg16(@intFromEnum(Reg32.esp));
            const ss = cpu.st.selector[@intFromEnum(Seg.ss)];
            const ret_ip = cpu.bus.readPhys16((@as(u32, ss) << 4) + frame_sp);
            const ret_cs = cpu.bus.readPhys16((@as(u32, ss) << 4) + frame_sp + 2);
            const caller_int22: u32 = (@as(u32, ret_cs) << 16) | ret_ip;
            cpu.bus.writePhys32(0x22 * 4, caller_int22);

            // (3) Push the 18-byte parent register block onto the PARENT stack
            // (LOCKED §3) and save the parent SS:SP into the PARENT PSP's saved-
            // stack field (0x2E) — exactly the slot `dos.terminate` restores from
            // (dos_execute.cpp:477-480 reg_sp-=18 + callpsp.SetStack). The block
            // layout (ascending from the new SP): AX,BX,CX,DX,SI,DI,BP,DS,ES. This
            // is parent state, so it MUST be written before loadProgramExec switches
            // current_psp/registers to the child. On a load failure (below) we undo
            // it by restoring the parent SP — the parent never observed the push.
            const parent_psp = dos.current_psp;
            const new_sp = frame_sp -% PARENT_REG_BLOCK_BYTES;
            const sbase: u32 = @as(u32, ss) << 4;
            cpu.bus.writePhys16(sbase + new_sp + 0, cpu.st.getReg16(@intFromEnum(Reg32.eax)));
            cpu.bus.writePhys16(sbase + new_sp + 2, cpu.st.getReg16(@intFromEnum(Reg32.ebx)));
            cpu.bus.writePhys16(sbase + new_sp + 4, cpu.st.getReg16(@intFromEnum(Reg32.ecx)));
            cpu.bus.writePhys16(sbase + new_sp + 6, cpu.st.getReg16(@intFromEnum(Reg32.edx)));
            cpu.bus.writePhys16(sbase + new_sp + 8, cpu.st.getReg16(@intFromEnum(Reg32.esi)));
            cpu.bus.writePhys16(sbase + new_sp + 10, cpu.st.getReg16(@intFromEnum(Reg32.edi)));
            cpu.bus.writePhys16(sbase + new_sp + 12, cpu.st.getReg16(@intFromEnum(Reg32.ebp)));
            cpu.bus.writePhys16(sbase + new_sp + 14, cpu.st.selector[@intFromEnum(Seg.ds)]);
            cpu.bus.writePhys16(sbase + new_sp + 16, cpu.st.selector[@intFromEnum(Seg.es)]);
            Psp.at(cpu, parent_psp).setStack(ss, new_sp);

            // (4) Load + build the child. buildPsp links it to the parent and runs
            // SaveVectors (capturing the INT22 we just set) and sets the child entry
            // CS:IP/SS:SP via setupRun. On failure: restore the parent INT22 +
            // parent SP (un-push the block) and return a faithful error WITHOUT
            // having entered any child (LOCKED — the failure path must not alter
            // parent CS:IP/SS:SP).
            var hostbuf: [13]u8 = undefined;
            const hn = r.name.display(&hostbuf);
            const res = loadProgramExec(dos, cpu, r.drive, hn, ct, .load_and_run, params) catch |e| {
                cpu.bus.writePhys32(0x22 * 4, old_int22);
                dos.current_psp = parent_psp;
                // (parent SS:SP/regs were never overwritten — loadProgramExec only
                // calls setupRun on SUCCESS; the un-pushed block bytes are dead.)
                dos.dosError(cpu, br, switch (e) {
                    error.NotFound => Dos.ERR_FILE_NOT_FOUND,
                    error.NoMemory => Dos.ERR_NOT_ENOUGH_MEM,
                    else => Dos.ERR_FILE_NOT_FOUND,
                });
                return;
            };

            // (5) Return INTO the child (dos_execute.cpp:546-572 LOADNGO). setupRun
            // already loaded the child SS:SP/CS:IP/DS/ES/AX/BX. Re-model dosbox's
            // "push CS:IP then jump to a RETF" so we resume the child via the RETF
            // stub instead of the INT 21h trap's own IRET (which would pop the
            // PARENT frame and clobber the child CS:IP). Push the child entry CS:IP
            // onto the CHILD stack (CS then IP, IP on top — real-mode far-return
            // order), then point CS:IP at the RETF stub. When this handler returns,
            // EIP is already past the trap stub; the CPU fetches the RETF, which
            // pops the child entry — the child's first instruction is the next thing
            // the controller's step loop fetches. No nested host loop.
            var csp = cpu.st.getReg16(@intFromEnum(Reg32.esp));
            csp -%= 2;
            cpu.segWrite16(.ss, csp, res.cs) catch {};
            csp -%= 2;
            cpu.segWrite16(.ss, csp, res.ip) catch {};
            cpu.st.setReg16(@intFromEnum(Reg32.esp), csp);
            const retf = @TypeOf(br.*).execRetfSegOff();
            cpu.loadSegment(.cs, retf.seg);
            cpu.st.eip = retf.off;
        }

        /// Read the byte-counted command tail at a far pointer into `buf`, returning
        /// the chars (without the length byte or the trailing CR).
        fn readCmdtail(cpu: *Cpu, seg: u16, off: u16, buf: []u8) []const u8 {
            const base: u32 = (@as(u32, seg) << 4) + off;
            const n: usize = @min(cpu.bus.readPhys8(base), @as(u8, @intCast(@min(buf.len, 126))));
            var i: usize = 0;
            while (i < n) : (i += 1) buf[i] = cpu.bus.readPhys8(base + 1 + @as(u32, @intCast(i)));
            return buf[0..i];
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
