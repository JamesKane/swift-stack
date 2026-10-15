struct S{ union { int a; float b; }; struct { int c; }; }; int f(struct S s){ return s.a + s.c; }
