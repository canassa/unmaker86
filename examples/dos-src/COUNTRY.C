/* COUNTRY — INT 21h AH=38 get-country-info via Borland's country(). Prints the
 * deterministic locale fields (date/time format, currency symbol, separators).
 * The data is a fixed constant block in DOS, not host state, so it is
 * deterministic on both sides. */
#include <stdio.h>
#include <dos.h>

static void hexstr(const char *label, const char *s, int n)
{
    int i;
    printf("%s=", label);
    for (i = 0; i < n; i++)
        printf("%02X ", (unsigned char)s[i]);
    printf("\n");
}

int main(void)
{
    struct COUNTRY c;
    struct COUNTRY *p;

    p = country(0, &c);          /* 0 = current/default country */
    if (p == NULL) { printf("FAIL: country()\n"); return 1; }

    printf("date_format=%d\n", c.co_date);
    printf("currency_style=%d\n", (int)c.co_currstyle);
    printf("currency_digits=%d\n", (int)c.co_digits);
    printf("time_format=%d\n", (int)c.co_time);
    hexstr("currency", c.co_curr, 5);
    hexstr("thousands_sep", c.co_thsep, 2);
    hexstr("decimal_sep", c.co_desep, 2);
    hexstr("date_sep", c.co_dtsep, 2);
    hexstr("time_sep", c.co_tmsep, 2);
    hexstr("data_sep", c.co_dasep, 2);
    return 0;
}
