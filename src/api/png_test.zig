//! Unit tests for the host-side PNG encoder (`src/api/png.zig`) + the determinism
//! boundary guard (§7). No machine, no socket — pure encode + std-decompress round-trip.

const std = @import("std");
const png = @import("png.zig");
const flate = std.compress.flate;

// ---------------------------------------------------------------------------
// Chunk-walk helpers — parse the encoded byte stream the way a PNG reader would.
// ---------------------------------------------------------------------------

const Chunk = struct { ctype: [4]u8, data: []const u8 };

const ChunkWalker = struct {
    bytes: []const u8,
    pos: usize,

    fn init(bytes: []const u8) !ChunkWalker {
        try std.testing.expectEqualSlices(u8, &png.signature, bytes[0..8]);
        return .{ .bytes = bytes, .pos = 8 };
    }

    fn next(self: *ChunkWalker) !?Chunk {
        if (self.pos >= self.bytes.len) return null;
        const len = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        const ctype: [4]u8 = self.bytes[self.pos + 4 ..][0..4].*;
        const data = self.bytes[self.pos + 8 ..][0..len];
        const crc_stored = std.mem.readInt(u32, self.bytes[self.pos + 8 + len ..][0..4], .big);
        // Recompute the chunk CRC over type+data and assert it matches.
        var crc = std.hash.Crc32.init();
        crc.update(&ctype);
        crc.update(data);
        try std.testing.expectEqual(crc_stored, crc.final());
        self.pos += 12 + len;
        return .{ .ctype = ctype, .data = data };
    }
};

/// Decompress a zlib IDAT stream into `out`, returning the recovered (filtered) bytes.
fn inflate(idat: []const u8, out: []u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&reader, .zlib, &window);
    const n = try dec.reader.readSliceShort(out);
    return out[0..n];
}

// ---------------------------------------------------------------------------
// encodeIndexed
// ---------------------------------------------------------------------------

test "encodeIndexed: signature, IHDR/PLTE/IDAT/IEND chunks, CRCs, round-trip" {
    const alloc = std.testing.allocator;
    const work = try alloc.create(png.Workspace);
    defer alloc.destroy(work);
    work.* = .{};

    // 2x2 indexed image, 4 distinct indices into a known palette.
    const w: u32 = 2;
    const h: u32 = 2;
    const indices = [_]u8{ 0, 1, 2, 3 };
    var palette: [256]png.Rgb = undefined;
    for (&palette, 0..) |*p, i| p.* = .{ .r = @intCast(i & 0xFF), .g = @intCast((i *% 2) & 0xFF), .b = @intCast((i *% 3) & 0xFF) };

    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try png.encodeIndexed(&out, work, w, h, &indices, &palette);
    const bytes = out.buffered();

    var walker = try ChunkWalker.init(bytes);
    const ihdr = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IHDR", &ihdr.ctype);
    try std.testing.expectEqual(@as(u32, w), std.mem.readInt(u32, ihdr.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, h), std.mem.readInt(u32, ihdr.data[4..8], .big));
    try std.testing.expectEqual(@as(u8, 8), ihdr.data[8]); // bit depth
    try std.testing.expectEqual(@as(u8, 3), ihdr.data[9]); // color type indexed

    const plte = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "PLTE", &plte.ctype);
    try std.testing.expectEqual(@as(usize, 768), plte.data.len);
    // PLTE[0] is palette[0] (r,g,b).
    try std.testing.expectEqual(palette[0].r, plte.data[0]);
    try std.testing.expectEqual(palette[1].g, plte.data[3 + 1]);

    const idat = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IDAT", &idat.ctype);

    const iend = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IEND", &iend.ctype);
    try std.testing.expectEqual(@as(usize, 0), iend.data.len);
    try std.testing.expectEqual(@as(?Chunk, null), try walker.next());

    // Round-trip: inflate IDAT, strip the per-row filter byte, recover the indices.
    var raw: [256]u8 = undefined;
    const filtered = try inflate(idat.data, &raw);
    try std.testing.expectEqual(@as(usize, h * (1 + w)), filtered.len);
    var ri: usize = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        try std.testing.expectEqual(@as(u8, 0), filtered[ri]); // filter type None
        ri += 1;
        try std.testing.expectEqualSlices(u8, indices[row * w ..][0..w], filtered[ri .. ri + w]);
        ri += w;
    }
}

test "encodeIndexed: IEND has the canonical fixed CRC AE 42 60 82" {
    const alloc = std.testing.allocator;
    const work = try alloc.create(png.Workspace);
    defer alloc.destroy(work);
    work.* = .{};
    const indices = [_]u8{0};
    var palette: [256]png.Rgb = std.mem.zeroes([256]png.Rgb);
    var buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try png.encodeIndexed(&out, work, 1, 1, &indices, &palette);
    const bytes = out.buffered();
    // The last 12 bytes are the IEND chunk: len=0 (4) + "IEND" (4) + fixed CRC (4).
    const tail = bytes[bytes.len - 12 ..];
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D' }, tail[0..8]);
    const crc = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 0xAE426082), crc);
}

