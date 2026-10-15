// Regression corpus: `.cfi_*` -> `.eh_frame` (data alignment -4, return column x30). DW_CFA_advance_loc /
// advance_loc2 / advance_loc4 gaps, multiple FDEs in two sections, remember/restore state, SIMD registers
// (DWARF 64+), `.cfi_negate_ra_state`, and CFI after a conditional branch (kept in range: clang does not
// relax an out-of-range `cbz`).

    .text
    .globl  f
    .type   f, %function
f:
    .cfi_startproc
    stp     x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset w30, -8
    .cfi_offset x29, -16
    mov     x29, sp
    .cfi_def_cfa w29, 16
    .space  400
    nop
    .cfi_remember_state
    ldp     x29, x30, [sp], #16
    .cfi_def_cfa sp, 0
    .cfi_restore x30
    .cfi_restore x29
    .space  70000
    .cfi_restore_state
    ret
    .cfi_endproc
    .size   f, . - f

    .section .text.g, "ax", %progbits
g:
    .cfi_startproc
    sub     sp, sp, #32
    .cfi_adjust_cfa_offset 32
    .cfi_rel_offset x19, 8
    .cfi_undefined x30
    .cfi_negate_ra_state
    .cfi_offset d8, -24
    cbz     x0, 1f
    .space  300
1:  add     sp, sp, #32
    .cfi_adjust_cfa_offset -32
    .cfi_same_value x19
    ret
    .cfi_endproc
