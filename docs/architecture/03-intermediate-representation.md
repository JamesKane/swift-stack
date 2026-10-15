# 03. Arena Intermediate Representation (AIR) & Optimizer

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [10](10-semantic-ir-and-name-resolution.md), [11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md), [04](04-backend.md), [08](08-runtime-and-stdlib.md), [14](14-measurement-methodology.md), [17](17-simd-and-vectorization.md), [18](18-data-catalog.md) |

## 1. Summary

AIR (Arena Intermediate Representation) is the single middle-end IR for both C23 and Swift. It is an SSA form stored as columns of fixed-width integers (`Column<T>`, see [00 §6, Principle 2](00-overview-and-principles.md)), allocated from a per-function arena. AIR keeps Swift-level semantics — ownership, ARC, witness dispatch, async — long enough for the optimizer to reason about them, then lowers them to plain loads, stores, and runtime calls before instruction selection ([04](04-backend.md)).

The optimizer is deliberately small: a fixed pipeline of well-understood passes chosen to capture most of the runtime performance available from a conventional optimizing compiler. The working hypothesis is that this reaches 80–90% of LLVM `-O2` runtime performance on non-vectorizable workloads; that number is a target to be measured ([14](14-measurement-methodology.md)), not a property of the design. AIR also carries the vector types and operations behind portable SIMD; auto-vectorization is an optional pass on top of them (D9, [17](17-simd-and-vectorization.md)).

```
SemIR (doc 10)
       │
       ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                AIR: columnar SSA storage                    │
 │  - Instructions: InstId -> {opcode, type, op0, op1, aux}    │
 │  - Blocks:       BlockId -> {inst range, CSR preds/succs}   │
 └─────────────────────────────────────────────────────────────┘
       │
       ▼  Mandatory lowering (runs at every -O level)
  - Definite initialization
  - Ownership & borrow verification (~Copyable, consume/borrow)
  - Lifetime-dependence checking (~Escapable)
  - Static exclusivity & region-isolation diagnostics
  - Deinit insertion, closure lowering, async coroutine split
  - Ownership lowering (copy/destroy -> retain/release)
  - Performance-annotation checking (@_noAllocation)
  - Mandatory inlining (@_transparent)
       │
       ▼  Optimization (-O only)
  Interprocedural, bottom-up over call-graph SCCs:
    generic specialization, inlining & devirtualization,
    then the per-function simplification pipeline
  Late, function-parallel:
    ARC optimization, stack promotion, check elimination,
    LICM & unrolling, loop idioms, [vectorize], cleanup
       │
       ▼
 LIR / instruction selection (doc 04)
```

## 2. Goals

- One IR for C23 and Swift so that C `static inline` functions can be inlined into Swift callers and vice versa.
- Columnar storage: no per-instruction heap objects, no pointers in persistent data, linear scans for most passes.
- Swift semantics (ownership, ARC, generics, async) represented explicitly until the passes that need them have run.
- Deterministic output (D6): the result of optimization MUST NOT depend on thread count or scheduling.
- An OS-agnostic IR: nothing in AIR names VectraOS ports, kqueue, or epoll. Platform behaviour lives in the runtime ([08](08-runtime-and-stdlib.md)).

## 3. Non-goals

- Auto-vectorization (loop or SLP) as a v1 *requirement*. It is an optional track built on AIR's vector operations (D9, [17](17-simd-and-vectorization.md) §5.6). Portable SIMD lowering and loop idiom recognition *are* required.
- Polyhedral loop optimization, profile-guided optimization, whole-program LTO beyond what the in-process pipeline naturally sees.
- A general peephole-combining library on the scale of LLVM InstCombine. Algebraic simplification is limited to what SCCP and GVN fold, plus a small table of identities.
- Bit-identical output with `swiftc` or `clang`. Only observable program behaviour must match ([09 §Verification](09-roadmap.md)).

## 4. Design

### 4.1 Function storage

