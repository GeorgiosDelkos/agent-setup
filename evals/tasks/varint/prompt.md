In this crate, write LEB128 variable-length integer encoding for `u64`: encode into a
caller-provided buffer, and decode from a byte slice returning the value and the number of bytes
read. Decoding must reject truncated input and encodings that do not fit in a `u64`. Include
tests.

The crate root exports two functions. `encode(value: u64, buf: &mut [u8])` returns a `Result`
holding the number of bytes written, or an error when the buffer is too small.
`decode(bytes: &[u8])` returns a `Result` holding `(value, bytes_read)`.
