---
name: rfr-designing-interfaces
description: Use when designing or reviewing public Rust APIs - naming, which common traits to implement, wrapper types and Deref, generic vs concrete arguments and returns, borrowed vs owned parameters, fallible or blocking destructors, docs, type-system guidance (newtypes, enums over bools, must_use), builders, and semver hazards (non_exhaustive, trait impls, sealed traits, re-exports, auto traits).
---

# Rust for Rustaceans, Ch 3: Designing Interfaces

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

The book organizes the chapter around four properties: unsurprising, flexible, obvious, and
constrained. It builds on the Rust API Guidelines and RFC 1105 (index p. 38), which this
skill cites by checklist ID.

## Unsurprising: naming

Source: RfR Ch 3 "Naming Practices" (TOC p. 38); Rust API Guidelines C-CONV, C-GETTER, C-ITER, C-ITER-TY, C-WORD-ORDER

| Pattern | Convention | Example |
|---------|-----------|---------|
| Free borrowed-to-borrowed view | `as_*` | `as_str()`, `as_bytes()` |
| Expensive conversion | `to_*` | `to_string()`, `to_vec()` |
| Consuming conversion | `into_*` | `into_bytes()`, `into_inner()` |
| Getter | field name, no `get_` (unless there is one obvious thing to get, like `Cell::get`) | `len()`, `name()` |
| Mutable access | `*_mut` | `get_mut()`, `iter_mut()` |
| Predicate | `is_*`, `has_*`, or a verb like std's `contains_key` | `is_empty()`, `contains_key()` |
| Fallible variant | `try_*` | `try_from()`, `try_lock()` |
| Unchecked variant | `*_unchecked`, `unsafe` if skipping the check can cause UB | `get_unchecked()` |
| Iterators | `iter`/`iter_mut`/`into_iter` returning `Iter`/`IterMut`/`IntoIter` | std collections |
| Error types | consistent word order in the crate | `ParseIntError` |

Follow std's pairings: a type with `len()` also has `is_empty()` (clippy
`len_without_is_empty`); an argument-less `new()` comes with `Default` (clippy
`new_without_default`); a type with `iter()` also implements `IntoIterator for &T`.

## Unsurprising: common traits

Source: RfR Ch 3 "Common Traits for Types" (TOC p. 39); Rust API Guidelines C-COMMON-TRAITS, C-CONV-TRAITS, C-SERDE

Downstream crates cannot add std traits to your types (orphan rule), so implement eagerly:

| Trait | When |
|-------|------|
| `Debug` | every public type; output never empty |
| `Clone`, `Default` | when duplication or an empty value is meaningful |
| `PartialEq`/`Eq`, `Hash` | value types; `Hash` must agree with `Eq` |
| `PartialOrd`/`Ord` | types with a natural order (needed for `BTreeMap` keys, sorting) |
| `Copy` | small plain values only; removing it later is breaking |
| `Display` | user-facing values and errors |
| `From`/`TryFrom`, `AsRef`/`AsMut` | conversions; never implement `Into`/`TryInto` directly |
| `serde` traits | behind a feature named exactly `serde` |
| `Send`/`Sync` | automatic; check they are what you intend (see Hidden contracts) |

## Unsurprising: ergonomic trait implementations

Source: RfR Ch 3 "Ergonomic Trait Implementations" (TOC p. 40); detail: general Rust practice (not from the book)

Generic code often holds `&T` or `Box<T>`, and auto-deref does not apply to trait bounds. If
you define a trait, implement it for `&T`, `&mut T`, and `Box<T>` where `T: Trait`. Do it in
the first release: adding these impls later can conflict with impls downstream wrote for
`&TheirType`.

```rust
pub trait Render {
    fn render(&self) -> String;
}

impl<T: Render + ?Sized> Render for &T {
    fn render(&self) -> String { (**self).render() }
}

impl<T: Render + ?Sized> Render for Box<T> {
    fn render(&self) -> String { (**self).render() }
}
```

## Unsurprising: wrapper types

Source: RfR Ch 3 "Wrapper Types" (TOC p. 40); index "Deref trait" (pp. 40-41), "AsRef trait" (pp. 40-41), "Borrow trait" (p. 41); RfR errata print01-ch03-deref-inheritance.md; Rust API Guidelines C-DEREF; https://doc.rust-lang.org/std/borrow/trait.Borrow.html

