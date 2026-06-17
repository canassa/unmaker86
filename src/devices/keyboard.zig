//! The 8042 keyboard controller (KBC) + its attached AT keyboard, ports 0x60
//! (data) / 0x64 (status + command). This is the *fill* side of the keyboard
//! hardware path (the half zdos lacked): a host injector pushes scancodes into the
//! controller output buffer and asserts IRQ1; the guest INT 09h ISR reads port
//! 0x60, translates, and fills the BDA ring; INT 16h drains it (input-injection.md
//! §4.1 — OPEN-A Option 2). Both reference emulators run this exact path (dosbox
//! `intel8042.cpp`/`keyboard.cpp`; spice86 `Intel8042Controller.cs`/`PS2Keyboard.cs`).
//!
//! It is an ordinary `src/devices/` module (M-D1): the machine OWNS the value,
//! registers its two ports through the bus `registerPort` seam like the PIC/PIT,
//! and wires a back-pointer to the PIC so the controller can assert IRQ1. Module
//! graph: it imports only the bus contract leaf; it never imports cpu/machine. The
//! PIC dependency is an opaque `ctx` + bound `raise` fn (re-bound on restore),
//! mirroring how the PIT reaches the PIC.
//!
//! Command set + responses (input-injection.md §5.1b — re-derived from the public
//! AT/8042 spec). Device commands are written to
//! port 0x60; controller commands to port 0x64. The ACK/response bytes are exact
//! because real drivers (and many games' keyboard init) issue these and WAIT for
//! the bytes: a missing 0xFA/0xAA after a 0xFF reset makes a driver retry 3x then
//! hang. So the FIFO + status sequencing must be correct, not approximate.
//!
//! Honest deferrals (flag, don't fake — §5.1b):
//!   - A20 via controller cmd 0xD1 bit1 is NOT handled here: the bus owns A20
//!     (`src/bus/a20.zig`). The device latches the output-port write but does NOT
//!     drive A20 (no double owner).
//!   - The auxiliary/mouse channel (0xA8/0xD4/0xD3) is NOT wired (OPEN-E: zdos
//!     models the INT 33h driver, not the PS/2 mouse controller).
//!   - Controller cmd 0xFE (pulse CPU-reset line) is out of scope.
//!
//! Determinism (CLAUDE prime directive): the device reads NO host clock; the FIFO
//! + status + config are plain device state, deterministically reset (CLAUDE #5).
//! Asserting IRQ1 only sets the PIC IRR (timing-neutral, M-D6) — the cost of the
//! guest INT 09h is charged by the normal fetch/execute loop on the next `run`, so
//! there is no ledger hole. No host time / RNG / float / thread anywhere
//! (grep-enforced under the `src/devices` gate).

const std = @import("std");
const bus_mod = @import("bus");
const timing = @import("timing");

const PortHandler = bus_mod.PortHandler;

/// The PIC raise seam (M-D1/M-D11), as a bound callback so the device module does
/// NOT import the machine. The machine binds it to its `Pic` at `wire` and re-binds
/// on restore. Pointer-free w.r.t. the device for snapshot.
pub const RaiseFn = *const fn (ctx: *anyopaque, line: u4) void;

/// The scheduler seam the keyboard uses for typematic auto-repeat, as bound
/// callbacks (mirror `pit.zig` `SchedulerApi`) so the device module does NOT import
/// the machine (module-graph rule: devices <- bus/abi only). The machine binds these
/// to its own `Scheduler` at `wire` and re-binds on restore. `schedule`/`cancel`
/// carry an opaque `ctx` (the machine, which owns the scheduler).
pub const SchedulerApi = struct {
    ctx: *anyopaque,
    /// schedule(ctx, from_cycle, delta_cycles) — schedules the keyboard's repeat
    /// event `delta_cycles` after `from`. Unlike the PIT seam this passes CYCLES
    /// directly (typematic is an ms→cycle conversion, not a PIT-tick count).
    schedule: *const fn (ctx: *anyopaque, from: u64, delta_cycles: u64) void,
    /// cancel any live keyboard repeat event.
    cancel: *const fn (ctx: *anyopaque) void,
};

