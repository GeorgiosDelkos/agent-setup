use std::future::Future;

/// Reads a frame.
pub async fn read_frame() {}

pub fn connect() -> impl std::future::Future<Output = ()> {
    async {}
}

/// Multi-line signature.
pub fn spawn_it(
    x: u8,
) -> impl Future<Output = u8> {
    async move { x }
}

/// # Cancel safety
/// Safe.
fn unrelated() {}

/// The section above belongs to `unrelated`, not to this fn.
pub async fn after_unrelated() {}
