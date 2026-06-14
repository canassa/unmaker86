/* DIRSCAN — findfirst/findnext (INT 21h AH=4E/4F) with a DIRECTORY-PATH prefix
 * mask (not just the mount root), plus the subdirectory attribute bit.
 *
 * Exercises (D8b):
 *   - a mask "SUB1\*.*" that scans INSIDE a subdirectory (path prefix on the
 *     mask, the directory portion must resolve through the tree walker)
 *   - attr=0x10 (FA_DIREC) so subdirectory entries are returned, and the
 *     directory-attribute bit (ff_attrib & 0x10) is reported per entry
 *   - a deeper mask "SUB1\SUB2\*.TXT" (two-level prefix + extension wildcard)
 *
 * The tree is built at runtime: SUB1 holds A.TXT, B.DAT and the subdir SUB2;
 * SUB2 holds X.TXT and Y.TXT. Entries are sorted in-program before printing so
 * output is enumeration-order independent. For each entry we print the name and
 * whether it is a directory, so the golden pins the attribute bit. ("." / ".."
 * are skipped — dosbox-x's LocalDrive does not synthesize them, and we want a
 * stable set.)
 */
#include <stdio.h>
#include <string.h>
#include <dir.h>
#include <dos.h>   /* FA_DIREC */

#define MAX 32

/* One scanned entry: name + is-directory flag, kept together so the sort and
 * the print stay paired. */
struct ent { char name[13]; int isdir; };

static int scan(const char *mask, struct ent *out)
{
    struct ffblk fb;
    int count = 0;
    int done;

    /* attr 0x10 (FA_DIREC) => include subdirectories as well as normal files */
    done = findfirst(mask, &fb, FA_DIREC);
    while (done == 0 && count < MAX) {
        if (strcmp(fb.ff_name, ".") != 0 && strcmp(fb.ff_name, "..") != 0) {
            strcpy(out[count].name, fb.ff_name);
            out[count].isdir = (fb.ff_attrib & FA_DIREC) ? 1 : 0;
            count++;
        }
        done = findnext(&fb);
    }
    return count;
}

static void sort_ents(struct ent *e, int n)
{
    int i, j;
    struct ent tmp;
    for (i = 1; i < n; i++) {
        tmp = e[i];
        j = i - 1;
        while (j >= 0 && strcmp(e[j].name, tmp.name) > 0) {
            e[j + 1] = e[j];
            j--;
        }
        e[j + 1] = tmp;
    }
}

static void report(const char *mask)
{
    struct ent e[MAX];
    int n, i;
    n = scan(mask, e);
    sort_ents(e, n);
    printf("mask %s: %d entries\n", mask, n);
    for (i = 0; i < n; i++)
        printf("  %-12s %s\n", e[i].name, e[i].isdir ? "<DIR>" : "file");
}

int main(void)
{
    FILE *f;

    mkdir("SUB1");
    mkdir("SUB1\\SUB2");
    f = fopen("SUB1\\A.TXT", "wb"); if (f) { fputs("a", f); fclose(f); }
    f = fopen("SUB1\\B.DAT", "wb"); if (f) { fputs("b", f); fclose(f); }
    f = fopen("SUB1\\SUB2\\X.TXT", "wb"); if (f) { fputs("x", f); fclose(f); }
    f = fopen("SUB1\\SUB2\\Y.TXT", "wb"); if (f) { fputs("y", f); fclose(f); }

    report("SUB1\\*.*");
    report("SUB1\\SUB2\\*.TXT");

    /* tear down */
    remove("SUB1\\A.TXT");
    remove("SUB1\\B.DAT");
    remove("SUB1\\SUB2\\X.TXT");
    remove("SUB1\\SUB2\\Y.TXT");
    rmdir("SUB1\\SUB2");
    rmdir("SUB1");

    printf("DIRSCAN done\n");
    return 0;
}
