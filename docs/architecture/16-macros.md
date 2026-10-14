# 16. Swift Macros

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md) (D1, D4, D6), [01](01-frontend.md), [03](03-intermediate-representation.md), [07](07-debugging-and-sdi.md), [10](10-semantic-ir-and-name-resolution.md), [13](13-modules-and-incremental-builds.md), [15](15-driver-and-diagnostics.md) |

## 1. Summary

Swift macros (SE-0382, SE-0389, SE-0397, SE-0402, SE-0415) are a goal, and **Todhchai OS is the first-party use case**. Its IPC system and audio SDK are built on macros, and they compile as Tier 0 Embedded Swift, so macro support is on the critical path for milestone M4 ([09](09-roadmap.md)).

Swift-Stack supports macros through the **out-of-process compiler-plugin protocol**. Each macro implementation is a separate plugin executable. The compiler sends it source text and context as JSON over a pipe and receives expanded source text back. Then:

- the compiler parses the expansion with its own parser;
- the compiler never links swift-syntax;
- the process boundary means a plugin's ABI doesn't matter, so plugins built by the host `swiftc` work unchanged (D1).

## 2. First-party requirements (Todhchai)

The following use was surveyed from the Todhchai source tree (pinned swift-syntax `604.0.0`).

| Macro | Roles | What it does | Used by |
|---|---|---|---|
| `@IPCLibrary(id:version:)` | `@attached(member, names: arbitrary)` | Generates `PClient`, `PHandler`, `PServer`, `PEvent`, `PEventSender` for each protocol `P` in an IPC library enum | `fs`, `node`, `keyring`, `router`, `pty`, `script`, `radharc`, graphics buffers, … |
| `@oneway`, `@event`, `@since(_:)` | `@attached(peer)` (marker: expands to nothing) | Annotations read by `@IPCLibrary` from the attached declaration's syntax | IPC protocol declarations |
| `@AudioRenderer` | `@attached(memberAttribute)`, `@attached(extension, conformances: AudioRenderer, names: named(_realtimeChecked))` | Adds `@_noAllocation` to `render` methods; adds the `AudioRenderer` conformance | Audio SDK clients |
| swift-testing `@Test`, `@Suite`, `#expect`, `#require` | attached peer/member, freestanding expression | Test declaration and assertions | ~166 test files |

Todhchai's Embedded CMake build passes `-load-plugin-executable <path>#<Module>`, with plugins built by host SwiftPM. Swift-Stack's `swiftc` compatibility personality must accept the same flag ([15](15-driver-and-diagnostics.md) §4.1).

`@AudioRenderer` exists only to attach `@_noAllocation`. Its value depends on the compiler enforcing that attribute. That is specified in [03](03-intermediate-representation.md) §4.3 (performance-annotation checking).

## 3. Goals

- Every macro role: freestanding `expression` and `declaration`, and attached `peer`, `member`, `memberAttribute`, `accessor`, `extension` and `body`. Experimental roles (`codeItem`, `preamble`) are deferred until Todhchai or the stdlib needs them.
- Executable plugins via `-load-plugin-executable <path>#<module>` and plugin search paths (`-plugin-path`).
- **Compatibility:** expanded source text identical to `swiftc`'s for the same plugin and input (differential-tested, §5.9). Name lookup and type-checking behavior around macros MUST match `swiftc` (D5).
- Macros usable from Tier 0 and Tier 1 code. Expansion happens on the build host and is independent of the target tier.
- Deterministic, cacheable expansion (D6, [13](13-modules-and-incremental-builds.md)).
- Diagnostics and debugging that work inside expansions.

## 4. Non-goals

- **In-process library plugins** (`-load-plugin-library`, `swift-plugin-server`). Loading a `swiftc`-built dynamic library into the compiler would need `swiftc` ABI compatibility (D1). The executable form covers the same macros.
- **Linking or reimplementing swift-syntax in the compiler.** Plugins use swift-syntax; the compiler does not.
- **Native reimplementation of specific macros** (an allowlist). The general mechanism makes that unnecessary. The only native macros are the built-in ones in §5.6.

