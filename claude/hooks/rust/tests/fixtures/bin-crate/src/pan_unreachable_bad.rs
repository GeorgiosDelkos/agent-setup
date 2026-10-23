fn f(x: u8) -> u8 {
    match x {
        0 => 1,
        _ => unreachable!(),
    }
}

fn g() {
    unreachable!( );
}
