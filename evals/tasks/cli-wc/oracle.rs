//! Outside check of the cli-wc task, run against the built `wcount` binary. The harness
//! copies this file into the crate as `tests/oracle.rs` after the session and the reviewer
//! are done, so the session never sees it. It asserts only what the task prompt states.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// A directory of this test's own, emptied first, inside the directory Cargo gives
/// integration tests: it goes with the build, and nothing is left in the system's.
fn scratch(test: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("wcount-oracle-{test}"));
    drop(fs::remove_dir_all(&dir));
    fs::create_dir_all(&dir).expect("the target directory is writable");
    dir
}

/// Writes `contents` to `name` in `dir` and returns the path as the tool will print it.
fn file(dir: &Path, name: &str, contents: impl AsRef<[u8]>) -> String {
    let path = dir.join(name);
    fs::write(&path, contents).expect("the scratch directory is writable");
    path.to_str()
        .expect("the temporary path is UTF-8")
        .to_owned()
}

fn wcount(args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_wcount"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the wcount binary starts");
    let mut pipe = child.stdin.take().expect("stdin is piped");
    // A tool that does not read standard input may have closed it already.
    drop(pipe.write_all(stdin.as_bytes()));
    drop(pipe);
    child.wait_with_output().expect("wcount exits")
}

/// Standard output as one list of whitespace-separated fields per line.
fn lines(output: &Output) -> Vec<Vec<String>> {
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| line.split_whitespace().map(str::to_owned).collect())
        .collect()
}

#[test]
fn one_file_prints_lines_words_bytes_and_its_name() {
    let dir = scratch("one");
    let path = file(&dir, "a.txt", "one two\nthree\n");
    let output = wcount(&[&path], "");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["2", "3", "14", path.as_str()]]);
}

#[test]
fn bytes_are_counted_not_characters() {
    let dir = scratch("bytes");
    let path = file(&dir, "utf8.txt", "h\u{e9}llo\n");
    assert_eq!(
        lines(&wcount(&[&path], "")),
        [["1", "1", "7", path.as_str()]]
    );
}

#[test]
fn a_file_that_is_not_utf8_is_counted_by_its_bytes() {
    let dir = scratch("not-utf8");
    let path = file(&dir, "latin1.txt", [0xFF, b'\n']);
    assert_eq!(
        lines(&wcount(&[&path], "")),
        [["1", "1", "2", path.as_str()]]
    );
}

#[test]
fn several_files_end_with_a_total_line() {
    let dir = scratch("total");
    let first = file(&dir, "a.txt", "one two\nthree\n");
    let second = file(&dir, "b.txt", "four\n");
    let output = wcount(&[&first, &second], "");
    assert!(output.status.success());
    assert_eq!(
        lines(&output),
        [
            vec!["2", "3", "14", first.as_str()],
            vec!["1", "1", "5", second.as_str()],
            vec!["3", "4", "19", "total"],
        ]
    );
}

#[test]
fn no_files_reads_standard_input() {
    let output = wcount(&[], "a b c\nd\n");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["2", "4", "8"]]);
}

#[test]
fn an_empty_file_counts_zero() {
    let dir = scratch("empty");
    let path = file(&dir, "empty.txt", "");
    assert_eq!(
        lines(&wcount(&[&path], "")),
        [["0", "0", "0", path.as_str()]]
    );
}

#[test]
fn an_unreadable_file_is_reported_and_the_rest_still_counted() {
    let dir = scratch("missing");
    let missing = dir.join("missing.txt");
    let missing = missing.to_str().expect("the temporary path is UTF-8");
    let present = file(&dir, "a.txt", "one two\nthree\n");
    let output = wcount(&[missing, &present], "");
    assert!(!output.status.success());
    assert!(
        !output.stderr.is_empty(),
        "the unreadable file is reported on standard error"
    );
    assert!(lines(&output).contains(&vec![
        "2".to_owned(),
        "3".to_owned(),
        "14".to_owned(),
        present.clone()
    ]));
}
