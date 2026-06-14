/* SUBDIR — open a file in a SUBDIRECTORY ("SUB\DATA.TXT") and print it.
 * Exercises subdirectory path resolution (DOS_MakeName component walking), the
 * KNOWN BaK blocker: zdos's single-dir VFS resolves only the final path
 * component, so "SUB\DATA.TXT" is expected to DIVERGE from dosbox-x (which walks
 * into SUB\). The committed corpus ships a SUB\ subdir with DATA.TXT. */
#include <stdio.h>

int main(void)
{
    FILE *f;
    char line[128];

    f = fopen("SUB\\DATA.TXT", "rb");
    if (!f) { printf("FAIL: cannot open SUB\\DATA.TXT\n"); return 1; }

    while (fgets(line, sizeof(line), f) != NULL)
        fputs(line, stdout);

    fclose(f);
    return 0;
}
