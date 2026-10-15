// Structured control flow (C23 6.8): loops, `switch` with its labels, `goto`, labels, `break`/`continue`, and GNU
// computed `goto`.
int control(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        if (i % 3 == 0) continue;
        if (i > 100) break;
        sum += i;
    }
    while (n > 0) n--;
    do { sum++; } while (sum < 10);
    switch (sum) {
    case 1: sum = 2;
    case 2 ... 4: break;
    default: goto out;
    }
again:
    if (sum < 0) goto again;
out:;
    static void *targets[] = { &&again, &&out };
    goto *targets[n & 1];
}
