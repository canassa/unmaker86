/* DOSERR — extended error info (INT 21h AH=59).
 *
 * Open a file that does not exist (AH=3D fails: CF set, AX=2 file-not-found),
 * then immediately issue AH=59 (BX=0 = DOS 3.x+ format) to retrieve the
 * extended-error record DOS latched for the LAST failed call:
 *   AX = extended error code (2 = ENOENT)
 *   BH = error class      (8 = "not found")
 *   BL = suggested action (typically 3 = "prompt user to retry" / 5 = "apply
 *        corrective action" depending on DOS; we print the raw byte)
 *   CH = locus            (where the error happened; for a path open this is
 *        the block device / file locus)
 * These are the bytes a CRT maps to errno/_doserrno. The values are a fixed
 * function of the error, not host state, so the golden is deterministic.
 *
 * dos.cpp:1337 (DOS_GetExtendedError): class/action/locus come from the
 * dos.errorcode -> errortable lookup; file-not-found yields class 8, locus 2.
 */
#include <stdio.h>
#include <dos.h>

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned err_code;
    unsigned char eclass, action, locus;

    /* --- AH=3D: open a nonexistent file (read-only) --- */
    r.x.ax = 0x3D00;
    r.x.dx = (unsigned)"NOSUCH.XYZ";
    segread(&s);
    int86x(0x21, &r, &r, &s);
    if (!r.x.cflag) { printf("FAIL: open unexpectedly succeeded\n"); return 1; }
    printf("open failed ax=%04X\n", r.x.ax);

    /* --- AH=59: get extended error (BX=0000 = version selector) --- */
    r.x.ax = 0x5900;
    r.x.bx = 0x0000;
    int86(0x21, &r, &r);
    err_code = r.x.ax;
    eclass   = r.h.bh;
    action   = r.h.bl;
    locus    = r.h.ch;

    printf("ext_error=%04X\n", err_code);
    printf("class=%02X\n", eclass);
    printf("action=%02X\n", action);
    printf("locus=%02X\n", locus);
    return 0;
}
