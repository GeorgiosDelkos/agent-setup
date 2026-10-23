# Async (ASY)

Read before adding `async`, `.await`, futures, `Poll`, wakers or Tokio code. Tags and IDs as
in `../SKILL.md`. For depth: `rfr-async-programming`; locks across tasks:
`topics/concurrency.md`.

## Documenting async APIs

- **ASY-1** Every public `async fn`, and every public function returning a future, in a
  *published library* has a `# Cancel safety` section `[check]`. Elsewhere, write one when
  the future is not cancel safe and a caller might race it in `select!`. A future is cancel safe when dropping
  it before completion and creating it again is a no-op. Losing a place in a FIFO queue
  (lock, semaphore, notify) counts as not cancel safe. When it is not, the section says what
  is lost and names the cancel-safe alternative. One-shot operations that nobody races in
  `select!` may say "Not applicable: ..." with the reason. [house: T does this for sync and
  net; J and C do not]
- **ASY-2** State ordering, fairness and queueing guarantees from the moment the future is
  first polled, not from the call: a future does nothing until polled. [ref: T]
- **ASY-3** Future, stream and sink types carry a `#[must_use]` reason. Tokio's strings:

  ```rust
  #[must_use = "futures do nothing unless you `.await` or poll them"]
  #[must_use = "streams do nothing unless polled"]
  ```

  [ref: T]

## Writing async code

- **ASY-4** Never block in async code. CPU-heavy work and blocking I/O go to
  `spawn_blocking` (or a dedicated thread); a library that runs user callbacks runs sync
  ones on `spawn_blocking` and async ones on `spawn`, and reports a callback panic
  (`JoinError`) as a failure, not a crash. [ref: J T]
- **ASY-5** No lock guard across `.await` (`await_holding_lock` is denied). Use
  `tokio::sync::Mutex` only when the guard must cross an await (CON-3). [ref: T]
- **ASY-6** Every spawned task's `JoinHandle` is awaited, stored (or put in a `JoinSet`),
  or its detachment is commented with why it may outlive its spawner. [house: a dropped
  handle hides panics and leaks work]
- **ASY-7** Shutdown is driven by a cancellation token or a user-supplied future raced in
  `select!`, with a bounded grace period for in-flight work. [ref: J (faktory)]
- **ASY-8** Box large futures (`large_futures` is denied). Recursive `async fn` boxes the
  recursive call: `Box::pin(walk(child)).await`. Pin on the stack with `std::pin::pin!`.
  [ref: T B]
- **ASY-9** A stateful client (one connection, many callers) is a cheap `Clone` handle
  holding an `mpsc::Sender` to one task that owns the connection; each request carries a
  `oneshot` reply; a closed channel becomes a "connection lost" error, never a panic; the
  task shuts down when the last handle drops. [ref: J (fantoccini)]

## Hand-written futures and streams

- **ASY-10** `poll` returns `Pending` only after arranging a wake-up through the waker of
  the current `Context` (store the latest waker; spurious polls are allowed). Never poll a
  future again after `Ready` unless it is documented as fused. [ref: B (Ch 8)]
- **ASY-11** Project pins with `pin-project-lite` (or `pin-project`); write `impl Unpin
  for X where Inner: Unpin {}` explicitly when it should depend on the inner type. A
  state-machine `poll` takes the state with `mem::replace` and restores it on `Pending`.
  [ref: T J]
- **ASY-12** A leaf future or stream that can be ready many times in a row (a channel, a
  socket) takes part in Tokio's cooperative budget (`tokio::task::coop`), so one busy
  stream cannot starve its task's siblings. [ref: T]
- **ASY-13** Library extension-trait methods return named, `#[must_use]` future types
  (`ReadU8<'_, Self>`), with the equivalent `async fn` signature shown in the docs, so
  callers can name them and check `Send`. [ref: T]
- **ASY-14** Sync wrappers of async APIs are `blocking_x`, `#[track_caller]`, and documented
  to panic inside a runtime. [ref: T]

## Dependencies and tests

- **ASY-15** Libraries enable only the Tokio features they use (`sync`, `rt`, `time`), each
  with a comment naming the API that needs it; dev-dependencies may take `full`. [ref: J
  (minimal features in 3 of 3 crates); house: the comment, from one J crate]
- **ASY-16** Test futures deterministically: `tokio_test::task::spawn` plus
  `assert_pending!`/`assert_ready!` for step-by-step polling, and paused time
  (`#[tokio::test(start_paused = true)]`) instead of real sleeps. [ref: T]
