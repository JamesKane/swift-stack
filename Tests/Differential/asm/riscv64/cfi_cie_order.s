// Regression corpus: `.eh_frame` with FDEs that need different CIEs, interleaved in source order. LLVM MC
// stable-sorts FDEs by CIE key (signal frame, `simple`, then return column, an explicit one before the
// default) and emits each CIE once before its group; an explicit `.cfi_return_column` equal to the default
// still gets its own CIE (05-assembler.md §4.9, §4.11).

    .text
    .globl  plain1
plain1:
    .cfi_startproc
    addi    sp, sp, -16
    .cfi_def_cfa_offset 16
    sd      ra, 8(sp)
    .cfi_offset ra, -8
    ld      ra, 8(sp)
    .cfi_restore ra
    addi    sp, sp, 16
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

sig1:
    .cfi_startproc
    .cfi_signal_frame
    nop
    .cfi_def_cfa_offset 16
    ret
    .cfi_endproc

plain2:
    .cfi_startproc
    addi    sp, sp, -32
    .cfi_adjust_cfa_offset 32
    addi    sp, sp, 32
    .cfi_adjust_cfa_offset -32
    ret
    .cfi_endproc

simple1:
    .cfi_startproc simple
    .cfi_def_cfa sp, 0
    ret
    .cfi_endproc

    .section .text.other, "ax", @progbits
ra_default:
    .cfi_startproc
    .cfi_return_column ra
    ret
    .cfi_endproc

ra_sig:
    .cfi_startproc
    .cfi_return_column t0
    .cfi_signal_frame
    nop
    .cfi_undefined t0
    ret
    .cfi_endproc

    .text
plain3:
    .cfi_startproc
    addi    sp, sp, -16
    .cfi_def_cfa_offset 16
    sd      s0, 0(sp)
    .cfi_offset s0, -16
    ld      s0, 0(sp)
    addi    sp, sp, 16
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

sig_simple:
    .cfi_startproc simple
    .cfi_signal_frame
    .cfi_def_cfa sp, 0
    ret
    .cfi_endproc
