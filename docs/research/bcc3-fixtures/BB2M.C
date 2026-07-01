/* BB2.C — richer source-level-debugger fixture (zdos M-S2).
 * Exercises the type/frame features BB.C lacks:
 *   - a POINTER local (p) for deref + a <null> child (np)
 *   - an ARRAY local (arr)
 *   - a struct with a BITFIELD member (struct Bits)
 *   - a RECURSIVE function (fact) -> distinct frame_base per level
 * Small memory model (default) -> all near calls; a medium-model build
 * (BB2M.EXE, identical source) supplies the far-call variant.
 *
 * Built with Borland C++ 3.1 (TLINK 5.1) headless under dosbox-x, TDS 3.10 debug
 * info embedded (-v). The EXACT commands (from the repo root):
 *   small model :  bcc -v          -Id:\include -Ld:\lib BB2.C     (-> BB2.EXE)
 *   medium model:  bcc -v -mm      -Id:\include -Ld:\lib BB2M.C    (-> BB2M.EXE, far)
 *   listings    :  tdump BB2.EXE BB2.LST ; tdump BB2M.EXE BB2M.LST
 * driven the same way as examples/BB.EXE (see tools/bcc.sh + docs/research/
 * borland-bcc3-debug-format.md). D: is the toolchain mount (toolchain/bc31).
 */

struct Bits { unsigned a : 3; unsigned b : 5; unsigned c : 8; };

int g_calls;

int fact(int n)
{
    int r;
    if (n <= 1) return 1;
    r = n * fact(n - 1);
    g_calls = g_calls + 1;
    return r;
}

int main(void)
{
    int arr[4];
    int *p;
    int *np;
    struct Bits bits;
    int i;
    int sum;

    arr[0] = 10;
    arr[1] = 20;
    arr[2] = 30;
    arr[3] = 40;
    p = &arr[0];
    np = 0;
    bits.a = 5;
    bits.b = 17;
    bits.c = 200;
    sum = 0;
    for (i = 0; i < 4; i++) {
        sum = sum + arr[i];
    }
    sum = sum + fact(5);
    sum = sum + *p;
    return sum + (np == 0 ? 0 : 1) + bits.a;
}