// ---------------------------------------------------------------------------
// encodeRgb
// ---------------------------------------------------------------------------

test "encodeRgb: IHDR color type 2, alpha dropped, round-trip" {
    const alloc = std.testing.allocator;
    const work = try alloc.create(png.Workspace);
    defer alloc.destroy(work);
    work.* = .{};

    const w: u32 = 3;
    const h: u32 = 2;
    // 6 pixels, RGBA. Alpha varies (and must be dropped).
    var rgba: [6 * 4]u8 = undefined;
    for (0..6) |i| {
        rgba[i * 4 + 0] = @intCast(i * 10);
        rgba[i * 4 + 1] = @intCast(i * 20);
        rgba[i * 4 + 2] = @intCast(i * 30);
        rgba[i * 4 + 3] = @intCast(i); // alpha — dropped
    }

    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try png.encodeRgb(&out, work, w, h, &rgba);
    const bytes = out.buffered();

    var walker = try ChunkWalker.init(bytes);
    const ihdr = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IHDR", &ihdr.ctype);
    try std.testing.expectEqual(@as(u8, 2), ihdr.data[9]); // color type RGB
    const idat = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IDAT", &idat.ctype);
    const iend = (try walker.next()).?;
    try std.testing.expectEqualSlices(u8, "IEND", &iend.ctype);

    // Round-trip: inflate, strip filter byte, recovered RGB == input with alpha dropped.
    var raw: [256]u8 = undefined;
    const filtered = try inflate(idat.data, &raw);
    const stride = w * 3;
    try std.testing.expectEqual(@as(usize, h * (1 + stride)), filtered.len);
    var ri: usize = 0;
    var px: u32 = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        try std.testing.expectEqual(@as(u8, 0), filtered[ri]);
        ri += 1;
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            try std.testing.expectEqual(rgba[px * 4 + 0], filtered[ri + 0]);
            try std.testing.expectEqual(rgba[px * 4 + 1], filtered[ri + 1]);
            try std.testing.expectEqual(rgba[px * 4 + 2], filtered[ri + 2]);
            ri += 3;
            px += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Determinism: two encodes of the same input -> byte-identical PNG (§7).
// ---------------------------------------------------------------------------

test "encodeIndexed is deterministic (two runs byte-identical)" {
    const alloc = std.testing.allocator;
    const work = try alloc.create(png.Workspace);
    defer alloc.destroy(work);
    work.* = .{};

    const w: u32 = 16;
    const h: u32 = 16;
    var indices: [256]u8 = undefined;
    for (&indices, 0..) |*p, i| p.* = @intCast((i * 7) & 0xFF);
    var palette: [256]png.Rgb = undefined;
    for (&palette, 0..) |*p, i| p.* = .{ .r = @intCast(i & 0xFF), .g = 0, .b = 0 };

    var b1: [8192]u8 = undefined;
    var b2: [8192]u8 = undefined;
    var o1: std.Io.Writer = .fixed(&b1);
    var o2: std.Io.Writer = .fixed(&b2);
    try png.encodeIndexed(&o1, work, w, h, &indices, &palette);
    work.* = .{}; // fresh workspace, same input
    try png.encodeIndexed(&o2, work, w, h, &indices, &palette);
    try std.testing.expectEqualSlices(u8, o1.buffered(), o2.buffered());
}

// ---------------------------------------------------------------------------
// Determinism boundary guard (§7): png.zig reads no cpu.st.cycles and is NOT in
// the devices grep-gate; the encoder uses no host clock / RNG / float.
// ---------------------------------------------------------------------------

test "png.zig: no cpu.st.cycles read, no host clock/RNG/float (boundary guard)" {
    const src = @embedFile("png.zig");
    const forbidden = [_][]const u8{
        "cpu.st.cycles",
        "st.cycles",
        "std.time",
        "std.Random",
        "std.rand",
        "f32",
        "f64",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) {
            std.debug.print("forbidden pattern '{s}' in png.zig (determinism boundary)\n", .{needle});
            return error.ForbiddenInEncoder;
        }
    }
}

test "png.zig is NOT listed in the src/devices grep-gate (pit_test.zig)" {
    // The encoder is host code (module `api`, above `devices`) — it must stay out of the
    // device sources that pit_test.zig embeds + scans. Assert the gate does not name it.
    // `@embedFile` cannot reach outside the `api` package, so read it at runtime from the
    // repo root (the build/test cwd). Skip gracefully if the source layout differs.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const gate = std.Io.Dir.cwd().readFileAlloc(io, "src/devices/pit_test.zig", alloc, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer alloc.free(gate);
    try std.testing.expect(std.mem.indexOf(u8, gate, "png.zig") == null);
}
