//! Outside check of the wal task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.
//!
//! The prompt fixes no file format, so the crash cases are made from the outside: the tests
//! note the file's length after each record and cut or change the file at those offsets.

use std::fs;
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
    let large: Vec<u8> = (0..100_000_u32).map(|n| n.to_le_bytes()[0]).collect();
    let all: [&[u8]; 5] = [b"", &[0, 0, 0, 0], &[0xFF; 9], &large, b""];
    write_log(&path, &all);
    assert_eq!(records(&path), all.map(<[u8]>::to_vec));
}

#[test]
fn an_append_cut_short_at_any_byte_loses_only_that_record() {
    let path = fresh_log("torn-last");
    let ends = write_log(&path, &[b"first", b"second", b"the third record"]);
    let whole = fs::read(&path).expect("the log file is readable");
    for cut in ends[1] + 1..ends[2] {
        fs::write(&path, &whole[..cut]).expect("the log file is writable");
        assert_eq!(
            records(&path),
            [b"first".to_vec(), b"second".to_vec()],
            "file cut at byte {cut} of {}",
            whole.len()
        );
    }
}

#[test]
fn a_first_append_cut_short_leaves_an_empty_log() {
    let path = fresh_log("torn-first");
    let ends = write_log(&path, &[b"the only record"]);
    let whole = fs::read(&path).expect("the log file is readable");
    for cut in 0..ends[0] {
        fs::write(&path, &whole[..cut]).expect("the log file is writable");
        assert!(
            records(&path).is_empty(),
            "file cut at byte {cut} of {}",
            whole.len()
        );
    }
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
fn a_changed_bit_anywhere_in_the_last_record_drops_it() {
    let path = fresh_log("flipped-last");
    let ends = write_log(&path, &[b"first", b"the second record"]);
    let whole = fs::read(&path).expect("the log file is readable");
    for at in ends[0]..ends[1] {
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
