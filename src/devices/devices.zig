//! `src/devices/` module root. Self-registering programmable devices (8259 PIC,
//! 8254 PIT, later VGA/SB/...). Devices import only the bus contract leaf + the
//! bus module's public handler interfaces (module graph: devices <- bus contract);
//! they never import `cpu` or `machine`.

pub const pic = @import("pic.zig");
pub const pit = @import("pit.zig");
pub const vga = @import("vga.zig");
pub const vga_render = @import("vga_render.zig");
pub const speaker = @import("speaker.zig");
pub const keyboard = @import("keyboard.zig");

pub const Pic = pic.Pic;
pub const Pit = pit.Pit;
pub const Vga = vga.Vga;
pub const Speaker = speaker.Speaker;
pub const Keyboard = keyboard.Keyboard;

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
