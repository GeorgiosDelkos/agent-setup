# Low-level, zero-dependency crates (LLV)

Read before editing a crate that sets `low-level = true` under
`[package.metadata.house-check]` (or the workspace table). The edit hook blocks until you do.
Tags and IDs as in `../SKILL.md`.

This profile is for infrastructure where every dependency, panic and allocation is a
decision: a cache, a codec, a protocol, a storage engine. It adds to the core rules; where an
LLV rule names a core rule it replaces, the LLV rule wins in this crate. Every other crate
keeps the core rules.

## Dependencies

- **LLV-1** Zero crates: no `[dependencies]`, `[dev-dependencies]` or
  `[build-dependencies]`, and no feature that pulls one. Small primitives (SHA-1, base64, a
  seeded RNG for tests) live in-tree, each with its provenance and checked against published
  test vectors. CI asserts `cargo tree -e normal|dev|build --all-features` prints only the
  package line. A fuzz harness that needs `libfuzzer-sys` is its own workspace, excluded with
  `[workspace] exclude = ["fuzz"]`. A design that seems to need a crate is redesigned first;
  the design doc records the crates considered and why each was refused.

## Panics

- **LLV-2** Library code never panics: no `unwrap`, `expect`, `panic!` or `unreachable!`
  (`templates/low-level/Cargo.lints.toml` denies or warns on them; tests may, by
  `clippy.toml`). Replaces PAN-2, PAN-3 and PAN-6 in this crate:
  - misuse and misconfiguration return an error from the constructor or `checked()`
    (`ConfigError::ZeroCapacity`), never an `assert!`;
  - an invariant is made a type or a control-flow fact the compiler checks (a slice pattern,
    `let ... else` returning an error, a newtype built only by its validator), not an
    `expect` that states it;
  - a panic in user code (a key's `Hash`, `Eq` or `Clone`) leaves the published state
    intact and poisons the writer: it returns `Error::Poisoned` from every later write
    instead of publishing a half-applied change. Document which state survives.
  - a poisoned `std` lock is recovered on purpose (`Err(poisoned) => poisoned.into_inner()`)
    with a comment saying why the guarded data is still valid.

## API

- **LLV-3** Configuration is a `Copy` value with private fields, built by consuming `const
  fn with_*` setters and validated once by `checked(self) -> Result<Self, ConfigError>`;
  constructors that take it call `checked` themselves. Replaces API-6 in this crate. Private
  fields let a later release add a cap without breaking callers.
- **LLV-4** Pure getters carry a bare `#[must_use]` (`must_use_candidate` stays on); types
  whose drop has an effect carry `#[must_use = "dropping the Writer releases the writer
  claim"]`. Extends API-8.
- **LLV-5** Hot read paths are measured and shaped: the common case is `#[inline]` and
  takes no lock, the slow case is a separate `#[cold] #[inline(never)]` function, and the
  docs say which path takes which lock. Work that can run user code (`Drop` of `K`/`V`)
  happens after the guard is released, with a comment.

## Docs

- **LLV-6** Every claim about concurrency and cost is precise and true: which lock a call
  takes, whether it allocates, whether it waits on the network, and what it is not ("The hit
  path is not wait-free."). Benchmarks back the numbers the README quotes.
- **LLV-7** A `docs/design.md` (`templates/low-level/design.md`) opens with a table (crate,
  dependencies, read path, transport, unsafe, MSRV), then overview, background and prior
  art, goals and non-goals, the wire or storage format, failure modes, and the reason for
  the MSRV. It is updated in the same change as the behaviour it describes.

## Tests

- **LLV-8** Tests use std only. Randomised tests run a seeded in-tree RNG (a small test-only
  module) against a simple model (`BTreeMap`), print the seed on failure, and
  are sized so Miri finishes in seconds. Replaces the proptest and arbtest suggestions of
  TST-7 and TST-8; the libFuzzer targets live in the excluded `fuzz/` workspace. Helpers in
  `tests/` that unwrap take a file-level `#![allow(clippy::expect_used, clippy::panic, reason
  = "...")]`, since clippy's test allowances cover only `#[test]` functions.

## Formatting

- **LLV-9** The crate may keep `templates/low-level/rustfmt.toml`: stable options only
  (edition, `max_width = 100`, import and module reordering, field-init and try shorthand).
  Replaces REPO-1's "no rustfmt.toml" in this crate.

## Exemplars

Written for this topic, not taken from a crate.

A hit that takes no lock, and an outlined miss:

```rust
#[inline]
fn get(&mut self) -> &Snapshot {
    let current = self.shared.version.load(Ordering::Acquire);
    if current != self.seen {
        self.reload(current);
    }
    &self.snapshot
}

/// The reload takes the lock, so it is kept out of line: the common path, a version that
/// has not moved, stays one load and one compare.
#[cold]
#[inline(never)]
fn reload(&mut self, current: u64) {
```

Validation that returns instead of panicking:

```rust
pub const fn checked(self) -> Result<Self, ConfigError> {
    if self.capacity == 0 {
        return Err(ConfigError::ZeroCapacity);
    }
    if self.max_entry_bytes > self.max_total_bytes {
        return Err(ConfigError::EntryAboveTotal {
            entry: self.max_entry_bytes,
            total: self.max_total_bytes,
        });
    }
    Ok(self)
}
```

A panic in user code, turned into a documented state:

```rust
/// A panic in user code interrupted an earlier write.
///
/// A key's `Hash` or `Eq`, or a value's `Clone`, panicked between this writer's checks and
/// its publish. The published data is intact, since a publish either finished or did not
/// start, but the writer's own copy may hold half a change, so it refuses every later
/// write. Drop it and open a new one, which starts from the published data.
Poisoned,
```
