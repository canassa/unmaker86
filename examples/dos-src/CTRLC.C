/* CTRLC — INT 23h (Ctrl-C / Ctrl-Break) handler dispatch through the DOS
 * break-check path. This proves the structural DOS-internal interrupt callout
 * that fires when DOS detects a Ctrl-C (0x03) in a character-input call.
 *
 * Background (dosbox-x dos.cpp): the character-input services AH=01 (read+echo),
 * AH=08 (read, no echo), and AH=0A (buffered line) each test the byte they just
 * read: if it is 3 (Ctrl-C), DOS calls DOS_BreakAction() then DOS_BreakTest()
 * (dos.cpp:1130, 1222, 1311). DOS_BreakTest (dos.cpp:652) prints "^C\r\n" to
 * STDOUT, sets the caller's CF, and INVOKES INT 23h (CALLBACK_RunRealInt(0x23)).
 * The installed INT 23h handler then runs as REAL guest code. How it returns
 * decides the outcome (dos.cpp:704-716):
 *   - returns via IRET (SP unchanged) OR with CF clear  -> DOS CONTINUES
 *   - returns via RETF with CF still set                -> DOS TERMINATES (abort)
 * Borland's 'interrupt' keyword emits an IRET frame, so an 'interrupt' handler
 * that simply returns makes DOS CONTINUE — the program is NOT aborted and the
 * input call returns the 0x03 byte in AL like any other character.
 *
 * SCENARIO (deterministic, fully oracle-able):
 *   1. Install a custom INT 23h 'interrupt' handler that sets a global flag and
 *      returns (IRET -> continue). The 'interrupt' prologue loads DS=DGROUP so
 *      the global is reachable (proven by VECTORS.C in this corpus).
 *   2. Read characters one at a time with AH=08 (no echo) from scripted stdin.
 *      The stream is "AB\x03CD\r": when the 0x03 is read, DOS prints "^C\r\n"
 *      and fires our INT 23h handler, which sets the flag and continues; AH=08
 *      then returns AL=3 to us. We keep reading until CR (13).
 *   3. Print: each byte's decimal code, the handler-ran flag, the count of
 *      bytes read, and whether a 0x03 was observed in AL.
 *   4. Restore the original INT 23h vector (good DOS citizenship) and exit with
 *      a deterministic code (0 = ran-and-continued as expected).
 *
 * All printed values are oracle-able and deterministic: the byte codes come from
 * the committed CTRLC.in sidecar, the "^C\r\n" comes from DOS, the flag is set
 * by our own guest handler, and the exit code is computed. The handler/vector
 * seg:off is load-dependent and is NOT printed. No files are created.
 *
 * dosbox-x refs: dos.cpp:652 DOS_BreakTest, dos.cpp:645 DOS_PrintCBreak,
 * dos.cpp:734 DOS_BreakAction, dos.cpp:1218-1227 AH=08 read+break-check.
 */
#include <stdio.h>
#include <dos.h>

/* Set by the INT 23h handler when DOS dispatches it on Ctrl-C. 'volatile'
 * because it is written by an asynchronously-invoked handler. */
static volatile int handler_ran = 0;

/* The Ctrl-C handler. The 'interrupt' attribute makes BC++ emit the register
 * save/restore + IRET (load DS=DGROUP in the prologue). Returning normally
 * (IRET, SP unchanged) tells DOS to CONTINUE the program rather than abort. */
void interrupt ctrlc_isr(void)
{
    handler_ran++;
}

static int read08(void)
{
    union REGS r;
    r.h.ah = 0x08; /* read char from STDIN, no echo, break-checked */
    intdos(&r, &r);
    return r.h.al;
}

int main(void)
{
    void interrupt (*saved23)(void);
    int c, n = 0, saw_ctrlc = 0;

    saved23 = getvect(0x23);
    setvect(0x23, ctrlc_isr);

    printf("bytes:");
    for (;;) {
        c = read08();
        if (c == 13) /* CR ends the stream */
            break;
        printf(" %d", c);
        if (c == 3)
            saw_ctrlc = 1;
        n++;
    }
    printf("\n");

    printf("handler ran = %d\n", handler_ran);
    printf("count = %d\n", n);
    printf("saw ctrlc = %d\n", saw_ctrlc);

    setvect(0x23, saved23); /* restore the original vector */

    /* Deterministic exit code: 0 iff the handler ran AND we continued past the
     * Ctrl-C (observed AL=3 and reached this line without being aborted). */
    return (handler_ran && saw_ctrlc) ? 0 : 1;
}
