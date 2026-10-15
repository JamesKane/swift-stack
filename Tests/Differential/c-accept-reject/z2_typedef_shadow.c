typedef int T; void f(void){ typedef double T; static_assert(sizeof(T)==8); }
