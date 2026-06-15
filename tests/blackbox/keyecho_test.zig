//! Black-box INPUT-INJECTION tests for the zdos debugger HTTP API.
//!
//! These spawn the REAL `zdos --serve 0 <exe>` child and drive it over a real
//! localhost socket (same harness as `blackbox_test.zig`), centered on two real
//! BCC-compiled DOS fixtures:
//!   - `KEYECHO.EXE` — blocks on bioskey(0) (INT 16h AH=00, the API-injected
//!     keyboard path: 8042 -> IRQ1 -> INT 09h -> BDA ring -> INT 16h), echoes each
//!     key's ASCII to CON via INT 21h AH=02, and exits on ESC.
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

/// Drive KEYECHO through one full key script and return the FINAL CON bytes + the
/// terminating stop reason. Used twice (two fresh processes) to prove determinism.
fn driveKeyechoScript(s: *Session, con_out: []u8) !struct { con: []u8, term_stop: bool, terminated: bool, ret_code: u16 } {
    // Run once so the guest reaches the blocking bioskey loop (INT 16h AH=00).
    _ = try s.run(RUN_CAP);

    // Inject 'H' then 'I' by CHARACTER; run a bounded cap after each so bioskey
    // unblocks, echoes (INT 21h AH=02 -> CON), and re-blocks.
    _ = try s.injectKeyChar('H');
    _ = try s.run(RUN_CAP);
    _ = try s.injectKeyChar('I');
    _ = try s.run(RUN_CAP);

    // Inject ESC as a precise scancode edge (make 0x01) — the safest ESC path.
    _ = try s.injectKey(SC_ESC, true, false);
    const stop = try s.run(RUN_CAP);

    const con = try s.consoleBytes(con_out);
    const st = try s.status();
    return .{
        .con = con,
        // The run that consumed ESC ended on the program-terminate stop reason.
        .term_stop = stop.stop.program_terminated != null,
        .terminated = st.terminated,
        .ret_code = st.ret_code,
    };
}

test "keyecho: inject H,I -> echoed 'HI'; ESC prints '!' and terminates (ret 0)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawnKeyecho(threaded.io());
    defer s.deinit();

    var buf: [64]u8 = undefined;
    const r = try driveKeyechoScript(&s, &buf);

    // Echo: the two printable keys were echoed to CON, then ESC printed the '!'
    // marker -> the full CON output is exactly "HI!".
    try std.testing.expectEqualStrings("HI!", r.con);
    // ESC terminated the program cleanly: the ESC run stopped on program_terminated,
    // and the final status confirms termination via INT 21h AH=4C with ret code 0.
    try std.testing.expect(r.term_stop);
    try std.testing.expect(r.terminated);
    try std.testing.expectEqual(@as(u16, 0), r.ret_code);
}

test "keyecho: DETERMINISM — two fresh processes produce byte-identical CON output" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a = try spawnKeyecho(io);
    defer a.deinit();
    var bufa: [64]u8 = undefined;
    const ra = try driveKeyechoScript(&a, &bufa);

    var b = try spawnKeyecho(io);
    defer b.deinit();
    var bufb: [64]u8 = undefined;
    const rb = try driveKeyechoScript(&b, &bufb);

    // The same command/key script over two INDEPENDENT processes yields identical
    // CON output AND identical termination — the input path is deterministic.
    try std.testing.expectEqualStrings(ra.con, rb.con);
    try std.testing.expectEqual(ra.terminated, rb.terminated);
    try std.testing.expectEqual(ra.ret_code, rb.ret_code);
}

test "keyboard: an injected key reaches the guest's BIOS keyboard chain (CON echo)" {
    // The general keyboard-injection gap: inject ONE key by RAW scancode edge and
    // assert it reached the guest by observing the echo it produced. Set-1 scancode
    // 0x1E with NO Shift is 'a' (ASCII 0x61); the INT 09h ISR cooks it to the BDA
    // word 0x1E61 and KEYECHO echoes the ASCII byte via INT 21h -> CON. This proves
    // the raw-scancode path (8042 -> IRQ1 -> INT 09h -> BDA ring -> INT 16h) carries
    // an injected key (distinct from the `{"char"}` convenience the flagship uses).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var s = try spawnKeyecho(threaded.io());
    defer s.deinit();

    _ = try s.run(RUN_CAP); // reach the blocking bioskey loop

    _ = try s.injectKey(0x1E, true, false); // make
    _ = try s.injectKey(0x1E, false, false); // break
    _ = try s.run(RUN_CAP);

    var buf: [16]u8 = undefined;
    const con = try s.consoleBytes(&buf);
    try std.testing.expectEqualStrings("a", con);
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
