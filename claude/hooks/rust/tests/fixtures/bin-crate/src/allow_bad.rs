fn f(x: Option<u8>) -> u8 {
    // house-check: allow(PAN-EXPECT):
    let a = x.expect("ok");
    // house-check: allow(LAY-SUPER): a different ID does not cover this line
    let b = x.expect("id");
    let c = x.expect("no"); let _ = 0; // house-check: allow(PAN-EXPECT)
    a + b + c
}
