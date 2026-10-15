struct S{ union { int a; double b; }; char c; }; static_assert(sizeof(struct S)==16);
