typedef int ti_int __attribute__((mode(TI))); typedef unsigned du_int __attribute__((mode(DI)));
static_assert(sizeof(ti_int) == 16 && sizeof(du_int) == 8 && (du_int)-1 > 0);
