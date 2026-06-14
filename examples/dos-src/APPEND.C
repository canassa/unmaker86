/* APPEND — write a file, reopen in append mode ("ab") and append more, then read
 * the whole file back to prove the appended bytes landed at the end. Exercises
 * the CRT append path: open-for-append seeks to EOF (LSEEK AH=42 AL=02) before
 * each write, then writes (AH=40). */
#include <stdio.h>
#include <string.h>

int main(void)
{
    FILE *f;
    char buf[128];
    int n;
    const char *part1 = "first-";
    const char *part2 = "second-";
    const char *part3 = "third";

    f = fopen("APP.DAT", "wb");
    if (!f) { printf("FAIL: create\n"); return 1; }
    fwrite(part1, 1, strlen(part1), f);
    fclose(f);

    f = fopen("APP.DAT", "ab");
    if (!f) { printf("FAIL: open append 1\n"); return 2; }
    fwrite(part2, 1, strlen(part2), f);
    fclose(f);

    f = fopen("APP.DAT", "ab");
    if (!f) { printf("FAIL: open append 2\n"); return 3; }
    fwrite(part3, 1, strlen(part3), f);
    fclose(f);

    f = fopen("APP.DAT", "rb");
    if (!f) { printf("FAIL: open read\n"); return 4; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    printf("appended file (%d bytes): %s\n", n, buf);
    remove("APP.DAT");
    return 0;
}
