---
name: rfr-ecosystem
description: Use when choosing Rust ecosystem tools (cargo-deny, cargo-expand, cargo-hack, cargo-llvm-lines, cargo tree) or well-known libraries, looking for an underused std API, or applying the patterns common in real crates - index pointers, drop guards, extension traits, crate preludes - plus type state, newtypes, builders and custom iterators. Use when keeping up with Rust releases.
---

# Rust for Rustaceans, Ch 13: The Rust Ecosystem

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

The book's Ch 13 surveys tools, libraries and std APIs, then four "patterns in the wild".
The later sections of this skill (type state, newtype, builder, iterators, RAII, `Deref`)
are not from Ch 13; their source lines say where they come from.

## Tools

Source: RfR Ch 13 "Tools" (TOC p. 224); RfR Ch 13 "Rust Tooling" (TOC p. 228); RfR Ch 13 index "cargo-deny", "cargo-expand", "cargo-hack" (p. 224), "cargo-llvm-lines" (pp. 224-225), "cargo-outdated", "cargo-udeps" (p. 225), "cargo tree" (pp. 228-229), "-Zprint-type-sizes", "-Ztimings" (p. 229); RfR errata print01-ch13-cargo-target-dir.md

| Tool | What it answers |
|---|---|
| `cargo deny check` | Advisories, licenses, banned or duplicate dependencies, allowed sources |
| `cargo expand` | What a macro or derive expands to |
| `cargo hack --feature-powerset check` | Does every feature combination build |
| `cargo llvm-lines` | Which generic functions produce the most LLVM IR (compile time, binary size) |
| `cargo outdated` | Which dependencies have newer releases |
| `cargo udeps` (nightly) | Which declared dependencies are unused |
| `cargo tree` (built in) | Why a crate is in the graph: `-i <crate>` inverts, `-d` lists duplicates, `-e features` shows feature edges |
| `cargo build --timings` | Where build time goes, per crate (stable; the book's `-Ztimings` is the old nightly form) |
| `rustc -Zprint-type-sizes` (nightly) | Size and padding of every type, to find large enum variants |
| `rustup` | Toolchains, components (`clippy`, `rustfmt`, `miri`) and cross targets |

To share build artifacts across projects, set `[build] target-dir = "..."` in
`~/.cargo/config.toml` (the errata corrects the book's `[build] target`).

## Libraries

Source: RfR Ch 13 "Libraries" (TOC p. 225); RfR Ch 13 index entries for each library (pp. 225-228)

The crates the book highlights, by need:

| Need | Crate |
|---|---|
| Cheaply cloneable, sliceable byte buffers | `bytes` |
| Statistical benchmarks | `criterion` |
| Safe C++ interop | `cxx` |
| Fast MPMC channels, sync and async | `flume` |
| Latency histograms | `hdrhistogram` |
| Fixed-capacity collections without allocation (`no_std`) | `heapless` |
| Extra iterator adaptors | `itertools` |
| Safe Unix system call wrappers | `nix` |
| Safe pin projections | `pin-project` |
| Cryptographic primitives | `ring` |
| Pre-allocated storage with stable keys | `slab` |
| Compile-time assertions (`assert_impl_all!`) | `static_assertions` |
| Error type derives | `thiserror` |
| Service and middleware abstraction | `tower` |
| Structured, span-aware diagnostics | `tracing` |

`structopt`, also listed, is in maintenance mode: its features moved into `clap` v3 (clap's
derive API). Check maintenance status and advisories before adding any crate.

## The Standard Library

Source: RfR Ch 13 "The Standard Library" (TOC p. 230); RfR Ch 13 index entries for each item (pp. 230-233)

Std APIs the book calls out because they are easy to miss:

| API | Use |
|---|---|
| `std::iter::once(x)` | A one-item iterator to chain onto others |
| `write!` / `writeln!` | Format into any `fmt::Write` or `io::Write` (a `String` too) without an extra allocation |
| `BufReader` / `BufWriter` | Batch small reads and writes to files and sockets |
| `Cow<'_, T>` | Borrow when you can, own only when you must |
| `VecDeque` | Queue with O(1) push and pop at both ends |
| `Arc::make_mut` | Clone-on-write for shared data (clones only if other references exist) |
| `Clone::clone_from` | Clone into an existing value, reusing its allocation |
| `Once` (now also `OnceLock`, `LazyLock`) | One-time initialization |
| `Formatter::debug_struct` etc. | Hand-written `Debug` that matches derived output |
| `Instant::elapsed` | Time since an `Instant` |
| `Option::as_deref` | `Option<String>` to `Option<&str>` |
| `Option::transpose`, `Result::transpose` | Swap `Option<Result<..>>` and `Result<Option<..>>` |
| `Ord::clamp` | Bound a value to a range |
| `Vec::swap_remove` | O(1) removal when order does not matter |
| `std::mem::replace` (and `take`, `swap`) | Move a value out of a `&mut` by leaving another behind |

## Index Pointers

Source: RfR Ch 13 "Index Pointers" (TOC p. 233); RfR Ch 13 index "indexmap library", "petgraph library" (p. 234)

When nodes refer to each other (graphs, trees with parent links, ECS), store them in a
`Vec` and refer to them by index instead of by reference or `Rc<RefCell<_>>`. No lifetimes
tie the nodes together, there is no reference counting, and the borrow checker stays out
of the way. A newtype keeps indices from being mixed up with other integers.

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct NodeId(usize);

#[derive(Debug, Default)]
pub struct Graph {
    nodes: Vec<Node>,
}

#[derive(Debug)]
struct Node {
    value: u32,
    edges: Vec<NodeId>,
}

impl Graph {
    pub fn add(&mut self, value: u32) -> NodeId {
        let id = NodeId(self.nodes.len());
        self.nodes.push(Node { value, edges: Vec::new() });
        id
    }

    pub fn connect(&mut self, from: NodeId, to: NodeId) {
        self.nodes[from.0].edges.push(to);
    }

    pub fn neighbors(&self, id: NodeId) -> impl Iterator<Item = u32> + '_ {
        self.nodes[id.0].edges.iter().map(|e| self.nodes[e.0].value)
    }
}
```

The cost: an index can go stale if items are removed and slots reused. If you remove,
use generational indices, or a crate such as `slab`; `petgraph` and `indexmap` use this
pattern internally.

## Drop Guards

Source: RfR Ch 13 "Drop Guards" (TOC p. 234); RfR errata print01-ch13-lst03-drop.md

A guard is a value whose `Drop` undoes or finishes something, so the cleanup runs on every
exit path: normal return, `?`, and panic unwinding. `MutexGuard` is the std example. The
book's listing guards a flag; the errata fixes its `Drop` to `self.0.store(false, ..)`:

```rust
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug)]
pub struct AlreadyRunning;

