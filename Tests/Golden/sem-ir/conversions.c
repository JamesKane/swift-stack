// Implicit conversions (C23 6.3): promotions, the usual arithmetic conversions, conversions as if by assignment,
// lvalue conversion, array and function decay, null pointer constants, tests against zero, and default argument
// promotions.
int printf(const char *, ...);
int takes_long(long);

int conversions(char c, unsigned short us, int i, unsigned u, long l, float f, double d) {
    int a[4];
    int *p = a;
    int (*fp)(long) = takes_long;
    void *v = 0;
    _Bool b = p;
    long double ld = f;
    i = c + us;
    l = i * u;
    d = f + l;
    u = d;
    p = nullptr;
    if (v && !fp) i = -c;
    printf("%f %d\n", f, c);
    return fp(i) + (i < u) + b + (int)ld;
}
