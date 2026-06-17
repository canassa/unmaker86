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
//!   - AX=000B read motion counters (accumulate-and-zero-on-read; see note).
//!   - AX=000C/0014 set/swap event handler far-ptr.
//!   - AX=001A/001B set/get sensitivity (clamped 0..100 round-trip, mouse.cpp:2008).
//!   - AX=0011 get-buttons CuteMouse identifier, AX=0024 driver version/type.
//!
//! Determinism: nothing reads the host pointer. POSITION is placed via AX=0004
//! (programmatic) or `injectAbsolute`/`injectRelative` (the deterministic scripted-
//! input seam) and read back via AX=0003 — fully deterministic on dosbox-x AND zdos
//! (proven by double-mint). The mickey motion counters (AX=000B) accumulate ONLY
//! from `injectRelative`'s fixed-point mickey math (input Phase 2), never the host
//! pointer, and are returned-and-zeroed on read (dosbox case 0x0b / spice86
//! GetMotionDistance, MouseInt33Handler.cs:624-638). With no relative motion
//! injected the accumulator stays 0, so AX=000B reads 0/0 — identical to headless
//! dosbox-x (MOUSE_IsLocked()=false: live mickeys only accrue from real host
//! motion, mouse.cpp:898) and to the prior zdos behavior. The contract is now
//! "accumulate-and-zero", not "hardcoded 0"; the difference is observable only once
//! `dx/dy` are injected (the MOUSE1 oracle injects none, so its golden is
//! unchanged — input-injection.md §5.2).

const std = @import("std");
const cpu_state = @import("cpu").state;
const Reg32 = cpu_state.Reg32;
const Seg = cpu_state.Seg;

const ECX = @intFromEnum(Reg32.ecx);
const EDX = @intFromEnum(Reg32.edx);
const EBX = @intFromEnum(Reg32.ebx);
const EAX = @intFromEnum(Reg32.eax);
const ESI = @intFromEnum(Reg32.esi);
const EDI = @intFromEnum(Reg32.edi);

/// dosbox-x reports a 3-button driver (MOUSE_BUTTONS, mouse.cpp:159).
const MOUSE_BUTTONS: u16 = 3;

/// INT 33h AX=0Ch event-callback CONDITION (event) mask bits — the Microsoft
/// Mouse Programmer's Reference layout the driver builds and AND-s against the
/// installed `handler_mask` before firing (dosbox-x `event.type`, mouse.cpp
/// MOUSE_EventXxx + the INT74 dispatch at :2266). Bit i means "event i happened".
const EV_MOVED: u16 = 1 << 0; // cursor position changed
const EV_LBTN_DOWN: u16 = 1 << 1; // left button pressed
const EV_LBTN_UP: u16 = 1 << 2; // left button released
const EV_RBTN_DOWN: u16 = 1 << 3; // right button pressed
const EV_RBTN_UP: u16 = 1 << 4; // right button released
const EV_MBTN_DOWN: u16 = 1 << 5; // middle button pressed
const EV_MBTN_UP: u16 = 1 << 6; // middle button released

/// Driver button-state bit layout (shared by `self.buttons`, AX=0003, and the
/// callback BX): bit0=left, bit1=right, bit2=middle (mouse.cpp button order).
const BTN_LEFT: u16 = 1 << 0;
const BTN_RIGHT: u16 = 1 << 1;
const BTN_MIDDLE: u16 = 1 << 2;

