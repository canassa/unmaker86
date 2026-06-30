enum Color { RED, GREEN=5, BLUE };
union Variant { int i; long l; double d; char c; };
struct Bits { unsigned a:3; unsigned b:5; int s:4; };
typedef int (*FuncPtr)(int, int);
enum Color g_color = GREEN;
union Variant g_var;
struct Bits g_bits;
double g_d = 3.5;
float g_f = 1.0;
unsigned long g_ul = 0;
char far *g_fp = 0;
char huge *g_hp = 0;
FuncPtr g_func = 0;
int dummy(int a, int b) { return a+b; }
int main(void){ g_func = dummy; return g_func(1,2); }
