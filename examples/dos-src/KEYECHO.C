/* KEYECHO — a real-mode DOS keyboard-echo loop, the flagship black-box fixture
 * for zdos's debugger keyboard INJECTION path AND the text-mode video page.
 *
 * INPUT: reads keys via the BLOCKING BIOS keyboard service (INT 16h AH=00, reached
 * through Borland's bioskey(0) in <bios.h>). This is the path zdos's API-injected
 * scancodes flow through: 8042 -> IRQ1 -> INT 09h ISR -> BDA ring -> INT 16h. (INT
 * 21h character input — getch()/scanf() — reads a SEPARATE scripted CON-stdin
 * buffer that injected scancodes never reach; verified in src/dos/int21.zig, where
 * AH=01/07/08/0A read dev_table.con, NOT the BDA ring. So bioskey(0) is required.)
 *
 * OUTPUT: echoes each key's ASCII byte to the screen via Borland conio putch().
 * BCC-3.1 putch() reads/advances the cursor via INT 10h (AH=03/AH=02) and writes
 * the character byte DIRECTLY to text-mode video RAM at B800:0000 (direct video) —
 * it does NOT use INT 21h, nor INT 10h AH=0Eh teletype. zdos now models the B8000
 * text page (src/devices/vga.zig text_vram + the INT 10h text services), so the
 * echoed byte lands in real, observable text VRAM and the debugger exposes the
 * whole text screen at GET /api/screen. The black-box harness reads /api/screen and
 * asserts the echoed characters appear at the cursor positions putch advanced to.
 *
 * (This fixture previously used a bdos(2,...) INT-21h workaround because the B8000
 * text page was unmodeled and a real putch() echo was unobservable; with the text
 * page modeled, the real putch() path is now the gate.)
 *
 * ESC (ASCII 27): print a '!' marker and return 0, so the program exits cleanly via
 * the DOS terminate path (INT 21h AH=4C, return code 0).
 *
 * Determinism: the loop blocks in the guest-asm INT 16h spin until an injected
 * scancode + IRQ1 unblocks it (no host clock, no fake cycles). putch's direct B800
 * write is charged as a normal guest memory write (the VGA host-pointer fast path,
 * no ledger hole). The black-box test injects-while-paused then runs a bounded cap,
 * so the same key script yields the same text screen every run.
 */
#include <bios.h>
#include <conio.h>

int main(void)
{
    for (;;) {
        unsigned k = bioskey(0);        /* INT 16h AH=00 — blocks for a key */
        int a = (int)(k & 0xFF);        /* low byte is the ASCII code */
        if (a == 27) {                  /* ESC */
            putch('!');                 /* print a termination marker */
            break;
        }
        putch(a);                       /* echo the typed key (direct video) */
    }
    return 0;                           /* -> INT 21h AH=4C, ret code 0 */
}
