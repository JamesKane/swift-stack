# 08. Runtime Systems & Todhchai OS Integration

## 1. Overview

A programming language stack is only as efficient as its runtime layer. In standard Apple/Linux Swift, `libswiftCore` and `libdispatch` are massive, complex C++ and Swift shared libraries that require complex metadata initialization, dynamic protocol witness instantiation, and OS thread pool management.

Swift-Stack designs a **lean, two-tier runtime system** optimized for:
1. **Todhchai OS & croi Microkernel:** Direct capability integration, zero-allocation microkernel paths, port-driven concurrency, and static ELF linking.
2. **POSIX Host Systems:** Minimalist compatibility shims for **FreeBSD**, **Linux**, and **macOS**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       SWIFT-STACK RUNTIME TIERS                             │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ Tier 0: Embedded Swift Runtime       │ Tier 1: Full Swift Runtime           │
│ - Strict zero heap allocation        │ - Value types & standard collections │
│ - Static .rodata type descriptors    │ - croi Port-Driven TaskExecutor      │
│ - Direct libsys / microkernel floor  │ - Concurrency, Actors, Async/Await   │
│ - Drivers, Taisce FS, Compositor     │ - Shell, UI Kit, Developer Tools     │
├──────────────────────────────────────┴──────────────────────────────────────┤
│                       C23 Libc & System Floor ABI                           │
│ - Static ELF startup at 0x1000000 (_start, argv, env, auxv)                │
│ - Thread-Local Storage (PT_TLS variant I/II)                                │
│ - Lightweight futex-based synchronization (Priority Inheritance)            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Tier 0: Embedded Swift Runtime

Tier 0 is designed for kernel-adjacent services, device drivers (NVMe, virtio, GPU), the Taisce filesystem, and real-time audio/compositor engines where heap allocations and nondeterministic pauses are strictly forbidden.

### Invariants of the Tier 0 Runtime

1. **Zero Runtime Heap Allocation:**
   - The runtime never calls `malloc`, `posix_memalign`, or memory allocators during language operations.
   - Dynamic collections (`Set`, `Dictionary`), dynamic existential containers, and key paths are excluded.
   - Arrays are fixed-capacity inline buffers (`InlineArray`) or stack/arena-allocated slices (`Span`).
2. **Statically Synthesized Metadata:**
   - All nominal type descriptors, field offset vectors, and witness tables are generated at compile time as read-only constants in `.rodata`.
   - Zero dynamic runtime type metadata records are created or registered at process startup.
3. **Freestanding Symbol Floor:**
   - Tier 0 requires only a handful of freestanding system primitives provided directly by Todhchai's `libsys`:
     - `memset`, `memcpy`, `memmove` (optimized SIMD/SWAR assembly).
     - `__stack_chk_guard` and `__stack_chk_fail` (stack protector).
     - `arc4random_buf` (cryptographic random entropy from croi CPRNG).
     - Minimal panic/fatal error formatting routines that write directly to the debug port without allocating memory.

---

## 3. Tier 1: Full Swift Runtime & Port Concurrency

Tier 1 provides the complete Swift language environment for user-space applications, shell utilities (Tracker, Deskbar, Terminal), and the high-level UI kit.

### The Port-Driven Concurrency Model (`TaskExecutor`)

In conventional Swift on Darwin or Linux, `_Concurrency` relies on `libdispatch`, creating OS worker threads that sleep on pthread condition variables or futexes.

On Todhchai OS, Swift-Stack implements a native **Port-Driven TaskExecutor**:

```
croi Microkernel
  ├─► Channel IPC Message Arrival
  ├─► Hardware Display VBlank Counter
  ├─► Absolute Monotonic Timer Expiration
  └─► Storage I/O Completion Ring
               │
               ▼  (Delivers packet to process-wide port)
       td_executor_port
               │
               ▼  (Wakes sleeping thread without context switch)
   TaskExecutor Worker Thread
               │
               ▼  (Direct resume of async Task continuation)
        Swift async Task
```

1. **Unified Wait Mechanism:** Worker threads in the concurrency pool sleep directly on `td_executor_port` via croi's `port_wait` system call.
2. **Zero Polling & Zero Idle Wakeups:** A thread wakes only when an actual event packet is queued to the port.
3. **Integrated Timers:** Async sleeps (`Task.sleep(until:)`) submit a timer packet with an absolute deadline directly to the port. When the deadline passes, croi wakes a single worker thread to resume the continuation.

### POSIX Fallback Concurrency

On POSIX host systems (FreeBSD, Linux, macOS), the TaskExecutor architecture maps directly to native OS multiplexing primitives:
- **FreeBSD:** `kqueue` / `kevent` using `EVFILT_READ`, `EVFILT_WRITE`, `EVFILT_TIMER` (with absolute/relative millisecond/nanosecond deadlines), and `EVFILT_USER` for thread wakeups, integrated directly with `libthr` 1:1 threads over `_umtx_op`.
- **Linux:** `epoll` with `timerfd` and `eventfd`.
- **macOS:** `kqueue` with `EVFILT_TIMER` and `EVFILT_USER`.

---

## 4. The System Floor & Process Startup

Every executable built by Swift-Stack starts execution at **the floor** (`system/sys/floor/start.S`), satisfying the exact Todhchai system contract:

```
Firmware / croi Loader ──► Static ELF mapped at 0x1000000
                                    │
                                    ▼
                         _start entry point
                                    │
        ┌───────────────────────────────────────────────────────┐
        │ 1. Align stack pointer to 16 bytes                    │
        │ 2. Unpack processargs (argc, argv, envp, auxv)        │
        │ 3. Initialize Thread-Local Storage (PT_TLS)           │
        │ 4. Run .preinit_array and .init_array constructors    │
        │ 5. Call main(argc, argv, envp)                        │
        │ 6. Run .fini_array and atexit handlers                │
        │ 7. Invoke sys_process_exit(status)                    │
        └───────────────────────────────────────────────────────┘
```

### Thread-Local Storage (TLS) Alignment

- **x86-64 (Variant II):**
  - TLS data is located immediately before the thread pointer (`FS` register points to `tcb.self`).
  - Swift-Stack linker calculates static TLS offsets (`%fs:offset`) directly, ensuring instant access to thread-local variables with zero runtime function calls.
- **AArch64 / RISC-V (Variant I):**
  - Thread pointer (`TP` / `x28` / `x4`) points directly to the TCB, with TLS variables allocated at positive offsets.

---

## 5. C23 Libc Interoperability

Swift-Stack binaries link seamlessly with Todhchai's clean-room C23 Libc:
- Full standard ISO/IEC 9899:2024 C library functions: formatted I/O (`snprintf`), string manipulation, math routines, and memory management.
- Standard memory allocation functions (`malloc`, `free`, `realloc`, `posix_memalign`) are routed to Todhchai's page-backed VMO allocators or arena allocators.
- Threading primitives (`pthread_mutex_t`, `pthread_cond_t`) map directly to croi's priority-inheritance futex system calls (`td_futex_wait`, `td_futex_wake`).
