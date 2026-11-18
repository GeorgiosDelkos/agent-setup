//! A correct solution of the cli-wc task after its follow-up. The harness tests use it as the
//! stub follow-up session's work, which pins `tasks/cli-wc/followup-oracle.rs`: every test
//! of that oracle must pass against it.

use std::io::Read;
use std::process::ExitCode;

/// Lines, words and bytes of `bytes`.
fn count(bytes: &[u8]) -> [usize; 3] {
    [
        // One piece more than there are newlines.
        bytes.split(|&byte| byte == b'\n').count() - 1,
        bytes
            .split(u8::is_ascii_whitespace)
            .filter(|word| !word.is_empty())
            .count(),
        bytes.len(),
    ]
}

/// Which of the three counts the flags at the start of `args` select, and how many arguments
/// those flags take up. All three when there is no flag.
///
/// # Errors
///
/// Returns the first flag character that is not `l`, `w` or `c`.
fn selection(args: &[String]) -> Result<([bool; 3], usize), char> {
    let mut selected = [false; 3];
    let mut flag_args = 0;
    for flags in args.iter().map_while(|arg| arg.strip_prefix('-')) {
        for flag in flags.chars() {
            let index = match flag {
                'l' => 0,
                'w' => 1,
                'c' => 2,
                other => return Err(other),
            };
            selected[index] = true;
        }
        flag_args += 1;
    }
    if flag_args == 0 {
        selected = [true; 3];
    }
    Ok((selected, flag_args))
}

/// One output line: the selected counts, then the name when there is one.
fn line(counts: [usize; 3], selected: [bool; 3], name: Option<&str>) -> String {
    let mut fields: Vec<String> = counts
        .iter()
        .zip(selected)
        .filter(|&(_, on)| on)
        .map(|(count, _)| count.to_string())
        .collect();
    fields.extend(name.map(str::to_owned));
    fields.join(" ")
}

#[expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "a command-line tool prints its counts and its errors from main"
)]
fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (selected, flag_args) = match selection(&args) {
        Ok(selection) => selection,
        Err(flag) => {
            eprintln!("wcount: unknown flag -{flag} (the flags are -l, -w and -c)");
            return ExitCode::FAILURE;
        }
    };
    let paths = &args[flag_args..];
    if paths.is_empty() {
        let mut input = Vec::new();
        if std::io::stdin().read_to_end(&mut input).is_err() {
            return ExitCode::FAILURE;
        }
        println!("{}", line(count(&input), selected, None));
        return ExitCode::SUCCESS;
    }

    let mut total = [0; 3];
    let mut failed = false;
    for path in paths {
        match std::fs::read(path) {
            Ok(contents) => {
                let counts = count(&contents);
                println!("{}", line(counts, selected, Some(path)));
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
        println!("{}", line(total, selected, Some("total")));
    }
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
