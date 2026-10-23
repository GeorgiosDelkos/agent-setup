---
name: rust-style
description: Use when writing or reviewing Rust in any repo. House rules distilled from Tokio, Cranelift, Jon Gjengset's crates and Rust for Rustaceans, each tagged with its evidence or its house reason, with stable rule IDs. Core rules here; topic files (unsafe, concurrency, async, library-api, testing, repo) load when an edit touches them. Templates for lints, clippy.toml, deny.toml, crate headers, CI, and prek. Load BEFORE the first Rust edit in a repo.
---

# Rust house style

The bar: code that would pass review in Jon Gjengset's crates (haphazard, left-right), Tokio, or
Cranelift. Order of authority, all under the design principles in `~/.config/agents/AGENTS.md`
(first principles, simplest design, data structures from the access pattern, APIs from the
call site, readable with partial context):

1. House decisions written here.
2. Where Tokio, Cranelift and Jon's crates agree, with *Rust for Rustaceans* and the Rust API
   Guidelines (the `rfr-*` skills).
3. Canonical's *Rust best practices*, only where 1 and 2 say nothing.

## How to read this skill

- **IDs.** Every rule has a stable ID (`ERR-4`). Hooks, the reviewer and commit messages
  name rules by ID.
- **Tags.** `[ref: T C J B]` means the references do this: T Tokio (with bytes, loom), C
  Cranelift (with regalloc2), J Jon Gjengset's crates, B *Rust for Rustaceans* or the API
  Guidelines. `[house: reason]` means the rule is stricter than, or differs from, at least
  one reference, and says why. Evidence for every tag, with file:line in the reference
  repos: the behave-rs research (`research/*.md`, decisions in `research/SYNTHESIS.md`).
- **Ceremony scales with the audience.** Core rules apply to all Rust. Published-library
  rules live in `topics/library-api.md` and in rules marked *published libraries*. A crate
  is published only when its manifest says so (`publish = ["crates-io"]` or `true`, directly
  or through `publish.workspace = true`); a crate without the key is internal.
- **Low-level profile.** A zero-dependency infrastructure crate (a cache, a codec, a
  protocol) sets `low-level = true` under `[package.metadata.house-check]` and follows
  `topics/low-level.md` on top of these rules: zero crates, no panics in library code,
  validated configuration values, std-only tests, a design doc. Its rules win where they
  name a core rule; every other crate keeps the core rules. Reference: `example/reference-crate`.
- **Whose repo.** In a repo that has opted in (`baseline = true` under
  `[workspace.metadata.house-check]`, REPO-1), every rule here applies. In any other repo,
  the repo's existing conventions win over every `[house]` rule: match the surrounding code
  (its error crate, module layout, lint suppressions, clone style). The design principles,
  soundness rules (PAN-5, `topics/unsafe.md`) and `[ref]` rules still apply.

## Topics (hooks force-load these)

Read the topic file before an edit that touches its area. The edit hook blocks until you do.

| Topic | File | Loaded when the edit adds |
|---|---|---|
| Unsafe and FFI | `topics/unsafe.md` | `unsafe`, `extern "C"`, `repr(C)`, raw pointers, `MaybeUninit`, `UnsafeCell` |
| Concurrency | `topics/concurrency.md` | atomics, `Ordering::`, `Mutex`, `RwLock`, `Condvar`, `thread::spawn`, loom |
| Async | `topics/async.md` | `async`, `.await`, `impl Future`, `Poll<`, `Waker`, `tokio::` |
| Library API | `topics/library-api.md` | a `pub` item in a published library crate |
| Testing | `topics/testing.md` | anything under `tests/` or `benches/`, `#[test]`, `#[cfg(test)]` |
| Repo setup | `topics/repo.md` | `Cargo.toml`, `deny.toml`, `clippy.toml`, toolchain files, CI workflows |
| Low-level profile | `topics/low-level.md` | any `.rs` edit in a crate with `low-level = true` under `[package.metadata.house-check]` |

## Machine enforcement (what runs without you)

- **Edit hook**: rustfmt on every `.rs` write (default style, edition from `Cargo.toml`);
  blocks the first Rust edit until this skill is loaded, and each topic edit until its
  topic file is read.
