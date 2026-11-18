In this crate, write an LRU cache for a library: a fixed capacity set at construction, `get` marks
an entry as recently used, and `insert` evicts the least recently used entry when the cache is
full. `get` and `insert` must be O(1). Include tests.

The crate root exports `LruCache<K, V>`. `LruCache::new(capacity)` takes a `usize` greater than
zero. `get(&mut self, key: &K)` returns an `Option<&V>`. `insert(&mut self, key: K, value: V)`
on a key that is already there replaces its value and marks it as recently used. `len()` returns
the number of entries.
