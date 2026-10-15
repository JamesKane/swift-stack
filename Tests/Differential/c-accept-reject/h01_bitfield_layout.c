struct A { char c; int a:30; char d; }; struct B { short a:9, b:9, c:9; }; struct C { char a; int :0; char b; };
static_assert(sizeof(struct A) == 12 && sizeof(struct B) == 6 && sizeof(struct C) == 5);
struct __attribute__((packed)) P { char a; int b; }; static_assert(sizeof(struct P) == 5);
