---
name: rfr-async-programming
description: Use when writing async Rust or hand-written futures, reasoning about Future, poll, Waker, Pin/Unpin, executors and reactors, or spawn vs join/select. Use when debugging lost wakeups, pinning errors, blocking in async, cancelled futures, or documenting cancel safety.
---

# Rust for Rustaceans, Ch 8: Asynchronous Programming

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## Why async

Source: RfR Ch 8 "What's the Deal with Asynchrony?" (TOC p. 118); RfR Ch 8 "Standardized Polling" (TOC p. 121)

- Synchronous interfaces block the calling thread until the operation completes (index
  "blocking", p. 118).
- One thread per operation scales poorly: each thread costs a stack and scheduler work.
- Asynchronous (non-blocking) interfaces return immediately and say "not yet". Rust
  standardises that answer as `Future::poll` returning `Poll::Pending`, so any executor can
  drive any future.
- `async fn` returns an `impl Future`; the body does not run until the future is polled
  (usually by `.await`). Forgetting `.await` means the work never happens (the
  `unused_must_use` lint warns, since futures are `#[must_use]`).

## The `Future` trait and async/await

Source: RfR Ch 8 "Ergonomic Futures" (TOC p. 121) and "async/await" (TOC p. 124); https://doc.rust-lang.org/std/future/trait.Future.html

```rust
use std::pin::Pin;
use std::task::{Context, Poll};

// The shape of std::future::Future (redeclared here to show it).
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}
```

- The compiler turns each `async fn`/block into a state machine: an enum with one variant
  per `.await` point, holding the locals that live across that point. The book explains
  this through generators (index "generators", pp. 124-126).
- The future's size is the size of its largest state, so big locals held across `.await`
  make every enclosing future bigger.
- `Poll::Ready(v)` ends the future. `Poll::Pending` means "poll me again after a wake".

## Pin and Unpin

Source: RfR Ch 8 "Pin and Unpin" (TOC p. 126); RfR Ch 8 index "stack, pinning to" (pp. 131-132); https://blog.rust-lang.org/2023/03/09/Rust-1.68.0/

- A generated future can hold a reference to its own local (a borrow across `.await`), so
  moving it after the first poll would leave that reference dangling.
- `Pin<P>` (where `P` is a pointer such as `&mut T` or `Box<T>`) promises the pointee is
  not moved again until dropped. `poll` takes `Pin<&mut Self>` so the executor makes that
  promise.
- `Unpin` (an auto trait) means "moving is fine even when pinned". Most types are `Unpin`;
  `async` blocks and `PhantomPinned` are not. For `T: Unpin`, `Pin<&mut T>` behaves like
  `&mut T`.

| Need | Use |
|---|---|
| Pin to the stack | `std::pin::pin!(fut)` (stable since 1.68; no runtime crate needed) |
| Pin on the heap, or store in a collection | `Box::pin(fut)` |
| Project `Pin<&mut Struct>` to its fields | `pin-project` (or `pin-project-lite`) instead of hand-written `unsafe` |

```rust
use std::pin::pin;

async fn work() -> u32 {
    42
}

#[tokio::main]
async fn main() {
    // Do: std::pin::pin! gives `Pin<&mut impl Future>` on the stack.
    let mut fut = pin!(work());
    // `&mut Pin<&mut F>` is itself a future, so it can be polled in a select loop
    // and still be awaited later without moving `fut`.
    tokio::select! {
        v = &mut fut => assert_eq!(v, 42),
        () = tokio::time::sleep(std::time::Duration::from_secs(1)) => {}
    }
}
```

## Going to sleep: leaf futures, executors, reactors

Source: RfR Ch 8 "Going to Sleep" and "Waking Up" (TOC p. 133); RfR Ch 8 index "leaf futures" (pp. 134-135), "executors" (pp. 133, 135), "reactors" (p. 135)

- **Leaf futures** do the actual waiting: a socket read, a timer, a channel receive. They
  are written by hand against a runtime's I/O or timer driver.
- **Executors** own tasks (top-level futures) and poll them when woken.
- **Reactors** watch the OS (epoll, kqueue, IOCP) or timers, and call the stored `Waker`
  when a leaf future's event fires.
