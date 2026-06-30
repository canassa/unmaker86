class A { public: int ax; virtual int fa() { return 1; } virtual int fz() { return 9; } };
class B { public: int bx; virtual int fb() { return 2; } };
class C : public A, public B { public: int cx; int fa() { return 3; } int fb() { return 4; } virtual int fc() { return 5; } };
A g_a;
B g_b;
C g_c;
int main(void) {
    A *p = &g_c;
    B *q = &g_c;
    return p->fa() + q->fb() + g_c.fc();
}
