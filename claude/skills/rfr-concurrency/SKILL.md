---
name: rfr-concurrency
description: Use when designing concurrent or parallel Rust code, choosing between shared memory, worker pools, actors and channels, reasoning about Send and Sync, atomics, memory orderings, or compare_exchange loops. Use when code has data races, deadlocks, lock contention or false sharing, and when testing concurrent code with stress tests, Loom or ThreadSanitizer.
---

# Rust for Rustaceans, Ch 10: Concurrency (and Parallelism)

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## The trouble with concurrency

Source: RfR Ch 10 "The Trouble with Concurrency" (TOC p. 168), "Correctness" (TOC p. 168), "Performance" (TOC p. 169); RfR Ch 10 index "lock oversharing" (p. 171), "false sharing" (pp. 23, 171), "'Scalability! But at what COST?'" (p. 172)

- **Correctness**: safe Rust rules out data races, but not race conditions (check-then-act
  on separately locked state), deadlocks, or lost wakeups.
- **Performance**: adding threads rarely scales linearly.
  - *Contention*: threads wait on the same lock or cache line.
  - *Lock oversharing*: one lock guards data that is not accessed together, so unrelated
    operations serialise. Split the lock by the data's access pattern.
  - *False sharing*: independent values written by different threads sit on one cache
    line, so the line bounces between cores although no data is shared.
- **Measure against a good single-threaded baseline** (the COST paper the book cites): a
  parallel version is only a win if it beats the best sequential implementation, not
  itself on one thread.

```rust
use std::sync::atomic::{AtomicU64, Ordering};

// Pad per-thread counters onto separate cache lines, only after a benchmark shows
// contention. 128 bytes covers adjacent-line prefetching on common x86_64 and aarch64
// parts (crossbeam_utils::CachePadded uses the same value there).
#[repr(align(128))]
struct Padded(AtomicU64);

fn main() {
    let counters: Vec<Padded> = (0..4).map(|_| Padded(AtomicU64::new(0))).collect();
    std::thread::scope(|s| {
        for c in &counters {
            s.spawn(move || {
                for _ in 0..1000 {
                    c.0.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    let total: u64 = counters.iter().map(|c| c.0.load(Ordering::Relaxed)).sum();
    assert_eq!(total, 4000);
}
```

## Concurrency models

Source: RfR Ch 10 "Concurrency Models" (TOC p. 172), "Shared Memory" (TOC p. 172), "Worker Pools" (TOC p. 173), "Actors" (TOC p. 174); RfR Ch 10 index "work stealing" (p. 173), "connection pools" (p. 174)

| Model | Mechanism | Trade-offs |
|---|---|---|
| Shared memory | `Arc<Mutex<T>>`, `RwLock`, atomics, lock-free structures | Direct and fast when contention is low; correctness rests on locking discipline |
| Worker pool | Fixed threads pull jobs from a shared queue (rayon, work stealing; connection pools) | Bounds thread count; jobs must be independent |
| Actors | One thread or task owns the state; others send it messages over a channel | No shared state to lock; one actor is a serial bottleneck, and request-reply cycles can deadlock |

## Asynchrony and parallelism

Source: RfR Ch 10 "Asynchrony and Parallelism" (TOC p. 175)

- Concurrency is about structure (many things in progress); parallelism is about
  execution (many things at the same instant). Async gives concurrency; parallelism needs
  multiple threads, for example `tokio::spawn` on a multi-threaded runtime (see
  `rfr-async-programming`).
- CPU-bound work belongs on threads or a pool (rayon, `spawn_blocking`), not inside async
  tasks.

## Send and Sync

Source: RfR Ch 10 index "Send trait" (pp. 39, 151-153, 205-206), "Sync trait" (pp. 39, 151, 205-206); https://doc.rust-lang.org/std/marker/trait.Sync.html

- `T: Send`: a `T` may be moved to another thread.
- `T: Sync`: a `&T` may be shared between threads. Exactly: `T: Sync` iff `&T: Send`.
- Both are auto traits; they are part of a type's public API (see
  `rfr-designing-interfaces`, hidden contracts).

| Type | Send | Sync | Why |
|---|---|---|---|
| `i32`, `String`, `Vec<T: Send + Sync>` | Yes | Yes | No shared mutable state |
| `Rc<T>` | No | No | Non-atomic reference count |
| `Arc<T>` | if `T: Send + Sync` | if `T: Send + Sync` | Atomic count; `T` is shared |
| `Cell<T>`, `RefCell<T>` | if `T: Send` | No | Unsynchronised interior mutability |
| `Mutex<T>` | if `T: Send` | if `T: Send` | The lock gives exclusive access |
| `RwLock<T>` | if `T: Send` | if `T: Send + Sync` | Readers share `&T` concurrently |
| `MutexGuard<'_, T>` | No | if `T: Sync` | Some platforms require unlock on the locking thread |
| `*const T`, `*mut T` | No | No | Not implemented, as a lint: wrappers must opt in with a SAFETY argument |

