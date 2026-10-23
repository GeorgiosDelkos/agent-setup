fn f(x: Option<u8>, msg: &str) -> u8 {
    let a = x.expect("config was validated in new()");
    let b = x.expect(msg);
    let c = x.expect("seeded above");
    // x.expect("")
    let _s = "x.expect(\"\")";
    a + b + c
}