pub fn Int33(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        /// BDA current-video-mode byte, physical address 0040:0049 (BIOS_VIDEO_MODE
        /// in dosbox-x). The DOS module does not import `bios`, so we read the BDA
        /// directly through the bus the way other DOS code does (e.g. dta/psp/mcb).
        const BDA_VIDEO_MODE_PHYS: u32 = 0x0449;

        // -------------------------------------------------------------------
        // Relative-motion (mickey) fixed-point constants — input Phase 2. ALL
        // INTEGER, NO FLOAT (the `src/dos` determinism grep gate bans float
        // types; the float pipeline the references use is exactly the non-
        // determinism anti-pattern this project escapes). See `injectRelative`
        // for the full derivation + exactness argument.
        //
        // SCALE is the common fixed-point denominator. The float pipeline is
        //   coeff             = (tmp*tmp)/3600 + 1/3 = (tmp*tmp + 1200)/3600
        //   pixels_per_mickey = 8 / ratio,  mickeys_per_pixel = ratio / 8
        // with the per-axis mickey/pixel `ratio` fixed at the driver defaults
        // (8 horizontal, 16 vertical — zdos implements no AX=000F to change
        // them). Every increment is an EXACT integer at SCALE = 3600 * 16:
        // 3600 is the coeff denominator; 16 = lcm(ratio_x=8, ratio_y=16) is
        // the pixels-per-mickey denominator. So both the per-move mickey
        // increment (rel*coeff) and the per-move cursor-pixel increment
        // (rel*coeff*8/ratio) are integers when scaled by SCALE — exact and
        // byte-identical across builds/hosts. (Verified against the dosbox
        // float reference: mickey counters AND cursor position match for
        // sensitivities 0/1/25/50/100 over randomized move sequences.)
        const SCALE: i64 = 3600 * 16; // = 57600
        /// 0.6-mickey flip-flop-protection threshold (mouse_common.cpp:103),
        /// scaled. `0.6 * 57600 = 34560` is exact.
        const ACCUM_THRESHOLD: i64 = (SCALE * 3) / 5; // 0.6 * SCALE = 34560
        /// Per-axis mickey/pixel ratio (dosbox `set_mickey_pixel_rate` defaults,
        /// mouseif_dos_driver.cpp:1170). zdos has no AX=000F, so these are
        /// constants. `pixels_per_mickey = 8/ratio`, `mickeys_per_pixel = ratio/8`.
        const RATIO_X: i64 = 8;
        const RATIO_Y: i64 = 16;

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

        /// Re-entrancy guard for the event callback (input Phase 3). TRANSIENT,
        /// stack-scoped: set on entry to `fireEventCallback` and cleared on exit,
        /// so a guest handler that itself injects (or whose nested instructions
        /// re-enter this path) cannot recursively fire the handler. It is ALWAYS
        /// false at any command/snapshot boundary (the far-call runs to completion
        /// synchronously on the worker before the next command), so it is NOT a
        /// snapshot field — capturing an invariably-false flag would add nothing
        /// and only widen the golden. See the snapshot SCOPE NOTE below.
        firing: bool = false,

        /// Sub-mickey remainder (dosbox `precise_mickey_counter`,
        /// mouseif_dos_driver.cpp:1268), scaled by SCALE. Carries the
        /// fractional mickey so repeated sub-threshold deltas accumulate
        /// correctly (no drift, no flip-flop).
        precise_mickey_x: i64 = 0,
        precise_mickey_y: i64 = 0,
        /// Sub-pixel cursor remainder, scaled by SCALE. dosbox keeps a FLOAT
        /// PosX that carries the fraction across reads and truncates toward
        /// zero on the int16 cast; zdos's position is an exact i16, so the
        /// fraction lives here and whole pixels are consumed by truncation
        /// toward zero (matching dosbox's `(int16_t)PosX`).
        precise_pixel_x: i64 = 0,
        precise_pixel_y: i64 = 0,
        /// Signed mickey motion counters (dosbox `mickey_counter`,
        /// mouseif_dos_driver.cpp:1270). Returned + zeroed by AX=000B.
        mickey_x: i16 = 0,
        mickey_y: i16 = 0,

        /// Granularity-masked position the guest observes (mouse.cpp POS_X/POS_Y).
        fn posX(self: *const Self) u16 {
            return @as(u16, @bitCast(self.x)) & self.gran_x;
        }
        fn posY(self: *const Self) u16 {
            return @as(u16, @bitCast(self.y)) & self.gran_y;
        }

        /// Derive the per-mode cursor RANGE (min/max) + granularity from the CURRENT
        /// BDA video mode (Mouse_AfterNewVideoMode, mouse.cpp:1422; dosbox-staging
        /// MOUSEDOS_AfterNewVideoMode, mouseif_dos_driver.cpp:1011). Shared by `reset`
        /// and `afterNewVideoMode` so the two paths derive an IDENTICAL range — the
        /// driver is the single source of truth for the range the API-layer live-mouse
        /// fold scales against (plans/mouse-input.md §5.3/§7). Does NOT touch the
        /// cursor position, buttons, handler, or mickeys; callers decide that.
        fn deriveRangeFromMode(self: *Self, cpu: *Cpu) void {
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
        }

        /// INT 10h AH=00 set-mode hook (Mouse_AfterNewVideoMode, mouse.cpp:1422;
        /// dosbox-staging MOUSEDOS_AfterNewVideoMode, mouseif_dos_driver.cpp:1011).
        /// Re-derives the per-mode range + granularity WITHOUT resetting the cursor
        /// position, buttons, or the installed AX=0Ch handler — exactly what dosbox
        /// does on a mode change (it does NOT re-center or drop the handler). Reclamps
        /// the live position into the new range (the "Battle Chess wants this" reclamp,
        /// shared with AX=07/08). This closes the pre-existing gap (plans/mouse-input.md
        /// §7): before, the INT 33h range only followed an AX=00/21 reset, never a bare
        /// INT 10h mode-set — so "scale by the driver's live max" was wrong for a guest
        /// that set the mode without re-resetting the mouse. Hooked from the machine
        /// facade (`Services.dispatchCallback`) after the BIOS services AH=00, since
        /// `src/bios` is below `src/dos` and cannot reach the driver directly.
        pub fn afterNewVideoMode(self: *Self, cpu: *Cpu) void {
            self.deriveRangeFromMode(cpu);
            // Reclamp the live position into the (possibly shrunk) range.
            if (self.x > self.max_x) self.x = self.max_x;
            if (self.x < self.min_x) self.x = self.min_x;
            if (self.y > self.max_y) self.y = self.max_y;
            if (self.y < self.min_y) self.y = self.min_y;
        }

        /// Mouse_AfterNewVideoMode + Mouse_Reset (mouse.cpp:1422/1570): derive the
        /// per-mode range + granularity from the CURRENT BDA video mode, then center
        /// the cursor and clear buttons/mickeys.
        fn reset(self: *Self, cpu: *Cpu) void {
            self.deriveRangeFromMode(cpu);

            // Mouse_Reset (mouse.cpp:1570): center cursor, clear buttons/handler.
            self.x = @intCast(@divTrunc(@as(i32, self.max_x) + 1, 2));
            self.y = @intCast(@divTrunc(@as(i32, self.max_y) + 1, 2));
            self.buttons = 0;
            self.hidden = 1; // a freshly reset cursor is hidden (shown via AX=0001)
            self.handler_seg = 0;
            self.handler_off = 0;
            self.handler_mask = 0;
            // Mouse_Reset clears the mickey counters + accumulators (mouse.cpp:1570).
            self.mickey_x = 0;
            self.mickey_y = 0;
            self.precise_mickey_x = 0;
            self.precise_mickey_y = 0;
            self.precise_pixel_x = 0;
            self.precise_pixel_y = 0;
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
                    // Shared with `injectAbsolute` so the two paths can't diverge.
                    self.setClampedX(cx);
                    self.setClampedY(dx);
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
                    // ACCUMULATE-AND-ZERO-ON-READ (input Phase 2). Return the
                    // signed mickey counters accumulated since the last AX=000B
                    // call, then zero them — matching dosbox case 0x0b and spice86
                    // GetMotionDistance (MouseInt33Handler.cs:624-638, zero at
                    // :635) so repeated reads don't drift. The counters are driven
                    // ONLY by `injectRelative` (the deterministic scripted-input
                    // seam, fixed-point mickey math) — never the host pointer — so
                    // they stay deterministic. With no relative motion injected the
                    // accumulator is 0, so AX=000B still reads 0/0 (the MOUSE1
                    // oracle, which injects no motion, is unaffected).
                    cpu.st.setReg16(ECX, @bitCast(self.mickey_x));
                    cpu.st.setReg16(EDX, @bitCast(self.mickey_y));
                    self.mickey_x = 0;
                    self.mickey_y = 0;
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

        /// Set X to `v`, clamped to the live range with the SAME signed clamp +
        /// "==POS rounding" quirk AX=0004 uses (mouse.cpp:1659). Shared by AX=0004
        /// and `injectAbsolute` so injection is byte-identical to a guest set.
        fn setClampedX(self: *Self, v: i16) void {
            if (v >= self.max_x) self.x = self.max_x else if (self.min_x >= v) self.x = self.min_x else if (v != @as(i16, @bitCast(self.posX()))) self.x = v;
        }
        fn setClampedY(self: *Self, v: i16) void {
            if (v >= self.max_y) self.y = self.max_y else if (self.min_y >= v) self.y = self.min_y else if (v != @as(i16, @bitCast(self.posY()))) self.y = v;
        }

        /// Inject an ABSOLUTE scripted mouse event (deterministic external-input
        /// seam, input Phase 2). Each of position-x / position-y / buttons is set
        /// only when its `set_*` flag is true, so a caller can update a subset.
        /// Position uses the SAME AX=0004 range clamp (mouse.cpp:1659) so an
        /// injected absolute position is read back verbatim by the guest via
        /// AX=0003. Nothing here reads the host pointer or clock.
        pub fn injectAbsolute(
            self: *Self,
            x: i16,
            y: i16,
            buttons: u16,
            set_x: bool,
            set_y: bool,
            set_buttons: bool,
        ) void {
            if (set_x) self.setClampedX(x);
            if (set_y) self.setClampedY(y);
            if (set_buttons) self.buttons = buttons;
        }

        /// Round a SCALE-fixed-point value to the nearest whole unit, half AWAY
        /// from zero (matching dosbox `std::round`, mouse_common.cpp:127). Returns
        /// the whole-unit count (NOT scaled).
        fn roundScaled(v: i64) i64 {
            return if (v >= 0)
                @divTrunc(2 * v + SCALE, 2 * SCALE)
            else
                -@divTrunc(-2 * v + SCALE, 2 * SCALE);
        }
        /// Truncate a SCALE-fixed-point value toward zero to whole units (matching
        /// dosbox's `(int16_t)PosX` cast on cursor read). Returns the whole count.
        fn truncScaled(v: i64) i64 {
            return @divTrunc(v, SCALE); // @divTrunc rounds toward zero for both signs
        }

        /// Inject RELATIVE motion + optional buttons (deterministic external-input
        /// seam, input Phase 2). `dx`/`dy` are the literal relative motion the
        /// driver consumes (dosbox `x_rel`/`y_rel`, mouseif_dos_driver.cpp:1224),
        /// in the driver's input units — NO host-OS pointer acceleration (raw input
        /// forced) and NO host-clock sample-rate gate (§7.4). This ports dosbox's
        /// `move_cursor_captured` + `update_mickeys_on_move` (the raw-input path) in
        /// EXACT FIXED-POINT (the grep gate bans float types); see the SCALE
        /// derivation above. Per axis (`ratio` = mickeys/pixel, `s` = sensitivity):
        ///   coeff   = (min(100,s)-1)^2 / 3600 + 1/3,  s==0 -> 0       (:848-853)
        ///   apply coeff iff |rel| > 1 OR coeff < 1 (raw forced, :1237-1239)
        ///   cursor_px_inc = rel * coeff * (8/ratio)   (-> self.x/self.y)
        ///   mickey_inc    = rel * coeff               (-> the AX=000B counters)
        /// The fractional remainder of each accumulator is carried so repeated
        /// sub-unit deltas accumulate without drift; the mickey counter only
        /// advances once |precise| >= 0.6 (mouse_common.cpp:103). Both increments
        /// are exact integers at SCALE, so the result is byte-identical every run.
        pub fn injectRelative(
            self: *Self,
            dx: i16,
            dy: i16,
            buttons: u16,
            set_dx: bool,
            set_dy: bool,
            set_buttons: bool,
        ) void {
            if (set_dx) self.applyRelAxis(dx, RATIO_X, self.senv_x_val, &self.precise_pixel_x, &self.precise_mickey_x, &self.mickey_x, true, false);
            if (set_dy) self.applyRelAxis(dy, RATIO_Y, self.senv_y_val, &self.precise_pixel_y, &self.precise_mickey_y, &self.mickey_y, false, false);
            if (set_buttons) self.buttons = buttons;
        }

        /// Advance ONLY the AX=0Bh mickey counters from a relative delta — NOT the
        /// cursor position. Used by the live SEAMLESS path: the absolute write owns
        /// the position, and the relative channel feeds mickeys only, matching dosbox
        /// `update_mickeys_on_move` (mouseif_dos_driver.cpp:1224, whose dx/dy position
        /// out-params the seamless path discards). Applying BOTH would double-count the
        /// same physical motion and break 1:1 absolute tracking (plans/mouse-input.md
        /// §3 — "relative → mickeys, absolute → position").
        fn accumulateMickeys(self: *Self, dx: i16, dy: i16) void {
            self.applyRelAxis(dx, RATIO_X, self.senv_x_val, &self.precise_pixel_x, &self.precise_mickey_x, &self.mickey_x, true, true);
            self.applyRelAxis(dy, RATIO_Y, self.senv_y_val, &self.precise_pixel_y, &self.precise_mickey_y, &self.mickey_y, false, true);
        }

        /// One axis of `injectRelative`. `is_x` selects which clamped-position
        /// setter to drive when whole cursor pixels are consumed. `mickeys_only`
        /// skips the cursor-position update entirely (the seamless path, where the
        /// absolute write owns position) — only the AX=0Bh mickey counter advances.
        fn applyRelAxis(
            self: *Self,
            rel_i: i16,
            ratio: i64,
            sens: u16,
            pixel_acc: *i64,
            mickey_acc: *i64,
            mickey_ctr: *i16,
            comptime is_x: bool,
            comptime mickeys_only: bool,
        ) void {
            const rel: i64 = rel_i;

            // coeff = (tmp*tmp + 1200) / 3600, with tmp = min(100,s)-1; s==0 -> 0.
            const s: i64 = @min(@as(i64, 100), @as(i64, sens));
            const tmp = s - 1;
            const coeff_num: i64 = if (sens == 0) 0 else (tmp * tmp + 1200);
            const coeff_den: i64 = 3600;
            // Raw input forced: apply coeff iff |rel| > 1 OR coeff < 1.
            const coeff_lt_one = coeff_num < coeff_den;
            const apply_coeff = (@abs(rel) > 1) or coeff_lt_one;

            // mickey_inc (scaled) = rel * coeff * SCALE ; cursor_inc (scaled) =
            // rel * coeff * (8/ratio) * SCALE. SCALE/coeff_den = 16 is exact, and
            // multiplying by 8/ratio (ratio in {8,16}) stays integral.
            var mickey_inc: i64 = undefined;
            var pixel_inc: i64 = undefined;
            if (apply_coeff) {
                if (sens == 0) {
                    mickey_inc = 0; // s==0 stops the cursor (coeff 0)
                    pixel_inc = 0;
                } else {
                    const base = rel * coeff_num * @divExact(SCALE, coeff_den); // rel*coeff*SCALE
                    mickey_inc = base;
                    pixel_inc = @divTrunc(base * 8, ratio);
                }
            } else {
                // No coeff: cursor px = rel*ppm = rel*8/ratio ; mickey = px*mpp = rel.
                mickey_inc = rel * SCALE;
                pixel_inc = @divTrunc(rel * SCALE * 8, ratio);
            }

            // Cursor: accumulate sub-pixel, consume WHOLE pixels (trunc toward 0).
            // Skipped for the seamless/mickeys-only path — position there comes solely
            // from the absolute write (no double-apply of the same motion).
            if (!mickeys_only) {
                pixel_acc.* += pixel_inc;
                const whole_px = truncScaled(pixel_acc.*);
                if (whole_px != 0) {
                    pixel_acc.* -= whole_px * SCALE;
                    const new_pos: i64 = @as(i64, if (is_x) self.x else self.y) + whole_px;
                    const clamped: i16 = @intCast(std.math.clamp(
                        new_pos,
                        @as(i64, if (is_x) self.min_x else self.min_y),
                        @as(i64, if (is_x) self.max_x else self.max_y),
                    ));
                    if (is_x) self.x = clamped else self.y = clamped;
                }
            }

            // Mickey counter: accumulate sub-mickey, advance once |precise| >= 0.6,
            // rounding half away from zero (the AX=000B observable).
            mickey_acc.* += mickey_inc;
            if (@abs(mickey_acc.*) >= ACCUM_THRESHOLD) {
                const consumed = roundScaled(mickey_acc.*);
                mickey_acc.* -= consumed * SCALE;
                const sum: i32 = @as(i32, mickey_ctr.*) + @as(i32, @intCast(consumed));
                mickey_ctr.* = @intCast(std.math.clamp(sum, -32768, 32767));
            }
        }

        // -------------------------------------------------------------------
        // Event callback (INT 33h AX=0Ch) — input Phase 3. This is what real
        // Betrayal at Krondor requires: BaK installs an AH=0Ch handler
        // (KRONDOR-flat.c `mouse_install`/`mouse_event_callback`) and NEVER polls
        // AX=03 — position/buttons reach the game ONLY through this far-call. The
        // handler latches CX/DX/BL into its DGROUP globals and draws its own cursor.
        // -------------------------------------------------------------------

        /// Build the CONDITION (event) mask for a move-and-button-change from the
        /// OLD button state (`old_btn`) to `self.buttons` plus whether the cursor
        /// moved (`moved`). Bits per the Microsoft layout (EV_* above). A button
        /// that both pressed and released between injects cannot be observed (one
        /// inject = one transition), so press/release are mutually exclusive per
        /// button here — exactly what dosbox derives per `MOUSE_EventXxx`.
        fn conditionMask(old_btn: u16, new_btn: u16, moved: bool) u16 {
            var mask: u16 = 0;
            if (moved) mask |= EV_MOVED;
            const pressed = new_btn & ~old_btn; // 0->1 transitions
            const released = old_btn & ~new_btn; // 1->0 transitions
            if (pressed & BTN_LEFT != 0) mask |= EV_LBTN_DOWN;
            if (released & BTN_LEFT != 0) mask |= EV_LBTN_UP;
            if (pressed & BTN_RIGHT != 0) mask |= EV_RBTN_DOWN;
            if (released & BTN_RIGHT != 0) mask |= EV_RBTN_UP;
            if (pressed & BTN_MIDDLE != 0) mask |= EV_MBTN_DOWN;
            if (released & BTN_MIDDLE != 0) mask |= EV_MBTN_UP;
            return mask;
        }

        /// Far-call the installed AX=0Ch event handler with the Microsoft callback
        /// register ABI, charging EVERY instruction it runs through the normal
        /// ledger (no hole — see `runGuestFarCall`). Fires ONLY when a handler is
        /// installed AND the triggering `condition` intersects the installed
        /// `handler_mask`. AX carries just the intersected bits (the events THIS
        /// call is reporting, the bits the handler asked for).
        ///
        /// Register ABI (dosbox-x INT74_Handler, mouse.cpp:2266-2273):
        ///   AX = condition mask (events ∩ installed mask)
        ///   BX = button state (bit0=L,1=R,2=M in BL; BH=wheel=0)
        ///   CX = cursor X position (granularity-masked POS_X — same units AX=03 reports)
        ///   DX = cursor Y position (POS_Y)
        ///   SI = signed horizontal mickey counter (mouse.mickey_x)
        ///   DI = signed vertical mickey counter (mouse.mickey_y)
        /// DS is left UNTOUCHED: the real driver never sets DS for the user sub
        /// (dosbox-x pushes only sub_seg:sub_ofs, never DS), and BaK's Borland far
        /// callback establishes its own DGROUP in its prologue — verified against
        /// `mouse_event_callback` (KRONDOR-flat.c:20257), which reads in_CX/in_DX/
        /// in_BL and writes DGROUP statics with no reliance on the caller's DS.
        ///
        /// Re-entrancy: guarded by `self.firing` (transient) so a handler that
        /// re-enters the inject path can't recursively fire. Runs on the worker
        /// (machine owner) at a command boundary, so the far-call completes before
        /// the next command — `firing` is always false across snapshots.
        fn fireEventCallback(self: *Self, cpu: *Cpu, br: *Bridge, condition: u16) void {
            if (self.firing) return; // re-entrancy guard (Phase 3)
            if (self.handler_seg == 0 and self.handler_off == 0) return;
            const fire_bits = condition & self.handler_mask;
            if (fire_bits == 0) return;

            self.firing = true;
            defer self.firing = false;

            // PRESERVE THE INTERRUPTED GUEST CONTEXT (the ISR-frame model).
            //
            // On real hardware the AX=0Ch handler is reached from the mouse driver's
            // INT 74h ISR: the hardware IRQ pushes FLAGS/CS/IP, and the driver's
            // dispatch preserves the GP registers around the user handler. The user
            // handler is therefore free to clobber AX/BX/CX/DX (mouse-handler ABI
            // scratch), but the FOREGROUND code it interrupted resumes with its
            // registers intact (dosbox-x INT74_Handler, mouse.cpp:2266 — the IRQ
            // entry frame restores the caller's full context on IRET).
            //
            // zdos fires the callback as a bare far-call between debugger commands
            // (the machine is parked mid-program), and `runGuestFarCall` only
            // restores CS:IP/SP. Without preserving the rest, the callback's scratch
            // writes to AX/BX/CX/DX/SI/DI and any DS/ES it establishes would corrupt
            // the parked foreground context — e.g. Betrayal at Krondor's per-frame
            // cursor loop resumes with garbage registers and blits to wrong VRAM
            // offsets (observed as top-of-screen corruption on every injected event).
            // Save the full architectural GP/DS/ES/FLAGS context here, set the
            // callback-ABI inputs, run the handler, then restore — so an injected
            // event is transparent to the interrupted program, exactly as a real IRQ
            // is. The whole GP file (incl. ESP) is captured BEFORE we touch any
            // register; `runGuestFarCall` independently restores ESP to this same
            // pre-call value, so restoring the saved file is consistent (no skew).
            const saved_regs = cpu.st.regs;
            const saved_eflags = cpu.st.eflags;
            const ds = @intFromEnum(Seg.ds);
            const es = @intFromEnum(Seg.es);
            const saved_ds_sel = cpu.st.selector[ds];
            const saved_ds_base = cpu.st.seg_base[ds];
            const saved_es_sel = cpu.st.selector[es];
            const saved_es_base = cpu.st.seg_base[es];
            defer {
                cpu.st.regs = saved_regs;
                cpu.st.eflags = saved_eflags;
                cpu.st.selector[ds] = saved_ds_sel;
                cpu.st.seg_base[ds] = saved_ds_base;
                cpu.st.selector[es] = saved_es_sel;
                cpu.st.seg_base[es] = saved_es_base;
            }

            cpu.st.setReg16(EAX, fire_bits);
            cpu.st.setReg16(EBX, self.buttons & 0x00FF); // BL=buttons, BH=wheel=0
            cpu.st.setReg16(ECX, self.posX());
            cpu.st.setReg16(EDX, self.posY());
            cpu.st.setReg16(ESI, @bitCast(self.mickey_x));
            cpu.st.setReg16(EDI, @bitCast(self.mickey_y));

            // CLEAR IF for the duration of the callback (restored by the `defer`
            // above with the rest of eflags). On real hardware the AX=0Ch sub is
            // reached through the mouse driver's INT 74h/IRQ12 gate, which clears IF
            // on entry. zdos fires it out of band as a bare `runGuestFarCall`, which
            // — unlike an INT — does NOT clear IF, so it inherited the foreground's
            // IF=1 and ran interruptible. That let a hardware IRQ (e.g. the guest's
            // fast timer IRQ0) be ACKNOWLEDGED inside the far-call; if the ack lands
            // on the step that RETFs onto the stop-sentinel, `runGuestFarCall`'s loop
            // exits (reentry_done) and its unconditional CS:IP/SP restore abandons
            // the just-entered ISR before its EOI — stranding the PIC in-service bit,
            // which then blocks all further delivery of that line (the BaK timer
            // deadlock; plans/mouse-callback-irq-strand.md). The host-driven far-call
            // owns no interrupt frame and discharges no EOI, so it MUST NOT permit a
            // maskable IRQ to be delivered inside it; clearing IF closes that window.
            // A pending IRQ simply stays latched in the PIC IRR and is delivered
            // normally once IF is restored on return.
            cpu.st.eflags.iff = false;

            br.runGuestFarCall(self.handler_seg, self.handler_off);
        }

        /// Inject an absolute/relative mouse event AND fire the AX=0Ch event
        /// callback for the resulting transition (input Phase 3, the BaK path). The
        /// FULL inject is applied first (so CX/DX/BL passed to the handler reflect
        /// the final state — BaK just latches them), then ONE far-call carries the
        /// combined condition mask. Captures the pre-inject button state + position
        /// BEFORE mutating so the press/release/move bits are derived from the real
        /// transition. The far-call self-charges its cycles via `runGuestFarCall`.
        pub fn injectAndFire(
            self: *Self,
            cpu: *Cpu,
            br: *Bridge,
            req: InjectReq,
        ) void {
            const old_btn = self.buttons;
            const old_x = self.x;
            const old_y = self.y;

            // Apply absolute first (verbatim range-clamped) then relative (the
            // fixed-point mickey path) — identical ordering to Controller.injectMouse
            // so the firing and non-firing paths can't diverge. Buttons ride with
            // whichever path the caller selected; both write `self.buttons`.
            if (req.set_x or req.set_y) {
                const btn_here = req.set_buttons and !(req.set_dx or req.set_dy);
                self.injectAbsolute(req.x, req.y, req.buttons, req.set_x, req.set_y, btn_here);
            }
            if (req.set_dx or req.set_dy or req.set_buttons) {
                self.injectRelative(req.dx, req.dy, req.buttons, req.set_dx, req.set_dy, req.set_buttons);
            }

            const moved = (self.x != old_x) or (self.y != old_y);
            const condition = conditionMask(old_btn, self.buttons, moved);
            self.fireEventCallback(cpu, br, condition);
        }

        /// Map a normalized Q16 value (0..0x1_0000 == [0,1]) into the virtual range
        /// `[min, max]` with ROUND-TO-NEAREST: `min + (((q16 * span) + 0x8000) >> 16)`
        /// (plans/mouse-input.md LOCKED minor). `span = max - min`. Saturates a q16 at
        /// or above 0x1_0000 to `max` (so a browser nx=1.0 reaches the full edge, not
        /// max-1 from truncation). All integer; no float.
        fn q16ToVirtual(q16: u32, min: i16, max: i16) i16 {
            const span: i64 = @as(i64, max) - @as(i64, min);
            if (span <= 0) return min;
            const q: i64 = @min(@as(i64, q16), @as(i64, 0x1_0000));
            const scaled: i64 = @divTrunc(q * span + 0x8000, 0x1_0000);
            return @intCast(@as(i64, min) + scaled);
        }

        /// LIVE-MOUSE SEAMLESS fold (plans/mouse-input.md §5, LOCKED §1/§2/§3). The
        /// low-latency browser path: the API/worker side coalesces a stream of moves
        /// into ONE sample (`live_mouse.zig`) and forwards it here as PLAIN INTEGERS.
        /// This is the `move_cursor_seamless` analogue (dosbox-staging
        /// mouseif_dos_driver.cpp:1304): the ABSOLUTE position is written DIRECTLY to
        /// the driver's internal position (so AX=03 pollers track the host cursor 1:1),
        /// and the mickeys come from the browser's TRUE relative channel (`movementX/Y`),
        /// fed through the EXISTING `injectRelative` fixed-point path — NOT derived from
        /// the absolute Δ (LOCKED §3 — faithful to dosbox, which uses `x_rel` for the
        /// mickeys and `x_abs` only for position).
        ///
        ///   - `abs_x_q16`/`abs_y_q16`: normalized [0,1] in Q16; the server owns the
        ///     ×range mapping HERE via the driver's LIVE `min/max` (per-mode, so a mode
        ///     change can't desync — LOCKED §2/§7). Applied only when `set_abs`.
        ///   - `dx`/`dy`: the raw summed `movementX/Y` (i32; saturated to i16 for the
        ///     mickey path). Applied only when `set_rel`.
        ///   - `buttons`: latest mask. Applied only when `set_buttons`.
        ///
        /// Fires the AX=0Ch callback ONCE for the combined transition; `moved` is
        /// derived from EITHER a position change OR a mickey-counter change (so a
        /// sub-granularity drag — which moves mickeys without crossing the granularity
        /// mask on `self.x` — still latches EV_MOVED; LOCKED minor). The far-call
        /// self-charges its cycles via `runGuestFarCall` (no ledger hole).
        pub fn injectSeamless(
            self: *Self,
            cpu: *Cpu,
            br: *Bridge,
            req: SeamlessReq,
        ) void {
            const old_btn = self.buttons;
            const old_x = self.x;
            const old_y = self.y;
            const old_mx = self.mickey_x;
            const old_my = self.mickey_y;

            // ABSOLUTE: write the driver's internal position directly (range-clamped,
            // read back verbatim by AX=03). Map Q16 → the driver's LIVE virtual range.
            if (req.set_abs) {
                const xv = q16ToVirtual(req.abs_x_q16, self.min_x, self.max_x);
                const yv = q16ToVirtual(req.abs_y_q16, self.min_y, self.max_y);
                self.injectAbsolute(xv, yv, 0, true, true, false);
            }

            // RELATIVE (the TRUE mickey channel): feed the raw movement deltas through
            // the fixed-point mickey path (AX=0B) — MICKEYS ONLY, never the cursor
            // position (the absolute write above owns position; applying both would
            // double-count the same motion, matching dosbox's seamless split). Saturate
            // i32 → i16 (a single browser movement event over one slice cannot exceed
            // i16; the saturate is just defensive against a pathological summed burst).
            if (req.set_rel) {
                const dx16: i16 = @intCast(std.math.clamp(req.dx, -32768, 32767));
                const dy16: i16 = @intCast(std.math.clamp(req.dy, -32768, 32767));
                self.accumulateMickeys(dx16, dy16);
            }

            // BUTTONS: latest mask (applied once, independent of motion).
            if (req.set_buttons) self.buttons = req.buttons;

            const moved = (self.x != old_x) or (self.y != old_y) or
                (self.mickey_x != old_mx) or (self.mickey_y != old_my);
            const condition = conditionMask(old_btn, self.buttons, moved);
            self.fireEventCallback(cpu, br, condition);
        }

        /// The coalesced live-mouse sample (plain integers — mirrors
        /// `api.LiveMouseState.Fold`). The Q16 absolute is range-agnostic; the relative
        /// deltas are the browser's true `movementX/Y` channel.
        pub const SeamlessReq = struct {
            abs_x_q16: u32 = 0,
            abs_y_q16: u32 = 0,
            dx: i32 = 0,
            dy: i32 = 0,
            buttons: u16 = 0,
            set_abs: bool = false,
            set_rel: bool = false,
            set_buttons: bool = false,
        };

        /// Inject request — mirrors the API `MouseInject` shape so the worker can
        /// forward one POST /api/input/mouse straight through.
        pub const InjectReq = struct {
            x: i16 = 0,
            y: i16 = 0,
            dx: i16 = 0,
            dy: i16 = 0,
            buttons: u16 = 0,
            set_x: bool = false,
            set_y: bool = false,
            set_dx: bool = false,
            set_dy: bool = false,
            set_buttons: bool = false,
        };

        // -------------------------------------------------------------------
        // Snapshot / restore (D14, the mouse-driver state hole closed in input
        // Phase 0). A POD by-value copy of EVERY mutable driver field that lives
        // host-side (NOT in guest RAM): the driver carries no guest-RAM-backed
        // state, so all of it must be captured here. This mirrors the
        // Pic/Pit/Speaker snapshot idiom (POD, byte-serializable, no pointers).
        //
        // SCOPE NOTE: this captures the fields that exist TODAY. The Phase-2
        // relative-motion (mickey) accumulators + counters ARE captured here (the
        // field deferred from Phase 0 — now mutable host-side state). The Phase-3
        // callback re-entrancy flag (`firing`) is DELIBERATELY NOT captured: it is
        // transient, set/cleared within a single `fireEventCallback` that runs to
        // completion synchronously on the worker before the next command, so it is
        // ALWAYS false at any snapshot boundary. Capturing an invariably-false flag
        // would only widen the golden without adding observable state.
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
            // Phase-2 relative-motion state (fixed-point, POD).
            precise_mickey_x: i64,
            precise_mickey_y: i64,
            precise_pixel_x: i64,
            precise_pixel_y: i64,
            mickey_x: i16,
            mickey_y: i16,
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
                .precise_mickey_x = self.precise_mickey_x,
                .precise_mickey_y = self.precise_mickey_y,
                .precise_pixel_x = self.precise_pixel_x,
                .precise_pixel_y = self.precise_pixel_y,
                .mickey_x = self.mickey_x,
                .mickey_y = self.mickey_y,
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
            self.precise_mickey_x = snap.precise_mickey_x;
            self.precise_mickey_y = snap.precise_mickey_y;
            self.precise_pixel_x = snap.precise_pixel_x;
            self.precise_pixel_y = snap.precise_pixel_y;
            self.mickey_x = snap.mickey_x;
            self.mickey_y = snap.mickey_y;
        }
    };
}
