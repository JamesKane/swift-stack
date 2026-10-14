int add(int a, int b) {
    return a + b;
}

int square(int x) {
    return x * x;
}

int main() {
    int sum = add(10, 20); // 30
    int sq = square(5);     // 25
    return sum + sq;        // 55
}
