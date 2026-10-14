# 01. Frontend: Source Management, Lexing, Preprocessing, and Parsing

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [14](14-measurement-methodology.md) |
| **Consumed by** | [02](02-semantic-analysis.md), [05](05-assembler.md), [10](10-semantic-ir-and-name-resolution.md) |

## 1. Summary

The frontend turns raw source bytes into two flat, index-addressed structures per compilation unit:

- a **`TokenBuffer`**: struct-of-arrays (SoA) columns, 10 bytes per token;
- a **`ParseTree`**: postorder SoA columns, 9 bytes per node, in the style of the Carbon toolchain.

A *compilation unit* here is one Swift source file, or one C translation unit (a `.c` file plus everything it `#include`s). Units are lexed and parsed independently and in parallel. No per-token or per-node heap allocation happens. Persistent columns use the arena-backed `Column<T>` type (decision D8, [00 §Memory](00-overview-and-principles.md)).

```
Source file bytes
       │  read into page-aligned buffer + 64 zero bytes of padding
       ▼
 SourceManager ──────────────► location space (per unit; §2.3)
       │
       ▼  SWAR / table-driven scanning
 TokenBuffer (SoA) ◄── C23 preprocessor (C units only; §4)
       │
       ▼  explicit-stack recursive descent + Pratt (C), sequence parsing (Swift)
 ParseTree (SoA, postorder)   [kind: u8 | token: u32 | subtreeSize: u32]
```

## 2. Goals

- G1. Lexing and parsing MUST NOT allocate per token or per node; all growth is amortized column growth inside an arena.
- G2. Every token and node MUST map back to a precise source location, including through C macro expansion.
- G3. The parser MUST NOT crash or overflow the native stack on any input, including adversarial input.
- G4. Output MUST be deterministic (D6): the same bytes and flags give the same columns.
- G5. Throughput targets (hypotheses, to be validated per [14](14-measurement-methodology.md)): lexing ≥ 600 MB/s per core and parsing ≥ 300 MB/s per core on the reference corpus.

## 3. Non-goals

- Incremental re-lexing or re-parsing inside a file (editor integration). Units are re-processed whole; see [13](13-modules-and-incremental-builds.md) for incrementality at unit granularity.
- C++ and Objective-C syntax.
- Blocks (`^`) and the full GNU C dialect (D7). §4.5 defines the supported host-header profile.

## 4. Design

### 4.1 Source buffers and the sentinel

Every file is loaded into a buffer followed by **64 zero bytes**:

```
┌────────────────────────────────────────────────────────┬──────────────────────┐
│                  Source bytes [0, length)              │  64 × 0x00 sentinel  │
└────────────────────────────────────────────────────────┴──────────────────────┘
 ▲ base                                                   ▲ end = base + length
```

- **Unchecked lookahead.** Scanners MAY read up to 64 bytes past any in-bounds position with unaligned loads and no bounds check. In practice the widest load is 8 bytes (SWAR); the slack is for SIMD paths added later.
- **NUL is not EOF by itself.** Hitting `0x00` sends the scanner to a cold path that checks `ptr == end`. If true, this is EOF. If false, the file contains an embedded NUL byte: a diagnostic is emitted (an error in Swift; a warning in C, where it is treated as whitespace) and scanning continues. Each NUL costs one compare on the cold path, and the hot loop keeps its single test.
- **Loading strategy.** The default is `read(2)` into an arena allocation of `length + 64` bytes. Copying protects against the file changing underneath the compiler and makes the padding trivial to provide.
  - `mmap` is an optional optimization, adopted only if [14](14-measurement-methodology.md) shows a measurable win. With `mmap`, the bytes past EOF in the last file page read as zero. If `length` is a multiple of the page size, though, there is no tail, and reading past `end` faults (`SIGBUS`).
  - The `mmap` path MUST therefore reserve `length + pageSize` bytes of address space anonymously, then map the file over the start with `MAP_FIXED`, so at least one zero-filled anonymous page always follows.
- **Encoding.** Swift sources MUST be valid UTF-8; invalid sequences are diagnosed. A UTF-8 BOM is skipped. CRLF and lone CR count as line terminators.

### 4.2 Line tables

A file's line-start offsets are computed lazily, the first time a diagnostic or debug-info consumer asks for a line or column in that file. Building the table is a SWAR scan for `\n`. Converting a location to (line, column) is then a binary search. Columns are counted in UTF-8 bytes internally and converted to display columns by the diagnostic renderer ([15](15-driver-and-diagnostics.md)).

