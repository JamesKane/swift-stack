// AArch64 build attributes as clang 22 emits them with -mbranch-protection=bti (`.aeabi_subsection`,
// `.aeabi_attribute`), plus the other directives of clang's -S output: `.xword`, `.file`, `.ident`, `.addrsig`.
// `.ARM.attributes` (SHT_AARCH64_ATTRIBUTES), `.comment` and `.llvm_addrsig` are compared exactly by
// M2ClangRoundTripTests; here the allocatable sections, relocations and symbols are checked against clang.
	.aeabi_subsection	aeabi_feature_and_bits, optional, uleb128
	.aeabi_attribute	0, 1	// Tag_Feature_BTI
	.aeabi_attribute	Tag_Feature_PAC, 0
	.aeabi_attribute	2, 0	// Tag_Feature_GCS
	.aeabi_subsection	aeabi_pauthabi, required, uleb128
	.aeabi_attribute	Tag_PAuth_Platform, 0
	.aeabi_subsection	private_vendor, optional, ntbs
	.aeabi_attribute	3, "text"
	.aeabi_subsection	aeabi_feature_and_bits
	.aeabi_attribute	Tag_Feature_GCS, 1
	.text
	.file	"build_attributes.c"
	.globl	f
	.p2align	2
	.type	f,@function
f:
	hint	#34
	adrp	x8, table
	add	x8, x8, :lo12:table
	ldr	x0, [x8, #8]
	ret
.Lfunc_end0:
	.size	f, .Lfunc_end0-f

	.section	.data.table,"aw",@progbits
	.p2align	3
table:
	.xword	f
	.xword	0x123456789abcdef0
	.dword	f+4
	.size	table, 24

	.ident	"clang version 22"
	.section	".note.GNU-stack","",@progbits
	.addrsig
	.addrsig_sym f
	.addrsig_sym table
