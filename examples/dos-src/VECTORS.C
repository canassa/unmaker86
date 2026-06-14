/* VECTORS — install a C interrupt handler on an UNUSED user software interrupt
 * (INT 0x60), invoke it, and prove the getvect/setvect round-trip.
 *
 * INT 0x60 is a documented "user / not used by DOS" vector — nothing in DOS or
 * the BIOS fires it, so triggering it ourselves with geninterrupt(0x60) is
 * fully deterministic (NOT time-driven like INT 1Ch/8).
 *
 * Flow:
 *   1. getvect(0x60) saves whatever vector is there (the default IVT entry).
 *   2. setvect(0x60, my_handler) installs our C handler.
 *   3. getvect(0x60) reads it back and we confirm seg:off == &my_handler.
 *   4. geninterrupt(0x60) x3 -> the handler increments a static marker.
 *   5. restore the saved vector with setvect, read it back, confirm restore.
 *
 * Deterministic output: the marker count and the boolean round-trip checks.
 * The raw handler seg:off is process-load-dependent, so we do NOT print it; we
 * print whether the read-back pointer EQUALS the one we installed (1) — which is
 * what proves AH=25 (set) and AH=35 (get) round-trip through the guest IVT.
 *
 * dos.cpp:759 (AH=25 set vector -> writes IVT) and dos.cpp:916 (AH=35 get
 * vector -> reads IVT). The actual INT 0x60 delivery is pure real-mode IVT
 * dispatch (no DOS involvement).
 */
#include <stdio.h>
#include <dos.h>

static volatile int marker = 0;

/* An 'interrupt' function: BC++ generates the full register save/restore + IRET
 * and (for the handler body) we just bump the marker. We do NOT chain here
 * because INT 0x60's default vector is not a real handler. */
void interrupt my_handler(void)
{
    marker++;
}

int main(void)
{
    void interrupt (*saved)(void);
    void interrupt (*readback)(void);
    int installed_ok, restored_ok;

    /* 1. save the current (default) vector */
    saved = getvect(0x60);

    /* 2. install our handler */
    setvect(0x60, my_handler);

    /* 3. read it back -> must equal what we installed */
    readback = getvect(0x60);
    installed_ok = (readback == my_handler) ? 1 : 0;
    printf("install round-trip = %d\n", installed_ok);

    /* 4. fire INT 0x60 three times -> marker should reach 3 */
    geninterrupt(0x60);
    geninterrupt(0x60);
    geninterrupt(0x60);
    printf("marker = %d\n", marker);

    /* 5. restore the saved vector and confirm */
    setvect(0x60, saved);
    readback = getvect(0x60);
    restored_ok = (readback == saved) ? 1 : 0;
    printf("restore round-trip = %d\n", restored_ok);

    return 0;
}
