//! The System File Table (SFT, D9/D17) — the ONE piece of host-side state (it
//! holds the Zig `File` handles, which cannot live in guest RAM). A fixed-size
//! `[N]SftEntry` array indexed by a stable id; the per-process JFT in the PSP maps
//! the guest's file handle -> SFT index (psp.zig). `SftEntry` is a TAGGED UNION
//! {device|file} (D17) with an INLINE `[128]u8 + len` path (NOT a slice — no
//! per-open alloc; one flat snapshot-friendly array, D14).

const std = @import("std");
const vfs = @import("vfs.zig");
const devices = @import("devices.zig");

/// Provisional / comptime-asserted cap (sized from a BaK trace later; too-small
/// fails loudly at open time).
pub const SFT_MAX: u8 = 64;
pub const MAX_PATH: usize = 128;

pub const SftRef = union(enum) {
    device: *devices.CharDevice,
    file: vfs.HostFile,
};

pub const SftEntry = struct {
    in_use: bool = false,
    ref: SftRef = .{ .file = .{ .file = undefined } },
    /// Current file position (the seek pointer). For devices this is unused.
    position: u64 = 0,
    mode: vfs.OpenMode = .read_only,
    /// Reference count (dup/dup2 would bump this; we keep 1 for now).
    refcount: u16 = 0,
    /// Inline DOS path (the munged host name relative to the drive), NOT a slice.
    path: [MAX_PATH]u8 = @splat(0),
    path_len: u8 = 0,
    /// The drive letter index (0='A') this file lives on (for VFS routing).
    drive: u8 = 0,
    /// Snapshot integrity (D11/D14): file length + a content hash recorded at open,
    /// so a restore can detect a replayed-file mismatch.
    snap_len: u64 = 0,
    snap_hash: u64 = 0,
    /// DOS-packed file date/time (INT 21h AH=57). Real DOS keeps these in the SFT
    /// and AH=57 AL=00 reads them back. dosbox-x re-derives them from the HOST
    /// file's modification timestamp on every GET (non-deterministic — see oracle
    /// band 9), which zdos must NOT do. Instead we seed them from the pinned epoch
    /// (D13) at open and let AH=57 AL=01 (SET) overwrite them, so a SET-then-GET
    /// round-trips deterministically. `time_set` records whether SET has run
    /// (purely for clarity; the seeded epoch is already a valid value).
    f_time: u16 = 0,
    f_date: u16 = 0,
    time_set: bool = false,

    pub fn setPath(self: *SftEntry, p: []const u8) void {
        const n = @min(p.len, MAX_PATH);
        @memcpy(self.path[0..n], p[0..n]);
        self.path_len = @intCast(n);
    }
    pub fn pathSlice(self: *const SftEntry) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn isDevice(self: *const SftEntry) bool {
        return self.ref == .device;
    }
};

pub const Sft = struct {
    entries: [SFT_MAX]SftEntry = @splat(.{}),

    pub fn reset(self: *Sft) void {
        self.entries = @splat(.{});
    }

    /// Find a free SFT slot; returns its index or null if full.
    pub fn allocSlot(self: *Sft) ?u8 {
        for (&self.entries, 0..) |*e, i| {
            if (!e.in_use) return @intCast(i);
        }
        return null;
    }

    pub fn get(self: *Sft, idx: u8) *SftEntry {
        return &self.entries[idx];
    }

    /// Pre-open a device entry at a fixed slot (the standard handles 0-4).
    pub fn openDeviceAt(self: *Sft, idx: u8, dev: *devices.CharDevice, mode: vfs.OpenMode) void {
        self.entries[idx] = .{
            .in_use = true,
            .ref = .{ .device = dev },
            .mode = mode,
            .refcount = 1,
        };
    }

    pub fn freeSlot(self: *Sft, idx: u8) void {
        self.entries[idx].in_use = false;
        self.entries[idx].refcount = 0;
    }
};

comptime {
    // The standard handles 0-4 must fit (D17 pre-open).
    std.debug.assert(SFT_MAX >= 5);
}
