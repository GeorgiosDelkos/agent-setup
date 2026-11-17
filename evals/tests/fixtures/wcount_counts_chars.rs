//! A solution of the cli-wc task with one defect: it counts characters where the task asks
//! for bytes. The harness tests use it as the stub session's work, which pins
//! `tasks/cli-wc/oracle.rs`: only the oracle's byte-count test may fail against it.

use std::io::Read;
use std::process::ExitCode;

/// Lines, words and (wrongly) characters of `bytes`. A lone invalid byte counts as one
/// character, so the oracle's file that is not UTF-8 does not show the defect.
fn count(bytes: &[u8]) -> [usize; 3] {
    [
        // One piece more than there are newlines.
        bytes.split(|&byte| byte == b'\n').count() - 1,
        bytes
            .split(u8::is_ascii_whitespace)
            .filter(|word| !word.is_empty())
            .count(),
        String::from_utf8_lossy(bytes).chars().count(),
    ]
}

#[expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a command-line tool prints its counts and its errors from main"
)]
fn main() -> ExitCode {
    let paths: Vec<String> = std::env::args().skip(1).collect();
    if paths.is_empty() {
        let mut input = Vec::new();
        if std::io::stdin().read_to_end(&mut input).is_err() {
            return ExitCode::FAILURE;
        }
        let [lines, words, bytes] = count(&input);
        println!("{lines} {words} {bytes}");
        return ExitCode::SUCCESS;
    }

    let mut total = [0; 3];
    let mut failed = false;
    for path in &paths {
        match std::fs::read(path) {
            Ok(contents) => {
                let counts = count(&contents);
                println!("{} {} {} {path}", counts[0], counts[1], counts[2]);
                for (sum, count) in total.iter_mut().zip(counts) {
                    *sum += count;
                }
            }
            Err(error) => {
                eprintln!("wcount: {path}: {error}");
                failed = true;
            }
        }
    }
    if paths.len() > 1 {
        println!("{} {} {} total", total[0], total[1], total[2]);
    }
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
