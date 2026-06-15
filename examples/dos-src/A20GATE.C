/* A20GATE — INT 15h AH=24 A20-gate control + AH=88 extended-memory size.
 *
 * The A20 gate state is a pure machine-model boolean (no host clock, no real
 * I/O), so set/get round-trips are fully deterministic on dosbox-x and zdos and
 * oracle-able by construction.
 *
 * AH=88 ext-memory size is a SCOPE-DIVERGENT value and is deliberately NOT
 * asserted as a golden: dosbox-x returns its configured extended-memory size
 * (size_extended, ~15 MiB under the oracle's default memsize; bios.cpp:7094),
 * whereas zdos models a 1 MiB real-mode machine with NO extended memory (XMS is
 * deferred entirely — the same scope as the xms=false oracle pin, CLAUDE.md
 * target "1 MB RAM + ~1 MB EMS"), so its faithful answer is 0 (int15.zig AH=88).
 * Reporting dosbox-x's 15 MiB would be FAKING RAM zdos does not have, which the
 * no-fakes ground rule forbids; reporting 0 cannot match dosbox-x's golden. So we
 * exercise the AH=88 PATH and assert only the host-independent, scope-agnostic
 * part both honor — the success carry flag (CF=0) — and document the size as a
 * scope boundary (mirroring the host-mtime exclusion in the DOS-phase bands).
 *
 * Semantics matched to references/dosbox-x/src/ints/bios.cpp INT15_Handler
 * AH=0x24 (the BIOS A20-gate function group) and AH=0x88:
 *   AH=24 AL=00 disable A20  -> CF=0 (success)
 *   AH=24 AL=01 enable  A20  -> CF=0
 *   AH=24 AL=02 get status   -> AL = current A20 state (0/1), CF=0
 *   AH=24 AL=03 query support-> BX = supported-methods bitmask, CF=0
 *   AH=88        ext-mem KiB -> AX = size in KiB
 * zdos int15.zig drives cpu.bus.setA20()/a20Enabled() for AL=00/01/02, returns
 * BX=0x0003 for AL=03, and returns AX=0 for AH=88 (it models 1 MiB + HMA only,
 * the faithful answer for a 1 MiB real-mode machine).
 *
 * We exercise the full path: query support, then ENABLE/DISABLE/re-ENABLE with a
 * status re-read after each, plus an extra toggle cycle, leaving A20 enabled. The
 * BOOT A20 default is deliberately NOT asserted — it is an incidental power-on
 * value that legitimately differs (dosbox-x boots A20 masked; zdos's BIOS POST
 * enables it per its documented design); every asserted value is an A20 boolean we
 * just SET, so the test proves the AH=24 control path itself and is boot-default-
 * independent. No host dependency, no files.
 */
#include <stdio.h>
#include <dos.h>

/* INT 15h AH=24 AL=sub, returns AX, BX and CF via the out frame. */
static void a20(unsigned char sub, unsigned *ax, unsigned *bx, unsigned *cf)
{
    union REGS r;
    r.h.ah = 0x24;
    r.h.al = sub;
    int86(0x15, &r, &r);
    *ax = r.x.ax;
    *bx = r.x.bx;
    *cf = r.x.cflag ? 1 : 0;
}

/* Read just the A20 status byte (AL) via AH=24 AL=02. */
static unsigned a20_status(void)
{
    unsigned ax, bx, cf;
    a20(0x02, &ax, &bx, &cf);
    return ax & 0xFF;
}

int main(void)
{
    union REGS r;
    unsigned ax, bx, cf;

    /* AL=03 query support -> BX = supported-methods bitmask. */
    a20(0x03, &ax, &bx, &cf);
    printf("support cf=%u bx=%04X\n", cf, bx);

    /* The BOOT A20 state is NOT asserted: it is an incidental power-on default
     * that legitimately differs (dosbox-x boots A20 masked; zdos's BIOS POST
     * enables it per its documented design — bios.zig post()). We instead ESTABLISH
     * a known state with AL=01 enable and assert from there, so the test is
     * boot-default-independent and the AH=24 enable/disable/status PATH (the actual
     * feature) is what is proven. */
    a20(0x01, &ax, &bx, &cf);
    printf("enable cf=%u status=%u\n", cf, a20_status());

    /* AL=00 disable, then confirm status=0. */
    a20(0x00, &ax, &bx, &cf);
    printf("disable cf=%u status=%u\n", cf, a20_status());

    /* AL=01 enable again, then confirm status=1 (proves it toggles both ways). */
    a20(0x01, &ax, &bx, &cf);
    printf("reenable cf=%u status=%u\n", cf, a20_status());

    /* AL=00 disable, status=0, AL=01 enable, status=1 — one more deterministic
     * toggle cycle, then leave A20 ENABLED (the safe default: a DOS program may
     * use the HMA; both dosbox-x and zdos honor INT 15h AL=01). */
    a20(0x00, &ax, &bx, &cf);
    printf("toggle_off status=%u\n", a20_status());
    a20(0x01, &ax, &bx, &cf);
    printf("toggle_on status=%u\n", a20_status());

    /* AH=88 extended-memory size: exercise the path, assert ONLY the success
     * carry flag (CF=0) — the returned KiB count is a scope-divergent value
     * (dosbox-x's configured ext-mem vs zdos's 1 MiB-only 0) and is NOT printed.
     * See the header comment for the documented boundary. */
    r.h.ah = 0x88;
    int86(0x15, &r, &r);
    printf("extmem_cf=%u\n", r.x.cflag ? 1 : 0);

    return 0;
}
