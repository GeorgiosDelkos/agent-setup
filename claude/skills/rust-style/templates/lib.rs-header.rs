// Crate-root attributes for libraries. Paste at the top of src/lib.rs, below the `//!` crate
// docs and above the first item. Lints live in Cargo.toml [lints] (Cargo.lints.toml), not here.
//
// Pair with this in Cargo.toml, so docs.rs (and `cargo docs-rs` in check.yml) builds with every
// feature and sets `--cfg docsrs`:
//
// [package.metadata.docs.rs]
// all-features = true
// rustdoc-args = ["--cfg", "docsrs"]

// Doctests are compiled as user code: no implicit `extern crate <this crate>` (examples show the
// real `use` lines), warnings and 2018 idioms are errors so examples stay clean, and unused
// bindings are fine because examples are fragments (Tokio, bytes).
#![doc(test(
    no_crate_inject,
    attr(deny(warnings, rust_2018_idioms), allow(dead_code, unused_variables))
))]
// On docs.rs (nightly, `--cfg docsrs`), label feature- and platform-gated items with the cfg
// they need. Stable builds never see the unstable feature (Tokio, Jon, Cranelift).
#![cfg_attr(docsrs, feature(doc_cfg))]
