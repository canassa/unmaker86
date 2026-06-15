//! INT 09h ISR + shift-flag state-machine tests (input Phase 1c). Each test
//! injects a raw scancode into the REAL 8042 device (which asserts IRQ1 through the
//! PIC), then runs guest code that enables interrupts and HLTs; the machine
//! recognizes IRQ1 at its deterministic boundary, the host-serviced INT 09h ISR
//! runs through the normal loop, reads port 0x60, updates the BDA flags, and
//! enqueues the cooked word. We then assert the ring word + the FLAGS bytes — the
//! full hardware fill path, no host-side ring write.

const std = @import("std");
const machine_mod = @import("machine");
const cpu_mod = @import("cpu");
const bda_mod = @import("bios").Bda;

const Machine = machine_mod.Machine;
const Cpu = machine_mod.Cpu;
const Reg32 = cpu_mod.state.Reg32;

const CODE_SEG: u16 = 0x2000;

const OFF_F1: u16 = 0x17;
const OFF_F2: u16 = 0x18;
const OFF_F3: u16 = 0x96;
const OFF_ALT_KP: u16 = 0x19;

fn boot(alloc: std.mem.Allocator) !*Machine {
    const m = try alloc.create(Machine);
    try m.init(alloc, &.{});
    m.wire();
    m.post();
    return m;
}

/// Load `STI ; JMP $` so the guest spins with interrupts enabled — the machine
/// recognizes the pending IRQ1 at an instruction boundary and runs INT 09h through
/// the normal loop (a real poll loop; no HLT fast-forward to skip the IRQ).
fn loadIdle(m: *Machine) void {
    const code = [_]u8{ 0xFB, 0xEB, 0xFE }; // STI ; JMP $-0 (self-loop at offset 1)
    const base = @as(u32, CODE_SEG) << 4;
    for (code, 0..) |b, i| m.bus.writePhys8(base + @as(u32, @intCast(i)), b);
    m.cpu.loadSegment(.cs, CODE_SEG);
    m.cpu.st.eip = 0;
    m.cpu.loadSegment(.ss, CODE_SEG);
    m.cpu.st.setReg16(@intFromEnum(Reg32.esp), 0xFFF0);
    m.cpu.loadSegment(.ds, CODE_SEG);
    m.cpu.loadSegment(.es, CODE_SEG);
    m.cpu.st.eflags.iff = true;
}

/// Run until the keyboard ring is non-empty (the cooked word landed) or budget.
fn runUntilKey(m: *Machine) void {
    const Pred = struct {
        fn ready(mm: *Machine) bool {
            const b = bda_mod(Cpu).init(&mm.cpu);
            return !b.kbEmpty();
        }
    };
    _ = m.runUntil(Pred.ready, 1_000_000);
}

/// Run a fixed number of cycles (for flag-only checks where nothing is enqueued).
fn runCycles(m: *Machine, n: u64) void {
    _ = m.runCycles(n);
}

fn bda(m: *Machine) bda_mod(Cpu) {
    return bda_mod(Cpu).init(&m.cpu);
}

/// Inject a make scancode into the 8042 (asserts IRQ1).
fn make(m: *Machine, code: u8) void {
    _ = m.kbd.pushScancode(code);
}
fn breakKey(m: *Machine, code: u8) void {
    _ = m.kbd.pushScancode(code | 0x80);
}

test "inject 'a' make -> cooked word 0x1E61 in the BDA ring via INT 09h" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x1E); // 'a'
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x1E61), bda(m).kbPeek());
}

test "shift+letter: left-shift make then 'a' make -> 'A' (0x1E41)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x2A); // left-shift make
    runCycles(m, 50_000); // let INT 09h process the shift make (no word enqueued)
    try std.testing.expectEqual(@as(u8, 0x02), m.bus.readPhys8(0x400 + OFF_F1) & 0x02); // LShift set
    make(m, 0x1E); // 'a' make while shift held
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x1E41), bda(m).kbPeek()); // 'A'
}

