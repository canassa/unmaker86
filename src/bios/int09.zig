//! INT 09h / IRQ1 — the keyboard-interrupt service routine (input Phase 1c). This
//! is the *fill* side of the keyboard path: it reads the raw scancode the 8042 put
//! on port 0x60, runs the shift-flag state machine (§5.1a) over the BDA flag bytes,
//! translates the scancode→BIOS-keycode via the set-1 tables (§1b / scancodes.zig),
//! and enqueues the cooked word into the BDA ring (`bda.kbEnqueue`) that INT 16h
//! drains. The EOI is emitted by the callback's `iret_eoi_pic1` return tail (like
//! INT 08h, bios.zig:69), NOT here.
//!
//! It is host-serviced: a guest IRQ1 traps to this Zig handler, which charges a
//! deterministic synthetic dispatch cost — the guest's real fetch/execute path
//! still ran the IRQ-recognition + trap. A guest that installs its OWN INT 09h ISR
//! overwrites IVT[9] (AH=25/35 read/write the same guest-RAM IVT); the bridge stub
//! is then no longer reached and the guest's ISR takes over (§4.0 / §5.1 access
//! patterns) — the IVT is the single source of truth.
//!
//! The shift-flag state machine (§5.1a) is SEPARATE from the keycode lookup: it
//! decides WHICH modifier column (normal/shift/ctrl/alt) applies and maintains the
//! lock state. It implements: CapsLock-vs-Shift cancellation for A-Z (effective
//! case = CapsLock XOR Shift), NumLock numpad digit-vs-cursor selection, the
//! 0xE0/0xE1 extended-prefix latches, and the Alt-numpad numeric accumulator
//! (digits typed on the numpad while Alt is held → one keystroke on Alt-release).
//! Refs (values verified, not copied): dosbox bios_keyboard.cpp:262-495
//! (IRQ1_Handler); spice86 BiosKeyboardInt9Handler.cs:321.
//!
//! Determinism: the scancode arrives via the device→PIC→IRQ path at the machine's
//! deterministic IRQ-recognition cycle; no host clock, no float, no RNG.

const std = @import("std");
const bda_mod = @import("bda.zig");
const sc = @import("scancodes.zig");

// ---- FLAGS1 (0040:0017) bit masks (AT spec) ----
const F1_RSHIFT: u8 = 0x01;
const F1_LSHIFT: u8 = 0x02;
const F1_CTRL: u8 = 0x04;
const F1_ALT: u8 = 0x08;
const F1_SCROLL_LOCK: u8 = 0x10;
const F1_NUM_LOCK: u8 = 0x20;
const F1_CAPS_LOCK: u8 = 0x40;
const F1_INSERT: u8 = 0x80;
const F1_SHIFT: u8 = F1_LSHIFT | F1_RSHIFT;

// ---- FLAGS2 (0040:0018) bit masks (pressed-vs-latched + Pause/SysReq) ----
const F2_LCTRL: u8 = 0x01;
const F2_LALT: u8 = 0x02;
const F2_SYSREQ: u8 = 0x04;
const F2_PAUSE: u8 = 0x08;
const F2_SCROLL_PRESSED: u8 = 0x10;
const F2_NUM_PRESSED: u8 = 0x20;
const F2_CAPS_PRESSED: u8 = 0x40;
const F2_INSERT_PRESSED: u8 = 0x80;

// ---- FLAGS3 (0040:0096) bit masks (enhanced flags + prefix latches) ----
const F3_LAST_E1: u8 = 0x01; // last code was the 0xE1 prefix
const F3_LAST_E0: u8 = 0x02; // last code was the 0xE0 prefix
const F3_RCTRL: u8 = 0x04; // right-Ctrl held
const F3_RALT: u8 = 0x08; // right-Alt held

