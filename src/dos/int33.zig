//! INT 33h — the mouse DRIVER (D18, host-serviced trap, owned HERE not the device
//! half). Reads raw motion/buttons from the mouse *device* via the same scripted-
//! input seam as the keyboard (deterministic external input), never the host.
//! Driver state (position, button mask, visibility, the installed event handler
//! far-ptr) is snapshot state (D14).
//!
//! Semantics are mirrored from dosbox-x's emulated mouse driver
//! (references/dosbox-x/src/ints/mouse.cpp INT33_Handler / Mouse_Reset /
//! Mouse_AfterNewVideoMode), cited inline. The DETERMINISTIC, oracle-able subset a
//! real-mode game (Betrayal at Krondor) uses at startup + per-frame:
//!   - AX=0000 reset+status, AX=0021 software reset (reset.read defaults from the
//!     CURRENT BDA video mode, mouse.cpp:1623/2042 + Mouse_Reset:1570 +
//!     Mouse_AfterNewVideoMode:1422).
//!   - AX=0001/0002 show/hide (the `hidden` show-COUNT, mouse.cpp:1627/1633).
//!   - AX=0003 get position+buttons (POS_X/POS_Y granularity mask, mouse.cpp:1642).
//!   - AX=0004 set position (signed clamp to range + the "==POS rounding" quirk,
//!     mouse.cpp:1659).
//!   - AX=0007/0008 define horizontal/vertical range (min<->max swap + reclamp the
//!     live position, mouse.cpp:1732/1801).
//!   - AX=000B read motion counters (headless -> NOT locked -> always 0; see note).
//!   - AX=000C/0014 set/swap event handler far-ptr.
//!   - AX=001A/001B set/get sensitivity (clamped 0..100 round-trip, mouse.cpp:2008).
//!   - AX=0011 get-buttons CuteMouse identifier, AX=0024 driver version/type.
//!
//! Determinism: nothing reads the host pointer. POSITION is placed only via AX=0004
//! (programmatic) and read back via AX=0003 — fully deterministic on dosbox-x AND
//! zdos (proven by double-mint). The mickey motion counters (AX=000B) read back as
//! 0 under headless dosbox-x because MOUSE_IsLocked() is false (no SDL capture) and
//! mickeys ONLY accumulate from real host motion (Mouse_CursorMoved, mouse.cpp:898)
//! — AX=0004 sets mouse.x directly and never touches mickey_x. So AX=000B is a
//! deterministic constant 0/0 headless; we model that exactly (locked=false).

const std = @import("std");
const cpu_state = @import("cpu").state;
const Reg32 = cpu_state.Reg32;
const Seg = cpu_state.Seg;

const ECX = @intFromEnum(Reg32.ecx);
const EDX = @intFromEnum(Reg32.edx);
const EBX = @intFromEnum(Reg32.ebx);
const EAX = @intFromEnum(Reg32.eax);

/// dosbox-x reports a 3-button driver (MOUSE_BUTTONS, mouse.cpp:159).
const MOUSE_BUTTONS: u16 = 3;

