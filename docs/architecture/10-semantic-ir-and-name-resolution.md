# 10. SemIR, Name Resolution, and the Semantic Pipeline

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [02](02-semantic-analysis.md), [16](16-macros.md) |
| **Consumed by** | [03](03-intermediate-representation.md), [11](11-generics-and-runtime-metadata.md), [13](13-modules-and-incremental-builds.md), [15](15-driver-and-diagnostics.md) |

## 1. Summary

**SemIR** is the typed, name-resolved representation that sits between the postorder `ParseTree` ([01](01-frontend.md)) and AIR ([03](03-intermediate-representation.md)). Its design is modeled on Carbon's SemIR. It is made of:

- a module-wide **declaration table**;
- per-body **instruction blocks**, flat columns of typed instructions in evaluation order.

This chapter specifies:

- the SemIR representation;
- how a linear, bottom-up postorder walk supports top-down (bidirectional) type checking;
- name lookup and scopes, including `SequenceExpr` folding;
- the parallel phase structure of Sem;
- concurrent interning with **deterministic ID assignment** (D6);
- diagnostics collection and error recovery;
- the hand-off to AIR lowering.

The language rules that SemIR encodes are in [02](02-semantic-analysis.md).

## 2. Goals

- G1. **One representation, two consumers.** One typed representation serves C and Swift. It is the input to AIR lowering, constant evaluation, debug-info type emission ([07](07-debugging-and-sdi.md)), and module-interface emission ([13](13-modules-and-incremental-builds.md)).
- G2. **Flat storage.** No per-node heap allocation. SemIR lives in `Column`-backed arenas (D8).
- G3. **Linear builder.** Building SemIR is a linear walk over parse-tree indices, plus targeted re-walks of contiguous subranges when an expression needs the constraint solver.
- G4. **Deterministic IDs.** Every ID whose numeric value can reach an output (`DeclId`, `TypeId`, `AtomId`, `FunctionId`) MUST be assigned deterministically, independent of thread count and scheduling (D6).
- G5. **Recovery.** Errors MUST NOT cascade. One root cause yields one diagnostic.

## 3. Non-goals

- A long-lived, editable AST for IDE tooling.
- SemIR is not a stable on-disk format. The module interface format is defined separately in [13](13-modules-and-incremental-builds.md).
- Flow-sensitive analyses (ownership, definite initialization, region isolation) happen in AIR.

## 4. Design

### 4.1 Representation

#### Declarations

The module declaration table is SoA, indexed by `DeclId`:

```swift
public struct DeclTable: ~Copyable {
    public var kinds:      Column<DeclKind>  // 1 byte: func, var, struct, class, enum, protocol, extension,
                                             //         typealias, operator, precedencegroup, C typedef/tag, …
    public var names:      Column<AtomId>    // 4 bytes: interned identifier (or operator spelling)
    public var parents:    Column<DeclId>    // 4 bytes: enclosing declaration context
    public var types:      Column<QualType>  // 4 bytes: interface type ([02] §4.1); unresolved until phase 3
    public var genericSig: Column<UInt32>    // 4 bytes: generic signature id, or none
    public var bodies:     Column<UInt32>    // 4 bytes: InstBlockId of the body, or none
    public var origin:     Column<GlobalLocation> // 8 bytes: (UnitId, SourceLocation) + parse NodeId via side table
    public var attrs:      Column<UInt32>    // 4 bytes: offset into attribute/modifier arena (access, isolation, …)
}
```

#### Instructions

Within a body, expressions and statements become **instructions** in a flat block:

```swift
public struct SemInstBlock: ~Copyable {
    public var kinds:  Column<UInt16>    // 2 bytes: SemInstKind (shared C + Swift set)
    public var types:  Column<QualType>  // 4 bytes: result type (or `error`)
    public var arg0:   Column<UInt32>    // 4 bytes: InstId, DeclId, constant id, nested InstBlockId, …
    public var arg1:   Column<UInt32>    // 4 bytes
    public var nodes:  Column<UInt32>    // 4 bytes: originating parse NodeId (source location, diagnostics)
}
```

