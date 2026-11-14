In this crate, write LEB128 variable-length integer encoding for `u64`: encode into a
caller-provided buffer, and decode from a byte slice returning the value and the number of bytes
read. Decoding must reject truncated input and encodings longer than a `u64` allows. Include
tests.
