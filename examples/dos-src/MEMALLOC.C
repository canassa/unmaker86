/* MEMALLOC — direct INT 21h memory management via int86 / int86x.
 *
 * Exercises the raw DOS memory API the CRT far heap is built on:
 *   AH=48 allocate N paragraphs   -> AX = segment (CF clear)
 *   AH=4A resize a block          -> grow then shrink (ES = block, BX = paras)
 *   AH=49 free a block            -> ES = block
 * then a DELIBERATELY-too-large AH=48 (0xFFFF paragraphs = 1 MB) which MUST
 * fail with CF set, AX=8 (insufficient memory) AND BX = the largest free block
 * available, in paragraphs — the documented DOS contract (dos.cpp:1173,
 * DOS_AllocateMemory returns the largest block in the size argument on failure).
 *
 * Everything is deterministic given a fixed conventional-memory arena. The
 * ABSOLUTE largest-free paragraph count differs between any two DOS memory maps
 * (arena base, env block, program size), so we do NOT print the raw figure;
 * instead we PROVE the BX contract: re-allocating exactly BX paragraphs MUST
 * succeed and BX+1 MUST fail. The printed sizes, success/fail flags and the
 * failing AX (=0008) are all arena-deterministic.
 */
#include <stdio.h>
#include <dos.h>

int main(void)
{
    union REGS r;
    struct SREGS s;
    unsigned seg_a, seg_b;
    unsigned largest;

    segread(&s);

    /* --- AH=48: allocate 16 paragraphs (256 bytes) --- */
    r.h.ah = 0x48;
    r.x.bx = 16;
    int86(0x21, &r, &r);
    if (r.x.cflag) { printf("FAIL alloc A ax=%04X\n", r.x.ax); return 1; }
    seg_a = r.x.ax;
    printf("alloc A: 16 paras ok\n");

    /* --- AH=48: allocate a second block, 32 paragraphs (512 bytes) --- */
    r.h.ah = 0x48;
    r.x.bx = 32;
    int86(0x21, &r, &r);
    if (r.x.cflag) { printf("FAIL alloc B ax=%04X\n", r.x.ax); return 2; }
    seg_b = r.x.ax;
    printf("alloc B: 32 paras ok\n");

    /* --- AH=4A: GROW block A from 16 to 48 paragraphs --- */
    r.h.ah = 0x4A;
    r.x.bx = 48;
    s.es   = seg_a;
    int86x(0x21, &r, &r, &s);
    /* Growing A may be blocked by B sitting right after it. Report the result
     * deterministically: ok, or fail with the max-growable paragraph count. */
    if (r.x.cflag)
        printf("grow A->48: fail max=%u\n", r.x.bx);
    else
        printf("grow A->48: ok\n");

    /* --- AH=4A: SHRINK block B from 32 to 8 paragraphs (always succeeds) --- */
    r.h.ah = 0x4A;
    r.x.bx = 8;
    s.es   = seg_b;
    int86x(0x21, &r, &r, &s);
    if (r.x.cflag) { printf("FAIL shrink B ax=%04X\n", r.x.ax); return 3; }
    printf("shrink B->8: ok\n");

    /* --- AH=49: free both blocks --- */
    r.h.ah = 0x49;
    s.es   = seg_a;
    int86x(0x21, &r, &r, &s);
    if (r.x.cflag) { printf("FAIL free A ax=%04X\n", r.x.ax); return 4; }
    r.h.ah = 0x49;
    s.es   = seg_b;
    int86x(0x21, &r, &r, &s);
    if (r.x.cflag) { printf("FAIL free B ax=%04X\n", r.x.ax); return 5; }
    printf("freed A,B\n");

    /* --- AH=48: deliberately too-large request: 0xFFFF paragraphs (~1 MB) --- */
    r.h.ah = 0x48;
    r.x.bx = 0xFFFF;
    int86(0x21, &r, &r);
    if (!r.x.cflag) { printf("FAIL: huge alloc unexpectedly succeeded\n"); return 6; }
    largest = r.x.bx;          /* DOS contract: BX = largest free block (paras) */
    printf("huge alloc failed ax=%04X\n", r.x.ax);

    /* Re-allocate exactly the largest reported block -> MUST succeed, proving BX
     * was the true largest free. Then free it. */
    r.h.ah = 0x48;
    r.x.bx = largest;
    int86(0x21, &r, &r);
    if (r.x.cflag) { printf("FAIL: largest alloc failed ax=%04X\n", r.x.ax); return 7; }
    printf("alloc largest ok\n");
    r.h.ah = 0x49;
    s.es   = r.x.ax;
    int86x(0x21, &r, &r, &s);

    /* One more paragraph than the largest -> MUST fail again. */
    r.h.ah = 0x48;
    r.x.bx = (unsigned)(largest + 1);
    int86(0x21, &r, &r);
    printf("largest+1 alloc cf=%d\n", r.x.cflag ? 1 : 0);

    return 0;
}
