enum Big { Z0, Z1, Z2, Z3=10, Z4, Z5=100, Z6, Z7=-5, Z8 };
enum Big g_big = Z5;
enum Small { SA, SB, SC };
enum Small g_small = SB;
int main(void) { return (int)g_big + (int)g_small; }
