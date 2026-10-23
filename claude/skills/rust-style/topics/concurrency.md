# Concurrency and atomics (CON)

Read before adding atomics, `Ordering::`, locks, `Condvar`, threads, or loom code. Tags and
IDs as in `../SKILL.md`. For depth: `rfr-concurrency`; for unsafe parts also
`topics/unsafe.md`.

## Design

- **CON-1** Start with the simplest correct design: one lock, or one thread that owns the
  state and a channel. Finer locking or lock-free code needs a benchmark against a good
  single-threaded baseline. [ref: B (Ch 10 "Start simple", COST) C]
- **CON-2** Parallelize across independent units, and keep per-unit work single-threaded
  with its own mutable context; shared configuration is immutable and passed in. [ref: C]
- **CON-3** Use `std::sync::Mutex` (or `parking_lot`) for plain data, even in async code.
  An async mutex only when the guard must live across `.await` (`await_holding_lock` is
  denied). [ref: T]
- **CON-4** Handle types encode the access discipline in their auto traits (a `ReadHandle`
  that is `Send` but not `Sync`, a `Sync` factory that hands out readers), say why in the
  docs, and pin it with compile tests (`topics/testing.md` TST-5). [ref: J]
- **CON-5** CPU-parallel work: scoped threads with bounded channels; drop the main thread's
  channel ends explicitly with a comment, because closing is the completion signal. [ref: J]

## Locks and callbacks

- **CON-6** Never wake, clone or drop a `Waker`, call a user closure, or drop a user `T`
  while holding a lock: that runs arbitrary code. Collect wakers into a batch under the
  lock and wake them after releasing it. When a loop calls user code over owned resources,
  hold a drop guard that cleans up the rest if a call panics, and say so in a comment.
  [ref: T]
- **CON-7** Lock order is documented where two locks are ever held together. [house]
- **CON-8** Poisoning is a decision (PAN-3): internal state whose invariants hold after any
  panic is locked with `unwrap_or_else(PoisonError::into_inner)` (Tokio's shim strips
  poisoning); otherwise `expect` with what panicked. [ref: T]

## Atomics

- **CON-9** Every ordering stronger than `Relaxed` that a protocol or an `unsafe` block
  relies on has a comment naming the load/store pair that creates the happens-before edge,
  even when the other half runs in another function or an earlier call. A `Relaxed` that
  looks suspicious says which other operation provides the synchronization. Every `fence`
  says what reordering it prevents. [ref: J; house: T comments only key points]
- **CON-10** `compare_exchange_weak` inside retry loops, `compare_exchange` for single
  attempts; the failure ordering is chosen separately (never `Release`/`AcqRel`). A plain
  counter needs only `Relaxed`. [ref: B (Ch 10)]
- **CON-11** State packed into one atomic has a named, documented `const` per bit or mask
  ("Once this bit is set, it is never unset."), transitions return `#[must_use]` enums, and
  the snapshot's `Debug` shows decoded flags. [ref: T]
- **CON-12** When porting an algorithm, note every ordering that differs from the source
  at the site, with the reason or the doubt ("NOTE: Folly uses Release, but ..."). [ref: J]
- **CON-13** Separate hot, independently written atomics onto different cache lines
  (`CachePadded`, `#[repr(align(64))]`) or shard them, only when a benchmark shows
  contention. [ref: J B]
- **CON-14** When ThreadSanitizer runs in CI, use an `Acquire` load of the same atomic
  instead of `fence(Acquire)`, with a comment (TSan does not model fences). [ref: T (bytes)]

## Loom

- **CON-15** Route every atomic, lock, `Arc`, and `UnsafeCell` through one shim module
  (`src/loom.rs` or `src/sync.rs`) that re-exports `loom::*` under the loom cfg and `std`
  otherwise. Pick the cfg by where the models live:
  - models in `tests/loom.rs`: `#[cfg(loom)]`, loom in `[target.'cfg(loom)'.dependencies]`
    (Jon's crates);
  - models inside the crate: `#[cfg(all(test, loom))]`, loom a `cfg(loom)`
    dev-dependency, so a dependent building with `--cfg loom` cannot switch your
    internals (Tokio).

  Declare `cfg(loom)` in `unexpected_cfgs` check-cfg. When loom cannot express something,
  the shim holds a compatibility function with a link to the loom issue. [ref: T J]
- **CON-16** `UnsafeCell` is reached only through `with(|ptr| ..)` / `with_mut(|ptr| ..)`
  closures in the shim, so loom sees each access begin and end. [ref: T, loom docs]
- **CON-17** Under loom, shrink capacities and thresholds (with a comment that the logic
  is unchanged), replace spinning with `loom::thread::yield_now()`, and keep real spinning
  behind `not(loom)`. [ref: T J]
- **CON-18** Write a model once behind `fn model(f)` that calls `loom::model(f)` under
  loom and `f()` otherwise, so it also runs (and runs under Miri) in normal CI. Run loom in
  `--release` with `-C debug_assertions` and `LOOM_MAX_PREEMPTIONS=2`; compile the loom
  build on every PR. [ref: T]

## Testing concurrent code

- **CON-19** Lock-free code (atomics that order other memory, or `unsafe` shared state)
  ships with loom models and stress tests and runs under TSan in CI. Code that only uses
  locks and channels needs ordinary tests of its behaviour, plus a stress test when its
  correctness depends on interleavings. [ref: B (Ch 10) J]
- **CON-20** Concurrent tests coordinate through explicit signals (an `AtomicBool`, a
  channel, a `#[cfg(test)]` "is waiting" field). Never retry N times, sleep, or yield a fixed
  number of times: under a loaded scheduler that becomes a flaky failure or a hang.
  [ref: J; house]
