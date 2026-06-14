/* CSCANF — the Borland CRT stdin path: scanf("%d %s") then fgets() of the rest.
 * The CRT reads handle 0 via INT 21h AH=3F (block read on the stdin handle),
 * buffers it, and parses. Exercises the file-handle stdin read (AH=3F on handle
 * 0) under redirected input, validated against the dosbox-x golden minted with
 * `< CSCANF.in`. */
#include <stdio.h>
#include <string.h>

int main(void)
{
    int n = 0;
    char word[64];
    char line[128];

    word[0] = 0;
    if (scanf("%d %63s", &n, word) != 2)
        strcpy(word, "<none>");

    printf("n=%d word=%s\n", n, word);

    /* Consume the newline left by scanf, then read the next whole line. */
    fgets(line, sizeof(line), stdin); /* eats the rest of line 1 (the EOL) */
    if (fgets(line, sizeof(line), stdin) != NULL) {
        /* strip trailing CR/LF for a stable golden */
        int len = (int)strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = 0;
        printf("line2=[%s]\n", line);
    } else {
        printf("line2=<eof>\n");
    }
    return 0;
}