Implementing them by hand is an unsafe promise. The `// SAFETY:` comment names what crosses
the thread boundary and why that is fine:

```rust
use std::ptr::NonNull;

/// Owns a heap buffer of bytes allocated in `new` and freed in `drop`.
pub struct Buffer {
    ptr: NonNull<u8>,
    len: usize,
}

impl Buffer {
    pub fn new(len: usize) -> Self {
        let boxed: Box<[u8]> = vec![0; len].into_boxed_slice();
        let ptr = NonNull::from(Box::leak(boxed)).cast::<u8>();
        Self { ptr, len }
    }
}

impl Drop for Buffer {
    fn drop(&mut self) {
        let slice = std::ptr::slice_from_raw_parts_mut(self.ptr.as_ptr(), self.len);
        // SAFETY: `ptr`/`len` came from `Box::leak` of a `Box<[u8]>` of exactly `len`
        // bytes in `new`, and only `drop` frees it, once.
        drop(unsafe { Box::from_raw(slice) });
    }
}

// SAFETY: Buffer uniquely owns its allocation (no other handle to it exists) and holds
// only `u8`s, so moving it to another thread moves sole access with it, as for Box<[u8]>.
unsafe impl Send for Buffer {}

fn main() {
    let b = Buffer::new(8);
    std::thread::spawn(move || drop(b)).join().expect("drop does not panic");
}
```

## Locks

Source: RfR Ch 10 "Shared Memory" (TOC p. 172); RfR Ch 10 index "mutual exclusion" (pp. 170, 185-186); general Rust practice (not from the book)

```rust
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let counter = Arc::new(Mutex::new(0_u64));
    let handles: Vec<_> = (0..4)
        .map(|_| {
            let counter = Arc::clone(&counter);
            thread::spawn(move || {
                // expect: a panic while holding this lock already failed the program.
                *counter.lock().expect("no thread panics while holding the lock") += 1;
            })
        })
        .collect();
    for h in handles {
        h.join().expect("worker threads do not panic");
    }
    assert_eq!(*counter.lock().expect("all workers joined"), 4);
}
```

| | `Mutex<T>` | `RwLock<T>` |
|---|---|---|
| Concurrent readers | No | Yes |
| Cost per lock | Lower | Higher (reader tracking); writers can starve or be starved depending on the platform |
| Use when | Default; short critical sections | Long reads dominate and a benchmark shows `Mutex` contention |

**Deadlocks** come from any cycle of waiting, not only from locks:

1. Acquire locks in one documented global order.
2. Keep critical sections short; copy out what you need and release before slow work or
   before calling unknown code (callbacks, `Drop` of user types).
3. Never hold a lock while blocking on a channel, a join, or another lock you do not order.
4. Channels deadlock too: two actors doing request-reply with each other over bounded
   channels, or a thread waiting on `recv` while it still holds the only `Sender` clone.
5. `try_lock` can break a cycle in a back-off path, but it does not replace an order.

**Poisoning**: if a thread panics while holding a std `Mutex`, later `lock()` calls return
`Err(PoisonError)`. In library code use `expect("<why no panic can happen here>")`, or
`unwrap_or_else(PoisonError::into_inner)` when the protected data stays valid after a
partial update. Never a bare `unwrap()`.

## Channels

Source: general Rust practice (not from the book); https://doc.rust-lang.org/std/sync/mpsc/

| Type | Bounded | When full | Notes |
|---|---|---|---|
| `std::sync::mpsc::channel` | No | Never blocks | Memory grows with a slow consumer |
| `std::sync::mpsc::sync_channel(n)` | Yes | `send` blocks | `n = 0` is a rendezvous channel |
| `crossbeam::channel::bounded(n)` / `flume` | Yes | `send` blocks | Multi-consumer, `select!` |
| `tokio::sync::mpsc` | Yes | `send().await` waits | Async; `unbounded_channel` exists |
| `tokio::sync::oneshot` / `broadcast` / `watch` | 1 / ring / latest | n/a / lagging receivers miss values / overwrite | Reply, fan-out, latest-state |

Prefer bounded channels: they give backpressure instead of unbounded memory growth.

