# LLVM MC 22 under linker relaxation: a forward branch to a local label keeps a relocation (its own fragment's size
# is not final), a backward one is folded unless a branch, a relaxable instruction or a relaxed alignment lies
# between; `jal` relocations get `R_RISCV_RELAX`; code alignment is relaxed (worst-case NOPs + `R_RISCV_ALIGN`) only
# after a branch or relaxable instruction in its section; a label difference across a branch stays an ADD/SUB pair.
.section .text.a, "ax"
    .p2align 2
la0: nop
    .p2align 3
    beqz a0, la1
    nop
la1: nop
    addi a0, a0, 1
    beqz a0, la1
    j la0
la2: beqz a0, la2
    .p2align 3
    beqz a0, la1
    .word la2 - la1
    .word la1 - la0

.section .text.b, "ax"
    nop
    j ext
    bnez a0, ext
    call ext
lb0: nop
    .p2align 2
    bltu a0, a1, lb0
.option push
.option norelax
    beqz a0, lb1
    nop
lb1: nop
.option pop
