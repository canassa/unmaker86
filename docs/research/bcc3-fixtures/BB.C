struct Pixel { int x; int y; unsigned char color; };
enum Mode { TEXT, GRAPHICS, HIRES };

int g_frames;

int clamp(int v, int lo, int hi)
{
    int r;
    r = v;
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}

int main(void)
{
    struct Pixel p;
    enum Mode m;
    int i;
    m = GRAPHICS;
    p.x = clamp(300, 0, 319);
    p.y = clamp(250, 0, 199);
    p.color = 15;
    for (i = 0; i < 3; i++) {
        g_frames = g_frames + 1;
    }
    return p.x + p.y + (int)m;
}