- `Deref`/`DerefMut`: only for smart pointers (`Box`, `Arc`, guards) and possibly
  transparent newtypes. Do not use them to emulate inheritance; method resolution through
  `Deref` surprises readers and freezes your API to the target's.
- `AsRef<U>`: a cheap reference conversion, used for flexible arguments.
- `Borrow<U>`: like `AsRef`, but promises that `Eq`, `Ord`, and `Hash` give the same answers
  for the borrowed and owned forms. That is why `HashMap<String, V>::get` accepts `&str`.
  Implement it only when that promise holds.

## Flexible: generic arguments and return types

Source: RfR Ch 3 "Generic Arguments" (TOC p. 43); Rust API Guidelines C-GENERIC, C-STRUCT-BOUNDS, C-NEWTYPE-HIDE; Jon Gjengset, Towards Impeccable Rust (2024)

Do: accept the weakest bound you need.

```rust
use std::path::Path;

pub fn open_config(path: impl AsRef<Path>) -> std::io::Result<String> {
    std::fs::read_to_string(path.as_ref()) // &str, String, PathBuf, &Path all work
}

pub fn total(items: impl IntoIterator<Item = u64>) -> u64 {
    items.into_iter().sum() // Vec, arrays, ranges, iterator chains
}

pub fn set_name(name: impl Into<String>) -> String {
    name.into() // the caller decides whether to allocate
}
```

- Take `&[T]` when you need random access or several passes; take `impl IntoIterator` when
  you only iterate once.
- Each generic parameter is monomorphized per caller type. For large bodies, delegate to a
  non-generic inner function (`rfr-types`).
- Put trait bounds on `impl` blocks, not on struct or enum definitions. Exceptions: `?Sized`,
  bounds needed to name an associated type in a field, and bounds a `Drop` impl requires.
  Adding a bound to a type later is breaking.
- Return types: `impl Trait` hides the concrete type (and lets you change it) but callers
  cannot name or store it easily; a concrete type can be named and can grow extra trait
  impls; a newtype wrapper gives both (C-NEWTYPE-HIDE). Jon's later advice leans to
  `-> impl Trait` over exposing concrete adapter chains. Neither is absolute.

## Flexible: dyn compatibility

Source: RfR Ch 3 "Object Safety" (TOC p. 44); Rust API Guidelines C-OBJECT

Decide up front whether a trait is meant for `dyn` use. If yes, keep it dyn compatible and
fence generic or `Self`-returning methods with `where Self: Sized`. Adding a method that
breaks dyn compatibility later is a major change (Cargo SemVer reference). Rules and
example: `rfr-types`.

## Flexible: borrowed vs owned

Source: RfR Ch 3 "Borrowed vs. Owned" (TOC p. 45); RfR errata print01-ch03-from-utf8-lossy.md; Rust API Guidelines C-CALLER-CONTROL

| Take `&T` when | Take `T` when |
|----------------|---------------|
| you only read it | you store it or consume it |
| the caller keeps using it | you would otherwise clone it inside |

- Taking ownership you then discard forces a clone on callers; borrowing and cloning inside
  hides an allocation the caller could have avoided. Let the caller decide.
- Do not use `Copy` as a bound to mean "cheap".
- Use `Cow` when ownership depends on runtime data:

```rust
use std::borrow::Cow;

fn normalize(s: &str) -> Cow<'_, str> {
    if s.contains(' ') {
        Cow::Owned(s.replace(' ', "_")) // allocate only when needed
    } else {
        Cow::Borrowed(s)
    }
}

assert!(matches!(normalize("a_b"), Cow::Borrowed(_)));
```

## Flexible: fallible and blocking destructors

Source: RfR Ch 3 "Fallible and Blocking Destructors" (TOC p. 46); index "explicit destructors" (p. 46), "ManuallyDrop type" (p. 47); Rust API Guidelines C-DTOR-FAIL, C-DTOR-BLOCK

`Drop` cannot return an error, runs during unwinding (where a panic in it aborts), and runs
on whatever thread drops the value, including async tasks. So:

- Offer an explicit method (`close`, `finish`, `shutdown`) that consumes `self` and returns
  `Result`, and document that callers should use it.
- Keep `Drop` as best-effort cleanup that never panics and does not block for long; it only
  matters if the caller skipped the explicit method.
