//! Black-box test: play the Betrayal at Krondor TTM Chapter-1 movie end-to-end on
//! the REAL `zdos --serve 0 TTM.EXE headless` server, break at 10/25/50/75/90% of the
//! deterministic total run (by CPU cycle), and capture a PNG screenshot at each via
//! `GET /api/framebuffer?format=png`.
//!
//! Presence-gated: the TTM/BMX/PAL/OVL assets are copyrighted BaK data and are NOT
//! committed. If they are absent the test SKIPS honestly (`error.SkipZigTest`) — it
//! never fabricates a pass or a screenshot.
//!
//! Determinism: the movie terminates at a fixed cycle count T; the five percentages
//! map to fixed target cycles, so the same frames are captured every run. No host
//! clock enters any assertion.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/Io/Dir.zig`):
//!   - `std.Io.Dir.cwd().access(io, sub_path, .{})` (`Io/Dir.zig:438`) — asset probe.
//!   - `Dir.createDirPath(io, sub_path)` (`Io/Dir.zig:843`) — the 0.16 `makePath`.
//!   - `Dir.copyFile(src, src_path, dst, dst_path, io, .{})` (`Io/Dir.zig:1809`).
//!   - `Dir.writeFile(io, .{ .sub_path, .data })` (`Io/Dir.zig:658`).
//!   - `Dir.realPathFileAlloc(io, sub_path, alloc)` (`Io/Dir.zig:944`) — the 0.16
//!     `realpathAlloc`; returns an owned, NUL-terminated absolute path.

const std = @import("std");
const Session = @import("session.zig").Session;

const Io = std.Io;

/// Candidate asset directories, relative to the repo root (= the test cwd). The first
/// that exists wins.
const ASSET_DIRS = [_][]const u8{
    "../bak-scratch-area/staging/tests/ttm",
    "../betrayal-at-krondor/c-recon/work/run_ttm",
};

/// The staging work dir (under zig-out, which is git-ignored).
const WORK_DIR = "zig-out/ttm-work";
const SHOTS_DIR = "ttm-shots";

/// Assets copied verbatim (already uppercase in the source dirs).
const VERBATIM = [_][]const u8{
    "C11.ADS",   "C11.TTM",  "C11.SCX",  "C11A.PAL", "C11A1.BMX",
    "C11A2.BMX", "C11B.PAL", "C11B.BMX", "GAME.FNT", "POINTER.BMX",
};

