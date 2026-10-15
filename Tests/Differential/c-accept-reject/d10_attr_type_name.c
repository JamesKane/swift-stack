int f(void); int call(void *p) { return ((__attribute__((noinline)) int (*)(void))p)(); }
