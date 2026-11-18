In this crate, write an append-only log file for a library. A record is a byte slice. Appending
writes the record with a length and a checksum; opening an existing log returns the records that
are intact and must cope with a crash that happened in the middle of an append. Include tests for
the crash cases.

The crate root exports `Log`. `Log::open(path: &Path)` creates the file when there is none and
returns a `Result` holding the log together with the intact records, oldest first:
`(Log, Vec<Vec<u8>>)`. `append(&mut self, record: &[u8])` returns a `Result`, and the record is
in the file when it returns.
