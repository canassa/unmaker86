//! Machine unit tests (Phase 0/1/3/6): smoke/reset state, two-reset determinism,
//! the HLT fast-forward, halted_forever, the armed-but-unwakeable periodic case,
//! and the snapshot round-trip.

const std = @import("std");
const machine = @import("machine");
const cpu_mod = @import("cpu");
const timing = @import("timing");

const Machine = machine.Machine;
const StopReason = machine.StopReason;
const Seg = cpu_mod.Seg;
const Reg32 = cpu_mod.state.Reg32;

fn msToCycles(ms: u64) u64 {
    return ms * timing.CPU_CLOCK_HZ / 1000;
}

/// Mirror the Controller's `injectScancode` at the machine layer (push the byte(s)
/// then drive the typematic edge), without pulling in the debug controller.
fn injectKey(m: *Machine, scancode: u8, make: bool, ext: bool) void {
    const code = if (make) scancode else scancode | 0x80;
    if (ext) {
        _ = m.kbd.pushScancode(0xE0);
    }
    _ = m.kbd.pushScancode(code);
    m.kbd.noteEdge(scancode, make, ext);
}

/// Advance the cycle ledger to each due keyboard event and fire it (mirrors the
/// HLT fast-forward + `fireDue`), counting how many `kbd_repeat` events fire while
/// `nextEventCycle <= until_cycle`. Drives the REAL scheduler + KBD_SOURCE_ID +
/// `fireDue` dispatch + `onRepeatFire` reschedule path.
fn fireKbdReptsUntil(m: *Machine, until_cycle: u64) u32 {
    var fired: u32 = 0;
    while (true) {
        const next = m.nextEventCycle();
        if (next > until_cycle) break;
        m.cpu.st.cycles = next;
        const before = m.kbd.fifo_count;
        m.fireDue();
        if (m.kbd.fifo_count > before) fired += 1; // a repeat pushed a byte
    }
    m.cpu.st.cycles = until_cycle;
    return fired;
}

fn makeMachine(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    return m;
}

/// Compare two CPU States byte-for-byte (the GenReg32 union can't be deep-compared
/// by std.testing, but the whole State is plain serializable bytes — CLAUDE #6).
fn expectStateEqual(a: cpu_mod.State, b: cpu_mod.State) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

test "smoke: init+wire lands 386 power-on; A20 off; PIC/PIT/scheduler at reset" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    try std.testing.expectEqual(@as(u32, 0xFFF0), m.cpu.st.eip);
    try std.testing.expectEqual(@as(u16, 0xF000), m.cpu.readSegSelector(.cs));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), m.cpu.st.seg_base[@intFromEnum(Seg.cs)]);
    try std.testing.expect(!m.bus.a20Enabled());
    try std.testing.expectEqual(@as(u8, 0xFF), m.pic.master.imr);
    try std.testing.expectEqual(@as(u8, 0xFF), m.pic.slave.imr);
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle());
    try std.testing.expect(!m.shutdown);
}

test "two resets are byte-identical (CPU state + PIC + PIT + scheduler)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Dirty the machine: program devices, dirty RAM.
    m.programDefaultPic();
    m.programDefaultTimer();
    m.bus.writePhys8(0x500, 0xAB);
    m.cpu.writeReg32(.eax, 0xDEAD);

    m.reset();
    const a = m.snapshot();
    m.reset();
    const b = m.snapshot();
    try expectStateEqual(a.cpu_state, b.cpu_state);
    try std.testing.expectEqualDeep(a.pic, b.pic);
    try std.testing.expectEqualDeep(a.pit, b.pit);
    try std.testing.expectEqualDeep(a.sched, b.sched);
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8(0x500)); // RAM re-zeroed
}

