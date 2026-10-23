---
name: rfr-types
description: Use when reasoning about Rust type layout, alignment, padding, repr attributes, wide pointers and DSTs, static vs dynamic dispatch and monomorphization cost, dyn compatibility, coherence and the orphan rule, trait bounds and HRTBs, impl Trait, PhantomData, or marker and auto traits. Use when hitting orphan-rule, dyn-compatibility, or Sized errors.
---

# Rust for Rustaceans, Ch 2: Types

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## Alignment, layout, and repr

Source: RfR Ch 2 "Alignment", "Layout" (TOC pp. 20-21); RfR Ch 2 index "padding" (p. 22); https://doc.rust-lang.org/reference/type-layout.html

- Every type has a size and an alignment; alignment is a power of two, and size is a
  multiple of alignment. A struct's alignment is at least the largest field alignment, and
  padding fills the gaps.
- The default (`repr(Rust)`) layout makes no promises: the compiler may reorder fields to
  reduce padding. Never rely on it for FFI, transmutes, or pointer arithmetic.

| Repr | Guarantee | Use for |
|------|-----------|---------|
| default | none | normal Rust types |
| `repr(C)` | fields in declaration order with C padding rules | FFI, stable layouts |
| `repr(transparent)` | same layout and ABI as the one non-ZST field | FFI newtypes |
| `repr(u8)` etc. on enums | fixed discriminant type | FFI, `as` casts of discriminants |
| `repr(packed)` | no padding, alignment 1 (or N) | wire formats; fields may be unaligned |
| `repr(align(N))` | alignment at least N | keeping hot data on separate cache lines |

```rust
#[repr(C)]
struct Header {
    version: u8,   // offset 0
    _pad: [u8; 3], // offset 1, explicit
    length: u32,   // offset 4
}

#[repr(transparent)]
struct UserId(u64); // same ABI as u64

assert_eq!(std::mem::size_of::<Header>(), 8);
```

### Packed fields

