// Regression corpus: RISC-V linker relaxation (clang's default, and how VectraOS builds its rv64 kernel), assembled
// for `-march=rv64imac_zicsr_zifencei -mabi=lp64 -fPIE`. Relaxable relocations (`call`, `%hi`/`%lo`, `lla`'s
// `%pcrel_hi`/`%pcrel_lo`) carry `R_RISCV_RELAX`; GOT `la` does not on its `auipc`. Code alignment emits
// worst-case NOPs plus `R_RISCV_ALIGN`. Branches and label differences that span either a relaxable instruction
// or a relaxed alignment stay relocations (`R_RISCV_RVC_*`, `ADD32`/`SUB32`); those that span neither fold.
// `.option norelax` turns all of it off. `li` of a single high bit is `c.li; c.slli` without Zbs.

.text
.globl f
f:
    beqz a0, 1f                 // folds: nothing relaxable in between
    addi a0, a0, 1
1:  bnez a0, 2f                 // spans `call`: R_RISCV_RVC_BRANCH
    call ext
2:  j 3f                        // spans `lla`: R_RISCV_RVC_JUMP
    lla t0, f
3:  lla t1, 3b                  // %pcrel_hi stays a relocation even for the label just before
    lla t2, 4f
4:  ret
    .long 4b - 3b
    .long 2b - 1b
    .long 1b - f                // folds
    .long 3b - 2b
    li t0, (8 << 60)

.section .text.a, "ax"
.balign 4
L_a0: nop
.balign 8
L_a1: beqz a0, L_a2             // spans an R_RISCV_ALIGN
.p2align 4
L_a2: ret

.section .text.b, "ax"
L_b0: call ext
.balign 8
L_b1: j L_b0
    .long L_b1 - L_b0

.section .rodata.c, "a"
.balign 8                       // not code: zero fill, no R_RISCV_ALIGN
L_c0: call ext
.balign 8
L_c1: nop

.section .text.d, "ax"
.option push
.option norelax
L_d0: call ext
    beqz a0, L_d1
    nop
L_d1: lla t0, L_d0
.balign 16
.option pop
L_d2: nop
    lui a0, %hi(sym)
    addi a0, a0, %lo(sym)
    la a1, sym
    sw a0, %lo(sym)(a1)
