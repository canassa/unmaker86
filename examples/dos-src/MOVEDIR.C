/* MOVEDIR — cross-directory file move via INT 21h AH=56 (rename).
 *
 * Exercises (D8b): rename where the OLD and NEW paths are in DIFFERENT
 * subdirectories — both multi-component paths must resolve through the tree
 * walker, and the move must land the file in the destination directory.
 *   - build SUB1 and SUB2 (siblings under the root)
 *   - create SUB1\FROM.TXT
 *   - rename SUB1\FROM.TXT -> SUB2\TO.TXT  (cross-directory move)
 *   - confirm the source is gone and the destination reads back the payload
 *
 * The C runtime's rename() issues AH=56. The tree is created and torn down at
 * runtime so reruns are stable.
 */
#include <stdio.h>
#include <string.h>
#include <dir.h>

int main(void)
{
    FILE *f;
    char buf[64];
    int n;
    const char *payload = "moved across dirs 2468";

    mkdir("SUB1");
    mkdir("SUB2");

    f = fopen("SUB1\\FROM.TXT", "wb");
    if (!f) { printf("FAIL: create SUB1\\FROM.TXT\n"); return 1; }
    fwrite(payload, 1, strlen(payload), f);
    fclose(f);

    if (rename("SUB1\\FROM.TXT", "SUB2\\TO.TXT") != 0) {
        printf("FAIL: rename across dirs\n"); return 2;
    }
    printf("rename SUB1\\FROM.TXT -> SUB2\\TO.TXT OK\n");

    /* source must be gone */
    f = fopen("SUB1\\FROM.TXT", "rb");
    if (f) { printf("FAIL: source still present\n"); fclose(f); return 3; }

    /* destination must read back the payload */
    f = fopen("SUB2\\TO.TXT", "rb");
    if (!f) { printf("FAIL: open destination\n"); return 4; }
    n = (int)fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    printf("dest read %d bytes: %s\n", n, buf);

    /* tear down */
    remove("SUB2\\TO.TXT");
    rmdir("SUB1");
    rmdir("SUB2");

    printf("MOVEDIR done\n");
    return 0;
}
