---
name: rfr-no-std
description: Use when writing no_std or embedded Rust crates, adding an optional `std` (or `alloc`) feature to a library, choosing between core, alloc and std, defining a global allocator, panic handler or out-of-memory behaviour, accessing memory-mapped registers with volatile reads and writes, designing misuse-resistant hardware abstractions, or cross-compiling and checking a crate for a bare-metal target.
---

# Rust for Rustaceans, Ch 12: Rust Without the Standard Library

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## Opting Out of the Standard Library

Source: RfR Ch 12 "Opting Out of the Standard Library" (TOC p. 212); RfR Ch 12 index "core library", "alloc library" (p. 212), "preludes" (p. 213); Rust API Guidelines C-FEATURE

std is three layers:

| Crate | Needs | Gives |
|---|---|---|
| `core` | nothing | primitives, `Option`/`Result`, iterators, `fmt`, atomics, `ptr`, `cell`, `core::error::Error` (stable since 1.81), `core::ffi` |
| `alloc` | a global allocator | `Box`, `Vec`, `String`, `Rc`/`Arc`, `BTreeMap`, `format!` |
| `std` | an operating system | I/O, files, networking, threads, time, env, `HashMap` (its default hasher needs OS randomness), `Mutex` |

`#![no_std]` on the crate root links only `core` and swaps the std prelude for the core
prelude. `alloc` items must be imported explicitly (`use alloc::vec::Vec;`).

A library that works without std should still offer std integration behind a feature.
C-FEATURE prescribes the shape: the feature is named `std` (never `use-std`, `with-std`,
or a negative `no-std`, since features must be additive) and is on by default:

```toml
[features]
default = ["std"]
std = ["alloc"]
alloc = []
```

```rust
#![no_std]

// Do: the C-FEATURE form. Paths stay `core::`/`alloc::` in every build, and `std` is
// pulled in only where it adds something.
#[cfg(feature = "std")]
extern crate std;

#[cfg(feature = "alloc")]
extern crate alloc;

use core::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    position: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid digit at byte {}", self.position)
    }
}

// `core::error::Error` needs no `std` feature gate (Rust 1.81+).
impl core::error::Error for ParseError {}

/// Works everywhere: no allocation.
pub fn parse_digits(input: &[u8], out: &mut [u8]) -> Result<usize, ParseError> {
    let mut n = 0;
    for (position, (&byte, slot)) in input.iter().zip(out.iter_mut()).enumerate() {
        if !byte.is_ascii_digit() {
            return Err(ParseError { position });
        }
        *slot = byte - b'0';
        n += 1;
    }
    Ok(n)
}

/// Needs a heap.
#[cfg(feature = "alloc")]
pub fn parse_digits_vec(input: &[u8]) -> Result<alloc::vec::Vec<u8>, ParseError> {
    let mut out = alloc::vec![0; input.len()];
    let n = parse_digits(input, &mut out)?;
    out.truncate(n);
    Ok(out)
}

/// Needs an OS.
#[cfg(feature = "std")]
pub fn parse_file(path: &std::path::Path) -> std::io::Result<std::vec::Vec<u8>> {
    let bytes = std::fs::read(path)?;
    parse_digits_vec(&bytes).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}
```

The common alternative, `#![cfg_attr(not(feature = "std"), no_std)]`, also works but
makes the prelude and paths differ between builds, so code that compiles with `std` can
fail without it.

Dependencies follow the same rule: depend with `default-features = false` and forward
your `std` feature (`std = ["alloc", "dep-name/std"]`), or one dependency's default
`std` feature silently pulls std back in.

## Dynamic Memory Allocation

Source: RfR Ch 12 "Dynamic Memory Allocation" (TOC p. 213); RfR Ch 12 index "global_allocator" (pp. 214, 216-217); RfR Ch 9 index "GlobalAlloc trait" (pp. 151-152); std docs `GlobalAlloc`; Rust Reference "The global_allocator attribute"