An AIR function is a set of columns sharing an index space. All columns are arena-backed `Column<T>` values (D8); `Opcode` is a `UInt8`-backed enum, all handle types are `UInt32`.

```swift
public struct AIRFunction: ~Copyable {
    public var id: FunctionId
    public var signature: TypeId              // canonical function type

    // Instruction columns, indexed by InstId (append-only storage).
    public var opcode: Column<Opcode>         // 1 byte
    public var type:   Column<TypeId>         // 4 bytes: result type (or .void)
    public var op0:    Column<ValueId>        // 4 bytes
    public var op1:    Column<ValueId>        // 4 bytes
    public var aux:    Column<UInt32>         // 4 bytes: 3rd operand, BlockId, immediate,
                                              //          or offset into `extra`
    public var extra:  Column<ValueId>        // overflow operands (calls, phis, switches)

    // Block columns, indexed by BlockId.
    public var blockOrder:   Column<InstId>   // CSR: instructions of block b are
    public var blockStart:   Column<UInt32>   //   blockOrder[blockStart[b] ..< blockStart[b+1]]
    public var succStart:    Column<UInt32>   // CSR successor lists
    public var succEdges:    Column<BlockId>
    public var predStart:    Column<UInt32>   // CSR predecessor lists
    public var predEdges:    Column<BlockId>
}
```

**Size.** Because each column is a separate contiguous array, there is no per-row padding. The fixed cost is 1 + 4 + 4 + 4 + 4 = **17 bytes per instruction**, plus 4 bytes in `blockOrder`, plus 4 bytes per operand beyond the third in `extra`. (An array-of-structs with the same fields would have a 20-byte stride.) LLVM, by contrast, allocates each `llvm::Instruction` individually and links it into intrusive instruction and use lists, costing several machine words of overhead per instruction; we make no stronger quantitative claim than that. The SoA choice is a hypothesis tracked in [18](18-data-catalog.md) §5.3. Many passes read only `opcode` and operands, but random def lookups pay one cache line per column, so an AoS or AoSoA layout is measured against it on the M0.5 slice ([09](09-roadmap.md)).

**Nil row.** `InstId` 0, `BlockId` 0 and `ValueId` 0 are nil rows (a `.nil` opcode with no operands, an empty block) per [18](18-data-catalog.md) §4. A missing operand is `ValueId` 0, not an `Optional`.

**Edges as CSR.** Successor and predecessor lists are stored in compressed-sparse-row form (an offset column plus a flat edge column) rather than as `[[BlockId]]`, which would allocate one heap array per block. CFG edits mark the CSR as stale; it is rebuilt in one linear pass at the next pass boundary that needs it.

**Insertion and deletion.** Instruction storage is append-only. Order within a block is given by `blockOrder`, so inserting an instruction appends it to storage and splices its `InstId` into the order column; deleting it removes it from the order column and sets its opcode to `.dead`. At pass-group boundaries a compaction step renumbers live instructions in block order. Renumbering is deterministic and restores locality for the next linear scan.

**Values.** A `ValueId` is a tagged 32-bit handle. The top 2 bits select instruction result, function parameter, constant-pool entry, or global; the remaining 30 bits are the index. Instructions with multiple results (for example, a call returning a tuple) produce one aggregate value, and `air.extract` projections select from it.

**Use lists** are not maintained incrementally. Passes that need def-use information build a CSR use index (`useStart`, `useInsts`) in one linear pass into the scratch arena, and discard it when they finish.

### 4.2 Swift semantics in AIR

**Ownership.** Before ownership lowering, every SSA value has an ownership kind: `owned`, `guaranteed` (borrowed), `none` (trivial), or `unowned`. Ownership is managed by these instructions:

- `air.copy_value` / `air.destroy_value`
- `air.begin_borrow` / `air.end_borrow`
- `air.move_value`
- `air.mark_unresolved_noncopyable` (an input to the move checker)

This form is what the mandatory ownership checks (§4.3) verify.

