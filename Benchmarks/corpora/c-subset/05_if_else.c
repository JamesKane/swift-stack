int main() {
    int a = 15;
    int b = 25;
    int result = 0;

    if (a < b) {
        result = result + 10; // 10
    } else {
        result = result + 100;
    }

    if (a == 15) {
        result = result + 20; // 30
    }

    if (b != 25) {
        result = result + 1000;
    } else {
        result = result + 40; // 70
    }

    return result;
}