- **Stop hook** (`check-on-stop.sh`): finds what this session changed (files the edit
  tools recorded plus git changes since the session's baseline, so shell edits and commits
  count too) and runs clippy over the changed packages and their workspace dependents with
  the repo's own lint table and `clippy.toml`, plus a minimal set (leftover `dbg!`/`todo!`,
  undocumented `unsafe`). It never injects the house template, so what it checks is what
  `cargo clippy` and CI check; an opted-in repo commits the template (REPO-1) and is told
  when it has not. In an opted-in repo it then runs `house-check` (the line-level rules
  tagged `[check]` below) and the column limit. Compiler errors in the checked packages block; lint and
  house-check findings block only on lines you changed, so touching a legacy file does not
  mean rewriting it. It blocks once per change with the findings.
- **house-check escape**: a finding that is wrong for one line is silenced on that line (or
  the line above) with `// house-check: allow(UNS-SPELL): <reason>`. The reason is
  required; an empty one is itself a finding.
- **Review gate**: once the repo's Rust changes reach 20 lines since the session's baseline
  or since the last review, the main agent runs the `rust-style-reviewer` agent, waits for it to finish, and
  fixes its findings before stopping.
- **Repo layer**: `templates/` holds the lint table, `clippy.toml`, `deny.toml`, the
  library crate header, `ci/` workflows (from `jonhoo/rust-ci-conf` plus house gates) and
  a prek config. `topics/repo.md` says how to adopt them. Never apply them without asking:
  stage, run clippy once, and show the owner the fallout.

Never hand back code that fails `cargo fmt --check` or clippy. Suppress a lint only with
`#[expect(lint, reason = "...")]` (LNT-1).

## Layout and modules (LAY)

- **LAY-1** Modules use `foo.rs` + `foo/`, never `foo/mod.rs` (`mod_module_files`).
  `tests/common/mod.rs` is fine; the lint ignores it. [house: one layout, so a module's
  file is found by its name; T, C and J all use `mod.rs` widely (J: 19 `mod.rs` vs 2
  pairs)]
- **LAY-2** The crate root is the narrative and the API surface: crate docs, lint
  attributes, `mod` declarations, `pub use` re-exports, the central trait or constructor.
  Implementation lives in private modules. [ref: J T]
- **LAY-3** `//!` docs on the crate root (always), on every public module, and on every
  internal module whose invariants span functions (a state machine, ref counting, rules for
  who may touch which field). They state the problem, the design, the invariants, and the
  tradeoffs. Plain helper modules may skip them. [ref: T C J]
- **LAY-4** Imports: one block at the top of the file, absolute `crate::` paths. `use
  super::*` only in test modules; `super::` only from a child into its parent; never
  `super::super` `[check]`. No glob imports except `use super::*` in tests and a variant
  glob inside a function that matches heavily on an enum. Importing variants by name
  (`use std::sync::atomic::Ordering::{Acquire, Release};`) is fine. [ref: T C J]
- **LAY-5** Internals are `pub(crate)` or `pub(super)`; bare `pub` means public API
  (`unreachable_pub`). [ref: T C J]
- **LAY-6** Item order: the type, then its `unsafe impl Send/Sync`, then the inherent
  `impl`, then trait impls (std traits first). Public items before their private helpers.
  [house: a reader finds the safety-relevant impls next to the type]
- **LAY-7** `Debug` first in derive lists, then one consistent order within the crate:
  `Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default`, then third-party
  derives. Optional serde: `#[cfg_attr(feature = "serde", derive(...))]`. [ref: T for
  Debug-first; house: the rest]
- **LAY-8** A declaration sits right above the block that uses it; blank lines separate
  steps, not statements. Group struct fields by role, with a short `//` header per group
  when it helps. [house]
- **LAY-9** Binaries are thin: `main` parses arguments, sets up logging, builds the
  library's options, and calls one library function. A *published* crate that is both
  library and CLI puts CLI-only dependencies behind a `cli` feature and sets
  `required-features` on the `[[bin]]`, so library users never build them; an internal
  crate's binary just depends on what it needs. [ref: J]

## Naming (NAM)

