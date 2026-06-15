/* BIOSEQ — INT 11h equipment list + INT 12h conventional memory size, plus the
 * BDA fields they read, proven equal via a far pointer.
 *
 * Both are pure BDA reads (no host clock, no I/O), so they are fully
 * deterministic on dosbox-x and zdos and oracle-able by construction.
 *
 *   INT 11h -> AX = equipment word (BDA 0040:0010, bios.cpp INT11_Handler ->
 *     mem_readw(BIOS_CONFIGURATION); zdos int11_12.zig handle11 reads
 *     BDA_PHYS+OFF_EQUIPMENT).
 *   INT 12h -> AX = conventional memory size in KiB (BDA 0040:0013,
 *     INT12_Handler -> mem_readw(BIOS_MEMORY_SIZE); zdos handle12 reads
 *     BDA_PHYS+OFF_MEMSIZE_KB).
 *
 * The CONFIG-dependent values (equipment word, memory KB) are whatever the
 * headless oracle config reports; the golden pins dosbox-x's truth and zdos must
 * agree (it seeds the same BDA defaults at POST — see bda.zig initDefaults).
 *
 * DETERMINISM/CAPABILITY BOUNDARY — the math-coprocessor bit (0x02) is MASKED OUT
 * of the asserted equipment word. dosbox-x reports it SET (equip=0x0067: it
 * emulates an x87 FPU), but zdos's CPU does NOT implement the FPU (CLAUDE.md
 * target "does not use the FPU"), so its faithful equipment word CLEARS bit 1
 * (0x0065) — advertising an FPU it can't execute would be a fake that breaks
 * float-using programs. So we assert equip WITHOUT bit 1 (both -> 0x0065) and the
 * raw FPU bit is NOT pinned. Every OTHER bit (floppy/PS2-mouse/video/2-floppies)
 * agrees with the oracle.
 *
 * We read the SAME two words back from the BDA via a far pointer (0040:0010 and
 * 0040:0013) and print eq_match / mem_match to prove the INT return equals the
 * raw BDA word — exercising the get-from-BDA contract end to end. No files.
 */
#include <stdio.h>
#include <dos.h>

#define BDA_SEG       0x0040
#define OFF_EQUIPMENT 0x0010
#define OFF_MEMSIZE   0x0013

static unsigned bda_peekw(unsigned off)
{
    unsigned far *p = (unsigned far *)MK_FP(BDA_SEG, off);
    return *p;
}

int main(void)
{
    union REGS r;
    unsigned equip, memkb, bda_equip, bda_mem;

    /* INT 11h: equipment word -> AX. */
    int86(0x11, &r, &r);
    equip = r.x.ax;

    /* INT 12h: conventional memory size in KiB -> AX. */
    int86(0x12, &r, &r);
    memkb = r.x.ax;

    /* The same two words straight out of the BDA via a far pointer. */
    bda_equip = bda_peekw(OFF_EQUIPMENT);
    bda_mem   = bda_peekw(OFF_MEMSIZE);

    /* Assert the equipment word with the FPU bit (0x02) masked out — see the
     * capability boundary in the header (dosbox-x sets it, zdos clears it). */
    printf("equip_nofpu=%04X\n", equip & ~0x0002);
    printf("memkb=%u\n", memkb);
    printf("eq_match=%d\n", equip == bda_equip ? 1 : 0);
    printf("mem_match=%d\n", memkb == bda_mem ? 1 : 0);

    return 0;
}
