# rel8-only branches (`loop`, `jrcxz`, `jecxz`) to local labels and to an external symbol (R_X86_64_PC8),
# prefixes on a line of their own, string instructions with explicit operands, `movabs` with a 64-bit address,
# and the double-shift, exchange-and-add and 8-byte compare-exchange instructions.
	.text
	.globl	strings
	.type	strings, @function
strings:
1:	loop	1b
	loope	2f
	loopnz	1b
	jrcxz	2f
	jecxz	1b
	nop
2:	loopne	1b
	jrcxz	far_away
	loop	far_away+4

	rep
	movsb
	rep; stosq
	lock
	xaddl	%eax, (%rdi)
	rep movsq (%rsi), %es:(%rdi)
	movsl	%fs:(%rsi), %es:(%rdi)
	lodsw	(%rsi), %ax
	repne scasb %es:(%rdi), %al
	repe cmpsq %es:(%rdi), (%rsi)
	insb	%dx, %es:(%rdi)
	outsl	(%rsi), %dx
	xlatb

	movabsq	0x1122334455667788, %rax
	movabsb	%al, 0x10
	movabs	ext_sym, %eax
	movabs	%ax, ext_sym+8

	shldq	$3, %rax, %rbx
	shrdl	%cl, %ecx, (%rdx)
	shld	%r8w, %r9w
	xaddq	%rax, 8(%rsp)
	lock xaddb %cl, (%rbx)
	lock cmpxchg8b (%rdi)
	cmpxchg16b (%rsi)
	pushq	%fs
	popw	%gs
	enter	$32, $0
	leave
	clc
	cmc
	stc
	nopw	(%rax)
	ret
	.size	strings, .-strings
