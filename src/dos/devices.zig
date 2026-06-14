//! DOS character-device layer (D17). Real DOS treats CON/AUX/PRN/NUL and
//! installable character devices as first-class objects opened by name AHEAD of
//! any file. The SFT entry is a tagged union {device|file}; standard handles 0-4
//! are pre-opened device objects; AH=3D resolves a device table BEFORE the drive
//! VFS; EMS registers `EMMXXXX0` so the documented EMS probe (open "EMMXXXX0")
//! succeeds truthfully.

const std = @import("std");

/// A character device's identity (CON keyboard/VGA seam, NUL discard, etc.).
pub const DeviceId = enum { con, aux, prn, nul, emm };

/// A DOS character device. `write` consumes bytes, `read` produces bytes (from
/// the scripted-input seam for CON, deterministic). The CON device records its
/// output so tests + the API server can observe console output without a VGA.
pub const CharDevice = struct {
    id: DeviceId,
    name: [8]u8, // FCB-form device name (space padded)

    /// CON output recording (a fixed ring; deterministic). The loader/print
    /// services + INT 21h AH=02/09 route here. Not host stdout (determinism).
    out_buf: [4096]u8 = @splat(0),
    out_len: usize = 0,

    /// Scripted CON input (keyboard seam) — deterministic external input. Tests
    /// preload this; reads consume from `in_pos`. When `redirected` is set, this
    /// CON's STDIN seam models a REDIRECTED stdin (DOS `prog < file`): in dosbox-x
    /// the handle-0 object is then a `LocalFile`, not the CON device, so
    /// `LocalFile::GetInformation()==0` (drive_local.cpp) — bit 6 (EOF/not-ready)
    /// is NEVER set, hence AH=0B STDIN-status is always "ready" (0xFF) and AH=0C
    /// does NOT flush (its flush is gated on the handle being named "CON").
    /// zdos preloads `.in` bytes via `loadInput`, which sets `redirected=true`.
    in_buf: [256]u8 = @splat(0),
    in_len: usize = 0,
    in_pos: usize = 0,
    redirected: bool = false,

    pub fn init(id: DeviceId, name: []const u8) CharDevice {
        var d: CharDevice = .{ .id = id, .name = @splat(' ') };
        const n = @min(name.len, 8);
        @memcpy(d.name[0..n], name[0..n]);
        return d;
    }

    /// The device-info word (AH=44 AL=00): bit 7 set (it IS a device). CON sets
    /// the stdin/stdout bits (bit 0/1) and the "special CON" bit (bit 4).
    pub fn infoWord(self: *const CharDevice) u16 {
        // Under REDIRECTION (the oracle mints with `prog < IN.TXT > OUT.TXT`),
        // dosbox-x backs handles 0/1/2 with LocalFiles, whose GetInformation()==0
        // (drive_local.cpp: bit 7 CLEAR = NOT a device, drive bits = 0). The
        // Borland CRT then treats stdout as a file -> FULLY buffered (flushed at
        // exit), so direct INT-21h console writes (AH=01/02/06/0A echo) appear
        // BEFORE the at-exit printf flush. zdos must report the SAME "this is a
        // redirected file" so the CRT buffers identically and the byte ORDER
        // matches the golden. (Without this, CON reports a device -> line-buffered
        // -> interleaved order diverges; see GETCH.)
        if (self.id == .con and self.redirected) return 0x0000;
        return switch (self.id) {
            .con => 0x80D3, // device + stdin + stdout + special + EOF-on-input bits
            .aux => 0x80C0,
            .prn => 0x80C0,
            .nul => 0x8084, // device + NUL bit (bit 2)
            .emm => 0xC080, // device, IOCTL-capable (the EMM probe expects bit 7)
        };
    }

    /// Write `bytes` to the device. Returns the number consumed (always all).
    pub fn write(self: *CharDevice, bytes: []const u8) usize {
        switch (self.id) {
            .nul => {}, // discard
            .con, .aux, .prn => {
                for (bytes) |b| {
                    if (self.out_len < self.out_buf.len) {
                        self.out_buf[self.out_len] = b;
                        self.out_len += 1;
                    }
                }
            },
            .emm => {}, // EMM device write: ignored (probe is IOCTL-only)
        }
        return bytes.len;
    }

    /// Read up to `dst.len` bytes from the device (scripted input for CON).
    /// Returns the number read (0 at end of scripted input — deterministic EOF).
    pub fn read(self: *CharDevice, dst: []u8) usize {
        switch (self.id) {
            .con, .aux => {
                var n: usize = 0;
                while (n < dst.len and self.in_pos < self.in_len) {
                    dst[n] = self.in_buf[self.in_pos];
                    n += 1;
                    self.in_pos += 1;
                }
                return n;
            },
            else => return 0,
        }
    }

    pub fn writeByte(self: *CharDevice, b: u8) void {
        _ = self.write(&[_]u8{b});
    }

    pub fn output(self: *const CharDevice) []const u8 {
        return self.out_buf[0..self.out_len];
    }

    pub fn loadInput(self: *CharDevice, bytes: []const u8) void {
        const n = @min(bytes.len, self.in_buf.len);
        @memcpy(self.in_buf[0..n], bytes[0..n]);
        self.in_len = n;
        self.in_pos = 0;
        self.redirected = true;
    }

    /// True if more scripted input remains (not yet at EOF).
    pub fn hasInput(self: *const CharDevice) bool {
        return self.in_pos < self.in_len;
    }

    /// DOS STDIN status (AH=0B / GetSTDINStatus): "is a key/byte ready?".
    /// Under REDIRECTED stdin, dosbox-x's handle-0 is a LocalFile whose
    /// GetInformation()==0, so bit 6 is never set and status is ALWAYS ready —
    /// even past EOF (a redirected status poll keeps returning 0xFF; the program
    /// then learns EOF only from a 0-byte read). Without redirection (interactive
    /// CON, no scripted input) we report not-ready (no keystrokes pending).
    pub fn stdinReady(self: *const CharDevice) bool {
        if (self.redirected) return true;
        return self.in_pos < self.in_len;
    }

    /// AH=0C flush-buffer gate: dosbox-x flushes STDIN only when the handle is
    /// named "CON". A redirected stdin (LocalFile) is NOT named CON, so no flush.
    pub fn isFlushable(self: *const CharDevice) bool {
        return self.id == .con and !self.redirected;
    }
};