- Everything else (`async fn`, combinators) only forwards `poll` down to leaves.

## The poll contract

Source: RfR Ch 8 "Fulfilling the Poll Contract" (TOC p. 134) and "Waking Is a Misnomer" (TOC p. 136); RfR Ch 8 index "fused futures" (p. 121); https://doc.rust-lang.org/std/future/trait.Future.html

Rules a hand-written `poll` must keep (the std docs are the authority):

1. **Before returning `Pending`, arrange a wake** through the waker of the `Context` passed
   to *this* call. The docs: on multiple calls, only the waker from the most recent call
   should receive the wakeup. Replace a stored waker unless `will_wake` says it is the
   same task.
2. **A poll is not a promise of progress.** After a wake the future may still be
   `Pending`, and executors may poll without any wake. Re-check the condition every time.
   "Waking" only means "schedule a poll"; nothing resumes on its own.
3. **Do not poll after `Ready`.** The trait places no requirement on what happens: it may
   panic or block forever, but must not cause UB. A *fused* future is one that is safe to
   poll after completion and keeps returning `Pending` (`futures::future::FusedFuture`,
   `.fuse()`); `select!` loops in the `futures` crate need them.
4. **Never block in `poll`.** Return `Pending` and let the reactor wake you.

```rust
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

#[derive(Default)]
struct Shared {
    done: bool,
    waker: Option<Waker>,
}

/// Completes once `Signal::fire` is called. A minimal leaf future.
pub struct Wait(Arc<Mutex<Shared>>);

/// The handle a reactor (here: any thread) uses to complete a `Wait`.
pub struct Signal(Arc<Mutex<Shared>>);

pub fn pair() -> (Wait, Signal) {
    let shared = Arc::new(Mutex::new(Shared::default()));
    (Wait(Arc::clone(&shared)), Signal(shared))
}

impl Future for Wait {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut s = self.0.lock().expect("Signal never panics while holding the lock");
        if s.done {
            return Poll::Ready(());
        }
        // Rule 1: keep the waker from the latest poll; the task may have moved.
        match &mut s.waker {
            Some(w) if w.will_wake(cx.waker()) => {}
            slot => *slot = Some(cx.waker().clone()),
        }
        Poll::Pending
    }
}

impl Signal {
    pub fn fire(self) {
        let waker = {
            let mut s = self.0.lock().expect("Wait never panics while holding the lock");
            s.done = true;
            s.waker.take()
        };
        // Wake outside the lock: the woken task may be polled on another thread at once.
        if let Some(w) = waker {
            w.wake();
        }
    }
}

#[tokio::main]
async fn main() {
    let (wait, signal) = pair();
    std::thread::spawn(move || signal.fire());
    wait.await;
}
```

## Tasks and subexecutors

Source: RfR Ch 8 "Tasks and Subexecutors" (TOC p. 136); RfR Ch 8 index "selects" (p. 137)

- A **task** is a top-level future the executor polls. `join!`, `select!`,
  `FuturesUnordered` and `JoinSet::join_next` are *subexecutors*: they poll several child
  futures inside one task.
- Children of a subexecutor run concurrently but **not in parallel**: one thread polls the
  whole task. A CPU-heavy child stalls its siblings.
- `select!` drops the futures of the branches that lose. That is cancellation (below).

```rust
async fn users() -> Vec<String> {
    vec!["ann".into()]
}
async fn posts() -> Vec<String> {
    Vec::new()
}

#[tokio::main]
async fn main() {
    // Both futures make progress within this one task.
    let (u, p) = tokio::join!(users(), posts());
    assert_eq!((u.len(), p.len()), (1, 0));
}
```

## spawn

Source: RfR Ch 8 "Tying It All Together with spawn" (TOC p. 138); https://docs.rs/tokio/latest/tokio/task/

- `tokio::spawn` hands a future to the executor as a **new task**. On a multi-threaded
  runtime, tasks run in parallel on different worker threads; that is why spawning, not
  `join!`, is how async code uses more than one core. The future must be `Send + 'static`.
