//! `SourceDebugger` — the protocol-neutral, source-level debug core object (M-S1).
//!
//! It holds a `*Controller` (the synchronous run/peek substrate) plus a host-side
//! Borland TDS symbol overlay (`Symbols` + the runtime `AddressMap`) re-attached on
//! every load — exactly the `LoadRecipe` precedent. It implements: attach-on-load,
//! `pcLocation`, source/function/addr breakpoint resolution (+ re-resolution across a
//! reload), and the four source-step kinds.
//!
//! Worker-side stepping split (debug-core-plan.md §5, Finding 1): this module is on the
//! `src/debug` determinism grep-gate, so it may NOT poll `RunControl.preemptRequested()`
//! (an atomic) and may NOT import `src/api`. It therefore exposes only the BOUNDED burst
//! primitive `stepBurst(budget) -> StepOutcome` (after a `beginStep`); the WORKER owns
//! the preempt-polling loop around it. A pure, non-preemptible convenience
//! (`stepLine`/`stepIn`/`stepOut`/`runToLine`) loops the burst to completion under the
//! fixed `STEP_WEDGE_CAP_CYCLES` ceiling — used by in-process tests and the simplest
//! blocking callers. Both share `beginStep` + `stepBurst` so the stop semantics are one
//! implementation.
//!
//! Determinism (CLAUDE.md §1): pure + synchronous. Run/step/run-to compose existing
//! `Controller` primitives; breakpoints are `execution_address{linear}` (no new kind);
//! inspection is the side-effect-free peek path. The only machine state the symbol path
//! consumes is `psp_seg`, via `AddressMap.attach`. No host clock/RNG/atomic/thread/float.

const std = @import("std");
const core = @import("core.zig");
const controller = @import("../controller.zig");
const symbols = @import("../symbols/symbols.zig");
const types = @import("../symbols/types.zig");

const Controller = controller.Controller;
const StopReason = controller.StopReason;
const Symbols = symbols.Symbols;
const AddressMap = symbols.AddressMap;

const Addr = core.Addr;
const SourceLoc = core.SourceLoc;
const PcLocation = core.PcLocation;
const BreakpointSpec = core.BreakpointSpec;
const ResolvedBreakpoint = core.ResolvedBreakpoint;
const StopKind = core.StopKind;
const StopState = core.StopState;
const StepKind = core.StepKind;
const StepOutcome = core.StepOutcome;

pub const Error = error{
    /// An inspection / step op was issued while a (background) run was in flight — the
    /// live BP/SP/registers are only meaningful at a clean instruction boundary.
    NotStopped,
    /// A source/function op needs the symbol overlay, which is absent (stripped image).
    NoSymbols,
    /// A `file:line` / function name resolved to no code address.
    Unresolved,
    /// The fixed 64-slot breakpoint spec table is full.
    SpecTableFull,
    /// Propagated from `Controller.addBreakpoint`.
    BreakpointTableFull,
    NoSuchBreakpoint,
};

/// Max source/function/addr breakpoint specs (mirrors `BreakpointSet`'s 64).
pub const MAX_SPECS = 64;

const SlotKind = enum { addr, function, source };

