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
 *   IMPORTANT — why bdos(2,...) and NOT putch(): zdos DOES now model the VGA Input
 *   Status Register #1 (port 0x3DA, cycle-derived vertical-retrace/display-enable —
 *   see src/devices/vga.zig statusReg1 / plans/vga-retrace.md), so Borland conio
 *   putch() NO LONGER hangs: a build using real putch() runs end-to-end, blocks on
 *   bioskey, unblocks on an injected key, and terminates cleanly on ESC (ret 0) —
 *   confirmed by tracing. HOWEVER, this BCC-3.1 putch() emits the echoed character
 *   by reading/advancing the cursor via INT 10h (AH=03/AH=02) and then writing the
 *   character byte DIRECTLY to text-mode video RAM at B800:0000 — it does NOT use
 *   INT 21h, nor INT 10h AH=0Eh teletype. zdos models mode-13h graphics VRAM (A000)
 *   but NOT the text-mode video page (B8000) and exposes only the DOS CON device at
 *   GET /api/console, so a real-putch() echo is UNOBSERVABLE (the byte lands in
 *   unmodeled B800 memory and is lost). Making putch echo observable needs a VGA
 *   text-device + console mirror — a separate, larger feature, flagged not faked.
 *   So this fixture keeps bdos(2,...): it goes straight through INT 21h to the CON
 *   device, so the echo both terminates AND is observable by the black-box harness.
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
