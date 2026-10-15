// Control flow (C23 6.8): conditions on comparisons and logical operators, loops with `break`/`continue`,
// `switch` with fallthrough, a GNU case range wide enough to be tested, `goto`, `?:` and computed `goto`.
int loops(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        if (i % 3 == 0 || i == 7) continue;
        if (i > 100 && n < 1000) break;
        sum += i;
    }
    while (n-- > 0) sum ^= n;
    do sum++; while (sum < 10);
    return sum > 0 ? sum : -sum;
}

int classify(int c) {
    int kind = 0;
    switch (c) {
    case 'a' ... 'e':
        kind = 1;
    case 'x':
        kind += 2;
        break;
    case 1000 ... 2000:
        kind = 3;
        break;
    default:
        goto out;
    }
    kind *= 2;
out:
    return kind;
}

int dispatch(int i) {
    static void *table[] = { &&one, &&two };
    goto *table[i & 1];
one:
    return 1;
two:
    return 2;
}
