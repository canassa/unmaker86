/* CDTEST — current-directory state + relative / `.` / `..` path resolution.
 * (Named CDTEST, not CHDIR: the dosbox-x shell intercepts a bare CHDIR command
 * as its built-in directory-change command before running the EXE.)
 *
 * Exercises per-drive CWD on the VFS backend (D8b):
 *   - build a tree SUB1\SUB2 with a file in each level
 *   - AH=3B CHDIR into "SUB1\SUB2"
 *   - AH=47 GETCWD and print it (must read back the normalized "SUB1\SUB2")
 *   - open a file by a RELATIVE name from the new CWD (resolves against CWD)
 *   - open a file in the PARENT via "..\\" (dot-dot resolution)
 *   - AH=3B CHDIR ".." (one level up); GETCWD again (must be "SUB1")
 *   - AH=3B CHDIR "\\" back to root; GETCWD again (must be empty)
 *
 * Each INT 21h dir op prints carry+AX; GETCWD prints the returned path. The
 * tree is created and torn down at runtime. Relative file resolution is shown
 * by reading the in-CWD file by its bare name and the parent file via "..".
 */
#include <stdio.h>
#include <string.h>
#include <dos.h>

static int do_mkdir(const char *path)
{
    union REGS r; struct SREGS s;
    segread(&s);
    r.h.ah = 0x39; r.x.dx = FP_OFF(path); s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    return r.x.cflag ? r.x.ax : 0;
}

static int do_rmdir(const char *path)
{
    union REGS r; struct SREGS s;
    segread(&s);
    r.h.ah = 0x3A; r.x.dx = FP_OFF(path); s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    return r.x.cflag ? r.x.ax : 0;
}

/* CHDIR via INT 21h AH=3B; print carry + AX. */
static void do_chdir(const char *path)
{
    union REGS r; struct SREGS s;
    segread(&s);
    r.h.ah = 0x3B; r.x.dx = FP_OFF(path); s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    printf("chdir %-12s cf=%d ax=%d\n", path, r.x.cflag ? 1 : 0,
           r.x.cflag ? r.x.ax : 0);
}

/* GETCWD via INT 21h AH=47 (DL=0 default drive); print the returned path. */
static void show_cwd(void)
{
    union REGS r; struct SREGS s;
    char path[80];
    segread(&s);
    r.h.ah = 0x47; r.h.dl = 0;
    r.x.si = FP_OFF(path); s.ds = FP_SEG(path);
    intdosx(&r, &r, &s);
    printf("getcwd cf=%d -> [%s]\n", r.x.cflag ? 1 : 0, path);
}

static void make_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(text, 1, strlen(text), f); fclose(f); }
}

static void read_file(const char *path)
{
    char buf[64];
    int n;
    FILE *f = fopen(path, "rb");
    if (!f) { printf("open %-14s FAIL\n", path); return; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    printf("open %-14s -> [%s]\n", path, buf);
}

int main(void)
{
    do_mkdir("SUB1");
    do_mkdir("SUB1\\SUB2");
    make_file("SUB1\\TOP.TXT", "top level file");
    make_file("SUB1\\SUB2\\INNER.TXT", "inner file");

    show_cwd();                 /* at root: empty */
    do_chdir("SUB1\\SUB2");
    show_cwd();                 /* SUB1\SUB2 */

    read_file("INNER.TXT");     /* relative to CWD */
    read_file("..\\TOP.TXT");   /* dot-dot to parent */

    do_chdir("..");             /* up one level */
    show_cwd();                 /* SUB1 */
    read_file("TOP.TXT");       /* now relative to SUB1 */

    do_chdir("\\");             /* back to root */
    show_cwd();                 /* empty */

    /* tear down */
    remove("SUB1\\SUB2\\INNER.TXT");
    remove("SUB1\\TOP.TXT");
    do_rmdir("SUB1\\SUB2");
    do_rmdir("SUB1");

    printf("CDTEST done\n");
    return 0;
}