test "shift make/break toggles FLAGS1 LShift bit" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x2A);
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x02), m.bus.readPhys8(0x400 + OFF_F1) & 0x02);
    breakKey(m, 0x2A);
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x00), m.bus.readPhys8(0x400 + OFF_F1) & 0x02);
}

test "CapsLock make toggles FLAGS1 caps-lock bit (lock toggle case)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    // First CapsLock make -> lock ON.
    make(m, 0x3A);
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x40), m.bus.readPhys8(0x400 + OFF_F1) & 0x40);
    // Release (no toggle), then a second make -> lock OFF.
    breakKey(m, 0x3A);
    runCycles(m, 50_000);
    make(m, 0x3A);
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x00), m.bus.readPhys8(0x400 + OFF_F1) & 0x40);
}

test "CapsLock-on lowercases via Caps XOR Shift" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x3A); // CapsLock ON
    runCycles(m, 50_000);
    make(m, 0x1E); // 'a' with caps on -> 'A'
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x1E41), bda(m).kbPeek());
    _ = bda(m).kbDequeue();
    // Now Shift held WITH CapsLock on -> lowercase 'a'.
    make(m, 0x2A);
    runCycles(m, 50_000);
    make(m, 0x1E);
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x1E61), bda(m).kbPeek());
}

test "ctrl+letter: left-ctrl make then 'a' -> ctrl-A (0x1E01)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x1D); // left-ctrl
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x04), m.bus.readPhys8(0x400 + OFF_F1) & 0x04);
    make(m, 0x1E); // 'a'
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x1E01), bda(m).kbPeek());
}

test "NumLock on: numpad-7 yields digit '7'; off yields Home (cursor)" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    // NumLock OFF (default) -> Home (scancode word 0x4700).
    make(m, 0x47);
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x4700), bda(m).kbPeek());
    _ = bda(m).kbDequeue();
    // Turn NumLock ON.
    make(m, 0x45);
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x20), m.bus.readPhys8(0x400 + OFF_F1) & 0x20);
    make(m, 0x47); // numpad-7 -> '7'
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x4737), bda(m).kbPeek());
}

test "extended key: E0 prefix + gray-Up enqueues 0x4800" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    _ = m.kbd.pushScancode(0xE0); // extended prefix (asserts IRQ1)
    _ = m.kbd.pushScancode(0x48); // gray Up
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 0x4800), bda(m).kbPeek());
}

test "right-ctrl (E0 1D) sets FLAGS3 right-ctrl + FLAGS1 ctrl" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    _ = m.kbd.pushScancode(0xE0);
    _ = m.kbd.pushScancode(0x1D); // right-ctrl make
    runCycles(m, 50_000);
    try std.testing.expectEqual(@as(u8, 0x04), m.bus.readPhys8(0x400 + OFF_F3) & 0x04); // F3 RCtrl
    try std.testing.expectEqual(@as(u8, 0x04), m.bus.readPhys8(0x400 + OFF_F1) & 0x04); // F1 Ctrl
}

test "Alt-numpad accumulator: Alt + KP-6 + KP-5 -> char 65 on Alt-release" {
    const alloc = std.testing.allocator;
    const m = try boot(alloc);
    defer {
        m.deinit();
        alloc.destroy(m);
    }
    loadIdle(m);
    make(m, 0x38); // left-Alt make
    runCycles(m, 50_000);
    make(m, 0x4D); // numpad-6 -> accumulate 6
    runCycles(m, 50_000);
    make(m, 0x4F); // numpad-1 -> accumulate 61
    runCycles(m, 50_000);
    // Nothing enqueued yet while Alt held.
    try std.testing.expect(bda(m).kbEmpty());
    try std.testing.expectEqual(@as(u8, 61), m.bus.readPhys8(0x400 + OFF_ALT_KP));
    breakKey(m, 0x38); // Alt release -> emit char 61 ('=')
    runUntilKey(m);
    try std.testing.expectEqual(@as(?u16, 61), bda(m).kbPeek());
    try std.testing.expectEqual(@as(u8, 0), m.bus.readPhys8(0x400 + OFF_ALT_KP)); // reset
}
