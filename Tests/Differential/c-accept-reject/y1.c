struct S{char c;}; int f(void){ struct S{double d;}; struct S s; return (int)s.d; }