- To move fields out in the explicit method, wrap them in `Option` or `ManuallyDrop`, or
  record that cleanup already happened.

```rust
use std::fs::File;
use std::io::Write;

pub struct Upload {
    file: Option<File>,
}

impl Upload {
    /// Flushes and syncs the file to disk.
    ///
    /// # Errors
    ///
    /// Returns the I/O error from flushing or syncing.
    pub fn finish(mut self) -> std::io::Result<()> {
        let mut file = self.file.take().expect("file is only taken here or in Drop");
        file.flush()?;
        file.sync_all()
    }
}

impl Drop for Upload {
    fn drop(&mut self) {
        if let Some(mut file) = self.file.take() {
            // Best effort: the caller chose not to call `finish`, so there is no one to
            // report an error to.
            let _ = file.flush();
        }
    }
}
```

## Obvious: documentation

Source: RfR Ch 3 "Documentation" (TOC p. 47); Rust API Guidelines C-CRATE-DOC, C-EXAMPLE, C-QUESTION-MARK, C-FAILURE, C-HIDDEN; Jon Gjengset, Towards Impeccable Rust (2024)

- Every public item has docs. Sections as they apply: `# Examples`, `# Errors` (when it
  returns `Err`), `# Panics`, `# Safety` (on `unsafe fn`, numbered preconditions).
- Examples show why to use an item, and use `?` with a hidden `fn main() -> Result<..>`
  rather than `unwrap`.
- Crate docs include an end-to-end example. Record design decisions and what is
  deliberately missing (an absent `From` impl, an unhandled case).
- Link related items with intra-doc links (`[`Other`]`).
- Hide public-for-technical-reasons items (used by your macros) with `#[doc(hidden)]`, and
  keep internals `pub(crate)`.

## Obvious: type system guidance

Source: RfR Ch 3 "Type System Guidance" (TOC p. 48); index "Booleans" (pp. 48-49), "semantic typing" (pp. 48-49), "#[must_use] attribute" (p. 49), "zero-sized types" (p. 49); Rust API Guidelines C-CUSTOM-TYPE, C-NEWTYPE; Jon Gjengset, Towards Impeccable Rust (2024)

Do: enums instead of bools, newtypes instead of aliases for units and IDs.

```rust
pub enum Compression { None, Gzip }
pub struct AccountId(pub u64);
pub struct Cents(pub u64);

pub fn transfer(from: AccountId, to: AccountId, amount: Cents) { /* ... */ }
pub fn save(data: &[u8], compression: Compression) { /* ... */ }
```

Avoid: `transfer(1, 2, 300)` and `save(data, true)`, where swapped arguments compile.

- Use one enum for arguments that are only valid together, instead of `(bool, Option<_>)`.
- Model unchecked and validated data as two types (a raw config and a resolved config).
- Type state with zero-sized marker types makes call-order mistakes compile errors
  (pattern in `rfr-ecosystem`).
- `#[must_use]` on types where ignoring the value is a bug (guards, futures, builders
  returning `Self`) and on functions whose only effect is the returned value. Do not put a
  bare `#[must_use]` on a function returning `Result`: `Result` is already `#[must_use]`
  and clippy's default `double_must_use` flags it.

```rust
#[must_use = "the lock is released as soon as the guard is dropped"]
pub struct Guard<'a> {
    owner: &'a std::cell::Cell<bool>,
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        self.owner.set(false);
    }
}
```

## Builders

Source: Rust API Guidelines C-BUILDER; general Rust practice (not from the book)

Prefer non-consuming builders: setters take and return `&mut Self`, and `build` takes
`&self`, so the builder supports both one-liners and conditional configuration. Use
consuming (`self -> Self`) setters only when `build` must move owned resources out.

```rust
use std::time::Duration;

#[derive(Debug)]
pub struct Server {
    port: u16,
    timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct ServerBuilder {
    port: u16,
    timeout: Duration,
}

impl ServerBuilder {
    pub fn new(port: u16) -> Self {
        Self { port, timeout: Duration::from_secs(30) }
    }

    pub fn timeout(&mut self, timeout: Duration) -> &mut Self {
        self.timeout = timeout;
        self
    }

    pub fn build(&self) -> Server {
        Server { port: self.port, timeout: self.timeout }
    }
}

let server = ServerBuilder::new(8080).timeout(Duration::from_secs(5)).build();

let mut builder = ServerBuilder::new(9090);
if cfg!(debug_assertions) {
    builder.timeout(Duration::from_secs(60)); // conditional step, no reassignment
}
let other = builder.build();
```

