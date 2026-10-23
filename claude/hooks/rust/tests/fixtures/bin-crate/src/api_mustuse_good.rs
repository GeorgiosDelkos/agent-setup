#[must_use = "the guard releases the lock when dropped"]
pub struct Guard;

#[must_use]
pub fn compute() -> u8 {
    0
}

// #[must_use]
struct Plain;