test "no-interrupt program runs to a target cycle (.cycles_reached)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // Real-mode flat program at 0:0x0500 — a tight loop (JMP $).
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    // EB FE = JMP $ (infinite loop, no HLT, no interrupt).
    m.bus.writePhys8(0x0500, 0xEB);
    m.bus.writePhys8(0x0501, 0xFE);
    const r = m.runCycles(100);
    try std.testing.expectEqual(StopReason.cycles_reached, r);
    try std.testing.expect(m.cpu.st.cycles >= 100);
}

test "HLT with no events and IF=0 -> halted_forever (deterministic, not a spin)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.cpu.st.eflags.iff = false; // interrupts disabled
    m.bus.writePhys8(0x0500, 0xF4); // HLT
    const r = m.runCycles(10_000);
    try std.testing.expectEqual(StopReason.halted_forever, r);
}

test "HLT fast-forward: STI;HLT jumps cpu.st.cycles to the next event cycle" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    // Program ch0 to a short period so the event is at a known cycle.
    m.bus.portOut8(0x43, 0x34); // ch0 mode 2 lohi
    m.bus.portOut8(0x40, 0x0A); // reload 10
    m.bus.portOut8(0x40, 0x00);
    // The event was armed at cycle 0 (the OUT writes happen before stepping but
    // the PIT reads cpu.st.cycles which is 0 here): fire_cycle = 10*12 = 120.
    const event_cycle = m.nextEventCycle();
    try std.testing.expectEqual(@as(u64, 120), event_cycle);

    // STI; HLT at 0:0x0500.
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.bus.writePhys8(0x0500, 0xFB); // STI
    m.bus.writePhys8(0x0501, 0xF4); // HLT
    // Mask IRQ0 so the IRQ doesn't get delivered (no IVT set up) — we only test
    // that the fast-forward lands cpu.st.cycles at the event cycle.
    m.bus.portOut8(0x21, 0x01); // mask IRQ0
    // Run a bounded budget past the event; the HLT fast-forwards to event_cycle.
    _ = m.runCycles(1000);
    try std.testing.expect(m.cpu.st.cycles >= event_cycle);
}

test "armed-but-unwakeable periodic: masked IRQ0, IF=0, HLT -> cycles_reached" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    m.bus.portOut8(0x21, 0x01); // mask IRQ0
    m.bus.portOut8(0x43, 0x34); // ch0 mode 2
    m.bus.portOut8(0x40, 0x0A);
    m.bus.portOut8(0x40, 0x00); // periodic event armed
    m.cpu.loadSegment(.cs, 0);
    m.cpu.st.eip = 0x0500;
    m.cpu.st.eflags.iff = false; // everything masked / IF=0
    m.bus.writePhys8(0x0500, 0xF4); // HLT
    const r = m.runCycles(5000);
    // Periodic events keep coming but never wake the CPU -> bounded cycles_reached.
    try std.testing.expectEqual(StopReason.cycles_reached, r);
    try std.testing.expect(m.cpu.st.cycles >= 5000);
}

test "snapshot round-trip of a populated machine restores identically" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.programDefaultPic();
    m.programDefaultTimer();
    m.pic.raiseIrq(1);
    m.bus.writePhys8(0x1234, 0x77);
    const snap = m.snapshot();
    const ram_copy = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ram_copy);

    // Restore into a fresh, re-wired machine.
    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    m2.restore(snap);
    @memcpy(m2.bus.ram, ram_copy);

    const s2 = m2.snapshot();
    try expectStateEqual(snap.cpu_state, s2.cpu_state);
    try std.testing.expectEqualDeep(snap.pic, s2.pic);
    try std.testing.expectEqualDeep(snap.pit, s2.pit);
    try std.testing.expectEqualDeep(snap.sched, s2.sched);
    try std.testing.expectEqual(@as(u8, 0x77), m2.bus.readPhys8(0x1234));
}

// ---------------------------------------------------------------------------
// Text-mode video pages (B8000 color / B0000 mono) — P1/P2. Before this work
// the UMA B-window defaulted to `.unmapped`, so a write to B800:0000 was
// silently dropped and a read returned the 0x00 fill. Now both windows are
// permanently mapped RAM-like MMIO (machine.wire), so a direct write round-trips.
// ---------------------------------------------------------------------------

