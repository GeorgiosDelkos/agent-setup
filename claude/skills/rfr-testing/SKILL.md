---
name: rfr-testing
description: Use when writing Rust tests or choosing a test strategy - unit, integration, doctests (including compile_fail), custom harnesses, test-only APIs, property testing, fuzzing, Miri, sanitizers, Loom for concurrency, mutation testing, or benchmarks with std::hint::black_box. Use when tests are flaky, slow, or miss edge cases, error paths, or undefined behavior.
---

# Rust for Rustaceans, Ch 6: Testing

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## The Test Harness

Source: RfR Ch 6 "The Test Harness" (TOC p. 86); RfR Ch 6 index "test harness" (pp. 86-87), "descriptors" (p. 86)

`cargo test` builds each target with `--test`: rustc collects every `#[test]` function
into a list of test descriptors and generates a `main` that runs them (in parallel
threads, filtered by name).

- Unit tests live next to the code in `#[cfg(test)] mod tests` and can reach private items.
- Integration tests live in `tests/*.rs`. Each file is its own crate that sees only the
  public API. Shared helpers go in `tests/common/mod.rs` and are pulled in with
  `mod common;` (a `tests/common.rs` would be compiled as a test crate of its own). The
  house `mod_module_files` lint does not fire on this file.
- `harness = false` on a `[[test]]` or `[[bench]]` target turns off the generated `main`;
  the file then supplies its own. Use it for criterion benchmarks, or for tests generated
  at runtime from data files (the `libtest-mimic` crate gives such a harness the usual
  CLI).

```toml
[[test]]
name = "conformance"
harness = false
```

| Attribute | Effect |
|-----------|--------|
| `#[test]` | Test function; may return `Result<(), E: Debug>` |
| `#[should_panic(expected = "msg")]` | Passes only if it panics with a message containing `msg` |
| `#[ignore = "reason"]` | Skipped unless `cargo test -- --ignored` |

```rust
pub fn parse_port(s: &str) -> Result<u16, std::num::ParseIntError> {
    s.parse()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_port() {
        assert_eq!(parse_port("8080"), Ok(8080));
    }

    #[test]
    fn rejects_out_of_range_port() {
        assert!(parse_port("70000").is_err());
    }
}
```

## `#[cfg(test)]`, Mocks, and Test-Only APIs

Source: RfR Ch 6 "#[cfg(test)]" (TOC p. 88); RfR Ch 6 index "mocks" (p. 88), "test-only APIs" (p. 89); RfR errata print01-ch06-buckets-visibility.md

- `cfg(test)` is set only while compiling this crate's own unit tests. It is not set for
  integration tests, doctests, or dependents, so test-only APIs behind it are invisible
  there. For helpers that integration tests or downstream crates need, use a feature
  (Tokio calls it `test-util`): `#[cfg(any(test, feature = "test-util"))]`.
