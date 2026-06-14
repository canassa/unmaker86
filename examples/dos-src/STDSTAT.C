/* STDSTAT — AH=0B (get STDIN status) + AH=0C (flush buffer & read STDIN with a
 * sub-function in AL). Under REDIRECTED stdin dosbox-x's handle 0 is a LocalFile
 * whose GetInformation()==0, so AH=0B reports "ready" (0xFF) and AH=0C does NOT
 * flush (its flush is gated on the handle being CON). We therefore call AH=0B a
 * fixed number of times (no status-polling loop — status stays 0xFF even at EOF),
 * print each result, then use AH=0C with AL=0x08 (read one char, no echo) to pull
 * a few bytes. Validated against the dosbox-x golden minted with `< STDSTAT.in`. */
#include <stdio.h>
#include <dos.h>

static int status0b(void)
{
    union REGS r;
    r.h.ah = 0x0B;
    intdos(&r, &r);
    return r.h.al;
}

static int read0c08(void)
{
    union REGS r;
    r.h.ah = 0x0C;
    r.h.al = 0x08; /* sub-function: AH=08 read char, no echo */
    intdos(&r, &r);
    return r.h.al;
}

int main(void)
{
    int i, c;

    for (i = 0; i < 3; i++)
        printf("status[%d]=%02X\n", i, status0b());

    printf("chars:");
    for (i = 0; i < 3; i++) {
        c = read0c08();
        printf(" %d", c);
    }
    printf("\n");
    return 0;
}
