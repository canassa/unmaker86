//! 8259 PIC unit tests (Phase 4): priority, masking, ICW1-clears-IMR,
//! specific/non-specific EOI, cascade (two independent EOIs), purity, the
//! re-resolving ackIrq (M-D14), and spurious-not-modeled.

const std = @import("std");
const devices = @import("devices");

const Pic = devices.Pic;

/// Program both controllers to the standard real-mode config directly (no bus):
/// master base 0x08, slave base 0x70, cascade on IRQ2, then a runtime mask.
fn programStandard(pic: *Pic) void {
    // Master.
    Pic.writeCommand(&pic.master, 0x11);
    Pic.writeData(&pic.master, 0x08);
    Pic.writeData(&pic.master, 0x04);
    Pic.writeData(&pic.master, 0x01);
    // Slave.
    Pic.writeCommand(&pic.slave, 0x11);
    Pic.writeData(&pic.slave, 0x70);
    Pic.writeData(&pic.slave, 0x02);
    Pic.writeData(&pic.slave, 0x01);
    // Unmask everything for the tests (OCW1 = 0).
    Pic.writeData(&pic.master, 0x00);
    Pic.writeData(&pic.slave, 0x00);
}

test "ICW1 clears IMR to 0" {
    var pic = Pic{};
    pic.master.imr = 0xFF;
    Pic.writeCommand(&pic.master, 0x11); // ICW1
    try std.testing.expectEqual(@as(u8, 0), pic.master.imr);
}

test "priority: higher-priority line wins; lower blocked until EOI" {
    var pic = Pic{};
    programStandard(&pic);
    pic.raiseIrq(1); // lower priority (line 1)
    pic.raiseIrq(0); // higher priority (line 0)
    // IRQ0 (vector 0x08) wins.
    try std.testing.expectEqual(@as(?u8, 0x08), pic.getPendingInterrupt());
    pic.ackIrq(0x08);
    // While IRQ0 is in service, the lower IRQ1 is blocked.
    try std.testing.expectEqual(@as(?u8, null), pic.getPendingInterrupt());
    // Non-specific EOI clears IRQ0; now IRQ1 surfaces.
    Pic.writeCommand(&pic.master, 0x20);
    try std.testing.expectEqual(@as(?u8, 0x09), pic.getPendingInterrupt());
}

test "masking: an IMR-masked line never surfaces; unmasking surfaces it" {
    var pic = Pic{};
    programStandard(&pic);
    Pic.writeData(&pic.master, 0x01); // mask IRQ0
    pic.raiseIrq(0);
    try std.testing.expectEqual(@as(?u8, null), pic.getPendingInterrupt());
    Pic.writeData(&pic.master, 0x00); // unmask
    try std.testing.expectEqual(@as(?u8, 0x08), pic.getPendingInterrupt());
}

test "specific EOI clears the named ISR bit" {
    var pic = Pic{};
    programStandard(&pic);
    pic.raiseIrq(3);
    try std.testing.expectEqual(@as(?u8, 0x0B), pic.getPendingInterrupt());
    pic.ackIrq(0x0B);
    try std.testing.expectEqual(@as(u8, 0x08), pic.master.isr); // bit 3 set
    Pic.writeCommand(&pic.master, 0x60 | 3); // specific EOI line 3
    try std.testing.expectEqual(@as(u8, 0), pic.master.isr);
}

test "non-specific EOI to an idle controller is a no-op" {
    var pic = Pic{};
    programStandard(&pic);
    Pic.writeCommand(&pic.master, 0x20); // EOI with nothing in service
    try std.testing.expectEqual(@as(u8, 0), pic.master.isr);
}

test "cascade: slave IRQ surfaces only when master IRQ2 unmasked; two EOIs clear both" {
    var pic = Pic{};
    programStandard(&pic);
    // Mask master IRQ2 (the cascade) -> the slave is dead.
    Pic.writeData(&pic.master, 0x04);
    pic.raiseIrq(12); // slave line 4 (IRQ12)
    try std.testing.expectEqual(@as(?u8, null), pic.getPendingInterrupt());
    // Unmask the cascade.
    Pic.writeData(&pic.master, 0x00);
    // Vector = slave_base(0x70) + 4 = 0x74.
    try std.testing.expectEqual(@as(?u8, 0x74), pic.getPendingInterrupt());
    pic.ackIrq(0x74);
    // ISR set on BOTH the slave (bit 4) and master IRQ2 (bit 2).
    try std.testing.expectEqual(@as(u8, 0x10), pic.slave.isr);
    try std.testing.expectEqual(@as(u8, 0x04), pic.master.isr);
    // Two INDEPENDENT EOIs (the guest ISR issues both).
    Pic.writeCommand(&pic.slave, 0x20); // EOI to slave
    try std.testing.expectEqual(@as(u8, 0), pic.slave.isr);
    try std.testing.expectEqual(@as(u8, 0x04), pic.master.isr); // master untouched
    Pic.writeCommand(&pic.master, 0x20); // EOI to master
    try std.testing.expectEqual(@as(u8, 0), pic.master.isr);
}

test "purity: getPendingInterrupt twice returns same vector, no mutation" {
    var pic = Pic{};
    programStandard(&pic);
    pic.raiseIrq(0);
    const irr_before = pic.master.irr;
    const isr_before = pic.master.isr;
    try std.testing.expectEqual(@as(?u8, 0x08), pic.getPendingInterrupt());
    try std.testing.expectEqual(@as(?u8, 0x08), pic.getPendingInterrupt());
    try std.testing.expectEqual(irr_before, pic.master.irr);
    try std.testing.expectEqual(isr_before, pic.master.isr);
}

test "ackIrq re-resolves with non-default vector bases (no reverse-map)" {
    var pic = Pic{};
    // Non-default master base 0x20.
    Pic.writeCommand(&pic.master, 0x11);
    Pic.writeData(&pic.master, 0x20);
    Pic.writeData(&pic.master, 0x04);
    Pic.writeData(&pic.master, 0x01);
    Pic.writeData(&pic.master, 0x00); // unmask all
    pic.raiseIrq(5);
    // Vector = 0x20 + 5 = 0x25.
    try std.testing.expectEqual(@as(?u8, 0x25), pic.getPendingInterrupt());
    pic.ackIrq(0x25); // re-resolves line 5 -> ISR bit 5
    try std.testing.expectEqual(@as(u8, 0x20), pic.master.isr);
}

test "spurious not modeled: nothing pending -> null" {
    var pic = Pic{};
    programStandard(&pic);
    try std.testing.expectEqual(@as(?u8, null), pic.getPendingInterrupt());
}

test "IRR/ISR/IMR read-back per OCW3" {
    var pic = Pic{};
    programStandard(&pic);
    pic.raiseIrq(0);
    // Default read select = IRR.
    try std.testing.expectEqual(@as(u8, 0x01), pic.readPort(0x20));
    // OCW3 select ISR.
    Pic.writeCommand(&pic.master, 0x0B); // OCW3 RR=1 RIS=1
    pic.ackIrq(0x08);
    try std.testing.expectEqual(@as(u8, 0x01), pic.readPort(0x20)); // ISR bit 0
    // Data port returns IMR.
    Pic.writeData(&pic.master, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), pic.readPort(0x21));
}
