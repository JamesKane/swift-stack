// Regression corpus: macro and `.irp` argument splitting as in LLVM MC's AsmParser (05-assembler.md §4.4).
// A blank ends an argument unless an operator follows it (`addk x0, x1, 4 -1` passes `4-1`), only
// parentheses group (`[x1, #8]` is two arguments, so it goes last or through `:vararg`), and keyword
// arguments may come in any order.

    .macro  addk rd, rn, imm
    add     \rd, \rn, #\imm
    .endm

    .macro  ldr2 rt, mem:vararg
    ldr     \rt, \mem
    .endm

    .macro  ldo rt, base, off=0
    ldr     \rt, [\base, #\off]
    .endm

    .text
    addk    x0, x1, 4 -1
    addk    x2 x3 8
    addk    x4, x5, (2 << 3) + 1
    addk    x6 x7 1 << 4
    addk    imm=12, rn=x9, rd=x8
    ldr2    x10, [x11, #16]
    ldr2    x12 [x13]
    ldo     x14 x15
    ldo     x16, x17, 2 *8
    .irp    r, x0 x1, x2
    mov     \r, xzr
    .endr

    .data
    .irp    v, 1 2, 4 -1, (5 + 6)
    .byte   \v
    .endr