/// AT/PS2 `0xF3` typematic byte `0dd rrrrr`: the delay field (bits 6-5) selects one
/// of these initial-delay values, in milliseconds (dosbox-x keyboard.cpp:684-690 /
/// dosbox-staging input/keyboard.cpp:346-354).
const DELAY_MS = [4]u64{ 250, 500, 750, 1000 };

/// The rate field (bits 4-0) selects one of these inter-repeat PERIODS, in
/// milliseconds (non-linear table; same references). Index 0 (~30 cps / 33 ms) is
/// the keyboard power-on default period.
const PERIOD_MS = [32]u64{
    33,  37,  42,  46,  50,  54,  58,  63,  67,  75,  83,  92,  100, 109, 118, 125,
    133, 149, 167, 182, 200, 217, 233, 250, 270, 303, 333, 370, 400, 435, 476, 500,
};

/// Convert milliseconds to DEVICE-TIME units (Phase 1 device-time seam). The
/// typematic delay/rate are real-time-anchored periods, so they live in the
/// mult-independent device-time domain; the scheduler keys on device-time and the
/// machine converts the fire point to CPU cycles at the boundary. Device-time ==
/// nominal cycles at the reference mult, so this is byte-identical to the former
/// ms→cycles math (`ms * CPU_CLOCK_HZ / 1000`). Integer, no host time, no floats.
fn msToDeviceTime(ms: u64) u64 {
    return timing.msToDeviceTime(ms);
}

/// The currently-repeating key (the last make still held). `scancode` is the set-1
/// make code; `ext` true means it is an extended key (re-injected with an 0xE0
/// prefix). Pause/PrtScn are excluded (no typematic — set to `null`).
const RepeatCode = struct { scancode: u8, ext: bool };

// ---- Status-register (port 0x64 read) bit layout, AT 8042 spec ----
const ST_OBF: u8 = 0x01; // output buffer full (a byte is ready on 0x60)
const ST_IBF: u8 = 0x02; // input buffer full (host wrote, ctrl not yet read)
const ST_SYS: u8 = 0x04; // system flag (set after a passed self-test)
const ST_CMD: u8 = 0x08; // 1 = last write was a command (0x64), 0 = data (0x60)
const ST_KBD_ENABLED: u8 = 0x10; // keyboard not inhibited
const ST_AUX_OBF: u8 = 0x20; // output buffer holds aux (mouse) data — unused here

// ---- Config (command) byte bits, AT 8042 spec ----
const CFG_KBD_IRQ: u8 = 0x01; // bit0: keyboard interrupt (IRQ1) enable
const CFG_AUX_IRQ: u8 = 0x02; // bit1: aux interrupt (IRQ12) enable — unused
const CFG_SYS: u8 = 0x04; // bit2: system flag (mirrors ST_SYS)
const CFG_KBD_DISABLE: u8 = 0x10; // bit4: keyboard clock disabled
const CFG_AUX_DISABLE: u8 = 0x20; // bit5: aux clock disabled
const CFG_TRANSLATE: u8 = 0x40; // bit6: translate to scancode set 1

// ---- Response/ACK bytes (AT keyboard + 8042 spec, §5.1b) ----
const RESP_ACK: u8 = 0xFA; // device ACK
const RESP_BAT_OK: u8 = 0xAA; // basic assurance test passed (after reset)
const RESP_ECHO: u8 = 0xEE; // echo reply
const RESP_RESEND: u8 = 0xFE; // resend
const RESP_ID_PREFIX: u8 = 0xAB; // identify: first byte (MF2 keyboard)
const RESP_ID_MF2: u8 = 0x83; // identify: second byte (MF2 101/102-key)
const RESP_SELFTEST_OK: u8 = 0x55; // controller self-test (0xAA) passed
const RESP_PORTTEST_OK: u8 = 0x00; // keyboard-port test (0xAB) — no error

