/* MALLOC — allocate/free a few hundred KB in chunks, write a pattern, read it
 * back, free. Exercises the far heap the CRT builds on top of INT 21h AH=48
 * (allocate memory) / AH=4A (resize) the startup set up. A loader that hands the
 * program too little memory makes these allocations fail. */
#include <stdio.h>
#include <stdlib.h>

#define CHUNKS   8
#define CHUNKSZ  4096U      /* 4 KB each -> 32 KB total (fits the small-model
                              far heap a default-memsize DOS gives the program) */

int main(void)
{
    char *p[CHUNKS];
    int i;
    unsigned j;
    long ok = 0;

    for (i = 0; i < CHUNKS; i++) {
        p[i] = (char *)malloc(CHUNKSZ);
        if (!p[i]) { printf("FAIL: malloc chunk %d\n", i); return 1; }
        for (j = 0; j < CHUNKSZ; j++) p[i][j] = (char)((i + j) & 0xFF);
    }

    for (i = 0; i < CHUNKS; i++)
        for (j = 0; j < CHUNKSZ; j++)
            if (p[i][j] == (char)((i + j) & 0xFF)) ok++;

    for (i = 0; i < CHUNKS; i++) free(p[i]);

    printf("allocated %d chunks of %u bytes\n", CHUNKS, CHUNKSZ);
    printf("verified %ld bytes\n", ok);
    return 0;
}
