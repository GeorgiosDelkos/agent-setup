//! Outside check of the actor-counter task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.
//!
//! The prompt's memory bound has no test here: nothing the prompt names shows how many
//! requests are waiting.

use std::collections::HashMap;
use std::future::Future;

use actor_counter::{Counter, spawn};

/// Runs `test` on a runtime of its own. Built by hand, with one thread: `#[tokio::test]` and
/// the multi-threaded runtime need Tokio features the crate may not have turned on.
fn run<F: Future>(test: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("a current-thread runtime builds")
        .block_on(test)
}

/// Adds `times` to `key`. `is_ok` here and `let ... else` below, not `unwrap`: the prompt asks
/// for no `Debug` on the error type.
async fn increment(counter: &Counter, key: &str, times: u64) {
    for _ in 0..times {
        assert!(
            counter.increment(key).await.is_ok(),
            "the service is running"
        );
    }
}

async fn count(counter: &Counter, key: &str) -> u64 {
    let Ok(count) = counter.get(key).await else {
        panic!("the service is running");
    };
    count
}

async fn snapshot(counter: &Counter) -> HashMap<String, u64> {
    let Ok(counts) = counter.snapshot().await else {
        panic!("the service is running");
    };
    counts
}

#[test]
fn a_key_never_incremented_reads_zero() {
    run(async {
        let counter = spawn();
        assert!(snapshot(&counter).await.is_empty());
        assert_eq!(count(&counter, "absent").await, 0);
    });
}

#[test]
fn each_key_has_its_own_count() {
    run(async {
        let counter = spawn();
        increment(&counter, "a", 3).await;
        increment(&counter, "b", 1).await;
        assert_eq!(count(&counter, "a").await, 3);
        assert_eq!(count(&counter, "b").await, 1);
        increment(&counter, "a", 1).await;
        assert_eq!(count(&counter, "a").await, 4);
        assert_eq!(count(&counter, "b").await, 1);
    });
}

#[test]
fn a_snapshot_holds_every_count() {
    run(async {
        let counter = spawn();
        increment(&counter, "a", 2).await;
        increment(&counter, "", 1).await;
        let expected = HashMap::from([("a".to_owned(), 2), (String::new(), 1)]);
        assert_eq!(snapshot(&counter).await, expected);
    });
}

#[test]
fn a_clone_reaches_the_same_service_and_outlives_the_first_handle() {
    run(async {
        let counter = spawn();
        let clone = counter.clone();
        increment(&counter, "a", 1).await;
        increment(&clone, "a", 1).await;
        assert_eq!(count(&counter, "a").await, 2);
        drop(counter);
        increment(&clone, "a", 1).await;
        assert_eq!(count(&clone, "a").await, 3);
    });
}

#[test]
fn a_handle_gets_an_error_once_the_service_is_gone() {
    // The service is a task of the runtime `spawn` was called in, so it ends with that
    // runtime. The handle outlives both.
    let counter = run(async {
        let counter = spawn();
        increment(&counter, "a", 1).await;
        counter
    });
    run(async {
        assert!(counter.increment("a").await.is_err());
        assert!(counter.get("a").await.is_err());
        assert!(counter.snapshot().await.is_err());
    });
}

#[test]
fn no_increment_is_lost_when_many_tasks_send_at_once() {
    // A multiple of the number of keys, so every key gets the same number of tasks.
    const TASKS: usize = 200;
    const EACH: u64 = 100;
    let keys = ["a", "b", "c", "d"];
    run(async {
        let counter = spawn();
        // Twenty thousand requests from tasks that take turns on one thread: far more than
        // any mailbox holds, so senders that must wait for room do wait, and all must finish.
        let tasks: Vec<_> = keys
            .iter()
            .cycle()
            .take(TASKS)
            .map(|&key| {
                let counter = counter.clone();
                tokio::spawn(async move { increment(&counter, key, EACH).await })
            })
            .collect();
        for task in tasks {
            assert!(task.await.is_ok(), "no sending task panicked");
        }
        let per_key = (TASKS / keys.len()) as u64 * EACH;
        let expected: HashMap<String, u64> = keys
            .iter()
            .map(|key| ((*key).to_owned(), per_key))
            .collect();
        assert_eq!(snapshot(&counter).await, expected);
    });
}
