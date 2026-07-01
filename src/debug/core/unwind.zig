//! `src/debug/core/unwind.zig` — the PURE real-mode stack unwinder (M-S2 §2).
//!
//! Reconstructs the call stack from the Borland C frame convention (`push bp; mov bp,sp`,
//! bytes `55 8B EC`): within a frame, the caller's BP is at `SS:[BP]`, the near return IP
//! at `SS:[BP+2]`, and a far return's `CS:IP` at `SS:[BP+2]`/`SS:[BP+4]`. It walks the
//! saved-BP chain, mapping each return address back to a function + source line.
//!
//! Determinism (CLAUDE.md §1): EVERY read is a side-effect-free peek —
//! `Controller.cpuSnapshot`/`peekMem(.ss, …)`/`peekMemPhys` — NEVER `bus.read*`/`portIn*`
//! (those mutate device state). Unwinding charges ZERO cycles, executes nothing, and
//! leaves `ctrl.snapshot()` byte-identical. On the `src/debug` grep gate: no host
//! clock, RNG, float, atomic, thread, or unordered container.
//!
//! No fabrication (CLAUDE.md §2 — this is the module where it matters most). zdos boots to
//! ZERO-init RAM, so a garbage BP can be even, in-window, and ascending yet name a
//! plausible-but-WRONG parent. Before ACCEPTING any reconstructed caller we require the
//! bytes ending at its return address to be a REAL `CALL` opcode (`endsWithCall`, T3); if
//! they are not, we refuse the frame and terminate with `no_call_site`. Every frame is
//! therefore either correct or honestly flagged, and every walk reports WHY it stopped.

const std = @import("std");
const core = @import("core.zig");
const debugger = @import("debugger.zig");
const symbols = @import("../symbols/symbols.zig");

const SourceDebugger = debugger.SourceDebugger;
const Addr = core.Addr;
const SourceLoc = core.SourceLoc;
const Frame = core.Frame;
const Backtrace = core.Backtrace;
const BacktraceStop = core.BacktraceStop;
const FuncRef = symbols.FuncRef;
const LineHit = symbols.LineHit;

/// The number of prologue bytes `55 8B EC` (`push bp; mov bp,sp`) — the mid-prologue
/// window used by the frame-0 structural check (T5).
const PROLOGUE_LEN: u16 = 3;