/// One persisted breakpoint spec ↔ its resolved `Controller` breakpoint id. The spec
/// text is OWNED (copied) so it survives the frontend's buffer and a reload.
const SpecSlot = struct {
    active: bool = false,
    kind: SlotKind = .addr,
    ctrl_id: ?u32 = null, // the underlying Controller breakpoint id (null ⇒ unresolved)
    linear: u32 = 0,
    verified: bool = false,
    line: u32 = 0,
    name_len: u8 = 0,
    name_buf: [128]u8 = undefined, // file path (source) or function name (function)

    fn name(self: *const SpecSlot) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn setName(self: *SpecSlot, s: []const u8) void {
        const n = @min(s.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

const LineKey = struct { file_id: u32, line: u16 };

/// The cross-burst state of an in-flight source step (the `beginRunToAddress` analog).
const StepSession = struct {
    active: bool = false,
    kind: StepKind = .line,
    start_line: ?LineKey = null,
    start_sp: u32 = 0, // the 16-bit SP captured at begin (frame anchor)
    oneshot_id: ?u32 = null, // the return / target one-shot (stepOut / runToLine)
    ret_linear: u32 = 0, // the stepOut return address (re-armed past a recursion false-hit)
    guard_sp: u32 = 0, // SP once the stepped-out frame tears down
};

const State = enum { configuring, running, stopped, terminated };

// ─────────────────────────── source cache (M-S1.5) ───────────────────────────
// A bounded, SourceDebugger-owned table of source-file TEXT (host-side, OUTSIDE the
// machine — never snapshotted), built eagerly at load from the configured source roots
// (the worker does the host reads; the core only STORES + RENDERS owned bytes). Same
// lifetime as the symbol overlay: freed/rebuilt by `attachOnLoad`, freed in `deinit`.

/// Max distinct source files cached (a fixed slot table, never an LRU).
pub const MAX_CACHED_SOURCES = 64;
/// Per-file cap on the STORED (transcoded) bytes; a larger file is SKIPPED (`has=false`,
/// graceful) — never truncated mid-file.
pub const MAX_SOURCE_BYTES: usize = 512 * 1024;
/// Total source-cache budget across all files; a file that would push past it is SKIPPED
/// in ascending `file_id` order — never evicts an already-admitted file (finding #8), so
/// the cached set is a pure function of `(file_id order, sizes, budget)`.
pub const MAX_TOTAL_SOURCE_BYTES: usize = 8 * 1024 * 1024;

/// One cached source file: owned UTF-8 (CP437-transcoded, TAB-expanded, CR-stripped)
/// bytes with NEWLINES REMOVED (pure separators), plus a `line_starts` index where
/// `line_starts[i]` is the byte offset of line `i+1` and `line_starts[len-1] == bytes.len`
/// (so line `n`'s content == `bytes[line_starts[n-1]..line_starts[n]]`, an O(1) slice).
const CachedSource = struct {
    file_id: u32 = 0,
    root_index: u8 = 0,
    active: bool = false,
    bytes: []u8 = &.{},
    line_starts: []u32 = &.{},
};

/// CP437 high-half (0x80..0xFF) → Unicode scalar table. The standard IBM PC code page;
/// ASCII 0x00..0x7F is identity (handled separately). Used by `cacheSource` to transcode
/// DOS source to valid UTF-8 so the wire body is never invalid-UTF-8 / a lone high byte
/// (plan §5/R1, CLAUDE.md §2 — no silent smear).
const cp437_high = [128]u21{
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
    0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
    0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
    0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
    0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
    0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
    0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
};

/// The tab stop used when expanding `\t` at cache time (plan §5: expand, do not escape).
const TAB_STOP = 8;

/// Transcode a single guest CP437 byte to its Unicode scalar (ASCII 0x00..0x7F is identity;
/// 0x80..0xFF via `cp437_high`). The M-S2 JSON emitters use this (T16c) so a raw high byte
/// in a symbol name / source path is valid UTF-8 BEFORE it reaches `encodeJsonString` —
/// never invalid UTF-8 or a panic under `escape_unicode`. Pure, host-clock/RNG/float-free.
pub fn cp437Scalar(b: u8) u21 {
    return if (b < 0x80) @as(u21, b) else cp437_high[b - 0x80];
}

// ─────────────────────────── expansion-handle / stop-epoch (M-S2 §3.5) ───────────────────────────
// A HOST-SIDE table (never snapshotted, never in `Machine.Snapshot`) that backs the DAP
// `variablesReference`. A struct/array/pointer var mints a slot; `variables{ref}` re-peeks
// it AT THE SAME STOP. We must NEVER serve a stale handle (from a prior stop) as a silent
// wrong read (CLAUDE.md §2) — so the ref packs a strictly-monotonic `stop_epoch`, and
// validation rejects a prior-epoch handle with `error.StaleHandle`.

/// Max live expansion handles within one Stopped epoch (fits the 16-bit slot field; a
/// table this deep never occurs in interactive use — an over-full mint degrades to a
/// non-expandable var, honest, never a wrong slot).
pub const MAX_HANDLES = 256;

/// What one node the variable being expanded is. The base linear address + type is enough
/// to re-peek the children at the same stop, so expansion never re-walks the scope path.
pub const ExpandTarget = enum { locals, aggregate, array, pointee };

/// One expansion node (what a `variables_ref` encodes). Pointer-free integers only.
pub const ExpandNode = struct {
    target: ExpandTarget,
    frame_index: u32 = 0,
    /// The type to expand (aggregate/array/pointee element type). Unused for `.locals`.
    type_ref: u16 = 0,
    /// Where the aggregate/array lives, or the pointer's pointee target (`.pointee`). For
    /// `.locals` this is the frame's `frame_base` carried in `off` (with `linear`=ss_base+bp).
    base: Addr = .{ .seg = 0, .off = 0, .linear = 0 },
    /// For a `.pointee`: which segment base the near/far pointer resolves against.
    seg_sel: types.PtrKind = .near,
    /// Array element count (for `.array` paging bounds).
    elem_count: u32 = 0,
};

const ExpandTable = struct {
    nodes: [MAX_HANDLES]ExpandNode = undefined,
    count: u16 = 0,
};

pub const SourceDebugger = struct {
    gpa: std.mem.Allocator,
    ctrl: *Controller,
    /// The symbol overlay for the currently-loaded program (rebuilt by `attachOnLoad`).
    /// Heap-stable address (the SourceDebugger itself is heap-owned by the Session), so
    /// `map` may borrow `&self.syms.?.index`.
    syms: ?Symbols = null,
    map: ?AddressMap = null,
    specs: [MAX_SPECS]SpecSlot = @splat(.{}),
    step: StepSession = .{},
    state: State = .configuring,
    /// STRICTLY MONOTONIC for the Session lifetime (T1). Starts at 0 ONLY for a fresh
    /// `init`; thereafter EVERY resume (`beginResume`/`beginStep`) and `attachOnLoad`/
    /// `onMachineReverted` only `+%= 1` it — it is NEVER reset to 0. Deliberately placed
    /// OUTSIDE the `self.step = .{}` reset (below) so the reset reflex cannot zero it: a
    /// prior-stop handle (`ref` reusing a cleared slot) is then always detectably stale.
    stop_epoch: u64 = 0,
    /// The expansion-handle table (host-side, never snapshotted). `count` is cleared on
    /// every resume; the nodes are rebuilt fresh each Stopped epoch.
    expand: ExpandTable = .{},
    /// The bounded source-TEXT cache (M-S1.5). Owned host-side bytes, NEVER snapshotted;
    /// freed/rebuilt by `attachOnLoad` (same lifetime as `syms`/`map`).
    sources: [MAX_CACHED_SOURCES]CachedSource = @splat(.{}),
    source_count: usize = 0,
    source_bytes_total: usize = 0,

    pub fn init(gpa: std.mem.Allocator, ctrl: *Controller) SourceDebugger {
        return .{ .gpa = gpa, .ctrl = ctrl };
    }

    pub fn deinit(self: *SourceDebugger) void {
        if (self.syms) |*s| s.deinit();
        self.syms = null;
        self.map = null;
        self.freeSourceCache();
    }

    // ─────────────────────────── attach-on-load ───────────────────────────

    /// Re-attach the symbol overlay for a fresh load (load / reset+load). Frees the prior
    /// overlay, opens a new one from the EXE bytes (precedence embedded-TDS → `.map` →
    /// none), attaches the runtime map at `psp_seg`, and re-resolves every breakpoint spec
    /// to its NEW linear (load_para changed). An OOM / unreadable image ⇒ `syms = none`,
    /// never a panic. Load-path only (never per-cycle), so determinism-safe.
    pub fn attachOnLoad(self: *SourceDebugger, exe: ?[]const u8, opt_map: ?[]const u8, psp_seg: u16) void {
        if (self.syms) |*old| old.deinit();
        self.syms = null;
        self.map = null;
        // Drop the prior source-text cache; the worker re-fills it eagerly AFTER this
        // returns (resolving each recorded file across the configured roots).
        self.freeSourceCache();
        if (exe) |bytes| {
            self.syms = Symbols.open(self.gpa, bytes, opt_map) catch null;
        }
        if (self.syms != null) self.map = self.syms.?.attach(psp_seg);
        self.reresolveBreakpoints();
        self.step = .{};
        self.state = .configuring;
        // A fresh load may reuse a symbol arena / RAM the prior program used — a prior-stop
        // handle must not re-validate against a DIFFERENT struct at the reused slot. Bump
        // the (monotonic) epoch + clear the table; NEVER zero the epoch (T1).
        self.invalidateHandles();
    }

    /// A restore reverted the machine to a prior cycle (load_para unchanged). Only the
    /// live frame/step caches are invalidated; symbols / specs persist. No reparse, no
    /// guest effect (debug-core-plan.md §2.2 / architecture §3.3).
    pub fn onMachineReverted(self: *SourceDebugger) void {
        self.step = .{};
        self.state = .stopped;
        // A restore rewinds RAM to a prior cycle: a handle minted at the (now-abandoned)
        // later stop is invalid. Bump the (monotonic) epoch + clear the table; the counter
        // only climbs, so a coincidental cycle match is still rejected by the epoch (T1).
        self.invalidateHandles();
    }

    // ─────────────────────────── stop-epoch / expansion handles (M-S2 §3.5/§6) ───────────────────────────

    /// Clear the expansion table and bump the STRICTLY-MONOTONIC stop epoch (T1). The
    /// ONLY mutation of `stop_epoch` besides `init` — always `+%= 1`, NEVER a reset. Called
    /// by every resume and by `attachOnLoad`/`onMachineReverted`, so a prior-epoch handle is
    /// universally, path-independently detectable as stale.
    fn invalidateHandles(self: *SourceDebugger) void {
        self.expand.count = 0;
        self.stop_epoch +%= 1;
    }

    /// The T4 resume wrapper: called by the WORKER BEFORE any `drainOne` arm that charges
    /// cycles, advances CS:IP, or wipes the machine (`run`/`run_slice`/`run_to_*`/`step*`/
    /// `reset`/input injection). Invalidates every outstanding handle and marks the session
    /// running so a concurrent inspection is refused with `not_stopped`.
    pub fn beginResume(self: *SourceDebugger) void {
        self.invalidateHandles();
        self.state = .running;
    }

    /// The T4 stop wrapper: called by the WORKER AFTER a resumed arm stops, whatever
    /// command drove it. Delegates to `projectStop` (the ONE place `StopReason` is read),
    /// which sets `state = .stopped/.terminated` and resolves the stop `pc`.
    pub fn noteStopped(self: *SourceDebugger, reason: StopReason) StopState {
        return self.projectStop(reason);
    }

    /// Mark the machine stopped at the current (clean) boundary WITHOUT a `StopReason`
    /// (a `reset` / a cycle-neutral input inject that returned no stop). Leaves `pc`
    /// resolution to the on-demand `pcLocation*`; only flips the gate back to Stopped.
    pub fn noteStoppedNoReason(self: *SourceDebugger) void {
        self.state = .stopped;
    }

    /// Mint a `variables_ref` for `node` in the current epoch: `(stop_epoch << 16) |
    /// (slot+1)` (slot+1 so a valid ref is never 0; the 48-bit epoch stays JSON-number-safe,
    /// T11). Returns 0 when the table is full (the var renders its summary but cannot be
    /// expanded — honest degradation, never a wrong slot).
    pub fn mintHandle(self: *SourceDebugger, node: ExpandNode) u64 {
        if (self.expand.count >= MAX_HANDLES) return 0;
        const slot = self.expand.count;
        self.expand.nodes[slot] = node;
        self.expand.count += 1;
        return (@as(u64, self.stop_epoch) << 16) | (@as(u64, slot) + 1);
    }

    /// Resolve a `variables_ref` back to its node, or `error.StaleHandle` if it is from a
    /// PRIOR epoch or names an unfilled slot (the no-stale-read guarantee). Because the
    /// epoch only climbs, a prior-stop handle is always detectably wrong.
    pub fn resolveHandle(self: *const SourceDebugger, ref: u64) error{StaleHandle}!ExpandNode {
        const epoch = ref >> 16;
        const raw = ref & 0xFFFF;
        if (epoch != self.stop_epoch or raw == 0) return error.StaleHandle;
        const slot = raw - 1;
        if (slot >= self.expand.count) return error.StaleHandle;
        return self.expand.nodes[@intCast(slot)];
    }

    fn reresolveBreakpoints(self: *SourceDebugger) void {
        for (0..MAX_SPECS) |i| {
            if (self.specs[i].active) self.resolveSlot(i) catch {};
        }
    }

    // ─────────────────────────── breakpoints ───────────────────────────

    pub fn setBreakpoint(self: *SourceDebugger, spec: BreakpointSpec) Error!ResolvedBreakpoint {
        const slot = self.freeSlot() orelse return error.SpecTableFull;
        var s = &self.specs[slot];
        s.* = .{ .active = true };
        switch (spec) {
            .addr => |a| {
                s.kind = .addr;
                s.linear = a.linear;
            },
            .function => |f| {
                s.kind = .function;
                s.setName(f.name);
            },
            .source => |src| {
                s.kind = .source;
                s.setName(src.file);
                s.line = src.line;
            },
        }
        try self.resolveSlot(slot);
        return self.resolvedFor(slot);
    }

    pub fn clearBreakpoint(self: *SourceDebugger, id: u32) Error!void {
        if (id >= MAX_SPECS or !self.specs[id].active) return error.NoSuchBreakpoint;
        const s = &self.specs[id];
        if (s.ctrl_id) |cid| self.ctrl.removeBreakpoint(cid) catch {};
        s.* = .{};
    }

    pub fn listBreakpoints(self: *SourceDebugger, out: []ResolvedBreakpoint) []ResolvedBreakpoint {
        var n: usize = 0;
        for (0..MAX_SPECS) |i| {
            if (n >= out.len) break;
            if (self.specs[i].active) {
                out[n] = self.resolvedFor(i);
                n += 1;
            }
        }
        return out[0..n];
    }

    fn freeSlot(self: *SourceDebugger) ?usize {
        for (0..MAX_SPECS) |i| if (!self.specs[i].active) return i;
        return null;
    }

    /// (Re)compute a slot's linear + arm/replace its `Controller` breakpoint.
    fn resolveSlot(self: *SourceDebugger, slot: usize) Error!void {
        var s = &self.specs[slot];
        if (s.ctrl_id) |cid| {
            self.ctrl.removeBreakpoint(cid) catch {};
            s.ctrl_id = null;
        }
        s.verified = false;
        if (self.resolveLinear(s)) |linear| {
            s.linear = linear;
            s.ctrl_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = linear } }, false);
            s.verified = true;
        }
    }

    fn resolveLinear(self: *SourceDebugger, s: *const SpecSlot) ?u32 {
        switch (s.kind) {
            .addr => return s.linear,
            .function => {
                const m = self.map orelse return null;
                const idx = &self.syms.?.index;
                const sym = idx.nameToSymbol(s.name()) orelse return null;
                const f = idx.addrToFunction(sym.segment, sym.offset) orelse return null;
                return m.entryAddrForFunction(f);
            },
            .source => {
                const m = self.map orelse return null;
                const idx = &self.syms.?.index;
                const fid = idx.fileId(s.name()) orelse return null;
                return m.runtimeAddrForLine(fid, @intCast(s.line));
            },
        }
    }

    fn resolvedFor(self: *SourceDebugger, slot: usize) ResolvedBreakpoint {
        const s = &self.specs[slot];
        var rb = ResolvedBreakpoint{
            .id = @intCast(slot),
            .spec = self.specOf(s),
            .verified = s.verified,
        };
        if (s.verified) {
            rb.resolved = self.addrFor(s.linear);
            if (self.map) |m| {
                if (m.lineForRuntimeAddr(s.linear)) |lh| rb.source = self.sourceLocOf(lh.file_id, lh.line);
            }
        }
        return rb;
    }

    fn specOf(self: *SourceDebugger, s: *const SpecSlot) BreakpointSpec {
        _ = self;
        return switch (s.kind) {
            .addr => .{ .addr = .{ .linear = s.linear } },
            .function => .{ .function = .{ .name = s.name() } },
            .source => .{ .source = .{ .file = s.name(), .line = s.line } },
        };
    }

    // ─────────────────────────── location ───────────────────────────

    /// Where the PC is, fully resolved. Rejected when a run is in flight (the live
    /// CS:IP would be a mid-burst value). Valid in Configuring / Stopped.
    pub fn pcLocation(self: *SourceDebugger) Error!PcLocation {
        if (self.state == .running) return error.NotStopped;
        return self.pcLocationUnchecked();
    }

    fn pcLocationUnchecked(self: *SourceDebugger) PcLocation {
        const snap = self.ctrl.cpuSnapshot();
        const pc = snap.cs_base +% snap.eip;
        var loc = PcLocation{ .addr = .{ .seg = snap.cs, .off = @truncate(snap.eip), .linear = pc } };
        if (self.map) |m| {
            if (m.functionForRuntimeAddr(pc)) |f| loc.function = self.syms.?.index.functionName(f);
            if (m.lineForRuntimeAddr(pc)) |lh| loc.source = self.sourceLocOf(lh.file_id, lh.line);
        }
        return loc;
    }

    fn sourceLocOf(self: *SourceDebugger, file_id: u32, line: u16) SourceLoc {
        const path = if (self.syms) |*s| (s.index.sourceFile(file_id) orelse "") else "";
        return .{ .file_id = file_id, .path = path, .line = line };
    }

    // ─────────────────────────── source cache (M-S1.5) ───────────────────────────

    /// Free every cached source slot (bytes + line index) and reset the counters. Called
    /// on every `attachOnLoad` (before the worker re-fills) and in `deinit`.
    fn freeSourceCache(self: *SourceDebugger) void {
        for (self.sources[0..self.source_count]) |*s| {
            if (s.bytes.len != 0) self.gpa.free(s.bytes);
            if (s.line_starts.len != 0) self.gpa.free(s.line_starts);
            s.* = .{};
        }
        self.source_count = 0;
        self.source_bytes_total = 0;
    }

    /// Admit one source file's raw bytes into the cache, transcoding **CP437→UTF-8**,
    /// **expanding TABs**, and **stripping CR** while copying, and building the `\n`
    /// line-offset index (newlines are dropped — pure separators). Admission is
    /// query-order-independent (finding #8): over the per-file cap or the total budget ⇒
    /// SKIPPED (the file simply has no window), never evicting an already-admitted file.
    /// The worker MUST call this in ascending `file_id` order so the cached set is a pure
    /// function of `(file_id order, sizes, budget)`. Load-time host work; no machine touch.
    pub fn cacheSource(self: *SourceDebugger, file_id: u32, root_index: u8, raw: []const u8) void {
        if (self.source_count >= MAX_CACHED_SOURCES) return;
        if (self.findSource(file_id) != null) return; // already cached (defensive)
        if (raw.len > MAX_SOURCE_BYTES) return; // cheap pre-check on the raw size

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        var starts: std.ArrayListUnmanaged(u32) = .empty;
        var ok = true;
        starts.append(self.gpa, 0) catch {
            ok = false;
        };
        var col: usize = 0;
        if (ok) for (raw) |b| {
            switch (b) {
                '\r' => {}, // strip CR (CRLF → LF; lone CR dropped too)
                '\n' => {
                    starts.append(self.gpa, @intCast(bytes.items.len)) catch {
                        ok = false;
                        break;
                    };
                    col = 0;
                },
                '\t' => {
                    const n = TAB_STOP - (col % TAB_STOP);
                    bytes.appendNTimes(self.gpa, ' ', n) catch {
                        ok = false;
                        break;
                    };
                    col += n;
                },
                else => {
                    if (b < 0x80) {
                        bytes.append(self.gpa, b) catch {
                            ok = false;
                            break;
                        };
                    } else {
                        var u8buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp437_high[b - 0x80], &u8buf) catch unreachable;
                        bytes.appendSlice(self.gpa, u8buf[0..len]) catch {
                            ok = false;
                            break;
                        };
                    }
                    col += 1;
                },
            }
            if (bytes.items.len > MAX_SOURCE_BYTES) {
                ok = false;
                break;
            }
        };
        // Final sentinel: if the file did not end on a newline, close the last line.
        if (ok and (starts.items.len == 0 or starts.getLast() != bytes.items.len)) {
            starts.append(self.gpa, @intCast(bytes.items.len)) catch {
                ok = false;
            };
        }
        const total_after = self.source_bytes_total + bytes.items.len;
        if (!ok or bytes.items.len > MAX_SOURCE_BYTES or total_after > MAX_TOTAL_SOURCE_BYTES) {
            bytes.deinit(self.gpa);
            starts.deinit(self.gpa);
            return; // graceful skip — the file just has no window
        }
        const owned_bytes = bytes.toOwnedSlice(self.gpa) catch {
            bytes.deinit(self.gpa);
            starts.deinit(self.gpa);
            return;
        };
        const owned_starts = starts.toOwnedSlice(self.gpa) catch {
            self.gpa.free(owned_bytes);
            starts.deinit(self.gpa);
            return;
        };
        self.sources[self.source_count] = .{
            .file_id = file_id,
            .root_index = root_index,
            .active = true,
            .bytes = owned_bytes,
            .line_starts = owned_starts,
        };
        self.source_count += 1;
        self.source_bytes_total += owned_bytes.len;
    }

    fn findSource(self: *SourceDebugger, file_id: u32) ?*const CachedSource {
        for (self.sources[0..self.source_count]) |*s| {
            if (s.active and s.file_id == file_id) return s;
        }
        return null;
    }

    /// True iff `file_id`'s text is in the source cache (for `list_sources`' `cached`).
    pub fn isSourceCached(self: *SourceDebugger, file_id: u32) bool {
        return self.findSource(file_id) != null;
    }

    /// Render a windowed view around `line` of `file_id` into the caller-provided `scratch`
    /// (borrowed slices into the owned cache bytes). `requested_ctx` lines each side, CLAMPED
    /// so `2*ctx+1 ≤ MAX_WINDOW_LINES` (sets `clamped`); the window is `min(2*ctx+1,
    /// num_lines)` rows, shifted to stay in `[1,num_lines]` while including `line`. Null when
    /// the file is not cached. Pure in-memory slicing — no host I/O, no machine touch.
    pub fn sourceWindow(self: *SourceDebugger, file_id: u32, line: u32, requested_ctx: u32, scratch: []core.SrcLine) ?core.SourceWindow {
        const slot = self.findSource(file_id) orelse return null;
        const num_lines: u32 = @intCast(slot.line_starts.len - 1);
        if (num_lines == 0) return null;
        const max_ctx: u32 = (core.MAX_WINDOW_LINES - 1) / 2;
        var ctx = requested_ctx;
        var clamped = false;
        if (ctx > max_ctx) {
            ctx = max_ctx;
            clamped = true;
        }
        const target = @min(2 * ctx + 1, num_lines);
        const center = std.math.clamp(line, 1, num_lines);
        var start: u32 = if (center > ctx) center - ctx else 1;
        var end: u32 = start + target - 1;
        if (end > num_lines) {
            end = num_lines;
            start = end + 1 - target;
        }
        if (start < 1) start = 1;
        var n: usize = 0;
        var ln = start;
        while (ln <= end and n < scratch.len) : (ln += 1) {
            const content = slot.bytes[slot.line_starts[ln - 1]..slot.line_starts[ln]];
            var text = content;
            var truncated = false;
            if (text.len > core.MAX_LINE_BYTES) {
                var cut: usize = core.MAX_LINE_BYTES;
                while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
                text = text[0..cut];
                truncated = true;
            }
            scratch[n] = .{ .number = ln, .text = text, .active = (ln == line), .truncated = truncated };
            n += 1;
        }
        return .{
            .file_id = file_id,
            .active_line = line,
            .clamped = clamped,
            .root_index = slot.root_index,
            .lines = scratch[0..n],
        };
    }

    // ── source-file discovery (M-S1.5: list_sources / read_source name lookup) ──

    /// The number of source files the symbol overlay knows (0 when stripped).
    pub fn sourceFileCount(self: *SourceDebugger) u32 {
        if (self.syms) |*s| return s.index.sourceFileCount();
        return 0;
    }

    /// The compiler-recorded name of source `file_id` (NOT a host path), or null.
    pub fn sourceFileName(self: *SourceDebugger, file_id: u32) ?[]const u8 {
        if (self.syms) |*s| return s.index.sourceFile(file_id);
        return null;
    }

    /// Resolve a caller-supplied name to a `file_id`: strict exact match first, then a
    /// basename fallback (finding #3 — a full-path-recorded TDS name still resolves to the
    /// bare basename an agent passes). Null when no symbols / no match.
    pub fn fileIdForName(self: *SourceDebugger, name: []const u8) ?u32 {
        if (self.syms) |*s| return s.index.fileId(name) orelse s.index.fileIdByBasename(name);
        return null;
    }

    fn addrFor(self: *SourceDebugger, linear: u32) Addr {
        var a = Addr{ .seg = 0, .off = 0, .linear = linear };
        if (self.map) |m| {
            if (m.imageAddrForLinear(linear)) |ia| {
                a.seg = ia.segment;
                a.off = ia.offset;
            }
        }
        return a;
    }

    // ─────────────────────────── stop projection ───────────────────────────

    /// The ONE place the raw `Controller.StopReason` union is read (design §4.6). Sets
    /// the session `state` and (unless terminated) resolves the stop's `PcLocation`.
    pub fn projectStop(self: *SourceDebugger, reason: StopReason) StopState {
        var ss = StopState{ .running = false, .kind = null, .pc = null, .cycle = 0 };
        switch (reason) {
            .breakpoint => |b| {
                ss.cycle = b.at_cycle;
                if (self.isOwnOneshot(b.id)) {
                    ss.kind = .step;
                } else {
                    ss.kind = .breakpoint;
                    ss.bp_id = self.handleForCtrlId(b.id);
                }
            },
            .step_complete => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .target_reached => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .dwell_complete => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .cycle_budget_exhausted => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .step;
            },
            .program_terminated => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .exit;
                ss.exit_code = c.ret_code;
            },
            .shutdown => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .halted_forever => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .terminated;
            },
            .branch_trap => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .no_progress => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .fault;
            },
            .stopped_by_request => |c| {
                ss.cycle = c.at_cycle;
                ss.kind = .pause;
            },
        }
        self.state = switch (ss.kind.?) {
            .exit, .terminated => .terminated,
            else => .stopped,
        };
        if (self.state != .terminated) ss.pc = self.pcLocationUnchecked();
        return ss;
    }

    fn isOwnOneshot(self: *SourceDebugger, id: u32) bool {
        return self.step.active and self.step.oneshot_id != null and self.step.oneshot_id.? == id;
    }

    fn handleForCtrlId(self: *SourceDebugger, id: u32) ?u32 {
        for (0..MAX_SPECS) |i| {
            const sl = &self.specs[i];
            if (sl.active and sl.ctrl_id != null and sl.ctrl_id.? == id) return @intCast(i);
        }
        return null;
    }

    // ─────────────────────────── stepping ───────────────────────────

    /// Begin a source step (the `beginRunToAddress` analog). Captures the frame anchor
    /// (`start_line` + `start_sp`) and arms any one-shot (`stepOut` return / `runToLine`
    /// target). `file`/`line` are only consulted for `.to_line`.
    pub fn beginStep(self: *SourceDebugger, kind: StepKind, file: ?[]const u8, line: u32) Error!void {
        const snap = self.ctrl.cpuSnapshot();
        self.step = .{
            .active = true,
            .kind = kind,
            .start_line = self.lineKey(snap.cs_base +% snap.eip),
            .start_sp = @as(u16, @truncate(snap.esp)),
        };
        // Arm any one-shot FIRST; only mark the session `running` once arming has succeeded.
        // (An arming failure — e.g. an unresolved `run_to_line` target — resets `self.step`
        // and propagates the error, leaving `state` at its prior `stopped`/`configuring` value
        // so a later `whereami`/inspection is not wedged into a spurious `not_stopped`.)
        switch (kind) {
            .line, .in => {},
            .out => try self.armStepOut(snap),
            .to_line => {
                const m = self.map orelse {
                    self.step = .{};
                    return error.NoSymbols;
                };
                const f = file orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                const fid = self.syms.?.index.fileId(f) orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                const lin = m.runtimeAddrForLine(fid, @intCast(line)) orelse {
                    self.step = .{};
                    return error.Unresolved;
                };
                self.step.oneshot_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = lin } }, true);
            },
        }
        // T4 (folded, per §6): a source step is a resume — invalidate outstanding handles +
        // bump the monotonic epoch. Done only AFTER arming succeeds (a failed arm returns an
        // error above and does not resume, so it must not bump).
        self.invalidateHandles();
        self.state = .running;
    }

    fn armStepOut(self: *SourceDebugger, snap: anytype) Error!void {
        const bpv: u16 = @truncate(snap.ebp);
        // far/near from the CURRENT function's TDS return type (`FuncRef` carries none).
        var far = false;
        if (self.map) |m| {
            if (m.functionForRuntimeAddr(snap.cs_base +% snap.eip)) |f| {
                if (self.syms.?.index.typeRefForFunction(f)) |t| {
                    if (self.syms.?.typegraph) |*tg| {
                        if (tg.typeInfo(t)) |ti| {
                            if (ti == .function) far = ti.function.far;
                        }
                    }
                }
            }
        }
        var b2: [2]u8 = undefined;
        self.ctrl.peekMem(.ss, @as(u32, bpv) +% 2, &b2);
        const retip = std.mem.readInt(u16, &b2, .little);
        var ret_linear: u32 = undefined;
        if (far) {
            var b4: [2]u8 = undefined;
            self.ctrl.peekMem(.ss, @as(u32, bpv) +% 4, &b4);
            const retcs = std.mem.readInt(u16, &b4, .little);
            ret_linear = (@as(u32, retcs) << 4) +% retip;
        } else {
            ret_linear = snap.cs_base +% retip;
        }
        self.step.ret_linear = ret_linear;
        self.step.guard_sp = @as(u32, bpv) + (if (far) @as(u32, 4) else @as(u32, 2));
        self.step.oneshot_id = try self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = ret_linear } }, true);
    }

    /// End / cancel the in-flight step (removes a still-armed one-shot). Idempotent.
    pub fn endStep(self: *SourceDebugger) void {
        if (self.step.oneshot_id) |oid| self.ctrl.removeBreakpoint(oid) catch {};
        self.step = .{};
    }

    /// One BOUNDED step burst (Finding 1). Runs up to `budget` stepped cycles, returning
    /// either a real `.stopped` (qualifying line / terminal / user-breakpoint) or
    /// `.budget_exhausted` (no qualifying stop yet — the WORKER then polls preempt and
    /// re-enters). NO atomics, NO preempt poll. `beginStep` must precede it.
    pub fn stepBurst(self: *SourceDebugger, budget: u64) StepOutcome {
        std.debug.assert(self.step.active);
        const start = self.ctrl.currentCycle();
        while (self.ctrl.currentCycle() -% start < budget) {
            switch (self.step.kind) {
                .line => if (self.lineStepOnce()) |ss| {
                    self.endStep();
                    return .{ .stopped = ss };
                },
                .in => if (self.inStepOnce()) |ss| {
                    self.endStep();
                    return .{ .stopped = ss };
                },
                // run-to-one-shot kinds consume the rest of the burst in one run.
                .out, .to_line => return self.targetBurst(budget, start),
            }
        }
        return .budget_exhausted;
    }

    /// `stepLine` / `next` inner step (§5.2): step OVER calls, stop at the next source
    /// line at the same-or-shallower frame. Null ⇒ keep going.
    fn lineStepOnce(self: *SourceDebugger) ?StopState {
        const res = self.ctrl.stepOver();
        if (res.reason != .step_complete) return self.projectStop(res.reason);
        const snap = self.ctrl.cpuSnapshot();
        const cur = self.lineKey(snap.cs_base +% snap.eip);
        const cur_sp: u32 = @as(u16, @truncate(snap.esp));
        if (cur) |ck| {
            const changed = if (self.step.start_line) |sl|
                !(sl.file_id == ck.file_id and sl.line == ck.line)
            else
                true;
            if (changed and cur_sp >= self.step.start_sp)
                return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
            if (cur_sp > self.step.start_sp)
                return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
        }
        return null;
    }

    /// `stepIn` inner step (§5.3): plain step (enters calls); stop on a NEW symbolized
    /// line. A callee with no debug info degrades to `stepLine` carrying the ORIGINAL
    /// `start_sp` anchor (so it runs back out instead of stranding one instruction in).
    fn inStepOnce(self: *SourceDebugger) ?StopState {
        const res = self.ctrl.stepInstruction();
        if (res != .step_complete) return self.projectStop(res);
        const pc = self.livePc();
        const cur = self.lineKey(pc);
        if (cur) |ck| {
            const changed = if (self.step.start_line) |sl|
                !(sl.file_id == ck.file_id and sl.line == ck.line)
            else
                true;
            if (changed) {
                if (self.map.?.functionForRuntimeAddr(pc) != null)
                    return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
                // unsymbolized callee: run back out with the original frame anchor.
                self.step.kind = .line;
            }
        }
        return null;
    }

    /// `stepOut` / `runToLine` burst: run to the armed one-shot. For `stepOut`, a hit
    /// below `guard_sp` is a recursion false-hit (re-arm, yield); a hit at/above it is
    /// the real return.
    fn targetBurst(self: *SourceDebugger, budget: u64, start: u64) StepOutcome {
        const elapsed = self.ctrl.currentCycle() -% start;
        const rem = if (budget > elapsed) budget - elapsed else 1;
        const r = self.ctrl.runUntilEvent(rem);
        switch (r) {
            .cycle_budget_exhausted => return .budget_exhausted,
            .breakpoint => |b| {
                if (self.step.oneshot_id != null and b.id == self.step.oneshot_id.?) {
                    const cur_sp: u32 = @as(u16, @truncate(self.ctrl.cpuSnapshot().esp));
                    if (self.step.kind == .to_line or cur_sp >= self.step.guard_sp) {
                        const ss = self.projectStop(.{ .step_complete = .{ .at_cycle = b.at_cycle } });
                        self.endStep();
                        return .{ .stopped = ss };
                    }
                    // recursion false-hit: the one-shot auto-removed itself; re-arm.
                    self.step.oneshot_id = self.ctrl.addBreakpoint(.{ .execution_address = .{ .linear = self.step.ret_linear } }, true) catch null;
                    return .budget_exhausted;
                }
                const ss = self.projectStop(r);
                self.endStep();
                return .{ .stopped = ss };
            },
            else => {
                const ss = self.projectStop(r);
                self.endStep();
                return .{ .stopped = ss };
            },
        }
    }

    // ── pure, non-preemptible convenience (tests / simplest blocking callers) ──

    pub fn stepLine(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.line, null, 0);
    }
    pub fn stepIn(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.in, null, 0);
    }
    pub fn stepOut(self: *SourceDebugger) Error!StopState {
        return self.runStepBlocking(.out, null, 0);
    }
    pub fn runToLine(self: *SourceDebugger, file: []const u8, line: u32) Error!StopState {
        return self.runStepBlocking(.to_line, file, line);
    }

    fn runStepBlocking(self: *SourceDebugger, kind: StepKind, file: ?[]const u8, line: u32) Error!StopState {
        try self.beginStep(kind, file, line);
        var spent: u64 = 0;
        while (true) {
            switch (self.stepBurst(core.STEP_BURST_CYCLES)) {
                .stopped => |ss| return ss,
                .budget_exhausted => {
                    spent +|= core.STEP_BURST_CYCLES;
                    if (spent >= core.STEP_WEDGE_CAP_CYCLES) {
                        self.endStep();
                        return self.projectStop(.{ .step_complete = .{ .at_cycle = self.ctrl.currentCycle() } });
                    }
                },
            }
        }
    }

    // ─────────────────────────── helpers ───────────────────────────

    fn livePc(self: *SourceDebugger) u32 {
        const snap = self.ctrl.cpuSnapshot();
        return snap.cs_base +% snap.eip;
    }

    fn lineKey(self: *SourceDebugger, linear: u32) ?LineKey {
        const m = self.map orelse return null;
        const lh = m.lineForRuntimeAddr(linear) orelse return null;
        return .{ .file_id = lh.file_id, .line = lh.line };
    }
};

test {
    std.testing.refAllDecls(@This());
}
