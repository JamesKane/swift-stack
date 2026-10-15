// Integer arithmetic of every width and signedness (C23 6.5.5-6.5.7, 6.3.1): promotions, the usual arithmetic
// conversions, signed and unsigned division, remainder and right shift, shift counts of their own type, `_BitInt`
// and `__int128`, `bool`, and comparisons.
typedef unsigned _BitInt(24) u24;

int widths(signed char c, unsigned short s, int i, unsigned u, long l, unsigned long long ull) {
    long r = c * s;            // promoted to int, then converted
    r += i / u;                // unsigned division
    r += l % i;                // signed remainder in long
    r += (u >> 3) + (i >> 2);  // logical and arithmetic shifts
    r += l << c;               // the count keeps its own type
    r -= (ull > (unsigned long long)l) + (c < s) + (u <= 7u);
    return (int)r;
}

__int128 wide(__int128 a, unsigned __int128 b) {
    return a * (__int128)b - (a >> 100);
}

u24 bitint(u24 x, _BitInt(7) y) {
    x += y;
    return x * 3 + (u24)(x != 0);
}

_Bool flags(_Bool b, int x) {
    b = x;           // to bool: compared with 0
    b++;             // sets it
    return !b || x;
}

unsigned char narrow(unsigned char c) {
    c += 200;        // computed in int, truncated
    c = ~c;
    return c-- ^ -c;
}
