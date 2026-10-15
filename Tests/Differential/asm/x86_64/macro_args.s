// Regression corpus: macro and `.irp` argument splitting as in LLVM MC's AsmParser (05-assembler.md §4.4).
// A blank ends an argument unless an operator follows it (`two 3 -4` passes `3-4`), only parentheses group,
// a string argument loses its quotes, and keyword arguments may come in any order. GNU `as` splits
// `two 3 -4` into `3` and `-4` and rejects `two 5 - 6`, `two (11 - 1) 12` and `two 24 *2`, so this file is
// compared with clang only (M2DifferentialTests.swift `gnuIncompatibleFiles`).

    .macro  two a, b=100
    .byte   \a
    .byte   \b
    .endm

    .macro  str s
    .ascii  "<\s>"
    .endm

    .macro  load disp, base
    movl    \disp(\base), %eax
    .endm

    .text
    load    8 %rdi
    load    4 +4, %rsi
    load    (2 * 8), %rdx

    .data
    two     1 2
    two     3 -4
    two     5 - 6
    two     7 +8
    two     -9 10
    two     (11 - 1) 12
    two     22 !23
    two     24 *2
    two     6 <<1
    two     6 >>1
    two     6 ==6
    two     2 <3
    two     6 &3
    two     6 |1
    two     6 ^3
    two     , 17
    two     b=18, a=19
    two     b = 20
    str     "a b"
    str     "c\"d"
    .irp    r, 1 2, 4 -1, (5 + 6)
    .byte   \r
    .endr
    .irp    r, 7, , 9
    .byte   6\r
    .endr
