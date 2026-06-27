//! The 8259A Programmable Interrupt Controller — master + slave cascade (IRQ0-15,
//! the slave wired on master IRQ2). Implements BOTH:
//!   - the bus-side `PortHandler` (ports 0x20/0x21 master, 0xA0/0xA1 slave), and
//!   - the CPU-side `InterruptController` contract (`getPendingInterrupt`/`ackIrq`,
//!     `src/abi/bus_contract.zig:41-48`), comptime-verified below.
//!
//! It is an ordinary `src/devices/` module (M-D1 Option B): the machine OWNS the
//! `Pic` value, registers its four ports through the bus `registerPort` seam like
//! any device, and ALSO hands `&self.pic` to the CPU as the interrupt controller.
//!
//! Determinism (M-D6, the resolution of cpu.md Phase 5's deferred C2):
//!   - `getPendingInterrupt` is a PURE QUERY — it resolves the highest-priority
//!     unmasked, not-in-service line from (IRR, ISR, IMR, priority) and returns
//!     `vector_base + line`; it NEVER mutates ISR/IRR (the CPU may call it twice
//!     per boundary: `wakeable` + `serviceInterrupts`).
//!   - `ackIrq(vector)` RE-RESOLVES the same line (M-D14 — no cache, no
//!     reverse-map), sets ISR, and asserts `vector == vector_base + resolved_line`.
//!   - IRR bits are set ONLY via `raiseIrq` (called from cycle-derived event
//!     callbacks), never from host timing — so the cycle an IRQ appears is a pure
//!     function of the schedule.
//! No host time / RNG / float / unordered iteration anywhere (grep-enforced).

const std = @import("std");
const bus = @import("bus");
const contract = @import("bus_contract");

const PortHandler = bus.PortHandler;

/// One 8259 controller (master or slave). Every field explicitly reset (CLAUDE
/// #5). Snapshot-serializable by value (M-D11).
pub const Controller = struct {
    irr: u8 = 0, // interrupt request register
    isr: u8 = 0, // in-service register
    imr: u8 = 0xFF, // interrupt mask register (all masked at power-on)
    vector_base: u8 = 0, // ICW2 — INT vector for line 0 of this controller

    // ICW/OCW programming state machine.
    icw_index: u8 = 0, // 0 = idle (expecting OCW); 1..4 = expecting ICWn
    icw_needed: u8 = 0, // how many ICWs this init sequence expects (3 or 4)
    single: bool = false, // ICW1 bit1: single (no cascade) vs cascade
    auto_eoi: bool = false, // ICW4 bit1: auto-EOI mode
    icw4_needed: bool = false, // ICW1 bit0: ICW4 will follow
    cascade_mask: u8 = 0, // ICW3 (master: slave-on-line bitmask; slave: id)

    // OCW3 read-back select + special mask mode.
    read_isr: bool = false, // true => IN of the command port returns ISR, else IRR
    special_mask: bool = false, // OCW3 SMM
    /// Priority rotation base (M-D11 snapshot field). Line `priority_base` is the
    /// highest priority; default 0 (fixed priority, the BIOS configuration). Only
    /// rotate-on-EOI moves it; the BaK path uses fixed priority.
    priority_base: u3 = 0,

    pub fn reset(self: *Controller) void {
        self.* = .{};
    }

    /// Priority rank of `line` (0 = highest). With `priority_base == 0` this is
    /// just the line number (fixed priority, master 0,1,2,...,7). Rotation shifts
    /// the base; computed as `(line - base) mod 8` so it is a strict total order.
    fn rank(self: *const Controller, line: u3) u3 {
        return line -% self.priority_base;
    }

    /// The highest-priority line that is requested, unmasked, and not blocked by
    /// an equal-or-higher in-service line. Returns null if none. PURE — no mutation.
    /// Mirrors `pic.cpp check_for_irq`'s `(irr & imrr) & isrr` gated by active_irq.
    fn pendingLine(self: *const Controller) ?u3 {
        const ready: u8 = self.irr & ~self.imr;
        if (ready == 0) return null;

        // The highest-priority IN-SERVICE rank currently blocking lower lines.
        // In special-mask mode the ISR does not block (SMM), matching pic.cpp's
        // `special?8:active_irq`.
        var blocking_rank: u8 = 8; // 8 == nothing in service
        if (!self.special_mask and self.isr != 0) {
            var l: u8 = 0;
            while (l < 8) : (l += 1) {
                if ((self.isr >> @intCast(l)) & 1 != 0) {
                    const r = self.rank(@intCast(l));
                    if (r < blocking_rank) blocking_rank = r;
                }
            }
        }

        // Pick the requested line with the best (lowest) rank that out-prioritizes
        // the blocking in-service line.
        var best_line: ?u3 = null;
        var best_rank: u8 = 8;
        var l: u8 = 0;
        while (l < 8) : (l += 1) {
            if ((ready >> @intCast(l)) & 1 == 0) continue;
            const r = self.rank(@intCast(l));
            if (r >= blocking_rank) continue; // blocked by in-service priority
            if (r < best_rank) {
                best_rank = r;
                best_line = @intCast(l);
            }
        }
        return best_line;
    }

    /// Acknowledge (set ISR, clear IRR) for `line` — the IRR->ISR transition.
    fn setInService(self: *Controller, line: u3) void {
        const bit = @as(u8, 1) << line;
        self.irr &= ~bit;
        self.isr |= bit;
    }

    /// Non-specific EOI: clear the highest-priority in-service bit. No-op if idle.
    fn nonSpecificEoi(self: *Controller) void {
        if (self.isr == 0) return; // idle controller -> no-op (M-D14 guard)
        var best_line: u3 = 0;
        var best_rank: u8 = 8;
        var l: u8 = 0;
        while (l < 8) : (l += 1) {
            if ((self.isr >> @intCast(l)) & 1 == 0) continue;
            const r = self.rank(@intCast(l));
            if (r < best_rank) {
                best_rank = r;
                best_line = @intCast(l);
            }
        }
        self.isr &= ~(@as(u8, 1) << best_line);
    }

    /// Specific EOI: clear a named in-service bit (no-op if not in service).
    fn specificEoi(self: *Controller, line: u3) void {
        self.isr &= ~(@as(u8, 1) << line);
    }
};

