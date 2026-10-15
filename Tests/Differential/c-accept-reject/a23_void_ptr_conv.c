void *malloc(unsigned long); void f(void){ int *p = malloc(4); void *q = p; p = q; }
