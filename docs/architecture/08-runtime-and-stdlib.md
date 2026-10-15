# 08. Runtime Systems & VectraOS Integration

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [03](03-intermediate-representation.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md), [13](13-modules-and-incremental-builds.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

This chapter specifies the runtime that Swift-Stack binaries link against. It covers:

- The two Swift runtime tiers, **Tier 0** (embedded profile) and **Tier 1** (full Swift), and what each actually implements.
- The OS-agnostic **executor interface** used by lowered async code, with backends for the VectraOS port, `kqueue`, and `epoll`.
- Process startup (VectraOS's user runtime entry and the POSIX host equivalent).
- Thread-local storage layout per architecture.
- The C library each target links against.

The Swift *standard library* (`Swift` module, FoundationEssentials) is compiled from upstream sources and is covered in [12](12-standard-library-strategy.md). This chapter covers the *runtime*: the non-Swift-source support code those libraries and compiled programs call into. Per decision D2, the upstream C++ runtime is not reused; Swift-Stack reimplements the runtime in Swift and C23.

## 2. Goals

- Provide every runtime entry point required by code that Swift-Stack emits and by the upstream stdlib sources it compiles ([12 §6](12-standard-library-strategy.md)).
- Keep Tier 0 small enough for the kernel, services, drivers, and real-time components on VectraOS, all of which are Tier 0 there.
- Use one executor abstraction across all targets so async lowering ([03](03-intermediate-representation.md)) never references OS primitives directly.
- Match the C ABI and TLS ABI of each target exactly (D1), so C code compiled by other toolchains can be linked in.

## 3. Non-goals

- Binary compatibility with Apple's `libswiftCore` / `libswift_Concurrency` or swiftc-built modules (D1). Metadata layout, refcount layout, and runtime symbol names are Swift-Stack's own ([11](11-generics-and-runtime-metadata.md)).
- Objective-C interop, bridging, or `NSObject` root classes.
- `libdispatch`. Neither tier depends on it on any target.
- Windows.

## 4. Runtime tiers

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
│                      C library & startup (§6, §8)                           │
│ VectraOS: first-party C23 libc, static │  Hosts: system libc, dynamic       │
└─────────────────────────────────────────────────────────────────────────────┘
```

The tier is a per-module compilation setting recorded in the module interface ([13](13-modules-and-incremental-builds.md)). A Tier 0 module MAY be linked into a Tier 1 program. A Tier 1 module MUST NOT be linked into a Tier 0 program; the linker rejects this ([06](06-linker.md)).

### 4.1 Tier 0: Embedded profile

Tier 0 follows the language subset of upstream Embedded Swift. All generics are fully specialized at compile time (D3), and there is no runtime metadata instantiation.

**"Zero heap allocation" is a profile, not an absolute property of the tier.** Embedded Swift permits class types, which are reference counted and need an allocator. The precise guarantee is:

- Language operations that do not involve class instances, escaping closures, or allocating stdlib APIs (for example `Array` growth) MUST NOT allocate.
- A module compiled with the `-no-allocations` profile flag MUST be rejected at compile time if it contains any construct that could reach the allocator. The diagnostic names the construct and the call path. This is the performance-annotation checker applied module-wide ([03](03-intermediate-representation.md) §4.3). Accepted code is guaranteed allocation-free.
- Without the flag, Tier 0 code that allocates calls the runtime's allocation entry points (the `swift_slowAlloc`/`swift_allocObject` families, [12 §6](12-standard-library-strategy.md); emitted under `_SS` names, [11](11-generics-and-runtime-metadata.md)). These forward to a hook the program provides; the default hook calls `posix_memalign`/`free`. On VectraOS the kernel implements those in Swift over its own heap (`@c @implementation`), and user programs get them from the user runtime's size-class heap over 64 KiB VMO chunks.

What the Tier 0 runtime implements:

| Area | Contents |
|---|---|
| Metadata | None at runtime. Nominal type descriptors, field offsets, and witness tables are emitted by the compiler as `.rodata` constants ([11](11-generics-and-runtime-metadata.md)). No registration at startup. |
| Refcounting | Non-atomic and atomic retain/release for class instances. Same object header layout as Tier 1, without the side-table extension (weak references are not supported in Tier 0, to be verified against the upstream Embedded subset). |
| Allocation | Allocator hook (see above). |
| Memory primitives | `memset`, `memcpy`, `memmove`, `memcmp`, provided by VectraOS's `lib/rt` (C23) and libc on hosts. |
| Failure | The `swift_reportError` / fatal-error family ([12 §6](12-standard-library-strategy.md)): writes a fixed-format message to the debug log (a VectraOS debuglog record) or `stderr` (hosts) without allocating, then traps. |
| Stack protector | `__stack_chk_guard`, `__stack_chk_fail`. |
| Entropy | `arc4random_buf` (on VectraOS over the kernel CPRNG, `cprng_draw`; libc on hosts), needed by the stdlib's hashing seed. |

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
| **Exclusivity** | Dynamic exclusivity checking for class properties, globals, and escaping closures. Per-thread access set, with a fast path for the common no-conflict case. Can be disabled per module with `-enforce-exclusivity=unchecked`, as in swiftc ([03](03-intermediate-representation.md) §4.4). |
| **Concurrency** | Task allocation (a task-local slab allocator), jobs, task groups, cancellation, task-local values, continuations, the default actor implementation, and the executor interface in §5. |
| **Errors & failure** | `fatalError` and precondition failures, error existential boxing (for untyped `throws`), and backtrace capture on crash using the unwinder ([07](07-debugging-and-sdi.md)). |
| **Reflection** | The field metadata needed by `Mirror` and by `print`/`debugPrint` of arbitrary values, as used by the upstream stdlib. |
| **Key paths** | Key path object layout and component interpretation as required by the stdlib's `KeyPath` implementation (to be audited against the pinned stdlib). |

The runtime is written in Swift (Tier 0 profile, so it cannot depend on itself) plus a small amount of C23 and assembly: context switching, atomics fallbacks, and the startup floor.

## 5. Executor interface and port-driven concurrency

### 5.1 OS-agnostic interface

Async lowering in AIR ([03](03-intermediate-representation.md)) emits calls only to the task and job runtime. The **OS-agnostic interface is that set of runtime entry points**, the `swift_task_*` families in [12 §6](12-standard-library-strategy.md). Below them, the shared runtime enqueues work through a small executor backend, and OS-specific code exists only inside the backend:

The interface is a fixed set of functions with **exactly one implementation per target**. The implementation is chosen when the runtime is compiled, by the target's OS, not at run time. There is no protocol and no witness-table dispatch on the enqueue/wake path:

```swift
// Runtime/Tier1/Executor/Backend.swift — one file per OS, selected at build time.
#if os(VectraOS)
typealias ExecutorBackend = PortBackend          // Backend+Port.swift
#elseif os(Linux)
typealias ExecutorBackend = EpollBackend         // Backend+Epoll.swift
#elseif os(FreeBSD) || os(macOS)
typealias ExecutorBackend = KqueueBackend        // Backend+Kqueue.swift
#endif

// Every backend is a struct providing the same concrete functions. Shared code
// calls them directly on `ExecutorBackend`, so each call is a static, inlinable call.
//   mutating func enqueue(_ job: JobRef)                          // any thread
//   mutating func wait(into ready: inout JobBatch, deadline: Deadline?)
//   mutating func enqueue(_ job: JobRef, at deadline: Deadline)   // monotonic clock
//   mutating func watch(_ source: IOSource, _ interest: IOInterest, _ job: JobRef)
//   mutating func wakeOne()
```

The required function set is checked by a compile-only conformance test per backend. That test is the only place a protocol is used, and it never appears on a runtime path. The `os(VectraOS)` spelling is still an open question ([12](12-standard-library-strategy.md)). Why compile-time selection:

- a runtime only ever runs on one OS;
- the wake path is the latency-critical part of the executor;
- a static call keeps it free of indirect branches and lets it inline into the run loop ([00](00-overview-and-principles.md) Principle 8).

The worker pool, global run queue, and actor scheduling are shared code above this interface. A backend is between roughly 300 and 800 lines of OS-specific code; this is a sizing estimate, not a measured figure.

### 5.2 VectraOS backend: the port

VectraOS has no Swift concurrency runtime yet; its user programs are Tier 0 today. This backend follows VectraOS's own rules, so it is the shape a Swift executor takes there: a thread waits on one port for everything (VectraOS principle 9), time is an absolute deadline plus a leeway (principle 10), event sources report to the port through `object_bind` (decision D20), and the port is drained as a ring in user memory, calling `port_wait` only when it is empty (D19, VectraOS roadmap V1).

```
VectraOS event sources, bound to the port with object_bind
  ├─ channel readable (Node protocol requests and replies)
  ├─ counter change (ring doorbells, timeline fences)
  ├─ interrupt (user-space drivers)
  └─ child exit, window events, …
            │  (packet written into the port's ring)
            ▼
     the executor's port
            │  (drained without a syscall; port_wait only when empty)
            ▼
   executor worker thread → runs job → resumes async task
```

- Worker threads drain the port's ring, and block in `port_wait` when it is empty.
- Timers (`Task.sleep(until:)`) need no kernel object: the earliest deadline among sleeping tasks is the `port_wait` deadline, with a leeway so that wake-ups coalesce. (VectraOS's V1 audit cuts its timer objects for exactly this use.)
- `enqueue` from a non-worker thread queues a user packet on the port (`port_queue`), which wakes one worker.

**What this saves.** The event source's packet wakes the executor thread directly. There is no intermediate dispatcher or reactor thread that receives the event and then signals a worker over a condition variable. Waking a blocked worker is still one kernel wake-up and one context switch. The design removes extra hops; it does not avoid the switch.

### 5.3 POSIX backends

| Host | Wait primitive | Timers | Cross-thread wake | Notes |
|---|---|---|---|---|
| FreeBSD | `kqueue` / `kevent` | `EVFILT_TIMER` (absolute deadlines via `NOTE_ABSTIME`) | `EVFILT_USER` | Threads are `libthr` 1:1; runtime locks use `_umtx_op` directly where `pthread` would add overhead (to be measured). |
| Linux | `epoll_wait` | `timerfd` (`CLOCK_MONOTONIC`, `TFD_TIMER_ABSTIME`) | `eventfd` | Runtime locks use `futex`. |
| macOS | `kqueue` / `kevent` | `EVFILT_TIMER` | `EVFILT_USER` | Runtime locks use `os_unfair_lock`. |

Timer coalescing, run-queue design, and the worker-count policy are shared. Backend behaviour MUST be observably identical: the same task ordering guarantees and the same cancellation semantics.

## 6. Process startup

### 6.1 VectraOS: the user runtime entry

VectraOS executables are static ELF images ([06](06-linker.md)): `ET_EXEC` at `0x1000000`, or static PIEs that the kernel's program loader or `userboot` place at a random base. A process starts with one handle, a bootstrap channel whose first message is Zircon's processargs. Execution begins in VectraOS's user runtime (`user/lib/runtime/start.c`, whose `_start` is a few lines of inline assembly per architecture):

```
kernel ProgramLoader / userboot ──► ELF mapped (PIE: relocated, RELRO made read-only)
                          │
                          ▼
                    _start (user runtime)
   1. Clear the frame pointer (and return address), so backtraces end here;
      on RV64 set gp from __global_pointer$ (under .option norelax)
   2. Take the bootstrap channel and the vDSO base from the entry registers
   3. Read the bootstrap message: the process, root-VMAR and startup handles
      (stdout debuglog, resource, …), argv and the environment
   4. Route stdout to the debuglog
   5. Call main(argc, argv)
   6. Flush stdout and exit the process with main's status
```

VectraOS's runtime has a fixed `__stack_chk_guard` and runs no `.init_array`. A Swift-Stack runtime on VectraOS adds both before step 5: initializing the stack protector guard and runtime globals MUST precede any Swift code, and `.init_array` runs after it. VectraOS's runtime does not yet set up an ELF TLS block for the main thread (§7); that comes with the pthreads of its userland (roadmap V2).

### 6.2 POSIX hosts

Hosted executables are dynamically linked against the system C library (§8). Proposed default: link the system's C runtime start files (`crt1.o`/`Scrt1.o`, `crti.o`, `crtn.o` on Linux and FreeBSD; on macOS, `dyld` calls `main` directly via `LC_MAIN`). Swift-Stack's runtime initialization runs from an `.init_array` entry, so the host's libc startup sequence is untouched.

The alternative is shipping Swift-Stack's own `crt` objects for Linux and FreeBSD, which removes the dependency on locating host crt files. This is an open question (§11).

## 7. Thread-local storage

The linker resolves static TLS offsets for executables ([06](06-linker.md)). The runtime sets up the main thread's TLS block (VectraOS user runtime, once it has one) or relies on the system dynamic loader (hosts). Layouts per the ELF TLS ABI:

| Arch | Variant | Thread pointer | Layout |
|---|---|---|---|
| x86-64 | II | `%fs` base (on VectraOS through the kernel, `object_set_property` with `REGISTER_FS` on the thread's own handle; its kernel leaves `CR4.FSGSBASE` off, so `wrfsbase` faults even though FSGSBASE is in the x86-64 floor ([17](17-simd-and-vectorization.md) §5.4)) | `%fs:0` holds the TCB self-pointer. The executable's TLS block sits immediately *below* the thread pointer, at negative offsets. Local-exec access is `mov %fs:-off, %reg`. |
| AArch64 | I | `TPIDR_EL0` | The thread pointer addresses a 16-byte TCB. The executable's TLS block starts at `tp + 16`, rounded up to the block's alignment. Local-exec uses `R_AARCH64_TLSLE_*` relocations. |
| RISC-V 64 | I | `tp` (`x4`) | The thread pointer addresses the start of the executable's TLS block (offset 0). The TCB, if any, lies below `tp`, so there is no gap above it. Local-exec uses `R_RISCV_TPREL_*` relocations. To be verified against the RISC-V ELF psABI for the pinned version. |

Executables use the local-exec model for their own TLS. Hosted executables that reference TLS defined in shared libraries use initial-exec. v1 produces no shared libraries, so general-dynamic is not generated; it appears only in foreign objects, which are handled as described in [06](06-linker.md) §5.5. The Swift runtime uses TLS for the current task, the exclusivity access set, and the current executor.

## 8. C library linkage

| Target | C library | Linkage |
|---|---|---|
| VectraOS | First-party C23 runtime today (`user/lib/runtime`, `lib/rt`); a full libc with its userland (roadmap V2) | Static |
| Linux | glibc (musl: open question) | Dynamic, `/lib64/ld-linux-x86-64.so.2` (x86-64), `/lib/ld-linux-aarch64.so.1`, `/lib/ld-linux-riscv64-lp64d.so.1` |
| FreeBSD | FreeBSD libc / `libthr` | Dynamic, `/libexec/ld-elf.so.1` |
| macOS | `libSystem` | Dynamic only. Static executables are not supported by the platform. |

On VectraOS:

- `malloc`, `free` and `posix_memalign` are the user runtime's size-class heap over 64 KiB VMO chunks in the root VMAR. The Swift runtime's allocator calls them.
- Locks and condition variables are built on futexes: VectraOS keeps `futex_wait` and `futex_wake` and cuts the owner-tracking calls in its V1 audit, so runtime locks use wait and wake only. `pthread_mutex_t` and `pthread_cond_t` arrive with its libc (roadmap V2).

C headers for all targets are parsed by Swift-Stack's own C frontend. Host headers require the GNU/Clang host-header profile (D7, [02](02-semantic-analysis.md)).

## 9. Testing

- Runtime unit tests run on every host backend and on VectraOS (in QEMU, as VectraOS's own suites run).
- The upstream stdlib test executables ([12 §9](12-standard-library-strategy.md)) exercise most runtime families indirectly.
- Executor backends share a conformance suite covering ordering, cancellation, timer accuracy, and wake-from-foreign-thread.
- TLS layout is checked by a test program per architecture that compares `&threadLocal` against `tp + expectedOffset` and against values produced by the host C compiler.

## 10. Alternatives considered

- **Reuse upstream's C++ runtime.** Rejected: Swift-Stack has no C++ frontend (C++ is a non-goal), and D1 frees us from Apple's metadata layout. Upstream remains a behavioural reference.
- **libdispatch-based executor on hosts.** Rejected: it would give the hosts a different scheduling model from VectraOS and adds a large dependency.
- **One reactor thread plus worker pool.** Rejected for the default backends because it adds a hop per event. It may be kept as a debugging backend.

## 11. Open questions

1. Host startup: system crt files or Swift-Stack-provided crt objects on Linux and FreeBSD?
2. musl support on Linux (static hosted executables)?
3. Weak references in Tier 0: follow the upstream Embedded restriction exactly, or allow them with a side-table opt-in?
4. Worker-count policy: fixed to core count, or adaptive with blocking detection?
5. Should the Tier 1 runtime itself be compiled as a Tier 0 module (no metadata dependence) throughout, or only its bootstrap subset?
