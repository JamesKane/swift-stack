#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#define AB(x) CAT(x,y)
#define foo foo
int foo; int f(void) { int xy = 42; return CAT(A,B)(x); }
