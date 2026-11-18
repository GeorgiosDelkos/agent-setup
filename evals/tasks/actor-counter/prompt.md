In this crate, write an async key-value counter service on Tokio: a task owns a map from key to
count, and handles reached from many tasks can increment a key, read a key, and take a snapshot of
all counts. The service must not grow memory without bound when callers are faster than it is.
Include tests.

The crate root exports `spawn()`, which takes no arguments, is called inside a Tokio runtime and
returns the handle type `Counter`, which is `Clone`. Its async methods take `&self`:
`increment(key: &str)` adds one to the key, `get(key: &str)` returns the key's count as a `u64`
(0 for a key never incremented), and `snapshot()` returns every count as a
`HashMap<String, u64>`. Each returns a `Result`, with an error when the service is gone.
