//! 8.3 munging tests (D10) — re-derived from the documented DOS rules + the
//! dosbox-test-suite behavioral spec (NOT copied from GPL code). Covers uppercase,
//! name/ext split, illegal-char handling, and DETERMINISTIC ~N generation.

const std = @import("std");
const name83 = @import("dos").name83;

test "uppercase + split on the last dot" {
    const n = name83.parse("file.txt").?;
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("FILE.TXT", n.display(&buf));
}

test "truncate name to 8 and ext to 3" {
    const n = name83.parse("longfilename.extra").?;
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("LONGFILE.EXT", n.display(&buf));
}

test "no extension" {
    const n = name83.parse("readme").?;
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("README", n.display(&buf));
}

test "illegal characters are rejected" {
    try std.testing.expect(name83.parse("a*b.txt") == null);
    try std.testing.expect(name83.parse("a?b") == null);
    try std.testing.expect(name83.parse("a:b") == null);
    try std.testing.expect(name83.parse(".") == null);
    try std.testing.expect(name83.parse("..") == null);
}

test "FCB 11-byte form is space-padded" {
    const n = name83.parse("ab.c").?;
    var fcb: [11]u8 = undefined;
    n.fcb(&fcb);
    try std.testing.expectEqualStrings("AB      C  ", &fcb);
}

test "wildcard expansion: *.TXT" {
    var fcb: [11]u8 = undefined;
    name83.wildcardToFcb("*.txt", &fcb);
    // '*' fills the 8-char name field with '?'; the ext is "TXT".
    try std.testing.expectEqualStrings("????????TXT", &fcb);
}

test "fcbMatch honours ? wildcards" {
    var pat: [11]u8 = undefined;
    name83.wildcardToFcb("*.*", &pat);
    var nm: [11]u8 = undefined;
    name83.parse("hello.exe").?.fcb(&nm);
    try std.testing.expect(name83.fcbMatch(&pat, &nm));

    var pat2: [11]u8 = undefined;
    name83.wildcardToFcb("*.txt", &pat2);
    try std.testing.expect(!name83.fcbMatch(&pat2, &nm)); // .exe != .txt
}

test "deterministic ~N short-name generation (same input -> same output)" {
    const a = name83.generateShort("averylongname.text", 1);
    const b = name83.generateShort("averylongname.text", 1);
    var ba: [12]u8 = undefined;
    var bb: [12]u8 = undefined;
    try std.testing.expectEqualStrings(a.display(&ba), b.display(&bb));
    // "AVERLO~1.TEX" style: 8-char field with the ~1 suffix, 3-char ext.
    try std.testing.expect(a.name_len <= 8);
    try std.testing.expect(a.ext_len <= 3);
    try std.testing.expect(std.mem.indexOfScalar(u8, a.name[0..a.name_len], '~') != null);
}

test "fitsShort detects already-8.3 names" {
    try std.testing.expect(name83.fitsShort("FILE.TXT"));
    try std.testing.expect(name83.fitsShort("file.txt")); // case-insensitive fit
    try std.testing.expect(!name83.fitsShort("averylongname.text"));
}