// ---- raw set-1 modifier scancodes ----
const SC_LSHIFT: u8 = 0x2A;
const SC_RSHIFT: u8 = 0x36;
const SC_CTRL: u8 = 0x1D; // left-Ctrl; with E0 prefix = right-Ctrl
const SC_ALT: u8 = 0x38; // left-Alt;  with E0 prefix = right-Alt
const SC_CAPS: u8 = 0x3A;
const SC_NUM: u8 = 0x45;
const SC_SCROLL: u8 = 0x46;
const SC_INSERT: u8 = 0x52; // numpad-0 / Ins
const BREAK_BIT: u8 = 0x80;

pub fn Int09(comptime Cpu: type) type {
    return struct {
        const Bda = bda_mod.Bda(Cpu);

        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            const bda = Bda.init(cpu);
            const raw = cpu.bus.portIn8(0x60);

            var f3 = bda.kbFlags3();
            const ext0 = (f3 & F3_LAST_E0) != 0; // this code follows a 0xE0 prefix

            // --- prefix latches (0xE0 / 0xE1) ---
            if (raw == 0xE0) {
                bda.setKbFlags3(f3 | F3_LAST_E0);
                return;
            }
            if (raw == 0xE1) {
                bda.setKbFlags3(f3 | F3_LAST_E1);
                return;
            }
            // Consume the E0 latch for THIS code (E1/Pause handled minimally below).
            if (ext0) {
                f3 &= ~F3_LAST_E0;
                bda.setKbFlags3(f3);
            }
            if ((f3 & F3_LAST_E1) != 0) {
                // 0xE1-prefixed Pause/Break multi-byte sequence: consume the code and
                // clear the latch on the trailing byte (we do not enqueue a word —
                // Pause is handled as a hold; faithful minimal behavior, flagged).
                bda.setKbFlags3(f3 & ~F3_LAST_E1);
                return;
            }

            const is_break = (raw & BREAK_BIT) != 0;
            const code = raw & ~BREAK_BIT;

            // --- modifier / lock keys: update the flag bytes, enqueue nothing ---
            if (updateModifiers(bda, code, is_break, ext0)) return;

            if (is_break) return; // a non-modifier break produces no ring word

            // --- Alt-numpad numeric accumulator: digits typed on the keypad while
            //     Alt is held accumulate; nothing is enqueued until Alt-release. ---
            const f1 = bda.kbShiftFlags();
            if ((f1 & F1_ALT) != 0 and !ext0) {
                if (numpadDigit(code)) |d| {
                    const acc = bda.kbAltKeypad();
                    bda.setKbAltKeypad(acc *% 10 +% d);
                    return;
                }
            }

            // --- translate via the set-1 keycode table in the selected column ---
            const col = selectColumn(f1, code, ext0);
            const word = if (ext0) sc.lookupExt(code, col) else sc.lookup(code, col);
            if (word) |w| {
                _ = bda.kbEnqueue(w); // ring full -> drop (real BIOS beeps); honored
            }
        }

        /// Update FLAGS1/2/3 for a modifier or lock scancode. Returns true if `code`
        /// was a modifier/lock (so the caller enqueues nothing). §5.1a.
        fn updateModifiers(bda: Bda, code: u8, is_break: bool, ext0: bool) bool {
            var f1 = bda.kbShiftFlags();
            var f2 = bda.kbFlags2();
            var f3 = bda.kbFlags3();
            const matched = true;
            switch (code) {
                SC_LSHIFT => setBit(&f1, F1_LSHIFT, !is_break),
                SC_RSHIFT => setBit(&f1, F1_RSHIFT, !is_break),
                SC_CTRL => {
                    // E0-prefixed = right-Ctrl (FLAGS3 bit2); else left-Ctrl (FLAGS2).
                    if (ext0) setBit(&f3, F3_RCTRL, !is_break) else setBit(&f2, F2_LCTRL, !is_break);
                    // The aggregate FLAGS1 Ctrl bit is the OR of both sides.
                    const ctrl_held = ((f2 & F2_LCTRL) != 0) or ((f3 & F3_RCTRL) != 0);
                    setBit(&f1, F1_CTRL, ctrl_held);
                },
                SC_ALT => {
                    if (ext0) setBit(&f3, F3_RALT, !is_break) else setBit(&f2, F2_LALT, !is_break);
                    const alt_held = ((f2 & F2_LALT) != 0) or ((f3 & F3_RALT) != 0);
                    setBit(&f1, F1_ALT, alt_held);
                    // On left-Alt RELEASE, emit the Alt-numpad accumulated code (§5.1a).
                    if (!ext0 and is_break and !alt_held) {
                        const acc = bda.kbAltKeypad();
                        if (acc != 0) {
                            _ = bda.kbEnqueue(@as(u16, acc)); // scancode 0, ASCII = code
                            bda.setKbAltKeypad(0);
                        }
                    }
                },
                SC_CAPS => toggleLock(&f1, &f2, F1_CAPS_LOCK, F2_CAPS_PRESSED, is_break),
                SC_NUM => toggleLock(&f1, &f2, F1_NUM_LOCK, F2_NUM_PRESSED, is_break),
                SC_SCROLL => toggleLock(&f1, &f2, F1_SCROLL_LOCK, F2_SCROLL_PRESSED, is_break),
                else => return false, // not a modifier/lock
            }
            bda.setKbShiftFlags(f1);
            bda.setKbFlags2(f2);
            bda.setKbFlags3(f3);
            return matched;
        }

        /// A lock key (Caps/Num/Scroll): the "pressed" bit (FLAGS2) tracks the held
        /// state; the "locked" bit (FLAGS1) TOGGLES on each make while not already
        /// pressed (a real BIOS toggles on the make edge, not on every repeat).
        fn toggleLock(f1: *u8, f2: *u8, lock_bit: u8, pressed_bit: u8, is_break: bool) void {
            if (is_break) {
                f2.* &= ~pressed_bit;
                return;
            }
            if ((f2.* & pressed_bit) == 0) {
                // make edge: toggle the lock, mark pressed.
                f1.* ^= lock_bit;
                f2.* |= pressed_bit;
            }
        }

        fn setBit(byte: *u8, mask: u8, on: bool) void {
            if (on) byte.* |= mask else byte.* &= ~mask;
        }

        /// Choose the modifier column for `code` from the live shift/lock flags.
        /// CapsLock-vs-Shift cancellation applies only to letters (A-Z): effective
        /// case = CapsLock XOR Shift. NumLock selects digit-vs-cursor on the numpad.
        fn selectColumn(f1: u8, code: u8, ext0: bool) sc.Column {
            const ctrl = (f1 & F1_CTRL) != 0;
            const alt = (f1 & F1_ALT) != 0;
            const shift = (f1 & F1_SHIFT) != 0;
            if (ctrl) return .ctrl;
            if (alt) return .alt;

            if (isLetter(code)) {
                const caps = (f1 & F1_CAPS_LOCK) != 0;
                return if (caps != shift) .shift else .normal; // XOR
            }
            if (!ext0 and isNumpad(code)) {
                // NumLock ON (and not Shift) -> the digit (shift column holds it);
                // Shift while NumLock-ON temporarily yields the cursor (normal).
                const num = (f1 & F1_NUM_LOCK) != 0;
                return if (num != shift) .shift else .normal;
            }
            return if (shift) .shift else .normal;
        }

        fn isLetter(code: u8) bool {
            return switch (code) {
                0x10...0x19, // q..p
                0x1E...0x26, // a..l
                0x2C...0x32, // z..m
                => true,
                else => false,
            };
        }

        fn isNumpad(code: u8) bool {
            return code >= 0x47 and code <= 0x53;
        }

        /// The decimal digit a numpad scancode contributes to the Alt-keypad
        /// accumulator, or null if it is not a numpad digit key. Numpad layout:
        /// 47/48/49 = 7/8/9, 4B/4C/4D = 4/5/6, 4F/50/51 = 1/2/3, 52 = 0.
        fn numpadDigit(code: u8) ?u8 {
            return switch (code) {
                0x47 => 7,
                0x48 => 8,
                0x49 => 9,
                0x4B => 4,
                0x4C => 5,
                0x4D => 6,
                0x4F => 1,
                0x50 => 2,
                0x51 => 3,
                0x52 => 0,
                else => null,
            };
        }
    };
}
