---
name: rfr-unsafe-code
description: Use when writing or reviewing unsafe Rust: raw pointers, casts and provenance, MaybeUninit, UnsafeCell, unsafe fn and unsafe trait contracts, SAFETY comments. Use when reasoning about soundness, validity, panic safety, the drop check, or the privacy boundary, and when running Miri or sanitizers.
---

# Rust for Rustaceans, Ch 9: Unsafe Code

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## The unsafe keyword

Source: RfR Ch 9 "The unsafe Keyword" (TOC p. 142); RfR Ch 9 index "RFC 2585" (p. 143); https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-op-in-unsafe-fn.html

- `unsafe` on a **declaration** (`unsafe fn`, `unsafe trait`) states a contract the caller
  or implementer must uphold. Document it under `# Safety`.
- `unsafe` on a **block** or **impl** says "I have checked that contract here". The
  `// SAFETY:` comment above it is that check, written down.
- The body of an `unsafe fn` is not an unsafe block (RFC 2585). Each unsafe operation inside
  needs its own `unsafe {}` and `// SAFETY:`. The `unsafe_op_in_unsafe_fn` lint warns by
  default in edition 2024; house style denies it.
- `unsafe` never turns off the borrow checker or type checking. It only unlocks the
  operations below.

## What unsafe unlocks

Source: RfR Ch 9 "Great Power" (TOC p. 144); https://doc.rust-lang.org/reference/unsafety.html; https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-extern.html; https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-attributes.html

| Operation | Notes |
|---|---|
| Dereference a raw pointer | `*const T`, `*mut T` |
| Call an `unsafe fn` | Includes items of an `unsafe extern` block not marked `safe` |
| Read or write a `static mut` or an extern static | Edition 2024 denies references to `static mut` (`static_mut_refs`); use atomics, `Mutex`, or `&raw` |
| Read a union field | Only the field whose bytes are valid for its type |
| Implement an `unsafe trait` | `Send`, `Sync`, `GlobalAlloc`, your own |
| Declare an `unsafe extern` block (edition 2024) | The block asserts the signatures are correct; items may be marked `safe fn` |
| Use an unsafe attribute (edition 2024) | `#[unsafe(no_mangle)]`, `#[unsafe(export_name = "..")]`, `#[unsafe(link_section = "..")]` |

## Raw pointers, casts and provenance

Source: RfR Ch 9 "Juggling Raw Pointers" (TOC p. 144); RfR Ch 9 index "pointer casting" (p. 147), "raw references" (p. 156), "RFC 2582" (p. 156); https://blog.rust-lang.org/2024/10/17/Rust-1.82.0/; https://blog.rust-lang.org/2025/01/09/Rust-1.84.0/

- Creating a raw pointer is safe; reading or writing through one is not. A raw pointer may
  be null, dangling, unaligned, or point to uninitialised memory.
- Make pointers without an intermediate reference: `&raw const place` / `&raw mut place`
  (stable since 1.82, replaces `ptr::addr_of!`). This is the only way to point at a
  misaligned `repr(packed)` field or at uninitialised memory.
- Change the pointee type with `ptr.cast::<U>()`, and mutability with `cast_mut` /
  `cast_const`. Avoid `as` for pointer-to-pointer casts (clippy `ptr_as_ptr`,
  `ptr_cast_constness`).
- **Provenance**: a pointer carries the right to access one allocation, not just an
  address. Since 1.84 the strict provenance APIs are stable: `ptr.addr()`,
  `ptr.with_addr(a)`, `ptr.map_addr(f)` keep provenance while changing the address;
  `ptr::without_provenance(a)` makes a pointer that must never be dereferenced (a
  sentinel); `expose_provenance` / `with_exposed_provenance` are the explicit
  integer round trip for code that truly needs it. Avoid `usize as *const T`.
- `NonNull<T>` is a non-null, covariant `*mut T`; `Option<NonNull<T>>` is pointer-sized
  (niche optimization, index pp. 145, 156).

