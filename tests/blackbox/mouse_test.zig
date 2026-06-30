//! Black-box test: drive the REAL Betrayal-at-Krondor cursor path with `MOUSE.EXE`
//! and prove the INT 33h AH=0Ch mouse event callback (Input Phase 3) moves the
//! on-screen cursor to an injected absolute position — end-to-end, over HTTP.
//!
//! WHY THIS IS THE REAL PHASE-3 TEST. `MOUSE.EXE` runs the game's faithful migrated
//! bringup: `video_init(8,…)` (VGA Mode-Y, unchained planar), `mouse_install()`
//! (INT 33h AX=0 detect → installs the game's `_mouse_event_callback` via AX=0Ch
//! with mask 0x1F), loads the POINTER.BMX cursor pack + G_LAMUT.PAL palette, places
//! the cursor at the centre (160,100) via `mouse_set_position`, then loops
//! `cursor_tick()`. Each tick polls `mouse_get_position` (= `g_mouse_x_mickeys >> 2`),
//! the value the AX=0Ch callback latches from CX, and blits the cursor sprite there.
//! So injecting a mouse event between ticks → the callback latches the new position
//! → the next draw-tick paints the cursor there. The capture goes through the Mode-Y
//! PLANAR rasterizer (`render256Planar`, kind=1) — a path LAMUT/TTM (chained mode 13h)
//! never exercised; the cursor sprite is a Mode-Y planar blit.
//!
//! COORDINATE UNITS (load-bearing). The BaK driver works in QUARTER-PIXELS: it
//! programs the INT 33h driver via AX=04/07/08 with `pixel << 2`, latches CX into
//! `g_mouse_x_mickeys`, and reads back `>> 2` to pixels (MOUSE.ASM). zdos's INT 33h
//! driver is faithful to a real Microsoft mouse driver: AX=03/AX=04, `injectAbsolute`,
//! and the AX=0Ch callback CX/DX all round-trip in the SAME driver-virtual units the
//! guest chose — here quarter-pixels. So to land the cursor at screen pixel (px,py)
//! we inject the driver-virtual coordinate `(px*4, py*4)`, exactly as the game's own
//! `mouse_set_position(px,py)` does. (This is NOT a fake rescale — it is the guest's
//! own convention; `PX_TO_DRV` documents it.)
//!
//! Presence-gated: MOUSE.EXE + VMCODE.OVL/POINTER.BMX/G_LAMUT.PAL are BaK
//! data, NOT committed (assets.txt: "Not committed"). Absent → `error.SkipZigTest`.
//!
//! Determinism: the guest advances ONLY on explicit run-to-cycle commands, and the
//! injects happen at fixed cycle boundaries, so the same script reaches byte-identical
//! frames at the same cycles every run (asserted by test 3). No host clock in any
//! assertion.

const std = @import("std");
const Session = @import("session.zig").Session;

const Io = std.Io;

/// Candidate asset dirs, relative to the repo root (= the test cwd). First wins.
const ASSET_DIRS = [_][]const u8{
    "../bak-scratch-area/staging/tests/mouse",
    "../betrayal-at-krondor/c-recon/work/run_mouse",
};

/// Staging work dir (under zig-out, which is git-ignored).
const WORK_DIR = "zig-out/mouse-work";
/// Where the test drops a couple of evidence PNGs.
const SHOTS_DIR = "mouse-shots";

/// Assets the fixture opens (uppercase; the VFS folds guest requests to uppercase).
const ASSETS = [_][]const u8{ "VMCODE.OVL", "POINTER.BMX", "G_LAMUT.PAL" };

/// Mode-Y logical resolution (the cursor sprite is blitted into this surface).
const SCREEN_W: u16 = 320;
const SCREEN_H: u16 = 200;
/// `render256Planar` (Mode-X/Y unchained planar) — `Kind.vga256_planar` == 1.
const KIND_VGA256_PLANAR: u8 = 1;

