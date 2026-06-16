# HTTP static-file serving (a UI page from zdos)

Goal: open `http://localhost:PORT/` in a browser and get a UI page (HTML + JS/CSS).
This page will later host the live-stream player (see `video-stream-api.md`) — but
that is OUT OF SCOPE here. This plan is JUST static serving. Keep it minimal.

## This is NOT a new server — it extends the existing one

zdos already runs an HTTP/1.1 server: `std.http.Server` in `src/api/server.zig`.
The accept loop is `Server.serve` (`server.zig:172`), one connection at a time,
keep-alive OFF; each request is parsed in `serveOne` (`:227`) and routed in
`Server.dispatch` (`:273`) by an `if (std.mem.eql(...))` route chain ending in a
catch-all 404 (`:432`). Static serving is a handful of new branches in that chain
plus one helper — no new socket, thread, or accept loop.

Why serve the page from zdos at all (vs a separate static server): it makes the UI
**same-origin** with the API and the future stream. The browser's `fetch` to
`/api/*` and a future `WebSocket`/SSE to the stream endpoint then "just work" — no
CORS preflight, no cross-origin cookie/headers fuss, no second port to manage. That
same-origin property is the whole reason to put it here.

## Decisions

### 1. Route shape — bare `/` + top-level assets, keep `/api/*` for the API

- `GET /`            -> `index.html`
- `GET /app.js`      -> the app JS
- `GET /style.css`   -> the CSS
- (any other known asset name, e.g. `/favicon.ico`)

Rationale: a flat top-level layout is the simplest thing a browser expects from
`/`, and relative asset URLs in `index.html` (`<script src="app.js">`) resolve
naturally. `/api/*` stays the API namespace — the static branches sit AFTER all
`/api/...` branches and BEFORE the 404 catch-all in `dispatch`, so they can never
shadow an API route (an API path simply never reaches them). No `/ui/` or
`/static/` prefix — unnecessary for v1, and a prefix only earns its keep with a
large asset tree we don't have.

### 2. Embed, not disk — `@embedFile` for v1

Recommend `@embedFile`. zdos already embeds source/data this way (e.g. the CPU
determinism grep-gate, `cpu/determinism_test.zig:68`; `abi/timing.zig:75`), and it
fits the project ethos: a single self-contained deterministic binary, no runtime FS
dependency, and **no path-traversal attack surface at all** (the set of servable
files is fixed at compile time). `@embedFile` resolves relative to the importing
source file, so no `build.zig` change is needed.

Source files live next to the server:

```
src/api/web/index.html
src/api/web/app.js
src/api/web/style.css
```

Embedded in `server.zig` as `const index_html = @embedFile("web/index.html");` etc.

Dev-loop tradeoff (note, not v1 scope): embedded assets require a rebuild to see an
edit. If iterating on the UI becomes painful, a *later* opt-in `--web-root <dir>`
flag could serve from disk for edit-and-refresh — but that path MUST add a
path-traversal guard (reject `..`, absolute paths, NUL; canonicalize under the
root). Not now.

### 3. Content-Type map — tiny extension -> MIME helper

A small function `contentTypeFor(path) []const u8`, minimal:

| ext    | MIME                          |
|--------|-------------------------------|
| `.html`| `text/html; charset=utf-8`    |
| `.js`  | `text/javascript; charset=utf-8` |
| `.css` | `text/css; charset=utf-8`     |
| `.png` | `image/png`                   |
| `.ico` | `image/x-icon`                |
| `.svg` | `image/svg+xml`               |
| (else) | `application/octet-stream`    |

### 4. How it fits the server model — off-worker, cycle-neutral

Static serving needs ZERO machine access, exactly like `/api/health`
(`server.zig:280`, answered off-worker with a constant body). So it does NOT enqueue
a `Command`, does NOT touch the worker/queue, charges NO synthetic cycle, and raises
NO determinism concern (the listener thread already does all socket/HTTP work
without crossing to the worker). The one-command-in-flight model is undisturbed
because no command is submitted.

Slot: a `serveStatic(req, method, path)` helper, called from a new branch in
`dispatch` placed after the `/api/...` branches and before the final
`respondError(... .not_found ...)`. The embedded byte slices are written straight to
the socket via `req.respond(body, .{...})` — the same one-shot respond call
`respondJson` uses (`server.zig:992`). The assets are small (an HTML/JS/CSS page
fits well within the existing `resp_buf`/write buffers), and unlike
`/api/framebuffer` we are not streaming megabytes, so the simple `req.respond` path
is correct. If a future asset ever grows large, the binary-stream pattern in
`submitAndRespondFramebuffer` (`:721`) is the template — but v1 does not need it.

### 5. Basics & guards

- **Method guard**: GET and HEAD only; anything else -> 405 via the existing
  `methodNotAllowed` (`server.zig:975`). (HEAD = same headers, empty body; cheap to
  support and well-behaved. Optional — GET-only is acceptable for v1 if simpler.)
- **404** for an unknown asset name -> the existing `respondError(... .not_found
  ...)`.
- **Headers**: `content-type` from the map; `Cache-Control: no-cache` so a rebuilt
  binary's assets are never stale during dev. `Content-Length` is set by
  `req.respond` from the body slice — nothing extra to do. Keep-alive stays OFF (R1,
  consistent with every other response).
- **No auth** — localhost dev tool, consistent with the API today.
- **No path-traversal guard needed** with `@embedFile` (closed, compile-time file
  set). Only the optional future disk mode (§2) would require one — mandatory there.

### 6. Scope discipline

This plan is static serving ONLY. It does NOT design the WebSocket/SSE stream, the
frame protocol, or the player JS — that is `video-stream-api.md`. The served
`index.html`/`app.js` are simply *where* that player will later live; because the
page is same-origin (§ "Why serve the page from zdos"), wiring the stream into it
later is trivial. For v1, `index.html` can be a near-empty placeholder that fetches
`/api/health` (or `/api/status`) and shows it — just enough to prove the page loads
and same-origin `fetch` works.

## Implementation roadmap

- [ ] Create `src/api/web/index.html` — minimal placeholder page that does a
      same-origin `fetch('/api/health')` and renders the result (proves it works).
- [ ] Create `src/api/web/app.js` and `src/api/web/style.css` (can be tiny stubs).
- [ ] In `server.zig`, add `const index_html = @embedFile("web/index.html");` (and
      `app.js`, `style.css`) near the other top-of-file consts.
- [ ] Add `fn contentTypeFor(path: []const u8) []const u8` (the §3 map).
- [ ] Add `fn serveStatic(self, req, method, path) void`: GET/HEAD guard ->
      method-match path to embedded slice (`/` -> index_html) -> respond with
      content-type + `Cache-Control: no-cache`; unknown -> 404.
- [ ] In `dispatch` (`server.zig:273`), add the static branch AFTER the `/api/...`
      branches and BEFORE the catch-all 404 at `:432`.
- [ ] Tests in `server_test.zig` (driving `serveOne` over in-memory streams, the
      existing pattern): `GET /` -> 200 + `text/html`; `GET /app.js` -> 200 +
      `text/javascript`; `GET /nope` -> 404; `POST /` -> 405; assert an `/api/*`
      route still works (no shadowing).
- [ ] Update `plans/ROADMAP.md` with the landed static-serving entry.
