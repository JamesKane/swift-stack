int a(int); int b(int); int (*tab[2])(int) = { a, b }; int call(int i){ return tab[i](i); }
