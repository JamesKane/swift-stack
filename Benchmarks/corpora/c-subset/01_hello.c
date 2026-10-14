long write(int fd, char *buf, long count);

int main() {
    write(1, "Hello from Swift-Stack M0.5!\n", 29);
    return 0;
}