/// BaK quarter-pixel driver convention: a screen pixel maps to `pixel*4` in the
/// driver-virtual coordinate space the game programmed via INT 33h AX=04/07/08.
inline fn pxToDrv(px: i16) i16 {
    return px * 4;
}

/// The cursor sprite's hot-spot is the top-left (0,0); the visible arrow extends to
/// the RIGHT and DOWN from there (POINTER.BMX shape 0, ~16×9). So when the cursor is
/// at pixel (px,py) the sprite occupies roughly x∈[px-1,px+16], y∈[py-1,py+9]. We
/// count non-background index pixels in that box — a cursor-sized cluster there is
/// proof the cursor was DRAWN at (px,py).
fn spriteCountAt(frame: Session.Frame, px: i16, py: i16) usize {
    const w: usize = frame.width;
    const h: usize = frame.height;
    if (frame.data.len < w * h) return 0;
    const bg = backgroundIndex(frame);
    var count: usize = 0;
    var dy: i16 = -2;
    while (dy <= 10) : (dy += 1) {
        const y = py + dy;
        if (y < 0 or y >= @as(i16, @intCast(h))) continue;
        var dx: i16 = -2;
        while (dx <= 17) : (dx += 1) {
            const x = px + dx;
            if (x < 0 or x >= @as(i16, @intCast(w))) continue;
            const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            if (frame.data[idx] != bg) count += 1;
        }
    }
    return count;
}

/// The background palette index = the most frequent byte in the frame. The Mode-Y
/// page is cleared to a single index; the cursor sprite is the only deviation.
fn backgroundIndex(frame: Session.Frame) u8 {
    var hist = [_]u32{0} ** 256;
    for (frame.data) |b| hist[b] += 1;
    var best: u8 = 0;
    var best_n: u32 = 0;
    for (hist, 0..) |n, i| {
        if (n > best_n) {
            best_n = n;
            best = @intCast(i);
        }
    }
    return best;
}

/// Total non-background pixels (cursor + any artefacts). Pristine ≈ one sprite (~27).
fn totalNonBg(frame: Session.Frame) usize {
    const bg = backgroundIndex(frame);
    var count: usize = 0;
    for (frame.data) |b| {
        if (b != bg) count += 1;
    }
    return count;
}

/// One injected-cursor probe: at `inject_cycle` set the absolute position to (px,py)
/// (in pixels; converted to driver-virtual units), then scan `SCAN_OFFSETS` cycles
/// AFTER the inject SETTLES and return the MAX sprite-count seen at (px,py).
///
/// CALLBACK DWELL (load-bearing for the timing model). The guest registered an INT 33h
/// AX=0Ch event handler (mask 0x1F), so an absolute-position inject that MOVES the
/// cursor FIRES that handler and runs a fixed, deterministic dwell — advancing the
/// machine ~1.43M cycles past `inject_cycle` (the inject HTTP reply is
/// `{"stop":{"dwell_complete":{...}}}`). The cursor stays LATCHED at the injected
/// position afterward. So the scan must be based on the ACTUAL post-inject cycle
/// (`status().cycles`), NOT `inject_cycle` (which is now in the past → run-to-cycle
/// no-ops). Re-injecting the position the cursor already sits at (the centre probe)
/// does NOT move it, so it fires no dwell and the base stays at `inject_cycle`.
const Probe = struct {
    px: i16,
    py: i16,
    inject_cycle: u64,
};

/// Dense scan offsets: every 1000 cycles across 0..15000 (> one full ~14k cursor
/// blink/burst period) relative to the POST-INJECT base. The cursor erases+redraws
/// each tick, so a single capture can land on an erase-frame; and the burst's
/// ≥`HIT_THRESHOLD`-pixel draw window is only ~3k cycles wide and recurs every ~14k,
/// so a COARSE offset set aliases (e.g. 20k spacing can miss every draw-frame at one
/// phase). A dense sweep over a full period makes the windowed MAX reliably catch a
/// draw-frame regardless of the post-inject phase. The schedule is fixed (no host
/// clock), so the result is deterministic.
const SCAN_OFFSETS = blk: {
    var offs: [16]u64 = undefined;
    for (&offs, 0..) |*o, i| o.* = @as(u64, i) * 1000;
    break :blk offs;
};

