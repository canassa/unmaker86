/* MOUSERB — mouse-injection READ-BACK fixture for the zdos debugger black-box
 * test. Unlike MOUSE1 (which SETS its own position then reads it), MOUSERB never
 * sets the position: it loops reading the live INT 33h driver state with AX=0003
 * (Get Position & Buttons) and stores the result to a FIXED, observable memory
 * location, so the debugger can inject a position over POST /api/input/mouse and
 * then read it back over GET /api/mem.
 *
 * Storage layout, at the fixed far address 0x0050:0000 (linear 0x500 — the DOS
 * "inter-application communication area", unused by this program):
 *   +0 word  X position (AX=0003 CX)
 *   +2 word  Y position (AX=0003 DX)
 *   +4 word  button mask (AX=0003 BX)
 *   +6 word  a monotone "I ran AX=0003 again" tick (so the test can confirm the
 *            loop is live across runs)
 * The address 0x500 is below the program (PSP is higher), is real guest RAM the
 * API reads with GET /api/mem?phys=1280, and is never touched by DOS during this
 * loop.
 *
 * TERMINATION: the loop exits when ANY mouse button is down (BX != 0), so the
 * black-box test ends the program deterministically by injecting a button mask.
 * It also bails after a large bounded iteration count (a safety net so it can
 * never hang the test harness; never reached in the scripted flow).
 *
 * Determinism: INT 33h driver state is a pure machine-model value (no host
 * pointer); the API injection mutates it at the one-command boundary and the next
 * run's AX=0003 observes exactly the injected value. No host clock, no files.
 */
#include <dos.h>

/* The fixed observation area at 0x0050:0000. */
#define OBS_SEG 0x0050

static void put_word(unsigned off, unsigned val)
{
    pokeb(OBS_SEG, off, (unsigned char)(val & 0xFF));
    pokeb(OBS_SEG, off + 1, (unsigned char)((val >> 8) & 0xFF));
}

int main(void)
{
    union REGS r;
    unsigned long i;
    unsigned tick = 0;

    for (i = 0; i < 200000UL; i++) {
        r.x.ax = 0x0003;            /* INT 33h AX=0003 get pos + buttons */
        int86(0x33, &r, &r);
        put_word(0, r.x.cx);        /* X */
        put_word(2, r.x.dx);        /* Y */
        put_word(4, r.x.bx);        /* buttons */
        put_word(6, ++tick);        /* liveness tick */
        if (r.x.bx != 0)            /* any button down -> exit */
            break;
    }
    return 0;
}
