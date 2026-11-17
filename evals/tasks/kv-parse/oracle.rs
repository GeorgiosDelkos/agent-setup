//! Outside check of the kv-parse task. The harness copies this file into the crate as
//! `tests/eval_oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use kv_parse::parse;

/// The parsed pairs as owned strings, so the check holds whether `parse` returns borrowed or
/// owned keys and values. `let ... else`, not `expect`, which would need the error type to
/// implement `Debug`: the prompt asks only for `Display`.
fn pairs(input: &str) -> Vec<(String, String)> {
    let Ok(parsed) = parse(input) else {
        panic!("{input:?} is valid");
    };
    parsed
        .into_iter()
        .map(|(key, value)| (owned(key), owned(value)))
        .collect()
}

/// Through `AsRef`, not `to_string` or `String::from`: each of those is a lint finding for
/// one of the types a session may return (`String`, `&str`), and an `#[expect]` would be
/// unfulfilled for the other. Checked by hand with `cargo clippy --all-targets` in a crate
/// seeded as the harness seeds one: the harness itself only runs `cargo test` on this file.
fn owned(text: impl AsRef<str>) -> String {
    text.as_ref().to_owned()
}

fn pair(key: &str, value: &str) -> (String, String) {
    (key.to_owned(), value.to_owned())
}

/// The `Display` text of the error for `input`. Callers look for the line number as a
/// digit, so no input they pass holds a digit of its own: an error that echoed the line
/// would otherwise pass with the wrong number.
fn error(input: &str) -> String {
    match parse(input) {
        Ok(_) => panic!("{input:?} must be rejected"),
        Err(error) => error.to_string(),
    }
}

#[test]
fn pairs_come_back_in_file_order() {
    assert_eq!(
        pairs("zeta = 1\nalpha = 2\nmid_3 = 4\n"),
        [pair("zeta", "1"), pair("alpha", "2"), pair("mid_3", "4")]
    );
}

#[test]
fn comments_and_blank_lines_are_skipped() {
    assert_eq!(
        pairs("# heading\n\na = 1\n   \n# between\nb = 2\n"),
        [pair("a", "1"), pair("b", "2")]
    );
    assert_eq!(pairs(""), []);
}

#[test]
fn whitespace_around_the_value_is_removed_and_inside_it_kept() {
    assert_eq!(
        pairs("name =    two words   \n"),
        [pair("name", "two words")]
    );
}

#[test]
fn the_value_is_the_rest_of_the_line() {
    assert_eq!(pairs("url = a=b=c\n"), [pair("url", "a=b=c")]);
    assert_eq!(pairs("empty =\n"), [pair("empty", "")]);
}

#[test]
fn the_last_line_needs_no_newline() {
    assert_eq!(pairs("a = 1"), [pair("a", "1")]);
}

#[test]
fn a_duplicate_key_is_an_error_that_names_its_line() {
    assert!(error("a = x\nb = y\n\na = z\n").contains('4'));
}

#[test]
fn a_key_with_other_characters_is_an_error_that_names_its_line() {
    assert!(error("ok = x\nnot-ok = y\n").contains('2'));
    assert!(error("with space = x\n").contains('1'));
}

#[test]
fn a_line_without_a_key_or_an_equals_sign_is_an_error_that_names_its_line() {
    assert!(error("a = x\n\n# c\n\njust words\n").contains('5'));
    assert!(error("a = x\n = value\n").contains('2'));
}
