//! A correct solution of the array-vec task. The harness tests use it as the stub session's
//! work, which pins `tasks/array-vec/oracle.rs`: every oracle test must pass against it.

use std::error::Error;
use std::fmt;
use std::mem::MaybeUninit;
use std::ptr;
use std::slice;

/// A vector of at most `N` elements, stored inline.
///
/// # Invariants
///
/// `slots[..len]` are initialised and `slots[len..]` are not.
pub struct ArrayVec<T, const N: usize> {
    len: usize,
    slots: [MaybeUninit<T>; N],
}

impl<T, const N: usize> ArrayVec<T, N> {
    /// Returns an empty vector.
    pub const fn new() -> Self {
        Self {
            len: 0,
            slots: [const { MaybeUninit::uninit() }; N],
        }
    }

    /// Appends `value`.
    ///
    /// # Errors
    ///
    /// Returns `value` in a [`Full`] when the vector holds `N` elements.
    pub fn push(&mut self, value: T) -> Result<(), Full<T>> {
        let Some(slot) = self.slots.get_mut(self.len) else {
            return Err(Full(value));
        };
        slot.write(value);
        // Post-invariant: the slot at the old `len` was written above.
        self.len += 1;
        Ok(())
    }

    /// Removes and returns the last element.
    pub fn pop(&mut self) -> Option<T> {
        self.len = self.len.checked_sub(1)?;
        // SAFETY: the slot at the old `len - 1` was initialised by the invariant. `len` no
        // longer covers it, so nothing reads or drops it again.
        Some(unsafe { self.slots[self.len].assume_init_read() })
    }

    /// Returns the number of elements.
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Returns true when the vector holds no element.
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Returns the elements, oldest first.
    pub const fn as_slice(&self) -> &[T] {
        // SAFETY: `slots[..len]` are initialised `T`s by the invariant, `MaybeUninit<T>` has
        // the layout of `T`, and the borrow of `self` keeps them alive and unchanged.
        unsafe { slice::from_raw_parts(self.slots.as_ptr().cast::<T>(), self.len) }
    }
}

impl<T, const N: usize> Default for ArrayVec<T, N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T, const N: usize> Drop for ArrayVec<T, N> {
    fn drop(&mut self) {
        let live = ptr::slice_from_raw_parts_mut(self.slots.as_mut_ptr().cast::<T>(), self.len);
        // If an element's `Drop` panics, the rest leak: `len` is zero before any runs, so
        // none is dropped twice.
        self.len = 0;
        // SAFETY: `live` covers the initialised prefix (the invariant, read before `len` was
        // cleared), exclusively borrowed through `&mut self`, and nothing uses it afterwards.
        unsafe { ptr::drop_in_place(live) }
    }
}

impl<T, const N: usize> fmt::Debug for ArrayVec<T, N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ArrayVec")
            .field("len", &self.len)
            .field("capacity", &N)
            .finish_non_exhaustive()
    }
}

/// The element a full [`ArrayVec`] did not take.
pub struct Full<T>(pub T);

impl<T> fmt::Debug for Full<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Full").finish_non_exhaustive()
    }
}

impl<T> fmt::Display for Full<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("vector is full")
    }
}

impl<T> Error for Full<T> {}
