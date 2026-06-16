//! Host-side PNG encoder for the screenshot API (`GET /api/framebuffer?format=png`).
//!
//! Placement / determinism boundary (plans/screenshot-api.md §3.1, §5): this module
//! lives in `src/api/` (module `api`, ABOVE `devices` in the module graph). It is an
//! OBSERVATION layer — it encodes a finished, immutable framebuffer snapshot the
//! existing pure `framebuffer_get` peek produced. It:
//!   - is NEVER imported by `src/devices/` (and is NOT in the `pit_test.zig` grep-gate),
//!   - charges NO cycle and reads NO emulated cycle counter,
//!   - uses NO host clock, NO RNG, NO float, NO thread feedback into emulation.
//! So the PNG bytes are a pure, byte-identical function of the captured frame
//! (deflate is deterministic for a fixed input + fixed options).
//!
//! Encoding faithfulness (§6): the PNG is a LOSSLESS re-encode of the real rasterized
//! frame (index image + the actual DAC palette via the pinned `expand6to8`). It invents
//! no pixels. An unsupported mode is rejected upstream as a 501 — never a fake frame.
//!
//! The PNG byte stream (§3.5): signature, IHDR, [PLTE for indexed], IDAT, IEND.
//!   - IDAT payload IS `std.compress.flate.Compress` output with `container = .zlib`
//!     (the `78 9C` header + Adler32 footer are exactly the zlib wrapper PNG wants).
//!   - Each scanline is prefixed with filter-type byte 0 (None) — simplest, correct,
//!     and deflate still compresses the index runs well.
//!   - Chunk framing uses `std.hash.Crc32` (= the PNG chunk CRC) over type+data.

const std = @import("std");
const flate = std.compress.flate;
const Crc32 = std.hash.Crc32;
const Writer = std.Io.Writer;

/// One RGB palette entry (already 6->8 expanded; the DAC is upstream).
pub const Rgb = extern struct { r: u8, g: u8, b: u8 };

/// The 8-byte PNG signature (`89 'P' 'N' 'G' \r \n 1A \n`).
pub const signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Server-owned scratch the encoder borrows (no internal alloc; §3.7). All fixed-size
/// slabs allocated ONCE by the server. `window` is the flate history window (>= 64 KiB);
/// `idat` holds the compressed zlib stream before it is framed into the output chunk.
pub const Workspace = struct {
    /// The flate `Compress` history window. Must be >= `flate.max_window_len` (64 KiB).
    window: [flate.max_window_len]u8 = undefined,
    /// Scratch for the compressed zlib stream (the IDAT chunk data). Sized like the
    /// final PNG output (worst case ~ raw RGB + deflate stored-block overhead).
    idat: [IDAT_SCRATCH_CAP]u8 = undefined,
};

/// Worst-case IDAT scratch: a 640x480 RGB frame stored uncompressed is
/// 640*480*3 = 921600 bytes of pixels + 480 filter bytes; deflate "stored" blocks add
/// ~5 bytes per 64 KiB plus the 6-byte zlib wrapper. ~1.0 MiB covers it with headroom.
pub const IDAT_SCRATCH_CAP: usize = 1024 * 1024;

/// PNG color types we emit (8-bit depth, no alpha — VGA frames are opaque).
const ColorType = enum(u8) {
    rgb = 2, // truecolor R,G,B
    indexed = 3, // palette index + PLTE
};

const Error = error{
    /// The output writer ran out of room (the server-owned `png_out` slab is too small
    /// for this frame). Surfaced rather than truncating a corrupt PNG.
    WriteFailed,
};

/// Encode an indexed (color type 3) PNG into `out`.
///   `palette` — 256 RGB triples, ALREADY 6->8 expanded (built from the DAC).
///   `indices` — `width*height` palette indices, ALREADY pel-masked by the peek so the
///               PLTE lookup matches `indexToRgba` (§3.3).
pub fn encodeIndexed(
    out: *Writer,
    work: *Workspace,
    width: u32,
    height: u32,
    indices: []const u8,
    palette: *const [256]Rgb,
) Error!void {
    std.debug.assert(indices.len == @as(usize, width) * height);
    writeSignature(out) catch return error.WriteFailed;
    writeIhdr(out, width, height, .indexed) catch return error.WriteFailed;
    writePlte(out, palette) catch return error.WriteFailed;
    // Each scanline: one filter byte (0 = None) + `width` index bytes.
    writeIdat(out, work, height, indices, width, 1) catch return error.WriteFailed;
    writeIend(out) catch return error.WriteFailed;
}