## 5. Design

### 5.1 Clean-room position

- The plugin wire protocol is an **interface**, like ELF or the C ABI. Swift-Stack implements it from its message definitions in the pinned swift-syntax release (the `PluginMessages` schema) and from observed `swiftc` behavior. Reading an interface definition to interoperate with it is consistent with Principle 3, which forbids linking or copying implementation code ([00](00-overview-and-principles.md)). This is recorded as part of D4.
- swift-syntax and macro implementations are **inputs**, in the same way the stdlib is under D2. Swift-Stack can compile them into plugin executables once Tier 1 works ([09](09-roadmap.md) M6). Until then the host `swiftc` builds them.

### 5.2 Pipeline

```
 ParseTree ──► macro use found (#name(...) or @Name on a declaration)
                 │
                 ▼  resolve the macro declaration (name lookup, §5.4)
           MacroDecl: #externalMacro(module: M, type: T), roles, introduced names
                 │
                 ▼  build request: role, syntax text + location, attached/parent decl text,
                 │  extended type, conformances, lexical context, discriminator
           Plugin host (driver-owned process pool, §5.5)
                 │  JSON over stdin/stdout ──► plugin executable (swift-syntax inside)
                 ▼
           expanded source text  |  diagnostics (+ notes, fix-its)
                 │
                 ▼  new SourceManager entry of kind `macroExpansion` (§5.3)
           lex + parse expansion with the Swift parser (role-specific entry point)
                 │
                 ▼  splice into the enclosing scope / SemIR (§5.4)
           name resolution and type checking continue as normal
```

### 5.3 Expansion buffers and locations

Each expansion produces a new source buffer, registered in the unit's location space as an entry of kind `macroExpansion` ([01](01-frontend.md) §4.3). It works like a C macro `expansion` entry and records:

- the **expansion site**: the range of the macro use or attribute in the parent buffer;
- the **macro**, as the `DeclId` of the macro declaration, and the **role**;
- a **discriminator** that is unique and deterministic per expansion. It is derived from the mangled name of the enclosing context and the ordinal of the expansion within it, never from a global counter (D6). The same discriminator is sent to the plugin as `context.makeUniqueName`'s seed, which is why expansions are reproducible.

