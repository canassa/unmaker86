//! The server-owned shared latest-frame buffer (video-stream §4.2) + the raw-indexed
//! wire protocol (§6.3). ONE instance lives on the server for the whole process; the
//! frame producer writes it under a mutex and bumps a seqno; each stream-connection
//! thread reads the seqno lock-free as an "is there new data" signal, then copies the
//! BODY only under the same mutex into a per-thread buffer.
//!
//! Determinism (CLAUDE #4): this is pure host-side OBSERVATION. The producer copies an
//! immutable framebuffer snapshot (the cycle-neutral peek into `RenderBuffers`) into
//! this buffer; the consumers only read it. Nothing here reads a host clock, charges a
//! cycle, or feeds back into emulation ordering. It is CLOCKLESS (only `std.atomic` +
//! a no-timeout `Io.Mutex`), so it is safe inside the `src/api` determinism grep-gate.
//!
//! Cited 0.16 stdlib APIs (verified against `references/zig/lib/std/`):
//!   - `std.atomic.Value(u64)` with `.load(.acquire)` / `.store(v, .release)`.
//!   - `std.Io.Mutex` (`Io.zig:1587`): `lockUncancelable(io)` / `unlock(io)` — the
//!     no-timeout variants, matching the command queue (no clock in the handoff).
//!   - `std.hash.Wyhash.hash(seed, bytes)` (`hash/wyhash.zig:178`) — non-crypto, NOT
//!     the SHA-256 used for goldens; used only for cheap frame-dedup.

const std = @import("std");
const debug = @import("debug");
const Io = std.Io;

/// The palette-index image cap (640x480 = 307200). The shared body sizes for the
/// widest standard VGA mode the rasterizer supports (no VESA).
pub const INDEX_CAP: usize = debug.RENDER_INDEX_CAP;
/// The 256-entry expanded RGB palette (6->8 already applied by the worker peek).
pub const PALETTE_LEN: usize = 768;
/// The inline cap for a terminal "stopped" reason token (e.g. "program_terminated").
pub const STOP_REASON_CAP: usize = 32;

/// The fixed wire header (§6.3): little-endian, 22 bytes. The index bytes (and, when
/// `has_palette`, the 768 palette bytes) follow it as the WebSocket binary payload.
pub const HEADER_LEN: usize = 22;
pub const MAGIC: u16 = 0x5A44; // 'ZD' (little-endian on the wire)
pub const VERSION: u8 = 1;

/// Header flag bits.
pub const FLAG_HAS_PALETTE: u8 = 1 << 0;
pub const FLAG_UNSUPPORTED: u8 = 1 << 1;

/// The maximum WS payload: header + full index + palette. ~308 KiB.
pub const MAX_PAYLOAD: usize = HEADER_LEN + INDEX_CAP + PALETTE_LEN;

