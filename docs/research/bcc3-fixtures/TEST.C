struct Point { int x; int y; };
int g_total = 0;

int add(int a, int b)
{
    int sum;
    sum = a + b;
    return sum;
}

int main(void)
{
    struct Point p;
    p.x = 3;
    p.y = 4;
    g_total = add(p.x, p.y);
    return g_total;
}