```rust
use std::ptr;

fn main() {
    let mut x: u32 = 0;
    let p: *mut u32 = &raw mut x;

    // SAFETY: `p` points to the live local `x`, is aligned for u32, and no reference to
    // `x` exists while we write.
    unsafe { p.write(7) };

    // Tag the low bit: u32 is 4-aligned, so bit 0 of a valid address is always 0.
    // map_addr keeps p's provenance, so the untagged pointer may be dereferenced again.
    let tagged = p.map_addr(|a| a | 1);
    let untagged = tagged.map_addr(|a| a & !1);
    assert_eq!(untagged, p);

    // SAFETY: `untagged` equals `p` with the same provenance; `x` is still live and
    // initialised (written above).
    let v = unsafe { untagged.read() };
    assert_eq!(v, 7);

    // A sentinel address that is never dereferenced: no provenance needed.
    let sentinel: *const u8 = ptr::without_provenance(usize::MAX);
    assert!(!sentinel.is_null());

    let bytes = p.cast::<u8>();
    // SAFETY: u8 has alignment 1 and `bytes` points at the first byte of the 4-byte,
    // initialised `x`.
    let first = unsafe { bytes.read() };
    assert_eq!(first, u32::to_ne_bytes(7)[0]);
}
```

**Casting rules** (general practice; book index "casting", pp. 159-160):

- A pointer cast does not make the target valid. The result must be aligned for `U`, in
  bounds of the allocation, and the bytes must be a valid `U`.
- Prefer safe conversions to `transmute`: `u32::from_ne_bytes`, `f32::to_bits`,
  `bytemuck`/`zerocopy` for checked plain-old-data casts. `transmute` needs equal sizes and
  a valid bit pattern for the target type.
- `as` between integers silently truncates or wraps. Use `From`/`TryFrom` where a lossy
  cast is not intended.
- Layout is only defined for `#[repr(C)]`, `#[repr(transparent)]` and primitive reprs.
  Casting `*const Foo` to `*const Bar` for `repr(Rust)` types assumes a layout the
  compiler does not promise.

## Calling unsafe functions and writing them

Source: RfR Ch 9 "Calling Unsafe Functions" (TOC p. 147); RfR Ch 9 "Read and Write Documentation" (TOC p. 164); Rust API Guidelines C-VALIDATE; https://doc.rust-lang.org/reference/unsafe-keyword.html

- The book's tour of std's unsafe functions (index pp. 148-150) includes
  `ptr::drop_in_place`, `ManuallyDrop::drop`, `MaybeUninit::assume_init`,
  `hint::unreachable_unchecked`, `Waker::from_raw`, `ptr::read_unaligned` /
  `write_unaligned`, `ptr::read_volatile` / `write_volatile`, and
  `thread::Builder::spawn_unchecked`. Read each one's `# Safety` section before calling it.
- A public `unsafe fn` is a legitimate API when callers can check a precondition you cannot
  check cheaply: name it `_unchecked` next to a checked safe version (C-VALIDATE), and list
  the preconditions as a numbered `# Safety` section. Callers discharge them by number.
- A safe function must be sound for **every** input. If it is not, mark it `unsafe` or add
  the check. A `debug_assert!` alone is not a check: it is compiled out in release builds.

```rust
/// Returns the byte at `idx` without a bounds check.
///
/// # Safety
///
/// 1. `idx < bytes.len()`.
pub unsafe fn byte_unchecked(bytes: &[u8], idx: usize) -> u8 {
    debug_assert!(idx < bytes.len(), "caller broke precondition 1");
    // SAFETY:
    // 1. Same as our caller's precondition 1, which is exactly get_unchecked's bound.
    unsafe { *bytes.get_unchecked(idx) }
}

/// Checked version: sound for every input.
pub fn byte(bytes: &[u8], idx: usize) -> Option<u8> {
    if idx < bytes.len() {
        // SAFETY:
        // 1. `idx < bytes.len()` was checked on the line above.
        Some(unsafe { byte_unchecked(bytes, idx) })
    } else {
        None
    }
}

fn main() {
    assert_eq!(byte(b"ab", 1), Some(b'b'));
    assert_eq!(byte(b"ab", 2), None);
}
```

Avoid: a *safe* `pub fn byte(bytes: &[u8], idx: usize) -> u8` that calls
`get_unchecked` with no check (or only a `debug_assert!`). Any safe caller can pass an
out-of-bounds index, so the function is unsound even if every current caller is careful.

## Implementing unsafe traits

Source: RfR Ch 9 "Implementing Unsafe Traits" (TOC p. 151); RfR Ch 9 index "GlobalAlloc trait" (pp. 151-152), "Unpin" (pp. 152-153)

- An `unsafe trait` is one where a wrong implementation lets *other* code cause UB
  (`Send`, `Sync`, `GlobalAlloc`). Its `# Safety` section lists what implementers promise;
  each `unsafe impl` has a `// SAFETY:` comment showing it holds.
- `Unpin` is a safe auto trait: implementing it wrongly can only break code that relies on
  it through `unsafe` pin projection, which is that code's responsibility.

