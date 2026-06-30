class Base { public: int bx; virtual int who(){return 1;} };
class Derived : public Base { public: int dy; int who(){return 2;} };
Base g_base;
Derived g_der;
int main(void){ Base *p = &g_der; return p->who(); }