## Constrained: type modifications

Source: RfR Ch 3 "Type Modifications" (TOC p. 50); https://doc.rust-lang.org/cargo/reference/semver.html; Rust API Guidelines C-STRUCT-PRIVATE

- Everything public is a promise. Start private, use `pub(crate)` for internals, and make
  items `pub` only when needed (`unreachable_pub` lint helps).
- Public fields pin the representation. Keep them for passive data (config structs);
  otherwise expose methods. Adding a public field to a struct whose fields are all public
  is a major change; adding a private field is minor only if a private field already exists.
- `#[non_exhaustive]` is a per-type decision, not a default. It forces a wildcard arm on
  enums and blocks struct literals and exhaustive destructuring, in other crates only.
  - Use it when the set will grow: error kinds, protocol variants, passive config structs
    (with `Default`).
  - Leave it off when exhaustive matching is the point (a closed state machine, `Ordering`)
    and say in the docs that the type is frozen.
  - Adding it to an existing type with no private fields is a major change.

```rust
#[derive(Debug, Default)]
#[non_exhaustive]
pub struct Limits {
    pub max_connections: usize,
    pub max_body_bytes: usize,
}
```

## Constrained: trait implementations

Source: RfR Ch 3 "Trait Implementations" (TOC p. 51); index "sealed traits" (pp. 52-53); Rust API Guidelines C-SEALED; https://rust-lang.github.io/rfcs/1105-api-evolution.html; https://doc.rust-lang.org/cargo/reference/semver.html

- Implementing an existing trait for an existing type is a minor change by RFC 1105, but
  can still break callers through method-resolution ambiguity. Removing an impl is major.
  Implementing a fundamental trait (`Sized`, `Fn*`) for an existing type is major.
- Adding a blanket impl to an existing public trait breaks downstream crates that already
  implemented it for their own types.
- Adding a defaulted trait method is possibly breaking (name clashes); adding a method
  without a default is major unless the trait is sealed.
- Seal traits that callers should use but not implement, and say "sealed" in the docs.

```rust
mod private {
    pub trait Sealed {}
}

/// A storage backend.
///
/// This trait is sealed and cannot be implemented outside this crate.
pub trait Backend: private::Sealed {
    fn name(&self) -> &'static str;
}

pub struct Memory;
impl private::Sealed for Memory {}
impl Backend for Memory {
    fn name(&self) -> &'static str { "memory" }
}
```

## Constrained: hidden contracts

Source: RfR Ch 3 "Hidden Contracts" (TOC p. 53); index "re-exports" (pp. 53-54), "semver trick" (p. 54), "autotraits" (pp. 54-55), "hidden items" (p. 55); Rust API Guidelines C-SEND-SYNC, C-STABLE; Jon Gjengset, Towards Impeccable Rust (2024)

- Public dependencies: a dependency type in your public API (argument, return, field,
  re-export, trait impl such as `impl From<dep::Error>`) makes that dependency's major
  version part of yours. Wrap or hide it unless sharing the type is the point. The "semver
  trick" (https://github.com/dtolnay/semver-trick) lets an old major version re-export
  types from the new one so both stay compatible.
- Auto traits are API: a private field change can remove `Send`, `Sync`, or `Unpin` from a
  public type, or from a returned `impl Trait`. Pin them in tests:

```rust
pub struct Client {
    inner: std::sync::Arc<std::sync::Mutex<Vec<u8>>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Client>();
    }
}
```

- `#[doc(hidden)]` items are still public to the compiler. Document that they are exempt
  from semver, or keep them out of the public surface.

## Common mistakes

Source: general Rust practice (not from the book)

1. `Deref` to emulate inheritance; use composition and explicit delegation.
2. Taking `String` or `Vec<T>` when the function only reads; take `&str` or `&[T]`.
3. Bare `#[must_use]` on `Result`-returning functions (`double_must_use`).
4. Reflexive `#[non_exhaustive]` on every enum, or none at all; decide per type.
5. `get_` prefixes on plain getters.
6. Implementing `Into` instead of `From`.
7. `Drop` that panics, blocks, or swallows the only report of a failure that has no
   explicit `close`/`finish` alternative.
8. Leaking a dependency's types through a public signature by accident.
