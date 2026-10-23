---
name: rfr-project-structure
description: Use when organizing Rust crates, modules, and workspaces, defining or naming Cargo features, using conditional compilation, configuring build profiles, patching dependencies, or deciding versioning, MSRV, minimal dependency versions, changelogs, and Cargo metadata. Use when structuring a multi-crate project or preparing a library release.
---

# Rust for Rustaceans, Ch 5: Project Structure

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## Features

Source: RfR Ch 5 "Features" (TOC p. 67), "Defining and Including Features" (TOC p. 68), "Using Features in Your Crate" (TOC p. 70); RfR Ch 5 index "optional dependencies" (p. 69), "cargo-hack" (p. 68); Rust API Guidelines C-FEATURE

Cargo unifies features: if any crate in the build enables a feature of a dependency, every
user of that dependency gets it. So features must be additive. Enabling one must never
remove an item or change behaviour that another crate relies on.

```toml
[features]
default = ["std"]
std = []
serde = ["dep:serde"]

[dependencies]
serde = { version = "1", optional = true, default-features = false, features = ["derive"] }
```

Naming (C-FEATURE):
- Do: name a feature for what it enables: `std`, `serde`, `tokio`.
- Avoid: placeholder words such as `use-std`, `with-serde`, and negative features such as
  `no-std`. A negative feature is not additive.
- Optional `std` support is a feature named exactly `std`, in `default`, with the crate
  `#![no_std]` and `extern crate std;` under `#[cfg(feature = "std")]`.
- Use `dep:name` for optional dependencies, so Cargo does not create an implicit feature
  named after the dependency that you never meant to expose.

```rust
#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
}
```

Check every combination, not just `--all-features`: features that compile together may not
compile apart.

```bash
cargo hack --feature-powerset check
```

## Workspaces

Source: RfR Ch 5 "Workspaces" (TOC p. 70); RfR Ch 5 index "intra-workspace dependencies" (p. 72); Cargo book, resolver https://doc.rust-lang.org/cargo/reference/resolver.html

One repository, several crates, one `Cargo.lock` and one `target/`. Split a crate when
the parts have different dependency sets, compile-time cost, or release cadence; a proc
macro must be its own crate.

```toml
# Root Cargo.toml (virtual manifest: no [package])
[workspace]
members = ["crates/core", "crates/server"]
resolver = "3" # virtual manifests have no edition to infer it from

[workspace.package]
edition = "2024"
rust-version = "1.85"

[workspace.dependencies]
serde = { version = "1", default-features = false }
tokio = "1"
my-core = { path = "crates/core", version = "0.3" }

[workspace.lints.clippy]
pedantic = { level = "warn", priority = -1 }
```

```toml
# crates/server/Cargo.toml
[package]
name = "my-server"
version = "0.3.0"
edition.workspace = true
rust-version.workspace = true

[dependencies]
my-core.workspace = true
tokio = { workspace = true, features = ["rt-multi-thread", "net"] }

[lints]
workspace = true
```

- Declare the minimal feature set in `[workspace.dependencies]` and let each member add
  the features it uses. Workspace-level `features = ["full"]` pulls every feature into
  every member.
- A path dependency between members also carries `version` so the crate can be published.
- Building several members at once unifies their features; build them separately to test
  each member's own feature set.

## Modules and Visibility

Source: general Rust practice (not from the book); house layout rule from `rust-style`

```text
src/
  lib.rs        // crate root: mod config; mod server;
  config.rs     // crate::config
  server.rs     // crate::server: mod handler; mod state;
  server/
    handler.rs  // crate::server::handler
    state.rs    // crate::server::state
```

House layout: `foo.rs` plus `foo/`, never `foo/mod.rs` (clippy `mod_module_files`). The
lint does not fire on the integration-test helper `tests/common/mod.rs`.

| Visibility | Scope |
|------------|-------|
| (none) | Current module and its descendants |
| `pub(super)` | Parent module |
| `pub(in crate::a)` | The named ancestor module |
| `pub(crate)` | Whole crate |
| `pub` | Dependents too |

