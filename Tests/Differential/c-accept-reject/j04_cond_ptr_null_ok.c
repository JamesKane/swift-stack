void f(int c, int *p) { int *q = c ? p : 0; (void)q; (void)(c ? (void)0 : 1); }
