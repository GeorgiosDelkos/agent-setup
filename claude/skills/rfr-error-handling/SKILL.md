---
name: rfr-error-handling
description: Use when designing error types for Rust libraries or binaries, choosing between an enumerated and an opaque error, implementing the Error trait, writing Display messages, propagating with ?, or deciding when to panic vs return Result. Use when error handling is inconsistent or error types leak dependencies.
---

# Rust for Rustaceans, Ch 4: Error Handling

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

House rules applied throughout (see `rust-style`): libraries return concrete error types,
written with `thiserror` or by hand (by hand for low-dependency or `no_std` crates).
Binaries may return `Box<dyn Error + Send + Sync>` from `main`. `anyhow` and `eyre` are not
used anywhere. The book's index has no `anyhow` entry; `thiserror` appears only in the
Ch 13 library list (p. 227).

## Enumerated Errors

Source: RfR Ch 4 "Enumeration" (TOC p. 58); RfR Ch 4 index "Error trait" (p. 58)

Use an enum when callers need to react differently to different failures. Each variant is
one documented failure mode, and callers match on it.

```rust
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid header at byte {offset}")]
    InvalidHeader { offset: usize },

    #[error("input ended {missing} bytes early")]
    UnexpectedEof { missing: usize },

    #[error("unsupported version {version}")]
    UnsupportedVersion { version: u8 },
}
```

- Decide `#[non_exhaustive]` per type. Add it when you expect new failure modes and want
  to add variants in a minor release; callers then need a `_` arm. Leave it off, and say
  in the docs that the enum is frozen, when callers benefit from exhaustive matching.
  Adding `#[non_exhaustive]` later is itself a breaking change (Cargo SemVer reference).
- Prefer one error type per operation or module over one crate-wide enum that every
  function returns. A caller should not have to handle variants a function cannot
  produce. (General Rust practice, not from the book.)

## Opaque Errors

Source: RfR Ch 4 "Opaque Errors" (TOC p. 59); RfR Ch 4 index "type-erased errors" (pp. 59-61), "Box<dyn Error> type" (pp. 60-61), "downcasting" (pp. 60-61)

Use an opaque error when callers can do little beyond reporting the failure, or when the
set of causes is an implementation detail you want freedom to change. In a library, keep
the type concrete: a struct with private fields, optionally carrying a type-erased source.

```rust
use std::error::Error as StdError;
use std::fmt;

/// Error returned by [`Store::load`].
#[derive(Debug)]
pub struct LoadError {
    kind: LoadErrorKind,
    source: Option<Box<dyn StdError + Send + Sync + 'static>>,
}

/// What went wrong, for callers that want to branch on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum LoadErrorKind {
    NotFound,
    Corrupt,
}

impl LoadError {
    pub fn kind(&self) -> LoadErrorKind {
        self.kind
    }
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.kind {
            LoadErrorKind::NotFound => f.write_str("record not found"),
            LoadErrorKind::Corrupt => f.write_str("record is corrupt"),
        }
    }
}

impl StdError for LoadError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.source.as_deref().map(|e| e as &(dyn StdError + 'static))
    }
}
```

- The boxed source hides which dependency failed, so a dependency upgrade does not change
  your public API. Callers can still walk `source()` and downcast if they must.
- Do: wrap dependency errors. Avoid: a public variant such as `Database(sqlx::Error)`,
  which makes the dependency's major version part of your API (Towards Impeccable Rust
  lists error types among public-dependency leaks).

### Downcasting

Downcasting needs a `'static` error. Walk the chain with std alone:

```rust
use std::error::Error;
use std::io;

fn is_not_found(err: &(dyn Error + 'static)) -> bool {
    let mut cur = Some(err);
    while let Some(e) = cur {
        if let Some(io) = e.downcast_ref::<io::Error>() {
            return io.kind() == io::ErrorKind::NotFound;
        }
        cur = e.source();
    }
    false
}
```

## The Error Trait and Well-Behaved Error Types

Source: RfR Ch 4 index "Error trait", "Error::source method" (p. 58), "Display trait" (p. 59); Rust API Guidelines C-GOOD-ERR

```rust,ignore
// ignore: shape of the std trait, shown for reference (defined in core::error)
pub trait Error: Debug + Display {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        None
    }
}
```

C-GOOD-ERR, as a checklist:
- Implement `std::error::Error` (or `core::error::Error`, stable since 1.81, in `no_std`).
- Make error types `Send + Sync + 'static`. `Send` and `Sync` let the error cross
  `thread::spawn`, sit in an `Arc`, and be wrapped by `io::Error::new`; `'static` enables
  `downcast_ref`.
- Never use `()` as an error type. Use a unit struct that implements `Error` and
  `Display` (clippy `result_unit_err` flags public `Result<_, ()>`).
- `Display` messages are lowercase, concise, and without trailing punctuation.

### Display and the source chain

Expose the cause through `source()`, not by formatting it into your own message. A
reporter that prints the chain would otherwise print the cause twice.

```rust
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    // Do: describe this layer's operation; the source carries the detail.
    #[error("failed to read config file {path}")]
    Read {
        path: std::path::PathBuf,
        #[source]
        source: std::io::Error,
    },
}
```

```rust
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    // Avoid: the io::Error text appears here and again as the source.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}
```

## Special Error Cases

Source: RfR Ch 4 "Special Error Cases" (TOC p. 61); RfR Ch 4 index "Result type" (pp. 61-62); Rust API Guidelines C-GOOD-ERR

