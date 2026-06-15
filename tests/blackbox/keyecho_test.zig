//! Black-box INPUT-INJECTION tests for the zdos debugger HTTP API.
//!
//! These spawn the REAL `zdos --serve 0 <exe>` child and drive it over a real
//! localhost socket (same harness as `blackbox_test.zig`), centered on two real
//! BCC-compiled DOS fixtures:
//!   - `KEYECHO.EXE` — blocks on bioskey(0) (INT 16h AH=00, the API-injected
//!     keyboard path: 8042 -> IRQ1 -> INT 09h -> BDA ring -> INT 16h), echoes each
//!     key's ASCII to the VGA TEXT PAGE via Borland conio putch() (direct B800
//!     video), and exits on ESC. The echo is observed at GET /api/screen — the
//!     text-mode-video acceptance gate (real putch() output is now observable).
//!   - `MOUSERB.EXE` — loops INT 33h AX=0003 (get position+buttons) and stores the
//!     live driver state to a fixed address (0x500), so an injected mouse position
//!     can be read back via GET /api/mem; exits when a button is injected.
//!
//! Determinism: each injection mutates input state at the one-command-in-flight
//! boundary (Model A); a subsequent cycle-bounded `run` delivers it. The same key
//! script therefore yields the same CON output every run — asserted by the
//! double-run check in the flagship test. No host clock enters any assertion.
//!
//! Real sockets + child processes -> these live in `test-blackbox`, NOT the
//! hermetic `test` gate. Every test reaps its child via `defer s.deinit()`.

const std = @import("std");
const Session = @import("session.zig").Session;

const KEYECHO = "examples/dos-src/KEYECHO.EXE";
const MOUSERB = "examples/dos-src/MOUSERB.EXE";

/// A cycle budget large enough for one bioskey unblock + echo + re-block (the BIOS
/// guest-asm INT 16h loop spins until the injected IRQ1 lands). Bounded so a stuck
/// guest can never hang the harness.
const RUN_CAP: u64 = 4_000_000;
/// ESC make scancode (set-1) — the precise-edge path; the INT 09h ISR cooks it to
/// the BDA word 0x011B (scancode 0x01, ASCII 0x1B = 27).
const SC_ESC: u8 = 0x01;

fn spawnKeyecho(io: std.Io) !Session {
    return Session.spawn(std.testing.allocator, io, KEYECHO);
}

/// The first `n` characters of row 0 of the text screen (the echo lands there
/// left-to-right). Returns the slice (in `out`).
fn screenRow0(s: *Session, out: []u8) ![]u8 {
    const scr = try s.screen(false);
    // `text` is rows joined by '\n'; row 0 is the prefix up to the first newline.
    const nl = std.mem.indexOfScalar(u8, scr.text, '\n') orelse scr.text.len;
    const row0 = scr.text[0..nl];
    const n = @min(row0.len, out.len);
    @memcpy(out[0..n], row0[0..n]);
    return out[0..n];
}

/// Drive KEYECHO through one full key script and return the echoed row-0 prefix +
/// the terminating status. Used twice (two fresh processes) to prove determinism.
fn driveKeyechoScript(s: *Session, row0_out: []u8) !struct { echo: []u8, term_stop: bool, terminated: bool, ret_code: u16 } {
    // Run once so the guest reaches the blocking bioskey loop (INT 16h AH=00).
    _ = try s.run(RUN_CAP);

    // Inject 'H' then 'I' by CHARACTER; run a bounded cap after each so bioskey
    // unblocks, echoes (putch direct video -> B800 text page), and re-blocks.
    _ = try s.injectKeyChar('H');
    _ = try s.run(RUN_CAP);
    _ = try s.injectKeyChar('I');
    _ = try s.run(RUN_CAP);

    // Inject ESC as a precise scancode edge (make 0x01) — the safest ESC path.
    _ = try s.injectKey(SC_ESC, true, false);
    const stop = try s.run(RUN_CAP);

    // The echo is on /api/screen now (putch writes the text page, not CON). The
    // first 3 cells of row 0 are 'H','I','!' (the two keys + the ESC marker).
    var full: [80]u8 = undefined;
    const row0 = try screenRow0(s, &full);
    const n = @min(@as(usize, 3), row0.len);
    @memcpy(row0_out[0..n], row0[0..n]);

    const st = try s.status();
    return .{
        .echo = row0_out[0..n],
        // The run that consumed ESC ended on the program-terminate stop reason.
        .term_stop = stop.stop.program_terminated != null,
        .terminated = st.terminated,
        .ret_code = st.ret_code,
    };
}

