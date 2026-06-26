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

// Leaf resolution must be case-insensitive / 8.3-munged just like directory
// components — mirroring DOSBox's GetExpandNameAndNormaliseCase, which resolves
// the leaf through the SAME GetLongName as each directory component (no leaf
// shortcut; on a miss the buffer keeps the DOS-supplied uppercased name).

test "leaf open: lowercase host file resolves via uppercased DOS name" {
    var td = std.testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();
    // Create the host file with a lowercase name DIRECTLY (not via the VFS, which
    // would uppercase it) so the leaf lookup must fold case to find it.
    {
        const f = try td.dir.createFile(std.testing.io, "krondor.exe", .{});
        f.close(std.testing.io);
    }
    var drive = dos.Vfs.HostDirDrive.init(td.dir, std.testing.io);

    // DOS looks up the uppercased 8.3 name; it must resolve to the lowercase host.
    const hf = try drive.open("KRONDOR.EXE", .read_only);
    drive.close(hf);
    const st = try drive.stat("KRONDOR.EXE");
    try std.testing.expect(!st.is_dir);
}

test "leaf open: long-named host file resolves via its ~N short name" {
    var td = std.testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();
    // A >8.3 host name; its deterministic short form is LONGFI~1.TXT.
    {
        const f = try td.dir.createFile(std.testing.io, "longfilename.txt", .{});
        f.close(std.testing.io);
    }
    var drive = dos.Vfs.HostDirDrive.init(td.dir, std.testing.io);

    const hf = try drive.open("LONGFI~1.TXT", .read_only);
    drive.close(hf);
    const st = try drive.stat("LONGFI~1.TXT");
    try std.testing.expect(!st.is_dir);
}

test "leaf open: uppercase host file still resolves (no regression)" {
    var td = std.testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();
    {
        const f = try td.dir.createFile(std.testing.io, "RETAIL.EXE", .{});
        f.close(std.testing.io);
    }
    var drive = dos.Vfs.HostDirDrive.init(td.dir, std.testing.io);

    const hf = try drive.open("RETAIL.EXE", .read_only);
    drive.close(hf);
}

test "leaf create: absent name uses the uppercased literal (create-new path)" {
    var td = std.testing.tmpDir(.{ .iterate = true });
    defer td.cleanup();
    var drive = dos.Vfs.HostDirDrive.init(td.dir, std.testing.io);

    // A genuinely-absent leaf: findChild returns null, so the resolved host name
    // is the uppercased 8.3 literal (DOSBox: GetLongName -1 keeps that name).
    const hf = try drive.create("newfile.dat");
    drive.close(hf);
    // The host file must exist under the UPPERCASED name, not the lowercase input.
    const up = try td.dir.statFile(std.testing.io, "NEWFILE.DAT", .{});
    try std.testing.expect(up.kind == .file);
    try std.testing.expectError(error.FileNotFound, td.dir.statFile(std.testing.io, "newfile.dat", .{}));
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
