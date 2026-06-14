//! INT 21h — the DOS kernel AH switch (D7). Each subfunction charges D5 cost
//! (base by the sink; byte-proportional added here). The default (unknown-AH) arm
//! follows D11 rule (b): AL=0 + CF CLEAR + the structural unsupported signal.

const std = @import("std");
const Seg = @import("cpu").state.Seg;
const Reg32 = @import("cpu").state.Reg32;
const vfs = @import("vfs.zig");
const name83 = @import("name83.zig");
const clock = @import("clock.zig");
const psp_mod = @import("psp.zig");
const dta_mod = @import("dta.zig");
const sft_mod = @import("sft.zig");
const mcb_mod = @import("mcb.zig");

const EAX = @intFromEnum(Reg32.eax);
const EBX = @intFromEnum(Reg32.ebx);
const ECX = @intFromEnum(Reg32.ecx);
const EDX = @intFromEnum(Reg32.edx);

pub fn Int21(comptime Cpu: type) type {
    return struct {
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        pub fn service(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const ah = cpu.st.getReg8(4);
            switch (ah) {
                // ---- Program control ----
                0x00 => dos.terminate(cpu, br, 0, 0),
                0x4C => dos.terminate(cpu, br, cpu.st.getReg8(0), 0),
                0x4D => { // get return code -> AL=code, AH=type
                    cpu.st.setReg8(0, @truncate(dos.ret_code));
                    cpu.st.setReg8(4, dos.ret_type);
                },
                0x30 => { // get DOS version -> AL=major, AH=minor, BH=OEM, BL:CX=serial
                    cpu.st.setReg8(0, Dos.DOS_VER_MAJOR);
                    cpu.st.setReg8(4, Dos.DOS_VER_MINOR);
                    cpu.st.setReg8(7, 0xFF); // BH = OEM = 0xFF
                    cpu.st.setReg8(3, 0); // BL
                    cpu.st.setReg16(ECX, 0); // CX
                },
                0x31 => dos.unsupported(cpu, br, 0x21), // TSR deferred (D11)

                // ---- Char I/O ----
                0x02 => { // output char in DL -> CON
                    dos.dev_table.con.writeByte(cpu.st.getReg8(2));
                },
                0x06 => { // direct console I/O (DL=0xFF -> input, else output)
                    const dl = cpu.st.getReg8(2);
                    if (dl == 0xFF) {
                        // dos.cpp:516 — if STDIN not ready: AL=0, ZF=1, done.
                        if (!dos.dev_table.con.stdinReady()) {
                            cpu.st.setReg8(0, 0);
                            br.setGuestZF(true);
                        } else {
                            var b: [1]u8 = undefined;
                            const n = dos.dev_table.con.read(&b);
                            cpu.st.setReg8(0, if (n == 1) b[0] else 0);
                            br.setGuestZF(false);
                        }
                    } else {
                        dos.dev_table.con.writeByte(dl);
                    }
                },
                0x07, 0x08 => { // input char without echo -> AL
                    var b: [1]u8 = undefined;
                    const n = dos.dev_table.con.read(&b);
                    cpu.st.setReg8(0, if (n == 1) b[0] else 0);
                },
                0x09 => printString(dos, cpu, br),
                0x01 => { // input char with echo -> AL
                    var b: [1]u8 = undefined;
                    const n = dos.dev_table.con.read(&b);
                    const c: u8 = if (n == 1) b[0] else 0;
                    cpu.st.setReg8(0, c);
                    dos.dev_table.con.writeByte(c);
                },
                0x0A => bufferedInput(dos, cpu, br),
                0x0B => { // get STDIN status -> AL = 0xFF ready / 0x00 not ready
                    cpu.st.setReg8(0, if (dos.dev_table.con.stdinReady()) 0xFF else 0x00);
                },
                0x0C => flushAndRead(dos, cpu, br),

                // ---- DTA + date/time ----
                0x1A => { // set DTA = DS:DX
                    dos.dta_seg = cpu.st.selector[@intFromEnum(Seg.ds)];
                    dos.dta_off = cpu.st.getReg16(EDX);
                },
                0x2F => { // get DTA -> ES:BX
                    cpu.loadSegment(.es, dos.dta_seg);
                    cpu.st.setReg16(EBX, dos.dta_off);
                },
                0x2A => getDate(dos, cpu),
                0x2C => getTime(dos, cpu),
                0x2B, 0x2D => cpu.st.setReg8(0, 0), // set date/time -> AL=0 (success)
                0x57 => getSetFileDateTime(dos, cpu, br),

                // ---- Interrupt vectors (read/write the guest-RAM IVT) ----
                0x25 => { // set vector AL -> DS:DX
                    const v = cpu.st.getReg8(0);
                    const off = cpu.st.getReg16(EDX);
                    const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
                    cpu.bus.writePhys16(@as(u32, v) * 4, off);
                    cpu.bus.writePhys16(@as(u32, v) * 4 + 2, seg);
                },
                0x35 => { // get vector AL -> ES:BX
                    const v = cpu.st.getReg8(0);
                    cpu.st.setReg16(EBX, cpu.bus.readPhys16(@as(u32, v) * 4));
                    cpu.loadSegment(.es, cpu.bus.readPhys16(@as(u32, v) * 4 + 2));
                },

                // ---- Drive ----
                0x19 => cpu.st.setReg8(0, dos.current_drive), // get current drive
                0x0E => { // select drive DL -> AL = number of drives
                    dos.current_drive = cpu.st.getReg8(2);
                    cpu.st.setReg8(0, 26);
                },

                // ---- PSP ----
                0x50 => dos.current_psp = cpu.st.getReg16(EBX), // set PSP
                0x51, 0x62 => cpu.st.setReg16(EBX, dos.current_psp), // get PSP

                // ---- File handles ----
                0x3C => createFile(dos, cpu, br),
                0x3D => openFile(dos, cpu, br),
                0x6C => extendedOpen(dos, cpu, br),
                0x3E => closeFile(dos, cpu, br),
                0x3F => readFile(dos, cpu, br),
                0x40 => writeFile(dos, cpu, br),
                0x42 => seekFile(dos, cpu, br),
                0x41 => unlinkFile(dos, cpu, br),
                0x43 => getSetAttr(dos, cpu, br),
                0x5B => createNewFile(dos, cpu, br),
                0x44 => ioctl(dos, cpu, br),
                0x56 => renameFile(dos, cpu, br),
                0x45 => dupHandle(dos, cpu, br),
                0x46 => dup2Handle(dos, cpu, br),

                // ---- Directory search ----
                0x4E => findFirst(dos, cpu, br),
                0x4F => findNext(dos, cpu, br),
                0x47 => getCwd(dos, cpu, br),
                0x3B => chdir(dos, cpu, br),
                0x39 => mkdir(dos, cpu, br),
                0x3A => rmdir(dos, cpu, br),

                // ---- CRT-startup / runtime baseline (D20) ----
                0x33 => breakCheck(dos, cpu, br),
                0x29 => parseFilename(dos, cpu, br),
                0x59 => extendedError(dos, cpu, br),
                0x52 => sysVars(dos, cpu, br),

                // ---- Disk / locale / commit (Tier-1 real-program surface) ----
                0x36 => getFreeDiskSpace(dos, cpu, br),
                0x38 => getCountryInfo(dos, cpu, br),
                0x68, 0x6A => commitFile(dos, cpu, br),

                // ---- Memory (MCB) ----
                0x48 => allocMem(dos, cpu, br),
                0x49 => freeMem(dos, cpu, br),
                0x4A => resizeMem(dos, cpu, br),
                0x58 => allocStrategy(dos, cpu, br),

                // ---- EXEC ----
                0x4B => exec(dos, cpu, br),

                else => dos.unsupported(cpu, br, 0x21),
            }
        }

        /// INT 2Fh multiplex (D18): default faithful "not installed". A program
        /// that probes (AX=xx00 -> AL=0 means "ok to install / not present") gets
        /// AL=0; we flag unhandled probes structurally without faking "installed".
        ///
        /// The XMS install-check pair (AX=4300 / AX=4310) is handled EXPLICITLY:
        /// zdos defers XMS (extended memory) entirely — BaK and our target class
        /// are plain real-mode with EMS via INT 67h, no XMS/DPMI/extender (see
        /// plans/dos-coverage-gaps.md §4). The FAITHFUL answer is therefore "no
        /// XMS driver resident", NOT a fake "installed". This mirrors dosbox-x
        /// with `xms=false`: its XMS multiplex handler (xms.cpp multiplex_xms,
        /// registered only when the `xms` config bool is true) is then absent, so
        /// AX=4300/4310 fall through INT2F_Handler (dos_misc.cpp:96) which logs
        /// "Unhandled" and returns WITHOUT touching registers — leaving AL = the
        /// low byte the caller loaded (0x00 for AX=4300), i.e. AL != 0x80 = "not
        /// installed". An XMS-aware program checks AL==0x80 and only issues
        /// AX=4310 (get entry point) when it is; on "not installed" it falls back
        /// to EMS/conventional memory and never calls 4310.
        pub fn handle2f(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            _ = dos;
            const ax = cpu.st.getReg16(EAX);
            switch (ax) {
                // XMS install check: AL != 0x80 => no XMS driver. dosbox-x with
                // xms=false leaves registers untouched (AL stays 0x00). We set AL
                // explicitly to make the "not installed" contract unmistakable;
                // we do NOT touch ES:BX (no entry point to advertise).
                0x4300 => cpu.st.setReg8(0, 0x00),
                // XMS get entry point: a correct program never reaches here after
                // a "not installed" 4300. Stay faithful to dosbox-x (xms=false):
                // leave ALL registers unchanged — do not synthesize a bogus
                // seg:offset that would point at a non-existent XMS driver.
                0x4310 => {},
                // All other multiplex calls: AL=0 ("not installed / available to
                // install") is the faithful default for an unclaimed AX.
                else => cpu.st.setReg8(0, 0),
            }
        }

        // ===================================================================
        // Char I/O helpers
        // ===================================================================
        fn printString(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            // AH=09: print the '$'-terminated string at DS:DX to CON.
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            var off = cpu.st.getReg16(EDX);
            var count: u64 = 0;
            while (count < 65536) : (count += 1) {
                const c = cpu.bus.readPhys8((@as(u32, seg) << 4) + off);
                if (c == '$') break;
                dos.dev_table.con.writeByte(c);
                off +%= 1;
            }
            cpu.st.setReg8(0, '$'); // AL = last char (DOS quirk)
        }

        /// AH=0A Buffered Input (dos.cpp:1247). DS:DX -> {max-len, count, chars...}.
        /// Read STDIN until CR (13), echoing to STDOUT; skip LF (10); handle
        /// backspace (8) non-destructively; bell (7) when the buffer is full and
        /// the byte is not CR. The CR is echoed AND stored, then `count` (byte 1)
        /// is set to the number of chars BEFORE the CR. `free` (max-len) of 0 is a
        /// no-op. On redirected EOF dosbox-x E_Exits (crash) — we instead stop
        /// deterministically (programs in this band are scripted to end with CR
        /// before EOF, so this path is not exercised by the corpus).
        fn bufferedInput(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            const con = &dos.dev_table.con;
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const data = (@as(u32, seg) << 4) + cpu.st.getReg16(EDX);
            var free = cpu.bus.readPhys8(data);
            if (free == 0) return;
            free -= 1;
            var read: u8 = 0;
            while (true) {
                var b: [1]u8 = undefined;
                if (con.read(&b) == 0) break; // EOF (dosbox E_Exits; we stop)
                const c = b[0];
                if (c == 10) continue; // LF: ignored
                if (c == 8) { // backspace: non-destructive erase if anything stored
                    if (read > 0) {
                        con.writeByte(8);
                        con.writeByte(' ');
                        con.writeByte(8);
                        read -= 1;
                    }
                    continue;
                }
                if (read == free and c != 13) { // buffer full, not CR: bell
                    con.writeByte(7);
                    continue;
                }
                con.writeByte(c);
                cpu.bus.writePhys8(data + 2 + read, c);
                if (c == 13) break;
                read += 1;
            }
            cpu.bus.writePhys8(data + 1, read);
        }

        /// AH=0C Flush Buffer and read STDIN (dos.cpp:1350). Flush pending STDIN
        /// ONLY if handle 0 is the CON device (an interactive console); a
        /// redirected stdin (LocalFile) is not named CON, so no flush. Then, if AL
        /// is one of {01,06,07,08,0A}, re-dispatch INT 21h with AH=AL; otherwise
        /// AL=0. (We model handle 0 as the CON device in either mode; `isFlushable`
        /// captures the redirected vs interactive distinction.)
        fn flushAndRead(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const con = &dos.dev_table.con;
            if (con.isFlushable()) {
                var b: [1]u8 = undefined;
                while (con.stdinReady() and con.read(&b) != 0) {}
            }
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x01, 0x06, 0x07, 0x08, 0x0A => {
                    cpu.st.setReg8(4, al); // AH = AL
                    service(dos, cpu, br); // re-dispatch
                },
                else => cpu.st.setReg8(0, 0),
            }
        }

        // ===================================================================
        // Date/time (D13 — from the emulated source, never host clock)
        // ===================================================================
        fn getDate(dos: *Dos, cpu: *Cpu) void {
            const bda_tick = cpu.bus.readPhys32(0x400 + 0x6C);
            const dt = clock.fromTicks(bda_tick);
            cpu.st.setReg16(ECX, dt.year);
            cpu.st.setReg8(2, dt.day); // DL
            cpu.st.setReg8(6, dt.month); // DH
            cpu.st.setReg8(0, dt.dow); // AL = day of week
            _ = dos;
        }
        fn getTime(dos: *Dos, cpu: *Cpu) void {
            const bda_tick = cpu.bus.readPhys32(0x400 + 0x6C);
            const dt = clock.fromTicks(bda_tick);
            cpu.st.setReg8(5, dt.hour); // CH
            cpu.st.setReg8(1, dt.minute); // CL
            cpu.st.setReg8(6, dt.second); // DH
            cpu.st.setReg8(2, 0); // DL = hundredths
            _ = dos;
        }
        /// AH=57 Get/Set File Date and Time (dos.cpp:2468 -> DOS_GetFileDate /
        /// DOS_SetFileDate, dos_files.cpp:2265/2290). BX = file handle.
        ///   AL=00 GET -> CX = packed time, DX = packed date.
        ///   AL=01 SET <- CX = packed time, DX = packed date.
        /// Both VALIDATE the handle and return invalid-handle (CF=1, AX=6) on a
        /// bad/closed handle (DOSERR_INVALID_HANDLE). DETERMINISM (band 9): dosbox-x
        /// derives the GET words from the HOST file's modification timestamp on
        /// every call (fstat in UpdateDateTimeFromHost) — non-deterministic and NOT
        /// oracle-able;
        /// zdos instead keeps the words IN the SFT (seeded from the pinned epoch at
        /// open, overwritten by SET), so SET-then-GET round-trips byte-identically
        /// every run. A device handle (CON/AUX/PRN) has no timestamp; real DOS
        /// returns garbage there — we report the epoch deterministically.
        fn getSetFileDateTime(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            const handle = cpu.st.getReg16(EBX);
            const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            switch (e.ref) {
                .device => {
                    if (al == 0) {
                        cpu.st.setReg16(ECX, clock.fileTime());
                        cpu.st.setReg16(EDX, clock.fileDate());
                    }
                    br.setGuestCF(false);
                },
                .file => {
                    if (al == 0) { // GET -> CX=time, DX=date from the SFT
                        cpu.st.setReg16(ECX, e.f_time);
                        cpu.st.setReg16(EDX, e.f_date);
                    } else { // SET <- CX=time, DX=date (stored in the SFT)
                        e.f_time = cpu.st.getReg16(ECX);
                        e.f_date = cpu.st.getReg16(EDX);
                        e.time_set = true;
                    }
                    br.setGuestCF(false);
                },
            }
        }

        // ===================================================================
        // Path resolution
        // ===================================================================
        /// Read an ASCIIZ path at DS:DX into `out`; returns the slice.
        fn readPath(cpu: *Cpu, out: []u8) []u8 {
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const off = cpu.st.getReg16(EDX);
            var i: usize = 0;
            while (i < out.len - 1) : (i += 1) {
                const c = cpu.bus.readPhys8((@as(u32, seg) << 4) + off + @as(u32, @intCast(i)));
                if (c == 0) break;
                out[i] = c;
            }
            return out[0..i];
        }

        /// Resolve a DOS path to (drive index, DOS-relative path). Strips a drive
        /// prefix; the remaining path (which MAY contain subdirectory components,
        /// D8b) is combined with the per-drive current directory when relative and
        /// handed to the VFS, which walks it against the host tree. `path_buf`
        /// receives the joined DOS-relative path. Returns null on a bad path.
        const Resolved = struct { drive: u8, path: []const u8 };
        fn resolve(dos: *Dos, path: []const u8, path_buf: []u8) ?Resolved {
            var p = path;
            var drive = dos.current_drive;
            if (p.len >= 2 and p[1] == ':') {
                const dl = p[0];
                drive = if (dl >= 'a' and dl <= 'z') dl - 'a' else if (dl >= 'A' and dl <= 'Z') dl - 'A' else return null;
                p = p[2..];
            }
            if (p.len == 0) return null;

            // Build the un-normalized DOS-relative path: an absolute path (leading
            // separator) ignores the CWD; a relative path is prefixed by the
            // per-drive current directory. Then canonicalize `.`/`..` away so the
            // VFS only ever sees a clean root-relative path — mirroring
            // dos_files.cpp:256-363 `DOS_MakeName`, which collapses `.`/`..`
            // against `curdir` and clamps `..` at the drive root (never errors).
            var jbuf: [256]u8 = undefined;
            var jlen: usize = 0;
            if (p[0] != '\\' and p[0] != '/') {
                const cwd = dos.cwdOf(drive);
                if (cwd.len != 0) {
                    if (cwd.len + 1 > jbuf.len) return null;
                    @memcpy(jbuf[0..cwd.len], cwd);
                    jbuf[cwd.len] = '\\';
                    jlen = cwd.len + 1;
                }
            } else {
                p = p[1..]; // drop the leading separator (path is from root)
            }
            if (jlen + p.len > jbuf.len) return null;
            @memcpy(jbuf[jlen..][0..p.len], p);
            jlen += p.len;

            const norm = normalizePath(jbuf[0..jlen], path_buf) orelse return null;
            return .{ .drive = drive, .path = norm };
        }

        /// Canonicalize a DOS-relative path (no drive, '\' or '/' separators) by
        /// collapsing `.` (current) and `..` (parent) components, writing the
        /// cleaned root-relative path (no leading separator, '\' separators) into
        /// `out`. `..` at the root is clamped (stays at root), matching
        /// `DOS_MakeName`. Returns the slice into `out`, or null if it overflows.
        fn normalizePath(in: []const u8, out: []u8) ?[]const u8 {
            var written: usize = 0; // length of the canonical path so far
            var it = std.mem.tokenizeAny(u8, in, "\\/");
            while (it.next()) |comp| {
                if (comp.len == 0) continue;
                if (std.mem.eql(u8, comp, ".")) continue;
                if (std.mem.eql(u8, comp, "..")) {
                    // Drop the last component (clamp at root).
                    if (std.mem.lastIndexOfScalar(u8, out[0..written], '\\')) |i| {
                        written = i;
                    } else {
                        written = 0;
                    }
                    continue;
                }
                if (written != 0) {
                    if (written + 1 > out.len) return null;
                    out[written] = '\\';
                    written += 1;
                }
                if (written + comp.len > out.len) return null;
                @memcpy(out[written..][0..comp.len], comp);
                written += comp.len;
            }
            return out[0..written];
        }

        // ===================================================================
        // File handles
        // ===================================================================
        fn openFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            const al = cpu.st.getReg8(0);
            const mode: vfs.OpenMode = switch (al & 0x07) {
                0 => .read_only,
                1 => .write_only,
                else => .read_write,
            };

            // D17: resolve the device table BEFORE the VFS.
            if (dos.dev_table.resolve(path)) |dev| {
                openDeviceHandle(dos, cpu, br, dev, mode);
                return;
            }

            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const hf = drive.open(r.path, mode) catch |e| {
                return dos.dosError(cpu, br, vfsErrToDos(e));
            };
            finishFileOpen(dos, cpu, br, hf, r, mode);
        }

        fn createFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            if (dos.dev_table.resolve(path)) |dev| {
                openDeviceHandle(dos, cpu, br, dev, .write_only);
                return;
            }
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const hf = drive.create(r.path) catch |e| {
                return dos.dosError(cpu, br, vfsErrToDos(e));
            };
            finishFileOpen(dos, cpu, br, hf, r, .read_write);
        }

        fn finishFileOpen(dos: *Dos, cpu: *Cpu, br: *Bridge, hf: vfs.HostFile, r: Resolved, mode: vfs.OpenMode) void {
            const slot = dos.sft.allocSlot() orelse {
                dos.drivePtr(r.drive).?.close(hf);
                return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            };
            const e = dos.sft.get(slot);
            e.* = .{ .in_use = true, .ref = .{ .file = hf }, .position = 0, .mode = mode, .refcount = 1, .drive = r.drive };
            e.setPath(r.path);
            // Seed the AH=57 file date/time from the pinned epoch (D13), NOT the
            // host file's modification timestamp: zdos's GET is deterministic, and
            // a later SET (AH=57 AL=01) overwrites these for a round-trip.
            e.f_time = clock.fileTime();
            e.f_date = clock.fileDate();
            // Snapshot integrity (D14): record length + a content hash.
            if (dos.drivePtr(r.drive).?.size(hf)) |sz| {
                e.snap_len = sz;
            } else |_| {}
            const handle = dos.psp().jftAlloc(slot) orelse {
                dos.sft.freeSlot(slot);
                dos.drivePtr(r.drive).?.close(hf);
                return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            };
            cpu.st.setReg16(EAX, handle);
            br.setGuestCF(false);
        }

        fn openDeviceHandle(dos: *Dos, cpu: *Cpu, br: *Bridge, dev: anytype, mode: vfs.OpenMode) void {
            const slot = dos.sft.allocSlot() orelse return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            const e = dos.sft.get(slot);
            e.* = .{ .in_use = true, .ref = .{ .device = dev }, .mode = mode, .refcount = 1 };
            const handle = dos.psp().jftAlloc(slot) orelse {
                dos.sft.freeSlot(slot);
                return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            };
            cpu.st.setReg16(EAX, handle);
            br.setGuestCF(false);
        }

        /// Resolve a guest handle -> SFT entry (via the PSP JFT). null on invalid.
        fn sftFor(dos: *Dos, handle: u16) ?*sft_mod.SftEntry {
            const idx = dos.psp().jftGet(handle);
            if (idx == psp_mod.JFT_FREE) return null;
            const e = dos.sft.get(idx);
            if (!e.in_use) return null;
            return e;
        }

        fn closeFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg16(EBX);
            const idx = dos.psp().jftGet(handle);
            if (idx == psp_mod.JFT_FREE) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const e = dos.sft.get(idx);
            if (!e.in_use) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            // Free this guest handle. If other handles still alias this SFT entry
            // (dup/dup2 bumped refcount), keep the underlying file open (D20).
            dos.psp().jftFree(handle);
            if (e.refcount > 1) {
                e.refcount -= 1;
                br.setGuestCF(false);
                return;
            }
            switch (e.ref) {
                .file => |hf| {
                    if (dos.drivePtr(e.drive)) |d| d.close(hf);
                },
                .device => {}, // devices stay open (CON/AUX/PRN are persistent)
            }
            // Only free the SFT slot for real files (not the shared device slots).
            if (e.ref == .file) dos.sft.freeSlot(idx);
            br.setGuestCF(false);
        }

        fn readFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg16(EBX);
            const count = cpu.st.getReg16(ECX);
            const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const off = cpu.st.getReg16(EDX);
            const dst_phys = (@as(u32, seg) << 4) + off;
            var scratch: [512]u8 = undefined;
            var done: u32 = 0;
            switch (e.ref) {
                .device => |dev| {
                    while (done < count) {
                        const chunk = @min(@as(u32, count) - done, scratch.len);
                        const n = dev.read(scratch[0..chunk]);
                        if (n == 0) break;
                        cpu.bus.writeGuestBlock(dst_phys + done, scratch[0..n]);
                        done += @intCast(n);
                        if (n < chunk) break;
                    }
                },
                .file => |hf| {
                    const drive = dos.drivePtr(e.drive) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    while (done < count) {
                        const chunk = @min(@as(u32, count) - done, scratch.len);
                        const n = drive.readAt(hf, e.position, scratch[0..chunk]) catch return dos.dosError(cpu, br, Dos.ERR_ACCESS_DENIED);
                        if (n == 0) break;
                        cpu.bus.writeGuestBlock(dst_phys + done, scratch[0..n]);
                        e.position += n;
                        done += @intCast(n);
                        if (n < chunk) break;
                    }
                },
            }
            br.chargeWork(done, 1); // D5 work-proportional cost (per byte)
            cpu.st.setReg16(EAX, @intCast(done));
            br.setGuestCF(false);
        }

        fn writeFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg16(EBX);
            const count = cpu.st.getReg16(ECX);
            const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const off = cpu.st.getReg16(EDX);
            const src_phys = (@as(u32, seg) << 4) + off;
            var scratch: [512]u8 = undefined;
            var done: u32 = 0;
            switch (e.ref) {
                .device => |dev| {
                    while (done < count) {
                        const chunk = @min(@as(u32, count) - done, scratch.len);
                        cpu.bus.readGuestBlock(src_phys + done, scratch[0..chunk]);
                        _ = dev.write(scratch[0..chunk]);
                        done += chunk;
                    }
                },
                .file => |hf| {
                    // Access-mode enforcement (drive_local.cpp:2819 LocalFile::Write):
                    // a file opened OPEN_READ (read-only access mode, AH=3D/6C BX
                    // low bits = 0) rejects ANY write with DOSERR_ACCESS_DENIED (5)
                    // — the live check in dosbox-x is at the file-object level (the
                    // DTA-layer check in DOS_WriteFile is commented out,
                    // dos_files.cpp:858). The per-FILE read-only ATTRIBUTE is a
                    // different thing and is NOT enforced on open (band 11); this is
                    // the open ACCESS MODE and IS enforced (band 12).
                    if (e.mode == .read_only) return dos.dosError(cpu, br, Dos.ERR_ACCESS_DENIED);
                    const drive = dos.drivePtr(e.drive) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    while (done < count) {
                        const chunk = @min(@as(u32, count) - done, scratch.len);
                        cpu.bus.readGuestBlock(src_phys + done, scratch[0..chunk]);
                        const n = drive.writeAt(hf, e.position, scratch[0..chunk]) catch return dos.dosError(cpu, br, Dos.ERR_ACCESS_DENIED);
                        e.position += n;
                        done += @intCast(n);
                        if (n < chunk) break;
                    }
                },
            }
            br.chargeWork(done, 1);
            cpu.st.setReg16(EAX, @intCast(done));
            br.setGuestCF(false);
        }

        fn seekFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg16(EBX);
            const whence = cpu.st.getReg8(0); // AL: 0=SET,1=CUR,2=END
            const offset: u32 = (@as(u32, cpu.st.getReg16(ECX)) << 16) | cpu.st.getReg16(EDX);
            const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const ioff: i64 = @as(i32, @bitCast(offset));
            var newpos: i64 = undefined;
            switch (whence) {
                0 => newpos = ioff,
                1 => newpos = @as(i64, @intCast(e.position)) + ioff,
                2 => {
                    var end: u64 = 0;
                    if (e.ref == .file) {
                        if (dos.drivePtr(e.drive)) |d| {
                            end = d.size(e.ref.file) catch 0;
                        }
                    }
                    newpos = @as(i64, @intCast(end)) + ioff;
                },
                else => return dos.dosError(cpu, br, Dos.ERR_INVALID_FUNC),
            }
            if (newpos < 0) newpos = 0;
            e.position = @intCast(newpos);
            cpu.st.setReg16(EDX, @truncate(@as(u32, @intCast(e.position)) >> 16));
            cpu.st.setReg16(EAX, @truncate(@as(u32, @intCast(e.position))));
            br.setGuestCF(false);
        }

        fn unlinkFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            drive.unlink(r.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
            br.setGuestCF(false);
        }

        fn renameFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // DS:DX = old, ES:DI = new.
            var ob: [128]u8 = undefined;
            const old = readPath(cpu, &ob);
            var nb: [128]u8 = undefined;
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const edi = cpu.st.getReg16(@intFromEnum(Reg32.edi));
            var i: usize = 0;
            while (i < nb.len - 1) : (i += 1) {
                const c = cpu.bus.readPhys8((@as(u32, eseg) << 4) + edi + @as(u32, @intCast(i)));
                if (c == 0) break;
                nb[i] = c;
            }
            const new = nb[0..i];
            var orbuf: [128]u8 = undefined;
            var nrbuf: [128]u8 = undefined;
            const ro = resolve(dos, old, &orbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const rn = resolve(dos, new, &nrbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(ro.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            drive.rename(ro.path, rn.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
            br.setGuestCF(false);
        }

        /// AH=43 Get/Set File Attributes (dos.cpp:2212).
        ///   AL=00 GET -> CX = attr, AX = attr (undocumented), CF clear; on a
        ///               missing file CF set, AX = errorcode (dos.cpp:2219).
        ///   AL=01 SET <- CX = attr; AX = 0x0202 ("ax destroyed"), CF clear; on a
        ///               missing file CF set, AX = errorcode (dos.cpp:2229).
        /// The attribute bits returned for a local-drive file come from the inode
        /// (ARCHIVE, plus READ_ONLY iff the host file is not owner-writable —
        /// drive_local.cpp:2070) MERGED with any prior AH=43 SET (vfs stores the
        /// set attribute rather than chmod-ing the host file; see vfs.zig
        /// AttrOverride for why). A subfunction other than 00/01 returns AX=1, CF
        /// set (dos.cpp:2238).
        fn getSetAttr(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            if (al != 0 and al != 1) { // illegal subfunction (dos.cpp:2238)
                cpu.st.setReg16(EAX, 1);
                return br.setGuestCF(true);
            }
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            if (al == 0) { // GET
                const st = drive.stat(r.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
                cpu.st.setReg16(ECX, st.attr);
                cpu.st.setReg16(EAX, st.attr); // undocumented: AX = attr (dos.cpp:2221)
                br.setGuestCF(false);
            } else { // SET (al == 1)
                const attr: u8 = @truncate(cpu.st.getReg16(ECX));
                drive.setAttr(r.path, attr) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
                cpu.st.setReg16(EAX, 0x0202); // "ax destroyed" (dos.cpp:2231)
                br.setGuestCF(false);
            }
        }

        /// AH=5B Create New File / exclusive create (dos.cpp:2550). DS:DX -> name,
        /// CX = attributes. Fails with DOSERR_FILE_ALREADY_EXISTS (80) if the name
        /// already exists; otherwise creates + truncates and returns the handle in
        /// AX (CF clear). Contrast AH=3C (create-or-truncate), which never fails on
        /// an existing name. dosbox-x implements the "exists?" probe as a read open
        /// + close; zdos's vfs.createNew does the same existence check.
        fn createNewFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            // A device name (CON/AUX/PRN) cannot be exclusively created; dosbox-x
            // routes AH=5B through DOS_CreateFile which would open the device — but
            // the corpus never exclusively-creates a device, so resolve the VFS.
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const hf = drive.createNew(r.path) catch |e| switch (e) {
                error.AlreadyExists => return dos.dosError(cpu, br, Dos.ERR_FILE_EXISTS),
                else => return dos.dosError(cpu, br, vfsErrToDos(e)),
            };
            finishFileOpen(dos, cpu, br, hf, r, .read_write);
        }

        /// AH=6C Extended Open/Create (dos.cpp:3002 -> DOS_OpenFileExtended,
        /// dos_files.cpp:1138). The combined open-or-create call that well-written
        /// DOS apps use. Register frame (note: the filename is at DS:SI, NOT DS:DX):
        ///   BX = open mode (access bits 0-2 + sharing/inheritance bits)
        ///   CX = create attributes (for the create path)
        ///   DX = action: low nibble (if-exists) 0=fail / 1=open / 2=replace;
        ///                high nibble (if-not-exists) 0x00=fail / 0x10=create
        /// On success: CF clear, AX = handle, CX = action TAKEN (1=opened,
        /// 2=created, 3=replaced/truncated). On failure: CF set, AX = error.
        ///
        /// Semantics mirror DOS_OpenFileExtended exactly:
        ///   - action==0 -> DOSERR_FUNCTION_NUMBER_INVALID (1).
        ///   - (action&0x0f)>2 or (action&0xf0)>0x10 -> invalid (1).
        ///   - file EXISTS: low nibble 0 -> FILE_ALREADY_EXISTS (80);
        ///                  1 -> open it, taken=1; 2 -> close+recreate, taken=3.
        ///   - file ABSENT: high nibble 0 -> error from the failed open;
        ///                  0x10 -> create it, taken=2.
        fn extendedOpen(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const bx = cpu.st.getReg16(EBX);
            const action = cpu.st.getReg16(EDX);

            // Validate the action parameter (dos_files.cpp:1143-1153).
            if (action == 0 or (action & 0x0f) > 2 or (action & 0xf0) > 0x10) {
                return dos.dosError(cpu, br, Dos.ERR_INVALID_FUNC);
            }

            // Read the ASCIIZ filename from DS:SI (NOT DS:DX — dos.cpp:3003).
            var pbuf: [128]u8 = undefined;
            const path = readPathDsSi(cpu, &pbuf);
            const mode: vfs.OpenMode = switch (bx & 0x07) {
                0 => .read_only,
                1 => .write_only,
                else => .read_write,
            };

            // A device name routes through the open path (dosbox-x calls
            // DOS_OpenFile, which resolves the device table first, D17). A device
            // always "exists"; the corpus never extended-opens a device, but stay
            // faithful: open it and report taken=1 for action low nibble 1.
            if (dos.dev_table.resolve(path)) |dev| {
                if ((action & 0x0f) == 0) return dos.dosError(cpu, br, Dos.ERR_FILE_EXISTS);
                openDeviceHandle(dos, cpu, br, dev, mode);
                if (!br.guestCF()) cpu.st.setReg16(ECX, if ((action & 0x0f) == 2) 3 else 1);
                return;
            }

            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);

            // Existence is probed exactly like DOS_OpenFileExtended: try the open
            // first (dos_files.cpp:1154). A successful open means the file exists.
            if (drive.open(r.path, mode)) |hf| {
                switch (action & 0x0f) {
                    0x00 => { // fail if exists
                        drive.close(hf);
                        return dos.dosError(cpu, br, Dos.ERR_FILE_EXISTS);
                    },
                    0x01 => { // open the existing file, taken = 1
                        finishExtendedOpen(dos, cpu, br, hf, r, mode, 1);
                    },
                    0x02 => { // replace: close + recreate (truncate), taken = 3
                        drive.close(hf);
                        const nf = drive.create(r.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
                        finishExtendedOpen(dos, cpu, br, nf, r, mode, 3);
                    },
                    else => unreachable, // validated above
                }
            } else |e| switch (e) {
                error.NotFound => {
                    // File doesn't exist (dos_files.cpp:1173).
                    if ((action & 0xf0) == 0) {
                        // if-not-exists = fail: return the open's error code.
                        return dos.dosError(cpu, br, Dos.ERR_FILE_NOT_FOUND);
                    }
                    // Create it, taken = 2.
                    const nf = drive.create(r.path) catch |ce| return dos.dosError(cpu, br, vfsErrToDos(ce));
                    finishExtendedOpen(dos, cpu, br, nf, r, mode, 2);
                },
                else => return dos.dosError(cpu, br, vfsErrToDos(e)),
            }
        }

        /// Finish an AH=6C open: build the SFT/JFT entry exactly like
        /// finishFileOpen, then set CX = the action taken (the AH=6C-specific
        /// return). On a slot/JFT overflow finishFileOpen sets CF + AX and CX is
        /// left as the caller's input (the open failed), matching dosbox-x (it
        /// only writes *status on success).
        fn finishExtendedOpen(dos: *Dos, cpu: *Cpu, br: *Bridge, hf: vfs.HostFile, r: Resolved, mode: vfs.OpenMode, taken: u16) void {
            finishFileOpen(dos, cpu, br, hf, r, mode);
            if (!br.guestCF()) cpu.st.setReg16(ECX, taken);
        }

        /// Read an ASCIIZ path at DS:SI into `out`; returns the slice. (AH=6C
        /// passes the name at DS:SI, unlike most file calls which use DS:DX.)
        fn readPathDsSi(cpu: *Cpu, out: []u8) []u8 {
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const off = cpu.st.getReg16(@intFromEnum(Reg32.esi));
            var i: usize = 0;
            while (i < out.len - 1) : (i += 1) {
                const c = cpu.bus.readPhys8((@as(u32, seg) << 4) + off + @as(u32, @intCast(i)));
                if (c == 0) break;
                out[i] = c;
            }
            return out[0..i];
        }

        fn ioctl(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // DOS_IOCTL (dos.cpp:1138). AL selects the subfunction; BX = handle.
            const al = cpu.st.getReg8(0);
            switch (al) {
                0x00 => { // get device info -> DX
                    const handle = cpu.st.getReg16(EBX);
                    const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    switch (e.ref) {
                        .device => |dev| cpu.st.setReg16(EDX, dev.infoWord()),
                        .file => cpu.st.setReg16(EDX, @as(u16, e.drive)), // bit 7 clear = file
                    }
                    br.setGuestCF(false);
                },
                0x01 => { // set device info from DX (only the low byte is settable)
                    const handle = cpu.st.getReg16(EBX);
                    _ = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    // The device-info word is a property of the device model; we
                    // accept the call (no host effect) — faithful for CON/AUX/PRN.
                    br.setGuestCF(false);
                },
                0x06 => { // get input status -> AL=0xFF ready / 0x00 (file at EOF)
                    const handle = cpu.st.getReg16(EBX);
                    const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    const ready: u8 = switch (e.ref) {
                        .device => 0xFF, // a character device is always input-ready
                        .file => |hf| blk: {
                            const d = dos.drivePtr(e.drive) orelse break :blk 0x00;
                            const sz = d.size(hf) catch 0;
                            break :blk if (e.position < sz) 0xFF else 0x00; // 0 at EOF
                        },
                    };
                    cpu.st.setReg8(0, ready);
                    br.setGuestCF(false);
                },
                0x07 => { // get output status -> AL=0xFF ready (always, for our sinks)
                    const handle = cpu.st.getReg16(EBX);
                    _ = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
                    cpu.st.setReg8(0, 0xFF);
                    br.setGuestCF(false);
                },
                else => dos.unsupported(cpu, br, 0x21),
            }
        }

        fn getCwd(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // AH=47: DS:SI gets the ASCIIZ current dir (no drive, no leading '\').
            // DL = drive (0=default, 1='A'). dos.cpp:1163.
            const dl = cpu.st.getReg8(2);
            const drive: u8 = if (dl == 0) dos.current_drive else dl - 1;
            if (dos.drivePtr(drive) == null) return dos.dosError(cpu, br, Dos.ERR_INVALID_DRIVE);
            const cwd = dos.cwdOf(drive);
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
            const base = (@as(u32, seg) << 4) + si;
            for (cwd, 0..) |c, i| cpu.bus.writePhys8(base + @as(u32, @intCast(i)), c);
            cpu.bus.writePhys8(base + @as(u32, @intCast(cwd.len)), 0); // ASCIIZ
            cpu.st.setReg16(EAX, 0x0100);
            br.setGuestCF(false);
        }

        fn chdir(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // AH=3B: validate the target dir against the VFS + set the per-drive
            // current directory. dos.cpp:1007.
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            if (!drive.dirExists(r.path)) return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            if (!dos.setCwd(r.drive, r.path)) return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            cpu.st.setReg16(EAX, 0);
            br.setGuestCF(false);
        }

        fn mkdir(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            drive.mkdir(r.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
            cpu.st.setReg16(EAX, 5);
            br.setGuestCF(false);
        }

        fn rmdir(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            drive.rmdir(r.path) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
            cpu.st.setReg16(EAX, 5);
            br.setGuestCF(false);
        }

        // ===================================================================
        // Disk free space / country info / commit (Tier-1 real-program surface)
        // ===================================================================

        /// AH=36 Get Free Disk Space (dos.cpp:920). For a present drive returns the
        /// deterministic synthetic geometry dosbox-x reports for a mounted local
        /// drive: AX=sectors/cluster, BX=free clusters, CX=bytes/sector,
        /// DX=total clusters. These are FIXED constants (not host statvfs) so the
        /// report is reproducible on both sides — verified byte-identical across
        /// three dosbox-x mints (the DISKFREE golden). An invalid drive returns
        /// AX=0xFFFF (dos.cpp:945), never CF.
        fn getFreeDiskSpace(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            const dl = cpu.st.getReg8(2);
            const drive: u8 = if (dl == 0) dos.current_drive else dl - 1;
            if (dos.drivePtr(drive) == null) {
                cpu.st.setReg16(EAX, 0xFFFF); // invalid drive (dos.cpp:945)
                return;
            }
            cpu.st.setReg16(EAX, 64); // sectors per cluster
            cpu.st.setReg16(EBX, 61440); // free clusters
            cpu.st.setReg16(ECX, 512); // bytes per sector
            cpu.st.setReg16(EDX, 65535); // total clusters
        }

        /// AH=38 Get Country Info (dos.cpp:963, DX != 0xFFFF). Writes the 0x18-byte
        /// country block to DS:DX, sets BX=country number, AH=0, AL=BL, CF clear.
        /// The block is the fixed US (country 1) layout dosbox-x reports — a DOS
        /// constant table, not host locale (deterministic). Bytes are exactly the
        /// COUNTRY golden: "$" currency, ',' thousands, '.' decimal, '/' date sep,
        /// ':' time sep, 2 currency digits, ',' data list separator. The casemap
        /// far-pointer field (offset 0x12) is zeroed (deterministic; programs that
        /// need real case mapping are out of band).
        fn getCountryInfo(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = dos;
            const dx = cpu.st.getReg16(EDX);
            if (dx == 0xFFFF) {
                // Set-country: accept current (US) only; AX=0, CF clear.
                cpu.st.setReg16(EAX, 0);
                br.setGuestCF(false);
                return;
            }
            // 0x18-byte country block (US / country 1), matching the dosbox-x golden.
            const country = [_]u8{
                0x00, 0x00, // date format (0 = USA m-d-y)
                0x24, 0x00, 0x00, 0x00, 0x00, // currency string "$"
                0x2C, 0x00, // thousands separator ","
                0x2E, 0x00, // decimal separator "."
                0x2F, 0x00, // date separator "/"
                0x3A, 0x00, // time separator ":"
                0x00, // currency format
                0x02, // digits after decimal
                0x00, // time format (0 = 12-hour)
                0x00, 0x00, 0x00, 0x00, // casemap far pointer (deterministic 0)
                0x2C, 0x00, // data-list separator ","
            };
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const base = (@as(u32, seg) << 4) + dx;
            for (country, 0..) |b, i| cpu.bus.writePhys8(base + @as(u32, @intCast(i)), b);
            cpu.st.setReg16(EBX, 1); // country number = 1 (USA)
            cpu.st.setReg8(0, 1); // AL = BL
            cpu.st.setReg8(4, 0); // AH = 0
            br.setGuestCF(false);
        }

        /// AH=68/6A Commit File / FFLUSH (dos.cpp:1554). BL = handle. zdos's VFS
        /// writes through to the host file with no DOS-level buffering (writeAt
        /// seeks + writes immediately), so a commit is a faithful no-op-success on
        /// a valid handle; an invalid handle returns CF=1/AX=6. On success real DOS
        /// sets AH=0x68 (dos.cpp:1557).
        fn commitFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg8(3); // BL
            const e = sftFor(dos, handle) orelse return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            _ = e;
            cpu.st.setReg8(4, 0x68); // AH = 0x68 (dos.cpp:1557)
            br.setGuestCF(false);
        }

        // ===================================================================
        // CRT-startup / runtime baseline (D20)
        // ===================================================================

        /// AH=33 extended break checking (dos.cpp:881-910).
        fn breakCheck(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            switch (cpu.st.getReg8(0)) {
                0 => cpu.st.setReg8(2, @intFromBool(dos.breakcheck)), // get -> DL
                1 => dos.breakcheck = cpu.st.getReg8(2) > 0, // set from DL
                2 => { // get + set
                    const old = dos.breakcheck;
                    dos.breakcheck = cpu.st.getReg8(2) > 0;
                    cpu.st.setReg8(2, @intFromBool(old));
                },
                5 => cpu.st.setReg8(2, 3), // boot drive -> DL=3 ('C:')
                6 => { // true version: BL=major, BH=minor, DL=revision, DH=0x10
                    cpu.st.setReg8(3, Dos.DOS_VER_MAJOR); // BL
                    cpu.st.setReg8(7, Dos.DOS_VER_MINOR); // BH
                    cpu.st.setReg8(2, 0); // DL revision
                    cpu.st.setReg8(6, 0x10); // DH = DOS in HMA
                },
                else => cpu.st.setReg8(0, 0xFF), // weird subfunc -> AL=0xFF
            }
        }

        /// AH=59 get extended error info (dos.cpp:1337). Returns last_error in AX.
        fn extendedError(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            cpu.st.setReg16(EAX, dos.last_error);
            const cls: u8 = if (dos.last_error == Dos.ERR_FILE_NOT_FOUND or
                dos.last_error == Dos.ERR_PATH_NOT_FOUND) 8 else 0;
            cpu.st.setReg8(7, cls); // BH = error class
            cpu.st.setReg8(3, 1); // BL = action (retry)
            cpu.st.setReg8(5, 0); // CH = locus
            br.setGuestCF(false); // undocumented: CF not set
        }

        /// AH=52 Get List of Lists / SysVars (dos.cpp:1256). ES:BX -> SysVars; the
        /// first-MCB anchor (offset -2 / +0x00) points at the real arena MCB (D9).
        /// Offset within the SysVars block that AH=52 returns in BX. The first-MCB
        /// segment anchor lives at [block:LOL_OFF-2] (the documented -2 field).
        pub const sysvars_lol_off: u16 = 0x26;

        fn sysVars(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = br;
            const sv = dos.sysvars_seg;
            cpu.loadSegment(.es, sv);
            // The documented "List of Lists" pointer points into the block, so
            // [ES:BX-2] is the first-MCB segment (the real arena anchor, D9).
            cpu.st.setReg16(EBX, sysvars_lol_off);
        }

        /// AH=29 parse filename into FCB (dos.cpp:743). DS:SI -> source string,
        /// ES:DI -> destination FCB. AL = parse-control bits. Returns AL = parse
        /// result (0 = no wildcards, 1 = wildcards present, 0xFF = bad drive) and
        /// advances SI past the parsed name. Re-derived from the documented rules.
        fn parseFilename(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            _ = dos;
            _ = br;
            const ctrl = cpu.st.getReg8(0);
            const dseg = cpu.st.selector[@intFromEnum(Seg.ds)];
            var si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
            const eseg = cpu.st.selector[@intFromEnum(Seg.es)];
            const di = cpu.st.getReg16(@intFromEnum(Reg32.edi));
            const sbase = @as(u32, dseg) << 4;
            const dbase = (@as(u32, eseg) << 4) + di;

            const rd = struct {
                fn at(c: *Cpu, b: u32, o: u16) u8 {
                    return c.bus.readPhys8(b + o);
                }
            };

            // Skip leading whitespace (the documented behavior regardless of the
            // bit-0 "scan-off separators" control flag).
            while (true) {
                const c = rd.at(cpu, sbase, si);
                if (c == ' ' or c == '\t') si +%= 1 else break;
            }

            // Drive: only initialize the FCB drive field if bit 1 is clear.
            var drive: u8 = 0; // 0 = default
            const c0 = rd.at(cpu, sbase, si);
            const c1 = rd.at(cpu, sbase, si +% 1);
            if (c1 == ':' and isAlpha(c0)) {
                drive = (upperByte(c0) - 'A') + 1;
                si +%= 2;
            }
            // Only set FCB drive if bit 1 (0x02) clear OR a drive was specified.
            if (ctrl & 0x02 == 0 or drive != 0) {
                cpu.bus.writePhys8(dbase, drive);
            }

            var has_wildcard = false;
            // Name field (8 bytes). Bit 2 (0x04) = keep existing if no name char.
            parseField(cpu, sbase, &si, dbase + 1, 8, ctrl & 0x04 != 0, &has_wildcard);
            // Extension field (3 bytes). Skip a leading '.'. Bit 3 (0x08) = keep.
            if (rd.at(cpu, sbase, si) == '.') {
                si +%= 1;
                parseField(cpu, sbase, &si, dbase + 9, 3, ctrl & 0x08 != 0, &has_wildcard);
            } else if (ctrl & 0x08 == 0) {
                var k: u16 = 0;
                while (k < 3) : (k += 1) cpu.bus.writePhys8(dbase + 9 + k, ' ');
            }

            cpu.st.setReg16(@intFromEnum(Reg32.esi), si);
            cpu.st.setReg8(0, if (has_wildcard) 1 else 0);
        }

        fn parseField(cpu: *Cpu, sbase: u32, si: *u16, dst: u32, width: u16, keep: bool, wild: *bool) void {
            if (!keep) {
                var k: u16 = 0;
                while (k < width) : (k += 1) cpu.bus.writePhys8(dst + k, ' ');
            }
            var w: u16 = 0;
            while (w < width) {
                const c = cpu.bus.readPhys8(sbase + si.*);
                if (c == '*') {
                    wild.* = true;
                    while (w < width) : (w += 1) cpu.bus.writePhys8(dst + w, '?');
                    si.* +%= 1;
                    return;
                }
                if (c == '?') wild.* = true;
                if (c == 0 or c == ' ' or c == '.' or c == ':' or c == ';' or
                    c == ',' or c == '=' or c == '+' or c == '\t' or
                    c == '\\' or c == '/' or c == '"' or c == '[' or c == ']' or
                    c == '<' or c == '>' or c == '|') break;
                cpu.bus.writePhys8(dst + w, upperByte(c));
                w += 1;
                si.* +%= 1;
            }
        }

        fn isAlpha(c: u8) bool {
            return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        }
        fn upperByte(c: u8) u8 {
            return if (c >= 'a' and c <= 'z') c - 32 else c;
        }

        // ---- AH=45/46 dup/dup2 (dos.cpp:1146-1162) ----
        fn dupHandle(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const handle = cpu.st.getReg16(EBX);
            const idx = dos.psp().jftGet(handle);
            if (idx == psp_mod.JFT_FREE) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const e = dos.sft.get(idx);
            if (!e.in_use) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const new_handle = dos.psp().jftAlloc(idx) orelse return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            e.refcount +%= 1;
            cpu.st.setReg16(EAX, new_handle);
            br.setGuestCF(false);
        }

        fn dup2Handle(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const src = cpu.st.getReg16(EBX);
            const dst = cpu.st.getReg16(ECX);
            const idx = dos.psp().jftGet(src);
            if (idx == psp_mod.JFT_FREE) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            const e = dos.sft.get(idx);
            if (!e.in_use) return dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            // If dst is already open, close it first (force-dup semantics).
            const cur = dos.psp().jftGet(dst);
            if (cur != psp_mod.JFT_FREE) {
                const ce = dos.sft.get(cur);
                if (ce.in_use and ce.ref == .file) {
                    if (ce.refcount > 1) {
                        ce.refcount -= 1;
                    } else {
                        if (dos.drivePtr(ce.drive)) |d| d.close(ce.ref.file);
                        dos.sft.freeSlot(cur);
                    }
                }
            }
            dos.psp().jftSet(dst, idx);
            e.refcount +%= 1;
            cpu.st.setReg16(EAX, dst);
            br.setGuestCF(false);
        }

        // ===================================================================
        // Directory search (D10 munging)
        // ===================================================================
        fn findFirst(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            // Resolve the directory portion (D8b) + take the final component as the
            // wildcard pattern.
            var rbuf: [128]u8 = undefined;
            const r = resolve(dos, path, &rbuf) orelse return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            var dir_part: []const u8 = "";
            var pat: []const u8 = r.path;
            if (std.mem.lastIndexOfAny(u8, r.path, "\\/")) |i| {
                dir_part = r.path[0..i];
                pat = r.path[i + 1 ..];
            }
            var fcb: [11]u8 = undefined;
            name83.wildcardToFcb(pat, &fcb);

            const dp = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);

            var found: [256]vfs.FoundEntry = undefined;
            const n = dp.enumerate(dir_part, &fcb, &found) catch return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            if (n == 0) return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);

            // Remember the search dir host-side so find-next walks the same
            // directory (the DTA reserved area is too small for a full path; only
            // one DTA search is active at a time by convention).
            _ = dos.setSearchDir(dir_part);
            const d = dos.dta();
            d.writeSearchState(r.drive + 1, &fcb, 1); // next index = 1
            writeFindEntry(cpu, d, found[0]);
            br.setGuestCF(false);
        }

        fn findNext(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const d = dos.dta();
            const idx = d.readSearchIdx();
            const drive = d.readDrive() - 1;
            var fcb: [11]u8 = undefined;
            d.readPattern(&fcb);
            const dir_part = dos.searchDir();
            const dp = dos.drivePtr(drive) orelse return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            var found: [256]vfs.FoundEntry = undefined;
            const n = dp.enumerate(dir_part, &fcb, &found) catch return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            if (idx >= n) return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            d.writeSearchState(drive + 1, &fcb, idx + 1);
            writeFindEntry(cpu, d, found[idx]);
            br.setGuestCF(false);
        }

        fn writeFindEntry(cpu: *Cpu, d: anytype, fe: vfs.FoundEntry) void {
            var nbuf: [13]u8 = undefined;
            const disp = fe.name.display(&nbuf);
            d.writeFound(fe.attr, clock.fileTime(), clock.fileDate(), fe.size, disp);
            _ = cpu;
        }

        // ===================================================================
        // Memory (MCB)
        // ===================================================================
        fn allocMem(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const paras = cpu.st.getReg16(EBX);
            var m = dos.mcb();
            if (m.alloc(paras, dos.current_psp)) |seg| {
                cpu.st.setReg16(EAX, seg);
                br.setGuestCF(false);
            } else {
                cpu.st.setReg16(EBX, m.largestFree()); // max available
                dos.dosError(cpu, br, Dos.ERR_NOT_ENOUGH_MEM);
            }
        }
        fn freeMem(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const seg = cpu.st.selector[@intFromEnum(Seg.es)];
            var m = dos.mcb();
            if (m.free(seg)) {
                br.setGuestCF(false);
            } else {
                dos.dosError(cpu, br, Dos.ERR_INVALID_HANDLE);
            }
        }
        fn resizeMem(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const seg = cpu.st.selector[@intFromEnum(Seg.es)];
            const paras = cpu.st.getReg16(EBX);
            var m = dos.mcb();
            const r = m.resize(seg, paras);
            if (r.ok) {
                br.setGuestCF(false);
            } else {
                cpu.st.setReg16(EBX, r.max);
                dos.dosError(cpu, br, Dos.ERR_NOT_ENOUGH_MEM);
            }
        }
        fn allocStrategy(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            if (al == 0) { // get
                cpu.st.setReg16(EAX, @intFromEnum(dos.strategy));
            } else { // set
                const s = cpu.st.getReg16(EBX) & 0x3;
                dos.strategy = @enumFromInt(@as(u2, @intCast(s)));
            }
            br.setGuestCF(false);
        }

        // ===================================================================
        // EXEC (AH=4B) -> the loader
        // ===================================================================
        fn exec(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const Loader = @import("loader.zig").Loader(Cpu);
            Loader.exec(dos, cpu, br);
        }

        fn vfsErrToDos(e: vfs.VfsError) u16 {
            return switch (e) {
                error.NotFound => Dos.ERR_FILE_NOT_FOUND,
                error.AccessDenied => Dos.ERR_ACCESS_DENIED,
                error.NoMoreFiles => Dos.ERR_NO_MORE_FILES,
                error.PathError => Dos.ERR_PATH_NOT_FOUND,
                error.IoFailed => Dos.ERR_ACCESS_DENIED,
                error.AlreadyExists => Dos.ERR_FILE_EXISTS,
            };
        }
    };
}
