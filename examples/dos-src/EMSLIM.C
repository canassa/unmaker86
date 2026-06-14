/* EMSLIM — LIM EMS 4.0 extensions (band 16): bulk map/unmap, reallocate, the
 * per-handle save/restore page map, and handle names. Extends EMSPAGE (which
 * covered AH=4B/4C/4D/4E) into the LIM 4.0 surface a real expanded-memory
 * manager touches.
 *
 * dosbox-x semantics matched (references/dosbox-x/src/ints/ems.cpp):
 *   AH=50 AL=00  Map Multiple Pages by LOGICAL/PHYSICAL number  ems.cpp:1049
 *                DS:SI -> CX * {logical_page:u16, physical_page:u16};
 *                a logical_page of 0xFFFF UNMAPS that physical slot
 *                (EMM_MapPage with log==NULL_PAGE, ems.cpp:519).
 *   AH=50 AL=01  Map Multiple Pages by LOGICAL/SEGMENT          ems.cpp:1061
 *                DS:SI -> CX * {logical_page:u16, segment:u16};
 *                segment = page-frame + slot*0x400 (EMM_MapSegment, ems.cpp:551).
 *   AH=47        Save Page Map (by handle)                      ems.cpp:448
 *   AH=48        Restore Page Map (by handle)                   ems.cpp:477
 *   AH=51        Reallocate Pages (BX = new count)              ems.cpp:1076
 *                grows/shrinks the handle; the free pool changes by the delta.
 *   AH=53 AL=01  Set Handle Name (DS:SI -> 8 bytes)             ems.cpp:812
 *   AH=53 AL=00  Get Handle Name (ES:DI <- 8 bytes)            ems.cpp:808
 *   AH=54 AL=00  Get All Handle Names (ES:DI <- {handle,name8}) ems.cpp:770
 *                AL = count of active handles
 *   AH=54 AL=01  Search for a handle by name (DS:SI -> 8 bytes) ems.cpp:781
 *                returns DX = handle, or AH=0xA0 (not found)
 *
 * Board mode (oracle pins xms=false -> EMS_BOARD): no OS system handle, so the
 * baseline active-handle count is 0 and the handles allocated here become 0/1.
 *
 * Everything printed is oracle-able: return codes, free-page counts (deltas from
 * the deterministic REPORTED total minus user-allocated pages), the bytes read
 * back through mapped windows (deterministic given the bump allocator + zero-init
 * backing), the handle-name round-trip (program-supplied strings), and the
 * search/enumerate results. No host-clock values are touched. The program
 * creates no files.
 */
#include <stdio.h>
#include <string.h>
#include <dos.h>

