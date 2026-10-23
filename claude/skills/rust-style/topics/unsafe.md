# Unsafe and FFI (UNS)

Read before adding `unsafe`, `extern "C"`, `repr(C)`, raw pointers, `MaybeUninit` or
`UnsafeCell`. Tags and IDs as in `../SKILL.md`. For depth: `rfr-unsafe-code`,
`rfr-ffi`.

## When

- **UNS-1** Avoid it. Between two designs, take the one with less `unsafe` even at a small
  measured cost; "faster" needs a benchmark. A crate with no `unsafe` declares
  `unsafe_code = "forbid"` in its lints, so adding some is a visible manifest change.
  [ref: C (Wasmtime coding guidelines: without `unsafe` the worst case is a panic, a
  low-severity DoS); house: `forbid`]
- **UNS-2** Every public API stays sound for any safe caller. If safety rests on a logical
  contract (a deterministic `Hash`/`Eq`, a predicate called twice), the function is `unsafe
  fn` with that contract, or a sealed marker trait unlocks a safe constructor. [ref: J
  (evmap `retain`, `StableHashEq`) C]

## Writing the argument

- **UNS-3** Every `unsafe` block has a comment directly above it, spelled exactly `//
  SAFETY:`, followed by the argument `[check]` (clippy accepts any casing; house-check does
  not). One unsafe operation per block (`multiple_unsafe_ops_per_block`), so each gets its
  own argument. [ref: T C J (policy); house: one spelling, since T and J mix three; C
  nearly always writes `SAFETY`]
- **UNS-4** The argument is checkable by local reasoning from values the code actually
  holds (a cached copy, a local snapshot, a bounds check above), not from the idealised
  shared state. For atomics it names the load/store pair that creates the happens-before
  edge, even when that load ran in an earlier call. When several blocks rely on one
  argument, later comments cite it ("same argument as for `table` above"). Enumerate cases
  for concurrent code ("we can be in one of three states: ..."). [ref: J]
- **UNS-5** `unsafe fn` and `unsafe trait` have a `# Safety` section with numbered
  preconditions. Callers discharge them by number:

  ```rust
  // SAFETY:
  // 1. `p` came from `Box::into_raw` in `new`, so it is valid and aligned.
  // 2. Same as our caller's requirement #2.
  ```

  [ref: J (haphazard); house: numbered, T and C mostly write prose]
- **UNS-6** `unsafe_op_in_unsafe_fn` is denied: inside an `unsafe fn` each unsafe operation
  sits in its own `unsafe {}` block with its own comment. A module that is nothing but
  unsafe plumbing may opt out with `#![expect(unsafe_op_in_unsafe_fn, reason = "...")]`.
  [ref: T J]
