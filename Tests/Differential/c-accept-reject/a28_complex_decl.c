typedef void (*sig_t)(int); sig_t signal(int, sig_t); void (*signal2(int sig, void (*func)(int)))(int);
