// Regression corpus: PC-relative data, `.size` with `.`, `ldr` literal forms, target macros.
#ifndef __aarch64__
#error "aarch64 target macro missing"
#endif
#if defined(__x86_64__) || defined(__riscv)
#error "foreign target macro leaked into aarch64 preprocessing"
#endif

.set COUNT, 3

    .text
    .globl  f
    .type   f, @function
f:
    ldr     x0, #64
    ldr     w3, #-8
    ldr     x1, lit
    cbz     x0, 1f
    tbz     x2, #3, 1f
    b.ne    1f
    bl      ext_fn
1:  mov     x0, #COUNT
    ret
    .p2align 3
lit:
    .quad   0x1122334455667788
    .size   f, . - f

    .section .rodata
    .p2align 3
table:
    .long   ext_sym - .
    .quad   ext_sym - .
    .long   f - .
    .quad   f
    .size   table, . - table
