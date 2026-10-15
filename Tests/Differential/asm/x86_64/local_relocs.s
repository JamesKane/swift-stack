# Relocations against local symbols (LLVM MC `ELFObjectWriter::useSectionSymbol`): a local label or `.L` symbol
# becomes its section symbol plus the label's offset, and a `.L` symbol so replaced is not in `.symtab`. The symbol
# is kept for GOT relocations, an explicit `@PLT`, TLS sections, and a nonzero addend into a mergeable section.
# Branches to a global symbol in the same section are relocated (it may be preempted). `.rept` takes a label
# difference already laid out. M2ClangRoundTripTests compares the symbol each relocation names exactly.
	.text
	.globl	g
f:
	call	loc
	call	loc@PLT
	leaq	.Lstr(%rip), %rax
	movl	$.Lstr, %eax
	movl	$.Lstr+1, %eax
	movq	loc@GOTPCREL(%rip), %rax
	movl	loc@GOTPCREL(%rip), %ecx
	movq	tv@GOTTPOFF(%rip), %rax
	jmp	.Lother
	jmp	g
	jne	g
g:	nop
start:	.long 1, 2, 3
end:
	.rept	(end - start) / 4
	.byte	0xaa
	.endr
	.p2align	4

	.section	.text.o,"ax",@progbits
.Lother:
	nop
loc:	nop

	.section	.rodata.str1.1,"aMS",@progbits,1
.Lstr:	.asciz	"hi"

	.section	.tbss,"awT",@nobits
tv:	.zero	8

	.data
	.quad	loc+3
	.quad	.Lstr
	.quad	.Lstr+2
	.quad	.Ld
.Ld:	.quad	0