/// The probe schedule: centre, then two distinct off-centre positions. Each off-centre
/// inject runs the ~1.43M-cycle callback dwell, so the probes are spaced ~1.6M apart
/// (each `inject_cycle` > the prior probe's last scanned cycle ≈ prev_base + 1.43M +
/// max SCAN_OFFSET) AND the last probe's scan (≈10.3M + 1.43M + 15k ≈ 11.75M) finishes
/// well before `TOTAL_CYCLES` (12,096,343) — the program's deterministic termination.
const PROBES = [_]Probe{
    .{ .px = 160, .py = 100, .inject_cycle = 7_000_000 },
    .{ .px = 60, .py = 30, .inject_cycle = 8_700_000 },
    .{ .px = 250, .py = 150, .inject_cycle = 10_300_000 },
};

/// A cursor cluster of at least this many non-bg pixels at the target box counts as
/// "the cursor is drawn there" (the arrow is ~22-27 pixels; an erase-frame is 0).
const HIT_THRESHOLD: usize = 18;

/// MOUSE.EXE terminates here (it runs the bounded 600-tick burst then restores text
/// mode + prints MOUSE-OK). Asserted as a determinism golden in test 1.
const TOTAL_CYCLES: u64 = 12_096_343;

fn resolveCase(io: Io, dir: std.Io.Dir, upper: []const u8, lower: []const u8) ?[]const u8 {
    if (dir.access(io, upper, .{})) |_| return upper else |_| {}
    if (dir.access(io, lower, .{})) |_| return lower else |_| {}
    return null;
}

/// Stage MOUSE.EXE + the BaK assets (uppercase) into WORK_DIR. Returns the staged
/// exe path on success, or `error.SkipZigTest` if any required asset is missing.
fn stageFixture(io: Io, alloc: std.mem.Allocator) ![]const u8 {
    _ = alloc;
    const cwd = std.Io.Dir.cwd();

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
            \\SKIP: MOUSE.EXE / BaK cursor assets not found. Tried (relative to repo root):
            \\  - {s}
            \\  - {s}
            \\These are Betrayal at Krondor data and are not committed.
            \\
        , .{ ASSET_DIRS[0], ASSET_DIRS[1] });
        return error.SkipZigTest;
    }
    var src = asset_dir.?;
    defer src.close(io);

    try cwd.createDirPath(io, WORK_DIR);
    var work = try cwd.openDir(io, WORK_DIR, .{});
    defer work.close(io);

    const exe_src = resolveCase(io, src, "MOUSE.EXE", "mouse.exe") orelse {
        std.debug.print("SKIP: neither MOUSE.EXE nor mouse.exe in {s}\n", .{asset_dir_path});
        return error.SkipZigTest;
    };
    try src.copyFile(exe_src, work, "MOUSE.EXE", io, .{});

    for (ASSETS) |name| {
        // VMCODE.OVL may be lowercase in the staging dir; fold it. The BMX/PAL are
        // uppercase already.
        const lower_buf = lowerName(name);
        const chosen = resolveCase(io, src, name, lower_buf.slice()) orelse {
            std.debug.print("SKIP: required asset {s} missing from {s}\n", .{ name, asset_dir_path });
            return error.SkipZigTest;
        };
        src.copyFile(chosen, work, name, io, .{}) catch |e| {
            std.debug.print("SKIP: cannot stage {s} from {s} ({s})\n", .{ name, asset_dir_path, @errorName(e) });
            return error.SkipZigTest;
        };
    }

    return WORK_DIR ++ "/MOUSE.EXE";
}

