extern int compute(int, int);
extern long process(void *p, int d);
int main(void)
{
    int r;
    long t;
    r = compute(3, 4);
    t = process(0, r);
    return (int)t;
}