- `spawn_blocking` moves blocking or CPU-heavy synchronous code onto a separate thread pool
  so it does not stall a worker thread.
- Keep the handles. Dropping a `JoinHandle` detaches the task; its panics and errors are
  then lost. `JoinSet` collects many handles and aborts the remaining tasks when dropped
  (general practice, not from the book).

| | `tokio::spawn` | `tokio::task::spawn_blocking` |
|---|---|---|
| Takes | a `Future + Send + 'static` | a `FnOnce + Send + 'static` closure |
| Runs on | async worker threads | a separate, growable blocking pool |
| Use for | I/O-bound async work, parallelism across tasks | blocking syscalls, sync libraries, CPU-heavy work |
| Cancel | `abort()` cancels at the next `.await` | cannot be aborted once started |

```rust
use tokio::task::JoinSet;

async fn fetch(id: u32) -> Result<u32, std::io::Error> {
    Ok(id * 2)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut set = JoinSet::new();
    for id in 0..4 {
        set.spawn(fetch(id));
    }
    // Outer `?`: the task panicked or was aborted. Inner `?`: the task's own error.
    while let Some(res) = set.join_next().await {
        let v = res??;
        assert!(v % 2 == 0);
    }

    let text = tokio::task::spawn_blocking(|| std::fs::read_to_string("Cargo.toml")).await?;
    let _ = text; // an Err here just means the file is missing
    Ok(())
}
```

## Cancellation and cancel safety

Source: general Rust practice (not from the book); house rule: `# Cancel safety` docs (rust-style, from Tokio)

- Dropping a future cancels it at the `.await` where it last stopped. Nothing after that
  point runs, and its locals are dropped.
- A future is **cancel safe** if dropping it before completion loses no data and leaves no
  half-done state, so it can be re-created in a `select!` loop. Example: `mpsc::Receiver::recv`
  is cancel safe; `AsyncReadExt::read_exact` is not (bytes already read are lost).
- Every public `async fn` or future-returning fn in a library documents this under
  `# Cancel safety` (one-shot calls may say "Not applicable").
- For cooperative shutdown, pass a `tokio_util::sync::CancellationToken` or a channel and
  `select!` on it, rather than aborting mid-operation.

```rust
use tokio::sync::mpsc;

/// Receives the next batch of up to `max` messages.
///
/// # Cancel safety
///
/// This method is cancel safe. If it is dropped before it completes, no message has been
/// removed from the channel.
pub async fn next_batch(rx: &mut mpsc::Receiver<u32>, max: usize) -> Vec<u32> {
    let mut out = Vec::with_capacity(max);
    // `recv_many` is documented as cancel safe; it is the only await point.
    rx.recv_many(&mut out, max).await;
    out
}

fn main() {}
```

## Pitfalls

Source: RfR Ch 8 index "blocking" (pp. 118, 137); https://blog.rust-lang.org/2024/03/21/Rust-1.77.0/; https://blog.rust-lang.org/2023/12/28/Rust-1.75.0/; general Rust practice (not from the book)

**Blocking in async code.** `std::thread::sleep`, `std::fs`, long CPU loops and blocking
locks held for long stall a worker thread and every task queued on it.

```rust
use std::time::Duration;

// Avoid: blocks the worker thread for a second.
async fn bad() {
    std::thread::sleep(Duration::from_secs(1));
}

// Do: async equivalents, or spawn_blocking for sync code.
async fn good() -> std::io::Result<String> {
    tokio::time::sleep(Duration::from_secs(1)).await;
    tokio::fs::read_to_string("Cargo.toml").await
}

fn main() {}
```

**Locks across `.await`.** A `std::sync::MutexGuard` is `!Send`, so holding one across
`.await` makes the future `!Send` and `tokio::spawn` rejects it. Copy what you need and
release the lock first. Use `tokio::sync::Mutex` only when the lock must stay held across
an `.await`; it is slower.

```rust,compile_fail
// Does not compile: the std MutexGuard is held across .await, so the future is not Send.
use std::sync::{Arc, Mutex};

async fn tick() {}

fn spawn_it(m: Arc<Mutex<u32>>) {
    tokio::spawn(async move {
        let mut g = m.lock().expect("no panics while locked");
        tick().await;
        *g += 1;
    });
}
```

