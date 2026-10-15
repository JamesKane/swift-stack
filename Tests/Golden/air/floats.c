// Floating arithmetic and conversions (C23 6.3.1.4-6.3.1.8): float, double and the x87 long double, conversions
// to and from signed and unsigned integers and `bool`, comparisons (ordered, `!=` unordered), increments.
double mix(float f, double d, long double ld, int i, unsigned long u) {
    double r = f * d + i;
    r -= (double)u;
    ld /= r;
    f++;
    return r + (double)ld + (f < d) + (d != r);
}

int to_int(double d, long double ld) {
    unsigned u = d;
    _Bool b = ld;
    return (int)d + (int)u + b + (int)-ld;
}

float narrow(double d) { return (float)d * 0.5f; }