```rust
use std::sync::mpsc;
use std::thread;

fn main() {
    let (tx, rx) = mpsc::sync_channel::<u32>(16);
    let producers: Vec<_> = (0..2)
        .map(|id| {
            let tx = tx.clone();
            thread::spawn(move || tx.send(id).expect("receiver outlives producers"))
        })
        .collect();
    // Drop the original sender, or `rx.iter()` below never ends (a self-inflicted deadlock).
    drop(tx);
    let mut got: Vec<u32> = rx.iter().collect();
    got.sort_unstable();
    assert_eq!(got, [0, 1]);
    for p in producers {
        p.join().expect("producers do not panic");
    }
}
```

## Atomics and memory ordering

Source: RfR Ch 10 "Lower-Level Concurrency" (TOC p. 177), "Memory Operations" (TOC p. 177), "Atomic Types" (TOC p. 178), "Memory Ordering" (TOC p. 178); https://doc.rust-lang.org/std/sync/atomic/

- Atomics make a single memory location safe to access from many threads. The `Ordering`
  says what *other* memory accesses become visible along with it.
- A `Release` store and an `Acquire` load that reads the stored value create a
  happens-before edge: everything the storing thread did before the store is visible to
  the loading thread after the load.

| Ordering | Guarantee | Use |
|---|---|---|
| `Relaxed` | Atomicity of this location only (index p. 180) | Counters, statistics, IDs that publish no other data |
| `Release` (stores) / `Acquire` (loads) | Pair up to form a happens-before edge (index pp. 181-182) | Publishing data behind a flag or pointer; lock implementations |
| `AcqRel` | Both, for read-modify-write ops | RMW that both consumes and publishes (for example a lock-free stack push/pop) |
| `SeqCst` | Acquire/Release plus one total order over all `SeqCst` operations (index pp. 182-184) | Only when correctness needs that global order, such as two threads each storing their own flag then loading the other's |

House rule (rust-style): choose the weakest ordering that is correct and say why in a
comment that names the load/store pair creating the happens-before edge. `SeqCst` "to be
safe" hides which edge the code depends on, and is not a fix for a missing one.

```rust
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread;

static DATA: AtomicU64 = AtomicU64::new(0);
static READY: AtomicBool = AtomicBool::new(false);

fn main() {
    let writer = thread::spawn(|| {
        DATA.store(42, Ordering::Relaxed);
        // Release: pairs with the Acquire load of READY below, publishing the DATA store.
        READY.store(true, Ordering::Release);
    });
    let reader = thread::spawn(|| {
        // Acquire: if this reads `true`, it synchronises with the Release store above, so
        // the earlier Relaxed store of 42 to DATA is visible.
        if READY.load(Ordering::Acquire) {
            assert_eq!(DATA.load(Ordering::Relaxed), 42);
        }
    });
    writer.join().expect("writer does not panic");
    reader.join().expect("reader does not panic");
}
```

## Compare and exchange, and the fetch methods

Source: RfR Ch 10 "Compare and Exchange" (TOC p. 184), "The Fetch Methods" (TOC p. 187); RfR Ch 10 index "success ordering" (p. 186), "failure ordering" (p. 186), "compare_exchange_weak method" (p. 187); RfR errata print01-ch10-conditional-store.md

- `compare_exchange(current, new, success, failure)` stores `new` only if the value is
  `current`, and returns `Ok(previous)` or `Err(actual)`.
- `success` orders the read-modify-write when it stores; `failure` orders the plain load
  when it does not. The failure ordering may only be `SeqCst`, `Acquire`, or `Relaxed`
  (std docs); `Release`/`AcqRel` there panic at run time, and rustc's
  `invalid_atomic_ordering` lint rejects them when they are constants.
- `compare_exchange_weak` may fail spuriously even when the value matches. On LL/SC
  architectures (ARM, RISC-V) the conditional store fails if the location was written at
  all, even with the same value, and the weak form avoids an inner retry loop. Use the
  weak form inside a retry loop, the strong form for a single attempt.
- If a single `fetch_*` method does the job (`fetch_add`, `fetch_or`, `fetch_max`, ...),
  use it: it is one instruction or one loop inside std. `fetch_update` wraps the CAS loop
  for arbitrary updates.

```rust
use std::sync::atomic::{AtomicU64, Ordering};

/// Increments `n` unless it has reached `max`. Returns whether it incremented.
fn increment_below(n: &AtomicU64, max: u64) -> bool {
    // Relaxed throughout: the counter publishes no other memory, so only atomicity of
    // this location matters.
    let mut cur = n.load(Ordering::Relaxed);
    loop {
        if cur >= max {
            return false;
        }
        match n.compare_exchange_weak(cur, cur + 1, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return true,
            // Spurious failure or another thread won: retry with the value we saw.
            Err(actual) => cur = actual,
        }
    }
}

fn main() {
    let n = AtomicU64::new(0);
    assert!(increment_below(&n, 1));
    assert!(!increment_below(&n, 1));
}
```

