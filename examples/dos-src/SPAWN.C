/* SPAWN — the PARENT. Prints "before", launches CHILD.EXE via Borland spawnl()
 * with P_WAIT (INT 21h AH=4B AL=00, load-and-execute), captures the child's
 * return code, and prints "after rc=N". The golden (minted by running SPAWN
 * under dosbox-x, which loads+runs CHILD) interleaves the parent's lines with
 * the child's output and ends with the captured rc — the truth zdos must
 * reproduce by faithfully running the child to termination and resuming the
 * parent (the full AH=4B / DOS_Terminate unwind).
 *
 * Before spawning, the parent sets CHILDVAR in the environment (putenv) so the
 * child can read it back, and passes a command-tail argument ("kid") so the
 * child's argv is exercised. */
#include <stdio.h>
#include <stdlib.h>
#include <process.h>

int main(void)
{
    int rc;

    printf("parent: before\n");
    fflush(stdout);

    /* Make a variable the child will inherit via its PSP environment block. */
    putenv("CHILDVAR=from-parent");

    /* P_WAIT: load CHILD.EXE, run it to completion, return its exit code.
     * arg0 is the program name (becomes the child's argv[0] path), then "kid",
     * then the NULL terminator. */
    rc = spawnl(P_WAIT, "CHILD.EXE", "CHILD.EXE", "kid", NULL);

    if (rc == -1) {
        printf("parent: spawn failed\n");
        return 1;
    }

    printf("parent: after rc=%d\n", rc);
    return 0;
}
