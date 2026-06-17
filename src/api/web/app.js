// zdos live player — WebGL2 indexed-frame renderer + keyboard/mouse round-trip.
//
// Connects to the same-origin WebSocket stream (`/api/stream`), decodes raw
// indexed VGA frames, expands index->RGB on the GPU via a palette texture, and
// forwards input to POST /api/input/key|mouse so the game is playable.
//
// Dependency-free, single file. No browser is available in CI, so correctness
// rests on (a) matching the server wire format byte-for-byte and (b) correct
// WebGL2 (integer index texture + texelFetch, NEAREST, UNPACK_ALIGNMENT=1).
//
// =====================================================================
// WIRE PROTOCOL — quoted verbatim from src/api/shared_frame.zig (§6.3).
// Fixed 22-byte header, LITTLE-ENDIAN, then index bytes [+ 768 palette bytes].
//
//   offset  size  field
//     0      2    magic         = 0x5A44   ('ZD', little-endian on the wire)
//     2      1    version       = 1
//     3      1    flags         bit0 = has_palette (palette bytes follow index)
//                               bit1 = unsupported (no pixels; control marker)
//     4      4    seqno         (u32, low 32 bits of the producer publish version)
//     8      2    width
//    10      2    height
//    12      1    kind          (vga_render.Kind enum value)
//    13      1    pel_mask      (DAC pixel mask; shader does index & pel_mask)
//    14      4    index_len     (= width*height)
//    18      4    palette_len   (768 when has_palette, else 0)
//    20      2    reserved      (zero)
//    22     ...   index bytes   (index_len)
//    ...    ...   palette bytes (palette_len; RGB triples, already 6->8 expanded)
// =====================================================================
"use strict";

