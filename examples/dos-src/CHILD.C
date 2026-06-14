/* CHILD — a child process spawned by SPAWN.EXE via INT 21h AH=4B AL=00
 * (load-and-execute). Exercises the child PSP/env/cmdtail plumbing: it prints a
 * line, reads an environment variable the parent set, echoes its own argv, then
 * exits with a specific nonzero code so the parent can capture it via AH=4D /
 * the spawn() return. The exit code (7) is the load-bearing observable. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    char *who;
    int i;

    printf("child: hello from CHILD.EXE\n");

    /* The parent sets CHILDVAR in the environment before spawning; reading it
     * back proves the child inherited (or was handed) a real environment block
     * via its PSP offset 0x2C. */
    who = getenv("CHILDVAR");
    printf("child: CHILDVAR=%s\n", who ? who : "(null)");

    /* Echo argv so the command tail at PSP:0x80 -> the child's real argv is
     * exercised end to end. */
    printf("child: argc=%d\n", argc);
    for (i = 1; i < argc; i++)
        printf("child: argv[%d]=%s\n", i, argv[i]);

    return 7;
}
