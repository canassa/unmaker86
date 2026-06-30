char _es *g_esp = 0;
char _cs *g_csp = 0;
char _ss *g_ssp = 0;
int pascal padd(int a, int b) { return a + b; }
void interrupt isr(void) { }
int cdecl cadd(int a, int b) { return a + b; }
int main(void) { return padd(1, 2) + cadd(3, 4); }
