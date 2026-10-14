void swap(int *a, int *b) {
    int tmp = *a;
    *a = *b;
    *b = tmp;
}

int main() {
    int x = 10;
    int y = 20;
    swap(&x, &y);
    return x * 2 + y; // 20 * 2 + 10 = 50
}
