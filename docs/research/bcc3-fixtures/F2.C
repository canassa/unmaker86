struct Node { int value; struct Node *next; };
typedef int (*FuncPtr)(int, int);
enum State { IDLE, RUNNING, DONE };
int g_state = 0;
struct Node g_nodes[4];
long process(struct Node *n, int depth)
{
    long total;
    int i;
    char buf[4];
    total = 0;
    for (i = 0; i < depth; i++) {
        buf[0] = (char)i;
        total += n->value + buf[0];
        n = n->next;
    }
    return total;
}
