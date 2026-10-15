// Regression corpus: `.equ`/`.set` whose value is a label difference (resolved at once when the labels are
// already fixed, after layout for forward references) used in immediates, data and `.size`, and GNU
// expression operator precedence.

    .section .rodata
msg:
    .ascii  "hello world\n"
    .equ    msg_len, . - msg
    .set    words, (msg_len + 3) >> 2

    .text
    .globl  f
    .type   f, %function
f:
    mov     x2, #msg_len
    ret
    .size   f, . - f

    .section .rodata
    .long   fwd_len, msg_len, words
    .quad   fwd_len * 2 + 1
    .p2align 3
tbl_start:
    .long   1, 2, 3
tbl_end:
    .equ    fwd_len, tbl_end - tbl_start
    .size   tbl_start, fwd_len

    .data
    .quad   3 == 1 + 2, 1 + 2 << 3, 6 & 3 * 2
    .quad   1 | 2 ^ 3, 3 + 1 | 1, 1 << 2 * 3
    .quad   1 < 2, 1 <> 2, -1 < 1, 2 == 2 < 3
    .quad   1 || 0 && 0, 4 ! -1 | 2, -16 >> 2, -7 % 2
