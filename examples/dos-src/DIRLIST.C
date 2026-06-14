/* DIRLIST — findfirst/findnext (INT 21h AH=4E/4F) over a committed multi-file
 * subdirectory, with two masks: "*.*" (all files) and "*.TXT" (wildcard subset).
 * The matched names are sorted IN-PROGRAM before printing so the output is
 * deterministic regardless of directory-enumeration order. Exercises find-first/
 * find-next breadth + DOS wildcard matching. Only names are printed (sizes/dates
 * could vary); names are fully deterministic. */
#include <stdio.h>
#include <string.h>
#include <dir.h>

#define MAX 64

static int scan(const char *mask, char names[][13])
{
    struct ffblk fb;
    int count = 0;
    int done;

    done = findfirst(mask, &fb, 0);   /* attr 0 = normal files only */
    while (done == 0 && count < MAX) {
        strcpy(names[count], fb.ff_name);
        count++;
        done = findnext(&fb);
    }
    return count;
}

static int cmpname(const char *a, const char *b)
{
    return strcmp(a, b);
}

/* simple deterministic insertion sort over fixed-size name records */
static void sortnames(char names[][13], int n)
{
    int i, j;
    char tmp[13];
    for (i = 1; i < n; i++) {
        strcpy(tmp, names[i]);
        j = i - 1;
        while (j >= 0 && cmpname(names[j], tmp) > 0) {
            strcpy(names[j + 1], names[j]);
            j--;
        }
        strcpy(names[j + 1], tmp);
    }
}

static void report(const char *mask, char names[][13])
{
    int n, i;
    n = scan(mask, names);
    sortnames(names, n);
    printf("mask %s: %d entries\n", mask, n);
    for (i = 0; i < n; i++)
        printf("  %s\n", names[i]);
}

int main(void)
{
    static char names[MAX][13];

    report("DIR\\*.*", names);
    report("DIR\\*.TXT", names);
    return 0;
}
