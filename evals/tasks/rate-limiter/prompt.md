In this crate, write a token bucket rate limiter that many threads share. It is built with a
capacity and a refill rate in tokens per second, and `try_acquire(n)` either takes n tokens or
reports that it cannot. The tests must not sleep.

The crate root exports `RateLimiter`. `RateLimiter::new(capacity: u64, refill_per_second: u64)`
makes a full bucket, and `try_acquire(&self, n: u64)` returns `true` when it took the tokens.