Expansions can be nested (a macro expanding to another macro use). Each nested expansion is its own entry, with its parent expansion as the parent location. A depth limit (default 64, matching the role of `swiftc`'s limit) turns runaway recursion into a diagnostic.

The parser has an entry point per role: expression, declaration list, member list, attribute list, accessor block, extension declarations, and function body. Expanded text that doesn't parse as its role's syntactic category is reported against the expansion buffer, with a note at the use site.

### 5.4 Name lookup and ordering

Macros interact with name lookup because attached macros introduce declarations ([10](10-semantic-ir-and-name-resolution.md)).

- **Declared names.** A macro declaration's role attributes list the names its expansions may introduce: `named(x)`, `overloaded`, `prefixed(p)`, `suffixed(s)`, or `arbitrary`. Declaration collection (Sem phase 1) records every attribute and `#name` use. Phase 2 resolves which ones name macros and records, per scope, each attached macro with its name patterns, without expanding it ([10](10-semantic-ir-and-name-resolution.md) §4.10).
- **Lazy expansion on lookup.** When a qualified or unqualified lookup in a scope asks for name `n`, the scope's macros are checked:
  - every macro whose patterns could introduce `n` is expanded first, if it hasn't been already;
  - `names: arbitrary` (as used by `@IPCLibrary`) matches every name, so any lookup into that type's members expands it.

  Expansions are memoized per (expansion site, role).
- **Resolving the macro itself.** Resolving which macro an attribute or `#name` refers to uses lookup that MUST NOT trigger macro expansion. This is the same restriction `swiftc` applies: macros cannot introduce names used to resolve macros. A cycle is a diagnostic, not a hang.
- **Eager expansion.** Expansions whose results are needed regardless of lookup are expanded eagerly in Phase 2, before canonical renumbering (D6). These are conformance-introducing `extension` macros, `memberAttribute` macros (which change attributes on existing members), `body` macros and `peer` macros on public declarations. Their provisional handles are renumbered like any other declaration ([10](10-semantic-ir-and-name-resolution.md) §4.6).
- **Context available to plugins.** Plugins receive syntax only: the attached declaration, the parent declaration, the extended type spelling, and the lexical context chain. They never receive type-checked information. That matches the language model, and it means expansion depends only on syntax and the plugin binary, which is what makes it cacheable (§5.7).

### 5.5 Plugin host

The driver owns plugin processes ([15](15-driver-and-diagnostics.md) §4.4):

- **Discovery.** `-load-plugin-executable <path>#<module>` maps a module name (as used in `#externalMacro(module:)`) to an executable. `-plugin-path <dir>` searches for executables named after the module. A macro whose module isn't mapped is a diagnostic at the macro declaration's first use.
- **Handshake.** On first use the host starts the executable, sends `getCapability`, and records the protocol version. The minimum supported version matches the pinned swift-syntax release; older plugins are rejected with a diagnostic.
- **Messages.** The protocol message set is to be verified against the pinned swift-syntax `PluginMessages` definitions:
  - `expandFreestandingMacro` and `expandAttachedMacro`, carrying: the macro reference (module, type name); the role; the discriminator; the syntax node as source text with location (file ID, file path, offset, line, column); the attached and parent declarations; the extended type; the conformance list; the lexical context.
  - Replies are `expandMacroResult`: expanded source, or diagnostics with positions, notes and fix-its.
  - Framing is a length-prefixed JSON message on stdin/stdout.
- **Concurrency.** One plugin process handles one request at a time. The host keeps a small pool per plugin, up to `min(jobs, 4)` processes by default, started lazily. Requests are dispatched from worker threads, and results are attached to the expansion site, so arrival order never affects output (D6).
- **Failure handling.** If a plugin crashes, times out (default 30 s, configurable) or sends a malformed reply, the expansion fails with a diagnostic naming the plugin and the macro, and the process is restarted for later requests. A plugin failure never crashes the compiler.
- **Sandboxing.** Plugins SHOULD run with only stdin, stdout and stderr:
  - Capsicum `cap_enter` on FreeBSD;
  - Landlock plus seccomp on Linux;
  - the system sandbox profile on macOS;
  - on Todhchai, the plugin process is given only its two channel handles.

  `--plugin-sandbox=off` disables this for debugging.

### 5.6 Built-in macros

These are expanded natively, because they are part of the language rather than a plugin:

- `#file`, `#fileID`, `#filePath`, `#line`, `#column`, `#function`, `#dsohandle`;
- `#warning`, `#error`, `#isolation`;
- `#externalMacro` (valid only as a macro definition).

When `#fileID`, `#line` and the others are used as default arguments, they expand at the call site. This applies to both built-in and plugin macros. Any macros that the upstream stdlib or FoundationEssentials *declare* (for example `#Predicate`, `@DebugDescription`, `@TaskLocal`; inventory to be verified by the audit in [12](12-standard-library-strategy.md)) go through the plugin mechanism like any other. Their plugins are built from the upstream macro sources as inputs.

### 5.7 Caching, determinism and modules

- **Expansion cache key:** BLAKE3 of (plugin executable content hash, macro module and type, role, the full request payload *excluding* absolute file paths, and the protocol version). Absolute paths are replaced by the stable file identity used elsewhere ([13](13-modules-and-incremental-builds.md)), so cache hits survive moving the checkout.
- **Purity assumption.** Plugins are assumed pure: the same request gives the same expansion. The cache makes the output deterministic even if a plugin isn't.
  - `--verify-macro-determinism`, which CI enables, expands each site twice in separate processes and reports any difference as a plugin defect.
- **Incremental builds.** An expansion depends on its request payload and the plugin hash. Editing an attached declaration re-expands only that site. Changing a plugin binary invalidates all of its expansions.
- **Module interfaces.** Declarations introduced by expansions are serialized into `.ssmodule` files as ordinary declarations, along with the expansion buffers' text, so that diagnostics and debug info can still show them. Clients of a module never need the plugins that module used. Only modules that *use* a macro need its plugin.

### 5.8 Diagnostics and debugging

- **Diagnostics inside an expansion** show the expanded-code location plus a note chain: "in expansion of macro `IPCLibrary` here" at each use site.
- **Plugin diagnostics** (from `context.diagnose`) are mapped into the `DiagnosticBag` with the plugin's severity, notes and fix-its ([15](15-driver-and-diagnostics.md) §4.5).
- **Dumps.** `--dump=macro-expansions` prints every expansion, along with its site and discriminator, in a stable format that is used by golden tests.
- **Debug info.** Expansion buffers appear in the SDI file table as virtual files (path `<macro:Module.Type>/<discriminator>.swift`), with their text stored in the SDI string pool. That lets a debugger show and step through generated code such as `FsServer.handle(...)`. DWARF output carries the same text through the embedded-source line-table extension (`DW_LNCT_LLVM_source`), subject to host debugger support ([07](07-debugging-and-sdi.md) §5.2).

### 5.9 Testing

- **Differential expansion.** For each macro use in the Todhchai corpus and a synthetic per-role suite, the expanded text from Swift-Stack must equal the text from `swiftc -Xfrontend -dump-macro-expansions` with the same plugin (exact flag to be verified). After that, the usual execution differential applies ([09](09-roadmap.md) §6).
- **Protocol conformance.** A fake plugin produces scripted replies, including malformed ones, crashes and timeouts, to exercise the host's error paths.
- **Name-lookup ordering tests:** `arbitrary` names, `named` names, macros on extensions, nested expansions, and cycles.
- **Plugin unit tests** (e.g. Todhchai's `SwiftSyntaxMacrosGenericTestSupport` suites) test the plugins, not the compiler. They are run, but they are not evidence of compiler correctness.

## 6. Alternatives considered

| Alternative | Why not |
|---|---|
| Make macros a non-goal (earlier draft of D4) | Todhchai's IPC and audio SDK depend on them; without macros, M4 can't compile `fs`. |
| Natively reimplement each needed macro | Doesn't scale to user macros, duplicates plugin logic, and diverges from the plugins' real behavior. |
| Reimplement swift-syntax's API inside the compiler and run plugins in-process | Needs `swiftc` ABI compatibility or a Swift-Stack-built swift-syntax. Large, and it couples the compiler's memory model to swift-syntax's object graph. |
| In-process library plugins | Same ABI problem (D1). Executable plugins are what SwiftPM and Todhchai's CMake already use. |

## 7. Open questions

1. Does the plugin protocol's lexical-context field need full declaration text for every enclosing context? This affects request size for deeply nested `@IPCLibrary` enums. Measure under [14](14-measurement-methodology.md) B12.
2. ~~Should Swift-Stack build Todhchai's plugins itself?~~ Resolved: yes, from M6 ([09](09-roadmap.md) M6 deliverables). Until then the host `swiftc` builds them.
3. Is a `swiftc`-compatible `-dump-macro-expansions` format worth matching byte-for-byte, or is only the expanded text compared?
4. How does swift-testing discover tests at runtime on Linux and Todhchai (a section-based record or metadata scanning)? This is needed for running Todhchai's test suites ([12](12-standard-library-strategy.md)).
