alignas(16) int x; _Alignas(double) char c; int f(void){ return alignof(long double) + _Alignof(int); }
