// Regression corpus: `.macro` parameters with `:req`, `:vararg` and defaults, keyword arguments, quoted
// arguments, `\()` concatenation, longest-name parameter matching, `\@`, nested macros with `.exitm`,
// `.irp`/`.irpc`, and character constants containing `;` and `#`.

    .macro  bytes first:req, rest:vararg
    .byte   \first
    .ifnb   \rest
    .byte   \rest
    .endif
    .endm

    .macro  pair a:req, b=7
    .byte   \a, \b
    .endm

    .macro  label name, n
\name\()_\n:
    .byte   \n
    .endm

    .macro  widths ab, a
    .byte   \ab, \a
    .endm

    .macro  str s
    .ascii  "\s"
    .endm

    .macro  limited n
    .if     \n > 2
    .byte   0xEE
    .exitm
    .endif
    .byte   \n
    .endm

    .macro  outer x
    limited \x
    .byte   0x55
    .endm

    .macro  uniq
.Luniq\@:
    .byte   \@ & 0
    .endm

    .data
    bytes   1, 2, 3, 4
    bytes   5
    bytes   6 7, 8
    bytes   9 + 1 10
    pair    3
    pair    1 + 2, 4
    pair    b=9, a=4
    label   lbl, 2
    widths  10, 20
    str     "hi there"
    str     hello
    outer   1
    outer   5
    uniq
    uniq
    .irp    r, 1, 2, 3
    .byte   \r * 2
    .endr
    .irpc   c, 579
    .byte   \c
    .endr
    .byte   ';', '#', 'x'
