// Relocations against local symbols (LLVM MC `ELFObjectWriter::useSectionSymbol`): a local label or `.L` symbol
// becomes its section symbol plus the label's offset, except for GOT relocations, TLS sections and a nonzero
// addend into a mergeable section. Branches to a global symbol in the same section are relocated. `.rept` takes a
// label difference already laid out.
	.text
	.globl	g
f:
	adrp	x0, :got:loc
	ldr	x0, [x0, :got_lo12:loc]
	adrp	x0, .Lstr
	add	x0, x0, :lo12:.Lstr
	add	x0, x0, :lo12:.Lstr+1
	bl	loc
	b	.Lother
	b	g
	cbz	x0, g
	b.ne	g
	add	x0, x0, :tprel_hi12:tv
g:	nop
start:	.word 1, 2, 3
end:
	.rept	(end - start) / 4
	nop
	.endr

	.section	.text.o,"ax",@progbits
.Lother:
	nop
loc:	nop

	.section	.rodata.str1.1,"aMS",@progbits,1
.Lstr:	.asciz	"hi"

	.section	.tbss,"awT",@nobits
tv:	.zero	8

	.data
	.xword	loc+3
	.xword	.Lstr
	.xword	.Lstr+2
	.xword	.Ld
.Ld:	.xword	0
