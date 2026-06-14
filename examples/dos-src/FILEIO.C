/* FILEIO — exercises the handle-based file API (INT 21h AH=3C/3D/3E/3F/40/42).
 * Writes a file on C:, seeks, reads it back, prints what it read + a checksum.
 * This drives the VFS create/open/write/seek/read/close path the CRT wraps. */
#include <stdio.h>
#include <string.h>

int main(void)
{
    FILE *f;
    char buf[64];
    long sum = 0;
    int i, n;
    const char *msg = "zdos file I/O roundtrip 0123456789";

    f = fopen("SCRATCH.DAT", "wb");
    if (!f) { printf("FAIL: fopen write\n"); return 1; }
    fwrite(msg, 1, strlen(msg), f);
    fclose(f);

    f = fopen("SCRATCH.DAT", "rb");
    if (!f) { printf("FAIL: fopen read\n"); return 2; }
    fseek(f, 5L, SEEK_SET);          /* skip "zdos " */
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    for (i = 0; i < n; i++) sum += (unsigned char)buf[i];

    printf("read %d bytes after seek: %s\n", n, buf);
    printf("checksum: %ld\n", sum);
    return 0;
}
