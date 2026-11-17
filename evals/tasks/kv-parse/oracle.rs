//! Outside check of the kv-parse task. The harness copies this file into the crate as
//! `tests/oracle.rs` after the session and the reviewer are done, so the session never sees
//! it. It asserts only what the task prompt states.

use kv_parse::parse;

/// The parsed pairs as owned strings, so the check holds whether `parse` returns borrowed or
/// owned keys and values.
fn pairs(input: &str) -> Vec<(String, String)> {
    parse(input)
        .expect("the input is valid")
        .into_iter()
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
}

fn pair(key: &str, value: &str) -> (String, String) {
    (key.to_owned(), value.to_owned())
}

/// The `Display` text of the error for `input`.
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
    assert!(error("a = 1\nb = 2\n\na = 9\n").contains('4'));
}

#[test]
fn a_key_with_other_characters_is_an_error_that_names_its_line() {
    assert!(error("ok = 1\nnot-ok = 2\n").contains('2'));
    assert!(error("with space = 1\n").contains('1'));
}

#[test]
fn a_line_without_a_key_or_an_equals_sign_is_an_error_that_names_its_line() {
    assert!(error("a = 1\n\n# c\n\njust words\n").contains('5'));
    assert!(error("a = 1\n = value\n").contains('2'));
}