/// The shared latest-frame buffer. ONE per server, heap-allocated once (like `render`).
/// The producer fills `index`/`palette`/scalars under `mutex`, bumps `palette_seq` iff
/// the palette changed, then `seqno.store(.release)`. Consumers `seqno.load(.acquire)`
/// to decide whether to take `mutex` and copy the body; the body is NEVER read outside
/// the mutex (a bare seqno compare is only the "new data?" gate, NOT a seqlock body
/// read — the producer's memcpy could be mid-flight).
pub const SharedFrame = struct {
    /// The publish version (monotonic). Truncated to u32 only on the wire (§6.3).
    seqno: std.atomic.Value(u64) = .init(0),
    /// Guards the body (index + palette + scalars) during copy-in / copy-out. NOT
    /// `std.Thread.Mutex` (it does not exist in 0.16) — `std.Io.Mutex` (§4.2).
    mutex: Io.Mutex = .init,
    /// Consumers PARK on this (clockless `waitUncancelable`) until the producer
    /// publishes a new frame or `wakeAll` is called at shutdown — no busy-spin, no host
    /// clock. Broadcast by `publish` and `wakeAll`.
    new_frame: Io.Condition = .init,
    /// A monotonic wake epoch, bumped by `wakeAll` so a consumer's predicate can break
    /// out at shutdown even if no new frame arrived. Read/written under `mutex`.
    wake_epoch: u64 = 0,
    /// Held once at construction so the helpers need no `io` argument per call (the
    /// uncontended lock/unlock is a CAS pair; only a contended wait touches a futex —
    /// no clock). Set by `init`.
    io: Io,

    // --- body (valid only under `mutex`) ---
    width: u16 = 0,
    height: u16 = 0,
    kind: u8 = 0,
    pel_mask: u8 = 0xFF,
    supported: bool = false,
    /// Set once when the guest PROGRAM TERMINATES (program_terminated/halted_forever),
    /// NOT on a user `/api/run/stop` or a breakpoint (those are debugger/user actions).
    /// Published by the pacer via `StreamHub.markStopped`; consumers send a one-shot
    /// `{"event":"stopped",...}` control frame (§6.4) and keep the connection open.
    stopped: bool = false,
    /// The terminal cycle (machine's final cycle) when `stopped` was set.
    stop_cycle: u64 = 0,
    /// A short reason token (e.g. "program_terminated"/"halted") + its length, stored
    /// inline (pointer-free) so the consumers can copy it out under the same mutex.
    stop_reason: [STOP_REASON_CAP]u8 = undefined,
    stop_reason_len: u8 = 0,
    index_len: u32 = 0,
    /// Bumped only when the palette bytes change vs. the previous publish, so a
    /// connection can tell whether to (re)send the palette (§4.2/§6.3).
    palette_seq: u64 = 0,
    /// Wyhash(index[0..index_len] ++ palette) — computed once by the producer; the
    /// per-connection dedup compares it to its `last_hash` (§4.3).
    frame_hash: u64 = 0,
    index: [INDEX_CAP]u8 = undefined,
    palette: [PALETTE_LEN]u8 = undefined,

    pub fn init(io: Io) SharedFrame {
        return .{ .io = io };
    }

    /// The producer's snapshot — what `framebuffer_get` returned + the server-owned
    /// render buffers it filled. Pointer-free copy IN happens under the mutex.
    pub const Publish = struct {
        supported: bool,
        width: u16,
        height: u16,
        kind: u8,
        pel_mask: u8,
        index: []const u8, // index[0..index_len] in RenderBuffers
        palette: []const u8, // the 768-byte expanded palette in RenderBuffers
    };

    /// Producer side (§4.2): copy the snapshot into the shared body under the mutex,
    /// bump `palette_seq` iff the palette changed, then publish via `seqno` and wake
    /// parked consumers. The mutex is held ONLY for the memcpy (sub-ms) — a slow
    /// consumer can never back-pressure the producer (it copies out under the same short
    /// critical section, then sends outside the lock). The hash is computed BEFORE taking
    /// the lock to shorten it.
    pub fn publish(self: *SharedFrame, p: Publish) void {
        // Hash index + palette together (palette-only fades are NOT skipped, §4.3).
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(p.index);
        if (p.supported) hasher.update(p.palette);
        const new_hash = hasher.final();

        self.mutex.lockUncancelable(self.io);
        const palette_changed = self.palette_seq == 0 or !std.mem.eql(u8, self.palette[0..], p.palette[0..@min(p.palette.len, PALETTE_LEN)]);
        self.supported = p.supported;
        self.width = p.width;
        self.height = p.height;
        self.kind = p.kind;
        self.pel_mask = p.pel_mask;
        self.index_len = @intCast(@min(p.index.len, INDEX_CAP));
        @memcpy(self.index[0..self.index_len], p.index[0..self.index_len]);
        const pn = @min(p.palette.len, PALETTE_LEN);
        @memcpy(self.palette[0..pn], p.palette[0..pn]);
        if (palette_changed) self.palette_seq += 1;
        self.frame_hash = new_hash;
        // Publish AFTER the body is written; the atomic store is for the lock-free
        // currentSeqno() gate (the body is only ever read under the mutex anyway).
        _ = self.seqno.fetchAdd(1, .release);
        // Wake every parked consumer (broadcast) while still under the mutex.
        self.new_frame.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Wake all parked consumers WITHOUT publishing a new frame (used at shutdown so a
    /// thread blocked in `waitNext` re-checks its stop flag and exits). Bumps the wake
    /// epoch so the predicate breaks even without a seqno change.
    pub fn wakeAll(self: *SharedFrame) void {
        self.mutex.lockUncancelable(self.io);
        self.wake_epoch += 1;
        self.new_frame.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Mark the stream as STOPPED because the guest program ended (§6.4): record the
    /// reason token + terminal cycle under the mutex, bump the seqno so parked consumers
    /// wake and observe it via `copyOut`, then broadcast. Idempotent — re-marking an
    /// already-stopped frame is a no-op (so a dead machine isn't re-signaled every tick).
    /// CLOCKLESS (no host clock; the cycle is the EMULATED cycle counter, not wall time).
    pub fn markStopped(self: *SharedFrame, reason: []const u8, cycle: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopped) return; // already signaled — don't re-publish
        const n = @min(reason.len, STOP_REASON_CAP);
        @memcpy(self.stop_reason[0..n], reason[0..n]);
        self.stop_reason_len = @intCast(n);
        self.stop_cycle = cycle;
        self.stopped = true;
        // Bump the publish version so a parked `waitNext` returns and the consumer
        // copies the stopped state out (the body bytes are unchanged — this rides the
        // same "new state" gate as a frame publish).
        _ = self.seqno.fetchAdd(1, .release);
        self.new_frame.broadcast(self.io);
    }

    /// The consumer's local snapshot of the shared body (copied OUT under the mutex
    /// into a per-thread buffer). Dedup + WS send happen on this, OUTSIDE the lock.
    pub const Snapshot = struct {
        seqno: u64,
        supported: bool,
        width: u16,
        height: u16,
        kind: u8,
        pel_mask: u8,
        palette_seq: u64,
        frame_hash: u64,
        index_len: u32,
        /// True when the guest program terminated (consumers send a one-shot control
        /// frame). `stop_reason` is the inline token (valid for `stop_reason_len` bytes,
        /// stored in the caller's per-thread reason buffer); `stop_cycle` the final cycle.
        stopped: bool,
        stop_cycle: u64,
        stop_reason: []const u8,
        /// Filled into the caller's per-thread buffers.
        index: []u8,
        palette: []u8,
    };

    /// The current publish version (the lock-free "is there new data?" gate). A
    /// consumer compares this to its last-seen seqno BEFORE bothering to take the mutex.
    pub fn currentSeqno(self: *const SharedFrame) u64 {
        return self.seqno.load(.acquire);
    }

    /// True once the guest program terminated (the producer should stop sampling the dead
    /// machine). Read under the mutex (the `stopped` flag is set there by `markStopped`).
    pub fn isStopped(self: *SharedFrame) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopped;
    }

    /// Consumer side: PARK (clockless) until the publish seqno advances past `last`, or
    /// `stop` is set, or `wakeAll` fires — no busy-spin, no host clock. Returns the
    /// current seqno (which the caller compares to `last` to decide whether a new frame
    /// is available; on a stop wake the caller re-checks `stop` and exits). The wait is a
    /// PREDICATE loop (lost/spurious-wakeup safe), reading `seqno`/`wake_epoch` under the
    /// mutex. The first call (last==0 with seqno already 0) returns immediately so a
    /// fresh client gets the current frame without waiting for a change.
    pub fn waitNext(self: *SharedFrame, last: u64, stop: *const std.atomic.Value(bool)) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.seqno.load(.acquire) == last and !stop.load(.acquire)) {
            self.new_frame.waitUncancelable(self.io, &self.mutex);
        }
        return self.seqno.load(.acquire);
    }

    /// Consumer side (§4.2): copy the body into the caller's per-thread `index_dst` /
    /// `palette_dst` (and the stopped reason into `reason_dst`) under the mutex and
    /// return the snapshot descriptor. The body is read ONLY here, under the lock.
    /// `index_dst` must be >= INDEX_CAP, `palette_dst` >= PALETTE_LEN, and `reason_dst`
    /// >= STOP_REASON_CAP.
    pub fn copyOut(self: *SharedFrame, index_dst: []u8, palette_dst: []u8, reason_dst: []u8) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = self.index_len;
        @memcpy(index_dst[0..n], self.index[0..n]);
        @memcpy(palette_dst[0..PALETTE_LEN], self.palette[0..PALETTE_LEN]);
        const rn = self.stop_reason_len;
        @memcpy(reason_dst[0..rn], self.stop_reason[0..rn]);
        return .{
            // Read the seqno under the lock so it pairs with the body we just copied.
            .seqno = self.seqno.load(.acquire),
            .supported = self.supported,
            .width = self.width,
            .height = self.height,
            .kind = self.kind,
            .pel_mask = self.pel_mask,
            .palette_seq = self.palette_seq,
            .frame_hash = self.frame_hash,
            .index_len = n,
            .stopped = self.stopped,
            .stop_cycle = self.stop_cycle,
            .stop_reason = reason_dst[0..rn],
            .index = index_dst[0..n],
            .palette = palette_dst[0..PALETTE_LEN],
        };
    }
};

