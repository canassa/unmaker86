/* EMSMAP — the core EMS correctness proof.
 *
 * Allocate a handle with 4 logical pages (INT 67h AH=43). Map logical page 0
 * into physical frame slot 0 (AH=44), write a pattern through the page-frame
 * window. Map logical page 1 into slot 0, write a different pattern. Then map
 * logical page 0 BACK into slot 0 and read it: it must still hold the first
 * pattern (proving the logical page persisted across the remap, i.e. the frame
 * is a real window onto distinct backing pages). Read page 1 back too. Print
 * the read-back bytes as hex. Free the handle (AH=45).
 *
 * The frame window is at <frame_seg>:0000; we get <frame_seg> from AH=41.
 */
#include <stdio.h>
#include <dos.h>

#define EMS_INT 0x67

static unsigned ems_frame_seg(void)
{
    union REGS r;
    r.h.ah = 0x41;
    int86(EMS_INT, &r, &r);
    return r.x.bx;
}

int main(void)
{
    union REGS r;
    unsigned frame, handle;
    unsigned char far *win;
    int i;

    frame = ems_frame_seg();
    win = (unsigned char far *)MK_FP(frame, 0);

    /* allocate a handle with 4 pages */
    r.h.ah = 0x43;
    r.x.bx = 4;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("alloc err %02X\n", r.h.ah); return 1; }
    handle = r.x.dx;

    /* map logical page 0 -> physical slot 0, write pattern A (0x11..) */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 0; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("map0 err %02X\n", r.h.ah); return 2; }
    for (i = 0; i < 16; i++) win[i] = (unsigned char)(0x11 + i);

    /* map logical page 1 -> physical slot 0, write pattern B (0xA0..) */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 1; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("map1 err %02X\n", r.h.ah); return 3; }
    for (i = 0; i < 16; i++) win[i] = (unsigned char)(0xA0 + i);

    /* map logical page 0 back -> read pattern A back (persistence proof) */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 0; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("remap0 err %02X\n", r.h.ah); return 4; }
    printf("page0:");
    for (i = 0; i < 8; i++) printf(" %02X", win[i]);
    printf("\n");

    /* map logical page 1 back -> read pattern B back */
    r.h.ah = 0x44; r.h.al = 0; r.x.bx = 1; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("remap1 err %02X\n", r.h.ah); return 5; }
    printf("page1:");
    for (i = 0; i < 8; i++) printf(" %02X", win[i]);
    printf("\n");

    /* free the handle */
    r.h.ah = 0x45; r.x.dx = handle;
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("free err %02X\n", r.h.ah); return 6; }

    printf("freed handle\n");
    return 0;
}
