int f(int n){ int a[n]; int (*p)[n] = &a; return sizeof(a) + (int)sizeof(*p); }