- **Footprint.** 18 bytes per instruction across five columns.
- **Extra operands.** Calls, tuples, argument lists, and switch cases store their operands in a CSR side array: `arg1 = offset`, and `arg0` or the kind gives the count. Nested regions such as closure bodies, `if` branches, and loop bodies are separate `InstBlockId`s that their parent instruction references, so blocks stay contiguous.
- **Decoupled from parsing.** A SemIR instruction refers to its parse node only for location. The *structure* comes from SemIR alone, so lowering never re-reads the parse tree.
- **Literals** go into a module constant pool:
  - integers are arbitrary precision, needed for `_BitInt` and `Builtin.IntLiteral`;
  - floats keep their decimal spelling plus parsed bits;
  - strings are deduplicated UTF-8.

### 4.2 From postorder to SemIR: the node stack

SemIR for a body is built by walking parse-node indices from left to right. The walk keeps two stacks.

- **Node stack** (as in Carbon). Each processed node pushes `(NodeId, result)`, where the result is an `InstId`, a `DeclId`, a type, or a name.
  - A parent node pops its children's entries. The children are exactly the stack entries whose `NodeId ≥ parentIndex − subtreeSize + 1`, so no child count needs to be stored.
- **Context stack.** Pushed by the *start marker* nodes the parser emits before certain subtrees ([01](01-frontend.md) §4.6): `VarDeclStart`, `CallArgsStart`, `FunctionBodyStart`, `ReturnStart`, `IfConditionStart`, and so on. Its entries carry **top-down information**: the expected type of the upcoming initializer or argument, the current declaration context, the current isolation, and the enclosing function's result and throw types.

The context stack is how bidirectional checking works over a bottom-up input:

1. **Declared types arrive first.** In `let x: Int = expr` the parser emits the pattern and its type annotation, then `VarDeclStart`, then the initializer. By the time the initializer's leaves are visited, the expected type `Int` is on the context stack.
2. **Stage 1 runs inline.** As expression nodes arrive, Stage 1 ([02](02-semantic-analysis.md) §4.3.2) types each node immediately where admissible: a unique declaration reference, a literal against a known expected type, a single viable overload. It emits instructions directly.
3. **Deferral at the expression root.** If Stage 1 cannot finish some node, the walk marks the enclosing *expression root* as deferred. Instructions emitted speculatively for that root are discarded by truncating the block back to its start mark. The root's parse range `[rootStart, rootEnd]` is contiguous in postorder, so the walk records `(rootStart, rootEnd, expectedType)` and continues.
4. **Re-walking deferred expressions.** At the end of the enclosing statement, each deferred range is re-walked to generate constraints, solved by Stage 2, and then walked a third time to emit instructions using the solution. All three walks are over contiguous memory.
5. **Closures.** Single-expression closures take part in the enclosing solve. Multi-statement closure bodies are checked after the enclosing expression's solution fixes the closure's type, following SE-0326's conjunction semantics. The body is again a contiguous parse range and is processed by the same walk.

For C, everything resolves in one pass. Declarators precede initializers, and `_Generic` association types precede their expressions. The only top-down C contexts, braced initializers and `_Generic` selection, are driven by the same context stack.

### 4.3 Scopes and lexical lookup

- **Lexical scopes** are parse-node ranges. A scope opens at its start marker (`BlockStart`, `FunctionBodyStart`, `ClosureStart`, …) and closes when the walk reaches the scope's own node.
- **Scope bindings.** A *scope binding stack* holds `(AtomId, DeclId or local InstId)` pairs. Entering a scope records the stack height, and leaving a scope truncates back to it. Local lookup is a backward linear scan, bounded by the number of bindings visible in the function, which is small in practice. A per-function hash index is built only if [14](14-measurement-methodology.md) shows long scans.
- **Visibility rules.** Swift local bindings are visible only after their declaration, and use-before-declaration is diagnosed. Local functions and types follow Swift's forward-reference rules. C bindings follow the C point-of-declaration rules.
- **C name spaces.** C has four namespaces: ordinary identifiers, tags, labels, and members. Each is a separate binding stack (labels are function-scoped).

