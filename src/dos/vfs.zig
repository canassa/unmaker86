//! Host-FS VFS (D8): a `DosDrive` abstraction with ONE backend for BaK — a
//! `HostDirDrive` mapping one host directory to one DOS drive letter, over
//! `std.Io.Dir` (the verified 0.16 file API). Determinism (D6): file CONTENT is
//! fixed external input (the game's data files on disk); file TIMING never touches
//! the ledger (the synthetic D5 cost is charged at the bridge, not here);
//! directory enumeration is deterministically ordered (D10); timestamps come from
//! the pinned epoch, never the host file timestamp (D13).
//!
//! Multi-component path traversal (D8b): a DOS path like `SUB\DATA.TXT` (or an
//! absolute `\A\B\C`) resolves component-by-component against the host directory
//! tree. Each component is matched case-insensitively, and where a host name is a
//! long name it is matched against its deterministic 8.3 munge — so the same
//! host tree resolves the same way every run. The resolved host-relative path
//! (joined with '/') is then opened relative to the mount root via `std.Io.Dir`
//! sub-path opening; no extra `Dir` handles are kept open across calls.

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
    /// Exclusive create (AH=5B) on a name that already exists.
    AlreadyExists,
};

/// DOS attribute bits (subset).
pub const ATTR_READONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;

/// Bits SetFileAttr (AH=43 AL=01) may NOT change: VOLUME + DIRECTORY are taken
/// from the existing entry (dos_files.cpp:1391 attr_mask). Everything else
/// (READONLY/HIDDEN/SYSTEM/ARCHIVE) is settable.
pub const ATTR_SET_MASK: u8 = ATTR_VOLUME | ATTR_DIRECTORY;

/// Stat result for a resolved DOS path (AH=43 get-attr, existence probes).
pub const StatResult = struct {
    size: u32,
    attr: u8,
    is_dir: bool,
};

/// Max length of a translated host-relative path (DOS path length cap).
pub const MAX_HOST_PATH = 128;

/// One open host file's per-handle state lives in the SFT, not here; the drive is
/// stateless except for its host `Dir` + `io`.
pub const HostFile = struct {
    file: Io.File,
};

/// A DOS-attribute override for one host file (AH=43 AL=01 SET). zdos does NOT
/// chmod the host file the way dosbox-x does (chmod would (a) mutate a committed
/// corpus file — a hygiene/permission hazard — and (b) make a later host
/// write-open fail with EACCES, which dosbox-x's localDrive::FileOpen does NOT do
/// for a per-FILE read-only bit: it only refuses writes on a whole-drive
/// read-only MOUNT, dos drive_local.cpp:1545). Instead the set attribute is held
/// here, keyed by the resolved host-relative path, so GET reflects SET, write-open
/// is unaffected, and no host state is touched. The override is per machine boot
/// (reset on init) — deterministic and snapshot-friendly.
const AttrOverride = struct {
    path: [MAX_HOST_PATH]u8 = @splat(0),
    path_len: u8 = 0,
    attr: u8 = 0,
    in_use: bool = false,
};