/// Clears the "busy" flag when dropped.
struct BusyGuard<'a>(&'a AtomicBool);

impl Drop for BusyGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

pub fn run_once(busy: &AtomicBool, job: impl FnOnce()) -> Result<(), AlreadyRunning> {
    if busy.swap(true, Ordering::Acquire) {
        return Err(AlreadyRunning);
    }
    let _guard = BusyGuard(busy);
    job(); // the flag is cleared even if `job` panics
    Ok(())
}
```

- Bind the guard to a named variable such as `_guard`. `let _ = BusyGuard(busy);` drops it
  immediately.
- A guard is not a safety mechanism: `mem::forget` is safe, so unsafe code must stay sound
  if the guard never runs.
- Panic aborts (`panic = "abort"`) skip guards.

## Extension Traits

Source: RfR Ch 13 "Extension Traits" (TOC p. 236)

Add methods to a type you do not own (or to every type implementing a trait) by defining a
trait and implementing it for that type. Callers bring the methods into scope with `use`.
Ecosystem examples: `itertools::Itertools`, `futures::StreamExt`, `tokio::io::AsyncReadExt`.

```rust
pub trait StrExt {
    /// The longest prefix of at most `max_len` bytes that ends on a char boundary.
    fn truncate_to(&self, max_len: usize) -> &str;
}

impl StrExt for str {
    fn truncate_to(&self, max_len: usize) -> &str {
        if self.len() <= max_len {
            return self;
        }
        let mut end = max_len;
        while !self.is_char_boundary(end) {
            end -= 1;
        }
        &self[..end]
    }
}

/// Adds `.batched(n)` to every iterator through a blanket impl.
pub trait IteratorExt: Iterator + Sized {
    fn batched(self, size: usize) -> Batched<Self> {
        assert!(size > 0, "batch size must be non-zero");
        Batched { inner: self, size }
    }
}

impl<I: Iterator> IteratorExt for I {}

pub struct Batched<I> {
    inner: I,
    size: usize,
}

impl<I: Iterator> Iterator for Batched<I> {
    type Item = Vec<I::Item>;

