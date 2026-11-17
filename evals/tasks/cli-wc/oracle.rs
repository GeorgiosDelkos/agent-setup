//! Outside check of the cli-wc task, run against the built `wcount` binary. The harness
//! copies this file into the crate as `tests/eval_oracle.rs` after the session and the reviewer
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

fn write(dir: &Path, name: &str, contents: impl AsRef<[u8]>) {
    fs::write(dir.join(name), contents).expect("the scratch directory is writable");
}

/// Runs `wcount` in `dir`, so files are named by a bare file name. The tests split each
/// output line on whitespace, and the path of `dir` may hold a space.
fn wcount(dir: &Path, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_wcount"))
        .current_dir(dir)
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
    write(&dir, "a.txt", "one two\nthree\n");
    let output = wcount(&dir, &["a.txt"], "");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["2", "3", "14", "a.txt"]]);
}

#[test]
fn bytes_are_counted_not_characters() {
    let dir = scratch("bytes");
    write(&dir, "utf8.txt", "h\u{e9}llo\n");
    let output = wcount(&dir, &["utf8.txt"], "");
    assert_eq!(lines(&output), [["1", "1", "7", "utf8.txt"]]);
}

#[test]
fn a_file_that_is_not_utf8_is_counted_by_its_bytes() {
    let dir = scratch("not-utf8");
    write(&dir, "latin1.txt", [0xFF, b'\n']);
    let output = wcount(&dir, &["latin1.txt"], "");
    assert_eq!(lines(&output), [["1", "1", "2", "latin1.txt"]]);
}

#[test]
fn several_files_end_with_a_total_line() {
    let dir = scratch("total");
    write(&dir, "a.txt", "one two\nthree\n");
    write(&dir, "b.txt", "four\n");
    let output = wcount(&dir, &["a.txt", "b.txt"], "");
    assert!(output.status.success());
    assert_eq!(
        lines(&output),
        [
            ["2", "3", "14", "a.txt"],
            ["1", "1", "5", "b.txt"],
            ["3", "4", "19", "total"],
        ]
    );
}

#[test]
fn no_files_reads_standard_input() {
    let output = wcount(&scratch("stdin"), &[], "a b c\nd\n");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["2", "4", "8"]]);
}

#[test]
fn an_empty_file_counts_zero() {
    let dir = scratch("empty");
    write(&dir, "empty.txt", "");
    let output = wcount(&dir, &["empty.txt"], "");
    assert_eq!(lines(&output), [["0", "0", "0", "empty.txt"]]);
}

#[test]
fn text_after_the_last_newline_is_no_line() {
    let dir = scratch("no-newline");
    write(&dir, "plain.txt", "hello");
    let output = wcount(&dir, &["plain.txt"], "");
    assert_eq!(lines(&output), [["0", "1", "5", "plain.txt"]]);
}

#[test]
fn an_unreadable_file_is_reported_and_the_rest_still_counted() {
    let dir = scratch("missing");
    write(&dir, "a.txt", "one two\nthree\n");
    let output = wcount(&dir, &["missing.txt", "a.txt"], "");
    assert!(!output.status.success());
    assert!(
        !output.stderr.is_empty(),
        "the unreadable file is reported on standard error"
    );
    let counted: Vec<String> = ["2", "3", "14", "a.txt"].map(str::to_owned).into();
    assert!(lines(&output).contains(&counted));
}
