In this crate, write a parser for a config format with one `key = value` per line. `#` starts a
comment, blank and whitespace-only lines are skipped, a key is one or more letters, digits and
`_`, and a value is the rest of the line with surrounding whitespace removed, which may leave
it empty. A duplicate key is an error. Errors must tell the user which line is wrong and why.
Include tests.

The crate root exports `parse(input: &str)`. It returns a `Result` holding the pairs in file
order, as a `Vec` of `(key, value)` tuples. The error's `Display` output names the line, counted
from 1.
