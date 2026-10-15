// Lvalues and the expressions built on them: members and bit-fields, `*p`, increments, compound assignment,
// pointer arithmetic, temporaries of rvalue structs, compound literals, VLAs, statement expressions and
// `_Generic`.
struct S { int x; unsigned f : 3; int arr[2]; };
struct S make(void);
typedef int (*fptr)(int);
int id(int i) { return i; }

int lvalues(struct S *s, int n) {
    int vla[n];
    s->f += 5;
    s->arr[1]++;
    int *p = &s->x;
    p += 2;
    long diff = p - &s->x;
    int t = make().arr[1];
    int *lit = (int[]){ 1, 2, 3 };
    unsigned long size = sizeof vla;
    int g = ({ int y = n * 2; y + 1; });
    int sel = _Generic(id, fptr: 3, default: 4) + _Generic((const int)n, int: 1, const int: 2);
    return *p + (int)diff + t + lit[2] + (int)size + g + sel;
}