pub const Pic = struct {
    master: Controller = .{},
    slave: Controller = .{},

    comptime {
        contract.assertInterruptControllerContract(Pic);
    }

    pub fn reset(self: *Pic) void {
        self.master.reset();
        self.slave.reset();
    }

    // -----------------------------------------------------------------------
    // Device-facing IRQ input (M-D6). The ONLY way IRR bits get set. Called
    // from cycle-derived event callbacks (the PIT's `onPitCh0Fire`), never from
    // host timing. Lines 0-7 -> master; 8-15 -> slave (the slave's request
    // surfaces through master IRQ2 via the cascade in `getPendingInterrupt`).
    // -----------------------------------------------------------------------
    pub fn raiseIrq(self: *Pic, line: u4) void {
        if (line < 8) {
            self.master.irr |= @as(u8, 1) << @intCast(line);
        } else {
            // The slave's INT output is wired to master IRQ2 (the cascade): a
            // slave request asserts master IRQ2 so the master sees the cascade.
            self.slave.irr |= @as(u8, 1) << @intCast(line - 8);
            self.master.irr |= @as(u8, 1) << 2;
        }
    }

    /// Clear the IMR mask bit for `line` on its controller (master 0-7, slave 8-15)
    /// — the "a driver unmasks its IRQ on install" step. Used by the INT 33h driver
    /// to unmask IRQ12 (slave bit4) at AX=0000 reset and AX=000C handler-install.
    /// Touches only the one mask bit (the other bits keep their POST values), so it
    /// is equivalent to the read-modify-write `IN/AND/OUT` a real driver issues.
    pub fn unmaskIrq(self: *Pic, line: u4) void {
        if (line < 8) {
            self.master.imr &= ~(@as(u8, 1) << @intCast(line));
        } else {
            self.slave.imr &= ~(@as(u8, 1) << @intCast(line - 8));
        }
    }

    pub fn lowerIrq(self: *Pic, line: u4) void {
        if (line < 8) {
            self.master.irr &= ~(@as(u8, 1) << @intCast(line));
        } else {
            self.slave.irr &= ~(@as(u8, 1) << @intCast(line - 8));
            // Drop the cascade assertion only if no slave line remains requested.
            if (self.slave.irr == 0) self.master.irr &= ~(@as(u8, 1) << 2);
        }
    }

    // -----------------------------------------------------------------------
    // InterruptController contract (the CPU handshake).
    // -----------------------------------------------------------------------

    /// PURE QUERY (M-D6): the highest-priority pending vector, or null. Resolves
    /// the master line; if it is IRQ2 (the cascade) and the slave is wired and has
    /// a pending line, surface the slave's vector instead. Returns null if nothing
    /// is pending (spurious IRQ7/15 NOT modeled — M-D6 decision).
    pub fn getPendingInterrupt(self: *Pic) ?u8 {
        const line = self.resolve() orelse return null;
        return line.controllerOf(self).vector_base + line.line;
    }

    /// Acknowledge half of the handshake (M-D14). RE-RESOLVES the same line (no
    /// cache, no reverse-map), sets ISR (cascade: a slave ack sets ISR on both the
    /// slave AND master IRQ2), and asserts the vector matches the re-resolved line.
    pub fn ackIrq(self: *Pic, vector: u8) void {
        const r = self.resolve() orelse {
            // The CPU only calls ackIrq right after a non-null getPendingInterrupt
            // at the same boundary; a null here is a contract violation.
            std.debug.assert(false);
            return;
        };
        const ctrl = r.controllerOf(self);
        std.debug.assert(vector == ctrl.vector_base + r.line); // M-D14 assert
        ctrl.setInService(r.line);
        if (r.from_slave) {
            // Cascade: the slave's request reached the CPU through master IRQ2, so
            // master IRQ2 also goes in-service (the guest will issue TWO EOIs).
            self.master.setInService(2);
        }
    }

    /// A resolved pending interrupt: which controller and which line.
    const Resolved = struct {
        line: u3,
        from_slave: bool,
        fn controllerOf(self: Resolved, pic: *Pic) *Controller {
            return if (self.from_slave) &pic.slave else &pic.master;
        }
    };

    /// Shared priority resolution used by BOTH getPendingInterrupt and ackIrq so
    /// they cannot drift (M-D14). PURE — no mutation.
    fn resolve(self: *Pic) ?Resolved {
        const m_line = self.master.pendingLine() orelse return null;
        // Master IRQ2 is the cascade input: a slave request surfaces only when
        // master IRQ2 wins master-side priority and is unmasked (pendingLine
        // already enforced unmasked + not-blocked).
        if (m_line == 2) {
            if (self.slave.pendingLine()) |s_line| {
                return .{ .line = s_line, .from_slave = true };
            }
            // IRQ2 requested but no slave line pending: treat the master IRQ2 line
            // itself as the request (a device on IRQ2 directly — rare; faithful).
        }
        return .{ .line = m_line, .from_slave = false };
    }

    // -----------------------------------------------------------------------
    // Port programming (PortHandler). Mirrors pic.cpp write_command/write_data.
    // -----------------------------------------------------------------------

    fn controllerForPort(self: *Pic, port: u16) *Controller {
        return if (port == 0x20 or port == 0x21) &self.master else &self.slave;
    }

    /// Command-port write (0x20 master / 0xA0 slave): ICW1 or OCW2/OCW3.
    pub fn writeCommand(c: *Controller, v: u8) void {
        if (v & 0x10 != 0) {
            // ICW1: start init. Bit0 = ICW4 needed, bit1 = single.
            c.irr = 0;
            c.isr = 0;
            c.imr = 0; // ICW1 CLEARS IMR to 0 (datasheet) — BIOS OCW1 re-masks.
            c.priority_base = 0;
            c.read_isr = false;
            c.special_mask = false;
            c.icw4_needed = (v & 0x01) != 0;
            c.single = (v & 0x02) != 0;
            c.icw_needed = if (c.icw4_needed) 4 else 3;
            c.icw_index = 2; // next data write is ICW2
            return;
        }
        if (v & 0x08 != 0) {
            // OCW3: read-back select / special-mask-mode.
            if (v & 0x02 != 0) c.read_isr = (v & 0x01) != 0; // RR + RIS
            if (v & 0x40 != 0) c.special_mask = (v & 0x20) != 0; // ESMM + SMM
            return;
        }
        // OCW2: EOI / rotate. Bits 7-5 = command; bits 2-0 = level (specific).
        const cmd = v >> 5;
        const level: u3 = @intCast(v & 0x07);
        switch (cmd) {
            0b001 => c.nonSpecificEoi(), // non-specific EOI
            0b011 => c.specificEoi(level), // specific EOI
            0b101 => { // rotate on non-specific EOI
                c.nonSpecificEoi();
                c.priority_base = level +% 1;
            },
            0b111 => { // rotate on specific EOI
                c.specificEoi(level);
                c.priority_base = level +% 1;
            },
            0b110 => c.priority_base = level +% 1, // set priority (rotate, no EOI)
            else => {}, // no-op / unimplemented automatic-rotation modes
        }
    }

    /// Data-port write (0x21 master / 0xA1 slave): ICW2/3/4 during init, else OCW1.
    pub fn writeData(c: *Controller, v: u8) void {
        if (c.icw_index != 0) {
            switch (c.icw_index) {
                2 => { // ICW2: vector base (low 3 bits ignored by the chip).
                    c.vector_base = v & 0xF8;
                    c.icw_index = 3;
                },
                3 => { // ICW3: cascade config.
                    c.cascade_mask = v;
                    c.icw_index = if (c.icw4_needed) 4 else 0;
                },
                4 => { // ICW4: 8086 mode + auto-EOI.
                    c.auto_eoi = (v & 0x02) != 0;
                    c.icw_index = 0;
                },
                else => c.icw_index = 0,
            }
            return;
        }
        // OCW1: the interrupt mask register (the most common runtime write).
        c.imr = v;
    }

    pub fn readPort(self: *Pic, port: u16) u8 {
        const c = self.controllerForPort(port);
        // Data port (0x21/0xA1) returns IMR; command port returns ISR or IRR per
        // the last OCW3 read-back select.
        if (port == 0x21 or port == 0xA1) return c.imr;
        return if (c.read_isr) c.isr else c.irr;
    }

    // -----------------------------------------------------------------------
    // PortHandler wiring (the machine registers ctx = &self.pic at `wire`).
    // -----------------------------------------------------------------------

    fn portIn8(ctx: *anyopaque, port: u16) u8 {
        const self: *Pic = @ptrCast(@alignCast(ctx));
        return self.readPort(port);
    }
    fn portOut8(ctx: *anyopaque, port: u16, v: u8) void {
        const self: *Pic = @ptrCast(@alignCast(ctx));
        const c = self.controllerForPort(port);
        if (port == 0x20 or port == 0xA0) {
            writeCommand(c, v);
        } else {
            writeData(c, v);
        }
    }

    const vtable: PortHandler.VTable = .{
        .in8 = portIn8,
        .out8 = portOut8,
    };

    /// Build the `PortHandler` for this PIC (ctx pinned to `self` by the machine's
    /// `wire`). The machine registers it at ports 0x20/0x21/0xA0/0xA1.
    pub fn portHandler(self: *Pic) PortHandler {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // -----------------------------------------------------------------------
    // Snapshot / restore (M-D11) — by value, no pointers.
    // -----------------------------------------------------------------------
    pub const Snapshot = struct {
        master: Controller,
        slave: Controller,
    };
    pub fn snapshot(self: *const Pic) Snapshot {
        return .{ .master = self.master, .slave = self.slave };
    }
    pub fn restore(self: *Pic, snap: Snapshot) void {
        self.master = snap.master;
        self.slave = snap.slave;
    }
};
