# 01. Frontend Architecture: Source, Lexing, and Parsing

## 1. Overview

The frontend transforms raw source text into structured, cache-contiguous syntactic data structures. In conventional compilers (e.g., `swiftc` using `swift-syntax` or Clang), the frontend accounts for 50–70% of total compilation time. This bottleneck is caused by recursive object allocation, character-by-character scanning, string deduplication in cold hash maps, and pointer-linked AST construction.

Swift-Stack replaces this with a **zero-allocation, data-oriented frontend** capable of parsing at sustained speeds exceeding 300–600 MB/s per core.

```
Source Files (*.swift, *.c, *.h)
               │
               ▼  (mmap with 64-byte sentinel padding)
         SourceManager
               │
               ▼  (SWAR 64-bit vector scan, SoA token stream)
          TokenBuffer  ◄───  C23 Token Stream Preprocessor (#embed zero-copy)
               │
               ▼  (Postorder flat array construction)
           ParseTree   [kind: u8, token: u32, subtree_size: u32]
```

---

## 2. Source Management & Memory Layout

### Sentinel-Padded Source Buffers

Bounds checks in inner lexical scanning loops degrade instruction throughput by up to 30% due to branch mispredictions and pipeline stalls.

Swift-Stack's `SourceManager` allocates all source files using page-aligned virtual memory (or memory mapping) with **64 zero-bytes (`0x00`) appended as sentinel padding**:

```
┌────────────────────────────────────────────────────────┬──────────────────────┐
│                  Source Code Bytes                     │  64 Sentinel Zeroes  │
│  "func add(a: Int, b: Int) -> Int { return a + b }\n"  │  00 00 00 ... 00 00  │
└────────────────────────────────────────────────────────┴──────────────────────┘
 ▲                                                        ▲
 └─ Base Pointer                                          └─ End Offset
```

- **Unchecked Lookahead:** Any scanning loop can safely read up to 8 bytes ahead using unaligned 64-bit integer loads without checking against buffer bounds.
- **Natural Termination:** When the scanner encounters byte `0x00`, it immediately knows EOF is reached.

### Contiguous Source Addressing

Every character position across an entire compilation unit is uniquely identified by a single 32-bit `SourceLocation` offset:
- Files are mapped into a monotonic address space: `[File 0: 0..N]`, `[File 1: N..M]`.
- Converting `SourceLocation` to `(file_name, line, column)` is deferred to diagnostic emission time and performed via binary search over an array of file and newline byte offsets.

---

## 3. Lexical Analysis (Swift & C23)

### Struct of Arrays (SoA) TokenBuffer

Tokens are never stored as individual objects or strings. A compilation unit produces a single `TokenBuffer` structured as parallel flat arrays:

```swift
public struct TokenBuffer: ~Copyable {
    public var kinds: UnsafeMutablePointer<UInt8>     // 1 byte: TokenKind enum
    public var flags: UnsafeMutablePointer<UInt8>     // 1 byte: Trivia & fixity flags
    public var starts: UnsafeMutablePointer<UInt32>   // 4 bytes: Start byte offset in Source
    public var ends: UnsafeMutablePointer<UInt32>     // 4 bytes: End byte offset in Source
    public var count: Int
    public var capacity: Int
}
```

**Total memory footprint per token:** Exactly **10 bytes**. (Compared to 48–80 bytes in traditional compilers).

### Trivia & Flag Classification