/// Write the 22-byte little-endian frame header (§6.3) into `dst[0..HEADER_LEN]`.
/// `dst` must be at least `HEADER_LEN` bytes.
pub fn writeHeader(
    dst: []u8,
    seqno: u32,
    flags: u8,
    width: u16,
    height: u16,
    kind: u8,
    pel_mask: u8,
    index_len: u32,
    palette_len: u16,
) void {
    std.debug.assert(dst.len >= HEADER_LEN);
    std.mem.writeInt(u16, dst[0..2], MAGIC, .little);
    dst[2] = VERSION;
    dst[3] = flags;
    std.mem.writeInt(u32, dst[4..8], seqno, .little);
    std.mem.writeInt(u16, dst[8..10], width, .little);
    std.mem.writeInt(u16, dst[10..12], height, .little);
    dst[12] = kind;
    dst[13] = pel_mask;
    std.mem.writeInt(u32, dst[14..18], index_len, .little);
    std.mem.writeInt(u16, dst[18..20], palette_len, .little);
    // Bytes 20..22 are reserved (the header is fixed at 22) — zero them.
    dst[20] = 0;
    dst[21] = 0;
}

test "writeHeader lays the §6.3 little-endian layout" {
    var buf: [HEADER_LEN]u8 = undefined;
    writeHeader(&buf, 0x12345678, FLAG_HAS_PALETTE, 320, 200, 5, 0xFF, 320 * 200, 768);
    try std.testing.expectEqual(MAGIC, std.mem.readInt(u16, buf[0..2], .little));
    try std.testing.expectEqual(VERSION, buf[2]);
    try std.testing.expectEqual(FLAG_HAS_PALETTE, buf[3]);
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u16, 320), std.mem.readInt(u16, buf[8..10], .little));
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[10..12], .little));
    try std.testing.expectEqual(@as(u8, 5), buf[12]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[13]);
    try std.testing.expectEqual(@as(u32, 320 * 200), std.mem.readInt(u32, buf[14..18], .little));
    try std.testing.expectEqual(@as(u16, 768), std.mem.readInt(u16, buf[18..20], .little));
}
