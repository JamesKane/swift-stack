# 08. Runtime Systems & Todhchai OS Integration

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [03](03-intermediate-representation.md), [06](06-linker.md), [11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md) |

---

## 1. Summary

This chapter specifies the runtime that Swift-Stack binaries link against. It covers:

- The two Swift runtime tiers, **Tier 0** (embedded profile) and **Tier 1** (full Swift), and what each actually implements.
- The OS-agnostic **executor interface** used by lowered async code, with backends for the croi port, `kqueue`, and `epoll`.
- Process startup (the Todhchai "system floor" and the POSIX host equivalent).
- Thread-local storage layout per architecture.
- The C library each target links against.

The Swift *standard library* (`Swift` module, FoundationEssentials) is compiled from upstream sources and is covered in [12](12-standard-library-strategy.md). This chapter covers the *runtime*: the non-Swift-source support code those libraries and compiled programs call into. Per decision D2, the upstream C++ runtime is not reused; Swift-Stack reimplements the runtime in Swift and C23.

## 2. Goals

- Provide every runtime entry point required by code that Swift-Stack emits and by the upstream stdlib sources it compiles ([12 §5](12-standard-library-strategy.md)).
- Keep Tier 0 small enough for kernel-adjacent services, drivers, and real-time components on Todhchai.
- Use one executor abstraction across all targets so async lowering ([03](03-intermediate-representation.md)) never references OS primitives directly.
- Match the C ABI and TLS ABI of each target exactly (D1), so C code compiled by other toolchains can be linked in.

## 3. Non-goals

- Binary compatibility with Apple's `libswiftCore` / `libswift_Concurrency` or swiftc-built modules (D1). Metadata layout, refcount layout, and runtime symbol names are Swift-Stack's own ([11](11-generics-and-runtime-metadata.md)).
- Objective-C interop, bridging, or `NSObject` root classes.
- `libdispatch`. Neither tier depends on it on any target.
- Windows.

---

## 4. Runtime Tiers

```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│ Tier 0: Embedded profile             │ Tier 1: Full Swift                   │
│ - Specialized generics only (D3)     │ - Generic metadata passing (D3)      │
│ - Static .rodata metadata            │ - Metadata instantiation & caches    │
│ - No existentials of non-class type  │ - Existentials, dynamic casts        │
│ - Optional allocator hook            │ - Allocator, refcounting             │
│ - Minimal panic path                 │ - Tasks, jobs, actors, executors     │
│ Users: drivers, fs, compositor       │ Users: shell, UI kit, tools          │
├──────────────────────────────────────┴──────────────────────────────────────┤
│                      C library & startup (§7, §8)                           │
│ Todhchai: clean-room C23 libc, static  │  Hosts: system libc, dynamic       │
└─────────────────────────────────────────────────────────────────────────────┘
```

The tier is a per-module compilation setting recorded in the module interface ([13](13-modules-and-incremental-builds.md)). A Tier 0 module MAY be linked into a Tier 1 program. A Tier 1 module MUST NOT be linked into a Tier 0 program; the linker rejects this ([06](06-linker.md)).

### 4.1 Tier 0: Embedded profile

Tier 0 follows the language subset of upstream Embedded Swift. All generics are fully specialized at compile time (D3), and there is no runtime metadata instantiation.

**"Zero heap allocation" is a profile, not an absolute property of the tier.** Embedded Swift permits class types, which are reference counted and need an allocator. The precise guarantee is:

- Language operations that do not involve class instances, escaping closures, or allocating stdlib APIs (for example `Array` growth) MUST NOT allocate.
- A module compiled with the `-no-allocations` profile flag MUST be rejected at compile time if it contains any construct that could reach the allocator. The diagnostic names the construct and the call path ([15](15-driver-and-diagnostics.md)). Accepted code is guaranteed allocation-free.
- Without the flag, Tier 0 code that allocates calls `swift_ss_alloc` / `swift_ss_dealloc` (symbol names are illustrative; final spelling follows the `_SS` scheme in [11](11-generics-and-runtime-metadata.md)). These forward to a hook the program provides; the default hook on Todhchai is the libsys page allocator.