```rust,compile_fail
// Does not compile: a Release failure ordering is meaningless (the failure path only
// loads), and the deny-by-default `invalid_atomic_ordering` lint rejects it.
use std::sync::atomic::{AtomicU64, Ordering};

fn main() {
    let n = AtomicU64::new(0);
    let _ = n.compare_exchange(0, 1, Ordering::AcqRel, Ordering::Release);
}
```

## Parallel iteration and scoped threads

Source: general Rust practice (not from the book); RfR Ch 10 index "worker pools" (pp. 173-174)

- rayon turns iterator chains into work-stealing parallel loops (`par_iter`, `join`).
  It pays off for CPU-bound work whose per-item cost outweighs task splitting; measure
  against the sequential version. It is not for blocking I/O.
- `std::thread::scope` (1.63) lets threads borrow from the caller's stack: every thread
  spawned in the scope is joined before `scope` returns. The borrowed data must be
  declared *outside* the scope closure.

```rust
use rayon::prelude::*;

fn main() {
    let sum: u64 = (0..10_000_u64).into_par_iter().map(|i| i * i).sum();
    assert_eq!(sum, (0..10_000_u64).map(|i| i * i).sum());

    let data = vec![1, 2, 3];
    let mut total = 0;
    std::thread::scope(|s| {
        s.spawn(|| println!("{data:?}"));
        s.spawn(|| total = data.iter().sum());
    });
    assert_eq!(total, 6);
}
```

## Sane concurrency

Source: RfR Ch 10 "Sane Concurrency" (TOC p. 188), "Start Simple" (TOC p. 188), "Write Stress Tests" (TOC p. 189), "Use Concurrency Testing Tools" (TOC p. 189); RfR Ch 10 index "Loom library" (pp. 97, 190), "ThreadSanitizer" (pp. 190-191), "Heisenbugs" (pp. 191-192); Jon Gjengset, Towards Impeccable Rust (2024)

1. **Start simple.** One lock around the whole state, or one thread that owns the state and
   a channel to it. Move to finer locks or lock-free code only when a benchmark against
   the simple version (and a good single-threaded baseline) shows the need.
2. **Write stress tests.** Many threads, many iterations, randomised interleavings, and
   assertions on invariants after every operation. They find bugs that show up once in a
   million runs, and those bugs (Heisenbugs) tend to disappear under a debugger.
3. **Use concurrency testing tools.**
   - **Loom** runs a test under every distinct interleaving permitted by the C11 memory
     model (bounded), for code that uses `loom::sync` types in place of `std::sync`
     under `cfg(loom)`.
   - **ThreadSanitizer** finds data races at run time in native code, including `unsafe`
     and FFI. Run it when the crate uses atomics or `unsafe`.
   - **Miri** also detects data races and some weak-memory effects in the paths it runs.

```rust
// Under `RUSTFLAGS="--cfg loom" cargo test --release`, the real code would import
// `loom::sync` instead of `std::sync`. Here the test uses loom types directly.
#[test]
fn counter_has_no_lost_updates() {
    use loom::sync::Arc;
    use loom::sync::atomic::{AtomicUsize, Ordering};

    loom::model(|| {
        let n = Arc::new(AtomicUsize::new(0));
        let n2 = Arc::clone(&n);
        let t = loom::thread::spawn(move || {
            n2.fetch_add(1, Ordering::Relaxed);
        });
        n.fetch_add(1, Ordering::Relaxed);
        t.join().expect("loom thread does not panic");
        assert_eq!(n.load(Ordering::Relaxed), 2);
    });
}
```

```bash
# ThreadSanitizer (nightly; std must be rebuilt with the same flag).
RUSTFLAGS="-Zsanitizer=thread" cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
```

## Common mistakes

Source: summary of the sections above; each item comes from the section that covers it.

1. `Rc` or `RefCell` shared across threads: use `Arc` and `Mutex`/`RwLock`/atomics.
2. Holding a lock across slow work, a blocking call, or user callbacks.
3. Assuming channels cannot deadlock.
4. `SeqCst` everywhere instead of a named Acquire/Release pair, or `Relaxed` used to
   publish other data.
5. `compare_exchange` (strong) inside a retry loop, or a CAS loop where a `fetch_*` method
   exists.
6. Unbounded channels with a producer faster than the consumer.
7. Fine-grained locking or lock-free code without a benchmark against the simple version.
8. Concurrent code tested only by ordinary unit tests: add stress tests, Loom, and TSan.
9. `static mut` for shared state: references to it are denied in edition 2024
   (`static_mut_refs`); use atomics, `Mutex`, `OnceLock`, or `LazyLock`.
