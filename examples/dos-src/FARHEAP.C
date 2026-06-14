/* FARHEAP — Borland far-heap API (farcoreleft / farmalloc / farfree), which is
 * implemented on top of INT 21h AH=48 (allocate) / AH=4A (resize) / AH=49 (free).
 *
 * farcoreleft() returns the number of bytes of UNALLOCATED conventional memory
 * the far heap can still grab from DOS. We allocate a few far blocks, free them,
 * and observe coreleft fall and recover — proving the AH=48/49 round-trip the
 * far heap rides on works.
 *
 * The ABSOLUTE coreleft byte count depends on the DOS memory map (arena base,
 * env block, program size) and differs between any two DOSes, so we never print
 * the raw figure. Instead we print DELTAS and orderings, which are arena-
 * deterministic: after allocating B bytes, coreleft drops by at least B; after
 * freeing, it returns to the original. Each printed line is a stable record.
 */
#include <stdio.h>
#include <alloc.h>

#define BLKSZ  4096UL      /* 4 KB per far block */

int main(void)
{
    unsigned long c0, c1, c2, c3, c4;
    void far *a;
    void far *b;

    c0 = farcoreleft();
    printf("start: coreleft>0 = %d\n", c0 > 0 ? 1 : 0);

    /* allocate one 4 KB far block */
    a = farmalloc(BLKSZ);
    if (a == NULL) { printf("FAIL farmalloc a\n"); return 1; }
    c1 = farcoreleft();
    printf("after a(%lu): dropped>=blk = %d\n", BLKSZ, (c0 - c1) >= BLKSZ ? 1 : 0);

    /* allocate a second 4 KB far block */
    b = farmalloc(BLKSZ);
    if (b == NULL) { printf("FAIL farmalloc b\n"); return 2; }
    c2 = farcoreleft();
    printf("after b(%lu): dropped>=2blk = %d\n", BLKSZ, (c0 - c2) >= 2UL * BLKSZ ? 1 : 0);

    /* free the first block */
    farfree(a);
    c3 = farcoreleft();
    printf("after free a: recovered = %d\n", c3 > c2 ? 1 : 0);

    /* free the second block -> coreleft back to the start */
    farfree(b);
    c4 = farcoreleft();
    printf("after free b: back to start = %d\n", c4 == c0 ? 1 : 0);

    return 0;
}