```rust
use std::sync::{Arc, Mutex};

async fn tick() {}

fn spawn_it(m: Arc<Mutex<u32>>) {
    tokio::spawn(async move {
        // Do: the guard is dropped at the end of this statement, before the await.
        *m.lock().expect("no panics while locked") += 1;
        tick().await;
    });
}

fn main() {}
```

**`Send` futures.** A future is `Send` only if everything held across an `.await` is
`Send`: watch for `Rc`, `RefCell` borrows, std guards and raw pointers.

**Recursion.** Since Rust 1.77 an `async fn` may call itself if the recursive call goes
through indirection such as `Box::pin`. No `Pin<Box<dyn Future>>` rewrite is needed, and
the function stays `Send` when its body is.

```rust
async fn fib(n: u32) -> u64 {
    match n {
        0 | 1 => 1,
        _ => Box::pin(fib(n - 1)).await + Box::pin(fib(n - 2)).await,
    }
}

#[tokio::main]
async fn main() {
    assert_eq!(fib(10).await, 89);
}
```

**Large futures.** Big arrays or structs held across `.await` inflate every enclosing
future. `Box::pin` the large inner future, or keep big locals out of the live range of an
`.await`. The clippy lint `large_futures` flags them.

**Async functions in traits.** Stable since 1.75 (`async fn` and `-> impl Future` in
traits). Such traits are not dyn-compatible. For `dyn Trait`, return
`Pin<Box<dyn Future<Output = T> + Send + '_>>` by hand or use the `async-trait` crate. A
public trait cannot let callers require `Send` futures from `async fn` methods; declare the
method as `fn call(&self) -> impl Future<Output = T> + Send` when callers need to spawn.

## Streams

Source: RfR errata and updates (https://rust-for-rustaceans.com/#features: streams will likely become `AsyncIterator`); general Rust practice (not from the book)

- A stream is the async counterpart of `Iterator`: `poll_next` returning
  `Poll<Option<Item>>`. Today use `futures::Stream` (with `StreamExt::next`) or
  `tokio-stream`; `core::async_iter::AsyncIterator` is still unstable.

```rust
use futures::stream::{self, StreamExt};

#[tokio::main]
async fn main() {
    let mut s = stream::iter([1, 2, 3]);
    let mut sum = 0;
    while let Some(v) = s.next().await {
        sum += v;
    }
    assert_eq!(sum, 6);
}
```

## Quick reference

Source: summary of the sections above; each row comes from the section that covers it.

| Concept | Key point |
|---|---|
| `async fn` | Returns a future; nothing runs until polled |
| `Pending` | Only after arranging a wake with the latest `Context`'s waker |
| Wake | Means "poll again", not "ready"; polls can be spurious |
| After `Ready` | Do not poll again unless the future is fused |
| `pin!` / `Box::pin` | Stack / heap pinning (`std::pin::pin!` since 1.68) |
| `join!` / `select!` | Concurrency inside one task, no parallelism |
| `spawn` | New task; parallel on a multi-threaded runtime |
| `spawn_blocking` | Blocking or CPU-heavy sync code |
| Drop a future | Cancels it at its last `.await`; document `# Cancel safety` |

## Common mistakes

Source: summary of the sections above; each item comes from the section that covers it.

1. Blocking calls inside async code: use async equivalents or `spawn_blocking`.
2. Holding a std `MutexGuard` (or `RefCell` borrow) across `.await`.
3. Returning `Pending` without storing the current waker, or keeping a stale one.
4. Assuming a wake means the resource is ready.
5. Expecting `join!`/`select!` to use more cores; spawn tasks for parallelism.
6. Dropping `JoinHandle`s and losing task panics and errors.
7. Using non-cancel-safe futures in a `select!` loop, and leaving `# Cancel safety`
   undocumented in library APIs.
8. Using `tokio::pin!` or a `Pin<Box<dyn Future>>` rewrite where `std::pin::pin!` or a
   boxed recursive call is enough.