### 4.4 Member and unqualified lookup (Swift)

- **Unqualified lookup** proceeds in this order, and the first scope that yields results wins, subject to Swift's shadowing rules:
  1. local scopes;
  2. members of the enclosing type contexts (including their extensions, protocol extension members, and superclass members);
  3. file-scope declarations;
  4. module-scope declarations;
  5. declarations from imported modules.
- **Member tables.** Each nominal type has a member table, a sorted `(AtomId, DeclId)` run in a module arena, searched by binary search.
  - **Extensions.** Extensions are *bound* to their extended nominal type during phase 2 (§4.6). Binding resolves the extended type's name, which may itself be nested or an alias, and is iterated to a fixed point. The extension's members are then merged into the nominal's lookup view.
  - **Protocol extensions.** Lookup through a protocol extension filters candidates by the extension's `where` clause against the base type, using the requirement machine ([02](02-semantic-analysis.md) §4.3.3).
- **Module-qualified names** (`Swift.print`, `Glibc.open`) search only the named module's export table ([13](13-modules-and-incremental-builds.md)).
- **Macro-introduced members.** Before a member table answers a lookup for name `n`, any attached macro in that context whose introduced-name patterns could produce `n` is expanded (§4.10). For `names: arbitrary`, that means any lookup.

### 4.5 Operators and `SequenceExpr` folding

- **The operator table.** Operator declarations (`prefix`/`postfix`/`infix operator`) and `precedencegroup` declarations are collected in phase 2 into a module operator table, merged with the tables of imported modules.
- **The precedence graph.** `higherThan`/`lowerThan` relations are closed transitively. Assignment and associativity flags are recorded. Cycles, and relations that cross modules illegally, are diagnosed.
- **Folding.** Folding happens when the walk reaches a `SequenceExpr` node, during body checking:
  - An operator-precedence (shunting-yard) pass over the flat operand/operator list uses the precedence graph to build a folded tree in a scratch buffer.
  - Comparing two operators from *unrelated* precedence groups is an error, as in `swiftc`.
  - `as`/`as?`/`as!`/`is` (CastingPrecedence), the ternary `?:`, `=` (AssignmentPrecedence), and `try`/`await` hoisting follow Swift's grammar rules.
  - The folded tree is then type-checked like any other expression: Stage 1, falling back to a deferred Stage 2 solve.
- **The parse tree stays unfolded.** Diagnostics point at operator tokens through each instruction's `nodes` entry.

### 4.6 Phase structure, interning, and deterministic IDs

```
Phase 1  (parallel per unit)   lex, preprocess (C), parse, collect declaration skeletons
            │                    → unit-local DeclTable, provisional local IDs
            ▼  barrier: merge + canonical renumbering
Phase 2  (sequential v1)       build module DeclTable, bind extensions, build member tables,
            │                    operator/precedence tables, import modules ([13]),
            │                    record attached macros + introduced-name patterns,
            │                    eager macro expansions (§4.10)
            ▼
Phase 3  (sequential v1)       resolve interface types, generic signatures, conformances
            │                    (on-demand "requests" with memoization + cycle detection;
            │                    lazy macro expansion is one such request, §4.10)
            ▼  barrier
Phase 4  (parallel per body)   check function/initializer bodies → SemIR instruction blocks
            │                    (types interned into worker-local overlays)
            ▼  barrier: merge type overlays + canonical renumbering
Phase 5  (queue)               enqueue bodies for AIR lowering ([03]), in FunctionId order
```

Phase numbers here are local to Sem. Sem phases 1, 2–3 and 4–5 correspond to phases 1, 2 and 3 of the whole-compiler model in [00](00-overview-and-principles.md) §8.

