In this crate, write `ArrayVec<T, const N: usize>`: a vector with inline storage for at most N
elements and no heap allocation. I need push that reports a full vector, pop, len, indexing as a
slice, and correct dropping of the elements. Do not require `T: Default` or `T: Copy`. Include
tests.

The crate root exports the type. `ArrayVec::new()` makes an empty one, `push(value)` returns a
`Result` with an error when the vector is full, `pop()` returns an `Option<T>`, `len()` a `usize`,
and `as_slice()` a `&[T]`.
