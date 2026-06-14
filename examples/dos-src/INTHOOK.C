/* INTHOOK — install a REAL guest ISR on a free user software-interrupt vector,
 * dispatch it via int86 with a register frame, and prove the ISR ran guest code
 * that read its INPUT registers and wrote an OUTPUT register that int86 reads
 * back. This exercises the CORE interrupt-dispatch path (CD nn -> IVT ->
 * guest handler -> IRET -> caller), not just IVT memory get/set.
 *
 * This EXTENDS VECTORS.C (which proves the getvect/setvect round-trip and a
 * marker-counting handler fired by geninterrupt). The new, high-value coverage
 * here is the REGISTER-FRAME round trip: the ISR computes a value FROM the
 * registers the caller passed IN, and the caller observes the result OUT — which
 * only works if the CPU faithfully (a) pushes FLAGS/CS/IP, (b) jumps to the
 * guest-installed CS:IP, (c) lets the guest code run with the caller's AX/BX/CX,
 * and (d) IRETs so the 'interrupt'-function's restored AX flows back to int86.
 *
 * Borland's 'interrupt' keyword generates the full pusha/IRET frame and exposes
 * the pushed registers as PARAMETERS. Assigning to the AX parameter changes the
 * value popped back into AX on IRET, which int86 then returns in outregs. This
 * is the robust deterministic design called out in the band brief (no reliance
 * on the ISR loading DS to touch a C global).
 *
 * INT 0x61 is a free user software-interrupt vector (DOS/BIOS never fire it;
 * 0x60-0x66 are documented "user / not used"). Triggering it ourselves with
 * int86(0x61, ...) is fully deterministic (NOT time-driven like INT 8/1Ch).
 *
 * Also covered:
 *   - AH=33 Ctrl-Break flag get/set/get round trip (dos.cpp:1796-1801:
 *     AL=00 get -> DL, AL=01 set <- DL).
 *   - INT 24h critical-error vector store (AH=25) + read-back (AH=35). We only
 *     prove the vector round-trip a program does at startup; we do NOT provoke a
 *     real critical error (the audit calls a forced critical error mostly-moot
 *     on the VFS). All vectors are restored before exit (good DOS citizenship).
 *
 * dos.cpp:759 (AH=25 set vector -> writes IVT), dos.cpp:916 (AH=35 get vector
 * -> reads IVT), dos.cpp:1796 (AH=33 break check). The INT 0x61 delivery itself
 * is pure real-mode IVT dispatch (no DOS involvement).
 *
 * Only oracle-able values are printed (computed register results, the boolean
 * round-trip checks, the break flag). The raw handler/vector seg:off is
 * process-load-dependent, so we print only whether the read-back EQUALS what we
 * stored. No files are created.
 */
#include <stdio.h>
#include <dos.h>

/* The ISR: read the caller's BX and CX (passed IN via int86), write their sum
 * back into AX (read OUT by int86 after IRET). The 'interrupt' attribute makes
 * BC++ emit the register save/restore + IRET; the named parameters are the
 * pushed register image, and assigning to `ax` sets the value IRET pops. */
void interrupt add_isr(unsigned bp, unsigned di, unsigned si, unsigned ds,
                       unsigned es, unsigned dx, unsigned cx, unsigned bx,
                       unsigned ax)
{
    /* silence "parameter not used" for the ones we don't touch */
    (void)bp; (void)di; (void)si; (void)ds; (void)es; (void)dx;
    ax = bx + cx;   /* OUT = IN.bx + IN.cx — flows back to int86 outregs.x.ax */
}

int main(void)
{
    void interrupt (*saved61)(void);
    void interrupt (*readback)(void);
    void interrupt (*saved24)(void);
    void interrupt (*rb24)(void);
    union REGS inregs, outregs;
    int installed_ok, restored_ok, isr_ok;
    int br_after_set, br_restored;
    int v24_stored_ok, v24_restored_ok;
    unsigned char saved_break;

    /* ---- 1. guest-installed-ISR register-frame dispatch (INT 0x61) ---- */
    saved61 = getvect(0x61);
    setvect(0x61, add_isr);

    readback = getvect(0x61);
    installed_ok = (readback == add_isr) ? 1 : 0;
    printf("install round-trip = %d\n", installed_ok);

    /* Pass BX=1000, CX=337 in; the ISR must return AX=1337. */
    inregs.x.ax = 0;
    inregs.x.bx = 1000;
    inregs.x.cx = 337;
    int86(0x61, &inregs, &outregs);
    isr_ok = (outregs.x.ax == 1337) ? 1 : 0;
    printf("isr ax result = %u\n", outregs.x.ax);
    printf("isr dispatch ok = %d\n", isr_ok);

    /* Fire again with different inputs to prove it's re-entrant/repeatable. */
    inregs.x.bx = 40;
    inregs.x.cx = 2;
    int86(0x61, &inregs, &outregs);
    printf("isr ax result 2 = %u\n", outregs.x.ax);

    /* restore + confirm */
    setvect(0x61, saved61);
    readback = getvect(0x61);
    restored_ok = (readback == saved61) ? 1 : 0;
    printf("restore round-trip = %d\n", restored_ok);

    /* ---- 2. AH=33 Ctrl-Break flag get / set / get round trip ---- */
    inregs.h.ah = 0x33;             /* get current break flag */
    inregs.h.al = 0x00;
    int86(0x21, &inregs, &outregs);
    saved_break = outregs.h.dl;     /* remember it to restore later */

    inregs.h.ah = 0x33;             /* set break flag = 1 */
    inregs.h.al = 0x01;
    inregs.h.dl = 1;
    int86(0x21, &inregs, &outregs);

    inregs.h.ah = 0x33;             /* read it back */
    inregs.h.al = 0x00;
    int86(0x21, &inregs, &outregs);
    br_after_set = outregs.h.dl;
    printf("break flag after set = %d\n", br_after_set);

    inregs.h.ah = 0x33;             /* restore original */
    inregs.h.al = 0x01;
    inregs.h.dl = saved_break;
    int86(0x21, &inregs, &outregs);

    inregs.h.ah = 0x33;             /* confirm restore */
    inregs.h.al = 0x00;
    int86(0x21, &inregs, &outregs);
    br_restored = (outregs.h.dl == saved_break) ? 1 : 0;
    printf("break flag restored = %d\n", br_restored);

    /* ---- 3. INT 24h critical-error vector store + read-back ---- */
    saved24 = getvect(0x24);            /* AH=35 */
    setvect(0x24, add_isr);             /* AH=25: store our routine */
    rb24 = getvect(0x24);               /* AH=35: read it back */
    v24_stored_ok = (rb24 == add_isr) ? 1 : 0;
    printf("int24 store round-trip = %d\n", v24_stored_ok);

    setvect(0x24, saved24);             /* restore the original handler */
    rb24 = getvect(0x24);
    v24_restored_ok = (rb24 == saved24) ? 1 : 0;
    printf("int24 restore round-trip = %d\n", v24_restored_ok);

    return 0;
}
