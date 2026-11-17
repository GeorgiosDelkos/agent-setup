//! A solution of the cli-wc task with one defect: it counts characters where the task asks
//! for bytes. The harness tests use it as the stub session's work, which pins
//! `tasks/cli-wc/oracle.rs`: only the oracle's byte-count test may fail against it.

use std::io::Read;
use std::process::ExitCode;

/// Lines, words and (wrongly) characters of `text`.
fn count(text: &str) -> [usize; 3] {
    [
        text.matches('\n').count(),
        text.split_whitespace().count(),
        text.chars().count(),
    ]
}

fn main() -> ExitCode {
    let paths: Vec<String> = std::env::args().skip(1).collect();
    if paths.is_empty() {
        let mut text = String::new();
        if std::io::stdin().read_to_string(&mut text).is_err() {
            return ExitCode::FAILURE;
        }
        let [lines, words, bytes] = count(&text);
        println!("{lines} {words} {bytes}");
        return ExitCode::SUCCESS;
    }

    let mut total = [0; 3];
    let mut failed = false;
    for path in &paths {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let counts = count(&text);
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
