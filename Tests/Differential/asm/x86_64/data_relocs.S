// Regression corpus: PC-relative data, `.size` with `.`, `.set` symbols, target macros, relaxation.
#ifndef __x86_64__
#error "x86_64 target macro missing"
#endif
#if defined(__aarch64__) || defined(__riscv)
#error "foreign target macro leaked into x86_64 preprocessing"
#endif

.set COUNT, 3
.equ STRIDE, COUNT * 8

    .text
    .globl  f
    .type   f, @function
f:
    pushq   %rbp
    movq    %rsp, %rbp
1:  decq    %rdi
    jnz     1b
    jmp     far_away
    .space  200, 0x90
far_away:
    call    ext_fn
    movl    $STRIDE, %eax
    popq    %rbp
    ret
    .size   f, . - f

    .section .rodata
    .balign 8
table:
    .long   ext_sym - .
    .quad   ext_sym - .
    .long   f - .
    .quad   f
    .long   far_away - f
    .byte   1, 2, 3
    .size   table, . - table
