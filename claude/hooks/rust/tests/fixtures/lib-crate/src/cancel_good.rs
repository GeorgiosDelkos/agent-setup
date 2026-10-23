use std::future::Future;

/// Reads a frame.
///
/// # Cancel safety
///
/// Cancel safe: no data is consumed until the frame is complete.
#[inline]
#[cfg_attr(
    docsrs,
    doc(cfg(feature = "x"))
)]
pub async fn read_frame() {}

/// # Cancel Safety
/// Not cancel safe.
pub fn connect() -> impl Future<Output = ()> {
    async {}
}

pub(crate) async fn internal() {}

pub fn sync_fn() -> u8 {
    0
}

async fn private() {}