**ARC.** After ownership lowering, copies and destroys of reference-counted values become `air.strong_retain` / `air.strong_release`. Escaping mutable captures use `air.alloc_box` and `air.project_box`. ARC stays explicit until the backend lowers it to runtime calls ([08](08-runtime-and-stdlib.md)), so the ARC optimizer (§4.5) can reason about pairs.

**Access markers.** `air.begin_access [read|modify] [static|dynamic]` and `air.end_access` delimit formal accesses for exclusivity enforcement. Dynamic markers lower to runtime calls; the optimizer removes them where it can prove they are unneeded (§4.5).

**Volatile memory.** `air.load` and `air.store` carry a `volatile` flag. It is set by C `volatile` accesses and by the `_Volatile` module's builtins (`VolatileMappedRegister`, used for VectraOS's MMIO drivers). Optimizations MUST NOT delete, duplicate, merge, widen, narrow or split a volatile access, and MUST NOT reorder two volatile accesses relative to each other. ADCE treats them as roots, and the vectorizer and loop-idiom pass skip loops that contain them.

**Vectors.** Builtin vector types (`Vec<N × E>`) and their operations (lane-wise arithmetic, masks and `select`, shuffles, reductions, vector loads and stores) are ordinary AIR types and opcodes. They are produced by `SIMDn<T>` code, C vector extensions, and the optional loop vectorizer, and are legalized per target in the backend ([17](17-simd-and-vectorization.md) §5.1–5.2).

**Generics.** `air.witness_method %wt, #Protocol.requirement` loads a requirement from a witness table. `air.metadata` produces a type-metadata reference. In unspecialized (Tier 1) code, values of unknown size are address-only and are handled through value-witness calls. The representation is defined in [11](11-generics-and-runtime-metadata.md).

**Async.** `air.await` marks a suspension point in an `async` function. The coroutine split (§4.3) turns each async function into a sequence of partial functions whose state lives in a heap-allocated async frame. A suspension becomes a tail call into the executor runtime interface ([08 §5](08-runtime-and-stdlib.md)), for example the `swift_task_switch` or `swift_task_enqueue` families ([12 §6](12-standard-library-strategy.md); emitted symbols use the `_SS` scheme). AIR never refers to a specific OS event mechanism. How the executor sleeps (a VectraOS port, kqueue, or epoll) is purely a runtime concern.

**Semantics attributes.** The upstream stdlib annotates functions with `@_semantics("...")` (for example `array.check_subscript` and `array.get_count`) and `@_effects(...)` (D2, [12](12-standard-library-strategy.md)). Lowering records these annotations in a per-function attribute column. The ARC optimizer and the bounds-check eliminator match on them; they do not pattern-match on function names.

### 4.3 Mandatory lowering

These steps run at every optimization level, including `-Onone`, because they produce diagnostics or establish invariants that later code relies on. Their diagnostics MUST be deterministic and MUST NOT depend on the optimization level.

1. **Definite initialization.** Every variable is initialized before use, `let` constants are initialized exactly once, and `self` is fully initialized before use inside initializers.
2. **Ownership and borrow verification.** This moves here from Sem, because it needs the control-flow graph.
   - Forward dataflow over **variable-length bitsets** (one bit per tracked variable or field path; no fixed 64-variable limit) checks that a consumed value is not used afterwards on any path.
   - It also checks that a borrowed value is not consumed while the borrow is active, and that `inout` access is exclusive.
   - Partial consumption of a `~Copyable` aggregate is tracked per field.
3. **Lifetime-dependence checking** (`~Escapable`, `@_lifetime`). Every non-escapable value (a `Span`, `MutableSpan`, or a user `~Escapable` type) is checked against its source:
   - it MUST NOT be used after its source's lifetime ends;
   - it MUST NOT escape through returns, stores, or captures, except into a result whose `@_lifetime` annotation declares the dependence.

   `copy x` dependencies inherit the source's own dependencies, and `borrow x` dependencies end when the borrow ends. This runs on the same dataflow framework as step 2.