/// Encode a truecolor (color type 2) PNG into `out` from packed RGBA, dropping alpha.
///   `rgba` — `width*height*4` bytes in R,G,B,A order (the peek's RGBA buffer).
pub fn encodeRgb(
    out: *Writer,
    work: *Workspace,
    width: u32,
    height: u32,
    rgba: []const u8,
) Error!void {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    writeSignature(out) catch return error.WriteFailed;
    writeIhdr(out, width, height, .rgb) catch return error.WriteFailed;
    // RGB rows are built from RGBA (alpha dropped) row-by-row in `writeIdatRgb`.
    writeIdatRgb(out, work, width, height, rgba) catch return error.WriteFailed;
    writeIend(out) catch return error.WriteFailed;
}

// ---------------------------------------------------------------------------
// Chunk framing
// ---------------------------------------------------------------------------

fn writeSignature(out: *Writer) Writer.Error!void {
    try out.writeAll(&signature);
}

/// Frame a complete chunk: `len(u32 BE)` + `type` + `data` + `crc32(type++data)(u32 BE)`.
/// The PNG CRC covers the chunk TYPE and DATA, not the length field.
fn writeChunk(out: *Writer, chunk_type: *const [4]u8, data: []const u8) Writer.Error!void {
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(chunk_type);
    try out.writeAll(data);
    var crc = Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

fn writeIhdr(out: *Writer, width: u32, height: u32, color: ColorType) Writer.Error!void {
    var data: [13]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], width, .big);
    std.mem.writeInt(u32, data[4..8], height, .big);
    data[8] = 8; // bit depth
    data[9] = @intFromEnum(color); // color type
    data[10] = 0; // compression method (deflate)
    data[11] = 0; // filter method (adaptive, per-row filter byte)
    data[12] = 0; // interlace (none)
    try writeChunk(out, "IHDR", &data);
}

fn writePlte(out: *Writer, palette: *const [256]Rgb) Writer.Error!void {
    // 256 entries * 3 bytes = 768 bytes, R,G,B per entry. `Rgb` is extern (r,g,b
    // contiguous), so the array is already the on-wire PLTE layout.
    const bytes = std.mem.asBytes(palette);
    std.debug.assert(bytes.len == 768);
    try writeChunk(out, "PLTE", bytes);
}

fn writeIend(out: *Writer) Writer.Error!void {
    try writeChunk(out, "IEND", &.{});
}

// ---------------------------------------------------------------------------
// IDAT — compress the filtered scanlines (zlib via flate.Compress), then frame.
// ---------------------------------------------------------------------------

/// Indexed IDAT: each row is `[filter=0]` followed by `stride` raw bytes from `pixels`.
/// `pixels` is laid out as `height` rows of `stride` bytes (filter byte excluded).
fn writeIdat(
    out: *Writer,
    work: *Workspace,
    height: u32,
    pixels: []const u8,
    stride: u32,
    /// bytes-per-pixel of the source (1 for indices) — kept for symmetry/asserts.
    bpp: u32,
) Writer.Error!void {
    std.debug.assert(bpp == 1);
    std.debug.assert(pixels.len == @as(usize, height) * stride);

    // Compress the filtered scanlines into the server-owned `idat` scratch.
    var idat_w: Writer = .fixed(&work.idat);
    var comp = try flate.Compress.init(&idat_w, &work.window, .zlib, .default);

    const filter0 = [_]u8{0};
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        try comp.writer.writeAll(&filter0);
        const off = @as(usize, row) * stride;
        try comp.writer.writeAll(pixels[off .. off + stride]);
    }
    try comp.finish();

    try writeChunk(out, "IDAT", idat_w.buffered());
}

/// Truecolor IDAT: each row is `[filter=0]` then `width` R,G,B triples taken from the
/// packed RGBA source (alpha dropped). Built three bytes at a time so we never need a
/// second full-frame RGB slab — the deflate window absorbs the streaming.
fn writeIdatRgb(
    out: *Writer,
    work: *Workspace,
    width: u32,
    height: u32,
    rgba: []const u8,
) Writer.Error!void {
    var idat_w: Writer = .fixed(&work.idat);
    var comp = try flate.Compress.init(&idat_w, &work.window, .zlib, .default);

    const filter0 = [_]u8{0};
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        try comp.writer.writeAll(&filter0);
        var col: u32 = 0;
        const row_off = @as(usize, row) * width * 4;
        while (col < width) : (col += 1) {
            const o = row_off + @as(usize, col) * 4;
            try comp.writer.writeAll(rgba[o .. o + 3]); // R,G,B (drop A)
        }
    }
    try comp.finish();

    try writeChunk(out, "IDAT", idat_w.buffered());
}
