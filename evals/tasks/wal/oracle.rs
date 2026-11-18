//! Outside check of the wal task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.
//!
//! The prompt fixes no file format, so the crash cases are made from the outside: the tests
//! note the file's length after each record and cut or change the file at those offsets.
//! The bytes one append adds may hold more than the prompt asks to protect (padding, say),
//! so a test that needs the record itself damaged looks for the payload's bytes in the file.

use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

use wal::Log;

/// The path of a log that does not exist yet, in a directory of this test's own, emptied
/// first, inside the directory Cargo gives integration tests.
fn fresh_log(test: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("wal-oracle-{test}"));
    drop(fs::remove_dir_all(&dir));
    fs::create_dir_all(&dir).expect("the target directory is writable");
    dir.join("log")
}

/// Opens the log. `let ... else` here and `is_ok` below, not `unwrap`: the prompt asks for no
/// `Debug` on the error type.
fn open(path: &Path) -> (Log, Vec<Vec<u8>>) {
    let Ok(opened) = Log::open(path) else {
        panic!("{} must open", path.display());
    };
    opened
}

/// The records an open returns, with the log closed again.
fn records(path: &Path) -> Vec<Vec<u8>> {
    open(path).1
}

fn append(log: &mut Log, record: &[u8]) {
    assert!(
        log.append(record).is_ok(),
        "a record of {} bytes is appended",
        record.len()
    );
}

/// Appends each record through an open of its own and returns the file's length after each,
/// taken once the log is closed, so a log that buffers until then is measured whole.
fn write_log(path: &Path, records: &[&[u8]]) -> Vec<usize> {
    let mut ends = Vec::new();
    for record in records {
        let (mut log, _) = open(path);
        append(&mut log, record);
        drop(log);
        ends.push(fs::read(path).expect("the log file is readable").len());
    }
    ends
}

/// A payload whose bytes occur nowhere else in a small log: no length, checksum or padding
/// a format puts around it is likely to hold the same 23 bytes. An odd length, so that a
/// format that pads its records has padding to write after it.
const MARKED: &[u8; 23] = b"\xA5payload-of-the-oracle\xC3";

/// Where `payload` lies in the bytes `added` of `file`, when the format stores it as it is.
/// `None` for a format that encodes its payloads: such a log is held only to what can be
/// asked without knowing where the record's bytes are.
fn payload_in(file: &[u8], added: Range<usize>, payload: &[u8]) -> Option<Range<usize>> {
    let start = added.start
        + file[added]
            .windows(payload.len())
            .position(|window| window == payload)?;
    Some(start..start + payload.len())
}

/// Asserts what a log holding `earlier` and then one more append of `MARKED` returns when
/// that append is cut short at every byte: `added` is the range of the file the append
/// wrote. A cut that leaves part of the payload out loses the record. A cut after the
/// payload may keep it, when what follows is not needed to trust it, or lose it.
fn assert_cuts_lose_at_most_the_last_record(path: &Path, added: Range<usize>, earlier: &[&[u8]]) {
    let whole = fs::read(path).expect("the log file is readable");
    let payload_end = payload_in(&whole, added.clone(), MARKED).map(|payload| payload.end);
    let earlier: Vec<Vec<u8>> = earlier.iter().map(|record| record.to_vec()).collect();
    let mut complete = earlier.clone();
    complete.push(MARKED.to_vec());
    for cut in added {
        fs::write(path, &whole[..cut]).expect("the log file is writable");
        let found = records(path);
        if payload_end.is_some_and(|end| cut < end) {
            assert_eq!(found, earlier, "file cut at byte {cut}, inside the record");
        } else {
            assert!(
                found == earlier || found == complete,
                "file cut at byte {cut} of {}: {} records",
                whole.len(),
                found.len()
            );
        }
    }
}

#[test]
fn opening_a_missing_file_creates_an_empty_log() {
    let path = fresh_log("create");
    assert!(records(&path).is_empty());
    assert!(path.exists());
    assert!(records(&path).is_empty());
}

#[test]
fn records_come_back_in_order_from_one_open_and_from_several() {
    let path = fresh_log("order");
    let (mut log, _) = open(&path);
    append(&mut log, b"one");
    append(&mut log, b"two");
    drop(log);

    let (mut log, found) = open(&path);
    assert_eq!(found, [b"one".to_vec(), b"two".to_vec()]);
    append(&mut log, b"three");
    drop(log);

    assert_eq!(
        records(&path),
        [b"one".to_vec(), b"two".to_vec(), b"three".to_vec()]
    );
}