Taking a reference to a field of a `repr(packed)` struct is a compile error, because the
reference could be unaligned (https://doc.rust-lang.org/reference/behavior-considered-undefined.html).

```rust,compile_fail
// Does not compile: E0793, reference to a field of a packed struct.
#[repr(C, packed)]
struct Wire { tag: u8, len: u32 }

let w = Wire { tag: 1, len: 7 };
let r: &u32 = &w.len;
```

Copy the field out (`let len = w.len;`), or take a raw pointer with `&raw const w.len`
(stable since 1.82) and read it with `read_unaligned`:

```rust
#[repr(C, packed)]
struct Wire { tag: u8, len: u32 }

let w = Wire { tag: 1, len: 7 };
let len = w.len; // Do: by-value copy is fine
let p = &raw const w.len;
// SAFETY: `p` points into `w`, which is alive and initialized for this whole block;
// `read_unaligned` has no alignment requirement.
let via_ptr = unsafe { p.read_unaligned() };
assert_eq!((len, via_ptr), (7, 7));
```

### False sharing

Source: RfR Ch 2 index "false sharing" (p. 23); RfR Ch 10 "Performance" (TOC p. 169)

Two values written by different threads that share a cache line make the cores fight over
that line. `repr(align(N))` on a wrapper puts each value on its own line. The line size is
target-specific; `crossbeam_utils::CachePadded` chooses it per target. Add padding only
when a benchmark shows contention.

```rust
#[repr(align(64))] // 64 is common on x86-64; check your target
struct Padded<T>(T);

struct Counters {
    produced: Padded<std::sync::atomic::AtomicU64>,
    consumed: Padded<std::sync::atomic::AtomicU64>,
}

assert_eq!(std::mem::align_of::<Padded<u8>>(), 64);
```

## Dynamically sized types and wide pointers

Source: RfR Ch 2 "Dynamically Sized Types and Wide Pointers" (TOC p. 23)

- `Sized` is an implicit bound on every type parameter. DSTs (`str`, `[T]`, `dyn Trait`)
  are not `Sized` and live only behind a pointer.
- A pointer to a DST is wide: data pointer plus metadata (a length for slices and `str`, a
  vtable pointer for `dyn Trait`).
- `T: ?Sized` lifts the implicit bound, so `&T`/`Box<T>` can hold a DST.

```rust
fn byte_len<T: ?Sized + AsRef<[u8]>>(t: &T) -> usize {
    t.as_ref().len()
}

assert_eq!(byte_len("hey"), 3); // T = str, unsized
assert_eq!(std::mem::size_of::<&[u8]>(), 2 * std::mem::size_of::<usize>());
```

### Zero-sized types

Source: RfR Ch 2 index "marker types" (p. 34); RfR Ch 3 index "zero-sized types" (p. 49)

- Size 0: `()`, empty structs, `PhantomData<T>`, `[T; 0]`. Alignment is not always 1
  (`[u64; 0]` has the alignment of `u64`).
- No storage cost; `Vec<()>` never allocates. Useful as markers and type-level tags.

## Static vs dynamic dispatch

Source: RfR Ch 2 "Compilation and Dispatch" (TOC p. 24); index "monomorphization" (p. 25), "vtables" (p. 26)

| | Generics (`T: Trait`, `impl Trait`) | Trait objects (`&dyn Trait`, `Box<dyn Trait>`) |
|-|-------------------------------------|---------------------------------------------|
| Resolution | compile time, one copy per concrete type (monomorphization) | runtime, through a vtable |
| Cost | inlining possible; larger binary and longer compile time | indirect call, no inlining across it; one copy of the code |
| Use | hot paths, maximum flexibility for callers | heterogeneous collections, plugin points, cutting compile time |

For libraries this is an API trade-off: generic parameters let callers pick, but every
caller instantiation is compiled in their crate.

### Non-generic inner functions

Source: RfR errata print01-ch02-innerfunctions-instead.md; Rust API Guidelines C-GENERIC

Keep the generic part of a function to a thin conversion and delegate to a non-generic
inner function, so only the shim is monomorphized per type. `cargo llvm-lines` shows which
generic functions dominate the generated code.

```rust
use std::path::Path;

pub fn load(path: impl AsRef<Path>) -> std::io::Result<String> {
    fn inner(path: &Path) -> std::io::Result<String> {
        std::fs::read_to_string(path) // the large body is compiled once
    }
    inner(path.as_ref())
}
```

## Dyn compatibility (object safety)

Source: RfR Ch 2 index "object-safe traits" (p. 27); https://doc.rust-lang.org/reference/items/traits.html; Rust API Guidelines C-OBJECT

The Reference now calls this "dyn compatibility". A trait can be used as `dyn Trait` when:

1. All supertraits are dyn compatible, and `Sized` is not a supertrait.
2. It has no associated constants and no generic associated types.
3. Every method is either dispatchable or explicitly excluded with `where Self: Sized`.
   Dispatchable methods have no type parameters, use `Self` only in the receiver, take
   `&self`, `&mut self`, `Box<Self>`, `Rc<Self>`, `Arc<Self>`, or `Pin<P>` of those, and do
   not return `impl Trait` (so no `async fn`).

If a trait may be useful as a trait object, decide that up front and fence the
non-dispatchable methods with `where Self: Sized`, as `Iterator` does for its adapters.

```rust
trait Shape {
    fn area(&self) -> f64;

    // Excluded from the vtable, so `dyn Shape` stays possible.
    fn scaled(&self, k: f64) -> Self
    where
        Self: Sized;
}

struct Square(f64);
impl Shape for Square {
    fn area(&self) -> f64 { self.0 * self.0 }
    fn scaled(&self, k: f64) -> Self { Square(self.0 * k) }
}

let shapes: Vec<Box<dyn Shape>> = vec![Box::new(Square(2.0))];
assert_eq!(shapes[0].area(), 4.0);
```

```rust,compile_fail
// Does not compile: E0038, the generic method makes `Convert` not dyn compatible.
trait Convert {
    fn convert<T: From<u8>>(&self) -> T;
}

fn take(_: &dyn Convert) {}
```

## Generic traits: associated types vs type parameters

Source: RfR Ch 2 "Generic Traits" (TOC p. 28)

| | Associated type | Type parameter |
|-|-----------------|----------------|
| Syntax | `trait Iterator { type Item; }` | `trait From<T>` |
| Impls per type | one | one per `T` |
| Caller | type is inferred from the impl | may need to name `T` |
| Use when | there is one natural choice per implementing type | a type can sensibly implement it many times |

Default to an associated type; a type parameter forces callers to disambiguate whenever
more than one impl applies.

## Coherence and the orphan rule

Source: RfR Ch 2 "Coherence and the Orphan Rule" (TOC p. 28); index "covered implementations" (p. 30), "#[fundamental] attribute" (p. 30); RfR errata print01-ch02-covered-impl.md; https://doc.rust-lang.org/reference/items/implementations.html

- You may implement a trait if the trait or a type in the impl is local. Precisely, for
  `impl<P1..=Pn> ForeignTrait<T1..=Tn> for T0`: at least one `Ti` is local, and no
  uncovered type parameter `P` appears in `T0..Ti` before the first local one. "Covered"
  means wrapped in some other type, as in `Vec<P>`.
- `#[fundamental]` types (`&T`, `&mut T`, `Box<T>`, `Pin<T>`) do not cover: `Box<Local>` is
  local, and `impl<T> ForeignTrait for Box<T>` is an orphan.
- Blanket impls (`impl<T: Display> MyTrait for T`) are only possible for local traits, and
  adding one to a published trait breaks downstream crates that implemented the trait for
  their own types.
- To implement a foreign trait for a foreign type, wrap it in a newtype.

```rust
use std::fmt;

struct Local;

// Allowed: T0 = Vec<T> is foreign but `T` is covered; T1 = Local is the first local type.
impl<T> From<Local> for Vec<T> {
    fn from(_: Local) -> Self { Vec::new() }
}

// Newtype for a foreign trait on a foreign type.
struct CommaList(Vec<String>);
impl fmt::Display for CommaList {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0.join(", "))
    }
}
```

```rust,compile_fail
// Does not compile: E0210, uncovered `T` appears before any local type.
struct Local;
impl<T> From<Local> for T {
    fn from(_: Local) -> T { todo!() }
}
```

## Trait bounds

Source: RfR Ch 2 "Trait Bounds" (TOC p. 31); index "higher-ranked trait bounds" (p. 32), "#[derive(Trait)]" (p. 32)

- Bounds can be on any type, not just parameters: `where Vec<T>: Debug`, `where for<'a>
  &'a T: IntoIterator`. Bound what you use, which is sometimes an expression's type.
- Higher-ranked trait bounds (`for<'a>`) say "for every lifetime": needed when a closure or
  trait must accept references of a lifetime the caller picks per call. `Fn(&str) -> &str`
  is sugar for `for<'a> Fn(&'a str) -> &'a str`.
- `#[derive(Clone)]` on `struct S<T>` adds `T: Clone` to the impl even when no field needs
  it (for example `Rc<T>` fields or `PhantomData<T>`). Write the impl by hand if that bound
  is too strict.

```rust
fn apply<F>(f: F) -> usize
where
    F: for<'a> Fn(&'a str) -> &'a str,
{
    let owned = String::from("local data");
    f(&owned).len() // the closure works for this short-lived borrow
}

assert_eq!(apply(|s| &s[..5]), 5);
```

## Existential types (`impl Trait`)

Source: RfR Ch 2 "Existential Types" (TOC p. 34)

- `-> impl Trait` returns one concrete, unnamed type. Callers can use only the trait; you
  can change the concrete type without a breaking change (auto traits like `Send` still
  leak through and are part of the contract).
- It is static dispatch: no boxing, no vtable. It is required for returning closures and
  `async` blocks without boxing.
- Argument-position `impl Trait` is an anonymous generic parameter; callers cannot name it
  with turbofish.

```rust
fn evens(limit: u32) -> impl Iterator<Item = u32> {
    (0..limit).filter(|n| n % 2 == 0)
}

assert_eq!(evens(7).collect::<Vec<_>>(), [0, 2, 4, 6]);
```

## PhantomData

Source: RfR Ch 2 "Marker Traits" (TOC p. 33), index "marker types" (p. 34); https://doc.rust-lang.org/nomicon/phantom-data.html

`PhantomData<X>` makes a type act, for variance, auto traits, and drop check, as if it held
an `X`.

| Marker | Variance in `T` | `Send`/`Sync` | Use for |
|--------|-----------------|---------------|---------|
| `PhantomData<T>` | covariant | as `T` | owning a `T` through a raw pointer |
| `PhantomData<&'a T>` | covariant | needs `T: Sync` | borrowing for `'a` (iterators over raw pointers) |
| `PhantomData<*const T>` | covariant | neither | opting out of `Send` and `Sync` |
| `PhantomData<fn() -> T>` | covariant | always both | type tags that do not own a `T` |
| `PhantomData<fn(T)>` | contravariant | always both | rare |
| `PhantomData<fn(T) -> T>` | invariant | always both | forcing invariance |

With an ordinary `Drop` impl, `PhantomData<T>` adds nothing to the drop check (the impl
already counts as using `T`); it matters with `#[may_dangle]` (std containers) and for
variance and auto traits. Opt out of `Unpin` with `PhantomPinned`, not `PhantomData`.

```rust
use std::marker::PhantomData;

struct Locked;
struct Unlocked;

struct Door<State> {
    _state: PhantomData<fn() -> State>, // a tag, not ownership
}

impl Door<Locked> {
    fn unlock(self) -> Door<Unlocked> {
        Door { _state: PhantomData }
    }
}

impl Door<Unlocked> {
    fn open(&self) {}
}

let door = Door::<Locked> { _state: PhantomData }.unlock();
door.open();
```

## Marker and auto traits

Source: RfR Ch 2 "Marker Traits" (TOC p. 33); index "autotraits" (p. 33)

| Trait | Meaning | How a type gets it |
|-------|---------|--------------------|
| `Send` | ownership can move to another thread | auto: all fields `Send` |
| `Sync` | `&T` can be shared across threads (`T: Sync` iff `&T: Send`) | auto: all fields `Sync` |
| `Unpin` | may be moved after being pinned | auto: all fields `Unpin` |
| `Copy` | bitwise copy is a full copy | opt-in (`derive` or impl); needs `Clone`, no `Drop` |
| `Sized` | size known at compile time | implicit bound; lift with `?Sized` |

- `Rc<T>`: neither `Send` nor `Sync`. `Arc<T>`: both iff `T: Send + Sync`.
- `Cell<T>`, `RefCell<T>`: `Send` if `T: Send`, never `Sync`. `Mutex<T>`: both if
  `T: Send`. `MutexGuard`: not `Send`. Raw pointers and `NonNull`: neither.
- Auto traits are inferred, so a private field change can silently remove `Send` from a
  public type. Pin them with a compile-time test (see `rfr-designing-interfaces`).

Implementing `Send`/`Sync` by hand is `unsafe`; the `// SAFETY:` comment must say why
sharing or moving is sound:

```rust
use std::ptr::NonNull;

/// Uniquely owns a heap-allocated `T` through a raw pointer.
struct OwnedPtr<T> {
    ptr: NonNull<T>, // NonNull makes the type !Send and !Sync by default
}

impl<T> OwnedPtr<T> {
    fn new(value: T) -> Self {
        Self { ptr: NonNull::from(Box::leak(Box::new(value))) }
    }

    fn get(&self) -> &T {
        // SAFETY: `ptr` came from `Box::leak` in `new`, is never freed before `drop`, and
        // no `&mut T` is ever handed out, so a shared borrow tied to `&self` is valid.
        unsafe { self.ptr.as_ref() }
    }
}

impl<T> Drop for OwnedPtr<T> {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from a `Box` in `new`, and `drop` runs once, so we
        // reclaim that allocation exactly once.
        drop(unsafe { Box::from_raw(self.ptr.as_ptr()) });
    }
}

// SAFETY: `OwnedPtr` is the only pointer to its `T` (no clones, the pointer is never
// exposed), so sending it to another thread moves the `T`, which is sound when `T: Send`.
unsafe impl<T: Send> Send for OwnedPtr<T> {}
// SAFETY: through `&OwnedPtr<T>` callers only get `&T` (`get`), so sharing it is sound
// exactly when sharing `&T` is, i.e. `T: Sync`.
unsafe impl<T: Sync> Sync for OwnedPtr<T> {}

let p = OwnedPtr::new(5);
std::thread::scope(|s| {
    s.spawn(|| assert_eq!(*p.get(), 5));
});
```

## Common mistakes

Source: general Rust practice (not from the book)

1. Relying on default (`repr(Rust)`) field order or size across compiler versions.
2. Referencing `repr(packed)` fields (compile error); copy them or use `&raw const` plus
   `read_unaligned`.
3. Raw-pointer types without the right `PhantomData`, giving the wrong variance or auto
   traits.
4. A type parameter on a trait where an associated type would do, forcing callers to annotate.
5. Large generic functions with no non-generic core, bloating every caller's binary.
6. Adding a generic method to a trait used as `dyn Trait` without `where Self: Sized`.
7. `unsafe impl Send/Sync` without an argument about what the type actually shares.
