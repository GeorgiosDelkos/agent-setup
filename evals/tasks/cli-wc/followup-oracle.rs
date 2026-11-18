//! Outside check of the cli-wc task's follow-up, the `-l`, `-w` and `-c` flags, run against
//! the built `wcount` binary. The harness copies this file into the crate as
//! `tests/eval_followup.rs` after the follow-up session is done, so no session sees it. It
//! asserts only what the two prompts state.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// A directory of this test's own, emptied first, inside the directory Cargo gives
/// integration tests, holding `a.txt` (2 lines, 3 words, 14 bytes) and `b.txt` (1, 1, 5).
fn scratch(test: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("wcount-followup-{test}"));
    drop(fs::remove_dir_all(&dir));
    fs::create_dir_all(&dir).expect("the target directory is writable");
    fs::write(dir.join("a.txt"), "one two\nthree\n").expect("the scratch directory is writable");
    fs::write(dir.join("b.txt"), "four\n").expect("the scratch directory is writable");
    dir
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
fn one_flag_prints_one_count_and_the_name() {
    let dir = scratch("one-flag");
    assert_eq!(lines(&wcount(&dir, &["-l", "a.txt"], "")), [["2", "a.txt"]]);
    assert_eq!(lines(&wcount(&dir, &["-w", "a.txt"], "")), [["3", "a.txt"]]);
    assert_eq!(
        lines(&wcount(&dir, &["-c", "a.txt"], "")),
        [["14", "a.txt"]]
    );
}

#[test]
fn the_counts_keep_their_order_whatever_the_order_of_the_flags() {
    let dir = scratch("order");
    let output = wcount(&dir, &["-c", "-l", "a.txt"], "");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["2", "14", "a.txt"]]);
}

#[test]
fn flags_can_be_combined_in_one_argument() {
    let dir = scratch("combined");
    assert_eq!(
        lines(&wcount(&dir, &["-cw", "a.txt"], "")),
        [["3", "14", "a.txt"]]
    );
    assert_eq!(
        lines(&wcount(&dir, &["-lwc", "a.txt"], "")),
        [["2", "3", "14", "a.txt"]]
    );
}

#[test]
fn the_total_line_has_the_selected_counts_only() {
    let dir = scratch("total");
    let output = wcount(&dir, &["-w", "a.txt", "b.txt"], "");
    assert_eq!(
        lines(&output),
        [["3", "a.txt"], ["1", "b.txt"], ["4", "total"]]
    );
}

#[test]
fn a_flag_applies_to_standard_input() {
    let output = wcount(&scratch("stdin"), &["-c"], "a b c\nd\n");
    assert!(output.status.success());
    assert_eq!(lines(&output), [["8"]]);
}

#[test]
fn an_unknown_flag_is_an_error_and_nothing_is_counted() {
    let dir = scratch("unknown");
    for args in [["-x", "a.txt"], ["-lx", "a.txt"]] {
        let output = wcount(&dir, &args, "");
        assert!(!output.status.success(), "{args:?}");
        assert!(!output.stderr.is_empty(), "{args:?} is reported");
        assert!(output.stdout.is_empty(), "{args:?} prints no count");
    }
}

#[test]
fn no_flag_prints_all_three_counts_as_before() {
    let dir = scratch("no-flag");
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
    // Bytes, as the first prompt says: this file has six characters in seven bytes.
    fs::write(dir.join("utf8.txt"), "h\u{e9}llo\n").expect("the scratch directory is writable");
    assert_eq!(
        lines(&wcount(&dir, &["utf8.txt"], "")),
        [["1", "1", "7", "utf8.txt"]]
    );
    assert_eq!(lines(&wcount(&dir, &["-c", "utf8.txt"], "")), [["7", "utf8.txt"]]);
}