- **NAM-1** One name per concept, the existing pattern copied, consistent word order, no
  type names inside names. If nothing names it well, the design is wrong. [ref: B]
- **NAM-2** Conversions: `as_` (free, borrowed to borrowed), `to_` (expensive), `into_`
  (consuming). Getters have no `get_` prefix unless there is one obvious thing to get
  (`Cell::get`). Iteration: `iter`, `iter_mut`, `into_iter` returning `Iter`, `IterMut`,
  `IntoIter`. [ref: B (APIG C-CONV, C-GETTER, C-ITER)]
- **NAM-3** Variants of an operation use a fixed vocabulary:
  - `try_x`: does not block or panic; returns `Result` or `Option`;
  - `x_unchecked`: skips validation; `unsafe` when skipping can cause UB;
  - `poll_x`: manual `Context` polling;
  - `blocking_x`: sync wrapper of an async API; panics inside a runtime;
  - `x_owned`: takes `Arc<Self>`, returns a `'static` guard;
  - `x_in` / `x_in_domain`: takes an explicit allocator or domain;
  - `get_ref` / `get_mut` / `into_inner` on wrappers.

  [ref: T J B]
- **NAM-4** Generic type parameters are single letters (`Fut` is the accepted exception).
  Write `'_` wherever a lifetime can be elided, including `Formatter<'_>`. A lone lifetime
  is `'a`; several are named after what they borrow (`'rh`, `'domain`). [ref: T J]
- **NAM-5** Error types read verb-object-`Error` (`ParseAddrError`). A payload type takes
  a `Data` suffix (`BlockData`), a bit-packed one `Packed`. [ref: B C]

## Data structures (DAT)

Data structures decide the code (AGENTS principle 3). These make that concrete.

- **DAT-1** Choose collections by access pattern: `Vec` or a slice by default, `HashMap`
  for lookup by key, `BTreeMap` only when order matters. A fast hasher
  (`rustc_hash::FxHashMap`, `foldhash`) for trusted keys, through one crate-level alias,
  only on a measured hot path or when the crate already depends on one. Build a `Vec` and
  sort once rather than keep an ordered structure updated, when the access is a later
  ordered scan. [ref: C J]
- **DAT-2** Graph-shaped data (IR, trees with back edges, caches with cross links) is a
  dense arena indexed by `u32` newtypes, never a web of `Rc`/`RefCell` or references. The
  typed container does not `Deref` to a slice (that would let callers index with a bare
  `usize`). Dense tables store a sentinel (`u32::MAX`) with a packed option; signatures use
  `Option<Index>`. [ref: C B (Ch 13 index pointers)]
- **DAT-3** Newtypes for IDs and units (`struct Meters(u64)`), never type aliases. Enums
  for state. Transition results are enums, not tuples of bools. [ref: B C T]
- **DAT-4** Unchecked input and validated state are two types (`RawConfig` parsed, then
  `Config` resolved), not one struct with validity flags. [ref: B (Jon, *Towards
  Impeccable Rust*)]
- **DAT-5** A type whose size is a performance promise has a test or `const _: () =
  assert!(size_of::<T>() == N);` that says why. Bit-packed layouts are drawn in a doc
  comment on the type. [ref: C T]
- **DAT-6** Hot paths reuse allocations: scratch buffers live in the struct or in a
  reusable `Context` with `clear()`, with a comment that they exist to avoid allocating
  per call. [ref: C J]
- **DAT-7** Owned data and plain functions before `Arc<Mutex<_>>`, trait objects, generics,
  or lifetimes on structs. Each must solve a problem the simpler form cannot. When the set
  of backends is known, an enum beats a trait object. [ref: C J]

## Types and APIs (API)

Library-only rules (semver, `#[non_exhaustive]`, sealed traits, dependency leakage,
auto traits as API) are in `topics/library-api.md`.

- **API-1** No `bool` or `Option` parameter whose meaning is unclear at the call site; use
  an enum. Arguments only valid together become one enum. Optional behaviour is a named
  method (`enable_io()`), not `set_io(bool)`. [ref: B T]