- **Phase 1** produces declaration *skeletons*: kind, name, parent, attributes, and the parse range of the signature and body. Nothing is resolved yet.
- **Phase 3 is sequential in v1** and evaluated lazily. A request such as "interface type of D" or "does T conform to P" computes its answer on first use and memoizes it. A request found in progress means a cycle, which is diagnosed. Parallelizing phase 3 would need in-progress states that are safe across threads, plus cross-thread cycle detection. It is deferred until measurement shows phase 3 matters ([14](14-measurement-methodology.md)).
- **Phase 4 is embarrassingly parallel.** Signatures are fixed, and each body only reads the shared tables and writes its own arena.

#### Interning and renumbering

Atoms (identifiers, operator spellings, string literals), types, declarations, and generic signatures are all interned. In a parallel phase, a worker assigns **provisional IDs** in a worker-local table, carrying a worker tag. At the barrier that follows:

1. **Merge.** Union the worker tables. Each entry has a **stable key**:
   - atoms: their UTF-8 bytes;
   - declarations: `(canonical unit order, parse NodeId)`, where unit order comes from the driver's sorted input list ([15](15-driver-and-diagnostics.md));
   - types: the structural encoding over canonical component IDs, assigned bottom-up from leaves to composites.
2. **Sort new entries by stable key,** and assign canonical IDs after the existing ones.
3. **Rewrite.** Rewrite every column that holds provisional IDs, in one linear pass per column through a remap table.

After a barrier, every ID is a function of the inputs alone. A second, independent safeguard backs this up: emitters ([04](04-backend.md), [06](06-linker.md), [07](07-debugging-and-sdi.md)) MUST order their output by stable keys and never by hash-table iteration order. CI compiles each test with 1, 2, and N worker threads and compares outputs byte for byte ([14](14-measurement-methodology.md)).

### 4.7 Diagnostics

- **Collection.** Each worker owns a `DiagnosticBag`, whose column layout is defined in [15](15-driver-and-diagnostics.md) §4.5: `DiagId`, `GlobalLocation`, and slices into argument, note and fix-it arenas. Arguments (types, names, numbers) are stored *as IDs*, and rendered only when the diagnostic is printed.
- **Ordering.** At each barrier, the bags are merged and sorted by the key in [15](15-driver-and-diagnostics.md) §4.5 (unit order, `SourceLocation`, `DiagId`, argument values). This makes diagnostic order deterministic.
- **Notes and fix-its** are slices attached to their parent diagnostic.
- Rendering (source snippets, column computation, colors) and the command-line interface are in [15](15-driver-and-diagnostics.md).

### 4.8 Error recovery

- **Poison values.** `TypeId.error` is a poison type. Any constraint, conversion, or lookup that involves an `error`-typed operand succeeds silently and yields `error`. An expression that depends on an earlier error therefore reports nothing new. Failed lookups produce an `ErrorDecl` reference, which behaves the same way.
- **Parse errors.** `errorTree` parse nodes ([01](01-frontend.md) §4.8) lower to an `ErrorInst` of type `error`.
- **Isolating bad declarations.** A declaration whose signature contains an error gets an `error` interface type. Calls to it are not diagnosed again.
- **Diagnostic caps.** There is a per-unit cap (configurable, default 200) and a per-expression cap (one Stage 2 failure diagnostic per expression root).
- **What reaches AIR.** Bodies with errors are not lowered to AIR. If any error exists, the pipeline stops after phase 4, so all semantic errors are reported, but no code is generated.

### 4.9 Lowering queue

