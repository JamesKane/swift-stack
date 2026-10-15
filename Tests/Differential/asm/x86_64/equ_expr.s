// Regression corpus: `.equ`/`.set` whose value is a label difference (backward and forward references,
// across an alignment, chained, used in immediates, displacements, data and `.size`; an alias of an undefined
// symbol redirects relocations to it), and the GNU-style expression operator precedence LLVM MC uses for ELF
// (`* / % << >>` > `| & ^ !` > `+ -` > comparisons (-1 = true) > `&&` > `||`).

    .text
    .globl  f
    .type   f, @function
f:
    movl    $msg_len, %edx
    movl    $fwd_len, %ecx
    leaq    msg(%rip), %rsi
    movl    fwd_len(%rdi), %eax
    movl    $count, %eax
    ret
    .size   f, fwd_len

    .section .rodata
msg:
    .ascii  "hello world\n"
    .equ    msg_len, . - msg
    .set    back_len, msg_len * 2
    .long   msg_len, back_len
    .long   fwd_len
    .quad   fwd_len + 1
    .byte   fwd_len
    .p2align 3
tbl_start:
    .long   1, 2, 3
tbl_end:
    .equ    fwd_len, tbl_end - tbl_start
    .set    alias, tbl_start + 4
    .long   alias - msg
    .equ    count, (tbl_end - tbl_start) / 4
    .long   count
    len2 = tbl_end - msg
    .short  len2
    .size   msg, msg_len

    .data
    .quad   alias_ext
    .set    alias_ext, ext + 8
    .long   alias_ext - .
prec:
    .quad   3 == 1 + 2
    .quad   1 + 2 << 3
    .quad   2 << 3 + 1
    .quad   2 * 3 << 1
    .quad   6 & 3 * 2
    .quad   1 < 2, 2 < 1, 1 <> 2, 3 >= 3, -1 < 1
    .quad   1 && 2, 0 || 3, !0, !5
    .quad   5 ! 1
    .quad   -7 / 2, -7 % 2, -16 >> 2
    .quad   1 == 1 && 2 == 2
    .quad   1 ^ 3 & 2, 1 & 3 ^ 2
    .quad   1 | 2 ^ 3, 3 ^ 1 | 2, 3 | 1 & 2
    .quad   3 + 1 | 1, 1 | 1 + 3
    .quad   1 << 2 * 3, 8 >> 1 * 2, 5 % 3 << 1
    .quad   1 || 0 && 0
    .quad   4 ! -1 | 2
    .quad   2 == 2 < 3, 1 - 1 == 0
    .quad   6 - 2 & 3, 0 & 1 ! 1
    .quad   ~1 & 3, !1 + 1, 3 && 0 + 1, 2 || 3 == 3
    .quad   10 / 3 * 3, 1 - 2 - 3, 2 > 1 + 1, 1 + (2 < 3)
    .quad   0b101 + 0x10 + 010, 'a' + 1
