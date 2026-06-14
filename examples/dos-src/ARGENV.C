/* ARGENV — print argc, each argv, and an environment variable. Exercises the
 * PSP command tail (offset 0x80) the CRT parses into argv, and the environment
 * block the PSP points at (offset 0x2C). The .args sidecar supplies the command
 * tail to BOTH the dosbox-x oracle and the zdos harness so the golden matches. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    int i;
    char *path;

    printf("argc=%d\n", argc);
    for (i = 0; i < argc; i++)
        printf("argv[%d]=%s\n", i, argv[i]);

    path = getenv("PATH");
    printf("PATH=%s\n", path ? path : "(null)");
    return 0;
}