#[test]
fn a_record_is_any_bytes_of_any_length() {
    let path = fresh_log("bytes");
    let large: Vec<u8> = (0..=u8::MAX).cycle().take(100_000).collect();
    let all: [&[u8]; 5] = [b"", &[0, 0, 0, 0], &[0xFF; 9], &large, b""];
    write_log(&path, &all);
    assert_eq!(records(&path), all.map(<[u8]>::to_vec));
}

#[test]
fn a_record_is_in_the_file_when_append_returns() {
    let path = fresh_log("durable");
    let copy = path.with_extension("copy");
    let (mut log, _) = open(&path);
    append(&mut log, b"one");
    // Copied while the log is still open: a log that keeps the record in memory until it is
    // closed has nothing in the file yet. A copy, so that no second open touches a file the
    // log may hold a lock on.
    fs::copy(&path, &copy).expect("the log file can be copied");
    assert_eq!(records(&copy), [b"one".to_vec()]);
    drop(log);
}

#[test]
fn a_tail_of_zeros_holds_no_records() {
    let path = fresh_log("zero-tail");
    write_log(&path, &[b"first", b"second"]);
    // A crash can leave the file extended with zeros where the record's bytes never arrived.
    let mut bytes = fs::read(&path).expect("the log file is readable");
    bytes.extend_from_slice(&[0; 4096]);
    fs::write(&path, &bytes).expect("the log file is writable");

    let (mut log, found) = open(&path);
    assert_eq!(found, [b"first".to_vec(), b"second".to_vec()]);
    append(&mut log, b"third");
    drop(log);
    assert_eq!(
        records(&path),
        [b"first".to_vec(), b"second".to_vec(), b"third".to_vec()]
    );
}

#[test]
fn an_append_cut_short_at_any_byte_loses_only_that_record() {
    let path = fresh_log("torn-last");
    let ends = write_log(&path, &[b"first", b"second", MARKED]);
    assert_cuts_lose_at_most_the_last_record(&path, ends[1]..ends[2], &[b"first", b"second"]);
}

#[test]
fn a_first_append_cut_short_leaves_an_empty_log() {
    let path = fresh_log("torn-first");
    // From byte 0: a log that writes a header before its first record is cut inside it too.
    let ends = write_log(&path, &[MARKED]);
    assert_cuts_lose_at_most_the_last_record(&path, 0..ends[0], &[]);
}

#[test]
fn a_record_appended_after_a_torn_tail_is_kept() {
    let path = fresh_log("append-after-torn");
    let ends = write_log(&path, &[b"first", b"second"]);
    let whole = fs::read(&path).expect("the log file is readable");
    fs::write(&path, &whole[..ends[1] - 1]).expect("the log file is writable");

    let (mut log, found) = open(&path);
    assert_eq!(found, [b"first".to_vec()]);
    // Written after the torn bytes without removing them, this record would be read as part
    // of the torn one and lost.
    append(&mut log, b"third");
    drop(log);

    assert_eq!(records(&path), [b"first".to_vec(), b"third".to_vec()]);
}

#[test]
fn a_changed_bit_anywhere_in_the_last_payload_drops_the_record() {
    let path = fresh_log("flipped-last");
    let ends = write_log(&path, &[b"first", MARKED]);
    let whole = fs::read(&path).expect("the log file is readable");
    // Only the payload's own bytes: the prompt asks for a checksum of the record, not of
    // every byte a format writes with it.
    let Some(payload) = payload_in(&whole, ends[0]..ends[1], MARKED) else {
        return;
    };
    for at in payload {
        let mut changed = whole.clone();
        changed[at] ^= 0x01;
        fs::write(&path, &changed).expect("the log file is writable");
        assert_eq!(
            records(&path),
            [b"first".to_vec()],
            "bit changed in byte {at}"
        );
    }
}

#[test]
fn a_damaged_record_in_the_middle_is_not_returned() {
    let path = fresh_log("flipped-middle");
    let middle = [0x5A_u8; 1_000];
    let ends = write_log(&path, &[b"first", &middle, b"last"]);
    let mut changed = fs::read(&path).expect("the log file is readable");
    // Halfway through the middle record's bytes: inside its thousand-byte payload, whatever
    // the format puts around it.
    changed[usize::midpoint(ends[0], ends[1])] ^= 0x01;
    fs::write(&path, &changed).expect("the log file is writable");

    let found = records(&path);
    // The prompt does not say whether the intact record after the damage is returned.
    assert_eq!(found.first().map(Vec::as_slice), Some(b"first".as_slice()));
    assert!(found.iter().all(|record| record.len() != middle.len()));
}
