/* FINDFILE — findfirst/findnext (INT 21h AH=4E/4F) coverage that EXTENDS the
 * existing DIRLIST/DIRSCAN band rather than duplicating it. New surface:
 *
 *   - the '?' single-char wildcard ("FILE?.DAT") — DIRLIST/DIRSCAN only use '*'.
 *   - the matched-file SIZE reported in the DTA (ff_fsize). Size comes from the
 *     file's byte length, which is DETERMINISTIC for files we write with fixed
 *     content (NOT host-mtime, which IS non-deterministic — proven by the band-9
 *     double-mint and by drive_local.cpp: find_size = stat.st_size, but
 *     find_date/find_time = localtime(stat.st_mtime)). So we print name + size +
 *     attribute, and NEVER the date/time.
 *   - find-next iteration over MANY entries (7 files), exercising the resume
 *     index beyond the 3-5 entries the existing programs cover.
 *   - a NO-MATCH glob ("*.XYZ") — findfirst returns nonzero; we report it.
 *   - a combined-extension glob ("*.DAT") to cross-check the '?' subset count.
 *
 * Work happens in a freshly-made subdirectory FFDIR that is created at the start
 * and fully removed at the end, so the committed corpus directory is byte-for-
 * byte identical before and after the run (the oracle and zdos both start from
 * the same committed state). Matches are sorted in-program before printing so
 * the output is independent of directory-enumeration order.
 */
#include <stdio.h>
#include <string.h>
#include <dir.h>

#define MAXN 32

/* One scanned entry: name + size + attribute, kept together for a paired sort. */
struct ent {
    char     name[13];
    long     size;
    unsigned attr;
};

static void makefile(const char *path, int nbytes)
{
    FILE *f;
    int i;
    f = fopen(path, "wb");
    if (f) {
        for (i = 0; i < nbytes; i++)
            fputc('x', f);
        fclose(f);
    }
}

static int scan(const char *mask, struct ent *out)
{
    struct ffblk fb;
    int count = 0;
    int done;

    done = findfirst(mask, &fb, 0);   /* attr 0 = normal files only */
    while (done == 0 && count < MAXN) {
        strcpy(out[count].name, fb.ff_name);
        out[count].size = fb.ff_fsize;
        out[count].attr = (unsigned)fb.ff_attrib;
        count++;
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
    struct ent e[MAXN];
    int n, i;
    n = scan(mask, e);
    if (n == 0) {
        printf("mask %s: no match\n", mask);
        return;
    }
    sort_ents(e, n);
    printf("mask %s: %d entries\n", mask, n);
    for (i = 0; i < n; i++)
        printf("  %-12s %5ld attr=%02X\n", e[i].name, e[i].size, e[i].attr);
}

int main(void)
{
    mkdir("FFDIR");

    /* Seven files, fixed deterministic byte lengths, two extensions. The
     * "FILE<N>" set is tailor-made to exercise the '?' single-char wildcard. */
    makefile("FFDIR\\FILE1.DAT", 1);
    makefile("FFDIR\\FILE2.DAT", 2);
    makefile("FFDIR\\FILE3.DAT", 3);
    makefile("FFDIR\\FILE10.DAT", 10);   /* 5-char stem: NOT matched by FILE?.DAT */
    makefile("FFDIR\\NOTES.TXT", 7);
    makefile("FFDIR\\READ.ME", 4);
    makefile("FFDIR\\DATA.DAT", 12);

    report("FFDIR\\*.DAT");      /* all .DAT (5 files) */
    report("FFDIR\\FILE?.DAT");  /* '?' wildcard: FILE1/2/3 only (FILE10 excluded) */
    report("FFDIR\\*.*");        /* everything (7 files) */
    report("FFDIR\\*.XYZ");      /* no match */

    /* tear down: remove every file then the directory, restoring committed state */
    remove("FFDIR\\FILE1.DAT");
    remove("FFDIR\\FILE2.DAT");
    remove("FFDIR\\FILE3.DAT");
    remove("FFDIR\\FILE10.DAT");
    remove("FFDIR\\NOTES.TXT");
    remove("FFDIR\\READ.ME");
    remove("FFDIR\\DATA.DAT");
    rmdir("FFDIR");

    printf("FINDFILE done\n");
    return 0;
}
