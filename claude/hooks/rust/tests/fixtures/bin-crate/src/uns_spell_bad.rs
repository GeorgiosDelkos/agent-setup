fn read(p: *const u8) -> u8 {
    // Safety: p is valid
    unsafe { *p }
}

fn read_bare(p: *const u8) -> u8 {
    unsafe { *p }
}

fn read_empty(p: *const u8) -> u8 {
    // SAFETY:
    unsafe { *p }
}

struct S;
//SAFETY S holds no references
unsafe impl Send for S {}

/// SAFETY: a doc comment is not a safety comment
fn doc_not_safety(p: *const u8) -> u8 { unsafe { *p } }

fn two(p: *const u8) -> u8 {
    // SAFETY: covers only the statement below, not the next one.
    let a = 1;
    let b = a
        + unsafe { *p };
    b
}