4. **Static exclusivity and isolation diagnostics.** Accesses that conflict when both are visible in one function are compile-time errors. The flow-sensitive part of Swift 6 concurrency checking, region-based isolation (SE-0414), runs here on the same CFG, using the isolation facts from Sem ([02](02-semantic-analysis.md) §4.4).
5. **Deinit insertion.** For each `~Copyable` value whose lifetime ends without being consumed, the step inserts the destroy (which runs `deinit`) at the end of its lexical lifetime.
6. **Closure lowering.**
   - Captures become explicit context arguments.
   - Escaping mutable captures are boxed.
   - Non-escaping closures receive a context that may be stack-allocated.
7. **Async coroutine split** (see §4.2).
8. **Ownership lowering.** Ownership instructions are rewritten to explicit retain/release and plain loads and stores, and ownership kinds are dropped.
9. **Performance-annotation checking.** This applies to `@_noAllocation` and `@_noLocks` functions, and runs after ownership lowering, because it has to see the explicit retains and releases.
   - **What the checker walks.** Starting from each annotated function, it walks the **call tree** under that function. Generic callees are specialized for the concrete types reaching them; this is a dedicated, diagnostic-only specialization, independent of the optimization level, so the result is the same at `-Onone` and `-O`.
   - **What it rejects.** Heap allocation (`alloc_ref`, `alloc_box`, escaping closure contexts, growing collections), retain and release, metadata instantiation, existential boxing, lock and runtime calls not marked safe, and calls to functions whose bodies are unavailable and that carry no matching annotation.
   - `@_noLocks` rejects locks and blocking runtime calls but permits allocation that the runtime documents as lock-free. `@_noAllocation` implies `@_noLocks`.
   - **Diagnostics** name the offending instruction and the call path from the annotated root.
   - The `@AudioRenderer` macro of VectraOS's SDK ([16](16-macros.md); lifted in VectraOS roadmap V6) attaches `@_noAllocation` to real-time `render` methods. The check is the point of that macro, so it is mandatory and never weakened to a warning. Which constructs `swiftc` accepts here must be matched (D5) and is differential-tested.
10. **Mandatory inlining.** `@_transparent` functions are always inlined, at every optimization level, and the inlined generic bodies are specialized for the concrete types at the call site. Swift semantics require this, and so does performance: the stdlib's `SIMDn<T>` operations and integer operators reach `Builtin` operations only through `@_transparent` code. Without it, `-Onone` SIMD code would run through generic witness calls ([17](17-simd-and-vectorization.md) §5.1). This step's position relative to steps 1–5 MUST match `swiftc`, because inlining affects which diagnostics fire (D5); the exact order is to be verified.

### 4.4 Optimization pipeline and scheduling

The optimizer has three groups of passes, plus the optional loop vectorizer. The schedule below fixes their order. Where a pass sits in the schedule matters as much as which passes exist.

**Core passes (C and Swift):**

| Pass | Purpose |
|---|---|
| Mem2Reg | Promote non-escaping `air.alloca` slots to SSA values. Phis are placed by iterated dominance frontiers. |
| SROA | Split aggregates (structs, tuples, enum payloads) into scalar slots so Mem2Reg can promote them. This is essential for Swift, where most values are structs. |
| SCCP | Sparse conditional constant propagation: a combined value and reachability lattice that folds constants and removes unreachable blocks. |
| GVN / CSE + alias analysis | Value numbering over `(opcode, type, operand VNs)`, plus redundant-load elimination using the alias analysis in §4.6. |
| LICM + simple unrolling | Hoist loop-invariant computations and loads. Fully unroll loops with a constant trip count ≤ 8 and a small body. |
| ADCE & CFG simplification | Mark live code from its roots and sweep the rest; merge blocks, thread trivial branches, and remove empty blocks. |
| Switch lowering hints | Classify each `switch` as a jump table, a binary search tree, or a bit test, by density and range. The backend implements the choice. |
| Loop idiom recognition | Rewrite fill, copy and move loops into `memset`/`memcpy`/`memmove` calls ([17](17-simd-and-vectorization.md) §5.5). |
| *Loop vectorization (optional, `-vectorize`)* | *Vectorize countable inner loops using AIR vector operations ([17](17-simd-and-vectorization.md) §5.6). Not part of the default pipeline until it meets its budgets.* |