Using `alloc` without std requires exactly one `#[global_allocator]` in the final
binary's crate graph: a `static` whose type implements `unsafe trait GlobalAlloc`. Put it
in the binary, not in a library, so the application chooses. The trait's contract (std
docs), which the `unsafe impl` promises to keep:

1. The allocator never reads, writes or frees memory that is currently allocated.
2. No method unwinds (a panic out of an allocator is undefined behaviour).
3. Each method keeps its documented contract; for `alloc`, the returned block fits
   `layout` (size and alignment) or is null. Null means out of memory or an unsupported
   layout.

A minimal bump allocator over a static buffer (it never frees; production code uses a
maintained allocator crate such as `embedded-alloc`):

```rust
#![no_std]

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::ptr;
use core::sync::atomic::{AtomicUsize, Ordering};

const HEAP_SIZE: usize = 64 * 1024;

pub struct BumpAllocator {
    heap: UnsafeCell<[u8; HEAP_SIZE]>,
    /// Offset of the first unreserved byte. Only grows.
    next: AtomicUsize,
}

// SAFETY: the heap is reached only through pointers returned by `alloc`, and the
// compare-exchange on `next` hands out each byte range at most once, so no two threads
// ever get overlapping memory.
unsafe impl Sync for BumpAllocator {}

// SAFETY: (1) every returned range lies past the old `next`, so it never overlaps a
// live allocation, and nothing else touches the heap; (2) no method can panic: all
// arithmetic is checked and failure returns null; (3) returned blocks are aligned to
// `layout.align()` and hold `layout.size()` bytes inside the heap.
unsafe impl GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let base = self.heap.get().cast::<u8>();
        let mut current = self.next.load(Ordering::Relaxed);
        loop {
            let Some(aligned) = base.addr().checked_add(current)
                .and_then(|a| a.checked_next_multiple_of(layout.align()))
            else {
                return ptr::null_mut();
            };
            let start = aligned - base.addr();
            let Some(end) = start.checked_add(layout.size()).filter(|&e| e <= HEAP_SIZE) else {
                return ptr::null_mut();
            };
            match self.next.compare_exchange_weak(current, end, Ordering::Relaxed, Ordering::Relaxed) {
                // SAFETY: `start <= end <= HEAP_SIZE`, so the offset stays inside the heap.
                Ok(_) => return unsafe { base.add(start) },
                Err(actual) => current = actual,
            }
        }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // A bump allocator never reuses memory.
    }
}

#[global_allocator]
static ALLOCATOR: BumpAllocator = BumpAllocator {
    heap: UnsafeCell::new([0; HEAP_SIZE]),
    next: AtomicUsize::new(0),
};
```

`Relaxed` is enough here: `next` only reserves ranges; it publishes no data that another
thread reads.

## The Rust Runtime

Source: RfR Ch 12 "The Rust Runtime" (TOC p. 215), "The Panic Handler" (TOC p. 215), "Program Initialization" (TOC p. 216), "The Out-of-Memory Handler" (TOC p. 216); RfR Ch 12 index "#[panic_handler] attribute", "#![no_main] attribute", "#[lang_start] attribute" (p. 216); Rust Reference "Panics"; std docs `handle_alloc_error`; Rust 1.68 release notes

**Panic handler.** A `no_std` binary (or `cdylib`/`staticlib`) must define exactly one
function `fn(&PanicInfo) -> !` marked `#[panic_handler]` in its dependency graph. Like the
allocator, it belongs in the binary; a library that defines one cannot be used with std
or with a different handler. Embedded crates such as `panic-halt` or `panic-probe` provide
ready-made handlers.

```rust
#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    // Halt. A real handler might log `info` over a debug probe or reset the chip.
    loop {
        core::hint::spin_loop();
    }
}
```

Bare-metal targets such as `thumbv7m-none-eabi` default to the abort panic strategy; there
is no unwinder.

