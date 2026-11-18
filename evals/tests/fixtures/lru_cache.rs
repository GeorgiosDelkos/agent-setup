//! A correct solution of the lru-cache task. The harness tests use it as the stub session's
//! work, which pins `tasks/lru-cache/oracle.rs`: every oracle test must pass against it.

use std::collections::HashMap;
use std::fmt;
use std::hash::Hash;

/// Stands for "no entry" in `Entry::newer`, `Entry::older`, `newest` and `oldest`.
const NONE: usize = usize::MAX;

/// A cache of at most `capacity` entries that evicts the least recently used one.
///
/// # Invariants
///
/// The entries form one doubly linked list by index, from `newest` through `older` links to
/// `oldest` and back through `newer` links, and `index` maps each entry's key to its place in
/// `entries`. An entry never moves: eviction reuses its place for the new entry.
pub struct LruCache<K, V> {
    capacity: usize,
    index: HashMap<K, usize>,
    entries: Vec<Entry<K, V>>,
    newest: usize,
    oldest: usize,
}

struct Entry<K, V> {
    key: K,
    value: V,
    newer: usize,
    older: usize,
}

impl<K, V> LruCache<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Returns an empty cache that holds up to `capacity` entries.
    ///
    /// # Panics
    ///
    /// Panics when `capacity` is zero.
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "an LRU cache needs a capacity above zero");
        Self {
            capacity,
            index: HashMap::with_capacity(capacity),
            entries: Vec::with_capacity(capacity),
            newest: NONE,
            oldest: NONE,
        }
    }

    /// Returns the value of `key` and marks the entry as the most recently used.
    pub fn get(&mut self, key: &K) -> Option<&V> {
        let at = *self.index.get(key)?;
        self.unlink(at);
        self.link_newest(at);
        Some(&self.entries[at].value)
    }

    /// Sets the value of `key` and marks the entry as the most recently used. A new key in a
    /// full cache replaces the least recently used entry.
    pub fn insert(&mut self, key: K, value: V) {
        if let Some(&at) = self.index.get(&key) {
            self.entries[at].value = value;
            self.unlink(at);
            self.link_newest(at);
            return;
        }
        let entry = Entry {
            key: key.clone(),
            value,
            newer: NONE,
            older: NONE,
        };
        let at = if self.entries.len() < self.capacity {
            self.entries.push(entry);
            self.entries.len() - 1
        } else {
            let at = self.oldest;
            self.unlink(at);
            self.index.remove(&self.entries[at].key);
            self.entries[at] = entry;
            at
        };
        self.index.insert(key, at);
        self.link_newest(at);
        // Post-invariant: the entry at `at` is in `index` and at the head of the list, and
        // an evicted entry left both before its place was reused.
    }

    /// Returns the number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns true when the cache holds no entry.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Takes the entry at `at` out of the list. Its own links are stale until it is linked
    /// again, which every caller does before returning.
    fn unlink(&mut self, at: usize) {
        let Entry { newer, older, .. } = self.entries[at];
        match self.entries.get_mut(newer) {
            Some(entry) => entry.older = older,
            None => self.newest = older,
        }
        match self.entries.get_mut(older) {
            Some(entry) => entry.newer = newer,
            None => self.oldest = newer,
        }
    }

    /// Puts the unlinked entry at `at` at the head of the list.
    fn link_newest(&mut self, at: usize) {
        self.entries[at].newer = NONE;
        self.entries[at].older = self.newest;
        match self.entries.get_mut(self.newest) {
            Some(entry) => entry.newer = at,
            None => self.oldest = at,
        }
        self.newest = at;
    }
}

impl<K, V> fmt::Debug for LruCache<K, V> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LruCache")
            .field("len", &self.entries.len())
            .field("capacity", &self.capacity)
            .finish_non_exhaustive()
    }
}
