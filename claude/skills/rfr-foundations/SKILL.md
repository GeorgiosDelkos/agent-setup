---
name: rfr-foundations
description: Use when reasoning about Rust memory, ownership, moves, borrowing, lifetimes (including generic lifetimes on types), variance, drop order, or interior mutability. Use when code has borrow checker errors, lifetime confusion, invariance surprises, or unexpected drop behavior.
---

# Rust for Rustaceans, Ch 1: Foundations

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it. This chapter is the free sample, so short quotes below are from it, with page.

## Code against the contract, not the compiler

Source: RfR Ch 1 "Shared References" (TOC p. 9)

- The compiler is allowed to assume a value behind `&T` does not change while the reference
  lives, and that a `&mut T` is exclusive. It may or may not exploit that today. "You
  generally want to code against what the compiler is allowed to do rather than what it
  actually does" (p. 10).
- Practical consequence: "it worked when I ran it" proves nothing for code that breaks
  these contracts (usually `unsafe` code). Miri checks the contract, not the codegen.

## Memory and variables

Source: RfR Ch 1 "Memory Terminology", "Variables in Depth", "Memory Regions" (TOC pp. 2-5)

- A *value* is a type plus an element of its value space; a *place* is where it is stored
  (stack, heap, static memory); a *pointer* holds a place's address.
- Stack frames hold a function's locals and die when it returns, so a reference to a local
  cannot outlive the call. Heap allocations (`Box`, `Vec`, `String`) live until their owner
  drops them. `Box::leak` gives a `'static` reference to a heap value.
- `static` items are places with a fixed address for the whole program. A `const` is not a
  place: it is a name for a value that is copied into each use site (p. 7 note).
- `T: 'static` means `T` is "owned and self-sufficient": it borrows nothing, or only
  `'static` data (p. 7). It does not mean the value lives forever. `thread::spawn` needs it
  because the new thread may outlive the caller's stack.

## Ownership and moves

Source: RfR Ch 1 "Ownership" (TOC p. 7)

- Every value has one owner. Assignment and passing by value move it; the source is then
  unusable. Types that are `Copy` are duplicated bit for bit instead.
- `Copy` is only for types whose bitwise copy is a full, independent copy (no heap
  ownership, no `Drop`). A type that implements `Drop` cannot be `Copy`.
- `Clone` duplicates by calling user code. What that means depends on the type: `Vec` and
  `String` copy their buffers, while `Rc::clone`/`Arc::clone` only bump a reference count
  and share the same value. Write `Arc::clone(&x)` so the cheap clone is visible.

```rust
let s1 = String::from("hello");
let s2 = s1; // s1 is moved; using it now is a compile error
let n1: i32 = 42;
let n2 = n1; // i32 is Copy; n1 is still usable
println!("{s2} {n1} {n2}");
```

### Moving out of a mutable reference

Source: RfR Ch 1 "Mutable References" (TOC p. 10)

The owner of a `&mut T` must find a valid value behind it when the borrow ends, so you can
move out of a `&mut` only by leaving something in its place: `std::mem::take` (leaves
`Default::default()`), `std::mem::replace`, or `std::mem::swap` (Ch 1 p. 11, Listing 1-7).

```rust
fn drain_name(name: &mut String) -> String {
    std::mem::take(name) // leaves an empty String behind
}

let mut n = String::from("ferris");
let taken = drain_name(&mut n);
assert_eq!((taken.as_str(), n.as_str()), ("ferris", ""));
```

## Borrowing

Source: RfR Ch 1 "Shared References", "Mutable References" (TOC pp. 9-10)

- `&T`: any number at once; each is `Copy`; no mutation through it (except interior
  mutability, below).
- `&mut T`: exclusive. No other reference to the same value may be used while it is live.
- The borrow checker rejects dangling references and aliased mutation.

```rust
let v = vec![1, 2, 3];
let (r1, r2) = (&v, &v); // Do: many shared borrows
println!("{r1:?} {r2:?}");
```

```rust,compile_fail
// Does not compile: `v` is mutably borrowed by push while `r` is still used later.
let mut v = vec![1, 2, 3];
let r = &v;
v.push(4);
println!("{r:?}");
```

## Lifetimes

Source: RfR Ch 1 "Lifetimes" (TOC p. 12)

- A lifetime is a name for a region of code where a reference must stay valid. It is not a
  scope: it runs from where the borrow is taken to its last use, and the borrow checker
  follows control flow. A lifetime can be non-contiguous and have holes, for example when a
  variable is reassigned to a fresh borrow (pp. 12-14, Listings 1-8 and 1-9).

```rust
let mut x = Box::new(42);
let mut z = &x;
for i in 0..3 {
    println!("{z}");
    x = Box::new(i); // the old borrow ends at the println above
    z = &x;          // a new one starts here
}
println!("{z}");
```

### Elision rules

Source: https://doc.rust-lang.org/reference/lifetime-elision.html

1. Each elided lifetime in the parameters becomes its own lifetime parameter.
2. If there is exactly one input lifetime, it is assigned to all elided output lifetimes.
3. If there is a `&self` or `&mut self` receiver, its lifetime is assigned to all elided
   output lifetimes.

Otherwise an elided output lifetime is an error and you must name it:

```rust
fn first(s: &str) -> &str { &s[..1] } // rule 2

fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() { x } else { y }
}
```

## Generic lifetimes on types

Source: RfR Ch 1 "Lifetimes" (TOC p. 12), sample pp. 14-15

- If your type implements `Drop`, dropping it counts as a use of every lifetime and type it
  is generic over, so those borrows must still be valid at the drop. Without a `Drop` impl,
  a dropped value's stored references need not be valid (p. 14). Ch 9 covers the drop check.