**Interprocedural passes (scheduled bottom-up):**

| Pass | Purpose |
|---|---|
| Generic specialization | Clone generic functions for concrete type arguments that are known at a call site ([11 §Specialization](11-generics-and-runtime-metadata.md)). In Tier 0 this is total and mandatory; in Tier 1 it is budget-driven. |
| Inlining & devirtualization | Inline small or single-call-site callees. Rewrite `witness_method` and class-method calls to direct calls when the concrete type is known, then inline. |

**Swift-specific passes:**

| Pass | Purpose |
|---|---|
| ARC optimization | Pair and remove retain/release; move retains later and releases earlier across blocks to expose more pairs (§4.5). |
| Stack promotion | Allocate non-escaping class instances and closure contexts on the stack. |
| Bounds-check & exclusivity-check elimination | Remove array bounds checks and dynamic `begin_access` checks that are proven redundant. |

**Schedule at `-O`:**

```
1. Mandatory lowering                                   (function-parallel)
2. Build the call graph; compute SCCs with Tarjan's algorithm;
   order the SCCs bottom-up (callees before callers)
3. For each SCC, once all callee SCCs are finished:     (SCC-parallel)
     specialize → inline/devirtualize → Mem2Reg → SROA → SCCP
     → GVN → ARC opt → ADCE/CFG
     → compute this function's effect summary (§4.6)
4. Late pipeline                                         (function-parallel)
     stack promotion → check elimination → LICM/unroll → loop idioms
     → [vectorize, if enabled] → GVN → ARC opt → ADCE/CFG → switch hints
     → compaction
```

**`-Onone`** runs step 1 only, plus a trivial ADCE that preserves debug values.

**`-Osize`** runs the `-O` schedule with these changes: inlining budgets cut to callees that shrink or keep the caller's size; no unrolling; loop idioms enabled (they shrink code); vectorization off. VectraOS's Embedded build uses `-Osize` for every target.

**Related flags:**
- `-no-allocations` applies the performance-annotation checker (§4.3 step 9) to every function in the module, as if each were `@_noAllocation`.
- `-enforce-exclusivity=unchecked` lowers dynamic `begin_access` markers to nothing. Static exclusivity diagnostics (§4.3 step 4) still run.

**Parallelism** (D11, SPMD lanes). Every lane runs the same pass code. Intraprocedural stages hand out functions through a shared **atomic cursor** over the `FunctionId`-ordered list: each lane takes the next index until the list is exhausted, and a barrier ends the stage. This is the irregular-work case of the lane model, with no deques and no job graph. Interprocedural work in step 3 runs lanes over a per-level frontier of the bottom-up SCC DAG: all SCCs whose callees are finished form one level, lanes claim SCCs from that level by atomic cursor, and a barrier separates levels. Because a function's callees have all finished before it starts, the inliner always sees optimized callee bodies and final effect summaries. Functions in the same SCC (mutual recursion) are not inlined into one another.

**Determinism (D6).** Every function's output depends only on its own input and the final state of its callees. In particular:

- **Specialization identity.** A specialization is identified by its mangled name ([11 §Mangling](11-generics-and-runtime-metadata.md)). Concurrent requests for the same specialization are deduplicated by that name, and the clones are identical by construction.
- **Function numbering.** New `FunctionId`s are assigned at a barrier after step 3, by sorting mangled names. They are never assigned in the order threads happen to finish.
- **Inliner budgets** are computed from instruction counts. Timing never enters them.