test "text page: direct write to B800:0000 and B000:0000 reads back (was dropped before)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    // Color text page (B800:0000) — a flat {char,attr} cell.
    m.bus.writePhys8(0xB8000, 'A');
    m.bus.writePhys8(0xB8001, 0x1F);
    try std.testing.expectEqual(@as(u8, 'A'), m.bus.readPhys8(0xB8000));
    try std.testing.expectEqual(@as(u8, 0x1F), m.bus.readPhys8(0xB8001));
    // The byte landed in the device slab (the host-pointer fast path), not RAM.
    try std.testing.expectEqual(@as(u8, 'A'), m.vga.text_vram[0]);

    // The far end of the color 32 KiB window (B8000..BFFFF) is reachable too.
    m.bus.writePhys8(0xBFFFF, 0x7E);
    try std.testing.expectEqual(@as(u8, 0x7E), m.bus.readPhys8(0xBFFFF));
    try std.testing.expectEqual(@as(u8, 0x7E), m.vga.text_vram[0x7FFF]);

    // Mono text page (B000:0000..B7FFF).
    m.bus.writePhys8(0xB0000, 'M');
    try std.testing.expectEqual(@as(u8, 'M'), m.bus.readPhys8(0xB0000));
    try std.testing.expectEqual(@as(u8, 'M'), m.vga.text_vram_mono[0]);
    m.bus.writePhys8(0xB7FFF, 0x3C);
    try std.testing.expectEqual(@as(u8, 0x3C), m.vga.text_vram_mono[0x7FFF]);

    // The debugger peek path (side-effect-free) sees the same bytes.
    var buf: [2]u8 = undefined;
    m.bus.peekBlock(0xB8000, &buf);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x1F), buf[1]);
}

test "text page: caller-copy snapshot round-trip (NOT a Snapshot struct field)" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }

    // Dirty both text pages.
    m.bus.writePhys8(0xB8000, 'Z');
    m.bus.writePhys8(0xB8001, 0x4E);
    m.bus.writePhys8(0xB0000, 'Q');

    // Snapshot: the large text slabs are copied OUT-OF-BAND by the caller (the
    // same discipline as `vram`/`bus.ram`), never via a Snapshot struct field.
    const snap = m.snapshot();
    const ram_copy = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ram_copy);
    const vram_copy = try alloc.dupe(u8, m.vga.vram);
    defer alloc.free(vram_copy);
    const text_copy = try alloc.dupe(u8, m.vga.text_vram);
    defer alloc.free(text_copy);
    const text_mono_copy = try alloc.dupe(u8, m.vga.text_vram_mono);
    defer alloc.free(text_mono_copy);

    // Mutate after the snapshot.
    m.bus.writePhys8(0xB8000, '!');
    m.bus.writePhys8(0xB0000, '?');

    // Restore into a fresh, re-wired machine (wire() re-maps the slabs → bus).
    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    m2.restore(snap);
    @memcpy(m2.bus.ram, ram_copy);
    @memcpy(m2.vga.vram, vram_copy);
    @memcpy(m2.vga.text_vram, text_copy);
    @memcpy(m2.vga.text_vram_mono, text_mono_copy);

    // Byte-identical text pages, readable through the re-established mapping.
    try std.testing.expectEqualSlices(u8, text_copy, m2.vga.text_vram);
    try std.testing.expectEqualSlices(u8, text_mono_copy, m2.vga.text_vram_mono);
    try std.testing.expectEqual(@as(u8, 'Z'), m2.bus.readPhys8(0xB8000));
    try std.testing.expectEqual(@as(u8, 0x4E), m2.bus.readPhys8(0xB8001));
    try std.testing.expectEqual(@as(u8, 'Q'), m2.bus.readPhys8(0xB0000));
}