- **API-2** Borrow unless the function stores or consumes the value; let the caller decide
  where copies happen. `impl AsRef<str>`/`impl Into<String>` in argument position for a
  simple parameter used once; `Cow` when ownership depends on runtime state. [ref: B J]
- **API-3** Trait bounds go in `where` clauses on impls and functions, never on type
  definitions, except `?Sized`, a bound `Drop` needs, or an associated type the type uses.
  [ref: B (C-STRUCT-BOUNDS) J C]
- **API-4** Every type implements `Debug`. Write it by hand when deriving would add bounds
  (`impl<T> Debug for Sender<T>` without `T: Debug`) or expose internals; end with
  `finish_non_exhaustive()` when fields are hidden; never print an empty `Debug`; show
  decoded state for packed types. [ref: T J B; house: `finish_non_exhaustive`]
- **API-5** Hand-write `Clone`/`Copy` too when `derive` would add a bound the fields do not
  need. [ref: J]
- **API-6** Builders: `Thing::builder()` or `Builder::new()`; setters `fn x(&mut self, v)
  -> &mut Self`; a flag is an argument-less method; invalid values panic in the setter
  (API misuse, PAN-2) and `build()` is fallible only if building can fail. Use consuming
  `self -> Self` setters only when `build` must move owned resources; those carry
  `#[must_use]`. [ref: B (C-BUILDER) T]
- **API-7** Options structs that are passive data have `pub` fields and a `Default` that
  documents each default on the field. Build them with struct update syntax, `Options { x:
  1, ..Options::default() }`; callers of another crate's `#[non_exhaustive]` options type
  cannot, and use `let mut o = Options::default(); o.x = 1;` (clippy's
  `field_reassign_with_default` flags that form everywhere else). Everything else has
  private fields. [ref: J B]
- **API-8** `#[must_use = "<reason>"]` on futures, streams, guards and values whose use
  is the point; never a bare `#[must_use]` on a type `[check]` or on a fn returning
  `Result` (`double_must_use`). [ref: T]
- **API-9** `Drop` never fails, blocks, or panics. A type whose teardown can fail or block
  offers `close(self) -> Result<..>`; `Drop` does best effort and ignores errors with a
  comment saying why that is benign. [ref: B (C-DTOR-FAIL, C-DTOR-BLOCK) J]
- **API-10** `Deref` only for smart pointers and transparent wrappers, never to emulate
  inheritance. Guard `map`/`try_map` are associated functions, so they do not shadow
  methods of the target. [ref: B J]
- **API-11** Return what the function computed anyway (the old value from an insert,
  `Err(index)` from a search). [ref: B (C-INTERMEDIATE)]
- **API-12** Write `Arc::clone(&x)`, never `x.clone()` (`clone_on_ref_ptr`). [house:
  makes reference-count clones visible; J does it, T does not]
- **API-13** `Self` in signatures and constructors (`use_self`). [house: T and J are mixed]
- **API-14** `#[inline]` only on small cross-crate accessors and on glue called from
  generated code; never on large or generic functions without a benchmark. A large generic
  function converts its arguments and calls a non-generic inner function. [ref: T C B]
- **API-15** No surface without a caller. In an internal crate, every `pub` item, trait
  impl and derive beyond `Debug` has a non-test caller today; add `Clone`, `Default`,
  accessors, conversions and iterator traits when a caller needs them. Tests do not count
  as callers: a test of an otherwise unused item is a test of dead code. A need the task
  states counts as a caller ("errors report the byte offset" justifies `Error::offset()`).
  The converse holds too: never route a real caller through an item to make it look used
  (a one-key lookup that builds a full index); if only a test needs it, leave it out and
  say so. Published libraries follow LIB-10 instead. [house: rules that say "every X has Y"
  otherwise outvote the simplest design]
