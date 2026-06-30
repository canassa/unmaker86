/* BBCPP.CPP - Tier-3 C++ class black-box fixture (distinct from CLS/MI/LCLS).
   Exercises: an enum, a base class with data members + a virtual method, a
   derived class (single inheritance) adding a data member + overriding the
   method, and a main() with locals of both class types and of the enum type.
   Compiled with BC++ 3.1: bcc -v -ml (large model, C++). */

enum Shape { CIRCLE, SQUARE, TRIANGLE };

class Entity {
public:
    int id;
    int hp;
    virtual int kind() { return CIRCLE; }
};

class Monster : public Entity {
public:
    int damage;
    int kind() { return SQUARE; }
};

Entity g_entity;
Monster g_monster;

int main(void)
{
    Entity e;
    Monster m;
    enum Shape s = TRIANGLE;
    return e.kind() + m.kind() + (int)s;
}