### 4.3 Source locations

A `SourceLocation` is a 32-bit offset into the **location space of its unit**. Location spaces are per unit, not global, for three reasons:

1. Units are processed in parallel. A single global monotonic counter would give locations that depend on thread scheduling, which violates D6.
2. A C unit re-includes headers. Clang's model, where every inclusion and every macro expansion gets fresh location ranges, needs those ranges to be unit-local.
3. 32 bits per unit is ample in practice, whereas 32 bits for a whole module is not.

Each location space is a sorted table of **location entries**. This follows Clang's `SLocEntry` design:

| Entry kind | Covers | Records |
|---|---|---|
| `file` | the bytes of one inclusion of a file | `FileId`, include location |
| `expansion` | the tokens produced by one macro expansion (or one argument pre-expansion) | spelling location, expansion range start and end |
| `scratch` | bytes synthesized by `#` stringizing and `##` token pasting | offset into the unit's scratch buffer |
| `macroExpansion` (Swift) | the source text returned by one Swift macro expansion ([16](16-macros.md)) | expansion-site range, macro `DeclId`, role, discriminator |

Mapping a location to its entry is a binary search over entry start offsets. Diagnostics show both the expansion location ("in expansion of macro `FOO`") and the spelling location.

- **Budget.** A unit's location space is limited to 2³² − 1 bytes (4 GiB), counting all included file bytes and all expansion ranges. A Swift unit uses only its file size. A C unit that exceeds the budget is rejected with a diagnostic; it is never silently truncated. `#embed` payloads do not consume location space, because only the directive is located.
- **Cross-unit references.** Anything stored beyond its unit (declarations, debug info, diagnostics after merge) uses `GlobalLocation = (UnitId: UInt32, loc: SourceLocation)`. Tokens and parse nodes store only the 32-bit unit-local form.

### 4.4 Lexical analysis

#### TokenBuffer (SoA)

```swift
public struct TokenBuffer: ~Copyable {
    public var kinds:  Column<UInt8>   // 1 byte: TokenKind (per-language enum)
    public var flags:  Column<UInt8>   // 1 byte: trivia and adjacency flags
    public var starts: Column<UInt32>  // 4 bytes: SourceLocation of first byte
    public var ends:   Column<UInt32>  // 4 bytes: SourceLocation one past last byte
}
```

- **Footprint.** 10 bytes per token across four separate columns. No column has padding. (An array-of-structs layout would have a stride of 12.)
- **Token kinds.** Each language has its own `TokenKind` enum, because a unit is only ever Swift, C, or assembly ([05](05-assembler.md)).
  - Swift *contextual* keywords (`get`, `set`, `async`, `some`, …) are lexed as identifiers and recognized by the parser. This keeps each enum comfortably below 256 values.
- **Locations of macro-expanded tokens.** For tokens produced by macro expansion, `starts`/`ends` fall inside an `expansion` entry, and the spelling is recovered through that entry (§4.3).

#### Flags

