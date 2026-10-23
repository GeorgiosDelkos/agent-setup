// TODO(#123): handle the empty case
// FIXME(https://github.com/owner/repo/issues/1): upstream bug
// TODO(MSRV 1.85): switch to try_update
const TODO_LIST: &str = "TODO: not a comment";
fn f() {}

/// Returns the TODO items, oldest first.
fn todo_items() {}
// The XXX field is a placeholder; HACK and FIXME appear here only as words.
/* Lists every TODO in the file. */
