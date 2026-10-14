int main() {
    int a = 0x0F;
    int b = 0xF0;
    int c = a | b; // 0xFF = 255
    int d = c & 0x55; // 0x55 = 85
    int e = d ^ 0x0F; // 0x55 ^ 0x0F = 0x5A = 90
    int f = (e << 1) >> 2; // (90 * 2) / 4 = 180 / 4 = 45
    return f;
}
