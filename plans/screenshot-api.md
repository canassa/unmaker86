# Screenshot API — viewable PNG of the current VGA frame

Add a screenshot capability to the zdos HTTP API: a single request returns a **viewable PNG**
of the current emulated VGA frame. This is a thin, host-side encoder layered on the existing,
already-deterministic framebuffer peek — **no new emulation, no cycle charge, no device
mutation**. It is the natural follow-up to the framebuffer capture (ROADMAP #11) and the
explicit "framebuffer/screenshot capture" backlog item under *[later] more debugger surface*.

> Status: IMPLEMENTED (ROADMAP #13). `src/api/png.zig` + the `?format=png` branch landed; all
> phases A–D done; Phase E docs done, the TTM black-box demo is DEFERRED (out-of-tree BaK assets).

---

## 0. Motivation / immediate consumer

The current `GET /api/framebuffer` returns **raw bytes** (an index image or RGBA) plus
`X-Frame-*` descriptor headers (`src/api/server.zig:712`). That is the right oracle surface for
byte-diffing against goldens (it is what the LAMUT milestone verified against
`tools/lamut-oracle/lamut_0.idx`), but it is **not directly viewable** — you cannot open it in an
image viewer or inline it into a chat/MCP client.

The motivating use case is the **TTM Chapter-1 movie** (`../bak-scratch-area/staging/tests/ttm/`,
runs on zdos to `TTM-OK`). We want to capture frames at several cycle stop-points:

```
POST /api/run-to-cycle {"cycle": N1}   →  GET /api/framebuffer?format=png  →  ttm_N1.png
POST /api/run-to-cycle {"cycle": N2}   →  GET /api/framebuffer?format=png  →  ttm_N2.png
...
```

Because run-to-cycle is deterministic and the screenshot is a pure peek, the same `N` always
yields the **byte-identical PNG**. This makes "show me what the screen looked like at cycle N" a
two-call, scriptable operation, and it is the plan's validation/demo (§7).

---

## 1. Reference research (how the others do screenshots)

### 1.1 dosbox-staging — libpng, indexed-or-RGB, raw-vs-upscaled-vs-rendered

dosbox-staging's image-capture pipeline lives under `src/capture/image/`:

- **`png_writer.cpp`** — a thin RAII wrapper over **libpng** (`#include <zlib.h>`,
  `png_create_write_struct`, `png_set_IHDR`, `png_set_PLTE`, `png_write_row`, `png_write_end`).
  Two entry points: `InitIndexed8` (paletted, `PNG_COLOR_TYPE_PALETTE`) and `InitRgb888`
  (truecolor, `PNG_COLOR_TYPE_RGB`), both **8-bit depth**
  (`references/dosbox-staging/src/capture/image/png_writer.cpp:28,41,118-150`).
  - Compression: `Z_DEFAULT_COMPRESSION` (≈ level 6) is chosen explicitly as the "sweet spot";
    level 9 "rarely results in smaller file sizes" but is "several folds" slower
    (`png_writer.cpp:85-116`).
  - Filtering: `PNG_ALL_FILTERS` — lets libpng pick the best per-row filter
    (`png_writer.cpp:103`).
  - Metadata: writes `gAMA` (1/2.2), `pHYs` (pixel aspect ratio — *ratio only*, unit 0), and two
    `tEXt` chunks (Software, Source resolution / PAR). All optional
    (`png_writer.cpp:152-221`).
- **`image_saver.cpp`** — turns a `RenderedImage` into PNG rows. Three capture flavors
  (`image_saver.cpp:79-105`, `to_capture_type`):
  - **Raw** (`SaveRawImage`, `:107`) — reconstructs the *logical* image by **skipping** baked-in
    double-scan rows and pixel-doubled columns (`row_skip_count`/`pixel_skip_count`,
    `:115-122`), and writes the **video-mode pixel aspect ratio** into `pHYs`. Paletted if the
    source is paletted, else RGB888. **This is the fidelity-first variant.**
  - **Upscaled** (`SaveUpscaledImage`, `:181`) — runs an `ImageScaler`, bakes non-square pixels
    into the data, writes **1:1** PAR.
  - **Rendered** (`SaveRenderedImage`, `:220`) — the exact post-shader host-monitor image, RGB,
    1:1 PAR.
  - The indexed path passes `image.palette` (an `std::array<Rgb888, NumVgaColors>`, 256 entries)
    straight to `png_set_PLTE` (`image_saver.cpp:130-138`, `png_writer.cpp:139-150`). The palette
    is already RGB888 — the 6→8 DAC expansion happened upstream.
- It runs the saver on a **background thread** with a FIFO queue (`image_saver.cpp:27-77`) — a
  throughput optimization for live capture, irrelevant to our pause-and-peek model.

**Worth copying:** the *indexed-PNG-when-paletted, RGB-PNG-otherwise* split; 8-bit depth; the
"raw logical resolution" choice (skip double-scan / pixel-doubling — for us that maps to the
`row_repeat`/`double_scan` flags we already record, §3.4); default-ish (level 6) compression.
**Worth avoiding:** the libpng dependency (we have `std.compress.flate`), the background thread
(we are single-request and want determinism), and the `gAMA`/`tEXt`/temp-file machinery (skip or
make optional — `tEXt` with a version string is harmless and reproducible, but a *timestamp* is
not; do **not** write time-varying metadata).

### 1.2 spice86 — SkiaSharp, truecolor, temp file + base64 (the MCP precedent)

spice86 exposes a screenshot through its **MCP** server, which is the closest analog to what we
want (`references/spice86/src/Spice86.Core/Emulator/Mcp/EmulatorMcpTools.cs:1200-1292`,
`TakeScreenshot`/`ExecuteScreenshot`):

- It **pauses the emulator** (`PauseHandler.RequestPause`, `:1209-1215`), takes a lock
  (`:1217`), and reads the last frame via `VgaRenderer.CopyLastFrame(buffer)` into a
  `uint[]` (`:1218-1222`) — so its renderer already produced a packed 32-bit framebuffer.
- It rejects an all-zero frame with `"No video frame is available"` (`:1224-1234`).
- It encodes with **SkiaSharp**: `SKBitmap` of `SKColorType.Bgra8888`, `SKImage.Encode(Png, 100)`
  (`:1243-1254`) → **truecolor PNG** (no PLTE). Quality 100.
- It writes the PNG to a **temp file** with a name containing `DateTime.UtcNow` and a `Guid`
  (`:1239-1241`), then returns both an inline base64 `ImageContentBlock` and a
  `ScreenshotResponse` record (width/height/format/mime/filePath/fileUri/fileSizeBytes —
  `Mcp/Response/ScreenshotResponse.cs`).

**Worth copying:** the API shape — one call, returns the image + a small metadata block;
content-type `image/png`. **Worth avoiding (determinism!):** the timestamp+GUID filename and the
temp-file round-trip (non-reproducible side effect; we stream bytes, the caller decides where to
save); the pause/resume dance (zdos's capture is *already* a cycle-neutral peek under the
one-command-in-flight model — no pause needed); the all-zero-frame heuristic (we already report
*unsupported mode* honestly via a 501, and a legitimately-black frame is a valid frame, not an
error). Note spice86 chose **truecolor** because its renderer hands back packed BGRA, not
indices — we have *both* the index image and the palette, so we can do better (indexed PNG, §3.3).

### 1.3 Summary

Both encode 8-bit PNG and both face the indexed-vs-truecolor choice. dosbox-staging keeps the
palette and emits indexed PNG when the source is paletted (smaller, exact); spice86 only has the
post-DAC bitmap so it emits truecolor. **zdos is in dosbox-staging's position** — it has the
index image + the DAC — so indexed PNG is the natural primary path, with truecolor as the
fallback for modes that bypass the palette. Neither library's transport (background FIFO, temp
files, libpng/Skia) is worth importing; the encoder is small enough to own in Zig over
`std.compress.flate`.

---

## 2. What zdos already has (survey)

The screenshot feature sits **on top of** an already-complete, already-deterministic pipeline.
Almost nothing in the emulation core needs to change.

### 2.1 The pixel source — `src/devices/vga_render.zig` (the rasterizer)

A **pure, whole-frame** rasterizer (ROADMAP #11; in the `src/devices` grep-gate, §6). Relevant
surface:

- `render(vga, mv, index) Descriptor` (`src/devices/vga_render.zig:502`) — dispatches by mode to
  `render256Linear` / `render256Planar` / `renderText` / `renderEga` / `renderCga`, writing an
  **8-bit index image**. Returns a `Descriptor` (kind, width, height, lens, double_scan,
  row_repeat). Unsupported modes return `kind = .unsupported` (`controller.zig:791`).
- `indexToRgba(vga, index, rgba)` (`vga_render.zig:123`) — second pass: index → DAC → 6→8 → RGBA.
  Reads the **raw** `vga.dac_rgb[]` (256 entries of `{red,green,blue}`, 6-bit each) and
  `vga.pel_mask`. RGBA byte order is R,G,B,A; alpha always `0xFF`.
- `expand6to8(c) = (c<<2)|(c>>4)` (`vga_render.zig:115`) — the **pinned** DAC 6→8 convention
  (S/§3.7). The screenshot must use this exact expansion (it already does, via `indexToRgba`).
- `Kind` (`vga_render.zig:46`), `MAX_WIDTH = 640`, `MAX_INDEX_LEN`, `MAX_RGBA_LEN` (the 640×480
  caps, `vga_render.zig:30-44`).

### 2.2 The capture peek — `src/debug/controller.zig`

- `Controller.framebuffer(index_buf, rgba_buf) FramebufferView` (`controller.zig:740`) — the
  **pure peek**: reads BDA mode/cols/rows/cursor, peeks the text-cell slab + ROM font, calls
  `vga_render.render`, then `indexToRgba`. It "advances NO cycles and mutates NO device field"
  (`controller.zig:730-735`) — R3/R6. `FramebufferView` (`controller.zig:716`) carries
  `kind/width/height/index_len/rgba_len/double_scan/row_repeat/supported`.
- This is exactly the data a PNG needs. **The screenshot reuses this peek verbatim** — it does
  not add a new controller method; it consumes the same `index`/`rgba` buffers and the
  descriptor.

### 2.3 The transport — `src/api/server.zig` + `src/api/worker.zig`

- Route table in `Server.dispatch` (`server.zig:270` onward). `/api/framebuffer`
  (`server.zig:299-310`) parses `?format=index|rgba` server-side and calls
  `submitAndRespondFramebuffer` (`server.zig:712`).
- `submitAndRespondFramebuffer` (`server.zig:712-751`): submits `framebuffer_get`, the worker
  renders into the **server-owned** `self.render` buffers, then the server streams the selected
  buffer directly to the socket as `application/octet-stream` with `X-Frame-*` headers — pixels
  **never** flow through `resp_buf`/JSON (B1). Unsupported mode → **501** (`server.zig:720-722`),
  never a fake frame.
- The worker side: `framebufferResp(ctrl, render)` (`worker.zig:314`) calls `ctrl.framebuffer`
  into `rb.index`/`rb.rgba` and returns the small descriptor. `RenderBuffers`
  (`worker.zig:45-50`): `index: [RENDER_INDEX_CAP]u8` + `rgba: [RENDER_RGBA_CAP]u8`, ≈1.5 MiB,
  allocated **once** at `Server.init` (`server.zig:117`) and reached by the worker via a
  `*RenderBuffers` (the Command stays pointer-free, `worker.zig:44`).
- One-command-in-flight model: a route maps to a `Command`, `queue.submit(&ctx)` blocks until the
  worker runs exactly that one method on the `Controller`, returns a `Response` (the listener
  thread does all socket/HTTP/JSON; the worker owns `ctrl`). The framebuffer route is the
  template to copy for binary, non-JSON responses.
- Integration-test pattern: `src/api/server_test.zig:366-434` (mode-13h index stream, RGBA stream,
  unsupported→501), with a `headerValue(raw, name)` helper (`:351`) to read `X-Frame-*`.

### 2.4 The PNG-relevant Zig std (confirmed in `references/zig/lib/std/`)

- **`std.compress.flate`** (`compress/flate.zig`) — has a `Container` enum with a **`.zlib`**
  variant that emits the **zlib header** (`compress/flate.zig:81`, bytes `0x78 0x9C`) and the
  **Adler32 footer** automatically (`compress/flate.zig:86-137`, the `Hasher` union holds an
  `std.hash.Adler32` for `.zlib` and `writeFooter` writes `zlib.adler` big-endian). This means
  **the PNG IDAT payload is exactly `flate.Compress` output with `container = .zlib`** — we do
  not hand-roll the zlib wrapper or Adler32.
- **`flate.Compress`** (`compress/flate/Compress.zig:303`): `init(output: *std.Io.Writer, buffer:
  []u8, container, opts: Options) !Compress`. `buffer.len >= flate.max_window_len` (= 64 KiB,
  `flate.zig:5`); `output.buffer.len > 8`. It exposes a `writer: std.Io.Writer` field; you write
  the to-be-compressed bytes to `compress.writer`, then `flush`/finish. `Options` presets
  `level_1..level_9` (`Compress.zig:286-298`), `default = level_6` — matches dosbox-staging's
  choice.
- **`std.hash.Crc32`** = `Crc32IsoHdlc` (`hash/crc.zig:10`), polynomial `0xEDB88320` reflected —
  **exactly the PNG chunk CRC**. API: `var c = Crc32.init(); c.update(bytes); const v =
  c.final();` or one-shot `Crc32.hash(bytes)` (`hash/crc/impl.zig:54+`). PNG CRC covers the chunk
  *type + data* (not the length field).
- **`std.hash.Adler32`** (`hash/Adler32.zig`) — `init`/`update`/`final` (or `hash`). Only needed
  if we ever emit raw-deflate IDAT and wrap zlib by hand; with `Container.zlib` it is internal to
  flate and we never call it directly.

**Conclusion:** a PNG encoder over `std` needs only `std.compress.flate` (`.zlib` IDAT) +
`std.hash.Crc32` (per-chunk CRC) + manual chunk framing. Small, dependency-free, host-side.

---

## 3. Design

### 3.1 Determinism boundary (the load-bearing decision)

**PNG encoding lives host-side, in `src/api/` (a new `src/api/png.zig`). It is NEVER imported by
`src/devices/`, never touches `cpu.st.cycles`, and never charges a cycle.**

Justification, tied to the prime directive and CLAUDE's module rules:

- The framebuffer pixels are **already** a deterministic pure peek (`controller.framebuffer`,
  §2.2): same machine state ⇒ same index image + same DAC ⇒ same bytes. PNG-encoding a
  deterministic input is itself a **pure function of that input** — an *observation*, not
  emulation. Per CLAUDE: "the API/MCP server observes the machine, never drives timing."
- The encoder must **not** be reachable from the emulation core. The `src/devices` grep-gate
  (`src/devices/pit_test.zig:52-86`) embeds and scans the device sources for `std.time`,
  `std.Random`, `std.Thread`, floats, etc. The PNG encoder is host code: it **may** use whatever
  it needs *except* it must stay out of that gate. Concretely:
  - Put it in `src/api/png.zig` (module `api`), which the module graph already places **above**
    devices (devices never import upward).
  - Do **not** add `png.zig` to the `@embedFile` list in `pit_test.zig` (it is not a device
    source).
  - Add a **negative** guard test (§7) asserting `png.zig` is not importable from / referenced by
    `src/devices/` and that it never reads `cpu.st.cycles`.
- Even though the encoder is "allowed" host time/float, **we will not use any** (no timestamp
  metadata, no wall-clock, no RNG). This keeps the *output* a pure function of the frame, so the
  two-run-identical-bytes test (§7) holds. flate's deflate is deterministic for a fixed input +
  fixed options (no randomized hashing). This is a stronger guarantee than the boundary strictly
  requires, and it is the one the TTM demo depends on.

### 3.2 Endpoint shape — `GET /api/framebuffer?format=png` (LOCKED)

**Decision (user, locked): extend the existing `/api/framebuffer` route with a new
`?format=png` value** — the same route already serves `?format=index|rgba`; `png` becomes a third
value. No separate `/api/screenshot` route.

- `GET /api/framebuffer?format=png` → Content-Type `image/png`. Streamed from a **server-owned
  buffer**, mirroring the existing binary transport (no per-request alloc); pixels never flow
  through `resp_buf`/JSON (B1, preserved).
- PNG **color type is auto**: indexed (color type 3 + PLTE) when the mode is paletted, truecolor
  RGB (color type 2) otherwise (§3.3). An alpha channel is never emitted (VGA frames are opaque →
  RGB, not RGBA). (An optional future `?png=indexed|rgb` override can force the color type; not in
  v1 — `?format=png` alone picks auto.)
- Response headers mirror the existing `?format=index|rgba` responses: `X-Frame-Width`,
  `X-Frame-Height`, `X-Frame-Kind`, and `X-Frame-Format: png-indexed|png-rgb`.
- Unsupported video mode → **501** (`not_implemented`), identical to the other formats
  (`server.zig:720`). No fake/blank frame.

How the contracts stay clean on one route:
- `?format=index|rgba` remain the **raw oracle** surfaces (byte-diffable against `.idx` goldens).
  `?format=png` is a *derived, viewable* artifact (NOT byte-comparable to the index/RGBA goldens).
  The single route just branches on the `format` param into the right serializer; the PNG path is
  not confused with the raw paths because the caller explicitly asks for `png`. All three reuse the
  same `framebuffer_get` worker command underneath (§3.6) — one machine peek, three serializations.

### 3.3 Pixel pipeline & color type — indexed-when-paletted, else RGB

`index image` (from `vga_render.render`) → PNG, choosing color type by mode:

- **Indexed PNG (color type 3, 8-bit, with PLTE)** when the mode uses the palette — i.e. the
  index image is the authentic per-pixel palette index (256-color modes, EGA/CGA/text where the
  rasterizer emits DAC indices). Build PLTE from the **256 DAC entries** via the pinned
  `expand6to8` (`vga_render.zig:115`): `PLTE[i] = { r=expand6to8(dac_rgb[i].red),
  g=expand6to8(...green), b=expand6to8(...blue) }`. **Smaller** (1 byte/pixel + 768-byte palette
  vs 3 bytes/pixel) and an **exact** palette. This is the primary/default path and mirrors
  dosbox-staging's `InitIndexed8`.
  - **`tRNS`:** VGA frames are opaque ⇒ **omit `tRNS`** (no transparent palette entries). (We
    note it here only to record the deliberate decision; emitting an all-opaque tRNS would be
    pure bloat.)
  - **pel_mask:** if `vga.pel_mask != 0xFF`, the live frame's effective palette is the masked
    set. For the indexed PNG we still emit all 256 PLTE entries and the raw indices — the viewer
    sees exactly what `indexToRgba` would compute *only if* we also mask the indices. To stay
    byte-identical to the RGBA peek, **apply the pel_mask to each index when writing** (i.e.
    `plte_index = idx & pel_mask`), matching `indexToRgba` (`vga_render.zig:125-127`). Document
    this; for BaK/TTM `pel_mask` is `0xFF`, so it is a no-op, but correctness first.
- **Truecolor RGB PNG (color type 2, 8-bit)** otherwise / when `?format=rgb` is forced, or when
  the source is not a clean 256-entry-palette mode. Source the pixels from the **RGBA peek**
  (`controller.framebuffer`'s `rgba_buf`, already `expand6to8`-expanded), dropping the alpha byte
  (RGBA → RGB) since the frame is opaque. This mirrors dosbox-staging's `InitRgb888` /
  spice86's truecolor path.

Both depths are **8-bit**. The 6→8 DAC expansion is `expand6to8` in both paths (in indexed via
PLTE construction, in RGB via the existing `indexToRgba`).

### 3.4 Output resolution — raw logical (recommended)

**Decision (user, locked): raw logical resolution** (e.g. 320×200 for mode 13h, 640×480 for 12h),
i.e. the `width`×`height` the rasterizer reports in the `Descriptor` — **no aspect-ratio
correction, no upscaling**.

- This matches the index/RGBA peek and the oracle goldens exactly, and is the fidelity-first
  choice (dosbox-staging's "Raw" variant). The `double_scan`/`row_repeat` flags
  (`FramebufferView`, `controller.zig:722-723`) are already folded into the rasterizer's emitted
  height where appropriate; the PNG just encodes whatever `width*height` the peek produced.
- **Note on optional scaling (deferred):** 4:3 aspect correction (mode 13h's 320×200 displays as
  ~320×240 / non-square pixels on real hardware) and integer upscaling are *presentation*
  concerns. They can be added later as an `?scale=` / `?aspect=4:3` option that nearest-neighbor
  expands rows/columns **host-side in the encoder** (still a pure function of the frame). For v1,
  emit raw logical and (optionally) record the intended PAR in a `pHYs` chunk like dosbox-staging
  (`png_writer.cpp:158-185`) — but `pHYs` is **optional** and most viewers ignore it; we may skip
  it in v1 to keep the encoder minimal. **Recommendation: skip `pHYs` in v1; raw square pixels.**

### 3.5 PNG encoder (`src/api/png.zig`) — chunks & approach

A small, self-contained host module. The PNG byte stream:

1. **Signature:** the 8 bytes `89 50 4E 47 0D 0A 1A 0A`.
2. **IHDR** chunk (13 bytes data): width (u32 BE), height (u32 BE), bit depth = `8`, color type
   = `3` (indexed) or `2` (RGB), compression = `0`, filter = `0`, interlace = `0`.
3. **PLTE** chunk (indexed only): 256×3 bytes (R,G,B per entry), built from `dac_rgb` via
   `expand6to8`.
4. **IDAT** chunk(s): the **zlib stream** produced by `std.compress.flate.Compress` with
   `container = .zlib` (this emits the `78 9C` header + Adler32 footer for us — §2.4). The bytes
   fed into the compressor are the **filtered scanlines**: for each row, one **filter-type byte**
   then the row's pixel bytes.
   - **Filter:** v1 uses **filter type 0 (None)** for every row — simplest, correct, and zlib
     still compresses the runs of repeated indices well. (Optional later: per-row adaptive
     filter / Paeth (type 4), like dosbox-staging's `PNG_ALL_FILTERS`, for smaller files. Not
     required for v1.) Document the choice; it does not affect viewability or determinism.
   - Row stride: indexed = `width` bytes; RGB = `width*3` bytes; +1 filter byte each.
   - **CRC:** wrap the IDAT data in chunk framing with a `Crc32` over the type+data.
   - **IDAT splitting:** a single IDAT chunk is legal at any size (4 GiB limit); emit one IDAT
     with the whole zlib stream. (Splitting into ≤8 KiB IDATs, like some encoders, is unnecessary.)
5. **IEND** chunk (empty data, fixed CRC `AE 42 60 82`).

Chunk framing helper: `writeChunk(out, type: [4]u8, data) ` = `len(u32 BE)` + `type` +
`data` + `crc32(type ++ data)(u32 BE)`. CRC via `std.hash.Crc32` (§2.4).

**Buffering / API choices to settle in implementation:**
- The encoder writes to a `std.Io.Writer` over a **server-owned PNG output buffer** (§3.7).
- `flate.Compress.init` needs a ≥64 KiB window `buffer` and an `output` writer with `buffer.len >
  8`. Both are server-owned fixed slabs (no per-request alloc) — see §3.7.
- IDAT length is only known after compression. Either (a) compress the full zlib stream into a
  scratch slab first, then write the IDAT chunk (length known) — simplest and matches our
  fixed-buffer model; or (b) two-pass. **Recommend (a):** compress into a fixed `idat_scratch`
  slab, then frame it.
- The CRC for the IDAT chunk is over the **compressed** bytes (the IDAT *data*), so compute it
  after compression over `idat_scratch[0..n]`.

The module's public API (sketch, to finalize against Zig 0.16 `std.Io.Writer` during
implementation — confirm signatures via the `zig-developer` skill):

```
// Encodes an indexed PNG. palette is 256 RGB triples (already 6->8 expanded).
pub fn encodeIndexed(out: *std.Io.Writer, work: *Workspace,
                     width: u32, height: u32,
                     indices: []const u8, palette: *const [256]Rgb) !void;

// Encodes a truecolor PNG from packed RGBA (alpha dropped).
pub fn encodeRgb(out: *std.Io.Writer, work: *Workspace,
                 width: u32, height: u32, rgba: []const u8) !void;
```

`Workspace` bundles the flate window buffer + a small chunk scratch (server-owned, §3.7).

### 3.6 Worker / server wiring (reuse the framebuffer command)

- **No new worker command is required.** The screenshot route can submit the **existing**
  `framebuffer_get` command (`worker.zig:135,314`): the worker renders into `self.render`
  (`index` + `rgba`) and returns the `FramebufferView` descriptor exactly as today. The PNG
  encoding then happens **on the listener thread** (the server side), reading from `self.render`
  (which the worker just filled and which no other request touches — one connection at a time,
  `server.zig:108`). Encoding off-worker is correct and *preferred*: it keeps the worker's
  one-method-per-command discipline intact and keeps the (potentially tens-of-ms) compression off
  the emulation-owning thread. The pixels in `self.render` are a finished, immutable snapshot by
  the time `submit` returns.
- The PNG path is reached **inside the existing `/api/framebuffer` handler** when `format=png`
  (the `submitAndRespondFramebuffer` path, `server.zig:712`, gains a `png` branch). The branch:
  1. `queue.submit(.framebuffer_get)` → `FramebufferView`. If `!supported` → 501. (Shared with the
     `index`/`rgba` branches — one peek.)
  2. Choose color type (auto from `kind`).
  3. Call `png.encodeIndexed`/`encodeRgb` into the **server-owned PNG buffer** (§3.7), reading
     `self.render.index[0..index_len]` (+ the expanded palette slab) or
     `self.render.rgba[0..rgba_len]`.
  4. `req.respond(png_bytes, .{ .status = .ok, ..., content-type image/png, X-Frame-* })`.
- **Palette access:** the indexed path needs the 256 DAC entries (`vga.dac_rgb`) + `pel_mask`.
  Two clean options (pick during implementation, both keep §A.3a — server reads no machine state
  off-worker):
  - (a) Extend `framebufferResp` to also copy the 256 expanded PLTE triples into a small
    server-owned `palette` slab (768 bytes) inside `RenderBuffers`, and add `palette_present` to
    the descriptor. The server then reads only its own buffer. **Recommended** — keeps all
    machine reads on the worker.
  - (b) Add a tiny `palette_get` worker command. More routes; (a) is simpler.

### 3.7 Buffers (no per-request alloc)

Add to `RenderBuffers` (`worker.zig:45`) or a sibling server-owned struct, allocated once at
`Server.init` (`server.zig:117`):

- `png_out: [PNG_OUT_CAP]u8` — the final PNG bytes streamed to the socket. Worst case is an
  RGB PNG of 640×480 with stored (uncompressed) deflate: `640*480*3` ≈ 0.9 MiB pixels + filter
  bytes + zlib/chunk overhead. Size `PNG_OUT_CAP` to a safe **~1.3 MiB** (a frame never expands
  past raw RGBA's ≈1.2 MiB by more than deflate stored-block overhead, and indexed is far
  smaller). For mode 13h / TTM the real output is a few KiB–tens of KiB.
- `png_window: [flate.max_window_len]u8` (64 KiB) — the flate `Compress` window buffer.
- `png_idat: [PNG_OUT_CAP]u8` (or share with `png_out` via a two-region layout) — the compressed
  zlib stream before framing, if using the compress-then-frame approach (§3.5).
- The 768-byte expanded palette slab (§3.6 option a).

All fixed, heap-allocated once (these are large; `RenderBuffers` is already heap, `server.zig:117`).
Total added ≈ 1.4–2.6 MiB depending on whether `png_idat` shares storage with `png_out` — settle
during implementation; sharing is fine if we frame in place.

### 3.8 Cycle-neutrality / purity (restated)

- The only machine read is `framebuffer_get` — the existing pure peek (`controller.zig:730-735`):
  no cycle charge, no DAC-index/AC-flip-flop/latch/device mutation. Verified by the existing
  cycle-neutrality/purity tests for `/api/framebuffer` (ROADMAP #11).
- PNG encoding reads only the server-owned snapshot buffers — it cannot perturb machine state.
- Output is a deterministic function of the frame (no time/RNG/float used; flate deterministic
  for fixed input+options) ⇒ two-run-identical-bytes (§7).

---

## 4. Implementation roadmap (phased)

### Phase A — the PNG encoder module (`src/api/png.zig`)
- [x] Create `src/api/png.zig` with chunk framing: signature, `writeChunk(type, data)` computing
      `std.hash.Crc32` over type+data, big-endian lengths/CRC.
- [x] IHDR writer (width/height/bit-depth-8/color-type/0/0/0).
- [x] `encodeIndexed`: IHDR(type 3) + PLTE(256×3) + IDAT(zlib of per-row `[filter=0][indices]`) +
      IEND. Apply `pel_mask` to indices to match `indexToRgba` (§3.3).
- [x] `encodeRgb`: IHDR(type 2) + IDAT(zlib of per-row `[filter=0][R,G,B...]` from RGBA, alpha
      dropped) + IEND.
- [x] Use `std.compress.flate.Compress` with `container = .zlib`, `Options.default` (level 6) for
      IDAT; compress into a passed-in scratch slab, then frame (§3.5 option a). Confirm the exact
      `Compress.init` / writer / finish call shape against `references/zig/lib/std/compress/flate/`
      via the `zig-developer` skill (Zig 0.16 `std.Io.Writer` semantics).
- [x] `Workspace`/buffer struct param so the encoder takes server-owned slabs (no internal alloc).

### Phase B — server-owned buffers + palette plumbing
- [x] Add `png_out`, `png_window`, (optional) `png_idat`, and the 768-byte expanded `palette`
      slab to `RenderBuffers` (or a sibling) with `PNG_OUT_CAP` const; allocate once at
      `Server.init`.
- [x] Extend `framebufferResp`/`Controller.framebuffer` path (§3.6 option a) to also fill the
      expanded PLTE (via `expand6to8` over `dac_rgb`, masked) + a `palette_present` flag in the
      descriptor — keeping all machine reads on the worker (§A.3a clean).

### Phase C — the `?format=png` branch + serializer
- [x] Extend the `/api/framebuffer` `?format=` parsing in `server.zig` to accept `png` (alongside
      `index`/`rgba`); keep the GET method-guard.
- [x] In `submitAndRespondFramebuffer`, add the `png` branch: submit `framebuffer_get`; 501 if
      `!supported`; pick color type (auto from `kind`); encode into `png_out`;
      `req.respond(png_out[0..n], image/png, X-Frame-*)` with `X-Frame-Format: png-indexed|png-rgb`.
- [x] Ensure the generic JSON serializer can never receive the PNG response (the existing
      framebuffer guard at `server.zig:776` already covers the binary path).

### Phase D — tests (§7)
- [x] Unit tests for `png.zig` (valid signature/chunks/CRC; decode round-trip; indexed & RGB).
- [x] API integration test for `GET /api/framebuffer?format=png` (mirror `server_test.zig:366`).
- [x] Determinism: two captures of the same frame → byte-identical PNG.
- [x] Negative guard: `png.zig` not in the devices grep-gate / not importable by `src/devices`;
      encoder references no `cpu.st.cycles`.
- [x] Wire new tests into `build.zig` (the `api` test target).

### Phase E — docs / roadmap / demo
- [x] Update `plans/ROADMAP.md` (move "framebuffer/screenshot capture" from backlog to done;
      add an entry).
- [ ] TTM demo script / black-box note (§7) — run-to-cycle + screenshot at a few stop-points.
      (DEFERRED: TTM/BMX/PAL are out-of-tree, presence-gated BaK assets — the
      `?format=png` path is exercised end-to-end by the in-tree mode-13h integration test instead;
      the black-box TTM eyeball is a manual step to run when the staged assets are present.)

---

## 5. Determinism boundary statement (the one-paragraph contract)

PNG encoding is a **host-side observation**, not emulation. It lives in `src/api/png.zig` (module
`api`, above `devices` in the module graph). It is invoked only by the API listener thread, only
over the server-owned snapshot buffers that the existing **pure, cycle-neutral** `framebuffer_get`
peek (`controller.framebuffer`, `controller.zig:740`) just filled. It **charges no cycles, mutates
no device state, reads no `cpu.st.cycles`, and is never imported by `src/devices/`** (and is not
added to the `src/devices` grep-gate in `pit_test.zig:52`). Although host code may use host
facilities, this encoder deliberately uses **no host clock, no RNG, no float, no thread feedback
into emulation** — so its output is a pure, byte-identical function of the captured frame. This
preserves Hard Constraints #1 (no holes — none added), #2/#3 (no host-clock/scheduling in
emulated time — encoding is off the emulation path), #4 (deterministic interleaving — single
command in flight; encoding off-worker over an immutable snapshot), and #6 (reproducibility — the
two-run test).

---

## 6. Why this is not a "fake"

The PNG is a faithful, lossless re-encoding of the *real* rasterized frame the emulator produced
(index image + actual DAC palette, via the pinned `expand6to8`). It adds **zero** new emulation
behavior and **invents no pixels** — an unsupported mode is reported honestly as **501**, exactly
as `/api/framebuffer` does (`server.zig:720`), never a blank or fabricated frame. It is a strict
view layer over data the project already trusts as its oracle.

---

## 7. Test plan

**Encoder unit tests (`src/api/png_test.zig`):**
- [x] Encode a tiny known indexed image (e.g. 2×2, palette of 4 distinct colors) → assert the
      8-byte signature, then walk chunks: IHDR present with correct dims/type, PLTE length 768,
      one IDAT, IEND with the fixed CRC. Verify each chunk's CRC32 recomputes
      (`std.hash.Crc32`).
- [x] **Round-trip:** decompress the IDAT zlib stream (`std.compress.flate.Decompress`), strip the
      per-row filter byte (type 0), and assert the recovered pixels equal the input indices /
      RGB. (Confirms the encoder is correct end-to-end without an external PNG lib.)
- [x] Same for `encodeRgb` (truecolor, alpha dropped).
- [x] `pel_mask` applied: an indexed encode with a non-`0xFF` mask matches the RGBA peek's masked
      lookup.

**API integration test (`src/api/server_test.zig`, mirror `:366`):**
- [x] Put BDA in mode 13h, lay a known VRAM pattern + DAC palette (as in the existing framebuffer
      test). `GET /api/framebuffer?format=png` → 200, `content-type: image/png`, body begins with
      the PNG signature, `X-Frame-Width/Height` = `320`/`200`, `X-Frame-Format = png-indexed`.
      Decode the body and assert pixel[0]/pixel[N] match the laid pattern through the palette.
- [x] Unsupported mode (e.g. 0xFE) → **501** (mirror `server_test.zig:425`).

**Determinism test:**
- [x] Capture the same frame twice (same machine state) → `expectEqualSlices(u8, png1, png2)`.
- [x] (Optional) run a fixed program to a fixed cycle, screenshot, reset, re-run, screenshot →
      byte-identical (the core reproducibility regression, Hard Constraint #6).

**Grep-gate / boundary guard:**
- [x] A test asserting `src/api/png.zig` contains no read of `cpu.st.cycles` and that the
      `src/devices` grep-gate (`pit_test.zig`) does **not** list `png.zig` (encoder stays out of
      the device sources).

**Manual / black-box demo (the immediate consumer, §0):**
- [ ] Black-box: load a real program, `POST /api/run-to-cycle {cycle:N}` then
      `GET /api/framebuffer?format=png` → save bytes → open the PNG and eyeball it. Do this for the **TTM
      Chapter-1 movie** (`../bak-scratch-area/staging/tests/ttm/`) at a few cycle stop-points
      along its run-to-`TTM-OK`, producing `ttm_<cycle>.png`. (TTM/BMX/PAL are BaK
      assets → out-of-tree, presence-gated, like the LAMUT probe — not committed. DEFERRED until
      the staged assets are present; the in-tree mode-13h integration test exercises the path.)
- [ ] Sanity-check against `/api/framebuffer?format=index` at the same cycle: the PNG, decoded,
      must equal the raw index bytes through the palette (the two surfaces agree). (DEFERRED — but
      the in-tree integration test already asserts the decoded PNG indices == the laid VRAM bytes.)

---

## 8. Open questions (settle during implementation)

- [x] Exact Zig 0.16 `std.compress.flate.Compress` drive sequence — RESOLVED (confirmed against
      `references/zig/lib/std/compress/flate/Compress.zig:303` `init` + `:363` `finish` and the
      module's own test `:1511-1594`): make a fixed `output` writer over the server-owned IDAT
      scratch (`var idat_w: std.Io.Writer = .fixed(&work.idat)`); `var comp = try
      flate.Compress.init(&idat_w, &work.window, .zlib, .default)` (window >= `flate.max_window_len`
      = 64 KiB, output cap > 8); write the filtered scanlines to `comp.writer` (`comp.writer.writeAll`);
      `try comp.finish()` (writes the deflate tail + the zlib Adler32 footer; the writer then becomes
      `.failing`). The complete zlib stream is now in `idat_w.buffered()` — that IS the IDAT chunk data.
      Decompress side (round-trip tests): `flate.Decompress.init(&reader, .zlib, &window)` then
      `dec.reader.readSliceShort(out)` (`Decompress.zig:1140-1145`).
- [x] `png_idat` does NOT share storage with `png_out` — kept a separate `IDAT_SCRATCH_CAP` slab in
      `png.Workspace` (the compressed stream is built there, then FRAMED into `png_out`). Simpler and
      correct; the few extra MiB sit in the once-allocated server-owned `RenderBuffers`.
- [x] v1 filter: type 0 (None) for every row — simplest, correct, deterministic; deflate still
      compresses the index runs well. (Paeth deferred; not needed.)
- [x] No `tEXt`/`pHYs`/`gAMA`/timestamp metadata in v1 — keeps the byte stream minimal AND keeps the
      output a pure function of the frame (no time-varying bytes).
