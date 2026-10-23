fn f(x: Option<u8>) -> u8 {
    // house-check: allow(PAN-EXPECT): "ok" is the protocol's literal status name
    let a = x.expect("ok");
    let b = x.expect("id"); // house-check: allow(PAN-EXPECT): same protocol literal
    a + b
}
