int use(void) {
    class Local { public: int lx; virtual int g() { return 7; } };
    Local lo;
    return lo.g();
}
class Glob { public: int gx; virtual int h() { return 8; } };
Glob gg;
int main(void) { return use() + gg.h(); }
