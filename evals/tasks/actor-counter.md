In this crate, write an async key-value counter service on Tokio: a task owns a map from key to
count, and handles reached from many tasks can increment a key, read a key, and take a snapshot of
all counts. The service must not grow memory without bound when callers are faster than it is.
Include tests.