```rust
/// A type whose bytes are a contiguous, initialised buffer.
///
/// # Safety
///
/// 1. `as_ptr` returns a pointer valid for reads of `len()` initialised bytes.
/// 2. The pointer and length stay valid until the next `&mut self` method call.
pub unsafe trait ByteBuffer {
    fn as_ptr(&self) -> *const u8;
    fn len(&self) -> usize;
}

// SAFETY:
// 1. Vec::as_ptr points at its first element and the first `len` elements are
//    initialised (Vec's own invariant).
// 2. Only `&mut self` methods of Vec can reallocate or shrink it.
unsafe impl ByteBuffer for Vec<u8> {
    fn as_ptr(&self) -> *const u8 {
        Vec::as_ptr(self)
    }
    fn len(&self) -> usize {
        Vec::len(self)
    }
}

fn main() {}
```

## What can go wrong: undefined behaviour

Source: RfR Ch 9 "What Can Go Wrong?" (TOC p. 154); https://doc.rust-lang.org/reference/behavior-considered-undefined.html

UB is not "a crash": the compiler may assume it never happens, so code before and after it
can be miscompiled. Write against what the language guarantees, not what today's compiler
does (RfR Ch 1, p. 10). The Reference's list (not exhaustive) includes:

| UB | Example |
|---|---|
| Data race | Two threads, at least one writing, no synchronisation |
| Access through a dangling or misaligned pointer | Read via a pointer to a freed `Box`; `p.cast::<u64>().read()` on a 1-aligned address |
| Out-of-bounds pointer arithmetic | `ptr.add(n)` past one-past-the-end |
| Breaking aliasing rules | Mutating behind a live `&T` (outside `UnsafeCell`), two live `&mut T` to one place |
| Mutating immutable bytes | Writing to a non-`mut` static or through a pointer derived from `&T` |
| Producing an invalid value | `bool` other than 0/1, `char` surrogate, bad enum discriminant, null or misaligned reference, uninitialised integer |
| Wrong ABI or unwinding where not allowed | Calling a `"C-unwind"` fn through a `"C"` pointer and unwinding |
| Executing code for unsupported target features | `#[target_feature]` fn on a CPU without the feature |

Infinite loops without side effects are **not** UB in Rust (unlike C++).

## Validity: values must always be valid

Source: RfR Ch 9 "Validity" (TOC p. 155); RfR Ch 9 index "MaybeUninit<T> type" (pp. 157-158); errata print01-ch09-mut-ptr-through-shared.md

- **Validity invariant**: what the compiler relies on for every value at all times (a
  `bool` is 0 or 1, a reference is non-null, aligned and not dangling). Breaking it is
  immediate UB, even if the value is never read again.
- **Safety invariant**: what a type's own API relies on (a `String` holds UTF-8; a `Vec`'s
  first `len` elements are initialised). Unsafe code inside the type may break it briefly,
  but it must hold again before any safe code, including a panic unwinding, can observe
  the value.
- Uninitialised memory lives only in `MaybeUninit<T>` (or a union). Never create a
  `&T`/`&mut T` to it, and never `set_len` over unwritten capacity and then slice it.
- `&` does not make data behind a stored raw pointer immutable: `&self` on a struct holding
  a `*mut T` does not forbid writing through that pointer. Whether doing so is sound
  depends on the type's own invariant (errata above).

```rust
use std::mem::MaybeUninit;

fn main() {
    // Do: inline const makes an array of uninit slots for any T (no `T: Copy` needed).
    let mut slots = [const { MaybeUninit::<String>::uninit() }; 3];
    for (i, slot) in slots.iter_mut().enumerate() {
        slot.write(i.to_string());
    }
    let names: [String; 3] = slots.map(|s| {
        // SAFETY: the loop above wrote every one of the 3 slots exactly once.
        unsafe { s.assume_init() }
    });
    assert_eq!(names[2], "2");
}
```

If `to_string` panicked mid-loop, the strings written so far would leak (a `MaybeUninit`
never drops its contents). Leaking is safe; reading or dropping an unwritten slot is not.

## Interior mutability with UnsafeCell

Source: RfR Ch 1 "Interior Mutability" (TOC p. 12); https://doc.rust-lang.org/src/core/cell.rs.html (`Cell::set` is `self.replace(val)`)

- `UnsafeCell<T>` is the only legal way to mutate through a shared reference. `Cell`,
  `RefCell`, `Mutex`, and the atomics are built on it.
- It makes the containing type invariant in `T` and `!Sync`.
- Drop the old value only after your own borrow of the cell has ended: a `Drop` impl can
  re-enter the cell. That is why std's `Cell::set` is `self.replace(val)`, which returns
  the old value and drops it after the write.

