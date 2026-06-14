//! DOS-layer unit tests: the VFS round-trip, the char-device layer, EMS, and
//! the MCB chain — exercised directly (no CPU) where that isolates the unit.

const std = @import("std");
const dos = @import("dos");

test "HostDirDrive create/write/read/seek round-trip (direct VFS)" {
    var td = std.testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();
    var drive = dos.Vfs.HostDirDrive.init(td.dir, std.testing.io);

    const hf = try drive.create("FOO.DAT");
    const wrote = try drive.writeAt(hf, 0, "HELLO!");
    try std.testing.expectEqual(@as(usize, 6), wrote);
    drive.close(hf);

    const rf = try drive.open("FOO.DAT", .read_only);
    defer drive.close(rf);
    var buf: [6]u8 = undefined;
    const n = try drive.readAt(rf, 0, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("HELLO!", &buf);

    var b2: [2]u8 = undefined;
    const n2 = try drive.readAt(rf, 0, &b2); // seek back to 0
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqualStrings("HE", &b2);

    try std.testing.expectEqual(@as(u64, 6), try drive.size(rf));
}

test "char-device CON write records output; NUL discards" {
    var t = dos.DeviceTable{};
    _ = t.con.write("abc");
    try std.testing.expectEqualStrings("abc", t.con.output());
    _ = t.nul.write("ignored");
    try std.testing.expectEqual(@as(usize, 0), t.nul.output().len);
    // EMMXXXX0 resolves by name (the EMS presence probe).
    try std.testing.expect(t.resolve("EMMXXXX0") != null);
    try std.testing.expect(t.resolve("CON") != null);
    try std.testing.expect(t.resolve("NOTADEVICE") == null);
}

// ---------------------------------------------------------------------------
// Phase 9 audit grep (D6/D13): no host time / RNG / thread / env / host file
// timestamp in src/dos/. Needles are built from bytes so this check list does
// not match its own source. The `io: Io` file API is allowed (content is fixed
// input); its TIMING never reaches the ledger (the cost is synthetic, D5).
// ---------------------------------------------------------------------------
test "no host-time / RNG / thread / mtime in the DOS sources (grep)" {
    const sources = [_][]const u8{
        @embedFile("dos.zig"),
        @embedFile("int21.zig"),
        @embedFile("vfs.zig"),
        @embedFile("loader.zig"),
        @embedFile("ems.zig"),
        @embedFile("clock.zig"),
        @embedFile("devices.zig"),
        @embedFile("sft.zig"),
        @embedFile("psp.zig"),
        @embedFile("mcb.zig"),
        @embedFile("dta.zig"),
        @embedFile("name83.zig"),
        @embedFile("int33.zig"),
    };
    const needles = [_][]const u8{
        &[_]u8{ 's', 't', 'd', '.', 't', 'i', 'm', 'e' },
        &[_]u8{ 's', 't', 'd', '.', 'R', 'a', 'n', 'd', 'o', 'm' },
        &[_]u8{ 's', 't', 'd', '.', 'T', 'h', 'r', 'e', 'a', 'd' },
        &[_]u8{ 'g', 'e', 't', 'e', 'n', 'v' },
        &[_]u8{ 'm', 't', 'i', 'm', 'e' },
        &[_]u8{ 'c', 't', 'i', 'm', 'e' },
    };
    for (sources) |src| {
        for (needles) |needle| {
            if (std.mem.indexOf(u8, src, needle) != null) {
                std.debug.print("forbidden host-dependence needle '{s}' found\n", .{needle});
                return error.ForbiddenHostDependence;
            }
        }
    }
}