What the Tier 0 runtime implements:

| Area | Contents |
|---|---|
| Metadata | None at runtime. Nominal type descriptors, field offsets, and witness tables are emitted by the compiler as `.rodata` constants ([11](11-generics-and-runtime-metadata.md)). No registration at startup. |
| Refcounting | Non-atomic and atomic retain/release for class instances. Same object header layout as Tier 1, without the side-table extension (weak references are not supported in Tier 0, to be verified against the upstream Embedded subset). |
| Allocation | Allocator hook (see above). |
| Memory primitives | `memset`, `memcpy`, `memmove`, `memcmp`, provided by libsys on Todhchai and libc on hosts. |
| Failure | `swift_ss_fatal`: writes a fixed-format message to the debug port (Todhchai) or `stderr` (hosts) without allocating, then traps. |
| Stack protector | `__stack_chk_guard`, `__stack_chk_fail`. |
| Entropy | `arc4random_buf` (croi CPRNG on Todhchai; libc on hosts), needed by the stdlib's hashing seed. |

Tier 0 provides no existentials over non-class protocols, no dynamic casts beyond class casts, no key paths, no reflection, and no concurrency runtime. The exact excluded set matches the upstream Embedded Swift restrictions for the pinned release ([12 §7](12-standard-library-strategy.md)).

### 4.2 Tier 1: Full Swift

Tier 1 is the runtime for general user-space code. It implements the following families. Layouts are specified in [11](11-generics-and-runtime-metadata.md); this table defines responsibility only.

| Family | Responsibility |
|---|---|
| **Allocation & refcounting** | Object header (metadata pointer plus inline refcount word), atomic strong retain/release, unowned and weak references via a side table, `deinit` dispatch on last release, unique-reference checks used by copy-on-write (`isUniquelyReferenced`). |
| **Metadata** | Instantiation of generic type metadata on first use, keyed by `(descriptor, generic arguments)`. Lock-free lookup caches with a slow path that takes a lock. Value witness tables for generic types. Metadata MUST be uniqued, so pointer equality means type equality. |
| **Conformances** | Protocol conformance lookup for dynamic casts and generic instantiation. The linker emits a sorted conformance table per image ([06](06-linker.md)); lookup is a binary search plus a cache. Conditional conformances are evaluated at instantiation time. |
| **Existentials** | Opaque, class, and metatype existential containers; boxing of values that don't fit the inline buffer; projection and copy via value witnesses. |
| **Dynamic casts** | `as?`, `as!`, `is` across classes, existentials, metatypes, `Optional`, and the collection bridges required by the stdlib. Cast semantics MUST match swiftc for supported types (D5). |
| **Exclusivity** | Dynamic exclusivity checking for class properties, globals, and escaping closures. Per-thread access set, with a fast path for the common no-conflict case. Can be disabled per module in release builds, matching swiftc's `-enforce-exclusivity=unchecked`. |
| **Concurrency** | Task allocation (a task-local slab allocator), jobs, task groups, cancellation, task-local values, continuations, the default actor implementation, and the executor interface in §5. |
| **Errors & failure** | `fatalError` and precondition failures, error existential boxing (for untyped `throws`), and backtrace capture on crash using the unwinder ([07](07-debugging-and-sdi.md)). |
| **Reflection** | The field metadata needed by `Mirror` and by `print`/`debugPrint` of arbitrary values, as used by the upstream stdlib. |
| **Key paths** | Key path object layout and component interpretation as required by the stdlib's `KeyPath` implementation (to be audited against the pinned stdlib). |

The runtime is written in Swift (Tier 0 profile, so it cannot depend on itself) plus a small amount of C23 and assembly: context switching, atomics fallbacks, and the startup floor.

---

## 5. Executor Interface & Port-Driven Concurrency

### 5.1 OS-agnostic interface

Async lowering in AIR ([03](03-intermediate-representation.md)) emits calls only to the task and job runtime. That runtime enqueues work through a single executor interface, and OS-specific code exists only behind it:

