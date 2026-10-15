struct S { char c; }; int f(void) { struct S { double d; } s = {1.0}; static_assert(sizeof(s) == 8); return (int)s.d; }