### 4.5 ARC optimization

Retain and release pairs are the main source of overhead specific to Swift.

**Basic rule.** A `strong_retain %x` and a later `strong_release %x` on the same path can both be removed if no instruction between them may decrement the reference count of `%x`, or of any value that may alias it, to zero. Equivalently, every instruction between them must be known **not to release** a reference to the object. A call meets this requirement only if the callee's effect summary (§4.6) says it does not release, or if the caller holds another strong reference that it provably keeps alive across the call, such as a guaranteed parameter.

```
// Before:
air.strong_retain %obj
%r = air.call @f(%obj)        // @f is known not to release (from its effect summary)
air.strong_release %obj

// After:
%r = air.call @f(%obj)
```

**Escape does not affect this rule.** If `@f` stores `%obj` somewhere, then under the guaranteed-argument convention `@f` performs its own retain for that store.

**Lifetimes and deinit barriers.** ARC optimization MUST respect Swift's lexical lifetime rules. It may not move a release, and with it a possible `deinit`, earlier across a deinit barrier: a call with unknown side effects, a synchronization point, or an access to memory that the deinit could observe. Variables that the user marked with `withExtendedLifetime` or `_fixLifetime` keep their full lifetime.

**Code motion.** Retains are moved later and releases earlier with a bidirectional dataflow over the CFG, which exposes pairs that span blocks. Code motion stops at deinit barriers and at loop boundaries; loop-carried pairs are handled by LICM-style hoisting only when the trip count is known to be nonzero.

### 4.6 Supporting analyses

- **Dominators.** The iterative Cooper–Harvey–Kennedy algorithm over a reverse postorder of the CSR CFG. Post-dominators are computed the same way on the reversed CFG.
- **Loops.** Natural loops are found from **back edges**: edges `t → h` where `h` dominates `t`. The body of each loop is collected by walking predecessors backward from `t` to `h`, and the loops are then arranged into a nesting forest. Tarjan's and Kosaraju's SCC algorithms are not used to find loops: they find cycles, but they do not identify headers or nesting. They are used only for call-graph SCCs (§4.4).
- **Irreducible control flow.** C `goto` can create a cycle with no dominating header; Swift cannot. Such cycles are detected (a retreating DFS edge that is not a back edge) and marked. Loop passes skip irreducible regions; v1 does no node splitting.
- **Alias analysis.** Basic, but adequate for GVN load elimination and LICM:
  - *Allocation-site:* distinct `alloca`s and fresh allocations do not alias each other. A non-escaping `alloca` is not touched by calls.
  - *Field-sensitive projection paths:* `s.a` and `s.b` do not alias.
  - *Type-based:*
    - In Swift, values of unrelated nominal types never alias, except through raw pointers.
    - In C, the effective-type (strict aliasing) rules of C23 §6.5 apply, with `char`-type access as the universal exception. The rule is disabled by `-fno-strict-aliasing`.
- **Effect summaries.** Computed bottom-up in step 3 of the schedule. For each function, a small record says whether it may read, write, or release memory, whether it may cause a parameter to escape, and whether it may throw. External functions without a summary are treated as having all effects. Stdlib functions annotated with `@_effects` take their summary from the annotation.
- **Escape analysis** for stack promotion. A value escapes if it is stored to non-local memory, passed to a callee whose summary marks that parameter as escaping, captured by an escaping closure, or returned.
- **Induction variables.** The canonical induction variables of each natural loop and their value ranges. These feed bounds-check elimination, which can remove a check or hoist it to a single range check before the loop.

### 4.7 Lowering to LIR

After the late pipeline, the remaining Swift operations are lowered to plain AIR:

