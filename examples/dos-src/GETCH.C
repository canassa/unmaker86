/* GETCH — AH=08 (read char, no echo) + AH=01 (read char, with echo) loop.
 * Reads characters from scripted stdin until CR (13). Each char: read with
 * AH=08 (no echo), print it via printf as "<dec>" so we observe the raw byte,
 * then read the SAME logical stream is NOT possible twice — so we alternate:
 * use AH=01 (DOS echoes to STDOUT) for the visible-echo half. Demonstrates both
 * the no-echo (AH=08) and echo (AH=01) console-input paths vs the dosbox-x
 * golden minted with `< GETCH.in`. */
#include <stdio.h>
#include <dos.h>

static int read08(void)
{
    union REGS r;
    r.h.ah = 0x08;
    intdos(&r, &r);
    return r.h.al;
}

static int read01(void)
{
    union REGS r;
    r.h.ah = 0x01; /* DOS echoes the char to STDOUT itself */
    intdos(&r, &r);
    return r.h.al;
}

int main(void)
{
    int c, n = 0;

    /* First pass: AH=08, no echo — we print the decimal codes ourselves. */
    printf("no-echo:");
    for (;;) {
        c = read08();
        if (c == 13)
            break;
        printf(" %d", c);
        n++;
    }
    printf("\ncount=%d\n", n);

    /* Second pass: AH=01, DOS echoes each char (incl. the CR) to STDOUT. */
    printf("echo:");
    for (;;) {
        c = read01();
        if (c == 13)
            break;
    }
    printf("\ndone\n");
    return 0;
}
