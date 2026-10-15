int (*rows)[4]; int (*tab[2])(int); int (*pick(int))(int); void (*sig(int, void (*)(int)))(int);
static_assert(sizeof(*rows) == 16 && sizeof(tab) == 16 && sizeof(int (*)[3]) == 8);
int use(void) { return tab[0](1) + pick(2)(3); }