/// Lowercase a short DOS name on the stack (for case-insensitive source resolution).
const LowerName = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const LowerName) []const u8 {
        return self.buf[0..self.len];
    }
};
fn lowerName(name: []const u8) LowerName {
    var out: LowerName = .{};
    out.len = @min(name.len, out.buf.len);
    for (name[0..out.len], 0..) |c, i| out.buf[i] = std.ascii.toLower(c);
    return out;
}

/// Capture a Mode-Y index frame at `cycle`, asserting it is the expected planar
/// surface (kind=1, 320×200). Returns the frame (in the session arena).
fn captureAt(s: *Session, cycle: u64) !Session.Frame {
    _ = try s.runToCycle(cycle);
    const f = try s.framebuffer("index");
    try std.testing.expectEqual(std.http.Status.ok, f.status);
    try std.testing.expectEqual(SCREEN_W, f.width);
    try std.testing.expectEqual(SCREEN_H, f.height);
    // The cursor capture goes through the Mode-Y PLANAR rasterizer (not chained 13h).
    try std.testing.expectEqual(KIND_VGA256_PLANAR, f.kind);
    try std.testing.expectEqual(@as(usize, SCREEN_W) * SCREEN_H, f.data.len);
    return f;
}

/// Where (best-effort) cursor evidence PNGs are written.
const PngSink = struct {
    io: Io,
    dir: std.Io.Dir,
};

/// Grab `GET /api/framebuffer?format=png` of the frame the machine is CURRENTLY parked
/// at (the caller has just confirmed it is a draw-frame via `captureAt`) and write it
/// to `<SHOTS_DIR>/cursor_px<px>_<py>.png`. Best-effort: no second inject, no machine
/// advance, so it never perturbs the probe schedule.
fn savePng(s: *Session, sink: PngSink, p: Probe) !void {
    const png = try s.requestRaw(.GET, "/api/framebuffer?format=png", null);
    if (png.status != .ok) return;
    var name_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&name_buf, SHOTS_DIR ++ "/cursor_px{d}_{d}.png", .{ p.px, p.py });
    try sink.dir.writeFile(sink.io, .{ .sub_path = rel, .data = png.body });
}

/// Run the inject-and-scan probe; returns the max sprite-count seen at the target.
/// When `png` is non-null, saves a PNG of the FIRST draw-frame found during the scan
/// (captured in place, since the machine is parked at that exact cycle — no re-inject).
fn probeMaxHit(s: *Session, p: Probe, png: ?PngSink) !usize {
    _ = try s.runToCycle(p.inject_cycle);
    _ = try s.injectMouse(pxToDrv(p.px), pxToDrv(p.py), null, null, null);
    // The inject may have run the fixed AX=0Ch callback dwell (~1.43M cycles); base the
    // scan on the ACTUAL post-inject cycle, not `inject_cycle` (now in the past).
    const base = (try s.status()).cycles;
    var best: usize = 0;
    var saved = false;
    for (SCAN_OFFSETS) |off| {
        const f = try captureAt(s, base + off);
        const c = spriteCountAt(f, p.px, p.py);
        if (c > best) best = c;
        if (!saved and c >= HIT_THRESHOLD) {
            saved = true;
            if (png) |sink| savePng(s, sink, p) catch {};
        }
    }
    return best;
}

