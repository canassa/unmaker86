/* READLINE — DOS AH=0A Buffered Input (DS:DX -> {max,count,chars...}).
 * Set the max-length byte, call INT 21h AH=0A with scripted stdin, then read
 * back the returned count + the line bytes and print them. Exercises the
 * buffered-line-input path (LF skip, CR terminate, count write-back) against the
 * dosbox-x golden minted with `< READLINE.in`. */
#include <stdio.h>
#include <dos.h>

int main(void)
{
    unsigned char buf[130];
    union REGS r;
    struct SREGS s;
    int i, count;

    buf[0] = 80; /* max chars the buffer accepts (incl. CR slot) */

    segread(&s);
    r.h.ah = 0x0A;
    r.x.dx = (unsigned)(buf); /* DS already = our data segment (small model) */
    intdosx(&r, &r, &s);

    count = buf[1];
    printf("\ncount=%d\n", count);
    printf("line=[");
    for (i = 0; i < count; i++)
        putchar(buf[2 + i]);
    printf("]\n");
    return 0;
}