/// Walk the stack from the live CS:IP, filling `out` innermost-first. `max_frames` is
/// clamped to `out.len`. The returned `Backtrace.frames` borrows `out[0..n]`; every string
/// it carries (`function`/`source.path`) borrows the symbol arena (valid for the load).
///
/// Peek-only: it reads registers via `cpuSnapshot` and memory via `peekMem(.ss, …)` /
/// `peekMemPhys`; it never runs the machine.
pub fn backtrace(sd: *SourceDebugger, out: []Frame, max_frames: usize) Backtrace {
    const limit = @min(max_frames, out.len);
    if (limit == 0) return .{ .frames = out[0..0], .truncated_reason = .max_frames };

    const snap = sd.ctrl.cpuSnapshot();
    const pc0 = snap.cs_base +% snap.eip;
    var bp: u16 = @truncate(snap.ebp);
    const ss_lo: u16 = @truncate(snap.esp); // current SP — the low bound of the stack window
    const ss_hi: u16 = @truncate(snap.ss_limit); // SS segment limit — the high bound

    // ---- frame 0 (live CS:IP) ----
    const f0 = if (sd.map) |m| m.functionForRuntimeAddr(pc0) else null;
    out[0] = .{
        .index = 0,
        .pc = .{ .seg = snap.cs, .off = @truncate(snap.eip), .linear = pc0 },
        .function = if (f0) |f| funcName(sd, f) else null,
        .source = lineAt(sd, pc0),
        .frame_base = bp,
        .is_far = false,
        .unreliable = false,
    };

    // No function covers the live PC (C runtime startup, a trampoline, or a stripped/`.map`
    // image with no cover): we cannot trust that BP frames this code, so emit frame 0 only.
    const ff = f0 orelse return .{ .frames = out[0..1], .truncated_reason = .no_function };

    // Mid-prologue / frame-less frame 0 (§2.4): BP does not yet frame this call, so the
    // saved-BP chain is unavailable — flag frame 0 and stop, never walk on a bad base.
    if (inPrologue(sd, pc0, ff)) {
        out[0].unreliable = true;
        return .{ .frames = out[0..1], .truncated_reason = .frameless_callee };
    }

    // T2: `cur_seg_base` is the code-segment base used for NEAR returns; it starts at
    // frame-0's CS base and is REBASED on every FAR pop, so a medium/large/huge-model
    // caller resolves against ITS segment, not frame-0's.
    var cur_seg_base = snap.cs_base;
    var prev_conv = fnConv(sd, ff); // the CALL convention of the function we are LEAVING
    var cur_far = prev_conv.far;

    var i: usize = 1;
    while (i < limit) {
        // BP sanity: nonzero, even (a real `push bp` leaves it word-aligned), inside the
        // stack window, and the saved-BP chain must strictly ASCEND toward the stack base.
        if (bp == 0) return .{ .frames = out[0..i], .truncated_reason = .bp_zero };
        if ((bp & 1) != 0) return .{ .frames = out[0..i], .truncated_reason = .bp_not_increasing };
        if (bp < ss_lo or bp >= ss_hi) return .{ .frames = out[0..i], .truncated_reason = .bp_not_increasing };

        const saved_bp = peek16(sd, bp);
        if (saved_bp != 0 and saved_bp <= bp) return .{ .frames = out[0..i], .truncated_reason = .bp_not_increasing };

        const ret_ip = peek16(sd, @as(u32, bp) + 2);
        var ret_lin: u32 = undefined;
        var ret_seg_base: u32 = cur_seg_base;
        if (cur_far) {
            const ret_cs = peek16(sd, @as(u32, bp) + 4);
            ret_seg_base = @as(u32, ret_cs) << 4;
            ret_lin = ret_seg_base +% ret_ip;
        } else {
            ret_lin = cur_seg_base +% ret_ip; // T2: NEAR uses the CURRENT code-seg base
        }
        const site_lin = ret_lin -% 1; // the CALL site, not the following statement (§2.5)

        // T3 — the anti-fabrication check: a garbage BP that survived the window/ascending
        // tests must still name a return address that a real CALL produced. Refuse otherwise.
        if (!endsWithCall(sd, ret_lin)) return .{ .frames = out[0..i], .truncated_reason = .no_call_site };

        // The callee we just left is an INTERRUPT handler → the CPU pushed `[FLAGS][CS][IP]`
        // above, not a BP frame; a BP-walk would mis-read, so stop at the boundary.
        if (prev_conv.interrupt) return .{ .frames = out[0..i], .truncated_reason = .interrupt_boundary };

        const site_fn = if (sd.map) |m| m.functionForRuntimeAddr(site_lin) else null;
        // The return maps to no function: we had symbols before it, so this is the C
        // runtime startup (C0) / a trampoline — a clean top-of-user-stack boundary.
        const sf = site_fn orelse return .{ .frames = out[0..i], .truncated_reason = .c0_startup };

        const conv = fnConv(sd, sf);
        out[i] = .{
            .index = @intCast(i),
            .pc = frameAddr(sd, site_lin),
            .function = funcName(sd, sf),
            .source = lineAt(sd, site_lin),
            .frame_base = saved_bp,
            .is_far = cur_far,
            // An assumption drove this frame's near/far handling (no TDS function type):
            // flag it (T15a). A hard failure never lands here — it terminates instead.
            .unreliable = !prev_conv.typed,
        };

        bp = saved_bp;
        prev_conv = conv;
        if (cur_far) cur_seg_base = ret_seg_base; // rebase NEAR reads after crossing segments
        cur_far = conv.far; // the NEXT pop uses the callee-being-left's far-ness
        i += 1;
    }
    return .{ .frames = out[0..i], .truncated_reason = if (i == 1) .ok_top else .max_frames };
}

// ─────────────────────────── peek helpers (side-effect-free) ───────────────────────────

/// A little-endian word from `SS:off` (offset masked to u16 — real-mode wraps at 64 KiB).
fn peek16(sd: *SourceDebugger, off: u32) u16 {
    var b: [2]u8 = undefined;
    sd.ctrl.peekMem(.ss, off & 0xFFFF, &b);
    return std.mem.readInt(u16, &b, .little);
}

// ─────────────────────────── call-site verification (T3) ───────────────────────────

/// True iff the bytes ENDING at `ret_lin` (the byte after the CALL) encode a real CALL:
/// `E8 cw` (near rel), `9A cd` (far abs), or `FF /2` (near indirect) / `FF /3` (far
/// indirect). We peek the ≤8 code bytes ending at `ret_lin` and check each candidate CALL
/// length lands exactly at `ret_lin`. No match ⇒ refuse the frame (never fabricate a parent
/// off zero-init RAM). Peek-only via `peekMemPhys`.
fn endsWithCall(sd: *SourceDebugger, ret_lin: u32) bool {
    if (ret_lin < 8) return false; // a real code return address is never this low
    var buf: [8]u8 = undefined; // buf[k] == byte at (ret_lin - 8 + k); buf[7] == ret_lin-1
    sd.ctrl.peekMemPhys(ret_lin - 8, &buf);

    // E8 cw — near relative CALL (3 bytes): opcode at ret_lin-3.
    if (buf[5] == 0xE8) return true;
    // 9A cd — far absolute CALL (5 bytes): opcode at ret_lin-5.
    if (buf[3] == 0x9A) return true;
    // FF /2 (near indirect) / FF /3 (far indirect): 2..4 bytes in 16-bit addressing.
    var l: u32 = 2;
    while (l <= 4) : (l += 1) {
        const op = buf[8 - l];
        if (op != 0xFF) continue;
        const modrm = buf[8 - l + 1];
        const reg = (modrm >> 3) & 7;
        if (reg != 2 and reg != 3) continue; // /2 near-call, /3 far-call only
        if (reg == 3 and (modrm >> 6) == 3) continue; // far-call cannot be register-direct
        if (ffModrmLen16(modrm) == l) return true; // the decoded length must reach ret_lin
    }
    return false;
}

