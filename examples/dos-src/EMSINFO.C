/* EMSINFO — detect LIM EMS and report the manager's static facts.
 *
 * Detection uses the documented "open the EMMXXXX0 character device" probe:
 * INT 21h AH=3D (open) the name "EMMXXXX0"; a successful open with a device
 * handle (IOCTL AH=44 AL=00 device bit set) means an EMM is resident. Then we
 * issue the INT 67h queries and print the read-back values as hex so the golden
 * is a deterministic record of the manager's facts:
 *   AH=46 get version          -> AL (BCD: 0x40 = 4.0, 0x32 = 3.2)
 *   AH=40 get status           -> AH (0 = OK)
 *   AH=41 get page-frame seg   -> BX (segment, e.g. E000)
 *   AH=42 get page count       -> BX free, DX total
 * Each INT 67h call returns its status in AH (0 = success).
 */
#include <stdio.h>
#include <dos.h>

#define EMS_INT 0x67

int main(void)
{
    union REGS r;
    struct SREGS s;
    int handle;
    unsigned version, status, frame, freep, totalp;

    /* --- presence probe: open the EMMXXXX0 character device --- */
    r.x.ax = 0x3D00;                 /* AH=3D open, AL=00 read-only */
    r.x.dx = (unsigned)"EMMXXXX0";
    segread(&s);                     /* s.ds = data segment, where the literal lives */
    int86x(0x21, &r, &r, &s);
    if (r.x.cflag) {
        printf("EMS not present\n");
        return 1;
    }
    handle = r.x.ax;

    /* confirm it is a device (IOCTL AH=44 AL=00 -> DX bit 7 set) */
    r.x.ax = 0x4400;
    r.x.bx = handle;
    int86(0x21, &r, &r);
    if (!(r.x.dx & 0x0080)) {
        printf("EMMXXXX0 is not a device\n");
        return 2;
    }

    /* close the probe handle */
    r.x.ax = 0x3E00;
    r.x.bx = handle;
    int86(0x21, &r, &r);

    /* --- INT 67h queries --- */
    r.h.ah = 0x46;                   /* get version */
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("AH=46 err %02X\n", r.h.ah); return 3; }
    version = r.h.al;

    r.h.ah = 0x40;                   /* get status */
    int86(EMS_INT, &r, &r);
    status = r.h.ah;

    r.h.ah = 0x41;                   /* get page-frame segment */
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("AH=41 err %02X\n", r.h.ah); return 4; }
    frame = r.x.bx;

    r.h.ah = 0x42;                   /* get page count */
    int86(EMS_INT, &r, &r);
    if (r.h.ah != 0) { printf("AH=42 err %02X\n", r.h.ah); return 5; }
    freep = r.x.bx;
    totalp = r.x.dx;

    printf("version=%02X\n", version);
    printf("status=%02X\n", status);
    printf("frame=%04X\n", frame);
    printf("free=%04X total=%04X\n", freep, totalp);
    return 0;
}
