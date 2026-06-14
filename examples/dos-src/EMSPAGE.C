/* EMSPAGE — deep EMS handle/page queries + page-map save/restore re-entrancy
 * (LIM AH=4B/4C/4D and AH=4E), band 15. Extends EMSCOUNT (which only reads the
 * counts) and EMSSAVE (a single-handle save/restore) into ONE program that
 * proves the page-map save/restore is the re-entrancy primitive a real ISR
 * would use: save the live window mapping, freely remap to a DIFFERENT logical
 * page (window content changes), then restore and confirm the ORIGINAL page's
 * data is back through the frame window.
 *
 * dosbox-x semantics matched (references/dosbox-x/src/ints/ems.cpp):
 *   AH=4B  Get Handle Count        ems.cpp:1008  -> BX = active handles
 *   AH=4C  Get Pages for one Handle ems.cpp:1013 -> BX = pages of handle DX
 *   AH=4D  Get Pages for all Handles ems.cpp:1018/696 -> ES:DI array of
 *                                    {handle:u16, pages:u16}, BX = entry count
 *   AH=4E AL=03 Get Page Map Size   ems.cpp:1036 -> AL = sizeof(emm_mappings)=16
 *   AH=4E AL=00 Save Page Map       ems.cpp:1023 -> blockwrite emm_mappings to ES:DI
 *   AH=4E AL=01 Restore Page Map    ems.cpp:1027 -> blockread emm_mappings from DS:SI
 *
 * Board mode (oracle pins xms=false -> EMS_BOARD): no OS system handle, so the
 * baseline active-handle count is 0 and our two handles become handle 0 and 1.
 *
 * Sequence:
 *   alloc H1 (3 pages), H2 (5 pages)
 *   AH=4B count            -> 2
 *   AH=4C pages(H1), pages(H2) -> 3, 5
 *   AH=4D all-handles array -> 2 entries, sumpages 8
 *   AH=4E AL=03 mapsize    -> 10 (=16 dec)
 *   map H1 logical page 0 -> frame slot 0; write marker A (0x5A..)
 *   map H2 logical page 2 -> frame slot 1; write marker B (0xB2..)
 *   AH=4E AL=00 SAVE the live two-slot map
 *   remap slot 0 to H1 page 1, slot 1 to H2 page 4 (window now shows OTHER pages)
 *   write fresh data so the windows definitely changed; read back to prove it
 *   AH=4E AL=01 RESTORE -> slot0 back to H1 p0, slot1 back to H2 p2
 *   read both windows -> original markers A and B must be back (re-entrancy proof)
 *   free H1, H2
 */
#include <stdio.h>
#include <dos.h>

