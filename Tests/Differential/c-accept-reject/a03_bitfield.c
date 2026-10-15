struct S{ unsigned a:3; signed b:5; unsigned :0; _Bool c:1; }; int f(struct S s){ return s.a + s.b; }
