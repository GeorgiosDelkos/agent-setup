//! Outside check of the lru-cache task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use lru_cache::LruCache;

/// A cache of `capacity` holding `keys`, inserted in that order, each with its own value.
///
/// The result of `insert` is bound and not used, here and below: the prompt does not say what
/// `insert` returns.
fn filled(capacity: usize, keys: &[&'static str]) -> LruCache<&'static str, String> {
    let mut cache = LruCache::new(capacity);
    for key in keys {
        let _unspecified = cache.insert(*key, key.to_uppercase());
    }
    cache
}

#[test]
fn a_full_cache_evicts_the_entry_inserted_first() {
    let mut cache = filled(2, &["a", "b", "c"]);
    assert_eq!(cache.len(), 2);
    assert!(cache.get(&"a").is_none());
    assert!(cache.get(&"b").is_some());
    assert!(cache.get(&"c").is_some());
}

#[test]
fn get_saves_an_entry_from_the_next_eviction() {
    let mut cache = filled(2, &["a", "b"]);
    assert!(cache.get(&"a").is_some());
    let _unspecified = cache.insert("c", String::new());
    assert!(cache.get(&"b").is_none());
    assert!(cache.get(&"a").is_some());
    assert!(cache.get(&"c").is_some());
}

#[test]
fn a_miss_changes_no_order() {
    let mut cache = filled(2, &["a", "b"]);
    assert!(cache.get(&"z").is_none());
    let _unspecified = cache.insert("c", String::new());
    assert!(cache.get(&"a").is_none());
    assert!(cache.get(&"b").is_some());
}

#[test]
fn inserting_a_present_key_replaces_its_value_and_evicts_nothing() {
    let mut cache = filled(2, &["a", "b"]);
    let _unspecified = cache.insert("a", "again".to_owned());
    assert_eq!(cache.len(), 2);
    assert_eq!(cache.get(&"a").map(String::as_str), Some("again"));
    assert_eq!(cache.get(&"b").map(String::as_str), Some("B"));
}

#[test]
fn inserting_a_present_key_marks_it_as_recently_used() {
    let mut cache = filled(2, &["a", "b"]);
    let _unspecified = cache.insert("a", "again".to_owned());
    let _unspecified = cache.insert("c", String::new());
    assert!(cache.get(&"b").is_none());
    assert_eq!(cache.get(&"a").map(String::as_str), Some("again"));
}

#[test]
fn a_cache_of_one_keeps_only_the_last_entry() {
    let mut cache = filled(1, &["a", "b"]);
    assert_eq!(cache.len(), 1);
    assert!(cache.get(&"a").is_none());
    assert!(cache.get(&"b").is_some());
    let _unspecified = cache.insert("b", "again".to_owned());
    assert_eq!(cache.len(), 1);
    assert_eq!(cache.get(&"b").map(String::as_str), Some("again"));
}

/// The cache as a list from least to most recently used: slow, and plainly right.
struct Model {
    capacity: usize,
    entries: Vec<(u64, u64)>,
}

impl Model {
    fn get(&mut self, key: u64) -> Option<u64> {
        let at = self.entries.iter().position(|&(k, _)| k == key)?;
        let entry = self.entries.remove(at);
        self.entries.push(entry);
        Some(entry.1)
    }

    fn insert(&mut self, key: u64, value: u64) {
        if let Some(at) = self.entries.iter().position(|&(k, _)| k == key) {
            self.entries.remove(at);
        } else if self.entries.len() == self.capacity {
            self.entries.remove(0);
        }
        self.entries.push((key, value));
    }
}

#[test]
fn a_long_run_of_gets_and_inserts_matches_a_list() {
    // The single cases above never unlink an entry from the middle of a longer order, or reuse
    // the slot of an evicted one many times over.
    let mut cache = LruCache::new(5);
    let mut model = Model {
        capacity: 5,
        entries: Vec::new(),
    };
    // Knuth's MMIX generator: fixed, so a failure names a step that fails every time.
    let mut state = 1_u64;
    for step in 0..20_000_u64 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let key = (state >> 33) % 9;
        if (state >> 60) % 3 == 0 {
            let _unspecified = cache.insert(key, step);
            model.insert(key, step);
        } else {
            assert_eq!(
                cache.get(&key).copied(),
                model.get(key),
                "get {key} at {step}"
            );
        }
        assert_eq!(cache.len(), model.entries.len(), "length at step {step}");
    }
}
