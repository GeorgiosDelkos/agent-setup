//! Outside check of the array-vec task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use std::cell::Cell;
use std::mem::size_of;
use std::rc::Rc;

use array_vec::ArrayVec;

/// Counts its own drops in a shared counter. Neither `Copy` nor `Default`, as the prompt allows.
struct Tracked(Rc<Cell<usize>>);

impl Drop for Tracked {
    fn drop(&mut self) {
        self.0.set(self.0.get() + 1);
    }
}

/// Pushes `value`, which must fit. `is_ok`, not `unwrap`: the prompt asks for no `Debug` on the
/// error.
fn push<T, const N: usize>(vec: &mut ArrayVec<T, N>, value: T) {
    assert!(
        vec.push(value).is_ok(),
        "a vector below its capacity takes a push"
    );
}

#[test]
fn a_new_vector_is_empty() {
    let mut vec = ArrayVec::<String, 4>::new();
    assert_eq!(vec.len(), 0);
    assert!(vec.as_slice().is_empty());
    assert!(vec.pop().is_none());
}

#[test]
fn the_slice_holds_the_elements_in_push_order() {
    let mut vec = ArrayVec::<String, 4>::new();
    for word in ["a", "b", "c"] {
        push(&mut vec, word.to_owned());
    }
    assert_eq!(vec.len(), 3);
    assert_eq!(vec.as_slice(), ["a", "b", "c"]);
}

#[test]
fn pop_returns_the_last_element_first() {
    let mut vec = ArrayVec::<String, 4>::new();
    push(&mut vec, "a".to_owned());
    push(&mut vec, "b".to_owned());
    assert_eq!(vec.pop().as_deref(), Some("b"));
    assert_eq!(vec.as_slice(), ["a"]);
    push(&mut vec, "c".to_owned());
    assert_eq!(vec.pop().as_deref(), Some("c"));
    assert_eq!(vec.pop().as_deref(), Some("a"));
    assert!(vec.pop().is_none());
    assert_eq!(vec.len(), 0);
}

#[test]
fn a_push_to_a_full_vector_is_reported_and_changes_nothing() {
    let mut vec = ArrayVec::<u32, 2>::new();
    push(&mut vec, 1);
    push(&mut vec, 2);
    assert!(vec.push(3).is_err());
    assert_eq!(vec.as_slice(), [1, 2]);
    // A slot freed by pop can be filled again.
    assert_eq!(vec.pop(), Some(2));
    push(&mut vec, 4);
    assert_eq!(vec.as_slice(), [1, 4]);
}

#[test]
fn a_vector_of_capacity_zero_is_always_full() {
    let mut vec = ArrayVec::<u32, 0>::new();
    assert!(vec.push(1).is_err());
    assert_eq!(vec.len(), 0);
    assert!(vec.pop().is_none());
}

#[test]
fn dropping_the_vector_drops_each_element_once() {
    let drops = Rc::new(Cell::new(0));
    let mut vec = ArrayVec::<Tracked, 8>::new();
    for _ in 0..3 {
        push(&mut vec, Tracked(Rc::clone(&drops)));
    }
    assert_eq!(drops.get(), 0, "an element in the vector is not dropped");
    drop(vec);
    assert_eq!(drops.get(), 3);
}

#[test]
fn a_popped_element_is_not_dropped_again_with_the_vector() {
    let drops = Rc::new(Cell::new(0));
    let mut vec = ArrayVec::<Tracked, 8>::new();
    for _ in 0..3 {
        push(&mut vec, Tracked(Rc::clone(&drops)));
    }
    let popped = vec.pop();
    assert_eq!(drops.get(), 0);
    drop(popped);
    assert_eq!(drops.get(), 1);
    drop(vec);
    assert_eq!(drops.get(), 3);
}

#[test]
fn an_element_a_full_vector_refused_is_dropped_once() {
    let drops = Rc::new(Cell::new(0));
    let mut vec = ArrayVec::<Tracked, 1>::new();
    push(&mut vec, Tracked(Rc::clone(&drops)));
    // Whether the error hands the element back or not, it is gone once the result is.
    drop(vec.push(Tracked(Rc::clone(&drops))));
    assert_eq!(drops.get(), 1);
    drop(vec);
    assert_eq!(drops.get(), 2);
}

#[test]
fn the_storage_is_inside_the_vector() {
    // A vector that kept its elements on the heap would be a pointer and two counts.
    assert!(size_of::<ArrayVec<u64, 100>>() >= 100 * size_of::<u64>());
}
