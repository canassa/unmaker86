//! Host-FS VFS (D8): a `DosDrive` abstraction with ONE backend for BaK — a
//! `HostDirDrive` mapping one host directory to one DOS drive letter, over
//! `std.Io.Dir` (the verified 0.16 file API). Determinism (D6): file CONTENT is
//! fixed external input (the game's data files on disk); file TIMING never touches
//! the ledger (the synthetic D5 cost is charged at the bridge, not here);
//! directory enumeration is deterministically ordered (D10); timestamps come from
//! the pinned epoch, never the host file timestamp (D13).

const std = @import("std");
const Io = std.Io;
const name83 = @import("name83.zig");

pub const OpenMode = enum { read_only, write_only, read_write };

/// A found directory entry returned by findFirst/findNext.
pub const FoundEntry = struct {
    /// 8.3 display name (ASCIIZ-able), e.g. "FILE.EXT".
    name: name83.Name83,
    size: u32,
    attr: u8,
    is_dir: bool,
};

/// VFS error set (mapped to DOS error codes by the caller).
pub const VfsError = error{
    NotFound,
    AccessDenied,
    NoMoreFiles,
    IoFailed,
    PathError,
};

/// One open host file's per-handle state lives in the SFT, not here; the drive is
/// stateless except for its host `Dir` + `io`.
pub const HostFile = struct {
    file: Io.File,
};

/// The single host-directory drive backend.
pub const HostDirDrive = struct {
    dir: Io.Dir,
    io: Io,

    pub fn init(dir: Io.Dir, io: Io) HostDirDrive {
        return .{ .dir = dir, .io = io };
    }

    /// Open an existing file by DOS 8.3 name (already munged to a host name by the
    /// caller). Returns the open host file.
    pub fn open(self: *HostDirDrive, host_name: []const u8, mode: OpenMode) VfsError!HostFile {
        const m: Io.Dir.OpenFileOptions.Mode = switch (mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        };
        const f = self.dir.openFile(self.io, host_name, .{ .mode = m, .allow_directory = false }) catch |e| {
            return mapErr(e);
        };
        return .{ .file = f };
    }

    /// Create (or truncate) a file. Returns the open host file (read_write).
    pub fn create(self: *HostDirDrive, host_name: []const u8) VfsError!HostFile {
        const f = self.dir.createFile(self.io, host_name, .{ .read = true, .truncate = true }) catch |e| {
            return mapErr(e);
        };
        return .{ .file = f };
    }

    pub fn close(self: *HostDirDrive, hf: HostFile) void {
        hf.file.close(self.io);
    }

    pub fn unlink(self: *HostDirDrive, host_name: []const u8) VfsError!void {
        self.dir.deleteFile(self.io, host_name) catch |e| return mapErr(e);
    }

    pub fn rename(self: *HostDirDrive, old_name: []const u8, new_name: []const u8) VfsError!void {
        self.dir.rename(old_name, self.dir, new_name, self.io) catch |e| return mapErr(e);
    }

    /// Read up to `dst.len` bytes from `hf` at absolute position `pos`. Returns
    /// the number read (0 at EOF). Uses a fresh Reader with a stack buffer +
    /// seek (no per-handle Reader state stored — the SFT tracks `pos`).
    pub fn readAt(self: *HostDirDrive, hf: HostFile, pos: u64, dst: []u8) VfsError!usize {
        // Unbuffered positioned read: seek the File.Reader then read straight into
        // `dst` (the SFT tracks the logical position; no Reader state is kept).
        var r = hf.file.reader(self.io, &.{});
        r.seekTo(pos) catch return error.IoFailed;
        return r.interface.readSliceShort(dst) catch return error.IoFailed;
    }

    /// Write `src` to `hf` at absolute position `pos`. Returns bytes written.
    pub fn writeAt(self: *HostDirDrive, hf: HostFile, pos: u64, src: []const u8) VfsError!usize {
        var w = hf.file.writer(self.io, &.{});
        w.seekTo(pos) catch return error.IoFailed;
        w.interface.writeAll(src) catch return error.IoFailed;
        return src.len;
    }

    pub fn size(self: *HostDirDrive, hf: HostFile) VfsError!u64 {
        return hf.file.length(self.io) catch return error.IoFailed;
    }

    /// Enumerate entries matching `fcb_pattern` (an 11-byte wildcard, '?' = any),
    /// returning them in a DETERMINISTIC order (D10: sort before assigning short
    /// names). `out` is a caller buffer; returns the count written. `start_idx`
    /// is the find-next resume index. This re-reads + re-sorts the directory each
    /// call (correct + deterministic; the directory is small for BaK).
    pub fn enumerate(
        self: *HostDirDrive,
        fcb_pattern: *const [11]u8,
        out: []FoundEntry,
    ) VfsError!usize {
        // Collect host names into a fixed buffer (no per-op heap on the hot path
        // beyond this bounded scratch). Sort deterministically, then munge + match.
        var names: [256][64]u8 = undefined;
        var name_lens: [256]u8 = undefined;
        var count: usize = 0;

        var it = self.dir.iterate();
        while (it.next(self.io) catch return error.IoFailed) |entry| {
            if (count >= names.len) break;
            if (entry.name.len > 63) continue;
            @memcpy(names[count][0..entry.name.len], entry.name);
            name_lens[count] = @intCast(entry.name.len);
            count += 1;
        }

        // Deterministic sort by raw host name bytes (CLAUDE #5).
        const Ctx = struct {
            names: *[256][64]u8,
            lens: *[256]u8,
            fn lessThan(c: @This(), a: usize, b: usize) bool {
                const sa = c.names[a][0..c.lens[a]];
                const sb = c.names[b][0..c.lens[b]];
                return std.mem.order(u8, sa, sb) == .lt;
            }
        };
        var order: [256]usize = undefined;
        for (0..count) |i| order[i] = i;
        std.sort.pdq(usize, order[0..count], Ctx{ .names = &names, .lens = &name_lens }, Ctx.lessThan);

        // Assign deterministic ~N short names + match the pattern.
        var written: usize = 0;
        var tilde: u32 = 1;
        for (order[0..count]) |idx| {
            if (written >= out.len) break;
            const hn = names[idx][0..name_lens[idx]];
            var n83: name83.Name83 = undefined;
            if (name83.fitsShort(hn)) {
                n83 = name83.parse(hn) orelse continue;
            } else {
                n83 = name83.generateShort(hn, tilde);
                tilde += 1;
            }
            var fcb: [11]u8 = undefined;
            n83.fcb(&fcb);
            if (!name83.fcbMatch(fcb_pattern, &fcb)) continue;

            // Stat the entry for size (content is fixed input; timestamp is the
            // epoch, NOT the host file timestamp — set by the caller via clock.zig).
            const fsize: u32 = blk: {
                const f = self.dir.openFile(self.io, hn, .{ .mode = .read_only, .allow_directory = true }) catch break :blk 0;
                defer f.close(self.io);
                var b: [16]u8 = undefined;
                var r = f.reader(self.io, &b);
                const s = r.getSize() catch 0;
                break :blk @intCast(@min(s, std.math.maxInt(u32)));
            };

            out[written] = .{ .name = n83, .size = fsize, .attr = 0x20, .is_dir = false };
            written += 1;
        }
        return written;
    }
};

fn mapErr(e: anyerror) VfsError {
    return switch (e) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.IoFailed,
    };
}
