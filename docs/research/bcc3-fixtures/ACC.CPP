/* ACC.CPP - Tier-3 review fixture: base/member ACCESS recoverability + member kinds.
   Public vs private vs protected base of the SAME base class, plus a class carrying a
   non-virtual method, a static data member, a constructor and a destructor, and both a
   public and a private data member. Compiled with BC++ 3.1: bcc -v -ml. */

class Base {
public:
    int b;
};

class Pub : public Base {
public:
    int px;
};

class Pri : private Base {
public:
    int qx;
};

class Prot : protected Base {
public:
    int rx;
};

class Acc {
public:
    int pub_data;
    static int s_count;
    Acc();
    ~Acc();
    int method(int a);
private:
    int priv_data;
};

int Acc::s_count = 0;
Acc::Acc() { pub_data = 1; priv_data = 2; }
Acc::~Acc() { }
int Acc::method(int a) { return pub_data + priv_data + a; }

Base g_base;
Pub  g_pub;
Pri  g_pri;
Prot g_prot;
Acc  g_acc;

int main(void)
{
    Acc a;
    return a.method(1) + g_pub.b + g_pub.px;
}
