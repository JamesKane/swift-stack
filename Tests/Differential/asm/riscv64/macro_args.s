// Regression corpus: macro and `.irp` argument splitting as in LLVM MC's AsmParser (05-assembler.md §4.4).
// A blank ends an argument unless an operator follows it (`addk a0, a1, 4 -1` passes `4-1`), only
// parentheses group, and a `(` after a blank starts a new argument (`ldo a2 8 (sp)` passes three).

    .macro  addk rd, rs, imm
    addi    \rd, \rs, \imm
    .endm

    .macro  ldo rd, off, base
    ld      \rd, \off\base
    .endm

    .text
    addk    a0, a1, 4 -1
    addk    a2 a3 8
    addk    a4, a5, (2 << 3) + 1
    addk    t0, t1, 0 -16
    addk    t2 t3 (0 - 16)
    addk    imm=12, rs=s1, rd=s0
    ldo     a2 8 (sp)
    ldo     a3, 4 *4, (a0)
    .irp    r, a0 a1, a2
    mv      \r, zero
    .endr

    .data
    .irp    v, 1 2, 4 -1, (5 + 6)
    .byte   \v
    .endr
