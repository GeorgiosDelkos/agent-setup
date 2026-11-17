//! Outside check of the varint task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use varint::{decode, encode};

/// The LEB128 encoding of `value`, through a buffer of the largest size a `u64` needs.
///
/// `let ... else` here and below, not `unwrap` or `expect`: those need the error type to
/// implement `Debug`, which the prompt does not ask for.
fn encoded(value: u64) -> Vec<u8> {
    let mut buf = [0_u8; 10];
    let Ok(written) = encode(value, &mut buf) else {
        panic!("ten bytes hold any u64, {value} included");
    };
    buf[..written].to_vec()
}

/// The value at the start of `bytes` and the number of bytes it took.
fn decoded(bytes: &[u8]) -> (u64, usize) {
    let Ok(decoded) = decode(bytes) else {
        panic!("{bytes:02X?} must decode");
    };
    decoded
}

#[test]
fn known_encodings() {
    assert_eq!(encoded(0), [0x00]);
    assert_eq!(encoded(127), [0x7F]);
    assert_eq!(encoded(128), [0x80, 0x01]);
    assert_eq!(encoded(300), [0xAC, 0x02]);
    assert_eq!(
        encoded(u64::MAX),
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    );
}

#[test]
fn round_trips_at_every_length_boundary() {
    let mut values = vec![0, u64::MAX];
    for bits in (7..64).step_by(7) {
        values.push((1 << bits) - 1);
        values.push(1 << bits);
    }
    for value in values {
        let bytes = encoded(value);
        assert_eq!(decoded(&bytes), (value, bytes.len()), "value {value}");
    }
}

#[test]
fn encode_reports_a_buffer_that_is_too_small() {
    assert!(encode(300, &mut [0_u8; 1]).is_err());
    assert!(encode(u64::MAX, &mut [0_u8; 9]).is_err());
    assert!(encode(0, &mut []).is_err());
    assert!(matches!(encode(300, &mut [0_u8; 2]), Ok(2)));
}

#[test]
fn decode_stops_after_the_first_value() {
    assert_eq!(decoded(&[0x7F, 0xFF, 0xFF]), (127, 1));
    assert_eq!(decoded(&[0xAC, 0x02, 0x80]), (300, 2));
}

#[test]
fn decode_rejects_truncated_input() {
    assert!(decode(&[]).is_err());
    assert!(decode(&[0x80]).is_err());
    assert!(decode(&[0xFF, 0xFF, 0xFF]).is_err());
}

#[test]
fn decode_rejects_more_bytes_than_a_u64_takes() {
    let mut bytes = [0x80_u8; 11];
    bytes[10] = 0x01;
    assert!(decode(&bytes).is_err());
}

#[test]
fn decode_rejects_a_tenth_byte_that_overflows_u64() {
    // Nine bytes carry 63 bits, so the tenth may hold only the top bit.
    let mut bytes = [0xFF_u8; 10];
    bytes[9] = 0x02;
    assert!(decode(&bytes).is_err());
}