#define EMS_INT 0x67

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned frame, h1, h2, count, p1, p2, entries, sumpages, mapsize, i;
    unsigned char far *win0;     /* frame slot 0 window */
    unsigned char far *win1;     /* frame slot 1 window */
    static unsigned table[64];   /* AH=4D {handle,pages} pairs */
    static unsigned char map[64];/* AH=4E page-map save buffer */

    /* page-frame segment (AH=41) */
    r.h.ah = 0x41; int86(EMS_INT, &r, &r);
    frame = r.x.bx;
    win0 = (unsigned char far *)MK_FP(frame, 0);
    win1 = (unsigned char far *)MK_FP(frame, 0x4000);  /* slot 1 = +16 KiB */

    /* allocate H1 = 3 pages, H2 = 5 pages */
    r.h.ah = 0x43; r.x.bx = 3; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc1 err %02X\n", r.h.ah); return 1; }
    h1 = r.x.dx;
    r.h.ah = 0x43; r.x.bx = 5; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc2 err %02X\n", r.h.ah); return 2; }
    h2 = r.x.dx;

    /* AH=4B handle count */
    r.h.ah = 0x4B; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("count err %02X\n", r.h.ah); return 3; }
    count = r.x.bx;

    /* AH=4C pages for each handle */
    r.h.ah = 0x4C; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("p1 err %02X\n", r.h.ah); return 4; }
    p1 = r.x.bx;
    r.h.ah = 0x4C; r.x.dx = h2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("p2 err %02X\n", r.h.ah); return 5; }
    p2 = r.x.bx;

    /* AH=4D pages for all handles -> table at ES:DI */
    segread(&s);
    r.h.ah = 0x4D; r.x.di = (unsigned)table; s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("all err %02X\n", r.h.ah); return 6; }
    entries = r.x.bx;
    sumpages = 0;
    for (i = 0; i < entries && i < 64; i++) sumpages += table[i * 2 + 1];

    /* AH=4E AL=03 page-map array size */
    r.h.ah = 0x4E; r.h.al = 0x03; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("size err %02X\n", r.h.ah); return 7; }
    mapsize = r.h.al;

    printf("count=%04X p1=%04X p2=%04X\n", count, p1, p2);
    printf("entries=%04X sumpages=%04X mapsize=%02X\n", entries, sumpages, mapsize);

    /* map H1 page 0 -> slot 0, H2 page 2 -> slot 1; write distinct markers */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 0; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("map00 err %02X\n", r.h.ah); return 8; }
    r.h.ah = 0x44; r.h.al = 1; r.x.bx = 2; r.x.dx = h2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("map12 err %02X\n", r.h.ah); return 9; }
    for (i = 0; i < 8; i++) win0[i] = (unsigned char)(0x5A + i);
    for (i = 0; i < 8; i++) win1[i] = (unsigned char)(0xB2 + i);

    printf("orig:");
    for (i = 0; i < 4; i++) printf(" %02X", win0[i]);
    for (i = 0; i < 4; i++) printf(" %02X", win1[i]);
    printf("\n");

    /* AH=4E AL=00 SAVE the live page map (ES:DI) */
    segread(&s);
    r.h.ah = 0x4E; r.h.al = 0x00; r.x.di = (unsigned)map; s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("save err %02X\n", r.h.ah); return 10; }

    /* remap to DIFFERENT logical pages: slot0 <- H1 p1, slot1 <- H2 p4 */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 1; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("rmap01 err %02X\n", r.h.ah); return 11; }
    r.h.ah = 0x44; r.h.al = 1; r.x.bx = 4; r.x.dx = h2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("rmap14 err %02X\n", r.h.ah); return 12; }
    /* write fresh data through the new windows so they CANNOT alias the saved
     * pages — proves the windows really changed before the restore. */
    for (i = 0; i < 8; i++) win0[i] = (unsigned char)(0x10 + i);
    for (i = 0; i < 8; i++) win1[i] = (unsigned char)(0x90 + i);

    printf("remap:");
    for (i = 0; i < 4; i++) printf(" %02X", win0[i]);
    for (i = 0; i < 4; i++) printf(" %02X", win1[i]);
    printf("\n");

    /* AH=4E AL=01 RESTORE the saved page map (DS:SI) */
    segread(&s);
    r.h.ah = 0x4E; r.h.al = 0x01; r.x.si = (unsigned)map;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("restore err %02X\n", r.h.ah); return 13; }

    /* windows must show the ORIGINAL markers again (re-entrancy proof) */
    printf("restd:");
    for (i = 0; i < 4; i++) printf(" %02X", win0[i]);
    for (i = 0; i < 4; i++) printf(" %02X", win1[i]);
    printf("\n");

    /* free both handles, re-check the count drops back to 0 */
    r.h.ah = 0x45; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("free1 err %02X\n", r.h.ah); return 14; }
    r.h.ah = 0x45; r.x.dx = h2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("free2 err %02X\n", r.h.ah); return 15; }

    r.h.ah = 0x4B; int86(EMS_INT, &r, &r);
    printf("final=%04X\n", r.x.bx);
    return 0;
}
