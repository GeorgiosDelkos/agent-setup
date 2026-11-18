//! A correct solution of the rate-limiter task. The harness tests use it as the stub session's
//! work, which pins `tasks/rate-limiter/oracle.rs`: every oracle test must pass against it.
//! It reads the system clock directly, so it has no tests of its own that do not sleep.

use std::sync::{Mutex, PoisonError};
use std::time::Instant;

/// Billionths of a token per token. Tokens are counted in billionths so that the refill for
/// any elapsed time, which `Instant` gives in nanoseconds, is exact: `nanoseconds * rate`.
const NANOS: u128 = 1_000_000_000;

/// A token bucket that threads share by reference.
#[derive(Debug)]
pub struct RateLimiter {
    capacity: u64,
    refill_per_second: u64,
    bucket: Mutex<Bucket>,
}

#[derive(Debug)]
struct Bucket {
    /// Billionths of a token, at most `capacity * NANOS`.
    nanotokens: u128,
    /// When `nanotokens` was last brought up to date.
    refilled: Instant,
}

impl RateLimiter {
    /// Returns a full bucket of `capacity` tokens that gains `refill_per_second` a second.
    pub fn new(capacity: u64, refill_per_second: u64) -> Self {
        Self {
            capacity,
            refill_per_second,
            bucket: Mutex::new(Bucket {
                nanotokens: u128::from(capacity) * NANOS,
                refilled: Instant::now(),
            }),
        }
    }

    /// Takes `n` tokens and returns true, or takes none and returns false.
    pub fn try_acquire(&self, n: u64) -> bool {
        // A panic cannot leave the bucket half updated: both fields are assigned from values
        // computed first.
        let mut bucket = self.bucket.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        let gained = (now - bucket.refilled)
            .as_nanos()
            .saturating_mul(u128::from(self.refill_per_second));
        let full = u128::from(self.capacity) * NANOS;
        bucket.nanotokens = bucket.nanotokens.saturating_add(gained).min(full);
        bucket.refilled = now;

        let wanted = u128::from(n) * NANOS;
        if bucket.nanotokens < wanted {
            return false;
        }
        bucket.nanotokens -= wanted;
        true
    }
}
