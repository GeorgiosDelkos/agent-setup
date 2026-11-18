//! Outside check of the ring-buffer task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use std::cell::Cell;
use std::collections::VecDeque;
use std::rc::Rc;

use ring_buffer::RingBuffer;

/// A buffer of `capacity` after pushing `values` in order.
///
/// The result of `push` is bound and not used, here and below: the prompt does not say what
/// `push` returns.
fn pushed(capacity: usize, values: &[u32]) -> RingBuffer<u32> {
    let mut buffer = RingBuffer::new(capacity);
    for &value in values {
        let _unspecified = buffer.push(value);
    }
    buffer
}

fn contents(buffer: &RingBuffer<u32>) -> Vec<u32> {
    buffer.iter().copied().collect()
}

#[test]
fn a_new_buffer_is_empty() {
    let mut buffer = RingBuffer::<u32>::new(3);
    assert_eq!(buffer.len(), 0);
    assert!(buffer.iter().next().is_none());
    assert!(buffer.pop().is_none());
}

#[test]
fn pop_returns_the_oldest_element_first() {
    let mut buffer = pushed(3, &[1, 2]);
    assert_eq!(buffer.len(), 2);
    assert_eq!(buffer.pop(), Some(1));
    assert_eq!(buffer.pop(), Some(2));
    assert_eq!(buffer.pop(), None);
    assert_eq!(buffer.len(), 0);
}

#[test]
fn a_push_to_a_full_buffer_overwrites_the_oldest() {
    let mut buffer = pushed(3, &[1, 2, 3, 4]);
    assert_eq!(buffer.len(), 3);
    assert_eq!(buffer.pop(), Some(2));
    assert_eq!(buffer.pop(), Some(3));
    assert_eq!(buffer.pop(), Some(4));
    assert_eq!(buffer.pop(), None);
}

#[test]
fn iteration_runs_from_oldest_to_newest() {
    assert_eq!(contents(&pushed(4, &[1, 2, 3])), [1, 2, 3]);
    // The newest element now sits before the oldest in the storage.
    assert_eq!(contents(&pushed(4, &[1, 2, 3, 4, 5, 6])), [3, 4, 5, 6]);
}

#[test]
fn iteration_takes_nothing_out() {
    let mut buffer = pushed(2, &[1, 2, 3]);
    assert_eq!(contents(&buffer), [2, 3]);
    assert_eq!(contents(&buffer), [2, 3]);
    assert_eq!(buffer.len(), 2);
    assert_eq!(buffer.pop(), Some(2));
}

#[test]
fn a_buffer_of_one_keeps_only_the_newest() {
    let mut buffer = pushed(1, &[1, 2, 3]);
    assert_eq!(buffer.len(), 1);
    assert_eq!(contents(&buffer), [3]);
    assert_eq!(buffer.pop(), Some(3));
    assert_eq!(buffer.pop(), None);
}

#[test]
fn a_long_run_of_pushes_and_pops_matches_a_queue() {
    // Pops in between move the oldest element off the start of the storage, which the cases
    // above never do before the buffer wraps.
    const CAPACITY: usize = 5;
    let mut buffer = RingBuffer::new(CAPACITY);
    let mut model = VecDeque::new();
    // Knuth's MMIX generator: fixed, so a failure names a step that fails every time.
    let mut state = 1_u64;
    for step in 0..20_000_u32 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        if (state >> 60) % 3 == 0 {
            assert_eq!(buffer.pop(), model.pop_front(), "pop at step {step}");
        } else {
            if model.len() == CAPACITY {
                model.pop_front();
            }
            model.push_back(step);
            let _unspecified = buffer.push(step);
        }
        assert_eq!(buffer.len(), model.len(), "length at step {step}");
        assert!(buffer.iter().eq(model.iter()), "order at step {step}");
    }
}

/// Counts its own drops in a shared counter.
struct Tracked(Rc<Cell<usize>>);

impl Drop for Tracked {
    fn drop(&mut self) {
        self.0.set(self.0.get() + 1);
    }
}

#[test]
fn every_element_is_dropped_once() {
    let drops = Rc::new(Cell::new(0));
    let mut buffer = RingBuffer::new(2);
    for _ in 0..5 {
        // An overwritten element goes when the buffer hands it back here, or inside `push`.
        drop(buffer.push(Tracked(Rc::clone(&drops))));
    }
    assert_eq!(drops.get(), 3, "the three overwritten elements");
    drop(buffer.pop());
    assert_eq!(drops.get(), 4);
    drop(buffer);
    assert_eq!(drops.get(), 5);
}