- `strong_retain` and `strong_release` become calls to the runtime's `swift_retain` and `swift_release` entry points (spelled as in [12 §6](12-standard-library-strategy.md) and emitted under `_SS` names), or inline fast paths ([08](08-runtime-and-stdlib.md)).
- Dynamic access markers become calls to the `swift_beginAccess` / `swift_endAccess` runtime entry points ([12 §6](12-standard-library-strategy.md)).
- `witness_method` becomes a load at a fixed offset into the witness table.

AIR then goes to instruction selection ([04](04-backend.md)). Switch hints, the `@_semantics`-derived cold-path annotations, and loop-nesting depth are passed along for block layout and for register allocation's splitting heuristics.

## 5. Performance targets

All of the following are **targets**, measured as described in [14](14-measurement-methodology.md):

- **Optimizer time.** At `-O`, the optimizer SHOULD take ≤ 25% of total compile time on the reference corpora.
- **Memory.** Peak optimizer memory SHOULD be proportional to the largest single function, plus module-level effect summaries and the call graph. Per-function scratch arenas are reset between functions.
- **Runtime performance (hypothesis).** On the non-vectorizable benchmark set, generated code reaches 80–90% of LLVM `-O2` (C) or `swiftc -O` (Swift), as a geometric mean.

**Known risks to the parity hypothesis:**

- **No auto-vectorization by default.** Plain scalar C numeric kernels, string scanning, and memory-bound loops may fall well below 80% unless they are written with portable SIMD types, hit a loop idiom, or are built with `-vectorize` ([17](17-simd-and-vectorization.md)). These benchmarks are reported separately, with and without `-vectorize`, and are not averaged away.
- **Swift abstraction removal is broader than this pipeline.** `swiftc -O` also performs closure specialization, CoW and array-semantics optimizations, function signature optimization, and more aggressive ARC code motion. Code that is heavy on generics or collections may land below target until some of these are added.
- **Alias analysis is basic.** Pointer-heavy C code gets less load elimination and less LICM than it would under LLVM.
- **No instruction scheduling.** This matters little on out-of-order x86-64 and AArch64 cores, but may matter on in-order RISC-V implementations.

**On LLVM, for comparison.** LLVM's `-O2` pipeline runs on the order of a hundred pass instances, including InstCombine, loop and SLP vectorization, and memory optimizations driven by alias analysis. Polly is not part of the default pipeline. How LLVM's optimizer time is split varies by workload, and this document assumes no particular split.

## 6. Alternatives considered

- **Pointer-linked SSA (LLVM / MLIR style).** Rejected for the storage reasons in [00](00-overview-and-principles.md). The cost is harder instruction insertion, which §4.1 handles with an order column and periodic compaction.
- **Sea of nodes (V8 TurboFan, HotSpot C2).** Rejected. Floating nodes simplify GVN and code motion, but scheduling becomes a separate hard problem, and the debug-info mapping gets worse.
- **Block arguments instead of phi.** A reasonable alternative, and it maps well onto CSR edges. Phis were kept because Mem2Reg and SCCP are written against them in the literature; this remains an open question.
- **Keeping ownership (OSSA) through optimization,** as `swiftc` is moving towards. Deferred. It gives better ARC optimization, but every pass would have to preserve ownership invariants.
- **A separate Swift-level IR (like SIL) above a C-level IR.** Rejected. Having one IR keeps C/Swift cross-inlining trivial, at the cost of a richer opcode set.

## 7. Open questions

1. ~~Should loop idiom recognition be added to v1?~~ Resolved: yes ([17](17-simd-and-vectorization.md) §5.5).
2. Phis or block arguments (§6)?
3. Should Tier 1 ever emit an unspecialized copy of a function that is used only in specialized form within the image, or can unspecialized copies be dropped when no metadata-passing caller exists?
4. When does the extra ARC optimization that ownership (OSSA) enables pay back the cost of every pass preserving ownership invariants? This should be measured once the M5 corpus exists.
5. How should the inliner budget be set (instruction-count threshold, caller growth cap)? The starting values are 25 AIR instructions and 2× caller growth; they are to be tuned against [14](14-measurement-methodology.md) data.
