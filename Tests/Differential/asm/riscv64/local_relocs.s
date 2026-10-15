# RISC-V relocations keep their symbols, local and `.L` ones included (LLVM MC's RISC-V `needsRelocateWithSymbol`),
# unlike x86-64 and AArch64. A branch to a global symbol, to another section or to an undefined symbol is relaxed
# to its longest form, an inverted branch (`c.bnez`/`c.beqz` when compressible) over `jal`. `.attribute`,
# `.dword` and `.half` are RISC-V data directives of clang's output. `.rept` takes a label difference.
	.attribute	4, 16
	.attribute	stack_align, 16
	.text
	.globl	g
f:
	call	loc
	lla	a0, .Ldat
	lla	a0, dat
	beqz	a0, ext
	bnez	s0, ext
	beq	a1, a2, ext
	beqz	a0, g
	j	ext
	jal	ext
	beqz	a0, .Lfar
g:	nop
start:	.word 1, 2, 3
end:
	.rept	(end - start) / 4
	nop
	.endr

	.section	.text.loc,"ax",@progbits
loc:	nop
.Lfar:	nop

	.data
dat:	.dword	1
.Ldat:	.dword	2
	.dword	.Ldat
	.dword	dat+4
	.half	7