test "MOUSE: AH=0Ch callback drives the real BaK cursor to injected positions (Phase 3)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const alloc = std.testing.allocator;

    const exe_path = try stageFixture(io, alloc);

    // ---- Test 1: MOUSE-OK + mouse=1, and the deterministic total-cycle golden. ----
    {
        var s = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
        defer s.deinit();

        // Run to termination (cap safely above the ~12M-cycle burst) and read CON.
        _ = try s.run(50_000_000);
        const st = try s.status();
        try std.testing.expect(st.terminated);
        try std.testing.expectEqual(TOTAL_CYCLES, st.cycles);

        var con_buf: [256]u8 = undefined;
        const con = try s.consoleBytes(&con_buf);
        // The driver reports PRESENT: `MOUSE-OK: adapter=8 mouse=1 cursor=16x9 at(160,100)`.
        try std.testing.expect(std.mem.indexOf(u8, con, "MOUSE-OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, con, "mouse=1") != null);
        try std.testing.expect(std.mem.indexOf(u8, con, "adapter=8") != null);
    }

    // ---- Test 2: the cursor TRACKS each injected absolute position. ----------------
    // A fresh session: at centre, then two distinct off-centre injects. Each must put
    // a cursor-sized cluster at its target (proving the AX=0Ch callback latched and the
    // real per-frame cursor loop drew there).
    var work_dir = std.Io.Dir.cwd();
    work_dir.createDirPath(io, SHOTS_DIR) catch {};
    {
        var s = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
        defer s.deinit();

        // Baseline: the static centre blit is present BEFORE any inject (sanity that
        // the cursor path is live and the capture is the Mode-Y planar surface).
        const base = try captureAt(&s, PROBES[0].inject_cycle - 100_000);
        try std.testing.expect(spriteCountAt(base, 160, 100) >= HIT_THRESHOLD);

        for (PROBES, 0..) |p, i| {
            // Save an evidence PNG of the cursor for the off-centre probes (captured
            // inline at the draw-frame the scan finds — no second inject that would
            // perturb the schedule).
            const sink: ?PngSink = if (i > 0) .{ .io = io, .dir = work_dir } else null;
            const best = try probeMaxHit(&s, p, sink);
            if (best < HIT_THRESHOLD) {
                std.debug.print(
                    "FAIL: injected px({d},{d}) (drv {d},{d}) — max cursor cluster at target = {d} (< {d})\n",
                    .{ p.px, p.py, pxToDrv(p.px), pxToDrv(p.py), best, HIT_THRESHOLD },
                );
            }
            try std.testing.expect(best >= HIT_THRESHOLD);
        }
    }

    // ---- Test 3: DETERMINISM — the same inject script yields byte-identical frames. -
    // Two independent sessions run the identical schedule; the index frame captured at
    // the SAME cycle after the SAME inject must be byte-for-byte equal. (If the API or
    // the callback perturbed emulation timing/state, these would differ.)
    {
        const probe = PROBES[2]; // the lower-right off-centre position

        // Session A: inject, then find the first scan offset that is a DRAW-frame (the
        // cursor blinks; the post-inject base + that offset is the absolute draw cycle).
        var a = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
        defer a.deinit();
        _ = try a.runToCycle(probe.inject_cycle);
        _ = try a.injectMouse(pxToDrv(probe.px), pxToDrv(probe.py), null, null, null);
        const base = (try a.status()).cycles;

        var draw_cycle: u64 = 0;
        var found = false;
        var a_bytes: []u8 = &.{};
        for (SCAN_OFFSETS) |off| {
            const fa = try captureAt(&a, base + off);
            if (spriteCountAt(fa, probe.px, probe.py) >= HIT_THRESHOLD) {
                draw_cycle = base + off;
                // Copy out of the session arena (a's next request would reset it).
                a_bytes = try alloc.dupe(u8, fa.data);
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
        defer alloc.free(a_bytes);

        // Session B runs the IDENTICAL script. The callback dwell is deterministic, so
        // B reaches the SAME post-inject base; capturing at the SAME absolute draw cycle
        // must yield a byte-for-byte equal frame (proves the API/callback did not perturb
        // emulation timing or state).
        var b = try Session.spawnArgs(alloc, io, exe_path, &.{"headless"});
        defer b.deinit();
        _ = try b.runToCycle(probe.inject_cycle);
        _ = try b.injectMouse(pxToDrv(probe.px), pxToDrv(probe.py), null, null, null);
        try std.testing.expectEqual(base, (try b.status()).cycles);
        const fb = try captureAt(&b, draw_cycle);

        try std.testing.expectEqualSlices(u8, a_bytes, fb.data);
        // And the cursor really is at the injected position in that frame.
        try std.testing.expect(spriteCountAt(fb, probe.px, probe.py) >= HIT_THRESHOLD);
    }
}