/// The fixed device table (D17). Indexed by `DeviceId`. EMMXXXX0 is present so
/// the EMS probe resolves it ahead of the VFS.
pub const DeviceTable = struct {
    con: CharDevice = CharDevice.init(.con, "CON"),
    aux: CharDevice = CharDevice.init(.aux, "AUX"),
    prn: CharDevice = CharDevice.init(.prn, "PRN"),
    nul: CharDevice = CharDevice.init(.nul, "NUL"),
    emm: CharDevice = CharDevice.init(.emm, "EMMXXXX0"),

    pub fn reset(self: *DeviceTable) void {
        self.* = .{};
    }

    /// Resolve a device by name (case-insensitive, the leaf before any extension
    /// — DOS ignores an extension on a device name, e.g. "CON.TXT" == CON).
    /// Returns null if no device matches (the caller falls through to the VFS).
    pub fn resolve(self: *DeviceTable, name: []const u8) ?*CharDevice {
        // Strip a path; take the leaf, then drop any extension.
        var leaf = name;
        if (std.mem.lastIndexOfAny(u8, name, "\\/")) |i| leaf = name[i + 1 ..];
        if (std.mem.indexOfScalar(u8, leaf, '.')) |i| leaf = leaf[0..i];

        if (eqi(leaf, "CON")) return &self.con;
        if (eqi(leaf, "AUX")) return &self.aux;
        if (eqi(leaf, "PRN")) return &self.prn;
        if (eqi(leaf, "NUL")) return &self.nul;
        if (eqi(leaf, "EMMXXXX0")) return &self.emm;
        return null;
    }
};

fn eqi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xu = if (x >= 'a' and x <= 'z') x - 32 else x;
        const yu = if (y >= 'a' and y <= 'z') y - 32 else y;
        if (xu != yu) return false;
    }
    return true;
}
