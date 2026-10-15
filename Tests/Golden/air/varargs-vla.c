// Variadic functions and variable length arrays (C23 7.16, 6.7.7.3): `va_start`/`va_arg`/`va_copy`/`va_end`,
// promoted arguments, a VLA whose storage is released at the end of its block and by `break`, `sizeof` of a VLA,
// pointer arithmetic on a pointer to a VLA, and `__builtin_alloca`.
#include <stdarg.h>

double sum(int n, ...) {
    va_list ap, copy;
    va_start(ap, n);
    va_copy(copy, ap);
    double total = 0;
    for (int i = 0; i < n; i++) total += va_arg(ap, double);
    va_end(copy);
    va_end(ap);
    return total;
}

double call(float f) { return sum(2, f, 1); }

long matrix(int rows, int cols) {
    long total = 0;
    for (int r = 0; r < rows; r++) {
        int row[cols];
        if (r > 10) break;
        row[0] = r;
        total += row[0] + (long)sizeof row;
    }
    int (*m)[cols] = __builtin_alloca(rows * sizeof *m);
    return total + m[1][2];
}
