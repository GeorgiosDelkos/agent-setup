In this crate, write a parser for a config format with one `key = value` per line. `#` starts a
comment, blank lines are skipped, a key is letters, digits and `_`, and a value is the rest of the
line with surrounding whitespace removed. A duplicate key is an error. Errors must tell the user
which line is wrong and why. Include tests.
