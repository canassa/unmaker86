/* XMSPROBE — the canonical XMS install-check handshake + graceful fallback.
 *
 * An XMS-aware DOS program never calls the XMS driver blindly. It performs the
 * documented two-step detection via the INT 2Fh multiplex interrupt:
 *
 *   1. AX=4300  XMS installation check.
 *      The driver (HIMEM.SYS et al.) answers AL=0x80 if resident. ANY other
 *      value means "no XMS driver" — the program MUST NOT proceed to step 2.
 *
 *   2. AX=4310  Get XMS driver entry point (only if AL==0x80 in step 1).
 *      Returns the FAR entry point in ES:BX. The program then calls that entry
 *      with AH=00 to read the XMS version, AH=08 to query free extended memory,
 *      etc. (We model just the version read here.)
 *
 * zdos DEFERS XMS entirely (extended memory is out of scope; the target class is
 * plain real-mode + EMS via INT 67h). So the FAITHFUL answer to AX=4300 is "not
 * installed" (AL != 0x80), which is exactly what dosbox-x reports when run with
 * xms=false (the pinned canonical oracle config). A correct XMS-aware program
 * then falls back to conventional/EMS memory — it does NOT stop.
 *
 * This program proves the whole handshake AND the fallback:
 *   - Reports whether XMS is installed (it is not, in our scope).
 *   - Because it is not, it does NOT issue AX=4310 (faithful: never touch a
 *     non-existent entry point).
 *   - It then exercises the fallback path: probe for EMS (open EMMXXXX0) and, if
 *     present, report that the program will use EMS instead. EMS IS in scope, so
 *     this proves "XMS absent -> EMS fallback" end to end.
 *
 * Deterministic output (no addresses, no host-dependent values):
 *   XMS install check: AL=00
 *   XMS not installed
 *   fallback: EMS available
 *   done
 * Exit code 0 = clean handshake + fallback (no unsupported stop).
 */
#include <stdio.h>
#include <dos.h>

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned char al;
    int ems_handle;

    /* --- step 1: XMS installation check (INT 2Fh AX=4300) --- */
    r.x.ax = 0x4300;
    int86(0x2F, &r, &r);
    al = r.h.al;
    printf("XMS install check: AL=%02X\n", al);

    if (al == 0x80) {
        /* --- step 2 (only if installed): get the entry point (AX=4310) --- */
        unsigned ver;
        void (far *xms_entry)(void);

        r.x.ax = 0x4310;
        segread(&s);
        int86x(0x2F, &r, &r, &s);
        /* ES:BX -> XMS driver entry point */
        xms_entry = (void (far *)(void))MK_FP(s.es, r.x.bx);

        /* call the entry point with AH=00 to read the XMS version (BCD in AX) */
        _AH = 0x00;
        (*xms_entry)();
        ver = _AX;
        printf("XMS present, version %X.%02X\n", (ver >> 8) & 0xFF, ver & 0xFF);
        /* a real program would now use XMS; nothing further to prove here */
        return 0;
    }

    /* --- not installed: the faithful path for zdos's deferred-XMS scope --- */
    printf("XMS not installed\n");

    /* --- graceful fallback: use EMS instead (in scope via INT 67h) --- */
    /* presence probe: open the EMMXXXX0 character device (the documented EMS
     * detection path; see EMSINFO.C). */
    r.x.ax = 0x3D00;                 /* AH=3D open, AL=00 read-only */
    r.x.dx = (unsigned)"EMMXXXX0";
    segread(&s);
    int86x(0x21, &r, &r, &s);
    if (r.x.cflag) {
        printf("fallback: no EMS either, using conventional memory\n");
    } else {
        ems_handle = r.x.ax;
        /* close the probe handle */
        r.x.ax = 0x3E00;
        r.x.bx = ems_handle;
        int86(0x21, &r, &r);
        printf("fallback: EMS available\n");
    }

    printf("done\n");
    return 0;
}
