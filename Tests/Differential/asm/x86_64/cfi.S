// Regression corpus: `.cfi_*` -> `.eh_frame`. DW_CFA_advance_loc / advance_loc1 / advance_loc2 / advance_loc4
// for growing gaps, multiple FDEs, a second CIE (`.cfi_signal_frame` + `.cfi_return_column`), remember/restore
// state, signed (`_sf`) offsets, `.cfi_escape`, CFI across a relaxed branch, and a function in another section.
// The signal frame comes last, so the FDE order is also GNU `as`'s source order and this file stays in the GNU
// comparison; `cfi_cie_order.s` covers LLVM MC's grouping of FDEs by CIE (05 §4.11).

#define FRAME 24

    .text
    .globl  f
    .type   f, @function
f:
    .cfi_startproc
    pushq   %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq    %rsp, %rbp
    .cfi_def_cfa_register %rbp
    .space  100, 0x90
    pushq   %rbx
    .cfi_offset %rbx, -24
    .space  300, 0x90
    .cfi_remember_state
    popq    %rbx
    .cfi_restore %rbx
    .space  70000, 0x90
    leave
    .cfi_def_cfa %rsp, 8
    .cfi_restore_state
    ret
    .cfi_endproc
    .size   f, . - f

g:
    .cfi_startproc
    subq    $FRAME, %rsp
    .cfi_adjust_cfa_offset FRAME
    .cfi_rel_offset %r12, 8
    .cfi_undefined %rip
    .cfi_same_value %r13
    .cfi_register %r14, %r15
    .cfi_escape 0x2e, 0x10
    testq   %rdi, %rdi
    jz      1f
    .cfi_offset %xmm1, 16
    .space  130, 0x90
1:  addq    $FRAME, %rsp
    .cfi_adjust_cfa_offset -FRAME
    ret
    .cfi_endproc

    .section .text.unlikely, "ax", @progbits
cold:
    .cfi_startproc
    pushq   %r15
    .cfi_def_cfa_offset 16
    popq    %r15
    .cfi_def_cfa_offset 8
    ret
    .cfi_endproc

    .text
h:
    .cfi_startproc
    .cfi_signal_frame
    nop
    .cfi_offset %r12, 16
    nop
    .cfi_return_column %rax
    .cfi_val_offset %rbx, -8
    ret
    .cfi_endproc
