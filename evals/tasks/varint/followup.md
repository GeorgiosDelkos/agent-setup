Add signed integers to this crate. `encode_signed(value: i64, buf: &mut [u8])` and
`decode_signed(bytes: &[u8])` work like `encode` and `decode` and return the same shapes, with
an `i64` value. They use zigzag encoding, as Protocol Buffers does for `sint64`, so that small
negative numbers stay short. Include tests.