/// The PNG 8-byte signature.
const PNG_SIG = [8]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Determinism goldens. The movie is fully deterministic (no host clock in the
/// emulated time base), so the total cycle count and EVERY captured frame are
/// byte-identical on every run. We pin the SHA-256 of each PNG (and its size), NOT
/// the PNG file itself: the frames are copyrighted BaK-derived pixels, so a hash is
/// the committable, copyright-safe golden. If the emulator/rasterizer/PNG-encoder
/// changes intentionally, regenerate: run the test, then `sha256sum ttm-shots/*.png`.
const TOTAL_CYCLES: u64 = 164_124_359;

const Golden = struct {
    pct: u64,
    cycle: u64, // == TOTAL_CYCLES * pct / 100 (integer)
    bytes: usize, // exact PNG size in bytes
    sha256: []const u8, // SHA-256 of the captured PNG, lowercase hex
};
const GOLDENS = [_]Golden{
    .{ .pct = 10, .cycle = 16_412_435, .bytes = 11054, .sha256 = "c09a927fc17c6cda775304426bf986964075464d7cf9e48452da6e344d840559" },
    .{ .pct = 25, .cycle = 41_031_089, .bytes = 11054, .sha256 = "639bc5d71c79fbd4dcfb2d5a91b35b214009e4664a82d3f14be0ebeffa809a77" },
    .{ .pct = 50, .cycle = 82_062_179, .bytes = 7181, .sha256 = "d336cb439455c6b5e113b983f5c56c5ad90e778ff6864fa85bcb5e8c79b3aac7" },
    .{ .pct = 75, .cycle = 123_093_269, .bytes = 8422, .sha256 = "492ac56607700e3cc1c1d52f5f5610d17d8509b22ca82e68ce9c2a81bdd9f9ef" },
    .{ .pct = 90, .cycle = 147_711_923, .bytes = 8422, .sha256 = "17ec03b4bf5f9d191976f2882d93827b89c7ea1327fe8657745456b0d39ded38" },
};

/// Resolve the case of `name` in `dir`: returns `upper` if present, else `lower` if
/// present, else null (source dirs may ship the exe/ovl lowercase or uppercase).
fn resolveCase(io: Io, dir: std.Io.Dir, upper: []const u8, lower: []const u8) ?[]const u8 {
    if (dir.access(io, upper, .{})) |_| return upper else |_| {}
    if (dir.access(io, lower, .{})) |_| return lower else |_| {}
    return null;
}

test "TTM: play Chapter-1 movie, screenshot at 10/25/50/75/90% by cycle" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const alloc = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    // ---- Step 1: locate the asset dir (first that exists). ----------------------
    var asset_dir: ?std.Io.Dir = null;
    var asset_dir_path: []const u8 = undefined;
    for (ASSET_DIRS) |cand| {
        const d = cwd.openDir(io, cand, .{}) catch continue;
        asset_dir = d;
        asset_dir_path = cand;
        break;
    }
    if (asset_dir == null) {
        std.debug.print(
            \\
            \\SKIP: TTM movie assets not found. Tried (relative to repo root):
            \\  - {s}
            \\  - {s}
            \\These are copyrighted Betrayal at Krondor data and are not committed.
            \\
        , .{ ASSET_DIRS[0], ASSET_DIRS[1] });
        return error.SkipZigTest;
    }
    var src = asset_dir.?;
    defer src.close(io);

    // ---- Step 2: stage into the work dir (uppercase DOS names). -----------------
    try cwd.createDirPath(io, WORK_DIR);
    var work = try cwd.openDir(io, WORK_DIR, .{});
    defer work.close(io);

    // The exe + ovl may be lowercase in the source dir — fold to the uppercase the
    // VFS expects. If a required source file is missing, skip honestly.
    const exe_src = resolveCase(io, src, "TTM.EXE", "ttm.exe") orelse {
        std.debug.print("SKIP: neither TTM.EXE nor ttm.exe in {s}\n", .{asset_dir_path});
        return error.SkipZigTest;
    };
    const ovl_src = resolveCase(io, src, "VMCODE.OVL", "vmcode.ovl") orelse {
        std.debug.print("SKIP: neither VMCODE.OVL nor vmcode.ovl in {s}\n", .{asset_dir_path});
        return error.SkipZigTest;
    };
    try src.copyFile(exe_src, work, "TTM.EXE", io, .{});
    try src.copyFile(ovl_src, work, "VMCODE.OVL", io, .{});
    for (VERBATIM) |name| {
        src.copyFile(name, work, name, io, .{}) catch |e| {
            std.debug.print("SKIP: required asset {s} missing from {s} ({s})\n", .{ name, asset_dir_path, @errorName(e) });
            return error.SkipZigTest;
        };
    }

    const exe_path = WORK_DIR ++ "/TTM.EXE";

    // ---- Step 3: measure the deterministic total cycle count T. -----------------
    var total: u64 = undefined;
    {
        var s = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
        defer s.deinit();
        // Cap safely above the ~164M-cycle movie.
        _ = try s.run(400_000_000);
        const st = try s.status();
        try std.testing.expect(st.terminated);
        // Determinism golden: the movie always terminates at the exact same cycle.
        try std.testing.expectEqual(TOTAL_CYCLES, st.cycles);
        total = st.cycles;
    }
    std.debug.print("\nTTM movie total cycles T = {d} (golden {d})\n", .{ total, TOTAL_CYCLES });

    // ---- Step 4: fresh session, capture a PNG at each percentage. ---------------
    try cwd.createDirPath(io, SHOTS_DIR);

    var s = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
    defer s.deinit();

    for (GOLDENS) |g| {
        const target = total * g.pct / 100;
        // The percentage maps to the exact golden cycle (T is pinned above).
        try std.testing.expectEqual(g.cycle, target);
        // run-to-cycle targets are monotonically increasing (10<25<50<75<90), so one
        // fresh session suffices — no reset between captures.
        _ = try s.runToCycle(target);

        const r = try s.requestRaw(.GET, "/api/framebuffer?format=png", null);
        try std.testing.expectEqual(std.http.Status.ok, r.status);
        try std.testing.expect(r.body.len >= PNG_SIG.len);
        try std.testing.expectEqualSlices(u8, &PNG_SIG, r.body[0..PNG_SIG.len]);
        const byte_len = r.body.len;

        // Determinism golden: the captured PNG must match the pinned size + SHA-256
        // byte-for-byte. (Same machine state at cycle N ⇒ same frame ⇒ same PNG.)
        try std.testing.expectEqual(g.bytes, byte_len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(r.body, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(g.sha256, &hex);

        // Write the body to a file BEFORE the next request (the session arena resets
        // on the next requestRaw, freeing `r.body`).
        var name_buf: [128]u8 = undefined;
        const rel = try std.fmt.bufPrint(&name_buf, SHOTS_DIR ++ "/ttm_p{d:0>2}_c{d}.png", .{ g.pct, target });
        try cwd.writeFile(io, .{ .sub_path = rel, .data = r.body });

        const abs = try cwd.realPathFileAlloc(io, rel, alloc);
        defer alloc.free(abs);
        std.debug.print("  p{d:0>2}%  cycle={d:>12}  bytes={d:>7}  sha256-OK  {s}\n", .{ g.pct, target, byte_len, abs });
    }
}