```rust
use std::cell::UnsafeCell;

/// A minimal `Cell`. It never hands out references into the cell, and UnsafeCell makes it
/// `!Sync`, so all access is from one thread and never overlaps.
pub struct MyCell<T> {
    value: UnsafeCell<T>,
}

impl<T> MyCell<T> {
    pub fn new(value: T) -> Self {
        Self { value: UnsafeCell::new(value) }
    }

    pub fn replace(&self, val: T) -> T {
        // SAFETY: MyCell is !Sync, so no other thread can reach `value`. No method returns
        // a reference into the cell, and `mem::replace` runs no user code, so this `&mut`
        // is the only reference to the contents while it lives.
        unsafe { std::mem::replace(&mut *self.value.get(), val) }
    }

    pub fn set(&self, val: T) {
        // The old value is dropped here, after the `&mut` in `replace` has ended, so its
        // Drop may call back into this cell.
        drop(self.replace(val));
    }

    pub fn get(&self) -> T
    where
        T: Copy,
    {
        // SAFETY: same argument as `replace`: single-threaded and no reference into the
        // cell is live, so reading a copy cannot overlap a write.
        unsafe { *self.value.get() }
    }
}

fn main() {
    let c = MyCell::new(1);
    c.set(2);
    assert_eq!(c.get(), 2);
}
```

## Panics

Source: RfR Ch 9 "Panics" (TOC p. 158); RfR Ch 9 index "unwinding panics" (pp. 158-159); RfR errata print01-ch09-lst06-fill_default.md

Any call you make may panic and unwind: user closures, `Clone`, `Drop`, `Hash`, allocation,
indexing. Unsafe code must leave every invariant intact at every point where a panic can
escape. Two techniques:

1. **Order the updates**: write the elements first, then publish them (set the length,
   swap in the pointer). A panic in between leaks, which is safe.
2. **Guard**: hold a struct whose `Drop` restores the invariant (std's internal
   `SetLenOnDrop`), so unwinding repairs the state.

```rust
/// Appends `n` values produced by `f`.
pub fn push_with<T>(v: &mut Vec<T>, n: usize, mut f: impl FnMut() -> T) {
    v.reserve(n);
    let start = v.len();
    for slot in &mut v.spare_capacity_mut()[..n] {
        // `f` may panic. `len` is still `start`, so the Vec never claims an unwritten slot.
        slot.write(f());
    }
    // SAFETY: `reserve(n)` made capacity >= start + n, and the loop initialised all `n`
    // slots in start..start + n.
    unsafe { v.set_len(start + n) };
}

fn main() {
    let mut v = vec![1];
    push_with(&mut v, 2, || 7);
    assert_eq!(v, [1, 7, 7]);
}
```

Avoid: calling `set_len(start + n)` *before* the loop. If `f` panics, the Vec's destructor
drops uninitialised slots.

## Leak safety

Source: RfR Ch 1 index "leaking memory" (p. 6); https://doc.rust-lang.org/std/mem/fn.forget.html

`mem::forget`, `Box::leak` and `Rc` cycles are safe, so destructors are not guaranteed to
run. Soundness must never depend on a `Drop` impl running. A guard may restore an invariant
on unwind (above), but if the guard is forgotten, the result must be a leak or a stuck
state, never UB. This is why `thread::scope` joins inside the call rather than in a
handle's `Drop`.

## The drop check

Source: RfR Ch 9 "The Drop Check" (TOC p. 160); RfR errata print01-ch09-lst11-drop.md; https://doc.rust-lang.org/nomicon/dropck.html; https://doc.rust-lang.org/nomicon/phantom-data.html

- If a generic type has a `Drop` impl, the compiler assumes `drop` may use every `T` and
  `'a` it holds, so those borrows must still be live when the value is dropped (this is
  the Ch 1 rule that dropping counts as a use).
- A generic `impl Drop` already makes the type count as owning `T` for the drop check. A
  `PhantomData<T>` field adds nothing for drop check in that case, but it still sets
  variance and auto traits; for a type holding `*const T` or `NonNull<T>` and owning `T`
  values, add it so `Send`/`Sync` and variance reflect ownership.
- `#[may_dangle]` (`unsafe impl<#[may_dangle] T> Drop`) promises `drop` never touches a
  `T`, letting borrowed data die first. It is unstable and meant for std-level
  containers; there `PhantomData<T>` *is* needed to say the container still drops `T`s.

## Manage unsafe boundaries: the privacy boundary

