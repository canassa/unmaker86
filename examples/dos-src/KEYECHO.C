/* KEYECHO — a real-mode DOS keyboard-echo loop, the flagship black-box fixture
 * for zdos's debugger keyboard INJECTION path.
 *
 * INPUT: reads keys via the BLOCKING BIOS keyboard service (INT 16h AH=00, reached
 * through Borland's bioskey(0) in <bios.h>). This is the path zdos's API-injected
 * scancodes flow through: 8042 -> IRQ1 -> INT 09h ISR -> BDA ring -> INT 16h. (INT
 * 21h character input — getch()/scanf() — reads a SEPARATE scripted CON-stdin
 * buffer that injected scancodes never reach; verified in src/dos/int21.zig, where
 * AH=01/07/08/0A read dev_table.con, NOT the BDA ring. So bioskey(0) is required.)
 *
 * OUTPUT: echoes each key's ASCII byte to the console via bdos(2, c, 0) — DOS
 * INT 21h AH=02 (direct console output, DL=char). The bytes land in the CON capture
 * buffer the debugger exposes at GET /api/console.
 *
 *   IMPORTANT — why bdos(2,...) and NOT putch(): Borland's conio putch() in text
 *   mode writes DIRECTLY to video RAM and busy-waits on the VGA vertical-retrace
 *   bit at port 0x3DA before each write (to avoid CGA snow). zdos deliberately does
 *   NOT model 0x3DA retrace timing (it is emulated-time-derived and is excluded
 *   from the cross-emulator goldens; see src/devices/vga.zig and io-oracle.md
 *   §1.5), so an unmapped 0x3DA read returns the constant floating-bus 0xFF and
 *   putch()'s "wait for retrace" loop spins forever. putch() output would also
 *   never reach the CON buffer (it bypasses DOS). bdos(2,...) goes straight through
 *   INT 21h to the CON device, so it both terminates and is observable. This is the
 *   one place the task brief's "putch -> INT 21h CON" premise did not hold for the
 *   BCC runtime; the DOS call achieves the same intent faithfully.
 *
 * ESC (ASCII 27): print a '!' marker and return 0, so the program exits cleanly via
 * the DOS terminate path (INT 21h AH=4C, return code 0).
 *
 * Determinism: the loop blocks in the guest-asm INT 16h spin until an injected
 * scancode + IRQ1 unblocks it (no host clock, no fake cycles). The black-box test
 * injects-while-paused then runs a bounded cap, so the same key script yields the
 * same console output every run.
 */
#include <bios.h>
#include <dos.h>

static void con_out(int c)
{
    bdos(2, c, 0);                      /* INT 21h AH=02, DL=c -> CON */
}

int main(void)
{
    for (;;) {
        unsigned k = bioskey(0);        /* INT 16h AH=00 — blocks for a key */
        int a = (int)(k & 0xFF);        /* low byte is the ASCII code */
        if (a == 27) {                  /* ESC */
            con_out('!');               /* print a termination marker */
            break;
        }
        con_out(a);                     /* echo the typed key */
    }
    return 0;                           /* -> INT 21h AH=4C, ret code 0 */
}
