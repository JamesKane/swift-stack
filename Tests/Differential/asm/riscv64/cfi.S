// Regression corpus: `.cfi_*` -> `.eh_frame` (data alignment -8, return column ra, R_RISCV_32_PCREL pc_begin).
// Advances over compressed (2-byte) instructions, advance_loc2 / advance_loc4 gaps, multiple FDEs,
// remember/restore state, FP registers (DWARF 32+) and `.cfi_register`.

    .text
    .globl  f
    .type   f, @function
f:
    .cfi_startproc
    addi    sp, sp, -16
    .cfi_def_cfa_offset 16
    sd      ra, 8(sp)
    sd      s0, 0(sp)
    .cfi_offset ra, -8
    .cfi_offset s0, -16
    addi    s0, sp, 16
    .cfi_def_cfa s0, 0
    .space  400
    nop
    .cfi_remember_state
    ld      ra, 8(sp)
    .cfi_restore ra
    .space  70000
    .cfi_restore_state
    ret
    .cfi_endproc
    .size   f, . - f

g:
    .cfi_startproc
    c.nop
    .cfi_adjust_cfa_offset 32
    .cfi_rel_offset s1, 8
    .cfi_undefined ra
    .cfi_offset fs0, -24
    .cfi_register s2, t0
    ret
    .cfi_endproc
