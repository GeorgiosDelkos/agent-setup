//! A correct solution of the ring-buffer task. The harness tests use it as the stub session's
//! work, which pins `tasks/ring-buffer/oracle.rs`: every oracle test must pass against it.

use std::collections::VecDeque;
use std::collections::vec_deque;
use std::fmt;

/// A queue of at most `capacity` elements that overwrites its oldest when full.
pub struct RingBuffer<T> {
    capacity: usize,
    elements: VecDeque<T>,
}

impl<T> RingBuffer<T> {
    /// Returns an empty buffer that holds up to `capacity` elements.
    ///
    /// # Panics
    ///
    /// Panics when `capacity` is zero.
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "a ring buffer needs a capacity above zero");
        Self {
            capacity,
            elements: VecDeque::with_capacity(capacity),
        }
    }

    /// Adds `value` as the newest element and returns the oldest one when it had to go.
    pub fn push(&mut self, value: T) -> Option<T> {
        let overwritten = if self.elements.len() == self.capacity {
            self.elements.pop_front()
        } else {
            None
        };
        self.elements.push_back(value);
        overwritten
    }

    /// Removes and returns the oldest element.
    pub fn pop(&mut self) -> Option<T> {
        self.elements.pop_front()
    }

    /// Returns the number of elements.
    pub fn len(&self) -> usize {
        self.elements.len()
    }

    /// Returns true when the buffer holds no element.
    pub fn is_empty(&self) -> bool {
        self.elements.is_empty()
    }

    /// Iterates from the oldest element to the newest.
    pub fn iter(&self) -> vec_deque::Iter<'_, T> {
        self.elements.iter()
    }
}

impl<'a, T> IntoIterator for &'a RingBuffer<T> {
    type Item = &'a T;
    type IntoIter = vec_deque::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

impl<T> fmt::Debug for RingBuffer<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RingBuffer")
            .field("len", &self.elements.len())
            .field("capacity", &self.capacity)
            .finish_non_exhaustive()
    }
}