    fn next(&mut self) -> Option<Self::Item> {
        let batch: Vec<_> = self.inner.by_ref().take(self.size).collect();
        if batch.is_empty() { None } else { Some(batch) }
    }
}
```

- Name the trait `<Type>Ext`.
- Avoid method names that std may add to the type later: an inherent method of the same
  name wins, and your method silently stops being called.
- Seal the trait if downstream crates should not implement it (Ch 3, `rfr-designing-interfaces`).

## Crate Preludes

Source: RfR Ch 13 "Crate Preludes" (TOC p. 236); RfR Ch 13 index "glob imports" (pp. 236-237); Cargo SemVer reference "Minor: adding new public items"

A crate with many extension traits or commonly paired types offers a `prelude` module
for a glob import: `use mycrate::prelude::*;` (as `std::io::prelude`, `rayon::prelude`).

```rust
pub mod prelude {
    //! `use mycrate::prelude::*;` brings the extension traits into scope.
    pub use crate::ext::{IteratorExt, StrExt};
}

pub mod ext {
    pub trait StrExt {}
    pub trait IteratorExt {}
}
```

Keep preludes small, mostly traits. Every name added to a prelude can collide with a name
in a downstream crate that glob-imports it, so additions need the same care as other
possibly-breaking changes.

## Staying Up to Date

Source: RfR Ch 13 "Staying Up to Date" (TOC p. 237); RfR Ch 13 index "Rust blog" (p. 237), "This Week in Rust blog", "Inside Rust blog" (p. 238), "The Edition Guide", "editions", "changelogs" (p. 237)

- Read the release notes on the Rust blog each six-week release; new std APIs and lints
  often replace a dependency or a hand-written helper.
- This Week in Rust for ecosystem news; the Inside Rust blog for what the project teams
  are working on.
- Run Clippy on beta as well as stable to see new lints early.
- Read the changelogs of your dependencies when bumping them.
- When a new edition ships, read the Edition Guide and migrate with `cargo fix --edition`.

## Type State

Source: general Rust practice (not from the book); related: RfR Ch 3 "Type System Guidance" (TOC p. 48)

Encode a state machine in a type parameter so calling a method in the wrong state does not
compile.

```rust
use std::marker::PhantomData;

pub struct Draft;
pub struct Review;
pub struct Published;

pub struct Document<State> {
    content: String,
    _state: PhantomData<State>,
}

impl Document<Draft> {
    pub fn new(content: String) -> Self {
        Self { content, _state: PhantomData }
    }

    pub fn submit(self) -> Document<Review> {
        Document { content: self.content, _state: PhantomData }
    }
}

impl Document<Review> {
    pub fn approve(self) -> Document<Published> {
        Document { content: self.content, _state: PhantomData }
    }

    pub fn reject(self) -> Document<Draft> {
        Document { content: self.content, _state: PhantomData }
    }
}

impl Document<Published> {
    pub fn content(&self) -> &str {
        &self.content
    }
}
```

Use it when transitions are known at compile time and misuse is a real bug. Use an enum
when the state is only known at run time, or when the number of states makes the impls
unwieldy (past five or six states, as a rule of thumb, not from the book).

## Newtypes

Source: Rust API Guidelines C-NEWTYPE; Jon Gjengset, Towards Impeccable Rust (2024); general Rust practice (not from Ch 13)

Wrap a primitive to give it a distinct type (`UserId` vs `OrderId`, `Meters` vs `Miles`;
newtypes, not type aliases, which are interchangeable), to enforce an invariant in the
constructor, or to implement a foreign trait for a foreign type.

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct UserId(u64);

/// A `Vec` that always holds at least one element.
#[derive(Debug, Clone)]
pub struct NonEmpty<T>(Vec<T>);

impl<T> NonEmpty<T> {
    pub fn new(first: T) -> Self {
        Self(vec![first])
    }

    pub fn push(&mut self, item: T) {
        self.0.push(item);
    }

    pub fn first(&self) -> &T {
        self.0.first().expect("NonEmpty holds at least one element by construction")
    }
}
```

Derive or forward the traits users need (`Debug`, `Clone`, `PartialEq`, `Hash`, `Display`);
a newtype does not inherit them. Add `#[repr(transparent)]` when the newtype must have the
same layout and ABI as its field (FFI, transmutes).

## Builders

Source: Rust API Guidelines C-BUILDER ("non-consuming builders (preferred)"); general Rust practice (not from Ch 13)