pub fn Int33(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        /// BDA current-video-mode byte, physical address 0040:0049 (BIOS_VIDEO_MODE
        /// in dosbox-x). The DOS module does not import `bios`, so we read the BDA
        /// directly through the bus the way other DOS code does (e.g. dta/psp/mcb).
        const BDA_VIDEO_MODE_PHYS: u32 = 0x0449;

        present: bool = true,
        /// Live cursor position (driver-internal, before the granularity mask).
        /// dosbox stores these as floats; for the programmatic Set-Position path
        /// they are always integral, so an i16 is exact.
        x: i16 = 0,
        y: i16 = 0,
        buttons: u16 = 0, // bit0=left, bit1=right, bit2=middle
        /// Cursor visibility is a SHOW-COUNT, not a boolean (mouse.cpp:1627/1633):
        /// hide increments, show decrements (floored at 0). Visible iff hidden==0.
        hidden: u16 = 1,
        /// Cursor range (signed; mode-dependent defaults set on reset).
        min_x: i16 = 0,
        max_x: i16 = 639,
        min_y: i16 = 0,
        max_y: i16 = 479,
        /// Granularity masks applied to POS_X/POS_Y (mouse.cpp:160/161). Mode 13h:
        /// gran_x=0xfffe (X rounded to even), gran_y=0xffff.
        gran_x: u16 = 0xffff,
        gran_y: u16 = 0xffff,
        /// Sensitivity values (AX=001A/001B), clamped 0..100 (mouse.cpp:1377).
        senv_x_val: u16 = 50,
        senv_y_val: u16 = 50,
        dspeed_val: u16 = 50,
        /// Installed event handler far pointer (seg:off) + event mask.
        handler_seg: u16 = 0,
        handler_off: u16 = 0,
        handler_mask: u16 = 0,

        /// Granularity-masked position the guest observes (mouse.cpp POS_X/POS_Y).
        fn posX(self: *const Self) u16 {
            return @as(u16, @bitCast(self.x)) & self.gran_x;
        }
        fn posY(self: *const Self) u16 {
            return @as(u16, @bitCast(self.y)) & self.gran_y;
        }

        /// Mouse_AfterNewVideoMode + Mouse_Reset (mouse.cpp:1422/1570): derive the
        /// per-mode range + granularity from the CURRENT BDA video mode, then center
        /// the cursor and clear buttons/mickeys.
        fn reset(self: *Self, cpu: *Cpu) void {
            const mode = cpu.bus.readPhys8(BDA_VIDEO_MODE_PHYS);

            // Defaults for the non-SVGA path (mode <= 0x13), mouse.cpp:1436-1441.
            self.gran_x = 0xffff;
            self.gran_y = 0xffff;
            self.min_x = 0;
            self.max_x = 639;
            self.min_y = 0;
            self.max_y = 479;

            switch (mode) {
                // Graphics 320x200 group (mouse.cpp:1472-1486).
                0x04, 0x05, 0x06, 0x08, 0x09, 0x0a, 0x0d, 0x0e, 0x13 => {
                    if (mode == 0x0d or mode == 0x13) self.gran_x = 0xfffe;
                    self.max_y = 199;
                },
                0x0f, 0x10 => self.max_y = 349,
                0x11, 0x12 => self.max_y = 479,
                // Text modes (mouse.cpp:1450-1470): 80x25 -> max_x=639, max_y=199,
                // gran_x=0xfff8, gran_y=0xfff8. (BaK is graphics; modeled for
                // completeness but the oracle band exercises mode 13h.)
                0x00, 0x01, 0x02, 0x03, 0x07 => {
                    self.gran_x = if (mode < 2) 0xfff0 else 0xfff8;
                    self.gran_y = 0xfff8;
                    self.max_y = 8 * 25 - 1; // 25 rows
                    self.max_x = 80 * 8 - 1; // 80 cols
                },
                else => {}, // unhandled mode keeps the 639x479 default
            }

            // Mouse_Reset (mouse.cpp:1570): center cursor, clear buttons/handler.
            self.x = @intCast(@divTrunc(@as(i32, self.max_x) + 1, 2));
            self.y = @intCast(@divTrunc(@as(i32, self.max_y) + 1, 2));
            self.buttons = 0;
            self.hidden = 1; // a freshly reset cursor is hidden (shown via AX=0001)
            self.handler_seg = 0;
            self.handler_off = 0;
            self.handler_mask = 0;
        }

        pub fn service(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const ax = cpu.st.getReg16(EAX);
            switch (ax) {
                0x0000 => { // RESET DRIVER AND READ STATUS (mouse.cpp:1623)
                    cpu.st.setReg16(EAX, if (self.present) 0xFFFF else 0x0000);
                    cpu.st.setReg16(EBX, MOUSE_BUTTONS);
                    self.reset(cpu);
                },
                0x0001 => { // SHOW CURSOR (mouse.cpp:1627): decrement show-count
                    if (self.hidden > 0) self.hidden -= 1;
                },
                0x0002 => { // HIDE CURSOR (mouse.cpp:1633): increment show-count
                    self.hidden +%= 1;
                },
                0x0003 => { // GET POSITION + BUTTONS (mouse.cpp:1642)
                    cpu.st.setReg16(EBX, self.buttons);
                    cpu.st.setReg16(ECX, self.posX());
                    cpu.st.setReg16(EDX, self.posY());
                },
                0x0004 => { // POSITION MOUSE CURSOR (mouse.cpp:1659)
                    const cx: i16 = @bitCast(cpu.st.getReg16(ECX));
                    const dx: i16 = @bitCast(cpu.st.getReg16(EDX));
                    // Signed clamp to range; the "!= POS" arms preserve the rounding
                    // quirk (a value equal to the current rounded pos is ignored).
                    if (cx >= self.max_x) self.x = self.max_x else if (self.min_x >= cx) self.x = self.min_x else if (cx != @as(i16, @bitCast(self.posX()))) self.x = cx;

                    if (dx >= self.max_y) self.y = self.max_y else if (self.min_y >= dx) self.y = self.min_y else if (dx != @as(i16, @bitCast(self.posY()))) self.y = dx;
                },
                0x0007 => { // DEFINE HORIZONTAL RANGE (mouse.cpp:1732)
                    const cx: i16 = @bitCast(cpu.st.getReg16(ECX));
                    const dx: i16 = @bitCast(cpu.st.getReg16(EDX));
                    if (cx < dx) {
                        self.min_x = cx;
                        self.max_x = dx;
                    } else {
                        self.min_x = dx;
                        self.max_x = cx;
                    }
                    // "Battle Chess wants this": reclamp the live position.
                    if (self.x > self.max_x) self.x = self.max_x;
                    if (self.x < self.min_x) self.x = self.min_x;
                },
                0x0008 => { // DEFINE VERTICAL RANGE (mouse.cpp:1801)
                    const cx: i16 = @bitCast(cpu.st.getReg16(ECX));
                    const dx: i16 = @bitCast(cpu.st.getReg16(EDX));
                    if (cx < dx) {
                        self.min_y = cx;
                        self.max_y = dx;
                    } else {
                        self.min_y = dx;
                        self.max_y = cx;
                    }
                    if (self.y > self.max_y) self.y = self.max_y;
                    if (self.y < self.min_y) self.y = self.min_y;
                },
                0x000B => { // READ MOTION COUNTERS (mouse.cpp:1900/1610)
                    // Headless: MOUSE_IsLocked() is false (no SDL capture), so the
                    // counters read back as 0/0. Mickeys only accumulate from real
                    // host motion, which the deterministic oracle never injects.
                    cpu.st.setReg16(ECX, 0);
                    cpu.st.setReg16(EDX, 0);
                },
                0x000C => { // DEFINE INTERRUPT SUBROUTINE (mouse.cpp:1904)
                    self.handler_mask = cpu.st.getReg16(ECX);
                    self.handler_seg = cpu.st.selector[@intFromEnum(Seg.es)];
                    self.handler_off = cpu.st.getReg16(EDX);
                },
                0x0011 => { // GET NUMBER OF BUTTONS / CuteMouse id (mouse.cpp:1935)
                    cpu.st.setReg16(EAX, 0x574D); // detection identifier
                    cpu.st.setReg16(EBX, 0); // reserved capability flags
                    cpu.st.setReg16(ECX, 1); // wheel supported
                },
                0x0014 => { // EXCHANGE INTERRUPT SUBROUTINES (mouse.cpp:1970)
                    const old_mask = self.handler_mask;
                    const old_seg = self.handler_seg;
                    const old_off = self.handler_off;
                    self.handler_mask = cpu.st.getReg16(ECX);
                    self.handler_seg = cpu.st.selector[@intFromEnum(Seg.es)];
                    self.handler_off = cpu.st.getReg16(EDX);
                    cpu.st.setReg16(ECX, old_mask);
                    cpu.loadSegment(.es, old_seg);
                    cpu.st.setReg16(EDX, old_off);
                },
                0x001A => { // SET MOUSE SENSITIVITY (mouse.cpp:2008/1377)
                    var px = cpu.st.getReg16(EBX);
                    var py = cpu.st.getReg16(ECX);
                    var ds = cpu.st.getReg16(EDX);
                    if (px > 100) px = 100;
                    if (py > 100) py = 100;
                    if (ds > 100) ds = 100;
                    self.senv_x_val = px;
                    self.senv_y_val = py;
                    self.dspeed_val = ds;
                },
                0x001B => { // RETURN MOUSE SENSITIVITY (mouse.cpp:2013)
                    cpu.st.setReg16(EBX, self.senv_x_val);
                    cpu.st.setReg16(ECX, self.senv_y_val);
                    cpu.st.setReg16(EDX, self.dspeed_val);
                },
                0x0021 => { // SOFTWARE RESET (mouse.cpp:2042) — same as AX=0000.
                    cpu.st.setReg16(EAX, if (self.present) 0xFFFF else 0x0000);
                    cpu.st.setReg16(EBX, MOUSE_BUTTONS);
                    self.reset(cpu);
                },
                0x0024 => { // GET VERSION / MOUSE TYPE / IRQ (mouse.cpp:2074)
                    // BX=0x0805 version 8.05, CH=0x04 PS/2 type, CL=0 IRQ (PS/2).
                    cpu.st.setReg16(EBX, 0x0805);
                    cpu.st.setReg16(ECX, 0x0400); // CH=0x04, CL=0x00
                },
                else => dos.unsupported(cpu, br, 0x33),
            }
        }

        /// Inject a scripted mouse event (deterministic external input seam).
        pub fn injectMotion(self: *Self, x: i16, y: i16, buttons: u16) void {
            self.x = x;
            self.y = y;
            self.buttons = buttons;
        }

        // -------------------------------------------------------------------
        // Snapshot / restore (D14, the mouse-driver state hole closed in input
        // Phase 0). A POD by-value copy of EVERY mutable driver field that lives
        // host-side (NOT in guest RAM): the driver carries no guest-RAM-backed
        // state, so all of it must be captured here. This mirrors the
        // Pic/Pit/Speaker snapshot idiom (POD, byte-serializable, no pointers).
        //
        // SCOPE NOTE: this captures the fields that exist TODAY. The Phase-2
        // relative-motion (mickey) accumulator and the Phase-3 callback
        // re-entrancy flag are added to this Snapshot WHEN those phases introduce
        // the fields — not forward-referenced here.
        // -------------------------------------------------------------------
        pub const Snapshot = struct {
            present: bool,
            x: i16,
            y: i16,
            buttons: u16,
            hidden: u16,
            min_x: i16,
            max_x: i16,
            min_y: i16,
            max_y: i16,
            gran_x: u16,
            gran_y: u16,
            senv_x_val: u16,
            senv_y_val: u16,
            dspeed_val: u16,
            handler_seg: u16,
            handler_off: u16,
            handler_mask: u16,
        };

        pub fn snapshot(self: *const Self) Snapshot {
            return .{
                .present = self.present,
                .x = self.x,
                .y = self.y,
                .buttons = self.buttons,
                .hidden = self.hidden,
                .min_x = self.min_x,
                .max_x = self.max_x,
                .min_y = self.min_y,
                .max_y = self.max_y,
                .gran_x = self.gran_x,
                .gran_y = self.gran_y,
                .senv_x_val = self.senv_x_val,
                .senv_y_val = self.senv_y_val,
                .dspeed_val = self.dspeed_val,
                .handler_seg = self.handler_seg,
                .handler_off = self.handler_off,
                .handler_mask = self.handler_mask,
            };
        }

        pub fn restore(self: *Self, snap: Snapshot) void {
            self.present = snap.present;
            self.x = snap.x;
            self.y = snap.y;
            self.buttons = snap.buttons;
            self.hidden = snap.hidden;
            self.min_x = snap.min_x;
            self.max_x = snap.max_x;
            self.min_y = snap.min_y;
            self.max_y = snap.max_y;
            self.gran_x = snap.gran_x;
            self.gran_y = snap.gran_y;
            self.senv_x_val = snap.senv_x_val;
            self.senv_y_val = snap.senv_y_val;
            self.dspeed_val = snap.dspeed_val;
            self.handler_seg = snap.handler_seg;
            self.handler_off = snap.handler_off;
            self.handler_mask = snap.handler_mask;
        }
    };
}
