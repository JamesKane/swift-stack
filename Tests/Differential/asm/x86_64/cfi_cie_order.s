// Regression corpus: `.eh_frame` with FDEs that need different CIEs, interleaved in source order. LLVM MC
// stable-sorts FDEs by CIE key (signal frame, `simple`, then return column, an explicit one before the
// default) and emits each CIE once before its group; an explicit `.cfi_return_column` equal to the default
// still gets its own CIE (05-assembler.md §4.9, §4.11). GNU `as` keeps source order and shares CIEs by
// content, so the GNU comparison skips `.eh_frame` for this file only.

    .text
    .globl  plain1
plain1:
    .cfi_startproc
    pushq   %rbp
    .cfi_def_cfa_offset 16
    popq    %rbp
    .cfi_def_cfa_offset 8
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
    subq    $24, %rsp
    .cfi_adjust_cfa_offset 24
    addq    $24, %rsp
    .cfi_adjust_cfa_offset -24
    ret
    .cfi_endproc

simple1:
    .cfi_startproc simple
    .cfi_def_cfa %rsp, 8
    .cfi_offset %rip, -8
    ret
    .cfi_endproc

    .section .text.other, "ax", @progbits
ra_default:
    .cfi_startproc
    .cfi_return_column %rip
    ret
    .cfi_endproc

ra_sig:
    .cfi_startproc
    .cfi_return_column %rax
    .cfi_signal_frame
    nop
    .cfi_undefined %rax
    ret
    .cfi_endproc

    .text
plain3:
    .cfi_startproc
    pushq   %rbx
    .cfi_def_cfa_offset 16
    .cfi_offset %rbx, -16
    popq    %rbx
    .cfi_def_cfa_offset 8
    ret
    .cfi_endproc

sig_simple:
    .cfi_startproc simple
    .cfi_signal_frame
    .cfi_def_cfa %rsp, 8
    ret
    .cfi_endproc