```swift
/// Implemented once per OS backend. All functions are thread-safe.
public protocol ExecutorBackend: ~Copyable {
    /// Make `job` runnable. May be called from any thread.
    func enqueue(_ job: JobRef)
    /// Block the calling worker until work, a timer, or an I/O event is ready.
    /// Returns the ready jobs.
    func wait(into ready: inout JobBatch, deadline: Deadline?)
    /// Arrange for `job` to be enqueued at or after `deadline` (monotonic clock).
    func enqueue(_ job: JobRef, at deadline: Deadline)
    /// Register interest in an I/O source; `job` is enqueued when it becomes ready.
    func watch(_ source: IOSource, _ interest: IOInterest, _ job: JobRef)
    /// Wake one blocked worker (used after enqueue from a non-worker thread).
    func wakeOne()
}
```

The worker pool, global run queue, and actor scheduling are shared code above this interface. A backend is between roughly 300 and 800 lines of OS-specific code; this is a sizing estimate, not a measured figure.

### 5.2 Todhchai backend: croi port

```
croi microkernel event sources
  ├─ channel message arrival
  ├─ display vblank
  ├─ monotonic timer expiry
  └─ storage I/O completion
            │  (packet queued on process-wide port)
            ▼
     td_executor_port
            │  (port_wait returns in one blocked worker)
            ▼
   executor worker thread → runs job → resumes async task
```

- Worker threads block in croi `port_wait` on `td_executor_port`.
- Timers (`Task.sleep(until:)`) are submitted as port packets with an absolute monotonic deadline.
- `enqueue` from a non-worker thread queues a user packet on the port, which wakes one worker.

**What this saves.** The event source's packet wakes the executor thread directly. There is no intermediate dispatcher or reactor thread that receives the event and then signals a worker over a condition variable. Waking a blocked worker is still one kernel wake-up and one context switch. The design removes extra hops; it does not avoid the switch.

### 5.3 POSIX backends

| Host | Wait primitive | Timers | Cross-thread wake | Notes |
|---|---|---|---|---|
| FreeBSD | `kqueue` / `kevent` | `EVFILT_TIMER` (absolute deadlines via `NOTE_ABSTIME`) | `EVFILT_USER` | Threads are `libthr` 1:1; runtime locks use `_umtx_op` directly where `pthread` would add overhead (to be measured). |
| Linux | `epoll_wait` | `timerfd` (`CLOCK_MONOTONIC`, `TFD_TIMER_ABSTIME`) | `eventfd` | Runtime locks use `futex`. |
| macOS | `kqueue` / `kevent` | `EVFILT_TIMER` | `EVFILT_USER` | Runtime locks use `os_unfair_lock`. |

Timer coalescing, run-queue design, and the worker-count policy are shared. Backend behaviour MUST be observably identical: the same task ordering guarantees and the same cancellation semantics.

---

## 6. Process Startup

### 6.1 Todhchai: the system floor

Todhchai executables are static `ET_EXEC` images loaded at `0x1000000` ([06](06-linker.md)). Execution begins in the floor (`system/sys/floor/start.S` in the Todhchai tree), assembled by the built-in assembler ([05](05-assembler.md)):

```
croi loader ──► static ELF mapped at 0x1000000
                          │
                          ▼
                    _start (floor)
   1. Align stack pointer to 16 bytes
   2. Unpack process args (argc, argv, envp, auxv)
   3. Set up static TLS for the main thread (§7) and set the thread pointer
   4. Initialize stack protector guard and runtime globals
   5. Run .preinit_array and .init_array
   6. Call main(argc, argv, envp)
   7. Run atexit handlers and .fini_array
   8. sys_process_exit(status)
```

Step 4 MUST precede any Swift code. In Tier 1 programs, the conformance and metadata tables need no registration step at startup, because they are located through linker-defined section bounds ([06](06-linker.md)).

### 6.2 POSIX hosts

Hosted executables are dynamically linked against the system C library (§8). Proposed default: link the system's C runtime start files (`crt1.o`/`Scrt1.o`, `crti.o`, `crtn.o` on Linux and FreeBSD; on macOS, `dyld` calls `main` directly via `LC_MAIN`). Swift-Stack's runtime initialization runs from an `.init_array` entry, so the host's libc startup sequence is untouched.

