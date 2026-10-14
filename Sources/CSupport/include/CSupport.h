#ifndef CSUPPORT_H
#define CSUPPORT_H

#include <stdint.h>
#include <stddef.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline uint64_t ss_read_cycles(void) {
#if defined(__x86_64__) || defined(_M_X64)
    uint32_t lo, hi;
    __asm__ __volatile__ ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#elif defined(__aarch64__) || defined(_M_ARM64)
    uint64_t val;
    __asm__ __volatile__ ("mrs %0, cntvct_el0" : "=r"(val));
    return val;
#elif defined(__riscv)
    uint64_t val;
    __asm__ __volatile__ ("rdtime %0" : "=r"(val));
    return val;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

static inline uint64_t ss_read_timer_freq(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
    uint64_t frq;
    __asm__ __volatile__ ("mrs %0, cntfrq_el0" : "=r"(frq));
    return frq;
#else
    return 0;
#endif
}

uint64_t ss_monotonic_time_ns(void);

#ifdef __cplusplus
}
#endif

#endif /* CSUPPORT_H */
