// Aggregates in memory (C23 6.7.10, 6.5.2.3): initializer lists with designators and a GNU range, string
// initializers, bit-fields (signed, unsigned, `bool`), struct assignment, arguments and results by value, compound
// literals, unions, and member access through pointers.
struct point { int x, y; };
struct flags { unsigned a : 3; signed b : 5; _Bool c : 1; unsigned long long d : 40; };
union number { int i; float f; };

struct point make(int x) {
    struct point p = { .y = x };
    return p;
}

int fields(struct flags *f, struct flags g) {
    f->a = g.b;
    f->b = -3;
    f->d += 1;
    return f->a + f->b + g.c + (int)f->d;
}

int arrays(int i) {
    int a[16] = { [2] = 1, [4 ... 15] = i };
    char s[8] = "hi";
    struct point ps[2] = { { 1, 2 }, make(i) };
    ps[0] = ps[1];
    union number n = { .f = 1.5f };
    int *p = (int[]){ 7, 8, 9 };
    return a[i] + s[1] + ps[0].y + n.i + p[2] + make(i).x;
}
