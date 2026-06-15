/* TIMERTK — INT 1Ah BIOS timer-tick services, the DETERMINISTIC round-trip.
 *
 * A bare INT 1Ah AH=00 get-tick read advances with emulated time (the BDA tick
 * at 0040:006C is bumped by the INT 08h handler off the PIT), so its value
 * differs run-to-run and is NOT oracle-able. The deterministic, oracle-able test
 * is to SET the tick to a known CX:DX with AH=01, then GET it back IMMEDIATELY
 * with AH=00 and assert the round-trip — no host clock is read, only the value we
 * just stored (proven stable by double-mint).
 *
 * Semantics matched to references/dosbox-x/src/ints/bios.cpp INT1A_Handler:
 *   AH=00 get: CX = high word of tick, DX = low word, AL = midnight-overflow flag
 *     (then cleared). bios.cpp: reg_cx = mem_readw(BIOS_TIMER+2);
 *     reg_dx = mem_readw(BIOS_TIMER); reg_al = mem_readb(BIOS_24_HOURS_FLAG);
 *     mem_writeb(BIOS_24_HOURS_FLAG, 0). zdos int1a.zig handle AH=00 mirrors this
 *     (CX:DX from BDA tickCount, AL from tickOverflow, then clearTickOverflow).
 *   AH=01 set: mem_writew(BIOS_TIMER, reg_dx); mem_writew(BIOS_TIMER+2, reg_cx);
 *     mem_writeb(BIOS_24_HOURS_FLAG, 0). zdos handle AH=01 sets tickCount from
 *     CX:DX and clears the overflow flag.
 *
 * Because AH=01 also CLEARS the overflow flag, the AH=00 read IMMEDIATELY after a
 * set returns AL=0 deterministically — a known constant, not a host-derived
 * value. We print the recovered CX:DX and the AL flag. Two distinct values are
 * round-tripped to prove it is the stored value (not a fixed echo). No files.
 */
#include <stdio.h>
#include <dos.h>

/* Set the tick to cx:dx via AH=01, then get it back via AH=00. Outputs the
 * recovered CX, DX and the AL overflow flag from the get. */
static void roundtrip(unsigned set_cx, unsigned set_dx,
                      unsigned *got_cx, unsigned *got_dx, unsigned char *al)
{
    union REGS r;

    r.h.ah = 0x01;          /* set tick count from CX:DX */
    r.x.cx = set_cx;
    r.x.dx = set_dx;
    int86(0x1A, &r, &r);

    r.h.ah = 0x00;          /* get tick count -> CX:DX, AL=overflow */
    int86(0x1A, &r, &r);
    *got_cx = r.x.cx;
    *got_dx = r.x.dx;
    *al = r.h.al;
}

int main(void)
{
    unsigned cx, dx;
    unsigned char al;

    /* Known value #1: CX:DX = 0x0012:0x3456 (tick 0x00123456). */
    roundtrip(0x0012, 0x3456, &cx, &dx, &al);
    printf("rt1 cx=%04X dx=%04X al=%02X match=%d\n",
           cx, dx, al, (cx == 0x0012 && dx == 0x3456) ? 1 : 0);

    /* Known value #2: a different tick to prove it's the stored value. */
    roundtrip(0x0000, 0x0001, &cx, &dx, &al);
    printf("rt2 cx=%04X dx=%04X al=%02X match=%d\n",
           cx, dx, al, (cx == 0x0000 && dx == 0x0001) ? 1 : 0);

    /* Known value #3: a near-rollover high tick (still below 0x1800B0). */
    roundtrip(0x0017, 0xFFFF, &cx, &dx, &al);
    printf("rt3 cx=%04X dx=%04X al=%02X match=%d\n",
           cx, dx, al, (cx == 0x0017 && dx == 0xFFFF) ? 1 : 0);

    return 0;
}
