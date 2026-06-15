//! The zdos BIOS (D12): IVT/BDA/POST stand-in + the BIOS INT handlers (INT 10h/
//! 16h/1Ah/08h/11h/12h, plus the deferred-by-default INT 13h/15h flag paths). It
//! is a host-serviced module: a guest `INT 10h` traps to a host Zig handler that
//! reads/writes guest regs + memory and charges a deterministic synthetic cost
//! (D5). It imports the shared bridge leaf; it does NOT import `dos` (D12).
//!
//! The POST (M-D9 replacement) programs the PIC/PIT/A20 with the SAME port writes
//! the real BIOS would (the devices process them normally — no special-casing,
//! ground rule), lands a documented IVT + BDA, and plants the BIOS callback stubs.

const std = @import("std");
const bridge_mod = @import("bridge");
const bda_mod = @import("bda.zig");

pub const Bda = bda_mod.Bda;
/// Scancode set-1 + BIOS-keycode tables (input Phase 1b). Re-exported so the API
/// layer can resolve the `{"char"}` convenience over the REAL table (§5.1e).
pub const scancodes = @import("scancodes.zig");

/// The set of BIOS INTs zdos services. Each maps to one callback id; the handler
/// switches on AH (the IndexBasedDispatcher shape, D7).
pub const BiosInt = enum {
    int08, // IRQ0 timer tick
    int09, // IRQ1 keyboard
    int10, // video
    int11, // equipment list
    int12, // conventional memory size
    int13, // disk (deferred-by-default, D11)
    int15, // system services
    int16, // keyboard
    int1a, // time of day
    int1c, // user timer tick (default IRET stub)
    unhandled, // catch-all for unserviced hardware/unused vectors
};

