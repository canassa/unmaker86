/* MKTREE — nested directory create/remove + a file deep in the tree.
 *
 * Exercises multi-component path resolution on the VFS backend (D8b):
 *   - AH=39 MKDIR "SUB1"        (one level)
 *   - AH=39 MKDIR "SUB1\SUB2"   (two levels — intermediate must resolve)
 *   - create+write a file at the MULTI-COMPONENT path SUB1\SUB2\DEEP.TXT
 *   - read it back through the same multi-component path
 *   - AH=3A RMDIR innermost-first, confirming a non-empty rmdir FAILS (AX=5)
 *     before the file is removed, then succeeds after.
 *
 * Every step prints PASS/FAIL plus, on the INT 21h calls, the carry flag and
 * AX so the dosbox-x golden pins the exact return semantics. The program
 * creates its OWN tree at runtime and removes it again, so reruns are stable
 * and no committed fixture is needed. Uses raw INT 21h (AH=39/3A) via intdos
 * for MKDIR/RMDIR so the carry+AX are observable; file I/O via the C runtime.
 */
#include <stdio.h>
#include <string.h>
#include <dos.h>

/* Make a directory via INT 21h AH=39. Returns 0 on success; on failure returns
 * the DOS error code in AX (carry set). Prints the outcome. */
static int do_mkdir(const char *path)
{
    union REGS r;
    struct SREGS s;
    int cf, ax;

    segread(&s);
    r.h.ah = 0x39;
    r.x.dx = FP_OFF(path);
    s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    cf = r.x.cflag ? 1 : 0;
    ax = r.x.ax;
    printf("mkdir %-14s cf=%d ax=%d\n", path, cf, cf ? ax : 0);
    return cf ? ax : 0;
}

/* Remove a directory via INT 21h AH=3A. Same reporting as do_mkdir. */
static int do_rmdir(const char *path)
{
    union REGS r;
    struct SREGS s;
    int cf, ax;

    segread(&s);
    r.h.ah = 0x3A;
    r.x.dx = FP_OFF(path);
    s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    cf = r.x.cflag ? 1 : 0;
    ax = r.x.ax;
    printf("rmdir %-14s cf=%d ax=%d\n", path, cf, cf ? ax : 0);
    return cf ? ax : 0;
}

int main(void)
{
    FILE *f;
    char buf[64];
    int n;
    const char *payload = "deep tree payload 13579";

    /* Build the tree, innermost requires the intermediate to resolve. */
    do_mkdir("SUB1");
    do_mkdir("SUB1\\SUB2");

    /* Create + write the deep file through the multi-component path. */
    f = fopen("SUB1\\SUB2\\DEEP.TXT", "wb");
    if (!f) { printf("FAIL: create SUB1\\SUB2\\DEEP.TXT\n"); return 1; }
    fwrite(payload, 1, strlen(payload), f);
    fclose(f);
    printf("create SUB1\\SUB2\\DEEP.TXT OK\n");

    /* Read it back through the same multi-component path. */
    f = fopen("SUB1\\SUB2\\DEEP.TXT", "rb");
    if (!f) { printf("FAIL: open SUB1\\SUB2\\DEEP.TXT\n"); return 2; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    printf("read %d bytes: %s\n", n, buf);

    /* rmdir of a NON-EMPTY dir must FAIL (still holds DEEP.TXT). */
    do_rmdir("SUB1\\SUB2");

    /* Remove the file, then the now-empty dirs innermost-first. */
    if (remove("SUB1\\SUB2\\DEEP.TXT") != 0) {
        printf("FAIL: remove DEEP.TXT\n"); return 3;
    }
    printf("remove SUB1\\SUB2\\DEEP.TXT OK\n");
    do_rmdir("SUB1\\SUB2");
    do_rmdir("SUB1");

    printf("MKTREE done\n");
    return 0;
}