(function () {
  // ---- protocol constants (must match shared_frame.zig) ----
  const HEADER_LEN = 22;
  const MAGIC = 0x5a44;
  const VERSION = 1;
  const FLAG_HAS_PALETTE = 1 << 0;
  const FLAG_UNSUPPORTED = 1 << 1;
  const PALETTE_LEN = 768;

  // ---- DOM ----
  const canvas = document.getElementById("screen");
  const overlay = document.getElementById("overlay");
  const overlayMsg = document.getElementById("overlay-msg");
  const statusEl = document.getElementById("status");
  const infoEl = document.getElementById("info");

  function setStatus(cls, text) {
    statusEl.classList.remove("pending", "ok", "err");
    statusEl.classList.add(cls);
    statusEl.textContent = text;
  }
  function showOverlay(text) {
    overlayMsg.textContent = text;
    overlay.classList.remove("hidden");
  }
  function hideOverlay() {
    overlay.classList.add("hidden");
  }

  // ===================================================================
  // WebGL2 renderer
  // ===================================================================
  const VERT_SRC = `#version 300 es
precision highp float;
// A single full-screen triangle: 3 verts cover the clip space, no buffers.
out vec2 vUv;
void main() {
  // gl_VertexID 0,1,2 -> clip positions (-1,-1),(3,-1),(-1,3).
  vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0,
                (gl_VertexID == 2) ? 3.0 : -1.0);
  // UV in 0..1; flip Y so row 0 of the index texture is the TOP of the image
  // (DOS framebuffers are top-down, GL clip space is bottom-up).
  vUv = vec2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
  gl_Position = vec4(p, 0.0, 1.0);
}`;

  const FRAG_SRC = `#version 300 es
precision highp float;
precision highp usampler2D;
uniform usampler2D uIndex;   // R8UI, width x height
uniform sampler2D  uPalette; // RGB8, 256 x 1
uniform uint uPelMask;       // DAC pixel mask
in vec2 vUv;
out vec4 fragColor;
void main() {
  // texelFetch with INTEGER coords — NEVER texture(): filtered sampling of an
  // integer (usampler2D / R8UI) texture is undefined.
  ivec2 sz = textureSize(uIndex, 0);
  ivec2 p = ivec2(vUv * vec2(sz));
  // clamp so the top/right edge texel (vUv==1.0) doesn't fetch out of range.
  p = clamp(p, ivec2(0), sz - 1);
  uint idx = texelFetch(uIndex, p, 0).r & uPelMask;
  vec3 rgb = texelFetch(uPalette, ivec2(int(idx), 0), 0).rgb;
  fragColor = vec4(rgb, 1.0);
}`;

  let gl = null;
  let prog = null;
  let uPelMaskLoc = null;
  let indexTex = null;
  let paletteTex = null;
  let texW = 0; // currently-allocated index texture dimensions
  let texH = 0;
  let havePalette = false; // a palette has been uploaded at least once

  function compileShader(type, src) {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      throw new Error("shader compile: " + gl.getShaderInfoLog(sh));
    }
    return sh;
  }

  function initGL() {
    gl = canvas.getContext("webgl2", {
      antialias: false,
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
      premultipliedAlpha: false,
    });
    if (!gl) throw new Error("WebGL2 is not available in this browser");

    const vs = compileShader(gl.VERTEX_SHADER, VERT_SRC);
    const fs = compileShader(gl.FRAGMENT_SHADER, FRAG_SRC);
    prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      throw new Error("program link: " + gl.getProgramInfoLog(prog));
    }
    gl.useProgram(prog);

    // Texture unit bindings are fixed: index on unit 0, palette on unit 1.
    gl.uniform1i(gl.getUniformLocation(prog, "uIndex"), 0);
    gl.uniform1i(gl.getUniformLocation(prog, "uPalette"), 1);
    uPelMaskLoc = gl.getUniformLocation(prog, "uPelMask");

    // 1-byte index rows -> alignment must be 1, or odd-width rows corrupt.
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);

    // ---- index texture (R8UI integer, NEAREST, CLAMP) ----
    indexTex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, indexTex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    // ---- palette texture (256x1 RGB8, NEAREST) ----
    paletteTex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, paletteTex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    // Allocate the 256x1 storage once; rows updated via texSubImage2D later.
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB8, 256, 1, 0, gl.RGB,
      gl.UNSIGNED_BYTE, null);
  }

  // (Re)allocate the index texture when the guest resolution changes; resize the
  // canvas backing store + viewport to match (NEAREST upscaling is done in CSS).
  function ensureSize(w, h) {
    if (w === texW && h === texH) return;
    texW = w;
    texH = h;
    canvas.width = w;
    canvas.height = h;
    gl.viewport(0, 0, w, h);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, indexTex);
    // Reallocate the integer index texture at the new size.
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8UI, w, h, 0, gl.RED_INTEGER,
      gl.UNSIGNED_BYTE, null);
  }

  function uploadIndex(w, h, indexBytes) {
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, indexTex);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RED_INTEGER,
      gl.UNSIGNED_BYTE, indexBytes);
  }

  function uploadPalette(paletteBytes) {
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, paletteTex);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 256, 1, gl.RGB,
      gl.UNSIGNED_BYTE, paletteBytes);
    havePalette = true;
  }

  function drawFrame(pelMask) {
    gl.useProgram(prog);
    gl.uniform1ui(uPelMaskLoc, pelMask >>> 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // ===================================================================
  // Wire parsing + drop-to-latest render loop
  // ===================================================================
  // Only the LATEST received ArrayBuffer is kept; the rAF loop draws it and never
  // queues. Stale frames the producer outran are simply overwritten and dropped.
  let latestBuf = null;
  let lastDrawnSeqno = -1;
  // The last palette bytes seen (frames without has_palette reuse the prior one).
  let lastPalette = null;

  function parseAndRender(buf) {
    if (buf.byteLength < HEADER_LEN) return; // truncated/garbage; ignore
    const dv = new DataView(buf);

    const magic = dv.getUint16(0, true);
    const version = dv.getUint8(2);
    if (magic !== MAGIC || version !== VERSION) return; // not our frame

    const flags = dv.getUint8(3);
    const seqno = dv.getUint32(4, true);
    const width = dv.getUint16(8, true);
    const height = dv.getUint16(10, true);
    // kind at byte 12 is informational; the unsupported flag drives rendering.
    const pelMask = dv.getUint8(13);
    const indexLen = dv.getUint32(14, true);
    const paletteLen = dv.getUint16(18, true); // u16 on the wire (bytes 20-21 are reserved)

    if (flags & FLAG_UNSUPPORTED) {
      // Non-graphics / text mode: show the overlay, keep the socket open, and
      // resume when a renderable frame arrives. Never fabricate pixels.
      showOverlay("non-graphics mode (text / unsupported) — streaming will resume");
      infoEl.textContent = "mode: unsupported";
      return;
    }

    // Slice the index bytes from the body.
    const indexStart = HEADER_LEN;
    const indexEnd = indexStart + indexLen;
    if (indexEnd > buf.byteLength) return; // malformed length
    const indexBytes = new Uint8Array(buf, indexStart, indexLen);

    // Palette: present only when the flag is set; otherwise reuse the last one.
    if (flags & FLAG_HAS_PALETTE) {
      const palLen = Math.min(paletteLen, PALETTE_LEN);
      const palEnd = indexEnd + palLen;
      if (palEnd <= buf.byteLength && palLen === PALETTE_LEN) {
        lastPalette = new Uint8Array(buf, indexEnd, PALETTE_LEN);
      }
    }
    if (!lastPalette) return; // can't render a paletted image without a palette yet

    ensureSize(width, height);
    uploadPalette(lastPalette);
    uploadIndex(width, height, indexBytes);
    drawFrame(pelMask);

    hideOverlay();
    infoEl.textContent = width + "×" + height + "  seq " + seqno;
    lastDrawnSeqno = seqno;
  }

  function renderLoop() {
    if (latestBuf) {
      const buf = latestBuf;
      latestBuf = null; // consume; only ever the newest is held
      try {
        parseAndRender(buf);
      } catch (err) {
        setStatus("err", "render error: " + err.message);
      }
    }
    requestAnimationFrame(renderLoop);
  }

  // ===================================================================
  // WebSocket: connect, drop-to-latest, reconnect
  // ===================================================================
  let ws = null;
  let reconnectTimer = null;
  let everConnected = false;

  function connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + "/api/stream";
    setStatus("pending", everConnected ? "reconnecting…" : "connecting…");
    showOverlay(everConnected ? "reconnecting…" : "connecting…");

    try {
      ws = new WebSocket(url);
    } catch (err) {
      scheduleReconnect();
      return;
    }
    ws.binaryType = "arraybuffer";

    ws.onopen = function () {
      everConnected = true;
      setStatus("ok", "connected");
    };

    ws.onmessage = function (ev) {
      if (typeof ev.data === "string") {
        // Control frame (§6.4): {"event":"stopped"|"unsupported", ...}.
        handleControl(ev.data);
        return;
      }
      // Binary frame: keep ONLY the latest (drop-to-latest). The rAF loop draws.
      latestBuf = ev.data;
    };

    ws.onclose = function () {
      setStatus("err", "disconnected");
      scheduleReconnect();
    };

    ws.onerror = function () {
      // onclose will follow; let it drive the reconnect.
      try { ws.close(); } catch (e) {}
    };
  }

  function handleControl(text) {
    let msg = null;
    try { msg = JSON.parse(text); } catch (e) { return; }
    if (!msg || !msg.event) return;
    if (msg.event === "stopped") {
      const reason = msg.reason != null ? String(msg.reason) : "stopped";
      const cyc = msg.cycle != null ? " @ cycle " + msg.cycle : "";
      showOverlay("program stopped: " + reason + cyc);
      setStatus("err", "stopped");
    } else if (msg.event === "unsupported") {
      showOverlay("non-graphics mode (text / unsupported)");
    }
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      connect();
    }, 1000);
  }

  // ===================================================================
  // Input round-trip
  // ===================================================================
  // KeyboardEvent.code (physical, layout-independent) -> set-1 scancode + ext.
  // Authority: src/bios/scancodes.zig (base `table` indices + `ext_table`). The
  // server's POST /api/input/key takes {scancode, make, ext} (json_wire.zig:84).
  // ext === true means the key is 0xE0-prefixed (the gray cursor cluster, gray
  // KP-Enter/KP-/, right Ctrl/Alt). The scancode is the BASE byte (NOT |0x80);
  // the server forms the break edge from make:false.
  const KEYMAP = {
    // row 1 (function + esc)
    Escape: [0x01, false],
    F1: [0x3b, false], F2: [0x3c, false], F3: [0x3d, false], F4: [0x3e, false],
    F5: [0x3f, false], F6: [0x40, false], F7: [0x41, false], F8: [0x42, false],
    F9: [0x43, false], F10: [0x44, false], F11: [0x57, false], F12: [0x58, false],
    // number row
    Backquote: [0x29, false],
    Digit1: [0x02, false], Digit2: [0x03, false], Digit3: [0x04, false],
    Digit4: [0x05, false], Digit5: [0x06, false], Digit6: [0x07, false],
    Digit7: [0x08, false], Digit8: [0x09, false], Digit9: [0x0a, false],
    Digit0: [0x0b, false], Minus: [0x0c, false], Equal: [0x0d, false],
    Backspace: [0x0e, false],
    // qwerty row
    Tab: [0x0f, false],
    KeyQ: [0x10, false], KeyW: [0x11, false], KeyE: [0x12, false],
    KeyR: [0x13, false], KeyT: [0x14, false], KeyY: [0x15, false],
    KeyU: [0x16, false], KeyI: [0x17, false], KeyO: [0x18, false],
    KeyP: [0x19, false], BracketLeft: [0x1a, false], BracketRight: [0x1b, false],
    Backslash: [0x2b, false],
    // home row
    CapsLock: [0x3a, false],
    KeyA: [0x1e, false], KeyS: [0x1f, false], KeyD: [0x20, false],
    KeyF: [0x21, false], KeyG: [0x22, false], KeyH: [0x23, false],
    KeyJ: [0x24, false], KeyK: [0x25, false], KeyL: [0x26, false],
    Semicolon: [0x27, false], Quote: [0x28, false], Enter: [0x1c, false],
    // bottom row
    ShiftLeft: [0x2a, false], ShiftRight: [0x36, false],
    KeyZ: [0x2c, false], KeyX: [0x2d, false], KeyC: [0x2e, false],
    KeyV: [0x2f, false], KeyB: [0x30, false], KeyN: [0x31, false],
    KeyM: [0x32, false], Comma: [0x33, false], Period: [0x34, false],
    Slash: [0x35, false],
    // modifiers + space
    ControlLeft: [0x1d, false], AltLeft: [0x38, false], Space: [0x39, false],
    // extended (0xE0-prefixed) right-hand modifiers
    ControlRight: [0x1d, true], AltRight: [0x38, true],
    // gray cursor / navigation cluster (extended)
    Insert: [0x52, true], Delete: [0x53, true],
    Home: [0x47, true], End: [0x4f, true],
    PageUp: [0x49, true], PageDown: [0x51, true],
    ArrowUp: [0x48, true], ArrowDown: [0x50, true],
    ArrowLeft: [0x4b, true], ArrowRight: [0x4d, true],
    // numeric keypad (NumLock state handled guest-side by the INT 09h machine)
    NumLock: [0x45, false], ScrollLock: [0x46, false],
    Numpad7: [0x47, false], Numpad8: [0x48, false], Numpad9: [0x49, false],
    NumpadSubtract: [0x4a, false], Numpad4: [0x4b, false], Numpad5: [0x4c, false],
    Numpad6: [0x4d, false], NumpadAdd: [0x4e, false], Numpad1: [0x4f, false],
    Numpad2: [0x50, false], Numpad3: [0x51, false], Numpad0: [0x52, false],
    NumpadDecimal: [0x53, false], NumpadMultiply: [0x37, false],
    // gray keypad keys (extended): KP-Enter and KP-/
    NumpadEnter: [0x1c, true], NumpadDivide: [0x35, true],
  };

  function postJSON(path, obj) {
    // Fire-and-forget; keepalive so a key-up still flushes on tab close.
    fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(obj),
      keepalive: true,
    }).catch(function () { /* swallow; input is best-effort */ });
  }

  function sendKey(scancode, ext, make) {
    postJSON("/api/input/key", { scancode: scancode, make: make, ext: ext });
  }

  // Track held keys so OS auto-repeat (repeated keydown without keyup) sends a
  // single make and we don't spam breaks.
  const held = Object.create(null);

  window.addEventListener("keydown", function (e) {
    const m = KEYMAP[e.code];
    if (!m) return;
    e.preventDefault(); // game owns these keys; don't scroll/navigate
    if (held[e.code]) return; // ignore auto-repeat
    held[e.code] = true;
    sendKey(m[0], m[1], true);
  });

  window.addEventListener("keyup", function (e) {
    const m = KEYMAP[e.code];
    if (!m) return;
    e.preventDefault();
    if (!held[e.code]) return;
    held[e.code] = false;
    sendKey(m[0], m[1], false); // break edge (server forms code|0x80)
  });

  // ---- mouse (LIVE coalesced path, plans/mouse-input.md LOCKED §2/§3/§4) ----
  // Send a Q16-NORMALIZED absolute over the CONTAINED image rect (object-fit:contain
  // letterbox-aware geometry, reused below) so the SERVER scales by the driver's live
  // per-mode range (0–639 in mode 13h) — the half-speed-X fix (the old path mapped to
  // 320 guest px). The mickeys come from the browser's TRUE relative channel
  // (movementX/movementY), sent ALONGSIDE the absolute as integers — NOT derived from
  // the absolute Δ. The server folds these non-blocking into LiveMouseState and the
  // pacer drains them at the slice boundary (≤ one slice latency).
  const Q16 = 65536;
  let lastButtons = 0;
  let mouseThrottle = false; // ~rAF-rate throttle for mousemove

  // Normalize client coords -> [0,1] Q16 over the CONTAINED (letterboxed) image rect.
  // The displayed image is the largest gw:gh rectangle that fits `rect`, centered
  // (object-fit:contain); mapping against that rect (not the full element) keeps the
  // letterbox bands from skewing the coordinates. `texW/texH` (the guest resolution)
  // only sets the IMAGE ASPECT for the contain math — the OUTPUT is normalized, so the
  // half-speed-X bug (mapping to 320 px) is gone. Falls back to the canvas aspect
  // before the first frame (texW/texH == 0).
  function guestCoordsNorm(e) {
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return null;
    const gw = texW || canvas.width;
    const gh = texH || canvas.height;
    const scale = Math.min(rect.width / gw, rect.height / gh);
    const dispW = gw * scale, dispH = gh * scale;
    const offX = (rect.width - dispW) / 2, offY = (rect.height - dispH) / 2;
    let nx = (e.clientX - rect.left - offX) / dispW;
    let ny = (e.clientY - rect.top - offY) / dispH;
    nx = Math.min(1, Math.max(0, nx));
    ny = Math.min(1, Math.max(0, ny));
    // [0,1] -> Q16 integer (the wire is integer; no float crosses to the server).
    return { nx_q16: Math.round(nx * Q16), ny_q16: Math.round(ny * Q16) };
  }

  canvas.addEventListener("mousemove", function (e) {
    if (mouseThrottle) return;
    mouseThrottle = true;
    requestAnimationFrame(function () { mouseThrottle = false; });
    const c = guestCoordsNorm(e);
    if (!c) return;
    // movementX/movementY: the browser's TRUE relative channel (integers). Sent
    // alongside the Q16 absolute so the guest's AX=0B mickeys reflect real motion.
    postJSON("/api/input/mouse", {
      nx_q16: c.nx_q16,
      ny_q16: c.ny_q16,
      mdx: e.movementX | 0,
      mdy: e.movementY | 0,
    });
  });

  // DOM MouseEvent.buttons mask: bit0 left(1), bit1 right(2), bit2 middle(4).
  // The server's mouse `buttons` mask: bit0 left, bit1 right, bit2 middle
  // (json_wire.zig) — same bit assignment, so we forward bit-for-bit (masking
  // off DOM's back/forward bits 3/4 which the guest has no concept of).
  function domButtonsToGuest(domButtons) {
    let b = 0;
    if (domButtons & 1) b |= 1; // left
    if (domButtons & 2) b |= 2; // right
    if (domButtons & 4) b |= 4; // middle
    return b;
  }

  function sendButtons(e) {
    e.preventDefault();
    const c = guestCoordsNorm(e);
    lastButtons = domButtonsToGuest(e.buttons);
    // A click carries the Q16 absolute too (so the latched position is current). If the
    // rect isn't measurable yet, send buttons alone (still routes to the live path
    // because we tag it with a zero-movement delta marker).
    const body = { buttons: lastButtons, mdx: 0, mdy: 0 };
    if (c) { body.nx_q16 = c.nx_q16; body.ny_q16 = c.ny_q16; }
    postJSON("/api/input/mouse", body);
  }

  canvas.addEventListener("mousedown", function (e) {
    canvas.focus();
    sendButtons(e);
  });
  canvas.addEventListener("mouseup", sendButtons);
  // Suppress the context menu so right-click is usable in-game.
  canvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });

  // ===================================================================
  // Speed knob — retunes the pacer's slice size live (wall-clock speed only,
  // NOT determinism). Effective cycles/sec ≈ slice_cycles * 100, so we label it
  // in MHz with slice_cycles = MHz * 10000 (25 MHz == the 250000 default slice).
  // ===================================================================
  var CYCLES_PER_MHZ = 10000; // slice_cycles per 1 MHz at the ~10 ms slice cadence

  function setupSpeedKnob() {
    var range = document.getElementById("speed-range");
    var valEl = document.getElementById("speed-val");
    if (!range || !valEl) return;

    function render(mhz) { valEl.textContent = mhz + " MHz"; }

    function apply(mhz) {
      render(mhz);
      postJSON("/api/run/start", { slice_cycles: mhz * CYCLES_PER_MHZ });
    }

    range.addEventListener("input", function () { apply(parseInt(range.value, 10)); });

    // Sync the slider to the server's CURRENT slice on load (so the knob reflects
    // reality and a reconnect doesn't silently reset the displayed speed).
    fetch("/api/run/status")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (s) {
        if (!s || typeof s.slice_cycles !== "number") return;
        var mhz = Math.round(s.slice_cycles / CYCLES_PER_MHZ);
        var min = parseInt(range.min, 10), max = parseInt(range.max, 10);
        if (mhz < min) mhz = min; else if (mhz > max) mhz = max;
        range.value = String(mhz);
        render(mhz);
      })
      .catch(function () { /* leave the default 25 MHz display */ });
  }

  // ===================================================================
  // Boot
  // ===================================================================
  function main() {
    try {
      initGL();
    } catch (err) {
      setStatus("err", err.message);
      showOverlay("WebGL2 unavailable: " + err.message);
      return;
    }
    requestAnimationFrame(renderLoop);
    connect();
    setupSpeedKnob();
    canvas.focus();
  }

  main();
})();
