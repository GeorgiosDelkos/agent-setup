//! Outside check of the interner task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::HashSet;
use std::mem::size_of;

use interner::{Interner, Symbol};

thread_local! {
    /// Heap allocations this thread has made. Per thread, because the tests of this file run
    /// in parallel and only one of them counts.
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

/// The system allocator, counting each allocation and reallocation of the calling thread.
struct Counting;

// SAFETY: every method forwards its arguments unchanged to `System`, which upholds the
// `GlobalAlloc` contract. The counter is a `const`-initialised thread local without a
// destructor, so touching it allocates nothing and cannot re-enter the allocator.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // `try_with`: a thread that is shutting down may allocate after its locals are gone.
        let _gone = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: the caller's obligations for `alloc` are the ones `System.alloc` asks for.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` came from `alloc` above, which is `System.alloc`, with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

#[test]
fn the_same_string_gets_the_same_symbol() {
    let mut interner = Interner::new();
    let first = interner.intern("loop");
    let other = interner.intern("while");
    // A second `String` with the same contents, at another address.
    let again = interner.intern(&String::from("loop"));
    assert!(first == again);
    assert!(first != other);
}

#[test]
fn resolve_gives_the_string_back() {
    let mut interner = Interner::new();
    let name = interner.intern("name");
    let value = interner.intern("value");
    assert_eq!(interner.resolve(name), "name");
    assert_eq!(interner.resolve(value), "value");
}

#[test]
fn the_empty_string_is_a_string_like_any_other() {
    let mut interner = Interner::new();
    let empty = interner.intern("");
    let space = interner.intern(" ");
    assert!(empty != space);
    assert!(empty == interner.intern(""));
    assert_eq!(interner.resolve(empty), "");
    assert_eq!(interner.resolve(space), " ");
}

#[test]
fn strings_that_share_bytes_stay_apart() {
    // Stored end to end these are "abcabc" either way: an interner that keeps one buffer and
    // gets a span wrong hands back a neighbour's bytes.
    let words = ["ab", "c", "a", "bc", "abc", "h\u{e9}", "\u{e9}h"];
    let mut interner = Interner::new();
    let symbols: Vec<Symbol> = words.iter().map(|word| interner.intern(word)).collect();
    for (word, &symbol) in words.iter().zip(&symbols) {
        assert_eq!(interner.resolve(symbol), *word);
    }
}

#[test]
fn every_symbol_still_resolves_after_many_more_strings() {
    let strings: Vec<String> = (0..100_000).map(|n| format!("ident_{n}")).collect();
    let mut interner = Interner::new();
    let symbols: Vec<Symbol> = strings.iter().map(|s| interner.intern(s)).collect();
    // The early symbols were handed out before the interner grew many times over.
    for (string, &symbol) in strings.iter().zip(&symbols) {
        assert_eq!(interner.resolve(symbol), string);
    }
    let distinct: HashSet<&str> = symbols.iter().map(|&s| interner.resolve(s)).collect();
    assert_eq!(distinct.len(), strings.len());
}

#[test]
fn looking_up_an_interned_string_does_not_allocate() {
    let strings: Vec<String> = (0..1_000).map(|n| format!("ident_{n}")).collect();
    let mut interner = Interner::new();
    let symbols: Vec<Symbol> = strings.iter().map(|s| interner.intern(s)).collect();

    let before = ALLOCATIONS.with(Cell::get);
    let mut same = true;
    for (string, &symbol) in strings.iter().zip(&symbols) {
        same &= interner.intern(string) == symbol;
    }
    let allocations = ALLOCATIONS.with(Cell::get) - before;

    assert!(same);
    // The prompt rules out an allocation per lookup, not a buffer the interner makes once
    // and reuses. Eight is arbitrary: far below one per lookup, above any such setup.
    assert!(
        allocations <= 8,
        "{allocations} heap allocations in 1000 lookups of known strings"
    );
}

#[test]
fn a_symbol_is_small_copyable_and_comparable() {
    fn assert_copy_and_eq<T: Copy + Eq>() {}
    assert_copy_and_eq::<Symbol>();
    // Two words hold an index or a span; a `String` is three.
    assert!(size_of::<Symbol>() <= 2 * size_of::<usize>());
}
