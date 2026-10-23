# Published library API (LIB)

Read before adding a `pub` item to a library crate that other crates depend on through a
version. Publishing is opt-in: `publish = ["crates-io"]` (or `true`) in `[package]`, or
`publish.workspace = true` with that in `[workspace.package]`; a crate without the key is
internal. Mark a crate you publish, so the hooks and the reviewer hold it to these rules.
Binaries and internal crates skip this ceremony: plain structs, `pub(crate)`, plain enums (Wasmtime puts "very little effort" into
internal crate APIs). Tags and IDs as in `../SKILL.md`. For depth:
`rfr-designing-interfaces`, `rfr-project-structure`.

## Semver

- **LIB-1** Every public item is a promise. Before adding one, decide whether it may grow
  and what removing it would cost. Run `cargo semver-checks` before a release, and treat it
  as necessary, not sufficient. [ref: B J T]
- **LIB-2** Deprecate, then remove: `#[deprecated(since = "1.4.0", note = "use
  `remove_value`")]` on a forwarding shim, kept until the next major release. A
  deprecated type nobody should name also gets `#[doc(hidden)]`. Patch releases carry only
  fixes and docs; new API, MSRV bumps and deprecations go in minor releases. [ref: T J;
  house decision 2026-10-23 scopes "replace, don't deprecate" to unpublished code]
- **LIB-3** Decide `#[non_exhaustive]` per public enum and struct-like variant:
  - sets that will grow (config, modes, flavors, error kinds that are not matched
    exhaustively): add it;
  - closed sets callers must match completely (a channel's `TrySendError`): leave it off and
    say in the docs that adding a variant is a breaking change.

  0.x crates that break on every release may skip the attribute. [ref: T J C]
- **LIB-4** Struct fields are private unless the type is passive data (API-7); public
  fields are a commitment. A struct is all-public or all-private (`partial_pub_fields`).
  [ref: B (C-STRUCT-PRIVATE)]

## What the API exposes

- **LIB-5** No dependency type in the public API: not in arguments, returns, public fields,
  trait impls (including `impl From<dep::Error>`), or re-exports. Wrap it in a
  `#[repr(transparent)]` newtype with a comment saying why ("so we can bump ahash's major
  version without bumping ours"). Types that are deliberately public go in
  `[package.metadata.cargo_check_external_types] allowed_external_types` and CI runs
  `cargo check-external-types`. [ref: T B J]
- **LIB-6** Complex return types: choose a concrete type, a newtype, or `impl Trait` on
  purpose; never expose an adapter chain. [ref: B (C-NEWTYPE-HIDE)]
- **LIB-7** `#[doc(hidden)]` items are not public API, and the crate docs say so. Items
  public only for macro expansion or the crate's own binaries are `#[doc(hidden)]` with a
  comment saying who uses them. [ref: T J]
- **LIB-8** APIs exempt from semver go behind `--cfg <crate>_unstable` (declared in
  check-cfg), not a Cargo feature, and unstable features must be inert without the cfg.
  [ref: T]
- **LIB-9** A library that runs user callbacks is generic over the user's error type and
  offers blanket impls for closures (`impl<F, Fut> Handler for F where F: Fn(Job) -> Fut`).
  [ref: J]

## Traits on your types

- **LIB-10** Implement common traits eagerly, since the orphan rule stops users from adding
  them: `Debug`, `Clone`, `Default` (with `new()`), `PartialEq`/`Eq`, `Hash`,
  `PartialOrd`/`Ord` where meaningful, `Display` for user-facing types. Collections also
  implement `FromIterator`, `Extend` (owned and `&'a T`), and `IntoIterator` for owned,
  `&` and `&mut`; mirror std's constructors (`with_capacity_and_hasher`) and `Borrow<Q>`
  lookups. [ref: B (C-COMMON-TRAITS) J]
- **LIB-11** Auto traits are API. Every public type and every public future has
  compile-time assertions for `Send`, `Sync`, `Unpin` (or their absence) and unwind safety
  (`topics/testing.md` TST-5). [ref: T J B (C-SEND-SYNC)]

## Traits you define

- **LIB-12** Seal traits that downstream code may use but not implement: `pub trait X:
  sealed::Sealed {}` with `mod sealed { pub trait Sealed {} }` private, and the docs say
  "This trait is sealed and cannot be implemented outside this crate." [ref: T J B]
- **LIB-13** Decide up front whether a trait is meant for `dyn`. If so, keep it
  dyn-compatible and fence generic or `Self`-returning methods with `where Self: Sized`.
  [ref: B (C-OBJECT)]
- **LIB-14** A trait has a small required core and provided methods for the rest. A
  provided method that can panic has a `try_` twin, and the panicking one is written on top
  of it. What implementations must uphold goes under `# Implementer notes`. Implement the
  trait for `&T`, `&mut T` and `Box<T>` where that makes sense. Extension traits are `pub
  trait FooExt: Foo` with a blanket impl. [ref: T (bytes) B J]

## Documentation

- **LIB-15** The crate root doc opens with the same sentence as `Cargo.toml`'s
  `description`, then: how it works, the tradeoffs (bulleted, bold lead-ins), when to use
  something else, a `# Feature flags` list, and one end-to-end example commented line by
  line. [ref: J T]
- **LIB-16** Feature-gated items show their feature on docs.rs: `#![cfg_attr(docsrs,
  feature(doc_cfg))]` (from `templates/lib.rs-header.rs`) and `[package.metadata.docs.rs]
  all-features = true, rustdoc-args = ["--cfg", "docsrs"]`. [ref: T J]
- **LIB-17** Every doc test runs with warnings denied: the crate-root `#![doc(test(...))]`
  attribute from `templates/lib.rs-header.rs`. [ref: T]
- **LIB-18** Keep a `CHANGELOG.md` (Keep a Changelog: `[Unreleased]`, Added/Changed/Fixed,
  a PR link per entry, `(BREAKING)` markers, MSRV changes at the top of the release).
  [ref: T J B]
