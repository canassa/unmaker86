/* HANDLES — file-handle management / the Job File Table (JFT).
 *
 * Exercises the three INT 21h handle-table services in band 13:
 *   AH=45 dup            (Borland dup()  / <io.h>)  — DOS_DuplicateEntry:
 *                        a NEW handle referring to the SAME SFT entry, so the
 *                        two handles SHARE one file position (one SFT slot,
 *                        refcount bumped). dos_files.cpp DOS_DuplicateEntry.
 *   AH=46 force-dup      (Borland dup2() / <io.h>)  — make handle `newfd` refer
 *                        to the same file as `oldfd`, closing newfd's prior file
 *                        first. This is the stdout/stdin redirection primitive.
 *   AH=67 SetHandleCount (int86, no Borland wrapper) — grow the per-process
 *                        open-file limit above the default 20 by replacing the
 *                        PSP's inline 20-byte JFT with a larger allocated block.
 *                        dos.cpp:2956 -> DOS_PSP::SetNumFiles (dos_classes.cpp).
 *
 * The shared-position proof is the heart of the dup semantics: we write via the
 * ORIGINAL handle, dup it, write MORE via the dup, then SEEK via the dup and
 * confirm the seek is visible to BOTH (one shared file pointer). We then close
 * the original and read back through the dup to prove the dup kept the underlying
 * file ALIVE (the SFT refcount did not hit zero when one of two handles closed).
 *
 * Only oracle-able values are printed: byte counts, file positions, file size,
 * content bytes, success flags, and error codes. No timestamps. The program
 * removes every file it creates before exit so the committed corpus stays
 * byte-identical.
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>
#include <dos.h>
#include <errno.h>

#define SCRATCH "HANDDUP.DAT"

/* Raise the per-process handle count via INT 21h AH=67, BX=count.
 * Returns 0 on success (CF clear), else the DOS error code in AX. Borland has
 * no wrapper for this call, so we issue it directly with int86. */
static unsigned set_handle_count(unsigned count)
{
    union REGS r;
    r.h.ah = 0x67;
    r.x.bx = count;
    int86(0x21, &r, &r);
    if (r.x.cflag) return r.x.ax;   /* CF set -> AX = error code */
    return 0;
}

int main(void)
{
    int fd, fd2, i, n;
    long pos;
    char buf[64];
    static const char part1[] = "AAAA";   /* written via the original handle */
    static const char part2[] = "BBBBBB"; /* written via the dup handle      */
    int many[40];
    int opened;

    /* ---- AH=45 dup: shared SFT entry / shared file position ---- */
    fd = open(SCRATCH, O_RDWR | O_CREAT | O_TRUNC | O_BINARY, 0644);
    if (fd < 0) { printf("FAIL: open scratch\n"); return 1; }

    n = write(fd, part1, (unsigned)strlen(part1));
    printf("orig wrote: %d\n", n);
    printf("orig pos after write: %ld\n", tell(fd));

    fd2 = dup(fd);                  /* AH=45 */
    if (fd2 < 0) { printf("FAIL: dup\n"); return 2; }
    printf("dup ok (newfd>orig): %d\n", fd2 > fd ? 1 : 0);

    /* The dup shares the file pointer: it continues from where the original
     * left off, NOT from 0. Writing via the dup advances the SHARED position. */
    printf("dup pos (shared w/ orig): %ld\n", tell(fd2));
    n = write(fd2, part2, (unsigned)strlen(part2));
    printf("dup wrote: %d\n", n);

    /* Seeking via the dup must move the ORIGINAL's pointer too (one SFT slot). */
    pos = lseek(fd2, 2L, SEEK_SET);
    printf("dup seek -> %ld\n", pos);
    printf("orig pos sees dup seek: %ld\n", tell(fd));

    /* Close the ORIGINAL. The dup keeps the file open (refcount > 1 at close). */
    close(fd);

    /* Read back the WHOLE file through the surviving dup to prove it is alive
     * and that both writes landed in one file at the shared position. */
    lseek(fd2, 0L, SEEK_SET);
    n = read(fd2, buf, sizeof(buf) - 1);
    buf[n] = '\0';
    printf("dup read after orig close: %d [%s]\n", n, buf);
    close(fd2);

    /* ---- AH=46 dup2 / force-dup: redirect a handle ---- */
    /* Open two distinct files; force handle B to alias handle A's file, which
     * first closes B's own file, then makes B share A's SFT entry. A write via
     * B then lands in A's file (the redirection primitive). */
    {
        int a, b;
        char rb[16];
        a = open(SCRATCH, O_RDWR | O_CREAT | O_TRUNC | O_BINARY, 0644);
        b = open("HANDB.DAT", O_RDWR | O_CREAT | O_TRUNC | O_BINARY, 0644);
        if (a < 0 || b < 0) { printf("FAIL: open a/b\n"); return 3; }

        write(a, "XYZ", 3);
        lseek(a, 0L, SEEK_SET);

        /* dup2(a,b): b now refers to a's file (closing b's own file first).
         * Borland dup2 returns 0 on success, -1 on error. */
        printf("dup2 rc: %d\n", dup2(a, b));

        /* b shares a's position (we seeked a to 0); reading via b yields a's
         * content, proving b was redirected onto a's file. */
        n = read(b, rb, 3);
        rb[n] = '\0';
        printf("redirected read via b: %d [%s]\n", n, rb);

        close(a);
        close(b);
        unlink("HANDB.DAT");
    }

    /* ---- AH=67 Set Handle Count: open more than the default 20 ---- */
    {
        unsigned rc = set_handle_count(40);
        printf("set_handle_count(40) rc: %u\n", rc);

        for (i = 0; i < 40; i++) many[i] = -1;
        opened = 0;
        for (i = 0; i < 25; i++) {
            char nm[16];
            sprintf(nm, "H%02d.TMP", i);
            many[i] = open(nm, O_RDWR | O_CREAT | O_TRUNC | O_BINARY, 0644);
            if (many[i] >= 0) opened++;
        }
        printf("opened %d files (want 25 > default 20)\n", opened);
        printf("all above default-20 limit: %d\n", opened > 20 ? 1 : 0);

        for (i = 0; i < 25; i++) {
            if (many[i] >= 0) {
                char nm[16];
                close(many[i]);
                sprintf(nm, "H%02d.TMP", i);
                unlink(nm);
            }
        }
    }

    unlink(SCRATCH);
    printf("done\n");
    return 0;
}
