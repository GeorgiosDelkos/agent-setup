In this crate, write `ArrayVec<T, const N: usize>`: a vector with inline storage for at most N
elements and no heap allocation. I need push that reports a full vector, pop, len, indexing as a
slice, and correct dropping of the elements. Do not require `T: Default` or `T: Copy`. Include
tests.