/// Build the BIOS type for a given comptime `Cpu`. Generic so the handler path
/// inlines and no concrete type is named in any shared leaf.
pub fn Bios(comptime Cpu: type) type {
    const Bridge = bridge_mod.Bridge(Cpu);
    const int10 = @import("int10.zig").Int10(Cpu);
    const int16 = @import("int16.zig").Int16(Cpu);
    const int1a = @import("int1a.zig").Int1a(Cpu);
    const int08 = @import("int08.zig").Int08(Cpu);
    const int09 = @import("int09.zig").Int09(Cpu);
    const int1112 = @import("int11_12.zig").Int1112(Cpu);
    const int15 = @import("int15.zig").Int15(Cpu);

    return struct {
        const Self = @This();
        pub const CpuType = Cpu;

        cpu: *Cpu = undefined,
        /// callback id for each serviced BIOS INT (assigned at registration).
        ids: std.enums.EnumArray(BiosInt, u8) = .initFill(0xFF),

        pub fn init(self: *Self, cpu: *Cpu) void {
            self.cpu = cpu;
            self.ids = .initFill(0xFF);
        }

        pub fn bda(self: *Self) Bda(Cpu) {
            return Bda(Cpu).init(self.cpu);
        }

        /// Allocate + record one callback id for `which` and tell the sink this id
        /// is BIOS-owned. `setOwner` is a closure over the machine's Services.
        pub fn registerCallbacks(
            self: *Self,
            br: *Bridge,
            ctx: *anyopaque,
            setOwner: *const fn (*anyopaque, u8) void,
        ) void {
            inline for (.{
                .{ BiosInt.int08, bridge_mod.CbType.iret_eoi_pic1 },
                .{ BiosInt.int09, bridge_mod.CbType.iret_eoi_pic1 },
                .{ BiosInt.int10, bridge_mod.CbType.iret },
                .{ BiosInt.int11, bridge_mod.CbType.iret },
                .{ BiosInt.int12, bridge_mod.CbType.iret },
                .{ BiosInt.int13, bridge_mod.CbType.iret },
                .{ BiosInt.int15, bridge_mod.CbType.iret },
                .{ BiosInt.int16, bridge_mod.CbType.iret },
                .{ BiosInt.int1a, bridge_mod.CbType.iret },
                .{ BiosInt.int1c, bridge_mod.CbType.iret },
                .{ BiosInt.unhandled, bridge_mod.CbType.iret },
            }) |pair| {
                const kind: bridge_mod.Kind = switch (pair[0]) {
                    .int08, .int09, .int1c => .irq,
                    .int13 => .unsupported,
                    else => .dispatch,
                };
                const id = br.allocCallback(pair[1], kind);
                self.ids.set(pair[0], id);
                setOwner(ctx, id);
            }
        }

        fn which(self: *Self, id: u8) BiosInt {
            var it = self.ids.iterator();
            while (it.next()) |e| {
                if (e.value.* == id) return e.key;
            }
            return .unhandled;
        }

        /// The CallbackSink routes BIOS-owned ids here. Switch id -> INT, then the
        /// per-INT handler switches on AH (D7). The synthetic base cost is already
        /// charged by the sink; byte-proportional services add their own.
        pub fn dispatch(self: *Self, id: u8, cpu: *Cpu, br: *Bridge) void {
            switch (self.which(id)) {
                .int08 => int08.handle(self, cpu, br),
                .int09 => int09.handle(self, cpu, br),
                .int10 => int10.handle(self, cpu, br),
                .int11 => int1112.handle11(self, cpu, br),
                .int12 => int1112.handle12(self, cpu, br),
                .int13 => self.unsupported(cpu, br, 0x13),
                .int15 => int15.handle(self, cpu, br),
                .int16 => int16.handle(self, cpu, br),
                .int1a => int1a.handle(self, cpu, br),
                .int1c => {}, // default user-timer-tick stub: IRET (do nothing)
                .unhandled => self.unsupportedVec(cpu, br),
            }
        }

        /// D11: an unsupported BIOS service. Surface the structural signal; do not
        /// fabricate a result. (For BIOS we leave registers as-is and clear CF —
        /// a faithful "no-op" for an unhandled service; the honest signal is the
        /// out-of-band record.) `last_unsupported` is the structural record.
        pub var last_unsupported: ?Unsupported = null;
        pub const Unsupported = struct { int: u8, ah: u8, al: u8 };

        pub fn unsupported(self: *Self, cpu: *Cpu, br: *Bridge, int: u8) void {
            _ = self;
            last_unsupported = .{
                .int = int,
                .ah = cpu.st.getReg8(4),
                .al = cpu.st.getReg8(0),
            };
            br.setGuestCF(false);
        }

        fn unsupportedVec(self: *Self, cpu: *Cpu, br: *Bridge) void {
            // A truly unused/unhandled vector reached its default stub.
            self.unsupported(cpu, br, 0xFF);
        }

        // -------------------------------------------------------------------
        // POST (Phase 2): program PIC/PIT/A20 + IVT + BDA + plant stubs.
        // -------------------------------------------------------------------

        /// Run the BIOS POST. `image` is the BIOS ROM image the bridge planted
        /// stubs into; this points the serviced IVT vectors at those stubs. The
        /// machine has already loaded `image` via bus.loadRom before calling POST,
        /// OR POST is called before loadRom and the machine loads after — the
        /// machine documents the order. Here we only touch guest RAM (IVT/BDA) +
        /// ports; stub bytes were planted by the bridge.
        pub fn post(self: *Self, br: *Bridge) void {
            self.programPic();
            self.programTimer();
            self.cpu.bus.setA20(true);
            self.initIvt(br);
            self.bda().initDefaults();
        }

        /// Program the 8259 master+slave to the standard real-mode config (the
        /// SAME writes the real BIOS issues; M-D9). Master INT 08h-0Fh, slave INT
        /// 70h-77h, cascade on IRQ2, unmask IRQ0/1/2.
        fn programPic(self: *Self) void {
            const b = self.cpu.bus;
            b.portOut8(0x20, 0x11);
            b.portOut8(0x21, 0x08);
            b.portOut8(0x21, 0x04);
            b.portOut8(0x21, 0x01);
            b.portOut8(0xA0, 0x11);
            b.portOut8(0xA1, 0x70);
            b.portOut8(0xA1, 0x02);
            b.portOut8(0xA1, 0x01);
            b.portOut8(0x21, 0xF8); // unmask IRQ0,1,2
            b.portOut8(0xA1, 0xFF);
        }

        /// Program PIT ch0 mode 3 reload 0 (~18.2 Hz IRQ0).
        fn programTimer(self: *Self) void {
            const b = self.cpu.bus;
            b.portOut8(0x43, 0x36);
            b.portOut8(0x40, 0x00);
            b.portOut8(0x40, 0x00);
        }

        /// Fill the IVT (D11): every vector -> the unhandled-default stub; then
        /// point the serviced vectors at their own stubs. INT 1Ch defaults to its
        /// own (IRET) stub the guest may hook.
        fn initIvt(self: *Self, br: *Bridge) void {
            const unhandled_id = self.ids.get(.unhandled);
            var v: u16 = 0;
            while (v < 256) : (v += 1) {
                br.setRealVec(unhandled_id, @intCast(v));
            }
            // Serviced vectors.
            br.setRealVec(self.ids.get(.int08), 0x08);
            // INT 09h is guest-overridable: a guest may install its own keyboard
            // ISR by writing IVT[9] (AH=25h), which then takes over (§4.0 / §5.1).
            br.setRealVec(self.ids.get(.int09), 0x09);
            br.setRealVec(self.ids.get(.int10), 0x10);
            br.setRealVec(self.ids.get(.int11), 0x11);
            br.setRealVec(self.ids.get(.int12), 0x12);
            br.setRealVec(self.ids.get(.int13), 0x13);
            br.setRealVec(self.ids.get(.int15), 0x15);
            br.setRealVec(self.ids.get(.int16), 0x16);
            br.setRealVec(self.ids.get(.int1a), 0x1A);
            br.setRealVec(self.ids.get(.int1c), 0x1C);
        }
    };
}
