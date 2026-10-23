---
name: rust-performance
description: Use when optimizing Rust code performance, profiling with flamegraph, writing benchmarks with criterion, or when code is unexpectedly slow. Use when reducing allocations, choosing data structures, or tuning release profiles.
---

# Rust Performance

## Overview

Optimize Rust code systematically: measure first, identify bottlenecks, optimize with data. Avoid premature optimization -- most code doesn't need tuning.

## When to Use

- Code is measurably too slow
- Writing performance-critical paths
- Choosing between data structures
- Setting up benchmarks
- Profiling CPU or memory usage
- Unexpected performance regression

**Not for:** General code improvement (use `rust-style`), first implementation (optimize later)

## Quick Reference

| Goal | Tool/Approach |
|------|---------------|
| Benchmark code | `criterion` crate |
| CPU profiling | `samply`, `perf` + Hotspot, `flamegraph` |
| Memory profiling | `heaptrack`, DHAT (`dhat-rs`) |
| Allocation tracking | `dhat-rs`, `#[global_allocator]` |
| Compile-time | `cargo build --timings` |
| Binary size | `cargo bloat`, `twiggy` |
| Type sizes | `RUSTFLAGS=-Zprint-type-sizes cargo +nightly build` |
| UB/safety checks | `cargo careful test` |

## Performance Workflow

```
1. Measure (don't guess)
   -> 2. Identify bottleneck
   -> 3. Hypothesize improvement
   -> 4. Implement change
   -> 5. Measure again
   -> 6. Keep or revert
```

## Build Configuration

### Maximum runtime speed

```toml
[profile.release]
codegen-units = 1           # Better optimization, slower compile
lto = "fat"                 # Cross-crate inlining; gains vary by workload, measure ("thin" is cheaper)
panic = "abort"             # Smaller binary; only if nothing relies on catch_unwind
debug = "line-tables-only"  # Symbolized profiles; strip separately for shipping
```

```bash
# CPU-specific instructions
RUSTFLAGS="-C target-cpu=native" cargo build --release
```

### Profile-Guided Optimization (PGO)

Compile, run on representative data, recompile with profile. Typical gain: 10-20%.

```bash
# Using cargo-pgo
cargo pgo build                    # Build instrumented
cargo pgo run -- <representative-args>  # Collect profile
cargo pgo optimize build           # Build optimized
```

### Global Allocator

Try these when the default allocator is a bottleneck (benchmark with your workload):

```rust
// jemalloc -- best for Linux, THP support
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

// mimalloc -- cross-platform, by Microsoft
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;
```

## Benchmarking with Criterion

```rust
// benches/my_benchmark.rs
use std::hint::black_box; // criterion::black_box is deprecated

use criterion::{criterion_group, criterion_main, Criterion};

fn bench_sort(c: &mut Criterion) {
    let mut group = c.benchmark_group("sorting");
    let data: Vec<u64> = (0..10_000).rev().collect();

    group.throughput(criterion::Throughput::Elements(data.len() as u64));

    group.bench_function("std_sort", |b| {
        b.iter(|| {
            let mut d = data.clone();
            d.sort();
            black_box(d)
        })
    });

    group.bench_function("sort_unstable", |b| {
        b.iter(|| {
            let mut d = data.clone();
            d.sort_unstable();
            black_box(d)
        })
    });

    group.finish();
}

criterion_group!(benches, bench_sort);
criterion_main!(benches);
```

**Apply `black_box` to inputs AND outputs** to prevent dead code elimination and constant folding.

Use `iter_batched` when setup is expensive and should not be measured:

```rust
b.iter_batched(
    || create_large_data(),  // setup (not measured)
    |data| process(data),    // measured
    BatchSize::SmallInput,
);
```

## Data Structures

| Access Pattern | Data Structure | Notes |
|---------------|----------------|-------|
| Lookup-heavy | `HashMap` | O(1) average; a faster hasher (`foldhash`, `rustc-hash`) for trusted keys is often the biggest win |
| Ordered iteration | `BTreeMap` | O(log n), range queries |
| Insertion-ordered | `IndexMap` | O(1) lookup, ordered iteration |
| Small collections (<50) | `Vec` | Cache-friendly linear scan |
| Stack-like | `Vec` with push/pop | O(1) amortized |
| Queue-like | `VecDeque` | O(1) both ends |
| Concurrent map | `DashMap` | Sharded `RwLock`s, not lock-free; holding a `Ref` while writing the same shard deadlocks |
| Bounded cache | `quick_cache::Cache` | LRU with size limit |
| Usually short, rarely long | `SmallVec<[T; N]>` | Inline storage, heap fallback |
| Fixed max length | `ArrayVec<T, N>` | No heap, panics on overflow |
| Deduplicated strings | `lasso::Rodeo` | String interning |

### SmallVec vs ArrayVec vs Vec

- **`SmallVec<[T; N]>`**: stores up to N inline, spills to heap. Use when most instances are small.
- **`ArrayVec<T, N>`**: fixed capacity, never allocates. Use when max size is known.
- **`Vec<T>`**: always heap. Use when size is unpredictable or large.

## Reducing Allocations

