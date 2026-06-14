/* SPRINTF — pure-libc CRT round-trip: sprintf/sscanf/atoi/strtol. No DOS I/O
 * surface beyond CON write; proves the Borland CRT's string<->number formatting
 * is correct and deterministic on both sides. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    char buf[128];
    int a, b;
    long base16, base10;
    char *endp;
    unsigned u;

    sprintf(buf, "%d|%05d|%x|%o|%c|%s", 42, 7, 255, 64, 'Z', "hi");
    printf("fmt=%s\n", buf);

    sprintf(buf, "%-8d|%+d|%8.3f", 13, 9, 3.14159);
    printf("fmt2=[%s]\n", buf);

    sscanf("123 456", "%d %d", &a, &b);
    printf("scan: a=%d b=%d sum=%d\n", a, b, a + b);

    printf("atoi(\"-2048\")=%d\n", atoi("-2048"));

    base16 = strtol("0xFF", &endp, 16);
    base10 = strtol("  -100xyz", &endp, 10);
    printf("strtol hex=%ld dec=%ld rest=%s\n", base16, base10, endp);

    u = (unsigned)strtoul("65000", &endp, 10);
    printf("strtoul=%u\n", u);

    {
        double d1 = 0.0, d2 = 0.0;
        sscanf("3.5,7.25", "%lf,%lf", &d1, &d2);
        sprintf(buf, "%.2f+%.2f=%.2f", d1, d2, d1 + d2);
        printf("dbl: %s\n", buf);
    }

    printf("strlen(fmt)=%d\n", (int)strlen("abcde"));
    return 0;
}
