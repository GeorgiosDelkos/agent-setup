fn f(x: u8) -> u8 {
    match x {
        0 => 1,
        _ => unreachable!("x is masked to 0 above"),
    }
}

// unreachable!() in a comment
const S: &str = "unreachable!()";
