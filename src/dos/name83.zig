//! 8.3 filename munging (D10) — RE-DERIVED from the documented DOS 8.3 rules and
//! the dosbox-test-suite behavioral spec; NOT copied from DOSBox's GPL
//! `DOS_MakeName`/`DTAExtendName`. Determinism (CLAUDE #5): the long->short `~N`
//! generation is assigned over a DETERMINISTICALLY SORTED directory listing, so
//! the same host directory yields the same short names every run.

const std = @import("std");

/// A canonical 8.3 name: NAME (<=8) + EXT (<=3), uppercase, space-padded form
/// available via `formatted`. `name`/`ext` are trimmed (no trailing spaces).
pub const Name83 = struct {
    name: [8]u8 = @splat(' '),
    ext: [3]u8 = @splat(' '),
    name_len: u8 = 0,
    ext_len: u8 = 0,

    /// The DOS "8.3 with a dot" display form (e.g. "FILE.EXT"), into `out`.
    /// Returns the slice written.
    pub fn display(self: *const Name83, out: []u8) []u8 {
        var i: usize = 0;
        for (self.name[0..self.name_len]) |c| {
            out[i] = c;
            i += 1;
        }
        if (self.ext_len > 0) {
            out[i] = '.';
            i += 1;
            for (self.ext[0..self.ext_len]) |c| {
                out[i] = c;
                i += 1;
            }
        }
        return out[0..i];
    }

    /// The 11-byte FCB / directory-entry form: NAME space-padded to 8 + EXT
    /// space-padded to 3 (no dot). Writes exactly 11 bytes into `out`.
    pub fn fcb(self: *const Name83, out: *[11]u8) void {
        @memset(out, ' ');
        @memcpy(out[0..self.name_len], self.name[0..self.name_len]);
        @memcpy(out[8 .. 8 + self.ext_len], self.ext[0..self.ext_len]);
    }
};

/// A character valid in a DOS 8.3 name (excluding '.', which is the separator).
/// Re-derived from the DOS reserved set: control chars and
/// " * + , / : ; < = > ? [ \ ] | are illegal.
pub fn isValid83Char(c: u8) bool {
    if (c < 0x20) return false;
    return switch (c) {
        ' ', '"', '*', '+', ',', '/', ':', ';', '<', '=', '>', '?', '[', '\\', ']', '|' => false,
        else => true,
    };
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// Parse a single DOS path component (already a leaf, no separators) into an 8.3
/// name. Uppercases; splits on the LAST dot; truncates name to 8 / ext to 3;
/// rejects illegal characters by returning null. A name that is exactly "." or
/// ".." returns null (the caller handles dot-dirs separately).
pub fn parse(component: []const u8) ?Name83 {
    if (component.len == 0) return null;
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return null;

    // Find the last dot (the name/ext split). A leading dot is part of the name
    // only if there is no other dot (DOS quirk: ".foo" -> name ".foo" truncated).
    const dot = std.mem.lastIndexOfScalar(u8, component, '.');
    const name_part = if (dot) |d| component[0..d] else component;
    const ext_part = if (dot) |d| component[d + 1 ..] else component[0..0];

    var out: Name83 = .{};
    for (name_part) |c| {
        if (c == '.') return null; // an interior dot in the name part
        if (!isValid83Char(c)) return null;
        if (out.name_len < 8) {
            out.name[out.name_len] = upper(c);
            out.name_len += 1;
        }
        // chars beyond 8 are silently truncated (DOS behavior)
    }
    for (ext_part) |c| {
        if (c == '.') return null;
        if (!isValid83Char(c)) return null;
        if (out.ext_len < 3) {
            out.ext[out.ext_len] = upper(c);
            out.ext_len += 1;
        }
    }
    if (out.name_len == 0) return null;
    return out;
}

/// True if a host filename already FITS the 8.3 form (no munging needed): its
/// uppercased form round-trips. Used to skip `~N` generation for short names.
pub fn fitsShort(host_name: []const u8) bool {
    const parsed = parse(host_name) orelse return false;
    var buf: [12]u8 = undefined;
    const disp = parsed.display(&buf);
    if (disp.len != host_name.len) return false;
    for (disp, host_name) |a, b| {
        if (a != upper(b)) return false;
    }
    return true;
}

/// Generate a deterministic `NAME~N.EXT` short name for a host long name. `n` is
/// the tilde number (1-based), assigned by the caller over a SORTED listing so it
/// is reproducible. The base name is the first up-to-(8 - digits(n) - 1) valid
/// uppercased chars; the ext is the first 3 valid chars after the last dot.
pub fn generateShort(host_name: []const u8, n: u32) Name83 {
    var out: Name83 = .{};

    const dot = std.mem.lastIndexOfScalar(u8, host_name, '.');
    const name_part = if (dot) |d| host_name[0..d] else host_name;
    const ext_part = if (dot) |d| host_name[d + 1 ..] else host_name[0..0];

    // The tilde suffix "~N" costs 1 + digits(n) chars of the 8-char name field.
    var ndigits: u8 = 1;
    var tmp = n;
    while (tmp >= 10) : (tmp /= 10) ndigits += 1;
    const base_room: u8 = if (8 > 1 + ndigits) 8 - 1 - ndigits else 1;

    var bi: u8 = 0;
    for (name_part) |c| {
        if (bi >= base_room) break;
        if (!isValid83Char(c) or c == '.') continue;
        out.name[bi] = upper(c);
        bi += 1;
    }
    // Append "~N".
    out.name[bi] = '~';
    bi += 1;
    var dbuf: [10]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{n}) catch unreachable;
    for (ds) |dc| {
        out.name[bi] = dc;
        bi += 1;
    }
    out.name_len = bi;

    var ei: u8 = 0;
    for (ext_part) |c| {
        if (ei >= 3) break;
        if (!isValid83Char(c) or c == '.') continue;
        out.ext[ei] = upper(c);
        ei += 1;
    }
    out.ext_len = ei;
    return out;
}

/// Wildcard match: does the 11-byte FCB pattern `pat` (with '?' = any, and a '*'
/// already expanded to '?'s by the caller) match the 11-byte FCB name `name`?
pub fn fcbMatch(pat: *const [11]u8, name: *const [11]u8) bool {
    for (pat, name) |p, n| {
        if (p == '?') continue;
        if (p != n) return false;
    }
    return true;
}

/// Expand a DOS wildcard pattern component (e.g. "*.TXT", "FOO?.*") into an
/// 11-byte FCB pattern with '*' -> trailing '?'s in its field.
pub fn wildcardToFcb(pattern: []const u8, out: *[11]u8) void {
    @memset(out, ' ');
    const dot = std.mem.lastIndexOfScalar(u8, pattern, '.');
    const name_part = if (dot) |d| pattern[0..d] else pattern;
    const ext_part = if (dot) |d| pattern[d + 1 ..] else pattern[0..0];
    expandField(name_part, out[0..8]);
    expandField(ext_part, out[8..11]);
}

fn expandField(src: []const u8, field: []u8) void {
    var i: usize = 0;
    for (src) |c| {
        if (i >= field.len) break;
        if (c == '*') {
            while (i < field.len) : (i += 1) field[i] = '?';
            break;
        }
        field[i] = upper(c);
        i += 1;
    }
}
