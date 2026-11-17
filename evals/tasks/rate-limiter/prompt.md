In this crate, write a token bucket rate limiter that many threads share. It is built with a
capacity and a refill rate in tokens per second, and `try_acquire(n)` either takes n tokens or
reports that it cannot. The tests must not sleep.