- **Phase 5.** Every successfully checked body (function, initializer, accessor, closure, C function, and the static initializer of a global) is enqueued as `(FunctionId, InstBlockId)`, sorted by `FunctionId`.
- **Lowering workers.** These pull from the queue, lower SemIR to AIR, and run the mandatory passes and the optimizer ([03](03-intermediate-representation.md)).
- **Specialization requests.** In Tier 0, and when specializing in Tier 1 ([11](11-generics-and-runtime-metadata.md)), lowering produces requests of the form *(generic FunctionId, substitution map)*. These are deduplicated by a stable key, assigned canonical `FunctionId`s at the next barrier, and lowered from the same SemIR with the substitutions applied.
- **When SemIR is freed.** `@inlinable`/`@_alwaysEmitIntoClient` bodies and C `static inline` functions go into the module interface as AIR after mandatory lowering, not as SemIR ([13](13-modules-and-incremental-builds.md) §5.1). A body's SemIR is freed after lowering, unless:
  - it is generic and may still receive specialization requests;
  - it is needed for constant evaluation.

### 4.10 Macro expansion

Swift macros ([16](16-macros.md)) are integrated with lookup as **memoized expansion requests**, keyed by (expansion site, role):

- **Recording.** Phase 1 records every custom attribute and `#name` use in declaration skeletons. Phase 2 resolves which attributes name macros and records each attached macro's role and introduced-name patterns (`named`, `overloaded`, `prefixed`, `suffixed`, `arbitrary`) on its scope.
- **Lookup that resolves a macro never expands macros.** Resolving `@IPCLibrary` to its macro declaration uses lookup with expansion disabled. If that resolution would depend on a macro-introduced name, a cycle diagnostic is produced, matching `swiftc`.
- **Eager expansions** happen at the end of phase 2 ([16](16-macros.md) §5.4), ordered by stable key: `extension` macros that add conformances, `memberAttribute`, `peer` on public declarations, and `body` macros. Their results are needed for conformance tables and signatures regardless of lookup.
- **Lazy expansions** run as phase-3 requests when a lookup could see their names, or when a body (phase 4) uses a freestanding macro. Phase-4 expansions inside bodies run on the worker checking that body. Their expansion buffers and declarations get provisional IDs like any other worker-local entity, and are renumbered at the phase-4 barrier.
- **Splicing.** The expansion's `ParseTree` is walked by the same node-stack builder (§4.2), with the expansion's declarations parented to the attached declaration's context. Members introduced by a `member` macro join the nominal's member table. Peers join the enclosing scope.
- **Determinism.** Discriminators come from the enclosing context's mangled name and the ordinal of the expansion within it, and are never from evaluation order. The plugin host's results are attached to their request, so plugin response order cannot leak into IDs (D6).

## 5. Alternatives considered

- **Lowering straight from the ParseTree to AIR.** Rejected: types, overload choices, and generic substitutions must be computed before lowering, and conformance checking needs a declaration table anyway. Without SemIR, this work would have to be redone in every AIR consumer.
- **A pointer-linked typed AST**, like `swiftc`'s AST with `Expr*` nodes annotated with types. Rejected on DOD grounds ([00](00-overview-and-principles.md)). In addition, the solver's need for a contiguous range is served better by parse-tree ranges.
- **A single global concurrent intern table that assigns final IDs on insertion.** Simpler, but the IDs depend on scheduling, which violates D6 unless every emitter re-sorts. Renumbering at barriers costs linear passes, and makes determinism a property of the data rather than of every consumer.
- **A full request-evaluator architecture for all of Sem,** as in `swiftc`. It is adopted only for phase 3, where the dependency order is genuinely unknown. Phases 1, 2, and 4 have a known order and do not need it.

## 6. Open questions

1. Is phase 3 (signature and conformance resolution) a measurable fraction of total time on large modules, which would justify parallel requests? Measure first ([14](14-measurement-methodology.md)).
2. Should `SemInstKind` be split into separate C and Swift enums (keeping 1-byte kinds), or shared (2 bytes)? Shared is assumed above, because interop lowering mixes them.
3. Default diagnostic caps, and whether `-Werror`-style escalation applies to Swift 5-mode concurrency warnings ([02](02-semantic-analysis.md) §6).
4. ~~How long is SemIR kept for `@inlinable` bodies?~~ Resolved: inlinable bodies are serialized as AIR after mandatory lowering ([13](13-modules-and-incremental-builds.md) §5.1), so their SemIR is not retained for the interface.
