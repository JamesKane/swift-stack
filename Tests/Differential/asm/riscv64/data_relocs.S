// Regression corpus: ADD/SUB pairs for symbol differences, `.size` with `.`, branches, target macros.
#ifndef __riscv
#error "riscv target macro missing"
#endif
#if defined(__x86_64__) || defined(__aarch64__)
#error "foreign target macro leaked into riscv64 preprocessing"
#endif

.set COUNT, 3

    .text
    .globl  f
    .type   f, @function
f:
    li      a1, COUNT
1:  addi    a1, a1, -1
    bnez    a1, 1b
    beq     a0, a2, 2f
    j       2f
    call    ext_fn
2:  ret
    .size   f, . - f

    .section .rodata
    .p2align 3
table:
    .long   ext_sym - .
    .quad   ext_sym - .
    .long   f - .
    .quad   f
    .size   table, . - table