// Krondor milestone Stage 1 (S1.2): the resident "EMMXXXX0" EMM device-driver
// header is staged so the INT 67h vector's segment carries the presence
// signature at offset 0x0A. BaK's `ems_detect_driver` does INT 21h AH=35h to get
// the INT 67h vector, then compares [vector_segment:0x0A] to "EMMXXXX0"; only on
// a match does it issue any INT 67h subfunction. Before this, [F000:000A] read
// zeros → detection bailed → EMS reported 0 free pages → the boot memory gate
// aborted.
test "EMS driver signature: INT 67h vector segment + 0x0A reads EMMXXXX0" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.post();

    // The standard EMS-driver-header name field the presence probe matches
    // (the load-bearing magic literal BaK's `ems_detect_driver` compares).
    const sig = [8]u8{ 'E', 'M', 'M', 'X', 'X', 'X', 'X', '0' };

    // (1) Read the INT 67h vector from the live guest-RAM IVT (the SAME table
    //     AH=35h returns): IVT[0x67] at phys 0x67*4 = {off:u16, seg:u16}.
    const vec_off = m.bus.readPhys16(0x67 * 4);
    const vec_seg = m.bus.readPhys16(0x67 * 4 + 2);
    // The vector points at the EMS trap stub in the BIOS callback segment.
    try std.testing.expectEqual(@as(u16, 0xF000), vec_seg);

    // (2) [vector_segment:0x0A .. +8] must read the signature — exactly the bytes
    //     the probe compares. This is the load-bearing assertion.
    const name_phys: u32 = (@as(u32, vec_seg) << 4) + 0x0A;
    var got: [8]u8 = undefined;
    for (&got, 0..) |*b, i| b.* = m.bus.readPhys8(name_phys + @as(u32, @intCast(i)));
    try std.testing.expectEqualSlices(u8, &sig, &got);

    // (3) Sanity on the header framing: a real char-device header at the segment
    //     base — next-ptr FFFF:FFFF, attribute word bit15 (char device) set.
    const seg_base: u32 = @as(u32, vec_seg) << 4;
    try std.testing.expectEqual(@as(u16, 0xFFFF), m.bus.readPhys16(seg_base + 0));
    try std.testing.expectEqual(@as(u16, 0xFFFF), m.bus.readPhys16(seg_base + 2));
    try std.testing.expect((m.bus.readPhys16(seg_base + 4) & 0x8000) != 0);

    // (4) The vector's entry offset must still resolve to the EMS trap stub
    //     (0xFE 0x38 <id>) — staging the header must NOT break EMS dispatch.
    const entry_phys: u32 = seg_base + vec_off;
    try std.testing.expectEqual(@as(u8, 0xFE), m.bus.readPhys8(entry_phys));
    try std.testing.expectEqual(@as(u8, 0x38), m.bus.readPhys8(entry_phys + 1));
}

// ===========================================================================
// Keyboard typematic auto-repeat (integration: the REAL scheduler + KBD_SOURCE_ID
// + fireDue dispatch + onRepeatFire reschedule).
// ===========================================================================

test "typematic KEYSTONE: no key held ⇒ no scheduled event ⇒ identical to today" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    // No keyboard make ever injected: the scheduler stays empty (no kbd_repeat).
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle());
    // A tap (make+break) must leave NO live event either.
    injectKey(m, 0x1E, true, false);
    try std.testing.expect(m.nextEventCycle() != std.math.maxInt(u64)); // armed while held
    injectKey(m, 0x1E, false, false);
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle()); // released
}

test "typematic BaK: a held key yields cycle-exact repeated scancodes" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.st.cycles = 0;
    // Hold 'a' (make, no break). Default cadence: 500 ms delay, 33 ms period.
    injectKey(m, 0x1E, true, false);
    // The first repeat fires at delay; subsequent at delay + k*period. Over a span
    // covering the delay + 5 periods, exactly 6 repeats fire (k=0..5).
    const span = msToCycles(500) + 5 * msToCycles(33);
    const fired = fireKbdReptsUntil(m, span);
    try std.testing.expectEqual(@as(u32, 6), fired);
    // The next repeat is scheduled exactly one period past the last fire.
    try std.testing.expectEqual(msToCycles(500) + 6 * msToCycles(33), m.nextEventCycle());
}