The alternative is shipping Swift-Stack's own `crt` objects for Linux and FreeBSD, which removes the dependency on locating host crt files. This is an open question (§11).

---

## 7. Thread-Local Storage

The linker resolves static TLS offsets for executables ([06](06-linker.md)). The runtime sets up the main thread's TLS block (Todhchai floor) or relies on the system dynamic loader (hosts). Layouts per the ELF TLS ABI:

| Arch | Variant | Thread pointer | Layout |
|---|---|---|---|
| x86-64 | II | `%fs` base | `%fs:0` holds the TCB self-pointer. The executable's TLS block sits immediately *below* the thread pointer, at negative offsets. Local-exec access is `mov %fs:-off, %reg`. |
| AArch64 | I | `TPIDR_EL0` | The thread pointer addresses a 16-byte TCB. The executable's TLS block starts at `tp + 16`, rounded up to the block's alignment. Local-exec uses `R_AARCH64_TLSLE_*` relocations. |
| RISC-V 64 | I | `tp` (`x4`) | The thread pointer addresses the start of the executable's TLS block (offset 0). The TCB, if any, lies below `tp`, so there is no gap above it. Local-exec uses `R_RISCV_TPREL_*` relocations. To be verified against the RISC-V ELF psABI for the pinned version. |

Executables use the local-exec model for their own TLS. Hosted executables that reference TLS in shared libraries use initial-exec or general-dynamic as required by the host ABI ([06](06-linker.md)). The Swift runtime uses TLS for the current task, the exclusivity access set, and the current executor.

---

## 8. C Library Linkage

| Target | C library | Linkage |
|---|---|---|
| Todhchai | Todhchai clean-room C23 libc | Static |
| Linux | glibc (musl: open question) | Dynamic, `/lib64/ld-linux-x86-64.so.2` (x86-64), `/lib/ld-linux-aarch64.so.1`, `/lib/ld-linux-riscv64-lp64d.so.1` |
| FreeBSD | FreeBSD libc / `libthr` | Dynamic, `/libexec/ld-elf.so.1` |
| macOS | `libSystem` | Dynamic only. Static executables are not supported by the platform. |

On Todhchai:

- `malloc`, `free`, `realloc`, and `posix_memalign` are backed by Todhchai's page-backed VMO allocator. The Swift runtime's allocator calls them.
- `pthread_mutex_t` and `pthread_cond_t` are implemented on croi priority-inheritance futexes (`td_futex_wait`, `td_futex_wake`).

C headers for all targets are parsed by Swift-Stack's own C frontend. Host headers require the GNU/Clang host-header profile (D7, [02](02-semantic-analysis.md)).

---

## 9. Testing

- Runtime unit tests run on every host backend and on Todhchai (or an emulator).
- The upstream stdlib test executables ([12 §9](12-standard-library-strategy.md)) exercise most runtime families indirectly.
- Executor backends share a conformance suite covering ordering, cancellation, timer accuracy, and wake-from-foreign-thread.
- TLS layout is checked by a test program per architecture that compares `&threadLocal` against `tp + expectedOffset` and against values produced by the host C compiler.

## 10. Alternatives considered

- **Reuse upstream's C++ runtime.** Rejected: Swift-Stack has no C++ frontend (C++ is a non-goal), and D1 frees us from Apple's metadata layout. Upstream remains a behavioural reference.
- **libdispatch-based executor on hosts.** Rejected: it would give the hosts a different scheduling model from Todhchai and adds a large dependency.
- **One reactor thread plus worker pool.** Rejected for the default backends because it adds a hop per event. It may be kept as a debugging backend.

## 11. Open questions

1. Host startup: system crt files or Swift-Stack-provided crt objects on Linux and FreeBSD?
2. musl support on Linux (static hosted executables)?
3. Weak references in Tier 0: follow the upstream Embedded restriction exactly, or allow them with a side-table opt-in?
4. Worker-count policy: fixed to core count, or adaptive with blocking detection?
5. Should the Tier 1 runtime itself be compiled as a Tier 0 module (no metadata dependence) throughout, or only its bootstrap subset?