```rust
// Pre-allocate when size is known
let mut v = Vec::with_capacity(items.len());

// Reuse allocations
fn process_reuse(items: &[Item], output: &mut Vec<String>) {
    output.clear();
    // output's allocation is reused
    for item in items {
        output.push(item.name.clone());
    }
}

// Return references instead of cloning
fn names<'a>(items: &'a [Item]) -> Vec<&'a str> {
    let mut result = Vec::with_capacity(items.len());
    for item in items {
        result.push(item.name.as_str());
    }
    result
}

// Cow for maybe-clone
use std::borrow::Cow;
fn normalize(input: &str) -> Cow<'_, str> {
    if input.contains('\t') {
        Cow::Owned(input.replace('\t', "    "))
    } else {
        Cow::Borrowed(input)
    }
}

// Boxed slices save one word vs Vec (no capacity field)
let data: Box<[u32]> = vec![1, 2, 3].into_boxed_slice();
```

## Zero-Copy with Bytes

```rust
use bytes::{Bytes, BytesMut, BufMut};

// Bytes: reference-counted, clone() is O(1), slice() is O(1)
fn process_data(data: Bytes) -> Bytes {
    data.slice(HEADER_LEN..)
}

// BytesMut for building up data
fn encode_frame(payload: &[u8]) -> Bytes {
    let mut buf = BytesMut::with_capacity(4 + payload.len());
    buf.put_u32(payload.len() as u32);
    buf.put_slice(payload);
    buf.freeze()
}
```

## Arena Allocation

For many short-lived objects of the same lifetime:

```rust
// bumpalo: fast bump allocator, heterogeneous types
use bumpalo::Bump;
let bump = Bump::new();
let x = bump.alloc(42u64);
let y = bump.alloc("hello");
// All freed when bump is dropped -- no individual deallocation

// typed-arena: single type, supports reference cycles
use typed_arena::Arena;
let arena: Arena<AstNode> = Arena::new();
let node = arena.alloc(AstNode::new("root"));
```

## Type Size Optimization

Measure with: `RUSTFLAGS=-Zprint-type-sizes cargo +nightly build --release`

```rust
// Box large enum variants to shrink the enum
enum Message {
    Ping,
    Data(Box<LargePayload>),  // Box keeps enum size small
}

// Use smaller integers when range permits
struct Compact {
    id: u32,      // not usize
    flags: u8,    // not u32
    offset: u16,  // not usize
}

// Static assertion to prevent size regressions
#[cfg(target_arch = "x86_64")]
const _: () = assert!(std::mem::size_of::<HotType>() <= 64);
```

## Cache-Friendly Layout (SoA vs AoS)

```rust
// Array of Structs (default) -- all fields per element contiguous
struct Particles { data: Vec<Particle> }

// Structure of Arrays -- each field is a separate array
// Better cache utilization when operations touch few fields
struct Particles {
    x: Vec<f32>,
    y: Vec<f32>,
    velocity_x: Vec<f32>,
    velocity_y: Vec<f32>,
}
// Updating positions loads only x, y, vx, vy -- no wasted cache lines
```

Use SoA for hot loops touching few fields. Use AoS when operations touch most fields per element.

## `#[inline]` Guidance

- **Small functions across crate boundaries** (without LTO): `#[inline]`. Since Rust 1.75 rustc
  already makes small leaf functions inlinable across crates, so this matters mostly for
  generic-free wrappers that call other functions.
- **Hot getters and wrappers**: `#[inline]`
- **Large functions**: do NOT inline (instruction cache pressure)
- **Error paths**: `#[inline(never)] #[cold]`
- **Default**: let the compiler decide. Profile before adding `#[inline]`.

```rust
#[inline]
pub fn is_empty(&self) -> bool { self.len == 0 }

#[inline(never)]
#[cold]
fn handle_error(err: &Error) { /* ... */ }
```

## Profiling Commands

```bash
# CPU flamegraph
cargo flamegraph --bin myapp
# Or using samply (cross-platform)
samply record ./target/release/myapp

# Memory profiling
heaptrack ./target/release/myapp

# Compile times
cargo build --timings

# Binary size
cargo bloat --release --crates

# With frame pointers for accurate stacks
RUSTFLAGS="-C force-frame-pointers=yes" cargo build --release
```

## Common Mistakes

| Mistake | Issue | Fix |
|---------|-------|-----|
| Optimizing without measuring | Wasted effort | Profile first |
| Debug builds for perf | 10-100x slower | Use `--release` |
| `clone()` in hot loop | Allocation overhead | Borrow or restructure |
| `Vec` for FIFO | O(n) remove(0) | Use `VecDeque` |
| `HashMap` for <50 items | Hash overhead | `Vec` + linear search |
| `Box<dyn Trait>` in hot path | Vtable indirection | Use enum or generics |
| `Vec<u8>` for shared buffers | Copy on every pass | Use `Bytes` |
| `Arc<RwLock<HashMap>>` contention | Lock bouncing | `DashMap` |
| `#[inline]` everywhere | Code bloat | Profile, inline selectively |
| No LTO in release | Missed cross-crate optimization | `lto = "fat"` |

## Essential Crates

- `criterion` -- Statistical benchmarking
- `bytes` -- Zero-copy byte buffers
- `rayon` -- Data parallelism
- `dashmap` -- Lock-free concurrent HashMap
- `quick_cache` -- Bounded concurrent LRU cache
- `parking_lot` -- Faster mutexes
- `smallvec` -- Stack allocation for small vecs
- `arrayvec` -- Fixed-capacity stack vec
- `bumpalo` -- Arena allocator
- `compact_str` -- Small string optimization
- `lasso` -- String interning
- `indexmap` -- Insertion-ordered hash map
- `tikv-jemallocator` / `mimalloc` -- Alternative allocators
- `cargo-pgo` -- Profile-guided optimization
