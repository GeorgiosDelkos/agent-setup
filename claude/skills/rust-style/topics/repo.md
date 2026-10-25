# Repo setup: manifests, lints, CI (REPO)

Read before editing `Cargo.toml`, `deny.toml`, `clippy.toml`, toolchain files, or CI
workflows. Tags and IDs as in `../SKILL.md`. For depth: `rfr-project-structure`,
`rust-dependency-audit`, `gh-actions-style` (for any workflow edit).

## Adopting the templates

- **REPO-1** A repo that lacks them gets the templates, proposed and never applied
  silently: stage them, run clippy once, and show the owner the fallout before committing.
  Adopting them includes the opt-in that turns on the house rules in the stop hook:

  ```toml
  [workspace.metadata.house-check]   # [package.metadata.house-check] in a single crate
  baseline = true
  ```

  Without it the hook adds only minimal lints and the repo's conventions win (SKILL.md,
  "Whose repo").
  - `templates/Cargo.lints.toml`: merge as `[workspace.lints.*]`, `[lints] workspace = true`
    in every member. Add the crate's own custom cfgs to `unexpected_cfgs` check-cfg. A crate
    with no `unsafe` adds `unsafe_code = "forbid"` (UNS-1).
  - `templates/clippy.toml`: repo root. Add product names to `doc-valid-idents`.
  - `templates/deny.toml`: `cargo deny check` in CI.
  - `templates/lib.rs-header.rs`: top of every published library's `lib.rs`.
  - `templates/ci/`: workflows from `jonhoo/rust-ci-conf` plus house gates; delete the ones
    whose header says they do not apply.
  - `templates/.pre-commit-config.yaml`: `prek install`.

  No `rustfmt.toml`: default rustfmt everywhere, and the hooks read the edition from
  `Cargo.toml`. [ref: T C J use default style; C and six J repos keep an edition-only
  `rustfmt.toml`, which drifts from `Cargo.toml` in three of J's]
- **REPO-2** Lints: `warn` in `[lints]` so work in progress builds locally; CI and the stop
  hook turn every warning into an error (`CARGO_BUILD_WARNINGS=deny` or `-D warnings`).
  The exceptions are `deny` on purpose: soundness lints (`unsafe_op_in_unsafe_fn`,
  `undocumented_unsafe_blocks`, `missing_safety_doc`, `static_mut_refs`) and leftovers
  that must never reach a commit (`dbg_macro`, `todo`, `unimplemented`, prints in
  libraries). [ref: C for `warn`; house: the denies]

## Manifests

- **REPO-3** Dependencies use caret requirements, never `=` pins. In a repo with a
  minimal-versions CI job (published libraries, REPO-13), the requirement is the oldest
  version that job proves works, raised only when you start using something newer; a
  transitive floor that needs raising goes in `[target.'cfg(any())'.dependencies]` with a
  comment naming the dependency it fixes. Everywhere else, require the current minor version
  (looked up, never from memory) and claim no floor: an "oldest that works" nothing checks is
  a DOC-7 violation and costs an afternoon of bisecting. [ref: T J B; house: no unchecked
  floors]
- **REPO-4** `Cargo.lock` is committed in every repo, applications and libraries, and CI
  runs with `--locked`. Dependabot: libraries ignore patch and minor cargo updates
  (consumers use their own lockfile); applications take them grouped. [ref: J; house
  decision 2026-10-23]
- **REPO-5** Turn off default features of dependencies and enable what you use
  (`default-features = false` in `[workspace.dependencies]`). Comment each optional
  dependency and each enabled feature with the API that needs it. [ref: C J T]
- **REPO-6** Every new dependency is justified: prefer std or existing code; a small need
  is copied in-tree with its provenance noted; core crates say in the manifest that new
  dependencies need a strong reason. Dependency updates are their own PRs. [ref: C J]
- **REPO-7** A crate's own proc-macro companion is pinned with `~` so the two stay in step
  within a minor version. [ref: T]

## Features

- **REPO-8** Features are additive (`cargo hack --feature-powerset check` proves it). Names
  have no `use-`/`with-`/`no-` prefix; optional std support is a `std` feature in
  `default`; optional serde is a feature named exactly `serde`. Use `dep:` for optional
  dependencies. Impossible combinations fail with `compile_error!` naming the supported
  set. [ref: B (C-FEATURE) T J]
- **REPO-9** Large libraries ship `default = []` (or only `std`) plus a `full`
  meta-feature. Every feature has a comment saying what it enables and what it costs, and
  the crate root lists them (LIB-15). [ref: T C]
- **REPO-10** Minimize `#[cfg]`: gate whole modules and definitions, not call sites; when
  a feature is off, compile a zero-sized stand-in with the same API so callers need no
  `#[cfg]`; never declare modules inside `cfg_if!` or other macros (rustfmt cannot see
  them). With many features, wrap `#[cfg(feature = "x")]` +
  `#[cfg_attr(docsrs, doc(cfg(feature = "x")))]` in one `cfg_x!` macro. [ref: C T]

## Toolchain and MSRV

- **REPO-11** Libraries set `rust-version`, no newer than stable minus 2, and raise it in
  a minor release with the reason in a comment and the changelog. CI checks it with `cargo
  hack check --rust-version`, which reads the manifest and cannot drift. Applications pin
  the latest stable in `rust-toolchain.toml`. Workarounds for an old MSRV are tagged
  `TODO(<owner>, MSRV 1.xx)` (DOC-10). [ref: C T J; house: toolchain pin for apps]
- **REPO-12** Library metadata: `description` (same sentence as the crate docs' first
  line), `license = "MIT OR Apache-2.0"`, `repository`, `keywords`, `categories`,
  `rust-version`; `exclude` CI files and fixtures from the package. [ref: J B]

## CI

- **REPO-13** CI comes from `templates/ci/` (rust-ci-conf structure, SHA-pinned actions per
  `gh-actions-style`). What applies:
  - every crate: fmt, clippy (stable blocking with warnings as errors, beta advisory), tests
    (`cargo nextest run` plus `cargo test --doc`, `--locked`), scheduled nightly and
    `cargo update` runs with `-D deprecated`, `cargo deny` on manifest changes and daily;
  - published libraries: macOS and Windows, docs (`cargo docs-rs`, warnings as errors),
    `cargo semver-checks`, `cargo hack --feature-powerset --depth 2 check`, MSRV, minimal
    versions;
  - any `unsafe` or lock-free code: Miri (strict provenance), ASan, LSan, TSan, loom, a
    `panic=abort` run;
  - no_std crates: `cargo check --target thumbv7m-none-eabi --no-default-features`;
  - applications: a release-mode check for each deploy target, and only the platforms
    they ship on.

  [ref: J T C; house: warnings as errors, `cargo deny`, SHA pins]
- **REPO-14** Nightly jobs run the latest nightly that ships the needed component, as
  rust-ci-conf does; when a nightly regression breaks one, pin that job to a dated nightly
  with a comment saying when to move it. Check benches and fuzz targets compile. A repo
  that generates code checks the output is deterministic. [ref: J (floating), T C (dated
  pins)]

## Process

- **REPO-15** Commit messages: imperative subject of at most 72 characters (a full sentence
  ending in a period is fine: "Stop Manual::replace collecting past the key cap."); the body states
  the current behaviour, what goes wrong, and the fix, in prose (no file lists, no "added a
  test"); `Fixes: #N` / `Refs: #N` trailers. Explanations of the code go in the code, the
  commit says why the new version is better. Once review starts, push new commits instead
  of rebasing. [ref: T C]
