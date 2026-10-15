// BTI landing pads and the GNU property note a BTI-enabled .S file emits itself (the
// GNU_PROPERTY_AARCH64_FEATURE_1_AND sequence of glibc's and Linux's assembler headers): Swift-Stack must
// produce the same pads and the same `.note.gnu.property` (SHT_NOTE, 8-byte aligned) as clang -c, so the
// linker can mark the program for guarded pages (VectraOS `ElfImage.branchTargets`).

#define NT_GNU_PROPERTY_TYPE_0              5
#define GNU_PROPERTY_AARCH64_FEATURE_1_AND  0xc0000000
#define GNU_PROPERTY_AARCH64_FEATURE_1_BTI  (1 << 0)
#define GNU_PROPERTY_AARCH64_FEATURE_1_PAC  (1 << 1)

    .text
    .globl  bti_entry
    .type   bti_entry, %function
    .p2align 2
bti_entry:                          // reached by `blr`
    bti     c
    paciasp
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adr     x1, bti_table
    add     x1, x1, x0, lsl #3      // 8-byte entries: bti j first
    blr     x1
    ldp     x29, x30, [sp], #16
    autiasp
    ret
    .size   bti_entry, . - bti_entry

    .p2align 3
bti_table:                          // reached by `br`
    bti     j
    ret
    bti     jc
    ret
    hint    #34                     // bti c
    ret
    hint    #36                     // bti j
    ret
    hint    #38                     // bti jc
    ret
    bti
    ret

    .pushsection .note.gnu.property, "a"
    .balign 8
    .long   4                       // n_namesz
    .long   16                      // n_descsz
    .long   NT_GNU_PROPERTY_TYPE_0
    .asciz  "GNU"
    .long   GNU_PROPERTY_AARCH64_FEATURE_1_AND
    .long   4                       // pr_datasz
    .long   GNU_PROPERTY_AARCH64_FEATURE_1_BTI | GNU_PROPERTY_AARCH64_FEATURE_1_PAC
    .long   0                       // pad to 8 bytes
    .popsection
