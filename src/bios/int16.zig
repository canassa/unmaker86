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
//! HYBRID DISPATCH (input-injection.md §4.1, Phase 1d). INT 16h is split: the
//! BLOCKING reads **AH=00 (GET) and AH=10 (enhanced GET)** are served by the
//! guest-asm poll loop installed via `Bridge.emitInt16Hybrid` (STI; has-key trap;
//! JNZ; INT 09h; JMP back; dequeue trap; IRET), so a program that blocks on an
//! empty ring unblocks deterministically when a scancode + IRQ1 is injected — the
//! loop is REAL guest code through the normal fetch/execute loop, so emulated time
//! ADVANCES during the wait (IRQ0/INT 1Ch tick; the injected IRQ1→INT 09h delivers
//! the key), charged cycle-for-cycle with NO ledger hole and NO host clock. The two
//! poll-loop callbacks are `hasKey`/`dequeue` below; they read AH (live, preserved
//! through the loop) to apply the SAME enhanced-vs-non-enhanced folding the
//! host AH=00 vs AH=10 paths did. **AH=01/02/05/11/12 (and any other AH) fall
//! through to `handle` below** (the host path). This DELETES the old empty-ring
//! "return AX=0 immediately" seam: AH=00 now blocks faithfully via the guest loop.

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
        const Bda = bda_mod.Bda(Cpu);

        /// The HOST path of the INT 16h hybrid (input-injection.md §4.1). Reached
        /// ONLY for AH=01/02/05/11/12 and any other AH — the blocking AH=00/10 are
        /// served by the guest-asm poll loop (`hasKey`/`dequeue` below). AH=00/10
        /// reaching here would mean the hybrid preamble mis-branched; route them to
        /// the structural-signal path rather than silently faking a result.
        pub fn handle(bios: anytype, cpu: *Cpu, br: anytype) void {
            const ah = cpu.st.getReg8(4);
            const bda = Bda.init(cpu);
            switch (ah) {
                0x01 => { // CHECK KEYSTROKE (peek; discards enhanced keys)
                    // Force IF on the IRET so a guest tight-poll (`AH=01; JZ poll`)
                    // keeps interrupts enabled and an injected IRQ1 can be recognized
                    // mid-loop (dosbox bios_keyboard.cpp:555-556 CALLBACK_SIF(true)).
                    br.setGuestIF(true);
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

        /// Poll-loop HAS-KEY callback (`Bridge.emitPollLoop` has_key_id). Sets the
        /// LIVE Zero Flag (`cpu.st.eflags.zf`) so the loop's following `JNZ` (a real
        /// guest instruction) branches: ZF=0 ⇒ a key is ready ⇒ jump to dequeue;
        /// ZF=1 ⇒ ring empty ⇒ run INT 09h and spin. It is an INLINE trap (NOT an
        /// interrupt — `0xFE 0x38 <id>` pushes no FLAGS frame), so it patches the
        /// live flag, not an IRET image. AH is preserved through the loop, so this
        /// reads it to apply the SAME fold the host AH=00 vs AH=10 paths did:
        ///   AH=00: skip (discard) leading enhanced keys, then ZF=0 iff a NORMAL
        ///          key is at head — matching `handle` AH=01's peek-and-discard.
        ///   AH=10: ZF=0 iff the ring is non-empty (enhanced keys count).
        /// It must NOT touch AX (the dequeue callback sets it).
        pub fn hasKey(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            const bda = Bda.init(cpu);
            const enhanced_mode = cpu.st.getReg8(4) == 0x10; // AH
            if (enhanced_mode) {
                cpu.st.eflags.zf = bda.kbEmpty();
                return;
            }
            // AH=00 fold: discard leading enhanced keys (the reg_ip idle loop), then
            // report "key ready" iff a normal key remains at head.
            while (bda.kbPeek()) |w| {
                if (!classifyKey(w).enhanced) {
                    cpu.st.eflags.zf = false; // a normal key is ready
                    return;
                }
                _ = bda.kbDequeue(); // drop the enhanced key, keep scanning
            }
            cpu.st.eflags.zf = true; // ring empty (of normal keys)
        }

        /// Poll-loop DEQUEUE callback (`Bridge.emitPollLoop` dequeue_id). Pops the
        /// head word into AX, applying the AH-mode fold (AH preserved through the
        /// loop). Only reached when `hasKey` reported ZF=0 (a key is ready), so the
        /// dequeue always succeeds; the empty branch is defensive.
        ///   AH=00: dequeue skipping enhanced keys, AX = the normal key (folded).
        ///   AH=10: dequeue one word, AX = enhanced-return-transform(word).
        pub fn dequeue(bios: anytype, cpu: *Cpu, br: anytype) void {
            _ = bios;
            _ = br;
            const bda = Bda.init(cpu);
            const enhanced_mode = cpu.st.getReg8(4) == 0x10; // AH
            if (enhanced_mode) {
                if (bda.kbDequeue()) |w| {
                    cpu.st.setReg16(0, enhancedReturnTransform(classifyKey(w).key));
                } else {
                    cpu.st.setReg16(0, 0); // defensive: hasKey gated this
                }
                return;
            }
            while (bda.kbDequeue()) |w| {
                const c = classifyKey(w);
                if (!c.enhanced) {
                    cpu.st.setReg16(0, c.key);
                    return;
                }
                // enhanced: discard and continue
            }
            cpu.st.setReg16(0, 0); // defensive: hasKey gated this
        }
    };
}
