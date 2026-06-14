//! INT 33h — the mouse DRIVER (D18, host-serviced trap, owned HERE not the device
//! half). Reads raw motion/buttons from the mouse *device* via the same scripted-
//! input seam as the keyboard (deterministic external input), never the host.
//! Driver state (position, button mask, visibility, the installed event handler
//! far-ptr) is snapshot state (D14).

const std = @import("std");
const Reg32 = @import("cpu").state.Reg32;

const ECX = @intFromEnum(Reg32.ecx);
const EDX = @intFromEnum(Reg32.edx);
const EBX = @intFromEnum(Reg32.ebx);
const EAX = @intFromEnum(Reg32.eax);

pub fn Int33(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        const Dos = @import("dos.zig").Dos(Cpu);
        const Bridge = @import("bridge").Bridge(Cpu);

        present: bool = true,
        x: u16 = 0,
        y: u16 = 0,
        buttons: u16 = 0, // bit0=left, bit1=right, bit2=middle
        visible: bool = false,
        /// Installed event handler far pointer (seg:off) + event mask.
        handler_seg: u16 = 0,
        handler_off: u16 = 0,
        handler_mask: u16 = 0,

        pub fn service(self: *Self, dos: *Dos, cpu: *Cpu, br: *Bridge) void {
            const ax = cpu.st.getReg16(EAX);
            switch (ax) {
                0x0000 => { // reset + get status -> AX=0xFFFF present, BX=button count
                    cpu.st.setReg16(EAX, if (self.present) 0xFFFF else 0x0000);
                    cpu.st.setReg16(EBX, 2); // 2-button mouse
                    self.x = 0;
                    self.y = 0;
                    self.buttons = 0;
                    self.visible = false;
                    self.handler_seg = 0;
                    self.handler_off = 0;
                    self.handler_mask = 0;
                },
                0x0001 => self.visible = true, // show cursor
                0x0002 => self.visible = false, // hide cursor
                0x0003 => { // get position + button state -> CX=x, DX=y, BX=buttons
                    cpu.st.setReg16(ECX, self.x);
                    cpu.st.setReg16(EDX, self.y);
                    cpu.st.setReg16(EBX, self.buttons);
                },
                0x0004 => { // set position from CX=x, DX=y
                    self.x = cpu.st.getReg16(ECX);
                    self.y = cpu.st.getReg16(EDX);
                },
                0x000C => { // set event handler: CX=mask, ES:DX=handler
                    self.handler_mask = cpu.st.getReg16(ECX);
                    self.handler_seg = cpu.st.selector[@intFromEnum(@import("cpu").state.Seg.es)];
                    self.handler_off = cpu.st.getReg16(EDX);
                },
                0x0014 => { // swap event handler: return the old one in CX/ES:DX
                    const old_mask = self.handler_mask;
                    const old_seg = self.handler_seg;
                    const old_off = self.handler_off;
                    self.handler_mask = cpu.st.getReg16(ECX);
                    self.handler_seg = cpu.st.selector[@intFromEnum(@import("cpu").state.Seg.es)];
                    self.handler_off = cpu.st.getReg16(EDX);
                    cpu.st.setReg16(ECX, old_mask);
                    cpu.loadSegment(.es, old_seg);
                    cpu.st.setReg16(EDX, old_off);
                },
                else => dos.unsupported(cpu, br, 0x33),
            }
        }

        /// Inject a scripted mouse event (deterministic external input seam).
        pub fn injectMotion(self: *Self, x: u16, y: u16, buttons: u16) void {
            self.x = x;
            self.y = y;
            self.buttons = buttons;
        }
    };
}