test "typematic Stunts: extra makes are idempotent; break ends the hold" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.st.cycles = 0;
    injectKey(m, 0x48, true, true); // up-arrow make (extended)
    const first = m.nextEventCycle();
    // A redundant make of the SAME key restarts the delay (last-key-wins) but keeps
    // exactly one live event — never an assert (cancel-then-schedule).
    m.cpu.st.cycles = 50;
    injectKey(m, 0x48, true, true);
    try std.testing.expectEqual(@as(u64, 50 + msToCycles(500)), m.nextEventCycle());
    try std.testing.expect(m.nextEventCycle() != first);
    // The break ends the hold: no live event remains.
    injectKey(m, 0x48, false, true);
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle());
}

test "typematic last-key-wins: a second make redirects; the first does not resume" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.st.cycles = 0;
    injectKey(m, 0x1E, true, false); // 'a' held
    injectKey(m, 0x30, true, false); // 'b' make redirects the repeat
    // Drain the two make bytes already in the FIFO.
    try std.testing.expectEqual(@as(u8, 0x1E), m.bus.portIn8(0x60));
    try std.testing.expectEqual(@as(u8, 0x30), m.bus.portIn8(0x60));
    // Fire one repeat: it must be 'b' (0x30), not 'a'.
    _ = fireKbdReptsUntil(m, msToCycles(500));
    try std.testing.expectEqual(@as(u8, 0x30), m.bus.portIn8(0x60));
    // Releasing 'b' stops everything; 'a' does NOT resume.
    injectKey(m, 0x30, false, false);
    try std.testing.expectEqual(std.math.maxInt(u64), m.nextEventCycle());
}

test "typematic determinism: two runs of the same script are byte-identical" {
    const alloc = std.testing.allocator;
    const run = struct {
        fn go(a: std.mem.Allocator) !Machine.Snapshot {
            const m = try makeMachine(a);
            defer {
                m.deinit();
                a.destroy(m);
            }
            m.cpu.st.cycles = 0;
            injectKey(m, 0x48, true, true); // hold up-arrow at cycle 0
            _ = fireKbdReptsUntil(m, msToCycles(500) + 10 * msToCycles(33));
            return m.snapshot();
        }
    };
    const a = try run.go(alloc);
    const b = try run.go(alloc);
    try expectStateEqual(a.cpu_state, b.cpu_state);
    try std.testing.expectEqualDeep(a.sched, b.sched);
    try std.testing.expectEqualDeep(a.kbd, b.kbd);
}

test "typematic snapshot: arm mid-delay, restore, continue → same cadence" {
    const alloc = std.testing.allocator;
    const m = try makeMachine(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    m.cpu.st.cycles = 0;
    injectKey(m, 0x1E, true, false); // arm; first repeat at 500 ms
    // Snapshot mid-delay (no repeat has fired yet).
    m.cpu.st.cycles = msToCycles(100);
    const snap = m.snapshot();
    const ram_copy = try alloc.dupe(u8, m.bus.ram);
    defer alloc.free(ram_copy);

    const m2 = try makeMachine(alloc);
    defer {
        m2.deinit();
        alloc.destroy(m2);
    }
    m2.restore(snap);
    @memcpy(m2.bus.ram, ram_copy);

    // The live repeat event rode the scheduler snapshot: same fire cycle, same code.
    try std.testing.expectEqual(msToCycles(500), m2.nextEventCycle());
    try std.testing.expectEqual(@as(u8, 0x1E), m2.kbd.repeat_code.?.scancode);
    // Continue: the resumed cadence fires repeats at the same period.
    const fired = fireKbdReptsUntil(m2, msToCycles(500) + 3 * msToCycles(33));
    try std.testing.expectEqual(@as(u32, 4), fired); // delay + 3 periods (k=0..3)
}
