//! A correct solution of the varint task. The harness tests use it as the stub session's
//! work, which pins `tasks/varint/oracle.rs`: every oracle test must pass against it.

/// The buffer cannot hold the encoding.
#[derive(Debug)]
pub struct BufferTooSmall;

/// Why a byte slice is not a LEB128 `u64`.
#[derive(Debug)]
pub enum DecodeError {
    /// The input ended inside a value.
    Truncated,
    /// The encoding holds more than 64 bits.
    Overflow,
}

/// Encodes `value` as LEB128 into `buf` and returns the number of bytes written.
///
/// # Errors
///
/// Returns [`BufferTooSmall`] when `buf` cannot hold the encoding.
pub fn encode(mut value: u64, buf: &mut [u8]) -> Result<usize, BufferTooSmall> {
    let mut written = 0;
    loop {
        let slot = buf.get_mut(written).ok_or(BufferTooSmall)?;
        let low = value.to_le_bytes()[0] & 0x7F;
        value >>= 7;
        written += 1;
        if value == 0 {
            *slot = low;
            return Ok(written);
        }
        *slot = low | 0x80;
    }
}

/// Decodes one LEB128 `u64` from the start of `bytes` and returns it with its length.
///
/// # Errors
///
/// Returns a [`DecodeError`] when the input ends inside a value or does not fit in 64 bits.
pub fn decode(bytes: &[u8]) -> Result<(u64, usize), DecodeError> {
    let mut value = 0_u64;
    for (index, &byte) in bytes.iter().enumerate() {
        // Nine bytes carry 63 bits, so the tenth may hold only the top bit and must be last.
        if index == 9 && byte > 1 {
            return Err(DecodeError::Overflow);
        }
        value |= u64::from(byte & 0x7F) << (7 * index);
        if byte & 0x80 == 0 {
            return Ok((value, index + 1));
        }
    }
    Err(DecodeError::Truncated)
}
