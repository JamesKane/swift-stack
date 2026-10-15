// Objects with static storage and their addresses: external, internal and thread-local objects, block-scope
// statics, string literals, address constants in initializers, functions and function pointers, and extern
// declarations (undefined symbols).
extern int ext;
int counter = 3;
static const char *names[] = { "zero", "one" };
_Thread_local int tls;
int (*hook)(const char *, ...);
int printf(const char *, ...);

static int next(void) {
    static int calls;
    return ++calls + counter;
}

int use(int i) {
    tls += i;
    hook = printf;
    hook("%s %d\n", names[i & 1], next());
    return ext + tls + (int)sizeof names;
}
