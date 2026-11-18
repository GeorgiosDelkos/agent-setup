//! Outside check of the kv-parse task's follow-up, quoted values. The harness copies this file
//! into the crate as `tests/eval_followup.rs` after the follow-up session is done, so no
//! session sees it. It asserts only what the two prompts state.

use kv_parse::parse;

/// The value of the one pair `input` holds, as an owned string, so the check holds whether
/// `parse` returns borrowed or owned values. `let ... else`, not `expect`, which would need
/// the error type to implement `Debug`: the prompts ask only for `Display`.
fn value(input: &str) -> String {
    let Ok(parsed) = parse(input) else {
        panic!("{input:?} is valid");
    };
    let mut values: Vec<String> = parsed.into_iter().map(|(_, value)| owned(value)).collect();
    assert_eq!(values.len(), 1, "{input:?} holds one pair");
    values.remove(0)
}

/// Through `AsRef`, not `to_string` or `String::from`: each of those is a lint finding for
/// one of the types a session may return (`String`, `&str`, `Cow<str>`).
fn owned(text: impl AsRef<str>) -> String {
    text.as_ref().to_owned()
}

/// The `Display` text of the error for `input`. Callers look for the line number as a
/// digit, so no input they pass holds a digit of its own.
fn error(input: &str) -> String {
    match parse(input) {
        Ok(_) => panic!("{input:?} must be rejected"),
        Err(error) => error.to_string(),
    }
}

#[test]
fn whitespace_inside_the_quotes_is_kept() {
    assert_eq!(value("a = \"  two words  \"\n"), "  two words  ");
}

#[test]
fn a_quoted_value_may_hold_a_hash_and_an_equals_sign() {
    assert_eq!(value("a = \"x # y = z\"\n"), "x # y = z");
}

#[test]
fn the_two_escapes_stand_for_a_quote_and_a_backslash() {
    assert_eq!(
        value("a = \"say \\\"hi\\\" in C:\\\\dir\"\n"),
        "say \"hi\" in C:\\dir"
    );
    // An escaped backslash before the closing quote does not escape that quote.
    assert_eq!(value("a = \"tail\\\\\"\n"), "tail\\");
}

#[test]
fn an_empty_quoted_value_is_empty() {
    assert_eq!(value("a = \"\"\n"), "");
}

#[test]
fn whitespace_may_follow_the_closing_quote() {
    assert_eq!(value("a = \"x\"  \t\n"), "x");
    assert_eq!(value("a = \"x\""), "x");
}

#[test]
fn a_missing_closing_quote_is_an_error_that_names_its_line() {
    assert!(error("a = \"x\"\nb = \"never closed\n").contains('2'));
    // The quote that would close it is escaped.
    assert!(error("a = \"x\\\"\n").contains('1'));
}

#[test]
fn text_after_the_closing_quote_is_an_error_that_names_its_line() {
    assert!(error("\n\na = \"x\" y\n").contains('3'));
}

#[test]
fn any_other_escape_is_an_error_that_names_its_line() {
    assert!(error("a = \"x\"\nb = \"tab\\there\"\n").contains('2'));
}

#[test]
fn a_value_that_does_not_start_with_a_quote_works_as_before() {
    assert_eq!(value("a = say \"hi\" \\ there\n"), "say \"hi\" \\ there");
}
