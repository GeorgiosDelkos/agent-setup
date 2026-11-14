In this crate, write an append-only log file for a library. A record is a byte slice. Appending
writes the record with a length and a checksum; opening an existing log returns the records that
are intact and must cope with a crash that happened in the middle of an append. Include tests for
the crash cases.