- Start private, widen only when needed. `unreachable_pub` flags `pub` items that are not
  reachable from the crate root.
- Re-export the main types at the crate root (`pub use config::Config;`). A re-exported
  item from another crate makes that crate's version part of your API (see
  `rfr-designing-interfaces`, hidden contracts).

## Crate Metadata

Source: RfR Ch 5 "Crate Metadata" (TOC p. 73); Rust API Guidelines C-METADATA

A published library's `[package]` carries `description`, `license`, `repository`,
`keywords`, `categories`, and `rust-version`. Set `documentation` only if docs are not on
docs.rs, and `homepage` only if the crate has its own site. clippy's
`cargo_common_metadata` (group `cargo`) checks the common fields.

## Build Configuration

Source: RfR Ch 5 "Build Configuration" (TOC p. 73); RfR Ch 5 index "profiles" (pp. 75-79), "codegen-units", "opt-level", "debugging options" (p. 75), "link-time optimization (LTO)" (pp. 75-76), "panic! macro", "unwinding" (pp. 76-77), "patches" (pp. 73-74)

### Profiles

```toml
[profile.release]
lto = "thin"        # cross-crate inlining; slower links
codegen-units = 1   # better optimization, slower builds
debug = "line-tables-only" # usable backtraces and profiles

[profile.dev.package."*"]
opt-level = 1       # optimize dependencies in dev builds
```

- Profiles are read only from the workspace root and only for the top-level build; a
  library's `[profile]` has no effect on its dependents.
- `panic = "abort"` makes panics abort instead of unwinding: smaller binaries, no
  `catch_unwind`, and `Drop` does not run on panic. It is a choice for the final binary.
  Libraries must not depend on unwinding or on aborting.

### Patching dependencies

`[patch]` swaps a dependency source for the whole build, for example to test an
unreleased fix:

```toml
[patch.crates-io]
some-dep = { git = "https://github.com/owner/some-dep", rev = "0123abc" }
```

The patched version must still satisfy the version requirement of every dependent. Remove
the patch once the fix is released; a published crate cannot carry `[patch]` for its users.

## Conditional Compilation

Source: RfR Ch 5 "Conditional Compilation" (TOC p. 78); RfR Ch 5 index "cfg conditions" (p. 78), "conditional dependencies" (pp. 79-80), "cfg! macro" (p. 70)

| Condition | True when |
|-----------|-----------|
| `feature = "x"` | Feature `x` is enabled |
| `target_os = "linux"`, `unix`, `windows` | Target OS or family |
| `target_arch = "x86_64"`, `target_pointer_width = "64"` | Target architecture |
| `test` | Compiling the crate's own tests |
| `debug_assertions` | Debug assertions on (dev profile by default) |
| `any(..)`, `all(..)`, `not(..)` | Combinators |

- `#[cfg(..)]` removes an item; `#[cfg_attr(cond, attr)]` adds an attribute conditionally;
  `cfg!(..)` is a boolean expression and both branches must compile.
- Platform-specific dependencies go in `[target.'cfg(unix)'.dependencies]`.
- Custom cfgs must be declared or rustc warns (`unexpected_cfgs`). Declare them in
  `[lints.rust] unexpected_cfgs = { level = "warn", check-cfg = ['cfg(loom)'] }`, or from
  a build script:

```rust
// build.rs
fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_fast_path)");
    if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") {
        println!("cargo::rustc-cfg=has_fast_path");
    }
}
```

## Versioning

Source: RfR Ch 5 "Versioning" (TOC p. 80); RfR Ch 5 index "semantic versioning" (p. 80), "RFC 1105" (p. 80); Cargo SemVer reference https://doc.rust-lang.org/cargo/reference/semver.html

Cargo semver: for `1.x.y`, a breaking change bumps the major; for `0.x.y` it bumps `x`;
for `0.0.x` every release is breaking. Classifications from the Cargo SemVer reference:

| Change | Class |
|--------|-------|
| Removing, renaming, or moving a public item | Major |
| Adding a public item | Minor |
| Adding a non-defaulted trait item | Major |
| Adding a defaulted trait item | Possibly-breaking |
| Adding a trait item that makes the trait not dyn-compatible | Major |
| Adding any inherent items | Possibly-breaking |
| Adding a variant to an enum without `#[non_exhaustive]` | Major |
| Adding a private field when all current fields are public | Major |
| Adding a public field when no private field exists | Major |
| Adding or removing private fields when one already exists | Minor |
| Adding `#[non_exhaustive]` to an existing enum, variant, or all-public struct | Major |
| Tightening generic bounds | Major |
| Loosening generic bounds | Minor |
| Switching from `no_std` support to requiring `std` | Major |
| Changing the minimum Rust version | Possibly-breaking |
| Adding a Cargo feature | Minor |
| Removing a Cargo feature, or removing a feature from `default` that changes items | Major |

"Possibly-breaking" means it can break some callers (a new inherent method can shadow a
trait method with the same name). Run `cargo semver-checks` on every library PR; it
catches much of this but not all.

### Minimum Supported Rust Version

Source: RfR Ch 5 "Minimum Supported Rust Version" (TOC p. 81); Cargo SemVer reference; Cargo book, resolver

- Set `rust-version` in `Cargo.toml`. With resolver `"3"` (default on edition 2024, Rust
  1.84+), Cargo prefers dependency versions whose `rust-version` your toolchain satisfies.
- Cargo classifies an MSRV bump as possibly-breaking and recommends treating it as minor.
  House rule: raise it in a minor release, record the reason in the changelog, and check
  it in CI (`cargo hack --rust-version check`).

### Minimal Dependency Versions

Source: RfR Ch 5 "Minimal Dependency Versions" (TOC p. 82); RfR Ch 5 index "-Zminimal-versions flag" (p. 82)

A requirement such as `serde = "1.0.100"` claims the crate works with 1.0.100. Normal
builds pick the newest version, so a wrong lower bound goes unnoticed. Check it in CI:

```bash
# Dev-dependencies would otherwise pull the floors up (Tokio's CI does the same).
cargo hack --remove-dev-deps --workspace
cargo +nightly update -Zminimal-versions
cargo check --locked --workspace --all-features
```

Libraries declare the oldest compatible version as a caret requirement (`"1.0.100"`),
never an `=` pin. Every repo, application or library, commits `Cargo.lock` so CI can run
`--locked` (house rule REPO-4); consumers of a library still resolve with their own
lockfile.

### Changelogs

Source: RfR Ch 5 "Changelogs" (TOC p. 83); Rust API Guidelines C-RELNOTES

Keep a changelog with a section per release. Flag breaking changes (as defined by RFC
1105) clearly. Tag each published release, preferably with annotated tags. Link the
changelog from the crate docs or repository.

### Unreleased Versions

Source: RfR Ch 5 "Unreleased Versions" (TOC p. 83); RfR Ch 5 index "unreleased versions" (pp. 83-84)

To use an unreleased change of a dependency, point at it with `[patch]` or a `git`
dependency (see Build Configuration). crates.io rejects git-only dependencies, so release
the dependency before publishing.

## Common Mistakes

Source: general Rust practice (not from the book); Rust API Guidelines C-FEATURE

1. **Non-additive or negative features** (`no-std`): break whoever else enables them.
2. **Only testing `--all-features`**: run `cargo hack --feature-powerset`.
3. **`use-`/`with-` feature prefixes**: name the feature after what it enables.
4. **`pub` on internal helpers**: use `pub(crate)` until external use is needed.
5. **Over-wide workspace features** such as `tokio` `full` for every member.
6. **Unchecked lower bounds**: a `-Zminimal-versions` job keeps them honest.
7. **Exact `=` pins in a library**: they force conflicts on every dependent.
8. **Blanket `#[non_exhaustive]`**: decide per type; it costs callers exhaustive matching.