test "keyecho: inject H,I -> echoed 'HI' on /api/screen; ESC prints '!' and terminates (ret 0)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawnKeyecho(threaded.io());
    defer s.deinit();

    var buf: [8]u8 = undefined;
    const r = try driveKeyechoScript(&s, &buf);

    // Echo: the two printable keys were echoed via putch (direct B800 video) to the
    // text page, then ESC printed the '!' marker -> row 0 starts with "HI!".
    // THIS IS THE TEXT-MODE-VIDEO ACCEPTANCE GATE: real putch() output is observable
    // on /api/screen.
    try std.testing.expectEqualStrings("HI!", r.echo);
    // ESC terminated the program cleanly: the ESC run stopped on program_terminated,
    // and the final status confirms termination via INT 21h AH=4C with ret code 0.
    try std.testing.expect(r.term_stop);
    try std.testing.expect(r.terminated);
    try std.testing.expectEqual(@as(u16, 0), r.ret_code);
}

test "keyecho: DETERMINISM — two fresh processes produce byte-identical screen echo" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a = try spawnKeyecho(io);
    defer a.deinit();
    var bufa: [8]u8 = undefined;
    const ra = try driveKeyechoScript(&a, &bufa);

    var b = try spawnKeyecho(io);
    defer b.deinit();
    var bufb: [8]u8 = undefined;
    const rb = try driveKeyechoScript(&b, &bufb);

    // The same command/key script over two INDEPENDENT processes yields identical
    // screen echo AND identical termination — the input + text-video path is
    // deterministic.
    try std.testing.expectEqualStrings(ra.echo, rb.echo);
    try std.testing.expectEqual(ra.terminated, rb.terminated);
    try std.testing.expectEqual(ra.ret_code, rb.ret_code);
}

test "keyboard: an injected key reaches the guest's BIOS keyboard chain (screen echo)" {
    // The general keyboard-injection gap: inject ONE key by RAW scancode edge and
    // assert it reached the guest by observing the echo it produced. Set-1 scancode
    // 0x1E with NO Shift is 'a' (ASCII 0x61); the INT 09h ISR cooks it to the BDA
    // word 0x1E61 and KEYECHO echoes the ASCII byte via putch -> the B800 text page.
    // This proves the raw-scancode path (8042 -> IRQ1 -> INT 09h -> BDA ring -> INT
    // 16h) carries an injected key (distinct from the `{"char"}` convenience).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawnKeyecho(threaded.io());
    defer s.deinit();

    _ = try s.run(RUN_CAP); // reach the blocking bioskey loop

    _ = try s.injectKey(0x1E, true, false); // make
    _ = try s.injectKey(0x1E, false, false); // break
    _ = try s.run(RUN_CAP);

    var buf: [80]u8 = undefined;
    const row0 = try screenRow0(&s, &buf);
    try std.testing.expect(row0.len >= 1);
    try std.testing.expectEqual(@as(u8, 'a'), row0[0]);
}

test "mouse: an injected position is read back by the guest (INT 33h AX=0003)" {
    // Inject an absolute mouse position over POST /api/input/mouse, then read it
    // back through MOUSERB's INT 33h AX=0003 loop, which stores X/Y/buttons at the
    // fixed address 0x500 (read via GET /api/mem). Proves the mouse-injection path.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try Session.spawn(std.testing.allocator, threaded.io(), MOUSERB);
    defer s.deinit();

    _ = try s.run(RUN_CAP); // reach the AX=0003 read loop

    // Inject an absolute position; the next run's AX=0003 observes exactly it.
    _ = try s.injectMouse(123, 77, null, null, null);
    _ = try s.run(RUN_CAP);

    // Read the observation area at 0x500: +0 word X, +2 word Y, +4 word buttons.
    const m = try s.mem(0x500, 6);
    // data is hex; decode the three little-endian words.
    var bytes: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), m.data.len);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        bytes[i] = (try hexNib(m.data[i * 2]) << 4) | try hexNib(m.data[i * 2 + 1]);
    }
    const x = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    const y = @as(u16, bytes[2]) | (@as(u16, bytes[3]) << 8);
    const btn = @as(u16, bytes[4]) | (@as(u16, bytes[5]) << 8);
    try std.testing.expectEqual(@as(u16, 123), x);
    try std.testing.expectEqual(@as(u16, 77), y);
    try std.testing.expectEqual(@as(u16, 0), btn);

    // Inject a button -> MOUSERB's loop exits -> program terminates (ret 0).
    _ = try s.injectMouse(null, null, null, null, 1);
    const stop = try s.run(RUN_CAP);
    try std.testing.expect(stop.stop.program_terminated != null);
    const st = try s.status();
    try std.testing.expect(st.terminated);
    try std.testing.expectEqual(@as(u16, 0), st.ret_code);
}

fn hexNib(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.BadHex,
    };
}
