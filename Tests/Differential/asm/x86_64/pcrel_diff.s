// Regression corpus: `A - B` with `B` defined in the current section and `A` undefined or in another section
// is a PC-relative relocation against `A` with `P - B` in the addend (VectraOS user/vdso/header.S).
.section .vdso.header, "a"
.balign 16
hdr:
    .long 0x53445643
    .long ext - hdr
    .quad ext2 - hdr + 4
    .long local - hdr

.text
local:
    nop
