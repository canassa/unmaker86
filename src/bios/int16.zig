//! INT 16h — BIOS keyboard services (D7 / I/O band K1). Reads the BDA keyboard
//! ring (0040:001E..., head/tail at 0040:001A/001C) filled either by the INT 09h/
//! IRQ1 handler from the keyboard device or — in the deterministic K1 oracle —
//! seeded directly by a guest program (plans/io-oracle.md §2.2). INT 16h drains
//! the buffer; it NEVER reads the host. Determinism: key input is scripted/seeded
//! external input delivered at deterministic cycles via the device→PIC→IRQ path
//! (or program-seeded), so the same guest code over the same ring is byte-stable.
//!
//! Semantics matched verbatim against dosbox-x INT16_Handler
//! (references/dosbox-x/src/ints/bios_keyboard.cpp:1319) for the non-PC98,
//! non-DOSV, non-CJK config (oracle machine=vgaonly):
//!
//!   AH=00 GET KEYSTROKE          dequeue head; if NORMAL return AX=scan:ascii;
//!                                if ENHANCED, discard it and read the next (the
//!                                reg_ip idle-loop at :1334-1340 re-issues INT16h
//!                                until a normal key surfaces — observably a
//!                                dequeue-and-skip-enhanced loop for a seeded ring).
//!   AH=10 GET KEYSTROKE enhanced dequeue head; KEEP enhanced scancodes; a key
//!                                whose low byte==0xF0 (and high!=0) has its low
//!                                byte cleared (:1355-1358).
//!   AH=01 CHECK KEYSTROKE        peek; loop discarding enhanced keys; if a normal
//!                                key is at head ZF=0, AX=word (NOT dequeued);
//!                                if the ring empties ZF=1 and AX is UNCHANGED
//!                                (:1372-1391 — dosbox does not touch reg_ax on
//!                                the empty branch).
//!   AH=11 CHECK KEYSTROKE enh.   peek once; empty→ZF=1 (AX unchanged); else ZF=0,
//!                                AX=word with the 0xF0 low-clear transform, NOT
//!                                dequeued (:1410-1419).
//!   AH=02 GET SHIFT FLAGS        AL = FLAGS1 (0040:0017) (:1421-1422).
//!
//! "Enhanced" per IsEnhancedKey (bios_keyboard.cpp:1269, non-PC98/non-CJK path):
//!   - high byte (scancode) > 0x84, OR (low byte==0xF0 && high!=0)  → enhanced.
//!   - high byte==0xE0 → numblock Enter/slash: TRANSLATED in place, NOT enhanced.
//!   - low byte==0xE0 with high!=0 (extended key) → masked to high<<8, NOT enhanced.
//!
//! DETERMINISM SEAM — blocking on an EMPTY ring (AH=00/10): a faithful blocking
//! read would idle (dosbox-x INT 28h / wait for a hardware key). In a headless
//! deterministic machine with no live keyboard a true block would hang, and
//! busy-waiting against host time is forbidden (CLAUDE #2/#3). The K1 oracle
//! programs always pre-seed the ring so AH=00 never blocks. For the empty case we
//! do the deterministic thing — return AX=0 (no key) without spinning — and FLAG
//! it as the carried seam in plans/dos-coverage-gaps.md §3.1: real blocking input
//! needs the deterministic event loop / INT 28h once a live keyboard device
//! arrives. Not faked, not in scope this band.

const std = @import("std");
const bda_mod = @import("bda.zig");

/// dosbox-x IsEnhancedKey (bios_keyboard.cpp:1269), non-PC98/non-CJK path.
/// Takes the key by value and returns both the (possibly translated) key and
/// whether it is an enhanced key the AH=00/01 path must drop.
const KeyClass = struct { key: u16, enhanced: bool };

fn classifyKey(key_in: u16) KeyClass {
    var key = key_in;
    const hi = key >> 8;
    // Numblock Enter (0x0A/0x0D) and slash under the 0xE0 high marker: translate
    // in place; NOT enhanced.
    if (hi == 0xE0) {
        const lo = key & 0xFF;
        if (lo == 0x0A or lo == 0x0D) {
            key = (key & 0xFF) | 0x1C00; // return on the numblock
        } else {
            key = (key & 0xFF) | 0x3500; // slash on the numblock
        }
        return .{ .key = key, .enhanced = false };
    }
    // Enhanced: scancode part > 0x84, or specially-marked combo (low==0xF0, high!=0).
    if (hi > 0x84 or ((key & 0xFF) == 0xF0 and hi != 0)) {
        return .{ .key = key, .enhanced = true };
    }
    // Extended key: low==0xE0 with high set → mask to the high byte. NOT enhanced.
    if (hi != 0 and (key & 0xFF) == 0xE0) {
        key &= 0xFF00;
    }
    return .{ .key = key, .enhanced = false };
}

/// The 0xF0 low-clear transform applied by AH=10/11 to enhanced keys before
/// returning them (bios_keyboard.cpp:1355-1358 / 1414-1417).
fn enhancedReturnTransform(key: u16) u16 {
    if ((key & 0xFF) == 0xF0 and (key >> 8) != 0) return key & 0xFF00;
    return key;
}

pub fn Int16(comptime Cpu: type) type {
    return struct {
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = bda_mod.Bda(Cpu).init(cpu);
            switch (ah) {
                0x00 => { // GET KEYSTROKE (skips enhanced keys)
                    while (bda.kbDequeue()) |w| {
                        const c = classifyKey(w);
                        if (!c.enhanced) {
                            cpu.st.setReg16(0, c.key);
                            return;
                        }
                        // enhanced: discard and continue (the reg_ip idle loop)
                    }
                    // Empty ring: deterministic no-key (documented seam above).
                    cpu.st.setReg16(0, 0);
                },
                0x10 => { // GET KEYSTROKE, enhanced (keeps enhanced scancodes)
                    if (bda.kbDequeue()) |w| {
                        const c = classifyKey(w);
                        cpu.st.setReg16(0, enhancedReturnTransform(c.key));
                    } else {
                        cpu.st.setReg16(0, 0);
                    }
                },
                0x01 => { // CHECK KEYSTROKE (peek; discards enhanced keys)
                    while (bda.kbPeek()) |w| {
                        const c = classifyKey(w);
                        if (!c.enhanced) {
                            cpu.st.setReg16(0, c.key);
                            br.setGuestZF(false);
                            return;
                        }
                        // enhanced: remove from buffer and ignore it
                        _ = bda.kbDequeue();
                    }
                    // No key available: ZF=1, AX UNCHANGED (dosbox does not touch it).
                    br.setGuestZF(true);
                },
                0x11 => { // CHECK KEYSTROKE, enhanced (peek; keeps enhanced)
                    if (bda.kbPeek()) |w| {
                        const c = classifyKey(w);
                        cpu.st.setReg16(0, enhancedReturnTransform(c.key));
                        br.setGuestZF(false);
                    } else {
                        // No key available: ZF=1, AX UNCHANGED.
                        br.setGuestZF(true);
                    }
                },
                0x02 => { // GET SHIFT FLAGS -> AL = FLAGS1
                    cpu.st.setReg8(0, bda.kbShiftFlags());
                },
                else => bios.unsupported(cpu, br, 0x16),
            }
        }
    };
}
