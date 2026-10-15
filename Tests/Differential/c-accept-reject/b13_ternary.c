struct S{int a;}; void f(int c){ struct S s; int *p; (void)(c ? s : p); }
