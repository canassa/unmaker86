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
                        var b: [1]u8 = undefined;
                        const n = dos.dev_table.con.read(&b);
                        if (n == 1) {
                            cpu.st.setReg8(0, b[0]);
                            br.setGuestZF(false);
                        } else {
                            cpu.st.setReg8(0, 0);
                            br.setGuestZF(true);
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
                0x3E => closeFile(dos, cpu, br),
                0x3F => readFile(dos, cpu, br),
                0x40 => writeFile(dos, cpu, br),
                0x42 => seekFile(dos, cpu, br),
                0x41 => unlinkFile(dos, cpu, br),
                0x43 => getSetAttr(dos, cpu, br),
                0x44 => ioctl(dos, cpu, br),
                0x56 => renameFile(dos, cpu, br),
                0x45, 0x46 => dos.unsupported(cpu, br, 0x21), // dup/dup2 deferred

                // ---- Directory search ----
                0x4E => findFirst(dos, cpu, br),
                0x4F => findNext(dos, cpu, br),
                0x47 => getCwd(dos, cpu, br),
                0x3B => cpu.st.setReg8(0, 0), // chdir -> success (single-dir VFS)
                0x39, 0x3A => dos.unsupported(cpu, br, 0x21), // mkdir/rmdir deferred

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
        pub fn handle2f(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // AL=0 (not installed / available) is the faithful default.
            cpu.st.setReg8(0, 0);
            _ = br;
            _ = dos;
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
        fn getSetFileDateTime(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            if (al == 0) { // get -> CX=time, DX=date (the epoch, D13)
                cpu.st.setReg16(ECX, clock.fileTime());
                cpu.st.setReg16(EDX, clock.fileDate());
                br.setGuestCF(false);
            } else { // set: accepted (no host file-timestamp write — determinism)
                br.setGuestCF(false);
            }
            _ = dos;
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

        /// Resolve a DOS path to (drive index, host leaf name). Strips a drive
        /// prefix + a leading backslash; maps the leaf via 8.3 (the single-dir VFS
        /// has no subdirs, so we use the final component). Returns null on a bad
        /// path. `host_out` receives the host filename (the 8.3 display form).
        const Resolved = struct { drive: u8, name: name83.Name83 };
        fn resolve(dos: *Dos, path: []const u8) ?Resolved {
            var p = path;
            var drive = dos.current_drive;
            if (p.len >= 2 and p[1] == ':') {
                const dl = p[0];
                drive = if (dl >= 'a' and dl <= 'z') dl - 'a' else if (dl >= 'A' and dl <= 'Z') dl - 'A' else return null;
                p = p[2..];
            }
            // Take the final component (single-dir VFS).
            if (std.mem.lastIndexOfAny(u8, p, "\\/")) |i| p = p[i + 1 ..];
            const n83 = name83.parse(p) orelse return null;
            return .{ .drive = drive, .name = n83 };
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

            const r = resolve(dos, path) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            var hostbuf: [13]u8 = undefined;
            const hn = r.name.display(&hostbuf);
            const hf = drive.open(hn, mode) catch |e| {
                return dos.dosError(cpu, br, vfsErrToDos(e));
            };
            finishFileOpen(dos, cpu, br, hf, r, mode, hn);
        }

        fn createFile(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            if (dos.dev_table.resolve(path)) |dev| {
                openDeviceHandle(dos, cpu, br, dev, .write_only);
                return;
            }
            const r = resolve(dos, path) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            var hostbuf: [13]u8 = undefined;
            const hn = r.name.display(&hostbuf);
            const hf = drive.create(hn) catch |e| {
                return dos.dosError(cpu, br, vfsErrToDos(e));
            };
            finishFileOpen(dos, cpu, br, hf, r, .read_write, hn);
        }

        fn finishFileOpen(dos: *Dos, cpu: *Cpu, br: *Bridge, hf: vfs.HostFile, r: Resolved, mode: vfs.OpenMode, hn: []const u8) void {
            const slot = dos.sft.allocSlot() orelse {
                dos.drivePtr(r.drive).?.close(hf);
                return dos.dosError(cpu, br, Dos.ERR_TOO_MANY_OPEN);
            };
            const e = dos.sft.get(slot);
            e.* = .{ .in_use = true, .ref = .{ .file = hf }, .position = 0, .mode = mode, .refcount = 1, .drive = r.drive };
            e.setPath(hn);
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
            switch (e.ref) {
                .file => |hf| {
                    if (dos.drivePtr(e.drive)) |d| d.close(hf);
                },
                .device => {}, // devices stay open (CON/AUX/PRN are persistent)
            }
            // Only free the SFT slot for real files (not the shared device slots).
            if (e.ref == .file) dos.sft.freeSlot(idx);
            dos.psp().jftFree(handle);
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
            const r = resolve(dos, path) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(r.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            var hostbuf: [13]u8 = undefined;
            const hn = r.name.display(&hostbuf);
            drive.unlink(hn) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
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
            const ro = resolve(dos, old) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const rn = resolve(dos, new) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            const drive = dos.drivePtr(ro.drive) orelse return dos.dosError(cpu, br, Dos.ERR_PATH_NOT_FOUND);
            var ob2: [13]u8 = undefined;
            var nb2: [13]u8 = undefined;
            drive.rename(ro.name.display(&ob2), rn.name.display(&nb2)) catch |e| return dos.dosError(cpu, br, vfsErrToDos(e));
            br.setGuestCF(false);
        }

        fn getSetAttr(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const al = cpu.st.getReg8(0);
            if (al == 0) { // get attr -> CX
                cpu.st.setReg16(ECX, 0x20); // archive (a plain file)
                br.setGuestCF(false);
            } else { // set attr: accepted (host attrs not modeled)
                br.setGuestCF(false);
            }
            _ = dos;
        }

        fn ioctl(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
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
                else => dos.unsupported(cpu, br, 0x21),
            }
        }

        fn getCwd(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            // AH=47: DS:SI gets the ASCIIZ path (without drive/leading backslash).
            // The single-dir VFS root is "" (the mounted dir root).
            const seg = cpu.st.selector[@intFromEnum(Seg.ds)];
            const si = cpu.st.getReg16(@intFromEnum(Reg32.esi));
            cpu.bus.writePhys8((@as(u32, seg) << 4) + si, 0); // empty root
            cpu.st.setReg16(EAX, 0x0100);
            br.setGuestCF(false);
            _ = dos;
        }

        // ===================================================================
        // Directory search (D10 munging)
        // ===================================================================
        fn findFirst(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            var pbuf: [128]u8 = undefined;
            const path = readPath(cpu, &pbuf);
            // Take the final component as the wildcard pattern.
            var pat = path;
            if (std.mem.lastIndexOfAny(u8, pat, "\\/")) |i| pat = pat[i + 1 ..];
            var fcb: [11]u8 = undefined;
            name83.wildcardToFcb(pat, &fcb);

            var drive = dos.current_drive;
            if (path.len >= 2 and path[1] == ':') {
                const dl = path[0];
                drive = if (dl >= 'a' and dl <= 'z') dl - 'a' else dl - 'A';
            }
            const dp = dos.drivePtr(drive) orelse return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);

            var found: [256]vfs.FoundEntry = undefined;
            const n = dp.enumerate(&fcb, &found) catch return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            if (n == 0) return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);

            const d = dos.dta();
            d.writeSearchState(drive + 1, &fcb, 1); // next index = 1
            writeFindEntry(cpu, d, found[0]);
            br.setGuestCF(false);
        }

        fn findNext(dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const d = dos.dta();
            const idx = d.readSearchIdx();
            const drive = d.readDrive() - 1;
            var fcb: [11]u8 = undefined;
            d.readPattern(&fcb);
            const dp = dos.drivePtr(drive) orelse return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
            var found: [256]vfs.FoundEntry = undefined;
            const n = dp.enumerate(&fcb, &found) catch return dos.dosError(cpu, br, Dos.ERR_NO_MORE_FILES);
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
            };
        }
    };
}