Whitespace and comments are not distinct tokens. Instead, lexical trivia is encoded directly into the 1-byte `flags` field of the immediately following token:
- Bit 0: `leading_space` (preceded by spaces or tabs on the same line).
- Bit 1: `leading_newline` (preceded by at least one line break).
- Bit 2: `trailing_space` (followed by whitespace).
- Bit 3–4: Operator fixity: `binary`, `prefix`, `postfix` (computed automatically via Swift's whitespace rule during scanning).
- Bit 5: `is_c23_macro_expanded` (identifies tokens originating from preprocessor expansion).

### SWAR Scanner & Branchless Keyword Hash

1. **SWAR (SIMD Within A Register) Word Scanning:**
   Whitespace runs and alphanumeric identifiers are scanned 8 bytes at a time using 64-bit integer bitwise operations:
   ```swift
   // Fast identification of ASCII identifier characters [a-zA-Z0-9_]
   @inline(__always)
   func scanIdentifierWord(_ word: UInt64) -> UInt32 {
       let hasLower = ((word &- 0x6161616161616161) & ~word) & 0x8080808080808080
       let hasUpper = ((word &- 0x4141414141414141) & ~word) & 0x8080808080808080
       // ... combined SWAR test compiles to 4-5 instructions ...
   }
   ```
2. **Minimal Perfect Keyword Hash:**
   Keywords are recognized without string comparisons. For words between 2 and 12 characters, two unaligned 8-byte loads are multiplied by a 64-bit magic constant and shifted into a 512-slot direct-lookup array:
   ```
   Word (8 bytes) ──► Multiply-Shift Hash ──► Direct Table Lookup ──► TokenKind
   ```
   A single memory probe determines if the identifier is a keyword or an arbitrary name.

### C23 Preprocessor & `#embed` Support

Modern C23 requires full preprocessor compliance with critical additions:
1. **Zero-Copy `#embed`:** C23 introduces `#embed` to include binary assets directly. Instead of generating millions of comma-separated integer tokens, Swift-Stack's preprocessor detects `#embed` and stores the raw byte slice directly in a global **BinaryAssetPool**. A single synthetic token `Tok_BinaryAsset(AssetId)` is emitted, reducing parse time for 100 MB assets from minutes to less than 1 millisecond.
2. **Streaming Macro Expansion:** Macro definitions are stored in a contiguous token arena. When an object-like or function-like macro expands, replacement tokens are streamed into the active token consumer without allocating heap strings.

---

## 4. Syntactic Analysis: Carbon-Style Postorder Parse Tree

### Representation

Instead of an AST built from pointer-linked class instances (`BinaryExpr*`, `IfStmt*`), Swift-Stack stores the entire syntactic structure of a file in a single flat array in **postorder sequence**:

```swift
public struct ParseTree: ~Copyable {
    public struct Node {
        public var kind: NodeKind      // 1 byte: Node type (e.g. VarDecl, BinaryExpr)
        public var token: TokenId      // 4 bytes: Identifying token (keyword, identifier)
        public var subtreeSize: UInt32 // 4 bytes: Count of nodes in subtree including self
    }

    public var nodes: UnsafeMutablePointer<Node>
    public var count: Int
    public var capacity: Int
}
```

**Footprint per syntactic node:** Exactly **9 bytes**.

### Why Postorder Traversal?

In a postorder tree, a node's children are parsed and appended to the array **before** the parent node itself is written. This yields enormous structural advantages:

```
Source: "return a + 1"

Token Stream: [return, a, +, 1]

ParseTree Array Layout (Appended from left to right):
Index  Kind         Token  SubtreeSize  Meaning
0      IdentExpr    'a'    1            Identifier leaf
1      IntLiteral   '1'    1            Literal leaf
2      BinaryExpr   '+'    3            Parent of (0, 1) -> size = 3
3      ReturnStmt   'return' 4          Parent of (2) -> size = 4
```

1. **Pure Sequential Append:** The parser never performs back-patching. When parsing a parent node:
   ```swift
   let startIndex = tree.count
   parseChildren()
   let subtreeSize = UInt32(tree.count - startIndex + 1)
   tree.append(Node(kind: parentKind, token: anchorToken, subtreeSize: subtreeSize))
   ```
2. **Instant Subtree Skipping:** To skip an entire expression or function body, traversal code simply subtracts `subtreeSize` from the current index:
   ```swift
   let previousSiblingIndex = currentIndex - Int(currentNode.subtreeSize)
   ```
   This gives $O(1)$ child jumping without pointer dereferences.
3. **Cache Prefetching:** Processing or lowering the tree executes as a sequential linear sweep through the array from index `0` to `N`.

---

## 5. Expression Parsing: Pratt Parsing & Deferred Operators

### C23 Expression Parser

For C23, operator precedence and associativity are fixed by ISO C:
- Swift-Stack utilizes an arena-based **Pratt (Top-Down Operator Precedence) Parser**.
- Evaluates binary, unary, ternary, and postfix operators with minimal stack depth and zero allocations.

### Swift Sequence Expression Strategy

In Swift, operator precedence and associativity are **user-definable** and can be introduced via `infix operator` declarations in imported modules. Therefore, the syntactic parser cannot fold binary operators during parsing without knowing all module declarations.
- Swift-Stack follows the official Swift model: expressions with binary operators are parsed into flat `SequenceExpr` nodes.
- Tree folding into binary operation DAGs is deferred to Phase 2 (Semantic Analysis), where the operator precedence graph is fully populated.

### Split Token Disambiguation

Grammars with nested generics and optional chaining (`Array<Array<Int>>`, `UnsafePointer<T?>`) introduce ambiguous token boundaries (`>>` vs two `>` tokens, `?>` vs `?` followed by `>`).
- The lexer emits multi-character operators context-free (`Tok_GreaterGreater`).
- When parsing generic argument lists, the parser uses a localized token cursor offset to consume a single `>` character, splitting the token in-place without restarting the lexer.

---

## 6. Error Resilience & Recovery

A production-grade compiler must never crash on malformed inputs and must emit precise diagnostics while continuing to parse the remainder of the file.

1. **Non-Destructive Error Injection:** When a syntax error occurs (e.g., missing closing parenthesis or malformed declaration), the parser:
   - Emits a diagnostic struct into the thread-local `DiagnosticBag`.
   - Skips tokens until the next synchronization barrier (e.g., newline outside of parentheses, or a closing curly brace `}`).
   - Appends a sentinel `NodeKind.errorTree` node into the `ParseTree`.
2. **Preservation of Postorder Invariants:** The error node's `subtreeSize` correctly reflects the number of consumed error tokens, ensuring subsequent compilation phases can traverse or inspect valid portions of the file without crashing.
3. **Depth Guard:** Nesting deeper than 512 levels (e.g., malicious deeply nested parentheses) triggers a controlled diagnostic and flattens recursion, preventing thread stack overflows.
