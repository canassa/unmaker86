/* EMSSAVE — page-map save/restore (LIM AH=4E).
 *
 * AH=4E AL=03  get page-map array size -> AL = bytes
 * AH=4E AL=00  save current page map   -> ES:DI buffer
 * AH=4E AL=01  restore page map        <- DS:SI buffer
 *
 * Proof: allocate 2 pages, map logical page 0 into frame slot 0, write a
 * marker. Map logical page 1 in (window now shows page 1's contents). SAVE the
 * page map (which records "slot 0 -> page 0" was NOT current — current is page
 * 1). Actually we save AFTER mapping page 0, then remap to page 1, then RESTORE
 * and confirm the window shows page 0's marker again.
 *
 * Sequence:
 *   map page0 -> slot0; write 0x5A.. ; map page0 again to be the saved state
 *   SAVE map         (records slot0 -> page0)
 *   map page1 -> slot0; write 0xC3.. ; window now shows page1
 *   RESTORE map      (slot0 -> page0 again)
 *   read window      -> must show page0's 0x5A.. marker
 */
#include <stdio.h>
#include <dos.h>

#define EMS_INT 0x67

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned frame, handle, mapsize, i;
    unsigned char far *win;
    static unsigned char buf[256];

    /* page-frame segment */
    r.h.ah = 0x41; int86(EMS_INT, &r, &r);
    frame = r.x.bx;
    win = (unsigned char far *)MK_FP(frame, 0);

    /* page-map array size */
    r.h.ah = 0x4E; r.h.al = 0x03;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("size err %02X\n", r.h.ah); return 1; }
    mapsize = r.h.al;

    /* allocate 2 pages */
    r.h.ah = 0x43; r.x.bx = 2;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc err %02X\n", r.h.ah); return 2; }
    handle = r.x.dx;

    /* map page0 -> slot0, write marker A */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 0; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    for (i = 0; i < 16; i++) win[i] = (unsigned char)(0x5A + i);

    /* SAVE current page map (slot0 -> page0) */
    segread(&s);
    r.h.ah = 0x4E; r.h.al = 0x00;
    r.x.di = (unsigned)buf;
    s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("save err %02X\n", r.h.ah); return 3; }

    /* map page1 -> slot0, write marker B (window now shows page1) */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 1; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    for (i = 0; i < 16; i++) win[i] = (unsigned char)(0xC3 + i);

    printf("before:");
    for (i = 0; i < 4; i++) printf(" %02X", win[i]);
    printf("\n");

    /* RESTORE page map (slot0 -> page0 again) */
    segread(&s);                      /* s.ds = our data segment, where buf lives */
    r.h.ah = 0x4E; r.h.al = 0x01;
    r.x.si = (unsigned)buf;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("restore err %02X\n", r.h.ah); return 4; }

    printf("after:");
    for (i = 0; i < 4; i++) printf(" %02X", win[i]);
    printf("\n");

    printf("mapsize=%02X\n", mapsize);

    r.h.ah = 0x45; r.x.dx = handle; int86(EMS_INT, &r, &r);
    return 0;
}
