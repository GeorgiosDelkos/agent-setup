In this crate, write a fixed-capacity ring buffer for a library. Pushing to a full buffer
overwrites the oldest element. I need push, pop of the oldest, the length, and iteration from
oldest to newest. Include tests.

The crate root exports `RingBuffer<T>`. `RingBuffer::new(capacity)` takes a `usize` greater than
zero, `push(&mut self, value: T)` adds the newest element, `pop(&mut self)` returns an
`Option<T>`, `len()` a `usize`, and `iter()` yields `&T`.
