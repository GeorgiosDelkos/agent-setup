//! Outside check of the varint task's follow-up, the signed functions. The harness copies this
//! file into the crate as `tests/eval_followup.rs` after the follow-up session is done, so no
//! session sees it. It asserts only what the two prompts state.

use varint::{decode, decode_signed, encode, encode_signed};

/// The zigzag LEB128 encoding of `value`, through a buffer of the largest size an `i64` needs.
///
/// `let ... else` here and below, not `unwrap` or `expect`: those need the error type to
/// implement `Debug`, which the prompts do not ask for.
fn encoded(value: i64) -> Vec<u8> {
    let mut buf = [0_u8; 10];
    let Ok(written) = encode_signed(value, &mut buf) else {
        panic!("ten bytes hold any i64, {value} included");
    };
    buf[..written].to_vec()
}

/// The signed value at the start of `bytes` and the number of bytes it took.
fn decoded(bytes: &[u8]) -> (i64, usize) {
    let Ok(decoded) = decode_signed(bytes) else {
        panic!("{bytes:02X?} must decode");
    };
    decoded
}

#[test]
fn known_zigzag_encodings() {
    assert_eq!(encoded(0), [0x00]);
    assert_eq!(encoded(-1), [0x01]);
    assert_eq!(encoded(1), [0x02]);
    assert_eq!(encoded(-2), [0x03]);
    assert_eq!(encoded(63), [0x7E]);
    assert_eq!(encoded(-64), [0x7F]);
    assert_eq!(encoded(64), [0x80, 0x01]);
    assert_eq!(encoded(-65), [0x81, 0x01]);
}

#[test]
fn the_extremes_take_ten_bytes() {
    assert_eq!(
        encoded(i64::MAX),
        [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    );
    assert_eq!(
        encoded(i64::MIN),
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    );
}

#[test]
fn round_trips_at_every_length_boundary_on_both_sides_of_zero() {
    let mut values = vec![0, i64::MIN, i64::MAX];
    // A zigzag value of n bits is a magnitude of n - 1 bits.
    for bits in (6..63).step_by(7) {
        let edge = 1_i64 << bits;
        values.extend([edge - 1, edge, -edge, -edge - 1]);
    }
    for value in values {
        let bytes = encoded(value);
        assert_eq!(decoded(&bytes), (value, bytes.len()), "value {value}");
    }
}

#[test]
fn encode_signed_reports_a_buffer_that_is_too_small() {
    assert!(encode_signed(-65, &mut [0_u8; 1]).is_err());
    assert!(encode_signed(i64::MIN, &mut [0_u8; 9]).is_err());
    assert!(encode_signed(0, &mut []).is_err());
    assert!(matches!(encode_signed(-65, &mut [0_u8; 2]), Ok(2)));
}

#[test]
fn decode_signed_stops_after_the_first_value() {
    assert_eq!(decoded(&[0x01, 0x02]), (-1, 1));
    assert_eq!(decoded(&[0x81, 0x01, 0x80]), (-65, 2));
}

#[test]
fn decode_signed_rejects_truncated_input_and_what_does_not_fit() {
    assert!(decode_signed(&[]).is_err());
    assert!(decode_signed(&[0x80]).is_err());
    // Nine bytes carry 63 bits, so the tenth may hold only the top bit.
    let mut bytes = [0xFF_u8; 10];
    bytes[9] = 0x02;
    assert!(decode_signed(&bytes).is_err());
}

#[test]
fn the_unsigned_functions_are_unchanged() {
    let mut buf = [0_u8; 10];
    assert!(matches!(encode(300, &mut buf), Ok(2)));
    assert_eq!(buf[..2], [0xAC, 0x02]);
    // The same byte is 1 unsigned and -1 signed.
    assert!(matches!(decode(&[0x01]), Ok((1, 1))));
    // What the first prompt asks `decode` to reject, it still rejects.
    assert!(decode(&[0x80]).is_err());
    let mut overflowing = [0xFF_u8; 10];
    overflowing[9] = 0x02;
    assert!(decode(&overflowing).is_err());
}
