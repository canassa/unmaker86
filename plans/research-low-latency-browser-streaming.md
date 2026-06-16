# Research: Low-Latency Game/Emulator Video Streaming to Web Browsers (localhost / local-LAN)

**Scope and assumption.** This report targets a *local* link (localhost or LAN) where bandwidth is
plentiful and cheap. The optimization target is **minimal end-to-end latency and low implementation
complexity**, NOT bandwidth/bitrate. The concrete consumer is **zdos**, a headless DOS emulator in
Zig 0.16, streaming a **320×200** (typ.) up to **640×480** (ceiling) **256-color / 16-color indexed**
VGA framebuffer to a browser developer who watches/plays the live game. The stream is an off-thread
observation (determinism does not apply; host wall clock + a separate thread are allowed), must be
**real-time, no buffering, drop-to-latest**, and zdos strongly prefers **no heavy C codec deps**
(it already hand-owns a PNG encoder over `std`'s deflate; see `plans/video-stream-api.md`).

> TL;DR recommendation (full rationale in §8): **v1 = WebSocket (binary) of frames →
> `<canvas>`**, exactly the project's current lean, with the refinements in §6/§7
> (raw indexed/RGBA as the *primary* on-the-wire format on localhost, PNG as the bandwidth-saving
> fallback for LAN; drop-to-latest via `requestAnimationFrame` + single-in-flight decode;
> `imageSmoothingEnabled=false`). **Neither WebCodecs nor WebRTC is justified for v1** — both add a
> server-side video encoder (a heavy dep we avoid) for latency that is already in the same ballpark as
> raw-frame WS on a local link. **WebCodecs is the right *later tier*** if we ever want real
> inter-frame compression without MSE; **WebRTC only if we later need WAN/NAT traversal**. MSE/LL-HLS
> are the wrong fit for true-live no-buffer and are excluded (§5.7).

---

## 1. Comparison matrix

Latency is **end-to-end glass-to-glass on localhost/LAN** (framebuffer ready → painted). "Codec dep"
means a server-side video/image *encoder beyond what zdos already has* (it already has PNG over
`std.compress.flate`). Numbers are from cited sources where available; where a source gives a figure
it is cited inline in the per-technique sections; "~" = order-of-magnitude/best-case estimate, flagged
as thin where evidence is weak.

| Transport / technique | Local latency | Server CPU | Client CPU | Impl. complexity | Browser support | New codec dep? |
|---|---|---|---|---|---|---|
| **WS + raw RGBA/indexed → `putImageData`/`drawImage`** | **lowest, ~1 frame (≈one paint, ~16 ms @60) + LAN RTT** | very low (memcpy/palette) | low–med (per-pixel upload) | **lowest** (reuse existing binary peek) | universal | **no** |
| **WS + PNG → `createImageBitmap` → `drawImage`** | low, ~1 frame + decode (native, async) | low–med (deflate) | low (native decode, off-main-thread) | low (reuse `png.zig`) | universal | no (PNG already owned) |
| **WS + JPEG/MJPEG-frame → `createImageBitmap`** | low | med (must write JPEG encoder) | low (native decode) | med (no JPEG in `std`) | universal | **yes (JPEG encoder)** |
| **MJPEG `multipart/x-mixed-replace` → `<img>`** | low (~tens ms) but quirky | med (JPEG encoder) | low | low (zero JS) | **patchy** (Chrome/FF history of bugs; not in `<video>`) | **yes (JPEG)** |
| **WebCodecs `VideoDecoder` (H.264/VP8/AV1 over WS), no MSE** | very low (~tens–100s ms, see §5.4) | **high** (real video encoder) | low (HW-decode) | **high** | Chrome/Edge/Opera; Safari 26+; **no MSE needed** | **yes (H.264/VP8/AV1 encoder)** |
| **WebRTC (media track / data channel, local peer)** | very low (sub-250 ms typical incl. WAN; less on LAN) | **high** (encoder + SDP/ICE/RTP stack) | low (native) | **highest** (signaling, SDP, ICE, RTP) | universal | **yes (video encoder)** |
| **WebTransport (HTTP/3 datagrams) + WebCodecs** | very low (QUIC, no HoL block) | high (encoder) | low | high (HTTP/3 server in Zig; + WebCodecs) | Chrome/Edge/Opera; FF partial; **Safari no** | yes |
| **MSE / LL-HLS / fMP4 `<video>`** | **seconds** (buffering by design); LL-HLS ~2–5 s | med | low | med–high | universal | yes (muxer + codec) |

Sources for the rows are cited in the corresponding sections below.

---

## 2. Background: the four "shapes" of browser video

There are exactly four ways to put moving pixels in a browser, ordered by how much machinery sits
between bytes-on-wire and pixels-on-screen:

1. **Draw to a `<canvas>` yourself** — you receive frames over any transport (WS/fetch/WebTransport),
   decode them (raw, or via PNG/JPEG native decode, or via a JS/WASM/`WebCodecs` video decoder), and
   blit. This is what **every browser-based emulator front end does** (jsmpeg, Broadway, v86,
   EmulatorJS, noVNC all paint a canvas) ([JSMpeg](https://jsmpeg.com/),
   [Broadway](https://github.com/mbebenita/Broadway), [v86 examples](https://github.com/copy/v86/blob/master/examples/basic.html)).
2. **`<img>` server-push** — `multipart/x-mixed-replace` (MJPEG). One tag, no JS, but historically
   buggy across browsers (§5.3).
3. **`<video>` + MSE** — feed an fMP4/WebM byte stream into a `SourceBuffer`. Designed for *smooth*
   playback, biased away from low latency (§5.7).
4. **`<video>` + WebRTC `MediaStream`** — the browser's native RTP pipeline; lowest WAN latency, most
   machinery (§5.5).

For a tiny indexed retro framebuffer on a local link, **#1 is the established, lowest-complexity fit**,
which is why all the reference emulators use it.

---

## 3. Why "compression doesn't matter much here" (sizing the local link)

A 320×200×8-bit indexed frame is **64,000 bytes raw**; as RGBA it is 256,000 bytes. At 60 fps that is
3.8 MB/s (indexed) or 15 MB/s (RGBA) — **trivial on localhost (effectively memory-bandwidth-bound) and
on Gigabit LAN** (~125 MB/s). 640×480×RGBA at 60 fps is ~88 MB/s, which still fits Gigabit but is
getting close; indexed (~18 MB/s) is comfortable. zdos already produces a **~10–15 KiB indexed PNG per
frame** for the real game (`plans/video-stream-api.md` §0), i.e. ~0.3–0.9 MB/s at 30–60 fps — also
trivial. **Conclusion:** on a local link the bottleneck is *encode + decode + paint CPU and the
per-frame latency*, not the wire. This is the central reason the heavy inter-frame codecs (H.264/VP8)
buy us little here: their whole value proposition is bandwidth reduction we don't need, at the cost of a
server-side encoder dependency we want to avoid.

---

## 4. WebSocket transport fundamentals (the substrate for our lean)

- WebSocket is a persistent, bidirectional, **TCP-based** framed channel — ideal for continuously
  pushing binary frames and reading back input, and the de-facto choice for low-latency browser game
  state ([Build New Games: WebSockets](http://buildnewgames.com/websockets/),
  [Codez Up: real-time gaming with WebSockets](https://codezup.com/real-time-gaming-with-websockets/)).
- **Send binary, not text/JSON, and decode with the synchronous typed-array API.** Set
  `ws.binaryType = "arraybuffer"` on the client: ArrayBuffer "allows faster processing since it can be
  used with the synchronous API of the DataView," vs the default Blob which forces an async read
  ([MDN: WebSocket.binaryType](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/binaryType),
  [Samsung Internet: binary data](https://medium.com/samsung-internet-dev/being-fast-and-light-using-binary-data-to-optimise-libraries-on-the-client-and-the-server-5709f06ef105)).
  (Note: some platforms default binary frames to Blob; always set `arraybuffer` explicitly —
  [Cloudflare changelog](https://developers.cloudflare.com/changelog/post/2026-04-21-websocket-standard-binary-type/).)
- **TCP caveat (mostly irrelevant locally):** WS is reliable+ordered, so a lost packet head-of-line
  blocks following frames. On localhost there is no loss; on a clean LAN it is negligible. This HoL
  property is the main thing WebTransport/WebRTC datagrams improve on, and it only matters on lossy
  WAN links ([WebTransport vs WebSockets](https://www.videosdk.live/blog/websocket-vs-webtransport),
  [TechBytes 2026](https://techbytes.app/posts/webtransport-vs-websockets-low-latency-streaming-2026/)).
- zdos's server already streams pixels as a raw `application/octet-stream` body from a server-owned
  buffer with `X-Frame-*` headers and never through JSON (`plans/video-stream-api.md` §1.2). The WS
  path mirrors that exact binary discipline.

---

## 5. Per-technique deep dive (with sources)

### 5.1 WebSocket + raw frames (RGBA or indexed) → canvas `putImageData` / `drawImage`

**How.** Server sends the raw pixel buffer (indexed 1 byte/px or RGBA 4 bytes/px) plus a tiny header
(w/h/format/palette). Client writes into an `ImageData` and `ctx.putImageData(...)`, or builds an
`ImageBitmap`/canvas and `drawImage`s it scaled.

**Latency.** This is the **lowest-latency option** because there is **no decode step at all** — the
only costs are a memcpy and the paint. End-to-end ≈ one paint interval (~16 ms @60 fps) plus the
(near-zero) local RTT. noVNC's "raw" encoding is literally this — "width × height pixel values … in
raw encoding," and "all RFB clients must be able to cope with … raw encoding"
([RFB protocol notes](https://deepwiki.com/novnc/noVNC/2.2-rfb-protocol-implementation),
[RFB protocol — Wikipedia](https://en.wikipedia.org/wiki/RFB_protocol)). It exists precisely for the
local/high-bandwidth case.

**Cost / pitfalls.**
- `putImageData` requires the data already in the canvas's native RGBA layout; for **indexed** frames
  you must expand palette→RGBA somewhere. Doing it **server-side** (zdos already has `indexToRgba` /
  `expand6to8`, `plans/video-stream-api.md` §1.1) keeps the client trivial; doing it client-side keeps
  the wire 4× smaller (send indexed + palette, expand in JS/WASM). On a local link, **sending indexed
  + a 256×3 palette and expanding on the client** is the sweet spot: ~64 KB/frame wire and a cheap
  palette LUT loop, avoiding RGBA's 4× wire.
- `putImageData` is **not** affected by `drawImage`'s scaling/smoothing; to scale (320×200 → display
  size) you typically `putImageData` to a small offscreen canvas then `drawImage` it scaled with
  `ctx.imageSmoothingEnabled = false` for crisp nearest-neighbor pixels
  ([createImageBitmap/drawImage perf notes](https://www.measurethat.net/Benchmarks/Show/9510/0/putimagedata-vs-drawimage)).
- General canvas guidance: **lower total pixel count = faster scaling**, and `drawImage` avoids the
  pixel-format conversion `getImageData`/`putImageData` can incur, so the
  "small canvas → `drawImage` scaled" path is generally as fast or faster than scaling pixel arrays
  ([MeasureThat putImageData vs drawImage](https://www.measurethat.net/Benchmarks/Show/9510/0/putimagedata-vs-drawimage),
  [middle-engine: canvas perf gotcha](https://www.middle-engine.com/blog/posts/2020/08/23/a-performance-testing-gotcha-with-the-canvas-web-api)).

**When raw beats compressed on local links:** when encode CPU + decode CPU > the cost of shipping more
bytes — which is exactly the localhost case for tiny frames. This is the strongest single argument for
making **raw indexed the primary localhost format** in zdos.

### 5.2 WebSocket + PNG / JPEG → `createImageBitmap` → `drawImage`

**How.** Server sends a compressed still per frame; client does
`const bmp = await createImageBitmap(blob)` then `ctx.drawImage(bmp, …)`. `createImageBitmap` decodes
**off the main thread** and returns a GPU-ready bitmap, so the main thread only does the cheap
`drawImage`.

**Why it's attractive for zdos specifically:** zdos **already has a dependency-free PNG encoder** over
`std.compress.flate` (`src/api/png.zig`), and PNG decode is native + async in every browser. So this
path adds essentially **zero new server code** and offloads decode to the browser. For a 256-color
indexed frame, PNG is a *good* codec (palette + per-row filters + deflate) — ~10–15 KiB/frame measured
for the real game (`plans/video-stream-api.md` §0).

**Cost / pitfalls.**
- `createImageBitmap` returns a **Promise**, so it is an async pipeline — you must manage stale decodes
  (only ever keep the latest in flight; see §6) and `bmp.close()` decoded bitmaps you skip to free GPU
  memory.
- PNG deflate has nonzero server CPU; on a local link the raw path (§5.1) is lower latency. PNG's win
  is when you want to also serve LAN clients or keep wire small with near-zero added complexity.
- **JPEG** would be smaller for photographic content but (a) zdos has **no JPEG encoder in `std`** — it
  would have to be hand-written (a new dep we avoid), and (b) JPEG is lossy on a 256-color indexed
  image, which is wrong for a pixel-exact developer tool. **PNG is the right compressed format here.**

### 5.3 MJPEG `multipart/x-mixed-replace` → `<img>`

**How.** A single HTTP response of `Content-Type: multipart/x-mixed-replace; boundary=…`, each part a
JPEG; the browser swaps the `<img>` content as parts arrive. Zero JavaScript.

**Latency.** Low (tens of ms) since each frame paints on arrival, but with quirks.

**Why it's a poor v1 fit for zdos.**
- Needs a **JPEG encoder** zdos doesn't have (and JPEG is lossy — wrong for pixel-exact retro frames).
- **Cross-browser flakiness is well-documented:** Firefox flickers depending on where the boundary
  string is placed relative to the frame
  ([Mozilla bug 987135](https://bugzilla.mozilla.org/show_bug.cgi?id=987135),
  [WPEWebKit #569](https://github.com/WebPlatformForEmbedded/WPEWebKit/issues/569)); Chromium has had
  cases where an MJPEG `<img>` embedded in a page doesn't render at all
  ([Chromium issue 238427](https://groups.google.com/a/chromium.org/g/chromium-bugs/c/fz42h1hHp9I/m/nNoFqpy7y9kJ));
  the stream isn't shown until the first frame and can stall
  ([flask-video-streaming #16](https://github.com/miguelgrinberg/flask-video-streaming/issues/16));
  and there is long-standing churn around `multipart/x-mixed-replace` support
  ([HN: Chrome removed multipart/x-mixed-replace](https://news.ycombinator.com/item?id=7349266)).
- It is an `<img>` technique only — **`<video>` cannot play MJPEG**, so it can't feed standard tooling.

**Verdict:** keep as an *optional zero-JS variant* only if a JPEG encoder is ever justified
(`plans/video-stream-api.md` already files it this way). Not v1.

### 5.4 WebCodecs API (`VideoEncoder`/`VideoDecoder`/`VideoFrame`) — assessed carefully

This is the most important "should we change our lean?" question, so it gets the most detail.

**What it is.** WebCodecs gives JS **direct access to the browser's built-in (often hardware) video
codecs** at the frame level — `VideoDecoder.decode(EncodedVideoChunk)` → `VideoFrame` you draw to
canvas — *without* `<video>`, MSE, or any container/muxer
([MDN: WebCodecs API](https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API),
[W3C WebCodecs](https://www.w3.org/TR/webcodecs/)).

**Does it remove the need for MSE / a media timeline?** **Yes.** This is its headline benefit for
interactive use: "Of all the ways to deal with video streaming in the browser (`<video>`, MSE,
WebRTC), WebCodecs provides the lowest level control … MSE forces a lot of overhead, while allowing raw
H.264 encoded frames to be passed to the hardware-accelerated decoder solves these issues"
([webrtcHacks: WebCodecs, WebTransport, WebRTC](https://webrtchacks.com/webcodecs-webtransport-and-webrtc/)).
The live-streaming pattern is: receive a binary chunk over *any* transport (WS/WebTransport),
reconstruct `new EncodedVideoChunk({timestamp, type:'key'|'delta', data})`, `decoder.decode(chunk)`,
and "the decoder outputs `VideoFrame` objects that render directly to canvas, eliminating the need for
MSE" ([WebCodecs Fundamentals: live streaming](https://webcodecsfundamentals.org/patterns/live-streaming/)).

**Can the *browser* hardware-decode H.264/VP8/AV1 fed over WebSocket with low latency?** Yes — WebCodecs
is **transport-agnostic**; chunks can arrive via WebSocket (it just needs encoded frames + key/delta
type + timestamp). Hardware acceleration "kicks in automatically when the system codec is GPU-backed,"
falling back to software otherwise, and there is a **low-delay hint** to "minimize the number of
EncodedVideoChunks that have to be decoded before a VideoFrame is output"
([WebCodecs browser-support/HW notes](https://www.testmuai.com/learning-hub/webcodecs-browser-support/),
[W3C WebCodecs spec](https://www.w3.org/TR/webcodecs/)). Each GOP must start with a **keyframe** ("the
first frame in the group is always a key frame")
([WebCodecs Fundamentals](https://webcodecsfundamentals.org/patterns/live-streaming/)).

**Latency caveats (real, flagged).** Some HW decoders have a pipeline delay before first output, and a
macOS H.264 case showed *delayed* decoding via `VideoDecoder` (sometimes only fixable with
`hardwareAcceleration:"prefer-software"`)
([w3c/webcodecs #899](https://github.com/w3c/webcodecs/issues/899),
[#732 1-in-1-out](https://github.com/w3c/webcodecs/issues/732)). So WebCodecs is **low-latency but not
trivially so** — you must configure low-delay mode and avoid B-frames/reordering on the encoder.

**What it does NOT remove: the server-side encoder.** WebCodecs gives you a *decoder* in the browser,
but **you must produce encoded H.264/VP8/AV1 on the server.** zdos has **no video encoder** and `std`
has none (`plans/video-stream-api.md` §0 confirms `std.compress` has flate/lzma/xz/zstd, no
image/jpeg/video). So adopting WebCodecs means **importing a C codec (openh264/x264/libvpx) via Zig
C-interop** — precisely the heavy binary dependency the project avoids. (A pure-Zig software H.264/VP8
encoder is not a realistic v1 scope.)

> **Note for the future:** there is also a *symmetric* trick — `VideoEncoder` in the browser and
> WebCodecs `VideoDecoder` on the other end — but that is for browser-as-source; our source is the Zig
> server, so it doesn't apply. The only way WebCodecs helps us is browser-decode of server-encoded
> frames, which requires the server encoder.

**Browser support (2024–2026).** Shipped in Chrome since v94; available in Edge/Opera (Opera 80+);
**Safari shipped full WebCodecs in Safari 26.0** (macOS/iOS/iPadOS); Chrome for Android full from
v147 ([WebCodecs browser support](https://www.testmuai.com/learning-hub/webcodecs-browser-support/),
[MDN WebCodecs](https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API)). So in 2026 it is
broadly available, but it is still newer than plain WebSocket+canvas.

**Verdict for zdos:** WebCodecs is the **correct later tier** *if* we ever want true inter-frame
compression (e.g. for a slow WAN link or 640×480 at high fps over modest LAN) **and** are willing to
take a C video-encoder dependency. It does **not** change the v1 lean, because on a local link it buys
latency we already have while adding a heavy server encoder.

### 5.5 WebRTC for localhost / LAN

**How.** Establish a peer connection (offer/answer SDP, ICE candidate exchange via a signaling
channel — often a WebSocket), then send either a **media track** (the browser's native RTP video
pipeline, lowest latency, needs server-side encode) or frames over a **`RTCDataChannel`** (SCTP/UDP).

**Latency.** WebRTC is the canonical "ultra-low latency" web path — implementations hit **sub-250 ms**
glass-to-glass including WAN; on a local link it is lower
([Red5: 7 ways WebRTC solves ultra-low latency](https://www.red5.net/blog/7-ways-webrtc-solves-ultra-low-latency-streaming/),
[nanocosmos: WebRTC latency 2026](https://www.nanocosmos.net/blog/webrtc-latency/)). Cloud-gaming
projects rely on it: **CloudRetro** uses **WebRTC with VP8/H264 video + Opus audio** and a WebSocket
for signaling/coordination, targeting sub-second interactive latency
([webrtcHacks: open-source cloud gaming](https://webrtchacks.com/open-source-cloud-gaming-with-webrtc/));
**Selkies** is an "open-source low-latency … WebRTC HTML5 remote-desktop streaming platform"
([selkies-project/selkies](https://github.com/selkies-project/selkies)).

**Is the complexity worth it on a local link?** **No, for v1.** WebRTC's advantages — congestion
control, FEC/retransmit, NAT traversal (STUN/TURN), jitter buffer, native HW codec path — are
**WAN/lossy-link** features. On localhost/LAN none of those problems exist, and you still pay the full
cost: an SDP/ICE negotiation, an RTP/RTCP stack, **and a server-side video encoder** (same dep problem
as WebCodecs). "WebSockets are TCP-based and less efficient than WebRTC because the developer needs JS
to manage them" — but that inefficiency is a *WAN* concern; locally the WS path is both simpler and
fast enough ([webrtcHacks](https://webrtchacks.com/webcodecs-webtransport-and-webrtc/),
[nanocosmos](https://www.nanocosmos.net/blog/webrtc-latency/)).

**Can you use WebRTC without a media server?** Yes — a **local peer** works: the Zig server is one peer,
the browser is the other, and signaling can be a plain WebSocket or even a copy-pasted SDP; no
TURN/relay needed on a LAN. But you still must implement an RTP/SDP/ICE peer in Zig (or pull in a C
WebRTC lib), which is *far* more than a WS frame pump. **Defer.**

### 5.6 WebTransport (HTTP/3 / QUIC datagrams)

**How.** A browser API over **HTTP/3 (QUIC)** offering both reliable streams and **unreliable,
unordered datagrams** (UDP-like, but encrypted + congestion-controlled), without TCP head-of-line
blocking ([MDN/overview via OpenReplay](https://blog.openreplay.com/low-latency-browser-communication-webtransport/),
[gocodeo: WebTransport over HTTP/3](https://www.gocodeo.com/post/webtransport-explained-low-latency-communication-over-http-3)).

**Relevance for local low-latency.** Its key win — eliminating TCP HoL blocking under loss — **does not
exist on localhost and is negligible on a clean LAN**, so it buys little over WebSocket for our case
([VideoSDK: WS vs WebTransport](https://www.videosdk.live/blog/websocket-vs-webtransport),
[TechBytes 2026](https://techbytes.app/posts/webtransport-vs-websockets-low-latency-streaming-2026/)).
One report measured a ~35% latency cut vs WebSockets in a WAN-ish setting
([vroble: Beyond WebSockets](https://www.vroble.com/2025/11/beyond-websockets-mastering.html)) — but
that gain comes from loss/HoL avoidance we don't suffer locally.

**Costs.** Requires implementing an **HTTP/3/QUIC server in Zig** (much heavier than zdos's current
HTTP/1.1 listener) and **Safari does not support WebTransport** as of 2026; Firefox is partial; full
support is Chrome/Edge/Opera ([VideoSDK](https://www.videosdk.live/blog/websocket-vs-webtransport),
[OpenReplay](https://blog.openreplay.com/low-latency-browser-communication-webtransport/)). It is most
interesting **paired with WebCodecs** for a future WAN tier, not for local v1.

### 5.7 MSE low-latency / LL-HLS / fMP4 — confirmed WRONG for true-live no-buffer

- **MSE is biased toward smoothness, not latency, by design.** "Media Source is designed only for video
  streaming use cases where smoothness is more important than latency"; low-latency MSE playback can
  cause "extremely high CPU/GPU usage and poor playback performance," and there is an open request to
  even expose an explicit low-latency vs smoothing mode because the buffering model fights live use
  ([Mozilla bug 1520894](https://bugzilla.mozilla.org/show_bug.cgi?id=1520894),
  [w3c/media-source #21](https://github.com/w3c/media-source/issues/21),
  [w3c bug 28379](https://www.w3.org/Bugs/Public/show_bug.cgi?id=28379)).
- **It needs a timeline + buffer + a muxer.** You must produce fMP4/CMAF segments and append to a
  `SourceBuffer`; the element maintains a presentation timeline and buffered ranges — inherently
  accumulating latency, the opposite of drop-to-latest. The community is actively trying to **bypass
  MSE with WebCodecs** precisely for this reason
  ([w3c/media-source #184 "MSE for WebCodecs"](https://github.com/w3c/media-source/issues/184)).
- **B-frames / reordering** add decode-order vs display-order buffering; even extra keyframes "can
  easily cause stuttering in low-latency streaming"
  ([MSE not suitable — search summary, Mozilla bug 1290840](https://bugzilla.mozilla.org/show_bug.cgi?id=1290840)).
- **LL-HLS** is a segment/chunked-transfer protocol; even "low latency" HLS is typically ~2–5 s — orders
  of magnitude worse than our budget and built around a player buffer.

**Verdict:** MSE/LL-HLS/fMP4 are excluded. They solve adaptive, smooth, buffered VOD/live-at-scale —
the opposite of a no-buffer, drop-to-latest developer view of a local emulator.

---

## 6. The "drop-to-latest / no-buffering" pattern (client + server)

This is the core behavioral requirement: the player has no future; if it falls behind, **show the
newest frame, never accumulate latency.** Best practices:

**Server side**
- **Coalesce sends — only ever send the latest frame.** Keep at most one frame queued per connection;
  if a new frame is ready before the prior send drained, **drop the older one**. This mirrors JSMpeg's
  philosophy: "tries to keep latency as low as possible … discards old (even unplayed) data to make
  room for newly arriving data," with deliberately small internal buffers
  ([JSMpeg README](https://github.com/phoboslab/jsmpeg/blob/master/README.md), [jsmpeg.com](https://jsmpeg.com/)).
- **Watch the socket's send backpressure.** Don't blindly enqueue; if the OS send buffer / app-level
  queue is backing up, skip frames rather than buffer them. (Client-side, the analog is polling
  `socket.bufferedAmount` and throttling when it exceeds a threshold —
  [SitePoint: streaming backends](https://www.sitepoint.com/streaming-backends-react-controlling-re-render-chaos/);
  the server should apply the same "skip, don't buffer" rule on its send side.)
- **Pace by wall clock, not max speed.** zdos's plan already adds a "paced free-run mode" throttled
  toward wall-clock (`plans/video-stream-api.md`); cap at e.g. 30–60 fps so you sample the framebuffer
  at display cadence rather than flooding.

**Client side**
- **Single-in-flight decode; drop stale.** With `createImageBitmap` (async), keep only the most recent
  encoded frame; if a new one arrives while a decode is pending, **replace the pending one** and, when
  the decode resolves out of order, `bmp.close()` the stale bitmap instead of drawing it. (General
  coalescing pattern: buffer in a mutable ref, flush newest on a frame tick —
  [SitePoint](https://www.sitepoint.com/streaming-backends-react-controlling-re-render-chaos/).)
- **Draw on `requestAnimationFrame`, decouple from receive.** The WS `onmessage` handler should only
  *store the latest frame* (and kick a decode); a separate `rAF` loop paints whatever the latest ready
  frame is. This naturally drops frames when the producer outruns the display and avoids doing paint
  work off the vsync cadence (browsers give ~16.6 ms/frame @60; over budget = dropped frame —
  [DEV: requestAnimationFrame explained](https://dev.to/tawe/requestanimationframe-explained-why-your-ui-feels-laggy-and-how-to-fix-it-3ep2)).
- **WebCodecs analog (if ever used):** monitor `VideoDecoder.decodeQueueSize` and drop input chunks (to
  the next keyframe) if it grows, and `VideoFrame.close()` frames you skip.

---

## 7. Client-side rendering best practices

- **`ws.binaryType = "arraybuffer"`** for synchronous typed-array access to incoming frames (§4).
- **Nearest-neighbor, no smoothing.** Set `ctx.imageSmoothingEnabled = false` so 320×200 scales up
  crisp (and faster) ([canvas perf / imageSmoothing](https://www.measurethat.net/Benchmarks/Show/9510/0/putimagedata-vs-drawimage)).
- **Two-stage blit for scaling.** `putImageData` writes 1:1 only; to upscale, put into a 320×200
  offscreen canvas then `drawImage` it scaled to the visible canvas. `drawImage` avoids the
  pixel-format conversion costs that can hit `getImageData`/`putImageData`, and fewer source pixels =
  faster scale ([MeasureThat](https://www.measurethat.net/Benchmarks/Show/9510/0/putimagedata-vs-drawimage),
  [middle-engine](https://www.middle-engine.com/blog/posts/2020/08/23/a-performance-testing-gotcha-with-the-canvas-web-api)).
  Be aware `drawImage` had a macOS perf regression history — test on target
  ([Mozilla bug 1602299](https://bugzilla.mozilla.org/show_bug.cgi?id=1602299)).
- **`createImageBitmap` decodes off the main thread** and yields a GPU-friendly bitmap; prefer it over
  decoding-then-`putImageData` for compressed frames, and `close()` bitmaps you skip.
- **`canvas` 2D vs WebGL.** For a single full-frame blit at 320×200..640×480, **2D `drawImage` is
  plenty** and simplest; this is what jsmpeg's Canvas2D renderer and noVNC use. JSMpeg/Broadway add a
  **WebGL** renderer mainly to do **YUV→RGB conversion on the GPU** (relevant only when you decode
  YUV frames, i.e. a video codec) — not needed for our RGBA/indexed path
  ([JSMpeg](https://jsmpeg.com/), [Broadway](https://github.com/mbebenita/Broadway)). For indexed
  frames a tiny WebGL palette-LUT shader *could* expand index→RGB on the GPU, but it's an optimization,
  not a v1 need.
- **`OffscreenCanvas` + Worker.** Move decode+paint entirely off the main thread by transferring the
  canvas to a worker; the WS can even run in the worker. Reduces main-thread jank for a 60 fps loop.
  Useful as a tier-2 polish, not required for tiny frames.
- **`SharedArrayBuffer` zero-copy (raw frames).** SAB lets a worker and main thread share the raw frame
  buffer with no copy, but it requires the page be **cross-origin isolated**: serve
  `Cross-Origin-Opener-Policy: same-origin` **and** `Cross-Origin-Embedder-Policy: require-corp` (or
  `credentialless`) ([web.dev: COOP/COEP](https://web.dev/articles/coop-coep),
  [MDN: COEP](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Embedder-Policy)).
  For zdos's local dev tool this is doable (it controls its own headers) but adds friction; **transfer
  (ArrayBuffer ownership) is simpler than share** and usually sufficient
  ([Samsung Internet: binary data / transferables](https://medium.com/samsung-internet-dev/being-fast-and-light-using-binary-data-to-optimise-libraries-on-the-client-and-the-server-5709f06ef105)).
  Recommend: **skip SAB for v1**, revisit only if profiling shows copy cost matters.

---

## 8. What real, shipping projects use (and the local-streaming consensus)

| Project | Transport | Codec / frame format | Presentation | Source |
|---|---|---|---|---|
| **JSMpeg** | WebSocket (binary MPEG-TS) | MPEG1 video / MP2 audio (WASM decoder) | Canvas2D **or** WebGL | [jsmpeg.com](https://jsmpeg.com/), [README](https://github.com/phoboslab/jsmpeg/blob/master/README.md) |
| **Broadway.js** | (transport-agnostic; commonly WS) | H.264 **Baseline** (Android decoder via Emscripten) | WebGL (YUV→RGB); canvas | [mbebenita/Broadway](https://github.com/mbebenita/Broadway) |
| **noVNC** | WebSocket (RFB/VNC) | **raw** + copyrect/RRE/hextile/tight encodings | `<canvas>` | [RFB impl](https://deepwiki.com/novnc/noVNC/2.2-rfb-protocol-implementation), [RFB — Wikipedia](https://en.wikipedia.org/wiki/RFB_protocol) |
| **v86** | (in-process; no network) | emulated VGA framebuffer (WASM) | `<canvas>` (+ text div) | [v86 examples](https://github.com/copy/v86/blob/master/examples/basic.html), [copy/v86](https://github.com/copy/v86) |
| **EmulatorJS / RetroArch-web / libretro** | (in-process WASM core) | libretro framebuffer | **WebGL** (canvas), WebGL1 | [EmulatorJS](https://github.com/EmulatorJS/EmulatorJS), [libretro OpenGL cores](https://docs.libretro.com/development/cores/opengl-cores/) |
| **CloudRetro** | **WebRTC** (WS for signaling) | VP8 / H264 + Opus | `<video>` (RTP track) | [webrtcHacks: open-source cloud gaming](https://webrtchacks.com/open-source-cloud-gaming-with-webrtc/) |
| **Selkies-GStreamer** | **WebRTC** | HW-encoded H.264/VP8/etc. | `<video>` | [selkies-project/selkies](https://github.com/selkies-project/selkies) |
| **Parsec / Moonlight-Sunshine** | UDP/RTP-style (native), HW codec | H.264/HEVC | native client (web clients are WebRTC/WebCodecs-based) | [Red5 WebRTC](https://www.red5.net/blog/7-ways-webrtc-solves-ultra-low-latency-streaming/) |

**Two clear camps:**
1. **In-process emulators** (v86, EmulatorJS, libretro-web) run the emulator *in the browser* via WASM
   and paint a **canvas/WebGL** directly — no transport at all. Not our model (zdos runs natively in
   Zig), but it confirms the **canvas** presentation layer.
2. **Remote-display / cloud-gaming** over a network split into:
   - **WAN / scale → WebRTC** (CloudRetro, Selkies, Parsec): worth its complexity because of
     NAT/loss/jitter/HW-codec at scale.
   - **Local / simple / pixel-pump → WebSocket + canvas** (jsmpeg, noVNC, Broadway): the consensus
     **local low-latency** pattern is exactly "**push frames over WebSocket, decode/blit to a
     `<canvas>`**," with the choice of frame format (raw vs MPEG1 vs H.264-baseline) trading server
     CPU/deps vs wire size. noVNC's **raw encoding** and JSMpeg's **immediate-decode, drop-old-data**
     loop are the closest analogues to what zdos wants.

**Consensus for *local* streaming specifically:** WebSocket binary frames → canvas, with aggressive
drop-to-latest. The heavyweight codec/WebRTC machinery is reserved for WAN.

---

## 9. Latency budget (localhost / LAN), with confidence notes

Glass-to-glass = capture → (encode) → send → (decode) → paint. Realistic local figures:

| Stage | Raw WS path | PNG WS path | WebCodecs/WebRTC (H.264) |
|---|---|---|---|
| Capture (peek) | sub-ms (memcpy) | sub-ms | sub-ms |
| Encode (server) | ~0 (none) | low (deflate, tiny frame) | encoder pipeline (ms; HW or SW) |
| Send (localhost) | sub-ms (loopback) | sub-ms | sub-ms |
| Decode (client) | ~0 (memcpy) | native async (low, off-thread) | HW decode + possible pipeline delay |
| Paint (rAF/vsync) | ~0–16.6 ms (wait for next vsync @60) | ~0–16.6 ms | ~0–16.6 ms |
| **Total (typical)** | **≈ one frame (~16 ms) + a few ms** | ~16 ms + small encode/decode | tens of ms; can be higher if decoder has startup/HoL delay |

**Anchors from sources (most are LAN-ish, not pure localhost — flagged as such):**
- **JSMpeg: ~50 ms over WebSocket on a local network**, explicitly "only dependent on your source, the
  network, and how fast your browser/GPU/monitor spit out frames"
  ([jsmpeg.com](https://jsmpeg.com/)). This is a *codec* path; a **raw** path should be at/below this
  since it skips decode.
- **Broadway.js (H.264 over WS): ~0.1 s (100 ms)** end-to-end, "acceptable for remote operations"
  ([Broadway low-latency usage](http://telerobotics.blogspot.com/2018/04/javascript-libraries-for-video.html)).
- **WebRTC: sub-250 ms** typical glass-to-glass *including WAN*; lower on a local link
  ([Red5](https://www.red5.net/blog/7-ways-webrtc-solves-ultra-low-latency-streaming/),
  [nanocosmos](https://www.nanocosmos.net/blog/webrtc-latency/)).
- **WebCodecs+WebTransport: 140 ms regional, <400 ms transcontinental** in one experiment
  ([webrtcHacks](https://webrtchacks.com/webcodecs-webtransport-and-webrtc/)) — dominated by WAN RTT;
  on localhost the transport term collapses and you're left with encode+decode+paint.
- **MSE/LL-HLS: seconds** (excluded).

**Evidence-thin flags:** I found no clean published "pure localhost, raw-RGBA-WS-to-canvas, glass-to-
glass ms" benchmark; the ~16 ms-plus-a-few estimate is a reasoned budget (one vsync + sub-ms loopback +
no decode), consistent with JSMpeg's ~50 ms *codec* number being an upper bound. Treat the exact raw-WS
number as an estimate, not a cited measurement.

---

## 10. Input round-trip (browser → server)

zdos already injects keyboard/mouse over the API (`POST /api/input/key`, `/api/input/mouse`,
`plans/video-stream-api.md` §1.3, ROADMAP #7) landing deterministically at command boundaries.

- **Send input over the *same* WebSocket** (a small binary opcode for key/mouse) rather than separate
  HTTP POSTs, to avoid per-event connection/handshake overhead and to keep ordering with frames. This
  is the cloud-gaming pattern: CloudRetro fans all user inputs into a central input channel feeding the
  emulator, separate from the media pipeline
  ([webrtcHacks: cloud gaming](https://webrtchacks.com/open-source-cloud-gaming-with-webrtc/)).
- **Local round-trip is dominated by loopback + the input-injection landing latency**, both sub-frame
  on localhost — interactive play is comfortable. For interactive games, >~150–500 ms input lag is the
  pain threshold the cloud-gaming literature targets ([webrtcHacks](https://webrtchacks.com/open-source-cloud-gaming-with-webrtc/)),
  and a local WS path is far under that.
- **Determinism boundary (project-specific):** zdos's CLAUDE.md/MEMORY require input injection be
  **cycle-keyed, not host-time-keyed**. The *stream* is non-deterministic/observational, but **input
  must still enter the emulation deterministically** (at a command/cycle boundary), exactly as the
  existing injection path does. Keep input landing on the worker/command path even though the video
  pump is off-thread. (This is an internal constraint, not a web-platform one.)

---

## 11. Recommendation for zdos

**Context recap:** Zig 0.16 server, localhost/LAN, no heavy C deps, 320×200..640×480 indexed frames,
real-time no-buffer, existing dependency-free PNG encoder + cycle-neutral framebuffer peek, existing
binary-octet-stream HTTP transport + input injection.

### v1 (do this now) — WebSocket binary frames → `<canvas>`
This **confirms and refines the current lean.** Specifically:

1. **Transport:** add a WebSocket endpoint that pushes binary frames from the existing server-owned
   render buffer (same discipline as `GET /api/framebuffer`), paced toward wall-clock (~30–60 fps cap),
   on the off-emulation observation thread.
2. **Primary on-the-wire format = raw *indexed* + palette** (1 byte/px + 256×3 palette + small header).
   It's the lowest-latency (no decode), tiny on a local link (§3), reuses the existing index buffer,
   and lets the client expand via a cheap palette LUT. **Offer PNG as a fallback/alt format** (reuses
   `png.zig` verbatim, ~10–15 KiB/frame) for LAN clients or when wire size matters — decoded via
   `createImageBitmap`.
3. **Client:** `ws.binaryType="arraybuffer"`; store-latest-frame in `onmessage`; paint newest ready
   frame on a `requestAnimationFrame` loop; `imageSmoothingEnabled=false`; two-stage blit (320×200
   offscreen → scaled `drawImage`). For PNG mode, single-in-flight `createImageBitmap`, `close()` stale
   bitmaps (§6/§7).
4. **Drop-to-latest everywhere:** server coalesces to one queued frame and skips on backpressure;
   client never queues more than the latest. (JSMpeg's discard-old-data discipline.)
5. **Input over the same WS** (binary key/mouse opcodes) routed to the existing deterministic injection
   command path.

This is **the lowest-complexity, lowest-latency, zero-new-dependency** option and matches what every
comparable *local* streamer (noVNC raw, jsmpeg) does.

### Does WebCodecs or WebRTC change the v1 lean? **No.**
- **WebCodecs** removes MSE and decodes in the browser (great), and is broadly supported in 2026
  (incl. Safari 26+), **but it still requires a server-side H.264/VP8/AV1 encoder** that neither zdos
  nor `std` provides — a heavy C dep the project deliberately avoids — for latency we already have
  locally. It's the right **later tier**, not v1.
- **WebRTC** is the gold standard for *WAN* ultra-low latency, but its SDP/ICE/RTP machinery **plus** a
  server encoder is unjustified on a local link where loss/NAT/jitter don't exist. **Defer to a future
  WAN tier.**

### Later tiers (only if a concrete need appears)
- **Tier 2 — client polish:** `OffscreenCanvas`+Worker, optional WebGL palette-LUT shader for indexed
  frames, optional `SharedArrayBuffer` (needs COOP/COEP) for zero-copy raw frames — pure jank/CPU
  optimizations, not latency-critical at our resolutions.
- **Tier 3 — WebCodecs path:** if we want real inter-frame compression (e.g. 640×480 high-fps over
  modest LAN, or a WAN dev view) without MSE — add a C video encoder + `VideoDecoder` client. Pairs
  naturally with **WebTransport** if WAN HoL-blocking becomes a problem (note Safari lacks
  WebTransport).
- **Tier 4 — WebRTC / true `<video src>`:** only if zdos must serve over the open internet with
  NAT traversal, or feed standard `<video>`/recording tooling (fMP4/H.264 via C codec). The existing
  plan (`plans/video-stream-api.md` Phase 4) already files the `<video src>` path here.

### One-line decision
**Ship WebSocket binary frames (raw indexed primary, PNG fallback) → canvas with strict drop-to-latest;
keep WebCodecs and WebRTC explicitly on the shelf as WAN/compression tiers, gated on a real need and on
accepting a C codec dependency.**

---

## Appendix: sources

- JSMpeg (MPEG1 over WebSocket, ~50 ms local, drop-old-data): https://jsmpeg.com/ ; https://github.com/phoboslab/jsmpeg/blob/master/README.md
- Broadway.js (H.264 baseline in JS, ~0.1 s WS): https://github.com/mbebenita/Broadway ; http://telerobotics.blogspot.com/2018/04/javascript-libraries-for-video.html
- noVNC / RFB (raw + delta encodings, canvas): https://deepwiki.com/novnc/noVNC/2.2-rfb-protocol-implementation ; https://en.wikipedia.org/wiki/RFB_protocol
- v86 (canvas framebuffer): https://github.com/copy/v86 ; https://github.com/copy/v86/blob/master/examples/basic.html
- EmulatorJS / libretro-web (WebGL canvas): https://github.com/EmulatorJS/EmulatorJS ; https://docs.libretro.com/development/cores/opengl-cores/
- CloudRetro (WebRTC VP8/H264 + Opus, WS signaling, input fan-in): https://webrtchacks.com/open-source-cloud-gaming-with-webrtc/
- Selkies (WebRTC remote desktop): https://github.com/selkies-project/selkies
- WebCodecs API: https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API ; https://www.w3.org/TR/webcodecs/
- WebCodecs live-streaming pattern (no MSE, keyframe/GOP): https://webcodecsfundamentals.org/patterns/live-streaming/
- WebCodecs vs MSE vs WebRTC (low-level, no MSE overhead): https://webrtchacks.com/webcodecs-webtransport-and-webrtc/
- WebCodecs browser support / HW accel: https://www.testmuai.com/learning-hub/webcodecs-browser-support/
- WebCodecs latency/HW caveats: https://github.com/w3c/webcodecs/issues/899 ; https://github.com/w3c/webcodecs/issues/732
- "MSE for WebCodecs": https://github.com/w3c/media-source/issues/184
- WebRTC ultra-low latency / numbers: https://www.red5.net/blog/7-ways-webrtc-solves-ultra-low-latency-streaming/ ; https://www.nanocosmos.net/blog/webrtc-latency/
- WebTransport vs WebSockets (datagrams, HoL, support): https://www.videosdk.live/blog/websocket-vs-webtransport ; https://blog.openreplay.com/low-latency-browser-communication-webtransport/ ; https://www.gocodeo.com/post/webtransport-explained-low-latency-communication-over-http-3 ; https://techbytes.app/posts/webtransport-vs-websockets-low-latency-streaming-2026/ ; https://www.vroble.com/2025/11/beyond-websockets-mastering.html
- MSE not for low-latency: https://bugzilla.mozilla.org/show_bug.cgi?id=1520894 ; https://github.com/w3c/media-source/issues/21 ; https://www.w3.org/Bugs/Public/show_bug.cgi?id=28379 ; https://bugzilla.mozilla.org/show_bug.cgi?id=1290840
- MJPEG `multipart/x-mixed-replace` quirks: https://bugzilla.mozilla.org/show_bug.cgi?id=987135 ; https://github.com/WebPlatformForEmbedded/WPEWebKit/issues/569 ; https://groups.google.com/a/chromium.org/g/chromium-bugs/c/fz42h1hHp9I/m/nNoFqpy7y9kJ ; https://news.ycombinator.com/item?id=7349266 ; https://github.com/miguelgrinberg/flask-video-streaming/issues/16
- WebSocket binaryType (arraybuffer vs blob): https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/binaryType ; https://medium.com/samsung-internet-dev/being-fast-and-light-using-binary-data-to-optimise-libraries-on-the-client-and-the-server-5709f06ef105 ; https://developers.cloudflare.com/changelog/post/2026-04-21-websocket-standard-binary-type/
- WebSockets for real-time gaming: http://buildnewgames.com/websockets/ ; https://codezup.com/real-time-gaming-with-websockets/
- canvas drawImage vs putImageData / scaling / imageSmoothing: https://www.measurethat.net/Benchmarks/Show/9510/0/putimagedata-vs-drawimage ; https://www.middle-engine.com/blog/posts/2020/08/23/a-performance-testing-gotcha-with-the-canvas-web-api ; https://bugzilla.mozilla.org/show_bug.cgi?id=1602299
- requestAnimationFrame / coalescing / backpressure: https://dev.to/tawe/requestanimationframe-explained-why-your-ui-feels-laggy-and-how-to-fix-it-3ep2 ; https://www.sitepoint.com/streaming-backends-react-controlling-re-render-chaos/
- COOP/COEP / SharedArrayBuffer cross-origin isolation: https://web.dev/articles/coop-coep ; https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Embedder-Policy