/// The single host-directory drive backend.
pub const HostDirDrive = struct {
    dir: Io.Dir,
    io: Io,
    /// Fixed-capacity DOS-attribute override table (no per-call alloc). Sized for
    /// the corpus + BaK working set; a full table fails the SET loudly rather
    /// than silently dropping an attribute.
    attr_overrides: [32]AttrOverride = @splat(.{}),

    pub fn init(dir: Io.Dir, io: Io) HostDirDrive {
        return .{ .dir = dir, .io = io };
    }

    /// Find the override slot for a host-relative path, or null.
    fn findOverride(self: *HostDirDrive, host: []const u8) ?*AttrOverride {
        for (&self.attr_overrides) |*o| {
            if (o.in_use and std.mem.eql(u8, o.path[0..o.path_len], host)) return o;
        }
        return null;
    }

    /// Set (or update) the DOS attribute override for `host`. Returns false if the
    /// table is full (the caller surfaces a faithful DOS error, never a silent
    /// drop). VOLUME/DIRECTORY are NOT stored here (they come from the inode).
    fn putOverride(self: *HostDirDrive, host: []const u8, attr: u8) bool {
        if (host.len > MAX_HOST_PATH) return false;
        if (self.findOverride(host)) |o| {
            o.attr = attr;
            return true;
        }
        for (&self.attr_overrides) |*o| {
            if (!o.in_use) {
                @memcpy(o.path[0..host.len], host);
                o.path_len = @intCast(host.len);
                o.attr = attr;
                o.in_use = true;
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Multi-component path resolution (D8b)
    // ------------------------------------------------------------------

    /// Resolve a DOS-relative path (already stripped of drive letter; '\' or '/'
    /// separators; may have a leading separator meaning "from root") into a
    /// host-relative path (joined with '/') in `out`. Each existing component is
    /// matched case-insensitively (and against its 8.3 munge for long names).
    /// The LEAF, if absent, is emitted as its uppercased component as-is (so a
    /// create can name a not-yet-existing file). Returns the slice into `out`, or
    /// null if a non-leaf intermediate component does not exist as a directory.
    fn resolveHostPath(self: *HostDirDrive, dos_path: []const u8, out: []u8) ?[]u8 {
        var written: usize = 0;
        // Split into components, skipping empty (leading/duplicate separators).
        var it = std.mem.tokenizeAny(u8, dos_path, "\\/");
        // We descend a directory chain; `cur` tracks the directory we resolve the
        // next component inside. We open each intermediate dir relative to root by
        // its accumulated host path (cheap; trees are shallow for DOS programs).
        var prefix_len: usize = 0; // length in `out` of the path so far (a dir)
        while (it.next()) |comp| {
            if (comp.len == 0) continue;
            if (std.mem.eql(u8, comp, ".")) continue;
            // ".." is not modeled (the corpus never needs it; faithful failure).
            if (std.mem.eql(u8, comp, "..")) return null;

            const is_leaf = it.peek() == null;

            // The DOS component as its uppercased 8.3 display form — the common
            // case where the host file is named identically (e.g. SUB, DATA.TXT).
            var name_buf: [64]u8 = undefined;
            const n83 = name83.parse(comp) orelse return null;
            const direct = n83.display(&name_buf);

            // FAST PATH: does `<prefix>/<direct>` already exist? A single statFile
            // (no directory iteration, so it also works on a non-iterable mount).
            var host_name: []const u8 = direct;
            if (!self.childStatExists(out[0..prefix_len], direct)) {
                if (is_leaf) {
                    // A leaf with no direct match: keep the uppercased direct name
                    // (a create / open names it; the host open will report absence).
                    // No directory iteration here — the mount need not be iterable.
                    host_name = direct;
                } else {
                    // An intermediate (directory) component must resolve. Walk the
                    // parent for a case-insensitive / 8.3-munged match.
                    const m = self.findChild(out[0..prefix_len], comp) orelse return null;
                    host_name = m.slice(&name_buf);
                }
            }

            // Append "/host_name" (no leading '/' for the first component).
            if (written != 0) {
                if (written >= out.len) return null;
                out[written] = '/';
                written += 1;
            }
            if (written + host_name.len > out.len) return null;
            @memcpy(out[written .. written + host_name.len], host_name);
            written += host_name.len;
            prefix_len = written;
        }
        return out[0..written];
    }

    /// True if `<dir_rel>/<name>` (or just `<name>` when dir_rel is empty) exists
    /// on the host. A single statFile — no directory iteration (works on a non-
    /// iterable mount handle).
    fn childStatExists(self: *HostDirDrive, dir_rel: []const u8, name: []const u8) bool {
        var buf: [MAX_HOST_PATH]u8 = undefined;
        var n: usize = 0;
        if (dir_rel.len != 0) {
            if (dir_rel.len + 1 + name.len > buf.len) return false;
            @memcpy(buf[0..dir_rel.len], dir_rel);
            buf[dir_rel.len] = '/';
            n = dir_rel.len + 1;
        } else {
            if (name.len > buf.len) return false;
        }
        @memcpy(buf[n .. n + name.len], name);
        n += name.len;
        _ = self.dir.statFile(self.io, buf[0..n], .{}) catch return false;
        return true;
    }

    const ChildName = struct {
        buf: [64]u8 = undefined,
        len: u8 = 0,
        fn slice(self: *const ChildName, out: *[64]u8) []const u8 {
            @memcpy(out[0..self.len], self.buf[0..self.len]);
            return out[0..self.len];
        }
    };

    /// Find an existing host entry inside the directory at host-relative path
    /// `dir_rel` (empty = the mount root) whose name matches `comp` either
    /// case-insensitively (direct) or via its deterministic 8.3 munge. Returns
    /// the actual host name. Deterministic: enumerates in sorted order and takes
    /// the first match.
    fn findChild(self: *HostDirDrive, dir_rel: []const u8, comp: []const u8) ?ChildName {
        var d: Io.Dir = if (dir_rel.len == 0)
            self.dir
        else
            self.dir.openDir(self.io, dir_rel, .{ .iterate = true }) catch return null;
        defer if (dir_rel.len != 0) d.close(self.io);

        // The DOS component we want, as an 8.3 form (for munge matching).
        const want = name83.parse(comp);

        // Collect + sort host names for determinism, then match.
        var names: [256][64]u8 = undefined;
        var lens: [256]u8 = undefined;
        var count: usize = 0;
        var dit = d.iterate();
        while (dit.next(self.io) catch return null) |entry| {
            if (count >= names.len) break;
            if (entry.name.len > 63) continue;
            @memcpy(names[count][0..entry.name.len], entry.name);
            lens[count] = @intCast(entry.name.len);
            count += 1;
        }
        var order: [256]usize = undefined;
        for (0..count) |i| order[i] = i;
        const Ctx = struct {
            names: *[256][64]u8,
            lens: *[256]u8,
            fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, c.names[a][0..c.lens[a]], c.names[b][0..c.lens[b]]) == .lt;
            }
        };
        std.sort.pdq(usize, order[0..count], Ctx{ .names = &names, .lens = &lens }, Ctx.lessThan);

        var tilde: u32 = 1;
        for (order[0..count]) |idx| {
            const hn = names[idx][0..lens[idx]];
            // Direct case-insensitive match (the common case: host == DOS name).
            if (eqlIgnoreCase(hn, comp)) {
                var r: ChildName = .{};
                @memcpy(r.buf[0..hn.len], hn);
                r.len = @intCast(hn.len);
                return r;
            }
            // Munge match: compare the host name's 8.3 form to the wanted 8.3.
            if (want) |w| {
                var n83: name83.Name83 = undefined;
                if (name83.fitsShort(hn)) {
                    n83 = name83.parse(hn) orelse continue;
                } else {
                    n83 = name83.generateShort(hn, tilde);
                    tilde += 1;
                }
                var a: [11]u8 = undefined;
                var b: [11]u8 = undefined;
                n83.fcb(&a);
                w.fcb(&b);
                if (std.mem.eql(u8, &a, &b)) {
                    var r: ChildName = .{};
                    @memcpy(r.buf[0..hn.len], hn);
                    r.len = @intCast(hn.len);
                    return r;
                }
            } else if (name83.fitsShort(hn)) {
                _ = name83.parse(hn);
            } else {
                tilde += 1;
            }
        }
        return null;
    }

    fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            const xu = if (x >= 'a' and x <= 'z') x - 32 else x;
            const yu = if (y >= 'a' and y <= 'z') y - 32 else y;
            if (xu != yu) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // File operations (full DOS-relative paths, D8b)
    // ------------------------------------------------------------------

    /// Open an existing file by DOS-relative path. Resolves multi-component paths.
    pub fn open(self: *HostDirDrive, dos_path: []const u8, mode: OpenMode) VfsError!HostFile {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.NotFound;
        const m: Io.Dir.OpenFileOptions.Mode = switch (mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        };
        const f = self.dir.openFile(self.io, host, .{ .mode = m, .allow_directory = false }) catch |e| {
            return mapErr(e);
        };
        return .{ .file = f };
    }

    /// Create (or truncate) a file by DOS-relative path (read_write). A fresh
    /// create resets any stale attribute override for this name (the new file
    /// starts as a plain ARCHIVE file, like a real DOS create).
    pub fn create(self: *HostDirDrive, dos_path: []const u8) VfsError!HostFile {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.PathError;
        const f = self.dir.createFile(self.io, host, .{ .read = true, .truncate = true }) catch |e| {
            return mapErr(e);
        };
        self.clearOverride(host);
        return .{ .file = f };
    }

    /// Drop any attribute override for a host-relative path (e.g. on a fresh
    /// create, which gives the file default attributes).
    fn clearOverride(self: *HostDirDrive, host: []const u8) void {
        if (self.findOverride(host)) |o| o.in_use = false;
    }

    /// Exclusive create (INT 21h AH=5B): create a NEW file that must not already
    /// exist. Mirrors dosbox-x dos.cpp:2550 — it first probes existence with a
    /// read open and, if the file opens, fails with FILE_ALREADY_EXISTS; otherwise
    /// it creates. Here we surface that as error.AlreadyExists so the INT 21h layer
    /// can return DOSERR_FILE_ALREADY_EXISTS (80). A non-existent name creates +
    /// truncates exactly like `create`.
    pub fn createNew(self: *HostDirDrive, dos_path: []const u8) VfsError!HostFile {
        if (self.stat(dos_path)) |_| {
            return error.AlreadyExists;
        } else |e| switch (e) {
            error.NotFound => {}, // good: the name is free, fall through to create
            else => return e,
        }
        return self.create(dos_path);
    }

    /// Stat a DOS-relative path (existence + attributes). NotFound when absent.
    /// The DOS attribute mirrors dosbox-x localDrive::GetFileAttr (non-WIN32 path,
    /// drive_local.cpp:2070): a regular file is ARCHIVE, a directory is DIRECTORY,
    /// and the READ_ONLY bit is set iff the host inode's owner-write bit is clear.
    /// On top of that, any AH=43 SET override for this path supersedes the
    /// settable bits (READONLY/HIDDEN/SYSTEM/ARCHIVE); VOLUME/DIRECTORY always come
    /// from the inode (they cannot be set, dos_files.cpp:1391).
    pub fn stat(self: *HostDirDrive, dos_path: []const u8) VfsError!StatResult {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.NotFound;
        const st = self.dir.statFile(self.io, host, .{}) catch |e| return mapErr(e);
        const is_dir = st.kind == .directory;
        var attr: u8 = if (is_dir) ATTR_DIRECTORY else ATTR_ARCHIVE;
        if (st.permissions.readOnly()) attr |= ATTR_READONLY;
        if (self.findOverride(host)) |o| {
            // Settable bits from the override; structural bits from the inode.
            attr = (o.attr & ~ATTR_SET_MASK) | (attr & ATTR_SET_MASK);
        }
        return .{
            .size = @intCast(@min(st.size, std.math.maxInt(u32))),
            .attr = attr,
            .is_dir = is_dir,
        };
    }

    /// Apply an AH=43 AL=01 (set file attributes) request to a DOS-relative path.
    /// Mirrors dosbox-x DOS_SetFileAttr (dos_files.cpp:1347): the file must exist;
    /// VOLUME/DIRECTORY bits cannot be changed (they are taken from the existing
    /// entry); the rest are recorded. NotFound when absent; IoFailed if the
    /// override table is full (surfaced as a faithful DOS error, never dropped).
    pub fn setAttr(self: *HostDirDrive, dos_path: []const u8, attr: u8) VfsError!void {
        const cur = try self.stat(dos_path); // NotFound if absent (== dosbox)
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.NotFound;
        // Keep VOLUME/DIRECTORY from the existing entry; take the rest from `attr`.
        const merged = (attr & ~ATTR_SET_MASK) | (cur.attr & ATTR_SET_MASK);
        if (!self.putOverride(host, merged)) return error.IoFailed;
    }

    pub fn close(self: *HostDirDrive, hf: HostFile) void {
        hf.file.close(self.io);
    }

    pub fn unlink(self: *HostDirDrive, dos_path: []const u8) VfsError!void {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.NotFound;
        self.dir.deleteFile(self.io, host) catch |e| return mapErr(e);
        self.clearOverride(host); // a deleted name carries no attribute override
    }

    pub fn mkdir(self: *HostDirDrive, dos_path: []const u8) VfsError!void {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.PathError;
        self.dir.createDir(self.io, host, .default_dir) catch |e| return mapErr(e);
    }

    pub fn rmdir(self: *HostDirDrive, dos_path: []const u8) VfsError!void {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return error.NotFound;
        self.dir.deleteDir(self.io, host) catch |e| return mapErr(e);
    }

    /// Test whether a DOS-relative path resolves to an existing directory.
    pub fn dirExists(self: *HostDirDrive, dos_path: []const u8) bool {
        var hbuf: [MAX_HOST_PATH]u8 = undefined;
        const host = self.resolveHostPath(dos_path, &hbuf) orelse return false;
        if (host.len == 0) return true; // the root
        const st = self.dir.statFile(self.io, host, .{}) catch return false;
        return st.kind == .directory;
    }

    pub fn rename(self: *HostDirDrive, old_path: []const u8, new_path: []const u8) VfsError!void {
        var ob: [MAX_HOST_PATH]u8 = undefined;
        var nb: [MAX_HOST_PATH]u8 = undefined;
        const oh = self.resolveHostPath(old_path, &ob) orelse return error.NotFound;
        const nh = self.resolveHostPath(new_path, &nb) orelse return error.PathError;
        self.dir.rename(oh, self.dir, nh, self.io) catch |e| return mapErr(e);
    }

    /// Read up to `dst.len` bytes from `hf` at absolute position `pos`. Returns
    /// the number read (0 at EOF). Uses a fresh Reader with a stack buffer +
    /// seek (no per-handle Reader state stored — the SFT tracks `pos`).
    pub fn readAt(self: *HostDirDrive, hf: HostFile, pos: u64, dst: []u8) VfsError!usize {
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

    /// Enumerate entries matching `fcb_pattern` (an 11-byte wildcard, '?' = any)
    /// inside the directory at DOS-relative `dir_path` (empty = root), returning
    /// them in a DETERMINISTIC order (D10: sort before assigning short names).
    /// `out` is a caller buffer; returns the count written. This re-reads +
    /// re-sorts the directory each call (correct + deterministic; small dirs).
    pub fn enumerate(
        self: *HostDirDrive,
        dir_path: []const u8,
        fcb_pattern: *const [11]u8,
        out: []FoundEntry,
    ) VfsError!usize {
        var d: Io.Dir = blk: {
            if (dir_path.len == 0) break :blk self.dir;
            var hbuf: [MAX_HOST_PATH]u8 = undefined;
            const host = self.resolveHostPath(dir_path, &hbuf) orelse return error.PathError;
            if (host.len == 0) break :blk self.dir;
            break :blk self.dir.openDir(self.io, host, .{ .iterate = true }) catch return error.PathError;
        };
        defer if (dir_path.len != 0) d.close(self.io);

        var names: [256][64]u8 = undefined;
        var name_lens: [256]u8 = undefined;
        var is_dir: [256]bool = undefined;
        var count: usize = 0;

        var it = d.iterate();
        while (it.next(self.io) catch return error.IoFailed) |entry| {
            if (count >= names.len) break;
            if (entry.name.len > 63) continue;
            @memcpy(names[count][0..entry.name.len], entry.name);
            name_lens[count] = @intCast(entry.name.len);
            is_dir[count] = entry.kind == .directory;
            count += 1;
        }

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

            const entry_is_dir = is_dir[idx];
            const fsize: u32 = if (entry_is_dir) 0 else blk: {
                const f = d.openFile(self.io, hn, .{ .mode = .read_only, .allow_directory = true }) catch break :blk 0;
                defer f.close(self.io);
                break :blk @intCast(@min(f.length(self.io) catch 0, std.math.maxInt(u32)));
            };

            out[written] = .{
                .name = n83,
                .size = fsize,
                .attr = if (entry_is_dir) ATTR_DIRECTORY else ATTR_ARCHIVE,
                .is_dir = entry_is_dir,
            };
            written += 1;
        }
        return written;
    }
};

fn mapErr(e: anyerror) VfsError {
    return switch (e) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.PathAlreadyExists => error.AccessDenied,
        error.NotDir => error.PathError,
        else => error.IoFailed,
    };
}
