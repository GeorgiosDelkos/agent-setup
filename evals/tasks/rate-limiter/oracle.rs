//! Outside check of the rate-limiter task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.
//!
//! The prompt names no way to set the limiter's clock, so these tests run on real time and are
//! written so that no schedule changes a verdict: a refusal is asserted only when the test
//! measured that too little time had passed for the refill to grant the request.

use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use rate_limiter::RateLimiter;

/// Asserts that `limiter` refuses `n` tokens, where `refill` after `since` is too short a time
/// for the tokens it lacks to arrive. A test that was stalled for longer asserts nothing: the
/// limiter may then be right to grant them.
fn assert_refused(limiter: &RateLimiter, n: u64, since: Instant, refill: Duration) {
    let granted = limiter.try_acquire(n);
    if since.elapsed() < refill {
        assert!(
            !granted,
            "{n} tokens granted by a bucket that cannot hold them yet"
        );
    }
}

/// One token a second: a test that ends within a second of building the limiter sees none.
const SLOW: u64 = 1;
const SLOW_REFILL: Duration = Duration::from_secs(1);

#[test]
fn a_new_bucket_is_full() {
    let limiter = RateLimiter::new(5, SLOW);
    assert!(limiter.try_acquire(5));
}

#[test]
fn a_request_above_the_capacity_is_refused_and_takes_nothing() {
    let limiter = RateLimiter::new(5, SLOW);
    assert!(!limiter.try_acquire(6));
    assert!(limiter.try_acquire(5));
}

#[test]
fn tokens_are_counted_across_requests() {
    let built = Instant::now();
    let limiter = RateLimiter::new(3, SLOW);
    assert!(limiter.try_acquire(1));
    assert!(limiter.try_acquire(2));
    assert_refused(&limiter, 1, built, SLOW_REFILL);
}

#[test]
fn a_refused_request_takes_no_tokens() {
    let built = Instant::now();
    let limiter = RateLimiter::new(5, SLOW);
    assert!(limiter.try_acquire(3));
    assert_refused(&limiter, 3, built, SLOW_REFILL);
    assert!(limiter.try_acquire(2));
}

#[test]
fn an_empty_bucket_refills() {
    // A token every nanosecond. The loop ends at the first grant, which a limiter that
    // refills reaches at once and one that does not never reaches.
    let limiter = RateLimiter::new(10, 1_000_000_000);
    assert!(limiter.try_acquire(10));
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut granted = false;
    while !granted && Instant::now() < deadline {
        granted = limiter.try_acquire(1);
    }
    assert!(
        granted,
        "no token came back in ten seconds at a token per nanosecond"
    );
}

#[test]
fn a_full_bucket_does_not_keep_filling() {
    // Ten thousand tokens a second: the wait is worth fifty tokens to a bucket without a
    // limit, and refilling the ten that are taken next takes a millisecond.
    let limiter = RateLimiter::new(10, 10_000);
    thread::sleep(Duration::from_millis(5));
    let drained = Instant::now();
    assert!(limiter.try_acquire(10));
    assert_refused(&limiter, 10, drained, Duration::from_millis(1));
}

#[test]
fn threads_that_share_a_bucket_take_each_token_once() {
    const CAPACITY: u64 = 1_000;
    let built = Instant::now();
    let limiter = RateLimiter::new(CAPACITY, SLOW);
    let granted = AtomicU64::new(0);
    thread::scope(|scope| {
        for _ in 0..8 {
            scope.spawn(|| {
                for _ in 0..CAPACITY {
                    if limiter.try_acquire(1) {
                        granted.fetch_add(1, Ordering::Relaxed);
                    }
                }
            });
        }
    });
    let granted = granted.into_inner();
    // Eight thousand requests for a thousand tokens: every token was there to take, and the
    // only others are the one a second that arrived while the threads ran.
    let refilled = built.elapsed().as_secs() * SLOW + 1;
    assert!(
        granted >= CAPACITY,
        "{granted} of {CAPACITY} tokens granted"
    );
    assert!(
        granted <= CAPACITY + refilled,
        "{granted} granted from {CAPACITY}"
    );
}
