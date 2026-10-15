// Atomics, volatile accesses, builtins and inline `asm`: the GNU `__atomic` and legacy `__sync` builtins,
// compare-and-exchange, fences, volatile loads and stores, bit counting, byte swaps, overflow checks, and `asm`
// with outputs, inputs, clobbers and a symbolic name.
int value;
volatile int *mmio;

int atomics(int x) {
    int old = __atomic_fetch_add(&value, x, __ATOMIC_RELAXED);
    __atomic_store_n(&value, old, __ATOMIC_RELEASE);
    int expected = 1;
    _Bool swapped = __atomic_compare_exchange_n(&value, &expected, 2, 0, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    return __sync_add_and_fetch(&value, 1) + swapped + __atomic_load_n(&value, __ATOMIC_ACQUIRE);
}

unsigned bits(unsigned x, unsigned long y) {
    *mmio = 1;
    (void)*mmio;
    int sum;
    if (__builtin_add_overflow(x, (int)y, &sum)) return 0;
    return __builtin_clz(x) + __builtin_popcountl(y) + __builtin_bswap32(x) + (unsigned)__builtin_expect(sum, 0);
}

unsigned long cycles(void) {
    unsigned lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), [high] "=d"(hi) : : "memory");
    return (unsigned long)hi << 32 | lo;
}
