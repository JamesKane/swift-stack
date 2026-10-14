# 18. Data Catalog: Tables, Transforms, and Layouts

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [02](02-semantic-analysis.md), [03](03-intermediate-representation.md), [04](04-backend.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [10](10-semantic-ir-and-name-resolution.md), [14](14-measurement-methodology.md) |

## 1. Summary

The purpose of every pass is to transform data. This chapter lists each major persistent table, the passes that produce and consume it, the fields each consumer touches, and the resulting layout choice. It follows Mike Acton's rules: know your data, lay it out for its transforms, and solve for the common case.

The chapters that own each table (01–07, 10) describe its *meaning*. This chapter owns its *layout*. Every layout here is a **hypothesis**. It is revised from the M0.5 vertical slice ([09](09-roadmap.md)) using the built-in profiler ([14](14-measurement-methodology.md)), and from then on is changed only with a measurement attached.

Struct-of-arrays (SoA) is not the default answer. A table that a pass consumes whole-row is usually better as an array of structs (AoS), or as a hybrid (AoSoA: small fixed-size blocks of SoA).

## 2. Goals

- Every persistent table has a stated producer, consumers, access pattern, expected size and layout rationale.
- Layout disagreements between chapters are resolved here, in one place.
- Row counts and byte sizes are observable for every table (`--stats`, [15](15-driver-and-diagnostics.md) §4.7).

## 3. Non-goals

- Fixing final layouts before any code exists.
- Transient scratch data inside a single pass. That is the pass's own business, provided it lives in a scratch arena ([00](00-overview-and-principles.md) Principle 2).

## 4. Rules

1. **Layout follows transforms** ([00](00-overview-and-principles.md) Principle 6). For each table, list the hot consumers and the fields they touch:
   - If the hot consumers touch *disjoint subsets* of fields, or one consumer filters on a narrow field (kind, flags) over many rows, use SoA.
   - If the hot consumers read *the whole row*, use AoS with fields ordered for alignment.
   - If both happen, use a hybrid: split hot and cold fields into separate tables, or use AoSoA.
2. **Row 0 is the nil row.** Every table reserves row 0 as a valid "nil" entry with defined default fields, and parents or links pointing to itself ([00](00-overview-and-principles.md) Principle 7). Reading handle 0 never traps and yields harmless defaults. `Optional<Id>` is not used in tables; "absent" is handle 0.
3. **Where there's one, there's many.** Table APIs are batch-first: `appendRange`, lookup of a sorted batch of keys, and bulk rewrite through a remap table ([10](10-semantic-ir-and-name-resolution.md) §4.6). Single-row helpers are thin wrappers over the batch forms.
4. **Observable.** Every table reports row count, bytes reserved and bytes committed under `--stats`, and is visible to the built-in profiler's memory counters ([14](14-measurement-methodology.md)).
5. **Measured changes only.** Changing a layout requires a before/after measurement from the built-in profiler on the [14](14-measurement-methodology.md) corpora, recorded in the change description.

## 5. Catalog

Expected sizes are **order-of-magnitude estimates** for 100K lines of source (about 3–4 MB). They come from typical token and node densities, not from measurement, and are listed so that layout decisions have a scale to reason about.

### 5.1 Frontend

| Table | Owner | Producer → consumers | Fields touched | Access | Rows / 100K lines (est.) | Layout | Rationale |
|---|---|---|---|---|---|---|---|
| Source buffers | [01](01-frontend.md) §4.1 | loader → lexer, line-table builder, diagnostics | bytes | sequential | ~3–4 MB | flat bytes + 64-byte sentinel | Scanned once, linearly. |
| Line tables | [01](01-frontend.md) §4.2 | lazy builder → diagnostics, SDI line emission | line-start offsets | binary search | ~10⁵ | single `UInt32` column per file | One field, so there is nothing to split. |
| Location entries | [01](01-frontend.md) §4.3 | preprocessor, macro expander → diagnostics, SDI | start offset (search); kind and payload (on hit) | binary search over `start`, then one row | Swift: 10²–10⁴; C: up to 10⁵–10⁶ per macro-heavy unit | **SoA**: `starts` column separate from the payload rows | The search touches only `starts`, and the payload is read once per hit. |
| `TokenBuffer` | [01](01-frontend.md) §4.4 | lexer → parser, preprocessor, assembler | parser: `kinds` and `flags` heavily, `starts` for anchors; `ends` rarely | sequential | ~10⁶ | **SoA** (10 B/token) | The parser's lookahead is a kind/flags sweep. Keeping `starts`/`ends` out of the hot stream is the clearest SoA win in the design. |
| `ParseTree` | [01](01-frontend.md) §4.6 | parser → Sem node-stack walk, error recovery | `kinds` and `subtreeSizes` for traversal and skipping; `tokens` per node visited | sequential (postorder), backward skips | ~10⁶ | **SoA** (9 B/node) | Subtree skipping and kind dispatch read only `kinds` and `subtreeSizes`. |

### 5.2 Semantic analysis

| Table | Owner | Producer → consumers | Fields touched | Access | Rows / 100K lines (est.) | Layout | Rationale |
|---|---|---|---|---|---|---|---|
| `DeclTable` | [10](10-semantic-ir-and-name-resolution.md) §4.1 | phase-1 collection → lookup, signature resolution, lowering, module writer | lookup: `names`, `parents`, `kinds`; checking: `types`, `genericSig`; lowering: most fields | random by handle; filtered scans by kind | ~10⁴–10⁵ | **SoA** | Lookup filters on `names`/`kinds` across many rows. Small enough that the choice matters little. |
| SemIR instructions | [10](10-semantic-ir-and-name-resolution.md) §4.1 | body checker → AIR lowering, constant evaluator | lowering reads **every field** of each instruction in order | sequential, whole-row | ~10⁵–10⁶ | currently SoA (18 B/inst); **AoS candidate** | Lowering is the only bulk consumer, and it reads whole rows. A packed 20-byte AoS row (`kind` widened in the padding) may beat five streams. Measure. |
| `TypePool` | [02](02-semantic-analysis.md) §4.1 | interner → every phase | filters: `kinds`, `flags` (trivial, copyable, Sendable); layout: `sizes` and `alignments`; structure: `payload` | random by handle; filter scans over kinds and flags | ~10⁴–10⁵ | **SoA** for `kinds`/`flags`/`canonical`; layout fields as a pair | The hot questions ("is T trivial?", "is T a struct?") read one narrow column. |
| Member tables | [10](10-semantic-ir-and-name-resolution.md) §4.4 | phase 2 → member lookup | `(AtomId, DeclId)` pairs | binary search by `AtomId` | ~10⁵ entries | **AoS** pairs, sorted | The search key and the result are read together. |
| `DiagnosticBag` | [15](15-driver-and-diagnostics.md) §4.5 | every stage → renderer | all fields | append, then one sort | 0–10³ | **simplest correct layout** | Rare. Layout is irrelevant to performance, so optimize for clarity. |

### 5.3 Middle end and backend

| Table | Owner | Producer → consumers | Fields touched | Access | Rows / 100K lines (est.) | Layout | Rationale |
|---|---|---|---|---|---|---|---|
| AIR instructions | [03](03-intermediate-representation.md) §4.1 | lowering, passes → passes, isel | SCCP and GVN: `opcode` and operands; ADCE: `opcode` and operands; type queries: `type`; isel: everything | sequential through `blockOrder`, plus random def lookups | ~10⁶ (more after specialization and inlining) | **SoA** (17 B/inst) | Many passes read `opcode` and operands without `type` or `aux`. Defensible, but random def lookups pay one cache line per column. Measure the AoS alternative on the slice. |
| AIR blocks and edges | [03](03-intermediate-representation.md) §4.1 | lowering, CFG edits → dominators, liveness, all passes | CSR offsets and edges | sequential | ~10⁵ blocks | **CSR** | Edge lists are variable-length, so CSR avoids per-block allocation. |
| LIR instructions | [04](04-backend.md) §4.3 | isel → liveness, regalloc, encoder | liveness and regalloc: `opcodes` + all operands; encoder: **whole row** | sequential, whole-row for the encoder | ~10⁶ | currently SoA (28 B/inst); **AoS candidate** | The two heaviest consumers read nearly every field per instruction. A 32-byte AoS row (with `imm` 8-aligned) is one cache-line half per instruction instead of seven streams. See [04](04-backend.md) §4.3. |
| Live intervals | [04](04-backend.md) §4.5 | liveness → linear scan, resolution | start, end, register hint, assigned register, spill slot: **whole row** | sorted sweep, whole-row | ~10⁴ per large function | **AoS** | The scan reads every field of each interval it touches. Range lists stay in a CSR side table. |

### 5.4 Objects, linking, and debug info

| Table | Owner | Producer → consumers | Fields touched | Access | Rows / 100K lines (est.) | Layout | Rationale |
|---|---|---|---|---|---|---|---|
| `RelocatableObject` sections | [06](06-linker.md) §5.1 | Codegen, Asm, object readers → layout | all fields | small sequential | ~10²–10⁴ | **AoS** | Few rows, read whole. |
| Symbols | [06](06-linker.md) §5.1 | Codegen, Asm, readers → resolution, symtab writer | resolution: name hash and binding; writer: whole row | hash probe, then whole-row | ~10⁴–10⁵ | **hybrid**: name-hash column for probing, AoS payload | Probing reads only the hash. Everything after reads whole rows. |
| Relocations | [06](06-linker.md) §5.5 | Codegen, Asm, readers → relocation workers | offset, type, symbol, addend: **whole row** | sequential per input section | ~10⁵–10⁶ | **AoS** (CSR per section) | Each relocation is applied by reading all four fields together. If 06 §5.1 stores relocations as SoA, this table overrides it. |
| `.ss_symtypes` | [06](06-linker.md) §5.3 | Codegen → linker type checks | whole 24-byte record | sorted merge | ~10⁴ | **AoS** (on-disk format) | It is a file format, and it is read whole. |
| SDI tables | [07](07-debugging-and-sdi.md) §5 | linker merge → debugger, symbolizer | debugger: the address map (search key only), then the procedure/line row on a hit | binary search, then whole-row | line rows ~10⁵–10⁶; procedures ~10⁴ | **search keys as separate columns; records AoS** | The same split as location entries: search touches keys, and a hit reads the whole record. This matches RDI practice. |

## 6. Known disagreements with owning chapters

Each of these is resolved by measurement on the vertical slice. Until then, the owning chapter's layout stands, marked as a hypothesis.

1. **LIR instructions** ([04](04-backend.md) §4.3): documented as SoA. The encoder and register allocator consume whole rows, so AoS is the leading candidate.
2. **SemIR instructions** ([10](10-semantic-ir-and-name-resolution.md) §4.1): documented as SoA. AIR lowering reads whole rows.
3. **Live intervals** and **relocations**: AoS is expected. Their owning chapters should not specify SoA.
4. **AIR instructions** ([03](03-intermediate-representation.md) §4.1): SoA is defensible, but it is the most-measured decision in the catalog, because the middle end is where compile time goes.

## 7. Alternatives considered

| Alternative | Why not |
|---|---|
| SoA everywhere, as an architectural rule | Pessimizes whole-row consumers (encoder, relocation, register allocator), and costs extra address computations per field. |
| AoS everywhere (the "natural" Swift struct array) | Loses the clear wins: token kinds, parse-node kinds, and type flags are scanned alone over 10⁵–10⁶ rows. |
| Decide every layout up front in the owning chapters | That is how the current SoA-by-default choices arose without access-pattern data. Layouts belong to measurement, not to prose. |

## 8. Open questions

1. Does AoSoA (for example, 8-row blocks) beat both pure forms for AIR, where some passes sweep narrow fields and others read whole rows?
2. Should `Column` expose a typed "row view" so that a table can switch between SoA and AoS without changing call sites, or is it simpler to rewrite the few consumers when a layout changes?
3. Are the row estimates in §5 close? The M0.5 slice should replace them with measured densities per 100K lines for C and Swift.