The book has a section on special cases; its text was not available. From the API
Guidelines: a function that can fail in only one uninteresting way still gets a named
error type (a unit struct), not `()`. A function that may legitimately return "nothing"
should say so in its type (`Option<T>`, or `Result<Option<T>, E>` when it can also fail).

## Propagating Errors

Source: RfR Ch 4 "Propagating Errors" (TOC p. 62); RfR Ch 4 index "question mark operator" (pp. 62-65), "From trait", "Into trait" (p. 63)

`expr?` on a `Result` returns early with `Err(From::from(e))`, so any error type with a
`From` impl into the function's error type converts automatically.

```rust
use std::num::ParseIntError;

#[derive(Debug, thiserror::Error)]
pub enum LoadError {
    #[error("failed to read the input file")]
    Read(#[from] std::io::Error),

    #[error("the input is not a number")]
    Parse(#[from] ParseIntError),
}

pub fn load(path: &std::path::Path) -> Result<u64, LoadError> {
    let text = std::fs::read_to_string(path)?; // io::Error -> LoadError::Read
    let n = text.trim().parse()?; // ParseIntError -> LoadError::Parse
    Ok(n)
}
```

- `#[from]` generates both the `From` impl and `source()`. One `From` impl per source
  type; when two variants wrap the same source type, use `#[source]` and `map_err`.
- Add context without anyhow by giving the variant fields for it and converting with
  `map_err`:

```rust
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
#[error("failed to open {path}")]
pub struct OpenError {
    path: PathBuf,
    #[source]
    source: std::io::Error,
}

pub fn open(path: &Path) -> Result<std::fs::File, OpenError> {
    std::fs::File::open(path).map_err(|source| OpenError { path: path.to_owned(), source })
}
```

- In a binary, `main` may erase the type:

```rust
fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port: u16 = "8080".parse()?;
    println!("listening on {port}");
    Ok(())
}
```

- Large error values make every `Result` large. Box big payloads inside the variant
  (clippy `result_large_err`, on by default, flags this).

## When to Panic

Source: general Rust practice (not from the book); Rust API Guidelines C-VALIDATE

Jon's site lists `unwrap`/`expect` guidance as a gap in the book (p. 64) and points to
BurntSushi's "Using unwrap() in Rust is Okay". House rule: library code uses
`expect("<why this cannot fail>")`, not bare `unwrap`.

- Panic for bugs: a broken internal invariant, a violated documented precondition.
- Return `Result` for anything that can happen in production: bad input, missing
  resources, timeouts.
- `debug_assert!` is compiled out of release builds. It is never the only guard in a safe
  function before an operation that is UB when the check fails. Use `assert!`, or make the
  function `unsafe` with a `# Safety` contract and an `_unchecked` name (C-VALIDATE).

```rust
pub struct Buffer {
    data: Vec<u32>,
}

impl Buffer {
    /// Returns the element at `idx`, panicking if it is out of bounds.
    pub fn get(&self, idx: usize) -> u32 {
        self.data[idx]
    }

    /// Returns the element at `idx` without a bounds check.
    ///
    /// # Safety
    ///
    /// 1. `idx` must be less than `self.len()`.
    pub unsafe fn get_unchecked(&self, idx: usize) -> u32 {
        debug_assert!(idx < self.data.len(), "caller broke precondition 1");
        // SAFETY: 1. The caller guarantees `idx < self.data.len()`.
        unsafe { *self.data.get_unchecked(idx) }
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}
```

```rust,compile_fail
// Does not compile: the safe-looking version is rejected because the call is unsafe;
// adding an `unsafe {}` block here would make it compile and be unsound in release builds.
pub struct Buffer {
    data: Vec<u32>,
}

impl Buffer {
    pub fn get_unchecked(&self, idx: usize) -> u32 {
        debug_assert!(idx < self.data.len());
        *self.data.get_unchecked(idx)
    }
}
```

## Quick Reference

Source: summary of the sections above

| Guideline | Rule |
|-----------|------|
| Library errors | Concrete type: enum when callers branch, opaque struct otherwise |
| Binary `main` | May return `Box<dyn Error + Send + Sync>` |
| `#[non_exhaustive]` | Decided per type, documented either way |
| Bounds | `Error + Send + Sync + 'static`; never `()` as the error |
| Display | Lowercase, no trailing punctuation, does not repeat the source |
| Source chain | `#[source]` / `#[from]`, or a hand-written `source()` |
| Dependencies | Never expose a dependency's error type in a public variant |
| Panic | Bugs only; `debug_assert!` never guards soundness |

## Common Mistakes

Source: general Rust practice (not from the book); Rust API Guidelines C-GOOD-ERR

1. **Bare `unwrap()` in library code**: return `Result`, or `expect` with the invariant.
2. **Repeating the source in `Display`**: `#[error("io: {0}")]` plus `#[from]` prints the
   cause twice in a chain report.
3. **Leaking dependency error types** in public variants or `From` impls.
4. **Ignoring an error with `let _ =`** without a comment saying why it is safe to ignore.
   Libraries return errors rather than logging them; at most they emit `warn!` or higher
   through the `tracing`/`log` facade. Binaries decide whether to log.
5. **One crate-wide error enum** that every function returns, so callers handle variants
   that cannot occur.
6. **Error types that are not `Send + Sync`**: they cannot cross `thread::spawn`, be stored
   in an `Arc`, or be wrapped by `io::Error::new` (C-GOOD-ERR). In async code, a `!Send`
   error held across an `.await` also makes the future `!Send`.