Source: RfR Ch 9 "Manage Unsafe Boundaries" (TOC p. 163); RfR Ch 9 index "privacy boundary" (pp. 163-164)

- A `// SAFETY:` argument usually relies on fields being in a known state (`len <= cap`).
  Any code that can write those fields, including **safe** code in the same module, can
  break that argument.
- So the unit of soundness review is the module (the privacy boundary), not the unsafe
  block. Keep the fields an unsafe block relies on private, keep the module that owns them
  small, and give it no mutating API that bypasses the invariant.
- State the module's invariant once in its docs, and have block comments cite it.
- Mark visibility-critical items: changing `pub(crate)` to `pub` on a field can make the
  crate unsound without touching any `unsafe` line.

## Check your work

Source: RfR Ch 9 "Check Your Work" (TOC p. 165); RfR Ch 9 index "Miri" (pp. 96-97, 165), "sanitizers" (p. 165), "assertions" (pp. 165-166); https://doc.rust-lang.org/beta/unstable-book/compiler-flags/sanitizer.html

- **Assertions**: `assert!` the preconditions of unsafe operations in safe code;
  `debug_assert!` them inside `unsafe fn`s as an extra check (never as the only guard in a
  safe fn).
- **Miri** interprets the program and reports UB it executes: out-of-bounds and
  use-after-free accesses, invalid values, alignment violations, aliasing-model
  violations (Stacked Borrows, or Tree Borrows with `-Zmiri-tree-borrows`), data races,
  and leaks. It only sees paths the tests run. Run the whole suite in CI, as
  rust-ci-conf's `safety.yml` does.
- **Sanitizers** check native execution, including FFI code Miri cannot run. They need
  nightly and an explicit `--target` so build scripts and proc macros are not
  instrumented.

```bash
rustup +nightly component add miri
cargo +nightly miri test

# AddressSanitizer: out-of-bounds, use-after-free, leaks (LSan is part of ASan on Linux).
RUSTFLAGS="-Zsanitizer=address" cargo +nightly test --target x86_64-unknown-linux-gnu

# ThreadSanitizer: data races. Needs std rebuilt with the same flag.
RUSTFLAGS="-Zsanitizer=thread" cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
```

## From the Nomicon: hazards the book covers lightly

Source: https://doc.rust-lang.org/nomicon/unbounded-lifetimes.html; https://doc.rust-lang.org/nomicon/leaking.html; https://doc.rust-lang.org/nomicon/safe-unsafe-meaning.html; https://doc.rust-lang.org/nomicon/exception-safety.html

- **Unbounded lifetimes.** `&*ptr` and `transmute` produce a reference whose lifetime is
  whatever the caller infers, up to `'static`. Bound it at once: return it from a function
  whose signature ties it to an input (`fn get<'a>(&'a self) -> &'a T`).
- **Leak amplification.** When a `Drop` that restores an invariant may never run (the guard
  is `mem::forget`-able), make the leaked state safe instead: `Vec::drain` sets the length
  to the start of the range before yielding, so a leaked `Drain` leaks elements rather than
  exposing moved-out ones.
- **Do not trust safe traits.** Unsafe code may not rely on a safe trait's contract for
  soundness: a user's `Ord` can be inconsistent, `Hash`/`Eq` can disagree, an iterator's
  `size_hint` or `ExactSizeIterator::len` can lie. Bound-check what they return, or require
  an `unsafe trait` (`TrustedLen`-style) whose implementers promise it.
- **Exception safety in generic code.** Every call to user code (`clone`, `cmp`, closures,
  `Drop` of a `T`) can panic. Order writes so a panic leaves the structure valid, or hold a
  guard whose `Drop` repairs it (the hole guard in `BinaryHeap::sift_up`).

## Common mistakes

Source: summary of the sections above; each item comes from the section that covers it.

1. An `unsafe` block without a `// SAFETY:` argument, or one that restates the code ("calls
   get_unchecked") instead of saying why the preconditions hold.
2. One block wrapping several unsafe operations, so no single argument covers them.
3. A safe function whose soundness depends on its callers, or on a `debug_assert!`.
4. Publishing state (lengths, pointers) before it is valid, so a panic exposes it.
5. Soundness that depends on a destructor running.
6. Fields relied on by unsafe code that other code in the module (or crate) can change.
7. `as` pointer casts and integer-to-pointer round trips instead of `cast`, `&raw`, and the
   provenance APIs.
8. `&mut` or `&` to uninitialised memory, or to a misaligned packed field.
9. Dropping the old value while still holding a `&mut` into the cell or container.
10. Trusting a passing test suite: run Miri, and sanitizers where FFI is involved.
