struct Point { int x; int y; int z; };
struct Rect { struct Point tl; struct Point br; long area; char name[8]; };
union Variant { int i; long l; char c; struct Point p; };
enum Color { RED, GREEN=5, BLUE };
typedef struct Point PointT;
typedef unsigned char byte;
int g_count = 0;
struct Rect g_rect;
int compute(int a, int b)
{
    int local1;
    long local2;
    struct Point pt;
    int *ap;
    local1 = a + b;
    ap = &local1;
    local2 = (long)(*ap) * 2;
    pt.x = local1; pt.y = (int)local2; pt.z = 0;
    {
        int inner;
        inner = pt.x + pt.y;
        local1 = inner;
    }
    return local1;
}
