/* RENAME — create+write a file, rename it (INT 21h AH=56), reopen by the NEW
 * name and read it back, then remove it (AH=41) and confirm it's gone (open of
 * the removed name fails). Exercises AH=56 rename + AH=41 unlink end to end. */
#include <stdio.h>
#include <string.h>
#include <stdio.h>

int main(void)
{
    FILE *f;
    char buf[64];
    int n;
    const char *msg = "renamed payload 9876";

    f = fopen("OLD.DAT", "wb");
    if (!f) { printf("FAIL: create OLD.DAT\n"); return 1; }
    fwrite(msg, 1, strlen(msg), f);
    fclose(f);

    if (rename("OLD.DAT", "NEW.DAT") != 0) { printf("FAIL: rename\n"); return 2; }

    /* old name must be gone */
    f = fopen("OLD.DAT", "rb");
    if (f) { printf("FAIL: OLD.DAT still openable after rename\n"); fclose(f); return 3; }

    /* new name must read back the original payload */
    f = fopen("NEW.DAT", "rb");
    if (!f) { printf("FAIL: open NEW.DAT after rename\n"); return 4; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    printf("after rename read %d bytes: %s\n", n, buf);

    if (remove("NEW.DAT") != 0) { printf("FAIL: remove NEW.DAT\n"); return 5; }

    f = fopen("NEW.DAT", "rb");
    if (f) { printf("FAIL: NEW.DAT still openable after remove\n"); fclose(f); return 6; }

    printf("rename+remove OK\n");
    return 0;
}