/// Default config byte: keyboard IRQ enabled, system flag set, translate on,
/// keyboard not inhibited. This matches the post-BIOS-init AT default a real
/// driver expects to read back via controller cmd 0x20.
const DEFAULT_CONFIG: u8 = CFG_KBD_IRQ | CFG_SYS | CFG_TRANSLATE;

/// The output-port (0xD0/0xD1) default: bit0 (CPU reset, active low) and bit1 (A20)
/// high. A20 itself is owned by the bus — this latch is read-back-only here.
const DEFAULT_OUTPUT_PORT: u8 = 0x03;

/// A command the controller is waiting to consume a parameter byte for, written to
/// port 0x60 after a port-0x64 / port-0x60 command that takes one.
const PendingParam = enum {
    none,
    write_config, // 0x64 cmd 0x60: the next 0x60 write is the new config byte
    write_output_port, // 0x64 cmd 0xD1: the next 0x60 write is the output port
    kbd_set_leds, // 0x60 cmd 0xED: the next 0x60 write is the LED mask
    kbd_typematic, // 0x60 cmd 0xF3: the next 0x60 write is the rate/delay
};

/// Output-buffer FIFO depth. A real 8042 has a 1-byte output buffer, but reset
/// (0xFA then 0xAA) and identify (0xFA then 0xAB then 0x83) queue multiple bytes
/// the driver reads back-to-back; a small FIFO models that read sequence without a
/// host clock. 16 comfortably covers any single response + injected scancodes.
pub const FIFO_LEN = 16;

