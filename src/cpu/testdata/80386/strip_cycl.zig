//! One-shot vendoring tool: read a SingleStepTests/80386 *.MOO.gz file, parse
//! the MOO chunk tree, DROP the per-test `CYCL` chunk (a bus-cycle trace that
//! zdos explicitly does NOT assert — see plans/cpu.md D8: assert state, not
//! bus-cycles), re-emit a compact MOO file, and gzip it.
//!
//! This is faithful: it removes ONLY the cycle-trace chunk we never compare;
//! every register/flag/memory/name/bytes/hash field is preserved byte-for-byte.
//! It shrinks the vendored corpus from ~579 MB to a repo-friendly size.
//!
//! Usage: strip_cycl <in.MOO.gz> <out.MOO.gz>

const std = @import("std");

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,
    fn rem(self: Cursor) usize {
        return self.data.len - self.pos;
    }
    fn readU32(self: *Cursor) !u32 {
        if (self.rem() < 4) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn id(self: *Cursor) ![4]u8 {
        if (self.rem() < 4) return error.Truncated;
        const v = self.data[self.pos..][0..4].*;
        self.pos += 4;
        return v;
    }
    fn slice(self: *Cursor, n: usize) ![]const u8 {
        if (self.rem() < n) return error.Truncated;
        const v = self.data[self.pos..][0..n];
        self.pos += n;
        return v;
    }
};

fn emitChunk(out: *std.ArrayList(u8), a: std.mem.Allocator, ty: []const u8, body: []const u8) !void {
    try out.appendSlice(a, ty);
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, @intCast(body.len), .little);
    try out.appendSlice(a, &lb);
    try out.appendSlice(a, body);
}

/// Rebuild a TEST body, dropping any CYCL subchunk.
fn stripTest(a: std.mem.Allocator, body: []const u8) ![]u8 {
    var c = Cursor{ .data = body };
    var out: std.ArrayList(u8) = .empty;
    const index = try c.readU32();
    var ib: [4]u8 = undefined;
    std.mem.writeInt(u32, &ib, index, .little);
    try out.appendSlice(a, &ib);
    while (c.rem() >= 8) {
        const ty = try c.id();
        const len = try c.readU32();
        const sub = try c.slice(len);
        if (std.mem.eql(u8, &ty, "CYCL")) continue; // drop (not asserted, D8)
        try emitChunk(&out, a, &ty, sub);
    }
    return out.toOwnedSlice(a);
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    const in_path = args.next() orelse return error.BadArgs;
    const out_path = args.next() orelse return error.BadArgs;
    // Optional 3rd arg: max number of TEST chunks to keep (subsample). 0/absent = all.
    const max_tests: usize = if (args.next()) |s| (std.fmt.parseInt(usize, s, 10) catch 0) else 0;

    // Read + gunzip input.
    const gz = try std.Io.Dir.cwd().readFileAlloc(io, in_path, a, .limited(1 << 30));
    defer a.free(gz);
    var in_reader: std.Io.Reader = .fixed(gz);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in_reader, .gzip, &decompress_buf);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    _ = try decompress.reader.streamRemaining(&aw.writer);
    const data = aw.writer.buffered();

    // Parse top-level: "MOO " + u32 hdr_len + hdr, then chunks.
    var c = Cursor{ .data = data };
    const magic = try c.id();
    if (!std.mem.eql(u8, &magic, "MOO ")) return error.BadMagic;
    const hdr_len = try c.readU32();
    const hdr = try c.slice(hdr_len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "MOO ");
    var hb: [4]u8 = undefined;
    std.mem.writeInt(u32, &hb, @intCast(hdr.len), .little);
    try out.appendSlice(a, &hb);
    try out.appendSlice(a, hdr);

    var test_count: usize = 0;
    while (c.rem() >= 8) {
        const ty = try c.id();
        const len = try c.readU32();
        const body = try c.slice(len);
        if (std.mem.eql(u8, &ty, "TEST")) {
            if (max_tests != 0 and test_count >= max_tests) continue; // subsample cap
            test_count += 1;
            const stripped = try stripTest(a, body);
            defer a.free(stripped);
            try emitChunk(&out, a, "TEST", stripped);
        } else {
            try emitChunk(&out, a, &ty, body);
        }
    }

    // gzip the output into an in-memory buffer, then write it out via posix.
    var gzout: std.Io.Writer.Allocating = try .initCapacity(a, 64 * 1024);
    defer gzout.deinit();
    var comp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&gzout.writer, &comp_buf, .gzip, .level_9);
    try compress.writer.writeAll(out.items);
    try compress.finish();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = gzout.writer.buffered() });
}