#define EMS_INT 0x67

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned frame, h1, h2, i, free0, free1, free2, found, names;
    unsigned char far *win[4];
    static unsigned maparr[16];   /* AH=50 {logical,physical|segment} pairs */
    static unsigned char name[16];/* name buffers */
    static unsigned char dir[128];/* AH=54 enumerate buffer */

    /* page-frame segment (AH=41); window pointers for the 4 frame slots */
    r.h.ah = 0x41; int86(EMS_INT, &r, &r);
    frame = r.x.bx;
    for (i = 0; i < 4; i++)
        win[i] = (unsigned char far *)MK_FP(frame, (unsigned)(i * 0x4000));

    /* free pool before any allocation */
    r.h.ah = 0x42; int86(EMS_INT, &r, &r);
    free0 = r.x.bx;

    /* allocate H1 = 4 pages, H2 = 2 pages */
    r.h.ah = 0x43; r.x.bx = 4; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc1 err %02X\n", r.h.ah); return 1; }
    h1 = r.x.dx;
    r.h.ah = 0x43; r.x.bx = 2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc2 err %02X\n", r.h.ah); return 2; }
    h2 = r.x.dx;

    /* free pool after alloc (drops by 4+2=6) */
    r.h.ah = 0x42; int86(EMS_INT, &r, &r);
    free1 = r.x.bx;
    printf("free0=%04X free1=%04X drop=%04X\n", free0, free1, free0 - free1);

    /* ---- AH=50 AL=00: BULK MAP by logical/physical page number ----
     * Map H1 logical pages 0,1,2,3 into physical slots 0,1,2,3 in ONE call. */
    for (i = 0; i < 4; i++) { maparr[i * 2] = i; maparr[i * 2 + 1] = i; }
    segread(&s);
    r.h.ah = 0x50; r.h.al = 0x00; r.x.cx = 4; r.x.dx = h1; r.x.si = (unsigned)maparr;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("bulkmap err %02X\n", r.h.ah); return 3; }

    /* write a distinct pattern through each window, then read back to confirm the
     * bulk map took effect across all four slots */
    for (i = 0; i < 4; i++) win[i][0] = (unsigned char)(0xA0 + i * 0x11);
    printf("bulk:");
    for (i = 0; i < 4; i++) printf(" %02X", win[i][0]);
    printf("\n");

    /* ---- AH=47 SAVE the page map for H1, then remap, then AH=48 RESTORE ---- */
    r.h.ah = 0x47; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("save err %02X\n", r.h.ah); return 4; }

    /* remap slot 0 to H1 page 3 (window now shows page 3's byte, 0xD3) */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 3; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("remap err %02X\n", r.h.ah); return 5; }
    printf("remap0=%02X\n", win[0][0]);

    r.h.ah = 0x48; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("restore err %02X\n", r.h.ah); return 6; }
    printf("restd0=%02X\n", win[0][0]);  /* must be 0xA0 again */

    /* ---- AH=50 AL=01: BULK MAP by logical/segment ----
     * Map H2 pages 0,1 into slots 2,3 using the segment form. Slot s segment is
     * frame + s*0x400. First UNMAP slots 2,3 via the logical=0xFFFF sentinel in
     * the SAME bulk call to prove unmap-by-bulk works, then map. */
    maparr[0] = 0xFFFF; maparr[1] = frame + 2 * 0x400; /* unmap slot 2 */
    maparr[2] = 0xFFFF; maparr[3] = frame + 3 * 0x400; /* unmap slot 3 */
    segread(&s);
    r.h.ah = 0x50; r.h.al = 0x01; r.x.cx = 2; r.x.dx = h2; r.x.si = (unsigned)maparr;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("bulkunmap err %02X\n", r.h.ah); return 7; }

    maparr[0] = 0; maparr[1] = frame + 2 * 0x400;      /* H2 page 0 -> slot 2 */
    maparr[2] = 1; maparr[3] = frame + 3 * 0x400;      /* H2 page 1 -> slot 3 */
    segread(&s);
    r.h.ah = 0x50; r.h.al = 0x01; r.x.cx = 2; r.x.dx = h2; r.x.si = (unsigned)maparr;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("bulkseg err %02X\n", r.h.ah); return 8; }
    win[2][0] = 0x22; win[3][0] = 0x33;
    printf("seg: %02X %02X\n", win[2][0], win[3][0]);

    /* ---- AH=51 REALLOCATE: grow H2 2 -> 5 (free pool drops 3 more) ---- */
    r.h.ah = 0x51; r.x.dx = h2; r.x.bx = 5; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("grow err %02X\n", r.h.ah); return 9; }
    r.h.ah = 0x4C; r.x.dx = h2; int86(EMS_INT, &r, &r);  /* confirm new count */
    printf("grown pages=%04X\n", r.x.bx);
    r.h.ah = 0x42; int86(EMS_INT, &r, &r);
    free2 = r.x.bx;
    printf("free2=%04X growdrop=%04X\n", free2, free1 - free2);  /* = 3 */

    /* grown H2's existing pages 0,1 must still be readable through slots 2,3 */
    printf("kept: %02X %02X\n", win[2][0], win[3][0]);  /* 0x22 0x33 */

    /* ---- AH=51 REALLOCATE: shrink H2 5 -> 1 (free pool rises by 4) ---- */
    r.h.ah = 0x51; r.x.dx = h2; r.x.bx = 1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("shrink err %02X\n", r.h.ah); return 10; }
    r.h.ah = 0x4C; r.x.dx = h2; int86(EMS_INT, &r, &r);
    printf("shrunk pages=%04X\n", r.x.bx);
    r.h.ah = 0x42; int86(EMS_INT, &r, &r);
    printf("freeS=%04X rise=%04X\n", r.x.bx, r.x.bx - free2);  /* rise = 4 */

    /* ---- AH=53 handle names: set H1's name, read it back ---- */
    memcpy(name, "KRONDOR\0", 8);
    segread(&s);
    r.h.ah = 0x53; r.h.al = 0x01; r.x.dx = h1; r.x.si = (unsigned)name; /* set */
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("setname err %02X\n", r.h.ah); return 11; }

    memset(name, 0, 16);
    segread(&s);
    r.h.ah = 0x53; r.h.al = 0x00; r.x.dx = h1; r.x.di = (unsigned)name; s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    if (r.h.ah != 0) { printf("getname err %02X\n", r.h.ah); return 12; }
    name[8] = 0;
    printf("name=%s\n", name);

    /* ---- AH=54 AL=01 search for the name -> should find h1 ---- */
    memcpy(name, "KRONDOR\0", 8);
    segread(&s);
    r.h.ah = 0x54; r.h.al = 0x01; r.x.si = (unsigned)name;
    int86x(EMS_INT, &r, &r, &s);
    found = (r.h.ah == 0) ? r.x.dx : 0xFFFF;
    printf("search rc=%02X found=%04X (h1=%04X)\n", r.h.ah, found, h1);

    /* ---- AH=54 AL=00 enumerate all handle names -> AL = count ---- */
    segread(&s);
    r.h.ah = 0x54; r.h.al = 0x00; r.x.di = (unsigned)dir; s.es = s.ds;
    int86x(EMS_INT, &r, &r, &s);
    names = r.h.al;
    printf("enum count=%04X\n", names);

    /* free both handles */
    r.h.ah = 0x45; r.x.dx = h1; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("free1 err %02X\n", r.h.ah); return 13; }
    r.h.ah = 0x45; r.x.dx = h2; int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("free2 err %02X\n", r.h.ah); return 14; }

    /* free pool fully restored to free0 */
    r.h.ah = 0x42; int86(EMS_INT, &r, &r);
    printf("freeF=%04X (free0=%04X)\n", r.x.bx, free0);
    return 0;
}
