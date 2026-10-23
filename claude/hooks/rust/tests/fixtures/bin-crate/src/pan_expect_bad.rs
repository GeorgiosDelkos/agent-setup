fn f(x: Option<u8>) -> u8 {
    let a = x.expect("");
    let b = x.expect("ok");
    let c = x.expect( "bad" );
    a + b + c
}