**Program initialization.** With std, the runtime (`lang_start`) sets things up and calls
`main`. Bare-metal programs have no such runtime: they use `#![no_main]` and a runtime
crate for the target (for Cortex-M, `cortex-m-rt`) whose reset handler initializes
`.data`/`.bss` and then calls your entry function.

```rust,ignore
// ignore: needs a thumbv7m target and the cortex-m-rt and panic-halt crates.
#![no_std]
#![no_main]

use cortex_m_rt::entry;
use panic_halt as _; // links the panic handler

#[entry]
fn main() -> ! {
    loop {}
}
```

**Out-of-memory handler.** When an allocation fails, `alloc` calls `handle_alloc_error`.
With std it prints a message and aborts. Since Rust 1.68, if every crate is `no_std`, it
calls `panic!` instead, so the panic handler sees OOM. A custom `#[alloc_error_handler]`
still requires nightly (feature `alloc_error_handler`, tracking issue #51540). To handle
OOM as a value, use the fallible APIs: `Vec::try_reserve`, `String::try_reserve`.

## Low-Level Memory Accesses

Source: RfR Ch 12 "Low-Level Memory Accesses" (TOC p. 217); RfR Ch 12 index "memory mapping" (p. 217); RfR Ch 9 index "read_volatile function", "write_volatile function" (p. 150); core docs `ptr::read_volatile`, `ptr::write_volatile`

Device registers are memory-mapped: reading or writing an address has side effects. The
compiler may remove, merge or reorder ordinary loads and stores (a second read of the same
address "cannot" differ; a write never read back "is" dead). Volatile accesses are never
elided and keep their order relative to other volatile accesses.

- Use `ptr::read_volatile`/`write_volatile` (or the pointer methods) for every register
  access.
- Do not create `&`/`&mut` to device memory: a reference tells the compiler the memory is
  ordinary and dereferenceable, so it may read it at any time. Keep raw pointers.
- Volatile is not atomic and does not synchronize threads or interrupts. Use atomics or a
  critical section for that.
- For MMIO the address may lie outside every Rust allocation; build the pointer with
  `ptr::without_provenance_mut(addr)` (provenance is irrelevant for such accesses, per the
  `read_volatile` docs).

```rust
#![no_std]

use core::ptr;

/// A 32-bit memory-mapped register.
pub struct Reg32 {
    addr: *mut u32,
}

impl Reg32 {
    /// # Safety
    ///
    /// 1. `addr` is the 4-byte-aligned address of a 32-bit device register that stays
    ///    mapped for the rest of the program.
    /// 2. Reading or writing it does not trap and does not modify memory inside any Rust
    ///    allocation.
    pub const unsafe fn new(addr: usize) -> Self {
        Self { addr: ptr::without_provenance_mut(addr) }
    }

    pub fn read(&self) -> u32 {
        // SAFETY: `Reg32::new` preconditions 1 and 2 are exactly what `read_volatile`
        // requires for memory outside Rust allocations.
        unsafe { self.addr.read_volatile() }
    }

    pub fn write(&mut self, value: u32) {
        // SAFETY: same argument as `read`, with `write_volatile`.
        unsafe { self.addr.write_volatile(value) }
    }
}
```

In practice, generate register types from the vendor's SVD file with `svd2rust`, which
produces this pattern plus field accessors.

## Misuse-Resistant Hardware Abstraction

Source: RfR Ch 12 "Misuse-Resistant Hardware Abstraction" (TOC p. 219); The Embedded Rust Book, "Peripherals" and "Static Guarantees" (https://docs.rust-embedded.org/book/)

Use ownership and types to make invalid hardware use fail to compile:

- **Peripherals are singletons.** A `take()` function hands out the peripheral struct at
  most once; after that, holding the value is the permission to use the hardware, and
  `&mut` gives exclusive access.
- **Configuration is type state.** A pin's mode is a type parameter; `set_high` exists
  only on output pins, and changing mode consumes the old value.

```rust
#![no_std]

use core::marker::PhantomData;
use core::sync::atomic::{AtomicBool, Ordering};

pub struct Input;
pub struct Output;

/// GPIO pin `N` in mode `Mode`. Fields are private, so only this crate creates pins.
pub struct Pin<const N: u8, Mode> {
    _mode: PhantomData<Mode>,
}

impl<const N: u8> Pin<N, Input> {
    pub fn into_output(self) -> Pin<N, Output> {
        // Write the direction register here (volatile).
        Pin { _mode: PhantomData }
    }
}

impl<const N: u8> Pin<N, Output> {
    pub fn set_high(&mut self) {
        // Write the output-set register here (volatile).
    }

    pub fn into_input(self) -> Pin<N, Input> {
        Pin { _mode: PhantomData }
    }
}

pub struct Peripherals {
    pub led: Pin<5, Input>,
    pub button: Pin<6, Input>,
}

static TAKEN: AtomicBool = AtomicBool::new(false);

impl Peripherals {
    /// Returns the peripherals the first time it is called, `None` afterwards.
    pub fn take() -> Option<Self> {
        if TAKEN.swap(true, Ordering::AcqRel) {
            return None;
        }
        Some(Self {
            led: Pin { _mode: PhantomData },
            button: Pin { _mode: PhantomData },
        })
    }
}
```

`AtomicBool::swap` needs compare-and-swap support. Targets without it (for example
`thumbv6m-none-eabi`) use a critical section instead. `cfg(target_has_atomic = "8")` is
false on such targets, so gate on it if the crate supports both.

## Cross-Compilation

Source: RfR Ch 12 "Cross-Compilation" (TOC p. 220); RfR Ch 12 index "target triples", "host platform", "target platform" (p. 221); RfR errata print01-ch12-cross-compile.md; jonhoo/rust-ci-conf .github/workflows/nostd.yml

- The **host** runs the compiler; the **target** runs the output. A target triple names
  the target as architecture-vendor-OS(-ABI): `x86_64-unknown-linux-gnu`,
  `thumbv7m-none-eabi` (Cortex-M3, no OS), `aarch64-unknown-none`.
- `rustup target add thumbv7m-none-eabi` installs the precompiled `core` and `alloc` for
  that target. OS-less targets have no `std`, so any accidental `std` use fails to build.
- `cargo build --target thumbv7m-none-eabi`, or set `[build] target = "..."` (and the
  linker and runner) in `.cargo/config.toml` of the firmware crate.
- Targets without precompiled libraries need nightly `-Zbuild-std`.
- Keep logic host-testable: with the `std` feature on, `cargo test` runs on the host;
  only the thin hardware layer needs the target.

CI for a library that claims `no_std` support, as in rust-ci-conf's `nostd.yml`, which
runs this for `thumbv7m-none-eabi` and `aarch64-unknown-none`:

```bash
rustup target add thumbv7m-none-eabi
cargo check --target thumbv7m-none-eabi --no-default-features
```

`--no-default-features` turns off `std`; checking on a target that has no std proves no
dependency pulls it back in. A host build with `--no-default-features` does not prove
that, because std is available there.

## Common Mistakes

Source: general Rust practice (not from the book)

1. **A feature named `no_std` or `use-std`**: features must be additive; name it `std`.
2. **A dependency left on its default features**: it drags std in; use
   `default-features = false` and forward `std`.
3. **`#[panic_handler]` or `#[global_allocator]` in a library**: it conflicts with every
   other choice; leave both to the binary.
4. **Plain reads and writes of device registers**: use volatile accesses and raw pointers.
5. **Using volatile for synchronization**: it is not atomic.
6. **Only checking `--no-default-features` on the host**: check on a std-less target.
7. **Panicking or unwinding inside a `GlobalAlloc` method**: undefined behaviour.
