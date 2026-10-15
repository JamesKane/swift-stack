struct S{char c;}; int f(void){ struct S{double d; double e;}; return sizeof(struct S); } static_assert(sizeof(struct S)==1);