- To give tests access to an internal field without making it public, use `pub(crate)`
  (the book's errata fixes an example on exactly this point).
- Mock at boundaries (clock, network, filesystem) by making the code generic over a trait
  or by passing the dependency in. Do not mock your own pure logic.

```rust
pub trait Clock {
    fn now_ms(&self) -> u64;
}

pub struct Timeout<C: Clock> {
    clock: C,
    deadline_ms: u64,
}

impl<C: Clock> Timeout<C> {
    pub fn new(clock: C, after_ms: u64) -> Self {
        let deadline_ms = clock.now_ms() + after_ms;
        Self { clock, deadline_ms }
    }

    pub fn expired(&self) -> bool {
        self.clock.now_ms() >= self.deadline_ms
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    struct FakeClock(Cell<u64>);

    impl Clock for &FakeClock {
        fn now_ms(&self) -> u64 {
            self.0.get()
        }
    }

    #[test]
    fn expires_at_deadline() {
        let clock = FakeClock(Cell::new(1_000));
        let t = Timeout::new(&clock, 50);
        assert!(!t.expired());
        clock.0.set(1_050);
        assert!(t.expired());
    }
}
```

## Doctests

Source: RfR Ch 6 "Doctests" (TOC p. 90); RfR Ch 6 index "compile_fail! macro" (p. 92), "#[should_panic] attribute" (p. 92); Rust API Guidelines C-QUESTION-MARK

Code blocks in `///` docs compile and run as separate crates against your public API.

| Fence | Effect |
|-------|--------|
| ```` ``` ```` | Compiled and run |
| ```` ```no_run ```` | Compiled, not run (network, filesystem) |
| ```` ```should_panic ```` | Must panic |
| ```` ```compile_fail ```` | Must fail to compile |
| ```` ```ignore ```` | Not compiled; say why next to it |

- Lines starting with `# ` are compiled but hidden from the rendered docs; use them for
  setup and for a `fn main() -> Result<..>` wrapper so examples use `?`, not `unwrap`
  (C-QUESTION-MARK).
- Use `compile_fail` to pin properties that must not compile: a type that must stay
  `!Send`, or a borrow your API must reject. It passes on any compile error, so keep the
  block minimal and check locally that it fails for the intended reason.

```rust
/// A handle that must stay on the thread that created it.
///
/// ```compile_fail
/// fn assert_send<T: Send>() {}
/// assert_send::<my_crate::LocalHandle>();
/// ```
pub struct LocalHandle {
    _not_send: std::marker::PhantomData<*const ()>,
}
```

## Linting

Source: RfR Ch 6 "Linting" (TOC p. 92); RfR Ch 6 index "correctness lints" (pp. 92-93)

```bash
cargo clippy --all-targets --all-features -- -D warnings
```

- `--all-targets` lints tests, examples, and benches too.
- Silence a lint with `#[expect(clippy::lint, reason = "...")]`, which warns once the lint
  no longer fires. House `clippy.toml` sets `allow-unwrap-in-tests`, so tests need no
  annotation for `unwrap`.

## Test Generation

Source: RfR Ch 6 "Test Generation" (TOC p. 93); RfR Ch 6 index "fuzzing" (pp. 93-94), "property-based testing" (pp. 94-95), "test generation techniques" (pp. 93-94, 112); Jon Gjengset, Towards Impeccable Rust (2024)

### Property-based testing

State a property that holds for all inputs; the tool generates inputs and shrinks a
failure to a minimal case. Good fits: round trips (encode then decode), parsers, data
structures checked against a simple model (`Vec`, `BTreeMap`), algebraic laws.

```rust
pub fn encode(n: u32) -> [u8; 4] {
    n.to_be_bytes()
}

pub fn decode(b: [u8; 4]) -> u32 {
    u32::from_be_bytes(b)
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    proptest! {
        #[test]
        fn roundtrip(n in any::<u32>()) {
            prop_assert_eq!(decode(encode(n)), n);
        }
    }
}
```

### Fuzzing

Coverage-guided fuzzing (`cargo fuzz`, libFuzzer) finds panics and crashes in code that
takes untrusted bytes: parsers, decoders, protocol state machines.

```rust,ignore
// ignore: a cargo-fuzz target; needs the libfuzzer-sys crate and `cargo +nightly fuzz`
// fuzz/fuzz_targets/parse.rs
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = my_crate::parse(data); // must not panic on any input
});
```

```bash
cargo +nightly fuzz run parse
```

### Generating tests across types

The book's macro chapter generates the same test battery for several types with a
`macro_rules!` (see `rfr-macros`). Prefer a generic test helper when a function will do.

## Test Augmentation

Source: RfR Ch 6 "Test Augmentation" (TOC p. 96); RfR Ch 6 index "Miri" (pp. 96-97), "Loom" (p. 97), "sanitizers" (p. 165, pp. 190-191); rust-ci-conf `.github/workflows/safety.yml`

### Miri

Miri interprets your tests and reports undefined behaviour: use-after-free, out-of-bounds
and unaligned access, invalid values, aliasing violations (Stacked Borrows by default),
data races, and leaks.

```bash
rustup +nightly component add miri
cargo +nightly miri test
```

Run the whole test suite under Miri in CI, as rust-ci-conf does. Miri is an interpreter
and much slower, so shrink large test inputs under `cfg(miri)` rather than skipping
tests. It cannot run most FFI.

### Sanitizers

Compiled-in runtime checks, nightly only. AddressSanitizer catches memory errors in code
Miri cannot run (FFI); LeakSanitizer catches leaks; ThreadSanitizer catches data races.

```bash
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --target x86_64-unknown-linux-gnu
```

### Loom

Loom runs a concurrent test under every distinguishable interleaving its model allows.
Code uses `loom`'s sync types when built with `--cfg loom`, and std's otherwise. See
`rfr-concurrency` for when to reach for it.

```rust
#[cfg(loom)]
use loom::sync::atomic::{AtomicUsize, Ordering};
#[cfg(not(loom))]
use std::sync::atomic::{AtomicUsize, Ordering};

pub struct Counter(AtomicUsize);

impl Counter {
    pub fn incr(&self) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}

#[cfg(all(test, loom))]
mod loom_tests {
    use loom::sync::Arc;

    use super::*;

    #[test]
    fn concurrent_increments_are_not_lost() {
        loom::model(|| {
            let c = Arc::new(Counter(AtomicUsize::new(0)));
            let c2 = Arc::clone(&c);
            let t = loom::thread::spawn(move || c2.incr());
            c.incr();
            t.join().expect("thread does not panic");
            assert_eq!(c.0.load(Ordering::Relaxed), 2);
        });
    }
}
```

```bash
# The models are a module inside the lib (cfg(all(test, loom))), not a tests/ target.
RUSTFLAGS="--cfg loom" cargo test --release --lib loom_tests
```

Declare the cfg so rustc does not warn: `[lints.rust] unexpected_cfgs = { level = "warn",
check-cfg = ['cfg(loom)'] }`.

### Beyond the book

From Jon's later talk *Towards Impeccable Rust* (2024): assert invariants everywhere,
have tests for your error cases, use mutation testing (`cargo mutants`) to find code your
tests do not check, deterministic simulation (turmoil, shuttle) for distributed and
concurrent code, and Kani proofs where exhaustive checking is feasible. Jon's book site
also points to `insta` for snapshot tests and builders for test scenarios.

## Performance Testing

Source: RfR Ch 6 "Performance Testing" (TOC p. 97); RfR Ch 6 index "black_box function" (p. 99), "benchmarking" (pp. 98-100); std docs https://doc.rust-lang.org/std/hint/fn.black_box.html; Jon Gjengset, Towards Impeccable Rust (2024)

- Use `std::hint::black_box` (stable since 1.66) on inputs and outputs so the optimizer
  cannot precompute or delete the measured work. `criterion::black_box` is deprecated in
  favour of it. It is best-effort only: never rely on it for correctness or constant-time
  code.
- Benchmark realistic inputs, and compare against a saved baseline.

```rust
// benches/parse.rs, with `[[bench]] name = "parse" harness = false`
use std::hint::black_box;

use criterion::{Criterion, criterion_group, criterion_main};

fn parse(s: &str) -> u64 {
    s.bytes().fold(0, |acc, b| acc * 10 + u64::from(b - b'0'))
}

fn bench_parse(c: &mut Criterion) {
    c.bench_function("parse 20 digits", |b| {
        b.iter(|| parse(black_box("12345678901234567890")));
    });
}

criterion_group!(benches, bench_parse);
criterion_main!(benches);
```

Benchmark noise (Towards Impeccable Rust): wall-clock time on shared CI machines is
noisy. Jon's advice: measure something other than time (instruction counts, e.g.
iai-callgrind), run old and new versions interleaved (e.g. tango), and let CI fail on a
regression.

## Common Mistakes

Source: general Rust practice (not from the book); Jon Gjengset, Towards Impeccable Rust (2024)

1. **Testing internals instead of behaviour**: refactors break tests that should not break.
2. **No tests for error paths**: every documented `Err` variant has a test that triggers it.
3. **Test-only helpers behind `cfg(test)` that integration tests need**: use a feature.
4. **`compile_fail` doctests that fail for the wrong reason**: keep them minimal.
5. **Benchmarks without `black_box`**, or timing noisy CI runners and trusting the numbers.
6. **Unsafe or concurrent code without Miri, Loom, or sanitizers**: tests that pass do not
   show the absence of UB or races.