/// Total length (incl. the `FF` opcode + ModRM) of an `FF /r` instruction in 16-bit
/// addressing; no SIB in 16-bit mode.
fn ffModrmLen16(modrm: u8) u32 {
    const mod = modrm >> 6;
    const rm = modrm & 7;
    return switch (mod) {
        3 => 2, // register-direct
        0 => if (rm == 6) 4 else 2, // [disp16] special case, else [base]
        1 => 3, // +disp8
        2 => 4, // +disp16
        else => unreachable,
    };
}

// ─────────────────────────── prologue / frame-less detection ───────────────────────────

/// True iff `pc` is still inside `f`'s prologue (BP not yet the frame base). Two OR-combined
/// tests (§2.4): (1) STRUCTURAL — the image offset is within `[f.start, f.start+3)` (catches
/// a `.map` function/addr breakpoint that lands at `f.start`, before `push bp`, which the
/// line-table `entryOffset` check would miss); (2) SHAPE — the first 3 bytes are not
/// `55 8B EC`, or `pc` sits before the post-prologue entry offset.
fn inPrologue(sd: *SourceDebugger, pc: u32, f: FuncRef) bool {
    const m = sd.map orelse return false;
    const ia = m.imageAddrForLinear(pc) orelse return false;
    if (ia.offset >= f.start and ia.offset < f.start +% PROLOGUE_LEN) return true;

    const s = if (sd.syms) |*sy| sy else return false;
    // Before the post-prologue landing (TDS line records present) ⇒ still in the prologue.
    if (ia.offset >= f.start and ia.offset < s.index.entryOffsetForFunction(f)) return true;

    // Prologue shape: the function's first 3 code bytes must be `push bp; mov bp,sp`.
    const entry_lin = m.toRuntimeLinear(f.segment, f.start);
    var pro: [3]u8 = undefined;
    sd.ctrl.peekMemPhys(entry_lin, &pro);
    if (!(pro[0] == 0x55 and pro[1] == 0x8B and pro[2] == 0xEC)) return true; // frame-less
    return false;
}

// ─────────────────────────── symbol resolution ───────────────────────────

const FnConv = struct { far: bool, interrupt: bool, typed: bool };

/// The far-ness + interrupt-ness of `f` from its TDS function type (`typeRefForFunction →
/// typeInfo(.function)`). `typed=false` ⇒ no function type (a `.map` image or a null/
/// non-`.function` type-ref): assume NEAR / not-interrupt (small-model default, T18) and the
/// caller marks that frame `unreliable`.
fn fnConv(sd: *SourceDebugger, f: FuncRef) FnConv {
    const s = if (sd.syms) |*sy| sy else return .{ .far = false, .interrupt = false, .typed = false };
    const t = s.index.typeRefForFunction(f) orelse return .{ .far = false, .interrupt = false, .typed = false };
    const tg = if (s.typegraph) |*g| g else return .{ .far = false, .interrupt = false, .typed = false };
    const ti = tg.typeInfo(t) orelse return .{ .far = false, .interrupt = false, .typed = false };
    if (ti != .function) return .{ .far = false, .interrupt = false, .typed = false };
    return .{ .far = ti.function.far, .interrupt = ti.function.conv == .interrupt, .typed = true };
}

fn funcName(sd: *SourceDebugger, f: FuncRef) ?[]const u8 {
    const s = if (sd.syms) |*sy| sy else return null;
    return s.index.functionName(f);
}

/// The source line owning `linear` (or null — an inter-statement address / no line record).
fn lineAt(sd: *SourceDebugger, linear: u32) ?SourceLoc {
    const m = sd.map orelse return null;
    const lh = m.lineForRuntimeAddr(linear) orelse return null;
    return srcLoc(sd, lh);
}

fn srcLoc(sd: *SourceDebugger, lh: LineHit) SourceLoc {
    const path = if (sd.syms) |*s| (s.index.sourceFile(lh.file_id) orelse "") else "";
    return .{ .file_id = lh.file_id, .path = path, .line = lh.line };
}

/// The `{seg, off, linear}` of a caller's call site, using the image `(segment, offset)`
/// (the same view `whereami` reports); `seg/off` are 0 when no code segment covers `linear`.
fn frameAddr(sd: *SourceDebugger, linear: u32) Addr {
    var a = Addr{ .seg = 0, .off = 0, .linear = linear };
    if (sd.map) |m| {
        if (m.imageAddrForLinear(linear)) |ia| {
            a.seg = ia.segment;
            a.off = ia.offset;
        }
    }
    return a;
}

test {
    std.testing.refAllDecls(@This());
}
