fn read(p: *const u8) -> u8 {
    // SAFETY: the caller guarantees p is valid for reads.
    unsafe { *p }
}

fn read_multi(p: *const u8) -> u8 {
    // SAFETY:
    // - p is non-null and aligned (checked by the caller).
    let v =
        unsafe { *p };
    v
}

struct S;
// SAFETY: S holds no references.
#[allow(dead_code)]
unsafe impl Send for S {}

unsafe fn contract() {}

fn strings() -> &'static str {
    let _raw = r#"unsafe { "quoted" }"#;
    let _c = '"';
    "unsafe { not code }"
}

/* unsafe { in a block comment } */

/// ```
/// unsafe { core::hint::unreachable_unchecked() }
/// ```
fn doc() {}

fn chained(p: *const u8) -> u8 {
    // SAFETY: p is valid for reads (caller contract).
    let v = Some(1)
        .map(|_| unsafe { *p })
        .unwrap_or(0);
    v
}