| Bit | Meaning |
|---|---|
| 0 | `leadingSpace`: horizontal whitespace or a comment precedes the token on the same line |
| 1 | `leadingNewline`: at least one line break precedes the token |
| 2 | `trailingSpace`: whitespace, a comment, or EOF follows the token |
| 3–4 | Swift operator fixity: `binary`, `prefix`, `postfix`, or `none`, from Swift's left-bound/right-bound whitespace rule |
| 5 | `macroExpanded` (C) |
| 6 | `needsCleaning`: the spelling contains C line splices (`\` + newline) or UCNs, so the raw byte range is not the token text |
| 7 | `hasError`: the token is malformed, for example an unterminated literal; a diagnostic has already been emitted |

Whitespace and comments are never tokens. Doc comments are found later from the byte gap between consecutive tokens, if the documentation tooling needs them.

#### Scanning

- **Character classes.** Dispatch on the first byte uses a 256-entry class table.
- **Identifier runs.** Runs of ASCII identifier characters are consumed 8 bytes at a time using SWAR range tests. Unaligned loads are safe because of the sentinel. All host and target architectures are little-endian, so the first non-identifier byte is the lowest set byte of the mask:

  ```swift
  @inline(__always) func bcast(_ b: UInt8) -> UInt64 { 0x0101_0101_0101_0101 &* UInt64(b) }
  let hiBits: UInt64 = 0x8080_8080_8080_8080

  /// High bit of each byte set where lo <= byte <= hi. Precondition: every byte < 0x80.
  @inline(__always) func inRange(_ w: UInt64, _ lo: UInt8, _ hi: UInt8) -> UInt64 {
      let ge = ((w | hiBits) &- bcast(lo)) & hiBits          // byte >= lo (no inter-byte borrow)
      let le = ((bcast(hi) | hiBits) &- w) & hiBits         // byte <= hi
      return ge & le
  }

  /// Number of leading identifier-continuation bytes in w (0...8), or nil for non-ASCII.
  @inline(__always) func identifierRun(_ w: UInt64) -> Int? {
      guard w & hiBits == 0 else { return nil }             // UTF-8 lead byte → Unicode slow path
      let ident = inRange(w, 0x61, 0x7A) | inRange(w, 0x41, 0x5A)
                | inRange(w, 0x30, 0x39) | inRange(w, 0x5F, 0x5F)
      let stop = ~ident & hiBits
      return stop == 0 ? 8 : stop.trailingZeroBitCount / 8
  }
  ```

  Non-ASCII identifier characters go to a slow path that applies the Unicode identifier rules: Swift's identifier grammar, and C23's UAX #31 XID_Start/XID_Continue rules.
- **Keyword recognition.** Identifiers of 2–16 bytes are hashed with a multiply-shift over one or two masked 8-byte loads into a 512-slot table. A hit is confirmed by comparing those same one or two words against the stored keyword, so recognition costs one probe plus one or two 64-bit compares, with no byte-by-byte `memcmp`. The table is generated at build time, and the hash constant is searched for until the keyword set has no collisions.
- **Numeric literals.** The lexer validates syntax only: Swift `_` separators; C23 `'` digit separators, `0b` binary literals, and `wb`/`uwb` `_BitInt` suffixes. Values are converted in Sem ([02](02-semantic-analysis.md)), where the type is known.

### 4.5 C23 preprocessor

The preprocessor runs per C unit and produces that unit's final, post-expansion `TokenBuffer`. The parser never sees directives.

- **Macro table.** Macro definitions live in a unit-local macro arena: name `AtomId` → (parameter count, variadic flag, replacement token range in the macro-token arena, definition location). `#undef` and redefinition follow C23 §6.10.4, including the rule that a redefinition is valid only if it is identical.
- **Expansion.** Expansion uses a disabled-macro context stack, the standard algorithm that gives the "painted blue" behavior.
  - Arguments are pre-expanded lazily, only when they are used without `#`/`##`.
  - `__VA_OPT__` and `__VA_ARGS__` are supported.
  - Stringizing and pasting write their spellings into the unit's scratch buffer (§4.3).
  - Expansion streams tokens into the output columns without heap strings.
- **Conditionals and queries.** `#if`/`#elif` expressions are evaluated in `intmax_t`/`uintmax_t`, following C23 rules. The following are supported: `#ifdef`, `#ifndef`, the C23 additions `#elifdef` and `#elifndef`, `defined`, `__has_include`, `__has_embed`, `__has_c_attribute`, and `#warning`.
- **Include guards.** The preprocessor detects the include-guard pattern and `#pragma once`, and skips re-entering such files.
- **`#embed`** (C23 §6.10.4). Full semantics MUST be preserved:
  - The parameters `limit(N)`, `prefix(...)`, `suffix(...)`, and `if_empty(...)` are supported, as are vendor parameters that `__has_embed` reports as unsupported.
  - The resource's bytes go into the module's **BinaryAssetPool**, keyed by file and byte range so that identical resources are stored once. The preprocessor emits `prefix` tokens, then one `EmbedAsset(assetId, offset, count)` token, then `suffix` tokens. If the resource is empty, it emits the `if_empty` tokens instead.
  - **Fast path.** When `EmbedAsset` appears as a run of elements in a brace initializer of an array of character type (or of any integer type whose element conversion is value-preserving), Sem records a reference to the asset slice. No per-byte tokens, nodes, or constants are created.
  - **General path.** In any other position (function arguments, a parenthesized comma expression, an enumerator list, and so on), the parser produces an `EmbedSequence` node. Sem treats it as exactly the comma-separated list of integer constants that C23 specifies, materializing elements only where they are actually needed.
  - A directive inside macro arguments is undefined behavior in C. It is diagnosed as an error rather than given a semantics.

#### Host-header profile (D7)

To parse glibc, FreeBSD libc, and macOS SDK headers, the preprocessor and parser accept a documented set of extensions:

- **Recognized syntax:**
  - `__attribute__((...))`
  - `__asm__("label")`
  - `__extension__`, `__inline`, `__restrict`, `__typeof__`
  - `_Nullable`, `_Nonnull`, `_Null_unspecified`
  - `__builtin_va_list` and other `__builtin_*` names, plus basic and extended `asm` statements
- **Feature queries:** `__has_feature`, `__has_extension`, `__has_attribute`, and `__has_builtin` answer from one table, which is the single source of truth for the profile.
- **Predefined macros** are generated per target triple: architecture, OS, sizes, `__STDC_VERSION__ == 202311L`, and the `__STDC_NO_*__` macros for the deferred features listed in [02](02-semantic-analysis.md). Which compiler-identity macros to define (`__GNUC__`, `__clang__`) is an open question (§7).
- **Blocks.** `__BLOCKS__` is never defined. macOS headers guard their block-based APIs behind it, so those declarations are simply not seen.

### 4.6 Parse tree

```swift
public struct ParseTree: ~Copyable {
    public var kinds:        Column<UInt8>   // 1 byte: NodeKind (per-language enum)
    public var tokens:       Column<UInt32>  // 4 bytes: TokenId of the node's anchor token
    public var subtreeSizes: Column<UInt32>  // 4 bytes: bit 31 = hasError; bits 0–30 = nodes in subtree incl. self
}
```

- **Footprint.** 9 bytes per node as three columns.
- **Kind width.** If either grammar needs more than 256 `NodeKind` values, `kinds` widens to `UInt16`, giving 10 bytes per node (open question, §7).
- **Error bit.** Setting aside bit 31 limits a subtree to 2³¹ nodes, which is far beyond the 4 GiB location budget.

#### Postorder layout

A node's children are appended before the node itself. Here is a C example, where binary expressions are folded during parsing:

```
C source: return a + 1;          Tokens: [return, a, +, 1, ;]

Index  Kind          Token     SubtreeSize
0      IdentExpr     'a'       1
1      IntLiteral    '1'       1
2      BinaryExpr    '+'       3     (children 0, 1)
3      ReturnStmt    'return'  4     (child 2)
```

The same statement in Swift. Folding is deferred to Sem, so the parser produces a flat `SequenceExpr` (§4.7):

```
Index  Kind              Token     SubtreeSize
0      IdentExpr         'a'       1
1      BinaryOperator    '+'       1
2      IntLiteral        '1'       1
3      SequenceExpr      'a'       4     (operand, operator, operand)
4      ReturnStmt        'return'  5
```

Properties:

1. **Append-only construction.** The parser records `start = count`, parses the children, and then appends the parent with `subtreeSize = count - start + 1`. No back-patching is needed.
2. **Sibling stepping.** For a node at index `i`, its last child is at `i - 1`, and the sibling before any child `c` is at `c - subtreeSize(c)`. Enumerating `k` children costs O(k), visiting them right to left. Skipping a whole subtree (for example an unneeded function body) is a single subtraction.
3. **Linear consumers.** Building SemIR walks indices `0..<count` in order ([10](10-semantic-ir-and-name-resolution.md) §4.2). To give that walk top-down information, the parser also emits *start marker* nodes before certain children, such as `VarDeclStart`, `CallArgsStart`, and `FunctionBodyStart`. These are ordinary leaf nodes that tell the checker "an initializer for the declared pattern begins here", so it can push an expected type before the initializer's children arrive.

#### Parsing strategy

- **No native recursion.** The parser is a recursive-descent grammar implemented with an explicit state stack, as in Carbon. It never recurses on the native stack, so input depth cannot overflow a thread stack (G3).
- **Nesting limit.** A configurable limit (default 1024 levels, well above C23's minimum translation limit of 63 nested parenthesized expressions) produces a diagnostic and an `errorTree` node. This limit is policy, not stack protection.
- **Swift macro syntax.** `#name(...)` freestanding uses, macro declarations (`macro M(...) = #externalMacro(...)`), and custom attributes are parsed into ordinary nodes. Whether an attribute names a macro is decided later, by name lookup ([10](10-semantic-ir-and-name-resolution.md) §4.10). Expansion text is parsed through **role-specific entry points**: expression, declaration list, member list, attribute list, accessor block, extension declarations, and function body. Each expansion gets its own `ParseTree` ([16](16-macros.md) §5.3).
- **C typedef names.** C parsing needs to know which identifiers name typedefs (in `T * x;`, a declaration versus a multiplication). The C parser keeps a scoped set of typedef names as it parses. This is the only feedback from semantics into parsing, and it covers identifiers only.

### 4.7 Expressions

- **C23.** C precedence is fixed, so the parser uses a Pratt (precedence-climbing) parser driven by a static precedence table. It folds binary, unary, conditional, cast, and postfix expressions directly into the tree.
- **Swift.** Swift precedence is user-definable through `infix operator` and `precedencegroup` declarations, which may live in other files or modules. The parser therefore emits a flat `SequenceExpr` containing operands and operators in alternation, plus special elements for `as`/`is`/`?:`/`=`/`try`. Folding happens in Sem once the operator tables are complete ([10](10-semantic-ir-and-name-resolution.md) §4.5).

#### Splitting `>>` and other angle-bracket tokens

The Swift lexer produces maximal-munch operator tokens, so `Array<Array<Int>>` lexes its closing brackets as a single `>>`, and `T?>` lexes as an operator starting with `?`. The parser **splits tokens virtually and never modifies the `TokenBuffer`**:

- **The cursor.** The parser's token cursor is a pair: `(TokenId, byteOffset)`, where `byteOffset` defaults to 0. When the parser needs a single `>` (or a postfix `?`/`!`) and the current token is an operator that *starts* with that character, it consumes one byte by advancing `byteOffset`. The remainder (`>` from `>>`, `>=` from `>>=`) is classified on the fly, from its bytes, as a virtual token. The next physical token is not touched until the remainder has been consumed.
- **Locating split tokens.** A parse node anchored on a virtual token records the physical `TokenId`. The few node kinds that can anchor on a split token (`GenericArgsEnd`, `OptionalTypeSuffix`) hold the byte offset in their payload. Diagnostics compute the location as `starts[tok] + byteOffset`.

Alternative rejected: having the lexer emit only single-character `>` tokens and letting the parser recombine them into `>>`, `>>=`, and similar for shift operators. Swift operators are arbitrary character sequences (`>>>`, `>~`, …), so recombination would have to re-implement operator lexing in the parser and would put adjacency rules in two places. The virtual split confines the special case to the few contexts that can close an angle bracket.

C23 has no angle-bracket generics and needs no splitting.

### 4.8 Error recovery

1. **Error nodes.** On a syntax error, the parser:
   - emits a diagnostic into its unit's `DiagnosticBag` ([10](10-semantic-ir-and-name-resolution.md) §4.7);
   - skips tokens to a synchronization point (a statement terminator, a newline at bracket depth 0 for Swift, or the matching `}`/`)`/`]`);
   - appends an `errorTree` node with `hasError` set.
2. **Invariants still hold.** The `errorTree`'s `subtreeSize` counts the *nodes* of any partially parsed children it absorbed. Skipped tokens are not nodes. The node anchors the first skipped token, and the skipped range ends just before the next node's first token. Downstream passes can therefore always traverse the tree.
3. **Error propagation.** `hasError` propagates to ancestors, so Sem can suppress follow-on diagnostics inside broken subtrees.

## 5. Alternatives considered

- **Pointer-linked AST with per-node allocation.** Rejected; see [00](00-overview-and-principles.md).
- **One global location space** with a monotonic counter. Rejected: it makes locations depend on thread scheduling (violating D6), and macro expansion would exhaust 32 bits across a large module.
- **64-bit `SourceLocation`.** Avoids the per-unit budget, but costs 4 extra bytes on every token. Revisit if real C units approach the 4 GiB budget.
- **Treating NUL as unconditional EOF.** Rejected: it silently truncates files containing NUL bytes.
- **Materializing `#embed` as integer tokens everywhere.** Rejected for initializers because of its O(N) cost on large assets, but kept, lazily, as the general fallback.

## 6. Interfaces

- `TokenBuffer`, `ParseTree`, and the location table are `~Copyable` values owned by the unit's arena. Sem borrows them.
- The assembler ([05](05-assembler.md)) reuses `SourceManager`, location spaces, and the scanning primitives, with its own `TokenKind` enum.

## 7. Open questions

1. Whether the Swift or C `NodeKind` set exceeds 256 values. Decide when the grammar coverage is complete.
2. Which compiler-identity macros to predefine for the host-header profile. Defining `__GNUC__` enables code paths in glibc headers that use extensions outside the profile. Not defining it may disable required declarations.
3. Whether to cache header token streams across C units. This is only sound when macro state is identical at inclusion; [13](13-modules-and-incremental-builds.md) may cover it with a precompiled-header-like mechanism.
4. Whether `mmap` loading beats `read` on the target corpora ([14](14-measurement-methodology.md)).