Required values go in `new`; optional ones are `&mut self -> &mut Self` setters, so the
builder works both chained and in conditional code. Use consuming `self -> Self` setters
only when `build` must move owned resources out of the builder.

```rust
use std::time::Duration;

#[derive(Debug)]
pub struct Server {
    host: String,
    port: u16,
    max_connections: usize,
    timeout: Duration,
}

#[derive(Debug, thiserror::Error)]
pub enum BuildError {
    #[error("port must be non-zero")]
    InvalidPort,
}

#[derive(Debug, Clone)]
pub struct ServerBuilder {
    host: String,
    port: u16,
    max_connections: usize,
    timeout: Duration,
}

impl ServerBuilder {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
            max_connections: 100,
            timeout: Duration::from_secs(30),
        }
    }

    pub fn max_connections(&mut self, n: usize) -> &mut Self {
        self.max_connections = n;
        self
    }

    pub fn timeout(&mut self, d: Duration) -> &mut Self {
        self.timeout = d;
        self
    }

    pub fn build(&self) -> Result<Server, BuildError> {
        if self.port == 0 {
            return Err(BuildError::InvalidPort);
        }
        Ok(Server {
            host: self.host.clone(),
            port: self.port,
            max_connections: self.max_connections,
            timeout: self.timeout,
        })
    }
}

fn main() -> Result<(), BuildError> {
    // One-liner:
    let server = ServerBuilder::new("localhost", 8080).max_connections(500).build()?;

    // Conditional configuration needs no reassignment:
    let slow_network = true;
    let mut builder = ServerBuilder::new("localhost", 8081);
    if slow_network {
        builder.timeout(Duration::from_secs(120));
    }
    let other = builder.build()?;
    println!("{server:?} {other:?}");
    Ok(())
}
```

## Custom Iterators and IntoIterator

Source: Rust API Guidelines C-ITER, C-ITER-TY; general Rust practice (not from Ch 13)

A collection with `iter()` also implements `IntoIterator` for `&Collection`, so
`for x in &c` works. Associated types cannot use the anonymous lifetime `'_`; name it:

```rust
pub struct MyCollection<T> {
    items: Vec<T>,
}

impl<T> MyCollection<T> {
    pub fn iter(&self) -> std::slice::Iter<'_, T> {
        self.items.iter()
    }
}

impl<'a, T> IntoIterator for &'a MyCollection<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.items.iter()
    }
}

/// An iterator over Fibonacci numbers that ends instead of overflowing.
pub struct Fibonacci {
    a: u64,
    b: u64,
}

impl Iterator for Fibonacci {
    type Item = u64;

    fn next(&mut self) -> Option<u64> {
        let current = self.a;
        let next = self.a.checked_add(self.b)?;
        self.a = self.b;
        self.b = next;
        Some(current)
    }
}
```

## RAII and Deref

Source: RfR Ch 3 "Fallible and Blocking Destructors" (TOC p. 46); RfR errata print01-ch03-deref-inheritance.md; Rust API Guidelines C-DEREF, C-DTOR-FAIL

- Tie every resource to a value whose `Drop` releases it (files, locks, temp dirs, the
  drop guards above). `Drop` must not fail or block; if teardown can fail, offer an
  explicit `close(self) -> Result<..>` and keep `Drop` best-effort.
- A panic in `Drop` during unwinding aborts the process.
- Implement `Deref` only for smart pointers (`Box`, `Arc`, `MutexGuard`-like types).

Avoid: `Deref` to emulate inheritance. The outer type silently gains every method of the
inner one, including ones that break its invariants.

```rust
pub struct Person {
    name: String,
}

impl Person {
    pub fn name(&self) -> &str {
        &self.name
    }
}

// Do: compose and delegate only what belongs to the outer type.
pub struct Employee {
    person: Person,
    department: String,
}

impl Employee {
    pub fn name(&self) -> &str {
        self.person.name()
    }

    pub fn department(&self) -> &str {
        &self.department
    }
}
```

## Common Mistakes

Source: general Rust practice (not from the book), except where noted

1. **`let _ = guard;`** drops a guard immediately; bind it to `_guard` (Drop Guards).
2. **Safety that relies on a guard's `Drop`**: `mem::forget` is safe.
3. **`Deref` for code reuse**: it is for smart pointers (RfR Ch 3 errata).
4. **Newtypes without the traits users need**: derive or forward them.
5. **Large preludes**: each glob-imported name can collide downstream.
6. **Extension methods named like likely future std methods**: the inherent method wins.
7. **Stale index pointers after removal**: use generational indices or `slab`.
