// Regression corpus: `.eh_frame` with FDEs that need different CIEs, interleaved in source order. LLVM MC
// stable-sorts FDEs by CIE key (signal frame, `simple`, then return column, an explicit one before the
// default) and emits each CIE once before its group; an explicit `.cfi_return_column` equal to the default
// still gets its own CIE (05-assembler.md §4.9, §4.11).

    .text
    .globl  plain1
plain1:
    .cfi_startproc
    stp     x29, x30, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x30, -8
    .cfi_offset x29, -16
    ldp     x29, x30, [sp], #16
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
    sub     sp, sp, #32
    .cfi_adjust_cfa_offset 32
    add     sp, sp, #32
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
    .cfi_return_column x30
    ret
    .cfi_endproc

ra_sig:
    .cfi_startproc
    .cfi_return_column x17
    .cfi_signal_frame
    nop
    .cfi_undefined x17
    ret
    .cfi_endproc

    .text
plain3:
    .cfi_startproc
    str     x19, [sp, #-16]!
    .cfi_def_cfa_offset 16
    .cfi_offset x19, -16
    ldr     x19, [sp], #16
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc

sig_simple:
    .cfi_startproc simple
    .cfi_signal_frame
    .cfi_def_cfa sp, 0
    ret
    .cfi_endproc
