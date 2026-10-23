---
name: rust-dependency-audit
description: Use when auditing Rust dependencies or deciding whether to add one - RUSTSEC advisories, licenses, bans and sources with cargo deny, supply-chain audits with cargo vet, build.rs review, cargo tree, and the checklist for a new dependency in Cargo.toml.
---

# Rust dependency audit

Every dependency is code you run, at build time too. House policy lives in
`rust-style/topics/repo.md` (REPO-3 to REPO-6) and the template
`rust-style/templates/deny.toml`; this skill is the workflow around them.

## One gate: cargo-deny

`cargo deny check` covers advisories (RUSTSEC, yanked, unsound, unmaintained), licenses,
bans and sources in one run, from the same advisory database `cargo audit` reads. Use it as
the only advisory gate in CI (`rust-style/templates/ci/deny.yml`); running `cargo audit` as
well reports the same advisories twice.

```bash
cargo deny check                 # everything
cargo deny check advisories      # after `cargo update`, or when a RUSTSEC notice lands
cargo deny check licenses
```

Start from `rust-style/templates/deny.toml`, not `cargo deny init`. It uses the current
schema: vulnerable and unmaintained crates are denied by default, `yanked = "deny"` and
`unsound = "all"` are explicit, and `[licenses.private] ignore = true` exempts unpublished
crates. Removed keys such as `vulnerability`, `copyleft` or `unlicensed` make current
cargo-deny refuse the file.

An advisory you cannot fix yet is ignored with its id and a reason, never silently:

```toml
[advisories]
ignore = [{ id = "RUSTSEC-0000-0000", reason = "not reachable: we never call X" }]
```

`[bans] deny` matches the whole dependency graph, transitive crates included. Use it for
crates that must never be built (a second TLS stack, a known-bad crate), not for "our code
should not call X": that is a lint or a review rule.

## build.rs and proc macros: the largest attack surface

Build scripts and proc macros run with your privileges during `cargo build` and in
rust-analyzer, with no sandbox. For every new dependency, and for new versions of the ones
that have them:

1. Read its `build.rs` and any proc-macro crate it pulls in.
2. Prefer an alternative without a build script when one exists.
3. Build untrusted code in a container or CI runner with restricted network.

## Supply-chain audits: cargo-vet

```bash
cargo vet init
cargo vet                        # every dependency audited or exempted?
cargo vet suggest                # unaudited crates, cheapest review first
cargo vet diff CRATE OLD NEW     # review only what changed between versions
cargo vet certify CRATE VERSION  # record your audit
```

Import audits from organisations you trust (`[imports]` in `supply-chain/config.toml`)
instead of re-reviewing popular crates.

## Understanding the graph

```bash
cargo tree -i regex              # why is regex here?
cargo tree -d                    # duplicate versions
cargo tree -e features -i serde  # which dependency enables which feature
cargo tree --depth 1             # direct dependencies only
```

## Adding a dependency

1. **Necessity**: can std or an existing dependency do it? A small need is copied in-tree
   with its provenance noted (REPO-6).
2. **Maintenance**: recent releases, responsive issues, more than one maintainer for
   anything critical. Check the current version and docs; never pick one from memory.
3. **Build-time code**: `build.rs`, proc macros, `links =`, bundled C sources.
4. **Advisories and license**: `cargo deny check` after adding it.
5. **Features**: `default-features = false`, enable only what you use, and comment each
   feature with the API that needs it (REPO-5).
6. **Version**: caret requirement at the oldest version that works (REPO-3); the lockfile
   is committed (REPO-4).

## Red flags

| Signal | Risk |
|---|---|
| New `build.rs` or proc macro in an update | Build-time code execution changed |
| Ownership or repository transfer | Account takeover, typosquat |
| No release in two years, open security issues | Unpatched vulnerabilities |
| Name one character off a popular crate | Typosquat |
| `features = ["full"]` in a library | Bloat, larger attack surface |