- **UNS-7** A crate (or module) with substantial unsafe states, once, the contract every
  block relies on ("an `AtomicPtr<T, F, P>` only ever holds a valid `T` allocated through `P`
  from a domain of family `F`, or null"), and block comments cite it. [ref: J]

## What the argument must cover

- **UNS-8** Code against what the language guarantees, never against what today's compiler
  does. [ref: B (Ch 1)]
- **UNS-9** Privacy boundary: every field an `unsafe` block relies on is private, the
  module that owns it stays small, and review covers the whole module, since any safe code
  there can break the invariant. Mark visibility-critical items ("NOTE: this module must not
  be public: ..."). [ref: B (Ch 9) J]
- **UNS-10** Panic safety: invariants hold if anything you call panics mid-update (user
  closures, `Clone`, `Drop`, allocation). Update lengths after elements are written, or
  hold a guard whose `Drop` restores the invariant. [ref: B (Ch 9) T]
- **UNS-11** Leak safety: soundness never depends on a destructor running; `mem::forget` is
  safe. [ref: B]
- **UNS-12** Never create a reference to uninitialized or invalid memory: no `set_len` over
  unwritten capacity followed by `&mut buf[..]`. Use `MaybeUninit`, `spare_capacity_mut`,
  or a `ReadBuf`-style API. [ref: B; J (async-bincode) is the counter-example]
- **UNS-13** `debug_assert!` is never the only guard before an unchecked operation in a
  safe function (PAN-5). Pair each `_unchecked` call in an `unsafe` context with a
  `debug_assert!` of its precondition. [ref: B J]
- **UNS-14** Pointer code that must not create intermediate references says so and uses
  raw-pointer methods (`ptr::addr_of!` is replaced by `&raw const`/`&raw mut`). [ref: T]

## Send, Sync and the drop check

- **UNS-15** Never write an `unsafe impl Send/Sync` the compiler would derive; delete it and
  pin the auto trait with a compile-time assertion. To give a type narrower auto traits than
  the default, add `PhantomData<*const T>` (with a comment saying why) and then the narrower
  `unsafe impl` with its argument. [ref: J]
- **UNS-16** Every `unsafe impl Send/Sync` has a `// SAFETY:` comment naming what crosses
  the thread boundary and why the bounds suffice (including when they are stricter than
  auto-derivation). When bounds cannot be stated on the type, implement unconditionally and
  move `T: Send`/`T: Sync` onto the methods that hand out `&T` or take ownership, and say
  so. [ref: J; T comments about half]
- **UNS-17** A type that owns `T`s through raw pointers declares it with `PhantomData<T>`,
  so variance and auto traits match ownership. A generic `Drop` impl already makes the drop
  check treat the type as owning `T`; `PhantomData<T>` becomes load-bearing for the drop
  check only with `#[may_dangle]`, which is for std-level containers. [ref: B (Ch 9),
  Nomicon (RFC 1238)]

## Casts, provenance, editions

- **UNS-18** `ptr.cast::<U>()` over `as`; `&raw const`/`&raw mut` over `addr_of!`; strict
  provenance APIs (`ptr.map_addr`, `ptr.with_addr`, `ptr::without_provenance`) over
  integer-to-pointer casts. Tag bits are cleared with provenance-preserving arithmetic.
  When the strict version is slower, keep it under `cfg(miri)` with a comment. [ref: J T
  B; lints `ptr_as_ptr`, `borrow_as_ptr`]
- **UNS-19** Edition 2024 syntax: `unsafe extern "C" { ... }`, `#[unsafe(no_mangle)]`,
  `#[unsafe(export_name = ..)]`; never a reference to a `static mut` (`static_mut_refs`).
  [ref: B (Edition Guide)]

## FFI

- **UNS-20** A panic escaping an `extern "C"` function aborts the process (since 1.81). If
  the caller needs an error instead, catch it with `catch_unwind` at the boundary and return
  a code. [ref: B (Rust 1.81)]
- **UNS-21** Nullable pointers are `Option<NonNull<T>>` or `Option<&T>`; opaque handles are
  distinct `#[repr(transparent)]` types, not `*mut c_void`; memory is freed by the
  allocator that allocated it; C types are `core::ffi::c_*`. A wrapper's `Send`/`Sync` is
  argued, never assumed. [ref: B (Ch 11 errata)]

## Documentation of hazards

- **UNS-22** An unsafe-adjacent abstraction users can misuse documents each hazard in its
  module docs with a heading and a malicious example ("a `PartialEq` that lies"). A `#
  Safety` heading is only for unsafe preconditions; logical hazards of a safe API go under
  `# Correctness`. [ref: J C]

## Verification

- **UNS-23** Before calling unsafe work done, run `cargo +nightly miri test` locally (with
  `MIRIFLAGS=-Zmiri-strict-provenance`) on the tests that reach it. Pointer-tagging code is
  also tested with an odd-address `#[global_allocator]`, a big-endian Miri target, and
  `--release` (wrapping overflow). A crate with any `unsafe` keeps the Miri job in CI.
  [ref: T J]
- **UNS-24** Intentionally leaked statics are registered with `miri_static_root` (under
  `cfg(miri)`), not hidden with `-Zmiri-ignore-leaks`; the sanitizer job keeps a checked-in
  `lsan-suppressions.txt`. [ref: J]

## Exemplar

Numbered preconditions (haphazard `src/lib.rs`, `AtomicPtr::new`):

```rust
/// # Safety
///
/// 1. `p` must reference a valid `T`, or be null.
/// 2. `p` must have been allocated using the pointer type `P`.
/// 3. `*p` must only be dropped through [`Domain::retire_ptr`].
pub unsafe fn new(p: *mut T) -> Self {
```

A caller discharging its callee's preconditions by number (haphazard `src/lib.rs`,
`Replaced::retire` calling `retire_in`):

```rust
// Safety:
//
// 1. Same as our caller requirement #1.
// 2. Same as our caller requirement #2.
// 3. Since there is exactly one Domain<Global>, we know that all calls to `load` that have
//    returned this object must have been using the same (global) domain as we're retiring
//    to.
unsafe { self.retire_in(Domain::global()) }
```

(The reference spells the label `Safety:`; house style is `SAFETY:`, UNS-3.)
