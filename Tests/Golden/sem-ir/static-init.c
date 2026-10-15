// Data images of static objects (C23 6.7.10): integers and floats in their formats, address constants as
// relocations, strings, designators and ranges, brace elision, a flexible array member, bit-fields, unions,
// compound literals, `asm` labels and block-scope statics.
struct P { long c[2]; long b; };
struct B { signed a : 3; unsigned b : 5; long long c : 40; };
union U { char c; double d; };
struct F { int n; short fam[]; };

int counter = 7;
long double ld = 1.0L / 3;
float fl = 0.1f;
char text[] = "hi";
char exact[2] = "hi";
int *ptr = &counter;
char *mid = "string" + 3;
int range[6] = { [1 ... 3] = 9, [5] = 1 };
struct P elided[] = { 1, 2, 3, 4, 5 };
struct B bits = { -1, 31, -2 };
union U u = { .d = -2.5 };
struct F flex = { 2, { 10, 20 } };
int *cl = (int[]){ 4, 5 };
extern int renamed(int) __asm__("renamed_v2");
int (*rp)(int) = renamed;
long addr = (long)&counter;

int *keep(void) {
    static int local = 3;
    return &local;
}
