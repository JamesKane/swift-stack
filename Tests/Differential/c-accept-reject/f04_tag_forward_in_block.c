struct A { int a; }; void f(void) { struct A; struct A *p = 0; p->a = 1; }