- **API-16** When correct use takes several steps in order (scan, repair a torn tail, then
  append and sync; validate, then commit), the library offers it as one operation, or makes
  the order a type (a writer built only from the reader's verdict). A getter the caller must
  remember to check before the next step is a finding: the first caller that forgets it
  corrupts data. The binary then just calls that operation (LAY-9). [house: principle 4,
  misuse fails loudly]

## Bindings and control flow (CTL)

- **CTL-1** Shadow through transformations: `let epochs = epochs.lock()...`. [ref: J]
- **CTL-2** `let ... else` for early returns; keep the happy path unindented. [house]
- **CTL-3** Iterator chains by default; loops (labelled ones included) for state machines,
  retries, and anything a chain would obscure. [house]
- **CTL-4** Scope mutability to construction: `let x = { let mut x = X::new(); x.set(..); x
  };`. [house]
- **CTL-5** Never call a method on an expression ending in `}`; bind it with `let` first.
  [house]
- **CTL-6** Inline format arguments: `format!("{path}/{file}")`. [ref: C (lint)]
- **CTL-7** On enums you own, where a new variant must be handled, list every arm. `_ =>`
  is for foreign or `#[non_exhaustive]` enums and intended catch-alls. `..` in struct
  patterns is fine. `matches!` for `is_*` predicates. Do-nothing arms are `=> {}`. [house]
- **CTL-8** Numeric casts say what they mean. Lossless on every target the crate builds
  for: `T::from` where it exists, plain `as` where it does not (`usize` to `u64`), never
  `try_from(..).expect(..)`. Possibly lossy and must fit: `try_from` with the error handled,
  or `expect` stating the invariant that bounds the value. Truncation is the point (hashing,
  bit extraction, table indices): `as` with `#[expect(clippy::cast_possible_truncation,
  reason = "...")]`. Never contort an expression to dodge a lint (`usize::from(x.to_le_bytes()
  [0])` for `x as u8`). Keep values in the wire type (`u64::from(len)` on a `u32` length
  field) and most casts disappear. [house]

## Errors (ERR)

- **ERR-1** Libraries define concrete error types, as `thiserror` derives or hand-written
  `Display` + `Error` impls. Hand-write them in low-dependency and `no_std` crates (`impl
  core::error::Error`), with a comment saying so. Two shapes:
  - a public enum, when callers branch on the variant;
  - an opaque `pub struct Error(Kind)` with `is_*()` predicates, when the variants should
    stay private; a data-less opaque error is `pub struct Elapsed(());`.

  [ref: T C J (hand-written); house decision 2026-10-23]
- **ERR-2** Binaries: `main` may return `anyhow::Result<()>` (or eyre's), `Result<(),
  Box<dyn Error + Send + Sync>>`, the library's error, or `io::Result<()>`. A CLI with more
  than one failure source uses anyhow rather than a hand-rolled error enum nobody matches
  on. Add context
  where an error crosses a layer (`.with_context(|| format!("read {path}"))`), not at every
  `?`. Services map errors to the framework's error
  (`StatusCode`) at the handler, logging the cause there with structured fields (LOG-2).
  `Box<dyn Error>` never appears in library code: not in public signatures (`[check]`),
  and not in private helpers either (review), except as a private `source` field inside a
  concrete error type. [ref: J; house decision]
- **ERR-3** Never `anyhow`, `eyre` or `color-eyre` in library code: not in a library's
  sources `[check]`, nor in a *published* library's normal `[dependencies]` `[check]`.
  Binaries, tests, examples and build scripts may use them (in a published crate through
  dev-, build- or optional `cli` dependencies, LAY-9), because
  nobody matches on a binary's errors and their context chains beat a hand-rolled enum
  there. [house: concrete library types keep failure modes visible to callers; no reference
  library uses them]
- **ERR-4** Error types implement `std::error::Error` (or `core::error::Error`), are `Send
  + Sync + 'static`, and are never `()` (`result_unit_err`). [ref: B (C-GOOD-ERR)]
- **ERR-5** `Display` is a short lowercase phrase with no trailing period that says what
  failed: `"channel closed"`, `"cannot open {path}"`. A wrapping variant either shows the
  source in `Display` or returns it from `source()`, never both; prefer `source()` plus a
  short context (`"parse URL"`). Implement `source()`, never the deprecated
  `description`/`cause`. [ref: T B; house: lowercase, which J and C are split on]
- **ERR-6** Name the alias next to the error: `pub type Result<T> = std::result::Result<T,
  Error>;`, or `CodegenResult<T>` when it must not shadow `Result`. [ref: C]
- **ERR-7** Struct-like variants name and document their fields. Data every variant
  carries (a key, a line number) gets an accessor when a caller needs it without matching
  (API-15). [ref: J]
- **ERR-8** An operation that hands the input back on failure returns a named error that
  wraps it (`SendError<T>(pub T)`, `TryInsertError { current, not_inserted }`) with
  `Display`, `Error` and `into_inner()`. A bare `Result<(), T>` only where the signature
  mirrors std (atomics' `compare_exchange`). [ref: T J]
- **ERR-9** Convert errors at the call site with `map_err` or `#[from]`. Context added
  higher up does not repeat lower-level detail. An error that must travel through an I/O
  interface (returned from a `Read`/`Write` impl, or to a caller that only takes
  `io::Error`) implements `From<E> for io::Error` with the closest `ErrorKind`; otherwise
  skip it (API-15). [ref: T]
- **ERR-10** A validation pass collects every error with its location (fatal stops,
  non-fatal continues) instead of failing on the first. [ref: C]

## Panics and assertions (PAN)

- **PAN-1** Runtime failures and bad user data return `Result`. A CLI never panics on an
  unreadable file or bad input. [ref: T C J]
- **PAN-2** A public API called wrongly may panic with `assert!` and a message naming the
  violated requirement, documented in a `# Panics` section. Misconfiguration panics say how
  to fix it ("call `enable_io` on the runtime builder"). *Published libraries* also put
  `#[track_caller]` on the public function and on every internal function between it and
  the panic, with a test that the reported location is the caller's file
  (`topics/testing.md` TST-6). [ref: T]
- **PAN-3** If an invariant guarantees success, `.expect("<why it cannot fail>")`, written
  as the invariant (`"inner is only taken in into_box, which drops self"`). A bare `unwrap`
  is for tests only. A poisoned mutex is handled on purpose: `.lock().unwrap_or_else(
  PoisonError::into_inner)` where the data's invariants hold after any panic, otherwise
  `.expect("<lock> poisoned: <who panicked>")`. [house: T's trailing comments ("as io
  shouldn't ever be None") show the reason belongs in the message]
- **PAN-4** Check internal invariants with `assert!`, or `debug_assert!` on hot paths;
  assert densely. A check that needs more than an expression goes in a
  `#[cfg(debug_assertions)]` function with an empty release twin, so the call site stays
  unconditional. [ref: C T J]
- **PAN-5** `debug_assert!` is never the only guard before an unchecked or `unsafe`
  operation in a safe function. Soundness needs `assert!` or an `unsafe fn` contract.
  [ref: B (C-VALIDATE)]
- **PAN-6** `unreachable!("<the invariant>")`, never bare `[check]`; `expect` messages
  state the invariant, never empty or a placeholder (house-check wants at least four
  characters) `[check]`. [house: T and C mostly omit them; the message is the proof]
- **PAN-7** Panic formatting in hot generic code moves into a `#[cold] fn ...() -> !`.
  [ref: T (bytes)]
- **PAN-8** Allocation failure aborts; it is not a panic and `# Panics` does not list it.
  APIs that must recover offer `try_reserve`-style variants returning an error with the
  requested size. [ref: C for `try_` variants; house: the `# Panics` wording]

## Docs and comments (DOC)

- **DOC-1** Every public item is documented (`missing_docs`). The first line is a
  third-person summary of at most two lines ("Returns the number of ..."). Under the house
  lints `missing_docs` also covers every crate root, so `main.rs`, each integration test
  file and each example start with a one-line `//!`. [ref: T C J]
- **DOC-2** Sections, as they apply: `# Examples`, `# Errors`, `# Panics`, `# Safety`
  (numbered, `topics/unsafe.md`), `# Cancel safety` (`topics/async.md`), `# Implementer
  notes` (what a trait expects from implementations). [ref: T]
- **DOC-3** In *published libraries*, every public API has a doc test written as a user of
  the public facade; elsewhere, add one where an example says more than the prose. Examples
  use `?` with a hidden `# fn main() -> Result<(), Box<dyn std::error::Error>>` wrapper, or
  end with a hidden `# Ok::<(), Box<dyn std::error::Error>>(())`, not `unwrap`. `no_run` for network or long-running examples, `should_panic` to demonstrate a
  panic, `compile_fail,E0277`-style (with the error code `[check]`) for misuse, `ignore`
  only for pseudo-signatures. [ref: T J B (C-QUESTION-MARK); house: error code]
- **DOC-4** Intra-doc links (``[`Sender::send`]``), checked as errors. An import that
  exists only for a link is `#[cfg(doc)] use ...;`. [ref: J]
- **DOC-5** Comments say why: invariants, orderings, why this is correct, why not the
  obvious alternative, which alternatives were rejected and which downsides accepted. Say
  what is deliberately not there (a missing `From` impl, an unhandled corner case). Never
  restate the code. [ref: B (Jon, *Towards Impeccable Rust*) J]
- **DOC-6** Structures with non-trivial invariants state them once (module docs or an `#
  Invariants` section on the type); each mutating method that relies on them argues they
  still hold in a `// Post-invariant:` comment. [ref: C T]
- **DOC-7** Every claim in a comment or doc is true and checkable. "Cannot overflow" comes
  with the bound that proves it. A claim about a dependency cites its docs. Reliance on
  undocumented behaviour says so and is pinned by a test. Every workaround links the
  upstream issue. [ref: J; house: checkable]
- **DOC-8** A tuned constant says how it was chosen and how to re-measure it. [ref: J]
- **DOC-9** Private fields are documented when they carry an invariant, a unit, or a role
  in a protocol. [ref: J; T documents about half]
- **DOC-10** `TODO`/`FIXME`/`XXX`/`HACK` take a tracker: `TODO(#123)`, `TODO(<url>)`, or
  `TODO(MSRV 1.85): switch to try_update` `[check]`. Never commit `todo!()` or
  `unimplemented!()` (lints). [house: T C J leave most untracked; an untracked TODO never
  gets done]
- **DOC-11** Rule IDs (`ERR-3`) go in reviews and commit messages, never in code comments:
  a comment states the reason itself `[check]`. [house: the reader of the code has no
  skill loaded]
- **DOC-12** `Debug` and `Display` of a type that holds user data (map contents, payloads,
  credentials, paths, headers) print sizes, kinds, counters and cursors, never the data; the
  module or type docs say so. Error messages follow the same rule: `"key too large: 70000
  bytes (limit 65536)"`, not the key. [house: logs leak what `Debug` prints]
- **DOC-13** Docs say what a call does not do and what it costs, wherever a reader would
  otherwise guess: which lock it takes, whether it allocates, blocks, waits on the network or
  runs user code ("Does not publish. It does not wait on the network."). [house]

## Logging and output (LOG)

- **LOG-1** Libraries never print and never install a logger or subscriber. They may emit
  `tracing` or `log` events at `warn` and above for recoverable bad input. Hot-path `trace!`
  and `debug!` go behind a feature or a crate-local macro that compiles to nothing when off.
  [ref: C T J]
- **LOG-2** Services use `tracing` with `tracing_subscriber` and an `EnvFilter`. Events carry
  structured fields (`%request_id`, `error = %e`) and pick the level by blame: `warn` when the
  client is at fault, `error` when a backend failed. [ref: J]
- **LOG-3** A CLI prints from `main` or one output function, with `println!`/`eprintln!`
  under a reasoned `#[expect(clippy::print_stdout, clippy::print_stderr, ...)]` on that
  function; never `drop(writeln!(io::stderr(), ..))` to dodge the lint. `-v`/`-q` set the
  default filter; `RUST_LOG` still overrides it. [ref: J]
- **LOG-4** Before panicking on an internal failure, log the input that triggered it at
  `error` level when it is not huge. [ref: C]

## Lint suppression (LNT)

- **LNT-1** Suppress a lint only with `#[expect(lint, reason = "...")]`, on the smallest
  item, so the suppression fails once it is stale (`allow_attributes` flags `#[allow]`).
  Where the lint fires only under some cfg, make the expectation conditional too:
  `#[cfg_attr(not(feature = "x"), expect(dead_code, reason = "..."))]`. A whole module
  that is nothing but unsafe plumbing may take `#![expect(unsafe_op_in_unsafe_fn, reason =
  "...")]`. [ref: C; house: T and J never use `reason =` (T sometimes comments)]

## Tests, briefly (TST)

Details in `topics/testing.md`.

- **TST-1** Behaviour changes come with tests, including a test for each error variant the
  code documents. [ref: B T]
- **TST-2** Unit tests: `#[cfg(test)] mod tests { use super::*; }` at the bottom of the
  file, or `#[cfg(test)] mod tests;` pointing at a file. Behaviour across the API: `tests/`.
  [ref: C J T]
- **TST-3** `#[test]` functions may `unwrap`. Helpers in `tests/` use `expect("<why>")`.
  [house: clippy's test exemption does not cover helpers]

## Exemplars

An invariant-stating `expect` (left-right `src/write.rs`):

```rust
.expect("inner is only taken in `into_box` which drops self")
```

A misuse panic, documented and tracked (Tokio `sync/mpsc/bounded.rs`):

```rust
/// # Panics
///
/// Panics if the buffer capacity is 0, or too large. Currently the maximum
/// capacity is [`Semaphore::MAX_PERMITS`].
#[track_caller]
pub fn channel<T>(buffer: usize) -> (Sender<T>, Receiver<T>) {
    assert!(buffer > 0, "mpsc bounded channel requires buffer > 0");
```

An opaque error with predicates (Tokio `time/error.rs`):

```rust
pub struct Error(Kind);

impl Error {
    pub fn is_shutdown(&self) -> bool {
        matches!(self.0, Kind::Shutdown)
    }
}
```

A newtype entity index and a size pin (Cranelift `ir/entities.rs`, `ir/instructions.rs`):

```rust
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Block(u32);
entity_impl!(Block, "block");

#[test]
fn inst_data_size() {
    // The size of `InstructionData` is performance sensitive, so make sure
    // we don't regress it unintentionally.
    assert_eq!(core::mem::size_of::<InstructionData>(), 16);
}
```

A `Debug` that shows decoded state (Tokio `runtime/task/state.rs`):

```rust
fmt.debug_struct("Snapshot")
    .field("is_running", &self.is_running())
    .field("is_complete", &self.is_complete())
    // ... (four more state flags)
    .field("ref_count", &self.ref_count())
    .finish()
```

A reason that belongs in the source, not in a reviewer's head (Cranelift `result.rs`):

```rust
// This is manually implementing Error and Display instead of using thiserror to reduce the amount
// of dependencies used by Cranelift.
impl core::error::Error for CodegenError {
```

### House exemplars

Removed from the published history.

## Deep reference (`rfr-*` = *Rust for Rustaceans*)

Load the matching chapter before non-trivial work:

| Topic | Skill |
|-------|-------|
| Ownership, borrowing, lifetimes, variance, drop order, interior mutability (Ch 1) | `rfr-foundations` |
| Layout, alignment, dispatch, coherence, marker traits (Ch 2) | `rfr-types` |
| Public API design, common traits, hidden contracts, destructors (Ch 3) | `rfr-designing-interfaces` |
| Error representation and propagation (Ch 4) | `rfr-error-handling` |
| Features, workspaces, profiles, MSRV, versioning (Ch 5) | `rfr-project-structure` |
| Test harness, doctests, generation, Miri, Loom, benchmarks (Ch 6) | `rfr-testing` |
| `macro_rules!`, proc macros, hygiene, cost (Ch 7) | `rfr-macros` |
| Futures, poll contract, Pin, wakers, spawn (Ch 8) | `rfr-async-programming` |
| Unsafe: validity, panic safety, drop check, privacy boundary (Ch 9) | `rfr-unsafe-code` |
| Atomics, orderings, sane concurrency, Loom, TSan (Ch 10) | `rfr-concurrency` |
| FFI: `extern`, type matching, allocation ownership, bindgen (Ch 11) | `rfr-ffi` |
| `no_std`: core/alloc, allocator, panic handler, cross-compilation (Ch 12) | `rfr-no-std` |
| Ecosystem: tools, std gems, index pointers, drop guards, preludes (Ch 13) | `rfr-ecosystem` |

Specialists: `rust-dependency-audit` (`cargo deny`, `vet`), `rust-performance`
(flamegraph, criterion).
