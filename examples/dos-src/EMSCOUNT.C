/* EMSCOUNT — handle/page accounting (LIM AH=4B/4C/4D).
 *
 * AH=4B  get handle count        -> BX = number of active EMM handles
 * AH=4C  get pages for a handle  -> BX = pages owned by the handle in DX
 * AH=4D  get pages for all       -> ES:DI = array of {handle,pages} words,
 *                                    BX = number of entries written
 *
 * Allocate two handles (3 pages, then 5 pages) and read the counts back. We
 * print the count BEFORE and AFTER our allocations (so the absolute baseline,
 * which may include an OS/system handle, is recorded by the golden), plus the
 * per-handle page counts and the total pages summed across the AH=4D array.
 */
#include <stdio.h>
#include <dos.h>

#define EMS_INT 0x67

static unsigned handle_count(void)
{
    union REGS r;
    r.h.ah = 0x4B;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) return 0xFFFF;
    return r.x.bx;
}

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned base_count, after_count;
    unsigned h1, h2, pages1, pages2;
    unsigned entries, sumpages, i;
    static unsigned table[64];       /* {handle,pages} pairs */

    base_count = handle_count();

    /* allocate handle #1 with 3 pages */
    r.h.ah = 0x43; r.x.bx = 3;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc1 err %02X\n", r.h.ah); return 1; }
    h1 = r.x.dx;

    /* allocate handle #2 with 5 pages */
    r.h.ah = 0x43; r.x.bx = 5;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc2 err %02X\n", r.h.ah); return 2; }
    h2 = r.x.dx;

    after_count = handle_count();

    /* AH=4C pages for each handle */
    r.h.ah = 0x4C; r.x.dx = h1;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("pages1 err %02X\n", r.h.ah); return 3; }
    pages1 = r.x.bx;

    r.h.ah = 0x4C; r.x.dx = h2;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("pages2 err %02X\n", r.h.ah); return 4; }
    pages2 = r.x.bx;

    /* AH=4D pages for all handles -> table at ES:DI */
    segread(&s);
    r.h.ah = 0x4D;
    r.x.di = (unsigned)table;
    s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("all err %02X\n", r.h.ah); return 5; }
    entries = r.x.bx;
    sumpages = 0;
    for (i = 0; i < entries && i < 64; i++) sumpages += table[i * 2 + 1];

    printf("base=%04X after=%04X\n", base_count, after_count);
    printf("h1pages=%04X h2pages=%04X\n", pages1, pages2);
    printf("entries=%04X sumpages=%04X\n", entries, sumpages);

    /* release both handles */
    r.h.ah = 0x45; r.x.dx = h1; int86(EMS_INT, &r, &r);
    r.h.ah = 0x45; r.x.dx = h2; int86(EMS_INT, &r, &r);
    return 0;
}