- Use one lifetime parameter by default. Use several only when the type holds several
  references and methods return references tied to just one of them (p. 15, `StrSplit`):

```rust
struct StrSplit<'s, 'p> {
    delimiter: &'p str,
    document: &'s str,
}

impl<'s> Iterator for StrSplit<'s, '_> {
    type Item = &'s str; // tied to the document only
    fn next(&mut self) -> Option<Self::Item> {
        if self.document.is_empty() {
            return None;
        }
        let (head, tail) = self
            .document
            .split_once(self.delimiter)
            .unwrap_or((self.document, ""));
        self.document = tail;
        Some(head)
    }
}

// With a single lifetime this would not compile: the result would be tied to the
// temporary String holding the delimiter.
fn str_before(s: &str, c: char) -> Option<&str> {
    StrSplit { document: s, delimiter: &c.to_string() }.next()
}
```

## Variance

Source: RfR Ch 1 "Lifetimes" (TOC p. 12), sample pp. 15-17; https://doc.rust-lang.org/reference/subtyping.html

`'b: 'a` (outlives) makes `'b` a subtype of `'a`; `&'static str` can go where `&'a str` is
expected.

| Type | Variance in `'a` | Variance in `T` |
|------|------------------|-----------------|
| `&'a T` | covariant | covariant |
| `&'a mut T` | covariant | invariant |
| `Box<T>`, `Vec<T>` | - | covariant |
| `Cell<T>`, `UnsafeCell<T>` | - | invariant |
| `fn(T) -> U` | - | contravariant in `T`, covariant in `U` |
| `*const T` / `*mut T` | - | covariant / invariant |

- Mutability makes a type invariant in what it lets you write: if `&mut Vec<&'a str>` could
  accept `&mut Vec<&'static str>`, the callee could store a short-lived string the caller
  then treats as `'static` (p. 16).
- Design rule: "ensure that your types remain covariant (or contravariant where
  appropriate) over as many of their generic parameters as possible", weighing an extra
  lifetime parameter against the cost of invariance (p. 17). Listing 1-11 shows the cost:

```rust
struct MutStr<'a, 'b> {
    s: &'a mut &'b str, // two lifetimes keep 'b independent of the invariant borrow
}

let mut s = "hello";
*MutStr { s: &mut s }.s = "world";
println!("{s}"); // with one lifetime ('a for both) this line fails to borrow `s`
```

## Drop order

Source: RfR Ch 1 "Ownership" (TOC p. 7); RfR errata print01-ch01-drop-order.md; https://doc.rust-lang.org/reference/destructors.html

- Variables (and function arguments) drop in reverse declaration order; nested values
  (struct fields, tuple elements, array elements) drop in source order (p. 9). Later
  variables may borrow earlier ones, so reverse order keeps those borrows valid.
- Closure captures drop in an unspecified order. Collections decide in their `Drop` impl:
  `Vec` drops its elements as a slice (first to last), and `HashMap` iteration order is
  unspecified, so do not rely on the order of its elements' drops.
- `Drop::drop` takes `&mut self`; to move a field out, use `mem::take` or wrap it in
  `Option` or `ManuallyDrop`. You cannot call `x.drop()`; use `drop(x)`.

```rust
struct Noisy(&'static str);
impl Drop for Noisy {
    fn drop(&mut self) {
        println!("drop {}", self.0);
    }
}

let _a = Noisy("a");
let _b = Noisy("b");
let _pair = (Noisy("first"), Noisy("second"));
// prints: drop first, drop second, drop b, drop a
```

- `ManuallyDrop<T>` suppresses the automatic drop. Leaking is safe (not UB), so code must
  never rely on a destructor running for soundness.

## Interior mutability

Source: RfR Ch 1 "Interior Mutability" (TOC p. 12)

`UnsafeCell` "is the only correct way to mutate through a shared reference" (p. 12). Every
type below is built on it, and holding one makes the type invariant in `T`.

| Type | Thread-safe | Cost | Use for |
|------|-------------|------|---------|
| `Cell<T>` | No (`!Sync`) | none; moves values in and out, never hands out references | small values, often `Copy` |
| `RefCell<T>` | No | runtime borrow flag; panics on conflict | single-threaded shared ownership graphs |
| `Mutex<T>` / `RwLock<T>` | Yes | lock | shared mutable state across threads |
| `Atomic*` | Yes | atomic instructions | counters, flags, lock-free structures |
| `OnceCell` / `OnceLock` | `OnceLock` yes | one-time init | lazy initialization |
| `UnsafeCell<T>` | No (`!Sync`) | none | building the above (needs `unsafe`) |

```rust
use std::cell::RefCell;

let data = RefCell::new(vec![1, 2, 3]);
data.borrow_mut().push(4); // mutation through a shared reference
assert_eq!(data.borrow().len(), 4);
```

## Common mistakes

Source: general Rust practice (not from the book), except item 1 (RfR Ch 1 p. 7)

1. Reading `T: 'static` as "lives forever"; it means "borrows nothing short-lived".
2. Cloning to silence the borrow checker before checking whether a narrower borrow, a
   `mem::take`, or a different owner would do.
3. Adding a second lifetime parameter "just in case"; add it only for the `StrSplit` or
   `MutStr` reasons above.
4. Putting `Cell`, `&mut`, or `fn(T)` fields into a public type without noticing the
   variance change (it is visible to callers and changing it later is breaking).
5. Using `RefCell` or `Rc` across threads; they are not `Sync`/`Send`. Use `Mutex`/`Arc`.
6. Storing references in long-lived structs when ownership would be simpler.
