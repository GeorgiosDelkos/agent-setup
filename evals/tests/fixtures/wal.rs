//! A correct solution of the wal task. The harness tests use it as the stub session's work,
//! which pins `tasks/wal/oracle.rs`: every oracle test must pass against it.
//!
//! A record in the file is its length as a little-endian `u32`, the CRC-32 of that length and
//! the payload as a little-endian `u32`, then the payload. The checksum covers the length so
//! that a tail of zero bytes is not read as empty records.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

/// An append-only log of byte records. One writer at a time: nothing locks the file.
#[derive(Debug)]
pub struct Log {
    file: File,
    /// Set when a write or a sync failed. The tail of the file is then unknown, and a record
    /// written behind torn bytes would be cut off with them at the next open.
    failed: bool,
}

impl Log {
    /// Opens the log at `path`, creating it when missing, and returns it with its intact
    /// records, oldest first. Bytes after the last intact record are removed from the file.
    /// The directory is not synced: after a crash, a log this call created may be missing,
    /// with the records appended to it.
    ///
    /// # Errors
    ///
    /// Returns the error of opening, reading, truncating or syncing the file.
    pub fn open(path: &Path) -> io::Result<(Self, Vec<Vec<u8>>)> {
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(path)?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;

        let mut records = Vec::new();
        let mut intact = 0;
        while let Some(payload) = record_at(&bytes[intact..]) {
            intact += 8 + payload.len();
            records.push(payload.to_vec());
        }
        // Without this an append would land behind the torn bytes and be read as part of them.
        file.set_len(intact as u64)?;
        file.sync_all()?;
        let log = Self {
            file,
            failed: false,
        };
        Ok((log, records))
    }

    /// Appends `record` and returns once it is on disk.
    ///
    /// # Errors
    ///
    /// Returns an error when `record` is longer than `u32::MAX` bytes, or the error of the
    /// write or the sync. After such a failure every later append is refused: open the log
    /// again, which removes what the failed write left.
    pub fn append(&mut self, record: &[u8]) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::other(
                "an earlier append failed: open the log again",
            ));
        }
        let len = u32::try_from(record.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "record over 4 GiB"))?
            .to_le_bytes();
        let mut framed = Vec::with_capacity(8 + record.len());
        framed.extend_from_slice(&len);
        framed.extend_from_slice(&checksum(len, record).to_le_bytes());
        framed.extend_from_slice(record);
        let written = self
            .file
            .write_all(&framed)
            .and_then(|()| self.file.sync_data());
        self.failed = written.is_err();
        written
    }
}

/// The payload of the record at the start of `bytes`, or `None` when the bytes end inside it
/// or its checksum does not match.
fn record_at(bytes: &[u8]) -> Option<&[u8]> {
    let (len, rest) = bytes.split_first_chunk::<4>()?;
    let (stored, rest) = rest.split_first_chunk::<4>()?;
    let payload = rest.get(..u32::from_le_bytes(*len) as usize)?;
    (checksum(*len, payload) == u32::from_le_bytes(*stored)).then_some(payload)
}

/// CRC-32 (the IEEE polynomial, reflected: `0xEDB8_8320`) of `len` followed by `payload`,
/// one bit at a time.
fn checksum(len: [u8; 4], payload: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for &byte in len.iter().chain(payload) {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 == 0 {
                crc >> 1
            } else {
                (crc >> 1) ^ 0xEDB8_8320
            };
        }
    }
    !crc
}
