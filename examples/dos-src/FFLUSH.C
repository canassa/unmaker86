/* FFLUSH — buffered fprintf into a file, then fflush() (which on DOS issues the
 * commit-file call INT 21h AH=68 / AH=6A) WITHOUT closing, then open a SECOND
 * handle to the same file and read it back to prove the flush actually pushed the
 * buffered bytes to the file. Exercises AH=68 commit + buffered-stdio flush. */
#include <stdio.h>

int main(void)
{
    FILE *w, *r;
    char buf[128];
    int n;

    w = fopen("FLUSH.DAT", "wb");
    if (!w) { printf("FAIL: create\n"); return 1; }

    fprintf(w, "line=%d value=%d\n", 1, 100);
    fprintf(w, "line=%d value=%d\n", 2, 200);

    /* flush the CRT buffer to the file WITHOUT closing the write handle */
    if (fflush(w) != 0) { printf("FAIL: fflush\n"); fclose(w); return 2; }

    /* a separate read handle must now see the flushed bytes */
    r = fopen("FLUSH.DAT", "rb");
    if (!r) { printf("FAIL: open read after flush\n"); fclose(w); return 3; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, r);
    fclose(r);
    buf[n] = '\0';

    fclose(w);

    printf("after fflush read %d bytes:\n%s", n, buf);
    remove("FLUSH.DAT");
    return 0;
}