pub const Keyboard = struct {
    // ---- output buffer (port 0x60 read) — a small ring FIFO ----
    fifo: [FIFO_LEN]u8 = @splat(0),
    fifo_head: u8 = 0,
    fifo_tail: u8 = 0,
    fifo_count: u8 = 0,

    status: u8 = ST_KBD_ENABLED, // port 0x64 read value
    config: u8 = DEFAULT_CONFIG, // controller command (config) byte
    output_port: u8 = DEFAULT_OUTPUT_PORT, // 0xD0/0xD1 latch (A20 owned by the bus)
    last_response: u8 = 0, // for the 0xFE "resend last byte" command
    pending: PendingParam = .none,

    // ---- typematic auto-repeat state (config; the live repeat event rides the
    //      scheduler snapshot, NOT this struct, so there is no `next_repeat_cycle`
    //      here — that would duplicate the scheduler entry's `fire_cycle`) ----
    /// The key currently auto-repeating (last make still held), or `null` when no
    /// key is held. KEYSTONE: `null` ⇒ no `schedule` call ⇒ byte-identical to a run
    /// with no typematic at all.
    repeat_code: ?RepeatCode = null,
    /// Initial-delay before the first repeat, in CPU cycles (decoded from `0xF3` /
    /// INT 16h AH=03; default 500 ms).
    delay_cycles: u64 = msToDeviceTime(500),
    /// Inter-repeat period, in CPU cycles (default 33 ms ≈ 30 cps).
    rate_cycles: u64 = msToDeviceTime(33),

    // ---- back-pointers wired by the machine at `wire` (M-D1) — NOT snapshotted;
    //      re-bound on restore exactly like `raise_*` ----
    raise_ctx: ?*anyopaque = null,
    raise_fn: ?RaiseFn = null,
    /// The typematic scheduler seam (bound at `wire`). `null` outside a wired
    /// machine (e.g. a pure port-level unit test) — then typematic is inert.
    sched: ?SchedulerApi = null,
    /// Back-pointer to the cycle ledger (`&cpu.st.cycles`) — the single time source
    /// for the "now" the first repeat is scheduled from.
    cycles: ?*const u64 = null,

    pub fn reset(self: *Keyboard) void {
        const ctx = self.raise_ctx;
        const f = self.raise_fn;
        const s = self.sched;
        const cyc = self.cycles;
        self.* = .{};
        self.raise_ctx = ctx;
        self.raise_fn = f;
        self.sched = s;
        self.cycles = cyc;
    }

    fn cyclesNow(self: *const Keyboard) u64 {
        return (self.cycles orelse return 0).*;
    }

    fn raiseIrq1(self: *Keyboard) void {
        if (self.raise_fn) |f| f(self.raise_ctx.?, 1);
    }

    // -----------------------------------------------------------------------
    // Output FIFO (the port-0x60 output buffer).
    // -----------------------------------------------------------------------

    /// Push one byte into the output buffer. Returns false if the FIFO is full.
    /// Updates the OBF status bit. Does NOT raise IRQ1 — callers decide (a device
    /// response does not, an injected scancode does, via `pushScancode`).
    pub fn pushByte(self: *Keyboard, b: u8) bool {
        if (self.fifo_count >= FIFO_LEN) return false;
        self.fifo[self.fifo_tail] = b;
        self.fifo_tail = (self.fifo_tail + 1) % FIFO_LEN;
        self.fifo_count += 1;
        self.status |= ST_OBF;
        return true;
    }

    /// A device response byte (ACK / BAT / identify / echo). Recorded as the
    /// "last byte" for the 0xFE resend command. Returns false if the FIFO is full.
    fn pushResponse(self: *Keyboard, b: u8) bool {
        self.last_response = b;
        return self.pushByte(b);
    }

    /// Pop the head byte (the value a port-0x60 read returns). When the buffer
    /// empties, OBF clears. On an empty buffer returns the last response (a real
    /// 8042 returns the stale latch); this is deterministic.
    ///
    /// IRQ1 follows the OBF LEVEL on a real 8042: as long as a byte remains in the
    /// output buffer after a read, the controller re-asserts IRQ1 so the ISR is
    /// re-entered to drain the rest (e.g. the 0xE0 prefix + its scancode arrive as
    /// two bytes the ISR reads across two IRQ1 invocations). Without this, a
    /// multi-byte sequence injected before the ISR runs would strand the tail bytes.
    fn popByte(self: *Keyboard) u8 {
        if (self.fifo_count == 0) {
            self.status &= ~ST_OBF;
            return self.last_response;
        }
        const b = self.fifo[self.fifo_head];
        self.fifo_head = (self.fifo_head + 1) % FIFO_LEN;
        self.fifo_count -= 1;
        if (self.fifo_count == 0) {
            self.status &= ~ST_OBF;
        } else if ((self.config & CFG_KBD_IRQ) != 0 and (self.config & CFG_KBD_DISABLE) == 0) {
            // Bytes remain (OBF still high): re-assert IRQ1 (level-triggered OBF).
            self.raiseIrq1();
        }
        return b;
    }

    // -----------------------------------------------------------------------
    // Injection seam (Phase 1e drives this through the Controller). A scancode
    // (already make/break-encoded, with the 0xE0 prefix prepended by the caller
    // for an extended key) is pushed into the output buffer and IRQ1 is asserted
    // if the keyboard interrupt is enabled (config bit0) and not inhibited.
    // -----------------------------------------------------------------------

    /// Push one scancode byte and assert IRQ1. Returns false if the FIFO is full
    /// (the caller surfaces `input_buffer_full`). The cooked BDA-ring word is
    /// produced by the guest INT 09h ISR, never host-side.
    pub fn pushScancode(self: *Keyboard, code: u8) bool {
        if (!self.pushByte(code)) return false;
        if ((self.config & CFG_KBD_IRQ) != 0 and (self.config & CFG_KBD_DISABLE) == 0) {
            self.raiseIrq1();
        }
        return true;
    }

    /// True if the output FIFO has room for one more scancode byte.
    pub fn fifoHasRoom(self: *const Keyboard) bool {
        return self.fifo_count < FIFO_LEN;
    }

    /// Free slots in the output FIFO (an extended key needs 2: prefix + code).
    pub fn fifoFree(self: *const Keyboard) u8 {
        return FIFO_LEN - self.fifo_count;
    }

    // -----------------------------------------------------------------------
    // Typematic auto-repeat (the held-key re-make path). The keyboard re-sends the
    // MAKE code (no intervening break) while a key is held, after an initial delay
    // and then at the typematic rate — exactly like real AT/PS2 hardware. The
    // cadence is a PURE function of the cycle ledger via the machine scheduler
    // (mirror `pit.zig` ch0): NEVER host time. The repeat event rides the scheduler
    // snapshot verbatim (`EventKind.kbd_repeat`); only the decoded config lives in
    // the keyboard snapshot.
    //
    // Driven from the INJECTION EDGE (`noteEdge`, called by the Controller's
    // `injectScancode`) with the clean `(scancode, make, ext)` decomposition, NOT by
    // re-parsing raw FIFO bytes (which would have to track 0xE0 prefixes / break
    // bit). Last-key-wins: a new make redirects the repeat and restarts the delay;
    // a break of a DIFFERENT key is ignored (no resume-on-release).
    // -----------------------------------------------------------------------

    /// Pause and Print-Screen do NOT auto-repeat on real hardware (dosbox-staging
    /// `typematic_update`). Pause cannot be injected through the single-(scancode,
    /// ext) seam at all; Print-Screen makes as the extended scancode 0x37.
    fn excludedFromRepeat(scancode: u8, ext: bool) bool {
        return ext and scancode == 0x37; // E0 37 = Print Screen make
    }

    /// Cancel any live repeat event (cancel-then-schedule discipline — `schedule`
    /// asserts `!hasLive`, so every (re)arm cancels first).
    fn cancelRepeat(self: *Keyboard) void {
        if (self.sched) |s| s.cancel(s.ctx);
    }

    /// Schedule the repeat event `delta` cycles after `from`. Caller has already
    /// canceled any live event.
    fn scheduleRepeat(self: *Keyboard, from: u64, delta: u64) void {
        if (self.sched) |s| s.schedule(s.ctx, from, delta);
    }

    /// Note a make/break EDGE entering the keyboard (called from the injection seam
    /// AFTER a successful push, so the typematic model tracks exactly the edges the
    /// guest observes). Drives the typematic state machine:
    ///   - MAKE of a repeatable key: set `repeat_code` (last-key-wins) and
    ///     cancel-then-schedule the first repeat at `now + delay_cycles`.
    ///   - BREAK of the repeating key: clear `repeat_code` + cancel.
    ///   - BREAK of a different key: ignore (only the last-held key repeats).
    pub fn noteEdge(self: *Keyboard, scancode: u8, make: bool, ext: bool) void {
        if (make) {
            if (excludedFromRepeat(scancode, ext)) {
                // A non-repeating make ends any current repeat candidate (real
                // hardware: the last key sent is what repeats; Pause/PrtScn aside).
                self.repeat_code = null;
                self.cancelRepeat();
                return;
            }
            self.repeat_code = .{ .scancode = scancode, .ext = ext };
            self.cancelRepeat();
            self.scheduleRepeat(self.cyclesNow(), self.delay_cycles);
        } else {
            // BREAK: only stop if it is the key currently repeating (last-key-wins;
            // no resume of an earlier-held key).
            if (self.repeat_code) |rc| {
                if (rc.scancode == scancode and rc.ext == ext) {
                    self.repeat_code = null;
                    self.cancelRepeat();
                }
            }
        }
    }

    /// The repeat-event callback (called by the machine's `fireDue` at the
    /// deterministic `fire_cycle`). Re-injects `repeat_code` as a MAKE via the normal
    /// FIFO/IRQ1 path (E0 prefix first if extended), then reschedules at
    /// `fire_cycle + rate_cycles` (from `fire_cycle`, NOT `cyclesNow`, so burst
    /// granularity never drifts the cadence — mirror `onPitCh0Fire`). On a full FIFO
    /// the repeat is dropped (real keyboards drop on a full buffer) but the cadence
    /// is preserved.
    pub fn onRepeatFire(self: *Keyboard, fire_cycle: u64) void {
        const rc = self.repeat_code orelse return; // race-safe: nothing to repeat
        if (rc.ext) {
            // An extended key needs BOTH slots (prefix + code); never strand a lone
            // 0xE0 (mirror `controller.zig:823`). On no room, skip this repeat.
            if (self.fifoFree() >= 2) {
                _ = self.pushScancode(0xE0);
                _ = self.pushScancode(rc.scancode);
            }
        } else {
            _ = self.pushScancode(rc.scancode); // false on full FIFO: dropped repeat
        }
        // Reschedule from the SCHEDULED fire_cycle (cancel-then-schedule).
        self.cancelRepeat();
        self.scheduleRepeat(fire_cycle, self.rate_cycles);
    }

    /// Decode an AT/PS2 `0xF3` typematic byte `0dd rrrrr` into delay/rate cycles
    /// (the SAME decode the BIOS INT 16h AH=03 path drives). Bits 6-5 = delay index,
    /// bits 4-0 = rate index.
    fn setTypematic(self: *Keyboard, byte: u8) void {
        self.delay_cycles = msToDeviceTime(DELAY_MS[(byte >> 5) & 0x03]);
        self.rate_cycles = msToDeviceTime(PERIOD_MS[byte & 0x1F]);
    }

    /// Public entry for the BIOS INT 16h AH=03 path (same decode as port 0x60 0xF3).
    pub fn setTypematicByte(self: *Keyboard, byte: u8) void {
        self.setTypematic(byte);
    }

    // -----------------------------------------------------------------------
    // Port 0x60 (data) write — a device command OR a pending parameter byte.
    // -----------------------------------------------------------------------
    fn writeData(self: *Keyboard, v: u8) void {
        switch (self.pending) {
            .write_config => {
                self.config = v;
                // Keep the system-flag status bit in sync with config bit2.
                if (v & CFG_SYS != 0) self.status |= ST_SYS else self.status &= ~ST_SYS;
                self.pending = .none;
                return;
            },
            .write_output_port => {
                // The output port is latched read-back-only; A20 (bit1) is owned by
                // the bus, NOT driven here (§5.1b deferral — no double owner).
                self.output_port = v;
                self.pending = .none;
                return;
            },
            .kbd_set_leds => { // the LED-mask param after 0xED — ACK it.
                self.pending = .none;
                _ = self.pushResponse(RESP_ACK);
                return;
            },
            .kbd_typematic => { // the rate/delay param after 0xF3 — decode + ACK.
                self.setTypematic(v);
                self.pending = .none;
                _ = self.pushResponse(RESP_ACK);
                return;
            },
            .none => {},
        }
        self.deviceCommand(v);
    }

    /// A keyboard-device command (written to port 0x60). §5.1b table.
    fn deviceCommand(self: *Keyboard, cmd: u8) void {
        switch (cmd) {
            0xED => { // set LEDs: ACK, then ACK the following mask byte.
                _ = self.pushResponse(RESP_ACK);
                self.pending = .kbd_set_leds;
            },
            0xEE => { // echo: replies 0xEE (NOT an ACK).
                _ = self.pushResponse(RESP_ECHO);
            },
            0xF2 => { // identify: ACK, then 0xAB, 0x83 (MF2 101/102-key).
                _ = self.pushResponse(RESP_ACK);
                _ = self.pushResponse(RESP_ID_PREFIX);
                _ = self.pushResponse(RESP_ID_MF2);
            },
            0xF3 => { // set typematic rate/delay: ACK, then ACK the rate byte.
                _ = self.pushResponse(RESP_ACK);
                self.pending = .kbd_typematic;
            },
            0xF4 => _ = self.pushResponse(RESP_ACK), // enable scanning
            0xF5 => _ = self.pushResponse(RESP_ACK), // disable scanning (defaults)
            0xF6 => _ = self.pushResponse(RESP_ACK), // set defaults
            0xFE => { // resend last byte: re-send the previous response.
                _ = self.pushByte(self.last_response);
            },
            0xFF => { // reset + self-test (BAT): ACK, then 0xAA (BAT-OK), in order.
                _ = self.pushResponse(RESP_ACK);
                _ = self.pushResponse(RESP_BAT_OK);
            },
            else => {
                // An unknown device command: respond RESEND (a real keyboard's
                // behavior), surfacing the gap honestly rather than silently ACKing.
                _ = self.pushResponse(RESP_RESEND);
            },
        }
    }

    // -----------------------------------------------------------------------
    // Port 0x64 (command) write — a controller command. §5.1b table.
    // -----------------------------------------------------------------------
    fn writeCommand(self: *Keyboard, cmd: u8) void {
        self.status |= ST_CMD;
        switch (cmd) {
            0x20 => _ = self.pushByte(self.config), // read config byte -> 0x60
            0x60 => self.pending = .write_config, // write config (next 0x60 write)
            0xAA => { // controller self-test -> 0x55 (passed)
                self.status |= ST_SYS; // self-test sets the system flag
                _ = self.pushByte(RESP_SELFTEST_OK);
            },
            0xAB => _ = self.pushByte(RESP_PORTTEST_OK), // test kbd port -> 0x00
            0xAD => self.config |= CFG_KBD_DISABLE, // disable keyboard port
            0xAE => self.config &= ~CFG_KBD_DISABLE, // enable keyboard port
            0xD0 => _ = self.pushByte(self.output_port), // read output port -> 0x60
            0xD1 => self.pending = .write_output_port, // write output port
            else => {
                // 0xA8/0xD4 (aux), 0xFE (pulse reset), and any other controller
                // command are deferred (§5.1b) — recorded as a no-op here. A guest
                // that depends on one is a structural gap to surface, not to fake.
            },
        }
    }

    // -----------------------------------------------------------------------
    // PortHandler wiring (ports 0x60 + 0x64).
    // -----------------------------------------------------------------------
    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Keyboard = @ptrCast(@alignCast(ctx));
        return switch (port) {
            0x60 => blk: {
                self.status &= ~ST_CMD; // a data read clears the cmd/data marker
                break :blk self.popByte();
            },
            0x64 => self.status,
            else => 0xFF,
        };
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Keyboard = @ptrCast(@alignCast(ctx));
        switch (port) {
            0x60 => self.writeData(v),
            0x64 => self.writeCommand(v),
            else => {},
        }
    }

    /// Direct typed port access (tests / internal callers). The bus path goes
    /// through the `*anyopaque` thunks above.
    pub fn out8(self: *Keyboard, port: u16, v: u8) void {
        portOut8(self, port, v);
    }
    pub fn in8(self: *Keyboard, port: u16) u8 {
        return portIn8(self, port);
    }

    const vtable: PortHandler.VTable = .{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    pub fn portHandler(self: *Keyboard) PortHandler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (M-D11) — by value, no pointers. The PIC raise
    // back-pointer is re-bound by the machine on restore (never by host pointer).
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        fifo: [FIFO_LEN]u8,
        fifo_head: u8,
        fifo_tail: u8,
        fifo_count: u8,
        status: u8,
        config: u8,
        output_port: u8,
        last_response: u8,
        pending: PendingParam,
        // Typematic config (the live repeat event itself rides the SCHEDULER
        // snapshot, not this struct — so no `next_repeat_cycle` here).
        repeat_code: ?RepeatCode,
        delay_cycles: u64,
        rate_cycles: u64,
    };
    pub fn snapshot(self: *const Keyboard) Snapshot {
        return .{
            .fifo = self.fifo,
            .fifo_head = self.fifo_head,
            .fifo_tail = self.fifo_tail,
            .fifo_count = self.fifo_count,
            .status = self.status,
            .config = self.config,
            .output_port = self.output_port,
            .last_response = self.last_response,
            .pending = self.pending,
            .repeat_code = self.repeat_code,
            .delay_cycles = self.delay_cycles,
            .rate_cycles = self.rate_cycles,
        };
    }
    pub fn restore(self: *Keyboard, snap: Snapshot) void {
        self.fifo = snap.fifo;
        self.fifo_head = snap.fifo_head;
        self.fifo_tail = snap.fifo_tail;
        self.fifo_count = snap.fifo_count;
        self.status = snap.status;
        self.config = snap.config;
        self.output_port = snap.output_port;
        self.last_response = snap.last_response;
        self.pending = snap.pending;
        self.repeat_code = snap.repeat_code;
        self.delay_cycles = snap.delay_cycles;
        self.rate_cycles = snap.rate_cycles;
    }
};
