//! A correct solution of the kv-parse task. The harness tests use it as the stub session's
//! work, which pins `tasks/kv-parse/oracle.rs`: every oracle test must pass against it.

use std::fmt;

/// A line that is not a comment, blank, or a valid `key = value`.
#[derive(Debug)]
pub struct ParseError {
    line: usize,
    reason: &'static str,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.reason)
    }
}

/// Parses `key = value` lines and returns the pairs in file order.
///
/// # Errors
///
/// Returns a [`ParseError`] naming the first line that is malformed or repeats a key.
pub fn parse(input: &str) -> Result<Vec<(String, String)>, ParseError> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    for (index, line) in input.lines().enumerate() {
        let error = |reason| ParseError {
            line: index + 1,
            reason,
        };
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = line.split_once('=').ok_or_else(|| error("missing `=`"))?;
        let key = key.trim();
        if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return Err(error("a key is letters, digits and `_`"));
        }
        if pairs.iter().any(|(seen, _)| seen == key) {
            return Err(error("duplicate key"));
        }
        pairs.push((key.to_owned(), value.trim().to_owned()));
    }
    Ok(pairs)
}
